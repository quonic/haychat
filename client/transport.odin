package client

import "../common"
import "core:crypto/ecdh"
import "core:encoding/cbor"
import "core:fmt"
import "core:strings"
import "core:time"
import "vendor:ENet"

STARTUP_AUTH_CHANNEL_CHAT :: u8(1)
STARTUP_AUTH_CHANNEL_COUNT :: uint(5)

ClientTransportResult :: struct {
	responsePacketBytes: []u8,
	hasResponse:         bool,
	openedPacket:        common.Packet,
	hasOpenedPacket:     bool,
}

ClientTransportRuntimeEventKind :: enum {
	None,
	RoomChatReceived,
	RoomListReceived,
	RoomHistoryReceived,
	RoomMembershipChanged,
	RoomEdited,
	RoomDeleted,
	ProtocolError,
	// Connection lifecycle, emitted by the connect state machine in connection.odin.
	Connecting,
	Connected,
	ConnectFailed,
	Disconnected,
	// Direct messages, the user directory, and presence (protocol 7).
	DirectMessageReceived,
	DirectHistoryReceived,
	UserListReceived,
	DirectConversationsReceived,
	UserPresenceChanged,
	// The creator's answer to ClientCreateRoom (protocol 8): room holds the new room.
	RoomCreated,
}

ClientTransportRuntimeEvent :: struct {
	kind:              ClientTransportRuntimeEventKind,
	serverID:          int,
	senderID:          int,
	senderNickname:    string, // Set for .RoomChatReceived
	roomID:            int,
	messageID:         int,
	timestamp:         string,
	message:           string,
	rooms:             [dynamic]common.RoomSummary,
	messages:          [dynamic]common.StoredChatMessage,
	hasOlder:          bool,
	joined:            bool,
	room:              common.RoomSummary,
	// Connection lifecycle fields. userID, nickname, and isAdmin are set on Connected. retryAt
	// is when the worker tries again after Disconnected or a retryable ConnectFailed.
	userID:            int,
	nickname:          string,
	isAdmin:           bool,
	failureKind:       ClientConnectFailureKind,
	retryable:         bool,
	retryAt:           time.Tick,
	// Hex server identity key and fingerprint: on Connected, a key pinned on first use that
	// the config should store; on a ServerKeyChanged failure, the key the server offered.
	serverPublicKey:   string,
	serverFingerprint: string,
	// Direct message fields. directMessage is set on DirectMessageReceived; peerUserID,
	// directMessages and hasOlder on DirectHistoryReceived; users on UserListReceived;
	// conversations on DirectConversationsReceived; user on UserPresenceChanged. All strings
	// and arrays are owned by the event until State takes them.
	directMessage:     common.StoredDirectMessage,
	peerUserID:        int,
	directMessages:    [dynamic]common.StoredDirectMessage,
	users:             [dynamic]common.UserSummary,
	conversations:     [dynamic]common.DirectConversationSummary,
	user:              common.UserSummary,
}

ClientServerTransport :: struct {
	serverID:                  int,
	serverName:                string,
	serverHost:                string,
	serverPort:                i32,
	nickname:                  string,
	clientIdentityPrivateKey:  common.IdentityPrivateKeyBytes,
	clientIdentityPublicKey:   common.IdentityPublicKeyBytes,
	clientEphemeralPrivateKey: ecdh.Private_Key,
	clientEphemeralPublicKey:  common.KeyExchangePublicKeyBytes,
	serverIdentityPublicKey:   common.IdentityPublicKeyBytes,
	serverEphemeralPublicKey:  common.KeyExchangePublicKeyBytes,
	sessionID:                 common.SessionID,
	authChallenge:             common.AuthChallengeBytes,
	pendingKeys:               common.DirectionalTransportKeys,
	pendingKeysReady:          bool,
	transport:                 common.TransportState,
	authenticatedUserID:       int,
	// Whether ServerAuthSuccess said the account is an admin; fixed for the session.
	authenticatedIsAdmin:      bool,
	lastError:                 string,
	enetHost:                  ^ENet.Host,
	enetPeer:                  ^ENet.Peer,
	// Owned copies of the server's pins, so the worker thread never reads State.config.
	pinnedServerPublicKey:     string,
	pinnedServerFingerprint:   string,
	// The key a server offered when it did not match the pin; kept for "Trust the new key".
	rejectedServerPublicKey:   common.IdentityPublicKeyBytes,
	hasRejectedServerKey:      bool,
	// Set when the server or identity config cannot produce a valid ClientHello at all.
	configInvalid:             bool,
	connection:                ClientConnection,
}

ClientServerTransport_setLastError :: proc(transport: ^ClientServerTransport, message: string) {
	if len(transport.lastError) > 0 {
		delete(transport.lastError)
	}
	transport.lastError = strings.clone(message)
}

ClientServerTransport_hasLiveENetSession :: proc(transport: ^ClientServerTransport) -> bool {
	return transport.enetHost != nil && transport.enetPeer != nil
}

