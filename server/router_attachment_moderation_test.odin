package server

import "../common"
import "core:encoding/cbor"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

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

// Starts a download of blobId by peerID and answers its check, up to the first reads, whose
// storage request IDs it returns.
@(private = "file")
modTestStartDownload :: proc(
	h: ^RouterTestHarness,
	peers: []RouterTestPeer,
	transport: ^common.TransportState,
	peerID: u32,
	blobId: common.AttachmentBlobID,
) -> (
	reads: [4]u64,
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
	for index in 0 ..< 4 {
		read := modTestPollStorage(h)
		_, ok := read.request.(StorageRead)
		assert(ok, fmt.tprintf("expected a chunk read, got %v", read.request))
		reads[index] = read.requestId
	}
	return
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
		ok &&
		request.action == .Remove &&
		request.userId == 42 &&
		request.blobId == blobId &&
		request.reason == "spam",
		fmt.tprintf("expected the removal statement for admin 42, got %v", query.request),
	)
	IPC__database_query_request_deinit(query.request)
	modTestAnswerRemove(
		&h,
		query.request_id,
		.Applied,
		common.DatabaseAttachmentRemoval {
			ownerUserId = 43,
			roomId = 1,
			senderId = 43,
			chatMessageId = 900,
		},
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
			notice.recipientId == 0 &&
			notice.chatMessageId == 900 &&
			notice.directMessageId == 0,
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

// Protocol 29 (#138): a direct message's removal names its message, so readers find it without
// scanning their caches.
@(test)
testRouterAttachmentRemovalNamesTheDirectMessage :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := modTestHarness()
	defer routerTestHarness_deinit(&h)
	adminPeer, bobPeer := u32(1), u32(2)
	h.state.connectedPeers[bobPeer] = true
	adminTransport := routerCompleteHandshake(&h, adminPeer, 42, isAdmin = true)
	peers := [?]RouterTestPeer{{adminPeer, &adminTransport}, {bobPeer, nil}}
	bobTransport := routerCompleteHandshake(&h, bobPeer, 43)
	peers[1].transport = &bobTransport
	skipped := modTestDrain(&h, peers[:])
	modTestFree(&skipped)

	blobId := modTestBlob(0x50)
	routerTestSendSealed(
		&h,
		&adminTransport,
		adminPeer,
		.ClientAdminRemoveAttachment,
		common.ClientAdminRemoveAttachmentPayload{blobId = blobId},
	)
	query := routerPollDatabaseQuery(&h)
	request := query.request.(common.DatabaseAttachmentRequest)
	assert(request.reason == "", fmt.tprintf("expected no reason, got %q", request.reason))
	IPC__database_query_request_deinit(query.request)
	modTestAnswerRemove(
		&h,
		query.request_id,
		.Applied,
		common.DatabaseAttachmentRemoval {
			ownerUserId = 43,
			senderId = 43,
			recipientId = 42,
			directMessageId = 31,
		},
		{43},
	)
	deleteCommand := modTestPollStorage(&h)
	StorageRequest_deinit(deleteCommand.request)
	messages := modTestDrain(&h, peers[:])
	defer modTestFree(&messages)
	notice: common.ServerAttachmentRemovedPayload
	assert(
		cbor.unmarshal(
			modTestFind(messages[:], bobPeer, .ServerAttachmentRemoved),
			&notice,
			temp_allocator = context.allocator,
		) ==
		nil,
		"expected the notice to decode",
	)
	assert(
		notice.blobId == blobId &&
		notice.roomId == 0 &&
		notice.senderId == 43 &&
		notice.recipientId == 42 &&
		notice.chatMessageId == 0 &&
		notice.directMessageId == 31,
		fmt.tprintf("expected the direct message's notice with its ID, got %v", notice),
	)
}

