package server

import "../common"
import "core:strings"
import "shared:pg"

// Editing and deleting messages (protocol 30, #76, migration 17,
// docs/plan/2026-11-19-message-edit-delete.md). Every check is in the statement that makes the
// change, so nothing can change between a check and the edit or delete:
//
// - the author is the message's sender (an admin's room delete: DATABASE_ACTOR_IS_ADMIN_SQL);
// - the message is in this conversation, not deleted, and one the author can still read (room
//   membership and the From join cut DATABASE_HISTORY_SINCE_*; a DM's two sides);
// - the client's originalClientMessageId, which its signature covers, is the message's;
// - an edit needs what a new message there needs (D10): a chat room type, SendMessages and,
//   sealed, the room's current log version; in a DM the restricted-account rule and, sealed,
//   the recipient's current identity key (the worker verifies the envelope against it first);
// - plaintext stays plaintext and sealed stays sealed (D11); an empty plaintext edit only for a
//   message with attachments (D9); at most common.MESSAGE_EDITS_MAX edits (D12);
// - a clientMessageId or chain index used before by the sender for a message or an edit is
//   refused (the post statements check the edit tables the same way).
//
// Each statement returns one row whose first column is the outcome word
// (databaseMessageChangeOutcome), plus what the router fans out: the sender, the readers
// (every account that may read the message: room members past the From join cut, or a DM's two
// sides), the stored edit, the tombstone's time and the blobs a delete made Removed (D8).

// A message's edit and tombstone columns, for the history and conversation statements, from a
// message row aliased me and its latest edit aliased le (the joins below): edit_count, deleted,
// deleted_at, delete_signature, and the edit's id, client_message_id, created_at, content,
// signature and sealed bytes (a DM edit's envelope). Read by databaseGetMessageEditColumns.
DATABASE_MESSAGE_EDIT_COLUMNS_SQL ::
	"COALESCE(me.edit_count, 0)::text, (me.deleted_at IS NOT NULL)::text, " +
	"COALESCE(me.deleted_at::text, ''), COALESCE(encode(me.delete_signature, 'hex'), ''), " +
	"COALESCE(le.id, 0)::text, COALESCE(encode(le.client_message_id, 'hex'), ''), " +
	"COALESCE(le.created_at::text, ''), COALESCE(le.content, ''), " +
	"COALESCE(encode(le.signature, 'hex'), ''), COALESCE(encode(le.sealed, 'hex'), '')"

// The same columns for a schema older than migration 17 (tests only).
DATABASE_MESSAGE_NO_EDIT_COLUMNS_SQL ::
	"'0', 'false', '', '', '0', '', '', '', '', ''"

DATABASE_MESSAGE_EDIT_COLUMN_COUNT :: 10

// The joins DATABASE_MESSAGE_EDIT_COLUMNS_SQL reads, for a room message: OPEN + "<message id
// expression>" + MIDDLE + "<the same>" + CLOSE. The message row is joined again by its primary
// key, so a statement's own column list stays as it was.
DATABASE_ROOM_MESSAGE_EDITS_JOIN_OPEN_SQL :: "LEFT JOIN chat_messages me ON me.id = "
DATABASE_ROOM_MESSAGE_EDITS_JOIN_MIDDLE_SQL ::
	" LEFT JOIN LATERAL (SELECT e.id, e.client_message_id, e.created_at, e.content, " +
	"e.signature, e.sealed FROM chat_message_edits e WHERE e.message_id = "
DATABASE_DIRECT_MESSAGE_EDITS_JOIN_OPEN_SQL :: "LEFT JOIN direct_messages me ON me.id = "
DATABASE_DIRECT_MESSAGE_EDITS_JOIN_MIDDLE_SQL ::
	" LEFT JOIN LATERAL (SELECT e.id, e.client_message_id, e.created_at, e.content, " +
	"e.signature, e.envelope AS sealed FROM direct_message_edits e WHERE e.message_id = "
DATABASE_MESSAGE_EDITS_JOIN_CLOSE_SQL :: " ORDER BY e.id DESC LIMIT 1) le ON true "

// D13: deleted messages never count as unread. Kept as their own pieces so the read marker
// migration tests can run the unread rules on schemas older than migration 17.
DATABASE_UNREAD_ROOM_NOT_DELETED_SQL :: "AND cm.deleted_at IS NULL "
DATABASE_UNREAD_DIRECT_NOT_DELETED_SQL :: "AND d.deleted_at IS NULL "

// The created_at test of a message aliased <alias> against <account>'s From join cut in room
// <room>: OPEN + alias + ".created_at > COALESCE(" + HISTORY_SINCE... + ", '-infinity')".
@(private = "file")
DATABASE_MESSAGE_READABLE_CLOSE_SQL :: ", '-infinity'::timestamptz)"

