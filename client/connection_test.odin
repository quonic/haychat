#+feature dynamic-literals
package client

import "../common"
import "core:strings"
import "core:testing"
import "core:time"

@(test)
testReconnectDelayDoublesUpToTheCap :: proc(t: ^testing.T) {
	cases := []struct {
		attempts: int,
		expected: time.Duration,
	} {
		{0, 1 * time.Second},
		{1, 1 * time.Second},
		{2, 2 * time.Second},
		{3, 4 * time.Second},
		{4, 8 * time.Second},
		{5, 16 * time.Second},
		{6, 30 * time.Second},
		{7, 30 * time.Second},
		{1000, 30 * time.Second},
	}
	for c in cases {
		delay := reconnectDelay(c.attempts, 0)
		testing.expectf(
			t,
			delay == c.expected,
			"expected attempt %d to wait %v without jitter, got %v",
			c.attempts,
			c.expected,
			delay,
		)
	}

	// Jitter only shortens the delay, by at most RECONNECT_JITTER_FRACTION.
	for attempts in 1 ..= 8 {
		base := reconnectDelay(attempts, 0)
		jittered := reconnectDelay(attempts, 0.999)
		testing.expectf(
			t,
			jittered < base && f64(jittered) >= f64(base) * (1 - RECONNECT_JITTER_FRACTION),
			"expected attempt %d's jittered delay %v within 20%% below %v",
			attempts,
			jittered,
			base,
		)
		testing.expect(
			t,
			jittered <= RECONNECT_MAX_DELAY,
			"expected jitter never to exceed the 30 s cap",
		)
	}
}

@(test)
testConnectFailuresAreClassifiedForRetry :: proc(t: ^testing.T) {
	cases := []struct {
		message:   string,
		kind:      ClientConnectFailureKind,
		retryable: bool,
	} {
		{"user identity is unavailable", .NameUnavailable, false},
		{SERVER_KEY_CHANGED_MESSAGE, .ServerKeyChanged, false},
		{"Unsupported protocol version", .ProtocolMismatch, false},
		{"Invalid nickname length", .InvalidName, false},
		{CLIENT_INVALID_NICKNAME_MESSAGE, .InvalidName, false},
		{CLIENT_INVALID_IDENTITY_MESSAGE, .InvalidIdentity, false},
		{"timed out connecting to the server", .Unreachable, true},
		{"could not reach the server", .Unreachable, true},
		{"failed to resolve the server address", .Unreachable, true},
		{"the server closed the connection during sign-in", .Other, true},
		{"invalid client auth signature", .Other, true},
	}
	for c in cases {
		kind := classifyConnectFailure(c.message)
		testing.expectf(
			t,
			kind == c.kind,
			"expected %q to classify as %v, got %v",
			c.message,
			c.kind,
			kind,
		)
		testing.expectf(
			t,
			connectFailureIsRetryable(kind) == c.retryable,
			"expected %q retryable=%v",
			c.message,
			c.retryable,
		)
	}
}

@(test)
testFirstRunIsNeededWithoutANameOrServer :: proc(t: ^testing.T) {
	empty := testConfigWithServers({})
	defer Config_deinit(&empty)
	delete(empty.display_name)
	empty.display_name = ""
	testing.expect(t, State_needsFirstRunSetup(empty), "expected an empty config to need setup")

	state := State_initFromConfig(empty)
	testing.expect(t, state.settingsOpen, "expected an empty config to open the first-run screen")
	testing.expect(t, len(state.serverTransports) == 0, "expected no transports without servers")
	testing.expect(t, state.selected_server_id == 0, "expected no selected server")
	State_closeSettings(&state)
	testing.expect(t, state.settingsOpen, "expected first-run setup to refuse to close")
	State_deinit(&state)

	named := testConfigWithServers({})
	defer Config_deinit(&named)
	testing.expect(t, State_needsFirstRunSetup(named), "expected a config without servers")

	// The documented way for tests and tools to get the old built-in profile.
	Config_fillLocalDefaults(&empty)
	testing.expect(t, !State_needsFirstRunSetup(empty), "expected local defaults to be complete")
	testing.expect(
		t,
		empty.display_name == LOCAL_DEFAULT_DISPLAY_NAME &&
		len(empty.servers) == 1 &&
		empty.servers[0].host == LOCAL_DEFAULT_SERVER_HOST &&
		empty.servers[0].port == common.DEFAULT_SERVER_PORT,
		"expected local defaults to be Test User on localhost:12345",
	)
}

