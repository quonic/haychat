package client

import "../common"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:testing"

// Client tests for editing and deleting messages (protocol 30, message_edits.odin): an edit is
// shown only when its author signed it against the pin, one that fails keeps the last good
// version, a tombstone always hides the content and reads "Removed by the server" unless the
// author signed it (D6), the edit list is checked edit by edit, and what goes out is signed.

MESSAGE_EDIT_TEST_SERVER :: 993
MESSAGE_EDIT_TEST_SELF :: 50
MESSAGE_EDIT_TEST_PEER :: 51
MESSAGE_EDIT_TEST_OTHER :: 52

messageChangeSendBridgeTestMutex: sync.Mutex

// The sends the stubbed bridge saw. Guarded by messageChangeSendBridgeTestMutex.
@(private = "file")
messageEditTestSends: [dynamic]MessageChangeSend

@(private = "file")
messageEditTestBridge :: proc(transport: ^ClientServerTransport, send: MessageChangeSend) -> bool {
	copied := send
	copied.roomEdit.content = strings.clone(send.roomEdit.content, context.temp_allocator)
	copied.directEdit.content = strings.clone(send.directEdit.content, context.temp_allocator)
	append(&messageEditTestSends, copied)
	return true
}

@(private = "file")
messageEditTestState :: proc() -> State {
	state := testUpdateStateForServer(testDirectServer(MESSAGE_EDIT_TEST_SERVER))
	testPrepareRoomSend(&state, MESSAGE_EDIT_TEST_SERVER, MESSAGE_EDIT_TEST_SELF)
	return state
}

// A signed live room message from senderID in #general.
@(private = "file")
messageEditTestRoomMessage :: proc(state: ^State, senderID, messageID: int, content: string) {
	clientMessageID, signature := testRoomMessageSignature(
		state,
		MESSAGE_EDIT_TEST_SERVER,
		common.GENERAL_ROOM_ID,
		senderID,
		messageID,
		content,
	)
	event := ClientTransportRuntimeEvent {
		kind            = .RoomChatReceived,
		serverID        = MESSAGE_EDIT_TEST_SERVER,
		roomID          = common.GENERAL_ROOM_ID,
		senderID        = senderID,
		senderNickname  = strings.clone("sender"),
		messageID       = messageID,
		timestamp       = strings.clone("t"),
		message         = strings.clone(content),
		clientMessageID = clientMessageID,
		signature       = signature,
	}
	State_applyRuntimeEvent(state, &event)
	ClientTransportRuntimeEvent_deinit(&event)
}

// An edit of a message as its author (signer) signs it; original is the message's ID.
@(private = "file")
messageEditTestEdit :: proc(
	state: ^State,
	kind: common.MessageEditsKind,
	conversationID, senderID, signerID: int,
	original: common.ClientMessageID,
	editID: int,
	content: string,
) -> common.MessageEdit {
	serverKey, privateKey := testMessageSigner(state, MESSAGE_EDIT_TEST_SERVER, signerID)
	edit := common.MessageEdit {
		id              = editID,
		clientMessageId = testMessageClientID(1000 + editID, 9),
		timestamp       = fmt.aprintf("t%d", editID),
		content         = strings.clone(content),
	}
	fields := common.MessageChangeFields {
		serverIdentityPublicKey = serverKey,
		conversationID          = conversationID,
		senderUserID            = senderID,
		original                = original,
		edit                    = edit.clientMessageId,
	}
	ok: bool
	if kind == .Room {
		edit.signature, ok = common.signRoomMessageEdit(fields, content, privateKey)
	} else {
		edit.signature, ok = common.signDirectMessageEdit(fields, content, privateKey)
	}
	assert(ok, "expected the test edit to sign")
	return edit
}

