package server

import "../common"
import "core:encoding/cbor"
import "core:fmt"
import "core:sync"
import "core:testing"

// Router tests for attachment moderation (protocol 28, router_attachment_moderation.odin): what
// the router sends once the database decided. Who may read a message is the removal statement's
// (database_attachments_test.odin); here the readers come from its result, and the test checks
// that exactly their sessions hear of it, that active downloads end, and that the file goes.

@(private = "file")
ModTestMessage :: struct {
	peerID: u32,
	packet: common.Packet, // payload owned
}

// Every queued network message, opened with its peer's transport, presence notices skipped.
@(private = "file")
modTestDrain :: proc(h: ^RouterTestHarness, peers: []RouterTestPeer) -> [dynamic]ModTestMessage {
	messages := make([dynamic]ModTestMessage)
	for {
		msg, err := IPC_Client_poll(h.networkFd)
		if err != nil {
			break
		}
		send, isSend := msg.(NetworkSendData)
		if !isSend {
			IPC__message_deinit(&msg)
			continue
		}
		outer := routerDecodePacketBytes(send.data)
		delete(send.data)
		opened := false
		for peer in peers {
			if peer.peerID != send.peerId {
				continue
			}
			packet, ok := common.openPacketForSession(peer.transport, outer)
			assert(ok, fmt.tprintf("expected peer %d to open its message", send.peerId))
			opened = true
			if packet.messageType == .ServerUserPresence {
				delete(packet.payload)
			} else {
				append(&messages, ModTestMessage{peerID = send.peerId, packet = packet})
			}
		}
		delete(outer.payload)
		assert(opened, fmt.tprintf("expected no message for peer %d", send.peerId))
	}
	return messages
}

@(private = "file")
modTestFree :: proc(messages: ^[dynamic]ModTestMessage) {
	for message in messages {
		delete(message.packet.payload)
	}
	delete(messages^)
}

@(private = "file")
modTestCount :: proc(
	messages: []ModTestMessage,
	peerID: u32,
	messageType: common.MessageType,
) -> int {
	count := 0
	for message in messages {
		if message.peerID == peerID && message.packet.messageType == messageType {
			count += 1
		}
	}
	return count
}

@(private = "file")
modTestFind :: proc(
	messages: []ModTestMessage,
	peerID: u32,
	messageType: common.MessageType,
) -> []u8 {
	for message in messages {
		if message.peerID == peerID && message.packet.messageType == messageType {
			return message.packet.payload
		}
	}
	assert(false, fmt.tprintf("expected %v for peer %d", messageType, peerID))
	return nil
}

@(private = "file")
modTestHarness :: proc() -> RouterTestHarness {
	h := routerTestHarness_init()
	h.pm.config.attachmentsEnabled = true
	h.pm.config.attachmentMaxBytes = DEFAULT_ATTACHMENT_MAX_BYTES
	h.pm.config.attachmentSessionBytesPerSecond = DEFAULT_ATTACHMENT_SESSION_BYTES_PER_SECOND
	h.pm.config.attachmentPendingHours = DEFAULT_ATTACHMENT_PENDING_HOURS
	return h
}

@(private = "file")
modTestPollStorage :: proc(h: ^RouterTestHarness) -> StorageCommand {
	msg, err := IPC_Client_poll(h.pm.config.storageFd)
	assert(err == nil, "expected a queued storage command")
	command, ok := msg.(StorageCommand)
	assert(ok, fmt.tprintf("expected a StorageCommand, got %v", msg))
	return command
}

@(private = "file")
modTestExpectNoStorage :: proc(h: ^RouterTestHarness, why: string) {
	_, err := IPC_Client_poll(h.pm.config.storageFd)
	assert(err != nil, why)
}

@(private = "file")
modTestBlob :: proc(fill: u8) -> common.AttachmentBlobID {
	blobId: common.AttachmentBlobID
	for index in 0 ..< len(blobId) {
		blobId[index] = fill + u8(index)
	}
	return blobId
}

