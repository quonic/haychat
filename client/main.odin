#+feature dynamic-literals
package client

// HayChat Client - A simple chat client built in Odin using SDL3 for graphics and a custom protocol
// for communication with the server.

import "../common"
import "core:fmt"
import "core:os"
import "core:strings"

CHAT_RUNTIME_MAX_EVENTS_PER_FRAME :: 32
DIRECT_MESSAGES_UNSUPPORTED_STATUS :: "Direct messages are not supported yet"

StartupAuthBridge :: proc(
	transport: ^ClientServerTransport,
	server: ^Server,
	config: ^Config,
	clientHelloPacketBytes: []u8,
) -> ClientStartupAuthSession

RoomChatSendBridge :: proc(transport: ^ClientServerTransport, roomID: int, content: string) -> bool

startupAuthBridge: StartupAuthBridge = startupAuthBridge_noop
roomChatSendBridge: RoomChatSendBridge = ClientServerTransport_sendRoomChatMessage

RoomCache :: struct {
	roomID:               int,
	messages:             [dynamic]common.StoredChatMessage,
	draft:                [dynamic]u8, // Client-local, edited in place by the chat input
	initialHistoryLoaded: bool,
	isLoadingHistory:     bool,
	oldestMessageID:      int,
	hasOlder:             bool,
}

// One line of a direct-message transcript. Both strings are owned.
DMLine :: struct {
	senderName: string,
	text:       string,
}

DMLines_deinit :: proc(lines: ^[dynamic]DMLine) {
	for line in lines {
		delete(line.senderName)
		delete(line.text)
	}
	delete(lines^)
	lines^ = nil
}

ServerRoomCache :: struct {
	serverID:     int,
	rooms:        [dynamic]common.RoomSummary,
	roomCaches:   [dynamic]RoomCache,
	roomsLoaded:  bool,
	roomsLoading: bool,
}

startupAuthBridge_noop :: proc(
	transport: ^ClientServerTransport,
	server: ^Server,
	config: ^Config,
	clientHelloPacketBytes: []u8,
) -> ClientStartupAuthSession {
	_ = transport
	_ = server
	_ = config
	_ = clientHelloPacketBytes
	return {}
}

startupAuthBridge_real :: proc(
	transport: ^ClientServerTransport,
	server: ^Server,
	config: ^Config,
	clientHelloPacketBytes: []u8,
) -> ClientStartupAuthSession {
	return ClientServerTransport_completeStartupAuthOverENet(
		transport,
		server,
		config,
		clientHelloPacketBytes,
	)
}

State :: struct {
	config:                         Config,
	serverTransports:               [dynamic]ClientServerTransport,
	should_join_server_from_scheme: bool,
	joinServerFromScheme_host:      string,
	joinServerFromScheme_port:      string,
	view_dms:                       bool,
	view_friends_list:              bool,
	selected_server_id:             int, // ID of the currently selected server, used for determining which server's channels and friends to display in the UI
	selected_transport_index:       int,
	selected_friend_id:             int,
	current_dm_chat:                [dynamic]DMLine,
	dm_chat_draft:                  [dynamic]u8, // Edited in place by the DM chat input
	chat_status_message:            string,
	selected_channel_id:            int, // ID of the currently selected channel within the selected server, used for determining which channel's messages to display in the UI
	server_room_caches:             [dynamic]ServerRoomCache,
	// Services every live server session off the UI thread; nil until init starts it.
	networkWorker:                  ^ClientNetworkWorker,
}

State_selectedTransportIndexForServerID :: proc(state: State, serverID: int) -> int {
	for i in 0 ..< len(state.serverTransports) {
		if state.serverTransports[i].serverID == serverID {
			return i
		}
	}
	return -1
}

State_serverForTransport :: proc(
	state: ^State,
	transport: ^ClientServerTransport,
) -> (
	^Server,
	bool,
) {
	for i in 0 ..< len(state.config.servers) {
		if state.config.servers[i].id == transport.serverID {
			return &state.config.servers[i], true
		}
	}
	return nil, false
}

State_attemptSelectedServerStartup :: proc(state: ^State) {
	if state.selected_transport_index < 0 ||
	   state.selected_transport_index >= len(state.serverTransports) {
		return
	}

	transport := &state.serverTransports[state.selected_transport_index]
	if transport.transport.phase == .Failed {
		fmt.println("[Error] Selected server startup attempt failed:", transport.lastError)
		return
	}

	packetBytes, ok := ClientServerTransport_beginHandshake(transport)
	if !ok {
		ClientServerTransport_fail(transport, "failed to encode client hello packet")
		fmt.println("[Error] Selected server startup attempt failed:", transport.lastError)
		return
	}

	server, serverOK := State_serverForTransport(state, transport)
	if !serverOK {
		delete(packetBytes)
		ClientServerTransport_fail(transport, "selected transport is missing server config")
		fmt.println("[Error] Selected server startup attempt failed:", transport.lastError)
		return
	}

	session := startupAuthBridge(transport, server, &state.config, packetBytes)
	if transport.transport.phase == .Established {
		ClientServerTransport_adoptStartupAuthSession(transport, session)
		if ClientServerTransport_hasLiveENetSession(transport) {
			State_requestRoomList(state, transport.serverID)
		}
	}
	delete(packetBytes)
}

