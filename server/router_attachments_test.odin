package server

import "../common"
import "core:encoding/cbor"
import "core:fmt"
import "core:sync"
import "core:testing"
import "core:time"

// Router tests for attachment transfers (protocol 26, router_attachments.odin): the begin
// checks the router makes itself, the D8 caps and window, acknowledgements on channel 5, and
// what a session's end does. The database and the storage worker are answered by hand.

@(private = "file")
attachTestSend :: proc(
	h: ^RouterTestHarness,
	transport: ^common.TransportState,
	peerID: u32,
	messageType: common.MessageType,
	payload: any,
) {
	sealed, ok := common.sealPacketForSession(transport, messageType, payload)
	assert(ok, "expected the client to seal its request")
	defer delete(sealed.payload)
	bytes := routerEncodePacketBytes(sealed)
	defer delete(bytes)
	MainRouterState_handleNetworkDataReceived(
		&h.pm,
		&h.state,
		NetworkDataReceived{peerId = peerID, channel = .Chat, data = bytes},
	)
}

@(private = "file")
attachTestRefusal :: proc(
	h: ^RouterTestHarness,
	transport: ^common.TransportState,
	expected: string,
) -> common.ServerAttachmentRefusedPayload {
	packet := routerTestOpenInnerPacket(h, transport)
	defer delete(packet.payload)
	assert(
		packet.messageType == .ServerAttachmentRefused,
		fmt.tprintf("expected ServerAttachmentRefused (%q), got %v", expected, packet.messageType),
	)
	refused: common.ServerAttachmentRefusedPayload
	assert(
		cbor.unmarshal(packet.payload, &refused, temp_allocator = context.allocator) == nil,
		"expected the refusal to decode",
	)
	defer common.ServerAttachmentRefusedPayload_deinit(&refused)
	assert(
		refused.message == expected,
		fmt.tprintf("expected the refusal %q, got %q", expected, refused.message),
	)
	result := refused
	result.message = ""
	return result
}

@(private = "file")
attachTestPollStorage :: proc(h: ^RouterTestHarness) -> StorageCommand {
	msg, err := IPC_Client_poll(h.pm.config.storageFd)
	assert(err == nil, "expected a queued storage command")
	command, ok := msg.(StorageCommand)
	assert(ok, fmt.tprintf("expected a StorageCommand, got %v", msg))
	return command
}

@(private = "file")
attachTestExpectNoStorage :: proc(h: ^RouterTestHarness, why: string) {
	_, err := IPC_Client_poll(h.pm.config.storageFd)
	assert(err != nil, why)
}

@(private = "file")
attachTestBegin :: proc(
	h: ^RouterTestHarness,
	transport: ^common.TransportState,
	peerID: u32,
	requestId: u32,
	size: u64,
	roomId := 1,
	recipientUserId := 0,
) {
	attachTestSend(
		h,
		transport,
		peerID,
		.ClientAttachmentUploadBegin,
		common.ClientAttachmentUploadBeginPayload {
			requestId = requestId,
			roomId = roomId,
			recipientUserId = recipientUserId,
			size = size,
		},
	)
}

