package wasapi_probe

// wasapi-probe: the #172 spike's prototype of a Windows capture path of our own. It opens a
// capture endpoint through WASAPI in shared mode, sets the stream category with
// IAudioClient2::SetClientProperties (AudioCategory_Communications by default), records
// 48 kHz mono F32LE to a file like the harness's `voice-sink`, and reports what Windows
// does with the stream: the mix format, whether AUTOCONVERTPCM is needed, the periods and
// latency, the effects the stream gets (IAudioEffectsManager, Windows 11) with each
// category, and whether IAcousticEchoCancellationControl accepts the render endpoint SDL
// plays to. Playback stays on SDL: --play-tone plays a tone through SDL's playback device
// during the capture, so the recording shows how much of it the stream's echo canceller
// removes (check it with dev/tools/voice-check).
//
//   wasapi-probe --list
//   wasapi-probe --out mic.f32 --seconds 10 --play-tone 440
//
// Findings and the manual checklist: docs/plan/2026-11-25-wasapi-communications-capture.md.
// Builds and runs on Windows only; on other systems it says so and exits 2. Build:
//   odin build dev/tools/wasapi-probe -target:windows_amd64 -linker:lld \
//       -windows-sdk-root:SYSROOT -out:wasapi-probe.exe   (cross, as deploy/release-artifacts.sh)
//   odin build dev/tools/wasapi-probe -out:wasapi-probe.exe   (on Windows with MSVC)
// and put SDL3.dll (from Odin's vendor/sdl3) next to the executable.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

EXIT_OK :: 0
EXIT_FAILED :: 1
EXIT_USAGE :: 2

SAMPLE_RATE :: 48000
DEFAULT_SECONDS :: 5
DEFAULT_PROBE_SECONDS :: 1
MAX_SECONDS :: 3600
DEFAULT_TONE_AMPLITUDE :: 0.25

USAGE ::
	"usage: wasapi-probe [--list] [--device NAME|ID] [--default-role console|communications]\n" +
	"                    [--render NAME|ID] [--echo-reference render|windows]\n" +
	"                    [--category NAME] [--raw] [--no-autoconvert]\n" +
	"                    [--seconds S] [--probe-seconds S] [--out FILE]\n" +
	"                    [--play-tone HZ] [--tone-amplitude A]\n" +
	"  --list              list capture and render endpoints and stop\n" +
	"  --device NAME|ID    capture endpoint by friendly name or endpoint ID\n" +
	"                      (default: the default capture endpoint of --default-role)\n" +
	"  --default-role R    console (what SDL follows, the default) or communications\n" +
	"  --render NAME|ID    the echo reference: SDL's playback endpoint (default: the default\n" +
	"                      console render endpoint, which SDL's default playback device is)\n" +
	"  --echo-reference R  what the main capture's echo canceller listens to: render (the\n" +
	"                      --render endpoint, the default) or windows (Windows' own choice)\n" +
	"  --category NAME     category of the main capture: communications (default), other,\n" +
	"                      speech, gamechat, media, movie\n" +
	"  --raw               add AUDCLNT_STREAMOPTIONS_RAW to the main capture\n" +
	"  --no-autoconvert    open the main capture in the mix format and convert in the tool\n" +
	"  --seconds S         length of the main capture (default 5, 0 for none)\n" +
	"  --probe-seconds S   capture per category in the comparison (default 1, 0 for none)\n" +
	"  --out FILE          write the main capture as raw F32LE mono 48 kHz\n" +
	"  --play-tone HZ      play a tone through SDL during the main capture (echo test)\n" +
	"  --tone-amplitude A  its amplitude, 0 to 1 (default 0.25)\n"

DefaultRole :: enum {
	Console,
	Communications,
}

EchoReference :: enum {
	Render,
	Windows,
}

// Options are the parsed command line. Strings borrow the arguments.
Options :: struct {
	list:          bool,
	device:        string,
	defaultRole:   DefaultRole,
	render:        string,
	echoReference: EchoReference,
	category:      StreamCategory,
	raw:           bool,
	autoconvert:   bool,
	seconds:       f64,
	probeSeconds:  f64,
	outPath:       string,
	toneHz:        f64,
	toneAmplitude: f64,
}

defaultOptions :: proc() -> Options {
	return Options {
		category = .Communications,
		autoconvert = true,
		seconds = DEFAULT_SECONDS,
		probeSeconds = DEFAULT_PROBE_SECONDS,
		toneAmplitude = DEFAULT_TONE_AMPLITUDE,
	}
}

// parseArgs reads the arguments after the program name. The error is a static string.
parseArgs :: proc(args: []string) -> (options: Options, err: string) {
	options = defaultOptions()
	index := 0
	value :: proc(args: []string, index: ^int) -> (string, bool) {
		if index^ + 1 >= len(args) {
			return "", false
		}
		index^ += 1
		return args[index^], true
	}
	for index < len(args) {
		arg := args[index]
		switch arg {
		case "--list":
			options.list = true
		case "--raw":
			options.raw = true
		case "--no-autoconvert":
			options.autoconvert = false
		case "--device", "--render", "--out", "--default-role", "--category", "--echo-reference":
			text, ok := value(args, &index)
			if !ok || text == "" {
				return options, "missing value after an option"
			}
			switch arg {
			case "--device":
				options.device = text
			case "--render":
				options.render = text
			case "--out":
				options.outPath = text
			case "--default-role":
				switch strings.to_lower(text, context.temp_allocator) {
				case "console":
					options.defaultRole = .Console
				case "communications":
					options.defaultRole = .Communications
				case:
					return options, "--default-role must be console or communications"
				}
			case "--echo-reference":
				switch strings.to_lower(text, context.temp_allocator) {
				case "render":
					options.echoReference = .Render
				case "windows":
					options.echoReference = .Windows
				case:
					return options, "--echo-reference must be render or windows"
				}
			case "--category":
				category, known := streamCategoryFromName(text)
				if !known {
					return options, "unknown --category"
				}
				options.category = category
			}
		case "--seconds", "--probe-seconds", "--play-tone", "--tone-amplitude":
			text, ok := value(args, &index)
			if !ok {
				return options, "missing value after an option"
			}
			number, parsed := strconv.parse_f64(text)
			if !parsed || number != number {
				return options, "expected a number"
			}
			switch arg {
			case "--seconds", "--probe-seconds":
				if number < 0 || number > MAX_SECONDS {
					return options, "seconds must be between 0 and 3600"
				}
				if arg == "--seconds" {
					options.seconds = number
				} else {
					options.probeSeconds = number
				}
			case "--play-tone":
				if number < 20 || number > 20000 {
					return options, "--play-tone must be between 20 and 20000 Hz"
				}
				options.toneHz = number
			case "--tone-amplitude":
				if number <= 0 || number > 1 {
					return options, "--tone-amplitude must be above 0 and at most 1"
				}
				options.toneAmplitude = number
			}
		case "-h", "--help":
			return options, "help"
		case:
			return options, "unknown argument"
		}
		index += 1
	}
	if options.toneHz > 0 && options.seconds == 0 {
		return options, "--play-tone needs a main capture (--seconds above 0)"
	}
	return options, ""
}

main :: proc() {
	options, err := parseArgs(os.args[1:])
	if err != "" {
		if err != "help" {
			fmt.eprintln("wasapi-probe:", err)
		}
		fmt.eprint(USAGE)
		os.exit(err == "help" ? EXIT_OK : EXIT_USAGE)
	}
	os.exit(run(options))
}
