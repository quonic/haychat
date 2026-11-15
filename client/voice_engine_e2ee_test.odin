package client

import "../common"
import "core:fmt"
import "core:testing"
import "opus"

// The voice engine in an encrypted room (protocol 21, voice_engine.odin): sealing before the
// outbound seam, opening before the jitter buffer, the key table, the sequence rule, constant
// bitrate, and wiping. Loopback frames come back as VOICE_LOOPBACK_USER_ID, so the engine's own
// sender ID is set to it and its send key doubles as the loopback speaker's key.

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
	assert(VoiceEngine_open(engine), fmt.tprintf("expected to open: %s", VoiceEngine_lastError(engine)))
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

	// Constant bitrate in an encrypted room.
	vbr, code := opus.encoderGet(engine.encoder, opus.GET_VBR_REQUEST)
	assert(code == opus.OK && vbr == 0, fmt.tprintf("expected CBR, got VBR %d", vbr))

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
	// Every sealed frame has the same length: constant bitrate.
	for length in outbound.lengths {
		assert(
			length == outbound.lengths[0],
			fmt.tprintf("expected one frame length under CBR, got %v", outbound.lengths[:]),
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
