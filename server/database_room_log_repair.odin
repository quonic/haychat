package server

import "../common"
import "core:fmt"
import "core:slice"
import "shared:pg"

// Repairing a damaged member log (protocol 34, #196, common/room_log_repair.odin). Admins only:
// the statement that reads the rooms checks the admin role (DATABASE_ACTOR_IS_ADMIN_SQL), and a
// truncation's lock statement checks it again in the transaction that makes the change.
//
// Status replays each room's stored log (databaseRoomLogRepairInspect) with the room row locked,
// so it reads what an append would; nothing is written. Truncate runs in one transaction:
//
// 1. Read the room (admin, exists, encrypted) and lock its row FOR UPDATE.
// 2. Replay the stored log. Refuse a log that is not damaged (an admin must not roll back a
//    healthy log, which would undo removals), a toVersion other than the goodVersion it
//    found (the smallest loss, and a compare-and-swap: a log that changed since the admin
//    looked is refused, not cut somewhere else), and a goodVersion of 0 (not even the Create
//    replays: delete the room instead, since only the creator's client could set it up again).
// 3. Delete the entries after toVersion.
// 4. Delete what belongs to the epochs after toVersion, whose numbers the next entries will use
//    again for other members: room key envelopes (no chain of those epochs can be handed out
//    again), sealed messages (with their edits, by cascade; their files lose their message and
//    the sweeper deletes them within the hour), and sealed edits of older messages made on a
//    chain of those epochs (edit_count and edited_at follow). Keeping them would let a member of
//    the new epoch with the same number ask for, or be forwarded, a chain sealed for others.
// 5. Make room_members the replayed members (a removed member's read marker goes, as for a
//    removal; an added one starts with nothing unread), room_log_managers the replayed
//    managers, rooms.access the replayed access and rooms.log_version toVersion.
//
// The router then ends the room's voice and fans the change out (router_room_log_repair.odin).

// $1 the requester, $2 the room (0: every encrypted room). Always one row first; the room
// columns are NULL when there is none, or when the requester is no admin.
DATABASE_ROOM_LOG_REPAIR_ROOMS_SQL ::
	"SELECT (" + DATABASE_ACTOR_IS_ADMIN_SQL + ")::text, r.id::text, r.encrypted::text " +
	"FROM (SELECT 1) AS one LEFT JOIN rooms r ON (" + DATABASE_ACTOR_IS_ADMIN_SQL + ") " +
	"AND (($2::bigint = 0 AND r.encrypted) OR r.id = $2::bigint) ORDER BY r.id"

// $1 the requester, $2 the room: its head, locked, while it is encrypted and $1 an admin.
DATABASE_ROOM_LOG_REPAIR_LOCK_SQL ::
	"SELECT r.log_version::text FROM rooms r WHERE r.id = $2::bigint AND r.encrypted " +
	"AND (" + DATABASE_ACTOR_IS_ADMIN_SQL + ") FOR UPDATE"

// $1 the room: the same lock for a status, which the caller already checked.
DATABASE_ROOM_LOG_REPAIR_STATUS_LOCK_SQL ::
	"SELECT log_version::text FROM rooms WHERE id = $1::bigint AND encrypted FOR UPDATE"

DATABASE_ROOM_LOG_REPAIR_MEMBERS_SQL ::
	"SELECT user_id::text FROM room_members WHERE room_id = $1::bigint " +
	"UNION SELECT user_id::text FROM room_log_managers WHERE room_id = $1::bigint"

// $1 the room, $2 toVersion. Each returns the count of rows it deleted.
DATABASE_ROOM_LOG_TRUNCATE_ENTRIES_SQL ::
	"WITH d AS (DELETE FROM room_log_entries WHERE room_id = $1::bigint " +
	"AND version > $2::bigint RETURNING 1) SELECT count(*)::text FROM d"

DATABASE_ROOM_LOG_TRUNCATE_ENVELOPES_SQL ::
	"WITH d AS (DELETE FROM room_key_envelopes WHERE room_id = $1::bigint " +
	"AND epoch > $2::bigint RETURNING 1) SELECT count(*)::text FROM d"

