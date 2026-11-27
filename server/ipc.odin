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
	NetworkVoiceSessionOpen,
	NetworkVoiceRoute,
	NetworkVoiceReset,
	// Database messages
	DatabaseQuery,
	DatabaseQueryResult,
	DatabaseError,
	DatabaseStartupReady,
	DatabaseStartupFailed,
	// Database change notifications (#116, database_notifications.odin)
	DatabaseChangeNotification,
	DatabaseChangeListening,
	// Storage worker messages (protocol 26, storage.odin)
	StorageCommand,
	StorageResponse,
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

// The transport keys are per channel (common.TransportChannel), numbered as the ENet channels
// these values name, so both enums must agree. The ENet host allocates channels
// 0..FileTransfer (network.odin, NETWORK_CHANNEL_COUNT), which includes Voice.
#assert(u8(NetworkChannel.Chat) == u8(common.TransportChannel.Control))
#assert(u8(NetworkChannel.Voice) == u8(common.TransportChannel.Voice))
#assert(u8(NetworkChannel.FileTransfer) == u8(common.TransportChannel.File))

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

// Router -> network thread, right after ServerAuthSuccess: the voice halves of the session's
// transport, taken out with common.TransportState_takeVoiceState. From here on only the
// network thread's VoiceRelay seals and opens this peer's voice datagrams; the router never
// touches voice crypto again. The keys are wiped wherever this message is freed
// (IPC__message_deinit), sent or not, so they never linger in a dropped message.
NetworkVoiceSessionOpen :: struct {
	peerId:    u32,
	userId:    int,
	sessionID: common.SessionID,
	send:      common.ChannelSendState,
	receive:   common.VoiceReceiveState,
}

NetworkVoiceRouteMember :: struct {
	peerId:   u32,
	muted:       bool, // the relay drops this peer's frames
	deafened:    bool, // the relay sends this peer nothing
	// Protocol 24: the account lacks SpeakInVoice in the room; the relay drops its frames.
	speakDenied: bool,
}

// Router -> network thread: the complete recipient set of one room's voice session, sent on
// every join, leave, mute or deafen change. It replaces the relay's previous set for roomId;
// an empty members list removes the room. members is owned.
NetworkVoiceRoute :: struct {
	roomId:    int,
	members:   []NetworkVoiceRouteMember,
	// Protocol 21: the room is encrypted, so its frames carry sealed payloads the relay checks
	// for shape only (voice_relay.odin).
	encrypted: bool,
}

// Router -> network thread: forget every voice session and route. Sent when the network
// service is stopped or restarted, so commands still queued from before the stop cannot
// attach old keys or routes to peers of the new service, whose peer IDs start over.
NetworkVoiceReset :: struct {}

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
	Database,
	Storage,
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
	IPC_Ring__wipeItems(ring.items)
	delete(ring.items, ring.allocator)
	ring^ = {}
}

IPC_Ring_len :: proc(ring: ^IPC_Ring($T)) -> int {
	return ring.count
}

IPC_Ring_capacity :: proc(ring: ^IPC_Ring($T)) -> int {
	return len(ring.items)
}

// Queued messages can carry voice keys (NetworkVoiceSessionOpen), so a buffer is zeroed before
// it goes back to the allocator; otherwise a grow would leave copies of them in freed memory.
IPC_Ring__wipeItems :: proc(items: []$T) {
	if len(items) > 0 {
		mem.zero_explicit(raw_data(items), len(items) * size_of(T))
	}
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
	IPC_Ring__wipeItems(ring.items)
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
	// Clear the slot so the ring never holds a second reference to popped, owned data, nor a
	// second copy of voice keys.
	mem.zero_explicit(&ring.items[ring.head], size_of(T))
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
	database_queue: IPC_Message_Queue,
	storage_queue:  IPC_Message_Queue,
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
	IPC_Ring_init(&ipcState.database_queue)
	IPC_Ring_init(&ipcState.storage_queue)
}

