package client

// H6 tests: the voice view models (channel list participants, room header, voice bar,
// Settings → Voice), the settings actions (config → template → running engines), and the
// engine's gain, volume and bitrate controls. Tests that swap voiceControlSendBridge hold
// voiceControlSendBridgeTestMutex and check with testing.expect while they hold it.

import "../common"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import "hotkey"
import "opus"
import SDL "vendor:sdl3"

UI_VOICE_SELF_USER_ID :: 3

// A state signed in as user 3 on serverID with #general (1) and #voice (2), whose engines use
// silence and a null sink, so a join starts a real, quiet engine with no audio device.
@(private = "file")
testVoiceUIState :: proc(serverID: int) -> State {
	server := Server {
		id   = serverID,
		name = fmt.tprintf("Voice %d", serverID),
		host = "localhost",
		port = 1,
	}
	state := testUpdateStateForServer(server)
	testApplyConnected(&state, serverID, UI_VOICE_SELF_USER_ID)
	testApplyNamedRooms(
		&state,
		serverID,
		common.RoomSummary{id = 1, name = "general"},
		common.RoomSummary{id = 2, name = "voice"},
	)
	State_setVoiceEngineTemplate(
		&state,
		{source = {kind = .Silence}, sink = {kind = .Null}, gateMode = .VoiceActivity},
	)
	return state
}

@(private = "file")
testVoiceUIParticipant :: struct {
	userID:   int,
	muted:    bool,
	deafened: bool,
}

@(private = "file")
testVoiceUIApplyParticipants :: proc(
	state: ^State,
	serverID, roomID: int,
	recipientJoined: bool,
	participants: ..testVoiceUIParticipant,
) {
	event := ClientTransportRuntimeEvent {
		kind                 = .VoiceParticipants,
		serverID             = serverID,
		roomID               = roomID,
		voiceRecipientJoined = recipientJoined,
	}
	for participant in participants {
		append(
			&event.voiceParticipants,
			common.VoiceParticipant {
				userId = participant.userID,
				nickname = strings.clone(fmt.tprintf("user-%d", participant.userID)),
				muted = participant.muted,
				deafened = participant.deafened,
			},
		)
	}
	State_applyRuntimeEvent(state, &event)
	ClientTransportRuntimeEvent_deinit(&event)
}

@(private = "file")
testVoiceUIUseStub :: proc() {
	voiceControlTestCount = 0
	voiceControlTestReturnValue = true
	voiceControlSendBridge = voiceControlSendBridgeTestStub
}

@(private = "file")
testVoiceUIRestore :: proc() {
	voiceControlSendBridge = ClientServerTransport_sendVoiceControl
}

// ── Channel list ──────────────────────────────────────────────────

// Each room with anyone in voice gets an indicator and its participants under it, also for
// rooms this client is not in voice of. The server lists each user once (protocol 13); a
// repeated user ID, which only an older server could send, still shows once, with the first
// entry's flags and no device count.
@(test)
testVoiceSidebarListsParticipantsOncePerUser :: proc(t: ^testing.T) {
	state := testVoiceUIState(941)
	defer State_deinit(&state)
	testVoiceUIApplyParticipants(
		&state,
		941,
		2,
		false,
		{userID = 9},
		{userID = UI_VOICE_SELF_USER_ID, muted = true, deafened = true},
		{userID = 9, muted = true},
		{userID = 12, muted = true},
	)

	rows := buildSidebarRows(&state)
	channelIndex := -1
	for row, index in rows {
		if row.kind == .Channel && row.id == 2 {
			channelIndex = index
		}
		if row.kind == .Channel && row.id == 1 {
			assert(row.voiceUsers == 0, "expected no voice indicator on #general")
		}
	}
	assert(channelIndex >= 0, "expected #voice in the channel list")
	assert(
		rows[channelIndex].voiceUsers == 3,
		fmt.tprintf("expected 3 users in #voice, got %d", rows[channelIndex].voiceUsers),
	)
	assert(len(rows) > channelIndex + 3, "expected the participant rows under #voice")
	first := rows[channelIndex + 1]
	selfRow := rows[channelIndex + 2]
	third := rows[channelIndex + 3]
	assert(
		first.kind == .VoiceParticipant &&
		first.roomID == 2 &&
		first.id == 9 &&
		first.label == "user-9" &&
		!first.voice.muted &&
		!first.voice.speaking,
		fmt.tprintf("expected user 9 once, unmuted as first listed, got %v", first),
	)
	assert(
		selfRow.voice.isSelf && selfRow.voice.muted && selfRow.voice.deafened,
		fmt.tprintf("expected this user marked muted and deafened, got %v", selfRow),
	)
	assert(
		third.id == 12 && third.voice.muted && !third.voice.deafened,
		fmt.tprintf("expected user 12 muted, got %v", third),
	)
	if len(rows) > channelIndex + 4 {
		assert(
			rows[channelIndex + 4].kind != .VoiceParticipant,
			"expected exactly three participant rows",
		)
	}

	// Nobody left: the indicator and the rows go.
	testVoiceUIApplyParticipants(&state, 941, 2, false)
	for row in buildSidebarRows(&state) {
		assert(row.kind != .VoiceParticipant, "expected no participant rows after an empty list")
		assert(row.voiceUsers == 0, "expected no voice indicator after an empty list")
	}
	_ = t
}

// Speaking comes from the joined engine: its speakers by user ID, and this client's gate for
// this user. Outside the joined room nobody shows as speaking.
@(test)
testVoiceParticipantRowsShowSpeaking :: proc(t: ^testing.T) {
	participants := []common.VoiceParticipant {
		{userId = 9, nickname = "nine"},
		{userId = 3, nickname = "me"},
		{userId = 12, nickname = ""},
	}
	speech: VoiceSpeechState
	speech.snapshot.speakerCount = 2
	speech.snapshot.speakers[0] = {userID = 9, speaking = true}
	speech.snapshot.speakers[1] = {userID = 12, speaking = false}
	speech.selfTransmitting = true
	rows := voiceParticipantRows(participants, 3, &speech)
	assert(len(rows) == 3, "expected three rows")
	assert(rows[0].speaking && rows[0].label == "nine", "expected user 9 speaking")
	assert(rows[1].speaking && rows[1].isSelf, "expected this user speaking from the gate")
	assert(!rows[2].speaking && rows[2].label == "User 12", "expected user 12 quiet, labelled")

	quiet := voiceParticipantRows(participants, 3, nil)
	for row in quiet {
		assert(!row.speaking, "expected nobody speaking outside the joined room")
	}
	_ = t
}

// ── Room header ───────────────────────────────────────────────────