// Closes the ENet session. ENet itself stays initialised for the whole process (see
// clientEnsureENetInitialized), so this never deinitialises it.
ClientServerTransport_releaseENetSession :: proc(transport: ^ClientServerTransport) {
	if transport.enetPeer != nil {
		// Tells a still-connected server right away, so it can drop the session; a peer that
		// is already disconnected is only reset.
		ENet.peer_disconnect_now(transport.enetPeer, 0)
		transport.enetPeer = nil
	}
	if transport.enetHost != nil {
		ENet.host_destroy(transport.enetHost)
		transport.enetHost = nil
	}
}

ClientServerTransport_clearSessionRuntimeState :: proc(transport: ^ClientServerTransport) {
	ClientServerTransport_releaseENetSession(transport)
	peerTrustState := transport.transport.peerTrustState
	common.TransportState_reset(&transport.transport)
	transport.transport.peerTrustState = peerTrustState
	transport.serverIdentityPublicKey = {}
	transport.serverEphemeralPublicKey = {}
	transport.sessionID = {}
	transport.authChallenge = {}
	transport.pendingKeys = {}
	transport.pendingKeysReady = false
	transport.authenticatedUserID = 0
	transport.authenticatedIsAdmin = false
}

// Releases the ENet session and every string the transport owns.
ClientServerTransport_deinit :: proc(transport: ^ClientServerTransport) {
	ClientServerTransport_releaseENetSession(transport)
	delete(transport.serverName)
	delete(transport.serverHost)
	delete(transport.nickname)
	delete(transport.lastError)
	delete(transport.pinnedServerPublicKey)
	delete(transport.pinnedServerFingerprint)
	transport^ = {}
}

ClientTransportCatalog_deinit :: proc(catalog: ^[dynamic]ClientServerTransport) {
	for index in 0 ..< len(catalog) {
		ClientServerTransport_deinit(&catalog[index])
	}
	delete(catalog^)
	catalog^ = nil
}

ClientServerTransport_fail :: proc(transport: ^ClientServerTransport, message: string) {
	ClientServerTransport_setLastError(transport, message)
	ClientServerTransport_clearSessionRuntimeState(transport)
	transport.transport.phase = .Failed
}

ClientServerTransport_runtimeProtocolError :: proc(
	transport: ^ClientServerTransport,
	message: string,
) {
	ClientServerTransport_setLastError(transport, message)
}

ClientServerTransport_handleDisconnect :: proc(transport: ^ClientServerTransport) {
	wasFailed := transport.transport.phase == .Failed
	ClientServerTransport_clearSessionRuntimeState(transport)
	if wasFailed {
		transport.transport.phase = .Failed
	}
}

ClientTransportRuntimeEvent_deinit :: proc(event: ^ClientTransportRuntimeEvent) {
	delete(event.senderNickname)
	delete(event.timestamp)
	delete(event.message)
	for room in event.rooms {
		delete(room.name)
		delete(room.description)
	}
	delete(event.rooms)
	for message in event.messages {
		delete(message.senderNickname)
		delete(message.timestamp)
		delete(message.content)
	}
	delete(event.messages)
	delete(event.room.name)
	delete(event.room.description)
	delete(event.nickname)
	delete(event.serverPublicKey)
	delete(event.serverFingerprint)
	StoredDirectMessage_deinit(&event.directMessage)
	StoredDirectMessages_deinit(&event.directMessages)
	UserSummaries_deinit(&event.users)
	DirectConversationSummaries_deinit(&event.conversations)
	delete(event.user.nickname)
	event^ = {}
}

StoredDirectMessage_deinit :: proc(message: ^common.StoredDirectMessage) {
	delete(message.senderNickname)
	delete(message.recipientNickname)
	delete(message.timestamp)
	delete(message.content)
	message^ = {}
}

StoredDirectMessages_deinit :: proc(messages: ^[dynamic]common.StoredDirectMessage) {
	for index in 0 ..< len(messages) {
		StoredDirectMessage_deinit(&messages[index])
	}
	delete(messages^)
	messages^ = nil
}

UserSummaries_deinit :: proc(users: ^[dynamic]common.UserSummary) {
	for user in users {
		delete(user.nickname)
	}
	delete(users^)
	users^ = nil
}

DirectConversationSummary_deinit :: proc(conversation: ^common.DirectConversationSummary) {
	delete(conversation.peerNickname)
	delete(conversation.lastTimestamp)
	delete(conversation.lastContent)
	conversation^ = {}
}

DirectConversationSummaries_deinit :: proc(
	conversations: ^[dynamic]common.DirectConversationSummary,
) {
	for index in 0 ..< len(conversations) {
		DirectConversationSummary_deinit(&conversations[index])
	}
	delete(conversations^)
	conversations^ = nil
}

ClientServerTransport_makeRuntimeEvent :: proc(
	transport: ^ClientServerTransport,
	kind: ClientTransportRuntimeEventKind,
	message: string,
	roomID: int = 0,
	senderID: int = 0,
) -> ClientTransportRuntimeEvent {
	return ClientTransportRuntimeEvent {
		kind = kind,
		serverID = transport.serverID,
		senderID = senderID,
		roomID = roomID,
		message = strings.clone(message),
	}
}