// Starts a download of blobId by peerID and answers its check, up to the first reads.
@(private = "file")
modTestStartDownload :: proc(
	h: ^RouterTestHarness,
	peers: []RouterTestPeer,
	transport: ^common.TransportState,
	peerID: u32,
	blobId: common.AttachmentBlobID,
) {
	routerTestSendSealed(
		h,
		transport,
		peerID,
		.ClientAttachmentDownload,
		common.ClientAttachmentDownloadPayload{blobId = blobId},
	)
	query := routerPollDatabaseQuery(h)
	request := query.request.(common.DatabaseAttachmentRequest)
	assert(request.action == .DownloadCheck, "expected the download check")
	IPC__database_query_request_deinit(query.request)
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		query.request_id,
		common.DatabaseQueryResponse {
			success = true,
			result = common.DatabaseAttachmentResult {
				action = .DownloadCheck,
				outcome = .Applied,
				size = u64(4 * common.ATTACHMENT_CHUNK_BYTES),
			},
		},
	)
	messages := modTestDrain(h, peers)
	defer modTestFree(&messages)
	assert(
		modTestCount(messages[:], peerID, .ServerAttachmentDownloadBegin) == 1,
		"expected DownloadBegin",
	)
	for _ in 0 ..< 4 {
		read := modTestPollStorage(h)
		_, ok := read.request.(StorageRead)
		assert(ok, fmt.tprintf("expected a chunk read, got %v", read.request))
	}
}

// Answers the removal statement for blobId with removal (readers cloned).
@(private = "file")
modTestAnswerRemove :: proc(
	h: ^RouterTestHarness,
	requestID: u64,
	outcome: common.DatabaseAttachmentOutcome,
	removal: common.DatabaseAttachmentRemoval,
	readers: []int,
) {
	answered := removal
	answered.readerUserIds = make([dynamic]int, 0, len(readers))
	append(&answered.readerUserIds, ..readers)
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		requestID,
		common.DatabaseQueryResponse {
			success = true,
			result = common.DatabaseAttachmentResult {
				action = .Remove,
				outcome = outcome,
				removal = answered,
			},
		},
	)
}

// D22: the removal reaches every session of exactly the accounts the statement names as
// readers, ends their active downloads with "Attachment removed by an admin", deletes the file,
// and answers the admin; a bystander hears nothing.
@(test)
testRouterAttachmentRemovalFansOutToReadersAndEndsDownloads :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := modTestHarness()
	defer routerTestHarness_deinit(&h)

	adminPeer, bobPeer, bobSecondPeer, carolPeer := u32(1), u32(2), u32(3), u32(4)
	for peerID in ([]u32{bobPeer, bobSecondPeer, carolPeer}) {
		h.state.connectedPeers[peerID] = true
	}
	adminTransport := routerCompleteHandshake(&h, adminPeer, 42, isAdmin = true)
	peers := [?]RouterTestPeer {
		{adminPeer, &adminTransport},
		{bobPeer, nil},
		{bobSecondPeer, nil},
		{carolPeer, nil},
	}
	// Each new account's presence goes out before the next handshake's ServerHello.
	bobTransport := routerCompleteHandshake(&h, bobPeer, 43)
	peers[1].transport = &bobTransport
	skipped := modTestDrain(&h, peers[:])
	modTestFree(&skipped)
	bobSecondTransport := routerCompleteHandshake(&h, bobSecondPeer, 43)
	peers[2].transport = &bobSecondTransport
	carolTransport := routerCompleteHandshake(&h, carolPeer, 44)
	peers[3].transport = &carolTransport
	skipped = modTestDrain(&h, peers[:])
	modTestFree(&skipped)

	blobId := modTestBlob(0x30)
	modTestStartDownload(&h, peers[:], &bobTransport, bobPeer, blobId)

	routerTestSendSealed(
		&h,
		&adminTransport,
		adminPeer,
		.ClientAdminRemoveAttachment,
		common.ClientAdminRemoveAttachmentPayload{blobId = blobId, reason = "spam"},
	)
	query := routerPollDatabaseQuery(&h)
	request, ok := query.request.(common.DatabaseAttachmentRequest)
	assert(
		ok && request.action == .Remove && request.userId == 42 && request.blobId == blobId,
		fmt.tprintf("expected the removal statement for admin 42, got %v", query.request),
	)
	IPC__database_query_request_deinit(query.request)
	modTestAnswerRemove(
		&h,
		query.request_id,
		.Applied,
		common.DatabaseAttachmentRemoval{ownerUserId = 43, roomId = 1, senderId = 43},
		{43, 77},
	)

	deleteCommand := modTestPollStorage(&h)
	deleteRequest, deleteOK := deleteCommand.request.(StorageDeleteBlobs)
	assert(
		deleteOK && len(deleteRequest.blobs) == 1 && deleteRequest.blobs[0].blobId == blobId,
		fmt.tprintf("expected the file deleted, got %v", deleteCommand.request),
	)
	StorageRequest_deinit(deleteCommand.request)
	modTestExpectNoStorage(&h, "expected nothing else for the storage worker")

	messages := modTestDrain(&h, peers[:])
	defer modTestFree(&messages)
	refusal: common.ServerAttachmentRefusedPayload
	assert(
		cbor.unmarshal(
			modTestFind(messages[:], bobPeer, .ServerAttachmentRefused),
			&refusal,
			temp_allocator = context.allocator,
		) ==
		nil,
		"expected the refusal to decode",
	)
	defer common.ServerAttachmentRefusedPayload_deinit(&refusal)
	assert(
		refusal.blobId == blobId && refusal.message == common.ATTACHMENT_REMOVED_MESSAGE,
		fmt.tprintf("expected the download ended as removed, got %v", refusal),
	)
	for peerID in ([]u32{bobPeer, bobSecondPeer}) {
		notice: common.ServerAttachmentRemovedPayload
		assert(
			cbor.unmarshal(
				modTestFind(messages[:], peerID, .ServerAttachmentRemoved),
				&notice,
				temp_allocator = context.allocator,
			) ==
			nil,
			"expected the notice to decode",
		)
		assert(
			notice.blobId == blobId &&
			notice.roomId == 1 &&
			notice.senderId == 43 &&
			notice.recipientId == 0,
			fmt.tprintf("expected the room notice for peer %d, got %v", peerID, notice),
		)
	}
	result: common.ServerAdminActionResultPayload
	assert(
		cbor.unmarshal(
			modTestFind(messages[:], adminPeer, .ServerAdminActionResult),
			&result,
			temp_allocator = context.allocator,
		) ==
		nil,
		"expected the admin result to decode",
	)
	defer common.ServerAdminActionResultPayload_deinit(&result)
	assert(
		result.action == .RemoveAttachment && result.userId == 43 && result.blobId == blobId,
		fmt.tprintf("expected the removal answered with the owner, got %v", result),
	)
	assert(
		modTestCount(messages[:], adminPeer, .ServerAttachmentRemoved) == 0,
		"expected the admin, not a reader, to hear no notice",
	)
	assert(
		modTestCount(messages[:], carolPeer, .ServerAttachmentRemoved) == 0 &&
		modTestCount(messages[:], carolPeer, .ServerAttachmentRefused) == 0,
		"expected the bystander to hear nothing",
	)
	assert(len(messages) == 4, fmt.tprintf("expected 4 messages, got %d", len(messages)))
	assert(len(h.state.attachments.downloads) == 0, "expected the download gone")

	// A chunk the storage worker read before the delete reaches nobody.
	for requestID, pending in h.state.attachments.pending {
		if pending.kind != .Read {
			continue
		}
		MainRouterState_handleStorageResponse(
			&h.pm,
			&h.state,
			StorageResponse {
				requestId = requestID,
				result = StorageReadData {
					blobId = blobId,
					data = make([]u8, common.ATTACHMENT_CHUNK_BYTES),
					ok = true,
				},
			},
		)
		break
	}
	routerTestExpectNoNetworkMessage(&h, "expected a late chunk of a removed blob dropped")
}

