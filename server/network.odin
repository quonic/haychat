package server

import "core:fmt"

import "core:net"
import "core:os"
import "core:sys/linux"
import "core:time"
import "vendor:ENet"

NetworkPeerInfo :: struct {
	peerId:  u32,
	address: net.Address, // Remote peer address (IP4 or IP6)
}

// Each loop pass handles at most this many IPC messages and this many ENet events, so a flood
// in one direction cannot starve the other. Both are far above steady-state traffic.
NETWORK_IPC_DRAIN_LIMIT :: 1024
NETWORK_ENET_EVENT_LIMIT :: 1024

// host_service wait when the IPC queue is empty. Outbound sends wait at most this long for the
// network thread to notice them, because ENet cannot wait on the socket and the queue at once.
NETWORK_SERVICE_TIMEOUT_MS :: 2

// Peers the ENet host accepts per HAYCHAT_MAX_NETWORK_THREADS unit. The key once sized a worker
// pool; it now only sets the peer capacity, which keeps the default at 64 peers.
NETWORK_PEERS_PER_CAPACITY_UNIT :: 16

// Per-packet log lines are printed only when HAYCHAT_LOG_LEVEL is debug.
@(private = "file")
networkDebugLogging := false

// NetworkIPCHandlers receives the commands that networkDrainIPC pops. Each handler borrows the
// message: networkDrainIPC frees its data after the handler returns. A nil handler skips the
// command. userData is passed through unchanged.
NetworkIPCHandlers :: struct {
	userData:       rawptr,
	sendData:       proc(userData: rawptr, msg: NetworkSendData),
	broadcast:      proc(userData: rawptr, msg: NetworkBroadcast),
	disconnectPeer: proc(userData: rawptr, msg: NetworkDisconnectPeer),
}

NetworkIPCDrainResult :: struct {
	processed:   int, // Messages popped from the queue
	transmitted: int, // Send, broadcast, and disconnect commands handed to a handler
	stop:        bool, // A shutdown or restart signal was seen; later messages stay queued
	hitLimit:    bool, // The pass stopped at its limit, so more messages may be waiting
}

// NetworkLoopState is what the real IPC handlers need to reach ENet.
NetworkLoopState :: struct {
	peerManager: ^PeerManager,
	enetHost:    ^ENet.Host,
	ipcFd:       linux.Fd,
}

// networkDrainIPC pops every pending message for the network endpoint, up to limit, and hands
// commands to the handlers. The old loop handled one message per host_service call, so a
// fan-out to N peers took N loop passes and the queue grew without bound under load.
networkDrainIPC :: proc(
	ipcFd: linux.Fd,
	handlers: NetworkIPCHandlers,
	limit := NETWORK_IPC_DRAIN_LIMIT,
) -> NetworkIPCDrainResult {
	result: NetworkIPCDrainResult
	for result.processed < limit {
		ipcMsg, ipcErr := IPC_Client_poll(ipcFd)
		if ipcErr != nil {
			return result
		}
		result.processed += 1

		switch msg in ipcMsg {
		case NetworkSendData:
			if handlers.sendData != nil {
				handlers.sendData(handlers.userData, msg)
			}
			delete(msg.data)
			result.transmitted += 1

		case NetworkBroadcast:
			if handlers.broadcast != nil {
				handlers.broadcast(handlers.userData, msg)
			}
			delete(msg.data)
			result.transmitted += 1

		case NetworkDisconnectPeer:
			if handlers.disconnectPeer != nil {
				handlers.disconnectPeer(handlers.userData, msg)
			}
			result.transmitted += 1

		case ProcessShutdown:
			fmt.println("[Network] Received shutdown signal from main process")
			result.stop = true
			return result

		case ProcessRestart:
			fmt.println("[Network] Received restart signal from main process")
			result.stop = true
			return result

		case Wake:
		// No-op wake signal

		case NetworkPeerConnected, NetworkPeerDisconnected, NetworkDataReceived:
			fmt.eprintfln("[Network] Received unexpected message type from main process")
			IPC__message_deinit(&ipcMsg)

		case AdminQueryStatus,
		     AdminQueryStatusResponse,
		     AdminGetPeers,
		     AdminGetPeersResponse,
		     AdminGetLogs,
		     AdminGetLogsResponse:
			fmt.eprintfln("[Network] Received admin message, ignoring")
			IPC__message_deinit(&ipcMsg)

		case DatabaseQuery,
		     DatabaseQueryResult,
		     DatabaseError,
		     DatabaseStartupReady,
		     DatabaseStartupFailed:
			fmt.eprintfln("[Network] Received database message, ignoring")
			IPC__message_deinit(&ipcMsg)

		case ProcessError:
			fmt.eprintfln("[Network] Received process error: %v", msg.error)
			IPC__message_deinit(&ipcMsg)
		}
	}
	result.hitLimit = true
	return result
}

