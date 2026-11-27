package server

import "../common"
import "core:fmt"
import "core:strings"
import "core:time"
import "shared:pg"

// Encrypted rooms' member logs (protocol 18, migration 7, e2ee-design.md 6.1, 6.2).
//
// An append is one transaction on the database worker's connection:
//
// 1. Lock the room row (FOR UPDATE) and read its flag, head version, mode, creator and the
//    requester's ManageRooms and ManageRoomMembers permissions (protocol 23) and membership.
// 2. Replay every stored entry with common.replayRoomLog (no pins: the server has none), so the
//    state it validates against is the log's, never room_members. A stored log that does not
//    replay, or whose head is not rooms.log_version, refuses every append (Damaged).
// 3. Validate the new entry with RoomLogState_validate. The server's "pins" are the accounts'
//    users.public_key: every identity key an entry names must be the named account's own key,
//    and an account without one cannot be named.
// 4. Check the server's own rules of design 5.1 on top (below).
// 5. Store the entry, move rooms.log_version, apply it to room_members (and room_log_managers,
//    and rooms.access for SetAccess), and commit.
//
// The server's rules: every signed entry's actor is the requester. Create needs ManageRooms
// (protocol 23; the admin role before it) and the room's creator, on a room at version 0, with
// the room's own access and history. Add needs ManageMembers in the room (protocol 24: the
// server's ManageRoomMembers, an admin, or a member's room grant;
// database_room_permissions.odin), or membership of a Member invite room (room_members).
// SetAccess needs ManageRooms. A Remove signed by a manager, a
// Leave, and the manager changes need nothing beyond the log's rules. Unsigned entries come
// only from the server itself (databaseExecuteServerRoomLogRemove, for a ClientRemoveRoomMember
// of an account holding ManageRoomMembers, and protocol 32's ban, databaseRoomLogRemoveBanned,
// which runs the same removal for every encrypted room the banned account is a member of and,
// since protocol 33 (#195), then removes it as a manager with an unsigned RemoveManager).
//
// Replaying on every append costs one signature check per stored entry; a room's log grows by
// one entry per membership change, so this stays small next to the round trip. Nothing here
// allocates from the temporary allocator.

// $1 the requester, $2 the room. No row for a room that does not exist.
DATABASE_ROOM_LOG_LOCK_SQL ::
	"SELECT r.encrypted::text, r.log_version::text, r.access::text, " +
	"r.history_visibility::text, COALESCE(r.created_by_user_id, 0)::text, " +
	"(" + DATABASE_ACTOR_MANAGES_ROOMS_SQL + ")::text, " +
	"EXISTS (SELECT 1 FROM room_members rm WHERE rm.room_id = r.id " +
	"AND rm.user_id = $1::bigint)::text, " +
	"((" + DATABASE_ROOM_PERMISSIONS_OPEN_SQL + "$1" + DATABASE_ROOM_PERMISSIONS_ROOM_SQL +
	"r.id" + DATABASE_ROOM_PERMISSIONS_CLOSE_SQL + " & " +
	DATABASE_ROOM_PERMISSION_MANAGE_MEMBERS_SQL + ") <> 0)::text " +
	"FROM rooms r WHERE r.id = $2::bigint FOR UPDATE"

// A ban's lock (protocol 32, #72) does not wait: a room another connection holds is reported
// to the admin instead of holding up the database worker.
DATABASE_ROOM_LOG_LOCK_NOWAIT_SQL :: DATABASE_ROOM_LOG_LOCK_SQL + " NOWAIT"

// $1 the banned account: the encrypted rooms it is a member or (protocol 33, #195) a log
// manager of, in the order a ban locks them.
DATABASE_ROOM_LOG_BANNED_ROOMS_SQL ::
	"SELECT r.id::text FROM rooms r WHERE r.encrypted AND (" +
	"EXISTS (SELECT 1 FROM room_members rm WHERE rm.room_id = r.id " +
	"AND rm.user_id = $1::bigint) OR " +
	"EXISTS (SELECT 1 FROM room_log_managers m WHERE m.room_id = r.id " +
	"AND m.user_id = $1::bigint)) ORDER BY r.id"

// PostgreSQL's lock_not_available, what a NOWAIT lock of a held row fails with.
DATABASE_LOCK_NOT_AVAILABLE_SQLSTATE :: "55P03"

// Ordered by the column itself: the output column of the same name is text.
DATABASE_ROOM_LOG_ENTRIES_SQL ::
	"SELECT e.version::text, encode(e.entry, 'hex') FROM room_log_entries e " +
	"WHERE e.room_id = $1::bigint ORDER BY e.version"

// The identity keys of the accounts in $1 (a Postgres array literal); accounts without a key
// are left out, like unknown ones.
DATABASE_ROOM_LOG_KEYS_SQL ::
	"SELECT id::text, encode(public_key, 'hex'), restricted::text FROM users " +
	"WHERE id = ANY($1::bigint[]) AND public_key IS NOT NULL"

DATABASE_ROOM_LOG_INSERT_SQL ::
	"INSERT INTO room_log_entries (room_id, version, entry) " +
	"VALUES ($1::bigint, $2::bigint, decode($3::text, 'hex'))"

// $3 is the room's access after the entry (unchanged unless the entry is a SetAccess).
DATABASE_ROOM_LOG_HEAD_SQL ::
	"UPDATE rooms SET log_version = $2::bigint, access = $3::smallint WHERE id = $1::bigint"

