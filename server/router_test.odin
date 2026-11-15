package server

import "../common"
import "core:crypto/ecdh"
import "core:encoding/cbor"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:sys/linux"
import "core:testing"
import "core:time"
import "shared:pg"

RouterTestHarness :: struct {
	config:     ^ServerConfig,
	pm:         ProcessManager,
	state:      MainRouterState,
	networkFd:  linux.Fd,
	databaseFd: linux.Fd,
}

routerTestMutex: sync.Mutex
routerTestDatabaseConnectMessage: cstring

routerTestCreateTempDir :: proc(prefix: string) -> string {
	tempRoot, tempRootErr := os.temp_directory(context.allocator)
	assert(tempRootErr == nil, "expected temp directory lookup to succeed")

	tempPath, tempPathErr := filepath.join(
		{tempRoot, fmt.aprintf("%s_%d", prefix, time.time_to_unix_nano(time.now()))},
	)
	assert(tempPathErr == nil, "expected temp directory path join to succeed")

	makeErr := os.make_directory(tempPath)
	assert(makeErr == nil, "expected temp directory creation to succeed")
	return tempPath
}

routerTestRemovePathIfExists :: proc(path: string) {
	if len(path) == 0 || !os.exists(path) {
		return
	}
	_ = os.remove(path)
}

routerTestGenerateValidIdentityConfig :: proc(config: ^ServerConfig) {
	privateKey, publicKey, identityOK := common.generateIdentityKeyPair()
	assert(identityOK, "expected test identity key generation to succeed")
	config.serverPrivateKey = common.identityPrivateKeyToHex(privateKey)
	config.serverPublicKey = common.identityPublicKeyToHex(publicKey)
}

routerTestDatabaseConnectHook :: proc "cdecl" (conninfo: cstring) -> pg.Conn {
	_ = conninfo
	return transmute(pg.Conn)uintptr(1)
}

routerTestDatabaseStatusOKHook :: proc "cdecl" (conn: pg.Conn) -> pg.Connection_Status {
	_ = conn
	return .Ok
}

routerTestDatabaseStatusBadHook :: proc "cdecl" (conn: pg.Conn) -> pg.Connection_Status {
	_ = conn
	return .Bad
}

routerTestDatabaseErrorMessageHook :: proc "cdecl" (conn: pg.Conn) -> cstring {
	_ = conn
	return routerTestDatabaseConnectMessage
}

routerTestDatabaseFinishHook :: proc "cdecl" (conn: pg.Conn) {
	_ = conn
}

routerResetIPCState :: proc() {
	sync.mutex_lock(&ipcState.state_mutex)
	defer sync.mutex_unlock(&ipcState.state_mutex)

	IPC__state_deinit()
	ipcState.next_fd = linux.Fd(10)
}

routerTestHarness_init :: proc() -> RouterTestHarness {
	routerResetIPCState()
	serverPrivateKey, serverPublicKey, identityOK := common.generateIdentityKeyPair()
	assert(identityOK, "expected server identity key generation to succeed")

	config := new(ServerConfig)
	config.networkSocketName = "router_test_network"
	config.databaseSocketName = "router_test_database"
	config.serverPrivateKey = common.identityPrivateKeyToHex(serverPrivateKey)
	config.serverPublicKey = common.identityPublicKeyToHex(serverPublicKey)
	// The defaults loadVoiceConfig would give, so voice tests start from production behaviour.
	config.voiceEnabled = DEFAULT_VOICE_ENABLED
	config.voiceMaxParticipants = DEFAULT_VOICE_MAX_PARTICIPANTS
	config.voiceMaxPacketsPerSecond = DEFAULT_VOICE_MAX_PACKETS_PER_SECOND
	config.voiceMaxFrameBytes = DEFAULT_VOICE_MAX_FRAME_BYTES

	pm := initProcessManager(config)
	pm.config.networkFd, _ = IPC_Client_init(&pm.config.networkSocket)
	pm.config.databaseFd, _ = IPC_Client_init(&pm.config.databaseSocket)

	state := MainRouterState_init(&pm)

	peerID := u32(1)
	state.connectedPeers[peerID] = true
	MainRouterState_setPeerSession(&state, peerID, RouterPeerSession_init())

	return RouterTestHarness {
		config = config,
		pm = pm,
		state = state,
		networkFd = pm.config.networkFd,
		databaseFd = pm.config.databaseFd,
	}
}

routerTestHarness_deinit :: proc(h: ^RouterTestHarness) {
	shutdownAllProcesses(&h.pm)
	MainRouterState_deinit(&h.state)
	delete(h.config.serverPrivateKey)
	delete(h.config.serverPublicKey)
	free(h.config)

	sync.mutex_lock(&ipcState.state_mutex)
	IPC__state_deinit()
	ipcState.next_fd = linux.Fd(10)
	sync.mutex_unlock(&ipcState.state_mutex)
}

routerPollNetworkSend :: proc(h: ^RouterTestHarness) -> NetworkSendData {
	msg, err := IPC_Client_poll(h.networkFd)
	assert(err == nil, "expected queued network IPC message")

	#partial switch m in msg {
	case NetworkSendData:
		return m
	case:
		assert(false, "expected NetworkSendData message")
	}
	return {}
}

// Pops the NetworkVoiceSessionOpen that follows ServerAuthSuccess. The caller wipes its keys.
routerPollVoiceSessionOpen :: proc(h: ^RouterTestHarness) -> NetworkVoiceSessionOpen {
	msg, err := IPC_Client_poll(h.networkFd)
	assert(err == nil, "expected queued NetworkVoiceSessionOpen after auth success")
	defer IPC__message_deinit(&msg)

	#partial switch m in msg {
	case NetworkVoiceSessionOpen:
		return m
	case:
		assert(false, fmt.tprintf("expected NetworkVoiceSessionOpen, got %v", msg))
	}
	return {}
}

routerPollDatabaseQuery :: proc(h: ^RouterTestHarness) -> DatabaseQuery {
	msg, err := IPC_Client_poll(h.databaseFd)
	assert(err == nil, "expected queued database IPC message")

	#partial switch m in msg {
	case DatabaseQuery:
		return m
	case:
		assert(false, "expected DatabaseQuery message")
	}
	return {}
}

routerPollDisconnect :: proc(h: ^RouterTestHarness) -> NetworkDisconnectPeer {
	msg, err := IPC_Client_poll(h.networkFd)
	assert(err == nil, "expected queued disconnect IPC message")

	#partial switch m in msg {
	case NetworkDisconnectPeer:
		return m
	case:
		assert(false, "expected NetworkDisconnectPeer message")
	}
	return {}
}

routerPollDatabaseResponseMessage :: proc(h: ^RouterTestHarness) -> NetworkSendData {
	msg, err := IPC_Client_poll(h.networkFd)
	assert(err == nil, "expected queued database response message")

	#partial switch m in msg {
	case NetworkSendData:
		return m
	case:
		assert(false, "expected NetworkSendData message for database response")
	}
	return {}
}

routerDecodePacketBytes :: proc(packetBytes: []u8) -> common.Packet {
	packet: common.Packet
	err := cbor.unmarshal(packetBytes, &packet)
	assert(err == nil, "expected packet CBOR decode to succeed")
	return packet
}

routerEncodePacketBytes :: proc(packet: common.Packet) -> []u8 {
	packetBytes, err := cbor.marshal(packet)
	assert(err == nil, "expected packet CBOR encode to succeed")
	return packetBytes
}