@(test)
testSettingsValidationRejectsUnusableInput :: proc(t: ^testing.T) {
	cases := []struct {
		name, host, port: string,
		requireServer:    bool,
		ok:               bool,
		hasServer:        bool,
		expectedHost:     string,
		expectedPort:     i32,
	} {
		{"alice", "chat.example.com", "12345", true, true, true, "chat.example.com", 12345},
		{"  alice  ", " 10.0.0.2 ", "", true, true, true, "10.0.0.2", common.DEFAULT_SERVER_PORT},
		{"alice", "chat.example.com:4000", "12345", true, true, true, "chat.example.com", 4000},
		{"alice", "", "12345", false, true, false, "", 0},
		{"alice", "", "12345", true, false, false, "", 0},
		{"al", "localhost", "12345", true, false, false, "", 0},
		{"abcdefghijklmnopqrstuvwxyz0123456", "localhost", "1", true, false, false, "", 0},
		{"ali\nce", "localhost", "12345", true, false, false, "", 0},
		{"alice", "bad host", "12345", true, false, false, "", 0},
		{"alice", ":5000", "12345", true, false, false, "", 0},
		{"alice", "::1", "12345", true, true, true, "::1", 12345},
		{"alice", "localhost", "0", true, false, false, "", 0},
		{"alice", "localhost", "65536", true, false, false, "", 0},
		{"alice", "localhost", "port", true, false, false, "", 0},
	}
	for c in cases {
		input, errorMessage := validateSettings(c.name, c.host, c.port, c.requireServer)
		testing.expectf(
			t,
			(len(errorMessage) == 0) == c.ok,
			"expected name=%q host=%q port=%q ok=%v, got error %q",
			c.name,
			c.host,
			c.port,
			c.ok,
			errorMessage,
		)
		if !c.ok {
			continue
		}
		testing.expectf(
			t,
			input.hasServer == c.hasServer &&
			(!c.hasServer || (input.host == c.expectedHost && input.port == c.expectedPort)),
			"expected host=%q port=%q to parse as %q:%d, got %v %q:%d",
			c.host,
			c.port,
			c.expectedHost,
			c.expectedPort,
			input.hasServer,
			input.host,
			input.port,
		)
	}
}

@(test)
testFirstRunSettingsAddServerAndQueueConnect :: proc(t: ^testing.T) {
	config := testConfigWithServers({})
	defer Config_deinit(&config)
	delete(config.display_name)
	config.display_name = ""
	state := State_initFromConfig(config)
	defer State_deinit(&state)

	testSetDraft(&state.settings.displayName, "alice")
	testSetDraft(&state.settings.serverHost, "chat.example.com:4000")
	testing.expect(t, State_applySettings(&state), "expected valid first-run settings to apply")

	testing.expect(t, !state.settingsOpen, "expected a completed first run to show the chat")
	testing.expect(t, state.config.display_name == "alice", "expected the display name saved")
	testing.expect(t, len(state.config.servers) == 1, "expected the server to be added")
	server := state.config.servers[0]
	testing.expect(
		t,
		server.host == "chat.example.com" && server.port == 4000,
		"expected the host:port to be split",
	)
	testing.expect(
		t,
		server.name == "chat.example.com:4000",
		"expected a label from the address",
	)
	testing.expect(t, state.selected_server_id == server.id, "expected the new server selected")
	testing.expect(
		t,
		len(state.serverTransports) == 1 &&
		state.serverTransports[0].connection.status == .Disconnected &&
		state.serverTransports[0].nickname == "alice",
		"expected the new server queued to connect as alice",
	)
	testing.expect(
		t,
		State_serverConnection(&state, server.id).status == .Connecting,
		"expected the new server to show as connecting",
	)
}

