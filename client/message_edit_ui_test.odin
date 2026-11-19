package client

import "../common"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

// The edit and delete GUI's view models (#76 M3, message_edit_ui.odin): the menu entries per
// case, the edit marker and tombstone lines, the inline edit's state machine with the draft
// left alone, the delete confirmation, the edit history rows and the conversation preview.

MESSAGE_EDIT_UI_TEST_SERVER :: 994
MESSAGE_EDIT_UI_TEST_SELF :: 60
MESSAGE_EDIT_UI_TEST_PEER :: 61

// The sends the stubbed bridge saw. Guarded by messageChangeSendBridgeTestMutex.
@(private = "file")
messageEditUITestSends: [dynamic]MessageChangeSend

@(private = "file")
messageEditUITestBridge :: proc(
	transport: ^ClientServerTransport,
	send: MessageChangeSend,
) -> bool {
	copied := send
	copied.roomEdit.content = strings.clone(send.roomEdit.content, context.temp_allocator)
	copied.directEdit.content = strings.clone(send.directEdit.content, context.temp_allocator)
	append(&messageEditUITestSends, copied)
	return true
}

// Signed in (an admin or not) with #general listed with the default grants, and the peer known.
@(private = "file")
messageEditUITestState :: proc(isAdmin: bool) -> State {
	state := testUpdateStateForServer(testDirectServer(MESSAGE_EDIT_UI_TEST_SERVER))
	testApplyConnectedAs(&state, MESSAGE_EDIT_UI_TEST_SERVER, MESSAGE_EDIT_UI_TEST_SELF, isAdmin)
	testMessageSigner(&state, MESSAGE_EDIT_UI_TEST_SERVER, MESSAGE_EDIT_UI_TEST_SELF)
	event := ClientTransportRuntimeEvent {
		kind     = .RoomListReceived,
		serverID = MESSAGE_EDIT_UI_TEST_SERVER,
	}
	append(
		&event.rooms,
		common.RoomSummary {
			id = common.GENERAL_ROOM_ID,
			name = strings.clone("general"),
			description = strings.clone(""),
			roomType = .ChatAndVoice,
			myPermissions = common.ROOM_PERMISSIONS_DEFAULT,
		},
	)
	State_applyRuntimeEvent(&state, &event)
	ClientTransportRuntimeEvent_deinit(&event)
	testApplyUserList(
		&state,
		MESSAGE_EDIT_UI_TEST_SERVER,
		{id = MESSAGE_EDIT_UI_TEST_SELF, nickname = "self", isOnline = true},
		{id = MESSAGE_EDIT_UI_TEST_PEER, nickname = "peer", isOnline = true},
	)
	return state
}

@(private = "file")
messageEditUITestRoomMessage :: proc(state: ^State, senderID, messageID: int, content: string) {
	testApplyRoomChat(
		state,
		MESSAGE_EDIT_UI_TEST_SERVER,
		common.GENERAL_ROOM_ID,
		senderID,
		messageID,
		content,
		senderID == MESSAGE_EDIT_UI_TEST_SELF ? "self" : "peer",
	)
}

@(private = "file")
messageEditUITestEntries :: proc(state: ^State) -> string {
	view := buildContextMenu(state, {})
	if !view.visible {
		return ""
	}
	builder := strings.builder_make(context.temp_allocator)
	for entry, index in view.entries {
		if index > 0 {
			strings.write_byte(&builder, ',')
		}
		if entry.separatorBefore {
			strings.write_string(&builder, "|")
		}
		strings.write_string(&builder, entry.label)
		if entry.danger {
			strings.write_byte(&builder, '!')
		}
		if !entry.enabled {
			strings.write_string(&builder, " (off)")
		}
	}
	return strings.to_string(builder)
}

@(private = "file")
messageEditUITestRoomEntry :: proc(state: ^State, messageID: int) -> ^RoomMessageEntry {
	entry := State_roomMessageEntry(
		state,
		MESSAGE_EDIT_UI_TEST_SERVER,
		common.GENERAL_ROOM_ID,
		messageID,
	)
	assert(entry != nil, fmt.tprintf("expected message %d cached", messageID))
	return entry
}

