package server

import "../common"
import "core:fmt"
import "core:strconv"
import "core:strings"
import "shared:pg"

// Room permissions and role rooms (protocol 24, migration 12, #96, plan 2026-11-18 D5-D6).
//
// A room permission is a common.RoomPermission bit (SendMessages 1, SpeakInVoice 2,
// ManageMembers 4, EditRoom 8). Grants are allow-only: rooms.everyone_permissions (default
// Send + Speak) for every member, and room_role_permissions(room_id, role_id, permissions) for
// members holding the role. Server permissions imply room ones in every room, member or not:
// ManageRoomMembers implies ManageMembers, ManageRooms implies EditRoom, and an admin holds
// every room permission. room_members still decides who sees a room.
//
// The shared subquery, for G1 and later packages to reuse:
//
//   DATABASE_ROOM_PERMISSIONS_OPEN_SQL + "<account ID expression>" +
//   DATABASE_ROOM_PERMISSIONS_ROOM_SQL + "<room ID expression>" +
//   DATABASE_ROOM_PERMISSIONS_CLOSE_SQL
//
// is a scalar BIGINT: -1 (every bit) for an admin, otherwise the implied bits OR, when the
// account is a member, the room's everyone grant and its roles' grants; 0 for a non-member
// without server permissions or a room that does not exist (only the implied bits then). Test
// one permission with
//
//   "((" + <that subquery> + " & " + DATABASE_ROOM_PERMISSION_<NAME>_SQL + ") <> 0)"
//
// Its aliases start with rp_ (and the server subquery's with perm_), so the expressions may
// name any outer alias. Every statement that needs a room permission checks it there, in the
// same statement as the change (D4). testRoomPermissionBitsMatchTheEnum pins the literals.
//
// Role rooms (rooms.access 4): the members are exactly the holders of the room's
// room_access_roles. Every statement that changes who holds a role or a room's access roles
// adds and removes those memberships itself, deleting the read marker of a removed member like
// a protocol 15 removal: DATABASE_SET_USER_ROLES_SQL and DATABASE_DELETE_ROLE_SQL
// (database_roles.odin), DATABASE_CREATE_ROOM_SQL and DATABASE_EDIT_ROOM_SQL (database.odin).
// The role statements report the changes through DATABASE_ROLE_ROOM_CHANGES_COLUMN_SQL.

DATABASE_ROOM_PERMISSIONS_OPEN_SQL ::
	"(SELECT CASE WHEN rp_server.mask = -1 THEN -1::bigint ELSE (" +
	"(CASE WHEN (rp_server.mask & " + DATABASE_PERMISSION_MANAGE_ROOM_MEMBERS_SQL +
	") <> 0 THEN " + DATABASE_ROOM_PERMISSION_MANAGE_MEMBERS_SQL + " ELSE 0 END) | " +
	"(CASE WHEN (rp_server.mask & " + DATABASE_PERMISSION_MANAGE_ROOMS_SQL + ") <> 0 THEN " +
	DATABASE_ROOM_PERMISSION_EDIT_ROOM_SQL + " ELSE 0 END) | " +
	"COALESCE((SELECT rp_room.everyone_permissions | COALESCE((" +
	"SELECT bit_or(rp_grant.permissions) FROM room_role_permissions rp_grant " +
	"JOIN user_server_roles rp_holder ON rp_holder.role_id = rp_grant.role_id " +
	"WHERE rp_grant.room_id = rp_room.id AND rp_holder.user_id = rp_ids.account_id), 0) " +
	"FROM rooms rp_room JOIN room_members rp_member ON rp_member.room_id = rp_room.id " +
	"AND rp_member.user_id = rp_ids.account_id WHERE rp_room.id = rp_ids.room_id), 0)" +
	")::bigint END FROM (SELECT ("
