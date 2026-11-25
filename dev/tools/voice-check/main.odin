package voice_check

// voice-check: checks a recorded voice file for a test tone, with the same Goertzel analysis
// the client's voice tests use (client/toneanalysis, voice-rooms-design.md 6.1 and 6.2), so
// the live voice proof needs neither sox nor numpy.
//
//   odin run dev/tools/voice-check -- FILE --freq 440 --tolerance 5 --min-seconds 3
//   odin run dev/tools/voice-check -- --write-tone FILE --freq 440 --seconds 8
//   odin run dev/tools/voice-check -- --write-noisy-tone FILE --freq 440 --seconds 30
//   odin run dev/tools/voice-check -- FILE --freq 440 --min-seconds 1 --max-floor -60
//
// The noisy tone (#170, noise suppression) is tone bursts (--burst seconds on, --gap seconds
// off) over white noise at --noise-db dBFS RMS, from a fixed seed (toneanalysis.NoisyTone).
// --max-floor and --min-floor check the recording's noise floor: the 25th percentile of its
// 20 ms block levels between the first and last tone-loud block, which lies in the gaps.
//
// Files are raw F32LE samples at 48 kHz, the format of the client's file sink and source
// (mono) and of SDL's disk audio driver (interleaved, so pass --channels 2 for a playback
// device's output; the first channel is analysed). It prints one line with the measured
// frequency, level and SNR, and exits 0 when the tone passes, 1 when it does not, and 2 on a
// usage or file error.

import "../../../client/toneanalysis"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strconv"

EXIT_PASS :: 0
EXIT_FAIL :: 1
EXIT_USAGE :: 2
DEFAULT_RATE :: 48000
DEFAULT_AMPLITUDE :: 0.5
MAX_CHANNELS :: 8
MAX_TONE_SECONDS :: 600
FREQ_RANGE_ERROR :: "--freq must be inside the analyser's scan range (50 to 4050 Hz)"
#assert(toneanalysis.SCAN_MIN_HZ == 50 && toneanalysis.SCAN_MAX_HZ == 4050, "update USAGE")

USAGE ::
	"usage: voice-check FILE --freq HZ [--tolerance HZ] [--min-seconds S] [--amplitude A]\n" +
	"                   [--level-tolerance DB] [--min-snr DB] [--channels N] [--rate HZ]\n" +
	"                   [--max-floor DB] [--min-floor DB]\n" +
	"       voice-check --write-tone FILE --freq HZ --seconds S [--amplitude A]\n" +
	"                   [--channels N] [--rate HZ]\n" +
	"       voice-check --write-noisy-tone FILE --freq HZ --seconds S [--amplitude A]\n" +
	"                   [--noise-db DB] [--burst S] [--gap S]\n" +
	"  FILE                raw F32LE samples (the client's file sink: mono, 48 kHz)\n" +
	"  --freq HZ           the expected tone, 50 to 4050 Hz (the analyser's scan range)\n" +
	"  --tolerance HZ      how far the dominant frequency may be off (default 5)\n" +
	"  --min-seconds S     the shortest stretch of tone that passes (default 1)\n" +
	"  --amplitude A       the source's peak amplitude, which sets the expected level\n" +
	"                      (default 0.5, -9 dBFS RMS)\n" +
	"  --level-tolerance DB  how far the RMS level may be off (default 6)\n" +
	"  --min-snr DB        the tone bin over the median bin (default 20)\n" +
	"  --channels N        interleaved channels in FILE (default 1; the first is used)\n" +
	"  --rate HZ           sample rate (default 48000)\n" +
	"  --write-tone FILE   write a tone instead (for SDL_AUDIO_DISK_INPUT_FILE)\n" +
	"  --write-noisy-tone FILE  write tone bursts over white noise instead (mono)\n" +
	"  --noise-db DB       the noise's RMS level (default -34 dBFS)\n" +
	"  --burst S, --gap S  seconds of tone, then of noise alone (default 1.5 and 1)\n" +
	"  --max-floor DB      fail when the noise floor between the bursts is above DB\n" +
	"  --min-floor DB      fail when it is below DB (the noise must be there)"

Options :: struct {
	path:           string,
	writeTone:      bool,
	freq:           f64,
	toleranceHz:    f64,
	minSeconds:     f64,
	amplitude:      f64,
	levelTolerance: f64,
	minSNR:         f64,
	channels:       int,
	rate:           f64,
	seconds:        f64,
	writeNoisyTone: bool,
	noiseDB:        f64,
	burstSeconds:   f64,
	gapSeconds:     f64,
	maxFloor:       Maybe(f64),
	minFloor:       Maybe(f64),
}

