#+feature dynamic-literals
package client

import "../common"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:testing"

// Room permissions and role rooms on the client (protocol 24, room_permissions.odin): what the
// room list's myPermissions turns on and off (the composer, voice, the Edit form), the
// Permissions page and the access role picker through their bridges, and the harness commands
// and events.

ROOM_PERMISSIONS_TEST_SELF :: 3
ROOM_PERMISSIONS_TEST_ROLE :: 5

@(private = "file")
roomPermissionsTestState :: proc(
	serverID: int,
	permissions: common.ServerPermissions = {},
	isAdmin := false,
) -> State {
	state := testUpdateStateForServer(testRoomAdminServer(serverID))
	event := ClientTransportRuntimeEvent {
		kind        = .Connected,
		serverID    = serverID,
		userID      = ROOM_PERMISSIONS_TEST_SELF,
		nickname    = strings.clone(state.config.display_name),
		isAdmin     = isAdmin,
		permissions = permissions,
	}
	State_applyRuntimeEvent(&state, &event)
	ClientTransportRuntimeEvent_deinit(&event)
	roles := ClientTransportRuntimeEvent {
		kind     = .RoleListReceived,
		serverID = serverID,
	}
	append(
		&roles.roles,
		common.RoleSummary {
			id = 1,
			name = strings.clone("admin"),
			permissions = common.SERVER_PERMISSIONS_ALL,
			builtin = true,
		},
		common.RoleSummary{id = ROOM_PERMISSIONS_TEST_ROLE, name = strings.clone("speakers")},
	)
	State_applyRuntimeEvent(&state, &roles)
	ClientTransportRuntimeEvent_deinit(&roles)
	return state
}

roomPermissionsBridgeTestMutex: sync.Mutex
roomPermissionsBridgeTestRequests: [dynamic]RoomPermissionsRequest

// Records the requests of this file's servers (2401..2409) only: opening the room editor
// fetches grants too, and other tests open it on other servers while this stub is installed.
@(private = "file")
roomPermissionsBridgeTestStub :: proc(
	transport: ^ClientServerTransport,
	request: RoomPermissionsRequest,
) -> bool {
	if transport.serverID < 2401 || transport.serverID > 2409 {
		return ClientServerTransport_sendRoomPermissions(transport, request)
	}
	append(&roomPermissionsBridgeTestRequests, request)
	return true
}

@(private = "file")
roomPermissionsTestGrants :: proc(
	state: ^State,
	serverID, roomID: int,
	everyone: common.RoomPermissions,
	roles: []common.RoomRoleGrant,
	accessRoleIDs: []int,
	mine: common.RoomPermissions,
) {
	event := ClientTransportRuntimeEvent {
		kind = .RoomPermissionsReceived,
		serverID = serverID,
		roomID = roomID,
		roomPermissions = {roomId = roomID, everyone = everyone, myPermissions = mine},
	}
	append(&event.roomPermissions.roles, ..roles)
	append(&event.roomPermissions.accessRoleIds, ..accessRoleIDs)
	State_applyRuntimeEvent(state, &event)
	ClientTransportRuntimeEvent_deinit(&event)
}

@(test)
testRoomPermissionsGateTheComposerAndVoice :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	state := roomPermissionsTestState(2401)
	defer State_deinit(&state)
	testApplyNamedRooms(
		&state,
		2401,
		{id = 1, name = "general"},
		{id = 2, name = "announcements", myPermissions = {.SpeakInVoice}},
		{id = 3, name = "stage", myPermissions = {.SendMessages}},
	)

	view := buildRoomView(&state)
	testing.expect(t, view.allowsChat, "expected #general to take messages")
	State_switchToChannel(&state, 2401, 2)
	view = buildRoomView(&state)
	testing.expect(
		t,
		!view.allowsChat && view.voiceOnlyNote == ROOM_SEND_NOT_PERMITTED_NOTE,
		fmt.tprintf("expected a read-only room, got %v", view.voiceOnlyNote),
	)
	testing.expect(t, !view.canEditRoom, "expected no Edit without EditRoom")
	draft := State_selectedRoomDraft(&state)
	append(draft, "hello")
	State_sendChannelChat(&state)
	testing.expect(
		t,
		state.chat_status_message == ROOM_SEND_NOT_PERMITTED_NOTE &&
		string(State_selectedRoomDraft(&state)[:]) == "hello",
		"expected the send refused locally with the draft kept",
	)

	// Server permissions imply room ones: ManageRoomMembers gives ManageMembers everywhere.
	testing.expect(
		t,
		State_roomPermissions(&state, 2401, 2) == {.SpeakInVoice},
		"expected only the room's own grant",
	)

	// Voice in a room without SpeakInVoice: joined, muted, and told why.
	state.voice.status = .Joined
	state.voice.serverID = 2401
	state.voice.roomID = 3
	State_voiceApplySpeakPermission(&state)
	bar := buildVoiceBarView(&state)
	testing.expect(
		t,
		state.voice.speakDenied && bar.speakDenied && bar.note == VOICE_SPEAK_NOT_PERMITTED_NOTE,
		fmt.tprintf("expected voice to say it cannot speak, got %q", bar.note),
	)
	// A new room list that grants it again lifts it.
	testApplyNamedRooms(&state, 2401, {id = 1, name = "general"}, {id = 3, name = "stage"})
	testing.expect(t, !state.voice.speakDenied, "expected speaking allowed after the grant")
	state.voice = {}
}

