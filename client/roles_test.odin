#+feature dynamic-literals
package client

import "../common"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:testing"

// Roles on the client (protocol 23, roles.odin): permissions from sign-in and
// ServerAccountUpdated, the role cache and its fan-outs, the controls gated on permissions, the
// Roles list and form, the member role picker and the menu entries, all through adminSendBridge,
// and the harness commands and events.

ROLES_TEST_SELF :: 3
ROLES_TEST_BOB :: 9
ROLES_TEST_ROOMS_ROLE :: 5
ROLES_TEST_MEMBERS_ROLE :: 6
ROLES_TEST_ADMIN_ROLE :: 1

// Signed in on serverID as user 3 (an admin or not, with permissions), rooms 1 and 2, the roles
// admin, room keepers (ManageRooms) and member keepers (ManageRoomMembers), and a directory of
// self and bob, who holds room keepers.
@(private = "file")
rolesTestState :: proc(
	serverID: int,
	isAdmin: bool,
	permissions: common.ServerPermissions = {},
) -> State {
	state := testUpdateStateForServer(testRoomAdminServer(serverID))
	event := ClientTransportRuntimeEvent {
		kind        = .Connected,
		serverID    = serverID,
		userID      = ROLES_TEST_SELF,
		nickname    = strings.clone(state.config.display_name),
		isAdmin     = isAdmin,
		permissions = permissions,
	}
	State_applyRuntimeEvent(&state, &event)
	ClientTransportRuntimeEvent_deinit(&event)
	testApplyNamedRooms(&state, serverID, {id = 1, name = "general"}, {id = 2, name = "lounge"})
	rolesTestApplyRoles(&state, serverID)
	selfRoles := [dynamic]int{ROLES_TEST_ADMIN_ROLE}
	defer delete(selfRoles)
	bobRoles := [dynamic]int{ROLES_TEST_ROOMS_ROLE}
	defer delete(bobRoles)
	testApplyUserList(
		&state,
		serverID,
		{
			id = ROLES_TEST_SELF,
			nickname = "alice",
			isOnline = true,
			isAdmin = isAdmin,
			roleIds = isAdmin ? selfRoles : nil,
		},
		{id = ROLES_TEST_BOB, nickname = "bob", isOnline = true, roleIds = bobRoles},
	)
	return state
}

@(private = "file")
rolesTestApplyRoles :: proc(state: ^State, serverID: int) {
	event := ClientTransportRuntimeEvent {
		kind     = .RoleListReceived,
		serverID = serverID,
	}
	append(
		&event.roles,
		common.RoleSummary {
			id = ROLES_TEST_ADMIN_ROLE,
			name = strings.clone("admin"),
			permissions = common.SERVER_PERMISSIONS_ALL,
			builtin = true,
		},
		common.RoleSummary {
			id = ROLES_TEST_MEMBERS_ROLE,
			name = strings.clone("member keepers"),
			permissions = {.ManageRoomMembers},
			position = 2,
		},
		common.RoleSummary {
			id = ROLES_TEST_ROOMS_ROLE,
			name = strings.clone("room keepers"),
			permissions = {.ManageRooms},
			position = 1,
		},
	)
	State_applyRuntimeEvent(state, &event)
	ClientTransportRuntimeEvent_deinit(&event)
}

@(private = "file")
rolesTestAccountUpdated :: proc(
	state: ^State,
	serverID: int,
	isAdmin: bool,
	permissions: common.ServerPermissions,
) {
	event := ClientTransportRuntimeEvent {
		kind        = .AccountUpdated,
		serverID    = serverID,
		isAdmin     = isAdmin,
		nickname    = strings.clone("alice"),
		permissions = permissions,
	}
	State_applyRuntimeEvent(state, &event)
	ClientTransportRuntimeEvent_deinit(&event)
}

