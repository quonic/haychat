package opus

// A small libopus binding loaded at runtime with core:dynlib, so the client neither links
// libopus nor needs it to start: chat works without it and voice reports why it is missing.
// Like client/ui, this package must not import HayChat types.
//
// Windows has no import library for libopus-0.dll, and Linux distributions ship only the
// versioned runtime name (libopus.so.0) outside their -devel packages, which is why the
// library is opened by name instead of linked.

import "core:c"
import "core:dynlib"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"

// Used only on Windows, to look next to the executable first.
_ :: os
_ :: strings

Encoder :: struct {}
Decoder :: struct {}

OK :: 0
APPLICATION_VOIP :: 2048
SIGNAL_VOICE :: 3001

SET_BITRATE_REQUEST :: 4002
GET_BITRATE_REQUEST :: 4003
SET_VBR_REQUEST :: 4006
GET_VBR_REQUEST :: 4007
SET_COMPLEXITY_REQUEST :: 4010
GET_COMPLEXITY_REQUEST :: 4011
SET_INBAND_FEC_REQUEST :: 4012
GET_INBAND_FEC_REQUEST :: 4013
SET_PACKET_LOSS_PERC_REQUEST :: 4014
GET_PACKET_LOSS_PERC_REQUEST :: 4015
SET_DTX_REQUEST :: 4016
GET_DTX_REQUEST :: 4017
SET_VBR_CONSTRAINT_REQUEST :: 4020
GET_VBR_CONSTRAINT_REQUEST :: 4021
SET_SIGNAL_REQUEST :: 4024
GET_SIGNAL_REQUEST :: 4025
GET_LOOKAHEAD_REQUEST :: 4027
RESET_STATE :: 4028

// Opus's own limit for one encoded frame.
MAX_PACKET_BYTES :: 1275