@(test)
testRoomPermissionsFollowServerPermissionsAndEdits :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	state := roomPermissionsTestState(2402, {.ManageRoomMembers})
	defer State_deinit(&state)
	testApplyNamedRooms(&state, 2402, {id = 1, name = "general", myPermissions = {.EditRoom}})
	testing.expect(
		t,
		State_roomPermissions(&state, 2402, 1) == {.EditRoom, .ManageMembers},
		"expected ManageRoomMembers to imply ManageMembers",
	)
	testing.expect(t, State_canEditRoom(&state, 2402, 1), "expected EditRoom to allow editing")
	testing.expect(
		t,
		State_roomGrantable(&state, 2402, 1) == {.EditRoom, .ManageMembers},
		"expected only held bits grantable without ManageRooms",
	)

	// ServerEditRoom carries no permissions: the room keeps the list's.
	edited := ClientTransportRuntimeEvent {
		kind = .RoomEdited,
		serverID = 2402,
		roomID = 1,
		room = {
			id = 1,
			name = strings.clone("lobby"),
			description = strings.clone(""),
			roomType = .ChatAndVoice,
			access = .Public,
		},
	}
	State_applyRuntimeEvent(&state, &edited)
	ClientTransportRuntimeEvent_deinit(&edited)
	room := State_knownRoom(&state, 2402, 1)
	testing.expect(
		t,
		room != nil && room.name == "lobby" && room.myPermissions == {.EditRoom},
		"expected the edit to keep myPermissions",
	)

	// An admin holds every room permission.
	admin := roomPermissionsTestState(2403, {}, isAdmin = true)
	defer State_deinit(&admin)
	testApplyNamedRooms(&admin, 2403, {id = 1, name = "general", myPermissions = {.SendMessages}})
	testing.expect(
		t,
		State_roomPermissions(&admin, 2403, 1) == common.ROOM_PERMISSIONS_ALL,
		"expected an admin to hold every room permission",
	)
}

@(test)
testRoomPermissionsPageSendsThroughTheBridge :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	sync.mutex_lock(&roomPermissionsBridgeTestMutex)
	defer sync.mutex_unlock(&roomPermissionsBridgeTestMutex)
	roomPermissionsSendBridge = roomPermissionsBridgeTestStub
	defer {
		roomPermissionsSendBridge = ClientServerTransport_sendRoomPermissions
		delete(roomPermissionsBridgeTestRequests)
		roomPermissionsBridgeTestRequests = nil
	}

	// A member holding EditRoom and SendMessages, no server permission.
	state := roomPermissionsTestState(2404)
	defer State_deinit(&state)
	testApplyNamedRooms(
		&state,
		2404,
		{id = 1, name = "general"},
		{id = 2, name = "stage", myPermissions = {.SendMessages, .EditRoom}},
	)
	State_openRoomPermissions(&state, 2404, 2)
	testing.expect(
		t,
		state.roomEditor.mode == .Permissions &&
		len(roomPermissionsBridgeTestRequests) == 1 &&
		!roomPermissionsBridgeTestRequests[0].set &&
		roomPermissionsBridgeTestRequests[0].roomID == 2,
		"expected the page to fetch the room's grants",
	)
	view := buildRoomPermissionsView(&state)
	testing.expect(t, view.visible && !view.loaded, "expected the page to wait for the grants")

	roomPermissionsTestGrants(
		&state,
		2404,
		2,
		common.ROOM_PERMISSIONS_DEFAULT,
		{{roleId = ROOM_PERMISSIONS_TEST_ROLE, permissions = {.EditRoom}}},
		nil,
		{.SendMessages, .EditRoom},
	)
	view = buildRoomPermissionsView(&state)
	testing.expect(
		t,
		view.loaded && len(view.rows) == 2 && view.rows[1].label == "speakers",
		fmt.tprintf("expected Everyone and speakers, got %v", view.rows),
	)
	// Send (index 0) and Edit room (3) may change; Speak (1) and Manage members (2) may not.
	testing.expect(
		t,
		view.rows[0].cells[0].enabled &&
		view.rows[0].cells[0].checked &&
		!view.rows[0].cells[1].enabled &&
		!view.rows[0].cells[2].enabled &&
		view.rows[1].cells[3].checked,
		fmt.tprintf("expected only held bits offered, got %v", view.rows[0].cells),
	)

	State_toggleRoomEditorGrant(&state, 0, .SendMessages)
	State_toggleRoomEditorGrant(&state, 0, .SpeakInVoice) // not grantable: no change
	State_toggleRoomEditorGrant(&state, ROOM_PERMISSIONS_TEST_ROLE, .SendMessages)
	State_saveRoomEditorPermissions(&state)
	testing.expect(
		t,
		len(roomPermissionsBridgeTestRequests) == 2 && state.roomEditor.pending == .Permissions,
		"expected the save to go out",
	)
	saved := roomPermissionsBridgeTestRequests[1]
	testing.expect(
		t,
		saved.set &&
		saved.roomID == 2 &&
		saved.everyone == {.SpeakInVoice, .AttachFiles} &&
		saved.roleCount == 1 &&
		saved.roles[0].roleId == ROOM_PERMISSIONS_TEST_ROLE &&
		saved.roles[0].permissions == {.SendMessages, .EditRoom},
		fmt.tprintf("expected a read-only everyone and the role's two bits, got %v", saved),
	)

	roomPermissionsTestGrants(
		&state,
		2404,
		2,
		{.SpeakInVoice},
		{{roleId = ROOM_PERMISSIONS_TEST_ROLE, permissions = {.SendMessages, .EditRoom}}},
		nil,
		{.SendMessages, .EditRoom},
	)
	testing.expect(
		t,
		state.roomEditor.pending == .None &&
		state.roomEditor.notice == "Saved the room's permissions." &&
		state.roomEditor.grantsEveryone == {.SpeakInVoice},
		"expected the answer to finish the save",
	)
}