DATABASE_ROOM_PERMISSIONS_ROOM_SQL :: ")::bigint AS account_id, ("
DATABASE_ROOM_PERMISSIONS_CLOSE_SQL ::
	")::bigint AS room_id) rp_ids CROSS JOIN LATERAL (SELECT " +
	DATABASE_SERVER_PERMISSIONS_OPEN_SQL + "rp_ids.account_id" +
	DATABASE_SERVER_PERMISSIONS_CLOSE_SQL + " AS mask) rp_server)"

// The mask of each common.RoomPermission, 1 << its value, as SQL literals.
DATABASE_ROOM_PERMISSION_SEND_MESSAGES_SQL :: "1"
DATABASE_ROOM_PERMISSION_SPEAK_IN_VOICE_SQL :: "2"
DATABASE_ROOM_PERMISSION_MANAGE_MEMBERS_SQL :: "4"
DATABASE_ROOM_PERMISSION_EDIT_ROOM_SQL :: "8"
// Every room permission, what a grant may hold.
DATABASE_ROOM_PERMISSIONS_ALL_SQL :: "15"
// What ManageRooms lets its holder grant in any room: SendMessages, SpeakInVoice, EditRoom.
@(private = "file")
DATABASE_ROOM_PERMISSIONS_ROOM_MANAGER_GRANTS_SQL :: "11"

// The requester's ($1) permissions in the room $2.
DATABASE_ACTOR_ROOM_PERMISSIONS_SQL ::
	DATABASE_ROOM_PERMISSIONS_OPEN_SQL + "$1" + DATABASE_ROOM_PERMISSIONS_ROOM_SQL + "$2" +
	DATABASE_ROOM_PERMISSIONS_CLOSE_SQL

// Whether the requester ($1) holds ManageMembers in the room $2: ManageRoomMembers, an admin,
// or a grant to a member.
DATABASE_ACTOR_MANAGES_ROOM_MEMBERS_IN_ROOM_SQL ::
	"((" + DATABASE_ACTOR_ROOM_PERMISSIONS_SQL + " & " +
	DATABASE_ROOM_PERMISSION_MANAGE_MEMBERS_SQL + ") <> 0)"

// A column that lists the Role room memberships a statement changed, for a statement with a CTE
// changes(room_id, user_id, joined): entries "room:user:1|0:member,member,..." joined by ';',
// each with the room's members after the statement. Data-modifying CTEs share one snapshot, so
// the members are the snapshot with every change of that room applied by hand.
DATABASE_ROLE_ROOM_CHANGES_COLUMN_SQL ::
	"COALESCE((SELECT string_agg(c.room_id::text || ':' || c.user_id::text || ':' || " +
	"CASE WHEN c.joined THEN '1' ELSE '0' END || ':' || COALESCE((" +
	"SELECT string_agg(x.user_id::text, ',' ORDER BY x.user_id) FROM (" +
	"(SELECT rm.user_id FROM room_members rm WHERE rm.room_id = c.room_id " +
	"UNION SELECT j.user_id FROM changes j WHERE j.room_id = c.room_id AND j.joined) " +
	"EXCEPT SELECT l.user_id FROM changes l WHERE l.room_id = c.room_id AND NOT l.joined) x), " +
	"''), ';' ORDER BY c.room_id, c.user_id) FROM changes c), '')"

// Parses DATABASE_ROLE_ROOM_CHANGES_COLUMN_SQL into changes. Malformed entries are skipped.
databaseParseRoleRoomChanges :: proc(
	text: string,
	changes: ^[dynamic]common.DatabaseRoomMembershipChange,
) {
	remaining := text
	for entry in strings.split_iterator(&remaining, ";") {
		fields := strings.split_n(entry, ":", 4)
		defer delete(fields)
		if len(fields) != 4 {
			continue
		}
		roomID, roomOK := strconv.parse_int(fields[0])
		userID, userOK := strconv.parse_int(fields[1])
		if !roomOK || !userOK {
			continue
		}
		append(
			changes,
			common.DatabaseRoomMembershipChange {
				roomId = roomID,
				userId = userID,
				joined = fields[2] == "1",
				memberUserIDs = databaseParseIDList(fields[3]),
			},
		)
	}
}

