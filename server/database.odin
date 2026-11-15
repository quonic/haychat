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
// An account created by this statement joins every Public room (protocol 15) in the same
// statement, so it can chat as soon as it authenticates; invite rooms take only whom a member
// or an admin adds. `existing` reads the snapshot from
// before the write, so only a brand-new nickname joins; a rename, a returning account, or a
// claimed account keeps whatever membership it had. The membership insert reads from
// `inserted`, which is empty when the key already owns an account or the identity is not
// claimable, so a refused login joins nothing.
//
// The final select also reports whether the resolved account holds the `admin` server role,
// for ServerAuthSuccess.isAdmin. user_server_roles is not written here, so the statement's
// snapshot is current: a claimed seeded admin reads true, a brand-new account false.
//
// Admin actions (migration 3, protocol 14): a key whose account has nickname_locked set (an
// admin renamed it) is never renamed here; it resolves to its account under the locked name,
// whatever the client asked for. A banned account is never renamed either, and resolves with
// its ban, which the router turns into a refused sign-in. users is not written for either, and
// a claimed keyless account's lock and ban come from the statement's snapshot, so they read
// right too.
//
// Columns: user ID, whether this was a rename, the nickname before the rename, whether the
// account is an admin, its nickname after this login, whether that nickname is locked, whether
// the account is banned, and the ban reason.
DATABASE_RESOLVE_USER_IDENTITY_SQL ::
	"WITH by_key AS (SELECT id, nickname, nickname_locked, banned_at IS NOT NULL AS banned " +
	"FROM users WHERE public_key = decode($2, 'hex')), " +
	"existing AS (SELECT id FROM users WHERE nickname = $1), " +
	"renamed AS (" +
	"UPDATE users SET nickname = $1 FROM by_key " +
	"WHERE users.id = by_key.id AND by_key.nickname <> $1 " +
	"AND NOT by_key.nickname_locked AND NOT by_key.banned " +
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
	"WHERE r.access = 1 AND NOT EXISTS (SELECT 1 FROM existing) ON CONFLICT DO NOTHING), " +
	"resolved AS (" +
	"SELECT id, false AS is_rename, ''::text AS previous_nickname, nickname::text " +
	"FROM by_key WHERE nickname = $1 OR nickname_locked OR banned " +
	"UNION ALL SELECT id, true, previous_nickname, $1::text FROM renamed " +
	"UNION ALL SELECT id, false, '', $1::text FROM inserted) " +
	"SELECT resolved.id::text, is_rename::text, previous_nickname, EXISTS (" +
	"SELECT 1 FROM user_server_roles usr JOIN server_roles sr ON sr.id = usr.role_id " +
	"WHERE usr.user_id = resolved.id AND sr.name = 'admin')::text, resolved.nickname, " +
	"COALESCE(u.nickname_locked, false)::text, (u.banned_at IS NOT NULL)::text, " +
	"COALESCE(u.ban_reason, '') FROM resolved LEFT JOIN users u ON u.id = resolved.id"

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

databaseGetIntOrZero :: proc(result: pg.Result, row: i32, column: i32) -> int {
	value, _ := databaseGetInt(result, row, column)
	return value
}

databaseGetBool :: proc(result: pg.Result, row: i32, column: i32) -> bool {
	text := databaseGetText(result, row, column)
	defer delete(text)
	// libpq's text format renders booleans as "t"/"f"; a ::text cast yields "true"/"false".
	return text == "t" || text == "true"
}

// Reads a rooms.access column. Its check allows only the three modes; anything else means a
// broken row, which reads as Admin invite, the mode that lets the fewest people in.
databaseGetRoomAccess :: proc(result: pg.Result, row: i32, column: i32) -> common.RoomAccess {
	value, ok := databaseGetInt(result, row, column)
	access := common.RoomAccess(value)
	if !ok || !common.roomAccessIsSupported(access) {
		return .AdminInvite
	}
	return access
}

// Reads a rooms.history_visibility column next to its access column, as the history new
// members read: Full for a Public room (common.roomEffectiveHistoryVisibility). A broken value
// reads as From join, the one that shows the least.
databaseGetRoomHistoryVisibility :: proc(
	result: pg.Result,
	row: i32,
	column: i32,
	access: common.RoomAccess,
) -> common.RoomHistoryVisibility {
	value, ok := databaseGetInt(result, row, column)
	visibility := common.RoomHistoryVisibility(value)
	if !ok || !common.roomHistoryVisibilityIsSupported(visibility) {
		visibility = .FromJoin
	}
	return common.roomEffectiveHistoryVisibility(access, visibility)
}