DATABASE_ROOM_LOG_ADD_MEMBER_SQL ::
	"INSERT INTO room_members (room_id, user_id) VALUES ($1::bigint, $2::bigint) " +
	"ON CONFLICT DO NOTHING RETURNING user_id::text"

// Like a protocol 15 removal, the read marker goes too, so someone added again starts over.
DATABASE_ROOM_LOG_REMOVE_MEMBER_SQL ::
	"WITH changed AS (DELETE FROM room_members WHERE room_id = $1::bigint " +
	"AND user_id = $2::bigint RETURNING user_id), " +
	"unmarked AS (DELETE FROM room_read_markers WHERE room_id = $1::bigint " +
	"AND user_id = $2::bigint AND EXISTS (SELECT 1 FROM changed)) " +
	"SELECT user_id::text FROM changed"

// Makes room_log_managers the set $2 (a Postgres array literal).
DATABASE_ROOM_LOG_SET_MANAGERS_SQL ::
	"WITH wanted AS (SELECT unnest($2::bigint[]) AS user_id), " +
	"removed AS (DELETE FROM room_log_managers m WHERE m.room_id = $1::bigint " +
	"AND m.user_id NOT IN (SELECT user_id FROM wanted)) " +
	"INSERT INTO room_log_managers (room_id, user_id) SELECT $1::bigint, w.user_id " +
	"FROM wanted w JOIN users u ON u.id = w.user_id ON CONFLICT DO NOTHING"

// $1 the requester, $2 the room, $3 afterVersion, $4 the page size plus one. Members, managers
// and accounts holding ManageRooms or ManageRoomMembers (protocol 23) may read; anyone else,
// and every request for a room that does not exist, reads as not allowed. One row with NULL
// entry columns when there is nothing to send.
DATABASE_FETCH_ROOM_LOG_SQL ::
	"WITH room AS (SELECT id, encrypted, log_version FROM rooms WHERE id = $2::bigint), " +
	"allowed AS (SELECT EXISTS (SELECT 1 FROM room) AND (" +
	"" + DATABASE_ACTOR_MANAGES_ROOMS_SQL + " OR " + DATABASE_ACTOR_MANAGES_ROOM_MEMBERS_SQL +
	" " +
	"OR EXISTS (SELECT 1 FROM room_members WHERE room_id = $2::bigint " +
	"AND user_id = $1::bigint) " +
	"OR EXISTS (SELECT 1 FROM room_log_managers WHERE room_id = $2::bigint " +
	"AND user_id = $1::bigint)) AS ok) " +
	"SELECT (SELECT ok FROM allowed)::text, " +
	"COALESCE((SELECT encrypted FROM room), false)::text, " +
	"COALESCE((SELECT log_version FROM room), 0)::text, e.version::text, " +
	"encode(e.entry, 'hex') FROM (SELECT 1) AS one LEFT JOIN LATERAL (" +
	"SELECT version, entry FROM room_log_entries WHERE room_id = $2::bigint " +
	"AND version > $3::bigint AND (SELECT ok FROM allowed) " +
	"ORDER BY version LIMIT $4::bigint) e ON true ORDER BY e.version"

// What the lock statement read.
@(private = "file")
RoomLogLockedRoom :: struct {
	found:             bool,
	encrypted:         bool,
	logVersion:        int,
	access:            common.RoomAccess,
	historyVisibility: common.RoomHistoryVisibility,
	createdBy:         int,
	actorManagesRooms:   bool,
	actorIsMember:       bool,
	actorManagesMembers: bool,
}

// The accounts' identity keys, the server's stand-in for pins during validation.
@(private = "file")
RoomLogKeyTable :: struct {
	keys:       map[int]common.IdentityPublicKeyBytes,
	// Protocol 25 (D11): the named accounts that are restricted.
	restricted: map[int]bool,
}

// A named account without a key reports a zero pin, so any key the entry names mismatches.
@(private = "file")
roomLogKeyTableLookup :: proc(
	userData: rawptr,
	userID: int,
) -> (
	identityKey: common.IdentityPublicKeyBytes,
	pinned: bool,
) {
	table := (^RoomLogKeyTable)(userData)
	key, found := table.keys[userID]
	if !found {
		return {}, true
	}
	return key, true
}

@(private)
databaseRoomLogExec :: proc(conn: pg.Conn, query: cstring) -> bool {
	result := pg.exec(conn, query)
	if result == nil {
		return false
	}
	defer pg.clear(result)
	return pg.result_status(result) == .Command_OK
}

// A transaction of its own, or a savepoint inside the caller's (the SQL tests run every test
// in one transaction they roll back; a ban, database_admin.odin, uses it for its own).
RoomLogTransaction :: struct {
	nested: bool,
}

databaseRoomLogBegin :: proc(conn: pg.Conn) -> (transaction: RoomLogTransaction, ok: bool) {
	transaction.nested = pg.transaction_status(conn) == .In_Trans
	if transaction.nested {
		return transaction, databaseRoomLogExec(conn, "SAVEPOINT haychat_room_log")
	}
	return transaction, databaseRoomLogExec(conn, "BEGIN")
}

databaseRoomLogCommit :: proc(conn: pg.Conn, transaction: RoomLogTransaction) -> bool {
	if transaction.nested {
		return databaseRoomLogExec(conn, "RELEASE SAVEPOINT haychat_room_log")
	}
	return databaseRoomLogExec(conn, "COMMIT")
}

