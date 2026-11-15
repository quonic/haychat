package common

import "core:fmt"
import "core:mem"
import "core:testing"

// Sealed voice payloads (protocol 21, voice_e2ee.odin). KAT_VOICE_PAYLOAD comes from
// dev/tools/e2ee-vectors.py: alice's 60-byte Opus packet sealed under the voice key of
// KAT_VOICE_KEY_ENVELOPE (common/e2ee_test.odin), with every input SHA-256 of a label.

@(private = "file")
KAT_VOICE_PAYLOAD ::
	"010770eb021fd0602774d6893a4fd1afd258df81329eac513dcec7540f0a4caaccf8773fb6f71f5d" +
	"295ed54ac5da3fe481ee628c0ba002b7cb17e424c792313c6bb596a52369e6314e6d7711fc25"

@(private = "file")
voiceTestLabel :: proc(label: string) -> [32]u8 {
	return hashBytes(transmute([]u8)label)
}

@(private = "file")
voiceTestFields :: proc() -> VoiceFrameAADFields {
	serverPrivate := IdentityPrivateKeyBytes(voiceTestLabel("haychat-e2ee-test-server-identity"))
	serverPublic, ok := identityPublicKeyFromPrivateKey(serverPrivate)
	assert(ok, "expected the test server key")
	session := voiceTestLabel("haychat-e2ee-test-voice-session")
	fields := VoiceFrameAADFields {
		serverIdentityPublicKey = serverPublic,
		roomID                  = 42,
		senderUserID            = 7,
		epoch                   = 3,
		generation              = 7,
		frameSequence           = 1234,
		flags                   = 0x02,
	}
	copy(fields.voiceSessionID[:], session[:VOICE_SESSION_ID_SIZE])
	return fields
}

@(private = "file")
voiceTestOpus :: proc() -> [60]u8 {
	first := voiceTestLabel("haychat-e2ee-test-voice-opus")
	second := voiceTestLabel("haychat-e2ee-test-voice-opus-2")
	opus: [60]u8
	copy(opus[:32], first[:])
	copy(opus[32:], second[:28])
	return opus
}

@(private = "file")
voiceTestKey :: proc() -> VoiceKey {
	return VoiceKey(voiceTestLabel("haychat-e2ee-test-voice-key"))
}

@(private = "file")
voiceTestKATBytes :: proc(buffer: []u8) -> []u8 {
	bytes := buffer[:len(KAT_VOICE_PAYLOAD) / 2]
	assert(decodeHexIntoBuffer(KAT_VOICE_PAYLOAD, bytes), "expected the payload vector hex")
	return bytes
}

@(test)
testVoiceE2EEConstants :: proc(t: ^testing.T) {
	_ = t
	assert(VOICE_E2EE_OVERHEAD == 18, "expected 18 bytes of sealed voice overhead")
	assert(VOICE_E2EE_OPUS_MAX_BYTES == 494, "expected 494-byte Opus packets in encrypted rooms")
	assert(
		VOICE_FRAME_AAD_SIZE == 105,
		fmt.tprintf("expected a 105-byte voice frame AAD, got %d", VOICE_FRAME_AAD_SIZE),
	)
	assert(VOICE_KEY_ROTATE_SECONDS == 1800, "expected rotation every 30 minutes")
	assert(VOICE_KEY_MAX_AGE_SECONDS == 3600, "expected keys to last an hour")
	assert(VOICE_KEY_MAX_FUTURE_SECONDS == 300, "expected 5 minutes of clock skew ahead")
	assert(VOICE_EPOCH_GRACE_SECONDS == 10, "expected a 10-second epoch grace")
	assert(VOICE_KEY_REQUEST_INTERVAL_SECONDS == 10, "expected one request every 10 seconds")
	nonce := makeVoiceFrameNonce(0x0403_0201)
	assert(
		nonce[0] == 1 && nonce[1] == 2 && nonce[2] == 3 && nonce[3] == 4,
		"expected the frame sequence little-endian at the front of the nonce",
	)
	for value in nonce[4:] {
		assert(value == 0, "expected 20 zero bytes after the sequence")
	}
	assert(voiceKeyIDForGeneration(0x1_02) == 2, "expected keyId to be the generation's low byte")
}

