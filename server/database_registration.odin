package server

import "../common"
import "core:strings"
import "shared:pg"

// Registration (protocol 25, migration 13, #43 G1, plan D7-D17). Like every other client
// action, each request is one statement that checks the requester's permission and every
// guard in the same statement as the change (D4).
//
// The registration mode is server_settings.registration_mode (D7). Invite codes are stored
// only as sha256 of their raw bytes (invites.code_hash, D9), and a code is matched by that
// hash inside the statement; the router never sees a stored code. A use is counted when the
// statement accepts a sign-up or a request, never for a refusal, and a declined request does
// not give it back (D9). Non-admin inviters create plain codes only, with an expiry of at most
// common.INVITE_INVITER_EXPIRY_MAX_SECONDS, and see and revoke only their own (D10).
//
// Restricted accounts (users.restricted, D11) never join Public rooms automatically (the
// identity, register, create room, edit room and default room statements skip them) and
// only accounts holding ManageMembers in a room may add them to it. Their roles' Role rooms
// are joined like anyone else's: only admins give roles. D17's visibility rule, used by the
// user list and direct message statements, is DATABASE_USERS_MAY_MEET_* below; the direct
// message paths that name a peer and the key fetch (#103) also use
// DATABASE_DIRECT_PEER_KNOWN_*.

// Whether two accounts may see each other and exchange direct messages (D17): neither is
// restricted, they share a room, or either is an admin. A scalar boolean (false when neither
// account exists), built as
//
//   DATABASE_USERS_MAY_MEET_OPEN_SQL + a + DATABASE_USERS_MAY_MEET_MIDDLE_SQL + b +
//   DATABASE_USERS_MAY_MEET_CLOSE_SQL
//
// where a and b are account ID expressions, which may name outer aliases; its own aliases
// start with meet_.
DATABASE_USERS_MAY_MEET_OPEN_SQL ::
	"COALESCE((SELECT (NOT bool_or(meet_u.restricted) " +
	"OR EXISTS (SELECT 1 FROM room_members meet_a JOIN room_members meet_b " +
	"ON meet_b.room_id = meet_a.room_id WHERE meet_a.user_id = meet_ids.a " +
	"AND meet_b.user_id = meet_ids.b) OR EXISTS (SELECT 1 FROM user_server_roles meet_h " +
	"JOIN server_roles meet_r ON meet_r.id = meet_h.role_id WHERE meet_r.builtin " +
	"AND meet_h.user_id IN (meet_ids.a, meet_ids.b))) FROM (SELECT "
DATABASE_USERS_MAY_MEET_MIDDLE_SQL :: "::bigint AS a, "
DATABASE_USERS_MAY_MEET_CLOSE_SQL ::
	"::bigint AS b) meet_ids JOIN users meet_u ON meet_u.id IN (meet_ids.a, meet_ids.b) " +
	"GROUP BY meet_ids.a, meet_ids.b), false)"

// Whether account a knows account b as a direct message peer (D17, #103): they may meet
// (DATABASE_USERS_MAY_MEET_*), or they already have a conversation, whose history stays
// readable after the last shared room is gone. Every direct message path that names a peer
// treats a peer a does not know exactly as an account that does not exist, so a restricted
// account cannot tell the two apart; a known peer it may no longer meet gets the restricted
// refusal. A scalar boolean, built as
//
//   DATABASE_DIRECT_PEER_KNOWN_OPEN_SQL + a + DATABASE_DIRECT_PEER_KNOWN_MIDDLE_SQL + b +
//   DATABASE_DIRECT_PEER_KNOWN_CLOSE_SQL
//
// where a and b are account ID expressions, which may name outer aliases; its own aliases start
// with pk_ (and meet_).
DATABASE_DIRECT_PEER_KNOWN_OPEN_SQL ::
	"(SELECT " + DATABASE_USERS_MAY_MEET_OPEN_SQL + "pk_ids.a" +
	DATABASE_USERS_MAY_MEET_MIDDLE_SQL + "pk_ids.b" + DATABASE_USERS_MAY_MEET_CLOSE_SQL +
	" OR EXISTS (SELECT 1 FROM direct_messages pk_h WHERE pk_h.sender_user_id = pk_ids.a " +
	"AND pk_h.recipient_user_id = pk_ids.b) " +
	"OR EXISTS (SELECT 1 FROM direct_messages pk_h WHERE pk_h.sender_user_id = pk_ids.b " +
	"AND pk_h.recipient_user_id = pk_ids.a) FROM (SELECT "
DATABASE_DIRECT_PEER_KNOWN_MIDDLE_SQL :: "::bigint AS a, "
DATABASE_DIRECT_PEER_KNOWN_CLOSE_SQL :: "::bigint AS b) pk_ids)"

// Whether the requester ($1) holds CreateInvites / ApproveRegistrations (admins hold both).
DATABASE_ACTOR_CREATES_INVITES_SQL ::
	"((" + DATABASE_ACTOR_PERMISSIONS_SQL + " & " + DATABASE_PERMISSION_CREATE_INVITES_SQL +
	") <> 0)"
DATABASE_ACTOR_APPROVES_REGISTRATIONS_SQL ::
	"((" + DATABASE_ACTOR_PERMISSIONS_SQL + " & " +
	DATABASE_PERMISSION_APPROVE_REGISTRATIONS_SQL + ") <> 0)"

// The registration mode, Open when the row is missing.
DATABASE_REGISTRATION_MODE_SQL ::
	"COALESCE((SELECT registration_mode FROM server_settings WHERE id = 1), 1)"

