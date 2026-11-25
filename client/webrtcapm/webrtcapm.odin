package webrtcapm

// A binding to HayChat's C wrapper around webrtc-audio-processing 2.x (WebRTC's audio
// processing module: AEC3 echo cancellation, noise suppression, high-pass filter), loaded at
// runtime with core:dynlib, so the client neither links it nor needs it to start: voice works
// without it and the voice settings say why echo cancellation is unavailable (#171). Like
// client/opus and client/rnnoise, this package must not import HayChat types.
//
// The library is C++ only, so HayChat ships a small wrapper with a C API (native/, built by
// deploy/build-linux-webrtc-apm.sh against the system's webrtc-audio-processing-2 and by
// deploy/build-windows-webrtc-apm.sh, which links a pinned source build into the DLL). It
// works on 10 ms frames of 48 kHz mono floats in [-1, 1], render (what is played) and
// capture (the microphone) alike.
//
// The library is looked for in HAYCHAT_WEBRTC_APM_LIBRARY (a path, for tests and dev builds),
// then next to the executable, then by name on the loader's search path.

import "core:dynlib"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"

Processor :: struct {}

// Samples per frame: 10 ms at 48 kHz.
FRAME_SIZE :: 480
SAMPLE_RATE :: 48000
// HAYCHAT_APM_ABI_VERSION in native/haychat_webrtc_apm.h.
ABI_VERSION :: 1

LIBRARY_PATH_ENV :: "HAYCHAT_WEBRTC_APM_LIBRARY"

NoiseLevel :: enum i32 {
	Low      = 0,
	Moderate = 1,
	High     = 2,
	VeryHigh = 3,
}

// HaychatApmConfig.
Config :: struct {
	echoCancellation: b32,
	noiseSuppression: b32,
	noiseLevel:       NoiseLevel,
	highPassFilter:   b32,
}

// HaychatApmStats: AEC3's statistics; each has* says whether the value is set.
Stats :: struct {
	hasEchoReturnLoss:            b32,
	hasEchoReturnLossEnhancement: b32,
	hasDivergentFilterFraction:   b32,
	hasDelayMedian:               b32,
	hasDelay:                     b32,
	hasResidualEchoLikelihood:    b32,
	// ERL and ERLE in dB.
	echoReturnLoss:               f64,
	echoReturnLossEnhancement:    f64,
	divergentFilterFraction:      f64,
	residualEchoLikelihood:       f64,
	delayMedianMS:                i32,
	delayStandardDeviationMS:     i32,
	// AEC3's instantaneous delay estimate.
	delayMS:                      i32,
	reserved:                     i32,
}
#assert(size_of(Stats) == 72)
#assert(size_of(Config) == 16)

// Every symbol the client calls. Field names are the C names without the "haychat_apm_"
// prefix, which is what dynlib.initialize_symbols looks up.
Symbols :: struct {
	abi_version:         proc "c" () -> i32,
	built_version:       proc "c" () -> cstring,
	create:              proc "c" (config: ^Config) -> ^Processor,
	destroy:             proc "c" (apm: ^Processor),
	apply_config:        proc "c" (apm: ^Processor, config: ^Config) -> i32,
	reset:               proc "c" (apm: ^Processor) -> i32,
	process_render:      proc "c" (apm: ^Processor, samples: [^]f32) -> i32,
	process_capture:     proc "c" (apm: ^Processor, samples: [^]f32) -> i32,
	set_stream_delay_ms: proc "c" (apm: ^Processor, delayMS: i32) -> i32,
	get_stats:           proc "c" (apm: ^Processor, stats: ^Stats) -> i32,
	__handle:            dynlib.Library,
}

SYMBOL_NAMES :: [?]string {
	"abi_version",
	"built_version",
	"create",
	"destroy",
	"apply_config",
	"reset",
	"process_render",
	"process_capture",
	"set_stream_delay_ms",
	"get_stats",
}

when ODIN_OS == .Windows {
	LIBRARY_NAMES :: [?]string{"haychat-webrtc-apm.dll"}
	PATH_SEPARATOR :: "\\"
} else when ODIN_OS == .Darwin {
	LIBRARY_NAMES :: [?]string{"libhaychat-webrtc-apm.dylib"}
	PATH_SEPARATOR :: "/"
} else {
	LIBRARY_NAMES :: [?]string{"libhaychat-webrtc-apm.so"}
	PATH_SEPARATOR :: "/"
}

