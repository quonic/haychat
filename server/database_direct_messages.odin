package server

import "../common"
import "core:strings"
import "shared:pg"

// Direct message statements. Like the room statements, each client action is one SQL
// statement, so a check (does the recipient exist?) and the action it guards cannot race.

// Checks that the recipient exists and is not the sender, stores the message only then, and
// reads both nicknames from the same snapshot. It always returns exactly one row; the first
// column is false, and nothing was stored, when the recipient is refused.
DATABASE_POST_DIRECT_MESSAGE_SQL ::
	"WITH recipient AS (SELECT id, nickname FROM users " +
	"WHERE id = $2::bigint AND id <> $1::bigint), " +
	"stored AS (INSERT INTO direct_messages (sender_user_id, recipient_user_id, content) " +
	"SELECT $1::bigint, recipient.id, $3::text FROM recipient RETURNING id, created_at) " +
	"SELECT EXISTS (SELECT 1 FROM recipient), s.id::text, s.created_at::text, " +
	"COALESCE((SELECT nickname FROM users WHERE id = $1::bigint), ''), " +
	"COALESCE((SELECT nickname FROM recipient), '') " +
	"FROM (SELECT 1) AS one LEFT JOIN stored s ON true"

// Returns the peer-exists flag on every row, with message columns NULL when the peer does
// not exist or the page is empty. Messages in both directions between $1 and $2 form one
// conversation. The caller passes limit + 1 as $4 to detect older messages.
DATABASE_GET_DIRECT_HISTORY_SQL ::
	"WITH peer AS (SELECT EXISTS (SELECT 1 FROM users WHERE id = $2::bigint) AS ok) " +
	"SELECT p.ok, d.id::text, d.sender_user_id::text, d.recipient_user_id::text, " +
	"d.created_at::text, d.content, d.sender_nickname, d.recipient_nickname " +
	"FROM peer p LEFT JOIN LATERAL (" +
	"SELECT dm.id, dm.sender_user_id, dm.recipient_user_id, dm.created_at, dm.content, " +
	"su.nickname AS sender_nickname, ru.nickname AS recipient_nickname " +
	"FROM direct_messages dm " +
	"JOIN users su ON su.id = dm.sender_user_id " +
	"JOIN users ru ON ru.id = dm.recipient_user_id " +
	"WHERE p.ok AND (" +
	"(dm.sender_user_id = $1::bigint AND dm.recipient_user_id = $2::bigint) OR " +
	"(dm.sender_user_id = $2::bigint AND dm.recipient_user_id = $1::bigint)) " +
	"AND ($3::bigint = 0 OR dm.id < $3::bigint) " +
	"ORDER BY dm.id DESC LIMIT $4::bigint) d ON true ORDER BY d.id DESC"

// The latest message per peer with the requester's read state: DISTINCT ON keeps the highest
// message ID of each peer, the inner query keeps the $2 newest conversations, and only those
// are counted. Unread is every message from the peer above the marker, or every message from
// the peer without one (migration 2), counted on direct_messages_by_sender_and_recipient and
// capped at common.UNREAD_COUNT_CAP ($3).
DATABASE_LIST_DIRECT_CONVERSATIONS_SQL ::
	"SELECT c.peer_id::text, u.nickname, c.id::text, c.sender_user_id::text, " +
	"c.created_at::text, c.content, COALESCE(m.last_read_message_id, 0)::text, " +
	"unread.n::text FROM (" +
	"SELECT * FROM (" +
	"SELECT DISTINCT ON (peer_id) peer_id, id, sender_user_id, created_at, content FROM (" +
	"SELECT CASE WHEN sender_user_id = $1::bigint THEN recipient_user_id " +
	"ELSE sender_user_id END AS peer_id, id, sender_user_id, created_at, content " +
	"FROM direct_messages " +
	"WHERE sender_user_id = $1::bigint OR recipient_user_id = $1::bigint) mine " +
	"ORDER BY peer_id, id DESC) latest ORDER BY id DESC LIMIT $2::bigint) c " +
	"JOIN users u ON u.id = c.peer_id " +
	"LEFT JOIN direct_read_markers m ON m.user_id = $1::bigint AND m.peer_user_id = c.peer_id " +
	"CROSS JOIN LATERAL (SELECT count(*) AS n FROM (" +
	"SELECT 1 FROM direct_messages d WHERE d.sender_user_id = c.peer_id " +
	"AND d.recipient_user_id = $1::bigint " +
	"AND d.id > COALESCE(m.last_read_message_id, 0) LIMIT $3::bigint) capped) unread " +
	"ORDER BY c.id DESC"

