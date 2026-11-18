package server

import "../common"
import "core:fmt"
import "core:strings"
import "shared:pg"

// Roles and server permissions (protocol 23, migration 11, #95, plan 2026-11-18 D1-D4).
//
// A role (server_roles) holds a set of common.ServerPermission bits in permissions (BIGINT,
// bit N is ServerPermission N). An account's effective permissions are the union (bit_or) of
// its roles' bits; the built-in admin role (server_roles.builtin, only `admin`) holds every
// bit, whatever its column says. Every statement that needs a permission checks it with the
// shared subquery below, in the same statement as the change (D4), so a role change between a
// check and the write cannot slip through.
//
// The shared subquery, for R2 and G1 to reuse:
//
//   DATABASE_SERVER_PERMISSIONS_OPEN_SQL + "<account ID expression>" +
//   DATABASE_SERVER_PERMISSIONS_CLOSE_SQL
//
// is a scalar BIGINT: -1 (every bit) for an admin, the bit_or of the roles' permissions
// otherwise, 0 for an account without roles. Test one permission with
//
//   "((" + <that subquery> + " & " + DATABASE_PERMISSION_<NAME>_SQL + ") <> 0)"
//
// as DATABASE_ACTOR_MANAGES_ROOMS_SQL does for $1. Its aliases start with perm_, so the
// expression may name any outer alias (for example "u.id"). serverPermissionsFromMask turns the
// mask into the wire set. testServerPermissionBitsMatchTheEnum pins the bit constants.
//
// Role management (admins only, the requester's role checked in the statement):
//
// - Save (create or edit): not_admin; unknown_role (no role has the ID); builtin_role (an edit
//   of admin that changes its name or does not send every permission; its position may
//   change); admin_only (another role given a permission outside
//   SERVER_PERMISSIONS_ASSIGNABLE); name_taken; too_many_roles (a create when SERVER_ROLES_MAX
//   roles exist).
// - Delete: not_admin; unknown_role; builtin_role (admin cannot be deleted).
// - SetUserRoles: not_admin; unknown_user; unknown_role (an ID that names no role or the
//   built-in one). The account's non-built-in roles become exactly the given set; its admin
//   role is ClientAdminSetRole's (database_admin.odin).
//
// Save, Delete and SetUserRoles also return every account whose effective permissions the
// change altered (before and after computed in the statement), so the router can send those
// accounts ServerAccountUpdated. Listing needs no permission: role names show next to accounts.

// The effective permissions of one account; see the file comment.
DATABASE_SERVER_PERMISSIONS_OPEN_SQL ::
	"(SELECT CASE WHEN bool_or(perm_role.builtin) THEN -1::bigint " +
	"ELSE COALESCE(bit_or(perm_role.permissions), 0)::bigint END " +
	"FROM user_server_roles perm_holder JOIN server_roles perm_role " +
	"ON perm_role.id = perm_holder.role_id WHERE perm_holder.user_id = "
DATABASE_SERVER_PERMISSIONS_CLOSE_SQL :: ")"

// The mask of each common.ServerPermission, 1 << its value, as SQL literals.
DATABASE_PERMISSION_MANAGE_ROOMS_SQL :: "1"
DATABASE_PERMISSION_MANAGE_ROOM_MEMBERS_SQL :: "2"
DATABASE_PERMISSION_CREATE_INVITES_SQL :: "4"
DATABASE_PERMISSION_APPROVE_REGISTRATIONS_SQL :: "8"

// The requester's ($1) effective permissions.
DATABASE_ACTOR_PERMISSIONS_SQL ::
	DATABASE_SERVER_PERMISSIONS_OPEN_SQL + "$1::bigint" + DATABASE_SERVER_PERMISSIONS_CLOSE_SQL

// Whether the requester ($1) holds ManageRooms / ManageRoomMembers.
DATABASE_ACTOR_MANAGES_ROOMS_SQL ::
	"((" + DATABASE_ACTOR_PERMISSIONS_SQL + " & " + DATABASE_PERMISSION_MANAGE_ROOMS_SQL +
	") <> 0)"