@(test)
testRoomHeaderOffersJoinOrLeaveVoice :: proc(t: ^testing.T) {
	state := testVoiceUIState(942)
	defer State_deinit(&state)
	assert(roomVoiceHeaderAction(&state, 942, 1) == .Join, "expected Join voice in #general")
	assert(roomVoiceHeaderAction(&state, 942, 7) == .None, "expected nothing for a non-member")
	assert(roomVoiceHeaderAction(&state, 942, 0) == .None, "expected nothing without a room")

	// The states a join passes through, set directly: this tests the view model only.
	state.voice.serverID = 942
	state.voice.roomID = 1
	state.voice.wantVoiceRoomID = 1
	statuses := [?]VoiceSessionStatus{.Joining, .Joined, .Idle}
	for status in statuses {
		state.voice.status = status
		assert(
			roomVoiceHeaderAction(&state, 942, 1) == .Leave,
			fmt.tprintf("expected Leave voice while %v", status),
		)
		assert(
			roomVoiceHeaderAction(&state, 942, 2) == .Join,
			fmt.tprintf("expected Join voice in another room while %v", status),
		)
	}
	state.voice.status = .Unavailable
	state.voice.wantVoiceRoomID = 0
	assert(roomVoiceHeaderAction(&state, 942, 1) == .Join, "expected Join to retry when off")
	state.voice = {engineTemplate = state.voice.engineTemplate}

	testApplyDisconnectedFor(&state, 942)
	assert(roomVoiceHeaderAction(&state, 942, 1) == .None, "expected nothing while disconnected")
	_ = t
}

@(private = "file")
testApplyDisconnectedFor :: proc(state: ^State, serverID: int) {
	event := ClientTransportRuntimeEvent {
		kind     = .Disconnected,
		serverID = serverID,
		message  = strings.clone("connection lost"),
	}
	State_applyRuntimeEvent(state, &event)
	ClientTransportRuntimeEvent_deinit(&event)
}

// ── Voice bar ─────────────────────────────────────────────────────

// Every state of the voice bar, driven through the real actions and events.
@(test)
testVoiceBarShowsEveryState :: proc(t: ^testing.T) {
	if !voiceTestOpusAvailable(t) {
		return
	}
	state := testVoiceUIState(943)
	defer State_deinit(&state)
	sync.mutex_lock(&voiceControlSendBridgeTestMutex)
	defer sync.mutex_unlock(&voiceControlSendBridgeTestMutex)
	testVoiceUIUseStub()
	defer testVoiceUIRestore()

	testing.expect(t, buildVoiceBarView(&state).kind == .Hidden, "expected no bar while idle")

	testing.expect(t, State_joinVoice(&state, 943, 1), "expected the join to go out")
	joining := buildVoiceBarView(&state)
	testing.expectf(
		t,
		joining.kind == .Joining &&
		joining.text == "Joining voice: #general on Voice 943…" &&
		joining.showControls &&
		!joining.showLevel,
		"expected Joining with controls, got %v",
		joining,
	)

	testVoiceUIApplyParticipants(&state, 943, 1, true, {userID = UI_VOICE_SELF_USER_ID})
	joined := buildVoiceBarView(&state)
	testing.expectf(
		t,
		joined.kind == .Joined &&
		joined.text == "Voice connected: #general on Voice 943" &&
		joined.showControls &&
		joined.showLevel &&
		!joined.muted &&
		!joined.isError,
		"expected Voice connected with controls and a meter, got %v",
		joined,
	)
	State_setVoiceMuted(&state, true)
	State_setVoiceDeafened(&state, true)
	marked := buildVoiceBarView(&state)
	testing.expect(
		t,
		marked.muted && marked.deafened && !marked.speaking,
		"expected the bar to show mute and deafen, and no speaking while muted",
	)

	testApplyDisconnectedFor(&state, 943)
	rejoining := buildVoiceBarView(&state)
	testing.expectf(
		t,
		rejoining.kind == .Rejoining &&
		rejoining.text == "Rejoining voice: #general on Voice 943…" &&
		rejoining.showControls,
		"expected Rejoining after a lost connection, got %v",
		rejoining,
	)
	// Leave cancels the re-join.
	State_leaveVoice(&state)
	testing.expect(t, buildVoiceBarView(&state).kind == .Hidden, "expected no bar after leave")

	// A refusal stays until dismissed.
	testApplyConnected(&state, 943, UI_VOICE_SELF_USER_ID)
	testing.expect(t, State_joinVoice(&state, 943, 2), "expected a second join to go out")
	reason := strings.clone("voice room is full")
	State_voiceJoinRejected(&state, 943, 2, &reason)
	delete(reason)
	notice := buildVoiceBarView(&state)
	testing.expectf(
		t,
		notice.kind == .Notice &&
		notice.text == "voice room is full" &&
		notice.isError &&
		!notice.showControls,
		"expected the refusal with only Dismiss, got %v",
		notice,
	)
	State_leaveVoice(&state)
	testing.expect(t, buildVoiceBarView(&state).kind == .Hidden, "expected Dismiss to clear it")

	// Unavailable: the engine's or libopus's error, in red.
	state.voice.status = .Unavailable
	delete(state.voice.lastError)
	state.voice.lastError = strings.clone("Voice unavailable: libopus not found")
	unavailable := buildVoiceBarView(&state)
	testing.expectf(
		t,
		unavailable.kind == .Unavailable &&
		unavailable.text == "Voice unavailable: libopus not found" &&
		unavailable.isError &&
		!unavailable.showControls,
		"expected the error with Dismiss, got %v",
		unavailable,
	)
	State_leaveVoice(&state)
	testing.expect(
		t,
		buildVoiceBarView(&state).kind == .Hidden && state.voice.status == .Idle,
		"expected Dismiss to clear Unavailable",
	)
}

// ── Settings → config → template → engines ───────────────────────

