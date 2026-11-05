package client

import "../common"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"

XDG_CONFIG_HOME: string = "" // Global variable to store the XDG config home directory path, initialized to an empty string
APP_DATA: string = "" // Global variable to store the APPDATA directory path on Windows, initialized to an empty string
haychatFolder: string = "haychat" // Global variable to store the name of the haychat configuration folder, initialized to "haychat"

Config :: struct {
	private_key:  string,
	public_key:   string,
	display_name: string,
	servers:      [dynamic]Server,
}

Server :: struct {
	id:                        int,
	name:                      string,
	short_name:                string,
	host:                      string,
	port:                      i32,
	pinned_server_public_key:  string,
	pinned_server_fingerprint: string,
}

loadConfig :: proc() -> (config: Config) {
	when ODIN_OS == .Windows {
		APP_DATA = os.get_env("APPDATA", context.allocator)
		if APP_DATA == "" {
			fmt.println(
				"[Warning] APPDATA environment variable is not set. Defaulting to current directory.",
			)
			APP_DATA = "."
		}
	} else when ODIN_OS == .Linux {
		XDG_CONFIG_HOME = os.get_env("XDG_CONFIG_HOME", context.allocator)
		if XDG_CONFIG_HOME == "" {
			delete(XDG_CONFIG_HOME)
			XDG_CONFIG_HOME = getDefaultLinuxConfigHome(os.get_env("HOME", context.temp_allocator))
		}
	}

	if !ensureConfigDirExists() {
		return {}
	}

	path := getConfigPath()
	defer delete(path)
	shouldLoad := false
	shouldPersist := false
	readPath := path

	when ODIN_OS == .Linux {
		legacyPath := getLegacyLinuxConfigPath()
		defer delete(legacyPath)
		if !os.exists(path) && legacyPath != path && os.exists(legacyPath) {
			fmt.println("[Info] Migrating config from legacy path: ", legacyPath)
			readPath = legacyPath
			shouldLoad = true
			shouldPersist = true
		}
	}

	if !shouldLoad && os.exists(readPath) {
		fmt.println("[Info] Loaded config from: ", readPath)
		shouldLoad = true
	} else if !shouldLoad {
		fmt.println("[Info] No config file found at: ", path)
		shouldPersist = true
	}

	if shouldLoad {
		data, err := os.read_entire_file_from_path(readPath, context.allocator)
		if err != nil {
			fmt.println("[Error] Failed to read config file: ", err)
			return {}
		}
		defer delete(data)
		json.unmarshal(data, &config)
	}

	if ensureIdentityKeys(&config) {
		shouldPersist = true
	}

	if shouldPersist {
		saveConfig(config)
	}

	return config
}

saveConfig :: proc(config: Config) {
	if !ensureConfigDirExists() {
		return
	}

	jsonData, json_err := json.marshal(config)
	if json_err != nil {
		fmt.println("[Error] Failed to marshal config to JSON: ", json_err)
		return
	}
	defer delete(jsonData)

	// The config holds the client's private identity key, so only the user may read it.
	configPath := getConfigPath()
	defer delete(configPath)
	write_err := os.write_entire_file_from_bytes(configPath, jsonData, os.perm(0o600))
	if write_err == nil {
		write_err = os.change_mode(configPath, os.perm(0o600))
	}
	if write_err != nil {
		fmt.println("[Error] Failed to write config file: ", write_err)
		return
	}
	fmt.println("[Info] Config saved successfully to: ", configPath)
}

ensureConfigDirExists :: proc() -> bool {
	configDir := getConfigDir()
	defer delete(configDir)
	if configDir == "" {
		fmt.println("[Error] Config directory could not be determined")
		return false
	}

	when ODIN_OS == .Linux {
		if !os.exists(XDG_CONFIG_HOME) {
			err := os.make_directory(XDG_CONFIG_HOME)
			if err != nil {
				fmt.println("[Error] Failed to create base config directory: ", err)
				return false
			}
		}
	}

	if os.exists(configDir) {
		return true
	}

	err := os.make_directory(configDir)
	if err != nil {
		fmt.println("[Error] Failed to create config directory: ", err)
		return false
	}

	fmt.println("[Info] Created config directory at: ", configDir)
	return true
}

getDefaultLinuxConfigHome :: proc(home: string, allocator := context.allocator) -> string {
	when ODIN_OS == .Linux {
		return strings.concatenate({home, "/.config"}, allocator)
	}
	return ""
}

getLinuxConfigDirForConfigHome :: proc(configHome: string) -> string {
	when ODIN_OS == .Linux {
		return strings.concatenate({configHome, "/", haychatFolder}, context.allocator)
	}
	return ""
}

getLinuxConfigPathForConfigHome :: proc(configHome: string) -> string {
	when ODIN_OS == .Linux {
		configDir := getLinuxConfigDirForConfigHome(configHome)
		defer delete(configDir)
		return strings.concatenate({configDir, "/config.json"}, context.allocator)
	}
	return ""
}

getHistoricalLegacyLinuxConfigPathForConfigHome :: proc(home, configHome: string) -> string {
	when ODIN_OS == .Linux {
		configPath := getLinuxConfigPathForConfigHome(configHome)
		defer delete(configPath)
		return strings.concatenate({home, configPath}, context.allocator)
	}
	return ""
}

