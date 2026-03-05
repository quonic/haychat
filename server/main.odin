package server

import "core:fmt"
import "core:strings"
import "core:thread"
import "core:time"

PendingDBRequestType :: enum {
	Auth,
	Generic,
}

PendingDBRequest :: struct {
	requestID:   u64,
	peerID:      u32,
	requestType: PendingDBRequestType,
}

MainRouterState :: struct {
	connectedPeers:          map[u32]bool,
	pendingDatabaseRequests: map[u64]PendingDBRequest,
	nextRequestID:           u64,
}

MainRouterState_init :: proc() -> MainRouterState {
	return MainRouterState {
		connectedPeers = make(map[u32]bool),
		pendingDatabaseRequests = make(map[u64]PendingDBRequest),
		nextRequestID = 1,
	}
}

MainRouterState_deinit :: proc(state: ^MainRouterState) {
	delete(state.connectedPeers)
	delete(state.pendingDatabaseRequests)
}

MainRouterState_generateRequestID :: proc(state: ^MainRouterState) -> u64 {
	id := state.nextRequestID
	state.nextRequestID += 1
	return id
}

MainRouterState_makeBytesFromString :: proc(text: string) -> []u8 {
	buf := make([dynamic]u8, 0, len(text))
	for i in 0 ..< len(text) {
		append(&buf, text[i])
	}
	return buf[:]
}

MainRouterState_sendPeerText :: proc(pm: ^ProcessManager, peerID: u32, text: string) {
	payload := MainRouterState_makeBytesFromString(text)
	IPC_Server_send(
		&pm.config.networkSocket,
		pm.config.networkFd,
		NetworkSendData{peerId = peerID, channel = .Chat, data = payload},
	)
}

MainRouterState_enqueueDatabaseRequest :: proc(
	state: ^MainRouterState,
	requestID: u64,
	peerID: u32,
	requestType: PendingDBRequestType,
) {
	state.pendingDatabaseRequests[requestID] = PendingDBRequest {
		requestID   = requestID,
		peerID      = peerID,
		requestType = requestType,
	}
}

MainRouterState_getDatabaseRequest :: proc(
	state: ^MainRouterState,
	requestID: u64,
) -> (
	PendingDBRequest,
	bool,
) {
	request, ok := state.pendingDatabaseRequests[requestID]
	if ok {
		delete_key(&state.pendingDatabaseRequests, requestID)
	}
	return request, ok
}

MainRouterState_handleNetworkDataReceived :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	msg: NetworkDataReceived,
) {
	if msg.channel != .Chat {
		return
	}

	payload := strings.trim(string(msg.data), " \t\r\n")
	if len(payload) == 0 {
		return
	}

	if strings.starts_with(payload, "AUTH ") {
		nickname := strings.trim(payload[len("AUTH "):], " \t\r\n")
		if len(nickname) == 0 {
			MainRouterState_sendPeerText(pm, msg.peerId, "AUTH_ERROR missing nickname")
			return
		}

		// NOTE: query generation is intentionally simple here and should be parameterized.
		query := fmt.aprintf("SELECT id FROM users WHERE nickname = '%s' LIMIT 1;", nickname)
		requestID := MainRouterState_generateRequestID(state)
		MainRouterState_enqueueDatabaseRequest(state, requestID, msg.peerId, .Auth)
		IPC_Server_send(
			&pm.config.databaseSocket,
			pm.config.databaseFd,
			DatabaseQuery{request_id = requestID, query = query},
		)
		return
	}

	if strings.starts_with(payload, "STORE ") {
		storePayload := payload[len("STORE "):]
		delimiter := -1
		for ch, idx in storePayload {
			if ch == '|' {
				delimiter = idx
				break
			}
		}

		if delimiter <= 0 || delimiter >= len(storePayload) - 1 {
			MainRouterState_sendPeerText(
				pm,
				msg.peerId,
				"STORE_ERROR expected format STORE <filename>|<content>",
			)
			return
		}

		filename := strings.trim(storePayload[:delimiter], " \t\r\n")
		fileContent := storePayload[delimiter + 1:]
		if len(filename) == 0 || len(fileContent) == 0 {
			MainRouterState_sendPeerText(pm, msg.peerId, "STORE_ERROR invalid payload")
			return
		}

		hashedName, ok := saveFile(
			pm.config,
			transmute([]u8)fileContent,
			filename,
			int(msg.peerId),
		)
		if !ok {
			MainRouterState_sendPeerText(pm, msg.peerId, "STORE_ERROR failed to save file")
			return
		}

		MainRouterState_sendPeerText(pm, msg.peerId, fmt.aprintf("STORE_OK %s", hashedName))
		return
	}

	if strings.starts_with(payload, "DB ") {
		query := strings.trim(payload[len("DB "):], " \t\r\n")
		if len(query) == 0 {
			MainRouterState_sendPeerText(pm, msg.peerId, "DB_ERROR empty query")
			return
		}

		requestID := MainRouterState_generateRequestID(state)
		MainRouterState_enqueueDatabaseRequest(state, requestID, msg.peerId, .Generic)
		IPC_Server_send(
			&pm.config.databaseSocket,
			pm.config.databaseFd,
			DatabaseQuery{request_id = requestID, query = query},
		)
		return
	}

	MainRouterState_sendPeerText(
		pm,
		msg.peerId,
		"UNKNOWN_COMMAND expected AUTH, STORE, or DB prefixes",
	)
}