ClientServerTransport_runtimeRoomID :: proc(roomID: int) -> int {
	if roomID == 0 {
		return common.GENERAL_ROOM_ID
	}
	return roomID
}

ClientServerTransport_initFailed :: proc(
	server: Server,
	message: string,
) -> ClientServerTransport {
	transport := ClientServerTransport {
		serverID      = server.id,
		serverName    = strings.clone(server.name),
		serverHost    = strings.clone(server.host),
		serverPort    = server.port,
		transport     = common.TransportState_init(.Client),
		configInvalid = true,
	}
	ClientServerTransport_fail(&transport, message)
	transport.connection.status = .Failed
	return transport
}

ClientServerTransport_init :: proc(
	server: Server,
	config: Config,
) -> (
	ClientServerTransport,
	string,
	bool,
) {
	if len(config.display_name) < DISPLAY_NAME_MIN_BYTES ||
	   len(config.display_name) > DISPLAY_NAME_MAX_BYTES {
		return {}, CLIENT_INVALID_NICKNAME_MESSAGE, false
	}

	clientPrivateKey, privateKeyOK := common.identityPrivateKeyFromHex(config.private_key)
	clientPublicKey, publicKeyOK := common.identityPublicKeyFromHex(config.public_key)
	if !privateKeyOK || !publicKeyOK {
		return {}, CLIENT_INVALID_IDENTITY_MESSAGE, false
	}

	clientEphemeralPrivateKey, clientEphemeralPublicKey, clientEphemeralOK :=
		common.generateKeyExchangeKeyPair()
	if !clientEphemeralOK {
		return {}, "failed to generate client ephemeral key pair", false
	}

	transport := ClientServerTransport {
			serverID                  = server.id,
			serverName                = strings.clone(server.name),
			serverHost                = strings.clone(server.host),
			serverPort                = server.port,
			nickname                  = strings.clone(config.display_name),
			clientIdentityPrivateKey  = clientPrivateKey,
			clientIdentityPublicKey   = clientPublicKey,
			clientEphemeralPrivateKey = clientEphemeralPrivateKey,
			clientEphemeralPublicKey  = clientEphemeralPublicKey,
			transport                 = common.TransportState_init(.Client),
			pinnedServerPublicKey     = strings.clone(server.pinned_server_public_key),
			pinnedServerFingerprint   = strings.clone(server.pinned_server_fingerprint),
		}
	return transport, "", true
}

// Builds the transport for one server; a config that cannot work yields a failed transport
// that keeps the reason in lastError.
ClientServerTransport_initForServer :: proc(
	server: Server,
	config: Config,
) -> ClientServerTransport {
	transport, message, ok := ClientServerTransport_init(server, config)
	if ok {
		return transport
	}
	return ClientServerTransport_initFailed(server, message)
}

ClientTransportCatalog_init :: proc(config: ^Config) -> [dynamic]ClientServerTransport {
	catalog := make([dynamic]ClientServerTransport, 0, len(config.servers))
	for server in config.servers {
		append(&catalog, ClientServerTransport_initForServer(server, config^))
	}
	return catalog
}

ClientServerTransport_sendENetPacket :: proc(
	host: ^ENet.Host,
	peer: ^ENet.Peer,
	channelID: u8,
	packetBytes: []u8,
) -> bool {
	dataPtr: rawptr = nil
	if len(packetBytes) > 0 {
		dataPtr = rawptr(&packetBytes[0])
	}

	packet := ENet.packet_create(dataPtr, uint(len(packetBytes)), {ENet.PacketFlag.RELIABLE})
	if packet == nil {
		return false
	}

	if ENet.peer_send(peer, channelID, packet) != 0 {
		ENet.packet_destroy(packet)
		return false
	}

	ENet.host_flush(host)
	return true
}

ClientServerTransport_beginHandshake :: proc(transport: ^ClientServerTransport) -> ([]u8, bool) {
	transport.pendingKeysReady = false
	transport.transport.phase = .ClientHelloSent

	clientHello := common.ClientHello {
		version                  = common.protocolVersion,
		nickname                 = transport.nickname,
		clientIdentityPublicKey  = transport.clientIdentityPublicKey,
		clientEphemeralPublicKey = transport.clientEphemeralPublicKey,
	}
	return common.buildPacketBytes(.ClientHello, clientHello)
}