@(test)
testVoicePayloadVectorAndRoundTripWithoutAllocating :: proc(t: ^testing.T) {
	_ = t
	key := voiceTestKey()
	fields := voiceTestFields()
	opus := voiceTestOpus()
	sealed: [VOICE_OPUS_MAX_BYTES]u8
	opened: [VOICE_OPUS_MAX_BYTES]u8
	katBuffer: [VOICE_OPUS_MAX_BYTES]u8
	kat := voiceTestKATBytes(katBuffer[:])

	// Neither procedure may allocate: they run on the voice thread for every frame.
	tracking: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracking, context.allocator)
	defer mem.tracking_allocator_destroy(&tracking)
	tempTracking: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tempTracking, context.allocator)
	defer mem.tracking_allocator_destroy(&tempTracking)
	n: int
	sealResult, openResult: VoicePayloadResult
	plaintext: []u8
	{
		context.allocator = mem.tracking_allocator(&tracking)
		context.temp_allocator = mem.tracking_allocator(&tempTracking)
		n, sealResult = sealVoicePayload(&key, fields, opus[:], sealed[:])
		plaintext, openResult = openVoicePayload(&key, fields, sealed[:n], opened[:])
	}
	assert(
		tracking.total_allocation_count == 0 && tempTracking.total_allocation_count == 0,
		fmt.tprintf(
			"expected no allocation, got %d and %d",
			tracking.total_allocation_count,
			tempTracking.total_allocation_count,
		),
	)
	assert(sealResult == .Ok && n == len(opus) + VOICE_E2EE_OVERHEAD, "expected the seal")
	assert(
		len(kat) == n && string(sealed[:n]) == string(kat),
		"expected the payload vector bytes",
	)
	assert(openResult == .Ok && string(plaintext) == string(opus[:]), "expected the Opus back")
	assert(voicePayloadLooksSealed(sealed[:n]), "expected the relay to see a sealed payload")
	version, keyID, peekOK := peekVoicePayloadHeader(sealed[:n])
	assert(peekOK && version == 1 && keyID == 7, "expected version 1 and keyId 7")
}

@(test)
testVoicePayloadBindsEveryAADField :: proc(t: ^testing.T) {
	_ = t
	key := voiceTestKey()
	fields := voiceTestFields()
	katBuffer: [VOICE_OPUS_MAX_BYTES]u8
	kat := voiceTestKATBytes(katBuffer[:])
	opened: [VOICE_OPUS_MAX_BYTES]u8

	changed: [8]VoiceFrameAADFields
	for &field in changed {
		field = fields
	}
	changed[0].serverIdentityPublicKey[0] ~= 1
	changed[1].roomID += 1
	changed[2].senderUserID += 1
	changed[3].epoch += 1
	changed[4].voiceSessionID[15] ~= 0x80
	changed[5].generation += 0x100 // the same keyId: only the AAD tells them apart
	changed[6].frameSequence += 1
	changed[7].flags ~= VOICE_FRAME_FLAG_END_OF_SPURT
	for field, index in changed {
		_, result := openVoicePayload(&key, field, kat, opened[:])
		assert(result == .BadTag, fmt.tprintf("AAD field %d: expected BadTag, got %v", index, result))
	}
	// A key ID that names another generation, with or without the matching generation.
	other := fields
	other.generation += 1
	_, result := openVoicePayload(&key, other, kat, opened[:])
	assert(result == .WrongKeyID, fmt.tprintf("expected WrongKeyID, got %v", result))
	copied: [VOICE_OPUS_MAX_BYTES]u8
	data := copied[:len(kat)]
	copy(data, kat)
	data[1] = voiceKeyIDForGeneration(other.generation)
	_, result = openVoicePayload(&key, other, data, opened[:])
	assert(result == .BadTag, fmt.tprintf("expected a changed keyId to fail the tag, got %v", result))
	// The version byte is in the AAD too, but a version 2 payload is refused before.
	copy(data, kat)
	data[0] = 2
	_, result = openVoicePayload(&key, fields, data, opened[:])
	assert(result == .UnsupportedVersion, fmt.tprintf("expected version 2 refused, got %v", result))
	// Another key, the ciphertext and the tag.
	otherKey := key
	otherKey[0] ~= 1
	_, result = openVoicePayload(&otherKey, fields, kat, opened[:])
	assert(result == .BadTag, fmt.tprintf("expected another key to fail, got %v", result))
	copy(data, kat)
	data[5] ~= 1
	_, result = openVoicePayload(&key, fields, data, opened[:])
	assert(result == .BadTag, fmt.tprintf("expected a changed ciphertext to fail, got %v", result))
	for value in opened[:len(kat) - VOICE_E2EE_OVERHEAD] {
		assert(value == 0, "expected no plaintext left behind after a failed open")
	}
	copy(data, kat)
	data[len(data) - 1] ~= 1
	_, result = openVoicePayload(&key, fields, data, opened[:])
	assert(result == .BadTag, fmt.tprintf("expected a changed tag to fail, got %v", result))
}

