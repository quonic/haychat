package client

import "core:testing"

// Normal builds carry no fault state at all: the hook is absent, not merely switched off.
@(test)
testVoiceReceiveFaultsAreAbsentFromNormalBuilds :: proc(t: ^testing.T) {
	when HAYCHAT_TEST_FAULTS {
		testing.expect(t, size_of(VoiceReceiveFaults) > 0, "expected fault state in this build")
	} else {
		testing.expectf(
			t,
			size_of(VoiceReceiveFaults) == 0,
			"expected an empty fault struct, got %d bytes",
			size_of(VoiceReceiveFaults),
		)
	}
}

// check.sh runs this one in a HAYCHAT_TEST_FAULTS build: the loss share, the delay bound,
// the release order and the seed's reproducibility.
@(test)
testVoiceReceiveFaultsDropAndDelayDeterministically :: proc(t: ^testing.T) {
	when HAYCHAT_TEST_FAULTS {
		FRAMES :: 4000
		run :: proc(seed: u64, decisions: ^[FRAMES]VoiceFaultDecision) -> (dropped, held: int) {
			faults := new(VoiceReceiveFaults)
			defer free(faults)
			faults^ = {
				enabled      = true,
				lossFraction = 0.05,
				jitterMS     = 20,
				random       = seed,
			}
			frame: VoiceInboundFrame
			released: VoiceInboundFrame
			for index in 0 ..< FRAMES {
				now := f64(index) * VOICE_FRAME_MS
				for VoiceReceiveFaults_release(faults, now, &released) {
				}
				frame.frameSequence = u32(index)
				decisions[index] = VoiceReceiveFaults_admit(faults, &frame, now)
				switch decisions[index] {
				case .Drop:
					dropped += 1
				case .Hold:
					held += 1
				case .Deliver:
				}
			}
			return
		}
		first := new([FRAMES]VoiceFaultDecision)
		defer free(first)
		second := new([FRAMES]VoiceFaultDecision)
		defer free(second)
		dropped, held := run(7, first)
		_, _ = run(7, second)
		testing.expect(t, first^ == second^, "expected the same seed to give the same pattern")
		testing.expectf(
			t,
			dropped > FRAMES * 4 / 100 && dropped < FRAMES * 6 / 100,
			"expected about 5 %% of %d frames dropped, got %d",
			FRAMES,
			dropped,
		)
		testing.expectf(t, held == FRAMES - dropped, "expected every kept frame held, %d", held)
		_, _ = run(8, second)
		testing.expect(t, first^ != second^, "expected another seed to give another pattern")

		// Held frames come out by the jitter bound, and the earliest due first: whatever is
		// still held after a release pass is due later.
		faults := new(VoiceReceiveFaults)
		defer free(faults)
		faults^ = {enabled = true, jitterMS = 20, random = 3}
		frame: VoiceInboundFrame
		for sequence in u32(0) ..< 50 {
			frame.frameSequence = sequence
			testing.expect(
				t,
				VoiceReceiveFaults_admit(faults, &frame, 0) == .Hold,
				"expected every frame held with no loss",
			)
		}
		released: VoiceInboundFrame
		testing.expect(t, faults.heldCount == 50, "expected 50 held frames")
		count := 0
		for now := 0.0; now <= 20; now += 0.5 {
			for VoiceReceiveFaults_release(faults, now, &released) {
				count += 1
			}
			for held in faults.held[:faults.heldCount] {
				testing.expectf(
					t,
					held.dueMS > now,
					"expected a frame due at %f to be released by %f",
					held.dueMS,
					now,
				)
			}
		}
		testing.expectf(t, count == 50, "expected all 50 released within 20 ms, got %d", count)
	} else {
		_ = t
	}
}
