package client

// Headless harness: `client --headless` runs the client without SDL so an agent or a shell
// script can act as a user. It reuses State, the actions, the transport and the network
// worker; only the presentation differs. Commands arrive one per line on stdin, and every
// command result and runtime event leaves as one JSON object per line on stdout. Diagnostics
// go to stderr. See docs/testing-harness.md for the protocol.

import "../common"
import "core:bufio"
import "core:encoding/json"
import "core:fmt"
import "core:io"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

HEADLESS_FLAG :: "--headless"
HEADLESS_EXIT_OK :: 0
HEADLESS_EXIT_ERROR :: 1
HEADLESS_EXIT_CONNECT_FAILED :: 2
HEADLESS_DEFAULT_WAIT_MS :: 5000
// Upper bound for `wait` and `sleep`, so a typo cannot park a scripted client for days.
HEADLESS_MAX_WAIT_MS :: 10 * 60 * 1000
HEADLESS_POLL_INTERVAL :: 5 * time.Millisecond
HEADLESS_MAX_ARGS :: 4
HEADLESS_DISPLAY_NAME_MIN :: 3
HEADLESS_DISPLAY_NAME_MAX :: 32
HEADLESS_USAGE ::
	"usage: client --headless [--name NAME] [--server HOST:PORT] [--config-dir DIR]\n" +
	"  --name NAME          display name (3-32 characters); saved to the profile\n" +
	"  --server HOST:PORT   the profile's only server; saved to the profile\n" +
	"  --config-dir DIR     config root for this profile (like XDG_CONFIG_HOME)\n" +
	"Commands are read from stdin; type `help` for the list."

// ── Options ───────────────────────────────────────────────────────

HeadlessOptions :: struct {
	// All strings are borrowed from the argument list.
	name:       string,
	serverHost: string,
	serverPort: i32,
	hasServer:  bool,
	configDir:  string,
}

headlessRequested :: proc(args: []string) -> bool {
	for arg in args {
		if arg == HEADLESS_FLAG {
			return true
		}
	}
	return false
}

// Splits HOST:PORT at the last colon. Brackets around an IPv6 host are removed. The host is
// borrowed from value.
headlessParseServerAddress :: proc(value: string) -> (host: string, port: i32, ok: bool) {
	separator := strings.last_index_byte(value, ':')
	if separator <= 0 || separator == len(value) - 1 {
		return "", 0, false
	}
	host = value[:separator]
	if len(host) >= 2 && host[0] == '[' && host[len(host) - 1] == ']' {
		host = host[1:len(host) - 1]
	}
	parsedPort, portOK := strconv.parse_int(value[separator + 1:], 10)
	if !portOK || parsedPort < 1 || parsedPort > 65535 || len(host) == 0 {
		return "", 0, false
	}
	return host, i32(parsedPort), true
}

// Parses the arguments after the program name. Returns a static error message on failure.
headlessParseOptions :: proc(args: []string) -> (options: HeadlessOptions, err: string) {
	for index := 0; index < len(args); index += 1 {
		arg := args[index]
		if arg == HEADLESS_FLAG {
			continue
		}
		flag := arg
		value := ""
		hasValue := false
		if equals := strings.index_byte(arg, '='); equals > 0 && strings.has_prefix(arg, "--") {
			flag = arg[:equals]
			value = arg[equals + 1:]
			hasValue = true
		}
		switch flag {
		case "--name", "--server", "--config-dir":
		case:
			return {}, "unknown argument"
		}
		if !hasValue {
			if index + 1 >= len(args) {
				return {}, "missing value for an option"
			}
			index += 1
			value = args[index]
		}
		switch flag {
		case "--name":
			if len(value) < HEADLESS_DISPLAY_NAME_MIN || len(value) > HEADLESS_DISPLAY_NAME_MAX {
				return {}, "--name must be between 3 and 32 characters"
			}
			options.name = value
		case "--server":
			host, port, ok := headlessParseServerAddress(value)
			if !ok {
				return {}, "--server must be HOST:PORT with a port from 1 to 65535"
			}
			options.serverHost = host
			options.serverPort = port
			options.hasServer = true
		case "--config-dir":
			if len(value) == 0 {
				return {}, "--config-dir must not be empty"
			}
			options.configDir = value
		}
	}
	return options, ""
}

