package client

import "../common"
import "core:fmt"
import "core:log"
import "core:math"
import "core:mem"
import "core:os"
import "core:testing"
import "core:time"
import "rnnoise"
import "toneanalysis"

// CI sets this (check.sh does) so that a missing RNNoise fails the suite instead of skipping
// the noise suppression tests.
VOICE_TEST_REQUIRE_RNNOISE_ENV :: "HAYCHAT_REQUIRE_RNNOISE"

// voiceTestRNNoiseAvailable loads RNNoise for a test. Without it the test is skipped with a
// warning, unless HAYCHAT_REQUIRE_RNNOISE=1 makes that a failure.
voiceTestRNNoiseAvailable :: proc(t: ^testing.T, loc := #caller_location) -> bool {
	if rnnoise.load() {
		return true
	}
	if os.get_env(VOICE_TEST_REQUIRE_RNNOISE_ENV, context.temp_allocator) == "1" {
		testing.fail_now(
			t,
			fmt.tprintf(
				"RNNoise is required (%s=1) but %s",
				VOICE_TEST_REQUIRE_RNNOISE_ENV,
				rnnoise.loadError(),
			),
			loc,
		)
	}
	log.warnf(
		"skipping: %s. Install the rnnoise runtime package, or set %s=1 to make this fail.",
		rnnoise.loadError(),
		VOICE_TEST_REQUIRE_RNNOISE_ENV,
	)
	return false
}

// #170's suppressor, kept even behind the echo canceller (where WebRTC's would take over).
VOICE_TEST_RNNOISE_OPTIONS :: VoiceCaptureOptions {
	noiseSuppression = true,
	noisePreference  = .RNNoise,
}

// The fixture of the noise suppression tests (and of dev/voice-proof.sh's stage): 440 Hz bursts
// at -9 dBFS RMS, 1.5 s on and 1 s off, over white noise at -34 dBFS, which is above the
// default -45 dBFS gate threshold, so the level gate alone sends the noise between the bursts.
VOICE_TEST_NOISY_TONE :: toneanalysis.NoisyTone {
	hz           = 440,
	amplitude    = 0.5,
	noiseRMSDB   = -34,
	burstSeconds = 1.5,
	gapSeconds   = 1,
	seed         = 170,
}

@(private = "file")
VOICE_TEST_NOISY_FRAMES :: 300 // 6 s

// Frames this long after a burst starts or ends are left out of the level comparison: RNNoise
// takes a few frames to adapt, and its 10 ms delay moves the edges.
@(private = "file")
VOICE_TEST_EDGE_FRAMES :: 10

@(private = "file")
voiceTestNoisyFixture :: proc() -> []f32 {
	samples := make([]f32, VOICE_TEST_NOISY_FRAMES * common.VOICE_FRAME_SAMPLES)
	toneanalysis.writeNoisyTone(samples, common.VOICE_SAMPLE_RATE, VOICE_TEST_NOISY_TONE)
	return samples
}

// Where frame lies: in a burst, in a gap, or near an edge (neither).
@(private = "file")
voiceTestFramePhase :: proc(frame: int) -> (burst: bool, gap: bool) {
	fixture := VOICE_TEST_NOISY_TONE
	period := int((fixture.burstSeconds + fixture.gapSeconds) * 1000 / VOICE_FRAME_MS)
	burstFrames := int(fixture.burstSeconds * 1000 / VOICE_FRAME_MS)
	position := frame % period
	if position >= VOICE_TEST_EDGE_FRAMES && position < burstFrames - VOICE_TEST_EDGE_FRAMES {
		return true, false
	}
	if position >= burstFrames + VOICE_TEST_EDGE_FRAMES &&
	   position < period - VOICE_TEST_EDGE_FRAMES {
		return false, true
	}
	return false, false
}

