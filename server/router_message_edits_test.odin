package server

import "../common"
import "core:encoding/cbor"
import "core:fmt"
import "core:sync"
import "core:testing"

// Router tests for editing and deleting messages (protocol 30, router_message_edits.odin): the
// checks the router makes before the database (shape, the session's signature), and what it
// sends once the statement decided. Who may read a message is the statement's
// (database_message_edits_test.odin); here the readers come from its result.

@(private = "file")
EditTestMessage :: struct {
	peerID: u32,
	packet: common.Packet, // payload owned
}

@(private = "file")
editTestDrain :: proc(h: ^RouterTestHarness, peers: []RouterTestPeer) -> [dynamic]EditTestMessage {
	messages := make([dynamic]EditTestMessage)
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
		for peer in peers {
			if peer.peerID != send.peerId {
				continue
			}
			packet, ok := common.openPacketForSession(peer.transport, outer)
			assert(ok, fmt.tprintf("expected peer %d to open its message", send.peerId))
			if packet.messageType == .ServerUserPresence {
				delete(packet.payload)
			} else {
				append(&messages, EditTestMessage{peerID = send.peerId, packet = packet})
			}
		}
		delete(outer.payload)
	}
	return messages
}

@(private = "file")
editTestFree :: proc(messages: ^[dynamic]EditTestMessage) {
	for message in messages {
		delete(message.packet.payload)
	}
	delete(messages^)
}

@(private = "file")
editTestTypes :: proc(messages: []EditTestMessage, peerID: u32) -> []common.MessageType {
	types := make([dynamic]common.MessageType, context.temp_allocator)
	for message in messages {
		if message.peerID == peerID {
			append(&types, message.packet.messageType)
		}
	}
	return types[:]
}