// Applies --name and --server to config. A headless profile has exactly one server: the entry
// matching --server is kept with its pinned key, anything else is replaced by a fresh entry
// without a pin. Returns true when config changed and should be saved.
headlessApplyOptions :: proc(config: ^Config, options: HeadlessOptions) -> bool {
	changed := false
	if len(options.name) > 0 && options.name != config.display_name {
		delete(config.display_name)
		config.display_name = strings.clone(options.name)
		changed = true
	}

	host := options.serverHost
	port := options.serverPort
	if !options.hasServer {
		if len(config.servers) > 0 {
			return changed
		}
		// A new profile without --server talks to the default local dev server.
		host = "localhost"
		port = common.DEFAULT_SERVER_PORT
	}

	keepIndex := -1
	for server, index in config.servers {
		if server.host == host && server.port == port {
			keepIndex = index
			break
		}
	}
	if keepIndex == 0 && len(config.servers) == 1 {
		return changed
	}

	kept: Server
	if keepIndex >= 0 {
		kept = config.servers[keepIndex]
		config.servers[keepIndex] = {}
	} else {
		serverID := 1
		if len(config.servers) > 0 {
			serverID = config.servers[0].id
		}
		name := fmt.aprintf("%s:%d", host, port)
		kept = Server {
			id         = serverID,
			name       = name,
			short_name = getShortServerName(name),
			host       = strings.clone(host),
			port       = port,
		}
	}
	for index in 0 ..< len(config.servers) {
		Server_deinit(&config.servers[index])
	}
	clear(&config.servers)
	append(&config.servers, kept)
	return true
}

// Points loadConfig and saveConfig at dir by setting the variable they read the config root
// from. On Linux that is XDG_CONFIG_HOME, so the profile lives in DIR/haychat/config.json.
headlessUseConfigDir :: proc(dir: string) -> bool {
	if err := os.make_directory_all(dir); err != nil && !os.exists(dir) {
		fmt.eprintln("[Error] Failed to create config directory:", dir, err)
		return false
	}
	when ODIN_OS == .Windows {
		key :: "APPDATA"
	} else {
		key :: "XDG_CONFIG_HOME"
	}
	if err := os.set_env(key, dir); err != nil {
		fmt.eprintln("[Error] Failed to set", key, err)
		return false
	}
	return true
}

// ── Event rendering ───────────────────────────────────────────────

// Kinds an agent can `wait` for. Connected and ConnectFailed come from the harness's connect
// step today; when the handshake moves onto the network worker they become runtime events.
HeadlessEventKind :: enum {
	Connected,
	ConnectFailed,
	RoomChat,
	RoomList,
	RoomHistory,
	RoomMembership,
	RoomEdited,
	RoomDeleted,
	ProtocolError,
	Disconnected,
}

HEADLESS_EVENT_NAMES := [HeadlessEventKind]string {
	.Connected      = "connected",
	.ConnectFailed  = "connect_failed",
	.RoomChat       = "room_chat",
	.RoomList       = "room_list",
	.RoomHistory    = "room_history",
	.RoomMembership = "room_membership",
	.RoomEdited     = "room_edited",
	.RoomDeleted    = "room_deleted",
	.ProtocolError  = "protocol_error",
	.Disconnected   = "disconnected",
}

headlessEventKindFromName :: proc(name: string) -> (HeadlessEventKind, bool) {
	for eventName, kind in HEADLESS_EVENT_NAMES {
		if eventName == name {
			return kind, true
		}
	}
	return {}, false
}

HeadlessConnectedJSON :: struct {
	event:    string,
	serverID: int,
	userID:   int,
	nickname: string,
}

HeadlessMessageEventJSON :: struct {
	event:    string,
	serverID: int,
	message:  string,
}

HeadlessRoomChatJSON :: struct {
	event:          string,
	serverID:       int,
	roomID:         int,
	messageID:      int,
	senderID:       int,
	senderNickname: string,
	timestamp:      string,
	content:        string,
}

HeadlessRoomListJSON :: struct {
	event:    string,
	serverID: int,
	rooms:    []common.RoomSummary,
}

HeadlessHistoryMessageJSON :: struct {
	id:             int,
	senderID:       int,
	senderNickname: string,
	timestamp:      string,
	content:        string,
}

HeadlessRoomHistoryJSON :: struct {
	event:    string,
	serverID: int,
	roomID:   int,
	hasOlder: bool,
	messages: []HeadlessHistoryMessageJSON,
}

HeadlessRoomMembershipJSON :: struct {
	event:    string,
	serverID: int,
	roomID:   int,
	joined:   bool,
}

HeadlessRoomEditedJSON :: struct {
	event:       string,
	serverID:    int,
	roomID:      int,
	name:        string,
	description: string,
}

