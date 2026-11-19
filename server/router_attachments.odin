package server

import "../common"
import "core:crypto"
import "core:encoding/cbor"
import "core:fmt"
import "core:sync"
import "core:time"

// Attachment transfers in the router (protocol 26, attachments plan F1, D5-D9, D17). The router
// orchestrates: the database worker decides (database_attachments.odin), the storage worker
// writes and reads (storage.odin), and the router seals and opens the channel 5 packets with
// the session's file keys, keeps every transfer's flow control, and paces each session.
//
// Upload: ClientAttachmentUploadBegin -> the begin statement -> StorageUploadOpen ->
// ServerAttachmentUploadReady. Chunks arrive in order from `received`; each is handed to the
// storage worker (paced) and acknowledged with an UploadAck only once it is written.
// ClientAttachmentUploadFinish -> StorageUploadFinish (size and hash, fsync, rename) -> the
// finish statement -> ServerAttachmentUploadDone. ClientAttachmentUploadResume reopens an
// Uploading blob at the length of its part file.
//
// Download: ClientAttachmentDownload -> the download check -> ServerAttachmentDownloadBegin,
// then StorageRead per chunk (paced, at most ATTACHMENT_WINDOW_CHUNKS unacknowledged), each
// sealed as a DownloadChunk; the client acknowledges every chunk.
//
// A session's transfers end with the session (disconnect, protocol violation, kick or ban): an
// upload's part file stays for a resume. Database and storage answers can arrive after that,
// so every pending step remembers the session ID and checks it before it answers anyone.

// How often an upload's progress (received, last_chunk_at) reaches the database, so the
// sweeper's "no chunk for an hour" sees an active upload as active.
ATTACHMENT_PROGRESS_PERSIST_INTERVAL :: 30 * time.Second
// The sweeper (D17) runs at startup and then this often; a full batch runs again soon.
ATTACHMENT_SWEEP_INTERVAL :: time.Hour
ATTACHMENT_SWEEP_FOLLOW_UP :: 2 * time.Second

AttachmentQueuedChunk :: struct {
	offset: u64,
	data:   []u8, // owned
}

AttachmentUploadTransfer :: struct {
	peerID:      u32,
	sessionID:   common.SessionID,
	userID:      int,
	blobId:      common.AttachmentBlobID,
	size:        u64,
	written:     u64, // bytes the storage worker confirmed
	expected:    u64, // the offset the next chunk must have
	// Chunks that arrived and wait for the pace, oldest first; and chunks the storage worker
	// has not answered yet. Together at most ATTACHMENT_WINDOW_CHUNKS.
	queued:      [dynamic]AttachmentQueuedChunk,
	inStorage:   int,
	finishing:   bool,
	lastPersist: time.Tick,
	persisted:   u64,
}

AttachmentDownloadKey :: struct {
	peerID: u32,
	blobId: common.AttachmentBlobID,
}

AttachmentDownloadTransfer :: struct {
	peerID:      u32,
	sessionID:   common.SessionID,
	blobId:      common.AttachmentBlobID,
	size:        u64,
	nextRead:    u64, // the next offset to ask the storage worker for
	reads:       int, // reads the storage worker has not answered
	sentOffsets: [dynamic]u64, // chunks sent and not yet acknowledged, oldest first
}

AttachmentPendingStorageKind :: enum u8 {
	Open,
	Write,
	Finish,
	Read,
	DeleteBlobs,
	Scan,
	DeleteOrphans,
}

AttachmentPendingStorage :: struct {
	kind:      AttachmentPendingStorageKind,
	peerID:    u32,
	sessionID: common.SessionID,
	userID:    int,
	blobId:    common.AttachmentBlobID,
	requestId: u32, // the client's begin request ID (0 for a resume)
	resume:    bool,
	size:      u64,
	sha256:    common.AttachmentSHA256, // Finish: the client's hash, for the finish statement
}

// A session's byte pace (D8): a token bucket shared by its uploads and downloads.
AttachmentPace :: struct {
	tokens: f64,
	last:   time.Tick,
}

// Counters for the [Status] line and the F1 measurement of file crypto on the router thread.
AttachmentRouterStats :: struct {
	bytesIn:      u64,
	bytesOut:     u64,
	packetsIn:    u64,
	packetsOut:   u64,
	cryptoNanos:  i64, // time spent in sealFilePacket and openFilePacket
	blobsSwept:   u64,
	orphansFound: u64,
}

// A session's file channel halves (protocol 26), taken out of its transport at sign-in
// (MainRouterState_attachmentsOpenChannel). Heap-allocated so a map rehash never copies keys,
// and wiped when the session ends.
AttachmentChannel :: struct {
	sessionID: common.SessionID,
	send:      common.ChannelSendState,
	receive:   common.ControlReceiveState,
}

RouterAttachmentState :: struct {
	channels:      map[u32]^AttachmentChannel,
	uploads:       map[common.AttachmentBlobID]^AttachmentUploadTransfer,
	downloads:     map[AttachmentDownloadKey]^AttachmentDownloadTransfer,
	pending:       map[u64]AttachmentPendingStorage,
	// Begins and resumes between the client's request and Ready, per session (the upload cap),
	// and download checks in the database (the download cap).
	pendingUploads:   map[common.SessionID]int,
	pendingDownloads: map[common.SessionID]int,
	// Blobs a begin or resume is opening right now, so a second resume cannot open them twice.
	opening:       map[common.AttachmentBlobID]bool,
	pace:          map[u32]AttachmentPace,
	// Scratch for one attachment packet's plaintext (encode and open).
	plaintext:     []u8,
	nextSweep:     time.Tick,
	sweepInFlight: bool,
	scanStarted:   bool,
	// The startup scan's files while the database says which have rows. Owned.
	scanFiles:     [dynamic]StorageFile,
	stats:         AttachmentRouterStats,
}

RouterAttachmentState_init :: proc() -> RouterAttachmentState {
	return RouterAttachmentState {
		channels = make(map[u32]^AttachmentChannel),
		uploads = make(map[common.AttachmentBlobID]^AttachmentUploadTransfer),
		downloads = make(map[AttachmentDownloadKey]^AttachmentDownloadTransfer),
		pending = make(map[u64]AttachmentPendingStorage),
		pendingUploads = make(map[common.SessionID]int),
		pendingDownloads = make(map[common.SessionID]int),
		opening = make(map[common.AttachmentBlobID]bool),
		pace = make(map[u32]AttachmentPace),
		plaintext = make([]u8, common.ATTACHMENT_PACKET_MAX_SIZE),
		scanFiles = make([dynamic]StorageFile),
	}
}

@(private = "file")
AttachmentUploadTransfer_free :: proc(upload: ^AttachmentUploadTransfer) {
	for chunk in upload.queued {
		delete(chunk.data)
	}
	delete(upload.queued)
	free(upload)
}