// One ClientRegister. $1 sha256 of the code (hex, '' for no code), $2 the identity key (hex),
// $3 the session's nickname, $4 the reason ('' for none).
//
// The decision, in order: has_account (the key owns an account; the identity statement should
// have signed it in), already_pending (the key has a pending or approved request), invalid_code
// (no code on a server that is not Open, or a code that is unknown, revoked, expired, used up,
// or restricted to a room that is gone or no longer an unencrypted invite room), name_taken,
// reason_required and pending (Invite + approval without the code's skip approval), else
// created. A declined request of the key is replaced by a new one. The code row is locked
// (FOR UPDATE), so two sign-ups racing for its last use are applied one after the other and
// the second one no longer matches.
//
// created inserts the account (restricted and with the code's ID when the code has a room),
// gives it the code's roles, joins it to the Public rooms (unless restricted), the code's room
// and its roles' Role rooms, and deletes an older request of the key; pending inserts or
// replaces the request. Either one counts a use. The insert's ON CONFLICT turns a name or key
// taken in between into name_taken, which counts nothing.
//
// One row: outcome, the new account's ID, its restriction, its permission mask (the code's
// roles), the mode, the code's ID, then (pending) the request in DATABASE_REQUEST_COLUMNS_SQL
// order and the pending count after it, and (#102) the code's role IDs (comma separated), which
// a created account holds.
DATABASE_REGISTER_SQL ::
	"WITH settings AS (SELECT " + DATABASE_REGISTRATION_MODE_SQL + " AS mode), " +
	"by_key AS (SELECT id FROM users WHERE public_key = decode($2::text, 'hex')), " +
	"prior AS (SELECT id, status FROM registration_requests " +
	"WHERE public_key = decode($2::text, 'hex')), " +
	"taken AS (SELECT 1 FROM users WHERE nickname = $3::text), " +
	"code AS (SELECT i.id, i.room_id, i.restricted, i.skip_approval FROM invites i " +
	"WHERE $1::text <> '' AND i.code_hash = decode(NULLIF($1::text, ''), 'hex') " +
	"AND i.revoked_at IS NULL " +
	"AND (i.expires_at IS NULL OR i.expires_at > CURRENT_TIMESTAMP) " +
	"AND (i.max_uses IS NULL OR i.uses < i.max_uses) " +
	"AND (NOT i.restricted OR EXISTS (SELECT 1 FROM rooms r WHERE r.id = i.room_id " +
	"AND r.access IN (2, 3) AND NOT r.encrypted)) FOR UPDATE OF i), " +
	"needs_approval AS (SELECT (SELECT mode FROM settings) = 3 " +
	"AND NOT COALESCE((SELECT skip_approval FROM code), false) AS yes), " +
	"decision AS (SELECT CASE " +
	"WHEN EXISTS (SELECT 1 FROM by_key) THEN 'has_account' " +
	"WHEN EXISTS (SELECT 1 FROM prior WHERE status IN (1, 2)) THEN 'already_pending' " +
	"WHEN $1::text = '' AND (SELECT mode FROM settings) <> 1 THEN 'invalid_code' " +
	"WHEN $1::text <> '' AND NOT EXISTS (SELECT 1 FROM code) THEN 'invalid_code' " +
	"WHEN EXISTS (SELECT 1 FROM taken) THEN 'name_taken' " +
	"WHEN (SELECT yes FROM needs_approval) AND $4::text = '' THEN 'reason_required' " +
	"WHEN (SELECT yes FROM needs_approval) THEN 'pending' " +
	"ELSE 'created' END AS outcome), " +
	"inserted AS (INSERT INTO users (nickname, public_key, restricted, invite_id) " +
	"SELECT $3::text, decode($2::text, 'hex'), COALESCE((SELECT restricted FROM code), false), " +
	"(SELECT id FROM code) FROM decision WHERE outcome = 'created' " +
	"ON CONFLICT DO NOTHING RETURNING id, restricted), " +
	"requested AS (INSERT INTO registration_requests (public_key, nickname, reason, invite_id) " +
	"SELECT decode($2::text, 'hex'), $3::text, $4::text, code.id FROM code, decision " +
	"WHERE outcome = 'pending' " +
	"ON CONFLICT (public_key) DO UPDATE SET nickname = EXCLUDED.nickname, " +
	"reason = EXCLUDED.reason, invite_id = EXCLUDED.invite_id, status = 1, " +
	"decided_by_user_id = NULL, decision_reason = '', created_at = CURRENT_TIMESTAMP, " +
	"decided_at = NULL WHERE registration_requests.status = 3 " +
	"RETURNING id, nickname, reason, status, public_key, invite_id, created_at, " +
	"decided_by_user_id, decided_at, decision_reason), " +
	"used AS (UPDATE invites SET uses = invites.uses + 1 FROM code WHERE invites.id = code.id " +
	"AND (EXISTS (SELECT 1 FROM inserted) OR EXISTS (SELECT 1 FROM requested))), " +
	"granted AS (INSERT INTO user_server_roles (user_id, role_id) " +
	"SELECT inserted.id, ir.role_id FROM inserted CROSS JOIN code " +
	"JOIN invite_roles ir ON ir.invite_id = code.id " +
	"JOIN server_roles sr ON sr.id = ir.role_id AND NOT sr.builtin ON CONFLICT DO NOTHING), " +
	"joined AS (INSERT INTO room_members (room_id, user_id) " +
	"SELECT r.id, inserted.id FROM rooms r CROSS JOIN inserted " +
	"WHERE r.access = 1 AND NOT inserted.restricted " +
	"OR (r.id = (SELECT room_id FROM code) AND r.access IN (2, 3) AND NOT r.encrypted) " +
	"OR (r.access = 4 AND EXISTS (SELECT 1 FROM room_access_roles ar " +
	"JOIN invite_roles ir ON ir.role_id = ar.role_id JOIN code c ON c.id = ir.invite_id " +
	"WHERE ar.room_id = r.id)) ON CONFLICT DO NOTHING), " +
	"cleared AS (DELETE FROM registration_requests rr USING inserted " +
	"WHERE rr.public_key = decode($2::text, 'hex')) " +
	"SELECT CASE WHEN d.outcome = 'created' AND NOT EXISTS (SELECT 1 FROM inserted) " +
	"THEN 'name_taken' WHEN d.outcome = 'pending' AND NOT EXISTS (SELECT 1 FROM requested) " +
	"THEN 'already_pending' ELSE d.outcome END, " +
	"(SELECT id FROM inserted)::text, COALESCE((SELECT restricted FROM inserted), false)::text, " +
	"COALESCE((SELECT bit_or(sr.permissions) FROM code c " +
	"JOIN invite_roles ir ON ir.invite_id = c.id " +
	"JOIN server_roles sr ON sr.id = ir.role_id AND NOT sr.builtin), 0)::text, " +
	"(SELECT mode FROM settings)::text, COALESCE((SELECT id FROM code), 0)::text, " +
	DATABASE_REQUEST_COLUMNS_SQL + ", " +
	"((SELECT count(*) FROM registration_requests WHERE status = 1) + " +
	"(SELECT count(*) FROM requested))::text, " +
	"COALESCE((SELECT string_agg(ir.role_id::text, ',' ORDER BY ir.role_id) FROM code c " +
	"JOIN invite_roles ir ON ir.invite_id = c.id " +
	"JOIN server_roles sr ON sr.id = ir.role_id AND NOT sr.builtin), '') " +
	"FROM decision d LEFT JOIN requested rr ON true LEFT JOIN invites i ON i.id = rr.invite_id"