// A SealedRoomMessage's epoch: bytes 1..8, little-endian (common/e2ee.odin).
DATABASE_SEALED_EDIT_EPOCH_SQL ::
	"(get_byte(ed.sealed, 1)::bigint | (get_byte(ed.sealed, 2)::bigint << 8) | " +
	"(get_byte(ed.sealed, 3)::bigint << 16) | (get_byte(ed.sealed, 4)::bigint << 24) | " +
	"(get_byte(ed.sealed, 5)::bigint << 32) | (get_byte(ed.sealed, 6)::bigint << 40) | " +
	"(get_byte(ed.sealed, 7)::bigint << 48) | (get_byte(ed.sealed, 8)::bigint << 56))"

// Sealed edits of messages the truncation keeps, made on a chain of a later epoch. The
// messages' edit_count and edited_at follow the edits left (the snapshot still holds the
// deleted rows, hence NOT IN gone).
DATABASE_ROOM_LOG_TRUNCATE_EDITS_SQL ::
	"WITH gone AS (DELETE FROM chat_message_edits ed USING chat_messages m " +
	"WHERE ed.message_id = m.id AND m.room_id = $1::bigint AND ed.sealed IS NOT NULL " +
	"AND octet_length(ed.sealed) >= 9 AND " + DATABASE_SEALED_EDIT_EPOCH_SQL + " > $2::bigint " +
	"AND COALESCE(m.epoch, 0) <= $2::bigint RETURNING ed.id, ed.message_id), " +
	"counted AS (SELECT message_id, count(*) AS n FROM gone GROUP BY message_id), " +
	"fixed AS (UPDATE chat_messages m SET edit_count = m.edit_count - c.n, " +
	"edited_at = (SELECT max(e.created_at) FROM chat_message_edits e " +
	"WHERE e.message_id = m.id AND e.id NOT IN (SELECT id FROM gone)) " +
	"FROM counted c WHERE m.id = c.message_id RETURNING m.id) " +
	"SELECT count(*)::text FROM gone"

// Sealed messages (tombstones too: they keep their epoch) of the later epochs; their edits
// cascade and their attachments lose the message, so the sweeper deletes them.
DATABASE_ROOM_LOG_TRUNCATE_MESSAGES_SQL ::
	"WITH d AS (DELETE FROM chat_messages WHERE room_id = $1::bigint " +
	"AND epoch > $2::bigint RETURNING 1) SELECT count(*)::text FROM d"

// $1 the room, $2 the members wanted (a Postgres array literal). One row per change: 'a' for a
// member added, 'r' for one removed (whose read marker goes too).
DATABASE_ROOM_LOG_TRUNCATE_MEMBERS_SQL ::
	"WITH wanted AS (SELECT unnest($2::bigint[]) AS user_id), " +
	"removed AS (DELETE FROM room_members rm WHERE rm.room_id = $1::bigint " +
	"AND rm.user_id NOT IN (SELECT user_id FROM wanted) RETURNING rm.user_id), " +
	"unmarked AS (DELETE FROM room_read_markers WHERE room_id = $1::bigint " +
	"AND user_id IN (SELECT user_id FROM removed)), " +
	"added AS (INSERT INTO room_members (room_id, user_id) SELECT $1::bigint, w.user_id " +
	"FROM wanted w JOIN users u ON u.id = w.user_id ON CONFLICT DO NOTHING RETURNING user_id) " +
	"SELECT 'r', user_id::text FROM removed UNION ALL SELECT 'a', user_id::text FROM added"

databaseExecuteRoomLogRepair :: proc(
	conn: pg.Conn,
	request: common.DatabaseRoomLogRepairRequest,
) -> common.DatabaseQueryResponse {
	switch request.action {
	case .Status:
		return databaseRoomLogRepairStatus(conn, request)
	case .Truncate:
		return databaseRoomLogRepairTruncate(conn, request)
	}
	return databaseSuccess(common.DatabaseRoomLogRepairResult{outcome = .UnknownRoom})
}