@(private = "file")
AttachmentDownloadTransfer_free :: proc(download: ^AttachmentDownloadTransfer) {
	delete(download.sentOffsets)
	free(download)
}

@(private = "file")
AttachmentChannel_free :: proc(channel: ^AttachmentChannel) {
	common.ChannelSendState_wipe(&channel.send)
	common.ControlReceiveState_wipe(&channel.receive)
	free(channel)
}

RouterAttachmentState_deinit :: proc(attachments: ^RouterAttachmentState) {
	for _, channel in attachments.channels {
		AttachmentChannel_free(channel)
	}
	delete(attachments.channels)
	for _, upload in attachments.uploads {
		AttachmentUploadTransfer_free(upload)
	}
	for _, download in attachments.downloads {
		AttachmentDownloadTransfer_free(download)
	}
	delete(attachments.uploads)
	delete(attachments.downloads)
	delete(attachments.pending)
	delete(attachments.pendingUploads)
	delete(attachments.pendingDownloads)
	delete(attachments.opening)
	delete(attachments.pace)
	delete(attachments.plaintext)
	delete(attachments.scanFiles)
	attachments^ = {}
}

// ── Helpers ───────────────────────────────────────────────────────

// The session of peerID when it is still the authenticated session sessionID.
@(private = "file")
attachmentSession :: proc(
	state: ^MainRouterState,
	peerID: u32,
	sessionID: common.SessionID,
) -> (
	^RouterPeerSession,
	bool,
) {
	session, ok := &state.peerSessions[peerID]
	if !ok || !session.isAuthenticated {
		return nil, false
	}
	expected := sessionID
	current := session.transport.sessionID
	if current != expected {
		return nil, false
	}
	return session, true
}

@(private = "file")
attachmentRefuse :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	sessionID: common.SessionID,
	requestId: u32,
	blobId: common.AttachmentBlobID,
	message: string,
) {
	if _, ok := attachmentSession(state, peerID, sessionID); !ok {
		return
	}
	MainRouterState_sendPeerMessage(
		pm,
		state,
		peerID,
		.ServerAttachmentRefused,
		common.ServerAttachmentRefusedPayload {
			requestId = requestId,
			blobId = blobId,
			message = message,
		},
	)
}

@(private = "file")
attachmentSend :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	sessionID: common.SessionID,
	messageType: common.MessageType,
	payload: any,
) {
	if _, ok := attachmentSession(state, peerID, sessionID); ok {
		MainRouterState_sendPeerMessage(pm, state, peerID, messageType, payload)
	}
}

@(private = "file")
attachmentStorageSend :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	request: StorageRequest,
	pending: AttachmentPendingStorage,
	answered := true,
) {
	requestID: u64 = 0
	if answered {
		requestID = MainRouterState_generateRequestID(state)
		state.attachments.pending[requestID] = pending
	}
	IPC_Server_send(
		&pm.config.storageSocket,
		pm.config.storageFd,
		StorageCommand{requestId = requestID, request = request},
	)
}

@(private = "file")
attachmentDatabaseSend :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	request: common.DatabaseAttachmentRequest,
	pending: PendingDBRequest,
) {
	pendingRequest := pending
	pendingRequest.requestType = .Attachment
	pendingRequest.attachmentAction = request.action
	pendingRequest.blobID = request.blobId
	MainRouterState_enqueueChannelDatabaseRequest(pm, state, peerID, request, pendingRequest)
}

// Seals one attachment packet with the session's file keys and queues it on channel 5.
@(private = "file")
attachmentSendPacket :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	sessionID: common.SessionID,
	packet: common.AttachmentPacket,
) -> bool {
	attachments := &state.attachments
	channel, hasChannel := attachments.channels[peerID]
	expected := sessionID
	if !hasChannel || channel.sessionID != expected {
		return false
	}
	n, encodeOK := common.encodeAttachmentPacket(packet, attachments.plaintext)
	if !encodeOK {
		return false
	}
	sealed := make([]u8, n + common.FILE_PACKET_OVERHEAD)
	start := time.tick_now()
	sealedLength, sealOK := common.sealFilePacket(
		&channel.send,
		channel.sessionID,
		attachments.plaintext[:n],
		sealed,
	)
	attachments.stats.cryptoNanos += i64(time.tick_since(start))
	if !sealOK {
		delete(sealed)
		return false
	}
	attachments.stats.packetsOut += 1
	attachments.stats.bytesOut += u64(len(packet.data))
	IPC_Server_send(
		&pm.config.networkSocket,
		pm.config.networkFd,
		NetworkSendData{peerId = peerID, channel = .FileTransfer, data = sealed[:sealedLength]},
	)
	return true
}

@(private = "file")
attachmentSessionUploads :: proc(state: ^MainRouterState, sessionID: common.SessionID) -> int {
	count := state.attachments.pendingUploads[sessionID]
	for _, upload in state.attachments.uploads {
		if upload.sessionID == sessionID {
			count += 1
		}
	}
	return count
}

@(private = "file")
attachmentSessionDownloads :: proc(state: ^MainRouterState, sessionID: common.SessionID) -> int {
	count := state.attachments.pendingDownloads[sessionID]
	for _, download in state.attachments.downloads {
		if download.sessionID == sessionID {
			count += 1
		}
	}
	return count
}

@(private = "file")
attachmentCountDown :: proc(counts: ^map[common.SessionID]int, sessionID: common.SessionID) {
	if value, ok := counts[sessionID]; ok {
		if value <= 1 {
			delete_key(counts, sessionID)
		} else {
			counts[sessionID] = value - 1
		}
	}
}

// Takes up to cost bytes of the session's pace. A chunk goes when the bucket is positive, and
// the bucket may go negative by one chunk, so a large chunk is never starved.
@(private = "file")
attachmentPaceTake :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	cost: int,
	now: time.Tick,
) -> bool {
	rate := f64(pm.config.attachmentSessionBytesPerSecond)
	if rate <= 0 {
		rate = f64(DEFAULT_ATTACHMENT_SESSION_BYTES_PER_SECOND)
	}
	burst := max(rate / 4, f64(2 * common.ATTACHMENT_CHUNK_BYTES))
	pace, ok := state.attachments.pace[peerID]
	if !ok {
		pace = AttachmentPace {
			tokens = burst,
			last   = now,
		}
	}
	elapsed := time.duration_seconds(time.tick_diff(pace.last, now))
	if elapsed > 0 {
		pace.tokens = min(burst, pace.tokens + elapsed * rate)
		pace.last = now
	}
	taken := pace.tokens > 0
	if taken {
		pace.tokens -= f64(cost)
	}
	state.attachments.pace[peerID] = pace
	return taken
}

