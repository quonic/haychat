package client

// Voice view models (voice-rooms-design.md 5.3): the participants under each room in the
// channel list, the room header's join or leave button, the voice bar at the bottom of the
// sidebar, and the Settings → Voice section. Pure snapshots of State, plus the engines'
// lock-free level and their published snapshot, so tests check them without a window.

import "../common"
import "core:fmt"
import "core:math"
import "hotkey"
import "rnnoise"
import "webrtcapm"

// One user in a room's voice. The server keeps one voice session per user (Q2, protocol 13),
// so each user is listed once.
VoiceParticipantRow :: struct {
	userID:   int,
	label:    string, // Borrowed from State, or allocated with the view allocator
	isSelf:   bool,
	// Only known for the room this client is joined to, from the engine's speakers (and the
	// gate for this user).
	speaking: bool,
	muted:    bool,
	deafened: bool,
	// Protocol 21, the joined encrypted room only: why this participant cannot be heard
	// ("Waiting for <name>'s voice key", "Clock out of sync"); "" when its key is held.
	keyNote:  string,
}

// Everything on screen that the voice engines change without an event: the level meter
// (the voice bar's, or Settings → Voice's, which show the same engine), whether that engine
// transmits, and who speaks. Comparable with ==, so the frame loop redraws only when one of
// them would look different (app.odin, State_voiceNeedsRedraws). Mute, deafen and the
// participant lists arrive as events, which redraw anyway.
VoiceVisualKey :: struct {
	// Clamped to the meter's range and rounded to whole dB: a smaller change moves the meter
	// by at most a pixel or two.
	meterLevelDB:  i32,
	transmitting:  bool,
	// The joined engine's speakers that are speaking, in slot order (0 elsewhere).
	speakingUsers: [VOICE_MAX_SPEAKERS]u32,
}

// The key from an engine's level and snapshot; snapshot may be nil.
voiceVisualKey :: proc(
	levelDB: f32,
	transmitting: bool,
	snapshot: ^VoiceEngineSnapshot,
) -> VoiceVisualKey {
	key := VoiceVisualKey {
		meterLevelDB = i32(
			math.round(clamp(levelDB, VOICE_METER_FLOOR_DB, VOICE_METER_CEILING_DB)),
		),
		transmitting = transmitting,
	}
	if snapshot != nil {
		for speaker, index in snapshot.speakers[:snapshot.speakerCount] {
			if speaker.speaking {
				key.speakingUsers[index] = speaker.userID
			}
		}
	}
	return key
}

State_voiceVisualKey :: proc(state: ^State) -> VoiceVisualKey {
	levelDB := VOICE_LEVEL_FLOOR_DB
	transmitting := false
	if engine := State_voiceMeterEngine(state); engine != nil {
		levelDB, transmitting = VoiceEngine_inputLevel(engine)
	}
	if state.voice.engine == nil {
		return voiceVisualKey(levelDB, transmitting, nil)
	}
	snapshot := VoiceEngine_snapshot(state.voice.engine)
	return voiceVisualKey(levelDB, transmitting, &snapshot)
}

// Whether userID is speaking in the joined room's engine.
@(private = "file")
voiceSnapshotSpeaking :: proc(snapshot: ^VoiceEngineSnapshot, userID: int) -> bool {
	for index in 0 ..< snapshot.speakerCount {
		speaker := snapshot.speakers[index]
		if int(speaker.userID) == userID && speaker.speaking {
			return true
		}
	}
	return false
}

// The users in roomID's voice on serverID, in the server's order, each once.
buildVoiceParticipantRows :: proc(
	state: ^State,
	serverID, roomID: int,
	allocator := context.temp_allocator,
) -> []VoiceParticipantRow {
	participants := State_voiceRoomParticipants(state, serverID, roomID)
	if len(participants) == 0 {
		return nil
	}
	// Speaking is known only where this client is joined and its engine runs.
	joinedHere :=
		state.voice.status == .Joined &&
		state.voice.serverID == serverID &&
		state.voice.roomID == roomID &&
		state.voice.engine != nil
	if !joinedHere {
		return voiceParticipantRows(participants, State_selfUserID(state, serverID), nil, allocator)
	}
	speech := VoiceSpeechState {
		snapshot = VoiceEngine_snapshot(state.voice.engine),
	}
	_, speech.selfTransmitting = VoiceEngine_inputLevel(state.voice.engine)
	speech.selfTransmitting &&= !state.voice.muted
	rows := voiceParticipantRows(
		participants,
		State_selfUserID(state, serverID),
		&speech,
		allocator,
	)
	for &row in rows {
		row.keyNote = State_voiceE2EEParticipantNote(state, serverID, roomID, row.userID, allocator)
	}
	return rows
}

