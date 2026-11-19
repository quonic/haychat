package server

import "../common"
import "core:fmt"
import "core:strconv"
import "core:strings"
import "shared:pg"

// Attachment statements (protocol 26, migration 14, attachments plan F1). The router
// orchestrates, the database decides, and the storage worker (storage.odin) writes: no file
// byte ever reaches PostgreSQL. Each client action is one statement whose checks and change
// cannot be separated by a concurrent change.

// The room permissions an upload to a room needs (D11, D20), as a mask: the requester's set
// (DATABASE_ROOM_PERMISSIONS_*) must contain all of them, SendMessages and (protocol 27)
// AttachFiles. Binding a blob to a message checks the same (DATABASE_POST_ROOM_CHAT_MESSAGE_SQL).
DATABASE_ATTACHMENT_ROOM_PERMISSIONS_REQUIRED_SQL ::
	"(" + DATABASE_ROOM_PERMISSION_SEND_MESSAGES_SQL + " | " +
	DATABASE_ROOM_PERMISSION_ATTACH_FILES_SQL + ")"

// Binding (protocol 27, D1, D11): the four message inserts (DATABASE_POST_ROOM_CHAT_MESSAGE_SQL
// for plaintext and sealed room messages, DATABASE_POST_DIRECT_MESSAGE_SQL for plaintext and
// sealed direct messages) bind the blobs a message lists in the statement that stores it, from
// these shared pieces:
//
// - bind_in: the listed blobs in order, from five comma-separated text parameters
//   (databaseAttachmentBindParams): blob IDs (hex), stored sizes, and for a plaintext message
//   the hashes, names and media types (hex; '' for a sealed message, which leaves them NULL).
//   DATABASE_ATTACHMENT_BIND_INPUT_OPEN_SQL + "$a" + _NEXT_ + "$b" + _NEXT_ + "$c" + _NEXT_ +
//   "$d" + _NEXT_ + "$e" + DATABASE_ATTACHMENT_BIND_INPUT_CLOSE_SQL.
// - bind_rows and bind_ok: the listed rows, locked, and whether every one may be bound: it
//   exists, is the sender's, is Ready and bound to nothing, was uploaded to this conversation,
//   is encrypted exactly when the message is sealed, has the size the message names and (a
//   plaintext message) its hash; and no blob is listed twice.
//   DATABASE_ATTACHMENT_BIND_CHECK_OPEN_SQL + "<sender>" + _SEALED_ + "<message is sealed>" +
//   _CONVERSATION_ + "<a.room_id or a.peer_user_id mismatch>" + _CLOSE_SQL.
// - bound: after the insert (a CTE named stored returning id), the rows become Bound to it
//   with their position, name and media type. DATABASE_ATTACHMENT_BIND_UPDATE_OPEN_SQL +
//   "chat_message_id" or "direct_message_id" + DATABASE_ATTACHMENT_BIND_UPDATE_CLOSE_SQL.
//
// The insert itself stores (SELECT count(*) FROM bind_in) as attachment_count and only when
// (SELECT ok FROM bind_ok), so a message with a blob that fails stores nothing.
DATABASE_ATTACHMENT_BIND_INPUT_OPEN_SQL ::
	"bind_in AS (SELECT decode(u.blob, 'hex') AS blob_id, u.size::bigint AS size, " +
	"decode(NULLIF(u.sha, ''), 'hex') AS sha256, " +
	"convert_from(decode(NULLIF(u.name, ''), 'hex'), 'UTF8') AS name, " +
	"convert_from(decode(NULLIF(u.kind, ''), 'hex'), 'UTF8') AS media_type, " +
	"(u.ord - 1)::smallint AS position FROM unnest(string_to_array(("
DATABASE_ATTACHMENT_BIND_INPUT_NEXT_SQL :: ")::text, ','), string_to_array(("
DATABASE_ATTACHMENT_BIND_INPUT_CLOSE_SQL ::
	")::text, ',')) WITH ORDINALITY AS u(blob, size, sha, name, kind, ord) " +
	"WHERE u.blob IS NOT NULL), "
DATABASE_ATTACHMENT_BIND_CHECK_OPEN_SQL ::
	"bind_rows AS (SELECT a.id, a.blob_id, a.owner_user_id, a.room_id, a.peer_user_id, " +
	"a.encrypted, a.state, a.size, a.sha256, a.chat_message_id, a.direct_message_id " +
	"FROM attachments a WHERE a.blob_id IN (SELECT blob_id FROM bind_in) FOR UPDATE), " +
	"bind_ok AS (SELECT (SELECT count(DISTINCT blob_id) FROM bind_in) = " +
	"(SELECT count(*) FROM bind_in) AND NOT EXISTS (SELECT 1 FROM bind_in i " +
	"LEFT JOIN bind_rows a ON a.blob_id = i.blob_id WHERE a.id IS NULL OR a.state <> 1 " +
	"OR a.chat_message_id IS NOT NULL OR a.direct_message_id IS NOT NULL " +
	"OR a.size <> i.size OR (NOT a.encrypted AND a.sha256 IS DISTINCT FROM i.sha256) " +
	"OR a.owner_user_id <> ("
DATABASE_ATTACHMENT_BIND_CHECK_SEALED_SQL :: ")::bigint OR a.encrypted <> ("
DATABASE_ATTACHMENT_BIND_CHECK_CONVERSATION_SQL :: ") OR "
DATABASE_ATTACHMENT_BIND_CHECK_CLOSE_SQL :: ") AS ok), "
DATABASE_ATTACHMENT_BIND_UPDATE_OPEN_SQL ::
	"bound AS (UPDATE attachments a SET state = 2, bound_at = now(), position = i.position, " +
	"name = i.name, media_type = i.media_type, "