@(private = "file")
attachmentRemoveUpload :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	blobId: common.AttachmentBlobID,
	closeFile: bool,
	discard := false,
) {
	upload, ok := state.attachments.uploads[blobId]
	if !ok {
		return
	}
	if closeFile {
		attachmentStorageSend(
			pm,
			state,
			StorageUploadClose{blobId = blobId, discard = discard},
			{},
			answered = false,
		)
	}
	delete_key(&state.attachments.uploads, blobId)
	AttachmentUploadTransfer_free(upload)
}

@(private = "file")
attachmentRemoveDownload :: proc(state: ^MainRouterState, key: AttachmentDownloadKey) {
	if download, ok := state.attachments.downloads[key]; ok {
		delete_key(&state.attachments.downloads, key)
		AttachmentDownloadTransfer_free(download)
	}
}

// Ends an upload the session can no longer continue but may resume: tells the client why,
// records its progress, and closes the part file (kept).
@(private = "file")
attachmentAbortUpload :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	upload: ^AttachmentUploadTransfer,
	message: string,
) {
	attachmentRefuse(pm, state, upload.peerID, upload.sessionID, 0, upload.blobId, message)
	attachmentPersistProgress(pm, state, upload)
	attachmentRemoveUpload(pm, state, upload.blobId, closeFile = true)
}

@(private = "file")
attachmentPersistProgress :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	upload: ^AttachmentUploadTransfer,
) {
	upload.lastPersist = time.tick_now()
	if upload.persisted == upload.written {
		return
	}
	upload.persisted = upload.written
	attachmentDatabaseSend(
		pm,
		state,
		upload.peerID,
		common.DatabaseAttachmentRequest {
			action = .Progress,
			userId = upload.userID,
			blobId = upload.blobId,
			size = upload.written,
		},
		PendingDBRequest{sessionID = upload.sessionID},
	)
}

@(private = "file")
attachmentDecode :: proc(payload: []u8, value: ^$T) -> bool {
	// Fixed-size byte fields decode through the temporary allocator, which the router never
	// frees, so they decode through the heap instead (server/AGENTS.md).
	return cbor.unmarshal(payload, value, temp_allocator = context.allocator) == nil
}

@(private = "file")
attachmentAuthenticated :: proc(
	state: ^MainRouterState,
	peerID: u32,
) -> (
	session: RouterPeerSession,
	ok: bool,
) {
	session, ok = MainRouterState_getPeerSession(state, peerID)
	return session, ok && session.isAuthenticated
}

// ── Control messages ──────────────────────────────────────────────

MainRouterState_handleClientAttachmentUploadBegin :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	payload: []u8,
) {
	session, ok := attachmentAuthenticated(state, peerID)
	if !ok {
		MainRouterState_sendProtocolError(pm, state, peerID, "Unauthenticated attachment request")
		return
	}
	sessionID := session.transport.sessionID
	req: common.ClientAttachmentUploadBeginPayload
	if !attachmentDecode(payload, &req) {
		attachmentRefuse(
			pm,
			state,
			peerID,
			sessionID,
			0,
			{},
			common.ATTACHMENT_INVALID_REQUEST_MESSAGE,
		)
		return
	}
	refusal := ""
	switch {
	case !pm.config.attachmentsEnabled:
		refusal = common.ATTACHMENTS_DISABLED_MESSAGE
	case (req.roomId > 0) == (req.recipientUserId > 0),
	     req.roomId < 0,
	     req.recipientUserId < 0,
	     req.recipientUserId == session.authenticatedUserID,
	     req.size == 0:
		refusal = common.ATTACHMENT_INVALID_REQUEST_MESSAGE
	case req.size > u64(pm.config.attachmentMaxBytes):
		refusal = common.ATTACHMENT_TOO_LARGE_MESSAGE
	case attachmentSessionUploads(state, sessionID) >= common.ATTACHMENT_UPLOADS_PER_SESSION_MAX:
		refusal = common.ATTACHMENT_TOO_MANY_UPLOADS_MESSAGE
	}
	if len(refusal) > 0 {
		attachmentRefuse(pm, state, peerID, sessionID, req.requestId, {}, refusal)
		return
	}
	blobId: common.AttachmentBlobID
	for !common.attachmentBlobIDIsSet(blobId) {
		crypto.rand_bytes(blobId[:])
	}
	state.attachments.pendingUploads[sessionID] += 1
	state.attachments.opening[blobId] = true
	attachmentDatabaseSend(
		pm,
		state,
		peerID,
		common.DatabaseAttachmentRequest {
			action = .Begin,
			userId = session.authenticatedUserID,
			blobId = blobId,
			roomId = req.roomId,
			recipientUserId = req.recipientUserId,
			encrypted = req.encrypted,
			size = req.size,
			maxBytes = pm.config.attachmentMaxBytes,
			quotaBytes = pm.config.attachmentAccountQuotaBytes,
			bytesPerHour = pm.config.attachmentUploadBytesPerHour,
			capacityBytes = pm.config.attachmentCapacityBytes,
		},
		PendingDBRequest {
			sessionID = sessionID,
			attachmentRequestID = req.requestId,
			attachmentSize = req.size,
			targetUserID = session.authenticatedUserID,
		},
	)
}

MainRouterState_handleClientAttachmentUploadResume :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	payload: []u8,
) {
	session, ok := attachmentAuthenticated(state, peerID)
	if !ok {
		MainRouterState_sendProtocolError(pm, state, peerID, "Unauthenticated attachment request")
		return
	}
	sessionID := session.transport.sessionID
	req: common.ClientAttachmentUploadResumePayload
	if !attachmentDecode(payload, &req) || !common.attachmentBlobIDIsSet(req.blobId) {
		attachmentRefuse(
			pm,
			state,
			peerID,
			sessionID,
			0,
			req.blobId,
			common.ATTACHMENT_INVALID_REQUEST_MESSAGE,
		)
		return
	}
	refusal := ""
	_, active := state.attachments.uploads[req.blobId]
	switch {
	case !pm.config.attachmentsEnabled:
		refusal = common.ATTACHMENTS_DISABLED_MESSAGE
	case active || state.attachments.opening[req.blobId]:
		refusal = common.ATTACHMENT_ALREADY_ACTIVE_MESSAGE
	case attachmentSessionUploads(state, sessionID) >= common.ATTACHMENT_UPLOADS_PER_SESSION_MAX:
		refusal = common.ATTACHMENT_TOO_MANY_UPLOADS_MESSAGE
	}
	if len(refusal) > 0 {
		attachmentRefuse(pm, state, peerID, sessionID, 0, req.blobId, refusal)
		return
	}
	state.attachments.pendingUploads[sessionID] += 1
	state.attachments.opening[req.blobId] = true
	attachmentDatabaseSend(
		pm,
		state,
		peerID,
		common.DatabaseAttachmentRequest {
			action = .Resume,
			userId = session.authenticatedUserID,
			blobId = req.blobId,
		},
		PendingDBRequest{sessionID = sessionID, targetUserID = session.authenticatedUserID},
	)
}

