package server

import "../common"
import "core:encoding/json"
import "core:fmt"
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
	databaseSocket:         IPC_Server_Context,
	databaseFd:             linux.Fd,
	databaseSocketName:     string,
	databaseProcess:        ProcessInfo,
	// The storage worker (protocol 26, storage.odin): attachment file I/O.
	storageSocket:          IPC_Server_Context,
	storageFd:              linux.Fd,
	storageSocketName:      string,

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

	// State directory: holds the default server identity file. Nothing is uploaded to it; the
	// file upload endpoint was removed (#31).
	fileStoragePath:        string,

	// Network server settings
	listenAddr:             string, // IP address to listen on (e.g., "0.0.0.0", "127.0.0.1")
	listenPort:             u16, // Port to listen on for client connections
	// ENet peer capacity hint: the host accepts 16 peers per unit. The name is historical; the
	// network worker pool it once sized was removed because it did no work.
	maxNetworkThreads:      int,

	// Server identity settings
	serverIdentityFilePath: string,
	serverPrivateKey:       string,
	serverPublicKey:        string,

	// Access control settings
	adminPublicKey:         string, // Hex Ed25519 key allowed to claim keyless privileged accounts

	// Voice settings (voice-rooms-design.md 4.4). Voice rides the ENet port above (channel 2).
	voiceEnabled:             bool, // false rejects every voice join with "voice is disabled"
	voiceMaxParticipants:     int, // voice sessions per room
	voiceMaxPacketsPerSecond: int, // per-peer relay rate limit; the burst is a third of it
	voiceMaxFrameBytes:       int, // largest Opus payload the relay forwards

	// Attachments (protocol 26, attachments plan D4, D21; loadAttachmentConfig). Byte limits
	// are i64; 0 means none for the quota, the hourly rate and the capacity.
	attachmentsEnabled:              bool, // false refuses every upload begin
	attachmentDir:                   string, // blob directory: incoming/ and blobs/
	attachmentMaxBytes:              i64, // largest stored blob
	attachmentAccountQuotaBytes:     i64, // stored per account
	attachmentUploadBytesPerHour:    i64, // uploaded per account in any hour
	attachmentCapacityBytes:         i64, // stored on the server
	attachmentMinFreeBytes:          i64, // free-disk reserve on the blob directory's volume
	attachmentPendingHours:          int, // unbound uploads are swept after this
	attachmentSessionBytesPerSecond: i64, // per-session pace, both directions together
	// One start's leave to delete orphans past the startup scan's guards (#131).
	attachmentAllowOrphanPurge:      bool,

	// Per-address sign-up limits (#105, router_registration_limits.odin;
	// loadRegistrationLimitConfig). 0 turns the sessions, attempts or requests limit off.
	registrationIPSessions:          int, // registering sessions one address may hold
	registrationIPAttemptsBurst:     int, // attempt bucket size
	registrationIPAttemptsPerMinute: int, // attempt bucket refill
	registrationIPRequestsPerHour:   int, // sign-up requests one address may make in an hour
}

ServerIdentityFile :: struct {
	private_key: string,
	public_key:  string,
}

DEFAULT_LOG_PATH :: "logs"
DEFAULT_FILE_STORAGE_PATH :: "storage"
DEFAULT_SERVER_IDENTITY_FILE_NAME :: "server_identity.json"

// Voice defaults and the ranges validateVoiceConfig clamps to. Clients send 50 frames per
// second, so the default rate leaves 20% headroom. The frame size cannot exceed the wire limit
// (common.VOICE_OPUS_MAX_BYTES); 64 bytes is about 25 kbit/s, the lowest useful cap.
DEFAULT_VOICE_ENABLED :: true
DEFAULT_VOICE_MAX_PARTICIPANTS :: 25
VOICE_MAX_PARTICIPANTS_MIN :: 1
VOICE_MAX_PARTICIPANTS_MAX :: 200
DEFAULT_VOICE_MAX_PACKETS_PER_SECOND :: 60
VOICE_MAX_PACKETS_PER_SECOND_MIN :: 1
VOICE_MAX_PACKETS_PER_SECOND_MAX :: 1000
DEFAULT_VOICE_MAX_FRAME_BYTES :: 512
VOICE_MAX_FRAME_BYTES_MIN :: 64
VOICE_MAX_FRAME_BYTES_MAX :: common.VOICE_OPUS_MAX_BYTES

