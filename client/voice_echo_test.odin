package client

// #171: echo cancellation (AEC3 through client/webrtcapm) in the capture stage and the engine.
// A known far-end signal is fed as the render reference and, delayed and scaled, into the
// capture as an echo; the tests measure how much AEC3 removes (ERLE, echo return loss
// enhancement: the echo's power over what is left, in dB) and that a near-end tone at another
// frequency survives double talk. The numbers are logged for the pull request.

import "../common"
import "core:fmt"
import "core:log"
import "core:math"
import "core:os"
import "core:testing"
import "core:time"
import "opus"
import "toneanalysis"
import "webrtcapm"

// CI sets this (check.sh does, with HAYCHAT_WEBRTC_APM_LIBRARY pointing at the wrapper it
// built) so that a missing library fails the suite instead of skipping the echo tests.
VOICE_TEST_REQUIRE_WEBRTC_APM_ENV :: "HAYCHAT_REQUIRE_WEBRTC_APM"

voiceTestWebRTCAPMAvailable :: proc(t: ^testing.T, loc := #caller_location) -> bool {
	if webrtcapm.load() {
		return true
	}
	if os.get_env(VOICE_TEST_REQUIRE_WEBRTC_APM_ENV, context.temp_allocator) == "1" {
		testing.fail_now(
			t,
			fmt.tprintf(
				"WebRTC audio processing is required (%s=1) but %s",
				VOICE_TEST_REQUIRE_WEBRTC_APM_ENV,
				webrtcapm.loadError(),
			),
			loc,
		)
	}
	log.warnf(
		"skipping: %s. Build it with deploy/build-linux-webrtc-apm.sh and set %s, or set " +
		"%s=1 to make this fail.",
		webrtcapm.loadError(),
		webrtcapm.LIBRARY_PATH_ENV,
		VOICE_TEST_REQUIRE_WEBRTC_APM_ENV,
	)
	return false
}

// The echo path of the tests: a loudspeaker 120 ms away (the device buffers and the air) at
// −6 dB, with two weaker reflections, as a small room would add.
@(private = "file")
VOICE_TEST_ECHO_TAPS :: [?]struct {
	delayMS: int,
	gain:    f32,
} {
	{120, 0.5},
	{127, 0.15},
	{141, 0.06},
}

@(private = "file")
VOICE_TEST_ECHO_SECONDS :: 12
@(private = "file")
VOICE_TEST_ECHO_FRAMES :: VOICE_TEST_ECHO_SECONDS * 50
// ERLE is measured after AEC3 has had this long to find the delay and converge.
@(private = "file")
VOICE_TEST_ECHO_SETTLE_FRAMES :: 4 * 50
// The double talk window: a near-end tone from 8 s to 11 s.
@(private = "file")
VOICE_TEST_DOUBLE_TALK_START :: 8 * 50
@(private = "file")
VOICE_TEST_DOUBLE_TALK_END :: 11 * 50
@(private = "file")
VOICE_TEST_NEAR_HZ :: 1000
@(private = "file")
VOICE_TEST_NEAR_AMPLITUDE :: f32(0.1)

// A far end like speech: noise through three one-pole low-passes at 1.5 kHz (speech has little
// energy above 4 kHz), in syllables of 160 ms with short pauses, at about −20 dBFS while it
// talks. Deterministic.
@(private = "file")
voiceTestSpeechLikeFarEnd :: proc(samples: []f32, seed: u64) {
	state := seed
	low, lower, lowest: f32
	alpha := f32(1 - math.exp(-2 * math.PI * 1500 / f64(common.VOICE_SAMPLE_RATE)))
	syllable := 160 * VOICE_SAMPLES_PER_MS
	for &sample, index in samples {
		white := f32(f64(voiceNextRandom(&state) >> 11) / f64(1 << 53)) * 2 - 1
		low += alpha * (white - low)
		lower += alpha * (low - lower)
		lowest += alpha * (lower - lowest)
		// Syllable envelope: a raised sine, every fourth syllable a pause.
		position := index % syllable
		envelope := f32(math.sin(math.PI * f64(position) / f64(syllable)))
		if (index / syllable) % 4 == 3 {
			envelope = 0
		}
		sample = lowest * envelope * 1.2
	}
}

