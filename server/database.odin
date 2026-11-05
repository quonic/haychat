package server

import "../common"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import "shared:pg"

DATABASE_CONNECT_TIMEOUT_SECONDS :: 5

DatabaseConnectDBProc :: #type proc "cdecl" (conninfo: cstring) -> pg.Conn
DatabaseConnectionStatusProc :: #type proc "cdecl" (conn: pg.Conn) -> pg.Connection_Status
DatabaseConnectionErrorProc :: #type proc "cdecl" (conn: pg.Conn) -> cstring
DatabaseConnectionFinishProc :: #type proc "cdecl" (conn: pg.Conn)

// Binds a client identity key to a nickname. The key is the identity; the nickname is the
// account's current display name. One statement, so the checks and the write cannot race:
//
// - The key owns an account (`by_key`) under this nickname: resolve to it.
// - The key owns an account under another nickname: `renamed` renames it when no other
//   account holds the new nickname, and returns no row (a refused login) when one does.
// - The key owns no account: `inserted` creates one, or claims the nickname's keyless account.
//   A keyless account can be claimed only when it holds no server roles; privileged keyless
//   accounts (such as the seeded admin) can only be claimed by HAYCHAT_ADMIN_PUBLIC_KEY ($3).
//   A nickname bound to another key is refused.
//
// Rooms are open: an account created by this statement joins every existing room in the same
// statement, so it can chat as soon as it authenticates. `existing` reads the snapshot from
// before the write, so only a brand-new nickname joins; a rename, a returning account, or a
// claimed account keeps whatever membership it had. The membership insert reads from
// `inserted`, which is empty when the key already owns an account or the identity is not
// claimable, so a refused login joins nothing.
//
// The final select also reports whether the resolved account holds the `admin` server role,
// for ServerAuthSuccess.isAdmin. user_server_roles is not written here, so the statement's
// snapshot is current: a claimed seeded admin reads true, a brand-new account false.
//
// Columns: user ID, whether this was a rename, the nickname before the rename, and whether the
// account is an admin.
DATABASE_RESOLVE_USER_IDENTITY_SQL ::
	"WITH by_key AS (SELECT id, nickname FROM users WHERE public_key = decode($2, 'hex')), " +
	"existing AS (SELECT id FROM users WHERE nickname = $1), " +
	"renamed AS (" +
	"UPDATE users SET nickname = $1 FROM by_key " +
	"WHERE users.id = by_key.id AND by_key.nickname <> $1 " +
	"AND NOT EXISTS (SELECT 1 FROM existing) " +
	"RETURNING users.id, by_key.nickname::text AS previous_nickname), " +
	"inserted AS (" +
	"INSERT INTO users (nickname, public_key) " +
	"SELECT $1, decode($2, 'hex') WHERE NOT EXISTS (SELECT 1 FROM by_key) " +
	"ON CONFLICT (nickname) DO UPDATE SET public_key = EXCLUDED.public_key " +
	"WHERE users.public_key = EXCLUDED.public_key OR (users.public_key IS NULL AND (" +
	"NOT EXISTS (SELECT 1 FROM user_server_roles usr WHERE usr.user_id = users.id) " +
	"OR EXCLUDED.public_key = decode(NULLIF($3, ''), 'hex'))) " +
	"RETURNING id), " +
	"joined AS (" +
	"INSERT INTO room_members (room_id, user_id) " +
	"SELECT r.id, inserted.id FROM rooms r CROSS JOIN inserted " +
	"WHERE NOT EXISTS (SELECT 1 FROM existing) ON CONFLICT DO NOTHING), " +
	"resolved AS (" +
	"SELECT id, false AS is_rename, ''::text AS previous_nickname FROM by_key " +
	"WHERE nickname = $1 " +
	"UNION ALL SELECT id, true, previous_nickname FROM renamed " +
	"UNION ALL SELECT id, false, '' FROM inserted) " +
	"SELECT resolved.id::text, is_rename::text, previous_nickname, EXISTS (" +
	"SELECT 1 FROM user_server_roles usr JOIN server_roles sr ON sr.id = usr.role_id " +
	"WHERE usr.user_id = resolved.id AND sr.name = 'admin')::text FROM resolved"

