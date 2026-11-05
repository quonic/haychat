package server

import "../common"
import "core:strings"
import "shared:pg"

// Read markers (migration 2). A mark-read is one statement per kind, like the other client
// actions: the access check (room membership, or an existing peer who is not the requester),
// the clamp to the newest message of the conversation, the forward-only upsert, and the unread
// count after it all read one snapshot, so a membership change or a new message cannot slip
// between them.
//
// Columns of both statements: whether the requester may mark this conversation, the new
// marker (NULL when it did not move), and the unread count after the move. The upsert's
// WHERE makes RETURNING empty for a marker that would not move forward, which is how the
// router knows to send nothing; GREATEST keeps the stored value from ever going back even if
// that WHERE were dropped. A clamped target of 0 (an empty conversation) stores nothing.
DATABASE_MARK_ROOM_READ_SQL ::
	"WITH target AS (SELECT rm.room_id, rm.user_id, LEAST($3::bigint, COALESCE((" +
	"SELECT max(cm.id) FROM chat_messages cm WHERE cm.room_id = rm.room_id), 0)) AS id " +
	"FROM room_members rm WHERE rm.room_id = $2::bigint AND rm.user_id = $1::bigint), " +
	"stored AS (INSERT INTO room_read_markers (user_id, room_id, last_read_message_id) " +
	"SELECT target.user_id, target.room_id, target.id FROM target WHERE target.id > 0 " +
	"ON CONFLICT (user_id, room_id) DO UPDATE SET last_read_message_id = GREATEST(" +
	"room_read_markers.last_read_message_id, EXCLUDED.last_read_message_id), " +
	"updated_at = CURRENT_TIMESTAMP " +
	"WHERE EXCLUDED.last_read_message_id > room_read_markers.last_read_message_id " +
	"RETURNING last_read_message_id) " +
	"SELECT EXISTS (SELECT 1 FROM target), s.last_read_message_id::text, (" +
	"SELECT count(*) FROM (SELECT 1 FROM chat_messages cm WHERE cm.room_id = $2::bigint " +
	"AND cm.id > s.last_read_message_id AND cm.sender_user_id <> $1::bigint " +
	"LIMIT $4::bigint) capped)::text " +
	"FROM (SELECT 1) AS one LEFT JOIN stored s ON true"

// The conversation's newest message is the larger of the two directions' newest, each read
// from its own index.
DATABASE_MARK_DIRECT_READ_SQL ::
	"WITH target AS (SELECT p.id AS peer_id, LEAST($3::bigint, COALESCE(GREATEST(" +
	"(SELECT max(d.id) FROM direct_messages d " +
	"WHERE d.sender_user_id = $1::bigint AND d.recipient_user_id = p.id), " +
	"(SELECT max(d.id) FROM direct_messages d " +
	"WHERE d.sender_user_id = p.id AND d.recipient_user_id = $1::bigint)), 0)) AS id " +
	"FROM users p WHERE p.id = $2::bigint AND p.id <> $1::bigint), " +
	"stored AS (INSERT INTO direct_read_markers (user_id, peer_user_id, last_read_message_id) " +
	"SELECT $1::bigint, target.peer_id, target.id FROM target WHERE target.id > 0 " +
	"ON CONFLICT (user_id, peer_user_id) DO UPDATE SET last_read_message_id = GREATEST(" +
	"direct_read_markers.last_read_message_id, EXCLUDED.last_read_message_id), " +
	"updated_at = CURRENT_TIMESTAMP " +
	"WHERE EXCLUDED.last_read_message_id > direct_read_markers.last_read_message_id " +
	"RETURNING last_read_message_id) " +
	"SELECT EXISTS (SELECT 1 FROM target), s.last_read_message_id::text, (" +
	"SELECT count(*) FROM (SELECT 1 FROM direct_messages d " +
	"WHERE d.sender_user_id = $2::bigint AND d.recipient_user_id = $1::bigint " +
	"AND d.id > s.last_read_message_id LIMIT $4::bigint) capped)::text " +
	"FROM (SELECT 1) AS one LEFT JOIN stored s ON true"

databaseExecuteMarkRead :: proc(
	conn: pg.Conn,
	request: common.DatabaseMarkReadRequest,
) -> common.DatabaseQueryResponse {
	query: cstring
	switch request.kind {
	case .Room:
		query = DATABASE_MARK_ROOM_READ_SQL
	case .Direct:
		query = DATABASE_MARK_DIRECT_READ_SQL
	case:
		return databaseErrorResponse(strings.clone("unknown read marker kind"))
	}
	userIDParam := databaseIntParam(request.userId)
	defer delete(userIDParam)
	conversationIDParam := databaseIntParam(request.conversationId)
	defer delete(conversationIDParam)
	messageIDParam := databaseIntParam(request.messageId)
	defer delete(messageIDParam)
	capParam := databaseIntParam(common.UNREAD_COUNT_CAP)
	defer delete(capParam)
	params := [?][^]byte {
		transmute([^]byte)userIDParam,
		transmute([^]byte)conversationIDParam,
		transmute([^]byte)messageIDParam,
		transmute([^]byte)capParam,
	}
	result := databaseExecParams(conn, query, params[:])
	if result == nil {
		return databaseConnectionError(conn)
	}
	defer pg.clear(result)
	if pg.result_status(result) != .Tuples_OK || pg.n_tuples(result) != 1 {
		return databaseResultError(&result)
	}

	marked := common.DatabaseMarkReadResult {
		allowed = databaseGetBool(result, 0, 0),
	}
	if lastRead, moved := databaseGetInt(result, 0, 1); marked.allowed && moved {
		marked.changed = true
		marked.lastReadMessageId = lastRead
		marked.unreadCount, _ = databaseGetInt(result, 0, 2)
	}
	return databaseSuccess(marked)
}
