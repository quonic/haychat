package client

import "../common"
import "core:crypto/ecdh"
import "core:encoding/cbor"
import "core:fmt"
import "core:strings"
import "core:time"
import "vendor:ENet"

// ENet channel 1 carries every control packet (the handshake and all CBOR traffic); channel
// 2 is reserved for voice datagrams. The host allocates channels 0..4, matching the server.
STARTUP_AUTH_CHANNEL_CHAT :: u8(1)
STARTUP_AUTH_CHANNEL_VOICE :: u8(2)
STARTUP_AUTH_CHANNEL_COUNT :: uint(5)

#assert(STARTUP_AUTH_CHANNEL_CHAT == u8(common.TransportChannel.Control))
#assert(STARTUP_AUTH_CHANNEL_VOICE == u8(common.TransportChannel.Voice))
#assert(uint(STARTUP_AUTH_CHANNEL_VOICE) < STARTUP_AUTH_CHANNEL_COUNT)

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
	// ServerReadMarker (protocol 11): readMarker holds the moved marker. Nothing to free.
	ReadMarkerReceived,
	// Voice control (protocol 10, voice_state.odin). VoiceParticipants carries roomID and the
	// room's full participant set in voiceParticipants; VoiceJoinRejected and VoiceLeft carry
	// roomID and the server's reason in message. Voice frames are never runtime events.
	VoiceParticipants,
	VoiceJoinRejected,
	VoiceLeft,
	// Admin actions (protocol 14). UserUpdated carries an account's full directory entry in
	// user (ServerUserUpdated). AccountUpdated carries this account's isAdmin, nickname and
	// nicknameLocked (ServerAccountUpdated, #41). AdminActionResult answers this session's admin
	// request: adminAction, peerUserID (the target) and the server's sentence in message.
	// SessionEnded is ServerSessionEnded: the transport has already ended the session as a
	// failure that is not retried (failureKind Kicked or Banned, message for people, detail the
	// admin's reason), and State handles it exactly like ConnectFailed.
	UserUpdated,
	AccountUpdated,
	AdminActionResult,
	SessionEnded,
	// Room access modes (protocol 15). RoomMembersReceived carries roomID and the members in
	// userIDs (ServerRoomMembers). AdminRoomsReceived carries every room in adminRooms
	// (ServerAdminRooms). RoomMemberResult answers this session's add (joined true) or removal
	// (joined false) of peerUserID in roomID, changed false when nothing moved.
	RoomMembersReceived,
	AdminRoomsReceived,
	RoomMemberResult,
	// Account encryption keys (protocol 16, e2ee_state.odin). UserKeysReceived carries
	// ServerUserKeys in userKeys and missingUserIDs (both owned); UserKeyChanged carries
	// ServerUserKeyChanged's bundle in userKey (nothing owned).
	UserKeysReceived,
	UserKeyChanged,
	// Encrypted rooms (protocol 18, room_log.odin). RoomLogReceived is ServerRoomLog: roomID,
	// the entries after logAfterVersion in logEntries (owned), the server's head version in
	// logHeadVersion, and hasOlder set when the server has more entries after these.
	RoomLogReceived,
	// Sender chains (protocol 19, room_chains.odin). RoomKeyEnvelopeReceived is a live
	// ServerRoomKeyEnvelope and RoomKeysReceived one page of ServerRoomKeys (roomID, hasOlder
	// when more follow); both carry the envelopes in roomKeyEnvelopes (owned). RoomKeyRequested
	// is ServerRoomKeyRequest: roomID, roomKeyEpoch, roomKeyChainID, the requester in
	// peerUserID and the chain's sender in senderID (protocol 20). RoomChatReceived carries a
	// sealed message's clientMessageID and sealed (owned).
	RoomKeyEnvelopeReceived,
	RoomKeysReceived,
	RoomKeyRequested,
	// Encrypted voice (protocol 21, voice_e2ee.odin). VoiceKeyReceived carries ServerVoiceKey in
	// voiceKey (its envelope owned); VoiceKeyRequested is ServerVoiceKeyRequest: roomID and the
	// requester in peerUserID.
	VoiceKeyReceived,
	VoiceKeyRequested,
	// Roles (protocol 23, roles.odin). RoleListReceived is ServerRoleList: every role in roles
	// (owned). RoleUpdated is ServerRoleUpdated: the role in role (name owned). RoleDeleted is
	// ServerRoleDeleted: the role's ID in roleID. Connected and AccountUpdated carry the
	// account's effective permissions; AdminActionResult carries roleID for a role action.
	RoleListReceived,
	RoleUpdated,
	RoleDeleted,
	// Room permissions (protocol 24, room_permissions.odin). RoomPermissionsReceived is
	// ServerAdminRoomPermissions: roomID and the payload in roomPermissions (arrays owned).
	RoomPermissionsReceived,
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
	// Connection lifecycle fields. userID, nickname, isAdmin and nicknameLocked are set on
	// Connected (nickname is the account's name from ServerAuthSuccess, which an admin may have
	// locked); AccountUpdated uses isAdmin, nickname and nicknameLocked too. retryAt is when the
	// worker tries again after Disconnected or a retryable ConnectFailed.
	userID:            int,
	nickname:          string,
	isAdmin:           bool,
	nicknameLocked:    bool,
	permissions:       common.ServerPermissions,
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
	readMarker:        common.ServerReadMarkerPayload,
	// Owned participant entries (nicknames included) on VoiceParticipants.
	voiceParticipants: [dynamic]common.VoiceParticipant,
	// VoiceParticipants: whether this session is itself in the room's voice (the server's
	// per-recipient ServerVoiceParticipants.recipientJoined).
	voiceRecipientJoined: bool,
	// On Connected: the transport's session counter, which voice bindings are checked against
	// (see ClientTransportVoiceBinding).
	sessionGeneration: u64,
	// AdminActionResult: which action the server answered.
	adminAction:       common.AdminAction,
	// SessionEnded: the admin's reason, owned (may be empty).
	detail:            string,
	// RoomMembersReceived: the room's members (owned). AdminRoomsReceived: every room (owned).
	userIDs:           [dynamic]int,
	adminRooms:        [dynamic]common.AdminRoomSummary,
	// RoomMemberResult: whether a membership row moved. RoomCreated: isMember says whether the
	// creator is a member of the new room (protocol 15).
	changed:           bool,
	isMember:          bool,
	// UserKeysReceived and UserKeyChanged (protocol 16).
	userKeys:          [dynamic]common.UserKeyBundle,
	missingUserIDs:    [dynamic]int,
	userKey:           common.UserKeyBundle,
	// RoomLogReceived (protocol 18).
	logEntries:        [dynamic][]u8,
	logAfterVersion:   int,
	logHeadVersion:    int,
	// Protocol 19.
	clientMessageID:   common.ClientMessageID,
	sealed:            []u8,
	// Protocol 22: RoomChatReceived's plaintext message signature.
	signature:         common.SignatureBytes,
	roomKeyEnvelopes:  [dynamic]common.RoomKeyEnvelope,
	roomKeyEpoch:      int,
	roomKeyChainID:    common.ChainID,
	// Protocol 21.
	voiceKey:          common.ServerVoiceKeyPayload,
	// Protocol 23.
	roles:             [dynamic]common.RoleSummary,
	role:              common.RoleSummary,
	roleID:            int,
	// Protocol 24.
	roomPermissions:   common.ServerAdminRoomPermissionsPayload,
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
	// Whether ServerAuthSuccess said the account is an admin; ServerAccountUpdated changes the
	// copy in State, not this one.
	authenticatedIsAdmin:      bool,
	// The account's name and lock from ServerAuthSuccess (protocol 14); owned, empty when the
	// server sent none.
	authenticatedNickname:     string,
	authenticatedNicknameLocked: bool,
	// The account's effective server permissions from ServerAuthSuccess (protocol 23).
	authenticatedPermissions:  common.ServerPermissions,
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
	// Counts established sessions; ClientServerTransport_connected bumps it. A voice binding
	// made for one session is dead in every later one (voice_network.odin).
	sessionGeneration:         u64,
	// The running voice engine for this server, set and cleared by the UI thread under the
	// worker lock (voice_network.odin). The network worker pushes received frames into it and
	// the voice thread checks it before every send.
	voice:                     ClientTransportVoiceBinding,
	// Voice datagrams in and out, and why any were dropped. Under the worker lock; never reset,
	// so it covers every session of this transport.
	voiceStats:                ClientVoiceNetworkStats,
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
	common.DirectionalTransportKeys_wipe(&transport.pendingKeys)
	transport.pendingKeysReady = false
	transport.authenticatedUserID = 0
	transport.authenticatedIsAdmin = false
	delete(transport.authenticatedNickname)
	transport.authenticatedNickname = ""
	transport.authenticatedNicknameLocked = false
	transport.authenticatedPermissions = {}
}