// Handles one plaintext handshake packet from the server. Runs on the network worker thread,
// so it reads the pins from the transport's own copies rather than the shared config.
ClientServerTransport_handleIncomingPacket :: proc(
	transport: ^ClientServerTransport,
	packetBytes: []u8,
) -> (
	ClientTransportResult,
	bool,
) {
	result: ClientTransportResult

	outerPacket: common.Packet
	if cbor.unmarshal(packetBytes, &outerPacket) != nil {
		ClientServerTransport_fail(transport, "invalid outer packet")
		return result, false
	}
	defer delete(outerPacket.payload)

	#partial switch outerPacket.messageType {
	case .ServerHello:
		if transport.transport.phase != .ClientHelloSent {
			ClientServerTransport_fail(transport, "unexpected ServerHello")
			return result, false
		}

		serverHello: common.ServerHello
		if cbor.unmarshal(outerPacket.payload, &serverHello) != nil {
			ClientServerTransport_fail(transport, "invalid ServerHello payload")
			return result, false
		}

		clientHello := common.ClientHello {
			version                  = common.protocolVersion,
			nickname                 = transport.nickname,
			clientIdentityPublicKey  = transport.clientIdentityPublicKey,
			clientEphemeralPublicKey = transport.clientEphemeralPublicKey,
		}
		if !common.verifyServerHello(serverHello, clientHello) {
			ClientServerTransport_fail(transport, "server hello signature verification failed")
			return result, false
		}

		// Refuse to authenticate to a server whose key no longer matches the pin: the user
		// has to accept the new key explicitly.
		serverKey := serverHello.serverIdentityPublicKey
		if !ClientServerTransport_pinServerIdentity(transport, serverKey) {
			ClientServerTransport_fail(transport, SERVER_KEY_CHANGED_MESSAGE)
			return result, false
		}
		transport.serverIdentityPublicKey = serverHello.serverIdentityPublicKey
		transport.serverEphemeralPublicKey = serverHello.serverEphemeralPublicKey
		transport.sessionID = serverHello.sessionID
		transport.transport.phase = .ServerHelloSent
		return result, true

	case .ServerAuthChallenge:
		if transport.transport.phase != .ServerHelloSent {
			ClientServerTransport_fail(transport, "unexpected auth challenge")
			return result, false
		}

		authChallenge: common.ServerAuthChallengePayload
		if cbor.unmarshal(outerPacket.payload, &authChallenge) != nil {
			ClientServerTransport_fail(transport, "invalid auth challenge payload")
			return result, false
		}

		requestSessionID := authChallenge.sessionID
		storedSessionID := transport.sessionID
		if !common.constantTimeEqual(requestSessionID[:], storedSessionID[:]) {
			ClientServerTransport_fail(transport, "auth challenge session ID mismatch")
			return result, false
		}

		transport.authChallenge = authChallenge.challenge
		clientAuthProof := common.buildClientAuthProof(
			transport.sessionID,
			transport.authChallenge,
			transport.nickname,
			transport.clientIdentityPublicKey,
			transport.clientEphemeralPublicKey,
			transport.serverIdentityPublicKey,
			transport.serverEphemeralPublicKey,
		)
		clientAuthRequest, clientAuthRequestOK := common.signClientAuthRequest(
			transport.clientIdentityPrivateKey,
			clientAuthProof,
		)
		if !clientAuthRequestOK {
			ClientServerTransport_fail(transport, "failed to sign auth request")
			return result, false
		}

		sharedSecret, sharedSecretOK := common.deriveSharedSecret(
			&transport.clientEphemeralPrivateKey,
			transport.serverEphemeralPublicKey,
		)
		if !sharedSecretOK {
			ClientServerTransport_fail(transport, "failed to derive shared secret")
			return result, false
		}

		serverHelloProof := common.buildServerHelloProof(
			transport.sessionID,
			transport.nickname,
			transport.clientIdentityPublicKey,
			transport.clientEphemeralPublicKey,
			transport.serverIdentityPublicKey,
			transport.serverEphemeralPublicKey,
		)
		transcriptHash, transcriptHashOK := common.deriveHandshakeTranscriptHash(
			serverHelloProof,
			clientAuthProof,
		)
		if !transcriptHashOK {
			ClientServerTransport_fail(transport, "failed to derive transcript hash")
			return result, false
		}

		transport.pendingKeys = common.deriveDirectionalTransportKeys(
			.Client,
			transport.sessionID,
			sharedSecret,
			transcriptHash,
		)
		transport.pendingKeysReady = true
		transport.transport.phase = .AwaitingAuthResult

		responsePacketBytes, responseOK := common.buildPacketBytes(
			.ClientAuthRequest,
			clientAuthRequest,
		)
		if !responseOK {
			ClientServerTransport_fail(transport, "failed to encode auth request packet")
			return result, false
		}

		result.responsePacketBytes = responsePacketBytes
		result.hasResponse = true
		return result, true

	case .ServerAuthSuccess:
		if transport.transport.phase != .AwaitingAuthResult || !transport.pendingKeysReady {
			ClientServerTransport_fail(transport, "unexpected auth success")
			return result, false
		}

		authSuccess: common.ServerAuthSuccessPayload
		if cbor.unmarshal(outerPacket.payload, &authSuccess) != nil {
			ClientServerTransport_fail(transport, "invalid auth success payload")
			return result, false
		}
		defer delete(authSuccess.message)

		common.TransportState_activate(
			&transport.transport,
			transport.sessionID,
			transport.pendingKeys,
			transport.transport.peerTrustState,
		)
		transport.pendingKeysReady = false
		transport.authenticatedUserID = authSuccess.userId
		transport.authenticatedIsAdmin = authSuccess.isAdmin
		return result, true

	case .ServerAuthFailure:
		authFailure: common.ServerAuthFailurePayload
		if cbor.unmarshal(outerPacket.payload, &authFailure) != nil {
			ClientServerTransport_fail(transport, "invalid auth failure payload")
			return result, false
		}
		defer delete(authFailure.message)
		ClientServerTransport_fail(transport, authFailure.message)
		return result, false

	case .EncryptedPacket:
		if !common.TransportState_canEncrypt(&transport.transport) {
			ClientServerTransport_fail(transport, "encrypted packet received before auth success")
			return result, false
		}

		innerPacket, openOK := common.openPacketForSession(&transport.transport, outerPacket)
		if !openOK {
			ClientServerTransport_fail(transport, "failed to open encrypted packet")
			return result, false
		}
		result.openedPacket = innerPacket
		result.hasOpenedPacket = true
		return result, true

	case .ServerProtocolError:
		protocolError: common.ProtocolErrorResponse
		if cbor.unmarshal(outerPacket.payload, &protocolError) == nil {
			defer delete(protocolError.message)
			ClientServerTransport_fail(transport, protocolError.message)
		} else {
			ClientServerTransport_fail(transport, "server protocol error")
		}
		return result, false

	case:
		ClientServerTransport_fail(
			transport,
			fmt.tprintf("unexpected server message type: %v", outerPacket.messageType),
		)
		return result, false
	}
}

