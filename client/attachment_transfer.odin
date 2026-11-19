package client

// Attachment transfers (protocol 26, docs/plan/2026-11-19-file-attachments.md F1): a transfer
// worker thread reads and writes the files, keeps each transfer's running SHA-256 and its D8
// window, and seals channel 5 packets through the server's transport. The network worker only
// moves packets: it opens a channel 5 packet and the attachment control answers and hands them
// here (ClientTransferWorker_deliver). Results come back as ClientTransferEvents, which the
// harness prints as attachment_progress, attachment_done and attachment_error.
//
// Threads and locks:
//   - The UI thread (or the harness) queues commands (ClientTransferWorker_upload, _resume,
//     _download, _cancel) and pops events, under the transfer worker's mutex.
//   - The network worker delivers answers and chunks with its own lock held, then takes the
//     transfer worker's mutex: lock order network worker mutex, then transfer worker mutex.
//   - The transfer thread owns every ClientTransfer and never holds its own mutex while it
//     takes the network worker's lock to send (control messages, or a chunk sealed with
//     transport.transport.fileSend, which only it uses).
//
// Protocol 27 (F2): an upload to an encrypted conversation is sealed here in the read path
// (common/attachment_e2ee.odin, AttachmentSealer): a random file key per file, every chunk
// sealed exactly once, and every sealed wire chunk kept in memory until the server acknowledged
// it, so a resume after a reconnect resends the same bytes and nothing is sealed twice (D12).
// An encrypted upload therefore cannot be resumed after a restart of the client. A download
// for a message (ClientTransferWorker_downloadVerified) checks the stored size and the whole
// blob's SHA-256 against the signed or sealed message and, for an encrypted file, opens it
// chunk by chunk (AttachmentOpener), writing only authenticated file bytes and checking that the
// padding is zero. A download is written to OUT.part next to OUT and renamed when every byte
// arrived and checked (D19); a failed check deletes the part file and reports
// common.ATTACHMENT_CHANGED_MESSAGE.

import "../common"
import "core:crypto"
import "core:crypto/sha2"
import "core:encoding/cbor"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

CLIENT_TRANSFER_IDLE_WAIT :: 20 * time.Millisecond
// At most one attachment_progress event per transfer this often (plus one at Ready).
CLIENT_TRANSFER_PROGRESS_INTERVAL :: 500 * time.Millisecond

ClientTransferDirection :: enum u8 {
	Upload,
	Download,
}

ClientTransferEventKind :: enum u8 {
	Progress,
	Done,
	Error,
}

// One transfer's progress or result. path and message are owned (free with
// ClientTransferEvent_deinit).
ClientTransferEvent :: struct {
	kind:      ClientTransferEventKind,
	direction: ClientTransferDirection,
	id:        int, // the local transfer ID the command returned
	serverID:  int,
	blobId:    common.AttachmentBlobID,
	hasBlobId: bool,
	bytes:     u64, // acknowledged (upload) or written (download) so far
	total:     u64,
	sha256:    common.AttachmentSHA256, // Done: the stored bytes' hash
	path:      string,
	message:   string, // Error: why
	elapsedMS: i64,
	// Protocol 27: whether the stored bytes are the encrypted format, the file's own size
	// (total is the stored size), and for an upload's Done the file key the sealed message
	// must carry (wiped by ClientTransferEvent_deinit).
	encrypted: bool,
	fileSize:  u64,
	key:       common.AttachmentFileKey,
}

ClientTransferEvent_deinit :: proc(event: ^ClientTransferEvent) {
	delete(event.path)
	delete(event.message)
	crypto.zero_explicit(&event.key, size_of(event.key))
	event.path = ""
	event.message = ""
}

// What a download for a message must find (protocol 27): the stored size and hash the signed or
// sealed message names and, for an encrypted file, its key and size. set false is the raw
// download of F1 (only the owner's own unbound blob is downloadable without a message).
ClientTransferExpect :: struct {
	set:        bool,
	storedSize: u64,
	sha256:     common.AttachmentSHA256,
	encrypted:  bool,
	key:        common.AttachmentFileKey,
	fileSize:   u64,
}

@(private = "file")
ClientTransferCommandKind :: enum u8 {
	Upload,
	Resume,
	Download,
	Cancel,
}

@(private = "file")
ClientTransferCommand :: struct {
	kind:            ClientTransferCommandKind,
	id:              int,
	serverID:        int,
	roomID:          int,
	recipientUserID: int,
	path:            string, // owned
	blobId:          common.AttachmentBlobID,
	encrypted:       bool, // Upload: seal the file (protocol 27)
	expect:          ClientTransferExpect, // Download: what to check (protocol 27)
}

ClientTransferInboundKind :: enum u8 {
	Ready,
	Done,
	DownloadBegin,
	Refused,
	UploadAck,
	DownloadChunk,
}

// What the network worker hands over: a decoded control answer or a channel 5 packet. message
// and data are owned.
ClientTransferInbound :: struct {
	kind:      ClientTransferInboundKind,
	serverID:  int,
	requestId: u32,
	blobId:    common.AttachmentBlobID,
	offset:    u64, // Ready: received; DownloadBegin: the start; chunks and acks: the offset
	size:      u64,
	sha256:    common.AttachmentSHA256,
	message:   string,
	data:      []u8,
}

@(private = "file")
ClientTransferInbound_deinit :: proc(inbound: ^ClientTransferInbound) {
	delete(inbound.message)
	delete(inbound.data)
	inbound^ = {}
}

@(private = "file")
ClientTransferState :: enum u8 {
	Beginning, // waiting for Ready or DownloadBegin
	Sending,
	Finishing, // every chunk acknowledged, ClientAttachmentUploadFinish sent
	Receiving,
	Finished, // done or failed; an upload with a blob ID stays for attach-resume
}

// A chunk in flight. An encrypted upload keeps its sealed bytes (owned) until the ack (D12).
@(private = "file")
ClientTransferChunk :: struct {
	offset: u64,
	length: u64,
	data:   []u8,
}

