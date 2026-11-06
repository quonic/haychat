#!/usr/bin/env python3
"""Analysis for dev/voice-manual-test.sh (voice-rooms-design.md 6.3 and 6.4).

Every input is a raw F32LE stereo 48 kHz "probe" recording made by one pw-record process:
channel 0 is what client A's virtual microphone carried, channel 1 is what client B played.
Both channels come from the same PipeWire graph cycle, so their time difference is the
mouth-to-ear delay through HayChat (capture, gate, Opus, server relay, jitter buffer, decode,
SDL playback queue), without the sound card's own buffers.

Subcommands, each printing indented human lines and one final `RESULT key=value ...` line:

  latency FILE   onsets of a click train in both channels; delay per click, p50 and p95
  speech FILE --clean CLEAN
                 per 10 ms frame, which speech frames of the clean (noise-free) speech reached
                 B, which word starts and ends were clipped, and how much non-speech passed
  tone FILE      dropouts (runs of digital silence) inside the tone B played

Run it with `python3 -I` (no user site, no script directory on the path). Needs numpy.
"""

import argparse
import sys

try:
    import numpy as np
except ImportError:  # The shell script checks for numpy first; this is for direct use.
    print("voice-manual-analyze: numpy is not installed", file=sys.stderr)
    sys.exit(2)

RATE = 48000
FRAME = 480  # 10 ms analysis frames: half the codec frame, so clipping shows to 10 ms
FLOOR_DB = -100.0
# Output frames at or below this are digital silence: nothing was played. Opus-decoded
# noise, even quiet, is far above it.
SILENT_DB = -90.0


def readProbe(path, channels=2):
    data = np.fromfile(path, dtype="<f4")
    usable = len(data) - len(data) % channels
    return data[:usable].reshape(-1, channels).T.astype(np.float64)


def frameLevels(signal):
    count = len(signal) // FRAME
    if count == 0:
        return np.zeros(0)
    frames = signal[: count * FRAME].reshape(count, FRAME)
    rms = np.sqrt(np.mean(frames * frames, axis=1))
    with np.errstate(divide="ignore"):
        levels = 20 * np.log10(np.maximum(rms, 1e-10))
    return np.maximum(levels, FLOOR_DB)


def percentile(values, q):
    return float(np.percentile(np.asarray(values), q)) if len(values) else float("nan")


def onsets(signal, threshold, minQuietSeconds):
    """Sample indices where |signal| first crosses threshold after minQuietSeconds below it."""
    loud = np.flatnonzero(np.abs(signal) >= threshold)
    if len(loud) == 0:
        return []
    minQuiet = int(minQuietSeconds * RATE)
    result = [int(loud[0])]
    gaps = np.diff(loud)
    for index in np.flatnonzero(gaps >= minQuiet):
        result.append(int(loud[index + 1]))
    return result


