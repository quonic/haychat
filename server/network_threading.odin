package server

import "core:log"
import "core:slice"
import "core:sync"
import "core:thread"
import "vendor:ENet"

// WorkerEventType discriminates the type of event in a worker thread queue
WorkerEventType :: enum u8 {
	ENetEvent,
	IPCCommand,
	ChannelStateChange,
}

// WorkerEvent represents an event queued for a worker thread to process
WorkerEvent :: union {
	ENetEventData,
	IPCCommandData,
	ChannelStateChangeData,
}

// ENetEventData wraps an ENet event for a peer
ENetEventData :: struct {
	peerId: u32,
	event:  ENet.Event,
}

// IPCCommandData wraps an IPC command routed to this thread
IPCCommandData :: struct {
	peerId:  u32,
	channel: NetworkChannel,
	data:    [dynamic]u8,
}

// ChannelStateChangeData represents a channel state change for a peer
ChannelStateChangeData :: struct {
	peerId:    u32,
	channel:   NetworkChannel,
	newStatus: ChannelStatus,
}

// WorkerEventQueue is a bounded circular queue for worker thread events
WorkerEventQueue :: struct {
	items:         [dynamic]WorkerEvent,
	start:         int, // Index of oldest item
	count:         int, // Number of items in queue
	capacity:      int, // Maximum items before overflow
	overflowCount: u32, // Count of dropped events due to overflow
	queueMutex:    sync.Mutex,
}

// WorkerEventQueue_init creates a new event queue with specified capacity
WorkerEventQueue_init :: proc(capacity: int) -> WorkerEventQueue {
	return WorkerEventQueue{items = make([dynamic]WorkerEvent, 0, capacity), capacity = capacity}
}

// WorkerEventQueue_deinit cleans up an event queue
WorkerEventQueue_deinit :: proc(queue: ^WorkerEventQueue) {
	delete(queue.items)
}

// NetworkThreadContext represents a single worker thread's context
NetworkThreadContext :: struct {
	id:             int,
	threadHandle:   rawptr, // thread.Thread
	peerIds:        [dynamic]u32, // Peers assigned to this thread
	peersMutex:     sync.Mutex,
	eventQueue:     WorkerEventQueue, // Queue of events to process
	shouldShutdown: bool,
}

// NetworkThreadPool manages all worker threads
NetworkThreadPool :: struct {
	threads:        [dynamic]^NetworkThreadContext,
	peerManager:    ^PeerManager,
	mainIPCFd:      int, // File descriptor for IPC communication to main process
	threadsMutex:   sync.Mutex,
	shouldShutdown: bool,
}

// NetworkThreadPool_init initializes the thread pool with specified number of threads
NetworkThreadPool_init :: proc(
	numThreads: int,
	peerManager: ^PeerManager,
	mainIPCFd: int,
) -> NetworkThreadPool {
	pool := NetworkThreadPool {
		threads        = make([dynamic]^NetworkThreadContext, 0, numThreads),
		peerManager    = peerManager,
		mainIPCFd      = mainIPCFd,
		shouldShutdown = false,
	}

	return pool
}

// NetworkThreadPool_spawn creates and starts the worker threads
NetworkThreadPool_spawn :: proc(pool: ^NetworkThreadPool, numThreads: int) -> bool {
	for i in 0 ..< numThreads {
		ctx := new(NetworkThreadContext)
		ctx.id = i
		ctx.peerIds = make([dynamic]u32)
		ctx.eventQueue = WorkerEventQueue_init(1000) // 1000 event capacity per thread
		ctx.shouldShutdown = false

		// Start worker thread
		threadHandle := thread.create_and_start_with_data(ctx, proc(ctx: rawptr) {
			threadContext := cast(^NetworkThreadContext)ctx
			networkThreadWorker(threadContext)
		})

		if threadHandle == nil {
			log.errorf("[NetworkThreadPool] Failed to spawn worker thread %d", i)
			WorkerEventQueue_deinit(&ctx.eventQueue)
			delete(ctx.peerIds)
			free(ctx)
			return false
		}

		ctx.threadHandle = threadHandle
		append(&pool.threads, ctx)
	}

	log.infof("[NetworkThreadPool] Spawned %d worker threads", numThreads)
	return true
}

// networkThreadWorker is the main worker thread procedure
networkThreadWorker :: proc(ctx: ^NetworkThreadContext) {
	log.infof("[NetworkThread-%d] Worker thread started", ctx.id)

	// Main worker loop - process events from queue
	for !ctx.shouldShutdown {
		// Poll event queue with short timeout
		event, ok := WorkerEventQueue_dequeue(&ctx.eventQueue)

		if ok {
			// Process the event
			switch e in event {
			case ENetEventData:
				handleWorkerENetEvent(ctx, e)
			case IPCCommandData:
				handleWorkerIPCCommand(ctx, e)
			case ChannelStateChangeData:
				handleWorkerChannelStateChange(ctx, e)
			}
		} else {
			// No event available, yield briefly
			thread.yield()
		}
	}

	// Drain any remaining events in queue on shutdown
	for {
		event, ok := WorkerEventQueue_dequeue(&ctx.eventQueue)
		if !ok {
			break
		}
		// Process remaining events before exiting
		switch e in event {
		case ENetEventData:
			handleWorkerENetEvent(ctx, e)
		case IPCCommandData:
			handleWorkerIPCCommand(ctx, e)
		case ChannelStateChangeData:
			handleWorkerChannelStateChange(ctx, e)
		}
	}

	log.infof("[NetworkThread-%d] Worker thread shutting down", ctx.id)
}

