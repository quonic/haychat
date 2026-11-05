package client

import "../common"
import "core:fmt"
import "core:strconv"
import "core:strings"

// The first-run and settings screen: the display name plus the server list. The form edits
// draft buffers; State_applySettings validates them, updates the config, saves it, and
// reconnects whatever changed.

// The server accepts nicknames of 3 to 32 bytes (server/main.odin handleClientHello).
DISPLAY_NAME_MIN_BYTES :: 3
DISPLAY_NAME_MAX_BYTES :: 32
SERVER_HOST_MAX_BYTES :: 253
SERVER_PORT_MAX_BYTES :: 5

SettingsForm :: struct {
	displayName:     [dynamic]u8, // Edited in place by the text inputs
	serverHost:      [dynamic]u8,
	serverPort:      [dynamic]u8,
	// The server whose address the form edits; 0 while adding a new one.
	editingServerID: int,
	error:           string, // Owned
}

SettingsForm_deinit :: proc(form: ^SettingsForm) {
	delete(form.displayName)
	delete(form.serverHost)
	delete(form.serverPort)
	delete(form.error)
	form^ = {}
}

@(private = "file")
SettingsForm_setError :: proc(form: ^SettingsForm, message: string) {
	delete(form.error)
	form.error = strings.clone(message)
}

@(private = "file")
setBuffer :: proc(buffer: ^[dynamic]u8, value: string) {
	clear(buffer)
	append(buffer, value)
}

// The GUI opens the settings screen by itself, and keeps it open, until the config has a
// display name and at least one server.
State_needsFirstRunSetup :: proc(config: Config) -> bool {
	return len(strings.trim_space(config.display_name)) == 0 || len(config.servers) == 0
}

// Settings the form produced once validated. Strings borrow from the form buffers.
SettingsInput :: struct {
	displayName: string,
	hasServer:   bool,
	host:        string,
	port:        i32,
}

// Validates the form fields. requireServer is true when the host may not be left empty
// (first run, or editing an existing server). Returns an empty error on success.
validateSettings :: proc(
	displayName, host, port: string,
	requireServer: bool,
) -> (
	input: SettingsInput,
	errorMessage: string,
) {
	input.displayName = strings.trim_space(displayName)
	if strings.contains_any(input.displayName, "\r\n\t") {
		return input, "The display name cannot contain line breaks or tabs."
	}
	if len(input.displayName) < DISPLAY_NAME_MIN_BYTES ||
	   len(input.displayName) > DISPLAY_NAME_MAX_BYTES {
		return input,
			"The display name must be 3 to 32 bytes long. Most letters take 1 byte; " +
			"accented letters and emoji take 2 to 4."
	}

	input.host = strings.trim_space(host)
	portText := strings.trim_space(port)
	// ":PORT" has no host to split off. "::1" and other IPv6 addresses also start with a colon,
	// so only a single colon is rejected.
	if strings.has_prefix(input.host, ":") && strings.count(input.host, ":") == 1 {
		return input, "Enter the server's host name or IP address before the port."
	}
	// Accept "host:port" pasted into the host field.
	if colon := strings.last_index_byte(input.host, ':'); colon > 0 &&
	   strings.count(input.host, ":") == 1 {
		portText = input.host[colon + 1:]
		input.host = input.host[:colon]
	}
	if len(input.host) == 0 {
		if requireServer {
			return input, "Enter the server's host name or IP address."
		}
		return input, ""
	}
	if strings.contains_any(input.host, " \r\n\t/") {
		return input, "The server host cannot contain spaces or slashes."
	}
	if len(input.host) > SERVER_HOST_MAX_BYTES {
		return input, "The server host is too long."
	}

	input.port = common.DEFAULT_SERVER_PORT
	if len(portText) > 0 {
		value, ok := strconv.parse_int(portText, 10)
		if !ok || value < 1 || value > 65535 {
			return input, "The port must be a number from 1 to 65535."
		}
		input.port = i32(value)
	}
	input.hasServer = true
	return input, ""
}