// A room edit of messageID signed by signerID as the message's author senderID.
@(private = "file")
messageEditUITestEdit :: proc(
	state: ^State,
	senderID, signerID, messageID, editID: int,
	content: string,
) -> common.MessageEdit {
	entry := messageEditUITestRoomEntry(state, messageID)
	serverKey, privateKey := testMessageSigner(state, MESSAGE_EDIT_UI_TEST_SERVER, signerID)
	edit := common.MessageEdit {
		id              = editID,
		clientMessageId = testMessageClientID(2000 + editID, 7),
		timestamp       = strings.clone("2026-11-19 10:05:00+00"),
		content         = strings.clone(content),
	}
	ok: bool
	edit.signature, ok = common.signRoomMessageEdit(
		common.MessageChangeFields {
			serverIdentityPublicKey = serverKey,
			conversationID = common.GENERAL_ROOM_ID,
			senderUserID = senderID,
			original = entry.clientMessageId,
			edit = edit.clientMessageId,
		},
		content,
		privateKey,
	)
	assert(ok, "expected the test edit to sign")
	return edit
}

@(private = "file")
messageEditUITestApplyEdit :: proc(
	state: ^State,
	senderID, messageID, editCount: int,
	edit: common.MessageEdit,
) {
	event := ClientTransportRuntimeEvent {
		kind        = .MessageEdited,
		serverID    = MESSAGE_EDIT_UI_TEST_SERVER,
		editKind    = .Room,
		roomID      = common.GENERAL_ROOM_ID,
		senderID    = senderID,
		messageID   = messageID,
		editCount   = editCount,
		messageEdit = edit,
	}
	State_applyRuntimeEvent(state, &event)
	ClientTransportRuntimeEvent_deinit(&event)
}

// A tombstone of a room message, signed by its author when signed is set (D6).
@(private = "file")
messageEditUITestApplyDelete :: proc(state: ^State, senderID, messageID: int, signed: bool) {
	deletion := common.MessageDeletion {
		deletedAt = strings.clone("d"),
	}
	if signed {
		entry := messageEditUITestRoomEntry(state, messageID)
		serverKey, privateKey := testMessageSigner(state, MESSAGE_EDIT_UI_TEST_SERVER, senderID)
		ok: bool
		deletion.signature, ok = common.signRoomMessageDelete(
			common.MessageChangeFields {
				serverIdentityPublicKey = serverKey,
				conversationID = common.GENERAL_ROOM_ID,
				senderUserID = senderID,
				original = entry.clientMessageId,
			},
			privateKey,
		)
		assert(ok, "expected the test delete to sign")
	}
	event := ClientTransportRuntimeEvent {
		kind            = .MessageDeleted,
		serverID        = MESSAGE_EDIT_UI_TEST_SERVER,
		editKind        = .Room,
		roomID          = common.GENERAL_ROOM_ID,
		senderID        = senderID,
		messageID       = messageID,
		messageDeletion = deletion,
	}
	State_applyRuntimeEvent(state, &event)
	ClientTransportRuntimeEvent_deinit(&event)
}

@(private = "file")
messageEditUITestExpect :: proc(t: ^testing.T, actual, expected: string, what: string) {
	testing.expectf(t, actual == expected, "%s: expected %q, got %q", what, expected, actual)
}

// The rights per case (pure): the author edits what opened and may be sent, deletes what is not
// a tombstone; an admin deletes others' room messages only (D5); nothing while disconnected.
@(test)
testMessageChangeRightsPerCase :: proc(t: ^testing.T) {
	Case :: struct {
		facts:                         MessageChangeFacts,
		canEdit, canDelete, canAdmin:  bool,
		what:                          string,
	}
	cases := [?]Case {
		{{kind = .Room, own = true, opened = true, connected = true, roomSends = true},
			true, true, false, "own room message"},
		{{kind = .Room, own = true, opened = true, connected = true, roomSends = false},
			false, true, false, "own message in a read-only room"},
		{{kind = .Room, own = true, opened = false, connected = true, roomSends = true},
			false, true, false, "own sealed message that did not open"},
		{{kind = .Room, own = true, opened = true, connected = false, roomSends = true},
			false, false, false, "not connected"},
		{{kind = .Room, own = true, deleted = true, opened = true, connected = true},
			false, false, false, "a tombstone"},
		{{kind = .Room, opened = true, connected = true, roomSends = true},
			false, false, false, "someone else's room message"},
		{{kind = .Room, opened = true, connected = true, isAdmin = true},
			false, false, true, "an admin on someone else's room message"},
		{{kind = .Room, deleted = true, connected = true, isAdmin = true},
			false, false, false, "an admin on a tombstone"},
		{{kind = .Direct, own = true, opened = true, connected = true},
			true, true, false, "own direct message"},
		{{kind = .Direct, opened = true, connected = true, isAdmin = true},
			false, false, false, "an admin on the peer's direct message (D5)"},
	}
	for c in cases {
		rights := messageChangeRightsFor(c.facts)
		testing.expectf(
			t,
			rights.canEdit == c.canEdit &&
			rights.canDelete == c.canDelete &&
			rights.canAdminDelete == c.canAdmin,
			"%s: expected edit %v delete %v admin %v, got %v",
			c.what,
			c.canEdit,
			c.canDelete,
			c.canAdmin,
			rights,
		)
	}
}

