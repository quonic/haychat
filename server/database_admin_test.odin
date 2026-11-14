package server

import "../common"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import "shared:pg"

// Runs the protocol 14 statements against a real PostgreSQL when HAYCHAT_DATABASE_SQL_TEST=1
// (dev/live-proof.sh --all and --sql): the identity statement with a locked name and a ban, the
// admin action statements with every guard, and room types. Like the identity test, each runs
// inside one transaction in a schema of its own that is rolled back.

// Opens a connection inside a transaction whose search_path is a new, migrated schema. The
// caller defers databaseAdminTestClose, which rolls everything back.
databaseAdminTestOpen :: proc(label: string) -> pg.Conn {
	conn, openErr := databaseOpenRuntimeConnection(databaseSQLTestConfig())
	assert(len(openErr) == 0, openErr)
	schema := fmt.tprintf("haychat_%s_test_%d", label, time.time_to_unix_nano(time.now()))
	databaseDefaultRoomTestExec(conn, "begin admin test", "BEGIN")
	databaseDefaultRoomTestExec(
		conn,
		"isolate admin test",
		fmt.tprintf(
			"SET LOCAL client_min_messages TO warning; CREATE SCHEMA %s; " +
			"SET LOCAL search_path TO %s",
			schema,
			schema,
		),
	)
	_, migrateErr := databaseApplyMigrations(conn, DATABASE_MIGRATIONS[:])
	assert(len(migrateErr) == 0, migrateErr)
	return conn
}

databaseAdminTestClose :: proc(conn: pg.Conn) {
	databaseDefaultRoomTestExec(conn, "roll back admin test", "ROLLBACK")
	pg.finish(conn)
}

// Column 0 of a one-row query, in the temp allocator.
databaseAdminTestValue :: proc(conn: pg.Conn, query: string) -> string {
	value := databaseDefaultRoomTestValue(conn, fmt.ctprintf("%s", query))
	defer delete(value)
	return strings.clone(value, context.temp_allocator)
}

// Creates an account without a key and returns its ID.
databaseAdminTestUser :: proc(conn: pg.Conn, nickname: string) -> int {
	value := databaseAdminTestValue(
		conn,
		fmt.tprintf("INSERT INTO users (nickname) VALUES ('%s') RETURNING id::text", nickname),
	)
	id, ok := databaseParseTestInt(value)
	assert(ok, fmt.tprintf("expected an ID for %s, got %q", nickname, value))
	return id
}

databaseParseTestInt :: proc(text: string) -> (int, bool) {
	ids := databaseParseIDList(text)
	defer delete(ids)
	if len(ids) != 1 {
		return 0, false
	}
	return ids[0], true
}

databaseAdminTestGrant :: proc(conn: pg.Conn, userID: int) {
	databaseDefaultRoomTestExec(
		conn,
		"grant admin",
		fmt.tprintf(
			"INSERT INTO server_roles (name) VALUES ('admin') ON CONFLICT DO NOTHING; " +
			"INSERT INTO user_server_roles (user_id, role_id) " +
			"SELECT %d, id FROM server_roles WHERE name = 'admin' ON CONFLICT DO NOTHING",
			userID,
		),
	)
}

// Runs one admin statement. The result's strings are moved to the temp allocator.
databaseAdminTestRun :: proc(
	conn: pg.Conn,
	request: common.DatabaseAdminUserRequest,
) -> common.DatabaseAdminUserResult {
	response := databaseExecuteRequest(conn, request)
	result, resultOK := response.result.(common.DatabaseAdminUserResult)
	assert(
		response.success && resultOK,
		fmt.tprintf("expected the admin statement %v to run: %s", request, response.message),
	)
	delete(response.message)
	nickname := result.user.nickname
	result.user.nickname = strings.clone(nickname, context.temp_allocator)
	delete(nickname)
	previous := result.previousNickname
	result.previousNickname = strings.clone(previous, context.temp_allocator)
	delete(previous)
	return result
}

databaseAdminTestExpect :: proc(
	conn: pg.Conn,
	request: common.DatabaseAdminUserRequest,
	outcome: common.DatabaseAdminOutcome,
	label: string,
) -> common.DatabaseAdminUserResult {
	result := databaseAdminTestRun(conn, request)
	assert(
		result.outcome == outcome,
		fmt.tprintf("expected %s to end %v, got %v", label, outcome, result),
	)
	return result
}

