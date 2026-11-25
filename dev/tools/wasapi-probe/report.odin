package wasapi_probe

// Platform-neutral parts of the probe: names for categories, effects and HRESULTs, sample
// conversion, capture statistics and the processing rule, so `odin test` covers them on
// Linux too.

import "core:fmt"
import "core:math"
import "core:strings"

// StreamCategory mirrors AUDIO_STREAM_CATEGORY (audioclient.h) for the categories we probe.
StreamCategory :: enum u32 {
	Other          = 0,
	Communications = 3,
	GameChat       = 8,
	Speech         = 9,
	Movie          = 10,
	Media          = 11,
}

streamCategoryFromName :: proc(name: string) -> (StreamCategory, bool) {
	switch strings.to_lower(name, context.temp_allocator) {
	case "other":
		return .Other, true
	case "communications":
		return .Communications, true
	case "gamechat":
		return .GameChat, true
	case "speech":
		return .Speech, true
	case "movie":
		return .Movie, true
	case "media":
		return .Media, true
	}
	return .Other, false
}

// Guid has windows.GUID's layout, so the Windows code can transmute between them.
Guid :: struct {
	data1: u32,
	data2: u16,
	data3: u16,
	data4: [8]u8,
}

formatGuid :: proc(guid: Guid, allocator := context.temp_allocator) -> string {
	d := guid.data4
	return fmt.aprintf(
		"{{%08x-%04x-%04x-%02x%02x-%02x%02x%02x%02x%02x%02x}}",
		guid.data1,
		guid.data2,
		guid.data3,
		d[0],
		d[1],
		d[2],
		d[3],
		d[4],
		d[5],
		d[6],
		d[7],
		allocator = allocator,
	)
}

// The AUDIO_EFFECT_TYPE_* GUIDs of ksmedia.h (Windows SDK 10.0.26100) differ only in
// data1, from 6f64adbe-8211-11e2-8c70-2c27d7f001fa upwards.
EFFECT_TYPE_DATA2 :: 0x8211
EFFECT_TYPE_DATA3 :: 0x11e2
EFFECT_TYPE_DATA4 :: [8]u8{0x8c, 0x70, 0x2c, 0x27, 0xd7, 0xf0, 0x01, 0xfa}

EffectKind :: enum {
	Unknown,
	AcousticEchoCancellation,
	NoiseSuppression,
	AutomaticGainControl,
	Beamforming,
	ConstantToneRemoval,
	Equalizer,
	LoudnessEqualizer,
	BassBoost,
	VirtualSurround,
	VirtualHeadphones,
	SpeakerFill,
	RoomCorrection,
	BassManagement,
	EnvironmentalEffects,
	SpeakerProtection,
	SpeakerCompensation,
	DynamicRangeCompression,
	FarFieldBeamforming,
	DeepNoiseSuppression,
}

// EFFECT_KIND_DATA1 is each known effect type's data1; the rest of the GUID is shared.
@(rodata)
EFFECT_KIND_DATA1 := [EffectKind]u32 {
	.Unknown                  = 0,
	.AcousticEchoCancellation = 0x6f64adbe,
	.NoiseSuppression         = 0x6f64adbf,
	.AutomaticGainControl     = 0x6f64adc0,
	.Beamforming              = 0x6f64adc1,
	.ConstantToneRemoval      = 0x6f64adc2,
	.Equalizer                = 0x6f64adc3,
	.LoudnessEqualizer        = 0x6f64adc4,
	.BassBoost                = 0x6f64adc5,
	.VirtualSurround          = 0x6f64adc6,
	.VirtualHeadphones        = 0x6f64adc7,
	.SpeakerFill              = 0x6f64adc8,
	.RoomCorrection           = 0x6f64adc9,
	.BassManagement           = 0x6f64adca,
	.EnvironmentalEffects     = 0x6f64adcb,
	.SpeakerProtection        = 0x6f64adcc,
	.SpeakerCompensation      = 0x6f64adcd,
	.DynamicRangeCompression  = 0x6f64adce,
	.FarFieldBeamforming      = 0x6f64adcf,
	.DeepNoiseSuppression     = 0x6f64add0,
}

effectKind :: proc(guid: Guid) -> EffectKind {
	if guid.data2 != EFFECT_TYPE_DATA2 ||
	   guid.data3 != EFFECT_TYPE_DATA3 ||
	   guid.data4 != EFFECT_TYPE_DATA4 {
		return .Unknown
	}
	for kind in EffectKind {
		if kind != .Unknown && EFFECT_KIND_DATA1[kind] == guid.data1 {
			return kind
		}
	}
	return .Unknown
}

