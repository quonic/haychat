package client

import "../common"
import "core:fmt"
import "core:math"
import "core:testing"
import "opus"

// The voice engine in an encrypted room (protocol 21, voice_engine.odin): sealing before the
// outbound seam, opening before the jitter buffer, the key table, the sequence rule, padded
// fixed-size packets, and wiping. Loopback frames come back as VOICE_LOOPBACK_USER_ID, so the
// engine's own sender ID is set to it and its send key doubles as the loopback speaker's key.

@(private = "file")
VoiceE2EETestOutbound :: struct {
	count:        int,
	allSealed:    bool,
	lengths:      [dynamic]int,
	maxSequence:  u32,
	sequenceBack: bool,
}

@(private = "file")
voiceE2EETestOnOutbound :: proc(userdata: rawptr, frame: VoiceOutboundFrame) {
	record := (^VoiceE2EETestOutbound)(userdata)
	if !common.voicePayloadLooksSealed(frame.opus) {
		record.allSealed = false
	}
	if record.count > 0 && frame.frameSequence <= record.maxSequence {
		record.sequenceBack = true
	}
	record.maxSequence = max(record.maxSequence, frame.frameSequence)
	append(&record.lengths, len(frame.opus))
	record.count += 1
}

@(private = "file")
voiceE2EETestKey :: proc(generation: u32, fill: u8, epoch := 3) -> VoiceEngineKey {
	key := VoiceEngineKey {
		set        = true,
		epoch      = epoch,
		generation = generation,
	}
	key.voiceSessionID[0] = 0xA5
	for &value, index in key.key {
		value = fill + u8(index)
	}
	return key
}

@(private = "file")
voiceE2EETestEngine :: proc(
	outbound: ^VoiceE2EETestOutbound,
	encrypted := true,
	loopback := true,
) -> ^VoiceEngine {
	config := VoiceEngineConfig {
		source = {kind = .Tone, toneHz = 440, toneAmplitude = 0.5},
		sink = {kind = .Null},
		gateMode = .PushToTalk,
		loopback = loopback,
		unpaced = true,
		onOutbound = voiceE2EETestOnOutbound,
		outboundUserdata = outbound,
	}
	if encrypted {
		config.encryption = VoiceEngineEncryption {
			enabled    = true,
			roomID     = 9,
			selfUserID = int(VOICE_LOOPBACK_USER_ID),
		}
		config.encryption.serverIdentityPublicKey[0] = 0x5E
	}
	engine := VoiceEngine_create(config)
	VoiceEngine_setPushToTalk(engine, true)
	assert(
		VoiceEngine_open(engine),
		fmt.tprintf("expected to open: %s", VoiceEngine_lastError(engine)),
	)
	return engine
}

@(private = "file")
voiceE2EETestSteps :: proc(engine: ^VoiceEngine, count: int) {
	for _ in 0 ..< count {
		VoiceEngine_step(engine)
	}
}