databaseRoomLogRollback :: proc(conn: pg.Conn, transaction: RoomLogTransaction) {
	if transaction.nested {
		_ = databaseRoomLogExec(conn, "ROLLBACK TO SAVEPOINT haychat_room_log")
		_ = databaseRoomLogExec(conn, "RELEASE SAVEPOINT haychat_room_log")
		return
	}
	_ = databaseRoomLogExec(conn, "ROLLBACK")
}

// Runs a statement with text parameters. The caller clears a non-nil result.
@(private)
databaseRoomLogQuery :: proc(conn: pg.Conn, query: cstring, values: []string) -> pg.Result {
	params := make([][^]byte, len(values))
	defer delete(params)
	cstrings := make([]cstring, len(values))
	defer {
		for value in cstrings {
			delete(value)
		}
		delete(cstrings)
	}
	for value, index in values {
		cstrings[index] = strings.clone_to_cstring(value)
		params[index] = transmute([^]byte)cstrings[index]
	}
	return databaseExecParams(conn, query, params)
}

// A Postgres array literal of ids, "{1,2,3}". The caller frees it.
@(private)
databaseRoomLogIDArray :: proc(ids: []int) -> string {
	builder := strings.builder_make()
	strings.write_byte(&builder, '{')
	for id, index in ids {
		if index > 0 {
			strings.write_byte(&builder, ',')
		}
		strings.write_int(&builder, id)
	}
	strings.write_byte(&builder, '}')
	return strings.to_string(builder)
}

// Locks roomID's row and reads it. With noWait a row another connection holds is not waited
// for: locked is true (ok too, nothing found), and the caller's transaction is aborted until it
// rolls back to a savepoint.
@(private = "file")
databaseRoomLogLock :: proc(
	conn: pg.Conn,
	actorUserID, roomID: int,
	noWait := false,
) -> (
	room: RoomLogLockedRoom,
	ok: bool,
	locked: bool,
) {
	actorText := fmt.aprintf("%d", actorUserID)
	defer delete(actorText)
	roomText := fmt.aprintf("%d", roomID)
	defer delete(roomText)
	query: cstring = noWait ? DATABASE_ROOM_LOG_LOCK_NOWAIT_SQL : DATABASE_ROOM_LOG_LOCK_SQL
	result := databaseRoomLogQuery(conn, query, {actorText, roomText})
	if result == nil {
		return {}, false, false
	}
	defer pg.clear(result)
	if pg.result_status(result) != .Tuples_OK {
		state := string(pg.result_error_field(result, .SQL_State))
		if noWait && state == DATABASE_LOCK_NOT_AVAILABLE_SQLSTATE {
			return {}, true, true
		}
		return {}, false, false
	}
	if pg.n_tuples(result) == 0 {
		return {}, true, false
	}
	room.found = true
	room.encrypted = databaseGetBool(result, 0, 0)
	room.logVersion = databaseGetIntOrZero(result, 0, 1)
	room.access = databaseGetRoomAccess(result, 0, 2)
	visibility := common.RoomHistoryVisibility(databaseGetIntOrZero(result, 0, 3))
	if !common.roomHistoryVisibilityIsSupported(visibility) {
		visibility = .FromJoin
	}
	room.historyVisibility = visibility
	room.createdBy = databaseGetIntOrZero(result, 0, 4)
	room.actorManagesRooms = databaseGetBool(result, 0, 5)
	room.actorIsMember = databaseGetBool(result, 0, 6)
	room.actorManagesMembers = databaseGetBool(result, 0, 7)
	return room, true, false
}

// The stored entries of roomID in version order (owned; free with databaseRoomLogFreeEntries).
// ok is false for a query failure; damaged is true for a row that is not hex or a version that
// is not the next.
@(private = "file")
databaseRoomLogLoadEntries :: proc(
	conn: pg.Conn,
	roomID: int,
) -> (
	entries: [dynamic][]u8,
	ok: bool,
	damaged: bool,
) {
	roomText := fmt.aprintf("%d", roomID)
	defer delete(roomText)
	result := databaseRoomLogQuery(conn, DATABASE_ROOM_LOG_ENTRIES_SQL, {roomText})
	if result == nil {
		return nil, false, false
	}
	defer pg.clear(result)
	if pg.result_status(result) != .Tuples_OK {
		return nil, false, false
	}
	entries = make([dynamic][]u8, 0, int(pg.n_tuples(result)))
	for row in 0 ..< pg.n_tuples(result) {
		version := databaseGetIntOrZero(result, row, 0)
		entry, entryOK := databaseRoomLogHexBytes(result, row, 1)
		if !entryOK || version != len(entries) + 1 {
			delete(entry)
			return entries, true, true
		}
		append(&entries, entry)
	}
	return entries, true, false
}

@(private)
databaseRoomLogHexBytes :: proc(result: pg.Result, row, column: i32) -> ([]u8, bool) {
	text := databaseGetText(result, row, column)
	defer delete(text)
	if len(text) == 0 || len(text) % 2 != 0 {
		return nil, false
	}
	bytes := make([]u8, len(text) / 2)
	if !common.decodeHexIntoBuffer(text, bytes) {
		delete(bytes)
		return nil, false
	}
	return bytes, true
}

@(private = "file")
databaseRoomLogFreeEntries :: proc(entries: ^[dynamic][]u8) {
	for entry in entries {
		delete(entry)
	}
	delete(entries^)
	entries^ = nil
}