// The message menu: Edit message and Delete message… on your own messages, Delete message… for
// admins on others' room messages only, nothing for a tombstone; each action opens what it
// says.
@(test)
testMessageMenuOffersEditAndDelete :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	for isAdmin in ([2]bool{false, true}) {
		state := messageEditUITestState(isAdmin)
		defer State_deinit(&state)
		server := MESSAGE_EDIT_UI_TEST_SERVER
		room := common.GENERAL_ROOM_ID
		messageEditUITestRoomMessage(&state, MESSAGE_EDIT_UI_TEST_SELF, 10, "mine")
		messageEditUITestRoomMessage(&state, MESSAGE_EDIT_UI_TEST_PEER, 11, "theirs")
		testApplyDirectMessage(
			&state,
			server,
			20,
			MESSAGE_EDIT_UI_TEST_SELF,
			MESSAGE_EDIT_UI_TEST_PEER,
			"my dm",
		)
		testApplyDirectMessage(
			&state,
			server,
			21,
			MESSAGE_EDIT_UI_TEST_PEER,
			MESSAGE_EDIT_UI_TEST_SELF,
			"their dm",
		)

		State_openContextMenu(&state, MessageMenuTarget{server, .Room, room, 10}, {})
		messageEditUITestExpect(
			t,
			messageEditUITestEntries(&state),
			"Copy message,Copy name,Quote,|Edit message,Delete message…!",
			"your own room message",
		)
		State_openContextMenu(&state, MessageMenuTarget{server, .Room, room, 11}, {})
		want := "Copy message,Copy name,Quote,|Send message to sender"
		if isAdmin {
			want = "Copy message,Copy name,Quote,|Send message to sender,|Delete message…!"
		}
		messageEditUITestExpect(t, messageEditUITestEntries(&state), want, "someone else's")
		State_openContextMenu(
			&state,
			MessageMenuTarget{server, .Direct, MESSAGE_EDIT_UI_TEST_PEER, 20},
			{},
		)
		messageEditUITestExpect(
			t,
			messageEditUITestEntries(&state),
			"Copy message,Copy name,Quote,|Edit message,Delete message…!",
			"your own direct message",
		)
		// D5: never an admin delete of a direct message.
		State_openContextMenu(
			&state,
			MessageMenuTarget{server, .Direct, MESSAGE_EDIT_UI_TEST_PEER, 21},
			{},
		)
		messageEditUITestExpect(
			t,
			messageEditUITestEntries(&state),
			"Copy message,Copy name,Quote",
			"the peer's direct message",
		)

		if isAdmin {
			// The admin's Delete message… opens the confirmation on the admin path.
			State_openContextMenu(&state, MessageMenuTarget{server, .Room, room, 11}, {})
			_ = State_runContextMenuAction(&state, .AdminDeleteMessage, time.tick_now())
			dialog := state.messageDeleteDialog
			assert(
				dialog.open && dialog.asAdmin && dialog.messageID == 11,
				fmt.tprintf("expected the admin confirmation for 11, got %v", dialog),
			)
			view := buildMessageDeleteDialogView(&state)
			assert(
				strings.contains(view.text, MESSAGE_REMOVED_BY_SERVER_TEXT) &&
				strings.contains(view.text, "edit history"),
				fmt.tprintf("expected the admin text to say what members see, got %q", view.text),
			)
			State_closeMessageDeleteDialog(&state)
		}

		// Edit message starts the inline edit; Delete message… opens the author's confirmation.
		State_openContextMenu(&state, MessageMenuTarget{server, .Room, room, 10}, {})
		_ = State_runContextMenuAction(&state, .EditMessage, time.tick_now())
		editor := State_messageEditIn(&state, server, .Room, room)
		assert(
			editor != nil && editor.messageID == 10 && string(editor.text[:]) == "mine",
			"expected the inline edit of message 10 with its text",
		)
		State_cancelMessageEdit(&state)
		State_openContextMenu(&state, MessageMenuTarget{server, .Room, room, 10}, {})
		_ = State_runContextMenuAction(&state, .DeleteMessage, time.tick_now())
		assert(
			state.messageDeleteDialog.open && !state.messageDeleteDialog.asAdmin,
			"expected the author's delete confirmation",
		)
		view := buildMessageDeleteDialogView(&state)
		assert(
			strings.contains(view.text, MESSAGE_DELETED_TEXT) &&
			strings.contains(view.text, "edit history"),
			fmt.tprintf("expected the author's text, got %q", view.text),
		)
		State_closeMessageDeleteDialog(&state)

		// A tombstone keeps only Copy name (and the sender's conversation).
		messageEditUITestApplyDelete(&state, MESSAGE_EDIT_UI_TEST_SELF, 10, signed = true)
		State_openContextMenu(&state, MessageMenuTarget{server, .Room, room, 10}, {})
		messageEditUITestExpect(t, messageEditUITestEntries(&state), "Copy name", "a tombstone")
	}
}

