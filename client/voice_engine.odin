package client

// VoiceEngine: capture → gate → Opus encode → outbound, and inbound → per-speaker jitter
// buffer → Opus decode (with FEC and PLC) → sink, on a thread of its own
// (voice-rooms-design.md sections 1.4 and 5.2). It has no networking: H5 plugs the network
// worker into the two seams below.
//
//   - Outbound: config.onOutbound is called on the voice thread with every encoded frame
//     (frameSequence, flags, Opus bytes borrowed for the call).
//   - Inbound: VoiceEngine_pushInbound(engine, senderUserID, frameSequence, flags, opus) may
//     be called from any thread; it copies the frame into a bounded queue under a mutex.
//
// Loopback mode feeds the encoder's output back into the inbound queue as a fake remote
// speaker, so the whole pipeline runs without a server. Tests can make it drop and reorder
// frames.
//
// Threads and ownership:
//   - VoiceEngine_create allocates the engine and every buffer the voice thread uses. Nothing
//     on the voice thread allocates per frame. Codec, SDL stream and file handles are created
//     in VoiceEngine_open and released in VoiceEngine_close.
//   - The voice thread owns the codec, gate, jitter buffers, SDL streams and sink file while
//     it runs. Other threads only set the atomic controls (mute, push-to-talk, gate mode,
//     threshold), push inbound frames, and read VoiceEngine_snapshot / VoiceEngine_inputLevel.
//   - SDL's audio subsystem is initialised only when a device source or sink is opened, so a
//     headless client never touches SDL unless asked to.

import "../common"
import "core:c"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "opus"
import SDL "vendor:sdl3"

#assert(ODIN_ENDIAN == .Little, "raw F32LE file sources and sinks assume a little-endian host")

VOICE_FRAME_BYTES :: common.VOICE_FRAME_SAMPLES * size_of(f32)
// Above the server's default room size of 25.
VOICE_MAX_SPEAKERS :: 32
// About 0.2 s of frames from 25 speakers; the voice thread drains it every few milliseconds.
VOICE_INBOUND_CAPACITY :: 256
VOICE_SPEAKER_IDLE_MS :: 10_000.0
VOICE_TICK_INTERVAL :: 5 * time.Millisecond
// Captured frames allowed to queue up before the oldest are dropped, so a stalled voice
// thread does not leave a lasting delay.
VOICE_CAPTURE_MAX_BACKLOG_FRAMES :: 3
// Decoded audio kept queued in each speaker's SDL stream.
VOICE_PLAYBACK_TARGET_FRAMES :: 2
// The sender ID of loopback frames; real user IDs are small positive integers.
VOICE_LOOPBACK_USER_ID :: u32(0xFFFF_FFFF)
VOICE_DEFAULT_TONE_AMPLITUDE :: f32(0.5)
VOICE_ERROR_BUFFER_SIZE :: 512

VoiceSourceKind :: enum u8 {
	Silence,
	// A sine wave at toneHz.
	Tone,
	// Raw F32LE mono 48 kHz samples read from path.
	File,
	// An SDL recording device; deviceName "" is the system default.
	Device,
}

VoiceSourceConfig :: struct {
	kind:          VoiceSourceKind,
	toneHz:        f32,
	// 0 means VOICE_DEFAULT_TONE_AMPLITUDE.
	toneAmplitude: f32,
	// Borrowed; VoiceEngine_create keeps its own copy.
	path:          string,
	// File: start over at the end instead of falling silent.
	loop:          bool,
	deviceName:    string,
}

VoiceSinkKind :: enum u8 {
	// Decode and discard (statistics only).
	Null,
	// Every speaker mixed into one raw F32LE mono 48 kHz track at path. Silence is written
	// while nobody speaks, so the file keeps one time base.
	File,
	// An SDL playback device with one SDL stream per remote speaker; SDL mixes them.
	Device,
}

VoiceSinkConfig :: struct {
	kind:       VoiceSinkKind,
	path:       string,
	deviceName: string,
}

// Faults applied to loopback frames only, so tests can exercise FEC, PLC and reordering
// deterministically.
VoiceLoopbackFaults :: struct {
	// Share of frames dropped, chosen by a generator seeded with seed.
	lossPercent:  int,
	seed:         u64,
	// Every Nth frame is held back and delivered after the frame that follows it.
	reorderEvery: int,
}

VoiceOutboundFrame :: struct {
	frameSequence: u32,
	flags:         u8,
	// Borrowed for the duration of the callback.
	opus:          []u8,
}

// Called on the voice thread for every encoded frame.
VoiceOutboundProc :: #type proc(userdata: rawptr, frame: VoiceOutboundFrame)

// One frame's timing, for latency measurements (voice-rooms-design.md 6.4). Encoded: this
// engine encoded its own frame `sequence` (speakerUserID 0). Played: it decoded frame
// `sequence` of speakerUserID for its sink (a normal decode, not FEC or concealment). at is
// the monotonic clock, which every engine and process on one host shares, so a test can
// match a sender's Encoded to a receiver's Played by sequence.
VoiceFrameTiming :: struct {
	played:        bool,
	speakerUserID: u32,
	sequence:      u32,
	at:            time.Tick,
}

// Called on the voice thread; it must be quick and must not call back into the engine.
VoiceFrameTimingProc :: #type proc(userdata: rawptr, timing: VoiceFrameTiming)

VoiceEngineConfig :: struct {
	source:           VoiceSourceConfig,
	sink:             VoiceSinkConfig,
	// A zero value means opus.VOICE_ENCODER_SETTINGS.
	encoder:          opus.EncoderSettings,
	gateMode:         VoiceGateMode,
	// 0 means VOICE_VAD_DEFAULT_THRESHOLD_DB, unless explicitLevels is set.
	vadThresholdDB:   f32,
	// 0 means 1, unless explicitLevels is set.
	inputGain:        f32,
	// Linear gain on everything played (the playback device's gain, or the file and null
	// mix). 0 means 1, unless explicitLevels is set.
	outputVolume:     f32,
	// Use inputGain, outputVolume and vadThresholdDB as given, zeros included. Configs built
	// from the user's settings set it, because 0 is a valid gain and threshold there.
	explicitLevels:   bool,
	loopback:         bool,
	loopbackFaults:   VoiceLoopbackFaults,
	// Advance the media clock by one 20 ms frame per step instead of following the wall
	// clock, for tests. Needs a non-device source and sink.
	unpaced:          bool,
	onOutbound:       VoiceOutboundProc,
	outboundUserdata: rawptr,
	// Where frameSequence starts. A restarted engine (State_voiceRestartEngine) continues
	// the old one's media clock, so listeners keep their place instead of dropping its frames
	// as late. resumeSequenceAt is when resumeSequence was the next sequence: VoiceEngine_open
	// adds the 20 ms ticks since then, because the clock ran on while no device captured.
	// Zero values start at 0.
	resumeSequence:   u32,
	resumeSequenceAt: time.Tick,
	// Optional, for latency tests: every encoded and every played frame.
	onFrameTiming:    VoiceFrameTimingProc,
	timingUserdata:   rawptr,
}

