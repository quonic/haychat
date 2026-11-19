package server

import "../common"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "shared:pg"

// Runs the protocol 23 role statements (database_roles.odin) against a real PostgreSQL when
// HAYCHAT_DATABASE_SQL_TEST=1 (dev/live-proof.sh --all and --sql), each in a migrated schema of
// its own that is rolled back: every guard of Save, Delete and SetUserRoles, effective
// permissions as the union of roles, the built-in admin role, the permission checks of the room
// statements, and the role IDs and permissions the other statements now report.

// Gives userID a role named name holding permissions, creating the role when it is missing.
databaseRoleTestGrant :: proc(
	conn: pg.Conn,
	userID: int,
	name: string,
	permissions: common.ServerPermissions,
) {
	databaseDefaultRoomTestExec(
		conn,
		"grant a role",
		fmt.tprintf(
			"INSERT INTO server_roles (name, permissions) VALUES ('%s', %d) " +
			"ON CONFLICT (name) DO UPDATE SET permissions = EXCLUDED.permissions; " +
			"INSERT INTO user_server_roles (user_id, role_id) " +
			"SELECT %d, id FROM server_roles WHERE name = '%s' ON CONFLICT DO NOTHING",
			name,
			common.serverPermissionsMask(permissions),
			userID,
			name,
		),
	)
}

// The account's effective permissions through the shared subquery.
databaseRoleTestPermissions :: proc(conn: pg.Conn, userID: int) -> common.ServerPermissions {
	value := databaseAdminTestValue(
		conn,
		fmt.tprintf(
			"SELECT %s%d%s::text",
			DATABASE_SERVER_PERMISSIONS_OPEN_SQL,
			userID,
			DATABASE_SERVER_PERMISSIONS_CLOSE_SQL,
		),
	)
	mask, ok := databaseParseTestInt(value)
	assert(ok, fmt.tprintf("expected a permission mask, got %q", value))
	return common.serverPermissionsFromMask(i64(mask))
}

// Runs one role statement. Owned results move to the temp allocator.
databaseRoleTestRun :: proc(
	conn: pg.Conn,
	request: common.DatabaseRoleRequest,
) -> common.DatabaseRoleResult {
	response := databaseExecuteRequest(conn, request)
	result, resultOK := response.result.(common.DatabaseRoleResult)
	assert(
		response.success && resultOK,
		fmt.tprintf("expected the role statement %v to run: %s", request.action, response.message),
	)
	delete(response.message)
	moved := result
	moved.roles = make([dynamic]common.RoleSummary, 0, len(result.roles), context.temp_allocator)
	for &role in result.roles {
		append(&moved.roles, common.RoleSummary_clone(role, context.temp_allocator))
		common.RoleSummary_deinit(&role)
	}
	delete(result.roles)
	moved.role = common.RoleSummary_clone(result.role, context.temp_allocator)
	delete(result.role.name)
	moved.user = common.UserSummary_clone(result.user, context.temp_allocator)
	common.UserSummary_deinit(&result.user)
	moved.affected = make(
		[dynamic]common.DatabaseAccountPermissions,
		0,
		len(result.affected),
		context.temp_allocator,
	)
	for account in result.affected {
		copy := account
		copy.nickname = strings.clone(account.nickname, context.temp_allocator)
		append(&moved.affected, copy)
		delete(account.nickname)
	}
	delete(result.affected)
	// Protocol 24: the Role room changes and the accounts whose room permissions may move.
	moved.membershipChanges = make(
		[dynamic]common.DatabaseRoomMembershipChange,
		0,
		len(result.membershipChanges),
		context.temp_allocator,
	)
	for &change in result.membershipChanges {
		copy := change
		copy.memberUserIDs = make(
			[dynamic]int,
			0,
			len(change.memberUserIDs),
			context.temp_allocator,
		)
		append(&copy.memberUserIDs, ..change.memberUserIDs[:])
		append(&moved.membershipChanges, copy)
		common.DatabaseRoomMembershipChange_deinit(&change)
	}
	delete(result.membershipChanges)
	moved.roomPermissionUserIDs = make([dynamic]int, context.temp_allocator)
	append(&moved.roomPermissionUserIDs, ..result.roomPermissionUserIDs[:])
	delete(result.roomPermissionUserIDs)
	return moved
}