effectKindGuid :: proc(kind: EffectKind) -> Guid {
	return Guid {
		data1 = EFFECT_KIND_DATA1[kind],
		data2 = EFFECT_TYPE_DATA2,
		data3 = EFFECT_TYPE_DATA3,
		data4 = EFFECT_TYPE_DATA4,
	}
}

// Effect is one entry of IAudioEffectsManager::GetAudioEffects.
Effect :: struct {
	id:          Guid,
	canSetState: bool,
	on:          bool,
}

// ProcessingAdvice is the "never double process" rule a real backend would apply to the
// effects its capture stream reports: an in-app stage runs only where Windows does not
// already do that job on this stream. `known` is false when the stream could not tell
// (no IAudioEffectsManager before Windows 11, or GetService failed); then the app cannot
// know, so it must choose by category: RAW or Other plus its own processing, or
// Communications and none of its own.
ProcessingAdvice :: struct {
	known:                   bool,
	osEchoCanceller:         bool,
	osNoiseSuppressor:       bool,
	osGainControl:           bool,
	runInAppEchoCanceller:   bool,
	runInAppNoiseSuppressor: bool,
	runInAppGainControl:     bool,
}

processingAdvice :: proc(effects: []Effect, known: bool) -> ProcessingAdvice {
	advice := ProcessingAdvice {
		known = known,
	}
	if !known {
		return advice
	}
	for effect in effects {
		if !effect.on {
			continue
		}
		#partial switch effectKind(effect.id) {
		case .AcousticEchoCancellation:
			advice.osEchoCanceller = true
		case .NoiseSuppression, .DeepNoiseSuppression:
			advice.osNoiseSuppressor = true
		case .AutomaticGainControl:
			advice.osGainControl = true
		}
	}
	advice.runInAppEchoCanceller = !advice.osEchoCanceller
	advice.runInAppNoiseSuppressor = !advice.osNoiseSuppressor
	advice.runInAppGainControl = !advice.osGainControl
	return advice
}

// processingAdviceText is one line for the report.
processingAdviceText :: proc(
	advice: ProcessingAdvice,
	allocator := context.temp_allocator,
) -> string {
	if !advice.known {
		return "effects unknown: choose by category (Communications and no in-app " +
		"processing, or Other/RAW and in-app processing)"
	}
	onOff :: proc(value: bool) -> string {
		return value ? "yes" : "no"
	}
	return fmt.aprintf(
		"Windows does AEC %s, NS %s, AGC %s; in-app AEC %s, NS %s, AGC %s",
		onOff(advice.osEchoCanceller),
		onOff(advice.osNoiseSuppressor),
		onOff(advice.osGainControl),
		onOff(advice.runInAppEchoCanceller),
		onOff(advice.runInAppNoiseSuppressor),
		onOff(advice.runInAppGainControl),
		allocator = allocator,
	)
}

// hresultName names the HRESULTs the probe can meet; others print as hex only.
hresultName :: proc(hr: u32) -> string {
	switch hr {
	case 0x00000000:
		return "S_OK"
	case 0x00000001:
		return "S_FALSE"
	case 0x80004001:
		return "E_NOTIMPL"
	case 0x80004002:
		return "E_NOINTERFACE"
	case 0x80004003:
		return "E_POINTER"
	case 0x80004005:
		return "E_FAIL"
	case 0x80070005:
		return "E_ACCESSDENIED"
	case 0x8007000E:
		return "E_OUTOFMEMORY"
	case 0x80070057:
		return "E_INVALIDARG"
	case 0x80070490:
		return "E_NOTFOUND (no such endpoint)"
	case 0x800401F0:
		return "CO_E_NOTINITIALIZED"
	case 0x88890001:
		return "AUDCLNT_E_NOT_INITIALIZED"
	case 0x88890002:
		return "AUDCLNT_E_ALREADY_INITIALIZED"
	case 0x88890004:
		return "AUDCLNT_E_DEVICE_INVALIDATED"
	case 0x88890008:
		return "AUDCLNT_E_UNSUPPORTED_FORMAT"
	case 0x8889000A:
		return "AUDCLNT_E_DEVICE_IN_USE"
	case 0x88890010:
		return "AUDCLNT_E_SERVICE_NOT_RUNNING"
	case 0x88890021:
		return "AUDCLNT_E_INVALID_STREAM_FLAG"
	case 0x88890026:
		return "AUDCLNT_E_RESOURCES_INVALIDATED"
	case 0x88890027:
		return "AUDCLNT_E_RAW_MODE_UNSUPPORTED"
	case 0x88890041:
		return "AUDCLNT_E_EFFECT_NOT_AVAILABLE"
	case 0x88890042:
		return "AUDCLNT_E_EFFECT_STATE_READ_ONLY"
	case 0x08890001:
		return "AUDCLNT_S_BUFFER_EMPTY"
	}
	return ""
}

