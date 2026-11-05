package server

import "../common"
import "core:mem"
import "core:strings"
import "core:sync"
import "core:sys/linux"
import "core:time"
import "vendor:ENet"

SERVER_SOCKET :: "haychat"

Message :: union {
	Wake,
	// Network process messages
	NetworkPeerConnected,
	NetworkPeerDisconnected,
	NetworkDataReceived,
	NetworkSendData,
	NetworkBroadcast,
	NetworkDisconnectPeer,
	// Web admin messages
	AdminQueryStatus,
	AdminQueryStatusResponse,
	AdminGetPeers,
	AdminGetPeersResponse,
	AdminGetLogs,
	AdminGetLogsResponse,
	// Database messages
	DatabaseQuery,
	DatabaseQueryResult,
	DatabaseError,
	DatabaseStartupReady,
	DatabaseStartupFailed,
	// System messages
	ProcessShutdown,
	ProcessRestart,
	ProcessError,
}

NetworkPeerConnected :: struct {
	peerId:  u32,
	address: ENet.Address,
}

NetworkPeerDisconnected :: struct {
	peerId: u32,
}

NetworkChannel :: enum u8 {
	None = 0,
	Chat,
	Voice,
	Video,
	Screenshare,
	FileTransfer,
}

NetworkDataReceived :: struct {
	peerId:  u32,
	channel: NetworkChannel,
	data:    []u8,
}

// unreliable is false by default, so every existing send stays reliable. Odin has no field
// defaults, and a `reliable` flag would make a forgotten field silently drop chat packets.
NetworkSendData :: struct {
	peerId:     u32,
	channel:    NetworkChannel,
	data:       []u8,
	unreliable: bool,
}

NetworkBroadcast :: struct {
	channel:    NetworkChannel,
	data:       []u8,
	unreliable: bool,
}

NetworkDisconnectPeer :: struct {
	peerId: u32,
}

AdminQueryStatus :: struct {}

AdminQueryStatusResponse :: struct {
	uptime:                 i64,
	connectedPeers:         int,
	networkRunning:         bool,
	webAdminRunning:        bool,
	databaseRunning:        bool,
	networkRestartPending:  bool,
	webAdminRestartPending: bool,
	databaseRestartPending: bool,
	shutdownRequested:      bool,
}

AdminPeerInfo :: struct {
	peerId:          u32,
	isAuthenticated: bool,
	authenticatedId: int,
}

AdminGetPeers :: struct {}

AdminGetPeersResponse :: struct {
	peers: []AdminPeerInfo,
}

AdminGetLogs :: struct {}

AdminGetLogsResponse :: struct {
	logs: []string,
}

DatabaseQuery :: struct {
	request_id: u64,
	request:    common.DatabaseQueryRequest,
}

DatabaseQueryResult :: struct {
	request_id: u64,
	response:   common.DatabaseQueryResponse,
}

DatabaseError :: struct {
	request_id: u64,
	error:      string,
}

DatabaseStartupReady :: struct {}

DatabaseStartupFailed :: struct {
	error: string,
}

ProcessShutdown :: struct {}

ProcessRestart :: struct {}

ProcessError :: struct {
	error: string,
}

Wake :: struct {}

IPC_Endpoint_Kind :: enum {
	Unknown,
	Main,
	Network,
	WebAdmin,
	Database,
}

IPC_Server_Context :: struct {
	socket_name:   string,
	endpoint_kind: IPC_Endpoint_Kind,
}

IPC_Queue_Message :: struct {
	sender: IPC_Endpoint_Kind,
	msg:    Message,
}

IPC_Endpoint :: struct {
	fd:   linux.Fd,
	kind: IPC_Endpoint_Kind,
}

// IPC_Ring is a growable FIFO ring buffer. Push and pop are O(1); a full ring doubles its
// capacity and keeps the order. It never drops items: the queues carry reliable chat traffic,
// so back-pressure, if it is ever needed, belongs to the producer.
IPC_Ring :: struct($T: typeid) {
	items:     []T,
	head:      int, // Index of the oldest item
	count:     int,
	allocator: mem.Allocator,
}

IPC_RING_MIN_CAPACITY :: 16

IPC_Ring_init :: proc(
	ring: ^IPC_Ring($T),
	capacity := IPC_RING_MIN_CAPACITY,
	allocator := context.allocator,
) {
	ring.allocator = allocator
	ring.items = make([]T, max(capacity, 1), allocator)
	ring.head = 0
	ring.count = 0
}

IPC_Ring_deinit :: proc(ring: ^IPC_Ring($T)) {
	delete(ring.items, ring.allocator)
	ring^ = {}
}

IPC_Ring_len :: proc(ring: ^IPC_Ring($T)) -> int {
	return ring.count
}