// Replays the stored log of room. damaged is true when it does not replay or its head is not
// the room's log_version; the state is then freed.
@(private = "file")
databaseRoomLogReplay :: proc(
	conn: pg.Conn,
	room: RoomLogLockedRoom,
	roomID: int,
	serverIdentityPublicKey: common.IdentityPublicKeyBytes,
) -> (
	state: common.RoomLogState,
	ok: bool,
	damaged: bool,
) {
	entries, loadOK, loadDamaged := databaseRoomLogLoadEntries(conn, roomID)
	defer databaseRoomLogFreeEntries(&entries)
	if !loadOK {
		return {}, false, false
	}
	if loadDamaged || len(entries) != room.logVersion {
		databaseRoomLogReportDamage(conn, roomID, room.logVersion, serverIdentityPublicKey)
		return {}, true, true
	}
	ctx := common.RoomLogContext {
		serverIdentityPublicKey = serverIdentityPublicKey,
	}
	if len(entries) == 0 {
		return common.RoomLogState_init(roomID), true, false
	}
	replayed, replayErr, _ := common.replayRoomLog(roomID, entries[:], ctx)
	if replayErr != .None {
		// Protocol 34 (#196): say which version to truncate to.
		databaseRoomLogReportDamage(conn, roomID, room.logVersion, serverIdentityPublicKey)
		return {}, true, true
	}
	return replayed, true, false
}

// Reads the identity keys of userIDs into table.keys.
@(private = "file")
databaseRoomLogLoadKeys :: proc(conn: pg.Conn, userIDs: []int, table: ^RoomLogKeyTable) -> bool {
	idArray := databaseRoomLogIDArray(userIDs)
	defer delete(idArray)
	result := databaseRoomLogQuery(conn, DATABASE_ROOM_LOG_KEYS_SQL, {idArray})
	if result == nil {
		return false
	}
	defer pg.clear(result)
	if pg.result_status(result) != .Tuples_OK {
		return false
	}
	for row in 0 ..< pg.n_tuples(result) {
		userID, idOK := databaseGetInt(result, row, 0)
		key: common.IdentityPublicKeyBytes
		if idOK && databaseGetHexBytes(result, row, 1, key[:]) {
			table.keys[userID] = key
			if databaseGetBool(result, row, 2) {
				table.restricted[userID] = true
			}
		}
	}
	return true
}

// The sorted keys of a log state's member or manager map, owned.
@(private)
roomLogSortedUserIDs :: proc(users: map[int]common.IdentityPublicKeyBytes) -> [dynamic]int {
	ids := make([dynamic]int, 0, len(users))
	for userID in users {
		append(&ids, userID)
	}
	for index in 1 ..< len(ids) {
		for cursor := index; cursor > 0 && ids[cursor - 1] > ids[cursor]; cursor -= 1 {
			ids[cursor - 1], ids[cursor] = ids[cursor], ids[cursor - 1]
		}
	}
	return ids
}

// What storing an applied entry changed.
@(private = "file")
RoomLogStored :: struct {
	ok:                bool,
	membershipChanged: bool,
}

// Stores entry (already applied to state, which is the state after it) and applies it to the
// room's tables. Runs inside the caller's transaction.
@(private = "file")
databaseRoomLogStore :: proc(
	conn: pg.Conn,
	roomID: int,
	entry: common.RoomLogEntry,
	data: []u8,
	state: ^common.RoomLogState,
) -> (
	stored: RoomLogStored,
) {
	roomText := fmt.aprintf("%d", roomID)
	defer delete(roomText)
	versionText := fmt.aprintf("%d", entry.version)
	defer delete(versionText)
	entryHex := common.encodeBytesToHex(data)
	defer delete(entryHex)
	insertValues := []string{roomText, versionText, entryHex}
	if !databaseRoomLogCommand(conn, DATABASE_ROOM_LOG_INSERT_SQL, insertValues) {
		return
	}
	accessText := fmt.aprintf("%d", int(state.access))
	defer delete(accessText)
	headValues := []string{roomText, versionText, accessText}
	if !databaseRoomLogCommand(conn, DATABASE_ROOM_LOG_HEAD_SQL, headValues) {
		return
	}

	memberID := 0
	adding := false
	#partial switch entry.action {
	case .Create:
		if entry.settings.creatorJoins {
			memberID = entry.actorUserID
			adding = true
		}
	case .Add:
		memberID = entry.targetUserID
		adding = true
	case .Remove, .Leave:
		memberID = entry.targetUserID
	}
	if memberID > 0 {
		memberText := fmt.aprintf("%d", memberID)
		defer delete(memberText)
		query: cstring = DATABASE_ROOM_LOG_REMOVE_MEMBER_SQL
		if adding {
			query = DATABASE_ROOM_LOG_ADD_MEMBER_SQL
		}
		result := databaseRoomLogQuery(conn, query, {roomText, memberText})
		if result == nil {
			return
		}
		statusOK := pg.result_status(result) == .Tuples_OK
		stored.membershipChanged = statusOK && pg.n_tuples(result) > 0
		pg.clear(result)
		if !statusOK {
			return
		}
	}

	if entry.action == .Create || entry.action == .AddManager || entry.action == .RemoveManager {
		managers := roomLogSortedUserIDs(state.managers)
		defer delete(managers)
		managerArray := databaseRoomLogIDArray(managers[:])
		defer delete(managerArray)
		result := databaseRoomLogQuery(
			conn,
			DATABASE_ROOM_LOG_SET_MANAGERS_SQL,
			{roomText, managerArray},
		)
		if result == nil {
			return
		}
		statusOK := pg.result_status(result) == .Command_OK
		pg.clear(result)
		if !statusOK {
			return
		}
	}
	stored.ok = true
	return
}