// Releases the ENet session and every string the transport owns.
ClientServerTransport_deinit :: proc(transport: ^ClientServerTransport) {
	ClientServerTransport_releaseENetSession(transport)
	delete(transport.serverName)
	delete(transport.serverHost)
	delete(transport.nickname)
	delete(transport.authenticatedNickname)
	delete(transport.lastError)
	delete(transport.pinnedServerPublicKey)
	delete(transport.pinnedServerFingerprint)
	common.TransportState_deinit(&transport.transport)
	common.DirectionalTransportKeys_wipe(&transport.pendingKeys)
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
	for &message in event.messages {
		common.StoredChatMessage_deinit(&message)
	}
	delete(event.messages)
	delete(event.sealed)
	for &envelope in event.roomKeyEnvelopes {
		common.RoomKeyEnvelope_deinit(&envelope)
	}
	delete(event.roomKeyEnvelopes)
	common.ServerVoiceKeyPayload_deinit(&event.voiceKey)
	delete(event.room.name)
	delete(event.room.description)
	delete(event.nickname)
	delete(event.serverPublicKey)
	delete(event.serverFingerprint)
	StoredDirectMessage_deinit(&event.directMessage)
	StoredDirectMessages_deinit(&event.directMessages)
	UserSummaries_deinit(&event.users)
	DirectConversationSummaries_deinit(&event.conversations)
	common.UserSummary_deinit(&event.user)
	for &role in event.roles {
		common.RoleSummary_deinit(&role)
	}
	delete(event.roles)
	common.RoleSummary_deinit(&event.role)
	common.ServerAdminRoomPermissionsPayload_deinit(&event.roomPermissions)
	for &participant in event.voiceParticipants {
		common.VoiceParticipant_deinit(&participant)
	}
	delete(event.voiceParticipants)
	delete(event.detail)
	delete(event.userIDs)
	AdminRoomSummaries_deinit(&event.adminRooms)
	delete(event.userKeys)
	delete(event.missingUserIDs)
	for entry in event.logEntries {
		delete(entry)
	}
	delete(event.logEntries)
	event^ = {}
}

StoredDirectMessage_deinit :: proc(message: ^common.StoredDirectMessage) {
	delete(message.senderNickname)
	delete(message.recipientNickname)
	delete(message.timestamp)
	delete(message.content)
	delete(message.envelope)
	message^ = {}
}

