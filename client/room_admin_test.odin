#+feature dynamic-literals
package client

import "../common"
import "core:encoding/cbor"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:testing"

roomAdminSendBridgeTestMutex: sync.Mutex
roomAdminSendBridgeTestCount: int
roomAdminSendBridgeTestKind: RoomAdminRequestKind
roomAdminSendBridgeTestRoomID: int
roomAdminSendBridgeTestName: string
roomAdminSendBridgeTestDescription: string
roomAdminSendBridgeTestRoomType: common.RoomType
roomAdminSendBridgeTestAccess: common.RoomAccess
roomAdminSendBridgeTestHistory: common.RoomHistoryVisibility
roomAdminSendBridgeTestCreatorJoins: bool
roomAdminSendBridgeTestReturnValue: bool

roomAdminSendBridgeTestStub :: proc(
	transport: ^ClientServerTransport,
	request: RoomAdminRequest,
) -> bool {
	roomAdminSendBridgeTestCount += 1
	roomAdminSendBridgeTestKind = request.kind
	roomAdminSendBridgeTestRoomID = request.roomID
	roomAdminSendBridgeTestRoomType = request.roomType
	roomAdminSendBridgeTestAccess = request.access
	roomAdminSendBridgeTestHistory = request.history
	roomAdminSendBridgeTestCreatorJoins = request.creatorJoins
	delete(roomAdminSendBridgeTestName)
	delete(roomAdminSendBridgeTestDescription)
	roomAdminSendBridgeTestName = strings.clone(request.name)
	roomAdminSendBridgeTestDescription = strings.clone(request.description)
	return roomAdminSendBridgeTestReturnValue
}

// Swaps in the stub; call with the mutex held and run the returned restore when done.
testRoomAdminUseStub :: proc() {
	roomAdminSendBridgeTestCount = 0
	roomAdminSendBridgeTestKind = .Create
	roomAdminSendBridgeTestRoomID = 0
	roomAdminSendBridgeTestReturnValue = true
	roomAdminSendBridge = roomAdminSendBridgeTestStub
}

testRoomAdminRestore :: proc() {
	roomAdminSendBridge = ClientServerTransport_sendRoomAdminRequest
	delete(roomAdminSendBridgeTestName)
	delete(roomAdminSendBridgeTestDescription)
	roomAdminSendBridgeTestName = ""
	roomAdminSendBridgeTestDescription = ""
}

testRoomAdminServer :: proc(id: int) -> Server {
	return Server {
		id = id,
		name = fmt.tprintf("Rooms %d", id),
		short_name = "R",
		host = "localhost",
		port = 1,
	}
}

// Signs in the way the worker's Connected event does, with the server's admin flag.
testApplyConnectedAs :: proc(state: ^State, serverID, userID: int, isAdmin: bool) {
	event := ClientTransportRuntimeEvent {
		kind     = .Connected,
		serverID = serverID,
		userID   = userID,
		nickname = strings.clone(state.config.display_name),
		isAdmin  = isAdmin,
	}
	State_applyRuntimeEvent(state, &event)
	ClientTransportRuntimeEvent_deinit(&event)
}

// Applies a room list of (id, name) pairs: general is room 1, the others are named. A room
// without a supported type is listed for text and voice, and one without an access mode as
// Public, as the server lists rooms.
testApplyNamedRooms :: proc(state: ^State, serverID: int, rooms: ..common.RoomSummary) {
	event := ClientTransportRuntimeEvent {
		kind     = .RoomListReceived,
		serverID = serverID,
	}
	for room in rooms {
		roomType := room.roomType
		if !common.roomTypeIsSupported(roomType) {
			roomType = .ChatAndVoice
		}
		// Rooms without an access mode are Public, as every room was before protocol 15.
		access := room.access
		if !common.roomAccessIsSupported(access) {
			access = .Public
		}
		append(
			&event.rooms,
			common.RoomSummary {
				id = room.id,
				name = strings.clone(room.name),
				description = strings.clone(room.description),
				roomType = roomType,
				access = access,
				historyVisibility = common.roomEffectiveHistoryVisibility(
					access,
					room.historyVisibility,
				),
			},
		)
	}
	State_applyRuntimeEvent(state, &event)
	ClientTransportRuntimeEvent_deinit(&event)
}

