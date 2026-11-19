package server

import "../common"
import "core:strings"
import "shared:pg"

// Direct message statements. Like the room statements, each client action is one SQL
// statement, so a check (does the recipient exist?) and the action it guards cannot race.

// Checks that the recipient exists and is not the sender, stores the message only then, and
// reads both nicknames from the same snapshot. $1 sender, $2 recipient, $3 content ('' for an
// encrypted message), $4 client message ID, $5 signature, $6 envelope (hex, '' for none), $7
// the recipient's identity key the envelope was verified against (hex; '' for a plaintext
// message), so an envelope is stored only while the recipient still has that key. A client
// message ID the sender used before stores nothing (direct_messages_sender_client_message_id).
// It always returns exactly one row: whether the recipient was accepted, then the stored ID
// and time (NULL when nothing was stored), both nicknames, and (protocol 25, D17) whether the
// two accounts may exchange messages: neither is restricted, they share a room, or one is an
// admin (database_registration.odin). Nothing is stored when they may not.
DATABASE_POST_DIRECT_MESSAGE_SQL ::
	"WITH recipient AS (SELECT id, nickname FROM users " +
	"WHERE id = $2::bigint AND id <> $1::bigint " +
	"AND ($7::text = '' OR public_key = decode($7::text, 'hex'))), " +
	"allowed AS (SELECT " + DATABASE_USERS_MAY_MEET_OPEN_SQL + "$1" +
	DATABASE_USERS_MAY_MEET_MIDDLE_SQL + "$2" + DATABASE_USERS_MAY_MEET_CLOSE_SQL + " AS ok), " +
	"stored AS (INSERT INTO direct_messages (sender_user_id, recipient_user_id, content, " +
	"client_message_id, signature, envelope) " +
	"SELECT $1::bigint, recipient.id, $3::text, decode(NULLIF($4::text, ''), 'hex'), " +
	"decode(NULLIF($5::text, ''), 'hex'), decode(NULLIF($6::text, ''), 'hex') FROM recipient " +
	"WHERE (SELECT ok FROM allowed) " +
	"ON CONFLICT (sender_user_id, client_message_id) WHERE client_message_id IS NOT NULL " +
	"DO NOTHING RETURNING id, created_at) " +
	"SELECT EXISTS (SELECT 1 FROM recipient), s.id::text, s.created_at::text, " +
	"COALESCE((SELECT nickname FROM users WHERE id = $1::bigint), ''), " +
	"COALESCE((SELECT nickname FROM recipient), ''), (SELECT ok FROM allowed)::text " +
	"FROM (SELECT 1) AS one LEFT JOIN stored s ON true"

// The identity key of the recipient $2 of a message from $1, as hex ('' for an account without
// one); no row for an unknown account or the sender itself. An envelope is checked against it
// before DATABASE_POST_DIRECT_MESSAGE_SQL stores it under the same key.
DATABASE_DIRECT_MESSAGE_RECIPIENT_KEY_SQL ::
	"SELECT COALESCE(encode(public_key, 'hex'), '') FROM users " +
	"WHERE id = $2::bigint AND id <> $1::bigint"

// Returns the peer-exists flag on every row, with message columns NULL when the peer does
// not exist or the page is empty. Messages in both directions between $1 and $2 form one
// conversation. The caller passes limit + 1 as $4 to detect older messages. The protocol 17
// columns come as hex, '' when NULL.
//
// Protocol 25 (D17): a peer the requester may not meet (a restricted account on either side,
// no shared room, no admin) counts as missing unless the two already have a conversation, whose
// history stays readable after the last shared room is gone.
DATABASE_GET_DIRECT_HISTORY_SQL ::
	"WITH peer AS (SELECT (EXISTS (SELECT 1 FROM users WHERE id = $2::bigint) AND (" +
	DATABASE_USERS_MAY_MEET_OPEN_SQL + "$1" + DATABASE_USERS_MAY_MEET_MIDDLE_SQL + "$2" +
	DATABASE_USERS_MAY_MEET_CLOSE_SQL + " OR EXISTS (SELECT 1 FROM direct_messages h " +
	"WHERE (h.sender_user_id = $1::bigint AND h.recipient_user_id = $2::bigint) " +
	"OR (h.sender_user_id = $2::bigint AND h.recipient_user_id = $1::bigint)))) AS ok) " +
	"SELECT p.ok, d.id::text, d.sender_user_id::text, d.recipient_user_id::text, " +
	"d.created_at::text, d.content, d.sender_nickname, d.recipient_nickname, " +
	"COALESCE(encode(d.client_message_id, 'hex'), ''), COALESCE(encode(d.envelope, 'hex'), ''), " +
	"COALESCE(encode(d.signature, 'hex'), '') " +
	"FROM peer p LEFT JOIN LATERAL (" +
	"SELECT dm.id, dm.sender_user_id, dm.recipient_user_id, dm.created_at, dm.content, " +
	"dm.client_message_id, dm.envelope, dm.signature, " +
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
	"unread.n::text, COALESCE(encode(c.client_message_id, 'hex'), ''), " +
	"COALESCE(encode(c.envelope, 'hex'), ''), COALESCE(encode(c.signature, 'hex'), '') FROM (" +
	"SELECT * FROM (" +
	"SELECT DISTINCT ON (peer_id) peer_id, id, sender_user_id, created_at, content, " +
	"client_message_id, envelope, signature FROM (" +
	"SELECT CASE WHEN sender_user_id = $1::bigint THEN recipient_user_id " +
	"ELSE sender_user_id END AS peer_id, id, sender_user_id, created_at, content, " +
	"client_message_id, envelope, signature " +
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

