package toneanalysis

// Tone analysis for the voice tests and the live voice proof (voice-rooms-design.md 6.1 and
// 6.2): find a test tone's frequency and level with Goertzel filters, so CI needs neither sox
// nor numpy. The client's tests use it through client/voice_analysis.odin, and
// dev/tools/voice-check uses it on recordings. Like client/opus it knows no HayChat types.
//
// Pass criteria: the dominant frequency within ±5 Hz of the target, the target bin at least
// 20 dB above the median bin, and the RMS level within 6 dB of the expected level.

import "core:math"
import "core:slice"

TOLERANCE_HZ :: 5.0
MIN_SNR_DB :: 20.0
RMS_TOLERANCE_DB :: 6.0
// At most half a second at 48 kHz is analysed: a Hann window that long has a main lobe of
// ±4 Hz, so a coarse scan in 4 Hz steps cannot step over a tone.
MAX_SAMPLES :: 24000
// The coarse scan's range and step; the fine scan then searches ±step around the peak.
SCAN_MIN_HZ :: 50.0
SCAN_MAX_HZ :: 4050.0
COARSE_STEP_HZ :: 4.0
FINE_STEP_HZ :: 0.25
// Levels below this count as no signal at all.
LEVEL_FLOOR_DB :: -200.0

ToneAnalysis :: struct {
	dominantHz: f64,
	// Power at the target frequency over the median coarse bin, in dB.
	snrDB:      f64,
	rmsDB:      f64,
}

// goertzelPower is the signal power at frequency hz. Pass samples already windowed with
// hannWindow, so leakage from a strong tone does not drown the neighbouring bins.
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

hannWindow :: proc(samples: []f32, allocator := context.temp_allocator) -> []f64 {
	windowed := make([]f64, len(samples), allocator)
	n := len(samples)
	for sample, index in samples {
		weight := n > 1 ? 0.5 - 0.5 * math.cos(2 * math.PI * f64(index) / f64(n - 1)) : 1
		windowed[index] = f64(sample) * weight
	}
	return windowed
}

powerDB :: proc(power: f64) -> f64 {
	return 10 * math.log10(max(power, 1e-20))
}

rmsDB :: proc(samples: []f32) -> f64 {
	if len(samples) == 0 {
		return LEVEL_FLOOR_DB
	}
	sum: f64
	for sample in samples {
		sum += f64(sample) * f64(sample)
	}
	return 10 * math.log10(max(sum / f64(len(samples)), 1e-20))
}

// analyze measures samples (mono; at most the middle half second is used) against targetHz.
// Allocates only temporary memory.
analyze :: proc(samples: []f32, sampleRate: f64, targetHz: f64) -> ToneAnalysis {
	middle := samples
	if len(middle) > MAX_SAMPLES {
		start := (len(middle) - MAX_SAMPLES) / 2
		middle = middle[start:][:MAX_SAMPLES]
	}
	window := hannWindow(middle)
	binCount := int((SCAN_MAX_HZ - SCAN_MIN_HZ) / COARSE_STEP_HZ)
	powers := make([]f64, binCount + 1, context.temp_allocator)
	bestHz := f64(SCAN_MIN_HZ)
	bestPower := -1.0
	for index in 0 ..= binCount {
		hz := SCAN_MIN_HZ + f64(index) * COARSE_STEP_HZ
		powers[index] = goertzelPower(window, sampleRate, hz)
		if powers[index] > bestPower {
			bestPower = powers[index]
			bestHz = hz
		}
	}
	coarseHz := bestHz
	for hz := coarseHz - COARSE_STEP_HZ; hz <= coarseHz + COARSE_STEP_HZ; hz += FINE_STEP_HZ {
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
		snrDB = powerDB(goertzelPower(window, sampleRate, targetHz)) - powerDB(median),
		rmsDB = rmsDB(middle),
	}
}

// sineRMSDB is the RMS level of a sine of the given peak amplitude.
sineRMSDB :: proc(amplitude: f64) -> f64 {
	return 20 * math.log10(amplitude / math.SQRT_TWO)
}

Criteria :: struct {
	targetHz:       f64,
	expectedRMSDB:  f64,
	// Zero values mean TOLERANCE_HZ, MIN_SNR_DB and RMS_TOLERANCE_DB.
	toleranceHz:    f64,
	minSNRDB:       f64,
	rmsToleranceDB: f64,
}

@(private = "file")
Criteria_withDefaults :: proc(criteria: Criteria) -> Criteria {
	result := criteria
	if result.toleranceHz == 0 {
		result.toleranceHz = TOLERANCE_HZ
	}
	if result.minSNRDB == 0 {
		result.minSNRDB = MIN_SNR_DB
	}
	if result.rmsToleranceDB == 0 {
		result.rmsToleranceDB = RMS_TOLERANCE_DB
	}
	return result
}

passes :: proc(analysis: ToneAnalysis, criteria: Criteria) -> bool {
	limits := Criteria_withDefaults(criteria)
	return(
		abs(analysis.dominantHz - limits.targetHz) <= limits.toleranceHz &&
		analysis.snrDB >= limits.minSNRDB &&
		abs(analysis.rmsDB - limits.expectedRMSDB) <= limits.rmsToleranceDB \
	)
}

