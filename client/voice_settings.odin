package client

// Voice settings (voice-rooms-design.md 5.3): the config keys, their validation, the engine
// template built from them, and the Settings → Voice panel's actions (device lists, the
// microphone test, push-to-talk key capture). Changing a setting updates the config, the
// template every new engine starts from, and any engine already running: levels, gate and
// bitrate through the engine's atomic controls, a device change by reopening the engine while
// the session stays joined.

import "base:runtime"
import "core:c"
import "core:math"
import "core:strings"
import "hotkey"
import "opus"
import SDL "vendor:sdl3"

VOICE_MODE_VOICE_ACTIVITY :: "voice_activity"
VOICE_MODE_PUSH_TO_TALK :: "push_to_talk"
// An SDL key name (SDL_GetKeyName).
VOICE_DEFAULT_PTT_KEY :: "Left Ctrl"
VOICE_VAD_THRESHOLD_MIN_DB :: f32(-80)
VOICE_VAD_THRESHOLD_MAX_DB :: f32(0)
VOICE_INPUT_GAIN_MAX :: f32(4)
VOICE_OUTPUT_VOLUME_MAX :: f32(2)
VOICE_BITRATE_MIN :: 12000
VOICE_BITRATE_MAX :: 64000
VOICE_BITRATE_DEFAULT :: int(opus.VOICE_ENCODER_SETTINGS.bitrate)
// Longer names than this are not device names; the setting falls back to the default.
VOICE_DEVICE_NAME_MAX_BYTES :: 256
VOICE_PTT_KEY_MAX_BYTES :: 64

// The user's voice settings, validated. Strings borrow from wherever they were read.
VoiceSettings :: struct {
	inputDevice:      string, // "" is the system default
	outputDevice:     string, // "" is the system default
	mode:             VoiceGateMode,
	pttKey:           string,
	// Push-to-talk also follows the key while another window has focus (client/hotkey).
	pttGlobal:        bool,
	vadThresholdDB:   f32,
	inputGain:        f32,
	outputVolume:     f32,
	bitrate:          int,
	// Noise suppression on the microphone (#170): WebRTC's or RNNoise. Works only when one of
	// the libraries loads.
	noiseSuppression: bool,
	// AEC3 echo cancellation (#171). Works only when WebRTC audio processing loads.
	echoCancellation: bool,
}

VOICE_DEFAULT_SETTINGS :: VoiceSettings {
	mode             = .VoiceActivity,
	pttKey           = VOICE_DEFAULT_PTT_KEY,
	pttGlobal        = true,
	vadThresholdDB   = VOICE_VAD_DEFAULT_THRESHOLD_DB,
	inputGain        = 1,
	outputVolume     = 1,
	bitrate          = VOICE_BITRATE_DEFAULT,
	noiseSuppression = true,
	echoCancellation = true,
}

@(private = "file")
voiceSettingTextIsValid :: proc(text: string, maxBytes: int) -> bool {
	if len(text) > maxBytes {
		return false
	}
	for index in 0 ..< len(text) {
		if text[index] < 0x20 || text[index] == 0x7f {
			return false
		}
	}
	return true
}

@(private = "file")
voiceClampLevel :: proc(value, low, high, fallback: f32) -> f32 {
	if math.is_nan(value) {
		return fallback
	}
	return clamp(value, low, high)
}

// Clamps every number to its range and replaces an invalid string with its default, so any
// config, however edited, gives settings the engine can use.
voiceSettingsValidate :: proc(settings: VoiceSettings) -> (valid: VoiceSettings) {
	valid = settings
	if !voiceSettingTextIsValid(valid.inputDevice, VOICE_DEVICE_NAME_MAX_BYTES) {
		valid.inputDevice = ""
	}
	if !voiceSettingTextIsValid(valid.outputDevice, VOICE_DEVICE_NAME_MAX_BYTES) {
		valid.outputDevice = ""
	}
	if valid.mode != .VoiceActivity && valid.mode != .PushToTalk {
		valid.mode = .VoiceActivity
	}
	key := strings.trim_space(valid.pttKey)
	if len(key) == 0 || !voiceSettingTextIsValid(key, VOICE_PTT_KEY_MAX_BYTES) {
		key = VOICE_DEFAULT_PTT_KEY
	}
	valid.pttKey = key
	valid.vadThresholdDB = voiceClampLevel(
		valid.vadThresholdDB,
		VOICE_VAD_THRESHOLD_MIN_DB,
		VOICE_VAD_THRESHOLD_MAX_DB,
		VOICE_DEFAULT_SETTINGS.vadThresholdDB,
	)
	valid.inputGain = voiceClampLevel(valid.inputGain, 0, VOICE_INPUT_GAIN_MAX, 1)
	valid.outputVolume = voiceClampLevel(valid.outputVolume, 0, VOICE_OUTPUT_VOLUME_MAX, 1)
	valid.bitrate = clamp(valid.bitrate, VOICE_BITRATE_MIN, VOICE_BITRATE_MAX)
	return
}