MainRouterState_handleClientAttachmentUploadFinish :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	payload: []u8,
) {
	session, ok := attachmentAuthenticated(state, peerID)
	if !ok {
		MainRouterState_sendProtocolError(pm, state, peerID, "Unauthenticated attachment request")
		return
	}
	sessionID := session.transport.sessionID
	req: common.ClientAttachmentUploadFinishPayload
	if !attachmentDecode(payload, &req) {
		attachmentRefuse(
			pm,
			state,
			peerID,
			sessionID,
			0,
			{},
			common.ATTACHMENT_INVALID_REQUEST_MESSAGE,
		)
		return
	}
	upload, active := state.attachments.uploads[req.blobId]
	if !active || upload.sessionID != sessionID {
		attachmentRefuse(
			pm,
			state,
			peerID,
			sessionID,
			0,
			req.blobId,
			common.ATTACHMENT_NOT_FOUND_MESSAGE,
		)
		return
	}
	if upload.finishing ||
	   upload.written != upload.size ||
	   len(upload.queued) > 0 ||
	   upload.inStorage > 0 {
		attachmentRefuse(
			pm,
			state,
			peerID,
			sessionID,
			0,
			req.blobId,
			common.ATTACHMENT_INCOMPLETE_MESSAGE,
		)
		return
	}
	upload.finishing = true
	attachmentStorageSend(
		pm,
		state,
		StorageUploadFinish{blobId = req.blobId, size = upload.size, sha256 = req.sha256},
		AttachmentPendingStorage {
			kind = .Finish,
			peerID = peerID,
			sessionID = sessionID,
			userID = upload.userID,
			blobId = req.blobId,
			size = upload.size,
			sha256 = req.sha256,
		},
	)
}

MainRouterState_handleClientAttachmentDownload :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	payload: []u8,
) {
	session, ok := attachmentAuthenticated(state, peerID)
	if !ok {
		MainRouterState_sendProtocolError(pm, state, peerID, "Unauthenticated attachment request")
		return
	}
	sessionID := session.transport.sessionID
	req: common.ClientAttachmentDownloadPayload
	if !attachmentDecode(payload, &req) || !common.attachmentBlobIDIsSet(req.blobId) {
		attachmentRefuse(
			pm,
			state,
			peerID,
			sessionID,
			0,
			req.blobId,
			common.ATTACHMENT_INVALID_REQUEST_MESSAGE,
		)
		return
	}
	if _, active := state.attachments.downloads[AttachmentDownloadKey{peerID, req.blobId}];
	   active {
		attachmentRefuse(
			pm,
			state,
			peerID,
			sessionID,
			0,
			req.blobId,
			common.ATTACHMENT_ALREADY_ACTIVE_MESSAGE,
		)
		return
	}
	if attachmentSessionDownloads(state, sessionID) >= common.ATTACHMENT_DOWNLOADS_PER_SESSION_MAX {
		attachmentRefuse(
			pm,
			state,
			peerID,
			sessionID,
			0,
			req.blobId,
			common.ATTACHMENT_TOO_MANY_DOWNLOADS_MESSAGE,
		)
		return
	}
	state.attachments.pendingDownloads[sessionID] += 1
	attachmentDatabaseSend(
		pm,
		state,
		peerID,
		common.DatabaseAttachmentRequest {
			action = .DownloadCheck,
			userId = session.authenticatedUserID,
			blobId = req.blobId,
		},
		PendingDBRequest{sessionID = sessionID, attachmentOffset = req.offset},
	)
}

MainRouterState_handleClientAttachmentCancel :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	payload: []u8,
) {
	session, ok := attachmentAuthenticated(state, peerID)
	if !ok {
		MainRouterState_sendProtocolError(pm, state, peerID, "Unauthenticated attachment request")
		return
	}
	req: common.ClientAttachmentCancelPayload
	if !attachmentDecode(payload, &req) {
		return
	}
	key := AttachmentDownloadKey{peerID, req.blobId}
	if _, downloading := state.attachments.downloads[key]; downloading {
		attachmentRemoveDownload(state, key)
		return
	}
	// An upload of this account, here or in a session that ended: the blob becomes a tombstone
	// in the database first, so nothing can resume it, and then its part file goes.
	if upload, active := state.attachments.uploads[req.blobId];
	   active && upload.sessionID == session.transport.sessionID {
		attachmentRemoveUpload(pm, state, req.blobId, closeFile = false)
	}
	attachmentDatabaseSend(
		pm,
		state,
		peerID,
		common.DatabaseAttachmentRequest {
			action = .Abandon,
			userId = session.authenticatedUserID,
			blobId = req.blobId,
		},
		PendingDBRequest{sessionID = session.transport.sessionID},
	)
}

// ── Channel 5 ─────────────────────────────────────────────────────

// Handles one channel 5 packet. Only an authenticated session may send them; a packet that does
// not open or decode ends the session like a bad control packet, and one that breaks a
// transfer's order or window ends only that transfer.
MainRouterState_handleFilePacket :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	data: []u8,
) {
	session, ok := &state.peerSessions[peerID]
	if !ok || !session.isAuthenticated {
		return
	}
	attachments := &state.attachments
	sessionID := session.transport.sessionID
	channel, hasChannel := attachments.channels[peerID]
	if !hasChannel || channel.sessionID != sessionID {
		return
	}
	if len(data) > common.ATTACHMENT_SEALED_PACKET_MAX_SIZE {
		MainRouterState_protocolViolation(pm, state, peerID, "Oversized file packet")
		return
	}
	start := time.tick_now()
	n, openResult := common.openFilePacket(
		&channel.receive,
		channel.sessionID,
		data,
		attachments.plaintext,
	)
	attachments.stats.cryptoNanos += i64(time.tick_since(start))
	if openResult != .Ok {
		MainRouterState_protocolViolation(pm, state, peerID, "Failed to open file packet")
		return
	}
	packet, decodeResult := common.decodeAttachmentPacket(attachments.plaintext[:n])
	if decodeResult != .Ok {
		MainRouterState_protocolViolation(pm, state, peerID, "Invalid file packet")
		return
	}
	attachments.stats.packetsIn += 1
	#partial switch packet.kind {
	case .UploadChunk:
		upload, active := attachments.uploads[packet.blobId]
		if !active || upload.sessionID != sessionID {
			attachmentRefuse(
				pm,
				state,
				peerID,
				sessionID,
				0,
				packet.blobId,
				common.ATTACHMENT_NOT_FOUND_MESSAGE,
			)
			return
		}
		length := u64(len(packet.data))
		if upload.finishing ||
		   packet.offset != upload.expected ||
		   upload.expected + length > upload.size ||
		   len(upload.queued) + upload.inStorage >= common.ATTACHMENT_WINDOW_CHUNKS {
			attachmentAbortUpload(pm, state, upload, common.ATTACHMENT_FLOW_MESSAGE)
			return
		}
		attachments.stats.bytesIn += length
		upload.expected += length
		chunk := make([]u8, len(packet.data))
		copy(chunk, packet.data)
		append(&upload.queued, AttachmentQueuedChunk{offset = packet.offset, data = chunk})
		attachmentPumpUpload(pm, state, upload, time.tick_now())
	case .DownloadAck:
		key := AttachmentDownloadKey{peerID, packet.blobId}
		download, active := attachments.downloads[key]
		if !active || download.sessionID != sessionID {
			return
		}
		if len(download.sentOffsets) == 0 || download.sentOffsets[0] != packet.offset {
			attachmentRefuse(
				pm,
				state,
				peerID,
				sessionID,
				0,
				packet.blobId,
				common.ATTACHMENT_FLOW_MESSAGE,
			)
			attachmentRemoveDownload(state, key)
			return
		}
		ordered_remove(&download.sentOffsets, 0)
		if download.nextRead >= download.size &&
		   download.reads == 0 &&
		   len(download.sentOffsets) == 0 {
			attachmentRemoveDownload(state, key)
			return
		}
		attachmentPumpDownload(pm, state, download, time.tick_now())
	case:
		MainRouterState_protocolViolation(pm, state, peerID, "Unexpected file packet")
	}
}

