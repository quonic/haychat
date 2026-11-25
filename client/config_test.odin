package client

import "../common"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

configTestMutex: sync.Mutex

ConfigTestEnvSnapshot :: struct {
	home:                string,
	xdgConfigHome:       string,
	appData:             string,
	globalXdgConfigHome: string,
	globalAppData:       string,
}

configTestJoinPath :: proc(parts: []string) -> string {
	path, err := filepath.join(parts, context.temp_allocator)
	assert(err == nil, "expected test path join to succeed")
	return path
}

configTestCreateTempDir :: proc(prefix: string) -> string {
	tempRoot, tempRootErr := os.temp_directory(context.temp_allocator)
	assert(tempRootErr == nil, "expected temp directory lookup to succeed")

	tempPath := configTestJoinPath(
		{tempRoot, fmt.tprintf("%s_%d", prefix, time.time_to_unix_nano(time.now()))},
	)
	makeErr := os.make_directory(tempPath)
	assert(makeErr == nil, "expected temp directory creation to succeed")
	return tempPath
}

configTestRemovePathIfExists :: proc(path: string) {
	if len(path) == 0 || !os.exists(path) {
		return
	}
	removeErr := os.remove_all(path)
	assert(removeErr == nil, "expected test path removal to succeed")
}

configTestCaptureEnv :: proc() -> ConfigTestEnvSnapshot {
	return ConfigTestEnvSnapshot {
		home = os.get_env("HOME", context.temp_allocator),
		xdgConfigHome = os.get_env("XDG_CONFIG_HOME", context.temp_allocator),
		appData = os.get_env("APPDATA", context.temp_allocator),
		globalXdgConfigHome = XDG_CONFIG_HOME,
		globalAppData = APP_DATA,
	}
}

configTestSetEnv :: proc(key, value: string) {
	if len(value) == 0 {
		_ = os.unset_env(key)
		return
	}

	err := os.set_env(key, value)
	assert(err == nil, "expected test env update to succeed")
}

configTestRestoreEnv :: proc(snapshot: ConfigTestEnvSnapshot) {
	configTestSetEnv("HOME", snapshot.home)
	configTestSetEnv("XDG_CONFIG_HOME", snapshot.xdgConfigHome)
	configTestSetEnv("APPDATA", snapshot.appData)
	XDG_CONFIG_HOME = snapshot.globalXdgConfigHome
	APP_DATA = snapshot.globalAppData
}

configTestExpectedCurrentLinuxConfigPath :: proc(configHome: string) -> string {
	return strings.concatenate({configHome, "/haychat/config.json"}, context.temp_allocator)
}

configTestExpectedHistoricalLegacyLinuxConfigDir :: proc(home, configHome: string) -> string {
	return strings.concatenate({home, configHome, "/haychat"}, context.temp_allocator)
}

configTestExpectedHistoricalLegacyLinuxConfigPath :: proc(home, configHome: string) -> string {
	return strings.concatenate(
		{home, configHome, "/haychat/config.json"},
		context.temp_allocator,
	)
}

@(test)
testLegacyLinuxConfigPathUsesHistoricalDefaultHomeConfig :: proc(t: ^testing.T) {
	when ODIN_OS != .Linux {
		_ = t
		return
	}

	sync.mutex_lock(&configTestMutex)
	defer sync.mutex_unlock(&configTestMutex)

	snapshot := configTestCaptureEnv()
	defer configTestRestoreEnv(snapshot)

	tempDir := configTestCreateTempDir("hc109_client_config_path")
	defer configTestRemovePathIfExists(tempDir)

	homeDir := configTestJoinPath({tempDir, "home"})
	customXdgDir := configTestJoinPath({tempDir, "custom_xdg"})
	assert(os.make_directory(homeDir) == nil, "expected test home directory creation to succeed")
	assert(
		os.make_directory(customXdgDir) == nil,
		"expected custom XDG directory creation to succeed",
	)

	configTestSetEnv("HOME", homeDir)
	configTestSetEnv("XDG_CONFIG_HOME", customXdgDir)
	XDG_CONFIG_HOME = os.get_env("XDG_CONFIG_HOME", context.temp_allocator)

	legacyPath := getLegacyLinuxConfigPath()
	defer delete(legacyPath)
	currentPath := getConfigPath()
	defer delete(currentPath)
	expectedLegacyPath := configTestExpectedHistoricalLegacyLinuxConfigPath(homeDir, customXdgDir)
	expectedCurrentPath := configTestExpectedCurrentLinuxConfigPath(customXdgDir)

	testing.expect(
		t,
		legacyPath == expectedLegacyPath,
		fmt.tprintf("expected legacy config path %q, got %q", expectedLegacyPath, legacyPath),
	)
	testing.expect(
		t,
		currentPath == expectedCurrentPath,
		fmt.tprintf("expected current config path %q, got %q", expectedCurrentPath, currentPath),
	)

	_ = t
}