// The voice_mode config value for a gate mode, and back. An unknown value is voice activity.
voiceModeConfigValue :: proc(mode: VoiceGateMode) -> string {
	return mode == .PushToTalk ? VOICE_MODE_PUSH_TO_TALK : VOICE_MODE_VOICE_ACTIVITY
}

voiceModeFromConfigValue :: proc(value: string) -> VoiceGateMode {
	return value == VOICE_MODE_PUSH_TO_TALK ? .PushToTalk : .VoiceActivity
}

// The validated voice settings of config, with the default for every key that is missing,
// empty or invalid. Strings borrow from config.
Config_voiceSettings :: proc(config: Config) -> VoiceSettings {
	settings := VOICE_DEFAULT_SETTINGS
	settings.inputDevice = config.voice_input_device
	settings.outputDevice = config.voice_output_device
	settings.mode = voiceModeFromConfigValue(config.voice_mode)
	if len(config.voice_ptt_key) > 0 {
		settings.pttKey = config.voice_ptt_key
	}
	if value, ok := config.voice_ptt_global.?; ok {
		settings.pttGlobal = value
	}
	if value, ok := config.voice_vad_threshold_db.?; ok {
		settings.vadThresholdDB = value
	}
	if value, ok := config.voice_input_gain.?; ok {
		settings.inputGain = value
	}
	if value, ok := config.voice_output_volume.?; ok {
		settings.outputVolume = value
	}
	if value, ok := config.voice_bitrate.?; ok {
		settings.bitrate = value
	}
	if value, ok := config.voice_noise_suppression.?; ok {
		settings.noiseSuppression = value
	}
	if value, ok := config.voice_echo_cancellation.?; ok {
		settings.echoCancellation = value
	}
	return voiceSettingsValidate(settings)
}

@(private = "file")
voiceSetConfigString :: proc(field: ^string, value, defaultValue: string) {
	stored := value == defaultValue ? "" : value
	if field^ == stored {
		return
	}
	delete(field^)
	field^ = strings.clone(stored)
}

// Writes validated settings into config. A setting equal to its default is stored as unset,
// so a later change of the default (for example H8's tuning) still reaches this user.
Config_setVoiceSettings :: proc(config: ^Config, settings: VoiceSettings) {
	valid := voiceSettingsValidate(settings)
	// valid may borrow from the fields being replaced, so copy its strings first.
	inputDevice := strings.clone(valid.inputDevice, context.temp_allocator)
	outputDevice := strings.clone(valid.outputDevice, context.temp_allocator)
	pttKey := strings.clone(valid.pttKey, context.temp_allocator)
	voiceSetConfigString(&config.voice_input_device, inputDevice, "")
	voiceSetConfigString(&config.voice_output_device, outputDevice, "")
	mode := voiceModeConfigValue(valid.mode)
	voiceSetConfigString(&config.voice_mode, mode, VOICE_MODE_VOICE_ACTIVITY)
	voiceSetConfigString(&config.voice_ptt_key, pttKey, VOICE_DEFAULT_PTT_KEY)
	defaults := VOICE_DEFAULT_SETTINGS
	config.voice_ptt_global = nil
	if valid.pttGlobal != defaults.pttGlobal {
		config.voice_ptt_global = valid.pttGlobal
	}
	config.voice_vad_threshold_db = nil
	if valid.vadThresholdDB != defaults.vadThresholdDB {
		config.voice_vad_threshold_db = valid.vadThresholdDB
	}
	config.voice_input_gain = nil
	if valid.inputGain != defaults.inputGain {
		config.voice_input_gain = valid.inputGain
	}
	config.voice_output_volume = nil
	if valid.outputVolume != defaults.outputVolume {
		config.voice_output_volume = valid.outputVolume
	}
	config.voice_bitrate = nil
	if valid.bitrate != defaults.bitrate {
		config.voice_bitrate = valid.bitrate
	}
	config.voice_noise_suppression = nil
	if valid.noiseSuppression != defaults.noiseSuppression {
		config.voice_noise_suppression = valid.noiseSuppression
	}
	config.voice_echo_cancellation = nil
	if valid.echoCancellation != defaults.echoCancellation {
		config.voice_echo_cancellation = valid.echoCancellation
	}
}