@(private)
databaseRoomLogCommand :: proc(conn: pg.Conn, query: cstring, values: []string) -> bool {
	result := databaseRoomLogQuery(conn, query, values)
	if result == nil {
		return false
	}
	defer pg.clear(result)
	return pg.result_status(result) == .Command_OK
}

// Which outcome a log rule's refusal is.
roomLogAppendOutcomeFor :: proc(err: common.RoomLogError) -> common.RoomLogAppendOutcome {
	#partial switch err {
	case .None:
		return .Applied
	case .VersionNotNext, .BadPrevHash:
		return .Conflict
	case .NotAuthorized, .Unsigned, .MalformedUnsigned:
		return .NotAuthorized
	case .RoomFull:
		return .RoomFull
	}
	return .Invalid
}

// The server's own rules (design 5.1) for a signed entry the log's rules accepted.
roomLogServerAllows :: proc(
	room: RoomLogLockedRoomView,
	actorUserID: int,
	entry: common.RoomLogEntry,
) -> common.RoomLogAppendOutcome {
	if entry.actorUserID != actorUserID {
		return .NotAuthorized
	}
	#partial switch entry.action {
	case .Create:
		if !room.actorManagesRooms || room.createdBy != actorUserID {
			return .NotAuthorized
		}
		if int(entry.settings.access) != int(room.access) ||
		   int(entry.settings.historyVisibility) != int(room.historyVisibility) {
			return .Invalid
		}
	case .Add:
		if !room.actorManagesMembers && !(room.access == .MemberInvite && room.actorIsMember) {
			return .NotAuthorized
		}
		// Protocol 25 (D11): only member managers add a restricted account.
		if room.targetRestricted && !room.actorManagesMembers {
			return .NotAuthorized
		}
	case .SetAccess:
		if !room.actorManagesRooms {
			return .NotAuthorized
		}
	}
	return .Applied
}

// The parts of the locked room the server's rules read, for roomLogServerAllows (and its test).
RoomLogLockedRoomView :: struct {
	access:              common.RoomAccess,
	historyVisibility:   common.RoomHistoryVisibility,
	createdBy:           int,
	actorManagesRooms:   bool,
	actorIsMember:       bool,
	actorManagesMembers: bool,
	targetRestricted:    bool,
}

databaseExecuteAppendRoomLog :: proc(
	conn: pg.Conn,
	request: common.DatabaseAppendRoomLogRequest,
) -> common.DatabaseQueryResponse {
	if len(request.entry) == 0 || len(request.entry) > common.ROOM_LOG_ENTRY_MAX_BYTES {
		return databaseSuccess(
			common.DatabaseAppendRoomLogResult{outcome = .Invalid, logError = .TooLarge},
		)
	}
	transaction, beginOK := databaseRoomLogBegin(conn)
	if !beginOK {
		return databaseConnectionError(conn)
	}
	result, failure, failed := databaseAppendRoomLogInTransaction(conn, request)
	if failed {
		databaseRoomLogRollback(conn, transaction)
		return failure
	}
	if result.outcome != .Applied {
		databaseRoomLogRollback(conn, transaction)
		return databaseSuccess(result)
	}
	if !databaseRoomLogCommit(conn, transaction) {
		databaseRoomLogRollback(conn, transaction)
		delete(result.entry)
		delete(result.memberUserIDs)
		delete(result.managerUserIDs)
		return databaseConnectionError(conn)
	}
	return databaseSuccess(result)
}