// Begins an upload and answers the database and the storage worker, up to Ready.
@(private = "file")
attachTestReadyUpload :: proc(
	h: ^RouterTestHarness,
	transport: ^common.TransportState,
	peerID: u32,
	size: u64,
) -> common.AttachmentBlobID {
	attachTestBegin(h, transport, peerID, 7, size)
	query := routerPollDatabaseQuery(h)
	request, ok := query.request.(common.DatabaseAttachmentRequest)
	assert(ok && request.action == .Begin, "expected the begin statement")
	assert(
		request.userId == 42 && request.roomId == 1 && request.size == size,
		fmt.tprintf("expected the begin for user 42 in room 1, got %v", request),
	)
	assert(common.attachmentBlobIDIsSet(request.blobId), "expected a random blob ID")
	blobId := request.blobId
	IPC__database_query_request_deinit(query.request)
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		query.request_id,
		common.DatabaseQueryResponse {
			success = true,
			result = common.DatabaseAttachmentResult {
				action = .Begin,
				outcome = .Applied,
				size = size,
			},
		},
	)
	open := attachTestPollStorage(h)
	openRequest, openOK := open.request.(StorageUploadOpen)
	assert(openOK && openRequest.blobId == blobId && !openRequest.resume, "expected a new file")
	MainRouterState_handleStorageResponse(
		&h.pm,
		&h.state,
		StorageResponse {
			requestId = open.requestId,
			result = StorageUploadOpened{blobId = blobId, ok = true},
		},
	)
	packet := routerTestOpenInnerPacket(h, transport)
	defer delete(packet.payload)
	assert(packet.messageType == .ServerAttachmentUploadReady, "expected Ready")
	ready: common.ServerAttachmentUploadReadyPayload
	assert(
		cbor.unmarshal(packet.payload, &ready, temp_allocator = context.allocator) == nil,
		"expected Ready to decode",
	)
	assert(
		ready.requestId == 7 &&
		ready.blobId == blobId &&
		ready.received == 0 &&
		ready.chunkBytes == common.ATTACHMENT_CHUNK_BYTES &&
		ready.windowChunks == common.ATTACHMENT_WINDOW_CHUNKS,
		fmt.tprintf("expected Ready for the new blob, got %v", ready),
	)
	return blobId
}

@(private = "file")
attachTestChunk :: proc(
	h: ^RouterTestHarness,
	transport: ^common.TransportState,
	peerID: u32,
	kind: common.AttachmentPacketKind,
	blobId: common.AttachmentBlobID,
	offset: u64,
	data: []u8,
) {
	plain := make([]u8, common.ATTACHMENT_PACKET_MAX_SIZE)
	defer delete(plain)
	n, ok := common.encodeAttachmentPacket(
		common.AttachmentPacket{kind = kind, blobId = blobId, offset = offset, data = data},
		plain,
	)
	assert(ok, "expected the chunk to encode")
	sealed := make([]u8, n + common.FILE_PACKET_OVERHEAD)
	defer delete(sealed)
	length, sealOK := common.sealFilePacket(
		&transport.fileSend,
		transport.sessionID,
		plain[:n],
		sealed,
	)
	assert(sealOK, "expected the client to seal the chunk")
	MainRouterState_handleNetworkDataReceived(
		&h.pm,
		&h.state,
		NetworkDataReceived{peerId = peerID, channel = .FileTransfer, data = sealed[:length]},
	)
}

@(private = "file")
attachTestReceiveFilePacket :: proc(
	h: ^RouterTestHarness,
	transport: ^common.TransportState,
) -> (
	packet: common.AttachmentPacket,
	data: [dynamic]u8,
) {
	send := routerPollNetworkSend(h)
	defer delete(send.data)
	assert(send.channel == .FileTransfer, fmt.tprintf("expected channel 5, got %v", send.channel))
	plain := make([]u8, len(send.data))
	defer delete(plain)
	n, result := common.openFilePacket(
		&transport.fileReceive,
		transport.sessionID,
		send.data,
		plain,
	)
	assert(result == .Ok, fmt.tprintf("expected the client to open it, got %v", result))
	decoded, decodeResult := common.decodeAttachmentPacket(plain[:n])
	assert(decodeResult == .Ok, "expected an attachment packet")
	data = make([dynamic]u8, len(decoded.data))
	copy(data[:], decoded.data)
	decoded.data = nil
	return decoded, data
}

@(private = "file")
attachTestHarness :: proc() -> RouterTestHarness {
	h := routerTestHarness_init()
	h.pm.config.attachmentsEnabled = true
	h.pm.config.attachmentMaxBytes = DEFAULT_ATTACHMENT_MAX_BYTES
	h.pm.config.attachmentSessionBytesPerSecond = DEFAULT_ATTACHMENT_SESSION_BYTES_PER_SECOND
	h.pm.config.attachmentPendingHours = DEFAULT_ATTACHMENT_PENDING_HOURS
	return h
}

