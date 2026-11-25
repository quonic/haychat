package voice_check

import "core:testing"

@(test)
testParseOptionsReadsACheck :: proc(t: ^testing.T) {
	options, err := parseOptions(
		{"b.f32", "--freq", "440", "--tolerance", "5", "--min-seconds", "3", "--channels", "2"},
	)
	testing.expectf(t, err == "", "expected no error, got %q", err)
	testing.expectf(
		t,
		options.path == "b.f32" &&
		options.freq == 440 &&
		options.toleranceHz == 5 &&
		options.minSeconds == 3 &&
		options.channels == 2 &&
		options.amplitude == DEFAULT_AMPLITUDE &&
		!options.writeTone,
		"unexpected options %v",
		options,
	)
	options, err = parseOptions({"--write-tone", "in.f32", "--freq", "440", "--seconds", "8"})
	testing.expectf(
		t,
		err == "" && options.writeTone && options.seconds == 8,
		"%v: %q",
		options,
		err,
	)
}

@(test)
testParseOptionsRejectsBadArguments :: proc(t: ^testing.T) {
	bad := [?][]string {
		{},
		{"b.f32"},
		{"--freq", "440"},
		{"a", "b", "--freq", "440"},
		{"b.f32", "--freq", "loud"},
		{"b.f32", "--freq", "30000"},
		{"b.f32", "--freq", "440", "--channels", "1.5"},
		{"b.f32", "--freq", "440", "--amplitude", "2"},
		{"b.f32", "--freq", "440", "--bogus", "1"},
		{"b.f32", "--freq"},
		{"--write-tone", "in.f32", "--freq", "440"},
	}
	for args in bad {
		_, err := parseOptions(args)
		testing.expectf(t, err != "", "expected %v to be rejected", args)
	}
}

// PR #23: the analyser scans only SCAN_MIN_HZ to SCAN_MAX_HZ, so a check outside that band is
// a usage error (exit 2), never a FAIL (exit 1). Writing a tone has no such limit.
@(test)
testParseOptionsLimitsACheckToTheScanRange :: proc(t: ^testing.T) {
	inside := [?]string{"50", "440", "4050"}
	for freq in inside {
		_, err := parseOptions({"b.f32", "--freq", freq})
		testing.expectf(t, err == "", "expected --freq %s to be accepted, got %q", freq, err)
	}
	outside := [?]string{"49.9", "4050.1", "5000", "12000"}
	for freq in outside {
		_, err := parseOptions({"b.f32", "--freq", freq})
		testing.expectf(
			t,
			err == FREQ_RANGE_ERROR,
			"expected --freq %s to be a usage error, got %q",
			freq,
			err,
		)
	}
	options, err := parseOptions({"--write-tone", "in.f32", "--freq", "5000", "--seconds", "1"})
	testing.expectf(
		t,
		err == "" && options.freq == 5000,
		"expected a 5000 Hz tone to be writable, got %q",
		err,
	)
}

// #170: the noisy tone writer and the noise floor limits.
@(test)
testParseOptionsReadsTheNoiseOptions :: proc(t: ^testing.T) {
	options, err := parseOptions(
		{"--write-noisy-tone", "n.f32", "--freq", "440", "--seconds", "30", "--noise-db", "-40"},
	)
	testing.expectf(
		t,
		err == "" &&
		options.writeTone &&
		options.writeNoisyTone &&
		options.noiseDB == -40 &&
		options.burstSeconds == DEFAULT_BURST_SECONDS &&
		options.gapSeconds == DEFAULT_GAP_SECONDS,
		"%v: %q",
		options,
		err,
	)
	options, err = parseOptions(
		{"b.f32", "--freq", "440", "--max-floor", "-60", "--min-floor", "-90"},
	)
	maxFloor, hasMax := options.maxFloor.?
	minFloor, hasMin := options.minFloor.?
	testing.expectf(
		t,
		err == "" && hasMax && maxFloor == -60 && hasMin && minFloor == -90,
		"%v: %q",
		options,
		err,
	)
	plain, _ := parseOptions({"b.f32", "--freq", "440"})
	testing.expect(t, plain.maxFloor == nil && plain.minFloor == nil, "expected no floor limits")
	_, err = parseOptions({"b.f32", "--freq", "440", "--max-floor", "3"})
	testing.expect(t, err != "", "expected a floor above 0 dBFS to be rejected")
	_, err = parseOptions({"--write-noisy-tone", "n.f32", "--freq", "440", "--noise-db", "-40"})
	testing.expect(t, err != "", "expected --write-noisy-tone without --seconds to be rejected")
}

// #171: --tone-level measures the end of a file, with optional limits.
@(test)
testParseOptionsReadsTheToneLevelOptions :: proc(t: ^testing.T) {
	options, err := parseOptions(
		{"x.f32", "--freq", "440", "--tone-level", "5", "--max-level", "-40"},
	)
	maxLevel, hasMax := options.maxLevel.?
	testing.expectf(
		t,
		err == "" &&
		options.toneLevelSeconds == 5 &&
		hasMax &&
		maxLevel == -40 &&
		options.minLevel == nil,
		"%v: %q",
		options,
		err,
	)
	_, err = parseOptions({"x.f32", "--freq", "440", "--tone-level", "0"})
	testing.expect(t, err != "", "expected an empty window to be rejected")
	_, err = parseOptions({"x.f32", "--freq", "440", "--tone-level", "5", "--min-level", "1"})
	testing.expect(t, err != "", "expected a level above 0 dBFS to be rejected")
}