// Reads a room's columns in the order id, name, description, room_type, access,
// history_visibility, encrypted, log_version (protocol 18) starting at first. The strings are
// owned by the caller.
databaseGetRoomSummary :: proc(
	result: pg.Result,
	row: i32,
	first: i32,
) -> (
	room: common.RoomSummary,
	ok: bool,
) {
	room.id, ok = databaseGetInt(result, row, first)
	if !ok {
		return {}, false
	}
	room.name = databaseGetText(result, row, first + 1)
	room.description = databaseGetText(result, row, first + 2)
	room.roomType = databaseGetRoomType(result, row, first + 3)
	room.access = databaseGetRoomAccess(result, row, first + 4)
	room.historyVisibility = databaseGetRoomHistoryVisibility(
		result,
		row,
		first + 5,
		room.access,
	)
	room.encrypted = databaseGetBool(result, row, first + 6)
	room.logVersion, _ = databaseGetInt(result, row, first + 7)
	return room, true
}

// The columns databaseGetRoomSummary reads, for a rooms row aliased r.
DATABASE_ROOM_SUMMARY_COLUMNS_SQL ::
	"r.id::text, r.name, r.description, r.room_type::text, r.access::text, " +
	"r.history_visibility::text, r.encrypted::text, r.log_version::text"


// Reads a rooms.room_type column. The column's check allows only the supported types, so
// anything else means a broken row; it reads as ChatAndVoice, what rooms were before types.
databaseGetRoomType :: proc(result: pg.Result, row: i32, column: i32) -> common.RoomType {
	value, ok := databaseGetInt(result, row, column)
	roomType := common.RoomType(value)
	if !ok || !common.roomTypeIsSupported(roomType) {
		return .ChatAndVoice
	}
	return roomType
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
		identity.nickname = databaseGetText(result, 0, 4)
		identity.nicknameLocked = databaseGetBool(result, 0, 5)
		identity.banned = databaseGetBool(result, 0, 6)
		if identity.banned {
			identity.banReason = databaseGetText(result, 0, 7)
		}
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
	"COALESCE(m.last_read_message_id, 0)::text, unread.n::text, r.room_type::text, " +
	"r.access::text, r.history_visibility::text, r.encrypted::text, r.log_version::text " +
	"FROM rooms r JOIN room_members rm ON rm.room_id = r.id AND rm.user_id = $1::bigint " +
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
		access := databaseGetRoomAccess(result, row, 6)
		append(
			&rooms,
			common.RoomSummary {
				id = roomID,
				name = databaseGetText(result, row, 1),
				description = databaseGetText(result, row, 2),
				lastReadMessageId = lastRead,
				unreadCount = unread,
				roomType = databaseGetRoomType(result, row, 5),
				access = access,
				historyVisibility = databaseGetRoomHistoryVisibility(result, row, 7, access),
				encrypted = databaseGetBool(result, row, 8),
				logVersion = databaseGetIntOrZero(result, row, 9),
			},
		)
	}
	return databaseSuccess(common.DatabaseRoomListResult{rooms = rooms})
}

// The room's type and members: one row per member, or one row with a NULL member for a room
// without members, and no row for a room that does not exist. The last columns are the room's
// encrypted flag (protocol 18) and its member log version (protocol 21: the epoch voice keys
// must name).
DATABASE_LIST_ROOM_MEMBERS_SQL ::
	"SELECT r.room_type::text, rm.user_id::text, r.encrypted::text, r.log_version::text " +
	"FROM rooms r " +
	"LEFT JOIN room_members rm ON rm.room_id = r.id WHERE r.id = $1"

databaseExecuteListRoomMemberUserIDs :: proc(
	conn: pg.Conn,
	request: common.DatabaseRoomMemberListRequest,
) -> common.DatabaseQueryResponse {
	roomIDParam := databaseIntParam(request.roomId)
	defer delete(roomIDParam)
	params := [?][^]byte{transmute([^]byte)roomIDParam}
	result := databaseExecParams(conn, DATABASE_LIST_ROOM_MEMBERS_SQL, params[:])
	if result == nil {
		return databaseConnectionError(conn)
	}
	defer pg.clear(result)
	if pg.result_status(result) != .Tuples_OK {
		return databaseResultError(&result)
	}

	members := common.DatabaseRoomMemberListResult {
		userIDs = make([dynamic]int),
	}
	for row in 0 ..< pg.n_tuples(result) {
		if row == 0 {
			members.roomFound = true
			members.roomType = databaseGetRoomType(result, row, 0)
			members.encrypted = databaseGetBool(result, row, 2)
			members.logVersion, _ = databaseGetInt(result, row, 3)
		}
		if userID, ok := databaseGetInt(result, row, 1); ok {
			append(&members.userIDs, userID)
		}
	}
	return databaseSuccess(members)
}