// Everything between BEGIN and COMMIT. failed with failure for a database error; otherwise
// result says what happened (and owns its arrays when Applied).
@(private = "file")
databaseAppendRoomLogInTransaction :: proc(
	conn: pg.Conn,
	request: common.DatabaseAppendRoomLogRequest,
) -> (
	result: common.DatabaseAppendRoomLogResult,
	failure: common.DatabaseQueryResponse,
	failed: bool,
) {
	room, lockOK, _ := databaseRoomLogLock(conn, request.actorUserId, request.roomId)
	if !lockOK {
		return {}, databaseConnectionError(conn), true
	}
	if !room.found {
		return {outcome = .NotMember}, {}, false
	}
	if !room.encrypted {
		return {outcome = .NotEncrypted}, {}, false
	}
	state, replayOK, damaged := databaseRoomLogReplay(
		conn,
		room,
		request.roomId,
		request.serverIdentityPublicKey,
	)
	if !replayOK {
		return {}, databaseConnectionError(conn), true
	}
	if damaged {
		return {outcome = .Damaged}, {}, false
	}
	defer common.RoomLogState_deinit(&state)

	// The accounts the entry names, so their keys can stand in for pins.
	managers: [common.ROOM_LOG_MANAGERS_MAX]common.RoomLogManager
	decoded, decodeErr := common.decodeRoomLogEntry(request.entry, managers[:])
	if decodeErr != .None {
		return {outcome = .Invalid, logError = decodeErr}, {}, false
	}
	named := make([dynamic]int, 0, len(decoded.settings.managers) + 2)
	defer delete(named)
	if decoded.actorUserID > 0 {
		append(&named, decoded.actorUserID)
	}
	if decoded.targetUserID > 0 {
		append(&named, decoded.targetUserID)
	}
	for manager in decoded.settings.managers {
		append(&named, manager.userID)
	}
	table := RoomLogKeyTable {
		keys       = make(map[int]common.IdentityPublicKeyBytes),
		restricted = make(map[int]bool),
	}
	defer delete(table.keys)
	defer delete(table.restricted)
	if len(named) > 0 && !databaseRoomLogLoadKeys(conn, named[:], &table) {
		return {}, databaseConnectionError(conn), true
	}
	ctx := common.RoomLogContext {
		serverIdentityPublicKey = request.serverIdentityPublicKey,
		lookupPin               = roomLogKeyTableLookup,
		pinUserData             = &table,
	}
	entry, validateErr := common.RoomLogState_validate(&state, request.entry, ctx)
	if validateErr != .None {
		return {outcome = roomLogAppendOutcomeFor(validateErr), logError = validateErr}, {}, false
	}
	view := RoomLogLockedRoomView {
		access            = room.access,
		historyVisibility = room.historyVisibility,
		createdBy         = room.createdBy,
		actorManagesRooms   = room.actorManagesRooms,
		actorIsMember       = room.actorIsMember,
		actorManagesMembers = room.actorManagesMembers,
		targetRestricted    = table.restricted[decoded.targetUserID],
	}
	if allowed := roomLogServerAllows(view, request.actorUserId, entry); allowed != .Applied {
		return {outcome = allowed}, {}, false
	}
	if _, applyErr := common.RoomLogState_apply(&state, request.entry, ctx); applyErr != .None {
		return {outcome = roomLogAppendOutcomeFor(applyErr), logError = applyErr}, {}, false
	}
	stored := databaseRoomLogStore(conn, request.roomId, entry, request.entry, &state)
	if !stored.ok {
		return {}, databaseConnectionError(conn), true
	}
	storedEntry := make([]u8, len(request.entry))
	copy(storedEntry, request.entry)
	return common.DatabaseAppendRoomLogResult {
			outcome = .Applied,
			entry = storedEntry,
			version = entry.version,
			action = entry.action,
			targetUserId = entry.action == .Create ? entry.actorUserID : entry.targetUserID,
			membershipChanged = stored.membershipChanged,
			memberUserIDs = roomLogSortedUserIDs(state.members),
			managerUserIDs = roomLogSortedUserIDs(state.managers),
			access = common.RoomAccess(int(state.access)),
		},
		{},
		false
}

// An admin's ClientRemoveRoomMember on an encrypted room (design 6.2): the server writes the
// log's unsigned Remove entry itself and applies it, in one transaction. Removing someone who
// is not a member of the verified log changes nothing.
databaseExecuteServerRoomLogRemove :: proc(
	conn: pg.Conn,
	request: common.DatabaseRoomMemberActionRequest,
) -> common.DatabaseQueryResponse {
	transaction, beginOK := databaseRoomLogBegin(conn)
	if !beginOK {
		return databaseConnectionError(conn)
	}
	result, failure, failed, _ := databaseServerRoomLogRemoveInTransaction(conn, request)
	if failed {
		databaseRoomLogRollback(conn, transaction)
		return failure
	}
	if result.outcome != .Applied || !result.changed {
		databaseRoomLogRollback(conn, transaction)
		return databaseSuccess(result)
	}
	if !databaseRoomLogCommit(conn, transaction) {
		databaseRoomLogRollback(conn, transaction)
		delete(result.memberUserIDs)
		delete(result.logEntry)
		delete(result.managerUserIDs)
		return databaseConnectionError(conn)
	}
	return databaseSuccess(result)
}

// The removal inside the caller's transaction. locked (only with noWait) means another
// connection holds the room: nothing changed, and the transaction is aborted until the caller
// rolls back to a savepoint.
//
// With managerEntry (a ban, protocol 33, #195), a target the verified log names as a manager
// is then removed as one too: the server's unsigned RemoveManager, after the Remove when it is
// also a member, even when it is the last manager. managerEntry receives it (entry owned, nil
// when the target was no manager), and result.changed is set for either entry; result.logEntry
// is nil when the target was no member.
@(private = "file")
databaseServerRoomLogRemoveInTransaction :: proc(
	conn: pg.Conn,
	request: common.DatabaseRoomMemberActionRequest,
	noWait := false,
	managerEntry: ^RoomLogServerEntry = nil,
) -> (
	result: common.DatabaseRoomMemberActionResult,
	failure: common.DatabaseQueryResponse,
	failed: bool,
	locked: bool,
) {
	room, lockOK, roomLocked := databaseRoomLogLock(
		conn,
		request.actorUserId,
		request.roomId,
		noWait,
	)
	if !lockOK {
		return {}, databaseConnectionError(conn), true, false
	}
	if roomLocked {
		return {}, {}, false, true
	}
	// The same order of refusals as an unencrypted removal.
	if !room.actorManagesMembers {
		return {outcome = .AdminRequired}, {}, false, false
	}
	if !room.found {
		return {outcome = .UnknownRoom}, {}, false, false
	}
	if !databaseRoomLogUserExists(conn, request.targetUserId) {
		return {outcome = .UnknownUser}, {}, false, false
	}
	state, replayOK, damaged := databaseRoomLogReplay(
		conn,
		room,
		request.roomId,
		request.serverIdentityPublicKey,
	)
	if !replayOK {
		return {}, databaseConnectionError(conn), true, false
	}
	if damaged {
		return {outcome = .LogDamaged}, {}, false, false
	}
	defer common.RoomLogState_deinit(&state)
	result.outcome = .Applied
	result.access = room.access
	targetKey, isMember := state.members[request.targetUserId]
	managerKey, isManager := state.managers[request.targetUserId]
	removeManager := managerEntry != nil && isManager
	if !isMember && !removeManager {
		return result, {}, false, false
	}

	if isMember {
		written := databaseRoomLogWriteServerEntry(
			conn,
			request.roomId,
			&state,
			.Remove,
			request.targetUserId,
			targetKey,
			request.serverIdentityPublicKey,
		)
		if written.failed {
			return {}, databaseConnectionError(conn), true, false
		}
		if written.refused {
			return {outcome = .LogDamaged}, {}, false, false
		}
		result.logEntry = written.entry
		result.logVersion = written.version
	}
	if removeManager {
		written := databaseRoomLogWriteServerEntry(
			conn,
			request.roomId,
			&state,
			.RemoveManager,
			request.targetUserId,
			managerKey,
			request.serverIdentityPublicKey,
		)
		if written.failed || written.refused {
			delete(result.logEntry)
			if written.failed {
				return {}, databaseConnectionError(conn), true, false
			}
			return {outcome = .LogDamaged}, {}, false, false
		}
		managerEntry^ = written
	}
	result.changed = true
	result.memberUserIDs = roomLogSortedUserIDs(state.members)
	result.managerUserIDs = roomLogSortedUserIDs(state.managers)
	return result, {}, false, false
}