VoiceEngineStats :: struct {
	framesCaptured:  u64,
	framesSent:      u64, // encoded and handed to the outbound seam
	framesGated:     u64, // captured while the gate was closed
	captureDropped:  u64, // dropped from a backed-up capture stream
	encodeErrors:    u64,
	inboundAccepted: u64,
	inboundDropped:  u64, // queue full (oldest dropped) or no free speaker slot
	inboundInvalid:  u64,
	inboundDeafened: u64, // refused or discarded while deafened
	loopbackDropped: u64, // simulated loss
	framesDecoded:   u64,
	decodeErrors:    u64,
	framesPlayed:    u64, // mixed frames written to a file or null sink
	sinkWriteErrors: u64, // file sink writes that failed (a full disk truncates the file)
	speakersCreated: u64,
	speakersExpired: u64,
	// Received frames decoded for playout (normal decodes), and how long they waited between
	// arriving and being decoded: the jitter buffer's delay. A device sink adds the SDL
	// stream's queue (up to VOICE_PLAYBACK_TARGET_FRAMES) on top.
	playoutDelayFrames:  u64,
	playoutDelayTotalMS: f64,
	playoutDelayMaxMS:   f64,
	// HAYCHAT_TEST_FAULTS builds only (voice_faults.odin): received frames the fault hook
	// dropped, and frames it delayed. Always 0 in normal builds.
	faultDropped:        u64,
	faultDelayed:        u64,
}

VoiceSpeakerSnapshot :: struct {
	userID:         u32,
	speaking:       bool,
	levelDB:        f32,
	bufferedFrames: int,
	targetDepth:    int,
	jitterMS:       f32,
}

VoiceEngineSnapshot :: struct {
	running:       bool,
	inputLevelDB:  f32,
	transmitting:  bool,
	frameSequence: u32,
	stats:         VoiceEngineStats,
	// Totals over every speaker, including expired ones.
	jitter:        JitterStats,
	speakerCount:  int,
	speakers:      [VOICE_MAX_SPEAKERS]VoiceSpeakerSnapshot,
}

VoiceInboundFrame :: struct {
	senderUserID:  u32,
	frameSequence: u32,
	flags:         u8,
	length:        int,
	data:          [common.VOICE_OPUS_MAX_BYTES]u8,
}

VoiceSpeaker :: struct {
	active:        bool,
	userID:        u32,
	jitter:        JitterBuffer,
	decoder:       ^opus.Decoder,
	stream:        ^SDL.AudioStream,
	lastArrivalMS: f64,
	levelDB:       f32,
}

VoiceEngine :: struct {
	config:              VoiceEngineConfig, // strings owned
	allocator:           mem.Allocator,
	thread:              ^thread.Thread,
	stopRequested:       bool, // atomic
	opened:              bool, // atomic; inbound frames are accepted only while open
	// Controls, written by any thread with atomics.
	muted:               bool,
	deafened:            bool,
	pttHeld:             bool,
	gateMode:            VoiceGateMode,
	thresholdBits:       u32,
	inputGainBits:       u32,
	outputVolumeBits:    u32,
	bitrateRequest:      i32,
	// Level meter, written by the voice thread with atomics.
	inputLevelBits:      u32,
	transmitting:        bool,
	// Published once per step under snapshotMutex.
	snapshotMutex:       sync.Mutex,
	published:           VoiceEngineSnapshot,
	// Inbound queue: a ring of VOICE_INBOUND_CAPACITY frames under inboundMutex.
	inboundMutex:        sync.Mutex,
	inbound:             [VOICE_INBOUND_CAPACITY]VoiceInboundFrame,
	inboundHead:         int,
	inboundCount:        int,
	inboundDropped:      u64, // under inboundMutex
	inboundInvalid:      u64, // under inboundMutex
	inboundDeafened:     u64, // under inboundMutex
	// Voice-thread copy of the queue, so speakers are created without holding inboundMutex.
	drainBatch:          [VOICE_INBOUND_CAPACITY]VoiceInboundFrame,
	// Voice-thread state.
	stats:               VoiceEngineStats,
	retiredJitter:       JitterStats,
	encoder:             ^opus.Encoder,
	encoderSettings:     opus.EncoderSettings,
	// The output volume last applied to the playback device or mix.
	appliedOutputVolume: f32,
	gate:                VoiceGate,
	frameSequence:       u32,
	captureFrame:        [common.VOICE_FRAME_SAMPLES]f32,
	decodeFrame:         [common.VOICE_FRAME_SAMPLES]f32,
	mixFrame:            [common.VOICE_FRAME_SAMPLES]f32,
	encodeBuffer:        [opus.MAX_PACKET_BYTES]u8,
	speakers:            [VOICE_MAX_SPEAKERS]VoiceSpeaker,
	clockStart:          time.Tick,
	mediaClockMS:        f64,
	nextCaptureMS:       f64,
	nextPlayoutMS:       f64,
	// Sources.
	captureStream:       ^SDL.AudioStream,
	sourceBytes:         []u8, // owned file contents
	sourceSamples:       []f32, // view of sourceBytes
	sourcePosition:      int,
	tonePhase:           f64,
	// Sinks.
	playbackDevice:      SDL.AudioDeviceID,
	sinkFile:            ^os.File,
	sdlAudioInitialised: bool,
	deviceFallback:      bool, // a named device was not found and the default was used
	// Loopback.
	faultState:          u64,
	loopbackCount:       u64,
	heldFrame:           VoiceOutboundFrame,
	heldFrameData:       [common.VOICE_OPUS_MAX_BYTES]u8,
	hasHeldFrame:        bool,
	errorBuffer:         [VOICE_ERROR_BUFFER_SIZE]u8,
	errorLength:         int,
	// File sink flushes (VoiceEngine_requestSinkFlush): tickets, both atomic. The voice
	// thread, which owns the file, flushes and then publishes the ticket it served.
	sinkFlushRequested:  u64,
	sinkFlushCompleted:  u64,
	// Empty unless built with HAYCHAT_TEST_FAULTS.
	faults:              VoiceReceiveFaults,
}

// ── Lifecycle ─────────────────────────────────────────────────────