// Only an admin may remove (the statement decides): not_admin and not_found change nothing on
// disk and answer with a protocol error; a bad reason never reaches the database.
@(test)
testRouterAttachmentRemovalRefusals :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := modTestHarness()
	defer routerTestHarness_deinit(&h)
	peerID := u32(1)
	transport := routerCompleteHandshake(&h, peerID, 42)
	peers := [?]RouterTestPeer{{peerID, &transport}}
	blobId := modTestBlob(0x40)

	cases := [?]struct {
		outcome:  common.DatabaseAttachmentOutcome,
		expected: string,
	} {
		{.NotAdmin, "Admin permission required"},
		{.NotFound, common.ATTACHMENT_NOT_FOUND_MESSAGE},
	}
	for c in cases {
		routerTestSendSealed(
			&h,
			&transport,
			peerID,
			.ClientAdminRemoveAttachment,
			common.ClientAdminRemoveAttachmentPayload{blobId = blobId},
		)
		query := routerPollDatabaseQuery(&h)
		IPC__database_query_request_deinit(query.request)
		modTestAnswerRemove(&h, query.request_id, c.outcome, {}, nil)
		routerTestExpectProtocolError(&h, peers[:], c.expected)
		modTestExpectNoStorage(&h, fmt.tprintf("expected no file deleted for %v", c.outcome))
	}

	tooLong := make([]u8, common.ATTACHMENT_REMOVE_REASON_MAX_BYTES + 1)
	defer delete(tooLong)
	for &b in tooLong {
		b = 'r'
	}
	for reason in ([]string{string(tooLong), "two\nlines"}) {
		routerTestSendSealed(
			&h,
			&transport,
			peerID,
			.ClientAdminRemoveAttachment,
			common.ClientAdminRemoveAttachmentPayload{blobId = blobId, reason = reason},
		)
		routerTestExpectProtocolError(
			&h,
			peers[:],
			common.ATTACHMENT_REMOVE_REASON_INVALID_MESSAGE,
		)
	}
	routerTestSendSealed(
		&h,
		&transport,
		peerID,
		.ClientAdminRemoveAttachment,
		common.ClientAdminRemoveAttachmentPayload{},
	)
	routerTestExpectProtocolError(&h, peers[:], ADMIN_INVALID_REQUEST_MESSAGE)
	routerTestExpectNoDatabaseQuery(&h, "expected bad requests refused before the database")
}

