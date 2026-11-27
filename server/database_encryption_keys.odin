package server

import "../common"
import "core:fmt"
import "core:strings"
import "shared:pg"

// Account encryption keys (protocol 16, migration 5, e2ee-design.md 3.1-3.2). The router
// verifies a published bundle against the session's identity key before it reaches the
// database, so these statements only store and read bytes. The identity key a bundle belongs
// to is always users.public_key; it is never stored with the bundle.

// Stores a bundle: inserts it, replaces a different one, and leaves an identical one alone
// (no row then). $1 user ID, $2 encryption key (hex), $3 createdAt, $4 signature (hex). The row
// it returns says whether it replaced a bundle and carries the stored bundle with the account's
// identity key.
DATABASE_PUBLISH_ENCRYPTION_KEY_SQL ::
	"WITH upserted AS (INSERT INTO user_encryption_keys AS k " +
	"(user_id, encryption_public_key, created_at_unix, signature) " +
	"VALUES ($1::bigint, decode($2::text, 'hex'), $3::bigint, decode($4::text, 'hex')) " +
	"ON CONFLICT (user_id) DO UPDATE SET encryption_public_key = EXCLUDED.encryption_public_key, " +
	"created_at_unix = EXCLUDED.created_at_unix, signature = EXCLUDED.signature, " +
	"updated_at = now() " +
	"WHERE (k.encryption_public_key, k.created_at_unix, k.signature) IS DISTINCT FROM " +
	"(EXCLUDED.encryption_public_key, EXCLUDED.created_at_unix, EXCLUDED.signature) " +
	"RETURNING k.user_id, NOT (k.xmax = 0) AS replaced, k.encryption_public_key, " +
	"k.created_at_unix, k.signature) " +
	"SELECT up.replaced::text, COALESCE(encode(u.public_key, 'hex'), ''), " +
	"encode(up.encryption_public_key, 'hex'), up.created_at_unix::text, " +
	"encode(up.signature, 'hex') FROM upserted up JOIN users u ON u.id = up.user_id"

// The user IDs a stored room log entry names, read from its bytes (alias ka_e;
// common/e2ee.odin, "RoomLogEntry, format 1", integers little-endian; PostgreSQL's get_byte
// counts from 0): targetUserId, the i64 at byte 50, and actorUserId, the i64 at byte 90. Both
// are 0 where the entry names nobody (a SetAccess's target, a server Remove's actor), which
// never matches an account. An entry too short to hold the ID (only a damaged one: the append
// stores whole entries) reads NULL instead of failing the fetch.
DATABASE_ROOM_LOG_ENTRY_TARGET_USER_ID_SQL ::
	"(CASE WHEN octet_length(ka_e.entry) >= 58 THEN " +
	"get_byte(ka_e.entry, 50)::bigint | (get_byte(ka_e.entry, 51)::bigint << 8) | " +
	"(get_byte(ka_e.entry, 52)::bigint << 16) | (get_byte(ka_e.entry, 53)::bigint << 24) | " +
	"(get_byte(ka_e.entry, 54)::bigint << 32) | (get_byte(ka_e.entry, 55)::bigint << 40) | " +
	"(get_byte(ka_e.entry, 56)::bigint << 48) | (get_byte(ka_e.entry, 57)::bigint << 56)" +
	" END)"
DATABASE_ROOM_LOG_ENTRY_ACTOR_USER_ID_SQL ::
	"(CASE WHEN octet_length(ka_e.entry) >= 98 THEN " +
	"get_byte(ka_e.entry, 90)::bigint | (get_byte(ka_e.entry, 91)::bigint << 8) | " +
	"(get_byte(ka_e.entry, 92)::bigint << 16) | (get_byte(ka_e.entry, 93)::bigint << 24) | " +
	"(get_byte(ka_e.entry, 94)::bigint << 32) | (get_byte(ka_e.entry, 95)::bigint << 40) | " +
	"(get_byte(ka_e.entry, 96)::bigint << 48) | (get_byte(ka_e.entry, 97)::bigint << 56)" +
	" END)"

// The rooms whose member log the server sends the viewer (kv.viewer, inside
// DATABASE_USER_KEY_VISIBLE_*): those it is a member of and those whose log names it as a
// manager (DATABASE_FETCH_ROOM_LOG_SQL lets both fetch). Only encrypted rooms have log rows, so
// the joins below find nothing in the others.
DATABASE_FETCH_USER_KEYS_LOG_ROOMS_SQL ::
	"(SELECT room_id FROM room_members WHERE user_id = kv.viewer " +
	"UNION SELECT room_id FROM room_log_managers WHERE user_id = kv.viewer)"

