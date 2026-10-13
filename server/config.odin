package server

import "../common"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
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

	// Access control settings
	adminPublicKey:         string, // Hex Ed25519 key allowed to claim keyless privileged accounts
	webAdminToken:          string, // Bearer token required by protected web admin routes
	webAdminTokenFilePath:  string, // Where a generated web admin token is persisted
}

ServerIdentityFile :: struct {
	private_key: string,
	public_key:  string,
}

DEFAULT_LOG_PATH :: "logs"
DEFAULT_FILE_STORAGE_PATH :: "storage"
DEFAULT_SERVER_IDENTITY_FILE_NAME :: "server_identity.json"
DEFAULT_WEB_ADMIN_TOKEN_FILE_NAME :: "web_admin_token"
WEB_ADMIN_TOKEN_MIN_LENGTH :: 32
WEB_ADMIN_GENERATED_TOKEN_BYTES :: 32

loadConfig :: proc() -> (ServerConfig, string) {
	logDir := getEnvOr("HAYCHAT_LOG_DIR", DEFAULT_LOG_PATH)

	config := ServerConfig {
		webAdminHost           = net.IP4_Loopback,
		webAdminPort           = parseOr("HAYCHAT_WEB_ADMIN_PORT", int(8080)),
		databaseURL            = getEnvOr("HAYCHAT_DATABASE_URL", "localhost"),
		databaseUser           = getEnvOr("HAYCHAT_DATABASE_USER", "haychat"), // Default user for local development
		databasePass           = getEnvOr("HAYCHAT_DATABASE_PASS", "haychat"), // Default password for local development
		databaseName           = getEnvOr("HAYCHAT_DATABASE_NAME", "haychat"), // Default database name for local development
		databasePort           = parseOr("HAYCHAT_DATABASE_PORT", int(5432)),
		maxRestarts            = parseOr("HAYCHAT_MAX_RESTARTS", int(5)),
		restartBackoffMin      = time.Duration(
			parseOr("HAYCHAT_RESTART_BACKOFF_MIN", f64(0.1)) * f64(time.Second),
		),
		restartBackoffMax      = time.Duration(
			parseOr("HAYCHAT_RESTART_BACKOFF_MAX", f64(10.0)) * f64(time.Second),
		),
		logLevel               = getEnvOr("HAYCHAT_LOG_LEVEL", "info"),
		logPath                = logDir,
		fileStoragePath        = getEnvOr("HAYCHAT_FILE_STORAGE_PATH", DEFAULT_FILE_STORAGE_PATH),
		maxFileSize            = parseOr("HAYCHAT_MAX_FILE_SIZE", i64(10 * mem.Megabyte)),
		maxStorageCapacity     = parseOr("HAYCHAT_MAX_STORAGE_CAPACITY", i64(1 * mem.Gigabyte)),
		listenAddr             = getEnvOr("HAYCHAT_LISTEN_ADDR", "0.0.0.0"),
		listenPort             = u16(
			parseOr("HAYCHAT_LISTEN_PORT", uint(common.DEFAULT_SERVER_PORT)),
		),
		maxNetworkThreads      = parseOr("HAYCHAT_MAX_NETWORK_THREADS", int(4)),
		serverIdentityFilePath = getEnvOr(
			"HAYCHAT_SERVER_IDENTITY_FILE",
			fmt.aprintf(
				"%s/%s",
				getEnvOr("HAYCHAT_FILE_STORAGE_PATH", DEFAULT_FILE_STORAGE_PATH),
				DEFAULT_SERVER_IDENTITY_FILE_NAME,
			),
		),
		serverPrivateKey       = getEnvOr("HAYCHAT_SERVER_PRIVATE_KEY", ""),
		serverPublicKey        = getEnvOr("HAYCHAT_SERVER_PUBLIC_KEY", ""),
		adminPublicKey         = getEnvOr("HAYCHAT_ADMIN_PUBLIC_KEY", ""),
		webAdminToken          = getEnvOr("HAYCHAT_WEB_ADMIN_TOKEN", ""),
	}

	validateAndNormalizeConfig(&config)
	if preflightErr := startupPreflightError(config); len(preflightErr) > 0 {
		return config, preflightErr
	}
	if identityErr := ensureServerIdentityKeys(&config); len(identityErr) > 0 {
		return config, identityErr
	}
	if tokenErr := ensureWebAdminToken(&config); len(tokenErr) > 0 {
		return config, tokenErr
	}
	return config, ""
}