// Returns base with the user's settings applied: device names, gate mode, levels, bitrate,
// noise suppression and echo cancellation.
// The source and sink kinds stay as they are, so a test or the harness that runs on tones,
// files or null sinks keeps them; device names only matter to device sources and sinks.
// Strings are borrowed; State_setVoiceEngineTemplate clones them.
voiceEngineConfigWithSettings :: proc(
	base: VoiceEngineConfig,
	settings: VoiceSettings,
) -> VoiceEngineConfig {
	config := base
	config.source.deviceName = settings.inputDevice
	config.sink.deviceName = settings.outputDevice
	config.gateMode = settings.mode
	config.vadThresholdDB = settings.vadThresholdDB
	config.inputGain = settings.inputGain
	config.outputVolume = settings.outputVolume
	config.explicitLevels = true
	config.noiseSuppression = settings.noiseSuppression
	config.echoCancellation = settings.echoCancellation
	if config.encoder == {} {
		config.encoder = opus.VOICE_ENCODER_SETTINGS
	}
	config.encoder.bitrate = i32(settings.bitrate)
	return config
}

// The template the GUI starts from: microphone and speakers, with the config's settings.
voiceDefaultEngineTemplate :: proc(config: Config) -> VoiceEngineConfig {
	settings := Config_voiceSettings(config)
	return voiceEngineConfigWithSettings(VOICE_DEFAULT_ENGINE_TEMPLATE, settings)
}

// Applies the settings that a running engine can change in place.
VoiceEngine_applySettings :: proc(engine: ^VoiceEngine, settings: VoiceSettings) {
	VoiceEngine_setGateMode(engine, settings.mode)
	VoiceEngine_setVADThreshold(engine, settings.vadThresholdDB)
	VoiceEngine_setInputGain(engine, settings.inputGain)
	VoiceEngine_setOutputVolume(engine, settings.outputVolume)
	VoiceEngine_setBitrate(engine, i32(settings.bitrate))
	VoiceEngine_setNoiseSuppression(engine, settings.noiseSuppression)
	VoiceEngine_setEchoCancellation(engine, settings.echoCancellation)
}

// Whether a settings change needs the engine reopened rather than applied in place: a new
// input or output device, or (on Windows) a change of whether HayChat processes the
// microphone itself, since SDL reads the raw stream hint (voiceSDLRawStream) only when it
// opens a device.
voiceSettingsNeedReopen :: proc(
	previous, next: VoiceSettings,
	os: runtime.Odin_OS_Type = ODIN_OS,
) -> bool {
	if previous.inputDevice != next.inputDevice || previous.outputDevice != next.outputDevice {
		return true
	}
	previousRaw := voiceSDLRawStream(os, previous.noiseSuppression, previous.echoCancellation)
	nextRaw := voiceSDLRawStream(os, next.noiseSuppression, next.echoCancellation)
	return previousRaw != nextRaw
}

State_voiceSettings :: proc(state: ^State) -> VoiceSettings {
	return Config_voiceSettings(state.config)
}

// Replaces the template's settings part, keeping its source and sink kinds and paths.
@(private = "file")
State_voiceUpdateTemplate :: proc(state: ^State, settings: VoiceSettings) {
	template := voiceEngineConfigWithSettings(state.voice.engineTemplate, settings)
	// State_setVoiceEngineTemplate frees the old strings before cloning the new ones, and
	// these still point at them.
	template.source.path = strings.clone(template.source.path, context.temp_allocator)
	template.sink.path = strings.clone(template.sink.path, context.temp_allocator)
	template.source.deviceName = strings.clone(template.source.deviceName, context.temp_allocator)
	template.sink.deviceName = strings.clone(template.sink.deviceName, context.temp_allocator)
	State_setVoiceEngineTemplate(state, template)
}