// One server entry databaseRoomLogWriteServerEntry wrote.
@(private = "file")
RoomLogServerEntry :: struct {
	entry:   []u8, // owned; nil unless written
	version: int,
	refused: bool, // the log's rules refused it: nothing was stored
	failed:  bool, // a database error: the caller's transaction must roll back
}

// Writes the server's unsigned action (Remove, or protocol 33's RemoveManager) of targetUserID
// as the next entry of state, applies it to state and stores it, inside the caller's
// transaction.
@(private = "file")
databaseRoomLogWriteServerEntry :: proc(
	conn: pg.Conn,
	roomID: int,
	state: ^common.RoomLogState,
	action: common.RoomLogAction,
	targetUserID: int,
	targetKey: common.IdentityPublicKeyBytes,
	serverIdentityPublicKey: common.IdentityPublicKeyBytes,
) -> (
	written: RoomLogServerEntry,
) {
	entry := common.RoomLogEntry {
		roomID            = roomID,
		version           = state.version + 1,
		prevHash          = state.headHash,
		action            = action,
		targetUserID      = targetUserID,
		targetIdentityKey = targetKey,
		createdAt         = u64(max(time.time_to_unix(time.now()), 0)),
	}
	buffer: [common.ROOM_LOG_ENTRY_MAX_BYTES]u8
	n, encodeErr := common.encodeRoomLogEntry(entry, buffer[:])
	if encodeErr != .None {
		return {refused = true}
	}
	ctx := common.RoomLogContext {
		serverIdentityPublicKey = serverIdentityPublicKey,
	}
	if _, applyErr := common.RoomLogState_apply(state, buffer[:n], ctx); applyErr != .None {
		return {refused = true}
	}
	if !databaseRoomLogStore(conn, roomID, entry, buffer[:n], state).ok {
		return {failed = true}
	}
	written.entry = make([]u8, n)
	copy(written.entry, buffer[:n])
	written.version = entry.version
	return
}