// Edit of room message $3 in room $2 by $1: $4 the original's client message ID (hex), $5 the
// edit's, $6 the content, $7 a plaintext edit's signature (hex, '' when sealed), $8 a sealed
// edit's bytes (hex, '' when plaintext), $9 its epoch, $10 its chain ID (hex), $11 its index.
// Columns: outcome, sender, edit count after, edit id, edit created_at, readers.
DATABASE_EDIT_ROOM_MESSAGE_SQL ::
	"WITH member AS (SELECT 1 FROM room_members WHERE room_id = $2::bigint " +
	"AND user_id = $1::bigint), " +
	"perms AS (SELECT " + DATABASE_ROOM_PERMISSIONS_OPEN_SQL + "$1" +
	DATABASE_ROOM_PERMISSIONS_ROOM_SQL + "$2" + DATABASE_ROOM_PERMISSIONS_CLOSE_SQL +
	" AS mask), " +
	"room AS (SELECT room_type, encrypted, log_version FROM rooms WHERE id = $2::bigint), " +
	"target AS (SELECT cm.id, cm.sender_user_id, cm.created_at, " +
	"(cm.deleted_at IS NOT NULL) AS deleted, (cm.sealed IS NOT NULL) AS sealed, " +
	"cm.edit_count, cm.attachment_count, cm.client_message_id FROM chat_messages cm " +
	"WHERE cm.id = $3::bigint AND cm.room_id = $2::bigint AND cm.created_at > COALESCE(" +
	DATABASE_HISTORY_SINCE_OPEN_SQL + "$2::bigint" + DATABASE_HISTORY_SINCE_MIDDLE_SQL +
	"$1::bigint" + DATABASE_HISTORY_SINCE_CLOSE_SQL + DATABASE_MESSAGE_READABLE_CLOSE_SQL + "), " +
	"decision AS (SELECT CASE " +
	"WHEN NOT EXISTS (SELECT 1 FROM member) THEN 'not_member' " +
	"WHEN NOT EXISTS (SELECT 1 FROM target) THEN 'not_found' " +
	"WHEN (SELECT sender_user_id FROM target) <> $1::bigint THEN 'not_author' " +
	"WHEN (SELECT deleted FROM target) THEN 'deleted' " +
	"WHEN (SELECT client_message_id FROM target) IS DISTINCT FROM decode($4::text, 'hex') " +
	"THEN 'not_found' " +
	"WHEN NOT COALESCE((SELECT room_type IN (1, 3) FROM room), false) THEN 'chat_disabled' " +
	"WHEN NOT (SELECT (mask & " + DATABASE_ROOM_PERMISSION_SEND_MESSAGES_SQL +
	") <> 0 FROM perms) THEN 'send_denied' " +
	"WHEN (SELECT sealed FROM target) <> ($8::text <> '') " +
	"OR (SELECT encrypted FROM room) <> ($8::text <> '') THEN 'kind' " +
	"WHEN $8::text <> '' AND (SELECT log_version FROM room) <> $9::bigint THEN 'stale_epoch' " +
	"WHEN $8::text = '' AND $6::text = '' AND (SELECT attachment_count FROM target) = 0 " +
	"THEN 'invalid' " +
	"WHEN (SELECT edit_count FROM target) >= 100 THEN 'edit_limit' " +
	"WHEN EXISTS (SELECT 1 FROM chat_messages u WHERE u.sender_user_id = $1::bigint " +
	"AND u.client_message_id = decode($5::text, 'hex')) " +
	"OR EXISTS (SELECT 1 FROM chat_message_edits u WHERE u.sender_user_id = $1::bigint " +
	"AND u.client_message_id = decode($5::text, 'hex')) " +
	"OR ($10::text <> '' AND (EXISTS (SELECT 1 FROM chat_messages u " +
	"WHERE u.sender_user_id = $1::bigint AND u.chain_id = decode($10::text, 'hex') " +
	"AND u.chain_index = $11::integer) OR EXISTS (SELECT 1 FROM chat_message_edits u " +
	"WHERE u.sender_user_id = $1::bigint AND u.chain_id = decode($10::text, 'hex') " +
	"AND u.chain_index = $11::integer))) THEN 'duplicate' " +
	"ELSE 'applied' END AS outcome), " +
	"bumped AS (UPDATE chat_messages SET edit_count = edit_count + 1, " +
	"edited_at = CURRENT_TIMESTAMP WHERE id = $3::bigint " +
	"AND (SELECT outcome FROM decision) = 'applied' RETURNING edit_count), " +
	"stored AS (INSERT INTO chat_message_edits (message_id, sender_user_id, " +
	"client_message_id, content, sealed, signature, chain_id, chain_index) " +
	"SELECT $3::bigint, $1::bigint, decode($5::text, 'hex'), $6::text, " +
	"decode(NULLIF($8::text, ''), 'hex'), decode(NULLIF($7::text, ''), 'hex'), " +
	"decode(NULLIF($10::text, ''), 'hex'), " +
	"CASE WHEN $10::text = '' THEN NULL ELSE $11::integer END FROM bumped " +
	"RETURNING id, created_at), " +
	"readers AS (SELECT rm.user_id FROM target t JOIN room_members rm " +
	"ON rm.room_id = $2::bigint WHERE t.created_at > COALESCE(" +
	DATABASE_HISTORY_SINCE_OPEN_SQL + "rm.room_id" + DATABASE_HISTORY_SINCE_MIDDLE_SQL +
	"rm.user_id" + DATABASE_HISTORY_SINCE_CLOSE_SQL + DATABASE_MESSAGE_READABLE_CLOSE_SQL + ") " +
	"SELECT d.outcome, COALESCE((SELECT sender_user_id FROM target), 0)::text, " +
	"COALESCE((SELECT edit_count FROM bumped), 0)::text, COALESCE(s.id, 0)::text, " +
	"COALESCE(s.created_at::text, ''), CASE WHEN d.outcome = 'applied' THEN " +
	"COALESCE((SELECT string_agg(user_id::text, ',' ORDER BY user_id) FROM readers), '') " +
	"ELSE '' END FROM decision d LEFT JOIN stored s ON true"

