#+feature dynamic-literals
package client

import "../common"
import "core:encoding/cbor"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

// Read state: badges from the server's lists, live counting, marking the viewed conversation
// read (with its throttle), and ServerReadMarker from another device.

readMarkerSendBridgeTestMutex: sync.Mutex

ReadMarkerTestSend :: struct {
	kind:           common.ReadMarkerKind,
	conversationID: int,
	messageID:      int,
}

@(private = "file")
readMarkerTestSends: [dynamic]ReadMarkerTestSend

@(private = "file")
readMarkerTestStub :: proc(
	transport: ^ClientServerTransport,
	kind: common.ReadMarkerKind,
	conversationID: int,
	messageID: int,
) -> bool {
	append(&readMarkerTestSends, ReadMarkerTestSend{kind, conversationID, messageID})
	return true
}

READ_MARKER_TEST_SEND_FAILURE :: "test send failure"

// A bridge whose sends always fail and, like the real send, say why in lastError.
@(private = "file")
readMarkerTestFailingStub :: proc(
	transport: ^ClientServerTransport,
	kind: common.ReadMarkerKind,
	conversationID: int,
	messageID: int,
) -> bool {
	append(&readMarkerTestSends, ReadMarkerTestSend{kind, conversationID, messageID})
	ClientServerTransport_setLastError(transport, READ_MARKER_TEST_SEND_FAILURE)
	return false
}

// Swaps in the recording stub. Call with readMarkerSendBridgeTestMutex held; undo with
// testReadMarkerRestore.
@(private = "file")
testReadMarkerUseStub :: proc() {
	clear(&readMarkerTestSends)
	readMarkerSendBridge = readMarkerTestStub
}

@(private = "file")
testReadMarkerRestore :: proc() {
	readMarkerSendBridge = ClientServerTransport_markRead
	delete(readMarkerTestSends)
	readMarkerTestSends = nil
}

// The sends since the last call, as "kind:id:message" joined with commas, then cleared.
@(private = "file")
testReadMarkerTakeSends :: proc() -> string {
	builder := strings.builder_make(context.temp_allocator)
	for send, index in readMarkerTestSends {
		if index > 0 {
			strings.write_byte(&builder, ',')
		}
		fmt.sbprintf(&builder, "%v:%d:%d", send.kind, send.conversationID, send.messageID)
	}
	clear(&readMarkerTestSends)
	return strings.to_string(builder)
}

// A room list with read state, as ServerListRooms delivers it.
@(private = "file")
testApplyRoomsWithReadState :: proc(state: ^State, serverID: int, rooms: ..common.RoomSummary) {
	event := ClientTransportRuntimeEvent {
		kind     = .RoomListReceived,
		serverID = serverID,
	}
	for room in rooms {
		clone := room
		clone.name = strings.clone(room.name)
		clone.description = strings.clone(room.description)
		if !common.roomTypeIsSupported(clone.roomType) {
			clone.roomType = .ChatAndVoice
		}
		append(&event.rooms, clone)
	}
	State_applyRuntimeEvent(state, &event)
	ClientTransportRuntimeEvent_deinit(&event)
}

@(private = "file")
testApplyReadMarker :: proc(
	state: ^State,
	serverID: int,
	kind: common.ReadMarkerKind,
	conversationID, lastRead, unread: int,
) {
	event := ClientTransportRuntimeEvent {
		kind = .ReadMarkerReceived,
		serverID = serverID,
		readMarker = {
			kind = kind,
			conversationId = conversationID,
			lastReadMessageId = lastRead,
			unreadCount = unread,
		},
	}
	State_applyRuntimeEvent(state, &event)
	ClientTransportRuntimeEvent_deinit(&event)
}

@(private = "file")
testSidebarUnread :: proc(state: ^State, kind: SidebarRowKind, id: int) -> int {
	for row in buildSidebarRows(state) {
		if row.kind == kind && row.id == id {
			return row.unreadCount
		}
	}
	return -1
}