// Creates the default room on a server that has none, so a fresh server is usable without
// loading a fixture. Rooms are open, so every existing account joins it. On an empty table
// the identity column hands out ID 1, which clients select first as common.GENERAL_ROOM_ID.
// Once any room exists this does nothing, so an admin who renamed or deleted #general keeps
// that choice. ON CONFLICT covers a second server racing the first on the same database.
DATABASE_ENSURE_DEFAULT_ROOM_SQL ::
	"WITH created_room AS (" +
	"INSERT INTO rooms (name, description) " +
	"SELECT 'general', 'General discussion' WHERE NOT EXISTS (SELECT 1 FROM rooms) " +
	"ON CONFLICT DO NOTHING RETURNING id), " +
	"all_members AS (" +
	"INSERT INTO room_members (room_id, user_id) " +
	"SELECT created_room.id, users.id FROM created_room CROSS JOIN users " +
	"ON CONFLICT DO NOTHING) " +
	"SELECT id::text FROM created_room"

// Runs DATABASE_ENSURE_DEFAULT_ROOM_SQL. Returns the created room's ID, or 0 when rooms
// already existed. The caller frees a non-empty error.
databaseEnsureDefaultRoom :: proc(conn: pg.Conn) -> (int, string) {
	result := pg.exec(conn, DATABASE_ENSURE_DEFAULT_ROOM_SQL)
	if result == nil {
		return 0, fmt.aprintf(
			"default room creation failed: %s",
			cloneCStringOrEmpty(pg.error_message(conn)),
		)
	}
	defer pg.clear(result)
	if pg.result_status(result) != .Tuples_OK {
		return 0, fmt.aprintf(
			"default room creation failed: %s",
			cloneCStringOrEmpty(pg.result_error_message(result)),
		)
	}
	if pg.n_tuples(result) == 0 {
		return 0, ""
	}
	roomID, roomIDOK := databaseGetInt(result, 0, 0)
	if !roomIDOK {
		return 0, strings.clone("default room creation returned an invalid room ID")
	}
	return roomID, ""
}

cloneCStringOrEmpty :: proc(value: cstring) -> string {
	if value == nil {
		return ""
	}
	text, err := strings.clone_from_cstring(value)
	if err != nil {
		return ""
	}
	return text
}

// Takes ownership of message, which must be heap allocated because the router frees it.
databaseErrorResponse :: proc(message: string) -> common.DatabaseQueryResponse {
	return common.DatabaseQueryResponse{success = false, message = message}
}

databaseConnectionError :: proc(conn: pg.Conn) -> common.DatabaseQueryResponse {
	return databaseErrorResponse(cloneCStringOrEmpty(pg.error_message(conn)))
}

databaseResultError :: proc(result: ^pg.Result) -> common.DatabaseQueryResponse {
	return databaseErrorResponse(cloneCStringOrEmpty(pg.result_error_message(result^)))
}

databaseSuccess :: proc(result: common.DatabaseQueryResult) -> common.DatabaseQueryResponse {
	return common.DatabaseQueryResponse{success = true, result = result}
}

// Formats an integer query parameter. The caller frees the result.
databaseIntParam :: proc(value: int) -> cstring {
	return fmt.caprintf("%d", value)
}

databaseExecParams :: proc(conn: pg.Conn, query: cstring, params: [][^]byte) -> pg.Result {
	return pg.exec_params(
		conn,
		query,
		i32(len(params)),
		nil,
		raw_data(params),
		nil,
		nil,
		.Text,
	)
}

databaseGetText :: proc(result: pg.Result, row: i32, column: i32) -> string {
	return cloneCStringOrEmpty(cstring(pg.get_value(result, row, column)))
}

databaseGetInt :: proc(result: pg.Result, row: i32, column: i32) -> (int, bool) {
	if pg.get_is_null(result, row, column) {
		return 0, false
	}
	text := databaseGetText(result, row, column)
	defer delete(text)
	value, ok := strconv.parse_int(text)
	return value, ok
}

databaseGetBool :: proc(result: pg.Result, row: i32, column: i32) -> bool {
	text := databaseGetText(result, row, column)
	defer delete(text)
	// libpq's text format renders booleans as "t"/"f"; a ::text cast yields "true"/"false".
	return text == "t" || text == "true"
}

// Parses a comma-separated list of IDs produced by string_agg.
databaseParseIDList :: proc(text: string) -> [dynamic]int {
	ids := make([dynamic]int)
	remaining := text
	for part in strings.split_iterator(&remaining, ",") {
		if id, ok := strconv.parse_int(part); ok {
			append(&ids, id)
		}
	}
	return ids
}