@(private = "file")
messageEditTestDeletion :: proc(
	state: ^State,
	kind: common.MessageEditsKind,
	conversationID, senderID, signerID: int,
	original: common.ClientMessageID,
) -> common.MessageDeletion {
	serverKey, privateKey := testMessageSigner(state, MESSAGE_EDIT_TEST_SERVER, signerID)
	fields := common.MessageChangeFields {
		serverIdentityPublicKey = serverKey,
		conversationID          = conversationID,
		senderUserID            = senderID,
		original                = original,
	}
	deletion := common.MessageDeletion {
		deletedAt = strings.clone("d"),
	}
	ok: bool
	if kind == .Room {
		deletion.signature, ok = common.signRoomMessageDelete(fields, privateKey)
	} else {
		deletion.signature, ok = common.signDirectMessageDelete(fields, privateKey)
	}
	assert(ok, "expected the test delete to sign")
	return deletion
}

// A room edit of the peer's message in #general, signed by signerID.
@(private = "file")
messageEditTestPeerEdit :: proc(
	state: ^State,
	signerID: int,
	original: common.ClientMessageID,
	editID: int,
	content: string,
) -> common.MessageEdit {
	return messageEditTestEdit(
		state,
		.Room,
		common.GENERAL_ROOM_ID,
		MESSAGE_EDIT_TEST_PEER,
		signerID,
		original,
		editID,
		content,
	)
}

// The delete of the peer's message in #general, signed by signerID.
@(private = "file")
messageEditTestPeerDeletion :: proc(
	state: ^State,
	signerID: int,
	original: common.ClientMessageID,
) -> common.MessageDeletion {
	return messageEditTestDeletion(
		state,
		.Room,
		common.GENERAL_ROOM_ID,
		MESSAGE_EDIT_TEST_PEER,
		signerID,
		original,
	)
}

@(private = "file")
messageEditTestApplyEdit :: proc(
	state: ^State,
	kind: common.MessageEditsKind,
	roomID, senderID, recipientID, messageID, editCount: int,
	edit: common.MessageEdit,
) {
	event := ClientTransportRuntimeEvent {
		kind        = .MessageEdited,
		serverID    = MESSAGE_EDIT_TEST_SERVER,
		editKind    = kind,
		roomID      = roomID,
		senderID    = senderID,
		peerUserID  = recipientID,
		messageID   = messageID,
		editCount   = editCount,
		messageEdit = edit,
	}
	State_applyRuntimeEvent(state, &event)
	ClientTransportRuntimeEvent_deinit(&event)
}

@(private = "file")
messageEditTestApplyDelete :: proc(
	state: ^State,
	kind: common.MessageEditsKind,
	roomID, senderID, recipientID, messageID: int,
	deletion: common.MessageDeletion,
) {
	event := ClientTransportRuntimeEvent {
		kind            = .MessageDeleted,
		serverID        = MESSAGE_EDIT_TEST_SERVER,
		editKind        = kind,
		roomID          = roomID,
		senderID        = senderID,
		peerUserID      = recipientID,
		messageID       = messageID,
		messageDeletion = deletion,
	}
	State_applyRuntimeEvent(state, &event)
	ClientTransportRuntimeEvent_deinit(&event)
}

@(private = "file")
messageEditTestRoomEntry :: proc(state: ^State, messageID: int) -> ^RoomMessageEntry {
	entry := State_roomMessageEntry(
		state,
		MESSAGE_EDIT_TEST_SERVER,
		common.GENERAL_ROOM_ID,
		messageID,
	)
	assert(entry != nil, fmt.tprintf("expected message %d cached", messageID))
	return entry
}

