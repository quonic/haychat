#+feature dynamic-literals
package client

import "../common"
import "core:strings"
import "core:testing"
import "core:time"

// Rewritten from testNetworkWorkerStartsAndStopsWithoutLiveSessions: the worker now owns
// connecting, so starting it must begin a connect attempt for every server without blocking,
// and stopping it mid-attempt must not leak.
@(test)
testNetworkWorkerStartsConnectingEveryServer :: proc(t: ^testing.T) {
	state := testStateWithServers(
		{
			Server{id = 701, name = "Worker A", host = "127.0.0.1", port = 1},
			Server{id = 702, name = "Worker B", host = "127.0.0.1", port = 1},
		},
	)
	State_startNetwork(&state)

	connecting := map[int]bool{}
	defer delete(connecting)
	deadline := time.tick_now()
	for len(connecting) < 2 && time.tick_since(deadline) < 2 * time.Second {
		event, hasEvent := ClientNetworkWorker_popEvent(state.networkWorker)
		if !hasEvent {
			time.sleep(5 * time.Millisecond)
			continue
		}
		testing.expectf(
			t,
			event.kind == .Connecting,
			"expected only connect attempts against a closed port, got %v",
			event.kind,
		)
		connecting[event.serverID] = true
		ClientTransportRuntimeEvent_deinit(&event)
	}
	testing.expect(t, connecting[701] && connecting[702], "expected both servers to connect")

	// State_deinit stops the worker before freeing the transports it services.
	State_deinit(&state)
}

@(test)
testDrainNetworkEventsDeliversEveryServer :: proc(t: ^testing.T) {
	serverA := Server{id = 703, name = "Drain A", host = "localhost", port = 1}
	serverB := Server{id = 704, name = "Drain B", host = "localhost", port = 1}
	state := testStateWithServers({serverA, serverB})
	defer State_deinit(&state)

	// A worker without a thread lets the test control the queue directly.
	state.networkWorker = new(ClientNetworkWorker)
	state.networkWorker.events = make([dynamic]ClientTransportRuntimeEvent)
	for server in ([]Server{serverA, serverB}) {
		append(
			&state.networkWorker.events,
			ClientTransportRuntimeEvent {
				kind = .RoomChatReceived,
				serverID = server.id,
				roomID = common.GENERAL_ROOM_ID,
				senderID = 5,
				messageID = server.id,
				message = strings.clone("background message"),
				timestamp = strings.clone("t"),
			},
		)
		// Signed by its sender (protocol 22).
		event := &state.networkWorker.events[len(state.networkWorker.events) - 1]
		event.clientMessageID, event.signature = testRoomMessageSignature(
			&state,
			server.id,
			common.GENERAL_ROOM_ID,
			event.senderID,
			event.messageID,
			"background message",
		)
	}

	applied := State_drainNetworkEvents(&state)

	testing.expect(t, applied, "expected draining to report applied events")
	testing.expect(
		t,
		len(state.networkWorker.events) == 0,
		"expected draining to empty the worker queue",
	)
	for server in ([]Server{serverA, serverB}) {
		cache := State_serverRoomCache(&state, server.id)
		room := ServerRoomCache_roomCache(cache, common.GENERAL_ROOM_ID)
		testing.expectf(
			t,
			len(room.messages) == 1 && room.messages[0].content == "background message",
			"expected server %d's room cache to receive its background message",
			server.id,
		)
	}
	testing.expect(t, !State_drainNetworkEvents(&state), "expected an empty queue to apply nothing")
}

@(test)
testNetworkWorkerServicePassWakesOnlyWhenEventsQueue :: proc(t: ^testing.T) {
	worker := ClientNetworkWorker {
		events = make([dynamic]ClientTransportRuntimeEvent),
		onEventQueued = proc(userdata: rawptr) {
			(^int)(userdata)^ += 1
		},
	}
	defer delete(worker.events)
	wakeCount := 0
	worker.onEventQueuedData = &wakeCount

	ClientNetworkWorker_servicePass(&worker)
	testing.expect(t, wakeCount == 0, "expected a pass without events not to wake the UI")
}

@(test)
testNetworkWorkerLockAndPopAreNilSafe :: proc(t: ^testing.T) {
	ClientNetworkWorker_lock(nil)
	ClientNetworkWorker_unlock(nil)
	_, hasEvent := ClientNetworkWorker_popEvent(nil)
	testing.expect(t, !hasEvent, "expected a nil worker to have no events")
	ClientNetworkWorker_stop(nil)
}

// The worker looks up due attempts' addresses before it takes its mutex; startConnect then
// uses the result instead of resolving under the lock.
@(test)
testNetworkWorkerResolvesDueAddressesBeforeConnecting :: proc(t: ^testing.T) {
	state := testStateWithServers(
		{
			Server{id = 705, name = "Due", host = "127.0.0.1", port = 12399},
			Server{id = 706, name = "Later", host = "127.0.0.1", port = 12399},
		},
	)
	defer State_deinit(&state)
	// Queued by State_initFromConfig, so the first is due now; push the second into the future.
	later := &state.serverTransports[1]
	later.connection.nextAttemptAt = time.tick_add(time.tick_now(), time.Hour)

	// A worker without a thread lets the test run one step at a time.
	state.networkWorker = new(ClientNetworkWorker)
	state.networkWorker.transports = state.serverTransports[:]
	state.networkWorker.events = make([dynamic]ClientTransportRuntimeEvent)
	ClientNetworkWorker_resolveDueAddresses(state.networkWorker)

	due := state.serverTransports[0].connection.resolved
	testing.expectf(
		t,
		due.ready && due.ok && due.address.host != 0 && due.address.port == 12399,
		"expected the due attempt's address to be resolved, got %v",
		due,
	)
	testing.expect(
		t,
		!later.connection.resolved.ready,
		"expected an attempt that is not due to be left alone",
	)

	event, hasEvent := ClientServerTransport_serviceConnection(
		&state.serverTransports[0],
		time.tick_now(),
	)
	defer ClientTransportRuntimeEvent_deinit(&event)
	testing.expectf(
		t,
		hasEvent && event.kind == .Connecting,
		"expected the attempt to start with the resolved address, got %v",
		event.kind,
	)
	testing.expect(
		t,
		!state.serverTransports[0].connection.resolved.ready,
		"expected the attempt to consume the resolved address",
	)
}