HeadlessRoomEventJSON :: struct {
	event:    string,
	serverID: int,
	roomID:   int,
}

HeadlessServerEventJSON :: struct {
	event:    string,
	serverID: int,
}

// Marshals value as one compact JSON object. The result is allocated with allocator.
headlessMarshal :: proc(value: any, allocator := context.allocator) -> string {
	data, err := json.marshal(value, allocator = allocator)
	if err != nil {
		fmt.eprintln("[Error] Failed to encode JSON output:", err)
		return strings.clone(`{"event":"internal_error"}`, allocator)
	}
	return string(data)
}

// Renders a runtime event as one JSON line without the newline. It reads the event's payload,
// so it must run before State_applyRuntimeEvent moves fields out. ok is false for events that
// are not reported (.None).
headlessRenderRuntimeEvent :: proc(
	event: ^ClientTransportRuntimeEvent,
	allocator := context.allocator,
) -> (
	line: string,
	kind: HeadlessEventKind,
	ok: bool,
) {
	switch event.kind {
	case .None:
		return "", {}, false
	case .RoomChatReceived:
		kind = .RoomChat
		line = headlessMarshal(
			HeadlessRoomChatJSON {
				event = HEADLESS_EVENT_NAMES[kind],
				serverID = event.serverID,
				roomID = event.roomID,
				messageID = event.messageID,
				senderID = event.senderID,
				senderNickname = event.senderNickname,
				timestamp = event.timestamp,
				content = event.message,
			},
			allocator,
		)
	case .RoomListReceived:
		kind = .RoomList
		line = headlessMarshal(
			HeadlessRoomListJSON {
				event = HEADLESS_EVENT_NAMES[kind],
				serverID = event.serverID,
				rooms = event.rooms[:],
			},
			allocator,
		)
	case .RoomHistoryReceived:
		kind = .RoomHistory
		messages := make([]HeadlessHistoryMessageJSON, len(event.messages), allocator)
		defer delete(messages, allocator)
		for message, index in event.messages {
			messages[index] = {
				id             = message.id,
				senderID       = message.senderId,
				senderNickname = message.senderNickname,
				timestamp      = message.timestamp,
				content        = message.content,
			}
		}
		line = headlessMarshal(
			HeadlessRoomHistoryJSON {
				event = HEADLESS_EVENT_NAMES[kind],
				serverID = event.serverID,
				roomID = event.roomID,
				hasOlder = event.hasOlder,
				messages = messages,
			},
			allocator,
		)
	case .RoomMembershipChanged:
		kind = .RoomMembership
		line = headlessMarshal(
			HeadlessRoomMembershipJSON {
				event = HEADLESS_EVENT_NAMES[kind],
				serverID = event.serverID,
				roomID = event.roomID,
				joined = event.joined,
			},
			allocator,
		)
	case .RoomEdited:
		kind = .RoomEdited
		line = headlessMarshal(
			HeadlessRoomEditedJSON {
				event = HEADLESS_EVENT_NAMES[kind],
				serverID = event.serverID,
				roomID = event.roomID,
				name = event.room.name,
				description = event.room.description,
			},
			allocator,
		)
	case .RoomDeleted:
		kind = .RoomDeleted
		line = headlessMarshal(
			HeadlessRoomEventJSON {
				event = HEADLESS_EVENT_NAMES[kind],
				serverID = event.serverID,
				roomID = event.roomID,
			},
			allocator,
		)
	case .ProtocolError:
		kind = .ProtocolError
		line = headlessMarshal(
			HeadlessMessageEventJSON {
				event = HEADLESS_EVENT_NAMES[kind],
				serverID = event.serverID,
				message = event.message,
			},
			allocator,
		)
	case .Disconnected:
		kind = .Disconnected
		line = headlessMarshal(
			HeadlessServerEventJSON{event = HEADLESS_EVENT_NAMES[kind], serverID = event.serverID},
			allocator,
		)
	}
	return line, kind, true
}

// ── Command results ───────────────────────────────────────────────

HeadlessOKJSON :: struct {
	ok:  bool,
	cmd: string,
}

HeadlessErrorJSON :: struct {
	ok:    bool,
	cmd:   string,
	error: string,
}

HeadlessStatusJSON :: struct {
	ok:             bool,
	cmd:            string,
	phase:          string,
	connected:      bool,
	serverID:       int,
	server:         string,
	userID:         int,
	nickname:       string,
	selectedRoomID: int,
	lastError:      string,
}