databaseRoleTestExpect :: proc(
	conn: pg.Conn,
	request: common.DatabaseRoleRequest,
	outcome: common.DatabaseAdminOutcome,
	label: string,
) -> common.DatabaseRoleResult {
	result := databaseRoleTestRun(conn, request)
	assert(
		result.outcome == outcome,
		fmt.tprintf("expected %s to end %v, got %v", label, outcome, result.outcome),
	)
	return result
}

databaseRoleTestSave :: proc(
	conn: pg.Conn,
	actor, roleID: int,
	name: string,
	permissions: common.ServerPermissions,
	outcome: common.DatabaseAdminOutcome,
	label: string,
	position := 0,
) -> common.DatabaseRoleResult {
	return databaseRoleTestExpect(
		conn,
		common.DatabaseRoleRequest {
			action = .Save,
			actorUserId = actor,
			roleId = roleID,
			name = name,
			permissions = permissions,
			position = position,
		},
		outcome,
		label,
	)
}

databaseRoleTestSetUserRoles :: proc(
	conn: pg.Conn,
	actor, target: int,
	roleIDs: []int,
	outcome: common.DatabaseAdminOutcome,
	label: string,
) -> common.DatabaseRoleResult {
	ids := make([dynamic]int, 0, len(roleIDs), context.temp_allocator)
	append(&ids, ..roleIDs)
	return databaseRoleTestExpect(
		conn,
		common.DatabaseRoleRequest {
			action = .SetUserRoles,
			actorUserId = actor,
			targetUserId = target,
			roleIds = ids,
		},
		outcome,
		label,
	)
}

databaseRoleTestAdminRoleID :: proc(conn: pg.Conn) -> int {
	value := databaseAdminTestValue(conn, "SELECT id::text FROM server_roles WHERE builtin")
	id, ok := databaseParseTestInt(value)
	assert(ok, fmt.tprintf("expected the built-in role, got %q", value))
	return id
}

// The bit constants the SQL uses must be the enum's masks.
@(test)
testServerPermissionBitsMatchTheEnum :: proc(t: ^testing.T) {
	_ = t
	Bit :: struct {
		literal:    string,
		permission: common.ServerPermission,
	}
	for bit in ([]Bit {
			{DATABASE_PERMISSION_MANAGE_ROOMS_SQL, .ManageRooms},
			{DATABASE_PERMISSION_MANAGE_ROOM_MEMBERS_SQL, .ManageRoomMembers},
			{DATABASE_PERMISSION_CREATE_INVITES_SQL, .CreateInvites},
			{DATABASE_PERMISSION_APPROVE_REGISTRATIONS_SQL, .ApproveRegistrations},
		}) {
		expected := fmt.tprintf("%d", common.serverPermissionsMask({bit.permission}))
		assert(
			bit.literal == expected,
			fmt.tprintf(
				"expected %v to be %s in SQL, got %s",
				bit.permission,
				expected,
				bit.literal,
			),
		)
	}
	assert(
		strings.contains(DATABASE_ACTOR_MANAGES_ROOMS_SQL, "perm_holder.user_id = $1::bigint"),
		"expected the room management check to read the requester",
	)
}