testApplyRoomEvent :: proc(
	state: ^State,
	kind: ClientTransportRuntimeEventKind,
	serverID, roomID: int,
	name := "",
	description := "",
) {
	event := ClientTransportRuntimeEvent {
		kind = kind,
		serverID = serverID,
		roomID = roomID,
		room = {
			id = roomID,
			name = strings.clone(name),
			description = strings.clone(description),
		},
	}
	State_applyRuntimeEvent(state, &event)
	ClientTransportRuntimeEvent_deinit(&event)
}

testRoomAdminSetForm :: proc(state: ^State, name, description: string) {
	testSetDraft(&state.roomEditor.name, name)
	testSetDraft(&state.roomEditor.description, description)
}

@(test)
testRoomAdminControlsAreOnlyForAdmins :: proc(t: ^testing.T) {
	server := testRoomAdminServer(901)
	state := testUpdateStateForServer(server)
	defer State_deinit(&state)

	testApplyConnectedAs(&state, server.id, 3, false)
	testApplyNamedRooms(&state, server.id, {id = 1, name = "general"})
	rows := buildSidebarRows(&state)
	testing.expect(
		t,
		rows[0].label == "Channels" && rows[0].action == .None,
		"expected no New room control for a non-admin",
	)
	testing.expect(t, !buildRoomView(&state).canEditRoom, "expected no Edit room for a non-admin")
	State_openRoomCreator(&state)
	State_openRoomEditor(&state, 1)
	testing.expect(
		t,
		state.roomEditor.mode == .Closed && !buildRoomEditorView(&state).visible,
		"expected a non-admin never to get the room form",
	)

	testApplyConnectedAs(&state, server.id, 3, true)
	testing.expect(t, State_isServerAdmin(&state, server.id), "expected the admin flag kept")
	rows = buildSidebarRows(&state)
	testing.expect(t, rows[0].action == .NewRoom, "expected New room for an admin")
	testing.expect(t, buildRoomView(&state).canEditRoom, "expected Edit room for an admin")

	// The flag belongs to the session: losing it hides the controls until the next sign-in.
	lost := ClientTransportRuntimeEvent {
		kind     = .Disconnected,
		serverID = server.id,
		message  = strings.clone("gone"),
	}
	State_applyRuntimeEvent(&state, &lost)
	ClientTransportRuntimeEvent_deinit(&lost)
	testing.expect(t, !State_isServerAdmin(&state, server.id), "expected no admin offline")
	rows = buildSidebarRows(&state)
	testing.expect(t, rows[0].action == .None, "expected no New room while disconnected")
}

@(test)
testRoomEditorViewLabelsAndGeneralNotice :: proc(t: ^testing.T) {
	server := testRoomAdminServer(902)
	state := testUpdateStateForServer(server)
	defer State_deinit(&state)
	testApplyConnectedAs(&state, server.id, 3, true)
	testApplyNamedRooms(
		&state,
		server.id,
		{id = 1, name = "general", description = "General discussion"},
		{id = 5, name = "random"},
	)

	State_openRoomCreator(&state)
	view := buildRoomEditorView(&state)
	testing.expect(
		t,
		view.visible && view.isCreate && view.title == "New room" &&
		view.submitLabel == "Create" && !view.showDelete && len(view.generalNotice) == 0,
		fmt.tprintf("expected the empty New room form, got %v", view),
	)

	State_openRoomEditor(&state, 1)
	testExpectString(t, string(state.roomEditor.name[:]), "general", "the prefilled name")
	testExpectString(
		t,
		string(state.roomEditor.description[:]),
		"General discussion",
		"the prefilled description",
	)
	view = buildRoomEditorView(&state)
	testing.expect(
		t,
		view.title == "Edit #general" && view.submitLabel == "Save" && view.showDelete &&
		view.deleteLabel == "Delete room" && view.generalNotice == ROOM_EDITOR_GENERAL_NOTICE,
		fmt.tprintf("expected the #general edit form with its notice, got %v", view),
	)

	State_openRoomEditor(&state, 5)
	view = buildRoomEditorView(&state)
	testing.expect(
		t,
		view.title == "Edit #random" && len(view.generalNotice) == 0,
		fmt.tprintf("expected no #general notice for another room, got %v", view),
	)

	// The form belongs to its server, and showing a room closes it.
	State_switchToChannel(&state, server.id, 1)
	testing.expect(t, state.roomEditor.mode == .Closed, "expected a room click to close it")
}