HeadlessRoomsJSON :: struct {
	ok:       bool,
	cmd:      string,
	serverID: int,
	loaded:   bool,
	loading:  bool,
	rooms:    []common.RoomSummary,
}

HeadlessHistoryJSON :: struct {
	ok:              bool,
	cmd:             string,
	serverID:        int,
	roomID:          int,
	beforeMessageID: int,
}

HeadlessSendJSON :: struct {
	ok:       bool,
	cmd:      string,
	serverID: int,
	roomID:   int,
}

HeadlessWaitJSON :: struct {
	ok:       bool,
	cmd:      string,
	event:    string,
	waitedMS: int,
}

HeadlessSleepJSON :: struct {
	ok:  bool,
	cmd: string,
	ms:  int,
}

HeadlessHelpCommandJSON :: struct {
	usage:   string,
	summary: string,
}

HeadlessHelpJSON :: struct {
	ok:       bool,
	cmd:      string,
	commands: []HeadlessHelpCommandJSON,
	events:   []string,
}

// ── Command table ─────────────────────────────────────────────────

HeadlessCommandProc :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand)

HeadlessCommand :: struct {
	name:         string,
	args:         int, // Required positional arguments
	optionalArgs: int, // Optional positional arguments after the required ones
	// The rest of the line after the required arguments is one more required argument, kept
	// verbatim (inner spaces included). Not combined with optionalArgs.
	takesText:    bool,
	usage:        string,
	summary:      string,
	run:          HeadlessCommandProc,
}

// Every command the harness understands. Adding one is a row here plus its handler, e.g. for
// direct messages (package B): {"users", 0, 0, false, ...}, {"dm", 1, 0, true, "dm USER_ID
// TEXT...", ...} and {"dm-history", 1, 1, false, ...}, plus their event kinds above.
HEADLESS_COMMANDS := [?]HeadlessCommand {
	{"status", 0, 0, false, "status", "connection phase, user, nickname, selected server",
		headlessCommandStatus},
	{"rooms", 0, 0, false, "rooms", "joined rooms from the cache; requests them if not loaded",
		headlessCommandRooms},
	{"history", 1, 1, false, "history ROOM_ID [BEFORE_MESSAGE_ID]",
		"requests a history page; it arrives as a room_history event", headlessCommandHistory},
	{"send", 1, 0, true, "send ROOM_ID TEXT...", "sends the rest of the line to a room",
		headlessCommandSend},
	{"wait", 1, 1, false, "wait EVENT_KIND [TIMEOUT_MS]",
		"waits for an unconsumed event of that kind (default 5000 ms)", headlessCommandWait},
	{"sleep", 1, 0, false, "sleep MS", "keeps servicing the connection for MS milliseconds",
		headlessCommandSleep},
	{"help", 0, 0, false, "help", "lists commands and event kinds", headlessCommandHelp},
	{"quit", 0, 0, false, "quit", "disconnects and exits with code 0", headlessCommandQuit},
}

HeadlessParseError :: enum {
	None,
	Empty, // Blank line or a `#` comment
	UnknownCommand,
	BadArguments,
}

// Arguments are borrowed from the parsed line.
HeadlessParsedCommand :: struct {
	command:  ^HeadlessCommand, // nil unless the command name is known
	name:     string,
	args:     [HEADLESS_MAX_ARGS]string,
	argCount: int,
}

@(private = "file")
isHeadlessSpace :: proc(c: byte) -> bool {
	return c == ' ' || c == '\t'
}

@(private = "file")
headlessNextWord :: proc(rest: ^string) -> string {
	value := strings.trim_left(rest^, " \t")
	end := 0
	for end < len(value) && !isHeadlessSpace(value[end]) {
		end += 1
	}
	rest^ = value[end:]
	return value[:end]
}

headlessParseCommand :: proc(
	commands: []HeadlessCommand,
	line: string,
) -> (
	parsed: HeadlessParsedCommand,
	err: HeadlessParseError,
) {
	rest := strings.trim(line, " \t\r\n")
	if len(rest) == 0 || rest[0] == '#' {
		return parsed, .Empty
	}
	parsed.name = headlessNextWord(&rest)
	for index in 0 ..< len(commands) {
		if commands[index].name == parsed.name {
			parsed.command = &commands[index]
			break
		}
	}
	if parsed.command == nil {
		return parsed, .UnknownCommand
	}
	command := parsed.command
	positional := command.args + command.optionalArgs
	assert(positional + int(command.takesText) <= HEADLESS_MAX_ARGS, "too many command args")
	for parsed.argCount < positional {
		word := headlessNextWord(&rest)
		if len(word) == 0 {
			break
		}
		parsed.args[parsed.argCount] = word
		parsed.argCount += 1
	}
	rest = strings.trim_left(rest, " \t")
	if parsed.argCount < command.args {
		return parsed, .BadArguments
	}
	if command.takesText {
		if len(rest) == 0 {
			return parsed, .BadArguments
		}
		parsed.args[parsed.argCount] = rest
		parsed.argCount += 1
	} else if len(rest) > 0 {
		return parsed, .BadArguments
	}
	return parsed, .None
}