DATABASE_ATTACHMENT_BIND_UPDATE_CLOSE_SQL ::
	" = s.id FROM stored s, bind_in i WHERE a.blob_id = i.blob_id RETURNING a.id) "

// A message's attachments as one text column, for the history and conversation statements:
// one entry per blob in the message's order, comma separated, each
// "blobId:size:sha256:name:mediaType:removed" with the hash, name and media type hex ('' for a
// sealed message's blob, whose fields are inside the seal) and removed 'true' for a Removed
// tombstone (F3). '' for a message without attachments. Parsed by
// databaseParseAttachmentRefs. OPEN + "chat_message_id = <id>" (or direct_message_id) + CLOSE.
DATABASE_MESSAGE_ATTACHMENTS_OPEN_SQL ::
	"COALESCE((SELECT string_agg(encode(ma.blob_id, 'hex') || ':' || ma.size::text || ':' || " +
	"CASE WHEN ma.encrypted THEN '' ELSE COALESCE(encode(ma.sha256, 'hex'), '') END || ':' || " +
	"COALESCE(encode(convert_to(ma.name, 'UTF8'), 'hex'), '') || ':' || " +
	"COALESCE(encode(convert_to(ma.media_type, 'UTF8'), 'hex'), '') || ':' || " +
	"(ma.state = 3)::text, ',' ORDER BY ma.position, ma.id) FROM attachments ma WHERE ma."
DATABASE_MESSAGE_ATTACHMENTS_CLOSE_SQL :: "), '')"

// The five bind parameters for a message's attachments (see the binding comment above), as
// owned C strings: blob IDs, sizes, hashes, names and media types. A sealed message sends only
// blob IDs and sizes.
databaseAttachmentBindParams :: proc(
	refs: []common.AttachmentRef,
	sealed: bool,
) -> (
	params: [5]cstring,
) {
	builders: [5]strings.Builder
	for &builder in builders {
		builder = strings.builder_make()
	}
	defer for &builder in builders {
		strings.builder_destroy(&builder)
	}
	for ref, index in refs {
		ref := ref
		if index > 0 {
			strings.write_byte(&builders[0], ',')
			strings.write_byte(&builders[1], ',')
			if !sealed {
				strings.write_byte(&builders[2], ',')
				strings.write_byte(&builders[3], ',')
				strings.write_byte(&builders[4], ',')
			}
		}
		databaseAttachmentWriteHex(&builders[0], ref.blobId[:])
		fmt.sbprintf(&builders[1], "%d", ref.size)
		if !sealed {
			databaseAttachmentWriteHex(&builders[2], ref.sha256[:])
			databaseAttachmentWriteHex(&builders[3], transmute([]u8)ref.name)
			databaseAttachmentWriteHex(&builders[4], transmute([]u8)ref.mediaType)
		}
	}
	for index in 0 ..< len(params) {
		params[index], _ = strings.clone_to_cstring(strings.to_string(builders[index]))
	}
	return
}

@(private = "file")
databaseAttachmentWriteHex :: proc(builder: ^strings.Builder, bytes: []u8) {
	hex := common.encodeBytesToHex(bytes)
	strings.write_string(builder, hex)
	delete(hex)
}

// Parses the column DATABASE_MESSAGE_ATTACHMENTS_* returns (owned references; nil for '').
// A malformed entry is skipped: a message whose list is then incomplete fails its signature or
// its seal check in the client, never silently.
databaseParseAttachmentRefs :: proc(text: string) -> [dynamic]common.AttachmentRef {
	if len(text) == 0 {
		return nil
	}
	refs := make([dynamic]common.AttachmentRef, 0, common.ATTACHMENTS_PER_MESSAGE_MAX)
	entries := text
	for entry in strings.split_iterator(&entries, ",") {
		fields: [6]string
		count := 0
		rest := entry
		for field in strings.split_iterator(&rest, ":") {
			if count == len(fields) {
				count += 1
				break
			}
			fields[count] = field
			count += 1
		}
		if count != len(fields) {
			continue
		}
		ref: common.AttachmentRef
		size, sizeOK := strconv.parse_u64(fields[1])
		if !common.decodeHexIntoBuffer(fields[0], ref.blobId[:]) || !sizeOK {
			continue
		}
		ref.size = size
		if len(fields[2]) > 0 && !common.decodeHexIntoBuffer(fields[2], ref.sha256[:]) {
			continue
		}
		name, nameOK := databaseAttachmentHexText(fields[3])
		mediaType, mediaTypeOK := databaseAttachmentHexText(fields[4])
		if !nameOK || !mediaTypeOK {
			delete(name)
			delete(mediaType)
			continue
		}
		ref.name = name
		ref.mediaType = mediaType
		ref.removed = fields[5] == "true"
		append(&refs, ref)
	}
	return refs
}

@(private = "file")
databaseAttachmentHexText :: proc(hex: string) -> (string, bool) {
	if len(hex) == 0 {
		return "", true
	}
	if len(hex) % 2 != 0 {
		return "", false
	}
	bytes := make([]u8, len(hex) / 2)
	if !common.decodeHexIntoBuffer(hex, bytes) {
		delete(bytes)
		return "", false
	}
	return string(bytes), true
}

