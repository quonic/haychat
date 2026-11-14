#+feature dynamic-literals
package client

import "../common"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

// A harness over a test state whose output goes to builder. Free with
// testHeadlessHarnessDeinit.
testHeadlessHarness :: proc(builder: ^strings.Builder, serverID: int) -> HeadlessHarness {
	server := Server {
		id         = serverID,
		name       = "Headless",
		short_name = "H",
		host       = "localhost",
		port       = 1,
	}
	return HeadlessHarness {
		state = testUpdateStateForServer(server),
		out = strings.to_writer(builder),
		commands = HEADLESS_COMMANDS[:],
		running = true,
	}
}

testHeadlessHarnessDeinit :: proc(harness: ^HeadlessHarness, builder: ^strings.Builder) {
	HeadlessHarness_deinit(harness)
	strings.builder_destroy(builder)
}

// Returns the output written so far and resets the builder. The result is temp allocated.
testHeadlessTakeOutput :: proc(builder: ^strings.Builder) -> string {
	output := strings.clone(strings.to_string(builder^), context.temp_allocator)
	strings.builder_reset(builder)
	return output
}

testExpectString :: proc(t: ^testing.T, actual, expected: string, what: string) {
	testing.expect(
		t,
		actual == expected,
		fmt.tprintf("expected %s to be\n  %s\ngot\n  %s", what, expected, actual),
	)
}

@(test)
testHeadlessRequestedLooksForTheFlagAnywhere :: proc(t: ^testing.T) {
	testing.expect(t, headlessRequested({"--name", "a", "--headless"}), "expected flag found")
	testing.expect(t, !headlessRequested({"--name", "--headlessly"}), "expected exact match")
	testing.expect(t, !headlessRequested({}), "expected no flag in an empty argument list")
}

@(test)
testHeadlessParseServerAddress :: proc(t: ^testing.T) {
	host, port, ok := headlessParseServerAddress("127.0.0.1:12345")
	testing.expect(t, ok && host == "127.0.0.1" && port == 12345, "expected host and port")
	host, port, ok = headlessParseServerAddress("[::1]:80")
	testing.expect(t, ok && host == "::1" && port == 80, "expected brackets stripped")
	for bad in ([]string{":80", "host:", "host", "host:0", "host:65536", "host:12a", "[]:80"}) {
		_, _, ok = headlessParseServerAddress(bad)
		testing.expect(t, !ok, fmt.tprintf("expected %q to be rejected", bad))
	}
}

@(test)
testHeadlessParseOptions :: proc(t: ^testing.T) {
	options, err := headlessParseOptions(
		{"--headless", "--name", "alice", "--server=example.org:9000", "--config-dir", "/tmp/a"},
	)
	testExpectString(t, err, "", "the parse error")
	testExpectString(t, options.name, "alice", "the name")
	testing.expect(
		t,
		options.hasServer && options.serverHost == "example.org" && options.serverPort == 9000,
		fmt.tprintf("expected example.org:9000, got %v", options),
	)
	testExpectString(t, options.configDir, "/tmp/a", "the config dir")

	_, err = headlessParseOptions({"--headless", "--bogus"})
	testExpectString(t, err, "unknown argument", "the error for an unknown flag")
	_, err = headlessParseOptions({"--name"})
	testExpectString(t, err, "missing value for an option", "the error for a missing value")
	_, err = headlessParseOptions({"--name", "al"})
	testing.expect(t, len(err) > 0, "expected a two-character name to be rejected")
	_, err = headlessParseOptions({"--server", "nowhere"})
	testing.expect(t, len(err) > 0, "expected a server without a port to be rejected")
	_, err = headlessParseOptions({"--config-dir="})
	testing.expect(t, len(err) > 0, "expected an empty config dir to be rejected")

	testing.expect(
		t,
		options.connectTimeoutMS == HEADLESS_DEFAULT_CONNECT_TIMEOUT_MS,
		fmt.tprintf("expected the default connect timeout, got %d", options.connectTimeoutMS),
	)
	options, err = headlessParseOptions({"--connect-timeout", "2500"})
	testing.expect(
		t,
		len(err) == 0 && options.connectTimeoutMS == 2500,
		fmt.tprintf(
			"expected a 2500 ms connect timeout, got %d (%s)",
			options.connectTimeoutMS,
			err,
		),
	)
	for bad in ([]string{"0", "-1", "soon", "600001"}) {
		_, err = headlessParseOptions({"--connect-timeout", bad})
		testing.expect(t, len(err) > 0, fmt.tprintf("expected timeout %q to be rejected", bad))
	}
}