DATABASE_ACTOR_MANAGES_ROOM_MEMBERS_SQL ::
	"((" + DATABASE_ACTOR_PERMISSIONS_SQL + " & " + DATABASE_PERMISSION_MANAGE_ROOM_MEMBERS_SQL +
	") <> 0)"

// Whether the requester ($1) holds the built-in admin role. Role management, kick, ban and
// rename stay keyed to it (D2, D3).
DATABASE_ACTOR_IS_ADMIN_SQL ::
	"EXISTS (SELECT 1 FROM user_server_roles admin_holder JOIN server_roles admin_role " +
	"ON admin_role.id = admin_holder.role_id WHERE admin_holder.user_id = $1::bigint " +
	"AND admin_role.builtin)"

// Columns of one role for databaseGetRoleSummary, for a server_roles row aliased r. The
// built-in role reads as every permission.
DATABASE_ROLE_COLUMNS_SQL ::
	"r.id::text, r.name, (CASE WHEN r.builtin THEN -1 ELSE r.permissions END)::text, " +
	"r.builtin::text, r.position::text"

DATABASE_LIST_ROLES_SQL ::
	"SELECT " + DATABASE_ROLE_COLUMNS_SQL + " FROM server_roles r ORDER BY r.position, r.id"

// Columns of an account whose permissions changed, for databaseGetAffectedAccount, from a row
// aliased a with user_id and after (the mask after the change), joined to users u. NULL when
// nothing changed.
@(private = "file")
DATABASE_AFFECTED_COLUMNS_SQL ::
	"a.user_id::text, u.nickname, u.nickname_locked::text, EXISTS (SELECT 1 " +
	"FROM user_server_roles ah JOIN server_roles ar ON ar.id = ah.role_id " +
	"WHERE ah.user_id = a.user_id AND ar.builtin)::text, a.after::text"