// VoiceEngine_create allocates an engine for config. It opens nothing: call VoiceEngine_start
// (thread) or VoiceEngine_open plus VoiceEngine_step (tests).
VoiceEngine_create :: proc(
	config: VoiceEngineConfig,
	allocator := context.allocator,
) -> ^VoiceEngine {
	engine := new(VoiceEngine, allocator)
	engine.allocator = allocator
	engine.config = config
	engine.config.source.path = strings.clone(config.source.path, allocator)
	engine.config.source.deviceName = strings.clone(config.source.deviceName, allocator)
	engine.config.sink.path = strings.clone(config.sink.path, allocator)
	engine.config.sink.deviceName = strings.clone(config.sink.deviceName, allocator)
	engine.encoderSettings = config.encoder
	if engine.encoderSettings == {} {
		engine.encoderSettings = opus.VOICE_ENCODER_SETTINGS
	}
	if engine.config.inputGain == 0 && !config.explicitLevels {
		engine.config.inputGain = 1
	}
	if engine.config.outputVolume == 0 && !config.explicitLevels {
		engine.config.outputVolume = 1
	}
	if engine.config.source.toneAmplitude == 0 {
		engine.config.source.toneAmplitude = VOICE_DEFAULT_TONE_AMPLITUDE
	}
	threshold := config.vadThresholdDB
	if threshold == 0 && !config.explicitLevels {
		threshold = VOICE_VAD_DEFAULT_THRESHOLD_DB
	}
	engine.gateMode = config.gateMode
	engine.thresholdBits = transmute(u32)threshold
	engine.inputGainBits = transmute(u32)engine.config.inputGain
	engine.outputVolumeBits = transmute(u32)engine.config.outputVolume
	engine.bitrateRequest = engine.encoderSettings.bitrate
	engine.inputLevelBits = transmute(u32)VOICE_LEVEL_FLOOR_DB
	return engine
}

// VoiceEngine_destroy stops the engine if it runs and frees it.
VoiceEngine_destroy :: proc(engine: ^VoiceEngine) {
	if engine == nil {
		return
	}
	VoiceEngine_stop(engine)
	allocator := engine.allocator
	delete(engine.config.source.path, allocator)
	delete(engine.config.source.deviceName, allocator)
	delete(engine.config.sink.path, allocator)
	delete(engine.config.sink.deviceName, allocator)
	free(engine, allocator)
}

// VoiceEngine_lastError explains the last failed open. Borrowed from the engine.
VoiceEngine_lastError :: proc(engine: ^VoiceEngine) -> string {
	return string(engine.errorBuffer[:engine.errorLength])
}

@(private = "file")
VoiceEngine_setError :: proc(engine: ^VoiceEngine, format: string, args: ..any) {
	text := fmt.bprintf(engine.errorBuffer[:], format, ..args)
	engine.errorLength = len(text)
}

// VoiceEngine_start opens the source, sink and codec on the calling thread (so errors come
// back here) and starts the voice thread.
VoiceEngine_start :: proc(engine: ^VoiceEngine) -> bool {
	if engine.thread != nil {
		return true
	}
	if !VoiceEngine_open(engine) {
		return false
	}
	sync.atomic_store(&engine.stopRequested, false)
	engine.thread = thread.create_and_start_with_data(engine, VoiceEngine_run, context)
	if engine.thread == nil {
		VoiceEngine_setError(engine, "could not start the voice thread")
		VoiceEngine_close(engine)
		return false
	}
	return true
}

// VoiceEngine_stop joins the voice thread and releases everything VoiceEngine_open opened.
// Safe to call when the engine is not running.
VoiceEngine_stop :: proc(engine: ^VoiceEngine) {
	if engine.thread != nil {
		sync.atomic_store(&engine.stopRequested, true)
		thread.join(engine.thread)
		thread.destroy(engine.thread)
		engine.thread = nil
	}
	VoiceEngine_close(engine)
}

// VoiceEngine_nextSequence is the frameSequence the engine would give its next captured
// frame. Only meaningful once VoiceEngine_stop has joined the voice thread, which owns it.
VoiceEngine_nextSequence :: proc(engine: ^VoiceEngine) -> u32 {
	assert(engine.thread == nil, "VoiceEngine_nextSequence needs a stopped engine")
	return engine.frameSequence
}

VoiceEngine_isRunning :: proc(engine: ^VoiceEngine) -> bool {
	return engine.thread != nil
}

@(private = "file")
VoiceEngine_run :: proc(data: rawptr) {
	engine := (^VoiceEngine)(data)
	for !sync.atomic_load(&engine.stopRequested) {
		VoiceEngine_step(engine)
		if engine.config.unpaced {
			thread.yield()
		} else {
			time.sleep(VOICE_TICK_INTERVAL)
		}
	}
}

// VoiceEngine_open prepares the codec, source and sink without starting a thread. Tests
// then drive the engine with VoiceEngine_step; VoiceEngine_start uses it too.
VoiceEngine_open :: proc(engine: ^VoiceEngine) -> bool {
	if sync.atomic_load(&engine.opened) {
		return true
	}
	engine.errorLength = 0
	engine.deviceFallback = false
	source := engine.config.source
	sink := engine.config.sink
	if engine.config.unpaced && (source.kind == .Device || sink.kind == .Device) {
		VoiceEngine_setError(engine, "an unpaced engine needs a non-device source and sink")
		return false
	}
	if !opus.load() {
		VoiceEngine_setError(engine, "Voice unavailable: %s", opus.loadError())
		return false
	}
	ok := false
	defer if !ok {
		VoiceEngine_close(engine)
	}
	code: c.int
	engine.encoder, code = opus.createVoiceEncoder(common.VOICE_SAMPLE_RATE, engine.encoderSettings)
	if engine.encoder == nil {
		VoiceEngine_setError(engine, "Opus encoder: %s", opus.errorString(code))
		return false
	}

	if source.kind == .Device || sink.kind == .Device {
		if !VoiceEngine_initSDLAudio(engine) {
			return false
		}
	}
	switch source.kind {
	case .Silence, .Tone:
	case .File:
		bytes, readErr := os.read_entire_file_from_path(source.path, engine.allocator)
		if readErr != nil {
			VoiceEngine_setError(engine, "voice source %s: %v", source.path, readErr)
			return false
		}
		engine.sourceBytes = bytes
		engine.sourceSamples = mem.slice_data_cast([]f32, bytes[:len(bytes) / 4 * 4])
	case .Device:
		if !VoiceEngine_openCapture(engine) {
			return false
		}
	}
	switch sink.kind {
	case .Null:
	case .File:
		file, createErr := os.create(sink.path)
		if createErr != nil {
			VoiceEngine_setError(engine, "voice sink %s: %v", sink.path, createErr)
			return false
		}
		engine.sinkFile = file
	case .Device:
		if !VoiceEngine_openPlayback(engine) {
			return false
		}
	}

	engine.gate = {}
	if sink.kind != .Device {
		engine.appliedOutputVolume = transmute(f32)sync.atomic_load(&engine.outputVolumeBits)
	}
	engine.frameSequence = engine.config.resumeSequence
	if engine.config.resumeSequenceAt != {} {
		// Round up: a skipped tick looks like one lost frame to a listener, while a reused
		// sequence would be dropped as a duplicate or a late frame.
		elapsedMS := time.duration_milliseconds(time.tick_since(engine.config.resumeSequenceAt))
		engine.frameSequence += u32(math.ceil(max(elapsedMS, 0) / VOICE_FRAME_MS))
	}
	engine.stats = {}
	engine.retiredJitter = {}
	engine.mediaClockMS = 0
	engine.nextCaptureMS = 0
	engine.nextPlayoutMS = 0
	engine.sourcePosition = 0
	engine.tonePhase = 0
	engine.faultState = engine.config.loopbackFaults.seed ~ 0x9E37_79B9_7F4A_7C15
	engine.loopbackCount = 0
	engine.hasHeldFrame = false
	when HAYCHAT_TEST_FAULTS {
		VoiceReceiveFaults_initFromEnvironment(&engine.faults)
	}
	engine.clockStart = time.tick_now()
	sync.mutex_lock(&engine.inboundMutex)
	engine.inboundHead = 0
	engine.inboundCount = 0
	engine.inboundDropped = 0
	engine.inboundInvalid = 0
	engine.inboundDeafened = 0
	sync.mutex_unlock(&engine.inboundMutex)
	sync.atomic_store(&engine.opened, true)
	VoiceEngine_publish(engine)
	ok = true
	return true
}