// Who is speaking in the joined room: the engine's speakers, and this client's own gate.
VoiceSpeechState :: struct {
	snapshot:         VoiceEngineSnapshot,
	selfTransmitting: bool,
}

// One row per user, in the server's order. The server lists each user once (Q2); a repeated
// user ID, which only a server older than protocol 13 could send, keeps its first entry, so
// the sidebar never shows anyone twice. speech is nil outside the joined room.
voiceParticipantRows :: proc(
	participants: []common.VoiceParticipant,
	selfUserID: int,
	speech: ^VoiceSpeechState,
	allocator := context.temp_allocator,
) -> []VoiceParticipantRow {
	rows := make([dynamic]VoiceParticipantRow, 0, len(participants), allocator)
	for participant in participants {
		listed := false
		for row in rows {
			listed ||= row.userID == participant.userId
		}
		if listed {
			continue
		}
		append(
			&rows,
			VoiceParticipantRow {
				userID = participant.userId,
				label = userLabel(participant.nickname, participant.userId, allocator),
				isSelf = selfUserID != 0 && participant.userId == selfUserID,
				muted = participant.muted,
				deafened = participant.deafened,
			},
		)
	}
	if speech != nil {
		for &row in rows {
			row.speaking = voiceSnapshotSpeaking(&speech.snapshot, row.userID)
			if row.isSelf && speech.selfTransmitting {
				row.speaking = true
			}
		}
	}
	return rows[:]
}

// The voice button in a room's header.
VoiceHeaderAction :: enum u8 {
	None, // not connected, not a member of the room, or a text-only room
	Join,
	Leave, // joined, joining or re-joining this room
}

VOICE_JOIN_TEXT :: "Join voice"
VOICE_LEAVE_TEXT :: "Leave voice"

roomVoiceHeaderAction :: proc(state: ^State, serverID, roomID: int) -> VoiceHeaderAction {
	if roomID <= 0 || !State_isServerConnected(state, serverID) {
		return .None
	}
	cacheIndex := State_serverRoomCacheIndex(state^, serverID)
	if cacheIndex < 0 ||
	   !ServerRoomCache_roomIsJoined(&state.server_room_caches[cacheIndex], roomID) {
		return .None
	}
	voice := &state.voice
	if voice.serverID == serverID {
		switch voice.status {
		case .Joining, .Joined:
			if voice.roomID == roomID {
				return .Leave
			}
		case .Idle:
			if voice.wantVoiceRoomID == roomID {
				return .Leave
			}
		case .Unavailable:
		}
	}
	// A text-only room (protocol 14) has no voice to join.
	if !State_roomAllowsVoice(state, serverID, roomID) {
		return .None
	}
	return .Join
}

// "#name on Server" for the voice bar, falling back to the room ID while the room list is
// not loaded.
voiceRoomPlaceText :: proc(
	state: ^State,
	serverID, roomID: int,
	allocator := context.temp_allocator,
) -> string {
	roomName := ""
	if index := State_serverRoomCacheIndex(state^, serverID); index >= 0 {
		for room in state.server_room_caches[index].rooms {
			if room.id == roomID {
				roomName = room.name
				break
			}
		}
	}
	serverName := ""
	if server, ok := State_serverConfig(state, serverID); ok {
		serverName = server.name
	}
	room := fmt.aprintf("room %d", roomID, allocator = allocator)
	if len(roomName) > 0 {
		room = fmt.aprintf("#%s", roomName, allocator = allocator)
	}
	if len(serverName) == 0 {
		return room
	}
	return fmt.aprintf("%s on %s", room, serverName, allocator = allocator)
}