@(test)
testAdminIdentityLockAndBanAgainstPostgreSQL :: proc(t: ^testing.T) {
	_ = t
	if os.get_env(DATABASE_SQL_TEST_ENV, context.temp_allocator) != "1" {
		return
	}
	conn := databaseAdminTestOpen("admin_identity")
	defer databaseAdminTestClose(conn)

	aliceKey := databaseIdentityTestKey()
	alice := databaseIdentityTestResolve(conn, "lock-alice", aliceKey)
	defer delete(alice.previousNickname)
	assert(
		alice.userId > 0 &&
		alice.nickname == "lock-alice" &&
		!alice.nicknameLocked &&
		!alice.banned,
		fmt.tprintf("expected a new, unlocked, unbanned account, got %v", alice),
	)

	// An admin renamed the account and locked the name: a sign-in under another name keeps it.
	databaseDefaultRoomTestExec(
		conn,
		"lock alice's name",
		fmt.tprintf(
			"UPDATE users SET nickname = 'admin-chose', nickname_locked = true WHERE id = %d",
			alice.userId,
		),
	)
	{
		locked := databaseIdentityTestResolve(conn, "lock-alice", aliceKey)
		defer delete(locked.previousNickname)
		assert(
			locked.userId == alice.userId &&
			!locked.renamed &&
			locked.nickname == "admin-chose" &&
			locked.nicknameLocked,
			fmt.tprintf("expected the locked name kept, got %v", locked),
		)
		name := databaseAdminTestValue(
			conn,
			fmt.tprintf("SELECT nickname FROM users WHERE id = %d", alice.userId),
		)
		assert(name == "admin-chose", fmt.tprintf("expected no rename, got %q", name))
	}
	// Unlocked, the next sign-in takes the client's name again.
	databaseDefaultRoomTestExec(
		conn,
		"unlock alice's name",
		fmt.tprintf("UPDATE users SET nickname_locked = false WHERE id = %d", alice.userId),
	)
	{
		unlocked := databaseIdentityTestResolve(conn, "lock-alice", aliceKey)
		defer delete(unlocked.previousNickname)
		assert(
			unlocked.userId == alice.userId &&
			unlocked.renamed &&
			unlocked.previousNickname == "admin-chose" &&
			unlocked.nickname == "lock-alice" &&
			!unlocked.nicknameLocked,
			fmt.tprintf("expected the client's name back, got %v", unlocked),
		)
	}

	// A banned account resolves with its ban and its reason, and is never renamed.
	databaseDefaultRoomTestExec(
		conn,
		"ban alice",
		fmt.tprintf(
			"UPDATE users SET banned_at = CURRENT_TIMESTAMP, ban_reason = 'spam' WHERE id = %d",
			alice.userId,
		),
	)
	{
		banned := databaseIdentityTestResolve(conn, "ban-new-name", aliceKey)
		defer delete(banned.previousNickname)
		assert(
			banned.userId == alice.userId &&
			!banned.renamed &&
			banned.banned &&
			banned.banReason == "spam" &&
			banned.nickname == "lock-alice",
			fmt.tprintf("expected the ban reported without a rename, got %v", banned),
		)
	}
	databaseDefaultRoomTestExec(
		conn,
		"unban alice",
		fmt.tprintf(
			"UPDATE users SET banned_at = NULL, ban_reason = '' WHERE id = %d",
			alice.userId,
		),
	)
	{
		unbanned := databaseIdentityTestResolve(conn, "lock-alice", aliceKey)
		defer delete(unbanned.previousNickname)
		assert(
			unbanned.userId == alice.userId && !unbanned.banned && unbanned.banReason == "",
			fmt.tprintf("expected the ban lifted, got %v", unbanned),
		)
	}

	// A keyless account that is banned stays banned when a key claims it.
	keyless := databaseAdminTestUser(conn, "keyless-banned")
	databaseDefaultRoomTestExec(
		conn,
		"ban the keyless account",
		fmt.tprintf("UPDATE users SET banned_at = CURRENT_TIMESTAMP WHERE id = %d", keyless),
	)
	{
		claimed := databaseIdentityTestResolve(conn, "keyless-banned", databaseIdentityTestKey())
		defer delete(claimed.previousNickname)
		assert(
			claimed.userId == keyless && claimed.banned && claimed.banReason == "",
			fmt.tprintf("expected the claimed account banned, got %v", claimed),
		)
	}
}

