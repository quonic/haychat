package common

import "core:crypto"
import "core:crypto/chacha20poly1305"
import "core:encoding/endian"

// End-to-end encrypted voice frames (protocol 21, e2ee-voice-design.md 5).
//
// In an encrypted room the bytes in the opus field of ClientVoiceFrame and ServerVoiceFrame
// (voice_wire.odin) are a SealedVoicePayload instead of Opus. The relay forwards them unchanged
// and cannot read them; it checks only the version byte and the length.
//
// SealedVoicePayload, version 1:
//
//   offset size field
//   0      1    version = 1
//   1      1    keyId u8 = generation & 0xFF
//   2      m    ciphertext: XChaCha20-Poly1305(voiceKey, nonce, opus, AAD), m = len(opus)
//   2+m    16   tag
//
//   nonce = frameSequence (u32 LE) || 20 zero bytes
//   AAD   = "haychat-voice-frame-v1" || serverIdentityPublicKey (32) || roomId (i64)
//           || senderUserId (i64) || epoch (i64) || voiceSessionId (16) || generation (u32)
//           || frameSequence (u32) || flags (u8) || version (u8) || keyId (u8): 105 bytes
//
// Nonces: a voice key is 32 random bytes (VoiceKey envelope, e2ee.odin) used by exactly one
// voice engine, whose frame sequence strictly increases and which refuses to seal a sequence at
// or behind the last one it sealed under that key. A new engine (a join, a device change) always
// makes a new generation. So (key, nonce) never repeats and the nonce needs no random bytes.
//
// The Opus bytes are not padded: encrypted rooms encode at constant bitrate instead (design 8).
// flags is in the AAD, so the server cannot mark a frame as the end of a spurt. keyId names one
// of the two keys a listener holds per speaker; the AAD binds the full generation.
//
// sealVoicePayload and openVoicePayload run on the voice thread, 50 times a second per
// speaker: they work in caller buffers and never allocate.

VOICE_E2EE_VERSION :: u8(1)
VOICE_E2EE_HEADER_SIZE :: 2
// Bytes a sealed payload adds to the Opus packet: version, keyId and the tag.
VOICE_E2EE_OVERHEAD :: VOICE_E2EE_HEADER_SIZE + E2EE_TAG_SIZE
// The largest Opus packet an encrypted room's encoder may produce, so the sealed payload still
// fits the wire's VOICE_OPUS_MAX_BYTES.
VOICE_E2EE_OPUS_MAX_BYTES :: VOICE_OPUS_MAX_BYTES - VOICE_E2EE_OVERHEAD
VOICE_E2EE_NONCE_SIZE :: E2EE_NONCE_SIZE

VOICE_FRAME_AAD_SIZE :: len(VOICE_FRAME_AAD_DOMAIN) + AUTH_IDENTITY_PUBLIC_KEY_SIZE + 8 + 8 + 8 +
	VOICE_SESSION_ID_SIZE + 4 + 4 + 1 + 1 + 1
VoiceFrameAAD :: [VOICE_FRAME_AAD_SIZE]u8

// Rotation and freshness (design 4). A speaker makes a new key at least every
// VOICE_KEY_ROTATE_SECONDS; a listener refuses a key made more than VOICE_KEY_MAX_AGE_SECONDS
// before or VOICE_KEY_MAX_FUTURE_SECONDS after its own clock; after its verified log reaches a
// new epoch it keeps the old epoch's keys, and accepts a speaker's key of the old epoch, for
// VOICE_EPOCH_GRACE_SECONDS. The server relays a listener's ClientRequestVoiceKey for one
// speaker at most once every VOICE_KEY_REQUEST_INTERVAL_SECONDS, and a speaker rotates on a
// request at most that often.
VOICE_KEY_ROTATE_SECONDS :: 30 * 60
VOICE_KEY_MAX_AGE_SECONDS :: 60 * 60
VOICE_KEY_MAX_FUTURE_SECONDS :: 5 * 60
VOICE_EPOCH_GRACE_SECONDS :: 10
VOICE_KEY_REQUEST_INTERVAL_SECONDS :: 10