@(test)
testHeadlessApplyOptionsKeepsOneServer :: proc(t: ^testing.T) {
	// A new profile without --server gets no server: there is no built-in default.
	config := testConfigWithServers({})
	defer Config_deinit(&config)
	changed := headlessApplyOptions(&config, HeadlessOptions{name = "alice"})
	testing.expect(t, changed, "expected the name to change the config")
	testExpectString(t, config.display_name, "alice", "the display name")
	testing.expect(
		t,
		len(config.servers) == 0,
		fmt.tprintf("expected no default server, got %d servers", len(config.servers)),
	)
	testing.expect(
		t,
		!headlessApplyOptions(&config, HeadlessOptions{name = "alice"}),
		"expected unchanged options to leave the config unchanged",
	)

	changed = headlessApplyOptions(
		&config,
		HeadlessOptions {
			hasServer = true,
			serverHost = "localhost",
			serverPort = common.DEFAULT_SERVER_PORT,
		},
	)
	testing.expect(
		t,
		changed &&
		len(config.servers) == 1 &&
		config.servers[0].host == "localhost" &&
		config.servers[0].port == common.DEFAULT_SERVER_PORT,
		"expected --server to add the localhost server",
	)

	// A matching entry keeps its pin and becomes the only server.
	delete(config.servers[0].pinned_server_public_key)
	config.servers[0].pinned_server_public_key = strings.clone("pin")
	append(
		&config.servers,
		Server {
			id = 7,
			name = strings.clone("Other"),
			short_name = strings.clone("Ot"),
			host = strings.clone("other"),
			port = 1,
		},
	)
	changed = headlessApplyOptions(
		&config,
		HeadlessOptions{hasServer = true, serverHost = "localhost", serverPort = 12345},
	)
	testing.expect(t, changed, "expected dropping the extra server to change the config")
	testing.expect(
		t,
		len(config.servers) == 1 && config.servers[0].pinned_server_public_key == "pin",
		"expected the matching server to be kept with its pin",
	)

	// A different address replaces the entry, keeps its ID, and drops the old pin.
	serverID := config.servers[0].id
	changed = headlessApplyOptions(
		&config,
		HeadlessOptions{hasServer = true, serverHost = "10.0.0.2", serverPort = 4000},
	)
	testing.expect(t, changed, "expected a new address to change the config")
	server := config.servers[0]
	testing.expect(
		t,
		len(config.servers) == 1 &&
		server.id == serverID &&
		server.host == "10.0.0.2" &&
		server.port == 4000 &&
		server.name == "10.0.0.2:4000" &&
		len(server.pinned_server_public_key) == 0,
		fmt.tprintf("expected a fresh unpinned 10.0.0.2:4000 entry, got %v", server),
	)
}

@(test)
testHeadlessParseCommand :: proc(t: ^testing.T) {
	commands := HEADLESS_COMMANDS[:]

	parsed, err := headlessParseCommand(commands, "  send 1   hello   there  \r\n")
	testing.expect(t, err == .None, fmt.tprintf("expected send to parse, got %v", err))
	testing.expect(t, parsed.argCount == 2, "expected a room ID and the message text")
	testExpectString(t, parsed.args[0], "1", "the send room ID")
	testExpectString(t, parsed.args[1], "hello   there", "the send text")

	parsed, err = headlessParseCommand(commands, "history 3")
	testing.expect(t, err == .None && parsed.argCount == 1, "expected history with one arg")
	parsed, err = headlessParseCommand(commands, "history\t3 40")
	testing.expect(t, err == .None && parsed.argCount == 2, "expected history with a cursor")
	testExpectString(t, parsed.args[1], "40", "the history cursor")
	_, err = headlessParseCommand(commands, "history 3 40 50")
	testing.expect(t, err == .BadArguments, "expected extra history arguments to be rejected")
	_, err = headlessParseCommand(commands, "history")
	testing.expect(t, err == .BadArguments, "expected missing history arguments to be rejected")
	_, err = headlessParseCommand(commands, "send 1")
	testing.expect(t, err == .BadArguments, "expected send without text to be rejected")
	_, err = headlessParseCommand(commands, "status now")
	testing.expect(t, err == .BadArguments, "expected status arguments to be rejected")

	parsed, err = headlessParseCommand(commands, "dance 1")
	testing.expect(t, err == .UnknownCommand, "expected an unknown command")
	testExpectString(t, parsed.name, "dance", "the unknown command name")

	_, err = headlessParseCommand(commands, "   ")
	testing.expect(t, err == .Empty, "expected a blank line to be ignored")
	_, err = headlessParseCommand(commands, "# a comment")
	testing.expect(t, err == .Empty, "expected a comment to be ignored")
}