@(private = "file")
ClientTransfer :: struct {
	id:           int,
	direction:    ClientTransferDirection,
	serverID:     int,
	path:         string, // owned: the source (upload) or the destination (download)
	partPath:     string, // owned: OUT.part (download)
	blobId:       common.AttachmentBlobID,
	hasBlobId:    bool,
	requestId:    u32,
	state:        ClientTransferState,
	failed:       bool,
	file:         ^os.File,
	size:         u64,
	nextSend:     u64, // upload: the next offset to read and send
	done:         u64, // upload: acknowledged; download: written
	unacked:      [dynamic]ClientTransferChunk,
	hash:         sha2.Context_256,
	// The transport's session generation when the transfer started talking to the server: a
	// later session has no transfer, so a change means the connection was lost.
	generation:   u64,
	started:      time.Tick,
	lastProgress: time.Tick,
	// Protocol 27, an encrypted upload: the sealer (key, layout, chunks sealed so far), the
	// file's size, and the sealed bytes not yet cut into wire chunks (pending, owned, of
	// pendingLength bytes).
	encrypted:     bool,
	sealer:        common.AttachmentSealer,
	fileSize:      u64,
	pending:       []u8,
	pendingLength: int,
	// Protocol 27, a download for a message: what to check, and for an encrypted file the
	// opener (borrowing openerBuffer, owned) and the file bytes written so far.
	expect:        ClientTransferExpect,
	opener:        common.AttachmentOpener,
	openerBuffer:  []u8,
	written:       u64,
}

ClientTransferWorker :: struct {
	mutex:         sync.Mutex,
	cond:          sync.Cond,
	commands:      [dynamic]ClientTransferCommand,
	inbound:       [dynamic]ClientTransferInbound,
	events:        [dynamic]ClientTransferEvent,
	thread:        ^thread.Thread,
	stopping:      bool,
	nextID:        int,
	// Borrowed: the network worker and its transports (fixed while both workers run).
	network:       ^ClientNetworkWorker,
	transports:    []ClientServerTransport,
	// Owned by the transfer thread.
	transfers:     [dynamic]^ClientTransfer,
	nextRequestID: u32,
	plaintext:     []u8,
	sealed:        []u8,
	chunk:         []u8,
	// Protocol 27: the sealer's scratch plaintext and output, and the opener's output.
	sealScratch:   []u8,
	sealOutput:    []u8,
	openOutput:    []u8,
}

// Starts the transfer worker for the network worker's transports and binds it to each of them.
ClientTransferWorker_start :: proc(
	network: ^ClientNetworkWorker,
	transports: []ClientServerTransport,
) -> ^ClientTransferWorker {
	worker := new(ClientTransferWorker)
	worker.network = network
	worker.transports = transports
	worker.nextID = 1
	worker.nextRequestID = 1
	worker.commands = make([dynamic]ClientTransferCommand)
	worker.inbound = make([dynamic]ClientTransferInbound)
	worker.events = make([dynamic]ClientTransferEvent)
	worker.transfers = make([dynamic]^ClientTransfer)
	worker.plaintext = make([]u8, common.ATTACHMENT_PACKET_MAX_SIZE)
	worker.sealed = make([]u8, common.ATTACHMENT_SEALED_PACKET_MAX_SIZE)
	worker.chunk = make([]u8, common.ATTACHMENT_CHUNK_BYTES)
	worker.sealScratch = make([]u8, common.ATTACHMENT_E2EE_CHUNK_BYTES)
	worker.sealOutput = make([]u8, common.ATTACHMENT_E2EE_SEAL_OUTPUT_MAX)
	worker.openOutput = make([]u8, common.ATTACHMENT_E2EE_CHUNK_BYTES)
	ClientNetworkWorker_lock(network)
	for index in 0 ..< len(transports) {
		transports[index].transfers = worker
	}
	ClientNetworkWorker_unlock(network)
	worker.thread = thread.create_and_start_with_data(worker, clientTransferRun, context)
	return worker
}

// Unbinds the worker, stops its thread and frees it with every queued event and transfer. A
// download in progress leaves no part file behind.
ClientTransferWorker_stop :: proc(worker: ^ClientTransferWorker) {
	if worker == nil {
		return
	}
	ClientNetworkWorker_lock(worker.network)
	for index in 0 ..< len(worker.transports) {
		if worker.transports[index].transfers == worker {
			worker.transports[index].transfers = nil
		}
	}
	ClientNetworkWorker_unlock(worker.network)
	sync.mutex_lock(&worker.mutex)
	worker.stopping = true
	sync.cond_broadcast(&worker.cond)
	sync.mutex_unlock(&worker.mutex)
	if worker.thread != nil {
		thread.join(worker.thread)
		thread.destroy(worker.thread)
	}
	for transfer in worker.transfers {
		clientTransferClose(transfer, discardPart = true)
		clientTransferFree(transfer)
	}
	delete(worker.transfers)
	for &command in worker.commands {
		delete(command.path)
	}
	delete(worker.commands)
	for &inbound in worker.inbound {
		ClientTransferInbound_deinit(&inbound)
	}
	delete(worker.inbound)
	for &event in worker.events {
		ClientTransferEvent_deinit(&event)
	}
	delete(worker.events)
	delete(worker.plaintext)
	delete(worker.sealed)
	delete(worker.chunk)
	crypto.zero_explicit(raw_data(worker.sealScratch), len(worker.sealScratch))
	crypto.zero_explicit(raw_data(worker.openOutput), len(worker.openOutput))
	delete(worker.sealScratch)
	delete(worker.sealOutput)
	delete(worker.openOutput)
	free(worker)
}

@(private = "file")
clientTransferQueue :: proc(worker: ^ClientTransferWorker, command: ClientTransferCommand) -> int {
	sync.mutex_lock(&worker.mutex)
	defer sync.mutex_unlock(&worker.mutex)
	queued := command
	queued.id = worker.nextID
	worker.nextID += 1
	append(&worker.commands, queued)
	sync.cond_broadcast(&worker.cond)
	return queued.id
}

// Uploads path to a room (roomID) or a direct conversation (recipientUserID), sealed with a
// fresh file key when encrypted (protocol 27). Returns the local transfer ID that its events
// carry; the Done event of an encrypted upload carries the key and the file's size.
ClientTransferWorker_upload :: proc(
	worker: ^ClientTransferWorker,
	serverID, roomID, recipientUserID: int,
	path: string,
	encrypted := false,
) -> int {
	return clientTransferQueue(
		worker,
		ClientTransferCommand {
			kind = .Upload,
			serverID = serverID,
			roomID = roomID,
			recipientUserID = recipientUserID,
			path = strings.clone(path),
			encrypted = encrypted,
		},
	)
}