// The columns of one request for databaseGetRegistrationRequest, from a registration_requests
// row aliased rr joined to its invites row i: ID, nickname, reason, status, identity key (hex),
// the code's ID, note and creator (0 for an operator), created, decided by (0), decided at
// ('' while pending) and the decision reason.
DATABASE_REQUEST_COLUMNS_SQL ::
	"rr.id::text, rr.nickname::text, rr.reason::text, rr.status::text, " +
	"encode(rr.public_key, 'hex'), rr.invite_id::text, COALESCE(i.note, '')::text, " +
	"COALESCE(i.created_by_user_id, 0)::text, rr.created_at::text, " +
	"COALESCE(rr.decided_by_user_id, 0)::text, COALESCE(rr.decided_at::text, ''), " +
	"rr.decision_reason::text"

// The number of columns DATABASE_REQUEST_COLUMNS_SQL has.
DATABASE_REQUEST_COLUMN_COUNT :: 12

// The columns of one code for databaseGetInviteSummary, from an invites row aliased i: ID,
// note, creator (0), its nickname, created, expires ('' never), use limit (0 none), uses,
// revoked, role IDs (comma separated), room (0), restricted, skip approval.
DATABASE_INVITE_COLUMNS_SQL ::
	"i.id::text, i.note::text, COALESCE(i.created_by_user_id, 0)::text, " +
	"COALESCE((SELECT nickname FROM users WHERE id = i.created_by_user_id), '')::text, " +
	"i.created_at::text, COALESCE(i.expires_at::text, ''), COALESCE(i.max_uses, 0)::text, " +
	"i.uses::text, (i.revoked_at IS NOT NULL)::text, " +
	"COALESCE((SELECT string_agg(ir.role_id::text, ',' ORDER BY ir.role_id) " +
	"FROM invite_roles ir WHERE ir.invite_id = i.id), ''), COALESCE(i.room_id, 0)::text, " +
	"i.restricted::text, i.skip_approval::text"

// The number of columns DATABASE_INVITE_COLUMNS_SQL has.
DATABASE_INVITE_COLUMN_COUNT :: 13

