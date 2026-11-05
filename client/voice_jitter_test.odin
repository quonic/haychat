package client

import "core:fmt"
import "core:testing"

// Each test frame's payload starts with its sequence's low byte, so a test can tell which
// frame JitterBuffer_next handed back.
@(private = "file")
jitterPush :: proc(jb: ^JitterBuffer, sequence: u32, flags: u8 = 0, arrivalMS: f64 = -1) -> bool {
	payload := [3]u8{u8(sequence), 0xAA, 0x55}
	arrival := arrivalMS >= 0 ? arrivalMS : f64(sequence) * VOICE_FRAME_MS
	return JitterBuffer_push(jb, sequence, flags, payload[:], arrival)
}

@(private = "file")
jitterExpect :: proc(
	jb: ^JitterBuffer,
	action: JitterAction,
	sequence: u32,
	loc := #caller_location,
) {
	output := JitterBuffer_next(jb)
	assert(
		output.action == action,
		fmt.tprintf(
			"expected %v at %d, got %v at %d",
			action,
			sequence,
			output.action,
			output.sequence,
		),
		loc,
	)
	if action == .Idle {
		return
	}
	assert(
		output.sequence == sequence,
		fmt.tprintf("expected sequence %d, got %d", sequence, output.sequence),
		loc,
	)
	switch action {
	case .Decode:
		assert(
			len(output.data) == 3 && output.data[0] == u8(sequence),
			fmt.tprintf("expected the payload of frame %d, got %v", sequence, output.data),
			loc,
		)
	case .DecodeFEC:
		assert(
			len(output.data) == 3 && output.data[0] == u8(sequence + 1),
			fmt.tprintf("expected FEC from frame %d, got %v", sequence + 1, output.data),
			loc,
		)
	case .Idle, .Silence, .Conceal:
		assert(output.data == nil, "expected no payload for silence or concealment", loc)
	}
}

@(private = "file")
jitterExpectPreroll :: proc(jb: ^JitterBuffer, firstSequence: u32, loc := #caller_location) {
	for offset in 0 ..< u32(jb.targetDepth) {
		jitterExpect(jb, .Silence, firstSequence - u32(jb.targetDepth) + offset, loc)
	}
}

@(test)
testJitterBufferPlaysInOrderFramesAfterPreroll :: proc(t: ^testing.T) {
	jb: JitterBuffer
	JitterBuffer_init(&jb)
	assert(JitterBuffer_next(&jb).action == .Idle, "expected an empty buffer to be idle")
	for sequence in u32(100) ..< 110 {
		assert(
			jitterPush(&jb, sequence),
			fmt.tprintf("expected frame %d to be accepted", sequence),
		)
	}
	assert(jb.targetDepth == JITTER_DEFAULT_DEPTH, "expected the default depth before adapting")
	jitterExpectPreroll(&jb, 100)
	for sequence in u32(100) ..< 110 {
		jitterExpect(&jb, .Decode, sequence)
	}
	// The sender went quiet without an end-of-spurt flag: conceal up to the limit, then play
	// silence until the spurt times out.
	for sequence in u32(110) ..< 110 + JITTER_MAX_PLC_RUN {
		jitterExpect(&jb, .Conceal, sequence)
	}
	for sequence in u32(110 + JITTER_MAX_PLC_RUN) ..< 110 + JITTER_SPURT_TIMEOUT_FRAMES {
		jitterExpect(&jb, .Silence, sequence)
	}
	jitterExpect(&jb, .Idle, 0)
	assert(!jb.inSpurt, "expected the spurt to time out")
	assert(
		jb.stats.played == 10 && jb.stats.plc == JITTER_MAX_PLC_RUN && jb.stats.spurts == 1,
		fmt.tprintf("unexpected stats %v", jb.stats),
	)
}

