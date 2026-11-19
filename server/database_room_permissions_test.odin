package server

import "../common"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "shared:pg"

// Runs the protocol 24 statements (database_room_permissions.odin and the room statements that
// read them) against a real PostgreSQL when HAYCHAT_DATABASE_SQL_TEST=1 (dev/live-proof.sh
// --all and --sql), each in a migrated schema of its own that is rolled back: the shared
// subquery, each check (post, sealed post, voice join, member add and remove, edit, grants),
// who may grant what, Role rooms' membership on create, edit, grant, revoke and role deletion,
// and the refusal of encrypted Role rooms.

// The bit constants the SQL uses must be the enum's masks.
@(test)
testRoomPermissionBitsMatchTheEnum :: proc(t: ^testing.T) {
	_ = t
	Bit :: struct {
		literal:    string,
		permission: common.RoomPermission,
	}
	for bit in ([]Bit {
			{DATABASE_ROOM_PERMISSION_SEND_MESSAGES_SQL, .SendMessages},
			{DATABASE_ROOM_PERMISSION_SPEAK_IN_VOICE_SQL, .SpeakInVoice},
			{DATABASE_ROOM_PERMISSION_MANAGE_MEMBERS_SQL, .ManageMembers},
			{DATABASE_ROOM_PERMISSION_EDIT_ROOM_SQL, .EditRoom},
			{DATABASE_ROOM_PERMISSION_ATTACH_FILES_SQL, .AttachFiles},
		}) {
		expected := fmt.tprintf("%d", common.roomPermissionsMask({bit.permission}))
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
		DATABASE_ROOM_PERMISSIONS_ALL_SQL ==
		fmt.tprintf("%d", common.roomPermissionsMask(common.ROOM_PERMISSIONS_ALL)),
		"expected the every-permission literal to be ROOM_PERMISSIONS_ALL",
	)
	// What migration 12 gave every room (send and speak), and what migration 15 makes the
	// default grant (protocol 27: attach files too).
	assert(
		strings.contains(DATABASE_MIGRATION_12_ROOM_PERMISSIONS_SQL, "DEFAULT 3;") &&
		strings.contains(DATABASE_MIGRATION_15_ATTACHMENTS_ON_MESSAGES_SQL, "SET DEFAULT 19;") &&
		DATABASE_ROOM_PERMISSIONS_DEFAULT_SQL ==
			fmt.tprintf("%d", common.roomPermissionsMask(common.ROOM_PERMISSIONS_DEFAULT)),
		"expected rooms.everyone_permissions to default to ROOM_PERMISSIONS_DEFAULT",
	)
}

// userID's permissions in roomID through the shared subquery.
@(private = "file")
databaseRoomPermissionsTestOf :: proc(
	conn: pg.Conn,
	userID, roomID: int,
) -> common.RoomPermissions {
	value := databaseAdminTestValue(
		conn,
		fmt.tprintf(
			"SELECT %s%d%s%d%s::text",
			DATABASE_ROOM_PERMISSIONS_OPEN_SQL,
			userID,
			DATABASE_ROOM_PERMISSIONS_ROOM_SQL,
			roomID,
			DATABASE_ROOM_PERMISSIONS_CLOSE_SQL,
		),
	)
	mask, ok := databaseParseTestInt(value)
	assert(ok, fmt.tprintf("expected a room permission mask, got %q", value))
	return common.roomPermissionsFromMask(i64(mask))
}

// The role's ID, creating it without server permissions when it is missing.
@(private = "file")
databaseRoomPermissionsTestRole :: proc(
	conn: pg.Conn,
	name: string,
	permissions: common.ServerPermissions = {},
) -> int {
	value := databaseAdminTestValue(
		conn,
		fmt.tprintf(
			"INSERT INTO server_roles (name, permissions) VALUES ('%s', %d) " +
			"ON CONFLICT (name) DO UPDATE SET permissions = EXCLUDED.permissions " +
			"RETURNING id::text",
			name,
			common.serverPermissionsMask(permissions),
		),
	)
	id, ok := databaseParseTestInt(value)
	assert(ok, fmt.tprintf("expected a role ID for %s, got %q", name, value))
	return id
}