// VoiceEngine_close releases what VoiceEngine_open created. The voice thread must not run.
VoiceEngine_close :: proc(engine: ^VoiceEngine) {
	sync.atomic_store(&engine.opened, false)
	for &speaker in engine.speakers {
		if speaker.active {
			VoiceEngine_releaseSpeaker(engine, &speaker)
		}
	}
	if engine.captureStream != nil {
		SDL.DestroyAudioStream(engine.captureStream)
		engine.captureStream = nil
	}
	if engine.playbackDevice != 0 {
		SDL.CloseAudioDevice(engine.playbackDevice)
		engine.playbackDevice = 0
	}
	if engine.sdlAudioInitialised {
		SDL.QuitSubSystem({.AUDIO})
		engine.sdlAudioInitialised = false
	}
	if engine.encoder != nil {
		opus.destroyEncoder(engine.encoder)
		engine.encoder = nil
	}
	if engine.sinkFile != nil {
		_ = os.close(engine.sinkFile)
		engine.sinkFile = nil
	}
	if engine.sourceBytes != nil {
		delete(engine.sourceBytes, engine.allocator)
		engine.sourceBytes = nil
		engine.sourceSamples = nil
	}
	sync.atomic_store(&engine.transmitting, false)
	VoiceEngine_publish(engine)
}

// ── SDL devices ───────────────────────────────────────────────────

@(private = "file")
VoiceEngine_initSDLAudio :: proc(engine: ^VoiceEngine) -> bool {
	// Hints set at normal priority, so SDL_AUDIO_* environment variables still win (the
	// disk driver in tests relies on that).
	_ = SDL.SetHint(SDL.HINT_AUDIO_DEVICE_STREAM_ROLE, "Communication")
	_ = SDL.SetHint(SDL.HINT_AUDIO_DEVICE_STREAM_NAME, "HayChat voice")
	// No HINT_AUDIO_DEVICE_SAMPLE_FRAMES: with "480" (10 ms), SDL 3.4's PipeWire backend
	// delivered under half the captured samples on a host whose minimum quantum is 1024.
	if !SDL.InitSubSystem({.AUDIO}) {
		VoiceEngine_setError(engine, "SDL audio: %s", SDL.GetError())
		return false
	}
	engine.sdlAudioInitialised = true
	return true
}

// voiceFindDevice maps a device name to its ID, falling back to the default device when
// the name is empty or unknown (IDs are not stable across runs, names are).
@(private = "file")
voiceFindDevice :: proc(name: string, recording: bool) -> (id: SDL.AudioDeviceID, fellBack: bool) {
	defaultID := recording ? SDL.AUDIO_DEVICE_DEFAULT_RECORDING : SDL.AUDIO_DEVICE_DEFAULT_PLAYBACK
	if name == "" {
		return defaultID, false
	}
	count: c.int
	devices :=
		recording ? SDL.GetAudioRecordingDevices(&count) : SDL.GetAudioPlaybackDevices(&count)
	if devices == nil {
		return defaultID, true
	}
	defer SDL.free(devices)
	for index in 0 ..< int(count) {
		if string(SDL.GetAudioDeviceName(devices[index])) == name {
			return devices[index], false
		}
	}
	return defaultID, true
}

@(private = "file")
VoiceEngine_openCapture :: proc(engine: ^VoiceEngine) -> bool {
	deviceID, fellBack := voiceFindDevice(engine.config.source.deviceName, true)
	engine.deviceFallback ||= fellBack
	spec := SDL.AudioSpec {
		format   = .F32,
		channels = 1,
		freq     = common.VOICE_SAMPLE_RATE,
	}
	engine.captureStream = SDL.OpenAudioDeviceStream(deviceID, &spec, nil, nil)
	if engine.captureStream == nil {
		VoiceEngine_setError(engine, "Microphone not available: %s", SDL.GetError())
		return false
	}
	// Device streams open paused.
	if !SDL.ResumeAudioStreamDevice(engine.captureStream) {
		VoiceEngine_setError(engine, "Microphone did not start: %s", SDL.GetError())
		return false
	}
	return true
}

@(private = "file")
VOICE_PLAYBACK_SPEC :: SDL.AudioSpec {
	format   = .F32,
	channels = 2,
	freq     = common.VOICE_SAMPLE_RATE,
}

@(private = "file")
VoiceEngine_openPlayback :: proc(engine: ^VoiceEngine) -> bool {
	deviceID, fellBack := voiceFindDevice(engine.config.sink.deviceName, false)
	engine.deviceFallback ||= fellBack
	// Stereo leaves room for panning later; each speaker's mono stream is converted by SDL.
	spec := VOICE_PLAYBACK_SPEC
	engine.playbackDevice = SDL.OpenAudioDevice(deviceID, &spec)
	if engine.playbackDevice == 0 {
		VoiceEngine_setError(engine, "Speakers not available: %s", SDL.GetError())
		return false
	}
	_ = SDL.ResumeAudioDevice(engine.playbackDevice)
	engine.appliedOutputVolume = transmute(f32)sync.atomic_load(&engine.outputVolumeBits)
	_ = SDL.SetAudioDeviceGain(engine.playbackDevice, engine.appliedOutputVolume)
	return true
}

// ── Controls (any thread) ─────────────────────────────────────────

VoiceEngine_setMuted :: proc(engine: ^VoiceEngine, muted: bool) {
	sync.atomic_store(&engine.muted, muted)
}

// VoiceEngine_setDeafened stops playback at once: inbound frames are refused, and the voice
// thread discards what is queued and releases every speaker on its next step, so nothing
// already buffered plays after the call. The server also stops relaying to a deafened
// session, but only once ClientVoiceState reaches it.
VoiceEngine_setDeafened :: proc(engine: ^VoiceEngine, deafened: bool) {
	sync.atomic_store(&engine.deafened, deafened)
}

