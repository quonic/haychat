#+feature dynamic-literals
package client

import "../common"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import "ui"

// Context menus (context_menu.odin): the entries each target gets, admin gating, disabled
// states, a target that went away, and what each action does. Sends go through the existing
// bridges under their test mutexes.

CONTEXT_MENU_TEST_SELF :: 7
CONTEXT_MENU_TEST_PEER :: 8

@(private = "file")
contextMenuTestSends: [dynamic]string

@(private = "file")
contextMenuTestMarkRead :: proc(
	transport: ^ClientServerTransport,
	kind: common.ReadMarkerKind,
	conversationID: int,
	messageID: int,
) -> bool {
	append(&contextMenuTestSends, fmt.aprintf("%v:%d:%d", kind, conversationID, messageID))
	return true
}

// The sends since the last call, joined with commas, then cleared.
@(private = "file")
contextMenuTestTakeSends :: proc() -> string {
	joined := strings.join(contextMenuTestSends[:], ",", context.temp_allocator)
	for send in contextMenuTestSends {
		delete(send)
	}
	clear(&contextMenuTestSends)
	return joined
}

@(private = "file")
contextMenuTestRestore :: proc() {
	readMarkerSendBridge = ClientServerTransport_markRead
	for send in contextMenuTestSends {
		delete(send)
	}
	delete(contextMenuTestSends)
	contextMenuTestSends = nil
}

// A signed-in state on one server with rooms 1 (general) and 2 (lounge), the given admin
// flag, and a directory with the peer.
@(private = "file")
contextMenuTestState :: proc(serverID: int, isAdmin: bool) -> State {
	state := testUpdateStateForServer(testDirectServer(serverID))
	testApplyConnectedAs(&state, serverID, CONTEXT_MENU_TEST_SELF, isAdmin)
	contextMenuTestRooms(&state, serverID, {id = 1, name = "general"}, {id = 2, name = "lounge"})
	testApplyUserList(
		&state,
		serverID,
		{id = CONTEXT_MENU_TEST_SELF, nickname = "self", isOnline = true},
		{id = CONTEXT_MENU_TEST_PEER, nickname = "peer", isOnline = true},
	)
	return state
}

// A room list with read state, as ServerListRooms delivers it.
@(private = "file")
contextMenuTestRooms :: proc(state: ^State, serverID: int, rooms: ..common.RoomSummary) {
	event := ClientTransportRuntimeEvent {
		kind     = .RoomListReceived,
		serverID = serverID,
	}
	for room in rooms {
		clone := room
		clone.name = strings.clone(room.name)
		clone.description = strings.clone(room.description)
		append(&event.rooms, clone)
	}
	State_applyRuntimeEvent(state, &event)
	ClientTransportRuntimeEvent_deinit(&event)
}

// A conversation list with one conversation with the peer.
@(private = "file")
contextMenuTestConversation :: proc(state: ^State, serverID, lastMessageID, unread: int) {
	event := ClientTransportRuntimeEvent {
		kind     = .DirectConversationsReceived,
		serverID = serverID,
	}
	append(
		&event.conversations,
		common.DirectConversationSummary {
			peerUserId = CONTEXT_MENU_TEST_PEER,
			peerNickname = strings.clone("peer"),
			lastMessageID = lastMessageID,
			lastSenderId = CONTEXT_MENU_TEST_PEER,
			lastTimestamp = strings.clone("t"),
			lastContent = strings.clone("last"),
			unreadCount = unread,
		},
	)
	State_applyRuntimeEvent(state, &event)
	ClientTransportRuntimeEvent_deinit(&event)
}

@(private = "file")
contextMenuTestVoice :: proc(state: ^State, serverID, roomID: int, userIDs: ..int) {
	event := ClientTransportRuntimeEvent {
		kind     = .VoiceParticipants,
		serverID = serverID,
		roomID   = roomID,
	}
	for userID in userIDs {
		append(
			&event.voiceParticipants,
			common.VoiceParticipant {
				userId = userID,
				nickname = strings.clone(fmt.tprintf("voice-%d", userID)),
			},
		)
	}
	State_applyRuntimeEvent(state, &event)
	ClientTransportRuntimeEvent_deinit(&event)
}