ClientServerTransport_buildEncryptedPacketBytes :: proc(
	transport: ^ClientServerTransport,
	messageType: common.MessageType,
	payload: any,
) -> (
	[]u8,
	bool,
) {
	if !common.TransportState_canEncrypt(&transport.transport) {
		ClientServerTransport_fail(transport, "transport not established")
		return nil, false
	}

	sealedPacket, sealOK := common.sealPacketForSession(&transport.transport, messageType, payload)
	if !sealOK {
		ClientServerTransport_fail(transport, "failed to seal encrypted packet")
		return nil, false
	}
	defer delete(sealedPacket.payload)

	packetBytes, packetErr := cbor.marshal(sealedPacket)
	if packetErr != nil {
		ClientServerTransport_fail(transport, "failed to marshal encrypted packet")
		return nil, false
	}
	return packetBytes, true
}

ClientServerTransport_buildRoomChatPacketBytes :: proc(
	transport: ^ClientServerTransport,
	roomID: int,
	content: string,
) -> (
	[]u8,
	bool,
) {
	return ClientServerTransport_buildEncryptedPacketBytes(
		transport,
		.ClientChatMessage,
		common.ClientChatMessagePayload {
			roomId = ClientServerTransport_runtimeRoomID(roomID),
			content = content,
		},
	)
}

ClientServerTransport_sendRoomChatMessage :: proc(
	transport: ^ClientServerTransport,
	roomID: int,
	content: string,
) -> bool {
	// Not being connected yet is normal while the worker connects or reconnects, so it only
	// reports an error instead of failing (and tearing down) the session.
	if !ClientServerTransport_isConnected(transport) {
		ClientServerTransport_setLastError(transport, NOT_CONNECTED_MESSAGE)
		return false
	}

	packetBytes, ok := ClientServerTransport_buildRoomChatPacketBytes(transport, roomID, content)
	if !ok {
		return false
	}
	defer delete(packetBytes)

	if !ClientServerTransport_sendENetPacket(
		transport.enetHost,
		transport.enetPeer,
		STARTUP_AUTH_CHANNEL_CHAT,
		packetBytes,
	) {
		ClientServerTransport_fail(transport, "failed to send room chat packet")
		return false
	}

	return true
}

ClientServerTransport_sendEncryptedRuntimeMessage :: proc(
	transport: ^ClientServerTransport,
	messageType: common.MessageType,
	payload: any,
) -> bool {
	// Not being connected yet is normal while the worker connects or reconnects, so it only
	// reports an error instead of failing (and tearing down) the session.
	if !ClientServerTransport_isConnected(transport) {
		ClientServerTransport_setLastError(transport, NOT_CONNECTED_MESSAGE)
		return false
	}
	packetBytes, ok := ClientServerTransport_buildEncryptedPacketBytes(
		transport,
		messageType,
		payload,
	)
	if !ok {
		return false
	}
	defer delete(packetBytes)
	if !ClientServerTransport_sendENetPacket(
		transport.enetHost,
		transport.enetPeer,
		STARTUP_AUTH_CHANNEL_CHAT,
		packetBytes,
	) {
		ClientServerTransport_fail(transport, "failed to send encrypted runtime packet")
		return false
	}
	return true
}

ClientServerTransport_requestRoomList :: proc(transport: ^ClientServerTransport) -> bool {
	return ClientServerTransport_sendEncryptedRuntimeMessage(
		transport,
		.ClientListRooms,
		common.ClientListRoomsPayload{},
	)
}

ClientServerTransport_requestRoomHistory :: proc(
	transport: ^ClientServerTransport,
	roomID: int,
	beforeMessageID: int,
	limit: int,
) -> bool {
	return ClientServerTransport_sendEncryptedRuntimeMessage(
		transport,
		.ClientFetchRoomHistory,
		common.ClientFetchRoomHistoryPayload {
			roomId = ClientServerTransport_runtimeRoomID(roomID),
			beforeMessageID = beforeMessageID,
			limit = limit,
		},
	)
}

