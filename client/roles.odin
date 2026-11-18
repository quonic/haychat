package client

import "../common"
import "core:slice"
import "core:strings"

// Roles and server permissions (protocol 23, #95). Every account lists the server's roles
// after it connects (ClientAdminListRoles), so role names can show next to accounts; admins
// also create, edit, delete and assign them from Server settings → Admin → Roles. The server
// checks the admin role and every guard (the built-in admin role cannot be renamed, deleted or
// reduced); the client only decides which controls to draw:
//
// - State_serverPermissions / State_hasPermission (connection_state.odin) read the account's
//   effective permissions from ServerAuthSuccess and ServerAccountUpdated.
// - ServerRoleCache keeps the role list per server; ServerRoleUpdated and ServerRoleDeleted keep
//   it current, and a deleted role also leaves every directory entry's roleIds.
// - The role form (RoleEditorForm in ServerSettingsForm) and the member role picker
//   (ServerSettingsForm.memberRolesUserID) send through the admin actions of admin.odin
//   (State_sendAdminSaveRole, State_sendAdminDeleteRole, State_sendAdminSetUserRoles), so their
//   answers show as the Admin section's status.

// The role list of one server.
ServerRoleCache :: struct {
	serverID: int,
	// By position, then ID, as the server orders them. Names are owned.
	roles:    [dynamic]common.RoleSummary,
	loaded:   bool,
	loading:  bool,
}

ServerRoleCache_deinit :: proc(cache: ^ServerRoleCache) {
	ServerRoleCache_clearRoles(cache)
	delete(cache.roles)
	cache^ = {}
}

@(private = "file")
ServerRoleCache_clearRoles :: proc(cache: ^ServerRoleCache) {
	for &role in cache.roles {
		common.RoleSummary_deinit(&role)
	}
	clear(&cache.roles)
}

@(private = "file")
roleLess :: proc(a, b: common.RoleSummary) -> bool {
	if a.position != b.position {
		return a.position < b.position
	}
	return a.id < b.id
}

State_serverRoleCacheIndex :: proc(state: ^State, serverID: int) -> int {
	for cache, index in state.serverRoles {
		if cache.serverID == serverID {
			return index
		}
	}
	return -1
}

// The server's role cache, created when missing. The pointer is valid until the next cache is
// added or removed.
State_serverRoleCache :: proc(state: ^State, serverID: int) -> ^ServerRoleCache {
	if index := State_serverRoleCacheIndex(state, serverID); index >= 0 {
		return &state.serverRoles[index]
	}
	append(&state.serverRoles, ServerRoleCache{serverID = serverID})
	return &state.serverRoles[len(state.serverRoles) - 1]
}

// The server's roles, borrowed from State; empty before the list arrived.
State_roles :: proc(state: ^State, serverID: int) -> []common.RoleSummary {
	if index := State_serverRoleCacheIndex(state, serverID); index >= 0 {
		return state.serverRoles[index].roles[:]
	}
	return nil
}

State_findRole :: proc(state: ^State, serverID, roleID: int) -> ^common.RoleSummary {
	index := State_serverRoleCacheIndex(state, serverID)
	if index < 0 {
		return nil
	}
	for &role in state.serverRoles[index].roles {
		if role.id == roleID {
			return &role
		}
	}
	return nil
}

State_deinitRoles :: proc(state: ^State) {
	for &cache in state.serverRoles {
		ServerRoleCache_deinit(&cache)
	}
	delete(state.serverRoles)
	state.serverRoles = nil
}

// Tests swap this to observe the role list request without a live session, under
// adminSendBridgeTestMutex.
RoleListSendBridge :: #type proc(transport: ^ClientServerTransport) -> bool
roleListSendBridge: RoleListSendBridge = ClientServerTransport_adminListRoles

