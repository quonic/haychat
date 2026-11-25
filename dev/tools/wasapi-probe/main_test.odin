package wasapi_probe

import "core:fmt"
import "core:mem"
import "core:testing"

@(test)
testParseArgsDefaults :: proc(t: ^testing.T) {
	options, err := parseArgs({})
	assert(err == "", fmt.tprintf("expected no error, got %q", err))
	assert(options.category == .Communications, "expected Communications by default")
	assert(options.autoconvert, "expected AUTOCONVERTPCM by default")
	assert(options.defaultRole == .Console, "expected the console role, as SDL")
	assert(options.seconds == DEFAULT_SECONDS, fmt.tprintf("got %v seconds", options.seconds))
	assert(options.probeSeconds == DEFAULT_PROBE_SECONDS, "expected the default probe length")
	assert(options.echoReference == .Render, "expected SDL's render endpoint as the reference")
}

@(test)
testParseArgsReadsEveryOption :: proc(t: ^testing.T) {
	options, err := parseArgs(
		{
			"--device",
			"Microphone (USB)",
			"--render",
			"{0.0.0.00000000}.{abc}",
			"--category",
			"GameChat",
			"--raw",
			"--no-autoconvert",
			"--seconds",
			"2.5",
			"--probe-seconds",
			"0",
			"--out",
			"mic.f32",
			"--play-tone",
			"440",
			"--tone-amplitude",
			"0.5",
			"--default-role",
			"communications",
			"--echo-reference",
			"windows",
		},
	)
	assert(err == "", fmt.tprintf("expected no error, got %q", err))
	assert(options.device == "Microphone (USB)", fmt.tprintf("got device %q", options.device))
	assert(options.render == "{0.0.0.00000000}.{abc}", "expected the render ID")
	assert(options.category == .GameChat, fmt.tprintf("got %v", options.category))
	assert(options.raw && !options.autoconvert, "expected RAW and no AUTOCONVERTPCM")
	assert(options.seconds == 2.5 && options.probeSeconds == 0, "expected both lengths")
	assert(options.outPath == "mic.f32", "expected the output path")
	assert(options.toneHz == 440 && options.toneAmplitude == 0.5, "expected the tone")
	assert(options.defaultRole == .Communications, "expected the communications role")
	assert(options.echoReference == .Windows, "expected Windows' own echo reference")
}

@(test)
testParseArgsRefusesBadInput :: proc(t: ^testing.T) {
	cases := [][]string {
		{"--category", "loud"},
		{"--seconds", "-1"},
		{"--seconds", "nan"},
		{"--seconds"},
		{"--device"},
		{"--play-tone", "5"},
		{"--tone-amplitude", "2"},
		{"--default-role", "multimedia"},
		{"--echo-reference", "loopback"},
		{"--play-tone", "440", "--seconds", "0"},
		{"--bogus"},
	}
	for args in cases {
		_, err := parseArgs(args)
		assert(err != "", fmt.tprintf("expected %v to be refused", args))
	}
}

@(test)
testEffectKindsMatchTheSDKGUIDs :: proc(t: ^testing.T) {
	aec := Guid{0x6f64adbe, 0x8211, 0x11e2, {0x8c, 0x70, 0x2c, 0x27, 0xd7, 0xf0, 0x01, 0xfa}}
	deep := Guid{0x6f64add0, 0x8211, 0x11e2, {0x8c, 0x70, 0x2c, 0x27, 0xd7, 0xf0, 0x01, 0xfa}}
	assert(
		effectKind(aec) == .AcousticEchoCancellation,
		fmt.tprintf("expected AEC, got %v", effectKind(aec)),
	)
	assert(effectKind(deep) == .DeepNoiseSuppression, "expected deep noise suppression")
	other := aec
	other.data4[7] = 0
	assert(effectKind(other) == .Unknown, "expected a GUID outside the family to be unknown")
	for kind in EffectKind {
		if kind != .Unknown {
			assert(effectKind(effectKindGuid(kind)) == kind, fmt.tprintf("round trip of %v", kind))
		}
	}
	text := formatGuid(aec)
	assert(
		text == "{6f64adbe-8211-11e2-8c70-2c27d7f001fa}",
		fmt.tprintf("expected the registry form, got %s", text),
	)
}