@(test)
testVoiceEngineSealsAndOpensWithItsKeyTable :: proc(t: ^testing.T) {
	if !voiceTestOpusAvailable(t) {
		return
	}
	outbound := VoiceE2EETestOutbound {
		allSealed = true,
	}
	defer delete(outbound.lengths)
	engine := voiceE2EETestEngine(&outbound)
	defer VoiceEngine_destroy(engine)

	// Constrained VBR in an encrypted room too: fixed lengths come from padding, not CBR,
	// which dropped steady tones by tens of dB with in-band FEC (e2ee-voice-design.md 8).
	vbr, code := opus.encoderGet(engine.encoder, opus.GET_VBR_REQUEST)
	assert(code == opus.OK && vbr == 1, fmt.tprintf("expected VBR, got VBR %d", vbr))
	constrained, _ := opus.encoderGet(engine.encoder, opus.GET_VBR_CONSTRAINT_REQUEST)
	assert(constrained == 1, "expected constrained VBR in an encrypted room")

	// No send key: nothing leaves, sealed or not.
	voiceE2EETestSteps(engine, 20)
	snapshot := VoiceEngine_snapshot(engine)
	assert(outbound.count == 0, "expected no frame without a send key")
	assert(
		snapshot.stats.framesSent == 0 && snapshot.stats.e2ee.sendNoKey > 0,
		fmt.tprintf("expected the frames held back, got %v", snapshot.stats.e2ee),
	)
	assert(snapshot.encrypted && !snapshot.hasSendKey, "expected an encrypted engine without key")

	// A send key and no speaker key: every frame sealed, none played.
	VoiceEngine_setSendKey(engine, voiceE2EETestKey(0, 1))
	voiceE2EETestSteps(engine, 20)
	snapshot = VoiceEngine_snapshot(engine)
	assert(outbound.count > 0 && outbound.allSealed, "expected only sealed frames to go out")
	assert(snapshot.hasSendKey && snapshot.sendKeyGeneration == 0, "expected generation 0")
	assert(
		snapshot.stats.e2ee.drops[.NoKey] > 0 &&
		snapshot.stats.e2ee.framesOpened == 0 &&
		snapshot.speakerCount == 0,
		fmt.tprintf("expected nothing played without a key, got %v", snapshot.stats.e2ee),
	)

	// The speaker's key: frames open and play.
	VoiceEngine_setSpeakerKeys(engine, VOICE_LOOPBACK_USER_ID, voiceE2EETestKey(0, 1), {})
	voiceE2EETestSteps(engine, 40)
	snapshot = VoiceEngine_snapshot(engine)
	opened := snapshot.stats.e2ee.framesOpened
	assert(opened > 30, fmt.tprintf("expected frames to open, got %v", snapshot.stats.e2ee))
	assert(snapshot.speakerCount == 1 && snapshot.jitter.played > 0, "expected the speaker heard")
	assert(snapshot.stats.decodeErrors == 0, "expected every opened frame to decode")
	assert(snapshot.stats.e2ee.drops[.BadTag] == 0, "expected no bad tags")
	// Every sealed frame has the same length: the padded size plus the sealing overhead.
	padded := voiceE2EEPaddedOpusBytes(int(opus.VOICE_ENCODER_SETTINGS.bitrate))
	for length in outbound.lengths {
		assert(
			length == padded + common.VOICE_E2EE_OVERHEAD,
			fmt.tprintf(
				"expected every frame %d bytes, got %v",
				padded + common.VOICE_E2EE_OVERHEAD,
				outbound.lengths[:],
			),
		)
	}

	// A rotation: the listener holds the new key and the previous one.
	VoiceEngine_setSendKey(engine, voiceE2EETestKey(1, 50))
	VoiceEngine_setSpeakerKeys(
		engine,
		VOICE_LOOPBACK_USER_ID,
		voiceE2EETestKey(1, 50),
		voiceE2EETestKey(0, 1),
	)
	voiceE2EETestSteps(engine, 20)
	snapshot = VoiceEngine_snapshot(engine)
	assert(snapshot.stats.e2ee.framesOpened > opened, "expected the new generation to open")
	assert(snapshot.sendKeyGeneration == 1, "expected generation 1")
	assert(snapshot.stats.e2ee.drops[.UnknownKeyID] == 0, "expected both keys usable")

	// A key ID the listener does not hold, then a key of the right ID with other bytes, in the
	// middle of a spurt: dropped and counted, and repaired as losses.
	VoiceEngine_setSpeakerKeys(engine, VOICE_LOOPBACK_USER_ID, voiceE2EETestKey(5, 50), {})
	voiceE2EETestSteps(engine, 5)
	snapshot = VoiceEngine_snapshot(engine)
	assert(snapshot.stats.e2ee.drops[.UnknownKeyID] > 0, "expected unknown key IDs counted")
	VoiceEngine_setSpeakerKeys(engine, VOICE_LOOPBACK_USER_ID, voiceE2EETestKey(1, 99), {})
	voiceE2EETestSteps(engine, 5)
	snapshot = VoiceEngine_snapshot(engine)
	assert(snapshot.stats.e2ee.drops[.BadTag] > 0, "expected bad tags counted")
	repaired := snapshot.jitter.fec + snapshot.jitter.plc + snapshot.jitter.silent
	assert(repaired > 0, fmt.tprintf("expected the drops concealed, got %v", snapshot.jitter))

	// Frames pushed from outside: plaintext Opus and a sealed packet that is not 20 ms.
	VoiceEngine_setSpeakerKeys(engine, 77, voiceE2EETestKey(2, 7), {})
	voiceE2EETestSteps(engine, 1)
	plain := [4]u8{0xF8, 1, 2, 3}
	assert(VoiceEngine_pushInbound(engine, 77, 1000, 0, plain[:]), "expected the frame queued")
	key := voiceE2EETestKey(2, 7)
	fortyMS := [4]u8{0x10, 1, 2, 3}
	sealed: [common.VOICE_OPUS_MAX_BYTES]u8
	n, result := common.sealVoicePayload(
		&key.key,
		common.VoiceFrameAADFields {
			serverIdentityPublicKey = engine.config.encryption.serverIdentityPublicKey,
			roomID = 9,
			senderUserID = 77,
			epoch = key.epoch,
			voiceSessionID = key.voiceSessionID,
			generation = key.generation,
			frameSequence = 1001,
		},
		fortyMS[:],
		sealed[:],
	)
	assert(result == .Ok, "expected the test payload to seal")
	assert(VoiceEngine_pushInbound(engine, 77, 1001, 0, sealed[:n]), "expected it queued")
	voiceE2EETestSteps(engine, 1)
	snapshot = VoiceEngine_snapshot(engine)
	assert(
		snapshot.stats.e2ee.drops[.NotSealed] == 1 && snapshot.stats.e2ee.drops[.BadDuration] == 1,
		fmt.tprintf("expected NotSealed and BadDuration, got %v", snapshot.stats.e2ee.drops),
	)
	for speaker in snapshot.speakers[:snapshot.speakerCount] {
		assert(speaker.userID != 77, "expected nothing of user 77 played")
	}
}