// $1 the requester, $2 the role (0 creates), $3 the name, $4 the permissions mask, $5 the
// position (0 on a create puts it last), $6 the mask of every permission (what admin must
// keep), $7 SERVER_ROLES_MAX, $8 the mask of SERVER_PERMISSIONS_ASSIGNABLE. Columns: outcome,
// changed, the stored role (5 columns, DATABASE_ROLE_COLUMNS_SQL order), then one affected
// account per row (5 columns).
DATABASE_SAVE_ROLE_SQL ::
	"WITH actor AS (SELECT " + DATABASE_ACTOR_IS_ADMIN_SQL + " AS ok), " +
	"current AS (SELECT id, name, builtin, permissions, position FROM server_roles " +
	"WHERE id = $2::bigint), " +
	"taken AS (SELECT 1 FROM server_roles WHERE name = $3::text AND id <> $2::bigint), " +
	"decision AS (SELECT CASE " +
	"WHEN NOT (SELECT ok FROM actor) THEN 'not_admin' " +
	"WHEN $2::bigint <> 0 AND NOT EXISTS (SELECT 1 FROM current) THEN 'unknown_role' " +
	"WHEN COALESCE((SELECT builtin FROM current), false) AND " +
	"((SELECT name FROM current) <> $3::text OR $4::bigint <> $6::bigint) THEN 'builtin_role' " +
	"WHEN NOT COALESCE((SELECT builtin FROM current), false) " +
	"AND ($4::bigint & ~$8::bigint) <> 0 THEN 'admin_only' " +
	"WHEN EXISTS (SELECT 1 FROM taken) THEN 'name_taken' " +
	"WHEN $2::bigint = 0 AND (SELECT count(*) FROM server_roles) >= $7::bigint " +
	"THEN 'too_many_roles' " +
	"ELSE 'applied' END AS outcome), " +
	"created AS (INSERT INTO server_roles (name, permissions, position) " +
	"SELECT $3::text, $4::bigint, CASE WHEN $5::integer > 0 THEN $5::integer " +
	"ELSE (SELECT COALESCE(max(position), 0) + 1 FROM server_roles) END " +
	"FROM decision WHERE outcome = 'applied' AND $2::bigint = 0 " +
	"RETURNING id, name, permissions, builtin, position), " +
	"updated AS (UPDATE server_roles SET name = $3::text, " +
	"permissions = CASE WHEN server_roles.builtin THEN $6::bigint ELSE $4::bigint END, " +
	"position = GREATEST($5::integer, 0) FROM decision d " +
	"WHERE server_roles.id = $2::bigint AND d.outcome = 'applied' " +
	"AND (server_roles.name <> $3::text OR server_roles.position <> GREATEST($5::integer, 0) " +
	"OR server_roles.permissions <> CASE WHEN server_roles.builtin THEN $6::bigint " +
	"ELSE $4::bigint END) " +
	"RETURNING server_roles.id, server_roles.name, server_roles.permissions, " +
	"server_roles.builtin, server_roles.position), " +
	"stored AS (SELECT * FROM created UNION ALL SELECT * FROM updated " +
	"UNION ALL SELECT id, name, permissions, builtin, position FROM current " +
	"WHERE (SELECT outcome FROM decision) = 'applied' " +
	"AND NOT EXISTS (SELECT 1 FROM updated)), " +
	// Holders of an edited role, with their mask as if the role already had $4.
	"after AS (SELECT h.user_id, CASE WHEN bool_or(r.builtin) THEN -1::bigint " +
	"ELSE COALESCE(bit_or(CASE WHEN r.id = $2::bigint THEN $4::bigint " +
	"ELSE r.permissions END), 0)::bigint END AS after " +
	"FROM user_server_roles h JOIN server_roles r ON r.id = h.role_id " +
	"WHERE EXISTS (SELECT 1 FROM updated) AND h.user_id IN " +
	"(SELECT user_id FROM user_server_roles WHERE role_id = $2::bigint) GROUP BY h.user_id), " +
	"affected AS (SELECT a.user_id, a.after FROM after a WHERE a.after <> " +
	DATABASE_SERVER_PERMISSIONS_OPEN_SQL + "a.user_id" + DATABASE_SERVER_PERMISSIONS_CLOSE_SQL +
	") " +
	"SELECT d.outcome, (EXISTS (SELECT 1 FROM created) OR EXISTS (SELECT 1 FROM updated))::text, " +
	"r.id::text, r.name, (CASE WHEN r.builtin THEN -1 ELSE r.permissions END)::text, " +
	"r.builtin::text, r.position::text, " + DATABASE_AFFECTED_COLUMNS_SQL + " " +
	"FROM decision d LEFT JOIN stored r ON true LEFT JOIN affected a ON true " +
	"LEFT JOIN users u ON u.id = a.user_id ORDER BY a.user_id"