// ── Recordings ────────────────────────────────────────────────────

// How far below the expected level a 20 ms block may be and still count as tone, so a
// recording's silent stretches (before the speaker joined, after it left) are told apart from
// the tone without knowing where it starts.
ACTIVE_BELOW_EXPECTED_DB :: 20.0
// Trimmed from each end of the tone before measuring, so the codec's onset and the fade of
// a spurt's end do not count against it.
EDGE_TRIM_SECONDS :: 0.1
// The block the activity detector works in: one voice frame.
BLOCK_SECONDS :: 0.02

RecordingCheck :: struct {
	totalSeconds:  f64,
	// The longest stretch of blocks at a tone-like level, and how many separate stretches
	// there were (more than one means a dropout somewhere).
	toneSeconds:   f64,
	toneStart:     f64,
	runs:          int,
	windows:       int,
	// Medians over the analysis windows, and the worst window for each criterion.
	dominantHz:    f64,
	worstOffsetHz: f64,
	snrDB:         f64,
	worstSNRDB:    f64,
	// Over the whole trimmed tone.
	rmsDB:         f64,
	passed:        bool,
	// A static reason when passed is false.
	failure:       string,
}

// checkRecording finds the longest stretch of tone in samples (mono) and checks it against
// criteria in half-second windows: every window must have its dominant frequency within the
// tolerance and an SNR above the minimum, the trimmed tone's RMS must be within the level
// tolerance, and the stretch must last at least minSeconds. Allocates only temporary memory.
checkRecording :: proc(
	samples: []f32,
	sampleRate: f64,
	criteria: Criteria,
	minSeconds: f64,
) -> RecordingCheck {
	limits := Criteria_withDefaults(criteria)
	result := RecordingCheck {
		totalSeconds = f64(len(samples)) / sampleRate,
	}
	block := max(int(sampleRate * BLOCK_SECONDS), 1)
	activeLevel := limits.expectedRMSDB - ACTIVE_BELOW_EXPECTED_DB
	bestStart, bestLength := 0, 0
	runStart, runLength := 0, 0
	for start := 0; start + block <= len(samples); start += block {
		if rmsDB(samples[start:][:block]) >= activeLevel {
			if runLength == 0 {
				runStart = start
				result.runs += 1
			}
			runLength += block
			if runLength > bestLength {
				bestStart, bestLength = runStart, runLength
			}
		} else {
			runLength = 0
		}
	}
	result.toneSeconds = f64(bestLength) / sampleRate
	result.toneStart = f64(bestStart) / sampleRate
	if bestLength == 0 {
		result.rmsDB = rmsDB(samples)
		result.failure = "no tone at the expected level"
		return result
	}

	trim := int(sampleRate * EDGE_TRIM_SECONDS)
	tone := samples[bestStart:][:bestLength]
	if len(tone) > 2 * trim + MAX_SAMPLES {
		tone = tone[trim:len(tone) - trim]
	}
	result.rmsDB = rmsDB(tone)
	windowCount := max(len(tone) / MAX_SAMPLES, 1)
	frequencies := make([]f64, windowCount, context.temp_allocator)
	snrs := make([]f64, windowCount, context.temp_allocator)
	result.worstSNRDB = math.F64_MAX
	for index in 0 ..< windowCount {
		window := tone[index * MAX_SAMPLES:]
		window = window[:min(len(window), MAX_SAMPLES)]
		analysis := analyze(window, sampleRate, limits.targetHz)
		frequencies[index] = analysis.dominantHz
		snrs[index] = analysis.snrDB
		offset := analysis.dominantHz - limits.targetHz
		if abs(offset) > abs(result.worstOffsetHz) {
			result.worstOffsetHz = offset
		}
		result.worstSNRDB = min(result.worstSNRDB, analysis.snrDB)
	}
	result.windows = windowCount
	slice.sort(frequencies)
	slice.sort(snrs)
	result.dominantHz = frequencies[windowCount / 2]
	result.snrDB = snrs[windowCount / 2]

	switch {
	case result.toneSeconds < minSeconds:
		result.failure = "the tone is shorter than the minimum"
	case abs(result.worstOffsetHz) > limits.toleranceHz:
		result.failure = "the dominant frequency is off target"
	case result.worstSNRDB < limits.minSNRDB:
		result.failure = "the tone is not far enough above the noise"
	case abs(result.rmsDB - limits.expectedRMSDB) > limits.rmsToleranceDB:
		result.failure = "the level is off the expected level"
	case:
		result.passed = true
	}
	return result
}

// writeTone fills samples with a sine of the given frequency and peak amplitude.
writeTone :: proc(samples: []f32, sampleRate, hz, amplitude: f64) {
	step := 2 * math.PI * hz / sampleRate
	for &sample, index in samples {
		sample = f32(amplitude * math.sin(step * f64(index)))
	}
}
