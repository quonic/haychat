package client

// Repairing a damaged member log (protocol 34, #196, common/room_log_repair.odin). Admins
// only; the server checks the admin role in the statement, so the client only decides which
// controls to offer (State_isServerAdmin).
//
// - Status: State_requestRoomLogStatus sends ClientAdminRoomLogStatus (roomID 0 for every
//   encrypted room); the answer (ServerAdminRoomLogStatus) is kept per server in
//   ServerConnection.roomLogStatus (State_roomLogStatus). A protocol error while a status is
//   pending is its refusal, and a connection change ends the wait.
// - Truncate: State_truncateRoomLog sends ClientAdminTruncateRoomLog through the admin request
//   tracker (State.adminRequest, admin.odin): the answer is ServerAdminActionResult
//   {TruncateRoomLog, roomId}, after which the status is asked for again
//   (State_roomLogTruncateApplied).
// - Every member's client hears of a truncation as a ServerRoomLog whose head is below the
//   version it verified, and fails the room (room_log.odin, Rollback); members whose client
//   had verified no further than the new head carry on.
//
// The Admin section of Server settings shows it (buildRoomLogRepairView), and the ban warning
// for failedRoomIDs points to it.

import "../common"
import "core:encoding/cbor"
import "core:fmt"
import "core:strings"

// ── Transport (network worker) ───────────────────────────────────

// Whether a status the server sent is one it could have sent.
roomLogStatusIsValid :: proc(status: common.RoomLogStatus) -> bool {
	return(
		status.roomId > 0 &&
		status.storedVersion >= 0 &&
		status.goodVersion >= 0 &&
		status.goodVersion <= status.entryCount &&
		(status.failingVersion == 0 || status.failingVersion > status.goodVersion) &&
		int(status.error) <= int(max(common.RoomLogError)) \
	)
}

ClientServerTransport_translateRoomLogStatusPacket :: proc(
	transport: ^ClientServerTransport,
	innerPacket: common.Packet,
) -> (
	ClientTransportRuntimeEvent,
	bool,
) {
	payload: common.ServerAdminRoomLogStatusPayload
	valid :=
		cbor.unmarshal(innerPacket.payload, &payload) == nil &&
		payload.roomId >= 0 &&
		payload.checkedRooms >= 0 &&
		payload.damagedRooms >= 0 &&
		len(payload.rooms) <= common.ROOM_LOG_STATUS_ROOMS_MAX &&
		(payload.roomId == 0 || len(payload.rooms) == 1)
	for status in payload.rooms {
		valid = valid && roomLogStatusIsValid(status)
		valid = valid && (payload.roomId == 0 || status.roomId == payload.roomId)
	}
	if !valid {
		common.ServerAdminRoomLogStatusPayload_deinit(&payload)
		return ClientServerTransport_invalidPayloadEvent(
				transport,
				"invalid room log status payload",
			),
			true
	}
	return ClientTransportRuntimeEvent {
			kind = .RoomLogStatusReceived,
			serverID = transport.serverID,
			roomLogStatus = payload,
		},
		true
}

ClientServerTransport_requestRoomLogStatus :: proc(
	transport: ^ClientServerTransport,
	roomID: int,
) -> bool {
	return ClientServerTransport_sendEncryptedRuntimeMessage(
		transport,
		.ClientAdminRoomLogStatus,
		common.ClientAdminRoomLogStatusPayload{roomId = roomID},
	)
}

ClientServerTransport_truncateRoomLog :: proc(
	transport: ^ClientServerTransport,
	roomID, toVersion: int,
) -> bool {
	return ClientServerTransport_sendEncryptedRuntimeMessage(
		transport,
		.ClientAdminTruncateRoomLog,
		common.ClientAdminTruncateRoomLogPayload{roomId = roomID, toVersion = toVersion},
	)
}

// ── State ────────────────────────────────────────────────────────