// The transcript's lines: "(edited)" after a verified edit (the text itself unmarked), the
// failed note when the latest edit did not verify, and a tombstone as one italic placeholder
// with no marker and no files, "Message deleted" signed and "Removed by the server" not.
@(test)
testEditMarkerAndTombstoneLines :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	state := messageEditUITestState(true)
	defer State_deinit(&state)
	state.selected_server_id = MESSAGE_EDIT_UI_TEST_SERVER
	state.selected_channel_id = common.GENERAL_ROOM_ID
	messageEditUITestRoomMessage(&state, MESSAGE_EDIT_UI_TEST_PEER, 30, "first")
	messageEditUITestRoomMessage(&state, MESSAGE_EDIT_UI_TEST_PEER, 31, "second")
	messageEditUITestRoomMessage(&state, MESSAGE_EDIT_UI_TEST_PEER, 32, "third")
	messageEditUITestApplyEdit(
		&state,
		MESSAGE_EDIT_UI_TEST_PEER,
		30,
		1,
		messageEditUITestEdit(&state, MESSAGE_EDIT_UI_TEST_PEER, MESSAGE_EDIT_UI_TEST_PEER, 30, 1,
			"first, edited"),
	)
	// Signed by someone else: not shown, and the last good version is marked.
	messageEditUITestApplyEdit(
		&state,
		MESSAGE_EDIT_UI_TEST_PEER,
		31,
		1,
		messageEditUITestEdit(&state, MESSAGE_EDIT_UI_TEST_PEER, MESSAGE_EDIT_UI_TEST_SELF, 31, 2,
			"forged"),
	)
	messageEditUITestApplyDelete(&state, MESSAGE_EDIT_UI_TEST_PEER, 32, signed = false)

	view := buildRoomView(&state)
	lines: [3]TranscriptLine
	for line in view.lines {
		if line.messageID >= 30 && line.messageID <= 32 {
			lines[line.messageID - 30] = line
		}
	}
	assert(
		lines[0].content == "first, edited" &&
		lines[0].marker == MESSAGE_EDIT_MARKER &&
		!lines[0].markerFailed,
		fmt.tprintf("expected the edit with its marker, got %v", lines[0]),
	)
	assert(
		lines[1].content == "second" &&
		lines[1].marker == MESSAGE_EDIT_FAILED_MARKER &&
		lines[1].markerFailed,
		fmt.tprintf("expected the last good version marked failed, got %v", lines[1]),
	)
	assert(
		lines[2].content == MESSAGE_REMOVED_BY_SERVER_TEXT &&
		lines[2].tombstone &&
		lines[2].placeholder &&
		lines[2].marker == "" &&
		len(lines[2].cards) == 0,
		fmt.tprintf("expected an unsigned tombstone, got %v", lines[2]),
	)
	messageEditUITestRoomMessage(&state, MESSAGE_EDIT_UI_TEST_PEER, 33, "fourth")
	messageEditUITestApplyDelete(&state, MESSAGE_EDIT_UI_TEST_PEER, 33, signed = true)
	entry := messageEditUITestRoomEntry(&state, 33)
	messageEditUITestExpect(t, messageDeletedText(entry.edit), MESSAGE_DELETED_TEXT, "signed")
	marker, _ := messageEditMarker(entry.edit, 3, true)
	messageEditUITestExpect(t, marker, "", "a tombstone's marker")
	pending, _ := messageEditMarker(MessageEditView{status = .Pending}, 1, false)
	messageEditUITestExpect(t, pending, MESSAGE_EDIT_PENDING_MARKER, "a pending edit's marker")
}