// One statement checks membership and the room type (a voice-only room takes no chat, protocol
// 14), stores the message only for members of a room with chat, and lists the room's
// recipients and the sender's nickname from the same snapshot.
//
// Protocol 19: a plaintext message ($4 '') is stored only in an unencrypted room and a sealed
// one ($4 the SealedRoomMessage as hex) only in an encrypted room whose log version is the
// message's epoch ($6), with its client message ID ($5), chain ID ($7) and index ($8). The
// unique indexes on (sender, client message ID) and (sender, chain ID, index) make a reused
// one store nothing (ON CONFLICT DO NOTHING). It always returns exactly one row: membership,
// the message ID and time, recipients, nickname, whether chat is allowed, whether the room is
// encrypted, and its log version.
DATABASE_POST_ROOM_CHAT_MESSAGE_SQL ::
	"WITH member AS (SELECT 1 FROM room_members WHERE room_id = $1 AND user_id = $2), " +
	"room AS (SELECT room_type, encrypted, log_version FROM rooms WHERE id = $1), " +
	"chat AS (SELECT 1 FROM room WHERE room_type IN (1, 3) AND encrypted = ($4::text <> '') " +
	"AND (NOT encrypted OR log_version = $6::bigint)), " +
	"stored AS (INSERT INTO chat_messages (room_id, sender_user_id, content, sealed, " +
	"client_message_id, epoch, chain_id, chain_index) " +
	"SELECT $1, $2, $3, " +
	"CASE WHEN $4::text = '' THEN NULL ELSE decode($4::text, 'hex') END, " +
	"CASE WHEN $4::text = '' THEN NULL ELSE decode($5::text, 'hex') END, " +
	"CASE WHEN $4::text = '' THEN NULL ELSE $6::bigint END, " +
	"CASE WHEN $4::text = '' THEN NULL ELSE decode($7::text, 'hex') END, " +
	"CASE WHEN $4::text = '' THEN NULL ELSE $8::integer END " +
	"WHERE EXISTS (SELECT 1 FROM member) AND EXISTS (SELECT 1 FROM chat) " +
	"ON CONFLICT DO NOTHING RETURNING id, created_at) " +
	"SELECT EXISTS (SELECT 1 FROM member), s.id::text, s.created_at::text, " +
	"COALESCE((SELECT string_agg(user_id::text, ',') FROM room_members WHERE room_id = $1), ''), " +
	"COALESCE((SELECT nickname FROM users WHERE id = $2), ''), " +
	"COALESCE((SELECT room_type IN (1, 3) FROM room), false), " +
	"COALESCE((SELECT encrypted FROM room), false), " +
	"COALESCE((SELECT log_version FROM room), 0)::text " +
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
	sealedHex := ""
	clientMessageIDHex := ""
	chainIDHex := ""
	sealed := len(request.sealed) > 0
	if sealed {
		clientMessageID := request.clientMessageId
		chainID := request.chainId
		sealedHex = common.encodeBytesToHex(request.sealed)
		clientMessageIDHex = common.encodeBytesToHex(clientMessageID[:])
		chainIDHex = common.encodeBytesToHex(chainID[:])
	}
	defer if sealed {
		delete(sealedHex)
		delete(clientMessageIDHex)
		delete(chainIDHex)
	}
	sealedParam, _ := strings.clone_to_cstring(sealedHex)
	defer delete(sealedParam)
	clientMessageIDParam, _ := strings.clone_to_cstring(clientMessageIDHex)
	defer delete(clientMessageIDParam)
	epochParam := databaseIntParam(request.epoch)
	defer delete(epochParam)
	chainIDParam, _ := strings.clone_to_cstring(chainIDHex)
	defer delete(chainIDParam)
	chainIndexParam := databaseIntParam(request.chainIndex)
	defer delete(chainIndexParam)
	params := [?][^]byte {
		transmute([^]byte)roomIDParam,
		transmute([^]byte)senderIDParam,
		transmute([^]byte)contentCString,
		transmute([^]byte)sealedParam,
		transmute([^]byte)clientMessageIDParam,
		transmute([^]byte)epochParam,
		transmute([^]byte)chainIDParam,
		transmute([^]byte)chainIndexParam,
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
	if !databaseGetBool(result, 0, 5) {
		return databaseSuccess(
			common.DatabasePostRoomChatMessageResult{isMember = true, chatDisabled = true},
		)
	}
	encrypted := databaseGetBool(result, 0, 6)
	if encrypted && !sealed {
		return databaseSuccess(
			common.DatabasePostRoomChatMessageResult{isMember = true, encryptedRoom = true},
		)
	}
	if !encrypted && sealed {
		return databaseSuccess(
			common.DatabasePostRoomChatMessageResult{isMember = true, notEncrypted = true},
		)
	}
	if logVersion, _ := databaseGetInt(result, 0, 7); sealed && logVersion != request.epoch {
		return databaseSuccess(
			common.DatabasePostRoomChatMessageResult{isMember = true, staleEpoch = true},
		)
	}
	if pg.get_is_null(result, 0, 1) {
		// Every check passed and nothing was inserted: a unique index refused it.
		return databaseSuccess(
			common.DatabasePostRoomChatMessageResult{isMember = true, duplicate = true},
		)
	}
	messageID, messageIDOK := databaseGetInt(result, 0, 1)
	if !messageIDOK {
		return databaseErrorResponse(strings.clone("database returned invalid message ID"))
	}
	recipientsText := databaseGetText(result, 0, 3)
	defer delete(recipientsText)
	storedSealed: []u8
	if sealed {
		storedSealed = make([]u8, len(request.sealed))
		copy(storedSealed, request.sealed)
	}
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
				clientMessageId = request.clientMessageId,
				sealed = storedSealed,
			},
			recipientUserIDs = databaseParseIDList(recipientsText),
		},
	)
}

