package client

import "base:runtime"
import "../common"
import "core:fmt"
import "core:log"
import "core:math"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import "opus"
import SDL "vendor:sdl3"

// CI sets this (check.sh does) so that a missing libopus fails the suite instead of skipping
// the codec and engine tests.
VOICE_TEST_REQUIRE_OPUS_ENV :: "HAYCHAT_REQUIRE_OPUS"

// voiceTestOpusAvailable loads libopus for a test. Without it the test is skipped with a
// warning, unless HAYCHAT_REQUIRE_OPUS=1 makes that a failure.
voiceTestOpusAvailable :: proc(t: ^testing.T, loc := #caller_location) -> bool {
	if opus.load() {
		return true
	}
	required := os.get_env(VOICE_TEST_REQUIRE_OPUS_ENV, context.temp_allocator) == "1"
	if required {
		testing.fail_now(
			t,
			fmt.tprintf(
				"libopus is required (%s=1) but %s",
				VOICE_TEST_REQUIRE_OPUS_ENV,
				opus.loadError(),
			),
			loc,
		)
	}
	log.warnf(
		"skipping: %s. Install the opus runtime package, or set %s=1 to make this fail.",
		opus.loadError(),
		VOICE_TEST_REQUIRE_OPUS_ENV,
	)
	return false
}

@(private = "file")
voiceTestTone :: proc(samples: []f32, hz: f64, amplitude: f32) {
	for &sample, index in samples {
		sample = amplitude * f32(math.sin(2 * math.PI * hz * f64(index) / common.VOICE_SAMPLE_RATE))
	}
}

@(private = "file")
voiceTestExpectTone :: proc(
	samples: []f32,
	hz: f64,
	amplitude: f64,
	what: string,
	loc := #caller_location,
) {
	analysis := analyzeVoiceTone(samples, common.VOICE_SAMPLE_RATE, hz)
	assert(
		voiceTonePasses(analysis, hz, voiceToneRMSDB(amplitude)),
		fmt.tprintf(
			"%s: expected %.0f Hz at %.1f dBFS RMS with SNR >= %.0f dB, " +
			"got %.2f Hz, %.1f dBFS, SNR %.1f dB",
			what,
			hz,
			voiceToneRMSDB(amplitude),
			VOICE_TONE_MIN_SNR_DB,
			analysis.dominantHz,
			analysis.rmsDB,
			analysis.snrDB,
		),
		loc,
	)
}

// ── Gate ──────────────────────────────────────────────────────────

@(private = "file")
gateFeed :: proc(
	gate: ^VoiceGate,
	levelDB: f32,
	mode := VoiceGateMode.VoiceActivity,
	ptt := false,
) -> VoiceGateResult {
	return VoiceGate_update(
		gate,
		{mode = mode, levelDB = levelDB, thresholdDB = -45, pttHeld = ptt},
	)
}

@(test)
testVoiceGateOpensAfterAttack :: proc(t: ^testing.T) {
	gate: VoiceGate
	assert(!gateFeed(&gate, -80).transmit, "expected silence to stay gated")
	assert(!gateFeed(&gate, -20).transmit, "expected one loud frame not to open the gate")
	assert(!gateFeed(&gate, -80).transmit, "expected a dip to restart the attack")
	assert(!gateFeed(&gate, -20).transmit, "expected the first loud frame of the attack to wait")
	result := gateFeed(&gate, -20)
	assert(result.transmit && !result.endOfSpurt, "expected the second loud frame to open")
	assert(gate.open, "expected the gate to be open")
}

@(test)
testVoiceGateHangoverEndsTheSpurt :: proc(t: ^testing.T) {
	gate: VoiceGate
	_ = gateFeed(&gate, -20)
	_ = gateFeed(&gate, -20)
	for index in 1 ..< VOICE_VAD_HANGOVER_FRAMES {
		result := gateFeed(&gate, -80)
		assert(
			result.transmit && !result.endOfSpurt,
			fmt.tprintf("expected hangover frame %d to be sent", index),
		)
	}
	// Speech inside the hangover restarts it.
	assert(gateFeed(&gate, -20).transmit, "expected speech during the hangover to be sent")
	for index in 1 ..< VOICE_VAD_HANGOVER_FRAMES {
		assert(gateFeed(&gate, -80).transmit, fmt.tprintf("expected hangover frame %d", index))
	}
	last := gateFeed(&gate, -80)
	assert(last.transmit && last.endOfSpurt, "expected the last hangover frame to end the spurt")
	assert(!gateFeed(&gate, -80).transmit, "expected the gate to be closed after the hangover")
}

@(test)
testVoiceGatePushToTalkHasATail :: proc(t: ^testing.T) {
	gate: VoiceGate
	assert(!gateFeed(&gate, -20, .PushToTalk).transmit, "expected PTT to ignore voice activity")
	assert(gateFeed(&gate, -80, .PushToTalk, true).transmit, "expected PTT to send while held")
	assert(gateFeed(&gate, -80, .PushToTalk, true).transmit, "expected PTT to keep sending")
	for index in 1 ..< VOICE_PTT_TAIL_FRAMES {
		result := gateFeed(&gate, -80, .PushToTalk)
		assert(
			result.transmit && !result.endOfSpurt,
			fmt.tprintf("expected tail frame %d after release", index),
		)
	}
	last := gateFeed(&gate, -80, .PushToTalk)
	assert(last.transmit && last.endOfSpurt, "expected the last tail frame to end the spurt")
	assert(
		!gateFeed(&gate, -80, .PushToTalk).transmit,
		"expected the gate to close after the tail",
	)
}