@(test)
testJitterBufferReordersFrames :: proc(t: ^testing.T) {
	jb: JitterBuffer
	JitterBuffer_init(&jb)
	for sequence in ([]u32{100, 102, 101, 104, 103}) {
		assert(
			jitterPush(&jb, sequence),
			fmt.tprintf("expected frame %d to be accepted", sequence),
		)
	}
	jitterExpectPreroll(&jb, 100)
	for sequence in u32(100) ..= 104 {
		jitterExpect(&jb, .Decode, sequence)
	}
	assert(jb.stats.fec == 0 && jb.stats.plc == 0, "expected reordering to cost nothing")
}

@(test)
testJitterBufferPlaysAnEarlierFrameThatArrivesDuringPreroll :: proc(t: ^testing.T) {
	jb: JitterBuffer
	JitterBuffer_init(&jb)
	assert(jitterPush(&jb, 100), "expected the first frame to start a spurt")
	// The real first frame of the spurt was overtaken by its successor.
	assert(jitterPush(&jb, 99), "expected an overtaken frame inside the pre-roll to be kept")
	jitterExpect(&jb, .Silence, 97)
	jitterExpect(&jb, .Silence, 98)
	jitterExpect(&jb, .Decode, 99)
	jitterExpect(&jb, .Decode, 100)
}

@(test)
testJitterBufferDropsDuplicates :: proc(t: ^testing.T) {
	jb: JitterBuffer
	JitterBuffer_init(&jb)
	assert(jitterPush(&jb, 100), "expected the first copy to be accepted")
	assert(!jitterPush(&jb, 100), "expected the duplicate to be dropped")
	assert(jitterPush(&jb, 101), "expected the next frame to be accepted")
	jitterExpectPreroll(&jb, 100)
	jitterExpect(&jb, .Decode, 100)
	jitterExpect(&jb, .Decode, 101)
	assert(
		jb.stats.duplicates == 1,
		fmt.tprintf("expected 1 duplicate, got %d", jb.stats.duplicates),
	)
}

@(test)
testJitterBufferDropsLateFrames :: proc(t: ^testing.T) {
	jb: JitterBuffer
	JitterBuffer_init(&jb)
	assert(jitterPush(&jb, 100), "expected the first frame to be accepted")
	assert(jitterPush(&jb, 102), "expected frame 102 to be accepted")
	jitterExpectPreroll(&jb, 100)
	jitterExpect(&jb, .Decode, 100)
	jitterExpect(&jb, .DecodeFEC, 101)
	// 101 arrives after its slot was played (rebuilt from FEC): too late.
	assert(!jitterPush(&jb, 101), "expected a frame behind the playout position to be late")
	assert(!jitterPush(&jb, 90), "expected an old frame to be late")
	jitterExpect(&jb, .Decode, 102)
	assert(jb.stats.late == 2, fmt.tprintf("expected 2 late frames, got %d", jb.stats.late))
}

@(test)
testJitterBufferRebuildsAGapFromTheNextFrame :: proc(t: ^testing.T) {
	jb: JitterBuffer
	JitterBuffer_init(&jb)
	for sequence in ([]u32{100, 101, 103, 104}) {
		_ = jitterPush(&jb, sequence)
	}
	jitterExpectPreroll(&jb, 100)
	jitterExpect(&jb, .Decode, 100)
	jitterExpect(&jb, .Decode, 101)
	jitterExpect(&jb, .DecodeFEC, 102)
	jitterExpect(&jb, .Decode, 103)
	jitterExpect(&jb, .Decode, 104)
	assert(jb.stats.fec == 1 && jb.stats.plc == 0, fmt.tprintf("unexpected stats %v", jb.stats))
}

