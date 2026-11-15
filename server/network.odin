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
	// The voice handlers. voiceSessionOpen gets the queued message itself so it can move the
	// keys out; the drain wipes whatever is left afterwards.
	voiceSessionOpen: proc(userData: rawptr, msg: ^NetworkVoiceSessionOpen),
	voiceRoute:       proc(userData: rawptr, msg: NetworkVoiceRoute),
	voiceReset:       proc(userData: rawptr),
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
	voiceRelay:  ^VoiceRelay,
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

		// By reference, so the voice session handler can move keys out of the queued message.
		switch &msg in ipcMsg {
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

		case NetworkVoiceSessionOpen:
			if handlers.voiceSessionOpen != nil {
				handlers.voiceSessionOpen(handlers.userData, &msg)
			}
			// Wipes the keys whether or not a handler took them.
			IPC__message_deinit(&ipcMsg)

		case NetworkVoiceRoute:
			if handlers.voiceRoute != nil {
				handlers.voiceRoute(handlers.userData, msg)
			}
			IPC__message_deinit(&ipcMsg)

		case NetworkVoiceReset:
			if handlers.voiceReset != nil {
				handlers.voiceReset(handlers.userData)
			}

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
	// The relay lives on this thread's stack for as long as the loop runs; its deinit wipes
	// every peer's voice keys when the service stops or restarts.
	voiceRelay: VoiceRelay
	VoiceRelay_init(
		&voiceRelay,
		VoiceRelayConfig {
			maxPacketsPerSecond = pm.config.voiceMaxPacketsPerSecond,
			maxFrameBytes = pm.config.voiceMaxFrameBytes,
		},
		networkLoop__voiceSend,
		networkLoop__voiceClock,
		&loopState,
	)
	defer VoiceRelay_deinit(&voiceRelay)
	loopState.voiceRelay = &voiceRelay
	// Counters start over with the service; publish the zeros so /status does not keep
	// showing the previous run's numbers.
	VoiceRelayStats_publish(&voiceRelayPublishedStats, voiceRelay.stats)

	handlers := NetworkIPCHandlers {
		userData         = &loopState,
		sendData         = networkLoop__sendData,
		broadcast        = networkLoop__broadcast,
		disconnectPeer   = networkLoop__disconnectPeer,
		voiceSessionOpen = networkLoop__voiceSessionOpen,
		voiceRoute       = networkLoop__voiceRoute,
		voiceReset       = networkLoop__voiceReset,
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
		voiceSentBefore := voiceRelay.stats.datagramsOut
		serviceOK := networkServiceENet(&loopState, timeout)
		// Relayed voice is queued in ENet during the pass; push it out in one flush.
		if voiceRelay.stats.datagramsOut != voiceSentBefore {
			ENet.host_flush(enetHost)
		}
		VoiceRelay_publishStats(&voiceRelay, &voiceRelayPublishedStats)
		if !serviceOK {
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
				state.voiceRelay,
			)
		case .DISCONNECT:
			handlePeerDisconnect(
				state.peerManager,
				enetEvent.peer,
				int(state.ipcFd),
				state.voiceRelay,
			)
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
	// The router dropped this peer; its voice must stop at once, like on a disconnect event.
	if state.voiceRelay != nil {
		VoiceRelay_removePeer(state.voiceRelay, msg.peerId)
	}
	handleNetworkDisconnectPeer(state.peerManager, msg)
}

networkLoop__voiceSessionOpen :: proc(userData: rawptr, msg: ^NetworkVoiceSessionOpen) {
	state := cast(^NetworkLoopState)userData
	// The peer may have disconnected while the message was queued. Its disconnect already went
	// through the relay, so installing the keys now would keep them until the service stops;
	// leave them in the message, which the drain wipes.
	if _, connected := PeerManager_getPeer(state.peerManager, msg.peerId); !connected {
		return
	}
	VoiceRelay_openSession(state.voiceRelay, msg)
}

networkLoop__voiceRoute :: proc(userData: rawptr, msg: NetworkVoiceRoute) {
	state := cast(^NetworkLoopState)userData
	VoiceRelay_applyRoute(state.voiceRelay, msg.roomId, msg.members, msg.encrypted)
}

networkLoop__voiceReset :: proc(userData: rawptr) {
	state := cast(^NetworkLoopState)userData
	VoiceRelay_reset(state.voiceRelay)
}

// Queues one relayed voice datagram: unreliable and unsequenced on the voice channel, so a
// late frame still reaches the jitter buffer (voice-rooms-design.md 3.1). packet_create copies
// the relay's scratch buffer. The loop flushes once after the ENet pass.
networkLoop__voiceSend :: proc(userData: rawptr, peerId: u32, datagram: []u8) -> bool {
	state := cast(^NetworkLoopState)userData
	peer, ok := PeerManager_getPeer(state.peerManager, peerId)
	if !ok || peer.enetPeer == nil || len(datagram) == 0 {
		return false
	}
	packet := ENet.packet_create(raw_data(datagram), uint(len(datagram)), {.UNSEQUENCED})
	if packet == nil {
		return false
	}
	if ENet.peer_send(peer.enetPeer, u8(NetworkChannel.Voice), packet) != 0 {
		ENet.packet_destroy(packet)
		return false
	}
	return true
}

networkLoop__voiceClock :: proc(userData: rawptr) -> i64 {
	_ = userData
	return time.tick_now()._nsec
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

// handlePeerData releases the ENet packet after handling it. Voice datagrams (channel 2) go to
// the relay on this thread and never reach the router: no IPC, no copy, no log line. Every other
// packet is copied into an IPC message for the router, which owns control decryption and
// routing.
handlePeerData :: proc(
	peerManager: ^PeerManager,
	enetPeer: ^ENet.Peer,
	packet: ^ENet.Packet,
	channelID: u8,
	ipcFd: int,
	voiceRelay: ^VoiceRelay,
) {
	_ = peerManager
	defer ENet.packet_destroy(packet)

	peerId := u32(uintptr(enetPeer.data))
	if NetworkChannel(channelID) == .Voice {
		// The relay counts a peer it does not know, peer ID 0 included.
		if voiceRelay != nil {
			VoiceRelay_handleDatagram(voiceRelay, peerId, packet.data[:packet.dataLength])
		}
		return
	}
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

// handlePeerDisconnect forgets the peer, in the voice relay first so its frames stop before the
// router has even seen the disconnect, and tells the router.
handlePeerDisconnect :: proc(
	peerManager: ^PeerManager,
	enetPeer: ^ENet.Peer,
	ipcFd: int,
	voiceRelay: ^VoiceRelay,
) {
	peerId := u32(uintptr(enetPeer.data))

	if peerId == 0 {
		return
	}

	if voiceRelay != nil {
		VoiceRelay_removePeer(voiceRelay, peerId)
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
// The router ends a session after its last words to the peer: a ServerAuthFailure, a protocol
// error, or ServerSessionEnded for a kick or ban (protocol 14). Those are queued in the same
// drain just before this, so the peer disconnects only once ENet has delivered them
// (peer_disconnect_later); peer_disconnect_now would drop them unsent. The peer stays in the
// manager until ENet reports the disconnect, and handlePeerDisconnect then removes it and tells
// the router, like any other disconnect. A peer that never answers is timed out by ENet.
handleNetworkDisconnectPeer :: proc(peerManager: ^PeerManager, msg: NetworkDisconnectPeer) {
	peer, ok := PeerManager_getPeer(peerManager, msg.peerId)
	if !ok {
		fmt.eprintfln("[Network] Cannot disconnect peer %d (peer not found)", msg.peerId)
		return
	}

	if peer.enetPeer == nil {
		PeerManager_removePeer(peerManager, msg.peerId)
		return
	}
	ENet.peer_disconnect_later(peer.enetPeer, 0)
	fmt.printfln("[Network] Disconnecting peer %d via IPC command", msg.peerId)
}