@(private = "file")
databaseRoomPermissionsTestHold :: proc(conn: pg.Conn, userID, roleID: int) {
	databaseDefaultRoomTestExec(
		conn,
		"hold a role",
		fmt.tprintf(
			"INSERT INTO user_server_roles (user_id, role_id) VALUES (%d, %d) " +
			"ON CONFLICT DO NOTHING",
			userID,
			roleID,
		),
	)
}

// Runs one grants statement. Owned arrays move to the temp allocator.
@(private = "file")
databaseRoomPermissionsTestRun :: proc(
	conn: pg.Conn,
	action: common.DatabaseRoomPermissionsAction,
	actorID, roomID: int,
	everyone: common.RoomPermissions = {},
	roles: []common.RoomRoleGrant = nil,
) -> common.DatabaseRoomPermissionsResult {
	grants := make([dynamic]common.RoomRoleGrant, 0, len(roles))
	append(&grants, ..roles)
	request := common.DatabaseRoomPermissionsRequest {
		action      = action,
		actorUserId = actorID,
		roomId      = roomID,
		everyone    = everyone,
		roles       = grants,
	}
	defer IPC__database_query_request_deinit(request)
	response := databaseExecuteRequest(conn, request)
	defer IPC__database_query_response_deinit(response)
	result, ok := response.result.(common.DatabaseRoomPermissionsResult)
	assert(
		response.success && ok,
		fmt.tprintf("expected the grants statement to run: %s", response.message),
	)
	moved := result
	moved.roles = make([dynamic]common.RoomRoleGrant, context.temp_allocator)
	append(&moved.roles, ..result.roles[:])
	moved.accessRoleIds = make([dynamic]int, context.temp_allocator)
	append(&moved.accessRoleIds, ..result.accessRoleIds[:])
	moved.memberUserIDs = make([dynamic]int, context.temp_allocator)
	append(&moved.memberUserIDs, ..result.memberUserIDs[:])
	return moved
}

@(private = "file")
databaseRoomPermissionsTestSet :: proc(
	conn: pg.Conn,
	actorID, roomID: int,
	everyone: common.RoomPermissions,
	roles: []common.RoomRoleGrant,
	outcome: common.DatabaseRoomPermissionsOutcome,
	label: string,
) -> common.DatabaseRoomPermissionsResult {
	result := databaseRoomPermissionsTestRun(conn, .Set, actorID, roomID, everyone, roles)
	assert(
		result.outcome == outcome,
		fmt.tprintf("expected %s to end %v, got %v", label, outcome, result.outcome),
	)
	return result
}

// Creates a room; ok false when the statement failed (a constraint refused it).
@(private = "file")
databaseRoomPermissionsTestCreate :: proc(
	conn: pg.Conn,
	creatorID: int,
	name: string,
	access: common.RoomAccess,
	accessRoleIDs: []int = nil,
	encrypted := false,
	creatorJoins := true,
) -> (
	mutation: common.DatabaseRoomMutationResult,
	ok: bool,
) {
	roles := make([dynamic]int, 0, len(accessRoleIDs))
	append(&roles, ..accessRoleIDs)
	request := common.DatabaseCreateRoomRequest {
		creatorUserId     = creatorID,
		name              = strings.clone(name),
		description       = strings.clone(""),
		roomType          = .ChatAndVoice,
		access            = access,
		historyVisibility = .FromJoin,
		creatorJoins      = creatorJoins,
		encrypted         = encrypted,
		accessRoleIds     = roles,
	}
	defer IPC__database_query_request_deinit(request)
	response := databaseExecuteRequest(conn, request)
	defer IPC__database_query_response_deinit(response)
	result, isMutation := response.result.(common.DatabaseRoomMutationResult)
	if !response.success || !isMutation {
		return {}, false
	}
	mutation = result
	mutation.room.name = ""
	mutation.room.description = ""
	mutation.addedUserIDs = make([dynamic]int, context.temp_allocator)
	append(&mutation.addedUserIDs, ..result.addedUserIDs[:])
	mutation.memberUserIDs = nil
	mutation.removedUserIDs = nil
	return mutation, true
}