VoiceBarKind :: enum u8 {
	Hidden,
	Joined,
	Joining,
	Rejoining, // Idle, waiting to re-join after a reconnect
	Unavailable, // libopus or a device failed
	Notice, // the server refused or ended voice; the reason stays until dismissed
}

VoiceBarView :: struct {
	kind:         VoiceBarKind,
	text:         string, // Allocated with the view allocator, or borrowed from State
	// Shown under the text, e.g. that a named microphone was not found.
	note:         string,
	isError:      bool,
	// Mute, Deafen and Leave; otherwise only Dismiss.
	showControls: bool,
	muted:        bool,
	deafened:     bool,
	// Your own level meter and speaking dot, while the engine runs.
	showLevel:    bool,
	levelDB:      f32,
	speaking:     bool,
	// Protocol 21: voice in this room is end-to-end encrypted (a lock and
	// VOICE_E2EE_ENCRYPTED_NOTE).
	encrypted:    bool,
	// Protocol 24: the room grants this account no SpeakInVoice (VOICE_SPEAK_NOT_PERMITTED_NOTE
	// in note); it listens only.
	speakDenied:  bool,
}

VOICE_UNAVAILABLE_FALLBACK_TEXT :: "Voice unavailable"
VOICE_DEVICE_FALLBACK_NOTE :: "A chosen audio device was not found; using the system default."

buildVoiceBarView :: proc(
	state: ^State,
	allocator := context.temp_allocator,
) -> (
	view: VoiceBarView,
) {
	voice := &state.voice
	view.muted = voice.muted
	view.deafened = voice.deafened
	switch voice.status {
	case .Joined:
		view.kind = .Joined
		view.text = fmt.aprintf(
			"Voice connected: %s",
			voiceRoomPlaceText(state, voice.serverID, voice.roomID, allocator),
			allocator = allocator,
		)
		view.showControls = true
		if voice.engine != nil {
			view.showLevel = true
			view.levelDB, view.speaking = VoiceEngine_inputLevel(voice.engine)
			view.speaking &&= !voice.muted && !voice.speakDenied
			if VoiceEngine_usedDeviceFallback(voice.engine) {
				view.note = VOICE_DEVICE_FALLBACK_NOTE
			}
		}
	case .Joining:
		view.kind = .Joining
		view.text = fmt.aprintf(
			"Joining voice: %s…",
			voiceRoomPlaceText(state, voice.serverID, voice.roomID, allocator),
			allocator = allocator,
		)
		view.showControls = true
	case .Idle:
		if voice.wantVoiceRoomID != 0 {
			view.kind = .Rejoining
			view.text = fmt.aprintf(
				"Rejoining voice: %s…",
				voiceRoomPlaceText(state, voice.serverID, voice.wantVoiceRoomID, allocator),
				allocator = allocator,
			)
			view.showControls = true
		} else if len(voice.lastError) > 0 {
			view.kind = .Notice
			view.text = voice.lastError
			view.isError = true
		}
	case .Unavailable:
		view.kind = .Unavailable
		view.text = len(voice.lastError) > 0 ? voice.lastError : VOICE_UNAVAILABLE_FALLBACK_TEXT
		view.isError = true
	}
	if view.kind == .Joining || view.kind == .Rejoining {
		// A failed send of a mute or deafen change, or a failed re-join attempt.
		view.note = voice.lastError
	}
	switch view.kind {
	case .Joined, .Joining, .Rejoining:
		if voice.encrypted {
			view.encrypted = true
			lock := "🔒 " + VOICE_E2EE_ENCRYPTED_NOTE
			if len(view.note) > 0 {
				lock = fmt.aprintf("%s · %s", lock, view.note, allocator = allocator)
			}
			view.note = lock
		}
	case .Hidden, .Unavailable, .Notice:
	}
	if (view.kind == .Joined || view.kind == .Joining) && voice.speakDenied {
		view.speakDenied = true
		if len(view.note) > 0 {
			view.note = fmt.aprintf(
				"%s · %s",
				VOICE_SPEAK_NOT_PERMITTED_NOTE,
				view.note,
				allocator = allocator,
			)
		} else {
			view.note = VOICE_SPEAK_NOT_PERMITTED_NOTE
		}
	}
	return
}