@(test)
testLoadConfigMigratesHistoricalLegacyLinuxConfigToCurrentXdgPath :: proc(t: ^testing.T) {
	when ODIN_OS != .Linux {
		_ = t
		return
	}

	sync.mutex_lock(&configTestMutex)
	defer sync.mutex_unlock(&configTestMutex)

	snapshot := configTestCaptureEnv()
	defer configTestRestoreEnv(snapshot)

	tempDir := configTestCreateTempDir("hc109_client_config_migration")
	defer configTestRemovePathIfExists(tempDir)

	homeDir := configTestJoinPath({tempDir, "home"})
	customXdgDir := configTestJoinPath({tempDir, "custom_xdg"})
	assert(os.make_directory(homeDir) == nil, "expected test home directory creation to succeed")
	assert(
		os.make_directory(customXdgDir) == nil,
		"expected custom XDG directory creation to succeed",
	)

	configTestSetEnv("HOME", homeDir)
	configTestSetEnv("XDG_CONFIG_HOME", customXdgDir)
	XDG_CONFIG_HOME = ""
	APP_DATA = ""

	legacyPath := configTestExpectedHistoricalLegacyLinuxConfigPath(homeDir, customXdgDir)
	legacyDir := configTestExpectedHistoricalLegacyLinuxConfigDir(homeDir, customXdgDir)
	currentPath := configTestExpectedCurrentLinuxConfigPath(customXdgDir)
	assert(
		os.make_directory_all(legacyDir) == nil,
		"expected legacy config directory creation to succeed",
	)
	legacyConfig := Config {
		display_name = "Legacy Linux Tester",
		servers      = {},
	}
	legacyJSON, legacyJSONErr := json.marshal(legacyConfig, allocator = context.temp_allocator)
	assert(legacyJSONErr == nil, "expected legacy config JSON encode to succeed")
	assert(
		os.write_entire_file_from_bytes(legacyPath, legacyJSON) == nil,
		"expected legacy config write to succeed",
	)

	loadedConfig := loadConfig()
	defer Config_deinit(&loadedConfig)
	// loadConfig allocates the process-lifetime XDG_CONFIG_HOME global; release it per test.
	defer delete(XDG_CONFIG_HOME)

	testing.expect(
		t,
		loadedConfig.display_name == "Legacy Linux Tester",
		fmt.tprintf(
			"expected migrated config to preserve display name, got %q",
			loadedConfig.display_name,
		),
	)
	testing.expect(
		t,
		os.exists(currentPath),
		"expected migrated config to be written to the current XDG path",
	)

	persistedBytes, persistedErr := os.read_entire_file_from_path(
		currentPath,
		context.temp_allocator,
	)
	assert(persistedErr == nil, "expected migrated config read to succeed")

	persistedConfig: Config
	json.unmarshal(persistedBytes, &persistedConfig)
	defer Config_deinit(&persistedConfig)
	testing.expect(
		t,
		persistedConfig.display_name == "Legacy Linux Tester",
		fmt.tprintf(
			"expected persisted migrated config to preserve display name, got %q",
			persistedConfig.display_name,
		),
	)

	_ = t
}

@(test)
testLoadConfigMigratesHistoricalLegacyLinuxConfigFromDefaultConfigHome :: proc(t: ^testing.T) {
	when ODIN_OS != .Linux {
		_ = t
		return
	}

	sync.mutex_lock(&configTestMutex)
	defer sync.mutex_unlock(&configTestMutex)

	snapshot := configTestCaptureEnv()
	defer configTestRestoreEnv(snapshot)

	tempDir := configTestCreateTempDir("hc109_client_config_default_migration")
	defer configTestRemovePathIfExists(tempDir)

	homeDir := configTestJoinPath({tempDir, "home"})
	assert(os.make_directory(homeDir) == nil, "expected test home directory creation to succeed")

	defaultConfigHome := configTestJoinPath({homeDir, ".config"})
	configTestSetEnv("HOME", homeDir)
	configTestSetEnv("XDG_CONFIG_HOME", "")
	XDG_CONFIG_HOME = ""
	APP_DATA = ""

	legacyPath := configTestExpectedHistoricalLegacyLinuxConfigPath(homeDir, defaultConfigHome)
	legacyDir := configTestExpectedHistoricalLegacyLinuxConfigDir(homeDir, defaultConfigHome)
	currentPath := configTestExpectedCurrentLinuxConfigPath(defaultConfigHome)
	assert(
		os.make_directory_all(legacyDir) == nil,
		"expected legacy config directory creation to succeed",
	)

	legacyConfig := Config {
		display_name = "Default Linux Tester",
		servers      = {},
	}
	legacyJSON, legacyJSONErr := json.marshal(legacyConfig, allocator = context.temp_allocator)
	assert(legacyJSONErr == nil, "expected legacy config JSON encode to succeed")
	assert(
		os.write_entire_file_from_bytes(legacyPath, legacyJSON) == nil,
		"expected legacy config write to succeed",
	)

	loadedConfig := loadConfig()
	defer Config_deinit(&loadedConfig)
	// loadConfig allocates the process-lifetime XDG_CONFIG_HOME global; release it per test.
	defer delete(XDG_CONFIG_HOME)

	testing.expect(
		t,
		loadedConfig.display_name == "Default Linux Tester",
		fmt.tprintf(
			"expected migrated config to preserve display name, got %q",
			loadedConfig.display_name,
		),
	)
	testing.expect(
		t,
		os.exists(currentPath),
		"expected migrated config to be written to the default XDG path",
	)

	_ = t
}