// The template every new engine starts from comes from the config keys, and a settings change
// updates the config and the template but keeps the template's source and sink kinds.
@(test)
testVoiceSettingsBuildTheEngineTemplate :: proc(t: ^testing.T) {
	config := Config {
		display_name           = "Tester",
		voice_input_device     = "USB Mic",
		voice_mode             = "push_to_talk",
		voice_vad_threshold_db = f32(-60),
		voice_input_gain       = f32(0),
		voice_output_volume    = f32(0.5),
		voice_bitrate          = 32000,
	}
	state := State_initFromConfig(config)
	defer State_deinit(&state)
	template := state.voice.engineTemplate
	assert(
		template.source.kind == .Device &&
		template.sink.kind == .Device &&
		template.source.deviceName == "USB Mic" &&
		template.sink.deviceName == "" &&
		template.gateMode == .PushToTalk &&
		template.vadThresholdDB == -60 &&
		template.inputGain == 0 &&
		template.outputVolume == 0.5 &&
		template.explicitLevels &&
		template.encoder.bitrate == 32000 &&
		template.encoder.inbandFEC &&
		template.noiseSuppression,
		fmt.tprintf("expected the GUI template from the config, got %v", template),
	)

	State_setVoiceEngineTemplate(
		&state,
		{source = {kind = .Tone, toneHz = 440}, sink = {kind = .Null}},
	)
	settings := State_voiceSettings(&state)
	settings.outputDevice = "Headset"
	settings.mode = .VoiceActivity
	settings.bitrate = 48000
	settings.noiseSuppression = false
	State_applyVoiceSettings(&state, settings)
	assert(
		state.config.voice_output_device == "Headset" &&
		state.config.voice_mode == "" &&
		state.config.voice_bitrate == 48000 &&
		state.config.voice_noise_suppression == false &&
		state.config.voice_input_device == "USB Mic",
		"expected the config to hold the new settings (voice activity stored as the default)",
	)
	template = state.voice.engineTemplate
	assert(
		template.source.kind == .Tone &&
		template.source.toneHz == 440 &&
		template.sink.kind == .Null &&
		template.sink.deviceName == "Headset" &&
		template.gateMode == .VoiceActivity &&
		template.encoder.bitrate == 48000 &&
		!template.noiseSuppression,
		fmt.tprintf("expected the settings applied with the kinds kept, got %v", template),
	)
	_ = t
}

// While joined, settings reach the running engine at once; a device change reopens it and
// the session stays joined without a word to the server.
@(test)
testVoiceSettingsReapplyToTheJoinedEngine :: proc(t: ^testing.T) {
	if !voiceTestOpusAvailable(t) {
		return
	}
	state := testVoiceUIState(944)
	defer State_deinit(&state)
	sync.mutex_lock(&voiceControlSendBridgeTestMutex)
	defer sync.mutex_unlock(&voiceControlSendBridgeTestMutex)
	testVoiceUIUseStub()
	defer testVoiceUIRestore()

	testing.expect(t, State_joinVoice(&state, 944, 1), "expected the join to go out")
	testVoiceUIApplyParticipants(&state, 944, 1, true, {userID = UI_VOICE_SELF_USER_ID})
	engine := state.voice.engine
	testing.expect(t, state.voice.status == .Joined && engine != nil, "expected Joined")
	if engine == nil {
		return
	}
	State_setVoiceMuted(&state, true)
	State_voicePushToTalkChanged(&state, true)
	sent := voiceControlTestCount

	settings := State_voiceSettings(&state)
	settings.vadThresholdDB = -30
	settings.inputGain = 2
	settings.outputVolume = 0.25
	settings.bitrate = 40000
	settings.mode = .PushToTalk
	settings.noiseSuppression = !sync.atomic_load(&engine.noiseSuppression)
	State_applyVoiceSettings(&state, settings)
	testing.expect(t, state.voice.engine == engine, "expected levels to keep the same engine")
	testing.expect(
		t,
		sync.atomic_load(&engine.noiseSuppression) == settings.noiseSuppression,
		"expected noise suppression switched on the running engine",
	)
	testing.expect(
		t,
		transmute(f32)sync.atomic_load(&engine.thresholdBits) == -30 &&
		transmute(f32)sync.atomic_load(&engine.inputGainBits) == 2 &&
		transmute(f32)sync.atomic_load(&engine.outputVolumeBits) == 0.25 &&
		sync.atomic_load(&engine.bitrateRequest) == 40000 &&
		sync.atomic_load(&engine.gateMode) == .PushToTalk,
		"expected threshold, gain, volume, bitrate and mode on the running engine",
	)

	// Back to voice activity releases a held push-to-talk key.
	settings.mode = .VoiceActivity
	State_applyVoiceSettings(&state, settings)
	testing.expect(
		t,
		!state.voice.pushToTalkHeld && !sync.atomic_load(&engine.pttHeld),
		"expected push-to-talk released when the mode leaves push-to-talk",
	)

	// Let the engine count a few frames, so the restart has a sequence to carry.
	sequenceBefore := testVoiceUIWaitForSequence(engine, 5)
	settings.inputDevice = "Other Mic"
	State_applyVoiceSettings(&state, settings)
	reopened := state.voice.engine
	testing.expect(
		t,
		state.voice.status == .Joined &&
		reopened != nil &&
		reopened != engine &&
		VoiceEngine_isRunning(reopened),
		"expected a device change to reopen the engine and stay joined",
	)
	if reopened == nil {
		return
	}
	transportIndex := State_selectedTransportIndexForServerID(state, 944)
	testing.expect(
		t,
		transportIndex >= 0 && state.serverTransports[transportIndex].voice.engine == reopened,
		"expected the new engine bound to the transport",
	)
	testing.expect(
		t,
		reopened.config.source.deviceName == "Other Mic" &&
		sync.atomic_load(&reopened.muted) &&
		transmute(f32)sync.atomic_load(&reopened.inputGainBits) == 2 &&
		sync.atomic_load(&reopened.bitrateRequest) == 40000,
		"expected the reopened engine to carry the device, the mute and the settings",
	)
	// Listeners are still in the old engine's spurt: a new engine that counted from 0 again
	// would have its frames dropped as late.
	sequenceAfter := VoiceEngine_snapshot(reopened).frameSequence
	testing.expect(
		t,
		sequenceBefore >= 5 && sequenceAfter > sequenceBefore,
		fmt.tprintf(
			"expected the restart to continue frameSequence past %d, got %d",
			sequenceBefore,
			sequenceAfter,
		),
	)
	testing.expect(
		t,
		voiceControlTestCount == sent,
		"expected no voice control message for settings changes",
	)
}

