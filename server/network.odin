package server

import "core:fmt"

import "core:net"
import "core:os"
import "core:sys/linux"
import "vendor:ENet"

NetworkPeerInfo :: struct {
	peerId:  u32,
	address: net.Address, // Remote peer address (IP4 or IP6)
}

// networkServerLoop is the main entry point for the network server process
networkServerLoop :: proc(pm: ^ProcessManager) {
	fmt.printfln("[Network] Network server loop started (PID: %d)", os.get_pid())

	// Initialize ENet
	if ENet.initialize() != 0 {
		fmt.eprint("[Network] Failed to initialize ENet library")
		return
	}
	defer ENet.deinitialize()

	// Create ENet host
	address := ENet.Address {
		host = ENet.HOST_ANY,
		port = u16(pm.config.listenPort),
	}

	enetHost := ENet.host_create(
		&address,
		uint(pm.config.maxNetworkThreads * 16), // Connections per thread estimate
		uint(NetworkChannel.FileTransfer), // Max channels
		0, // Incoming bandwidth
		0, // Outgoing bandwidth
	)

	if enetHost == nil {
		fmt.eprintfln("[Network] Failed to create ENet host on port %d", pm.config.listenPort)
		return
	}
	defer ENet.host_destroy(enetHost)

	fmt.printfln("[Network] ENet host listening on port %d", pm.config.listenPort)

	// Initialize IPC client connection to main process
	client_fd, ipc_err := IPC_Client_init(&pm.config.networkSocket)
	if ipc_err != nil {
		fmt.eprintfln("[Network] Failed to connect to main process via IPC: %v", ipc_err)
		return
	}
	pm.config.networkFd = client_fd
	defer IPC_Client_deinit(&pm.config.networkSocket)

	fmt.println("[Network] Connected to main process via IPC")

	// Initialize peer manager
	peerManager := PeerManager_init()
	defer PeerManager_deinit(&peerManager)

	// Initialize thread pool
	threadPool := NetworkThreadPool_init(
		pm.config.maxNetworkThreads,
		&peerManager,
		int(pm.config.networkFd),
	)
	if !NetworkThreadPool_spawn(&threadPool, pm.config.maxNetworkThreads) {
		fmt.eprint("[Network] Failed to spawn worker threads")
		return
	}
	defer NetworkThreadPool_shutdown(&threadPool)

	fmt.printfln(
		"[Network] Network server initialized with %d worker threads",
		pm.config.maxNetworkThreads,
	)

	// Main server loop
	running := true
	for running {
		// Poll ENet for events with timeout
		enetEvent: ENet.Event
		pollResult := ENet.host_service(enetHost, &enetEvent, 100) // 100ms timeout

		if pollResult > 0 {
			switch enetEvent.type {
			case .CONNECT:
				handlePeerConnect(
					&peerManager,
					&threadPool,
					enetEvent.peer,
					int(pm.config.networkFd),
				)

			case .RECEIVE:
				handlePeerData(
					&peerManager,
					&threadPool,
					enetEvent.peer,
					enetEvent.packet,
					enetEvent.channelID,
					int(pm.config.networkFd),
				)

			case .DISCONNECT:
				handlePeerDisconnect(
					&peerManager,
					&threadPool,
					enetEvent.peer,
					int(pm.config.networkFd),
				)

			case .NONE:
			// Timeout
			}
		}

		// Poll IPC for messages from main process
		ipcMsg, ipcErr := IPC_Client_poll(linux.Fd(pm.config.networkFd))
		if ipcErr == nil && ipcMsg != nil {
			switch msg in ipcMsg {
			case NetworkSendData:
				handleNetworkSendData(&peerManager, &threadPool, msg, enetHost)
				delete(msg.data)

			case NetworkBroadcast:
				handleNetworkBroadcast(&peerManager, &threadPool, msg, enetHost)
				delete(msg.data)

			case NetworkDisconnectPeer:
				handleNetworkDisconnectPeer(&peerManager, &threadPool, msg, enetHost)

			case ProcessShutdown:
				fmt.println("[Network] Received shutdown signal from main process")
				running = false

			case ProcessRestart:
				fmt.println("[Network] Received restart signal from main process")
				running = false

			case Wake:
				// No-op wake signal
				continue

			case NetworkPeerConnected, NetworkPeerDisconnected, NetworkDataReceived:
				// These shouldn't be sent to network process
				fmt.eprintfln("[Network] Received unexpected message type from main process")

			case AdminQueryStatus, AdminQueryStatusResponse, AdminGetPeers, AdminGetPeersResponse:
				// Admin messages not for network process
				fmt.eprintfln("[Network] Received admin message, ignoring")

			case AdminGetLogs, AdminGetLogsResponse:
				// Log messages not for network process
				fmt.eprintfln("[Network] Received log message, ignoring")

			case DatabaseQuery,
			     DatabaseQueryResult,
			     DatabaseError,
			     DatabaseStartupReady,
			     DatabaseStartupFailed:
				// Database messages not for network process
				fmt.eprintfln("[Network] Received database message, ignoring")

			case ProcessError:
				// Process error message
				fmt.eprintfln("[Network] Received process error: %v", msg)
			}
		}
	}

	fmt.println("[Network] Network server shutting down")
}

