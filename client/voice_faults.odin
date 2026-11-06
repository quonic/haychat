package client

// Test-only network faults in the voice receive path (voice-rooms-design.md 6.5). Rootless CI
// cannot use netem, so a client built with -define:HAYCHAT_TEST_FAULTS=true drops and delays
// the frames its engine receives, as a lossy, jittery network would:
//
//   HAYCHAT_TEST_VOICE_LOSS=0.05      the fraction of received frames dropped (0..1)
//   HAYCHAT_TEST_VOICE_JITTER_MS=20   each kept frame is held for a uniformly random
//                                     0..N ms before it reaches the jitter buffer, so
//                                     frames also arrive out of order (0..500)
//   HAYCHAT_TEST_VOICE_SEED=1         the generator's seed (default 1)
//
// The generator is splitmix64 (voiceNextRandom), drawn once per frame for loss and once per
// kept frame for delay, in arrival order, so one sender gives the same loss pattern on every
// run. The faults apply on the voice thread as frames leave the inbound queue, after the
// network worker counted them as delivered, and are counted in VoiceEngineStats
// (faultDropped, faultDelayed).
//
// Without the define none of this is compiled: VoiceReceiveFaults is an empty struct, the
// environment is never read, and VoiceEngine_drainInbound has no fault branch.

import "core:fmt"
import "core:os"
import "core:strconv"

HAYCHAT_TEST_FAULTS :: #config(HAYCHAT_TEST_FAULTS, false)

// Normal builds use none of these imports.
_ :: fmt
_ :: os
_ :: strconv

when HAYCHAT_TEST_FAULTS {
	VOICE_FAULT_MAX_JITTER_MS :: 500.0
	VOICE_FAULT_DEFAULT_SEED :: u64(1)

	VoiceHeldFrame :: struct {
		dueMS: f64,
		frame: VoiceInboundFrame,
	}

	VoiceReceiveFaults :: struct {
		enabled:      bool,
		lossFraction: f64,
		jitterMS:     f64,
		random:       u64,
		held:         [VOICE_INBOUND_CAPACITY]VoiceHeldFrame,
		heldCount:    int,
	}

	VoiceFaultDecision :: enum u8 {
		Deliver,
		Drop,
		Hold,
	}

	// Reads the fault settings from the environment. An unset or invalid value means no
	// fault of that kind; an invalid one is reported once on stderr so a proof run that
	// mistyped it does not silently test nothing.
	VoiceReceiveFaults_initFromEnvironment :: proc(faults: ^VoiceReceiveFaults) {
		faults^ = {}
		faults.lossFraction = voiceFaultEnvNumber("HAYCHAT_TEST_VOICE_LOSS", 0, 1)
		faults.jitterMS = voiceFaultEnvNumber(
			"HAYCHAT_TEST_VOICE_JITTER_MS",
			0,
			VOICE_FAULT_MAX_JITTER_MS,
		)
		seed := VOICE_FAULT_DEFAULT_SEED
		if text := os.get_env("HAYCHAT_TEST_VOICE_SEED", context.temp_allocator); len(text) > 0 {
			if value, ok := strconv.parse_u64(text); ok {
				seed = value
			} else {
				fmt.eprintfln("voice faults: ignoring HAYCHAT_TEST_VOICE_SEED=%q", text)
			}
		}
		faults.random = seed
		faults.enabled = faults.lossFraction > 0 || faults.jitterMS > 0
	}

	@(private = "file")
	voiceFaultEnvNumber :: proc(name: string, low, high: f64) -> f64 {
		text := os.get_env(name, context.temp_allocator)
		if len(text) == 0 {
			return 0
		}
		value, ok := strconv.parse_f64(text)
		if !ok || value < low || value > high {
			fmt.eprintfln(
				"voice faults: ignoring %s=%q (expected %v to %v)",
				name,
				text,
				low,
				high,
			)
			return 0
		}
		return value
	}

	// A uniform number in [0, 1) from the top 53 bits.
	@(private = "file")
	voiceFaultUnit :: proc(faults: ^VoiceReceiveFaults) -> f64 {
		return f64(voiceNextRandom(&faults.random) >> 11) / f64(u64(1) << 53)
	}

	// Decides one frame's fate. A held frame is copied into the queue; when the queue is
	// full the frame is delivered at once instead, which only shortens its delay.
	VoiceReceiveFaults_admit :: proc(
		faults: ^VoiceReceiveFaults,
		frame: ^VoiceInboundFrame,
		now: f64,
	) -> VoiceFaultDecision {
		if faults.lossFraction > 0 && voiceFaultUnit(faults) < faults.lossFraction {
			return .Drop
		}
		if faults.jitterMS <= 0 {
			return .Deliver
		}
		delay := voiceFaultUnit(faults) * faults.jitterMS
		if faults.heldCount == len(faults.held) {
			return .Deliver
		}
		faults.held[faults.heldCount] = {
			dueMS = now + delay,
			frame = frame^,
		}
		faults.heldCount += 1
		return .Hold
	}

	// Takes the earliest held frame that is due by now into out. Returns false when none is.
	VoiceReceiveFaults_release :: proc(
		faults: ^VoiceReceiveFaults,
		now: f64,
		out: ^VoiceInboundFrame,
	) -> bool {
		earliest := -1
		for index in 0 ..< faults.heldCount {
			held := &faults.held[index]
			if held.dueMS <= now && (earliest < 0 || held.dueMS < faults.held[earliest].dueMS) {
				earliest = index
			}
		}
		if earliest < 0 {
			return false
		}
		out^ = faults.held[earliest].frame
		faults.heldCount -= 1
		faults.held[earliest] = faults.held[faults.heldCount]
		return true
	}

	VoiceReceiveFaults_clear :: proc(faults: ^VoiceReceiveFaults) {
		faults.heldCount = 0
	}
} else {
	VoiceReceiveFaults :: struct {}
}