// D6, D11, D14: a room edit is shown once its author's signature verifies; a forged, moved or
// sealed edit of a plaintext message is not, and the last good version stays.
@(test)
testRoomMessageEditsAreShownOnlyWhenTheirAuthorSigned :: proc(t: ^testing.T) {
	_ = t
	defer free_all(context.temp_allocator)
	state := messageEditTestState()
	defer State_deinit(&state)
	room := common.GENERAL_ROOM_ID
	messageEditTestRoomMessage(&state, MESSAGE_EDIT_TEST_PEER, 10, "hello")
	original := messageEditTestRoomEntry(&state, 10).clientMessageId

	messageEditTestApplyEdit(
		&state,
		.Room,
		room,
		MESSAGE_EDIT_TEST_PEER,
		0,
		10,
		1,
		messageEditTestPeerEdit(&state, MESSAGE_EDIT_TEST_PEER, original, 1, "hello, edited"),
	)
	entry := messageEditTestRoomEntry(&state, 10)
	assert(
		entry.edit.status == .Verified &&
		entry.edit.shownContent == "hello, edited" &&
		entry.editCount == 1 &&
		entry.content == "hello",
		fmt.tprintf("expected the verified edit shown and the original kept, got %v", entry.edit),
	)
	text, placeholder, _ := roomMessageDisplay(&state, MESSAGE_EDIT_TEST_SERVER, entry^)
	assert(
		!placeholder && text == "hello, edited" + MESSAGE_EDITED_SUFFIX,
		fmt.tprintf("expected the edit with its marker, got %q", text),
	)

	// Signed by someone else, moved from another message, or sealed: not shown.
	other := original
	other[3] ~= 0x01
	refused := [?]common.MessageEdit {
		messageEditTestPeerEdit(&state, MESSAGE_EDIT_TEST_OTHER, original, 2, "forged"),
		messageEditTestPeerEdit(&state, MESSAGE_EDIT_TEST_PEER, other, 3, "moved"),
		messageEditTestEdit(
			&state,
			.Room,
			room + 1,
			MESSAGE_EDIT_TEST_PEER,
			MESSAGE_EDIT_TEST_PEER,
			original,
			4,
			"other room",
		),
	}
	for edit, index in refused {
		messageEditTestApplyEdit(
			&state,
			.Room,
			room,
			MESSAGE_EDIT_TEST_PEER,
			0,
			10,
			2 + index,
			edit,
		)
		entry = messageEditTestRoomEntry(&state, 10)
		assert(
			entry.edit.status == .Failed && entry.edit.shownContent == "hello, edited",
			fmt.tprintf("expected refused edit %d not shown, got %v", index, entry.edit),
		)
	}
	text, _, _ = roomMessageDisplay(&state, MESSAGE_EDIT_TEST_SERVER, entry^)
	assert(
		text == "hello, edited" + MESSAGE_EDIT_FAILED_SUFFIX,
		fmt.tprintf("expected the last good version marked, got %q", text),
	)
	sealedEdit := common.MessageEdit {
		id        = 9,
		timestamp = strings.clone("t9"),
		content   = strings.clone(""),
		sealed    = make([]u8, 3),
	}
	messageEditTestApplyEdit(&state, .Room, room, MESSAGE_EDIT_TEST_PEER, 0, 10, 6, sealedEdit)
	assert(
		messageEditTestRoomEntry(&state, 10).edit.status == .Failed,
		"expected a sealed edit of a plaintext message refused (D11)",
	)
	// An edit claimed for another sender, or of a message not cached, changes nothing.
	messageEditTestApplyEdit(
		&state,
		.Room,
		room,
		MESSAGE_EDIT_TEST_OTHER,
		0,
		10,
		7,
		messageEditTestEdit(
			&state,
			.Room,
			room,
			MESSAGE_EDIT_TEST_OTHER,
			MESSAGE_EDIT_TEST_OTHER,
			original,
			10,
			"other",
		),
	)
	assert(messageEditTestRoomEntry(&state, 10).editCount == 6, "expected the other sender ignored")
	messageEditTestApplyEdit(
		&state,
		.Room,
		room,
		MESSAGE_EDIT_TEST_PEER,
		0,
		99,
		1,
		messageEditTestPeerEdit(&state, MESSAGE_EDIT_TEST_PEER, original, 11, "nowhere"),
	)
}