@(private = "file")
editTestFind :: proc(
	messages: []EditTestMessage,
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

// Three accounts: alice (42) on peer 1, bob (43) on peers 2 and 3, carol (44) on peer 4.
@(private = "file")
EditTestSessions :: struct {
	alice, bob, bobSecond, carol: common.TransportState,
	aliceKey:                     common.IdentityPrivateKeyBytes,
	bobKey:                       common.IdentityPrivateKeyBytes,
}

@(private = "file")
editTestSessions :: proc(
	h: ^RouterTestHarness,
	sessions: ^EditTestSessions,
	peers: ^[4]RouterTestPeer,
	aliceAdmin := false,
) {
	for peerID in ([]u32{2, 3, 4}) {
		h.state.connectedPeers[peerID] = true
	}
	sessions.alice = routerCompleteHandshake(
		h,
		1,
		42,
		isAdmin = aliceAdmin,
		identityPrivateKeyOut = &sessions.aliceKey,
	)
	peers^ = {{1, &sessions.alice}, {2, nil}, {3, nil}, {4, nil}}
	sessions.bob = routerCompleteHandshake(h, 2, 43, identityPrivateKeyOut = &sessions.bobKey)
	peers[1].transport = &sessions.bob
	skipped := editTestDrain(h, peers[:])
	editTestFree(&skipped)
	sessions.bobSecond = routerCompleteHandshake(h, 3, 43)
	peers[2].transport = &sessions.bobSecond
	sessions.carol = routerCompleteHandshake(h, 4, 44)
	peers[3].transport = &sessions.carol
	skipped = editTestDrain(h, peers[:])
	editTestFree(&skipped)
}

@(private = "file")
editTestOriginal :: proc() -> common.ClientMessageID {
	return common.ClientMessageID{0 = 0x11, 15 = 0x22}
}

@(private = "file")
editTestEditID :: proc() -> common.ClientMessageID {
	return common.ClientMessageID{0 = 0x33, 15 = 0x44}
}

@(private = "file")
editTestRoomEdit :: proc(
	h: ^RouterTestHarness,
	key: common.IdentityPrivateKeyBytes,
	senderID: int,
	content: string,
) -> common.ClientEditRoomMessagePayload {
	edit := common.ClientEditRoomMessagePayload {
		roomId                  = 1,
		messageId               = 700,
		originalClientMessageId = editTestOriginal(),
		clientMessageId         = editTestEditID(),
		content                 = content,
	}
	signature, ok := common.signRoomMessageEdit(
		common.MessageChangeFields {
			serverIdentityPublicKey = h.state.serverIdentityPublicKey,
			conversationID = 1,
			senderUserID = senderID,
			original = edit.originalClientMessageId,
			edit = edit.clientMessageId,
		},
		content,
		key,
	)
	assert(ok, "expected the edit to sign")
	edit.signature = signature
	return edit
}

// A plaintext edit reaches the database only with the session's signature over the message's
// ID; the stored edit goes to every session of exactly the readers the statement named.
@(test)
testRouterRoomMessageEditChecksTheSignatureAndFansOutToReaders :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)
	sessions: EditTestSessions
	peers: [4]RouterTestPeer
	editTestSessions(&h, &sessions, &peers)

	// Signed by bob's key, for bob's account, or over another message's ID: refused here.
	forged := [?]common.ClientEditRoomMessagePayload {
		editTestRoomEdit(&h, sessions.bobKey, 42, "forged"),
		editTestRoomEdit(&h, sessions.aliceKey, 43, "for bob"),
		editTestRoomEdit(&h, sessions.aliceKey, 42, "moved"),
	}
	forged[2].originalClientMessageId[3] ~= 0x01
	for edit in forged {
		routerTestSendSealed(&h, &sessions.alice, 1, .ClientEditRoomMessage, edit)
		routerTestExpectProtocolError(
			&h,
			peers[:],
			"Invalid message edit signature (message 700)",
		)
		routerTestExpectNoDatabaseQuery(&h, "expected a forged edit to stay in the router")
	}
	// An edit that reuses the message's own client message ID is malformed.
	same := editTestRoomEdit(&h, sessions.aliceKey, 42, "same")
	same.clientMessageId = same.originalClientMessageId
	routerTestSendSealed(&h, &sessions.alice, 1, .ClientEditRoomMessage, same)
	routerTestExpectProtocolError(&h, peers[:], "Invalid message edit (message 700)")

	edit := editTestRoomEdit(&h, sessions.aliceKey, 42, "edited")
	routerTestSendSealed(&h, &sessions.alice, 1, .ClientEditRoomMessage, edit)
	query := routerPollDatabaseQuery(&h)
	request, ok := query.request.(common.DatabaseMessageChangeRequest)
	assert(
		ok &&
		request.action == .EditRoom &&
		request.actorUserId == 42 &&
		request.roomId == 1 &&
		request.messageId == 700 &&
		request.content == "edited" &&
		request.originalClientMessageId == editTestOriginal() &&
		request.clientMessageId == editTestEditID() &&
		len(request.sealed) == 0,
		fmt.tprintf("expected the edit statement for alice, got %v", query.request),
	)
	IPC__database_query_request_deinit(query.request)
	readers := make([dynamic]int, 0, 2)
	append(&readers, 42, 43)
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		query.request_id,
		common.DatabaseQueryResponse {
			success = true,
			result = common.DatabaseMessageChangeResult {
				outcome = .Applied,
				senderId = 42,
				editCount = 3,
				edit = common.MessageEdit {
					id = 9,
					clientMessageId = editTestEditID(),
					timestamp = fmt.aprintf("2026-11-19 12:00:00+00"),
					content = fmt.aprintf("edited"),
					signature = edit.signature,
				},
				readerUserIds = readers,
			},
		},
	)
	messages := editTestDrain(&h, peers[:])
	defer editTestFree(&messages)
	for peerID in ([]u32{1, 2, 3}) {
		notice: common.ServerRoomMessageEditedPayload
		assert(
			cbor.unmarshal(
				editTestFind(messages[:], peerID, .ServerRoomMessageEdited),
				&notice,
				temp_allocator = context.allocator,
			) ==
			nil,
			"expected the edit notice to decode",
		)
		defer common.ServerRoomMessageEditedPayload_deinit(&notice)
		assert(
			notice.roomId == 1 &&
			notice.messageId == 700 &&
			notice.senderId == 42 &&
			notice.editCount == 3 &&
			notice.edit.id == 9 &&
			notice.edit.content == "edited" &&
			notice.edit.signature == edit.signature,
			fmt.tprintf("expected the stored edit for peer %d, got %v", peerID, notice),
		)
	}
	assert(len(editTestTypes(messages[:], 4)) == 0, "expected carol to hear nothing")
	assert(len(messages) == 3, fmt.tprintf("expected three notices, got %d", len(messages)))
}

