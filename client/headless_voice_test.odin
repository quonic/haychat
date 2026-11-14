#+feature dynamic-literals
package client

import "../common"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

@(private = "file")
testHeadlessVoiceRun :: proc(
	harness: ^HeadlessHarness,
	builder: ^strings.Builder,
	line: string,
) -> string {
	headlessHandleLine(harness, line)
	return testHeadlessTakeOutput(builder)
}

@(test)
testHeadlessVoiceCommandsParseTheirArguments :: proc(t: ^testing.T) {
	good := [?]string {
		"voice-join 1",
		"voice-leave",
		"voice-source tone:440:0.5",
		"voice-sink file:/tmp/b.f32",
		"voice-gate vad -40",
		"voice-gate open",
		"voice-mute on",
		"voice-deafen off",
		"voice-ptt down",
		"voice-stats",
		"voice-flush",
		"voice-volume 7 50",
		"voice-mute-user 7 on",
	}
	for line in good {
		_, err := headlessParseCommand(HEADLESS_COMMANDS[:], line)
		testing.expectf(t, err == .None, "expected %q to parse, got %v", line, err)
	}
	// Missing or extra words never reach a handler.
	bad := [?]string {
		"voice-join",
		"voice-join 1 2",
		"voice-leave now",
		"voice-source",
		"voice-source tone:440 file:x",
		"voice-sink",
		"voice-gate",
		"voice-gate vad -40 fast",
		"voice-mute",
		"voice-deafen on off",
		"voice-ptt",
		"voice-stats all",
		"voice-flush now",
		"voice-volume 7",
		"voice-volume 7 50 60",
		"voice-mute-user 7",
	}
	for line in bad {
		_, err := headlessParseCommand(HEADLESS_COMMANDS[:], line)
		testing.expectf(t, err == .BadArguments, "expected %q to be bad, got %v", line, err)
	}
}

@(test)
testHeadlessVoiceCommandsRejectBadValues :: proc(t: ^testing.T) {
	builder := strings.builder_make()
	harness := testHeadlessHarness(&builder, 811)
	defer testHeadlessHarnessDeinit(&harness, &builder)

	cases := [?]struct {
		line:  string,
		usage: string,
	} {
		{"voice-join 0", "voice-join ROOM_ID"},
		{"voice-join general", "voice-join ROOM_ID"},
		{"voice-source tone:abc", "voice-source tone:HZ[:AMP]|file:PATH|silence|device[:NAME]"},
		{"voice-source tone:440:2", "voice-source tone:HZ[:AMP]|file:PATH|silence|device[:NAME]"},
		{"voice-source tone:0", "voice-source tone:HZ[:AMP]|file:PATH|silence|device[:NAME]"},
		{"voice-source file:", "voice-source tone:HZ[:AMP]|file:PATH|silence|device[:NAME]"},
		{"voice-source mic", "voice-source tone:HZ[:AMP]|file:PATH|silence|device[:NAME]"},
		{"voice-sink file:", "voice-sink file:PATH|null|device[:NAME]"},
		{"voice-sink null:x", "voice-sink file:PATH|null|device[:NAME]"},
		{"voice-sink speakers", "voice-sink file:PATH|null|device[:NAME]"},
		{"voice-gate loud", "voice-gate vad [THRESHOLD_DB]|ptt|open"},
		{"voice-gate ptt -40", "voice-gate vad [THRESHOLD_DB]|ptt|open"},
		{"voice-gate vad 5", "voice-gate vad [THRESHOLD_DB]|ptt|open"},
		{"voice-gate vad quiet", "voice-gate vad [THRESHOLD_DB]|ptt|open"},
		{"voice-mute yes", "voice-mute on|off"},
		{"voice-deafen 1", "voice-deafen on|off"},
		{"voice-ptt sideways", "voice-ptt down|up"},
	}
	before := harness.state.voice.engineTemplate
	for entry in cases {
		cmd, _, _ := strings.partition(entry.line, " ")
		expected := strings.concatenate(
			{`{"ok":false,"cmd":"`, cmd, `","error":"usage: `, entry.usage, `"}`, "\n"},
			context.temp_allocator,
		)
		output := testHeadlessVoiceRun(&harness, &builder, entry.line)
		testExpectString(t, output, expected, entry.line)
	}
	after := harness.state.voice.engineTemplate
	testing.expectf(
		t,
		after.source.kind == before.source.kind && after.sink.kind == before.sink.kind,
		"expected bad values to leave the template alone, got %v",
		after,
	)

	// Not connected: the join is refused with the state's reason, and nothing is sent.
	testExpectString(
		t,
		testHeadlessVoiceRun(&harness, &builder, "voice-join 1"),
		`{"ok":false,"cmd":"voice-join","error":"` + NOT_CONNECTED_MESSAGE + `"}` + "\n",
		"the offline join",
	)
	testExpectString(
		t,
		testHeadlessVoiceRun(&harness, &builder, "voice-flush"),
		`{"ok":false,"cmd":"voice-flush","error":"voice-flush needs a file sink ` +
		`(voice-sink file:PATH)"}` + "\n",
		"a flush without a file sink",
	)
}