// The open menu's entries as "Label" or "Label (off)", with "|" for a separator and "!" after
// a danger entry, joined with commas. "" when the menu is not shown.
@(private = "file")
contextMenuTestEntries :: proc(state: ^State, facts: ContextMenuFacts = {}) -> string {
	view := buildContextMenu(state, facts)
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
contextMenuTestExpect :: proc(t: ^testing.T, actual, expected: string, what: string) {
	testing.expectf(t, actual == expected, "%s: expected %q, got %q", what, expected, actual)
}

@(test)
testChannelMenuEntriesAndAdminGating :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	state := contextMenuTestState(931, false)
	defer State_deinit(&state)

	State_openContextMenu(&state, ChannelMenuTarget{931, 2}, {10, 10})
	contextMenuTestExpect(
		t,
		contextMenuTestEntries(&state),
		"Mark as read (off),Join voice,Copy room name",
		"a read channel for a member",
	)

	contextMenuTestRooms(
		&state,
		931,
		{id = 1, name = "general"},
		{id = 2, name = "lounge", unreadCount = 3},
	)
	contextMenuTestExpect(
		t,
		contextMenuTestEntries(&state),
		"Mark as read,Join voice,Copy room name",
		"an unread channel",
	)

	// The admin entries come only with the admin flag.
	testApplyConnectedAs(&state, 931, CONTEXT_MENU_TEST_SELF, true)
	contextMenuTestRooms(&state, 931, {id = 1, name = "general"}, {id = 2, name = "lounge"})
	State_openContextMenu(&state, ChannelMenuTarget{931, 2}, {10, 10})
	contextMenuTestExpect(
		t,
		contextMenuTestEntries(&state),
		"Mark as read (off),Join voice,Copy room name,|Edit room…,Delete room…!",
		"a channel for an admin",
	)

	// Offline, nothing can be marked or joined.
	lost := ClientTransportRuntimeEvent {
		kind     = .Disconnected,
		serverID = 931,
		message  = strings.clone("gone"),
	}
	State_applyRuntimeEvent(&state, &lost)
	ClientTransportRuntimeEvent_deinit(&lost)
	contextMenuTestExpect(
		t,
		contextMenuTestEntries(&state),
		"Mark as read (off),Join voice (off),Copy room name",
		"a channel while disconnected",
	)

	// A room that left the list closes its menu.
	State_openContextMenu(&state, ChannelMenuTarget{931, 99}, {10, 10})
	contextMenuTestExpect(t, contextMenuTestEntries(&state), "", "a room that is gone")
}

@(test)
testChannelMenuActions :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	sync.mutex_lock(&readMarkerSendBridgeTestMutex)
	defer sync.mutex_unlock(&readMarkerSendBridgeTestMutex)
	readMarkerSendBridge = contextMenuTestMarkRead
	defer contextMenuTestRestore()

	state := contextMenuTestState(932, true)
	defer State_deinit(&state)
	contextMenuTestRooms(
		&state,
		932,
		{id = 1, name = "general"},
		{id = 2, name = "lounge", lastReadMessageId = 4, unreadCount = 2},
	)
	now := time.tick_now()

	// Nothing loaded: the whole room is marked with the ID the server clamps, and the
	// automatic mark-read keeps its own bookkeeping.
	State_openContextMenu(&state, ChannelMenuTarget{932, 2}, {10, 10})
	effect := State_runContextMenuAction(&state, .MarkRead, now)
	contextMenuTestExpect(
		t,
		contextMenuTestTakeSends(),
		fmt.tprintf("Room:2:%d", int(CONTEXT_MENU_MARK_ALL_READ_ID)),
		"marking an unloaded room",
	)
	assert(state.contextMenu.target == nil && !effect.keepOpen, "expected the menu closed")
	assert(
		State_readMarkerSendState(&state, .Room, 932, 2).sentMessageID == 0,
		"expected the sentinel kept out of the send bookkeeping",
	)

	// Loaded messages: up to the newest one.
	testApplyRoomChat(&state, 932, 2, CONTEXT_MENU_TEST_PEER, 6, "hello", "peer")
	State_openContextMenu(&state, ChannelMenuTarget{932, 2}, {10, 10})
	_ = State_runContextMenuAction(&state, .MarkRead, now)
	contextMenuTestExpect(t, contextMenuTestTakeSends(), "Room:2:6", "marking a loaded room")

	State_openContextMenu(&state, ChannelMenuTarget{932, 2}, {10, 10})
	effect = State_runContextMenuAction(&state, .CopyRoomName, now)
	contextMenuTestExpect(t, effect.copyText, "lounge", "copying the room name")

	State_openContextMenu(&state, ChannelMenuTarget{932, 2}, {10, 10})
	_ = State_runContextMenuAction(&state, .EditRoom, now)
	assert(state.roomEditor.mode == .Edit && state.roomEditor.roomID == 2, "expected the form")
	assert(!state.roomEditor.confirmDelete, "expected Edit room… not to arm the delete")
	State_closeRoomEditor(&state)

	// Delete room… opens the same form with the delete armed: one more click sends it.
	State_openContextMenu(&state, ChannelMenuTarget{932, 2}, {10, 10})
	_ = State_runContextMenuAction(&state, .DeleteRoom, now)
	assert(state.roomEditor.mode == .Edit && state.roomEditor.roomID == 2, "expected the form")
	assert(state.roomEditor.confirmDelete, "expected the delete armed")
	contextMenuTestExpect(
		t,
		buildRoomEditorView(&state).deleteLabel,
		"Confirm delete",
		"the armed delete button",
	)
}