// The microphone test runs a loopback engine from the template, follows settings changes,
// reopens on a device change, and stops as soon as voice takes the microphone.
@(test)
testVoiceMicrophoneTestRunsALoopbackEngine :: proc(t: ^testing.T) {
	if !voiceTestOpusAvailable(t) {
		return
	}
	state := testVoiceUIState(945)
	defer State_deinit(&state)
	testing.expect(t, State_startVoiceTest(&state), "expected the microphone test to start")
	engine := state.voicePanel.testEngine
	testing.expect(
		t,
		engine != nil && VoiceEngine_isRunning(engine) && engine.config.loopback,
		"expected a running loopback engine",
	)
	testing.expect(t, State_voiceNeedsRedraws(&state), "expected redraws while the test runs")
	view := buildVoiceSettingsView(&state)
	testing.expect(
		t,
		view.meter == .Test && view.testRunning && view.testButtonText == VOICE_TEST_STOP_TEXT,
		"expected the meter to follow the test",
	)
	if engine == nil {
		return
	}

	settings := State_voiceSettings(&state)
	settings.inputGain = 3
	State_applyVoiceSettings(&state, settings)
	testing.expect(
		t,
		state.voicePanel.testEngine == engine &&
		transmute(f32)sync.atomic_load(&engine.inputGainBits) == 3,
		"expected the test engine to take the new gain in place",
	)
	settings.outputDevice = "Headset"
	State_applyVoiceSettings(&state, settings)
	testing.expect(
		t,
		state.voicePanel.testEngine != nil && state.voicePanel.testEngine != engine,
		"expected a device change to reopen the test engine",
	)

	// Joining voice takes the microphone: the test stops on the next frame.
	state.voice.status = .Joining
	State_voiceSettingsFrame(&state)
	testing.expect(t, state.voicePanel.testEngine == nil, "expected the test stopped by a join")
	testing.expect(t, !buildVoiceSettingsView(&state).testEnabled, "expected no test while joining")
	state.voice.status = .Idle
	testing.expect(t, !State_voiceNeedsRedraws(&state), "expected no redraws once idle")
	State_stopVoiceTest(&state)
}

// The push-to-talk key capture stores the key's name and ends the capture.
@(test)
testVoicePushToTalkKeyCaptureStoresTheKey :: proc(t: ^testing.T) {
	state := testVoiceUIState(946)
	defer State_deinit(&state)
	State_setVoiceKeyCapture(&state, true)
	assert(
		buildVoiceSettingsView(&state).pttKeyLabel == VOICE_KEY_CAPTURE_TEXT,
		"expected the capture prompt while capturing",
	)
	State_setVoicePushToTalkKey(&state, "Space")
	assert(!state.voicePanel.capturingKey, "expected the capture to end")
	assert(
		state.config.voice_ptt_key == "Space" && State_voiceSettings(&state).pttKey == "Space",
		"expected the new key in the config",
	)
	assert(buildVoiceSettingsView(&state).pttKeyLabel == "Space", "expected the key shown")
	State_setVoicePushToTalkKey(&state, "Left Ctrl")
	assert(state.config.voice_ptt_key == "", "expected the default key stored as unset")
	_ = t
}

// The device lists start with System default, mark the chosen device, and keep a chosen
// device that is unplugged visible; without an audio subsystem the section says why.
@(test)
testVoiceSettingsViewListsDevices :: proc(t: ^testing.T) {
	state := testVoiceUIState(947)
	defer State_deinit(&state)
	panel := &state.voicePanel
	append(&panel.inputDevices, strings.clone("Mic A"), strings.clone("Mic B"))
	append(&panel.outputDevices, strings.clone("Speakers"))
	settings := State_voiceSettings(&state)
	settings.inputDevice = "Mic C"
	settings.outputDevice = "Speakers"
	State_applyVoiceSettings(&state, settings)

	view := buildVoiceSettingsView(&state)
	assert(len(view.inputOptions) == 4, fmt.tprintf("expected 4 inputs, got %v", view.inputOptions))
	assert(
		view.inputOptions[0].label == VOICE_SYSTEM_DEFAULT_LABEL &&
		view.inputOptions[0].name == "" &&
		!view.inputOptions[0].selected,
		"expected System default first, not selected",
	)
	assert(
		view.inputOptions[3].label == "Mic C (not connected)" &&
		view.inputOptions[3].name == "Mic C" &&
		view.inputOptions[3].selected,
		fmt.tprintf("expected the unplugged choice kept, got %v", view.inputOptions[3]),
	)
	assert(
		len(view.outputOptions) == 2 &&
		view.outputOptions[1].selected &&
		!view.outputOptions[0].selected,
		"expected the chosen output selected",
	)
	assert(
		view.thresholdText == "-45 dBFS" &&
		view.inputGainText == "100%" &&
		view.outputVolumeText == "100%" &&
		view.bitrateText == "24 kbit/s",
		fmt.tprintf("expected the default texts, got %v", view),
	)
	assert(
		view.meter == .None && view.testEnabled && view.levelDB == VOICE_LEVEL_FLOOR_DB,
		"expected no meter until the test runs",
	)

	delete(panel.audioError)
	panel.audioError = strings.clone("no audio driver")
	noted := buildVoiceSettingsView(&state)
	assert(
		strings.contains(noted.devicesNote, "no audio driver"),
		fmt.tprintf("expected the reason in the note, got %q", noted.devicesNote),
	)
	_ = t
}

// After a hotplug event an engine reopens when a named device it uses went away, or when it
// fell back to the default and every named device is back. Default devices never reopen.
@(test)
testVoiceDevicesNeedReopenAfterHotplug :: proc(t: ^testing.T) {
	none := VoiceDeviceUse{}
	present := VoiceDeviceUse{named = true, present = true}
	missing := VoiceDeviceUse{named = true, present = false}
	assert(!voiceDevicesNeedReopen(none, none, false), "expected defaults to follow the system")
	assert(!voiceDevicesNeedReopen(present, none, false), "expected no reopen while present")
	assert(voiceDevicesNeedReopen(missing, none, false), "expected a reopen when a device goes")
	assert(voiceDevicesNeedReopen(none, missing, false), "expected the same for the output")
	assert(!voiceDevicesNeedReopen(missing, none, true), "expected no reopen while still missing")
	assert(voiceDevicesNeedReopen(present, none, true), "expected a reopen when it comes back")
	assert(
		!voiceDevicesNeedReopen(present, missing, true),
		"expected to wait until every named device is back",
	)
	_ = t
}

// ── Engine controls ───────────────────────────────────────────────