formatHresult :: proc(hr: u32, allocator := context.temp_allocator) -> string {
	name := hresultName(hr)
	if name == "" {
		return fmt.aprintf("0x%08x", hr, allocator = allocator)
	}
	return fmt.aprintf("0x%08x %s", hr, name, allocator = allocator)
}

// SampleFormat is the layout of one sample in a capture packet.
SampleFormat :: enum {
	Unsupported,
	Float32,
	Int16,
	Int32, // also 24 valid bits in a 32-bit container, which WASAPI left-justifies
}

sampleFormatBytes :: proc(format: SampleFormat) -> int {
	switch format {
	case .Float32, .Int32:
		return 4
	case .Int16:
		return 2
	case .Unsupported:
	}
	return 0
}

// downmixToMono converts `frames` interleaved frames of `channels` channels into mono
// float samples (the mean of the channels). It returns how many frames it wrote, which is
// less than asked only when `dst` or `src` is too short.
downmixToMono :: proc(
	dst: []f32,
	src: []u8,
	frames: int,
	channels: int,
	format: SampleFormat,
) -> int {
	sampleBytes := sampleFormatBytes(format)
	if sampleBytes == 0 || channels <= 0 {
		return 0
	}
	count := min(frames, len(dst), len(src) / (sampleBytes * channels))
	scale := 1 / f32(channels)
	for frame in 0 ..< count {
		sum: f32
		for channel in 0 ..< channels {
			offset := (frame * channels + channel) * sampleBytes
			bytes := src[offset:offset + sampleBytes]
			switch format {
			case .Float32:
				sum += f32((^f32le)(raw_data(bytes))^)
			case .Int16:
				sum += f32(i16((^i16le)(raw_data(bytes))^)) / 32768
			case .Int32:
				sum += f32(f64(i32((^i32le)(raw_data(bytes))^)) / 2147483648)
			case .Unsupported:
			}
		}
		dst[frame] = sum * scale
	}
	return count
}

// CaptureStats sums what one capture run received.
CaptureStats :: struct {
	packets:         int,
	frames:          int,
	silentPackets:   int,
	discontinuities: int,
	timestampErrors: int,
	eventTimeouts:   int,
	maxEventGapMs:   f64,
	firstPacketMs:   f64,
	peak:            f32,
	sumSquares:      f64,
	levelSamples:    int,
	stopError:       u32,
}

AUDCLNT_BUFFERFLAGS_DATA_DISCONTINUITY :: 0x1
AUDCLNT_BUFFERFLAGS_SILENT :: 0x2
AUDCLNT_BUFFERFLAGS_TIMESTAMP_ERROR :: 0x4

captureStatsAddPacket :: proc(stats: ^CaptureStats, frames: int, flags: u32) {
	stats.packets += 1
	stats.frames += frames
	if flags & AUDCLNT_BUFFERFLAGS_SILENT != 0 {
		stats.silentPackets += 1
	}
	if flags & AUDCLNT_BUFFERFLAGS_DATA_DISCONTINUITY != 0 {
		stats.discontinuities += 1
	}
	if flags & AUDCLNT_BUFFERFLAGS_TIMESTAMP_ERROR != 0 {
		stats.timestampErrors += 1
	}
}

captureStatsAddLevels :: proc(stats: ^CaptureStats, samples: []f32) {
	for sample in samples {
		stats.peak = max(stats.peak, abs(sample))
		stats.sumSquares += f64(sample) * f64(sample)
	}
	stats.levelSamples += len(samples)
}

// dbfs is a level in dB below full scale, with -200 for silence.
dbfs :: proc(level: f64) -> f64 {
	if level <= 1e-10 {
		return -200
	}
	return 20 * math.log10(level)
}

captureStatsSummary :: proc(
	stats: CaptureStats,
	rate: int,
	seconds: f64,
	allocator := context.temp_allocator,
) -> string {
	rms := stats.levelSamples > 0 ? math.sqrt(stats.sumSquares / f64(stats.levelSamples)) : 0
	expected := f64(rate) * seconds
	ratio := expected > 0 ? f64(stats.frames) / expected : 0
	return fmt.aprintf(
		"frames %d of %.0f expected (%.1f%%), packets %d, silent %d, discontinuities %d, " +
		"timestamp errors %d, event timeouts %d, first packet after %.1f ms, " +
		"longest event gap %.1f ms, peak %.1f dBFS, RMS %.1f dBFS",
		stats.frames,
		expected,
		ratio * 100,
		stats.packets,
		stats.silentPackets,
		stats.discontinuities,
		stats.timestampErrors,
		stats.eventTimeouts,
		stats.firstPacketMs,
		stats.maxEventGapMs,
		dbfs(f64(stats.peak)),
		dbfs(rms),
		allocator = allocator,
	)
}
