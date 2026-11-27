package server

import "../common"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

configTestStorageConfig :: proc(storagePath: string) -> ServerConfig {
	config := ServerConfig {
		fileStoragePath = storagePath,
		attachmentDir   = fmt.tprintf("%s/attachments", storagePath),
	}
	routerTestGenerateValidIdentityConfig(&config)
	return config
}

@(test)
testConfigStartupPreflightRejectsInvalidAdminPublicKey :: proc(t: ^testing.T) {
	// ServerConfig is process-lifetime and never freed, so config tests run on the temp allocator.
	context.allocator = context.temp_allocator
	_ = t
	storagePath := routerTestCreateTempDir("haychat_config_admin_key")
	defer os.remove_all(storagePath)

	config := configTestStorageConfig(storagePath)
	config.adminPublicKey = "not-a-key"
	preflightErr := startupPreflightError(config)
	assert(
		strings.contains(preflightErr, "HAYCHAT_ADMIN_PUBLIC_KEY"),
		fmt.tprintf("expected invalid admin key to fail preflight, got %q", preflightErr),
	)

	_, adminPublicKey, keyOK := common.generateIdentityKeyPair()
	assert(keyOK, "expected admin key generation to succeed")
	config.adminPublicKey = common.identityPublicKeyToHex(adminPublicKey)
	preflightErr = startupPreflightError(config)
	assert(
		len(preflightErr) == 0,
		fmt.tprintf("expected valid admin key to pass preflight, got %q", preflightErr),
	)
}

@(test)
testDatabaseErrorResponsesOwnTheirStrings :: proc(t: ^testing.T) {
	_ = t
	// The router frees every response string, so literals here would crash the server.
	response := databaseExecuteRequest(nil, nil)
	assert(!response.success, "expected missing query type to fail")
	assert(
		response.message == "missing database query",
		fmt.tprintf("expected missing query type message, got %q", response.message),
	)
	IPC__database_query_response_deinit(response)
}

@(test)
testConfigLogLevelDebugGatesPerPacketLogs :: proc(t: ^testing.T) {
	_ = t
	assert(serverLogLevelIsDebug("debug"), "expected log level debug to enable debug lines")
	assert(serverLogLevelIsDebug(" DEBUG "), "expected level matching to ignore case and spaces")
	assert(!serverLogLevelIsDebug("info"), "expected the default level info to hide debug lines")
	assert(!serverLogLevelIsDebug(""), "expected an empty log level to disable debug lines")
}