// The mean power level of the burst and the gap frames of samples, in dBFS.
@(private = "file")
voiceTestBurstAndGapLevels :: proc(samples: []f32) -> (burstDB: f64, gapDB: f64) {
	burstSum, gapSum: f64
	burstCount, gapCount := 0, 0
	for frame in 0 ..< len(samples) / common.VOICE_FRAME_SAMPLES {
		burst, gap := voiceTestFramePhase(frame)
		power: f64
		for sample in samples[frame * common.VOICE_FRAME_SAMPLES:][:common.VOICE_FRAME_SAMPLES] {
			power += f64(sample) * f64(sample)
		}
		power /= common.VOICE_FRAME_SAMPLES
		if burst {
			burstSum += power
			burstCount += 1
		} else if gap {
			gapSum += power
			gapCount += 1
		}
	}
	burstDB = 10 * math.log10(max(burstSum / f64(max(burstCount, 1)), 1e-20))
	gapDB = 10 * math.log10(max(gapSum / f64(max(gapCount, 1)), 1e-20))
	return
}

// The proof of #170: RNNoise takes the noise out of the gaps and keeps the tone, and says
// which frames are speech. Its time per frame is logged for the pull request.
@(test)
testVoiceCaptureStageRemovesNoiseBetweenTheBursts :: proc(t: ^testing.T) {
	if !voiceTestRNNoiseAvailable(t) {
		return
	}
	input := voiceTestNoisyFixture()
	defer delete(input)
	output := make([]f32, len(input))
	defer delete(output)
	copy(output, input)

	stage: VoiceCaptureStage
	assert(VoiceCaptureStage_open(&stage), "expected RNNoise to open")
	defer VoiceCaptureStage_close(&stage)
	totalUS, maxUS: f64
	speechInBursts, speechInGaps, burstFrames, gapFrames := 0, 0, 0, 0
	for frame in 0 ..< VOICE_TEST_NOISY_FRAMES {
		samples := output[frame * common.VOICE_FRAME_SAMPLES:][:common.VOICE_FRAME_SAMPLES]
		result := VoiceCaptureStage_process(&stage, samples, VOICE_TEST_RNNOISE_OPTIONS)
		assert(
			result.denoised && result.noiseBackend == .RNNoise,
			"expected every frame to be denoised by RNNoise",
		)
		elapsedUS := time.duration_microseconds(result.elapsed)
		totalUS += elapsedUS
		maxUS = max(maxUS, elapsedUS)
		speech := result.speechProbability >= VOICE_VAD_SPEECH_PROBABILITY
		burst, gap := voiceTestFramePhase(frame)
		if burst {
			burstFrames += 1
			speechInBursts += speech ? 1 : 0
		} else if gap {
			gapFrames += 1
			speechInGaps += speech ? 1 : 0
		}
	}
	burstIn, gapIn := voiceTestBurstAndGapLevels(input)
	burstOut, gapOut := voiceTestBurstAndGapLevels(output)
	log.infof(
		"RNNoise: bursts %.1f -> %.1f dBFS, gaps %.1f -> %.1f dBFS; speech in %d of %d burst " +
		"and %d of %d gap frames; %.1f us per 20 ms frame (max %.1f us)",
		burstIn,
		burstOut,
		gapIn,
		gapOut,
		speechInBursts,
		burstFrames,
		speechInGaps,
		gapFrames,
		totalUS / VOICE_TEST_NOISY_FRAMES,
		maxUS,
	)
	assert(abs(gapIn - -34) < 1, fmt.tprintf("expected -34 dBFS of noise, got %.2f", gapIn))
	assert(
		gapOut < gapIn - 30,
		fmt.tprintf("expected the gaps 30 dB quieter, got %.1f -> %.1f dBFS", gapIn, gapOut),
	)
	assert(
		abs(burstOut - burstIn) < 2,
		fmt.tprintf("expected the bursts kept within 2 dB, got %.1f -> %.1f", burstIn, burstOut),
	)
	assert(
		speechInBursts * 10 >= burstFrames * 9 && speechInGaps == 0,
		fmt.tprintf(
			"expected speech in 90 %% of the bursts and none of the gaps, got %d/%d and %d/%d",
			speechInBursts,
			burstFrames,
			speechInGaps,
			gapFrames,
		),
	)
	// The tone itself survives at its frequency and level.
	check := toneanalysis.checkRecording(
		output,
		common.VOICE_SAMPLE_RATE,
		{targetHz = 440, expectedRMSDB = toneanalysis.sineRMSDB(0.5)},
		1,
	)
	free_all(context.temp_allocator)
	assert(check.passed, fmt.tprintf("expected the tone to pass voice-check, got %v", check))
}