// Changes the voice settings: validates them, stores them in the config (and saves it when
// persist is set; a slider being dragged passes false until it is released), updates the
// template, and reapplies them to the joined engine and the microphone test. A new input or
// output device (or on Windows a change of the raw stream, voiceSettingsNeedReopen) reopens
// the engine; the session stays joined and the server is not told.
State_applyVoiceSettings :: proc(state: ^State, settings: VoiceSettings, persist := true) {
	// settings may borrow from the config fields that are about to be replaced.
	next := voiceSettingsValidate(settings)
	next.inputDevice = strings.clone(next.inputDevice, context.temp_allocator)
	next.outputDevice = strings.clone(next.outputDevice, context.temp_allocator)
	next.pttKey = strings.clone(next.pttKey, context.temp_allocator)
	previous := State_voiceSettings(state)
	devicesChanged := voiceSettingsNeedReopen(previous, next)

	Config_setVoiceSettings(&state.config, next)
	if persist {
		State_saveConfig(state)
	}
	State_voiceUpdateTemplate(state, next)

	if next.mode != .PushToTalk {
		state.voice.pushToTalkWindowHeld = false
		if state.voice.pushToTalkHeld {
			State_voicePushToTalkChanged(state, false)
		}
	}
	if state.voice.engine != nil {
		if devicesChanged {
			State_voiceRestartEngine(state)
		} else {
			VoiceEngine_applySettings(state.voice.engine, next)
		}
	}
	panel := &state.voicePanel
	if panel.testEngine != nil {
		if devicesChanged {
			State_stopVoiceTest(state)
			State_startVoiceTest(state)
		} else {
			VoiceEngine_applySettings(panel.testEngine, next)
		}
	}
}

// Saves the config after changes applied with persist = false.
State_saveVoiceSettings :: proc(state: ^State) {
	State_saveConfig(state)
}

// Push-to-talk went down or up (from State_voiceSyncPushToTalk in the GUI). It drives the
// joined engine and the microphone test.
State_voicePushToTalkChanged :: proc(state: ^State, held: bool) {
	State_setVoicePushToTalk(state, held)
	if state.voicePanel.testEngine != nil {
		VoiceEngine_setPushToTalk(state.voicePanel.testEngine, held)
	}
}

// ── Global push-to-talk (issue 45) ────────────────────────────────

// Whether push-to-talk can matter now: voice is joining or joined, or the microphone test
// runs. Only then is the global monitor armed, so it reads no key and (on Wayland) shows no
// desktop dialog at any other time.
State_voicePushToTalkInUse :: proc(state: ^State) -> bool {
	return(
		state.voice.status == .Joining ||
		state.voice.status == .Joined ||
		state.voicePanel.testEngine != nil \
	)
}

// Push-to-talk from both sources: the window's own key events and the global monitor. A held
// global key that types is ignored while HayChat has focus and a text field has keyboard
// focus, exactly like the window's own key events (voicePushToTalkKeyEvent), so typing that
// letter in the message box never opens the microphone.
voicePushToTalkCombined :: proc(
	windowHeld, globalHeld, focused, textFocused: bool,
	key: SDL.Keycode,
) -> bool {
	if globalHeld && focused && textFocused && voiceKeyEditsText(key) {
		return windowHeld
	}
	return windowHeld || globalHeld
}

// Runs once per GUI loop pass, after the events: points the global monitor at the configured
// key, arms it while push-to-talk is in use and allowed in other windows, and applies the
// combined state to the engine and the test. Returns true when the settings view shows
// something new (the monitor's report changed).
State_voiceSyncPushToTalk :: proc(state: ^State, textFocused: bool) -> bool {
	settings := State_voiceSettings(state)
	key := SDL.Keycode(0)
	if settings.mode == .PushToTalk {
		key = voicePushToTalkKeyFromName(settings.pttKey)
	}
	monitor := state.voice.globalPushToTalk
	armed := key != 0 && settings.pttGlobal && State_voicePushToTalkInUse(state)
	hotkey.setKey(monitor, key)
	hotkey.setArmed(monitor, armed)
	globalHeld := armed && hotkey.held(monitor)
	windowHeld := key != 0 && state.voice.pushToTalkWindowHeld
	held := voicePushToTalkCombined(
		windowHeld,
		globalHeld,
		state.windowFocused,
		textFocused,
		key,
	)
	if held != state.voice.pushToTalkHeld {
		State_voicePushToTalkChanged(state, held)
	}
	if monitor == nil {
		return false
	}
	report := hotkey.report(monitor)
	if report == state.voice.globalReport {
		return false
	}
	state.voice.globalReport = report
	return state.voicePanel.visible
}