@(test)
testVoiceGateMuteClosesAtOnce :: proc(t: ^testing.T) {
	gate: VoiceGate
	_ = gateFeed(&gate, -20)
	_ = gateFeed(&gate, -20)
	muted := VoiceGate_update(&gate, {levelDB = -20, thresholdDB = -45, muted = true})
	assert(!muted.transmit && !muted.endOfSpurt, "expected mute to send nothing at all")
	ptt := VoiceGate_update(&gate, {mode = .PushToTalk, pttHeld = true, muted = true})
	assert(!ptt.transmit, "expected mute to win over push-to-talk")
	assert(!gateFeed(&gate, -20).transmit, "expected unmuting to need a new attack")
}

@(test)
testVoiceFrameLevel :: proc(t: ^testing.T) {
	frame: [common.VOICE_FRAME_SAMPLES]f32
	assert(voiceFrameLevelDB(frame[:]) == VOICE_LEVEL_FLOOR_DB, "expected silence at the floor")
	voiceTestTone(frame[:], 1000, 0.5)
	level := voiceFrameLevelDB(frame[:])
	assert(
		abs(level - (-9.03)) < 0.1,
		fmt.tprintf("expected a 0.5 sine at -9.03 dBFS, got %f", level),
	)
}

// ── Analysis ──────────────────────────────────────────────────────

@(test)
testVoiceToneAnalysisFindsTheTone :: proc(t: ^testing.T) {
	samples := make([]f32, common.VOICE_SAMPLE_RATE)
	defer delete(samples)
	voiceTestTone(samples, 440, 0.5)
	voiceTestExpectTone(samples, 440, 0.5, "pure tone")

	analysis := analyzeVoiceTone(samples, common.VOICE_SAMPLE_RATE, 460)
	assert(
		!voiceTonePasses(analysis, 460, voiceToneRMSDB(0.5)),
		"expected a 440 Hz tone not to pass as 460 Hz",
	)
	assert(
		!voiceTonePasses(
			analyzeVoiceTone(samples, common.VOICE_SAMPLE_RATE, 440),
			440,
			voiceToneRMSDB(0.05),
		),
		"expected a tone 20 dB too loud to fail the level check",
	)

	// White noise has no dominant bin.
	state := u64(42)
	for &sample in samples {
		state = state * 6364136223846793005 + 1442695040888963407
		sample = f32(i32(state >> 33) % 20000) / 40000
	}
	noise := analyzeVoiceTone(samples, common.VOICE_SAMPLE_RATE, 440)
	assert(
		noise.snrDB < VOICE_TONE_MIN_SNR_DB,
		fmt.tprintf("expected noise to fail, SNR %f", noise.snrDB),
	)
}

// ── Opus binding ──────────────────────────────────────────────────

@(test)
testOpusReportsAMissingLibrary :: proc(t: ^testing.T) {
	lib: opus.Library
	assert(
		!opus.Library_loadPath(&lib, "libhaychat-no-such-opus.so.0"),
		"expected the load to fail",
	)
	message := opus.Library_error(&lib)
	assert(
		strings.contains(message, "libopus not found"),
		fmt.tprintf("expected a clear error, got %q", message),
	)
	assert(!lib.loaded && lib.encoder_create == nil, "expected no symbols after a failed load")
	opus.Library_unload(&lib)
}

@(test)
testOpusEncoderUsesVoiceSettings :: proc(t: ^testing.T) {
	if !voiceTestOpusAvailable(t) {
		return
	}
	encoder, code := opus.createVoiceEncoder(common.VOICE_SAMPLE_RATE, opus.VOICE_ENCODER_SETTINGS)
	assert(encoder != nil, fmt.tprintf("expected an encoder, got %s", opus.errorString(code)))
	defer opus.destroyEncoder(encoder)
	expected := [][2]i32 {
		{opus.GET_BITRATE_REQUEST, 24000},
		{opus.GET_VBR_REQUEST, 1},
		{opus.GET_VBR_CONSTRAINT_REQUEST, 1},
		{opus.GET_COMPLEXITY_REQUEST, 8},
		{opus.GET_INBAND_FEC_REQUEST, 1},
		{opus.GET_PACKET_LOSS_PERC_REQUEST, 10},
		{opus.GET_DTX_REQUEST, 0},
		{opus.GET_SIGNAL_REQUEST, opus.SIGNAL_VOICE},
	}
	for entry in expected {
		value, getCode := opus.encoderGet(encoder, entry[0])
		assert(
			getCode == opus.OK && value == entry[1],
			fmt.tprintf(
				"expected request %d to read %d, got %d (code %d)",
				entry[0],
				entry[1],
				value,
				getCode,
			),
		)
	}
	log.infof("libopus version: %s", opus.versionString())
}

