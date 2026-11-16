package server

import "../common"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "shared:pg"

// Runs the protocol 15 statements against a real PostgreSQL when HAYCHAT_DATABASE_SQL_TEST=1
// (dev/live-proof.sh --all and --sql): who may add, remove, leave and list members in each
// access mode, creating a room without joining it, room lists, From join history, mode
// changes, auto-join of new accounts, and migration 4 from a version 3 database. Like the admin
// tests, each runs inside one transaction in a schema of its own that is rolled back. Because
// the whole test is one transaction, CURRENT_TIMESTAMP never moves: the history test sets
// joined_at and created_at by hand.

@(private = "file")
databaseRoomAccessTestCreate :: proc(
	conn: pg.Conn,
	creatorID: int,
	name: string,
	access: common.RoomAccess,
	history: common.RoomHistoryVisibility,
	creatorJoins: bool,
) -> (
	roomID: int,
	isMember: bool,
	stored: common.RoomSummary,
) {
	response := databaseExecuteRequest(
		conn,
		common.DatabaseCreateRoomRequest {
			creatorUserId = creatorID,
			name = name,
			description = "",
			roomType = .ChatAndVoice,
			access = access,
			historyVisibility = history,
			creatorJoins = creatorJoins,
		},
	)
	defer IPC__database_query_response_deinit(response)
	mutation, ok := response.result.(common.DatabaseRoomMutationResult)
	assert(
		response.success && ok && mutation.changed,
		fmt.tprintf("expected room %s created: %v", name, response),
	)
	stored = mutation.room
	stored.name = ""
	stored.description = ""
	return mutation.room.id, mutation.isMember, stored
}

// Runs one member statement; the member list is copied to the temp allocator.
@(private = "file")
databaseRoomAccessTestRun :: proc(
	conn: pg.Conn,
	action: common.RoomMemberAction,
	actorID, roomID: int,
	targetID := 0,
) -> (
	result: common.DatabaseRoomMemberActionResult,
) {
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
	got, ok := response.result.(common.DatabaseRoomMemberActionResult)
	assert(
		response.success && ok,
		fmt.tprintf("expected the %v statement to run: %s", action, response.message),
	)
	result = got
	result.memberUserIDs = make([dynamic]int, context.temp_allocator)
	append(&result.memberUserIDs, ..got.memberUserIDs[:])
	return
}

@(private = "file")
databaseRoomAccessTestExpect :: proc(
	conn: pg.Conn,
	action: common.RoomMemberAction,
	actorID, roomID: int,
	targetID: int,
	outcome: common.DatabaseRoomMemberOutcome,
	changed: bool,
	label: string,
) -> common.DatabaseRoomMemberActionResult {
	result := databaseRoomAccessTestRun(conn, action, actorID, roomID, targetID)
	assert(
		result.outcome == outcome && result.changed == changed,
		fmt.tprintf("expected %s to end %v (changed %v), got %v", label, outcome, changed, result),
	)
	return result
}

