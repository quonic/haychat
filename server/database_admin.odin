package server

import "../common"
import "core:strings"
import "shared:pg"

// Admin actions on accounts (protocol 14, migration 3): grant or revoke the admin role, rename
// an account and lock its name, kick, and ban or unban. Each action is one statement that
// checks the requester's admin role, applies the action's guards (D6 of the 2026-11-14 plan),
// and makes the change, so nothing can change between the checks and the write. A refusal
// changes nothing and names its reason in the first column.
//
// The guards, in the order they are checked:
//
// - not_admin: the requester ($1) does not hold the admin role.
// - unknown_user: no account has the target ID ($2).
// - last_admin (role revoke): the target is the only admin. Since the requester must be an
//   admin and may not revoke their own role, this can only be the sole admin revoking
//   themselves; it is checked before `self` so that case says why.
// - self (role revoke, kick, ban): the requester is the target. Renaming yourself is allowed.
// - admin_target (kick, ban): the target holds the admin role; revoke it first.
// - banned_target (role grant): the target is banned; unban it first.
// - nickname_taken (rename): another account holds the new nickname. A rename that races
//   another account taking the name fails on users.nickname UNIQUE instead.
//
// The database worker runs one statement at a time on one connection, so two admins revoking
// each other are applied one after the other: the second one is no longer an admin and is
// refused with not_admin, and the server always keeps an admin.
//
// Every statement returns one row: outcome, whether a row changed, and the target's ID,
// nickname, nickname lock, admin flag, and ban flag after the action, its nickname before it,
// and (protocol 16) its identity key in hex ('' without one) and whether it has published an
// encryption key bundle. The target columns are NULL for unknown_user and not_admin of a
// missing target. Protocol 23 (#95) adds two more: the target's role IDs after the action
// (comma separated) and its effective permission mask after it (database_roles.odin), and
// protocol 25 one: whether the target is restricted after it.

@(private = "file")
DATABASE_ADMIN_ACTOR_AND_TARGET_SQL ::
	"WITH actor AS (SELECT EXISTS (SELECT 1 FROM user_server_roles usr " +
	"JOIN server_roles sr ON sr.id = usr.role_id " +
	"WHERE usr.user_id = $1::bigint AND sr.name = 'admin') AS ok), " +
	"target AS (SELECT u.id, u.nickname, u.nickname_locked, u.banned_at IS NOT NULL AS banned, " +
	"u.restricted, COALESCE(encode(u.public_key, 'hex'), '') AS public_key_hex, " +
	"(u.public_key IS NOT NULL AND EXISTS (SELECT 1 FROM user_encryption_keys k " +
	"WHERE k.user_id = u.id)) AS has_key, " +
	"EXISTS (SELECT 1 FROM user_server_roles usr JOIN server_roles sr ON sr.id = usr.role_id " +
	"WHERE usr.user_id = u.id AND sr.name = 'admin') AS is_admin, " +
	"COALESCE((SELECT string_agg(usr.role_id::text, ',' ORDER BY usr.role_id) " +
	"FROM user_server_roles usr WHERE usr.user_id = u.id), '') AS role_ids, " +
	DATABASE_SERVER_PERMISSIONS_OPEN_SQL + "u.id" + DATABASE_SERVER_PERMISSIONS_CLOSE_SQL +
	" AS permissions, " +
	// What a grant or a revoke of admin leaves: the roles with or without admin, and the mask
	// of the other roles.
	"COALESCE((SELECT string_agg(x.id::text, ',' ORDER BY x.id) FROM (" +
	"SELECT usr.role_id AS id FROM user_server_roles usr WHERE usr.user_id = u.id " +
	"UNION SELECT sr.id FROM server_roles sr WHERE sr.name = 'admin') x), '') " +
	"AS role_ids_granted, " +
	"COALESCE((SELECT string_agg(usr.role_id::text, ',' ORDER BY usr.role_id) " +
	"FROM user_server_roles usr JOIN server_roles sr ON sr.id = usr.role_id " +
	"WHERE usr.user_id = u.id AND sr.name <> 'admin'), '') AS role_ids_revoked, " +
	"COALESCE((SELECT bit_or(sr.permissions) FROM user_server_roles usr " +
	"JOIN server_roles sr ON sr.id = usr.role_id " +
	"WHERE usr.user_id = u.id AND sr.name <> 'admin'), 0)::bigint AS permissions_revoked " +
	"FROM users u WHERE u.id = $2::bigint), "

