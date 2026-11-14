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