// The inline edit: it starts with the shown text and leaves the draft alone; Enter with the
// same text just closes, empty text is refused for a message without files, a new text goes out
// as the edit and closes the bar; Esc cancels; Up edits the newest own message; the draft is
// the same after each.
@(test)
testInlineEditStateMachineKeepsTheDraft :: proc(t: ^testing.T) {
	sync.mutex_lock(&messageChangeSendBridgeTestMutex)
	defer sync.mutex_unlock(&messageChangeSendBridgeTestMutex)
	messageChangeSendBridge = messageEditUITestBridge
	defer {
		messageChangeSendBridge = ClientServerTransport_sendMessageChange
		delete(messageEditUITestSends)
		messageEditUITestSends = nil
	}
	defer free_all(context.temp_allocator)
	state := messageEditUITestState(false)
	defer State_deinit(&state)
	server := MESSAGE_EDIT_UI_TEST_SERVER
	room := common.GENERAL_ROOM_ID
	state.selected_server_id = server
	state.selected_channel_id = room
	messageEditUITestRoomMessage(&state, MESSAGE_EDIT_UI_TEST_SELF, 40, "older")
	messageEditUITestRoomMessage(&state, MESSAGE_EDIT_UI_TEST_SELF, 41, "newest")
	messageEditUITestRoomMessage(&state, MESSAGE_EDIT_UI_TEST_PEER, 42, "the peer's")
	testSetDraft(State_selectedRoomDraft(&state), "half a thought")

	// Up in the empty composer: the newest message of this account, not the peer's.
	failure := State_editNewestOwnMessage(&state, server, .Room, room)
	editor := State_messageEditIn(&state, server, .Room, room)
	assert(
		failure == "" && editor != nil && editor.messageID == 41 && editor.focusPending,
		fmt.tprintf("expected the newest own message in the editor, got %q %v", failure, editor),
	)
	messageEditUITestExpect(t, string(editor.text[:]), "newest", "the editor's text")
	messageEditUITestExpect(
		t,
		string(State_selectedRoomDraft(&state)[:]),
		"half a thought",
		"the draft while editing",
	)

	// Unchanged: closes without sending.
	State_submitMessageEdit(&state)
	assert(
		State_messageEditIn(&state, server, .Room, room) == nil &&
		len(messageEditUITestSends) == 0 &&
		state.messageEditComposer.refocusComposer,
		"expected an unchanged edit to close without sending",
	)

	// Empty: refused, and the bar stays.
	_ = State_beginMessageEdit(&state, server, .Room, room, 40)
	editor = State_messageEditIn(&state, server, .Room, room)
	clear(&editor.text)
	append(&editor.text, "   ")
	State_submitMessageEdit(&state)
	editor = State_messageEditIn(&state, server, .Room, room)
	assert(
		editor != nil && editor.status == MESSAGE_EDIT_EMPTY_TEXT && editor.statusError,
		"expected an empty edit refused with the bar open",
	)
	assert(len(messageEditUITestSends) == 0, "expected nothing sent for an empty edit")

	// A new text: sent as the edit of 40, and the bar closes (the edit appears with the
	// server's notice).
	clear(&editor.text)
	append(&editor.text, "older, edited")
	State_submitMessageEdit(&state)
	assert(
		State_messageEditIn(&state, server, .Room, room) == nil &&
		len(messageEditUITestSends) == 1 &&
		messageEditUITestSends[0].messageType == .ClientEditRoomMessage &&
		messageEditUITestSends[0].roomEdit.messageId == 40 &&
		messageEditUITestSends[0].roomEdit.content == "older, edited",
		"expected the edit sent and the bar closed",
	)
	entry := messageEditUITestRoomEntry(&state, 40)
	messageEditUITestExpect(t, entry.content, "older", "the message before the notice")
	messageEditUITestExpect(
		t,
		string(State_selectedRoomDraft(&state)[:]),
		"half a thought",
		"the draft after the save",
	)

	// Cancel: nothing sent, the draft is back as it was.
	_ = State_beginMessageEdit(&state, server, .Room, room, 41)
	editor = State_messageEditIn(&state, server, .Room, room)
	append(&editor.text, " and more")
	State_cancelMessageEdit(&state)
	assert(
		State_messageEditIn(&state, server, .Room, room) == nil &&
		len(messageEditUITestSends) == 1,
		"expected a cancel to send nothing",
	)
	messageEditUITestExpect(
		t,
		string(State_selectedRoomDraft(&state)[:]),
		"half a thought",
		"the draft after a cancel",
	)

	// Someone else's message cannot be edited; a message deleted while it is edited closes the
	// bar.
	failure = State_beginMessageEdit(&state, server, .Room, room, 42)
	messageEditUITestExpect(t, failure, MESSAGE_EDIT_NOT_OWN_MESSAGE, "the peer's message")
	_ = State_beginMessageEdit(&state, server, .Room, room, 41)
	messageEditUITestApplyDelete(&state, MESSAGE_EDIT_UI_TEST_SELF, 41, signed = true)
	State_messageEditPoll(&state)
	assert(
		State_messageEditIn(&state, server, .Room, room) == nil,
		"expected the bar closed once its message was deleted",
	)
	// Up skips the tombstone and goes to the older message.
	failure = State_editNewestOwnMessage(&state, server, .Room, room)
	editor = State_messageEditIn(&state, server, .Room, room)
	assert(
		failure == "" && editor != nil && editor.messageID == 40,
		"expected Up to skip the tombstone",
	)
}