// Asks for the server's roles (any account may). Returns "" when the transport took it.
State_requestRoles :: proc(state: ^State, serverID: int) -> string {
	transportIndex := State_selectedTransportIndexForServerID(state^, serverID)
	if transportIndex < 0 {
		return "No server transport selected"
	}
	if !State_isServerConnected(state, serverID) {
		return NOT_CONNECTED_MESSAGE
	}
	transport := &state.serverTransports[transportIndex]
	ClientNetworkWorker_lock(state.networkWorker)
	sent := roleListSendBridge(transport)
	sendError := sent ? "" : strings.clone(transport.lastError, context.temp_allocator)
	ClientNetworkWorker_unlock(state.networkWorker)
	if !sent {
		return len(sendError) > 0 ? sendError : "Failed to ask for the roles"
	}
	State_serverRoleCache(state, serverID).loading = true
	return ""
}

// A new session: the old list may be stale, so fetch it again.
State_rolesConnected :: proc(state: ^State, serverID: int) {
	State_serverRoleCache(state, serverID).loading = false
	State_requestRoles(state, serverID)
}

// ServerRoleList: takes ownership of roles and clears the caller's array.
State_receiveRoleList :: proc(state: ^State, serverID: int, roles: ^[dynamic]common.RoleSummary) {
	if State_selectedTransportIndexForServerID(state^, serverID) < 0 {
		return
	}
	cache := State_serverRoleCache(state, serverID)
	ServerRoleCache_clearRoles(cache)
	delete(cache.roles)
	cache.roles = roles^
	roles^ = nil
	slice.sort_by(cache.roles[:], roleLess)
	cache.loaded = true
	cache.loading = false
}

// ServerRoleUpdated: replaces or adds the role. Takes ownership of role's name.
State_roleUpdated :: proc(state: ^State, serverID: int, role: ^common.RoleSummary) {
	if State_selectedTransportIndexForServerID(state^, serverID) < 0 || role.id <= 0 {
		return
	}
	cache := State_serverRoleCache(state, serverID)
	replaced := false
	for &known in cache.roles {
		if known.id == role.id {
			common.RoleSummary_deinit(&known)
			known = role^
			replaced = true
			break
		}
	}
	if !replaced {
		append(&cache.roles, role^)
	}
	role^ = {}
	slice.sort_by(cache.roles[:], roleLess)
}

// ServerRoleDeleted: the role leaves the list and every account that held it. The server sends
// no ServerUserUpdated for its holders, so their directory entries are changed here.
State_roleDeleted :: proc(state: ^State, serverID, roleID: int) {
	if index := State_serverRoleCacheIndex(state, serverID); index >= 0 {
		cache := &state.serverRoles[index]
		for &role, roleIndex in cache.roles {
			if role.id == roleID {
				common.RoleSummary_deinit(&role)
				ordered_remove(&cache.roles, roleIndex)
				break
			}
		}
	}
	if index := State_serverDirectCacheIndex(state^, serverID); index >= 0 {
		for &user in state.serverDirectCaches[index].users {
			for id, idIndex in user.roleIds {
				if id == roleID {
					ordered_remove(&user.roleIds, idIndex)
					break
				}
			}
		}
	}
	form := &state.serverSettings
	if form.serverID == serverID && form.roleEditor.open && form.roleEditor.roleID == roleID {
		State_closeRoleEditor(state)
	}
}

// The account stopped being an admin: the role controls go with the role.
State_rolesAdminLost :: proc(state: ^State, serverID: int) {
	form := &state.serverSettings
	if form.serverID != serverID {
		return
	}
	State_closeRoleEditor(state)
	State_closeMemberRoles(state)
}

// The account was handed room permissions while Server settings shows that server: fetch
// every room for the Admin section.
State_noteRoomManagementGained :: proc(state: ^State, serverID: int) {
	if State_serverSettingsVisible(state) && state.serverSettings.serverID == serverID {
		cache := State_serverRoomCache(state, serverID)
		if !cache.adminRoomsLoaded {
			State_requestAdminRooms(state, serverID)
		}
	}
}

// The names of the roles userID holds other than admin (the Admin badge says that), in the
// list's order, in allocator. Unknown role IDs (the list has not arrived) are left out.
State_userRoleNames :: proc(
	state: ^State,
	serverID, userID: int,
	allocator := context.temp_allocator,
) -> []string {
	names := make([dynamic]string, 0, allocator)
	user, known := State_directoryUser(state, serverID, userID)
	if !known {
		return names[:]
	}
	for role in State_roles(state, serverID) {
		if role.builtin {
			continue
		}
		if slice.contains(user.roleIds[:], role.id) {
			append(&names, role.name)
		}
	}
	return names[:]
}

