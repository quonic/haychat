package client

import "../common"
import "core:crypto/ecdh"
import "core:encoding/cbor"
import "core:fmt"
import "core:strings"
import "vendor:ENet"

STARTUP_AUTH_CHANNEL_CHAT :: u8(1)
STARTUP_AUTH_CHANNEL_COUNT :: uint(5)
STARTUP_AUTH_CONNECT_TIMEOUT_MS :: u32(1000)
STARTUP_AUTH_EVENT_TIMEOUT_MS :: u32(1000)
STARTUP_AUTH_MAX_EVENTS :: 8

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
	Disconnected,
}

ClientTransportRuntimeEvent :: struct {
	kind:     ClientTransportRuntimeEventKind,
	serverID: int,
	senderID: int,
	roomID:   int,
	messageID: int,
	timestamp: string,
	message:  string,
	rooms:    [dynamic]common.RoomSummary,
	messages: [dynamic]common.StoredChatMessage,
	hasOlder: bool,
	joined:   bool,
	room:     common.RoomSummary,
}

ClientStartupAuthSession :: struct {
	enetHost:        ^ENet.Host,
	enetPeer:        ^ENet.Peer,
	enetInitialized: bool,
}

ClientServerTransport :: struct {
	serverID:                  int,
	serverName:                string,
	serverHost:                string,
	serverPort:                i32,
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
	lastError:                 string,
	enetHost:                  ^ENet.Host,
	enetPeer:                  ^ENet.Peer,
	enetInitialized:           bool,
}

ClientServerTransport_setLastError :: proc(transport: ^ClientServerTransport, message: string) {
	if len(transport.lastError) > 0 {
		delete(transport.lastError)
	}
	transport.lastError = strings.clone(message)
}

ClientServerTransport_hasLiveENetSession :: proc(transport: ^ClientServerTransport) -> bool {
	return transport.enetInitialized && transport.enetHost != nil && transport.enetPeer != nil
}

ClientServerTransport_releaseENetSession :: proc(transport: ^ClientServerTransport) {
	if transport.enetPeer != nil {
		ENet.peer_reset(transport.enetPeer)
		transport.enetPeer = nil
	}
	if transport.enetHost != nil {
		ENet.host_destroy(transport.enetHost)
		transport.enetHost = nil
	}
	if transport.enetInitialized {
		ENet.deinitialize()
		transport.enetInitialized = false
	}
}

ClientServerTransport_adoptStartupAuthSession :: proc(
	transport: ^ClientServerTransport,
	session: ClientStartupAuthSession,
) {
	ClientServerTransport_releaseENetSession(transport)
	transport.enetHost = session.enetHost
	transport.enetPeer = session.enetPeer
	transport.enetInitialized = session.enetInitialized
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
	delete(event.timestamp)
	delete(event.message)
	for room in event.rooms {
		delete(room.name)
		delete(room.description)
	}
	delete(event.rooms)
	for message in event.messages {
		delete(message.timestamp)
		delete(message.content)
	}
	delete(event.messages)
	delete(event.room.name)
	delete(event.room.description)
	event^ = {}
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
		serverID   = server.id,
		serverName = strings.clone(server.name),
		serverHost = strings.clone(server.host),
		serverPort = server.port,
		transport  = common.TransportState_init(.Client),
	}
	ClientServerTransport_fail(&transport, message)
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
	clientPrivateKey, privateKeyOK := common.identityPrivateKeyFromHex(config.private_key)
	clientPublicKey, publicKeyOK := common.identityPublicKeyFromHex(config.public_key)
	if !privateKeyOK || !publicKeyOK {
		return {}, "client identity keys are missing or invalid", false
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
			clientIdentityPrivateKey  = clientPrivateKey,
			clientIdentityPublicKey   = clientPublicKey,
			clientEphemeralPrivateKey = clientEphemeralPrivateKey,
			clientEphemeralPublicKey  = clientEphemeralPublicKey,
			transport                 = common.TransportState_init(.Client),
		}
	return transport, "", true
}