databaseExecuteUserIdentityResolution :: proc(
	conn: pg.Conn,
	request: common.DatabaseUserIdentityRequest,
) -> common.DatabaseQueryResponse {
	nicknameCString, _ := strings.clone_to_cstring(request.nickname)
	defer delete(nicknameCString)
	publicKeyHex := common.identityPublicKeyToHex(request.publicKey)
	defer delete(publicKeyHex)
	publicKeyHexCString, _ := strings.clone_to_cstring(publicKeyHex)
	defer delete(publicKeyHexCString)
	// An empty $3 means no admin key is configured, so privileged accounts stay unclaimable.
	adminPublicKeyHex: string
	if request.hasAdminPublicKey {
		adminPublicKeyHex = common.identityPublicKeyToHex(request.adminPublicKey)
	}
	defer if request.hasAdminPublicKey do delete(adminPublicKeyHex)
	adminPublicKeyHexCString, _ := strings.clone_to_cstring(adminPublicKeyHex)
	defer delete(adminPublicKeyHexCString)
	params := [?][^]byte {
		transmute([^]byte)nicknameCString,
		transmute([^]byte)publicKeyHexCString,
		transmute([^]byte)adminPublicKeyHexCString,
	}
	result := databaseExecParams(conn, DATABASE_RESOLVE_USER_IDENTITY_SQL, params[:])
	if result == nil {
		return databaseConnectionError(conn)
	}
	defer pg.clear(result)
	if pg.result_status(result) != .Tuples_OK {
		return databaseResultError(&result)
	}

	// No row means the nickname is bound to a different account or is not claimable.
	identity: common.DatabaseUserIdentityResult
	if pg.n_tuples(result) == 1 {
		identity.userId, _ = databaseGetInt(result, 0, 0)
		identity.renamed = databaseGetBool(result, 0, 1)
		if identity.renamed {
			identity.previousNickname = databaseGetText(result, 0, 2)
		}
		identity.isAdmin = databaseGetBool(result, 0, 3)
	}
	return databaseSuccess(identity)
}

// The requester's rooms with their read state. Unread follows the rules of migration 2
// (database_migrations.odin): messages from others above the marker, or, without a marker,
// created after the requester joined the room. Each branch walks one index range,
// chat_messages_by_room_id_and_id or chat_messages_by_room_id_and_created_at, and stops after
// common.UNREAD_COUNT_CAP rows ($2); the branch that does not apply is skipped by its one-time
// filter on the marker.
DATABASE_LIST_ROOMS_FOR_USER_SQL ::
	"SELECT r.id::text, r.name, r.description, " +
	"COALESCE(m.last_read_message_id, 0)::text, unread.n::text FROM rooms r " +
	"JOIN room_members rm ON rm.room_id = r.id AND rm.user_id = $1::bigint " +
	"LEFT JOIN room_read_markers m ON m.user_id = rm.user_id AND m.room_id = r.id " +
	"CROSS JOIN LATERAL (SELECT count(*) AS n FROM (" +
	"SELECT 1 FROM chat_messages cm WHERE m.user_id IS NOT NULL AND cm.room_id = r.id " +
	"AND cm.id > m.last_read_message_id AND cm.sender_user_id <> rm.user_id " +
	"UNION ALL " +
	"SELECT 1 FROM chat_messages cm WHERE m.user_id IS NULL AND cm.room_id = r.id " +
	"AND cm.created_at > rm.joined_at AND cm.sender_user_id <> rm.user_id " +
	"LIMIT $2::bigint) capped) unread " +
	"ORDER BY r.name"

databaseExecuteListRoomsForUser :: proc(
	conn: pg.Conn,
	request: common.DatabaseRoomListRequest,
) -> common.DatabaseQueryResponse {
	userIDParam := databaseIntParam(request.userId)
	defer delete(userIDParam)
	capParam := databaseIntParam(common.UNREAD_COUNT_CAP)
	defer delete(capParam)
	params := [?][^]byte{transmute([^]byte)userIDParam, transmute([^]byte)capParam}
	result := databaseExecParams(conn, DATABASE_LIST_ROOMS_FOR_USER_SQL, params[:])
	if result == nil {
		return databaseConnectionError(conn)
	}
	defer pg.clear(result)
	if pg.result_status(result) != .Tuples_OK {
		return databaseResultError(&result)
	}

	rooms := make([dynamic]common.RoomSummary)
	for row in 0 ..< pg.n_tuples(result) {
		roomID, roomIDOK := databaseGetInt(result, row, 0)
		if !roomIDOK {
			continue
		}
		lastRead, _ := databaseGetInt(result, row, 3)
		unread, _ := databaseGetInt(result, row, 4)
		append(
			&rooms,
			common.RoomSummary {
				id = roomID,
				name = databaseGetText(result, row, 1),
				description = databaseGetText(result, row, 2),
				lastReadMessageId = lastRead,
				unreadCount = unread,
			},
		)
	}
	return databaseSuccess(common.DatabaseRoomListResult{rooms = rooms})
}