@(private = "file")
voiceTestTone :: proc(samples: []f32, hz: f64, amplitude: f32, from, to: int) {
	for index in from ..< min(to, len(samples)) {
		phase := 2 * math.PI * hz * f64(index) / f64(common.VOICE_SAMPLE_RATE)
		samples[index] += amplitude * f32(math.sin(phase))
	}
}

@(private = "file")
voiceTestPowerDB :: proc(samples: []f32) -> f64 {
	power: f64
	for sample in samples {
		power += f64(sample) * f64(sample)
	}
	return 10 * math.log10(max(power / f64(max(len(samples), 1)), 1e-20))
}

@(private = "file")
VoiceTestEchoRun :: struct {
	erleDB:            f64,
	echoInDB:          f64,
	echoOutDB:         f64,
	nearInDB:          f64,
	nearOutDB:         f64,
	// The near-end tone's level (Goertzel) during double talk, in and out.
	nearToneInDB:      f64,
	nearToneOutDB:     f64,
	captureMeanUS:     f64,
	captureMaxUS:      f64,
	renderMeanUS:      f64,
	stats:             webrtcapm.Stats,
	hasStats:          bool,
}

// Runs the fixture through a stage: far end as the render reference, capture = echo (+ the
// near-end tone during double talk). Returns the measurements.
@(private = "file")
voiceTestEchoRun :: proc(
	options: VoiceCaptureOptions,
	doubleTalk: bool,
) -> (
	run: VoiceTestEchoRun,
) {
	total := VOICE_TEST_ECHO_FRAMES * common.VOICE_FRAME_SAMPLES
	far := make([]f32, total)
	defer delete(far)
	echo := make([]f32, total)
	defer delete(echo)
	near := make([]f32, total)
	defer delete(near)
	output := make([]f32, total)
	defer delete(output)
	voiceTestSpeechLikeFarEnd(far, 171)
	for tap in VOICE_TEST_ECHO_TAPS {
		delay := tap.delayMS * VOICE_SAMPLES_PER_MS
		for index in delay ..< total {
			echo[index] += tap.gain * far[index - delay]
		}
	}
	if doubleTalk {
		voiceTestTone(
			near,
			VOICE_TEST_NEAR_HZ,
			VOICE_TEST_NEAR_AMPLITUDE,
			VOICE_TEST_DOUBLE_TALK_START * common.VOICE_FRAME_SAMPLES,
			VOICE_TEST_DOUBLE_TALK_END * common.VOICE_FRAME_SAMPLES,
		)
	}
	for index in 0 ..< total {
		output[index] = clamp(echo[index] + near[index], -1, 1)
	}

	stage: VoiceCaptureStage
	_ = VoiceCaptureStage_open(&stage)
	defer VoiceCaptureStage_close(&stage)
	captureUS, renderUS: f64
	for frame in 0 ..< VOICE_TEST_ECHO_FRAMES {
		at := frame * common.VOICE_FRAME_SAMPLES
		// What is played reaches the canceller before its echo is captured.
		renderUS += time.duration_microseconds(
			VoiceCaptureStage_render(&stage, far[at:][:common.VOICE_FRAME_SAMPLES]),
		)
		result := VoiceCaptureStage_process(
			&stage,
			output[at:][:common.VOICE_FRAME_SAMPLES],
			options,
		)
		elapsedUS := time.duration_microseconds(result.elapsed)
		captureUS += elapsedUS
		run.captureMaxUS = max(run.captureMaxUS, elapsedUS)
	}
	run.captureMeanUS = captureUS / VOICE_TEST_ECHO_FRAMES
	run.renderMeanUS = renderUS / VOICE_TEST_ECHO_FRAMES
	run.stats, run.hasStats = VoiceCaptureStage_echoStats(&stage)

	// Echo alone: from the settled point to the double talk window.
	echoFrom := VOICE_TEST_ECHO_SETTLE_FRAMES * common.VOICE_FRAME_SAMPLES
	echoTo := VOICE_TEST_DOUBLE_TALK_START * common.VOICE_FRAME_SAMPLES
	run.echoInDB = voiceTestPowerDB(echo[echoFrom:echoTo])
	run.echoOutDB = voiceTestPowerDB(output[echoFrom:echoTo])
	run.erleDB = run.echoInDB - run.echoOutDB
	// Double talk: the tone's own bin, so the far end's echo does not count.
	talkFrom := VOICE_TEST_DOUBLE_TALK_START * common.VOICE_FRAME_SAMPLES
	talkTo := VOICE_TEST_DOUBLE_TALK_END * common.VOICE_FRAME_SAMPLES
	run.nearInDB = voiceTestPowerDB(near[talkFrom:talkTo])
	run.nearOutDB = voiceTestPowerDB(output[talkFrom:talkTo])
	run.nearToneInDB = voiceTestToneLevel(near[talkFrom:talkTo])
	run.nearToneOutDB = voiceTestToneLevel(output[talkFrom:talkTo])
	return
}

