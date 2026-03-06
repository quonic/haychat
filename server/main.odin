package server

import "../common"
import "core:encoding/cbor"
import "core:fmt"
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

MainRouterState_sendPeerPacket :: proc(pm: ^ProcessManager, peerID: u32, packetBytes: []u8) {
	IPC_Server_send(
		&pm.config.networkSocket,
		pm.config.networkFd,
		NetworkSendData{peerId = peerID, channel = .Chat, data = packetBytes},
	)
}

MainRouterState_sendPeerMessage :: proc(
	pm: ^ProcessManager,
	peerID: u32,
	messageType: common.MessageType,
	payload: any,
) -> bool {
	payloadBytes, payloadErr := cbor.marshal(payload)
	if payloadErr != nil {
		fmt.printf("[Main] Failed to encode payload for peer %d: %v\n", peerID, payloadErr)
		return false
	}
	defer delete(payloadBytes)

	packet := common.Packet {
		messageType = messageType,
		payload     = payloadBytes,
	}

	packetBytes, packetErr := cbor.marshal(packet)
	if packetErr != nil {
		fmt.printf("[Main] Failed to encode packet for peer %d: %v\n", peerID, packetErr)
		return false
	}

	MainRouterState_sendPeerPacket(pm, peerID, packetBytes)
	return true
}

MainRouterState_sendProtocolError :: proc(pm: ^ProcessManager, peerID: u32, message: string) {
	MainRouterState_sendPeerMessage(
		pm,
		peerID,
		common.MessageType.ServerProtocolError,
		common.ProtocolErrorResponse{message = message},
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

	if len(msg.data) == 0 {
		return
	}

	packet: common.Packet
	packetErr := cbor.unmarshal(msg.data, &packet)
	if packetErr != nil {
		MainRouterState_sendProtocolError(pm, msg.peerId, "Invalid CBOR packet")
		return
	}
	defer delete(packet.payload)

	#partial switch packet.messageType {
	case .ClientAuthLookup:
		req: common.ClientAuthLookupRequest
		err := cbor.unmarshal(packet.payload, &req)
		if err != nil || len(req.nickname) == 0 {
			MainRouterState_sendPeerMessage(
				pm,
				msg.peerId,
				common.MessageType.ServerAuthLookupResponse,
				common.ServerAuthLookupResult {
					success = false,
					message = "missing nickname",
					result = "",
				},
			)
			return
		}

		// NOTE: query generation is intentionally simple here and should be parameterized.
		query := fmt.aprintf("SELECT id FROM users WHERE nickname = '%s' LIMIT 1;", req.nickname)
		requestID := MainRouterState_generateRequestID(state)
		MainRouterState_enqueueDatabaseRequest(state, requestID, msg.peerId, .Auth)
		IPC_Server_send(
			&pm.config.databaseSocket,
			pm.config.databaseFd,
			DatabaseQuery{request_id = requestID, query = query},
		)
	case .ClientStoreFile:
		req: common.ClientStoreFileRequest
		err := cbor.unmarshal(packet.payload, &req)
		if err != nil || len(req.filename) == 0 || len(req.content) == 0 {
			MainRouterState_sendPeerMessage(
				pm,
				msg.peerId,
				common.MessageType.ServerStoreFileResponse,
				common.ServerStoreFileResult {
					success = false,
					message = "invalid payload",
					hashedFilename = "",
				},
			)
			return
		}

		hashedName, ok := saveFile(pm.config, req.content, req.filename, int(msg.peerId))
		if !ok {
			MainRouterState_sendPeerMessage(
				pm,
				msg.peerId,
				common.MessageType.ServerStoreFileResponse,
				common.ServerStoreFileResult {
					success = false,
					message = "failed to save file",
					hashedFilename = "",
				},
			)
			return
		}

		MainRouterState_sendPeerMessage(
			pm,
			msg.peerId,
			common.MessageType.ServerStoreFileResponse,
			common.ServerStoreFileResult {
				success = true,
				message = "ok",
				hashedFilename = hashedName,
			},
		)
	case .ClientDatabaseQuery:
		req: common.ClientDatabaseQueryRequest
		err := cbor.unmarshal(packet.payload, &req)
		if err != nil || len(req.query) == 0 {
			MainRouterState_sendPeerMessage(
				pm,
				msg.peerId,
				common.MessageType.ServerDatabaseQueryResponse,
				common.ServerDatabaseQueryResult {
					success = false,
					message = "empty query",
					result = "",
				},
			)
			return
		}

		requestID := MainRouterState_generateRequestID(state)
		MainRouterState_enqueueDatabaseRequest(state, requestID, msg.peerId, .Generic)
		IPC_Server_send(
			&pm.config.databaseSocket,
			pm.config.databaseFd,
			DatabaseQuery{request_id = requestID, query = req.query},
		)
	case:
		MainRouterState_sendProtocolError(pm, msg.peerId, "Unsupported message type")
	}
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
			MainRouterState_sendPeerMessage(
				pm,
				request.peerID,
				common.MessageType.ServerAuthLookupResponse,
				common.ServerAuthLookupResult{success = false, message = result, result = ""},
			)
		} else {
			MainRouterState_sendPeerMessage(
				pm,
				request.peerID,
				common.MessageType.ServerAuthLookupResponse,
				common.ServerAuthLookupResult{success = true, message = "ok", result = result},
			)
		}
	case .Generic:
		if isError {
			MainRouterState_sendPeerMessage(
				pm,
				request.peerID,
				common.MessageType.ServerDatabaseQueryResponse,
				common.ServerDatabaseQueryResult{success = false, message = result, result = ""},
			)
		} else {
			MainRouterState_sendPeerMessage(
				pm,
				request.peerID,
				common.MessageType.ServerDatabaseQueryResponse,
				common.ServerDatabaseQueryResult{success = true, message = "ok", result = result},
			)
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