// Every account the requester ($1) may see, the requester included. Online flags are not
// stored; the router adds them.
//
// Protocol 25 (D17): admins and holders of ApproveRegistrations see every account; anyone else
// sees an account unless one of the two is restricted, and then only when they share a room or
// the account is an admin. The eighth column is the account's restriction.
DATABASE_LIST_USERS_SQL ::
	"WITH viewer AS (SELECT u.id, u.restricted, ((" + DATABASE_ACTOR_PERMISSIONS_SQL + " & " +
	DATABASE_PERMISSION_APPROVE_REGISTRATIONS_SQL + ") <> 0) AS sees_all " +
	"FROM users u WHERE u.id = $1::bigint) " +
	"SELECT u.id::text, u.nickname, EXISTS (SELECT 1 FROM user_server_roles usr " +
	"JOIN server_roles sr ON sr.id = usr.role_id WHERE usr.user_id = u.id " +
	"AND sr.name = 'admin')::text, (u.banned_at IS NOT NULL)::text, " +
	"COALESCE(encode(u.public_key, 'hex'), ''), " +
	"(u.public_key IS NOT NULL AND EXISTS (SELECT 1 FROM user_encryption_keys k " +
	"WHERE k.user_id = u.id))::text, " +
	// Protocol 23: the account's role IDs, comma separated.
	"COALESCE((SELECT string_agg(usr.role_id::text, ',' ORDER BY usr.role_id) " +
	"FROM user_server_roles usr WHERE usr.user_id = u.id), ''), u.restricted::text " +
	"FROM users u CROSS JOIN viewer v WHERE u.id = v.id OR v.sees_all " +
	"OR (NOT v.restricted AND NOT u.restricted) " +
	"OR EXISTS (SELECT 1 FROM room_members ma JOIN room_members mb ON mb.room_id = ma.room_id " +
	"WHERE ma.user_id = v.id AND mb.user_id = u.id) " +
	"OR EXISTS (SELECT 1 FROM user_server_roles ah JOIN server_roles ar ON ar.id = ah.role_id " +
	"WHERE ah.user_id = u.id AND ar.builtin) " +
	"ORDER BY lower(u.nickname), u.id"