@(test)
testPermissionsComeFromSignInAndAccountUpdates :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	state := rolesTestState(1301, false, {.ManageRooms})
	defer State_deinit(&state)

	testing.expect(
		t,
		State_hasPermission(&state, 1301, .ManageRooms) &&
		!State_hasPermission(&state, 1301, .ManageRoomMembers),
		"expected ManageRooms from sign-in",
	)
	// ManageRooms offers New room and room editing, but not member management.
	testing.expect(t, State_hasAdminSection(&state, 1301), "expected the Admin section")
	sidebar := buildSidebarRows(&state)
	foundNewRoom := false
	for row in sidebar {
		foundNewRoom ||= row.action == .NewRoom
	}
	testing.expect(t, foundNewRoom, "expected New room on the Channels header")
	State_openRoomCreator(&state)
	testing.expect(t, state.roomEditor.mode == .Create, "expected the room form to open")
	State_closeRoomEditor(&state)
	testing.expect(
		t,
		!roomMemberRights(&state, 1301, 2).canRemove,
		"expected no member removal without ManageRoomMembers",
	)

	// An admin takes ManageRooms away while the form is open: it closes.
	State_openRoomCreator(&state)
	rolesTestAccountUpdated(&state, 1301, false, {.ManageRoomMembers})
	testing.expect(
		t,
		state.roomEditor.mode == .Closed &&
		State_hasPermission(&state, 1301, .ManageRoomMembers) &&
		!State_hasPermission(&state, 1301, .ManageRooms),
		"expected the form closed and ManageRoomMembers now",
	)
	testing.expect(
		t,
		roomMemberRights(&state, 1301, 2).canRemove,
		"expected member removal with ManageRoomMembers",
	)

	// An admin holds every permission whatever the set says; nobody holds any once offline.
	rolesTestAccountUpdated(&state, 1301, true, {})
	testing.expect(
		t,
		State_serverPermissions(&state, 1301) == common.SERVER_PERMISSIONS_ALL,
		"expected every permission for an admin",
	)
	rolesTestAccountUpdated(&state, 1301, false, {})
	testing.expect(t, !State_hasAdminSection(&state, 1301), "expected no Admin section")
}

@(test)
testRoleCacheFollowsTheServer :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	state := rolesTestState(1302, true)
	defer State_deinit(&state)

	roles := State_roles(&state, 1302)
	testing.expectf(
		t,
		len(roles) == 3 &&
		roles[0].builtin &&
		roles[1].id == ROLES_TEST_ROOMS_ROLE &&
		roles[2].id == ROLES_TEST_MEMBERS_ROLE,
		"expected the roles by position, got %v",
		roles,
	)
	names := State_userRoleNames(&state, 1302, ROLES_TEST_BOB)
	testing.expectf(t, len(names) == 1 && names[0] == "room keepers", "got %v", names)
	testing.expect(
		t,
		len(State_userRoleNames(&state, 1302, ROLES_TEST_SELF)) == 0,
		"expected the admin role left out of the names",
	)

	// An update replaces the role in place and keeps the order.
	updated := ClientTransportRuntimeEvent {
		kind     = .RoleUpdated,
		serverID = 1302,
		role     = {
			id = ROLES_TEST_ROOMS_ROLE,
			name = strings.clone("rooms"),
			permissions = {.ManageRooms, .CreateInvites},
			position = 3,
		},
	}
	State_applyRuntimeEvent(&state, &updated)
	ClientTransportRuntimeEvent_deinit(&updated)
	roles = State_roles(&state, 1302)
	testing.expectf(
		t,
		len(roles) == 3 && roles[2].name == "rooms" && .CreateInvites in roles[2].permissions,
		"expected the renamed role last, got %v",
		roles,
	)

	// A deletion leaves the list and every directory entry; an open form for it closes.
	testing.expect(t, State_openRoleEditor(&state, 1302, ROLES_TEST_ROOMS_ROLE), "expected it")
	deleted := ClientTransportRuntimeEvent {
		kind     = .RoleDeleted,
		serverID = 1302,
		roleID   = ROLES_TEST_ROOMS_ROLE,
	}
	State_applyRuntimeEvent(&state, &deleted)
	ClientTransportRuntimeEvent_deinit(&deleted)
	bob, _ := State_directoryUser(&state, 1302, ROLES_TEST_BOB)
	testing.expectf(
		t,
		len(State_roles(&state, 1302)) == 2 &&
		len(bob.roleIds) == 0 &&
		!state.serverSettings.roleEditor.open,
		"expected the role gone from the list, bob and the form, got %v",
		bob.roleIds,
	)
}