// $1 the requester, $2 sha256 of the new code (hex), $3 the note, $4 seconds until it expires
// (0 never), $5 its use limit (0 none), $6 its roles (bigint array), $7 its room (0 none), $8
// skip approval, $9 INVITE_INVITER_EXPIRY_MAX_SECONDS, $10 INVITES_ACTIVE_MAX_PER_INVITER.
// Outcomes in order: not_permitted (no CreateInvites), admin_required (a non-admin attaching
// roles, a room or skip approval), expiry_too_long (a non-admin without an expiry or with a
// longer one), unknown_role (unknown or built-in), bad_room (missing, Public, Role or
// encrypted), too_many_invites (a non-admin's usable codes), applied. One row: outcome, then
// the stored code in DATABASE_INVITE_COLUMNS_SQL order (NULL unless applied). The role IDs
// and the creator's nickname come from the request and the snapshot, since the statement's own
// inserts are not visible to it.
DATABASE_CREATE_INVITE_SQL ::
	"WITH actor AS (SELECT " + DATABASE_ACTOR_IS_ADMIN_SQL + " AS is_admin, " +
	DATABASE_ACTOR_CREATES_INVITES_SQL + " AS may_invite), " +
	"wanted AS (SELECT DISTINCT unnest($6::bigint[]) AS role_id), " +
	"active AS (SELECT count(*) AS n FROM invites WHERE created_by_user_id = $1::bigint " +
	"AND revoked_at IS NULL AND (expires_at IS NULL OR expires_at > CURRENT_TIMESTAMP) " +
	"AND (max_uses IS NULL OR uses < max_uses)), " +
	"decision AS (SELECT CASE " +
	"WHEN NOT (SELECT may_invite FROM actor) THEN 'not_permitted' " +
	"WHEN NOT (SELECT is_admin FROM actor) AND (EXISTS (SELECT 1 FROM wanted) " +
	"OR $7::bigint <> 0 OR $8::boolean) THEN 'admin_required' " +
	"WHEN NOT (SELECT is_admin FROM actor) AND ($4::bigint <= 0 OR $4::bigint > $9::bigint) " +
	"THEN 'expiry_too_long' " +
	"WHEN EXISTS (SELECT 1 FROM wanted w LEFT JOIN server_roles r ON r.id = w.role_id " +
	"WHERE r.id IS NULL OR r.builtin) THEN 'unknown_role' " +
	"WHEN $7::bigint <> 0 AND NOT EXISTS (SELECT 1 FROM rooms r WHERE r.id = $7::bigint " +
	"AND r.access IN (2, 3) AND NOT r.encrypted) THEN 'bad_room' " +
	"WHEN NOT (SELECT is_admin FROM actor) AND (SELECT n FROM active) >= $10::bigint " +
	"THEN 'too_many_invites' " +
	"ELSE 'applied' END AS outcome), " +
	"created AS (INSERT INTO invites (code_hash, created_by_user_id, note, expires_at, " +
	"max_uses, room_id, restricted, skip_approval) " +
	"SELECT decode($2::text, 'hex'), $1::bigint, $3::text, CASE WHEN $4::bigint > 0 " +
	"THEN CURRENT_TIMESTAMP + $4::bigint * interval '1 second' END, " +
	"NULLIF($5::integer, 0), NULLIF($7::bigint, 0), $7::bigint <> 0, $8::boolean " +
	"FROM decision WHERE outcome = 'applied' RETURNING *), " +
	"roles AS (INSERT INTO invite_roles (invite_id, role_id) " +
	"SELECT c.id, w.role_id FROM created c CROSS JOIN wanted w) " +
	"SELECT d.outcome, i.id::text, i.note::text, COALESCE(i.created_by_user_id, 0)::text, " +
	"COALESCE((SELECT nickname FROM users WHERE id = $1::bigint), '')::text, " +
	"i.created_at::text, COALESCE(i.expires_at::text, ''), COALESCE(i.max_uses, 0)::text, " +
	"i.uses::text, (i.revoked_at IS NOT NULL)::text, " +
	"COALESCE((SELECT string_agg(role_id::text, ',' ORDER BY role_id) FROM wanted), ''), " +
	"COALESCE(i.room_id, 0)::text, i.restricted::text, i.skip_approval::text " +
	"FROM decision d LEFT JOIN created i ON true"

// $1 the requester, $2 the most rows. Admins see every code, other holders of CreateInvites
// their own, newest first. The first column says whether the requester may list at all; one
// row with NULL code columns comes back when it may not or there is no code.
DATABASE_LIST_INVITES_SQL ::
	"WITH actor AS (SELECT " + DATABASE_ACTOR_IS_ADMIN_SQL + " AS is_admin, " +
	DATABASE_ACTOR_CREATES_INVITES_SQL + " AS may_invite) " +
	"SELECT a.may_invite::text, " + DATABASE_INVITE_COLUMNS_SQL + " FROM actor a " +
	"LEFT JOIN LATERAL (SELECT * FROM invites WHERE a.may_invite " +
	"AND (a.is_admin OR created_by_user_id = $1::bigint) ORDER BY id DESC LIMIT $2::bigint) i " +
	"ON true ORDER BY i.id DESC"

// $1 the requester, $2 the code. Admins revoke any code, anyone else only one it created
// (unknown_invite otherwise, so codes of others stay invisible). Revoking a revoked code
// changes nothing. One row: outcome, changed.
DATABASE_REVOKE_INVITE_SQL ::
	"WITH actor AS (SELECT " + DATABASE_ACTOR_IS_ADMIN_SQL + " AS is_admin), " +
	"target AS (SELECT id, created_by_user_id FROM invites WHERE id = $2::bigint), " +
	"decision AS (SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM target) " +
	"OR (NOT (SELECT is_admin FROM actor) " +
	"AND (SELECT created_by_user_id FROM target) IS DISTINCT FROM $1::bigint) " +
	"THEN 'unknown_invite' ELSE 'applied' END AS outcome), " +
	"revoked AS (UPDATE invites SET revoked_at = CURRENT_TIMESTAMP FROM decision d " +
	"WHERE invites.id = $2::bigint AND d.outcome = 'applied' AND invites.revoked_at IS NULL " +
	"RETURNING invites.id) " +
	"SELECT d.outcome, EXISTS (SELECT 1 FROM revoked)::text FROM decision d"

// $1 the requester, $2 include decided requests, $3 the most decided rows. Holders of
// ApproveRegistrations get every pending request (oldest first) and, with $2, the newest
// decided ones. Columns: allowed, the pending count, then the request (NULL when there is
// none) in DATABASE_REQUEST_COLUMNS_SQL order.
DATABASE_LIST_REGISTRATION_REQUESTS_SQL ::
	"WITH actor AS (SELECT " + DATABASE_ACTOR_APPROVES_REGISTRATIONS_SQL + " AS ok), " +
	"listed AS (SELECT * FROM (SELECT q.*, 0 AS part, q.id AS sort_key " +
	"FROM registration_requests q WHERE q.status = 1) p UNION ALL SELECT * FROM (" +
	"SELECT q.*, 1, -q.id FROM registration_requests q WHERE $2::boolean AND q.status <> 1 " +
	"ORDER BY q.id DESC LIMIT $3::bigint) d) " +
	"SELECT a.ok::text, (SELECT count(*) FROM registration_requests WHERE status = 1)::text, " +
	DATABASE_REQUEST_COLUMNS_SQL + " FROM actor a " +
	"LEFT JOIN listed rr ON a.ok LEFT JOIN invites i ON i.id = rr.invite_id " +
	"ORDER BY rr.part, rr.sort_key"