// The account's directory entry, borrowed.
State_directoryUser :: proc(
	state: ^State,
	serverID, userID: int,
) -> (
	user: common.UserSummary,
	known: bool,
) {
	index := State_serverDirectCacheIndex(state^, serverID)
	if index < 0 {
		return
	}
	cache := &state.serverDirectCaches[index]
	userIndex := ServerDirectCache_userIndex(cache^, userID)
	if userIndex < 0 {
		return
	}
	return cache.users[userIndex], true
}

// ── Permissions for people ────────────────────────────────────────

// What a permission is called in the role form, and what it lets a role do.
serverPermissionLabel :: proc(permission: common.ServerPermission) -> (label, note: string) {
	switch permission {
	case .ManageRooms:
		return "Manage rooms", "Create, edit and delete rooms."
	case .ManageRoomMembers:
		return "Manage room members", "Add and remove members of invite rooms, and see every room."
	case .CreateInvites:
		return "Create invites", "Create invite codes, once sign-up by invitation arrives."
	case .ApproveRegistrations:
		return "Approve sign-ups", "Accept or decline sign-up requests, once they arrive."
	case .ManageRoles:
		return "Manage roles", "Admins only."
	case .ManageRegistration:
		return "Manage sign-up", "Admins only."
	case .KickUsers:
		return "Kick", "Admins only."
	case .BanUsers:
		return "Ban", "Admins only."
	case .RenameUsers:
		return "Rename", "Admins only."
	}
	return "Unknown", ""
}

// "Manage rooms, Manage room members", "Every permission" for the built-in role, or "No
// permissions", in allocator.
serverPermissionsSummary :: proc(
	permissions: common.ServerPermissions,
	builtin: bool,
	allocator := context.temp_allocator,
) -> string {
	if builtin {
		return "Every permission"
	}
	builder := strings.builder_make(allocator)
	for permission in common.ServerPermission {
		if permission not_in permissions {
			continue
		}
		if strings.builder_len(builder) > 0 {
			strings.write_string(&builder, ", ")
		}
		label, _ := serverPermissionLabel(permission)
		strings.write_string(&builder, label)
	}
	if strings.builder_len(builder) == 0 {
		return "No permissions"
	}
	return strings.to_string(builder)
}

// ── The role form ─────────────────────────────────────────────────

// The open role form in Server settings → Admin → Roles: a new role (roleID 0) or an edit.
RoleEditorForm :: struct {
	open:          bool,
	roleID:        int,
	name:          [dynamic]u8,
	permissions:   common.ServerPermissions,
	position:      int,
	builtin:       bool,
	// Delete takes two clicks.
	confirmDelete: bool,
}

RoleEditorForm_deinit :: proc(form: ^RoleEditorForm) {
	delete(form.name)
	form^ = {}
}

// Opens the role form for roleID (0 for a new role) on serverID, opening Server settings there
// first unless it is shown already. Admins only.
State_openRoleEditor :: proc(state: ^State, serverID, roleID: int) -> bool {
	if !State_isServerAdmin(state, serverID) {
		return false
	}
	role: common.RoleSummary
	if roleID > 0 {
		found := State_findRole(state, serverID, roleID)
		if found == nil {
			return false
		}
		role = found^
	}
	if !State_serverSettingsVisible(state) || state.serverSettings.serverID != serverID {
		if !State_openServerSettings(state, serverID) {
			return false
		}
	}
	editor := &state.serverSettings.roleEditor
	editor.open = true
	editor.roleID = roleID
	clear(&editor.name)
	append(&editor.name, role.name)
	editor.permissions = role.permissions
	editor.position = role.position
	editor.builtin = role.builtin
	editor.confirmDelete = false
	return true
}

State_closeRoleEditor :: proc(state: ^State) {
	editor := &state.serverSettings.roleEditor
	editor.open = false
	editor.roleID = 0
	clear(&editor.name)
	editor.permissions = {}
	editor.position = 0
	editor.builtin = false
	editor.confirmDelete = false
}