// handlePeerConnect handles a new incoming peer connection
handlePeerConnect :: proc(
	peerManager: ^PeerManager,
	threadPool: ^NetworkThreadPool,
	enetPeer: ^ENet.Peer,
	ipcFd: int,
) {
	peerId := PeerManager_allocateID(peerManager)

	// Store peer pointer in ENet peer's user data
	enetPeer.data = rawptr(uintptr(peerId))

	// Create peer info and add to manager
	peer := NetworkPeer {
		id       = peerId,
		address  = enetPeer.address,
		enetPeer = enetPeer,
	}

	if !PeerManager_addPeer(peerManager, peer) {
		fmt.eprintfln("[Network] Failed to add peer %d to manager", peerId)
		ENet.peer_disconnect(enetPeer, 0)
		return
	}

	// Assign peer to worker thread
	if !NetworkThreadPool_assignPeer(threadPool, peerId) {
		fmt.eprintfln("[Network] Failed to assign peer %d to worker thread", peerId)
		PeerManager_removePeer(peerManager, peerId)
		ENet.peer_disconnect(enetPeer, 0)
		return
	}

	// Send notification to main process
	msg := NetworkPeerConnected {
		peerId  = peerId,
		address = enetPeer.address,
	}
	IPC_Client_send(linux.Fd(ipcFd), msg)
	fmt.printfln("[Network] New peer connected: ID=%d", peerId)
}

// handlePeerData handles incoming data from a peer
handlePeerData :: proc(
	peerManager: ^PeerManager,
	threadPool: ^NetworkThreadPool,
	enetPeer: ^ENet.Peer,
	packet: ^ENet.Packet,
	channelID: u8,
	ipcFd: int,
) {
	peerId := u32(uintptr(enetPeer.data))

	if peerId == 0 {
		fmt.eprintfln("[Network] Received data from peer with invalid ID")
		ENet.packet_destroy(packet)
		return
	}

	channel := NetworkChannel(channelID)

	// Send data to main process via IPC
	packetData := packet.data[:packet.dataLength]
	packetCopy := make([dynamic]u8, 0, len(packetData))
	for b in packetData {
		append(&packetCopy, b)
	}
	msg := NetworkDataReceived {
		peerId  = peerId,
		channel = channel,
		data    = packetCopy[:],
	}
	IPC_Client_send(linux.Fd(ipcFd), msg)

	// Queue ENet event to worker thread for this peer (for future processing)
	event := ENetEventData {
		peerId = peerId,
		event = {type = .RECEIVE, peer = enetPeer, packet = packet},
	}
	NetworkThreadPool_enqueueToPeer(threadPool, peerId, event)

	ENet.packet_destroy(packet)
}

// handlePeerDisconnect handles a peer disconnection
handlePeerDisconnect :: proc(
	peerManager: ^PeerManager,
	threadPool: ^NetworkThreadPool,
	enetPeer: ^ENet.Peer,
	ipcFd: int,
) {
	peerId := u32(uintptr(enetPeer.data))

	if peerId == 0 {
		return
	}

	// Remove from thread pool assignment
	NetworkThreadPool_removePeer(threadPool, peerId)

	// Remove from peer manager
	PeerManager_removePeer(peerManager, peerId)

	// Send notification to main process
	msg := NetworkPeerDisconnected {
		peerId = peerId,
	}
	IPC_Client_send(linux.Fd(ipcFd), msg)
	fmt.printfln("[Network] Peer disconnected: ID=%d", peerId)
}