// renamed makes the stubbed identity resolution report that this login renamed the account,
// and isAdmin that the account holds the admin role; ServerAuthSuccess must carry the latter.
// accountNickname (protocol 14) is the account's name the identity statement reports, as for
// a name an admin locked (nicknameLocked); empty means the requested nickname. ServerAuthSuccess
// must carry it and the session must take it.
routerCompleteHandshake :: proc(
	h: ^RouterTestHarness,
	peerID: u32,
	userID := 42,
	nickname := "router-tester",
	renamed := false,
	isAdmin := false,
	voiceOpen: ^NetworkVoiceSessionOpen = nil,
	accountNickname := "",
	nicknameLocked := false,
	// When set, receives the client's identity private key (tests that sign as the client).
	identityPrivateKeyOut: ^common.IdentityPrivateKeyBytes = nil,
) -> common.TransportState {
	clientPrivateKey, clientPublicKey, identityOK := common.generateIdentityKeyPair()
	assert(identityOK, "expected client identity key generation to succeed")
	if identityPrivateKeyOut != nil {
		identityPrivateKeyOut^ = clientPrivateKey
	}

	clientEphemeralPrivateKey, clientEphemeralPublicKey, clientEphemeralOK :=
		common.generateKeyExchangeKeyPair()
	assert(clientEphemeralOK, "expected client ephemeral key generation to succeed")
	defer ecdh.private_key_clear(&clientEphemeralPrivateKey)

	clientHello := common.ClientHello {
			version                  = common.protocolVersion,
			nickname                 = nickname,
			clientIdentityPublicKey  = clientPublicKey,
			clientEphemeralPublicKey = clientEphemeralPublicKey,
		}
	clientHelloBytes, clientHelloOK := common.buildPacketBytes(.ClientHello, clientHello)
	assert(clientHelloOK, "expected ClientHello packet encoding to succeed")
	defer delete(clientHelloBytes)

	MainRouterState_handleNetworkDataReceived(
		&h.pm,
		&h.state,
		NetworkDataReceived{peerId = peerID, channel = .Chat, data = clientHelloBytes},
	)

	serverHelloSend := routerPollNetworkSend(h)
	defer delete(serverHelloSend.data)
	serverHelloPacket := routerDecodePacketBytes(serverHelloSend.data)
	defer delete(serverHelloPacket.payload)
	assert(
		serverHelloPacket.messageType == .ServerHello,
		"expected first handshake response to be ServerHello",
	)

	serverHello: common.ServerHello
	serverHelloErr := cbor.unmarshal(serverHelloPacket.payload, &serverHello)
	assert(serverHelloErr == nil, "expected ServerHello payload decode to succeed")
	assert(
		common.verifyServerHello(serverHello, clientHello),
		"expected ServerHello signature verification to succeed",
	)

	authChallengeSend := routerPollNetworkSend(h)
	defer delete(authChallengeSend.data)
	authChallengePacket := routerDecodePacketBytes(authChallengeSend.data)
	defer delete(authChallengePacket.payload)
	assert(
		authChallengePacket.messageType == .ServerAuthChallenge,
		"expected second handshake response to be ServerAuthChallenge",
	)

	authChallenge: common.ServerAuthChallengePayload
	authChallengeErr := cbor.unmarshal(authChallengePacket.payload, &authChallenge)
	assert(authChallengeErr == nil, "expected auth challenge payload decode to succeed")

	clientAuthProof := common.buildClientAuthProof(
		authChallenge.sessionID,
		authChallenge.challenge,
		clientHello.nickname,
		clientPublicKey,
		clientEphemeralPublicKey,
		serverHello.serverIdentityPublicKey,
		serverHello.serverEphemeralPublicKey,
	)
	clientAuthRequest, clientAuthRequestOK := common.signClientAuthRequest(
		clientPrivateKey,
		clientAuthProof,
	)
	assert(clientAuthRequestOK, "expected ClientAuthRequest signing to succeed")

	clientAuthBytes, clientAuthBytesOK := common.buildPacketBytes(
		.ClientAuthRequest,
		clientAuthRequest,
	)
	assert(clientAuthBytesOK, "expected ClientAuthRequest packet encoding to succeed")
	defer delete(clientAuthBytes)

	MainRouterState_handleNetworkDataReceived(
		&h.pm,
		&h.state,
		NetworkDataReceived{peerId = peerID, channel = .Chat, data = clientAuthBytes},
	)

	identityQuery := routerPollDatabaseQuery(h)
	defer IPC__database_query_request_deinit(identityQuery.request)
	identityRequest, identityRequestOK := identityQuery.request.(common.DatabaseUserIdentityRequest)
	assert(
		identityRequestOK,
		"expected auth to resolve the durable user identity before succeeding",
	)
	assert(
		identityRequest.nickname == clientHello.nickname,
		"expected identity resolution to use the client nickname",
	)
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		identityQuery.request_id,
		common.DatabaseQueryResponse {
			success = true,
			result = common.DatabaseUserIdentityResult {
				userId = userID,
				renamed = renamed,
				previousNickname = renamed ? strings.clone("router-previous") : "",
				isAdmin = isAdmin,
				nickname = strings.clone(len(accountNickname) > 0 ? accountNickname : nickname),
				nicknameLocked = nicknameLocked,
			},
		},
	)

	authSuccessSend := routerPollNetworkSend(h)
	defer delete(authSuccessSend.data)
	authSuccessPacket := routerDecodePacketBytes(authSuccessSend.data)
	defer delete(authSuccessPacket.payload)
	assert(
		authSuccessPacket.messageType == .ServerAuthSuccess,
		"expected auth result packet to be ServerAuthSuccess",
	)

	// The voice halves go to the network thread right after ServerAuthSuccess (H3). A caller
	// that wants them passes voiceOpen and wipes them; otherwise they are wiped here.
	voiceSessionOpen := routerPollVoiceSessionOpen(h)
	assert(
		voiceSessionOpen.peerId == peerID && voiceSessionOpen.userId == userID,
		fmt.tprintf(
			"expected the voice session for peer %d as user %d, got peer %d as user %d",
			peerID,
			userID,
			voiceSessionOpen.peerId,
			voiceSessionOpen.userId,
		),
	)
	assert(
		voiceSessionOpen.send.active && voiceSessionOpen.receive.active,
		"expected NetworkVoiceSessionOpen to carry active voice halves",
	)
	if voiceOpen != nil {
		voiceOpen^ = voiceSessionOpen
	}
	common.ChannelSendState_wipe(&voiceSessionOpen.send)
	common.VoiceReceiveState_wipe(&voiceSessionOpen.receive)

	authSuccess: common.ServerAuthSuccessPayload
	authSuccessErr := cbor.unmarshal(authSuccessPacket.payload, &authSuccess)
	assert(authSuccessErr == nil, "expected auth success payload decode to succeed")
	defer common.ServerAuthSuccessPayload_deinit(&authSuccess)
	assert(
		authSuccess.userId == userID,
		"expected authenticated user ID from database resolution",
	)
	expectedNickname := len(accountNickname) > 0 ? accountNickname : nickname
	assert(
		authSuccess.nickname == expectedNickname &&
		authSuccess.nicknameLocked == nicknameLocked,
		fmt.tprintf(
			"expected ServerAuthSuccess to name the account %q (locked %v), got %q (locked %v)",
			expectedNickname,
			nicknameLocked,
			authSuccess.nickname,
			authSuccess.nicknameLocked,
		),
	)
	assert(
		authSuccess.isAdmin == isAdmin,
		fmt.tprintf(
			"expected ServerAuthSuccess.isAdmin %v from the identity result, got %v",
			isAdmin,
			authSuccess.isAdmin,
		),
	)

	sharedSecret, sharedSecretOK := common.deriveSharedSecret(
		&clientEphemeralPrivateKey,
		serverHello.serverEphemeralPublicKey,
	)
	assert(sharedSecretOK, "expected client shared secret derivation to succeed")

	serverHelloProof := common.buildServerHelloProof(
		authChallenge.sessionID,
		clientHello.nickname,
		clientPublicKey,
		clientEphemeralPublicKey,
		serverHello.serverIdentityPublicKey,
		serverHello.serverEphemeralPublicKey,
	)
	transcriptHash, transcriptHashOK := common.deriveHandshakeTranscriptHash(
		serverHelloProof,
		clientAuthProof,
	)
	assert(transcriptHashOK, "expected handshake transcript hash derivation to succeed")

	clientKeys := common.deriveDirectionalTransportKeys(
		.Client,
		authChallenge.sessionID,
		sharedSecret,
		transcriptHash,
	)
	clientTransport := common.TransportState_init(.Client)
	common.TransportState_activate(&clientTransport, authChallenge.sessionID, clientKeys, .Trusted)

	session, ok := MainRouterState_getPeerSession(&h.state, peerID)
	assert(ok, "expected router peer session to exist")
	assert(session.isAuthenticated, "expected router peer session to be authenticated")
	zeroSend: common.ChannelSendState
	zeroReceive: common.VoiceReceiveState
	assert(
		session.transport.voiceSend == zeroSend && session.transport.voiceReceive == zeroReceive,
		"expected the router's copy of the voice halves to be zero after the hand-off",
	)

	return clientTransport
}