@(private = "file")
databaseRoomPermissionsTestEdit :: proc(
	conn: pg.Conn,
	actorID, roomID: int,
	name: string,
	access: common.RoomAccess,
	accessRoleIDs: []int = nil,
) -> common.DatabaseRoomMutationResult {
	roles := make([dynamic]int, 0, len(accessRoleIDs))
	append(&roles, ..accessRoleIDs)
	request := common.DatabaseEditRoomRequest {
		actorUserId   = actorID,
		roomId        = roomID,
		name          = strings.clone(name),
		description   = strings.clone(""),
		roomType      = .ChatAndVoice,
		access        = access,
		accessRoleIds = roles,
	}
	defer IPC__database_query_request_deinit(request)
	response := databaseExecuteRequest(conn, request)
	defer IPC__database_query_response_deinit(response)
	result, ok := response.result.(common.DatabaseRoomMutationResult)
	assert(response.success && ok, fmt.tprintf("expected the edit to run: %s", response.message))
	mutation := result
	mutation.room.name = ""
	mutation.room.description = ""
	mutation.addedUserIDs = make([dynamic]int, context.temp_allocator)
	append(&mutation.addedUserIDs, ..result.addedUserIDs[:])
	mutation.removedUserIDs = make([dynamic]int, context.temp_allocator)
	append(&mutation.removedUserIDs, ..result.removedUserIDs[:])
	mutation.memberUserIDs = nil
	return mutation
}

@(private = "file")
databaseRoomPermissionsTestMembers :: proc(conn: pg.Conn, roomID: int) -> string {
	return databaseAdminTestValue(
		conn,
		fmt.tprintf(
			"SELECT COALESCE(string_agg(user_id::text, ',' ORDER BY user_id), '') " +
			"FROM room_members WHERE room_id = %d",
			roomID,
		),
	)
}

@(private = "file")
databaseRoomPermissionsTestIDs :: proc(ids: ..int) -> string {
	builder := strings.builder_make(context.temp_allocator)
	for id, index in ids {
		if index > 0 {
			strings.write_byte(&builder, ',')
		}
		fmt.sbprintf(&builder, "%d", id)
	}
	return strings.to_string(builder)
}

// The post statement's verdict for a plaintext (or, with sealed, a sealed) message.
@(private = "file")
databaseRoomPermissionsTestPost :: proc(
	conn: pg.Conn,
	roomID, senderID: int,
	sealed := false,
	epoch := 0,
) -> common.DatabasePostRoomChatMessageResult {
	request := databaseTestPlainRoomPost(roomID, senderID, "hello")
	request.content = strings.clone("hello")
	if sealed {
		delete(request.content)
		request.content = strings.clone("")
		request.sealed = make([]u8, 8)
		request.sealed[0] = 1
		request.epoch = epoch
		request.chainId[0] = 7
		request.chainIndex = 0
	}
	defer IPC__database_query_request_deinit(request)
	response := databaseExecuteRequest(conn, request)
	defer IPC__database_query_response_deinit(response)
	result, ok := response.result.(common.DatabasePostRoomChatMessageResult)
	assert(response.success && ok, fmt.tprintf("expected the post to run: %s", response.message))
	verdict := result
	verdict.storedMessage = {id = result.storedMessage.id}
	verdict.recipientUserIDs = nil
	return verdict
}

@(private = "file")
databaseRoomPermissionsTestMemberAction :: proc(
	conn: pg.Conn,
	action: common.RoomMemberAction,
	actorID, roomID, targetID: int,
) -> common.DatabaseRoomMemberOutcome {
	response := databaseExecuteRequest(
		conn,
		common.DatabaseRoomMemberActionRequest {
			action = action,
			actorUserId = actorID,
			roomId = roomID,
			targetUserId = targetID,
		},
	)
	defer IPC__database_query_response_deinit(response)
	result, ok := response.result.(common.DatabaseRoomMemberActionResult)
	assert(
		response.success && ok,
		fmt.tprintf("expected the %v statement to run: %s", action, response.message),
	)
	return result.outcome
}