databaseExecuteListRoomMemberUserIDs :: proc(
	conn: pg.Conn,
	request: common.DatabaseRoomMemberListRequest,
) -> common.DatabaseQueryResponse {
	roomIDParam := databaseIntParam(request.roomId)
	defer delete(roomIDParam)
	params := [?][^]byte{transmute([^]byte)roomIDParam}
	result := databaseExecParams(
		conn,
		"SELECT user_id::text FROM room_members WHERE room_id = $1",
		params[:],
	)
	if result == nil {
		return databaseConnectionError(conn)
	}
	defer pg.clear(result)
	if pg.result_status(result) != .Tuples_OK {
		return databaseResultError(&result)
	}

	userIDs := make([dynamic]int)
	for row in 0 ..< pg.n_tuples(result) {
		if userID, ok := databaseGetInt(result, row, 0); ok {
			append(&userIDs, userID)
		}
	}
	return databaseSuccess(common.DatabaseRoomMemberListResult{userIDs = userIDs})
}

// One statement checks membership, stores the message only for members, and lists the room's
// recipients and the sender's nickname from the same snapshot. It always returns exactly one
// row.
DATABASE_POST_ROOM_CHAT_MESSAGE_SQL ::
	"WITH member AS (SELECT 1 FROM room_members WHERE room_id = $1 AND user_id = $2), " +
	"stored AS (INSERT INTO chat_messages (room_id, sender_user_id, content) " +
	"SELECT $1, $2, $3 WHERE EXISTS (SELECT 1 FROM member) RETURNING id, created_at) " +
	"SELECT EXISTS (SELECT 1 FROM member), s.id::text, s.created_at::text, " +
	"COALESCE((SELECT string_agg(user_id::text, ',') FROM room_members WHERE room_id = $1), ''), " +
	"COALESCE((SELECT nickname FROM users WHERE id = $2), '') " +
	"FROM (SELECT 1) AS one LEFT JOIN stored s ON true"

databaseExecutePostRoomChatMessage :: proc(
	conn: pg.Conn,
	request: common.DatabasePostRoomChatMessageRequest,
) -> common.DatabaseQueryResponse {
	roomIDParam := databaseIntParam(request.roomId)
	defer delete(roomIDParam)
	senderIDParam := databaseIntParam(request.senderId)
	defer delete(senderIDParam)
	contentCString, _ := strings.clone_to_cstring(request.content)
	defer delete(contentCString)
	params := [?][^]byte {
		transmute([^]byte)roomIDParam,
		transmute([^]byte)senderIDParam,
		transmute([^]byte)contentCString,
	}
	result := databaseExecParams(conn, DATABASE_POST_ROOM_CHAT_MESSAGE_SQL, params[:])
	if result == nil {
		return databaseConnectionError(conn)
	}
	defer pg.clear(result)
	if pg.result_status(result) != .Tuples_OK || pg.n_tuples(result) != 1 {
		return databaseResultError(&result)
	}

	if !databaseGetBool(result, 0, 0) {
		return databaseSuccess(common.DatabasePostRoomChatMessageResult{isMember = false})
	}
	messageID, messageIDOK := databaseGetInt(result, 0, 1)
	if !messageIDOK {
		return databaseErrorResponse(strings.clone("database returned invalid message ID"))
	}
	recipientsText := databaseGetText(result, 0, 3)
	defer delete(recipientsText)
	return databaseSuccess(
		common.DatabasePostRoomChatMessageResult {
			isMember = true,
			storedMessage = {
				id = messageID,
				senderId = request.senderId,
				senderNickname = databaseGetText(result, 0, 4),
				roomId = request.roomId,
				timestamp = databaseGetText(result, 0, 2),
				content = strings.clone(request.content),
			},
			recipientUserIDs = databaseParseIDList(recipientsText),
		},
	)
}