// $3 is true to grant the role and false to revoke it.
DATABASE_ADMIN_SET_ROLE_SQL ::
	DATABASE_ADMIN_ACTOR_AND_TARGET_SQL +
	"admins AS (SELECT count(*) AS n FROM user_server_roles usr " +
	"JOIN server_roles sr ON sr.id = usr.role_id WHERE sr.name = 'admin'), " +
	"decision AS (SELECT CASE " +
	"WHEN NOT (SELECT ok FROM actor) THEN 'not_admin' " +
	"WHEN NOT EXISTS (SELECT 1 FROM target) THEN 'unknown_user' " +
	"WHEN NOT $3::boolean AND (SELECT is_admin FROM target) " +
	"AND (SELECT n FROM admins) <= 1 THEN 'last_admin' " +
	"WHEN NOT $3::boolean AND $1::bigint = $2::bigint THEN 'self' " +
	"WHEN $3::boolean AND (SELECT banned FROM target) THEN 'banned_target' " +
	"ELSE 'applied' END AS outcome), " +
	"granted AS (INSERT INTO user_server_roles (user_id, role_id) " +
	"SELECT $2::bigint, sr.id FROM server_roles sr, decision d " +
	"WHERE sr.name = 'admin' AND d.outcome = 'applied' AND $3::boolean " +
	"ON CONFLICT DO NOTHING RETURNING user_id), " +
	"revoked AS (DELETE FROM user_server_roles usr USING server_roles sr, decision d " +
	"WHERE usr.role_id = sr.id AND sr.name = 'admin' AND usr.user_id = $2::bigint " +
	"AND d.outcome = 'applied' AND NOT $3::boolean RETURNING usr.user_id) " +
	"SELECT d.outcome, (EXISTS (SELECT 1 FROM granted) OR EXISTS (SELECT 1 FROM revoked))::text, " +
	"t.id::text, t.nickname, t.nickname_locked::text, " +
	"(CASE WHEN d.outcome = 'applied' THEN $3::boolean ELSE t.is_admin END)::text, " +
	"t.banned::text, t.nickname, " +
	"COALESCE(t.public_key_hex, ''), COALESCE(t.has_key, false)::text, " +
	"CASE WHEN d.outcome <> 'applied' THEN t.role_ids WHEN $3::boolean " +
	"THEN t.role_ids_granted ELSE t.role_ids_revoked END, " +
	"(CASE WHEN d.outcome <> 'applied' THEN t.permissions WHEN $3::boolean THEN -1::bigint " +
	"ELSE t.permissions_revoked END)::text, COALESCE(t.restricted, false)::text " +
	"FROM decision d LEFT JOIN target t ON true"

// $3 is the new nickname, or '' to keep it; $4 is the new lock.
DATABASE_ADMIN_RENAME_SQL ::
	DATABASE_ADMIN_ACTOR_AND_TARGET_SQL +
	"taken AS (SELECT 1 FROM users WHERE nickname = $3::text AND id <> $2::bigint), " +
	"decision AS (SELECT CASE " +
	"WHEN NOT (SELECT ok FROM actor) THEN 'not_admin' " +
	"WHEN NOT EXISTS (SELECT 1 FROM target) THEN 'unknown_user' " +
	"WHEN EXISTS (SELECT 1 FROM taken) THEN 'nickname_taken' " +
	"ELSE 'applied' END AS outcome), " +
	"updated AS (UPDATE users SET nickname = COALESCE(NULLIF($3::text, ''), users.nickname), " +
	"nickname_locked = $4::boolean FROM decision d " +
	"WHERE users.id = $2::bigint AND d.outcome = 'applied' " +
	"AND (users.nickname_locked <> $4::boolean " +
	"OR ($3::text <> '' AND users.nickname <> $3::text)) " +
	"RETURNING users.nickname::text AS nickname, users.nickname_locked) " +
	"SELECT d.outcome, EXISTS (SELECT 1 FROM updated)::text, t.id::text, " +
	"COALESCE((SELECT nickname FROM updated), t.nickname), " +
	"COALESCE((SELECT nickname_locked FROM updated), t.nickname_locked)::text, " +
	"t.is_admin::text, t.banned::text, t.nickname, " +
	"COALESCE(t.public_key_hex, ''), COALESCE(t.has_key, false)::text, " +
	"t.role_ids, t.permissions::text, COALESCE(t.restricted, false)::text " +
	"FROM decision d LEFT JOIN target t ON true"

