#+feature dynamic-literals
package client

import "../common"
import "core:fmt"
import "core:strings"
import "core:testing"

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
}

@(test)
testHeadlessApplyOptionsKeepsOneServer :: proc(t: ^testing.T) {
	// A new profile without --server gets the default local server.
	config := testConfigWithServers({})
	defer Config_deinit(&config)
	changed := headlessApplyOptions(&config, HeadlessOptions{name = "alice"})
	testing.expect(t, changed, "expected the name and default server to change the config")
	testExpectString(t, config.display_name, "alice", "the display name")
	testing.expect(
		t,
		len(config.servers) == 1 &&
		config.servers[0].host == "localhost" &&
		config.servers[0].port == common.DEFAULT_SERVER_PORT,
		"expected the default localhost server",
	)
	testing.expect(
		t,
		!headlessApplyOptions(&config, HeadlessOptions{name = "alice"}),
		"expected unchanged options to leave the config unchanged",
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
		`{"event":"room_list","serverID":1,"rooms":[{"id":1,"name":"Room 1","description":""}]}`,
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

	disconnected := ClientTransportRuntimeEvent {
		kind     = .Disconnected,
		serverID = 1,
	}
	line, kind, ok = headlessRenderRuntimeEvent(&disconnected)
	testing.expect(t, ok && kind == .Disconnected, "expected a disconnected event")
	testExpectString(t, line, `{"event":"disconnected","serverID":1}`, "the disconnected JSON")
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
		`{"event":"room_list","serverID":801,"rooms":[{"id":1,"name":"Room 1","description":""},` +
		`{"id":2,"name":"Room 2","description":""}]}` +
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
		`{"id":1,"name":"Room 1","description":""},{"id":2,"name":"Room 2","description":""}]}` +
		"\n",
		"the rooms result",
	)
}

@(test)
testHeadlessCommandResults :: proc(t: ^testing.T) {
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

	headlessHandleLine(&harness, "status")
	output = testHeadlessTakeOutput(&builder)
	testing.expect(
		t,
		strings.has_prefix(output, `{"ok":true,"cmd":"status","phase":"Failed","connected":false`),
		fmt.tprintf("expected a disconnected status, got %s", output),
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