// Attachment defaults (attachments plan D21) and the ranges validateAttachmentConfig clamps to.
// Limits whose default is "none" take 0 for none.
ATTACHMENT_KIB :: i64(1024)
ATTACHMENT_MIB :: 1024 * ATTACHMENT_KIB
ATTACHMENT_GIB :: 1024 * ATTACHMENT_MIB
ATTACHMENT_TIB :: 1024 * ATTACHMENT_GIB
DEFAULT_ATTACHMENTS_ENABLED :: true
DEFAULT_ATTACHMENT_DIR :: "attachments"
DEFAULT_ATTACHMENT_MAX_BYTES :: 25 * ATTACHMENT_MIB
ATTACHMENT_MAX_BYTES_MIN :: ATTACHMENT_KIB
ATTACHMENT_MAX_BYTES_MAX :: 4 * ATTACHMENT_GIB
DEFAULT_ATTACHMENT_ACCOUNT_QUOTA_BYTES :: ATTACHMENT_GIB
ATTACHMENT_ACCOUNT_QUOTA_BYTES_MAX :: ATTACHMENT_TIB
DEFAULT_ATTACHMENT_UPLOAD_BYTES_PER_HOUR :: 512 * ATTACHMENT_MIB
ATTACHMENT_UPLOAD_BYTES_PER_HOUR_MAX :: ATTACHMENT_TIB
DEFAULT_ATTACHMENT_CAPACITY_BYTES :: i64(0)
ATTACHMENT_CAPACITY_BYTES_MAX :: 1024 * ATTACHMENT_TIB
DEFAULT_ATTACHMENT_MIN_FREE_BYTES :: ATTACHMENT_GIB
ATTACHMENT_MIN_FREE_BYTES_MAX :: ATTACHMENT_TIB
DEFAULT_ATTACHMENT_PENDING_HOURS :: 24
ATTACHMENT_PENDING_HOURS_MIN :: 1
ATTACHMENT_PENDING_HOURS_MAX :: 30 * 24
DEFAULT_ATTACHMENT_SESSION_BYTES_PER_SECOND :: 4 * ATTACHMENT_MIB
ATTACHMENT_SESSION_BYTES_PER_SECOND_MIN :: 64 * ATTACHMENT_KIB
ATTACHMENT_SESSION_BYTES_PER_SECOND_MAX :: ATTACHMENT_GIB
// The blob directory's subdirectories (storage.odin), created at startup with mode 0700.
// The startup scan's override (#131): set for one start, it lets the scan delete orphans past
// its guards (an empty attachments table, more than ATTACHMENT_ORPHAN_PURGE_MAX_SHARE_PERCENT).
ATTACHMENT_ALLOW_ORPHAN_PURGE_KEY :: "HAYCHAT_ATTACHMENT_ALLOW_ORPHAN_PURGE"
DEFAULT_ATTACHMENT_ALLOW_ORPHAN_PURGE :: false

ATTACHMENT_INCOMING_DIR_NAME :: "incoming"
ATTACHMENT_BLOBS_DIR_NAME :: "blobs"