// Continues an upload of this process at the offset the server acknowledged last (D9).
ClientTransferWorker_resume :: proc(
	worker: ^ClientTransferWorker,
	serverID: int,
	blobId: common.AttachmentBlobID,
) -> int {
	return clientTransferQueue(
		worker,
		ClientTransferCommand{kind = .Resume, serverID = serverID, blobId = blobId},
	)
}

// Downloads a blob into path (through path.part).
ClientTransferWorker_download :: proc(
	worker: ^ClientTransferWorker,
	serverID: int,
	blobId: common.AttachmentBlobID,
	path: string,
) -> int {
	return clientTransferQueue(
		worker,
		ClientTransferCommand {
			kind = .Download,
			serverID = serverID,
			blobId = blobId,
			path = strings.clone(path),
		},
	)
}

// Downloads a message's file into path (through path.part) and checks it against expect: the
// stored size, the whole blob's hash and, for an encrypted file, every chunk and the padding
// (protocol 27). A failed check deletes the part file and reports
// common.ATTACHMENT_CHANGED_MESSAGE.
ClientTransferWorker_downloadVerified :: proc(
	worker: ^ClientTransferWorker,
	serverID: int,
	blobId: common.AttachmentBlobID,
	path: string,
	expect: ClientTransferExpect,
) -> int {
	verified := expect
	verified.set = true
	return clientTransferQueue(
		worker,
		ClientTransferCommand {
			kind = .Download,
			serverID = serverID,
			blobId = blobId,
			path = strings.clone(path),
			expect = verified,
		},
	)
}

// Stops an upload (which then cannot be resumed) or a download of the blob.
ClientTransferWorker_cancel :: proc(
	worker: ^ClientTransferWorker,
	serverID: int,
	blobId: common.AttachmentBlobID,
) -> int {
	return clientTransferQueue(
		worker,
		ClientTransferCommand{kind = .Cancel, serverID = serverID, blobId = blobId},
	)
}

// Moves the oldest event to the caller, who then owns it.
ClientTransferWorker_popEvent :: proc(
	worker: ^ClientTransferWorker,
) -> (
	event: ClientTransferEvent,
	ok: bool,
) {
	if worker == nil {
		return {}, false
	}
	sync.mutex_lock(&worker.mutex)
	defer sync.mutex_unlock(&worker.mutex)
	if len(worker.events) == 0 {
		return {}, false
	}
	event = worker.events[0]
	ordered_remove(&worker.events, 0)
	return event, true
}

// Called by the network worker with its lock held; takes ownership of inbound.
ClientTransferWorker_deliver :: proc(
	worker: ^ClientTransferWorker,
	inbound: ClientTransferInbound,
) {
	sync.mutex_lock(&worker.mutex)
	append(&worker.inbound, inbound)
	sync.cond_broadcast(&worker.cond)
	sync.mutex_unlock(&worker.mutex)
}

// ── Network worker side (worker lock held) ───────────────────────

@(private = "file")
clientTransferDeliverOrFree :: proc(
	transport: ^ClientServerTransport,
	inbound: ClientTransferInbound,
) {
	if transport.transfers == nil {
		dropped := inbound
		ClientTransferInbound_deinit(&dropped)
		return
	}
	ClientTransferWorker_deliver(transport.transfers, inbound)
}

// Decodes an attachment control answer (an opened control packet) for the transfer worker.
ClientServerTransport_receiveAttachmentControl :: proc(
	transport: ^ClientServerTransport,
	packet: common.Packet,
) {
	inbound := ClientTransferInbound {
		serverID = transport.serverID,
	}
	// Fixed-size byte fields decode through the temporary allocator; use the heap.
	decoded := false
	#partial switch packet.messageType {
	case .ServerAttachmentUploadReady:
		payload: common.ServerAttachmentUploadReadyPayload
		if cbor.unmarshal(packet.payload, &payload, temp_allocator = context.allocator) == nil {
			decoded = true
			inbound.kind = .Ready
			inbound.requestId = payload.requestId
			inbound.blobId = payload.blobId
			inbound.offset = payload.received
		}
	case .ServerAttachmentUploadDone:
		payload: common.ServerAttachmentUploadDonePayload
		if cbor.unmarshal(packet.payload, &payload, temp_allocator = context.allocator) == nil {
			decoded = true
			inbound.kind = .Done
			inbound.blobId = payload.blobId
			inbound.size = payload.size
			inbound.sha256 = payload.sha256
		}
	case .ServerAttachmentDownloadBegin:
		payload: common.ServerAttachmentDownloadBeginPayload
		if cbor.unmarshal(packet.payload, &payload, temp_allocator = context.allocator) == nil {
			decoded = true
			inbound.kind = .DownloadBegin
			inbound.blobId = payload.blobId
			inbound.size = payload.size
			inbound.offset = payload.offset
		}
	case .ServerAttachmentRefused:
		payload: common.ServerAttachmentRefusedPayload
		if cbor.unmarshal(packet.payload, &payload, temp_allocator = context.allocator) == nil {
			decoded = true
			inbound.kind = .Refused
			inbound.requestId = payload.requestId
			inbound.blobId = payload.blobId
			inbound.message = payload.message
		} else {
			common.ServerAttachmentRefusedPayload_deinit(&payload)
		}
	}
	if !decoded {
		ClientServerTransport_runtimeProtocolError(transport, "invalid attachment payload")
		return
	}
	clientTransferDeliverOrFree(transport, inbound)
}