// Delete of room message $3 in room $2 by $1: the author with $5 its signature (hex) over $4,
// the message's client message ID (hex), or an admin with $5 '' (moderation, D5; the admin
// need not be a member). The tombstone keeps the ID, sender, time, client message ID and chain
// position (D7); the content, sealed bytes, signature and every edit go, and the message's files
// become Removed tombstones in the same statement (D8); an admin's delete also writes them to the
// removal log (protocol 29) with the admin as the remover. Columns: outcome, sender, deleted_at,
// readers, the removed blobs (hex, comma separated).
DATABASE_DELETE_ROOM_MESSAGE_SQL ::
	"WITH member AS (SELECT 1 FROM room_members WHERE room_id = $2::bigint " +
	"AND user_id = $1::bigint), " +
	"admin AS (SELECT " + DATABASE_ACTOR_IS_ADMIN_SQL + " AS ok), " +
	"target AS (SELECT cm.id, cm.sender_user_id, cm.created_at, " +
	"(cm.deleted_at IS NOT NULL) AS deleted, cm.client_message_id, " +
	"(cm.created_at > COALESCE(" + DATABASE_HISTORY_SINCE_OPEN_SQL + "$2::bigint" +
	DATABASE_HISTORY_SINCE_MIDDLE_SQL + "$1::bigint" + DATABASE_HISTORY_SINCE_CLOSE_SQL +
	DATABASE_MESSAGE_READABLE_CLOSE_SQL + ") AS readable " +
	"FROM chat_messages cm WHERE cm.id = $3::bigint AND cm.room_id = $2::bigint), " +
	"decision AS (SELECT CASE WHEN $5::text = '' THEN CASE " +
	"WHEN NOT (SELECT ok FROM admin) THEN 'not_admin' " +
	"WHEN NOT EXISTS (SELECT 1 FROM target) THEN 'not_found' " +
	"WHEN (SELECT deleted FROM target) THEN 'deleted' ELSE 'applied' END " +
	"WHEN NOT EXISTS (SELECT 1 FROM member) THEN 'not_member' " +
	"WHEN NOT EXISTS (SELECT 1 FROM target WHERE readable) THEN 'not_found' " +
	"WHEN (SELECT sender_user_id FROM target) <> $1::bigint THEN 'not_author' " +
	"WHEN (SELECT deleted FROM target) THEN 'deleted' " +
	"WHEN (SELECT client_message_id FROM target) IS DISTINCT FROM decode($4::text, 'hex') " +
	"THEN 'not_found' ELSE 'applied' END AS outcome), " +
	"tombstone AS (UPDATE chat_messages SET content = '', sealed = NULL, signature = NULL, " +
	"attachment_count = 0, edit_count = 0, edited_at = NULL, " +
	"deleted_at = CURRENT_TIMESTAMP, deleted_by_user_id = $1::bigint, " +
	"delete_signature = decode(NULLIF($5::text, ''), 'hex') WHERE id = $3::bigint " +
	"AND (SELECT outcome FROM decision) = 'applied' RETURNING id, deleted_at), " +
	"dropped AS (DELETE FROM chat_message_edits WHERE message_id IN " +
	"(SELECT id FROM tombstone) RETURNING id), " +
	"files AS (UPDATE attachments a SET state = 3, removed_by_user_id = $1::bigint, " +
	"removed_at = CURRENT_TIMESTAMP FROM tombstone t WHERE a.chat_message_id = t.id " +
	"AND a.state <> 3 RETURNING a.blob_id, a.owner_user_id, a.room_id, a.encrypted, a.name, " +
	"a.chat_message_id), " +
	"logged AS (INSERT INTO attachment_removals (blob_id, owner_user_id, removed_by_user_id, " +
	"removed_at, reason, room_id, direct, encrypted, chat_message_id, name) " +
	"SELECT f.blob_id, f.owner_user_id, $1::bigint, CURRENT_TIMESTAMP, '" +
	DATABASE_MESSAGE_DELETED_REMOVAL_REASON + "', f.room_id, false, f.encrypted, " +
	"f.chat_message_id, CASE WHEN f.encrypted THEN NULL ELSE f.name END FROM files f " +
	"WHERE $5::text = '' RETURNING id), " +
	"readers AS (SELECT rm.user_id FROM target t JOIN room_members rm " +
	"ON rm.room_id = $2::bigint WHERE t.created_at > COALESCE(" +
	DATABASE_HISTORY_SINCE_OPEN_SQL + "rm.room_id" + DATABASE_HISTORY_SINCE_MIDDLE_SQL +
	"rm.user_id" + DATABASE_HISTORY_SINCE_CLOSE_SQL + DATABASE_MESSAGE_READABLE_CLOSE_SQL + ") " +
	"SELECT d.outcome, COALESCE((SELECT sender_user_id FROM target), 0)::text, " +
	"COALESCE(t.deleted_at::text, ''), CASE WHEN d.outcome = 'applied' THEN " +
	"COALESCE((SELECT string_agg(user_id::text, ',' ORDER BY user_id) FROM readers), '') " +
	"ELSE '' END, COALESCE((SELECT string_agg(encode(blob_id, 'hex'), ',') FROM files), ''), " +
	"(SELECT count(*) FROM logged)::text, (SELECT count(*) FROM dropped)::text " +
	"FROM decision d LEFT JOIN tombstone t ON true"

// The removal log's reason for the files of a message an admin deleted.
DATABASE_MESSAGE_DELETED_REMOVAL_REASON :: "Message deleted"