// Returns the membership flag on every row, with message columns NULL when the requester is
// not a member or the page is empty. Fetches one extra row to detect older messages. The
// sender's current nickname is joined in so clients can label history without a user lookup.
//
// From join history (protocol 15): in a non-public room whose history_visibility is From join,
// a member reads only messages created after their room_members.joined_at (`since`), the same
// cut the unread count uses, so someone removed and added again starts over from the second
// addition. `first_visible` is the first such message's ID, found through
// chat_messages_by_room_id_and_created_at, so a page that reaches the cut stops there instead
// of scanning every older message; the created_at test stays as the rule itself.
DATABASE_GET_ROOM_HISTORY_SQL ::
	"WITH member AS (SELECT EXISTS (SELECT 1 FROM room_members " +
	"WHERE room_id = $1 AND user_id = $2) AS ok, " +
	"(SELECT rm.joined_at FROM room_members rm JOIN rooms r ON r.id = rm.room_id " +
	"WHERE rm.room_id = $1 AND rm.user_id = $2 AND r.access <> 1 " +
	"AND r.history_visibility = 1) AS since), " +
	"first_visible AS (SELECT CASE WHEN m.since IS NULL THEN 0 ELSE COALESCE((" +
	"SELECT cm.id FROM chat_messages cm WHERE cm.room_id = $1 AND cm.created_at > m.since " +
	"ORDER BY cm.created_at, cm.id LIMIT 1), 9223372036854775807) END AS id FROM member m) " +
	"SELECT m.ok, c.id::text, c.sender_user_id::text, c.created_at::text, c.content, " +
	"c.nickname, COALESCE(encode(c.client_message_id, 'hex'), ''), " +
	"COALESCE(encode(c.sealed, 'hex'), '') FROM member m CROSS JOIN first_visible f " +
	"LEFT JOIN LATERAL (" +
	"SELECT cm.id, cm.sender_user_id, cm.created_at, cm.content, u.nickname, " +
	"cm.client_message_id, cm.sealed " +
	"FROM chat_messages cm JOIN users u ON u.id = cm.sender_user_id " +
	"WHERE m.ok AND cm.room_id = $1 AND ($3::bigint = 0 OR cm.id < $3::bigint) " +
	"AND cm.id >= f.id AND (m.since IS NULL OR cm.created_at > m.since) " +
	"ORDER BY cm.id DESC LIMIT $4) c ON true ORDER BY c.id DESC"