// D6, D7, D13: a tombstone hides the content and reads "Message deleted" only with the author's
// signature; a live message counted unread is taken back out of the count.
@(test)
testRoomMessageTombstonesShowWhoDeletedThem :: proc(t: ^testing.T) {
	_ = t
	defer free_all(context.temp_allocator)
	state := messageEditTestState()
	defer State_deinit(&state)
	room := common.GENERAL_ROOM_ID
	rooms := ClientTransportRuntimeEvent {
		kind     = .RoomListReceived,
		serverID = MESSAGE_EDIT_TEST_SERVER,
	}
	append(
		&rooms.rooms,
		common.RoomSummary {
			id = room,
			name = strings.clone("general"),
			description = strings.clone(""),
			roomType = .ChatAndVoice,
			myPermissions = common.ROOM_PERMISSIONS_DEFAULT,
		},
	)
	State_applyRuntimeEvent(&state, &rooms)
	ClientTransportRuntimeEvent_deinit(&rooms)
	for messageID in ([]int{20, 21, 22}) {
		messageEditTestRoomMessage(&state, MESSAGE_EDIT_TEST_PEER, messageID, "to be deleted")
	}
	summary := State_roomSummary(&state, MESSAGE_EDIT_TEST_SERVER, room)
	assert(summary != nil, "expected the room's summary")
	counted := summary.unreadCount

	signed := messageEditTestRoomEntry(&state, 20).clientMessageId
	messageEditTestApplyDelete(
		&state,
		.Room,
		room,
		MESSAGE_EDIT_TEST_PEER,
		0,
		20,
		messageEditTestPeerDeletion(&state, MESSAGE_EDIT_TEST_PEER, signed),
	)
	messageEditTestApplyDelete(
		&state,
		.Room,
		room,
		MESSAGE_EDIT_TEST_PEER,
		0,
		21,
		common.MessageDeletion{deletedAt = strings.clone("d")},
	)
	forgedID := messageEditTestRoomEntry(&state, 22).clientMessageId
	messageEditTestApplyDelete(
		&state,
		.Room,
		room,
		MESSAGE_EDIT_TEST_PEER,
		0,
		22,
		messageEditTestPeerDeletion(&state, MESSAGE_EDIT_TEST_OTHER, forgedID),
	)
	expected := [?]string {
		MESSAGE_DELETED_TEXT,
		MESSAGE_REMOVED_BY_SERVER_TEXT,
		MESSAGE_REMOVED_BY_SERVER_TEXT,
	}
	for messageID, index in ([]int{20, 21, 22}) {
		entry := messageEditTestRoomEntry(&state, messageID)
		text, placeholder, _ := roomMessageDisplay(&state, MESSAGE_EDIT_TEST_SERVER, entry^)
		assert(
			entry.deleted && entry.content == "" && placeholder && text == expected[index],
			fmt.tprintf("expected message %d to read %q, got %q", messageID, expected[index], text),
		)
	}
	summary = State_roomSummary(&state, MESSAGE_EDIT_TEST_SERVER, room)
	assert(
		counted == 3 && summary.unreadCount == 0,
		fmt.tprintf(
			"expected the deleted messages taken out of 3 unread, got %d",
			summary.unreadCount,
		),
	)
	// A tombstone takes no edit.
	messageEditTestApplyEdit(
		&state,
		.Room,
		room,
		MESSAGE_EDIT_TEST_PEER,
		0,
		20,
		1,
		messageEditTestPeerEdit(&state, MESSAGE_EDIT_TEST_PEER, signed, 1, "zombie"),
	)
	assert(
		messageEditTestRoomEntry(&state, 20).edit.shownContent == "",
		"expected a tombstone to stay one",
	)
}

// D14: a history page brings the latest edit and tombstones, and an already cached message takes
// them from a page fetched again.
@(test)
testRoomHistoryCarriesTheLatestEditAndTombstones :: proc(t: ^testing.T) {
	_ = t
	defer free_all(context.temp_allocator)
	state := messageEditTestState()
	defer State_deinit(&state)
	room := common.GENERAL_ROOM_ID
	page := messageEditTestPage(&state)
	event := ClientTransportRuntimeEvent {
		kind     = .RoomHistoryReceived,
		serverID = MESSAGE_EDIT_TEST_SERVER,
		roomID   = room,
		messages = page,
	}
	State_applyRuntimeEvent(&state, &event)
	ClientTransportRuntimeEvent_deinit(&event)
	edited := messageEditTestRoomEntry(&state, 30)
	assert(
		edited.edit.status == .Verified &&
		edited.edit.shownContent == "second version" &&
		edited.editCount == 2,
		fmt.tprintf("expected history's latest edit shown, got %v", edited.edit),
	)
	tombstone := messageEditTestRoomEntry(&state, 31)
	assert(
		tombstone.deleted && tombstone.edit.deleteStatus == .Author,
		"expected history's signed tombstone",
	)
	_ = room
}