// Protocol 29 (#138): the removal log list. The statement decides who is an admin; the router
// refuses a negative cursor before it, passes the page size, and echoes the cursor.
@(test)
testRouterAttachmentRemovalsList :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := modTestHarness()
	defer routerTestHarness_deinit(&h)
	peerID := u32(1)
	transport := routerCompleteHandshake(&h, peerID, 42, isAdmin = true)
	peers := [?]RouterTestPeer{{peerID, &transport}}

	routerTestSendSealed(
		&h,
		&transport,
		peerID,
		.ClientAdminListAttachmentRemovals,
		common.ClientAdminListAttachmentRemovalsPayload{beforeId = -1},
	)
	routerTestExpectProtocolError(&h, peers[:], ADMIN_INVALID_REQUEST_MESSAGE)
	routerTestExpectNoDatabaseQuery(&h, "expected a negative cursor refused before the database")

	// Not an admin, as the statement says: refused.
	routerTestSendSealed(
		&h,
		&transport,
		peerID,
		.ClientAdminListAttachmentRemovals,
		common.ClientAdminListAttachmentRemovalsPayload{},
	)
	query := routerPollDatabaseQuery(&h)
	request := query.request.(common.DatabaseAttachmentRequest)
	assert(
		request.action == .Removals &&
		request.userId == 42 &&
		request.beforeId == 0 &&
		request.limit == common.ATTACHMENT_REMOVALS_PAGE_MAX,
		fmt.tprintf("expected the removals statement, got %v", request),
	)
	IPC__database_query_request_deinit(query.request)
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		query.request_id,
		common.DatabaseQueryResponse {
			success = true,
			result = common.DatabaseAttachmentResult{action = .Removals, outcome = .NotAdmin},
		},
	)
	routerTestExpectProtocolError(&h, peers[:], "Admin permission required")

	// An admin's second page: the entries as the statement listed them, and the cursor.
	routerTestSendSealed(
		&h,
		&transport,
		peerID,
		.ClientAdminListAttachmentRemovals,
		common.ClientAdminListAttachmentRemovalsPayload{beforeId = 30},
	)
	query = routerPollDatabaseQuery(&h)
	request = query.request.(common.DatabaseAttachmentRequest)
	assert(request.beforeId == 30, fmt.tprintf("expected the cursor passed, got %v", request))
	IPC__database_query_request_deinit(query.request)
	blobId := modTestBlob(0x60)
	removals := make([dynamic]common.AttachmentRemovalEntry, 0, 2)
	append(
		&removals,
		common.AttachmentRemovalEntry {
			id = 29,
			blobId = blobId,
			ownerUserId = 43,
			removedByUserId = 42,
			removedAt = strings.clone("2026-11-19 12:00:00+00"),
			reason = strings.clone("spam"),
			roomId = 1,
			chatMessageId = 5,
			name = strings.clone("a.txt"),
		},
		common.AttachmentRemovalEntry {
			id = 27,
			blobId = blobId,
			ownerUserId = 44,
			removedAt = strings.clone("2026-11-18 12:00:00+00"),
			direct = true,
			encrypted = true,
		},
	)
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		query.request_id,
		common.DatabaseQueryResponse {
			success = true,
			result = common.DatabaseAttachmentResult {
				action = .Removals,
				outcome = .Applied,
				removals = removals,
				hasMore = true,
			},
		},
	)
	_, packet := routerTestReceive(&h, peers[:])
	defer delete(packet.payload)
	assert(packet.messageType == .ServerAdminAttachmentRemovals, "expected the removals page")
	page: common.ServerAdminAttachmentRemovalsPayload
	assert(
		cbor.unmarshal(packet.payload, &page, temp_allocator = context.allocator) == nil,
		"expected the page to decode",
	)
	defer common.ServerAdminAttachmentRemovalsPayload_deinit(&page)
	assert(
		page.beforeId == 30 &&
		page.hasMore &&
		len(page.entries) == 2 &&
		page.entries[0].id == 29 &&
		page.entries[0].blobId == blobId &&
		page.entries[0].removedByUserId == 42 &&
		page.entries[0].reason == "spam" &&
		page.entries[0].name == "a.txt" &&
		page.entries[0].chatMessageId == 5 &&
		page.entries[1].id == 27 &&
		page.entries[1].removedByUserId == 0 &&
		page.entries[1].direct &&
		page.entries[1].encrypted,
		fmt.tprintf("expected the page with its cursor, got %v", page),
	)
	routerTestExpectNoNetworkMessage(&h, "expected only the page")
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