// A hex column as owned bytes, nil for NULL, '' or malformed hex.
databaseGetOwnedHexBytes :: proc(result: pg.Result, row: i32, column: i32) -> []u8 {
	if pg.get_is_null(result, row, column) {
		return nil
	}
	text := databaseGetText(result, row, column)
	defer delete(text)
	if len(text) == 0 || len(text) % 2 != 0 {
		return nil
	}
	bytes := make([]u8, len(text) / 2)
	if !common.decodeHexIntoBuffer(text, bytes) {
		delete(bytes)
		return nil
	}
	return bytes
}

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
		message := common.StoredChatMessage {
			id             = messageID,
			senderId       = senderID,
			senderNickname = databaseGetText(result, row, 5),
			roomId         = request.roomId,
			timestamp      = databaseGetText(result, row, 3),
			content        = databaseGetText(result, row, 4),
		}
		// Protocol 19: a sealed message's client message ID and bytes; malformed reads as none.
		if !databaseGetHexBytes(result, row, 6, message.clientMessageId[:]) {
			message.clientMessageId = {}
		}
		message.sealed = databaseGetOwnedHexBytes(result, row, 7)
		append(&messages, message)
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

// A new Public room ($5 = 1) includes every account, the creator among them, and stores Full
// history whatever $6 says; an invite room includes only the creator, and only when $7
// (creatorJoins) is true. An encrypted room ($8, protocol 18; never Public, which the router
// and rooms_encrypted_access refuse) starts with no members: its log's Create entry adds the
// creator. The database worker runs one statement at a time on one connection, so an account
// created concurrently either sees this room or is seen by it. The last column says whether the
// creator is a member.
DATABASE_CREATE_ROOM_SQL ::
	"WITH created_room AS (" +
	"INSERT INTO rooms (name, description, created_by_user_id, room_type, access, " +
	"history_visibility, encrypted) VALUES ($2, $3, $1, $4::smallint, $5::smallint, " +
	"CASE WHEN $5::smallint = 1 THEN 2 ELSE $6::smallint END, $8::boolean) " +
	"RETURNING id, name, description, room_type, access, history_visibility, encrypted, " +
	"log_version" +
	"), members AS (" +
	"INSERT INTO room_members (room_id, user_id) " +
	"SELECT created_room.id, users.id FROM created_room CROSS JOIN users " +
	"WHERE NOT created_room.encrypted AND (created_room.access = 1 " +
	"OR (users.id = $1::bigint AND $7::boolean)) " +
	"ON CONFLICT DO NOTHING RETURNING user_id" +
	") SELECT id::text, name, description, room_type::text, access::text, " +
	"history_visibility::text, encrypted::text, log_version::text, " +
	"EXISTS (SELECT 1 FROM members WHERE user_id = $1::bigint)::text FROM created_room"

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
	roomTypeParam := databaseIntParam(int(request.roomType))
	defer delete(roomTypeParam)
	accessParam := databaseIntParam(int(request.access))
	defer delete(accessParam)
	historyParam := databaseIntParam(int(request.historyVisibility))
	defer delete(historyParam)
	joinsParam := strings.clone_to_cstring(request.creatorJoins ? "true" : "false")
	defer delete(joinsParam)
	encryptedParam := strings.clone_to_cstring(request.encrypted ? "true" : "false")
	defer delete(encryptedParam)
	params := [?][^]byte {
		transmute([^]byte)creatorUserIDParam,
		transmute([^]byte)nameCString,
		transmute([^]byte)descriptionCString,
		transmute([^]byte)roomTypeParam,
		transmute([^]byte)accessParam,
		transmute([^]byte)historyParam,
		transmute([^]byte)joinsParam,
		transmute([^]byte)encryptedParam,
	}
	result := databaseExecParams(conn, DATABASE_CREATE_ROOM_SQL, params[:])
	if result == nil {
		return databaseConnectionError(conn)
	}
	defer pg.clear(result)
	if pg.result_status(result) != .Tuples_OK || pg.n_tuples(result) != 1 {
		return databaseResultError(&result)
	}

	room, roomOK := databaseGetRoomSummary(result, 0, 0)
	if !roomOK {
		return databaseErrorResponse(strings.clone("database returned invalid room ID"))
	}
	return databaseSuccess(
		common.DatabaseRoomMutationResult {
			changed = true,
			room = room,
			isMember = databaseGetBool(result, 0, 8),
		},
	)
}