@(test)
testAdminSectionShowsWhatThePermissionsAllow :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	{
		state := rolesTestState(1303, false, {.ManageRoomMembers})
		defer State_deinit(&state)
		testing.expect(t, State_openServerSettings(&state, 1303), "expected the screen to open")
		view := buildServerSettingsView(&state).admin
		testing.expectf(
			t,
			view.visible &&
			!view.showMembers &&
			!view.showRoles &&
			view.showRooms &&
			view.canManageRoomMembers &&
			!view.canManageRooms &&
			len(view.members) == 0,
			"expected only the rooms for a member manager, got %v",
			view,
		)
	}

	state := rolesTestState(1303, true)
	defer State_deinit(&state)
	testing.expect(t, State_openServerSettings(&state, 1303), "expected the screen to open")
	view := buildServerSettingsView(&state).admin
	testing.expect(
		t,
		view.showMembers && view.showRoles && view.showRooms && view.canManageRooms,
		"expected everything for an admin",
	)
	testing.expectf(
		t,
		len(view.roles) == 3 &&
		view.roles[0].permissionsLabel == "Every permission" &&
		view.roles[1].name == "room keepers" &&
		view.roles[1].permissionsLabel == "Manage rooms" &&
		view.roles[1].holders == 1 &&
		view.roles[2].holders == 0,
		"expected the roles with their holders, got %v",
		view.roles,
	)
	bobRow: AdminMemberRow
	for member in view.members {
		if member.userID == ROLES_TEST_BOB {
			bobRow = member
		}
	}
	testing.expectf(
		t,
		len(bobRow.roleNames) == 1 && bobRow.roleNames[0] == "room keepers" &&
		bobRow.rolesControl.enabled,
		"expected bob's roles and Roles…, got %v",
		bobRow,
	)
}