// A ban (protocol 32, #72), inside the ban's transaction after DATABASE_ADMIN_BAN_SQL applied:
// the server's unsigned Remove of targetUserID in every encrypted room room_members lists it
// in, exactly as an admin's ClientRemoveRoomMember writes it, and (protocol 33, #195) then its
// unsigned RemoveManager in every encrypted room whose log names it as a manager
// (room_log_managers lists it), also the last one, one savepoint per room. A room
// whose stored log does not replay (LogDamaged), that another connection holds locked (the lock
// does not wait), or that refuses the removal otherwise is left as it was and listed in
// result.failedRoomIDs: the ban still applies. A room whose verified log does not name the
// account (a row added behind the log) changes nothing and is not listed. Each removal goes to
// result.banRemovals for the router's fan-out. failed with failure only for a database error,
// after which the caller rolls the whole ban back.
databaseRoomLogRemoveBanned :: proc(
	conn: pg.Conn,
	request: common.DatabaseAdminUserRequest,
	result: ^common.DatabaseAdminUserResult,
) -> (
	failure: common.DatabaseQueryResponse,
	failed: bool,
) {
	targetText := fmt.aprintf("%d", request.targetUserId)
	defer delete(targetText)
	rooms := databaseRoomLogQuery(conn, DATABASE_ROOM_LOG_BANNED_ROOMS_SQL, {targetText})
	if rooms == nil {
		return databaseConnectionError(conn), true
	}
	if pg.result_status(rooms) != .Tuples_OK {
		pg.clear(rooms)
		return databaseConnectionError(conn), true
	}
	roomIDs := make([dynamic]int, 0, int(pg.n_tuples(rooms)))
	defer delete(roomIDs)
	for row in 0 ..< pg.n_tuples(rooms) {
		append(&roomIDs, databaseGetIntOrZero(rooms, row, 0))
	}
	pg.clear(rooms)

	for roomID in roomIDs {
		if !databaseRoomLogExec(conn, "SAVEPOINT haychat_ban_room") {
			return databaseConnectionError(conn), true
		}
		managerEntry: RoomLogServerEntry
		removal, removalFailure, removalFailed, locked := databaseServerRoomLogRemoveInTransaction(
			conn,
			common.DatabaseRoomMemberActionRequest {
				action = .Remove,
				actorUserId = request.actorUserId,
				roomId = roomID,
				targetUserId = request.targetUserId,
				serverIdentityPublicKey = request.serverIdentityPublicKey,
			},
			noWait = true,
			managerEntry = &managerEntry,
		)
		if removalFailed {
			return removalFailure, true
		}
		applied := !locked && removal.outcome == .Applied
		if !applied || !removal.changed {
			// Nothing of this room's is kept: a locked room's error aborted the transaction,
			// and the other refusals wrote nothing.
			delete(removal.memberUserIDs)
			delete(removal.logEntry)
			delete(removal.managerUserIDs)
			delete(managerEntry.entry)
			rolledBack :=
				databaseRoomLogExec(conn, "ROLLBACK TO SAVEPOINT haychat_ban_room") &&
				databaseRoomLogExec(conn, "RELEASE SAVEPOINT haychat_ban_room")
			if !rolledBack {
				return databaseConnectionError(conn), true
			}
			// A room deleted since the list was read needs nothing.
			if !applied && removal.outcome != .UnknownRoom {
				append(&result.failedRoomIDs, roomID)
			}
			continue
		}
		if !databaseRoomLogExec(conn, "RELEASE SAVEPOINT haychat_ban_room") {
			delete(removal.memberUserIDs)
			delete(removal.logEntry)
			delete(removal.managerUserIDs)
			delete(managerEntry.entry)
			return databaseConnectionError(conn), true
		}
		append(
			&result.banRemovals,
			common.DatabaseBanRoomRemoval {
				roomId = roomID,
				logEntry = removal.logEntry,
				logVersion = removal.logVersion,
				managerLogEntry = managerEntry.entry,
				managerLogVersion = managerEntry.version,
				memberUserIDs = removal.memberUserIDs,
				managerUserIDs = removal.managerUserIDs,
			},
		)
	}
	return {}, false
}

@(private = "file")
databaseRoomLogUserExists :: proc(conn: pg.Conn, userID: int) -> bool {
	userText := fmt.aprintf("%d", userID)
	defer delete(userText)
	result := databaseRoomLogQuery(
		conn,
		"SELECT 1 FROM users WHERE id = $1::bigint",
		{userText},
	)
	if result == nil {
		return false
	}
	defer pg.clear(result)
	return pg.result_status(result) == .Tuples_OK && pg.n_tuples(result) == 1
}

// Whether roomID is encrypted, for routing a removal; false for a room that does not exist.
databaseRoomIsEncrypted :: proc(conn: pg.Conn, roomID: int) -> (encrypted: bool, ok: bool) {
	roomText := fmt.aprintf("%d", roomID)
	defer delete(roomText)
	result := databaseRoomLogQuery(
		conn,
		"SELECT encrypted::text FROM rooms WHERE id = $1::bigint",
		{roomText},
	)
	if result == nil {
		return false, false
	}
	defer pg.clear(result)
	if pg.result_status(result) != .Tuples_OK {
		return false, false
	}
	if pg.n_tuples(result) == 0 {
		return false, true
	}
	return databaseGetBool(result, 0, 0), true
}

databaseExecuteFetchRoomLog :: proc(
	conn: pg.Conn,
	request: common.DatabaseFetchRoomLogRequest,
) -> common.DatabaseQueryResponse {
	actorText := fmt.aprintf("%d", request.actorUserId)
	defer delete(actorText)
	roomText := fmt.aprintf("%d", request.roomId)
	defer delete(roomText)
	afterText := fmt.aprintf("%d", max(request.afterVersion, 0))
	defer delete(afterText)
	limitText := fmt.aprintf("%d", common.ROOM_LOG_FETCH_MAX_ENTRIES + 1)
	defer delete(limitText)
	result := databaseRoomLogQuery(
		conn,
		DATABASE_FETCH_ROOM_LOG_SQL,
		{actorText, roomText, afterText, limitText},
	)
	if result == nil {
		return databaseConnectionError(conn)
	}
	defer pg.clear(result)
	if pg.result_status(result) != .Tuples_OK || pg.n_tuples(result) < 1 {
		return databaseResultError(&result)
	}
	if !databaseGetBool(result, 0, 0) {
		return databaseSuccess(common.DatabaseFetchRoomLogResult{outcome = .NotMember})
	}
	if !databaseGetBool(result, 0, 1) {
		return databaseSuccess(common.DatabaseFetchRoomLogResult{outcome = .NotEncrypted})
	}
	fetched := common.DatabaseFetchRoomLogResult {
		outcome     = .Applied,
		headVersion = databaseGetIntOrZero(result, 0, 2),
		entries     = make([dynamic][]u8),
	}
	for row in 0 ..< pg.n_tuples(result) {
		if pg.get_is_null(result, row, 3) {
			continue
		}
		if len(fetched.entries) == common.ROOM_LOG_FETCH_MAX_ENTRIES {
			fetched.hasMore = true
			break
		}
		entry, entryOK := databaseRoomLogHexBytes(result, row, 4)
		if !entryOK {
			// A row that is not an entry ends the page; the client's replay refuses the gap.
			break
		}
		append(&fetched.entries, entry)
	}
	return databaseSuccess(fetched)
}