// Parses a non-negative integer argument that must not exceed maxValue.
headlessParseNumber :: proc(value: string, maxValue: int = max(int)) -> (int, bool) {
	parsed, ok := strconv.parse_int(value, 10)
	if !ok || parsed < 0 || parsed > maxValue {
		return 0, false
	}
	return parsed, true
}

// ── Harness ───────────────────────────────────────────────────────

HeadlessHarness :: struct {
	state:         State,
	out:           io.Writer, // JSON lines only
	commands:      []HeadlessCommand,
	// Events that arrived and have not been consumed by `wait` yet, per kind.
	pendingEvents: [HeadlessEventKind]int,
	running:       bool,
}

HeadlessHarness_deinit :: proc(harness: ^HeadlessHarness) {
	State_deinit(&harness.state)
}

// Writes one line followed by a newline in a single write, so lines never interleave.
headlessWriteLine :: proc(harness: ^HeadlessHarness, line: string) {
	buffer := make([]u8, len(line) + 1)
	defer delete(buffer)
	copy(buffer, line)
	buffer[len(line)] = '\n'
	_, _ = io.write(harness.out, buffer)
}

headlessWriteJSON :: proc(harness: ^HeadlessHarness, value: any) {
	line := headlessMarshal(value)
	defer delete(line)
	headlessWriteLine(harness, line)
}

headlessWriteError :: proc(harness: ^HeadlessHarness, cmd: string, message: string) {
	headlessWriteJSON(harness, HeadlessErrorJSON{ok = false, cmd = cmd, error = message})
}

headlessRecordEvent :: proc(harness: ^HeadlessHarness, kind: HeadlessEventKind) {
	harness.pendingEvents[kind] += 1
}

// Prints a runtime event, counts it for `wait`, then applies it to State exactly as the GUI
// does. The caller still owns the event and must deinit it.
headlessHandleRuntimeEvent :: proc(harness: ^HeadlessHarness, event: ^ClientTransportRuntimeEvent) {
	line, kind, ok := headlessRenderRuntimeEvent(event)
	if ok {
		headlessWriteLine(harness, line)
		delete(line)
		headlessRecordEvent(harness, kind)
	}
	State_applyRuntimeEvent(&harness.state, event)
}

headlessDrainEvents :: proc(harness: ^HeadlessHarness) {
	for _ in 0 ..< CHAT_RUNTIME_MAX_EVENTS_PER_FRAME {
		event, hasEvent := ClientNetworkWorker_popEvent(harness.state.networkWorker)
		if !hasEvent {
			return
		}
		headlessHandleRuntimeEvent(harness, &event)
		ClientTransportRuntimeEvent_deinit(&event)
	}
}

headlessHandleLine :: proc(harness: ^HeadlessHarness, line: string) {
	parsed, err := headlessParseCommand(harness.commands, line)
	switch err {
	case .Empty:
	case .UnknownCommand:
		headlessWriteError(harness, parsed.name, "unknown command; send `help` for the list")
	case .BadArguments:
		message := strings.concatenate({"usage: ", parsed.command.usage})
		defer delete(message)
		headlessWriteError(harness, parsed.name, message)
	case .None:
		parsed.command.run(harness, &parsed)
	}
}

