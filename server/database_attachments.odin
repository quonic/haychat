package server

import "../common"
import "core:fmt"
import "core:strings"
import "shared:pg"

// Attachment statements (protocol 26, migration 14, attachments plan F1). The router
// orchestrates, the database decides, and the storage worker (storage.odin) writes: no file
// byte ever reaches PostgreSQL. Each client action is one statement whose checks and change
// cannot be separated by a concurrent change.

// The room permissions an upload to a room needs (D11), as a mask: the requester's set
// (DATABASE_ROOM_PERMISSIONS_*) must contain all of them. F2 adds AttachFiles (D20) here, as
// "(" + DATABASE_ROOM_PERMISSION_SEND_MESSAGES_SQL + " | " +
// DATABASE_ROOM_PERMISSION_ATTACH_FILES_SQL + ")", and nothing else in the statement changes.
DATABASE_ATTACHMENT_ROOM_PERMISSIONS_REQUIRED_SQL :: DATABASE_ROOM_PERMISSION_SEND_MESSAGES_SQL

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
// size, quota, rate, capacity) and the new row's ID (NULL when nothing was stored).
DATABASE_ATTACHMENT_BEGIN_SQL ::
	"WITH room AS (SELECT r.encrypted, r.room_type FROM rooms r " +
	"WHERE r.id = $2::bigint AND $2::bigint > 0), " +
	"member AS (SELECT 1 FROM room_members WHERE room_id = $2::bigint AND user_id = $1::bigint), " +
	"may_send AS (SELECT ((" + DATABASE_ROOM_PERMISSIONS_OPEN_SQL + "$1" +
	DATABASE_ROOM_PERMISSIONS_ROOM_SQL + "$2" + DATABASE_ROOM_PERMISSIONS_CLOSE_SQL + " & " +
	DATABASE_ATTACHMENT_ROOM_PERMISSIONS_REQUIRED_SQL + ") = " +
	DATABASE_ATTACHMENT_ROOM_PERMISSIONS_REQUIRED_SQL + ") AS ok), " +
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
	"(NOT $2::bigint > 0 OR (SELECT ok FROM may_send)) AS send_ok, " +
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
	"WHERE member_ok AND send_ok AND chat_ok AND encryption_ok AND peer_ok AND meet_ok " +
	"AND size_ok AND quota_ok AND rate_ok AND capacity_ok " +
	"AND (($2::bigint > 0) <> ($3::bigint > 0)) RETURNING id) " +
	"SELECT c.member_ok, c.send_ok, c.chat_ok, c.encryption_ok, c.peer_ok, c.meet_ok, " +
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

// May $2 download blob $1? F1 (no message binds a blob yet): only the owner, and only a Ready or
// Bound blob. F2 replaces this statement with D10's check (room membership and From join, or a
// direct message's sender or recipient, sharing the history statements' predicate) and keeps
// the owner's right to its own unbound blob. One row: the stored size and the hash as hex.
DATABASE_ATTACHMENT_DOWNLOAD_CHECK_SQL ::
	"SELECT size::text, encode(sha256, 'hex') FROM attachments " +
	"WHERE blob_id = decode($1::text, 'hex') AND owner_user_id = $2::bigint AND state IN (1, 2)"

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

// Most rows one sweep pass deletes; the router runs another pass when a pass was full.
ATTACHMENT_SWEEP_BATCH :: 500

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
			attachment.outcome = .Applied
			attachment.size = databaseAttachmentGetU64(result, 0, 0)
			shaText := databaseGetText(result, 0, 1)
			defer delete(shaText)
			_ = common.decodeHexIntoBuffer(shaText, attachment.sha256[:])
		}
		return databaseSuccess(attachment)
	case .Sweep, .Known:
		query: cstring = DATABASE_ATTACHMENT_KNOWN_SQL
		params := make([dynamic]cstring, 0, 3)
		defer delete(params)
		if request.action == .Sweep {
			query = DATABASE_ATTACHMENT_SWEEP_SQL
			append(
				&params,
				databaseIntParam(request.pendingHours),
				databaseIntParam(request.limit > 0 ? request.limit : ATTACHMENT_SWEEP_BATCH),
			)
		}
		append(&params, databaseAttachmentHexList(request.blobIds[:]))
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
