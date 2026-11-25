package webrtcapm

import "core:fmt"
import "core:log"
import "core:math"
import "core:os"
import "core:strings"
import "core:testing"

// A library that is not there is reported, not fatal, and leaves nothing loaded.
@(test)
testLoadPathReportsAMissingLibrary :: proc(t: ^testing.T) {
	lib: Library
	path := "/nonexistent/libhaychat-webrtc-apm.so"
	assert(!Library_loadPath(&lib, path), "expected the load to fail")
	assert(!lib.loaded && lib.symbols.__handle == nil, "expected nothing loaded")
	message := Library_error(&lib)
	assert(
		strings.has_prefix(message, "WebRTC audio processing not found (/nonexistent/"),
		fmt.tprintf("expected the path in the error, got %q", message),
	)
	_ = t
}

// The wrapper loads (HAYCHAT_WEBRTC_APM_LIBRARY, set by check.sh), reports its ABI and build,
// takes render and capture frames, and cancels a plain delayed copy of the render signal.
// Skipped without it unless HAYCHAT_REQUIRE_WEBRTC_APM=1 (check.sh sets it).
@(test)
testDefaultLibraryCancelsADelayedCopy :: proc(t: ^testing.T) {
	if !load() {
		if os.get_env("HAYCHAT_REQUIRE_WEBRTC_APM", context.temp_allocator) == "1" {
			testing.fail_now(
				t,
				fmt.tprintf("WebRTC audio processing is required: %s", loadError()),
			)
		}
		log.warnf("skipping: %s", loadError())
		return
	}
	assert(len(builtVersion()) > 0, "expected the built-against version")
	apm := create({echoCancellation = true, noiseLevel = .High, highPassFilter = true})
	assert(apm != nil, "expected a processor")
	defer destroy(apm)
	// Low-passed noise as the far end (AEC3 cancels linearly below 8 kHz and only suppresses
	// above, like a phone call); its copy 60 ms (6 frames) later as the echo, at -6 dB.
	DELAY_FRAMES :: 6
	FRAMES :: 600
	history: [DELAY_FRAMES + 1][FRAME_SIZE]f32
	state := u64(171)
	low, lower: f32
	echoPower, outputPower: f64
	for frame in 0 ..< FRAMES {
		render := &history[frame % len(history)]
		for &sample in render {
			state = state * 6364136223846793005 + 1442695040888963407
			white := f32(state >> 40) / f32(1 << 24) * 2 - 1
			low += 0.2 * (white - low)
			lower += 0.2 * (low - lower)
			sample = lower * 0.5
		}
		assert(processRender(apm, render[:]), "expected the render frame taken")
		capture: [FRAME_SIZE]f32
		if frame >= DELAY_FRAMES {
			echo := &history[(frame - DELAY_FRAMES) % len(history)]
			for &sample, index in capture {
				sample = 0.5 * echo[index]
			}
		}
		if frame >= FRAMES / 2 {
			for sample in capture {
				echoPower += f64(sample) * f64(sample)
			}
		}
		assert(processCapture(apm, capture[:]), "expected the capture frame processed")
		if frame >= FRAMES / 2 {
			for sample in capture {
				outputPower += f64(sample) * f64(sample)
			}
		}
	}
	erle := 10 * math.log10(echoPower / max(outputPower, 1e-20))
	_, statsOK := stats(apm)
	log.infof("ERLE %.1f dB on steady noise", erle)
	assert(statsOK, "expected statistics")
	// A smoke test of the binding; client/voice_echo_test.odin measures AEC3 properly.
	assert(erle > 10, fmt.tprintf("expected 10 dB of ERLE on a plain copy, got %.1f", erle))
}