// Opens one channel 5 packet with the session's file keys and hands it to the transfer worker.
// Returns false when the packet does not open or decode, which ends the session like a bad
// control packet.
ClientServerTransport_receiveFilePacket :: proc(
	transport: ^ClientServerTransport,
	datagram: []u8,
) -> bool {
	if len(datagram) > common.ATTACHMENT_SEALED_PACKET_MAX_SIZE {
		return false
	}
	plaintext := make([]u8, len(datagram))
	defer delete(plaintext)
	n, result := common.openFilePacket(
		&transport.transport.fileReceive,
		transport.transport.sessionID,
		datagram,
		plaintext,
	)
	if result != .Ok {
		return false
	}
	packet, decodeResult := common.decodeAttachmentPacket(plaintext[:n])
	if decodeResult != .Ok {
		return false
	}
	inbound := ClientTransferInbound {
		serverID = transport.serverID,
		blobId   = packet.blobId,
		offset   = packet.offset,
	}
	#partial switch packet.kind {
	case .UploadAck:
		inbound.kind = .UploadAck
	case .DownloadChunk:
		inbound.kind = .DownloadChunk
		inbound.data = make([]u8, len(packet.data))
		copy(inbound.data, packet.data)
	case:
		return false
	}
	clientTransferDeliverOrFree(transport, inbound)
	return true
}

// ── Transfer thread ──────────────────────────────────────────────

@(private = "file")
clientTransferRun :: proc(data: rawptr) {
	worker := cast(^ClientTransferWorker)data
	commands := make([dynamic]ClientTransferCommand)
	defer delete(commands)
	inbound := make([dynamic]ClientTransferInbound)
	defer delete(inbound)
	for {
		sync.mutex_lock(&worker.mutex)
		if len(worker.commands) == 0 && len(worker.inbound) == 0 && !worker.stopping {
			sync.cond_wait_with_timeout(&worker.cond, &worker.mutex, CLIENT_TRANSFER_IDLE_WAIT)
		}
		stopping := worker.stopping
		append(&commands, ..worker.commands[:])
		clear(&worker.commands)
		append(&inbound, ..worker.inbound[:])
		clear(&worker.inbound)
		sync.mutex_unlock(&worker.mutex)
		if stopping {
			for &command in commands {
				delete(command.path)
			}
			for &item in inbound {
				ClientTransferInbound_deinit(&item)
			}
			return
		}
		for command in commands {
			clientTransferHandleCommand(worker, command)
		}
		clear(&commands)
		for &item in inbound {
			clientTransferHandleInbound(worker, &item)
			ClientTransferInbound_deinit(&item)
		}
		clear(&inbound)
		clientTransferCheckSessions(worker)
		free_all(context.temp_allocator)
	}
}

@(private = "file")
clientTransferFree :: proc(transfer: ^ClientTransfer) {
	delete(transfer.path)
	delete(transfer.partPath)
	clientTransferDropUnacked(transfer)
	delete(transfer.unacked)
	clientTransferWipeCrypto(transfer)
	free(transfer)
}

@(private = "file")
clientTransferDropUnacked :: proc(transfer: ^ClientTransfer) {
	for chunk in transfer.unacked {
		delete(chunk.data)
	}
	clear(&transfer.unacked)
}

// Wipes and frees what an encrypted transfer holds: the sealer (its key), the sealed bytes not
// yet sent, the opener and its buffer. Called when the transfer can never continue.
@(private = "file")
clientTransferWipeCrypto :: proc(transfer: ^ClientTransfer) {
	common.AttachmentSealer_wipe(&transfer.sealer)
	if len(transfer.pending) > 0 {
		crypto.zero_explicit(raw_data(transfer.pending), len(transfer.pending))
	}
	delete(transfer.pending)
	transfer.pending = nil
	transfer.pendingLength = 0
	common.AttachmentOpener_wipe(&transfer.opener)
	delete(transfer.openerBuffer)
	transfer.openerBuffer = nil
	crypto.zero_explicit(&transfer.expect.key, size_of(transfer.expect.key))
}

@(private = "file")
clientTransferClose :: proc(transfer: ^ClientTransfer, discardPart := false) {
	if transfer.file != nil {
		os.close(transfer.file)
		transfer.file = nil
	}
	if discardPart && len(transfer.partPath) > 0 && transfer.direction == .Download {
		_ = os.remove(transfer.partPath)
	}
}

@(private = "file")
clientTransferEmit :: proc(
	worker: ^ClientTransferWorker,
	transfer: ^ClientTransfer,
	kind: ClientTransferEventKind,
	message := "",
) {
	event := ClientTransferEvent {
		kind      = kind,
		direction = transfer.direction,
		id        = transfer.id,
		serverID  = transfer.serverID,
		blobId    = transfer.blobId,
		hasBlobId = transfer.hasBlobId,
		bytes     = transfer.done,
		total     = transfer.size,
		path      = strings.clone(transfer.path),
		message   = strings.clone(message),
		elapsedMS = i64(time.duration_milliseconds(time.tick_since(transfer.started))),
		encrypted = transfer.encrypted || transfer.expect.encrypted,
		fileSize  = transfer.fileSize,
	}
	if kind == .Done {
		hash := transfer.hash
		sha2.final(&hash, event.sha256[:])
		if transfer.direction == .Upload && transfer.encrypted {
			event.key = transfer.sealer.key
		}
	}
	transfer.lastProgress = time.tick_now()
	sync.mutex_lock(&worker.mutex)
	append(&worker.events, event)
	sync.mutex_unlock(&worker.mutex)
}

@(private = "file")
clientTransferFail :: proc(
	worker: ^ClientTransferWorker,
	transfer: ^ClientTransfer,
	message: string,
) {
	if transfer.state == .Finished {
		return
	}
	transfer.state = .Finished
	transfer.failed = true
	clientTransferClose(transfer, discardPart = true)
	clientTransferEmit(worker, transfer, .Error, message)
	if transfer.direction == .Download {
		clientTransferWipeCrypto(transfer)
	}
}

// A transfer the command or packet names, newest first.
@(private = "file")
clientTransferFind :: proc(
	worker: ^ClientTransferWorker,
	serverID: int,
	blobId: common.AttachmentBlobID,
	direction: ClientTransferDirection,
	activeOnly: bool,
) -> ^ClientTransfer {
	#reverse for transfer in worker.transfers {
		if transfer.serverID == serverID &&
		   transfer.hasBlobId &&
		   transfer.blobId == blobId &&
		   transfer.direction == direction &&
		   (!activeOnly || transfer.state != .Finished) {
			return transfer
		}
	}
	return nil
}

@(private = "file")
clientTransferTransport :: proc(
	worker: ^ClientTransferWorker,
	serverID: int,
) -> ^ClientServerTransport {
	for index in 0 ..< len(worker.transports) {
		if worker.transports[index].serverID == serverID {
			return &worker.transports[index]
		}
	}
	return nil
}