// Every account, the requester included. Online flags are not stored; the router adds them.
DATABASE_LIST_USERS_SQL ::
	"SELECT u.id::text, u.nickname, EXISTS (SELECT 1 FROM user_server_roles usr " +
	"JOIN server_roles sr ON sr.id = usr.role_id WHERE usr.user_id = u.id " +
	"AND sr.name = 'admin')::text, (u.banned_at IS NOT NULL)::text, " +
	"COALESCE(encode(u.public_key, 'hex'), ''), " +
	"(u.public_key IS NOT NULL AND EXISTS (SELECT 1 FROM user_encryption_keys k " +
	"WHERE k.user_id = u.id))::text FROM users u " +
	"ORDER BY lower(u.nickname), u.id"

databaseExecutePostDirectMessage :: proc(
	conn: pg.Conn,
	request: common.DatabasePostDirectMessageRequest,
) -> common.DatabaseQueryResponse {
	senderIDParam := databaseIntParam(request.senderId)
	defer delete(senderIDParam)
	recipientIDParam := databaseIntParam(request.recipientId)
	defer delete(recipientIDParam)
	contentCString, _ := strings.clone_to_cstring(request.content)
	defer delete(contentCString)
	params := [?][^]byte {
		transmute([^]byte)senderIDParam,
		transmute([^]byte)recipientIDParam,
		transmute([^]byte)contentCString,
	}
	result := databaseExecParams(conn, DATABASE_POST_DIRECT_MESSAGE_SQL, params[:])
	if result == nil {
		return databaseConnectionError(conn)
	}
	defer pg.clear(result)
	if pg.result_status(result) != .Tuples_OK || pg.n_tuples(result) != 1 {
		return databaseResultError(&result)
	}

	if !databaseGetBool(result, 0, 0) {
		return databaseSuccess(common.DatabasePostDirectMessageResult{recipientExists = false})
	}
	messageID, messageIDOK := databaseGetInt(result, 0, 1)
	if !messageIDOK {
		return databaseErrorResponse(strings.clone("database returned invalid message ID"))
	}
	return databaseSuccess(
		common.DatabasePostDirectMessageResult {
			recipientExists = true,
			storedMessage = {
				id = messageID,
				senderId = request.senderId,
				senderNickname = databaseGetText(result, 0, 3),
				recipientId = request.recipientId,
				recipientNickname = databaseGetText(result, 0, 4),
				timestamp = databaseGetText(result, 0, 2),
				content = strings.clone(request.content),
			},
		},
	)
}

databaseExecuteGetDirectHistory :: proc(
	conn: pg.Conn,
	request: common.DatabaseDirectHistoryRequest,
) -> common.DatabaseQueryResponse {
	limit := request.limit
	if limit < 1 || limit > common.HISTORY_PAGE_MAX_MESSAGES {
		limit = common.HISTORY_PAGE_MAX_MESSAGES
	}
	userIDParam := databaseIntParam(request.userId)
	defer delete(userIDParam)
	peerUserIDParam := databaseIntParam(request.peerUserId)
	defer delete(peerUserIDParam)
	beforeMessageIDParam := databaseIntParam(request.beforeMessageID)
	defer delete(beforeMessageIDParam)
	limitParam := databaseIntParam(limit + 1)
	defer delete(limitParam)
	params := [?][^]byte {
		transmute([^]byte)userIDParam,
		transmute([^]byte)peerUserIDParam,
		transmute([^]byte)beforeMessageIDParam,
		transmute([^]byte)limitParam,
	}
	result := databaseExecParams(conn, DATABASE_GET_DIRECT_HISTORY_SQL, params[:])
	if result == nil {
		return databaseConnectionError(conn)
	}
	defer pg.clear(result)
	if pg.result_status(result) != .Tuples_OK || pg.n_tuples(result) < 1 {
		return databaseResultError(&result)
	}
	if !databaseGetBool(result, 0, 0) {
		return databaseSuccess(common.DatabaseDirectHistoryResult{peerExists = false})
	}

	// Rows arrive newest first; drop the probe row and return the page oldest first.
	rowCount := 0
	for row in 0 ..< pg.n_tuples(result) {
		if !pg.get_is_null(result, row, 1) {
			rowCount += 1
		}
	}
	messageCount := min(rowCount, limit)
	messages := make([dynamic]common.StoredDirectMessage, 0, messageCount)
	for offset in 0 ..< messageCount {
		row := i32(messageCount - offset - 1)
		messageID, messageIDOK := databaseGetInt(result, row, 1)
		senderID, senderIDOK := databaseGetInt(result, row, 2)
		recipientID, recipientIDOK := databaseGetInt(result, row, 3)
		if !messageIDOK || !senderIDOK || !recipientIDOK {
			continue
		}
		append(
			&messages,
			common.StoredDirectMessage {
				id = messageID,
				senderId = senderID,
				senderNickname = databaseGetText(result, row, 6),
				recipientId = recipientID,
				recipientNickname = databaseGetText(result, row, 7),
				timestamp = databaseGetText(result, row, 4),
				content = databaseGetText(result, row, 5),
			},
		)
	}
	return databaseSuccess(
		common.DatabaseDirectHistoryResult {
			peerExists = true,
			messages = messages,
			hasOlder = rowCount > limit,
		},
	)
}