IPC_Ring_capacity :: proc(ring: ^IPC_Ring($T)) -> int {
	return len(ring.items)
}

// IPC_Ring__grow copies the items into a buffer twice as large, oldest first, so head is 0.
IPC_Ring__grow :: proc(ring: ^IPC_Ring($T)) {
	if ring.allocator.procedure == nil {
		ring.allocator = context.allocator
	}
	newCapacity := max(len(ring.items) * 2, IPC_RING_MIN_CAPACITY)
	newItems := make([]T, newCapacity, ring.allocator)
	for i in 0 ..< ring.count {
		newItems[i] = ring.items[(ring.head + i) % len(ring.items)]
	}
	delete(ring.items, ring.allocator)
	ring.items = newItems
	ring.head = 0
}

IPC_Ring_push :: proc(ring: ^IPC_Ring($T), item: T) {
	if ring.count == len(ring.items) {
		IPC_Ring__grow(ring)
	}
	ring.items[(ring.head + ring.count) % len(ring.items)] = item
	ring.count += 1
}

IPC_Ring_pop :: proc(ring: ^IPC_Ring($T)) -> (T, bool) {
	if ring.count == 0 {
		return {}, false
	}
	item := ring.items[ring.head]
	// Clear the slot so the ring never holds a second reference to popped, owned data.
	ring.items[ring.head] = {}
	ring.head = (ring.head + 1) % len(ring.items)
	ring.count -= 1
	if ring.count == 0 {
		ring.head = 0
	}
	return item, true
}

IPC_Message_Queue :: IPC_Ring(IPC_Queue_Message)

IPC_State :: struct {
	next_fd:        linux.Fd,
	initialized:    bool,
	state_mutex:    sync.Mutex,
	endpoints:      [dynamic]IPC_Endpoint,
	main_queue:     IPC_Message_Queue,
	network_queue:  IPC_Message_Queue,
	webadmin_queue: IPC_Message_Queue,
	database_queue: IPC_Message_Queue,
	// One condition per queue, signalled on every push, so a consumer can sleep in
	// IPC_Client_wait instead of polling. All of them pair with state_mutex.
	queue_ready:    [IPC_Endpoint_Kind]sync.Cond,
}

ipcState := IPC_State {
	next_fd = linux.Fd(10),
}

IPC__state_init :: proc() {
	if ipcState.initialized {
		return
	}
	ipcState.initialized = true
	ipcState.endpoints = make([dynamic]IPC_Endpoint)
	IPC_Ring_init(&ipcState.main_queue)
	IPC_Ring_init(&ipcState.network_queue)
	IPC_Ring_init(&ipcState.webadmin_queue)
	IPC_Ring_init(&ipcState.database_queue)
}

// Exhaustive on purpose: a new request variant must decide what it owns.
IPC__database_query_request_deinit :: proc(request: common.DatabaseQueryRequest) {
	switch r in request {
	case common.DatabaseUserIdentityRequest:
		delete(r.nickname)
	case common.DatabasePostRoomChatMessageRequest:
		delete(r.content)
	case common.DatabaseCreateRoomRequest:
		delete(r.name)
		delete(r.description)
	case common.DatabaseEditRoomRequest:
		delete(r.name)
		delete(r.description)
	case common.DatabasePostDirectMessageRequest:
		delete(r.content)
	case common.DatabaseRoomListRequest,
	     common.DatabaseRoomMemberListRequest,
	     common.DatabaseRoomHistoryRequest,
	     common.DatabaseUserServerAdminRequest,
	     common.DatabaseDeleteRoomRequest,
	     common.DatabaseAddRoomMemberRequest,
	     common.DatabaseRemoveRoomMemberRequest,
	     common.DatabaseDirectHistoryRequest,
	     common.DatabaseDirectConversationListRequest,
	     common.DatabaseUserDirectoryRequest:
	case nil:
	}
}

IPC__stored_chat_message_deinit :: proc(message: common.StoredChatMessage) {
	delete(message.senderNickname)
	delete(message.timestamp)
	delete(message.content)
}

IPC__stored_direct_message_deinit :: proc(message: common.StoredDirectMessage) {
	delete(message.senderNickname)
	delete(message.recipientNickname)
	delete(message.timestamp)
	delete(message.content)
}