// VoiceEngine_setPushToTalk records whether the push-to-talk key is held. The UI sets it from
// keyboard events while its window has focus (Q3: no global hotkeys).
VoiceEngine_setPushToTalk :: proc(engine: ^VoiceEngine, held: bool) {
	sync.atomic_store(&engine.pttHeld, held)
}

VoiceEngine_setGateMode :: proc(engine: ^VoiceEngine, mode: VoiceGateMode) {
	sync.atomic_store(&engine.gateMode, mode)
}

VoiceEngine_setVADThreshold :: proc(engine: ^VoiceEngine, thresholdDB: f32) {
	sync.atomic_store(&engine.thresholdBits, transmute(u32)thresholdDB)
}

// VoiceEngine_setInputGain sets the linear gain applied to every captured frame before the
// level meter and the gate see it, from the next frame on.
VoiceEngine_setInputGain :: proc(engine: ^VoiceEngine, gain: f32) {
	sync.atomic_store(&engine.inputGainBits, transmute(u32)max(gain, 0))
}

// VoiceEngine_setOutputVolume sets the linear gain on everything the engine plays. The voice
// thread applies it on its next step: as the playback device's gain (SDL mixes every speaker
// into that device), or to the mixed frame of a file or null sink.
VoiceEngine_setOutputVolume :: proc(engine: ^VoiceEngine, volume: f32) {
	sync.atomic_store(&engine.outputVolumeBits, transmute(u32)max(volume, 0))
}

// VoiceEngine_setBitrate asks for a new Opus bitrate in bit/s. The voice thread owns the
// encoder, so it applies the change (OPUS_SET_BITRATE) on its next step; the stream goes on
// without a restart.
VoiceEngine_setBitrate :: proc(engine: ^VoiceEngine, bitrate: i32) {
	sync.atomic_store(&engine.bitrateRequest, bitrate)
}

// VoiceEngine_bitrate is the bitrate the encoder uses now. Only meaningful on the voice
// thread or while no thread runs (tests driving VoiceEngine_step).
VoiceEngine_bitrate :: proc(engine: ^VoiceEngine) -> i32 {
	return engine.encoderSettings.bitrate
}

// VoiceEngine_usedDeviceFallback says whether the last open could not find a named device and
// used the system default instead, so the UI can say so. Written only by VoiceEngine_open.
VoiceEngine_usedDeviceFallback :: proc(engine: ^VoiceEngine) -> bool {
	return engine.deviceFallback
}

// VoiceEngine_inputLevel is the latest captured frame's level in dBFS and whether that frame
// was sent, for the level meter and the "you are speaking" indicator. Lock-free.
VoiceEngine_inputLevel :: proc(engine: ^VoiceEngine) -> (levelDB: f32, transmitting: bool) {
	levelDB = transmute(f32)sync.atomic_load(&engine.inputLevelBits)
	transmitting = sync.atomic_load(&engine.transmitting)
	return
}

// VoiceEngine_snapshot copies the counters and per-speaker state the voice thread published
// on its last step.
VoiceEngine_snapshot :: proc(engine: ^VoiceEngine) -> VoiceEngineSnapshot {
	sync.mutex_lock(&engine.snapshotMutex)
	defer sync.mutex_unlock(&engine.snapshotMutex)
	return engine.published
}

// ── Inbound seam (any thread) ─────────────────────────────────────

// VoiceEngine_pushInbound queues one received frame for the voice thread. The opus bytes are
// copied, so the caller keeps ownership. When the queue is full the oldest frame is dropped,
// because a late frame is worth less than a new one. Returns false for an invalid frame or
// while the engine is not open.
VoiceEngine_pushInbound :: proc(
	engine: ^VoiceEngine,
	senderUserID: u32,
	frameSequence: u32,
	flags: u8,
	opus: []u8,
) -> bool {
	sync.mutex_lock(&engine.inboundMutex)
	defer sync.mutex_unlock(&engine.inboundMutex)
	if !sync.atomic_load(&engine.opened) {
		return false
	}
	if senderUserID == 0 || len(opus) == 0 || len(opus) > common.VOICE_OPUS_MAX_BYTES {
		engine.inboundInvalid += 1
		return false
	}
	if sync.atomic_load(&engine.deafened) {
		engine.inboundDeafened += 1
		return false
	}
	if engine.inboundCount == VOICE_INBOUND_CAPACITY {
		engine.inboundHead = (engine.inboundHead + 1) % VOICE_INBOUND_CAPACITY
		engine.inboundCount -= 1
		engine.inboundDropped += 1
	}
	index := (engine.inboundHead + engine.inboundCount) % VOICE_INBOUND_CAPACITY
	frame := &engine.inbound[index]
	frame.senderUserID = senderUserID
	frame.frameSequence = frameSequence
	frame.flags = flags
	frame.length = copy(frame.data[:], opus)
	engine.inboundCount += 1
	return true
}

// ── Voice thread ──────────────────────────────────────────────────

@(private = "file")
VoiceEngine_clockMS :: proc(engine: ^VoiceEngine) -> f64 {
	if engine.config.unpaced {
		return engine.mediaClockMS
	}
	return time.duration_milliseconds(time.tick_since(engine.clockStart))
}

// VoiceEngine_step runs one pass of the voice thread: capture and send what is due, move
// inbound frames into jitter buffers, play out what is due, expire idle speakers, and
// publish a snapshot. Unpaced engines process exactly one 20 ms frame each way per step.
VoiceEngine_step :: proc(engine: ^VoiceEngine) {
	if !sync.atomic_load(&engine.opened) {
		return
	}
	if engine.config.unpaced {
		engine.mediaClockMS += VOICE_FRAME_MS
	}
	now := VoiceEngine_clockMS(engine)
	VoiceEngine_applyControls(engine)
	VoiceEngine_capture(engine, now)
	VoiceEngine_drainInbound(engine, now)
	VoiceEngine_playout(engine, now)
	VoiceEngine_serveSinkFlush(engine)
	VoiceEngine_expireSpeakers(engine, now)
	VoiceEngine_publish(engine)
}

// Applies the controls that need the voice thread's own objects: the encoder's bitrate and
// the playback device's gain.
@(private = "file")
VoiceEngine_applyControls :: proc(engine: ^VoiceEngine) {
	bitrate := sync.atomic_load(&engine.bitrateRequest)
	if bitrate > 0 && bitrate != engine.encoderSettings.bitrate && engine.encoder != nil {
		if opus.encoderSetBitrate(engine.encoder, bitrate) == opus.OK {
			engine.encoderSettings.bitrate = bitrate
		} else {
			// Refused (out of libopus's range): keep the current rate and stop asking.
			sync.atomic_store(&engine.bitrateRequest, engine.encoderSettings.bitrate)
		}
	}
	volume := transmute(f32)sync.atomic_load(&engine.outputVolumeBits)
	if volume != engine.appliedOutputVolume {
		engine.appliedOutputVolume = volume
		if engine.playbackDevice != 0 {
			_ = SDL.SetAudioDeviceGain(engine.playbackDevice, volume)
		}
	}
}