@(test)
testAdminActionStatementsAgainstPostgreSQL :: proc(t: ^testing.T) {
	_ = t
	if os.get_env(DATABASE_SQL_TEST_ENV, context.temp_allocator) != "1" {
		return
	}
	conn := databaseAdminTestOpen("admin_actions")
	defer databaseAdminTestClose(conn)

	admin := databaseAdminTestUser(conn, "act-admin")
	bob := databaseAdminTestUser(conn, "act-bob")
	carol := databaseAdminTestUser(conn, "act-carol")
	databaseAdminTestGrant(conn, admin)
	unknown := carol + 1000

	// Only an admin may act, and only on an account that exists.
	for action in common.AdminAction {
		databaseAdminTestExpect(
			conn,
			{
				action = action,
				actorUserId = bob,
				targetUserId = carol,
				isAdmin = true,
				nickname = "x-y-z",
				banned = true,
			},
			.NotAdmin,
			fmt.tprintf("%v by a non-admin", action),
		)
		databaseAdminTestExpect(
			conn,
			{
				action = action,
				actorUserId = admin,
				targetUserId = unknown,
				isAdmin = true,
				nickname = "x-y-z",
				banned = true,
			},
			.UnknownUser,
			fmt.tprintf("%v of an unknown account", action),
		)
	}

	// The sole admin cannot revoke the role: the server must keep one (checked before self).
	databaseAdminTestExpect(
		conn,
		{action = .SetRole, actorUserId = admin, targetUserId = admin},
		.LastAdmin,
		"the last admin's revoke",
	)

	// Grant, then a repeated grant that changes nothing.
	{
		granted := databaseAdminTestExpect(
			conn,
			{action = .SetRole, actorUserId = admin, targetUserId = bob, isAdmin = true},
			.Applied,
			"the grant",
		)
		assert(
			granted.changed &&
			granted.user.id == bob &&
			granted.user.nickname == "act-bob" &&
			granted.user.isAdmin &&
			!granted.user.isBanned,
			fmt.tprintf("expected bob made an admin, got %v", granted),
		)
		again := databaseAdminTestExpect(
			conn,
			{action = .SetRole, actorUserId = admin, targetUserId = bob, isAdmin = true},
			.Applied,
			"the repeated grant",
		)
		assert(
			!again.changed && again.user.isAdmin,
			"expected the repeated grant to change nothing",
		)
	}
	// With two admins, revoking yourself is still refused, and admins cannot be kicked or banned.
	databaseAdminTestExpect(
		conn,
		{action = .SetRole, actorUserId = admin, targetUserId = admin},
		.SelfTarget,
		"revoking your own role",
	)
	databaseAdminTestExpect(
		conn,
		{action = .Kick, actorUserId = admin, targetUserId = bob},
		.AdminTarget,
		"kicking an admin",
	)
	databaseAdminTestExpect(
		conn,
		{action = .Ban, actorUserId = admin, targetUserId = bob, banned = true},
		.AdminTarget,
		"banning an admin",
	)
	databaseAdminTestExpect(
		conn,
		{action = .Kick, actorUserId = admin, targetUserId = admin},
		.SelfTarget,
		"kicking yourself",
	)
	databaseAdminTestExpect(
		conn,
		{action = .Ban, actorUserId = admin, targetUserId = admin, banned = true},
		.SelfTarget,
		"banning yourself",
	)
	{
		revoked := databaseAdminTestExpect(
			conn,
			{action = .SetRole, actorUserId = admin, targetUserId = bob},
			.Applied,
			"the revoke",
		)
		assert(revoked.changed && !revoked.user.isAdmin, "expected bob's role revoked")
		admins := databaseAdminTestValue(
			conn,
			"SELECT string_agg(usr.user_id::text, ',') FROM user_server_roles usr " +
			"JOIN server_roles sr ON sr.id = usr.role_id WHERE sr.name = 'admin'",
		)
		assert(
			admins == fmt.tprintf("%d", admin),
			fmt.tprintf("expected one admin, got %q", admins),
		)
	}

	// A kick changes nothing in the database.
	{
		kicked := databaseAdminTestExpect(
			conn,
			{action = .Kick, actorUserId = admin, targetUserId = carol, reason = "bye"},
			.Applied,
			"the kick",
		)
		assert(!kicked.changed && kicked.user.id == carol, "expected the kick to pass the guards")
	}

	// Ban with a reason, ban again with another (banned_at stays), and no role while banned.
	{
		banned := databaseAdminTestExpect(
			conn,
			{
				action = .Ban,
				actorUserId = admin,
				targetUserId = carol,
				banned = true,
				reason = "spam",
			},
			.Applied,
			"the ban",
		)
		assert(banned.changed && banned.user.isBanned, "expected carol banned")
		first := databaseAdminTestValue(
			conn,
			fmt.tprintf(
				"SELECT banned_at::text || '|' || ban_reason FROM users WHERE id = %d",
				carol,
			),
		)
		assert(
			strings.has_suffix(first, "|spam"),
			fmt.tprintf("expected the reason, got %q", first),
		)
		rebanned := databaseAdminTestExpect(
			conn,
			{
				action = .Ban,
				actorUserId = admin,
				targetUserId = carol,
				banned = true,
				reason = "abuse",
			},
			.Applied,
			"the second ban",
		)
		assert(rebanned.changed && rebanned.user.isBanned, "expected the new reason stored")
		second := databaseAdminTestValue(
			conn,
			fmt.tprintf(
				"SELECT banned_at::text || '|' || ban_reason FROM users WHERE id = %d",
				carol,
			),
		)
		firstBannedAt := strings.split(first, "|", context.temp_allocator)[0]
		assert(
			second == fmt.tprintf("%s|abuse", firstBannedAt),
			fmt.tprintf("expected banned_at kept and the reason replaced, got %q", second),
		)
		databaseAdminTestExpect(
			conn,
			{action = .SetRole, actorUserId = admin, targetUserId = carol, isAdmin = true},
			.BannedTarget,
			"making a banned account an admin",
		)
		directory := databaseExecuteRequest(conn, common.DatabaseUserDirectoryRequest{})
		defer IPC__database_query_response_deinit(directory)
		users, usersOK := directory.result.(common.DatabaseUserDirectoryResult)
		assert(directory.success && usersOK, "expected the directory")
		flags := strings.builder_make(context.temp_allocator)
		for user in users.users {
			fmt.sbprintf(&flags, "%s:%v:%v ", user.nickname, user.isAdmin, user.isBanned)
		}
		listed := strings.to_string(flags)
		assert(
			listed == "act-admin:true:false act-bob:false:false act-carol:false:true ",
			fmt.tprintf("expected the directory to show roles and bans, got %q", listed),
		)
		unbanned := databaseAdminTestExpect(
			conn,
			{action = .Ban, actorUserId = admin, targetUserId = carol, reason = "ignored"},
			.Applied,
			"the unban",
		)
		assert(unbanned.changed && !unbanned.user.isBanned, "expected carol unbanned")
		cleared := databaseAdminTestValue(
			conn,
			fmt.tprintf(
				"SELECT (banned_at IS NULL)::text || '|' || ban_reason FROM users WHERE id = %d",
				carol,
			),
		)
		assert(cleared == "true|", fmt.tprintf("expected no ban and no reason, got %q", cleared))
		again := databaseAdminTestExpect(
			conn,
			{action = .Ban, actorUserId = admin, targetUserId = carol},
			.Applied,
			"a second unban",
		)
		assert(!again.changed, "expected a second unban to change nothing")
	}

	// Renames: a taken name is refused; a rename locks; an empty name only changes the lock.
	databaseAdminTestExpect(
		conn,
		{
			action = .Rename,
			actorUserId = admin,
			targetUserId = bob,
			nickname = "act-carol",
			locked = true,
		},
		.NicknameTaken,
		"a rename to a taken name",
	)
	{
		renamed := databaseAdminTestExpect(
			conn,
			{
				action = .Rename,
				actorUserId = admin,
				targetUserId = bob,
				nickname = "act-robert",
				locked = true,
			},
			.Applied,
			"the rename",
		)
		assert(
			renamed.changed &&
			renamed.previousNickname == "act-bob" &&
			renamed.user.nickname == "act-robert" &&
			renamed.nicknameLocked,
			fmt.tprintf("expected bob renamed and locked, got %v", renamed),
		)
		unlocked := databaseAdminTestExpect(
			conn,
			{action = .Rename, actorUserId = admin, targetUserId = bob, locked = false},
			.Applied,
			"the unlock",
		)
		assert(
			unlocked.changed &&
			unlocked.user.nickname == "act-robert" &&
			unlocked.previousNickname == "act-robert" &&
			!unlocked.nicknameLocked,
			fmt.tprintf("expected only the lock to change, got %v", unlocked),
		)
		same := databaseAdminTestExpect(
			conn,
			{action = .Rename, actorUserId = admin, targetUserId = bob, nickname = "act-robert"},
			.Applied,
			"a rename to the same name",
		)
		assert(!same.changed, "expected a rename to the same name and lock to change nothing")
		self := databaseAdminTestExpect(
			conn,
			{action = .Rename, actorUserId = admin, targetUserId = admin, nickname = "act-boss"},
			.Applied,
			"renaming yourself",
		)
		assert(
			self.changed && self.user.nickname == "act-boss",
			"expected an admin to rename itself",
		)
	}
}