DEFAULT_NOISE_DB :: -34.0
DEFAULT_BURST_SECONDS :: 1.5
DEFAULT_GAP_SECONDS :: 1.0
// The noisy tone's seed; any fixed value works, this one names the issue.
NOISY_TONE_SEED :: 170

// Parses the arguments after the program name. Returns a static error message on failure.
parseOptions :: proc(args: []string) -> (options: Options, err: string) {
	options = {
		toleranceHz    = toneanalysis.TOLERANCE_HZ,
		minSeconds     = 1,
		amplitude      = DEFAULT_AMPLITUDE,
		levelTolerance = toneanalysis.RMS_TOLERANCE_DB,
		minSNR         = toneanalysis.MIN_SNR_DB,
		channels       = 1,
		rate           = DEFAULT_RATE,
		noiseDB        = DEFAULT_NOISE_DB,
		burstSeconds   = DEFAULT_BURST_SECONDS,
		gapSeconds     = DEFAULT_GAP_SECONDS,
	}
	for index := 0; index < len(args); index += 1 {
		arg := args[index]
		if len(arg) == 0 || arg[0] != '-' {
			if len(options.path) > 0 {
				return {}, "more than one FILE"
			}
			options.path = arg
			continue
		}
		if index + 1 >= len(args) {
			return {}, "missing value for an option"
		}
		index += 1
		value := args[index]
		if arg == "--write-tone" || arg == "--write-noisy-tone" {
			if len(options.path) > 0 {
				return {}, "more than one FILE"
			}
			options.path = value
			options.writeTone = true
			options.writeNoisyTone = arg == "--write-noisy-tone"
			continue
		}
		number, ok := strconv.parse_f64(value)
		if !ok {
			return {}, "option values must be numbers"
		}
		switch arg {
		case "--freq":
			ok = number > 0 && number < 24000
			options.freq = number
		case "--tolerance":
			ok = number > 0
			options.toleranceHz = number
		case "--min-seconds":
			ok = number >= 0
			options.minSeconds = number
		case "--amplitude":
			ok = number > 0 && number <= 1
			options.amplitude = number
		case "--level-tolerance":
			ok = number > 0
			options.levelTolerance = number
		case "--min-snr":
			ok = number > 0
			options.minSNR = number
		case "--channels":
			ok = number >= 1 && number <= MAX_CHANNELS && number == f64(int(number))
			options.channels = int(number)
		case "--rate":
			ok = number >= 8000 && number <= 192000
			options.rate = number
		case "--seconds":
			ok = number > 0 && number <= MAX_TONE_SECONDS
			options.seconds = number
		case "--noise-db":
			ok = number >= -120 && number < 0
			options.noiseDB = number
		case "--burst":
			ok = number > 0 && number <= MAX_TONE_SECONDS
			options.burstSeconds = number
		case "--gap":
			ok = number >= 0 && number <= MAX_TONE_SECONDS
			options.gapSeconds = number
		case "--max-floor":
			ok = number <= 0
			options.maxFloor = number
		case "--min-floor":
			ok = number <= 0
			options.minFloor = number
		case:
			return {}, "unknown option"
		}
		if !ok {
			return {}, "an option value is out of range"
		}
	}
	switch {
	case len(options.path) == 0:
		return {}, "missing FILE"
	case options.freq == 0:
		return {}, "--freq is required"
	case options.writeTone && options.seconds == 0:
		return {}, "--write-tone needs --seconds"
	case options.rate / 2 <= options.freq:
		return {}, "--freq must be below half of --rate"
	case !options.writeTone &&
	     (options.freq < toneanalysis.SCAN_MIN_HZ || options.freq > toneanalysis.SCAN_MAX_HZ):
		// The analyser only looks for the dominant tone in this band, so a check outside it
		// would always fail for a reason that has nothing to do with the recording.
		return {}, FREQ_RANGE_ERROR
	}
	return options, ""
}