// An encrypted DM's edit waiting for the peer's key keeps the bar open with the wait, and a
// plaintext DM's edit goes out signed.
@(test)
testInlineDirectEditGoesOutOrWaits :: proc(t: ^testing.T) {
	sync.mutex_lock(&messageChangeSendBridgeTestMutex)
	defer sync.mutex_unlock(&messageChangeSendBridgeTestMutex)
	messageChangeSendBridge = messageEditUITestBridge
	defer {
		messageChangeSendBridge = ClientServerTransport_sendMessageChange
		delete(messageEditUITestSends)
		messageEditUITestSends = nil
	}
	defer free_all(context.temp_allocator)
	state := messageEditUITestState(false)
	defer State_deinit(&state)
	server := MESSAGE_EDIT_UI_TEST_SERVER
	peer := MESSAGE_EDIT_UI_TEST_PEER
	testApplyDirectMessage(&state, server, 50, MESSAGE_EDIT_UI_TEST_SELF, peer, "plain dm")
	failure := State_beginMessageEdit(&state, server, .Direct, peer, 50)
	editor := State_messageEditIn(&state, server, .Direct, peer)
	assert(failure == "" && editor != nil, "expected the DM edit to open")
	clear(&editor.text)
	append(&editor.text, "plain dm, edited")
	State_submitMessageEdit(&state)
	assert(
		State_messageEditIn(&state, server, .Direct, peer) == nil &&
		len(messageEditUITestSends) == 1 &&
		messageEditUITestSends[0].messageType == .ClientEditDirectMessage &&
		messageEditUITestSends[0].directEdit.content == "plain dm, edited",
		"expected the plaintext DM edit sent",
	)

	// The waiting state (State_editDirectMessage's "Setting up encryption…") keeps the bar.
	_ = State_beginMessageEdit(&state, server, .Direct, peer, 50)
	editor = State_messageEditIn(&state, server, .Direct, peer)
	editor.waitingForKey = true
	State_messageEditPoll(&state)
	editor = State_messageEditIn(&state, server, .Direct, peer)
	assert(editor != nil, "expected the bar to stay while the key is decided")
}