// VoiceEngine_requestSinkFlush asks the voice thread to flush the file sink after its next
// playout and returns a ticket; once VoiceEngine_sinkFlushCompleted reaches it, every frame
// played before the request is in the file. From any thread. With no file sink the request is
// served all the same, so a caller never waits for nothing.
VoiceEngine_requestSinkFlush :: proc(engine: ^VoiceEngine) -> u64 {
	return sync.atomic_add(&engine.sinkFlushRequested, 1) + 1
}

VoiceEngine_sinkFlushCompleted :: proc(engine: ^VoiceEngine) -> u64 {
	return sync.atomic_load(&engine.sinkFlushCompleted)
}

@(private = "file")
VoiceEngine_serveSinkFlush :: proc(engine: ^VoiceEngine) {
	requested := sync.atomic_load(&engine.sinkFlushRequested)
	if requested == sync.atomic_load(&engine.sinkFlushCompleted) {
		return
	}
	// Writes are unbuffered, so this only makes them durable (fsync); the point is the
	// ticket, which says the frames before the request have been written.
	if engine.sinkFile != nil {
		if os.flush(engine.sinkFile) != nil {
			engine.stats.sinkWriteErrors += 1
		}
	}
	sync.atomic_store(&engine.sinkFlushCompleted, requested)
}

@(private = "file")
VoiceEngine_capture :: proc(engine: ^VoiceEngine, now: f64) {
	frame := engine.captureFrame[:]
	switch engine.config.source.kind {
	case .Device:
		available := int(SDL.GetAudioStreamAvailable(engine.captureStream))
		for available > VOICE_CAPTURE_MAX_BACKLOG_FRAMES * VOICE_FRAME_BYTES {
			_ = SDL.GetAudioStreamData(engine.captureStream, raw_data(frame), VOICE_FRAME_BYTES)
			engine.stats.captureDropped += 1
			available -= VOICE_FRAME_BYTES
		}
		for available >= VOICE_FRAME_BYTES {
			got := SDL.GetAudioStreamData(engine.captureStream, raw_data(frame), VOICE_FRAME_BYTES)
			if got != VOICE_FRAME_BYTES {
				break
			}
			available -= VOICE_FRAME_BYTES
			VoiceEngine_processCapturedFrame(engine)
		}
	case .Silence, .Tone, .File:
		if engine.config.unpaced {
			VoiceEngine_generateFrame(engine)
			VoiceEngine_processCapturedFrame(engine)
			return
		}
		if now - engine.nextCaptureMS > VOICE_CAPTURE_MAX_BACKLOG_FRAMES * VOICE_FRAME_MS {
			// The thread stalled: skip ahead like a real microphone would drop audio.
			skipped := u64((now - engine.nextCaptureMS) / VOICE_FRAME_MS) - 1
			engine.stats.captureDropped += skipped
			engine.nextCaptureMS += f64(skipped) * VOICE_FRAME_MS
		}
		for now >= engine.nextCaptureMS {
			VoiceEngine_generateFrame(engine)
			VoiceEngine_processCapturedFrame(engine)
			engine.nextCaptureMS += VOICE_FRAME_MS
		}
	}
}

@(private = "file")
VoiceEngine_generateFrame :: proc(engine: ^VoiceEngine) {
	frame := engine.captureFrame[:]
	source := engine.config.source
	switch source.kind {
	case .Silence, .Device:
		mem.zero_slice(frame)
	case .Tone:
		step := 2 * math.PI * f64(source.toneHz) / common.VOICE_SAMPLE_RATE
		for &sample in frame {
			sample = source.toneAmplitude * f32(math.sin(engine.tonePhase))
			engine.tonePhase += step
			if engine.tonePhase >= 2 * math.PI {
				engine.tonePhase -= 2 * math.PI
			}
		}
	case .File:
		samples := engine.sourceSamples
		for &sample in frame {
			if engine.sourcePosition >= len(samples) && source.loop && len(samples) > 0 {
				engine.sourcePosition = 0
			}
			if engine.sourcePosition < len(samples) {
				sample = samples[engine.sourcePosition]
				engine.sourcePosition += 1
			} else {
				sample = 0
			}
		}
	}
}

@(private = "file")
VoiceEngine_processCapturedFrame :: proc(engine: ^VoiceEngine) {
	frame := engine.captureFrame[:]
	gain := transmute(f32)sync.atomic_load(&engine.inputGainBits)
	if gain != 1 {
		for &sample in frame {
			sample = clamp(sample * gain, -1, 1)
		}
	}
	engine.stats.framesCaptured += 1
	level := voiceFrameLevelDB(frame)
	sync.atomic_store(&engine.inputLevelBits, transmute(u32)level)

	result := VoiceGate_update(
		&engine.gate,
		{
			mode = sync.atomic_load(&engine.gateMode),
			levelDB = level,
			thresholdDB = transmute(f32)sync.atomic_load(&engine.thresholdBits),
			muted = sync.atomic_load(&engine.muted),
			pttHeld = sync.atomic_load(&engine.pttHeld),
		},
	)
	// The media clock advances on every tick, gated or not, so receivers can tell silence
	// from loss.
	sequence := engine.frameSequence
	engine.frameSequence += 1
	sync.atomic_store(&engine.transmitting, result.transmit)
	if !result.transmit {
		engine.stats.framesGated += 1
		return
	}
	length := opus.encodeFloat(engine.encoder, frame, engine.encodeBuffer[:])
	if length <= 0 || int(length) > common.VOICE_OPUS_MAX_BYTES {
		engine.stats.encodeErrors += 1
		return
	}
	flags: u8
	if result.endOfSpurt {
		flags |= common.VOICE_FRAME_FLAG_END_OF_SPURT
	}
	if engine.encoderSettings.inbandFEC {
		flags |= common.VOICE_FRAME_FLAG_FEC_PRESENT
	}
	outbound := VoiceOutboundFrame {
		frameSequence = sequence,
		flags         = flags,
		opus          = engine.encodeBuffer[:length],
	}
	engine.stats.framesSent += 1
	if engine.config.onFrameTiming != nil {
		engine.config.onFrameTiming(
			engine.config.timingUserdata,
			{sequence = sequence, at = time.tick_now()},
		)
	}
	if engine.config.onOutbound != nil {
		engine.config.onOutbound(engine.config.outboundUserdata, outbound)
	}
	if engine.config.loopback {
		VoiceEngine_loopback(engine, outbound)
	}
}

// voiceNextRandom is splitmix64: tiny, seedable, and the same on every platform, so loopback
// loss patterns are reproducible.
voiceNextRandom :: proc(state: ^u64) -> u64 {
	state^ += 0x9E37_79B9_7F4A_7C15
	z := state^
	z = (z ~ (z >> 30)) * 0xBF58_476D_1CE4_E5B9
	z = (z ~ (z >> 27)) * 0x94D0_49BB_1331_11EB
	return z ~ (z >> 31)
}