// The direct message $3 between $1 and $2, as the CTE target.
@(private = "file")
DATABASE_DIRECT_TARGET_SQL ::
	"target AS (SELECT dm.id, dm.sender_user_id, dm.recipient_user_id, " +
	"(dm.deleted_at IS NOT NULL) AS deleted, (dm.envelope IS NOT NULL) AS sealed, " +
	"dm.edit_count, dm.attachment_count, dm.client_message_id FROM direct_messages dm " +
	"WHERE dm.id = $3::bigint AND ((dm.sender_user_id = $1::bigint " +
	"AND dm.recipient_user_id = $2::bigint) OR (dm.sender_user_id = $2::bigint " +
	"AND dm.recipient_user_id = $1::bigint)))"

// Edit of direct message $3 between $1 (its sender) and $2: $4 the original's client message
// ID, $5 the edit's, $6 the content, $7 a plaintext edit's signature, $8 a sealed edit's
// envelope (hex, '' when plaintext), $9 the recipient's identity key the worker checked the
// envelope against (hex, '' when plaintext). Columns: outcome, sender, recipient, edit count
// after, edit id, edit created_at.
DATABASE_EDIT_DIRECT_MESSAGE_SQL ::
	"WITH " + DATABASE_DIRECT_TARGET_SQL + ", " +
	"allowed AS (SELECT " + DATABASE_USERS_MAY_MEET_OPEN_SQL + "$1" +
	DATABASE_USERS_MAY_MEET_MIDDLE_SQL + "$2" + DATABASE_USERS_MAY_MEET_CLOSE_SQL + " AS ok), " +
	"recipient_key AS (SELECT 1 FROM users WHERE id = $2::bigint " +
	"AND ($9::text = '' OR public_key = decode($9::text, 'hex'))), " +
	"decision AS (SELECT CASE " +
	"WHEN NOT EXISTS (SELECT 1 FROM target) THEN 'not_found' " +
	"WHEN (SELECT sender_user_id FROM target) <> $1::bigint THEN 'not_author' " +
	"WHEN (SELECT deleted FROM target) THEN 'deleted' " +
	"WHEN (SELECT client_message_id FROM target) IS DISTINCT FROM decode($4::text, 'hex') " +
	"THEN 'not_found' " +
	"WHEN NOT (SELECT ok FROM allowed) THEN 'restricted' " +
	"WHEN (SELECT sealed FROM target) <> ($8::text <> '') THEN 'kind' " +
	"WHEN NOT EXISTS (SELECT 1 FROM recipient_key) THEN 'invalid_envelope' " +
	"WHEN $8::text = '' AND $6::text = '' AND (SELECT attachment_count FROM target) = 0 " +
	"THEN 'invalid' " +
	"WHEN (SELECT edit_count FROM target) >= 100 THEN 'edit_limit' " +
	"WHEN EXISTS (SELECT 1 FROM direct_messages u WHERE u.sender_user_id = $1::bigint " +
	"AND u.client_message_id = decode($5::text, 'hex')) " +
	"OR EXISTS (SELECT 1 FROM direct_message_edits u WHERE u.sender_user_id = $1::bigint " +
	"AND u.client_message_id = decode($5::text, 'hex')) THEN 'duplicate' " +
	"ELSE 'applied' END AS outcome), " +
	"bumped AS (UPDATE direct_messages SET edit_count = edit_count + 1, " +
	"edited_at = CURRENT_TIMESTAMP WHERE id = $3::bigint " +
	"AND (SELECT outcome FROM decision) = 'applied' RETURNING edit_count), " +
	"stored AS (INSERT INTO direct_message_edits (message_id, sender_user_id, " +
	"client_message_id, content, envelope, signature) " +
	"SELECT $3::bigint, $1::bigint, decode($5::text, 'hex'), $6::text, " +
	"decode(NULLIF($8::text, ''), 'hex'), decode(NULLIF($7::text, ''), 'hex') FROM bumped " +
	"RETURNING id, created_at) " +
	"SELECT d.outcome, COALESCE((SELECT sender_user_id FROM target), 0)::text, " +
	"COALESCE((SELECT recipient_user_id FROM target), 0)::text, " +
	"COALESCE((SELECT edit_count FROM bumped), 0)::text, COALESCE(s.id, 0)::text, " +
	"COALESCE(s.created_at::text, '') FROM decision d LEFT JOIN stored s ON true"

// Delete of direct message $3 between $1 (its sender) and $2 with $5 the sender's signature
// (hex) over $4, the message's client message ID. Only the sender deletes a direct message
// (D5). Columns: outcome, sender, recipient, deleted_at, the removed blobs.
DATABASE_DELETE_DIRECT_MESSAGE_SQL ::
	"WITH " + DATABASE_DIRECT_TARGET_SQL + ", " +
	"decision AS (SELECT CASE " +
	"WHEN NOT EXISTS (SELECT 1 FROM target) THEN 'not_found' " +
	"WHEN (SELECT sender_user_id FROM target) <> $1::bigint THEN 'not_author' " +
	"WHEN (SELECT deleted FROM target) THEN 'deleted' " +
	"WHEN (SELECT client_message_id FROM target) IS DISTINCT FROM decode($4::text, 'hex') " +
	"THEN 'not_found' ELSE 'applied' END AS outcome), " +
	"tombstone AS (UPDATE direct_messages SET content = '', envelope = NULL, signature = NULL, " +
	"attachment_count = 0, edit_count = 0, edited_at = NULL, " +
	"deleted_at = CURRENT_TIMESTAMP, deleted_by_user_id = $1::bigint, " +
	"delete_signature = decode($5::text, 'hex') WHERE id = $3::bigint " +
	"AND (SELECT outcome FROM decision) = 'applied' RETURNING id, deleted_at), " +
	"dropped AS (DELETE FROM direct_message_edits WHERE message_id IN " +
	"(SELECT id FROM tombstone) RETURNING id), " +
	"files AS (UPDATE attachments a SET state = 3, removed_by_user_id = $1::bigint, " +
	"removed_at = CURRENT_TIMESTAMP FROM tombstone t WHERE a.direct_message_id = t.id " +
	"AND a.state <> 3 RETURNING a.blob_id) " +
	"SELECT d.outcome, COALESCE((SELECT sender_user_id FROM target), 0)::text, " +
	"COALESCE((SELECT recipient_user_id FROM target), 0)::text, " +
	"COALESCE(t.deleted_at::text, ''), " +
	"COALESCE((SELECT string_agg(encode(blob_id, 'hex'), ',') FROM files), ''), " +
	"(SELECT count(*) FROM dropped)::text FROM decision d LEFT JOIN tombstone t ON true"