// Opens the desktop's dialog for the push-to-talk shortcut (Wayland portal version 2).
State_configureGlobalPushToTalk :: proc(state: ^State) {
	hotkey.requestConfigure(state.voice.globalPushToTalk)
}

// ── Settings → Voice panel ────────────────────────────────────────

// What the Voice section of the settings screen keeps while it is open. The device lists
// and the SDL audio subsystem are held only then.
VoiceSettingsPanel :: struct {
	visible:          bool,
	// The panel's own reference on SDL's audio subsystem, for listing devices.
	audioInitialised: bool,
	audioError:       string, // Owned; why devices cannot be listed
	inputDevices:     [dynamic]string, // Owned names
	outputDevices:    [dynamic]string, // Owned names
	// The microphone test: a loopback engine (microphone → Opus → your own speakers).
	testEngine:       ^VoiceEngine,
	testError:        string, // Owned
	// The next key press becomes the push-to-talk key.
	capturingKey:     bool,
	// The section's height on the last frame, for its scroll area.
	contentH:         f32,
}

@(private = "file")
voiceDeleteNames :: proc(names: ^[dynamic]string) {
	for name in names {
		delete(name)
	}
	clear(names)
}

@(private = "file")
voiceSetOwnedText :: proc(field: ^string, text: string) {
	delete(field^)
	field^ = strings.clone(text)
}

VoiceSettingsPanel_deinit :: proc(panel: ^VoiceSettingsPanel) {
	voiceDeleteNames(&panel.inputDevices)
	voiceDeleteNames(&panel.outputDevices)
	delete(panel.inputDevices)
	delete(panel.outputDevices)
	delete(panel.audioError)
	delete(panel.testError)
	panel^ = {}
}

// Lists SDL's recording or playback device names, in SDL's order, into names.
@(private = "file")
voiceListDeviceNames :: proc(names: ^[dynamic]string, recording: bool) {
	voiceDeleteNames(names)
	count: c.int
	devices :=
		recording ? SDL.GetAudioRecordingDevices(&count) : SDL.GetAudioPlaybackDevices(&count)
	if devices == nil {
		return
	}
	defer SDL.free(devices)
	for index in 0 ..< int(count) {
		name := SDL.GetAudioDeviceName(devices[index])
		if name != nil && len(name) > 0 {
			append(names, strings.clone(string(name)))
		}
	}
}

// Lists the devices again (on opening the panel and on hotplug).
State_refreshVoiceDevices :: proc(state: ^State) {
	panel := &state.voicePanel
	if !panel.audioInitialised {
		return
	}
	voiceListDeviceNames(&panel.inputDevices, true)
	voiceListDeviceNames(&panel.outputDevices, false)
}

// Shows or hides the Voice section; the view calls it every frame. Showing it takes a
// reference on SDL's audio subsystem and lists the devices; hiding it stops the microphone
// test and gives everything back. Without an audio subsystem (no driver, a container) the
// section still works: it offers only the system default and says why.
State_setVoiceSettingsVisible :: proc(state: ^State, visible: bool) {
	panel := &state.voicePanel
	if panel.visible == visible {
		return
	}
	panel.visible = visible
	panel.capturingKey = false
	if visible {
		voiceSetOwnedText(&panel.audioError, "")
		voiceSetOwnedText(&panel.testError, "")
		if SDL.InitSubSystem({.AUDIO}) {
			panel.audioInitialised = true
			State_refreshVoiceDevices(state)
		} else {
			voiceSetOwnedText(&panel.audioError, string(SDL.GetError()))
		}
		return
	}
	State_stopVoiceTest(state)
	voiceDeleteNames(&panel.inputDevices)
	voiceDeleteNames(&panel.outputDevices)
	if panel.audioInitialised {
		SDL.QuitSubSystem({.AUDIO})
		panel.audioInitialised = false
	}
}