// Parses "role:mask,role:mask" (DATABASE_ROOM_GRANTS_COLUMN_SQL) into grants.
@(private = "file")
databaseParseRoomRoleGrants :: proc(text: string) -> [dynamic]common.RoomRoleGrant {
	grants := make([dynamic]common.RoomRoleGrant)
	remaining := text
	for entry in strings.split_iterator(&remaining, ",") {
		separator := strings.index_byte(entry, ':')
		if separator < 0 {
			continue
		}
		roleID, roleOK := strconv.parse_int(entry[:separator])
		mask, maskOK := strconv.parse_i64(entry[separator + 1:])
		if !roleOK || !maskOK {
			continue
		}
		append(
			&grants,
			common.RoomRoleGrant {
				roleId = roleID,
				permissions = common.roomPermissionsFromMask(mask),
			},
		)
	}
	return grants
}

// Fetch and Set of a room's grants (ClientAdminFetchRoomPermissions,
// ClientAdminSetRoomPermissions). $1 the requester, $2 the room, $3 the everyone mask, $4 the
// granted role IDs and $5 their masks (parallel bigint arrays), $6 whether to apply (Set).
//
// Who: ManageRooms (an admin included) or the room's EditRoom; a missing room is unknown_room
// to holders of ManageRooms and not_permitted to everyone else. Set then refuses a grant to a
// role that does not exist or is the built-in one (unknown_role), and any bit it adds or takes
// away that the requester may not grant (not_grantable): the requester's own room permissions,
// plus SendMessages, SpeakInVoice and EditRoom for a holder of ManageRooms, and every bit for an
// admin. A role sent with no permissions loses its grant, like one left out.
//
// One row: outcome, whether a grant changed, the everyone mask and the role grants
// ("role:mask,...") after the statement, the access roles (comma separated), the requester's
// permissions after it, and the room's members.
DATABASE_ROOM_PERMISSIONS_SQL ::
	"WITH actor AS (SELECT " + DATABASE_ACTOR_PERMISSIONS_SQL + " AS server_mask, " +
	DATABASE_ACTOR_ROOM_PERMISSIONS_SQL + " AS room_mask), " +
	"room AS (SELECT id, everyone_permissions FROM rooms WHERE id = $2::bigint), " +
	"requested AS (SELECT w.role_id, w.permissions " +
	"FROM unnest($4::bigint[], $5::bigint[]) AS w(role_id, permissions)), " +
	"wanted AS (SELECT role_id, permissions FROM requested WHERE permissions <> 0), " +
	"current AS (SELECT role_id, permissions FROM room_role_permissions " +
	"WHERE room_id = $2::bigint), " +
	"grantable AS (SELECT CASE WHEN a.server_mask = -1 THEN " +
	DATABASE_ROOM_PERMISSIONS_ALL_SQL + "::bigint ELSE a.room_mask | " +
	"CASE WHEN (a.server_mask & " + DATABASE_PERMISSION_MANAGE_ROOMS_SQL + ") <> 0 THEN " +
	DATABASE_ROOM_PERMISSIONS_ROOM_MANAGER_GRANTS_SQL + " ELSE 0 END END AS mask " +
	"FROM actor a), " +
	"decision AS (SELECT CASE " +
	"WHEN NOT EXISTS (SELECT 1 FROM room) THEN CASE WHEN ((SELECT server_mask FROM actor) & " +
	DATABASE_PERMISSION_MANAGE_ROOMS_SQL + ") <> 0 THEN 'unknown_room' ELSE 'not_permitted' END " +
	"WHEN ((SELECT server_mask FROM actor) & " + DATABASE_PERMISSION_MANAGE_ROOMS_SQL +
	") = 0 AND ((SELECT room_mask FROM actor) & " + DATABASE_ROOM_PERMISSION_EDIT_ROOM_SQL +
	") = 0 THEN 'not_permitted' " +
	"WHEN $6::boolean AND EXISTS (SELECT 1 FROM requested q LEFT JOIN server_roles r " +
	"ON r.id = q.role_id WHERE r.id IS NULL OR r.builtin) THEN 'unknown_role' " +
	"WHEN $6::boolean AND (((SELECT everyone_permissions FROM room) # $3::bigint) & " +
	"~(SELECT mask FROM grantable)) <> 0 THEN 'not_grantable' " +
	"WHEN $6::boolean AND EXISTS (SELECT 1 FROM current c FULL JOIN wanted w " +
	"ON w.role_id = c.role_id WHERE ((COALESCE(c.permissions, 0) # " +
	"COALESCE(w.permissions, 0)) & ~(SELECT mask FROM grantable)) <> 0) THEN 'not_grantable' " +
	"ELSE 'applied' END AS outcome), " +
	"apply AS (SELECT $6::boolean AND outcome = 'applied' AS ok FROM decision), " +
	"everyone_set AS (UPDATE rooms SET everyone_permissions = $3::bigint " +
	"WHERE id = $2::bigint AND (SELECT ok FROM apply) " +
	"AND everyone_permissions <> $3::bigint RETURNING id), " +
	"grants_removed AS (DELETE FROM room_role_permissions p WHERE p.room_id = $2::bigint " +
	"AND (SELECT ok FROM apply) AND p.role_id NOT IN (SELECT role_id FROM wanted) " +
	"RETURNING p.role_id), " +
	"grants_set AS (INSERT INTO room_role_permissions (room_id, role_id, permissions) " +
	"SELECT $2::bigint, w.role_id, w.permissions FROM wanted w WHERE (SELECT ok FROM apply) " +
	"ON CONFLICT (room_id, role_id) DO UPDATE SET permissions = EXCLUDED.permissions " +
	"WHERE room_role_permissions.permissions <> EXCLUDED.permissions RETURNING role_id), " +
	// The requester's permissions as if the new grants were already stored.
	"mine AS (SELECT CASE WHEN NOT (SELECT ok FROM apply) THEN a.room_mask " +
	"WHEN a.server_mask = -1 THEN -1::bigint ELSE (" +
	"(CASE WHEN (a.server_mask & " + DATABASE_PERMISSION_MANAGE_ROOM_MEMBERS_SQL + ") <> 0 " +
	"THEN " + DATABASE_ROOM_PERMISSION_MANAGE_MEMBERS_SQL + " ELSE 0 END) | " +
	"(CASE WHEN (a.server_mask & " + DATABASE_PERMISSION_MANAGE_ROOMS_SQL + ") <> 0 THEN " +
	DATABASE_ROOM_PERMISSION_EDIT_ROOM_SQL + " ELSE 0 END) | " +
	"CASE WHEN EXISTS (SELECT 1 FROM room_members WHERE room_id = $2::bigint " +
	"AND user_id = $1::bigint) THEN $3::bigint | COALESCE((SELECT bit_or(w.permissions) " +
	"FROM wanted w JOIN user_server_roles h ON h.role_id = w.role_id " +
	"AND h.user_id = $1::bigint), 0) ELSE 0 END)::bigint END AS mask FROM actor a) " +
	"SELECT d.outcome, (EXISTS (SELECT 1 FROM everyone_set) OR " +
	"EXISTS (SELECT 1 FROM grants_removed) OR EXISTS (SELECT 1 FROM grants_set))::text, " +
	"(CASE WHEN (SELECT ok FROM apply) THEN $3::bigint " +
	"ELSE COALESCE((SELECT everyone_permissions FROM room), 0) END)::text, " +
	"COALESCE(CASE WHEN (SELECT ok FROM apply) THEN (SELECT string_agg(role_id::text || ':' || " +
	"permissions::text, ',' ORDER BY role_id) FROM wanted) ELSE (SELECT string_agg(" +
	"role_id::text || ':' || permissions::text, ',' ORDER BY role_id) FROM current) END, ''), " +
	"COALESCE((SELECT string_agg(role_id::text, ',' ORDER BY role_id) FROM room_access_roles " +
	"WHERE room_id = $2::bigint), ''), (SELECT mask FROM mine)::text, " +
	"COALESCE((SELECT string_agg(user_id::text, ',' ORDER BY user_id) FROM room_members " +
	"WHERE room_id = $2::bigint), '') FROM decision d"