ClientTransportCatalog_init :: proc(config: ^Config) -> [dynamic]ClientServerTransport {
	catalog := make([dynamic]ClientServerTransport, 0, len(config.servers))
	for server in config.servers {
		transport, message, ok := ClientServerTransport_init(server, config^)
		if ok {
			append(&catalog, transport)
		} else {
			append(&catalog, ClientServerTransport_initFailed(server, message))
		}
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

ClientServerTransport_completeStartupAuthOverENet :: proc(
	transport: ^ClientServerTransport,
	server: ^Server,
	config: ^Config,
	clientHelloPacketBytes: []u8,
) -> ClientStartupAuthSession {
	session: ClientStartupAuthSession
	shouldReleaseSession := true
	defer if shouldReleaseSession {
		if session.enetPeer != nil {
			ENet.peer_reset(session.enetPeer)
			session.enetPeer = nil
		}
		if session.enetHost != nil {
			ENet.host_destroy(session.enetHost)
			session.enetHost = nil
		}
		if session.enetInitialized {
			ENet.deinitialize()
			session.enetInitialized = false
		}
	}

	if ENet.initialize() != 0 {
		ClientServerTransport_fail(transport, "failed to initialize ENet")
		return session
	}
	session.enetInitialized = true

	session.enetHost = ENet.host_create(nil, 1, STARTUP_AUTH_CHANNEL_COUNT, 0, 0)
	if session.enetHost == nil {
		ClientServerTransport_fail(transport, "failed to create ENet client host")
		return session
	}

	serverHostCString, serverHostCStringErr := strings.clone_to_cstring(server.host)
	if serverHostCStringErr != nil {
		ClientServerTransport_fail(transport, "failed to prepare server host")
		return session
	}
	defer delete(serverHostCString)

	address := ENet.Address {
			port = u16(server.port),
		}
	if ENet.address_set_host(&address, serverHostCString) != 0 {
		ClientServerTransport_fail(
			transport,
			fmt.aprintf("failed to resolve server host: %s", server.host),
		)
		return session
	}

	session.enetPeer = ENet.host_connect(session.enetHost, &address, STARTUP_AUTH_CHANNEL_COUNT, 0)
	if session.enetPeer == nil {
		ClientServerTransport_fail(transport, "failed to start ENet connection")
		return session
	}

	connectEvent: ENet.Event
	connectResult := ENet.host_service(
		session.enetHost,
		&connectEvent,
		STARTUP_AUTH_CONNECT_TIMEOUT_MS,
	)
	if connectResult <= 0 || connectEvent.type != .CONNECT {
		ClientServerTransport_fail(transport, "timed out connecting to server")
		return session
	}

	if !ClientServerTransport_sendENetPacket(
		session.enetHost,
		session.enetPeer,
		STARTUP_AUTH_CHANNEL_CHAT,
		clientHelloPacketBytes,
	) {
		ClientServerTransport_fail(transport, "failed to send client hello packet")
		return session
	}

	for _ in 0 ..< STARTUP_AUTH_MAX_EVENTS {
		event: ENet.Event
		eventResult := ENet.host_service(session.enetHost, &event, STARTUP_AUTH_EVENT_TIMEOUT_MS)
		if eventResult <= 0 {
			if transport.transport.phase == .Failed {
				return session
			}
			ClientServerTransport_fail(transport, "timed out waiting for auth response")
			return session
		}

		switch event.type {
		case .RECEIVE:
			packetData := event.packet.data[:event.packet.dataLength]
			packetCopy := make([dynamic]u8, 0, len(packetData))
			for b in packetData {
				append(&packetCopy, b)
			}
			ENet.packet_destroy(event.packet)

			result, ok := ClientServerTransport_handleIncomingPacket(
				transport,
				server,
				config,
				packetCopy[:],
			)
			delete(packetCopy)
			defer if result.hasOpenedPacket do delete(result.openedPacket.payload)

			if result.hasResponse {
				responseSent := ClientServerTransport_sendENetPacket(
					session.enetHost,
					session.enetPeer,
					STARTUP_AUTH_CHANNEL_CHAT,
					result.responsePacketBytes,
				)
				delete(result.responsePacketBytes)
				if !responseSent {
					ClientServerTransport_fail(transport, "failed to send auth response packet")
					return session
				}
			}

			if transport.transport.phase == .Established {
				shouldReleaseSession = false
				return session
			}

			if !ok && transport.transport.phase == .Failed {
				continue
			}

		case .DISCONNECT:
			ClientServerTransport_handleDisconnect(transport)
			return session

		case .CONNECT, .NONE:
		}
	}

	if transport.transport.phase != .Established && transport.transport.phase != .Failed {
		ClientServerTransport_fail(transport, "startup auth did not complete")
	}

	return session
}

ClientServerTransport_beginHandshake :: proc(transport: ^ClientServerTransport) -> ([]u8, bool) {
	transport.pendingKeysReady = false
	transport.transport.phase = .ClientHelloSent

	clientHello := common.ClientHello {
		version                  = common.protocolVersion,
		clientIdentityPublicKey  = transport.clientIdentityPublicKey,
		clientEphemeralPublicKey = transport.clientEphemeralPublicKey,
	}
	return common.buildPacketBytes(.ClientHello, clientHello)
}

ClientServerTransport_handleIncomingPacket :: proc(
	transport: ^ClientServerTransport,
	server: ^Server,
	config: ^Config,
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
			clientIdentityPublicKey  = transport.clientIdentityPublicKey,
			clientEphemeralPublicKey = transport.clientEphemeralPublicKey,
		}
		if !common.verifyServerHello(serverHello, clientHello) {
			ClientServerTransport_fail(transport, "server hello signature verification failed")
			return result, false
		}

		trustState, configChanged := pinServerIdentity(server, serverHello.serverIdentityPublicKey)
		transport.transport.peerTrustState = trustState
		if configChanged {
			saveConfig(config^)
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
			fmt.aprintf("unexpected server message type: %v", outerPacket.messageType),
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
	if !ClientServerTransport_hasLiveENetSession(transport) {
		ClientServerTransport_fail(transport, "live ENet session is unavailable")
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
	if !ClientServerTransport_hasLiveENetSession(transport) {
		ClientServerTransport_fail(transport, "live ENet session is unavailable")
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
			roomID = chatPayload.roomId,
			messageID = chatPayload.id,
			timestamp = chatPayload.timestamp,
			message = chatPayload.content,
		}, true

	case .ServerListRooms:
		payload: common.ServerListRoomsPayload
		if cbor.unmarshal(innerPacket.payload, &payload) != nil {
			ClientServerTransport_runtimeProtocolError(transport, "invalid room list payload")
			return ClientServerTransport_makeRuntimeEvent(transport, .ProtocolError, transport.lastError), true
		}
		return ClientTransportRuntimeEvent {
			kind = .RoomListReceived,
			serverID = transport.serverID,
			rooms = payload.rooms,
		}, true

	case .ServerRoomHistory:
		payload: common.ServerRoomHistoryPayload
		if cbor.unmarshal(innerPacket.payload, &payload) != nil {
			ClientServerTransport_runtimeProtocolError(transport, "invalid room history payload")
			return ClientServerTransport_makeRuntimeEvent(transport, .ProtocolError, transport.lastError), true
		}
		return ClientTransportRuntimeEvent {
			kind = .RoomHistoryReceived,
			serverID = transport.serverID,
			roomID = payload.roomId,
			messages = payload.messages,
			hasOlder = payload.hasOlder,
		}, true

	case .ServerRoomMembershipChanged:
		payload: common.ServerRoomMembershipChangedPayload
		if cbor.unmarshal(innerPacket.payload, &payload) != nil {
			ClientServerTransport_runtimeProtocolError(transport, "invalid room membership payload")
			return ClientServerTransport_makeRuntimeEvent(transport, .ProtocolError, transport.lastError), true
		}
		return ClientTransportRuntimeEvent {
			kind = .RoomMembershipChanged,
			serverID = transport.serverID,
			roomID = payload.roomId,
			joined = payload.joined,
		}, true

	case .ServerEditRoom:
		payload: common.ServerRoomMutationPayload
		if cbor.unmarshal(innerPacket.payload, &payload) != nil {
			ClientServerTransport_runtimeProtocolError(transport, "invalid room edit payload")
			return ClientServerTransport_makeRuntimeEvent(transport, .ProtocolError, transport.lastError), true
		}
		return ClientTransportRuntimeEvent {
			kind = .RoomEdited,
			serverID = transport.serverID,
			roomID = payload.roomId,
			room = payload.room,
		}, true

	case .ServerDeleteRoom:
		payload: common.ServerRoomMutationPayload
		if cbor.unmarshal(innerPacket.payload, &payload) != nil {
			ClientServerTransport_runtimeProtocolError(transport, "invalid room delete payload")
			return ClientServerTransport_makeRuntimeEvent(transport, .ProtocolError, transport.lastError), true
		}
		defer delete(payload.room.name)
		defer delete(payload.room.description)
		return ClientTransportRuntimeEvent {
			kind = .RoomDeleted,
			serverID = transport.serverID,
			roomID = payload.roomId,
		}, true

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
			fmt.aprintf("unexpected runtime message type: %v", innerPacket.messageType),
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
			fmt.aprintf("unexpected runtime outer message type: %v", outerPacket.messageType),
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

ClientServerTransport_serviceRuntime :: proc(
	transport: ^ClientServerTransport,
) -> (
	ClientTransportRuntimeEvent,
	bool,
) {
	if transport.transport.phase != .Established ||
	   !ClientServerTransport_hasLiveENetSession(transport) {
		return {}, false
	}

	event: ENet.Event
	eventResult := ENet.host_service(transport.enetHost, &event, 0)
	if eventResult <= 0 {
		return {}, false
	}

	switch event.type {
	case .RECEIVE:
		packetData := event.packet.data[:event.packet.dataLength]
		packetCopy := make([dynamic]u8, 0, len(packetData))
		for b in packetData {
			append(&packetCopy, b)
		}
		ENet.packet_destroy(event.packet)
		defer delete(packetCopy)

		return ClientServerTransport_handleRuntimePacketBytes(transport, packetCopy[:])

	case .DISCONNECT:
		ClientServerTransport_handleDisconnect(transport)
		return ClientServerTransport_makeRuntimeEvent(transport, .Disconnected, ""), true

	case .CONNECT, .NONE:
		return {}, false
	}
	return {}, false
}