@(test)
testRoomPermissionChecksAgainstPostgreSQL :: proc(t: ^testing.T) {
	_ = t
	if os.get_env(DATABASE_SQL_TEST_ENV, context.temp_allocator) != "1" {
		return
	}
	conn := databaseAdminTestOpen(t, "room_permissions")
	admin := databaseAdminTestUser(conn, "perm-admin")
	databaseAdminTestGrant(conn, admin)
	bob := databaseAdminTestUser(conn, "perm-bob")
	carol := databaseAdminTestUser(conn, "perm-carol")
	dave := databaseAdminTestUser(conn, "perm-dave")
	adminRole := databaseRoleTestAdminRoleID(conn)
	speakers := databaseRoomPermissionsTestRole(conn, "speakers")
	editors := databaseRoomPermissionsTestRole(conn, "editors")
	keepers := databaseRoomPermissionsTestRole(conn, "keepers")
	membersRole := databaseRoomPermissionsTestRole(conn, "members", {.ManageRoomMembers})

	lobby, lobbyOK := databaseRoomPermissionsTestCreate(conn, admin, "lobby", .Public)
	assert(lobbyOK && lobby.changed, "expected a Public room")
	assert(
		lobby.room.myPermissions == common.ROOM_PERMISSIONS_ALL,
		fmt.tprintf("expected the admin creator to hold every permission, got %v", lobby.room),
	)
	room := lobby.room.id

	// The shared subquery: the default grant for members, every bit for an admin, what server
	// permissions imply for anyone, nothing for a missing room but those.
	assert(
		databaseRoomPermissionsTestOf(conn, bob, room) == common.ROOM_PERMISSIONS_DEFAULT,
		"expected a member to hold the default grant",
	)
	assert(
		databaseRoomPermissionsTestOf(conn, admin, room) == common.ROOM_PERMISSIONS_ALL,
		"expected an admin to hold every room permission",
	)
	databaseRoomPermissionsTestHold(conn, dave, membersRole)
	assert(
		databaseRoomPermissionsTestOf(conn, dave, 999_999) == {.ManageMembers},
		"expected ManageRoomMembers to imply ManageMembers in every room",
	)

	// Only ManageRooms or the room's EditRoom read or change the grants.
	fetched := databaseRoomPermissionsTestRun(conn, .Fetch, bob, room)
	assert(fetched.outcome == .NotPermitted, "expected a plain member refused the grants")
	missing := databaseRoomPermissionsTestRun(conn, .Fetch, admin, 999_999)
	assert(missing.outcome == .UnknownRoom, "expected a missing room unknown to ManageRooms")
	databaseRoomPermissionsTestSet(
		conn,
		admin,
		room,
		{.SpeakInVoice},
		{{roleId = adminRole, permissions = {.SendMessages}}},
		.UnknownRole,
		"a grant to the built-in role",
	)

	// A read-only room for everyone but the speakers, and EditRoom for the editors.
	readOnly := databaseRoomPermissionsTestSet(
		conn,
		admin,
		room,
		{.SpeakInVoice},
		{
			{roleId = speakers, permissions = {.SendMessages}},
			{roleId = editors, permissions = {.EditRoom}},
		},
		.Applied,
		"the admin's grants",
	)
	assert(
		readOnly.changed &&
		readOnly.everyone == {.SpeakInVoice} &&
		len(readOnly.roles) == 2 &&
		readOnly.myPermissions == common.ROOM_PERMISSIONS_ALL &&
		databaseRoomPermissionsTestIDs(..readOnly.memberUserIDs[:]) ==
			databaseRoomPermissionsTestIDs(admin, bob, carol, dave),
		fmt.tprintf("expected the grants stored with every member listed, got %v", readOnly),
	)
	again := databaseRoomPermissionsTestSet(
		conn,
		admin,
		room,
		{.SpeakInVoice},
		{
			{roleId = speakers, permissions = {.SendMessages}},
			{roleId = editors, permissions = {.EditRoom}},
		},
		.Applied,
		"the same grants",
	)
	assert(!again.changed, "expected the same grants to change nothing")

	// The post statement: a member without SendMessages is refused, a speaker is not.
	refused := databaseRoomPermissionsTestPost(conn, room, bob)
	assert(
		refused.isMember && refused.sendDenied && refused.storedMessage.id == 0,
		fmt.tprintf("expected bob refused in a read-only room, got %v", refused),
	)
	databaseRoomPermissionsTestHold(conn, bob, speakers)
	posted := databaseRoomPermissionsTestPost(conn, room, bob)
	assert(
		!posted.sendDenied && posted.storedMessage.id > 0,
		fmt.tprintf("expected a speaker's message stored, got %v", posted),
	)
	adminPost := databaseRoomPermissionsTestPost(conn, room, admin)
	assert(adminPost.storedMessage.id > 0, "expected an admin to send anywhere")

	// The voice join check reports the joiner's permissions; SpeakInVoice decides the relay.
	{
		response := databaseExecuteRequest(
			conn,
			common.DatabaseRoomMemberListRequest{roomId = room, userId = carol},
		)
		defer IPC__database_query_response_deinit(response)
		list, ok := response.result.(common.DatabaseRoomMemberListResult)
		assert(
			response.success && ok && list.permissions == {.SpeakInVoice},
			fmt.tprintf("expected carol to speak but not send, got %v", list),
		)
	}
	databaseRoomPermissionsTestSet(
		conn,
		admin,
		room,
		{},
		{
			{roleId = speakers, permissions = {.SendMessages, .SpeakInVoice}},
			{roleId = editors, permissions = {.EditRoom}},
		},
		.Applied,
		"a room only speakers may speak in",
	)
	{
		response := databaseExecuteRequest(
			conn,
			common.DatabaseRoomMemberListRequest{roomId = room, userId = carol},
		)
		defer IPC__database_query_response_deinit(response)
		list, ok := response.result.(common.DatabaseRoomMemberListResult)
		assert(
			response.success && ok && list.permissions == {},
			fmt.tprintf("expected carol to lose SpeakInVoice, got %v", list),
		)
	}

	// Grants by a member holding EditRoom: only bits it holds may change.
	databaseRoomPermissionsTestHold(conn, carol, editors)
	carolView := databaseRoomPermissionsTestRun(conn, .Fetch, carol, room)
	assert(
		carolView.outcome == .Applied && carolView.myPermissions == {.EditRoom},
		fmt.tprintf("expected carol to read the grants with EditRoom, got %v", carolView),
	)
	databaseRoomPermissionsTestSet(
		conn,
		carol,
		room,
		{.SendMessages},
		{
			{roleId = speakers, permissions = {.SendMessages, .SpeakInVoice}},
			{roleId = editors, permissions = {.EditRoom}},
		},
		.NotGrantable,
		"carol granting SendMessages, which she lacks",
	)
	databaseRoomPermissionsTestSet(
		conn,
		carol,
		room,
		{},
		{{roleId = editors, permissions = {.EditRoom}}},
		.NotGrantable,
		"carol taking away the speakers' grant",
	)
	databaseRoomPermissionsTestSet(
		conn,
		carol,
		room,
		{},
		{
			{roleId = speakers, permissions = {.SendMessages, .SpeakInVoice}},
			{roleId = editors, permissions = {.EditRoom}},
			{roleId = keepers, permissions = {.EditRoom}},
		},
		.Applied,
		"carol sharing EditRoom with the keepers",
	)
	assert(
		databaseAdminTestValue(
			conn,
			fmt.tprintf(
				"SELECT permissions::text FROM room_role_permissions " +
				"WHERE room_id = %d AND role_id = %d",
				room,
				keepers,
			),
		) ==
		"8",
		"expected the keepers' EditRoom stored",
	)

	// The edit statement: EditRoom changes the name, never the access.
	renamed := databaseRoomPermissionsTestEdit(conn, carol, room, "hall", .Public)
	assert(renamed.changed && !renamed.notPermitted, "expected carol to rename the room")
	switched := databaseRoomPermissionsTestEdit(conn, carol, room, "hall", .AdminInvite)
	assert(switched.notPermitted, "expected carol refused a change of access")
	stranger := databaseRoomPermissionsTestEdit(conn, bob, room, "bobs", .Public)
	assert(stranger.notPermitted, "expected a member without EditRoom refused")

	// Member statements: the room's ManageMembers lets a member add and remove.
	crewRoom, crewOK := databaseRoomPermissionsTestCreate(conn, admin, "crew", .AdminInvite)
	assert(crewOK, "expected an Admin invite room")
	crew := crewRoom.room.id
	assert(
		databaseRoomPermissionsTestMemberAction(conn, .Add, admin, crew, carol) == .Applied &&
		databaseRoomPermissionsTestMemberAction(conn, .Add, admin, crew, bob) == .Applied,
		"expected the admin to add carol and bob",
	)
	assert(
		databaseRoomPermissionsTestMemberAction(conn, .Add, carol, crew, admin + 1000) ==
		.AdminRequired,
		"expected carol to need ManageMembers in an Admin invite room",
	)
	databaseRoomPermissionsTestSet(
		conn,
		admin,
		crew,
		common.ROOM_PERMISSIONS_DEFAULT,
		{{roleId = keepers, permissions = {.ManageMembers}}},
		.Applied,
		"ManageMembers for the keepers",
	)
	databaseRoomPermissionsTestHold(conn, carol, keepers)
	assert(
		databaseRoomPermissionsTestMemberAction(conn, .Add, carol, crew, dave) == .Applied,
		"expected a keeper to add dave",
	)
	assert(
		databaseRoomPermissionsTestMemberAction(conn, .Remove, bob, crew, dave) == .AdminRequired,
		"expected bob, without the grant, refused a removal",
	)
	assert(
		databaseRoomPermissionsTestMemberAction(conn, .Remove, carol, crew, dave) == .Applied,
		"expected a keeper to remove dave",
	)
	assert(
		databaseRoomPermissionsTestMembers(conn, crew) ==
		databaseRoomPermissionsTestIDs(admin, bob, carol),
		"expected admin, bob and carol left",
	)
	// The grant applies only to members: carol outside the room manages nothing there.
	assert(
		databaseRoomPermissionsTestMemberAction(conn, .Leave, carol, crew, 0) == .Applied &&
		databaseRoomPermissionsTestMemberAction(conn, .Add, carol, crew, dave) == .NotMember,
		"expected a former member's grant to stop applying",
	)
}