// ── Settings → Voice ──────────────────────────────────────────────

VOICE_SYSTEM_DEFAULT_LABEL :: "System default"

VoiceDeviceOption :: struct {
	name:     string, // "" for the system default; borrowed
	label:    string, // borrowed, or allocated with the view allocator
	selected: bool,
}

VoiceMeterSource :: enum u8 {
	None, // nothing captures: the test is off and the user is not in voice
	Voice, // the joined engine
	Test, // the microphone test
}

VoiceSettingsView :: struct {
	settings:          VoiceSettings,
	inputOptions:      []VoiceDeviceOption,
	outputOptions:     []VoiceDeviceOption,
	// Why devices cannot be listed; the lists then offer only the system default.
	devicesNote:       string,
	pttKeyLabel:       string,
	// Where push-to-talk works (voicePushToTalkNotice), plus what a key that types does.
	pttNotice:         string,
	// The "in other windows too" toggle is offered: this system has a global backend.
	pttGlobalOffered:  bool,
	// The desktop can show its shortcut dialog (Wayland portal version 2, session active).
	pttCanConfigure:   bool,
	capturingKey:      bool,
	thresholdText:     string,
	inputGainText:     string,
	outputVolumeText:  string,
	bitrateText:       string,
	// #170: whether a suppressor loads, the toggle's text, and what it does or why it is
	// missing.
	noiseAvailable:    bool,
	noiseText:         string,
	noiseNote:         string,
	// #171: the same for echo cancellation, and the notice at the top of the section while it
	// does not run ("" while it does).
	echoAvailable:     bool,
	echoText:          string,
	echoNote:          string,
	echoNotice:        string,
	meter:             VoiceMeterSource,
	levelDB:           f32,
	transmitting:      bool,
	meterNote:         string,
	testRunning:       bool,
	testEnabled:       bool,
	testButtonText:    string,
	testError:         string,
}

// The notice at the top of Settings → Voice while echo cancellation does not run.
VOICE_ECHO_UNAVAILABLE_NOTICE ::
	"Echo cancellation is unavailable here: use headphones, or others hear themselves through " +
	"your microphone."
VOICE_ECHO_OFF_NOTICE ::
	"Echo cancellation is off: use headphones, or others hear themselves through your " +
	"microphone."
VOICE_PTT_FOCUS_NOTICE :: "Push-to-talk works only while the HayChat window has focus."
VOICE_PTT_TYPING_ADDENDUM ::
	" This key types, so it does nothing while you are typing in a text field; a key such as " +
	"Ctrl or an F-key works everywhere."
VOICE_PTT_TYPING_NOTICE :: VOICE_PTT_FOCUS_NOTICE + VOICE_PTT_TYPING_ADDENDUM
VOICE_PTT_GLOBAL_TYPING_ADDENDUM ::
	" This key types: in a HayChat text field it types instead, but in other windows it " +
	"opens your microphone while you type. A key such as Ctrl or an F-key avoids that."
VOICE_PTT_GLOBAL_POLLING_NOTICE ::
	"Push-to-talk also works while another window has focus. HayChat reads only this key, " +
	"and only while you are in voice or testing your microphone."
VOICE_PTT_GLOBAL_UNSUPPORTED_KEY_NOTICE ::
	"This key cannot be followed outside HayChat, so push-to-talk works only while the " +
	"HayChat window has focus. Modifiers, F-keys, letters, digits and the keypad work in " +
	"every window."
VOICE_PTT_NO_GLOBAL_NOTICE ::
	VOICE_PTT_FOCUS_NOTICE +
	" This system offers no global hotkey (Windows, X11 and Wayland desktops with the " +
	"GlobalShortcuts portal do)."
VOICE_PTT_PORTAL_IDLE_NOTICE ::
	"In other windows, push-to-talk is a desktop shortcut. The first time you use " +
	"push-to-talk in voice, your desktop asks you to confirm it, and may let you choose its key."
VOICE_PTT_PORTAL_UNASSIGNED_NOTICE ::
	"In other windows, push-to-talk is a desktop shortcut without a key yet. Assign one in " +
	"your desktop's shortcut settings."

