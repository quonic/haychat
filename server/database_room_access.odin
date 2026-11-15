package server

import "../common"
import "core:strings"
import "shared:pg"

// Room access modes (protocol 15, migration 4): who may add, remove, leave, and list a room's
// members, and the admin's list of every room. Like the admin actions (database_admin.odin),
// each request is one statement that reads who the requester is (admin, member), the room's
// mode, and the target, decides, and makes the change, so a role or membership change between
// a check and the write cannot slip through. A refusal changes nothing and names its reason
// in the first column.
//
// The rules (design 5.1), checked in this order:
//
// - Add: a room that does not exist is `unknown_room` to admins and `not_member` to anyone
//   else, so non-members learn nothing about rooms they cannot see; a requester who is neither
//   an admin nor a member is `not_member`; a Public room is `public_room` (it already includes
//   every account); an Admin invite room needs an admin (`admin_required`); the target must
//   exist (`unknown_user`). Adding a member again changes nothing.
// - Remove: admins only (`admin_required`), in every mode; then `unknown_room` and
//   `unknown_user`. Removing someone who is not a member changes nothing.
// - Leave: the requester must be a member (`not_member`, also for a missing room), and Public
//   rooms cannot be left (`public_room`).
// - Fetch: members and admins (`not_member` otherwise, `unknown_room` to admins).
//
// A removal or a leave also deletes the account's read marker for the room, so someone added
// again later counts unread messages from the new joined_at, like a new member.
//
// Encrypted rooms (protocol 18): an add or a leave is `encrypted_room` (checked after the
// requester may see the room), because their members change only through signed member log
// entries (ClientAppendRoomLog). A removal by an admin becomes the log's unsigned Remove entry,
// which database_room_log.odin writes and applies in one transaction.
//
// Every statement returns one row: outcome, whether a membership row changed, the room's
// access, and the members after the action (ascending, comma separated). Data-modifying CTEs
// do not see each other's changes, so the member list is the statement's snapshot with the
// change applied by hand.

@(private = "file")
DATABASE_ROOM_MEMBER_PREFIX_SQL ::
	"WITH actor AS (SELECT EXISTS (SELECT 1 FROM user_server_roles usr " +
	"JOIN server_roles sr ON sr.id = usr.role_id " +
	"WHERE usr.user_id = $1::bigint AND sr.name = 'admin') AS is_admin, " +
	"EXISTS (SELECT 1 FROM room_members " +
	"WHERE room_id = $2::bigint AND user_id = $1::bigint) AS is_member), " +
	"room AS (SELECT id, access, encrypted FROM rooms WHERE id = $2::bigint), " +
	"target AS (SELECT id FROM users WHERE id = $3::bigint), "

// The final select. members is how the members after the action are built from the snapshot.
@(private = "file")
DATABASE_ROOM_MEMBER_SUFFIX_SQL_START ::
	"SELECT d.outcome, EXISTS (SELECT 1 FROM changed)::text, " +
	"COALESCE((SELECT access FROM room), 1)::text, " +
	"CASE WHEN d.outcome = 'applied' THEN COALESCE((SELECT string_agg(user_id::text, ',' " +
	"ORDER BY user_id) FROM ("

@(private = "file")
DATABASE_ROOM_MEMBER_SUFFIX_SQL_END :: ") members), '') ELSE '' END FROM decision d"

@(private = "file")
DATABASE_ROOM_MEMBER_SNAPSHOT_SQL :: "SELECT user_id FROM room_members WHERE room_id = $2::bigint"

DATABASE_ROOM_ADD_MEMBER_SQL ::
	DATABASE_ROOM_MEMBER_PREFIX_SQL +
	"decision AS (SELECT CASE " +
	"WHEN NOT EXISTS (SELECT 1 FROM room) THEN " +
	"CASE WHEN (SELECT is_admin FROM actor) THEN 'unknown_room' ELSE 'not_member' END " +
	"WHEN NOT (SELECT is_admin FROM actor) AND NOT (SELECT is_member FROM actor) " +
	"THEN 'not_member' " +
	"WHEN (SELECT encrypted FROM room) THEN 'encrypted_room' " +
	"WHEN (SELECT access FROM room) = 1 THEN 'public_room' " +
	"WHEN (SELECT access FROM room) = 3 AND NOT (SELECT is_admin FROM actor) " +
	"THEN 'admin_required' " +
	"WHEN NOT EXISTS (SELECT 1 FROM target) THEN 'unknown_user' " +
	"ELSE 'applied' END AS outcome), " +
	"changed AS (INSERT INTO room_members (room_id, user_id) " +
	"SELECT $2::bigint, $3::bigint FROM decision WHERE outcome = 'applied' " +
	"ON CONFLICT DO NOTHING RETURNING user_id) " +
	DATABASE_ROOM_MEMBER_SUFFIX_SQL_START +
	DATABASE_ROOM_MEMBER_SNAPSHOT_SQL +
	" UNION SELECT user_id FROM changed" +
	DATABASE_ROOM_MEMBER_SUFFIX_SQL_END

