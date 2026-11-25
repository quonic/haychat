package rnnoise

// A small RNNoise binding loaded at runtime with core:dynlib, so the client neither links
// RNNoise nor needs it to start: voice works without it and the voice settings say why noise
// suppression is unavailable. Like client/opus, this package must not import HayChat types.
//
// RNNoise 0.2 (BSD-3-Clause, with its default model compiled in) denoises 480-sample frames of
// 48 kHz mono audio in the range of 16-bit samples (±32768, not ±1) and returns the frame's
// speech probability. Linux distributions ship only the versioned runtime name
// (librnnoise.so.0) outside their -devel packages, and the Windows release carries an
// rnnoise.dll built by deploy/release-artifacts.sh, which is why the library is opened by name.

import "core:c"
import "core:dynlib"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"

// Used only on Windows, to look next to the executable first.
_ :: os
_ :: strings

DenoiseState :: struct {}
Model :: struct {}

// Samples per frame: 10 ms at 48 kHz. RNNoise has no other frame size.
FRAME_SIZE :: 480
// RNNoise works on floats in the range of 16-bit samples.
SAMPLE_SCALE :: f32(32768)

// Every symbol the client calls. Field names are the C names without the "rnnoise_" prefix,
// which is what dynlib.initialize_symbols looks up.
Symbols :: struct {
	get_size:       proc "c" () -> c.int,
	get_frame_size: proc "c" () -> c.int,
	// Resets st to its first-frame state. With a nil model it uses the built-in model and
	// allocates nothing.
	init:           proc "c" (st: ^DenoiseState, model: ^Model) -> c.int,
	create:         proc "c" (model: ^Model) -> ^DenoiseState,
	destroy:        proc "c" (st: ^DenoiseState),
	// Denoises one FRAME_SIZE frame from in to out (they may be the same buffer) and returns
	// the speech probability of the frame, 0..1.
	process_frame:  proc "c" (st: ^DenoiseState, out: [^]f32, input: [^]f32) -> f32,
	__handle:       dynlib.Library,
}

SYMBOL_NAMES :: [?]string {
	"get_size",
	"get_frame_size",
	"init",
	"create",
	"destroy",
	"process_frame",
}

when ODIN_OS == .Windows {
	LIBRARY_NAMES :: [?]string{"rnnoise.dll", "librnnoise-0.dll"}
} else when ODIN_OS == .Darwin {
	LIBRARY_NAMES :: [?]string{"librnnoise.0.dylib", "librnnoise.dylib"}
} else {
	LIBRARY_NAMES :: [?]string{"librnnoise.so.0"}
}

ERROR_BUFFER_SIZE :: 512

// One loaded copy of RNNoise. The error text lives in a fixed buffer so callers can borrow it
// without owning an allocation.
Library :: struct {
	using symbols: Symbols,
	loaded:        bool,
	errorBuffer:   [ERROR_BUFFER_SIZE]u8,
	errorLength:   int,
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
// present and that it works on FRAME_SIZE frames. A library that fails either is unloaded
// again, so a half-filled table is never used.
Library_loadPath :: proc(lib: ^Library, path: string) -> bool {
	if lib.loaded {
		return true
	}
	lib.symbols = {}
	_, ok := dynlib.initialize_symbols(&lib.symbols, path, "rnnoise_")
	if lib.symbols.__handle == nil {
		Library_setError(lib, "RNNoise not found (%s: %s)", path, dynlib.last_error())
		return false
	}
	missing := Symbols_firstMissing(&lib.symbols)
	if !ok || missing != "" {
		Library_setError(lib, "RNNoise at %s lacks rnnoise_%s", path, missing)
		Library_unloadHandle(lib)
		return false
	}
	if frameSize := lib.get_frame_size(); frameSize != FRAME_SIZE {
		Library_setError(
			lib,
			"RNNoise at %s uses %d-sample frames, not %d",
			path,
			frameSize,
			FRAME_SIZE,
		)
		Library_unloadHandle(lib)
		return false
	}
	lib.loaded = true
	lib.errorLength = 0
	return true
}

@(private)
Library_unloadHandle :: proc(lib: ^Library) {
	_ = dynlib.unload_library(lib.symbols.__handle)
	lib.symbols = {}
}

// Library_loadDefault tries the platform's library names. On Windows the copy next to the
// executable comes first, so the DLL shipped in the release archive wins over any other
// RNNoise on the search path.
Library_loadDefault :: proc(lib: ^Library) -> bool {
	when ODIN_OS == .Windows {
		exeDir, dirErr := os.get_executable_directory(context.temp_allocator)
		if dirErr == nil && exeDir != "" {
			for name in LIBRARY_NAMES {
				path := strings.concatenate({exeDir, "\\", name}, context.temp_allocator)
				if os.exists(path) && Library_loadPath(lib, path) {
					return true
				}
			}
		}
	}
	firstError: [ERROR_BUFFER_SIZE]u8
	firstErrorLength := 0
	for name, index in LIBRARY_NAMES {
		if Library_loadPath(lib, name) {
			return true
		}
		if index == 0 {
			firstErrorLength = copy(firstError[:], Library_error(lib))
		}
	}
	// Report the primary name's failure; later names are only fallbacks.
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
		rawptr(symbols.get_size),
		rawptr(symbols.get_frame_size),
		rawptr(symbols.init),
		rawptr(symbols.create),
		rawptr(symbols.destroy),
		rawptr(symbols.process_frame),
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

// RNNoise is loaded once per process and never unloaded, because denoisers may outlive any
// one voice session.
@(private)
defaultLibrary: Library
@(private)
defaultLibraryMutex: sync.Mutex
@(private)
defaultLibraryAttempted: bool

// load opens RNNoise for the whole process. It is safe to call from any thread and as often as
// wanted: only the first call touches the disk, and later calls return its result.
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

// loadError explains why load failed, for example "RNNoise not found (librnnoise.so.0: ...)".
// Empty when the library is loaded or load was never called.
loadError :: proc() -> string {
	sync.mutex_lock(&defaultLibraryMutex)
	defer sync.mutex_unlock(&defaultLibraryMutex)
	return Library_error(&defaultLibrary)
}

// ── Denoiser ──────────────────────────────────────────────────────

// createDenoiser makes a denoiser with the built-in model. RNNoise allocates it with its own
// malloc; free it with destroyDenoiser. Nil when the library is not loaded or creation fails.
createDenoiser :: proc() -> ^DenoiseState {
	if !isLoaded() {
		return nil
	}
	return defaultLibrary.create(nil)
}

destroyDenoiser :: proc(st: ^DenoiseState) {
	if st != nil && isLoaded() {
		defaultLibrary.destroy(st)
	}
}

// resetDenoiser puts a denoiser back into its first-frame state without allocating, so audio
// from before a pause does not shape the first frames after it.
resetDenoiser :: proc(st: ^DenoiseState) -> bool {
	return defaultLibrary.init(st, nil) == 0
}

// processFrame denoises one frame in place. samples holds FRAME_SIZE samples in RNNoise's
// ±SAMPLE_SCALE range. Returns the frame's speech probability, 0..1.
processFrame :: proc(st: ^DenoiseState, samples: []f32) -> f32 {
	assert(len(samples) == FRAME_SIZE, "RNNoise frames are FRAME_SIZE samples")
	return defaultLibrary.process_frame(st, raw_data(samples), raw_data(samples))
}