@(test)
testRoomBadgesComeFromTheServerAndCountLiveMessages :: proc(t: ^testing.T) {
	_ = t
	server := testDirectServer(901)
	state := testStateWithServers({server})
	defer State_deinit(&state)
	testApplyConnected(&state, server.id, 7)
	testApplyRoomsWithReadState(
		&state,
		server.id,
		{id = 1, name = "general", lastReadMessageId = 10, unreadCount = 2},
		{id = 2, name = "lounge", lastReadMessageId = 5},
	)
	assert(
		testSidebarUnread(&state, .Channel, 1) == 2,
		"expected #general's badge to show the server's count of 2",
	)
	assert(testSidebarUnread(&state, .Channel, 2) == 0, "expected no badge on #lounge")

	// The window has no focus, so nothing is viewed: someone else's new message counts, the
	// user's own does not, and neither does an old message at or below the marker.
	testApplyRoomChat(&state, server.id, 2, 8, 11, "hi", "bob")
	assert(
		testSidebarUnread(&state, .Channel, 2) == 1,
		"expected a message from someone else to add to #lounge's badge",
	)
	testApplyRoomChat(&state, server.id, 2, 7, 12, "mine")
	testApplyRoomChat(&state, server.id, 2, 8, 4, "old", "bob")
	testApplyRoomChat(&state, server.id, 2, 8, 11, "again", "bob")
	assert(
		testSidebarUnread(&state, .Channel, 2) == 1,
		"expected own, old, and duplicate messages not to count",
	)

	// The selected room counts while the window is unfocused, and not once it has focus.
	State_switchToChannel(&state, server.id, 2)
	testApplyRoomChat(&state, server.id, 2, 8, 13, "unfocused", "bob")
	assert(testSidebarUnread(&state, .Channel, 2) == 2, "expected an unfocused room to count")
	state.windowFocused = true
	testApplyRoomChat(&state, server.id, 2, 8, 14, "focused", "bob")
	assert(testSidebarUnread(&state, .Channel, 2) == 2, "expected a viewed room not to count")
	// The settings screen hides the room, so it is not viewed.
	state.settingsOpen = true
	testApplyRoomChat(&state, server.id, 2, 8, 15, "behind settings", "bob")
	assert(testSidebarUnread(&state, .Channel, 2) == 3, "expected a hidden room to count")
	state.settingsOpen = false

	// ServerEditRoom carries no read state; the room keeps its own.
	testApplyRoomEvent(&state, .RoomEdited, server.id, 2, "lounge-2", "renamed")
	summary := State_roomSummary(&state, server.id, 2)
	assert(
		summary != nil && summary.name == "lounge-2" && summary.unreadCount == 3 &&
		summary.lastReadMessageId == 5,
		fmt.tprintf("expected the edited room to keep 3 unread at 5, got %v", summary^),
	)

	// The count stops at the server's cap, and the badge says "99+" from 100 on.
	summary.unreadCount = common.UNREAD_COUNT_CAP
	state.windowFocused = false
	testApplyRoomChat(&state, server.id, 2, 8, 16, "more", "bob")
	assert(
		State_roomSummary(&state, server.id, 2).unreadCount == common.UNREAD_COUNT_CAP,
		"expected the live count capped like the server's",
	)
	assert(unreadBadgeText(99) == "99", "expected 99 to show as 99")
	assert(unreadBadgeText(common.UNREAD_COUNT_CAP) == "99+", "expected 100 to show as 99+")
	assert(unreadBadgeText(3) == "3", "expected small counts as numbers")
}

@(test)
testDirectBadgesComeFromTheServerList :: proc(t: ^testing.T) {
	_ = t
	server := testDirectServer(902)
	state := testStateWithServers({server})
	defer State_deinit(&state)
	testApplyConnected(&state, server.id, 7)
	event := ClientTransportRuntimeEvent {
		kind     = .DirectConversationsReceived,
		serverID = server.id,
	}
	append(
		&event.conversations,
		common.DirectConversationSummary {
			peerUserId = 11,
			peerNickname = strings.clone("bob"),
			lastMessageID = 40,
			lastSenderId = 11,
			lastTimestamp = strings.clone("t"),
			lastContent = strings.clone("hey"),
			lastReadMessageId = 30,
			unreadCount = 4,
		},
	)
	State_applyRuntimeEvent(&state, &event)
	ClientTransportRuntimeEvent_deinit(&event)
	assert(
		testSidebarUnread(&state, .Conversation, 11) == 4,
		"expected bob's badge to show the server's count of 4",
	)

	// A live message moves the conversation and keeps its read state, plus one.
	testApplyDirectMessage(&state, server.id, 41, 11, 7, "one more", "bob", "me")
	summary := State_directSummary(&state, server.id, 11)
	assert(
		summary.unreadCount == 5 && summary.lastReadMessageId == 30,
		fmt.tprintf("expected 5 unread at 30, got %v", summary^),
	)
	// An older message than the listed latest was already in the server's count.
	testApplyDirectMessage(&state, server.id, 35, 11, 7, "older", "bob", "me")
	assert(State_directSummary(&state, server.id, 11).unreadCount == 5, "expected no recount")

	// Reading on another device clears the badge here; an older marker changes nothing.
	testApplyReadMarker(&state, server.id, .Direct, 11, 41, 0)
	assert(
		testSidebarUnread(&state, .Conversation, 11) == 0,
		"expected a remote ServerReadMarker to clear bob's badge",
	)
	testApplyReadMarker(&state, server.id, .Direct, 11, 39, 2)
	summary = State_directSummary(&state, server.id, 11)
	assert(
		summary.unreadCount == 0 && summary.lastReadMessageId == 41,
		fmt.tprintf("expected an older marker to be ignored, got %v", summary^),
	)
	// A marker for a conversation the list does not show, or another server, is dropped.
	testApplyReadMarker(&state, server.id, .Direct, 99, 50, 1)
	testApplyReadMarker(&state, server.id + 1, .Direct, 11, 60, 1)
	assert(
		State_directSummary(&state, server.id, 11).lastReadMessageId == 41,
		"expected markers for unknown conversations to change nothing",
	)
}