@(test)
testRoleFormSendsThroughTheAdminBridge :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	sync.mutex_lock(&adminSendBridgeTestMutex)
	defer sync.mutex_unlock(&adminSendBridgeTestMutex)
	testAdminUseStub()
	defer testAdminRestore()

	state := rolesTestState(1304, true)
	defer State_deinit(&state)

	// A new role: a name and the delegable permissions only.
	testing.expect(t, State_openRoleEditor(&state, 1304, 0), "expected the new role form")
	editor := &state.serverSettings.roleEditor
	append(&editor.name, "  hosts ")
	State_toggleRoleEditorPermission(&state, .ManageRooms)
	State_toggleRoleEditorPermission(&state, .KickUsers)
	State_toggleRoleEditorPermission(&state, .CreateInvites)
	State_toggleRoleEditorPermission(&state, .CreateInvites)
	form := buildRoleEditorView(&state)
	testing.expectf(
		t,
		form.open && form.saveLabel == "Create" && !form.canDelete && len(form.permissions) == 4,
		"expected the four delegable permissions, got %v",
		form,
	)
	testing.expect(t, State_submitRoleEditor(&state), "expected the create to go out")
	testing.expectf(
		t,
		adminSendBridgeTestCount == 1 &&
		adminSendBridgeTestLast.action == .SaveRole &&
		adminSendBridgeTestLast.roleID == 0 &&
		adminSendBridgeTestLast.roleName == "hosts" &&
		adminSendBridgeTestLast.permissions == {.ManageRooms} &&
		!editor.open,
		"expected a create of hosts with ManageRooms, got %v",
		adminSendBridgeTestLast,
	)

	// A name the server would refuse stays in the form with the reason as the status.
	State_openRoleEditor(&state, 1304, 0)
	append(&editor.name, "ab")
	testing.expect(t, !State_submitRoleEditor(&state), "expected a short name refused")
	testing.expect(t, adminSendBridgeTestCount == 1 && editor.open, "expected nothing sent")
	State_closeRoleEditor(&state)

	// The built-in role: fixed name and permissions, no Save or Delete.
	testing.expect(t, State_openRoleEditor(&state, 1304, ROLES_TEST_ADMIN_ROLE), "expected it")
	State_toggleRoleEditorPermission(&state, .ManageRooms)
	builtin := buildRoleEditorView(&state)
	testing.expectf(
		t,
		builtin.builtin &&
		!builtin.canDelete &&
		editor.permissions == common.SERVER_PERMISSIONS_ALL &&
		!builtin.permissions[0].enabled &&
		builtin.permissions[0].checked,
		"expected the admin role fixed, got %v",
		builtin,
	)
	testing.expect(t, !State_deleteRoleEditorRole(&state), "expected no delete of admin")
	State_closeRoleEditor(&state)

	// Delete takes two clicks.
	State_openRoleEditor(&state, 1304, ROLES_TEST_MEMBERS_ROLE)
	testing.expect(t, !State_deleteRoleEditorRole(&state), "expected the first click to arm")
	testing.expect(t, State_deleteRoleEditorRole(&state), "expected the second to delete")
	testing.expectf(
		t,
		adminSendBridgeTestCount == 2 &&
		adminSendBridgeTestLast.action == .DeleteRole &&
		adminSendBridgeTestLast.roleID == ROLES_TEST_MEMBERS_ROLE,
		"expected the delete, got %v",
		adminSendBridgeTestLast,
	)

	// The member picker sends the whole new set, without the admin role.
	testing.expect(t, State_openMemberRoles(&state, 1304, ROLES_TEST_BOB), "expected the picker")
	testing.expect(
		t,
		State_toggleMemberRole(&state, 1304, ROLES_TEST_BOB, ROLES_TEST_MEMBERS_ROLE),
		"expected the grant to go out",
	)
	sent := adminSendBridgeTestLast
	testing.expectf(
		t,
		sent.action == .SetUserRoles &&
		sent.userID == ROLES_TEST_BOB &&
		sent.roleIDCount == 2 &&
		sent.roleIDs[0] == ROLES_TEST_ROOMS_ROLE &&
		sent.roleIDs[1] == ROLES_TEST_MEMBERS_ROLE,
		"expected bob's two roles, got %v",
		sent,
	)
	testing.expect(
		t,
		State_toggleMemberRole(&state, 1304, ROLES_TEST_BOB, ROLES_TEST_ROOMS_ROLE),
		"expected the revoke to go out",
	)
	testing.expectf(
		t,
		adminSendBridgeTestLast.roleIDCount == 0,
		"expected bob left with no roles, got %v",
		adminSendBridgeTestLast,
	)
	testing.expect(
		t,
		!State_toggleMemberRole(&state, 1304, ROLES_TEST_SELF, ROLES_TEST_ADMIN_ROLE),
		"expected the admin role never toggled here",
	)
	testing.expect(t, adminSendBridgeTestCount == 4, "expected nothing more sent")

	// None of it for a non-admin.
	rolesTestAccountUpdated(&state, 1304, false, {.ManageRooms})
	testing.expect(
		t,
		!State_openRoleEditor(&state, 1304, 0) &&
		!State_openMemberRoles(&state, 1304, ROLES_TEST_BOB) &&
		!State_toggleMemberRole(&state, 1304, ROLES_TEST_BOB, ROLES_TEST_MEMBERS_ROLE),
		"expected no role controls without the admin role",
	)
}