// A refusal names its message, and goes only to the session that asked.
@(test)
testRouterMessageChangeRefusalsNameTheirMessage :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)
	sessions: EditTestSessions
	peers: [4]RouterTestPeer
	editTestSessions(&h, &sessions, &peers)

	refusals := [?]struct {
		outcome: common.MessageChangeOutcome,
		message: string,
	} {
		{.NotAuthor, "You can only edit or delete your own messages (message 700)"},
		{.Deleted, "This message was deleted (message 700)"},
		{.EditLimit, "This message cannot be edited again (message 700)"},
		{.Duplicate, "Duplicate message edit (message 700)"},
		{.SendDenied, "You cannot send messages in this room (message 700)"},
		{.NotFound, "Message not found (message 700)"},
	}
	for refusal in refusals {
		routerTestSendSealed(
			&h,
			&sessions.alice,
			1,
			.ClientEditRoomMessage,
			editTestRoomEdit(&h, sessions.aliceKey, 42, "again"),
		)
		query := routerPollDatabaseQuery(&h)
		IPC__database_query_request_deinit(query.request)
		MainRouterState_handleDatabaseResult(
			&h.pm,
			&h.state,
			query.request_id,
			common.DatabaseQueryResponse {
				success = true,
				result = common.DatabaseMessageChangeResult{outcome = refusal.outcome},
			},
		)
		routerTestExpectProtocolError(&h, peers[:], refusal.message)
		routerTestExpectNoNetworkMessage(&h, "expected the refusal alone")
	}
}

