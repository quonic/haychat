package client

import "../common"
import "core:crypto"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:time"

XDG_CONFIG_HOME: string = "" // Global variable to store the XDG config home directory path, initialized to an empty string
APP_DATA: string = "" // Global variable to store the APPDATA directory path on Windows, initialized to an empty string
haychatFolder: string = "haychat" // Global variable to store the name of the haychat configuration folder, initialized to "haychat"

Config :: struct {
	private_key:            string,
	public_key:             string,
	display_name:           string,
	servers:                [dynamic]Server,
	// Voice settings (voice_settings.odin). Read them through Config_voiceSettings, which
	// validates them and fills in the defaults: an empty string or a missing number means the
	// default, so a config written before voice existed, or a Config literal, behaves the
	// same as a new one. The numbers are Maybe so that 0, a valid gain and threshold, is not
	// mistaken for "not set". omitempty keeps unset keys out of config.json.
	voice_input_device:     string `json:"voice_input_device,omitempty"`,
	voice_output_device:    string `json:"voice_output_device,omitempty"`,
	voice_mode:             string `json:"voice_mode,omitempty"`,
	voice_ptt_key:          string `json:"voice_ptt_key,omitempty"`,
	// Whether push-to-talk also works while another window has focus (client/hotkey).
	voice_ptt_global:       Maybe(bool) `json:"voice_ptt_global,omitempty"`,
	voice_vad_threshold_db: Maybe(f32) `json:"voice_vad_threshold_db,omitempty"`,
	voice_input_gain:       Maybe(f32) `json:"voice_input_gain,omitempty"`,
	voice_output_volume:    Maybe(f32) `json:"voice_output_volume,omitempty"`,
	voice_bitrate:          Maybe(int) `json:"voice_bitrate,omitempty"`,
	// RNNoise noise suppression on the microphone (#170, client/rnnoise); on when unset. It
	// only works when the library loads; the voice settings say why when it does not.
	voice_noise_suppression: Maybe(bool) `json:"voice_noise_suppression,omitempty"`,
	// This profile's voice device ID (protocol 13, common/voice_device.odin): 32 lowercase hex
	// characters, random, generated on first use and sent with every voice join so the server
	// can tell this device's stale voice session from another device's. loadConfig replaces a
	// missing or malformed value with a new one, so deleting the key resets it. A copied profile
	// directory keeps the same ID; reset it in the copy so the two count as different devices.
	device_id:              string `json:"device_id,omitempty"`,
	// This profile's end-to-end encryption key (e2ee-design.md 2.2, 9.3): an X25519 key pair in
	// hex, the identity key's signature over the bundle, and the bundle's creation time (Unix
	// seconds). Like private_key, encryption_private_key is a secret and config.json stays 0600.
	// loadConfig (ensureEncryptionKey) generates a new key when any of them is missing, does not
	// parse, does not match its private key, or does not verify against the identity key; peers
	// then see a new encryption key. One key for every server.
	encryption_private_key:    string `json:"encryption_private_key,omitempty"`,
	encryption_public_key:     string `json:"encryption_public_key,omitempty"`,
	encryption_key_signature:  string `json:"encryption_key_signature,omitempty"`,
	encryption_key_created_at: u64 `json:"encryption_key_created_at,omitempty"`,
}

Server :: struct {
	id:                        int,
	name:                      string,
	short_name:                string,
	host:                      string,
	port:                      i32,
	pinned_server_public_key:  string,
	pinned_server_fingerprint: string,
	// Per-server user settings (server_settings.odin). Kept only in this profile's config, so
	// they are not synced between devices. display_name is the name used on this server only;
	// empty means the global display_name (Server_displayName).
	display_name:              string `json:"display_name,omitempty"`,
	// Voice volume and local mute per user of this server. Only entries that differ from the
	// default (volume 1, not muted) are kept; Config_validateServers drops the rest.
	user_voice:                [dynamic]ServerUserVoice `json:"user_voice,omitempty"`,
	// Protocol 25 (#43 G2): sign up with an invite code even when the server is Open, by
	// setting ClientAuthRequestPayload.registering (Server settings → Use an invite code). It
	// changes nothing for a key that already has an account. Never holds the code itself.
	// (Odin's JSON writer may still write false despite omitempty.)
	use_invite_code:           bool `json:"use_invite_code,omitempty"`,
}

