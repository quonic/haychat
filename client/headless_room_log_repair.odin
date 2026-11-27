package client

// Headless member log repair (protocol 35, #196; docs/testing-harness.md "Encrypted rooms"):
// room-log-status [ROOM_ID] asks for the member log status of one encrypted room or of every
// one (admins), answered by room_log_status; room-log-truncate ROOM_ID VERSION truncates a
// damaged log to its goodVersion (admins), answered by admin_result room-log-truncate with
// roomID, after which every member's client hears the new head (room_log).

import "../common"
import "core:fmt"
import "core:strconv"

HeadlessRoomLogStatusEntryJSON :: struct {
	roomID:         int,
	storedVersion:  int,
	entryCount:     int,
	goodVersion:    int,
	failingVersion: int,
	error:          string,
	damaged:        bool,
}

// room_log_status: roomID as asked (0 for every encrypted room), the statuses (every room
// asked for by ID; otherwise only damaged ones), and for every room how many were checked and
// damaged.
HeadlessRoomLogStatusJSON :: struct {
	event:        string,
	serverID:     int,
	roomID:       int,
	checkedRooms: int,
	damagedRooms: int,
	rooms:        []HeadlessRoomLogStatusEntryJSON,
}

HeadlessRoomLogRepairRequestJSON :: struct {
	ok:        bool,
	cmd:       string,
	serverID:  int,
	roomID:    int,
	toVersion: int,
}

headlessRenderRoomLogStatusEvent :: proc(
	event: ^ClientTransportRuntimeEvent,
	allocator := context.allocator,
) -> (
	line: string,
	kind: HeadlessEventKind,
	ok: bool,
) {
	kind = .RoomLogStatus
	status := &event.roomLogStatus
	rooms := make([]HeadlessRoomLogStatusEntryJSON, len(status.rooms), context.temp_allocator)
	for room, index in status.rooms {
		rooms[index] = {
			roomID         = room.roomId,
			storedVersion  = room.storedVersion,
			entryCount     = room.entryCount,
			goodVersion    = room.goodVersion,
			failingVersion = room.failingVersion,
			error          = room.error == .None ? "" : fmt.tprintf("%v", room.error),
			damaged        = common.roomLogStatusIsDamaged(room),
		}
	}
	line = headlessMarshal(
		HeadlessRoomLogStatusJSON {
			event = HEADLESS_EVENT_NAMES[kind],
			serverID = event.serverID,
			roomID = status.roomId,
			checkedRooms = status.checkedRooms,
			damagedRooms = status.damagedRooms,
			rooms = rooms,
		},
		allocator,
	)
	return line, kind, true
}

// room-log-status [ROOM_ID]
headlessCommandRoomLogStatus :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	roomID := 0
	if command.argCount > 0 {
		value, ok := strconv.parse_int(command.args[0])
		if !ok || value < 0 {
			headlessWriteError(harness, command.name, "ROOM_ID must be a room ID (0 for every room)")
			return
		}
		roomID = value
	}
	state := &harness.state
	serverID := state.selected_server_id
	if errorMessage := State_requestRoomLogStatus(state, serverID, roomID); len(errorMessage) > 0 {
		headlessWriteError(harness, command.name, errorMessage)
		return
	}
	headlessWriteJSON(
		harness,
		HeadlessRoomLogRepairRequestJSON {
			ok = true,
			cmd = command.name,
			serverID = serverID,
			roomID = roomID,
		},
	)
}

// room-log-truncate ROOM_ID VERSION
headlessCommandRoomLogTruncate :: proc(
	harness: ^HeadlessHarness,
	command: ^HeadlessParsedCommand,
) {
	roomID, roomOK := strconv.parse_int(command.args[0])
	toVersion, versionOK := strconv.parse_int(command.args[1])
	if !roomOK || roomID <= 0 || !versionOK || toVersion < 0 {
		headlessWriteError(harness, command.name, "usage: room-log-truncate ROOM_ID VERSION")
		return
	}
	state := &harness.state
	serverID := state.selected_server_id
	if errorMessage := State_truncateRoomLog(state, serverID, roomID, toVersion);
	   len(errorMessage) > 0 {
		headlessWriteError(harness, command.name, errorMessage)
		return
	}
	headlessWriteJSON(
		harness,
		HeadlessRoomLogRepairRequestJSON {
			ok = true,
			cmd = command.name,
			serverID = serverID,
			roomID = roomID,
			toVersion = toVersion,
		},
	)
}

// admin_result's roomID: only a room-log-truncate names a room.
headlessAdminResultRoom :: proc(event: ^ClientTransportRuntimeEvent) -> Maybe(int) {
	if event.adminAction == .TruncateRoomLog && event.roomID > 0 {
		return event.roomID
	}
	return nil
}