@(test)
testConfigVoiceKeysDefaultParseAndClamp :: proc(t: ^testing.T) {
	// ServerConfig is process-lifetime and never freed, so config tests run on the temp allocator.
	context.allocator = context.temp_allocator
	_ = t
	keys := [?]string {
		"HAYCHAT_VOICE_ENABLED",
		"HAYCHAT_VOICE_MAX_PARTICIPANTS",
		"HAYCHAT_VOICE_MAX_PACKETS_PER_SECOND",
		"HAYCHAT_VOICE_MAX_FRAME_BYTES",
	}
	// Restore whatever the environment had, so the test leaves no trace.
	saved: [len(keys)]string
	for key, index in keys {
		saved[index] = os.get_env(key, context.temp_allocator)
	}
	defer for key, index in keys {
		if len(saved[index]) > 0 {
			os.set_env(key, saved[index])
		} else {
			os.unset_env(key)
		}
	}

	for key in keys {
		os.unset_env(key)
	}
	config: ServerConfig
	loadVoiceConfig(&config)
	assert(
		config.voiceEnabled == DEFAULT_VOICE_ENABLED &&
		config.voiceMaxParticipants == DEFAULT_VOICE_MAX_PARTICIPANTS &&
		config.voiceMaxPacketsPerSecond == DEFAULT_VOICE_MAX_PACKETS_PER_SECOND &&
		config.voiceMaxFrameBytes == DEFAULT_VOICE_MAX_FRAME_BYTES,
		fmt.tprintf("expected the voice defaults true/25/60/512, got %v", config),
	)

	os.set_env("HAYCHAT_VOICE_ENABLED", " Off ")
	os.set_env("HAYCHAT_VOICE_MAX_PARTICIPANTS", "8")
	os.set_env("HAYCHAT_VOICE_MAX_PACKETS_PER_SECOND", "75")
	os.set_env("HAYCHAT_VOICE_MAX_FRAME_BYTES", "128")
	loadVoiceConfig(&config)
	assert(
		!config.voiceEnabled &&
		config.voiceMaxParticipants == 8 &&
		config.voiceMaxPacketsPerSecond == 75 &&
		config.voiceMaxFrameBytes == 128,
		fmt.tprintf("expected false/8/75/128 from the environment, got %v", config),
	)

	// Out of range values clamp; an unparsable one falls back to the default.
	os.set_env("HAYCHAT_VOICE_ENABLED", "maybe")
	os.set_env("HAYCHAT_VOICE_MAX_PARTICIPANTS", "0")
	os.set_env("HAYCHAT_VOICE_MAX_PACKETS_PER_SECOND", "50000")
	os.set_env("HAYCHAT_VOICE_MAX_FRAME_BYTES", "1275")
	loadVoiceConfig(&config)
	assert(
		config.voiceEnabled == DEFAULT_VOICE_ENABLED &&
		config.voiceMaxParticipants == VOICE_MAX_PARTICIPANTS_MIN &&
		config.voiceMaxPacketsPerSecond == VOICE_MAX_PACKETS_PER_SECOND_MAX &&
		config.voiceMaxFrameBytes == common.VOICE_OPUS_MAX_BYTES,
		fmt.tprintf("expected default/1/1000/512 after clamping, got %v", config),
	)

	os.set_env("HAYCHAT_VOICE_MAX_PARTICIPANTS", "500")
	os.set_env("HAYCHAT_VOICE_MAX_PACKETS_PER_SECOND", "-3")
	os.set_env("HAYCHAT_VOICE_MAX_FRAME_BYTES", "12")
	loadVoiceConfig(&config)
	assert(
		config.voiceMaxParticipants == VOICE_MAX_PARTICIPANTS_MAX &&
		config.voiceMaxPacketsPerSecond == VOICE_MAX_PACKETS_PER_SECOND_MIN &&
		config.voiceMaxFrameBytes == VOICE_MAX_FRAME_BYTES_MIN,
		fmt.tprintf("expected 200/1/64 after clamping, got %v", config),
	)
}

@(test)
testConfigRetiredVariablesAreReportedOnlyWhenSet :: proc(t: ^testing.T) {
	_ = t
	// Restore whatever the environment had, so the test leaves no trace.
	saved: [len(RETIRED_CONFIG_VARIABLES)]string
	for key, index in RETIRED_CONFIG_VARIABLES {
		saved[index] = os.get_env(key, context.temp_allocator)
	}
	defer for key, index in RETIRED_CONFIG_VARIABLES {
		if len(saved[index]) > 0 {
			os.set_env(key, saved[index])
		} else {
			os.unset_env(key)
		}
	}

	for key in RETIRED_CONFIG_VARIABLES {
		os.unset_env(key)
	}
	unset := retiredConfigVariablesSet()
	defer delete(unset)
	assert(
		len(unset) == 0,
		fmt.tprintf("expected no retired variables when none are set, got %v", unset[:]),
	)

	os.set_env("HAYCHAT_MAX_FILE_SIZE", "10485760")
	set := retiredConfigVariablesSet()
	defer delete(set)
	assert(
		len(set) == 1 && set[0] == "HAYCHAT_MAX_FILE_SIZE",
		fmt.tprintf("expected only HAYCHAT_MAX_FILE_SIZE to be reported, got %v", set[:]),
	)
}