@(test)
testMainRouterAuthSuccessCarriesTheAdminFlag :: proc(t: ^testing.T) {
	_ = t

	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)

	// routerCompleteHandshake asserts that ServerAuthSuccess.isAdmin matches the identity
	// statement's flag, for an admin account and for an ordinary one.
	for isAdmin in ([]bool{true, false}) {
		h := routerTestHarness_init()
		defer routerTestHarness_deinit(&h)
		peerID := u32(1)
		_ = routerCompleteHandshake(&h, peerID, 42, isAdmin = isAdmin)
		session, ok := MainRouterState_getPeerSession(&h.state, peerID)
		assert(
			ok && session.isAuthenticated && session.authenticatedUserID == 42,
			"expected the session to be authenticated as user 42",
		)
	}
}

@(test)
testMainRouterHandshakeRoutesEncryptedApplicationPackets :: proc(t: ^testing.T) {
	_ = t

	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)

	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)

	peerID := u32(1)
	clientTransport := routerCompleteHandshake(&h, peerID)

	sealedPacket, sealOK := common.sealPacketForSession(
		&clientTransport,
		.ClientListRooms,
		common.ClientListRoomsPayload{},
	)
	assert(sealOK, "expected encrypted client application packet sealing to succeed")
	defer delete(sealedPacket.payload)

	sealedPacketBytes := routerEncodePacketBytes(sealedPacket)
	defer delete(sealedPacketBytes)

	MainRouterState_handleNetworkDataReceived(
		&h.pm,
		&h.state,
		NetworkDataReceived{peerId = peerID, channel = .Chat, data = sealedPacketBytes},
	)

	databaseQuery := routerPollDatabaseQuery(&h)
	defer IPC__database_query_request_deinit(databaseQuery.request)
	roomListRequest, roomListRequestOK := databaseQuery.request.(common.DatabaseRoomListRequest)
	assert(
		roomListRequestOK,
		"expected encrypted ClientListRooms to be routed as a room list database request",
	)
	assert(
		roomListRequest.userId == 42,
		"expected room list request to be scoped to the authenticated user ID",
	)
}

@(test)
testMainRouterRejectsUnsupportedApplicationMessage :: proc(t: ^testing.T) {
	_ = t

	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)

	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)

	peerID := u32(1)
	clientTransport := routerCompleteHandshake(&h, peerID)

	sealedPacket, sealOK := common.sealPacketForSession(
		&clientTransport,
		.ClientUploadFile,
		common.ClientListRoomsPayload{},
	)
	assert(sealOK, "expected encrypted unsupported packet sealing to succeed")
	defer delete(sealedPacket.payload)

	sealedPacketBytes := routerEncodePacketBytes(sealedPacket)
	defer delete(sealedPacketBytes)

	MainRouterState_handleNetworkDataReceived(
		&h.pm,
		&h.state,
		NetworkDataReceived{peerId = peerID, channel = .Chat, data = sealedPacketBytes},
	)

	responseSend := routerPollNetworkSend(&h)
	defer delete(responseSend.data)
	responseOuterPacket := routerDecodePacketBytes(responseSend.data)
	defer delete(responseOuterPacket.payload)
	responseInnerPacket, openOK := common.openPacketForSession(
		&clientTransport,
		responseOuterPacket,
	)
	assert(openOK, "expected client to decrypt unsupported message response")
	defer delete(responseInnerPacket.payload)
	assert(
		responseInnerPacket.messageType == .ServerProtocolError,
		"expected unsupported application message to produce ServerProtocolError",
	)

	_, databaseErr := IPC_Client_poll(h.databaseFd)
	assert(databaseErr != nil, "expected unsupported application message to reach no database")
}

@(test)
testMainRouterInitParsesConfiguredAdminPublicKey :: proc(t: ^testing.T) {
	_ = t

	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)

	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)

	assert(!h.state.hasAdminPublicKey, "expected no admin key when none is configured")

	_, adminPublicKey, keyOK := common.generateIdentityKeyPair()
	assert(keyOK, "expected admin key generation to succeed")
	h.config.adminPublicKey = common.identityPublicKeyToHex(adminPublicKey)
	defer delete(h.config.adminPublicKey)

	state := MainRouterState_init(&h.pm)
	defer MainRouterState_deinit(&state)
	assert(state.hasAdminPublicKey, "expected configured admin key to be parsed")
	assert(state.adminPublicKey == adminPublicKey, "expected parsed admin key to match config")
}

@(test)
testResolveUserIdentitySQLGuardsPrivilegedAccounts :: proc(t: ^testing.T) {
	_ = t
	assert(
		strings.contains(DATABASE_RESOLVE_USER_IDENTITY_SQL, "user_server_roles"),
		"expected identity claim SQL to check server roles before binding a key",
	)
	assert(
		strings.contains(DATABASE_RESOLVE_USER_IDENTITY_SQL, "$3"),
		"expected identity claim SQL to compare against the configured admin key",
	)
	assert(
		!strings.contains(DATABASE_RESOLVE_USER_IDENTITY_SQL, "WHERE users.public_key IS NULL OR"),
		"expected identity claim SQL not to let any key claim any keyless account",
	)
}

@(test)
testMainRouterRejectsFailedUserIdentityResolution :: proc(t: ^testing.T) {
	_ = t

	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)

	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)

	peerID := u32(1)
	MainRouterState_sendDatabaseRequest(
		&h.pm,
		&h.state,
		peerID,
		.ResolveUserIdentity,
		common.DatabaseUserIdentityRequest{nickname = strings.clone("taken-name")},
	)
	identityQuery := routerPollDatabaseQuery(&h)
	defer IPC__database_query_request_deinit(identityQuery.request)
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		identityQuery.request_id,
		common.DatabaseQueryResponse {
			success = true,
			result = common.DatabaseUserIdentityResult{userId = 0},
		},
	)

	failureSend := routerPollNetworkSend(&h)
	defer delete(failureSend.data)
	failurePacket := routerDecodePacketBytes(failureSend.data)
	defer delete(failurePacket.payload)
	assert(
		failurePacket.messageType == .ServerAuthFailure,
		"expected unresolved user identity to fail authentication",
	)
	disconnect := routerPollDisconnect(&h)
	assert(disconnect.peerId == peerID, "expected failed identity resolution to disconnect peer")

	session, sessionOK := MainRouterState_getPeerSession(&h.state, peerID)
	assert(sessionOK, "expected peer session to remain available until disconnect event")
	assert(
		!session.isAuthenticated,
		"expected failed identity resolution to leave peer unauthenticated",
	)
	assert(
		session.transport.phase == .Failed,
		"expected failed identity resolution to fail transport",
	)
}

