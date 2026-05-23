#+feature dynamic-literals
package client

// HayChat Client - A simple chat client built in Odin using skald for graphics and a custom protocol for communication with the server.

import "core:os"
import "core:strings"
import "shared:skald"

State :: struct {
	config:                         Config,
	should_join_server_from_scheme: bool,
	joinServerFromScheme_host:      string,
	joinServerFromScheme_port:      string,
	view_dms:                       bool,
	view_friends_list:              bool,
	selected_server_id:             int, // ID of the currently selected server, used for determining which server's channels and friends to display in the UI
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
	// when ODIN_DEBUG {
	init_state.config = {
		private_key  = "test_private_key",
		public_key   = "test_public_key",
		display_name = "Test User",
		servers      = {
			Server {
				id = 1,
				name = "Test Server 1",
				short_name = getShortServerName("Test Server 1"),
				host = "localhost",
				port = 12345,
			},
			Server {
				id = 2,
				name = "Test Server 2",
				short_name = getShortServerName("Test Server 2"),
				host = "localhost",
				port = 12345,
			},
		},
		friends      = {
			Friend {
				id = 1,
				display_name = "Friend 1",
				public_key = "friend1_public_key",
				servers = {1},
				status = .Online,
			},
			Friend {
				id = 2,
				display_name = "Friend 2",
				public_key = "friend2_public_key",
				servers = {1, 2},
				status = .Away,
			},
			Friend {
				id = 3,
				display_name = "Friend 3",
				public_key = "friend3_public_key",
				servers = {1, 2},
				status = .Idle,
			},
			Friend {
				id = 4,
				display_name = "Friend 4",
				public_key = "friend4_public_key",
				servers = {1, 2},
				status = .DoNotDisturb,
			},
		},
	}
	// } else {
	// 	registerSchemeHandler()
	// 	init_state.config = loadConfig()
	// }

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
	init_state.view_dms = true
	init_state.view_friends_list = true
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
