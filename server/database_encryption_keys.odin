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

// Whether the requester ($1) may have the bundle of account u.id (D17, #103): itself; every
// account for holders of ApproveRegistrations (admins hold every permission), as in the user
// list; a peer it knows (DATABASE_DIRECT_PEER_KNOWN_*: a shared room, an admin on either side,
// neither restricted, or an existing conversation); or the author of a room message it can
// read (a member of the room, past the From join cut DATABASE_HISTORY_SINCE_*), whose
// signature it must verify. The last two name accounts the server has already shown the
// requester, so they reveal nothing; withholding them would leave readable history unverified
// on a new device.
DATABASE_FETCH_USER_KEYS_VISIBLE_SQL ::
	"(u.id = $1::bigint OR v.sees_all OR " + DATABASE_DIRECT_PEER_KNOWN_OPEN_SQL + "$1" +
	DATABASE_DIRECT_PEER_KNOWN_MIDDLE_SQL + "u.id" + DATABASE_DIRECT_PEER_KNOWN_CLOSE_SQL +
	" OR EXISTS (SELECT 1 FROM room_members ka_m JOIN chat_messages ka_c " +
	"ON ka_c.room_id = ka_m.room_id WHERE ka_m.user_id = $1::bigint " +
	"AND ka_c.sender_user_id = u.id AND ka_c.client_message_id IS NOT NULL " +
	"AND ka_c.created_at > COALESCE(" + DATABASE_HISTORY_SINCE_OPEN_SQL + "ka_m.room_id" +
	DATABASE_HISTORY_SINCE_MIDDLE_SQL + "$1::bigint" + DATABASE_HISTORY_SINCE_CLOSE_SQL +
	", '-infinity'::timestamptz)))"

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