@(test)
testRoomEditorCreatesARoomAndSelectsIt :: proc(t: ^testing.T) {
	sync.mutex_lock(&roomAdminSendBridgeTestMutex)
	defer sync.mutex_unlock(&roomAdminSendBridgeTestMutex)
	testRoomAdminUseStub()
	defer testRoomAdminRestore()

	server := testRoomAdminServer(903)
	state := testUpdateStateForServer(server)
	defer State_deinit(&state)
	testApplyConnectedAs(&state, server.id, 3, true)
	testApplyNamedRooms(&state, server.id, {id = 1, name = "general"})

	State_openRoomCreator(&state)
	// Validation runs before anything is sent.
	testRoomAdminSetForm(&state, "   ", "")
	State_submitRoomEditor(&state)
	testExpectString(t, state.roomEditor.error, "Enter a room name.", "the empty name error")
	testRoomAdminSetForm(&state, "# general", "")
	State_submitRoomEditor(&state)
	testExpectString(
		t,
		state.roomEditor.error,
		"A room named #general already exists.",
		"the duplicate name error",
	)
	testRoomAdminSetForm(&state, strings.repeat("x", 65, context.temp_allocator), "")
	State_submitRoomEditor(&state)
	testing.expect(
		t,
		strings.has_prefix(state.roomEditor.error, "The room name must be at most 64 bytes"),
		fmt.tprintf("expected a too-long name error, got %q", state.roomEditor.error),
	)
	testing.expect(t, roomAdminSendBridgeTestCount == 0, "expected no request for a bad form")

	testRoomAdminSetForm(&state, "  #random ", " Off topic ")
	State_submitRoomEditor(&state)
	testing.expect(
		t,
		roomAdminSendBridgeTestCount == 1 && roomAdminSendBridgeTestKind == .Create,
		"expected one create request",
	)
	testExpectString(t, roomAdminSendBridgeTestName, "random", "the sent room name")
	testExpectString(t, roomAdminSendBridgeTestDescription, "Off topic", "the sent description")
	testing.expect(
		t,
		state.roomEditor.pending == .Create && len(state.roomEditor.error) == 0,
		"expected the form to wait for the server",
	)
	testExpectString(t, buildRoomEditorView(&state).submitLabel, "Creating…", "the busy label")
	// A second submit while waiting sends nothing.
	State_submitRoomEditor(&state)
	testing.expect(t, roomAdminSendBridgeTestCount == 1, "expected no second create request")

	testApplyRoomEvent(&state, .RoomCreated, server.id, 7, "random", "Off topic")
	testing.expect(t, state.roomEditor.mode == .Closed, "expected RoomCreated to close the form")
	testing.expect(t, state.selected_channel_id == 7, "expected the new room to be selected")
	cache := State_serverRoomCache(&state, server.id)
	testing.expect(
		t,
		ServerRoomCache_roomIsJoined(cache, 7),
		"expected the new room in the room list before the refresh arrives",
	)

	// A repeated answer for a room already listed frees its copy and keeps one entry.
	testApplyRoomEvent(&state, .RoomCreated, server.id, 7, "random", "Off topic")
	cache = State_serverRoomCache(&state, server.id)
	testing.expect(t, len(cache.rooms) == 2, "expected the room listed once")
}

