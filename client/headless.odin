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
// How long startup waits for the first connection before giving up with exit code 2.
HEADLESS_DEFAULT_CONNECT_TIMEOUT_MS :: 15000
// Upper bound for `wait` and `sleep`, so a typo cannot park a scripted client for days.
HEADLESS_MAX_WAIT_MS :: 10 * 60 * 1000
HEADLESS_POLL_INTERVAL :: 5 * time.Millisecond
HEADLESS_MAX_ARGS :: 4
HEADLESS_DISPLAY_NAME_MIN :: 3
HEADLESS_DISPLAY_NAME_MAX :: 32
HEADLESS_USAGE ::
	"usage: client --headless [--name NAME] [--server HOST:PORT] [--config-dir DIR]\n" +
	"                         [--connect-timeout MS]\n" +
	"  --name NAME            display name (3-32 bytes); saved to the profile\n" +
	"  --server HOST:PORT     the profile's only server; saved to the profile\n" +
	"  --config-dir DIR       config root for this profile (like XDG_CONFIG_HOME)\n" +
	"  --connect-timeout MS   how long to wait for the first connection (default 15000)\n" +
	"Commands are read from stdin; type `help` for the list."

// ── Options ───────────────────────────────────────────────────────

HeadlessOptions :: struct {
	// All strings are borrowed from the argument list.
	name:       string,
	serverHost: string,
	serverPort: i32,
	hasServer:        bool,
	configDir:        string,
	connectTimeoutMS: int,
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
	options.connectTimeoutMS = HEADLESS_DEFAULT_CONNECT_TIMEOUT_MS
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
		case "--name", "--server", "--config-dir", "--connect-timeout":
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
				return {}, "--name must be between 3 and 32 bytes"
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
		case "--connect-timeout":
			timeoutMS, ok := headlessParseNumber(value, HEADLESS_MAX_WAIT_MS)
			if !ok || timeoutMS == 0 {
				return {}, "--connect-timeout must be from 1 to 600000 milliseconds"
			}
			options.connectTimeoutMS = timeoutMS
		}
	}
	return options, ""
}