// The near-end tone's power in samples (the mean Goertzel power of 0.5 s Hann-windowed
// blocks), in dB. Only the difference between two of these means anything.
@(private = "file")
voiceTestToneLevel :: proc(samples: []f32) -> f64 {
	block := 24000
	sum: f64
	count := 0
	for start := 0; start + block <= len(samples); start += block {
		window := toneanalysis.hannWindow(samples[start:][:block])
		sum += toneanalysis.goertzelPower(window, common.VOICE_SAMPLE_RATE, VOICE_TEST_NEAR_HZ)
		count += 1
	}
	free_all(context.temp_allocator)
	return toneanalysis.powerDB(sum / f64(max(count, 1)))
}

// The proof of #171: AEC3 removes a delayed echo of a speech-like far end, keeps a near-end
// tone during double talk, and finds the echo path's delay. Its time per frame is logged.
@(test)
testVoiceCaptureStageCancelsADelayedEcho :: proc(t: ^testing.T) {
	if !voiceTestWebRTCAPMAvailable(t) {
		return
	}
	off := voiceTestEchoRun({}, true)
	on := voiceTestEchoRun({echoCancellation = true}, true)
	// The client's default: AEC3 with WebRTC's noise suppression after it.
	both := voiceTestEchoRun({echoCancellation = true, noiseSuppression = true}, true)
	log.infof(
		"AEC3 + WebRTC noise suppression: ERLE %.1f dB; near-end tone %.1f -> %.1f dBFS; " +
		"%.1f us per frame (max %.1f us) with RNNoise's VAD",
		both.erleDB,
		both.nearToneInDB,
		both.nearToneOutDB,
		both.captureMeanUS,
		both.captureMaxUS,
	)
	assert(
		both.erleDB >= 30 && both.nearToneOutDB > both.nearToneInDB - 6,
		fmt.tprintf("expected 30 dB of ERLE and the near-end tone kept, got %v", both),
	)
	log.infof(
		"AEC3: echo %.1f -> %.1f dBFS (ERLE %.1f dB; AEC3 reports ERLE %.1f dB, ERL %.1f dB, " +
		"delay %d ms); double talk: near-end tone %.1f -> %.1f dBFS; capture %.1f us per " +
		"20 ms frame (max %.1f us), render %.1f us",
		on.echoInDB,
		on.echoOutDB,
		on.erleDB,
		on.stats.echoReturnLossEnhancement,
		on.stats.echoReturnLoss,
		on.stats.delayMS,
		on.nearToneInDB,
		on.nearToneOutDB,
		on.captureMeanUS,
		on.captureMaxUS,
		on.renderMeanUS,
	)
	assert(abs(off.erleDB) < 0.01, fmt.tprintf("expected no change while off, got %v", off))
	assert(on.erleDB >= 20, fmt.tprintf("expected at least 20 dB of ERLE, got %.1f", on.erleDB))
	assert(
		on.nearToneOutDB > on.nearToneInDB - 6,
		fmt.tprintf(
			"expected the near-end tone kept within 6 dB in double talk, got %.1f -> %.1f",
			on.nearToneInDB,
			on.nearToneOutDB,
		),
	)
	assert(
		on.hasStats && on.stats.hasDelay && abs(on.stats.delayMS - 120) <= 12,
		fmt.tprintf("expected AEC3 to find the 120 ms delay, got %v", on.stats),
	)
}

// The delay is unknown to AEC3 and differs by device; it finds short and long ones.
@(test)
testVoiceCaptureStageCancelsEchoesAtOtherDelays :: proc(t: ^testing.T) {
	if !voiceTestWebRTCAPMAvailable(t) {
		return
	}
	for delayMS in ([?]int{40, 200}) {
		erle := voiceTestEchoErleAtDelay(delayMS)
		log.infof("AEC3: ERLE %.1f dB with a %d ms echo", erle, delayMS)
		assert(erle >= 20, fmt.tprintf("expected 20 dB of ERLE at %d ms, got %.1f", delayMS, erle))
	}
}