// One user's voice playback on one server, as only this client hears it. user_id is the
// server's account ID. volume is a linear gain from 0 to SERVER_USER_VOICE_VOLUME_MAX (2,
// i.e. 200 %); unset means 1. muted drops the user's voice before it is decoded.
ServerUserVoice :: struct {
	user_id: int,
	volume:  Maybe(f32) `json:"volume,omitempty"`,
	muted:   bool `json:"muted,omitempty"`,
}

// Reads where the config lives (APPDATA on Windows, XDG_CONFIG_HOME or ~/.config on Linux).
initConfigHome :: proc() {
	when ODIN_OS == .Windows {
		delete(APP_DATA)
		APP_DATA = os.get_env("APPDATA", context.allocator)
		if APP_DATA == "" {
			fmt.println(
				"[Warning] APPDATA environment variable is not set. Defaulting to current directory.",
			)
			APP_DATA = "."
		}
	} else when ODIN_OS == .Linux {
		delete(XDG_CONFIG_HOME)
		XDG_CONFIG_HOME = os.get_env("XDG_CONFIG_HOME", context.allocator)
		if XDG_CONFIG_HOME == "" {
			delete(XDG_CONFIG_HOME)
			XDG_CONFIG_HOME = getDefaultLinuxConfigHome(os.get_env("HOME", context.temp_allocator))
		}
	}
}