// $1 the requester, $2 the role. Columns: outcome, changed, then one affected account per row
// (5 columns). The holders' user_server_roles rows go with the role (ON DELETE CASCADE).
//
// Protocol 24 (#96): every row also carries the Role room memberships the deletion ended
// (DATABASE_ROLE_ROOM_CHANGES_COLUMN_SQL: a holder leaves each Role room whose access roles
// include this one and no other role it holds) and the role's holders, whose room permissions
// may change (comma separated). The room's grants and access role rows go with the role too.
DATABASE_DELETE_ROLE_SQL ::
	"WITH actor AS (SELECT " + DATABASE_ACTOR_IS_ADMIN_SQL + " AS ok), " +
	"current AS (SELECT id, builtin FROM server_roles WHERE id = $2::bigint), " +
	"decision AS (SELECT CASE " +
	"WHEN NOT (SELECT ok FROM actor) THEN 'not_admin' " +
	"WHEN NOT EXISTS (SELECT 1 FROM current) THEN 'unknown_role' " +
	"WHEN (SELECT builtin FROM current) THEN 'builtin_role' " +
	"ELSE 'applied' END AS outcome), " +
	"deleted AS (DELETE FROM server_roles USING decision d " +
	"WHERE server_roles.id = $2::bigint AND d.outcome = 'applied' RETURNING server_roles.id), " +
	"after AS (SELECT h.user_id, " +
	"CASE WHEN bool_or(r.builtin) FILTER (WHERE r.id <> $2::bigint) THEN -1::bigint " +
	"ELSE COALESCE(bit_or(r.permissions) FILTER (WHERE r.id <> $2::bigint), 0)::bigint END " +
	"AS after FROM user_server_roles h JOIN server_roles r ON r.id = h.role_id " +
	"WHERE EXISTS (SELECT 1 FROM deleted) AND h.user_id IN " +
	"(SELECT user_id FROM user_server_roles WHERE role_id = $2::bigint) GROUP BY h.user_id), " +
	"affected AS (SELECT a.user_id, a.after FROM after a WHERE a.after <> " +
	DATABASE_SERVER_PERMISSIONS_OPEN_SQL + "a.user_id" + DATABASE_SERVER_PERMISSIONS_CLOSE_SQL +
	"), " +
	"holders AS (SELECT user_id FROM user_server_roles WHERE role_id = $2::bigint " +
	"AND EXISTS (SELECT 1 FROM deleted)), " +
	"changes AS (SELECT m.room_id, m.user_id, false AS joined FROM room_members m " +
	"JOIN rooms r ON r.id = m.room_id AND r.access = 4 " +
	"JOIN room_access_roles ar ON ar.room_id = m.room_id AND ar.role_id = $2::bigint " +
	"WHERE m.user_id IN (SELECT user_id FROM holders) AND NOT EXISTS (" +
	"SELECT 1 FROM room_access_roles other JOIN user_server_roles h " +
	"ON h.role_id = other.role_id WHERE other.room_id = m.room_id " +
	"AND other.role_id <> $2::bigint AND h.user_id = m.user_id)), " +
	"left_rooms AS (DELETE FROM room_members m USING changes c " +
	"WHERE m.room_id = c.room_id AND m.user_id = c.user_id), " +
	"unmarked AS (DELETE FROM room_read_markers k USING changes c " +
	"WHERE k.room_id = c.room_id AND k.user_id = c.user_id) " +
	"SELECT d.outcome, EXISTS (SELECT 1 FROM deleted)::text, " + DATABASE_AFFECTED_COLUMNS_SQL +
	", " + DATABASE_ROLE_ROOM_CHANGES_COLUMN_SQL + ", COALESCE((SELECT string_agg(" +
	"user_id::text, ',' ORDER BY user_id) FROM holders), '') " +
	"FROM decision d LEFT JOIN affected a ON true LEFT JOIN users u ON u.id = a.user_id " +
	"ORDER BY a.user_id"

