package client

// `client --voice-loopback`: a hidden debug mode that runs the VoiceEngine in loopback, from
// the microphone through Opus and the jitter buffer to the speakers, with no window and no
// server. It exists for manual checks of devices and codec settings; see
// docs/testing-harness.md. Sources and sinks can be swapped for tones and raw files, so the
// same mode also works in a container under SDL's disk driver.

import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:time"

VOICE_LOOPBACK_FLAG :: "--voice-loopback"
VOICE_LOOPBACK_DEFAULT_SECONDS :: 10
VOICE_LOOPBACK_MAX_SECONDS :: 600
VOICE_LOOPBACK_USAGE ::
	"usage: client --voice-loopback [--seconds N] [--source SPEC] [--sink SPEC] [--loss PCT]\n" +
	"                               [--threshold DB] [--always-on]\n" +
	"  --seconds N      how long to run (default 10, at most 600)\n" +
	"  --source SPEC    device[:NAME] (default), tone:HZ, file:PATH (raw F32LE mono 48 kHz),\n" +
	"                   or silence\n" +
	"  --sink SPEC      device[:NAME] (default), file:PATH (raw F32LE mono 48 kHz), or null\n" +
	"  --loss PCT       drop this share of loopback frames (0-90) to hear FEC and PLC\n" +
	"  --threshold DB   voice activity threshold in dBFS (default -45)\n" +
	"  --always-on      send every frame (push-to-talk held) instead of voice activity\n" +
	"Prints the input level every second on stderr and the engine counters as JSON on stdout."

voiceLoopbackRequested :: proc(args: []string) -> bool {
	for arg in args {
		if arg == VOICE_LOOPBACK_FLAG {
			return true
		}
	}
	return false
}

@(private = "file")
voiceLoopbackParseSource :: proc(spec: string, source: ^VoiceSourceConfig) -> bool {
	kind, _, rest := strings.partition(spec, ":")
	switch kind {
	case "device":
		source^ = {
			kind       = .Device,
			deviceName = rest,
		}
	case "silence":
		source^ = {
			kind = .Silence,
		}
	case "file":
		source^ = {
			kind = .File,
			path = rest,
		}
		return rest != ""
	case "tone":
		hz, ok := strconv.parse_f32(rest)
		if !ok || hz <= 0 || hz >= 24000 {
			return false
		}
		source^ = {
			kind   = .Tone,
			toneHz = hz,
		}
	case:
		return false
	}
	return true
}

@(private = "file")
voiceLoopbackParseSink :: proc(spec: string, sink: ^VoiceSinkConfig) -> bool {
	kind, _, rest := strings.partition(spec, ":")
	switch kind {
	case "device":
		sink^ = {
			kind       = .Device,
			deviceName = rest,
		}
	case "null":
		sink^ = {
			kind = .Null,
		}
	case "file":
		sink^ = {
			kind = .File,
			path = rest,
		}
		return rest != ""
	case:
		return false
	}
	return true
}

voiceLoopbackMain :: proc(args: []string) -> int {
	config := VoiceEngineConfig {
		source = {kind = .Device},
		sink = {kind = .Device},
		loopback = true,
	}
	seconds := VOICE_LOOPBACK_DEFAULT_SECONDS
	alwaysOn := false
	for index := 0; index < len(args); index += 1 {
		arg := args[index]
		value := index + 1 < len(args) ? args[index + 1] : ""
		ok := true
		switch arg {
		case VOICE_LOOPBACK_FLAG:
			continue
		case "--always-on":
			alwaysOn = true
			continue
		case "--help", "-h":
			fmt.println(VOICE_LOOPBACK_USAGE)
			return 0
		case "--seconds":
			parsed, parsedOK := strconv.parse_int(value)
			ok = parsedOK && parsed > 0 && parsed <= VOICE_LOOPBACK_MAX_SECONDS
			seconds = parsed
		case "--source":
			ok = voiceLoopbackParseSource(value, &config.source)
		case "--sink":
			ok = voiceLoopbackParseSink(value, &config.sink)
		case "--loss":
			parsed, parsedOK := strconv.parse_int(value)
			ok = parsedOK && parsed >= 0 && parsed <= 90
			config.loopbackFaults = {
				lossPercent = parsed,
				seed        = u64(time.time_to_unix_nano(time.now())),
			}
		case "--threshold":
			parsed, parsedOK := strconv.parse_f32(value)
			ok = parsedOK && parsed >= -100 && parsed < 0
			config.vadThresholdDB = parsed
		case:
			ok = false
		}
		if !ok {
			fmt.eprintfln("[Error] bad voice loopback option: %s %s", arg, value)
			fmt.eprintln(VOICE_LOOPBACK_USAGE)
			return 1
		}
		index += 1
	}
	if alwaysOn {
		config.gateMode = .PushToTalk
	}

	engine := VoiceEngine_create(config)
	defer VoiceEngine_destroy(engine)
	VoiceEngine_setPushToTalk(engine, alwaysOn)
	if !VoiceEngine_start(engine) {
		fmt.eprintln("[Error] voice loopback:", VoiceEngine_lastError(engine))
		return 1
	}
	if engine.deviceFallback {
		fmt.eprintln("[Warn] a named audio device was not found; using the system default")
	}
	fmt.eprintfln("[Info] voice loopback for %d s; speak into the microphone", seconds)
	for second in 1 ..= seconds {
		time.sleep(time.Second)
		level, transmitting := VoiceEngine_inputLevel(engine)
		fmt.eprintfln(
			"[Info] %3d s  input %6.1f dBFS  %s",
			second,
			level,
			transmitting ? "sending" : "gated",
		)
	}
	snapshot := VoiceEngine_snapshot(engine)
	VoiceEngine_stop(engine)
	stats := snapshot.stats
	jitter := snapshot.jitter
	fmt.printfln(
		`{{"result":"voice-loopback","captured":%d,"sent":%d,"gated":%d,"captureDropped":%d,` +
		`"loopbackDropped":%d,"decoded":%d,"fec":%d,"plc":%d,"late":%d,"decodeErrors":%d}}`,
		stats.framesCaptured,
		stats.framesSent,
		stats.framesGated,
		stats.captureDropped,
		stats.loopbackDropped,
		stats.framesDecoded,
		jitter.fec,
		jitter.plc,
		jitter.late,
		stats.decodeErrors,
	)
	return 0
}
