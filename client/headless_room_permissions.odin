package client

import "../common"
import "core:strings"

// Room permissions in the headless harness (protocol 24, room_permissions.odin). Permissions
// are lists of the words roomPermissionWord gives: send, speak, manage-members, edit-room.
// Like the other admin commands, the harness checks nothing the server checks, so an agent can
// see the server refuse (protocol_error).
//
// - room_list, rooms and admin_rooms carry each room's myPermissions (this account's set).
// - room-permissions ROOM_ID: asks for the room's grants; the answer is room_permissions
//   {roomID, everyone, roles: [{roleID, permissions}], accessRoleIDs, myPermissions}.
// - room-permissions-set ROOM_ID EVERYONE [ROLE_ID=PERMISSIONS...]: replaces the room's
//   grants (EVERYONE and each role's list may be `none`); answered by room_permissions, and
//   the members' sessions get a fresh room_list.
// - room-create and room-edit take roles=ID+ID for a Role room. room-edit of a Role room without
//   it repeats the roles of the room's last room_permissions.

// The words of a set, in enum order, in allocator.
headlessRoomPermissionNames :: proc(
	permissions: common.RoomPermissions,
	allocator := context.temp_allocator,
) -> []string {
	names := make([dynamic]string, 0, allocator)
	for permission in ROOM_PERMISSION_ORDER {
		if permission in permissions {
			append(&names, roomPermissionWord(permission))
		}
	}
	return names[:]
}

// Parses "send,speak" or "none".
headlessParseRoomPermissions :: proc(
	text: string,
) -> (
	permissions: common.RoomPermissions,
	ok: bool,
) {
	if text == "none" {
		return {}, true
	}
	remaining := text
	for word in strings.split_iterator(&remaining, ",") {
		permission, found := roomPermissionFromWord(word)
		if !found {
			return {}, false
		}
		permissions += {permission}
	}
	return permissions, true
}

// A RoomSummary as the harness prints it: the protocol's fields, myPermissions as words.
HeadlessRoomJSON :: struct {
	id:                int,
	name:              string,
	description:       string,
	lastReadMessageId: int,
	unreadCount:       int,
	roomType:          int,
	access:            int,
	historyVisibility: int,
	encrypted:         bool,
	logVersion:        int,
	myPermissions:     []string,
}

HeadlessAdminRoomJSON :: struct {
	room:        HeadlessRoomJSON,
	isMember:    bool,
	memberCount: int,
}

headlessRoom :: proc(
	room: common.RoomSummary,
	allocator := context.temp_allocator,
) -> HeadlessRoomJSON {
	return HeadlessRoomJSON {
		id = room.id,
		name = room.name,
		description = room.description,
		lastReadMessageId = room.lastReadMessageId,
		unreadCount = room.unreadCount,
		roomType = int(room.roomType),
		access = int(room.access),
		historyVisibility = int(room.historyVisibility),
		encrypted = room.encrypted,
		logVersion = room.logVersion,
		myPermissions = headlessRoomPermissionNames(room.myPermissions, allocator),
	}
}

headlessRooms :: proc(
	rooms: []common.RoomSummary,
	allocator := context.temp_allocator,
) -> []HeadlessRoomJSON {
	rows := make([]HeadlessRoomJSON, len(rooms), allocator)
	for room, index in rooms {
		rows[index] = headlessRoom(room, allocator)
	}
	return rows
}

headlessAdminRooms :: proc(
	rooms: []common.AdminRoomSummary,
	allocator := context.temp_allocator,
) -> []HeadlessAdminRoomJSON {
	rows := make([]HeadlessAdminRoomJSON, len(rooms), allocator)
	for entry, index in rooms {
		rows[index] = HeadlessAdminRoomJSON {
			room        = headlessRoom(entry.room, allocator),
			isMember    = entry.isMember,
			memberCount = entry.memberCount,
		}
	}
	return rows
}

HeadlessRoomGrantJSON :: struct {
	roleID:      int,
	permissions: []string,
}