@(test)
testSettingsChangesReconnectOnlyWhatChanged :: proc(t: ^testing.T) {
	state := testStateWithServers(
		{
			Server{id = 801, name = "Keep", host = "keep.example", port = 1},
			Server{id = 802, name = "Move", host = "move.example", port = 1},
		},
	)
	defer State_deinit(&state)
	// Markers that survive only if the transport itself is kept.
	state.serverTransports[0].authenticatedUserID = 5
	state.serverTransports[1].authenticatedUserID = 6
	testApplyRoomChat(&state, 801, common.GENERAL_ROOM_ID, 1, 1, "kept")
	testApplyRoomChat(&state, 802, common.GENERAL_ROOM_ID, 1, 1, "dropped")

	State_openSettings(&state)
	State_settingsEditServer(&state, 802)
	testSetDraft(&state.settings.serverHost, "moved.example")
	testing.expect(t, State_applySettings(&state), "expected the address change to apply")

	testing.expect(
		t,
		state.serverTransports[0].authenticatedUserID == 5,
		"expected the unchanged server to keep its session",
	)
	testing.expect(
		t,
		state.serverTransports[1].authenticatedUserID == 0 &&
		state.serverTransports[1].serverHost == "moved.example",
		"expected the moved server to reconnect to its new address",
	)
	testing.expect(
		t,
		State_serverRoomCacheIndex(state, 801) >= 0 && State_serverRoomCacheIndex(state, 802) < 0,
		"expected only the moved server to lose its room cache",
	)

	State_openSettings(&state)
	testSetDraft(&state.settings.displayName, "Renamed")
	testing.expect(t, State_applySettings(&state), "expected the name change to apply")
	for index in 0 ..< len(state.serverTransports) {
		testing.expect(
			t,
			state.serverTransports[index].nickname == "Renamed" &&
			state.serverTransports[index].authenticatedUserID == 0,
			"expected a name change to reconnect every server",
		)
	}

	State_openSettings(&state)
	State_settingsEditServer(&state, 0)
	testSetDraft(&state.settings.serverHost, "keep.example:1")
	testing.expect(t, !State_applySettings(&state), "expected a duplicate server to be refused")
	testing.expect(t, len(state.settings.error) > 0, "expected the duplicate to be explained")
}

@(test)
testRemovingTheLastServerReturnsToFirstRun :: proc(t: ^testing.T) {
	state := testStateWithServers({Server{id = 811, name = "Only", host = "only", port = 1}})
	defer State_deinit(&state)

	State_settingsRemoveServer(&state, 811)
	testing.expect(t, len(state.config.servers) == 0, "expected the server to be removed")
	testing.expect(t, len(state.serverTransports) == 0, "expected its transport to be closed")
	testing.expect(
		t,
		State_serverConnectionIndex(state, 811) < 0,
		"expected its connection status to go",
	)
	testing.expect(t, state.settingsOpen, "expected the first-run screen to open")
	testing.expect(t, state.selected_server_id == 0, "expected nothing selected")
}

@(test)
testConnectionEventsDriveTheBanner :: proc(t: ^testing.T) {
	server := Server {
		id   = 821,
		name = "Banner Server",
		host = "localhost",
		port = 1,
	}
	state := testUpdateStateForServer(server)
	defer State_deinit(&state)
	now := time.tick_now()

	banner := buildConnectionBanner(&state, now)
	testing.expect(
		t,
		banner.tone == .Progress && banner.text == "Connecting to Banner Server…",
		"expected a queued server to show as connecting",
	)

	testApplyConnected(&state, server.id, 9)
	banner = buildConnectionBanner(&state, now)
	testing.expectf(
		t,
		banner.tone == .Quiet && banner.summary == "Connected as Tester" && len(banner.text) == 0,
		"expected a quiet connected status, got %v %q %q",
		banner.tone,
		banner.summary,
		banner.text,
	)

	lost := ClientTransportRuntimeEvent {
		kind      = .Disconnected,
		serverID  = server.id,
		message   = strings.clone("the server closed the connection"),
		retryable = true,
		retryAt   = time.tick_add(now, 3500 * time.Millisecond),
	}
	State_applyRuntimeEvent(&state, &lost)
	ClientTransportRuntimeEvent_deinit(&lost)
	banner = buildConnectionBanner(&state, now)
	testing.expectf(
		t,
		banner.text == "Disconnected from Banner Server. Reconnecting in 4 s" &&
		banner.showRetry &&
		banner.refreshIn == 500 * time.Millisecond,
		"expected a reconnect countdown, got %q (refresh in %v)",
		banner.text,
		banner.refreshIn,
	)
	testing.expect(t, State_selfUserID(&state, server.id) == 0, "expected no user while offline")

	retrying := ClientTransportRuntimeEvent {
		kind     = .Connecting,
		serverID = server.id,
	}
	State_applyRuntimeEvent(&state, &retrying)
	banner = buildConnectionBanner(&state, now)
	testing.expectf(
		t,
		banner.text == "Reconnecting to Banner Server…",
		"expected a retry after a lost session to read as reconnecting, got %q",
		banner.text,
	)

	taken := ClientTransportRuntimeEvent {
		kind        = .ConnectFailed,
		serverID    = server.id,
		message     = strings.clone("user identity is unavailable"),
		failureKind = .NameUnavailable,
	}
	State_applyRuntimeEvent(&state, &taken)
	ClientTransportRuntimeEvent_deinit(&taken)
	banner = buildConnectionBanner(&state, now)
	testing.expect(
		t,
		banner.tone == .Error && banner.showSettings && !banner.showTrustKey,
		"expected a taken name to stop and point at Settings",
	)
	testing.expectf(
		t,
		strings.contains(banner.text, "The name Tester is already in use on this server"),
		"expected a readable explanation, got %q",
		banner.text,
	)
}