// $1 the requester, $2 the request, $3 approve, $4 the decision reason. Outcomes in order:
// not_permitted (no ApproveRegistrations), unknown_request, already_decided, room_unavailable
// (#115: approving a room code's request whose room is gone or no longer an unencrypted Member
// or Admin invite room; declining it still works), applied. One row: outcome, the pending
// count after it, then the request after it (NULL unless applied).
DATABASE_DECIDE_REGISTRATION_SQL ::
	"WITH actor AS (SELECT " + DATABASE_ACTOR_APPROVES_REGISTRATIONS_SQL + " AS ok), " +
	"target AS (SELECT q.id, q.status, i.restricted, i.room_id FROM registration_requests q " +
	"JOIN invites i ON i.id = q.invite_id WHERE q.id = $2::bigint), " +
	"decision AS (SELECT CASE WHEN NOT (SELECT ok FROM actor) THEN 'not_permitted' " +
	"WHEN NOT EXISTS (SELECT 1 FROM target) THEN 'unknown_request' " +
	"WHEN (SELECT status FROM target) <> 1 THEN 'already_decided' " +
	"WHEN $3::boolean AND (SELECT restricted FROM target) AND NOT EXISTS (SELECT 1 FROM rooms r " +
	"WHERE r.id = (SELECT room_id FROM target) AND r.access IN (2, 3) AND NOT r.encrypted) " +
	"THEN 'room_unavailable' " +
	"ELSE 'applied' END AS outcome), " +
	"updated AS (UPDATE registration_requests q SET " +
	"status = CASE WHEN $3::boolean THEN 2 ELSE 3 END, decided_by_user_id = $1::bigint, " +
	"decision_reason = $4::text, decided_at = CURRENT_TIMESTAMP FROM decision d " +
	"WHERE q.id = $2::bigint AND d.outcome = 'applied' AND q.status = 1 RETURNING q.*) " +
	"SELECT d.outcome, ((SELECT count(*) FROM registration_requests WHERE status = 1) - " +
	"(SELECT count(*) FROM updated))::text, " + DATABASE_REQUEST_COLUMNS_SQL +
	" FROM decision d LEFT JOIN updated rr ON true LEFT JOIN invites i ON i.id = rr.invite_id"

// $1 the requester, $2 the mode. Admins only. One row: allowed, changed, the mode after it.
DATABASE_SET_REGISTRATION_MODE_SQL ::
	"WITH actor AS (SELECT " + DATABASE_ACTOR_IS_ADMIN_SQL + " AS ok), " +
	"updated AS (INSERT INTO server_settings (id, registration_mode) " +
	"SELECT 1, $2::smallint FROM actor WHERE ok " +
	"ON CONFLICT (id) DO UPDATE SET registration_mode = EXCLUDED.registration_mode " +
	"WHERE server_settings.registration_mode <> EXCLUDED.registration_mode " +
	"RETURNING registration_mode) " +
	"SELECT a.ok::text, EXISTS (SELECT 1 FROM updated)::text, COALESCE((SELECT " +
	"registration_mode FROM updated), " + DATABASE_REGISTRATION_MODE_SQL + ")::text " +
	"FROM actor a"

// $1 an account, $2 candidates (bigint array): those that may see $1 because they share a room
// with it or either of the two is an admin (D17).
DATABASE_SHARED_ROOMS_SQL ::
	"SELECT c.id::text FROM unnest($2::bigint[]) c(id) WHERE EXISTS (SELECT 1 " +
	"FROM room_members a JOIN room_members b ON b.room_id = a.room_id " +
	"WHERE a.user_id = $1::bigint AND b.user_id = c.id) " +
	"OR EXISTS (SELECT 1 FROM user_server_roles h JOIN server_roles r ON r.id = h.role_id " +
	"WHERE r.builtin AND h.user_id IN ($1::bigint, c.id)) ORDER BY c.id"

DATABASE_RESTRICTED_USERS_SQL :: "SELECT id::text FROM users WHERE restricted ORDER BY id"

databaseGetRegistrationMode :: proc(
	result: pg.Result,
	row: i32,
	column: i32,
) -> common.RegistrationMode {
	value, ok := databaseGetInt(result, row, column)
	mode := common.RegistrationMode(value)
	if !ok || !common.registrationModeIsSupported(mode) {
		// A broken row reads as the mode that lets the fewest people in.
		return .InviteApproval
	}
	return mode
}

databaseGetRegistrationRequestStatus :: proc(
	result: pg.Result,
	row: i32,
	column: i32,
) -> common.RegistrationRequestStatus {
	value, _ := databaseGetInt(result, row, column)
	switch value {
	case 1:
		return .Pending
	case 2:
		return .Approved
	case 3:
		return .Declined
	}
	return .None
}

// Reads a request in DATABASE_REQUEST_COLUMNS_SQL order at first; ok is false for NULLs.
databaseGetRegistrationRequest :: proc(
	result: pg.Result,
	row: i32,
	first: i32,
) -> (
	request: common.RegistrationRequestSummary,
	ok: bool,
) {
	request.id, ok = databaseGetInt(result, row, first)
	if !ok {
		return {}, false
	}
	request.nickname = databaseGetText(result, row, first + 1)
	request.reason = databaseGetText(result, row, first + 2)
	request.status = databaseGetRegistrationRequestStatus(result, row, first + 3)
	request.identityPublicKey = databaseGetIdentityPublicKey(result, row, first + 4)
	request.inviteId, _ = databaseGetInt(result, row, first + 5)
	request.inviteNote = databaseGetText(result, row, first + 6)
	request.inviteCreatedBy, _ = databaseGetInt(result, row, first + 7)
	request.createdAt = databaseGetText(result, row, first + 8)
	request.decidedBy, _ = databaseGetInt(result, row, first + 9)
	request.decidedAt = databaseGetText(result, row, first + 10)
	request.decisionReason = databaseGetText(result, row, first + 11)
	return request, true
}