// Where push-to-talk works, for the settings note: only in the window, or also in other
// windows through the global monitor, and what a key that types does there. present says
// the GUI has a monitor (tests and the harness have none).
voicePushToTalkNotice :: proc(
	settings: VoiceSettings,
	report: hotkey.StatusReport,
	present: bool,
	allocator := context.temp_allocator,
) -> string {
	report := report
	types := voiceKeyEditsText(voicePushToTalkKeyFromName(settings.pttKey))
	typing := types ? VOICE_PTT_TYPING_ADDENDUM : ""
	if !present || !settings.pttGlobal {
		return types ? VOICE_PTT_TYPING_NOTICE : VOICE_PTT_FOCUS_NOTICE
	}
	if report.backend == .None {
		return fmt.aprint(VOICE_PTT_NO_GLOBAL_NOTICE, typing, sep = "", allocator = allocator)
	}
	switch report.status {
	case .Unavailable:
		return fmt.aprintf(
			"%s Not in other windows: %s.%s",
			VOICE_PTT_FOCUS_NOTICE,
			hotkey.StatusReport_message(&report),
			typing,
			allocator = allocator,
		)
	case .KeyUnsupported:
		return fmt.aprint(
			VOICE_PTT_GLOBAL_UNSUPPORTED_KEY_NOTICE,
			typing,
			sep = "",
			allocator = allocator,
		)
	case .Idle, .Starting, .Active:
	}
	if report.backend != .Portal {
		globalTyping := types ? VOICE_PTT_GLOBAL_TYPING_ADDENDUM : ""
		return fmt.aprint(
			VOICE_PTT_GLOBAL_POLLING_NOTICE,
			globalTyping,
			sep = "",
			allocator = allocator,
		)
	}
	// The portal: the desktop owns the trigger, so the configured key matters only in the
	// window (and as the trigger proposed on the first bind).
	switch report.status {
	case .Starting:
		return fmt.aprintf(
			"Setting up the desktop shortcut for push-to-talk in other windows: %s.%s",
			hotkey.StatusReport_message(&report),
			typing,
			allocator = allocator,
		)
	case .Active:
		trigger := hotkey.StatusReport_trigger(&report)
		if len(trigger) == 0 {
			return fmt.aprint(
				VOICE_PTT_PORTAL_UNASSIGNED_NOTICE,
				typing,
				sep = "",
				allocator = allocator,
			)
		}
		return fmt.aprintf(
			"In other windows, push-to-talk is the desktop shortcut %s; change it in your " +
			"desktop's shortcut settings. In HayChat the key above works too.%s",
			trigger,
			typing,
			allocator = allocator,
		)
	case .Idle, .Unavailable, .KeyUnsupported:
	}
	return fmt.aprint(VOICE_PTT_PORTAL_IDLE_NOTICE, typing, sep = "", allocator = allocator)
}
VOICE_KEY_CAPTURE_TEXT :: "Press a key… (Esc cancels)"
VOICE_TEST_START_TEXT :: "Test microphone"
VOICE_TEST_STOP_TEXT :: "Stop test"

@(private = "file")
voiceDeviceOptions :: proc(
	listed: []string,
	chosen: string,
	allocator := context.temp_allocator,
) -> []VoiceDeviceOption {
	options := make([dynamic]VoiceDeviceOption, 0, len(listed) + 2, allocator)
	append(
		&options,
		VoiceDeviceOption{label = VOICE_SYSTEM_DEFAULT_LABEL, selected = len(chosen) == 0},
	)
	for name in listed {
		append(&options, VoiceDeviceOption{name = name, label = name, selected = name == chosen})
	}
	// A chosen device that is unplugged stays visible, so the user sees why the default plays.
	if len(chosen) > 0 && !voiceDeviceListed(listed, chosen) {
		append(
			&options,
			VoiceDeviceOption {
				name = chosen,
				label = fmt.aprintf("%s (not connected)", chosen, allocator = allocator),
				selected = true,
			},
		)
	}
	return options[:]
}

// "100%" for a linear gain.
voicePercentText :: proc(gain: f32, allocator := context.temp_allocator) -> string {
	return fmt.aprintf("%d%%", int(gain * 100 + 0.5), allocator = allocator)
}