// Hands an upload's queued chunks to the storage worker as the pace allows.
@(private = "file")
attachmentPumpUpload :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	upload: ^AttachmentUploadTransfer,
	now: time.Tick,
) {
	for len(upload.queued) > 0 {
		chunk := upload.queued[0]
		if !attachmentPaceTake(pm, state, upload.peerID, len(chunk.data), now) {
			return
		}
		ordered_remove(&upload.queued, 0)
		upload.inStorage += 1
		attachmentStorageSend(
			pm,
			state,
			StorageUploadWrite{blobId = upload.blobId, offset = chunk.offset, data = chunk.data},
			AttachmentPendingStorage {
				kind = .Write,
				peerID = upload.peerID,
				sessionID = upload.sessionID,
				blobId = upload.blobId,
			},
		)
	}
}

// Asks the storage worker for a download's next chunks, as the window and the pace allow.
@(private = "file")
attachmentPumpDownload :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	download: ^AttachmentDownloadTransfer,
	now: time.Tick,
) {
	for download.nextRead < download.size &&
	    download.reads + len(download.sentOffsets) < common.ATTACHMENT_WINDOW_CHUNKS {
		length := int(min(u64(common.ATTACHMENT_CHUNK_BYTES), download.size - download.nextRead))
		if !attachmentPaceTake(pm, state, download.peerID, length, now) {
			return
		}
		attachmentStorageSend(
			pm,
			state,
			StorageRead{blobId = download.blobId, offset = download.nextRead, length = length},
			AttachmentPendingStorage {
				kind = .Read,
				peerID = download.peerID,
				sessionID = download.sessionID,
				blobId = download.blobId,
				size = u64(length),
			},
		)
		download.reads += 1
		download.nextRead += u64(length)
	}
}

// ── Database results ──────────────────────────────────────────────

MainRouterState_handleAttachmentResult :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	request: PendingDBRequest,
	response: common.DatabaseQueryResponse,
) {
	result, resultOK := response.result.(common.DatabaseAttachmentResult)
	if !response.success || !resultOK {
		MainRouterState_attachmentDatabaseFailed(pm, state, request)
		return
	}
	peerID := request.peerID
	sessionID := request.sessionID
	blobId := request.blobID
	attachments := &state.attachments
	switch request.attachmentAction {
	case .Begin:
		if result.outcome != .Applied {
			attachmentCountDown(&attachments.pendingUploads, sessionID)
			delete_key(&attachments.opening, blobId)
			attachmentRefuse(
				pm,
				state,
				peerID,
				sessionID,
				request.attachmentRequestID,
				{},
				attachmentRefusalMessage(result.outcome),
			)
			return
		}
		attachmentStorageSend(
			pm,
			state,
			StorageUploadOpen {
				blobId = blobId,
				size = request.attachmentSize,
				minFreeBytes = pm.config.attachmentMinFreeBytes,
			},
			AttachmentPendingStorage {
				kind = .Open,
				peerID = peerID,
				sessionID = sessionID,
				userID = request.targetUserID,
				blobId = blobId,
				requestId = request.attachmentRequestID,
				size = request.attachmentSize,
			},
		)
	case .Resume:
		if result.outcome != .Applied {
			attachmentCountDown(&attachments.pendingUploads, sessionID)
			delete_key(&attachments.opening, blobId)
			attachmentRefuse(
				pm,
				state,
				peerID,
				sessionID,
				0,
				blobId,
				common.ATTACHMENT_NOT_FOUND_MESSAGE,
			)
			return
		}
		attachmentStorageSend(
			pm,
			state,
			StorageUploadOpen{blobId = blobId, size = result.size, resume = true},
			AttachmentPendingStorage {
				kind = .Open,
				peerID = peerID,
				sessionID = sessionID,
				userID = request.targetUserID,
				blobId = blobId,
				resume = true,
				size = result.size,
			},
		)
	case .Finish:
		attachmentRemoveUpload(pm, state, blobId, closeFile = false)
		if result.outcome != .Applied {
			attachmentRefuse(
				pm,
				state,
				peerID,
				sessionID,
				0,
				blobId,
				common.ATTACHMENT_STORAGE_ERROR_MESSAGE,
			)
			return
		}
		attachmentSend(
			pm,
			state,
			peerID,
			sessionID,
			.ServerAttachmentUploadDone,
			common.ServerAttachmentUploadDonePayload {
				blobId = blobId,
				size = result.size,
				sha256 = result.sha256,
			},
		)
	case .Abandon:
		if result.outcome == .Applied {
			// The tombstone is written; another session of the account may still have the upload.
			attachmentRemoveUpload(pm, state, blobId, closeFile = false)
			attachmentStorageSend(
				pm,
				state,
				StorageUploadClose{blobId = blobId, discard = true},
				{},
				answered = false,
			)
		}
	case .Progress, .DeleteNew:
	case .DownloadCheck:
		attachmentCountDown(&attachments.pendingDownloads, sessionID)
		if result.outcome != .Applied {
			attachmentRefuse(
				pm,
				state,
				peerID,
				sessionID,
				0,
				blobId,
				common.ATTACHMENT_NOT_FOUND_MESSAGE,
			)
			return
		}
		if request.attachmentOffset > result.size {
			attachmentRefuse(
				pm,
				state,
				peerID,
				sessionID,
				0,
				blobId,
				common.ATTACHMENT_INVALID_REQUEST_MESSAGE,
			)
			return
		}
		if _, ok := attachmentSession(state, peerID, sessionID); !ok {
			return
		}
		key := AttachmentDownloadKey{peerID, blobId}
		if _, active := attachments.downloads[key]; active {
			attachmentRefuse(
				pm,
				state,
				peerID,
				sessionID,
				0,
				blobId,
				common.ATTACHMENT_ALREADY_ACTIVE_MESSAGE,
			)
			return
		}
		attachmentSend(
			pm,
			state,
			peerID,
			sessionID,
			.ServerAttachmentDownloadBegin,
			common.ServerAttachmentDownloadBeginPayload {
				blobId = blobId,
				size = result.size,
				offset = request.attachmentOffset,
			},
		)
		if request.attachmentOffset == result.size {
			return
		}
		download := new(AttachmentDownloadTransfer)
		download^ = AttachmentDownloadTransfer {
			peerID      = peerID,
			sessionID   = sessionID,
			blobId      = blobId,
			size        = result.size,
			nextRead    = request.attachmentOffset,
			sentOffsets = make([dynamic]u64, 0, common.ATTACHMENT_WINDOW_CHUNKS),
		}
		attachments.downloads[key] = download
		attachmentPumpDownload(pm, state, download, time.tick_now())
	case .Sweep:
		attachments.sweepInFlight = false
		if len(result.blobs) == 0 {
			return
		}
		attachments.stats.blobsSwept += u64(len(result.blobs))
		fmt.printfln("[Attachments] Swept %d attachment rows", len(result.blobs))
		blobs := make([dynamic]common.DatabaseAttachmentBlob, 0, len(result.blobs))
		append(&blobs, ..result.blobs[:])
		attachmentStorageSend(
			pm,
			state,
			StorageDeleteBlobs{blobs = blobs},
			AttachmentPendingStorage{kind = .DeleteBlobs},
		)
		if len(result.blobs) >= ATTACHMENT_SWEEP_BATCH {
			attachments.nextSweep = time.tick_add(time.tick_now(), ATTACHMENT_SWEEP_FOLLOW_UP)
		}
	case .Known:
		attachmentDeleteOrphans(pm, state, result.blobs[:])
	}
}

