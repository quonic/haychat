#+feature dynamic-literals
package client

// HayChat Client - A simple chat client built in Odin using skald for graphics and a custom protocol for communication with the server.

import "../common"
import "core:fmt"
import "core:os"
import "core:strings"
import "shared:skald"

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
	draft:                string,
	initialHistoryLoaded: bool,
	isLoadingHistory:     bool,
	oldestMessageID:      int,
	hasOlder:             bool,
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
	window_width:                   f32, // Current width of the application window, used for responsive UI layout
	window_height:                  f32, // Current height of the application window, used for responsive UI layout
	current_dm_chat:                [dynamic]skald.Text_Span,
	dm_chat_draft:                  string,
	chat_input_draft:               string, // Current draft text in the chat input field, used for sending messages
	chat_status_message:            string,
	current_chat_messages:          [dynamic]skald.Text_Span, // List of chat messages currently displayed in the chat area, used for rendering the chat history
	selected_channel_id:            int, // ID of the currently selected channel within the selected server, used for determining which channel's messages to display in the UI
	server_room_caches:             [dynamic]ServerRoomCache,
	// Services every live server session off the UI thread; nil until init starts it.
	networkWorker:                  ^ClientNetworkWorker,
}

Vector2 :: [2]f32
iVector2 :: [2]i32

Msg :: struct {
	kind:          MsgKind,
	id:            int, // Generic ID field
	channel_id:    int, // ID of the channel, used for switching to a specific channel
	sender_id:     int,
	message_id:    int,
	timestamp:     string,
	rooms:         [dynamic]common.RoomSummary,
	messages:      [dynamic]common.StoredChatMessage,
	has_older:     bool,
	joined:        bool,
	room:          common.RoomSummary,
	vector:        Vector2, // Generic Vector2 field for passing position or size data in messages, such as for window resize events
	window_vector: iVector2, // Generic iVector2 field for passing integer vector data in messages if needed
	// Generic string field for passing new values in messages, such as the chat input value.
	// Borrowed for view-originated messages; owned (and freed by update) for transport
	// messages: RecieveChannelChatMessage and TransportProtocolError.
	new_value:     string,
}

MsgKind :: enum {
	None,
	SwitchToDMs,
	SwitchToServer,
	SwitchToChannel,
	SwitchToFriendsList,
	UpdateWindowSize,
	UpdateChatInputValue,
	UpdateChannelChatInputValue,
	SendChatMessage,
	SendChannelChatMessage,
	RecieveChatMessage,
	RecieveChannelChatMessage,
	RecieveRoomList,
	RecieveRoomHistory,
	RoomMembershipChanged,
	RoomEdited,
	RoomDeleted,
	LoadOlderRoomHistory,
	TransportProtocolError,
	New_Conversation,
	AddFriend,
}

ClientTransportRuntimeEvent_toMsg :: proc(event: ClientTransportRuntimeEvent) -> (Msg, bool) {
	switch event.kind {
	case .RoomChatReceived:
		return Msg {
				kind = .RecieveChannelChatMessage,
				id = event.serverID,
				channel_id = event.roomID,
				sender_id = event.senderID,
				message_id = event.messageID,
				timestamp = event.timestamp,
				new_value = event.message,
			},
			true
	case .RoomListReceived:
		return Msg{kind = .RecieveRoomList, id = event.serverID, rooms = event.rooms}, true
	case .RoomHistoryReceived:
		return Msg {
				kind = .RecieveRoomHistory,
				id = event.serverID,
				channel_id = event.roomID,
				messages = event.messages,
				has_older = event.hasOlder,
			},
			true
	case .RoomMembershipChanged:
		return Msg {
				kind = .RoomMembershipChanged,
				id = event.serverID,
				channel_id = event.roomID,
				joined = event.joined,
			},
			true
	case .RoomEdited:
		return Msg {
				kind = .RoomEdited,
				id = event.serverID,
				channel_id = event.roomID,
				room = event.room,
			},
			true
	case .RoomDeleted:
		return Msg{kind = .RoomDeleted, id = event.serverID, channel_id = event.roomID}, true

	case .ProtocolError:
		return Msg{kind = .TransportProtocolError, id = event.serverID, new_value = event.message},
			true

	case .Disconnected, .None:
		return {}, false
	}
	return {}, false
}