// The membership and read marker deletes shared by Remove ($3 the target) and Leave ($3 the
// requester).
@(private = "file")
DATABASE_ROOM_MEMBER_DELETE_SQL ::
	"changed AS (DELETE FROM room_members rm USING decision d " +
	"WHERE rm.room_id = $2::bigint AND rm.user_id = $3::bigint AND d.outcome = 'applied' " +
	"RETURNING rm.user_id), " +
	"unmarked AS (DELETE FROM room_read_markers m USING decision d " +
	"WHERE m.room_id = $2::bigint AND m.user_id = $3::bigint AND d.outcome = 'applied') " +
	DATABASE_ROOM_MEMBER_SUFFIX_SQL_START +
	DATABASE_ROOM_MEMBER_SNAPSHOT_SQL +
	" EXCEPT SELECT user_id FROM changed" +
	DATABASE_ROOM_MEMBER_SUFFIX_SQL_END

DATABASE_ROOM_REMOVE_MEMBER_SQL ::
	DATABASE_ROOM_MEMBER_PREFIX_SQL +
	"decision AS (SELECT CASE " +
	"WHEN NOT (SELECT is_admin FROM actor) THEN 'admin_required' " +
	"WHEN NOT EXISTS (SELECT 1 FROM room) THEN 'unknown_room' " +
	"WHEN NOT EXISTS (SELECT 1 FROM target) THEN 'unknown_user' " +
	"ELSE 'applied' END AS outcome), " +
	DATABASE_ROOM_MEMBER_DELETE_SQL

// $3 is the requester again.
DATABASE_ROOM_LEAVE_SQL ::
	DATABASE_ROOM_MEMBER_PREFIX_SQL +
	"decision AS (SELECT CASE " +
	"WHEN NOT EXISTS (SELECT 1 FROM room) OR NOT (SELECT is_member FROM actor) " +
	"THEN 'not_member' " +
	"WHEN (SELECT encrypted FROM room) THEN 'encrypted_room' " +
	"WHEN (SELECT access FROM room) = 1 THEN 'public_room' " +
	"ELSE 'applied' END AS outcome), " +
	DATABASE_ROOM_MEMBER_DELETE_SQL

DATABASE_ROOM_FETCH_MEMBERS_SQL ::
	DATABASE_ROOM_MEMBER_PREFIX_SQL +
	"decision AS (SELECT CASE " +
	"WHEN NOT EXISTS (SELECT 1 FROM room) THEN " +
	"CASE WHEN (SELECT is_admin FROM actor) THEN 'unknown_room' ELSE 'not_member' END " +
	"WHEN NOT (SELECT is_admin FROM actor) AND NOT (SELECT is_member FROM actor) " +
	"THEN 'not_member' " +
	"ELSE 'applied' END AS outcome), " +
	"changed AS (SELECT 1 WHERE false) " +
	DATABASE_ROOM_MEMBER_SUFFIX_SQL_START +
	DATABASE_ROOM_MEMBER_SNAPSHOT_SQL +
	DATABASE_ROOM_MEMBER_SUFFIX_SQL_END

databaseRoomMemberOutcomeFromText :: proc(
	text: string,
) -> (
	common.DatabaseRoomMemberOutcome,
	bool,
) {
	switch text {
	case "applied":
		return .Applied, true
	case "admin_required":
		return .AdminRequired, true
	case "not_member":
		return .NotMember, true
	case "unknown_room":
		return .UnknownRoom, true
	case "unknown_user":
		return .UnknownUser, true
	case "public_room":
		return .PublicRoom, true
	case "encrypted_room":
		return .EncryptedRoom, true
	}
	return .NotMember, false
}