loadConfig :: proc() -> (config: Config) {
	initConfigHome()

	if !ensureConfigDirExists() {
		return {}
	}

	path := getConfigPath()
	defer delete(path)
	shouldLoad := false
	shouldPersist := false
	readPath := path

	when ODIN_OS == .Linux {
		legacyPath := getLegacyLinuxConfigPath()
		defer delete(legacyPath)
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
		defer delete(data)
		json.unmarshal(data, &config)
	}

	Config_validateServers(&config)
	if ensureIdentityKeys(&config) {
		shouldPersist = true
	}
	if ensureDeviceID(&config) {
		shouldPersist = true
	}
	if ensureEncryptionKey(&config) {
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
	defer delete(jsonData)

	// The config holds the client's private identity and encryption keys, so only the user may
	// read it.
	configPath := getConfigPath()
	defer delete(configPath)
	write_err := writeFileAtomically(configPath, jsonData)
	if write_err != nil {
		fmt.println("[Error] Failed to write config file: ", write_err)
		return
	}
	fmt.println("[Info] Config saved successfully to: ", configPath)
}

// Writes data to path so that a reader sees either the old file or the new one, never a part:
// it goes to path + ".tmp" (mode 0600, only the user may read it) and is renamed over path.
// A failed write leaves path as it was.
writeFileAtomically :: proc(path: string, data: []u8) -> os.Error {
	tempPath := strings.concatenate({path, ".tmp"})
	defer delete(tempPath)
	err := os.write_entire_file_from_bytes(tempPath, data, os.perm(0o600))
	if err == nil {
		// The mode only applies to a new file; an old temporary file keeps its own.
		err = os.change_mode(tempPath, os.perm(0o600))
	}
	if err == nil {
		err = os.rename(tempPath, path)
	}
	if err != nil {
		os.remove(tempPath)
	}
	return err
}

ensureConfigDirExists :: proc() -> bool {
	configDir := getConfigDir()
	defer delete(configDir)
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

getDefaultLinuxConfigHome :: proc(home: string, allocator := context.allocator) -> string {
	when ODIN_OS == .Linux {
		return strings.concatenate({home, "/.config"}, allocator)
	}
	return ""
}

getLinuxConfigDirForConfigHome :: proc(configHome: string) -> string {
	when ODIN_OS == .Linux {
		return strings.concatenate({configHome, "/", haychatFolder}, context.allocator)
	}
	return ""
}

getLinuxConfigPathForConfigHome :: proc(configHome: string) -> string {
	when ODIN_OS == .Linux {
		configDir := getLinuxConfigDirForConfigHome(configHome)
		defer delete(configDir)
		return strings.concatenate({configDir, "/config.json"}, context.allocator)
	}
	return ""
}

getHistoricalLegacyLinuxConfigPathForConfigHome :: proc(home, configHome: string) -> string {
	when ODIN_OS == .Linux {
		configPath := getLinuxConfigPathForConfigHome(configHome)
		defer delete(configPath)
		return strings.concatenate({home, configPath}, context.allocator)
	}
	return ""
}

getConfigDir :: proc() -> string {
	when ODIN_OS == .Windows {
		return strings.concatenate({APP_DATA, "\\", haychatFolder}, context.allocator)
	} else when ODIN_OS == .Linux {
		return getLinuxConfigDirForConfigHome(XDG_CONFIG_HOME)
	}
	return ""
}

getConfigPath :: proc() -> string {
	// Returns the path to the configuration file based on the operating system
	when ODIN_OS == .Windows {
		configDir := getConfigDir()
		defer delete(configDir)
		return strings.concatenate({configDir, "\\config.json"}, context.allocator)
	} else when ODIN_OS == .Linux {
		return getLinuxConfigPathForConfigHome(XDG_CONFIG_HOME)
	}
	return ""
}

getLegacyLinuxConfigPath :: proc() -> string {
	when ODIN_OS == .Linux {
		home := os.get_env("HOME", context.temp_allocator)
		legacyConfigHome := XDG_CONFIG_HOME
		if legacyConfigHome == "" {
			legacyConfigHome = os.get_env("XDG_CONFIG_HOME", context.temp_allocator)
		}
		if legacyConfigHome == "" {
			legacyConfigHome = getDefaultLinuxConfigHome(home, context.temp_allocator)
		}

		// The original Linux client wrote to HOME + XDG_CONFIG_HOME + /haychat/config.json.
		return getHistoricalLegacyLinuxConfigPathForConfigHome(home, legacyConfigHome)
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

	delete(config.private_key)
	delete(config.public_key)
	config.private_key = common.identityPrivateKeyToHex(privateKeyBytes)
	config.public_key = common.identityPublicKeyToHex(publicKeyBytes)
	return true
}

// Gives the config a voice device ID unless it has a valid one. Returns true when it changed and
// should be saved. The ID is not a secret, but it identifies the profile, so it is not printed.
ensureDeviceID :: proc(config: ^Config) -> bool {
	if common.voiceDeviceIDIsValid(config.device_id) {
		return false
	}
	id, ok := common.generateVoiceDeviceID()
	if !ok {
		fmt.println("[Error] Failed to generate a voice device ID")
		return false
	}
	delete(config.device_id)
	config.device_id = common.voiceDeviceIDToHex(id)
	return true
}

// The profile's encryption key pair and its signed bundle, when the config holds a valid one
// (ensureEncryptionKey made sure of it at load). The caller wipes keyPair after use.
Config_encryptionKey :: proc(
	config: Config,
) -> (
	keyPair: common.EncryptionKeyPair,
	bundle: common.EncryptionKeyBundle,
	ok: bool,
) {
	identityPrivateKey, identityOK := common.identityPrivateKeyFromHex(config.private_key)
	defer crypto.zero_explicit(&identityPrivateKey, size_of(identityPrivateKey))
	if !identityOK {
		return
	}
	identityPublicKey, publicOK := common.identityPublicKeyFromHex(config.public_key)
	derivedPublicKey, derivedOK := common.identityPublicKeyFromPrivateKey(identityPrivateKey)
	if !publicOK || !derivedOK || derivedPublicKey != identityPublicKey {
		return
	}
	privateKey: common.EncryptionPrivateKeyBytes
	defer crypto.zero_explicit(&privateKey, size_of(privateKey))
	publicKey: common.EncryptionPublicKeyBytes
	signature: common.SignatureBytes
	if !common.decodeHexIntoBuffer(config.encryption_private_key, privateKey[:]) ||
	   !common.decodeHexIntoBuffer(config.encryption_public_key, publicKey[:]) ||
	   !common.decodeHexIntoBuffer(config.encryption_key_signature, signature[:]) ||
	   config.encryption_key_created_at == 0 {
		return
	}
	derived := common.encryptionKeyPairFromPrivateKey(privateKey)
	if derived.publicKey != publicKey {
		common.EncryptionKeyPair_wipe(&derived)
		return
	}
	candidate := common.EncryptionKeyBundle {
		identityPublicKey   = identityPublicKey,
		encryptionPublicKey = publicKey,
		createdAt           = config.encryption_key_created_at,
		signature           = signature,
	}
	if !common.verifyEncryptionKeyBundle(candidate) {
		common.EncryptionKeyPair_wipe(&derived)
		return
	}
	return derived, candidate, true
}

// Gives the config an encryption key unless it holds a valid one for its identity key (see
// Config.encryption_private_key). Run after ensureIdentityKeys. Returns true when it changed
// and should be saved. Never prints a key.
ensureEncryptionKey :: proc(config: ^Config) -> bool {
	if keyPair, _, ok := Config_encryptionKey(config^); ok {
		common.EncryptionKeyPair_wipe(&keyPair)
		return false
	}
	identityPrivateKey, identityOK := common.identityPrivateKeyFromHex(config.private_key)
	defer crypto.zero_explicit(&identityPrivateKey, size_of(identityPrivateKey))
	if !identityOK {
		return false
	}
	keyPair, keyOK := common.generateEncryptionKeyPair()
	defer common.EncryptionKeyPair_wipe(&keyPair)
	if !keyOK {
		fmt.println("[Error] Failed to generate an encryption key")
		return false
	}
	createdAt := u64(max(time.time_to_unix(time.now()), 1))
	bundle, signOK := common.signEncryptionKeyBundle(
		identityPrivateKey,
		keyPair.publicKey,
		createdAt,
	)
	if !signOK {
		fmt.println("[Error] Failed to sign the encryption key")
		return false
	}
	hadKey := len(config.encryption_public_key) > 0
	delete(config.encryption_private_key)
	delete(config.encryption_public_key)
	delete(config.encryption_key_signature)
	config.encryption_private_key = common.encodeBytesToHex(keyPair.privateKey[:])
	config.encryption_public_key = common.encodeBytesToHex(keyPair.publicKey[:])
	config.encryption_key_signature = common.encodeBytesToHex(bundle.signature[:])
	config.encryption_key_created_at = createdAt
	if hadKey {
		fmt.println(
			"[Warning] The encryption key in the config was not valid; made a new one. " +
			"Other users will see that this profile set up encryption again.",
		)
	}
	return true
}

// Replaces a server's pins with clones of the given hex key and fingerprint.
Server_setPins :: proc(server: ^Server, publicKey, fingerprint: string) {
	delete(server.pinned_server_public_key)
	delete(server.pinned_server_fingerprint)
	server.pinned_server_public_key = strings.clone(publicKey)
	server.pinned_server_fingerprint = strings.clone(fingerprint)
}

// Config values are owned: every string and array is heap allocated. Clone before storing a
// config somewhere that frees it, and free it with Config_deinit.
Server_clone :: proc(server: Server) -> Server {
	clone := Server {
		id = server.id,
		name = strings.clone(server.name),
		short_name = strings.clone(server.short_name),
		host = strings.clone(server.host),
		port = server.port,
		pinned_server_public_key = strings.clone(server.pinned_server_public_key),
		pinned_server_fingerprint = strings.clone(server.pinned_server_fingerprint),
		display_name = strings.clone(server.display_name),
		use_invite_code = server.use_invite_code,
	}
	if len(server.user_voice) > 0 {
		clone.user_voice = make([dynamic]ServerUserVoice, 0, len(server.user_voice))
		append(&clone.user_voice, ..server.user_voice[:])
	}
	return clone
}

Server_deinit :: proc(server: ^Server) {
	delete(server.name)
	delete(server.short_name)
	delete(server.host)
	delete(server.pinned_server_public_key)
	delete(server.pinned_server_fingerprint)
	delete(server.display_name)
	delete(server.user_voice)
	server^ = {}
}

// The name this client signs in with on server: its own display_name when set, otherwise the
// profile's global one. Borrowed from server or config.
Server_displayName :: proc(server: Server, config: Config) -> string {
	if len(server.display_name) > 0 {
		return server.display_name
	}
	return config.display_name
}

SERVER_USER_VOICE_VOLUME_MAX :: f32(2)
// At most this many users per server keep a volume or mute. It matches the voice engine's
// table (VOICE_SPEAKER_CONTROL_CAPACITY), which holds one server's entries.
SERVER_USER_VOICE_MAX_ENTRIES :: 256

// A user's voice entry made valid: the volume clamped to 0..SERVER_USER_VOICE_VOLUME_MAX
// (unset or NaN is 1).
serverUserVoiceVolume :: proc(entry: ServerUserVoice) -> f32 {
	volume, hasVolume := entry.volume.?
	if !hasVolume || math.is_nan(volume) {
		return 1
	}
	return clamp(volume, 0, SERVER_USER_VOICE_VOLUME_MAX)
}

// Whether the entry changes anything; default entries are not stored.
serverUserVoiceIsDefault :: proc(volume: f32, muted: bool) -> bool {
	return volume == 1 && !muted
}

// Makes the per-server settings of a loaded or hand-edited config usable: trims the per-server
// display name (blank means "use the global one"), and for user_voice drops entries without a
// valid user ID, clamps volumes, stores a volume of 1 as unset, drops default entries and
// repeats of a user (the last one wins), and keeps at most SERVER_USER_VOICE_MAX_ENTRIES. A
// per-server name of the wrong length is kept: the transport refuses it with the same
// "invalid name" failure as a bad global name, and the banner points to Server settings.
Config_validateServers :: proc(config: ^Config) {
	for &server in config.servers {
		trimmed := strings.trim_space(server.display_name)
		if trimmed != server.display_name {
			clean := strings.clone(trimmed)
			delete(server.display_name)
			server.display_name = clean
		}
		if len(server.display_name) == 0 {
			delete(server.display_name)
			server.display_name = ""
		}
		kept := 0
		for index in 0 ..< len(server.user_voice) {
			entry := server.user_voice[index]
			if entry.user_id <= 0 {
				continue
			}
			repeated := false
			for later in server.user_voice[index + 1:] {
				repeated ||= later.user_id == entry.user_id
			}
			volume := serverUserVoiceVolume(entry)
			if repeated || serverUserVoiceIsDefault(volume, entry.muted) {
				continue
			}
			if kept == SERVER_USER_VOICE_MAX_ENTRIES {
				break
			}
			entry.volume = nil
			if volume != 1 {
				entry.volume = volume
			}
			server.user_voice[kept] = entry
			kept += 1
		}
		resize(&server.user_voice, kept)
		if kept == 0 {
			delete(server.user_voice)
			server.user_voice = nil
		}
	}
}

// The volume and local mute this client applies to userID's voice on server.
Server_userVoice :: proc(server: Server, userID: int) -> (volume: f32, muted: bool) {
	for entry in server.user_voice {
		if entry.user_id == userID {
			return serverUserVoiceVolume(entry), entry.muted
		}
	}
	return 1, false
}

// Stores userID's volume and mute on server, dropping the entry when both are the default.
// Returns false when the user is new and the server already has SERVER_USER_VOICE_MAX_ENTRIES.
Server_setUserVoice :: proc(server: ^Server, userID: int, volume: f32, muted: bool) -> bool {
	if userID <= 0 {
		return false
	}
	clean := serverUserVoiceVolume({volume = volume})
	stored: Maybe(f32)
	if clean != 1 {
		stored = clean
	}
	for index in 0 ..< len(server.user_voice) {
		if server.user_voice[index].user_id != userID {
			continue
		}
		if serverUserVoiceIsDefault(clean, muted) {
			ordered_remove(&server.user_voice, index)
		} else {
			server.user_voice[index].volume = stored
			server.user_voice[index].muted = muted
		}
		return true
	}
	if serverUserVoiceIsDefault(clean, muted) {
		return true
	}
	if len(server.user_voice) >= SERVER_USER_VOICE_MAX_ENTRIES {
		return false
	}
	append(&server.user_voice, ServerUserVoice{user_id = userID, volume = stored, muted = muted})
	return true
}

Config_clone :: proc(config: Config) -> Config {
	clone := Config {
		private_key  = strings.clone(config.private_key),
		public_key   = strings.clone(config.public_key),
		display_name = strings.clone(config.display_name),
		servers      = make([dynamic]Server, 0, len(config.servers)),
		voice_input_device = strings.clone(config.voice_input_device),
		voice_output_device = strings.clone(config.voice_output_device),
		voice_mode = strings.clone(config.voice_mode),
		voice_ptt_key = strings.clone(config.voice_ptt_key),
		voice_ptt_global = config.voice_ptt_global,
		voice_vad_threshold_db = config.voice_vad_threshold_db,
		voice_input_gain = config.voice_input_gain,
		voice_output_volume = config.voice_output_volume,
		voice_bitrate = config.voice_bitrate,
		voice_noise_suppression = config.voice_noise_suppression,
		device_id = strings.clone(config.device_id),
		encryption_private_key = strings.clone(config.encryption_private_key),
		encryption_public_key = strings.clone(config.encryption_public_key),
		encryption_key_signature = strings.clone(config.encryption_key_signature),
		encryption_key_created_at = config.encryption_key_created_at,
	}
	for server in config.servers {
		append(&clone.servers, Server_clone(server))
	}
	return clone
}

Config_deinit :: proc(config: ^Config) {
	delete(config.private_key)
	delete(config.public_key)
	delete(config.display_name)
	for index in 0 ..< len(config.servers) {
		Server_deinit(&config.servers[index])
	}
	delete(config.servers)
	delete(config.voice_input_device)
	delete(config.voice_output_device)
	delete(config.voice_mode)
	delete(config.voice_ptt_key)
	delete(config.device_id)
	delete(config.encryption_private_key)
	delete(config.encryption_public_key)
	delete(config.encryption_key_signature)
	config^ = {}
}

LOCAL_DEFAULT_DISPLAY_NAME :: "Test User"
LOCAL_DEFAULT_SERVER_NAME :: "Test Server"
LOCAL_DEFAULT_SERVER_HOST :: "localhost"

// Fills an empty display name and an empty server list with the local development profile
// ("Test User" on localhost:12345). The GUI never does this: it shows the first-run screen
// instead. Tests and tools that want a ready-to-connect default call it explicitly.
Config_fillLocalDefaults :: proc(config: ^Config) {
	if len(config.display_name) == 0 {
		delete(config.display_name)
		config.display_name = strings.clone(LOCAL_DEFAULT_DISPLAY_NAME)
	}
	if len(config.servers) == 0 {
		append(
			&config.servers,
			Server {
				id = 1,
				name = strings.clone(LOCAL_DEFAULT_SERVER_NAME),
				short_name = getShortServerName(LOCAL_DEFAULT_SERVER_NAME),
				host = strings.clone(LOCAL_DEFAULT_SERVER_HOST),
				port = common.DEFAULT_SERVER_PORT,
			},
		)
	}
}