@(test)
testRouterAttachmentBeginChecksShapeLimitsAndTheUploadCap :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := attachTestHarness()
	defer routerTestHarness_deinit(&h)
	peerID := u32(1)
	transport := routerCompleteHandshake(&h, peerID)

	for bad in ([]struct {
			room, recipient: int,
			size:            u64,
			message:         string,
		} {
			{1, 3, 10, common.ATTACHMENT_INVALID_REQUEST_MESSAGE},
			{0, 0, 10, common.ATTACHMENT_INVALID_REQUEST_MESSAGE},
			{0, 42, 10, common.ATTACHMENT_INVALID_REQUEST_MESSAGE},
			{1, 0, 0, common.ATTACHMENT_INVALID_REQUEST_MESSAGE},
			{1, 0, u64(DEFAULT_ATTACHMENT_MAX_BYTES) + 1, common.ATTACHMENT_TOO_LARGE_MESSAGE},
		}) {
		attachTestBegin(&h, &transport, peerID, 9, bad.size, bad.room, bad.recipient)
		refused := attachTestRefusal(&h, &transport, bad.message)
		assert(refused.requestId == 9, "expected the refusal to name the request")
	}
	routerTestExpectNoDatabaseQuery(&h, "expected no refused begin to reach the database")

	// Two uploads at once (D8); the third is refused before the database.
	for requestId in u32(1) ..= 2 {
		attachTestBegin(&h, &transport, peerID, requestId, 1000)
		query := routerPollDatabaseQuery(&h)
		IPC__database_query_request_deinit(query.request)
	}
	attachTestBegin(&h, &transport, peerID, 3, 1000)
	attachTestRefusal(&h, &transport, common.ATTACHMENT_TOO_MANY_UPLOADS_MESSAGE)
	routerTestExpectNoDatabaseQuery(&h, "expected the third upload refused by the router")

	h.pm.config.attachmentsEnabled = false
	attachTestBegin(&h, &transport, peerID, 4, 1000)
	attachTestRefusal(&h, &transport, common.ATTACHMENTS_DISABLED_MESSAGE)
}

@(test)
testRouterAttachmentBeginRefusalsComeFromTheDatabase :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := attachTestHarness()
	defer routerTestHarness_deinit(&h)
	peerID := u32(1)
	transport := routerCompleteHandshake(&h, peerID)

	cases := []struct {
		outcome: common.DatabaseAttachmentOutcome,
		message: string,
	} {
		{.NotMember, common.ATTACHMENT_NOT_MEMBER_MESSAGE},
		{.SendDenied, common.ROOM_SEND_NOT_PERMITTED_MESSAGE},
		{.QuotaExceeded, common.ATTACHMENT_QUOTA_MESSAGE},
		{.RateExceeded, common.ATTACHMENT_RATE_MESSAGE},
		{.CapacityExceeded, common.ATTACHMENT_STORAGE_FULL_MESSAGE},
		{.Restricted, common.DIRECT_MESSAGE_RESTRICTED_MESSAGE},
	}
	for c in cases {
		attachTestBegin(&h, &transport, peerID, 11, 1000)
		query := routerPollDatabaseQuery(&h)
		IPC__database_query_request_deinit(query.request)
		MainRouterState_handleDatabaseResult(
			&h.pm,
			&h.state,
			query.request_id,
			common.DatabaseQueryResponse {
				success = true,
				result = common.DatabaseAttachmentResult{action = .Begin, outcome = c.outcome},
			},
		)
		attachTestRefusal(&h, &transport, c.message)
		attachTestExpectNoStorage(&h, "expected a refused begin to open no file")
	}

	// The free-disk reserve: the storage worker refuses, the row is deleted again.
	attachTestBegin(&h, &transport, peerID, 12, 1000)
	query := routerPollDatabaseQuery(&h)
	blobId := query.request.(common.DatabaseAttachmentRequest).blobId
	IPC__database_query_request_deinit(query.request)
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		query.request_id,
		common.DatabaseQueryResponse {
			success = true,
			result = common.DatabaseAttachmentResult{action = .Begin, outcome = .Applied},
		},
	)
	open := attachTestPollStorage(&h)
	MainRouterState_handleStorageResponse(
		&h.pm,
		&h.state,
		StorageResponse {
			requestId = open.requestId,
			result = StorageUploadOpened{blobId = blobId, full = true},
		},
	)
	deleteQuery := routerPollDatabaseQuery(&h)
	deleteRequest := deleteQuery.request.(common.DatabaseAttachmentRequest)
	assert(
		deleteRequest.action == .DeleteNew && deleteRequest.blobId == blobId,
		"expected the unwritten row deleted",
	)
	IPC__database_query_request_deinit(deleteQuery.request)
	attachTestRefusal(&h, &transport, common.ATTACHMENT_STORAGE_FULL_MESSAGE)
}