// The begin statement (D11, D21). $1 the owner, $2 the room (0 for a direct message), $3 the
// recipient (0 for a room), $4 whether the client encrypts, $5 the declared size, $6 the new
// blob ID as hex, $7 the account quota, $8 the hourly upload limit, $9 the server capacity
// (each 0 for none) and $10 the largest blob.
//
// A room upload needs membership of a room with chat, the room permissions above through the
// shared subquery (admins hold every bit), and the room's encryption flag; a direct message
// upload needs a recipient that exists and is not the owner, whom the owner may meet
// (DATABASE_USERS_MAY_MEET_*, the direct message send's rule). The quota sums the owner's rows
// that are not Removed, the rate every row of the owner created in the last hour, the capacity
// every row that is not Removed; the insert reserves the declared size at once, so later
// begins see it. One row: each check (member, send, chat, encryption, recipient, visibility,
// size, quota, rate, capacity; protocol 27 reports Send and AttachFiles apart) and the new row's
// ID (NULL when nothing was stored).
DATABASE_ATTACHMENT_BEGIN_SQL ::
	"WITH room AS (SELECT r.encrypted, r.room_type FROM rooms r " +
	"WHERE r.id = $2::bigint AND $2::bigint > 0), " +
	"member AS (SELECT 1 FROM room_members WHERE room_id = $2::bigint AND user_id = $1::bigint), " +
	"may_send AS (SELECT p.mask, ((p.mask & " + DATABASE_ATTACHMENT_ROOM_PERMISSIONS_REQUIRED_SQL +
	") = " + DATABASE_ATTACHMENT_ROOM_PERMISSIONS_REQUIRED_SQL + ") AS ok FROM (SELECT " +
	DATABASE_ROOM_PERMISSIONS_OPEN_SQL + "$1" + DATABASE_ROOM_PERMISSIONS_ROOM_SQL + "$2" +
	DATABASE_ROOM_PERMISSIONS_CLOSE_SQL + " AS mask) p), " +
	"peer AS (SELECT id FROM users WHERE id = $3::bigint AND id <> $1::bigint " +
	"AND $3::bigint > 0), " +
	"allowed AS (SELECT " + DATABASE_USERS_MAY_MEET_OPEN_SQL + "$1" +
	DATABASE_USERS_MAY_MEET_MIDDLE_SQL + "$3" + DATABASE_USERS_MAY_MEET_CLOSE_SQL + " AS ok), " +
	"usage AS (SELECT COALESCE(sum(size) FILTER (WHERE state <> 3), 0) AS stored, " +
	"COALESCE(sum(size) FILTER (WHERE created_at > now() - interval '1 hour'), 0) AS recent " +
	"FROM attachments WHERE owner_user_id = $1::bigint), " +
	"total AS (SELECT CASE WHEN $9::bigint > 0 THEN (SELECT COALESCE(sum(size), 0) " +
	"FROM attachments WHERE state <> 3) ELSE 0 END AS stored), " +
	"checks AS (SELECT " +
	"(NOT $2::bigint > 0 OR (EXISTS (SELECT 1 FROM room) AND EXISTS (SELECT 1 FROM member))) " +
	"AS member_ok, " +
	"(NOT $2::bigint > 0 OR ((SELECT mask FROM may_send) & " +
	DATABASE_ROOM_PERMISSION_SEND_MESSAGES_SQL + ") <> 0) AS send_ok, " +
	"(NOT $2::bigint > 0 OR ((SELECT mask FROM may_send) & " +
	DATABASE_ROOM_PERMISSION_ATTACH_FILES_SQL + ") <> 0) AS attach_ok, " +
	"(NOT $2::bigint > 0 OR COALESCE((SELECT room_type IN (1, 3) FROM room), false)) AS chat_ok, " +
	"(NOT $2::bigint > 0 OR COALESCE((SELECT encrypted FROM room), false) = $4::boolean) " +
	"AS encryption_ok, " +
	"(NOT $3::bigint > 0 OR EXISTS (SELECT 1 FROM peer)) AS peer_ok, " +
	"(NOT $3::bigint > 0 OR (SELECT ok FROM allowed)) AS meet_ok, " +
	"($5::bigint BETWEEN 1 AND $10::bigint) AS size_ok, " +
	"($7::bigint = 0 OR (SELECT stored FROM usage) + $5::bigint <= $7::bigint) AS quota_ok, " +
	"($8::bigint = 0 OR (SELECT recent FROM usage) + $5::bigint <= $8::bigint) AS rate_ok, " +
	"($9::bigint = 0 OR (SELECT stored FROM total) + $5::bigint <= $9::bigint) AS capacity_ok), " +
	"stored AS (INSERT INTO attachments (blob_id, owner_user_id, room_id, peer_user_id, " +
	"encrypted, size) SELECT decode($6::text, 'hex'), $1::bigint, NULLIF($2::bigint, 0), " +
	"NULLIF($3::bigint, 0), $4::boolean, $5::bigint FROM checks " +
	"WHERE member_ok AND (NOT $2::bigint > 0 OR (SELECT ok FROM may_send)) AND chat_ok " +
	"AND encryption_ok AND peer_ok AND meet_ok " +
	"AND size_ok AND quota_ok AND rate_ok AND capacity_ok " +
	"AND (($2::bigint > 0) <> ($3::bigint > 0)) RETURNING id) " +
	"SELECT c.member_ok, c.send_ok, c.attach_ok, c.chat_ok, c.encryption_ok, c.peer_ok, " +
	"c.meet_ok, " +
	"c.size_ok, c.quota_ok, c.rate_ok, c.capacity_ok, (SELECT id FROM stored)::text FROM checks c"

