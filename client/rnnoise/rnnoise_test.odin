package rnnoise

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:testing"

// A library that is not there is reported, not fatal, and leaves nothing loaded.
@(test)
testLoadPathReportsAMissingLibrary :: proc(t: ^testing.T) {
	lib: Library
	assert(!Library_loadPath(&lib, "/nonexistent/librnnoise.so.0"), "expected the load to fail")
	assert(!lib.loaded && lib.symbols.__handle == nil, "expected nothing loaded")
	message := Library_error(&lib)
	assert(
		strings.has_prefix(message, "RNNoise not found (/nonexistent/librnnoise.so.0: "),
		fmt.tprintf("expected the path in the error, got %q", message),
	)
	_ = t
}

// The system library loads, works on 480-sample frames, and denoises white noise. Skipped
// without it unless HAYCHAT_REQUIRE_RNNOISE=1 (check.sh sets it).
@(test)
testDefaultLibraryDenoisesWhiteNoise :: proc(t: ^testing.T) {
	if !load() {
		if os.get_env("HAYCHAT_REQUIRE_RNNOISE", context.temp_allocator) == "1" {
			testing.fail_now(t, fmt.tprintf("RNNoise is required: %s", loadError()))
		}
		log.warnf("skipping: %s", loadError())
		return
	}
	st := createDenoiser()
	assert(st != nil, "expected a denoiser")
	defer destroyDenoiser(st)
	frame: [FRAME_SIZE]f32
	state := u64(1)
	inputPower, outputPower: f64
	maxProbability: f32
	for index in 0 ..< 100 {
		power: f64
		for &sample in frame {
			sample = (f32(nextRandom(&state) >> 40) / f32(1 << 24) * 2 - 1) * 1000
			power += f64(sample) * f64(sample)
		}
		probability := processFrame(st, frame[:])
		if index < 50 {
			continue
		}
		inputPower += power
		for sample in frame {
			outputPower += f64(sample) * f64(sample)
		}
		maxProbability = max(maxProbability, probability)
	}
	assert(
		outputPower * 1000 < inputPower,
		fmt.tprintf("expected 30 dB less noise, got %v of %v", outputPower, inputPower),
	)
	assert(maxProbability < 0.5, fmt.tprintf("expected no speech, got %.2f", maxProbability))
	assert(resetDenoiser(st), "expected the reset to succeed")
}

@(private = "file")
nextRandom :: proc(state: ^u64) -> u64 {
	state^ += 0x9E37_79B9_7F4A_7C15
	z := state^
	z = (z ~ (z >> 30)) * 0xBF58_476D_1CE4_E5B9
	z = (z ~ (z >> 27)) * 0x94D0_49BB_1331_11EB
	return z ~ (z >> 31)
}