// Off, or without RNNoise (a stage that never opened, as when the library is missing), the
// frame is passed on exactly as it came, and no speech probability reaches the gate.
@(test)
testVoiceCaptureStagePassesFramesThroughWhenOffOrMissing :: proc(t: ^testing.T) {
	input := voiceTestNoisyFixture()
	defer delete(input)
	frame := make([]f32, common.VOICE_FRAME_SAMPLES)
	defer delete(frame)
	copy(frame, input[:common.VOICE_FRAME_SAMPLES])

	missing: VoiceCaptureStage
	assert(!VoiceCaptureStage_available(&missing), "expected a stage that never opened")
	result := VoiceCaptureStage_process(
		&missing,
		frame,
		{noiseSuppression = true, echoCancellation = true},
	)
	assert(
		!result.denoised && !result.echoCancelled && result.speechProbability == 0,
		"expected no processing",
	)
	assert(
		mem.compare(mem.slice_to_bytes(frame), mem.slice_to_bytes(input[:len(frame)])) == 0,
		"expected the frame unchanged without RNNoise",
	)
	if !voiceTestRNNoiseAvailable(t) {
		return
	}
	stage: VoiceCaptureStage
	assert(VoiceCaptureStage_open(&stage), "expected RNNoise to open")
	defer VoiceCaptureStage_close(&stage)
	result = VoiceCaptureStage_process(&stage, frame, {})
	assert(!result.denoised && !result.echoCancelled, "expected an off stage not to process")
	assert(
		mem.compare(mem.slice_to_bytes(frame), mem.slice_to_bytes(input[:len(frame)])) == 0,
		"expected the frame unchanged while off",
	)
}

// Runs the fixture through an unpaced engine in voice activity mode at the default threshold
// and returns its counters.
@(private = "file")
voiceTestNoisyEngine :: proc(
	path: string,
	noiseSuppression: bool,
	preference := VoiceNoisePreference.RNNoise,
	echoCancellation := false,
) -> VoiceEngineSnapshot {
	engine := VoiceEngine_create(
		{
			source = {kind = .File, path = path},
			sink = {kind = .Null},
			gateMode = .VoiceActivity,
			unpaced = true,
			noiseSuppression = noiseSuppression,
			noisePreference = preference,
			echoCancellation = echoCancellation,
		},
	)
	defer VoiceEngine_destroy(engine)
	assert(
		VoiceEngine_open(engine),
		fmt.tprintf("expected to open: %s", VoiceEngine_lastError(engine)),
	)
	for _ in 0 ..< VOICE_TEST_NOISY_FRAMES {
		VoiceEngine_step(engine)
	}
	snapshot := VoiceEngine_snapshot(engine)
	VoiceEngine_close(engine)
	return snapshot
}