// $1 the requester, $2 the account, $3 its new non-built-in roles (a bigint array literal).
// One row: outcome, changed, the account's ID, nickname, nickname lock, admin flag, ban flag,
// identity key hex ('' without one), whether it has an encryption key, its role IDs after
// (comma separated), and its permission masks before and after. The account columns are NULL
// for unknown_user and for not_admin of a missing account.
//
// Protocol 24 (#96): the account joins every Role room one of its roles after the change gives
// access to and leaves every other Role room (deleting its read marker there), in the same
// statement; column 12 lists those changes (DATABASE_ROLE_ROOM_CHANGES_COLUMN_SQL).
DATABASE_SET_USER_ROLES_SQL ::
	"WITH actor AS (SELECT " + DATABASE_ACTOR_IS_ADMIN_SQL + " AS ok), " +
	"target AS (SELECT u.id, u.nickname, u.nickname_locked, u.banned_at IS NOT NULL AS banned, " +
	"COALESCE(encode(u.public_key, 'hex'), '') AS public_key_hex, " +
	"(u.public_key IS NOT NULL AND EXISTS (SELECT 1 FROM user_encryption_keys k " +
	"WHERE k.user_id = u.id)) AS has_key, " +
	DATABASE_SERVER_PERMISSIONS_OPEN_SQL + "u.id" + DATABASE_SERVER_PERMISSIONS_CLOSE_SQL +
	" AS before FROM users u WHERE u.id = $2::bigint), " +
	"wanted AS (SELECT DISTINCT unnest($3::bigint[]) AS role_id), " +
	"held AS (SELECT h.role_id, r.builtin FROM user_server_roles h " +
	"JOIN server_roles r ON r.id = h.role_id WHERE h.user_id = $2::bigint), " +
	"decision AS (SELECT CASE " +
	"WHEN NOT (SELECT ok FROM actor) THEN 'not_admin' " +
	"WHEN NOT EXISTS (SELECT 1 FROM target) THEN 'unknown_user' " +
	"WHEN EXISTS (SELECT 1 FROM wanted w LEFT JOIN server_roles r ON r.id = w.role_id " +
	"WHERE r.id IS NULL OR r.builtin) THEN 'unknown_role' " +
	"ELSE 'applied' END AS outcome), " +
	"removed AS (DELETE FROM user_server_roles h USING server_roles r, decision d " +
	"WHERE h.user_id = $2::bigint AND r.id = h.role_id AND NOT r.builtin " +
	"AND h.role_id NOT IN (SELECT role_id FROM wanted) AND d.outcome = 'applied' " +
	"RETURNING h.role_id), " +
	"added AS (INSERT INTO user_server_roles (user_id, role_id) " +
	"SELECT $2::bigint, w.role_id FROM wanted w, decision d WHERE d.outcome = 'applied' " +
	"ON CONFLICT DO NOTHING RETURNING role_id), " +
	"roles_after AS (SELECT role_id FROM held WHERE builtin OR (SELECT outcome FROM decision) " +
	"<> 'applied' UNION SELECT role_id FROM wanted WHERE (SELECT outcome FROM decision) = " +
	"'applied'), " +
	"after AS (SELECT CASE WHEN EXISTS (SELECT 1 FROM held WHERE builtin) THEN -1::bigint " +
	"ELSE COALESCE((SELECT bit_or(r.permissions) FROM server_roles r " +
	"WHERE r.id IN (SELECT role_id FROM roles_after)), 0)::bigint END AS mask), " +
	"role_rooms AS (SELECT r.id AS room_id, EXISTS (SELECT 1 FROM room_access_roles ar " +
	"WHERE ar.room_id = r.id AND ar.role_id IN (SELECT role_id FROM roles_after)) AS holds, " +
	"EXISTS (SELECT 1 FROM room_members m WHERE m.room_id = r.id " +
	"AND m.user_id = $2::bigint) AS is_member FROM rooms r " +
	"WHERE r.access = 4 AND (SELECT outcome FROM decision) = 'applied'), " +
	"changes AS (SELECT room_id, $2::bigint AS user_id, holds AS joined FROM role_rooms " +
	"WHERE holds <> is_member), " +
	"joined_rooms AS (INSERT INTO room_members (room_id, user_id) " +
	"SELECT room_id, user_id FROM changes WHERE joined ON CONFLICT DO NOTHING), " +
	"left_rooms AS (DELETE FROM room_members m USING changes c " +
	"WHERE m.room_id = c.room_id AND m.user_id = c.user_id AND NOT c.joined), " +
	"unmarked AS (DELETE FROM room_read_markers k USING changes c " +
	"WHERE k.room_id = c.room_id AND k.user_id = c.user_id AND NOT c.joined) " +
	"SELECT d.outcome, (EXISTS (SELECT 1 FROM removed) OR EXISTS (SELECT 1 FROM added))::text, " +
	"t.id::text, t.nickname, t.nickname_locked::text, " +
	"EXISTS (SELECT 1 FROM held WHERE builtin)::text, t.banned::text, " +
	"COALESCE(t.public_key_hex, ''), COALESCE(t.has_key, false)::text, " +
	"COALESCE((SELECT string_agg(role_id::text, ',' ORDER BY role_id) FROM roles_after), ''), " +
	"t.before::text, (SELECT mask FROM after)::text, " + DATABASE_ROLE_ROOM_CHANGES_COLUMN_SQL +
	" FROM decision d LEFT JOIN target t ON true"

