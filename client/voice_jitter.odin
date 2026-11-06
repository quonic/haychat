package client

import "../common"

// Per-speaker jitter buffer (voice-rooms-design.md section 5.2). Pure code with no audio and
// no allocation, so every loss and reordering case is unit-tested without a device.
//
// Frames are keyed by the sender's frameSequence, a 20 ms tick counter that keeps counting
// while the sender's gate is closed, so a gap in sequence numbers is either loss or silence.
// All sequence comparisons wrap (voiceSequenceDiff).

JITTER_SLOT_COUNT :: 32
JITTER_DEFAULT_DEPTH :: 3
JITTER_MIN_DEPTH :: 2
JITTER_MAX_DEPTH :: 8
// More than this many frames played past the newest arrival ends the spurt.
JITTER_SPURT_TIMEOUT_FRAMES :: 10
// Concealed frames in a row before the buffer gives up and plays silence.
JITTER_MAX_PLC_RUN :: 5
// Arrivals measured before the depth adapts; until then it stays at JITTER_DEFAULT_DEPTH.
JITTER_MIN_SAMPLES_TO_ADAPT :: 16
VOICE_FRAME_MS :: 20.0
// A change in transit time larger than the ring (640 ms) is a clock step, not jitter: inside
// a spurt such a frame already resets the buffer, and between spurts it means the sender's
// sequence started over. Counting it would hold the depth at the maximum for many spurts.
JITTER_CLOCK_STEP_MS :: f64(JITTER_SLOT_COUNT) * VOICE_FRAME_MS

// Wrapping difference a − b, so sequence 0 comes after 0xFFFF_FFFF.
voiceSequenceDiff :: proc(a, b: u32) -> i32 {
	return i32(a - b)
}

JitterSlot :: struct {
	used:     bool,
	sequence: u32,
	flags:     u8,
	length:    int,
	// The receiver's clock when the frame arrived, for the playout delay.
	arrivalMS: f64,
	data:      [common.VOICE_OPUS_MAX_BYTES]u8,
}

JitterStats :: struct {
	received:   u64, // frames accepted into the buffer
	duplicates: u64,
	late:       u64, // arrived after their playout time
	invalid:    u64, // empty or oversize payloads
	played:     u64, // normal decodes
	fec:        u64, // missing frames rebuilt from the next frame's redundancy
	plc:        u64, // missing frames concealed
	silent:     u64, // missing frames after the PLC limit, played as silence
	resets:     u64, // far-ahead frames that restarted the buffer
	spurts:     u64,
	// The longest run of frames inside a spurt that the listener heard as neither a decoded
	// nor an FEC-rebuilt frame (concealment, or silence after the PLC limit; not pre-roll).
	// A maximum, not a sum: jitterStatsAdd keeps the larger.
	maxGapRun:  u64,
}

JitterAction :: enum {
	// Not in a talk spurt: produce nothing.
	Idle,
	// Inside a spurt but nothing to decode (pre-roll or after the PLC limit): play 20 ms of
	// silence so the playout clock keeps its place.
	Silence,
	// Decode data normally.
	Decode,
	// Decode data (the following frame) with the FEC flag to rebuild the missing frame.
	DecodeFEC,
	// Conceal the missing frame (decode with no packet).
	Conceal,
}

JitterOutput :: struct {
	action:    JitterAction,
	sequence:  u32,
	// Borrowed from a slot: valid until the next JitterBuffer_push or JitterBuffer_next.
	data:      []u8,
	// Decode only: when the frame arrived (JitterBuffer_push's arrivalMS).
	arrivalMS: f64,
}

JitterBuffer :: struct {
	slots:         [JITTER_SLOT_COUNT]JitterSlot,
	inSpurt:       bool,
	// The next sequence JitterBuffer_next plays.
	playoutSeq:    u32,
	// The earliest sequence of this spurt known so far; positions before it are pre-roll.
	spurtStartSeq: u32,
	newestSeq:     u32,
	// The last sequence played in an ended spurt, so stragglers from it are dropped as late.
	hasLastPlayed: bool,
	lastPlayedSeq: u32,
	targetDepth:   int,
	plcRun:        int,
	// Frames in a row heard as neither decoded nor FEC-rebuilt (stats.maxGapRun).
	gapRun:        int,
	// RFC 3550-style interarrival jitter, in milliseconds.
	hasTransit:    bool,
	lastTransitMS: f64,
	jitterMS:      f64,
	jitterSamples: int,
	stats:         JitterStats,
}