@(test)
testOpusRoundTripsATone :: proc(t: ^testing.T) {
	if !voiceTestOpusAvailable(t) {
		return
	}
	encoder, _ := opus.createVoiceEncoder(common.VOICE_SAMPLE_RATE, opus.VOICE_ENCODER_SETTINGS)
	decoder, _ := opus.createDecoder(common.VOICE_SAMPLE_RATE)
	assert(encoder != nil && decoder != nil, "expected an encoder and a decoder")
	defer opus.destroyEncoder(encoder)
	defer opus.destroyDecoder(decoder)

	FRAMES :: 75 // 1.5 s
	source := make([]f32, FRAMES * common.VOICE_FRAME_SAMPLES)
	defer delete(source)
	decoded := make([]f32, FRAMES * common.VOICE_FRAME_SAMPLES)
	defer delete(decoded)
	voiceTestTone(source, 440, 0.5)

	packet: [opus.MAX_PACKET_BYTES]u8
	totalBytes := 0
	for frame in 0 ..< FRAMES {
		pcm := source[frame * common.VOICE_FRAME_SAMPLES:][:common.VOICE_FRAME_SAMPLES]
		length := opus.encodeFloat(encoder, pcm, packet[:])
		assert(
			length > 0 && int(length) <= common.VOICE_OPUS_MAX_BYTES,
			fmt.tprintf("expected a packet within the relay's cap, got %d", length),
		)
		totalBytes += int(length)
		samples := opus.packetSampleCount(packet[:length], common.VOICE_SAMPLE_RATE)
		assert(
			samples == common.VOICE_FRAME_SAMPLES,
			fmt.tprintf("expected 960 samples, got %d", samples),
		)
		out := decoded[frame * common.VOICE_FRAME_SAMPLES:][:common.VOICE_FRAME_SAMPLES]
		got := opus.decodeFloat(decoder, packet[:length], out)
		assert(
			got == common.VOICE_FRAME_SAMPLES,
			fmt.tprintf("expected 960 decoded samples, got %d", got),
		)
	}
	// 24 kbit/s is 60 bytes per 20 ms frame; constrained VBR stays close.
	average := totalBytes / FRAMES
	assert(
		average > 30 && average < 120,
		fmt.tprintf("expected about 60 bytes per frame, got %d", average),
	)
	// Skip the codec's start-up (lookahead and the first frames).
	voiceTestExpectTone(decoded[common.VOICE_SAMPLE_RATE / 5:], 440, 0.5, "Opus round trip")

	// Concealment and FEC both yield one full frame.
	pcm: [common.VOICE_FRAME_SAMPLES]f32
	plc := opus.decodeFloat(decoder, nil, pcm[:])
	assert(
		plc == common.VOICE_FRAME_SAMPLES,
		fmt.tprintf("expected 960 concealed samples, got %d", plc),
	)
	length := opus.encodeFloat(encoder, source[:common.VOICE_FRAME_SAMPLES], packet[:])
	fec := opus.decodeFloat(decoder, packet[:length], pcm[:], fec = true)
	assert(fec == common.VOICE_FRAME_SAMPLES, fmt.tprintf("expected 960 FEC samples, got %d", fec))
}

// ── Engine ────────────────────────────────────────────────────────

@(private = "file")
VoiceTestOutbound :: struct {
	count:        int,
	lastSequence: u32,
	inOrder:      bool,
	allFEC:       bool,
}

@(private = "file")
voiceTestOnOutbound :: proc(userdata: rawptr, frame: VoiceOutboundFrame) {
	record := (^VoiceTestOutbound)(userdata)
	if record.count > 0 && frame.frameSequence != record.lastSequence + 1 {
		record.inOrder = false
	}
	if frame.flags & common.VOICE_FRAME_FLAG_FEC_PRESENT == 0 {
		record.allFEC = false
	}
	record.lastSequence = frame.frameSequence
	record.count += 1
}

@(private = "file")
voiceTestReadSamples :: proc(path: string) -> []f32 {
	bytes, err := os.read_entire_file_from_path(path, context.allocator)
	assert(err == nil, fmt.tprintf("expected to read %s, got %v", path, err))
	return mem.slice_data_cast([]f32, bytes[:len(bytes) / 4 * 4])
}

@(private = "file")
voiceTestFreeSamples :: proc(samples: []f32) {
	delete(mem.slice_to_bytes(samples))
}

// The size of the file at path in bytes, or 0 while it does not exist yet.
@(private = "file")
voiceTestFileBytes :: proc(path: string) -> i64 {
	info, err := os.stat(path, context.allocator)
	if err != nil {
		return 0
	}
	defer os.file_info_delete(info, context.allocator)
	return info.size
}

@(private = "file")
voiceTestLoopbackToFile :: proc(
	faults: VoiceLoopbackFaults,
	frames: int,
	outbound: ^VoiceTestOutbound = nil,
) -> (
	snapshot: VoiceEngineSnapshot,
	samples: []f32,
) {
	dir := configTestCreateTempDir("haychat_voice_loopback")
	defer configTestRemovePathIfExists(dir)
	path := configTestJoinPath({dir, "out.f32"})
	engine := VoiceEngine_create(
		{
			source = {kind = .Tone, toneHz = 440, toneAmplitude = 0.5},
			sink = {kind = .File, path = path},
			loopback = true,
			loopbackFaults = faults,
			unpaced = true,
			onOutbound = outbound != nil ? voiceTestOnOutbound : nil,
			outboundUserdata = outbound,
		},
	)
	defer VoiceEngine_destroy(engine)
	assert(
		VoiceEngine_open(engine),
		fmt.tprintf("expected to open: %s", VoiceEngine_lastError(engine)),
	)
	for _ in 0 ..< frames {
		VoiceEngine_step(engine)
	}
	snapshot = VoiceEngine_snapshot(engine)
	VoiceEngine_close(engine)
	samples = voiceTestReadSamples(path)
	return
}