// The owner's ($2) Uploading blob $1 (hex): its declared size and the bytes recorded so far.
DATABASE_ATTACHMENT_RESUME_SQL ::
	"SELECT size::text, received::text FROM attachments " +
	"WHERE blob_id = decode($1::text, 'hex') AND owner_user_id = $2::bigint AND state = 0"

// Records an upload's progress ($3 bytes stored) and that a chunk arrived.
DATABASE_ATTACHMENT_PROGRESS_SQL ::
	"UPDATE attachments SET received = LEAST($3::bigint, size), last_chunk_at = now() " +
	"WHERE blob_id = decode($1::text, 'hex') AND owner_user_id = $2::bigint AND state = 0 " +
	"RETURNING id"

// Marks the owner's Uploading blob Ready once the storage worker stored exactly its declared
// size ($4) with the hash $3 (hex).
DATABASE_ATTACHMENT_FINISH_SQL ::
	"UPDATE attachments SET state = 1, sha256 = decode($3::text, 'hex'), received = size, " +
	"completed_at = now(), last_chunk_at = now() " +
	"WHERE blob_id = decode($1::text, 'hex') AND owner_user_id = $2::bigint AND state = 0 " +
	"AND size = $4::bigint RETURNING size::text"

// Makes the owner's Uploading blob a tombstone (a cancel or a hash mismatch): it stops counting
// toward the quota at once and toward the hourly rate an hour after it was created, and the
// sweeper deletes the row after that hour.
DATABASE_ATTACHMENT_ABANDON_SQL ::
	"UPDATE attachments SET state = 3, removed_by_user_id = $2::bigint, removed_at = now() " +
	"WHERE blob_id = decode($1::text, 'hex') AND owner_user_id = $2::bigint AND state = 0 " +
	"RETURNING id"

// Deletes a blob nothing was written to: the storage worker refused it at begin (the free-disk
// reserve), so it reserved nothing on disk and must not count toward any limit.
DATABASE_ATTACHMENT_DELETE_NEW_SQL ::
	"DELETE FROM attachments WHERE blob_id = decode($1::text, 'hex') " +
	"AND owner_user_id = $2::bigint AND state = 0 AND received = 0 RETURNING id"

// May $2 download blob $1 (D10, protocol 27)? Whoever may read the message's history may
// download its files, and nobody else:
//
// - a Bound blob of a room message: $2 is a member of the room and, in a From join room
//   (DATABASE_HISTORY_SINCE_*, the cut the room history statement uses), the message was
//   created after $2 joined;
// - a Bound blob of a direct message: $2 is its sender or its recipient (a restricted account
//   keeps its direct message history, D17, so it keeps these files too);
// - the owner's own Ready blob, before any message binds it.
//
// Admins get no bypass, as for history. A Removed blob (state 3) and an Uploading one are never
// downloadable. One row when allowed: the stored size, the hash as hex, and (protocol 28)
// whether an admin removed the file, for a reader of a bound tombstone, so its refusal can say
// so (ATTACHMENT_REMOVED_MESSAGE) instead of "not found".
DATABASE_ATTACHMENT_DOWNLOAD_CHECK_SQL ::
	"SELECT a.size::text, encode(a.sha256, 'hex'), (a.state = 3)::text FROM attachments a " +
	"LEFT JOIN chat_messages cm ON cm.id = a.chat_message_id " +
	"LEFT JOIN direct_messages dm ON dm.id = a.direct_message_id " +
	"WHERE a.blob_id = decode($1::text, 'hex') AND (" +
	"(a.state = 1 AND a.owner_user_id = $2::bigint) OR (a.state IN (2, 3) AND (" +
	"(cm.id IS NOT NULL AND EXISTS (SELECT 1 FROM room_members dl_rm " +
	"WHERE dl_rm.room_id = cm.room_id AND dl_rm.user_id = $2::bigint) " +
	"AND cm.created_at > COALESCE(" + DATABASE_HISTORY_SINCE_OPEN_SQL + "cm.room_id" +
	DATABASE_HISTORY_SINCE_MIDDLE_SQL + "$2::bigint" + DATABASE_HISTORY_SINCE_CLOSE_SQL +
	", '-infinity'::timestamptz)) OR " +
	"(dm.id IS NOT NULL AND $2::bigint IN (dm.sender_user_id, dm.recipient_user_id)))))"

// The rows the sweeper may delete (D17), for an alias a of attachments and $1 the pending window
// in hours: never one younger than an hour, never one bound to a message; an upload with no
// chunk for an hour or older than the window, a Ready blob older than the window, a Bound blob
// whose message is gone (its link turned NULL), and an unbound tombstone.
DATABASE_ATTACHMENT_SWEEPABLE_SQL ::
	"(a.created_at < now() - interval '1 hour' AND a.chat_message_id IS NULL " +
	"AND a.direct_message_id IS NULL AND ((a.state = 0 AND (a.last_chunk_at < now() - " +
	"interval '1 hour' OR a.created_at < now() - make_interval(hours => $1::integer))) " +
	"OR (a.state = 1 AND a.created_at < now() - make_interval(hours => $1::integer)) " +
	"OR a.state IN (2, 3)))"

// Deletes up to $2 sweepable rows except those whose blob ID is in $3 (comma-separated hex,
// live transfers) and returns their blob IDs and states, for the storage worker to delete the
// files. The rows go first: a blob whose row is gone can no longer be bound, resumed or
// downloaded, and a file a crash leaves behind has no row, which the startup scan removes.
DATABASE_ATTACHMENT_SWEEP_SQL ::
	"DELETE FROM attachments WHERE id IN (SELECT a.id FROM attachments a WHERE " +
	DATABASE_ATTACHMENT_SWEEPABLE_SQL +
	" AND a.blob_id NOT IN (SELECT decode(x, 'hex') FROM " +
	"unnest(string_to_array($3::text, ',')) x) ORDER BY a.id LIMIT $2::integer) " +
	"RETURNING encode(blob_id, 'hex'), state::text"

