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

databaseErrorResponse :: proc(
	queryType: common.DatabaseQueryType,
	message: string,
) -> common.DatabaseQueryResponse {
	return common.DatabaseQueryResponse {
		queryType = queryType,
		success = false,
		message = message,
		result = "",
	}
}

databaseExecuteRawQuery :: proc(
	conn: pg.Conn,
	request: common.DatabaseRawQueryRequest,
) -> common.DatabaseQueryResponse {
	queryCString, _ := strings.clone_to_cstring(request.query)
	result := pg.exec(conn, queryCString)
	if result == nil {
		return databaseErrorResponse(.RawSQL, cloneCStringOrEmpty(pg.error_message(conn)))
	}
	defer pg.clear(result)

	status := pg.result_status(result)
	if status == .Fatal_Error || status == .Bad_Response {
		return databaseErrorResponse(.RawSQL, cloneCStringOrEmpty(pg.result_error_message(result)))
	}

	return common.DatabaseQueryResponse {
		queryType = .RawSQL,
		success = true,
		message = "ok",
		result = cloneCStringOrEmpty(pg.res_status(status)),
	}
}

databaseExecuteAuthLookup :: proc(
	conn: pg.Conn,
	request: common.DatabaseAuthLookupRequest,
) -> common.DatabaseQueryResponse {
	nicknameCString, _ := strings.clone_to_cstring(request.nickname)
	paramValues := [?][^]byte{transmute([^]byte)nicknameCString}
	result := pg.exec_params(
		conn,
		"SELECT id::text FROM users WHERE nickname = $1 LIMIT 1",
		1,
		nil,
		raw_data(paramValues[:]),
		nil,
		nil,
		.Text,
	)
	if result == nil {
		return databaseErrorResponse(
			.AuthLookupByNickname,
			cloneCStringOrEmpty(pg.error_message(conn)),
		)
	}
	defer pg.clear(result)

	status := pg.result_status(result)
	if status != .Tuples_OK {
		return databaseErrorResponse(
			.AuthLookupByNickname,
			cloneCStringOrEmpty(pg.result_error_message(result)),
		)
	}

	lookupResult := ""
	if pg.n_tuples(result) > 0 && !pg.get_is_null(result, 0, 0) {
		lookupResult = cloneCStringOrEmpty(cstring(pg.get_value(result, 0, 0)))
	}

	return common.DatabaseQueryResponse {
		queryType = .AuthLookupByNickname,
		success = true,
		message = "ok",
		result = lookupResult,
	}
}

databaseResultError :: proc(
	queryType: common.DatabaseQueryType,
	result: ^pg.Result,
) -> common.DatabaseQueryResponse {
	return databaseErrorResponse(queryType, cloneCStringOrEmpty(pg.result_error_message(result^)))
}

databaseExecuteListRoomsForUser :: proc(
	conn: pg.Conn,
	request: common.DatabaseRoomListRequest,
) -> common.DatabaseQueryResponse {
	userIDText := fmt.aprintf("%d", request.userId)
	defer delete(userIDText)
	userIDCString, _ := strings.clone_to_cstring(userIDText)
	defer delete(userIDCString)
	paramValues := [?][^]byte{transmute([^]byte)userIDCString}
	result := pg.exec_params(
		conn,
		"SELECT r.id::text, r.name, r.description FROM rooms r " +
		"JOIN room_members rm ON rm.room_id = r.id " +
		"WHERE rm.user_id = $1 ORDER BY r.name",
		1,
		nil,
		raw_data(paramValues[:]),
		nil,
		nil,
		.Text,
	)
	if result == nil {
		return databaseErrorResponse(
			.ListRoomsForUser,
			cloneCStringOrEmpty(pg.error_message(conn)),
		)
	}
	defer pg.clear(result)
	if pg.result_status(result) != .Tuples_OK {
		return databaseResultError(.ListRoomsForUser, &result)
	}

	response := common.DatabaseQueryResponse {
		queryType = .ListRoomsForUser,
		success   = true,
		message   = "ok",
	}
	for row in 0 ..< pg.n_tuples(result) {
		roomIDText := cloneCStringOrEmpty(cstring(pg.get_value(result, row, 0)))
		roomID, roomIDOK := strconv.parse_int(roomIDText)
		delete(roomIDText)
		if !roomIDOK {
			continue
		}
		append(
			&response.roomSummaries,
			common.RoomSummary {
				id = int(roomID),
				name = cloneCStringOrEmpty(cstring(pg.get_value(result, row, 1))),
				description = cloneCStringOrEmpty(cstring(pg.get_value(result, row, 2))),
			},
		)
	}
	return response
}