// Changes nothing: the router ends the target's sessions when the guards pass.
DATABASE_ADMIN_KICK_SQL ::
	DATABASE_ADMIN_ACTOR_AND_TARGET_SQL +
	"decision AS (SELECT CASE " +
	"WHEN NOT (SELECT ok FROM actor) THEN 'not_admin' " +
	"WHEN NOT EXISTS (SELECT 1 FROM target) THEN 'unknown_user' " +
	"WHEN $1::bigint = $2::bigint THEN 'self' " +
	"WHEN (SELECT is_admin FROM target) THEN 'admin_target' " +
	"ELSE 'applied' END AS outcome) " +
	"SELECT d.outcome, 'false', t.id::text, t.nickname, t.nickname_locked::text, " +
	"t.is_admin::text, t.banned::text, t.nickname, " +
	"COALESCE(t.public_key_hex, ''), COALESCE(t.has_key, false)::text, " +
	"t.role_ids, t.permissions::text, COALESCE(t.restricted, false)::text " +
	"FROM decision d LEFT JOIN target t ON true"

// $3 is true to ban and false to unban; $4 is the reason, kept only while banned. Banning a
// banned account again keeps banned_at and replaces the reason.
DATABASE_ADMIN_BAN_SQL ::
	DATABASE_ADMIN_ACTOR_AND_TARGET_SQL +
	"decision AS (SELECT CASE " +
	"WHEN NOT (SELECT ok FROM actor) THEN 'not_admin' " +
	"WHEN NOT EXISTS (SELECT 1 FROM target) THEN 'unknown_user' " +
	"WHEN $3::boolean AND $1::bigint = $2::bigint THEN 'self' " +
	"WHEN $3::boolean AND (SELECT is_admin FROM target) THEN 'admin_target' " +
	"ELSE 'applied' END AS outcome), " +
	"updated AS (UPDATE users SET banned_at = CASE WHEN $3::boolean " +
	"THEN COALESCE(users.banned_at, CURRENT_TIMESTAMP) ELSE NULL END, " +
	"ban_reason = CASE WHEN $3::boolean THEN $4::text ELSE '' END FROM decision d " +
	"WHERE users.id = $2::bigint AND d.outcome = 'applied' " +
	"AND ((users.banned_at IS NULL) = $3::boolean " +
	"OR ($3::boolean AND users.ban_reason <> $4::text)) " +
	"RETURNING users.banned_at IS NOT NULL AS banned) " +
	"SELECT d.outcome, EXISTS (SELECT 1 FROM updated)::text, t.id::text, t.nickname, " +
	"t.nickname_locked::text, t.is_admin::text, " +
	"COALESCE((SELECT banned FROM updated), t.banned)::text, t.nickname, " +
	"COALESCE(t.public_key_hex, ''), COALESCE(t.has_key, false)::text, " +
	"t.role_ids, t.permissions::text, COALESCE(t.restricted, false)::text " +
	"FROM decision d LEFT JOIN target t ON true"

// Protocol 25 (#43, D11): $3 is true to restrict the account and false to lift it. Admins
// cannot be restricted (admin_target). Lifting adds the account to every Public room in the
// same statement (column 13, the room IDs); setting it removes no membership.
DATABASE_ADMIN_SET_RESTRICTED_SQL ::
	DATABASE_ADMIN_ACTOR_AND_TARGET_SQL +
	"decision AS (SELECT CASE " +
	"WHEN NOT (SELECT ok FROM actor) THEN 'not_admin' " +
	"WHEN NOT EXISTS (SELECT 1 FROM target) THEN 'unknown_user' " +
	"WHEN $3::boolean AND (SELECT is_admin FROM target) THEN 'admin_target' " +
	"ELSE 'applied' END AS outcome), " +
	"updated AS (UPDATE users SET restricted = $3::boolean FROM decision d " +
	"WHERE users.id = $2::bigint AND d.outcome = 'applied' " +
	"AND users.restricted <> $3::boolean RETURNING users.id), " +
	"joined AS (INSERT INTO room_members (room_id, user_id) " +
	"SELECT r.id, updated.id FROM rooms r CROSS JOIN updated " +
	"WHERE r.access = 1 AND NOT $3::boolean ON CONFLICT DO NOTHING RETURNING room_id) " +
	"SELECT d.outcome, EXISTS (SELECT 1 FROM updated)::text, t.id::text, t.nickname, " +
	"t.nickname_locked::text, t.is_admin::text, t.banned::text, t.nickname, " +
	"COALESCE(t.public_key_hex, ''), COALESCE(t.has_key, false)::text, " +
	"t.role_ids, t.permissions::text, " +
	"(CASE WHEN d.outcome = 'applied' THEN $3::boolean ELSE t.restricted END)::text, " +
	"COALESCE((SELECT string_agg(room_id::text, ',' ORDER BY room_id) FROM joined), '') " +
	"FROM decision d LEFT JOIN target t ON true"

databaseAdminOutcomeFromText :: proc(text: string) -> (common.DatabaseAdminOutcome, bool) {
	switch text {
	case "applied":
		return .Applied, true
	case "not_admin":
		return .NotAdmin, true
	case "unknown_user":
		return .UnknownUser, true
	case "self":
		return .SelfTarget, true
	case "admin_target":
		return .AdminTarget, true
	case "last_admin":
		return .LastAdmin, true
	case "nickname_taken":
		return .NicknameTaken, true
	case "banned_target":
		return .BannedTarget, true
	}
	return .NotAdmin, false
}