// Asks for the member log status of roomID, or of every encrypted room (roomID 0). The
// answer arrives as RoomLogStatusReceived. Returns "" when the request went out.
State_requestRoomLogStatus :: proc(state: ^State, serverID: int, roomID := 0) -> string {
	transportIndex := State_selectedTransportIndexForServerID(state^, serverID)
	if transportIndex < 0 {
		return "No server transport selected"
	}
	if !State_isServerConnected(state, serverID) {
		return NOT_CONNECTED_MESSAGE
	}
	transport := &state.serverTransports[transportIndex]
	ClientNetworkWorker_lock(state.networkWorker)
	sent := ClientServerTransport_requestRoomLogStatus(transport, max(roomID, 0))
	ClientNetworkWorker_unlock(state.networkWorker)
	if !sent {
		return "Failed to send the member log check"
	}
	if index := State_serverConnectionIndex(state^, serverID); index >= 0 {
		connection := &state.serverConnections[index]
		connection.roomLogStatusPending = true
		delete(connection.roomLogStatusError)
		connection.roomLogStatusError = ""
	}
	return ""
}

// Truncates roomID's damaged log to toVersion (its goodVersion) through the admin request
// tracker. Returns "" when the request went out.
State_truncateRoomLog :: proc(state: ^State, serverID, roomID, toVersion: int) -> string {
	return State_sendAdminRequest(
		state,
		serverID,
		AdminRequest{action = .TruncateRoomLog, roomID = roomID, toVersion = toVersion},
	)
}

// The last status held for serverID (borrowed), whether one arrived in this session, whether a
// request waits, and the refusal of the last one.
State_roomLogStatus :: proc(
	state: ^State,
	serverID: int,
) -> (
	status: common.ServerAdminRoomLogStatusPayload,
	loaded: bool,
	pending: bool,
	errorMessage: string,
) {
	index := State_serverConnectionIndex(state^, serverID)
	if index < 0 {
		return
	}
	connection := &state.serverConnections[index]
	return connection.roomLogStatus,
		connection.hasRoomLogStatus,
		connection.roomLogStatusPending,
		connection.roomLogStatusError
}

// RoomLogStatusReceived: keeps the status (takes the rooms).
State_roomLogStatusReceived :: proc(
	state: ^State,
	serverID: int,
	payload: ^common.ServerAdminRoomLogStatusPayload,
) {
	defer common.ServerAdminRoomLogStatusPayload_deinit(payload)
	index := State_serverConnectionIndex(state^, serverID)
	if index < 0 {
		return
	}
	connection := &state.serverConnections[index]
	common.ServerAdminRoomLogStatusPayload_deinit(&connection.roomLogStatus)
	connection.roomLogStatus = payload^
	payload.rooms = nil
	connection.hasRoomLogStatus = true
	connection.roomLogStatusPending = false
	delete(connection.roomLogStatusError)
	connection.roomLogStatusError = ""
}

// A protocol error on serverID answers a pending status ("Admin permission required").
State_roomLogStatusProtocolError :: proc(state: ^State, serverID: int, message: string) {
	index := State_serverConnectionIndex(state^, serverID)
	if index < 0 || !state.serverConnections[index].roomLogStatusPending {
		return
	}
	connection := &state.serverConnections[index]
	connection.roomLogStatusPending = false
	delete(connection.roomLogStatusError)
	connection.roomLogStatusError = strings.clone(
		len(message) > 0 ? message : "The server refused the request.",
	)
}

// A truncation this admin made (ServerAdminActionResult TruncateRoomLog): a status already on
// screen is asked for again (for every room when that is what it showed); nothing is replayed
// when none was asked for.
State_roomLogTruncateApplied :: proc(state: ^State, serverID: int) {
	index := State_serverConnectionIndex(state^, serverID)
	if index < 0 || !state.serverConnections[index].hasRoomLogStatus {
		return
	}
	_ = State_requestRoomLogStatus(
		state,
		serverID,
		state.serverConnections[index].roomLogStatus.roomId,
	)
}

// ── View model ───────────────────────────────────────────────────

// One damaged room in Server settings, Admin, Member logs. Strings are temp-allocated.
RoomLogRepairRow :: struct {
	roomID:      int,
	roomName:    string,
	detail:      string,
	damaged:     bool,
	// The version a truncation keeps, 0 when nothing replays (delete the room instead).
	toVersion:   int,
	actionLabel: string,
	confirmText: string,
}

RoomLogRepairView :: struct {
	visible: bool,
	pending: bool,
	loaded:  bool,
	summary: string,
	error:   string,
	rows:    [dynamic]RoomLogRepairRow,
}