databaseExecuteCheckRoomMembership :: proc(
	conn: pg.Conn,
	request: common.DatabaseRoomMembershipRequest,
) -> common.DatabaseQueryResponse {
	roomIDText := fmt.aprintf("%d", request.roomId)
	defer delete(roomIDText)
	roomIDCString, _ := strings.clone_to_cstring(roomIDText)
	defer delete(roomIDCString)
	userIDText := fmt.aprintf("%d", request.userId)
	defer delete(userIDText)
	userIDCString, _ := strings.clone_to_cstring(userIDText)
	defer delete(userIDCString)
	paramValues := [?][^]byte{transmute([^]byte)roomIDCString, transmute([^]byte)userIDCString}
	result := pg.exec_params(
		conn,
		"SELECT EXISTS(SELECT 1 FROM room_members WHERE room_id = $1 AND user_id = $2)",
		2,
		nil,
		raw_data(paramValues[:]),
		nil,
		nil,
		.Text,
	)
	if result == nil {
		return databaseErrorResponse(
			.CheckRoomMembership,
			cloneCStringOrEmpty(pg.error_message(conn)),
		)
	}
	defer pg.clear(result)
	if pg.result_status(result) != .Tuples_OK {
		return databaseResultError(.CheckRoomMembership, &result)
	}

	isMember := false
	if pg.n_tuples(result) == 1 {
		value := cloneCStringOrEmpty(cstring(pg.get_value(result, 0, 0)))
		isMember = value == "t"
		delete(value)
	}
	return common.DatabaseQueryResponse {
		queryType = .CheckRoomMembership,
		success = true,
		message = "ok",
		isRoomMember = isMember,
	}
}

databaseExecuteListRoomMemberUserIDs :: proc(
	conn: pg.Conn,
	request: common.DatabaseRoomMemberListRequest,
) -> common.DatabaseQueryResponse {
	roomIDText := fmt.aprintf("%d", request.roomId)
	defer delete(roomIDText)
	roomIDCString, _ := strings.clone_to_cstring(roomIDText)
	defer delete(roomIDCString)
	paramValues := [?][^]byte{transmute([^]byte)roomIDCString}
	result := pg.exec_params(
		conn,
		"SELECT user_id::text FROM room_members WHERE room_id = $1",
		1,
		nil,
		raw_data(paramValues[:]),
		nil,
		nil,
		.Text,
	)
	if result == nil {
		return databaseErrorResponse(
			.ListRoomMemberUserIDs,
			cloneCStringOrEmpty(pg.error_message(conn)),
		)
	}
	defer pg.clear(result)
	if pg.result_status(result) != .Tuples_OK {
		return databaseResultError(.ListRoomMemberUserIDs, &result)
	}

	response := common.DatabaseQueryResponse {
		queryType = .ListRoomMemberUserIDs,
		success   = true,
		message   = "ok",
	}
	for row in 0 ..< pg.n_tuples(result) {
		userIDText := cloneCStringOrEmpty(cstring(pg.get_value(result, row, 0)))
		userID, userIDOK := strconv.parse_int(userIDText)
		delete(userIDText)
		if userIDOK {
			append(&response.memberUserIDs, int(userID))
		}
	}
	return response
}

databaseExecuteStoreRoomChatMessage :: proc(
	conn: pg.Conn,
	request: common.DatabaseStoreRoomChatMessageRequest,
) -> common.DatabaseQueryResponse {
	roomIDText := fmt.aprintf("%d", request.roomId)
	defer delete(roomIDText)
	roomIDCString, _ := strings.clone_to_cstring(roomIDText)
	defer delete(roomIDCString)
	senderIDText := fmt.aprintf("%d", request.senderId)
	defer delete(senderIDText)
	senderIDCString, _ := strings.clone_to_cstring(senderIDText)
	defer delete(senderIDCString)
	contentCString, _ := strings.clone_to_cstring(request.content)
	defer delete(contentCString)
	paramValues := [?][^]byte {
		transmute([^]byte)roomIDCString,
		transmute([^]byte)senderIDCString,
		transmute([^]byte)contentCString,
	}
	result := pg.exec_params(
		conn,
		"INSERT INTO chat_messages (room_id, sender_user_id, content) VALUES ($1, $2, $3) " +
		"RETURNING id::text, created_at::text",
		3,
		nil,
		raw_data(paramValues[:]),
		nil,
		nil,
		.Text,
	)
	if result == nil {
		return databaseErrorResponse(
			.StoreRoomChatMessage,
			cloneCStringOrEmpty(pg.error_message(conn)),
		)
	}
	defer pg.clear(result)
	if pg.result_status(result) != .Tuples_OK || pg.n_tuples(result) != 1 {
		return databaseResultError(.StoreRoomChatMessage, &result)
	}

	messageIDText := cloneCStringOrEmpty(cstring(pg.get_value(result, 0, 0)))
	messageID, messageIDOK := strconv.parse_int(messageIDText)
	delete(messageIDText)
	if !messageIDOK {
		return databaseErrorResponse(.StoreRoomChatMessage, "database returned invalid message ID")
	}
	return common.DatabaseQueryResponse {
		queryType = .StoreRoomChatMessage,
		success = true,
		message = "ok",
		storedChatMessage = {
			id = int(messageID),
			senderId = request.senderId,
			roomId = request.roomId,
			timestamp = cloneCStringOrEmpty(cstring(pg.get_value(result, 0, 1))),
			content = strings.clone(request.content),
		},
	}
}