// Configs written before direct messages existed carry a placeholder `friends` list. The key
// is no longer part of Config, so loading must skip it and keep everything else.
@(test)
testConfigWithRemovedFriendsKeyStillLoads :: proc(t: ^testing.T) {
	data := `{"display_name":"Old Tester","servers":[{"id":3,"name":"Old","short_name":"O",` +
		`"host":"example.org","port":12345}],"friends":[{"id":1,"display_name":"New Friend",` +
		`"public_key":"x","servers":[3],"status":"Online"}]}`
	config: Config
	err := json.unmarshal(transmute([]u8)data, &config)
	defer Config_deinit(&config)
	assert(err == nil, fmt.tprintf("expected the old config to load, got %v", err))
	assert(
		config.display_name == "Old Tester",
		fmt.tprintf("expected display name Old Tester, got %q", config.display_name),
	)
	assert(
		len(config.servers) == 1 && config.servers[0].host == "example.org",
		fmt.tprintf("expected the one saved server, got %v", config.servers),
	)
	_ = t
}

// A config without voice keys (written before voice existed, or a Config literal) gives the
// design's defaults (voice-rooms-design.md 5.3).
@(test)
testVoiceConfigKeysDefaultWhenMissing :: proc(t: ^testing.T) {
	data := `{"display_name":"Old Tester","servers":[]}`
	config: Config
	err := json.unmarshal(transmute([]u8)data, &config)
	defer Config_deinit(&config)
	assert(err == nil, fmt.tprintf("expected the config to load, got %v", err))
	settings := Config_voiceSettings(config)
	assert(
		settings.inputDevice == "" &&
		settings.outputDevice == "" &&
		settings.mode == .VoiceActivity &&
		settings.pttKey == "Left Ctrl" &&
		settings.vadThresholdDB == -45 &&
		settings.inputGain == 1 &&
		settings.outputVolume == 1 &&
		settings.bitrate == 24000,
		fmt.tprintf("expected the default voice settings, got %v", settings),
	)
	assert(
		Config_voiceSettings(Config{}) == settings,
		"expected a Config literal to give the same defaults",
	)
	_ = t
}

// Every key is read, numbers are clamped to their ranges, and invalid values fall back to the
// default instead of breaking voice.
@(test)
testVoiceConfigKeysAreValidatedAndClamped :: proc(t: ^testing.T) {
	data :=
		`{"voice_input_device":"USB Mic","voice_output_device":"Headset",` +
		`"voice_mode":"push_to_talk","voice_ptt_key":"Space","voice_vad_threshold_db":-30.5,` +
		`"voice_input_gain":0,"voice_output_volume":1.5,"voice_bitrate":32000}`
	config: Config
	err := json.unmarshal(transmute([]u8)data, &config)
	defer Config_deinit(&config)
	assert(err == nil, fmt.tprintf("expected the voice keys to load, got %v", err))
	settings := Config_voiceSettings(config)
	assert(
		settings.inputDevice == "USB Mic" &&
		settings.outputDevice == "Headset" &&
		settings.mode == .PushToTalk &&
		settings.pttKey == "Space" &&
		settings.vadThresholdDB == -30.5 &&
		settings.inputGain == 0 &&
		settings.outputVolume == 1.5 &&
		settings.bitrate == 32000,
		fmt.tprintf("expected every voice key read, a gain of 0 included, got %v", settings),
	)

	high := Config {
		voice_mode             = "shout",
		voice_ptt_key          = "Bad\nKey",
		voice_vad_threshold_db = f32(12),
		voice_input_gain       = f32(9),
		voice_output_volume    = f32(-1),
		voice_bitrate          = 1_000_000,
	}
	clamped := Config_voiceSettings(high)
	assert(
		clamped.mode == .VoiceActivity &&
		clamped.pttKey == "Left Ctrl" &&
		clamped.vadThresholdDB == 0 &&
		clamped.inputGain == 4 &&
		clamped.outputVolume == 0 &&
		clamped.bitrate == 64000,
		fmt.tprintf("expected clamped values and default strings, got %v", clamped),
	)
	low := Config {
		voice_vad_threshold_db = f32(-200),
		voice_bitrate          = 100,
	}
	lowClamped := Config_voiceSettings(low)
	assert(
		lowClamped.vadThresholdDB == -80 && lowClamped.bitrate == 12000,
		fmt.tprintf("expected the low ends of the ranges, got %v", lowClamped),
	)
	_ = t
}

// Saved settings round-trip through config.json, defaults are stored as unset (so a changed
// default still reaches the user), and the clone keeps every voice key.
@(test)
testVoiceConfigKeysRoundTripAndStoreDefaultsAsUnset :: proc(t: ^testing.T) {
	config: Config
	defer Config_deinit(&config)
	Config_setVoiceSettings(&config, VOICE_DEFAULT_SETTINGS)
	defaultJSON, defaultErr := json.marshal(config)
	defer delete(defaultJSON)
	assert(defaultErr == nil, "expected the default config to marshal")
	assert(
		!strings.contains(string(defaultJSON), "voice_"),
		fmt.tprintf("expected no voice keys for the defaults, got %s", string(defaultJSON)),
	)

	chosen := VoiceSettings {
		inputDevice    = "USB Mic",
		outputDevice   = "",
		mode           = .PushToTalk,
		pttKey         = "Right Alt",
		vadThresholdDB = -52,
		inputGain      = 0,
		outputVolume   = 1,
		bitrate        = 40000,
	}
	Config_setVoiceSettings(&config, chosen)
	assert(
		config.voice_output_volume == nil && config.voice_output_device == "",
		"expected the default output volume and device stored as unset",
	)
	data, marshalErr := json.marshal(config)
	defer delete(data)
	assert(marshalErr == nil, "expected the voice config to marshal")
	loaded: Config
	defer Config_deinit(&loaded)
	unmarshalErr := json.unmarshal(data, &loaded)
	assert(unmarshalErr == nil, fmt.tprintf("expected %s to load, got %v", data, unmarshalErr))
	expected := voiceSettingsValidate(chosen)
	assert(
		Config_voiceSettings(loaded) == expected,
		fmt.tprintf(
			"expected %v back from %s, got %v",
			expected,
			data,
			Config_voiceSettings(loaded),
		),
	)

	clone := Config_clone(loaded)
	defer Config_deinit(&clone)
	assert(
		Config_voiceSettings(clone) == expected,
		"expected Config_clone to keep every voice key",
	)
	// Setting values from the config's own strings must not read freed memory.
	Config_setVoiceSettings(&clone, Config_voiceSettings(clone))
	assert(
		Config_voiceSettings(clone) == expected,
		"expected re-applying the config's own settings to change nothing",
	)
	_ = t
}