@(test)
testRouterAttachmentUploadKeepsTheWindowAndAcksWrittenChunks :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := attachTestHarness()
	defer routerTestHarness_deinit(&h)
	peerID := u32(1)
	transport := routerCompleteHandshake(&h, peerID)
	size := u64(12 * common.ATTACHMENT_CHUNK_BYTES)
	blobId := attachTestReadyUpload(&h, &transport, peerID, size)

	chunk := make([]u8, common.ATTACHMENT_CHUNK_BYTES)
	defer delete(chunk)
	for index in 0 ..< len(chunk) {
		chunk[index] = u8(index)
	}
	// A full window goes to the storage worker in order; nothing is acknowledged yet.
	writes: [common.ATTACHMENT_WINDOW_CHUNKS]StorageCommand
	for index in 0 ..< common.ATTACHMENT_WINDOW_CHUNKS {
		offset := u64(index * common.ATTACHMENT_CHUNK_BYTES)
		attachTestChunk(&h, &transport, peerID, .UploadChunk, blobId, offset, chunk)
		writes[index] = attachTestPollStorage(&h)
		write, ok := writes[index].request.(StorageUploadWrite)
		assert(
			ok && write.blobId == blobId && write.offset == offset && len(write.data) == len(chunk),
			fmt.tprintf("expected chunk %d handed to the storage worker, got %v", index, write),
		)
	}
	routerTestExpectNoNetworkMessage(&h, "expected no ack before the storage worker wrote")

	// Written: the router acknowledges each chunk on channel 5.
	for index in 0 ..< 2 {
		write := writes[index].request.(StorageUploadWrite)
		MainRouterState_handleStorageResponse(
			&h.pm,
			&h.state,
			StorageResponse {
				requestId = writes[index].requestId,
				result = StorageUploadWritten {
					blobId = blobId,
					offset = write.offset,
					length = len(write.data),
					ok = true,
				},
			},
		)
		ack, data := attachTestReceiveFilePacket(&h, &transport)
		delete(data)
		assert(
			ack.kind == .UploadAck && ack.blobId == blobId && ack.offset == write.offset,
			fmt.tprintf("expected the ack of chunk %d, got %v", index, ack),
		)
	}
	// Two slots are free again: chunks 8 and 9 fit, chunk 10 overflows the window.
	for index in 8 ..< 10 {
		attachTestChunk(
			&h,
			&transport,
			peerID,
			.UploadChunk,
			blobId,
			u64(index * len(chunk)),
			chunk,
		)
		command := attachTestPollStorage(&h)
		StorageRequest_deinit(command.request)
	}
	attachTestChunk(&h, &transport, peerID, .UploadChunk, blobId, u64(10 * len(chunk)), chunk)
	refused := attachTestRefusal(&h, &transport, common.ATTACHMENT_FLOW_MESSAGE)
	assert(refused.blobId == blobId, "expected the refusal to name the blob")
	closeCommand := attachTestPollStorage(&h)
	closeRequest, closeOK := closeCommand.request.(StorageUploadClose)
	assert(
		closeOK && closeRequest.blobId == blobId && !closeRequest.discard,
		"expected the part file closed and kept for a resume",
	)
	// The aborted upload recorded the two chunks that were written.
	progress := routerPollDatabaseQuery(&h)
	progressRequest := progress.request.(common.DatabaseAttachmentRequest)
	assert(
		progressRequest.action == .Progress && progressRequest.size == u64(2 * len(chunk)),
		fmt.tprintf("expected the progress recorded, got %v", progressRequest),
	)
	IPC__database_query_request_deinit(progress.request)
	for index in 0 ..< len(writes) {
		StorageRequest_deinit(writes[index].request)
	}
	_, active := h.state.attachments.uploads[blobId]
	assert(!active, "expected the transfer gone")
}

