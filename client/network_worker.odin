package client

import "core:sync"
import "core:thread"
import "core:time"

// Number of ENet events drained per server per worker pass, so one busy server cannot starve
// the others.
NETWORK_WORKER_MAX_EVENTS_PER_SERVER :: 16
NETWORK_WORKER_IDLE_SLEEP :: 5 * time.Millisecond

// ClientNetworkWorker services every server session on a background thread: it runs each
// transport's connect state machine (connection.odin), so connecting, signing in, and
// reconnecting never block the UI, and it keeps established sessions serviced, since ENet needs
// regular servicing to send acknowledgements and keepalives. Decoded runtime events are queued
// for the UI thread, which drains them each frame without doing any network I/O itself.
//
// mutex guards the ENet hosts, the transport crypto state, and the event queue. Any code on
// the UI thread that sends through a transport must hold it (see ClientNetworkWorker_lock).
ClientNetworkWorker :: struct {
	mutex:             sync.Mutex,
	transports:        []ClientServerTransport,
	events:            [dynamic]ClientTransportRuntimeEvent,
	thread:            ^thread.Thread,
	stopping:          bool,
	// Called on the worker thread, without the mutex held, after a pass queued new events.
	onEventQueued:     NetworkWorkerEventQueuedProc,
	onEventQueuedData: rawptr,
}

NetworkWorkerEventQueuedProc :: proc(userdata: rawptr)

// Starts servicing transports. The slice must stay valid until ClientNetworkWorker_stop, so
// the owning array must not be reallocated while the worker runs.
ClientNetworkWorker_start :: proc(
	transports: []ClientServerTransport,
	onEventQueued: NetworkWorkerEventQueuedProc = nil,
	onEventQueuedData: rawptr = nil,
) -> ^ClientNetworkWorker {
	worker := new(ClientNetworkWorker)
	worker.transports = transports
	worker.onEventQueued = onEventQueued
	worker.onEventQueuedData = onEventQueuedData
	worker.events = make([dynamic]ClientTransportRuntimeEvent)
	// The worker allocates the events and transport strings that the UI thread later frees,
	// so it must use the same allocator. The thread package gives it its own temp allocator.
	worker.thread = thread.create_and_start_with_data(worker, ClientNetworkWorker_run, context)
	return worker
}

// Stops and joins the worker thread but keeps the worker and its queued events, so the caller
// can still drain them (see State_stopNetwork). Safe to call more than once.
ClientNetworkWorker_stopThread :: proc(worker: ^ClientNetworkWorker) {
	if worker == nil {
		return
	}
	sync.atomic_store(&worker.stopping, true)
	if worker.thread != nil {
		thread.join(worker.thread)
		thread.destroy(worker.thread)
		worker.thread = nil
	}
}

// Stops the thread and frees the worker, including any events still queued.
ClientNetworkWorker_stop :: proc(worker: ^ClientNetworkWorker) {
	if worker == nil {
		return
	}
	ClientNetworkWorker_stopThread(worker)
	for index in 0 ..< len(worker.events) {
		ClientTransportRuntimeEvent_deinit(&worker.events[index])
	}
	delete(worker.events)
	free(worker)
}

ClientNetworkWorker_lock :: proc(worker: ^ClientNetworkWorker) {
	if worker != nil {
		sync.mutex_lock(&worker.mutex)
	}
}

ClientNetworkWorker_unlock :: proc(worker: ^ClientNetworkWorker) {
	if worker != nil {
		sync.mutex_unlock(&worker.mutex)
	}
}

// Services each transport once and queues any events. Exposed separately from the thread loop
// so tests can drive it deterministically.
ClientNetworkWorker_servicePass :: proc(worker: ^ClientNetworkWorker) {
	queued := false
	sync.mutex_lock(&worker.mutex)
	for index in 0 ..< len(worker.transports) {
		transport := &worker.transports[index]
		for _ in 0 ..< NETWORK_WORKER_MAX_EVENTS_PER_SERVER {
			event, hasEvent := ClientServerTransport_serviceRuntime(transport)
			if !hasEvent {
				break
			}
			append(&worker.events, event)
			queued = true
		}
	}
	sync.mutex_unlock(&worker.mutex)

	if queued && worker.onEventQueued != nil {
		worker.onEventQueued(worker.onEventQueuedData)
	}
}

// Moves the oldest queued event to the caller, who then owns it.
ClientNetworkWorker_popEvent :: proc(
	worker: ^ClientNetworkWorker,
) -> (
	event: ClientTransportRuntimeEvent,
	ok: bool,
) {
	if worker == nil {
		return {}, false
	}
	sync.mutex_lock(&worker.mutex)
	defer sync.mutex_unlock(&worker.mutex)

	if len(worker.events) == 0 {
		return {}, false
	}
	event = worker.events[0]
	ordered_remove(&worker.events, 0)
	return event, true
}

@(private = "file")
ClientNetworkWorker_run :: proc(data: rawptr) {
	worker := cast(^ClientNetworkWorker)data
	for !sync.atomic_load(&worker.stopping) {
		ClientNetworkWorker_servicePass(worker)
		free_all(context.temp_allocator)
		time.sleep(NETWORK_WORKER_IDLE_SLEEP)
	}
}