// Reads a code in DATABASE_INVITE_COLUMNS_SQL order at first; ok is false for NULLs.
databaseGetInviteSummary :: proc(
	result: pg.Result,
	row: i32,
	first: i32,
) -> (
	invite: common.InviteSummary,
	ok: bool,
) {
	invite.id, ok = databaseGetInt(result, row, first)
	if !ok {
		return {}, false
	}
	invite.note = databaseGetText(result, row, first + 1)
	invite.createdBy, _ = databaseGetInt(result, row, first + 2)
	invite.createdByNickname = databaseGetText(result, row, first + 3)
	invite.createdAt = databaseGetText(result, row, first + 4)
	invite.expiresAt = databaseGetText(result, row, first + 5)
	invite.maxUses, _ = databaseGetInt(result, row, first + 6)
	invite.uses, _ = databaseGetInt(result, row, first + 7)
	invite.revoked = databaseGetBool(result, row, first + 8)
	roleIDs := databaseGetText(result, row, first + 9)
	defer delete(roleIDs)
	invite.roleIds = databaseParseIDList(roleIDs)
	invite.roomId, _ = databaseGetInt(result, row, first + 10)
	invite.restricted = databaseGetBool(result, row, first + 11)
	invite.skipApproval = databaseGetBool(result, row, first + 12)
	return invite, true
}

@(private = "file")
databaseRegisterOutcomeFromText :: proc(text: string) -> (common.DatabaseRegisterOutcome, bool) {
	switch text {
	case "created":
		return .Created, true
	case "pending":
		return .Pending, true
	case "already_pending":
		return .AlreadyPending, true
	case "invalid_code":
		return .InvalidCode, true
	case "name_taken":
		return .NameTaken, true
	case "reason_required":
		return .ReasonRequired, true
	case "has_account":
		return .HasAccount, true
	}
	return .InvalidCode, false
}

databaseExecuteRegister :: proc(
	conn: pg.Conn,
	request: common.DatabaseRegisterRequest,
) -> common.DatabaseQueryResponse {
	codeHashHex := ""
	if request.hasCode {
		hash := request.codeHash
		codeHashHex = common.encodeBytesToHex(hash[:])
	}
	defer delete(codeHashHex)
	codeParam := strings.clone_to_cstring(codeHashHex)
	defer delete(codeParam)
	publicKeyHex := common.identityPublicKeyToHex(request.publicKey)
	defer delete(publicKeyHex)
	keyParam := strings.clone_to_cstring(publicKeyHex)
	defer delete(keyParam)
	nicknameParam := strings.clone_to_cstring(request.nickname)
	defer delete(nicknameParam)
	reasonParam := strings.clone_to_cstring(request.reason)
	defer delete(reasonParam)
	params := [?][^]byte {
		transmute([^]byte)codeParam,
		transmute([^]byte)keyParam,
		transmute([^]byte)nicknameParam,
		transmute([^]byte)reasonParam,
	}
	result := databaseExecParams(conn, DATABASE_REGISTER_SQL, params[:])
	if result == nil {
		return databaseConnectionError(conn)
	}
	defer pg.clear(result)
	if pg.result_status(result) != .Tuples_OK || pg.n_tuples(result) != 1 {
		return databaseResultError(&result)
	}
	outcomeText := databaseGetText(result, 0, 0)
	defer delete(outcomeText)
	outcome, outcomeOK := databaseRegisterOutcomeFromText(outcomeText)
	if !outcomeOK {
		return databaseErrorResponse(strings.clone("database returned an unknown sign-up outcome"))
	}
	registered := common.DatabaseRegisterResult {
		outcome          = outcome,
		registrationMode = databaseGetRegistrationMode(result, 0, 4),
	}
	registered.inviteId, _ = databaseGetInt(result, 0, 5)
	#partial switch outcome {
	case .Created:
		userID, userIDOK := databaseGetInt(result, 0, 1)
		if !userIDOK {
			return databaseErrorResponse(strings.clone("database returned an invalid user ID"))
		}
		registered.userId = userID
		registered.nickname = strings.clone(request.nickname)
		registered.isRestricted = databaseGetBool(result, 0, 2)
		mask, _ := databaseGetInt(result, 0, 3)
		registered.permissions = common.serverPermissionsFromMask(i64(mask))
		roleIDs := databaseGetText(result, 0, 7 + DATABASE_REQUEST_COLUMN_COUNT)
		defer delete(roleIDs)
		registered.roleIds = databaseParseIDList(roleIDs)
	case .Pending:
		requestSummary, requestOK := databaseGetRegistrationRequest(result, 0, 6)
		if !requestOK {
			return databaseErrorResponse(strings.clone("database returned no sign-up request"))
		}
		registered.request = requestSummary
		registered.pendingCount, _ = databaseGetInt(result, 0, 6 + DATABASE_REQUEST_COLUMN_COUNT)
	}
	return databaseSuccess(registered)
}

@(private = "file")
databaseInviteOutcomeFromText :: proc(text: string) -> (common.DatabaseInviteOutcome, bool) {
	switch text {
	case "applied":
		return .Applied, true
	case "not_permitted":
		return .NotPermitted, true
	case "admin_required":
		return .AdminRequired, true
	case "expiry_too_long":
		return .ExpiryTooLong, true
	case "unknown_role":
		return .UnknownRole, true
	case "bad_room":
		return .BadRoom, true
	case "too_many_invites":
		return .TooManyInvites, true
	case "unknown_invite":
		return .UnknownInvite, true
	}
	return .NotPermitted, false
}