@(test)
testRouterAttachmentUploadRefusesOutOfOrderChunksAndAnEarlyFinish :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := attachTestHarness()
	defer routerTestHarness_deinit(&h)
	peerID := u32(1)
	transport := routerCompleteHandshake(&h, peerID)
	blobId := attachTestReadyUpload(&h, &transport, peerID, 100)

	attachTestSend(
		&h,
		&transport,
		peerID,
		.ClientAttachmentUploadFinish,
		common.ClientAttachmentUploadFinishPayload{blobId = blobId},
	)
	attachTestRefusal(&h, &transport, common.ATTACHMENT_INCOMPLETE_MESSAGE)

	data := [?]u8{1, 2, 3}
	attachTestChunk(&h, &transport, peerID, .UploadChunk, blobId, 50, data[:])
	attachTestRefusal(&h, &transport, common.ATTACHMENT_FLOW_MESSAGE)
	closeCommand := attachTestPollStorage(&h)
	_, closeOK := closeCommand.request.(StorageUploadClose)
	assert(closeOK, "expected the upload's file closed")

	// A chunk for a blob without a transfer is refused; an upload ack from a client ends the
	// session.
	attachTestChunk(&h, &transport, peerID, .UploadChunk, blobId, 0, data[:])
	attachTestRefusal(&h, &transport, common.ATTACHMENT_NOT_FOUND_MESSAGE)
	attachTestChunk(&h, &transport, peerID, .UploadAck, blobId, 0, nil)
	protocolError := routerTestOpenInnerPacket(&h, &transport)
	delete(protocolError.payload)
	assert(protocolError.messageType == .ServerProtocolError, "expected a protocol violation")
	disconnect := routerPollDisconnect(&h)
	assert(disconnect.peerId == peerID, "expected the session ended")
}