// The rooms a request names: whether the requester is an admin, and each room with its flag.
@(private = "file")
RoomLogRepairRoom :: struct {
	id:        int,
	encrypted: bool,
}

@(private = "file")
databaseRoomLogRepairRooms :: proc(
	conn: pg.Conn,
	actorUserID, roomID: int,
) -> (
	isAdmin: bool,
	rooms: [dynamic]RoomLogRepairRoom,
	ok: bool,
) {
	actorText := fmt.aprintf("%d", actorUserID)
	defer delete(actorText)
	roomText := fmt.aprintf("%d", roomID)
	defer delete(roomText)
	result := databaseRoomLogQuery(conn, DATABASE_ROOM_LOG_REPAIR_ROOMS_SQL, {actorText, roomText})
	if result == nil {
		return false, nil, false
	}
	defer pg.clear(result)
	if pg.result_status(result) != .Tuples_OK || pg.n_tuples(result) < 1 {
		return false, nil, false
	}
	isAdmin = databaseGetBool(result, 0, 0)
	rooms = make([dynamic]RoomLogRepairRoom, 0, int(pg.n_tuples(result)))
	for row in 0 ..< pg.n_tuples(result) {
		if pg.get_is_null(result, row, 1) {
			continue
		}
		append(
			&rooms,
			RoomLogRepairRoom {
				id = databaseGetIntOrZero(result, row, 1),
				encrypted = databaseGetBool(result, row, 2),
			},
		)
	}
	return isAdmin, rooms, true
}

// Replays roomID's stored log (the caller holds the room's row, whose head is storedVersion).
// With keepState, state is the replayed state at status.goodVersion (owned); otherwise it is
// freed. ok is false only for a query failure.
databaseRoomLogRepairInspect :: proc(
	conn: pg.Conn,
	roomID, storedVersion: int,
	serverIdentityPublicKey: common.IdentityPublicKeyBytes,
	keepState := false,
) -> (
	status: common.RoomLogStatus,
	state: common.RoomLogState,
	ok: bool,
) {
	roomText := fmt.aprintf("%d", roomID)
	defer delete(roomText)
	result := databaseRoomLogQuery(conn, DATABASE_ROOM_LOG_ENTRIES_SQL, {roomText})
	if result == nil {
		return {}, {}, false
	}
	defer pg.clear(result)
	if pg.result_status(result) != .Tuples_OK {
		return {}, {}, false
	}
	status.roomId = roomID
	status.storedVersion = storedVersion
	state = common.RoomLogState_init(roomID)
	ctx := common.RoomLogContext {
		serverIdentityPublicKey = serverIdentityPublicKey,
	}
	for row in 0 ..< pg.n_tuples(result) {
		status.entryCount += 1
		if status.failingVersion != 0 {
			continue
		}
		version := databaseGetIntOrZero(result, row, 0)
		if version != status.goodVersion + 1 {
			status.failingVersion = version
			status.error = .VersionNotNext
			continue
		}
		entry, entryOK := databaseRoomLogHexBytes(result, row, 1)
		if !entryOK {
			status.failingVersion = version
			status.error = .Truncated
			continue
		}
		_, applyErr := common.RoomLogState_apply(&state, entry, ctx)
		delete(entry)
		if applyErr != .None {
			status.failingVersion = version
			status.error = applyErr
			continue
		}
		status.goodVersion = version
	}
	if !keepState {
		common.RoomLogState_deinit(&state)
	}
	return status, state, true
}

// What a damaged log's [RoomLog] line and the admin UI say about it.
roomLogStatusDescription :: proc(
	status: common.RoomLogStatus,
	allocator := context.allocator,
) -> string {
	if status.failingVersion != 0 {
		return fmt.aprintf(
			"version %d does not replay (%v); it replays to version %d of %d stored entries, " +
			"and the room's head is version %d",
			status.failingVersion,
			status.error,
			status.goodVersion,
			status.entryCount,
			status.storedVersion,
			allocator = allocator,
		)
	}
	return fmt.aprintf(
		"its %d stored entries replay, but the room's head is version %d",
		status.entryCount,
		status.storedVersion,
		allocator = allocator,
	)
}