// Input gain reaches the level meter and the encoder from the next frame, a bitrate change
// reaches the running encoder, and output volume scales what a file sink writes. A config
// with explicitLevels keeps a gain of 0 instead of treating it as "unset".
@(test)
testVoiceEngineAppliesGainVolumeAndBitrate :: proc(t: ^testing.T) {
	if !voiceTestOpusAvailable(t) {
		return
	}
	tempRoot, tempErr := os.temp_directory(context.temp_allocator)
	assert(tempErr == nil, "expected a temp directory")
	sinkPath := fmt.tprintf(
		"%s/haychat_voice_volume_%d.f32",
		tempRoot,
		time.time_to_unix_nano(time.now()),
	)
	defer os.remove(sinkPath)
	config := VoiceEngineConfig {
		source = {kind = .Tone, toneHz = 440},
		sink = {kind = .File, path = sinkPath},
		gateMode = .PushToTalk,
		loopback = true,
		unpaced = true,
	}
	engine := VoiceEngine_create(config)
	defer VoiceEngine_destroy(engine)
	VoiceEngine_setPushToTalk(engine, true)
	assert(
		VoiceEngine_open(engine),
		fmt.tprintf("expected the engine to open: %s", VoiceEngine_lastError(engine)),
	)
	VoiceEngine_step(engine)
	level, _ := VoiceEngine_inputLevel(engine)
	assert(
		math.abs(level - -9.03) < 0.5,
		fmt.tprintf("expected a 0.5 sine at -9 dBFS, got %v", level),
	)

	VoiceEngine_setInputGain(engine, 2)
	VoiceEngine_setBitrate(engine, 48000)
	VoiceEngine_step(engine)
	level, _ = VoiceEngine_inputLevel(engine)
	assert(math.abs(level - -3.01) < 0.5, fmt.tprintf("expected gain 2 at -3 dBFS, got %v", level))
	bitrate, code := opus.encoderGet(engine.encoder, opus.GET_BITRATE_REQUEST)
	assert(
		code == opus.OK && bitrate == 48000 && VoiceEngine_bitrate(engine) == 48000,
		fmt.tprintf("expected the encoder at 48 kbit/s, got %d (code %d)", bitrate, code),
	)

	// Loud output first, then silence once the volume is 0.
	for _ in 0 ..< 40 {
		VoiceEngine_step(engine)
	}
	VoiceEngine_setOutputVolume(engine, 0)
	VoiceEngine_step(engine)
	for _ in 0 ..< 20 {
		VoiceEngine_step(engine)
	}
	VoiceEngine_close(engine)
	bytes, readErr := os.read_entire_file_from_path(sinkPath, context.allocator)
	defer delete(bytes)
	assert(readErr == nil, "expected the sink file to be readable")
	samples := mem.slice_data_cast([]f32, bytes[:len(bytes) / 4 * 4])
	frames := len(samples) / common.VOICE_FRAME_SAMPLES
	assert(frames >= 60, fmt.tprintf("expected at least 60 frames written, got %d", frames))
	loudPeak, quietPeak: f32
	for sample, index in samples {
		frame := index / common.VOICE_FRAME_SAMPLES
		if frame >= 20 && frame < 40 {
			loudPeak = max(loudPeak, math.abs(sample))
		} else if frame >= frames - 15 {
			quietPeak = max(quietPeak, math.abs(sample))
		}
	}
	assert(loudPeak > 0.1, fmt.tprintf("expected sound at volume 1, peak %v", loudPeak))
	assert(quietPeak == 0, fmt.tprintf("expected silence at volume 0, peak %v", quietPeak))

	silent := VoiceEngine_create(
		{
			source = {kind = .Tone, toneHz = 440},
			sink = {kind = .Null},
			gateMode = .PushToTalk,
			explicitLevels = true,
			inputGain = 0,
			vadThresholdDB = 0,
			unpaced = true,
		},
	)
	defer VoiceEngine_destroy(silent)
	assert(VoiceEngine_open(silent), "expected the silent engine to open")
	VoiceEngine_step(silent)
	silentLevel, _ := VoiceEngine_inputLevel(silent)
	assert(
		silentLevel == VOICE_LEVEL_FLOOR_DB &&
		transmute(f32)sync.atomic_load(&silent.thresholdBits) == 0,
		fmt.tprintf("expected gain 0 and threshold 0 kept as given, got %v dBFS", silentLevel),
	)
	_ = t
}

// Polls the engine's published frameSequence until it reaches atLeast (or 5 s pass) and
// returns the last value seen.
@(private = "file")
testVoiceUIWaitForSequence :: proc(engine: ^VoiceEngine, atLeast: u32) -> u32 {
	started := time.tick_now()
	for {
		sequence := VoiceEngine_snapshot(engine).frameSequence
		if sequence >= atLeast || time.tick_since(started) > 5 * time.Second {
			return sequence
		}
		time.sleep(5 * time.Millisecond)
	}
}

// A push-to-talk key that types (a letter, Space, Enter...) is left to a focused text field,
// so typing "t" in the message box never opens the microphone; keys a text field does not
// use work everywhere, and a key up always releases.
@(test)
testVoicePushToTalkIgnoresTypingKeysInTextFields :: proc(t: ^testing.T) {
	letter := voicePushToTalkKeyFromName("T")
	ctrl := voicePushToTalkKeyFromName("Left Ctrl")
	testing.expect(t, letter == SDL.K_T && ctrl == SDL.K_LCTRL, "expected SDL key names")
	testing.expect(
		t,
		voiceKeyEditsText(SDL.K_T) &&
		voiceKeyEditsText(SDL.K_SPACE) &&
		voiceKeyEditsText(SDL.K_RETURN) &&
		voiceKeyEditsText(SDL.K_BACKSPACE),
		"expected letters, Space, Enter and Backspace to edit text",
	)
	testing.expect(
		t,
		!voiceKeyEditsText(SDL.K_LCTRL) &&
		!voiceKeyEditsText(SDL.K_F13) &&
		!voiceKeyEditsText(SDL.K_RALT) &&
		!voiceKeyEditsText(SDL.K_UNKNOWN),
		"expected modifiers and function keys not to edit text",
	)
	testing.expect(
		t,
		voicePushToTalkKeyFromName("No Such Key") == ctrl,
		"expected an unknown name to fall back to the default key",
	)

	Case :: struct {
		pttKey, key:                SDL.Keycode,
		down, held, textFocused:    bool,
		wantChange, wantHeld:       bool,
		name:                       string,
	}
	cases := [?]Case {
		{letter, letter, true, false, false, true, true, "letter, no text field: press"},
		{letter, letter, true, false, true, false, false, "letter while typing: ignored"},
		{letter, letter, false, false, true, false, false, "letter up while typing: nothing"},
		{letter, letter, false, true, true, true, false, "held letter: up releases anyway"},
		{ctrl, ctrl, true, false, true, true, true, "Ctrl while typing: press"},
		{ctrl, ctrl, false, true, true, true, false, "Ctrl up while typing: release"},
		{ctrl, ctrl, true, true, false, false, true, "already held: no change"},
		{ctrl, letter, true, false, false, false, false, "another key: nothing"},
		{0, ctrl, true, false, false, false, false, "push-to-talk off: nothing"},
	}
	for c in cases {
		change, held := voicePushToTalkKeyEvent(c.pttKey, c.key, c.down, c.held, c.textFocused)
		testing.expectf(
			t,
			change == c.wantChange && held == c.wantHeld,
			"%s: expected change %v held %v, got %v %v",
			c.name,
			c.wantChange,
			c.wantHeld,
			change,
			held,
		)
	}
}

