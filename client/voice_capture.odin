package client

// The capture-processing stage (#170): the one step between capture (after the input gain) and
// the level meter, the gate and the encoder. Today it is RNNoise noise suppression, loaded at
// runtime (client/rnnoise); an echo canceller (#171) is meant to replace or extend this stage
// rather than add a second one, so everything the voice thread does to the microphone signal
// stays in VoiceCaptureStage_process.
//
// The stage belongs to the voice thread: VoiceEngine_open opens it, VoiceEngine_close closes
// it, and nothing in it allocates per frame (RNNoise's state is created once, in open, with
// RNNoise's own malloc). Whether it runs is the engine's atomic noiseSuppression control, read
// once per frame; turning it back on resets RNNoise so audio from before the pause does not
// shape the first frames after it.

import "../common"
import "core:time"
import "rnnoise"

// RNNoise's 10 ms frames: two per 20 ms Opus frame.
VOICE_CAPTURE_SUBFRAMES :: common.VOICE_FRAME_SAMPLES / rnnoise.FRAME_SIZE
#assert(VOICE_CAPTURE_SUBFRAMES * rnnoise.FRAME_SIZE == common.VOICE_FRAME_SAMPLES)

// The speech probability at or above which a frame counts as speech for the voice activity
// gate while noise suppression runs (VoiceGateInput.speechProbability). RNNoise 0.2 gives a
// steady tone or speech 0.9 to 1, and white noise at −26 to −40 dBFS at most 0.02 to 0.2
// (dev numbers in #170's pull request), so 0.5 leaves room on both sides.
VOICE_VAD_SPEECH_PROBABILITY :: f32(0.5)

// What the stage does now, for the settings screen and voice-stats.
VoiceNoiseSuppressionStatus :: enum u8 {
	// Turned off in the settings (or the engine is not open).
	Off,
	// RNNoise processes every captured frame.
	Active,
	// Turned on, but RNNoise could not be loaded or created: frames pass through unchanged and
	// the level gate decides alone.
	Unavailable,
}

VoiceCaptureStage :: struct {
	denoiser:     ^rnnoise.DenoiseState,
	// Whether the last frame was denoised, so a frame after a pause can reset RNNoise first.
	wasDenoising: bool,
	scratch:      [rnnoise.FRAME_SIZE]f32,
}

VoiceCaptureResult :: struct {
	denoised:          bool,
	// The frame's speech probability (the larger of its two RNNoise frames); only meaningful
	// when denoised is set.
	speechProbability: f32,
	// How long processing took, for the CPU counters.
	elapsed:           time.Duration,
}

// Loads RNNoise and creates its state. Returns false, with the stage passing frames through,
// when the library is missing or creation fails; rnnoise.loadError says why for the former.
VoiceCaptureStage_open :: proc(stage: ^VoiceCaptureStage) -> bool {
	VoiceCaptureStage_close(stage)
	if !rnnoise.load() {
		return false
	}
	stage.denoiser = rnnoise.createDenoiser()
	return stage.denoiser != nil
}

VoiceCaptureStage_close :: proc(stage: ^VoiceCaptureStage) {
	if stage.denoiser != nil {
		rnnoise.destroyDenoiser(stage.denoiser)
	}
	stage^ = {}
}

VoiceCaptureStage_available :: proc(stage: ^VoiceCaptureStage) -> bool {
	return stage.denoiser != nil
}

// Processes one 20 ms frame (±1 floats) in place. With denoise unset, or without RNNoise, the
// frame is left as it is. RNNoise delays the signal by one of its frames (10 ms).
VoiceCaptureStage_process :: proc(
	stage: ^VoiceCaptureStage,
	frame: []f32,
	denoise: bool,
) -> (
	result: VoiceCaptureResult,
) {
	assert(len(frame) == common.VOICE_FRAME_SAMPLES, "capture frames are 20 ms")
	if !denoise || stage.denoiser == nil {
		stage.wasDenoising = false
		return
	}
	start := time.tick_now()
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
		probability := rnnoise.processFrame(stage.denoiser, scratch)
		result.speechProbability = max(result.speechProbability, probability)
		for &sample, index in samples {
			sample = clamp(scratch[index] / rnnoise.SAMPLE_SCALE, -1, 1)
		}
	}
	result.denoised = true
	result.elapsed = time.tick_since(start)
	return
}