// Every edit of room message $3 in room $2, for $1 when it may read the message, oldest first.
// Every row: whether $1 is a member, whether the message is readable, then the edit's id,
// client message ID, created_at, content, signature and sealed bytes (NULL without edits).
DATABASE_FETCH_ROOM_MESSAGE_EDITS_SQL ::
	"WITH member AS (SELECT EXISTS (SELECT 1 FROM room_members WHERE room_id = $2::bigint " +
	"AND user_id = $1::bigint) AS ok), " +
	"target AS (SELECT cm.id FROM chat_messages cm CROSS JOIN member m WHERE m.ok " +
	"AND cm.id = $3::bigint AND cm.room_id = $2::bigint AND cm.created_at > COALESCE(" +
	DATABASE_HISTORY_SINCE_OPEN_SQL + "$2::bigint" + DATABASE_HISTORY_SINCE_MIDDLE_SQL +
	"$1::bigint" + DATABASE_HISTORY_SINCE_CLOSE_SQL + DATABASE_MESSAGE_READABLE_CLOSE_SQL + ") " +
	"SELECT (SELECT ok FROM member)::text, EXISTS (SELECT 1 FROM target)::text, e.id::text, " +
	"encode(e.client_message_id, 'hex'), e.created_at::text, e.content, " +
	"COALESCE(encode(e.signature, 'hex'), ''), COALESCE(encode(e.sealed, 'hex'), '') " +
	"FROM (SELECT 1) AS one LEFT JOIN LATERAL (SELECT * FROM chat_message_edits x " +
	"WHERE x.message_id IN (SELECT id FROM target) ORDER BY x.id LIMIT 100) e ON true " +
	"ORDER BY e.id"

// The same for direct message $3 between $1 and $2 (the first column is always true).
DATABASE_FETCH_DIRECT_MESSAGE_EDITS_SQL ::
	"WITH " + DATABASE_DIRECT_TARGET_SQL + " " +
	"SELECT 'true', EXISTS (SELECT 1 FROM target)::text, e.id::text, " +
	"encode(e.client_message_id, 'hex'), e.created_at::text, e.content, " +
	"COALESCE(encode(e.signature, 'hex'), ''), COALESCE(encode(e.envelope, 'hex'), '') " +
	"FROM (SELECT 1) AS one LEFT JOIN LATERAL (SELECT * FROM direct_message_edits x " +
	"WHERE x.message_id IN (SELECT id FROM target) ORDER BY x.id LIMIT 100) e ON true " +
	"ORDER BY e.id"

// The outcome word every statement above returns first.
databaseMessageChangeOutcome :: proc(word: string) -> (common.MessageChangeOutcome, bool) {
	switch word {
	case "applied":
		return .Applied, true
	case "not_member":
		return .NotMember, true
	case "not_found":
		return .NotFound, true
	case "not_author":
		return .NotAuthor, true
	case "not_admin":
		return .NotAdmin, true
	case "deleted":
		return .Deleted, true
	case "chat_disabled":
		return .ChatDisabled, true
	case "send_denied":
		return .SendDenied, true
	case "restricted":
		return .Restricted, true
	case "kind":
		return .KindMismatch, true
	case "stale_epoch":
		return .StaleEpoch, true
	case "invalid_envelope":
		return .InvalidEnvelope, true
	case "invalid":
		return .InvalidContent, true
	case "edit_limit":
		return .EditLimit, true
	case "duplicate":
		return .Duplicate, true
	}
	return .NotFound, false
}

// Reads DATABASE_MESSAGE_EDIT_COLUMNS_SQL's ten columns starting at first. Owned strings.
databaseGetMessageEditColumns :: proc(
	result: pg.Result,
	row: i32,
	first: i32,
) -> (
	editCount: int,
	lastEdit: common.MessageEdit,
	deleted: bool,
	deletion: common.MessageDeletion,
) {
	editCount = databaseGetIntOrZero(result, row, first)
	deleted = databaseGetBool(result, row, first + 1)
	if deleted {
		deletion.deletedAt = databaseGetText(result, row, first + 2)
		if !databaseGetHexBytes(result, row, first + 3, deletion.signature[:]) {
			deletion.signature = {}
		}
		return 0, {}, true, deletion
	}
	editID := databaseGetIntOrZero(result, row, first + 4)
	if editID <= 0 {
		return
	}
	lastEdit = databaseGetMessageEdit(result, row, first + 4)
	return
}