// Whether a viewer may have the bundle of a subject account (D17, #103), apart from holders of
// ApproveRegistrations, who have every bundle as they see every account in the user list (each
// statement adds that rule itself): itself; a peer it knows (DATABASE_DIRECT_PEER_KNOWN_*: a
// shared room, an admin on either side, neither restricted, or an existing conversation); the
// author of a room message it can read (a member of the room, past the From join cut
// DATABASE_HISTORY_SINCE_*), whose signature it must verify; in an encrypted room whose log it
// reads (the LOG_ROOMS statement above), the actor or target of any log entry and a current log
// manager (the Create's managers still in force; removed ones are RemoveManager targets), since
// a client replays the whole log against pinned identity keys; and the sender or forwarder of a
// room key envelope with a wrap for it in a room it is a member of (what
// DATABASE_FETCH_ROOM_KEYS_SQL returns), whose signature it verifies. Everything after the first
// rule names accounts the server has already shown the viewer, so their keys reveal nothing;
// withholding them would leave readable history unverified, or an encrypted room's log
// unverifiable, on a new device. A scalar boolean, built as
//
//   DATABASE_USER_KEY_VISIBLE_OPEN_SQL + viewer + DATABASE_USER_KEY_VISIBLE_MIDDLE_SQL +
//   subject + DATABASE_USER_KEY_VISIBLE_CLOSE_SQL
//
// where viewer and subject are account ID expressions, which may name outer aliases; its own
// aliases start with kv and ka_. The key fetch (DATABASE_FETCH_USER_KEYS_SQL) and the
// recipients of a key change (DATABASE_KEY_CHANGE_RECIPIENTS_SQL, #190) share it, so whoever
// may fetch a key hears when it changes. Each EXISTS runs over the viewer's rooms, through
// room_members_by_user_id, room_log_managers_by_user_id, the room_log_entries key and
// room_key_envelopes_by_chain or room_key_envelopes_by_room_id_and_epoch.
DATABASE_USER_KEY_VISIBLE_OPEN_SQL ::
	"(SELECT (kv.subject = kv.viewer OR " +
	DATABASE_DIRECT_PEER_KNOWN_OPEN_SQL + "kv.viewer" + DATABASE_DIRECT_PEER_KNOWN_MIDDLE_SQL +
	"kv.subject" + DATABASE_DIRECT_PEER_KNOWN_CLOSE_SQL +
	" OR EXISTS (SELECT 1 FROM room_members ka_m JOIN chat_messages ka_c " +
	"ON ka_c.room_id = ka_m.room_id WHERE ka_m.user_id = kv.viewer " +
	"AND ka_c.sender_user_id = kv.subject AND ka_c.client_message_id IS NOT NULL " +
	"AND ka_c.created_at > COALESCE(" + DATABASE_HISTORY_SINCE_OPEN_SQL + "ka_m.room_id" +
	DATABASE_HISTORY_SINCE_MIDDLE_SQL + "kv.viewer" + DATABASE_HISTORY_SINCE_CLOSE_SQL +
	", '-infinity'::timestamptz)) " +
	"OR EXISTS (SELECT 1 FROM " + DATABASE_FETCH_USER_KEYS_LOG_ROOMS_SQL + " ka_l " +
	"JOIN room_log_entries ka_e ON ka_e.room_id = ka_l.room_id WHERE kv.subject IN (" +
	DATABASE_ROOM_LOG_ENTRY_TARGET_USER_ID_SQL + ", " +
	DATABASE_ROOM_LOG_ENTRY_ACTOR_USER_ID_SQL + ")) " +
	"OR EXISTS (SELECT 1 FROM " + DATABASE_FETCH_USER_KEYS_LOG_ROOMS_SQL + " ka_l " +
	"JOIN room_log_managers ka_g ON ka_g.room_id = ka_l.room_id AND ka_g.user_id = kv.subject) " +
	"OR EXISTS (SELECT 1 FROM room_members ka_km JOIN room_key_envelopes ka_k " +
	"ON ka_k.room_id = ka_km.room_id WHERE ka_km.user_id = kv.viewer " +
	"AND (ka_k.sender_user_id = kv.subject OR ka_k.forwarder_user_id = kv.subject) " +
	"AND kv.viewer = ANY (ka_k.recipient_user_ids))) FROM (SELECT "