// A server's label in the rail tooltip and headers: the host, plus the port when it is not
// the default.
serverLabel :: proc(host: string, port: i32) -> string {
	if port == common.DEFAULT_SERVER_PORT {
		return strings.clone(host)
	}
	return fmt.aprintf("%s:%d", host, port)
}

State_openSettings :: proc(state: ^State) {
	state.settingsOpen = true
	form := &state.settings
	setBuffer(&form.displayName, state.config.display_name)
	delete(form.error)
	form.error = ""
	editID := state.selected_server_id
	if _, ok := State_serverConfig(state, editID); !ok {
		editID = len(state.config.servers) > 0 ? state.config.servers[0].id : 0
	}
	State_settingsEditServer(state, editID)
}

// Closing is refused until first-run setup is complete, since there is nothing to show.
State_closeSettings :: proc(state: ^State) {
	if State_needsFirstRunSetup(state.config) {
		return
	}
	state.settingsOpen = false
	delete(state.settings.error)
	state.settings.error = ""
}

// Loads a server's address into the form; serverID 0 starts a new server.
State_settingsEditServer :: proc(state: ^State, serverID: int) {
	form := &state.settings
	form.editingServerID = 0
	clear(&form.serverHost)
	setBuffer(&form.serverPort, fmt.tprintf("%d", common.DEFAULT_SERVER_PORT))
	if server, ok := State_serverConfig(state, serverID); ok {
		form.editingServerID = serverID
		setBuffer(&form.serverHost, server.host)
		setBuffer(&form.serverPort, fmt.tprintf("%d", server.port))
	}
}

// Validates and applies the form. Returns false (with form.error set) when nothing changed.
State_applySettings :: proc(state: ^State) -> bool {
	form := &state.settings
	editingServer, editingExisting := State_serverConfig(state, form.editingServerID)
	requireServer := len(state.config.servers) == 0 || editingExisting
	input, errorMessage := validateSettings(
		string(form.displayName[:]),
		string(form.serverHost[:]),
		string(form.serverPort[:]),
		requireServer,
	)
	if len(errorMessage) > 0 {
		SettingsForm_setError(form, errorMessage)
		return false
	}
	if input.hasServer {
		for server in state.config.servers {
			if server.id != form.editingServerID &&
			   strings.equal_fold(server.host, input.host) &&
			   server.port == input.port {
				SettingsForm_setError(form, "That server is already in your list.")
				return false
			}
		}
	}

	if input.displayName != state.config.display_name {
		delete(state.config.display_name)
		state.config.display_name = strings.clone(input.displayName)
	}

	addedServerID := 0
	if input.hasServer && editingExisting {
		if !strings.equal_fold(editingServer.host, input.host) ||
		   editingServer.port != input.port {
			oldLabel := serverLabel(editingServer.host, editingServer.port)
			defer delete(oldLabel)
			// Keep a name the user chose; only an automatic label follows the address.
			if editingServer.name == oldLabel {
				delete(editingServer.name)
				delete(editingServer.short_name)
				editingServer.name = serverLabel(input.host, input.port)
				editingServer.short_name = getShortServerName(editingServer.name)
			}
			delete(editingServer.host)
			editingServer.host = strings.clone(input.host)
			editingServer.port = input.port
			// A different address is a different server, so its key is pinned afresh.
			Server_setPins(editingServer, "", "")
		}
	} else if input.hasServer {
		addedServerID = 1
		for server in state.config.servers {
			addedServerID = max(addedServerID, server.id + 1)
		}
		name := serverLabel(input.host, input.port)
		append(
			&state.config.servers,
			Server {
				id = addedServerID,
				name = name,
				short_name = getShortServerName(name),
				host = strings.clone(input.host),
				port = input.port,
			},
		)
	}

	State_saveConfig(state)
	State_reconfigureNetwork(state)
	state.settingsOpen = false
	delete(form.error)
	form.error = ""
	if addedServerID != 0 {
		State_switchToServer(state, addedServerID)
	}
	return true
}