// ── Files missing from storage (#132 follow-up, router_attachment_missing.odin) ───────────

// Answers one chunk read of blobId as a file the storage worker did not find.
@(private = "file")
modTestAnswerMissing :: proc(
	h: ^RouterTestHarness,
	requestID: u64,
	blobId: common.AttachmentBlobID,
	intact: bool,
) {
	MainRouterState_handleStorageResponse(
		&h.pm,
		&h.state,
		StorageResponse {
			requestId = requestID,
			result = StorageReadData{blobId = blobId, missing = true, blobDirectoryIntact = intact},
		},
	)
}

@(private = "file")
modTestDecodeRefusal :: proc(payload: []u8) -> common.ServerAttachmentRefusedPayload {
	refusal: common.ServerAttachmentRefusedPayload
	assert(
		cbor.unmarshal(payload, &refusal, temp_allocator = context.allocator) == nil,
		"expected the refusal to decode",
	)
	return refusal
}

// Expects the mark of blobId in the database and returns its request ID.
@(private = "file")
modTestExpectMark :: proc(h: ^RouterTestHarness, blobId: common.AttachmentBlobID) -> u64 {
	query := routerPollDatabaseQuery(h)
	request, ok := query.request.(common.DatabaseAttachmentRequest)
	assert(
		ok &&
		request.action == .MarkMissing &&
		request.userId == 0 &&
		request.blobId == blobId &&
		request.reason == ATTACHMENT_MISSING_REMOVAL_REASON,
		fmt.tprintf("expected the server's mark of the missing file, got %v", query.request),
	)
	IPC__database_query_request_deinit(query.request)
	return query.request_id
}

