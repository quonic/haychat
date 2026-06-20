package server

import "../common"
import "core:crypto/ecdh"
import "core:encoding/cbor"
import "core:sync"
import "core:sys/linux"
import "core:testing"

RouterTestHarness :: struct {
	config:     ^ServerConfig,
	pm:         ProcessManager,
	state:      MainRouterState,
	networkFd:  linux.Fd,
	databaseFd: linux.Fd,
}

routerTestMutex: sync.Mutex

routerResetIPCState :: proc() {
	sync.mutex_lock(&ipcState.state_mutex)
	defer sync.mutex_unlock(&ipcState.state_mutex)

	ipcState = IPC_State {
		next_fd = linux.Fd(10),
	}
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
	MainRouterState_deinit(&h.state)
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
	assert(
		databaseQuery.query == "SELECT 1",
		"expected encrypted ClientDatabaseQuery to reach database IPC intact",
	)
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