@(test)
testVoiceEngineLoopbackPlaysTheTone :: proc(t: ^testing.T) {
	if !voiceTestOpusAvailable(t) {
		return
	}
	FRAMES :: 100
	outbound := VoiceTestOutbound {
		inOrder = true,
		allFEC  = true,
	}
	snapshot, samples := voiceTestLoopbackToFile({}, FRAMES, &outbound)
	defer voiceTestFreeSamples(samples)

	assert(
		len(samples) == FRAMES * common.VOICE_FRAME_SAMPLES,
		fmt.tprintf("expected one mixed frame per step, got %d samples", len(samples)),
	)
	stats := snapshot.stats
	// The VAD attack holds back the first frame; every later frame is sent.
	assert(
		stats.framesSent == FRAMES - VOICE_VAD_ATTACK_FRAMES + 1,
		fmt.tprintf(
			"expected %d frames sent, got %v",
			FRAMES - VOICE_VAD_ATTACK_FRAMES + 1,
			stats,
		),
	)
	assert(snapshot.frameSequence == FRAMES, "expected the media clock to count every frame")
	assert(
		outbound.count == int(stats.framesSent) && outbound.inOrder && outbound.allFEC,
		fmt.tprintf("expected the outbound seam to see every frame in order, got %v", outbound),
	)
	assert(snapshot.speakerCount == 1, "expected the loopback speaker")
	assert(snapshot.speakers[0].userID == VOICE_LOOPBACK_USER_ID, "expected the loopback user ID")
	assert(snapshot.speakers[0].speaking, "expected the loopback speaker to be speaking")
	assert(
		snapshot.jitter.plc == 0 && snapshot.jitter.fec == 0 && snapshot.jitter.late == 0,
		fmt.tprintf("expected a clean loopback, got %v", snapshot.jitter),
	)
	assert(stats.decodeErrors == 0, "expected no decode errors")
	// Skip the attack, the jitter pre-roll and the codec's start-up.
	voiceTestExpectTone(samples[common.VOICE_SAMPLE_RATE / 4:], 440, 0.5, "loopback")
}

@(test)
testVoiceEngineLoopbackSurvivesLossAndReordering :: proc(t: ^testing.T) {
	if !voiceTestOpusAvailable(t) {
		return
	}
	FRAMES :: 150
	snapshot, samples := voiceTestLoopbackToFile(
		{lossPercent = 10, seed = 7, reorderEvery = 9},
		FRAMES,
	)
	defer voiceTestFreeSamples(samples)
	stats := snapshot.stats
	jitter := snapshot.jitter
	log.infof(
		"lossy loopback: dropped %d, fec %d, plc %d, silent %d, late %d",
		stats.loopbackDropped,
		jitter.fec,
		jitter.plc,
		jitter.silent,
		jitter.late,
	)
	assert(stats.loopbackDropped > 5, fmt.tprintf("expected simulated loss, got %v", stats))
	// Every dropped frame inside the spurt is rebuilt or concealed; the last few may not have
	// been played yet when the run stopped.
	repaired := jitter.fec + jitter.plc + jitter.silent
	assert(
		repaired + 4 >= stats.loopbackDropped && repaired <= stats.loopbackDropped,
		fmt.tprintf(
			"expected repairs to match the loss, dropped %d, got %v",
			stats.loopbackDropped,
			jitter,
		),
	)
	assert(jitter.fec > 0, fmt.tprintf("expected some frames rebuilt from FEC, got %v", jitter))
	assert(
		jitter.late == 0,
		fmt.tprintf("expected reordered frames to arrive in time, got %v", jitter),
	)
	voiceTestExpectTone(samples[common.VOICE_SAMPLE_RATE / 4:], 440, 0.5, "lossy loopback")
}

@(test)
testVoiceEngineCountsFramesWhileGated :: proc(t: ^testing.T) {
	if !voiceTestOpusAvailable(t) {
		return
	}
	outbound := VoiceTestOutbound{}
	engine := VoiceEngine_create(
		{
			source = {kind = .Tone, toneHz = 440},
			sink = {kind = .Null},
			unpaced = true,
			onOutbound = voiceTestOnOutbound,
			outboundUserdata = &outbound,
		},
	)
	defer VoiceEngine_destroy(engine)
	VoiceEngine_setMuted(engine, true)
	assert(VoiceEngine_open(engine), VoiceEngine_lastError(engine))
	for _ in 0 ..< 20 {
		VoiceEngine_step(engine)
	}
	snapshot := VoiceEngine_snapshot(engine)
	assert(
		outbound.count == 0 && snapshot.stats.framesSent == 0,
		"expected nothing sent while muted",
	)
	assert(snapshot.stats.framesGated == 20, "expected every muted frame to be gated")
	level, transmitting := VoiceEngine_inputLevel(engine)
	assert(
		abs(level - (-9.03)) < 0.1,
		fmt.tprintf("expected the meter to work while muted, got %f", level),
	)
	assert(!transmitting, "expected not to be transmitting while muted")

	VoiceEngine_setMuted(engine, false)
	VoiceEngine_setGateMode(engine, .PushToTalk)
	for _ in 0 ..< 5 {
		VoiceEngine_step(engine)
	}
	assert(outbound.count == 0, "expected push-to-talk to send nothing while the key is up")
	VoiceEngine_setPushToTalk(engine, true)
	for _ in 0 ..< 5 {
		VoiceEngine_step(engine)
	}
	assert(
		outbound.count == 5,
		fmt.tprintf("expected 5 frames while held, got %d", outbound.count),
	)
	// The sequence counted the 25 gated frames too.
	assert(
		outbound.lastSequence == 29,
		fmt.tprintf("expected sequence 29, got %d", outbound.lastSequence),
	)
}