// Applies --name and --server to config. A headless profile has exactly one server: the entry
// matching --server is kept with its pinned key, anything else is replaced by a fresh entry
// without a pin. Without --server the profile's saved servers are used as they are; there is
// no built-in default, so a profile with neither fails to connect with a clear message.
// Returns true when config changed and should be saved.
headlessApplyOptions :: proc(config: ^Config, options: HeadlessOptions) -> bool {
	changed := false
	if len(options.name) > 0 && options.name != config.display_name {
		delete(config.display_name)
		config.display_name = strings.clone(options.name)
		changed = true
	}

	if !options.hasServer {
		return changed
	}
	host := options.serverHost
	port := options.serverPort

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

// Kinds an agent can `wait` for. The connection lifecycle kinds come from the network worker's
// connect state machine, so they keep arriving after startup (for example a reconnect after the
// server restarts).
HeadlessEventKind :: enum {
	Connecting,
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
	DirectMessage,
	DirectHistory,
	UserList,
	Conversations,
	Presence,
	RoomCreated,
}

HEADLESS_EVENT_NAMES := [HeadlessEventKind]string {
	.Connecting     = "connecting",
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
	.DirectMessage  = "direct_message",
	.DirectHistory  = "direct_history",
	.UserList       = "user_list",
	.Conversations  = "conversations",
	.Presence       = "presence",
	.RoomCreated    = "room_created",
}

headlessEventKindFromName :: proc(name: string) -> (HeadlessEventKind, bool) {
	for eventName, kind in HEADLESS_EVENT_NAMES {
		if eventName == name {
			return kind, true
		}
	}
	return {}, false
}

// isAdmin is the server's ServerAuthSuccess flag for this session: whether room management
// is offered. A role granted while connected shows on the next connection (`reconnect`).
HeadlessConnectedJSON :: struct {
	event:    string,
	serverID: int,
	userID:   int,
	nickname: string,
	isAdmin:  bool,
}

HeadlessConnectingJSON :: struct {
	event:    string,
	serverID: int,
	// Attempts since the last connected or disconnected event, starting at 1.
	attempt:  int,
}

// failure names the ClientConnectFailureKind, or a harness-only reason (NoServer, Timeout).
// message is the explanation the GUI shows; detail is the raw transport or server reason.
// retryable is true when the worker will try again (retryInMS from now); false means no further
// attempt happens until something changes.
HeadlessConnectFailedJSON :: struct {
	event:     string,
	serverID:  int,
	message:   string,
	detail:    string,
	failure:   string,
	retryable: bool,
	retryInMS: int,
}

HeadlessDisconnectedJSON :: struct {
	event:     string,
	serverID:  int,
	message:   string,
	retryInMS: int,
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

// A direct message, live or from history. The conversation's peer is recipientID when
// senderID is the viewer's own userID (from `connected`), otherwise senderID.
HeadlessDirectMessageJSON :: struct {
	event:             string,
	serverID:          int,
	id:                int,
	senderID:          int,
	senderNickname:    string,
	recipientID:       int,
	recipientNickname: string,
	timestamp:         string,
	content:           string,
}

HeadlessDirectHistoryMessageJSON :: struct {
	id:                int,
	senderID:          int,
	senderNickname:    string,
	recipientID:       int,
	recipientNickname: string,
	timestamp:         string,
	content:           string,
}

HeadlessDirectHistoryJSON :: struct {
	event:      string,
	serverID:   int,
	peerUserID: int,
	hasOlder:   bool,
	messages:   []HeadlessDirectHistoryMessageJSON,
}

// common.UserSummary already marshals as {"id","nickname","isOnline"}.
HeadlessUserListJSON :: struct {
	event:    string,
	serverID: int,
	users:    []common.UserSummary,
}

HeadlessConversationJSON :: struct {
	peerUserID:    int,
	peerNickname:  string,
	lastMessageID: int,
	lastSenderID:  int,
	lastTimestamp: string,
	lastContent:   string,
}

HeadlessConversationsJSON :: struct {
	event:         string,
	serverID:      int,
	conversations: []HeadlessConversationJSON,
}

HeadlessPresenceJSON :: struct {
	event:    string,
	serverID: int,
	userID:   int,
	nickname: string,
	isOnline: bool,
}

// Converts conversation summaries to their JSON shape. Strings stay borrowed; free the slice
// with allocator.
headlessConversationsJSON :: proc(
	conversations: []common.DirectConversationSummary,
	allocator := context.allocator,
) -> []HeadlessConversationJSON {
	result := make([]HeadlessConversationJSON, len(conversations), allocator)
	for conversation, index in conversations {
		result[index] = {
			peerUserID    = conversation.peerUserId,
			peerNickname  = conversation.peerNickname,
			lastMessageID = conversation.lastMessageID,
			lastSenderID  = conversation.lastSenderId,
			lastTimestamp = conversation.lastTimestamp,
			lastContent   = conversation.lastContent,
		}
	}
	return result
}

// What rendering needs beyond the event itself. The harness fills it in; zero values are fine
// for tests (now defaults to the current time).
HeadlessRenderInfo :: struct {
	attempt:     int, // For .Connecting
	displayName: string, // Names the user in a NameUnavailable explanation
	now:         time.Tick, // Reference for retryInMS
}

// Milliseconds from now until at, never negative; 0 when at is unset.
headlessMillisecondsUntil :: proc(at, now: time.Tick) -> int {
	if at == {} {
		return 0
	}
	return max(int(time.duration_milliseconds(time.tick_diff(now, at))), 0)
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
	info := HeadlessRenderInfo{},
	allocator := context.allocator,
) -> (
	line: string,
	kind: HeadlessEventKind,
	ok: bool,
) {
	now := info.now
	if now == {} {
		now = time.tick_now()
	}
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
	case .RoomCreated:
		kind = .RoomCreated
		line = headlessMarshal(
			HeadlessRoomEditedJSON {
				event = HEADLESS_EVENT_NAMES[kind],
				serverID = event.serverID,
				roomID = event.room.id,
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
	case .Connecting:
		kind = .Connecting
		line = headlessMarshal(
			HeadlessConnectingJSON {
				event = HEADLESS_EVENT_NAMES[kind],
				serverID = event.serverID,
				attempt = max(info.attempt, 1),
			},
			allocator,
		)
	case .Connected:
		kind = .Connected
		line = headlessMarshal(
			HeadlessConnectedJSON {
				event = HEADLESS_EVENT_NAMES[kind],
				serverID = event.serverID,
				userID = event.userID,
				nickname = event.nickname,
				isAdmin = event.isAdmin,
			},
			allocator,
		)
	case .ConnectFailed:
		kind = .ConnectFailed
		message := describeConnectFailure(
			event.failureKind,
			event.message,
			info.displayName,
			event.serverFingerprint,
			allocator,
		)
		defer delete(message, allocator)
		line = headlessMarshal(
			HeadlessConnectFailedJSON {
				event = HEADLESS_EVENT_NAMES[kind],
				serverID = event.serverID,
				message = message,
				detail = event.message,
				failure = fmt.tprintf("%v", event.failureKind),
				retryable = event.retryable,
				retryInMS = event.retryable ? headlessMillisecondsUntil(event.retryAt, now) : 0,
			},
			allocator,
		)
	case .Disconnected:
		kind = .Disconnected
		line = headlessMarshal(
			HeadlessDisconnectedJSON {
				event = HEADLESS_EVENT_NAMES[kind],
				serverID = event.serverID,
				message = event.message,
				retryInMS = headlessMillisecondsUntil(event.retryAt, now),
			},
			allocator,
		)
	case .DirectMessageReceived:
		kind = .DirectMessage
		message := event.directMessage
		line = headlessMarshal(
			HeadlessDirectMessageJSON {
				event = HEADLESS_EVENT_NAMES[kind],
				serverID = event.serverID,
				id = message.id,
				senderID = message.senderId,
				senderNickname = message.senderNickname,
				recipientID = message.recipientId,
				recipientNickname = message.recipientNickname,
				timestamp = message.timestamp,
				content = message.content,
			},
			allocator,
		)
	case .DirectHistoryReceived:
		kind = .DirectHistory
		messages := make([]HeadlessDirectHistoryMessageJSON, len(event.directMessages), allocator)
		defer delete(messages, allocator)
		for message, index in event.directMessages {
			messages[index] = {
				id                = message.id,
				senderID          = message.senderId,
				senderNickname    = message.senderNickname,
				recipientID       = message.recipientId,
				recipientNickname = message.recipientNickname,
				timestamp         = message.timestamp,
				content           = message.content,
			}
		}
		line = headlessMarshal(
			HeadlessDirectHistoryJSON {
				event = HEADLESS_EVENT_NAMES[kind],
				serverID = event.serverID,
				peerUserID = event.peerUserID,
				hasOlder = event.hasOlder,
				messages = messages,
			},
			allocator,
		)
	case .UserListReceived:
		kind = .UserList
		line = headlessMarshal(
			HeadlessUserListJSON {
				event = HEADLESS_EVENT_NAMES[kind],
				serverID = event.serverID,
				users = event.users[:],
			},
			allocator,
		)
	case .DirectConversationsReceived:
		kind = .Conversations
		conversations := headlessConversationsJSON(event.conversations[:], allocator)
		defer delete(conversations, allocator)
		line = headlessMarshal(
			HeadlessConversationsJSON {
				event = HEADLESS_EVENT_NAMES[kind],
				serverID = event.serverID,
				conversations = conversations,
			},
			allocator,
		)
	case .UserPresenceChanged:
		kind = .Presence
		line = headlessMarshal(
			HeadlessPresenceJSON {
				event = HEADLESS_EVENT_NAMES[kind],
				serverID = event.serverID,
				userID = event.user.id,
				nickname = event.user.nickname,
				isOnline = event.user.isOnline,
			},
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

// connection is "connecting", "connected", "retrying" (retryInMS until the next attempt),
// "failed" (stopped until `reconnect`), or "none" when no server is selected.
HeadlessStatusJSON :: struct {
	ok:             bool,
	cmd:            string,
	connection:     string,
	connected:      bool,
	retryInMS:      int,
	serverID:       int,
	server:         string,
	userID:         int,
	nickname:       string,
	isAdmin:        bool,
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

HeadlessServerResultJSON :: struct {
	ok:       bool,
	cmd:      string,
	serverID: int,
}

HeadlessSendJSON :: struct {
	ok:       bool,
	cmd:      string,
	serverID: int,
	roomID:   int,
}

HeadlessUsersJSON :: struct {
	ok:       bool,
	cmd:      string,
	serverID: int,
	loaded:   bool,
	loading:  bool,
	users:    []common.UserSummary,
}

HeadlessConversationsResultJSON :: struct {
	ok:            bool,
	cmd:           string,
	serverID:      int,
	loaded:        bool,
	loading:       bool,
	conversations: []HeadlessConversationJSON,
}

// The result of room-create, room-edit, and room-delete: the request went out. roomID is 0 for
// room-create; the server's answer arrives as a room_created, room_edited, or room_deleted
// event, or as a protocol_error (for example "Admin permission required").
HeadlessRoomRequestJSON :: struct {
	ok:          bool,
	cmd:         string,
	serverID:    int,
	roomID:      int,
	name:        string,
	description: string,
}

HeadlessDirectSendJSON :: struct {
	ok:         bool,
	cmd:        string,
	serverID:   int,
	peerUserID: int,
}

HeadlessDirectHistoryRequestJSON :: struct {
	ok:              bool,
	cmd:             string,
	serverID:        int,
	peerUserID:      int,
	beforeMessageID: int,
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

// Whether the rest of the line after the positional arguments is one more argument, kept
// verbatim (inner spaces included). Not combined with optionalArgs.
HeadlessTextArgument :: enum u8 {
	None,
	Required,
	Optional,
}

HeadlessCommand :: struct {
	name:         string,
	args:         int, // Required positional arguments
	optionalArgs: int, // Optional positional arguments after the required ones
	text:         HeadlessTextArgument,
	usage:        string,
	summary:      string,
	run:          HeadlessCommandProc,
}

// Every command the harness understands. Adding one is a row here plus its handler.
HEADLESS_COMMANDS := [?]HeadlessCommand {
	{"status", 0, 0, .None, "status",
		"connection status, user, nickname, admin flag, selected server", headlessCommandStatus},
	{"reconnect", 0, 0, .None, "reconnect",
		"connects again now, without waiting for the next retry (also after a failure)",
		headlessCommandReconnect},
	{"rooms", 0, 0, .None, "rooms", "joined rooms from the cache; requests them if not loaded",
		headlessCommandRooms},
	{"history", 1, 1, .None, "history ROOM_ID [BEFORE_MESSAGE_ID]",
		"requests a history page; it arrives as a room_history event", headlessCommandHistory},
	{"send", 1, 0, .Required, "send ROOM_ID TEXT...", "sends the rest of the line to a room",
		headlessCommandSend},
	{"users", 0, 0, .None, "users",
		"every account with its online flag, from the cache; requests it if not loaded",
		headlessCommandUsers},
	{"conversations", 0, 0, .None, "conversations",
		"recent direct conversations, newest first; requests them if not loaded",
		headlessCommandConversations},
	{"dm", 1, 0, .Required, "dm USER_ID TEXT...",
		"sends the rest of the line as a direct message", headlessCommandDirectMessage},
	{"dm-history", 1, 1, .None, "dm-history USER_ID [BEFORE_MESSAGE_ID]",
		"requests a page of a direct conversation; it arrives as a direct_history event",
		headlessCommandDirectHistory},
	{"room-create", 1, 0, .Optional, "room-create NAME [DESCRIPTION...]",
		"admins: creates a room; it arrives as room_created", headlessCommandRoomCreate},
	{"room-edit", 2, 0, .Optional, "room-edit ROOM_ID NAME [DESCRIPTION...]",
		"admins: renames a room and sets its description (empty without one)",
		headlessCommandRoomEdit},
	{"room-delete", 1, 0, .None, "room-delete ROOM_ID",
		"admins: deletes a room and its history; it arrives as room_deleted",
		headlessCommandRoomDelete},
	{"wait", 1, 1, .None, "wait EVENT_KIND [TIMEOUT_MS]",
		"waits for an unconsumed event of that kind (default 5000 ms)", headlessCommandWait},
	{"sleep", 1, 0, .None, "sleep MS", "keeps servicing the connection for MS milliseconds",
		headlessCommandSleep},
	{"help", 0, 0, .None, "help", "lists commands and event kinds", headlessCommandHelp},
	{"quit", 0, 0, .None, "quit", "disconnects and exits with code 0", headlessCommandQuit},
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
	assert(
		positional + int(command.text != .None) <= HEADLESS_MAX_ARGS,
		"too many command args",
	)
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
	if command.text != .None {
		if len(rest) > 0 {
			parsed.args[parsed.argCount] = rest
			parsed.argCount += 1
		} else if command.text == .Required {
			return parsed, .BadArguments
		}
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
	pendingEvents:   [HeadlessEventKind]int,
	// Connecting events per server since its last connected or disconnected event.
	connectAttempts: map[int]int,
	running:         bool,
}

HeadlessHarness_deinit :: proc(harness: ^HeadlessHarness) {
	State_deinit(&harness.state)
	delete(harness.connectAttempts)
	harness.connectAttempts = nil
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
	info := HeadlessRenderInfo {
		displayName = harness.state.config.display_name,
	}
	#partial switch event.kind {
	case .Connecting:
		harness.connectAttempts[event.serverID] += 1
		info.attempt = harness.connectAttempts[event.serverID]
	case .Connected, .Disconnected:
		delete_key(&harness.connectAttempts, event.serverID)
	}
	line, kind, ok := headlessRenderRuntimeEvent(event, info)
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

// Writes a connect_failed line that the harness itself produces (no runtime event behind it)
// and counts it for `wait`.
headlessWriteConnectFailed :: proc(
	harness: ^HeadlessHarness,
	serverID: int,
	message, detail, failure: string,
) {
	headlessWriteJSON(
		harness,
		HeadlessConnectFailedJSON {
			event = HEADLESS_EVENT_NAMES[.ConnectFailed],
			serverID = serverID,
			message = message,
			detail = detail,
			failure = failure,
		},
	)
	headlessRecordEvent(harness, .ConnectFailed)
}

// Builds the state, starts the network worker, and waits until the selected server is
// connected. This is the only place that knows how the client connects. The worker drives the
// connect state machine (connection.odin) and reports every step as a runtime event, which is
// printed and applied like any other, so `connecting` and `connect_failed` lines for retried
// attempts show up here too. Returns false, after a connect_failed line, when there is no
// server, when a failure stops retrying, or when timeout passes first.
headlessConnectAndWait :: proc(
	harness: ^HeadlessHarness,
	config: Config,
	timeout: time.Duration,
) -> bool {
	harness.state = State_initFromConfig(config)
	state := &harness.state
	serverID := state.selected_server_id
	_, hasTransport := State_selectedTransport(state)
	connectionIndex := State_serverConnectionIndex(state^, serverID)
	if !hasTransport || connectionIndex < 0 {
		headlessWriteConnectFailed(harness, 0, "no server is configured", "", "NoServer")
		return false
	}
	// A server whose config cannot work (such as a corrupt identity key) is failed before the
	// worker starts, so no runtime event will report it.
	if connection := state.serverConnections[connectionIndex]; connection.status == .Failed {
		message := describeConnectFailure(
			connection.failureKind,
			connection.detail,
			state.config.display_name,
			"",
		)
		failure := fmt.tprintf("%v", connection.failureKind)
		headlessWriteConnectFailed(harness, serverID, message, connection.detail, failure)
		return false
	}

	State_startNetwork(state)
	start := time.tick_now()
	for {
		headlessDrainEvents(harness)
		free_all(context.temp_allocator)
		// Applying events can add connection entries, so look the index up again.
		connectionIndex = State_serverConnectionIndex(state^, serverID)
		if connectionIndex >= 0 {
			#partial switch state.serverConnections[connectionIndex].status {
			case .Established:
				return true
			case .Failed:
				// The worker's connect_failed event (retryable false) is already printed.
				return false
			}
		}
		if time.tick_since(start) >= timeout {
			break
		}
		time.sleep(HEADLESS_POLL_INTERVAL)
	}

	address := ""
	if server, ok := State_serverConfig(state, serverID); ok {
		address = fmt.tprintf("%s:%d", server.host, server.port)
	}
	detail := ""
	if connectionIndex >= 0 {
		detail = state.serverConnections[connectionIndex].detail
	}
	message := fmt.tprintf(
		"timed out after %d ms connecting to %s",
		int(time.duration_milliseconds(timeout)),
		address,
	)
	headlessWriteConnectFailed(harness, serverID, message, detail, "Timeout")
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

// Reports State's mirror of the connection, the same source the GUI's status line uses, so it
// needs no worker lock.
headlessCommandStatus :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	state := &harness.state
	result := HeadlessStatusJSON {
		ok             = true,
		cmd            = command.name,
		connection     = "none",
		serverID       = state.selected_server_id,
		selectedRoomID = state.selected_channel_id,
	}
	if server, ok := State_serverConfig(state, state.selected_server_id); ok {
		result.server = fmt.tprintf("%s:%d", server.host, server.port)
	}
	if index := State_serverConnectionIndex(state^, state.selected_server_id); index >= 0 {
		connection := &state.serverConnections[index]
		switch connection.status {
		case .Idle, .Connecting, .Handshaking:
			result.connection = "connecting"
		case .Established:
			result.connection = "connected"
			result.connected = true
			result.userID = connection.userID
			result.nickname = connection.nickname
			result.isAdmin = connection.isAdmin
		case .Disconnected:
			result.connection = "retrying"
			result.retryInMS = headlessMillisecondsUntil(connection.retryAt, time.tick_now())
		case .Failed:
			result.connection = "failed"
		}
		result.lastError = connection.detail
	}
	headlessWriteJSON(harness, result)
}

// "Retry now": drops any session in progress and connects at once. The outcome arrives as
// connecting and then connected or connect_failed events.
headlessCommandReconnect :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	state := &harness.state
	serverID := state.selected_server_id
	if _, ok := State_selectedTransport(state); !ok {
		headlessWriteError(harness, command.name, "no server is configured")
		return
	}
	State_retryConnection(state, serverID)
	// A server whose config cannot work stays failed; retrying it cannot help.
	if index := State_serverConnectionIndex(state^, serverID); index >= 0 {
		if connection := &state.serverConnections[index]; connection.status == .Failed {
			message := connection.detail
			if len(message) == 0 {
				message = "the server's config cannot be used to connect"
			}
			headlessWriteError(harness, command.name, message)
			return
		}
	}
	headlessWriteJSON(
		harness,
		HeadlessServerResultJSON{ok = true, cmd = command.name, serverID = serverID},
	)
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
	state.selected_dm_peer_id = 0
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

headlessCommandUsers :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	state := &harness.state
	serverID := state.selected_server_id
	cache := State_serverDirectCache(state, serverID)
	if !cache.usersLoaded && !cache.usersLoading {
		State_requestUserList(state, serverID)
		cache = State_serverDirectCache(state, serverID)
	}
	headlessWriteJSON(
		harness,
		HeadlessUsersJSON {
			ok = true,
			cmd = command.name,
			serverID = serverID,
			loaded = cache.usersLoaded,
			loading = cache.usersLoading,
			users = cache.users[:],
		},
	)
}

headlessCommandConversations :: proc(
	harness: ^HeadlessHarness,
	command: ^HeadlessParsedCommand,
) {
	state := &harness.state
	serverID := state.selected_server_id
	cache := State_serverDirectCache(state, serverID)
	if !cache.conversationsLoaded && !cache.conversationsLoading {
		State_requestDirectConversations(state, serverID)
		cache = State_serverDirectCache(state, serverID)
	}
	conversations := headlessConversationsJSON(cache.conversations[:])
	defer delete(conversations)
	headlessWriteJSON(
		harness,
		HeadlessConversationsResultJSON {
			ok = true,
			cmd = command.name,
			serverID = serverID,
			loaded = cache.conversationsLoaded,
			loading = cache.conversationsLoading,
			conversations = conversations,
		},
	)
}

// Sends through State_sendDirectMessageTo, the action behind the GUI's DM composer: the text
// goes into that conversation's draft. The open conversation does not change.
headlessCommandDirectMessage :: proc(
	harness: ^HeadlessHarness,
	command: ^HeadlessParsedCommand,
) {
	peerUserID, peerOK := headlessParseNumber(command.args[0])
	if !peerOK || peerUserID == 0 {
		headlessWriteError(harness, command.name, "usage: dm USER_ID TEXT...")
		return
	}
	state := &harness.state
	serverID := state.selected_server_id
	draft := &ServerDirectCache_conversationCache(
		State_serverDirectCache(state, serverID),
		peerUserID,
	).draft
	clear(draft)
	append(draft, ..transmute([]u8)command.args[1])
	State_clearChatStatus(state)
	State_sendDirectMessageTo(state, serverID, peerUserID)

	draft = &ServerDirectCache_conversationCache(
		State_serverDirectCache(state, serverID),
		peerUserID,
	).draft
	if len(draft) > 0 {
		// Leave nothing behind for the next message to the same user.
		clear(draft)
		message := state.chat_status_message
		if len(message) == 0 {
			message = "failed to send direct message"
		}
		headlessWriteError(harness, command.name, message)
		return
	}
	headlessWriteJSON(
		harness,
		HeadlessDirectSendJSON {
			ok = true,
			cmd = command.name,
			serverID = serverID,
			peerUserID = peerUserID,
		},
	)
}

headlessCommandDirectHistory :: proc(
	harness: ^HeadlessHarness,
	command: ^HeadlessParsedCommand,
) {
	peerUserID, peerOK := headlessParseNumber(command.args[0])
	beforeMessageID, beforeOK := 0, true
	if command.argCount > 1 {
		beforeMessageID, beforeOK = headlessParseNumber(command.args[1])
	}
	if !peerOK || peerUserID == 0 || !beforeOK {
		headlessWriteError(
			harness,
			command.name,
			"usage: dm-history USER_ID [BEFORE_MESSAGE_ID]",
		)
		return
	}
	state := &harness.state
	serverID := state.selected_server_id
	conversation := ServerDirectCache_conversationCache(
		State_serverDirectCache(state, serverID),
		peerUserID,
	)
	// As with `history`, an explicit request always goes out: error replies do not name the
	// request, so the in-flight guard could otherwise stay set.
	conversation.isLoadingHistory = false
	State_clearChatStatus(state)
	State_requestDirectHistory(state, serverID, peerUserID, beforeMessageID)
	conversation = ServerDirectCache_conversationCache(
		State_serverDirectCache(state, serverID),
		peerUserID,
	)
	if !conversation.isLoadingHistory {
		message := state.chat_status_message
		if len(message) == 0 {
			message = "failed to request direct history"
		}
		headlessWriteError(harness, command.name, message)
		return
	}
	headlessWriteJSON(
		harness,
		HeadlessDirectHistoryRequestJSON {
			ok = true,
			cmd = command.name,
			serverID = serverID,
			peerUserID = peerUserID,
			beforeMessageID = beforeMessageID,
		},
	)
}

// Room management goes through the same actions as the GUI's room form, minus the form: the
// harness does not check the admin flag, so an agent can see the server refuse a non-admin.
@(private = "file")
headlessWriteRoomRequest :: proc(
	harness: ^HeadlessHarness,
	command: ^HeadlessParsedCommand,
	errorMessage: string,
	roomID: int,
	name, description: string,
) {
	if len(errorMessage) > 0 {
		headlessWriteError(harness, command.name, errorMessage)
		return
	}
	headlessWriteJSON(
		harness,
		HeadlessRoomRequestJSON {
			ok = true,
			cmd = command.name,
			serverID = harness.state.selected_server_id,
			roomID = roomID,
			name = name,
			description = description,
		},
	)
}

headlessCommandRoomCreate :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	name := command.args[0]
	description := command.argCount > 1 ? command.args[1] : ""
	state := &harness.state
	errorMessage := State_sendCreateRoom(state, state.selected_server_id, name, description)
	cleanName, cleanDescription, _ := validateRoomMetadata(name, description)
	headlessWriteRoomRequest(harness, command, errorMessage, 0, cleanName, cleanDescription)
}

headlessCommandRoomEdit :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	roomID, roomOK := headlessParseNumber(command.args[0])
	if !roomOK || roomID == 0 {
		headlessWriteError(harness, command.name, "usage: room-edit ROOM_ID NAME [DESCRIPTION...]")
		return
	}
	name := command.args[1]
	description := command.argCount > 2 ? command.args[2] : ""
	state := &harness.state
	errorMessage := State_sendEditRoom(state, state.selected_server_id, roomID, name, description)
	cleanName, cleanDescription, _ := validateRoomMetadata(name, description)
	headlessWriteRoomRequest(harness, command, errorMessage, roomID, cleanName, cleanDescription)
}

headlessCommandRoomDelete :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	roomID, roomOK := headlessParseNumber(command.args[0])
	if !roomOK || roomID == 0 {
		headlessWriteError(harness, command.name, "usage: room-delete ROOM_ID")
		return
	}
	state := &harness.state
	errorMessage := State_sendDeleteRoom(state, state.selected_server_id, roomID)
	headlessWriteRoomRequest(harness, command, errorMessage, roomID, "", "")
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
	connectTimeout := time.Duration(options.connectTimeoutMS) * time.Millisecond
	if !headlessConnectAndWait(&harness, config, connectTimeout) {
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