// The state keeps its own deep copy of config, so callers still own (and free) theirs.
State_initFromConfig :: proc(config: Config) -> (init_state: State) {
	init_state.config = Config_clone(config)

	if len(init_state.config.display_name) == 0 {
		delete(init_state.config.display_name)
		init_state.config.display_name = strings.clone("Test User")
	}

	if len(init_state.config.servers) == 0 {
		append(
			&init_state.config.servers,
			Server {
				id = 1,
				name = strings.clone("Test Server"),
				short_name = getShortServerName("Test Server"),
				host = strings.clone("localhost"),
				port = common.DEFAULT_SERVER_PORT,
			},
		)
	}

	init_state.serverTransports = ClientTransportCatalog_init(&init_state.config)
	init_state.view_dms = false
	init_state.view_friends_list = false
	init_state.selected_transport_index = -1
	init_state.selected_channel_id = common.GENERAL_ROOM_ID
	if len(init_state.config.servers) > 0 {
		init_state.selected_server_id = init_state.config.servers[0].id
		init_state.selected_transport_index = State_selectedTransportIndexForServerID(
			init_state,
			init_state.selected_server_id,
		)
		State_attemptSelectedServerStartup(&init_state)
	}

	return
}

State_deinit :: proc(state: ^State) {
	// Stop the worker before freeing the transports it services.
	ClientNetworkWorker_stop(state.networkWorker)
	Config_deinit(&state.config)
	ClientTransportCatalog_deinit(&state.serverTransports)
	delete(state.joinServerFromScheme_host)
	delete(state.joinServerFromScheme_port)
	DMLines_deinit(&state.current_dm_chat)
	delete(state.dm_chat_draft)
	delete(state.chat_status_message)
	for index in 0 ..< len(state.server_room_caches) {
		ServerRoomCache_deinit(&state.server_room_caches[index])
	}
	delete(state.server_room_caches)
	state^ = {}
}

// onEventQueued is called from the network worker thread whenever it queues runtime events, so
// the UI loop can wake up and drain them.
init :: proc(
	onEventQueued: NetworkWorkerEventQueuedProc = nil,
	onEventQueuedData: rawptr = nil,
) -> (
	init_state: State,
) {
	startupAuthBridge = startupAuthBridge_real
	config := loadConfig()
	defer Config_deinit(&config)
	init_state = State_initFromConfig(config)
	// Startup auth above runs before the worker exists; from here on the worker owns servicing.
	init_state.networkWorker = ClientNetworkWorker_start(
		init_state.serverTransports[:],
		onEventQueued,
		onEventQueuedData,
	)

	if len(os.args) > 1 {
		for arg in os.args {
			if strings.starts_with(arg, "haychat://") {
				// Get the host and port
				// schemeHandler() already handles checking if their is already an instance running and saving the URL data to a temporary file, so we just need to call it here to ensure that the URL data is processed correctly.
				// If we are the first process to run, continue with the normal startup process and handle the URL data after the window is initialized. If we are a subsequent process, exit immediately to allow the existing instance to handle the URL data.
				init_state.joinServerFromScheme_host, init_state.joinServerFromScheme_port =
					schemeHandler(arg)
				init_state.should_join_server_from_scheme = true
				// TODO: Implement logic to add the server to the config and connect to it after the window is initialized. This should include checking if the server is already in the config, and if not, adding it and then connecting to it.
			}
		}
	}

	return
}

// Builds a short server label from the first letter of each word, or the first two characters
// of a single-word name. The result is always heap allocated.
getShortServerName :: proc(serverName: string) -> string {
	builder := strings.builder_make()
	wordCount := 0
	remaining := serverName
	for word in strings.fields_iterator(&remaining) {
		wordCount += 1
		if firstRune, ok := strings.substring(word, 0, 1); ok {
			strings.write_string(&builder, firstRune)
		}
	}
	if wordCount == 1 {
		strings.builder_reset(&builder)
		shortName, _ := strings.substring(strings.trim_space(serverName), 0, 2)
		strings.write_string(&builder, shortName)
	}
	if strings.builder_len(builder) == 0 {
		strings.write_string(&builder, "?")
	}
	return strings.to_string(builder)
}
