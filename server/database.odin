package server

import "../common"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "shared:pg"

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

// Database process entry point
// Manages PostgreSQL connection pool and handles database queries from main process
databaseServerLoop :: proc(pm: ^ProcessManager) {
	fmt.printfln("[Database] Database server loop started (PID: %d)", os.get_pid())
	// Connect to PostgreSQL database using shared:pg
	db_connection := pg.connectdb(
		fmt.caprintf(
			"host=%s port=%d user=%s password=%s dbname=%s",
			pm.config.databaseURL,
			pm.config.databasePort,
			pm.config.databaseUser,
			pm.config.databasePass,
			pm.config.databaseName,
		),
	)
	defer pg.finish(db_connection)

	databaseFd, ipcInitErr := IPC_Client_init(&pm.config.databaseSocket)
	if ipcInitErr != nil {
		fmt.eprintfln("[Database] Failed to initialize coordinator endpoint: %s", ipcInitErr)
		return
	}
	pm.config.databaseFd = databaseFd
	defer IPC_Client_deinit(&pm.config.databaseSocket)

	running := true
	for running {
		message, err := IPC_Client_poll(pm.config.databaseFd)
		if err != nil {
			time.sleep(1 * time.Millisecond)
			continue
		}

		#partial switch msg in message {
		case DatabaseQuery:
			response := databaseExecuteRequest(db_connection, msg.request)
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
