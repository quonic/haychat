package client

// Voice view models (voice-rooms-design.md 5.3): the participants under each room in the
// channel list, the room header's join or leave button, the voice bar at the bottom of the
// sidebar, and the Settings → Voice section. Pure snapshots of State, plus the engines'
// lock-free level and their published snapshot, so tests check them without a window.

import "../common"
import "core:fmt"

// One user in a room's voice. The server lists each session (device) separately (Q2); the
// list shows the user once, with how many devices they joined from.
VoiceParticipantRow :: struct {
	userID:      int,
	label:       string, // Borrowed from State, or allocated with the view allocator
	deviceCount: int,
	isSelf:      bool,
	// Only known for the room this client is joined to, from the engine's speakers (and the
	// gate for this user).
	speaking:    bool,
	// Every device of the user is muted or deafened.
	muted:       bool,
	deafened:    bool,
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
	return voiceParticipantRows(
		participants,
		State_selfUserID(state, serverID),
		&speech,
		allocator,
	)
}

// Who is speaking in the joined room: the engine's speakers, and this client's own gate.
VoiceSpeechState :: struct {
	snapshot:         VoiceEngineSnapshot,
	selfTransmitting: bool,
}

// Groups the server's per-session list by user (Q2). A user is muted or deafened only when
// every device is; they speak when any device does. speech is nil outside the joined room.
voiceParticipantRows :: proc(
	participants: []common.VoiceParticipant,
	selfUserID: int,
	speech: ^VoiceSpeechState,
	allocator := context.temp_allocator,
) -> []VoiceParticipantRow {
	rows := make([dynamic]VoiceParticipantRow, 0, len(participants), allocator)
	for participant in participants {
		found := -1
		for row, index in rows {
			if row.userID == participant.userId {
				found = index
				break
			}
		}
		if found >= 0 {
			row := &rows[found]
			row.deviceCount += 1
			row.muted &&= participant.muted
			row.deafened &&= participant.deafened
			continue
		}
		append(
			&rows,
			VoiceParticipantRow {
				userID = participant.userId,
				label = userLabel(participant.nickname, participant.userId, allocator),
				deviceCount = 1,
				isSelf = selfUserID != 0 && participant.userId == selfUserID,
				muted = participant.muted,
				deafened = participant.deafened,
			},
		)
	}
	if speech != nil {
		for &row in rows {
			// Another device of this user may be speaking too; the server relays it here.
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
	None, // not connected, or not a member of the room
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
			view.speaking &&= !voice.muted
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
	// VOICE_PTT_FOCUS_NOTICE, plus why a key that types is ignored in text fields.
	pttNotice:         string,
	capturingKey:      bool,
	thresholdText:     string,
	inputGainText:     string,
	outputVolumeText:  string,
	bitrateText:       string,
	meter:             VoiceMeterSource,
	levelDB:           f32,
	transmitting:      bool,
	meterNote:         string,
	testRunning:       bool,
	testEnabled:       bool,
	testButtonText:    string,
	testError:         string,
}

VOICE_ECHO_NOTICE ::
	"HayChat has no echo cancellation: use headphones, or others hear themselves through " +
	"your microphone."
VOICE_PTT_FOCUS_NOTICE :: "Push-to-talk works only while the HayChat window has focus."
VOICE_PTT_TYPING_NOTICE ::
	VOICE_PTT_FOCUS_NOTICE +
	" This key types, so it does nothing while you are typing in a text field; a key such as " +
	"Ctrl or an F-key works everywhere."
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
	view.pttNotice = VOICE_PTT_FOCUS_NOTICE
	if voiceKeyEditsText(voicePushToTalkKeyFromName(view.settings.pttKey)) {
		view.pttNotice = VOICE_PTT_TYPING_NOTICE
	}
	view.thresholdText = fmt.aprintf(
		"%d dBFS",
		int(view.settings.vadThresholdDB),
		allocator = allocator,
	)
	view.inputGainText = voicePercentText(view.settings.inputGain, allocator)
	view.outputVolumeText = voicePercentText(view.settings.outputVolume, allocator)
	view.bitrateText = fmt.aprintf("%d kbit/s", view.settings.bitrate / 1000, allocator = allocator)

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

// The level meter's range in dBFS, which is also the threshold slider's range.
VOICE_METER_FLOOR_DB :: VOICE_VAD_THRESHOLD_MIN_DB
VOICE_METER_CEILING_DB :: VOICE_VAD_THRESHOLD_MAX_DB