@(test)
testRouterAttachmentDownloadCapAndWindow :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := attachTestHarness()
	defer routerTestHarness_deinit(&h)
	peerID := u32(1)
	transport := routerCompleteHandshake(&h, peerID)

	queries: [common.ATTACHMENT_DOWNLOADS_PER_SESSION_MAX]DatabaseQuery
	for index in 0 ..< len(queries) {
		blobId: common.AttachmentBlobID
		blobId[0] = u8(index + 1)
		attachTestSend(
			&h,
			&transport,
			peerID,
			.ClientAttachmentDownload,
			common.ClientAttachmentDownloadPayload{blobId = blobId},
		)
		queries[index] = routerPollDatabaseQuery(&h)
		request := queries[index].request.(common.DatabaseAttachmentRequest)
		assert(request.action == .DownloadCheck && request.userId == 42, "expected a check")
	}
	fifth: common.AttachmentBlobID
	fifth[0] = 9
	attachTestSend(
		&h,
		&transport,
		peerID,
		.ClientAttachmentDownload,
		common.ClientAttachmentDownloadPayload{blobId = fifth},
	)
	attachTestRefusal(&h, &transport, common.ATTACHMENT_TOO_MANY_DOWNLOADS_MESSAGE)

	// The first is the owner's 20-chunk blob: Begin, then a window of reads, no more.
	size := u64(20 * common.ATTACHMENT_CHUNK_BYTES)
	first := queries[0].request.(common.DatabaseAttachmentRequest).blobId
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		queries[0].request_id,
		common.DatabaseQueryResponse {
			success = true,
			result = common.DatabaseAttachmentResult {
				action = .DownloadCheck,
				outcome = .Applied,
				size = size,
			},
		},
	)
	begin := routerTestOpenInnerPacket(&h, &transport)
	delete(begin.payload)
	assert(begin.messageType == .ServerAttachmentDownloadBegin, "expected DownloadBegin")
	reads: [common.ATTACHMENT_WINDOW_CHUNKS]StorageCommand
	for index in 0 ..< len(reads) {
		reads[index] = attachTestPollStorage(&h)
		read, ok := reads[index].request.(StorageRead)
		assert(
			ok && read.offset == u64(index * common.ATTACHMENT_CHUNK_BYTES),
			fmt.tprintf("expected read %d, got %v", index, reads[index].request),
		)
	}
	MainRouterState_attachmentsTick(&h.pm, &h.state, time.tick_now())
	// The tick also starts the startup scan and the sweeper; nothing else may be read.
	scan := attachTestPollStorage(&h)
	_, scanOK := scan.request.(StorageScan)
	assert(scanOK, "expected the startup scan")
	sweep := routerPollDatabaseQuery(&h)
	assert(sweep.request.(common.DatabaseAttachmentRequest).action == .Sweep, "expected a sweep")
	assert(
		len(sweep.request.(common.DatabaseAttachmentRequest).blobIds) == 1,
		"expected the live download excluded from the sweep",
	)
	IPC__database_query_request_deinit(sweep.request)
	attachTestExpectNoStorage(&h, "expected the window to hold further reads")

	// A chunk read is sealed and sent; its ack frees one slot.
	chunk := make([]u8, common.ATTACHMENT_CHUNK_BYTES)
	MainRouterState_handleStorageResponse(
		&h.pm,
		&h.state,
		StorageResponse {
			requestId = reads[0].requestId,
			result = StorageReadData{blobId = first, offset = 0, data = chunk, ok = true},
		},
	)
	sent, sentData := attachTestReceiveFilePacket(&h, &transport)
	assert(
		sent.kind == .DownloadChunk && sent.offset == 0 && len(sentData) == len(chunk),
		"expected the first chunk sent",
	)
	delete(sentData)
	attachTestChunk(&h, &transport, peerID, .DownloadAck, first, 0, nil)
	next := attachTestPollStorage(&h)
	nextRead := next.request.(StorageRead)
	assert(
		nextRead.offset == u64(8 * common.ATTACHMENT_CHUNK_BYTES),
		"expected the ack to let the ninth read go",
	)
	// An ack out of order ends the download.
	attachTestChunk(&h, &transport, peerID, .DownloadAck, first, 999, nil)
	attachTestRefusal(&h, &transport, common.ATTACHMENT_FLOW_MESSAGE)
	for index in 1 ..< len(queries) {
		IPC__database_query_request_deinit(queries[index].request)
	}
}

@(test)
testRouterAttachmentSessionEndKeepsUploadsResumable :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := attachTestHarness()
	defer routerTestHarness_deinit(&h)
	peerID := u32(1)
	transport := routerCompleteHandshake(&h, peerID)
	blobId := attachTestReadyUpload(&h, &transport, peerID, 100)

	MainRouterState_handlePeerDisconnected(&h.pm, &h.state, peerID)
	closeCommand := attachTestPollStorage(&h)
	closeRequest, ok := closeCommand.request.(StorageUploadClose)
	assert(ok && closeRequest.blobId == blobId && !closeRequest.discard, "expected a kept part")
	_, active := h.state.attachments.uploads[blobId]
	assert(!active, "expected the transfer ended with the session")
	_, channel := h.state.attachments.channels[peerID]
	assert(!channel, "expected the session's file keys wiped")
}