validateAndNormalizeConfig :: proc(config: ^ServerConfig) {
	if config.webAdminPort <= 0 || config.webAdminPort > 65535 {
		config.webAdminPort = 8080
	}
	if config.databasePort <= 0 || config.databasePort > 65535 {
		config.databasePort = 5432
	}
	if config.maxRestarts < 0 {
		config.maxRestarts = 0
	}
	if config.maxNetworkThreads < 1 {
		config.maxNetworkThreads = 1
	}
	if config.maxFileSize < 1 {
		config.maxFileSize = i64(10 * mem.Megabyte)
	}
	if config.maxStorageCapacity < config.maxFileSize {
		config.maxStorageCapacity = config.maxFileSize
	}
	if config.restartBackoffMin < 0 {
		config.restartBackoffMin = 0
	}
	if config.restartBackoffMax < config.restartBackoffMin {
		config.restartBackoffMax = config.restartBackoffMin
	}
	if len(config.logPath) == 0 {
		config.logPath = DEFAULT_LOG_PATH
	}
	if len(config.fileStoragePath) == 0 {
		config.fileStoragePath = DEFAULT_FILE_STORAGE_PATH
	}
	if len(config.serverIdentityFilePath) == 0 {
		config.serverIdentityFilePath = fmt.aprintf(
			"%s/%s",
			config.fileStoragePath,
			DEFAULT_SERVER_IDENTITY_FILE_NAME,
		)
	}

	if len(config.webAdminTokenFilePath) == 0 {
		config.webAdminTokenFilePath = fmt.aprintf(
			"%s/%s",
			config.fileStoragePath,
			DEFAULT_WEB_ADMIN_TOKEN_FILE_NAME,
		)
	}

	ensureDirectoryPathExists(config.logPath)
	ensureDirectoryPathExists(config.fileStoragePath)
	identityDir := pathDirname(config.serverIdentityFilePath)
	if len(identityDir) > 0 {
		ensureDirectoryPathExists(identityDir)
	}
}

pathDirname :: proc(path: string) -> string {
	lastSeparator := -1
	for i := len(path) - 1; i >= 0; i -= 1 {
		if path[i] == '/' || path[i] == '\\' {
			lastSeparator = i
			break
		}
	}
	if lastSeparator <= 0 {
		return ""
	}
	return path[:lastSeparator]
}

ensureDirectoryPathExists :: proc(path: string) -> bool {
	if len(path) == 0 {
		return false
	}
	if os.exists(path) {
		return true
	}

	start := 0
	when ODIN_OS != .Windows {
		if path[0] == '/' {
			start = 1
		}
	}

	for i := start; i < len(path); i += 1 {
		if path[i] != '/' && path[i] != '\\' {
			continue
		}
		if i == 0 {
			continue
		}
		prefix := path[:i]
		if len(prefix) == 0 || os.exists(prefix) {
			continue
		}
		err := os.make_directory(prefix)
		if err != nil {
			fmt.println("[Warning] Failed to create directory: ", prefix, " - ", err)
			return false
		}
	}

	err := os.make_directory(path)
	if err != nil {
		fmt.println("[Warning] Failed to create directory: ", path, " - ", err)
		return false
	}
	return true
}

startupProbeWriteError :: proc(path: string, label: string) -> string {
	probePath := fmt.aprintf(
		"%s/.haychat_startup_probe_%d",
		path,
		time.time_to_unix_nano(time.now()),
	)
	defer delete(probePath)

	writeErr := os.write_entire_file_from_bytes(probePath, []u8{'o', 'k'})
	if writeErr != nil {
		return fmt.aprintf(
			"startup preflight failed: %s is not writable at %q: %v",
			label,
			path,
			writeErr,
		)
	}

	_ = os.remove(probePath)
	return ""
}