databaseExecuteGetRoomHistory :: proc(
	conn: pg.Conn,
	request: common.DatabaseRoomHistoryRequest,
) -> common.DatabaseQueryResponse {
	limit := request.limit
	if limit < 1 || limit > 50 {
		limit = 50
	}
	roomIDText := fmt.aprintf("%d", request.roomId)
	defer delete(roomIDText)
	roomIDCString, _ := strings.clone_to_cstring(roomIDText)
	defer delete(roomIDCString)
	beforeMessageIDText := fmt.aprintf("%d", request.beforeMessageID)
	defer delete(beforeMessageIDText)
	beforeMessageIDCString, _ := strings.clone_to_cstring(beforeMessageIDText)
	defer delete(beforeMessageIDCString)
	limitText := fmt.aprintf("%d", limit + 1)
	defer delete(limitText)
	limitCString, _ := strings.clone_to_cstring(limitText)
	defer delete(limitCString)
	paramValues := [?][^]byte {
		transmute([^]byte)roomIDCString,
		transmute([^]byte)beforeMessageIDCString,
		transmute([^]byte)limitCString,
	}
	result := pg.exec_params(
		conn,
		"SELECT id::text, sender_user_id::text, created_at::text, content FROM chat_messages " +
		"WHERE room_id = $1 AND ($2::bigint = 0 OR id < $2::bigint) " +
		"ORDER BY id DESC LIMIT $3",
		3,
		nil,
		raw_data(paramValues[:]),
		nil,
		nil,
		.Text,
	)
	if result == nil {
		return databaseErrorResponse(.GetRoomHistory, cloneCStringOrEmpty(pg.error_message(conn)))
	}
	defer pg.clear(result)
	if pg.result_status(result) != .Tuples_OK {
		return databaseResultError(.GetRoomHistory, &result)
	}

	rowCount := int(pg.n_tuples(result))
	response := common.DatabaseQueryResponse {
		queryType       = .GetRoomHistory,
		success         = true,
		message         = "ok",
		hasOlderHistory = rowCount > limit,
	}
	messageCount := min(rowCount, limit)
	for offset in 0 ..< messageCount {
		row := i32(messageCount - offset - 1)
		messageIDText := cloneCStringOrEmpty(cstring(pg.get_value(result, row, 0)))
		messageID, messageIDOK := strconv.parse_int(messageIDText)
		delete(messageIDText)
		senderIDText := cloneCStringOrEmpty(cstring(pg.get_value(result, row, 1)))
		senderID, senderIDOK := strconv.parse_int(senderIDText)
		delete(senderIDText)
		if !messageIDOK || !senderIDOK {
			continue
		}
		append(
			&response.historyMessages,
			common.StoredChatMessage {
				id = int(messageID),
				senderId = int(senderID),
				roomId = request.roomId,
				timestamp = cloneCStringOrEmpty(cstring(pg.get_value(result, row, 2))),
				content = cloneCStringOrEmpty(cstring(pg.get_value(result, row, 3))),
			},
		)
	}
	return response
}

databaseExecuteRequest :: proc(
	conn: pg.Conn,
	request: common.DatabaseQueryRequest,
) -> common.DatabaseQueryResponse {
	switch request.queryType {
	case .AuthLookupByNickname:
		return databaseExecuteAuthLookup(conn, request.authLookup)
	case .RawSQL:
		return databaseExecuteRawQuery(conn, request.rawSQL)
	case .ListRoomsForUser:
		return databaseExecuteListRoomsForUser(conn, request.roomList)
	case .CheckRoomMembership:
		return databaseExecuteCheckRoomMembership(conn, request.membership)
	case .ListRoomMemberUserIDs:
		return databaseExecuteListRoomMemberUserIDs(conn, request.memberList)
	case .StoreRoomChatMessage:
		return databaseExecuteStoreRoomChatMessage(conn, request.storeChat)
	case .GetRoomHistory:
		return databaseExecuteGetRoomHistory(conn, request.history)
	case .None:
		return databaseErrorResponse(.None, "missing database query type")
	case:
		return databaseErrorResponse(request.queryType, "unsupported database query type")
	}
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

	readyErr := IPC_Client_send(pm.config.databaseFd, DatabaseStartupReady{})
	if readyErr != nil {
		fmt.eprintfln("[Database] Failed to report startup readiness")
		return
	}

	running := true
	for running {
		message, err := IPC_Client_poll(pm.config.databaseFd)
		if err != nil {
			time.sleep(1 * time.Millisecond)
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
