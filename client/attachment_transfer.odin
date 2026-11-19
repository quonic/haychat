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
// F1 transfers plaintext bytes only; F2 adds the encrypted format (common/attachment_e2ee.odin).
// A download is written to OUT.part next to OUT and renamed when every byte arrived (D19).

import "../common"
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
}

ClientTransferEvent_deinit :: proc(event: ^ClientTransferEvent) {
	delete(event.path)
	delete(event.message)
	event.path = ""
	event.message = ""
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

@(private = "file")
ClientTransferChunk :: struct {
	offset: u64,
	length: u64,
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

// Uploads path to a room (roomID) or a direct conversation (recipientUserID). Returns the local
// transfer ID that its events carry.
ClientTransferWorker_upload :: proc(
	worker: ^ClientTransferWorker,
	serverID, roomID, recipientUserID: int,
	path: string,
) -> int {
	return clientTransferQueue(
		worker,
		ClientTransferCommand {
			kind = .Upload,
			serverID = serverID,
			roomID = roomID,
			recipientUserID = recipientUserID,
			path = strings.clone(path),
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
	delete(transfer.unacked)
	free(transfer)
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
	}
	if kind == .Done {
		hash := transfer.hash
		sha2.final(&hash, event.sha256[:])
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
		if sizeErr != nil || size <= 0 {
			clientTransferFail(worker, transfer, "the file is empty or unreadable")
			return
		}
		transfer.size = u64(size)
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
		clear(&transfer.unacked)
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
		// The running hash covers every byte from the start: rebuild it up to the server's
		// offset on a resume (D9; F1 never re-encrypts, nothing is encrypted yet).
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
			return
		}
		clientTransferEmit(worker, transfer, .Done)
	case .DownloadBegin:
		transfer := clientTransferFind(worker, inbound.serverID, inbound.blobId, .Download, true)
		if transfer == nil || transfer.state != .Beginning {
			return
		}
		if inbound.offset != 0 || inbound.size == 0 {
			clientTransferFail(worker, transfer, "unexpected download start")
			return
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
		n, err := os.write_at(transfer.file, inbound.data, i64(inbound.offset))
		if err != nil || n != len(inbound.data) {
			clientTransferFail(worker, transfer, "cannot write the file")
			return
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
			syncOK := os.sync(transfer.file) == nil
			clientTransferClose(transfer)
			if !syncOK || os.rename(transfer.partPath, transfer.path) != nil {
				clientTransferFail(worker, transfer, "cannot save the file")
				return
			}
			transfer.state = .Finished
			clientTransferEmit(worker, transfer, .Done)
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
	for transfer.nextSend < transfer.size &&
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

