package client

// The capture-processing stage (#170, #171): the one step between capture (after the input
// gain) and the level meter, the gate and the encoder. Everything the voice thread does to the
// microphone signal happens in VoiceCaptureStage_process, with two optional libraries, both
// loaded at runtime:
//
//   - WebRTC audio processing (client/webrtcapm, #171): AEC3 echo cancellation and WebRTC noise
//     suppression in one module, fed what the engine plays (VoiceCaptureStage_render) as the
//     echo reference. When it loads it owns noise suppression too: AEC3 cancels worse behind
//     another stage's nonlinear suppression, and two suppressors in a row remove speech
//     (docs/plan/2026-11-25-wasapi-communications-capture.md, "No Double Processing").
//   - RNNoise (client/rnnoise, #170): noise suppression when WebRTC audio processing is missing
//     (or a test asks for it), and in every case the speech probability for the voice activity
//     gate. Behind WebRTC's noise suppression it only analyses a copy of the processed frame
//     (VAD only, about 120 µs per 20 ms frame) and changes nothing, so there is still one
//     suppressor; WebRTC 2.x has no voice activity detector of its own, and RNNoise's speech
//     gate keeps background noise out where the level gate alone would send it
//     (docs/voice-manual-test.md, "Noise Suppression").
//
// The stage belongs to the voice thread: VoiceEngine_open opens it, VoiceEngine_close closes
// it, and nothing in it allocates on HayChat's heap per frame (RNNoise's and WebRTC's states
// are created once, in open, by the libraries themselves). What runs is decided per frame from
// VoiceCaptureOptions; turning a processor back on resets it, so audio from before a pause
// does not shape the first frames after it.

import "../common"
import "core:time"
import "rnnoise"
import "webrtcapm"

// RNNoise's and WebRTC's 10 ms frames: two per 20 ms Opus frame.
VOICE_CAPTURE_SUBFRAMES :: common.VOICE_FRAME_SAMPLES / rnnoise.FRAME_SIZE
#assert(VOICE_CAPTURE_SUBFRAMES * rnnoise.FRAME_SIZE == common.VOICE_FRAME_SAMPLES)
#assert(webrtcapm.FRAME_SIZE == rnnoise.FRAME_SIZE)
#assert(webrtcapm.SAMPLE_RATE == common.VOICE_SAMPLE_RATE)

// The speech probability at or above which a frame counts as speech for the voice activity
// gate while noise suppression runs (VoiceGateInput.speechProbability). RNNoise 0.2 gives a
// steady tone or speech 0.9 to 1, and white noise at −26 to −40 dBFS at most 0.02 to 0.2
// (dev numbers in #170's pull request), so 0.5 leaves room on both sides; real speech was
// measured with dev/voice-manual-test.sh (docs/voice-manual-test.md).
VOICE_VAD_SPEECH_PROBABILITY :: f32(0.5)

// WebRTC's noise suppression level when it owns noise suppression. High is what browsers use
// for calls. On the #170 fixture (−34 dBFS white noise) it lowers the gaps to −52 dBFS
// (VeryHigh: −54), far less than RNNoise's −98, but the gate's speech probability still
// closes them; behind AEC3 it keeps a double-talk tone that RNNoise there would remove
// (voice_capture_test.odin, voice_echo_test.odin).
VOICE_WEBRTC_NOISE_LEVEL :: webrtcapm.NoiseLevel.High

// How often (in 20 ms frames) the stage reads AEC3's statistics: once a second.
VOICE_ECHO_STATS_INTERVAL_FRAMES :: 50

// What the noise suppression setting does now, for the settings screen and voice-stats.
VoiceNoiseSuppressionStatus :: enum u8 {
	// Turned off in the settings (or the engine is not open).
	Off,
	// A suppressor processes every captured frame (VoiceNoiseBackend says which).
	Active,
	// Turned on, but neither library could be loaded or created: frames pass through
	// unchanged and the level gate decides alone.
	Unavailable,
}

// Which library suppresses noise.
VoiceNoiseBackend :: enum u8 {
	None,
	RNNoise,
	WebRTC,
}

// What the echo cancellation setting does now.
VoiceEchoCancellationStatus :: enum u8 {
	Off,
	// AEC3 processes every captured frame against what the engine plays.
	Active,
	// Turned on, but WebRTC audio processing could not be loaded or created.
	Unavailable,
}

// Which noise suppressor a stage may use. Auto is the client's rule (WebRTC when it loads,
// else RNNoise); RNNoise keeps #170's suppressor for tests and its proof.
VoiceNoisePreference :: enum u8 {
	Auto,
	RNNoise,
}