// D5, D8: an admin's delete carries no signature; the deleted message's files end their
// downloads and go to the storage worker, every reader hears ServerAttachmentRemoved and then
// the tombstone, and the admin (no reader) gets the tombstone too.
@(test)
testRouterAdminRoomDeleteRemovesFilesAndTellsReaders :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)
	sessions: EditTestSessions
	peers: [4]RouterTestPeer
	editTestSessions(&h, &sessions, &peers, aliceAdmin = true)

	routerTestSendSealed(
		&h,
		&sessions.alice,
		1,
		.ClientDeleteRoomMessage,
		common.ClientDeleteRoomMessagePayload{roomId = 1, messageId = 701},
	)
	query := routerPollDatabaseQuery(&h)
	request, ok := query.request.(common.DatabaseMessageChangeRequest)
	assert(
		ok && request.action == .DeleteRoom && request.adminDelete && request.actorUserId == 42,
		fmt.tprintf("expected an admin delete, got %v", query.request),
	)
	IPC__database_query_request_deinit(query.request)
	blob := common.AttachmentBlobID{0 = 0x51, 15 = 0x52}
	readers := make([dynamic]int, 0, 1)
	append(&readers, 43)
	blobs := make([dynamic]common.AttachmentBlobID, 0, 1)
	append(&blobs, blob)
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		query.request_id,
		common.DatabaseQueryResponse {
			success = true,
			result = common.DatabaseMessageChangeResult {
				outcome = .Applied,
				senderId = 43,
				deletion = common.MessageDeletion {
					deletedAt = fmt.aprintf("2026-11-19 13:00:00+00"),
				},
				readerUserIds = readers,
				removedBlobs = blobs,
			},
		},
	)
	storage, storageErr := IPC_Client_poll(h.pm.config.storageFd)
	assert(storageErr == nil, "expected a storage command")
	command := storage.(StorageCommand)
	deleteRequest, deleteOK := command.request.(StorageDeleteBlobs)
	assert(
		deleteOK && len(deleteRequest.blobs) == 1 && deleteRequest.blobs[0].blobId == blob,
		fmt.tprintf("expected the file deleted, got %v", command.request),
	)
	StorageRequest_deinit(command.request)

	messages := editTestDrain(&h, peers[:])
	defer editTestFree(&messages)
	for peerID in ([]u32{2, 3}) {
		types := editTestTypes(messages[:], peerID)
		assert(
			len(types) == 2 &&
			types[0] == .ServerAttachmentRemoved &&
			types[1] == .ServerRoomMessageDeleted,
			fmt.tprintf(
				"expected the file and then the tombstone for peer %d, got %v",
				peerID,
				types,
			),
		)
		removed: common.ServerAttachmentRemovedPayload
		assert(
			cbor.unmarshal(
				editTestFind(messages[:], peerID, .ServerAttachmentRemoved),
				&removed,
				temp_allocator = context.allocator,
			) ==
			nil,
			"expected the file notice to decode",
		)
		assert(
			removed.blobId == blob && removed.roomId == 1 && removed.chatMessageId == 701,
			fmt.tprintf("expected the file notice to name the message, got %v", removed),
		)
	}
	tombstone: common.ServerRoomMessageDeletedPayload
	assert(
		cbor.unmarshal(
			editTestFind(messages[:], 1, .ServerRoomMessageDeleted),
			&tombstone,
			temp_allocator = context.allocator,
		) ==
		nil,
		"expected the admin's tombstone to decode",
	)
	defer common.ServerRoomMessageDeletedPayload_deinit(&tombstone)
	assert(
		tombstone.messageId == 701 &&
		tombstone.senderId == 43 &&
		tombstone.deletion.signature == {},
		fmt.tprintf("expected an unsigned tombstone, got %v", tombstone),
	)
	assert(len(editTestTypes(messages[:], 4)) == 0, "expected carol to hear nothing")
}

// D5, D6: a direct message delete is always signed by its author; an unsigned one never
// reaches the database. A signed one does, and both sides hear the tombstone.
@(test)
testRouterDirectMessageDeleteNeedsTheAuthorsSignature :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)
	sessions: EditTestSessions
	peers: [4]RouterTestPeer
	editTestSessions(&h, &sessions, &peers)

	unsigned := common.ClientDeleteDirectMessagePayload {
		peerUserId              = 43,
		messageId               = 800,
		originalClientMessageId = editTestOriginal(),
	}
	routerTestSendSealed(&h, &sessions.alice, 1, .ClientDeleteDirectMessage, unsigned)
	routerTestExpectProtocolError(&h, peers[:], "Invalid message delete signature (message 800)")
	routerTestExpectNoDatabaseQuery(&h, "expected an unsigned DM delete to stay in the router")

	signed := unsigned
	signature, signOK := common.signDirectMessageDelete(
		common.MessageChangeFields {
			serverIdentityPublicKey = h.state.serverIdentityPublicKey,
			conversationID = 43,
			senderUserID = 42,
			original = unsigned.originalClientMessageId,
		},
		sessions.aliceKey,
	)
	assert(signOK, "expected the delete to sign")
	signed.signature = signature
	routerTestSendSealed(&h, &sessions.alice, 1, .ClientDeleteDirectMessage, signed)
	query := routerPollDatabaseQuery(&h)
	request, ok := query.request.(common.DatabaseMessageChangeRequest)
	assert(
		ok &&
		request.action == .DeleteDirect &&
		request.peerUserId == 43 &&
		request.signature == signature,
		fmt.tprintf("expected the DM delete statement, got %v", query.request),
	)
	IPC__database_query_request_deinit(query.request)
	readers := make([dynamic]int, 0, 2)
	append(&readers, 42, 43)
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		query.request_id,
		common.DatabaseQueryResponse {
			success = true,
			result = common.DatabaseMessageChangeResult {
				outcome = .Applied,
				senderId = 42,
				recipientId = 43,
				deletion = common.MessageDeletion {
					deletedAt = fmt.aprintf("2026-11-19 14:00:00+00"),
					signature = signature,
				},
				readerUserIds = readers,
			},
		},
	)
	messages := editTestDrain(&h, peers[:])
	defer editTestFree(&messages)
	for peerID in ([]u32{1, 2, 3}) {
		types := editTestTypes(messages[:], peerID)
		assert(
			len(types) == 1 && types[0] == .ServerDirectMessageDeleted,
			fmt.tprintf("expected the tombstone for peer %d, got %v", peerID, types),
		)
	}
	assert(len(editTestTypes(messages[:], 4)) == 0, "expected carol to hear nothing")
}