StoredDirectMessages_deinit :: proc(messages: ^[dynamic]common.StoredDirectMessage) {
	for index in 0 ..< len(messages) {
		StoredDirectMessage_deinit(&messages[index])
	}
	delete(messages^)
	messages^ = nil
}

AdminRoomSummaries_deinit :: proc(rooms: ^[dynamic]common.AdminRoomSummary) {
	for entry in rooms {
		delete(entry.room.name)
		delete(entry.room.description)
	}
	delete(rooms^)
	rooms^ = nil
}

UserSummaries_deinit :: proc(users: ^[dynamic]common.UserSummary) {
	for &user in users {
		common.UserSummary_deinit(&user)
	}
	delete(users^)
	users^ = nil
}

DirectConversationSummary_deinit :: proc(conversation: ^common.DirectConversationSummary) {
	delete(conversation.peerNickname)
	delete(conversation.lastTimestamp)
	delete(conversation.lastContent)
	delete(conversation.lastEnvelope)
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
	// A per-server display name replaces the global one on that server only.
	nickname := Server_displayName(server, config)
	if len(nickname) < DISPLAY_NAME_MIN_BYTES || len(nickname) > DISPLAY_NAME_MAX_BYTES {
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
			nickname                  = strings.clone(nickname),
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
			common.ServerAuthSuccessPayload_deinit(&authSuccess)
			ClientServerTransport_fail(transport, "invalid auth success payload")
			return result, false
		}
		defer common.ServerAuthSuccessPayload_deinit(&authSuccess)

		common.TransportState_activate(
			&transport.transport,
			transport.sessionID,
			transport.pendingKeys,
			transport.transport.peerTrustState,
		)
		common.DirectionalTransportKeys_wipe(&transport.pendingKeys)
		transport.pendingKeysReady = false
		transport.authenticatedUserID = authSuccess.userId
		transport.authenticatedIsAdmin = authSuccess.isAdmin
		delete(transport.authenticatedNickname)
		transport.authenticatedNickname = authSuccess.nickname
		authSuccess.nickname = ""
		transport.authenticatedNicknameLocked = authSuccess.nicknameLocked
		transport.authenticatedPermissions = authSuccess.permissions & common.SERVER_PERMISSIONS_ALL
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

// A plaintext room message to send (protocol 22): every one carries a fresh client message ID
// and this profile's signature over the server's identity key, the room, its account and the
// content (State_signRoomChat). Borrowed for the send.
RoomChatSend :: struct {
	roomID:          int,
	content:         string,
	clientMessageID: common.ClientMessageID,
	signature:       common.SignatureBytes,
}

ClientServerTransport_buildRoomChatPacketBytes :: proc(
	transport: ^ClientServerTransport,
	send: RoomChatSend,
) -> (
	[]u8,
	bool,
) {
	return ClientServerTransport_buildEncryptedPacketBytes(
		transport,
		.ClientChatMessage,
		common.ClientChatMessagePayload {
			roomId = ClientServerTransport_runtimeRoomID(send.roomID),
			content = send.content,
			clientMessageId = send.clientMessageID,
			signature = send.signature,
		},
	)
}

ClientServerTransport_sendRoomChatMessage :: proc(
	transport: ^ClientServerTransport,
	send: RoomChatSend,
) -> bool {
	// Not being connected yet is normal while the worker connects or reconnects, so it only
	// reports an error instead of failing (and tearing down) the session.
	if !ClientServerTransport_isConnected(transport) {
		ClientServerTransport_setLastError(transport, NOT_CONNECTED_MESSAGE)
		return false
	}

	packetBytes, ok := ClientServerTransport_buildRoomChatPacketBytes(transport, send)
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

// One direct message ready to go out (direct_messages_e2ee.odin builds it): an encrypted one
// carries its envelope, a plaintext fallback its content and signature. Borrowed for the send.
DirectMessageSend :: struct {
	recipientUserID: int,
	clientMessageID: common.ClientMessageID,
	envelope:        []u8,
	content:         string,
	signature:       common.SignatureBytes,
}

// Direct messages share the room chat channel and the not-connected handling of every other
// runtime request. An envelope goes out as ClientSealedDirectMessage, anything else as the
// signed ClientDirectMessage (protocol 17).
ClientServerTransport_sendDirectMessage :: proc(
	transport: ^ClientServerTransport,
	send: DirectMessageSend,
) -> bool {
	if len(send.envelope) > 0 {
		return ClientServerTransport_sendEncryptedRuntimeMessage(
			transport,
			.ClientSealedDirectMessage,
			common.ClientSealedDirectMessagePayload {
				recipientUserId = send.recipientUserID,
				clientMessageId = send.clientMessageID,
				envelope = send.envelope,
			},
		)
	}
	return ClientServerTransport_sendEncryptedRuntimeMessage(
		transport,
		.ClientDirectMessage,
		common.ClientDirectMessagePayload {
			recipientUserId = send.recipientUserID,
			content = send.content,
			clientMessageId = send.clientMessageID,
			signature = send.signature,
		},
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

// Account encryption keys (protocol 16): this profile's bundle, once per session.
ClientServerTransport_publishEncryptionKey :: proc(
	transport: ^ClientServerTransport,
	bundle: common.EncryptionKeyBundle,
) -> bool {
	return ClientServerTransport_sendEncryptedRuntimeMessage(
		transport,
		.ClientPublishEncryptionKey,
		common.ClientPublishEncryptionKeyPayload {
			encryptionPublicKey = bundle.encryptionPublicKey,
			createdAt = bundle.createdAt,
			signature = bundle.signature,
		},
	)
}

// Requests the bundles of userIDs: 1..USER_KEYS_FETCH_MAX distinct positive IDs. The server
// answers with ServerUserKeys.
ClientServerTransport_fetchUserKeys :: proc(
	transport: ^ClientServerTransport,
	userIDs: []int,
) -> bool {
	if !common.userKeysFetchIsValid(userIDs) {
		return false
	}
	ids := make([dynamic]int, 0, len(userIDs))
	defer delete(ids)
	append(&ids, ..userIDs)
	return ClientServerTransport_sendEncryptedRuntimeMessage(
		transport,
		.ClientFetchUserKeys,
		common.ClientFetchUserKeysPayload{userIds = ids},
	)
}

// Read state (protocol 11): the server answers with ServerReadMarker on every session of the
// account when the marker moved, and with nothing when it did not.
ClientServerTransport_markRead :: proc(
	transport: ^ClientServerTransport,
	kind: common.ReadMarkerKind,
	conversationID: int,
	messageID: int,
) -> bool {
	return ClientServerTransport_sendEncryptedRuntimeMessage(
		transport,
		.ClientMarkRead,
		common.ClientMarkReadPayload {
			kind = kind,
			conversationId = conversationID,
			messageId = messageID,
		},
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
	roomType: common.RoomType,
	access: common.RoomAccess,
	historyVisibility: common.RoomHistoryVisibility,
	creatorJoins: bool,
	encrypted := false,
	accessRoleIDs: []int = nil,
) -> bool {
	accessRoles := make([dynamic]int, 0, len(accessRoleIDs))
	defer delete(accessRoles)
	append(&accessRoles, ..accessRoleIDs)
	return ClientServerTransport_sendEncryptedRuntimeMessage(
		transport,
		.ClientCreateRoom,
		common.ClientCreateRoomPayload {
			name = name,
			description = description,
			roomType = roomType,
			access = access,
			historyVisibility = historyVisibility,
			creatorJoins = creatorJoins,
			encrypted = encrypted,
			accessRoleIds = accessRoles,
		},
	)
}

// Room permissions (protocol 24): a room's grants, answered by ServerAdminRoomPermissions.
ClientServerTransport_fetchRoomPermissions :: proc(
	transport: ^ClientServerTransport,
	roomID: int,
) -> bool {
	return ClientServerTransport_sendEncryptedRuntimeMessage(
		transport,
		.ClientAdminFetchRoomPermissions,
		common.ClientAdminFetchRoomPermissionsPayload{roomId = roomID},
	)
}

// Replaces a room's grants; roles is borrowed.
ClientServerTransport_setRoomPermissions :: proc(
	transport: ^ClientServerTransport,
	roomID: int,
	everyone: common.RoomPermissions,
	roles: []common.RoomRoleGrant,
) -> bool {
	grants := make([dynamic]common.RoomRoleGrant, 0, len(roles))
	defer delete(grants)
	append(&grants, ..roles)
	return ClientServerTransport_sendEncryptedRuntimeMessage(
		transport,
		.ClientAdminSetRoomPermissions,
		common.ClientAdminSetRoomPermissionsPayload {
			roomId = roomID,
			everyone = everyone,
			roles = grants,
		},
	)
}

ClientServerTransport_editRoom :: proc(
	transport: ^ClientServerTransport,
	roomID: int,
	name: string,
	description: string,
	roomType: common.RoomType,
	access: common.RoomAccess,
	encrypted := false,
	accessRoleIDs: []int = nil,
) -> bool {
	accessRoles := make([dynamic]int, 0, len(accessRoleIDs))
	defer delete(accessRoles)
	append(&accessRoles, ..accessRoleIDs)
	return ClientServerTransport_sendEncryptedRuntimeMessage(
		transport,
		.ClientEditRoom,
		common.ClientEditRoomPayload {
			roomId = roomID,
			name = name,
			description = description,
			roomType = roomType,
			access = access,
			encrypted = encrypted,
			accessRoleIds = accessRoles,
		},
	)
}

// Encrypted rooms (protocol 18): one signed member log entry, and a fetch of the log after a
// version. The answers, and the fan-out of every stored entry, are ServerRoomLog.
ClientServerTransport_appendRoomLog :: proc(
	transport: ^ClientServerTransport,
	roomID: int,
	entry: []u8,
) -> bool {
	return ClientServerTransport_sendEncryptedRuntimeMessage(
		transport,
		.ClientAppendRoomLog,
		common.ClientAppendRoomLogPayload{roomId = roomID, entry = entry},
	)
}

ClientServerTransport_fetchRoomLog :: proc(
	transport: ^ClientServerTransport,
	roomID, afterVersion: int,
) -> bool {
	return ClientServerTransport_sendEncryptedRuntimeMessage(
		transport,
		.ClientFetchRoomLog,
		common.ClientFetchRoomLogPayload{roomId = roomID, afterVersion = afterVersion},
	)
}

// Room members (protocol 15). The server checks who may add, remove, leave and list against
// the room's access mode and answers a refusal with ServerProtocolError.
ClientServerTransport_addRoomMember :: proc(
	transport: ^ClientServerTransport,
	roomID, userID: int,
) -> bool {
	return ClientServerTransport_sendEncryptedRuntimeMessage(
		transport,
		.ClientAddRoomMember,
		common.ClientRoomMembershipPayload{roomId = roomID, userId = userID},
	)
}

ClientServerTransport_removeRoomMember :: proc(
	transport: ^ClientServerTransport,
	roomID, userID: int,
) -> bool {
	return ClientServerTransport_sendEncryptedRuntimeMessage(
		transport,
		.ClientRemoveRoomMember,
		common.ClientRoomMembershipPayload{roomId = roomID, userId = userID},
	)
}

ClientServerTransport_leaveRoom :: proc(transport: ^ClientServerTransport, roomID: int) -> bool {
	return ClientServerTransport_sendEncryptedRuntimeMessage(
		transport,
		.ClientLeaveRoom,
		common.ClientLeaveRoomPayload{roomId = roomID},
	)
}

ClientServerTransport_fetchRoomMembers :: proc(
	transport: ^ClientServerTransport,
	roomID: int,
) -> bool {
	return ClientServerTransport_sendEncryptedRuntimeMessage(
		transport,
		.ClientFetchRoomMembers,
		common.ClientFetchRoomMembersPayload{roomId = roomID},
	)
}

ClientServerTransport_adminListRooms :: proc(transport: ^ClientServerTransport) -> bool {
	return ClientServerTransport_sendEncryptedRuntimeMessage(
		transport,
		.ClientAdminListRooms,
		common.ClientAdminListRoomsPayload{},
	)
}

// Admin actions on accounts (protocol 14). The server checks the admin role and the guards in
// the database and answers with ServerAdminActionResult or a ServerProtocolError.
ClientServerTransport_adminSetRole :: proc(
	transport: ^ClientServerTransport,
	userID: int,
	isAdmin: bool,
) -> bool {
	return ClientServerTransport_sendEncryptedRuntimeMessage(
		transport,
		.ClientAdminSetRole,
		common.ClientAdminSetRolePayload{userId = userID, isAdmin = isAdmin},
	)
}

ClientServerTransport_adminRenameUser :: proc(
	transport: ^ClientServerTransport,
	userID: int,
	nickname: string,
	locked: bool,
) -> bool {
	return ClientServerTransport_sendEncryptedRuntimeMessage(
		transport,
		.ClientAdminRenameUser,
		common.ClientAdminRenameUserPayload{userId = userID, nickname = nickname, locked = locked},
	)
}

ClientServerTransport_adminKickUser :: proc(
	transport: ^ClientServerTransport,
	userID: int,
	reason: string,
) -> bool {
	return ClientServerTransport_sendEncryptedRuntimeMessage(
		transport,
		.ClientAdminKickUser,
		common.ClientAdminKickUserPayload{userId = userID, reason = reason},
	)
}

ClientServerTransport_adminBanUser :: proc(
	transport: ^ClientServerTransport,
	userID: int,
	banned: bool,
	reason: string,
) -> bool {
	return ClientServerTransport_sendEncryptedRuntimeMessage(
		transport,
		.ClientAdminBanUser,
		common.ClientAdminBanUserPayload{userId = userID, banned = banned, reason = reason},
	)
}

// Roles (protocol 23). Listing is open to every account; the server checks the admin role for
// the others and answers with ServerAdminActionResult or a ServerProtocolError.
ClientServerTransport_adminListRoles :: proc(transport: ^ClientServerTransport) -> bool {
	return ClientServerTransport_sendEncryptedRuntimeMessage(
		transport,
		.ClientAdminListRoles,
		common.ClientAdminListRolesPayload{},
	)
}

ClientServerTransport_adminSaveRole :: proc(
	transport: ^ClientServerTransport,
	roleID: int,
	name: string,
	permissions: common.ServerPermissions,
	position: int,
) -> bool {
	return ClientServerTransport_sendEncryptedRuntimeMessage(
		transport,
		.ClientAdminSaveRole,
		common.ClientAdminSaveRolePayload {
			roleId = roleID,
			name = name,
			permissions = permissions,
			position = position,
		},
	)
}

ClientServerTransport_adminDeleteRole :: proc(
	transport: ^ClientServerTransport,
	roleID: int,
) -> bool {
	return ClientServerTransport_sendEncryptedRuntimeMessage(
		transport,
		.ClientAdminDeleteRole,
		common.ClientAdminDeleteRolePayload{roleId = roleID},
	)
}

ClientServerTransport_adminSetUserRoles :: proc(
	transport: ^ClientServerTransport,
	userID: int,
	roleIDs: []int,
) -> bool {
	ids := make([dynamic]int, 0, len(roleIDs))
	defer delete(ids)
	append(&ids, ..roleIDs)
	return ClientServerTransport_sendEncryptedRuntimeMessage(
		transport,
		.ClientAdminSetUserRoles,
		common.ClientAdminSetUserRolesPayload{userId = userID, roleIds = ids},
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
			common.ServerChatMessagePayload_deinit(&chatPayload)
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
				clientMessageID = chatPayload.clientMessageId,
				sealed = chatPayload.sealed,
				signature = chatPayload.signature,
			},
			true

	// Protocol 19: SenderKey envelopes and key requests (room_chains.odin).
	case .ServerRoomKeyEnvelope:
		payload: common.ServerRoomKeyEnvelopePayload
		if cbor.unmarshal(innerPacket.payload, &payload) != nil ||
		   payload.envelope.roomId <= 0 ||
		   len(payload.envelope.envelope) == 0 {
			common.ServerRoomKeyEnvelopePayload_deinit(&payload)
			return ClientServerTransport_invalidPayloadEvent(
					transport,
					"invalid room key envelope payload",
				),
				true
		}
		event := ClientTransportRuntimeEvent {
			kind     = .RoomKeyEnvelopeReceived,
			serverID = transport.serverID,
			roomID   = payload.envelope.roomId,
		}
		append(&event.roomKeyEnvelopes, payload.envelope)
		return event, true

	case .ServerRoomKeys:
		payload: common.ServerRoomKeysPayload
		if cbor.unmarshal(innerPacket.payload, &payload) != nil || payload.roomId <= 0 {
			common.ServerRoomKeysPayload_deinit(&payload)
			return ClientServerTransport_invalidPayloadEvent(
					transport,
					"invalid room keys payload",
				),
				true
		}
		return ClientTransportRuntimeEvent {
				kind = .RoomKeysReceived,
				serverID = transport.serverID,
				roomID = payload.roomId,
				roomKeyEnvelopes = payload.envelopes,
				hasOlder = payload.hasMore,
			},
			true

	case .ServerRoomKeyRequest:
		payload: common.ServerRoomKeyRequestPayload
		if cbor.unmarshal(innerPacket.payload, &payload) != nil ||
		   payload.roomId <= 0 ||
		   payload.epoch <= 0 ||
		   payload.requesterId <= 0 {
			return ClientServerTransport_invalidPayloadEvent(
					transport,
					"invalid room key request payload",
				),
				true
		}
		return ClientTransportRuntimeEvent {
				kind = .RoomKeyRequested,
				serverID = transport.serverID,
				roomID = payload.roomId,
				roomKeyEpoch = payload.epoch,
				roomKeyChainID = payload.chainId,
				peerUserID = payload.requesterId,
				senderID = payload.senderId,
			},
			true

	// Protocol 21: voice keys in encrypted rooms (voice_e2ee.odin).
	case .ServerVoiceKey:
		payload: common.ServerVoiceKeyPayload
		if cbor.unmarshal(innerPacket.payload, &payload) != nil ||
		   payload.roomId <= 0 ||
		   payload.senderId <= 0 ||
		   payload.epoch <= 0 ||
		   len(payload.envelope) == 0 ||
		   len(payload.envelope) > common.SEALED_ENVELOPE_MAX_BYTES {
			common.ServerVoiceKeyPayload_deinit(&payload)
			return ClientServerTransport_invalidPayloadEvent(
					transport,
					"invalid voice key payload",
				),
				true
		}
		return ClientTransportRuntimeEvent {
				kind = .VoiceKeyReceived,
				serverID = transport.serverID,
				roomID = payload.roomId,
				senderID = payload.senderId,
				voiceKey = payload,
			},
			true

	case .ServerVoiceKeyRequest:
		payload: common.ServerVoiceKeyRequestPayload
		if cbor.unmarshal(innerPacket.payload, &payload) != nil ||
		   payload.roomId <= 0 ||
		   payload.requesterId <= 0 {
			return ClientServerTransport_invalidPayloadEvent(
					transport,
					"invalid voice key request payload",
				),
				true
		}
		return ClientTransportRuntimeEvent {
				kind = .VoiceKeyRequested,
				serverID = transport.serverID,
				roomID = payload.roomId,
				peerUserID = payload.requesterId,
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
			for &message in payload.messages {
				common.StoredChatMessage_deinit(&message)
			}
			delete(payload.messages)
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
				peerUserID = payload.userId,
			},
			true

	case .ServerRoomMemberAdded, .ServerRoomMemberRemoved:
		payload: common.ServerRoomMutationPayload
		if cbor.unmarshal(innerPacket.payload, &payload) != nil {
			delete(payload.room.name)
			delete(payload.room.description)
			return ClientServerTransport_invalidPayloadEvent(
					transport,
					"invalid room member payload",
				),
				true
		}
		delete(payload.room.name)
		delete(payload.room.description)
		return ClientTransportRuntimeEvent {
				kind = .RoomMemberResult,
				serverID = transport.serverID,
				roomID = payload.roomId,
				peerUserID = payload.userId,
				joined = innerPacket.messageType == .ServerRoomMemberAdded,
				changed = payload.changed,
			},
			true

	case .ServerRoomMembers:
		payload: common.ServerRoomMembersPayload
		if cbor.unmarshal(innerPacket.payload, &payload) != nil || payload.roomId <= 0 {
			common.ServerRoomMembersPayload_deinit(&payload)
			return ClientServerTransport_invalidPayloadEvent(
					transport,
					"invalid room members payload",
				),
				true
		}
		return ClientTransportRuntimeEvent {
				kind = .RoomMembersReceived,
				serverID = transport.serverID,
				roomID = payload.roomId,
				userIDs = payload.userIds,
			},
			true

	case .ServerRoomLog:
		payload: common.ServerRoomLogPayload
		if cbor.unmarshal(innerPacket.payload, &payload) != nil ||
		   payload.roomId <= 0 ||
		   payload.afterVersion < 0 ||
		   payload.headVersion < 0 {
			common.ServerRoomLogPayload_deinit(&payload)
			return ClientServerTransport_invalidPayloadEvent(
					transport,
					"invalid room log payload",
				),
				true
		}
		return ClientTransportRuntimeEvent {
				kind = .RoomLogReceived,
				serverID = transport.serverID,
				roomID = payload.roomId,
				logEntries = payload.entries,
				logAfterVersion = payload.afterVersion,
				logHeadVersion = payload.headVersion,
				hasOlder = payload.hasMore,
			},
			true

	case .ServerAdminRooms:
		payload: common.ServerAdminRoomsPayload
		if cbor.unmarshal(innerPacket.payload, &payload) != nil {
			common.ServerAdminRoomsPayload_deinit(&payload)
			return ClientServerTransport_invalidPayloadEvent(
					transport,
					"invalid admin room list payload",
				),
				true
		}
		return ClientTransportRuntimeEvent {
				kind = .AdminRoomsReceived,
				serverID = transport.serverID,
				adminRooms = payload.rooms,
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
				isMember = payload.isMember,
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
			common.ServerDirectMessagePayload_deinit(&payload)
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
					clientMessageId = payload.clientMessageId,
					signature = payload.signature,
				},
			},
			true

	// Protocol 17: an encrypted direct message, the same event with the envelope and no
	// content. State opens it (direct_messages_e2ee.odin).
	case .ServerSealedDirectMessage:
		payload: common.ServerSealedDirectMessagePayload
		if cbor.unmarshal(innerPacket.payload, &payload) != nil || len(payload.envelope) == 0 {
			common.ServerSealedDirectMessagePayload_deinit(&payload)
			return ClientServerTransport_invalidPayloadEvent(
					transport,
					"invalid encrypted direct message payload",
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
					clientMessageId = payload.clientMessageId,
					envelope = payload.envelope,
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

	case .ServerReadMarker:
		payload: common.ServerReadMarkerPayload
		if cbor.unmarshal(innerPacket.payload, &payload) != nil ||
		   (payload.kind != .Room && payload.kind != .Direct) {
			return ClientServerTransport_invalidPayloadEvent(
					transport,
					"invalid read marker payload",
				),
				true
		}
		return ClientTransportRuntimeEvent {
				kind = .ReadMarkerReceived,
				serverID = transport.serverID,
				readMarker = payload,
			},
			true

	case .ServerVoiceParticipants:
		payload: common.ServerVoiceParticipantsPayload
		if cbor.unmarshal(innerPacket.payload, &payload) != nil || payload.roomId <= 0 {
			common.ServerVoiceParticipantsPayload_deinit(&payload)
			return ClientServerTransport_invalidPayloadEvent(
					transport,
					"invalid voice participants payload",
				),
				true
		}
		return ClientTransportRuntimeEvent {
				kind = .VoiceParticipants,
				serverID = transport.serverID,
				roomID = payload.roomId,
				voiceParticipants = payload.participants,
				voiceRecipientJoined = payload.recipientJoined,
			},
			true

	case .ServerVoiceJoinRejected:
		payload: common.ServerVoiceJoinRejectedPayload
		if cbor.unmarshal(innerPacket.payload, &payload) != nil {
			common.ServerVoiceJoinRejectedPayload_deinit(&payload)
			return ClientServerTransport_invalidPayloadEvent(
					transport,
					"invalid voice join rejection payload",
				),
				true
		}
		return ClientTransportRuntimeEvent {
				kind = .VoiceJoinRejected,
				serverID = transport.serverID,
				roomID = payload.roomId,
				message = payload.reason,
			},
			true

	case .ServerVoiceLeft:
		payload: common.ServerVoiceLeftPayload
		if cbor.unmarshal(innerPacket.payload, &payload) != nil {
			common.ServerVoiceLeftPayload_deinit(&payload)
			return ClientServerTransport_invalidPayloadEvent(
					transport,
					"invalid voice left payload",
				),
				true
		}
		return ClientTransportRuntimeEvent {
				kind = .VoiceLeft,
				serverID = transport.serverID,
				roomID = payload.roomId,
				message = payload.reason,
			},
			true

	case .ServerUserUpdated:
		payload: common.ServerUserUpdatedPayload
		if cbor.unmarshal(innerPacket.payload, &payload) != nil || payload.user.id <= 0 {
			common.ServerUserUpdatedPayload_deinit(&payload)
			return ClientServerTransport_invalidPayloadEvent(
					transport,
					"invalid user update payload",
				),
				true
		}
		return ClientTransportRuntimeEvent {
				kind = .UserUpdated,
				serverID = transport.serverID,
				user = payload.user,
			},
			true

	case .ServerAccountUpdated:
		payload: common.ServerAccountUpdatedPayload
		if cbor.unmarshal(innerPacket.payload, &payload) != nil {
			common.ServerAccountUpdatedPayload_deinit(&payload)
			return ClientServerTransport_invalidPayloadEvent(
					transport,
					"invalid account update payload",
				),
				true
		}
		return ClientTransportRuntimeEvent {
				kind = .AccountUpdated,
				serverID = transport.serverID,
				userID = transport.authenticatedUserID,
				isAdmin = payload.isAdmin,
				nickname = payload.nickname,
				nicknameLocked = payload.nicknameLocked,
				permissions = payload.permissions & common.SERVER_PERMISSIONS_ALL,
			},
			true

	case .ServerAdminActionResult:
		payload: common.ServerAdminActionResultPayload
		if cbor.unmarshal(innerPacket.payload, &payload) != nil ||
		   int(payload.action) > int(max(common.AdminAction)) {
			common.ServerAdminActionResultPayload_deinit(&payload)
			return ClientServerTransport_invalidPayloadEvent(
					transport,
					"invalid admin result payload",
				),
				true
		}
		return ClientTransportRuntimeEvent {
				kind = .AdminActionResult,
				serverID = transport.serverID,
				adminAction = payload.action,
				peerUserID = payload.userId,
				message = payload.message,
				roleID = payload.roleId,
			},
			true

	case .ServerRoleList:
		payload: common.ServerRoleListPayload
		if cbor.unmarshal(innerPacket.payload, &payload) != nil {
			common.ServerRoleListPayload_deinit(&payload)
			return ClientServerTransport_invalidPayloadEvent(
					transport,
					"invalid role list payload",
				),
				true
		}
		for &role in payload.roles {
			role.permissions &= common.SERVER_PERMISSIONS_ALL
		}
		return ClientTransportRuntimeEvent {
				kind = .RoleListReceived,
				serverID = transport.serverID,
				roles = payload.roles,
			},
			true

	case .ServerRoleUpdated:
		payload: common.ServerRoleUpdatedPayload
		if cbor.unmarshal(innerPacket.payload, &payload) != nil || payload.role.id <= 0 {
			common.ServerRoleUpdatedPayload_deinit(&payload)
			return ClientServerTransport_invalidPayloadEvent(
					transport,
					"invalid role update payload",
				),
				true
		}
		payload.role.permissions &= common.SERVER_PERMISSIONS_ALL
		return ClientTransportRuntimeEvent {
				kind = .RoleUpdated,
				serverID = transport.serverID,
				role = payload.role,
			},
			true

	case .ServerAdminRoomPermissions:
		payload: common.ServerAdminRoomPermissionsPayload
		if cbor.unmarshal(innerPacket.payload, &payload) != nil || payload.roomId <= 0 {
			common.ServerAdminRoomPermissionsPayload_deinit(&payload)
			return ClientServerTransport_invalidPayloadEvent(
					transport,
					"invalid room permissions payload",
				),
				true
		}
		payload.everyone &= common.ROOM_PERMISSIONS_ALL
		payload.myPermissions &= common.ROOM_PERMISSIONS_ALL
		for &grant in payload.roles {
			grant.permissions &= common.ROOM_PERMISSIONS_ALL
		}
		return ClientTransportRuntimeEvent {
				kind = .RoomPermissionsReceived,
				serverID = transport.serverID,
				roomID = payload.roomId,
				roomPermissions = payload,
			},
			true

	case .ServerRoleDeleted:
		payload: common.ServerRoleDeletedPayload
		if cbor.unmarshal(innerPacket.payload, &payload) != nil || payload.roleId <= 0 {
			return ClientServerTransport_invalidPayloadEvent(
					transport,
					"invalid role delete payload",
				),
				true
		}
		return ClientTransportRuntimeEvent {
				kind = .RoleDeleted,
				serverID = transport.serverID,
				roleID = payload.roleId,
			},
			true

	case .ServerUserKeys:
		payload: common.ServerUserKeysPayload
		if cbor.unmarshal(innerPacket.payload, &payload) != nil {
			common.ServerUserKeysPayload_deinit(&payload)
			return ClientServerTransport_invalidPayloadEvent(
					transport,
					"invalid user keys payload",
				),
				true
		}
		return ClientTransportRuntimeEvent {
				kind = .UserKeysReceived,
				serverID = transport.serverID,
				userKeys = payload.keys,
				missingUserIDs = payload.missingUserIds,
			},
			true

	case .ServerUserKeyChanged:
		payload: common.ServerUserKeyChangedPayload
		if cbor.unmarshal(innerPacket.payload, &payload) != nil || payload.bundle.userId <= 0 {
			return ClientServerTransport_invalidPayloadEvent(
					transport,
					"invalid user key change payload",
				),
				true
		}
		return ClientTransportRuntimeEvent {
				kind = .UserKeyChanged,
				serverID = transport.serverID,
				userKey = payload.bundle,
			},
			true

	case .ServerSessionEnded:
		payload: common.ServerSessionEndedPayload
		decodeOK := cbor.unmarshal(innerPacket.payload, &payload) == nil
		defer common.ServerSessionEndedPayload_deinit(&payload)
		// Even a payload that does not decode means the server is about to drop the session;
		// it is treated as a kick, so the client still waits for the user.
		kind := decodeOK ? payload.kind : .Kicked
		if kind != .Kicked && kind != .Banned {
			kind = .Kicked
		}
		return ClientServerTransport_sessionEnded(transport, time.tick_now(), kind, payload.reason)

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

// Reads ENet events from the established session until one decodes into a runtime event or
// none are left. Voice datagrams are handled in place (they go straight to the voice engine and
// never become events), so a stream of them cannot hold up the control packets behind it; at
// most CLIENT_VOICE_DATAGRAMS_PER_SERVICE are handled per call so the worker still gets round
// to the other servers.
ClientServerTransport_serviceEstablishedSession :: proc(
	transport: ^ClientServerTransport,
	now: time.Tick,
) -> (
	ClientTransportRuntimeEvent,
	bool,
) {
	for _ in 0 ..< CLIENT_VOICE_DATAGRAMS_PER_SERVICE {
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
			switch clientReceiveChannel(event.channelID) {
			case .Voice:
				ClientServerTransport_receiveVoiceDatagram(
					transport,
					event.packet.data[:event.packet.dataLength],
				)
				ENet.packet_destroy(event.packet)
				continue
			case .Other:
				transport.voiceStats.receiveDropped[.WrongChannel] += 1
				ENet.packet_destroy(event.packet)
				continue
			case .Control:
			}
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
	}
	return {}, false
}

ClientReceiveChannel :: enum u8 {
	Control,
	Voice,
	Other,
}

clientReceiveChannel :: proc(channelID: u8) -> ClientReceiveChannel {
	switch channelID {
	case STARTUP_AUTH_CHANNEL_CHAT:
		return .Control
	case STARTUP_AUTH_CHANNEL_VOICE:
		return .Voice
	}
	return .Other
}

// Reports whether a packet received during the handshake may be handled as a control packet.
// Everything else is counted and dropped: there are no voice keys before the session is
// established, and a datagram ENet does not authenticate must never be able to end the
// session by failing to parse.
ClientServerTransport_acceptReceiveChannel :: proc(
	transport: ^ClientServerTransport,
	channelID: u8,
) -> bool {
	switch clientReceiveChannel(channelID) {
	case .Control:
		return true
	case .Voice:
		transport.voiceStats.receiveDropped[.BeforeSession] += 1
	case .Other:
		transport.voiceStats.receiveDropped[.WrongChannel] += 1
	}
	return false
}

// Copies an ENet packet's bytes and destroys the packet.
ClientServerTransport_copyENetPacket :: proc(packet: ^ENet.Packet) -> []u8 {
	packetBytes := make([]u8, packet.dataLength)
	copy(packetBytes, packet.data[:packet.dataLength])
	ENet.packet_destroy(packet)
	return packetBytes
}
