package client

// Tone analysis for voice tests (voice-rooms-design.md section 6.1): find a test tone's
// frequency and level with Goertzel filters, so CI needs neither sox nor numpy. Only tests
// (and later the live proof's voice-check tool) use it.
//
// Pass criteria: the dominant frequency within ±5 Hz of the target, the target bin at least
// 20 dB above the median bin, and the RMS level within 6 dB of the expected level.

import "core:math"
import "core:slice"

VOICE_TONE_TOLERANCE_HZ :: 5.0
VOICE_TONE_MIN_SNR_DB :: 20.0
VOICE_TONE_RMS_TOLERANCE_DB :: 6.0
// At most half a second at 48 kHz is analysed: a Hann window that long has a main lobe of
// ±4 Hz, so a coarse scan in 4 Hz steps cannot step over a tone.
VOICE_TONE_MAX_SAMPLES :: 24000
// The coarse scan's range and step; the fine scan then searches ±step around the peak.
VOICE_TONE_SCAN_MIN_HZ :: 50.0
VOICE_TONE_SCAN_MAX_HZ :: 4050.0
VOICE_TONE_COARSE_STEP_HZ :: 4.0
VOICE_TONE_FINE_STEP_HZ :: 0.25

VoiceToneAnalysis :: struct {
	dominantHz: f64,
	// Power at the target frequency over the median coarse bin, in dB.
	snrDB:      f64,
	rmsDB:      f64,
}

// goertzelPower is the signal power at frequency hz. Pass samples already windowed with
// voiceHannWindow, so leakage from a strong tone does not drown the neighbouring bins.
goertzelPower :: proc(windowed: []f64, sampleRate: f64, hz: f64) -> f64 {
	n := len(windowed)
	if n == 0 {
		return 0
	}
	coefficient := 2 * math.cos(2 * math.PI * hz / sampleRate)
	s1, s2: f64
	for sample in windowed {
		s0 := sample + coefficient * s1 - s2
		s2 = s1
		s1 = s0
	}
	return (s1 * s1 + s2 * s2 - coefficient * s1 * s2) / f64(n * n)
}

voiceHannWindow :: proc(samples: []f32, allocator := context.temp_allocator) -> []f64 {
	windowed := make([]f64, len(samples), allocator)
	n := len(samples)
	for sample, index in samples {
		weight := n > 1 ? 0.5 - 0.5 * math.cos(2 * math.PI * f64(index) / f64(n - 1)) : 1
		windowed[index] = f64(sample) * weight
	}
	return windowed
}

voicePowerDB :: proc(power: f64) -> f64 {
	return 10 * math.log10(max(power, 1e-20))
}

voiceRMSDB :: proc(samples: []f32) -> f64 {
	if len(samples) == 0 {
		return -200
	}
	sum: f64
	for sample in samples {
		sum += f64(sample) * f64(sample)
	}
	return 10 * math.log10(max(sum / f64(len(samples)), 1e-20))
}

// analyzeVoiceTone measures samples (mono; at most the middle half second is used) against
// targetHz. Allocates only temporary memory.
analyzeVoiceTone :: proc(samples: []f32, sampleRate: f64, targetHz: f64) -> VoiceToneAnalysis {
	middle := samples
	if len(middle) > VOICE_TONE_MAX_SAMPLES {
		start := (len(middle) - VOICE_TONE_MAX_SAMPLES) / 2
		middle = middle[start:][:VOICE_TONE_MAX_SAMPLES]
	}
	window := voiceHannWindow(middle)
	binCount := int((VOICE_TONE_SCAN_MAX_HZ - VOICE_TONE_SCAN_MIN_HZ) / VOICE_TONE_COARSE_STEP_HZ)
	powers := make([]f64, binCount + 1, context.temp_allocator)
	bestHz := f64(VOICE_TONE_SCAN_MIN_HZ)
	bestPower := -1.0
	for index in 0 ..= binCount {
		hz := VOICE_TONE_SCAN_MIN_HZ + f64(index) * VOICE_TONE_COARSE_STEP_HZ
		powers[index] = goertzelPower(window, sampleRate, hz)
		if powers[index] > bestPower {
			bestPower = powers[index]
			bestHz = hz
		}
	}
	coarseHz := bestHz
	for hz := coarseHz - VOICE_TONE_COARSE_STEP_HZ;
	    hz <= coarseHz + VOICE_TONE_COARSE_STEP_HZ;
	    hz += VOICE_TONE_FINE_STEP_HZ {
		power := goertzelPower(window, sampleRate, hz)
		if power > bestPower {
			bestPower = power
			bestHz = hz
		}
	}
	slice.sort(powers)
	median := powers[len(powers) / 2]
	return {
		dominantHz = bestHz,
		snrDB = voicePowerDB(goertzelPower(window, sampleRate, targetHz)) - voicePowerDB(median),
		rmsDB = voiceRMSDB(middle),
	}
}

// voiceToneRMSDB is the RMS level of a sine of the given peak amplitude.
voiceToneRMSDB :: proc(amplitude: f64) -> f64 {
	return 20 * math.log10(amplitude / math.SQRT_TWO)
}

voiceTonePasses :: proc(analysis: VoiceToneAnalysis, targetHz: f64, expectedRMSDB: f64) -> bool {
	return(
		abs(analysis.dominantHz - targetHz) <= VOICE_TONE_TOLERANCE_HZ &&
		analysis.snrDB >= VOICE_TONE_MIN_SNR_DB &&
		abs(analysis.rmsDB - expectedRMSDB) <= VOICE_TONE_RMS_TOLERANCE_DB \
	)
}