// The rows among the blob IDs $1 (comma-separated hex), with their states.
DATABASE_ATTACHMENT_KNOWN_SQL ::
	"SELECT encode(blob_id, 'hex'), state::text FROM attachments WHERE blob_id IN " +
	"(SELECT decode(x, 'hex') FROM unnest(string_to_array($1::text, ',')) x)"

// Whether the attachments table has any row at all (#131): asked only when Known found none of
// the scanned files, since a found row already answers it.
DATABASE_ATTACHMENT_ANY_ROW_SQL :: "SELECT EXISTS (SELECT 1 FROM attachments)"

// Most rows one sweep pass deletes; the router runs another pass when a pass was full.
ATTACHMENT_SWEEP_BATCH :: 500

// ── Moderation (protocol 28, attachments plan F3, D22) ────────────────────────────────────

// An admin ($1) removes blob $2 (hex): a Ready or Bound blob becomes a Removed tombstone with
// removed_by_user_id and removed_at. Nothing else changes: sha256, size, name, media_type,
// position and the message link stay, because a plaintext message's v2 signature covers them
// and its history must still list the file (as removed). The admin check
// (DATABASE_ACTOR_IS_ADMIN_SQL) is in the statement; admins may remove their own files too.
// The tombstone stops counting toward the quota and the capacity at once (they sum state <> 3).
//
// One row: the outcome ('applied', 'not_admin', 'not_found' for an unknown, Uploading or
// already Removed blob), the owner, the conversation as ServerAttachmentRemoved names it (a room
// message's room and sender; a direct message's sender and recipient; an unbound blob's owner
// and the room or recipient it was uploaded to), the message IDs (0 for none), and the accounts
// that may read the message, comma separated: a room message's members who may read it (the
// From join cut DATABASE_HISTORY_SINCE_*, shared with history and the download check), both
// sides of a direct message, or the owner of a blob no message holds.
DATABASE_ATTACHMENT_REMOVE_SQL ::
	"WITH actor AS (SELECT " + DATABASE_ACTOR_IS_ADMIN_SQL + " AS ok), " +
	"target AS (SELECT a.id, a.owner_user_id, a.room_id, a.peer_user_id, a.chat_message_id, " +
	"a.direct_message_id FROM attachments a WHERE a.blob_id = decode($2::text, 'hex') " +
	"AND a.state IN (1, 2)), " +
	"decision AS (SELECT CASE WHEN NOT (SELECT ok FROM actor) THEN 'not_admin' " +
	"WHEN NOT EXISTS (SELECT 1 FROM target) THEN 'not_found' ELSE 'applied' END AS outcome), " +
	"removed AS (UPDATE attachments a SET state = 3, removed_by_user_id = $1::bigint, " +
	"removed_at = now() FROM target t, decision d WHERE a.id = t.id AND d.outcome = 'applied' " +
	"RETURNING a.id), " +
	"cm AS (SELECT c.id, c.room_id, c.sender_user_id, c.created_at FROM chat_messages c " +
	"JOIN target t ON c.id = t.chat_message_id WHERE (SELECT ok FROM actor)), " +
	"dm AS (SELECT m.id, m.sender_user_id, m.recipient_user_id FROM direct_messages m " +
	"JOIN target t ON m.id = t.direct_message_id WHERE (SELECT ok FROM actor)), " +
	"readers AS (SELECT rm.user_id FROM cm JOIN room_members rm ON rm.room_id = cm.room_id " +
	"WHERE cm.created_at > COALESCE(" + DATABASE_HISTORY_SINCE_OPEN_SQL + "cm.room_id" +
	DATABASE_HISTORY_SINCE_MIDDLE_SQL + "rm.user_id" + DATABASE_HISTORY_SINCE_CLOSE_SQL +
	", '-infinity'::timestamptz) " +
	"UNION SELECT sender_user_id FROM dm UNION SELECT recipient_user_id FROM dm " +
	"UNION SELECT t.owner_user_id FROM target t WHERE (SELECT ok FROM actor) " +
	"AND NOT EXISTS (SELECT 1 FROM cm) AND NOT EXISTS (SELECT 1 FROM dm)) " +
	"SELECT d.outcome, " +
	"(EXISTS (SELECT 1 FROM removed))::text, COALESCE(t.owner_user_id, 0)::text, " +
	"COALESCE(cm.room_id, CASE WHEN dm.id IS NULL THEN t.room_id END, 0)::text, " +
	"COALESCE(cm.sender_user_id, dm.sender_user_id, t.owner_user_id, 0)::text, " +
	"COALESCE(dm.recipient_user_id, CASE WHEN cm.id IS NULL THEN t.peer_user_id END, 0)::text, " +
	"COALESCE(cm.id, 0)::text, COALESCE(dm.id, 0)::text, " +
	"COALESCE((SELECT string_agg(user_id::text, ',' ORDER BY user_id) FROM readers), '') " +
	"FROM decision d LEFT JOIN target t ON true LEFT JOIN cm ON true LEFT JOIN dm ON true"