// Returns the membership flag on every row, with message columns NULL when the requester is
// not a member or the page is empty. Fetches one extra row to detect older messages. The
// sender's current nickname is joined in so clients can label history without a user lookup.
DATABASE_GET_ROOM_HISTORY_SQL ::
	"WITH member AS (SELECT EXISTS (SELECT 1 FROM room_members " +
	"WHERE room_id = $1 AND user_id = $2) AS ok) " +
	"SELECT m.ok, c.id::text, c.sender_user_id::text, c.created_at::text, c.content, " +
	"c.nickname FROM member m LEFT JOIN LATERAL (" +
	"SELECT cm.id, cm.sender_user_id, cm.created_at, cm.content, u.nickname " +
	"FROM chat_messages cm JOIN users u ON u.id = cm.sender_user_id " +
	"WHERE m.ok AND cm.room_id = $1 AND ($3::bigint = 0 OR cm.id < $3::bigint) " +
	"ORDER BY cm.id DESC LIMIT $4) c ON true ORDER BY c.id DESC"

databaseExecuteGetRoomHistory :: proc(
	conn: pg.Conn,
	request: common.DatabaseRoomHistoryRequest,
) -> common.DatabaseQueryResponse {
	limit := request.limit
	if limit < 1 || limit > 50 {
		limit = 50
	}
	roomIDParam := databaseIntParam(request.roomId)
	defer delete(roomIDParam)
	userIDParam := databaseIntParam(request.userId)
	defer delete(userIDParam)
	beforeMessageIDParam := databaseIntParam(request.beforeMessageID)
	defer delete(beforeMessageIDParam)
	limitParam := databaseIntParam(limit + 1)
	defer delete(limitParam)
	params := [?][^]byte {
		transmute([^]byte)roomIDParam,
		transmute([^]byte)userIDParam,
		transmute([^]byte)beforeMessageIDParam,
		transmute([^]byte)limitParam,
	}
	result := databaseExecParams(conn, DATABASE_GET_ROOM_HISTORY_SQL, params[:])
	if result == nil {
		return databaseConnectionError(conn)
	}
	defer pg.clear(result)
	if pg.result_status(result) != .Tuples_OK || pg.n_tuples(result) < 1 {
		return databaseResultError(&result)
	}
	if !databaseGetBool(result, 0, 0) {
		return databaseSuccess(common.DatabaseRoomHistoryResult{isMember = false})
	}

	// Rows arrive newest first; drop the probe row and return the page oldest first.
	rowCount := 0
	for row in 0 ..< pg.n_tuples(result) {
		if !pg.get_is_null(result, row, 1) {
			rowCount += 1
		}
	}
	messageCount := min(rowCount, limit)
	messages := make([dynamic]common.StoredChatMessage, 0, messageCount)
	for offset in 0 ..< messageCount {
		row := i32(messageCount - offset - 1)
		messageID, messageIDOK := databaseGetInt(result, row, 1)
		senderID, senderIDOK := databaseGetInt(result, row, 2)
		if !messageIDOK || !senderIDOK {
			continue
		}
		append(
			&messages,
			common.StoredChatMessage {
				id = messageID,
				senderId = senderID,
				senderNickname = databaseGetText(result, row, 5),
				roomId = request.roomId,
				timestamp = databaseGetText(result, row, 3),
				content = databaseGetText(result, row, 4),
			},
		)
	}
	return databaseSuccess(
		common.DatabaseRoomHistoryResult {
			isMember = true,
			messages = messages,
			hasOlder = rowCount > limit,
		},
	)
}

databaseExecuteCheckUserServerAdmin :: proc(
	conn: pg.Conn,
	request: common.DatabaseUserServerAdminRequest,
) -> common.DatabaseQueryResponse {
	userIDParam := databaseIntParam(request.userId)
	defer delete(userIDParam)
	params := [?][^]byte{transmute([^]byte)userIDParam}
	result := databaseExecParams(
		conn,
		"SELECT EXISTS(SELECT 1 FROM user_server_roles usr " +
		"JOIN server_roles sr ON sr.id = usr.role_id " +
		"WHERE usr.user_id = $1 AND sr.name = 'admin')",
		params[:],
	)
	if result == nil {
		return databaseConnectionError(conn)
	}
	defer pg.clear(result)
	if pg.result_status(result) != .Tuples_OK || pg.n_tuples(result) != 1 {
		return databaseResultError(&result)
	}
	return databaseSuccess(
		common.DatabaseUserServerAdminResult{isAdmin = databaseGetBool(result, 0, 0)},
	)
}