def bestLag(reference, delayed, maxLagSeconds):
    """Lag (in samples, >= 0) that best aligns delayed with reference, by cross-correlating
    their 10 ms envelopes and then refining on the samples around it."""
    refEnv = np.sqrt(np.mean(reference[: len(reference) // FRAME * FRAME]
                             .reshape(-1, FRAME) ** 2, axis=1))
    delEnv = np.sqrt(np.mean(delayed[: len(delayed) // FRAME * FRAME]
                             .reshape(-1, FRAME) ** 2, axis=1))
    size = 1
    while size < len(refEnv) + len(delEnv):
        size *= 2
    corr = np.fft.irfft(np.fft.rfft(delEnv, size) * np.conj(np.fft.rfft(refEnv, size)), size)
    maxLag = min(int(maxLagSeconds * RATE / FRAME), len(delEnv) - 1)
    coarse = int(np.argmax(corr[: maxLag + 1]))
    # Refine to the sample within one frame either side.
    lo = max(0, (coarse - 1) * FRAME)
    hi = (coarse + 1) * FRAME
    window = min(len(reference), len(delayed) - hi) - 1
    if window <= RATE // 10:
        return coarse * FRAME
    best, bestScore = lo, -np.inf
    ref = reference[:window]
    for lag in range(lo, hi + 1, 8):
        score = float(np.dot(ref, delayed[lag: lag + window]))
        if score > bestScore:
            best, bestScore = lag, score
    return best


def cmdLatency(args):
    source, played = readProbe(args.file)
    sourceOnsets = onsets(source, args.threshold, args.min_quiet)
    playedOnsets = np.array(onsets(played, args.threshold, args.min_quiet))
    delays = []
    for onset in sourceOnsets:
        later = playedOnsets[(playedOnsets >= onset) &
                             (playedOnsets < onset + int(args.max_delay * RATE))]
        if len(later):
            delays.append((later[0] - onset) * 1000.0 / RATE)
    print(f"    clicks: {len(sourceOnsets)} sent, {len(delays)} heard "
          f"(onset threshold {args.threshold}, search window {args.max_delay * 1000:.0f} ms)")
    if delays:
        print("    delay per click (ms): " + " ".join(f"{d:.0f}" for d in delays))
        print(f"    mouth-to-ear: p50 {percentile(delays, 50):.1f} ms, "
              f"p95 {percentile(delays, 95):.1f} ms, min {min(delays):.1f} ms, "
              f"max {max(delays):.1f} ms")
    print(f"RESULT sent={len(sourceOnsets)} heard={len(delays)} "
          f"p50={percentile(delays, 50):.1f} p95={percentile(delays, 95):.1f} "
          f"min={min(delays) if delays else float('nan'):.1f} "
          f"max={max(delays) if delays else float('nan'):.1f}")
    return 0 if delays and len(delays) >= len(sourceOnsets) * 0.9 else 1


def runs(mask):
    """(start, end) frame index pairs of the True runs in mask, end exclusive."""
    padded = np.concatenate(([False], mask, [False]))
    edges = np.flatnonzero(np.diff(padded.astype(np.int8)))
    return list(zip(edges[0::2], edges[1::2]))


def cmdSpeech(args):
    source, played = readProbe(args.file)
    clean = np.fromfile(args.clean, dtype="<f4").astype(np.float64)
    # Where the clean speech sits in the probe: the material was played some time after the
    # recording started.
    offset = bestLag(clean, source, maxLagSeconds=10.0)
    lag = bestLag(source, played, maxLagSeconds=args.max_delay)
    count = min(len(clean) // FRAME, (len(source) - offset) // FRAME,
                (len(played) - offset - lag) // FRAME)
    if count <= 0:
        print("    speech: the recording is shorter than the speech", file=sys.stderr)
        print("RESULT error=short")
        return 1
    cleanDB = frameLevels(clean[: count * FRAME])
    sourceDB = frameLevels(source[offset: offset + count * FRAME])
    playedDB = frameLevels(played[offset + lag: offset + lag + count * FRAME])

    # The background: A's mic where the clean material is silent (the pauses).
    pauses = cleanDB <= FLOOR_DB + 1
    noiseDB = 10 * np.log10(np.mean(10 ** (sourceDB[pauses] / 10))) if pauses.any() \
        else FLOOR_DB
    # Speech frames: the clean speech within 40 dB of its loudest frame (the quietest sounds
    # a listener notices in a word, breathy starts and final consonants, sit 30-40 dB under
    # its peak) and not under the background, which masks it anyway.
    cleanAtMicDB = cleanDB + (sourceDB.max() - cleanDB.max())
    speech = (cleanDB >= cleanDB.max() - 40.0) & (cleanAtMicDB >= noiseDB)
    passed = playedDB > SILENT_DB
    activeDB = 10 * np.log10(np.mean(10 ** (sourceDB[speech] / 10)))
    aboveThreshold = sourceDB >= args.threshold

    # Words: speech runs merged across gaps shorter than 150 ms (the gaps inside a word or
    # between words of a phrase). Phrases: merged across gaps shorter than the hangover.
    def merged(mask, gapFrames):
        result = mask.copy()
        for start, end in runs(~mask):
            if start > 0 and end < len(mask) and end - start < gapFrames:
                result[start:end] = True
        return result

    words = runs(merged(speech, 15))
    startClips, endClips = [], []
    for start, end in words:
        segment = passed[start:end] & speech[start:end]
        speechIdx = np.flatnonzero(speech[start:end])
        firstPassed = np.flatnonzero(segment)
        if len(firstPassed) == 0:
            startClips.append(len(speechIdx) * 10)
            endClips.append(0)
            continue
        startClips.append(int(np.sum(speechIdx < firstPassed[0])) * 10)
        endClips.append(int(np.sum(speechIdx > firstPassed[-1])) * 10)
    clippedStarts = sum(1 for c in startClips if c > args.clip_ms)
    clippedEnds = sum(1 for c in endClips if c > args.clip_ms)

    # Non-speech that passed: frames away from any speech by more than the hangover plus
    # one codec frame, which a well-behaved gate never sends.
    nearSpeech = np.zeros(count, dtype=bool)
    guard = args.hangover_ms // 10 + 4
    for start, end in runs(speech):
        nearSpeech[max(0, start - 4): min(count, end + guard)] = True
    farSilence = ~nearSpeech
    noisePassed = int(np.sum(passed & farSilence))

    speechPassed = int(np.sum(passed & speech))
    speechTotal = int(np.sum(speech))
    print(f"    level: speech {activeDB:.1f} dBFS (mean power over speech frames, A's mic), "
          f"background {noiseDB:.1f} dBFS; gate threshold {args.threshold:.0f} dBFS")
    print(f"    speech frames above the threshold at A: "
          f"{int(np.sum(aboveThreshold & speech))} of {speechTotal}")
    print(f"    speech frames heard at B: {speechPassed} of {speechTotal} "
          f"({100.0 * speechPassed / max(speechTotal, 1):.1f} %), aligned at "
          f"{lag * 1000.0 / RATE:.0f} ms")
    print(f"    words: {len(words)}; start clipped >{args.clip_ms} ms: {clippedStarts} "
          f"(mean {np.mean(startClips) if startClips else 0:.0f} ms, max "
          f"{max(startClips) if startClips else 0} ms); end clipped >{args.clip_ms} ms: "
          f"{clippedEnds} (max {max(endClips) if endClips else 0} ms)")
    print(f"    non-speech sent beyond the hangover: {noisePassed * 10} ms of "
          f"{int(np.sum(farSilence)) * 10} ms")
    print(f"RESULT level={activeDB:.1f} noise={noiseDB:.1f} "
          f"speechPassedPct={100.0 * speechPassed / max(speechTotal, 1):.1f} "
          f"words={len(words)} startClipped={clippedStarts} endClipped={clippedEnds} "
          f"meanStartClipMS={np.mean(startClips) if startClips else 0:.0f} "
          f"maxEndClipMS={max(endClips) if endClips else 0} "
          f"noisePassedMS={noisePassed * 10} lagMS={lag * 1000.0 / RATE:.0f}")
    return 0


def cmdTone(args):
    _, played = readProbe(args.file)
    loud = np.flatnonzero(np.abs(played) >= args.threshold)
    if len(loud) == 0:
        print("    tone: B played nothing")
        print("RESULT dropouts=-1 longestMS=0")
        return 1
    # Inside the tone (first to last loud sample, minus 100 ms each end), a dropout is a run
    # of at least 1 ms with every sample under 1e-4: an empty playout queue, not a zero
    # crossing (a 440 Hz tone at 0.5 crosses zero far faster than that).
    start, end = loud[0] + RATE // 10, loud[-1] - RATE // 10
    quiet = np.abs(played[start:end]) < 1e-4
    minRun = RATE // 1000
    dropouts = [(b - a) for a, b in runs(quiet) if b - a >= minRun]
    longest = max(dropouts) * 1000.0 / RATE if dropouts else 0.0
    print(f"    playout dropouts inside the tone ({(end - start) / RATE:.1f} s): "
          f"{len(dropouts)}, longest {longest:.1f} ms")
    print(f"RESULT dropouts={len(dropouts)} longestMS={longest:.1f}")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    latency = sub.add_parser("latency")
    latency.add_argument("file")
    latency.add_argument("--threshold", type=float, default=0.05)
    latency.add_argument("--min-quiet", type=float, default=0.2)
    latency.add_argument("--max-delay", type=float, default=0.9)
    speech = sub.add_parser("speech")
    speech.add_argument("file")
    speech.add_argument("--clean", required=True)
    speech.add_argument("--threshold", type=float, default=-45.0)
    speech.add_argument("--hangover-ms", type=int, default=300)
    speech.add_argument("--clip-ms", type=int, default=20)
    speech.add_argument("--max-delay", type=float, default=1.0)
    tone = sub.add_parser("tone")
    tone.add_argument("file")
    tone.add_argument("--threshold", type=float, default=0.05)
    args = parser.parse_args()
    handlers = {"latency": cmdLatency, "speech": cmdSpeech, "tone": cmdTone}
    return handlers[args.command](args)


if __name__ == "__main__":
    sys.exit(main())
