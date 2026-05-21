package client

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "widgets"

lastMonitor: i32 = -1 // Global variable to store the last monitor index used by the client, initialized to -1 (no monitor)

XDG_CONFIG_HOME: string = "" // Global variable to store the XDG config home directory path, initialized to an empty string
APP_DATA: string = "" // Global variable to store the APPDATA directory path on Windows, initialized to an empty string
haychatFolder: string = "haychat" // Global variable to store the name of the haychat configuration folder, initialized to "haychat"

Config :: struct {
	private_key:  string,
	public_key:   string,
	display_name: string,
	servers:      [dynamic]Server,
	friends:      [dynamic]Friend,
}

Server :: struct {
	id:     int,
	name:   string,
	host:   string,
	port:   i32,
	handle: widgets.Handle, // Handle to the server button widget in the UI, used for event handling and updating the button state
}

Friend :: struct {
	id:           int,
	display_name: string,
	public_key:   string,
	servers:      [dynamic]int, // List of server IDs the friend is associated with, that the client can use to determine which server(s) to connect to when communicating with this friend
}

loadConfig :: proc() -> Config {

	when ODIN_OS == .Windows {
		APP_DATA = os.get_env("APPDATA", context.allocator)
		if APP_DATA == "" {
			fmt.println(
				"[Warning] APPDATA environment variable is not set. Defaulting to current directory.",
			)
			APP_DATA = "."
		}
	} else when ODIN_OS == .Linux {
		if XDG_CONFIG_HOME == "" {
			XDG_CONFIG_HOME = strings.concatenate(
				{os.get_env("HOME", context.allocator), "/.config"},
				context.allocator,
			)
		}
	}

	path := getConfigPath()
	when ODIN_OS == .Windows {
		if os.exists(strings.concatenate({APP_DATA, "\\", haychatFolder}, context.allocator)) {
			fmt.println(
				"[Info] Found existing config directory at: ",
				strings.concatenate({APP_DATA, "\\", haychatFolder}, context.allocator),
			)
		} else {
			fmt.println(
				"[Info] No existing config directory found at: ",
				strings.concatenate({APP_DATA, "\\", haychatFolder}, context.allocator),
			)
			err := os.make_directory(
				strings.concatenate({APP_DATA, "\\", haychatFolder}, context.allocator),
			)
			if err != nil {
				fmt.println("[Error] Failed to create config directory: ", err)
			} else {
				fmt.println(
					"[Info] Created config directory at: ",
					strings.concatenate({APP_DATA, "\\", haychatFolder}, context.allocator),
				)
			}
		}
	} else when ODIN_OS == .Linux {
		if os.exists(
			strings.concatenate({XDG_CONFIG_HOME, "/", haychatFolder}, context.allocator),
		) {
			fmt.println(
				"[Info] Found existing config directory at: ",
				strings.concatenate({XDG_CONFIG_HOME, "/", haychatFolder}, context.allocator),
			)
		} else {
			fmt.println(
				"[Info] No existing config directory found at: ",
				strings.concatenate({XDG_CONFIG_HOME, "/", haychatFolder}, context.allocator),
			)
			err := os.make_directory(
				strings.concatenate({XDG_CONFIG_HOME, "/", haychatFolder}, context.allocator),
			)
			if err != nil {
				fmt.println("[Error] Failed to create config directory: ", err)
			} else {
				fmt.println(
					"[Info] Created config directory at: ",
					strings.concatenate({XDG_CONFIG_HOME, "/", haychatFolder}, context.allocator),
				)
			}
		}
	}

	shouldLoad := false

	if os.exists(path) {
		fmt.println("[Info] Loaded config from: ", path)
		file, err := os.open(path, {.Read})
		if err != nil {
			fmt.println("[Error] Failed to open config file: ", err)
			return
		}
		shouldLoad = true
		defer os.close(file)
	} else {
		fmt.println("[Info] No config file found at: ", path)
		file, err := os.open(path, {.Create, .Read}, {.Read_User, .Write_User})
		if err != nil {
			fmt.println("[Error] Failed to create config file: ", err)
			return
		} else {
			fmt.println("[Info] Created config file at: ", path)
		}
		defer os.close(file)
	}

	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		fmt.println("[Error] Failed to read config file: ", err)
		return
	}
	if shouldLoad {
		json.unmarshal(data, &config)
	}
	return config
}

saveConfig :: proc(config: Config) {
	if os.exists(getConfigPath()) {
		file, file_err := os.open(getConfigPath(), {.Write})
		if file_err != nil {
			fmt.println("[Error] Failed to open config file for writing: ", file_err)
			return
		}
		defer os.close(file)

		jsonData, json_err := json.marshal(config)
		if json_err != nil {
			fmt.println("[Error] Failed to marshal config to JSON: ", json_err)
			return
		}

		write_err := os.write_entire_file_from_bytes(getConfigPath(), jsonData)
		if write_err != nil {
			fmt.println("[Error] Failed to write config file: ", write_err)
			return
		}
		fmt.println("[Info] Config saved successfully to: ", getConfigPath())
	} else {
		fmt.println("[Error] Config file does not exist at: ", getConfigPath())
	}
}

getConfigPath :: proc() -> string {
	// Returns the path to the configuration file based on the operating system
	when ODIN_OS == .Windows {
		return strings.concatenate(
			{APP_DATA, "\\", haychatFolder, "\\config.json"},
			context.allocator,
		)
	} else when ODIN_OS == .Linux {
		return strings.concatenate(
			{
				os.get_env("HOME", context.allocator),
				XDG_CONFIG_HOME,
				"/",
				haychatFolder,
				"/config.json",
			},
			context.allocator,
		)
	}
	return ""
}