// Per-address sign-up limit defaults (#105) and the ranges validateRegistrationLimitConfig
// clamps to. A limit of 0 is off. The defaults leave room for a household or a small office
// behind one address; see docs/server-configuration.md (Sign-up Limits).
REGISTRATION_IP_SESSIONS_KEY :: "HAYCHAT_REGISTRATION_IP_SESSIONS"
REGISTRATION_IP_ATTEMPTS_BURST_KEY :: "HAYCHAT_REGISTRATION_IP_ATTEMPTS_BURST"
REGISTRATION_IP_ATTEMPTS_PER_MINUTE_KEY :: "HAYCHAT_REGISTRATION_IP_ATTEMPTS_PER_MINUTE"
REGISTRATION_IP_REQUESTS_PER_HOUR_KEY :: "HAYCHAT_REGISTRATION_IP_REQUESTS_PER_HOUR"
DEFAULT_REGISTRATION_IP_SESSIONS :: 8
REGISTRATION_IP_SESSIONS_MAX :: common.REGISTERING_SESSIONS_MAX
DEFAULT_REGISTRATION_IP_ATTEMPTS_BURST :: 30
REGISTRATION_IP_ATTEMPTS_BURST_MAX :: 10000
DEFAULT_REGISTRATION_IP_ATTEMPTS_PER_MINUTE :: 10
REGISTRATION_IP_ATTEMPTS_PER_MINUTE_MIN :: 1
REGISTRATION_IP_ATTEMPTS_PER_MINUTE_MAX :: 10000
DEFAULT_REGISTRATION_IP_REQUESTS_PER_HOUR :: 10
REGISTRATION_IP_REQUESTS_PER_HOUR_MAX :: 10000

loadConfig :: proc() -> (ServerConfig, string) {
	logDir := getEnvOr("HAYCHAT_LOG_DIR", DEFAULT_LOG_PATH)

	config := ServerConfig {
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
	}
	loadVoiceConfig(&config)
	loadAttachmentConfig(&config)
	loadRegistrationLimitConfig(&config)

	validateAndNormalizeConfig(&config)
	if preflightErr := startupPreflightError(config); len(preflightErr) > 0 {
		return config, preflightErr
	}
	if identityErr := ensureServerIdentityKeys(&config); len(identityErr) > 0 {
		return config, identityErr
	}
	return config, ""
}

// Variables the server no longer reads. Startup warns when one is set, so an operator does not
// believe a limit still applies. HAYCHAT_MAX_FILE_SIZE and HAYCHAT_MAX_STORAGE_CAPACITY limited
// the file upload endpoint removed in #31; attachments (protocol 26) use
// HAYCHAT_ATTACHMENT_MAX_BYTES and HAYCHAT_ATTACHMENT_CAPACITY_BYTES instead.
RETIRED_CONFIG_VARIABLES :: [?]string{"HAYCHAT_MAX_FILE_SIZE", "HAYCHAT_MAX_STORAGE_CAPACITY"}

// Returns the retired variables set in the environment, allocated with the given allocator.
retiredConfigVariablesSet :: proc(allocator := context.allocator) -> [dynamic]string {
	set := make([dynamic]string, allocator)
	for key in RETIRED_CONFIG_VARIABLES {
		value := os.get_env(key, context.temp_allocator)
		if len(value) > 0 {
			append(&set, key)
		}
	}
	return set
}

// Reads the HAYCHAT_VOICE_* keys and clamps them to their ranges. A value that does not parse
// falls back to the default.
loadVoiceConfig :: proc(config: ^ServerConfig) {
	config.voiceEnabled = parseBoolOr("HAYCHAT_VOICE_ENABLED", DEFAULT_VOICE_ENABLED)
	config.voiceMaxParticipants = parseOr(
		"HAYCHAT_VOICE_MAX_PARTICIPANTS",
		int(DEFAULT_VOICE_MAX_PARTICIPANTS),
	)
	config.voiceMaxPacketsPerSecond = parseOr(
		"HAYCHAT_VOICE_MAX_PACKETS_PER_SECOND",
		int(DEFAULT_VOICE_MAX_PACKETS_PER_SECOND),
	)
	config.voiceMaxFrameBytes = parseOr(
		"HAYCHAT_VOICE_MAX_FRAME_BYTES",
		int(DEFAULT_VOICE_MAX_FRAME_BYTES),
	)
	validateVoiceConfig(config)
}

