package server

import "core:sync"
import "core:sys/linux"
import "core:testing"
import "vendor:ENet"

networkTestResetIPCState :: proc() {
	sync.mutex_lock(&ipcState.state_mutex)
	defer sync.mutex_unlock(&ipcState.state_mutex)

	IPC__state_deinit()
	ipcState.next_fd = linux.Fd(10)
}

networkTestInitNetworkIPC :: proc(socketName: string) -> (linux.Fd, linux.Fd) {
	networkTestResetIPCState()

	mainFd := IPC_Main_init()
	ctx := IPC_Server_Context{}
	serverErr := IPC_Server_init(&ctx, socketName)
	assert(serverErr == nil, "expected IPC server init to succeed")

	networkFd, clientErr := IPC_Client_init(&ctx)
	assert(clientErr == nil, "expected IPC client init to succeed")

	return mainFd, networkFd
}

networkTestCreatePacket :: proc(data: []u8) -> ^ENet.Packet {
	dataPtr: rawptr = nil
	if len(data) > 0 {
		dataPtr = rawptr(&data[0])
	}

	packet := ENet.packet_create(dataPtr, uint(len(data)), {})
	assert(packet != nil, "expected ENet packet allocation to succeed")
	return packet
}

@(test)
testHandlePeerDataForwardsControlPacketsToTheRouter :: proc(t: ^testing.T) {
	_ = t

	mainFd, networkFd := networkTestInitNetworkIPC("network_event_handler_test_network")
	defer networkTestResetIPCState()

	peerManager := PeerManager_init()
	defer PeerManager_deinit(&peerManager)

	packetBytes := []u8{1, 2, 3, 4}
	packet := networkTestCreatePacket(packetBytes)

	enetPeer := ENet.Peer{}
	enetPeer.data = rawptr(uintptr(42))

	handlePeerData(&peerManager, &enetPeer, packet, u8(NetworkChannel.Chat), int(networkFd), nil)

	msg, err := IPC_Client_poll(mainFd)
	assert(err == nil, "expected main IPC queue to receive a network data message")

	#partial switch m in msg {
	case NetworkDataReceived:
		assert(m.peerId == 42, "expected peer ID to be forwarded")
		assert(m.channel == .Chat, "expected inbound ENet channel to be forwarded")
		assert(len(m.data) == 4, "expected packet data to be copied")
		delete(m.data)
	case:
		assert(false, "expected NetworkDataReceived IPC message")
	}
	_ = networkFd
}

// Test PeerManager_setChannelState
@(test)
testPeerManagerChannelState :: proc(t: ^testing.T) {
	pm := PeerManager_init()
	defer PeerManager_deinit(&pm)

	// Add a peer
	peer := NetworkPeer {
		id = 1,
	}
	PeerManager_addPeer(&pm, peer)

	// Set channel state
	state := ChannelState {
		status       = .Active,
		rateLimit    = 100000,
		codecQuality = 75,
	}

	result := PeerManager_setChannelState(&pm, 1, .Chat, state)
	testing.expect(t, result == true, "setChannelState should succeed")

	// Get channel state
	retrieved, ok := PeerManager_getChannelState(&pm, 1, .Chat)
	testing.expect(t, ok == true, "getChannelState should succeed")
	testing.expect(t, retrieved.status == .Active, "Channel status should be Active")
	testing.expect(t, retrieved.rateLimit == 100000, "Rate limit should be 100000")
	testing.expect(t, retrieved.codecQuality == 75, "Codec quality should be 75")
}

// Test PeerManager_pauseChannel
@(test)
testPeerManagerPauseResume :: proc(t: ^testing.T) {
	pm := PeerManager_init()
	defer PeerManager_deinit(&pm)

	// Add a peer with active channel
	peer := NetworkPeer {
		id = 1,
	}
	// Initialize the channel state manually
	peer.activeChannels[.Chat] = {
		status = .Active,
	}

	PeerManager_addPeer(&pm, peer)

	// Pause channel
	pauseResult := PeerManager_pauseChannel(&pm, 1, .Chat)
	testing.expect(t, pauseResult == true, "pauseChannel should succeed")

	// Verify paused
	state, _ := PeerManager_getChannelState(&pm, 1, .Chat)
	testing.expect(t, state.status == .Paused, "Channel status should be Paused")

	// Resume channel
	resumeResult := PeerManager_resumeChannel(&pm, 1, .Chat)
	testing.expect(t, resumeResult == true, "resumeChannel should succeed")

	// Verify active again
	state, _ = PeerManager_getChannelState(&pm, 1, .Chat)
	testing.expect(t, state.status == .Active, "Channel status should be Active again")
}

// Test PeerManager_isChannelActive
@(test)
testPeerManagerIsChannelActive :: proc(t: ^testing.T) {
	pm := PeerManager_init()
	defer PeerManager_deinit(&pm)

	// Add a peer
	peer := NetworkPeer {
		id = 1,
	}
	// Initialize specific channels
	peer.activeChannels[.Chat] = {
		status = .Active,
	}
	peer.activeChannels[.Voice] = {
		status = .Paused,
	}
	peer.activeChannels[.Video] = {
		status = .None,
	}

	PeerManager_addPeer(&pm, peer)

	// Test channel active states
	testing.expect(t, PeerManager_isChannelActive(&pm, 1, .Chat) == true, "Chat should be active")
	testing.expect(
		t,
		PeerManager_isChannelActive(&pm, 1, .Voice) == false,
		"Voice should not be active (paused)",
	)
	testing.expect(
		t,
		PeerManager_isChannelActive(&pm, 1, .Video) == false,
		"Video should not be active (none)",
	)
	testing.expect(
		t,
		PeerManager_isChannelActive(&pm, 999, .Chat) == false,
		"Non-existent peer should return false",
	)
}