DATABASE_USER_KEY_VISIBLE_MIDDLE_SQL :: "::bigint AS viewer, "
DATABASE_USER_KEY_VISIBLE_CLOSE_SQL :: "::bigint AS subject) kv)"

// Whether the requester ($1) may have the bundle of account u.id: every account for holders of
// ApproveRegistrations (admins hold every permission), else DATABASE_USER_KEY_VISIBLE_*.
DATABASE_FETCH_USER_KEYS_VISIBLE_SQL ::
	"(v.sees_all OR " + DATABASE_USER_KEY_VISIBLE_OPEN_SQL + "$1" +
	DATABASE_USER_KEY_VISIBLE_MIDDLE_SQL + "u.id" + DATABASE_USER_KEY_VISIBLE_CLOSE_SQL + ")"

// The bundles of the accounts in $2 (a bigint array literal) that the requester $1 may see
// (DATABASE_FETCH_USER_KEYS_VISIBLE_SQL), one row per requested ID in the order asked. An
// account without an identity key or a bundle, an ID with no account, and (protocol 25, D17,
// #103) an account the requester may not see all come back with NULL key columns, so the
// answer lists them alike in missingUserIds.
DATABASE_FETCH_USER_KEYS_SQL ::
	"WITH viewer AS (SELECT " + DATABASE_ACTOR_APPROVES_REGISTRATIONS_SQL + " AS sees_all) " +
	"SELECT r.id::text, encode(u.public_key, 'hex'), encode(k.encryption_public_key, 'hex'), " +
	"k.created_at_unix::text, encode(k.signature, 'hex') " +
	"FROM unnest($2::bigint[]) WITH ORDINALITY AS r(id, position) CROSS JOIN viewer v " +
	"LEFT JOIN users u ON u.id = r.id AND " + DATABASE_FETCH_USER_KEYS_VISIBLE_SQL + " " +
	"LEFT JOIN user_encryption_keys k ON k.user_id = u.id AND u.public_key IS NOT NULL " +
	"ORDER BY r.position"

// #190: $1 an account whose bundle changed, $2 candidates (bigint array): those that may fetch
// the new bundle, by the fetch's own rule (DATABASE_FETCH_USER_KEYS_VISIBLE_SQL with the
// candidate as requester), so ServerUserKeyChanged reaches exactly the accounts a fetch would
// answer.
DATABASE_KEY_CHANGE_RECIPIENTS_SQL ::
	"SELECT c.id::text FROM unnest($2::bigint[]) c(id) WHERE ((" +
	DATABASE_SERVER_PERMISSIONS_OPEN_SQL + "c.id" + DATABASE_SERVER_PERMISSIONS_CLOSE_SQL +
	" & " + DATABASE_PERMISSION_APPROVE_REGISTRATIONS_SQL + ") <> 0) OR " +
	DATABASE_USER_KEY_VISIBLE_OPEN_SQL + "c.id" + DATABASE_USER_KEY_VISIBLE_MIDDLE_SQL +
	"$1::bigint" + DATABASE_USER_KEY_VISIBLE_CLOSE_SQL +
	" ORDER BY c.id"

// Decodes a hex column into dst. False for NULL, bad hex, or the wrong length.
databaseGetHexBytes :: proc(result: pg.Result, row: i32, column: i32, dst: []u8) -> bool {
	if pg.get_is_null(result, row, column) {
		return false
	}
	text := databaseGetText(result, row, column)
	defer delete(text)
	return common.decodeHexIntoBuffer(text, dst)
}

// A users.public_key column read as hex; all zeros when it is NULL, empty or malformed, which
// is what UserSummary carries for an account without an identity key.
databaseGetIdentityPublicKey :: proc(
	result: pg.Result,
	row: i32,
	column: i32,
) -> common.IdentityPublicKeyBytes {
	key: common.IdentityPublicKeyBytes
	if !databaseGetHexBytes(result, row, column, key[:]) {
		return {}
	}
	return key
}

