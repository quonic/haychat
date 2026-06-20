package server

import "../common"
import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:net"
import "core:os"
import "core:strconv"
import "core:sys/linux"
import "core:time"

// Configuration for the HayChat server
ServerConfig :: struct {
	// IPC socket paths for inter-process communication
	mainFd:                 linux.Fd,
	networkSocket:          IPC_Server_Context,
	networkFd:              linux.Fd,
	networkSocketName:      string,
	networkProcess:         ProcessInfo,
	webAdminSocket:         IPC_Server_Context,
	webAdminFd:             linux.Fd,
	webAdminSocketName:     string,
	webAdminProcess:        ProcessInfo,
	databaseSocket:         IPC_Server_Context,
	databaseFd:             linux.Fd,
	databaseSocketName:     string,
	databaseProcess:        ProcessInfo,

	// Web admin server settings (localhost only)
	webAdminHost:           net.Address,
	webAdminPort:           int,

	// Database connection settings
	databaseURL:            string,
	databaseUser:           string,
	databasePass:           string,
	databaseName:           string,
	databasePort:           int,

	// Process management settings
	maxRestarts:            int, // Maximum restart attempts before giving up
	restartBackoffMin:      time.Duration, // Minimum backoff in seconds
	restartBackoffMax:      time.Duration, // Maximum backoff in seconds

	// Logging settings
	logLevel:               string, // "debug", "info", "warn", "error"
	logPath:                string, // Directory for log files

	// File storage settings
	fileStoragePath:        string, // Directory for storing uploaded files
	maxFileSize:            i64, // Maximum allowed file size for uploads
	maxStorageCapacity:     i64, // Maximum total storage capacity for all uploaded files combined

	// Network server settings
	listenAddr:             string, // IP address to listen on (e.g., "0.0.0.0", "127.0.0.1")
	listenPort:             u16, // Port to listen on for client connections
	maxNetworkThreads:      int, // Number of threads in the network thread pool

	// Server identity settings
	serverIdentityFilePath: string,
	serverPrivateKey:       string,
	serverPublicKey:        string,
}

ServerIdentityFile :: struct {
	private_key: string,
	public_key:  string,
}

// Load configuration from environment variables and defaults
loadConfig :: proc() -> ServerConfig {
	logDir := getEnvOr("HAYCHAT_LOG_DIR", "/var/log/haychat")

	config := ServerConfig {
		// Web admin (localhost only)
		webAdminHost           = net.IP4_Loopback,
		webAdminPort           = parseOr("HAYCHAT_WEB_ADMIN_PORT", int(8080)),

		// Database
		databaseURL            = getEnvOr("HAYCHAT_DATABASE_URL", "localhost"),
		databaseUser           = getEnvOr("HAYCHAT_DATABASE_USER", "haychat"),
		databasePass           = getEnvOr("HAYCHAT_DATABASE_PASS", ""),
		databaseName           = getEnvOr("HAYCHAT_DATABASE_NAME", "haychat"),
		databasePort           = parseOr("HAYCHAT_DATABASE_PORT", int(5432)),

		// Process management
		maxRestarts            = parseOr("HAYCHAT_MAX_RESTARTS", int(5)),
		restartBackoffMin      = time.Duration(
			parseOr("HAYCHAT_RESTART_BACKOFF_MIN", f64(0.1)) * f64(time.Second),
		),
		restartBackoffMax      = time.Duration(
			parseOr("HAYCHAT_RESTART_BACKOFF_MAX", f64(10.0)) * f64(time.Second),
		),

		// Logging
		logLevel               = getEnvOr("HAYCHAT_LOG_LEVEL", "info"),
		logPath                = logDir,

		// File storage
		fileStoragePath        = getEnvOr("HAYCHAT_FILE_STORAGE_PATH", "/var/lib/haychat/files"),
		maxFileSize            = parseOr("HAYCHAT_MAX_FILE_SIZE", i64(10 * mem.Megabyte)),
		maxStorageCapacity     = parseOr("HAYCHAT_MAX_STORAGE_CAPACITY", i64(1 * mem.Gigabyte)),

		// Network server
		listenAddr             = getEnvOr("HAYCHAT_LISTEN_ADDR", "0.0.0.0"),
		listenPort             = u16(
			parseOr("HAYCHAT_LISTEN_PORT", uint(common.DEFAULT_SERVER_PORT)),
		),
		maxNetworkThreads      = parseOr("HAYCHAT_MAX_NETWORK_THREADS", int(4)),

		// Server identity
		serverIdentityFilePath = getEnvOr(
			"HAYCHAT_SERVER_IDENTITY_FILE",
			fmt.aprintf(
				"%s/server_identity.json",
				getEnvOr("HAYCHAT_FILE_STORAGE_PATH", "/var/lib/haychat/files"),
			),
		),
		serverPrivateKey       = getEnvOr("HAYCHAT_SERVER_PRIVATE_KEY", ""),
		serverPublicKey        = getEnvOr("HAYCHAT_SERVER_PUBLIC_KEY", ""),
	}

	ensureServerIdentityKeys(&config)
	return config
}