@(test)
testVoiceEngineRefusesToSealAtOrBehindTheLastSequence :: proc(t: ^testing.T) {
	if !voiceTestOpusAvailable(t) {
		return
	}
	outbound := VoiceE2EETestOutbound {
		allSealed = true,
	}
	defer delete(outbound.lengths)
	engine := voiceE2EETestEngine(&outbound, loopback = false)
	defer VoiceEngine_destroy(engine)
	VoiceEngine_setSendKey(engine, voiceE2EETestKey(0, 1))
	voiceE2EETestSteps(engine, 10)
	sent := outbound.count
	assert(sent > 0 && engine.hasSealed, "expected frames sealed")
	last := engine.lastSealedSequence

	// The media clock goes back (it never does on its own): the same key refuses it.
	engine.frameSequence = 0
	voiceE2EETestSteps(engine, int(last) + 1)
	snapshot := VoiceEngine_snapshot(engine)
	assert(outbound.count == sent, "expected no frame sealed at or behind the last sequence")
	assert(!outbound.sequenceBack, "expected the outbound sequence never to go back")
	assert(
		snapshot.stats.e2ee.sequenceRefused == u64(last) + 1,
		fmt.tprintf("expected %d refusals, got %v", last + 1, snapshot.stats.e2ee),
	)
	// The next sequence after the last sealed one goes again.
	voiceE2EETestSteps(engine, 1)
	assert(outbound.count == sent + 1, "expected the sequence after the last sealed to go")

	// A new generation is a new key: its own count starts over.
	engine.frameSequence = 0
	VoiceEngine_setSendKey(engine, voiceE2EETestKey(1, 9))
	voiceE2EETestSteps(engine, 1)
	assert(outbound.count == sent + 2, "expected the new key to seal from sequence 0")
}