@(private = "file")
databaseRoomAccessTestMembers :: proc(conn: pg.Conn, roomID: int) -> string {
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
databaseRoomAccessTestIDs :: proc(ids: ..int) -> string {
	builder := strings.builder_make(context.temp_allocator)
	for id, index in ids {
		if index > 0 {
			strings.write_byte(&builder, ',')
		}
		fmt.sbprintf(&builder, "%d", id)
	}
	return strings.to_string(builder)
}

@(private = "file")
databaseRoomAccessTestListed :: proc(conn: pg.Conn, userID: int) -> string {
	response := databaseExecuteRequest(conn, common.DatabaseRoomListRequest{userId = userID})
	defer IPC__database_query_response_deinit(response)
	list, ok := response.result.(common.DatabaseRoomListResult)
	assert(response.success && ok, fmt.tprintf("expected the room list to run: %v", response))
	builder := strings.builder_make(context.temp_allocator)
	for room, index in list.rooms {
		if index > 0 {
			strings.write_byte(&builder, ',')
		}
		fmt.sbprintf(&builder, "%s:%d:%d", room.name, int(room.access), int(room.historyVisibility))
	}
	return strings.to_string(builder)
}

@(test)
testRoomAccessModeRulesAgainstPostgreSQL :: proc(t: ^testing.T) {
	_ = t
	if os.get_env(DATABASE_SQL_TEST_ENV, context.temp_allocator) != "1" {
		return
	}
	conn := databaseAdminTestOpen("room_access")
	defer databaseAdminTestClose(conn)

	admin := databaseAdminTestUser(conn, "acc-admin")
	databaseAdminTestGrant(conn, admin)
	bob := databaseAdminTestUser(conn, "acc-bob")
	carol := databaseAdminTestUser(conn, "acc-carol")
	dave := databaseAdminTestUser(conn, "acc-dave")

	// A Public room includes every account and always reads full history; an invite room only
	// its creator, and none when the creator does not join.
	public, publicMember, publicRoom := databaseRoomAccessTestCreate(
		conn,
		admin,
		"acc-public",
		.Public,
		.FromJoin,
		true,
	)
	assert(
		publicMember && publicRoom.access == .Public && publicRoom.historyVisibility == .Full,
		fmt.tprintf("expected a Public room with full history, got %v", publicRoom),
	)
	assert(
		databaseRoomAccessTestMembers(conn, public) ==
		databaseRoomAccessTestIDs(admin, bob, carol, dave),
		"expected the Public room to include every account",
	)
	stored := databaseAdminTestValue(
		conn,
		fmt.tprintf("SELECT access || ':' || history_visibility FROM rooms WHERE id = %d", public),
	)
	assert(stored == "1:2", fmt.tprintf("expected Public stored with Full history, got %q", stored))
	memberRoom, memberJoined, memberSummary := databaseRoomAccessTestCreate(
		conn,
		admin,
		"acc-member",
		.MemberInvite,
		.FromJoin,
		true,
	)
	assert(
		memberJoined &&
		memberSummary.access == .MemberInvite &&
		memberSummary.historyVisibility == .FromJoin,
		fmt.tprintf("expected a Member invite room the admin joined, got %v", memberSummary),
	)
	assert(
		databaseRoomAccessTestMembers(conn, memberRoom) == databaseRoomAccessTestIDs(admin),
		"expected only the creator in the Member invite room",
	)
	adminRoom, adminJoined, _ := databaseRoomAccessTestCreate(
		conn,
		admin,
		"acc-admin-only",
		.AdminInvite,
		.Full,
		false,
	)
	assert(!adminJoined, "expected the creator not in a room created without joining")
	assert(
		databaseRoomAccessTestMembers(conn, adminRoom) == "",
		"expected nobody in the room created without joining",
	)

	// Public: nobody adds, nobody leaves; admins still remove.
	databaseRoomAccessTestExpect(conn, .Add, admin, public, bob, .PublicRoom, false, "public add")
	databaseRoomAccessTestExpect(conn, .Leave, bob, public, 0, .PublicRoom, false, "public leave")
	databaseRoomAccessTestExpect(
		conn,
		.Remove,
		bob,
		public,
		carol,
		.AdminRequired,
		false,
		"a member removing in a public room",
	)

	// Member invite: the admin and then any member add; a non-member cannot.
	databaseRoomAccessTestExpect(conn, .Add, admin, memberRoom, bob, .Applied, true, "admin add")
	added := databaseRoomAccessTestExpect(
		conn,
		.Add,
		bob,
		memberRoom,
		carol,
		.Applied,
		true,
		"a member inviting",
	)
	assert(
		databaseRoomAccessTestIDs(..added.memberUserIDs[:]) ==
			databaseRoomAccessTestIDs(admin, bob, carol) &&
		added.access == .MemberInvite,
		fmt.tprintf("expected the members after the invite, got %v", added),
	)
	databaseRoomAccessTestExpect(
		conn,
		.Add,
		bob,
		memberRoom,
		carol,
		.Applied,
		false,
		"inviting a member again",
	)
	databaseRoomAccessTestExpect(
		conn,
		.Add,
		dave,
		memberRoom,
		dave,
		.NotMember,
		false,
		"a non-member adding themselves",
	)
	databaseRoomAccessTestExpect(
		conn,
		.Add,
		bob,
		memberRoom,
		999_999,
		.UnknownUser,
		false,
		"inviting an unknown account",
	)
	// Members cannot remove each other (Q8); admins can.
	databaseRoomAccessTestExpect(
		conn,
		.Remove,
		bob,
		memberRoom,
		carol,
		.AdminRequired,
		false,
		"a member removing another",
	)
	removed := databaseRoomAccessTestExpect(
		conn,
		.Remove,
		admin,
		memberRoom,
		carol,
		.Applied,
		true,
		"an admin removing",
	)
	assert(
		databaseRoomAccessTestIDs(..removed.memberUserIDs[:]) ==
		databaseRoomAccessTestIDs(admin, bob),
		fmt.tprintf("expected carol gone from the member list, got %v", removed),
	)
	databaseRoomAccessTestExpect(
		conn,
		.Remove,
		admin,
		memberRoom,
		carol,
		.Applied,
		false,
		"removing a non-member",
	)

	// Admin invite: only admins add, even an admin who is not a member; members leave.
	databaseRoomAccessTestExpect(
		conn,
		.Add,
		admin,
		adminRoom,
		bob,
		.Applied,
		true,
		"a non-member admin adding",
	)
	databaseRoomAccessTestExpect(
		conn,
		.Add,
		bob,
		adminRoom,
		carol,
		.AdminRequired,
		false,
		"a member adding to an admin invite room",
	)
	databaseRoomAccessTestExpect(
		conn,
		.Leave,
		carol,
		adminRoom,
		0,
		.NotMember,
		false,
		"a non-member leaving",
	)
	databaseRoomAccessTestExpect(conn, .Leave, bob, adminRoom, 0, .Applied, true, "bob leaving")
	assert(databaseRoomAccessTestMembers(conn, adminRoom) == "", "expected bob gone")

	// Fetching members: members and admins, members or not.
	databaseRoomAccessTestExpect(
		conn,
		.Fetch,
		dave,
		memberRoom,
		0,
		.NotMember,
		false,
		"a non-member fetching members",
	)
	fetched := databaseRoomAccessTestExpect(
		conn,
		.Fetch,
		bob,
		memberRoom,
		0,
		.Applied,
		false,
		"a member fetching members",
	)
	assert(
		databaseRoomAccessTestIDs(..fetched.memberUserIDs[:]) ==
		databaseRoomAccessTestIDs(admin, bob),
		fmt.tprintf("expected admin and bob, got %v", fetched),
	)
	databaseRoomAccessTestExpect(
		conn,
		.Fetch,
		admin,
		adminRoom,
		0,
		.Applied,
		false,
		"a non-member admin fetching",
	)

	// A missing room is Room not found to admins and Not a room member to anyone else.
	databaseRoomAccessTestExpect(
		conn,
		.Add,
		admin,
		999_999,
		bob,
		.UnknownRoom,
		false,
		"an admin adding to a missing room",
	)
	databaseRoomAccessTestExpect(
		conn,
		.Add,
		bob,
		999_999,
		carol,
		.NotMember,
		false,
		"a member adding to a missing room",
	)
	databaseRoomAccessTestExpect(
		conn,
		.Remove,
		admin,
		999_999,
		bob,
		.UnknownRoom,
		false,
		"removing from a missing room",
	)

	// Non-public rooms appear only in their members' room lists.
	listedDave := databaseRoomAccessTestListed(conn, dave)
	assert(
		listedDave == "acc-public:1:2",
		fmt.tprintf("expected dave in public, got %q", listedDave),
	)
	listedBob := databaseRoomAccessTestListed(conn, bob)
	assert(
		listedBob == "acc-member:2:1,acc-public:1:2",
		fmt.tprintf("expected bob's rooms with their modes, got %q", listedBob),
	)

	// The admin list shows every room, joined or not.
	{
		response := databaseExecuteRequest(
			conn,
			common.DatabaseAdminRoomListRequest{actorUserId = admin},
		)
		defer IPC__database_query_response_deinit(response)
		list, ok := response.result.(common.DatabaseAdminRoomListResult)
		assert(
			response.success && ok && list.isAdmin,
			fmt.tprintf("expected the list: %v", response),
		)
		builder := strings.builder_make(context.temp_allocator)
		for entry in list.rooms {
			fmt.sbprintf(
				&builder,
				"%s:%d:%v:%d;",
				entry.room.name,
				int(entry.room.access),
				entry.isMember,
				entry.memberCount,
			)
		}
		got := strings.to_string(builder)
		assert(
			got == "acc-admin-only:3:false:0;acc-member:2:true:2;acc-public:1:true:4;",
			fmt.tprintf("expected every room, got %q", got),
		)
		refused := databaseExecuteRequest(
			conn,
			common.DatabaseAdminRoomListRequest{actorUserId = bob},
		)
		defer IPC__database_query_response_deinit(refused)
		none, noneOK := refused.result.(common.DatabaseAdminRoomListResult)
		assert(
			refused.success && noneOK && !none.isAdmin && len(none.rooms) == 0,
			fmt.tprintf("expected bob refused, got %v", refused),
		)
	}

	// Mode changes: switching to Public adds every account, switching back keeps them.
	{
		response := databaseExecuteRequest(
			conn,
			common.DatabaseEditRoomRequest {
				roomId = adminRoom,
				name = "acc-admin-only",
				roomType = .ChatAndVoice,
				access = .Public,
			},
		)
		defer IPC__database_query_response_deinit(response)
		mutation, ok := response.result.(common.DatabaseRoomMutationResult)
		assert(
			response.success &&
			ok &&
			mutation.changed &&
			mutation.room.access == .Public &&
			mutation.room.historyVisibility == .Full,
			fmt.tprintf("expected the room made Public, got %v", response),
		)
		assert(
			databaseRoomAccessTestIDs(..mutation.addedUserIDs[:]) ==
			databaseRoomAccessTestIDs(admin, bob, carol, dave),
			fmt.tprintf("expected every account added, got %v", mutation.addedUserIDs),
		)
	}
	{
		response := databaseExecuteRequest(
			conn,
			common.DatabaseEditRoomRequest {
				roomId = adminRoom,
				name = "acc-admin-only",
				roomType = .ChatAndVoice,
				access = .MemberInvite,
			},
		)
		defer IPC__database_query_response_deinit(response)
		mutation, ok := response.result.(common.DatabaseRoomMutationResult)
		assert(
			response.success &&
			ok &&
			mutation.room.access == .MemberInvite &&
			mutation.room.historyVisibility == .Full &&
			len(mutation.addedUserIDs) == 0,
			fmt.tprintf("expected the room back to Member invite, got %v", response),
		)
		assert(
			databaseRoomAccessTestMembers(conn, adminRoom) ==
			databaseRoomAccessTestIDs(admin, bob, carol, dave),
			"expected every member kept when leaving Public",
		)
	}

	// A new account joins only the Public rooms.
	{
		key := databaseIdentityTestKey()
		newcomer := databaseIdentityTestResolve(conn, "acc-newcomer", key)
		defer delete(newcomer.previousNickname)
		listed := databaseRoomAccessTestListed(conn, newcomer.userId)
		assert(
			listed == "acc-public:1:2",
			fmt.tprintf("expected the newcomer only in the Public room, got %q", listed),
		)
	}

	// The columns take only the defined values.
	for probe in ([]string{"access = 0", "access = 4", "history_visibility = 3"}) {
		databaseDefaultRoomTestExec(
			conn,
			"probe the access checks",
			fmt.tprintf(
				"DO $$ BEGIN UPDATE rooms SET %s WHERE id = %d; " +
				"RAISE EXCEPTION '%s accepted'; " +
				"EXCEPTION WHEN check_violation THEN NULL; END $$",
				probe,
				public,
				probe,
			),
		)
	}
}

// History pages for a From join room start at joined_at, Full rooms show everything, and an
// account removed and added again starts over.
@(test)
testRoomAccessFromJoinHistoryAgainstPostgreSQL :: proc(t: ^testing.T) {
	_ = t
	if os.get_env(DATABASE_SQL_TEST_ENV, context.temp_allocator) != "1" {
		return
	}
	conn := databaseAdminTestOpen("room_history")
	defer databaseAdminTestClose(conn)

	admin := databaseAdminTestUser(conn, "his-admin")
	databaseAdminTestGrant(conn, admin)
	bob := databaseAdminTestUser(conn, "his-bob")
	fromJoin, _, _ := databaseRoomAccessTestCreate(
		conn,
		admin,
		"his-from-join",
		.MemberInvite,
		.FromJoin,
		true,
	)
	full, _, _ := databaseRoomAccessTestCreate(conn, admin, "his-full", .MemberInvite, .Full, true)

	// Three messages in each room, ten, five and zero minutes ago; the admin joined before them
	// and bob is added between the first and the second.
	for roomID in ([]int{fromJoin, full}) {
		databaseDefaultRoomTestExec(
			conn,
			"fill history",
			fmt.tprintf(
				"UPDATE room_members SET joined_at = now() - interval '1 hour' " +
				"WHERE room_id = %d; " +
				"INSERT INTO chat_messages (room_id, sender_user_id, content, created_at, " +
				"client_message_id, signature) VALUES " +
				"(%d, %d, 'before', now() - interval '10 minutes', %s), " +
				"(%d, %d, 'after', now() - interval '5 minutes', %s), " +
				"(%d, %d, 'latest', now(), %s)",
				roomID,
				roomID,
				admin,
				DATABASE_TEST_PLAIN_COLUMNS_SQL,
				roomID,
				admin,
				DATABASE_TEST_PLAIN_COLUMNS_SQL,
				roomID,
				admin,
				DATABASE_TEST_PLAIN_COLUMNS_SQL,
			),
		)
		databaseRoomAccessTestExpect(conn, .Add, admin, roomID, bob, .Applied, true, "add bob")
		databaseDefaultRoomTestExec(
			conn,
			"bob joined seven minutes ago",
			fmt.tprintf(
				"UPDATE room_members SET joined_at = now() - interval '7 minutes' " +
				"WHERE room_id = %d AND user_id = %d",
				roomID,
				bob,
			),
		)
	}

	history :: proc(conn: pg.Conn, roomID, userID: int, before := 0, limit := 50) -> string {
		response := databaseExecuteRequest(
			conn,
			common.DatabaseRoomHistoryRequest {
				roomId = roomID,
				userId = userID,
				beforeMessageID = before,
				limit = limit,
			},
		)
		defer IPC__database_query_response_deinit(response)
		page, ok := response.result.(common.DatabaseRoomHistoryResult)
		assert(response.success && ok, fmt.tprintf("expected history to run: %v", response))
		if !page.isMember {
			return "not a member"
		}
		builder := strings.builder_make(context.temp_allocator)
		for message, index in page.messages {
			if index > 0 {
				strings.write_byte(&builder, ',')
			}
			strings.write_string(&builder, message.content)
		}
		fmt.sbprintf(&builder, " older=%v", page.hasOlder)
		return strings.to_string(builder)
	}

	got := history(conn, fromJoin, bob)
	assert(
		got == "after,latest older=false",
		fmt.tprintf("expected From join for bob, got %q", got),
	)
	got = history(conn, fromJoin, bob, limit = 1)
	assert(got == "latest older=true", fmt.tprintf("expected one page with more, got %q", got))
	newest, _ := databaseParseTestInt(
		databaseAdminTestValue(
			conn,
			fmt.tprintf("SELECT max(id)::text FROM chat_messages WHERE room_id = %d", fromJoin),
		),
	)
	got = history(conn, fromJoin, bob, before = newest, limit = 1)
	assert(
		got == "after older=false",
		fmt.tprintf("expected the page to stop at join, got %q", got),
	)
	got = history(conn, fromJoin, admin)
	assert(
		got == "before,after,latest older=false",
		fmt.tprintf("expected the admin's whole history, got %q", got),
	)
	got = history(conn, full, bob)
	assert(
		got == "before,after,latest older=false",
		fmt.tprintf("expected Full history for bob, got %q", got),
	)

	// Removed and added again, bob counts from the second addition (now), and his read marker
	// is gone with the removal.
	databaseDefaultRoomTestExec(
		conn,
		"bob read the room",
		fmt.tprintf(
			"INSERT INTO room_read_markers (user_id, room_id, last_read_message_id) " +
			"VALUES (%d, %d, %d)",
			bob,
			fromJoin,
			newest,
		),
	)
	databaseRoomAccessTestExpect(conn, .Remove, admin, fromJoin, bob, .Applied, true, "remove")
	markers := databaseAdminTestValue(
		conn,
		fmt.tprintf("SELECT count(*)::text FROM room_read_markers WHERE user_id = %d", bob),
	)
	assert(markers == "0", fmt.tprintf("expected bob's marker removed, got %q", markers))
	got = history(conn, fromJoin, bob)
	assert(got == "not a member", fmt.tprintf("expected bob refused after removal, got %q", got))
	databaseRoomAccessTestExpect(conn, .Add, admin, fromJoin, bob, .Applied, true, "add again")
	got = history(conn, fromJoin, bob)
	assert(got == " older=false", fmt.tprintf("expected nothing before the re-add, got %q", got))

	// Made Public, the room shows bob everything.
	{
		response := databaseExecuteRequest(
			conn,
			common.DatabaseEditRoomRequest {
				roomId = fromJoin,
				name = "his-from-join",
				roomType = .ChatAndVoice,
				access = .Public,
			},
		)
		IPC__database_query_response_deinit(response)
	}
	got = history(conn, fromJoin, bob)
	assert(
		got == "before,after,latest older=false",
		fmt.tprintf("expected full history in a Public room, got %q", got),
	)
}

@(test)
testRoomAccessMigrationUpgradesVersion3AgainstPostgreSQL :: proc(t: ^testing.T) {
	_ = t
	if os.get_env(DATABASE_SQL_TEST_ENV, context.temp_allocator) != "1" {
		return
	}
	conn, schema := databaseMigrationTestOpen("room_access_v3")
	defer databaseMigrationTestClose(conn, schema)

	// A database a version 3 server migrated and used.
	databaseMigrationTestMigrate(conn, DATABASE_MIGRATIONS[:3])
	databaseDefaultRoomTestExec(conn, "fill version 3 schema", DATABASE_MIGRATION_TEST_RC1_ROWS_SQL)
	databaseDefaultRoomTestExec(conn, "a voice room", "UPDATE rooms SET room_type = 2 WHERE id = 2")
	before := databaseMigrationTestValue(conn, DATABASE_MIGRATION_TEST_FINGERPRINT_SQL)
	markersBefore := databaseMigrationTestValue(conn, DATABASE_MIGRATION_TEST_MARKERS_SQL)

	// Only as far as version 4; migration 5 is tested in database_encryption_keys_test.odin.
	outcome := databaseMigrationTestMigrate(conn, DATABASE_MIGRATIONS[:4])
	assert(
		outcome == DatabaseMigrationOutcome{previousVersion = 3, version = 4},
		fmt.tprintf("expected only migration 4 to run, got %v", outcome),
	)
	assert(
		databaseMigrationTestRecorded(conn) == "1:baseline,2:read markers,3:admin,4:room access",
		"expected version 4 recorded",
	)
	databaseMigrationTestValidationPassesFor(conn, DATABASE_MIGRATIONS[:4])
	after := databaseMigrationTestValue(conn, DATABASE_MIGRATION_TEST_FINGERPRINT_SQL)
	assert(
		after == before,
		fmt.tprintf("expected every row intact:\nbefore %q\nafter  %q", before, after),
	)
	markersAfter := databaseMigrationTestValue(conn, DATABASE_MIGRATION_TEST_MARKERS_SQL)
	assert(markersAfter == markersBefore, "expected the read markers intact")

	// Existing rooms become Public with full history and keep their type.
	rooms := databaseMigrationTestValue(
		conn,
		"SELECT string_agg(name || ':' || room_type || ':' || access || ':' || " +
		"history_visibility, ',' ORDER BY id) FROM rooms",
	)
	assert(
		rooms == "general:3:1:2,lounge:2:1:2",
		fmt.tprintf("expected existing rooms Public with full history, got %q", rooms),
	)
	defaults := databaseMigrationTestValue(
		conn,
		"WITH r AS (INSERT INTO rooms (name) VALUES ('mig-new') " +
		"RETURNING access, history_visibility) " +
		"SELECT access || ':' || history_visibility FROM r",
	)
	assert(defaults == "1:2", fmt.tprintf("expected the defaults, got %q", defaults))
}

@(test)
testRoomAccessMigrationKeepsItsShape :: proc(t: ^testing.T) {
	_ = t
	migration := DATABASE_MIGRATIONS[3]
	assert(
		migration.version == 4 && migration.name == "room access",
		fmt.tprintf("expected migration 4 to be room access, got %v", migration),
	)
	for required in ([]string {
			"ADD COLUMN access SMALLINT NOT NULL DEFAULT 1",
			"CHECK (access IN (1, 2, 3))",
			"ADD COLUMN history_visibility SMALLINT NOT NULL DEFAULT 2",
			"CHECK (history_visibility IN (1, 2))",
		}) {
		assert(
			strings.contains(migration.sql, required),
			fmt.tprintf("expected migration 4 to contain %q", required),
		)
	}
	assert(!strings.contains(migration.sql, "DROP "), "expected migration 4 to drop nothing")
	assert(
		int(common.RoomAccess.Public) == 1 && int(common.RoomHistoryVisibility.Full) == 2,
		"expected the defaults to be Public and Full",
	)
	assert(
		strings.contains(DATABASE_SCHEMA_VALIDATION_SQL, "rooms_access_check") &&
		strings.contains(DATABASE_SCHEMA_VALIDATION_SQL, "rooms history_visibility"),
		"expected schema validation to require migration 4's columns",
	)
}
