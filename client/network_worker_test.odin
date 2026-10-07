#+feature dynamic-literals
package client

import "../common"
import "core:strings"
import "core:testing"
import "core:time"
import "shared:skald"

@(test)
testNetworkWorkerStartsAndStopsWithoutLiveSessions :: proc(t: ^testing.T) {
	state := testStateWithServers(
		{
			Server{id = 701, name = "Worker A", host = "localhost", port = 1},
			Server{id = 702, name = "Worker B", host = "localhost", port = 1},
		},
	)
	state.networkWorker = ClientNetworkWorker_start(state.serverTransports[:])
	time.sleep(20 * time.Millisecond)

	_, hasEvent := ClientNetworkWorker_popEvent(state.networkWorker)
	testing.expect(t, !hasEvent, "expected transports without live sessions to produce no events")

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
				messageID = server.id,
				message = strings.clone("background message"),
				timestamp = strings.clone("t"),
			},
		)
	}

	theme := skald.theme_dark()
	input: skald.Input
	msgs: [dynamic]Msg
	defer delete(msgs)
	widgets: skald.Widget_Store
	defer skald.widget_store_destroy(&widgets)
	ctx := testViewCtx(&theme, &input, &msgs, &widgets)

	State_drainNetworkEvents(state, &ctx)

	testing.expect(t, len(msgs) == 2, "expected one Msg per queued event")
	testing.expect(
		t,
		len(state.networkWorker.events) == 0,
		"expected draining to empty the worker queue",
	)
	seenA, seenB := false, false
	for msg in msgs {
		seenA ||= msg.id == serverA.id
		seenB ||= msg.id == serverB.id
		testing.expect(t, msg.new_value == "background message", "expected message text to move")
		// Transport messages own their strings; update would normally free them.
		delete(msg.new_value)
		delete(msg.timestamp)
	}
	testing.expect(t, seenA && seenB, "expected events from the non-selected server too")
}

@(test)
testNetworkWorkerLockAndPopAreNilSafe :: proc(t: ^testing.T) {
	ClientNetworkWorker_lock(nil)
	ClientNetworkWorker_unlock(nil)
	_, hasEvent := ClientNetworkWorker_popEvent(nil)
	testing.expect(t, !hasEvent, "expected a nil worker to have no events")
	ClientNetworkWorker_stop(nil)
}