// Sends a control message through the server's session, under the network worker's lock, and
// returns that session's generation.
@(private = "file")
clientTransferSendControl :: proc(
	worker: ^ClientTransferWorker,
	serverID: int,
	messageType: common.MessageType,
	payload: any,
) -> (
	generation: u64,
	ok: bool,
) {
	ClientNetworkWorker_lock(worker.network)
	defer ClientNetworkWorker_unlock(worker.network)
	transport := clientTransferTransport(worker, serverID)
	if transport == nil || !ClientServerTransport_isConnected(transport) {
		return 0, false
	}
	if !ClientServerTransport_sendEncryptedRuntimeMessage(transport, messageType, payload) {
		return 0, false
	}
	return transport.sessionGeneration, true
}

// Seals an attachment packet with the session's file keys and sends it reliably on channel 5,
// only in the session the transfer started in.
@(private = "file")
clientTransferSendPacket :: proc(
	worker: ^ClientTransferWorker,
	transfer: ^ClientTransfer,
	packet: common.AttachmentPacket,
) -> bool {
	n, encodeOK := common.encodeAttachmentPacket(packet, worker.plaintext)
	if !encodeOK {
		return false
	}
	ClientNetworkWorker_lock(worker.network)
	defer ClientNetworkWorker_unlock(worker.network)
	transport := clientTransferTransport(worker, transfer.serverID)
	if transport == nil ||
	   !ClientServerTransport_isConnected(transport) ||
	   transport.sessionGeneration != transfer.generation {
		return false
	}
	length, sealOK := common.sealFilePacket(
		&transport.transport.fileSend,
		transport.transport.sessionID,
		worker.plaintext[:n],
		worker.sealed,
	)
	if !sealOK {
		return false
	}
	return ClientServerTransport_sendENetPacket(
		transport.enetHost,
		transport.enetPeer,
		STARTUP_AUTH_CHANNEL_FILE,
		worker.sealed[:length],
	)
}

@(private = "file")
clientTransferHandleCommand :: proc(worker: ^ClientTransferWorker, command: ClientTransferCommand) {
	switch command.kind {
	case .Upload:
		transfer := new(ClientTransfer)
		transfer^ = ClientTransfer {
			id        = command.id,
			direction = .Upload,
			serverID  = command.serverID,
			path      = command.path,
			started   = time.tick_now(),
			unacked   = make([dynamic]ClientTransferChunk),
		}
		append(&worker.transfers, transfer)
		file, err := os.open(command.path, {.Read})
		if err != nil {
			clientTransferFail(worker, transfer, fmt.tprintf("cannot open the file: %v", err))
			return
		}
		transfer.file = file
		size, sizeErr := os.file_size(file)
		if sizeErr != nil || size < 0 || (size == 0 && !command.encrypted) {
			clientTransferFail(worker, transfer, "the file is empty or unreadable")
			return
		}
		transfer.fileSize = u64(size)
		transfer.size = u64(size)
		if command.encrypted {
			// A fresh key for this file only (D12); the stored size is the sealed layout's.
			key, keyOK := common.generateAttachmentFileKey()
			sealer, sealerErr := common.AttachmentSealer_init(key, u64(size))
			crypto.zero_explicit(&key, size_of(key))
			if !keyOK || sealerErr != .None {
				clientTransferFail(worker, transfer, "cannot encrypt the file")
				return
			}
			transfer.encrypted = true
			transfer.sealer = sealer
			transfer.size = sealer.layout.storedSize
			transfer.pending = make(
				[]u8,
				common.ATTACHMENT_CHUNK_BYTES + common.ATTACHMENT_E2EE_SEAL_OUTPUT_MAX,
			)
		}
		transfer.requestId = worker.nextRequestID
		worker.nextRequestID += 1
		generation, sent := clientTransferSendControl(
			worker,
			command.serverID,
			.ClientAttachmentUploadBegin,
			common.ClientAttachmentUploadBeginPayload {
				requestId = transfer.requestId,
				roomId = command.roomID,
				recipientUserId = command.recipientUserID,
				size = transfer.size,
				encrypted = command.encrypted,
			},
		)
		if !sent {
			clientTransferFail(worker, transfer, NOT_CONNECTED_MESSAGE)
			return
		}
		transfer.generation = generation
	case .Resume:
		transfer := clientTransferFind(worker, command.serverID, command.blobId, .Upload, false)
		if transfer == nil {
			fake := ClientTransfer {
				id        = command.id,
				direction = .Upload,
				serverID  = command.serverID,
				blobId    = command.blobId,
				hasBlobId = true,
				started   = time.tick_now(),
			}
			clientTransferEmit(
				worker,
				&fake,
				.Error,
				"unknown upload: only an upload this process started can be resumed",
			)
			return
		}
		if transfer.state != .Finished || !transfer.failed {
			fake := transfer^
			fake.id = command.id
			clientTransferEmit(worker, &fake, .Error, "the upload is not stopped")
			return
		}
		file, err := os.open(transfer.path, {.Read})
		if err != nil {
			clientTransferEmit(worker, transfer, .Error, "cannot open the file again")
			return
		}
		transfer.file = file
		transfer.id = command.id
		transfer.started = time.tick_now()
		transfer.state = .Beginning
		transfer.failed = false
		transfer.requestId = 0
		// A plaintext upload reads its chunks again from the file; an encrypted one keeps the
		// sealed chunks in flight and resends exactly those (D12).
		if !transfer.encrypted {
			clientTransferDropUnacked(transfer)
		}
		generation, sent := clientTransferSendControl(
			worker,
			transfer.serverID,
			.ClientAttachmentUploadResume,
			common.ClientAttachmentUploadResumePayload{blobId = transfer.blobId},
		)
		if !sent {
			clientTransferFail(worker, transfer, NOT_CONNECTED_MESSAGE)
			return
		}
		transfer.generation = generation
	case .Download:
		transfer := new(ClientTransfer)
		transfer^ = ClientTransfer {
			id        = command.id,
			direction = .Download,
			serverID  = command.serverID,
			path      = command.path,
			partPath  = strings.concatenate({command.path, ".part"}),
			blobId    = command.blobId,
			hasBlobId = true,
			started   = time.tick_now(),
			expect    = command.expect,
		}
		append(&worker.transfers, transfer)
		if active := clientTransferFind(worker, command.serverID, command.blobId, .Download, true);
		   active != nil && active != transfer {
			clientTransferFail(worker, transfer, "this blob is already downloading")
			return
		}
		generation, sent := clientTransferSendControl(
			worker,
			command.serverID,
			.ClientAttachmentDownload,
			common.ClientAttachmentDownloadPayload{blobId = command.blobId},
		)
		if !sent {
			clientTransferFail(worker, transfer, NOT_CONNECTED_MESSAGE)
			return
		}
		transfer.generation = generation
	case .Cancel:
		_, _ = clientTransferSendControl(
			worker,
			command.serverID,
			.ClientAttachmentCancel,
			common.ClientAttachmentCancelPayload{blobId = command.blobId},
		)
		for direction in ClientTransferDirection {
			serverID := command.serverID
			if transfer := clientTransferFind(worker, serverID, command.blobId, direction, true);
			   transfer != nil {
				clientTransferFail(worker, transfer, "cancelled")
				// A cancelled upload is a tombstone on the server: it cannot be resumed.
				transfer.hasBlobId = direction == .Download
				clientTransferDropUnacked(transfer)
				clientTransferWipeCrypto(transfer)
			}
		}
	}
}