@(test)
testRemoteReadMarkerClearsARoomBadge :: proc(t: ^testing.T) {
	_ = t
	server := testDirectServer(903)
	state := testStateWithServers({server})
	defer State_deinit(&state)
	testApplyConnected(&state, server.id, 7)
	testApplyRoomsWithReadState(
		&state,
		server.id,
		{id = 1, name = "general", lastReadMessageId = 3, unreadCount = 2},
	)
	testApplyReadMarker(&state, server.id, .Room, 1, 5, 0)
	assert(
		testSidebarUnread(&state, .Channel, 1) == 0,
		"expected a remote ServerReadMarker to clear #general's badge",
	)
	// A newer message than the marker counts again.
	testApplyRoomChat(&state, server.id, 1, 8, 6, "after", "bob")
	assert(testSidebarUnread(&state, .Channel, 1) == 1, "expected a message after the marker")
	testApplyRoomChat(&state, server.id, 1, 8, 5, "at the marker", "bob")
	assert(testSidebarUnread(&state, .Channel, 1) == 1, "expected the marked message not to")
}

@(test)
testViewedConversationIsMarkedReadAtMostOncePerSecond :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&readMarkerSendBridgeTestMutex)
	defer sync.mutex_unlock(&readMarkerSendBridgeTestMutex)
	testReadMarkerUseStub()
	defer testReadMarkerRestore()

	server := testDirectServer(904)
	state := testStateWithServers({server})
	defer State_deinit(&state)
	testApplyConnected(&state, server.id, 7)
	testApplyRoomsWithReadState(
		&state,
		server.id,
		{id = 1, name = "general", lastReadMessageId = 0, unreadCount = 2},
	)
	State_switchToChannel(&state, server.id, 1)
	start := time.tick_now()
	at :: proc(start: time.Tick, ms: int) -> time.Tick {
		return time.tick_add(start, time.Duration(ms) * time.Millisecond)
	}

	// Nothing loaded, or no focus: nothing to mark.
	state.windowFocused = true
	assert(State_updateReadMarkers(&state, start) == -1, "expected nothing to mark yet")
	state.windowFocused = false
	testApplyRoomChat(&state, server.id, 1, 8, 5, "first", "bob")
	assert(State_updateReadMarkers(&state, start) == -1, "expected no mark without focus")
	assert(testReadMarkerTakeSends() == "", "expected no mark-read without focus")

	// Focused: the newest loaded message is marked once.
	state.windowFocused = true
	assert(State_updateReadMarkers(&state, start) == -1, "expected the mark to go out")
	assert(testReadMarkerTakeSends() == "Room:1:5", "expected #general marked read up to 5")
	State_updateReadMarkers(&state, at(start, 10))
	assert(testReadMarkerTakeSends() == "", "expected no second mark for the same message")
	// The client never clears a badge by itself; the server's marker does.
	// 2 from the list plus the message that arrived while the window had no focus.
	assert(testSidebarUnread(&state, .Channel, 1) == 3, "expected the badge to wait")
	testApplyReadMarker(&state, server.id, .Room, 1, 5, 0)
	assert(testSidebarUnread(&state, .Channel, 1) == 0, "expected the server's marker to clear it")

	// A new message within the second waits for the rest of it.
	testApplyRoomChat(&state, server.id, 1, 8, 6, "second", "bob")
	wait := State_updateReadMarkers(&state, at(start, 200))
	assert(
		wait > 0 && wait <= 800 * time.Millisecond,
		fmt.tprintf("expected to wait out the second, got %v", wait),
	)
	assert(testReadMarkerTakeSends() == "", "expected the throttle to hold the mark-read")
	assert(testSidebarUnread(&state, .Channel, 1) == 0, "expected a viewed message not to count")
	State_updateReadMarkers(&state, at(start, 1000))
	assert(testReadMarkerTakeSends() == "Room:1:6", "expected the held mark-read after a second")

	// The user's own message moves the newest loaded ID too, and is marked like any other.
	testApplyRoomChat(&state, server.id, 1, 7, 7, "mine")
	State_updateReadMarkers(&state, at(start, 2100))
	assert(testReadMarkerTakeSends() == "Room:1:7", "expected the own message marked read")

	// Another room is not marked while #general is the one viewed.
	testApplyRoomsWithReadState(
		&state,
		server.id,
		{id = 1, name = "general", lastReadMessageId = 7},
		{id = 2, name = "lounge", lastReadMessageId = 0},
	)
	testApplyRoomChat(&state, server.id, 2, 8, 8, "elsewhere", "bob")
	State_updateReadMarkers(&state, at(start, 3200))
	assert(testReadMarkerTakeSends() == "", "expected only the viewed room to be marked")
	assert(testSidebarUnread(&state, .Channel, 2) == 1, "expected #lounge to count it")

	// A new connection forgets what was sent, so a mark that may have been lost goes again.
	State_resetReadMarkerSends(&state, server.id)
	send := State_readMarkerSendState(&state, .Room, server.id, 1)
	assert(send^ == {}, "expected the send bookkeeping cleared on a new connection")

	// A direct conversation works the same way.
	testApplyConversations(&state, server.id, {id = 11, nickname = "bob"})
	State_openDirectConversation(&state, server.id, 11)
	testApplyDirectMessage(&state, server.id, 300, 11, 7, "dm", "bob", "me")
	assert(
		testSidebarUnread(&state, .Conversation, 11) == 0,
		"expected a message in the viewed conversation not to count",
	)
	State_updateReadMarkers(&state, at(start, 4300))
	assert(testReadMarkerTakeSends() == "Direct:11:300", "expected the conversation marked read")
	// The room editor or settings hide the conversation too.
	state.settingsOpen = true
	testApplyDirectMessage(&state, server.id, 301, 11, 7, "hidden", "bob", "me")
	State_updateReadMarkers(&state, at(start, 5400))
	assert(testReadMarkerTakeSends() == "", "expected no mark while settings cover the pane")
	assert(testSidebarUnread(&state, .Conversation, 11) == 1, "expected the hidden one to count")
}