databaseExecuteInviteRequest :: proc(
	conn: pg.Conn,
	request: common.DatabaseInviteRequest,
) -> common.DatabaseQueryResponse {
	actorParam := databaseIntParam(request.actorUserId)
	defer delete(actorParam)
	switch request.action {
	case .Create:
		hash := request.codeHash
		hashHex := common.encodeBytesToHex(hash[:])
		defer delete(hashHex)
		hashParam := strings.clone_to_cstring(hashHex)
		defer delete(hashParam)
		noteParam := strings.clone_to_cstring(request.note)
		defer delete(noteParam)
		expiryParam := databaseIntParam(request.expiresInSeconds)
		defer delete(expiryParam)
		usesParam := databaseIntParam(request.maxUses)
		defer delete(usesParam)
		rolesParam := databaseIntArrayParam(request.roleIds[:])
		defer delete(rolesParam)
		roomParam := databaseIntParam(request.roomId)
		defer delete(roomParam)
		skipParam: cstring = request.skipApproval ? "true" : "false"
		inviterExpiryParam := databaseIntParam(common.INVITE_INVITER_EXPIRY_MAX_SECONDS)
		defer delete(inviterExpiryParam)
		activeParam := databaseIntParam(common.INVITES_ACTIVE_MAX_PER_INVITER)
		defer delete(activeParam)
		params := [?][^]byte {
			transmute([^]byte)actorParam,
			transmute([^]byte)hashParam,
			transmute([^]byte)noteParam,
			transmute([^]byte)expiryParam,
			transmute([^]byte)usesParam,
			transmute([^]byte)rolesParam,
			transmute([^]byte)roomParam,
			transmute([^]byte)skipParam,
			transmute([^]byte)inviterExpiryParam,
			transmute([^]byte)activeParam,
		}
		result := databaseExecParams(conn, DATABASE_CREATE_INVITE_SQL, params[:])
		if result == nil {
			return databaseConnectionError(conn)
		}
		defer pg.clear(result)
		if pg.result_status(result) != .Tuples_OK || pg.n_tuples(result) != 1 {
			return databaseResultError(&result)
		}
		outcomeText := databaseGetText(result, 0, 0)
		defer delete(outcomeText)
		outcome, outcomeOK := databaseInviteOutcomeFromText(outcomeText)
		if !outcomeOK {
			return databaseErrorResponse(strings.clone("database returned an unknown outcome"))
		}
		inviteResult := common.DatabaseInviteResult {
			outcome = outcome,
		}
		if outcome == .Applied {
			invite, inviteOK := databaseGetInviteSummary(result, 0, 1)
			if !inviteOK {
				return databaseErrorResponse(strings.clone("database returned no invite"))
			}
			inviteResult.invite = invite
			inviteResult.changed = true
		}
		return databaseSuccess(inviteResult)
	case .List:
		limitParam := databaseIntParam(common.INVITE_LIST_MAX)
		defer delete(limitParam)
		params := [?][^]byte{transmute([^]byte)actorParam, transmute([^]byte)limitParam}
		result := databaseExecParams(conn, DATABASE_LIST_INVITES_SQL, params[:])
		if result == nil {
			return databaseConnectionError(conn)
		}
		defer pg.clear(result)
		if pg.result_status(result) != .Tuples_OK || pg.n_tuples(result) < 1 {
			return databaseResultError(&result)
		}
		if !databaseGetBool(result, 0, 0) {
			return databaseSuccess(common.DatabaseInviteResult{outcome = .NotPermitted})
		}
		inviteResult := common.DatabaseInviteResult {
			outcome = .Applied,
			invites = make([dynamic]common.InviteSummary, 0, pg.n_tuples(result)),
		}
		for row in 0 ..< pg.n_tuples(result) {
			if invite, ok := databaseGetInviteSummary(result, row, 1); ok {
				append(&inviteResult.invites, invite)
			}
		}
		return databaseSuccess(inviteResult)
	case .Revoke:
		inviteParam := databaseIntParam(request.inviteId)
		defer delete(inviteParam)
		params := [?][^]byte{transmute([^]byte)actorParam, transmute([^]byte)inviteParam}
		result := databaseExecParams(conn, DATABASE_REVOKE_INVITE_SQL, params[:])
		if result == nil {
			return databaseConnectionError(conn)
		}
		defer pg.clear(result)
		if pg.result_status(result) != .Tuples_OK || pg.n_tuples(result) != 1 {
			return databaseResultError(&result)
		}
		outcomeText := databaseGetText(result, 0, 0)
		defer delete(outcomeText)
		outcome, outcomeOK := databaseInviteOutcomeFromText(outcomeText)
		if !outcomeOK {
			return databaseErrorResponse(strings.clone("database returned an unknown outcome"))
		}
		return databaseSuccess(
			common.DatabaseInviteResult {
				outcome = outcome,
				changed = outcome == .Applied && databaseGetBool(result, 0, 1),
			},
		)
	}
	return databaseErrorResponse(strings.clone("unknown invite request"))
}

@(private = "file")
databaseRequestsOutcomeFromText :: proc(
	text: string,
) -> (
	common.DatabaseRegistrationRequestsOutcome,
	bool,
) {
	switch text {
	case "applied":
		return .Applied, true
	case "not_permitted":
		return .NotPermitted, true
	case "unknown_request":
		return .UnknownRequest, true
	case "already_decided":
		return .AlreadyDecided, true
	case "room_unavailable":
		return .RoomUnavailable, true
	}
	return .NotPermitted, false
}

