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