// Starts the microphone test: the template's source and sink in loopback, so the user hears
// themselves through Opus and sees the level against the threshold without joining a room.
// Not while in voice, which already uses the microphone (the meter then shows that engine).
State_startVoiceTest :: proc(state: ^State) -> bool {
	panel := &state.voicePanel
	if panel.testEngine != nil {
		return true
	}
	if state.voice.engine != nil {
		return false
	}
	config := state.voice.engineTemplate
	config.loopback = true
	config.onOutbound = nil
	config.outboundUserdata = nil
	engine := VoiceEngine_create(config)
	VoiceEngine_setPushToTalk(engine, state.voice.pushToTalkHeld)
	if !VoiceEngine_start(engine) {
		voiceSetOwnedText(&panel.testError, VoiceEngine_lastError(engine))
		VoiceEngine_destroy(engine)
		return false
	}
	voiceSetOwnedText(&panel.testError, "")
	panel.testEngine = engine
	return true
}

State_stopVoiceTest :: proc(state: ^State) {
	panel := &state.voicePanel
	if panel.testEngine == nil {
		return
	}
	VoiceEngine_destroy(panel.testEngine)
	panel.testEngine = nil
}

// Keeps the test from running beside a voice session (the user may join, or re-join after a
// reconnect, while the panel is open). Called once per frame.
State_voiceSettingsFrame :: proc(state: ^State) {
	if state.voicePanel.testEngine != nil &&
	   (state.voice.engine != nil || state.voice.status == .Joining) {
		State_stopVoiceTest(state)
	}
}

// The engine whose input level the meters show: the joined one, else the microphone test.
State_voiceMeterEngine :: proc(state: ^State) -> ^VoiceEngine {
	if state.voice.engine != nil {
		return state.voice.engine
	}
	return state.voicePanel.testEngine
}

// Whether audio meters and speaking dots may move, so the frame loop should check them about
// every VOICE_REDRAW_INTERVAL_MS (and redraw when State_voiceVisualKey changed).
State_voiceNeedsRedraws :: proc(state: ^State) -> bool {
	return state.voice.status == .Joined || state.voicePanel.testEngine != nil
}

// For the frame loop, on every pass: whether the engine-driven voice state on screen
// (State_voiceVisualKey) changed since the last frame drew it. It checks only while
// State_voiceNeedsRedraws and at most every VOICE_REDRAW_INTERVAL_MS, keeping the next check's
// time in pollAtMS; the loop wakes for that time.
State_voiceRedrawDue :: proc(state: ^State, nowMS: u64, pollAtMS: ^u64) -> bool {
	if !State_voiceNeedsRedraws(state) || nowMS < pollAtMS^ {
		return false
	}
	pollAtMS^ = nowMS + VOICE_REDRAW_INTERVAL_MS
	return State_voiceVisualKey(state) != state.voice.drawnVisual
}

// Starts or stops capturing the push-to-talk key.
State_setVoiceKeyCapture :: proc(state: ^State, capturing: bool) {
	state.voicePanel.capturingKey = capturing
}

// Takes the captured key's SDL name as the push-to-talk key and ends the capture.
State_setVoicePushToTalkKey :: proc(state: ^State, keyName: string) {
	state.voicePanel.capturingKey = false
	if len(keyName) == 0 {
		return
	}
	settings := State_voiceSettings(state)
	settings.pttKey = keyName
	State_applyVoiceSettings(state, settings)
}

// A key pressed while capturing: Esc cancels, any other key with a name becomes the
// push-to-talk key.
State_captureVoicePushToTalkKey :: proc(state: ^State, key: SDL.Keycode) {
	if key == SDL.K_ESCAPE {
		State_setVoiceKeyCapture(state, false)
		return
	}
	name := SDL.GetKeyName(key)
	if name == nil || len(name) == 0 {
		return
	}
	State_setVoicePushToTalkKey(state, string(name))
}

// The keycode of the configured push-to-talk key, or 0 when push-to-talk is off. A name SDL
// does not know falls back to the default key.
State_voicePushToTalkKeycode :: proc(state: ^State) -> SDL.Keycode {
	settings := State_voiceSettings(state)
	if settings.mode != .PushToTalk {
		return 0
	}
	return voicePushToTalkKeyFromName(settings.pttKey)
}