// Loads the profile under configHome the way the client starts, and frees the XDG_CONFIG_HOME
// copy loadConfig allocates, so a test can load the same profile several times.
@(private = "file")
configTestLoadFrom :: proc(configHome: string) -> Config {
	configTestSetEnv("XDG_CONFIG_HOME", configHome)
	XDG_CONFIG_HOME = ""
	config := loadConfig()
	delete(XDG_CONFIG_HOME)
	XDG_CONFIG_HOME = ""
	return config
}

// Rewrites device_id in configHome's config.json; an empty value removes the key.
@(private = "file")
configTestSetStoredDeviceID :: proc(configHome: string, deviceID: string) {
	path := configTestExpectedCurrentLinuxConfigPath(configHome)
	data, readErr := os.read_entire_file_from_path(path, context.temp_allocator)
	assert(readErr == nil, "expected the saved config to be readable")
	stored: Config
	defer Config_deinit(&stored)
	assert(json.unmarshal(data, &stored) == nil, "expected the saved config to parse")
	delete(stored.device_id)
	stored.device_id = strings.clone(deviceID)
	encoded, encodeErr := json.marshal(stored, allocator = context.temp_allocator)
	assert(encodeErr == nil, "expected the edited config to encode")
	assert(os.write_entire_file_from_bytes(path, encoded) == nil, "expected the config written")
}

// The voice device ID (protocol 13) is generated once per profile and saved, survives a save
// and a load, comes back new when it is missing or malformed, and differs between profiles that
// share an identity key.
@(test)
testDeviceIDIsGeneratedOnceAndSurvivesSaveAndLoad :: proc(t: ^testing.T) {
	when ODIN_OS != .Linux {
		_ = t
		return
	}

	sync.mutex_lock(&configTestMutex)
	defer sync.mutex_unlock(&configTestMutex)
	snapshot := configTestCaptureEnv()
	defer configTestRestoreEnv(snapshot)
	tempDir := configTestCreateTempDir("hc_client_device_id")
	defer configTestRemovePathIfExists(tempDir)
	configHome := configTestJoinPath({tempDir, "xdg"})
	otherHome := configTestJoinPath({tempDir, "other_xdg"})
	assert(os.make_directory(configHome) == nil, "expected the XDG directory created")
	assert(os.make_directory(otherHome) == nil, "expected the other XDG directory created")
	// loadConfig also looks for a legacy profile under HOME; keep that inside the test too.
	configTestSetEnv("HOME", tempDir)

	first := configTestLoadFrom(configHome)
	defer Config_deinit(&first)
	testing.expectf(
		t,
		common.voiceDeviceIDIsValid(first.device_id),
		"expected a new profile to get a valid device ID, got %q",
		first.device_id,
	)

	second := configTestLoadFrom(configHome)
	defer Config_deinit(&second)
	testing.expect(t, second.device_id == first.device_id, "expected the same ID after a load")

	// Saving and loading again, as every settings change does, keeps it.
	saveTarget := Config_clone(second)
	defer Config_deinit(&saveTarget)
	testing.expect(t, saveTarget.device_id == first.device_id, "expected the clone to keep it")
	configTestSetEnv("XDG_CONFIG_HOME", configHome)
	XDG_CONFIG_HOME = configHome
	saveConfig(saveTarget)
	XDG_CONFIG_HOME = ""
	saved := configTestLoadFrom(configHome)
	defer Config_deinit(&saved)
	testing.expect(t, saved.device_id == first.device_id, "expected the ID to survive a save")

	// A malformed or missing value is replaced and saved.
	configTestSetStoredDeviceID(configHome, "NOT-A-DEVICE-ID")
	repaired := configTestLoadFrom(configHome)
	defer Config_deinit(&repaired)
	testing.expectf(
		t,
		common.voiceDeviceIDIsValid(repaired.device_id) && repaired.device_id != first.device_id,
		"expected a malformed ID replaced by a new one, got %q",
		repaired.device_id,
	)
	reloaded := configTestLoadFrom(configHome)
	defer Config_deinit(&reloaded)
	testing.expect(t, reloaded.device_id == repaired.device_id, "expected the new ID saved")
	configTestSetStoredDeviceID(configHome, "")
	reset := configTestLoadFrom(configHome)
	defer Config_deinit(&reset)
	testing.expect(
		t,
		common.voiceDeviceIDIsValid(reset.device_id) && reset.device_id != repaired.device_id,
		"expected deleting the key to reset the ID",
	)

	// Another profile with the same identity key is another device.
	otherPath := configTestExpectedCurrentLinuxConfigPath(otherHome)
	assert(os.make_directory_all(configTestJoinPath({otherHome, "haychat"})) == nil, "mkdir")
	shared := Config {
		private_key = reset.private_key,
		public_key  = reset.public_key,
	}
	sharedJSON, sharedErr := json.marshal(shared, allocator = context.temp_allocator)
	assert(sharedErr == nil, "expected the shared-key profile to encode")
	assert(os.write_entire_file_from_bytes(otherPath, sharedJSON) == nil, "expected it written")
	other := configTestLoadFrom(otherHome)
	defer Config_deinit(&other)
	testing.expectf(
		t,
		other.public_key == reset.public_key &&
		common.voiceDeviceIDIsValid(other.device_id) &&
		other.device_id != reset.device_id,
		"expected the same identity with its own device ID, got %q and %q",
		other.device_id,
		reset.device_id,
	)
}