// Everything a voice frame's AAD binds besides the payload's own version and keyId. The
// sender seals with its own fields; a listener rebuilds them from the ServerVoiceFrame (room,
// sender, sequence, flags), its verified epoch and the speaker's key (session, generation).
VoiceFrameAADFields :: struct {
	serverIdentityPublicKey: IdentityPublicKeyBytes,
	roomID:                  int,
	senderUserID:            int,
	epoch:                   int,
	voiceSessionID:          VoiceSessionID,
	generation:              u32,
	frameSequence:           u32,
	flags:                   u8,
}

VoicePayloadResult :: enum u8 {
	Ok,
	BufferTooSmall, // dst cannot hold the result
	EmptyOpus, // seal: no Opus bytes
	OpusTooLarge, // seal: more than VOICE_E2EE_OPUS_MAX_BYTES
	Truncated, // open: not even the header, one byte and the tag
	UnsupportedVersion, // open: a version byte other than VOICE_E2EE_VERSION
	WrongKeyID, // open: the keyId byte does not match the key's generation
	BadTag, // open: authentication failed
}

// The keyId a payload sealed under generation carries.
voiceKeyIDForGeneration :: proc(generation: u32) -> u8 {
	return u8(generation & 0xFF)
}

// The payload's version and keyId without checking anything else, so a listener can pick the
// key to open it with. ok is false for a payload shorter than the header.
peekVoicePayloadHeader :: proc(payload: []u8) -> (version: u8, keyID: u8, ok: bool) {
	if len(payload) < VOICE_E2EE_HEADER_SIZE {
		return 0, 0, false
	}
	return payload[0], payload[1], true
}

// Whether payload has the shape of a version 1 sealed payload: the relay's check (design 6).
voicePayloadLooksSealed :: proc(payload: []u8) -> bool {
	return len(payload) >= VOICE_E2EE_OVERHEAD + 1 && payload[0] == VOICE_E2EE_VERSION
}

makeVoiceFrameAAD :: proc(fields: VoiceFrameAADFields) -> VoiceFrameAAD {
	fields := fields
	aad: VoiceFrameAAD
	offset := 0
	copy(aad[offset:], VOICE_FRAME_AAD_DOMAIN)
	offset += len(VOICE_FRAME_AAD_DOMAIN)
	copy(aad[offset:], fields.serverIdentityPublicKey[:])
	offset += AUTH_IDENTITY_PUBLIC_KEY_SIZE
	endian.unchecked_put_u64le(aad[offset:offset + 8], u64(i64(fields.roomID)))
	offset += 8
	endian.unchecked_put_u64le(aad[offset:offset + 8], u64(i64(fields.senderUserID)))
	offset += 8
	endian.unchecked_put_u64le(aad[offset:offset + 8], u64(i64(fields.epoch)))
	offset += 8
	copy(aad[offset:], fields.voiceSessionID[:])
	offset += VOICE_SESSION_ID_SIZE
	endian.unchecked_put_u32le(aad[offset:offset + 4], fields.generation)
	offset += 4
	endian.unchecked_put_u32le(aad[offset:offset + 4], fields.frameSequence)
	offset += 4
	aad[offset] = fields.flags
	aad[offset + 1] = VOICE_E2EE_VERSION
	aad[offset + 2] = voiceKeyIDForGeneration(fields.generation)
	offset += 3
	assert(offset == VOICE_FRAME_AAD_SIZE, "voice frame AAD size mismatch")
	return aad
}

// frameSequence (u32 LE) followed by 20 zero bytes.
makeVoiceFrameNonce :: proc(frameSequence: u32) -> [VOICE_E2EE_NONCE_SIZE]u8 {
	nonce: [VOICE_E2EE_NONCE_SIZE]u8
	endian.unchecked_put_u32le(nonce[0:4], frameSequence)
	return nonce
}