// Exhaustive on purpose: a new request variant must decide what it owns.
IPC__database_query_request_deinit :: proc(request: common.DatabaseQueryRequest) {
	switch r in request {
	case common.DatabaseUserIdentityRequest:
		delete(r.nickname)
	case common.DatabasePostRoomChatMessageRequest:
		delete(r.content)
		delete(r.sealed)
		attachments := r.attachments
		common.AttachmentRefs_deinit(&attachments)
	case common.DatabaseStoreRoomKeyEnvelopeRequest:
		delete(r.envelope)
		delete(r.recipientUserIDs)
	case common.DatabaseCreateRoomRequest:
		delete(r.name)
		delete(r.description)
		delete(r.accessRoleIds)
	case common.DatabaseEditRoomRequest:
		delete(r.name)
		delete(r.description)
		delete(r.accessRoleIds)
	case common.DatabaseRoomPermissionsRequest:
		delete(r.roles)
	case common.DatabasePostDirectMessageRequest:
		delete(r.content)
		delete(r.envelope)
		attachments := r.attachments
		common.AttachmentRefs_deinit(&attachments)
	case common.DatabaseAdminUserRequest:
		delete(r.nickname)
		delete(r.reason)
	case common.DatabaseFetchUserKeysRequest:
		delete(r.userIds)
	case common.DatabaseAppendRoomLogRequest:
		delete(r.entry)
	case common.DatabaseRoleRequest:
		delete(r.name)
		delete(r.roleIds)
	case common.DatabaseRegisterRequest:
		delete(r.nickname)
		delete(r.reason)
	case common.DatabaseInviteRequest:
		delete(r.note)
		delete(r.roleIds)
	case common.DatabaseRegistrationRequestsRequest:
		delete(r.reason)
	case common.DatabaseSharedRoomsRequest:
		delete(r.candidateUserIds)
	case common.DatabaseAttachmentRequest:
		delete(r.blobIds)
		delete(r.reason)
	case common.DatabaseMessageChangeRequest:
		request := r
		common.DatabaseMessageChangeRequest_deinit(&request)
	case common.DatabaseRestrictedChangesRequest:
		delete(r.userIds)
		delete(r.restrictedUserIds)
	case common.DatabaseRegistrationModeRequest, common.DatabaseRestrictedUsersRequest:
	case common.DatabaseRoomListRequest,
	     common.DatabaseRoomMemberListRequest,
	     common.DatabaseRoomHistoryRequest,
	     common.DatabaseDeleteRoomRequest,
	     common.DatabaseRoomMemberActionRequest,
	     common.DatabaseAdminRoomListRequest,
	     common.DatabaseDirectHistoryRequest,
	     common.DatabaseDirectConversationListRequest,
	     common.DatabaseUserDirectoryRequest,
	     common.DatabaseMarkReadRequest,
	     common.DatabasePublishEncryptionKeyRequest,
	     common.DatabaseFetchRoomLogRequest,
	     common.DatabaseFetchRoomKeysRequest,
	     common.DatabaseRoomKeyRequestCheckRequest,
	     common.DatabaseRejectRoomKeyEnvelopeRequest:
	case nil:
	}
}

IPC__stored_chat_message_deinit :: proc(message: common.StoredChatMessage) {
	delete(message.senderNickname)
	delete(message.timestamp)
	delete(message.content)
	delete(message.sealed)
	attachments := message.attachments
	common.AttachmentRefs_deinit(&attachments)
	lastEdit := message.lastEdit
	common.MessageEdit_deinit(&lastEdit)
	deletion := message.deletion
	common.MessageDeletion_deinit(&deletion)
}

IPC__stored_direct_message_deinit :: proc(message: common.StoredDirectMessage) {
	delete(message.senderNickname)
	delete(message.recipientNickname)
	delete(message.timestamp)
	delete(message.content)
	delete(message.envelope)
	attachments := message.attachments
	common.AttachmentRefs_deinit(&attachments)
	lastEdit := message.lastEdit
	common.MessageEdit_deinit(&lastEdit)
	deletion := message.deletion
	common.MessageDeletion_deinit(&deletion)
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
		delete(r.addedUserIDs)
		delete(r.memberUserIDs)
		delete(r.removedUserIDs)
	case common.DatabaseRoomMemberActionResult:
		delete(r.memberUserIDs)
		delete(r.logEntry)
		delete(r.managerUserIDs)
	case common.DatabaseAdminRoomListResult:
		for entry in r.rooms {
			delete(entry.room.name)
			delete(entry.room.description)
		}
		delete(r.rooms)
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
			delete(conversation.lastEnvelope)
			lastAttachments := conversation.lastAttachments
			common.AttachmentRefs_deinit(&lastAttachments)
			lastEdit := conversation.lastEdit
			common.MessageEdit_deinit(&lastEdit)
			lastDeletion := conversation.lastDeletion
			common.MessageDeletion_deinit(&lastDeletion)
		}
		delete(r.conversations)
	case common.DatabaseUserDirectoryResult:
		for &user in r.users {
			common.UserSummary_deinit(&user)
		}
		delete(r.users)
	case common.DatabaseUserIdentityResult:
		delete(r.previousNickname)
		delete(r.nickname)
		delete(r.banReason)
		delete(r.decisionReason)
		delete(r.roleIds)
		declined := r.declinedRequest
		common.RegistrationRequestSummary_deinit(&declined)
	case common.DatabaseAdminUserResult:
		IPC__admin_user_result_deinit(r)
	case common.DatabaseRestrictedChangesResult:
		for account in r.accounts {
			IPC__admin_user_result_deinit(account)
		}
		delete(r.accounts)
	case common.DatabaseRegisterResult:
		delete(r.nickname)
		delete(r.roleIds)
		request := r.request
		common.RegistrationRequestSummary_deinit(&request)
	case common.DatabaseInviteResult:
		invite := r.invite
		common.InviteSummary_deinit(&invite)
		for &listed in r.invites {
			common.InviteSummary_deinit(&listed)
		}
		delete(r.invites)
	case common.DatabaseRegistrationRequestsResult:
		for &listed in r.requests {
			common.RegistrationRequestSummary_deinit(&listed)
		}
		delete(r.requests)
		request := r.request
		common.RegistrationRequestSummary_deinit(&request)
	case common.DatabaseSharedRoomsResult:
		delete(r.userIds)
	case common.DatabaseRestrictedUsersResult:
		delete(r.userIds)
	case common.DatabaseMessageChangeResult:
		result := r
		common.DatabaseMessageChangeResult_deinit(&result)
	case common.DatabaseAttachmentResult:
		delete(r.blobs)
		delete(r.removal.readerUserIds)
		delete(r.accounts)
		removals := r.removals
		common.AttachmentRemovalEntries_deinit(&removals)
	case common.DatabaseRegistrationModeResult:
	case common.DatabaseRoleResult:
		for &role in r.roles {
			common.RoleSummary_deinit(&role)
		}
		delete(r.roles)
		delete(r.role.name)
		user := r.user
		common.UserSummary_deinit(&user)
		for account in r.affected {
			delete(account.nickname)
		}
		delete(r.affected)
		for &change in r.membershipChanges {
			common.DatabaseRoomMembershipChange_deinit(&change)
		}
		delete(r.membershipChanges)
		delete(r.roomPermissionUserIDs)
	case common.DatabaseRoomPermissionsResult:
		delete(r.roles)
		delete(r.accessRoleIds)
		delete(r.memberUserIDs)
	case common.DatabaseFetchUserKeysResult:
		delete(r.keys)
		delete(r.missingUserIds)
	case common.DatabaseAppendRoomLogResult:
		delete(r.entry)
		delete(r.memberUserIDs)
		delete(r.managerUserIDs)
	case common.DatabaseFetchRoomLogResult:
		for entry in r.entries {
			delete(entry)
		}
		delete(r.entries)
	case common.DatabaseStoreRoomKeyEnvelopeResult:
		delete(r.stored.envelope)
		delete(r.recipientUserIDs)
	case common.DatabaseFetchRoomKeysResult:
		for envelope in r.envelopes {
			delete(envelope.envelope)
		}
		delete(r.envelopes)
	case common.DatabaseRoomKeyRequestCheckResult:
		delete(r.memberUserIDs)
	case common.DatabaseMarkReadResult,
	     common.DatabasePublishEncryptionKeyResult,
	     common.DatabaseRejectRoomKeyEnvelopeResult:
	case nil:
	}
}