// voice_ptt_global defaults to on, is stored only when turned off, and survives a round trip.
@(test)
testConfigVoicePushToTalkGlobalDefaultsOnAndRoundTrips :: proc(t: ^testing.T) {
	assert(Config_voiceSettings(Config{}).pttGlobal, "expected global push-to-talk on by default")
	config: Config
	defer Config_deinit(&config)
	settings := VOICE_DEFAULT_SETTINGS
	settings.pttGlobal = false
	Config_setVoiceSettings(&config, settings)
	data, marshalErr := json.marshal(config)
	defer delete(data)
	assert(marshalErr == nil, "expected the config to marshal")
	assert(
		strings.contains(string(data), `"voice_ptt_global":false`),
		fmt.tprintf("expected voice_ptt_global stored as false, got %s", string(data)),
	)
	loaded: Config
	defer Config_deinit(&loaded)
	unmarshalErr := json.unmarshal(data, &loaded)
	assert(unmarshalErr == nil, fmt.tprintf("expected %s to load, got %v", data, unmarshalErr))
	assert(!Config_voiceSettings(loaded).pttGlobal, "expected global push-to-talk off after a load")
	clone := Config_clone(loaded)
	defer Config_deinit(&clone)
	assert(!Config_voiceSettings(clone).pttGlobal, "expected Config_clone to keep the setting")

	settings.pttGlobal = true
	Config_setVoiceSettings(&config, settings)
	assert(config.voice_ptt_global == nil, "expected the default (on) stored as unset")
	_ = t
}

// voice_noise_suppression (#170) defaults to on, is stored only when turned off, and survives a
// round trip and a clone.
@(test)
testConfigVoiceNoiseSuppressionDefaultsOnAndRoundTrips :: proc(t: ^testing.T) {
	assert(Config_voiceSettings(Config{}).noiseSuppression, "expected noise suppression on")
	config: Config
	defer Config_deinit(&config)
	settings := VOICE_DEFAULT_SETTINGS
	settings.noiseSuppression = false
	Config_setVoiceSettings(&config, settings)
	data, marshalErr := json.marshal(config)
	defer delete(data)
	assert(marshalErr == nil, "expected the config to marshal")
	assert(
		strings.contains(string(data), `"voice_noise_suppression":false`),
		fmt.tprintf("expected voice_noise_suppression stored as false, got %s", string(data)),
	)
	loaded: Config
	defer Config_deinit(&loaded)
	unmarshalErr := json.unmarshal(data, &loaded)
	assert(unmarshalErr == nil, fmt.tprintf("expected %s to load, got %v", data, unmarshalErr))
	assert(!Config_voiceSettings(loaded).noiseSuppression, "expected it off after a load")
	clone := Config_clone(loaded)
	defer Config_deinit(&clone)
	assert(!Config_voiceSettings(clone).noiseSuppression, "expected Config_clone to keep it")
	template := voiceDefaultEngineTemplate(clone)
	assert(!template.noiseSuppression, "expected the engine template to follow the setting")

	settings.noiseSuppression = true
	Config_setVoiceSettings(&config, settings)
	assert(config.voice_noise_suppression == nil, "expected the default (on) stored as unset")
	unset, unsetErr := json.marshal(config)
	defer delete(unset)
	assert(
		unsetErr == nil && !strings.contains(string(unset), "voice_noise_suppression"),
		fmt.tprintf("expected the key left out while unset, got %s", string(unset)),
	)
	_ = t
}

// voice_echo_cancellation (#171) defaults to on, is stored only when turned off, and survives a
// round trip and a clone.
@(test)
testConfigVoiceEchoCancellationDefaultsOnAndRoundTrips :: proc(t: ^testing.T) {
	assert(Config_voiceSettings(Config{}).echoCancellation, "expected echo cancellation on")
	config: Config
	defer Config_deinit(&config)
	settings := VOICE_DEFAULT_SETTINGS
	settings.echoCancellation = false
	Config_setVoiceSettings(&config, settings)
	data, marshalErr := json.marshal(config)
	defer delete(data)
	assert(marshalErr == nil, "expected the config to marshal")
	assert(
		strings.contains(string(data), `"voice_echo_cancellation":false`),
		fmt.tprintf("expected voice_echo_cancellation stored as false, got %s", string(data)),
	)
	loaded: Config
	defer Config_deinit(&loaded)
	unmarshalErr := json.unmarshal(data, &loaded)
	assert(unmarshalErr == nil, fmt.tprintf("expected %s to load, got %v", data, unmarshalErr))
	assert(!Config_voiceSettings(loaded).echoCancellation, "expected it off after a load")
	clone := Config_clone(loaded)
	defer Config_deinit(&clone)
	assert(!Config_voiceSettings(clone).echoCancellation, "expected Config_clone to keep it")
	template := voiceDefaultEngineTemplate(clone)
	assert(!template.echoCancellation, "expected the engine template to follow the setting")
	assert(template.noiseSuppression, "expected noise suppression left on")

	settings.echoCancellation = true
	Config_setVoiceSettings(&config, settings)
	assert(config.voice_echo_cancellation == nil, "expected the default (on) stored as unset")
	unset, unsetErr := json.marshal(config)
	defer delete(unset)
	assert(
		unsetErr == nil && !strings.contains(string(unset), "voice_echo_cancellation"),
		fmt.tprintf("expected the key left out while unset, got %s", string(unset)),
	)
	_ = t
}