// One edit from six columns starting at first: id, client message ID, created_at, content,
// signature and sealed bytes (hex, '' for none). Owned strings and bytes.
databaseGetMessageEdit :: proc(result: pg.Result, row: i32, first: i32) -> common.MessageEdit {
	edit := common.MessageEdit {
		id        = databaseGetIntOrZero(result, row, first),
		timestamp = databaseGetText(result, row, first + 2),
		content   = databaseGetText(result, row, first + 3),
	}
	if !databaseGetHexBytes(result, row, first + 1, edit.clientMessageId[:]) {
		edit.clientMessageId = {}
	}
	if !databaseGetHexBytes(result, row, first + 4, edit.signature[:]) {
		edit.signature = {}
	}
	edit.sealed = databaseGetOwnedHexBytes(result, row, first + 5)
	return edit
}

// Owned C strings for one statement's parameters, freed together.
@(private = "file")
DatabaseMessageParams :: struct {
	values: [12]cstring,
	count:  int,
}

@(private = "file")
databaseMessageParamsAdd :: proc(params: ^DatabaseMessageParams, text: string) {
	value, _ := strings.clone_to_cstring(text)
	params.values[params.count] = value
	params.count += 1
}

@(private = "file")
databaseMessageParamsAddInt :: proc(params: ^DatabaseMessageParams, value: int) {
	params.values[params.count] = databaseIntParam(value)
	params.count += 1
}

@(private = "file")
databaseMessageParamsAddHex :: proc(params: ^DatabaseMessageParams, bytes: []u8) {
	if len(bytes) == 0 {
		databaseMessageParamsAdd(params, "")
		return
	}
	text := common.encodeBytesToHex(bytes)
	defer delete(text)
	databaseMessageParamsAdd(params, text)
}

@(private = "file")
databaseMessageParamsFree :: proc(params: ^DatabaseMessageParams) {
	for index in 0 ..< params.count {
		delete(params.values[index])
	}
	params.count = 0
}

@(private = "file")
databaseMessageParamsRun :: proc(
	conn: pg.Conn,
	query: cstring,
	params: ^DatabaseMessageParams,
) -> pg.Result {
	raw: [12][^]byte
	for index in 0 ..< params.count {
		raw[index] = transmute([^]byte)params.values[index]
	}
	return databaseExecParams(conn, query, raw[:params.count])
}

databaseExecuteMessageChange :: proc(
	conn: pg.Conn,
	request: common.DatabaseMessageChangeRequest,
) -> common.DatabaseQueryResponse {
	switch request.action {
	case .EditRoom:
		return databaseExecuteEditRoomMessage(conn, request)
	case .DeleteRoom:
		return databaseExecuteDeleteRoomMessage(conn, request)
	case .EditDirect:
		return databaseExecuteEditDirectMessage(conn, request)
	case .DeleteDirect:
		return databaseExecuteDeleteDirectMessage(conn, request)
	case .FetchRoomEdits, .FetchDirectEdits:
		return databaseExecuteFetchMessageEdits(conn, request)
	}
	return databaseErrorResponse(strings.clone("unknown message change"))
}

// The outcome column of a one-row result, or an error response.
@(private = "file")
databaseMessageChangeRow :: proc(
	conn: pg.Conn,
	result: ^pg.Result,
) -> (
	outcome: common.MessageChangeOutcome,
	failed: common.DatabaseQueryResponse,
	ok: bool,
) {
	if result^ == nil {
		return {}, databaseConnectionError(conn), false
	}
	if pg.result_status(result^) != .Tuples_OK || pg.n_tuples(result^) != 1 {
		return {}, databaseResultError(result), false
	}
	word := databaseGetText(result^, 0, 0)
	defer delete(word)
	parsed, known := databaseMessageChangeOutcome(word)
	if !known {
		return {}, databaseErrorResponse(strings.clone("unknown message change outcome")), false
	}
	return parsed, {}, true
}

databaseExecuteEditRoomMessage :: proc(
	conn: pg.Conn,
	request: common.DatabaseMessageChangeRequest,
) -> common.DatabaseQueryResponse {
	original := request.originalClientMessageId
	edit := request.clientMessageId
	signature := request.signature
	chainID := request.chainId
	sealed := len(request.sealed) > 0
	params: DatabaseMessageParams
	defer databaseMessageParamsFree(&params)
	databaseMessageParamsAddInt(&params, request.actorUserId)
	databaseMessageParamsAddInt(&params, request.roomId)
	databaseMessageParamsAddInt(&params, request.messageId)
	databaseMessageParamsAddHex(&params, original[:])
	databaseMessageParamsAddHex(&params, edit[:])
	databaseMessageParamsAdd(&params, sealed ? "" : request.content)
	databaseMessageParamsAddHex(&params, sealed ? nil : signature[:])
	databaseMessageParamsAddHex(&params, request.sealed)
	databaseMessageParamsAddInt(&params, sealed ? request.epoch : 0)
	databaseMessageParamsAddHex(&params, sealed ? chainID[:] : nil)
	databaseMessageParamsAddInt(&params, sealed ? request.chainIndex : 0)
	result := databaseMessageParamsRun(conn, DATABASE_EDIT_ROOM_MESSAGE_SQL, &params)
	defer if result != nil {
		pg.clear(result)
	}
	outcome, failed, ok := databaseMessageChangeRow(conn, &result)
	if !ok {
		return failed
	}
	changed := common.DatabaseMessageChangeResult {
		outcome  = outcome,
		senderId = databaseGetIntOrZero(result, 0, 1),
	}
	if outcome != .Applied {
		return databaseSuccess(changed)
	}
	changed.editCount = databaseGetIntOrZero(result, 0, 2)
	changed.edit = databaseMessageChangeStoredEdit(result, 3, request, sealed)
	readers := databaseGetText(result, 0, 5)
	defer delete(readers)
	changed.readerUserIds = databaseParseIDList(readers)
	return databaseSuccess(changed)
}