@(test)
testRoleRoomAccessRolesInTheForms :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	sync.mutex_lock(&roomAdminSendBridgeTestMutex)
	defer sync.mutex_unlock(&roomAdminSendBridgeTestMutex)
	sync.mutex_lock(&roomPermissionsBridgeTestMutex)
	defer sync.mutex_unlock(&roomPermissionsBridgeTestMutex)
	testRoomAdminUseStub()
	defer testRoomAdminRestore()
	roomPermissionsSendBridge = roomPermissionsBridgeTestStub
	defer {
		roomPermissionsSendBridge = ClientServerTransport_sendRoomPermissions
		delete(roomPermissionsBridgeTestRequests)
		roomPermissionsBridgeTestRequests = nil
	}
	captured: RoomAdminRequest
	roomAdminSendBridge = roomPermissionsTestCaptureAdminRequest

	state := roomPermissionsTestState(2405, {.ManageRooms})
	defer State_deinit(&state)
	testApplyNamedRooms(&state, 2405, {id = 1, name = "general"})
	State_openRoomCreator(&state)
	append(&state.roomEditor.name, "crew")
	State_setRoomEditorAccess(&state, .Role)
	view := buildRoomEditorView(&state)
	testing.expect(
		t,
		view.showAccessRoles &&
		len(view.accessRoles) == 1 &&
		view.accessRoles[0].roleID == ROOM_PERMISSIONS_TEST_ROLE &&
		!view.showEncrypt,
		fmt.tprintf("expected the speakers role offered and no encryption, got %v", view),
	)
	State_submitRoomEditor(&state)
	testing.expect(
		t,
		state.roomEditor.error == "Choose the roles whose holders are the room's members.",
		fmt.tprintf("expected a Role room to need a role, got %q", state.roomEditor.error),
	)
	State_toggleRoomEditorAccessRole(&state, ROOM_PERMISSIONS_TEST_ROLE)
	State_submitRoomEditor(&state)
	captured = roomPermissionsTestLastAdminRequest
	testing.expect(
		t,
		captured.kind == .Create &&
		captured.access == .Role &&
		captured.accessRoleCount == 1 &&
		captured.accessRoleIDs[0] == ROOM_PERMISSIONS_TEST_ROLE,
		fmt.tprintf("expected a Role room with the speakers role, got %v", captured),
	)

	// Editing a Role room waits for its access roles, then repeats them.
	testApplyNamedRooms(
		&state,
		2405,
		{id = 1, name = "general"},
		{id = 4, name = "crew", access = .Role},
	)
	State_openRoomEditor(&state, 4)
	State_submitRoomEditor(&state)
	testing.expect(
		t,
		state.roomEditor.error == "The room's roles have not arrived yet. Try again.",
		fmt.tprintf("expected the edit to wait, got %q", state.roomEditor.error),
	)
	roomPermissionsTestGrants(
		&state,
		2405,
		4,
		common.ROOM_PERMISSIONS_DEFAULT,
		nil,
		{ROOM_PERMISSIONS_TEST_ROLE},
		{.EditRoom},
	)
	State_submitRoomEditor(&state)
	captured = roomPermissionsTestLastAdminRequest
	testing.expect(
		t,
		captured.kind == .Edit &&
		captured.roomID == 4 &&
		captured.access == .Role &&
		captured.accessRoleCount == 1 &&
		captured.accessRoleIDs[0] == ROOM_PERMISSIONS_TEST_ROLE,
		fmt.tprintf("expected the edit to repeat the access roles, got %v", captured),
	)
	testing.expect(
		t,
		State_sendCreateRoom(&state, 2405, "x", "", .Chat, .Role, encrypted = true) ==
		common.ROOM_ENCRYPTED_ROLE_MESSAGE,
		"expected an encrypted Role room refused",
	)
}