// History page: 30 edited twice (its latest edit signed), 31 deleted by its author.
@(private = "file")
messageEditTestPage :: proc(state: ^State) -> [dynamic]common.StoredChatMessage {
	room := common.GENERAL_ROOM_ID
	page := make([dynamic]common.StoredChatMessage)
	first := common.StoredChatMessage {
		id             = 30,
		senderId       = MESSAGE_EDIT_TEST_PEER,
		senderNickname = strings.clone("peer"),
		roomId         = room,
		timestamp      = strings.clone("t"),
		content        = strings.clone("first version"),
		editCount      = 2,
	}
	testSignRoomMessage(state, MESSAGE_EDIT_TEST_SERVER, &first)
	first.lastEdit = messageEditTestEdit(
		state,
		.Room,
		room,
		MESSAGE_EDIT_TEST_PEER,
		MESSAGE_EDIT_TEST_PEER,
		first.clientMessageId,
		7,
		"second version",
	)
	append(&page, first)
	gone := common.StoredChatMessage {
		id              = 31,
		senderId        = MESSAGE_EDIT_TEST_PEER,
		senderNickname  = strings.clone("peer"),
		roomId          = room,
		timestamp       = strings.clone("t"),
		content         = strings.clone(""),
		clientMessageId = testMessageClientID(31, 2),
		deleted         = true,
	}
	gone.deletion = messageEditTestDeletion(
		state,
		.Room,
		room,
		MESSAGE_EDIT_TEST_PEER,
		MESSAGE_EDIT_TEST_PEER,
		gone.clientMessageId,
	)
	append(&page, gone)
	return page
}

// The edit list is checked edit by edit.
@(test)
testMessageEditListIsCheckedEditByEdit :: proc(t: ^testing.T) {
	_ = t
	defer free_all(context.temp_allocator)
	state := messageEditTestState()
	defer State_deinit(&state)
	room := common.GENERAL_ROOM_ID
	messageEditTestRoomMessage(&state, MESSAGE_EDIT_TEST_PEER, 40, "v0")
	original := messageEditTestRoomEntry(&state, 40).clientMessageId
	event := ClientTransportRuntimeEvent {
		kind      = .MessageEditsReceived,
		serverID  = MESSAGE_EDIT_TEST_SERVER,
		editKind  = .Room,
		roomID    = room,
		messageID = 40,
	}
	append(
		&event.messageEdits,
		messageEditTestPeerEdit(&state, MESSAGE_EDIT_TEST_PEER, original, 1, "v1"),
		messageEditTestPeerEdit(&state, MESSAGE_EDIT_TEST_OTHER, original, 2, "v2"),
	)
	State_applyRuntimeEvent(&state, &event)
	ClientTransportRuntimeEvent_deinit(&event)
	edits, statuses, loaded := State_messageEdits(&state, MESSAGE_EDIT_TEST_SERVER, .Room, room, 40)
	assert(
		loaded &&
		len(edits) == 2 &&
		statuses[0] == .Verified &&
		statuses[1] == .Failed &&
		edits[0].content == "v1",
		fmt.tprintf("expected the list checked edit by edit, got %v", statuses),
	)
}

