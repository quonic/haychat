package client

import "../common"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:testing"

// Client tests for member log repair (protocol 34, #196, room_log_repair.odin): the transport
// decodes ServerAdminRoomLogStatus and refuses statuses the server could not have sent, the
// truncation goes through the admin request tracker with its room, the status and its refusal
// are kept per server, and the Admin section's Member logs rows say what is wrong and offer
// the truncation behind a confirmation that names the member-list warning.

@(test)
testRoomLogRepairStatusTransportAndViewModel :: proc(t: ^testing.T) {
	sync.mutex_lock(&adminSendBridgeTestMutex)
	defer sync.mutex_unlock(&adminSendBridgeTestMutex)
	testAdminUseStub()
	defer testAdminRestore()
	defer free_all(context.temp_allocator)

	transport := testAdminTransport(955)
	defer common.TransportState_deinit(&transport.transport)
	defer delete(transport.lastError)
	damaged := common.RoomLogStatus {
		roomId         = 12,
		storedVersion  = 6,
		entryCount     = 6,
		goodVersion    = 4,
		failingVersion = 5,
		error          = .BadSignature,
	}
	{
		rooms := make([dynamic]common.RoomLogStatus, context.temp_allocator)
		append(&rooms, damaged)
		event := testAdminTranslate(
			&transport,
			.ServerAdminRoomLogStatus,
			common.ServerAdminRoomLogStatusPayload {
				rooms = rooms,
				checkedRooms = 3,
				damagedRooms = 1,
			},
		)
		defer ClientTransportRuntimeEvent_deinit(&event)
		assert(
			event.kind == .RoomLogStatusReceived &&
			len(event.roomLogStatus.rooms) == 1 &&
			event.roomLogStatus.rooms[0] == damaged &&
			event.roomLogStatus.checkedRooms == 3,
			fmt.tprintf("expected the status event, got %v", event.kind),
		)
	}
	// A good version past the stored entries, a failing version at or below the good one, and
	// a one-room answer naming another room are refused.
	bad := [?]common.RoomLogStatus {
		{roomId = 12, storedVersion = 3, entryCount = 3, goodVersion = 4},
		{roomId = 12, storedVersion = 3, entryCount = 3, goodVersion = 2, failingVersion = 2},
		{roomId = 0, storedVersion = 3, entryCount = 3, goodVersion = 3},
	}
	for status in bad {
		rooms := make([dynamic]common.RoomLogStatus, context.temp_allocator)
		append(&rooms, status)
		event := testAdminTranslate(
			&transport,
			.ServerAdminRoomLogStatus,
			common.ServerAdminRoomLogStatusPayload{roomId = 0, rooms = rooms},
		)
		defer ClientTransportRuntimeEvent_deinit(&event)
		assert(event.kind == .ProtocolError, fmt.tprintf("expected %v refused", status))
	}
	{
		rooms := make([dynamic]common.RoomLogStatus, context.temp_allocator)
		append(&rooms, damaged)
		event := testAdminTranslate(
			&transport,
			.ServerAdminRoomLogStatus,
			common.ServerAdminRoomLogStatusPayload{roomId = 13, rooms = rooms},
		)
		defer ClientTransportRuntimeEvent_deinit(&event)
		assert(event.kind == .ProtocolError, "expected a one-room answer for another room refused")
	}
	{
		event := testAdminTranslate(
			&transport,
			.ServerAdminActionResult,
			common.ServerAdminActionResultPayload {
				action = .TruncateRoomLog,
				roomId = 12,
				message = "Truncated the member log",
			},
		)
		defer ClientTransportRuntimeEvent_deinit(&event)
		assert(
			event.kind == .AdminActionResult &&
			event.adminAction == .TruncateRoomLog &&
			event.roomID == 12,
			"expected the truncation's answer to name room 12",
		)
	}

	server := testRoomAdminServer(955)
	state := testUpdateStateForServer(server)
	defer State_deinit(&state)
	testApplyConnectedAs(&state, server.id, 3, true)

	view := buildRoomLogRepairView(&state, server.id)
	assert(
		view.visible && !view.loaded && len(view.rows) == 0,
		"expected the block offered to an admin before any check",
	)

	// The truncation goes through the admin bridge with its room and version.
	testExpectString(t, State_truncateRoomLog(&state, server.id, 12, 4), "", "the truncation")
	assert(
		adminSendBridgeTestCount == 1 &&
		adminSendBridgeTestLast.action == .TruncateRoomLog &&
		adminSendBridgeTestLast.roomID == 12 &&
		adminSendBridgeTestLast.toVersion == 4 &&
		state.adminRequest.pending &&
		state.adminRequest.roomID == 12,
		fmt.tprintf("expected the truncation tracked, got %v", adminSendBridgeTestLast),
	)

	// A status for every room arrives: one damaged room, named from the room list.
	index := State_serverConnectionIndex(state, server.id)
	state.serverConnections[index].roomLogStatusPending = true
	rooms := make([dynamic]common.RoomLogStatus)
	append(&rooms, damaged, common.RoomLogStatus{roomId = 14, storedVersion = 2})
	payload := common.ServerAdminRoomLogStatusPayload {
		rooms        = rooms,
		checkedRooms = 5,
		damagedRooms = 2,
	}
	State_roomLogStatusReceived(&state, server.id, &payload)
	assert(payload.rooms == nil, "expected the state to take the rooms")
	view = buildRoomLogRepairView(&state, server.id)
	assert(
		view.loaded && !view.pending && len(view.rows) == 2,
		fmt.tprintf("expected two rows, got %v", view),
	)
	assert(
		view.summary == "Checked 5 encrypted rooms: 2 have a damaged member list.",
		fmt.tprintf("unexpected summary %q", view.summary),
	)
	row := view.rows[0]
	assert(
		row.roomID == 12 &&
		row.damaged &&
		row.toVersion == 4 &&
		row.actionLabel == "Truncate log to version 4…" &&
		strings.contains(row.detail, "Version 5 does not replay (BadSignature)") &&
		strings.contains(row.confirmText, ROOM_LOG_CHANGED_WARNING) &&
		strings.contains(row.confirmText, "version 4"),
		fmt.tprintf("expected room 12's row to offer version 4, got %v", row),
	)
	nothing := view.rows[1]
	assert(
		nothing.damaged && nothing.toVersion == 0 && len(nothing.actionLabel) == 0 &&
		strings.contains(nothing.detail, "delete the room"),
		fmt.tprintf("expected a log with nothing to keep to offer no truncation, got %v",
			nothing),
	)

	// A refusal while pending is kept, and the block shows it.
	state.serverConnections[index].roomLogStatusPending = true
	State_roomLogStatusProtocolError(&state, server.id, "Admin permission required")
	view = buildRoomLogRepairView(&state, server.id)
	assert(
		!view.pending && view.error == "Admin permission required",
		fmt.tprintf("expected the refusal shown, got %q", view.error),
	)
	// Not offered to someone who is no admin.
	testApplyConnectedAs(&state, server.id, 3, false)
	assert(!buildRoomLogRepairView(&state, server.id).visible, "expected no block for a member")
}

