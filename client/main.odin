#+feature dynamic-literals
package client

// HayChat Client - A simple chat client built in Odin using raylib for graphics and a custom protocol for communication with the server.

import "core:os"
import "core:strings"
import "vendor:raylib"
import "widgets"

TAKE_SCREENSHOT: bool : #config(TEST_SCREENSHOT, false) // Set to true to take a screenshot of the client window when it starts up, for testing purposes.

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

	raylib.SetConfigFlags({.WINDOW_RESIZABLE})
	raylib.InitWindow(800, 600, "HayChat Client")

	when ODIN_OS == .Linux {
		if lastMonitor >= 0 {
			SetWindowToSpecificMonitor(lastMonitor, true)
		} else {
			SetWindowToPrimaryMonitor(true)
		}
	} else when ODIN_OS == .Windows {
		// Let Windows handle the monitor selection automatically
	}

	// Initialize the UI widgets
	initUI()

	for !raylib.WindowShouldClose() {

		updateUI()

		raylib.BeginDrawing()
		raylib.ClearBackground(raylib.BLACK)

		drawUI()

		raylib.EndDrawing()

		when TAKE_SCREENSHOT {
			raylib.TakeScreenshot("haychat_screenshot.png")
			break
		}
	}

	lastMonitor = raylib.GetCurrentMonitor()

	// saveConfig()

	raylib.CloseWindow()
}


// Utility function to generate short server names
getShortServerName :: proc(serverName: string) -> cstring {
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
		return strings.clone_to_cstring(shortName)
	}

	return strings.clone_to_cstring(shortName)
}