@(test)
testMainRouterBroadcastsChatToAuthenticatedPeers :: proc(t: ^testing.T) {
	_ = t

	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)

	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)

	senderPeerID := u32(1)
	recipientPeerID := u32(2)
	h.state.connectedPeers[recipientPeerID] = true

	senderTransport := routerCompleteHandshake(&h, senderPeerID)
	recipientTransport := routerCompleteHandshake(&h, recipientPeerID)

	senderSession, senderOK := MainRouterState_getPeerSession(&h.state, senderPeerID)
	assert(senderOK, "expected sender router peer session to exist")

	sealedPacket, sealOK := common.sealPacketForSession(
		&senderTransport,
		.ClientChatMessage,
		common.ClientChatMessagePayload{roomId = 1, content = "hello haychat"},
	)
	assert(sealOK, "expected encrypted client chat packet sealing to succeed")
	defer delete(sealedPacket.payload)

	sealedPacketBytes := routerEncodePacketBytes(sealedPacket)
	defer delete(sealedPacketBytes)

	MainRouterState_handleNetworkDataReceived(
		&h.pm,
		&h.state,
		NetworkDataReceived{peerId = senderPeerID, channel = .Chat, data = sealedPacketBytes},
	)
	postQuery := routerPollDatabaseQuery(&h)
	defer IPC__database_query_request_deinit(postQuery.request)
	postRequest, postRequestOK := postQuery.request.(common.DatabasePostRoomChatMessageRequest)
	assert(postRequestOK, "expected chat send to be a single post-room-chat database request")
	assert(
		postRequest.senderId == senderSession.authenticatedUserID,
		"expected chat post to use the authenticated sender, not a client-supplied ID",
	)
	assert(postRequest.roomId == 1, "expected chat post to target the requested room")
	assert(postRequest.content == "hello haychat", "expected chat post to carry the content")

	recipientUserIDs := make([dynamic]int)
	append(&recipientUserIDs, senderSession.authenticatedUserID)
	recipientSession, recipientOK := MainRouterState_getPeerSession(&h.state, recipientPeerID)
	assert(recipientOK, "expected recipient router peer session to exist")
	append(&recipientUserIDs, recipientSession.authenticatedUserID)
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		postQuery.request_id,
		common.DatabaseQueryResponse {
			success = true,
			result = common.DatabasePostRoomChatMessageResult {
				isMember = true,
				storedMessage = {
					id = 17,
					senderId = senderSession.authenticatedUserID,
					senderNickname = strings.clone("router-tester"),
					roomId = 1,
					timestamp = strings.clone("2026-07-14T00:00:00Z"),
					content = strings.clone("hello haychat"),
				},
				recipientUserIDs = recipientUserIDs,
			},
		},
	)

	_, extraQueryErr := IPC_Client_poll(h.databaseFd)
	assert(extraQueryErr != nil, "expected chat send to need no further database round trips")

	seenSender := false
	seenRecipient := false
	for _ in 0 ..< 2 {
		broadcastSend := routerPollNetworkSend(&h)
		defer delete(broadcastSend.data)
		broadcastOuterPacket := routerDecodePacketBytes(broadcastSend.data)
		defer delete(broadcastOuterPacket.payload)
		assert(
			broadcastOuterPacket.messageType == .EncryptedPacket,
			"expected chat broadcast to use encrypted transport",
		)

		clientTransport := &senderTransport
		if broadcastSend.peerId == recipientPeerID {
			clientTransport = &recipientTransport
		}

		broadcastInnerPacket, openOK := common.openPacketForSession(
			clientTransport,
			broadcastOuterPacket,
		)
		assert(openOK, "expected client to decrypt chat broadcast packet")
		defer delete(broadcastInnerPacket.payload)
		assert(
			broadcastInnerPacket.messageType == .ServerChatMessage,
			"expected chat broadcast inner packet to be ServerChatMessage",
		)

		chatPayload: common.ServerChatMessagePayload
		chatPayloadErr := cbor.unmarshal(broadcastInnerPacket.payload, &chatPayload)
		assert(chatPayloadErr == nil, "expected chat broadcast payload decode to succeed")
		defer delete(chatPayload.senderNickname)
		defer delete(chatPayload.timestamp)
		defer delete(chatPayload.content)
		assert(chatPayload.id == 17, "expected persisted chat message ID to be broadcast")
		assert(
			chatPayload.senderNickname == "router-tester",
			"expected chat broadcast to carry the stored sender nickname",
		)
		assert(chatPayload.roomId == 1, "expected chat broadcast roomId to remain the MVP room")
		assert(
			chatPayload.senderId == senderSession.authenticatedUserID,
			"expected chat broadcast senderId to match authenticated sender",
		)
		assert(
			chatPayload.content == "hello haychat",
			"expected chat broadcast content to remain intact",
		)

		if broadcastSend.peerId == senderPeerID {
			seenSender = true
		} else if broadcastSend.peerId == recipientPeerID {
			seenRecipient = true
		} else {
			assert(false, "expected chat broadcast to target only authenticated peers")
		}
	}

	assert(seenSender, "expected sender to receive broadcasted chat message")
	assert(seenRecipient, "expected other authenticated peer to receive broadcasted chat message")
	_, networkErr := IPC_Client_poll(h.networkFd)
	assert(networkErr != nil, "expected only two chat broadcast messages to be queued")
}

@(test)
testMainRouterRejectsChatFromNonMember :: proc(t: ^testing.T) {
	_ = t

	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)

	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)

	peerID := u32(1)
	clientTransport := routerCompleteHandshake(&h, peerID)

	sealedPacket, sealOK := common.sealPacketForSession(
		&clientTransport,
		.ClientChatMessage,
		common.ClientChatMessagePayload{roomId = 2, content = "wrong room"},
	)
	assert(sealOK, "expected encrypted client chat packet sealing to succeed")
	defer delete(sealedPacket.payload)

	sealedPacketBytes := routerEncodePacketBytes(sealedPacket)
	defer delete(sealedPacketBytes)

	MainRouterState_handleNetworkDataReceived(
		&h.pm,
		&h.state,
		NetworkDataReceived{peerId = peerID, channel = .Chat, data = sealedPacketBytes},
	)
	postQuery := routerPollDatabaseQuery(&h)
	defer IPC__database_query_request_deinit(postQuery.request)
	_, postRequestOK := postQuery.request.(common.DatabasePostRoomChatMessageRequest)
	assert(postRequestOK, "expected chat send to let the database check membership")
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		postQuery.request_id,
		common.DatabaseQueryResponse {
			success = true,
			result = common.DatabasePostRoomChatMessageResult{isMember = false},
		},
	)

	responseSend := routerPollNetworkSend(&h)
	defer delete(responseSend.data)
	responseOuterPacket := routerDecodePacketBytes(responseSend.data)
	defer delete(responseOuterPacket.payload)
	assert(
		responseOuterPacket.messageType == .EncryptedPacket,
		"expected unsupported roomId response to use encrypted transport",
	)

	responseInnerPacket, openOK := common.openPacketForSession(
		&clientTransport,
		responseOuterPacket,
	)
	assert(openOK, "expected client to decrypt unsupported roomId response")
	defer delete(responseInnerPacket.payload)
	assert(
		responseInnerPacket.messageType == .ServerProtocolError,
		"expected non-member chat to return ServerProtocolError",
	)

	responsePayload: common.ProtocolErrorResponse
	responsePayloadErr := cbor.unmarshal(responseInnerPacket.payload, &responsePayload)
	assert(responsePayloadErr == nil, "expected non-member payload decode to succeed")
	defer delete(responsePayload.message)
	assert(
		responsePayload.message == "Not a room member",
		"expected non-member error message to match membership contract",
	)

	_, networkErr := IPC_Client_poll(h.networkFd)
	assert(networkErr != nil, "expected non-member chat to avoid extra network messages")

	session, ok := MainRouterState_getPeerSession(&h.state, peerID)
	assert(ok, "expected peer session to remain available after membership rejection")
	assert(
		session.isAuthenticated,
		"expected membership rejection to preserve authentication state",
	)
}

@(test)
testMainRouterRejectsMalformedOuterPacket :: proc(t: ^testing.T) {
	_ = t

	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)

	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)

	peerID := u32(1)
	MainRouterState_handleNetworkDataReceived(
		&h.pm,
		&h.state,
		NetworkDataReceived{peerId = peerID, channel = .Chat, data = []u8{1, 2, 3}},
	)

	protocolErrorMsg := routerPollNetworkSend(&h)
	defer delete(protocolErrorMsg.data)
	protocolErrorPacket := routerDecodePacketBytes(protocolErrorMsg.data)
	defer delete(protocolErrorPacket.payload)
	assert(
		protocolErrorPacket.messageType == .ServerProtocolError,
		"expected malformed outer packet to produce plaintext protocol error before auth",
	)

	protocolErrorPayload: common.ProtocolErrorResponse
	protocolErrorPayloadErr := cbor.unmarshal(protocolErrorPacket.payload, &protocolErrorPayload)
	assert(protocolErrorPayloadErr == nil, "expected malformed packet error payload to decode")
	defer delete(protocolErrorPayload.message)
	assert(
		protocolErrorPayload.message == "Invalid CBOR packet",
		"expected malformed outer packet to report invalid CBOR packet",
	)

	disconnectMsg := routerPollDisconnect(&h)
	assert(
		disconnectMsg.peerId == peerID,
		"expected malformed outer packet to disconnect offending peer",
	)
}

@(test)
testMainRouterRejectsUnexpectedPlaintextMessageBeforeAuth :: proc(t: ^testing.T) {
	_ = t

	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)

	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)

	peerID := u32(1)
	packetBytes, packetOK := common.buildPacketBytes(
		.ClientListRooms,
		common.ClientListRoomsPayload{},
	)
	assert(packetOK, "expected plaintext application packet encoding to succeed")
	defer delete(packetBytes)

	MainRouterState_handleNetworkDataReceived(
		&h.pm,
		&h.state,
		NetworkDataReceived{peerId = peerID, channel = .Chat, data = packetBytes},
	)

	protocolErrorMsg := routerPollNetworkSend(&h)
	defer delete(protocolErrorMsg.data)
	protocolErrorPacket := routerDecodePacketBytes(protocolErrorMsg.data)
	defer delete(protocolErrorPacket.payload)
	assert(
		protocolErrorPacket.messageType == .ServerProtocolError,
		"expected unexpected plaintext application packet to produce plaintext protocol error before auth",
	)

	protocolErrorPayload: common.ProtocolErrorResponse
	protocolErrorPayloadErr := cbor.unmarshal(protocolErrorPacket.payload, &protocolErrorPayload)
	assert(protocolErrorPayloadErr == nil, "expected unexpected plaintext error payload to decode")
	defer delete(protocolErrorPayload.message)
	assert(
		protocolErrorPayload.message == "Unexpected plaintext message",
		"expected unexpected plaintext application packet to report protocol violation",
	)

	disconnectMsg := routerPollDisconnect(&h)
	assert(
		disconnectMsg.peerId == peerID,
		"expected unexpected plaintext application packet to disconnect peer",
	)
}