@(test)
testHeadlessVoiceCommandsSetTheTemplateAndControls :: proc(t: ^testing.T) {
	builder := strings.builder_make()
	harness := testHeadlessHarness(&builder, 812)
	defer testHeadlessHarnessDeinit(&harness, &builder)
	state := &harness.state

	testExpectString(
		t,
		testHeadlessVoiceRun(&harness, &builder, "voice-source tone:440:0.25"),
		`{"ok":true,"cmd":"voice-source","value":"tone:440:0.25","pendingRejoin":false}` + "\n",
		"the tone source",
	)
	source := state.voice.engineTemplate.source
	testing.expectf(
		t,
		source.kind == .Tone && source.toneHz == 440 && source.toneAmplitude == 0.25,
		"expected a 440 Hz tone at 0.25, got %v",
		source,
	)
	testExpectString(
		t,
		testHeadlessVoiceRun(&harness, &builder, "voice-sink file:/tmp/haychat-sink.f32"),
		`{"ok":true,"cmd":"voice-sink","value":"file:/tmp/haychat-sink.f32",` +
		`"pendingRejoin":false}` + "\n",
		"the file sink",
	)
	// Changing the sink must keep the source, whose strings the template owns.
	testHeadlessVoiceRun(&harness, &builder, "voice-source file:/tmp/haychat-source.f32")
	testHeadlessVoiceRun(&harness, &builder, "voice-sink null")
	template := state.voice.engineTemplate
	testing.expectf(
		t,
		template.source.kind == .File &&
		template.source.path == "/tmp/haychat-source.f32" &&
		template.sink.kind == .Null &&
		template.sink.path == "",
		"expected the file source to survive a sink change, got %v",
		template,
	)
	testHeadlessVoiceRun(&harness, &builder, "voice-sink device:Speakers")
	testing.expectf(
		t,
		state.voice.engineTemplate.sink.kind == .Device &&
		state.voice.engineTemplate.sink.deviceName == "Speakers",
		"expected the named device, got %v",
		state.voice.engineTemplate.sink,
	)

	testExpectString(
		t,
		testHeadlessVoiceRun(&harness, &builder, "voice-gate open"),
		`{"ok":true,"cmd":"voice-gate","value":"open","pendingRejoin":false}` + "\n",
		"the open gate",
	)
	testing.expect(
		t,
		state.voice.engineTemplate.gateMode == .PushToTalk && state.voice.pushToTalkHeld,
		"expected open to be push-to-talk held",
	)
	testHeadlessVoiceRun(&harness, &builder, "voice-gate vad -40")
	testing.expectf(
		t,
		state.voice.engineTemplate.gateMode == .VoiceActivity &&
		state.voice.engineTemplate.vadThresholdDB == -40 &&
		!state.voice.pushToTalkHeld,
		"expected voice activity at -40 dB with the key released, got %v held %v",
		state.voice.engineTemplate,
		state.voice.pushToTalkHeld,
	)
	testHeadlessVoiceRun(&harness, &builder, "voice-gate ptt")
	testExpectString(
		t,
		testHeadlessVoiceRun(&harness, &builder, "voice-ptt down"),
		`{"ok":true,"cmd":"voice-ptt","value":"down","pendingRejoin":false}` + "\n",
		"push-to-talk down",
	)
	testing.expect(t, state.voice.pushToTalkHeld, "expected the key held")
	testHeadlessVoiceRun(&harness, &builder, "voice-ptt up")
	testing.expect(t, !state.voice.pushToTalkHeld, "expected the key released")

	// Out of voice, mute and deafen are local choices that the next join carries.
	testExpectString(
		t,
		testHeadlessVoiceRun(&harness, &builder, "voice-mute on"),
		`{"ok":true,"cmd":"voice-mute","value":"on","pendingRejoin":false}` + "\n",
		"mute",
	)
	testHeadlessVoiceRun(&harness, &builder, "voice-deafen on")
	testing.expect(t, state.voice.muted && state.voice.deafened, "expected muted and deafened")
	testHeadlessVoiceRun(&harness, &builder, "voice-mute off")
	testing.expect(t, !state.voice.muted, "expected unmuted")

	testExpectString(
		t,
		testHeadlessVoiceRun(&harness, &builder, "voice-leave"),
		`{"ok":true,"cmd":"voice-leave","serverID":0,"roomID":0,"status":"idle"}` + "\n",
		"a leave outside voice",
	)
	output := testHeadlessVoiceRun(&harness, &builder, "voice-stats")
	testing.expectf(
		t,
		strings.has_prefix(
			output,
			`{"ok":true,"cmd":"voice-stats","status":"idle","serverID":0,"roomID":0,` +
			`"running":false,"joinedMS":0,"sent":0,"received":0,"lost":0,`,
		) &&
		strings.contains(output, `"speakers":[],"network":{"datagramsReceived":0,`) &&
		strings.contains(output, `"receiveDropped":{"Malformed":0,`),
		"unexpected stats outside voice: %s",
		output,
	)
}