// Rooms are open: a new room includes every account, the creator among them, so nobody has
// to be added by hand. The database worker runs one statement at a time on one connection,
// so an account created concurrently either sees this room or is seen by it.
DATABASE_CREATE_ROOM_SQL ::
	"WITH created_room AS (" +
	"INSERT INTO rooms (name, description, created_by_user_id) VALUES ($2, $3, $1) " +
	"RETURNING id, name, description" +
	"), all_members AS (" +
	"INSERT INTO room_members (room_id, user_id) " +
	"SELECT created_room.id, users.id FROM created_room CROSS JOIN users " +
	"ON CONFLICT DO NOTHING" +
	") SELECT id::text, name, description FROM created_room"

databaseExecuteCreateRoom :: proc(
	conn: pg.Conn,
	request: common.DatabaseCreateRoomRequest,
) -> common.DatabaseQueryResponse {
	creatorUserIDParam := databaseIntParam(request.creatorUserId)
	defer delete(creatorUserIDParam)
	nameCString, _ := strings.clone_to_cstring(request.name)
	defer delete(nameCString)
	descriptionCString, _ := strings.clone_to_cstring(request.description)
	defer delete(descriptionCString)
	params := [?][^]byte {
		transmute([^]byte)creatorUserIDParam,
		transmute([^]byte)nameCString,
		transmute([^]byte)descriptionCString,
	}
	result := databaseExecParams(conn, DATABASE_CREATE_ROOM_SQL, params[:])
	if result == nil {
		return databaseConnectionError(conn)
	}
	defer pg.clear(result)
	if pg.result_status(result) != .Tuples_OK || pg.n_tuples(result) != 1 {
		return databaseResultError(&result)
	}

	roomID, roomIDOK := databaseGetInt(result, 0, 0)
	if !roomIDOK {
		return databaseErrorResponse(strings.clone("database returned invalid room ID"))
	}
	return databaseSuccess(
		common.DatabaseRoomMutationResult {
			changed = true,
			room = {
				id = roomID,
				name = databaseGetText(result, 0, 1),
				description = databaseGetText(result, 0, 2),
			},
		},
	)
}

databaseExecuteEditRoom :: proc(
	conn: pg.Conn,
	request: common.DatabaseEditRoomRequest,
) -> common.DatabaseQueryResponse {
	roomIDParam := databaseIntParam(request.roomId)
	defer delete(roomIDParam)
	nameCString, _ := strings.clone_to_cstring(request.name)
	defer delete(nameCString)
	descriptionCString, _ := strings.clone_to_cstring(request.description)
	defer delete(descriptionCString)
	params := [?][^]byte {
		transmute([^]byte)roomIDParam,
		transmute([^]byte)nameCString,
		transmute([^]byte)descriptionCString,
	}
	result := databaseExecParams(
		conn,
		"UPDATE rooms SET name = $2, description = $3 WHERE id = $1 " +
		"RETURNING id::text, name, description",
		params[:],
	)
	if result == nil {
		return databaseConnectionError(conn)
	}
	defer pg.clear(result)
	if pg.result_status(result) != .Tuples_OK {
		return databaseResultError(&result)
	}

	mutation := common.DatabaseRoomMutationResult {
		changed = pg.n_tuples(result) == 1,
	}
	if mutation.changed {
		mutation.room = {
			id          = request.roomId,
			name        = databaseGetText(result, 0, 1),
			description = databaseGetText(result, 0, 2),
		}
	}
	return databaseSuccess(mutation)
}

databaseExecuteDeleteRoom :: proc(
	conn: pg.Conn,
	request: common.DatabaseDeleteRoomRequest,
) -> common.DatabaseQueryResponse {
	roomIDParam := databaseIntParam(request.roomId)
	defer delete(roomIDParam)
	params := [?][^]byte{transmute([^]byte)roomIDParam}
	result := databaseExecParams(
		conn,
		"DELETE FROM rooms WHERE id = $1 RETURNING id::text",
		params[:],
	)
	if result == nil {
		return databaseConnectionError(conn)
	}
	defer pg.clear(result)
	if pg.result_status(result) != .Tuples_OK {
		return databaseResultError(&result)
	}
	return databaseSuccess(common.DatabaseRoomMutationResult{changed = pg.n_tuples(result) == 1})
}