@(test)
testHeadlessRendersRuntimeEvents :: proc(t: ^testing.T) {
	chat := ClientTransportRuntimeEvent {
		kind           = .RoomChatReceived,
		serverID       = 1,
		roomID         = 1,
		messageID      = 12,
		senderID       = 3,
		senderNickname = "carol",
		timestamp      = "2026-11-05T10:00:00Z",
		message        = "say \"hi\"\n\\o/",
	}
	line, kind, ok := headlessRenderRuntimeEvent(&chat)
	testing.expect(t, ok && kind == .RoomChat, "expected a room_chat event")
	testExpectString(
		t,
		line,
		`{"event":"room_chat","serverID":1,"roomID":1,"messageID":12,"senderID":3,` +
		`"senderNickname":"carol","timestamp":"2026-11-05T10:00:00Z",` +
		`"content":"say \"hi\"\n\\o/"}`,
		"the room_chat JSON",
	)
	delete(line)

	roomList := testRoomListEvent(1, 1)
	defer ClientTransportRuntimeEvent_deinit(&roomList)
	line, kind, ok = headlessRenderRuntimeEvent(&roomList)
	testing.expect(t, ok && kind == .RoomList, "expected a room_list event")
	testExpectString(
		t,
		line,
		`{"event":"room_list","serverID":1,"rooms":[{"id":1,"name":"Room 1","description":"",` +
		`"lastReadMessageId":0,"unreadCount":0,"roomType":0}]}`,
		"the room_list JSON",
	)
	delete(line)

	emptyList := ClientTransportRuntimeEvent {
		kind     = .RoomListReceived,
		serverID = 2,
	}
	line, _, _ = headlessRenderRuntimeEvent(&emptyList)
	testExpectString(t, line, `{"event":"room_list","serverID":2,"rooms":[]}`, "an empty list")
	delete(line)

	history := ClientTransportRuntimeEvent {
		kind     = .RoomHistoryReceived,
		serverID = 1,
		roomID   = 4,
		hasOlder = true,
	}
	append(
		&history.messages,
		common.StoredChatMessage {
			id = 9,
			senderId = 2,
			roomId = 4,
			timestamp = strings.clone("t"),
			content = strings.clone("old"),
		},
	)
	defer ClientTransportRuntimeEvent_deinit(&history)
	line, kind, ok = headlessRenderRuntimeEvent(&history)
	testing.expect(t, ok && kind == .RoomHistory, "expected a room_history event")
	testExpectString(
		t,
		line,
		`{"event":"room_history","serverID":1,"roomID":4,"hasOlder":true,` +
		`"messages":[{"id":9,"senderID":2,"senderNickname":"","timestamp":"t",` +
		`"content":"old"}]}`,
		"the room_history JSON",
	)
	delete(line)

	protocolError := ClientTransportRuntimeEvent {
		kind     = .ProtocolError,
		serverID = 1,
		message  = "not a member",
	}
	line, kind, ok = headlessRenderRuntimeEvent(&protocolError)
	testing.expect(t, ok && kind == .ProtocolError, "expected a protocol_error event")
	testExpectString(
		t,
		line,
		`{"event":"protocol_error","serverID":1,"message":"not a member"}`,
		"the protocol_error JSON",
	)
	delete(line)

	membership := ClientTransportRuntimeEvent {
		kind     = .RoomMembershipChanged,
		serverID = 1,
		roomID   = 5,
		joined   = true,
	}
	line, _, _ = headlessRenderRuntimeEvent(&membership)
	testExpectString(
		t,
		line,
		`{"event":"room_membership","serverID":1,"roomID":5,"joined":true}`,
		"the room_membership JSON",
	)
	delete(line)

	now := time.tick_now()
	disconnected := ClientTransportRuntimeEvent {
		kind      = .Disconnected,
		serverID  = 1,
		message   = "connection lost",
		retryable = true,
		retryAt   = time.tick_add(now, 900 * time.Millisecond),
	}
	line, kind, ok = headlessRenderRuntimeEvent(&disconnected, {now = now})
	testing.expect(t, ok && kind == .Disconnected, "expected a disconnected event")
	testExpectString(
		t,
		line,
		`{"event":"disconnected","serverID":1,"message":"connection lost","retryInMS":900}`,
		"the disconnected JSON",
	)
	delete(line)

	connecting := ClientTransportRuntimeEvent {
		kind     = .Connecting,
		serverID = 1,
	}
	line, kind, ok = headlessRenderRuntimeEvent(&connecting, {attempt = 3})
	testing.expect(t, ok && kind == .Connecting, "expected a connecting event")
	testExpectString(
		t,
		line,
		`{"event":"connecting","serverID":1,"attempt":3}`,
		"the connecting JSON",
	)
	delete(line)

	connected := ClientTransportRuntimeEvent {
		kind     = .Connected,
		serverID = 1,
		userID   = 3,
		nickname = "alice-1",
	}
	line, kind, ok = headlessRenderRuntimeEvent(&connected)
	testing.expect(t, ok && kind == .Connected, "expected a connected event")
	testExpectString(
		t,
		line,
		`{"event":"connected","serverID":1,"userID":3,"nickname":"alice-1","isAdmin":false,` +
		`"nicknameLocked":false}`,
		"the connected JSON",
	)
	delete(line)
	connected.isAdmin = true
	line, kind, ok = headlessRenderRuntimeEvent(&connected)
	testExpectString(
		t,
		line,
		`{"event":"connected","serverID":1,"userID":3,"nickname":"alice-1","isAdmin":true,` +
		`"nicknameLocked":false}`,
		"the connected JSON for an admin",
	)
	delete(line)

	// A retried failure says when the next attempt starts.
	timedOut := ClientTransportRuntimeEvent {
		kind        = .ConnectFailed,
		serverID    = 1,
		message     = "timed out connecting to the server",
		failureKind = .Unreachable,
		retryable   = true,
		retryAt     = time.tick_add(now, 2 * time.Second),
	}
	line, kind, ok = headlessRenderRuntimeEvent(&timedOut, {now = now})
	testing.expect(t, ok && kind == .ConnectFailed, "expected a connect_failed event")
	testExpectString(
		t,
		line,
		`{"event":"connect_failed","serverID":1,"message":"timed out connecting to the server",` +
		`"detail":"timed out connecting to the server","failure":"Unreachable",` +
		`"retryable":true,"retryInMS":2000}`,
		"the retryable connect_failed JSON",
	)
	delete(line)

	// A failure that stops retrying carries the explanation the GUI shows.
	nameTaken := ClientTransportRuntimeEvent {
		kind        = .ConnectFailed,
		serverID    = 1,
		message     = SERVER_IDENTITY_UNAVAILABLE_MESSAGE,
		failureKind = .NameUnavailable,
	}
	line, kind, ok = headlessRenderRuntimeEvent(&nameTaken, {displayName = "alice"})
	testing.expect(t, ok && kind == .ConnectFailed, "expected a connect_failed event")
	testExpectString(
		t,
		line,
		`{"event":"connect_failed","serverID":1,"message":"The name alice is already in use on ` +
		`this server (or bound to another device's key). Choose another name in Settings.",` +
		`"detail":"user identity is unavailable","failure":"NameUnavailable",` +
		`"retryable":false,"retryInMS":0}`,
		"the permanent connect_failed JSON",
	)
	delete(line)

	none := ClientTransportRuntimeEvent{}
	_, _, ok = headlessRenderRuntimeEvent(&none)
	testing.expect(t, !ok, "expected .None events to stay unreported")
}