// The edit list goes only to the session that asked for it.
@(test)
testRouterFetchMessageEditsAnswersTheRequester :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)
	sessions: EditTestSessions
	peers: [4]RouterTestPeer
	editTestSessions(&h, &sessions, &peers)

	routerTestSendSealed(
		&h,
		&sessions.bob,
		2,
		.ClientFetchMessageEdits,
		common.ClientFetchMessageEditsPayload{kind = .Direct, conversationId = 42, messageId = 5},
	)
	query := routerPollDatabaseQuery(&h)
	request, ok := query.request.(common.DatabaseMessageChangeRequest)
	assert(
		ok && request.action == .FetchDirectEdits && request.actorUserId == 43 &&
		request.peerUserId == 42,
		fmt.tprintf("expected the DM edit fetch, got %v", query.request),
	)
	IPC__database_query_request_deinit(query.request)
	edits := make([dynamic]common.MessageEdit, 0, 2)
	append(&edits, common.MessageEdit{id = 1, content = fmt.aprintf("one")})
	append(&edits, common.MessageEdit{id = 2, content = fmt.aprintf("two")})
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		query.request_id,
		common.DatabaseQueryResponse {
			success = true,
			result = common.DatabaseMessageChangeResult{outcome = .Applied, edits = edits},
		},
	)
	messages := editTestDrain(&h, peers[:])
	defer editTestFree(&messages)
	assert(len(messages) == 1, fmt.tprintf("expected one answer, got %d", len(messages)))
	list: common.ServerMessageEditsPayload
	assert(
		cbor.unmarshal(editTestFind(messages[:], 2, .ServerMessageEdits), &list) == nil,
		"expected the edit list to decode",
	)
	defer common.ServerMessageEditsPayload_deinit(&list)
	assert(
		list.kind == .Direct &&
		list.conversationId == 42 &&
		list.messageId == 5 &&
		len(list.edits) == 2 &&
		list.edits[1].content == "two",
		fmt.tprintf("expected both edits oldest first, got %v", list),
	)

	// Bad requests never reach the database.
	bad := [?]common.ClientFetchMessageEditsPayload {
		{kind = .None, conversationId = 1, messageId = 5},
		{kind = .Room, conversationId = 0, messageId = 5},
		{kind = .Direct, conversationId = 43, messageId = 5},
	}
	for payload in bad {
		routerTestSendSealed(&h, &sessions.bob, 2, .ClientFetchMessageEdits, payload)
		routerTestExpectProtocolError(&h, peers[:], "Invalid message edits request")
		routerTestExpectNoDatabaseQuery(&h, "expected a bad fetch to stay in the router")
	}
}