// networkServerLoop is the main entry point for the network server process
networkServerLoop :: proc(pm: ^ProcessManager) {
	fmt.printfln("[Network] Network server loop started (PID: %d)", os.get_pid())
	networkDebugLogging = serverLogLevelIsDebug(pm.config.logLevel)

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
		uint(pm.config.maxNetworkThreads * NETWORK_PEERS_PER_CAPACITY_UNIT),
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

	peerManager := PeerManager_init()
	defer PeerManager_deinit(&peerManager)

	loopState := NetworkLoopState {
		peerManager = &peerManager,
		enetHost    = enetHost,
		ipcFd       = client_fd,
	}
	handlers := NetworkIPCHandlers {
		userData       = &loopState,
		sendData       = networkLoop__sendData,
		broadcast      = networkLoop__broadcast,
		disconnectPeer = networkLoop__disconnectPeer,
	}

	serviceFailing := false
	for {
		// Outbound first: queue every pending send, then push them out in one flush rather
		// than one flush per packet.
		drain := networkDrainIPC(client_fd, handlers)
		if drain.transmitted > 0 {
			ENet.host_flush(enetHost)
		}
		if drain.stop {
			break
		}

		// Do not wait on the socket while IPC messages are still queued.
		timeout := u32(NETWORK_SERVICE_TIMEOUT_MS)
		if drain.hitLimit {
			timeout = 0
		}
		if !networkServiceENet(&loopState, timeout) {
			if !serviceFailing {
				fmt.eprintln("[Network] ENet host_service failed")
			}
			serviceFailing = true
			// host_service returns at once on failure, so wait here instead of spinning.
			time.sleep(NETWORK_SERVICE_TIMEOUT_MS * time.Millisecond)
		} else {
			serviceFailing = false
		}
	}

	fmt.println("[Network] Network server shutting down")
}

// networkServiceENet handles every ENet event that is ready, up to NETWORK_ENET_EVENT_LIMIT.
// Only the first host_service call may wait; later ones only collect what has arrived. It
// returns false if host_service reported an error.
networkServiceENet :: proc(state: ^NetworkLoopState, timeoutMS: u32) -> bool {
	for i in 0 ..< NETWORK_ENET_EVENT_LIMIT {
		wait := timeoutMS if i == 0 else 0
		enetEvent: ENet.Event
		serviceResult := ENet.host_service(state.enetHost, &enetEvent, wait)
		if serviceResult < 0 {
			return false
		}
		if serviceResult == 0 {
			return true
		}

		switch enetEvent.type {
		case .CONNECT:
			handlePeerConnect(state.peerManager, enetEvent.peer, int(state.ipcFd))
		case .RECEIVE:
			handlePeerData(
				state.peerManager,
				enetEvent.peer,
				enetEvent.packet,
				enetEvent.channelID,
				int(state.ipcFd),
			)
		case .DISCONNECT:
			handlePeerDisconnect(state.peerManager, enetEvent.peer, int(state.ipcFd))
		case .NONE:
		}
	}
	return true
}

networkLoop__sendData :: proc(userData: rawptr, msg: NetworkSendData) {
	state := cast(^NetworkLoopState)userData
	handleNetworkSendData(state.peerManager, msg)
}

networkLoop__broadcast :: proc(userData: rawptr, msg: NetworkBroadcast) {
	state := cast(^NetworkLoopState)userData
	handleNetworkBroadcast(state.peerManager, msg)
}

networkLoop__disconnectPeer :: proc(userData: rawptr, msg: NetworkDisconnectPeer) {
	state := cast(^NetworkLoopState)userData
	handleNetworkDisconnectPeer(state.peerManager, msg)
}

// networkPacketFlags maps a send's delivery mode to ENet flags. Unreliable packets use no
// flag, so ENet still drops ones that arrive after a newer packet on the same channel.
networkPacketFlags :: proc(unreliable: bool) -> ENet.PacketFlags {
	if unreliable {
		return {}
	}
	return {.RELIABLE}
}

// handlePeerConnect handles a new incoming peer connection
handlePeerConnect :: proc(peerManager: ^PeerManager, enetPeer: ^ENet.Peer, ipcFd: int) {
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

	// Send notification to main process
	msg := NetworkPeerConnected {
		peerId  = peerId,
		address = enetPeer.address,
	}
	IPC_Client_send(linux.Fd(ipcFd), msg)
	fmt.printfln("[Network] New peer connected: ID=%d", peerId)
}

