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
	config.webAdminSocketName = "router_test_webadmin"
	config.databaseSocketName = "router_test_database"
	config.serverPrivateKey = common.identityPrivateKeyToHex(serverPrivateKey)
	config.serverPublicKey = common.identityPublicKeyToHex(serverPublicKey)

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

routerCompleteHandshake :: proc(h: ^RouterTestHarness, peerID: u32) -> common.TransportState {
	clientPrivateKey, clientPublicKey, identityOK := common.generateIdentityKeyPair()
	assert(identityOK, "expected client identity key generation to succeed")

	clientEphemeralPrivateKey, clientEphemeralPublicKey, clientEphemeralOK :=
		common.generateKeyExchangeKeyPair()
	assert(clientEphemeralOK, "expected client ephemeral key generation to succeed")
	defer ecdh.private_key_clear(&clientEphemeralPrivateKey)

	clientHello := common.ClientHello {
			version                  = common.protocolVersion,
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

	authSuccessSend := routerPollNetworkSend(h)
	defer delete(authSuccessSend.data)
	authSuccessPacket := routerDecodePacketBytes(authSuccessSend.data)
	defer delete(authSuccessPacket.payload)
	assert(
		authSuccessPacket.messageType == .ServerAuthSuccess,
		"expected auth result packet to be ServerAuthSuccess",
	)

	authSuccess: common.ServerAuthSuccessPayload
	authSuccessErr := cbor.unmarshal(authSuccessPacket.payload, &authSuccess)
	assert(authSuccessErr == nil, "expected auth success payload decode to succeed")
	defer delete(authSuccess.message)
	assert(authSuccess.userId != 0, "expected authenticated user ID to be non-zero")

	sharedSecret, sharedSecretOK := common.deriveSharedSecret(
		&clientEphemeralPrivateKey,
		serverHello.serverEphemeralPublicKey,
	)
	assert(sharedSecretOK, "expected client shared secret derivation to succeed")

	serverHelloProof := common.buildServerHelloProof(
		authChallenge.sessionID,
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

	return clientTransport
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
		.ClientDatabaseQuery,
		common.ClientDatabaseQueryRequest{query = "SELECT 1"},
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
	assert(
		databaseQuery.request.queryType == .RawSQL,
		"expected encrypted ClientDatabaseQuery to be routed as a raw SQL database request",
	)
	assert(
		databaseQuery.request.rawSQL.query == "SELECT 1",
		"expected encrypted ClientDatabaseQuery to reach database IPC intact",
	)
}

@(test)
testMainRouterAuthLookupUsesStructuredDatabaseRequest :: proc(t: ^testing.T) {
	_ = t

	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)

	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)

	peerID := u32(1)
	clientTransport := routerCompleteHandshake(&h, peerID)

	sealedPacket, sealOK := common.sealPacketForSession(
		&clientTransport,
		.ClientAuthLookup,
		common.ClientAuthLookupRequest{nickname = "hayseed"},
	)
	assert(sealOK, "expected encrypted auth lookup packet sealing to succeed")
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
	assert(
		databaseQuery.request.queryType == .AuthLookupByNickname,
		"expected auth lookup to use structured auth lookup request type",
	)
	assert(
		databaseQuery.request.authLookup.nickname == "hayseed",
		"expected auth lookup nickname to be forwarded in structured request",
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
		defer delete(chatPayload.content)
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
testMainRouterRejectsUnsupportedChatRoomID :: proc(t: ^testing.T) {
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
		"expected unsupported roomId to return ServerProtocolError",
	)

	responsePayload: common.ProtocolErrorResponse
	responsePayloadErr := cbor.unmarshal(responseInnerPacket.payload, &responsePayload)
	assert(responsePayloadErr == nil, "expected unsupported roomId payload decode to succeed")
	defer delete(responsePayload.message)
	assert(
		responsePayload.message == "Unsupported roomId",
		"expected unsupported roomId error message to match MVP contract",
	)

	_, networkErr := IPC_Client_poll(h.networkFd)
	assert(networkErr != nil, "expected unsupported roomId to avoid extra network messages")

	session, ok := MainRouterState_getPeerSession(&h.state, peerID)
	assert(ok, "expected peer session to remain available after unsupported roomId")
	assert(session.isAuthenticated, "expected unsupported roomId to preserve authentication state")
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
		.ClientDatabaseQuery,
		common.ClientDatabaseQueryRequest{query = "SELECT 3"},
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
		.ClientDatabaseQuery,
		common.ClientDatabaseQueryRequest{query = "SELECT 2"},
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
		.ClientDatabaseQuery,
		common.ClientDatabaseQueryRequest{query = "SELECT restart"},
	)
	assert(sealOK, "expected encrypted database query packet sealing to succeed")
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
	assert(
		databaseQuery.request.rawSQL.query == "SELECT restart",
		"expected database request to be queued before restart cleanup",
	)

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
		responseInnerPacket.messageType == .ServerDatabaseQueryResponse,
		"expected failed pending generic database request to produce database query response",
	)

	responsePayload: common.ServerDatabaseQueryResult
	responsePayloadErr := cbor.unmarshal(responseInnerPacket.payload, &responsePayload)
	assert(responsePayloadErr == nil, "expected failed restart response payload decode to succeed")
	defer delete(responsePayload.message)
	defer delete(responsePayload.result)
	assert(!responsePayload.success, "expected pending request to fail during database restart")
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
testConfigStartupPreflightSkipsIdentityWriteGateWhenConfigAlreadyHasValidIdentity :: proc(
	t: ^testing.T,
) {
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
testWaitForDatabaseStartupAckReturnsFailureMessage :: proc(t: ^testing.T) {
	_ = t

	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)

	routerResetIPCState()
	config := new(ServerConfig)
	config.networkSocketName = "startup_ack_network"
	config.webAdminSocketName = "startup_ack_webadmin"
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
	config.webAdminSocketName = "startup_ack_timeout_webadmin"
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
	config.webAdminSocketName = "startup_ack_exit_webadmin"
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