// The usage statement decides who may see it; the storage worker adds the free space.
@(test)
testRouterAttachmentUsageAddsTheFreeSpace :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := modTestHarness()
	defer routerTestHarness_deinit(&h)
	h.pm.config.attachmentCapacityBytes = 1 << 30
	peerID := u32(1)
	transport := routerCompleteHandshake(&h, peerID, 42, isAdmin = true)
	peers := [?]RouterTestPeer{{peerID, &transport}}

	// A non-admin: refused, and the storage worker is never asked.
	routerTestSendSealed(&h, &transport, peerID, .ClientAdminAttachmentUsage, struct {}{})
	query := routerPollDatabaseQuery(&h)
	request := query.request.(common.DatabaseAttachmentRequest)
	assert(
		request.action == .Usage &&
		request.userId == 42 &&
		request.limit == common.ATTACHMENT_USAGE_ACCOUNTS_MAX,
		fmt.tprintf("expected the usage statement, got %v", request),
	)
	IPC__database_query_request_deinit(query.request)
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		query.request_id,
		common.DatabaseQueryResponse {
			success = true,
			result = common.DatabaseAttachmentResult{action = .Usage, outcome = .NotAdmin},
		},
	)
	routerTestExpectProtocolError(&h, peers[:], "Admin permission required")
	modTestExpectNoStorage(&h, "expected no free space asked for a non-admin")

	routerTestSendSealed(&h, &transport, peerID, .ClientAdminAttachmentUsage, struct {}{})
	query = routerPollDatabaseQuery(&h)
	IPC__database_query_request_deinit(query.request)
	accounts := make([dynamic]common.AttachmentAccountUsage, 0, 2)
	append(&accounts, common.AttachmentAccountUsage{userId = 43, bytes = 900, count = 2})
	append(&accounts, common.AttachmentAccountUsage{userId = 42, bytes = 100, count = 1})
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		query.request_id,
		common.DatabaseQueryResponse {
			success = true,
			result = common.DatabaseAttachmentResult {
				action = .Usage,
				outcome = .Applied,
				usedBytes = 1000,
				accounts = accounts,
			},
		},
	)
	routerTestExpectNoNetworkMessage(&h, "expected the usage to wait for the free space")
	free := modTestPollStorage(&h)
	_, freeOK := free.request.(StorageFreeSpace)
	assert(freeOK, fmt.tprintf("expected the free space asked, got %v", free.request))
	MainRouterState_handleStorageResponse(
		&h.pm,
		&h.state,
		StorageResponse {
			requestId = free.requestId,
			result = StorageFreeSpaceResult{freeBytes = 5 << 30, ok = true},
		},
	)
	_, packet := routerTestReceive(&h, peers[:])
	defer delete(packet.payload)
	assert(packet.messageType == .ServerAdminAttachmentUsage, "expected the usage")
	usage: common.ServerAdminAttachmentUsagePayload
	assert(cbor.unmarshal(packet.payload, &usage) == nil, "expected the usage to decode")
	defer common.ServerAdminAttachmentUsagePayload_deinit(&usage)
	assert(
		usage.usedBytes == 1000 &&
		usage.capacityBytes == 1 << 30 &&
		usage.freeBytes == 5 << 30 &&
		usage.freeBytesKnown &&
		len(usage.accounts) == 2 &&
		usage.accounts[0].userId == 43 &&
		usage.accounts[0].bytes == 900 &&
		usage.accounts[0].count == 2,
		fmt.tprintf("expected the usage with the free space, got %v", usage),
	)

	// The storage worker stopping still answers, without the free space.
	routerTestSendSealed(&h, &transport, peerID, .ClientAdminAttachmentUsage, struct {}{})
	query = routerPollDatabaseQuery(&h)
	IPC__database_query_request_deinit(query.request)
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		query.request_id,
		common.DatabaseQueryResponse {
			success = true,
			result = common.DatabaseAttachmentResult {
				action = .Usage,
				outcome = .Applied,
				usedBytes = 7,
			},
		},
	)
	stopped := modTestPollStorage(&h)
	_ = stopped
	MainRouterState_attachmentsStorageStopped(&h.pm, &h.state)
	_, unknown := routerTestReceive(&h, peers[:])
	defer delete(unknown.payload)
	unknownUsage: common.ServerAdminAttachmentUsagePayload
	assert(cbor.unmarshal(unknown.payload, &unknownUsage) == nil, "expected the usage")
	defer common.ServerAdminAttachmentUsagePayload_deinit(&unknownUsage)
	assert(
		unknownUsage.usedBytes == 7 && !unknownUsage.freeBytesKnown,
		fmt.tprintf("expected the usage without the free space, got %v", unknownUsage),
	)
}