// Every symbol the client calls. Field names are the C names without the "opus_" prefix,
// which is what dynlib.initialize_symbols looks up.
Symbols :: struct {
	encoder_create:        proc "c" (
		fs: i32,
		channels: c.int,
		application: c.int,
		error: ^c.int,
	) -> ^Encoder,
	// Opus reads opus_int32 (or a pointer to one) after the request, so callers pass i32
	// values explicitly.
	encoder_ctl:           proc "c" (st: ^Encoder, request: c.int, #c_vararg args: ..any) -> c.int,
	encode_float:          proc "c" (
		st: ^Encoder,
		pcm: [^]f32,
		frame_size: c.int,
		data: [^]u8,
		max_data_bytes: i32,
	) -> i32,
	encoder_destroy:       proc "c" (st: ^Encoder),
	decoder_create:        proc "c" (fs: i32, channels: c.int, error: ^c.int) -> ^Decoder,
	decoder_ctl:           proc "c" (st: ^Decoder, request: c.int, #c_vararg args: ..any) -> c.int,
	decode_float:          proc "c" (
		st: ^Decoder,
		data: [^]u8,
		len: i32,
		pcm: [^]f32,
		frame_size: c.int,
		decode_fec: c.int,
	) -> c.int,
	decoder_destroy:       proc "c" (st: ^Decoder),
	packet_get_nb_samples: proc "c" (data: [^]u8, len: i32, fs: i32) -> c.int,
	strerror:              proc "c" (error: c.int) -> cstring,
	get_version_string:    proc "c" () -> cstring,
	__handle:              dynlib.Library,
}

SYMBOL_NAMES :: [?]string {
	"encoder_create",
	"encoder_ctl",
	"encode_float",
	"encoder_destroy",
	"decoder_create",
	"decoder_ctl",
	"decode_float",
	"decoder_destroy",
	"packet_get_nb_samples",
	"strerror",
	"get_version_string",
}

when ODIN_OS == .Windows {
	LIBRARY_NAMES :: [?]string{"libopus-0.dll", "opus.dll"}
} else when ODIN_OS == .Darwin {
	LIBRARY_NAMES :: [?]string{"libopus.0.dylib", "libopus.dylib"}
} else {
	LIBRARY_NAMES :: [?]string{"libopus.so.0"}
}

ERROR_BUFFER_SIZE :: 512

// One loaded copy of libopus. The error text lives in a fixed buffer so callers can borrow
// it without owning an allocation.
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
// present. A library without them is unloaded again, so a half-filled table is never used.
Library_loadPath :: proc(lib: ^Library, path: string) -> bool {
	if lib.loaded {
		return true
	}
	lib.symbols = {}
	_, ok := dynlib.initialize_symbols(&lib.symbols, path, "opus_")
	if lib.symbols.__handle == nil {
		Library_setError(lib, "libopus not found (%s: %s)", path, dynlib.last_error())
		return false
	}
	missing := Symbols_firstMissing(&lib.symbols)
	if !ok || missing != "" {
		Library_setError(lib, "libopus at %s lacks opus_%s", path, missing)
		_ = dynlib.unload_library(lib.symbols.__handle)
		lib.symbols = {}
		return false
	}
	lib.loaded = true
	lib.errorLength = 0
	return true
}

// Library_loadDefault tries the platform's library names. On Windows the copy next to the
// executable comes first, so the DLL shipped in the release archive wins over any other
// libopus on the search path.
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
		rawptr(symbols.encoder_create),
		rawptr(symbols.encoder_ctl),
		rawptr(symbols.encode_float),
		rawptr(symbols.encoder_destroy),
		rawptr(symbols.decoder_create),
		rawptr(symbols.decoder_ctl),
		rawptr(symbols.decode_float),
		rawptr(symbols.decoder_destroy),
		rawptr(symbols.packet_get_nb_samples),
		rawptr(symbols.strerror),
		rawptr(symbols.get_version_string),
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

// libopus is loaded once per process and never unloaded, because encoders and decoders may
// outlive any one voice session.
@(private)
defaultLibrary: Library
@(private)
defaultLibraryMutex: sync.Mutex
@(private)
defaultLibraryAttempted: bool

// load opens libopus for the whole process. It is safe to call from any thread and as often
// as wanted: only the first call touches the disk, and later calls return its result.
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

// loadError explains why load failed, for example "libopus not found (libopus.so.0: ...)".
// Empty when the library is loaded or load was never called.
loadError :: proc() -> string {
	sync.mutex_lock(&defaultLibraryMutex)
	defer sync.mutex_unlock(&defaultLibraryMutex)
	return Library_error(&defaultLibrary)
}

versionString :: proc() -> string {
	if !isLoaded() {
		return ""
	}
	return string(defaultLibrary.get_version_string())
}

errorString :: proc(code: c.int) -> string {
	if !isLoaded() {
		return "libopus is not loaded"
	}
	return string(defaultLibrary.strerror(code))
}

// ── Encoder ───────────────────────────────────────────────────────

EncoderSettings :: struct {
	bitrate:           i32,
	complexity:        i32,
	packetLossPercent: i32,
	inbandFEC:         bool,
	dtx:               bool,
	constrainedVBR:    bool,
	// Constant bitrate (protocol 21, e2ee-voice-design.md 8): every 20 ms packet the same
	// length, so the lengths of an encrypted room's frames do not follow the speech. The zero
	// value keeps VBR (constrained when constrainedVBR is set).
	cbr:               bool,
}

// HayChat's voice settings (voice-rooms-design.md section 2.1, Q4 and Q5): 24 kbit/s
// constrained VBR, complexity 8, in-band FEC tuned for 10% loss, DTX off because the
// client's own gate stops sending during silence.
VOICE_ENCODER_SETTINGS :: EncoderSettings {
	bitrate           = 24000,
	complexity        = 8,
	packetLossPercent = 10,
	inbandFEC         = true,
	dtx               = false,
	constrainedVBR    = true,
}

// createVoiceEncoder makes a 48 kHz mono VOIP encoder with the given settings applied.
// Returns nil and the libopus error code when creation or a setting fails.
createVoiceEncoder :: proc(
	sampleRate: i32,
	settings: EncoderSettings,
) -> (
	encoder: ^Encoder,
	code: c.int,
) {
	if !isLoaded() {
		return nil, -1
	}
	err: c.int
	encoder = defaultLibrary.encoder_create(sampleRate, 1, APPLICATION_VOIP, &err)
	if encoder == nil || err != OK {
		if encoder != nil {
			defaultLibrary.encoder_destroy(encoder)
		}
		return nil, err != OK ? err : -1
	}
	code = configureEncoder(encoder, settings)
	if code != OK {
		defaultLibrary.encoder_destroy(encoder)
		return nil, code
	}
	return encoder, OK
}

configureEncoder :: proc(encoder: ^Encoder, settings: EncoderSettings) -> c.int {
	requests := [?][2]i32 {
		{SET_SIGNAL_REQUEST, SIGNAL_VOICE},
		{SET_BITRATE_REQUEST, settings.bitrate},
		{SET_VBR_REQUEST, settings.cbr ? 0 : 1},
		{SET_VBR_CONSTRAINT_REQUEST, settings.constrainedVBR ? 1 : 0},
		{SET_COMPLEXITY_REQUEST, settings.complexity},
		{SET_INBAND_FEC_REQUEST, settings.inbandFEC ? 1 : 0},
		{SET_PACKET_LOSS_PERC_REQUEST, settings.packetLossPercent},
		{SET_DTX_REQUEST, settings.dtx ? 1 : 0},
	}
	for request in requests {
		code := defaultLibrary.encoder_ctl(encoder, c.int(request[0]), request[1])
		if code != OK {
			return code
		}
	}
	return OK
}

// encoderGet reads one integer setting back (a GET_*_REQUEST), mostly for tests.
encoderGet :: proc(encoder: ^Encoder, request: i32) -> (value: i32, code: c.int) {
	code = defaultLibrary.encoder_ctl(encoder, c.int(request), &value)
	return
}

// encoderSetBitrate changes a running encoder's bitrate (bit/s) without resetting it.
encoderSetBitrate :: proc(encoder: ^Encoder, bitrate: i32) -> c.int {
	return defaultLibrary.encoder_ctl(encoder, SET_BITRATE_REQUEST, bitrate)
}

encoderReset :: proc(encoder: ^Encoder) -> c.int {
	return defaultLibrary.encoder_ctl(encoder, RESET_STATE)
}

destroyEncoder :: proc(encoder: ^Encoder) {
	if encoder != nil && isLoaded() {
		defaultLibrary.encoder_destroy(encoder)
	}
}

// encodeFloat encodes one frame (len(pcm) samples, mono) into out. Returns the number of
// bytes written, or a negative libopus error code.
encodeFloat :: proc(encoder: ^Encoder, pcm: []f32, out: []u8) -> i32 {
	return defaultLibrary.encode_float(
		encoder,
		raw_data(pcm),
		c.int(len(pcm)),
		raw_data(out),
		i32(min(len(out), MAX_PACKET_BYTES)),
	)
}

// ── Decoder ───────────────────────────────────────────────────────

createDecoder :: proc(sampleRate: i32) -> (decoder: ^Decoder, code: c.int) {
	if !isLoaded() {
		return nil, -1
	}
	err: c.int
	decoder = defaultLibrary.decoder_create(sampleRate, 1, &err)
	if decoder == nil || err != OK {
		if decoder != nil {
			defaultLibrary.decoder_destroy(decoder)
		}
		return nil, err != OK ? err : -1
	}
	return decoder, OK
}

decoderReset :: proc(decoder: ^Decoder) -> c.int {
	return defaultLibrary.decoder_ctl(decoder, RESET_STATE)
}

destroyDecoder :: proc(decoder: ^Decoder) {
	if decoder != nil && isLoaded() {
		defaultLibrary.decoder_destroy(decoder)
	}
}

// decodeFloat decodes into pcm, whose length is the frame size asked for.
//   - packet with fec=false: normal decode.
//   - packet with fec=true: rebuild the frame *before* packet from its redundant data; pcm
//     must be exactly the missing duration.
//   - empty packet: packet loss concealment.
// Returns the number of samples decoded, or a negative libopus error code.
decodeFloat :: proc(decoder: ^Decoder, packet: []u8, pcm: []f32, fec := false) -> c.int {
	data: [^]u8 = len(packet) > 0 ? raw_data(packet) : nil
	return defaultLibrary.decode_float(
		decoder,
		data,
		i32(len(packet)),
		raw_data(pcm),
		c.int(len(pcm)),
		fec && len(packet) > 0 ? 1 : 0,
	)
}

// packetSampleCount returns how many samples per channel a packet decodes to at sampleRate,
// or a negative error code for a malformed packet.
packetSampleCount :: proc(packet: []u8, sampleRate: i32) -> c.int {
	if len(packet) == 0 {
		return -1
	}
	return defaultLibrary.packet_get_nb_samples(raw_data(packet), i32(len(packet)), sampleRate)
}