// handleWorkerENetEvent processes an ENet event for a peer
handleWorkerENetEvent :: proc(ctx: ^NetworkThreadContext, event: ENetEventData) {
	// In this hybrid model, the main loop already handled the IPC send
	// This handler could be extended for additional per-thread processing
	// For now, mainly used for potential encryption/decryption logic
	log.debugf("[NetworkThread-%d] ENet event for peer %d", ctx.id, event.peerId)
}

// handleWorkerIPCCommand processes an IPC command routed to this thread
handleWorkerIPCCommand :: proc(ctx: ^NetworkThreadContext, cmd: IPCCommandData) {
	// This would handle NetworkSendData/NetworkBroadcast routed to this thread's peers
	log.debugf(
		"[NetworkThread-%d] IPC command for peer %d on channel %v",
		ctx.id,
		cmd.peerId,
		cmd.channel,
	)
	// Data is held in cmd.data as u8 slice
	delete(cmd.data)
}

// handleWorkerChannelStateChange processes a channel state change for a peer
handleWorkerChannelStateChange :: proc(
	ctx: ^NetworkThreadContext,
	change: ChannelStateChangeData,
) {
	log.infof(
		"[NetworkThread-%d] Channel state change for peer %d: %v -> %v",
		ctx.id,
		change.peerId,
		change.channel,
		change.newStatus,
	)
	// Could trigger any thread-local channel state reactions here
}

// NetworkThreadPool_assignPeer assigns a peer to the least-loaded thread
NetworkThreadPool_assignPeer :: proc(pool: ^NetworkThreadPool, peerId: u32) -> bool {
	if len(pool.threads) == 0 {
		log.warn("[NetworkThreadPool] No worker threads available")
		return false
	}

	// Find the thread with the fewest peers (least-loaded assignment)
	leastLoadedThread := pool.threads[0]
	minPeerCount := len(pool.threads[0].peerIds)

	for i in 1 ..< len(pool.threads) {
		sync.mutex_lock(&pool.threads[i].peersMutex)
		peerCount := len(pool.threads[i].peerIds)
		sync.mutex_unlock(&pool.threads[i].peersMutex)

		if peerCount < minPeerCount {
			minPeerCount = peerCount
			leastLoadedThread = pool.threads[i]
		}
	}

	// Assign peer to least-loaded thread
	sync.mutex_lock(&leastLoadedThread.peersMutex)
	append(&leastLoadedThread.peerIds, peerId)
	sync.mutex_unlock(&leastLoadedThread.peersMutex)

	log.infof("[NetworkThreadPool] Assigned peer %d to thread %d", peerId, leastLoadedThread.id)
	return true
}

// NetworkThreadPool_removePeer removes a peer from its assigned thread
NetworkThreadPool_removePeer :: proc(pool: ^NetworkThreadPool, peerId: u32) -> bool {
	// Search for the peer in all threads
	for thread in pool.threads {
		sync.mutex_lock(&thread.peersMutex)
		idx, found := slice.linear_search(thread.peerIds[:], peerId)
		if found {
			ordered_remove(&thread.peerIds, idx)
			sync.mutex_unlock(&thread.peersMutex)
			log.infof("[NetworkThreadPool] Removed peer %d from thread %d", peerId, thread.id)
			return true
		}
		sync.mutex_unlock(&thread.peersMutex)
	}

	return false
}

// NetworkThreadPool_broadcast sends a broadcast message to all peers on a channel
// Returns the count of peers that received the broadcast
NetworkThreadPool_broadcast :: proc(
	pool: ^NetworkThreadPool,
	channel: NetworkChannel,
	data: []u8,
) -> int {
	if pool.peerManager == nil {
		log.warn("[NetworkThreadPool] Cannot broadcast: peer manager not initialized")
		return 0
	}

	// Get all connected peers
	allPeers := PeerManager_getAllPeers(pool.peerManager)
	defer delete(allPeers)

	broadcastCount := 0

	// For each peer that has this channel active, queue broadcast to it
	for peerId in allPeers {
		if peer, ok := PeerManager_getPeer(pool.peerManager, peerId); ok {
			// Check if peer has this channel active
			if peer.activeChannels[channel].status == .Active {
				// Create IPC command event for this peer
				cmdData := make([dynamic]u8)
				for b in data {
					append(&cmdData, b)
				}

				event := IPCCommandData {
					peerId  = peerId,
					channel = channel,
					data    = cmdData,
				}

				// Queue broadcast to the thread handling this peer
				if NetworkThreadPool_enqueueToPeer(pool, peerId, event) {
					broadcastCount += 1
				} else {
					// Queue full - log overflow and clean up allocated data
					log.warnf(
						"[NetworkThreadPool] Broadcast queue full for peer %d on channel %v",
						peerId,
						channel,
					)
					delete(cmdData)
				}
			}
		}
	}

	log.infof(
		"[NetworkThreadPool] Broadcast queued to %d peers on channel %v (%d bytes)",
		broadcastCount,
		channel,
		len(data),
	)

	return broadcastCount
}