buildVoiceSettingsView :: proc(
	state: ^State,
	allocator := context.temp_allocator,
) -> (
	view: VoiceSettingsView,
) {
	panel := &state.voicePanel
	view.settings = State_voiceSettings(state)
	view.inputOptions = voiceDeviceOptions(
		panel.inputDevices[:],
		view.settings.inputDevice,
		allocator,
	)
	view.outputOptions = voiceDeviceOptions(
		panel.outputDevices[:],
		view.settings.outputDevice,
		allocator,
	)
	if len(panel.audioError) > 0 {
		view.devicesNote = fmt.aprintf(
			"Audio devices cannot be listed (%s). Voice uses the system default.",
			panel.audioError,
			allocator = allocator,
		)
	}
	view.capturingKey = panel.capturingKey
	view.pttKeyLabel = panel.capturingKey ? VOICE_KEY_CAPTURE_TEXT : view.settings.pttKey
	present := state.voice.globalPushToTalk != nil
	report := state.voice.globalReport
	view.pttNotice = voicePushToTalkNotice(view.settings, report, present, allocator)
	view.pttGlobalOffered = present && report.backend != .None
	view.pttCanConfigure =
		view.settings.pttGlobal &&
		report.backend == .Portal &&
		report.status == .Active &&
		report.canConfigure
	view.thresholdText = fmt.aprintf(
		"%d dBFS",
		int(view.settings.vadThresholdDB),
		allocator = allocator,
	)
	view.inputGainText = voicePercentText(view.settings.inputGain, allocator)
	view.outputVolumeText = voicePercentText(view.settings.outputVolume, allocator)
	view.bitrateText = fmt.aprintf("%d kbit/s", view.settings.bitrate / 1000, allocator = allocator)
	echoLoaded := voiceEchoCancellationLoad()
	view.noiseAvailable, view.noiseText, view.noiseNote = voiceNoiseSuppressionView(
		view.settings.noiseSuppression,
		voiceNoiseSuppressionLoad(),
		echoLoaded,
		rnnoise.loadError(),
		allocator,
	)
	view.echoAvailable, view.echoText, view.echoNote, view.echoNotice =
		voiceEchoCancellationView(
			view.settings.echoCancellation,
			echoLoaded,
			webrtcapm.loadError(),
			allocator,
		)

	view.levelDB = VOICE_LEVEL_FLOOR_DB
	switch {
	case state.voice.engine != nil:
		view.meter = .Voice
		view.meterNote = "Your input in voice. Leave voice to test your microphone."
	case panel.testEngine != nil:
		view.meter = .Test
		view.meterNote = "Speak: you hear yourself through Opus. The line marks the threshold."
		if view.settings.mode == .PushToTalk {
			view.meterNote = "Hold the push-to-talk key and speak: you hear yourself through Opus."
		}
	case:
		view.meter = .None
		view.meterNote = "Start the microphone test to see your input level."
	}
	if engine := State_voiceMeterEngine(state); engine != nil {
		view.levelDB, view.transmitting = VoiceEngine_inputLevel(engine)
	}
	view.testRunning = panel.testEngine != nil
	view.testEnabled = state.voice.engine == nil && state.voice.status != .Joining
	view.testButtonText = view.testRunning ? VOICE_TEST_STOP_TEXT : VOICE_TEST_START_TEXT
	view.testError = panel.testError
	return
}

VOICE_NOISE_ON_TEXT :: "Noise suppression: on"
VOICE_NOISE_OFF_TEXT :: "Noise suppression: off"
VOICE_NOISE_UNAVAILABLE_TEXT :: "Noise suppression: unavailable"
VOICE_NOISE_NOTE ::
	"RNNoise removes steady background noise (fans, hum, traffic) from your microphone before " +
	"it is sent, and only speech opens voice activity. Loud typing can still get through."
// #171: with WebRTC audio processing, its suppressor (after the echo canceller) does the work.
VOICE_NOISE_WEBRTC_NOTE ::
	"WebRTC's noise suppression removes steady background noise (fans, hum, traffic) from " +
	"your microphone before it is sent, together with the echo canceller."