@(test)
testMainRouterIgnoresNonChatChannelPackets :: proc(t: ^testing.T) {
	_ = t

	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)

	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)

	peerID := u32(1)
	packetBytes, packetOK := common.buildPacketBytes(.ClientHello, common.ClientHello{})
	assert(packetOK, "expected ClientHello packet encoding to succeed")
	defer delete(packetBytes)

	MainRouterState_handleNetworkDataReceived(
		&h.pm,
		&h.state,
		NetworkDataReceived{peerId = peerID, channel = .Voice, data = packetBytes},
	)

	_, networkErr := IPC_Client_poll(h.networkFd)
	assert(networkErr != nil, "expected non-chat channel packet to be ignored")
	assert(
		h.state.unexpectedVoiceDatagrams == 1,
		fmt.tprintf(
			"expected the stray voice datagram to be counted, got %d",
			h.state.unexpectedVoiceDatagrams,
		),
	)
}

@(test)
testMainRouterIgnoresEmptyPacketData :: proc(t: ^testing.T) {
	_ = t

	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)

	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)

	MainRouterState_handleNetworkDataReceived(
		&h.pm,
		&h.state,
		NetworkDataReceived{peerId = 1, channel = .Chat, data = nil},
	)

	_, networkErr := IPC_Client_poll(h.networkFd)
	assert(networkErr != nil, "expected empty packet data to be ignored")
}

@(test)
testMainRouterRejectsPlaintextAfterAuthentication :: proc(t: ^testing.T) {
	_ = t

	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)

	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)

	peerID := u32(1)
	clientTransport := routerCompleteHandshake(&h, peerID)

	plaintextPacketBytes, plaintextPacketOK := common.buildPacketBytes(
		.ClientListRooms,
		common.ClientListRoomsPayload{},
	)
	assert(plaintextPacketOK, "expected plaintext application packet encoding to succeed")
	defer delete(plaintextPacketBytes)

	MainRouterState_handleNetworkDataReceived(
		&h.pm,
		&h.state,
		NetworkDataReceived{peerId = peerID, channel = .Chat, data = plaintextPacketBytes},
	)

	firstNetworkMsg, firstNetworkErr := IPC_Client_poll(h.networkFd)
	assert(
		firstNetworkErr == nil,
		"expected post-auth plaintext violation to notify network process",
	)

	seenDisconnect := false
	#partial switch m in firstNetworkMsg {
	case NetworkSendData:
		defer delete(m.data)
		protocolErrorOuterPacket := routerDecodePacketBytes(m.data)
		defer delete(protocolErrorOuterPacket.payload)
		assert(
			protocolErrorOuterPacket.messageType == .EncryptedPacket,
			"expected post-auth protocol error to be sent as encrypted transport packet",
		)

		protocolErrorInnerPacket, openOK := common.openPacketForSession(
			&clientTransport,
			protocolErrorOuterPacket,
		)
		assert(openOK, "expected client to open encrypted protocol error packet")
		defer delete(protocolErrorInnerPacket.payload)
		assert(
			protocolErrorInnerPacket.messageType == .ServerProtocolError,
			"expected decrypted message type to be ServerProtocolError",
		)

		protocolErrorPayload: common.ProtocolErrorResponse
		protocolErrorPayloadErr := cbor.unmarshal(
			protocolErrorInnerPacket.payload,
			&protocolErrorPayload,
		)
		assert(protocolErrorPayloadErr == nil, "expected protocol error payload decode to succeed")
		defer delete(protocolErrorPayload.message)
		assert(
			protocolErrorPayload.message == "Encrypted transport required after authentication",
			"expected plaintext post-auth rejection message to describe encrypted transport requirement",
		)

		disconnectMsg := routerPollDisconnect(&h)
		assert(
			disconnectMsg.peerId == peerID,
			"expected protocol violation to disconnect offending peer",
		)
		seenDisconnect = true
	case NetworkDisconnectPeer:
		assert(
			m.peerId == peerID,
			"expected protocol violation disconnect to target offending peer",
		)
		seenDisconnect = true
	case:
		assert(false, "expected either encrypted protocol error or disconnect notification")
	}
	assert(seenDisconnect, "expected protocol violation to disconnect offending peer")

	session, ok := MainRouterState_getPeerSession(&h.state, peerID)
	assert(ok, "expected router peer session to remain inspectable after disconnect command")
	assert(
		session.transport.phase == .Failed,
		"expected protocol violation to mark transport phase failed",
	)
}

@(test)
testMainRouterPrepareForDatabaseRestartFailsPendingRequest :: proc(t: ^testing.T) {
	_ = t

	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)

	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)

	peerID := u32(1)
	clientTransport := routerCompleteHandshake(&h, peerID)

	sealedPacket, sealOK := common.sealPacketForSession(
		&clientTransport,
		.ClientListRooms,
		common.ClientListRoomsPayload{},
	)
	assert(sealOK, "expected encrypted room list packet sealing to succeed")
	defer delete(sealedPacket.payload)

	sealedPacketBytes := routerEncodePacketBytes(sealedPacket)
	defer delete(sealedPacketBytes)

	MainRouterState_handleNetworkDataReceived(
		&h.pm,
		&h.state,
		NetworkDataReceived{peerId = peerID, channel = .Chat, data = sealedPacketBytes},
	)

	databaseQuery := routerPollDatabaseQuery(&h)
	defer IPC__database_query_request_deinit(databaseQuery.request)
	_, isRoomListRequest := databaseQuery.request.(common.DatabaseRoomListRequest)
	assert(isRoomListRequest, "expected database request to be queued before restart cleanup")

	MainRouterState_prepareForProcessStop(&h.pm, &h.state, .Database, "database restarting")

	responseSend := routerPollDatabaseResponseMessage(&h)
	defer delete(responseSend.data)
	responseOuterPacket := routerDecodePacketBytes(responseSend.data)
	defer delete(responseOuterPacket.payload)
	assert(
		responseOuterPacket.messageType == .EncryptedPacket,
		"expected restart failure notification to use encrypted transport",
	)

	responseInnerPacket, openOK := common.openPacketForSession(
		&clientTransport,
		responseOuterPacket,
	)
	assert(openOK, "expected client to decrypt restart failure response")
	defer delete(responseInnerPacket.payload)
	assert(
		responseInnerPacket.messageType == .ServerProtocolError,
		"expected failed pending room list request to produce a protocol error",
	)

	responsePayload: common.ProtocolErrorResponse
	responsePayloadErr := cbor.unmarshal(responseInnerPacket.payload, &responsePayload)
	assert(responsePayloadErr == nil, "expected failed restart response payload decode to succeed")
	defer delete(responsePayload.message)
	assert(
		responsePayload.message == "database restarting",
		"expected restart failure message to explain database restart",
	)
	assert(
		len(h.state.pendingDatabaseRequests) == 0,
		"expected pending database requests to be drained during database restart",
	)
}

@(test)
testProcessManagerRestartSchedulingIsDeduplicated :: proc(t: ^testing.T) {
	_ = t

	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)

	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)

	h.pm.config.maxRestarts = 5
	h.pm.config.restartBackoffMin = 0
	h.pm.config.restartBackoffMax = 0
	h.pm.config.maxNetworkThreads = 0

	h.pm.networkProcess.isRunning = false
	firstScheduled := restartProcess(&h.pm, .Network)
	secondScheduled := restartProcess(&h.pm, .Network)

	assert(firstScheduled, "expected first restart schedule to succeed")
	assert(
		secondScheduled,
		"expected duplicate restart request to be treated as already scheduled",
	)
	assert(
		h.pm.networkProcess.restartPending,
		"expected restart scheduling to mark the process restart as pending",
	)
	assert(
		h.pm.networkProcess.restartCount == 1,
		"expected duplicate restart scheduling to avoid incrementing restart count twice",
	)

}