// Storage use for an admin ($1; DATABASE_ACTOR_IS_ADMIN_SQL in the statement): whether the
// requester is an admin, every stored byte that is not a tombstone, and the top $2 accounts by
// those bytes as "userId:bytes:count", comma separated, largest first. An Uploading blob counts
// with its declared size, which its begin reserved.
DATABASE_ATTACHMENT_USAGE_SQL ::
	"WITH actor AS (SELECT " + DATABASE_ACTOR_IS_ADMIN_SQL + " AS ok), " +
	"live AS (SELECT owner_user_id, size FROM attachments WHERE state <> 3 " +
	"AND (SELECT ok FROM actor)), " +
	"accounts AS (SELECT owner_user_id, sum(size) AS bytes, count(*) AS n FROM live " +
	"GROUP BY owner_user_id ORDER BY bytes DESC, owner_user_id LIMIT $2::integer) " +
	"SELECT (SELECT ok FROM actor)::text, (SELECT COALESCE(sum(size), 0) FROM live)::text, " +
	"COALESCE((SELECT string_agg(owner_user_id::text || ':' || bytes::text || ':' || n::text, " +
	"',' ORDER BY bytes DESC, owner_user_id) FROM accounts), '')"

// The newest $1 bound tombstones (state Removed with a message link). The hourly pass hands
// their blob IDs to the storage worker, whose delete is idempotent, so a removal made in SQL
// (deploy/sql/remove-attachment.sql, which cannot reach the storage worker) loses its file
// within the hour. An unbound tombstone's file goes with its row (the sweeper), and the startup
// scan deletes every file whose row is Removed.
DATABASE_ATTACHMENT_TOMBSTONE_FILES_SQL ::
	"SELECT encode(blob_id, 'hex'), state::text FROM attachments WHERE state = 3 " +
	"AND (chat_message_id IS NOT NULL OR direct_message_id IS NOT NULL) " +
	"ORDER BY removed_at DESC NULLS LAST, id DESC LIMIT $1::integer"

// Most tombstones one hourly pass re-deletes files for.
ATTACHMENT_TOMBSTONE_FILES_BATCH :: 1000

@(private = "file")
databaseAttachmentHex :: proc(bytes: []u8) -> cstring {
	hex := common.encodeBytesToHex(bytes)
	defer delete(hex)
	value, _ := strings.clone_to_cstring(hex)
	return value
}

// The blob IDs as one comma-separated hex string.
@(private = "file")
databaseAttachmentHexList :: proc(blobIds: []common.AttachmentBlobID) -> cstring {
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	for blobId, index in blobIds {
		if index > 0 {
			strings.write_byte(&builder, ',')
		}
		id := blobId
		hex := common.encodeBytesToHex(id[:])
		strings.write_string(&builder, hex)
		delete(hex)
	}
	value, _ := strings.clone_to_cstring(strings.to_string(builder))
	return value
}

@(private = "file")
databaseAttachmentGetU64 :: proc(result: pg.Result, row, column: i32) -> u64 {
	value, ok := databaseGetInt(result, row, column)
	if !ok || value < 0 {
		return 0
	}
	return u64(value)
}

// Parses a hex blob ID column; false for anything that is not 16 bytes.
@(private = "file")
databaseAttachmentGetBlobID :: proc(
	result: pg.Result,
	row, column: i32,
) -> (
	blobId: common.AttachmentBlobID,
	ok: bool,
) {
	text := databaseGetText(result, row, column)
	defer delete(text)
	ok = common.decodeHexIntoBuffer(text, blobId[:])
	return
}

// Runs one statement with text parameters and frees them.
@(private = "file")
databaseAttachmentExec :: proc(conn: pg.Conn, query: cstring, params: []cstring) -> pg.Result {
	raw := make([][^]byte, len(params))
	defer delete(raw)
	for param, index in params {
		raw[index] = transmute([^]byte)param
	}
	result := databaseExecParams(conn, query, raw)
	for param in params {
		delete(param)
	}
	return result
}