@(test)
testRoomEditorSavesAndDeletesWithConfirmation :: proc(t: ^testing.T) {
	sync.mutex_lock(&roomAdminSendBridgeTestMutex)
	defer sync.mutex_unlock(&roomAdminSendBridgeTestMutex)
	testRoomAdminUseStub()
	defer testRoomAdminRestore()

	server := testRoomAdminServer(904)
	state := testUpdateStateForServer(server)
	defer State_deinit(&state)
	testApplyConnectedAs(&state, server.id, 3, true)
	testApplyNamedRooms(&state, server.id, {id = 1, name = "general"}, {id = 5, name = "random"})
	State_switchToChannel(&state, server.id, 5)

	State_openRoomEditor(&state, 5)
	testRoomAdminSetForm(&state, "lounge", "Sit down")
	State_submitRoomEditor(&state)
	testing.expect(
		t,
		roomAdminSendBridgeTestKind == .Edit && roomAdminSendBridgeTestRoomID == 5,
		"expected an edit request for room 5",
	)
	testExpectString(t, roomAdminSendBridgeTestName, "lounge", "the new room name")
	testExpectString(t, roomAdminSendBridgeTestDescription, "Sit down", "the new description")
	// The server's echo renames the room and closes the form.
	testApplyRoomEvent(&state, .RoomEdited, server.id, 5, "lounge", "Sit down")
	testing.expect(t, state.roomEditor.mode == .Closed, "expected RoomEdited to close the form")

	State_openRoomEditor(&state, 5)
	before := roomAdminSendBridgeTestCount
	State_deleteRoomFromEditor(&state)
	testing.expect(
		t,
		roomAdminSendBridgeTestCount == before && state.roomEditor.confirmDelete,
		"expected the first Delete click only to ask for confirmation",
	)
	testExpectString(
		t,
		buildRoomEditorView(&state).deleteLabel,
		"Confirm delete",
		"the armed delete label",
	)
	State_deleteRoomFromEditor(&state)
	testing.expect(
		t,
		roomAdminSendBridgeTestCount == before + 1 &&
		roomAdminSendBridgeTestKind == .Delete &&
		roomAdminSendBridgeTestRoomID == 5 &&
		state.roomEditor.pending == .Delete,
		"expected the second click to send the delete",
	)
	testApplyRoomEvent(&state, .RoomDeleted, server.id, 5)
	testing.expect(t, state.roomEditor.mode == .Closed, "expected RoomDeleted to close the form")
	testing.expect(
		t,
		state.selected_channel_id == common.GENERAL_ROOM_ID,
		"expected the selection to fall back to #general",
	)
}

@(test)
testRoomEditorClosesWhenAnotherAdminChangesItsRoom :: proc(t: ^testing.T) {
	server := testRoomAdminServer(905)
	state := testUpdateStateForServer(server)
	defer State_deinit(&state)
	testApplyConnectedAs(&state, server.id, 3, true)
	testApplyNamedRooms(
		&state,
		server.id,
		{id = 1, name = "general"},
		{id = 5, name = "random"},
		{id = 6, name = "music"},
	)

	State_openRoomEditor(&state, 5)
	testRoomAdminSetForm(&state, "half-typed", "")
	// A change to another room leaves the form alone.
	testApplyRoomEvent(&state, .RoomEdited, server.id, 6, "tunes", "")
	testing.expect(t, state.roomEditor.mode == .Edit, "expected another room's edit to keep it")
	testApplyRoomEvent(&state, .RoomDeleted, server.id, 6)
	testing.expect(t, state.roomEditor.mode == .Edit, "expected another room's delete to keep it")

	testApplyRoomEvent(&state, .RoomEdited, server.id, 5, "renamed elsewhere", "")
	testing.expect(
		t,
		state.roomEditor.mode == .Closed,
		"expected a remote edit of the room to close the form",
	)

	State_openRoomEditor(&state, 5)
	testApplyRoomEvent(&state, .RoomDeleted, server.id, 5)
	testing.expect(
		t,
		state.roomEditor.mode == .Closed && !buildRoomEditorView(&state).visible,
		"expected a remote delete of the room to close the form",
	)
}

@(test)
testRoomEditorShowsTheServersRefusal :: proc(t: ^testing.T) {
	sync.mutex_lock(&roomAdminSendBridgeTestMutex)
	defer sync.mutex_unlock(&roomAdminSendBridgeTestMutex)
	testRoomAdminUseStub()
	defer testRoomAdminRestore()

	server := testRoomAdminServer(906)
	state := testUpdateStateForServer(server)
	defer State_deinit(&state)
	testApplyConnectedAs(&state, server.id, 3, true)
	testApplyNamedRooms(&state, server.id, {id = 1, name = "general"})

	// The flag can be stale: the role was revoked after this session signed in.
	State_openRoomCreator(&state)
	testRoomAdminSetForm(&state, "random", "")
	State_submitRoomEditor(&state)
	refused := ClientTransportRuntimeEvent {
		kind     = .ProtocolError,
		serverID = server.id,
		message  = strings.clone("Admin permission required"),
	}
	State_applyRuntimeEvent(&state, &refused)
	ClientTransportRuntimeEvent_deinit(&refused)
	testing.expect(
		t,
		state.roomEditor.mode == .Create && state.roomEditor.pending == .None,
		"expected the form to stay open for another try",
	)
	testExpectString(t, state.roomEditor.error, "Admin permission required", "the form error")
	testExpectString(t, state.chat_status_message, "Admin permission required", "the status")

	// A rejected send (no session) is shown too, and nothing waits for an answer.
	roomAdminSendBridgeTestReturnValue = false
	State_submitRoomEditor(&state)
	testing.expect(
		t,
		state.roomEditor.pending == .None && len(state.roomEditor.error) > 0,
		"expected a failed send to show an error",
	)

	// A dropped session ends the wait.
	roomAdminSendBridgeTestReturnValue = true
	State_submitRoomEditor(&state)
	testApplyConnectedAs(&state, server.id, 3, true)
	testing.expect(
		t,
		state.roomEditor.pending == .None &&
		strings.has_prefix(state.roomEditor.error, "The connection dropped"),
		fmt.tprintf("expected a reset to end the wait, got %q", state.roomEditor.error),
	)
}