JitterBuffer_init :: proc(jb: ^JitterBuffer) {
	jb^ = {}
	jb.targetDepth = JITTER_DEFAULT_DEPTH
}

@(private = "file")
JitterBuffer_clearSlots :: proc(jb: ^JitterBuffer) {
	for &slot in jb.slots {
		slot.used = false
	}
}

// jitterDepthForJitter maps measured jitter to a target depth: two frames of floor plus
// enough frames to cover about three times the mean deviation.
jitterDepthForJitter :: proc(jitterMS: f64) -> int {
	extra := int((3.0 * jitterMS + VOICE_FRAME_MS - 1.0) / VOICE_FRAME_MS)
	return clamp(JITTER_MIN_DEPTH + extra, JITTER_MIN_DEPTH, JITTER_MAX_DEPTH)
}

@(private = "file")
JitterBuffer_startSpurt :: proc(jb: ^JitterBuffer, sequence: u32) {
	JitterBuffer_clearSlots(jb)
	// The depth only changes here, between spurts, so a running spurt never jumps.
	if jb.jitterSamples >= JITTER_MIN_SAMPLES_TO_ADAPT {
		jb.targetDepth = jitterDepthForJitter(jb.jitterMS)
	}
	jb.inSpurt = true
	jb.playoutSeq = sequence - u32(jb.targetDepth)
	jb.spurtStartSeq = sequence
	jb.newestSeq = sequence
	jb.plcRun = 0
	jb.gapRun = 0
	jb.stats.spurts += 1
}

// Ends the spurt whose last frame (END_OF_SPURT, or the last before a timeout) was the one
// just before playoutSeq. Frames of that spurt still in the ring are dropped, but frames
// after it already belong to the next spurt: after a quick push-to-talk re-press they arrive
// while the END_OF_SPURT frame still waits its turn behind the buffer's depth. They start the
// next spurt at once and keep the playout position, so they play as far behind their arrival
// as the old spurt did, and the frames the sender's gate skipped play as pre-roll silence.
@(private = "file")
JitterBuffer_endSpurt :: proc(jb: ^JitterBuffer) {
	endedSeq := jb.playoutSeq - 1
	jb.hasLastPlayed = true
	jb.lastPlayedSeq = endedSeq
	hasNext := false
	nextSeq: u32
	for &slot in jb.slots {
		if !slot.used {
			continue
		}
		if voiceSequenceDiff(slot.sequence, endedSeq) <= 0 {
			slot.used = false
			continue
		}
		if !hasNext || voiceSequenceDiff(slot.sequence, nextSeq) < 0 {
			nextSeq = slot.sequence
			hasNext = true
		}
	}
	if !hasNext {
		jb.inSpurt = false
		return
	}
	jb.spurtStartSeq = nextSeq
	jb.plcRun = 0
	jb.gapRun = 0
	jb.stats.spurts += 1
}

@(private = "file")
JitterBuffer_measureArrival :: proc(jb: ^JitterBuffer, sequence: u32, arrivalMS: f64) {
	// Transit is arrival minus media time; only its changes matter, so the sender's clock
	// offset cancels out. u32 media time wraps after 2.7 years, far beyond a session.
	transit := arrivalMS - f64(sequence) * VOICE_FRAME_MS
	if jb.hasTransit && abs(transit - jb.lastTransitMS) > JITTER_CLOCK_STEP_MS {
		// A step no queue could cause: the sender restarted and its sequence started over (a
		// re-join or a new client while this speaker was still held), or the receiver's clock
		// jumped. Only the transit baseline is stale; the jitter measured so far still
		// describes the path, so it is kept.
		jb.hasTransit = false
	}
	if jb.hasTransit {
		deviation := abs(transit - jb.lastTransitMS)
		jb.jitterMS += (deviation - jb.jitterMS) / 16.0
		jb.jitterSamples += 1
	}
	jb.lastTransitMS = transit
	jb.hasTransit = true
}