@(test)
testMemberMenusShowRoles :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	state := rolesTestState(1305, true)
	defer State_deinit(&state)
	State_openContextMenu(&state, MemberMenuTarget{1305, ROLES_TEST_BOB}, {10, 10})
	view := buildContextMenu(&state, {})
	labels := make([dynamic]string, context.temp_allocator)
	for entry in view.entries {
		append(&labels, entry.label)
	}
	joined := strings.join(labels[:], ",", context.temp_allocator)
	testing.expectf(
		t,
		strings.contains(joined, "Roles: room keepers,Rename…") &&
		strings.has_suffix(joined, "Roles…"),
		"expected bob's roles and Roles…, got %q",
		joined,
	)
	_ = State_runContextMenuAction(&state, .MemberRoles, {})
	testing.expect(
		t,
		State_serverSettingsVisible(&state) &&
		state.serverSettings.memberRolesUserID == ROLES_TEST_BOB,
		"expected Roles… to open the picker under bob",
	)

	// A member sees the roles, not the admin entries.
	rolesTestAccountUpdated(&state, 1305, false, {})
	State_openContextMenu(&state, MemberMenuTarget{1305, ROLES_TEST_BOB}, {10, 10})
	member := buildContextMenu(&state, {})
	last := member.entries[len(member.entries) - 1]
	testing.expectf(
		t,
		last.action == .RoleNames && last.label == "Roles: room keepers" && !last.enabled,
		"expected the roles line last and disabled, got %v",
		last,
	)
}

@(test)
testHeadlessRoleCommandsAndEvents :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	permissions, ok := headlessParsePermissions("manage-rooms,create-invites")
	testing.expect(
		t,
		ok && permissions == {.ManageRooms, .CreateInvites},
		"expected two permissions",
	)
	_, bad := headlessParsePermissions("manage-rooms,fly")
	testing.expect(t, !bad, "expected an unknown permission refused")
	none, noneOK := headlessParsePermissions("none")
	testing.expect(t, noneOK && none == {}, "expected none to be the empty set")
	ids, idsOK := headlessParseIDList("3,7")
	testing.expect(t, idsOK && len(ids) == 2 && ids[1] == 7, "expected two IDs")
	_, badIDs := headlessParseIDList("3,x")
	testing.expect(t, !badIDs, "expected a bad ID refused")

	event := ClientTransportRuntimeEvent {
		kind     = .RoleUpdated,
		serverID = 7,
		role     = {id = 4, name = strings.clone("hosts"), permissions = {.ManageRooms}},
	}
	defer ClientTransportRuntimeEvent_deinit(&event)
	line, kind, rendered := headlessRenderRuntimeEvent(&event)
	defer delete(line)
	testExpectString(
		t,
		line,
		`{"event":"role_updated","serverID":7,"role":{"id":4,"name":"hosts",` +
		`"permissions":["manage-rooms"],"builtin":false,"position":0}}`,
		"the role_updated JSON",
	)
	testing.expect(t, rendered && kind == .RoleUpdated, "expected a role_updated event")

	deleted := ClientTransportRuntimeEvent {
		kind     = .RoleDeleted,
		serverID = 7,
		roleID   = 4,
	}
	deletedLine, _, _ := headlessRenderRuntimeEvent(&deleted)
	defer delete(deletedLine)
	testExpectString(
		t,
		deletedLine,
		`{"event":"role_deleted","serverID":7,"roleID":4}`,
		"the role_deleted JSON",
	)

	account := ClientTransportRuntimeEvent {
		kind        = .AccountUpdated,
		serverID    = 7,
		nickname    = strings.clone("bob"),
		permissions = {.ManageRooms, .ManageRoomMembers},
	}
	defer ClientTransportRuntimeEvent_deinit(&account)
	accountLine, _, _ := headlessRenderRuntimeEvent(&account)
	defer delete(accountLine)
	testExpectString(
		t,
		accountLine,
		`{"event":"account_updated","serverID":7,"isAdmin":false,"nickname":"bob",` +
		`"nicknameLocked":false,"permissions":["manage-rooms","manage-room-members"],` +
		`"isRestricted":false}`,
		"the account_updated JSON with permissions",
	)
	_ = fmt.tprintf("")
}