@(private = "file")
testVoiceSnapshot :: proc(
	transmitting: bool,
	speakers: ..VoiceSpeakerSnapshot,
) -> VoiceEngineSnapshot {
	snapshot := VoiceEngineSnapshot {
		running      = true,
		transmitting = transmitting,
		speakerCount = len(speakers),
	}
	copy(snapshot.speakers[:], speakers)
	return snapshot
}

@(test)
testHeadlessVoiceSpeakingEdges :: proc(t: ^testing.T) {
	tracker: HeadlessVoiceTracker
	render :: proc(update: HeadlessVoiceSpeakingEdges) -> string {
		edges := update
		builder := strings.builder_make(context.temp_allocator)
		for edge in edges.edges[:edges.count] {
			line := headlessRenderVoiceSpeaking(1, 7, edge, context.temp_allocator)
			strings.write_string(&builder, line)
			strings.write_byte(&builder, '\n')
		}
		return strings.to_string(builder)
	}

	// Speaker 5 starts talking while 9 is connected but quiet; this client starts sending.
	snapshot := testVoiceSnapshot(true, {userID = 5, speaking = true}, {userID = 9})
	testExpectString(
		t,
		render(headlessVoiceSpeakingUpdate(&tracker, &snapshot, 3)),
		`{"event":"voice_speaking","serverID":1,"roomID":7,"userID":5,"speaking":true,` +
		`"self":false}` + "\n" +
		`{"event":"voice_speaking","serverID":1,"roomID":7,"userID":3,"speaking":true,` +
		`"self":true}` + "\n",
		"the first edges",
	)
	// Nothing changed: no edges, however often the harness polls.
	testExpectString(
		t,
		render(headlessVoiceSpeakingUpdate(&tracker, &snapshot, 3)),
		"",
		"a repeated snapshot",
	)
	// 5 stops and 9 starts in the same step; stops come first.
	snapshot = testVoiceSnapshot(true, {userID = 9, speaking = true}, {userID = 5})
	testExpectString(
		t,
		render(headlessVoiceSpeakingUpdate(&tracker, &snapshot, 3)),
		`{"event":"voice_speaking","serverID":1,"roomID":7,"userID":5,"speaking":false,` +
		`"self":false}` + "\n" +
		`{"event":"voice_speaking","serverID":1,"roomID":7,"userID":9,"speaking":true,` +
		`"self":false}` + "\n",
		"a hand-over",
	)
	// The engine goes away (a leave): everyone still speaking stops, this client too.
	testExpectString(
		t,
		render(headlessVoiceSpeakingUpdate(&tracker, nil, 3)),
		`{"event":"voice_speaking","serverID":1,"roomID":7,"userID":9,"speaking":false,` +
		`"self":false}` + "\n" +
		`{"event":"voice_speaking","serverID":1,"roomID":7,"userID":3,"speaking":false,` +
		`"self":true}` + "\n",
		"the engine stopping",
	)
	testing.expect(
		t,
		tracker.speakingCount == 0 && !tracker.selfSpeaking,
		"expected nobody tracked as speaking",
	)
}