// Clamps the voice limits into their ranges, so a typo cannot turn the relay off (0 packets per
// second) or past the wire limit.
validateVoiceConfig :: proc(config: ^ServerConfig) {
	config.voiceMaxParticipants = clamp(
		config.voiceMaxParticipants,
		VOICE_MAX_PARTICIPANTS_MIN,
		VOICE_MAX_PARTICIPANTS_MAX,
	)
	config.voiceMaxPacketsPerSecond = clamp(
		config.voiceMaxPacketsPerSecond,
		VOICE_MAX_PACKETS_PER_SECOND_MIN,
		VOICE_MAX_PACKETS_PER_SECOND_MAX,
	)
	config.voiceMaxFrameBytes = clamp(
		config.voiceMaxFrameBytes,
		VOICE_MAX_FRAME_BYTES_MIN,
		VOICE_MAX_FRAME_BYTES_MAX,
	)
}

// Reads the HAYCHAT_ATTACHMENT* keys and clamps them to their ranges. A value that does not
// parse falls back to the default.
loadAttachmentConfig :: proc(config: ^ServerConfig) {
	config.attachmentsEnabled = parseBoolOr(
		"HAYCHAT_ATTACHMENTS_ENABLED",
		DEFAULT_ATTACHMENTS_ENABLED,
	)
	config.attachmentDir = getEnvOr("HAYCHAT_ATTACHMENT_DIR", DEFAULT_ATTACHMENT_DIR)
	config.attachmentMaxBytes = parseOr(
		"HAYCHAT_ATTACHMENT_MAX_BYTES",
		DEFAULT_ATTACHMENT_MAX_BYTES,
	)
	config.attachmentAccountQuotaBytes = parseOr(
		"HAYCHAT_ATTACHMENT_ACCOUNT_QUOTA_BYTES",
		DEFAULT_ATTACHMENT_ACCOUNT_QUOTA_BYTES,
	)
	config.attachmentUploadBytesPerHour = parseOr(
		"HAYCHAT_ATTACHMENT_UPLOAD_BYTES_PER_HOUR",
		DEFAULT_ATTACHMENT_UPLOAD_BYTES_PER_HOUR,
	)
	config.attachmentCapacityBytes = parseOr(
		"HAYCHAT_ATTACHMENT_CAPACITY_BYTES",
		DEFAULT_ATTACHMENT_CAPACITY_BYTES,
	)
	config.attachmentMinFreeBytes = parseOr(
		"HAYCHAT_ATTACHMENT_MIN_FREE_BYTES",
		DEFAULT_ATTACHMENT_MIN_FREE_BYTES,
	)
	config.attachmentPendingHours = parseOr(
		"HAYCHAT_ATTACHMENT_PENDING_HOURS",
		int(DEFAULT_ATTACHMENT_PENDING_HOURS),
	)
	config.attachmentSessionBytesPerSecond = parseOr(
		"HAYCHAT_ATTACHMENT_SESSION_BYTES_PER_SECOND",
		DEFAULT_ATTACHMENT_SESSION_BYTES_PER_SECOND,
	)
	config.attachmentAllowOrphanPurge = parseBoolOr(
		ATTACHMENT_ALLOW_ORPHAN_PURGE_KEY,
		DEFAULT_ATTACHMENT_ALLOW_ORPHAN_PURGE,
	)
	validateAttachmentConfig(config)
}

// Clamps the attachment limits into their ranges: a typo cannot make a limit negative, the
// pending window shorter than the sweeper's one hour, or the session pace stall transfers.
validateAttachmentConfig :: proc(config: ^ServerConfig) {
	config.attachmentMaxBytes = clamp(
		config.attachmentMaxBytes,
		ATTACHMENT_MAX_BYTES_MIN,
		ATTACHMENT_MAX_BYTES_MAX,
	)
	config.attachmentAccountQuotaBytes = clamp(
		config.attachmentAccountQuotaBytes,
		0,
		ATTACHMENT_ACCOUNT_QUOTA_BYTES_MAX,
	)
	config.attachmentUploadBytesPerHour = clamp(
		config.attachmentUploadBytesPerHour,
		0,
		ATTACHMENT_UPLOAD_BYTES_PER_HOUR_MAX,
	)
	config.attachmentCapacityBytes = clamp(
		config.attachmentCapacityBytes,
		0,
		ATTACHMENT_CAPACITY_BYTES_MAX,
	)
	config.attachmentMinFreeBytes = clamp(
		config.attachmentMinFreeBytes,
		0,
		ATTACHMENT_MIN_FREE_BYTES_MAX,
	)
	config.attachmentPendingHours = clamp(
		config.attachmentPendingHours,
		ATTACHMENT_PENDING_HOURS_MIN,
		ATTACHMENT_PENDING_HOURS_MAX,
	)
	config.attachmentSessionBytesPerSecond = clamp(
		config.attachmentSessionBytesPerSecond,
		ATTACHMENT_SESSION_BYTES_PER_SECOND_MIN,
		ATTACHMENT_SESSION_BYTES_PER_SECOND_MAX,
	)
}

