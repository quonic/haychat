package client

// Source and sink specs, shared by `client --voice-loopback` (--source, --sink) and the
// headless harness (voice-source, voice-sink): device[:NAME], tone:HZ[:AMP], file:PATH and
// silence for a source; device[:NAME], file:PATH and null for a sink. Files are raw F32LE
// mono 48 kHz samples. Strings in the result are borrowed from spec.

import "core:strconv"
import "core:strings"

voiceParseSourceSpec :: proc(spec: string) -> (source: VoiceSourceConfig, ok: bool) {
	kind, _, rest := strings.partition(spec, ":")
	switch kind {
	case "device":
		return {kind = .Device, deviceName = rest}, true
	case "silence":
		return {kind = .Silence}, rest == ""
	case "file":
		return {kind = .File, path = rest}, rest != ""
	case "tone":
		hzText, _, amplitudeText := strings.partition(rest, ":")
		hz, hzOK := strconv.parse_f32(hzText)
		if !hzOK || hz <= 0 || hz >= 24000 {
			return {}, false
		}
		source = {
			kind   = .Tone,
			toneHz = hz,
		}
		if amplitudeText != "" {
			amplitude, amplitudeOK := strconv.parse_f32(amplitudeText)
			if !amplitudeOK || amplitude <= 0 || amplitude > 1 {
				return {}, false
			}
			source.toneAmplitude = amplitude
		}
		return source, true
	}
	return {}, false
}

voiceParseSinkSpec :: proc(spec: string) -> (sink: VoiceSinkConfig, ok: bool) {
	kind, _, rest := strings.partition(spec, ":")
	switch kind {
	case "device":
		return {kind = .Device, deviceName = rest}, true
	case "null":
		return {kind = .Null}, rest == ""
	case "file":
		return {kind = .File, path = rest}, rest != ""
	}
	return {}, false
}