// The delete confirmation: Delete sends and waits, a refusal naming the message stays in it,
// and the tombstone closes it.
@(test)
testMessageDeleteDialogSendsAndCloses :: proc(t: ^testing.T) {
	sync.mutex_lock(&messageChangeSendBridgeTestMutex)
	defer sync.mutex_unlock(&messageChangeSendBridgeTestMutex)
	messageChangeSendBridge = messageEditUITestBridge
	defer {
		messageChangeSendBridge = ClientServerTransport_sendMessageChange
		delete(messageEditUITestSends)
		messageEditUITestSends = nil
	}
	defer free_all(context.temp_allocator)
	state := messageEditUITestState(true)
	defer State_deinit(&state)
	server := MESSAGE_EDIT_UI_TEST_SERVER
	room := common.GENERAL_ROOM_ID
	messageEditUITestRoomMessage(&state, MESSAGE_EDIT_UI_TEST_PEER, 60, "theirs")
	assert(
		!State_openMessageDeleteDialog(&state, server, .Room, room, 60, asAdmin = false),
		"expected no author delete of someone else's message",
	)
	assert(
		State_openMessageDeleteDialog(&state, server, .Room, room, 60, asAdmin = true),
		"expected the admin confirmation",
	)
	State_submitMessageDeleteDialog(&state)
	view := buildMessageDeleteDialogView(&state)
	assert(
		view.busy &&
		view.status == MESSAGE_DELETE_WAITING_TEXT &&
		len(messageEditUITestSends) == 1 &&
		messageEditUITestSends[0].messageType == .ClientDeleteRoomMessage &&
		messageEditUITestSends[0].roomDelete.signature == {},
		"expected an unsigned admin delete sent and the dialog waiting",
	)
	refusal := common.messageRefusal(common.MESSAGE_NOT_FOUND_MESSAGE, 60)
	defer delete(refusal)
	State_messageChangeProtocolError(&state, server, "something else (message 61)")
	assert(buildMessageDeleteDialogView(&state).busy, "expected another message's refusal ignored")
	State_messageChangeProtocolError(&state, server, refusal)
	view = buildMessageDeleteDialogView(&state)
	assert(
		!view.busy && view.statusError && view.status == refusal,
		fmt.tprintf("expected the refusal in the dialog, got %v", view),
	)
	State_submitMessageDeleteDialog(&state)
	messageEditUITestApplyDelete(&state, MESSAGE_EDIT_UI_TEST_PEER, 60, signed = false)
	assert(buildMessageDeleteDialogView(&state).done, "expected the tombstone to close it")
}

// The edit history: loading until the list arrives, then the original and each edit oldest
// first with its time; a pending edit reads "Waiting for key…", a failed one "This edit could
// not be verified", and the failed note shows when the shown version is not the latest.
@(test)
testEditHistoryRows :: proc(t: ^testing.T) {
	sync.mutex_lock(&messageChangeSendBridgeTestMutex)
	defer sync.mutex_unlock(&messageChangeSendBridgeTestMutex)
	messageChangeSendBridge = messageEditUITestBridge
	defer {
		messageChangeSendBridge = ClientServerTransport_sendMessageChange
		delete(messageEditUITestSends)
		messageEditUITestSends = nil
	}
	defer free_all(context.temp_allocator)
	state := messageEditUITestState(false)
	defer State_deinit(&state)
	server := MESSAGE_EDIT_UI_TEST_SERVER
	room := common.GENERAL_ROOM_ID
	peer := MESSAGE_EDIT_UI_TEST_PEER
	messageEditUITestRoomMessage(&state, peer, 70, "v0")
	State_openEditHistory(&state, server, .Room, room, 70, {}, pinned = false)
	assert(
		len(messageEditUITestSends) == 1 &&
		messageEditUITestSends[0].messageType == .ClientFetchMessageEdits,
		"expected the edits fetched on first open",
	)
	view := buildEditHistoryView(&state, state.editHistory)
	assert(view.visible && view.loading, "expected the history loading")
	State_openEditHistory(&state, server, .Room, room, 70, {}, pinned = true)
	assert(
		len(messageEditUITestSends) == 1 && state.editHistory.pinned,
		"expected no second fetch, and a click to pin it",
	)

	event := ClientTransportRuntimeEvent {
		kind      = .MessageEditsReceived,
		serverID  = server,
		editKind  = .Room,
		roomID    = room,
		messageID = 70,
	}
	append(&event.messageEdits, messageEditUITestEdit(&state, peer, peer, 70, 1, "v1"))
	append(
		&event.messageEdits,
		messageEditUITestEdit(&state, peer, MESSAGE_EDIT_UI_TEST_SELF, 70, 2, "forged"),
	)
	State_applyRuntimeEvent(&state, &event)
	ClientTransportRuntimeEvent_deinit(&event)

	view = buildEditHistoryView(&state, state.editHistory)
	assert(
		view.visible && !view.loading && len(view.rows) == 3,
		fmt.tprintf("expected three versions, got %v", view),
	)
	messageEditUITestExpect(t, view.rows[0].label, MESSAGE_EDIT_HISTORY_ORIGINAL, "the first")
	messageEditUITestExpect(t, view.rows[0].content, "v0", "the original's text")
	messageEditUITestExpect(t, view.rows[1].label, "Edit 1", "the second")
	messageEditUITestExpect(t, view.rows[1].content, "v1", "the first edit's text")
	messageEditUITestExpect(t, view.rows[1].time, "2026-11-19 10:05 UTC", "the edit's time")
	assert(
		view.rows[2].failed &&
		view.rows[2].note == MESSAGE_EDIT_UNVERIFIED_TEXT &&
		view.rows[2].content == "",
		fmt.tprintf("expected the forged edit unverified, got %v", view.rows[2]),
	)

	// A pending edit (a sealed one waiting for its key) and the failed latest edit's note.
	entry := messageEditUITestRoomEntry(&state, 70)
	entry.edit.editStatuses[1] = .Pending
	entry.edit.status = .Failed
	view = buildEditHistoryView(&state, state.editHistory)
	assert(
		view.rows[2].note == MESSAGE_EDIT_WAITING_TEXT &&
		view.failedNote == MESSAGE_EDIT_FAILED_NOTE,
		fmt.tprintf("expected the waiting edit and the failed note, got %v", view),
	)

	// A tombstone has no history.
	messageEditUITestApplyDelete(&state, peer, 70, signed = true)
	view = buildEditHistoryView(&state, state.editHistory)
	assert(!view.visible, "expected no history for a tombstone")
}