// Every scanned file whose blob has no row, or a row in a state with no such file, is an orphan.
@(private = "file")
attachmentDeleteOrphans :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	known: []common.DatabaseAttachmentBlob,
) {
	attachments := &state.attachments
	states := make(map[common.AttachmentBlobID]common.AttachmentState, len(known))
	defer delete(states)
	for blob in known {
		states[blob.blobId] = blob.state
	}
	orphans := make([dynamic]StorageFile)
	for file in attachments.scanFiles {
		rowState, hasRow := states[file.blobId]
		keep :=
			hasRow &&
			(file.isPart ? rowState == .Uploading : rowState == .Ready || rowState == .Bound)
		if !keep {
			append(&orphans, file)
		}
	}
	clear(&attachments.scanFiles)
	if len(orphans) == 0 {
		delete(orphans)
		return
	}
	attachments.stats.orphansFound += u64(len(orphans))
	attachmentStorageSend(
		pm,
		state,
		StorageDeleteOrphans{files = orphans},
		AttachmentPendingStorage{kind = .DeleteOrphans},
	)
}

@(private = "file")
attachmentRefusalMessage :: proc(outcome: common.DatabaseAttachmentOutcome) -> string {
	switch outcome {
	case .Applied, .NotFound:
		return common.ATTACHMENT_INVALID_REQUEST_MESSAGE
	case .NotMember:
		return common.ATTACHMENT_NOT_MEMBER_MESSAGE
	case .SendDenied:
		return common.ROOM_SEND_NOT_PERMITTED_MESSAGE
	case .AttachDenied:
		return common.ATTACHMENT_SEND_NOT_PERMITTED_MESSAGE
	case .ChatDisabled:
		return CHAT_DISABLED_MESSAGE
	case .EncryptionMismatch:
		return common.ATTACHMENT_ENCRYPTION_MISMATCH_MESSAGE
	case .UnknownRecipient:
		return common.ATTACHMENT_UNKNOWN_RECIPIENT_MESSAGE
	case .Restricted:
		return common.DIRECT_MESSAGE_RESTRICTED_MESSAGE
	case .TooLarge:
		return common.ATTACHMENT_TOO_LARGE_MESSAGE
	case .QuotaExceeded:
		return common.ATTACHMENT_QUOTA_MESSAGE
	case .RateExceeded:
		return common.ATTACHMENT_RATE_MESSAGE
	case .CapacityExceeded:
		return common.ATTACHMENT_STORAGE_FULL_MESSAGE
	}
	return common.ATTACHMENT_INVALID_REQUEST_MESSAGE
}

// A database request of an attachment step failed (the worker restarted, or the statement
// erred): undo what the router holds for it and tell the client.
MainRouterState_attachmentDatabaseFailed :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	request: PendingDBRequest,
) {
	attachments := &state.attachments
	switch request.attachmentAction {
	case .Begin, .Resume:
		attachmentCountDown(&attachments.pendingUploads, request.sessionID)
		delete_key(&attachments.opening, request.blobID)
		attachmentRefuse(
			pm,
			state,
			request.peerID,
			request.sessionID,
			request.attachmentRequestID,
			request.attachmentAction == .Begin ? {} : request.blobID,
			common.ATTACHMENT_UNAVAILABLE_MESSAGE,
		)
	case .Finish:
		attachmentRemoveUpload(pm, state, request.blobID, closeFile = false)
		attachmentRefuse(
			pm,
			state,
			request.peerID,
			request.sessionID,
			0,
			request.blobID,
			common.ATTACHMENT_UNAVAILABLE_MESSAGE,
		)
	case .DownloadCheck:
		attachmentCountDown(&attachments.pendingDownloads, request.sessionID)
		attachmentRefuse(
			pm,
			state,
			request.peerID,
			request.sessionID,
			0,
			request.blobID,
			common.ATTACHMENT_UNAVAILABLE_MESSAGE,
		)
	case .Sweep:
		attachments.sweepInFlight = false
	case .Known:
		clear(&attachments.scanFiles)
	case .Progress, .Abandon, .DeleteNew:
	}
}

// ── Storage results ───────────────────────────────────────────────