@(test)
testEncryptedRoomPermissionsAgainstPostgreSQL :: proc(t: ^testing.T) {
	_ = t
	if os.get_env(DATABASE_SQL_TEST_ENV, context.temp_allocator) != "1" {
		return
	}
	conn := databaseAdminTestOpen(t, "encrypted_room_permissions")
	admin := databaseAdminTestUser(conn, "enc-admin")
	databaseAdminTestGrant(conn, admin)
	bob := databaseAdminTestUser(conn, "enc-bob")
	crew := databaseRoomPermissionsTestRole(conn, "enc-crew")

	// An encrypted room at log version 1 with bob as a member, made directly.
	roomText := databaseAdminTestValue(
		conn,
		"INSERT INTO rooms (name, description, access, history_visibility, encrypted, " +
		"log_version) VALUES ('vault', '', 2, 1, true, 1) RETURNING id::text",
	)
	room, roomOK := databaseParseTestInt(roomText)
	assert(roomOK, "expected an encrypted room")
	databaseDefaultRoomTestExec(
		conn,
		"add bob",
		fmt.tprintf("INSERT INTO room_members (room_id, user_id) VALUES (%d, %d)", room, bob),
	)
	stored := databaseRoomPermissionsTestPost(conn, room, bob, sealed = true, epoch = 1)
	assert(stored.storedMessage.id > 0, fmt.tprintf("expected a sealed message, got %v", stored))
	databaseRoomPermissionsTestSet(
		conn,
		admin,
		room,
		{.SpeakInVoice},
		nil,
		.Applied,
		"a read-only encrypted room",
	)
	refused := databaseRoomPermissionsTestPost(conn, room, bob, sealed = true, epoch = 1)
	assert(
		refused.isMember && refused.sendDenied && refused.storedMessage.id == 0,
		fmt.tprintf("expected the sealed message refused without Send, got %v", refused),
	)

	// Encrypted rooms never take their members from roles. The constraint aborts the statement,
	// so it runs under a savepoint of the test's transaction.
	databaseDefaultRoomTestExec(conn, "savepoint", "SAVEPOINT encrypted_role")
	_, created := databaseRoomPermissionsTestCreate(
		conn,
		admin,
		"sealed-crew",
		.Role,
		{crew},
		encrypted = true,
	)
	assert(!created, "expected an encrypted Role room refused by rooms_encrypted_not_role")
	databaseDefaultRoomTestExec(conn, "roll back", "ROLLBACK TO SAVEPOINT encrypted_role")
	assert(
		databaseAdminTestValue(
			conn,
			"SELECT count(*)::text FROM rooms WHERE name = 'sealed-crew'",
		) ==
		"0",
		"expected nothing created",
	)
}