@(test)
testVoiceEngineWipesKeysWhenItCloses :: proc(t: ^testing.T) {
	if !voiceTestOpusAvailable(t) {
		return
	}
	outbound := VoiceE2EETestOutbound {
		allSealed = true,
	}
	defer delete(outbound.lengths)
	engine := voiceE2EETestEngine(&outbound)
	defer VoiceEngine_destroy(engine)
	VoiceEngine_setSendKey(engine, voiceE2EETestKey(0, 1))
	VoiceEngine_setSpeakerKeys(engine, VOICE_LOOPBACK_USER_ID, voiceE2EETestKey(0, 1), {})
	assert(VoiceEngine_setSpeakerKeys(engine, 5, voiceE2EETestKey(3, 3), {}), "expected a slot")
	voiceE2EETestSteps(engine, 10)
	assert(engine.appliedSendKey.set && engine.appliedSpeakerKeyCount == 2, "expected keys")

	// Removing a speaker's keys wipes its slot.
	VoiceEngine_setSpeakerKeys(engine, 5, {}, {})
	assert(engine.speakerKeyCount == 1, "expected one speaker left")
	isZero :: proc(bytes: []u8) -> bool {
		for value in bytes {
			if value != 0 {
				return false
			}
		}
		return true
	}
	assert(
		isZero(([^]u8)(&engine.speakerKeys[1])[:size_of(VoiceEngineSpeakerKeys)]),
		"expected the removed slot wiped",
	)

	VoiceEngine_close(engine)
	assert(
		isZero(([^]u8)(&engine.sendKey)[:size_of(VoiceEngineKey)]) &&
		isZero(([^]u8)(&engine.appliedSendKey)[:size_of(VoiceEngineKey)]) &&
		isZero(([^]u8)(&engine.speakerKeys)[:size_of(engine.speakerKeys)]) &&
		isZero(([^]u8)(&engine.appliedSpeakerKeys)[:size_of(engine.appliedSpeakerKeys)]) &&
		isZero(engine.sealBuffer[:]) &&
		isZero(engine.openBuffer[:]),
		"expected every key and scratch buffer wiped when the engine closed",
	)
	assert(engine.speakerKeyCount == 0 && engine.appliedSpeakerKeyCount == 0, "expected none")
}

@(test)
testVoiceEngineKeepsVBROutsideEncryptedRooms :: proc(t: ^testing.T) {
	if !voiceTestOpusAvailable(t) {
		return
	}
	outbound := VoiceE2EETestOutbound {
		allSealed = true,
	}
	defer delete(outbound.lengths)
	engine := voiceE2EETestEngine(&outbound, encrypted = false, loopback = false)
	defer VoiceEngine_destroy(engine)
	vbr, code := opus.encoderGet(engine.encoder, opus.GET_VBR_REQUEST)
	assert(code == opus.OK && vbr == 1, "expected VBR outside encrypted rooms")
	constrained, _ := opus.encoderGet(engine.encoder, opus.GET_VBR_CONSTRAINT_REQUEST)
	assert(constrained == 1, "expected constrained VBR outside encrypted rooms")
	voiceE2EETestSteps(engine, 10)
	assert(outbound.count > 0 && !outbound.allSealed, "expected plain Opus without encryption")
}

@(test)
testVoiceE2EEPaddedSizes :: proc(t: ^testing.T) {
	cases := [?][2]int {
		{24000, 96}, // the default: 60 bytes nominal, 1.6 times
		{12000, 48},
		{64000, 256},
		{20001, 81}, // rounds up
		{0, VOICE_E2EE_PADDED_MIN_BYTES},
		{1_000_000, common.VOICE_E2EE_OPUS_MAX_BYTES},
	}
	for entry in cases {
		got := voiceE2EEPaddedOpusBytes(entry[0])
		assert(
			got == entry[1],
			fmt.tprintf("expected %d bytes at %d bit/s, got %d", entry[1], entry[0], got),
		)
	}
}

