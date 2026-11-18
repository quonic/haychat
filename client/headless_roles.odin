package client

import "../common"
import "core:strings"

// Roles in the headless harness (protocol 23, roles.odin): the roles-* commands and the
// role_list, role_updated and role_deleted events. Permissions are lists of the words in
// HEADLESS_PERMISSION_NAMES. Like the other admin commands, the harness checks nothing the
// server checks, so an agent can see the server refuse (protocol_error).
//
// - roles-list: the role list from the cache ({ok, cmd, serverID, loaded, roles}); asks for it
//   when it has not arrived, and the answer is role_list.
// - roles-save ROLE_ID PERMISSIONS NAME...: creates (ROLE_ID 0) or edits a role. PERMISSIONS is
//   a comma list or `none`; an edit keeps the role's position. Answered by admin_result
//   (action role-save, roleID) and role_updated on every session.
// - roles-delete ROLE_ID: answered by admin_result (role-delete) and role_deleted.
// - roles-assign USER_ID ROLE_IDS: makes a comma list (or `none`) every role of the account
//   other than admin. Answered by admin_result (role-assign) and user_updated, and
//   account_updated on the account's sessions when its permissions changed.

HEADLESS_PERMISSION_NAMES := [common.ServerPermission]string {
	.ManageRooms          = "manage-rooms",
	.ManageRoomMembers    = "manage-room-members",
	.CreateInvites        = "create-invites",
	.ApproveRegistrations = "approve-registrations",
	.ManageRoles          = "manage-roles",
	.ManageRegistration   = "manage-registration",
	.KickUsers            = "kick-users",
	.BanUsers             = "ban-users",
	.RenameUsers          = "rename-users",
}

// The permission words of a set, in enum order, in allocator.
headlessPermissionNames :: proc(
	permissions: common.ServerPermissions,
	allocator := context.temp_allocator,
) -> []string {
	names := make([dynamic]string, 0, allocator)
	for permission in common.ServerPermission {
		if permission in permissions {
			append(&names, HEADLESS_PERMISSION_NAMES[permission])
		}
	}
	return names[:]
}

// Parses "manage-rooms,manage-room-members" or "none".
headlessParsePermissions :: proc(text: string) -> (permissions: common.ServerPermissions, ok: bool) {
	if text == "none" {
		return {}, true
	}
	remaining := text
	for word in strings.split_iterator(&remaining, ",") {
		found := false
		for name, permission in HEADLESS_PERMISSION_NAMES {
			if name == word {
				permissions += {permission}
				found = true
				break
			}
		}
		if !found {
			return {}, false
		}
	}
	return permissions, true
}

// Parses "3,7" or "none" into allocator.
headlessParseIDList :: proc(text: string, allocator := context.temp_allocator) -> ([]int, bool) {
	ids := make([dynamic]int, 0, allocator)
	if text == "none" {
		return ids[:], true
	}
	remaining := text
	for word in strings.split_iterator(&remaining, ",") {
		id, ok := headlessParseNumber(word)
		if !ok || id <= 0 {
			return nil, false
		}
		append(&ids, id)
	}
	return ids[:], true
}

HeadlessRoleJSON :: struct {
	id:          int,
	name:        string,
	permissions: []string,
	builtin:     bool,
	position:    int,
}

headlessRole :: proc(
	role: common.RoleSummary,
	allocator := context.temp_allocator,
) -> HeadlessRoleJSON {
	return HeadlessRoleJSON {
		id = role.id,
		name = role.name,
		permissions = headlessPermissionNames(role.permissions, allocator),
		builtin = role.builtin,
		position = role.position,
	}
}

headlessRoles :: proc(
	roles: []common.RoleSummary,
	allocator := context.temp_allocator,
) -> []HeadlessRoleJSON {
	rows := make([]HeadlessRoleJSON, len(roles), allocator)
	for role, index in roles {
		rows[index] = headlessRole(role, allocator)
	}
	return rows
}

// role_list (ServerRoleList), and the answer to roles-list.
HeadlessRoleListJSON :: struct {
	event:    string,
	serverID: int,
	roles:    []HeadlessRoleJSON,
}

HeadlessRoleListResultJSON :: struct {
	ok:       bool,
	cmd:      string,
	serverID: int,
	loaded:   bool,
	roles:    []HeadlessRoleJSON,
}

// role_updated (ServerRoleUpdated) and role_deleted (ServerRoleDeleted).
HeadlessRoleUpdatedJSON :: struct {
	event:    string,
	serverID: int,
	role:     HeadlessRoleJSON,
}