// room_permissions (ServerAdminRoomPermissions).
HeadlessRoomPermissionsJSON :: struct {
	event:         string,
	serverID:      int,
	roomID:        int,
	everyone:      []string,
	roles:         []HeadlessRoomGrantJSON,
	accessRoleIDs: []int,
	myPermissions: []string,
}

HeadlessRoomPermissionsRequestJSON :: struct {
	ok:       bool,
	cmd:      string,
	serverID: int,
	roomID:   int,
}

headlessRenderRoomPermissionsEvent :: proc(
	event: ^ClientTransportRuntimeEvent,
	allocator := context.allocator,
) -> (
	line: string,
	kind: HeadlessEventKind,
	ok: bool,
) {
	payload := &event.roomPermissions
	roles := make([]HeadlessRoomGrantJSON, len(payload.roles), context.temp_allocator)
	for grant, index in payload.roles {
		roles[index] = {
			roleID      = grant.roleId,
			permissions = headlessRoomPermissionNames(grant.permissions),
		}
	}
	kind = .RoomPermissions
	line = headlessMarshal(
		HeadlessRoomPermissionsJSON {
			event = HEADLESS_EVENT_NAMES[kind],
			serverID = event.serverID,
			roomID = event.roomID,
			everyone = headlessRoomPermissionNames(payload.everyone),
			roles = roles,
			accessRoleIDs = payload.accessRoleIds[:],
			myPermissions = headlessRoomPermissionNames(payload.myPermissions),
		},
		allocator,
	)
	return line, kind, true
}

@(private = "file")
headlessWriteRoomPermissionsRequest :: proc(
	harness: ^HeadlessHarness,
	command: ^HeadlessParsedCommand,
	errorMessage: string,
	roomID: int,
) {
	if len(errorMessage) > 0 {
		headlessWriteError(harness, command.name, errorMessage)
		return
	}
	headlessWriteJSON(
		harness,
		HeadlessRoomPermissionsRequestJSON {
			ok = true,
			cmd = command.name,
			serverID = harness.state.selected_server_id,
			roomID = roomID,
		},
	)
}

@(private = "file")
headlessRoomPermissionsUsage :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	usage := strings.concatenate({"usage: ", command.command.usage})
	defer delete(usage)
	headlessWriteError(harness, command.name, usage)
}

headlessCommandRoomPermissions :: proc(
	harness: ^HeadlessHarness,
	command: ^HeadlessParsedCommand,
) {
	roomID, roomOK := headlessParseNumber(command.args[0])
	if !roomOK || roomID <= 0 {
		headlessRoomPermissionsUsage(harness, command)
		return
	}
	state := &harness.state
	errorMessage := State_requestRoomPermissions(state, state.selected_server_id, roomID)
	headlessWriteRoomPermissionsRequest(harness, command, errorMessage, roomID)
}

headlessCommandRoomPermissionsSet :: proc(
	harness: ^HeadlessHarness,
	command: ^HeadlessParsedCommand,
) {
	roomID, roomOK := headlessParseNumber(command.args[0])
	everyone, everyoneOK := headlessParseRoomPermissions(command.args[1])
	if !roomOK || roomID <= 0 || !everyoneOK {
		headlessRoomPermissionsUsage(harness, command)
		return
	}
	grants := make([dynamic]common.RoomRoleGrant, 0, context.temp_allocator)
	if command.argCount > 2 {
		remaining := command.args[2]
		for word in strings.fields_iterator(&remaining) {
			separator := strings.index_byte(word, '=')
			if separator <= 0 {
				headlessRoomPermissionsUsage(harness, command)
				return
			}
			roleID, idOK := headlessParseNumber(word[:separator])
			permissions, permissionsOK := headlessParseRoomPermissions(word[separator + 1:])
			if !idOK || roleID <= 0 || !permissionsOK {
				headlessRoomPermissionsUsage(harness, command)
				return
			}
			append(&grants, common.RoomRoleGrant{roleId = roleID, permissions = permissions})
		}
	}
	state := &harness.state
	errorMessage := State_sendSetRoomPermissions(
		state,
		state.selected_server_id,
		roomID,
		everyone,
		grants[:],
	)
	headlessWriteRoomPermissionsRequest(harness, command, errorMessage, roomID)
}