// The conversation list's preview: the latest verified version, and a tombstone's sentence.
@(test)
testDirectPreviewShowsEditsAndTombstones :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	state := messageEditUITestState(false)
	defer State_deinit(&state)
	server := MESSAGE_EDIT_UI_TEST_SERVER
	peer := MESSAGE_EDIT_UI_TEST_PEER
	testApplyDirectMessage(&state, server, 80, peer, MESSAGE_EDIT_UI_TEST_SELF, "hello there")
	cache := State_serverDirectCache(&state, server)
	index := ServerDirectCache_conversationIndex(cache^, peer)
	assert(index >= 0, "expected the conversation listed")
	messageEditUITestExpect(
		t,
		State_directPreviewText(&state, server, cache.conversations[index]),
		"hello there",
		"the preview",
	)
	summary := cache.conversations[index]
	summary.lastDeleted = true
	messageEditUITestExpect(
		t,
		State_directPreviewText(&state, server, summary),
		MESSAGE_REMOVED_BY_SERVER_TEXT,
		"an unsigned tombstone",
	)
	serverKey, privateKey := testMessageSigner(&state, server, peer)
	ok: bool
	summary.lastDeletion.signature, ok = common.signDirectMessageDelete(
		common.MessageChangeFields {
			serverIdentityPublicKey = serverKey,
			conversationID = MESSAGE_EDIT_UI_TEST_SELF,
			senderUserID = peer,
			original = summary.lastClientMessageId,
		},
		privateKey,
	)
	assert(ok, "expected the delete to sign")
	messageEditUITestExpect(
		t,
		State_directPreviewText(&state, server, summary),
		MESSAGE_DELETED_TEXT,
		"a signed tombstone",
	)

	// The conversation row: a deleted newest message is no "Unencrypted" plaintext.
	state.selected_server_id = server
	cache.conversations[index].lastDeleted = true
	cache.conversations[index].security = {protection = .Signed}
	found := false
	for row in buildSidebarRows(&state) {
		if row.kind == .Conversation && row.id == peer {
			found = true
			assert(
				!row.previewUnencrypted && row.preview == MESSAGE_REMOVED_BY_SERVER_TEXT,
				fmt.tprintf("expected a tombstone row without the badge, got %v", row),
			)
		}
	}
	assert(found, "expected the conversation's row")
	cache.conversations[index].lastDeleted = false
	long := strings.repeat("é", 60, context.temp_allocator)
	summary.lastDeleted = false
	summary.lastContent = long
	preview := State_directPreviewText(&state, server, summary)
	assert(
		len(preview) <= DIRECT_PREVIEW_MAX_BYTES + len("…") && strings.has_suffix(preview, "…"),
		fmt.tprintf("expected a cut preview, got %q", preview),
	)
}