@(test)
testVoiceEngineInboundQueueIsBoundedAndValidated :: proc(t: ^testing.T) {
	if !voiceTestOpusAvailable(t) {
		return
	}
	engine := VoiceEngine_create({sink = {kind = .Null}, unpaced = true})
	defer VoiceEngine_destroy(engine)
	payload := []u8{1, 2, 3}
	assert(!VoiceEngine_pushInbound(engine, 5, 1, 0, payload), "expected no frames before open")
	assert(VoiceEngine_open(engine), VoiceEngine_lastError(engine))
	oversize: [common.VOICE_OPUS_MAX_BYTES + 1]u8
	assert(!VoiceEngine_pushInbound(engine, 0, 1, 0, payload), "expected sender 0 to be rejected")
	assert(
		!VoiceEngine_pushInbound(engine, 5, 1, 0, nil),
		"expected an empty frame to be rejected",
	)
	assert(!VoiceEngine_pushInbound(engine, 5, 1, 0, oversize[:]), "expected an oversize frame")
	for sequence in 0 ..< u32(VOICE_INBOUND_CAPACITY + 44) {
		assert(VoiceEngine_pushInbound(engine, 5, sequence, 0, payload), "expected a valid frame")
	}
	VoiceEngine_step(engine)
	stats := VoiceEngine_snapshot(engine).stats
	assert(
		stats.inboundDropped == 44 && stats.inboundInvalid == 3,
		fmt.tprintf("expected 44 dropped and 3 invalid, got %v", stats),
	)
	assert(
		stats.inboundAccepted == VOICE_INBOUND_CAPACITY,
		fmt.tprintf("expected a full queue to be drained, got %d", stats.inboundAccepted),
	)
}

@(test)
testVoiceEngineDropsIdleSpeakers :: proc(t: ^testing.T) {
	if !voiceTestOpusAvailable(t) {
		return
	}
	engine := VoiceEngine_create({sink = {kind = .Null}, unpaced = true})
	defer VoiceEngine_destroy(engine)
	assert(VoiceEngine_open(engine), VoiceEngine_lastError(engine))

	encoder, _ := opus.createVoiceEncoder(common.VOICE_SAMPLE_RATE, opus.VOICE_ENCODER_SETTINGS)
	defer opus.destroyEncoder(encoder)
	pcm: [common.VOICE_FRAME_SAMPLES]f32
	voiceTestTone(pcm[:], 300, 0.3)
	packet: [opus.MAX_PACKET_BYTES]u8
	length := opus.encodeFloat(encoder, pcm[:], packet[:])
	for user in u32(1) ..= 3 {
		assert(
			VoiceEngine_pushInbound(
				engine,
				user,
				10,
				common.VOICE_FRAME_FLAG_END_OF_SPURT,
				packet[:length],
			),
			"expected the frame to be queued",
		)
	}
	VoiceEngine_step(engine)
	snapshot := VoiceEngine_snapshot(engine)
	assert(
		snapshot.speakerCount == 3,
		fmt.tprintf("expected 3 speakers, got %d", snapshot.speakerCount),
	)
	// Ten seconds of media clock without frames.
	for _ in 0 ..< int(VOICE_SPEAKER_IDLE_MS / VOICE_FRAME_MS) + 2 {
		VoiceEngine_step(engine)
	}
	snapshot = VoiceEngine_snapshot(engine)
	assert(
		snapshot.speakerCount == 0,
		fmt.tprintf("expected idle speakers to go, got %d", snapshot.speakerCount),
	)
	assert(snapshot.stats.speakersExpired == 3, "expected three expired speakers")
	assert(
		snapshot.jitter.played == 3,
		fmt.tprintf("expected each frame played, got %v", snapshot.jitter),
	)
}

@(test)
testVoiceEngineReportsOpenErrors :: proc(t: ^testing.T) {
	if !voiceTestOpusAvailable(t) {
		return
	}
	engine := VoiceEngine_create(
		{source = {kind = .File, path = "/nonexistent/haychat-voice.f32"}, unpaced = true},
	)
	defer VoiceEngine_destroy(engine)
	assert(!VoiceEngine_open(engine), "expected a missing source file to fail")
	assert(
		strings.contains(VoiceEngine_lastError(engine), "haychat-voice.f32"),
		fmt.tprintf("expected the path in the error, got %q", VoiceEngine_lastError(engine)),
	)
	assert(!VoiceEngine_start(engine), "expected start to fail the same way")

	unpacedDevice := VoiceEngine_create({source = {kind = .Device}, unpaced = true})
	defer VoiceEngine_destroy(unpacedDevice)
	assert(!VoiceEngine_open(unpacedDevice), "expected an unpaced device engine to be refused")
}