@(test)
testProcessingAdviceNeverDoublesUp :: proc(t: ^testing.T) {
	effects := []Effect {
		{id = effectKindGuid(.AcousticEchoCancellation), on = true},
		{id = effectKindGuid(.DeepNoiseSuppression), on = true},
		{id = effectKindGuid(.AutomaticGainControl), on = false, canSetState = true},
	}
	advice := processingAdvice(effects, true)
	assert(advice.osEchoCanceller && !advice.runInAppEchoCanceller, "expected the OS AEC alone")
	assert(
		advice.osNoiseSuppressor && !advice.runInAppNoiseSuppressor,
		"expected deep noise suppression to count as noise suppression",
	)
	assert(
		!advice.osGainControl && advice.runInAppGainControl,
		"expected an effect that is off to leave the job to the app",
	)
	unknown := processingAdvice(effects, false)
	assert(
		!unknown.known && !unknown.runInAppEchoCanceller && !unknown.runInAppNoiseSuppressor,
		"expected no advice when the stream cannot list its effects",
	)
	text := processingAdviceText(advice)
	assert(
		text == "Windows does AEC yes, NS yes, AGC no; in-app AEC no, NS no, AGC yes",
		fmt.tprintf("got %q", text),
	)
	none := processingAdvice({}, true)
	assert(
		none.runInAppEchoCanceller && none.runInAppNoiseSuppressor,
		"expected the app to process a stream without effects",
	)
}

@(test)
testDownmixToMono :: proc(t: ^testing.T) {
	stereoFloat := []f32{0.5, -0.5, 1, 0, -1, -0.5}
	mono: [4]f32
	count := downmixToMono(mono[:], mem.slice_to_bytes(stereoFloat), 3, 2, .Float32)
	assert(count == 3, fmt.tprintf("expected 3 frames, got %d", count))
	assert(
		mono[0] == 0 && mono[1] == 0.5 && mono[2] == -0.75,
		fmt.tprintf("expected the channel means, got %v", mono[:3]),
	)

	pcm16 := []i16{16384, -32768}
	count = downmixToMono(mono[:], mem.slice_to_bytes(pcm16), 2, 1, .Int16)
	assert(count == 2 && mono[0] == 0.5 && mono[1] == -1, fmt.tprintf("got %v", mono[:2]))

	pcm32 := []i32{1 << 30}
	count = downmixToMono(mono[:], mem.slice_to_bytes(pcm32), 1, 1, .Int32)
	assert(count == 1 && mono[0] == 0.5, fmt.tprintf("got %v", mono[0]))

	count = downmixToMono(mono[:], mem.slice_to_bytes(stereoFloat), 10, 2, .Float32)
	assert(count == 3, fmt.tprintf("expected a short source to bound the count, got %d", count))
	assert(downmixToMono(mono[:], {}, 1, 1, .Unsupported) == 0, "expected nothing unsupported")
}

@(test)
testCaptureStatsAndNames :: proc(t: ^testing.T) {
	stats: CaptureStats
	captureStatsAddPacket(&stats, 480, AUDCLNT_BUFFERFLAGS_SILENT)
	captureStatsAddPacket(
		&stats,
		480,
		AUDCLNT_BUFFERFLAGS_DATA_DISCONTINUITY | AUDCLNT_BUFFERFLAGS_TIMESTAMP_ERROR,
	)
	captureStatsAddLevels(&stats, {0.5, -1})
	assert(stats.packets == 2 && stats.frames == 960, fmt.tprintf("got %v", stats))
	assert(stats.silentPackets == 1 && stats.discontinuities == 1, "expected the flags counted")
	assert(stats.timestampErrors == 1 && stats.peak == 1, "expected the peak and errors")
	summary := captureStatsSummary(stats, SAMPLE_RATE, 0.02)
	assert(len(summary) > 0, "expected a summary")
	assert(dbfs(0) == -200 && dbfs(1) == 0, "expected silence and full scale")

	assert(hresultName(0x88890004) == "AUDCLNT_E_DEVICE_INVALIDATED", "expected the name")
	assert(
		formatHresult(0x80004002) == "0x80004002 E_NOINTERFACE",
		fmt.tprintf("got %s", formatHresult(0x80004002)),
	)
	assert(formatHresult(0x12345678) == "0x12345678", "expected hex for an unknown code")
	category, known := streamCategoryFromName("COMMUNICATIONS")
	assert(known && category == .Communications && u32(category) == 3, "AudioCategory 3")
}