databaseExecutePostDirectMessage :: proc(
	conn: pg.Conn,
	request: common.DatabasePostDirectMessageRequest,
) -> common.DatabaseQueryResponse {
	senderIDParam := databaseIntParam(request.senderId)
	defer delete(senderIDParam)
	recipientIDParam := databaseIntParam(request.recipientId)
	defer delete(recipientIDParam)

	// An envelope is checked against the recipient's identity key first, and stored only under
	// that key (the insert's $7).
	recipientKeyHex := ""
	if len(request.envelope) > 0 {
		recipientKey, outcome, response, failed := databaseDirectMessageRecipientKey(
			conn,
			senderIDParam,
			recipientIDParam,
		)
		if failed {
			return response
		}
		if outcome == .Stored {
			outcome = databaseCheckSealedDirectMessage(request, recipientKey)
		}
		if outcome != .Stored {
			return databaseSuccess(common.DatabasePostDirectMessageResult{outcome = outcome})
		}
		recipientKeyHex = common.encodeBytesToHex(recipientKey[:])
	}
	defer delete(recipientKeyHex)

	contentCString, _ := strings.clone_to_cstring(request.content)
	defer delete(contentCString)
	clientMessageID := request.clientMessageId
	clientMessageIDHex := ""
	if common.clientMessageIDIsSet(clientMessageID) {
		clientMessageIDHex = common.encodeBytesToHex(clientMessageID[:])
	}
	defer delete(clientMessageIDHex)
	signature := request.signature
	signatureHex := ""
	if len(request.envelope) == 0 && signature != {} {
		signatureHex = common.encodeBytesToHex(signature[:])
	}
	defer delete(signatureHex)
	envelopeHex := common.encodeBytesToHex(request.envelope)
	defer delete(envelopeHex)
	clientMessageIDParam, _ := strings.clone_to_cstring(clientMessageIDHex)
	defer delete(clientMessageIDParam)
	signatureParam, _ := strings.clone_to_cstring(signatureHex)
	defer delete(signatureParam)
	envelopeParam, _ := strings.clone_to_cstring(envelopeHex)
	defer delete(envelopeParam)
	recipientKeyParam, _ := strings.clone_to_cstring(recipientKeyHex)
	defer delete(recipientKeyParam)
	params := [?][^]byte {
		transmute([^]byte)senderIDParam,
		transmute([^]byte)recipientIDParam,
		transmute([^]byte)contentCString,
		transmute([^]byte)clientMessageIDParam,
		transmute([^]byte)signatureParam,
		transmute([^]byte)envelopeParam,
		transmute([^]byte)recipientKeyParam,
	}
	result := databaseExecParams(conn, DATABASE_POST_DIRECT_MESSAGE_SQL, params[:])
	if result == nil {
		return databaseConnectionError(conn)
	}
	defer pg.clear(result)
	if pg.result_status(result) != .Tuples_OK || pg.n_tuples(result) != 1 {
		return databaseResultError(&result)
	}

	if databaseGetBool(result, 0, 0) && !databaseGetBool(result, 0, 5) {
		return databaseSuccess(common.DatabasePostDirectMessageResult{outcome = .Restricted})
	}
	if !databaseGetBool(result, 0, 0) {
		// The recipient checked above lost the key the envelope names in between.
		outcome := common.DirectMessagePostOutcome.UnknownRecipient
		if len(request.envelope) > 0 {
			outcome = .InvalidEnvelope
		}
		return databaseSuccess(common.DatabasePostDirectMessageResult{outcome = outcome})
	}
	if pg.get_is_null(result, 0, 1) {
		return databaseSuccess(common.DatabasePostDirectMessageResult{outcome = .Duplicate})
	}
	messageID, messageIDOK := databaseGetInt(result, 0, 1)
	if !messageIDOK {
		return databaseErrorResponse(strings.clone("database returned invalid message ID"))
	}
	envelope: []u8
	if len(request.envelope) > 0 {
		envelope = make([]u8, len(request.envelope))
		copy(envelope, request.envelope)
	}
	return databaseSuccess(
		common.DatabasePostDirectMessageResult {
			outcome = .Stored,
			storedMessage = {
				id = messageID,
				senderId = request.senderId,
				senderNickname = databaseGetText(result, 0, 3),
				recipientId = request.recipientId,
				recipientNickname = databaseGetText(result, 0, 4),
				timestamp = databaseGetText(result, 0, 2),
				content = strings.clone(request.content),
				clientMessageId = request.clientMessageId,
				envelope = envelope,
				signature = len(request.envelope) == 0 ? request.signature : {},
			},
		},
	)
}

// Reads the identity key of the recipient. outcome is UnknownRecipient for no such account (or
// the sender itself) and InvalidEnvelope for an account without a valid identity key, which no
// envelope can name; failed means the query failed and response says why.
@(private = "file")
databaseDirectMessageRecipientKey :: proc(
	conn: pg.Conn,
	senderIDParam, recipientIDParam: cstring,
) -> (
	key: common.IdentityPublicKeyBytes,
	outcome: common.DirectMessagePostOutcome,
	response: common.DatabaseQueryResponse,
	failed: bool,
) {
	params := [?][^]byte{transmute([^]byte)senderIDParam, transmute([^]byte)recipientIDParam}
	result := databaseExecParams(conn, DATABASE_DIRECT_MESSAGE_RECIPIENT_KEY_SQL, params[:])
	if result == nil {
		return {}, .Stored, databaseConnectionError(conn), true
	}
	defer pg.clear(result)
	if pg.result_status(result) != .Tuples_OK {
		return {}, .Stored, databaseResultError(&result), true
	}
	if pg.n_tuples(result) == 0 {
		return {}, .UnknownRecipient, {}, false
	}
	if !databaseGetHexBytes(result, 0, 0, key[:]) || key == {} {
		return {}, .InvalidEnvelope, {}, false
	}
	return key, .Stored, {}, false
}

