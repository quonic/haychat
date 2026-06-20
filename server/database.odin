package server

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:time"
import "shared:pg"

// Database process entry point
// Manages PostgreSQL connection pool and handles database queries from main process
databaseServerLoop :: proc(pm: ^ProcessManager) {

	messageQueue: [dynamic]Message // Simple in-memory queue for incoming queries
	currentRequestID: u64 = 0 // Track the request_id for the current query

	log.infof("[Database] Database server loop started (PID: %d)", os.get_pid())
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
		log.errorf("[Database] Failed to initialize coordinator endpoint: %s", ipcInitErr)
		return
	}
	pm.config.databaseFd = databaseFd
	defer IPC_Client_deinit(&pm.config.databaseSocket)

	// Main event loop
	running := true
	for running {
		message, err := IPC_Client_poll(pm.config.databaseFd)
		if err != nil && message != nil {
			log.errorf("[Database] IPC poll error: %s, %s", err, message)
			continue
		}
		if message != nil {
			append(&messageQueue, message)
		}

		if pg.is_busy(db_connection) == true {
			// Still waiting for query result, check for shutdown/restart signals
			for message in messageQueue {
				switch typeid_of(type_of(message)) {
				case ProcessShutdown:
					log.infof("[Database] Received shutdown signal")
					running = false
				case ProcessRestart:
					log.infof("[Database] Received restart signal")
					// For simplicity, we'll just break the loop and let the process manager restart us
					running = false
				case Wake:
				// No-op, just wake up to check for shutdown/restart signals
				case:
				// Ignore other messages while waiting for query result
				}
			}
			// Clear the message queue after processing shutdown/restart signals
			messageQueue = [dynamic]Message{}
			continue
		} else if pg.is_busy(db_connection) == false {
			// Query result is ready, send it back to main process
			result := pg.get_result(db_connection)
			if result != nil {
				result_status := pg.result_status(result) // Clear the result to free memory
				log.errorf("[Database] Query result: %s", result_status)
				IPC_Client_send(
					pm.config.databaseFd,
					DatabaseQueryResult {
						request_id = currentRequestID,
						result = fmt.aprintf("%s", result_status),
					},
				)
				pg.clear(result)
			}
		}

		for message in messageQueue {
			switch typeid_of(type_of(message)) {
			case DatabaseQuery:
				dbQuery := message.(DatabaseQuery)
				currentRequestID = dbQuery.request_id
				query := dbQuery.query
				log.infof("[Database] Received query: %s", query)
				if pg.send_query(db_connection, strings.clone_to_cstring(query)) == false {
					error_msg := fmt.aprintf("Failed to send query: %s", query)
					log.errorf("[Database] %s", error_msg)
					IPC_Client_send(
						pm.config.databaseFd,
						DatabaseError{request_id = currentRequestID, error = error_msg},
					)
					continue
				}
			case ProcessShutdown:
				log.infof("[Database] Received shutdown signal")
				running = false
			case ProcessRestart:
				log.infof("[Database] Received restart signal")
				// For simplicity, we'll just break the loop and let the process manager restart us
				running = false
			case Wake:
			// No-op, just wake up to check for shutdown/restart signals
			case:
				log.errorf("[Database] Received unknown message type")
			}
		}
		time.sleep(1 * time.Millisecond)
	}

	log.infof("[Database] Process shutting down")
}