// JitterBuffer_push stores one received frame. arrivalMS is the receiver's clock when the
// frame arrived. Returns false when the frame was dropped (late, duplicate or invalid).
JitterBuffer_push :: proc(
	jb: ^JitterBuffer,
	sequence: u32,
	flags: u8,
	opus: []u8,
	arrivalMS: f64,
) -> bool {
	if len(opus) == 0 || len(opus) > common.VOICE_OPUS_MAX_BYTES {
		jb.stats.invalid += 1
		return false
	}
	if !jb.inSpurt {
		if jb.hasLastPlayed &&
		   voiceSequenceDiff(sequence, jb.lastPlayedSeq) <= 0 &&
		   voiceSequenceDiff(jb.lastPlayedSeq, sequence) < JITTER_SLOT_COUNT {
			jb.stats.late += 1
			return false
		}
		JitterBuffer_startSpurt(jb, sequence)
	} else {
		ahead := voiceSequenceDiff(sequence, jb.playoutSeq)
		if ahead < 0 {
			jb.stats.late += 1
			return false
		}
		if ahead >= JITTER_SLOT_COUNT {
			// Too far ahead to fit the ring: a long stall or a restarted sender. Start over
			// from this frame rather than play a stale window.
			jb.stats.resets += 1
			jb.hasTransit = false
			JitterBuffer_startSpurt(jb, sequence)
		}
	}
	slot := &jb.slots[sequence % JITTER_SLOT_COUNT]
	if slot.used && slot.sequence == sequence {
		jb.stats.duplicates += 1
		return false
	}
	slot.used = true
	slot.sequence = sequence
	slot.flags = flags
	slot.arrivalMS = arrivalMS
	slot.length = copy(slot.data[:], opus)
	if voiceSequenceDiff(sequence, jb.newestSeq) > 0 {
		jb.newestSeq = sequence
	}
	if voiceSequenceDiff(sequence, jb.spurtStartSeq) < 0 {
		jb.spurtStartSeq = sequence
	}
	jb.stats.received += 1
	JitterBuffer_measureArrival(jb, sequence, arrivalMS)
	return true
}

@(private = "file")
JitterBuffer_slotFor :: proc(jb: ^JitterBuffer, sequence: u32) -> ^JitterSlot {
	slot := &jb.slots[sequence % JITTER_SLOT_COUNT]
	if slot.used && slot.sequence == sequence {
		return slot
	}
	return nil
}

// JitterBuffer_next decides what to play for the next 20 ms of this speaker. Call it once
// per frame of output; it advances the playout position whenever it returns anything but
// Idle.
JitterBuffer_next :: proc(jb: ^JitterBuffer) -> JitterOutput {
	if !jb.inSpurt {
		return {action = .Idle}
	}
	if voiceSequenceDiff(jb.playoutSeq, jb.newestSeq) > JITTER_SPURT_TIMEOUT_FRAMES {
		// Nothing has arrived for a while: the sender stopped without an END_OF_SPURT (mute,
		// a lost last frame, or a disconnect).
		JitterBuffer_endSpurt(jb)
		return {action = .Idle}
	}
	sequence := jb.playoutSeq
	jb.playoutSeq += 1
	if slot := JitterBuffer_slotFor(jb, sequence); slot != nil {
		slot.used = false
		jb.plcRun = 0
		jb.gapRun = 0
		jb.stats.played += 1
		output := JitterOutput {
			action    = .Decode,
			sequence  = sequence,
			data      = slot.data[:slot.length],
			arrivalMS = slot.arrivalMS,
		}
		if slot.flags & common.VOICE_FRAME_FLAG_END_OF_SPURT != 0 {
			// The slot's bytes stay in place until the next push, so data is still valid.
			JitterBuffer_endSpurt(jb)
		}
		return output
	}
	if voiceSequenceDiff(sequence, jb.spurtStartSeq) < 0 {
		// Pre-roll before the first frame of the spurt: silence, not loss.
		return {action = .Silence, sequence = sequence}
	}
	if next := JitterBuffer_slotFor(jb, sequence + 1); next != nil {
		jb.plcRun = 0
		jb.gapRun = 0
		jb.stats.fec += 1
		return {action = .DecodeFEC, sequence = sequence, data = next.data[:next.length]}
	}
	jb.gapRun += 1
	jb.stats.maxGapRun = max(jb.stats.maxGapRun, u64(jb.gapRun))
	if jb.plcRun < JITTER_MAX_PLC_RUN {
		jb.plcRun += 1
		jb.stats.plc += 1
		return {action = .Conceal, sequence = sequence}
	}
	jb.stats.silent += 1
	return {action = .Silence, sequence = sequence}
}

// JitterBuffer_buffered is how many frames are waiting at or after the playout position.
JitterBuffer_buffered :: proc(jb: ^JitterBuffer) -> int {
	if !jb.inSpurt {
		return 0
	}
	count := 0
	for slot in jb.slots {
		if slot.used && voiceSequenceDiff(slot.sequence, jb.playoutSeq) >= 0 {
			count += 1
		}
	}
	return count
}