@(test)
testClientServerTransportCarriesReadMarkers :: proc(t: ^testing.T) {
	_ = t
	server := testDirectServer(905)
	config := testConfigWithServers({server})
	defer Config_deinit(&config)
	transport, serverTransport, ok := buildEstablishedTransportPair(server, config)
	assert(ok, "expected transport pair setup to succeed")
	defer ClientServerTransport_deinit(&transport)

	// ClientMarkRead opens on the server side as the request.
	packetBytes, built := ClientServerTransport_buildEncryptedPacketBytes(
		&transport,
		.ClientMarkRead,
		common.ClientMarkReadPayload{kind = .Direct, conversationId = 3, messageId = 44},
	)
	assert(built, "expected the mark-read packet to build")
	defer delete(packetBytes)
	outer: common.Packet
	assert(cbor.unmarshal(packetBytes, &outer) == nil, "expected the outer packet to decode")
	defer delete(outer.payload)
	inner, openOK := common.openPacketForSession(&serverTransport, outer)
	assert(openOK, "expected the server to open the packet")
	defer delete(inner.payload)
	request: common.ClientMarkReadPayload
	assert(
		inner.messageType == .ClientMarkRead && cbor.unmarshal(inner.payload, &request) == nil,
		"expected a ClientMarkRead packet",
	)
	assert(
		request == common.ClientMarkReadPayload{kind = .Direct, conversationId = 3, messageId = 44},
		fmt.tprintf("expected the request fields, got %v", request),
	)

	// ServerReadMarker becomes a .ReadMarkerReceived event.
	marker := common.ServerReadMarkerPayload {
		kind              = .Room,
		conversationId    = 1,
		lastReadMessageId = 9,
		unreadCount       = 0,
	}
	sealed, sealOK := common.sealPacketForSession(&serverTransport, .ServerReadMarker, marker)
	assert(sealOK, "expected the server transport to seal the marker")
	defer delete(sealed.payload)
	markerBytes, bytesOK := common.marshalPacket(sealed)
	assert(bytesOK, "expected the sealed marker to marshal")
	defer delete(markerBytes)
	event, eventOK := ClientServerTransport_handleRuntimePacketBytes(&transport, markerBytes)
	defer ClientTransportRuntimeEvent_deinit(&event)
	assert(
		eventOK &&
		event.kind == .ReadMarkerReceived &&
		event.serverID == server.id &&
		event.readMarker == marker,
		fmt.tprintf("expected a read marker event, got %v", event),
	)

	// Without a live ENet session a mark-read reports "not connected".
	assert(
		!ClientServerTransport_markRead(&transport, .Room, 1, 9),
		"expected no mark-read without a live session",
	)
	testExpectString(t, transport.lastError, NOT_CONNECTED_MESSAGE, "the mark-read error")
}