// Reads a bundle from columns identity, encryption key, createdAt, signature starting at first.
// False when any of them is missing or malformed.
@(private = "file")
databaseGetUserKeyBundle :: proc(
	result: pg.Result,
	row: i32,
	first: i32,
	userID: int,
) -> (
	common.UserKeyBundle,
	bool,
) {
	bundle := common.UserKeyBundle {
		userId = userID,
	}
	createdAt, createdAtOK := databaseGetInt(result, row, first + 2)
	if !databaseGetHexBytes(result, row, first, bundle.identityPublicKey[:]) ||
	   !databaseGetHexBytes(result, row, first + 1, bundle.encryptionPublicKey[:]) ||
	   !createdAtOK ||
	   createdAt < 0 ||
	   !databaseGetHexBytes(result, row, first + 3, bundle.signature[:]) {
		return {}, false
	}
	bundle.createdAt = u64(createdAt)
	return bundle, true
}

databaseExecutePublishEncryptionKey :: proc(
	conn: pg.Conn,
	request: common.DatabasePublishEncryptionKeyRequest,
) -> common.DatabaseQueryResponse {
	encryptionKey := request.encryptionPublicKey
	signature := request.signature
	userParam := databaseIntParam(request.userId)
	defer delete(userParam)
	keyHex := common.encodeBytesToHex(encryptionKey[:])
	defer delete(keyHex)
	keyParam := strings.clone_to_cstring(keyHex)
	defer delete(keyParam)
	createdAtParam := fmt.caprintf("%d", request.createdAt)
	defer delete(createdAtParam)
	signatureHex := common.encodeBytesToHex(signature[:])
	defer delete(signatureHex)
	signatureParam := strings.clone_to_cstring(signatureHex)
	defer delete(signatureParam)
	params := [?][^]byte {
		transmute([^]byte)userParam,
		transmute([^]byte)keyParam,
		transmute([^]byte)createdAtParam,
		transmute([^]byte)signatureParam,
	}
	result := databaseExecParams(conn, DATABASE_PUBLISH_ENCRYPTION_KEY_SQL, params[:])
	if result == nil {
		return databaseConnectionError(conn)
	}
	defer pg.clear(result)
	if pg.result_status(result) != .Tuples_OK {
		return databaseResultError(&result)
	}
	if pg.n_tuples(result) == 0 {
		return databaseSuccess(common.DatabasePublishEncryptionKeyResult{})
	}
	bundle, bundleOK := databaseGetUserKeyBundle(result, 0, 1, request.userId)
	if !bundleOK {
		return databaseErrorResponse(strings.clone("database returned an invalid key bundle"))
	}
	return databaseSuccess(
		common.DatabasePublishEncryptionKeyResult {
			stored = true,
			replaced = databaseGetBool(result, 0, 0),
			bundle = bundle,
		},
	)
}

// The bigint array literal for userIDs, "{1,2,3}". The caller frees it.
databaseIntArrayParam :: proc(userIDs: []int) -> cstring {
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	strings.write_byte(&builder, '{')
	for userID, index in userIDs {
		if index > 0 {
			strings.write_byte(&builder, ',')
		}
		strings.write_int(&builder, userID)
	}
	strings.write_byte(&builder, '}')
	text, _ := strings.clone_to_cstring(strings.to_string(builder))
	return text
}

databaseExecuteFetchUserKeys :: proc(
	conn: pg.Conn,
	request: common.DatabaseFetchUserKeysRequest,
) -> common.DatabaseQueryResponse {
	requesterParam := databaseIntParam(request.requesterUserId)
	defer delete(requesterParam)
	idsParam := databaseIntArrayParam(request.userIds[:])
	defer delete(idsParam)
	params := [?][^]byte{transmute([^]byte)requesterParam, transmute([^]byte)idsParam}
	result := databaseExecParams(conn, DATABASE_FETCH_USER_KEYS_SQL, params[:])
	if result == nil {
		return databaseConnectionError(conn)
	}
	defer pg.clear(result)
	if pg.result_status(result) != .Tuples_OK {
		return databaseResultError(&result)
	}

	rows := pg.n_tuples(result)
	fetched := common.DatabaseFetchUserKeysResult {
		keys           = make([dynamic]common.UserKeyBundle, 0, rows),
		missingUserIds = make([dynamic]int, 0, rows),
	}
	for row in 0 ..< rows {
		userID, userIDOK := databaseGetInt(result, row, 0)
		if !userIDOK {
			continue
		}
		if bundle, ok := databaseGetUserKeyBundle(result, row, 1, userID); ok {
			append(&fetched.keys, bundle)
		} else {
			append(&fetched.missingUserIds, userID)
		}
	}
	return databaseSuccess(fetched)
}