// Reads one role in DATABASE_ROLE_COLUMNS_SQL order starting at first. name is owned.
databaseGetRoleSummary :: proc(
	result: pg.Result,
	row: i32,
	first: i32,
) -> (
	role: common.RoleSummary,
	ok: bool,
) {
	role.id, ok = databaseGetInt(result, row, first)
	if !ok {
		return {}, false
	}
	role.name = databaseGetText(result, row, first + 1)
	mask, _ := databaseGetInt(result, row, first + 2)
	role.builtin = databaseGetBool(result, row, first + 3)
	role.permissions = common.serverPermissionsFromMask(i64(mask))
	if role.builtin {
		role.permissions = common.SERVER_PERMISSIONS_ALL
	}
	role.position, _ = databaseGetInt(result, row, first + 4)
	return role, true
}

// Appends the affected account in DATABASE_AFFECTED_COLUMNS_SQL order at first, when the row
// has one.
@(private = "file")
databaseAppendAffectedAccount :: proc(
	affected: ^[dynamic]common.DatabaseAccountPermissions,
	result: pg.Result,
	row: i32,
	first: i32,
) {
	userID, ok := databaseGetInt(result, row, first)
	if !ok {
		return
	}
	mask, _ := databaseGetInt(result, row, first + 4)
	append(
		affected,
		common.DatabaseAccountPermissions {
			userId = userID,
			nickname = databaseGetText(result, row, first + 1),
			nicknameLocked = databaseGetBool(result, row, first + 2),
			isAdmin = databaseGetBool(result, row, first + 3),
			permissions = common.serverPermissionsFromMask(i64(mask)),
		},
	)
}

databaseRoleOutcomeFromText :: proc(text: string) -> (common.DatabaseAdminOutcome, bool) {
	switch text {
	case "unknown_role":
		return .UnknownRole, true
	case "builtin_role":
		return .BuiltinRole, true
	case "name_taken":
		return .RoleNameTaken, true
	case "too_many_roles":
		return .TooManyRoles, true
	case "admin_only":
		return .AdminOnlyPermission, true
	}
	return databaseAdminOutcomeFromText(text)
}

databaseExecuteRoleRequest :: proc(
	conn: pg.Conn,
	request: common.DatabaseRoleRequest,
) -> common.DatabaseQueryResponse {
	switch request.action {
	case .List:
		return databaseExecuteListRoles(conn)
	case .Save:
		return databaseExecuteSaveRole(conn, request)
	case .Delete:
		return databaseExecuteDeleteRole(conn, request)
	case .SetUserRoles:
		return databaseExecuteSetUserRoles(conn, request)
	}
	return databaseErrorResponse(strings.clone("unknown role request"))
}

@(private = "file")
databaseExecuteListRoles :: proc(conn: pg.Conn) -> common.DatabaseQueryResponse {
	result := databaseExecParams(conn, DATABASE_LIST_ROLES_SQL, nil)
	if result == nil {
		return databaseConnectionError(conn)
	}
	defer pg.clear(result)
	if pg.result_status(result) != .Tuples_OK {
		return databaseResultError(&result)
	}
	roleResult := common.DatabaseRoleResult {
		outcome = .Applied,
		roles   = make([dynamic]common.RoleSummary, 0, pg.n_tuples(result)),
	}
	for row in 0 ..< pg.n_tuples(result) {
		if role, ok := databaseGetRoleSummary(result, row, 0); ok {
			append(&roleResult.roles, role)
		}
	}
	return databaseSuccess(roleResult)
}

