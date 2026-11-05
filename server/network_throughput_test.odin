package server

import "core:sys/linux"
import "core:testing"
import "core:thread"
import "core:time"
import "vendor:ENet"

// NetworkDrainTestSink records what networkDrainIPC hands to its handlers.
NetworkDrainTestSink :: struct {
	sends:          int,
	broadcasts:     int,
	disconnects:    int,
	nextPeerID:     u32, // The peer ID the next send must carry, to check FIFO order
	outOfOrder:     bool,
	unreliableSeen: bool,
}

networkDrainTestHandlers :: proc(sink: ^NetworkDrainTestSink) -> NetworkIPCHandlers {
	return NetworkIPCHandlers {
		userData = sink,
		sendData = proc(userData: rawptr, msg: NetworkSendData) {
			sink := cast(^NetworkDrainTestSink)userData
			inOrder := msg.peerId == sink.nextPeerID
			dataMatches := len(msg.data) == 1 && msg.data[0] == u8(msg.peerId)
			if !inOrder || !dataMatches {
				sink.outOfOrder = true
			}
			if msg.unreliable {
				sink.unreliableSeen = true
			}
			sink.nextPeerID += 1
			sink.sends += 1
		},
		broadcast = proc(userData: rawptr, msg: NetworkBroadcast) {
			sink := cast(^NetworkDrainTestSink)userData
			sink.broadcasts += 1
		},
		disconnectPeer = proc(userData: rawptr, msg: NetworkDisconnectPeer) {
			sink := cast(^NetworkDrainTestSink)userData
			sink.disconnects += 1
		},
	}
}

// networkDrainTestQueueSends queues count sends from the main endpoint to the network
// endpoint, exactly as MainRouterState_sendPeerPacket does. Peer IDs start at firstPeerID.
networkDrainTestQueueSends :: proc(networkFd: linux.Fd, firstPeerID: u32, count: int) {
	mainContext := IPC_Server_Context{}
	for i in 0 ..< count {
		peerID := firstPeerID + u32(i)
		data := make([]u8, 1)
		data[0] = u8(peerID)
		IPC_Server_send(
			&mainContext,
			networkFd,
			NetworkSendData{peerId = peerID, channel = .Chat, data = data},
		)
	}
}

networkDrainTestQueueIsEmpty :: proc(networkFd: linux.Fd) -> bool {
	msg, err := IPC_Client_poll(networkFd)
	if err == nil {
		IPC__message_deinit(&msg)
		return false
	}
	return true
}

@(test)
testNetworkDrainEmptiesThousandSendsInOnePass :: proc(t: ^testing.T) {
	_ = t

	_, networkFd := networkTestInitNetworkIPC("network_throughput_test_network")
	defer networkTestResetIPCState()

	MESSAGE_COUNT :: 1000
	networkDrainTestQueueSends(networkFd, 1, MESSAGE_COUNT)

	sink := NetworkDrainTestSink {
		nextPeerID = 1,
	}
	result := networkDrainIPC(networkFd, networkDrainTestHandlers(&sink))

	assert(
		result.processed == MESSAGE_COUNT,
		"expected one drain pass to pop all 1000 queued messages",
	)
	assert(result.transmitted == MESSAGE_COUNT, "expected all 1000 sends to reach the handler")
	assert(sink.sends == MESSAGE_COUNT, "expected the send handler to run 1000 times")
	assert(!sink.outOfOrder, "expected sends to be handed over in FIFO order with their data")
	assert(!sink.unreliableSeen, "expected sends to be reliable unless they ask otherwise")
	assert(!result.hitLimit, "expected 1000 messages to fit under the per-pass limit")
	assert(!result.stop, "expected no stop signal from plain sends")
	assert(networkDrainTestQueueIsEmpty(networkFd), "expected the network queue to be empty")
}

@(test)
testNetworkDrainStopsAtPassLimit :: proc(t: ^testing.T) {
	_ = t

	_, networkFd := networkTestInitNetworkIPC("network_throughput_test_network")
	defer networkTestResetIPCState()

	EXTRA :: 476
	networkDrainTestQueueSends(networkFd, 1, NETWORK_IPC_DRAIN_LIMIT + EXTRA)

	sink := NetworkDrainTestSink {
		nextPeerID = 1,
	}
	handlers := networkDrainTestHandlers(&sink)

	first := networkDrainIPC(networkFd, handlers)
	assert(
		first.processed == NETWORK_IPC_DRAIN_LIMIT,
		"expected the first pass to stop at NETWORK_IPC_DRAIN_LIMIT messages",
	)
	assert(first.hitLimit, "expected the first pass to report that it hit the limit")

	second := networkDrainIPC(networkFd, handlers)
	assert(second.processed == EXTRA, "expected the second pass to pop the remaining 476")
	assert(!second.hitLimit, "expected the second pass to empty the queue")
	assert(!sink.outOfOrder, "expected order to hold across passes")
	assert(networkDrainTestQueueIsEmpty(networkFd), "expected the network queue to be empty")
}