@(test)
testHeadlessVoicePollReportsStatusChanges :: proc(t: ^testing.T) {
	builder := strings.builder_make()
	harness := testHeadlessHarness(&builder, 813)
	defer testHeadlessHarnessDeinit(&harness, &builder)

	headlessPollVoice(&harness)
	testExpectString(t, testHeadlessTakeOutput(&builder), "", "no change, no line")
	harness.state.voice.status = .Joining
	harness.state.voice.serverID = 813
	harness.state.voice.roomID = 4
	harness.state.voice.wantVoiceRoomID = 4
	headlessPollVoice(&harness)
	testExpectString(
		t,
		testHeadlessTakeOutput(&builder),
		`{"event":"voice_status","serverID":813,"roomID":4,"status":"joining","wantRoomID":4,` +
		`"error":""}` + "\n",
		"the joining status",
	)
	testing.expect(t, harness.pendingEvents[.VoiceStatus] == 1, "expected it counted for wait")
	headlessPollVoice(&harness)
	testExpectString(t, testHeadlessTakeOutput(&builder), "", "no repeat")
	// The status line names the reason voice ended.
	harness.state.voice.status = .Unavailable
	harness.state.voice.lastError = strings.clone("voice sink /nope: Not_Exist")
	headlessPollVoice(&harness)
	testExpectString(
		t,
		testHeadlessTakeOutput(&builder),
		`{"event":"voice_status","serverID":813,"roomID":4,"status":"unavailable",` +
		`"wantRoomID":4,"error":"voice sink /nope: Not_Exist"}` + "\n",
		"the unavailable status",
	)
	testing.expect(t, HEADLESS_EVENT_NAMES[.VoiceSpeaking] == "voice_speaking", "event name")
	kind, ok := headlessEventKindFromName("voice_status")
	testing.expect(t, ok && kind == .VoiceStatus, "expected wait to know voice_status")
}

@(private = "file")
testFileSize :: proc(path: string) -> i64 {
	info, err := os.stat(path, context.temp_allocator)
	return err == nil ? info.size : -1
}

@(test)
testHeadlessVoiceFlushWritesTheFileSinkOut :: proc(t: ^testing.T) {
	if !voiceTestOpusAvailable(t) {
		return
	}
	dir := configTestCreateTempDir("haychat_headless_flush")
	defer configTestRemovePathIfExists(dir)
	path := configTestJoinPath({dir, "sink.f32"})

	builder := strings.builder_make()
	harness := testHeadlessHarness(&builder, 814)
	defer testHeadlessHarnessDeinit(&harness, &builder)
	state := &harness.state

	// A running engine with a file sink, as a join would start one, minus the network: the
	// loopback plays its own tone back, so the file fills with sound.
	engine := VoiceEngine_create(
		{
			source = {kind = .Tone, toneHz = 440},
			sink = {kind = .File, path = path},
			gateMode = .PushToTalk,
			loopback = true,
		},
	)
	VoiceEngine_setPushToTalk(engine, true)
	started := VoiceEngine_start(engine)
	defer VoiceEngine_destroy(engine)
	testing.expectf(t, started, "expected the engine to start: %s", VoiceEngine_lastError(engine))
	if !started {
		return
	}
	state.voice.engine = engine
	state.voice.status = .Joined
	state.voice.serverID = 814
	state.voice.roomID = 1
	// State_deinit would stop it through a link the test did not make.
	defer state.voice.engine = nil

	time.sleep(300 * time.Millisecond)
	output := testHeadlessVoiceRun(&harness, &builder, "voice-flush")
	prefix := strings.concatenate(
		{`{"ok":true,"cmd":"voice-flush","path":"`, path, `","bytes":`},
		context.temp_allocator,
	)
	testing.expectf(t, strings.has_prefix(output, prefix), "unexpected flush result %s", output)
	testing.expectf(t, strings.has_suffix(output, `"running":true}` + "\n"), "running: %s", output)
	// Every frame played before the flush is in the file, whole frames only.
	played := VoiceEngine_snapshot(engine).stats.framesPlayed
	size := testFileSize(path)
	testing.expectf(
		t,
		size >= VOICE_FRAME_BYTES * 10 && size % VOICE_FRAME_BYTES == 0,
		"expected at least 10 whole frames on disk, got %d bytes",
		size,
	)
	testing.expectf(
		t,
		u64(size) <= played * VOICE_FRAME_BYTES,
		"expected no more than the %d played frames, got %d bytes",
		played,
		size,
	)
	testing.expect(t, engine.sinkFlushCompleted == engine.sinkFlushRequested, "expected served")

	// The harness reports this client's own sending and the loopback speaker.
	time.sleep(200 * time.Millisecond)
	headlessPollVoice(&harness)
	polled := testHeadlessTakeOutput(&builder)
	testing.expectf(
		t,
		strings.contains(polled, `"status":"joined"`) &&
		strings.contains(
			polled,
			`{"event":"voice_speaking","serverID":814,"roomID":1,"userID":0,"speaking":true,` +
			`"self":true}`,
		) &&
		strings.contains(
			polled,
			fmt.tprint(
				`"userID":`,
				VOICE_LOOPBACK_USER_ID,
				`,"speaking":true,"self":false}`,
				sep = "",
			),
		),
		"expected the status and both speaking edges, got %s",
		polled,
	)
	testing.expect(t, common.VOICE_SAMPLE_RATE == 48000, "the file format assumes 48 kHz")
}