// Direct messages share the room chat channel and the not-connected handling of every other
// runtime request.
ClientServerTransport_sendDirectMessage :: proc(
	transport: ^ClientServerTransport,
	recipientUserID: int,
	content: string,
) -> bool {
	return ClientServerTransport_sendEncryptedRuntimeMessage(
		transport,
		.ClientDirectMessage,
		common.ClientDirectMessagePayload{recipientUserId = recipientUserID, content = content},
	)
}

ClientServerTransport_requestDirectHistory :: proc(
	transport: ^ClientServerTransport,
	peerUserID: int,
	beforeMessageID: int,
	limit: int,
) -> bool {
	return ClientServerTransport_sendEncryptedRuntimeMessage(
		transport,
		.ClientFetchDirectHistory,
		common.ClientFetchDirectHistoryPayload {
			peerUserId = peerUserID,
			beforeMessageID = beforeMessageID,
			limit = limit,
		},
	)
}

ClientServerTransport_requestUserList :: proc(transport: ^ClientServerTransport) -> bool {
	return ClientServerTransport_sendEncryptedRuntimeMessage(
		transport,
		.ClientUserList,
		common.ClientListUsersPayload{},
	)
}

ClientServerTransport_requestDirectConversations :: proc(
	transport: ^ClientServerTransport,
) -> bool {
	return ClientServerTransport_sendEncryptedRuntimeMessage(
		transport,
		.ClientListDirectConversations,
		common.ClientListDirectConversationsPayload{},
	)
}

// Room management (admins only). The server checks the admin role itself and answers anyone
// else with ServerProtocolError "Admin permission required".
ClientServerTransport_createRoom :: proc(
	transport: ^ClientServerTransport,
	name: string,
	description: string,
) -> bool {
	return ClientServerTransport_sendEncryptedRuntimeMessage(
		transport,
		.ClientCreateRoom,
		common.ClientCreateRoomPayload{name = name, description = description},
	)
}

ClientServerTransport_editRoom :: proc(
	transport: ^ClientServerTransport,
	roomID: int,
	name: string,
	description: string,
) -> bool {
	return ClientServerTransport_sendEncryptedRuntimeMessage(
		transport,
		.ClientEditRoom,
		common.ClientEditRoomPayload{roomId = roomID, name = name, description = description},
	)
}

ClientServerTransport_deleteRoom :: proc(transport: ^ClientServerTransport, roomID: int) -> bool {
	return ClientServerTransport_sendEncryptedRuntimeMessage(
		transport,
		.ClientDeleteRoom,
		common.ClientDeleteRoomPayload{roomId = roomID},
	)
}

// Reports a payload that failed to decode as a ProtocolError event.
@(private = "file")
ClientServerTransport_invalidPayloadEvent :: proc(
	transport: ^ClientServerTransport,
	message: string,
) -> ClientTransportRuntimeEvent {
	ClientServerTransport_runtimeProtocolError(transport, message)
	return ClientServerTransport_makeRuntimeEvent(transport, .ProtocolError, transport.lastError)
}