// The gate: the level alone sends the -34 dBFS noise between the bursts; with RNNoise the gaps
// are gated (the denoised level and the speech probability both fall), and the bursts still go
// out. The snapshot reports the stage and its counters.
@(test)
testVoiceEngineNoiseSuppressionGatesTheNoise :: proc(t: ^testing.T) {
	if !voiceTestOpusAvailable(t) || !voiceTestRNNoiseAvailable(t) {
		return
	}
	dir := configTestCreateTempDir("haychat_voice_noise")
	defer configTestRemovePathIfExists(dir)
	path := configTestJoinPath({dir, "noisy.f32"})
	input := voiceTestNoisyFixture()
	writeErr := os.write_entire_file(path, mem.slice_to_bytes(input))
	delete(input)
	assert(writeErr == nil, fmt.tprintf("expected to write the fixture: %v", writeErr))

	off := voiceTestNoisyEngine(path, false)
	on := voiceTestNoisyEngine(path, true)
	log.infof(
		"gate: %d of %d frames gated without RNNoise, %d with it (%d sent)",
		off.stats.framesGated,
		off.stats.framesCaptured,
		on.stats.framesGated,
		on.stats.framesSent,
	)
	assert(
		off.stats.framesGated <= VOICE_VAD_ATTACK_FRAMES && off.stats.framesDenoised == 0,
		fmt.tprintf("expected the level gate to send the noise, got %v", off.stats),
	)
	// The 6 s hold two 1 s gaps (100 frames) and 200 burst frames; the hangover still sends
	// VOICE_VAD_HANGOVER_FRAMES after each burst, so about 70 gap frames can be gated.
	gapFrames := 100 - 2 * VOICE_VAD_HANGOVER_FRAMES
	assert(
		int(on.stats.framesGated) >= gapFrames - 10,
		fmt.tprintf("expected about %d frames gated with RNNoise, got %v", gapFrames, on.stats),
	)
	assert(
		on.stats.framesSent >= 200 - 2 * VOICE_VAD_ATTACK_FRAMES,
		fmt.tprintf("expected the bursts sent with RNNoise, got %v", on.stats),
	)
	assert(
		on.stats.framesDenoised == VOICE_TEST_NOISY_FRAMES && on.stats.denoiseMaxUS > 0,
		fmt.tprintf("expected every frame denoised and timed, got %v", on.stats),
	)
	assert(
		on.noiseSuppression == .Active && off.noiseSuppression == .Off,
		fmt.tprintf(
			"expected active and off, got %v and %v",
			on.noiseSuppression,
			off.noiseSuppression,
		),
	)
}

// The control: a running engine turns RNNoise on and off from the next frame on, and the
// snapshot says what runs.
@(test)
testVoiceEngineNoiseSuppressionFollowsItsControl :: proc(t: ^testing.T) {
	if !voiceTestOpusAvailable(t) || !voiceTestRNNoiseAvailable(t) {
		return
	}
	engine := VoiceEngine_create(
		{
			source = {kind = .Tone, toneHz = 440},
			sink = {kind = .Null},
			unpaced = true,
			noisePreference = .RNNoise,
		},
	)
	defer VoiceEngine_destroy(engine)
	assert(VoiceEngine_open(engine), "expected to open")
	VoiceEngine_step(engine)
	snapshot := VoiceEngine_snapshot(engine)
	assert(
		snapshot.noiseSuppression == .Off && snapshot.stats.framesDenoised == 0,
		"expected noise suppression off by default in an engine config",
	)
	VoiceEngine_setNoiseSuppression(engine, true)
	for _ in 0 ..< 5 {
		VoiceEngine_step(engine)
	}
	snapshot = VoiceEngine_snapshot(engine)
	assert(
		snapshot.noiseSuppression == .Active &&
		snapshot.noiseBackend == .RNNoise &&
		snapshot.stats.framesDenoised == 5,
		fmt.tprintf("expected 5 frames denoised by RNNoise, got %v", snapshot.stats),
	)
	assert(
		snapshot.speechProbability >= VOICE_VAD_SPEECH_PROBABILITY,
		fmt.tprintf("expected a tone to read as speech, got %.2f", snapshot.speechProbability),
	)
	VoiceEngine_setNoiseSuppression(engine, false)
	VoiceEngine_step(engine)
	snapshot = VoiceEngine_snapshot(engine)
	assert(
		snapshot.noiseSuppression == .Off && snapshot.stats.framesDenoised == 5,
		"expected noise suppression to stop",
	)
	VoiceEngine_close(engine)
}