// Per-server settings (server_settings.odin, user_voice.odin): display_name and user_voice
// survive a JSON round trip and a clone, are left out of config.json while unset, and a
// default volume is stored as unset.
@(test)
testServerSettingsConfigKeysRoundTrip :: proc(t: ^testing.T) {
	config := Config {
		display_name = strings.clone("alice"),
	}
	defer Config_deinit(&config)
	append(
		&config.servers,
		Server{id = 1, name = strings.clone("Plain"), host = strings.clone("a"), port = 1},
	)
	plainJSON, plainErr := json.marshal(config)
	defer delete(plainJSON)
	assert(plainErr == nil, "expected the config to marshal")
	assert(
		!strings.contains(string(plainJSON), "user_voice") &&
		!strings.contains(string(plainJSON), `"display_name":""`),
		fmt.tprintf("expected no per-server keys while unset, got %s", plainJSON),
	)

	server := &config.servers[0]
	server.display_name = strings.clone("alice-at-work")
	assert(Server_setUserVoice(server, 7, 0.5, false), "expected a volume for user 7")
	assert(Server_setUserVoice(server, 9, 1, true), "expected a mute for user 9")
	assert(Server_setUserVoice(server, 11, 1.5, false), "expected a volume for user 11")
	// Back to the default drops the entry.
	assert(Server_setUserVoice(server, 11, 1, false), "expected user 11 reset")
	assert(
		len(server.user_voice) == 2 && server.user_voice[1].volume == nil,
		fmt.tprintf("expected two entries, the mute without a volume, got %v", server.user_voice),
	)
	assert(
		Server_displayName(server^, config) == "alice-at-work",
		"expected the server's own name to win over the global one",
	)

	data, marshalErr := json.marshal(config)
	defer delete(data)
	assert(marshalErr == nil, "expected the config to marshal")
	// A volume of 1 is not written; the mute-only entry has no volume key.
	assert(
		strings.contains(string(data), `"display_name":"alice-at-work","user_voice":[`) &&
		strings.contains(string(data), `{"user_id":7,"volume":0.5`) &&
		strings.contains(string(data), `{"user_id":9,"muted":true}`),
		fmt.tprintf("unexpected per-server keys in %s", data),
	)
	loaded: Config
	defer Config_deinit(&loaded)
	unmarshalErr := json.unmarshal(data, &loaded)
	assert(unmarshalErr == nil, fmt.tprintf("expected %s to load, got %v", data, unmarshalErr))
	Config_validateServers(&loaded)
	clone := Config_clone(loaded)
	defer Config_deinit(&clone)
	for copyOf in ([2]^Config{&loaded, &clone}) {
		back := copyOf.servers[0]
		volume7, muted7 := Server_userVoice(back, 7)
		volume9, muted9 := Server_userVoice(back, 9)
		volume11, muted11 := Server_userVoice(back, 11)
		assert(
			back.display_name == "alice-at-work" &&
			volume7 == 0.5 &&
			!muted7 &&
			volume9 == 1 &&
			muted9 &&
			volume11 == 1 &&
			!muted11,
			fmt.tprintf("expected the per-server keys back, got %v", back),
		)
	}
	// The clone owns its own array.
	assert(
		raw_data(clone.servers[0].user_voice) != raw_data(loaded.servers[0].user_voice),
		"expected Config_clone to copy user_voice",
	)
	_ = t
}