@(test)
testVoicePayloadSizes :: proc(t: ^testing.T) {
	_ = t
	key := voiceTestKey()
	fields := voiceTestFields()
	opus: [VOICE_OPUS_MAX_BYTES]u8
	for &value, index in opus {
		value = u8(index)
	}
	sealed: [VOICE_OPUS_MAX_BYTES + 1]u8
	opened: [VOICE_OPUS_MAX_BYTES]u8

	// The largest packet fits the wire exactly; one byte more is refused.
	n, result := sealVoicePayload(&key, fields, opus[:VOICE_E2EE_OPUS_MAX_BYTES], sealed[:])
	assert(result == .Ok && n == VOICE_OPUS_MAX_BYTES, fmt.tprintf("expected 494 to fit: %v", result))
	plaintext, openResult := openVoicePayload(&key, fields, sealed[:n], opened[:])
	assert(openResult == .Ok && len(plaintext) == VOICE_E2EE_OPUS_MAX_BYTES, "expected it back")
	_, result = sealVoicePayload(&key, fields, opus[:VOICE_E2EE_OPUS_MAX_BYTES + 1], sealed[:])
	assert(result == .OpusTooLarge, fmt.tprintf("expected 495 refused, got %v", result))
	_, result = sealVoicePayload(&key, fields, nil, sealed[:])
	assert(result == .EmptyOpus, fmt.tprintf("expected empty Opus refused, got %v", result))
	_, result = sealVoicePayload(&key, fields, opus[:10], sealed[:27])
	assert(result == .BufferTooSmall, fmt.tprintf("expected a short dst refused, got %v", result))

	// One Opus byte is the shortest payload; the overhead alone and less are truncated.
	n, result = sealVoicePayload(&key, fields, opus[:1], sealed[:])
	assert(result == .Ok && n == VOICE_E2EE_OVERHEAD + 1, "expected a one-byte payload")
	_, openResult = openVoicePayload(&key, fields, sealed[:n], opened[:])
	assert(openResult == .Ok, "expected the one-byte payload to open")
	for length in 0 ..< VOICE_E2EE_OVERHEAD + 1 {
		_, openResult = openVoicePayload(&key, fields, sealed[:length], opened[:])
		assert(
			openResult == .Truncated,
			fmt.tprintf("expected %d bytes truncated, got %v", length, openResult),
		)
		assert(!voicePayloadLooksSealed(sealed[:length]), "expected the relay to refuse it")
	}
	_, openResult = openVoicePayload(&key, fields, sealed[:n], opened[:0])
	assert(openResult == .BufferTooSmall, "expected a short dst refused on open")
}