ERROR_BUFFER_SIZE :: 512

// One loaded copy of the wrapper. The error text lives in a fixed buffer so callers can borrow
// it without owning an allocation.
Library :: struct {
	using symbols: Symbols,
	loaded:        bool,
	errorBuffer:   [ERROR_BUFFER_SIZE]u8,
	errorLength:   int,
	versionBuffer: [32]u8,
	versionLength: int,
}

Library_error :: proc(lib: ^Library) -> string {
	return string(lib.errorBuffer[:lib.errorLength])
}

@(private)
Library_setError :: proc(lib: ^Library, format: string, args: ..any) {
	text := fmt.bprintf(lib.errorBuffer[:], format, ..args)
	lib.errorLength = len(text)
}

// Library_loadPath opens one library file and checks that every symbol the client calls is
// present and that its ABI version matches. A library that fails either is unloaded again, so
// a half-filled table is never used. On Linux the wrapper needs the system's
// libwebrtc-audio-processing-2.so.1; when that is missing the loader's error names it.
Library_loadPath :: proc(lib: ^Library, path: string) -> bool {
	if lib.loaded {
		return true
	}
	lib.symbols = {}
	_, ok := dynlib.initialize_symbols(&lib.symbols, path, "haychat_apm_")
	if lib.symbols.__handle == nil {
		Library_setError(
			lib,
			"WebRTC audio processing not found (%s: %s)",
			path,
			dynlib.last_error(),
		)
		return false
	}
	missing := Symbols_firstMissing(&lib.symbols)
	if !ok || missing != "" {
		Library_setError(
			lib,
			"WebRTC audio processing at %s lacks haychat_apm_%s",
			path,
			missing,
		)
		Library_unloadHandle(lib)
		return false
	}
	if abi := lib.abi_version(); abi != ABI_VERSION {
		Library_setError(
			lib,
			"WebRTC audio processing at %s has ABI %d, not %d",
			path,
			abi,
			ABI_VERSION,
		)
		Library_unloadHandle(lib)
		return false
	}
	lib.versionLength = copy(lib.versionBuffer[:], string(lib.built_version()))
	lib.loaded = true
	lib.errorLength = 0
	return true
}

@(private)
Library_unloadHandle :: proc(lib: ^Library) {
	_ = dynlib.unload_library(lib.symbols.__handle)
	lib.symbols = {}
}

// Library_loadDefault tries HAYCHAT_WEBRTC_APM_LIBRARY, then the copy next to the executable
// (the one the release archive ships), then the platform's library name.
Library_loadDefault :: proc(lib: ^Library) -> bool {
	if path := os.get_env(LIBRARY_PATH_ENV, context.temp_allocator); path != "" {
		return Library_loadPath(lib, path)
	}
	firstError: [ERROR_BUFFER_SIZE]u8
	firstErrorLength := 0
	exeDir, dirErr := os.get_executable_directory(context.temp_allocator)
	if dirErr == nil && exeDir != "" {
		for name in LIBRARY_NAMES {
			path := strings.concatenate({exeDir, PATH_SEPARATOR, name}, context.temp_allocator)
			if !os.exists(path) {
				continue
			}
			if Library_loadPath(lib, path) {
				return true
			}
			// A copy that is there but does not load (on Linux: no
			// libwebrtc-audio-processing-2.so.1) explains more than "not found" by name.
			if firstErrorLength == 0 {
				firstErrorLength = copy(firstError[:], Library_error(lib))
			}
		}
	}
	for name in LIBRARY_NAMES {
		if Library_loadPath(lib, name) {
			return true
		}
		if firstErrorLength == 0 {
			firstErrorLength = copy(firstError[:], Library_error(lib))
		}
	}
	lib.errorLength = copy(lib.errorBuffer[:], firstError[:firstErrorLength])
	return false
}

Library_unload :: proc(lib: ^Library) {
	if lib.loaded && lib.symbols.__handle != nil {
		_ = dynlib.unload_library(lib.symbols.__handle)
	}
	lib.symbols = {}
	lib.loaded = false
}