// Helper procedures for environment variable parsing
getEnvOr :: proc(key: string, default_value: string) -> string {
	value := os.get_env(key, context.allocator)
	if len(value) == 0 {
		return default_value
	}
	return value
}

parseOr :: proc {
	parseUintOr,
	parseIntOr,
	parseInt64Or,
	parseF32Or,
	parseF64Or,
}

parseUintOr :: proc(key: string, default_value: uint) -> uint {
	string_value := getEnvOr(key, fmt.aprintf("%d", default_value))
	value, ok := strconv.parse_int(string_value)
	if !ok do return default_value
	return uint(value)
}

parseIntOr :: proc(key: string, default_value: int) -> int {
	string_value := getEnvOr(key, fmt.aprintf("%d", default_value))
	value, ok := strconv.parse_int(string_value)
	if !ok do return default_value
	return value
}

parseInt64Or :: proc(key: string, default_value: i64) -> i64 {
	string_value := getEnvOr(key, fmt.aprintf("%d", default_value))
	value, ok := strconv.parse_i64(string_value)
	if !ok do return default_value
	return i64(value)
}

parseF32Or :: proc(key: string, default_value: f32) -> f32 {
	string_value := getEnvOr(key, fmt.aprintf("%f", default_value))
	value, ok := strconv.parse_f32(string_value)
	if !ok do return default_value
	return f32(value)
}

parseF64Or :: proc(key: string, default_value: f64) -> f64 {
	string_value := getEnvOr(key, fmt.aprintf("%f", default_value))
	value, ok := strconv.parse_f64(string_value)
	if !ok do return default_value
	return f64(value)
}

ensureServerIdentityKeys :: proc(config: ^ServerConfig) {
	if hasValidServerIdentity(config^) {
		return
	}

	if loadServerIdentityFile(config) {
		return
	}

	privateKeyBytes, publicKeyBytes, ok := common.generateIdentityKeyPair()
	if !ok {
		log.info("[Error] Failed to generate server identity key pair")
		return
	}

	config.serverPrivateKey = common.identityPrivateKeyToHex(privateKeyBytes)
	config.serverPublicKey = common.identityPublicKeyToHex(publicKeyBytes)
	saveServerIdentityFile(config^)
}

hasValidServerIdentity :: proc(config: ServerConfig) -> bool {
	if len(config.serverPrivateKey) == 0 || len(config.serverPublicKey) == 0 {
		return false
	}

	_, privateKeyOK := common.identityPrivateKeyFromHex(config.serverPrivateKey)
	_, publicKeyOK := common.identityPublicKeyFromHex(config.serverPublicKey)
	return privateKeyOK && publicKeyOK
}

loadServerIdentityFile :: proc(config: ^ServerConfig) -> bool {
	if len(config.serverIdentityFilePath) == 0 || !os.exists(config.serverIdentityFilePath) {
		return false
	}

	data, err := os.read_entire_file_from_path(config.serverIdentityFilePath, context.allocator)
	if err != nil {
		return false
	}
	defer delete(data)

	identityFile: ServerIdentityFile
	json.unmarshal(data, &identityFile)
	config.serverPrivateKey = identityFile.private_key
	config.serverPublicKey = identityFile.public_key
	return hasValidServerIdentity(config^)
}

saveServerIdentityFile :: proc(config: ServerConfig) {
	if len(config.serverIdentityFilePath) == 0 || !hasValidServerIdentity(config) {
		return
	}

	identityFile := ServerIdentityFile {
		private_key = config.serverPrivateKey,
		public_key  = config.serverPublicKey,
	}
	jsonData, err := json.marshal(identityFile)
	if err != nil {
		log.info("[Error] Failed to marshal server identity file: ", err)
		return
	}
	defer delete(jsonData)

	writeErr := os.write_entire_file_from_bytes(config.serverIdentityFilePath, jsonData)
	if writeErr != nil {
		log.info("[Warning] Failed to persist server identity file: ", writeErr)
	}
}