databaseExecuteListDirectConversations :: proc(
	conn: pg.Conn,
	request: common.DatabaseDirectConversationListRequest,
) -> common.DatabaseQueryResponse {
	userIDParam := databaseIntParam(request.userId)
	defer delete(userIDParam)
	limitParam := databaseIntParam(common.DIRECT_CONVERSATIONS_MAX)
	defer delete(limitParam)
	capParam := databaseIntParam(common.UNREAD_COUNT_CAP)
	defer delete(capParam)
	params := [?][^]byte {
		transmute([^]byte)userIDParam,
		transmute([^]byte)limitParam,
		transmute([^]byte)capParam,
	}
	result := databaseExecParams(conn, DATABASE_LIST_DIRECT_CONVERSATIONS_SQL, params[:])
	if result == nil {
		return databaseConnectionError(conn)
	}
	defer pg.clear(result)
	if pg.result_status(result) != .Tuples_OK {
		return databaseResultError(&result)
	}

	conversations := make([dynamic]common.DirectConversationSummary, 0, pg.n_tuples(result))
	for row in 0 ..< pg.n_tuples(result) {
		peerUserID, peerUserIDOK := databaseGetInt(result, row, 0)
		messageID, messageIDOK := databaseGetInt(result, row, 2)
		senderID, senderIDOK := databaseGetInt(result, row, 3)
		if !peerUserIDOK || !messageIDOK || !senderIDOK {
			continue
		}
		lastRead, _ := databaseGetInt(result, row, 6)
		unread, _ := databaseGetInt(result, row, 7)
		append(
			&conversations,
			common.DirectConversationSummary {
				peerUserId = peerUserID,
				peerNickname = databaseGetText(result, row, 1),
				lastMessageID = messageID,
				lastSenderId = senderID,
				lastTimestamp = databaseGetText(result, row, 4),
				lastContent = databaseGetText(result, row, 5),
				lastReadMessageId = lastRead,
				unreadCount = unread,
			},
		)
	}
	return databaseSuccess(
		common.DatabaseDirectConversationListResult{conversations = conversations},
	)
}

databaseExecuteListUsers :: proc(conn: pg.Conn) -> common.DatabaseQueryResponse {
	result := databaseExecParams(conn, DATABASE_LIST_USERS_SQL, nil)
	if result == nil {
		return databaseConnectionError(conn)
	}
	defer pg.clear(result)
	if pg.result_status(result) != .Tuples_OK {
		return databaseResultError(&result)
	}

	users := make([dynamic]common.UserSummary, 0, pg.n_tuples(result))
	for row in 0 ..< pg.n_tuples(result) {
		userID, userIDOK := databaseGetInt(result, row, 0)
		if !userIDOK {
			continue
		}
		append(
			&users,
			common.UserSummary {
				id = userID,
				nickname = databaseGetText(result, row, 1),
				isAdmin = databaseGetBool(result, row, 2),
				isBanned = databaseGetBool(result, row, 3),
				identityPublicKey = databaseGetIdentityPublicKey(result, row, 4),
				hasEncryptionKey = databaseGetBool(result, row, 5),
			},
		)
	}
	return databaseSuccess(common.DatabaseUserDirectoryResult{users = users})
}