// handlePeerData copies an incoming packet into an IPC message for the router, which owns
// decryption and routing, and releases the ENet packet.
handlePeerData :: proc(
	peerManager: ^PeerManager,
	enetPeer: ^ENet.Peer,
	packet: ^ENet.Packet,
	channelID: u8,
	ipcFd: int,
) {
	_ = peerManager
	defer ENet.packet_destroy(packet)

	peerId := u32(uintptr(enetPeer.data))
	if peerId == 0 {
		fmt.eprintfln("[Network] Received data from peer with invalid ID")
		return
	}

	packetData := packet.data[:packet.dataLength]
	packetCopy := make([]u8, len(packetData))
	copy(packetCopy, packetData)
	msg := NetworkDataReceived {
		peerId  = peerId,
		channel = NetworkChannel(channelID),
		data    = packetCopy,
	}
	if IPC_Client_send(linux.Fd(ipcFd), msg) != nil {
		fmt.eprintfln("[Network] Failed to queue data from peer %d for the router", peerId)
		delete(packetCopy)
		return
	}

	if networkDebugLogging {
		fmt.printfln(
			"[Network] Received %d bytes from peer %d on channel %v",
			len(packetData),
			peerId,
			msg.channel,
		)
	}
}

// handlePeerDisconnect handles a peer disconnection
handlePeerDisconnect :: proc(peerManager: ^PeerManager, enetPeer: ^ENet.Peer, ipcFd: int) {
	peerId := u32(uintptr(enetPeer.data))

	if peerId == 0 {
		return
	}

	PeerManager_removePeer(peerManager, peerId)

	// Send notification to main process
	msg := NetworkPeerDisconnected {
		peerId = peerId,
	}
	IPC_Client_send(linux.Fd(ipcFd), msg)
	fmt.printfln("[Network] Peer disconnected: ID=%d", peerId)
}

// handleNetworkSendData queues data for one peer. The loop flushes once after the IPC drain.
handleNetworkSendData :: proc(peerManager: ^PeerManager, msg: NetworkSendData) {
	peer, ok := PeerManager_getPeer(peerManager, msg.peerId)
	if !ok {
		fmt.eprintfln("[Network] Cannot send data to peer %d (peer not found)", msg.peerId)
		return
	}
	if peer.enetPeer == nil {
		fmt.eprintfln("[Network] Cannot send data to peer %d (missing ENet peer)", msg.peerId)
		return
	}

	dataPtr: rawptr = nil
	if len(msg.data) > 0 {
		dataPtr = rawptr(&msg.data[0])
	}
	packet := ENet.packet_create(
		dataPtr,
		uint(len(msg.data)),
		networkPacketFlags(msg.unreliable),
	)
	if packet == nil {
		fmt.eprintfln("[Network] Failed to allocate ENet packet for peer %d", msg.peerId)
		return
	}

	if ENet.peer_send(peer.enetPeer, u8(msg.channel), packet) != 0 {
		ENet.packet_destroy(packet)
		fmt.eprintfln("[Network] Failed to send data to peer %d", msg.peerId)
		return
	}

	if networkDebugLogging {
		fmt.printfln(
			"[Network] Sent data to peer %d on channel %v (%d bytes)",
			msg.peerId,
			msg.channel,
			len(msg.data),
		)
	}
}

// handleNetworkBroadcast queues data for every peer whose channel is active. The loop flushes
// once after the IPC drain.
handleNetworkBroadcast :: proc(peerManager: ^PeerManager, msg: NetworkBroadcast) {
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
			packet := ENet.packet_create(
				dataPtr,
				uint(len(msg.data)),
				networkPacketFlags(msg.unreliable),
			)
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

	if networkDebugLogging {
		fmt.printfln(
			"[Network] Broadcast data on channel %v to %d peers (%d bytes per message)",
			msg.channel,
			broadcastCount,
			len(msg.data),
		)
	}
}

// handleNetworkDisconnectPeer forcefully disconnects a specific peer.
// peer_disconnect_now sends the disconnect notice itself, so no flush is needed here.
handleNetworkDisconnectPeer :: proc(peerManager: ^PeerManager, msg: NetworkDisconnectPeer) {
	peer, ok := PeerManager_getPeer(peerManager, msg.peerId)
	if !ok {
		fmt.eprintfln("[Network] Cannot disconnect peer %d (peer not found)", msg.peerId)
		return
	}

	if peer.enetPeer != nil {
		ENet.peer_disconnect_now(peer.enetPeer, 0)
	}

	PeerManager_removePeer(peerManager, msg.peerId)
	fmt.printfln("[Network] Disconnected peer %d via IPC command", msg.peerId)
}