// Converts queued network events from every server into Msgs. The network worker does all the
// ENet servicing, so this only moves already-decoded events and never blocks on I/O.
State_drainNetworkEvents :: proc(state: State, ctx: ^skald.Ctx(Msg)) {
	for _ in 0 ..< CHAT_RUNTIME_MAX_EVENTS_PER_FRAME {
		runtimeEvent, hasEvent := ClientNetworkWorker_popEvent(state.networkWorker)
		if !hasEvent {
			return
		}

		msg, hasMsg := ClientTransportRuntimeEvent_toMsg(runtimeEvent)
		if hasMsg {
			// Ownership of these fields moved into msg.
			runtimeEvent.timestamp = ""
			runtimeEvent.message = ""
			runtimeEvent.rooms = {}
			runtimeEvent.messages = {}
			runtimeEvent.room = {}
			skald.send(ctx, msg)
		}
		ClientTransportRuntimeEvent_deinit(&runtimeEvent)
	}
}

viewWithRuntime :: proc(state: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	State_drainNetworkEvents(state, ctx)
	return view(state, ctx)
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
	init_state.window_width = 1920
	init_state.window_height = 1080
	State_appendTranscriptSpan(
		&init_state.current_dm_chat,
		skald.span("Say Hi!", skald.theme_dark().color.fg_muted),
	)

	return
}

State_deinit :: proc(state: ^State) {
	// Stop the worker before freeing the transports it services.
	ClientNetworkWorker_stop(state.networkWorker)
	Config_deinit(&state.config)
	ClientTransportCatalog_deinit(&state.serverTransports)
	delete(state.joinServerFromScheme_host)
	delete(state.joinServerFromScheme_port)
	TranscriptSpans_deinit(&state.current_dm_chat)
	TranscriptSpans_deinit(&state.current_chat_messages)
	delete(state.dm_chat_draft)
	delete(state.chat_input_draft)
	delete(state.chat_status_message)
	for index in 0 ..< len(state.server_room_caches) {
		ServerRoomCache_deinit(&state.server_room_caches[index])
	}
	delete(state.server_room_caches)
	state^ = {}
}

// Transcript spans own their text: append clones it, and deinit frees it.
State_appendTranscriptSpan :: proc(spans: ^[dynamic]skald.Text_Span, span: skald.Text_Span) {
	owned := span
	owned.str = strings.clone(span.str)
	append(spans, owned)
}

TranscriptSpans_deinit :: proc(spans: ^[dynamic]skald.Text_Span) {
	for span in spans {
		delete(span.str)
	}
	delete(spans^)
	spans^ = nil
}

init :: proc() -> (init_state: State) {
	startupAuthBridge = startupAuthBridge_real
	config := loadConfig()
	defer Config_deinit(&config)
	init_state = State_initFromConfig(config)
	// Startup auth above runs before the worker exists; from here on the worker owns servicing.
	init_state.networkWorker = ClientNetworkWorker_start(init_state.serverTransports[:])

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

main :: proc() {

	skald.run(
		skald.App(State, Msg) {
			title = "HayChat",
			size = {1920, 1080},
			theme = skald.theme_dark(),
			always_redraw = true,
			init = init,
			update = update,
			view = viewWithRuntime,
			on_window_state_change = changeWindowState,
		},
	)
}

changeWindowState :: proc(new_state: skald.Window_State) -> Msg {
	return Msg{kind = .UpdateWindowSize, window_vector = new_state.size}
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