@(test)
testRoleStatementsAgainstPostgreSQL :: proc(t: ^testing.T) {
	_ = t
	if os.get_env(DATABASE_SQL_TEST_ENV, context.temp_allocator) != "1" {
		return
	}
	conn := databaseAdminTestOpen(t, "roles")

	admin := databaseAdminTestUser(conn, "role-admin")
	databaseAdminTestGrant(conn, admin)
	bob := databaseAdminTestUser(conn, "role-bob")
	carol := databaseAdminTestUser(conn, "role-carol")
	adminRole := databaseRoleTestAdminRoleID(conn)

	// The list always holds the built-in role, reading as every permission.
	{
		list := databaseRoleTestRun(conn, common.DatabaseRoleRequest{action = .List})
		assert(
			len(list.roles) == 1 &&
			list.roles[0].id == adminRole &&
			list.roles[0].builtin &&
			list.roles[0].name == common.ADMIN_ROLE_NAME &&
			list.roles[0].permissions == common.SERVER_PERMISSIONS_ALL,
			fmt.tprintf("expected only the admin role, got %v", list.roles),
		)
	}

	// Only admins save roles.
	databaseRoleTestSave(conn, bob, 0, "rooms", {.ManageRooms}, .NotAdmin, "a non-admin create")
	assert(
		databaseAdminTestValue(conn, "SELECT count(*)::text FROM server_roles") == "1",
		"expected a refused create to store nothing",
	)
	rooms := databaseRoleTestSave(conn, admin, 0, "rooms", {.ManageRooms}, .Applied, "a create")
	assert(
		rooms.changed &&
		rooms.role.id > 0 &&
		rooms.role.name == "rooms" &&
		!rooms.role.builtin &&
		rooms.role.permissions == {.ManageRooms} &&
		rooms.role.position == 1 &&
		len(rooms.affected) == 0,
		fmt.tprintf("expected the rooms role last with ManageRooms, got %v", rooms),
	)
	members := databaseRoleTestSave(
		conn,
		admin,
		0,
		"members",
		{.ManageRoomMembers},
		.Applied,
		"a second create",
	)
	assert(members.role.position == 2, fmt.tprintf("expected position 2, got %v", members.role))
	databaseRoleTestSave(conn, admin, 0, "rooms", {}, .RoleNameTaken, "a taken name")
	databaseRoleTestSave(conn, admin, 0, "admin", {}, .RoleNameTaken, "the admin role's name")
	databaseRoleTestSave(conn, admin, 9999, "ghost", {}, .UnknownRole, "an unknown role")
	databaseRoleTestSave(
		conn,
		admin,
		rooms.role.id,
		"rooms",
		{.ManageRooms, .KickUsers},
		.AdminOnlyPermission,
		"an admin-only permission",
	)

	// The built-in admin role cannot be renamed or reduced; its position can move.
	databaseRoleTestSave(
		conn,
		admin,
		adminRole,
		"boss",
		common.SERVER_PERMISSIONS_ALL,
		.BuiltinRole,
		"renaming admin",
	)
	databaseRoleTestSave(
		conn,
		admin,
		adminRole,
		"admin",
		{.ManageRooms},
		.BuiltinRole,
		"reducing admin",
	)
	moved := databaseRoleTestSave(
		conn,
		admin,
		adminRole,
		"admin",
		common.SERVER_PERMISSIONS_ALL,
		.Applied,
		"moving admin",
		position = 5,
	)
	assert(
		moved.changed && moved.role.builtin && moved.role.position == 5,
		fmt.tprintf("expected admin moved to 5, got %v", moved.role),
	)
	databaseRoleTestExpect(
		conn,
		common.DatabaseRoleRequest{action = .Delete, actorUserId = admin, roleId = adminRole},
		.BuiltinRole,
		"deleting admin",
	)
	stillAdmin := databaseAdminTestValue(
		conn,
		"SELECT name || ':' || permissions || ':' || builtin FROM server_roles WHERE builtin",
	)
	assert(stillAdmin == "admin:511:true", fmt.tprintf("expected admin intact, got %q", stillAdmin))

	// Assigning: admins only, existing non-built-in roles only, and the set replaces the old one.
	databaseRoleTestSetUserRoles(conn, bob, carol, {rooms.role.id}, .NotAdmin, "a non-admin")
	databaseRoleTestSetUserRoles(conn, admin, 9999, {rooms.role.id}, .UnknownUser, "no account")
	databaseRoleTestSetUserRoles(conn, admin, bob, {9999}, .UnknownRole, "an unknown role")
	databaseRoleTestSetUserRoles(conn, admin, bob, {adminRole}, .UnknownRole, "the admin role")
	assert(databaseRoleTestPermissions(conn, bob) == {}, "expected bob without permissions")
	granted := databaseRoleTestSetUserRoles(
		conn,
		admin,
		bob,
		{rooms.role.id, members.role.id},
		.Applied,
		"two roles",
	)
	assert(
		granted.changed &&
		granted.user.id == bob &&
		len(granted.user.roleIds) == 2 &&
		!granted.user.isAdmin &&
		len(granted.affected) == 1 &&
		granted.affected[0].userId == bob &&
		granted.affected[0].permissions == {.ManageRooms, .ManageRoomMembers},
		fmt.tprintf("expected bob to hold both roles, got %v", granted),
	)
	// The union of the roles.
	assert(
		databaseRoleTestPermissions(conn, bob) == {.ManageRooms, .ManageRoomMembers},
		"expected bob's permissions to be the union of his roles",
	)
	again := databaseRoleTestSetUserRoles(
		conn,
		admin,
		bob,
		{members.role.id, rooms.role.id},
		.Applied,
		"the same roles",
	)
	assert(!again.changed && len(again.affected) == 0, "expected nothing to change")
	narrowed := databaseRoleTestSetUserRoles(
		conn,
		admin,
		bob,
		{members.role.id},
		.Applied,
		"one role",
	)
	assert(
		narrowed.changed &&
		len(narrowed.user.roleIds) == 1 &&
		narrowed.affected[0].permissions == {.ManageRoomMembers},
		fmt.tprintf("expected bob down to members, got %v", narrowed),
	)

	// SetUserRoles never touches the admin role.
	adminKept := databaseRoleTestSetUserRoles(
		conn,
		admin,
		admin,
		{rooms.role.id},
		.Applied,
		"an admin's roles",
	)
	assert(
		adminKept.user.isAdmin && len(adminKept.user.roleIds) == 2 && len(adminKept.affected) == 0,
		fmt.tprintf("expected admin kept, with no permission change, got %v", adminKept),
	)
	assert(
		databaseRoleTestPermissions(conn, admin) == common.SERVER_PERMISSIONS_ALL,
		"expected an admin to hold every permission",
	)

	// Editing a held role tells its holders; an edit that keeps their set tells nobody.
	databaseRoleTestSetUserRoles(
		conn,
		admin,
		carol,
		{members.role.id, rooms.role.id},
		.Applied,
		"carol's roles",
	)
	widened := databaseRoleTestSave(
		conn,
		admin,
		members.role.id,
		"members",
		{.ManageRoomMembers, .CreateInvites},
		.Applied,
		"widening members",
	)
	assert(
		widened.changed && len(widened.affected) == 2,
		fmt.tprintf("expected bob and carol told, got %v", widened.affected),
	)
	for account in widened.affected {
		expected := common.ServerPermissions{.ManageRooms, .ManageRoomMembers, .CreateInvites}
		if account.userId == bob {
			expected = {.ManageRoomMembers, .CreateInvites}
		}
		assert(
			(account.userId == bob || account.userId == carol) &&
			account.permissions == expected,
			fmt.tprintf(
				"expected %v for %d, got %v",
				expected,
				account.userId,
				account.permissions,
			),
		)
	}
	renamed := databaseRoleTestSave(
		conn,
		admin,
		rooms.role.id,
		"room keepers",
		{.ManageRooms},
		.Applied,
		"a rename",
	)
	assert(
		renamed.changed && len(renamed.affected) == 0,
		"expected a rename to change nobody's permissions",
	)
	// Emptying "room keepers" takes ManageRooms from carol, who holds it nowhere else, so she is
	// told; the admin, who also holds the role, keeps every permission and is not.
	reduced := databaseRoleTestSave(
		conn,
		admin,
		rooms.role.id,
		"room keepers",
		{},
		.Applied,
		"emptying a role",
	)
	assert(
		len(reduced.affected) == 1 &&
		reduced.affected[0].userId == carol &&
		reduced.affected[0].permissions == {.ManageRoomMembers, .CreateInvites},
		fmt.tprintf("expected only carol told, got %v", reduced.affected),
	)

	// Deleting a role takes it from its holders and tells those whose set changed.
	databaseRoleTestExpect(
		conn,
		common.DatabaseRoleRequest{action = .Delete, actorUserId = bob, roleId = members.role.id},
		.NotAdmin,
		"a non-admin delete",
	)
	databaseRoleTestExpect(
		conn,
		common.DatabaseRoleRequest{action = .Delete, actorUserId = admin, roleId = 9999},
		.UnknownRole,
		"an unknown delete",
	)
	deleted := databaseRoleTestExpect(
		conn,
		common.DatabaseRoleRequest{action = .Delete, actorUserId = admin, roleId = members.role.id},
		.Applied,
		"a delete",
	)
	assert(
		deleted.changed && len(deleted.affected) == 2,
		fmt.tprintf("expected bob and carol told, got %v", deleted.affected),
	)
	for account in deleted.affected {
		assert(account.permissions == {}, fmt.tprintf("expected nothing left, got %v", account))
	}
	assert(
		databaseAdminTestValue(
			conn,
			fmt.tprintf(
				"SELECT count(*)::text FROM user_server_roles WHERE role_id = %d",
				members.role.id,
			),
		) ==
		"0",
		"expected the holders' rows gone with the role",
	)

	// Too many roles.
	for index in 0 ..< common.SERVER_ROLES_MAX {
		count := databaseAdminTestValue(conn, "SELECT count(*)::text FROM server_roles")
		if count == fmt.tprintf("%d", common.SERVER_ROLES_MAX) {
			break
		}
		databaseRoleTestSave(
			conn,
			admin,
			0,
			fmt.tprintf("filler %d", index),
			{},
			.Applied,
			"a filler",
		)
	}
	databaseRoleTestSave(conn, admin, 0, "one too many", {}, .TooManyRoles, "too many roles")
}