@(test)
testNetworkDrainStopsAtShutdownAndKeepsLaterMessages :: proc(t: ^testing.T) {
	_ = t

	_, networkFd := networkTestInitNetworkIPC("network_throughput_test_network")
	defer networkTestResetIPCState()

	mainContext := IPC_Server_Context{}
	networkDrainTestQueueSends(networkFd, 1, 3)
	broadcast := NetworkBroadcast {
		channel = .Chat,
		data    = make([]u8, 2),
	}
	IPC_Server_send(&mainContext, networkFd, broadcast)
	IPC_Server_send(&mainContext, networkFd, NetworkDisconnectPeer{peerId = 9})
	// A message the network thread never expects must still have its data freed.
	IPC_Server_send(
		&mainContext,
		networkFd,
		NetworkDataReceived{peerId = 5, channel = .Chat, data = make([]u8, 4)},
	)
	IPC_Server_send(&mainContext, networkFd, ProcessShutdown{})
	networkDrainTestQueueSends(networkFd, 4, 2)

	sink := NetworkDrainTestSink {
		nextPeerID = 1,
	}
	result := networkDrainIPC(networkFd, networkDrainTestHandlers(&sink))

	assert(result.stop, "expected the drain to report the shutdown signal")
	assert(result.processed == 7, "expected the drain to stop right after the shutdown signal")
	assert(result.transmitted == 5, "expected 3 sends, 1 broadcast, and 1 disconnect")
	assert(sink.sends == 3 && sink.broadcasts == 1, "expected sends before shutdown to be handled")
	assert(sink.disconnects == 1, "expected the disconnect before shutdown to be handled")
	assert(!networkDrainTestQueueIsEmpty(networkFd), "expected sends after shutdown to stay queued")
}

@(test)
testNetworkPacketFlagsFollowDeliveryMode :: proc(t: ^testing.T) {
	_ = t

	assert(
		networkPacketFlags(false) == ENet.PacketFlags{.RELIABLE},
		"expected the default send to use ENet's reliable flag",
	)
	assert(
		networkPacketFlags(true) == ENet.PacketFlags{},
		"expected an unreliable send to use no ENet flags",
	)
	defaultSend := NetworkSendData{}
	assert(!defaultSend.unreliable, "expected a zero NetworkSendData to be reliable")
}

@(test)
testIPCRingWrapsAroundAndGrowsWhenFull :: proc(t: ^testing.T) {
	_ = t

	ring: IPC_Ring(int)
	IPC_Ring_init(&ring, 4)
	defer IPC_Ring_deinit(&ring)

	_, emptyOK := IPC_Ring_pop(&ring)
	assert(!emptyOK, "expected pop on an empty ring to fail")

	for value in 1 ..= 3 {
		IPC_Ring_push(&ring, value)
	}
	first, _ := IPC_Ring_pop(&ring)
	second, _ := IPC_Ring_pop(&ring)
	assert(first == 1 && second == 2, "expected FIFO order before wrap-around")

	// head is now 2; these three pushes wrap past the end of the buffer and fill it.
	for value in 4 ..= 6 {
		IPC_Ring_push(&ring, value)
	}
	assert(IPC_Ring_len(&ring) == 4, "expected four items after wrapping")
	assert(IPC_Ring_capacity(&ring) == 4, "expected a full ring to keep its capacity")

	// A push into a full ring grows it and must keep the order of the wrapped items.
	IPC_Ring_push(&ring, 7)
	assert(IPC_Ring_capacity(&ring) > 4, "expected a push into a full ring to grow it")
	assert(IPC_Ring_len(&ring) == 5, "expected five items after growing")

	for expected in 3 ..= 7 {
		value, ok := IPC_Ring_pop(&ring)
		assert(ok && value == expected, "expected FIFO order to survive wrap-around and growth")
	}
	_, drainedOK := IPC_Ring_pop(&ring)
	assert(!drainedOK, "expected the ring to be empty after popping every item")
	assert(ring.head == 0, "expected an emptied ring to reset its head")
}

@(test)
testIPCClientWaitWakesOnPush :: proc(t: ^testing.T) {
	_ = t

	_, networkFd := networkTestInitNetworkIPC("network_throughput_test_network")
	defer networkTestResetIPCState()

	assert(
		!IPC_Client_wait(networkFd, 1 * time.Millisecond),
		"expected a wait on an empty queue to time out",
	)

	WakeSender :: struct {
		networkFd: linux.Fd,
	}
	sender := WakeSender {
		networkFd = networkFd,
	}
	worker := thread.create_and_start_with_poly_data(&sender, proc(sender: ^WakeSender) {
		time.sleep(20 * time.Millisecond)
		mainContext := IPC_Server_Context{}
		IPC_Server_send(&mainContext, sender.networkFd, Wake{})
	})

	start := time.now()
	woke := IPC_Client_wait(networkFd, 5 * time.Second)
	elapsed := time.since(start)
	thread.join(worker)
	thread.destroy(worker)

	assert(woke, "expected a push from another thread to wake the waiting consumer")
	assert(elapsed < 2 * time.Second, "expected the wait to end on the push, not the timeout")
	assert(IPC_Client_wait(networkFd, 0), "expected a queued message to report ready at once")
	assert(!networkDrainTestQueueIsEmpty(networkFd), "expected the Wake message to be queued")
}