// Seals opus into dst as a SealedVoicePayload under key and the AAD built from fields, and
// returns its length (len(opus) + VOICE_E2EE_OVERHEAD). dst must not overlap opus. Allocates
// nothing. The caller guarantees that (key, fields.frameSequence) is never sealed twice.
sealVoicePayload :: proc(
	key: ^VoiceKey,
	fields: VoiceFrameAADFields,
	opus: []u8,
	dst: []u8,
) -> (
	n: int,
	result: VoicePayloadResult,
) {
	if len(opus) == 0 {
		return 0, .EmptyOpus
	}
	if len(opus) > VOICE_E2EE_OPUS_MAX_BYTES {
		return 0, .OpusTooLarge
	}
	total := len(opus) + VOICE_E2EE_OVERHEAD
	if len(dst) < total {
		return 0, .BufferTooSmall
	}
	aad := makeVoiceFrameAAD(fields)
	nonce := makeVoiceFrameNonce(fields.frameSequence)
	dst[0] = VOICE_E2EE_VERSION
	dst[1] = voiceKeyIDForGeneration(fields.generation)
	ciphertext := dst[VOICE_E2EE_HEADER_SIZE:VOICE_E2EE_HEADER_SIZE + len(opus)]
	tag := dst[VOICE_E2EE_HEADER_SIZE + len(opus):total]
	ctx: chacha20poly1305.Context
	chacha20poly1305.init_xchacha(&ctx, key[:])
	chacha20poly1305.seal(&ctx, ciphertext, tag, nonce[:], aad[:], opus)
	chacha20poly1305.reset(&ctx)
	return total, .Ok
}

// Opens a SealedVoicePayload sealed under key and the AAD built from fields, writing the Opus
// bytes into dst and returning them as a slice of dst. dst must not overlap payload. On
// failure dst holds no plaintext. Allocates nothing.
openVoicePayload :: proc(
	key: ^VoiceKey,
	fields: VoiceFrameAADFields,
	payload: []u8,
	dst: []u8,
) -> (
	opus: []u8,
	result: VoicePayloadResult,
) {
	if len(payload) < VOICE_E2EE_OVERHEAD + 1 {
		return nil, .Truncated
	}
	if payload[0] != VOICE_E2EE_VERSION {
		return nil, .UnsupportedVersion
	}
	if payload[1] != voiceKeyIDForGeneration(fields.generation) {
		return nil, .WrongKeyID
	}
	length := len(payload) - VOICE_E2EE_OVERHEAD
	if len(dst) < length {
		return nil, .BufferTooSmall
	}
	aad := makeVoiceFrameAAD(fields)
	nonce := makeVoiceFrameNonce(fields.frameSequence)
	ciphertext := payload[VOICE_E2EE_HEADER_SIZE:VOICE_E2EE_HEADER_SIZE + length]
	tag := payload[VOICE_E2EE_HEADER_SIZE + length:]
	ctx: chacha20poly1305.Context
	chacha20poly1305.init_xchacha(&ctx, key[:])
	ok := chacha20poly1305.open(&ctx, dst[:length], nonce[:], aad[:], ciphertext, tag)
	chacha20poly1305.reset(&ctx)
	if !ok {
		crypto.zero_explicit(raw_data(dst), length)
		return nil, .BadTag
	}
	return dst[:length], .Ok
}

// Fills key with 32 bytes from the OS generator.
generateVoiceKey :: proc() -> (key: VoiceKey, ok: bool) {
	if !generateRandomBytes(key[:]) {
		return {}, false
	}
	return key, true
}

// A fresh random voice session ID.
generateVoiceSessionID :: proc() -> (id: VoiceSessionID, ok: bool) {
	if !generateRandomBytes(id[:]) {
		return {}, false
	}
	return id, true
}

VoiceKey_wipe :: proc(key: ^VoiceKey) {
	crypto.zero_explicit(key, size_of(key^))
}