// A hand-edited config is made usable: a blank per-server name means the global one, invalid
// user IDs and default entries go, volumes are clamped, a repeated user keeps its last entry,
// and a name of the wrong length is kept for the transport to refuse visibly.
@(test)
testServerSettingsConfigKeysAreValidated :: proc(t: ^testing.T) {
	text := `{"display_name":"alice","servers":[` +
		`{"id":1,"name":"One","host":"a","port":1,"display_name":"  work  ","user_voice":[` +
		`{"user_id":0,"volume":0.5},{"user_id":-3,"muted":true},{"user_id":4,"volume":9},` +
		`{"user_id":5,"volume":-1},{"user_id":6},{"user_id":7,"volume":1},` +
		`{"user_id":8,"volume":0.25},{"user_id":8,"volume":1.75,"muted":true}]},` +
		`{"id":2,"name":"Two","host":"b","port":1,"display_name":"   "},` +
		`{"id":3,"name":"Three","host":"c","port":1,"display_name":"ab"}]}`
	config: Config
	defer Config_deinit(&config)
	unmarshalErr := json.unmarshal(transmute([]u8)text, &config)
	assert(unmarshalErr == nil, fmt.tprintf("expected the config to parse, got %v", unmarshalErr))
	Config_validateServers(&config)

	one := config.servers[0]
	assert(
		one.display_name == "work",
		fmt.tprintf("expected a trimmed name, got %q", one.display_name),
	)
	assert(
		len(one.user_voice) == 3,
		fmt.tprintf("expected users 4, 5 and 8 kept, got %v", one.user_voice),
	)
	volume4, _ := Server_userVoice(one, 4)
	volume5, _ := Server_userVoice(one, 5)
	volume8, muted8 := Server_userVoice(one, 8)
	assert(
		volume4 == SERVER_USER_VOICE_VOLUME_MAX && volume5 == 0,
		fmt.tprintf("expected volumes clamped to 0..2, got %v and %v", volume4, volume5),
	)
	assert(
		volume8 == 1.75 && muted8,
		fmt.tprintf("expected the last entry of user 8, got %v %v", volume8, muted8),
	)
	assert(config.servers[1].display_name == "", "expected a blank name to mean the global one")
	assert(
		Server_displayName(config.servers[1], config) == "alice",
		"expected the global name for a server without its own",
	)
	assert(config.servers[2].display_name == "ab", "expected a too short name kept as written")
	transport := ClientServerTransport_initForServer(config.servers[2], config)
	defer ClientServerTransport_deinit(&transport)
	assert(
		transport.configInvalid && transport.lastError == CLIENT_INVALID_NICKNAME_MESSAGE,
		fmt.tprintf("expected the transport to refuse the name, got %q", transport.lastError),
	)

	// The table is bounded; a new user beyond it is refused, an existing one still changes.
	full: Server
	defer Server_deinit(&full)
	for userID in 1 ..= SERVER_USER_VOICE_MAX_ENTRIES {
		assert(Server_setUserVoice(&full, userID, 0.5, false), "expected room in the table")
	}
	assert(
		!Server_setUserVoice(&full, SERVER_USER_VOICE_MAX_ENTRIES + 1, 0.5, false),
		"expected a full table to refuse a new user",
	)
	assert(Server_setUserVoice(&full, 1, 1, true), "expected an existing user to change")
	assert(
		Server_setUserVoice(&full, SERVER_USER_VOICE_MAX_ENTRIES + 1, 1, false),
		"expected a default for an unknown user to need no slot",
	)
	assert(!Server_setUserVoice(&full, 0, 0.5, false), "expected user ID 0 refused")
	_ = t
}

// Rewrites configHome's config.json through edit.
@(private = "file")
configTestEditStored :: proc(configHome: string, edit: proc(config: ^Config)) {
	path := configTestExpectedCurrentLinuxConfigPath(configHome)
	data, readErr := os.read_entire_file_from_path(path, context.temp_allocator)
	assert(readErr == nil, "expected the saved config to be readable")
	stored: Config
	defer Config_deinit(&stored)
	assert(json.unmarshal(data, &stored) == nil, "expected the saved config to parse")
	edit(&stored)
	encoded, encodeErr := json.marshal(stored, allocator = context.temp_allocator)
	assert(encodeErr == nil, "expected the edited config to encode")
	assert(os.write_entire_file_from_bytes(path, encoded) == nil, "expected the config written")
}