@(test)
testVoiceEngineFileSourceFeedsTheEncoder :: proc(t: ^testing.T) {
	if !voiceTestOpusAvailable(t) {
		return
	}
	dir := configTestCreateTempDir("haychat_voice_file")
	defer configTestRemovePathIfExists(dir)
	inputPath := configTestJoinPath({dir, "in.f32"})
	outputPath := configTestJoinPath({dir, "out.f32"})
	input := make([]f32, common.VOICE_SAMPLE_RATE)
	defer delete(input)
	voiceTestTone(input, 600, 0.4)
	assert(
		os.write_entire_file(inputPath, mem.slice_to_bytes(input)) == nil,
		"expected to write input",
	)

	engine := VoiceEngine_create(
		{
			source = {kind = .File, path = inputPath},
			sink = {kind = .File, path = outputPath},
			loopback = true,
			unpaced = true,
		},
	)
	defer VoiceEngine_destroy(engine)
	assert(VoiceEngine_open(engine), VoiceEngine_lastError(engine))
	// One second of file, then silence: the gate closes after its hangover.
	for _ in 0 ..< 80 {
		VoiceEngine_step(engine)
	}
	snapshot := VoiceEngine_snapshot(engine)
	VoiceEngine_close(engine)
	assert(
		snapshot.stats.framesSent == 50 - VOICE_VAD_ATTACK_FRAMES + 1 + VOICE_VAD_HANGOVER_FRAMES,
		fmt.tprintf("expected the file plus the hangover to be sent, got %v", snapshot.stats),
	)
	assert(
		snapshot.jitter.spurts == 1 && !snapshot.speakers[0].speaking,
		"expected the spurt to end",
	)
	output := voiceTestReadSamples(outputPath)
	defer voiceTestFreeSamples(output)
	voiceTestExpectTone(
		output[common.VOICE_SAMPLE_RATE / 4:][:common.VOICE_SAMPLE_RATE / 2],
		600,
		0.4,
		"file source",
	)
}

@(test)
testVoiceEngineStartsAndStops :: proc(t: ^testing.T) {
	if !voiceTestOpusAvailable(t) {
		return
	}
	engine := VoiceEngine_create(
		{source = {kind = .Tone, toneHz = 440}, sink = {kind = .Null}, loopback = true},
	)
	defer VoiceEngine_destroy(engine)
	VoiceEngine_stop(engine) // stopping an engine that never ran is a no-op
	for round in 0 ..< 2 {
		assert(VoiceEngine_start(engine), VoiceEngine_lastError(engine))
		assert(VoiceEngine_isRunning(engine), "expected the voice thread to run")
		deadline := time.tick_now()
		for VoiceEngine_snapshot(engine).stats.framesPlayed < 10 &&
		    time.tick_since(deadline) < 3 * time.Second {
			time.sleep(10 * time.Millisecond)
		}
		snapshot := VoiceEngine_snapshot(engine)
		assert(
			snapshot.running && snapshot.stats.framesSent > 0 && snapshot.stats.framesDecoded > 0,
			fmt.tprintf(
				"round %d: expected the paced engine to send and play, got %v",
				round,
				snapshot.stats,
			),
		)
		VoiceEngine_stop(engine)
		assert(!VoiceEngine_isRunning(engine), "expected the voice thread to be joined")
		assert(!VoiceEngine_snapshot(engine).running, "expected the snapshot to show it stopped")
		assert(
			!VoiceEngine_pushInbound(engine, 5, 1, 0, []u8{1}),
			"expected inbound frames to be refused once stopped",
		)
	}
}

@(private = "file")
VoiceTestPusher :: struct {
	engine: ^VoiceEngine,
	stop:   bool, // atomic
}

// Pushes junk frames from a second sender as fast as it can; the engine must survive both
// the contention and payloads that are not valid Opus.
@(private = "file")
voiceTestPush :: proc(data: rawptr) {
	pusher := (^VoiceTestPusher)(data)
	payload := []u8{0x48, 0x01, 0x02, 0x03}
	sequence: u32
	for !sync.atomic_load(&pusher.stop) {
		_ = VoiceEngine_pushInbound(pusher.engine, 42, sequence, 0, payload)
		sequence += 1
		thread.yield()
	}
}

@(test)
testVoiceEngineStopsWhileRunningFlatOut :: proc(t: ^testing.T) {
	if !voiceTestOpusAvailable(t) {
		return
	}
	dir := configTestCreateTempDir("haychat_voice_stop")
	defer configTestRemovePathIfExists(dir)
	engine := VoiceEngine_create(
		{
			source = {kind = .Tone, toneHz = 440},
			sink = {kind = .File, path = configTestJoinPath({dir, "out.f32"})},
			loopback = true,
			loopbackFaults = {lossPercent = 20, seed = 3},
			unpaced = true,
		},
	)
	assert(VoiceEngine_start(engine), VoiceEngine_lastError(engine))
	// Another thread pushes inbound frames the whole time, like the network worker would.
	pusher := VoiceTestPusher {
		engine = engine,
	}
	pusherThread := thread.create_and_start_with_data(&pusher, voiceTestPush, context)
	time.sleep(50 * time.Millisecond)
	VoiceEngine_stop(engine)
	sync.atomic_store(&pusher.stop, true)
	thread.join(pusherThread)
	thread.destroy(pusherThread)
	snapshot := VoiceEngine_snapshot(engine)
	assert(snapshot.stats.framesPlayed > 0, "expected the unpaced engine to have run")
	VoiceEngine_destroy(engine)
}

// ── SDL device path (disk driver) ─────────────────────────────────