@(test)
testUserMenusForConversationsMembersSendersAndVoice :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	sync.mutex_lock(&readMarkerSendBridgeTestMutex)
	defer sync.mutex_unlock(&readMarkerSendBridgeTestMutex)
	readMarkerSendBridge = contextMenuTestMarkRead
	defer contextMenuTestRestore()

	state := contextMenuTestState(933, false)
	defer State_deinit(&state)
	now := time.tick_now()

	// A member without a conversation gets no Mark as read.
	State_openContextMenu(&state, MemberMenuTarget{933, CONTEXT_MENU_TEST_PEER}, {10, 10})
	contextMenuTestExpect(
		t,
		contextMenuTestEntries(&state),
		"Send message,Copy name",
		"a member without a conversation",
	)
	effect := State_runContextMenuAction(&state, .CopyName, now)
	contextMenuTestExpect(t, effect.copyText, "peer", "copying a member's name")

	contextMenuTestConversation(&state, 933, 40, 2)
	State_openContextMenu(&state, ConversationMenuTarget{933, CONTEXT_MENU_TEST_PEER}, {10, 10})
	contextMenuTestExpect(
		t,
		contextMenuTestEntries(&state),
		"Send message,Mark as read,Copy name",
		"an unread conversation",
	)
	_ = State_runContextMenuAction(&state, .MarkRead, now)
	contextMenuTestExpect(
		t,
		contextMenuTestTakeSends(),
		fmt.tprintf("Direct:%d:40", CONTEXT_MENU_TEST_PEER),
		"marking a conversation up to its last message",
	)

	State_openContextMenu(&state, ConversationMenuTarget{933, CONTEXT_MENU_TEST_PEER}, {10, 10})
	_ = State_runContextMenuAction(&state, .SendMessage, now)
	assert(state.selected_dm_peer_id == CONTEXT_MENU_TEST_PEER, "expected the conversation open")

	// An account the directory does not know closes its menu.
	State_openContextMenu(&state, MemberMenuTarget{933, 999}, {10, 10})
	contextMenuTestExpect(t, contextMenuTestEntries(&state), "", "an unknown account")

	// Sender names get the member entries; your own name cannot be messaged.
	testApplyRoomChat(&state, 933, 1, CONTEXT_MENU_TEST_SELF, 50, "mine", "self")
	State_openContextMenu(&state, SenderMenuTarget{933, .Room, 1, 50}, {10, 10})
	contextMenuTestExpect(
		t,
		contextMenuTestEntries(&state),
		"Send message (off),Copy name",
		"your own sender name",
	)
	effect = State_runContextMenuAction(&state, .CopyName, now)
	contextMenuTestExpect(t, effect.copyText, "self", "copying your own name")

	// Voice participants: Send message (not to yourself) and Copy name, while they are listed.
	contextMenuTestVoice(&state, 933, 1, CONTEXT_MENU_TEST_SELF, CONTEXT_MENU_TEST_PEER)
	target := VoiceParticipantMenuTarget{933, 1, CONTEXT_MENU_TEST_PEER}
	State_openContextMenu(&state, target, {10, 10})
	contextMenuTestExpect(t, contextMenuTestEntries(&state), "Send message,Copy name", "voice")
	State_openContextMenu(&state, VoiceParticipantMenuTarget{933, 1, CONTEXT_MENU_TEST_SELF}, {})
	contextMenuTestExpect(
		t,
		contextMenuTestEntries(&state),
		"Send message (off),Copy name",
		"yourself in voice",
	)
	contextMenuTestVoice(&state, 933, 1, CONTEXT_MENU_TEST_SELF)
	State_openContextMenu(&state, target, {10, 10})
	contextMenuTestExpect(t, contextMenuTestEntries(&state), "", "a participant who left voice")
}

