#+feature dynamic-literals
package client

// HayChat Client - A simple chat client built in Odin using skald for graphics and a custom protocol for communication with the server.

import "../common"
import "core:os"
import "core:strings"
import "shared:skald"

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
}

Vector2 :: [2]f32
iVector2 :: [2]i32

Msg :: struct {
	kind:          MsgKind,
	id:            int, // Generic ID field
	vector:        Vector2, // Generic Vector2 field for passing position or size data in messages, such as for window resize events
	window_vector: iVector2, // Generic iVector2 field for passing integer vector data in messages if needed
	new_value:     string, // Generic string field for passing new values in messages, such as for updating the chat input value
}

MsgKind :: enum {
	None,
	SwitchToDMs,
	SwitchToServer,
	SwitchToFriendsList,
	UpdateWindowSize,
	UpdateChatInputValue,
	SendChatMessage,
	RecieveChatMessage,
	New_Conversation,
	AddFriend,
}

init :: proc() -> (init_state: State) {
	init_state.config = loadConfig()

	if len(init_state.config.display_name) == 0 {
		init_state.config.display_name = "Test User"
	}

	if len(init_state.config.servers) == 0 {
		init_state.config.servers = {
			Server {
				id = 1,
				name = "Test Server",
				short_name = getShortServerName("Test Server"),
				host = "localhost",
				port = common.DEFAULT_SERVER_PORT,
			},
		}
	}

	if len(init_state.config.friends) == 0 {
		init_state.config.friends = {}
	}

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
	init_state.serverTransports = ClientTransportCatalog_init(&init_state.config)
	init_state.view_dms = true
	init_state.view_friends_list = false
	init_state.selected_transport_index = -1
	if len(init_state.config.servers) > 0 {
		init_state.selected_server_id = init_state.config.servers[0].id
		init_state.selected_transport_index = 0
	}
	init_state.window_width = 1920
	init_state.window_height = 1080
	append(&init_state.current_dm_chat, skald.span("Say Hi!", skald.theme_dark().color.fg_muted))

	return
}

main :: proc() {

	skald.run(
		skald.App(State, Msg) {
			title = "HayChat",
			size = {1920, 1080},
			theme = skald.theme_dark(),
			init = init,
			update = update,
			view = view,
			on_window_state_change = changeWindowState,
		},
	)
}

changeWindowState :: proc(new_state: skald.Window_State) -> Msg {
	return Msg{kind = .UpdateWindowSize, window_vector = new_state.size}
}

// Utility function to generate short server names
getShortServerName :: proc(serverName: string) -> string {
	// Generate a short name for the server by taking the first letter of each word in the server name
	words := strings.split(serverName, " ")
	shortName := ""
	for word in words {
		if len(word) > 0 {
			subString, ok := strings.substring(word, 0, 1)
			if ok {
				shortName = strings.concatenate({shortName, subString})
			}
		}
	}
	if len(shortName) == 0 {
		return "?"
	}
	if len(words) < 2 {
		shortName, _ = strings.substring(serverName, 0, 2)
		return shortName
	}

	return shortName
}
