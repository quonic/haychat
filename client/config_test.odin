package client

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
	path, err := filepath.join(parts)
	assert(err == nil, "expected test path join to succeed")
	return path
}

configTestCreateTempDir :: proc(prefix: string) -> string {
	tempRoot, tempRootErr := os.temp_directory(context.allocator)
	assert(tempRootErr == nil, "expected temp directory lookup to succeed")

	tempPath := configTestJoinPath(
		{tempRoot, fmt.aprintf("%s_%d", prefix, time.time_to_unix_nano(time.now()))},
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
		home = os.get_env("HOME", context.allocator),
		xdgConfigHome = os.get_env("XDG_CONFIG_HOME", context.allocator),
		appData = os.get_env("APPDATA", context.allocator),
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
	return strings.concatenate({configHome, "/haychat/config.json"}, context.allocator)
}

configTestExpectedHistoricalLegacyLinuxConfigDir :: proc(home, configHome: string) -> string {
	return strings.concatenate({home, configHome, "/haychat"}, context.allocator)
}

configTestExpectedHistoricalLegacyLinuxConfigPath :: proc(home, configHome: string) -> string {
	return strings.concatenate({home, configHome, "/haychat/config.json"}, context.allocator)
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
	XDG_CONFIG_HOME = os.get_env("XDG_CONFIG_HOME", context.allocator)

	legacyPath := getLegacyLinuxConfigPath()
	currentPath := getConfigPath()
	expectedLegacyPath := configTestExpectedHistoricalLegacyLinuxConfigPath(homeDir, customXdgDir)
	expectedCurrentPath := configTestExpectedCurrentLinuxConfigPath(customXdgDir)

	testing.expect(
		t,
		legacyPath == expectedLegacyPath,
		fmt.aprintf("expected legacy config path %q, got %q", expectedLegacyPath, legacyPath),
	)
	testing.expect(
		t,
		currentPath == expectedCurrentPath,
		fmt.aprintf("expected current config path %q, got %q", expectedCurrentPath, currentPath),
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
		friends      = {},
	}
	legacyJSON, legacyJSONErr := json.marshal(legacyConfig)
	assert(legacyJSONErr == nil, "expected legacy config JSON encode to succeed")
	assert(
		os.write_entire_file_from_bytes(legacyPath, legacyJSON) == nil,
		"expected legacy config write to succeed",
	)

	loadedConfig := loadConfig()

	testing.expect(
		t,
		loadedConfig.display_name == "Legacy Linux Tester",
		fmt.aprintf(
			"expected migrated config to preserve display name, got %q",
			loadedConfig.display_name,
		),
	)
	testing.expect(
		t,
		os.exists(currentPath),
		"expected migrated config to be written to the current XDG path",
	)

	persistedBytes, persistedErr := os.read_entire_file_from_path(currentPath, context.allocator)
	assert(persistedErr == nil, "expected migrated config read to succeed")

	persistedConfig: Config
	json.unmarshal(persistedBytes, &persistedConfig)
	testing.expect(
		t,
		persistedConfig.display_name == "Legacy Linux Tester",
		fmt.aprintf(
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
		friends      = {},
	}
	legacyJSON, legacyJSONErr := json.marshal(legacyConfig)
	assert(legacyJSONErr == nil, "expected legacy config JSON encode to succeed")
	assert(
		os.write_entire_file_from_bytes(legacyPath, legacyJSON) == nil,
		"expected legacy config write to succeed",
	)

	loadedConfig := loadConfig()

	testing.expect(
		t,
		loadedConfig.display_name == "Default Linux Tester",
		fmt.aprintf(
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