// Connects the selected server and blocks until it is connected or has failed, then reports
// the outcome as a `connected` or `connect_failed` event. This is the only place that knows
// how the client connects. Today the handshake runs synchronously inside
// State_initFromConfig and the worker starts afterwards. When the handshake moves onto the
// network worker, this becomes: start the worker, then drain events until a Connected or
// ConnectFailed runtime event arrives (or a timeout passes).
headlessConnectAndWait :: proc(harness: ^HeadlessHarness, config: Config) -> bool {
	startupAuthBridge = startupAuthBridge_real
	harness.state = State_initFromConfig(config)
	harness.state.networkWorker = ClientNetworkWorker_start(harness.state.serverTransports[:])

	transport, ok := State_selectedTransport(&harness.state)
	if !ok {
		headlessWriteJSON(
			harness,
			HeadlessMessageEventJSON {
				event = HEADLESS_EVENT_NAMES[.ConnectFailed],
				message = "no server is configured",
			},
		)
		headlessRecordEvent(harness, .ConnectFailed)
		return false
	}

	ClientNetworkWorker_lock(harness.state.networkWorker)
	defer ClientNetworkWorker_unlock(harness.state.networkWorker)
	if transport.transport.phase == .Established {
		headlessWriteJSON(
			harness,
			HeadlessConnectedJSON {
				event = HEADLESS_EVENT_NAMES[.Connected],
				serverID = transport.serverID,
				userID = transport.authenticatedUserID,
				nickname = transport.nickname,
			},
		)
		headlessRecordEvent(harness, .Connected)
		return true
	}
	message := transport.lastError
	if len(message) == 0 {
		message = "connection failed"
	}
	headlessWriteJSON(
		harness,
		HeadlessMessageEventJSON {
			event = HEADLESS_EVENT_NAMES[.ConnectFailed],
			serverID = transport.serverID,
			message = message,
		},
	)
	headlessRecordEvent(harness, .ConnectFailed)
	return false
}

// Keeps draining network events for duration, so the session stays serviced and every event
// is still printed while a command blocks.
headlessPumpFor :: proc(harness: ^HeadlessHarness, duration: time.Duration) {
	start := time.tick_now()
	for {
		headlessDrainEvents(harness)
		if time.tick_since(start) >= duration {
			return
		}
		time.sleep(HEADLESS_POLL_INTERVAL)
	}
}

// ── Command handlers ──────────────────────────────────────────────

headlessCommandStatus :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	state := &harness.state
	result := HeadlessStatusJSON {
		ok             = true,
		cmd            = command.name,
		phase          = "None",
		serverID       = state.selected_server_id,
		selectedRoomID = state.selected_channel_id,
	}
	for server in state.config.servers {
		if server.id == state.selected_server_id {
			result.server = fmt.tprintf("%s:%d", server.host, server.port)
		}
	}
	if transport, ok := State_selectedTransport(state); ok {
		// The worker updates phase and lastError on disconnect, so read them under its lock.
		ClientNetworkWorker_lock(state.networkWorker)
		result.phase = fmt.tprintf("%v", transport.transport.phase)
		result.connected =
			transport.transport.phase == .Established &&
			ClientServerTransport_hasLiveENetSession(transport)
		result.userID = transport.authenticatedUserID
		result.nickname = strings.clone(transport.nickname, context.temp_allocator)
		result.lastError = strings.clone(transport.lastError, context.temp_allocator)
		ClientNetworkWorker_unlock(state.networkWorker)
	}
	headlessWriteJSON(harness, result)
}

headlessCommandRooms :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	state := &harness.state
	serverID := state.selected_server_id
	cache := State_serverRoomCache(state, serverID)
	if !cache.roomsLoaded && !cache.roomsLoading {
		State_requestRoomList(state, serverID)
		// Requesting can append a server cache, so look it up again.
		cache = State_serverRoomCache(state, serverID)
	}
	headlessWriteJSON(
		harness,
		HeadlessRoomsJSON {
			ok = true,
			cmd = command.name,
			serverID = serverID,
			loaded = cache.roomsLoaded,
			loading = cache.roomsLoading,
			rooms = cache.rooms[:],
		},
	)
}

headlessCommandHistory :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	roomID, roomOK := headlessParseNumber(command.args[0])
	beforeMessageID, beforeOK := 0, true
	if command.argCount > 1 {
		beforeMessageID, beforeOK = headlessParseNumber(command.args[1])
	}
	if !roomOK || roomID == 0 || !beforeOK {
		headlessWriteError(harness, command.name, "usage: " + "history ROOM_ID [BEFORE_MESSAGE_ID]")
		return
	}
	state := &harness.state
	serverID := state.selected_server_id
	roomCache := ServerRoomCache_roomCache(State_serverRoomCache(state, serverID), roomID)
	// An agent asks explicitly, so always send. The GUI's in-flight guard would otherwise
	// swallow the request forever after an error reply, which does not name the room.
	roomCache.isLoadingHistory = false
	State_clearChatStatus(state)
	State_requestRoomHistory(state, serverID, roomID, beforeMessageID)
	roomCache = ServerRoomCache_roomCache(State_serverRoomCache(state, serverID), roomID)
	if !roomCache.isLoadingHistory {
		message := state.chat_status_message
		if len(message) == 0 {
			message = "failed to request room history"
		}
		headlessWriteError(harness, command.name, message)
		return
	}
	headlessWriteJSON(
		harness,
		HeadlessHistoryJSON {
			ok = true,
			cmd = command.name,
			serverID = serverID,
			roomID = roomID,
			beforeMessageID = beforeMessageID,
		},
	)
}