// Reads the first two columns, outcome and changed, shared by every role statement. ok false
// means the outcome was unknown, and the response to return is set.
@(private = "file")
databaseRoleOutcome :: proc(
	result: pg.Result,
) -> (
	roleResult: common.DatabaseRoleResult,
	failure: common.DatabaseQueryResponse,
	ok: bool,
) {
	outcomeText := databaseGetText(result, 0, 0)
	defer delete(outcomeText)
	outcome, outcomeOK := databaseRoleOutcomeFromText(outcomeText)
	if !outcomeOK {
		message := strings.clone("database returned an unknown role outcome")
		return {}, databaseErrorResponse(message), false
	}
	roleResult.outcome = outcome
	roleResult.changed = outcome == .Applied && databaseGetBool(result, 0, 1)
	return roleResult, {}, true
}

@(private = "file")
databaseExecuteSaveRole :: proc(
	conn: pg.Conn,
	request: common.DatabaseRoleRequest,
) -> common.DatabaseQueryResponse {
	actorParam := databaseIntParam(request.actorUserId)
	defer delete(actorParam)
	roleParam := databaseIntParam(request.roleId)
	defer delete(roleParam)
	nameParam := strings.clone_to_cstring(request.name)
	defer delete(nameParam)
	maskParam := fmt.caprintf("%d", common.serverPermissionsMask(request.permissions))
	defer delete(maskParam)
	positionParam := databaseIntParam(request.position)
	defer delete(positionParam)
	allParam := fmt.caprintf("%d", common.serverPermissionsMask(common.SERVER_PERMISSIONS_ALL))
	defer delete(allParam)
	maxParam := databaseIntParam(common.SERVER_ROLES_MAX)
	defer delete(maxParam)
	assignableParam := fmt.caprintf(
		"%d",
		common.serverPermissionsMask(common.SERVER_PERMISSIONS_ASSIGNABLE),
	)
	defer delete(assignableParam)
	params := [?][^]byte {
		transmute([^]byte)actorParam,
		transmute([^]byte)roleParam,
		transmute([^]byte)nameParam,
		transmute([^]byte)maskParam,
		transmute([^]byte)positionParam,
		transmute([^]byte)allParam,
		transmute([^]byte)maxParam,
		transmute([^]byte)assignableParam,
	}
	result := databaseExecParams(conn, DATABASE_SAVE_ROLE_SQL, params[:])
	if result == nil {
		return databaseConnectionError(conn)
	}
	defer pg.clear(result)
	if pg.result_status(result) != .Tuples_OK || pg.n_tuples(result) < 1 {
		return databaseResultError(&result)
	}
	roleResult, failure, ok := databaseRoleOutcome(result)
	if !ok {
		return failure
	}
	if roleResult.outcome != .Applied {
		return databaseSuccess(roleResult)
	}
	role, roleOK := databaseGetRoleSummary(result, 0, 2)
	if !roleOK {
		return databaseErrorResponse(strings.clone("database returned no saved role"))
	}
	roleResult.role = role
	roleResult.affected = make([dynamic]common.DatabaseAccountPermissions)
	for row in 0 ..< pg.n_tuples(result) {
		databaseAppendAffectedAccount(&roleResult.affected, result, row, 7)
	}
	return databaseSuccess(roleResult)
}