// The settings note warns when the chosen key types.
@(test)
testVoiceSettingsViewWarnsAboutATypingPushToTalkKey :: proc(t: ^testing.T) {
	state := testVoiceUIState(946)
	defer State_deinit(&state)
	settings := State_voiceSettings(&state)
	settings.mode = .PushToTalk
	State_applyVoiceSettings(&state, settings, persist = false)
	view := buildVoiceSettingsView(&state, context.temp_allocator)
	testing.expectf(t, view.pttNotice == VOICE_PTT_FOCUS_NOTICE, "Left Ctrl: %q", view.pttNotice)
	settings.pttKey = "Space"
	State_applyVoiceSettings(&state, settings, persist = false)
	view = buildVoiceSettingsView(&state, context.temp_allocator)
	testing.expectf(t, view.pttNotice == VOICE_PTT_TYPING_NOTICE, "Space: %q", view.pttNotice)
}

// The frame loop redraws for voice only when the key changes: a level that rounds to the same
// dB, or that stays below the meter's floor, is no change; speaking or transmitting is.
@(test)
testVoiceVisualKeyChangesOnlyWithWhatIsDrawn :: proc(t: ^testing.T) {
	snapshot: VoiceEngineSnapshot
	snapshot.speakerCount = 2
	snapshot.speakers[0] = {userID = 5}
	snapshot.speakers[1] = {userID = 9}
	quiet := voiceVisualKey(-42.2, false, &snapshot)
	testing.expect(
		t,
		voiceVisualKey(-41.8, false, &snapshot) == quiet,
		"expected a level within the same whole dB to be no change",
	)
	testing.expect(
		t,
		voiceVisualKey(-100, false, nil) == voiceVisualKey(-90, false, nil),
		"expected levels below the meter's floor to look the same",
	)
	testing.expect(
		t,
		voiceVisualKey(-40, false, &snapshot) != quiet,
		"expected a 2 dB move of the meter to be a change",
	)
	testing.expect(
		t,
		voiceVisualKey(-42.2, true, &snapshot) != quiet,
		"expected transmitting to be a change",
	)
	snapshot.speakers[1].speaking = true
	speaking := voiceVisualKey(-42.2, false, &snapshot)
	testing.expect(t, speaking != quiet, "expected a speaker starting to speak to be a change")
	testing.expect(
		t,
		speaking.speakingUsers[1] == 9 && speaking.speakingUsers[0] == 0,
		"expected only the speaking user in the key",
	)

	// A state with no engine has a constant key, so an idle window never redraws for voice.
	state := testVoiceUIState(947)
	defer State_deinit(&state)
	testing.expect(
		t,
		State_voiceVisualKey(&state) == voiceVisualKey(VOICE_LEVEL_FLOOR_DB, false, nil),
		"expected the resting key without an engine",
	)
}

// The frame loop's voice redraw decision against a running engine: nothing to check while no
// meter is on screen, one redraw when the microphone test's level first moves, none while it
// stays put, and checks no more often than VOICE_REDRAW_INTERVAL_MS.
@(test)
testVoiceRedrawDueFollowsTheEngine :: proc(t: ^testing.T) {
	if !voiceTestOpusAvailable(t) {
		return
	}
	state := testVoiceUIState(948)
	defer State_deinit(&state)
	pollAt: u64
	testing.expect(
		t,
		!State_voiceRedrawDue(&state, 1000, &pollAt) && pollAt == 0,
		"expected no voice checks without an engine",
	)
	template := state.voice.engineTemplate
	template.source = {kind = .Tone, toneHz = 440}
	template.gateMode = .VoiceActivity
	State_setVoiceEngineTemplate(&state, template)
	state.voice.drawnVisual = State_voiceVisualKey(&state)
	testing.expect(t, State_startVoiceTest(&state), "expected the microphone test to start")

	// Wait for the tone's level to reach the meter, as the loop would.
	now := u64(1000)
	changed := false
	started := time.tick_now()
	for !changed && time.tick_since(started) < 5 * time.Second {
		changed = State_voiceRedrawDue(&state, now, &pollAt)
		testing.expect(t, pollAt == now + VOICE_REDRAW_INTERVAL_MS, "expected the next check")
		testing.expect(
			t,
			!State_voiceRedrawDue(&state, now + 1, &pollAt),
			"expected no second check inside the interval",
		)
		now += VOICE_REDRAW_INTERVAL_MS
		time.sleep(10 * time.Millisecond)
	}
	testing.expect(t, changed, "expected the tone's level to ask for a redraw")
	// The gate opens a frame or two after the level rises, which is a change of its own. Once
	// the frame has drawn the settled state, a steady tone looks the same on every check.
	time.sleep(200 * time.Millisecond)
	state.voice.drawnVisual = State_voiceVisualKey(&state)
	testing.expect(t, state.voice.drawnVisual.transmitting, "expected the tone to open the gate")
	for _ in 0 ..< 5 {
		time.sleep(20 * time.Millisecond)
		testing.expect(
			t,
			!State_voiceRedrawDue(&state, now, &pollAt),
			"expected no redraw while the meter stays put",
		)
		now += VOICE_REDRAW_INTERVAL_MS
	}
	State_stopVoiceTest(&state)
	testing.expect(
		t,
		!State_voiceRedrawDue(&state, now, &pollAt),
		"expected no checks once the test stopped",
	)
}

// ── Global push-to-talk (issue 45) ────────────────────────────────

// The window's key and the global monitor combine, and a global key that types is ignored
// only while HayChat has focus with a text field focused.
@(test)
testVoicePushToTalkCombinesTheWindowAndTheGlobalKey :: proc(t: ^testing.T) {
	letter := voicePushToTalkKeyFromName("V")
	ctrl := voicePushToTalkKeyFromName("Left Ctrl")
	cases := []struct {
		window, global, focused, textFocused: bool,
		key:                                  SDL.Keycode,
		want:                                 bool,
		name:                                 string,
	} {
		{false, false, true, false, ctrl, false, "nothing held"},
		{true, false, true, false, ctrl, true, "the window's key"},
		{false, true, false, false, ctrl, true, "the global key in another window"},
		{false, true, true, true, ctrl, true, "Ctrl in a focused text field still talks"},
		{false, true, true, true, letter, false, "a letter typed in HayChat's text field"},
		{false, true, false, true, letter, true, "a letter in another window talks"},
		{false, true, true, false, letter, true, "a letter in HayChat outside a text field"},
		{true, true, true, true, letter, true, "the window's own state wins"},
	}
	for c in cases {
		got := voicePushToTalkCombined(c.window, c.global, c.focused, c.textFocused, c.key)
		testing.expectf(t, got == c.want, "%s: want %v, got %v", c.name, c.want, got)
	}
}