MainRouterState_handleDatabaseResult :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	requestID: u64,
	result: string,
	isError: bool,
) {
	request, ok := MainRouterState_getDatabaseRequest(state, requestID)
	if !ok {
		fmt.printf("[Main] Received database response for unknown request ID %d\n", requestID)
		return
	}

	switch request.requestType {
	case .Auth:
		if isError {
			MainRouterState_sendPeerText(pm, request.peerID, fmt.aprintf("AUTH_ERROR %s", result))
		} else {
			MainRouterState_sendPeerText(
				pm,
				request.peerID,
				fmt.aprintf("AUTH_DB_RESULT %s", result),
			)
		}
	case .Generic:
		if isError {
			MainRouterState_sendPeerText(pm, request.peerID, fmt.aprintf("DB_ERROR %s", result))
		} else {
			MainRouterState_sendPeerText(pm, request.peerID, fmt.aprintf("DB_RESULT %s", result))
		}
	case:
	}
}

main :: proc() {
	fmt.println("=== HayChat Server - Threaded Architecture ===")
	fmt.println()

	config := loadConfig()
	fmt.println("Configuration loaded:")
	fmt.printf("  Web Admin: %s:%d\n", config.webAdminHost, config.webAdminPort)
	fmt.printf(
		"  Database: %s@%s:%d/%s\n",
		config.databaseUser,
		config.databaseURL,
		config.databasePort,
		config.databaseName,
	)
	fmt.printf(
		"  Max Restarts: %d (backoff: %v-%v)\n",
		config.maxRestarts,
		config.restartBackoffMin,
		config.restartBackoffMax,
	)
	fmt.println()

	config.networkSocketName = fmt.aprintf("%s_network", SERVER_SOCKET)
	config.webAdminSocketName = fmt.aprintf("%s_webadmin", SERVER_SOCKET)
	config.databaseSocketName = fmt.aprintf("%s_database", SERVER_SOCKET)

	pm := initProcessManager(&config)

	fmt.println("=== Starting Service Threads ===")
	if !spawnProcess(&pm, .Network) {
		fmt.println("[Network] Failed to start network service thread")
		return
	}
	if !spawnProcess(&pm, .WebAdmin) {
		fmt.println("[WebAdmin] Failed to start web admin service thread")
		return
	}
	if !spawnProcess(&pm, .Database) {
		fmt.println("[Database] Failed to start database service thread")
		return
	}

	fmt.println("\n=== Server Running ===")
	fmt.println("Main thread is supervising network, web admin, and database threads")
	fmt.println()

	mainLoop(&pm)

	fmt.println("\n=== Server Shutdown Complete ===")
}

@(private)
mainLoop :: proc(pm: ^ProcessManager) {
	running := true
	routerState := MainRouterState_init()
	defer MainRouterState_deinit(&routerState)

	for running {
		msg, err := IPC_Client_poll(pm.config.mainFd)
		if err == nil {
			switch m in msg {
			case NetworkSendData, NetworkBroadcast, NetworkDisconnectPeer:
			// Commands are generated by main and should not loop back here.
			case NetworkPeerConnected:
				routerState.connectedPeers[m.peerId] = true
			case NetworkPeerDisconnected:
				delete_key(&routerState.connectedPeers, m.peerId)
			case NetworkDataReceived:
				MainRouterState_handleNetworkDataReceived(pm, &routerState, m)
				delete(m.data)
			case AdminQueryStatus:
				uptime := i64(time.duration_seconds(time.since(pm.startTime)))
				response := AdminQueryStatusResponse {
					uptime         = uptime,
					connectedPeers = len(routerState.connectedPeers),
				}
				IPC_Server_send(&pm.config.webAdminSocket, pm.config.webAdminFd, response)
			case AdminQueryStatusResponse, AdminGetPeersResponse, AdminGetLogsResponse:
			// Responses are consumed by web admin.
			case AdminGetPeers:
				IPC_Server_send(
					&pm.config.webAdminSocket,
					pm.config.webAdminFd,
					AdminGetPeersResponse{peers = make([dynamic]NetworkPeerInfo)[:]},
				)
			case AdminGetLogs:
				IPC_Server_send(
					&pm.config.webAdminSocket,
					pm.config.webAdminFd,
					AdminGetLogsResponse {
						logs = []string{"Logs are not wired yet in threaded mode."},
					},
				)
			case DatabaseQuery:
				IPC_Server_send(&pm.config.databaseSocket, pm.config.databaseFd, m)
			case DatabaseQueryResult:
				MainRouterState_handleDatabaseResult(
					pm,
					&routerState,
					m.request_id,
					m.result,
					false,
				)
			case DatabaseError:
				MainRouterState_handleDatabaseResult(pm, &routerState, m.request_id, m.error, true)
			case ProcessShutdown:
				running = false
			case ProcessRestart:
				restartProcess(pm, .Network)
				restartProcess(pm, .WebAdmin)
				restartProcess(pm, .Database)
			case Wake:
				IPC_Server_send(&pm.config.webAdminSocket, pm.config.webAdminFd, Wake{})
			case ProcessError:
				fmt.printf("[Main] Process error: %s\n", m.error)
			case:
			}
		}

		if !pm.shouldShutdown {
			if !pm.networkProcess.isRunning {
				restartProcess(pm, .Network)
			}
			if !pm.webAdminProcess.isRunning {
				restartProcess(pm, .WebAdmin)
			}
			if !pm.databaseProcess.isRunning {
				restartProcess(pm, .Database)
			}
		}

		thread.yield()
	}

	shutdownAllProcesses(pm)
}