ClientServerTransport_translateRuntimeOpenedPacket :: proc(
	transport: ^ClientServerTransport,
	innerPacket: common.Packet,
) -> (
	ClientTransportRuntimeEvent,
	bool,
) {
	#partial switch innerPacket.messageType {
	case .ServerChatMessage:
		chatPayload: common.ServerChatMessagePayload
		if cbor.unmarshal(innerPacket.payload, &chatPayload) != nil {
			ClientServerTransport_runtimeProtocolError(transport, "invalid server chat payload")
			return ClientServerTransport_makeRuntimeEvent(
					transport,
					.ProtocolError,
					transport.lastError,
				),
				true
		}
		return ClientTransportRuntimeEvent {
				kind = .RoomChatReceived,
				serverID = transport.serverID,
				senderID = chatPayload.senderId,
				senderNickname = chatPayload.senderNickname,
				roomID = chatPayload.roomId,
				messageID = chatPayload.id,
				timestamp = chatPayload.timestamp,
				message = chatPayload.content,
			},
			true

	case .ServerListRooms:
		payload: common.ServerListRoomsPayload
		if cbor.unmarshal(innerPacket.payload, &payload) != nil {
			ClientServerTransport_runtimeProtocolError(transport, "invalid room list payload")
			return ClientServerTransport_makeRuntimeEvent(
					transport,
					.ProtocolError,
					transport.lastError,
				),
				true
		}
		return ClientTransportRuntimeEvent {
				kind = .RoomListReceived,
				serverID = transport.serverID,
				rooms = payload.rooms,
			},
			true

	case .ServerRoomHistory:
		payload: common.ServerRoomHistoryPayload
		if cbor.unmarshal(innerPacket.payload, &payload) != nil {
			ClientServerTransport_runtimeProtocolError(transport, "invalid room history payload")
			return ClientServerTransport_makeRuntimeEvent(
					transport,
					.ProtocolError,
					transport.lastError,
				),
				true
		}
		return ClientTransportRuntimeEvent {
				kind = .RoomHistoryReceived,
				serverID = transport.serverID,
				roomID = payload.roomId,
				messages = payload.messages,
				hasOlder = payload.hasOlder,
			},
			true

	case .ServerRoomMembershipChanged:
		payload: common.ServerRoomMembershipChangedPayload
		if cbor.unmarshal(innerPacket.payload, &payload) != nil {
			ClientServerTransport_runtimeProtocolError(
				transport,
				"invalid room membership payload",
			)
			return ClientServerTransport_makeRuntimeEvent(
					transport,
					.ProtocolError,
					transport.lastError,
				),
				true
		}
		return ClientTransportRuntimeEvent {
				kind = .RoomMembershipChanged,
				serverID = transport.serverID,
				roomID = payload.roomId,
				joined = payload.joined,
			},
			true

	case .ServerEditRoom:
		payload: common.ServerRoomMutationPayload
		if cbor.unmarshal(innerPacket.payload, &payload) != nil {
			ClientServerTransport_runtimeProtocolError(transport, "invalid room edit payload")
			return ClientServerTransport_makeRuntimeEvent(
					transport,
					.ProtocolError,
					transport.lastError,
				),
				true
		}
		return ClientTransportRuntimeEvent {
				kind = .RoomEdited,
				serverID = transport.serverID,
				roomID = payload.roomId,
				room = payload.room,
			},
			true

	case .ServerCreateRoom:
		payload: common.ServerRoomMutationPayload
		if cbor.unmarshal(innerPacket.payload, &payload) != nil {
			delete(payload.room.name)
			delete(payload.room.description)
			return ClientServerTransport_invalidPayloadEvent(
					transport,
					"invalid room create payload",
				),
				true
		}
		// The event owns the room's strings until State takes them.
		return ClientTransportRuntimeEvent {
				kind = .RoomCreated,
				serverID = transport.serverID,
				roomID = payload.room.id,
				room = payload.room,
			},
			true

	case .ServerDeleteRoom:
		payload: common.ServerRoomMutationPayload
		if cbor.unmarshal(innerPacket.payload, &payload) != nil {
			ClientServerTransport_runtimeProtocolError(transport, "invalid room delete payload")
			return ClientServerTransport_makeRuntimeEvent(
					transport,
					.ProtocolError,
					transport.lastError,
				),
				true
		}
		defer delete(payload.room.name)
		defer delete(payload.room.description)
		return ClientTransportRuntimeEvent {
				kind = .RoomDeleted,
				serverID = transport.serverID,
				roomID = payload.roomId,
			},
			true

	// A payload that fails to decode may still hold partial allocations, so each failure
	// path below frees what was decoded before reporting it.
	case .ServerDirectMessage:
		payload: common.ServerDirectMessagePayload
		if cbor.unmarshal(innerPacket.payload, &payload) != nil {
			delete(payload.senderNickname)
			delete(payload.recipientNickname)
			delete(payload.timestamp)
			delete(payload.content)
			return ClientServerTransport_invalidPayloadEvent(
					transport,
					"invalid direct message payload",
				),
				true
		}
		return ClientTransportRuntimeEvent {
				kind = .DirectMessageReceived,
				serverID = transport.serverID,
				directMessage = common.StoredDirectMessage {
					id = payload.id,
					senderId = payload.senderId,
					senderNickname = payload.senderNickname,
					recipientId = payload.recipientId,
					recipientNickname = payload.recipientNickname,
					timestamp = payload.timestamp,
					content = payload.content,
				},
			},
			true

	case .ServerDirectHistory:
		payload: common.ServerDirectHistoryPayload
		if cbor.unmarshal(innerPacket.payload, &payload) != nil {
			StoredDirectMessages_deinit(&payload.messages)
			return ClientServerTransport_invalidPayloadEvent(
					transport,
					"invalid direct history payload",
				),
				true
		}
		return ClientTransportRuntimeEvent {
				kind = .DirectHistoryReceived,
				serverID = transport.serverID,
				peerUserID = payload.peerUserId,
				directMessages = payload.messages,
				hasOlder = payload.hasOlder,
			},
			true

	case .ServerUserList:
		payload: common.ServerUserListPayload
		if cbor.unmarshal(innerPacket.payload, &payload) != nil {
			UserSummaries_deinit(&payload.users)
			return ClientServerTransport_invalidPayloadEvent(
					transport,
					"invalid user list payload",
				),
				true
		}
		return ClientTransportRuntimeEvent {
				kind = .UserListReceived,
				serverID = transport.serverID,
				users = payload.users,
			},
			true

	case .ServerDirectConversations:
		payload: common.ServerDirectConversationsPayload
		if cbor.unmarshal(innerPacket.payload, &payload) != nil {
			DirectConversationSummaries_deinit(&payload.conversations)
			return ClientServerTransport_invalidPayloadEvent(
					transport,
					"invalid direct conversation list payload",
				),
				true
		}
		return ClientTransportRuntimeEvent {
				kind = .DirectConversationsReceived,
				serverID = transport.serverID,
				conversations = payload.conversations,
			},
			true

	case .ServerUserPresence:
		payload: common.ServerUserPresencePayload
		if cbor.unmarshal(innerPacket.payload, &payload) != nil {
			delete(payload.nickname)
			return ClientServerTransport_invalidPayloadEvent(
					transport,
					"invalid user presence payload",
				),
				true
		}
		return ClientTransportRuntimeEvent {
				kind = .UserPresenceChanged,
				serverID = transport.serverID,
				user = common.UserSummary {
					id = payload.userId,
					nickname = payload.nickname,
					isOnline = payload.isOnline,
				},
			},
			true

	case .ServerProtocolError:
		protocolError: common.ProtocolErrorResponse
		if cbor.unmarshal(innerPacket.payload, &protocolError) == nil {
			defer delete(protocolError.message)
			ClientServerTransport_runtimeProtocolError(transport, protocolError.message)
		} else {
			ClientServerTransport_runtimeProtocolError(transport, "server protocol error")
		}
		return ClientServerTransport_makeRuntimeEvent(
				transport,
				.ProtocolError,
				transport.lastError,
			),
			true

	case:
		ClientServerTransport_runtimeProtocolError(
			transport,
			fmt.tprintf("unexpected runtime message type: %v", innerPacket.messageType),
		)
		return ClientServerTransport_makeRuntimeEvent(
				transport,
				.ProtocolError,
				transport.lastError,
			),
			true
	}
	return {}, false
}