@(test)
testMainRouterStoreFileValidationFailureReturnsMessage :: proc(t: ^testing.T) {
	_ = t

	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)

	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)

	peerID := u32(1)
	clientTransport := routerCompleteHandshake(&h, peerID)

	searedPacket, sealOK := common.sealPacketForSession(
		&clientTransport,
		.ClientStoreFile,
		common.ClientStoreFileRequest{filename = "", content = []u8{1}},
	)
	assert(sealOK, "expected encrypted file-store packet sealing to succeed")
	defer delete(searedPacket.payload)

	sealedPacketBytes := routerEncodePacketBytes(searedPacket)
	defer delete(sealedPacketBytes)

	MainRouterState_handleNetworkDataReceived(
		&h.pm,
		&h.state,
		NetworkDataReceived{peerId = peerID, channel = .Chat, data = sealedPacketBytes},
	)

	responseSend := routerPollDatabaseResponseMessage(&h)
	defer delete(responseSend.data)
	responseOuterPacket := routerDecodePacketBytes(responseSend.data)
	defer delete(responseOuterPacket.payload)
	assert(
		responseOuterPacket.messageType == .EncryptedPacket,
		"expected file-store validation failure to use encrypted transport",
	)

	responseInnerPacket, openOK := common.openPacketForSession(
		&clientTransport,
		responseOuterPacket,
	)
	assert(openOK, "expected client to decrypt file-store validation response")
	defer delete(responseInnerPacket.payload)
	assert(
		responseInnerPacket.messageType == .ServerStoreFileResponse,
		"expected file-store validation failure to return a file-store response",
	)

	responsePayload: common.ServerStoreFileResult
	responsePayloadErr := cbor.unmarshal(responseInnerPacket.payload, &responsePayload)
	assert(responsePayloadErr == nil, "expected file-store response payload decode to succeed")
	defer delete(responsePayload.message)
	defer delete(responsePayload.hashedFilename)
	assert(!responsePayload.success, "expected invalid file-store request to fail")
	assert(
		responsePayload.message == "invalid payload",
		"expected invalid file-store request to explain payload validation failure",
	)
}

@(test)
testConfigStartupPreflightFailsWhenFileStoragePathIsNotWritable :: proc(t: ^testing.T) {
	// ServerConfig is process-lifetime and never freed, so config tests run on the temp allocator.
	context.allocator = context.temp_allocator
	_ = t

	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)

	tempDir := routerTestCreateTempDir("hc107_storage_not_writable")
	defer routerTestRemovePathIfExists(tempDir)

	fileStoragePath, joinErr := filepath.join({tempDir, "not_a_directory"})
	assert(joinErr == nil, "expected file storage test path join to succeed")

	writeErr := os.write_entire_file_from_bytes(fileStoragePath, []u8{1, 2, 3})
	assert(writeErr == nil, "expected file storage test file creation to succeed")
	defer routerTestRemovePathIfExists(fileStoragePath)

	config := ServerConfig {
		fileStoragePath = fileStoragePath,
	}
	routerTestGenerateValidIdentityConfig(&config)

	preflightErr := startupPreflightError(config)
	assert(
		len(preflightErr) > 0,
		"expected startup preflight to fail for a non-directory file storage path",
	)
	assert(
		strings.contains(preflightErr, "file storage path"),
		"expected startup preflight error to mention the file storage path",
	)
	delete(preflightErr)
}

@(test)
testValidateAndNormalizeConfigUsesTesterSafeLocalRuntimeDefaults :: proc(t: ^testing.T) {
	// ServerConfig is process-lifetime and never freed, so config tests run on the temp allocator.
	context.allocator = context.temp_allocator
	_ = t

	config := ServerConfig{}
	validateAndNormalizeConfig(&config)
	defer delete(config.serverIdentityFilePath)

	assert(
		config.logPath == "logs",
		"expected empty log path to normalize to a local logs directory",
	)
	assert(
		config.fileStoragePath == "storage",
		"expected empty file storage path to normalize to a local storage directory",
	)
	assert(
		config.serverIdentityFilePath == "storage/server_identity.json",
		"expected empty server identity path to default under local storage",
	)
}

@(test)
testValidateAndNormalizeConfigUsesConfiguredStorageForDefaultIdentityPath :: proc(t: ^testing.T) {
	// ServerConfig is process-lifetime and never freed, so config tests run on the temp allocator.
	context.allocator = context.temp_allocator
	_ = t

	config := ServerConfig {
		fileStoragePath = "custom-storage",
	}
	validateAndNormalizeConfig(&config)
	defer delete(config.serverIdentityFilePath)

	assert(
		config.serverIdentityFilePath == "custom-storage/server_identity.json",
		"expected default identity path to follow the configured storage path",
	)
}

@(test)
testConfigStartupPreflightSkipsIdentityWriteGateWhenConfigAlreadyHasValidIdentity :: proc(
	t: ^testing.T,
) {
	// ServerConfig is process-lifetime and never freed, so config tests run on the temp allocator.
	context.allocator = context.temp_allocator
	_ = t

	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)

	tempDir := routerTestCreateTempDir("hc107_identity_skip")
	defer routerTestRemovePathIfExists(tempDir)

	storageDir, storageDirErr := filepath.join({tempDir, "storage"})
	assert(storageDirErr == nil, "expected storage path join to succeed")
	storageDirMakeErr := os.make_directory(storageDir)
	assert(storageDirMakeErr == nil, "expected storage directory creation to succeed")
	defer routerTestRemovePathIfExists(storageDir)

	blockingParentPath, blockingParentErr := filepath.join({tempDir, "identity_parent_blocker"})
	assert(blockingParentErr == nil, "expected identity blocker path join to succeed")
	blockingParentWriteErr := os.write_entire_file_from_bytes(blockingParentPath, []u8{9})
	assert(blockingParentWriteErr == nil, "expected identity blocker file creation to succeed")
	defer routerTestRemovePathIfExists(blockingParentPath)

	identityPath, identityPathErr := filepath.join({blockingParentPath, "server_identity.json"})
	assert(identityPathErr == nil, "expected identity path join to succeed")

	config := ServerConfig {
		fileStoragePath        = storageDir,
		serverIdentityFilePath = identityPath,
	}
	routerTestGenerateValidIdentityConfig(&config)

	preflightErr := startupPreflightError(config)
	assert(
		len(preflightErr) == 0,
		"expected valid configured identity to skip identity path write preflight",
	)
}

@(test)
testDatabaseOpenRuntimeConnectionWithHooksReturnsActionableFailure :: proc(t: ^testing.T) {
	_ = t

	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)

	connectMessage, connectMessageErr := strings.clone_to_cstring(
		"dial tcp 127.0.0.1:5432: connection refused",
	)
	assert(connectMessageErr == nil, "expected test cstring allocation to succeed")
	routerTestDatabaseConnectMessage = connectMessage
	defer delete(connectMessage)

	config := ServerConfig {
		databaseURL  = "127.0.0.1",
		databasePort = 5432,
		databaseUser = "haychat",
		databasePass = "",
		databaseName = "haychat",
	}

	conn, openErr := databaseOpenRuntimeConnectionWithHooks(
		config,
		routerTestDatabaseConnectHook,
		routerTestDatabaseStatusBadHook,
		routerTestDatabaseErrorMessageHook,
		routerTestDatabaseFinishHook,
	)

	assert(
		conn == pg.Conn(nil),
		"expected failed database startup connection to return nil connection",
	)
	assert(len(openErr) > 0, "expected failed database startup connection to return an error")
	assert(
		strings.contains(openErr, "connection refused"),
		"expected failed database startup connection to preserve the libpq failure detail",
	)
	delete(openErr)
}

@(test)
testDatabaseRuntimeConninfoAddsConnectTimeout :: proc(t: ^testing.T) {
	_ = t

	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)

	config := ServerConfig {
		databaseURL  = "10.0.0.99",
		databasePort = 5432,
		databaseUser = "haychat",
		databasePass = "secret",
		databaseName = "haychat",
	}

	conninfo := databaseRuntimeConninfo(config)
	defer delete(conninfo)
	conninfoText := cloneCStringOrEmpty(conninfo)
	defer delete(conninfoText)

	assert(
		strings.contains(conninfoText, "connect_timeout="),
		"expected runtime database conninfo to set a bounded connect timeout",
	)
}