@(test)
testConfigAttachmentKeysClamp :: proc(t: ^testing.T) {
	_ = t
	config := ServerConfig {
		attachmentMaxBytes              = 1,
		attachmentAccountQuotaBytes     = -5,
		attachmentUploadBytesPerHour    = ATTACHMENT_UPLOAD_BYTES_PER_HOUR_MAX + 1,
		attachmentCapacityBytes         = -1,
		attachmentMinFreeBytes          = -1,
		attachmentPendingHours          = 0,
		attachmentSessionBytesPerSecond = 1,
	}
	validateAttachmentConfig(&config)
	assert(config.attachmentMaxBytes == ATTACHMENT_MAX_BYTES_MIN, "expected the size clamped up")
	assert(config.attachmentAccountQuotaBytes == 0, "expected a negative quota to mean none")
	assert(
		config.attachmentUploadBytesPerHour == ATTACHMENT_UPLOAD_BYTES_PER_HOUR_MAX,
		"expected the hourly limit clamped down",
	)
	assert(config.attachmentCapacityBytes == 0, "expected a negative capacity to mean none")
	assert(config.attachmentMinFreeBytes == 0, "expected a negative reserve to be none")
	assert(
		config.attachmentPendingHours == ATTACHMENT_PENDING_HOURS_MIN,
		"expected the pending window to stay at least the sweeper's hour",
	)
	assert(
		config.attachmentSessionBytesPerSecond == ATTACHMENT_SESSION_BYTES_PER_SECOND_MIN,
		"expected the session pace clamped up",
	)

	defaults := ServerConfig {
		attachmentMaxBytes              = DEFAULT_ATTACHMENT_MAX_BYTES,
		attachmentAccountQuotaBytes     = DEFAULT_ATTACHMENT_ACCOUNT_QUOTA_BYTES,
		attachmentUploadBytesPerHour    = DEFAULT_ATTACHMENT_UPLOAD_BYTES_PER_HOUR,
		attachmentCapacityBytes         = DEFAULT_ATTACHMENT_CAPACITY_BYTES,
		attachmentMinFreeBytes          = DEFAULT_ATTACHMENT_MIN_FREE_BYTES,
		attachmentPendingHours          = DEFAULT_ATTACHMENT_PENDING_HOURS,
		attachmentSessionBytesPerSecond = DEFAULT_ATTACHMENT_SESSION_BYTES_PER_SECOND,
	}
	kept := defaults
	validateAttachmentConfig(&kept)
	assert(kept == defaults, "expected the defaults inside their ranges")
	assert(
		DEFAULT_ATTACHMENT_MAX_BYTES == 25 * 1024 * 1024 &&
		DEFAULT_ATTACHMENT_ACCOUNT_QUOTA_BYTES == 1024 * 1024 * 1024 &&
		DEFAULT_ATTACHMENT_UPLOAD_BYTES_PER_HOUR == 512 * 1024 * 1024 &&
		DEFAULT_ATTACHMENT_MIN_FREE_BYTES == 1024 * 1024 * 1024 &&
		DEFAULT_ATTACHMENT_SESSION_BYTES_PER_SECOND == 4 * 1024 * 1024,
		"expected the plan's default limits (D21)",
	)
}