@(test)
testHeadlessEventKindNamesRoundTrip :: proc(t: ^testing.T) {
	for name, kind in HEADLESS_EVENT_NAMES {
		parsed, ok := headlessEventKindFromName(name)
		testing.expect(t, ok && parsed == kind, fmt.tprintf("expected %q to map back", name))
	}
	_, ok := headlessEventKindFromName("room-chat")
	testing.expect(t, !ok, "expected an unknown event name to be rejected")
}

@(test)
testHeadlessPrintsEventsBeforeApplyingThem :: proc(t: ^testing.T) {
	builder := strings.builder_make()
	harness := testHeadlessHarness(&builder, 801)
	defer testHeadlessHarnessDeinit(&harness, &builder)

	roomList := testRoomListEvent(801, 1, 2)
	headlessHandleRuntimeEvent(&harness, &roomList)
	ClientTransportRuntimeEvent_deinit(&roomList)
	testExpectString(
		t,
		testHeadlessTakeOutput(&builder),
		`{"event":"room_list","serverID":801,"rooms":[{"id":1,"name":"Room 1","description":"",` +
		`"lastReadMessageId":0,"unreadCount":0,"roomType":0},` +
		`{"id":2,"name":"Room 2","description":"","lastReadMessageId":0,"unreadCount":0,` +
		`"roomType":0}]}` +
		"\n",
		"the printed room list",
	)
	testing.expect(
		t,
		harness.pendingEvents[.RoomList] == 1,
		"expected the room list to be counted for wait",
	)
	cache := State_serverRoomCache(&harness.state, 801)
	testing.expect(
		t,
		cache.roomsLoaded && len(cache.rooms) == 2,
		"expected the room list to be applied to State after printing",
	)

	headlessHandleLine(&harness, "rooms")
	testExpectString(
		t,
		testHeadlessTakeOutput(&builder),
		`{"ok":true,"cmd":"rooms","serverID":801,"loaded":true,"loading":false,"rooms":[` +
		`{"id":1,"name":"Room 1","description":"","lastReadMessageId":0,"unreadCount":0,` +
		`"roomType":0},` +
		`{"id":2,"name":"Room 2","description":"","lastReadMessageId":0,"unreadCount":0,` +
		`"roomType":0}]}` +
		"\n",
		"the rooms result",
	)
}