// A replay inside an append, removal or ban found roomID's log damaged (the caller holds the
// room): writes the line an operator needs, with the version to truncate to.
databaseRoomLogReportDamage :: proc(
	conn: pg.Conn,
	roomID, storedVersion: int,
	serverIdentityPublicKey: common.IdentityPublicKeyBytes,
) {
	status, _, ok := databaseRoomLogRepairInspect(
		conn,
		roomID,
		storedVersion,
		serverIdentityPublicKey,
	)
	if !ok {
		return
	}
	description := roomLogStatusDescription(status)
	defer delete(description)
	if status.goodVersion == 0 {
		fmt.eprintfln(
			"[RoomLog] Room %d's member log is damaged: %s. No version replays; delete the room.",
			roomID,
			description,
		)
		return
	}
	fmt.eprintfln(
		"[RoomLog] Room %d's member log is damaged: %s. Truncate it to version %d " +
		"(Server settings, Admin, Member logs; or deploy/sql/truncate-room-log.sql " +
		"-v room_id=%d -v to_version=%d, then restart the server).",
		roomID,
		description,
		status.goodVersion,
		roomID,
		status.goodVersion,
	)
}

// Locks roomID for a status and replays it. found is false for a room no longer encrypted.
@(private = "file")
databaseRoomLogRepairStatusOf :: proc(
	conn: pg.Conn,
	roomID: int,
	serverIdentityPublicKey: common.IdentityPublicKeyBytes,
) -> (
	status: common.RoomLogStatus,
	found: bool,
	ok: bool,
) {
	transaction, beginOK := databaseRoomLogBegin(conn)
	if !beginOK {
		return {}, false, false
	}
	defer databaseRoomLogRollback(conn, transaction)
	roomText := fmt.aprintf("%d", roomID)
	defer delete(roomText)
	locked := databaseRoomLogQuery(conn, DATABASE_ROOM_LOG_REPAIR_STATUS_LOCK_SQL, {roomText})
	if locked == nil {
		return {}, false, false
	}
	if pg.result_status(locked) != .Tuples_OK {
		pg.clear(locked)
		return {}, false, false
	}
	if pg.n_tuples(locked) == 0 {
		pg.clear(locked)
		return {}, false, true
	}
	storedVersion := databaseGetIntOrZero(locked, 0, 0)
	pg.clear(locked)
	inspected, _, inspectOK := databaseRoomLogRepairInspect(
		conn,
		roomID,
		storedVersion,
		serverIdentityPublicKey,
	)
	return inspected, inspectOK, inspectOK
}

@(private = "file")
databaseRoomLogRepairStatus :: proc(
	conn: pg.Conn,
	request: common.DatabaseRoomLogRepairRequest,
) -> common.DatabaseQueryResponse {
	isAdmin, rooms, roomsOK := databaseRoomLogRepairRooms(
		conn,
		request.actorUserId,
		request.roomId,
	)
	defer delete(rooms)
	if !roomsOK {
		return databaseConnectionError(conn)
	}
	if !isAdmin {
		return databaseSuccess(common.DatabaseRoomLogRepairResult{outcome = .NotAdmin})
	}
	if request.roomId > 0 {
		if len(rooms) == 0 {
			return databaseSuccess(common.DatabaseRoomLogRepairResult{outcome = .UnknownRoom})
		}
		if !rooms[0].encrypted {
			return databaseSuccess(common.DatabaseRoomLogRepairResult{outcome = .NotEncrypted})
		}
	}
	result := common.DatabaseRoomLogRepairResult {
		outcome  = .Applied,
		statuses = make([dynamic]common.RoomLogStatus, 0, 1),
	}
	for room in rooms {
		status, found, ok := databaseRoomLogRepairStatusOf(
			conn,
			room.id,
			request.serverIdentityPublicKey,
		)
		if !ok {
			common.DatabaseRoomLogRepairResult_deinit(&result)
			return databaseConnectionError(conn)
		}
		if !found {
			continue // Deleted since the list was read
		}
		result.checkedRooms += 1
		damaged := common.roomLogStatusIsDamaged(status)
		if damaged {
			result.damagedRooms += 1
		}
		if request.roomId > 0 ||
		   (damaged && len(result.statuses) < common.ROOM_LOG_STATUS_ROOMS_MAX) {
			append(&result.statuses, status)
		}
	}
	if request.roomId > 0 && len(result.statuses) == 0 {
		common.DatabaseRoomLogRepairResult_deinit(&result)
		return databaseSuccess(common.DatabaseRoomLogRepairResult{outcome = .UnknownRoom})
	}
	return databaseSuccess(result)
}