@(test)
testDatabaseSchemaCreationOwnsTablesWithoutSeedData :: proc(t: ^testing.T) {
	_ = t

	assert(
		strings.contains(
			DATABASE_MIGRATION_1_BASELINE_SQL,
			"CREATE TABLE IF NOT EXISTS users",
		),
		"expected server schema setup to create the users table",
	)
	assert(
		strings.contains(
			DATABASE_MIGRATION_1_BASELINE_SQL,
			"CREATE TABLE IF NOT EXISTS chat_messages",
		),
		"expected server schema setup to create the chat messages table",
	)
	assert(
		!strings.contains(DATABASE_MIGRATION_1_BASELINE_SQL, "INSERT INTO"),
		"expected normal server schema setup to avoid seeding application data",
	)
	assert(
		!strings.contains(DATABASE_MIGRATION_1_BASELINE_SQL, "DELETE FROM"),
		"expected normal server schema setup to avoid deleting application data",
	)
}

@(test)
testDatabaseSchemaValidationRequiresQueryIndexes :: proc(t: ^testing.T) {
	_ = t

	assert(
		strings.contains(DATABASE_SCHEMA_VALIDATION_SQL, "users_public_key_unique"),
		"expected schema validation to require the public key index",
	)
	assert(
		strings.contains(DATABASE_SCHEMA_VALIDATION_SQL, "room_members_by_user_id"),
		"expected schema validation to require the room membership index",
	)
	assert(
		strings.contains(DATABASE_SCHEMA_VALIDATION_SQL, "chat_messages_by_room_id_and_id"),
		"expected schema validation to require the chat history index",
	)
}

@(test)
testWaitForDatabaseStartupAckReturnsFailureMessage :: proc(t: ^testing.T) {
	_ = t

	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)

	routerResetIPCState()
	config := new(ServerConfig)
	config.networkSocketName = "startup_ack_network"
	config.databaseSocketName = "startup_ack_database"
	pm := initProcessManager(config)
	defer free(config)

	IPC_Server_send(
		&config.databaseSocket,
		config.mainFd,
		DatabaseStartupFailed{error = strings.clone("database unavailable")},
	)

	startupErr := waitForDatabaseStartupAck(&pm)
	assert(
		startupErr == "database unavailable",
		"expected database startup ack wait to return the startup failure message",
	)
	delete(startupErr)

	sync.mutex_lock(&ipcState.state_mutex)
	IPC__state_deinit()
	ipcState.next_fd = linux.Fd(10)
	sync.mutex_unlock(&ipcState.state_mutex)
}

@(test)
testWaitForDatabaseStartupAckTimesOutWhenWorkerNeverResponds :: proc(t: ^testing.T) {
	_ = t

	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)

	routerResetIPCState()
	config := new(ServerConfig)
	config.networkSocketName = "startup_ack_timeout_network"
	config.databaseSocketName = "startup_ack_timeout_database"
	config.databaseURL = "127.0.0.1"
	config.databasePort = 5432
	config.databaseUser = "haychat"
	config.databaseName = "haychat"
	pm := initProcessManager(config)
	pm.databaseProcess.isRunning = true
	defer free(config)

	startupErr := waitForDatabaseStartupAckWithTimeout(&pm, 5 * time.Millisecond)
	assert(len(startupErr) > 0, "expected database startup ack wait to time out")
	assert(
		strings.contains(startupErr, "timed out"),
		"expected database startup ack timeout to mention the timeout",
	)
	assert(
		strings.contains(startupErr, "haychat@"),
		"expected database startup ack timeout to identify the database target",
	)
	delete(startupErr)

	sync.mutex_lock(&ipcState.state_mutex)
	IPC__state_deinit()
	ipcState.next_fd = linux.Fd(10)
	sync.mutex_unlock(&ipcState.state_mutex)
}

@(test)
testWaitForDatabaseStartupAckReturnsActionableExitFailure :: proc(t: ^testing.T) {
	_ = t

	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)

	routerResetIPCState()
	config := new(ServerConfig)
	config.networkSocketName = "startup_ack_exit_network"
	config.databaseSocketName = "startup_ack_exit_database"
	config.databaseURL = "127.0.0.1"
	config.databasePort = 5432
	config.databaseUser = "haychat"
	config.databaseName = "haychat"
	pm := initProcessManager(config)
	defer free(config)

	startupErr := waitForDatabaseStartupAckWithTimeout(&pm, 5 * time.Millisecond)
	assert(len(startupErr) > 0, "expected database startup ack wait to fail when worker exits")
	assert(
		strings.contains(startupErr, "exited before reporting readiness"),
		"expected database startup exit failure to explain the missing readiness report",
	)
	assert(
		strings.contains(startupErr, "haychat@"),
		"expected database startup exit failure to identify the database target",
	)
	delete(startupErr)

	sync.mutex_lock(&ipcState.state_mutex)
	IPC__state_deinit()
	ipcState.next_fd = linux.Fd(10)
	sync.mutex_unlock(&ipcState.state_mutex)
}

routerTestSendRoomHistoryRequest :: proc(
	h: ^RouterTestHarness,
	clientTransport: ^common.TransportState,
	peerID: u32,
) -> DatabaseQuery {
	sealedPacket, sealOK := common.sealPacketForSession(
		clientTransport,
		.ClientFetchRoomHistory,
		common.ClientFetchRoomHistoryPayload{roomId = 3, beforeMessageID = 0, limit = 20},
	)
	assert(sealOK, "expected encrypted history request sealing to succeed")
	defer delete(sealedPacket.payload)
	sealedPacketBytes := routerEncodePacketBytes(sealedPacket)
	defer delete(sealedPacketBytes)

	MainRouterState_handleNetworkDataReceived(
		&h.pm,
		&h.state,
		NetworkDataReceived{peerId = peerID, channel = .Chat, data = sealedPacketBytes},
	)
	return routerPollDatabaseQuery(h)
}

routerTestOpenInnerPacket :: proc(
	h: ^RouterTestHarness,
	clientTransport: ^common.TransportState,
) -> common.Packet {
	responseSend := routerPollNetworkSend(h)
	defer delete(responseSend.data)
	responseOuterPacket := routerDecodePacketBytes(responseSend.data)
	defer delete(responseOuterPacket.payload)
	innerPacket, openOK := common.openPacketForSession(clientTransport, responseOuterPacket)
	assert(openOK, "expected client to decrypt the router response")
	return innerPacket
}

@(test)
testMainRouterRoomHistoryChecksMembershipInOneQuery :: proc(t: ^testing.T) {
	_ = t

	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)

	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)

	peerID := u32(1)
	clientTransport := routerCompleteHandshake(&h, peerID)

	historyQuery := routerTestSendRoomHistoryRequest(&h, &clientTransport, peerID)
	defer IPC__database_query_request_deinit(historyQuery.request)
	historyRequest, historyRequestOK := historyQuery.request.(common.DatabaseRoomHistoryRequest)
	assert(historyRequestOK, "expected history fetch to be a single room history request")
	assert(
		historyRequest.userId == 42 && historyRequest.roomId == 3 && historyRequest.limit == 20,
		"expected history request to carry the authenticated user, room, and page size",
	)

	messages := make([dynamic]common.StoredChatMessage)
	append(
		&messages,
		common.StoredChatMessage {
			id = 5,
			senderId = 42,
			senderNickname = strings.clone("history-sender"),
			roomId = 3,
			timestamp = strings.clone("t5"),
			content = strings.clone("five"),
		},
	)
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		historyQuery.request_id,
		common.DatabaseQueryResponse {
			success = true,
			result = common.DatabaseRoomHistoryResult {
				isMember = true,
				messages = messages,
				hasOlder = true,
			},
		},
	)
	historyPacket := routerTestOpenInnerPacket(&h, &clientTransport)
	defer delete(historyPacket.payload)
	assert(historyPacket.messageType == .ServerRoomHistory, "expected members to get history")
	historyPayload: common.ServerRoomHistoryPayload
	assert(
		cbor.unmarshal(historyPacket.payload, &historyPayload) == nil,
		"expected history payload decode to succeed",
	)
	defer {
		for message in historyPayload.messages {
			delete(message.senderNickname)
			delete(message.timestamp)
			delete(message.content)
		}
		delete(historyPayload.messages)
	}
	assert(
		len(historyPayload.messages) == 1 && historyPayload.messages[0].id == 5,
		"expected the stored page to reach the client",
	)
	assert(historyPayload.hasOlder, "expected pagination state to reach the client")
	assert(
		historyPayload.messages[0].senderNickname == "history-sender",
		"expected history messages to carry the sender nickname",
	)

	deniedQuery := routerTestSendRoomHistoryRequest(&h, &clientTransport, peerID)
	defer IPC__database_query_request_deinit(deniedQuery.request)
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		deniedQuery.request_id,
		common.DatabaseQueryResponse {
			success = true,
			result = common.DatabaseRoomHistoryResult{isMember = false},
		},
	)
	deniedPacket := routerTestOpenInnerPacket(&h, &clientTransport)
	defer delete(deniedPacket.payload)
	assert(
		deniedPacket.messageType == .ServerProtocolError,
		"expected non-members to be refused room history",
	)
}