@(private = "file")
VoiceEngine_loopback :: proc(engine: ^VoiceEngine, frame: VoiceOutboundFrame) {
	faults := engine.config.loopbackFaults
	engine.loopbackCount += 1
	if faults.lossPercent > 0 &&
	   int(voiceNextRandom(&engine.faultState) % 100) < faults.lossPercent {
		engine.stats.loopbackDropped += 1
		return
	}
	if faults.reorderEvery > 0 &&
	   !engine.hasHeldFrame &&
	   engine.loopbackCount % u64(faults.reorderEvery) == 0 {
		length := copy(engine.heldFrameData[:], frame.opus)
		engine.heldFrame = frame
		engine.heldFrame.opus = engine.heldFrameData[:length]
		engine.hasHeldFrame = true
		return
	}
	_ = VoiceEngine_pushInbound(
		engine,
		VOICE_LOOPBACK_USER_ID,
		frame.frameSequence,
		frame.flags,
		frame.opus,
	)
	if engine.hasHeldFrame {
		engine.hasHeldFrame = false
		held := engine.heldFrame
		_ = VoiceEngine_pushInbound(
			engine,
			VOICE_LOOPBACK_USER_ID,
			held.frameSequence,
			held.flags,
			held.opus,
		)
	}
}

@(private = "file")
VoiceEngine_findSpeaker :: proc(engine: ^VoiceEngine, userID: u32, now: f64) -> ^VoiceSpeaker {
	freeSlot: ^VoiceSpeaker
	for &speaker in engine.speakers {
		if speaker.active && speaker.userID == userID {
			return &speaker
		}
		if !speaker.active && freeSlot == nil {
			freeSlot = &speaker
		}
	}
	if freeSlot == nil {
		return nil
	}
	decoder, _ := opus.createDecoder(common.VOICE_SAMPLE_RATE)
	if decoder == nil {
		return nil
	}
	stream: ^SDL.AudioStream
	if engine.config.sink.kind == .Device {
		sourceSpec := SDL.AudioSpec {
			format   = .F32,
			channels = 1,
			freq     = common.VOICE_SAMPLE_RATE,
		}
		deviceSpec := VOICE_PLAYBACK_SPEC
		stream = SDL.CreateAudioStream(&sourceSpec, &deviceSpec)
		if stream == nil || !SDL.BindAudioStream(engine.playbackDevice, stream) {
			if stream != nil {
				SDL.DestroyAudioStream(stream)
			}
			opus.destroyDecoder(decoder)
			return nil
		}
	}
	freeSlot^ = {}
	freeSlot.active = true
	freeSlot.userID = userID
	freeSlot.decoder = decoder
	freeSlot.stream = stream
	freeSlot.lastArrivalMS = now
	freeSlot.levelDB = VOICE_LEVEL_FLOOR_DB
	JitterBuffer_init(&freeSlot.jitter)
	engine.stats.speakersCreated += 1
	return freeSlot
}

@(private = "file")
VoiceEngine_releaseSpeaker :: proc(engine: ^VoiceEngine, speaker: ^VoiceSpeaker) {
	jitterStatsAdd(&engine.retiredJitter, speaker.jitter.stats)
	if speaker.stream != nil {
		// Destroying a bound stream unbinds it.
		SDL.DestroyAudioStream(speaker.stream)
	}
	opus.destroyDecoder(speaker.decoder)
	speaker^ = {}
}

jitterStatsAdd :: proc(total: ^JitterStats, add: JitterStats) {
	total.received += add.received
	total.duplicates += add.duplicates
	total.late += add.late
	total.invalid += add.invalid
	total.played += add.played
	total.fec += add.fec
	total.plc += add.plc
	total.silent += add.silent
	total.resets += add.resets
	total.spurts += add.spurts
	total.maxGapRun = max(total.maxGapRun, add.maxGapRun)
}

@(private = "file")
VoiceEngine_drainInbound :: proc(engine: ^VoiceEngine, now: f64) {
	// Move the queued frames out under the lock and work on the copy without it. A frame
	// from a new speaker creates an Opus decoder and an SDL stream, which must never stall
	// the network worker waiting in VoiceEngine_pushInbound.
	sync.mutex_lock(&engine.inboundMutex)
	count := engine.inboundCount
	for index in 0 ..< count {
		slot := (engine.inboundHead + index) % VOICE_INBOUND_CAPACITY
		engine.drainBatch[index] = engine.inbound[slot]
	}
	engine.inboundHead = (engine.inboundHead + count) % VOICE_INBOUND_CAPACITY
	engine.inboundCount = 0
	sync.mutex_unlock(&engine.inboundMutex)

	noSpeaker: u64
	deafenedDiscards: u64
	if sync.atomic_load(&engine.deafened) {
		// Nothing buffered may play once deafened, so drop the speakers and their jitter
		// buffers; they come back with the next frame after undeafening.
		for &speaker in engine.speakers {
			if speaker.active {
				VoiceEngine_releaseSpeaker(engine, &speaker)
			}
		}
		deafenedDiscards = u64(count)
		count = 0
		when HAYCHAT_TEST_FAULTS {
			VoiceReceiveFaults_clear(&engine.faults)
		}
	}
	when HAYCHAT_TEST_FAULTS {
		if engine.faults.enabled {
			// Delayed frames that are due go first: they arrived earlier.
			released: VoiceInboundFrame
			for VoiceReceiveFaults_release(&engine.faults, now, &released) {
				if !VoiceEngine_deliverInbound(engine, &released, now) {
					noSpeaker += 1
				}
			}
		}
	}
	for &frame in engine.drainBatch[:count] {
		when HAYCHAT_TEST_FAULTS {
			if engine.faults.enabled {
				switch VoiceReceiveFaults_admit(&engine.faults, &frame, now) {
				case .Deliver:
				case .Drop:
					engine.stats.faultDropped += 1
					continue
				case .Hold:
					engine.stats.faultDelayed += 1
					continue
				}
			}
		}
		if !VoiceEngine_deliverInbound(engine, &frame, now) {
			noSpeaker += 1
		}
	}

	sync.mutex_lock(&engine.inboundMutex)
	engine.inboundDropped += noSpeaker
	engine.inboundDeafened += deafenedDiscards
	engine.stats.inboundDropped = engine.inboundDropped
	engine.stats.inboundInvalid = engine.inboundInvalid
	engine.stats.inboundDeafened = engine.inboundDeafened
	sync.mutex_unlock(&engine.inboundMutex)
}

// Pushes one frame into its speaker's jitter buffer. Returns false when there is no free
// speaker slot.
@(private = "file")
VoiceEngine_deliverInbound :: proc(
	engine: ^VoiceEngine,
	frame: ^VoiceInboundFrame,
	now: f64,
) -> bool {
	speaker := VoiceEngine_findSpeaker(engine, frame.senderUserID, now)
	if speaker == nil {
		return false
	}
	speaker.lastArrivalMS = now
	engine.stats.inboundAccepted += 1
	_ = JitterBuffer_push(
		&speaker.jitter,
		frame.frameSequence,
		frame.flags,
		frame.data[:frame.length],
		now,
	)
	return true
}