@(private = "file")
clientTransferHandleInbound :: proc(
	worker: ^ClientTransferWorker,
	inbound: ^ClientTransferInbound,
) {
	switch inbound.kind {
	case .Ready:
		transfer: ^ClientTransfer
		for candidate in worker.transfers {
			if candidate.serverID != inbound.serverID ||
			   candidate.direction != .Upload ||
			   candidate.state != .Beginning {
				continue
			}
			byRequest := inbound.requestId != 0 && candidate.requestId == inbound.requestId
			byBlob :=
				inbound.requestId == 0 && candidate.hasBlobId && candidate.blobId == inbound.blobId
			if byRequest || byBlob {
				transfer = candidate
				break
			}
		}
		if transfer == nil {
			return
		}
		if inbound.offset > transfer.size {
			clientTransferFail(worker, transfer, "the server reported more bytes than the file has")
			return
		}
		transfer.blobId = inbound.blobId
		transfer.hasBlobId = true
		if transfer.encrypted {
			clientTransferResumeSealed(worker, transfer, inbound.offset)
			return
		}
		// The running hash covers every byte from the start: rebuild it up to the server's
		// offset on a resume (D9).
		sha2.init_256(&transfer.hash)
		position := u64(0)
		for position < inbound.offset {
			length := min(u64(len(worker.chunk)), inbound.offset - position)
			n, err := os.read_at(transfer.file, worker.chunk[:length], i64(position))
			if err != nil || u64(n) != length {
				clientTransferFail(worker, transfer, "cannot read the file")
				return
			}
			sha2.update(&transfer.hash, worker.chunk[:n])
			position += length
		}
		transfer.nextSend = inbound.offset
		transfer.done = inbound.offset
		transfer.state = .Sending
		clientTransferEmit(worker, transfer, .Progress)
		clientTransferPumpUpload(worker, transfer)
	case .UploadAck:
		transfer := clientTransferFind(worker, inbound.serverID, inbound.blobId, .Upload, true)
		if transfer == nil || transfer.state != .Sending {
			return
		}
		if len(transfer.unacked) == 0 || transfer.unacked[0].offset != inbound.offset {
			clientTransferFail(worker, transfer, "the server acknowledged an unexpected chunk")
			return
		}
		transfer.done += transfer.unacked[0].length
		delete(transfer.unacked[0].data)
		ordered_remove(&transfer.unacked, 0)
		clientTransferPumpUpload(worker, transfer)
	case .Done:
		transfer := clientTransferFind(worker, inbound.serverID, inbound.blobId, .Upload, true)
		if transfer == nil || transfer.state != .Finishing {
			return
		}
		transfer.state = .Finished
		clientTransferClose(transfer)
		mine: common.AttachmentSHA256
		hash := transfer.hash
		sha2.final(&hash, mine[:])
		if inbound.sha256 != mine || inbound.size != transfer.size {
			transfer.failed = true
			clientTransferEmit(worker, transfer, .Error, "the server stored different bytes")
			clientTransferWipeCrypto(transfer)
			return
		}
		clientTransferEmit(worker, transfer, .Done)
		clientTransferWipeCrypto(transfer)
	case .DownloadBegin:
		transfer := clientTransferFind(worker, inbound.serverID, inbound.blobId, .Download, true)
		if transfer == nil || transfer.state != .Beginning {
			return
		}
		if inbound.offset != 0 || inbound.size == 0 {
			clientTransferFail(worker, transfer, "unexpected download start")
			return
		}
		transfer.fileSize = inbound.size
		if transfer.expect.set {
			// The message names the stored size; for an encrypted file the layout of the
			// sealed size must give it too (AttachmentOpener_init).
			if inbound.size != transfer.expect.storedSize {
				clientTransferFail(worker, transfer, common.ATTACHMENT_CHANGED_MESSAGE)
				return
			}
			if transfer.expect.encrypted {
				transfer.openerBuffer = make([]u8, common.ATTACHMENT_E2EE_SEALED_CHUNK_MAX)
				opener, openerErr := common.AttachmentOpener_init(
					transfer.expect.key,
					transfer.expect.fileSize,
					inbound.size,
					transfer.openerBuffer,
				)
				if openerErr != .None {
					clientTransferFail(worker, transfer, common.ATTACHMENT_CHANGED_MESSAGE)
					return
				}
				transfer.opener = opener
				transfer.fileSize = transfer.expect.fileSize
			}
		}
		file, err := os.open(transfer.partPath, {.Write, .Create, .Trunc}, os.perm(0o600))
		if err != nil {
			clientTransferFail(
				worker,
				transfer,
				fmt.tprintf("cannot write %s: %v", transfer.partPath, err),
			)
			return
		}
		transfer.file = file
		transfer.size = inbound.size
		transfer.done = 0
		sha2.init_256(&transfer.hash)
		transfer.state = .Receiving
		clientTransferEmit(worker, transfer, .Progress)
	case .DownloadChunk:
		transfer := clientTransferFind(worker, inbound.serverID, inbound.blobId, .Download, true)
		if transfer == nil || transfer.state != .Receiving {
			return
		}
		length := u64(len(inbound.data))
		if inbound.offset != transfer.done || transfer.done + length > transfer.size {
			clientTransferFail(worker, transfer, "the server sent an unexpected chunk")
			return
		}
		if transfer.expect.set && transfer.expect.encrypted {
			// Only authenticated file bytes reach the part file; padding is checked, not
			// written.
			remaining := inbound.data
			for len(remaining) > 0 {
				consumed, produced, openErr := common.AttachmentOpener_feed(
					&transfer.opener,
					remaining,
					worker.openOutput,
				)
				if openErr != .None {
					clientTransferFail(worker, transfer, common.ATTACHMENT_CHANGED_MESSAGE)
					return
				}
				if produced > 0 {
					n, err := os.write_at(
						transfer.file,
						worker.openOutput[:produced],
						i64(transfer.written),
					)
					crypto.zero_explicit(raw_data(worker.openOutput), produced)
					if err != nil || n != produced {
						clientTransferFail(worker, transfer, "cannot write the file")
						return
					}
					transfer.written += u64(produced)
				}
				remaining = remaining[consumed:]
			}
		} else {
			n, err := os.write_at(transfer.file, inbound.data, i64(inbound.offset))
			if err != nil || n != len(inbound.data) {
				clientTransferFail(worker, transfer, "cannot write the file")
				return
			}
			transfer.written += length
		}
		sha2.update(&transfer.hash, inbound.data)
		transfer.done += length
		if !clientTransferSendPacket(
			worker,
			transfer,
			common.AttachmentPacket {
				kind = .DownloadAck,
				blobId = transfer.blobId,
				offset = inbound.offset,
			},
		) {
			clientTransferFail(worker, transfer, NOT_CONNECTED_MESSAGE)
			return
		}
		if transfer.done == transfer.size {
			if transfer.expect.set && !clientTransferDownloadChecks(transfer) {
				clientTransferFail(worker, transfer, common.ATTACHMENT_CHANGED_MESSAGE)
				return
			}
			syncOK := os.sync(transfer.file) == nil
			clientTransferClose(transfer)
			if !syncOK || os.rename(transfer.partPath, transfer.path) != nil {
				clientTransferFail(worker, transfer, "cannot save the file")
				return
			}
			transfer.state = .Finished
			transfer.fileSize = transfer.written
			clientTransferEmit(worker, transfer, .Done)
			clientTransferWipeCrypto(transfer)
		} else if time.tick_since(transfer.lastProgress) >= CLIENT_TRANSFER_PROGRESS_INTERVAL {
			clientTransferEmit(worker, transfer, .Progress)
		}
	case .Refused:
		for transfer in worker.transfers {
			if transfer.serverID != inbound.serverID || transfer.state == .Finished {
				continue
			}
			byRequest :=
				inbound.requestId != 0 &&
				transfer.direction == .Upload &&
				transfer.requestId == inbound.requestId &&
				!transfer.hasBlobId
			byBlob :=
				inbound.requestId == 0 && transfer.hasBlobId && transfer.blobId == inbound.blobId
			if byRequest || byBlob {
				clientTransferFail(worker, transfer, inbound.message)
				return
			}
		}
	}
}