@(test)
testHeadlessCommandResults :: proc(t: ^testing.T) {
	// `send` must go through the real transport, but other tests swap the room chat send
	// bridge for a stub while they run, so hold their lock.
	sync.mutex_lock(&roomChatSendBridgeTestMutex)
	defer sync.mutex_unlock(&roomChatSendBridgeTestMutex)
	builder := strings.builder_make()
	harness := testHeadlessHarness(&builder, 802)
	defer testHeadlessHarnessDeinit(&harness, &builder)

	headlessHandleLine(&harness, "dance")
	testExpectString(
		t,
		testHeadlessTakeOutput(&builder),
		`{"ok":false,"cmd":"dance","error":"unknown command; send ` + "`help`" +
		` for the list"}` +
		"\n",
		"the unknown command result",
	)

	headlessHandleLine(&harness, "send 1")
	testExpectString(
		t,
		testHeadlessTakeOutput(&builder),
		`{"ok":false,"cmd":"send","error":"usage: send ROOM_ID TEXT..."}` + "\n",
		"the usage error",
	)

	headlessHandleLine(&harness, "# nothing")
	testExpectString(t, testHeadlessTakeOutput(&builder), "", "the output for a comment")

	// No worker runs here, so a pending event is the only way wait can succeed.
	headlessRecordEvent(&harness, .Connected)
	headlessHandleLine(&harness, "wait connected 0")
	output := testHeadlessTakeOutput(&builder)
	testing.expect(
		t,
		strings.has_prefix(output, `{"ok":true,"cmd":"wait","event":"connected","waitedMS":`),
		fmt.tprintf("expected a successful wait, got %s", output),
	)
	testing.expect(t, harness.pendingEvents[.Connected] == 0, "expected wait to consume it")

	headlessHandleLine(&harness, "wait connected 0")
	testExpectString(
		t,
		testHeadlessTakeOutput(&builder),
		`{"ok":false,"cmd":"wait","error":"timed out after 0 ms waiting for connected"}` + "\n",
		"the wait timeout",
	)

	headlessHandleLine(&harness, "wait nothing")
	output = testHeadlessTakeOutput(&builder)
	testing.expect(
		t,
		strings.has_prefix(output, `{"ok":false,"cmd":"wait","error":"unknown event kind`),
		fmt.tprintf("expected an unknown event kind error, got %s", output),
	)

	headlessHandleLine(&harness, "sleep 0")
	testExpectString(
		t,
		testHeadlessTakeOutput(&builder),
		`{"ok":true,"cmd":"sleep","ms":0}` + "\n",
		"the sleep result",
	)

	// The test transport has no live session, so sending fails and the draft is cleared.
	headlessHandleLine(&harness, "send 1 hello")
	output = testHeadlessTakeOutput(&builder)
	testing.expect(
		t,
		strings.has_prefix(output, `{"ok":false,"cmd":"send","error":`),
		fmt.tprintf("expected a send failure without a live session, got %s", output),
	)
	testing.expect(
		t,
		len(State_selectedRoomDraft(&harness.state)) == 0,
		"expected a failed send to leave no draft behind",
	)

	// No worker runs, so the queued connection never leaves "connecting".
	headlessHandleLine(&harness, "status")
	output = testHeadlessTakeOutput(&builder)
	testing.expect(
		t,
		strings.has_prefix(
			output,
			`{"ok":true,"cmd":"status","connection":"connecting","connected":false,` +
			`"retryInMS":0,"serverID":802,"server":"localhost:1",`,
		),
		fmt.tprintf("expected a connecting status, got %s", output),
	)

	headlessHandleLine(&harness, "reconnect")
	testExpectString(
		t,
		testHeadlessTakeOutput(&builder),
		`{"ok":true,"cmd":"reconnect","serverID":802}` + "\n",
		"the reconnect result",
	)

	headlessHandleLine(&harness, "help")
	output = testHeadlessTakeOutput(&builder)
	testing.expect(
		t,
		strings.contains(output, `{"usage":"send ROOM_ID TEXT...",`) &&
		strings.contains(output, `"room_chat"`),
		fmt.tprintf("expected help to list commands and events, got %s", output),
	)

	headlessHandleLine(&harness, "quit")
	testExpectString(
		t,
		testHeadlessTakeOutput(&builder),
		`{"ok":true,"cmd":"quit"}` + "\n",
		"the quit result",
	)
	testing.expect(t, !harness.running, "expected quit to stop the harness")
}

@(test)
testHeadlessInputQueueKeepsOrderUntilClosed :: proc(t: ^testing.T) {
	input: HeadlessInput
	defer HeadlessInput_deinit(&input)

	HeadlessInput_push(&input, strings.clone("status"))
	HeadlessInput_push(&input, strings.clone("quit"))
	HeadlessInput_close(&input)

	line, ok, closed := HeadlessInput_pop(&input)
	testing.expect(t, ok && !closed && line == "status", "expected the first line first")
	delete(line)
	// A line still queued at EOF must be handled before the harness sees the close.
	line, ok, closed = HeadlessInput_pop(&input)
	testing.expect(t, ok && !closed && line == "quit", "expected the queued line before EOF")
	delete(line)
	_, ok, closed = HeadlessInput_pop(&input)
	testing.expect(t, !ok && closed, "expected EOF once the queue is empty")

	HeadlessInput_push(&input, strings.clone("left over"))
}