ClientServerTransport_handleRuntimePacketBytes :: proc(
	transport: ^ClientServerTransport,
	packetBytes: []u8,
) -> (
	ClientTransportRuntimeEvent,
	bool,
) {
	outerPacket: common.Packet
	if cbor.unmarshal(packetBytes, &outerPacket) != nil {
		ClientServerTransport_fail(transport, "invalid outer packet")
		return ClientServerTransport_makeRuntimeEvent(
				transport,
				.ProtocolError,
				transport.lastError,
			),
			true
	}
	defer delete(outerPacket.payload)

	#partial switch outerPacket.messageType {
	case .EncryptedPacket:
		if !common.TransportState_canEncrypt(&transport.transport) {
			ClientServerTransport_fail(transport, "encrypted packet received before auth success")
			return ClientServerTransport_makeRuntimeEvent(
					transport,
					.ProtocolError,
					transport.lastError,
				),
				true
		}

		innerPacket, openOK := common.openPacketForSession(&transport.transport, outerPacket)
		if !openOK {
			ClientServerTransport_fail(transport, "failed to open encrypted packet")
			return ClientServerTransport_makeRuntimeEvent(
					transport,
					.ProtocolError,
					transport.lastError,
				),
				true
		}
		defer delete(innerPacket.payload)

		return ClientServerTransport_translateRuntimeOpenedPacket(transport, innerPacket)

	case .ServerProtocolError:
		protocolError: common.ProtocolErrorResponse
		if cbor.unmarshal(outerPacket.payload, &protocolError) == nil {
			defer delete(protocolError.message)
			ClientServerTransport_runtimeProtocolError(transport, protocolError.message)
		} else {
			ClientServerTransport_runtimeProtocolError(transport, "server protocol error")
		}
		return ClientServerTransport_makeRuntimeEvent(
				transport,
				.ProtocolError,
				transport.lastError,
			),
			true

	case:
		ClientServerTransport_fail(
			transport,
			fmt.tprintf("unexpected runtime outer message type: %v", outerPacket.messageType),
		)
		return ClientServerTransport_makeRuntimeEvent(
				transport,
				.ProtocolError,
				transport.lastError,
			),
			true
	}
	return {}, false
}

// Services the transport once without blocking: advances the connect state machine and, once
// established, returns at most one decoded runtime event. Called by the network worker.
ClientServerTransport_serviceRuntime :: proc(
	transport: ^ClientServerTransport,
) -> (
	ClientTransportRuntimeEvent,
	bool,
) {
	return ClientServerTransport_serviceConnection(transport, time.tick_now())
}

// Reads one ENet event from the established session and decodes it.
ClientServerTransport_serviceEstablishedSession :: proc(
	transport: ^ClientServerTransport,
	now: time.Tick,
) -> (
	ClientTransportRuntimeEvent,
	bool,
) {
	event: ENet.Event
	eventResult := ENet.host_service(transport.enetHost, &event, 0)
	if eventResult < 0 {
		return ClientServerTransport_lostConnection(transport, now, "network error")
	}
	if eventResult == 0 {
		return {}, false
	}

	switch event.type {
	case .RECEIVE:
		packetBytes := ClientServerTransport_copyENetPacket(event.packet)
		defer delete(packetBytes)
		return ClientServerTransport_handleRuntimePacketBytes(transport, packetBytes)

	case .DISCONNECT:
		return ClientServerTransport_lostConnection(
			transport,
			now,
			"the server closed the connection",
		)

	case .CONNECT, .NONE:
		return {}, false
	}
	return {}, false
}

// Copies an ENet packet's bytes and destroys the packet.
ClientServerTransport_copyENetPacket :: proc(packet: ^ENet.Packet) -> []u8 {
	packetBytes := make([]u8, packet.dataLength)
	copy(packetBytes, packet.data[:packet.dataLength])
	ENet.packet_destroy(packet)
	return packetBytes
}
