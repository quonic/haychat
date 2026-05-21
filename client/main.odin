#+feature dynamic-literals
package client

// HayChat Client - A simple chat client built in Odin using raylib for graphics and a custom protocol for communication with the server.

import "core:os"
import "core:strings"
import "shared:skald"

State :: struct {}

Msg :: union {}

init :: proc() -> State {
	return State{}
}

main :: proc() {

	when ODIN_DEBUG {
		config = Config {
			private_key  = "test_private_key",
			public_key   = "test_public_key",
			display_name = "Test User",
			servers      = {
				Server{id = 1, name = "Test Server", host = "localhost", port = 12345},
				Server{id = 2, name = "TestServer", host = "localhost", port = 12345},
			},
			friends      = {
				Friend {
					id = 1,
					display_name = "Friend 1",
					public_key = "friend1_public_key",
					servers = {1},
				},
			},
		}
	} else {
		registerSchemeHandler()
		loadConfig()
	}

	joinServerFromScheme_host: string
	joinServerFromScheme_port: string
	if len(os.args) > 1 {
		for arg in os.args {
			if strings.starts_with(arg, "haychat://") {
				// Get the host and port
				// schemeHandler() already handles checking if their is already an instance running and saving the URL data to a temporary file, so we just need to call it here to ensure that the URL data is processed correctly.
				// If we are the first process to run, continue with the normal startup process and handle the URL data after the window is initialized. If we are a subsequent process, exit immediately to allow the existing instance to handle the URL data.
				joinServerFromScheme_host, joinServerFromScheme_port = schemeHandler(arg)
				// TODO: Implement logic to add the server to the config and connect to it after the window is initialized. This should include checking if the server is already in the config, and if not, adding it and then connecting to it.
			}
		}
	}

	skald.run(
		skald.App(State, Msg) {
			title = "Skald — Variable-height Virtual List",
			size = {680, 700},
			theme = skald.theme_dark(),
			init = init,
			update = update,
			view = view,
		},
	)
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
