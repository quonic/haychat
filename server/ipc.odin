package server

import "../common"
import "core:strings"
import "core:sync"
import "core:sys/linux"
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

NetworkSendData :: struct {
	peerId:  u32,
	channel: NetworkChannel,
	data:    []u8,
}

NetworkBroadcast :: struct {
	channel: NetworkChannel,
	data:    []u8,
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

IPC_State :: struct {
	next_fd:        linux.Fd,
	initialized:    bool,
	state_mutex:    sync.Mutex,
	endpoints:      [dynamic]IPC_Endpoint,
	main_queue:     [dynamic]IPC_Queue_Message,
	network_queue:  [dynamic]IPC_Queue_Message,
	webadmin_queue: [dynamic]IPC_Queue_Message,
	database_queue: [dynamic]IPC_Queue_Message,
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
	ipcState.main_queue = make([dynamic]IPC_Queue_Message)
	ipcState.network_queue = make([dynamic]IPC_Queue_Message)
	ipcState.webadmin_queue = make([dynamic]IPC_Queue_Message)
	ipcState.database_queue = make([dynamic]IPC_Queue_Message)
}

IPC__database_query_request_deinit :: proc(request: common.DatabaseQueryRequest) {
	#partial switch request.queryType {
	case .AuthLookupByNickname:
		delete(request.authLookup.nickname)
	case .RawSQL:
		delete(request.rawSQL.query)
	case .StoreRoomChatMessage:
		delete(request.storeChat.content)
	case .CreateRoom:
		delete(request.createRoom.name)
		delete(request.createRoom.description)
	case .EditRoom:
		delete(request.editRoom.name)
		delete(request.editRoom.description)
	case:
	}
}

IPC__database_query_response_deinit :: proc(response: common.DatabaseQueryResponse) {
	delete(response.message)
	delete(response.result)
	for room in response.roomSummaries {
		delete(room.name)
		delete(room.description)
	}
	delete(response.roomSummaries)
	delete(response.memberUserIDs)
	delete(response.storedChatMessage.timestamp)
	delete(response.storedChatMessage.content)
	delete(response.mutationRoom.name)
	delete(response.mutationRoom.description)
	for message in response.historyMessages {
		delete(message.timestamp)
		delete(message.content)
	}
	delete(response.historyMessages)
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

IPC__queue_deinit :: proc(queue: ^[dynamic]IPC_Queue_Message) {
	for i in 0 ..< len(queue^) {
		IPC__message_deinit(&queue^[i].msg)
	}
	delete(queue^)
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

IPC__queue_for_kind :: proc(kind: IPC_Endpoint_Kind) -> ^[dynamic]IPC_Queue_Message {
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

IPC_Client_poll :: proc(client_fd: linux.Fd) -> (Message, linux.Errno) {
	sync.mutex_lock(&ipcState.state_mutex)
	defer sync.mutex_unlock(&ipcState.state_mutex)

	kind := IPC__find_endpoint_kind(client_fd)
	queue := IPC__queue_for_kind(kind)
	if queue == nil || len(queue^) == 0 {
		return Message{}, linux.Errno(-1)
	}

	entry := queue^[0]
	ordered_remove(queue, 0)
	return entry.msg, nil
}

IPC_Client_send :: proc(client_fd: linux.Fd, msg: Message) -> linux.Errno {
	sync.mutex_lock(&ipcState.state_mutex)
	defer sync.mutex_unlock(&ipcState.state_mutex)

	sender := IPC__find_endpoint_kind(client_fd)
	destination := IPC__route_to(sender, msg)
	if destination == .Unknown {
		return linux.Errno(-1)
	}

	queue := IPC__queue_for_kind(destination)
	if queue == nil {
		return linux.Errno(-1)
	}

	append(queue, IPC_Queue_Message{sender = sender, msg = msg})
	return nil
}

IPC_Server_send :: proc(ctx: ^IPC_Server_Context, client_fd: linux.Fd, msg: Message) {
	sync.mutex_lock(&ipcState.state_mutex)
	defer sync.mutex_unlock(&ipcState.state_mutex)

	destination := IPC__find_endpoint_kind(client_fd)
	queue := IPC__queue_for_kind(destination)
	if queue == nil {
		return
	}

	sender := ctx.endpoint_kind
	if sender == .Unknown {
		sender = .Main
	}
	append(queue, IPC_Queue_Message{sender = sender, msg = msg})
}

IPC_Server_deinit :: proc(ctx: ^IPC_Server_Context) -> linux.Errno {
	return nil
}

IPC_Client_deinit :: proc(ctx: ^IPC_Server_Context) -> linux.Errno {
	return nil
}