// Removes a server from the config and disconnects it. Removing the last one returns to the
// first-run screen.
State_settingsRemoveServer :: proc(state: ^State, serverID: int) {
	for index in 0 ..< len(state.config.servers) {
		if state.config.servers[index].id == serverID {
			Server_deinit(&state.config.servers[index])
			ordered_remove(&state.config.servers, index)
			break
		}
	}
	State_saveConfig(state)
	State_reconfigureNetwork(state)
	if state.settingsOpen {
		State_settingsEditServer(state, state.selected_server_id)
	}
}

@(private = "file")
State_removeServerRoomCache :: proc(state: ^State, serverID: int) {
	State_closeRoomEditorForServer(state, serverID)
	if index := State_serverRoomCacheIndex(state^, serverID); index >= 0 {
		ServerRoomCache_deinit(&state.server_room_caches[index])
		ordered_remove(&state.server_room_caches, index)
	}
	// A different address or name is a different account, so its conversations go too.
	State_removeServerDirectCache(state, serverID)
}

// A live transport can be kept across a settings change only if nothing it connects with
// changed.
@(private = "file")
ClientServerTransport_matchesConfig :: proc(
	transport: ^ClientServerTransport,
	server: Server,
	config: Config,
) -> bool {
	return(
		!transport.configInvalid &&
		transport.serverID == server.id &&
		transport.serverHost == server.host &&
		transport.serverPort == server.port &&
		transport.nickname == config.display_name \
	)
}

// Rebuilds the transport list from the config. Servers whose address and nickname did not
// change keep their sessions; the others reconnect from scratch and lose their room caches,
// since a different address or name is a different account. The worker is stopped while the
// array changes, because it holds a slice of it.
State_reconfigureNetwork :: proc(state: ^State) {
	wasRunning := state.networkWorker != nil
	State_stopNetwork(state)

	previous := state.serverTransports
	rebuilt := make([dynamic]ClientServerTransport, 0, len(state.config.servers))
	for server in state.config.servers {
		reused := false
		for index in 0 ..< len(previous) {
			transport := &previous[index]
			if ClientServerTransport_matchesConfig(transport, server, state.config) {
				append(&rebuilt, transport^)
				transport^ = {}
				reused = true
				break
			}
		}
		if reused {
			continue
		}
		append(&rebuilt, ClientServerTransport_initForServer(server, state.config))
		transport := &rebuilt[len(rebuilt) - 1]
		ClientServerTransport_requestConnect(transport, {})
		State_removeServerRoomCache(state, server.id)
		State_resetServerConnection(state, transport)
	}
	// Whatever was not moved belongs to a removed or changed server; this closes it.
	ClientTransportCatalog_deinit(&previous)
	state.serverTransports = rebuilt

	for index := len(state.serverConnections) - 1; index >= 0; index -= 1 {
		serverID := state.serverConnections[index].serverID
		if _, ok := State_serverConfig(state, serverID); !ok {
			State_removeServerConnection(state, serverID)
			State_removeServerRoomCache(state, serverID)
		}
	}

	if _, ok := State_serverConfig(state, state.selected_server_id); !ok {
		state.selected_server_id = 0
		state.selected_channel_id = 0
		state.selected_dm_peer_id = 0
		if len(state.config.servers) > 0 {
			state.selected_server_id = state.config.servers[0].id
			state.selected_channel_id = common.GENERAL_ROOM_ID
		}
	}
	state.selected_transport_index = State_selectedTransportIndexForServerID(
		state^,
		state.selected_server_id,
	)
	if State_needsFirstRunSetup(state.config) && !state.settingsOpen {
		State_openSettings(state)
	}

	if wasRunning {
		State_startNetwork(state, state.networkWake, state.networkWakeData)
	}
	State_voiceResumeAfterReconfigure(state)
}