// The startup scan's override (#131): off by default, parsed like the other booleans, and
// documented under the name the server reads.
@(test)
testConfigAttachmentAllowOrphanPurgeDefaultParseAndDocs :: proc(t: ^testing.T) {
	// ServerConfig is process-lifetime and never freed, so config tests run on the temp allocator.
	context.allocator = context.temp_allocator
	_ = t
	assert(
		ATTACHMENT_ALLOW_ORPHAN_PURGE_KEY == "HAYCHAT_ATTACHMENT_ALLOW_ORPHAN_PURGE",
		"expected the documented variable name",
	)
	assert(!DEFAULT_ATTACHMENT_ALLOW_ORPHAN_PURGE, "expected the override off by default")
	saved := os.get_env(ATTACHMENT_ALLOW_ORPHAN_PURGE_KEY, context.temp_allocator)
	defer if len(saved) > 0 {
		os.set_env(ATTACHMENT_ALLOW_ORPHAN_PURGE_KEY, saved)
	} else {
		os.unset_env(ATTACHMENT_ALLOW_ORPHAN_PURGE_KEY)
	}

	config: ServerConfig
	os.unset_env(ATTACHMENT_ALLOW_ORPHAN_PURGE_KEY)
	loadAttachmentConfig(&config)
	assert(!config.attachmentAllowOrphanPurge, "expected no override without the variable")
	for value in ([]string{"1", " true ", "YES", "on"}) {
		os.set_env(ATTACHMENT_ALLOW_ORPHAN_PURGE_KEY, value)
		loadAttachmentConfig(&config)
		assert(
			config.attachmentAllowOrphanPurge,
			fmt.tprintf("expected %q to allow the purge", value),
		)
	}
	for value in ([]string{"0", "false", "off", "maybe", ""}) {
		os.set_env(ATTACHMENT_ALLOW_ORPHAN_PURGE_KEY, value)
		loadAttachmentConfig(&config)
		assert(
			!config.attachmentAllowOrphanPurge,
			fmt.tprintf("expected %q to leave the purge off", value),
		)
	}

	documented := [?]string {
		#load("../docs/server-configuration.md", string),
		#load("../.env.example", string),
		#load("../deploy/README.md", string),
	}
	for text, index in documented {
		assert(
			strings.contains(text, ATTACHMENT_ALLOW_ORPHAN_PURGE_KEY),
			fmt.tprintf("expected document %d to name %s", index, ATTACHMENT_ALLOW_ORPHAN_PURGE_KEY),
		)
	}
}

@(test)
testConfigStartupRefusesAnAttachmentDirectoryHoldingTheServerState :: proc(t: ^testing.T) {
	// ServerConfig is process-lifetime and never freed, so config tests run on the temp allocator.
	context.allocator = context.temp_allocator
	_ = t
	storagePath := routerTestCreateTempDir("haychat_config_attachment_dir")
	defer os.remove_all(storagePath)

	config := configTestStorageConfig(storagePath)
	config.serverIdentityFilePath = fmt.tprintf("%s/server_identity.json", storagePath)
	ok := startupPreflightError(config)
	assert(
		len(ok) == 0,
		fmt.tprintf("expected a separate attachment directory to pass, got %q", ok),
	)
	attachmentDir := config.attachmentDir
	for name in ([]string{"", "/incoming", "/blobs"}) {
		path := fmt.tprintf("%s%s", attachmentDir, name)
		info, err := os.stat(path, context.temp_allocator)
		assert(err == nil, fmt.tprintf("expected %q to exist", path))
		assert(
			int(transmute(u32)info.mode) & 0o777 == 0o700,
			fmt.tprintf("expected %q to be mode 0700", path),
		)
	}

	config.attachmentDir = storagePath
	same := startupPreflightError(config)
	assert(
		strings.contains(same, "must not be HAYCHAT_FILE_STORAGE_PATH"),
		fmt.tprintf("expected the state directory refused, got %q", same),
	)

	// The identity file inside the attachment directory, with the state directory elsewhere.
	config.attachmentDir = attachmentDir
	config.serverIdentityFilePath = fmt.tprintf("%s/keys/server_identity.json", attachmentDir)
	assert(os.make_directory(fmt.tprintf("%s/keys", attachmentDir)) == nil, "expected a dir")
	contains := startupPreflightError(config)
	assert(
		strings.contains(contains, "must not contain the server identity file"),
		fmt.tprintf(
			"expected an attachment directory holding the identity refused, got %q",
			contains,
		),
	)
}