startupPreflightError :: proc(config: ServerConfig) -> string {
	if len(config.fileStoragePath) == 0 {
		return "startup preflight failed: file storage path is empty"
	}
	if storageErr := startupProbeWriteError(config.fileStoragePath, "file storage path");
	   len(storageErr) > 0 {
		return storageErr
	}

	if len(config.adminPublicKey) > 0 {
		if _, ok := common.identityPublicKeyFromHex(config.adminPublicKey); !ok {
			return "startup preflight failed: HAYCHAT_ADMIN_PUBLIC_KEY must be a hex Ed25519 public key"
		}
	}
	if len(config.webAdminToken) > 0 && len(config.webAdminToken) < WEB_ADMIN_TOKEN_MIN_LENGTH {
		return fmt.aprintf(
			"startup preflight failed: HAYCHAT_WEB_ADMIN_TOKEN must be at least %d characters",
			WEB_ADMIN_TOKEN_MIN_LENGTH,
		)
	}

	if hasValidServerIdentity(config) {
		return ""
	}

	identityConfig := ServerConfig {
		serverIdentityFilePath = config.serverIdentityFilePath,
	}
	if loadServerIdentityFile(&identityConfig) {
		delete(identityConfig.serverPrivateKey)
		delete(identityConfig.serverPublicKey)
		return ""
	}
	delete(identityConfig.serverPrivateKey)
	delete(identityConfig.serverPublicKey)

	identityDir := pathDirname(config.serverIdentityFilePath)
	if len(identityDir) == 0 {
		return fmt.aprintf(
			"startup preflight failed: server identity file path %q has no writable parent directory",
			config.serverIdentityFilePath,
		)
	}

	if identityErr := startupProbeWriteError(identityDir, "server identity directory");
	   len(identityErr) > 0 {
		return identityErr
	}

	return ""
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

ensureServerIdentityKeys :: proc(config: ^ServerConfig) -> string {
	if hasValidServerIdentity(config^) {
		return ""
	}

	if loadServerIdentityFile(config) {
		return ""
	}

	privateKeyBytes, publicKeyBytes, ok := common.generateIdentityKeyPair()
	if !ok {
		return "startup preflight failed: could not generate server identity key pair"
	}

	config.serverPrivateKey = common.identityPrivateKeyToHex(privateKeyBytes)
	config.serverPublicKey = common.identityPublicKeyToHex(publicKeyBytes)
	return saveServerIdentityFile(config^)
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

saveServerIdentityFile :: proc(config: ServerConfig) -> string {
	if len(config.serverIdentityFilePath) == 0 || !hasValidServerIdentity(config) {
		return ""
	}

	identityFile := ServerIdentityFile {
		private_key = config.serverPrivateKey,
		public_key  = config.serverPublicKey,
	}
	jsonData, err := json.marshal(identityFile)
	if err != nil {
		return fmt.aprintf(
			"startup preflight failed: could not encode server identity for %q: %v",
			config.serverIdentityFilePath,
			err,
		)
	}
	defer delete(jsonData)

	writeErr := writePrivateFile(config.serverIdentityFilePath, jsonData)
	if writeErr != nil {
		return fmt.aprintf(
			"startup preflight failed: could not persist server identity file at %q: %v",
			config.serverIdentityFilePath,
			writeErr,
		)
	}

	return ""
}

// Writes a file that only the server's user may read, because it holds secret material.
writePrivateFile :: proc(path: string, data: []u8) -> os.Error {
	if err := os.write_entire_file_from_bytes(path, data, os.perm(0o600)); err != nil {
		return err
	}
	// An existing file keeps its old mode on truncate, so tighten it explicitly.
	return os.change_mode(path, os.perm(0o600))
}

// Uses HAYCHAT_WEB_ADMIN_TOKEN when set; otherwise reuses or generates a token persisted at
// webAdminTokenFilePath so operators can read it without it appearing in logs.
ensureWebAdminToken :: proc(config: ^ServerConfig) -> string {
	if len(config.webAdminToken) > 0 {
		return ""
	}

	if os.exists(config.webAdminTokenFilePath) {
		data, err := os.read_entire_file_from_path(config.webAdminTokenFilePath, context.allocator)
		if err == nil {
			token := strings.trim_space(string(data))
			if len(token) >= WEB_ADMIN_TOKEN_MIN_LENGTH {
				config.webAdminToken = strings.clone(token)
				delete(data)
				return ""
			}
		}
		delete(data)
	}

	tokenBytes: [WEB_ADMIN_GENERATED_TOKEN_BYTES]u8
	if !common.generateRandomBytes(tokenBytes[:]) {
		return "startup preflight failed: could not generate web admin token"
	}
	config.webAdminToken = common.encodeBytesToHex(tokenBytes[:])

	if writeErr := writePrivateFile(config.webAdminTokenFilePath, transmute([]u8)config.webAdminToken);
	   writeErr != nil {
		return fmt.aprintf(
			"startup preflight failed: could not persist web admin token at %q: %v",
			config.webAdminTokenFilePath,
			writeErr,
		)
	}
	return ""
}