// The gate's speech probability: without one the level decides; with one both must pass.
@(test)
testVoiceGateNeedsSpeechWhenNoiseSuppressionRuns :: proc(t: ^testing.T) {
	loudNoise := VoiceGateInput {
		mode                 = .VoiceActivity,
		levelDB              = -20,
		thresholdDB          = -45,
		hasSpeechProbability = true,
		speechProbability    = 0.1,
	}
	gate: VoiceGate
	for _ in 0 ..< 10 {
		assert(!VoiceGate_update(&gate, loudNoise).transmit, "expected noise to stay gated")
	}
	levelOnly := loudNoise
	levelOnly.hasSpeechProbability = false
	opened := false
	for _ in 0 ..< VOICE_VAD_ATTACK_FRAMES {
		opened = VoiceGate_update(&gate, levelOnly).transmit
	}
	assert(opened, "expected the level gate to open without a speech probability")

	gate = {}
	quietSpeech := loudNoise
	quietSpeech.levelDB = -60
	quietSpeech.speechProbability = 0.99
	for _ in 0 ..< 10 {
		assert(!VoiceGate_update(&gate, quietSpeech).transmit, "expected the threshold to hold")
	}
	speech := quietSpeech
	speech.levelDB = -20
	for _ in 0 ..< VOICE_VAD_ATTACK_FRAMES {
		opened = VoiceGate_update(&gate, speech).transmit
	}
	assert(opened, "expected loud speech to open the gate")
}

// #171: while echo cancellation runs, WebRTC's suppressor takes the noise out of the gaps
// instead of RNNoise, and RNNoise (listening only) still tells the gate which frames are
// speech. Nothing is played, so AEC3 has no echo to remove here. Its numbers are logged for
// the pull request.
@(test)
testVoiceCaptureStageWebRTCRemovesNoiseBetweenTheBursts :: proc(t: ^testing.T) {
	if !voiceTestWebRTCAPMAvailable(t) || !voiceTestRNNoiseAvailable(t) {
		return
	}
	input := voiceTestNoisyFixture()
	defer delete(input)
	output := make([]f32, len(input))
	defer delete(output)
	copy(output, input)

	stage: VoiceCaptureStage
	assert(VoiceCaptureStage_open(&stage), "expected the stage to open")
	defer VoiceCaptureStage_close(&stage)
	totalUS: f64
	speechInBursts, speechInGaps, burstFrames, gapFrames := 0, 0, 0, 0
	for frame in 0 ..< VOICE_TEST_NOISY_FRAMES {
		samples := output[frame * common.VOICE_FRAME_SAMPLES:][:common.VOICE_FRAME_SAMPLES]
		result := VoiceCaptureStage_process(
			&stage,
			samples,
			{noiseSuppression = true, echoCancellation = true},
		)
		assert(
			result.denoised && result.noiseBackend == .WebRTC && result.hasSpeechProbability,
			"expected WebRTC's suppressor with RNNoise's speech probability",
		)
		totalUS += time.duration_microseconds(result.elapsed)
		speech := result.speechProbability >= VOICE_VAD_SPEECH_PROBABILITY
		burst, gap := voiceTestFramePhase(frame)
		if burst {
			burstFrames += 1
			speechInBursts += speech ? 1 : 0
		} else if gap {
			gapFrames += 1
			speechInGaps += speech ? 1 : 0
		}
	}
	burstIn, gapIn := voiceTestBurstAndGapLevels(input)
	burstOut, gapOut := voiceTestBurstAndGapLevels(output)
	log.infof(
		"WebRTC noise suppression: bursts %.1f -> %.1f dBFS, gaps %.1f -> %.1f dBFS; speech " +
		"in %d of %d burst and %d of %d gap frames; %.1f us per 20 ms frame with RNNoise's VAD",
		burstIn,
		burstOut,
		gapIn,
		gapOut,
		speechInBursts,
		burstFrames,
		speechInGaps,
		gapFrames,
		totalUS / VOICE_TEST_NOISY_FRAMES,
	)
	assert(
		gapOut < gapIn - 15,
		fmt.tprintf("expected the gaps 15 dB quieter, got %.1f -> %.1f dBFS", gapIn, gapOut),
	)
	// WebRTC's suppressor takes a little of a steady tone too (2.3 dB at High).
	assert(
		abs(burstOut - burstIn) < 4,
		fmt.tprintf("expected the bursts kept within 4 dB, got %.1f -> %.1f", burstIn, burstOut),
	)
	assert(
		speechInBursts * 10 >= burstFrames * 9 && speechInGaps == 0,
		fmt.tprintf(
			"expected speech in 90 %% of the bursts and none of the gaps, got %d/%d and %d/%d",
			speechInBursts,
			burstFrames,
			speechInGaps,
			gapFrames,
		),
	)
}

