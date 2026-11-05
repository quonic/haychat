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