VoiceCaptureOptions :: struct {
	noiseSuppression: bool,
	echoCancellation: bool,
	noisePreference:  VoiceNoisePreference,
	// Milliseconds between a render frame and its echo in the capture, as far as the engine
	// can tell (device buffers and the capture backlog); 0 when it cannot. AEC3 estimates the
	// delay itself and takes this only as a starting point.
	delayHintMS:      int,
}

VoiceCaptureStage :: struct {
	denoiser:         ^rnnoise.DenoiseState,
	// Whether the last frame ran RNNoise, so a frame after a pause can reset it first.
	wasDenoising:     bool,
	scratch:          [rnnoise.FRAME_SIZE]f32,
	apm:              ^webrtcapm.Processor,
	// The configuration last applied to apm, and whether the last frame ran it.
	apmConfig:        webrtcapm.Config,
	wasProcessing:    bool,
	// Whether render frames reach apm: set while echo cancellation runs.
	renderActive:     bool,
	framesSinceStats: int,
	echoStats:        webrtcapm.Stats,
	hasEchoStats:     bool,
}

VoiceCaptureResult :: struct {
	// Noise suppression ran (by noiseBackend).
	denoised:             bool,
	noiseBackend:         VoiceNoiseBackend,
	// AEC3 ran on the frame.
	echoCancelled:        bool,
	// The frame's speech probability (the larger of its two RNNoise frames), for the gate.
	hasSpeechProbability: bool,
	speechProbability:    f32,
	// How long processing took, for the CPU counters.
	elapsed:              time.Duration,
}

// Loads both libraries and creates their states. Each is optional: without one the stage
// does what the other allows, and without both it passes frames through; rnnoise.loadError
// and webrtcapm.loadError say why. Returns whether any processor is available.
VoiceCaptureStage_open :: proc(stage: ^VoiceCaptureStage) -> bool {
	VoiceCaptureStage_close(stage)
	if rnnoise.load() {
		stage.denoiser = rnnoise.createDenoiser()
	}
	if webrtcapm.load() {
		stage.apmConfig = {
			echoCancellation = true,
			noiseSuppression = true,
			noiseLevel       = VOICE_WEBRTC_NOISE_LEVEL,
			highPassFilter   = true,
		}
		stage.apm = webrtcapm.create(stage.apmConfig)
	}
	return stage.denoiser != nil || stage.apm != nil
}

VoiceCaptureStage_close :: proc(stage: ^VoiceCaptureStage) {
	if stage.denoiser != nil {
		rnnoise.destroyDenoiser(stage.denoiser)
	}
	if stage.apm != nil {
		webrtcapm.destroy(stage.apm)
	}
	stage^ = {}
}

// Whether noise suppression can run, by either library.
VoiceCaptureStage_available :: proc(stage: ^VoiceCaptureStage) -> bool {
	return stage.denoiser != nil || stage.apm != nil
}

VoiceCaptureStage_echoAvailable :: proc(stage: ^VoiceCaptureStage) -> bool {
	return stage.apm != nil
}

// Whether RNNoise is there to give the gate a speech probability.
VoiceCaptureStage_hasVAD :: proc(stage: ^VoiceCaptureStage) -> bool {
	return stage.denoiser != nil
}

// The suppressor options would use.
VoiceCaptureStage_noiseBackend :: proc(
	stage: ^VoiceCaptureStage,
	options: VoiceCaptureOptions,
) -> VoiceNoiseBackend {
	if !options.noiseSuppression {
		return .None
	}
	if stage.apm != nil && options.noisePreference == .Auto {
		return .WebRTC
	}
	if stage.denoiser != nil {
		return .RNNoise
	}
	return .None
}

// AEC3's latest statistics (read once a second while it runs).
VoiceCaptureStage_echoStats :: proc(stage: ^VoiceCaptureStage) -> (webrtcapm.Stats, bool) {
	return stage.echoStats, stage.hasEchoStats
}

// Feeds what the engine plays (any whole number of 10 ms frames, ±1 floats, unchanged) as the
// echo reference. Ignored unless echo cancellation ran on the last captured frame, so a
// paused canceller starts from a clean reference after its reset.
VoiceCaptureStage_render :: proc(stage: ^VoiceCaptureStage, played: []f32) -> time.Duration {
	if stage.apm == nil || !stage.renderActive {
		return 0
	}
	assert(len(played) % webrtcapm.FRAME_SIZE == 0, "render frames are 10 ms")
	start := time.tick_now()
	for part in 0 ..< len(played) / webrtcapm.FRAME_SIZE {
		_ = webrtcapm.processRender(
			stage.apm,
			played[part * webrtcapm.FRAME_SIZE:][:webrtcapm.FRAME_SIZE],
		)
	}
	return time.tick_since(start)
}