@(test)
testJitterBufferConcealsAGapWithoutANextFrame :: proc(t: ^testing.T) {
	jb: JitterBuffer
	JitterBuffer_init(&jb)
	for sequence in ([]u32{100, 101, 105}) {
		_ = jitterPush(&jb, sequence)
	}
	jitterExpectPreroll(&jb, 100)
	jitterExpect(&jb, .Decode, 100)
	jitterExpect(&jb, .Decode, 101)
	jitterExpect(&jb, .Conceal, 102)
	jitterExpect(&jb, .Conceal, 103)
	jitterExpect(&jb, .DecodeFEC, 104)
	jitterExpect(&jb, .Decode, 105)
	assert(jb.stats.plc == 2 && jb.stats.fec == 1, fmt.tprintf("unexpected stats %v", jb.stats))
}

@(test)
testJitterBufferLimitsConcealmentInsideASpurt :: proc(t: ^testing.T) {
	jb: JitterBuffer
	JitterBuffer_init(&jb)
	_ = jitterPush(&jb, 100)
	_ = jitterPush(&jb, 109)
	jitterExpectPreroll(&jb, 100)
	jitterExpect(&jb, .Decode, 100)
	for sequence in u32(101) ..< 101 + JITTER_MAX_PLC_RUN {
		jitterExpect(&jb, .Conceal, sequence)
	}
	for sequence in u32(101 + JITTER_MAX_PLC_RUN) ..< 108 {
		jitterExpect(&jb, .Silence, sequence)
	}
	jitterExpect(&jb, .DecodeFEC, 108)
	jitterExpect(&jb, .Decode, 109)
	assert(jb.stats.silent == 2, fmt.tprintf("expected 2 silent frames, got %d", jb.stats.silent))
}

@(test)
testJitterBufferEndsAndRestartsSpurts :: proc(t: ^testing.T) {
	jb: JitterBuffer
	JitterBuffer_init(&jb)
	_ = jitterPush(&jb, 100)
	_ = jitterPush(&jb, 101, VOICE_FLAG_END_OF_SPURT)
	jitterExpectPreroll(&jb, 100)
	jitterExpect(&jb, .Decode, 100)
	jitterExpect(&jb, .Decode, 101)
	assert(!jb.inSpurt, "expected END_OF_SPURT to end the spurt")
	jitterExpect(&jb, .Idle, 0)
	jitterExpect(&jb, .Idle, 0)
	assert(!jitterPush(&jb, 99), "expected a straggler from the ended spurt to be late")
	// The sender's clock kept counting through the silence.
	assert(jitterPush(&jb, 150), "expected a new spurt to start")
	assert(jitterPush(&jb, 151), "expected the second frame of the new spurt")
	jitterExpectPreroll(&jb, 150)
	jitterExpect(&jb, .Decode, 150)
	jitterExpect(&jb, .Decode, 151)
	assert(jb.stats.spurts == 2, fmt.tprintf("expected 2 spurts, got %d", jb.stats.spurts))
	assert(jb.stats.plc == 0, "expected no concealment across the silence")
}

@(test)
testJitterBufferResetsOnAFarAheadFrame :: proc(t: ^testing.T) {
	jb: JitterBuffer
	JitterBuffer_init(&jb)
	_ = jitterPush(&jb, 100)
	_ = jitterPush(&jb, 101)
	jitterExpectPreroll(&jb, 100)
	// A restarted sender, or a stall longer than the ring.
	far := u32(100 + JITTER_SLOT_COUNT + 10)
	assert(jitterPush(&jb, far), "expected the far-ahead frame to restart the buffer")
	assert(jb.stats.resets == 1, "expected one reset")
	jitterExpectPreroll(&jb, far)
	jitterExpect(&jb, .Decode, far)
}