// The edit a statement stored, from its id and created_at columns at first and the request.
@(private = "file")
databaseMessageChangeStoredEdit :: proc(
	result: pg.Result,
	first: i32,
	request: common.DatabaseMessageChangeRequest,
	sealed: bool,
) -> common.MessageEdit {
	edit := common.MessageEdit {
		id              = databaseGetIntOrZero(result, 0, first),
		clientMessageId = request.clientMessageId,
		timestamp       = databaseGetText(result, 0, first + 1),
	}
	if sealed {
		edit.content = strings.clone("")
		edit.sealed = make([]u8, len(request.sealed))
		copy(edit.sealed, request.sealed)
	} else {
		edit.content = strings.clone(request.content)
		edit.signature = request.signature
	}
	return edit
}

databaseExecuteDeleteRoomMessage :: proc(
	conn: pg.Conn,
	request: common.DatabaseMessageChangeRequest,
) -> common.DatabaseQueryResponse {
	original := request.originalClientMessageId
	signature := request.signature
	params: DatabaseMessageParams
	defer databaseMessageParamsFree(&params)
	databaseMessageParamsAddInt(&params, request.actorUserId)
	databaseMessageParamsAddInt(&params, request.roomId)
	databaseMessageParamsAddInt(&params, request.messageId)
	databaseMessageParamsAddHex(&params, request.adminDelete ? nil : original[:])
	databaseMessageParamsAddHex(&params, request.adminDelete ? nil : signature[:])
	result := databaseMessageParamsRun(conn, DATABASE_DELETE_ROOM_MESSAGE_SQL, &params)
	defer if result != nil {
		pg.clear(result)
	}
	outcome, failed, ok := databaseMessageChangeRow(conn, &result)
	if !ok {
		return failed
	}
	changed := common.DatabaseMessageChangeResult {
		outcome  = outcome,
		senderId = databaseGetIntOrZero(result, 0, 1),
	}
	if outcome != .Applied {
		return databaseSuccess(changed)
	}
	changed.deletion = common.MessageDeletion {
		deletedAt = databaseGetText(result, 0, 2),
		signature = request.adminDelete ? {} : request.signature,
	}
	readers := databaseGetText(result, 0, 3)
	defer delete(readers)
	changed.readerUserIds = databaseParseIDList(readers)
	changed.removedBlobs = databaseParseBlobIDList(result, 4)
	return databaseSuccess(changed)
}

// A comma-separated hex blob ID column as owned IDs (malformed entries skipped).
@(private = "file")
databaseParseBlobIDList :: proc(
	result: pg.Result,
	column: i32,
) -> [dynamic]common.AttachmentBlobID {
	text := databaseGetText(result, 0, column)
	defer delete(text)
	blobs := make([dynamic]common.AttachmentBlobID)
	remaining := text
	for part in strings.split_iterator(&remaining, ",") {
		blob: common.AttachmentBlobID
		if len(part) == 2 * len(blob) && common.decodeHexIntoBuffer(part, blob[:]) {
			append(&blobs, blob)
		}
	}
	return blobs
}

databaseExecuteEditDirectMessage :: proc(
	conn: pg.Conn,
	request: common.DatabaseMessageChangeRequest,
) -> common.DatabaseQueryResponse {
	sealed := len(request.sealed) > 0
	recipientKeyHex := ""
	if sealed {
		// The envelope's AAD names the recipient's identity key: read it, verify the envelope
		// against it, and store only while the recipient still has it (the statement's
		// recipient_key), exactly as a new sealed direct message.
		senderParam := databaseIntParam(request.actorUserId)
		defer delete(senderParam)
		recipientParam := databaseIntParam(request.peerUserId)
		defer delete(recipientParam)
		keyParams := [?][^]byte {
			transmute([^]byte)senderParam,
			transmute([^]byte)recipientParam,
		}
		keyResult := databaseExecParams(
			conn,
			DATABASE_DIRECT_MESSAGE_RECIPIENT_KEY_SQL,
			keyParams[:],
		)
		if keyResult == nil {
			return databaseConnectionError(conn)
		}
		defer pg.clear(keyResult)
		if pg.result_status(keyResult) != .Tuples_OK {
			return databaseResultError(&keyResult)
		}
		recipientKey: common.IdentityPublicKeyBytes
		if pg.n_tuples(keyResult) == 0 ||
		   !databaseGetHexBytes(keyResult, 0, 0, recipientKey[:]) ||
		   recipientKey == {} ||
		   common.verifyDirectMessageEnvelope(
			   request.sealed,
			   common.DirectMessageAADFields {
				   serverIdentityPublicKey = request.serverIdentityPublicKey,
				   senderUserID = request.actorUserId,
				   recipientUserID = request.peerUserId,
				   senderIdentityPublicKey = request.senderIdentityPublicKey,
				   recipientIdentityPublicKey = recipientKey,
				   clientMessageID = request.clientMessageId,
			   },
		   ) !=
			   .None {
			return databaseSuccess(
				common.DatabaseMessageChangeResult{outcome = .InvalidEnvelope},
			)
		}
		recipientKeyHex = common.encodeBytesToHex(recipientKey[:])
	}
	defer delete(recipientKeyHex)
	original := request.originalClientMessageId
	edit := request.clientMessageId
	signature := request.signature
	params: DatabaseMessageParams
	defer databaseMessageParamsFree(&params)
	databaseMessageParamsAddInt(&params, request.actorUserId)
	databaseMessageParamsAddInt(&params, request.peerUserId)
	databaseMessageParamsAddInt(&params, request.messageId)
	databaseMessageParamsAddHex(&params, original[:])
	databaseMessageParamsAddHex(&params, edit[:])
	databaseMessageParamsAdd(&params, sealed ? "" : request.content)
	databaseMessageParamsAddHex(&params, sealed ? nil : signature[:])
	databaseMessageParamsAddHex(&params, request.sealed)
	databaseMessageParamsAdd(&params, recipientKeyHex)
	result := databaseMessageParamsRun(conn, DATABASE_EDIT_DIRECT_MESSAGE_SQL, &params)
	defer if result != nil {
		pg.clear(result)
	}
	outcome, failed, ok := databaseMessageChangeRow(conn, &result)
	if !ok {
		return failed
	}
	changed := common.DatabaseMessageChangeResult {
		outcome     = outcome,
		senderId    = databaseGetIntOrZero(result, 0, 1),
		recipientId = databaseGetIntOrZero(result, 0, 2),
	}
	if outcome != .Applied {
		return databaseSuccess(changed)
	}
	changed.editCount = databaseGetIntOrZero(result, 0, 3)
	changed.edit = databaseMessageChangeStoredEdit(result, 4, request, sealed)
	changed.readerUserIds = databaseDirectReaders(changed.senderId, changed.recipientId)
	return databaseSuccess(changed)
}

