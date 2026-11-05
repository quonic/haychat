#+feature dynamic-literals
package client

import "../common"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:testing"
import "core:time"

LIVE_VOICE_SERVER_ID :: 69
LIVE_VOICE_ROOM_ID :: 1
LIVE_VOICE_TONE_HZ :: 440
LIVE_VOICE_TONE_AMPLITUDE :: 0.5
// How long A talks while B is joined. The check needs a second of tone after the first
// 200 ms, which leaves room for the jitter buffer's start-up.
LIVE_VOICE_TALK_TIME :: 2500 * time.Millisecond

// Applies every queued event on each state, the way the frame loop does.
@(private = "file")
liveVoicePump :: proc(states: ..^State) {
	for state in states {
		for State_drainNetworkEvents(state) {
		}
	}
}

// Pumps both states until done(state) holds or timeout passes.
@(private = "file")
liveVoiceWaitUntil :: proc(
	state, other: ^State,
	timeout: time.Duration,
	done: proc(state: ^State, wanted: int) -> bool,
	wanted: int,
) -> bool {
	start := time.tick_now()
	for time.tick_since(start) < timeout {
		liveVoicePump(state, other)
		if done(state, wanted) {
			return true
		}
		time.sleep(5 * time.Millisecond)
	}
	return done(state, wanted)
}

@(private = "file")
liveVoiceIsSettled :: proc(state: ^State, _: int) -> bool {
	return state.voice.status == .Joined || state.voice.status == .Unavailable ||
		state.voice.status == .Idle
}

@(private = "file")
liveVoiceRoomLacksUser :: proc(state: ^State, userID: int) -> bool {
	for participant in State_voiceRoomParticipants(
		state,
		LIVE_VOICE_SERVER_ID,
		LIVE_VOICE_ROOM_ID,
	) {
		if participant.userId == userID {
			return false
		}
	}
	return true
}

@(private = "file")
liveVoiceStats :: proc(state: ^State) -> ClientVoiceNetworkStats {
	ClientNetworkWorker_lock(state.networkWorker)
	defer ClientNetworkWorker_unlock(state.networkWorker)
	return state.serverTransports[0].voiceStats
}

@(private = "file")
liveVoiceJoin :: proc(t: ^testing.T, state, other: ^State, label: string) -> bool {
	if !State_joinVoice(state, LIVE_VOICE_SERVER_ID, LIVE_VOICE_ROOM_ID) {
		testing.expectf(t, false, "expected %s's join to go out: %q", label, state.voice.lastError)
		return false
	}
	liveVoiceWaitUntil(state, other, 5 * time.Second, liveVoiceIsSettled, 0)
	testing.expectf(
		t,
		state.voice.status == .Joined && state.voice.engine != nil,
		"expected %s to be Joined with a running engine, got %v %q",
		label,
		state.voice.status,
		state.voice.lastError,
	)
	return state.voice.status == .Joined
}