databaseExecuteAdminUser :: proc(
	conn: pg.Conn,
	request: common.DatabaseAdminUserRequest,
) -> common.DatabaseQueryResponse {
	actorParam := databaseIntParam(request.actorUserId)
	defer delete(actorParam)
	targetParam := databaseIntParam(request.targetUserId)
	defer delete(targetParam)

	query: cstring
	flag: bool
	text: string
	#partial switch request.action {
	case .SetRole:
		query = DATABASE_ADMIN_SET_ROLE_SQL
		flag = request.isAdmin
	case .Rename:
		query = DATABASE_ADMIN_RENAME_SQL
		text = request.nickname
		flag = request.locked
	case .Kick:
		query = DATABASE_ADMIN_KICK_SQL
	case .Ban:
		query = DATABASE_ADMIN_BAN_SQL
		flag = request.banned
		text = request.reason
	case .SetRestricted:
		query = DATABASE_ADMIN_SET_RESTRICTED_SQL
		flag = request.restricted
	case:
		// Role actions are DatabaseRoleRequests (database_roles.odin).
		return databaseErrorResponse(strings.clone("not an account admin action"))
	}
	flagParam := strings.clone_to_cstring(flag ? "true" : "false")
	defer delete(flagParam)
	textParam := strings.clone_to_cstring(text)
	defer delete(textParam)

	// Every statement takes $1 and $2; the others take the flag and the text in the order
	// their SQL names them.
	params := make([dynamic][^]byte, 0, 4)
	defer delete(params)
	append(&params, transmute([^]byte)actorParam, transmute([^]byte)targetParam)
	#partial switch request.action {
	case .SetRole:
		append(&params, transmute([^]byte)flagParam)
	case .Rename:
		append(&params, transmute([^]byte)textParam, transmute([^]byte)flagParam)
	case .Kick:
	case .Ban:
		append(&params, transmute([^]byte)flagParam, transmute([^]byte)textParam)
	case .SetRestricted:
		append(&params, transmute([^]byte)flagParam)
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
	outcome, outcomeOK := databaseAdminOutcomeFromText(outcomeText)
	if !outcomeOK {
		return databaseErrorResponse(strings.clone("database returned an unknown admin outcome"))
	}
	if outcome != .Applied {
		return databaseSuccess(common.DatabaseAdminUserResult{outcome = outcome})
	}
	adminResult, rowOK := databaseGetAdminUserRow(result, 0, request.action == .SetRestricted)
	if !rowOK {
		return databaseErrorResponse(strings.clone("database returned an invalid user ID"))
	}
	return databaseSuccess(adminResult)
}

// An Applied row of the admin statements (columns 1..12, see the file comment, and with
// addedRooms column 13, the Public rooms a lifted restriction joined) as an owned result.
// DATABASE_RESTRICTED_CHANGES_SQL (#116) returns the same columns. false for a row without a
// valid user ID, with nothing allocated.
databaseGetAdminUserRow :: proc(
	result: pg.Result,
	row: i32,
	addedRooms: bool,
) -> (
	common.DatabaseAdminUserResult,
	bool,
) {
	userID, userIDOK := databaseGetInt(result, row, 2)
	if !userIDOK {
		return {}, false
	}
	adminResult := common.DatabaseAdminUserResult {
		outcome = .Applied,
		changed = databaseGetBool(result, row, 1),
	}
	roleIDs := databaseGetText(result, row, 10)
	defer delete(roleIDs)
	mask, _ := databaseGetInt(result, row, 11)
	adminResult.user = common.UserSummary {
		id               = userID,
		nickname         = databaseGetText(result, row, 3),
		isAdmin          = databaseGetBool(result, row, 5),
		isBanned         = databaseGetBool(result, row, 6),
		hasEncryptionKey = databaseGetBool(result, row, 9),
		roleIds          = databaseParseIDList(roleIDs),
		isRestricted     = databaseGetBool(result, row, 12),
	}
	adminResult.user.identityPublicKey = databaseGetIdentityPublicKey(result, row, 8)
	if addedRooms {
		added := databaseGetText(result, row, 13)
		defer delete(added)
		adminResult.addedRoomIDs = databaseParseIDList(added)
	}
	adminResult.permissions = common.serverPermissionsFromMask(i64(mask))
	adminResult.nicknameLocked = databaseGetBool(result, row, 4)
	adminResult.previousNickname = databaseGetText(result, row, 7)
	return adminResult, true
}