// Exhaustive on purpose: a new result variant must decide what it owns.
IPC__database_query_response_deinit :: proc(response: common.DatabaseQueryResponse) {
	delete(response.message)
	switch r in response.result {
	case common.DatabaseRoomListResult:
		for room in r.rooms {
			delete(room.name)
			delete(room.description)
		}
		delete(r.rooms)
	case common.DatabaseRoomMemberListResult:
		delete(r.userIDs)
	case common.DatabasePostRoomChatMessageResult:
		IPC__stored_chat_message_deinit(r.storedMessage)
		delete(r.recipientUserIDs)
	case common.DatabaseRoomHistoryResult:
		for message in r.messages {
			IPC__stored_chat_message_deinit(message)
		}
		delete(r.messages)
	case common.DatabaseRoomMutationResult:
		delete(r.room.name)
		delete(r.room.description)
	case common.DatabasePostDirectMessageResult:
		IPC__stored_direct_message_deinit(r.storedMessage)
	case common.DatabaseDirectHistoryResult:
		for message in r.messages {
			IPC__stored_direct_message_deinit(message)
		}
		delete(r.messages)
	case common.DatabaseDirectConversationListResult:
		for conversation in r.conversations {
			delete(conversation.peerNickname)
			delete(conversation.lastTimestamp)
			delete(conversation.lastContent)
		}
		delete(r.conversations)
	case common.DatabaseUserDirectoryResult:
		for user in r.users {
			delete(user.nickname)
		}
		delete(r.users)
	case common.DatabaseUserIdentityResult:
		delete(r.previousNickname)
	case common.DatabaseUserServerAdminResult:
	case nil:
	}
}

IPC__message_deinit :: proc(msg: ^Message) {
	#partial switch m in msg^ {
	case NetworkDataReceived:
		delete(m.data)
	case NetworkSendData:
		delete(m.data)
	case NetworkBroadcast:
		delete(m.data)
	case AdminGetPeersResponse:
		delete(m.peers)
	case AdminGetLogsResponse:
		for i in 0 ..< len(m.logs) {
			delete(m.logs[i])
		}
		delete(m.logs)
	case DatabaseQuery:
		IPC__database_query_request_deinit(m.request)
	case DatabaseQueryResult:
		IPC__database_query_response_deinit(m.response)
	case DatabaseError:
		delete(m.error)
	case DatabaseStartupFailed:
		delete(m.error)
	case ProcessError:
		delete(m.error)
	case:
	}
	msg^ = Message{}
}

IPC__queue_deinit :: proc(queue: ^IPC_Message_Queue) {
	for {
		entry, ok := IPC_Ring_pop(queue)
		if !ok {
			break
		}
		IPC__message_deinit(&entry.msg)
	}
	IPC_Ring_deinit(queue)
}

IPC__state_deinit :: proc() {
	if !ipcState.initialized {
		return
	}

	delete(ipcState.endpoints)
	IPC__queue_deinit(&ipcState.main_queue)
	IPC__queue_deinit(&ipcState.network_queue)
	IPC__queue_deinit(&ipcState.webadmin_queue)
	IPC__queue_deinit(&ipcState.database_queue)
	ipcState.initialized = false
}

IPC__endpoint_kind_from_socket :: proc(socket_name: string) -> IPC_Endpoint_Kind {
	if strings.contains(socket_name, "network") {
		return .Network
	}
	if strings.contains(socket_name, "webadmin") {
		return .WebAdmin
	}
	if strings.contains(socket_name, "database") {
		return .Database
	}
	if strings.contains(socket_name, "main") {
		return .Main
	}
	return .Unknown
}

IPC__find_endpoint_kind :: proc(fd: linux.Fd) -> IPC_Endpoint_Kind {
	for endpoint in ipcState.endpoints {
		if endpoint.fd == fd {
			return endpoint.kind
		}
	}
	return .Unknown
}

IPC__queue_for_kind :: proc(kind: IPC_Endpoint_Kind) -> ^IPC_Message_Queue {
	switch kind {
	case .Main:
		return &ipcState.main_queue
	case .Network:
		return &ipcState.network_queue
	case .WebAdmin:
		return &ipcState.webadmin_queue
	case .Database:
		return &ipcState.database_queue
	case .Unknown:
		return nil
	case:
		return nil
	}
}

IPC__route_to :: proc(sender: IPC_Endpoint_Kind, msg: Message) -> IPC_Endpoint_Kind {
	switch sender {
	case .Main:
		switch typeid_of(type_of(msg)) {
		case NetworkSendData, NetworkBroadcast, NetworkDisconnectPeer:
			return .Network
		case AdminQueryStatusResponse, AdminGetPeersResponse, AdminGetLogsResponse:
			return .WebAdmin
		case DatabaseQuery:
			return .Database
		case ProcessShutdown, ProcessRestart:
			return .Unknown
		case:
			return .Unknown
		}
	case .Network:
		return .Main
	case .WebAdmin:
		return .Main
	case .Database:
		return .Main
	case .Unknown:
		return .Unknown
	case:
		return .Unknown
	}
}