@(private)
Symbols_firstMissing :: proc(symbols: ^Symbols) -> string {
	pointers := [?]rawptr {
		rawptr(symbols.abi_version),
		rawptr(symbols.built_version),
		rawptr(symbols.create),
		rawptr(symbols.destroy),
		rawptr(symbols.apply_config),
		rawptr(symbols.reset),
		rawptr(symbols.process_render),
		rawptr(symbols.process_capture),
		rawptr(symbols.set_stream_delay_ms),
		rawptr(symbols.get_stats),
	}
	#assert(len(pointers) == len(SYMBOL_NAMES))
	names := SYMBOL_NAMES
	for pointer, index in pointers {
		if pointer == nil {
			return names[index]
		}
	}
	return ""
}

// ── Process-wide library ──────────────────────────────────────────

// The wrapper is loaded once per process and never unloaded, because processors may outlive
// any one voice session.
@(private)
defaultLibrary: Library
@(private)
defaultLibraryMutex: sync.Mutex
@(private)
defaultLibraryAttempted: bool

// load opens the wrapper for the whole process. It is safe to call from any thread and as
// often as wanted: only the first call touches the disk, and later calls return its result.
load :: proc() -> bool {
	sync.mutex_lock(&defaultLibraryMutex)
	defer sync.mutex_unlock(&defaultLibraryMutex)
	if !defaultLibraryAttempted {
		defaultLibraryAttempted = true
		_ = Library_loadDefault(&defaultLibrary)
	}
	return defaultLibrary.loaded
}

isLoaded :: proc() -> bool {
	sync.mutex_lock(&defaultLibraryMutex)
	defer sync.mutex_unlock(&defaultLibraryMutex)
	return defaultLibrary.loaded
}

// loadError explains why load failed. Empty when the library is loaded or load was never
// called.
loadError :: proc() -> string {
	sync.mutex_lock(&defaultLibraryMutex)
	defer sync.mutex_unlock(&defaultLibraryMutex)
	return Library_error(&defaultLibrary)
}

// builtVersion is the webrtc-audio-processing version the wrapper was built against, such as
// "2.1"; empty when not loaded.
builtVersion :: proc() -> string {
	sync.mutex_lock(&defaultLibraryMutex)
	defer sync.mutex_unlock(&defaultLibraryMutex)
	return string(defaultLibrary.versionBuffer[:defaultLibrary.versionLength])
}

// ── Processor ─────────────────────────────────────────────────────

// create makes a processor (the C++ library allocates it); free it with destroy. Nil when the
// library is not loaded or creation fails.
create :: proc(config: Config) -> ^Processor {
	if !isLoaded() {
		return nil
	}
	config := config
	return defaultLibrary.create(&config)
}

destroy :: proc(apm: ^Processor) {
	if apm != nil && isLoaded() {
		defaultLibrary.destroy(apm)
	}
}

applyConfig :: proc(apm: ^Processor, config: Config) -> bool {
	config := config
	return defaultLibrary.apply_config(apm, &config) == 0
}

reset :: proc(apm: ^Processor) -> bool {
	return defaultLibrary.reset(apm) == 0
}

// processRender feeds one FRAME_SIZE frame of what is played (unchanged).
processRender :: proc(apm: ^Processor, samples: []f32) -> bool {
	assert(len(samples) == FRAME_SIZE, "WebRTC audio processing frames are FRAME_SIZE samples")
	return defaultLibrary.process_render(apm, raw_data(samples)) == 0
}

// processCapture processes one FRAME_SIZE frame of the microphone in place.
processCapture :: proc(apm: ^Processor, samples: []f32) -> bool {
	assert(len(samples) == FRAME_SIZE, "WebRTC audio processing frames are FRAME_SIZE samples")
	return defaultLibrary.process_capture(apm, raw_data(samples)) == 0
}

// setStreamDelay is the delay hint: milliseconds between a render frame being fed and its
// echo reaching processCapture. AEC3 estimates the delay itself and uses this as a start.
setStreamDelay :: proc(apm: ^Processor, delayMS: int) {
	_ = defaultLibrary.set_stream_delay_ms(apm, i32(clamp(delayMS, 0, 500)))
}

stats :: proc(apm: ^Processor) -> (result: Stats, ok: bool) {
	ok = defaultLibrary.get_stats(apm, &result) == 0
	return
}