@(test)
testMessageMenuEntriesAndActions :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	state := contextMenuTestState(934, false)
	defer State_deinit(&state)
	now := time.tick_now()
	testApplyRoomChat(&state, 934, 1, CONTEXT_MENU_TEST_PEER, 60, "line one\nline two", "peer")
	testApplyRoomChat(&state, 934, 1, CONTEXT_MENU_TEST_SELF, 61, "my own", "self")

	target := MessageMenuTarget{934, .Room, 1, 60}
	State_openContextMenu(&state, target, {10, 10})
	contextMenuTestExpect(
		t,
		contextMenuTestEntries(&state),
		"Copy message,Copy name,Quote,|Send message to sender",
		"someone else's message",
	)
	effect := State_runContextMenuAction(&state, .CopyMessage, now)
	contextMenuTestExpect(t, effect.copyText, "line one\nline two", "copying the message")

	State_openContextMenu(&state, target, {10, 10}, "one\nline")
	contextMenuTestExpect(
		t,
		contextMenuTestEntries(&state),
		"Copy message,Copy selected text,Copy name,Quote,|Send message to sender",
		"a message with a selection",
	)
	effect = State_runContextMenuAction(&state, .CopySelection, now)
	contextMenuTestExpect(t, effect.copyText, "one\nline", "copying the selection")
	assert(state.contextMenu.selectionText == "", "expected the selection freed on close")

	// Quote goes on lines of its own after what was typed, and focuses the composer.
	draft := State_selectedRoomDraft(&state)
	testSetDraft(draft, "see")
	State_openContextMenu(&state, target, {10, 10})
	effect = State_runContextMenuAction(&state, .Quote, now)
	contextMenuTestExpect(
		t,
		string(State_selectedRoomDraft(&state)[:]),
		"see\n> line one\n> line two\n",
		"the quoted draft",
	)
	assert(effect.focusInput == ui.idOf("room-input", 934, 1), "expected the composer focused")

	State_openContextMenu(&state, target, {10, 10})
	_ = State_runContextMenuAction(&state, .SendMessage, now)
	assert(state.selected_dm_peer_id == CONTEXT_MENU_TEST_PEER, "expected the sender's DM open")

	// Your own message: no Send message to sender.
	State_openContextMenu(&state, MessageMenuTarget{934, .Room, 1, 61}, {10, 10})
	contextMenuTestExpect(
		t,
		contextMenuTestEntries(&state),
		"Copy message,Copy name,Quote",
		"your own message",
	)

	// Direct messages: the sender's conversation is the one open, so it is not offered.
	peer, self := CONTEXT_MENU_TEST_PEER, CONTEXT_MENU_TEST_SELF
	testApplyDirectMessage(&state, 934, 70, peer, self, "dm", "peer")
	State_openContextMenu(&state, MessageMenuTarget{934, .Direct, peer, 70}, {})
	contextMenuTestExpect(
		t,
		contextMenuTestEntries(&state),
		"Copy message,Copy name,Quote",
		"a direct message",
	)
	effect = State_runContextMenuAction(&state, .Quote, now)
	dm := testDirectCache(&state, 934, CONTEXT_MENU_TEST_PEER)
	contextMenuTestExpect(t, string(dm.draft[:]), "> dm\n", "a quote in the DM draft")
	assert(effect.focusInput == ui.idOf("dm-input", 934, CONTEXT_MENU_TEST_PEER), "expected DM")

	// A message that is no longer cached closes its menu.
	State_openContextMenu(&state, MessageMenuTarget{934, .Room, 1, 999}, {10, 10})
	contextMenuTestExpect(t, contextMenuTestEntries(&state), "", "a message that is gone")
}

@(test)
testQuoteNeverGrowsTheDraftPastTheLimit :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	state := contextMenuTestState(935, false)
	defer State_deinit(&state)
	draft := State_selectedRoomDraft(&state)
	// Four bytes of room: "\n> " fits, the two-byte é after it would only half fit.
	typed := strings.repeat("a", common.CHAT_MESSAGE_MAX_BYTES - 4, context.temp_allocator)
	testSetDraft(draft, typed)
	_ = State_quoteIntoDraft(&state, MessageMenuTarget{935, .Room, 1, 1}, "ééé")
	draft = State_selectedRoomDraft(&state)
	testing.expectf(
		t,
		len(draft) == common.CHAT_MESSAGE_MAX_BYTES - 1,
		"expected the quote cut before a split character, got %d bytes",
		len(draft),
	)
	testing.expect(t, strings.has_suffix(string(draft[:]), "\n> "), "expected the cut quote")
}