// The worker's lifecycle events for one server, as the harness sees them.
@(test)
testHeadlessCountsConnectAttemptsUntilConnected :: proc(t: ^testing.T) {
	builder := strings.builder_make()
	harness := testHeadlessHarness(&builder, 803)
	defer testHeadlessHarnessDeinit(&harness, &builder)

	connecting := ClientTransportRuntimeEvent {
		kind     = .Connecting,
		serverID = 803,
	}
	headlessHandleRuntimeEvent(&harness, &connecting)
	headlessHandleRuntimeEvent(&harness, &connecting)
	connected := ClientTransportRuntimeEvent {
		kind     = .Connected,
		serverID = 803,
		userID   = 4,
		nickname = strings.clone("dora"),
	}
	headlessHandleRuntimeEvent(&harness, &connected)
	ClientTransportRuntimeEvent_deinit(&connected)
	headlessHandleRuntimeEvent(&harness, &connecting)
	testExpectString(
		t,
		testHeadlessTakeOutput(&builder),
		`{"event":"connecting","serverID":803,"attempt":1}` + "\n" +
		`{"event":"connecting","serverID":803,"attempt":2}` + "\n" +
		`{"event":"connected","serverID":803,"userID":4,"nickname":"dora","isAdmin":false,` +
		`"nicknameLocked":false}` +
		"\n" +
		`{"event":"connecting","serverID":803,"attempt":1}` + "\n",
		"the lifecycle lines",
	)
	testing.expect(
		t,
		harness.pendingEvents[.Connecting] == 3 && harness.pendingEvents[.Connected] == 1,
		"expected lifecycle events to be counted for wait",
	)

	// Status reads State's mirror, which the applied events keep up to date.
	connectedAgain := ClientTransportRuntimeEvent {
		kind     = .Connected,
		serverID = 803,
		userID   = 4,
		nickname = strings.clone("dora"),
	}
	headlessHandleRuntimeEvent(&harness, &connectedAgain)
	ClientTransportRuntimeEvent_deinit(&connectedAgain)
	_ = testHeadlessTakeOutput(&builder)
	headlessHandleLine(&harness, "status")
	output := testHeadlessTakeOutput(&builder)
	testing.expect(
		t,
		strings.has_prefix(
			output,
			`{"ok":true,"cmd":"status","connection":"connected","connected":true,` +
			`"retryInMS":0,"serverID":803,"server":"localhost:1","userID":4,"nickname":"dora",`,
		),
		fmt.tprintf("expected a connected status, got %s", output),
	)
}

@(test)
testHeadlessConnectFailsWithoutAServer :: proc(t: ^testing.T) {
	builder := strings.builder_make()
	harness := HeadlessHarness {
		out      = strings.to_writer(&builder),
		commands = HEADLESS_COMMANDS[:],
		running  = true,
	}
	defer testHeadlessHarnessDeinit(&harness, &builder)
	config := testConfigWithServers({})
	defer Config_deinit(&config)

	connected := headlessConnectAndWait(&harness, config, time.Second)
	testing.expect(t, !connected, "expected connecting without a server to fail")
	testExpectString(
		t,
		testHeadlessTakeOutput(&builder),
		`{"event":"connect_failed","serverID":0,"message":"no server is configured",` +
		`"detail":"","failure":"NoServer","retryable":false,"retryInMS":0}` +
		"\n",
		"the no-server failure",
	)
	testing.expect(t, harness.state.networkWorker == nil, "expected no worker without a server")
}

// A real ENet attempt to a closed local port: the worker reports the attempt, and the harness
// gives up when its own timeout passes (well before ENet's 5 s connect timeout).
@(test)
testHeadlessConnectTimesOutWhileTheServerIsUnreachable :: proc(t: ^testing.T) {
	builder := strings.builder_make()
	harness := HeadlessHarness {
		out      = strings.to_writer(&builder),
		commands = HEADLESS_COMMANDS[:],
		running  = true,
	}
	defer testHeadlessHarnessDeinit(&harness, &builder)
	config := testConfigWithServers(
		{Server{id = 804, name = "Closed", host = "127.0.0.1", port = 12399}},
	)
	defer Config_deinit(&config)

	connected := headlessConnectAndWait(&harness, config, 300 * time.Millisecond)
	testing.expect(t, !connected, "expected the connect to time out")
	output := testHeadlessTakeOutput(&builder)
	testing.expect(
		t,
		strings.has_prefix(output, `{"event":"connecting","serverID":804,"attempt":1}` + "\n"),
		fmt.tprintf("expected a connecting line first, got %s", output),
	)
	lastLine := strings.trim_right(output, "\n")
	lastLine = lastLine[strings.last_index_byte(lastLine, '\n') + 1:]
	// detail is the last attempt's reason, if one already failed; it is usually empty here.
	testing.expect(
		t,
		strings.has_prefix(
			lastLine,
			`{"event":"connect_failed","serverID":804,"message":"timed out after 300 ms ` +
			`connecting to 127.0.0.1:12399","detail":`,
		) &&
		strings.has_suffix(lastLine, `"failure":"Timeout","retryable":false,"retryInMS":0}`),
		fmt.tprintf("expected a timeout failure last, got %s", output),
	)
	testing.expect(
		t,
		harness.pendingEvents[.ConnectFailed] == 1,
		"expected the timeout to be counted for wait",
	)
}