@(private = "file")
voicePacketIsOneFrame :: proc(packet: []u8) -> bool {
	return opus.packetSampleCount(packet, common.VOICE_SAMPLE_RATE) == common.VOICE_FRAME_SAMPLES
}

// Counts a received frame's wait in the jitter buffer and reports its playout.
@(private = "file")
VoiceEngine_notePlayed :: proc(
	engine: ^VoiceEngine,
	speaker: ^VoiceSpeaker,
	output: JitterOutput,
	now: f64,
) {
	delay := max(now - output.arrivalMS, 0)
	engine.stats.playoutDelayFrames += 1
	engine.stats.playoutDelayTotalMS += delay
	engine.stats.playoutDelayMaxMS = max(engine.stats.playoutDelayMaxMS, delay)
	if engine.config.onFrameTiming != nil {
		engine.config.onFrameTiming(
			engine.config.timingUserdata,
			{
				played = true,
				speakerUserID = speaker.userID,
				sequence = output.sequence,
				at = time.tick_now(),
			},
		)
	}
}

// VoiceEngine_decode turns one jitter-buffer decision into 20 ms of PCM in decodeFrame.
@(private = "file")
VoiceEngine_decode :: proc(
	engine: ^VoiceEngine,
	speaker: ^VoiceSpeaker,
	output: JitterOutput,
	now: f64,
) -> []f32 {
	pcm := engine.decodeFrame[:]
	decoded: c.int = -1
	switch output.action {
	case .Idle, .Silence:
		mem.zero_slice(pcm)
		return pcm
	case .Decode:
		VoiceEngine_notePlayed(engine, speaker, output, now)
		if voicePacketIsOneFrame(output.data) {
			decoded = opus.decodeFloat(speaker.decoder, output.data, pcm)
		} else {
			// Not a 20 ms packet: conceal rather than desynchronise the decoder.
			engine.stats.decodeErrors += 1
			decoded = opus.decodeFloat(speaker.decoder, nil, pcm)
		}
	case .DecodeFEC:
		if voicePacketIsOneFrame(output.data) {
			decoded = opus.decodeFloat(speaker.decoder, output.data, pcm, fec = true)
		} else {
			decoded = opus.decodeFloat(speaker.decoder, nil, pcm)
		}
	case .Conceal:
		decoded = opus.decodeFloat(speaker.decoder, nil, pcm)
	}
	if decoded != common.VOICE_FRAME_SAMPLES {
		engine.stats.decodeErrors += 1
		mem.zero_slice(pcm)
	} else {
		engine.stats.framesDecoded += 1
	}
	speaker.levelDB = voiceFrameLevelDB(pcm)
	return pcm
}

@(private = "file")
VoiceEngine_playout :: proc(engine: ^VoiceEngine, now: f64) {
	switch engine.config.sink.kind {
	case .Device:
		target := c.int(VOICE_PLAYBACK_TARGET_FRAMES * VOICE_FRAME_BYTES)
		for &speaker in engine.speakers {
			if !speaker.active {
				continue
			}
			for SDL.GetAudioStreamQueued(speaker.stream) < target {
				output := JitterBuffer_next(&speaker.jitter)
				if output.action == .Idle {
					speaker.levelDB = VOICE_LEVEL_FLOOR_DB
					break
				}
				pcm := VoiceEngine_decode(engine, &speaker, output, now)
				_ = SDL.PutAudioStreamData(speaker.stream, raw_data(pcm), VOICE_FRAME_BYTES)
			}
		}
	case .File, .Null:
		if engine.config.unpaced {
			VoiceEngine_playMixedFrame(engine, now)
			return
		}
		if now - engine.nextPlayoutMS > VOICE_CAPTURE_MAX_BACKLOG_FRAMES * VOICE_FRAME_MS {
			// After a stall, skip the missed time instead of bursting it out.
			engine.nextPlayoutMS = now
		}
		for now >= engine.nextPlayoutMS {
			VoiceEngine_playMixedFrame(engine, now)
			engine.nextPlayoutMS += VOICE_FRAME_MS
		}
	}
}

@(private = "file")
VoiceEngine_playMixedFrame :: proc(engine: ^VoiceEngine, now: f64) {
	mix := engine.mixFrame[:]
	mem.zero_slice(mix)
	for &speaker in engine.speakers {
		if !speaker.active {
			continue
		}
		output := JitterBuffer_next(&speaker.jitter)
		if output.action == .Idle {
			speaker.levelDB = VOICE_LEVEL_FLOOR_DB
			continue
		}
		pcm := VoiceEngine_decode(engine, &speaker, output, now)
		for sample, index in pcm {
			mix[index] += sample
		}
	}
	volume := engine.appliedOutputVolume
	for &sample in mix {
		sample = clamp(sample * volume, -1, 1)
	}
	engine.stats.framesPlayed += 1
	if engine.sinkFile != nil {
		if _, writeErr := os.write(engine.sinkFile, mem.slice_to_bytes(mix)); writeErr != nil {
			engine.stats.sinkWriteErrors += 1
		}
	}
}

@(private = "file")
VoiceEngine_expireSpeakers :: proc(engine: ^VoiceEngine, now: f64) {
	for &speaker in engine.speakers {
		if speaker.active &&
		   !speaker.jitter.inSpurt &&
		   now - speaker.lastArrivalMS > VOICE_SPEAKER_IDLE_MS {
			VoiceEngine_releaseSpeaker(engine, &speaker)
			engine.stats.speakersExpired += 1
		}
	}
}

@(private = "file")
VoiceEngine_publish :: proc(engine: ^VoiceEngine) {
	sync.mutex_lock(&engine.snapshotMutex)
	defer sync.mutex_unlock(&engine.snapshotMutex)
	snapshot := &engine.published
	snapshot.running = sync.atomic_load(&engine.opened)
	snapshot.inputLevelDB, snapshot.transmitting = VoiceEngine_inputLevel(engine)
	snapshot.frameSequence = engine.frameSequence
	snapshot.stats = engine.stats
	snapshot.jitter = engine.retiredJitter
	snapshot.speakerCount = 0
	for &speaker in engine.speakers {
		if !speaker.active {
			continue
		}
		jitterStatsAdd(&snapshot.jitter, speaker.jitter.stats)
		snapshot.speakers[snapshot.speakerCount] = {
			userID         = speaker.userID,
			speaking       = speaker.jitter.inSpurt,
			levelDB        = speaker.levelDB,
			bufferedFrames = JitterBuffer_buffered(&speaker.jitter),
			targetDepth    = speaker.jitter.targetDepth,
			jitterMS       = f32(speaker.jitter.jitterMS),
		}
		snapshot.speakerCount += 1
	}
}