// H1–H5 end to end through the real server relay: client A speaks a 440 Hz tone (gate held
// open, null sink), client B listens (silent source, file sink). After B has heard A for a
// while, A leaves and B sees the participant update, then B's recording must pass the tone
// check from voice_analysis.odin. Gated like the other live client tests.
@(test)
testClientVoiceLiveToneReachesSecondClientThroughServer :: proc(t: ^testing.T) {
	if os.get_env("HAYCHAT_LIVE_STARTUP_AUTH", context.temp_allocator) != "1" {
		return
	}
	if !voiceTestOpusAvailable(t) {
		return
	}
	testing.set_fail_timeout(t, 90 * time.Second)

	liveServer := Server {
		id   = LIVE_VOICE_SERVER_ID,
		name = "Live Voice Server",
		host = "127.0.0.1",
		port = 12345,
	}
	configA := testConfigWithServers({liveServer})
	defer Config_deinit(&configA)
	configB := testConfigWithServers({liveServer})
	defer Config_deinit(&configB)
	delete(configA.display_name)
	configA.display_name = liveTestUniqueNickname("voice-a")
	delete(configB.display_name)
	configB.display_name = liveTestUniqueNickname("voice-b")

	tempDir, tempErr := os.temp_directory(context.temp_allocator)
	if tempErr != nil || len(tempDir) == 0 {
		tempDir = "/tmp"
	}
	sinkPath := fmt.tprintf(
		"%s/haychat-voice-live-%x.f32",
		tempDir,
		time.time_to_unix_nano(time.now()),
	)
	defer os.remove(sinkPath)

	stateA := State_initFromConfig(configA)
	defer State_deinit(&stateA)
	stateB := State_initFromConfig(configB)
	defer State_deinit(&stateB)
	State_setVoiceEngineTemplate(
		&stateA,
		{
			source = {
				kind = .Tone,
				toneHz = LIVE_VOICE_TONE_HZ,
				toneAmplitude = LIVE_VOICE_TONE_AMPLITUDE,
			},
			sink = {kind = .Null},
			gateMode = .PushToTalk,
		},
	)
	// Push-to-talk held: every frame is sent, so the tone needs no voice activity check.
	State_setVoicePushToTalk(&stateA, true)
	State_setVoiceEngineTemplate(
		&stateB,
		{source = {kind = .Silence}, sink = {kind = .File, path = sinkPath}},
	)

	if !liveTestConnect(t, &stateA, "client A") || !liveTestConnect(t, &stateB, "client B") {
		return
	}
	userA := State_selfUserID(&stateA, LIVE_VOICE_SERVER_ID)
	userB := State_selfUserID(&stateB, LIVE_VOICE_SERVER_ID)
	if !liveVoiceJoin(t, &stateA, &stateB, "client A") ||
	   !liveVoiceJoin(t, &stateB, &stateA, "client B") {
		return
	}

	// B's join reaches A as a participant update listing both.
	bothListed := liveVoiceWaitUntil(
		&stateA,
		&stateB,
		3 * time.Second,
		proc(state: ^State, userID: int) -> bool {
			return !liveVoiceRoomLacksUser(state, userID)
		},
		userB,
	)
	testing.expect(t, bothListed, "expected A to see B join the room's voice")

	talkStart := time.tick_now()
	for time.tick_since(talkStart) < LIVE_VOICE_TALK_TIME {
		liveVoicePump(&stateA, &stateB)
		time.sleep(10 * time.Millisecond)
	}
	snapshotB, _ := State_voiceEngineSnapshot(&stateB)
	statsA := liveVoiceStats(&stateA)
	statsB := liveVoiceStats(&stateB)

	State_leaveVoice(&stateA)
	sawLeave := liveVoiceWaitUntil(
		&stateB,
		&stateA,
		3 * time.Second,
		liveVoiceRoomLacksUser,
		userA,
	)
	testing.expect(t, sawLeave, "expected B's participant list to drop A after A left")
	testing.expect(
		t,
		!liveVoiceRoomLacksUser(&stateB, userB) && stateB.voice.status == .Joined,
		"expected B still listed and Joined after A left",
	)
	testing.expect(
		t,
		stateA.voice.status == .Idle && stateA.voice.engine == nil,
		"expected A Idle with its engine gone",
	)

	// About 50 frames a second each way; allow for start-up and scheduling.
	testing.expectf(
		t,
		statsA.framesSent >= 100 && statsA.sendDropped[.SendFailed] == 0,
		"expected A to send at least 100 frames, got %d sent, drops %v",
		statsA.framesSent,
		statsA.sendDropped,
	)
	testing.expectf(
		t,
		statsB.framesDelivered >= 80 &&
		statsB.receiveDropped[.BadTag] == 0 &&
		statsB.receiveDropped[.Replayed] == 0 &&
		statsB.receiveDropped[.Malformed] == 0,
		"expected B to receive at least 80 good frames, got %d delivered, drops %v",
		statsB.framesDelivered,
		statsB.receiveDropped,
	)
	testing.expectf(
		t,
		snapshotB.stats.framesDecoded >= 80,
		"expected B's engine to decode at least 80 frames, got %d",
		snapshotB.stats.framesDecoded,
	)

	// Stopping B's engine closes the file sink, so the whole recording is on disk.
	State_leaveVoice(&stateB)
	bytes, readErr := os.read_entire_file_from_path(sinkPath, context.allocator)
	defer delete(bytes)
	testing.expectf(t, readErr == nil, "expected B's recording at %s: %v", sinkPath, readErr)
	samples := mem.slice_data_cast([]f32, bytes[:len(bytes) / 4 * 4])
	first := -1
	for sample, index in samples {
		if abs(sample) > 0.05 {
			first = index
			break
		}
	}
	SKIP :: common.VOICE_SAMPLE_RATE / 5
	WINDOW :: common.VOICE_SAMPLE_RATE
	testing.expectf(
		t,
		first >= 0 && first + SKIP + WINDOW <= len(samples),
		"expected over 1.2 s of A's tone in B's recording, got %d samples, first sound at %d",
		len(samples),
		first,
	)
	if first < 0 || first + SKIP + WINDOW > len(samples) {
		return
	}
	analysis := analyzeVoiceTone(
		samples[first + SKIP:][:WINDOW],
		common.VOICE_SAMPLE_RATE,
		LIVE_VOICE_TONE_HZ,
	)
	expectedRMSDB := voiceToneRMSDB(LIVE_VOICE_TONE_AMPLITUDE)
	log.infof(
		"voice proof: A sent %d frames; B got %d datagrams, delivered %d, decoded %d " +
		"(FEC %d, PLC %d, late %d); B heard %.2f Hz at %.1f dBFS, SNR %.1f dB",
		statsA.framesSent,
		statsB.datagramsReceived,
		statsB.framesDelivered,
		snapshotB.stats.framesDecoded,
		snapshotB.jitter.fec,
		snapshotB.jitter.plc,
		snapshotB.jitter.late,
		analysis.dominantHz,
		analysis.rmsDB,
		analysis.snrDB,
	)
	testing.expectf(
		t,
		voiceTonePasses(analysis, LIVE_VOICE_TONE_HZ, expectedRMSDB),
		"expected %d Hz at %.1f dBFS RMS with SNR >= %.0f dB in B's recording, " +
		"got %.2f Hz, %.1f dBFS, SNR %.1f dB",
		LIVE_VOICE_TONE_HZ,
		expectedRMSDB,
		VOICE_TONE_MIN_SNR_DB,
		analysis.dominantHz,
		analysis.rmsDB,
		analysis.snrDB,
	)
	testing.expect(
		t,
		State_isServerConnected(&stateA, LIVE_VOICE_SERVER_ID) &&
		State_isServerConnected(&stateB, LIVE_VOICE_SERVER_ID),
		"expected both chat sessions still up after voice",
	)
}