@(test)
testOpenRoomSQLJoinsEveryAccount :: proc(t: ^testing.T) {
	_ = t
	assert(
		strings.contains(DATABASE_RESOLVE_USER_IDENTITY_SQL, "INSERT INTO room_members") &&
		strings.contains(DATABASE_RESOLVE_USER_IDENTITY_SQL, "CROSS JOIN inserted"),
		"expected identity resolution to join the created account to rooms in one statement",
	)
	assert(
		strings.contains(DATABASE_RESOLVE_USER_IDENTITY_SQL, "UPDATE users SET nickname = $1") &&
		strings.contains(DATABASE_RESOLVE_USER_IDENTITY_SQL, "WHERE public_key = decode($2"),
		"expected identity resolution to rename the key's account in the same statement",
	)
	assert(
		strings.contains(DATABASE_RESOLVE_USER_IDENTITY_SQL, "NOT EXISTS (SELECT 1 FROM existing)"),
		"expected only accounts created by the statement to be auto-joined",
	)
	assert(
		strings.contains(DATABASE_RESOLVE_USER_IDENTITY_SQL, "WHERE r.access = 1 AND"),
		"expected new accounts to join only Public rooms (protocol 15)",
	)
	assert(
		strings.contains(DATABASE_CREATE_ROOM_SQL, "CROSS JOIN users") &&
		strings.contains(DATABASE_CREATE_ROOM_SQL, "(created_room.access = 1 ") &&
		strings.contains(DATABASE_CREATE_ROOM_SQL, "WHERE NOT created_room.encrypted AND"),
		"expected a Public room to include every account, an invite room only its creator, " +
		"and an encrypted room nobody until its log's Create",
	)
	assert(
		strings.contains(DATABASE_POST_ROOM_CHAT_MESSAGE_SQL, "nickname FROM users") &&
		strings.contains(DATABASE_GET_ROOM_HISTORY_SQL, "JOIN users"),
		"expected chat post and history to read the sender nickname",
	)
}

@(test)
testMainRouterCreateRoomNotifiesEveryAuthenticatedSession :: proc(t: ^testing.T) {
	_ = t

	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)

	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)

	adminPeerID := u32(1)
	otherPeerID := u32(2)
	unauthenticatedPeerID := u32(3)
	h.state.connectedPeers[otherPeerID] = true
	h.state.connectedPeers[unauthenticatedPeerID] = true
	MainRouterState_setPeerSession(&h.state, unauthenticatedPeerID, RouterPeerSession_init())

	adminTransport := routerCompleteHandshake(&h, adminPeerID, 42)
	otherTransport := routerCompleteHandshake(&h, otherPeerID, 43)
	// 43's first session announces it to the admin's session before any room traffic.
	presencePeers := [?]RouterTestPeer{{adminPeerID, &adminTransport}}
	presencePeerID, presence := routerTestReceivePresence(&h, presencePeers[:])
	delete(presence.nickname)
	assert(
		presencePeerID == adminPeerID && presence.userId == 43 && presence.isOnline,
		"expected the admin's session to hear that 43 came online",
	)

	sealedPacket, sealOK := common.sealPacketForSession(
		&adminTransport,
		.ClientCreateRoom,
		common.ClientCreateRoomPayload {
			name = "lobby",
			description = "hang out",
			roomType = .ChatAndVoice,
			access = .Public,
			historyVisibility = .FromJoin,
			creatorJoins = true,
		},
	)
	assert(sealOK, "expected encrypted create room packet sealing to succeed")
	defer delete(sealedPacket.payload)
	sealedPacketBytes := routerEncodePacketBytes(sealedPacket)
	defer delete(sealedPacketBytes)
	MainRouterState_handleNetworkDataReceived(
		&h.pm,
		&h.state,
		NetworkDataReceived{peerId = adminPeerID, channel = .Chat, data = sealedPacketBytes},
	)

	adminQuery := routerPollDatabaseQuery(&h)
	defer IPC__database_query_request_deinit(adminQuery.request)
	_, adminRequestOK := adminQuery.request.(common.DatabaseUserServerAdminRequest)
	assert(adminRequestOK, "expected room creation to check the admin role first")
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		adminQuery.request_id,
		common.DatabaseQueryResponse {
			success = true,
			result = common.DatabaseUserServerAdminResult{isAdmin = true},
		},
	)

	createQuery := routerPollDatabaseQuery(&h)
	defer IPC__database_query_request_deinit(createQuery.request)
	createRequest, createRequestOK := createQuery.request.(common.DatabaseCreateRoomRequest)
	assert(createRequestOK, "expected an admin's room creation to reach the database")
	assert(
		createRequest.creatorUserId == 42 &&
		createRequest.name == "lobby" &&
		createRequest.roomType == .ChatAndVoice &&
		createRequest.access == .Public &&
		createRequest.historyVisibility == .FromJoin &&
		createRequest.creatorJoins,
		"expected the create request to carry the creator, room name, type and access",
	)
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		createQuery.request_id,
		common.DatabaseQueryResponse {
			success = true,
			result = common.DatabaseRoomMutationResult {
				changed = true,
				isMember = true,
				room = {
					id = 9,
					name = strings.clone("lobby"),
					description = strings.clone("hang out"),
					access = .Public,
					historyVisibility = .Full,
				},
			},
		},
	)

	adminSawCreate := false
	adminSawMembership := false
	otherSawMembership := false
	for _ in 0 ..< 3 {
		send := routerPollNetworkSend(&h)
		defer delete(send.data)
		assert(
			send.peerId == adminPeerID || send.peerId == otherPeerID,
			fmt.tprintf("expected no message for unauthenticated peer, got peer %d", send.peerId),
		)
		outerPacket := routerDecodePacketBytes(send.data)
		defer delete(outerPacket.payload)
		clientTransport := &adminTransport
		if send.peerId == otherPeerID {
			clientTransport = &otherTransport
		}
		innerPacket, openOK := common.openPacketForSession(clientTransport, outerPacket)
		assert(openOK, "expected the recipient to decrypt the room creation notice")
		defer delete(innerPacket.payload)

		#partial switch innerPacket.messageType {
		case .ServerCreateRoom:
			assert(send.peerId == adminPeerID, "expected only the creator to get ServerCreateRoom")
			adminSawCreate = true
		case .ServerRoomMembershipChanged:
			payload: common.ServerRoomMembershipChangedPayload
			assert(
				cbor.unmarshal(innerPacket.payload, &payload) == nil,
				"expected membership payload decode to succeed",
			)
			expectedUserID := send.peerId == adminPeerID ? 42 : 43
			assert(
				payload.roomId == 9 && payload.joined && payload.userId == expectedUserID,
				fmt.tprintf(
					"expected the membership notice to say %d joined room 9, got %v",
					expectedUserID,
					payload,
				),
			)
			if send.peerId == adminPeerID {
				adminSawMembership = true
			} else {
				otherSawMembership = true
			}
		case:
			assert(
				false,
				fmt.tprintf("unexpected room creation message %v", innerPacket.messageType),
			)
		}
	}
	assert(adminSawCreate, "expected the creator to get the room creation result")
	assert(adminSawMembership, "expected the creator to be told to refresh its room list")
	assert(otherSawMembership, "expected every other session to refresh its room list")
	_, networkErr := IPC_Client_poll(h.networkFd)
	assert(networkErr != nil, "expected exactly one notice per authenticated session")
}

@(test)
testDatabaseParseIDListSkipsInvalidEntries :: proc(t: ^testing.T) {
	_ = t
	ids := databaseParseIDList("10,11,,x,12")
	defer delete(ids)
	assert(
		len(ids) == 3 && ids[0] == 10 && ids[1] == 11 && ids[2] == 12,
		"expected numeric IDs to be parsed and blanks or junk skipped",
	)
	empty := databaseParseIDList("")
	defer delete(empty)
	assert(len(empty) == 0, "expected an empty recipient list to parse as empty")
}