// SDL's backends spell the voice role differently (voiceSDLStreamRole): PipeWire takes
// "Communication" as media.role, and WASAPI matches "Communications" case-insensitively.
@(test)
testVoiceSDLStreamRolePerPlatform :: proc(t: ^testing.T) {
	windowsRole := voiceSDLStreamRole(.Windows)
	linuxRole := voiceSDLStreamRole(.Linux)
	assert(
		windowsRole == "Communications",
		fmt.tprintf("expected \"Communications\" on Windows, got %q", windowsRole),
	)
	assert(
		linuxRole == "Communication",
		fmt.tprintf("expected \"Communication\" on Linux, got %q", linuxRole),
	)
	assert(
		voiceSDLStreamRole(.Darwin) == linuxRole,
		"expected other platforms to keep the PipeWire spelling",
	)
}

// Only this test initialises SDL audio, and it resets every hint it sets, so SDL is never
// left initialised or configured for other tests.
@(private = "file")
voiceDeviceTestMutex: sync.Mutex

@(test)
testVoiceEngineDevicePathWithTheDiskDriver :: proc(t: ^testing.T) {
	if !voiceTestOpusAvailable(t) {
		return
	}
	sync.mutex_lock(&voiceDeviceTestMutex)
	defer sync.mutex_unlock(&voiceDeviceTestMutex)
	if SDL.WasInit({.AUDIO}) != {} {
		log.warn("skipping: SDL audio is already initialised in this process")
		return
	}
	dir := configTestCreateTempDir("haychat_voice_disk")
	defer configTestRemovePathIfExists(dir)
	inputPath := configTestJoinPath({dir, "mic.f32"})
	outputPath := configTestJoinPath({dir, "speaker.f32"})
	input := make([]f32, 3 * common.VOICE_SAMPLE_RATE)
	defer delete(input)
	voiceTestTone(input, 440, 0.5)
	assert(
		os.write_entire_file(inputPath, mem.slice_to_bytes(input)) == nil,
		"expected to write input",
	)

	hints := [?]cstring {
		SDL.HINT_AUDIO_DRIVER,
		SDL.HINT_AUDIO_DISK_INPUT_FILE,
		SDL.HINT_AUDIO_DISK_OUTPUT_FILE,
		SDL.HINT_AUDIO_DEVICE_STREAM_ROLE,
		SDL.HINT_AUDIO_DEVICE_STREAM_NAME,
	}
	defer for hint in hints {
		_ = SDL.ResetHint(hint)
	}
	_ = SDL.SetHint(SDL.HINT_AUDIO_DRIVER, "disk")
	_ = SDL.SetHint(
		SDL.HINT_AUDIO_DISK_INPUT_FILE,
		strings.clone_to_cstring(inputPath, context.temp_allocator),
	)
	_ = SDL.SetHint(
		SDL.HINT_AUDIO_DISK_OUTPUT_FILE,
		strings.clone_to_cstring(outputPath, context.temp_allocator),
	)

	engine := VoiceEngine_create(
		{source = {kind = .Device}, sink = {kind = .Device}, loopback = true},
	)
	started := VoiceEngine_start(engine)
	role := SDL.GetHint(SDL.HINT_AUDIO_DEVICE_STREAM_ROLE)
	assert(
		role == voiceSDLStreamRole(ODIN_OS),
		fmt.tprintf("expected the stream role %q, got %q", voiceSDLStreamRole(ODIN_OS), role),
	)
	// Wait until audio has really flowed through both devices instead of sleeping a fixed
	// time, so a loaded CI runner gets as long as it needs, up to the deadline. The checks
	// below need over 1 s of stereo F32 from the disk driver with a steady tone in its last
	// 0.5 s, so wait for 1.25 s to leave room for the device and jitter pre-roll.
	minOutputBytes := i64(common.VOICE_SAMPLE_RATE) * 5 / 4 * 2 * size_of(f32)
	if started {
		waitStart := time.tick_now()
		for time.tick_since(waitStart) < 15 * time.Second {
			progress := VoiceEngine_snapshot(engine)
			if progress.stats.framesCaptured >= 40 &&
			   progress.stats.framesDecoded >= 30 &&
			   voiceTestFileBytes(outputPath) > minOutputBytes {
				break
			}
			time.sleep(50 * time.Millisecond)
		}
	}
	snapshot := VoiceEngine_snapshot(engine)
	errorText := strings.clone(VoiceEngine_lastError(engine), context.temp_allocator)
	VoiceEngine_destroy(engine)
	assert(SDL.WasInit({.AUDIO}) == {}, "expected the engine to shut SDL audio down")
	assert(started, fmt.tprintf("expected the disk driver to open: %s", errorText))
	assert(
		snapshot.stats.framesCaptured >= 40 && snapshot.stats.framesDecoded >= 30,
		fmt.tprintf("expected about 1.5 s through the devices, got %v", snapshot.stats),
	)

	// The disk driver writes the playback device's format: F32 stereo at 48 kHz.
	output := voiceTestReadSamples(outputPath)
	defer voiceTestFreeSamples(output)
	left := make([]f32, len(output) / 2)
	defer delete(left)
	for &sample, index in left {
		sample = output[index * 2]
	}
	assert(
		len(left) > common.VOICE_SAMPLE_RATE,
		fmt.tprintf("expected over 1 s of output, got %d samples", len(left)),
	)
	log.infof(
		"disk driver: captured %d, sent %d, decoded %d, output %d samples",
		snapshot.stats.framesCaptured,
		snapshot.stats.framesSent,
		snapshot.stats.framesDecoded,
		len(left),
	)
	// The tail holds the steady tone; the start is device and jitter pre-roll.
	voiceTestExpectTone(left[len(left) - common.VOICE_SAMPLE_RATE / 2:], 440, 0.5, "disk driver")
}

