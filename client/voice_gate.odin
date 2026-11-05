package client

// The transmit gate (voice-rooms-design.md section 2.3): mute, push-to-talk and voice
// activity. Pure code, fed one 20 ms frame level at a time, so attack, hangover and the
// push-to-talk tail are unit-tested on synthetic levels.

import "core:math"

VoiceGateMode :: enum u8 {
	VoiceActivity,
	PushToTalk,
}

VOICE_VAD_DEFAULT_THRESHOLD_DB :: f32(-45)
// Frames in a row above the threshold before the gate opens (40 ms).
VOICE_VAD_ATTACK_FRAMES :: 2
// Frames below the threshold still sent after speech, so word endings are not clipped
// (300 ms).
VOICE_VAD_HANGOVER_FRAMES :: 15
// Frames still sent after the push-to-talk key is released (200 ms).
VOICE_PTT_TAIL_FRAMES :: 10
// The level reported for digital silence.
VOICE_LEVEL_FLOOR_DB :: f32(-100)

VoiceGate :: struct {
	open:       bool,
	aboveCount: int,
	belowCount: int,
	tailCount:  int,
}

VoiceGateInput :: struct {
	mode:        VoiceGateMode,
	levelDB:     f32,
	thresholdDB: f32,
	muted:       bool,
	pttHeld:     bool,
}

VoiceGateResult :: struct {
	// Send this frame.
	transmit:   bool,
	// This is the last frame of the talk spurt; it carries common.VOICE_FRAME_FLAG_END_OF_SPURT.
	endOfSpurt: bool,
}

// VoiceGate_update feeds one frame and says whether to send it. Mute closes the gate at
// once without an end-of-spurt frame, because sending even one more frame after the user
// muted would leak audio; receivers end the spurt by timeout instead.
VoiceGate_update :: proc(gate: ^VoiceGate, input: VoiceGateInput) -> VoiceGateResult {
	if input.muted {
		gate^ = {}
		return {}
	}
	switch input.mode {
	case .PushToTalk:
		gate.aboveCount = 0
		gate.belowCount = 0
		if input.pttHeld {
			gate.open = true
			gate.tailCount = 0
			return {transmit = true}
		}
		if !gate.open {
			return {}
		}
		gate.tailCount += 1
		if gate.tailCount >= VOICE_PTT_TAIL_FRAMES {
			gate.open = false
			gate.tailCount = 0
			return {transmit = true, endOfSpurt = true}
		}
		return {transmit = true}
	case .VoiceActivity:
		gate.tailCount = 0
		loud := input.levelDB >= input.thresholdDB
		if !gate.open {
			gate.aboveCount = loud ? gate.aboveCount + 1 : 0
			if gate.aboveCount >= VOICE_VAD_ATTACK_FRAMES {
				gate.open = true
				gate.aboveCount = 0
				gate.belowCount = 0
				return {transmit = true}
			}
			return {}
		}
		if loud {
			gate.belowCount = 0
			return {transmit = true}
		}
		gate.belowCount += 1
		if gate.belowCount >= VOICE_VAD_HANGOVER_FRAMES {
			gate.open = false
			gate.belowCount = 0
			return {transmit = true, endOfSpurt = true}
		}
		return {transmit = true}
	}
	return {}
}

// voiceFrameLevelDB is the frame's RMS level in dBFS, floored at VOICE_LEVEL_FLOOR_DB.
voiceFrameLevelDB :: proc(samples: []f32) -> f32 {
	if len(samples) == 0 {
		return VOICE_LEVEL_FLOOR_DB
	}
	sum: f64
	for sample in samples {
		sum += f64(sample) * f64(sample)
	}
	rms := math.sqrt(sum / f64(len(samples)))
	if rms <= 1e-5 {
		return VOICE_LEVEL_FLOOR_DB
	}
	return max(f32(20 * math.log10(rms)), VOICE_LEVEL_FLOOR_DB)
}