// What goes out is signed by this profile over the message's own ID; others' messages, sealed
// ones and an admin delete without the role are refused locally.
@(test)
testMessageEditsAndDeletesGoOutSigned :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&messageChangeSendBridgeTestMutex)
	defer sync.mutex_unlock(&messageChangeSendBridgeTestMutex)
	messageChangeSendBridge = messageEditTestBridge
	defer {
		messageChangeSendBridge = ClientServerTransport_sendMessageChange
		delete(messageEditTestSends)
		messageEditTestSends = nil
	}
	defer free_all(context.temp_allocator)
	state := messageEditTestState()
	defer State_deinit(&state)
	room := common.GENERAL_ROOM_ID
	messageEditTestRoomMessage(&state, MESSAGE_EDIT_TEST_SELF, 60, "mine")
	messageEditTestRoomMessage(&state, MESSAGE_EDIT_TEST_PEER, 61, "theirs")
	own := messageEditTestRoomEntry(&state, 60).clientMessageId
	serverKey, _ := testMessageSigner(&state, MESSAGE_EDIT_TEST_SERVER, MESSAGE_EDIT_TEST_SELF)
	selfKey, selfOK := common.identityPublicKeyFromHex(state.config.public_key)
	assert(selfOK, "expected this profile's key")

	failure := State_editRoomMessage(&state, MESSAGE_EDIT_TEST_SERVER, room, 60, "mine, edited")
	assert(
		failure == "" && len(messageEditTestSends) == 1,
		fmt.tprintf("expected the edit sent, got %q", failure),
	)
	edit := messageEditTestSends[0].roomEdit
	assert(
		messageEditTestSends[0].messageType == .ClientEditRoomMessage &&
		edit.messageId == 60 &&
		edit.originalClientMessageId == own &&
		edit.clientMessageId != own &&
		common.verifyRoomMessageEdit(
			common.MessageChangeFields {
				serverIdentityPublicKey = serverKey,
				conversationID = room,
				senderUserID = MESSAGE_EDIT_TEST_SELF,
				original = own,
				edit = edit.clientMessageId,
			},
			"mine, edited",
			selfKey,
			edit.signature,
		),
		"expected the edit signed by this profile over the message's ID",
	)
	failure = State_deleteRoomMessage(&state, MESSAGE_EDIT_TEST_SERVER, room, 60)
	deleteSend := messageEditTestSends[1].roomDelete
	assert(
		failure == "" &&
		common.verifyRoomMessageDelete(
			common.MessageChangeFields {
				serverIdentityPublicKey = serverKey,
				conversationID = room,
				senderUserID = MESSAGE_EDIT_TEST_SELF,
				original = own,
			},
			selfKey,
			deleteSend.signature,
		),
		"expected the delete signed by this profile",
	)
	// Nothing changed locally: the server's notice does that.
	assert(!messageEditTestRoomEntry(&state, 60).deleted, "expected no local delete")

	refusals := [?]string {
		State_editRoomMessage(&state, MESSAGE_EDIT_TEST_SERVER, room, 61, "not mine"),
		State_deleteRoomMessage(&state, MESSAGE_EDIT_TEST_SERVER, room, 61),
		State_deleteRoomMessage(&state, MESSAGE_EDIT_TEST_SERVER, room, 61, asAdmin = true),
		State_editRoomMessage(&state, MESSAGE_EDIT_TEST_SERVER, room, 62, "not loaded"),
		State_editRoomMessage(&state, MESSAGE_EDIT_TEST_SERVER, room, 60, ""),
	}
	expected := [?]string {
		MESSAGE_EDIT_NOT_OWN_MESSAGE,
		MESSAGE_DELETE_NOT_OWN_MESSAGE,
		MESSAGE_DELETE_ADMIN_ONLY_MESSAGE,
		MESSAGE_NOT_LOADED_MESSAGE,
		"Cannot send an empty message",
	}
	for refusal, index in refusals {
		assert(
			refusal == expected[index],
			fmt.tprintf("expected refusal %d %q, got %q", index, expected[index], refusal),
		)
	}
	assert(len(messageEditTestSends) == 2, "expected nothing sent for the refusals")
	// The harness's unchecked admin delete goes out unsigned; the server decides.
	failure = State_deleteRoomMessage(
		&state,
		MESSAGE_EDIT_TEST_SERVER,
		room,
		61,
		asAdmin = true,
		checkRights = false,
	)
	assert(
		failure == "" && messageEditTestSends[2].roomDelete.signature == {},
		"expected an unsigned moderation delete",
	)
	failure = State_fetchMessageEdits(&state, MESSAGE_EDIT_TEST_SERVER, .Room, room, 60)
	assert(
		failure == "" &&
		messageEditTestSends[3].messageType == .ClientFetchMessageEdits &&
		messageEditTestRoomEntry(&state, 60).edit.editsLoading,
		"expected the edit list requested once",
	)
	_ = State_fetchMessageEdits(&state, MESSAGE_EDIT_TEST_SERVER, .Room, room, 60)
	assert(len(messageEditTestSends) == 4, "expected no second request while loading")
}