// The harness: room-log-truncate goes through the admin bridge, admin_result names the room,
// and room_log_status lists each status with whether it is damaged.
@(test)
testHeadlessRoomLogRepairCommandsAndEvents :: proc(t: ^testing.T) {
	sync.mutex_lock(&adminSendBridgeTestMutex)
	defer sync.mutex_unlock(&adminSendBridgeTestMutex)
	testAdminUseStub()
	defer testAdminRestore()

	builder := strings.builder_make()
	harness := testHeadlessHarness(&builder, 955)
	defer testHeadlessHarnessDeinit(&harness, &builder)
	testApplyConnectedAs(&harness.state, 955, 3, true)

	headlessHandleLine(&harness, "room-log-truncate 12 4")
	testExpectString(
		t,
		testHeadlessTakeOutput(&builder),
		`{"ok":true,"cmd":"room-log-truncate","serverID":955,"roomID":12,"toVersion":4}` + "\n",
		"the truncation request",
	)
	assert(
		adminSendBridgeTestLast.action == .TruncateRoomLog &&
		adminSendBridgeTestLast.roomID == 12 &&
		adminSendBridgeTestLast.toVersion == 4,
		fmt.tprintf("expected the truncation sent, got %v", adminSendBridgeTestLast),
	)
	headlessHandleLine(&harness, "room-log-truncate 12 none")
	testExpectString(
		t,
		testHeadlessTakeOutput(&builder),
		`{"ok":false,"cmd":"room-log-truncate","error":"usage: room-log-truncate ROOM_ID ` +
		`VERSION"}` + "\n",
		"the truncation usage error",
	)

	answer := ClientTransportRuntimeEvent {
		kind        = .AdminActionResult,
		serverID    = 955,
		adminAction = .TruncateRoomLog,
		roomID      = 12,
		message     = strings.clone("Truncated the member log"),
	}
	headlessHandleRuntimeEvent(&harness, &answer)
	ClientTransportRuntimeEvent_deinit(&answer)
	output := testHeadlessTakeOutput(&builder)
	assert(
		strings.has_prefix(
			output,
			`{"event":"admin_result","serverID":955,"action":"room-log-truncate","userID":0,` +
			`"message":"Truncated the member log","roleID":0,"inviteID":0,"requestID":0,` +
			`"roomID":12}` + "\n",
		),
		fmt.tprintf("expected admin_result naming room 12, got %q", output),
	)

	status := ClientTransportRuntimeEvent {
		kind     = .RoomLogStatusReceived,
		serverID = 955,
		roomLogStatus = {checkedRooms = 2, damagedRooms = 1},
	}
	append(
		&status.roomLogStatus.rooms,
		common.RoomLogStatus {
			roomId = 12,
			storedVersion = 6,
			entryCount = 6,
			goodVersion = 4,
			failingVersion = 5,
			error = .BadSignature,
		},
	)
	headlessHandleRuntimeEvent(&harness, &status)
	ClientTransportRuntimeEvent_deinit(&status)
	testExpectString(
		t,
		testHeadlessTakeOutput(&builder),
		`{"event":"room_log_status","serverID":955,"roomID":0,"checkedRooms":2,` +
		`"damagedRooms":1,"rooms":[{"roomID":12,"storedVersion":6,"entryCount":6,` +
		`"goodVersion":4,"failingVersion":5,"error":"BadSignature","damaged":true}]}` + "\n",
		"the status event",
	)
}