// A direct message's readers: its two sides.
@(private = "file")
databaseDirectReaders :: proc(senderID, recipientID: int) -> [dynamic]int {
	readers := make([dynamic]int, 0, 2)
	append(&readers, senderID)
	if recipientID != senderID {
		append(&readers, recipientID)
	}
	return readers
}

databaseExecuteDeleteDirectMessage :: proc(
	conn: pg.Conn,
	request: common.DatabaseMessageChangeRequest,
) -> common.DatabaseQueryResponse {
	original := request.originalClientMessageId
	signature := request.signature
	params: DatabaseMessageParams
	defer databaseMessageParamsFree(&params)
	databaseMessageParamsAddInt(&params, request.actorUserId)
	databaseMessageParamsAddInt(&params, request.peerUserId)
	databaseMessageParamsAddInt(&params, request.messageId)
	databaseMessageParamsAddHex(&params, original[:])
	databaseMessageParamsAddHex(&params, signature[:])
	result := databaseMessageParamsRun(conn, DATABASE_DELETE_DIRECT_MESSAGE_SQL, &params)
	defer if result != nil {
		pg.clear(result)
	}
	outcome, failed, ok := databaseMessageChangeRow(conn, &result)
	if !ok {
		return failed
	}
	changed := common.DatabaseMessageChangeResult {
		outcome     = outcome,
		senderId    = databaseGetIntOrZero(result, 0, 1),
		recipientId = databaseGetIntOrZero(result, 0, 2),
	}
	if outcome != .Applied {
		return databaseSuccess(changed)
	}
	changed.deletion = common.MessageDeletion {
		deletedAt = databaseGetText(result, 0, 3),
		signature = request.signature,
	}
	changed.readerUserIds = databaseDirectReaders(changed.senderId, changed.recipientId)
	changed.removedBlobs = databaseParseBlobIDList(result, 4)
	return databaseSuccess(changed)
}

databaseExecuteFetchMessageEdits :: proc(
	conn: pg.Conn,
	request: common.DatabaseMessageChangeRequest,
) -> common.DatabaseQueryResponse {
	room := request.action == .FetchRoomEdits
	params: DatabaseMessageParams
	defer databaseMessageParamsFree(&params)
	databaseMessageParamsAddInt(&params, request.actorUserId)
	databaseMessageParamsAddInt(&params, room ? request.roomId : request.peerUserId)
	databaseMessageParamsAddInt(&params, request.messageId)
	query: cstring = DATABASE_FETCH_ROOM_MESSAGE_EDITS_SQL
	if !room {
		query = DATABASE_FETCH_DIRECT_MESSAGE_EDITS_SQL
	}
	result := databaseMessageParamsRun(conn, query, &params)
	if result == nil {
		return databaseConnectionError(conn)
	}
	defer pg.clear(result)
	if pg.result_status(result) != .Tuples_OK || pg.n_tuples(result) < 1 {
		return databaseResultError(&result)
	}
	if !databaseGetBool(result, 0, 0) {
		return databaseSuccess(common.DatabaseMessageChangeResult{outcome = .NotMember})
	}
	if !databaseGetBool(result, 0, 1) {
		return databaseSuccess(common.DatabaseMessageChangeResult{outcome = .NotFound})
	}
	changed := common.DatabaseMessageChangeResult {
		outcome = .Applied,
		edits   = make([dynamic]common.MessageEdit, 0, pg.n_tuples(result)),
	}
	for row in 0 ..< pg.n_tuples(result) {
		if pg.get_is_null(result, row, 2) {
			continue
		}
		append(&changed.edits, databaseGetMessageEdit(result, row, 2))
	}
	return databaseSuccess(changed)
}
