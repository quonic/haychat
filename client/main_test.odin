#+feature dynamic-literals
package client

import "../common"
import "core:os"
import "core:sync"
import "core:testing"

startupAuthBridgeTestMutex: sync.Mutex

buildServerHelloPacketBytes :: proc(
	transport: ^ClientServerTransport,
	serverIdentityPrivateKey: common.IdentityPrivateKeyBytes,
	serverIdentityPublicKey: common.IdentityPublicKeyBytes,
	serverEphemeralPublicKey: common.KeyExchangePublicKeyBytes,
	sessionID: common.SessionID,
) -> (
	[]u8,
	bool,
) {
	clientHello := common.ClientHello {
		version                  = common.protocolVersion,
		clientIdentityPublicKey  = transport.clientIdentityPublicKey,
		clientEphemeralPublicKey = transport.clientEphemeralPublicKey,
	}
	serverHelloProof := common.buildServerHelloProof(
		sessionID,
		clientHello.clientIdentityPublicKey,
		clientHello.clientEphemeralPublicKey,
		serverIdentityPublicKey,
		serverEphemeralPublicKey,
	)
	serverHello, signOK := common.signServerHello(serverIdentityPrivateKey, serverHelloProof)
	if !signOK {
		return nil, false
	}
	return common.buildPacketBytes(.ServerHello, serverHello)
}

testConfigWithServers :: proc(servers: [dynamic]Server) -> Config {
	privateKey, publicKey, ok := common.generateIdentityKeyPair()
	assert(ok, "expected identity key generation to succeed")

	return Config {
		private_key = common.identityPrivateKeyToHex(privateKey),
		public_key = common.identityPublicKeyToHex(publicKey),
		display_name = "Tester",
		servers = servers,
		friends = {},
	}
}

@(test)
testStateInitFromConfigAttemptsOnlySelectedDefaultServer :: proc(t: ^testing.T) {
	sync.mutex_lock(&startupAuthBridgeTestMutex)
	defer sync.mutex_unlock(&startupAuthBridgeTestMutex)

	config := testConfigWithServers(
		{
			Server {
				id = 11,
				name = "Alpha Server",
				short_name = getShortServerName("Alpha Server"),
				host = "localhost",
				port = common.DEFAULT_SERVER_PORT,
			},
			Server {
				id = 22,
				name = "Bravo Server",
				short_name = getShortServerName("Bravo Server"),
				host = "localhost",
				port = common.DEFAULT_SERVER_PORT + 1,
			},
		},
	)

	state := State_initFromConfig(config)

	testing.expect(
		t,
		state.selected_server_id == 11,
		"expected first configured server to be selected",
	)
	testing.expect(
		t,
		state.selected_transport_index == 0,
		"expected selected transport index to point at the selected server",
	)
	testing.expect(t, len(state.serverTransports) == 2, "expected a transport entry per server")
	testing.expect(
		t,
		state.serverTransports[0].transport.phase == .ClientHelloSent,
		"expected selected/default server startup attempt to begin the handshake",
	)
	testing.expect(
		t,
		state.serverTransports[1].transport.phase == .Disconnected,
		"expected non-selected servers to remain idle",
	)
	testing.expect(
		t,
		len(state.serverTransports[0].lastError) == 0,
		"expected selected/default startup attempt to avoid setting an error on success",
	)
}