databaseExecuteAttachmentRequest :: proc(
	conn: pg.Conn,
	request: common.DatabaseAttachmentRequest,
) -> common.DatabaseQueryResponse {
	blobId := request.blobId
	switch request.action {
	case .Begin:
		return databaseExecuteAttachmentBegin(conn, request)
	case .Resume:
		result := databaseAttachmentExec(
			conn,
			DATABASE_ATTACHMENT_RESUME_SQL,
			{databaseAttachmentHex(blobId[:]), databaseIntParam(request.userId)},
		)
		if result == nil {
			return databaseConnectionError(conn)
		}
		defer pg.clear(result)
		if pg.result_status(result) != .Tuples_OK {
			return databaseResultError(&result)
		}
		attachment := common.DatabaseAttachmentResult {
			action  = request.action,
			outcome = .NotFound,
		}
		if pg.n_tuples(result) == 1 {
			attachment.outcome = .Applied
			attachment.size = databaseAttachmentGetU64(result, 0, 0)
			attachment.received = databaseAttachmentGetU64(result, 0, 1)
		}
		return databaseSuccess(attachment)
	case .Progress, .Abandon, .DeleteNew:
		query: cstring = DATABASE_ATTACHMENT_PROGRESS_SQL
		params := make([dynamic]cstring, 0, 3)
		defer delete(params)
		append(&params, databaseAttachmentHex(blobId[:]), databaseIntParam(request.userId))
		#partial switch request.action {
		case .Progress:
			append(&params, databaseIntParam(int(request.size)))
		case .Abandon:
			query = DATABASE_ATTACHMENT_ABANDON_SQL
		case .DeleteNew:
			query = DATABASE_ATTACHMENT_DELETE_NEW_SQL
		}
		result := databaseAttachmentExec(conn, query, params[:])
		if result == nil {
			return databaseConnectionError(conn)
		}
		defer pg.clear(result)
		if pg.result_status(result) != .Tuples_OK {
			return databaseResultError(&result)
		}
		return databaseSuccess(
			common.DatabaseAttachmentResult {
				action = request.action,
				outcome = pg.n_tuples(result) > 0 ? .Applied : .NotFound,
			},
		)
	case .Finish:
		sha := request.sha256
		result := databaseAttachmentExec(
			conn,
			DATABASE_ATTACHMENT_FINISH_SQL,
			{
				databaseAttachmentHex(blobId[:]),
				databaseIntParam(request.userId),
				databaseAttachmentHex(sha[:]),
				databaseIntParam(int(request.size)),
			},
		)
		if result == nil {
			return databaseConnectionError(conn)
		}
		defer pg.clear(result)
		if pg.result_status(result) != .Tuples_OK {
			return databaseResultError(&result)
		}
		attachment := common.DatabaseAttachmentResult {
			action  = request.action,
			outcome = .NotFound,
			sha256  = sha,
		}
		if pg.n_tuples(result) == 1 {
			attachment.outcome = .Applied
			attachment.size = databaseAttachmentGetU64(result, 0, 0)
		}
		return databaseSuccess(attachment)
	case .DownloadCheck:
		result := databaseAttachmentExec(
			conn,
			DATABASE_ATTACHMENT_DOWNLOAD_CHECK_SQL,
			{databaseAttachmentHex(blobId[:]), databaseIntParam(request.userId)},
		)
		if result == nil {
			return databaseConnectionError(conn)
		}
		defer pg.clear(result)
		if pg.result_status(result) != .Tuples_OK {
			return databaseResultError(&result)
		}
		attachment := common.DatabaseAttachmentResult {
			action  = request.action,
			outcome = .NotFound,
		}
		if pg.n_tuples(result) == 1 {
			if databaseGetBool(result, 0, 2) {
				attachment.outcome = .Removed
				return databaseSuccess(attachment)
			}
			attachment.outcome = .Applied
			attachment.size = databaseAttachmentGetU64(result, 0, 0)
			shaText := databaseGetText(result, 0, 1)
			defer delete(shaText)
			_ = common.decodeHexIntoBuffer(shaText, attachment.sha256[:])
		}
		return databaseSuccess(attachment)
	case .Remove:
		return databaseExecuteAttachmentRemove(conn, request)
	case .Usage:
		return databaseExecuteAttachmentUsage(conn, request)
	case .Sweep, .Known, .TombstoneFiles:
		query: cstring = DATABASE_ATTACHMENT_KNOWN_SQL
		params := make([dynamic]cstring, 0, 3)
		defer delete(params)
		#partial switch request.action {
		case .Sweep:
			query = DATABASE_ATTACHMENT_SWEEP_SQL
			append(
				&params,
				databaseIntParam(request.pendingHours),
				databaseIntParam(request.limit > 0 ? request.limit : ATTACHMENT_SWEEP_BATCH),
			)
			append(&params, databaseAttachmentHexList(request.blobIds[:]))
		case .TombstoneFiles:
			query = DATABASE_ATTACHMENT_TOMBSTONE_FILES_SQL
			append(
				&params,
				databaseIntParam(
					request.limit > 0 ? request.limit : ATTACHMENT_TOMBSTONE_FILES_BATCH,
				),
			)
		case:
			append(&params, databaseAttachmentHexList(request.blobIds[:]))
		}
		result := databaseAttachmentExec(conn, query, params[:])
		if result == nil {
			return databaseConnectionError(conn)
		}
		defer pg.clear(result)
		if pg.result_status(result) != .Tuples_OK {
			return databaseResultError(&result)
		}
		attachment := common.DatabaseAttachmentResult {
			action  = request.action,
			outcome = .Applied,
			blobs   = make([dynamic]common.DatabaseAttachmentBlob, 0, pg.n_tuples(result)),
		}
		for row in 0 ..< pg.n_tuples(result) {
			id, idOK := databaseAttachmentGetBlobID(result, row, 0)
			stateValue, stateOK := databaseGetInt(result, row, 1)
			if !idOK || !stateOK || stateValue < 0 || stateValue > 3 {
				continue
			}
			append(
				&attachment.blobs,
				common.DatabaseAttachmentBlob {
					blobId = id,
					state = common.AttachmentState(stateValue),
				},
			)
		}
		if request.action == .Known && len(attachment.blobs) == 0 {
			anyRow := databaseAttachmentExec(conn, DATABASE_ATTACHMENT_ANY_ROW_SQL, nil)
			if anyRow == nil {
				delete(attachment.blobs)
				return databaseConnectionError(conn)
			}
			defer pg.clear(anyRow)
			if pg.result_status(anyRow) != .Tuples_OK || pg.n_tuples(anyRow) != 1 {
				delete(attachment.blobs)
				return databaseResultError(&anyRow)
			}
			attachment.tableEmpty = !databaseGetBool(anyRow, 0, 0)
		}
		return databaseSuccess(attachment)
	}
	return databaseErrorResponse(strings.clone("unknown attachment action"))
}