databaseExecuteRoomMemberMutation :: proc(
	conn: pg.Conn,
	request: common.DatabaseRoomMemberMutationRequest,
	query: cstring,
) -> common.DatabaseQueryResponse {
	roomIDParam := databaseIntParam(request.roomId)
	defer delete(roomIDParam)
	userIDParam := databaseIntParam(request.userId)
	defer delete(userIDParam)
	params := [?][^]byte{transmute([^]byte)roomIDParam, transmute([^]byte)userIDParam}
	result := databaseExecParams(conn, query, params[:])
	if result == nil {
		return databaseConnectionError(conn)
	}
	defer pg.clear(result)
	if pg.result_status(result) != .Tuples_OK {
		return databaseResultError(&result)
	}
	return databaseSuccess(common.DatabaseRoomMutationResult{changed = pg.n_tuples(result) == 1})
}

databaseExecuteRequest :: proc(
	conn: pg.Conn,
	request: common.DatabaseQueryRequest,
) -> common.DatabaseQueryResponse {
	switch r in request {
	case common.DatabaseUserIdentityRequest:
		return databaseExecuteUserIdentityResolution(conn, r)
	case common.DatabaseRoomListRequest:
		return databaseExecuteListRoomsForUser(conn, r)
	case common.DatabaseRoomMemberListRequest:
		return databaseExecuteListRoomMemberUserIDs(conn, r)
	case common.DatabasePostRoomChatMessageRequest:
		return databaseExecutePostRoomChatMessage(conn, r)
	case common.DatabaseRoomHistoryRequest:
		return databaseExecuteGetRoomHistory(conn, r)
	case common.DatabaseUserServerAdminRequest:
		return databaseExecuteCheckUserServerAdmin(conn, r)
	case common.DatabaseCreateRoomRequest:
		return databaseExecuteCreateRoom(conn, r)
	case common.DatabaseEditRoomRequest:
		return databaseExecuteEditRoom(conn, r)
	case common.DatabaseDeleteRoomRequest:
		return databaseExecuteDeleteRoom(conn, r)
	case common.DatabaseAddRoomMemberRequest:
		return databaseExecuteRoomMemberMutation(
			conn,
			common.DatabaseRoomMemberMutationRequest(r),
			"INSERT INTO room_members (room_id, user_id) VALUES ($1, $2) " +
			"ON CONFLICT DO NOTHING RETURNING room_id::text",
		)
	case common.DatabaseRemoveRoomMemberRequest:
		return databaseExecuteRoomMemberMutation(
			conn,
			common.DatabaseRoomMemberMutationRequest(r),
			"DELETE FROM room_members WHERE room_id = $1 AND user_id = $2 RETURNING room_id::text",
		)
	case common.DatabasePostDirectMessageRequest:
		return databaseExecutePostDirectMessage(conn, r)
	case common.DatabaseDirectHistoryRequest:
		return databaseExecuteGetDirectHistory(conn, r)
	case common.DatabaseDirectConversationListRequest:
		return databaseExecuteListDirectConversations(conn, r)
	case common.DatabaseUserDirectoryRequest:
		return databaseExecuteListUsers(conn)
	case common.DatabaseMarkReadRequest:
		return databaseExecuteMarkRead(conn, r)
	case nil:
		return databaseErrorResponse(strings.clone("missing database query"))
	}
	return databaseErrorResponse(strings.clone("missing database query"))
}

databaseRuntimeConninfo :: proc(config: ServerConfig) -> cstring {
	return fmt.caprintf(
		"host=%s port=%d user=%s password=%s dbname=%s connect_timeout=%d",
		config.databaseURL,
		config.databasePort,
		config.databaseUser,
		config.databasePass,
		config.databaseName,
		DATABASE_CONNECT_TIMEOUT_SECONDS,
	)
}

