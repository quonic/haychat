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
	friends:      [dynamic]Friend,
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

Friend :: struct {
	id:           int,
	display_name: string,
	public_key:   string,
	servers:      [dynamic]int, // List of server IDs the friend is associated with, that the client can use to determine which server(s) to connect to when communicating with this friend
	status:       FriendStatus,
}
FriendStatus :: enum {
	Offline,
	Online,
	Busy,
	Away,
	DoNotDisturb,
	Idle,
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
			XDG_CONFIG_HOME = strings.concatenate(
				{os.get_env("HOME", context.allocator), "/.config"},
				context.allocator,
			)
		}
	}

	if !ensureConfigDirExists() {
		return {}
	}

	path := getConfigPath()
	shouldLoad := false
	shouldPersist := false
	readPath := path

	when ODIN_OS == .Linux {
		legacyPath := getLegacyLinuxConfigPath()
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

	write_err := os.write_entire_file_from_bytes(getConfigPath(), jsonData)
	if write_err != nil {
		fmt.println("[Error] Failed to write config file: ", write_err)
		return
	}
	fmt.println("[Info] Config saved successfully to: ", getConfigPath())
}

ensureConfigDirExists :: proc() -> bool {
	configDir := getConfigDir()
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

getConfigDir :: proc() -> string {
	when ODIN_OS == .Windows {
		return strings.concatenate({APP_DATA, "\\", haychatFolder}, context.allocator)
	} else when ODIN_OS == .Linux {
		return strings.concatenate({XDG_CONFIG_HOME, "/", haychatFolder}, context.allocator)
	}
	return ""
}

getConfigPath :: proc() -> string {
	// Returns the path to the configuration file based on the operating system
	when ODIN_OS == .Windows {
		return strings.concatenate({getConfigDir(), "\\config.json"}, context.allocator)
	} else when ODIN_OS == .Linux {
		return strings.concatenate({getConfigDir(), "/config.json"}, context.allocator)
	}
	return ""
}

getLegacyLinuxConfigPath :: proc() -> string {
	when ODIN_OS == .Linux {
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

	config.private_key = common.identityPrivateKeyToHex(privateKeyBytes)
	config.public_key = common.identityPublicKeyToHex(publicKeyBytes)
	return true
}

pinServerIdentity :: proc(
	server: ^Server,
	serverPublicKey: common.IdentityPublicKeyBytes,
) -> common.PeerTrustState {
	serverPublicKeyHex := common.identityPublicKeyToHex(serverPublicKey)
	serverFingerprintHex := common.fingerprintToHex(
		common.fingerprintIdentityPublicKey(serverPublicKey),
	)

	if len(server.pinned_server_public_key) == 0 && len(server.pinned_server_fingerprint) == 0 {
		server.pinned_server_public_key = serverPublicKeyHex
		server.pinned_server_fingerprint = serverFingerprintHex
		return .Trusted
	}

	if server.pinned_server_public_key == serverPublicKeyHex &&
	   server.pinned_server_fingerprint == serverFingerprintHex {
		return .Trusted
	}

	return .Changed
}