// WorkerEventQueue_enqueue adds an event to the queue, returns false if overflow
WorkerEventQueue_enqueue :: proc(queue: ^WorkerEventQueue, event: WorkerEvent) -> bool {
	sync.mutex_lock(&queue.queueMutex)
	defer sync.mutex_unlock(&queue.queueMutex)

	if queue.count >= queue.capacity {
		queue.overflowCount += 1
		return false // Queue full, event dropped
	}

	// Find insertion index: (start + count) % capacity
	idx := (queue.start + queue.count) % queue.capacity

	// Expand storage if needed
	if len(queue.items) <= idx {
		for len(queue.items) <= idx {
			append(&queue.items, event)
		}
	} else {
		queue.items[idx] = event
	}

	queue.count += 1
	return true
}

// WorkerEventQueue_dequeue removes and returns the oldest event from queue
WorkerEventQueue_dequeue :: proc(queue: ^WorkerEventQueue) -> (WorkerEvent, bool) {
	sync.mutex_lock(&queue.queueMutex)
	defer sync.mutex_unlock(&queue.queueMutex)

	if queue.count == 0 {
		return nil, false // Queue empty
	}

	event := queue.items[queue.start]
	queue.start = (queue.start + 1) % queue.capacity
	queue.count -= 1

	return event, true
}

// NetworkThreadPool_enqueueEventToThread routes an event to a specific worker thread
NetworkThreadPool_enqueueEventToThread :: proc(
	pool: ^NetworkThreadPool,
	threadId: int,
	event: WorkerEvent,
) -> bool {
	if threadId < 0 || threadId >= len(pool.threads) {
		log.warnf("[NetworkThreadPool] Invalid thread ID: %d", threadId)
		return false
	}

	thread := pool.threads[threadId]
	return WorkerEventQueue_enqueue(&thread.eventQueue, event)
}

// NetworkThreadPool_enqueueToPeer routes an event to the thread handling a specific peer
NetworkThreadPool_enqueueToPeer :: proc(
	pool: ^NetworkThreadPool,
	peerId: u32,
	event: WorkerEvent,
) -> bool {
	// Find which thread has this peer
	for thread in pool.threads {
		sync.mutex_lock(&thread.peersMutex)
		_, found := slice.linear_search(thread.peerIds[:], peerId)
		sync.mutex_unlock(&thread.peersMutex)

		if found {
			return WorkerEventQueue_enqueue(&thread.eventQueue, event)
		}
	}

	log.warnf("[NetworkThreadPool] Peer %d not found in any thread", peerId)
	return false
}

// NetworkThreadPool_shutdown gracefully shuts down all worker threads
NetworkThreadPool_shutdown :: proc(pool: ^NetworkThreadPool) {
	log.info("[NetworkThreadPool] Initiating shutdown of worker threads")

	// Signal all threads to shut down
	for threadPtr in pool.threads {
		threadPtr.shouldShutdown = true
	}

	// Wait for all threads to complete (simple busy-wait for now)
	for threadPtr in pool.threads {
		count := 0
		for threadPtr.shouldShutdown && count < 100 {
			thread.yield()
			count += 1
		}

		// Clean up thread context
		WorkerEventQueue_deinit(&threadPtr.eventQueue)
		delete(threadPtr.peerIds)
		free(threadPtr)
	}

	delete(pool.threads)
	log.info("[NetworkThreadPool] All worker threads shut down")
}

// NetworkThreadPool_deinit cleans up the thread pool
NetworkThreadPool_deinit :: proc(pool: ^NetworkThreadPool) {
	if !pool.shouldShutdown {
		NetworkThreadPool_shutdown(pool)
	}
}

// NetworkThreadPool_getLoadInfo returns load distribution info for monitoring
NetworkThreadPool_getLoadInfo :: proc(pool: ^NetworkThreadPool) -> [][2]int {
	loadInfo := make([dynamic][2]int, len(pool.threads))

	for i in 0 ..< len(pool.threads) {
		threadPtr := pool.threads[i]
		sync.mutex_lock(&threadPtr.peersMutex)
		loadInfo[i] = [2]int{threadPtr.id, len(threadPtr.peerIds)}
		sync.mutex_unlock(&threadPtr.peersMutex)
	}

	return loadInfo[:]
}