@(test)
testHeadlessRendersDirectMessageEvents :: proc(t: ^testing.T) {
	direct := ClientTransportRuntimeEvent {
		kind = .DirectMessageReceived,
		serverID = 1,
		directMessage = {
			id = 12,
			senderId = 3,
			senderNickname = "alice",
			recipientId = 4,
			recipientNickname = "bob",
			timestamp = "t",
			content = "hi bob",
		},
	}
	line, kind, ok := headlessRenderRuntimeEvent(&direct)
	testing.expect(t, ok && kind == .DirectMessage, "expected a direct_message event")
	testExpectString(
		t,
		line,
		`{"event":"direct_message","serverID":1,"id":12,"senderID":3,"senderNickname":"alice",` +
		`"recipientID":4,"recipientNickname":"bob","timestamp":"t","content":"hi bob"}`,
		"the direct_message JSON",
	)
	delete(line)

	history := ClientTransportRuntimeEvent {
		kind       = .DirectHistoryReceived,
		serverID   = 1,
		peerUserID = 4,
		hasOlder   = true,
	}
	append(
		&history.directMessages,
		common.StoredDirectMessage {
			id = 9,
			senderId = 4,
			senderNickname = strings.clone("bob"),
			recipientId = 3,
			recipientNickname = strings.clone("alice"),
			timestamp = strings.clone("t"),
			content = strings.clone("old"),
		},
	)
	defer ClientTransportRuntimeEvent_deinit(&history)
	line, kind, ok = headlessRenderRuntimeEvent(&history)
	testing.expect(t, ok && kind == .DirectHistory, "expected a direct_history event")
	testExpectString(
		t,
		line,
		`{"event":"direct_history","serverID":1,"peerUserID":4,"hasOlder":true,"messages":[` +
		`{"id":9,"senderID":4,"senderNickname":"bob","recipientID":3,` +
		`"recipientNickname":"alice","timestamp":"t","content":"old"}]}`,
		"the direct_history JSON",
	)
	delete(line)

	users := ClientTransportRuntimeEvent {
		kind     = .UserListReceived,
		serverID = 1,
	}
	append(&users.users, common.UserSummary{id = 4, nickname = strings.clone("bob")})
	defer ClientTransportRuntimeEvent_deinit(&users)
	line, kind, ok = headlessRenderRuntimeEvent(&users)
	testing.expect(t, ok && kind == .UserList, "expected a user_list event")
	testExpectString(
		t,
		line,
		`{"event":"user_list","serverID":1,"users":[{"id":4,"nickname":"bob","isOnline":false,` +
		`"isAdmin":false,"isBanned":false}]}`,
		"the user_list JSON",
	)
	delete(line)

	conversations := ClientTransportRuntimeEvent {
		kind     = .DirectConversationsReceived,
		serverID = 1,
	}
	append(
		&conversations.conversations,
		common.DirectConversationSummary {
			peerUserId = 4,
			peerNickname = strings.clone("bob"),
			lastMessageID = 12,
			lastSenderId = 3,
			lastTimestamp = strings.clone("t"),
			lastContent = strings.clone("hi bob"),
		},
	)
	defer ClientTransportRuntimeEvent_deinit(&conversations)
	line, kind, ok = headlessRenderRuntimeEvent(&conversations)
	testing.expect(t, ok && kind == .Conversations, "expected a conversations event")
	testExpectString(
		t,
		line,
		`{"event":"conversations","serverID":1,"conversations":[{"peerUserID":4,` +
		`"peerNickname":"bob","lastMessageID":12,"lastSenderID":3,"lastTimestamp":"t",` +
		`"lastContent":"hi bob","lastReadMessageId":0,"unreadCount":0}]}`,
		"the conversations JSON",
	)
	delete(line)

	presence := ClientTransportRuntimeEvent {
		kind = .UserPresenceChanged,
		serverID = 1,
		user = {id = 4, nickname = "bob", isOnline = true},
	}
	line, kind, ok = headlessRenderRuntimeEvent(&presence)
	testing.expect(t, ok && kind == .Presence, "expected a presence event")
	testExpectString(
		t,
		line,
		`{"event":"presence","serverID":1,"userID":4,"nickname":"bob","isOnline":true}`,
		"the presence JSON",
	)
	delete(line)
}