// voice-stats' flat latency and loss fields: the mean playout delay, its maximum, the longest
// gap inside a spurt, and the fault hook's drops.
@(test)
testHeadlessVoiceStatsSummarisesDelayAndGaps :: proc(t: ^testing.T) {
	voice := ClientVoiceState {
		status = .Joined,
	}
	snapshot: VoiceEngineSnapshot
	snapshot.running = true
	snapshot.stats.playoutDelayFrames = 4
	snapshot.stats.playoutDelayTotalMS = 200
	snapshot.stats.playoutDelayMaxMS = 80
	snapshot.stats.faultDropped = 3
	snapshot.jitter.maxGapRun = 2
	snapshot.jitter.fec = 2
	snapshot.jitter.plc = 1
	result := headlessVoiceStatsJSON(&voice, &snapshot, {}, 1000, context.temp_allocator)
	testing.expectf(
		t,
		result.playoutDelayMS == 50 &&
		result.playoutDelayMaxMS == 80 &&
		result.maxGapRun == 2 &&
		result.injectedLoss == 3 &&
		result.lost == 3,
		"unexpected summary %v",
		result,
	)
	idle := headlessVoiceStatsJSON(&voice, nil, {}, 0, context.temp_allocator)
	testing.expect(t, idle.playoutDelayMS == 0, "expected no delay without an engine")
}

// voice-volume and voice-mute-user store a per-user setting on the selected server through the
// Server settings actions, refuse bad values, and voice-stats lists every stored setting.
@(test)
testHeadlessVoiceUserVolumeCommands :: proc(t: ^testing.T) {
	builder := strings.builder_make()
	harness := testHeadlessHarness(&builder, 813)
	defer testHeadlessHarnessDeinit(&harness, &builder)

	testExpectString(
		t,
		testHeadlessVoiceRun(&harness, &builder, "voice-volume 7 50"),
		`{"ok":true,"cmd":"voice-volume","serverID":813,"userID":7,"volumePercent":50,` +
		`"muted":false,"engineRunning":false,"engineVolumePercent":100,"engineMuted":false}` +
		"\n",
		"the volume result",
	)
	testExpectString(
		t,
		testHeadlessVoiceRun(&harness, &builder, "voice-mute-user 9 on"),
		`{"ok":true,"cmd":"voice-mute-user","serverID":813,"userID":9,"volumePercent":100,` +
		`"muted":true,"engineRunning":false,"engineVolumePercent":100,"engineMuted":false}` +
		"\n",
		"the mute result",
	)
	volume, muted := State_userVoice(&harness.state, 813, 7)
	testing.expectf(t, volume == 0.5 && !muted, "expected user 7 at 0.5, got %v", volume)
	for line in ([?]string{"voice-volume 0 50", "voice-volume 7 201", "voice-volume x 50",
		"voice-mute-user 9 maybe", "voice-mute-user 0 on"}) {
		output := testHeadlessVoiceRun(&harness, &builder, line)
		testing.expectf(
			t,
			strings.has_prefix(output, `{"ok":false,`),
			"expected %q refused, got %s",
			line,
			output,
		)
	}
	output := testHeadlessVoiceRun(&harness, &builder, "voice-stats")
	testing.expectf(
		t,
		strings.contains(
			output,
			`"userVoice":[{"userID":7,"volumePercent":50,"muted":false,"engineRunning":false,` +
			`"engineVolumePercent":100,"engineMuted":false},{"userID":9,"volumePercent":100,` +
			`"muted":true,`,
		),
		"expected the stored settings in voice-stats, got %s",
		output,
	)
	// Back to the default removes the stored entry.
	testHeadlessVoiceRun(&harness, &builder, "voice-volume 7 100")
	testHeadlessVoiceRun(&harness, &builder, "voice-mute-user 9 off")
	output = testHeadlessVoiceRun(&harness, &builder, "voice-stats")
	testing.expectf(
		t,
		strings.contains(output, `"userVoice":[]`),
		"expected no stored settings, got %s",
		output,
	)
}