getConfigDir :: proc() -> string {
	when ODIN_OS == .Windows {
		return strings.concatenate({APP_DATA, "\\", haychatFolder}, context.allocator)
	} else when ODIN_OS == .Linux {
		return getLinuxConfigDirForConfigHome(XDG_CONFIG_HOME)
	}
	return ""
}

getConfigPath :: proc() -> string {
	// Returns the path to the configuration file based on the operating system
	when ODIN_OS == .Windows {
		configDir := getConfigDir()
		defer delete(configDir)
		return strings.concatenate({configDir, "\\config.json"}, context.allocator)
	} else when ODIN_OS == .Linux {
		return getLinuxConfigPathForConfigHome(XDG_CONFIG_HOME)
	}
	return ""
}

getLegacyLinuxConfigPath :: proc() -> string {
	when ODIN_OS == .Linux {
		home := os.get_env("HOME", context.temp_allocator)
		legacyConfigHome := XDG_CONFIG_HOME
		if legacyConfigHome == "" {
			legacyConfigHome = os.get_env("XDG_CONFIG_HOME", context.temp_allocator)
		}
		if legacyConfigHome == "" {
			legacyConfigHome = getDefaultLinuxConfigHome(home, context.temp_allocator)
		}

		// The original Linux client wrote to HOME + XDG_CONFIG_HOME + /haychat/config.json.
		return getHistoricalLegacyLinuxConfigPathForConfigHome(home, legacyConfigHome)
	}
	return ""
}

ensureIdentityKeys :: proc(config: ^Config) -> bool {
	if len(config.private_key) > 0 && len(config.public_key) > 0 {
		_, privateKeyOK := common.identityPrivateKeyFromHex(config.private_key)
		_, publicKeyOK := common.identityPublicKeyFromHex(config.public_key)
		if privateKeyOK && publicKeyOK {
			return false
		}
	}

	privateKeyBytes, publicKeyBytes, ok := common.generateIdentityKeyPair()
	if !ok {
		fmt.println("[Error] Failed to generate client identity key pair")
		return false
	}

	delete(config.private_key)
	delete(config.public_key)
	config.private_key = common.identityPrivateKeyToHex(privateKeyBytes)
	config.public_key = common.identityPublicKeyToHex(publicKeyBytes)
	return true
}

// Replaces a server's pins with clones of the given hex key and fingerprint.
Server_setPins :: proc(server: ^Server, publicKey, fingerprint: string) {
	delete(server.pinned_server_public_key)
	delete(server.pinned_server_fingerprint)
	server.pinned_server_public_key = strings.clone(publicKey)
	server.pinned_server_fingerprint = strings.clone(fingerprint)
}

// Config values are owned: every string and array is heap allocated. Clone before storing a
// config somewhere that frees it, and free it with Config_deinit.
Server_clone :: proc(server: Server) -> Server {
	return Server {
		id = server.id,
		name = strings.clone(server.name),
		short_name = strings.clone(server.short_name),
		host = strings.clone(server.host),
		port = server.port,
		pinned_server_public_key = strings.clone(server.pinned_server_public_key),
		pinned_server_fingerprint = strings.clone(server.pinned_server_fingerprint),
	}
}

Server_deinit :: proc(server: ^Server) {
	delete(server.name)
	delete(server.short_name)
	delete(server.host)
	delete(server.pinned_server_public_key)
	delete(server.pinned_server_fingerprint)
	server^ = {}
}

Config_clone :: proc(config: Config) -> Config {
	clone := Config {
		private_key  = strings.clone(config.private_key),
		public_key   = strings.clone(config.public_key),
		display_name = strings.clone(config.display_name),
		servers      = make([dynamic]Server, 0, len(config.servers)),
	}
	for server in config.servers {
		append(&clone.servers, Server_clone(server))
	}
	return clone
}

Config_deinit :: proc(config: ^Config) {
	delete(config.private_key)
	delete(config.public_key)
	delete(config.display_name)
	for index in 0 ..< len(config.servers) {
		Server_deinit(&config.servers[index])
	}
	delete(config.servers)
	config^ = {}
}

LOCAL_DEFAULT_DISPLAY_NAME :: "Test User"
LOCAL_DEFAULT_SERVER_NAME :: "Test Server"
LOCAL_DEFAULT_SERVER_HOST :: "localhost"

// Fills an empty display name and an empty server list with the local development profile
// ("Test User" on localhost:12345). The GUI never does this: it shows the first-run screen
// instead. Tests and tools that want a ready-to-connect default call it explicitly.
Config_fillLocalDefaults :: proc(config: ^Config) {
	if len(config.display_name) == 0 {
		delete(config.display_name)
		config.display_name = strings.clone(LOCAL_DEFAULT_DISPLAY_NAME)
	}
	if len(config.servers) == 0 {
		append(
			&config.servers,
			Server {
				id = 1,
				name = strings.clone(LOCAL_DEFAULT_SERVER_NAME),
				short_name = getShortServerName(LOCAL_DEFAULT_SERVER_NAME),
				host = strings.clone(LOCAL_DEFAULT_SERVER_HOST),
				port = common.DEFAULT_SERVER_PORT,
			},
		)
	}
}