@(test)
testHeadlessDirectMessageCommands :: proc(t: ^testing.T) {
	// Another test swaps the send bridge for a stub; this one needs the real transport.
	sync.mutex_lock(&directMessageSendBridgeTestMutex)
	defer sync.mutex_unlock(&directMessageSendBridgeTestMutex)
	builder := strings.builder_make()
	harness := testHeadlessHarness(&builder, 803)
	defer testHeadlessHarnessDeinit(&harness, &builder)
	testApplyConnected(&harness.state, 803, 3)
	testApplyUserList(
		&harness.state,
		803,
		{id = 3, nickname = "alice", isOnline = true},
		{id = 4, nickname = "bob"},
	)

	headlessHandleLine(&harness, "users")
	testExpectString(
		t,
		testHeadlessTakeOutput(&builder),
		`{"ok":true,"cmd":"users","serverID":803,"loaded":true,"loading":false,"users":[` +
		`{"id":3,"nickname":"alice","isOnline":true,"lastReadMessageId":0,"unreadCount":0,` +
		`"isAdmin":false,"isBanned":false},` +
		`{"id":4,"nickname":"bob","isOnline":false,"lastReadMessageId":0,"unreadCount":0,` +
		`"isAdmin":false,"isBanned":false}]}` +
		"\n",
		"the users result",
	)

	// The test transport has no live session, so the list request fails and stays unloaded.
	headlessHandleLine(&harness, "conversations")
	testExpectString(
		t,
		testHeadlessTakeOutput(&builder),
		`{"ok":true,"cmd":"conversations","serverID":803,"loaded":false,"loading":false,` +
		`"conversations":[]}` +
		"\n",
		"the conversations result",
	)

	headlessHandleLine(&harness, "dm 4")
	testExpectString(
		t,
		testHeadlessTakeOutput(&builder),
		`{"ok":false,"cmd":"dm","error":"usage: dm USER_ID TEXT..."}` + "\n",
		"the dm usage error",
	)

	headlessHandleLine(&harness, "dm 4 hello bob")
	output := testHeadlessTakeOutput(&builder)
	testing.expect(
		t,
		strings.has_prefix(output, `{"ok":false,"cmd":"dm","error":`),
		fmt.tprintf("expected a dm failure without a live session, got %s", output),
	)
	testing.expect(
		t,
		len(testDirectCache(&harness.state, 803, 4).draft) == 0,
		"expected a failed dm to leave no draft behind",
	)

	headlessHandleLine(&harness, "dm-history x")
	testExpectString(
		t,
		testHeadlessTakeOutput(&builder),
		`{"ok":false,"cmd":"dm-history","error":"usage: dm-history USER_ID ` +
		`[BEFORE_MESSAGE_ID]"}` +
		"\n",
		"the dm-history usage error",
	)

	headlessHandleLine(&harness, "dm-history 4 10")
	output = testHeadlessTakeOutput(&builder)
	testing.expect(
		t,
		strings.has_prefix(output, `{"ok":false,"cmd":"dm-history","error":`),
		fmt.tprintf("expected a dm-history failure without a live session, got %s", output),
	)

	headlessHandleLine(&harness, "help")
	output = testHeadlessTakeOutput(&builder)
	testing.expect(
		t,
		strings.contains(output, `{"usage":"dm USER_ID TEXT...",`) &&
		strings.contains(output, `"direct_message"`) &&
		strings.contains(output, `"presence"`),
		fmt.tprintf("expected help to list the DM commands and events, got %s", output),
	)
}

@(test)
testHeadlessRendersVoiceEvents :: proc(t: ^testing.T) {
	participants := ClientTransportRuntimeEvent {
		kind                 = .VoiceParticipants,
		serverID             = 1,
		roomID               = 2,
		voiceRecipientJoined = true,
	}
	append(
		&participants.voiceParticipants,
		common.VoiceParticipant{userId = 3, nickname = strings.clone("alice"), muted = true},
		common.VoiceParticipant{userId = 4, nickname = strings.clone("bob"), deafened = true},
	)
	defer ClientTransportRuntimeEvent_deinit(&participants)
	line, kind, ok := headlessRenderRuntimeEvent(&participants)
	testing.expect(t, ok && kind == .VoiceParticipants, "expected a voice_participants event")
	testExpectString(
		t,
		line,
		`{"event":"voice_participants","serverID":1,"roomID":2,"recipientJoined":true,` +
		`"participants":[` +
		`{"userID":3,"nickname":"alice","muted":true,"deafened":false},` +
		`{"userID":4,"nickname":"bob","muted":false,"deafened":true}]}`,
		"the voice_participants JSON",
	)
	delete(line)

	empty := ClientTransportRuntimeEvent {
		kind     = .VoiceParticipants,
		serverID = 1,
		roomID   = 2,
	}
	line, _, _ = headlessRenderRuntimeEvent(&empty)
	testExpectString(
		t,
		line,
		`{"event":"voice_participants","serverID":1,"roomID":2,"recipientJoined":false,` +
		`"participants":[]}`,
		"an empty participant list",
	)
	delete(line)

	rejected := ClientTransportRuntimeEvent {
		kind     = .VoiceJoinRejected,
		serverID = 1,
		roomID   = 2,
		message  = "voice room is full",
	}
	line, kind, ok = headlessRenderRuntimeEvent(&rejected)
	testing.expect(t, ok && kind == .VoiceJoinRejected, "expected a voice_join_rejected event")
	testExpectString(
		t,
		line,
		`{"event":"voice_join_rejected","serverID":1,"roomID":2,"reason":"voice room is full"}`,
		"the voice_join_rejected JSON",
	)
	delete(line)

	left := ClientTransportRuntimeEvent {
		kind     = .VoiceLeft,
		serverID = 1,
		roomID   = 2,
		message  = "the room was deleted",
	}
	line, kind, ok = headlessRenderRuntimeEvent(&left)
	testing.expect(t, ok && kind == .VoiceLeft, "expected a voice_left event")
	testExpectString(
		t,
		line,
		`{"event":"voice_left","serverID":1,"roomID":2,"reason":"the room was deleted"}`,
		"the voice_left JSON",
	)
	delete(line)
	testing.expect(
		t,
		HEADLESS_EVENT_NAMES[.VoiceParticipants] == "voice_participants" &&
		HEADLESS_EVENT_NAMES[.VoiceJoinRejected] == "voice_join_rejected" &&
		HEADLESS_EVENT_NAMES[.VoiceLeft] == "voice_left",
		"expected the voice event names H7 waits on",
	)
}