@(test)
testServerMenuRetriesAndRemovesAfterConfirmation :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	first := testDirectServer(936)
	second := testDirectServer(937)
	state := testStateWithServers({first, second})
	defer State_deinit(&state)
	testApplyConnected(&state, 936, CONTEXT_MENU_TEST_SELF)
	now := time.tick_now()

	State_openContextMenu(&state, ServerMenuTarget{936}, {10, 10})
	contextMenuTestExpect(
		t,
		contextMenuTestEntries(&state),
		"Copy address,|Remove server…!",
		"a connected server",
	)
	effect := State_runContextMenuAction(&state, .CopyAddress, now)
	contextMenuTestExpect(
		t,
		effect.copyText,
		fmt.tprintf("localhost:%d", common.DEFAULT_SERVER_PORT),
		"copying the address",
	)

	State_openContextMenu(&state, ServerMenuTarget{937}, {10, 10})
	contextMenuTestExpect(
		t,
		contextMenuTestEntries(&state),
		"Retry now,Copy address,|Remove server…!",
		"a server that is not connected",
	)

	// The first click only arms the removal, inside the menu.
	effect = State_runContextMenuAction(&state, .RemoveServer, now)
	assert(effect.keepOpen && state.contextMenu.target != nil, "expected the menu kept open")
	assert(len(state.config.servers) == 2, "expected nothing removed yet")
	contextMenuTestExpect(
		t,
		contextMenuTestEntries(&state),
		"Retry now,Copy address,|Click again to remove!",
		"the armed removal",
	)
	_ = State_runContextMenuAction(&state, .ConfirmRemoveServer, now)
	assert(state.contextMenu.target == nil, "expected the menu closed")
	assert(len(state.config.servers) == 1 && state.config.servers[0].id == 936, "expected removed")

	// A server that is gone closes its menu; a new menu starts unarmed.
	State_openContextMenu(&state, ServerMenuTarget{937}, {10, 10})
	contextMenuTestExpect(t, contextMenuTestEntries(&state), "", "a removed server")
	State_openContextMenu(&state, ServerMenuTarget{936}, {10, 10})
	assert(!state.contextMenu.confirmRemove, "expected a new menu unarmed")
}

@(test)
testTextFieldMenuFollowsTheFieldAndClipboard :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	state := contextMenuTestState(938, false)
	defer State_deinit(&state)
	inputID := ui.idOf("room-input", 938, 1)
	State_openContextMenu(&state, TextFieldMenuTarget{inputID}, {10, 10})

	contextMenuTestExpect(
		t,
		contextMenuTestEntries(&state, {textFieldDrawn = true}),
		"Cut (off),Copy (off),Paste (off),|Select all (off)",
		"an empty field and clipboard",
	)
	facts := ContextMenuFacts {
		textField = {hasSelection = true, hasText = true},
		textFieldDrawn = true,
		clipboardHasText = true,
	}
	contextMenuTestExpect(
		t,
		contextMenuTestEntries(&state, facts),
		"Cut,Copy,Paste,|Select all",
		"a field with a selection",
	)
	// The field is not on screen any more.
	contextMenuTestExpect(t, contextMenuTestEntries(&state), "", "a field that is gone")

	Expected :: struct {
		action:  ContextMenuAction,
		command: ui.TextMenuCommand,
	}
	cases := [?]Expected{{.Cut, .Cut}, {.Copy, .Copy}, {.Paste, .Paste}, {.SelectAll, .SelectAll}}
	for expected in cases {
		State_openContextMenu(&state, TextFieldMenuTarget{inputID}, {10, 10})
		effect := State_runContextMenuAction(&state, expected.action, time.tick_now())
		testing.expectf(
			t,
			effect.textCommand == expected.command && effect.textInputID == inputID,
			"%v: expected the %v command for the field, got %v",
			expected.action,
			expected.command,
			effect,
		)
	}
}

@(test)
testContextMenuRequestsWaitForTheFrameToOpen :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	state := contextMenuTestState(939, false)
	defer State_deinit(&state)
	State_requestContextMenu(&state, ChannelMenuTarget{939, 1}, {5, 6}, "picked")
	assert(state.contextMenu.target == nil, "expected nothing open before the frame ends")
	menu := &state.contextMenu
	State_openContextMenu(&state, menu.pending, menu.pendingPosition, menu.pendingSelection)
	serial := menu.serial
	assert(menu.position == ui.Vec2{5, 6}, "expected the click position kept")
	assert(menu.selectionText == "picked", "expected the selection copied into the menu")
	State_openContextMenu(&state, ServerMenuTarget{939}, {1, 1})
	assert(menu.serial == serial + 1, "expected each menu opened to be a new menu")
	assert(menu.selectionText == "", "expected the old selection freed")
}