// Sends an upload's next chunks while the window allows, and the finish once all are acked.
@(private = "file")
clientTransferPumpUpload :: proc(worker: ^ClientTransferWorker, transfer: ^ClientTransfer) {
	for transfer.encrypted &&
	    transfer.nextSend < transfer.size &&
	    len(transfer.unacked) < common.ATTACHMENT_WINDOW_CHUNKS {
		data, ok := clientTransferNextSealedChunk(worker, transfer)
		if !ok {
			clientTransferFail(worker, transfer, "cannot read or encrypt the file")
			return
		}
		// Kept before it is sent, so a lost connection resends exactly these bytes (D12).
		chunk := ClientTransferChunk {
			offset = transfer.nextSend,
			length = u64(len(data)),
			data   = data,
		}
		append(&transfer.unacked, chunk)
		sha2.update(&transfer.hash, data)
		transfer.nextSend += chunk.length
		if !clientTransferSendChunk(worker, transfer, chunk) {
			clientTransferFail(worker, transfer, NOT_CONNECTED_MESSAGE)
			return
		}
	}
	for !transfer.encrypted &&
	    transfer.nextSend < transfer.size &&
	    len(transfer.unacked) < common.ATTACHMENT_WINDOW_CHUNKS {
		length := min(u64(common.ATTACHMENT_CHUNK_BYTES), transfer.size - transfer.nextSend)
		n, err := os.read_at(transfer.file, worker.chunk[:length], i64(transfer.nextSend))
		if err != nil || u64(n) != length {
			clientTransferFail(worker, transfer, "cannot read the file")
			return
		}
		if !clientTransferSendPacket(
			worker,
			transfer,
			common.AttachmentPacket {
				kind = .UploadChunk,
				blobId = transfer.blobId,
				offset = transfer.nextSend,
				data = worker.chunk[:length],
			},
		) {
			clientTransferFail(worker, transfer, NOT_CONNECTED_MESSAGE)
			return
		}
		sha2.update(&transfer.hash, worker.chunk[:length])
		append(&transfer.unacked, ClientTransferChunk{offset = transfer.nextSend, length = length})
		transfer.nextSend += length
	}
	if transfer.done == transfer.size && len(transfer.unacked) == 0 {
		final: common.AttachmentSHA256
		hash := transfer.hash
		sha2.final(&hash, final[:])
		if transfer.encrypted {
			sealed, finishErr := common.AttachmentSealer_finish(&transfer.sealer)
			if finishErr != .None || sealed != final {
				clientTransferFail(worker, transfer, "cannot encrypt the file")
				return
			}
		}
		if _, sent := clientTransferSendControl(
			worker,
			transfer.serverID,
			.ClientAttachmentUploadFinish,
			common.ClientAttachmentUploadFinishPayload{blobId = transfer.blobId, sha256 = final},
		); !sent {
			clientTransferFail(worker, transfer, NOT_CONNECTED_MESSAGE)
			return
		}
		transfer.state = .Finishing
	} else if time.tick_since(transfer.lastProgress) >= CLIENT_TRANSFER_PROGRESS_INTERVAL {
		clientTransferEmit(worker, transfer, .Progress)
	}
}