// The encryption key (e2ee-design.md 2.2, 9.3) is generated once, signed by the identity key,
// kept across a save and a load, and replaced when it is missing, damaged, does not match its
// private key, or does not verify against the profile's identity key.
@(test)
testEncryptionKeyIsGeneratedOnceAndReplacedWhenInvalid :: proc(t: ^testing.T) {
	when ODIN_OS != .Linux {
		_ = t
		return
	}

	sync.mutex_lock(&configTestMutex)
	defer sync.mutex_unlock(&configTestMutex)
	snapshot := configTestCaptureEnv()
	defer configTestRestoreEnv(snapshot)
	tempDir := configTestCreateTempDir("hc_client_encryption_key")
	defer configTestRemovePathIfExists(tempDir)
	configHome := configTestJoinPath({tempDir, "xdg"})
	assert(os.make_directory(configHome) == nil, "expected the XDG directory created")
	configTestSetEnv("HOME", tempDir)

	first := configTestLoadFrom(configHome)
	defer Config_deinit(&first)
	keyPair, bundle, ok := Config_encryptionKey(first)
	common.EncryptionKeyPair_wipe(&keyPair)
	identity, _ := common.identityPublicKeyFromHex(first.public_key)
	assert(
		ok &&
		bundle.identityPublicKey == identity &&
		common.verifyEncryptionKeyBundle(bundle) &&
		first.encryption_key_created_at > 0 &&
		len(first.encryption_private_key) == 64 &&
		len(first.encryption_public_key) == 64 &&
		len(first.encryption_key_signature) == 128,
		"expected a new profile to get a valid, signed encryption key",
	)
	// The file stays readable by the user only, and no temporary file is left behind.
	path := configTestExpectedCurrentLinuxConfigPath(configHome)
	info, statErr := os.stat(path, context.temp_allocator)
	assert(statErr == nil, "expected the config to exist")
	assert(
		info.mode & os.perm(0o077) == {},
		fmt.tprintf("expected config.json to be 0600, got %v", info.mode),
	)
	assert(!os.exists(fmt.tprintf("%s.tmp", path)), "expected no temporary file left")

	second := configTestLoadFrom(configHome)
	defer Config_deinit(&second)
	assert(
		second.encryption_private_key == first.encryption_private_key &&
		second.encryption_public_key == first.encryption_public_key &&
		second.encryption_key_signature == first.encryption_key_signature &&
		second.encryption_key_created_at == first.encryption_key_created_at,
		"expected the same encryption key after a load",
	)

	Case :: struct {
		label: string,
		edit:  proc(config: ^Config),
	}
	cases := [?]Case {
		{"a missing key", proc(config: ^Config) {
				delete(config.encryption_private_key)
				config.encryption_private_key = ""
			}},
		{"a signature that does not verify", proc(config: ^Config) {
				config.encryption_key_created_at += 1
			}},
		{"a public key that is not the private key's", proc(config: ^Config) {
				delete(config.encryption_public_key)
				config.encryption_public_key = strings.repeat("09", 32)
			}},
		{"bad hex", proc(config: ^Config) {
				delete(config.encryption_key_signature)
				config.encryption_key_signature = strings.clone("zz")
			}},
		// A key signed by another identity (a profile whose identity key was replaced).
		{"a key for another identity", proc(config: ^Config) {
				privateKey, publicKey, _ := common.generateIdentityKeyPair()
				delete(config.private_key)
				delete(config.public_key)
				config.private_key = common.identityPrivateKeyToHex(privateKey)
				config.public_key = common.identityPublicKeyToHex(publicKey)
			}},
	}
	previous := strings.clone(first.encryption_public_key)
	defer delete(previous)
	for testCase in cases {
		configTestEditStored(configHome, testCase.edit)
		repaired := configTestLoadFrom(configHome)
		defer Config_deinit(&repaired)
		repairedPair, repairedBundle, repairedOK := Config_encryptionKey(repaired)
		common.EncryptionKeyPair_wipe(&repairedPair)
		repairedIdentity, _ := common.identityPublicKeyFromHex(repaired.public_key)
		assert(
			repairedOK &&
			repairedBundle.identityPublicKey == repairedIdentity &&
			repaired.encryption_public_key != previous,
			fmt.tprintf("expected %s to be replaced by a new valid key", testCase.label),
		)
		// The replacement was saved: the next load keeps it.
		again := configTestLoadFrom(configHome)
		defer Config_deinit(&again)
		assert(
			again.encryption_public_key == repaired.encryption_public_key,
			fmt.tprintf("expected the key that replaced %s to be saved", testCase.label),
		)
		delete(previous)
		previous = strings.clone(repaired.encryption_public_key)
	}
}

// A config without an identity key gets no encryption key, and Config_clone keeps the keys.
@(test)
testEncryptionKeyNeedsAnIdentityKeyAndIsCloned :: proc(t: ^testing.T) {
	_ = t
	empty: Config
	assert(!ensureEncryptionKey(&empty), "expected no encryption key without an identity key")
	_, _, emptyOK := Config_encryptionKey(empty)
	assert(!emptyOK, "expected no valid encryption key without an identity key")

	privateKey, publicKey, _ := common.generateIdentityKeyPair()
	config := Config {
		private_key = common.identityPrivateKeyToHex(privateKey),
		public_key  = common.identityPublicKeyToHex(publicKey),
	}
	defer Config_deinit(&config)
	assert(ensureEncryptionKey(&config), "expected a key to be made")
	assert(!ensureEncryptionKey(&config), "expected a valid key to be kept")
	clone := Config_clone(config)
	defer Config_deinit(&clone)
	assert(
		clone.encryption_private_key == config.encryption_private_key &&
		clone.encryption_public_key == config.encryption_public_key &&
		clone.encryption_key_signature == config.encryption_key_signature &&
		clone.encryption_key_created_at == config.encryption_key_created_at,
		"expected the clone to keep the encryption key",
	)
	_, _, cloneOK := Config_encryptionKey(clone)
	assert(cloneOK, "expected the cloned key to be valid")
}

// Protocol 25 (#43 G2): Use an invite code is stored per server as use_invite_code (false or
// left out while off, as the JSON writer decides) and survives a round trip and a clone. The
// code itself is never in the config.
@(test)
testUseInviteCodeConfigKeyRoundTrips :: proc(t: ^testing.T) {
	config := Config {
		display_name = strings.clone("alice"),
	}
	defer Config_deinit(&config)
	append(
		&config.servers,
		Server{id = 1, name = strings.clone("Plain"), host = strings.clone("a"), port = 1},
	)
	plainJSON, plainErr := json.marshal(config)
	defer delete(plainJSON)
	assert(plainErr == nil, "expected the config to marshal")
	assert(
		!strings.contains(string(plainJSON), `"use_invite_code":true`),
		fmt.tprintf("expected use_invite_code off, got %s", plainJSON),
	)

	config.servers[0].use_invite_code = true
	data, marshalErr := json.marshal(config)
	defer delete(data)
	assert(marshalErr == nil, "expected the config to marshal")
	assert(
		strings.contains(string(data), `"use_invite_code":true`),
		fmt.tprintf("expected use_invite_code in %s", data),
	)
	loaded: Config
	defer Config_deinit(&loaded)
	assert(json.unmarshal(data, &loaded) == nil, fmt.tprintf("expected %s to load", data))
	Config_validateServers(&loaded)
	clone := Config_clone(loaded)
	defer Config_deinit(&clone)
	assert(
		loaded.servers[0].use_invite_code && clone.servers[0].use_invite_code,
		"expected use_invite_code back from the file and the clone",
	)
	_ = t
}