// Reads the HAYCHAT_REGISTRATION_IP_* keys and clamps them to their ranges. A value that does
// not parse falls back to the default.
loadRegistrationLimitConfig :: proc(config: ^ServerConfig) {
	config.registrationIPSessions = parseOr(
		REGISTRATION_IP_SESSIONS_KEY,
		int(DEFAULT_REGISTRATION_IP_SESSIONS),
	)
	config.registrationIPAttemptsBurst = parseOr(
		REGISTRATION_IP_ATTEMPTS_BURST_KEY,
		int(DEFAULT_REGISTRATION_IP_ATTEMPTS_BURST),
	)
	config.registrationIPAttemptsPerMinute = parseOr(
		REGISTRATION_IP_ATTEMPTS_PER_MINUTE_KEY,
		int(DEFAULT_REGISTRATION_IP_ATTEMPTS_PER_MINUTE),
	)
	config.registrationIPRequestsPerHour = parseOr(
		REGISTRATION_IP_REQUESTS_PER_HOUR_KEY,
		int(DEFAULT_REGISTRATION_IP_REQUESTS_PER_HOUR),
	)
	validateRegistrationLimitConfig(config)
}

// Clamps the per-address sign-up limits into their ranges: a negative value is off, a share
// cannot exceed common.REGISTERING_SESSIONS_MAX, and the attempt bucket always refills.
validateRegistrationLimitConfig :: proc(config: ^ServerConfig) {
	config.registrationIPSessions = clamp(
		config.registrationIPSessions,
		0,
		REGISTRATION_IP_SESSIONS_MAX,
	)
	config.registrationIPAttemptsBurst = clamp(
		config.registrationIPAttemptsBurst,
		0,
		REGISTRATION_IP_ATTEMPTS_BURST_MAX,
	)
	config.registrationIPAttemptsPerMinute = clamp(
		config.registrationIPAttemptsPerMinute,
		REGISTRATION_IP_ATTEMPTS_PER_MINUTE_MIN,
		REGISTRATION_IP_ATTEMPTS_PER_MINUTE_MAX,
	)
	config.registrationIPRequestsPerHour = clamp(
		config.registrationIPRequestsPerHour,
		0,
		REGISTRATION_IP_REQUESTS_PER_HOUR_MAX,
	)
}

// serverLogLevelIsDebug reports whether HAYCHAT_LOG_LEVEL asks for per-packet debug lines.
serverLogLevelIsDebug :: proc(logLevel: string) -> bool {
	return strings.equal_fold(strings.trim_space(logLevel), "debug")
}