// The encoder path of an encrypted room (capped constrained VBR, then padded) on a steady
// 440 Hz tone, at the bitrates where constant bitrate failed: every packet has the padded
// size and decodes to one 20 ms frame, its in-band FEC still decodes, and no 20 ms block of
// the decoded tone falls 20 dB under the tone's level (CBR dropped some by 40 to 50 dB at 24
// and 28 kbit/s with libopus 1.6, e2ee-voice-design.md 8).
@(test)
testVoiceE2EEPaddedTonesKeepTheirLevel :: proc(t: ^testing.T) {
	if !voiceTestOpusAvailable(t) {
		return
	}
	FRAMES :: 20 * 50 // 20 s
	for bitrate in ([]i32{16000, 24000, 28000, 32000, 64000}) {
		settings := opus.VOICE_ENCODER_SETTINGS
		settings.bitrate = bitrate
		encoder, code := opus.createVoiceEncoder(common.VOICE_SAMPLE_RATE, settings)
		assert(encoder != nil, fmt.tprintf("expected an encoder, got %d", code))
		decoder, decoderCode := opus.createDecoder(common.VOICE_SAMPLE_RATE)
		assert(decoder != nil, fmt.tprintf("expected a decoder, got %d", decoderCode))
		padded := voiceE2EEPaddedOpusBytes(int(bitrate))
		pcm: [common.VOICE_FRAME_SAMPLES]f32
		decoded: [common.VOICE_FRAME_SAMPLES]f32
		rebuilt: [common.VOICE_FRAME_SAMPLES]f32
		packet: [opus.MAX_PACKET_BYTES]u8
		quietest := f64(0)
		for frame in 0 ..< FRAMES {
			for index in 0 ..< len(pcm) {
				sample := f64(frame * len(pcm) + index)
				pcm[index] = 0.5 * f32(math.sin(2 * math.PI * 440 * sample / 48000))
			}
			length := opus.encodeFloat(encoder, pcm[:], packet[:padded])
			assert(
				length > 0 && int(length) <= padded,
				fmt.tprintf("expected 1..%d bytes at %d bit/s, got %d", padded, bitrate, length),
			)
			assert(
				opus.padPacket(packet[:], int(length), padded) == opus.OK,
				"expected the packet to pad",
			)
			assert(
				opus.packetSampleCount(packet[:padded], common.VOICE_SAMPLE_RATE) ==
				common.VOICE_FRAME_SAMPLES,
				"expected a padded packet of one 20 ms frame",
			)
			if frame == 100 {
				got := opus.decodeFloat(decoder, packet[:padded], rebuilt[:], fec = true)
				assert(got == common.VOICE_FRAME_SAMPLES, "expected FEC from a padded packet")
			}
			got := opus.decodeFloat(decoder, packet[:padded], decoded[:])
			assert(got == common.VOICE_FRAME_SAMPLES, fmt.tprintf("expected a decode, got %d", got))
			if frame < 10 {
				continue // the codec's start
			}
			power := f64(0)
			for value in decoded {
				power += f64(value) * f64(value)
			}
			levelDB := 10 * math.log10(max(power / f64(len(decoded)), 1e-20))
			quietest = min(quietest, levelDB)
		}
		opus.destroyEncoder(encoder)
		opus.destroyDecoder(decoder)
		// The tone is at -9 dBFS RMS.
		assert(
			quietest > -29,
			fmt.tprintf("expected no 20 ms block under -29 dBFS at %d bit/s, got %.1f", bitrate,
				quietest),
		)
	}
}