// Ticks or clears one permission in the open form. The built-in role's are fixed, and only the
// delegable ones can be given to another role.
State_toggleRoleEditorPermission :: proc(state: ^State, permission: common.ServerPermission) {
	editor := &state.serverSettings.roleEditor
	if !editor.open || editor.builtin || permission not_in common.SERVER_PERMISSIONS_ASSIGNABLE {
		return
	}
	editor.confirmDelete = false
	if permission in editor.permissions {
		editor.permissions -= {permission}
	} else {
		editor.permissions += {permission}
	}
}

// Create or Save. The form closes once the transport took the request; the answer shows as the
// Admin section's status. Returns false, with the reason as the status, when nothing was sent.
State_submitRoleEditor :: proc(state: ^State) -> bool {
	form := &state.serverSettings
	editor := &form.roleEditor
	if !form.open || !editor.open {
		return false
	}
	serverID := form.serverID
	name := strings.trim_space(string(editor.name[:]))
	permissions := editor.builtin ? common.SERVER_PERMISSIONS_ALL : editor.permissions
	errorMessage := State_sendAdminSaveRole(
		state,
		serverID,
		editor.roleID,
		name,
		permissions,
		editor.position,
	)
	if len(errorMessage) > 0 {
		State_adminRequestFailed(state, serverID, .SaveRole, 0, errorMessage)
		return false
	}
	State_closeRoleEditor(state)
	return true
}

// Delete…, then "Click again to delete". The built-in role has no Delete.
State_deleteRoleEditorRole :: proc(state: ^State) -> bool {
	form := &state.serverSettings
	editor := &form.roleEditor
	if !form.open || !editor.open || editor.roleID <= 0 || editor.builtin {
		return false
	}
	if !editor.confirmDelete {
		editor.confirmDelete = true
		return false
	}
	serverID, roleID := form.serverID, editor.roleID
	if errorMessage := State_sendAdminDeleteRole(state, serverID, roleID); len(errorMessage) > 0 {
		State_adminRequestFailed(state, serverID, .DeleteRole, 0, errorMessage)
		return false
	}
	State_closeRoleEditor(state)
	return true
}

// ── The member role picker ────────────────────────────────────────

// Opens the role picker under userID in Server settings → Admin (from the member's Roles…
// button or its context menu), opening the screen on serverID first unless it is shown.
State_openMemberRoles :: proc(state: ^State, serverID, userID: int) -> bool {
	if !State_isServerAdmin(state, serverID) {
		return false
	}
	if _, known := State_directoryUser(state, serverID, userID); !known {
		return false
	}
	if !State_serverSettingsVisible(state) || state.serverSettings.serverID != serverID {
		if !State_openServerSettings(state, serverID) {
			return false
		}
	}
	state.serverSettings.memberRolesUserID = userID
	state.serverSettings.adminConfirm.scrollTo = true
	return true
}

State_closeMemberRoles :: proc(state: ^State) {
	state.serverSettings.memberRolesUserID = 0
}

// Gives userID roleID or takes it away, sending the account's whole new set of roles other than
// admin. Returns false, with the reason as the status, when nothing was sent.
State_toggleMemberRole :: proc(state: ^State, serverID, userID, roleID: int) -> bool {
	if !State_isServerAdmin(state, serverID) {
		return false
	}
	user, known := State_directoryUser(state, serverID, userID)
	role := State_findRole(state, serverID, roleID)
	if !known || role == nil || role.builtin {
		return false
	}
	roleIDs := make([dynamic]int, 0, len(user.roleIds) + 1, context.temp_allocator)
	held := false
	for id in user.roleIds {
		if id == roleID {
			held = true
			continue
		}
		if other := State_findRole(state, serverID, id); other != nil && other.builtin {
			continue
		}
		append(&roleIDs, id)
	}
	if !held {
		append(&roleIDs, roleID)
	}
	if errorMessage := State_sendAdminSetUserRoles(state, serverID, userID, roleIDs[:]);
	   len(errorMessage) > 0 {
		State_adminRequestFailed(state, serverID, .SetUserRoles, userID, errorMessage)
		return false
	}
	return true
}

