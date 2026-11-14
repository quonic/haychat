#+feature dynamic-literals
package client

// HayChat Client - A simple chat client built in Odin using SDL3 for graphics and a custom protocol
// for communication with the server.

import "../common"
import "core:os"
import "core:strings"
import "hotkey"

CHAT_RUNTIME_MAX_EVENTS_PER_FRAME :: 32

RoomChatSendBridge :: proc(transport: ^ClientServerTransport, roomID: int, content: string) -> bool

roomChatSendBridge: RoomChatSendBridge = ClientServerTransport_sendRoomChatMessage

RoomCache :: struct {
	roomID:               int,
	messages:             [dynamic]common.StoredChatMessage,
	draft:                [dynamic]u8, // Client-local, edited in place by the chat input
	initialHistoryLoaded: bool,
	isLoadingHistory:     bool,
	oldestMessageID:      int,
	hasOlder:             bool,
	// The room's last mark-read (read_state.odin); its marker and unread count live in the
	// room's RoomSummary in ServerRoomCache.rooms.
	readSend:             ReadMarkerSendState,
}

ServerRoomCache :: struct {
	serverID:     int,
	rooms:        [dynamic]common.RoomSummary,
	roomCaches:   [dynamic]RoomCache,
	roomsLoaded:  bool,
	roomsLoading: bool,
}