// Processes one 20 ms frame (±1 floats) in place. With nothing asked for, or nothing loaded,
// the frame is left as it is. RNNoise delays the signal by one of its frames (10 ms); WebRTC
// processes without delay.
VoiceCaptureStage_process :: proc(
	stage: ^VoiceCaptureStage,
	frame: []f32,
	options: VoiceCaptureOptions,
) -> (
	result: VoiceCaptureResult,
) {
	assert(len(frame) == common.VOICE_FRAME_SAMPLES, "capture frames are 20 ms")
	backend := VoiceCaptureStage_noiseBackend(stage, options)
	echo := options.echoCancellation && stage.apm != nil
	if backend == .None && !echo {
		stage.wasDenoising = false
		stage.wasProcessing = false
		stage.renderActive = false
		return
	}
	start := time.tick_now()
	if echo || backend == .WebRTC {
		VoiceCaptureStage_runWebRTC(stage, frame, echo, backend == .WebRTC, options.delayHintMS)
		result.echoCancelled = echo
	} else {
		stage.wasProcessing = false
		stage.renderActive = false
	}
	if backend != .None {
		result.denoised = true
		result.noiseBackend = backend
		// RNNoise suppresses (its own backend) or only listens (behind WebRTC's).
		if stage.denoiser != nil {
			result.speechProbability = VoiceCaptureStage_runRNNoise(
				stage,
				frame,
				backend == .RNNoise,
			)
			result.hasSpeechProbability = true
		}
	} else {
		stage.wasDenoising = false
	}
	result.elapsed = time.tick_since(start)
	return
}

@(private = "file")
VoiceCaptureStage_runWebRTC :: proc(
	stage: ^VoiceCaptureStage,
	frame: []f32,
	echo: bool,
	denoise: bool,
	delayHintMS: int,
) {
	config := stage.apmConfig
	config.echoCancellation = b32(echo)
	config.noiseSuppression = b32(denoise)
	if config != stage.apmConfig {
		_ = webrtcapm.applyConfig(stage.apm, config)
		stage.apmConfig = config
	}
	if !stage.wasProcessing {
		_ = webrtcapm.reset(stage.apm)
		stage.wasProcessing = true
		stage.framesSinceStats = 0
		stage.hasEchoStats = false
	}
	stage.renderActive = echo
	for part in 0 ..< VOICE_CAPTURE_SUBFRAMES {
		samples := frame[part * webrtcapm.FRAME_SIZE:][:webrtcapm.FRAME_SIZE]
		if echo {
			webrtcapm.setStreamDelay(stage.apm, delayHintMS)
		}
		_ = webrtcapm.processCapture(stage.apm, samples)
		for &sample in samples {
			sample = clamp(sample, -1, 1)
		}
	}
	if !echo {
		stage.hasEchoStats = false
		return
	}
	stage.framesSinceStats += 1
	if stage.framesSinceStats >= VOICE_ECHO_STATS_INTERVAL_FRAMES {
		stage.framesSinceStats = 0
		stage.echoStats, stage.hasEchoStats = webrtcapm.stats(stage.apm)
	}
}

// Runs RNNoise over both halves of frame and returns the larger speech probability. With
// suppress it writes the denoised samples back; without, it works on its scratch copy only.
@(private = "file")
VoiceCaptureStage_runRNNoise :: proc(
	stage: ^VoiceCaptureStage,
	frame: []f32,
	suppress: bool,
) -> (
	probability: f32,
) {
	if !stage.wasDenoising {
		_ = rnnoise.resetDenoiser(stage.denoiser)
		stage.wasDenoising = true
	}
	scratch := stage.scratch[:]
	for part in 0 ..< VOICE_CAPTURE_SUBFRAMES {
		samples := frame[part * rnnoise.FRAME_SIZE:][:rnnoise.FRAME_SIZE]
		for sample, index in samples {
			scratch[index] = sample * rnnoise.SAMPLE_SCALE
		}
		probability = max(probability, rnnoise.processFrame(stage.denoiser, scratch))
		if suppress {
			for &sample, index in samples {
				sample = clamp(scratch[index] / rnnoise.SAMPLE_SCALE, -1, 1)
			}
		}
	}
	return
}