IPC__admin_user_result_deinit :: proc(result: common.DatabaseAdminUserResult) {
	user := result.user
	common.UserSummary_deinit(&user)
	delete(result.previousNickname)
	delete(result.addedRoomIDs)
}

IPC__message_deinit :: proc(msg: ^Message) {
	#partial switch &m in msg^ {
	case NetworkDataReceived:
		delete(m.data)
	case NetworkSendData:
		delete(m.data)
	case NetworkBroadcast:
		delete(m.data)
	case NetworkVoiceSessionOpen:
		// m is a reference into msg, so this wipes the queued copy itself.
		common.ChannelSendState_wipe(&m.send)
		common.VoiceReceiveState_wipe(&m.receive)
	case NetworkVoiceRoute:
		delete(m.members)
	case DatabaseQuery:
		IPC__database_query_request_deinit(m.request)
	case DatabaseQueryResult:
		IPC__database_query_response_deinit(m.response)
	case DatabaseError:
		delete(m.error)
	case DatabaseStartupFailed:
		delete(m.error)
	case DatabaseChangeNotification:
		delete(m.ids)
	case StorageCommand:
		StorageRequest_deinit(m.request)
	case StorageResponse:
		StorageResult_deinit(m.result)
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
	IPC__queue_deinit(&ipcState.database_queue)
	IPC__queue_deinit(&ipcState.storage_queue)
	ipcState.initialized = false
}

IPC__endpoint_kind_from_socket :: proc(socket_name: string) -> IPC_Endpoint_Kind {
	if strings.contains(socket_name, "network") {
		return .Network
	}
	if strings.contains(socket_name, "database") {
		return .Database
	}
	if strings.contains(socket_name, "storage") {
		return .Storage
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
	case .Database:
		return &ipcState.database_queue
	case .Storage:
		return &ipcState.storage_queue
	case .Unknown:
		return nil
	case:
		return nil
	}
}

IPC__route_to :: proc(sender: IPC_Endpoint_Kind, msg: Message) -> IPC_Endpoint_Kind {
	switch sender {
	case .Main:
		// Switch on the variant the union holds. `type_of(msg)` is `Message` itself, so a
		// typeid switch on it never matched a variant and routed every message to Unknown.
		#partial switch _ in msg {
		case NetworkSendData,
		     NetworkBroadcast,
		     NetworkDisconnectPeer,
		     NetworkVoiceSessionOpen,
		     NetworkVoiceRoute,
		     NetworkVoiceReset:
			return .Network
		case DatabaseQuery:
			return .Database
		case StorageCommand:
			return .Storage
		case:
			// Main addresses shutdown and restart to each service with IPC_Server_send.
			return .Unknown
		}
	case .Network:
		return .Main
	case .Database:
		return .Main
	case .Storage:
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
