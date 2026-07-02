package server

import "../common"
import "core:fmt"
import "core:os"
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

databaseExecuteRequest :: proc(
	conn: pg.Conn,
	request: common.DatabaseQueryRequest,
) -> common.DatabaseQueryResponse {
	switch request.queryType {
	case .AuthLookupByNickname:
		return databaseExecuteAuthLookup(conn, request.authLookup)
	case .RawSQL:
		return databaseExecuteRawQuery(conn, request.rawSQL)
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