// The other statements report roles and permissions, and the room statements check them.
@(test)
testRolePermissionsInOtherStatementsAgainstPostgreSQL :: proc(t: ^testing.T) {
	_ = t
	if os.get_env(DATABASE_SQL_TEST_ENV, context.temp_allocator) != "1" {
		return
	}
	conn := databaseAdminTestOpen(t, "role_checks")

	admin := databaseAdminTestUser(conn, "perm-admin")
	databaseAdminTestGrant(conn, admin)
	bob := databaseAdminTestUser(conn, "perm-bob")
	carol := databaseAdminTestUser(conn, "perm-carol")
	adminRole := databaseRoleTestAdminRoleID(conn)

	create :: proc(conn: pg.Conn, creator: int, name: string) -> common.DatabaseRoomMutationResult {
		response := databaseExecuteRequest(
			conn,
			common.DatabaseCreateRoomRequest {
				creatorUserId = creator,
				name = name,
				roomType = .ChatAndVoice,
				access = .AdminInvite,
				historyVisibility = .FromJoin,
				creatorJoins = true,
			},
		)
		defer IPC__database_query_response_deinit(response)
		mutation, ok := response.result.(common.DatabaseRoomMutationResult)
		assert(response.success && ok, fmt.tprintf("expected the create to run: %v", response))
		copy := mutation
		copy.room.name = ""
		copy.room.description = ""
		copy.addedUserIDs = nil
		copy.memberUserIDs = nil
		return copy
	}

	// Without ManageRooms nothing is created; with it (through a role) the room is.
	refused := create(conn, bob, "perm-refused")
	assert(refused.notPermitted && !refused.changed, "expected bob refused without a role")
	assert(
		databaseAdminTestValue(
			conn,
			"SELECT count(*)::text FROM rooms WHERE name = 'perm-refused'",
		) ==
		"0",
		"expected no room stored",
	)
	databaseRoleTestGrant(conn, bob, "perm-rooms", {.ManageRooms})
	created := create(conn, bob, "perm-bobs")
	assert(created.changed && created.isMember, "expected bob's room created with him in it")

	// Edit and delete check ManageRooms too.
	edit :: proc(conn: pg.Conn, actor, roomID: int) -> common.DatabaseRoomMutationResult {
		response := databaseExecuteRequest(
			conn,
			common.DatabaseEditRoomRequest {
				actorUserId = actor,
				roomId = roomID,
				name = "perm-renamed",
				roomType = .Chat,
				access = .AdminInvite,
			},
		)
		defer IPC__database_query_response_deinit(response)
		mutation, ok := response.result.(common.DatabaseRoomMutationResult)
		assert(response.success && ok, "expected the edit to run")
		return {changed = mutation.changed, notPermitted = mutation.notPermitted}
	}
	assert(edit(conn, carol, created.room.id).notPermitted, "expected carol's edit refused")
	assert(edit(conn, bob, created.room.id).changed, "expected bob's edit applied")

	// ManageRooms does not manage members: in an Admin invite room bob cannot add carol.
	add := databaseExecuteRequest(
		conn,
		common.DatabaseRoomMemberActionRequest {
			action = .Add,
			actorUserId = bob,
			roomId = created.room.id,
			targetUserId = carol,
		},
	)
	addResult := add.result.(common.DatabaseRoomMemberActionResult)
	assert(
		add.success && addResult.outcome == .AdminRequired,
		fmt.tprintf("expected bob's add refused without ManageRoomMembers, got %v", addResult),
	)
	IPC__database_query_response_deinit(add)
	databaseRoleTestGrant(conn, bob, "perm-members", {.ManageRoomMembers})
	added := databaseExecuteRequest(
		conn,
		common.DatabaseRoomMemberActionRequest {
			action = .Add,
			actorUserId = bob,
			roomId = created.room.id,
			targetUserId = carol,
		},
	)
	addedResult := added.result.(common.DatabaseRoomMemberActionResult)
	assert(
		added.success && addedResult.outcome == .Applied && addedResult.changed,
		fmt.tprintf("expected bob's add with ManageRoomMembers, got %v", addedResult),
	)
	IPC__database_query_response_deinit(added)

	// The Admin section's room list: managers only.
	{
		list := databaseExecuteRequest(
			conn,
			common.DatabaseAdminRoomListRequest{actorUserId = carol},
		)
		defer IPC__database_query_response_deinit(list)
		rooms := list.result.(common.DatabaseAdminRoomListResult)
		assert(list.success && !rooms.allowed, "expected carol refused the admin room list")
	}
	{
		list := databaseExecuteRequest(conn, common.DatabaseAdminRoomListRequest{actorUserId = bob})
		defer IPC__database_query_response_deinit(list)
		rooms := list.result.(common.DatabaseAdminRoomListResult)
		assert(list.success && rooms.allowed, "expected bob to see every room")
	}

	// The identity statement reports the permissions with the sign-in.
	{
		key := databaseIdentityTestKey()
		identity := databaseIdentityTestResolve(conn, "perm-dave", key)
		defer delete(identity.previousNickname)
		assert(identity.permissions == {}, "expected a new account without permissions")
		databaseRoleTestGrant(conn, identity.userId, "perm-rooms", {.ManageRooms})
		again := databaseIdentityTestResolve(conn, "perm-dave", key)
		defer delete(again.previousNickname)
		assert(
			again.permissions == {.ManageRooms},
			fmt.tprintf("expected ManageRooms at sign-in, got %v", again.permissions),
		)
	}

	// The directory and the admin statements carry role IDs; granting admin reports every
	// permission and revoking it leaves the other roles' union.
	{
		directory := databaseExecuteRequest(
			conn,
			common.DatabaseUserDirectoryRequest{viewerUserId = admin},
		)
		defer IPC__database_query_response_deinit(directory)
		users := directory.result.(common.DatabaseUserDirectoryResult)
		found := false
		for user in users.users {
			if user.id == bob {
				found = true
				assert(len(user.roleIds) == 2, fmt.tprintf("expected two roles, got %v", user))
			}
		}
		assert(found, "expected bob in the directory")
	}
	grant := databaseAdminTestExpect(
		conn,
		common.DatabaseAdminUserRequest {
			action = .SetRole,
			actorUserId = admin,
			targetUserId = bob,
			isAdmin = true,
		},
		.Applied,
		"granting admin",
	)
	assert(
		grant.permissions == common.SERVER_PERMISSIONS_ALL &&
		len(grant.user.roleIds) == 3 &&
		sliceContainsInt(grant.user.roleIds[:], adminRole),
		fmt.tprintf("expected every permission and the admin role, got %v", grant),
	)
	revoke := databaseAdminTestExpect(
		conn,
		common.DatabaseAdminUserRequest {
			action = .SetRole,
			actorUserId = admin,
			targetUserId = bob,
			isAdmin = false,
		},
		.Applied,
		"revoking admin",
	)
	assert(
		revoke.permissions == {.ManageRooms, .ManageRoomMembers} &&
		len(revoke.user.roleIds) == 2 &&
		!sliceContainsInt(revoke.user.roleIds[:], adminRole),
		fmt.tprintf("expected the two roles left, got %v", revoke),
	)

	// Delete checks ManageRooms and reports the members it removed.
	deleteRoom :: proc(conn: pg.Conn, actor, roomID: int) -> (bool, bool, int) {
		response := databaseExecuteRequest(
			conn,
			common.DatabaseDeleteRoomRequest{actorUserId = actor, roomId = roomID},
		)
		defer IPC__database_query_response_deinit(response)
		mutation, ok := response.result.(common.DatabaseRoomMutationResult)
		assert(response.success && ok, "expected the delete to run")
		return mutation.notPermitted, mutation.changed, len(mutation.memberUserIDs)
	}
	notPermitted, changed, _ := deleteRoom(conn, carol, created.room.id)
	assert(notPermitted && !changed, "expected carol's delete refused")
	bobRefused, bobChanged, memberCount := deleteRoom(conn, bob, created.room.id)
	assert(
		!bobRefused && bobChanged && memberCount == 2,
		fmt.tprintf("expected the room deleted with its two members, got %d", memberCount),
	)
}

@(private = "file")
sliceContainsInt :: proc(values: []int, wanted: int) -> bool {
	for value in values {
		if value == wanted {
			return true
		}
	}
	return false
}