@(private = "file")
voiceTestEchoErleAtDelay :: proc(delayMS: int) -> f64 {
	total := VOICE_TEST_ECHO_FRAMES * common.VOICE_FRAME_SAMPLES
	far := make([]f32, total)
	defer delete(far)
	capture := make([]f32, total)
	defer delete(capture)
	voiceTestSpeechLikeFarEnd(far, u64(delayMS))
	delay := delayMS * VOICE_SAMPLES_PER_MS
	for index in delay ..< total {
		capture[index] = 0.5 * far[index - delay]
	}
	from := VOICE_TEST_ECHO_SETTLE_FRAMES * common.VOICE_FRAME_SAMPLES
	echoDB := voiceTestPowerDB(capture[from:])
	stage: VoiceCaptureStage
	_ = VoiceCaptureStage_open(&stage)
	defer VoiceCaptureStage_close(&stage)
	for frame in 0 ..< VOICE_TEST_ECHO_FRAMES {
		at := frame * common.VOICE_FRAME_SAMPLES
		_ = VoiceCaptureStage_render(&stage, far[at:][:common.VOICE_FRAME_SAMPLES])
		_ = VoiceCaptureStage_process(
			&stage,
			capture[at:][:common.VOICE_FRAME_SAMPLES],
			{echoCancellation = true},
		)
	}
	return echoDB - voiceTestPowerDB(capture[from:])
}

// With both on, WebRTC owns noise suppression (never RNNoise on top) and RNNoise only gives the
// gate its speech probability, without changing the frame. Echo cancellation going off and on
// mid-call switches the suppressor with it.
@(test)
testVoiceCaptureStageLetsWebRTCOwnNoiseSuppression :: proc(t: ^testing.T) {
	if !voiceTestWebRTCAPMAvailable(t) {
		return
	}
	stage: VoiceCaptureStage
	assert(VoiceCaptureStage_open(&stage), "expected the stage to open")
	defer VoiceCaptureStage_close(&stage)
	frame: [common.VOICE_FRAME_SAMPLES]f32
	options := VoiceCaptureOptions {
		noiseSuppression = true,
		echoCancellation = true,
	}
	assert(
		VoiceCaptureStage_noiseBackend(&stage, options) == .WebRTC,
		"expected WebRTC's suppressor while echo cancellation runs",
	)
	result := VoiceCaptureStage_process(&stage, frame[:], options)
	assert(
		result.denoised && result.noiseBackend == .WebRTC && result.echoCancelled,
		fmt.tprintf("expected WebRTC noise suppression and AEC3, got %v", result),
	)
	assert(
		result.hasSpeechProbability == VoiceCaptureStage_hasVAD(&stage),
		"expected RNNoise's speech probability whenever RNNoise loads",
	)
	if VoiceCaptureStage_hasVAD(&stage) {
		// Echo cancellation off (a headset): RNNoise suppresses, AEC3 does not run.
		headset := VoiceCaptureOptions {
			noiseSuppression = true,
		}
		result = VoiceCaptureStage_process(&stage, frame[:], headset)
		assert(
			result.denoised && result.noiseBackend == .RNNoise && !result.echoCancelled,
			fmt.tprintf("expected RNNoise with echo cancellation off, got %v", result),
		)
		assert(!stage.renderActive, "expected no reference fed while AEC3 is off")
		// And back on: WebRTC again, its state reset first.
		result = VoiceCaptureStage_process(&stage, frame[:], options)
		assert(
			result.noiseBackend == .WebRTC && result.echoCancelled && stage.renderActive,
			fmt.tprintf("expected AEC3 and WebRTC's suppressor again, got %v", result),
		)
		preferred := options
		preferred.noisePreference = .RNNoise
		assert(
			VoiceCaptureStage_noiseBackend(&stage, preferred) == .RNNoise,
			"expected the RNNoise preference to keep RNNoise",
		)
	}
	// Echo cancellation alone suppresses no noise and asks the gate nothing extra.
	result = VoiceCaptureStage_process(&stage, frame[:], {echoCancellation = true})
	assert(
		!result.denoised && result.echoCancelled && !result.hasSpeechProbability,
		fmt.tprintf("expected AEC3 alone, got %v", result),
	)
}