// The monitor follows the configured key and is armed only while push-to-talk is in use and
// allowed in other windows; the window's key reaches the engine through the sync.
@(test)
testVoiceSyncPushToTalkArmsTheMonitorOnlyWhileInUse :: proc(t: ^testing.T) {
	state := testVoiceUIState(947)
	defer State_deinit(&state)
	monitor := hotkey.create(.None, nil, nil)
	state.voice.globalPushToTalk = monitor
	armed :: proc(monitor: ^hotkey.Monitor) -> bool {
		return sync.atomic_load(&monitor.armed)
	}

	_ = State_voiceSyncPushToTalk(&state, false)
	testing.expect(t, !armed(monitor), "voice activity mode: the monitor is not armed")
	settings := State_voiceSettings(&state)
	settings.mode = .PushToTalk
	State_applyVoiceSettings(&state, settings, persist = false)
	_ = State_voiceSyncPushToTalk(&state, false)
	testing.expect(t, !armed(monitor), "push-to-talk out of voice: not armed")
	testing.expectf(
		t,
		sync.atomic_load(&monitor.key) == voicePushToTalkKeyFromName("Left Ctrl"),
		"the monitor follows the configured key, got %v",
		sync.atomic_load(&monitor.key),
	)

	state.voice.status = .Joining
	_ = State_voiceSyncPushToTalk(&state, false)
	testing.expect(t, armed(monitor), "push-to-talk while joining voice: armed")
	settings.pttGlobal = false
	State_applyVoiceSettings(&state, settings, persist = false)
	_ = State_voiceSyncPushToTalk(&state, false)
	testing.expect(t, !armed(monitor), "global push-to-talk off: not armed")

	state.voice.pushToTalkWindowHeld = true
	_ = State_voiceSyncPushToTalk(&state, false)
	testing.expect(t, state.voice.pushToTalkHeld, "the window's key holds push-to-talk")
	state.voice.pushToTalkWindowHeld = false
	_ = State_voiceSyncPushToTalk(&state, false)
	testing.expect(t, !state.voice.pushToTalkHeld, "and releases it")

	state.voice.pushToTalkWindowHeld = true
	settings.mode = .VoiceActivity
	State_applyVoiceSettings(&state, settings, persist = false)
	_ = State_voiceSyncPushToTalk(&state, false)
	testing.expect(
		t,
		!state.voice.pushToTalkHeld && !state.voice.pushToTalkWindowHeld,
		"leaving push-to-talk mode releases the key",
	)
	state.voice.status = .Idle
}

@(private = "file")
testHotkeyReport :: proc(
	backend: hotkey.Backend,
	status: hotkey.Status,
	message := "",
	trigger := "",
	canConfigure := false,
) -> (
	report: hotkey.StatusReport,
) {
	report.backend = backend
	report.status = status
	report.messageLength = copy(report.messageBuffer[:], message)
	report.triggerLength = copy(report.triggerBuffer[:], trigger)
	report.canConfigure = canConfigure
	return
}

// The settings note says where push-to-talk works for each backend and status.
@(test)
testVoicePushToTalkNoticeFollowsTheMonitor :: proc(t: ^testing.T) {
	settings := VOICE_DEFAULT_SETTINGS
	settings.mode = .PushToTalk
	notice := voicePushToTalkNotice(settings, {}, false)
	testing.expectf(t, notice == VOICE_PTT_FOCUS_NOTICE, "no monitor: %q", notice)

	notice = voicePushToTalkNotice(settings, testHotkeyReport(.None, .Idle), true)
	testing.expectf(t, notice == VOICE_PTT_NO_GLOBAL_NOTICE, "no backend: %q", notice)

	notice = voicePushToTalkNotice(settings, testHotkeyReport(.X11, .Active), true)
	testing.expectf(t, notice == VOICE_PTT_GLOBAL_POLLING_NOTICE, "X11 active: %q", notice)

	off := settings
	off.pttGlobal = false
	notice = voicePushToTalkNotice(off, testHotkeyReport(.Windows, .Active), true)
	testing.expectf(t, notice == VOICE_PTT_FOCUS_NOTICE, "turned off: %q", notice)

	notice = voicePushToTalkNotice(
		settings,
		testHotkeyReport(.X11, .Unavailable, "cannot open the X display"),
		true,
	)
	testing.expectf(
		t,
		strings.has_prefix(notice, VOICE_PTT_FOCUS_NOTICE) &&
		strings.contains(notice, "cannot open the X display"),
		"unavailable: %q",
		notice,
	)

	notice = voicePushToTalkNotice(settings, testHotkeyReport(.X11, .KeyUnsupported), true)
	testing.expectf(t, notice == VOICE_PTT_GLOBAL_UNSUPPORTED_KEY_NOTICE, "unsupported: %q", notice)

	notice = voicePushToTalkNotice(settings, testHotkeyReport(.Portal, .Idle), true)
	testing.expectf(t, notice == VOICE_PTT_PORTAL_IDLE_NOTICE, "portal idle: %q", notice)
	notice = voicePushToTalkNotice(
		settings,
		testHotkeyReport(.Portal, .Active, trigger = "Ctrl+Space"),
		true,
	)
	testing.expectf(t, strings.contains(notice, "Ctrl+Space"), "portal active: %q", notice)
	notice = voicePushToTalkNotice(settings, testHotkeyReport(.Portal, .Active), true)
	testing.expectf(t, notice == VOICE_PTT_PORTAL_UNASSIGNED_NOTICE, "unassigned: %q", notice)

	// A key that types warns about other windows only where it is read there.
	typing := settings
	typing.pttKey = "V"
	notice = voicePushToTalkNotice(typing, testHotkeyReport(.Windows, .Active), true)
	testing.expectf(
		t,
		notice == VOICE_PTT_GLOBAL_POLLING_NOTICE + VOICE_PTT_GLOBAL_TYPING_ADDENDUM,
		"typing key on Windows: %q",
		notice,
	)
	notice = voicePushToTalkNotice(typing, {}, false)
	testing.expectf(t, notice == VOICE_PTT_TYPING_NOTICE, "typing key, no monitor: %q", notice)
}