@(test)
testClientServerTransportHandlesRoomManagementPackets :: proc(t: ^testing.T) {
	server := testRoomAdminServer(907)
	config := testConfigWithServers({server})
	defer Config_deinit(&config)
	transport, serverTransport, ok := buildEstablishedTransportPair(server, config)
	assert(ok, "expected transport pair setup to succeed")
	defer ClientServerTransport_deinit(&transport)

	// ServerCreateRoom becomes RoomCreated, owning the new room.
	{
		sealed, sealOK := common.sealPacketForSession(
			&serverTransport,
			.ServerCreateRoom,
			common.ServerRoomMutationPayload {
				room = {id = 9, name = "random", description = "Off topic"},
				roomId = 9,
				userId = 3,
				changed = true,
			},
		)
		assert(sealOK, "expected the server transport to seal the payload")
		defer delete(sealed.payload)
		packetBytes, bytesOK := common.marshalPacket(sealed)
		assert(bytesOK, "expected the sealed packet to marshal")
		defer delete(packetBytes)
		event, eventOK := ClientServerTransport_handleRuntimePacketBytes(&transport, packetBytes)
		testing.expectf(
			t,
			eventOK &&
			event.kind == .RoomCreated &&
			event.serverID == server.id &&
			event.roomID == 9 &&
			event.room.id == 9 &&
			event.room.name == "random" &&
			event.room.description == "Off topic",
			"expected a decoded RoomCreated event, got %v",
			event,
		)
		ClientTransportRuntimeEvent_deinit(&event)
	}

	// Each request opens on the server side as the payload it was built from.
	open :: proc(
		transport: ^ClientServerTransport,
		serverTransport: ^common.TransportState,
		messageType: common.MessageType,
		payload: any,
	) -> common.Packet {
		packetBytes, built := ClientServerTransport_buildEncryptedPacketBytes(
			transport,
			messageType,
			payload,
		)
		assert(built, "expected the request packet to build")
		defer delete(packetBytes)
		outer: common.Packet
		assert(cbor.unmarshal(packetBytes, &outer) == nil, "expected the outer packet to decode")
		defer delete(outer.payload)
		inner, openOK := common.openPacketForSession(serverTransport, outer)
		assert(openOK, "expected the server to open the packet")
		return inner
	}
	{
		inner := open(
			&transport,
			&serverTransport,
			.ClientCreateRoom,
			common.ClientCreateRoomPayload {
				name = "random",
				description = "Off topic",
				roomType = .Voice,
			},
		)
		defer delete(inner.payload)
		request: common.ClientCreateRoomPayload
		decoded := cbor.unmarshal(inner.payload, &request) == nil
		defer delete(request.name)
		defer delete(request.description)
		testing.expect(
			t,
			inner.messageType == .ClientCreateRoom &&
			decoded &&
			request.name == "random" &&
			request.roomType == .Voice,
			"expected a ClientCreateRoom request",
		)
	}
	{
		inner := open(
			&transport,
			&serverTransport,
			.ClientEditRoom,
			common.ClientEditRoomPayload{roomId = 9, name = "lounge", roomType = .Chat},
		)
		defer delete(inner.payload)
		request: common.ClientEditRoomPayload
		decoded := cbor.unmarshal(inner.payload, &request) == nil
		defer delete(request.name)
		defer delete(request.description)
		testing.expect(
			t,
			inner.messageType == .ClientEditRoom &&
			decoded &&
			request.roomId == 9 &&
			request.name == "lounge" &&
			request.roomType == .Chat,
			"expected a ClientEditRoom request",
		)
	}
	{
		inner := open(
			&transport,
			&serverTransport,
			.ClientDeleteRoom,
			common.ClientDeleteRoomPayload{roomId = 9},
		)
		defer delete(inner.payload)
		request: common.ClientDeleteRoomPayload
		decoded := cbor.unmarshal(inner.payload, &request) == nil
		testing.expect(
			t,
			inner.messageType == .ClientDeleteRoom && decoded && request.roomId == 9,
			"expected a ClientDeleteRoom request",
		)
	}

	// Without a live ENet session the requests report "not connected" without failing it.
	testing.expect(
		t,
		!ClientServerTransport_sendRoomAdminRequest(
			&transport,
			RoomAdminRequest{kind = .Create, name = "random"},
		),
		"expected no create request without a live session",
	)
	testExpectString(t, transport.lastError, NOT_CONNECTED_MESSAGE, "the request error")
}