IPC_Server_init :: proc(ctx: ^IPC_Server_Context, socket_name: string) -> linux.Errno {
	sync.mutex_lock(&ipcState.state_mutex)
	defer sync.mutex_unlock(&ipcState.state_mutex)

	IPC__state_init()
	ctx.socket_name = socket_name
	ctx.endpoint_kind = IPC__endpoint_kind_from_socket(socket_name)
	return nil
}

IPC_Main_init :: proc() -> linux.Fd {
	sync.mutex_lock(&ipcState.state_mutex)
	defer sync.mutex_unlock(&ipcState.state_mutex)

	IPC__state_init()
	fd := ipcState.next_fd
	ipcState.next_fd += 1
	append(&ipcState.endpoints, IPC_Endpoint{fd = fd, kind = .Main})
	return fd
}

IPC_Client_init :: proc(ctx: ^IPC_Server_Context) -> (linux.Fd, linux.Errno) {
	sync.mutex_lock(&ipcState.state_mutex)
	defer sync.mutex_unlock(&ipcState.state_mutex)

	IPC__state_init()
	fd := ipcState.next_fd
	ipcState.next_fd += 1
	append(&ipcState.endpoints, IPC_Endpoint{fd = fd, kind = ctx.endpoint_kind})
	return fd, nil
}

IPC_Server_poll :: proc(ctx: ^IPC_Server_Context) {
	// In-memory coordinator does not need active polling for accept/read.
}

// IPC__push appends to the destination queue and wakes its consumer. Hold state_mutex.
IPC__push :: proc(destination: IPC_Endpoint_Kind, entry: IPC_Queue_Message) -> bool {
	queue := IPC__queue_for_kind(destination)
	if queue == nil {
		return false
	}
	IPC_Ring_push(queue, entry)
	sync.cond_broadcast(&ipcState.queue_ready[destination])
	return true
}

IPC_Client_poll :: proc(client_fd: linux.Fd) -> (Message, linux.Errno) {
	sync.mutex_lock(&ipcState.state_mutex)
	defer sync.mutex_unlock(&ipcState.state_mutex)

	kind := IPC__find_endpoint_kind(client_fd)
	queue := IPC__queue_for_kind(kind)
	if queue == nil {
		return Message{}, linux.Errno(-1)
	}

	entry, ok := IPC_Ring_pop(queue)
	if !ok {
		return Message{}, linux.Errno(-1)
	}
	return entry.msg, nil
}

// IPC_Client_wait blocks until the endpoint's queue holds a message or the timeout passes,
// and reports whether a message is waiting. Consumers call it when a poll came back empty,
// so they sleep instead of spinning and still wake as soon as a producer pushes.
IPC_Client_wait :: proc(client_fd: linux.Fd, timeout: time.Duration) -> bool {
	sync.mutex_lock(&ipcState.state_mutex)
	defer sync.mutex_unlock(&ipcState.state_mutex)

	kind := IPC__find_endpoint_kind(client_fd)
	queue := IPC__queue_for_kind(kind)
	if queue == nil {
		return false
	}
	if IPC_Ring_len(queue) > 0 {
		return true
	}
	if timeout > 0 {
		// A spurious or early wake-up is fine: callers poll again and wait again.
		sync.cond_wait_with_timeout(&ipcState.queue_ready[kind], &ipcState.state_mutex, timeout)
	}
	return IPC_Ring_len(queue) > 0
}

IPC_Client_send :: proc(client_fd: linux.Fd, msg: Message) -> linux.Errno {
	sync.mutex_lock(&ipcState.state_mutex)
	defer sync.mutex_unlock(&ipcState.state_mutex)

	sender := IPC__find_endpoint_kind(client_fd)
	destination := IPC__route_to(sender, msg)
	if destination == .Unknown {
		return linux.Errno(-1)
	}

	if !IPC__push(destination, IPC_Queue_Message{sender = sender, msg = msg}) {
		return linux.Errno(-1)
	}
	return nil
}

IPC_Server_send :: proc(ctx: ^IPC_Server_Context, client_fd: linux.Fd, msg: Message) {
	sync.mutex_lock(&ipcState.state_mutex)
	defer sync.mutex_unlock(&ipcState.state_mutex)

	destination := IPC__find_endpoint_kind(client_fd)
	sender := ctx.endpoint_kind
	if sender == .Unknown {
		sender = .Main
	}
	IPC__push(destination, IPC_Queue_Message{sender = sender, msg = msg})
}

IPC_Server_deinit :: proc(ctx: ^IPC_Server_Context) -> linux.Errno {
	return nil
}

IPC_Client_deinit :: proc(ctx: ^IPC_Server_Context) -> linux.Errno {
	return nil
}
