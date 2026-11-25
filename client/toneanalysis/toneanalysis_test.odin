package toneanalysis

import "core:fmt"
import "core:math"
import "core:testing"

TEST_RATE :: 48000.0

// Silence, then seconds of a 0.5 sine at hz, then silence: the shape of a voice-sink file.
@(private = "file")
testRecording :: proc(lead, seconds, tail: f64, hz: f64) -> []f32 {
	leadSamples := int(lead * TEST_RATE)
	toneSamples := int(seconds * TEST_RATE)
	samples := make([]f32, leadSamples + toneSamples + int(tail * TEST_RATE))
	writeTone(samples[leadSamples:][:toneSamples], TEST_RATE, hz, 0.5)
	return samples
}

@(test)
testCheckRecordingPassesATonePaddedWithSilence :: proc(t: ^testing.T) {
	samples := testRecording(1.3, 3.2, 0.7, 440)
	defer delete(samples)
	check := checkRecording(samples, TEST_RATE, {targetHz = 440, expectedRMSDB = sineRMSDB(0.5)}, 3)
	testing.expectf(t, check.passed, "expected the tone to pass, got %v", check)
	testing.expectf(t, abs(check.toneSeconds - 3.2) < 0.03, "expected 3.2 s of tone, got %v", check)
	testing.expectf(t, abs(check.toneStart - 1.3) < 0.03, "expected it at 1.3 s, got %v", check)
	testing.expectf(t, check.runs == 1 && check.windows >= 5, "expected one run, got %v", check)
	testing.expectf(t, abs(check.dominantHz - 440) <= 0.5, "expected 440 Hz, got %v", check)
	testing.expectf(t, abs(check.rmsDB - sineRMSDB(0.5)) < 0.2, "expected -9 dBFS, got %v", check)
	testing.expectf(t, check.snrDB > 40, "expected a clean tone, got %v", check)
}

@(test)
testCheckRecordingRejectsWrongToneShortToneAndSilence :: proc(t: ^testing.T) {
	criteria := Criteria {
		targetHz      = 440,
		expectedRMSDB = sineRMSDB(0.5),
	}
	wrong := testRecording(0.5, 3, 0.5, 470)
	defer delete(wrong)
	check := checkRecording(wrong, TEST_RATE, criteria, 2)
	testing.expectf(t, !check.passed && abs(check.worstOffsetHz - 30) < 1, "470 Hz: %v", check)

	short := testRecording(0.5, 1, 0.5, 440)
	defer delete(short)
	check = checkRecording(short, TEST_RATE, criteria, 2)
	testing.expectf(t, !check.passed && check.failure == "the tone is shorter than the minimum",
		"expected 1 s to be too short for 2 s, got %v", check)

	silence := make([]f32, int(TEST_RATE))
	defer delete(silence)
	check = checkRecording(silence, TEST_RATE, criteria, 1)
	testing.expectf(t, !check.passed && check.toneSeconds == 0, "silence: %v", check)

	// The right tone at a quarter of the level is 12 dB too quiet.
	quiet := testRecording(0.2, 2, 0.2, 440)
	defer delete(quiet)
	for &sample in quiet {
		sample *= 0.25
	}
	check = checkRecording(quiet, TEST_RATE, criteria, 1)
	testing.expectf(t, !check.passed && check.failure == "the level is off the expected level",
		"expected a quiet tone to fail the level check, got %v", check)
}

@(test)
testCheckRecordingFindsTheLongestRunAcrossADropout :: proc(t: ^testing.T) {
	samples := testRecording(0.2, 4, 0.2, 440)
	defer delete(samples)
	// 100 ms of silence a second into the tone.
	gap := samples[int(1.2 * TEST_RATE):][:int(0.1 * TEST_RATE)]
	for &sample in gap {
		sample = 0
	}
	check := checkRecording(samples, TEST_RATE, {targetHz = 440, expectedRMSDB = sineRMSDB(0.5)}, 2)
	testing.expectf(t, check.runs == 2, "expected two runs, got %v", check)
	testing.expect(
		t,
		abs(check.toneSeconds - 2.9) < 0.05,
		fmt.tprintf("expected the 2.9 s after the gap, got %v", check),
	)
	testing.expectf(t, check.passed, "expected the longer run to pass, got %v", check)
}

@(test)
testAnalyzeFindsTheToneAndItsLevel :: proc(t: ^testing.T) {
	samples := make([]f32, int(TEST_RATE))
	defer delete(samples)
	writeTone(samples, TEST_RATE, 1000, 0.25)
	analysis := analyze(samples, TEST_RATE, 1000)
	testing.expectf(t, abs(analysis.dominantHz - 1000) <= 0.5, "expected 1000 Hz, got %v", analysis)
	testing.expectf(t, abs(analysis.rmsDB - sineRMSDB(0.25)) < 0.1, "expected -15 dB: %v", analysis)
	testing.expect(
		t,
		passes(analysis, {targetHz = 1000, expectedRMSDB = sineRMSDB(0.25)}),
		"expected the tone to pass",
	)
	testing.expect(
		t,
		!passes(analysis, {targetHz = 1000, expectedRMSDB = sineRMSDB(0.25) + 7}),
		"expected a level 7 dB off to fail",
	)
	testing.expect(t, math.abs(rmsDB(nil) - LEVEL_FLOOR_DB) < 1e-9, "expected the level floor")
}

@(test)
testNoisyToneHasItsNoiseLevelInTheGaps :: proc(t: ^testing.T) {
	fixture := NoisyTone {
		hz           = 440,
		amplitude    = 0.5,
		noiseRMSDB   = -34,
		burstSeconds = 1.5,
		gapSeconds   = 1,
		seed         = 7,
	}
	samples := make([]f32, int(6 * TEST_RATE))
	defer delete(samples)
	writeNoisyTone(samples, TEST_RATE, fixture)
	gap := samples[int(1.7 * TEST_RATE):int(2.3 * TEST_RATE)]
	assert(abs(rmsDB(gap) - -34) < 0.5, fmt.tprintf("expected -34 dBFS gaps, got %.2f", rmsDB(gap)))
	again := make([]f32, len(samples))
	defer delete(again)
	writeNoisyTone(again, TEST_RATE, fixture)
	for sample, index in samples {
		assert(sample == again[index], "expected the same fixture from the same seed")
	}
	check := checkRecording(
		samples,
		TEST_RATE,
		{targetHz = 440, expectedRMSDB = sineRMSDB(0.5)},
		1,
	)
	assert(check.passed, fmt.tprintf("expected the bursts to pass as tone, got %v", check))

	// The floor is the gaps' noise, with silence around the recording left out.
	padded := make([]f32, len(samples) + int(2 * TEST_RATE))
	defer delete(padded)
	copy(padded[int(TEST_RATE):], samples)
	floor, blocks := noiseFloorDB(padded, TEST_RATE, sineRMSDB(0.5) - ACTIVE_BELOW_EXPECTED_DB)
	free_all(context.temp_allocator)
	assert(abs(floor - -34) < 1, fmt.tprintf("expected a -34 dBFS floor, got %.2f", floor))
	assert(blocks >= 250 && blocks <= 300, fmt.tprintf("expected about 5.5 s, got %d", blocks))
	silent, none := noiseFloorDB(padded[:int(TEST_RATE)], TEST_RATE, -29)
	assert(none == 0 && silent == LEVEL_FLOOR_DB, "expected no floor without a loud block")
}