@(private = "file")
databaseRoomLogRepairTruncate :: proc(
	conn: pg.Conn,
	request: common.DatabaseRoomLogRepairRequest,
) -> common.DatabaseQueryResponse {
	transaction, beginOK := databaseRoomLogBegin(conn)
	if !beginOK {
		return databaseConnectionError(conn)
	}
	result, failed := databaseRoomLogTruncateInTransaction(conn, request)
	if failed {
		databaseRoomLogRollback(conn, transaction)
		common.DatabaseRoomLogRepairResult_deinit(&result)
		return databaseConnectionError(conn)
	}
	if result.outcome != .Applied {
		databaseRoomLogRollback(conn, transaction)
		return databaseSuccess(result)
	}
	if !databaseRoomLogCommit(conn, transaction) {
		databaseRoomLogRollback(conn, transaction)
		common.DatabaseRoomLogRepairResult_deinit(&result)
		return databaseConnectionError(conn)
	}
	return databaseSuccess(result)
}

// Runs a statement whose one row is a count.
@(private = "file")
databaseRoomLogRepairCount :: proc(
	conn: pg.Conn,
	query: cstring,
	values: []string,
) -> (
	count: int,
	ok: bool,
) {
	result := databaseRoomLogQuery(conn, query, values)
	if result == nil {
		return 0, false
	}
	defer pg.clear(result)
	if pg.result_status(result) != .Tuples_OK || pg.n_tuples(result) != 1 {
		return 0, false
	}
	return databaseGetIntOrZero(result, 0, 0), true
}