MainRouterState_handleStorageResponse :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	response: StorageResponse,
) {
	defer StorageResult_deinit(response.result)
	attachments := &state.attachments
	pending, ok := attachments.pending[response.requestId]
	if !ok {
		return
	}
	delete_key(&attachments.pending, response.requestId)
	switch r in response.result {
	case StorageUploadOpened:
		attachmentCountDown(&attachments.pendingUploads, pending.sessionID)
		delete_key(&attachments.opening, pending.blobId)
		_, live := attachmentSession(state, pending.peerID, pending.sessionID)
		if !r.ok {
			if !pending.resume {
				// Nothing was written: the row must not hold quota or rate (D21).
				attachmentDatabaseSend(
					pm,
					state,
					pending.peerID,
					common.DatabaseAttachmentRequest {
						action = .DeleteNew,
						userId = pending.userID,
						blobId = pending.blobId,
					},
					PendingDBRequest{sessionID = pending.sessionID},
				)
			}
			message := common.ATTACHMENT_STORAGE_ERROR_MESSAGE
			if r.full {
				message = common.ATTACHMENT_STORAGE_FULL_MESSAGE
			} else if pending.resume {
				message = common.ATTACHMENT_NOT_FOUND_MESSAGE
			}
			attachmentRefuse(
				pm,
				state,
				pending.peerID,
				pending.sessionID,
				pending.requestId,
				pending.resume ? pending.blobId : {},
				message,
			)
			return
		}
		if !live {
			// The client left before it heard the blob ID: a new blob cannot be resumed by
			// anyone, a resumed one keeps its part file.
			attachmentStorageSend(
				pm,
				state,
				StorageUploadClose{blobId = pending.blobId, discard = !pending.resume},
				{},
				answered = false,
			)
			if !pending.resume {
				attachmentDatabaseSend(
					pm,
					state,
					pending.peerID,
					common.DatabaseAttachmentRequest {
						action = .Abandon,
						userId = pending.userID,
						blobId = pending.blobId,
					},
					PendingDBRequest{sessionID = pending.sessionID},
				)
			}
			return
		}
		upload := new(AttachmentUploadTransfer)
		upload^ = AttachmentUploadTransfer {
			peerID      = pending.peerID,
			sessionID   = pending.sessionID,
			userID      = pending.userID,
			blobId      = pending.blobId,
			size        = pending.size,
			written     = r.received,
			expected    = r.received,
			queued      = make([dynamic]AttachmentQueuedChunk, 0, common.ATTACHMENT_WINDOW_CHUNKS),
			lastPersist = time.tick_now(),
			persisted   = r.received,
		}
		attachments.uploads[pending.blobId] = upload
		MainRouterState_sendPeerMessage(
			pm,
			state,
			pending.peerID,
			.ServerAttachmentUploadReady,
			common.ServerAttachmentUploadReadyPayload {
				requestId = pending.requestId,
				blobId = pending.blobId,
				received = r.received,
				chunkBytes = common.ATTACHMENT_CHUNK_BYTES,
				windowChunks = common.ATTACHMENT_WINDOW_CHUNKS,
			},
		)
	case StorageUploadWritten:
		upload, active := attachments.uploads[r.blobId]
		if !active || upload.sessionID != pending.sessionID {
			return
		}
		upload.inStorage = max(upload.inStorage - 1, 0)
		if !r.ok {
			attachmentAbortUpload(pm, state, upload, common.ATTACHMENT_STORAGE_ERROR_MESSAGE)
			return
		}
		upload.written += u64(r.length)
		if _, live := attachmentSession(state, upload.peerID, upload.sessionID); !live {
			return
		}
		attachmentSendPacket(
			pm,
			state,
			upload.peerID,
			upload.sessionID,
			common.AttachmentPacket{kind = .UploadAck, blobId = r.blobId, offset = r.offset},
		)
		if time.tick_since(upload.lastPersist) >= ATTACHMENT_PROGRESS_PERSIST_INTERVAL {
			attachmentPersistProgress(pm, state, upload)
		}
		attachmentPumpUpload(pm, state, upload, time.tick_now())
	case StorageUploadFinished:
		upload, active := attachments.uploads[r.blobId]
		if !active || upload.sessionID != pending.sessionID {
			// The session ended while the file was finishing; a stored blob still becomes Ready.
			if r.ok {
				attachmentDatabaseSend(
					pm,
					state,
					pending.peerID,
					common.DatabaseAttachmentRequest {
						action = .Finish,
						userId = pending.userID,
						blobId = r.blobId,
						size = pending.size,
						sha256 = pending.sha256,
					},
					PendingDBRequest{sessionID = pending.sessionID},
				)
			}
			return
		}
		if r.mismatch {
			// The part file is already gone; the row becomes a tombstone (D17).
			attachmentRemoveUpload(pm, state, r.blobId, closeFile = false)
			attachmentDatabaseSend(
				pm,
				state,
				pending.peerID,
				common.DatabaseAttachmentRequest {
					action = .Abandon,
					userId = pending.userID,
					blobId = r.blobId,
				},
				PendingDBRequest{sessionID = pending.sessionID},
			)
			attachmentRefuse(
				pm,
				state,
				pending.peerID,
				pending.sessionID,
				0,
				r.blobId,
				common.ATTACHMENT_MISMATCH_MESSAGE,
			)
			return
		}
		if !r.ok {
			attachmentRemoveUpload(pm, state, r.blobId, closeFile = false)
			attachmentRefuse(
				pm,
				state,
				pending.peerID,
				pending.sessionID,
				0,
				r.blobId,
				common.ATTACHMENT_STORAGE_ERROR_MESSAGE,
			)
			return
		}
		// The finish statement stores the hash the storage worker checked.
		attachmentDatabaseSend(
			pm,
			state,
			pending.peerID,
			common.DatabaseAttachmentRequest {
				action = .Finish,
				userId = upload.userID,
				blobId = r.blobId,
				size = upload.size,
				sha256 = pending.sha256,
			},
			PendingDBRequest{sessionID = pending.sessionID},
		)
	case StorageReadData:
		key := AttachmentDownloadKey{pending.peerID, r.blobId}
		download, active := attachments.downloads[key]
		if !active || download.sessionID != pending.sessionID {
			return
		}
		download.reads = max(download.reads - 1, 0)
		if _, live := attachmentSession(state, pending.peerID, pending.sessionID); !live {
			attachmentRemoveDownload(state, key)
			return
		}
		if !r.ok || u64(len(r.data)) != pending.size {
			attachmentRefuse(
				pm,
				state,
				pending.peerID,
				pending.sessionID,
				0,
				r.blobId,
				common.ATTACHMENT_STORAGE_ERROR_MESSAGE,
			)
			attachmentRemoveDownload(state, key)
			return
		}
		if !attachmentSendPacket(
			pm,
			state,
			pending.peerID,
			pending.sessionID,
			common.AttachmentPacket {
				kind = .DownloadChunk,
				blobId = r.blobId,
				offset = r.offset,
				data = r.data,
			},
		) {
			attachmentRemoveDownload(state, key)
			return
		}
		append(&download.sentOffsets, r.offset)
	case StorageBlobsDeleted:
	case StorageScanResult:
		if len(r.files) == 0 {
			return
		}
		clear(&attachments.scanFiles)
		append(&attachments.scanFiles, ..r.files[:])
		known := make([dynamic]common.AttachmentBlobID, 0, len(r.files))
		for file in r.files {
			append(&known, file.blobId)
		}
		attachmentDatabaseSend(
			pm,
			state,
			0,
			common.DatabaseAttachmentRequest{action = .Known, blobIds = known},
			{},
		)
	case StorageOrphansDeleted:
		if r.deleted > 0 {
			fmt.printfln("[Attachments] Deleted %d orphan attachment files", r.deleted)
		}
	}
}