// The toggle is offered only with a global backend, and Change shortcut only for an active
// portal session that supports it.
@(test)
testVoiceSettingsViewOffersTheGlobalToggle :: proc(t: ^testing.T) {
	state := testVoiceUIState(948)
	defer State_deinit(&state)
	settings := State_voiceSettings(&state)
	settings.mode = .PushToTalk
	State_applyVoiceSettings(&state, settings, persist = false)
	view := buildVoiceSettingsView(&state, context.temp_allocator)
	testing.expect(t, !view.pttGlobalOffered, "no monitor: no toggle")

	state.voice.globalPushToTalk = hotkey.create(.None, nil, nil)
	state.voice.globalReport = testHotkeyReport(.None, .Idle)
	view = buildVoiceSettingsView(&state, context.temp_allocator)
	testing.expect(t, !view.pttGlobalOffered, "no backend: no toggle")

	state.voice.globalReport = testHotkeyReport(.Portal, .Active, "", "Ctrl+Space", true)
	view = buildVoiceSettingsView(&state, context.temp_allocator)
	testing.expect(t, view.pttGlobalOffered && view.pttCanConfigure, "portal v2: toggle + dialog")
	state.voice.globalReport = testHotkeyReport(.Portal, .Active, "", "Ctrl+Space", false)
	view = buildVoiceSettingsView(&state, context.temp_allocator)
	testing.expect(t, view.pttGlobalOffered && !view.pttCanConfigure, "portal v1: no dialog")
	state.voice.globalReport = testHotkeyReport(.X11, .Active)
	view = buildVoiceSettingsView(&state, context.temp_allocator)
	testing.expect(t, view.pttGlobalOffered && !view.pttCanConfigure, "X11: toggle only")
}

// #170: the noise suppression toggle is offered only when RNNoise loads; without it the note
// says why and how to get it.
@(test)
testVoiceSettingsViewOffersNoiseSuppressionOnlyWithRNNoise :: proc(t: ^testing.T) {
	offered, text, note := voiceNoiseSuppressionView(true, true, false, false, "")
	assert(
		offered && text == VOICE_NOISE_ON_TEXT && note == VOICE_NOISE_NOTE,
		fmt.tprintf("expected the toggle on, got %v %q %q", offered, text, note),
	)
	offered, text, _ = voiceNoiseSuppressionView(false, true, false, false, "")
	assert(offered && text == VOICE_NOISE_OFF_TEXT, fmt.tprintf("expected off, got %q", text))
	reason := "RNNoise not found (librnnoise.so.0: cannot open shared object file)"
	offered, text, note = voiceNoiseSuppressionView(true, false, false, false, reason)
	assert(
		!offered &&
		text == VOICE_NOISE_UNAVAILABLE_TEXT &&
		strings.contains(note, reason) &&
		strings.contains(note, VOICE_NOISE_INSTALL_HINT),
		fmt.tprintf("expected the reason and the hint, got %v %q %q", offered, text, note),
	)
	// #171: WebRTC audio processing alone offers it too, and the note names its suppressor.
	offered, text, note = voiceNoiseSuppressionView(true, false, true, false, reason)
	assert(
		offered && text == VOICE_NOISE_ON_TEXT && note == VOICE_NOISE_WEBRTC_ONLY_NOTE,
		fmt.tprintf("expected WebRTC's suppressor, got %v %q %q", offered, text, note),
	)
	// With both, RNNoise suppresses while echo cancellation is off, WebRTC while it is on.
	offered, _, note = voiceNoiseSuppressionView(true, true, true, false, "")
	assert(
		offered && note == VOICE_NOISE_NOTE,
		fmt.tprintf("expected RNNoise with echo cancellation off, got %q", note),
	)
	offered, _, note = voiceNoiseSuppressionView(true, true, true, true, "")
	assert(
		offered && note == VOICE_NOISE_WEBRTC_VAD_NOTE,
		fmt.tprintf("expected WebRTC's suppressor with RNNoise's VAD, got %q", note),
	)
	free_all(context.temp_allocator)
	_ = t
}

// #171: the echo cancellation toggle is offered only when WebRTC audio processing loads; the
// notice at the top of the section warns while it does not run.
@(test)
testVoiceSettingsViewOffersEchoCancellationOnlyWithWebRTC :: proc(t: ^testing.T) {
	offered, text, note, notice := voiceEchoCancellationView(true, true, "")
	assert(
		offered && text == VOICE_ECHO_ON_TEXT && note == VOICE_ECHO_NOTE && notice == "",
		fmt.tprintf("expected the toggle on and no notice, got %v %q %q", offered, text, notice),
	)
	offered, text, _, notice = voiceEchoCancellationView(false, true, "")
	assert(
		offered && text == VOICE_ECHO_OFF_TEXT && notice == VOICE_ECHO_OFF_NOTICE,
		fmt.tprintf("expected off with its notice, got %q %q", text, notice),
	)
	reason := "WebRTC audio processing not found (libhaychat-webrtc-apm.so: cannot open)"
	offered, text, note, notice = voiceEchoCancellationView(true, false, reason)
	assert(
		!offered &&
		text == VOICE_ECHO_UNAVAILABLE_TEXT &&
		strings.contains(note, reason) &&
		strings.contains(note, VOICE_ECHO_INSTALL_HINT) &&
		notice == VOICE_ECHO_UNAVAILABLE_NOTICE,
		fmt.tprintf("expected the reason, the hint and the notice, got %q %q", note, notice),
	)
	free_all(context.temp_allocator)
	_ = t
}

// #171: a device change reopens the engine everywhere; a processing change only on Windows,
// where SDL reads the raw stream hint when it opens a device.
@(test)
testVoiceSettingsReopenForTheWindowsRawStream :: proc(t: ^testing.T) {
	base := VOICE_DEFAULT_SETTINGS
	device := base
	device.inputDevice = "USB microphone"
	assert(voiceSettingsNeedReopen(base, device, .Linux), "expected a device change to reopen")
	echoOff := base
	echoOff.echoCancellation = false
	assert(!voiceSettingsNeedReopen(base, echoOff, .Linux), "expected Linux to apply in place")
	assert(
		!voiceSettingsNeedReopen(base, echoOff, .Windows),
		"expected no reopen while noise suppression still asks for raw mode",
	)
	bothOff := echoOff
	bothOff.noiseSuppression = false
	assert(voiceSettingsNeedReopen(echoOff, bothOff, .Windows), "expected raw mode to end")
	assert(voiceSettingsNeedReopen(bothOff, base, .Windows), "expected raw mode to start")
	assert(
		voiceSDLRawStream(.Windows, true, false) == "1" &&
		voiceSDLRawStream(.Windows, false, false) == "0" &&
		voiceSDLRawStream(.Linux, true, true) == "0",
		"expected raw mode only on Windows while HayChat processes the microphone",
	)
	_ = t
}