@(test)
testRoomTypeStatementsAgainstPostgreSQL :: proc(t: ^testing.T) {
	_ = t
	if os.get_env(DATABASE_SQL_TEST_ENV, context.temp_allocator) != "1" {
		return
	}
	conn := databaseAdminTestOpen("room_types")
	defer databaseAdminTestClose(conn)

	member := databaseAdminTestUser(conn, "type-member")
	created := databaseExecuteRequest(
		conn,
		common.DatabaseCreateRoomRequest {
			creatorUserId = member,
			name = "type-voice",
			description = "talk",
			roomType = .Voice,
			access = .Public,
			historyVisibility = .Full,
			creatorJoins = true,
		},
	)
	defer IPC__database_query_response_deinit(created)
	mutation, mutationOK := created.result.(common.DatabaseRoomMutationResult)
	assert(
		created.success && mutationOK && mutation.room.roomType == .Voice,
		fmt.tprintf("expected a voice room, got %v", created),
	)
	roomID := mutation.room.id

	post :: proc(conn: pg.Conn, roomID, senderID: int) -> common.DatabasePostRoomChatMessageResult {
		response := databaseExecuteRequest(
			conn,
			common.DatabasePostRoomChatMessageRequest {
				roomId = roomID,
				senderId = senderID,
				content = "hello",
			},
		)
		result, ok := response.result.(common.DatabasePostRoomChatMessageResult)
		assert(response.success && ok, fmt.tprintf("expected the post to run: %v", response))
		posted := common.DatabasePostRoomChatMessageResult {
			isMember     = result.isMember,
			chatDisabled = result.chatDisabled,
		}
		posted.storedMessage.id = result.storedMessage.id
		IPC__database_query_response_deinit(response)
		return posted
	}
	// A voice-only room takes no chat, and stores nothing.
	refused := post(conn, roomID, member)
	assert(
		refused.isMember && refused.chatDisabled && refused.storedMessage.id == 0,
		fmt.tprintf("expected chat refused in a voice room, got %v", refused),
	)
	count := databaseAdminTestValue(conn, "SELECT count(*)::text FROM chat_messages")
	assert(count == "0", fmt.tprintf("expected nothing stored, got %q", count))

	// The member list carries the room's type, and says when the room does not exist.
	{
		members := databaseExecuteRequest(
			conn,
			common.DatabaseRoomMemberListRequest{roomId = roomID},
		)
		defer IPC__database_query_response_deinit(members)
		list, listOK := members.result.(common.DatabaseRoomMemberListResult)
		assert(
			members.success &&
			listOK &&
			list.roomFound &&
			list.roomType == .Voice &&
			len(list.userIDs) == 1 &&
			list.userIDs[0] == member,
			fmt.tprintf("expected the voice room with its member, got %v", members),
		)
		missing := databaseExecuteRequest(
			conn,
			common.DatabaseRoomMemberListRequest{roomId = roomID + 100},
		)
		defer IPC__database_query_response_deinit(missing)
		none, noneOK := missing.result.(common.DatabaseRoomMemberListResult)
		assert(missing.success && noneOK && !none.roomFound, "expected an unknown room")
		databaseDefaultRoomTestExec(
			conn,
			"add an empty room",
			"INSERT INTO rooms (name) VALUES ('type-empty')",
		)
		emptyID, _ := databaseParseTestInt(
			databaseAdminTestValue(conn, "SELECT id::text FROM rooms WHERE name = 'type-empty'"),
		)
		empty := databaseExecuteRequest(
			conn,
			common.DatabaseRoomMemberListRequest{roomId = emptyID},
		)
		defer IPC__database_query_response_deinit(empty)
		emptyList, emptyOK := empty.result.(common.DatabaseRoomMemberListResult)
		assert(
			empty.success &&
			emptyOK &&
			emptyList.roomFound &&
			emptyList.roomType == .ChatAndVoice &&
			len(emptyList.userIDs) == 0,
			fmt.tprintf("expected an empty room of both kinds, got %v", empty),
		)
	}

	// Edited to text only, the room takes chat and lists with its type.
	{
		edited := databaseExecuteRequest(
			conn,
			common.DatabaseEditRoomRequest {
				roomId = roomID,
				name = "type-text",
				description = "",
				roomType = .Chat,
				access = .Public,
			},
		)
		defer IPC__database_query_response_deinit(edited)
		editMutation, editOK := edited.result.(common.DatabaseRoomMutationResult)
		assert(
			edited.success && editOK && editMutation.changed && editMutation.room.roomType == .Chat,
			fmt.tprintf("expected the room made text-only, got %v", edited),
		)
	}
	accepted := post(conn, roomID, member)
	assert(
		accepted.isMember && !accepted.chatDisabled && accepted.storedMessage.id > 0,
		fmt.tprintf("expected chat in a text room, got %v", accepted),
	)
	{
		rooms := databaseExecuteRequest(conn, common.DatabaseRoomListRequest{userId = member})
		defer IPC__database_query_response_deinit(rooms)
		list, listOK := rooms.result.(common.DatabaseRoomListResult)
		assert(
			rooms.success && listOK && len(list.rooms) == 1 && list.rooms[0].roomType == .Chat,
			fmt.tprintf("expected the room listed as text-only, got %v", rooms),
		)
	}

	// The column takes only the supported types.
	for value in ([]int{0, 4}) {
		databaseDefaultRoomTestExec(
			conn,
			"probe the room type check",
			fmt.tprintf(
				"DO $$ BEGIN UPDATE rooms SET room_type = %d WHERE id = %d; " +
				"RAISE EXCEPTION 'room type %d accepted'; " +
				"EXCEPTION WHEN check_violation THEN NULL; END $$",
				value,
				roomID,
				value,
			),
		)
	}
}