@(test)
testHeadlessReadStateCommandsAndEvents :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&readMarkerSendBridgeTestMutex)
	defer sync.mutex_unlock(&readMarkerSendBridgeTestMutex)
	testReadMarkerUseStub()
	defer testReadMarkerRestore()

	// The event, rendered before State applies it.
	markerEvent := ClientTransportRuntimeEvent {
		kind = .ReadMarkerReceived,
		serverID = 1,
		readMarker = {kind = .Direct, conversationId = 4, lastReadMessageId = 12, unreadCount = 0},
	}
	line, kind, ok := headlessRenderRuntimeEvent(&markerEvent)
	defer delete(line)
	assert(ok && kind == .ReadMarker, "expected a read_marker event")
	testExpectString(
		t,
		line,
		`{"event":"read_marker","serverID":1,"kind":"dm","conversationID":4,` +
		`"lastReadMessageId":12,"unreadCount":0}`,
		"the read_marker JSON",
	)

	builder := strings.builder_make()
	harness := testHeadlessHarness(&builder, 906)
	defer testHeadlessHarnessDeinit(&harness, &builder)
	testApplyConnected(&harness.state, 906, 3)
	testApplyRoomsWithReadState(
		&harness.state,
		906,
		{id = 1, name = "general", lastReadMessageId = 2, unreadCount = 1},
	)

	for bad in ([]string{"read x 1", "read room 0", "read room 1 0", "read dm"}) {
		headlessHandleLine(&harness, bad)
		testExpectString(
			t,
			testHeadlessTakeOutput(&builder),
			`{"ok":false,"cmd":"read","error":"usage: read room|dm ID [MESSAGE_ID]"}` + "\n",
			fmt.tprintf("the usage error of %q", bad),
		)
	}
	headlessHandleLine(&harness, "read room 1")
	output := testHeadlessTakeOutput(&builder)
	assert(
		strings.contains(output, `"error":"nothing loaded in that conversation`),
		fmt.tprintf("expected an error with nothing loaded, got %s", output),
	)

	// Explicit and default message IDs; the harness itself never marks anything.
	headlessHandleLine(&harness, "read room 1 2")
	testExpectString(
		t,
		testHeadlessTakeOutput(&builder),
		`{"ok":true,"cmd":"read","serverID":906,"kind":"room","conversationID":1,` +
		`"messageID":2}` +
		"\n",
		"the read result",
	)
	testApplyRoomChat(&harness.state, 906, 1, 4, 9, "hi", "bob")
	assert(
		State_updateReadMarkers(&harness.state, time.tick_now()) == -1,
		"expected the harness never to mark read on its own",
	)
	headlessHandleLine(&harness, "read room 1")
	output = testHeadlessTakeOutput(&builder)
	assert(
		strings.contains(output, `"conversationID":1,"messageID":9}`),
		fmt.tprintf("expected the newest loaded message, got %s", output),
	)
	assert(
		testReadMarkerTakeSends() == "Room:1:2,Room:1:9",
		"expected exactly the two requested mark-reads",
	)

	// rooms, conversations, and users carry the read state.
	headlessHandleLine(&harness, "rooms")
	output = testHeadlessTakeOutput(&builder)
	assert(
		strings.contains(output, `"name":"general","description":"","lastReadMessageId":2,` +
			`"unreadCount":2,"roomType":3}`),
		fmt.tprintf("expected #general with its marker and 2 unread, got %s", output),
	)
	testApplyUserList(&harness.state, 906, {id = 3, nickname = "me"}, {id = 4, nickname = "bob"})
	testApplyDirectMessage(&harness.state, 906, 20, 4, 3, "psst", "bob", "me")
	headlessHandleLine(&harness, "users")
	output = testHeadlessTakeOutput(&builder)
	assert(
		strings.contains(
			output,
			`{"id":4,"nickname":"bob","isOnline":false,"lastReadMessageId":0,"unreadCount":1,`,
		),
		fmt.tprintf("expected bob with 1 unread, got %s", output),
	)
	headlessHandleLine(&harness, "conversations")
	output = testHeadlessTakeOutput(&builder)
	assert(
		strings.contains(output, `"lastContent":"psst","lastReadMessageId":0,"unreadCount":1}`),
		fmt.tprintf("expected the conversation with 1 unread, got %s", output),
	)

	headlessHandleLine(&harness, "help")
	output = testHeadlessTakeOutput(&builder)
	assert(
		strings.contains(output, `{"usage":"read room|dm ID [MESSAGE_ID]",`) &&
		strings.contains(output, `"read_marker"`),
		fmt.tprintf("expected help to list read and read_marker, got %s", output),
	)
}