ROOM_LOG_REPAIR_CHECK_LABEL :: "Check member logs"

// What a damaged room's row says, for people (temp-allocated).
roomLogStatusDetail :: proc(status: common.RoomLogStatus) -> string {
	if !common.roomLogStatusIsDamaged(status) {
		return fmt.tprintf("Intact: %d entries, version %d.", status.entryCount, status.storedVersion)
	}
	if status.failingVersion != 0 {
		return fmt.tprintf(
			"Version %d does not replay (%v). It replays to version %d of %d stored entries; " +
			"the room's head is version %d.",
			status.failingVersion,
			status.error,
			status.goodVersion,
			status.entryCount,
			status.storedVersion,
		)
	}
	return fmt.tprintf(
		"Its %d entries replay, but the room's head is version %d.",
		status.entryCount,
		status.storedVersion,
	)
}

// The confirmation a truncation asks for: what members will see.
roomLogTruncateConfirmText :: proc(roomName: string, toVersion: int) -> string {
	return fmt.tprintf(
		"Truncate the member list of %s to version %d? The later entries are deleted, with the " +
		"room's keys and encrypted messages of the later versions, and its members become who " +
		"they were at version %d. Members whose app verified a later version will see \"%s\" " +
		"for this room until they leave it. Voice in the room ends.",
		roomName,
		toVersion,
		toVersion,
		ROOM_LOG_CHANGED_WARNING,
	)
}

// The room's name from the admin's room lists, "room N" otherwise (temp-allocated).
State_roomLogRepairRoomName :: proc(state: ^State, serverID, roomID: int) -> string {
	index := State_serverRoomCacheIndex(state^, serverID)
	if index >= 0 {
		cache := &state.server_room_caches[index]
		for entry in cache.adminRooms {
			if entry.room.id == roomID {
				return fmt.tprintf("#%s", entry.room.name)
			}
		}
		for room in cache.rooms {
			if room.id == roomID {
				return fmt.tprintf("#%s", room.name)
			}
		}
	}
	return fmt.tprintf("room %d", roomID)
}

// The Member logs block of the Admin section: visible to admins only.
buildRoomLogRepairView :: proc(state: ^State, serverID: int) -> RoomLogRepairView {
	view := RoomLogRepairView {
		visible = State_isServerAdmin(state, serverID),
		rows    = make([dynamic]RoomLogRepairRow, context.temp_allocator),
	}
	if !view.visible {
		return view
	}
	status, loaded, pending, errorMessage := State_roomLogStatus(state, serverID)
	view.loaded = loaded
	view.pending = pending
	view.error = errorMessage
	switch {
	case pending:
		view.summary = "Checking the encrypted rooms' member lists…"
	case !loaded:
		view.summary = "Replays every encrypted room's member list and lists the damaged ones."
	case status.roomId != 0:
		view.summary = fmt.tprintf(
			"%s:",
			State_roomLogRepairRoomName(state, serverID, status.roomId),
		)
	case status.damagedRooms == 0:
		view.summary = fmt.tprintf(
			"Checked %d encrypted %s: every member list replays.",
			status.checkedRooms,
			status.checkedRooms == 1 ? "room" : "rooms",
		)
	case:
		view.summary = fmt.tprintf(
			"Checked %d encrypted %s: %d %s a damaged member list.",
			status.checkedRooms,
			status.checkedRooms == 1 ? "room" : "rooms",
			status.damagedRooms,
			status.damagedRooms == 1 ? "has" : "have",
		)
	}
	if !loaded || pending {
		return view
	}
	for room in status.rooms {
		name := State_roomLogRepairRoomName(state, serverID, room.roomId)
		row := RoomLogRepairRow {
			roomID   = room.roomId,
			roomName = name,
			detail   = roomLogStatusDetail(room),
			damaged  = common.roomLogStatusIsDamaged(room),
		}
		if row.damaged && room.goodVersion > 0 {
			row.toVersion = room.goodVersion
			row.actionLabel = fmt.tprintf("Truncate log to version %d…", room.goodVersion)
			row.confirmText = roomLogTruncateConfirmText(name, room.goodVersion)
		} else if row.damaged {
			row.detail = fmt.tprintf("%s Nothing replays: delete the room.", row.detail)
		}
		append(&view.rows, row)
	}
	return view
}