@(test)
testAdminMigrationUpgradesVersion2AgainstPostgreSQL :: proc(t: ^testing.T) {
	_ = t
	if os.get_env(DATABASE_SQL_TEST_ENV, context.temp_allocator) != "1" {
		return
	}
	conn, schema := databaseMigrationTestOpen("admin_v2")
	defer databaseMigrationTestClose(conn, schema)

	// A database a version 2 server migrated and used.
	databaseMigrationTestMigrate(conn, DATABASE_MIGRATIONS[:2])
	assert(
		databaseMigrationTestRecorded(conn) == "1:baseline,2:read markers",
		"expected version 2 recorded",
	)
	databaseDefaultRoomTestExec(conn, "fill version 2 schema", DATABASE_MIGRATION_TEST_RC1_ROWS_SQL)
	before := databaseMigrationTestValue(conn, DATABASE_MIGRATION_TEST_FINGERPRINT_SQL)
	markersBefore := databaseMigrationTestValue(conn, DATABASE_MIGRATION_TEST_MARKERS_SQL)

	outcome := databaseMigrationTestMigrate(conn, DATABASE_MIGRATIONS[:3])
	assert(
		outcome == DatabaseMigrationOutcome{previousVersion = 2, version = 3},
		fmt.tprintf("expected only migration 3 to run, got %v", outcome),
	)
	assert(
		databaseMigrationTestRecorded(conn) == "1:baseline,2:read markers,3:admin",
		"expected version 3 recorded",
	)
	// Version 3 validates as version 3; migration 4 is tested in database_room_access_test.odin.
	{
		query := databaseSchemaValidationQuery(DATABASE_MIGRATIONS[:3])
		defer delete(query)
		validationErr := databaseSchemaValidationError(conn, query)
		defer delete(validationErr)
		assert(
			len(validationErr) == 0,
			fmt.tprintf("expected version 3 to validate, got %q", validationErr),
		)
	}
	after := databaseMigrationTestValue(conn, DATABASE_MIGRATION_TEST_FINGERPRINT_SQL)
	assert(
		after == before,
		fmt.tprintf("expected every row intact:\nbefore %q\nafter  %q", before, after),
	)
	markersAfter := databaseMigrationTestValue(conn, DATABASE_MIGRATION_TEST_MARKERS_SQL)
	assert(markersAfter == markersBefore, "expected the read markers intact")

	// Existing accounts are unlocked and unbanned; existing rooms are text and voice.
	users := databaseMigrationTestValue(
		conn,
		"SELECT string_agg(nickname || ':' || nickname_locked || ':' || " +
		"(banned_at IS NULL) || ':' || ban_reason, ',' ORDER BY id) FROM users",
	)
	assert(
		users == "mig-alice:false:true:,mig-bob:false:true:,mig-carol:false:true:",
		fmt.tprintf("expected the accounts unlocked and unbanned, got %q", users),
	)
	rooms := databaseMigrationTestValue(
		conn,
		"SELECT string_agg(name || ':' || room_type, ',' ORDER BY id) FROM rooms",
	)
	assert(
		rooms == "general:3,lounge:3",
		fmt.tprintf("expected existing rooms to keep text and voice, got %q", rooms),
	)
	// New rows get the defaults, and the check refuses an unsupported type.
	defaults := databaseMigrationTestValue(
		conn,
		"WITH r AS (INSERT INTO rooms (name) VALUES ('mig-new') RETURNING room_type), " +
		"u AS (INSERT INTO users (nickname) VALUES ('mig-new-user') " +
		"RETURNING nickname_locked, banned_at, ban_reason) " +
		"SELECT (SELECT room_type FROM r) || ':' || (SELECT nickname_locked FROM u) || ':' || " +
		"((SELECT banned_at FROM u) IS NULL) || ':' || (SELECT ban_reason FROM u)",
	)
	assert(defaults == "3:false:true:", fmt.tprintf("expected the defaults, got %q", defaults))
	databaseDefaultRoomTestExec(
		conn,
		"probe the room type check",
		"DO $$ BEGIN INSERT INTO rooms (name, room_type) VALUES ('mig-forum', 4); " +
		"RAISE EXCEPTION 'forum accepted'; " +
		"EXCEPTION WHEN check_violation THEN NULL; END $$",
	)
}