roomPermissionsTestLastAdminRequest: RoomAdminRequest

@(private = "file")
roomPermissionsTestCaptureAdminRequest :: proc(
	transport: ^ClientServerTransport,
	request: RoomAdminRequest,
) -> bool {
	if transport.serverID < 2401 || transport.serverID > 2409 {
		return ClientServerTransport_sendRoomAdminRequest(transport, request)
	}
	roomPermissionsTestLastAdminRequest = request
	return true
}

@(test)
testHeadlessRoomPermissionCommandsAndEvents :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	permissions, ok := headlessParseRoomPermissions("send,edit-room")
	testing.expect(t, ok && permissions == {.SendMessages, .EditRoom}, "expected two permissions")
	_, bad := headlessParseRoomPermissions("send,fly")
	testing.expect(t, !bad, "expected an unknown permission refused")

	event := ClientTransportRuntimeEvent {
		kind = .RoomPermissionsReceived,
		serverID = 7,
		roomID = 4,
		roomPermissions = {roomId = 4, everyone = {.SpeakInVoice}, myPermissions = {.EditRoom}},
	}
	defer ClientTransportRuntimeEvent_deinit(&event)
	append(
		&event.roomPermissions.roles,
		common.RoomRoleGrant{roleId = 5, permissions = {.SendMessages, .ManageMembers}},
	)
	append(&event.roomPermissions.accessRoleIds, 5)
	line, kind, rendered := headlessRenderRuntimeEvent(&event)
	defer delete(line)
	testing.expect(t, rendered && kind == .RoomPermissions, "expected a room_permissions event")
	testExpectString(
		t,
		line,
		`{"event":"room_permissions","serverID":7,"roomID":4,"everyone":["speak"],` +
		`"roles":[{"roleID":5,"permissions":["send","manage-members"]}],"accessRoleIDs":[5],` +
		`"myPermissions":["edit-room"]}`,
		"the room_permissions JSON",
	)

	sync.mutex_lock(&roomPermissionsBridgeTestMutex)
	defer sync.mutex_unlock(&roomPermissionsBridgeTestMutex)
	roomPermissionsSendBridge = roomPermissionsBridgeTestStub
	defer {
		roomPermissionsSendBridge = ClientServerTransport_sendRoomPermissions
		delete(roomPermissionsBridgeTestRequests)
		roomPermissionsBridgeTestRequests = nil
	}
	builder := strings.builder_make()
	harness := testHeadlessHarness(&builder, 2406)
	defer testHeadlessHarnessDeinit(&harness, &builder)
	testApplyConnectedAs(&harness.state, 2406, ROOM_PERMISSIONS_TEST_SELF, true)
	_ = testHeadlessTakeOutput(&builder)
	headlessHandleLine(&harness, "room-permissions-set 4 speak 5=send,manage-members 6=none")
	testExpectString(
		t,
		testHeadlessTakeOutput(&builder),
		`{"ok":true,"cmd":"room-permissions-set","serverID":2406,"roomID":4}` + "\n",
		"the room-permissions-set result",
	)
	testing.expect(
		t,
		len(roomPermissionsBridgeTestRequests) == 1 &&
		roomPermissionsBridgeTestRequests[0].everyone == {.SpeakInVoice} &&
		roomPermissionsBridgeTestRequests[0].roleCount == 1 &&
		roomPermissionsBridgeTestRequests[0].roles[0].permissions ==
			{.SendMessages, .ManageMembers},
		"expected one role grant sent (an empty one is left out)",
	)
	headlessHandleLine(&harness, "room-permissions-set 4 fly")
	output := testHeadlessTakeOutput(&builder)
	testing.expect(
		t,
		strings.contains(output, `"ok":false`) && strings.contains(output, "usage:"),
		fmt.tprintf("expected a usage error, got %s", output),
	)
}