@(test)
testRoleRoomMembershipAgainstPostgreSQL :: proc(t: ^testing.T) {
	_ = t
	if os.get_env(DATABASE_SQL_TEST_ENV, context.temp_allocator) != "1" {
		return
	}
	conn := databaseAdminTestOpen(t, "role_rooms")
	admin := databaseAdminTestUser(conn, "rr-admin")
	databaseAdminTestGrant(conn, admin)
	bob := databaseAdminTestUser(conn, "rr-bob")
	carol := databaseAdminTestUser(conn, "rr-carol")
	dave := databaseAdminTestUser(conn, "rr-dave")
	adminRole := databaseRoleTestAdminRoleID(conn)
	crew := databaseRoomPermissionsTestRole(conn, "crew")
	deck := databaseRoomPermissionsTestRole(conn, "deck")
	databaseRoomPermissionsTestHold(conn, bob, crew)
	databaseRoomPermissionsTestHold(conn, dave, deck)

	// An access role must exist and not be the built-in one.
	refusedCreate, refusedOK := databaseRoomPermissionsTestCreate(
		conn,
		admin,
		"admins-only",
		.Role,
		{adminRole},
	)
	assert(
		refusedOK && refusedCreate.refusal == .UnknownAccessRole && !refusedCreate.changed,
		fmt.tprintf("expected the built-in role refused as an access role, got %v", refusedCreate),
	)

	// A Role room's members are its roles' holders, the creator only as one of them.
	created, createdOK := databaseRoomPermissionsTestCreate(conn, admin, "bridge", .Role, {crew})
	assert(createdOK && created.changed && !created.isMember, "expected a Role room")
	room := created.room.id
	assert(
		created.room.access == .Role &&
		databaseRoomPermissionsTestIDs(..created.addedUserIDs[:]) ==
			databaseRoomPermissionsTestIDs(bob) &&
		databaseRoomPermissionsTestMembers(conn, room) == databaseRoomPermissionsTestIDs(bob),
		fmt.tprintf("expected only bob, the crew, a member, got %v", created.addedUserIDs),
	)

	// Nobody adds, removes or leaves by hand.
	assert(
		databaseRoomPermissionsTestMemberAction(conn, .Add, admin, room, carol) == .RoleRoom &&
		databaseRoomPermissionsTestMemberAction(conn, .Remove, admin, room, bob) == .RoleRoom &&
		databaseRoomPermissionsTestMemberAction(conn, .Leave, bob, room, 0) == .RoleRoom,
		"expected a Role room's members to come only from roles",
	)

	// Granting the role adds the account, in the same statement.
	granted := databaseRoleTestSetUserRoles(conn, admin, carol, {crew}, .Applied, "carol joins")
	assert(
		len(granted.membershipChanges) == 1 &&
		granted.membershipChanges[0].roomId == room &&
		granted.membershipChanges[0].userId == carol &&
		granted.membershipChanges[0].joined &&
		databaseRoomPermissionsTestIDs(..granted.membershipChanges[0].memberUserIDs[:]) ==
			databaseRoomPermissionsTestIDs(bob, carol) &&
		len(granted.roomPermissionUserIDs) == 1 &&
		granted.roomPermissionUserIDs[0] == carol,
		fmt.tprintf("expected carol to join the bridge, got %v", granted.membershipChanges),
	)
	assert(
		databaseRoomPermissionsTestMembers(conn, room) ==
		databaseRoomPermissionsTestIDs(bob, carol),
		"expected bob and carol members",
	)

	// Revoking it removes the account and its read marker.
	databaseDefaultRoomTestExec(
		conn,
		"mark bob read",
		fmt.tprintf(
			"INSERT INTO room_read_markers (user_id, room_id, last_read_message_id) " +
			"VALUES (%d, %d, 0)",
			bob,
			room,
		),
	)
	revoked := databaseRoleTestSetUserRoles(conn, admin, bob, {}, .Applied, "bob leaves")
	assert(
		len(revoked.membershipChanges) == 1 &&
		!revoked.membershipChanges[0].joined &&
		revoked.membershipChanges[0].userId == bob &&
		databaseRoomPermissionsTestIDs(..revoked.membershipChanges[0].memberUserIDs[:]) ==
			databaseRoomPermissionsTestIDs(carol),
		fmt.tprintf("expected bob to leave, got %v", revoked.membershipChanges),
	)
	assert(
		databaseRoomPermissionsTestMembers(conn, room) == databaseRoomPermissionsTestIDs(carol) &&
		databaseAdminTestValue(
			conn,
			fmt.tprintf(
				"SELECT count(*)::text FROM room_read_markers WHERE user_id = %d " +
				"AND room_id = %d",
				bob,
				room,
			),
		) ==
		"0",
		"expected bob's membership and read marker gone",
	)
	unchanged := databaseRoleTestSetUserRoles(conn, admin, bob, {}, .Applied, "bob again")
	assert(len(unchanged.membershipChanges) == 0, "expected nothing more to change")

	// Changing the access roles makes the members exactly the new holders.
	both := databaseRoomPermissionsTestEdit(conn, admin, room, "bridge", .Role, {crew, deck})
	assert(
		both.changed &&
		databaseRoomPermissionsTestIDs(..both.addedUserIDs[:]) ==
			databaseRoomPermissionsTestIDs(dave) &&
		len(both.removedUserIDs) == 0,
		fmt.tprintf("expected dave added with the deck, got %v", both),
	)
	deckOnly := databaseRoomPermissionsTestEdit(conn, admin, room, "bridge", .Role, {deck})
	assert(
		databaseRoomPermissionsTestIDs(..deckOnly.removedUserIDs[:]) ==
		databaseRoomPermissionsTestIDs(carol),
		fmt.tprintf("expected carol removed with the crew, got %v", deckOnly),
	)
	// A member holding only EditRoom must repeat the access roles.
	editors := databaseRoomPermissionsTestRole(conn, "rr-editors")
	databaseRoomPermissionsTestHold(conn, dave, editors)
	databaseRoomPermissionsTestSet(
		conn,
		admin,
		room,
		common.ROOM_PERMISSIONS_DEFAULT,
		{{roleId = editors, permissions = {.EditRoom}}},
		.Applied,
		"EditRoom for dave",
	)
	keep := databaseRoomPermissionsTestEdit(conn, dave, room, "deck", .Role, {deck})
	assert(keep.changed, "expected dave to rename the room with its roles unchanged")
	change := databaseRoomPermissionsTestEdit(conn, dave, room, "deck", .Role, {crew, deck})
	assert(change.notPermitted, "expected dave refused a change of the access roles")

	// Deleting a role ends the memberships it gave.
	deleted := databaseRoleTestExpect(
		conn,
		common.DatabaseRoleRequest{action = .Delete, actorUserId = admin, roleId = deck},
		.Applied,
		"the deck's deletion",
	)
	assert(
		len(deleted.membershipChanges) == 1 &&
		deleted.membershipChanges[0].userId == dave &&
		!deleted.membershipChanges[0].joined &&
		len(deleted.roomPermissionUserIDs) == 1 &&
		deleted.roomPermissionUserIDs[0] == dave,
		fmt.tprintf("expected dave to leave with the deck, got %v", deleted.membershipChanges),
	)
	assert(
		databaseRoomPermissionsTestMembers(conn, room) == "" &&
		databaseAdminTestValue(
			conn,
			fmt.tprintf("SELECT count(*)::text FROM room_access_roles WHERE room_id = %d", room),
		) ==
		"0",
		"expected an empty room without access roles",
	)

	// Switching away from Role keeps the members and drops the access roles.
	databaseRoomPermissionsTestEdit(conn, admin, room, "deck", .Role, {crew})
	assert(
		databaseRoomPermissionsTestMembers(conn, room) == databaseRoomPermissionsTestIDs(carol),
		"expected carol back with the crew",
	)
	away := databaseRoomPermissionsTestEdit(conn, admin, room, "deck", .MemberInvite)
	assert(away.changed && len(away.removedUserIDs) == 0, "expected nobody removed")
	assert(
		databaseRoomPermissionsTestMembers(conn, room) == databaseRoomPermissionsTestIDs(carol) &&
		databaseAdminTestValue(
			conn,
			fmt.tprintf("SELECT count(*)::text FROM room_access_roles WHERE room_id = %d", room),
		) ==
		"0",
		"expected carol kept and the access roles gone",
	)
	// The crew no longer reaches the room.
	regranted := databaseRoleTestSetUserRoles(conn, admin, bob, {crew}, .Applied, "bob rejoins")
	assert(len(regranted.membershipChanges) == 0, "expected a Member invite room left alone")
}