// The engine: a far-end tone arrives from a speaker, the null sink plays it, and the simulated
// echo puts it back into the microphone 120 ms later. With echo cancellation the level the
// gate sees falls; the snapshot reports the canceller and its counters.
@(test)
testVoiceEngineCancelsTheEchoOfWhatItPlays :: proc(t: ^testing.T) {
	if !voiceTestOpusAvailable(t) || !voiceTestWebRTCAPMAvailable(t) {
		return
	}
	off := voiceTestEchoEngine(false)
	on := voiceTestEchoEngine(true)
	log.infof(
		"engine: input level with the echo %.1f dBFS, %.1f dBFS cancelled; %d frames " +
		"cancelled, %d render frames; capture %.1f us, render %.1f us per frame",
		off.levelDB,
		on.levelDB,
		on.snapshot.stats.framesEchoCancelled,
		on.snapshot.stats.renderFrames,
		on.snapshot.stats.echoTotalUS / f64(max(on.snapshot.stats.framesEchoCancelled, 1)),
		on.snapshot.stats.renderTotalUS / f64(max(on.snapshot.stats.renderFrames, 1)),
	)
	assert(
		off.snapshot.echoCancellation == .Off && on.snapshot.echoCancellation == .Active,
		fmt.tprintf(
			"expected off and active, got %v and %v",
			off.snapshot.echoCancellation,
			on.snapshot.echoCancellation,
		),
	)
	assert(off.levelDB > -25, fmt.tprintf("expected the echo heard, got %.1f", off.levelDB))
	assert(
		on.levelDB < off.levelDB - 20,
		fmt.tprintf("expected 20 dB less echo, got %.1f -> %.1f", off.levelDB, on.levelDB),
	)
	assert(
		on.snapshot.stats.renderFrames >= 2 * on.snapshot.stats.framesEchoCancelled - 2,
		fmt.tprintf("expected two render frames per captured frame, got %v", on.snapshot.stats),
	)
}

@(private = "file")
VoiceTestEchoEngineResult :: struct {
	// The mean input level over the last 2 s.
	levelDB:  f32,
	snapshot: VoiceEngineSnapshot,
}

@(private = "file")
voiceTestEchoEngine :: proc(echoCancellation: bool) -> (result: VoiceTestEchoEngineResult) {
	engine := VoiceEngine_create(
		{
			source = {kind = .Silence},
			sink = {kind = .Null},
			unpaced = true,
			echoCancellation = echoCancellation,
			echoSimulation = {delayMS = 120, gain = 0.5},
		},
	)
	defer VoiceEngine_destroy(engine)
	assert(VoiceEngine_open(engine), "expected to open")
	encoder, code := opus.createVoiceEncoder(common.VOICE_SAMPLE_RATE, opus.VOICE_ENCODER_SETTINGS)
	assert(encoder != nil, fmt.tprintf("expected an encoder: %s", opus.errorString(code)))
	defer opus.destroyEncoder(encoder)
	tone: [common.VOICE_FRAME_SAMPLES]f32
	packet: [opus.MAX_PACKET_BYTES]u8
	frames := 8 * 50
	levelSum: f64
	levelCount := 0
	for frame in 0 ..< frames {
		for &sample, index in tone {
			at := frame * common.VOICE_FRAME_SAMPLES + index
			sample = 0.5 * f32(math.sin(2 * math.PI * 440 * f64(at) / common.VOICE_SAMPLE_RATE))
		}
		length := opus.encodeFloat(encoder, tone[:], packet[:])
		assert(length > 0, "expected the far end to encode")
		_ = VoiceEngine_pushInbound(engine, 7, u32(frame), 0, packet[:length])
		VoiceEngine_step(engine)
		if frame >= frames - 100 {
			level, _ := VoiceEngine_inputLevel(engine)
			levelSum += math.pow(10, f64(level) / 10)
			levelCount += 1
		}
	}
	result.levelDB = f32(10 * math.log10(max(levelSum / f64(levelCount), 1e-20)))
	result.snapshot = VoiceEngine_snapshot(engine)
	VoiceEngine_close(engine)
	return
}