writeToneFile :: proc(options: Options) -> int {
	frames := int(options.seconds * options.rate)
	mono := make([]f32, frames)
	defer delete(mono)
	if options.writeNoisyTone {
		toneanalysis.writeNoisyTone(
			mono,
			options.rate,
			{
				hz = options.freq,
				amplitude = options.amplitude,
				noiseRMSDB = options.noiseDB,
				burstSeconds = options.burstSeconds,
				gapSeconds = options.gapSeconds,
				seed = NOISY_TONE_SEED,
			},
		)
	} else {
		toneanalysis.writeTone(mono, options.rate, options.freq, options.amplitude)
	}
	samples := make([]f32, frames * options.channels)
	defer delete(samples)
	for sample, index in mono {
		for channel in 0 ..< options.channels {
			samples[index * options.channels + channel] = sample
		}
	}
	if err := os.write_entire_file(options.path, mem.slice_to_bytes(samples)); err != nil {
		fmt.eprintfln("voice-check: cannot write %s: %v", options.path, err)
		return EXIT_USAGE
	}
	fmt.printfln(
		"voice-check: wrote %.2f s of %.2f Hz at amplitude %.2f to %s " +
		"(F32LE, %d channel(s), %.0f Hz)",
		options.seconds,
		options.freq,
		options.amplitude,
		options.path,
		options.channels,
		options.rate,
	)
	return EXIT_PASS
}

checkFile :: proc(options: Options) -> int {
	bytes, readErr := os.read_entire_file_from_path(options.path, context.allocator)
	if readErr != nil {
		fmt.eprintfln("voice-check: cannot read %s: %v", options.path, readErr)
		return EXIT_USAGE
	}
	defer delete(bytes)
	interleaved := mem.slice_data_cast([]f32, bytes[:len(bytes) / 4 * 4])
	frames := len(interleaved) / options.channels
	samples := make([]f32, frames)
	defer delete(samples)
	for &sample, index in samples {
		sample = interleaved[index * options.channels]
	}

	expectedRMSDB := toneanalysis.sineRMSDB(options.amplitude)
	check := toneanalysis.checkRecording(
		samples,
		options.rate,
		{
			targetHz = options.freq,
			expectedRMSDB = expectedRMSDB,
			toleranceHz = options.toleranceHz,
			minSNRDB = options.minSNR,
			rmsToleranceDB = options.levelTolerance,
		},
		options.minSeconds,
	)
	activeLevel := expectedRMSDB - toneanalysis.ACTIVE_BELOW_EXPECTED_DB
	floorDB, floorBlocks := toneanalysis.noiseFloorDB(samples, options.rate, activeLevel)
	free_all(context.temp_allocator)
	floorFailure := ""
	if maxFloor, has := options.maxFloor.?; has && floorDB > maxFloor {
		floorFailure = "the noise floor between the bursts is above --max-floor"
	}
	if minFloor, has := options.minFloor.?; has && floorDB < minFloor {
		floorFailure = "the noise floor between the bursts is below --min-floor"
	}
	if check.passed && len(floorFailure) > 0 {
		check.passed = false
		check.failure = floorFailure
	}
	verdict := check.passed ? "PASS" : "FAIL"
	fmt.printfln(
		"voice-check: %s %s: %.2f s recorded, %.2f s of tone from %.2f s (%d run(s), " +
		"%d window(s)); %.2f Hz (worst %+.2f Hz, target %.2f ± %.2f); level %.2f dBFS " +
		"(expected %.2f ± %.2f); SNR %.1f dB (worst %.1f, min %.1f)",
		verdict,
		options.path,
		check.totalSeconds,
		check.toneSeconds,
		check.toneStart,
		check.runs,
		check.windows,
		check.dominantHz,
		check.worstOffsetHz,
		options.freq,
		options.toleranceHz,
		check.rmsDB,
		expectedRMSDB,
		options.levelTolerance,
		check.snrDB,
		check.worstSNRDB,
		options.minSNR,
	)
	if options.maxFloor != nil || options.minFloor != nil {
		fmt.printfln(
			"voice-check: noise floor %.2f dBFS over %d block(s) (max %v, min %v)",
			floorDB,
			floorBlocks,
			options.maxFloor,
			options.minFloor,
		)
	}
	if !check.passed {
		fmt.printfln("voice-check: %s (needs %.2f s of tone)", check.failure, options.minSeconds)
		return EXIT_FAIL
	}
	return EXIT_PASS
}

main :: proc() {
	options, err := parseOptions(os.args[1:])
	if len(err) > 0 {
		fmt.eprintln("voice-check:", err)
		fmt.eprintln(USAGE)
		os.exit(EXIT_USAGE)
	}
	status := options.writeTone ? writeToneFile(options) : checkFile(options)
	os.exit(status)
}