// The hourly pass deletes bound tombstones' files again and ends any download of one (a
// removal made in SQL); a download check of a removed file says so.
@(test)
testRouterAttachmentTombstonePassAndRemovedDownloads :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := modTestHarness()
	defer routerTestHarness_deinit(&h)
	peerID := u32(1)
	transport := routerCompleteHandshake(&h, peerID, 43)
	peers := [?]RouterTestPeer{{peerID, &transport}}
	blobId := modTestBlob(0x50)
	modTestStartDownload(&h, peers[:], &transport, peerID, blobId)

	MainRouterState_attachmentsTombstonePass(&h.pm, &h.state)
	query := routerPollDatabaseQuery(&h)
	request := query.request.(common.DatabaseAttachmentRequest)
	assert(
		request.action == .TombstoneFiles && request.limit == ATTACHMENT_TOMBSTONE_FILES_BATCH,
		fmt.tprintf("expected the tombstone statement, got %v", request),
	)
	IPC__database_query_request_deinit(query.request)
	blobs := make([dynamic]common.DatabaseAttachmentBlob, 0, 1)
	append(&blobs, common.DatabaseAttachmentBlob{blobId = blobId, state = .Removed})
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		query.request_id,
		common.DatabaseQueryResponse {
			success = true,
			result = common.DatabaseAttachmentResult {
				action = .TombstoneFiles,
				outcome = .Applied,
				blobs = blobs,
			},
		},
	)
	deleteCommand := modTestPollStorage(&h)
	deleteRequest, deleteOK := deleteCommand.request.(StorageDeleteBlobs)
	assert(
		deleteOK && len(deleteRequest.blobs) == 1 && deleteRequest.blobs[0].blobId == blobId,
		"expected the tombstone's file deleted again",
	)
	StorageRequest_deinit(deleteCommand.request)
	_, packet := routerTestReceive(&h, peers[:])
	defer delete(packet.payload)
	refusal: common.ServerAttachmentRefusedPayload
	assert(
		packet.messageType == .ServerAttachmentRefused &&
		cbor.unmarshal(packet.payload, &refusal, temp_allocator = context.allocator) == nil,
		"expected the download refused",
	)
	defer common.ServerAttachmentRefusedPayload_deinit(&refusal)
	assert(
		refusal.message == common.ATTACHMENT_REMOVED_MESSAGE,
		fmt.tprintf("expected the download ended as removed, got %q", refusal.message),
	)
	assert(len(h.state.attachments.downloads) == 0, "expected the download gone")

	// A new download of the tombstone: the check says Removed.
	routerTestSendSealed(
		&h,
		&transport,
		peerID,
		.ClientAttachmentDownload,
		common.ClientAttachmentDownloadPayload{blobId = blobId},
	)
	check := routerPollDatabaseQuery(&h)
	IPC__database_query_request_deinit(check.request)
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		check.request_id,
		common.DatabaseQueryResponse {
			success = true,
			result = common.DatabaseAttachmentResult{action = .DownloadCheck, outcome = .Removed},
		},
	)
	_, refused := routerTestReceive(&h, peers[:])
	defer delete(refused.payload)
	again: common.ServerAttachmentRefusedPayload
	assert(
		cbor.unmarshal(refused.payload, &again, temp_allocator = context.allocator) == nil,
		"expected the refusal to decode",
	)
	defer common.ServerAttachmentRefusedPayload_deinit(&again)
	assert(
		again.message == common.ATTACHMENT_REMOVED_MESSAGE,
		fmt.tprintf("expected the check refused as removed, got %q", again.message),
	)
}