databaseRoomPermissionsOutcomeFromText :: proc(
	text: string,
) -> (
	common.DatabaseRoomPermissionsOutcome,
	bool,
) {
	switch text {
	case "applied":
		return .Applied, true
	case "not_permitted":
		return .NotPermitted, true
	case "unknown_room":
		return .UnknownRoom, true
	case "unknown_role":
		return .UnknownRole, true
	case "not_grantable":
		return .NotGrantable, true
	}
	return .NotPermitted, false
}

databaseExecuteRoomPermissions :: proc(
	conn: pg.Conn,
	request: common.DatabaseRoomPermissionsRequest,
) -> common.DatabaseQueryResponse {
	apply := request.action == .Set
	actorParam := databaseIntParam(request.actorUserId)
	defer delete(actorParam)
	roomParam := databaseIntParam(request.roomId)
	defer delete(roomParam)
	everyoneParam := fmt.caprintf("%d", common.roomPermissionsMask(request.everyone))
	defer delete(everyoneParam)
	roleIDs := make([dynamic]int, 0, len(request.roles))
	defer delete(roleIDs)
	masks := make([dynamic]int, 0, len(request.roles))
	defer delete(masks)
	if apply {
		for grant in request.roles {
			append(&roleIDs, grant.roleId)
			append(&masks, int(common.roomPermissionsMask(grant.permissions)))
		}
	}
	rolesParam := databaseIntArrayParam(roleIDs[:])
	defer delete(rolesParam)
	masksParam := databaseIntArrayParam(masks[:])
	defer delete(masksParam)
	applyParam := strings.clone_to_cstring(apply ? "true" : "false")
	defer delete(applyParam)
	params := [?][^]byte {
		transmute([^]byte)actorParam,
		transmute([^]byte)roomParam,
		transmute([^]byte)everyoneParam,
		transmute([^]byte)rolesParam,
		transmute([^]byte)masksParam,
		transmute([^]byte)applyParam,
	}
	result := databaseExecParams(conn, DATABASE_ROOM_PERMISSIONS_SQL, params[:])
	if result == nil {
		return databaseConnectionError(conn)
	}
	defer pg.clear(result)
	if pg.result_status(result) != .Tuples_OK || pg.n_tuples(result) != 1 {
		return databaseResultError(&result)
	}
	outcomeText := databaseGetText(result, 0, 0)
	defer delete(outcomeText)
	outcome, outcomeOK := databaseRoomPermissionsOutcomeFromText(outcomeText)
	if !outcomeOK {
		return databaseErrorResponse(
			strings.clone("database returned an unknown room permissions outcome"),
		)
	}
	permissions := common.DatabaseRoomPermissionsResult {
		outcome = outcome,
	}
	if outcome != .Applied {
		return databaseSuccess(permissions)
	}
	permissions.changed = apply && databaseGetBool(result, 0, 1)
	everyone, _ := databaseGetInt(result, 0, 2)
	permissions.everyone = common.roomPermissionsFromMask(i64(everyone))
	grants := databaseGetText(result, 0, 3)
	defer delete(grants)
	permissions.roles = databaseParseRoomRoleGrants(grants)
	accessRoles := databaseGetText(result, 0, 4)
	defer delete(accessRoles)
	permissions.accessRoleIds = databaseParseIDList(accessRoles)
	mine, _ := databaseGetInt(result, 0, 5)
	permissions.myPermissions = common.roomPermissionsFromMask(i64(mine))
	members := databaseGetText(result, 0, 6)
	defer delete(members)
	permissions.memberUserIDs = databaseParseIDList(members)
	return databaseSuccess(permissions)
}