@(test)
testChangedServerKeyStopsUntilTrusted :: proc(t: ^testing.T) {
	_, pinnedKey, pinnedOK := common.generateIdentityKeyPair()
	assert(pinnedOK, "expected key generation to succeed")
	pinnedHex := common.identityPublicKeyToHex(pinnedKey)
	defer delete(pinnedHex)
	pinnedFingerprint := common.fingerprintToHex(common.fingerprintIdentityPublicKey(pinnedKey))
	defer delete(pinnedFingerprint)
	server := Server {
		id                        = 831,
		name                      = "Reset Server",
		host                      = "localhost",
		port                      = 1,
		pinned_server_public_key  = pinnedHex,
		pinned_server_fingerprint = pinnedFingerprint,
	}
	state := testStateWithServers({server})
	defer State_deinit(&state)
	transport := &state.serverTransports[0]

	// The server comes back with a different key, as after a dev server reset.
	newPrivate, newPublic, newOK := common.generateIdentityKeyPair()
	assert(newOK, "expected key generation to succeed")
	testing.expect(
		t,
		!testRunHandshake(transport, newPrivate, newPublic, 1),
		"expected the handshake to stop at the changed key",
	)
	testing.expect(
		t,
		transport.lastError == SERVER_KEY_CHANGED_MESSAGE && transport.pendingKeysReady == false,
		"expected no auth request to be signed for a changed key",
	)

	event, _ := ClientServerTransport_connectFailed(transport, time.tick_now(), transport.lastError)
	newHex := common.identityPublicKeyToHex(newPublic)
	defer delete(newHex)
	testing.expect(
		t,
		event.failureKind == .ServerKeyChanged && !event.retryable &&
		event.serverPublicKey == newHex,
		"expected a permanent failure that carries the offered key",
	)
	testing.expect(
		t,
		transport.connection.status == .Failed,
		"expected the transport to stop retrying",
	)
	State_applyRuntimeEvent(&state, &event)
	ClientTransportRuntimeEvent_deinit(&event)

	banner := buildConnectionBanner(&state, time.tick_now())
	testing.expect(
		t,
		banner.showTrustKey && strings.contains(banner.text, "does not match"),
		"expected the banner to explain the key change and offer to trust it",
	)

	State_trustNewServerKey(&state, server.id)
	testing.expect(
		t,
		state.config.servers[0].pinned_server_public_key == newHex &&
		transport.pinnedServerPublicKey == newHex,
		"expected trusting to replace the pin in the config and the transport",
	)
	testing.expect(
		t,
		transport.connection.status == .Disconnected &&
		State_serverConnection(&state, server.id).status == .Connecting,
		"expected trusting to reconnect",
	)
}