// Sends through State_sendChannelChat, the same action the GUI composer uses: the text goes
// into the room's draft and the room becomes the selected one.
headlessCommandSend :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	roomID, roomOK := headlessParseNumber(command.args[0])
	if !roomOK || roomID == 0 {
		headlessWriteError(harness, command.name, "usage: send ROOM_ID TEXT...")
		return
	}
	state := &harness.state
	state.view_dms = false
	state.selected_channel_id = roomID
	draft := State_selectedRoomDraft(state)
	clear(draft)
	append(draft, ..transmute([]u8)command.args[1])
	State_sendChannelChat(state)

	draft = State_selectedRoomDraft(state)
	if len(draft) > 0 {
		// Leave nothing behind for the next send to the same room.
		clear(draft)
		message := state.chat_status_message
		if len(message) == 0 {
			message = "failed to send room chat message"
		}
		headlessWriteError(harness, command.name, message)
		return
	}
	headlessWriteJSON(
		harness,
		HeadlessSendJSON {
			ok = true,
			cmd = command.name,
			serverID = state.selected_server_id,
			roomID = roomID,
		},
	)
}

headlessCommandWait :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	kind, kindOK := headlessEventKindFromName(command.args[0])
	if !kindOK {
		headlessWriteError(harness, command.name, "unknown event kind; send `help` for the list")
		return
	}
	timeoutMS, timeoutOK := HEADLESS_DEFAULT_WAIT_MS, true
	if command.argCount > 1 {
		timeoutMS, timeoutOK = headlessParseNumber(command.args[1], HEADLESS_MAX_WAIT_MS)
	}
	if !timeoutOK {
		headlessWriteError(harness, command.name, "TIMEOUT_MS must be from 0 to 600000")
		return
	}
	timeout := time.Duration(timeoutMS) * time.Millisecond
	start := time.tick_now()
	for {
		headlessDrainEvents(harness)
		if harness.pendingEvents[kind] > 0 {
			harness.pendingEvents[kind] -= 1
			waited := int(time.duration_milliseconds(time.tick_since(start)))
			headlessWriteJSON(
				harness,
				HeadlessWaitJSON {
					ok = true,
					cmd = command.name,
					event = HEADLESS_EVENT_NAMES[kind],
					waitedMS = waited,
				},
			)
			return
		}
		if time.tick_since(start) >= timeout {
			message := fmt.tprintf(
				"timed out after %d ms waiting for %s",
				timeoutMS,
				HEADLESS_EVENT_NAMES[kind],
			)
			headlessWriteError(harness, command.name, message)
			return
		}
		time.sleep(HEADLESS_POLL_INTERVAL)
	}
}

headlessCommandSleep :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	durationMS, ok := headlessParseNumber(command.args[0], HEADLESS_MAX_WAIT_MS)
	if !ok {
		headlessWriteError(harness, command.name, "MS must be from 0 to 600000")
		return
	}
	headlessPumpFor(harness, time.Duration(durationMS) * time.Millisecond)
	headlessWriteJSON(harness, HeadlessSleepJSON{ok = true, cmd = command.name, ms = durationMS})
}

headlessCommandHelp :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	commands := make([]HeadlessHelpCommandJSON, len(harness.commands))
	defer delete(commands)
	for entry, index in harness.commands {
		commands[index] = {
			usage   = entry.usage,
			summary = entry.summary,
		}
	}
	events: [len(HeadlessEventKind)]string
	for name, kind in HEADLESS_EVENT_NAMES {
		events[int(kind)] = name
	}
	headlessWriteJSON(
		harness,
		HeadlessHelpJSON{ok = true, cmd = command.name, commands = commands, events = events[:]},
	)
}

headlessCommandQuit :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	headlessWriteJSON(harness, HeadlessOKJSON{ok = true, cmd = command.name})
	harness.running = false
}

// ── Stdin ─────────────────────────────────────────────────────────