// Switching a room to Public ($5 = 1) adds every account in the same statement; column 8
// lists the accounts it added. Switching away from Public keeps every member. The history
// setting never changes. Protocol 18: the edit applies only when $6 is the room's encrypted
// flag and, for an encrypted room, $5 its access (an encrypted room's access changes through a
// signed SetAccess log entry). It always returns one row; columns 9 and 10 are the room's flag
// and access before the edit (NULL for no such room), so a refusal can say why.
DATABASE_EDIT_ROOM_SQL ::
	"WITH current AS (SELECT encrypted, access FROM rooms WHERE id = $1), " +
	"updated AS (UPDATE rooms SET name = $2, description = $3, " +
	"room_type = $4::smallint, access = $5::smallint WHERE id = $1 " +
	"AND encrypted = $6::boolean AND (NOT encrypted OR access = $5::smallint) " +
	"RETURNING id, name, description, room_type, access, history_visibility, encrypted, " +
	"log_version), " +
	"added AS (INSERT INTO room_members (room_id, user_id) " +
	"SELECT updated.id, users.id FROM updated CROSS JOIN users WHERE updated.access = 1 " +
	"ON CONFLICT DO NOTHING RETURNING user_id) " +
	"SELECT u.id::text, u.name, u.description, u.room_type::text, u.access::text, " +
	"u.history_visibility::text, u.encrypted::text, u.log_version::text, " +
	"COALESCE((SELECT string_agg(user_id::text, ',' ORDER BY user_id) FROM added), ''), " +
	"(SELECT encrypted FROM current)::text, (SELECT access FROM current)::text " +
	"FROM (SELECT 1) AS one LEFT JOIN updated u ON true"

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
	roomTypeParam := databaseIntParam(int(request.roomType))
	defer delete(roomTypeParam)
	accessParam := databaseIntParam(int(request.access))
	defer delete(accessParam)
	encryptedParam := strings.clone_to_cstring(request.encrypted ? "true" : "false")
	defer delete(encryptedParam)
	params := [?][^]byte {
		transmute([^]byte)roomIDParam,
		transmute([^]byte)nameCString,
		transmute([^]byte)descriptionCString,
		transmute([^]byte)roomTypeParam,
		transmute([^]byte)accessParam,
		transmute([^]byte)encryptedParam,
	}
	result := databaseExecParams(conn, DATABASE_EDIT_ROOM_SQL, params[:])
	if result == nil {
		return databaseConnectionError(conn)
	}
	defer pg.clear(result)
	if pg.result_status(result) != .Tuples_OK || pg.n_tuples(result) != 1 {
		return databaseResultError(&result)
	}

	mutation := common.DatabaseRoomMutationResult {
		changed = !pg.get_is_null(result, 0, 0),
	}
	if mutation.changed {
		mutation.room, _ = databaseGetRoomSummary(result, 0, 0)
		mutation.room.id = request.roomId
		added := databaseGetText(result, 0, 8)
		defer delete(added)
		mutation.addedUserIDs = databaseParseIDList(added)
	} else if !pg.get_is_null(result, 0, 9) {
		// The room exists, so the encryption rules refused the edit.
		if databaseGetBool(result, 0, 9) != request.encrypted {
			mutation.refusal = .EncryptionFlag
		} else {
			mutation.refusal = .EncryptedAccess
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
	case common.DatabaseRoomMemberActionRequest:
		return databaseExecuteRoomMemberAction(conn, r)
	case common.DatabaseAdminRoomListRequest:
		return databaseExecuteAdminRoomList(conn, r)
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
	case common.DatabaseAdminUserRequest:
		return databaseExecuteAdminUser(conn, r)
	case common.DatabasePublishEncryptionKeyRequest:
		return databaseExecutePublishEncryptionKey(conn, r)
	case common.DatabaseFetchUserKeysRequest:
		return databaseExecuteFetchUserKeys(conn, r)
	case common.DatabaseAppendRoomLogRequest:
		return databaseExecuteAppendRoomLog(conn, r)
	case common.DatabaseFetchRoomLogRequest:
		return databaseExecuteFetchRoomLog(conn, r)
	case common.DatabaseStoreRoomKeyEnvelopeRequest:
		return databaseExecuteStoreRoomKeyEnvelope(conn, r)
	case common.DatabaseFetchRoomKeysRequest:
		return databaseExecuteFetchRoomKeys(conn, r)
	case common.DatabaseRoomKeyRequestCheckRequest:
		return databaseExecuteRoomKeyRequestCheck(conn, r)
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