// A download that finds the file missing is refused "not found" and marks the row: one mark
// for the blob however many downloads find it missing, and once the database applied it every
// other download ends as removed and each reader the statement named hears
// ServerAttachmentRemoved. No file is deleted (it is gone already).
@(test)
testRouterAttachmentMissingFileBecomesATombstone :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := modTestHarness()
	defer routerTestHarness_deinit(&h)

	bobPeer, carolPeer, davePeer, erinPeer := u32(1), u32(2), u32(3), u32(4)
	for peerID in ([]u32{carolPeer, davePeer, erinPeer}) {
		h.state.connectedPeers[peerID] = true
	}
	bobTransport := routerCompleteHandshake(&h, bobPeer, 43)
	peers := [?]RouterTestPeer {
		{bobPeer, &bobTransport},
		{carolPeer, nil},
		{davePeer, nil},
		{erinPeer, nil},
	}
	transports: [3]common.TransportState
	for index in 0 ..< 3 {
		transports[index] = routerCompleteHandshake(&h, peers[index + 1].peerID, 44 + index)
		peers[index + 1].transport = &transports[index]
		skipped := modTestDrain(&h, peers[:])
		modTestFree(&skipped)
	}

	blobId := modTestBlob(0x50)
	bobReads := modTestStartDownload(&h, peers[:], &bobTransport, bobPeer, blobId)
	_ = modTestStartDownload(&h, peers[:], &transports[0], carolPeer, blobId)
	daveReads := modTestStartDownload(&h, peers[:], &transports[1], davePeer, blobId)

	// Bob's read finds no file: Bob is refused, and the row is marked.
	modTestAnswerMissing(&h, bobReads[0], blobId, true)
	messages := modTestDrain(&h, peers[:])
	refusal := modTestDecodeRefusal(modTestFind(messages[:], bobPeer, .ServerAttachmentRefused))
	assert(
		refusal.blobId == blobId && refusal.message == common.ATTACHMENT_NOT_FOUND_MESSAGE,
		fmt.tprintf("expected Bob refused as not found, got %v", refusal),
	)
	common.ServerAttachmentRefusedPayload_deinit(&refusal)
	modTestFree(&messages)
	markID := modTestExpectMark(&h, blobId)

	// Dave's read finds none either while the mark is in the database: no second mark.
	modTestAnswerMissing(&h, daveReads[0], blobId, true)
	messages = modTestDrain(&h, peers[:])
	assert(
		modTestCount(messages[:], davePeer, .ServerAttachmentRefused) == 1,
		"expected Dave refused",
	)
	modTestFree(&messages)
	routerTestExpectNoDatabaseQuery(&h, "expected one mark of the blob")
	assert(h.state.attachments.missing.marks == 1, "expected one mark counted")

	// Applied: Carol's download ends as removed, the readers hear it, no file is deleted.
	readers := make([dynamic]int, 0, 3)
	append(&readers, 43, 44, 45)
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		markID,
		common.DatabaseQueryResponse {
			success = true,
			result = common.DatabaseAttachmentResult {
				action = .MarkMissing,
				outcome = .Applied,
				removal = common.DatabaseAttachmentRemoval {
					ownerUserId = 44,
					roomId = 1,
					senderId = 44,
					chatMessageId = 901,
					readerUserIds = readers,
				},
			},
		},
	)
	modTestExpectNoStorage(&h, "expected no file deletion for a missing file")
	messages = modTestDrain(&h, peers[:])
	defer modTestFree(&messages)
	ended := modTestDecodeRefusal(modTestFind(messages[:], carolPeer, .ServerAttachmentRefused))
	defer common.ServerAttachmentRefusedPayload_deinit(&ended)
	assert(
		ended.blobId == blobId && ended.message == common.ATTACHMENT_REMOVED_MESSAGE,
		fmt.tprintf("expected Carol's download ended as removed, got %v", ended),
	)
	assert(len(h.state.attachments.downloads) == 0, "expected every download of the blob gone")
	for peerID in ([]u32{bobPeer, carolPeer, davePeer}) {
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
			notice.senderId == 44 &&
			notice.chatMessageId == 901,
			fmt.tprintf("expected the room notice for peer %d, got %v", peerID, notice),
		)
	}
	assert(
		modTestCount(messages[:], erinPeer, .ServerAttachmentRemoved) == 0,
		"expected no notice for an account that is not a reader",
	)
	assert(len(h.state.attachments.missing.marking) == 0, "expected the mark answered")
}