validateAndNormalizeConfig :: proc(config: ^ServerConfig) {
	if config.databasePort <= 0 || config.databasePort > 65535 {
		config.databasePort = 5432
	}
	if config.maxRestarts < 0 {
		config.maxRestarts = 0
	}
	if config.maxNetworkThreads < 1 {
		config.maxNetworkThreads = 1
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

	if len(config.attachmentDir) == 0 {
		config.attachmentDir = DEFAULT_ATTACHMENT_DIR
	}

	ensureDirectoryPathExists(config.logPath)
	ensureDirectoryPathExists(config.fileStoragePath)
	ensureDirectoryPathExists(config.attachmentDir)
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

	if attachmentErr := attachmentDirectoryPreflightError(config); len(attachmentErr) > 0 {
		return attachmentErr
	}

	if len(config.adminPublicKey) > 0 {
		if _, ok := common.identityPublicKeyFromHex(config.adminPublicKey); !ok {
			return "startup preflight failed: HAYCHAT_ADMIN_PUBLIC_KEY must be a hex Ed25519 public key"
		}
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

// Checks the blob directory (D4): it must not be the state directory and must not contain the
// server identity file, so a sweep can never touch the server's key, and it must be writable.
// Creates incoming/ and blobs/ and makes all three mode 0700. Returns "" when it is usable.
attachmentDirectoryPreflightError :: proc(config: ServerConfig) -> string {
	if len(config.attachmentDir) == 0 {
		return "startup preflight failed: HAYCHAT_ATTACHMENT_DIR is empty"
	}
	if !os.exists(config.attachmentDir) {
		ensureDirectoryPathExists(config.attachmentDir)
	}
	attachmentAbs, attachmentErr := os.get_absolute_path(
		config.attachmentDir,
		context.temp_allocator,
	)
	if attachmentErr != nil {
		return fmt.aprintf(
			"startup preflight failed: attachment directory %q is not usable: %v",
			config.attachmentDir,
			attachmentErr,
		)
	}
	if storageAbs, storageErr := os.get_absolute_path(
		config.fileStoragePath,
		context.temp_allocator,
	); storageErr == nil && storageAbs == attachmentAbs {
		return fmt.aprintf(
			"startup preflight failed: HAYCHAT_ATTACHMENT_DIR %q must not be " +
			"HAYCHAT_FILE_STORAGE_PATH",
			config.attachmentDir,
		)
	}
	if identityDirAbs, identityOK := attachmentIdentityDirectory(config); identityOK {
		inside := strings.concatenate({attachmentAbs, "/"}, context.temp_allocator)
		if identityDirAbs == attachmentAbs || strings.has_prefix(identityDirAbs, inside) {
			return fmt.aprintf(
				"startup preflight failed: HAYCHAT_ATTACHMENT_DIR %q must not contain the " +
				"server identity file %q",
				config.attachmentDir,
				config.serverIdentityFilePath,
			)
		}
	}
	for name in ([]string{"", ATTACHMENT_INCOMING_DIR_NAME, ATTACHMENT_BLOBS_DIR_NAME}) {
		path := config.attachmentDir
		if len(name) > 0 {
			path = fmt.tprintf("%s/%s", config.attachmentDir, name)
			if !os.exists(path) {
				if err := os.make_directory(path, os.perm(0o700)); err != nil {
					return fmt.aprintf(
						"startup preflight failed: could not create %q: %v",
						path,
						err,
					)
				}
			}
		}
		if err := os.change_mode(path, os.perm(0o700)); err != nil {
			return fmt.aprintf(
				"startup preflight failed: could not make %q private (mode 0700): %v",
				path,
				err,
			)
		}
	}
	return startupProbeWriteError(config.attachmentDir, "attachment directory")
}

// The absolute directory that holds the server identity file, when it exists.
@(private = "file")
attachmentIdentityDirectory :: proc(config: ServerConfig) -> (string, bool) {
	identityDir := pathDirname(config.serverIdentityFilePath)
	if len(identityDir) == 0 {
		identityDir = "."
	}
	absolute, err := os.get_absolute_path(identityDir, context.temp_allocator)
	return absolute, err == nil
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

// Accepts true/false, 1/0, yes/no and on/off in any case; anything else is the default.
parseBoolOr :: proc(key: string, default_value: bool) -> bool {
	value := strings.trim_space(os.get_env(key, context.temp_allocator))
	for word in ([]string{"true", "1", "yes", "on"}) {
		if strings.equal_fold(value, word) {
			return true
		}
	}
	for word in ([]string{"false", "0", "no", "off"}) {
		if strings.equal_fold(value, word) {
			return false
		}
	}
	return default_value
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
