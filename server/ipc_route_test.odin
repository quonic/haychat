package server

import "../common"
import "core:sys/linux"
import "core:testing"

// ipcRouteTestEndpoint registers a service endpoint the way each service process does at
// startup. The socket name decides the endpoint kind.
ipcRouteTestEndpoint :: proc(socketName: string) -> linux.Fd {
	ctx := IPC_Server_Context{}
	serverErr := IPC_Server_init(&ctx, socketName)
	assert(serverErr == nil, "expected IPC server init to succeed")
	fd, clientErr := IPC_Client_init(&ctx)
	assert(clientErr == nil, "expected IPC client init to succeed")
	return fd
}

ipcRouteTestQueueIsEmpty :: proc(fd: linux.Fd) -> bool {
	msg, err := IPC_Client_poll(fd)
	if err == nil {
		IPC__message_deinit(&msg)
		return false
	}
	return true
}

@(test)
testIPCClientSendFromMainRoutesEachMessageToItsService :: proc(t: ^testing.T) {
	_ = t

	networkTestResetIPCState()
	defer networkTestResetIPCState()

	mainFd := IPC_Main_init()
	networkFd := ipcRouteTestEndpoint("ipc_route_test_network")
	webAdminFd := ipcRouteTestEndpoint("ipc_route_test_webadmin")
	databaseFd := ipcRouteTestEndpoint("ipc_route_test_database")

	assert(
		IPC_Client_send(mainFd, NetworkDisconnectPeer{peerId = 7}) == nil,
		"expected Main to route NetworkDisconnectPeer, got an error",
	)
	assert(
		IPC_Client_send(mainFd, AdminQueryStatusResponse{connectedPeers = 3}) == nil,
		"expected Main to route AdminQueryStatusResponse, got an error",
	)
	assert(
		IPC_Client_send(
			mainFd,
			DatabaseQuery {
				request_id = 11,
				request = common.DatabaseRoomListRequest{userId = 5},
			},
		) ==
		nil,
		"expected Main to route DatabaseQuery, got an error",
	)

	networkMsg, networkErr := IPC_Client_poll(networkFd)
	assert(networkErr == nil, "expected the network queue to hold the disconnect")
	disconnect, isDisconnect := networkMsg.(NetworkDisconnectPeer)
	assert(
		isDisconnect && disconnect.peerId == 7,
		"expected NetworkDisconnectPeer{peerId = 7} on the network queue",
	)
	IPC__message_deinit(&networkMsg)

	webAdminMsg, webAdminErr := IPC_Client_poll(webAdminFd)
	assert(webAdminErr == nil, "expected the web admin queue to hold the status response")
	status, isStatus := webAdminMsg.(AdminQueryStatusResponse)
	assert(
		isStatus && status.connectedPeers == 3,
		"expected AdminQueryStatusResponse{connectedPeers = 3} on the web admin queue",
	)
	IPC__message_deinit(&webAdminMsg)

	databaseMsg, databaseErr := IPC_Client_poll(databaseFd)
	assert(databaseErr == nil, "expected the database queue to hold the query")
	query, isQuery := databaseMsg.(DatabaseQuery)
	assert(isQuery && query.request_id == 11, "expected DatabaseQuery 11 on the database queue")
	IPC__message_deinit(&databaseMsg)

	// Every message went to exactly one queue.
	assert(ipcRouteTestQueueIsEmpty(networkFd), "expected the network queue to be empty")
	assert(ipcRouteTestQueueIsEmpty(webAdminFd), "expected the web admin queue to be empty")
	assert(ipcRouteTestQueueIsEmpty(databaseFd), "expected the database queue to be empty")
	assert(ipcRouteTestQueueIsEmpty(mainFd), "expected the main queue to be empty")
}

@(test)
testIPCClientSendFromMainRefusesMessagesWithoutARoute :: proc(t: ^testing.T) {
	_ = t

	networkTestResetIPCState()
	defer networkTestResetIPCState()

	mainFd := IPC_Main_init()
	networkFd := ipcRouteTestEndpoint("ipc_route_test_network")

	// Shutdown and restart are addressed to one service at a time with IPC_Server_send, and
	// inbound kinds such as NetworkPeerDisconnected have no destination when Main sends them.
	assert(
		IPC_Client_send(mainFd, ProcessShutdown{}) != nil,
		"expected Main's ProcessShutdown to have no route",
	)
	assert(
		IPC_Client_send(mainFd, NetworkPeerDisconnected{peerId = 2}) != nil,
		"expected Main's NetworkPeerDisconnected to have no route",
	)
	assert(ipcRouteTestQueueIsEmpty(networkFd), "expected nothing queued for the network")
	assert(ipcRouteTestQueueIsEmpty(mainFd), "expected nothing queued for main")
}

@(test)
testIPCClientSendFromAServiceRoutesToMain :: proc(t: ^testing.T) {
	_ = t

	networkTestResetIPCState()
	defer networkTestResetIPCState()

	mainFd := IPC_Main_init()
	databaseFd := ipcRouteTestEndpoint("ipc_route_test_database")

	assert(
		IPC_Client_send(databaseFd, DatabaseStartupReady{}) == nil,
		"expected the database endpoint to route to Main",
	)
	msg, err := IPC_Client_poll(mainFd)
	assert(err == nil, "expected the main queue to hold the startup message")
	_, isReady := msg.(DatabaseStartupReady)
	assert(isReady, "expected DatabaseStartupReady on the main queue")
	IPC__message_deinit(&msg)
}