// Lines read from stdin by a background thread, so a blocking read never stops the main loop
// from draining network events.
HeadlessInput :: struct {
	mutex:  sync.Mutex,
	lines:  [dynamic]string, // Owned
	closed: bool, // stdin reached EOF or failed
}

// Takes ownership of line.
HeadlessInput_push :: proc(input: ^HeadlessInput, line: string) {
	sync.mutex_lock(&input.mutex)
	defer sync.mutex_unlock(&input.mutex)
	append(&input.lines, line)
}

HeadlessInput_close :: proc(input: ^HeadlessInput) {
	sync.mutex_lock(&input.mutex)
	defer sync.mutex_unlock(&input.mutex)
	input.closed = true
}

// Moves the oldest line to the caller, who then owns it. closed is true only once every
// queued line has been taken and stdin is at EOF.
HeadlessInput_pop :: proc(input: ^HeadlessInput) -> (line: string, ok: bool, closed: bool) {
	sync.mutex_lock(&input.mutex)
	defer sync.mutex_unlock(&input.mutex)
	if len(input.lines) > 0 {
		line = input.lines[0]
		ordered_remove(&input.lines, 0)
		return line, true, false
	}
	return "", false, input.closed
}

HeadlessInput_deinit :: proc(input: ^HeadlessInput) {
	for line in input.lines {
		delete(line)
	}
	delete(input.lines)
	input.lines = nil
}

@(private = "file")
headlessReadStdin :: proc(data: rawptr) {
	input := (^HeadlessInput)(data)
	reader: bufio.Reader
	bufio.reader_init(&reader, os.to_stream(os.stdin))
	defer bufio.reader_destroy(&reader)
	for {
		line, err := bufio.reader_read_string(&reader, '\n')
		if len(line) > 0 {
			HeadlessInput_push(input, strings.clone(strings.trim_right(line, "\r\n")))
		}
		delete(line)
		if err != nil {
			break
		}
	}
	HeadlessInput_close(input)
}

// ── Entry point ───────────────────────────────────────────────────

// Runs the harness until `quit` or EOF on stdin. Returns the process exit code.
headlessMain :: proc(args: []string) -> int {
	// stdout carries only JSON lines. The shared client code prints diagnostics with
	// fmt.println, so route os.stdout to stderr and keep the real stdout for the protocol.
	jsonOut := os.stdout
	os.stdout = os.stderr
	defer os.stdout = jsonOut

	options, optionsErr := headlessParseOptions(args)
	if len(optionsErr) > 0 {
		fmt.eprintln("[Error]", optionsErr)
		fmt.eprintln(HEADLESS_USAGE)
		return HEADLESS_EXIT_ERROR
	}
	if len(options.configDir) > 0 && !headlessUseConfigDir(options.configDir) {
		return HEADLESS_EXIT_ERROR
	}

	config := loadConfig()
	defer Config_deinit(&config)
	if len(config.private_key) == 0 || len(config.public_key) == 0 {
		fmt.eprintln("[Error] Could not load or create the client config and identity key")
		return HEADLESS_EXIT_ERROR
	}
	if headlessApplyOptions(&config, options) {
		saveConfig(config)
	}
	if len(config.display_name) == 0 {
		fmt.eprintln("[Error] The profile has no display name; pass --name NAME")
		return HEADLESS_EXIT_ERROR
	}

	harness := HeadlessHarness {
		out      = os.to_writer(jsonOut),
		commands = HEADLESS_COMMANDS[:],
		running  = true,
	}
	defer HeadlessHarness_deinit(&harness)
	if !headlessConnectAndWait(&harness, config) {
		return HEADLESS_EXIT_CONNECT_FAILED
	}

	// The reader thread can stay blocked in read() after `quit`, so input is never freed: the
	// process exits right after this returns.
	input := new(HeadlessInput)
	readerThread := thread.create_and_start_with_data(
		input,
		headlessReadStdin,
		init_context = context,
	)
	if readerThread == nil {
		fmt.eprintln("[Error] Failed to start the stdin reader thread")
		return HEADLESS_EXIT_ERROR
	}

	for harness.running {
		headlessDrainEvents(&harness)
		line, hasLine, closed := HeadlessInput_pop(input)
		if hasLine {
			headlessHandleLine(&harness, line)
			delete(line)
		} else if closed {
			fmt.eprintln("[Info] stdin closed; exiting")
			harness.running = false
		} else {
			time.sleep(HEADLESS_POLL_INTERVAL)
		}
		free_all(context.temp_allocator)
	}
	return HEADLESS_EXIT_OK
}