@(test)
testLosingFocusFlushesAThrottledMarkRead :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&readMarkerSendBridgeTestMutex)
	defer sync.mutex_unlock(&readMarkerSendBridgeTestMutex)
	testReadMarkerUseStub()
	defer testReadMarkerRestore()

	server := testDirectServer(905)
	state := testStateWithServers({server})
	defer State_deinit(&state)
	testApplyConnected(&state, server.id, 7)
	testApplyRoomsWithReadState(&state, server.id, {id = 1, name = "general"})
	State_switchToChannel(&state, server.id, 1)
	state.windowFocused = true
	start := time.tick_now()
	later := time.tick_add(start, 200 * time.Millisecond)

	testApplyRoomChat(&state, server.id, 1, 8, 5, "first", "bob")
	State_updateReadMarkers(&state, start)
	assert(testReadMarkerTakeSends() == "Room:1:5", "expected the first message marked read")

	// Inside the throttle a viewed message neither counts nor goes out yet.
	testApplyRoomChat(&state, server.id, 1, 8, 6, "second", "bob")
	assert(State_updateReadMarkers(&state, later) > 0, "expected the throttle to hold it")
	assert(testReadMarkerTakeSends() == "", "expected nothing sent inside the second")
	assert(testSidebarUnread(&state, .Channel, 1) == 0, "expected a viewed message not to count")

	// Losing focus flushes it, ignoring the throttle, while the room still counts as viewed.
	State_flushReadMarkers(&state, later)
	assert(testReadMarkerTakeSends() == "Room:1:6", "expected the flush to mark it read")
	state.windowFocused = false
	State_flushReadMarkers(&state, later)
	assert(testReadMarkerTakeSends() == "", "expected no flush without a viewed conversation")
}

@(test)
testAutomaticMarkReadFailureLeavesTheStatusAlone :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&readMarkerSendBridgeTestMutex)
	defer sync.mutex_unlock(&readMarkerSendBridgeTestMutex)
	testReadMarkerUseStub()
	defer testReadMarkerRestore()
	readMarkerSendBridge = readMarkerTestFailingStub

	server := testDirectServer(906)
	state := testStateWithServers({server})
	defer State_deinit(&state)
	testApplyConnected(&state, server.id, 7)
	testApplyRoomsWithReadState(&state, server.id, {id = 1, name = "general"})
	State_switchToChannel(&state, server.id, 1)
	state.windowFocused = true
	testApplyRoomChat(&state, server.id, 1, 8, 5, "first", "bob")

	// The automatic path tries, fails, and keeps quiet.
	State_setChatStatus(&state, "Connected as me")
	State_updateReadMarkers(&state, time.tick_now())
	assert(testReadMarkerTakeSends() == "Room:1:5", "expected the automatic mark-read attempt")
	assert(
		state.chat_status_message == "Connected as me",
		fmt.tprintf("expected the status untouched, got %q", state.chat_status_message),
	)

	// A user-initiated read reports the failure, replacing the unrelated status.
	sent := State_markConversationRead(&state, .Room, server.id, 1, 5, time.tick_now())
	assert(!sent, "expected the failing bridge to refuse the send")
	assert(
		state.chat_status_message == READ_MARKER_TEST_SEND_FAILURE,
		fmt.tprintf("expected the failure reported, got %q", state.chat_status_message),
	)
}