// The guards: a read error that is not a missing file, and a missing file in a blob directory
// that does not look intact, mark nothing; past the window's cap nothing is marked but the
// reader is still refused "not found", and a new window marks again; a mark the database
// failed is forgotten, so a later read may try again.
@(test)
testRouterAttachmentMissingFileGuards :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := modTestHarness()
	defer routerTestHarness_deinit(&h)
	peerID := u32(1)
	transport := routerCompleteHandshake(&h, peerID, 43)
	peers := [?]RouterTestPeer{{peerID, &transport}}

	expectRefused :: proc(h: ^RouterTestHarness, peers: []RouterTestPeer, message: string) {
		messages := modTestDrain(h, peers)
		defer modTestFree(&messages)
		refusal := modTestDecodeRefusal(
			modTestFind(messages[:], peers[0].peerID, .ServerAttachmentRefused),
		)
		defer common.ServerAttachmentRefusedPayload_deinit(&refusal)
		assert(
			refusal.message == message,
			fmt.tprintf("expected the refusal %q, got %q", message, refusal.message),
		)
	}

	// Another read error is the disk's: no mark.
	blobId := modTestBlob(0x60)
	reads := modTestStartDownload(&h, peers[:], &transport, peerID, blobId)
	MainRouterState_handleStorageResponse(
		&h.pm,
		&h.state,
		StorageResponse{requestId = reads[0], result = StorageReadData{blobId = blobId}},
	)
	expectRefused(&h, peers[:], common.ATTACHMENT_STORAGE_ERROR_MESSAGE)
	routerTestExpectNoDatabaseQuery(&h, "expected no mark for a read error")

	// Missing, but the blob directory looks absent or incomplete: no mark.
	reads = modTestStartDownload(&h, peers[:], &transport, peerID, blobId)
	modTestAnswerMissing(&h, reads[0], blobId, false)
	expectRefused(&h, peers[:], common.ATTACHMENT_NOT_FOUND_MESSAGE)
	routerTestExpectNoDatabaseQuery(&h, "expected no mark while the blob directory is suspect")
	assert(h.state.attachments.missing.marks == 0, "expected no mark counted")

	// The window's marks are spent: refused as not found, no mark.
	now := time.tick_now()
	h.state.attachments.missing.windowStart = now
	h.state.attachments.missing.marks = ATTACHMENT_MISSING_MARKS_PER_WINDOW
	reads = modTestStartDownload(&h, peers[:], &transport, peerID, blobId)
	modTestAnswerMissing(&h, reads[0], blobId, true)
	expectRefused(&h, peers[:], common.ATTACHMENT_NOT_FOUND_MESSAGE)
	routerTestExpectNoDatabaseQuery(&h, "expected no mark past the cap")
	assert(h.state.attachments.missing.capLogged, "expected the cap logged")

	// An hour later a new window marks again; a failed mark is forgotten.
	h.state.attachments.missing.windowStart = time.tick_add(now, -2 * time.Hour)
	reads = modTestStartDownload(&h, peers[:], &transport, peerID, blobId)
	modTestAnswerMissing(&h, reads[0], blobId, true)
	expectRefused(&h, peers[:], common.ATTACHMENT_NOT_FOUND_MESSAGE)
	markID := modTestExpectMark(&h, blobId)
	assert(
		h.state.attachments.missing.marks == 1 && !h.state.attachments.missing.capLogged,
		"expected a new window with one mark",
	)
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		markID,
		common.DatabaseQueryResponse{success = false},
	)
	assert(len(h.state.attachments.missing.marking) == 0, "expected the failed mark forgotten")
	routerTestExpectNoNetworkMessage(&h, "expected nothing sent for a failed mark")
}

// attachmentMissingDecide counts marks per window: the cap stops the next one and logs once,
// a blob being marked is not marked twice, a suspect directory never marks or counts, and the
// window resets after an hour.
@(test)
testAttachmentMissingDecideCountsMarksPerWindow :: proc(t: ^testing.T) {
	_ = t
	guard := AttachmentMissingGuard {
		marking = make(map[common.AttachmentBlobID]bool),
	}
	defer delete(guard.marking)
	now := time.tick_now()
	decision, logCap := attachmentMissingDecide(&guard, modTestBlob(0x70), false, now)
	assert(decision == .StorageSuspect && !logCap && guard.marks == 0, "expected a suspect")
	for index in 0 ..< ATTACHMENT_MISSING_MARKS_PER_WINDOW {
		decision, _ = attachmentMissingDecide(&guard, modTestBlob(u8(index)), true, now)
		assert(decision == .Mark, fmt.tprintf("expected mark %d allowed, got %v", index, decision))
	}
	decision, _ = attachmentMissingDecide(&guard, modTestBlob(0), true, now)
	assert(decision == .AlreadyMarking, fmt.tprintf("expected a duplicate, got %v", decision))
	delete_key(&guard.marking, modTestBlob(0))
	decision, logCap = attachmentMissingDecide(&guard, modTestBlob(0x80), true, now)
	assert(decision == .CapReached && logCap, "expected the cap reached and logged")
	decision, logCap = attachmentMissingDecide(&guard, modTestBlob(0x81), true, now)
	assert(decision == .CapReached && !logCap, "expected the cap logged once")
	later := time.tick_add(now, ATTACHMENT_MISSING_MARK_WINDOW)
	decision, _ = attachmentMissingDecide(&guard, modTestBlob(0x82), true, later)
	assert(decision == .Mark && guard.marks == 1, "expected a new window")
}