// The server's check of an envelope (design 4.5): every AAD field is known here, the sender's
// identity key is the session's and the recipient's is the database's, so a valid envelope is
// one the sender sealed for exactly this conversation on this server. Pure, for tests.
databaseCheckSealedDirectMessage :: proc(
	request: common.DatabasePostDirectMessageRequest,
	recipientIdentityPublicKey: common.IdentityPublicKeyBytes,
) -> common.DirectMessagePostOutcome {
	if len(request.envelope) > common.SEALED_ENVELOPE_MAX_BYTES ||
	   !common.clientMessageIDIsSet(request.clientMessageId) ||
	   recipientIdentityPublicKey == {} {
		return .InvalidEnvelope
	}
	verifyErr := common.verifyDirectMessageEnvelope(
		request.envelope,
		common.DirectMessageAADFields {
			serverIdentityPublicKey = request.serverIdentityPublicKey,
			senderUserID = request.senderId,
			recipientUserID = request.recipientId,
			senderIdentityPublicKey = request.senderIdentityPublicKey,
			recipientIdentityPublicKey = recipientIdentityPublicKey,
			clientMessageID = request.clientMessageId,
		},
	)
	return verifyErr == .None ? .Stored : .InvalidEnvelope
}

// The protocol 17 columns of a history or conversation row, starting at first: client message
// ID, envelope (owned, nil when empty) and signature, each hex ('' for NULL). A malformed value
// reads as absent.
@(private = "file")
databaseGetDirectMessageSecurity :: proc(
	result: pg.Result,
	row: i32,
	first: i32,
) -> (
	clientMessageID: common.ClientMessageID,
	envelope: []u8,
	signature: common.SignatureBytes,
) {
	if !databaseGetHexBytes(result, row, first, clientMessageID[:]) {
		clientMessageID = {}
	}
	if !databaseGetHexBytes(result, row, first + 2, signature[:]) {
		signature = {}
	}
	envelopeHex := databaseGetText(result, row, first + 1)
	defer delete(envelopeHex)
	if len(envelopeHex) > 0 && len(envelopeHex) % 2 == 0 {
		envelope = make([]u8, len(envelopeHex) / 2)
		if !common.decodeHexIntoBuffer(envelopeHex, envelope) {
			delete(envelope)
			envelope = nil
		}
	}
	return
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
		clientMessageID, envelope, signature := databaseGetDirectMessageSecurity(result, row, 8)
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
				clientMessageId = clientMessageID,
				envelope = envelope,
				signature = signature,
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
		clientMessageID, envelope, signature := databaseGetDirectMessageSecurity(result, row, 8)
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
				lastClientMessageId = clientMessageID,
				lastEnvelope = envelope,
				lastSignature = signature,
			},
		)
	}
	return databaseSuccess(
		common.DatabaseDirectConversationListResult{conversations = conversations},
	)
}

databaseExecuteListUsers :: proc(
	conn: pg.Conn,
	request: common.DatabaseUserDirectoryRequest,
) -> common.DatabaseQueryResponse {
	viewerParam := databaseIntParam(request.viewerUserId)
	defer delete(viewerParam)
	params := [?][^]byte{transmute([^]byte)viewerParam}
	result := databaseExecParams(conn, DATABASE_LIST_USERS_SQL, params[:])
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
		roleIDs := databaseGetText(result, row, 6)
		defer delete(roleIDs)
		append(
			&users,
			common.UserSummary {
				roleIds = databaseParseIDList(roleIDs),
				id = userID,
				nickname = databaseGetText(result, row, 1),
				isAdmin = databaseGetBool(result, row, 2),
				isBanned = databaseGetBool(result, row, 3),
				identityPublicKey = databaseGetIdentityPublicKey(result, row, 4),
				hasEncryptionKey = databaseGetBool(result, row, 5),
				isRestricted = databaseGetBool(result, row, 7),
			},
		)
	}
	return databaseSuccess(common.DatabaseUserDirectoryResult{users = users})
}