voicePushToTalkKeyFromName :: proc(name: string) -> SDL.Keycode {
	key := SDL.GetKeyFromName(strings.clone_to_cstring(name, context.temp_allocator))
	if key == SDL.K_UNKNOWN {
		key = SDL.GetKeyFromName(VOICE_DEFAULT_PTT_KEY)
	}
	return key
}

// Whether a focused text field uses key: a character key (letters, digits, punctuation,
// Space) or Enter, Tab, Backspace, Delete or Esc. These are exactly the SDL keycodes without
// SDLK_SCANCODE_MASK; modifiers, function keys, arrows and the like carry it.
voiceKeyEditsText :: proc(key: SDL.Keycode) -> bool {
	return key != SDL.K_UNKNOWN && key & SDL.K_SCANCODE_MASK == 0
}

// What one key event does to push-to-talk. pttKey is 0 when push-to-talk is off. A key that
// edits text is ignored while a text field has keyboard focus, so a letter or Space chosen as
// the push-to-talk key types normally in the message box instead of opening the microphone;
// keys a text field does not use (the default Left Ctrl, F-keys, ...) work everywhere. A key
// up always releases a held key, even if a text field took focus in between.
voicePushToTalkKeyEvent :: proc(
	pttKey, key: SDL.Keycode,
	down, held, textFocused: bool,
) -> (
	change: bool,
	nextHeld: bool,
) {
	if pttKey == 0 || key != pttKey {
		return false, held
	}
	if !down {
		return held, false
	}
	if held || (textFocused && voiceKeyEditsText(key)) {
		return false, held
	}
	return true, true
}

// Whether name is among the listed devices.
voiceDeviceListed :: proc(names: []string, name: string) -> bool {
	for listed in names {
		if listed == name {
			return true
		}
	}
	return false
}

// Whether an engine should reopen after a hotplug event. A named device it uses went away
// (SDL would leave that stream silent, while a reopen falls back to the system default), or
// it fell back to the default at open time and every named device is back. A device that is
// not named (the system default) follows the system by itself.
VoiceDeviceUse :: struct {
	named:   bool, // a device source or sink with a device name
	present: bool, // that name is in SDL's current list
}

voiceDevicesNeedReopen :: proc(input, output: VoiceDeviceUse, usedFallback: bool) -> bool {
	if !input.named && !output.named {
		return false
	}
	inputMissing := input.named && !input.present
	outputMissing := output.named && !output.present
	if usedFallback {
		return !inputMissing && !outputMissing
	}
	return inputMissing || outputMissing
}

@(private = "file")
voiceEngineNeedsReopen :: proc(engine: ^VoiceEngine) -> bool {
	// The engine holds the audio subsystem while it uses a device; without it there is no
	// list to compare with, and nothing to reopen.
	if .AUDIO not_in SDL.WasInit({.AUDIO}) {
		return false
	}
	inputs, outputs: [dynamic]string
	defer {
		voiceDeleteNames(&inputs)
		voiceDeleteNames(&outputs)
		delete(inputs)
		delete(outputs)
	}
	voiceListDeviceNames(&inputs, true)
	voiceListDeviceNames(&outputs, false)
	source := engine.config.source
	sink := engine.config.sink
	input := VoiceDeviceUse {
		named   = source.kind == .Device && len(source.deviceName) > 0,
		present = voiceDeviceListed(inputs[:], source.deviceName),
	}
	output := VoiceDeviceUse {
		named   = sink.kind == .Device && len(sink.deviceName) > 0,
		present = voiceDeviceListed(outputs[:], sink.deviceName),
	}
	return voiceDevicesNeedReopen(input, output, VoiceEngine_usedDeviceFallback(engine))
}

// SDL reported an audio device added or removed: refresh the panel's lists, and reopen an
// engine whose named device went away (it falls back to the system default) or came back.
State_voiceAudioDevicesChanged :: proc(state: ^State) {
	State_refreshVoiceDevices(state)
	if state.voice.engine != nil && voiceEngineNeedsReopen(state.voice.engine) {
		State_voiceRestartEngine(state)
	}
	if state.voicePanel.testEngine != nil && voiceEngineNeedsReopen(state.voicePanel.testEngine) {
		State_stopVoiceTest(state)
		State_startVoiceTest(state)
	}
}