// Sends one chunk of an upload on channel 5 (data borrowed).
@(private = "file")
clientTransferSendChunk :: proc(
	worker: ^ClientTransferWorker,
	transfer: ^ClientTransfer,
	chunk: ClientTransferChunk,
) -> bool {
	return clientTransferSendPacket(
		worker,
		transfer,
		common.AttachmentPacket {
			kind = .UploadChunk,
			blobId = transfer.blobId,
			offset = chunk.offset,
			data = chunk.data,
		},
	)
}

// The next wire chunk of an encrypted upload's stored bytes (owned): seals file chunks, each
// exactly once and in order, until enough sealed bytes are pending, and cuts the chunk off.
@(private = "file")
clientTransferNextSealedChunk :: proc(
	worker: ^ClientTransferWorker,
	transfer: ^ClientTransfer,
) -> (
	data: []u8,
	ok: bool,
) {
	need := int(min(u64(common.ATTACHMENT_CHUNK_BYTES), transfer.size - transfer.nextSend))
	for transfer.pendingLength < need {
		count, done := common.AttachmentSealer_nextFileBytes(&transfer.sealer)
		if done {
			return nil, false
		}
		fileBytes := worker.chunk[:count]
		if count > 0 {
			n, err := os.read_at(transfer.file, fileBytes, i64(transfer.sealer.fileBytes))
			if err != nil || n != count {
				crypto.zero_explicit(raw_data(fileBytes), count)
				return nil, false
			}
		}
		sealedLength, sealErr := common.AttachmentSealer_next(
			&transfer.sealer,
			fileBytes,
			worker.sealScratch,
			worker.sealOutput,
		)
		crypto.zero_explicit(raw_data(worker.chunk), count)
		if sealErr != .None ||
		   transfer.pendingLength + sealedLength > len(transfer.pending) {
			return nil, false
		}
		copy(transfer.pending[transfer.pendingLength:], worker.sealOutput[:sealedLength])
		transfer.pendingLength += sealedLength
	}
	data = make([]u8, need)
	copy(data, transfer.pending[:need])
	copy(transfer.pending, transfer.pending[need:transfer.pendingLength])
	transfer.pendingLength -= need
	return data, true
}

// Ready for an encrypted upload: the first one starts at 0; a resume (D9) must start at the
// first chunk still in flight (or at the next one when none is), whose sealed bytes are resent
// unchanged. Anything else cannot be resumed, since no chunk is ever sealed twice.
@(private = "file")
clientTransferResumeSealed :: proc(
	worker: ^ClientTransferWorker,
	transfer: ^ClientTransfer,
	offset: u64,
) {
	if transfer.nextSend == 0 && len(transfer.unacked) == 0 {
		if offset != 0 {
			clientTransferFail(worker, transfer, "the server reported bytes this upload never sent")
			return
		}
		sha2.init_256(&transfer.hash)
	}
	// The server may have stored chunks whose acks were lost with the session.
	for len(transfer.unacked) > 0 &&
	    transfer.unacked[0].offset + transfer.unacked[0].length <= offset {
		transfer.done += transfer.unacked[0].length
		delete(transfer.unacked[0].data)
		ordered_remove(&transfer.unacked, 0)
	}
	expected := transfer.nextSend
	if len(transfer.unacked) > 0 {
		expected = transfer.unacked[0].offset
	}
	if offset != expected || offset != transfer.done {
		clientTransferFail(
			worker,
			transfer,
			"an encrypted upload can only continue where the server stopped acknowledging it",
		)
		return
	}
	transfer.state = .Sending
	clientTransferEmit(worker, transfer, .Progress)
	for chunk in transfer.unacked {
		if !clientTransferSendChunk(worker, transfer, chunk) {
			clientTransferFail(worker, transfer, NOT_CONNECTED_MESSAGE)
			return
		}
	}
	clientTransferPumpUpload(worker, transfer)
}

// The checks a download for a message makes once every byte arrived (D2, D12): the whole
// stored blob's SHA-256 is the message's and, for an encrypted file, the last chunk was opened
// and every byte of the layout consumed.
@(private = "file")
clientTransferDownloadChecks :: proc(transfer: ^ClientTransfer) -> bool {
	if transfer.expect.encrypted {
		return common.AttachmentOpener_finish(&transfer.opener, transfer.expect.sha256) == .None
	}
	digest: common.AttachmentSHA256
	hash := transfer.hash
	sha2.final(&hash, digest[:])
	return digest == transfer.expect.sha256 && transfer.written == transfer.expect.storedSize
}

// Fails every transfer whose session is gone: the server ended its side with the session (an
// upload can be resumed with attach-resume once connected again).
@(private = "file")
clientTransferCheckSessions :: proc(worker: ^ClientTransferWorker) {
	active := false
	for transfer in worker.transfers {
		if transfer.state != .Finished {
			active = true
			break
		}
	}
	if !active {
		return
	}
	lost := make([dynamic]^ClientTransfer, context.temp_allocator)
	ClientNetworkWorker_lock(worker.network)
	for transfer in worker.transfers {
		if transfer.state == .Finished {
			continue
		}
		transport := clientTransferTransport(worker, transfer.serverID)
		if transport == nil ||
		   !ClientServerTransport_isConnected(transport) ||
		   transport.sessionGeneration != transfer.generation {
			append(&lost, transfer)
		}
	}
	ClientNetworkWorker_unlock(worker.network)
	for transfer in lost {
		clientTransferFail(worker, transfer, "connection lost")
	}
}

// Parses 32 hex characters into a blob ID.
attachmentBlobIDFromHex :: proc(text: string) -> (common.AttachmentBlobID, bool) {
	blobId: common.AttachmentBlobID
	if len(text) != 2 * common.ATTACHMENT_BLOB_ID_SIZE {
		return {}, false
	}
	ok := common.decodeHexIntoBuffer(text, blobId[:])
	return blobId, ok && common.attachmentBlobIDIsSet(blobId)
}