@(test)
testHeadlessRoomManagementCommandsAndEvents :: proc(t: ^testing.T) {
	sync.mutex_lock(&roomAdminSendBridgeTestMutex)
	defer sync.mutex_unlock(&roomAdminSendBridgeTestMutex)
	testRoomAdminUseStub()
	defer testRoomAdminRestore()

	builder := strings.builder_make()
	harness := testHeadlessHarness(&builder, 908)
	defer testHeadlessHarnessDeinit(&harness, &builder)
	testApplyConnectedAs(&harness.state, 908, 3, true)
	testApplyNamedRooms(&harness.state, 908, {id = 1, name = "general"})

	headlessHandleLine(&harness, "status")
	output := testHeadlessTakeOutput(&builder)
	testing.expect(
		t,
		strings.contains(output, `"userID":3,"nickname":"Tester","isAdmin":true,`),
		fmt.tprintf("expected status to report the admin flag, got %s", output),
	)

	headlessHandleLine(&harness, "room-create voice random Off topic, mostly")
	testExpectString(
		t,
		testHeadlessTakeOutput(&builder),
		`{"ok":true,"cmd":"room-create","serverID":908,"roomID":0,"name":"random",` +
		`"description":"Off topic, mostly","roomType":2,"access":1,"historyVisibility":1,` +
		`"creatorJoins":true}` +
		"\n",
		"the room-create result",
	)
	testing.expect(
		t,
		roomAdminSendBridgeTestKind == .Create &&
		roomAdminSendBridgeTestName == "random" &&
		roomAdminSendBridgeTestDescription == "Off topic, mostly" &&
		roomAdminSendBridgeTestRoomType == .Voice,
		"expected room-create to send the type, the name and the rest of the line",
	)

	headlessHandleLine(&harness, "room-create forum random")
	testExpectString(
		t,
		testHeadlessTakeOutput(&builder),
		`{"ok":false,"cmd":"room-create","error":"usage: room-create ` +
		`TYPE[,public|member-invite|admin-invite][,from-join|full][,no-join]` +
		`[,encrypted][,managers=ID+ID|managers=none] NAME [DESCRIPTION...]"}` +
		"\n",
		"the room-create type error",
	)

	headlessHandleLine(&harness, "room-create both general")
	testExpectString(
		t,
		testHeadlessTakeOutput(&builder),
		`{"ok":false,"cmd":"room-create","error":"A room named #general already exists."}` +
		"\n",
		"the duplicate room-create error",
	)

	headlessHandleLine(&harness, "room-edit 1 text lobby")
	testExpectString(
		t,
		testHeadlessTakeOutput(&builder),
		`{"ok":true,"cmd":"room-edit","serverID":908,"roomID":1,"name":"lobby",` +
		`"description":"","roomType":1,"access":1,"historyVisibility":0,"creatorJoins":false}` +
		"\n",
		"the room-edit result",
	)
	testing.expect(
		t,
		roomAdminSendBridgeTestKind == .Edit &&
		roomAdminSendBridgeTestRoomID == 1 &&
		roomAdminSendBridgeTestRoomType == .Chat,
		"expected room-edit to send a text-only edit of room 1",
	)

	headlessHandleLine(&harness, "room-edit x both lobby")
	testExpectString(
		t,
		testHeadlessTakeOutput(&builder),
		`{"ok":false,"cmd":"room-edit","error":"usage: room-edit ROOM_ID ` +
		`TYPE[,public|member-invite|admin-invite] NAME [DESCRIPTION...]"}` +
		"\n",
		"the room-edit usage error",
	)

	headlessHandleLine(&harness, "room-delete 1")
	testExpectString(
		t,
		testHeadlessTakeOutput(&builder),
		`{"ok":true,"cmd":"room-delete","serverID":908,"roomID":1,"name":"",` +
		`"description":"","roomType":0,"access":0,"historyVisibility":0,"creatorJoins":false}` +
		"\n",
		"the room-delete result",
	)
	testing.expect(
		t,
		roomAdminSendBridgeTestKind == .Delete && roomAdminSendBridgeTestRoomID == 1,
		"expected room-delete to send a delete of room 1",
	)

	headlessHandleLine(&harness, "room-delete")
	testExpectString(
		t,
		testHeadlessTakeOutput(&builder),
		`{"ok":false,"cmd":"room-delete","error":"usage: room-delete ROOM_ID"}` + "\n",
		"the room-delete usage error",
	)

	created := ClientTransportRuntimeEvent {
		kind = .RoomCreated,
		serverID = 908,
		roomID = 9,
		room = {
			id = 9,
			name = strings.clone("random"),
			description = strings.clone("Off"),
			roomType = .Voice,
		},
	}
	headlessHandleRuntimeEvent(&harness, &created)
	ClientTransportRuntimeEvent_deinit(&created)
	testExpectString(
		t,
		testHeadlessTakeOutput(&builder),
		`{"event":"room_created","serverID":908,"roomID":9,"name":"random",` +
		`"description":"Off","roomType":2,"access":0,"historyVisibility":0,"isMember":false,` +
		`"encrypted":false,"logVersion":0}` +
		"\n",
		"the room_created event",
	)
	testing.expect(
		t,
		harness.pendingEvents[.RoomCreated] == 1 && harness.state.selected_channel_id == 9,
		"expected room_created to count for wait and select the new room",
	)

	headlessHandleLine(&harness, "help")
	output = testHeadlessTakeOutput(&builder)
	testing.expect(
		t,
		strings.contains(
			output,
			`{"usage":"room-create TYPE[,public|member-invite|admin-invite]` +
			`[,from-join|full][,no-join][,encrypted][,managers=ID+ID|managers=none] ` +
			`NAME [DESCRIPTION...]",`,
		) &&
		strings.contains(output, `"room_created"`),
		fmt.tprintf("expected help to list the room commands and events, got %s", output),
	)
}