@(test)
testAdminMigrationKeepsItsShape :: proc(t: ^testing.T) {
	_ = t
	migration := DATABASE_MIGRATIONS[2]
	assert(
		migration.version == 3 && migration.name == "admin",
		fmt.tprintf("expected migration 3 to be admin, got %v", migration),
	)
	for required in ([]string {
			"ADD COLUMN nickname_locked BOOLEAN NOT NULL DEFAULT false",
			"ADD COLUMN banned_at TIMESTAMPTZ NULL",
			"ADD COLUMN ban_reason VARCHAR(256) NOT NULL DEFAULT ''",
			"ADD COLUMN room_type SMALLINT NOT NULL DEFAULT 3",
			"CHECK (room_type IN (1, 2, 3))",
		}) {
		assert(
			strings.contains(migration.sql, required),
			fmt.tprintf("expected migration 3 to contain %q", required),
		)
	}
	assert(!strings.contains(migration.sql, "DROP "), "expected migration 3 to drop nothing")
	// The default is ChatAndVoice and the check allows exactly the supported types.
	assert(
		int(common.RoomType.ChatAndVoice) == 3 &&
		int(common.RoomType.Chat) == 1 &&
		int(common.RoomType.Voice) == 2,
		"expected the column's numbers to match common.RoomType",
	)
	assert(
		strings.contains(DATABASE_SCHEMA_VALIDATION_SQL, "rooms_room_type_check") &&
		strings.contains(DATABASE_SCHEMA_VALIDATION_SQL, "users nickname_locked"),
		"expected schema validation to require migration 3's columns",
	)
}