@(private = "file")
databaseExecuteAttachmentBegin :: proc(
	conn: pg.Conn,
	request: common.DatabaseAttachmentRequest,
) -> common.DatabaseQueryResponse {
	blobId := request.blobId
	params := [?]cstring {
		databaseIntParam(request.userId),
		databaseIntParam(max(request.roomId, 0)),
		databaseIntParam(max(request.recipientUserId, 0)),
		fmt.caprintf("%v", request.encrypted),
		fmt.caprintf("%d", request.size),
		databaseAttachmentHex(blobId[:]),
		fmt.caprintf("%d", request.quotaBytes),
		fmt.caprintf("%d", request.bytesPerHour),
		fmt.caprintf("%d", request.capacityBytes),
		fmt.caprintf("%d", request.maxBytes),
	}
	result := databaseAttachmentExec(conn, DATABASE_ATTACHMENT_BEGIN_SQL, params[:])
	if result == nil {
		return databaseConnectionError(conn)
	}
	defer pg.clear(result)
	if pg.result_status(result) != .Tuples_OK || pg.n_tuples(result) != 1 {
		return databaseResultError(&result)
	}
	// The checks in the order a refusal is reported: the first that failed names it.
	refusals := [?]common.DatabaseAttachmentOutcome {
		.NotMember,
		.SendDenied,
		.AttachDenied,
		.ChatDisabled,
		.EncryptionMismatch,
		.UnknownRecipient,
		.Restricted,
		.TooLarge,
		.QuotaExceeded,
		.RateExceeded,
		.CapacityExceeded,
	}
	attachment := common.DatabaseAttachmentResult {
		action  = .Begin,
		outcome = .Applied,
		size    = request.size,
	}
	for refusal, column in refusals {
		if !databaseGetBool(result, 0, i32(column)) {
			attachment.outcome = refusal
			return databaseSuccess(attachment)
		}
	}
	if pg.get_is_null(result, 0, i32(len(refusals))) {
		attachment.outcome = .NotFound
	}
	return databaseSuccess(attachment)
}

// Parses a comma-separated list of positive integers (malformed entries skipped).
@(private = "file")
databaseAttachmentParseIDs :: proc(text: string) -> [dynamic]int {
	ids := make([dynamic]int)
	rest := text
	for field in strings.split_iterator(&rest, ",") {
		if value, ok := strconv.parse_int(field); ok && value > 0 {
			append(&ids, value)
		}
	}
	return ids
}

@(private = "file")
databaseExecuteAttachmentRemove :: proc(
	conn: pg.Conn,
	request: common.DatabaseAttachmentRequest,
) -> common.DatabaseQueryResponse {
	blobId := request.blobId
	result := databaseAttachmentExec(
		conn,
		DATABASE_ATTACHMENT_REMOVE_SQL,
		{databaseIntParam(request.userId), databaseAttachmentHex(blobId[:])},
	)
	if result == nil {
		return databaseConnectionError(conn)
	}
	defer pg.clear(result)
	if pg.result_status(result) != .Tuples_OK || pg.n_tuples(result) != 1 {
		return databaseResultError(&result)
	}
	attachment := common.DatabaseAttachmentResult {
		action  = .Remove,
		outcome = .NotFound,
	}
	outcome := databaseGetText(result, 0, 0)
	defer delete(outcome)
	switch outcome {
	case "not_admin":
		attachment.outcome = .NotAdmin
		return databaseSuccess(attachment)
	case "applied":
		if !databaseGetBool(result, 0, 1) {
			return databaseSuccess(attachment)
		}
		attachment.outcome = .Applied
	case:
		return databaseSuccess(attachment)
	}
	readers := databaseGetText(result, 0, 8)
	defer delete(readers)
	attachment.removal = common.DatabaseAttachmentRemoval {
		ownerUserId     = databaseGetIntOrZero(result, 0, 2),
		roomId          = databaseGetIntOrZero(result, 0, 3),
		senderId        = databaseGetIntOrZero(result, 0, 4),
		recipientId     = databaseGetIntOrZero(result, 0, 5),
		chatMessageId   = databaseGetIntOrZero(result, 0, 6),
		directMessageId = databaseGetIntOrZero(result, 0, 7),
		readerUserIds   = databaseAttachmentParseIDs(readers),
	}
	return databaseSuccess(attachment)
}

@(private = "file")
databaseExecuteAttachmentUsage :: proc(
	conn: pg.Conn,
	request: common.DatabaseAttachmentRequest,
) -> common.DatabaseQueryResponse {
	limit := request.limit > 0 ? request.limit : common.ATTACHMENT_USAGE_ACCOUNTS_MAX
	result := databaseAttachmentExec(
		conn,
		DATABASE_ATTACHMENT_USAGE_SQL,
		{databaseIntParam(request.userId), databaseIntParam(limit)},
	)
	if result == nil {
		return databaseConnectionError(conn)
	}
	defer pg.clear(result)
	if pg.result_status(result) != .Tuples_OK || pg.n_tuples(result) != 1 {
		return databaseResultError(&result)
	}
	attachment := common.DatabaseAttachmentResult {
		action  = .Usage,
		outcome = .NotAdmin,
	}
	if !databaseGetBool(result, 0, 0) {
		return databaseSuccess(attachment)
	}
	attachment.outcome = .Applied
	attachment.usedBytes = databaseAttachmentGetU64(result, 0, 1)
	text := databaseGetText(result, 0, 2)
	defer delete(text)
	attachment.accounts = make([dynamic]common.AttachmentAccountUsage, 0, limit)
	rest := text
	for entry in strings.split_iterator(&rest, ",") {
		fields := strings.split(entry, ":")
		defer delete(fields)
		if len(fields) != 3 {
			continue
		}
		userId, userOK := strconv.parse_int(fields[0])
		bytes, bytesOK := strconv.parse_u64(fields[1])
		count, countOK := strconv.parse_int(fields[2])
		if !userOK || !bytesOK || !countOK {
			continue
		}
		append(
			&attachment.accounts,
			common.AttachmentAccountUsage{userId = userId, bytes = bytes, count = count},
		)
	}
	return databaseSuccess(attachment)
}