@(test)
testStateInitFromConfigCanEstablishSelectedTransportViaStartupBridge :: proc(t: ^testing.T) {
	sync.mutex_lock(&startupAuthBridgeTestMutex)
	defer sync.mutex_unlock(&startupAuthBridgeTestMutex)

	config := testConfigWithServers(
		{
			Server {
				id = 44,
				name = "Handshake Server",
				short_name = getShortServerName("Handshake Server"),
				host = "localhost",
				port = common.DEFAULT_SERVER_PORT,
			},
		},
	)

	originalBridge := startupAuthBridge
	startupAuthBridge = proc(
		transport: ^ClientServerTransport,
		server: ^Server,
		bridgeConfig: ^Config,
		clientHelloPacketBytes: []u8,
	) -> ClientStartupAuthSession {
		_ = clientHelloPacketBytes

		serverIdentityPrivateKey, serverIdentityPublicKey, identityOK :=
			common.generateIdentityKeyPair()
		assert(identityOK, "expected server identity key generation to succeed")

		_, serverEphemeralPublicKey, ephemeralOK := common.generateKeyExchangeKeyPair()
		assert(ephemeralOK, "expected server ephemeral key generation to succeed")

		sessionID, sessionIDOK := common.generateSessionID()
		assert(sessionIDOK, "expected session ID generation to succeed")

		serverHelloBytes, serverHelloOK := buildServerHelloPacketBytes(
			transport,
			serverIdentityPrivateKey,
			serverIdentityPublicKey,
			serverEphemeralPublicKey,
			sessionID,
		)
		assert(serverHelloOK, "expected ServerHello packet encoding to succeed")
		defer delete(serverHelloBytes)

		_, serverHelloHandleOK := ClientServerTransport_handleIncomingPacket(
			transport,
			server,
			bridgeConfig,
			serverHelloBytes,
		)
		assert(serverHelloHandleOK, "expected selected startup bridge to accept ServerHello")

		authChallenge, authChallengeOK := common.generateAuthChallenge()
		assert(authChallengeOK, "expected auth challenge generation to succeed")

		authChallengeBytes, authChallengeBytesOK := common.buildPacketBytes(
			.ServerAuthChallenge,
			common.ServerAuthChallengePayload {
				sessionID = transport.sessionID,
				challenge = authChallenge,
			},
		)
		assert(authChallengeBytesOK, "expected auth challenge packet encoding to succeed")
		defer delete(authChallengeBytes)

		authChallengeResult, authChallengeHandleOK := ClientServerTransport_handleIncomingPacket(
			transport,
			server,
			bridgeConfig,
			authChallengeBytes,
		)
		assert(authChallengeHandleOK, "expected selected startup bridge to accept auth challenge")
		defer if authChallengeResult.hasResponse do delete(authChallengeResult.responsePacketBytes)
		assert(
			authChallengeResult.hasResponse,
			"expected auth challenge handling to emit ClientAuthRequest bytes",
		)

		authSuccessBytes, authSuccessBytesOK := common.buildPacketBytes(
			.ServerAuthSuccess,
			common.ServerAuthSuccessPayload{userId = 77, message = "ok"},
		)
		assert(authSuccessBytesOK, "expected auth success packet encoding to succeed")
		defer delete(authSuccessBytes)

		_, authSuccessHandleOK := ClientServerTransport_handleIncomingPacket(
			transport,
			server,
			bridgeConfig,
			authSuccessBytes,
		)
		assert(authSuccessHandleOK, "expected selected startup bridge to accept auth success")

		return {}
	}
	defer startupAuthBridge = originalBridge

	state := State_initFromConfig(config)

	testing.expect(t, len(state.serverTransports) == 1, "expected a single transport")
	testing.expect(
		t,
		state.serverTransports[0].transport.phase == .Established,
		"expected startup bridge to be able to establish the selected transport",
	)
	testing.expect(
		t,
		state.serverTransports[0].authenticatedUserID == 77,
		"expected startup bridge to capture the authenticated user ID",
	)
}

@(test)
testStateInitFromConfigClearsPendingAuthStateAfterFailureAndDisconnect :: proc(t: ^testing.T) {
	sync.mutex_lock(&startupAuthBridgeTestMutex)
	defer sync.mutex_unlock(&startupAuthBridgeTestMutex)

	config := testConfigWithServers(
		{
			Server {
				id = 55,
				name = "Rejecting Server",
				short_name = getShortServerName("Rejecting Server"),
				host = "localhost",
				port = common.DEFAULT_SERVER_PORT,
			},
		},
	)

	originalBridge := startupAuthBridge
	startupAuthBridge = proc(
		transport: ^ClientServerTransport,
		server: ^Server,
		bridgeConfig: ^Config,
		clientHelloPacketBytes: []u8,
	) -> ClientStartupAuthSession {
		_ = clientHelloPacketBytes

		serverIdentityPrivateKey, serverIdentityPublicKey, identityOK :=
			common.generateIdentityKeyPair()
		assert(identityOK, "expected server identity key generation to succeed")

		_, serverEphemeralPublicKey, ephemeralOK := common.generateKeyExchangeKeyPair()
		assert(ephemeralOK, "expected server ephemeral key generation to succeed")

		sessionID, sessionIDOK := common.generateSessionID()
		assert(sessionIDOK, "expected session ID generation to succeed")

		serverHelloBytes, serverHelloOK := buildServerHelloPacketBytes(
			transport,
			serverIdentityPrivateKey,
			serverIdentityPublicKey,
			serverEphemeralPublicKey,
			sessionID,
		)
		assert(serverHelloOK, "expected ServerHello packet encoding to succeed")
		defer delete(serverHelloBytes)

		_, serverHelloHandleOK := ClientServerTransport_handleIncomingPacket(
			transport,
			server,
			bridgeConfig,
			serverHelloBytes,
		)
		assert(serverHelloHandleOK, "expected selected startup bridge to accept ServerHello")

		authFailureBytes, authFailureBytesOK := common.buildPacketBytes(
			.ServerAuthFailure,
			common.ServerAuthFailurePayload{message = "invalid client auth signature"},
		)
		assert(authFailureBytesOK, "expected auth failure packet encoding to succeed")
		defer delete(authFailureBytes)

		_, authFailureHandleOK := ClientServerTransport_handleIncomingPacket(
			transport,
			server,
			bridgeConfig,
			authFailureBytes,
		)
		assert(!authFailureHandleOK, "expected auth failure to fail the selected transport")

		ClientServerTransport_handleDisconnect(transport)
		return {}
	}
	defer startupAuthBridge = originalBridge

	state := State_initFromConfig(config)
	transport := state.serverTransports[0]

	testing.expect(
		t,
		transport.transport.phase == .Failed,
		"expected transport to remain failed after disconnect",
	)
	testing.expect(t, !transport.pendingKeysReady, "expected pending auth keys to be cleared")
	testing.expect(
		t,
		!common.TransportState_canEncrypt(&transport.transport),
		"expected transport to stay non-established",
	)
	testing.expect(
		t,
		transport.authenticatedUserID == 0,
		"expected authenticated user ID to be cleared",
	)
	testing.expect(
		t,
		transport.sessionID == common.SessionID{},
		"expected session ID to be cleared",
	)
	testing.expect(
		t,
		transport.lastError == "invalid client auth signature",
		"expected auth failure message to remain visible after disconnect cleanup",
	)
}