// Direct messages: an edit verified against the sender's pin, the conversation preview showing
// it, a signed tombstone, and the count taking a deleted message back out.
@(test)
testDirectMessageEditsAndTombstones :: proc(t: ^testing.T) {
	_ = t
	defer free_all(context.temp_allocator)
	state := messageEditTestState()
	defer State_deinit(&state)
	testApplyDirectMessage(
		&state,
		MESSAGE_EDIT_TEST_SERVER,
		70,
		MESSAGE_EDIT_TEST_PEER,
		MESSAGE_EDIT_TEST_SELF,
		"dm hello",
		"peer",
		"self",
	)
	entry := State_directMessageEntry(&state, MESSAGE_EDIT_TEST_SERVER, MESSAGE_EDIT_TEST_PEER, 70)
	assert(entry != nil && entry.security.protection == .Signed, "expected the DM shown")
	original := entry.clientMessageId
	messageEditTestApplyEdit(
		&state,
		.Direct,
		0,
		MESSAGE_EDIT_TEST_PEER,
		MESSAGE_EDIT_TEST_SELF,
		70,
		1,
		messageEditTestEdit(
			&state,
			.Direct,
			MESSAGE_EDIT_TEST_SELF,
			MESSAGE_EDIT_TEST_PEER,
			MESSAGE_EDIT_TEST_PEER,
			original,
			1,
			"dm hello, edited",
		),
	)
	entry = State_directMessageEntry(&state, MESSAGE_EDIT_TEST_SERVER, MESSAGE_EDIT_TEST_PEER, 70)
	text, _ := directMessageText(entry^)
	assert(
		entry.edit.status == .Verified && text == "dm hello, edited" + MESSAGE_EDITED_SUFFIX,
		fmt.tprintf("expected the DM edit shown, got %q", text),
	)
	cache := State_serverDirectCache(&state, MESSAGE_EDIT_TEST_SERVER)
	index := ServerDirectCache_conversationIndex(cache^, MESSAGE_EDIT_TEST_PEER)
	assert(
		index >= 0 && cache.conversations[index].lastContent == "dm hello, edited",
		"expected the preview to show the edit",
	)
	unread := cache.conversations[index].unreadCount

	messageEditTestApplyDelete(
		&state,
		.Direct,
		0,
		MESSAGE_EDIT_TEST_PEER,
		MESSAGE_EDIT_TEST_SELF,
		70,
		messageEditTestDeletion(
			&state,
			.Direct,
			MESSAGE_EDIT_TEST_SELF,
			MESSAGE_EDIT_TEST_PEER,
			MESSAGE_EDIT_TEST_PEER,
			original,
		),
	)
	entry = State_directMessageEntry(&state, MESSAGE_EDIT_TEST_SERVER, MESSAGE_EDIT_TEST_PEER, 70)
	text, _ = directMessageText(entry^)
	assert(
		entry.deleted && entry.content == "" && text == MESSAGE_DELETED_TEXT,
		fmt.tprintf("expected the signed tombstone, got %q", text),
	)
	cache = State_serverDirectCache(&state, MESSAGE_EDIT_TEST_SERVER)
	summary := cache.conversations[index]
	assert(
		summary.lastDeleted && summary.lastContent == "" &&
		summary.unreadCount == max(unread - 1, 0),
		fmt.tprintf("expected the preview tombstoned and not unread, got %v", summary.unreadCount),
	)
}