@(test)
testJitterBufferWrapsSequenceNumbers :: proc(t: ^testing.T) {
	jb: JitterBuffer
	JitterBuffer_init(&jb)
	sequences := []u32{0xFFFF_FFFE, 0, 0xFFFF_FFFF, 1}
	for sequence, index in sequences {
		assert(
			jitterPush(&jb, sequence, 0, f64(index) * VOICE_FRAME_MS),
			fmt.tprintf("expected frame %d to be accepted across the wrap", sequence),
		)
	}
	jitterExpectPreroll(&jb, 0xFFFF_FFFE)
	jitterExpect(&jb, .Decode, 0xFFFF_FFFE)
	jitterExpect(&jb, .Decode, 0xFFFF_FFFF)
	jitterExpect(&jb, .Decode, 0)
	jitterExpect(&jb, .Decode, 1)
	assert(voiceSequenceDiff(2, 0xFFFF_FFFF) == 3, "expected wrapping difference")
	assert(voiceSequenceDiff(0xFFFF_FFFF, 2) == -3, "expected negative wrapping difference")
}

@(test)
testJitterBufferAdaptsDepthBetweenSpurts :: proc(t: ^testing.T) {
	jb: JitterBuffer
	JitterBuffer_init(&jb)
	// A steady spurt: no jitter, so the next spurt may use the minimum depth.
	for sequence in u32(0) ..< 20 {
		flags := sequence == 19 ? VOICE_FLAG_END_OF_SPURT : 0
		_ = jitterPush(&jb, sequence, flags, f64(sequence) * VOICE_FRAME_MS)
	}
	for JitterBuffer_next(&jb).action != .Idle {}
	assert(jb.targetDepth == JITTER_DEFAULT_DEPTH, "expected the first spurt to keep the default")

	// A jittery spurt: arrivals swing ±30 ms around their media time.
	base := u32(100)
	_ = jitterPush(&jb, base, 0, f64(base) * VOICE_FRAME_MS)
	assert(
		jb.targetDepth == JITTER_MIN_DEPTH,
		fmt.tprintf(
			"expected depth %d after a steady spurt, got %d",
			JITTER_MIN_DEPTH,
			jb.targetDepth,
		),
	)
	for offset in u32(1) ..< 40 {
		sequence := base + offset
		swing := offset % 2 == 0 ? 30.0 : -30.0
		flags := offset == 39 ? VOICE_FLAG_END_OF_SPURT : 0
		_ = jitterPush(&jb, sequence, flags, f64(sequence) * VOICE_FRAME_MS + 40 + swing)
		assert(jb.targetDepth == JITTER_MIN_DEPTH, "expected the depth to hold during a spurt")
		// Play one frame per arrival, so the playout position keeps pace with the sender.
		_ = JitterBuffer_next(&jb)
	}
	for JitterBuffer_next(&jb).action != .Idle {}
	assert(
		jb.jitterMS > 20,
		fmt.tprintf("expected measured jitter above 20 ms, got %f", jb.jitterMS),
	)

	_ = jitterPush(&jb, 200, 0, 200 * VOICE_FRAME_MS + 40)
	assert(
		jb.targetDepth > JITTER_DEFAULT_DEPTH && jb.targetDepth <= JITTER_MAX_DEPTH,
		fmt.tprintf("expected a deeper buffer after a jittery spurt, got %d", jb.targetDepth),
	)
	assert(jitterDepthForJitter(0) == JITTER_MIN_DEPTH, "expected the minimum depth for no jitter")
	assert(jitterDepthForJitter(1000) == JITTER_MAX_DEPTH, "expected the depth to be capped")
}

@(test)
testJitterBufferRejectsInvalidPayloads :: proc(t: ^testing.T) {
	jb: JitterBuffer
	JitterBuffer_init(&jb)
	oversize: [VOICE_OPUS_MAX_FRAME_BYTES + 1]u8
	assert(!JitterBuffer_push(&jb, 1, 0, nil, 0), "expected an empty payload to be rejected")
	assert(
		!JitterBuffer_push(&jb, 1, 0, oversize[:], 0),
		"expected an oversize payload to be rejected",
	)
	assert(jb.stats.invalid == 2 && !jb.inSpurt, "expected invalid frames not to start a spurt")
}