@(test)
testConnectedEventStoresAKeyPinnedOnFirstUse :: proc(t: ^testing.T) {
	state := testStateWithServers({Server{id = 841, name = "Fresh", host = "localhost", port = 1}})
	defer State_deinit(&state)

	event := ClientTransportRuntimeEvent {
		kind              = .Connected,
		serverID          = 841,
		userID            = 3,
		nickname          = strings.clone("Tester"),
		serverPublicKey   = strings.clone("aabb"),
		serverFingerprint = strings.clone("ccdd"),
	}
	State_applyRuntimeEvent(&state, &event)
	ClientTransportRuntimeEvent_deinit(&event)

	testing.expect(
		t,
		state.config.servers[0].pinned_server_public_key == "aabb" &&
		state.config.servers[0].pinned_server_fingerprint == "ccdd",
		"expected the pinned key to reach the config",
	)
	testing.expect(t, State_selfUserID(&state, 841) == 3, "expected the signed-in user ID")
}

@(test)
testConnectAttemptTimesOutAndSchedulesARetry :: proc(t: ^testing.T) {
	state := testStateWithServers({Server{id = 851, name = "Closed", host = "127.0.0.1", port = 1}})
	defer State_deinit(&state)
	transport := &state.serverTransports[0]
	start := time.tick_now()

	event, hasEvent := ClientServerTransport_serviceConnection(transport, start)
	testing.expect(t, hasEvent && event.kind == .Connecting, "expected an attempt to start")
	ClientTransportRuntimeEvent_deinit(&event)
	testing.expect(
		t,
		transport.connection.status == .Connecting &&
		ClientServerTransport_hasLiveENetSession(transport),
		"expected an ENet connection in progress",
	)

	late := time.tick_add(start, CONNECT_TIMEOUT + time.Second)
	event, hasEvent = ClientServerTransport_serviceConnection(transport, late)
	defer ClientTransportRuntimeEvent_deinit(&event)
	testing.expect(
		t,
		hasEvent && event.kind == .ConnectFailed && event.retryable &&
		event.failureKind == .Unreachable,
		"expected a timed-out attempt to fail as retryable",
	)
	wait := time.tick_diff(late, event.retryAt)
	testing.expectf(
		t,
		wait <= time.Second && f64(wait) >= f64(time.Second) * (1 - RECONNECT_JITTER_FRACTION),
		"expected the first retry about 1 s later, got %v",
		wait,
	)
	testing.expect(
		t,
		transport.connection.status == .Disconnected &&
		!ClientServerTransport_hasLiveENetSession(transport),
		"expected the failed attempt's session to be released",
	)
	_, early := ClientServerTransport_serviceConnection(transport, late)
	testing.expect(t, !early, "expected no new attempt before the retry time")
}

@(test)
testLostSessionReconnectsWithBackoff :: proc(t: ^testing.T) {
	server := Server {
		id   = 861,
		name = "Lost",
		host = "localhost",
		port = 1,
	}
	config := testConfigWithServers({server})
	defer Config_deinit(&config)
	transport, _, ok := buildEstablishedTransportPair(config.servers[0], config)
	assert(ok, "expected transport pair setup to succeed")
	defer ClientServerTransport_deinit(&transport)
	transport.connection.status = .Established

	// The established transport has no ENet session (as after a failed send tore it down).
	now := time.tick_now()
	event, hasEvent := ClientServerTransport_serviceConnection(&transport, now)
	defer ClientTransportRuntimeEvent_deinit(&event)
	testing.expect(
		t,
		hasEvent && event.kind == .Disconnected && event.retryable,
		"expected a dead session to report a disconnect",
	)
	testing.expect(
		t,
		transport.connection.status == .Disconnected &&
		transport.transport.phase == .Disconnected &&
		transport.authenticatedUserID == 0,
		"expected the session state cleared and a retry scheduled",
	)
	testing.expect(
		t,
		time.tick_diff(now, event.retryAt) <= time.Second,
		"expected the first reconnect within a second",
	)
}

@(test)
testSendingWhileDisconnectedKeepsTheTransport :: proc(t: ^testing.T) {
	state := testStateWithServers({Server{id = 871, name = "Idle", host = "localhost", port = 1}})
	defer State_deinit(&state)
	transport := &state.serverTransports[0]

	sent := ClientServerTransport_sendRoomChatMessage(transport, common.GENERAL_ROOM_ID, "hi")
	testing.expect(t, !sent, "expected no send before connecting")
	testing.expect(
		t,
		transport.lastError == NOT_CONNECTED_MESSAGE &&
		transport.connection.status == .Disconnected,
		"expected a not-connected error without failing the queued connection",
	)
}