@(test)
testStateInitFromConfigSurfacesSelectedTransportInitFailure :: proc(t: ^testing.T) {
	sync.mutex_lock(&startupAuthBridgeTestMutex)
	defer sync.mutex_unlock(&startupAuthBridgeTestMutex)

	config := Config {
		private_key  = "invalid-private-key",
		public_key   = "invalid-public-key",
		display_name = "Tester",
		servers      = {
			Server {
				id = 33,
				name = "Broken Server",
				short_name = getShortServerName("Broken Server"),
				host = "localhost",
				port = common.DEFAULT_SERVER_PORT,
			},
		},
		friends      = {},
	}

	state := State_initFromConfig(config)

	testing.expect(
		t,
		len(state.serverTransports) == 1,
		"expected selected server failure to stay visible",
	)
	testing.expect(
		t,
		state.selected_transport_index == 0,
		"expected the failed selected server to keep a transport slot",
	)
	testing.expect(
		t,
		state.serverTransports[0].transport.phase == .Failed,
		"expected selected/default transport init failures to surface as failed state",
	)
	testing.expect(
		t,
		state.serverTransports[0].lastError == "client identity keys are missing or invalid",
		"expected selected/default transport init failures to keep a visible error message",
	)
}

@(test)
testClientServerTransportCanEstablishLiveStartupAuthOverENet :: proc(t: ^testing.T) {
	if os.get_env("HAYCHAT_LIVE_STARTUP_AUTH", context.allocator) != "1" {
		return
	}

	sync.mutex_lock(&startupAuthBridgeTestMutex)
	defer sync.mutex_unlock(&startupAuthBridgeTestMutex)

	config := testConfigWithServers(
		{
			Server {
				id = 66,
				name = "Live Server",
				short_name = getShortServerName("Live Server"),
				host = "127.0.0.1",
				port = 12345,
			},
		},
	)

	originalBridge := startupAuthBridge
	startupAuthBridge = startupAuthBridge_real
	defer startupAuthBridge = originalBridge

	state := State_initFromConfig(config)
	transport := &state.serverTransports[0]
	defer ClientServerTransport_handleDisconnect(transport)

	testing.expect(
		t,
		transport.transport.phase == .Established,
		"expected live startup auth bridge to establish the transport",
	)
	testing.expect(
		t,
		transport.authenticatedUserID != 0,
		"expected live startup auth bridge to report a non-zero authenticated user ID",
	)
	testing.expect(
		t,
		len(transport.lastError) == 0,
		"expected live startup auth bridge to succeed without setting an error",
	)
	testing.expect(
		t,
		ClientServerTransport_hasLiveENetSession(transport),
		"expected startup return to retain the live ENet session",
	)

	postAuthProbeSent := ClientServerTransport_sendENetPacket(
		transport.enetHost,
		transport.enetPeer,
		STARTUP_AUTH_CHANNEL_CHAT,
		{0x01},
	)
	testing.expect(
		t,
		postAuthProbeSent,
		"expected retained ENet session to allow a post-auth outbound send",
	)
}