State :: struct {
	config:                         Config,
	serverTransports:               [dynamic]ClientServerTransport,
	should_join_server_from_scheme: bool,
	joinServerFromScheme_host:      string,
	joinServerFromScheme_port:      string,
	// The server whose channels, conversations, and members the sidebar shows.
	selected_server_id:             int,
	selected_transport_index:       int,
	chat_status_message:            string,
	selected_channel_id:            int, // ID of the currently selected channel within the selected server, used for determining which channel's messages to display in the UI
	// The peer of the open direct conversation on the selected server, or 0 while a room is
	// shown. Kept apart from selected_channel_id so closing the conversation restores the room.
	selected_dm_peer_id:            int,
	server_room_caches:             [dynamic]ServerRoomCache,
	// Directory, conversation list, and conversation caches per server (direct_messages.odin).
	serverDirectCaches:             [dynamic]ServerDirectCache,
	// Connects and services every server session off the UI thread; nil until
	// State_startNetwork. Tests that never start it get no network I/O at all.
	networkWorker:                  ^ClientNetworkWorker,
	// Wakes the UI loop when the worker queues events; kept so the worker can be restarted
	// after a settings change.
	networkWake:                    NetworkWorkerEventQueuedProc,
	networkWakeData:                rawptr,
	// The UI thread's view of each server's connection, updated from runtime events, so the
	// view never reads transport fields the worker writes.
	serverConnections:              [dynamic]ServerConnection,
	// Only the real app writes config.json; states built by tests never touch the disk.
	persistConfig:                  bool,
	// The settings screen replaces the chat view while open. It opens by itself on first run.
	settingsOpen:                   bool,
	settings:                       SettingsForm,
	// The admin's room create/edit form (room_admin.odin); shown in the main pane while open
	// on the selected server.
	roomEditor:                     RoomEditor,
	// The last admin action on an account and its answer (admin.odin, protocol 14).
	adminRequest:                   AdminRequestState,
	// Whether the window has input focus. Only the GUI sets it; a conversation counts as
	// viewed (marked read, no new badge) only while it is set (read_state.odin).
	windowFocused:                  bool,
	// Voice rooms (voice_state.odin): the session status, the participant lists, and the
	// running engine.
	voice:                          ClientVoiceState,
	// The Settings → Voice section (voice_settings.odin): device lists and the microphone
	// test, held only while the section is shown.
	voicePanel:                     VoiceSettingsPanel,
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

// Builds a state from a deep copy of config, so callers still own (and free) theirs. Every
// server with a usable config is queued to connect as soon as the network worker starts; no
// network I/O happens here. The config is used as given: an empty display name or server list
// opens the first-run settings screen. Tests that want the old built-in profile ("Test User"
// on localhost) can call Config_fillLocalDefaults first.
State_initFromConfig :: proc(config: Config) -> (init_state: State) {
	init_state.config = Config_clone(config)
	// loadConfig gives every profile a device ID; a config built in code (tests, tools) gets one
	// for this run only, so every voice join can carry a valid one.
	ensureDeviceID(&init_state.config)
	init_state.serverTransports = ClientTransportCatalog_init(&init_state.config)
	for index in 0 ..< len(init_state.serverTransports) {
		transport := &init_state.serverTransports[index]
		ClientServerTransport_requestConnect(transport, {})
		State_resetServerConnection(&init_state, transport)
	}

	init_state.selected_transport_index = -1
	init_state.selected_channel_id = common.GENERAL_ROOM_ID
	if len(init_state.config.servers) > 0 {
		init_state.selected_server_id = init_state.config.servers[0].id
		init_state.selected_transport_index = State_selectedTransportIndexForServerID(
			init_state,
			init_state.selected_server_id,
		)
	}
	if State_needsFirstRunSetup(init_state.config) {
		State_openSettings(&init_state)
	}
	State_setVoiceEngineTemplate(&init_state, voiceDefaultEngineTemplate(init_state.config))
	return
}

// Starts the network worker, which connects every queued server. onEventQueued runs on the
// worker thread whenever events are queued, so the UI loop can wake up and drain them.
State_startNetwork :: proc(
	state: ^State,
	onEventQueued: NetworkWorkerEventQueuedProc = nil,
	onEventQueuedData: rawptr = nil,
) {
	state.networkWake = onEventQueued
	state.networkWakeData = onEventQueuedData
	if state.networkWorker != nil {
		return
	}
	state.networkWorker = ClientNetworkWorker_start(
		state.serverTransports[:],
		onEventQueued,
		onEventQueuedData,
	)
}

// Stops the network worker without closing any session, applying the events it had already
// queued so nothing it reported is lost. Used before the transport array is rebuilt.
State_stopNetwork :: proc(state: ^State) {
	if state.networkWorker == nil {
		return
	}
	// The voice thread sends through the worker's transports, so it stops while they exist.
	State_voiceSuspendForReconfigure(state)
	ClientNetworkWorker_stopThread(state.networkWorker)
	for State_drainNetworkEvents(state) {
	}
	ClientNetworkWorker_stop(state.networkWorker)
	state.networkWorker = nil
}

State_deinit :: proc(state: ^State) {
	// The voice engine sends through the worker and its transports, so it stops first; then
	// the worker stops before the transports it services are freed.
	State_setVoiceSettingsVisible(state, false)
	// Its thread wakes the UI loop through SDL, so it stops while SDL is still up.
	hotkey.destroy(state.voice.globalPushToTalk)
	state.voice.globalPushToTalk = nil
	State_voiceShutdown(state)
	ClientNetworkWorker_stop(state.networkWorker)
	Config_deinit(&state.config)
	ClientTransportCatalog_deinit(&state.serverTransports)
	delete(state.joinServerFromScheme_host)
	delete(state.joinServerFromScheme_port)
	delete(state.chat_status_message)
	for index in 0 ..< len(state.server_room_caches) {
		ServerRoomCache_deinit(&state.server_room_caches[index])
	}
	delete(state.server_room_caches)
	for index in 0 ..< len(state.serverDirectCaches) {
		ServerDirectCache_deinit(&state.serverDirectCaches[index])
	}
	delete(state.serverDirectCaches)
	for index in 0 ..< len(state.serverConnections) {
		ServerConnection_deinit(&state.serverConnections[index])
	}
	delete(state.serverConnections)
	SettingsForm_deinit(&state.settings)
	RoomEditor_deinit(&state.roomEditor)
	AdminRequestState_deinit(&state.adminRequest)
	ClientVoiceState_deinit(&state.voice)
	VoiceSettingsPanel_deinit(&state.voicePanel)
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
	config := loadConfig()
	defer Config_deinit(&config)
	init_state = State_initFromConfig(config)
	init_state.persistConfig = true
	// Connecting happens on the worker, so this returns at once and the window can show the
	// connection status while it runs.
	State_startNetwork(&init_state, onEventQueued, onEventQueuedData)

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