// ── View model ────────────────────────────────────────────────────

AdminRoleRow :: struct {
	roleID:           int,
	name:             string, // Borrowed from State
	permissionsLabel: string, // In the view allocator
	builtin:          bool,
	holders:          int,
}

RolePermissionRow :: struct {
	permission: common.ServerPermission,
	label:      string,
	note:       string,
	checked:    bool,
	enabled:    bool,
}

RoleEditorView :: struct {
	open:          bool,
	roleID:        int,
	title:         string,
	builtin:       bool,
	note:          string,
	permissions:   []RolePermissionRow,
	saveLabel:     string,
	canDelete:     bool,
	deleteLabel:   string,
	confirmDelete: bool,
}

AdminMemberRoleRow :: struct {
	roleID: int,
	name:   string, // Borrowed from State
	held:   bool,
}

// Every role with what it allows and how many accounts hold it, for admins.
buildAdminRoleRows :: proc(
	state: ^State,
	serverID: int,
	allocator := context.temp_allocator,
) -> []AdminRoleRow {
	rows := make([dynamic]AdminRoleRow, 0, allocator)
	users: []common.UserSummary
	if index := State_serverDirectCacheIndex(state^, serverID); index >= 0 {
		users = state.serverDirectCaches[index].users[:]
	}
	for role in State_roles(state, serverID) {
		holders := 0
		for user in users {
			if slice.contains(user.roleIds[:], role.id) {
				holders += 1
			}
		}
		append(
			&rows,
			AdminRoleRow {
				roleID = role.id,
				name = role.name,
				permissionsLabel = serverPermissionsSummary(role.permissions, role.builtin, allocator),
				builtin = role.builtin,
				holders = holders,
			},
		)
	}
	return rows[:]
}

buildRoleEditorView :: proc(
	state: ^State,
	allocator := context.temp_allocator,
) -> (
	view: RoleEditorView,
) {
	editor := &state.serverSettings.roleEditor
	if !editor.open {
		return
	}
	view.open = true
	view.roleID = editor.roleID
	view.builtin = editor.builtin
	switch {
	case editor.builtin:
		view.title = "The admin role"
		view.note =
			"Built in: it holds every permission and cannot be renamed or deleted. Admins " +
			"are given it with Make admin."
	case editor.roleID == 0:
		view.title = "New role"
		view.note = "Give the role to accounts from their Roles… button below."
	case:
		view.title = "Edit role"
		view.note = "Accounts holding the role get the change at once."
	}
	rows := make([dynamic]RolePermissionRow, 0, len(common.ServerPermission), allocator)
	for permission in common.SERVER_PERMISSIONS_ASSIGNABLE {
		label, note := serverPermissionLabel(permission)
		append(
			&rows,
			RolePermissionRow {
				permission = permission,
				label = label,
				note = note,
				checked = editor.builtin || permission in editor.permissions,
				enabled = !editor.builtin,
			},
		)
	}
	view.permissions = rows[:]
	view.saveLabel = editor.roleID == 0 ? "Create" : "Save"
	view.canDelete = editor.roleID > 0 && !editor.builtin
	view.confirmDelete = editor.confirmDelete
	view.deleteLabel = editor.confirmDelete ? "Click again to delete" : "Delete…"
	return
}

// The roles userID may be given, ticked where it holds them.
buildAdminMemberRoleRows :: proc(
	state: ^State,
	serverID, userID: int,
	allocator := context.temp_allocator,
) -> []AdminMemberRoleRow {
	rows := make([dynamic]AdminMemberRoleRow, 0, allocator)
	user, known := State_directoryUser(state, serverID, userID)
	if !known {
		return rows[:]
	}
	for role in State_roles(state, serverID) {
		if role.builtin {
			continue
		}
		append(
			&rows,
			AdminMemberRoleRow {
				roleID = role.id,
				name = role.name,
				held = slice.contains(user.roleIds[:], role.id),
			},
		)
	}
	return rows[:]
}
