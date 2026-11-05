package client

import "base:runtime"
import "core:strings"
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
	ClientNetworkWorker_resolveDueAddresses(worker)
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

// Looks up the server address of every attempt that is due, without holding the mutex, so a
// slow DNS lookup delays only that server's attempt, never the UI thread (which takes the
// mutex to send) or the other servers' sessions. The transport slice and each transport's
// host stay fixed while the worker runs, so only the connection state needs the mutex.
ClientNetworkWorker_resolveDueAddresses :: proc(worker: ^ClientNetworkWorker) {
	PendingLookup :: struct {
		index: int,
		host:  string,
		port:  i32,
	}
	pending := make([dynamic]PendingLookup, context.temp_allocator)
	now := time.tick_now()
	sync.mutex_lock(&worker.mutex)
	for index in 0 ..< len(worker.transports) {
		transport := &worker.transports[index]
		if ClientServerTransport_attemptIsDue(transport, now) &&
		   !transport.connection.resolved.ready {
			host := strings.clone(transport.serverHost, context.temp_allocator)
			append(&pending, PendingLookup{index, host, transport.serverPort})
		}
	}
	sync.mutex_unlock(&worker.mutex)
	if len(pending) == 0 {
		return
	}

	results := make([]ClientResolvedAddress, len(pending), context.temp_allocator)
	for lookup, index in pending {
		results[index].address, results[index].ok = clientResolveServerAddress(
			lookup.host,
			lookup.port,
		)
		results[index].ready = true
	}

	sync.mutex_lock(&worker.mutex)
	for lookup, index in pending {
		worker.transports[lookup.index].connection.resolved = results[index]
	}
	sync.mutex_unlock(&worker.mutex)
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
	// The thread package gives this thread its own default temp allocator, but because the
	// thread starts with an explicit context it leaves destroying it to us. Without this every
	// worker restart (a settings change) would leak the arena.
	defer if context.temp_allocator.procedure == runtime.default_temp_allocator_proc {
		runtime.default_temp_allocator_destroy(
			(^runtime.Default_Temp_Allocator)(context.temp_allocator.data),
		)
	}
	for !sync.atomic_load(&worker.stopping) {
		ClientNetworkWorker_servicePass(worker)
		free_all(context.temp_allocator)
		time.sleep(NETWORK_WORKER_IDLE_SLEEP)
	}
}