// #105: the per-address sign-up limits default, parse, clamp, and are documented under the
// names the server reads.
@(test)
testConfigRegistrationLimitKeysDefaultParseAndClamp :: proc(t: ^testing.T) {
	// ServerConfig is process-lifetime and never freed, so config tests run on the temp allocator.
	context.allocator = context.temp_allocator
	_ = t
	keys := [?]string {
		REGISTRATION_IP_SESSIONS_KEY,
		REGISTRATION_IP_ATTEMPTS_BURST_KEY,
		REGISTRATION_IP_ATTEMPTS_PER_MINUTE_KEY,
		REGISTRATION_IP_REQUESTS_PER_HOUR_KEY,
	}
	// Restore whatever the environment had, so the test leaves no trace.
	saved: [len(keys)]string
	for key, index in keys {
		saved[index] = os.get_env(key, context.temp_allocator)
	}
	defer for key, index in keys {
		if len(saved[index]) > 0 {
			os.set_env(key, saved[index])
		} else {
			os.unset_env(key)
		}
	}

	for key in keys {
		os.unset_env(key)
	}
	config: ServerConfig
	loadRegistrationLimitConfig(&config)
	assert(
		config.registrationIPSessions == 8 &&
		config.registrationIPAttemptsBurst == 30 &&
		config.registrationIPAttemptsPerMinute == 10 &&
		config.registrationIPRequestsPerHour == 10,
		fmt.tprintf("expected the defaults 8/30/10/10, got %v", config),
	)
	assert(
		DEFAULT_REGISTRATION_IP_SESSIONS < common.REGISTERING_SESSIONS_MAX,
		"expected one address's default share below every registering session",
	)

	os.set_env(REGISTRATION_IP_SESSIONS_KEY, "16")
	os.set_env(REGISTRATION_IP_ATTEMPTS_BURST_KEY, "lots")
	os.set_env(REGISTRATION_IP_ATTEMPTS_PER_MINUTE_KEY, "120")
	os.set_env(REGISTRATION_IP_REQUESTS_PER_HOUR_KEY, "0")
	loadRegistrationLimitConfig(&config)
	assert(
		config.registrationIPSessions == 16 &&
		config.registrationIPAttemptsBurst == DEFAULT_REGISTRATION_IP_ATTEMPTS_BURST &&
		config.registrationIPAttemptsPerMinute == 120 &&
		config.registrationIPRequestsPerHour == 0,
		fmt.tprintf("expected 16/default (unparsable)/120/0 from the environment, got %v", config),
	)

	// Out of range values clamp; an unparsable one falls back to the default.
	os.set_env(REGISTRATION_IP_SESSIONS_KEY, "500")
	os.set_env(REGISTRATION_IP_ATTEMPTS_BURST_KEY, "-4")
	os.set_env(REGISTRATION_IP_ATTEMPTS_PER_MINUTE_KEY, "0")
	os.set_env(REGISTRATION_IP_REQUESTS_PER_HOUR_KEY, "many")
	loadRegistrationLimitConfig(&config)
	assert(
		config.registrationIPSessions == common.REGISTERING_SESSIONS_MAX &&
		config.registrationIPAttemptsBurst == 0 &&
		config.registrationIPAttemptsPerMinute == REGISTRATION_IP_ATTEMPTS_PER_MINUTE_MIN &&
		config.registrationIPRequestsPerHour == DEFAULT_REGISTRATION_IP_REQUESTS_PER_HOUR,
		fmt.tprintf("expected 64/0/1/default after clamping, got %v", config),
	)

	os.set_env(REGISTRATION_IP_SESSIONS_KEY, "-1")
	os.set_env(REGISTRATION_IP_ATTEMPTS_BURST_KEY, "50000")
	os.set_env(REGISTRATION_IP_ATTEMPTS_PER_MINUTE_KEY, "50000")
	os.set_env(REGISTRATION_IP_REQUESTS_PER_HOUR_KEY, "50000")
	loadRegistrationLimitConfig(&config)
	assert(
		config.registrationIPSessions == 0 &&
		config.registrationIPAttemptsBurst == REGISTRATION_IP_ATTEMPTS_BURST_MAX &&
		config.registrationIPAttemptsPerMinute == REGISTRATION_IP_ATTEMPTS_PER_MINUTE_MAX &&
		config.registrationIPRequestsPerHour == REGISTRATION_IP_REQUESTS_PER_HOUR_MAX,
		fmt.tprintf("expected 0/10000/10000/10000 after clamping, got %v", config),
	)

	documented := [?]string {
		#load("../docs/server-configuration.md", string),
		#load("../.env.example", string),
	}
	for text, index in documented {
		for key in keys {
			assert(
				strings.contains(text, key),
				fmt.tprintf("expected document %d to name %s", index, key),
			)
		}
	}
}
