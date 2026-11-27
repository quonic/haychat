package server

import "../common"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "shared:pg"

// Runs the protocol 18 member log statements against a real PostgreSQL when
// HAYCHAT_DATABASE_SQL_TEST=1 (dev/live-proof.sh --all and --sql): creating an encrypted room
// without members, its Create entry, signed adds, removals, leaves, manager changes and access
// switches, the server's rules on top of the log's (an add needs both), keys that are not the
// accounts' own, entries that do not follow the head, the server's own unsigned removal, who may
// fetch the log, refused plaintext chat and protocol 15 member changes, edits that would change
// the encryption, a damaged stored log, a full room, and migration 7 from a version 6 database
// with rows. Each test runs in one transaction in a schema of its own that is rolled back, so
// the worker's transaction becomes a savepoint. The pure rules have tests without a database.

// One account with a real identity key, stored in users.public_key.
@(private = "file")
RoomLogTestAccount :: struct {
	userID:     int,
	privateKey: common.IdentityPrivateKeyBytes,
	publicKey:  common.IdentityPublicKeyBytes,
}

@(private = "file")
roomLogTestAccount :: proc(conn: pg.Conn, nickname: string) -> RoomLogTestAccount {
	privateKey, publicKey, ok := common.generateIdentityKeyPair()
	assert(ok, "expected test identity key generation to succeed")
	account := RoomLogTestAccount {
		userID     = databaseAdminTestUser(conn, nickname),
		privateKey = privateKey,
		publicKey  = publicKey,
	}
	keyHex := common.encodeBytesToHex(publicKey[:])
	defer delete(keyHex)
	databaseAdminTestValue(
		conn,
		fmt.tprintf(
			"UPDATE users SET public_key = decode('%s', 'hex') WHERE id = %d RETURNING id::text",
			keyHex,
			account.userID,
		),
	)
	return account
}

// The head the test expects, advanced after each stored entry.
@(private = "file")
RoomLogTestHead :: struct {
	roomID:  int,
	version: int,
	hash:    common.RoomLogHash,
}

@(private = "file")
RoomLogTestEntry :: struct {
	action:    common.RoomLogAction,
	actor:     RoomLogTestAccount,
	target:    RoomLogTestAccount,
	// A key to name for the target instead of its own.
	targetKey: Maybe(common.IdentityPublicKeyBytes),
	access:    common.RoomLogAccess,
	history:   common.RoomLogHistoryVisibility,
	joins:     bool,
	managers:  []RoomLogTestAccount,
	// Another version than the head's next.
	version:   int,
}

// Signs the next entry after head. The bytes are in the temp allocator.
@(private = "file")
roomLogTestSign :: proc(
	serverKey: common.IdentityPublicKeyBytes,
	head: RoomLogTestHead,
	spec: RoomLogTestEntry,
) -> []u8 {
	entry := common.RoomLogEntry {
		roomID      = head.roomID,
		version     = spec.version > 0 ? spec.version : head.version + 1,
		prevHash    = head.hash,
		action      = spec.action,
		actorUserID = spec.actor.userID,
		createdAt   = 1_731_600_000,
	}
	managers: [8]common.RoomLogManager
	switch spec.action {
	case .Create:
		entry.targetUserID = spec.actor.userID
		entry.targetIdentityKey = spec.actor.publicKey
		for manager, index in spec.managers {
			managers[index] = {manager.userID, manager.publicKey}
		}
		entry.settings = {
			access            = spec.access,
			historyVisibility = spec.history,
			creatorJoins      = spec.joins,
			managers          = managers[:len(spec.managers)],
		}
	case .SetAccess:
		entry.settings = {
			access            = spec.access,
			historyVisibility = spec.history,
		}
	case .Add, .Remove, .AddManager, .RemoveManager, .Leave:
		entry.targetUserID = spec.target.userID
		entry.targetIdentityKey = spec.target.publicKey
		if key, ok := spec.targetKey.?; ok {
			entry.targetIdentityKey = key
		}
	}
	assert(
		common.signRoomLogEntry(&entry, serverKey, spec.actor.privateKey) == .None,
		"expected the test entry to sign",
	)
	buffer: [common.ROOM_LOG_ENTRY_MAX_BYTES]u8
	n, err := common.encodeRoomLogEntry(entry, buffer[:])
	assert(err == .None, fmt.tprintf("expected the test entry to encode, got %v", err))
	data := make([]u8, n, context.temp_allocator)
	copy(data, buffer[:n])
	return data
}

@(private = "file")
roomLogTestAdvance :: proc(head: ^RoomLogTestHead, data: []u8) {
	head.version += 1
	head.hash = common.hashRoomLogEntry(data)
}

// Appends data as actorID; the result's arrays are copied to the temp allocator.
@(private = "file")
roomLogTestAppend :: proc(
	conn: pg.Conn,
	serverKey: common.IdentityPublicKeyBytes,
	actorID, roomID: int,
	data: []u8,
) -> (
	result: common.DatabaseAppendRoomLogResult,
) {
	entry := make([]u8, len(data))
	copy(entry, data)
	request := common.DatabaseAppendRoomLogRequest {
		actorUserId             = actorID,
		roomId                  = roomID,
		entry                   = entry,
		serverIdentityPublicKey = serverKey,
	}
	defer IPC__database_query_request_deinit(request)
	response := databaseExecuteRequest(conn, request)
	defer IPC__database_query_response_deinit(response)
	got, ok := response.result.(common.DatabaseAppendRoomLogResult)
	assert(response.success && ok, fmt.tprintf("expected the append to run: %s", response.message))
	result = got
	result.entry = nil
	result.memberUserIDs = make([dynamic]int, context.temp_allocator)
	append(&result.memberUserIDs, ..got.memberUserIDs[:])
	result.managerUserIDs = make([dynamic]int, context.temp_allocator)
	append(&result.managerUserIDs, ..got.managerUserIDs[:])
	return
}

// Appends and checks the outcome; an Applied entry advances head.
@(private = "file")
roomLogTestExpect :: proc(
	conn: pg.Conn,
	serverKey: common.IdentityPublicKeyBytes,
	head: ^RoomLogTestHead,
	actorID: int,
	data: []u8,
	outcome: common.RoomLogAppendOutcome,
	label: string,
) -> common.DatabaseAppendRoomLogResult {
	result := roomLogTestAppend(conn, serverKey, actorID, head.roomID, data)
	assert(
		result.outcome == outcome,
		fmt.tprintf("expected %s to end %v, got %v (%v)", label, outcome, result.outcome,
			result.logError),
	)
	if outcome == .Applied {
		roomLogTestAdvance(head, data)
		assert(result.version == head.version, fmt.tprintf("expected %s at the head", label))
	}
	return result
}

@(private = "file")
roomLogTestFetch :: proc(
	conn: pg.Conn,
	actorID, roomID: int,
	afterVersion := 0,
) -> (
	outcome: common.RoomLogAppendOutcome,
	count: int,
	headVersion: int,
) {
	response := databaseExecuteRequest(
		conn,
		common.DatabaseFetchRoomLogRequest {
			actorUserId = actorID,
			roomId = roomID,
			afterVersion = afterVersion,
		},
	)
	defer IPC__database_query_response_deinit(response)
	got, ok := response.result.(common.DatabaseFetchRoomLogResult)
	assert(response.success && ok, fmt.tprintf("expected the fetch to run: %s", response.message))
	return got.outcome, len(got.entries), got.headVersion
}

