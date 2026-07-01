#+feature dynamic-literals
package client

import "../common"
import "core:testing"

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
testStateInitFromConfigSurfacesSelectedTransportInitFailure :: proc(t: ^testing.T) {
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