// Everything between BEGIN and COMMIT; failed for a database error.
@(private = "file")
databaseRoomLogTruncateInTransaction :: proc(
	conn: pg.Conn,
	request: common.DatabaseRoomLogRepairRequest,
) -> (
	result: common.DatabaseRoomLogRepairResult,
	failed: bool,
) {
	isAdmin, rooms, roomsOK := databaseRoomLogRepairRooms(
		conn,
		request.actorUserId,
		request.roomId,
	)
	defer delete(rooms)
	if !roomsOK {
		return {}, true
	}
	if !isAdmin {
		return {outcome = .NotAdmin}, false
	}
	if len(rooms) == 0 {
		return {outcome = .UnknownRoom}, false
	}
	if !rooms[0].encrypted {
		return {outcome = .NotEncrypted}, false
	}
	actorText := fmt.aprintf("%d", request.actorUserId)
	defer delete(actorText)
	roomText := fmt.aprintf("%d", request.roomId)
	defer delete(roomText)
	locked := databaseRoomLogQuery(conn, DATABASE_ROOM_LOG_REPAIR_LOCK_SQL, {actorText, roomText})
	if locked == nil {
		return {}, true
	}
	if pg.result_status(locked) != .Tuples_OK {
		pg.clear(locked)
		return {}, true
	}
	if pg.n_tuples(locked) == 0 {
		pg.clear(locked)
		return {outcome = .UnknownRoom}, false
	}
	storedVersion := databaseGetIntOrZero(locked, 0, 0)
	pg.clear(locked)

	status, state, inspectOK := databaseRoomLogRepairInspect(
		conn,
		request.roomId,
		storedVersion,
		request.serverIdentityPublicKey,
		keepState = true,
	)
	if !inspectOK {
		return {}, true
	}
	defer common.RoomLogState_deinit(&state)
	result.status = status
	switch {
	case !common.roomLogStatusIsDamaged(status):
		result.outcome = .NotDamaged
	case status.goodVersion == 0:
		result.outcome = .NothingToKeep
	case request.toVersion != status.goodVersion:
		result.outcome = .WrongVersion
	}
	if result.outcome != .Applied {
		return result, false
	}

	// Everyone the change concerns: the members and managers before it.
	former := databaseRoomLogQuery(conn, DATABASE_ROOM_LOG_REPAIR_MEMBERS_SQL, {roomText})
	if former == nil {
		return result, true
	}
	if pg.result_status(former) != .Tuples_OK {
		pg.clear(former)
		return result, true
	}
	result.formerUserIDs = make([dynamic]int, 0, int(pg.n_tuples(former)))
	for row in 0 ..< pg.n_tuples(former) {
		append(&result.formerUserIDs, databaseGetIntOrZero(former, row, 0))
	}
	pg.clear(former)
	slice.sort(result.formerUserIDs[:])

	versionText := fmt.aprintf("%d", request.toVersion)
	defer delete(versionText)
	counts := [4]^int {
		&result.deletedEntries,
		&result.deletedEnvelopes,
		&result.deletedEdits,
		&result.deletedMessages,
	}
	queries := [4]cstring {
		DATABASE_ROOM_LOG_TRUNCATE_ENTRIES_SQL,
		DATABASE_ROOM_LOG_TRUNCATE_ENVELOPES_SQL,
		DATABASE_ROOM_LOG_TRUNCATE_EDITS_SQL,
		DATABASE_ROOM_LOG_TRUNCATE_MESSAGES_SQL,
	}
	for query, index in queries {
		count, countOK := databaseRoomLogRepairCount(conn, query, {roomText, versionText})
		if !countOK {
			return result, true
		}
		counts[index]^ = count
	}

	result.memberUserIDs = roomLogSortedUserIDs(state.members)
	result.managerUserIDs = roomLogSortedUserIDs(state.managers)
	result.addedUserIDs = make([dynamic]int)
	result.removedUserIDs = make([dynamic]int)
	memberArray := databaseRoomLogIDArray(result.memberUserIDs[:])
	defer delete(memberArray)
	changes := databaseRoomLogQuery(
		conn,
		DATABASE_ROOM_LOG_TRUNCATE_MEMBERS_SQL,
		{roomText, memberArray},
	)
	if changes == nil {
		return result, true
	}
	if pg.result_status(changes) != .Tuples_OK {
		pg.clear(changes)
		return result, true
	}
	for row in 0 ..< pg.n_tuples(changes) {
		kind := databaseGetText(changes, row, 0)
		userID := databaseGetIntOrZero(changes, row, 1)
		if kind == "a" {
			append(&result.addedUserIDs, userID)
		} else {
			append(&result.removedUserIDs, userID)
		}
		delete(kind)
	}
	pg.clear(changes)
	slice.sort(result.addedUserIDs[:])
	slice.sort(result.removedUserIDs[:])

	managerArray := databaseRoomLogIDArray(result.managerUserIDs[:])
	defer delete(managerArray)
	if !databaseRoomLogCommand(conn, DATABASE_ROOM_LOG_SET_MANAGERS_SQL, {roomText, managerArray}) {
		return result, true
	}
	accessText := fmt.aprintf("%d", int(state.access))
	defer delete(accessText)
	if !databaseRoomLogCommand(
		conn,
		DATABASE_ROOM_LOG_HEAD_SQL,
		{roomText, versionText, accessText},
	) {
		return result, true
	}
	return result, false
}
