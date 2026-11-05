package server

import "../common"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

configTestStorageConfig :: proc(storagePath: string) -> ServerConfig {
	config := ServerConfig {
		fileStoragePath = storagePath,
	}
	routerTestGenerateValidIdentityConfig(&config)
	config.webAdminTokenFilePath = fmt.aprintf("%s/%s", storagePath, DEFAULT_WEB_ADMIN_TOKEN_FILE_NAME)
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
testConfigStartupPreflightRejectsShortWebAdminToken :: proc(t: ^testing.T) {
	// ServerConfig is process-lifetime and never freed, so config tests run on the temp allocator.
	context.allocator = context.temp_allocator
	_ = t
	storagePath := routerTestCreateTempDir("haychat_config_short_token")
	defer os.remove_all(storagePath)

	config := configTestStorageConfig(storagePath)
	config.webAdminToken = "too-short"
	preflightErr := startupPreflightError(config)
	assert(
		strings.contains(preflightErr, "HAYCHAT_WEB_ADMIN_TOKEN"),
		fmt.tprintf("expected short web admin token to fail preflight, got %q", preflightErr),
	)
}

@(test)
testEnsureWebAdminTokenGeneratesPrivateFileAndReusesIt :: proc(t: ^testing.T) {
	// ServerConfig is process-lifetime and never freed, so config tests run on the temp allocator.
	context.allocator = context.temp_allocator
	_ = t
	storagePath := routerTestCreateTempDir("haychat_config_token_file")
	defer os.remove_all(storagePath)

	config := configTestStorageConfig(storagePath)
	tokenErr := ensureWebAdminToken(&config)
	assert(len(tokenErr) == 0, fmt.tprintf("expected token generation to succeed, got %q", tokenErr))
	assert(
		len(config.webAdminToken) >= WEB_ADMIN_TOKEN_MIN_LENGTH,
		fmt.tprintf("expected generated token length >= %d", WEB_ADMIN_TOKEN_MIN_LENGTH),
	)

	info, statErr := os.stat(config.webAdminTokenFilePath, context.temp_allocator)
	assert(statErr == nil, "expected generated token file to exist")
	assert(
		info.mode & os.Permissions_Read_Write_All == os.perm(0o600),
		fmt.tprintf("expected token file mode 0600, got %v", info.mode),
	)

	reloaded := configTestStorageConfig(storagePath)
	reloadErr := ensureWebAdminToken(&reloaded)
	assert(len(reloadErr) == 0, "expected persisted token reload to succeed")
	assert(
		reloaded.webAdminToken == config.webAdminToken,
		"expected restart to reuse the persisted web admin token",
	)
}

@(test)
testEnsureWebAdminTokenPrefersEnvironmentValue :: proc(t: ^testing.T) {
	// ServerConfig is process-lifetime and never freed, so config tests run on the temp allocator.
	context.allocator = context.temp_allocator
	_ = t
	storagePath := routerTestCreateTempDir("haychat_config_token_env")
	defer os.remove_all(storagePath)

	config := configTestStorageConfig(storagePath)
	config.webAdminToken = "0123456789abcdef0123456789abcdef"
	tokenErr := ensureWebAdminToken(&config)
	assert(len(tokenErr) == 0, "expected configured token to be accepted")
	assert(
		!os.exists(config.webAdminTokenFilePath),
		"expected configured token not to be written to disk",
	)
}

@(test)
testWebAdminAuthorizationRequiresExactBearerToken :: proc(t: ^testing.T) {
	_ = t
	token := "0123456789abcdef0123456789abcdef"
	assert(
		webAdminAuthorizationValid("Bearer 0123456789abcdef0123456789abcdef", token),
		"expected matching bearer token to be accepted",
	)
	assert(!webAdminAuthorizationValid("", token), "expected missing header to be rejected")
	assert(
		!webAdminAuthorizationValid("0123456789abcdef0123456789abcdef", token),
		"expected token without Bearer prefix to be rejected",
	)
	assert(
		!webAdminAuthorizationValid("Bearer 0123456789abcdef0123456789abcdee", token),
		"expected wrong token to be rejected",
	)
	assert(
		!webAdminAuthorizationValid("Bearer 0123456789abcdef", token),
		"expected token prefix to be rejected",
	)
	assert(!webAdminAuthorizationValid("Bearer ", ""), "expected empty expected token to deny")
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
testWebAdminStatusListsVoiceCounters :: proc(t: ^testing.T) {
	_ = t
	status := AdminQueryStatusResponse {
		voiceRooms        = 2,
		voiceParticipants = 5,
	}
	status.voiceRelay.datagramsIn = 100
	status.voiceRelay.framesRelayed = 90
	status.voiceRelay.datagramsOut = 360
	status.voiceRelay.drops[.RateLimited] = 7
	status.voiceRelay.drops[.BadTag] = 3
	text := webAdminFormatStatus(status, context.temp_allocator)
	for line in ([]string {
			"voice_rooms=2",
			"voice_participants=5",
			"voice_frames_in=100",
			"voice_frames_relayed=90",
			"voice_frames_out=360",
			"voice_send_failures=0",
			"voice_drops_rate_limited=7",
			"voice_drops_bad_tag=3",
			"voice_drops_bad_duration=0",
		}) {
		assert(
			strings.contains(text, fmt.tprintf("\n%s\n", line)) ||
			strings.has_suffix(text, fmt.tprintf("\n%s", line)),
			fmt.tprintf("expected /status to include %q, got:\n%s", line, text),
		)
	}
}