databaseExecuteRegistrationRequests :: proc(
	conn: pg.Conn,
	request: common.DatabaseRegistrationRequestsRequest,
) -> common.DatabaseQueryResponse {
	actorParam := databaseIntParam(request.actorUserId)
	defer delete(actorParam)
	switch request.action {
	case .List:
		decidedParam: cstring = request.includeDecided ? "true" : "false"
		limitParam := databaseIntParam(common.REGISTRATION_REQUESTS_LIST_MAX)
		defer delete(limitParam)
		params := [?][^]byte {
			transmute([^]byte)actorParam,
			transmute([^]byte)decidedParam,
			transmute([^]byte)limitParam,
		}
		result := databaseExecParams(conn, DATABASE_LIST_REGISTRATION_REQUESTS_SQL, params[:])
		if result == nil {
			return databaseConnectionError(conn)
		}
		defer pg.clear(result)
		if pg.result_status(result) != .Tuples_OK || pg.n_tuples(result) < 1 {
			return databaseResultError(&result)
		}
		if !databaseGetBool(result, 0, 0) {
			return databaseSuccess(
				common.DatabaseRegistrationRequestsResult{outcome = .NotPermitted},
			)
		}
		listed := common.DatabaseRegistrationRequestsResult {
			outcome  = .Applied,
			requests = make([dynamic]common.RegistrationRequestSummary, 0, pg.n_tuples(result)),
		}
		listed.pendingCount, _ = databaseGetInt(result, 0, 1)
		for row in 0 ..< pg.n_tuples(result) {
			if summary, ok := databaseGetRegistrationRequest(result, row, 2); ok {
				append(&listed.requests, summary)
			}
		}
		return databaseSuccess(listed)
	case .Decide:
		requestParam := databaseIntParam(request.requestId)
		defer delete(requestParam)
		approveParam: cstring = request.approve ? "true" : "false"
		reasonParam := strings.clone_to_cstring(request.reason)
		defer delete(reasonParam)
		params := [?][^]byte {
			transmute([^]byte)actorParam,
			transmute([^]byte)requestParam,
			transmute([^]byte)approveParam,
			transmute([^]byte)reasonParam,
		}
		result := databaseExecParams(conn, DATABASE_DECIDE_REGISTRATION_SQL, params[:])
		if result == nil {
			return databaseConnectionError(conn)
		}
		defer pg.clear(result)
		if pg.result_status(result) != .Tuples_OK || pg.n_tuples(result) != 1 {
			return databaseResultError(&result)
		}
		outcomeText := databaseGetText(result, 0, 0)
		defer delete(outcomeText)
		outcome, outcomeOK := databaseRequestsOutcomeFromText(outcomeText)
		if !outcomeOK {
			return databaseErrorResponse(strings.clone("database returned an unknown outcome"))
		}
		decided := common.DatabaseRegistrationRequestsResult {
			outcome = outcome,
		}
		if outcome == .Applied {
			decided.pendingCount, _ = databaseGetInt(result, 0, 1)
			summary, ok := databaseGetRegistrationRequest(result, 0, 2)
			if !ok {
				return databaseErrorResponse(strings.clone("database returned no request"))
			}
			decided.request = summary
		}
		return databaseSuccess(decided)
	}
	return databaseErrorResponse(strings.clone("unknown registration request"))
}

databaseExecuteRegistrationMode :: proc(
	conn: pg.Conn,
	request: common.DatabaseRegistrationModeRequest,
) -> common.DatabaseQueryResponse {
	actorParam := databaseIntParam(request.actorUserId)
	defer delete(actorParam)
	modeParam := databaseIntParam(int(request.mode))
	defer delete(modeParam)
	params := [?][^]byte{transmute([^]byte)actorParam, transmute([^]byte)modeParam}
	result := databaseExecParams(conn, DATABASE_SET_REGISTRATION_MODE_SQL, params[:])
	if result == nil {
		return databaseConnectionError(conn)
	}
	defer pg.clear(result)
	if pg.result_status(result) != .Tuples_OK || pg.n_tuples(result) != 1 {
		return databaseResultError(&result)
	}
	return databaseSuccess(
		common.DatabaseRegistrationModeResult {
			allowed = databaseGetBool(result, 0, 0),
			changed = databaseGetBool(result, 0, 1),
			mode = databaseGetRegistrationMode(result, 0, 2),
		},
	)
}

// Reads one ID per row from the first column.
@(private = "file")
databaseGetIDColumn :: proc(result: pg.Result) -> [dynamic]int {
	ids := make([dynamic]int, 0, pg.n_tuples(result))
	for row in 0 ..< pg.n_tuples(result) {
		if id, ok := databaseGetInt(result, row, 0); ok {
			append(&ids, id)
		}
	}
	return ids
}

databaseExecuteSharedRooms :: proc(
	conn: pg.Conn,
	request: common.DatabaseSharedRoomsRequest,
) -> common.DatabaseQueryResponse {
	userParam := databaseIntParam(request.userId)
	defer delete(userParam)
	candidatesParam := databaseIntArrayParam(request.candidateUserIds[:])
	defer delete(candidatesParam)
	params := [?][^]byte{transmute([^]byte)userParam, transmute([^]byte)candidatesParam}
	statement: cstring = DATABASE_SHARED_ROOMS_SQL
	if request.keyRecipients {
		statement = DATABASE_KEY_CHANGE_RECIPIENTS_SQL
	}
	result := databaseExecParams(conn, statement, params[:])
	if result == nil {
		return databaseConnectionError(conn)
	}
	defer pg.clear(result)
	if pg.result_status(result) != .Tuples_OK {
		return databaseResultError(&result)
	}
	return databaseSuccess(common.DatabaseSharedRoomsResult{userIds = databaseGetIDColumn(result)})
}

databaseExecuteRestrictedUsers :: proc(conn: pg.Conn) -> common.DatabaseQueryResponse {
	result := databaseExecParams(conn, DATABASE_RESTRICTED_USERS_SQL, nil)
	if result == nil {
		return databaseConnectionError(conn)
	}
	defer pg.clear(result)
	if pg.result_status(result) != .Tuples_OK {
		return databaseResultError(&result)
	}
	return databaseSuccess(
		common.DatabaseRestrictedUsersResult{userIds = databaseGetIDColumn(result)},
	)
}