@(private = "file")
roomLogTestIDs :: proc(ids: []int) -> string {
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
roomLogTestMembers :: proc(conn: pg.Conn, roomID: int) -> string {
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
roomLogTestManagers :: proc(conn: pg.Conn, roomID: int) -> string {
	return databaseAdminTestValue(
		conn,
		fmt.tprintf(
			"SELECT COALESCE(string_agg(user_id::text, ',' ORDER BY user_id), '') " +
			"FROM room_log_managers WHERE room_id = %d",
			roomID,
		),
	)
}

@(private = "file")
roomLogTestCreateRoom :: proc(
	conn: pg.Conn,
	creatorID: int,
	name: string,
	access: common.RoomAccess,
) -> common.DatabaseRoomMutationResult {
	response := databaseExecuteRequest(
		conn,
		common.DatabaseCreateRoomRequest {
			creatorUserId = creatorID,
			name = name,
			roomType = .ChatAndVoice,
			access = access,
			historyVisibility = .FromJoin,
			creatorJoins = true,
			encrypted = true,
		},
	)
	defer IPC__database_query_response_deinit(response)
	mutation, ok := response.result.(common.DatabaseRoomMutationResult)
	assert(response.success && ok && mutation.changed, fmt.tprintf("expected %s created", name))
	result := mutation
	result.room.name = ""
	result.room.description = ""
	result.addedUserIDs = nil
	return result
}

@(private = "file")
roomLogTestMemberAction :: proc(
	conn: pg.Conn,
	serverKey: common.IdentityPublicKeyBytes,
	action: common.RoomMemberAction,
	actorID, roomID, targetID: int,
) -> (
	outcome: common.DatabaseRoomMemberOutcome,
	changed: bool,
	logVersion: int,
	logEntry: []u8,
) {
	response := databaseExecuteRequest(
		conn,
		common.DatabaseRoomMemberActionRequest {
			action = action,
			actorUserId = actorID,
			roomId = roomID,
			targetUserId = targetID,
			serverIdentityPublicKey = serverKey,
		},
	)
	defer IPC__database_query_response_deinit(response)
	got, ok := response.result.(common.DatabaseRoomMemberActionResult)
	assert(response.success && ok, fmt.tprintf("expected the %v statement to run", action))
	logEntry = make([]u8, len(got.logEntry), context.temp_allocator)
	copy(logEntry, got.logEntry)
	return got.outcome, got.changed, got.logVersion, logEntry
}

@(test)
testRoomLogAppendRulesAgainstPostgreSQL :: proc(t: ^testing.T) {
	_ = t
	if os.get_env(DATABASE_SQL_TEST_ENV, context.temp_allocator) != "1" {
		return
	}
	conn := databaseAdminTestOpen(t, "room_log")
	_, serverKey, serverKeyOK := common.generateIdentityKeyPair()
	assert(serverKeyOK, "expected a server key")

	alice := roomLogTestAccount(conn, "log-alice")
	databaseAdminTestGrant(conn, alice.userID)
	erin := roomLogTestAccount(conn, "log-erin")
	databaseAdminTestGrant(conn, erin.userID)
	bob := roomLogTestAccount(conn, "log-bob")
	carol := roomLogTestAccount(conn, "log-carol")
	dave := roomLogTestAccount(conn, "log-dave")
	keyless := RoomLogTestAccount {
		userID = databaseAdminTestUser(conn, "log-keyless"),
	}
	_, keyless.publicKey, _ = common.generateIdentityKeyPair()

	// An encrypted room starts with no members and version 0, whatever creatorJoins says.
	created := roomLogTestCreateRoom(conn, alice.userID, "log-admin", .AdminInvite)
	roomID := created.room.id
	assert(
		!created.isMember && created.room.encrypted && created.room.logVersion == 0,
		fmt.tprintf("expected an empty encrypted room, got %v", created),
	)
	assert(roomLogTestMembers(conn, roomID) == "", "expected nobody in the room yet")
	outcome, count, headVersion := roomLogTestFetch(conn, alice.userID, roomID)
	assert(
		outcome == .Applied && count == 0 && headVersion == 0,
		fmt.tprintf("expected an empty log for the admin, got %v %d %d", outcome, count,
			headVersion),
	)
	outcome, _, _ = roomLogTestFetch(conn, carol.userID, roomID)
	assert(outcome == .NotMember, "expected carol, an outsider, unable to fetch the log")

	head := RoomLogTestHead {
		roomID = roomID,
	}
	managers := []RoomLogTestAccount{alice}
	createSpec := RoomLogTestEntry {
		action   = .Create,
		actor    = alice,
		access   = .AdminInvite,
		history  = .FromJoin,
		joins    = true,
		managers = managers,
	}

	// Only the creator, an admin, signs Create, with the room's own settings.
	bobManagers := []RoomLogTestAccount{bob}
	bobCreate := createSpec
	bobCreate.actor = bob
	bobCreate.managers = bobManagers
	roomLogTestExpect(conn, serverKey, &head, bob.userID,
		roomLogTestSign(serverKey, head, bobCreate), .NotAuthorized, "bob's Create")
	wrongAccess := createSpec
	wrongAccess.access = .MemberInvite
	roomLogTestExpect(conn, serverKey, &head, alice.userID,
		roomLogTestSign(serverKey, head, wrongAccess), .Invalid, "a Create with other settings")
	createData := roomLogTestSign(serverKey, head, createSpec)
	// Sent by someone else than its actor.
	roomLogTestExpect(conn, serverKey, &head, erin.userID, createData, .NotAuthorized,
		"alice's Create sent by erin")
	createResult := roomLogTestExpect(conn, serverKey, &head, alice.userID, createData, .Applied,
		"alice's Create")
	assert(
		createResult.action == .Create &&
		createResult.targetUserId == alice.userID &&
		createResult.membershipChanged &&
		roomLogTestIDs(createResult.memberUserIDs[:]) == roomLogTestIDs({alice.userID}) &&
		roomLogTestIDs(createResult.managerUserIDs[:]) == roomLogTestIDs({alice.userID}),
		fmt.tprintf("expected alice the first member and manager, got %v", createResult),
	)
	assert(
		roomLogTestMembers(conn, roomID) == roomLogTestIDs({alice.userID}) &&
		roomLogTestManagers(conn, roomID) == roomLogTestIDs({alice.userID}) &&
		databaseAdminTestValue(conn, fmt.tprintf("SELECT log_version::text FROM rooms " +
			"WHERE id = %d", roomID)) == "1",
		"expected the Create applied to room_members, room_log_managers and log_version",
	)
	// The same entry again does not follow the head.
	again := roomLogTestAppend(conn, serverKey, alice.userID, roomID, createData)
	assert(again.outcome == .Conflict, fmt.tprintf("expected a Conflict, got %v", again))

	// alice (a manager and an admin) adds bob.
	addBob := roomLogTestSign(serverKey, head, {action = .Add, actor = alice, target = bob})
	added := roomLogTestExpect(conn, serverKey, &head, alice.userID, addBob, .Applied,
		"alice adds bob")
	assert(
		added.membershipChanged &&
		roomLogTestMembers(conn, roomID) == roomLogTestIDs({alice.userID, bob.userID}),
		"expected bob in room_members",
	)

	// An admin who is not a manager, a member who is neither, a key that is not carol's, an
	// account without a key, and an unsigned add are all refused.
	roomLogTestExpect(conn, serverKey, &head, erin.userID,
		roomLogTestSign(serverKey, head, {action = .Add, actor = erin, target = carol}),
		.NotAuthorized, "erin (admin, not a manager) adds carol")
	roomLogTestExpect(conn, serverKey, &head, bob.userID,
		roomLogTestSign(serverKey, head, {action = .Add, actor = bob, target = carol}),
		.NotAuthorized, "bob (member) adds carol to an Admin invite room")
	roomLogTestExpect(conn, serverKey, &head, alice.userID,
		roomLogTestSign(serverKey, head, {action = .Add, actor = alice, target = carol,
			targetKey = dave.publicKey}),
		.Invalid, "an add naming dave's key for carol")
	roomLogTestExpect(conn, serverKey, &head, alice.userID,
		roomLogTestSign(serverKey, head, {action = .Add, actor = alice, target = keyless}),
		.Invalid, "an add of an account without a key")
	{
		entry := common.RoomLogEntry {
			roomID            = roomID,
			version           = head.version + 1,
			prevHash          = head.hash,
			action            = .Add,
			targetUserID      = carol.userID,
			targetIdentityKey = carol.publicKey,
			createdAt         = 1,
		}
		buffer: [common.ROOM_LOG_ENTRY_MAX_BYTES]u8
		n, err := common.encodeRoomLogEntry(entry, buffer[:])
		assert(err == .None, "expected the unsigned add to encode")
		roomLogTestExpect(conn, serverKey, &head, alice.userID, buffer[:n], .NotAuthorized,
			"an unsigned add")
	}
	// An entry that skips a version.
	skipped := RoomLogTestEntry {
		action  = .Add,
		actor   = alice,
		target  = carol,
		version = head.version + 2,
	}
	roomLogTestExpect(conn, serverKey, &head, alice.userID,
		roomLogTestSign(serverKey, head, skipped), .Conflict, "an add two versions ahead")

	// Members, admins (members or not) and managers fetch; outsiders do not.
	outcome, count, headVersion = roomLogTestFetch(conn, bob.userID, roomID)
	assert(
		outcome == .Applied && count == 2 && headVersion == 2,
		fmt.tprintf("expected bob to read both entries, got %v %d %d", outcome, count,
			headVersion),
	)
	outcome, count, _ = roomLogTestFetch(conn, erin.userID, roomID, 1)
	assert(outcome == .Applied && count == 1, "expected erin (admin) to read after version 1")
	outcome, _, _ = roomLogTestFetch(conn, carol.userID, roomID)
	assert(outcome == .NotMember, "expected carol still unable to fetch")
	outcome, _, _ = roomLogTestFetch(conn, carol.userID, roomID + 1000)
	assert(outcome == .NotMember, "expected a missing room to read as not allowed")

	// Nothing plaintext is stored in an encrypted room, and voice is refused.
	{
		response := databaseExecuteRequest(
			conn,
			databaseTestPlainRoomPost(roomID, alice.userID, "plain"),
		)
		defer IPC__database_query_response_deinit(response)
		posted, ok := response.result.(common.DatabasePostRoomChatMessageResult)
		assert(
			response.success && ok && posted.isMember && posted.encryptedRoom,
			fmt.tprintf("expected plaintext chat refused, got %v", posted),
		)
		stored := databaseAdminTestValue(
			conn,
			fmt.tprintf("SELECT count(*)::text FROM chat_messages WHERE room_id = %d", roomID),
		)
		assert(stored == "0", "expected no chat message stored")
		members := databaseExecuteRequest(
			conn,
			common.DatabaseRoomMemberListRequest{roomId = roomID},
		)
		defer IPC__database_query_response_deinit(members)
		list, listOK := members.result.(common.DatabaseRoomMemberListResult)
		assert(listOK && list.roomFound && list.encrypted, "expected the voice check to see it")
	}

	// Protocol 15 adds and leaves are refused for an encrypted room.
	memberOutcome, _, _, _ := roomLogTestMemberAction(conn, serverKey, .Add, alice.userID,
		roomID, carol.userID)
	assert(memberOutcome == .EncryptedRoom, "expected ClientAddRoomMember refused")
	memberOutcome, _, _, _ = roomLogTestMemberAction(conn, serverKey, .Leave, bob.userID,
		roomID, 0)
	assert(memberOutcome == .EncryptedRoom, "expected ClientLeaveRoom refused")
	memberOutcome, _, _, _ = roomLogTestMemberAction(conn, serverKey, .Remove, bob.userID,
		roomID, alice.userID)
	assert(memberOutcome == .AdminRequired, "expected a removal by a non-admin refused")

	// erin (an admin, not a manager) removes bob: the server writes the unsigned Remove.
	memberChanged: bool
	logVersion: int
	logEntry: []u8
	memberOutcome, memberChanged, logVersion, logEntry = roomLogTestMemberAction(
		conn,
		serverKey,
		.Remove,
		erin.userID,
		roomID,
		bob.userID,
	)
	assert(
		memberOutcome == .Applied && memberChanged && logVersion == 3 && len(logEntry) > 0,
		fmt.tprintf("expected the server's Remove at version 3, got %v %v %d", memberOutcome,
			memberChanged, logVersion),
	)
	{
		decodeManagers: [common.ROOM_LOG_MANAGERS_MAX]common.RoomLogManager
		removal, err := common.decodeRoomLogEntry(logEntry, decodeManagers[:])
		assert(
			err == .None &&
			removal.action == .Remove &&
			removal.actorUserID == 0 &&
			removal.targetUserID == bob.userID &&
			removal.targetIdentityKey == bob.publicKey &&
			removal.prevHash == head.hash,
			fmt.tprintf("expected an unsigned Remove of bob after the head, got %v %v", err,
				removal),
		)
		roomLogTestAdvance(&head, logEntry)
	}
	assert(
		roomLogTestMembers(conn, roomID) == roomLogTestIDs({alice.userID}),
		"expected bob out of room_members",
	)
	memberOutcome, memberChanged, _, _ = roomLogTestMemberAction(conn, serverKey, .Remove,
		erin.userID, roomID, bob.userID)
	assert(
		memberOutcome == .Applied && !memberChanged,
		"expected removing a non-member to change nothing",
	)

	// alice makes erin a manager; erin, a manager who is not a member, adds carol.
	roomLogTestExpect(conn, serverKey, &head, alice.userID,
		roomLogTestSign(serverKey, head, {action = .AddManager, actor = alice, target = erin}),
		.Applied, "alice makes erin a manager")
	assert(
		roomLogTestManagers(conn, roomID) == roomLogTestIDs({alice.userID, erin.userID}),
		"expected erin in room_log_managers",
	)
	addCarol := roomLogTestSign(serverKey, head, {action = .Add, actor = erin, target = carol})
	roomLogTestExpect(conn, serverKey, &head, erin.userID, addCarol, .Applied,
		"erin (manager) adds carol")
	// Without the admin role erin may still fetch (a manager) but not add: an add needs both.
	databaseAdminTestValue(
		conn,
		fmt.tprintf(
			"WITH d AS (DELETE FROM user_server_roles WHERE user_id = %d RETURNING user_id) " +
			"SELECT count(*)::text FROM d",
			erin.userID,
		),
	)
	outcome, _, _ = roomLogTestFetch(conn, erin.userID, roomID)
	assert(outcome == .Applied, "expected a manager who is not a member or admin to fetch")
	roomLogTestExpect(conn, serverKey, &head, erin.userID,
		roomLogTestSign(serverKey, head, {action = .Add, actor = erin, target = dave}),
		.NotAuthorized, "erin (manager, no longer an admin) adds dave")
	databaseAdminTestGrant(conn, erin.userID)

	// alice switches the room to Member invite; carol, a member, then adds dave.
	roomLogTestExpect(conn, serverKey, &head, alice.userID,
		roomLogTestSign(serverKey, head, {action = .SetAccess, actor = alice,
			access = .MemberInvite, history = .FromJoin}),
		.Applied, "alice switches to Member invite")
	assert(
		databaseAdminTestValue(conn, fmt.tprintf("SELECT access::text FROM rooms WHERE id = %d",
			roomID)) == "2",
		"expected rooms.access to follow the SetAccess",
	)
	roomLogTestExpect(conn, serverKey, &head, carol.userID,
		roomLogTestSign(serverKey, head, {action = .Add, actor = carol, target = dave}),
		.Applied, "carol (member) adds dave to a Member invite room")
	// carol leaves; erin stops being a manager.
	leave := roomLogTestExpect(conn, serverKey, &head, carol.userID,
		roomLogTestSign(serverKey, head, {action = .Leave, actor = carol, target = carol}),
		.Applied, "carol leaves")
	assert(leave.membershipChanged && leave.targetUserId == carol.userID, "expected carol out")
	roomLogTestExpect(conn, serverKey, &head, alice.userID,
		roomLogTestSign(serverKey, head, {action = .RemoveManager, actor = alice, target = erin}),
		.Applied, "alice removes erin as a manager")
	assert(
		roomLogTestManagers(conn, roomID) == roomLogTestIDs({alice.userID}) &&
		roomLogTestMembers(conn, roomID) == roomLogTestIDs({alice.userID, dave.userID}),
		fmt.tprintf("expected alice the only manager and alice, dave the members"),
	)

	// Edits never change the encryption or an encrypted room's access.
	edit :: proc(
		conn: pg.Conn,
		actor, roomID: int,
		access: common.RoomAccess,
		encrypted: bool,
	) -> (
		bool,
		common.RoomEditRefusal,
	) {
		response := databaseExecuteRequest(
			conn,
			common.DatabaseEditRoomRequest {
				actorUserId = actor,
				roomId = roomID,
				name = "log-admin",
				roomType = .Chat,
				access = access,
				encrypted = encrypted,
			},
		)
		defer IPC__database_query_response_deinit(response)
		mutation, ok := response.result.(common.DatabaseRoomMutationResult)
		assert(response.success && ok, "expected the edit to run")
		return mutation.changed, mutation.refusal
	}
	changed, refusal := edit(conn, alice.userID, roomID, .MemberInvite, false)
	assert(!changed && refusal == .EncryptionFlag, "expected clearing the flag refused")
	changed, refusal = edit(conn, alice.userID, roomID, .AdminInvite, true)
	assert(!changed && refusal == .EncryptedAccess, "expected an access change refused")
	changed, refusal = edit(conn, alice.userID, roomID, .MemberInvite, true)
	assert(changed && refusal == .None, "expected a rename keeping the access applied")
	changed, refusal = edit(conn, alice.userID, roomID + 1000, .MemberInvite, true)
	assert(!changed && refusal == .None, "expected a missing room to be not found")

	// A row written behind the server's back (an unsigned Add of bob) damages the log: every
	// append is refused, and clients see it when they fetch.
	{
		entry := common.RoomLogEntry {
			roomID            = roomID,
			version           = head.version + 1,
			prevHash          = head.hash,
			action            = .Add,
			targetUserID      = bob.userID,
			targetIdentityKey = bob.publicKey,
			createdAt         = 1,
		}
		buffer: [common.ROOM_LOG_ENTRY_MAX_BYTES]u8
		n, err := common.encodeRoomLogEntry(entry, buffer[:])
		assert(err == .None, "expected the forged add to encode")
		entryHex := common.encodeBytesToHex(buffer[:n])
		defer delete(entryHex)
		databaseAdminTestValue(
			conn,
			fmt.tprintf(
				"WITH i AS (INSERT INTO room_log_entries (room_id, version, entry) " +
				"VALUES (%d, %d, decode('%s', 'hex')) RETURNING version), " +
				"u AS (UPDATE rooms SET log_version = %d WHERE id = %d) " +
				"SELECT version::text FROM i",
				roomID,
				head.version + 1,
				entryHex,
				head.version + 1,
				roomID,
			),
		)
		roomLogTestAdvance(&head, buffer[:n])
	}
	roomLogTestExpect(conn, serverKey, &head, alice.userID,
		roomLogTestSign(serverKey, head, {action = .Add, actor = alice, target = carol}),
		.Damaged, "an add after a forged entry")
	memberOutcome, _, _, _ = roomLogTestMemberAction(conn, serverKey, .Remove, erin.userID,
		roomID, dave.userID)
	assert(memberOutcome == .LogDamaged, "expected the server's removal refused too")
	outcome, count, headVersion = roomLogTestFetch(conn, alice.userID, roomID)
	assert(
		outcome == .Applied && count == head.version && headVersion == head.version,
		"expected the damaged log served as stored",
	)

	// The table checks hold even for SQL the server never runs.
	refused := databaseAdminTestValue(
		conn,
		"SELECT CASE WHEN EXISTS (SELECT 1 FROM pg_constraint " +
		"WHERE conname = 'rooms_encrypted_access') THEN 'ok' ELSE 'missing' END",
	)
	assert(refused == "ok", "expected rooms_encrypted_access")
}

@(test)
testRoomLogFullRoomAgainstPostgreSQL :: proc(t: ^testing.T) {
	_ = t
	if os.get_env(DATABASE_SQL_TEST_ENV, context.temp_allocator) != "1" {
		return
	}
	conn := databaseAdminTestOpen(t, "room_log_full")
	_, serverKey, _ := common.generateIdentityKeyPair()
	alice := roomLogTestAccount(conn, "full-alice")
	databaseAdminTestGrant(conn, alice.userID)
	created := roomLogTestCreateRoom(conn, alice.userID, "log-full", .AdminInvite)
	head := RoomLogTestHead {
		roomID = created.room.id,
	}
	managers := []RoomLogTestAccount{alice}
	roomLogTestExpect(conn, serverKey, &head, alice.userID,
		roomLogTestSign(serverKey, head, {action = .Create, actor = alice, access = .AdminInvite,
			history = .FromJoin, joins = true, managers = managers}),
		.Applied, "the Create")
	// alice plus 99 more fill the room; the 101st member is refused.
	for index in 1 ..< common.ENCRYPTED_ROOM_MEMBERS_MAX {
		member := roomLogTestAccount(conn, fmt.tprintf("full-%d", index))
		roomLogTestExpect(conn, serverKey, &head, alice.userID,
			roomLogTestSign(serverKey, head, {action = .Add, actor = alice, target = member}),
			.Applied, "an add while there is room")
	}
	extra := roomLogTestAccount(conn, "full-extra")
	roomLogTestExpect(conn, serverKey, &head, alice.userID,
		roomLogTestSign(serverKey, head, {action = .Add, actor = alice, target = extra}),
		.RoomFull, "the 101st member")
	count := databaseAdminTestValue(
		conn,
		fmt.tprintf("SELECT count(*)::text FROM room_members WHERE room_id = %d", head.roomID),
	)
	assert(count == "100", fmt.tprintf("expected 100 members, got %s", count))
	// The fetch pages: ROOM_LOG_FETCH_MAX_ENTRIES entries, then the rest.
	outcome, first, headVersion := roomLogTestFetch(conn, alice.userID, head.roomID)
	assert(
		outcome == .Applied &&
		first == min(common.ROOM_LOG_FETCH_MAX_ENTRIES, head.version) &&
		headVersion == head.version,
		fmt.tprintf("expected a first page, got %v %d %d", outcome, first, headVersion),
	)
}

// #103 review: a restricted member of an encrypted room gets the key of every account the room's
// log names (a signer who left and shares nothing else with it, a removed target, a manager
// removed or still named by the Create) and of the sender and forwarder of an envelope wrapped
// for it, since it replays the log and checks envelopes against pinned keys; an account named
// only in another room's log or in envelopes for others still reads as missing, and so do all
// of them once it is removed from the room.
@(test)
testRestrictedMemberGetsRoomLogKeysAgainstPostgreSQL :: proc(t: ^testing.T) {
	_ = t
	if os.get_env(DATABASE_SQL_TEST_ENV, context.temp_allocator) != "1" {
		return
	}
	conn := databaseAdminTestOpen(t, "room_log_keys")
	_, serverKey, _ := common.generateIdentityKeyPair()
	alice := roomLogTestAccount(conn, "lk-alice")
	databaseAdminTestGrant(conn, alice.userID)
	carol := roomLogTestAccount(conn, "lk-carol")
	dave := roomLogTestAccount(conn, "lk-dave")
	erin := roomLogTestAccount(conn, "lk-erin")
	lena := roomLogTestAccount(conn, "lk-lena")
	mona := roomLogTestAccount(conn, "lk-mona")
	gina := roomLogTestAccount(conn, "lk-gina")
	hank := roomLogTestAccount(conn, "lk-hank")
	ivan := roomLogTestAccount(conn, "lk-ivan")
	judy := roomLogTestAccount(conn, "lk-judy")
	kate := roomLogTestAccount(conn, "lk-kate")
	zed := roomLogTestAccount(conn, "lk-zed")
	everyone := [?]RoomLogTestAccount {
		alice, carol, dave, erin, lena, mona, gina, hank, ivan, judy, kate, zed,
	}
	for account, index in everyone {
		bundle := common.DatabasePublishEncryptionKeyRequest {
			userId    = account.userID,
			createdAt = 1_700_000_000,
		}
		for byteIndex in 0 ..< len(bundle.encryptionPublicKey) {
			bundle.encryptionPublicKey[byteIndex] = u8(index + 1)
		}
		published := databaseExecuteRequest(conn, bundle)
		assert(published.success, fmt.tprintf("expected a bundle: %s", published.message))
		IPC__database_query_response_deinit(published)
	}

	// The room: alice creates it with lena and mona as managers, adds carol, who adds erin and
	// dave; alice removes dave and mona as a manager, and carol leaves.
	room := roomLogTestCreateRoom(conn, alice.userID, "lk-room", .MemberInvite).room.id
	head := RoomLogTestHead {
		roomID = room,
	}
	managers := []RoomLogTestAccount{alice, lena, mona}
	steps := [?]struct {
		sender: RoomLogTestAccount,
		spec:   RoomLogTestEntry,
		label:  string,
	} {
		{alice, {action = .Create, actor = alice, access = .MemberInvite, history = .FromJoin,
				joins = true, managers = managers}, "the Create"},
		{alice, {action = .Add, actor = alice, target = carol}, "alice adds carol"},
		{carol, {action = .Add, actor = carol, target = erin}, "carol adds erin"},
		{carol, {action = .Add, actor = carol, target = dave}, "carol adds dave"},
		{alice, {action = .Remove, actor = alice, target = dave}, "alice removes dave"},
		{alice, {action = .RemoveManager, actor = alice, target = mona}, "alice removes mona"},
		{carol, {action = .Leave, actor = carol, target = carol}, "carol leaves"},
	}
	for step in steps {
		roomLogTestExpect(conn, serverKey, &head, step.sender.userID,
			roomLogTestSign(serverKey, head, step.spec), .Applied, step.label)
	}
	assert(
		roomLogTestMembers(conn, room) == roomLogTestIDs({alice.userID, erin.userID}) &&
		roomLogTestManagers(conn, room) == roomLogTestIDs({alice.userID, lena.userID}),
		"expected alice and erin the members, alice and lena the managers",
	)
	// Another room erin is not in names kate.
	other := roomLogTestCreateRoom(conn, alice.userID, "lk-other", .MemberInvite).room.id
	otherHead := RoomLogTestHead {
		roomID = other,
	}
	aliceOnly := []RoomLogTestAccount{alice}
	roomLogTestExpect(conn, serverKey, &otherHead, alice.userID,
		roomLogTestSign(serverKey, otherHead, {action = .Create, actor = alice,
			access = .MemberInvite, history = .FromJoin, joins = true, managers = aliceOnly}),
		.Applied, "the other room's Create")
	roomLogTestExpect(conn, serverKey, &otherHead, alice.userID,
		roomLogTestSign(serverKey, otherHead, {action = .Add, actor = alice, target = kate}),
		.Applied, "alice adds kate to the other room")
	// Envelopes: hank's chain wrapped for erin and alice, alice's chain forwarded to erin by
	// gina; ivan's chain and judy's forward wrap only alice. erin becomes restricted.
	databaseDefaultRoomTestExec(
		conn,
		"store the envelopes",
		fmt.tprintf(
			"INSERT INTO room_key_envelopes (room_id, epoch, sender_user_id, chain_id, " +
			"recipient_user_ids, envelope, forwarder_user_id) VALUES " +
			"(%d, 1, %d, '\\x00112233445566778899aabbccddeeff', ARRAY[%d, %d]::bigint[], " +
			"'\\x01', NULL), " +
			"(%d, 1, %d, '\\x00112233445566778899aabbccddeeff', ARRAY[%d]::bigint[], " +
			"'\\x01', %d), " +
			"(%d, 1, %d, '\\x00112233445566778899aabbccddeeff', ARRAY[%d]::bigint[], " +
			"'\\x01', NULL), " +
			"(%d, 1, %d, '\\x00112233445566778899aabbccddeeff', ARRAY[%d]::bigint[], " +
			"'\\x01', %d); " +
			"UPDATE users SET restricted = true WHERE id = %d",
			room, hank.userID, erin.userID, alice.userID,
			room, alice.userID, erin.userID, gina.userID,
			room, ivan.userID, alice.userID,
			room, alice.userID, alice.userID, judy.userID,
			erin.userID,
		),
	)

	// The IDs erin got bundles for and the IDs listed as missing, both sorted.
	fetch :: proc(conn: pg.Conn, viewer: int, ids: []RoomLogTestAccount) -> (string, string) {
		request := common.DatabaseFetchUserKeysRequest {
			requesterUserId = viewer,
			userIds         = make([dynamic]int, 0, len(ids)),
		}
		defer delete(request.userIds)
		for account in ids {
			append(&request.userIds, account.userID)
		}
		response := databaseExecuteRequest(conn, request)
		defer IPC__database_query_response_deinit(response)
		assert(response.success, fmt.tprintf("expected the fetch to run: %s", response.message))
		fetched := response.result.(common.DatabaseFetchUserKeysResult)
		found := make([dynamic]int, 0, len(fetched.keys), context.temp_allocator)
		for bundle in fetched.keys {
			append(&found, bundle.userId)
		}
		absent := slice.clone(fetched.missingUserIds[:], context.temp_allocator)
		slice.sort(found[:])
		slice.sort(absent)
		return roomLogTestIDs(found[:]), roomLogTestIDs(absent)
	}
	sorted :: proc(accounts: ..RoomLogTestAccount) -> string {
		ids := make([]int, len(accounts), context.temp_allocator)
		for account, index in accounts {
			ids[index] = account.userID
		}
		slice.sort(ids)
		return roomLogTestIDs(ids)
	}
	keys, missing := fetch(conn, erin.userID, everyone[:])
	wantKeys := sorted(alice, carol, dave, erin, lena, mona, gina, hank)
	wantMissing := sorted(ivan, judy, kate, zed)
	assert(
		keys == wantKeys && missing == wantMissing,
		fmt.tprintf(
			"expected erin to get the keys of the log's accounts (%s) and the envelopes' " +
			"senders and forwarder, with %s missing, got %s and %s",
			wantKeys,
			wantMissing,
			keys,
			missing,
		),
	)

	// Removed from the room, erin keeps only her own key and the admin's.
	outcome, changed, _, _ := roomLogTestMemberAction(conn, serverKey, .Remove, alice.userID,
		room, erin.userID)
	assert(outcome == .Applied && changed, "expected alice to remove erin")
	keys, missing = fetch(conn, erin.userID, everyone[:])
	wantKeys = sorted(alice, erin)
	wantMissing = sorted(carol, dave, lena, mona, gina, hank, ivan, judy, kate, zed)
	assert(
		keys == wantKeys && missing == wantMissing,
		fmt.tprintf("expected only %s after the removal, got %s and %s", wantKeys, keys, missing),
	)
}

@(test)
testRoomLogMigrationUpgradesVersion6AgainstPostgreSQL :: proc(t: ^testing.T) {
	_ = t
	if os.get_env(DATABASE_SQL_TEST_ENV, context.temp_allocator) != "1" {
		return
	}
	conn, schema := databaseMigrationTestOpen(t, "room_log_v6")

	// A database a version 6 server migrated and used, with an invite room.
	databaseMigrationTestMigrate(conn, DATABASE_MIGRATIONS[:6])
	databaseDefaultRoomTestExec(conn, "fill version 6 schema", DATABASE_MIGRATION_TEST_RC1_ROWS_SQL)
	databaseDefaultRoomTestExec(
		conn,
		"an invite room",
		"UPDATE rooms SET access = 3, history_visibility = 1 WHERE id = 2",
	)
	before := databaseMigrationTestValue(conn, DATABASE_MIGRATION_TEST_FINGERPRINT_SQL)
	markersBefore := databaseMigrationTestValue(conn, DATABASE_MIGRATION_TEST_MARKERS_SQL)

	outcome := databaseMigrationTestMigrate(conn, DATABASE_MIGRATIONS[:7])
	assert(
		outcome == DatabaseMigrationOutcome{previousVersion = 6, version = 7},
		fmt.tprintf("expected only migration 7 to run, got %v", outcome),
	)
	databaseMigrationTestValidationPassesFor(conn, DATABASE_MIGRATIONS[:7])
	after := databaseMigrationTestValue(conn, DATABASE_MIGRATION_TEST_FINGERPRINT_SQL)
	assert(
		after == before,
		fmt.tprintf("expected every row intact:\nbefore %q\nafter  %q", before, after),
	)
	assert(
		databaseMigrationTestValue(conn, DATABASE_MIGRATION_TEST_MARKERS_SQL) == markersBefore,
		"expected the read markers intact",
	)
	rooms := databaseMigrationTestValue(
		conn,
		"SELECT string_agg(name || ':' || access || ':' || encrypted || ':' || log_version, " +
		"',' ORDER BY id) FROM rooms",
	)
	assert(
		rooms == "general:1:false:0,lounge:3:false:0",
		fmt.tprintf("expected existing rooms unencrypted at version 0, got %q", rooms),
	)
	empty := databaseMigrationTestValue(
		conn,
		"SELECT ((SELECT count(*) FROM room_log_entries) + " +
		"(SELECT count(*) FROM room_log_managers))::text",
	)
	assert(empty == "0", "expected both new tables empty")
	// An encrypted Public room and a log version on an unencrypted room break the checks.
	probe := databaseMigrationTestValue(
		conn,
		"SELECT (SELECT count(*) FROM pg_constraint WHERE conrelid = to_regclass('rooms') " +
		"AND conname IN ('rooms_encrypted_access', 'rooms_log_version_check'))::text",
	)
	assert(probe == "2", fmt.tprintf("expected both rooms checks, got %q", probe))
}

@(test)
testRoomLogMigrationKeepsItsShape :: proc(t: ^testing.T) {
	_ = t
	migration := DATABASE_MIGRATIONS[6]
	assert(
		migration.version == 7 && migration.name == "encrypted room log",
		fmt.tprintf("expected migration 7 to be the encrypted room log, got %v", migration),
	)
	for required in ([]string {
			"ADD COLUMN encrypted BOOLEAN NOT NULL DEFAULT false",
			"ADD COLUMN log_version BIGINT NOT NULL DEFAULT 0",
			"CHECK (NOT encrypted OR access IN (2, 3))",
			"CREATE TABLE room_log_entries",
			"PRIMARY KEY (room_id, version)",
			"CREATE TABLE room_log_managers",
		}) {
		assert(
			strings.contains(migration.sql, required),
			fmt.tprintf("expected migration 7 to contain %q", required),
		)
	}
	assert(!strings.contains(migration.sql, "DROP "), "expected migration 7 to drop nothing")
	assert(
		strings.contains(migration.sql, fmt.tprintf("BETWEEN 1 AND %d)",
			common.ROOM_LOG_ENTRY_MAX_BYTES)),
		"expected the entry size check to be ROOM_LOG_ENTRY_MAX_BYTES",
	)
	assert(
		strings.contains(DATABASE_SCHEMA_VALIDATION_SQL, "room_log_entries table") &&
		strings.contains(DATABASE_SCHEMA_VALIDATION_SQL, "rooms encryption checks"),
		"expected schema validation to require migration 7's objects",
	)
}

// The server's own rules on top of the log's (design 5.1), without a database.
@(test)
testRoomLogServerRules :: proc(t: ^testing.T) {
	_ = t
	room := RoomLogLockedRoomView {
		access            = .AdminInvite,
		historyVisibility = .FromJoin,
		createdBy         = 1,
		actorManagesRooms = true,
		actorManagesMembers = true,
	}
	create := common.RoomLogEntry {
		action = .Create,
		actorUserID = 1,
		settings = {access = .AdminInvite, historyVisibility = .FromJoin},
	}
	assert(roomLogServerAllows(room, 1, create) == .Applied, "expected the creator's Create")
	assert(roomLogServerAllows(room, 2, create) == .NotAuthorized, "expected the actor checked")
	other := room
	other.createdBy = 2
	assert(
		roomLogServerAllows(other, 1, create) == .NotAuthorized,
		"expected only the room's creator",
	)
	settings := create
	settings.settings.historyVisibility = .Full
	assert(roomLogServerAllows(room, 1, settings) == .Invalid, "expected the room's settings")

	add := common.RoomLogEntry {
		action      = .Add,
		actorUserID = 1,
	}
	member := room
	member.actorManagesRooms = false
	member.actorManagesMembers = false
	member.actorIsMember = true
	assert(roomLogServerAllows(room, 1, add) == .Applied, "expected an admin's add")
	assert(
		roomLogServerAllows(member, 1, add) == .NotAuthorized,
		"expected a member's add refused in an Admin invite room",
	)
	member.access = .MemberInvite
	assert(roomLogServerAllows(member, 1, add) == .Applied, "expected a Member invite member")
	setAccess := common.RoomLogEntry {
		action      = .SetAccess,
		actorUserID = 1,
	}
	assert(
		roomLogServerAllows(member, 1, setAccess) == .NotAuthorized,
		"expected SetAccess to need the admin role",
	)
	leave := common.RoomLogEntry {
		action      = .Leave,
		actorUserID = 1,
	}
	assert(roomLogServerAllows(member, 1, leave) == .Applied, "expected a leave allowed")

	// Protocol 23: the permissions, not the admin role, decide. ManageRoomMembers adds in an
	// Admin invite room but cannot create or change the access; ManageRooms the reverse.
	membersOnly := room
	membersOnly.actorManagesRooms = false
	assert(roomLogServerAllows(membersOnly, 1, add) == .Applied, "expected a manager's add")
	assert(
		roomLogServerAllows(membersOnly, 1, create) == .NotAuthorized,
		"expected Create to need ManageRooms",
	)
	roomsOnly := room
	roomsOnly.actorManagesMembers = false
	assert(roomLogServerAllows(roomsOnly, 1, create) == .Applied, "expected ManageRooms to create")
	assert(
		roomLogServerAllows(roomsOnly, 1, add) == .NotAuthorized,
		"expected Add in an Admin invite room to need ManageRoomMembers",
	)
	assert(roomLogServerAllows(roomsOnly, 1, setAccess) == .Applied, "expected SetAccess allowed")

	assert(roomLogAppendOutcomeFor(.VersionNotNext) == .Conflict, "expected a conflict")
	assert(roomLogAppendOutcomeFor(.BadPrevHash) == .Conflict, "expected a conflict")
	assert(roomLogAppendOutcomeFor(.NotAuthorized) == .NotAuthorized, "expected refused")
	assert(roomLogAppendOutcomeFor(.Unsigned) == .NotAuthorized, "expected unsigned refused")
	assert(roomLogAppendOutcomeFor(.RoomFull) == .RoomFull, "expected full")
	assert(roomLogAppendOutcomeFor(.BadSignature) == .Invalid, "expected invalid")
	assert(roomLogAppendOutcomeFor(.PinMismatch) == .Invalid, "expected invalid")
}

// Protocol 32 (#72): what a ban did to encrypted rooms, copied to the temp allocator. removed
// lists "room@version" per removal; members and entry are the first removal's. Protocol 33
// (#195): demoted lists "room@version" per RemoveManager, managers is the first removal's
// manager set after it, and managerEntry the first RemoveManager.
@(private = "file")
RoomLogTestBan :: struct {
	outcome:      common.DatabaseAdminOutcome,
	changed:      bool,
	removed:      string,
	members:      string,
	entry:        []u8,
	failed:       string,
	demoted:      string,
	managers:     string,
	managerEntry: []u8,
}

@(private = "file")
roomLogTestBan :: proc(
	conn: pg.Conn,
	serverKey: common.IdentityPublicKeyBytes,
	actorID, targetID: int,
	banned: bool,
) -> (
	ban: RoomLogTestBan,
) {
	response := databaseExecuteRequest(
		conn,
		common.DatabaseAdminUserRequest {
			action = .Ban,
			actorUserId = actorID,
			targetUserId = targetID,
			banned = banned,
			reason = "proof ban",
			serverIdentityPublicKey = serverKey,
		},
	)
	defer IPC__database_query_response_deinit(response)
	got, ok := response.result.(common.DatabaseAdminUserResult)
	assert(response.success && ok, fmt.tprintf("expected the ban to run: %s", response.message))
	ban.outcome = got.outcome
	ban.changed = got.changed
	removed := strings.builder_make(context.temp_allocator)
	demoted := strings.builder_make(context.temp_allocator)
	for removal, index in got.banRemovals {
		if removal.logEntry != nil {
			if strings.builder_len(removed) > 0 {
				strings.write_byte(&removed, ',')
			}
			fmt.sbprintf(&removed, "%d@%d", removal.roomId, removal.logVersion)
		}
		if removal.managerLogEntry != nil {
			if strings.builder_len(demoted) > 0 {
				strings.write_byte(&demoted, ',')
			}
			fmt.sbprintf(&demoted, "%d@%d", removal.roomId, removal.managerLogVersion)
		}
		if index == 0 {
			ban.members = roomLogTestIDs(removal.memberUserIDs[:])
			ban.managers = roomLogTestIDs(removal.managerUserIDs[:])
			ban.entry = make([]u8, len(removal.logEntry), context.temp_allocator)
			copy(ban.entry, removal.logEntry)
			ban.managerEntry = make([]u8, len(removal.managerLogEntry), context.temp_allocator)
			copy(ban.managerEntry, removal.managerLogEntry)
		}
	}
	ban.removed = strings.to_string(removed)
	ban.demoted = strings.to_string(demoted)
	ban.failed = roomLogTestIDs(got.failedRoomIDs[:])
	return
}

// An encrypted Admin invite room alice creates and joins, with members added by her.
@(private = "file")
roomLogTestBanRoom :: proc(
	conn: pg.Conn,
	serverKey: common.IdentityPublicKeyBytes,
	alice: RoomLogTestAccount,
	name: string,
	members: []RoomLogTestAccount,
) -> RoomLogTestHead {
	created := roomLogTestCreateRoom(conn, alice.userID, name, .AdminInvite)
	head := RoomLogTestHead {
		roomID = created.room.id,
	}
	managers := []RoomLogTestAccount{alice}
	roomLogTestExpect(conn, serverKey, &head, alice.userID,
		roomLogTestSign(serverKey, head, {action = .Create, actor = alice, access = .AdminInvite,
			history = .FromJoin, joins = true, managers = managers}),
		.Applied, "the Create")
	for member in members {
		roomLogTestExpect(conn, serverKey, &head, alice.userID,
			roomLogTestSign(serverKey, head, {action = .Add, actor = alice, target = member}),
			.Applied, "an add")
	}
	return head
}

// Stores an unsigned Add of target behind the server's back, so the log no longer replays.
@(private = "file")
roomLogTestDamage :: proc(conn: pg.Conn, head: ^RoomLogTestHead, target: RoomLogTestAccount) {
	entry := common.RoomLogEntry {
		roomID            = head.roomID,
		version           = head.version + 1,
		prevHash          = head.hash,
		action            = .Add,
		targetUserID      = target.userID,
		targetIdentityKey = target.publicKey,
		createdAt         = 1,
	}
	buffer: [common.ROOM_LOG_ENTRY_MAX_BYTES]u8
	n, err := common.encodeRoomLogEntry(entry, buffer[:])
	assert(err == .None, "expected the forged add to encode")
	entryHex := common.encodeBytesToHex(buffer[:n])
	defer delete(entryHex)
	databaseAdminTestValue(
		conn,
		fmt.tprintf(
			"WITH i AS (INSERT INTO room_log_entries (room_id, version, entry) " +
			"VALUES (%d, %d, decode('%s', 'hex')) RETURNING version), " +
			"u AS (UPDATE rooms SET log_version = %d WHERE id = %d) " +
			"SELECT version::text FROM i",
			head.roomID,
			head.version + 1,
			entryHex,
			head.version + 1,
			head.roomID,
		),
	)
	roomLogTestAdvance(head, buffer[:n])
}

@(private = "file")
roomLogTestLogVersion :: proc(conn: pg.Conn, roomID: int) -> string {
	return databaseAdminTestValue(
		conn,
		fmt.tprintf("SELECT log_version::text FROM rooms WHERE id = %d", roomID),
	)
}

// Protocol 32 (#72): a ban removes the account from every encrypted room it is a member of, in
// the ban's transaction, with the server's unsigned Remove: a room it is in loses it (a new
// epoch the remaining members' next entry follows), a room it is not in is left alone, and a
// room whose log is damaged is reported while the ban still applies. A refused ban removes
// nothing, banning again retries only what is left, and an unban adds nobody back.
@(test)
testBanRemovesFromEncryptedRoomsAgainstPostgreSQL :: proc(t: ^testing.T) {
	_ = t
	if os.get_env(DATABASE_SQL_TEST_ENV, context.temp_allocator) != "1" {
		return
	}
	conn := databaseAdminTestOpen(t, "room_log_ban")
	_, serverKey, serverKeyOK := common.generateIdentityKeyPair()
	assert(serverKeyOK, "expected a server key")
	alice := roomLogTestAccount(conn, "ban-alice")
	databaseAdminTestGrant(conn, alice.userID)
	bob := roomLogTestAccount(conn, "ban-bob")
	carol := roomLogTestAccount(conn, "ban-carol")

	member := roomLogTestBanRoom(conn, serverKey, alice, "ban-member", {bob, carol})
	other := roomLogTestBanRoom(conn, serverKey, alice, "ban-other", {carol})
	damaged := roomLogTestBanRoom(conn, serverKey, alice, "ban-damaged", {bob})
	roomLogTestDamage(conn, &damaged, carol)

	// carol is no admin: the statement's guards decide before any room is touched.
	refused := roomLogTestBan(conn, serverKey, carol.userID, bob.userID, true)
	assert(
		refused.outcome == .NotAdmin && refused.removed == "" && refused.failed == "",
		fmt.tprintf("expected carol's ban refused with nothing removed, got %v", refused),
	)
	assert(
		roomLogTestLogVersion(conn, member.roomID) == "3" &&
		roomLogTestMembers(conn, member.roomID) ==
			roomLogTestIDs({alice.userID, bob.userID, carol.userID}),
		"expected a refused ban to leave the member room alone",
	)
	self := roomLogTestBan(conn, serverKey, alice.userID, alice.userID, true)
	assert(self.outcome == .SelfTarget && self.removed == "", "expected a self ban refused")

	ban := roomLogTestBan(conn, serverKey, alice.userID, bob.userID, true)
	assert(
		ban.outcome == .Applied && ban.changed,
		fmt.tprintf("expected alice's ban applied, got %v", ban),
	)
	assert(
		ban.removed == fmt.tprintf("%d@4", member.roomID),
		fmt.tprintf("expected bob removed from room %d only, got %q", member.roomID, ban.removed),
	)
	assert(
		ban.members == roomLogTestIDs({alice.userID, carol.userID}),
		fmt.tprintf("expected alice and carol left, got %q", ban.members),
	)
	assert(
		ban.failed == roomLogTestIDs({damaged.roomID}),
		fmt.tprintf("expected the damaged room %d reported, got %q", damaged.roomID, ban.failed),
	)
	managers: [common.ROOM_LOG_MANAGERS_MAX]common.RoomLogManager
	removal, decodeErr := common.decodeRoomLogEntry(ban.entry, managers[:])
	assert(
		decodeErr == .None &&
		removal.action == .Remove &&
		removal.actorUserID == 0 &&
		removal.targetUserID == bob.userID &&
		removal.version == 4,
		fmt.tprintf("expected the server's unsigned Remove of bob, got %v (%v)", removal,
			decodeErr),
	)
	assert(
		databaseAdminTestValue(
			conn,
			fmt.tprintf("SELECT (banned_at IS NOT NULL)::text FROM users WHERE id = %d",
				bob.userID),
		) == "true",
		"expected bob banned",
	)
	assert(
		roomLogTestMembers(conn, member.roomID) == roomLogTestIDs({alice.userID, carol.userID}) &&
		roomLogTestLogVersion(conn, member.roomID) == "4",
		"expected bob out of the member room at version 4",
	)
	assert(
		roomLogTestMembers(conn, other.roomID) == roomLogTestIDs({alice.userID, carol.userID}) &&
		roomLogTestLogVersion(conn, other.roomID) == "2",
		"expected the room bob is not in left alone",
	)
	assert(
		roomLogTestMembers(conn, damaged.roomID) == roomLogTestIDs({alice.userID, bob.userID}) &&
		roomLogTestLogVersion(conn, damaged.roomID) == fmt.tprintf("%d", damaged.version),
		"expected the damaged room left as it was",
	)
	// The stored log still replays: alice's next entry follows the server's Remove.
	roomLogTestAdvance(&member, ban.entry)
	roomLogTestExpect(conn, serverKey, &member, alice.userID,
		roomLogTestSign(serverKey, member, {action = .Remove, actor = alice, target = carol}),
		.Applied, "alice's removal after the ban's")

	// Banning again retries what is left: the damaged room, still reported.
	again := roomLogTestBan(conn, serverKey, alice.userID, bob.userID, true)
	assert(
		again.outcome == .Applied && !again.changed && again.removed == "" &&
		again.failed == roomLogTestIDs({damaged.roomID}),
		fmt.tprintf("expected a second ban to change nothing but report the room, got %v",
			again),
	)

	// An unban lifts the ban and adds bob back to nothing.
	unban := roomLogTestBan(conn, serverKey, alice.userID, bob.userID, false)
	assert(
		unban.outcome == .Applied && unban.changed && unban.removed == "" && unban.failed == "",
		fmt.tprintf("expected the unban applied alone, got %v", unban),
	)
	assert(
		roomLogTestMembers(conn, member.roomID) == roomLogTestIDs({alice.userID}) &&
		roomLogTestLogVersion(conn, member.roomID) == "5",
		"expected the unban to leave the member room as it was",
	)
}

// Protocol 32 (#72): a ban does not wait for a room another connection holds locked; it
// reports the room and still applies, and removes the account from the others. The schema is
// committed (the second connection must see it) and dropped by the test's cleanup.
@(test)
testBanReportsLockedEncryptedRoomAgainstPostgreSQL :: proc(t: ^testing.T) {
	_ = t
	if os.get_env(DATABASE_SQL_TEST_ENV, context.temp_allocator) != "1" {
		return
	}
	conn, schema := databaseMigrationTestOpen(t, "ban_locked")
	databaseMigrationTestMigrate(conn, DATABASE_MIGRATIONS[:])
	_, serverKey, serverKeyOK := common.generateIdentityKeyPair()
	assert(serverKeyOK, "expected a server key")
	alice := roomLogTestAccount(conn, "lock-alice")
	databaseAdminTestGrant(conn, alice.userID)
	bob := roomLogTestAccount(conn, "lock-bob")
	unheld := roomLogTestBanRoom(conn, serverKey, alice, "lock-free", {bob})
	held := roomLogTestBanRoom(conn, serverKey, alice, "lock-held", {bob})

	// Opened after conn, so its cleanup (a rollback) runs before conn drops the schema.
	holder := databaseSQLTestOpen(t)
	databaseDefaultRoomTestExec(
		holder,
		"hold the room",
		fmt.tprintf(
			"SET search_path TO %s; BEGIN; SELECT id FROM rooms WHERE id = %d FOR UPDATE",
			schema,
			held.roomID,
		),
	)
	ban := roomLogTestBan(conn, serverKey, alice.userID, bob.userID, true)
	databaseDefaultRoomTestExec(holder, "release the room", "ROLLBACK")
	assert(
		ban.outcome == .Applied && ban.changed,
		fmt.tprintf("expected the ban applied, got %v", ban),
	)
	assert(
		ban.removed == fmt.tprintf("%d@3", unheld.roomID) &&
		ban.failed == roomLogTestIDs({held.roomID}),
		fmt.tprintf("expected room %d changed and %d reported, got %q and %q", unheld.roomID,
			held.roomID, ban.removed, ban.failed),
	)
	assert(
		roomLogTestMembers(conn, held.roomID) == roomLogTestIDs({alice.userID, bob.userID}) &&
		roomLogTestMembers(conn, unheld.roomID) == roomLogTestIDs({alice.userID}),
		"expected bob still in the held room only",
	)
	// Once released, banning again removes him there too.
	again := roomLogTestBan(conn, serverKey, alice.userID, bob.userID, true)
	assert(
		again.removed == fmt.tprintf("%d@3", held.roomID) && again.failed == "",
		fmt.tprintf("expected the retry to remove bob from room %d, got %v", held.roomID, again),
	)
}

// A sealed post's verdict: the database checks the room's log version and membership (the
// router checked the seal's signature before).
@(private = "file")
roomLogTestSealedPost :: proc(
	conn: pg.Conn,
	roomID, senderID, epoch: int,
	chain: u8,
) -> common.DatabasePostRoomChatMessageResult {
	request := databaseTestPlainRoomPost(roomID, senderID, "")
	request.content = strings.clone("")
	request.sealed = make([]u8, 8)
	request.sealed[0] = 1
	request.epoch = epoch
	request.chainId[0] = chain
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

// An encrypted Admin invite room alice creates and joins with managers alice and manager, then
// her signed adds of members.
@(private = "file")
roomLogTestManagedRoom :: proc(
	conn: pg.Conn,
	serverKey: common.IdentityPublicKeyBytes,
	alice, manager: RoomLogTestAccount,
	name: string,
	members: []RoomLogTestAccount,
) -> RoomLogTestHead {
	created := roomLogTestCreateRoom(conn, alice.userID, name, .AdminInvite)
	head := RoomLogTestHead {
		roomID = created.room.id,
	}
	managers := []RoomLogTestAccount{alice, manager}
	roomLogTestExpect(conn, serverKey, &head, alice.userID,
		roomLogTestSign(serverKey, head, {action = .Create, actor = alice, access = .AdminInvite,
			history = .FromJoin, joins = true, managers = managers}),
		.Applied, "the Create")
	for member in members {
		roomLogTestExpect(conn, serverKey, &head, alice.userID,
			roomLogTestSign(serverKey, head, {action = .Add, actor = alice, target = member}),
			.Applied, "an add")
	}
	return head
}

// The server's unsigned entry of action on target after head, as a client would send it.
@(private = "file")
roomLogTestUnsigned :: proc(
	head: RoomLogTestHead,
	action: common.RoomLogAction,
	target: RoomLogTestAccount,
) -> []u8 {
	entry := common.RoomLogEntry {
		roomID            = head.roomID,
		version           = head.version + 1,
		prevHash          = head.hash,
		action            = action,
		targetUserID      = target.userID,
		targetIdentityKey = target.publicKey,
		createdAt         = 1,
	}
	buffer: [common.ROOM_LOG_ENTRY_MAX_BYTES]u8
	n, err := common.encodeRoomLogEntry(entry, buffer[:])
	assert(err == .None, "expected the unsigned entry to encode")
	data := make([]u8, n, context.temp_allocator)
	copy(data, buffer[:n])
	return data
}

// Protocol 33 (#195): a ban also removes the account from every encrypted room's log manager
// set with the server's unsigned RemoveManager, after its Remove: a manager who is a member
// (Remove, then RemoveManager), a manager who is no member (RemoveManager alone), and the only
// manager (the room is left with none: members still post, an admin still removes, and nobody
// adds). A client cannot send the server's RemoveManager itself.
@(test)
testBanRemovesLogManagersAgainstPostgreSQL :: proc(t: ^testing.T) {
	_ = t
	if os.get_env(DATABASE_SQL_TEST_ENV, context.temp_allocator) != "1" {
		return
	}
	conn := databaseAdminTestOpen(t, "room_log_ban_managers")
	_, serverKey, serverKeyOK := common.generateIdentityKeyPair()
	assert(serverKeyOK, "expected a server key")
	alice := roomLogTestAccount(conn, "mgr-alice")
	databaseAdminTestGrant(conn, alice.userID)
	bob := roomLogTestAccount(conn, "mgr-bob")
	carol := roomLogTestAccount(conn, "mgr-carol")
	dave := roomLogTestAccount(conn, "mgr-dave")

	// bob manages all three; he is a member of the first and the last.
	member := roomLogTestManagedRoom(conn, serverKey, alice, bob, "mgr-member", {bob, carol})
	outside := roomLogTestManagedRoom(conn, serverKey, alice, bob, "mgr-outside", {carol})
	last := roomLogTestManagedRoom(conn, serverKey, alice, bob, "mgr-last", {bob, carol})
	// alice steps down in the last room, so bob is its only manager.
	roomLogTestExpect(conn, serverKey, &last, alice.userID,
		roomLogTestSign(serverKey, last, {action = .RemoveManager, actor = alice, target = alice}),
		.Applied, "alice stepping down")
	assert(
		roomLogTestManagers(conn, last.roomID) == roomLogTestIDs({bob.userID}),
		"expected bob the last room's only manager",
	)

	// A client's unsigned RemoveManager is refused like any entry not signed by its sender.
	roomLogTestExpect(conn, serverKey, &outside, carol.userID,
		roomLogTestUnsigned(outside, .RemoveManager, bob), .NotAuthorized,
		"carol's unsigned RemoveManager")

	ban := roomLogTestBan(conn, serverKey, alice.userID, bob.userID, true)
	assert(
		ban.outcome == .Applied && ban.changed && ban.failed == "",
		fmt.tprintf("expected the ban applied everywhere, got %v", ban),
	)
	assert(
		ban.removed == fmt.tprintf("%d@4,%d@5", member.roomID, last.roomID),
		fmt.tprintf("expected bob removed from the member rooms, got %q", ban.removed),
	)
	assert(
		ban.demoted ==
		fmt.tprintf("%d@5,%d@3,%d@6", member.roomID, outside.roomID, last.roomID),
		fmt.tprintf("expected bob no manager anywhere, got %q", ban.demoted),
	)
	assert(
		ban.members == roomLogTestIDs({alice.userID, carol.userID}) &&
		ban.managers == roomLogTestIDs({alice.userID}),
		fmt.tprintf("expected alice and carol left with alice managing, got %v", ban),
	)
	managers: [common.ROOM_LOG_MANAGERS_MAX]common.RoomLogManager
	demotion, decodeErr := common.decodeRoomLogEntry(ban.managerEntry, managers[:])
	assert(
		decodeErr == .None &&
		demotion.action == .RemoveManager &&
		demotion.actorUserID == 0 &&
		demotion.targetUserID == bob.userID &&
		demotion.targetIdentityKey == bob.publicKey &&
		demotion.version == 5,
		fmt.tprintf("expected the server's unsigned RemoveManager of bob, got %v (%v)",
			demotion, decodeErr),
	)
	assert(
		roomLogTestMembers(conn, member.roomID) == roomLogTestIDs({alice.userID, carol.userID}) &&
		roomLogTestManagers(conn, member.roomID) == roomLogTestIDs({alice.userID}) &&
		roomLogTestLogVersion(conn, member.roomID) == "5",
		"expected bob out of the member room's members and managers",
	)
	assert(
		roomLogTestMembers(conn, outside.roomID) == roomLogTestIDs({alice.userID, carol.userID}) &&
		roomLogTestManagers(conn, outside.roomID) == roomLogTestIDs({alice.userID}) &&
		roomLogTestLogVersion(conn, outside.roomID) == "3",
		"expected bob out of the other room's managers",
	)
	assert(
		roomLogTestMembers(conn, last.roomID) == roomLogTestIDs({alice.userID, carol.userID}) &&
		roomLogTestManagers(conn, last.roomID) == "" &&
		roomLogTestLogVersion(conn, last.roomID) == "6",
		"expected the last room left with no manager",
	)

	// Every stored log still replays: the managers' next entries follow the server's.
	roomLogTestAdvance(&member, ban.entry)
	roomLogTestAdvance(&member, ban.managerEntry)
	roomLogTestExpect(conn, serverKey, &member, alice.userID,
		roomLogTestSign(serverKey, member, {action = .Add, actor = alice, target = dave}),
		.Applied, "alice's add after the ban")
	fetched, count, headVersion := roomLogTestFetch(conn, carol.userID, last.roomID)
	assert(
		fetched == .Applied && count == 6 && headVersion == 6,
		fmt.tprintf("expected carol to fetch the last room's 6 entries, got %v %d %d", fetched,
			count, headVersion),
	)
	// The head: replay what was stored, as a client does.
	last.version = 6
	entriesResponse := databaseExecuteRequest(
		conn,
		common.DatabaseFetchRoomLogRequest{actorUserId = carol.userID, roomId = last.roomID},
	)
	entries := entriesResponse.result.(common.DatabaseFetchRoomLogResult).entries
	state, replayErr, _ := common.replayRoomLog(
		last.roomID,
		entries[:],
		common.RoomLogContext{serverIdentityPublicKey = serverKey},
	)
	assert(replayErr == .None, fmt.tprintf("expected the last room to replay, got %v", replayErr))
	assert(len(state.managers) == 0 && len(state.members) == 2, "expected no manager, 2 members")
	last.hash = state.headHash
	common.RoomLogState_deinit(&state)
	IPC__database_query_response_deinit(entriesResponse)

	// With no manager the members still post at the new epoch, and the old one is refused.
	posted := roomLogTestSealedPost(conn, last.roomID, carol.userID, 6, 1)
	assert(
		posted.isMember && !posted.staleEpoch && posted.storedMessage.id > 0,
		fmt.tprintf("expected carol's sealed post stored, got %v", posted),
	)
	stale := roomLogTestSealedPost(conn, last.roomID, alice.userID, 5, 2)
	assert(stale.staleEpoch, fmt.tprintf("expected the old epoch refused, got %v", stale))
	// Nobody adds, not a member and not an admin who is no manager.
	roomLogTestExpect(conn, serverKey, &last, carol.userID,
		roomLogTestSign(serverKey, last, {action = .Add, actor = carol, target = dave}),
		.NotAuthorized, "a member's add without a manager")
	roomLogTestExpect(conn, serverKey, &last, alice.userID,
		roomLogTestSign(serverKey, last, {action = .Add, actor = alice, target = dave}),
		.NotAuthorized, "an admin's add without a manager")
	roomLogTestExpect(conn, serverKey, &last, alice.userID,
		roomLogTestSign(serverKey, last, {action = .AddManager, actor = alice, target = alice}),
		.NotAuthorized, "an admin making herself a manager")
	// An admin still removes members through the server's entry.
	outcome, changed, logVersion, _ := roomLogTestMemberAction(
		conn,
		serverKey,
		.Remove,
		alice.userID,
		last.roomID,
		carol.userID,
	)
	assert(
		outcome == .Applied && changed && logVersion == 7,
		fmt.tprintf("expected alice to remove carol, got %v %v %d", outcome, changed, logVersion),
	)
	assert(
		roomLogTestMembers(conn, last.roomID) == roomLogTestIDs({alice.userID}),
		"expected alice alone in the last room",
	)

	// Banning again changes nothing: bob manages no room's log now.
	again := roomLogTestBan(conn, serverKey, alice.userID, bob.userID, true)
	assert(
		again.outcome == .Applied && again.removed == "" && again.demoted == "" &&
		again.failed == "",
		fmt.tprintf("expected a second ban to change nothing, got %v", again),
	)
}