// The engine with the client's rule (Auto) and echo cancellation on: WebRTC suppresses,
// RNNoise's speech probability still gates the gaps. With echo cancellation off, RNNoise
// suppresses again, as in #170.
@(test)
testVoiceEngineWebRTCNoiseSuppressionGatesTheNoise :: proc(t: ^testing.T) {
	if !voiceTestOpusAvailable(t) ||
	   !voiceTestRNNoiseAvailable(t) ||
	   !voiceTestWebRTCAPMAvailable(t) {
		return
	}
	dir := configTestCreateTempDir("haychat_voice_webrtc_noise")
	defer configTestRemovePathIfExists(dir)
	path := configTestJoinPath({dir, "noisy.f32"})
	input := voiceTestNoisyFixture()
	writeErr := os.write_entire_file(path, mem.slice_to_bytes(input))
	delete(input)
	assert(writeErr == nil, fmt.tprintf("expected to write the fixture: %v", writeErr))
	on := voiceTestNoisyEngine(path, true, .Auto, echoCancellation = true)
	headset := voiceTestNoisyEngine(path, true, .Auto)
	gapFrames := 100 - 2 * VOICE_VAD_HANGOVER_FRAMES
	assert(
		on.noiseSuppression == .Active &&
		on.noiseBackend == .WebRTC &&
		on.stats.framesEchoCancelled == VOICE_TEST_NOISY_FRAMES,
		fmt.tprintf("expected AEC3 and WebRTC noise suppression, got %v", on.noiseBackend),
	)
	assert(
		headset.noiseSuppression == .Active &&
		headset.noiseBackend == .RNNoise &&
		headset.stats.framesEchoCancelled == 0 &&
		int(headset.stats.framesGated) >= gapFrames - 10,
		fmt.tprintf("expected RNNoise with echo cancellation off, got %v", headset.noiseBackend),
	)
	assert(
		int(on.stats.framesGated) >= gapFrames - 10 &&
		on.stats.framesSent >= 200 - 2 * VOICE_VAD_ATTACK_FRAMES,
		fmt.tprintf("expected the gaps gated and the bursts sent, got %v", on.stats),
	)
}

// #171's rule: WebRTC's suppressor only while echo cancellation runs (or without RNNoise),
// RNNoise otherwise; the RNNoise preference keeps it whenever it loads.
@(test)
testVoiceNoiseBackendFollowsEchoCancellation :: proc(t: ^testing.T) {
	Case :: struct {
		rnnoise, webrtc, echo: bool,
		preference:            VoiceNoisePreference,
		expected:              VoiceNoiseBackend,
	}
	cases := [?]Case {
		{true, true, true, .Auto, .WebRTC},
		{true, true, false, .Auto, .RNNoise},
		{true, false, true, .Auto, .RNNoise},
		{false, true, false, .Auto, .WebRTC},
		{false, true, true, .Auto, .WebRTC},
		{false, false, true, .Auto, .None},
		{true, true, true, .RNNoise, .RNNoise},
		{false, true, true, .RNNoise, .WebRTC},
	}
	for c in cases {
		got := voiceNoiseBackendFor(c.rnnoise, c.webrtc, c.echo, c.preference)
		assert(got == c.expected, fmt.tprintf("expected %v for %v, got %v", c.expected, c, got))
	}
	_ = t
}