VOICE_NOISE_WEBRTC_VAD_NOTE :: VOICE_NOISE_WEBRTC_NOTE + " Only speech opens voice activity."
when ODIN_OS == .Windows {
	VOICE_NOISE_INSTALL_HINT :: "rnnoise.dll belongs next to haychat-client.exe."
	VOICE_ECHO_INSTALL_HINT :: "haychat-webrtc-apm.dll belongs next to haychat-client.exe."
} else {
	VOICE_NOISE_INSTALL_HINT :: "Install your distribution's rnnoise package to use it."
	VOICE_ECHO_INSTALL_HINT ::
		"Install your distribution's webrtc-audio-processing package (version 2) and keep " +
		"libhaychat-webrtc-apm.so next to haychat-client to use it."
}

VOICE_ECHO_ON_TEXT :: "Echo cancellation: on"
VOICE_ECHO_OFF_TEXT :: "Echo cancellation: off"
VOICE_ECHO_UNAVAILABLE_TEXT :: "Echo cancellation: unavailable"
VOICE_ECHO_NOTE ::
	"Removes the voices HayChat plays from your microphone, so others do not hear themselves " +
	"through your speakers. With headphones it is not needed."

// Loads RNNoise for the settings screen (process-wide and idempotent: only the first call
// touches the disk). Tests swap it to see the screen without the library.
voiceNoiseSuppressionLoad: proc() -> bool = rnnoise.load
// The same for WebRTC audio processing (#171).
voiceEchoCancellationLoad: proc() -> bool = webrtcapm.load

// The noise suppression toggle: offered when WebRTC audio processing or RNNoise loads (WebRTC
// suppresses when it loads, with RNNoise's speech probability for the gate), else a note
// with RNNoise's loadError. Strings are allocated with allocator.
voiceNoiseSuppressionView :: proc(
	enabled, rnnoiseAvailable, webrtcAvailable: bool,
	loadError: string,
	allocator := context.temp_allocator,
) -> (
	offered: bool,
	text: string,
	note: string,
) {
	if !rnnoiseAvailable && !webrtcAvailable {
		reason := len(loadError) > 0 ? loadError : "RNNoise could not be loaded"
		note = fmt.aprintf(
			"Noise suppression is unavailable: %s. %s",
			reason,
			VOICE_NOISE_INSTALL_HINT,
			allocator = allocator,
		)
		return false, VOICE_NOISE_UNAVAILABLE_TEXT, note
	}
	note = VOICE_NOISE_NOTE
	if webrtcAvailable {
		note = rnnoiseAvailable ? VOICE_NOISE_WEBRTC_VAD_NOTE : VOICE_NOISE_WEBRTC_NOTE
	}
	return true, enabled ? VOICE_NOISE_ON_TEXT : VOICE_NOISE_OFF_TEXT, note
}

// The echo cancellation toggle (#171): offered only when WebRTC audio processing loads, else a
// note with loadError. notice is the warning at the top of the section, empty while echo
// cancellation runs. Strings are allocated with allocator.
voiceEchoCancellationView :: proc(
	enabled, available: bool,
	loadError: string,
	allocator := context.temp_allocator,
) -> (
	offered: bool,
	text: string,
	note: string,
	notice: string,
) {
	if !available {
		reason := len(loadError) > 0 ? loadError : "WebRTC audio processing could not be loaded"
		note = fmt.aprintf(
			"Echo cancellation is unavailable: %s. %s",
			reason,
			VOICE_ECHO_INSTALL_HINT,
			allocator = allocator,
		)
		return false, VOICE_ECHO_UNAVAILABLE_TEXT, note, VOICE_ECHO_UNAVAILABLE_NOTICE
	}
	if !enabled {
		return true, VOICE_ECHO_OFF_TEXT, VOICE_ECHO_NOTE, VOICE_ECHO_OFF_NOTICE
	}
	return true, VOICE_ECHO_ON_TEXT, VOICE_ECHO_NOTE, ""
}

// The level meter's range in dBFS, which is also the threshold slider's range.
VOICE_METER_FLOOR_DB :: VOICE_VAD_THRESHOLD_MIN_DB
VOICE_METER_CEILING_DB :: VOICE_VAD_THRESHOLD_MAX_DB