@(test)
testHeadlessParsesOptionalText :: proc(t: ^testing.T) {
	commands := HEADLESS_COMMANDS[:]
	parsed, err := headlessParseCommand(commands, "room-create both random")
	testing.expect(t, err == .None && parsed.argCount == 2, "expected the description optional")
	parsed, err = headlessParseCommand(commands, "room-create text random  for  fun ")
	testing.expect(t, err == .None && parsed.argCount == 3, "expected a description")
	testExpectString(t, parsed.args[2], "for  fun", "the description text")
	_, err = headlessParseCommand(commands, "room-create random")
	testing.expect(t, err == .BadArguments, "expected room-create without a type rejected")
	parsed, err = headlessParseCommand(commands, "room-edit 4 voice lobby the front room")
	testing.expect(t, err == .None && parsed.argCount == 4, "expected an edit with text")
	testExpectString(t, parsed.args[3], "the front room", "the edit description")
	parsed, err = headlessParseCommand(commands, "admin-rename 4 lock new name")
	testing.expect(t, err == .None && parsed.argCount == 3, "expected a rename with a name")
	testExpectString(t, parsed.args[2], "new name", "the new name")
	parsed, err = headlessParseCommand(commands, "admin-rename 4 unlock")
	testing.expect(t, err == .None && parsed.argCount == 2, "expected the name optional")
	parsed, err = headlessParseCommand(commands, "admin-ban 4 spam and abuse")
	testing.expect(t, err == .None && parsed.argCount == 2, "expected a ban reason")
	_, err = headlessParseCommand(commands, "admin-role 4")
	testing.expect(t, err == .BadArguments, "expected admin-role without on|off rejected")
	_, err = headlessParseCommand(commands, "room-delete 4 now")
	testing.expect(t, err == .BadArguments, "expected extra room-delete arguments rejected")
}