// handleNetworkSendData sends data to a specific peer
handleNetworkSendData :: proc(
	peerManager: ^PeerManager,
	threadPool: ^NetworkThreadPool,
	msg: NetworkSendData,
	enetHost: ^ENet.Host,
) {
	_ = threadPool

	if peer, ok := PeerManager_getPeer(peerManager, msg.peerId); ok {
		if peer.enetPeer == nil {
			fmt.eprintfln("[Network] Cannot send data to peer %d (missing ENet peer)", msg.peerId)
			return
		}

		dataPtr: rawptr = nil
		if len(msg.data) > 0 {
			dataPtr = rawptr(&msg.data[0])
		}
		packet := ENet.packet_create(dataPtr, uint(len(msg.data)), {ENet.PacketFlag.RELIABLE})
		if packet == nil {
			fmt.eprintfln("[Network] Failed to allocate ENet packet for peer %d", msg.peerId)
			return
		}

		if ENet.peer_send(peer.enetPeer, u8(msg.channel), packet) != 0 {
			ENet.packet_destroy(packet)
			fmt.eprintfln("[Network] Failed to send data to peer %d", msg.peerId)
			return
		}

		ENet.host_flush(enetHost)
		fmt.printfln(
			"[Network] Sent data to peer %d on channel %v (%d bytes)",
			msg.peerId,
			msg.channel,
			len(msg.data),
		)
	} else {
		fmt.eprintfln("[Network] Cannot send data to peer %d (peer not found)", msg.peerId)
	}
}

// handleNetworkBroadcast broadcasts data to all peers on a specified channel
handleNetworkBroadcast :: proc(
	peerManager: ^PeerManager,
	threadPool: ^NetworkThreadPool,
	msg: NetworkBroadcast,
	enetHost: ^ENet.Host,
) {
	_ = threadPool
	allPeers := PeerManager_getAllPeers(peerManager)
	defer delete(allPeers)

	broadcastCount := 0
	for peerId in allPeers {
		if peer, ok := PeerManager_getPeer(peerManager, peerId); ok {
			if peer.activeChannels[msg.channel].status != .Active || peer.enetPeer == nil {
				continue
			}

			dataPtr: rawptr = nil
			if len(msg.data) > 0 {
				dataPtr = rawptr(&msg.data[0])
			}
			packet := ENet.packet_create(dataPtr, uint(len(msg.data)), {ENet.PacketFlag.RELIABLE})
			if packet == nil {
				continue
			}
			if ENet.peer_send(peer.enetPeer, u8(msg.channel), packet) == 0 {
				broadcastCount += 1
			} else {
				ENet.packet_destroy(packet)
			}
		}
	}

	ENet.host_flush(enetHost)
	fmt.printfln(
		"[Network] Broadcast data on channel %v to %d peers (%d bytes per message)",
		msg.channel,
		broadcastCount,
		len(msg.data),
	)
}

// handleNetworkDisconnectPeer forcefully disconnects a specific peer
handleNetworkDisconnectPeer :: proc(
	peerManager: ^PeerManager,
	threadPool: ^NetworkThreadPool,
	msg: NetworkDisconnectPeer,
	enetHost: ^ENet.Host,
) {
	peer, ok := PeerManager_getPeer(peerManager, msg.peerId)
	if !ok {
		fmt.eprintfln("[Network] Cannot disconnect peer %d (peer not found)", msg.peerId)
		return
	}

	if peer.enetPeer != nil {
		ENet.peer_disconnect_now(peer.enetPeer, 0)
		ENet.host_flush(enetHost)
	}

	PeerManager_removePeer(peerManager, msg.peerId)
	NetworkThreadPool_removePeer(threadPool, msg.peerId)
	fmt.printfln("[Network] Disconnected peer %d via IPC command", msg.peerId)
}