HeadlessRoleDeletedJSON :: struct {
	event:    string,
	serverID: int,
	roleID:   int,
}

HeadlessRoleRequestJSON :: struct {
	ok:       bool,
	cmd:      string,
	serverID: int,
	roleID:   int,
	userID:   int,
}

// The role events' lines; ok false for other kinds.
headlessRenderRoleEvent :: proc(
	event: ^ClientTransportRuntimeEvent,
	allocator := context.allocator,
) -> (
	line: string,
	kind: HeadlessEventKind,
	ok: bool,
) {
	#partial switch event.kind {
	case .RoleListReceived:
		kind = .RoleList
		line = headlessMarshal(
			HeadlessRoleListJSON {
				event = HEADLESS_EVENT_NAMES[kind],
				serverID = event.serverID,
				roles = headlessRoles(event.roles[:]),
			},
			allocator,
		)
		return line, kind, true
	case .RoleUpdated:
		kind = .RoleUpdated
		line = headlessMarshal(
			HeadlessRoleUpdatedJSON {
				event = HEADLESS_EVENT_NAMES[kind],
				serverID = event.serverID,
				role = headlessRole(event.role),
			},
			allocator,
		)
		return line, kind, true
	case .RoleDeleted:
		kind = .RoleDeleted
		line = headlessMarshal(
			HeadlessRoleDeletedJSON {
				event = HEADLESS_EVENT_NAMES[kind],
				serverID = event.serverID,
				roleID = event.roleID,
			},
			allocator,
		)
		return line, kind, true
	}
	return "", {}, false
}

@(private = "file")
headlessWriteRoleRequest :: proc(
	harness: ^HeadlessHarness,
	command: ^HeadlessParsedCommand,
	errorMessage: string,
	roleID, userID: int,
) {
	if len(errorMessage) > 0 {
		headlessWriteError(harness, command.name, errorMessage)
		return
	}
	headlessWriteJSON(
		harness,
		HeadlessRoleRequestJSON {
			ok = true,
			cmd = command.name,
			serverID = harness.state.selected_server_id,
			roleID = roleID,
			userID = userID,
		},
	)
}

@(private = "file")
headlessRoleUsage :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	usage := strings.concatenate({"usage: ", command.command.usage})
	defer delete(usage)
	headlessWriteError(harness, command.name, usage)
}

headlessCommandRolesList :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	state := &harness.state
	serverID := state.selected_server_id
	cache := State_serverRoleCache(state, serverID)
	if !cache.loaded && !cache.loading {
		if errorMessage := State_requestRoles(state, serverID); len(errorMessage) > 0 {
			headlessWriteError(harness, command.name, errorMessage)
			return
		}
		cache = State_serverRoleCache(state, serverID)
	}
	headlessWriteJSON(
		harness,
		HeadlessRoleListResultJSON {
			ok = true,
			cmd = command.name,
			serverID = serverID,
			loaded = cache.loaded,
			roles = headlessRoles(cache.roles[:]),
		},
	)
}

headlessCommandRolesSave :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	roleID, roleOK := headlessParseNumber(command.args[0])
	permissions, permissionsOK := headlessParsePermissions(command.args[1])
	if !roleOK || !permissionsOK {
		headlessRoleUsage(harness, command)
		return
	}
	state := &harness.state
	serverID := state.selected_server_id
	position := 0
	if role := State_findRole(state, serverID, roleID); role != nil {
		position = role.position
	}
	errorMessage := State_sendAdminSaveRole(
		state,
		serverID,
		roleID,
		command.args[2],
		permissions,
		position,
	)
	headlessWriteRoleRequest(harness, command, errorMessage, roleID, 0)
}

headlessCommandRolesDelete :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	roleID, roleOK := headlessParseNumber(command.args[0])
	if !roleOK || roleID <= 0 {
		headlessRoleUsage(harness, command)
		return
	}
	state := &harness.state
	errorMessage := State_sendAdminDeleteRole(state, state.selected_server_id, roleID)
	headlessWriteRoleRequest(harness, command, errorMessage, roleID, 0)
}

headlessCommandRolesAssign :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	userID, userOK := headlessParseNumber(command.args[0])
	roleIDs, rolesOK := headlessParseIDList(command.args[1])
	if !userOK || userID <= 0 || !rolesOK {
		headlessRoleUsage(harness, command)
		return
	}
	state := &harness.state
	errorMessage := State_sendAdminSetUserRoles(state, state.selected_server_id, userID, roleIDs)
	headlessWriteRoleRequest(harness, command, errorMessage, 0, userID)
}