databaseOpenRuntimeConnectionWithHooks :: proc(
	config: ServerConfig,
	connectdbProc: DatabaseConnectDBProc,
	statusProc: DatabaseConnectionStatusProc,
	errorMessageProc: DatabaseConnectionErrorProc,
	finishProc: DatabaseConnectionFinishProc,
) -> (
	pg.Conn,
	string,
) {
	conninfo := databaseRuntimeConninfo(config)
	defer delete(conninfo)

	conn := connectdbProc(conninfo)
	if conn != nil && statusProc(conn) == .Ok {
		return conn, ""
	}

	detail := ""
	if conn != nil {
		detail = cloneCStringOrEmpty(errorMessageProc(conn))
		finishProc(conn)
	}
	if len(detail) == 0 {
		detail = strings.clone("unknown PostgreSQL connection error")
	}

	err := fmt.aprintf(
		"database connection failed for %s@%s:%d/%s: %s",
		config.databaseUser,
		config.databaseURL,
		config.databasePort,
		config.databaseName,
		detail,
	)
	delete(detail)
	return nil, err
}

databaseOpenRuntimeConnection :: proc(config: ServerConfig) -> (pg.Conn, string) {
	return databaseOpenRuntimeConnectionWithHooks(
		config,
		pg.connectdb,
		pg.status,
		pg.error_message,
		pg.finish,
	)
}

DATABASE_IDLE_WAIT :: 100 * time.Millisecond

// Database process entry point
// Manages PostgreSQL connection pool and handles database queries from main process
databaseServerLoop :: proc(pm: ^ProcessManager) {
	fmt.printfln("[Database] Database server loop started (PID: %d)", os.get_pid())
	databaseFd, ipcInitErr := IPC_Client_init(&pm.config.databaseSocket)
	if ipcInitErr != nil {
		fmt.eprintfln("[Database] Failed to initialize coordinator endpoint: %s", ipcInitErr)
		return
	}
	pm.config.databaseFd = databaseFd
	defer IPC_Client_deinit(&pm.config.databaseSocket)

	dbConnection, startupErr := databaseOpenRuntimeConnection(pm.config^)
	if len(startupErr) > 0 {
		sendErr := IPC_Client_send(pm.config.databaseFd, DatabaseStartupFailed{error = startupErr})
		if sendErr != nil {
			fmt.eprintfln("[Database] %s", startupErr)
			delete(startupErr)
		}
		return
	}
	defer pg.finish(dbConnection)
	// Migrations run before anything else reads the schema. A refusal leaves the database as it
	// was and becomes a [Startup] error in main.
	migrationOutcome, schemaErr := databaseMigrateSchema(dbConnection, DATABASE_MIGRATIONS[:])
	if len(schemaErr) > 0 {
		sendErr := IPC_Client_send(pm.config.databaseFd, DatabaseStartupFailed{error = schemaErr})
		if sendErr != nil {
			fmt.eprintfln("[Database] %s", schemaErr)
			delete(schemaErr)
		}
		return
	}
	databaseLogMigrationOutcome(migrationOutcome, DATABASE_MIGRATIONS[:])
	// Before readiness, so the first client to connect already finds #general.
	defaultRoomID, defaultRoomErr := databaseEnsureDefaultRoom(dbConnection)
	if len(defaultRoomErr) > 0 {
		sendErr := IPC_Client_send(
			pm.config.databaseFd,
			DatabaseStartupFailed{error = defaultRoomErr},
		)
		if sendErr != nil {
			fmt.eprintfln("[Database] %s", defaultRoomErr)
			delete(defaultRoomErr)
		}
		return
	}
	if defaultRoomID > 0 {
		fmt.printfln("[Database] Created default room #general (ID %d)", defaultRoomID)
	}

	readyErr := IPC_Client_send(pm.config.databaseFd, DatabaseStartupReady{})
	if readyErr != nil {
		fmt.eprintfln("[Database] Failed to report startup readiness")
		return
	}

	running := true
	for running {
		message, err := IPC_Client_poll(pm.config.databaseFd)
		if err != nil {
			// Shutdown and restart arrive as messages, so a long wait is safe.
			IPC_Client_wait(pm.config.databaseFd, DATABASE_IDLE_WAIT)
			continue
		}

		#partial switch msg in message {
		case DatabaseQuery:
			response := databaseExecuteRequest(dbConnection, msg.request)
			IPC_Client_send(
				pm.config.databaseFd,
				DatabaseQueryResult{request_id = msg.request_id, response = response},
			)
		case ProcessShutdown:
			fmt.printfln("[Database] Received shutdown signal")
			running = false
		case ProcessRestart:
			fmt.printfln("[Database] Received restart signal")
			running = false
		case Wake:
		// No-op, just wake up to check for shutdown/restart signals
		case:
			fmt.eprintfln("[Database] Received unsupported message type")
		}
	}

	fmt.printfln("[Database] Process shutting down")
}