@(private = "file")
databaseExecuteDeleteRole :: proc(
	conn: pg.Conn,
	request: common.DatabaseRoleRequest,
) -> common.DatabaseQueryResponse {
	actorParam := databaseIntParam(request.actorUserId)
	defer delete(actorParam)
	roleParam := databaseIntParam(request.roleId)
	defer delete(roleParam)
	params := [?][^]byte{transmute([^]byte)actorParam, transmute([^]byte)roleParam}
	result := databaseExecParams(conn, DATABASE_DELETE_ROLE_SQL, params[:])
	if result == nil {
		return databaseConnectionError(conn)
	}
	defer pg.clear(result)
	if pg.result_status(result) != .Tuples_OK || pg.n_tuples(result) < 1 {
		return databaseResultError(&result)
	}
	roleResult, failure, ok := databaseRoleOutcome(result)
	if !ok {
		return failure
	}
	if roleResult.outcome != .Applied {
		return databaseSuccess(roleResult)
	}
	roleResult.role.id = request.roleId
	roleResult.affected = make([dynamic]common.DatabaseAccountPermissions)
	for row in 0 ..< pg.n_tuples(result) {
		databaseAppendAffectedAccount(&roleResult.affected, result, row, 2)
	}
	changes := databaseGetText(result, 0, 7)
	defer delete(changes)
	roleResult.membershipChanges = make([dynamic]common.DatabaseRoomMembershipChange)
	databaseParseRoleRoomChanges(changes, &roleResult.membershipChanges)
	holders := databaseGetText(result, 0, 8)
	defer delete(holders)
	roleResult.roomPermissionUserIDs = databaseParseIDList(holders)
	return databaseSuccess(roleResult)
}

@(private = "file")
databaseExecuteSetUserRoles :: proc(
	conn: pg.Conn,
	request: common.DatabaseRoleRequest,
) -> common.DatabaseQueryResponse {
	actorParam := databaseIntParam(request.actorUserId)
	defer delete(actorParam)
	targetParam := databaseIntParam(request.targetUserId)
	defer delete(targetParam)
	rolesParam := databaseIntArrayParam(request.roleIds[:])
	defer delete(rolesParam)
	params := [?][^]byte {
		transmute([^]byte)actorParam,
		transmute([^]byte)targetParam,
		transmute([^]byte)rolesParam,
	}
	result := databaseExecParams(conn, DATABASE_SET_USER_ROLES_SQL, params[:])
	if result == nil {
		return databaseConnectionError(conn)
	}
	defer pg.clear(result)
	if pg.result_status(result) != .Tuples_OK || pg.n_tuples(result) != 1 {
		return databaseResultError(&result)
	}
	roleResult, failure, ok := databaseRoleOutcome(result)
	if !ok {
		return failure
	}
	if roleResult.outcome != .Applied {
		return databaseSuccess(roleResult)
	}
	userID, userOK := databaseGetInt(result, 0, 2)
	if !userOK {
		return databaseErrorResponse(strings.clone("database returned an invalid user ID"))
	}
	roleIDs := databaseGetText(result, 0, 9)
	defer delete(roleIDs)
	roleResult.user = common.UserSummary {
		id               = userID,
		nickname         = databaseGetText(result, 0, 3),
		isAdmin          = databaseGetBool(result, 0, 5),
		isBanned         = databaseGetBool(result, 0, 6),
		hasEncryptionKey = databaseGetBool(result, 0, 8),
		roleIds          = databaseParseIDList(roleIDs),
	}
	roleResult.user.identityPublicKey = databaseGetIdentityPublicKey(result, 0, 7)
	before, _ := databaseGetInt(result, 0, 10)
	after, _ := databaseGetInt(result, 0, 11)
	changes := databaseGetText(result, 0, 12)
	defer delete(changes)
	roleResult.membershipChanges = make([dynamic]common.DatabaseRoomMembershipChange)
	databaseParseRoleRoomChanges(changes, &roleResult.membershipChanges)
	roleResult.roomPermissionUserIDs = make([dynamic]int)
	if roleResult.changed {
		append(&roleResult.roomPermissionUserIDs, userID)
	}
	roleResult.affected = make([dynamic]common.DatabaseAccountPermissions)
	if before != after {
		append(
			&roleResult.affected,
			common.DatabaseAccountPermissions {
				userId = userID,
				nickname = strings.clone(roleResult.user.nickname),
				nicknameLocked = databaseGetBool(result, 0, 4),
				isAdmin = roleResult.user.isAdmin,
				permissions = common.serverPermissionsFromMask(i64(after)),
			},
		)
	}
	return databaseSuccess(roleResult)
}