// ── Lifecycle ─────────────────────────────────────────────────────

// Ends every transfer of a session that is going away (disconnect, protocol violation, kick or
// ban). Uploads keep their part files and record their progress, so the account can resume.
MainRouterState_attachmentsEndSession :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
) {
	attachments := &state.attachments
	session, ok := state.peerSessions[peerID]
	if ok {
		delete_key(&attachments.pendingUploads, session.transport.sessionID)
		delete_key(&attachments.pendingDownloads, session.transport.sessionID)
	}
	uploads := make([dynamic]^AttachmentUploadTransfer, 0, 2)
	defer delete(uploads)
	for _, upload in attachments.uploads {
		if upload.peerID == peerID {
			append(&uploads, upload)
		}
	}
	for upload in uploads {
		if upload.finishing {
			// The storage worker is finishing it; its answer still marks the blob Ready
			// (MainRouterState_handleStorageResponse, a transfer that is gone).
			attachmentRemoveUpload(pm, state, upload.blobId, closeFile = false)
			continue
		}
		attachmentPersistProgress(pm, state, upload)
		attachmentRemoveUpload(pm, state, upload.blobId, closeFile = true)
	}
	keys := make([dynamic]AttachmentDownloadKey, 0, 4)
	defer delete(keys)
	for key in attachments.downloads {
		if key.peerID == peerID {
			append(&keys, key)
		}
	}
	for key in keys {
		attachmentRemoveDownload(state, key)
	}
	delete_key(&attachments.pace, peerID)
	if channel, hasChannel := attachments.channels[peerID]; hasChannel {
		delete_key(&attachments.channels, peerID)
		AttachmentChannel_free(channel)
	}
}

// Takes the file channel halves out of a session's transport right after ServerAuthSuccess.
// From here on only these copies seal and open the session's channel 5 packets.
MainRouterState_attachmentsOpenChannel :: proc(
	state: ^MainRouterState,
	peerID: u32,
	transport: ^common.TransportState,
) {
	channel := new(AttachmentChannel)
	channel.sessionID = transport.sessionID
	channel.send, channel.receive = common.TransportState_takeFileState(transport)
	if old, hasOld := state.attachments.channels[peerID]; hasOld {
		AttachmentChannel_free(old)
	}
	state.attachments.channels[peerID] = channel
}

// The storage worker stopped: every transfer and pending storage step is gone with its state.
MainRouterState_attachmentsStorageStopped :: proc(pm: ^ProcessManager, state: ^MainRouterState) {
	attachments := &state.attachments
	for _, upload in attachments.uploads {
		attachmentRefuse(
			pm,
			state,
			upload.peerID,
			upload.sessionID,
			0,
			upload.blobId,
			common.ATTACHMENT_UNAVAILABLE_MESSAGE,
		)
		AttachmentUploadTransfer_free(upload)
	}
	clear(&attachments.uploads)
	for key, download in attachments.downloads {
		attachmentRefuse(
			pm,
			state,
			key.peerID,
			download.sessionID,
			0,
			key.blobId,
			common.ATTACHMENT_UNAVAILABLE_MESSAGE,
		)
		AttachmentDownloadTransfer_free(download)
	}
	clear(&attachments.downloads)
	for _, pending in attachments.pending {
		if pending.kind == .Open {
			attachmentRefuse(
				pm,
				state,
				pending.peerID,
				pending.sessionID,
				pending.requestId,
				pending.resume ? pending.blobId : {},
				common.ATTACHMENT_UNAVAILABLE_MESSAGE,
			)
		}
	}
	clear(&attachments.pending)
	clear(&attachments.pendingUploads)
	clear(&attachments.opening)
}

// Runs on every main loop pass: paces queued work, records progress, and starts the sweeper
// (at startup and hourly) and, once, the startup orphan scan.
MainRouterState_attachmentsTick :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	now: time.Tick,
) {
	attachments := &state.attachments
	for _, upload in attachments.uploads {
		if len(upload.queued) > 0 {
			attachmentPumpUpload(pm, state, upload, now)
		}
		if !upload.finishing &&
		   time.tick_diff(upload.lastPersist, now) >= ATTACHMENT_PROGRESS_PERSIST_INTERVAL {
			attachmentPersistProgress(pm, state, upload)
		}
	}
	for _, download in attachments.downloads {
		attachmentPumpDownload(pm, state, download, now)
	}
	// The storage thread registers its IPC endpoint as it starts; the scan waits for it.
	if !attachments.scanStarted && sync.atomic_load(&pm.config.storageFd) != 0 {
		attachments.scanStarted = true
		attachmentStorageSend(pm, state, StorageScan{}, AttachmentPendingStorage{kind = .Scan})
	}
	if !attachments.sweepInFlight && time.tick_diff(attachments.nextSweep, now) >= 0 {
		MainRouterState_attachmentsSweep(pm, state)
		attachments.nextSweep = time.tick_add(now, ATTACHMENT_SWEEP_INTERVAL)
	}
}

// One sweeper pass (D17): the database deletes the rows it may and the storage worker their
// files. Blobs with a live transfer are never swept.
MainRouterState_attachmentsSweep :: proc(pm: ^ProcessManager, state: ^MainRouterState) {
	attachments := &state.attachments
	active := make([dynamic]common.AttachmentBlobID, 0, len(attachments.uploads))
	for blobId in attachments.uploads {
		append(&active, blobId)
	}
	for key in attachments.downloads {
		append(&active, key.blobId)
	}
	attachments.sweepInFlight = true
	attachmentDatabaseSend(
		pm,
		state,
		0,
		common.DatabaseAttachmentRequest {
			action = .Sweep,
			pendingHours = pm.config.attachmentPendingHours,
			limit = ATTACHMENT_SWEEP_BATCH,
			blobIds = active,
		},
		{},
	)
}

MainRouterState_attachmentCounts :: proc(state: ^MainRouterState) -> (uploads, downloads: int) {
	return len(state.attachments.uploads), len(state.attachments.downloads)
}

// What ServerAuthSuccess.attachments announces (protocol 27, D18): whether uploads are on, the
// largest blob, the account quota (0 = none) and the account's stored bytes from the identity
// statement. A client refuses early with it; every limit is checked again at begin.
MainRouterState_attachmentLimits :: proc(
	pm: ^ProcessManager,
	usedBytes: u64,
) -> common.AttachmentLimits {
	return common.AttachmentLimits {
		enabled = pm.config.attachmentsEnabled,
		maxBytes = u64(max(pm.config.attachmentMaxBytes, 0)),
		quotaBytes = u64(max(pm.config.attachmentAccountQuotaBytes, 0)),
		usedBytes = usedBytes,
	}
}