databaseExecuteRoomMemberAction :: proc(
	conn: pg.Conn,
	request: common.DatabaseRoomMemberActionRequest,
) -> common.DatabaseQueryResponse {
	query: cstring
	targetUserID := request.targetUserId
	switch request.action {
	case .Add:
		query = DATABASE_ROOM_ADD_MEMBER_SQL
	case .Remove:
		// Protocol 18: removing someone from an encrypted room goes through its member log, as
		// an unsigned Remove entry the server writes (database_room_log.odin).
		encrypted, encryptedOK := databaseRoomIsEncrypted(conn, request.roomId)
		if !encryptedOK {
			return databaseConnectionError(conn)
		}
		if encrypted {
			return databaseExecuteServerRoomLogRemove(conn, request)
		}
		query = DATABASE_ROOM_REMOVE_MEMBER_SQL
	case .Leave:
		query = DATABASE_ROOM_LEAVE_SQL
		targetUserID = request.actorUserId
	case .Fetch:
		query = DATABASE_ROOM_FETCH_MEMBERS_SQL
		targetUserID = request.actorUserId
	}
	actorParam := databaseIntParam(request.actorUserId)
	defer delete(actorParam)
	roomParam := databaseIntParam(request.roomId)
	defer delete(roomParam)
	targetParam := databaseIntParam(targetUserID)
	defer delete(targetParam)
	params := [?][^]byte {
		transmute([^]byte)actorParam,
		transmute([^]byte)roomParam,
		transmute([^]byte)targetParam,
	}
	result := databaseExecParams(conn, query, params[:])
	if result == nil {
		return databaseConnectionError(conn)
	}
	defer pg.clear(result)
	if pg.result_status(result) != .Tuples_OK || pg.n_tuples(result) != 1 {
		return databaseResultError(&result)
	}

	outcomeText := databaseGetText(result, 0, 0)
	defer delete(outcomeText)
	outcome, outcomeOK := databaseRoomMemberOutcomeFromText(outcomeText)
	if !outcomeOK {
		return databaseErrorResponse(
			strings.clone("database returned an unknown room member outcome"),
		)
	}
	memberResult := common.DatabaseRoomMemberActionResult {
		outcome = outcome,
	}
	if outcome != .Applied {
		return databaseSuccess(memberResult)
	}
	memberResult.changed = databaseGetBool(result, 0, 1)
	memberResult.access = databaseGetRoomAccess(result, 0, 2)
	members := databaseGetText(result, 0, 3)
	defer delete(members)
	memberResult.memberUserIDs = databaseParseIDList(members)
	return databaseSuccess(memberResult)
}

// Every room by name, with whether the requester is a member and how many members it has, for
// the Admin section. One row with NULL room columns comes back when the requester is not an
// admin (the last column false) or there are no rooms.
DATABASE_ADMIN_LIST_ROOMS_SQL ::
	"WITH actor AS (SELECT EXISTS (SELECT 1 FROM user_server_roles usr " +
	"JOIN server_roles sr ON sr.id = usr.role_id " +
	"WHERE usr.user_id = $1::bigint AND sr.name = 'admin') AS ok) " +
	"SELECT " + DATABASE_ROOM_SUMMARY_COLUMNS_SQL + ", EXISTS (SELECT 1 FROM room_members rm " +
	"WHERE rm.room_id = r.id AND rm.user_id = $1::bigint)::text, " +
	"(SELECT count(*) FROM room_members rm WHERE rm.room_id = r.id)::text, a.ok::text " +
	"FROM actor a LEFT JOIN rooms r ON a.ok ORDER BY r.name"

databaseExecuteAdminRoomList :: proc(
	conn: pg.Conn,
	request: common.DatabaseAdminRoomListRequest,
) -> common.DatabaseQueryResponse {
	actorParam := databaseIntParam(request.actorUserId)
	defer delete(actorParam)
	params := [?][^]byte{transmute([^]byte)actorParam}
	result := databaseExecParams(conn, DATABASE_ADMIN_LIST_ROOMS_SQL, params[:])
	if result == nil {
		return databaseConnectionError(conn)
	}
	defer pg.clear(result)
	if pg.result_status(result) != .Tuples_OK || pg.n_tuples(result) < 1 {
		return databaseResultError(&result)
	}
	list := common.DatabaseAdminRoomListResult {
		isAdmin = databaseGetBool(result, 0, 10),
	}
	if !list.isAdmin {
		return databaseSuccess(list)
	}
	list.rooms = make([dynamic]common.AdminRoomSummary)
	for row in 0 ..< pg.n_tuples(result) {
		room, roomOK := databaseGetRoomSummary(result, row, 0)
		if !roomOK {
			continue
		}
		memberCount, _ := databaseGetInt(result, row, 9)
		append(
			&list.rooms,
			common.AdminRoomSummary {
				room = room,
				isMember = databaseGetBool(result, row, 8),
				memberCount = memberCount,
			},
		)
	}
	return databaseSuccess(list)
}