// #171: a device sink's echo reference. A far-end tone pushed in as a remote speaker plays
// through SDL's disk driver, and with echo cancellation on, what SDL plays also reaches AEC3:
// two 10 ms render frames per 20 ms, most of them carrying the tone. The microphone is a
// generated silence, so the reference is the only thing that is not silent.
@(test)
testVoiceEngineDeviceSinkFeedsTheEchoReference :: proc(t: ^testing.T) {
	if !voiceTestOpusAvailable(t) || !voiceTestWebRTCAPMAvailable(t) {
		return
	}
	sync.mutex_lock(&voiceDeviceTestMutex)
	defer sync.mutex_unlock(&voiceDeviceTestMutex)
	if SDL.WasInit({.AUDIO}) != {} {
		log.warn("skipping: SDL audio is already initialised in this process")
		return
	}
	dir := configTestCreateTempDir("haychat_voice_disk_echo")
	defer configTestRemovePathIfExists(dir)
	outputPath := configTestJoinPath({dir, "speaker.f32"})
	hints := [?]cstring {
		SDL.HINT_AUDIO_DRIVER,
		SDL.HINT_AUDIO_DISK_OUTPUT_FILE,
		SDL.HINT_AUDIO_DEVICE_STREAM_ROLE,
		SDL.HINT_AUDIO_DEVICE_STREAM_NAME,
		SDL.HINT_AUDIO_DEVICE_RAW_STREAM,
	}
	defer for hint in hints {
		_ = SDL.ResetHint(hint)
	}
	_ = SDL.SetHint(SDL.HINT_AUDIO_DRIVER, "disk")
	_ = SDL.SetHint(
		SDL.HINT_AUDIO_DISK_OUTPUT_FILE,
		strings.clone_to_cstring(outputPath, context.temp_allocator),
	)
	engine := VoiceEngine_create(
		{source = {kind = .Silence}, sink = {kind = .Device}, echoCancellation = true},
	)
	started := VoiceEngine_start(engine)
	raw := SDL.GetHint(SDL.HINT_AUDIO_DEVICE_RAW_STREAM)
	encoder, code := opus.createVoiceEncoder(common.VOICE_SAMPLE_RATE, opus.VOICE_ENCODER_SETTINGS)
	assert(encoder != nil, fmt.tprintf("expected an encoder: %s", opus.errorString(code)))
	tone: [common.VOICE_FRAME_SAMPLES]f32
	packet: [opus.MAX_PACKET_BYTES]u8
	// 1.5 s of a far-end tone, pushed in real time.
	if started {
		begin := time.tick_now()
		for frame in 0 ..< 75 {
			for &sample, index in tone {
				at := frame * common.VOICE_FRAME_SAMPLES + index
				phase := 2 * math.PI * 440 * f64(at) / common.VOICE_SAMPLE_RATE
				sample = 0.5 * f32(math.sin(phase))
			}
			length := opus.encodeFloat(encoder, tone[:], packet[:])
			_ = VoiceEngine_pushInbound(engine, 7, u32(frame), 0, packet[:length])
			due := time.Duration(frame + 1) * 20 * time.Millisecond
			if wait := due - time.tick_since(begin); wait > 0 {
				time.sleep(wait)
			}
		}
		time.sleep(200 * time.Millisecond)
	}
	opus.destroyEncoder(encoder)
	snapshot := VoiceEngine_snapshot(engine)
	errorText := strings.clone(VoiceEngine_lastError(engine), context.temp_allocator)
	VoiceEngine_destroy(engine)
	assert(started, fmt.tprintf("expected the disk driver to open: %s", errorText))
	stats := snapshot.stats
	log.infof(
		"device echo reference: %d render frames (%d with sound) for %d captured frames, " +
		"%d decoded; capture %.1f us, render %.1f us per frame",
		stats.renderFrames,
		stats.renderActiveFrames,
		stats.framesEchoCancelled,
		stats.framesDecoded,
		stats.echoTotalUS / f64(max(stats.framesEchoCancelled, 1)),
		stats.renderTotalUS / f64(max(stats.renderFrames, 1)),
	)
	assert(
		snapshot.echoCancellation == .Active && stats.framesEchoCancelled >= 60,
		fmt.tprintf("expected AEC3 on every captured frame, got %v", stats),
	)
	// Two render frames per captured frame, give or take the step that is still running.
	assert(
		stats.renderFrames + 4 >= 2 * stats.framesEchoCancelled &&
		stats.renderFrames <= 2 * stats.framesEchoCancelled + 4,
		fmt.tprintf("expected two render frames per captured frame, got %v", stats),
	)
	// The tone played for about 1.4 s of the run (pre-roll and the tail are silent).
	assert(
		stats.renderActiveFrames >= 2 * (stats.framesDecoded - 5) &&
		stats.renderActiveFrames <= stats.renderFrames,
		fmt.tprintf("expected the played tone in the reference, got %v", stats),
	)
	assert(raw == voiceSDLRawStream(ODIN_OS, false, true), "expected the raw stream hint")
}
