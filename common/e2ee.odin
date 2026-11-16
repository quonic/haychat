package common

import "core:crypto"
import "core:crypto/chacha20poly1305"
import "core:crypto/ed25519"
import crypto_hash "core:crypto/hash"
import "core:crypto/hkdf"
import "core:crypto/x25519"
import "core:encoding/endian"
import "core:time"
import "core:unicode/utf8"

// End-to-end encryption primitives (docs/plan/e2ee-design.md, sections 2.2, 3.5, 4, 6.2-6.5).
//
// Pure procedures on caller buffers: no globals, no protocol messages, no I/O. The server's
// validation and both clients share them. Nothing here is on the wire yet; later packages carry
// these byte strings inside CBOR byte strings (design 9.1), so the signed bytes never depend on a
// CBOR encoder's choices.
//
// Conventions for every layout below:
//
// - Integers are little-endian. Fields the protocol holds as `int` (user, room IDs, epochs,
//   log versions) are i64. Fixed-size fields have no length prefix; variable fields are preceded
//   by their count or byte length. Decoders refuse trailing bytes, so each value has exactly one
//   encoding.
// - Every signature is Ed25519 by an identity key over DOMAIN || ... . The domain strings are
//   prefix-free among themselves and all longer than 32 bytes once their fields follow, so none
//   can be read as another, nor as the 32-byte transcript hashes the transport handshake signs.
// - Every failure returns its own error value. Opening procedures verify the signature against
//   the caller's pinned identity key before they touch any key material, and never retry with
//   another key (design 4.1).
// - Every plaintext that is sealed is padded first (padPlaintext): a 0x80 byte, then zeros to the
//   next multiple of E2EE_PADDING_BLOCK. A ciphertext is the padded plaintext followed by the
//   16-byte Poly1305 tag.
//
// SealedEnvelope, version 1 (design 4.1). At most SEALED_ENVELOPE_MAX_BYTES in total.
//
//   offset        size   field
//   0             1      version = 1
//   1             1      kind (EnvelopeKind: 1 DirectMessage, 2 SenderKey, 3 RoomKeyForward,
//                          4 VoiceKey)
//   2             32     ephemeralKey: X25519 public key, fresh per envelope
//   34            2      wrapCount u16 (1..SEALED_ENVELOPE_MAX_WRAPS)
//   36            56*n   wraps, each KeyWrap:
//                          +0  8   recipientUserId i64 (> 0, unique within the envelope)
//                          +8  48  wrappedKey: XChaCha20-Poly1305 of the 32-byte message key
//                                  under wrapKey_R with the all-zero nonce and no AAD,
//                                  ciphertext (32) || tag (16)
//   w = 36+56n    24     nonce (random)
//   w+24          4      ciphertextLength u32 = 16 + 256*k, k >= 1
//   w+28          m      ciphertext: XChaCha20-Poly1305(K, nonce, pad(plaintext), AAD) || tag
//   w+28+m        64     signature: Ed25519(sender identity key,
//                          "haychat-e2ee-envelope-v1" || AAD || bytes [0, w+28+m))
//
//   ss_R      = X25519(ephemeralPrivate, R.encryptionPublicKey)   (all zeros is refused)
//   wrapKey_R = HKDF-SHA256(ikm = ss_R, salt = ephemeralKey || R.encryptionPublicKey,
//                           info = "haychat-e2ee-wrap-v1" || kind (1) || AAD), 32 bytes
//
//   The AAD is not carried; both sides rebuild it (makeDirectMessageAAD, makeRoomKeyAAD,
//   makeRoomKeyForwardAAD, makeVoiceKeyAAD) and it is at most E2EE_AAD_MAX_BYTES.
//
// SealedDirectMessagePlaintext (design 4.4): CBOR map {"content": text}, content 1..
//   CHAT_MESSAGE_MAX_BYTES bytes of UTF-8. encodeSealedDirectMessagePlaintext writes the one
//   canonical encoding A1 67 "content" <text header> <bytes>; the decoder accepts a map of up to
//   16 unique text keys in any order and skips unknown ones, so later fields (replies, edits)
//   can be added inside. It refuses indefinite lengths and trailing bytes.
//
// SenderKeyDistribution plaintext, version 1 (design 6.4), 69 bytes, sealed in a SenderKey
//   envelope:
//
//   0   1   version = 1
//   1   8   roomId i64 (> 0)
//   9   8   epoch i64 (> 0)
//   17  16  chainId
//   33  4   startIndex u32 (< SENDER_CHAIN_MAX_MESSAGES): the index chainKey belongs to
//   37  32  chainKey
//
//   The same plaintext travels in a RoomKeyForward envelope (design 6.6, Full history rooms):
//   one member forwards a chain it holds, its own or another member's, to one newcomer. The
//   envelope has exactly one wrap, for the recipient, is signed by the forwarder, and is sealed
//   under makeRoomKeyForwardAAD, which names the chain's original sender, the forwarder and the
//   recipient. Messages of the chain are still signed by the original sender, so a forwarder
//   can give access to a chain but never forge a message in it.
//
// VoiceKeyPlaintext, version 1 (e2ee-voice-design.md 3.1), 77 bytes, sealed in a VoiceKey
//   envelope with one wrap per member of the epoch in the sender's verified log, the sender
//   excluded, under makeVoiceKeyAAD:
//
//   0   1   version = 1
//   1   8   roomId i64 (> 0)
//   9   8   epoch i64 (> 0): the verified log version the key is for
//   17  16  voiceSessionId: random, one per voice join
//   33  4   generation u32: from 0, one more on every rotation within the voice session
//   37  8   createdAtUnix i64: seconds by the sender's clock
//   45  32  voiceKey: 32 random bytes, used by one voice engine only (common/voice_e2ee.odin)
//
//   The opener checks that the plaintext repeats the AAD's fields. Voice keys are never stored
//   or forwarded by anyone: the server keeps the latest envelope per voice participant in
//   memory only.
//
// SealedRoomMessage, version 1 (design 6.5). At most SEALED_ROOM_MESSAGE_MAX_BYTES in total.
//
//   0       1   version = 1
//   1       8   epoch i64 (> 0)
//   9       16  chainId
//   25      4   index u32 (< SENDER_CHAIN_MAX_MESSAGES)
//   29      24  nonce (random)
//   53      4   ciphertextLength u32 = 16 + 256*k, k >= 1
//   57      m   ciphertext: XChaCha20-Poly1305(messageKey_index, nonce, pad(plaintext), AAD)
//   57+m    64  signature: Ed25519(sender identity key,
//                 "haychat-room-message-v1" || AAD || bytes [0, 57+m))
//
// RoomLogEntry, format 1 (design 6.2). At most ROOM_LOG_ENTRY_MAX_BYTES.
//
//   0     1   format = 1
//   1     8   roomId i64 (> 0)
//   9     8   version i64 (>= 1); also the room's epoch from this entry on
//   17    32  prevHash: SHA-256 of the previous entry's full bytes; zeros for version 1
//   49    1   action (RoomLogAction: 1 Create, 2 Add, 3 Remove, 4 AddManager,
//               5 RemoveManager, 6 Leave, 7 SetAccess)
//   50    8   targetUserId i64 (> 0; 0 for SetAccess)
//   58    32  targetIdentityKey (zeros for SetAccess)
//   90    8   actorUserId i64 (> 0; 0 only for a server Remove)
//   98    32  actorIdentityKey (zeros for a server Remove)
//   130   8   createdAt u64, Unix seconds
//   138   1   hasSettings: 1 for Create and SetAccess, 0 otherwise
//   139   (settings, only when hasSettings is 1)
//         1   access (RoomLogAccess: 2 MemberInvite, 3 AdminInvite)
//         1   historyVisibility (RoomLogHistoryVisibility: 1 FromJoin, 2 Full)
//         1   creatorJoins (0 or 1; 0 for SetAccess)
//         2   managerCount u16 (Create: 1..ROOM_LOG_MANAGERS_MAX; SetAccess: 0)
//         40n managers: userId i64 (> 0, unique) || identityKey (32)
//   s     64  signature: Ed25519(actor identity key,
//               "haychat-room-log-v1" || serverIdentityPublicKey || bytes [0, s));
//               zeros for a server Remove
//
//   The entry hash (hashRoomLogEntry) is SHA-256 over all bytes, signature included.
//
// The AAD builders below have fixed layouts; see each one.

// Limits (design 3.2, 4.5, 6.1, 6.3).
SEALED_ENVELOPE_MAX_BYTES :: 8192
SEALED_ROOM_MESSAGE_MAX_BYTES :: SEALED_ENVELOPE_MAX_BYTES
ENCRYPTED_ROOM_MEMBERS_MAX :: 100
USER_KEYS_FETCH_MAX :: 64
SENDER_CHAIN_MAX_MESSAGES :: 1000
SENDER_CHAIN_MAX_AGE_SECONDS :: 7 * 24 * 60 * 60
SENDER_CHAIN_MAX_AGE :: SENDER_CHAIN_MAX_AGE_SECONDS * time.Second
// One wrap per member, the sender included; managers who are not members get no wraps.
SEALED_ENVELOPE_MAX_WRAPS :: ENCRYPTED_ROOM_MEMBERS_MAX
// Managers a member log may name at once (Create plus AddManager).
ROOM_LOG_MANAGERS_MAX :: 100

ENCRYPTION_PRIVATE_KEY_SIZE :: x25519.SCALAR_SIZE
ENCRYPTION_PUBLIC_KEY_SIZE :: x25519.POINT_SIZE
E2EE_KEY_SIZE :: chacha20poly1305.KEY_SIZE
E2EE_NONCE_SIZE :: chacha20poly1305.XIV_SIZE
E2EE_TAG_SIZE :: chacha20poly1305.TAG_SIZE
E2EE_PADDING_BLOCK :: 256
// Longest AAD an envelope may be sealed with. Every AAD builder below is shorter.
E2EE_AAD_MAX_BYTES :: 256
CLIENT_MESSAGE_ID_SIZE :: 16
CHAIN_ID_SIZE :: 16
ROOM_LOG_HASH_SIZE :: 32
VOICE_SESSION_ID_SIZE :: 16

EncryptionPrivateKeyBytes :: distinct [ENCRYPTION_PRIVATE_KEY_SIZE]u8
EncryptionPublicKeyBytes :: distinct [ENCRYPTION_PUBLIC_KEY_SIZE]u8
// The random per-envelope key K, and a sender chain's per-message key.
MessageKey :: distinct [E2EE_KEY_SIZE]u8
ChainKey :: distinct [E2EE_KEY_SIZE]u8
E2EENonce :: [E2EE_NONCE_SIZE]u8
ClientMessageID :: [CLIENT_MESSAGE_ID_SIZE]u8
ChainID :: [CHAIN_ID_SIZE]u8
RoomLogHash :: [ROOM_LOG_HASH_SIZE]u8
// A voice participant's random per-join ID, and one of its voice keys (e2ee-voice-design.md 3).
VoiceSessionID :: [VOICE_SESSION_ID_SIZE]u8
VoiceKey :: distinct [E2EE_KEY_SIZE]u8

// Domain strings and HKDF labels. Changing one changes every vector in e2ee_test.odin.
ENCRYPTION_KEY_BUNDLE_DOMAIN :: "haychat-e2ee-encryption-key-v1"
ENVELOPE_SIGNATURE_DOMAIN :: "haychat-e2ee-envelope-v1"
ENVELOPE_WRAP_INFO :: "haychat-e2ee-wrap-v1"
DIRECT_MESSAGE_AAD_DOMAIN :: "haychat-dm-v1"
PLAINTEXT_DIRECT_MESSAGE_DOMAIN :: "haychat-dm-plain-v1"
// Protocol 22 (#90): a plaintext room message's signature. Prefix-free against every label.
PLAINTEXT_ROOM_MESSAGE_DOMAIN :: "haychat-room-plain-v1"
ROOM_KEY_AAD_DOMAIN :: "haychat-room-key-v1"
// Its own label (E0's note): no AAD label is a prefix of another.
ROOM_KEY_FORWARD_AAD_DOMAIN :: "haychat-room-key-forward-v1"
ROOM_MESSAGE_AAD_DOMAIN :: "haychat-room-v1"
ROOM_MESSAGE_SIGNATURE_DOMAIN :: "haychat-room-message-v1"
ROOM_LOG_SIGNATURE_DOMAIN :: "haychat-room-log-v1"
SENDER_CHAIN_MESSAGE_INFO :: "haychat-room-msg-v1"
SENDER_CHAIN_STEP_INFO :: "haychat-room-chain-v1"
SAFETY_NUMBER_DOMAIN :: "haychat-safety-number-v1"
// Protocol 21 (e2ee-voice-design.md 3.1, 5.1): the voice key envelope's AAD and the voice frame
// AAD (common/voice_e2ee.odin). Prefix-free against every label above.
VOICE_KEY_AAD_DOMAIN :: "haychat-voice-key-v1"
VOICE_FRAME_AAD_DOMAIN :: "haychat-voice-frame-v1"

// Every failure of the envelope, room message, padding and plaintext procedures. Each has its
// own value so tests and logs can tell them apart; the UI shows one message for all of them
// ("This message could not be decrypted").
E2EEError :: enum u8 {
	None,
	// Encoding and buffers.
	BufferTooSmall, // dst cannot hold the result
	TooLarge, // over SEALED_ENVELOPE_MAX_BYTES or SEALED_ROOM_MESSAGE_MAX_BYTES
	Truncated, // ends inside a field, or a length runs past the end
	TrailingBytes, // bytes after the signature or the last field
	UnsupportedVersion,
	UnknownKind,
	BadWrapCount, // zero wraps, or more than SEALED_ENVELOPE_MAX_WRAPS
	BadRecipientUserID, // a recipient user ID that is not positive
	BadSenderUserID, // a sender user ID that is not positive
	DuplicateRecipient, // two wraps (or recipients) for one user ID
	BadCiphertextLength, // not the tag plus a positive multiple of E2EE_PADDING_BLOCK
	BadRoomID, // a room ID that is not positive
	BadEpoch, // an epoch that is not positive
	BadIndex, // a chain index at or past SENDER_CHAIN_MAX_MESSAGES
	AADTooLarge,
	PlaintextTooLarge, // the sealed result would exceed its maximum size
	// Sealing inputs.
	NoRecipients,
	BadSigningKey, // the identity private key does not match the identity key the AAD names
	BadRecipientKey, // a recipient's X25519 key is of small order
	RandomUnavailable,
	// Opening.
	WrongKind, // a valid envelope of another kind than the caller expects
	WrongRecipients, // a direct message envelope whose wraps are not exactly sender and recipient
	BadSenderKey, // the pinned identity key is not a valid Ed25519 key
	BadSignature,
	NoWrapForRecipient,
	BadEphemeralKey, // the ephemeral key gives an all-zero shared secret
	BadWrap, // the wrap's tag does not verify
	BadCiphertext, // the body's tag does not verify
	BadPadding,
	BadPlaintext, // the opened plaintext is not the expected structure
	MismatchedKeyDistribution, // a SenderKey plaintext names another room, epoch or chain
	// Appended (protocol 20): a RoomKeyForward's forwarder is not positive or is the chain's
	// sender (who re-seals its own chain as a SenderKey envelope).
	BadForwarderUserID,
	// Appended (protocol 21): a VoiceKey plaintext names another room, epoch, voice session,
	// generation or creation time than its AAD.
	MismatchedVoiceKey,
}

EnvelopeKind :: enum u8 {
	DirectMessage  = 1,
	SenderKey      = 2,
	RoomKeyForward = 3,
	VoiceKey       = 4, // protocol 21: a voice participant's key (e2ee-voice-design.md 3.1)
}

EncryptionKeyPair :: struct {
	privateKey: EncryptionPrivateKeyBytes,
	publicKey:  EncryptionPublicKeyBytes,
}

// One recipient of an envelope: a wrap is made for userID under encryptionPublicKey. Callers
// pass keys that verifyEncryptionKeyBundle accepted and that match their pins.
EnvelopeRecipient :: struct {
	userID:              int,
	encryptionPublicKey: EncryptionPublicKeyBytes,
}

KEY_WRAP_WRAPPED_KEY_SIZE :: E2EE_KEY_SIZE + E2EE_TAG_SIZE
KEY_WRAP_SIZE :: 8 + KEY_WRAP_WRAPPED_KEY_SIZE

KeyWrap :: struct {
	recipientUserID: int,
	wrappedKey:      [KEY_WRAP_WRAPPED_KEY_SIZE]u8,
}

SEALED_ENVELOPE_VERSION :: u8(1)
SEALED_ENVELOPE_HEADER_SIZE :: 1 + 1 + ENCRYPTION_PUBLIC_KEY_SIZE + 2
// Everything but the wraps and the padded plaintext.
SEALED_ENVELOPE_OVERHEAD :: SEALED_ENVELOPE_HEADER_SIZE + E2EE_NONCE_SIZE + 4 + E2EE_TAG_SIZE +
	AUTH_SIGNATURE_SIZE

// A decoded envelope. It borrows the bytes it was decoded from: wraps, ciphertext and
// signedBytes are slices of them, valid only while they are. Read wraps with
// SealedEnvelope_wrap or SealedEnvelope_findWrap.
SealedEnvelope :: struct {
	version:      u8,
	kind:         EnvelopeKind,
	ephemeralKey: EncryptionPublicKeyBytes,
	wrapCount:    int,
	wraps:        []u8, // wrapCount * KEY_WRAP_SIZE bytes
	nonce:        E2EENonce,
	ciphertext:   []u8, // padded plaintext and tag
	signature:    SignatureBytes,
	signedBytes:  []u8, // every byte before the signature
}

// ---------------------------------------------------------------------------------------------
// Encryption keys and the signed bundle (design 2.2).

ENCRYPTION_KEY_BUNDLE_SIGNED_SIZE :: len(ENCRYPTION_KEY_BUNDLE_DOMAIN) +
	AUTH_IDENTITY_PUBLIC_KEY_SIZE + ENCRYPTION_PUBLIC_KEY_SIZE + 8

EncryptionKeyBundleSignedBytes :: [ENCRYPTION_KEY_BUNDLE_SIGNED_SIZE]u8

// What a profile publishes (ClientPublishEncryptionKey) and peers fetch (UserKeyBundle).
EncryptionKeyBundle :: struct {
	identityPublicKey:   IdentityPublicKeyBytes,
	encryptionPublicKey: EncryptionPublicKeyBytes,
	createdAt:           u64, // Unix seconds
	signature:           SignatureBytes,
}

generateEncryptionKeyPair :: proc() -> (EncryptionKeyPair, bool) {
	privateKey: EncryptionPrivateKeyBytes
	defer crypto.zero_explicit(&privateKey, size_of(privateKey))
	if !generateRandomBytes(privateKey[:]) {
		return {}, false
	}
	return encryptionKeyPairFromPrivateKey(privateKey), true
}

// Derives the public half. Every 32-byte string is a valid X25519 private key (it is clamped).
encryptionKeyPairFromPrivateKey :: proc(
	privateKey: EncryptionPrivateKeyBytes,
) -> EncryptionKeyPair {
	keyPair := EncryptionKeyPair {
		privateKey = privateKey,
	}
	x25519.scalarmult_basepoint(keyPair.publicKey[:], keyPair.privateKey[:])
	return keyPair
}

EncryptionKeyPair_wipe :: proc(keyPair: ^EncryptionKeyPair) {
	crypto.zero_explicit(keyPair, size_of(keyPair^))
}

// False for a key of small order (including all zeros), for which every shared secret is
// zero. Multiplying by a clamped scalar (a multiple of 8) maps exactly those points to zero.
encryptionPublicKeyIsValid :: proc(publicKey: EncryptionPublicKeyBytes) -> bool {
	publicKeyCopy := publicKey
	probeScalar: [ENCRYPTION_PRIVATE_KEY_SIZE]u8
	probeScalar[0] = 9
	result: [ENCRYPTION_PUBLIC_KEY_SIZE]u8
	x25519.scalarmult(result[:], probeScalar[:], publicKeyCopy[:])
	return crypto.is_zero_constant_time(result[:]) == 0
}

// "haychat-e2ee-encryption-key-v1" || identityPublicKey (32) || encryptionPublicKey (32)
// || createdAt (u64 LE): 102 bytes.
makeEncryptionKeyBundleSignedBytes :: proc(
	identityPublicKey: IdentityPublicKeyBytes,
	encryptionPublicKey: EncryptionPublicKeyBytes,
	createdAt: u64,
) -> EncryptionKeyBundleSignedBytes {
	identityCopy := identityPublicKey
	encryptionCopy := encryptionPublicKey
	signed: EncryptionKeyBundleSignedBytes
	writer := e2eeWriter(signed[:])
	e2eeWriteString(&writer, ENCRYPTION_KEY_BUNDLE_DOMAIN)
	e2eeWriteBytes(&writer, identityCopy[:])
	e2eeWriteBytes(&writer, encryptionCopy[:])
	e2eeWriteU64(&writer, createdAt)
	return signed
}

// Signs encryptionPublicKey with the identity key. The bundle's identityPublicKey is derived
// from identityPrivateKey.
signEncryptionKeyBundle :: proc(
	identityPrivateKey: IdentityPrivateKeyBytes,
	encryptionPublicKey: EncryptionPublicKeyBytes,
	createdAt: u64,
) -> (
	EncryptionKeyBundle,
	bool,
) {
	identityPublicKey, ok := identityPublicKeyFromPrivateKey(identityPrivateKey)
	if !ok || !encryptionPublicKeyIsValid(encryptionPublicKey) {
		return {}, false
	}
	signed := makeEncryptionKeyBundleSignedBytes(identityPublicKey, encryptionPublicKey, createdAt)
	signature, signOK := signBytes(identityPrivateKey, signed[:])
	if !signOK {
		return {}, false
	}
	return EncryptionKeyBundle {
			identityPublicKey = identityPublicKey,
			encryptionPublicKey = encryptionPublicKey,
			createdAt = createdAt,
			signature = signature,
		},
		true
}

// True when the bundle's signature verifies against the bundle's own identity key and the
// encryption key is not of small order. The caller still compares identityPublicKey with its
// pin (design 3.2).
verifyEncryptionKeyBundle :: proc(bundle: EncryptionKeyBundle) -> bool {
	if !encryptionPublicKeyIsValid(bundle.encryptionPublicKey) {
		return false
	}
	signed := makeEncryptionKeyBundleSignedBytes(
		bundle.identityPublicKey,
		bundle.encryptionPublicKey,
		bundle.createdAt,
	)
	return verifySignature(bundle.identityPublicKey, signed[:], bundle.signature)
}

identityPublicKeyFromPrivateKey :: proc(
	privateKeyBytes: IdentityPrivateKeyBytes,
) -> (
	IdentityPublicKeyBytes,
	bool,
) {
	privateKey, ok := identityPrivateKeyFromBytes(privateKeyBytes)
	if !ok {
		return {}, false
	}
	defer ed25519.private_key_clear(&privateKey)
	publicKey: IdentityPublicKeyBytes
	ed25519.private_key_public_bytes(&privateKey, publicKey[:])
	return publicKey, true
}

// ---------------------------------------------------------------------------------------------
// AAD builders (design 4.2, 6.4, 6.5). Each binds the server's identity key, so nothing sealed
// for one server opens as if it came from another.

DIRECT_MESSAGE_AAD_SIZE :: len(DIRECT_MESSAGE_AAD_DOMAIN) + AUTH_IDENTITY_PUBLIC_KEY_SIZE + 8 + 8 +
	2 * AUTH_IDENTITY_PUBLIC_KEY_SIZE + CLIENT_MESSAGE_ID_SIZE
DirectMessageAAD :: [DIRECT_MESSAGE_AAD_SIZE]u8

// The fields of a direct message's AAD. senderIdentityPublicKey and recipientIdentityPublicKey
// are the keys the client has pinned for the two users.
DirectMessageAADFields :: struct {
	serverIdentityPublicKey:    IdentityPublicKeyBytes,
	senderUserID:               int,
	recipientUserID:            int,
	senderIdentityPublicKey:    IdentityPublicKeyBytes,
	recipientIdentityPublicKey: IdentityPublicKeyBytes,
	clientMessageID:            ClientMessageID,
}

// "haychat-dm-v1" || serverIdentityPublicKey (32) || senderUserId (i64) || recipientUserId (i64)
// || senderIdentityKey (32) || recipientIdentityKey (32) || clientMessageId (16): 141 bytes.
makeDirectMessageAAD :: proc(fields: DirectMessageAADFields) -> DirectMessageAAD {
	fields := fields
	aad: DirectMessageAAD
	writer := e2eeWriter(aad[:])
	e2eeWriteString(&writer, DIRECT_MESSAGE_AAD_DOMAIN)
	e2eeWriteBytes(&writer, fields.serverIdentityPublicKey[:])
	e2eeWriteInt(&writer, fields.senderUserID)
	e2eeWriteInt(&writer, fields.recipientUserID)
	e2eeWriteBytes(&writer, fields.senderIdentityPublicKey[:])
	e2eeWriteBytes(&writer, fields.recipientIdentityPublicKey[:])
	e2eeWriteBytes(&writer, fields.clientMessageID[:])
	return aad
}

ROOM_KEY_AAD_SIZE :: len(ROOM_KEY_AAD_DOMAIN) + AUTH_IDENTITY_PUBLIC_KEY_SIZE + 8 + 8 + 8 +
	CHAIN_ID_SIZE
RoomKeyAAD :: [ROOM_KEY_AAD_SIZE]u8

RoomKeyAADFields :: struct {
	serverIdentityPublicKey: IdentityPublicKeyBytes,
	roomID:                  int,
	epoch:                   int,
	senderUserID:            int, // the chain's owner, who seals the distribution
	chainID:                 ChainID,
}

// "haychat-room-key-v1" || serverIdentityPublicKey (32) || roomId (i64) || epoch (i64)
// || senderUserId (i64) || chainId (16): 91 bytes.
makeRoomKeyAAD :: proc(fields: RoomKeyAADFields) -> RoomKeyAAD {
	fields := fields
	aad: RoomKeyAAD
	writer := e2eeWriter(aad[:])
	e2eeWriteString(&writer, ROOM_KEY_AAD_DOMAIN)
	e2eeWriteBytes(&writer, fields.serverIdentityPublicKey[:])
	e2eeWriteInt(&writer, fields.roomID)
	e2eeWriteInt(&writer, fields.epoch)
	e2eeWriteInt(&writer, fields.senderUserID)
	e2eeWriteBytes(&writer, fields.chainID[:])
	return aad
}

ROOM_KEY_FORWARD_AAD_SIZE :: len(ROOM_KEY_FORWARD_AAD_DOMAIN) + AUTH_IDENTITY_PUBLIC_KEY_SIZE +
	8 + 8 + 8 + CHAIN_ID_SIZE + 8 + 8
RoomKeyForwardAAD :: [ROOM_KEY_FORWARD_AAD_SIZE]u8

// The fields of a RoomKeyForward envelope's AAD (design 6.6): which chain (room, epoch, its
// original sender, chain ID), who forwards it, and to whom.
RoomKeyForwardAADFields :: struct {
	serverIdentityPublicKey: IdentityPublicKeyBytes,
	roomID:                  int,
	epoch:                   int,
	senderUserID:            int, // the chain's original sender, who signs its messages
	chainID:                 ChainID,
	forwarderUserID:         int, // the member who seals and signs the forward
	recipientUserID:         int, // the newcomer, the envelope's only wrap
}

// "haychat-room-key-forward-v1" || serverIdentityPublicKey (32) || roomId (i64) || epoch (i64)
// || senderUserId (i64) || chainId (16) || forwarderUserId (i64) || recipientUserId (i64):
// 115 bytes.
makeRoomKeyForwardAAD :: proc(fields: RoomKeyForwardAADFields) -> RoomKeyForwardAAD {
	fields := fields
	aad: RoomKeyForwardAAD
	writer := e2eeWriter(aad[:])
	e2eeWriteString(&writer, ROOM_KEY_FORWARD_AAD_DOMAIN)
	e2eeWriteBytes(&writer, fields.serverIdentityPublicKey[:])
	e2eeWriteInt(&writer, fields.roomID)
	e2eeWriteInt(&writer, fields.epoch)
	e2eeWriteInt(&writer, fields.senderUserID)
	e2eeWriteBytes(&writer, fields.chainID[:])
	e2eeWriteInt(&writer, fields.forwarderUserID)
	e2eeWriteInt(&writer, fields.recipientUserID)
	return aad
}

ROOM_MESSAGE_AAD_SIZE :: len(ROOM_MESSAGE_AAD_DOMAIN) + AUTH_IDENTITY_PUBLIC_KEY_SIZE + 8 + 8 + 8 +
	CHAIN_ID_SIZE + 4 + CLIENT_MESSAGE_ID_SIZE
RoomMessageAAD :: [ROOM_MESSAGE_AAD_SIZE]u8

// What a room message's reader knows from outside the sealed bytes: the server, the room, the
// sender the server names, and the client message ID carried next to the sealed message.
RoomMessageContext :: struct {
	serverIdentityPublicKey: IdentityPublicKeyBytes,
	roomID:                  int,
	senderUserID:            int,
	clientMessageID:         ClientMessageID,
}

// The chain position a room message is sealed under; it travels in the SealedRoomMessage.
RoomMessageHeader :: struct {
	epoch:   int,
	chainID: ChainID,
	index:   u32,
}

// "haychat-room-v1" || serverIdentityPublicKey (32) || roomId (i64) || senderUserId (i64)
// || epoch (i64) || chainId (16) || index (u32) || clientMessageId (16): 107 bytes.
makeRoomMessageAAD :: proc(
	roomContext: RoomMessageContext,
	header: RoomMessageHeader,
) -> RoomMessageAAD {
	roomContext := roomContext
	header := header
	aad: RoomMessageAAD
	writer := e2eeWriter(aad[:])
	e2eeWriteString(&writer, ROOM_MESSAGE_AAD_DOMAIN)
	e2eeWriteBytes(&writer, roomContext.serverIdentityPublicKey[:])
	e2eeWriteInt(&writer, roomContext.roomID)
	e2eeWriteInt(&writer, roomContext.senderUserID)
	e2eeWriteInt(&writer, header.epoch)
	e2eeWriteBytes(&writer, header.chainID[:])
	e2eeWriteU32(&writer, header.index)
	e2eeWriteBytes(&writer, roomContext.clientMessageID[:])
	return aad
}

VOICE_KEY_AAD_SIZE :: len(VOICE_KEY_AAD_DOMAIN) + AUTH_IDENTITY_PUBLIC_KEY_SIZE + 8 + 8 + 8 +
	VOICE_SESSION_ID_SIZE + 4 + 8
VoiceKeyAAD :: [VOICE_KEY_AAD_SIZE]u8

// The fields of a VoiceKey envelope's AAD (e2ee-voice-design.md 3.1). Every one but the server
// key is repeated in the plaintext, and travels next to the envelope in ClientVoiceKey and
// ServerVoiceKey so the server can check the signature.
VoiceKeyAADFields :: struct {
	serverIdentityPublicKey: IdentityPublicKeyBytes,
	roomID:                  int,
	epoch:                   int,
	senderUserID:            int, // the voice participant who made, seals and signs the key
	voiceSessionID:          VoiceSessionID,
	generation:              u32,
	createdAtUnix:           i64,
}

// "haychat-voice-key-v1" || serverIdentityPublicKey (32) || roomId (i64) || epoch (i64)
// || senderUserId (i64) || voiceSessionId (16) || generation (u32) || createdAtUnix (i64):
// 104 bytes.
makeVoiceKeyAAD :: proc(fields: VoiceKeyAADFields) -> VoiceKeyAAD {
	fields := fields
	aad: VoiceKeyAAD
	writer := e2eeWriter(aad[:])
	e2eeWriteString(&writer, VOICE_KEY_AAD_DOMAIN)
	e2eeWriteBytes(&writer, fields.serverIdentityPublicKey[:])
	e2eeWriteInt(&writer, fields.roomID)
	e2eeWriteInt(&writer, fields.epoch)
	e2eeWriteInt(&writer, fields.senderUserID)
	e2eeWriteBytes(&writer, fields.voiceSessionID[:])
	e2eeWriteU32(&writer, fields.generation)
	e2eeWriteU64(&writer, u64(fields.createdAtUnix))
	return aad
}

// ---------------------------------------------------------------------------------------------
// Padding (design 4.4).

// Length of plaintextLength bytes after padding: the next multiple of E2EE_PADDING_BLOCK that
// leaves room for the 0x80 byte, so a full block gains a whole block of padding.
paddedLength :: proc(plaintextLength: int) -> int {
	return (plaintextLength / E2EE_PADDING_BLOCK + 1) * E2EE_PADDING_BLOCK
}

// Writes plaintext, 0x80, then zeros up to paddedLength(len(plaintext)) into dst, and returns
// that length. dst may start at plaintext (padding in place) but must not otherwise overlap it.
padPlaintext :: proc(plaintext: []u8, dst: []u8) -> (n: int, err: E2EEError) {
	total := paddedLength(len(plaintext))
	if len(dst) < total {
		return 0, .BufferTooSmall
	}
	copy(dst[:len(plaintext)], plaintext)
	dst[len(plaintext)] = 0x80
	for index in len(plaintext) + 1 ..< total {
		dst[index] = 0
	}
	return total, .None
}

// Strips the padding and returns the plaintext as a slice of padded. Strict: the length must
// be a positive multiple of E2EE_PADDING_BLOCK, and the padding must be one 0x80 byte followed
// only by zeros, all inside the last block.
unpadPlaintext :: proc(padded: []u8) -> (plaintext: []u8, err: E2EEError) {
	if len(padded) == 0 || len(padded) % E2EE_PADDING_BLOCK != 0 {
		return nil, .BadPadding
	}
	lastBlockStart := len(padded) - E2EE_PADDING_BLOCK
	for index := len(padded) - 1; index >= lastBlockStart; index -= 1 {
		switch padded[index] {
		case 0x00:
			continue
		case 0x80:
			return padded[:index], .None
		case:
			return nil, .BadPadding
		}
	}
	return nil, .BadPadding
}

// ---------------------------------------------------------------------------------------------
// Sealed envelopes (design 4.1).

// Size of an envelope with wrapCount wraps around plaintextLength bytes of unpadded plaintext.
sealedEnvelopeSize :: proc(wrapCount: int, plaintextLength: int) -> int {
	return SEALED_ENVELOPE_OVERHEAD + wrapCount * KEY_WRAP_SIZE + paddedLength(plaintextLength)
}

// Seals plaintext for every recipient and signs the envelope with the sender's identity key,
// writing it into dst. The sender reads its own envelopes later only if it is one of the
// recipients. aad must be the builder's output for this conversation. dst must not overlap
// plaintext or aad. On failure dst holds no partial envelope.
sealEnvelope :: proc(
	kind: EnvelopeKind,
	aad: []u8,
	plaintext: []u8,
	recipients: []EnvelopeRecipient,
	senderIdentityPrivateKey: IdentityPrivateKeyBytes,
	dst: []u8,
) -> (
	n: int,
	err: E2EEError,
) {
	messageKey: MessageKey
	ephemeralPrivateKey: EncryptionPrivateKeyBytes
	nonce: E2EENonce
	defer crypto.zero_explicit(&messageKey, size_of(messageKey))
	defer crypto.zero_explicit(&ephemeralPrivateKey, size_of(ephemeralPrivateKey))
	if !generateRandomBytes(messageKey[:]) ||
	   !generateRandomBytes(ephemeralPrivateKey[:]) ||
	   !generateRandomBytes(nonce[:]) {
		return 0, .RandomUnavailable
	}
	return sealEnvelopeWithRandomness(
		kind,
		aad,
		plaintext,
		recipients,
		senderIdentityPrivateKey,
		messageKey,
		ephemeralPrivateKey,
		nonce,
		dst,
	)
}

// sealEnvelope with its random inputs supplied, for known-answer tests only.
@(private)
sealEnvelopeWithRandomness :: proc(
	kind: EnvelopeKind,
	aad: []u8,
	plaintext: []u8,
	recipients: []EnvelopeRecipient,
	senderIdentityPrivateKey: IdentityPrivateKeyBytes,
	messageKey: MessageKey,
	ephemeralPrivateKey: EncryptionPrivateKeyBytes,
	nonce: E2EENonce,
	dst: []u8,
) -> (
	n: int,
	err: E2EEError,
) {
	if !envelopeKindIsValid(u8(kind)) {
		return 0, .UnknownKind
	}
	if len(aad) > E2EE_AAD_MAX_BYTES {
		return 0, .AADTooLarge
	}
	if len(recipients) == 0 {
		return 0, .NoRecipients
	}
	if len(recipients) > SEALED_ENVELOPE_MAX_WRAPS {
		return 0, .BadWrapCount
	}
	for recipient, index in recipients {
		if recipient.userID <= 0 {
			return 0, .BadRecipientUserID
		}
		for other in recipients[:index] {
			if other.userID == recipient.userID {
				return 0, .DuplicateRecipient
			}
		}
	}
	total := sealedEnvelopeSize(len(recipients), len(plaintext))
	if total > SEALED_ENVELOPE_MAX_BYTES {
		return 0, .PlaintextTooLarge
	}
	if len(dst) < total {
		return 0, .BufferTooSmall
	}

	messageKey := messageKey
	ephemeralPrivateKey := ephemeralPrivateKey
	nonce := nonce
	ephemeralPublicKey: EncryptionPublicKeyBytes
	x25519.scalarmult_basepoint(ephemeralPublicKey[:], ephemeralPrivateKey[:])

	out := dst[:total]
	writer := e2eeWriter(out)
	e2eeWriteU8(&writer, SEALED_ENVELOPE_VERSION)
	e2eeWriteU8(&writer, u8(kind))
	e2eeWriteBytes(&writer, ephemeralPublicKey[:])
	e2eeWriteU16(&writer, u16(len(recipients)))
	for recipient in recipients {
		e2eeWriteInt(&writer, recipient.userID)
		wrapped := out[writer.offset:writer.offset + KEY_WRAP_WRAPPED_KEY_SIZE]
		if !envelopeWrapKey(
			kind,
			aad,
			ephemeralPrivateKey,
			ephemeralPublicKey,
			recipient.encryptionPublicKey,
			messageKey,
			wrapped,
		) {
			crypto.zero_explicit(raw_data(out), len(out))
			return 0, .BadRecipientKey
		}
		writer.offset += KEY_WRAP_WRAPPED_KEY_SIZE
	}
	e2eeWriteBytes(&writer, nonce[:])
	paddedSize := paddedLength(len(plaintext))
	e2eeWriteU32(&writer, u32(paddedSize + E2EE_TAG_SIZE))
	body := out[writer.offset:writer.offset + paddedSize]
	tag := out[writer.offset + paddedSize:writer.offset + paddedSize + E2EE_TAG_SIZE]
	_, _ = padPlaintext(plaintext, body)
	e2eeSeal(messageKey[:], nonce, aad, body, tag, body)
	writer.offset += paddedSize + E2EE_TAG_SIZE

	signedBytes := out[:writer.offset]
	signature, signOK := signWithDomain(
		senderIdentityPrivateKey,
		ENVELOPE_SIGNATURE_DOMAIN,
		aad,
		signedBytes,
	)
	if !signOK {
		crypto.zero_explicit(raw_data(out), len(out))
		return 0, .BadSigningKey
	}
	e2eeWriteBytes(&writer, signature[:])
	assert(writer.offset == total, "sealed envelope size mismatch")
	return total, .None
}

// Reads an envelope's structure without verifying anything cryptographic. The result borrows
// data. Refuses unknown versions and kinds, zero or too many wraps, non-positive or repeated
// recipient IDs, impossible ciphertext lengths and trailing bytes.
decodeSealedEnvelope :: proc(data: []u8) -> (envelope: SealedEnvelope, err: E2EEError) {
	if len(data) > SEALED_ENVELOPE_MAX_BYTES {
		return {}, .TooLarge
	}
	if len(data) < SEALED_ENVELOPE_HEADER_SIZE {
		return {}, .Truncated
	}
	envelope.version = data[0]
	if envelope.version != SEALED_ENVELOPE_VERSION {
		return {}, .UnsupportedVersion
	}
	if !envelopeKindIsValid(data[1]) {
		return {}, .UnknownKind
	}
	envelope.kind = EnvelopeKind(data[1])
	copy(envelope.ephemeralKey[:], data[2:2 + ENCRYPTION_PUBLIC_KEY_SIZE])
	envelope.wrapCount = int(endian.unchecked_get_u16le(data[34:36]))
	if envelope.wrapCount == 0 || envelope.wrapCount > SEALED_ENVELOPE_MAX_WRAPS {
		return {}, .BadWrapCount
	}
	wrapsEnd := SEALED_ENVELOPE_HEADER_SIZE + envelope.wrapCount * KEY_WRAP_SIZE
	if len(data) < wrapsEnd + E2EE_NONCE_SIZE + 4 {
		return {}, .Truncated
	}
	envelope.wraps = data[SEALED_ENVELOPE_HEADER_SIZE:wrapsEnd]
	for index in 0 ..< envelope.wrapCount {
		userID := envelopeWrapUserID(envelope.wraps, index)
		if userID <= 0 {
			return {}, .BadRecipientUserID
		}
		for other in 0 ..< index {
			if envelopeWrapUserID(envelope.wraps, other) == userID {
				return {}, .DuplicateRecipient
			}
		}
	}
	copy(envelope.nonce[:], data[wrapsEnd:wrapsEnd + E2EE_NONCE_SIZE])
	ciphertextLength := int(
		endian.unchecked_get_u32le(data[wrapsEnd + E2EE_NONCE_SIZE:wrapsEnd + E2EE_NONCE_SIZE + 4]),
	)
	ciphertextStart := wrapsEnd + E2EE_NONCE_SIZE + 4
	end := ciphertextStart + ciphertextLength + AUTH_SIGNATURE_SIZE
	if len(data) < end {
		return {}, .Truncated
	}
	if len(data) > end {
		return {}, .TrailingBytes
	}
	if !ciphertextLengthIsValid(ciphertextLength) {
		return {}, .BadCiphertextLength
	}
	envelope.ciphertext = data[ciphertextStart:ciphertextStart + ciphertextLength]
	envelope.signedBytes = data[:ciphertextStart + ciphertextLength]
	copy(envelope.signature[:], data[ciphertextStart + ciphertextLength:end])
	return envelope, .None
}

// The wrap at index (0 ..< wrapCount).
SealedEnvelope_wrap :: proc(envelope: SealedEnvelope, index: int) -> KeyWrap {
	assert(index >= 0 && index < envelope.wrapCount, "envelope wrap index out of range")
	wrap := KeyWrap {
		recipientUserID = envelopeWrapUserID(envelope.wraps, index),
	}
	start := index * KEY_WRAP_SIZE + 8
	copy(wrap.wrappedKey[:], envelope.wraps[start:start + KEY_WRAP_WRAPPED_KEY_SIZE])
	return wrap
}

SealedEnvelope_findWrap :: proc(envelope: SealedEnvelope, userID: int) -> (KeyWrap, bool) {
	for index in 0 ..< envelope.wrapCount {
		if envelopeWrapUserID(envelope.wraps, index) == userID {
			return SealedEnvelope_wrap(envelope, index), true
		}
	}
	return {}, false
}

// Checks a decoded envelope's signature against the sender's pinned identity key and the AAD.
// The server can call this too: it knows every AAD field.
verifySealedEnvelopeSignature :: proc(
	envelope: SealedEnvelope,
	aad: []u8,
	senderIdentityPublicKey: IdentityPublicKeyBytes,
) -> E2EEError {
	if len(aad) > E2EE_AAD_MAX_BYTES {
		return .AADTooLarge
	}
	return verifyWithDomain(
		senderIdentityPublicKey,
		ENVELOPE_SIGNATURE_DOMAIN,
		aad,
		envelope.signedBytes,
		envelope.signature,
	)
}

// Opens an envelope for recipientUserID. Order: structure, then the signature against the
// pinned senderIdentityPublicKey, then the kind, then this recipient's wrap, the body and the
// padding. The plaintext is written into dst (which needs len(ciphertext) - 16 bytes;
// SEALED_ENVELOPE_MAX_BYTES always suffices) and returned as a slice of it. On failure dst
// holds no plaintext.
openEnvelope :: proc(
	data: []u8,
	expectedKind: EnvelopeKind,
	aad: []u8,
	senderIdentityPublicKey: IdentityPublicKeyBytes,
	recipientUserID: int,
	recipientKeyPair: EncryptionKeyPair,
	dst: []u8,
) -> (
	plaintext: []u8,
	err: E2EEError,
) {
	if len(aad) > E2EE_AAD_MAX_BYTES {
		return nil, .AADTooLarge
	}
	envelope := decodeSealedEnvelope(data) or_return
	verifySealedEnvelopeSignature(envelope, aad, senderIdentityPublicKey) or_return
	if envelope.kind != expectedKind {
		return nil, .WrongKind
	}
	return openVerifiedEnvelope(envelope, aad, recipientUserID, recipientKeyPair, dst)
}

// The second half of openEnvelope, for an envelope whose signature and kind were checked.
@(private = "file")
openVerifiedEnvelope :: proc(
	envelope: SealedEnvelope,
	aad: []u8,
	recipientUserID: int,
	recipientKeyPair: EncryptionKeyPair,
	dst: []u8,
) -> (
	plaintext: []u8,
	err: E2EEError,
) {
	paddedSize := len(envelope.ciphertext) - E2EE_TAG_SIZE
	if len(dst) < paddedSize {
		return nil, .BufferTooSmall
	}
	wrap, found := SealedEnvelope_findWrap(envelope, recipientUserID)
	if !found {
		return nil, .NoWrapForRecipient
	}

	messageKey: MessageKey
	defer crypto.zero_explicit(&messageKey, size_of(messageKey))
	unwrapEnvelopeKey(envelope, wrap, aad, recipientKeyPair, &messageKey) or_return

	body := dst[:paddedSize]
	if !e2eeOpen(
		messageKey[:],
		envelope.nonce,
		aad,
		envelope.ciphertext[:paddedSize],
		envelope.ciphertext[paddedSize:],
		body,
	) {
		return nil, .BadCiphertext
	}
	unpadded, padErr := unpadPlaintext(body)
	if padErr != .None {
		crypto.zero_explicit(raw_data(body), len(body))
		return nil, padErr
	}
	return unpadded, .None
}

// ---------------------------------------------------------------------------------------------
// Encrypted direct messages (design 4.4, 4.5).

SealedDirectMessagePlaintext :: struct {
	content: string,
}

SealedDirectMessagePlaintext_deinit :: proc(
	plaintext: ^SealedDirectMessagePlaintext,
	allocator := context.allocator,
) {
	delete(plaintext.content, allocator)
	plaintext.content = ""
}

// The canonical CBOR of SealedDirectMessagePlaintext with CHAT_MESSAGE_MAX_BYTES of content:
// map header (1), "content" (1 + 7), text header (3), content.
DIRECT_MESSAGE_PLAINTEXT_MAX_SIZE :: 1 + 8 + 3 + CHAT_MESSAGE_MAX_BYTES

// Writes CBOR {"content": content} into dst. content must be 1..CHAT_MESSAGE_MAX_BYTES bytes of
// valid UTF-8.
encodeSealedDirectMessagePlaintext :: proc(content: string, dst: []u8) -> (n: int, ok: bool) {
	if !directMessageContentIsValid(content) {
		return 0, false
	}
	headerSize := 1
	if len(content) >= 24 {
		headerSize = len(content) < 256 ? 2 : 3
	}
	total := 1 + 8 + headerSize + len(content)
	if len(dst) < total {
		return 0, false
	}
	writer := e2eeWriter(dst[:total])
	e2eeWriteU8(&writer, 0xA1) // map of one pair
	e2eeWriteU8(&writer, 0x67) // text of 7 bytes
	e2eeWriteString(&writer, "content")
	switch headerSize {
	case 1:
		e2eeWriteU8(&writer, 0x60 | u8(len(content)))
	case 2:
		e2eeWriteU8(&writer, 0x78)
		e2eeWriteU8(&writer, u8(len(content)))
	case:
		e2eeWriteU8(&writer, 0x79)
		endian.unchecked_put_u16be(writer.buffer[writer.offset:], u16(len(content)))
		writer.offset += 2
	}
	e2eeWriteString(&writer, content)
	return total, true
}

// Decodes an opened direct message plaintext with a strict CBOR reader: one definite-length map
// with unique text keys and no trailing bytes. Unknown keys are skipped, so later fields can be
// added. The content is copied with allocator; free it with
// SealedDirectMessagePlaintext_deinit. (core:encoding/cbor is not used here: it accepts trailing
// bytes and leaks the first value of a repeated key, which a peer could repeat at will.)
decodeSealedDirectMessagePlaintext :: proc(
	data: []u8,
	allocator := context.allocator,
) -> (
	plaintext: SealedDirectMessagePlaintext,
	err: E2EEError,
) {
	content, ok := cborFindContent(data)
	if !ok || !directMessageContentIsValid(string(content)) {
		return {}, .BadPlaintext
	}
	cloned, cloneErr := make([]u8, len(content), allocator)
	if cloneErr != nil {
		return {}, .BadPlaintext
	}
	copy(cloned, content)
	return SealedDirectMessagePlaintext{content = string(cloned)}, .None
}

// Most keys a plaintext map may have, and how deep a skipped value may nest.
@(private = "file")
CBOR_PLAINTEXT_MAX_KEYS :: 16
@(private = "file")
CBOR_SKIP_MAX_DEPTH :: 8

@(private = "file")
CborCursor :: struct {
	data:   []u8,
	offset: int,
}

@(private = "file")
cborRemaining :: proc(cursor: ^CborCursor) -> int {
	return len(cursor.data) - cursor.offset
}

// Reads one item head. Refuses indefinite lengths (31) and the reserved values 28..30.
@(private = "file")
cborReadHead :: proc(cursor: ^CborCursor) -> (major: u8, argument: u64, ok: bool) {
	if cborRemaining(cursor) < 1 {
		return 0, 0, false
	}
	initial := cursor.data[cursor.offset]
	cursor.offset += 1
	major = initial >> 5
	info := initial & 0x1F
	size := 0
	switch info {
	case 0 ..= 23:
		return major, u64(info), true
	case 24:
		size = 1
	case 25:
		size = 2
	case 26:
		size = 4
	case 27:
		size = 8
	case:
		return 0, 0, false
	}
	if cborRemaining(cursor) < size {
		return 0, 0, false
	}
	for byteValue in cursor.data[cursor.offset:cursor.offset + size] {
		argument = argument << 8 | u64(byteValue)
	}
	cursor.offset += size
	return major, argument, true
}

// Reads a text or byte string of the given major type and returns its bytes (borrowed).
@(private = "file")
cborReadString :: proc(cursor: ^CborCursor, expectedMajor: u8) -> ([]u8, bool) {
	major, length, ok := cborReadHead(cursor)
	if !ok || major != expectedMajor || length > u64(cborRemaining(cursor)) {
		return nil, false
	}
	bytes := cursor.data[cursor.offset:cursor.offset + int(length)]
	cursor.offset += int(length)
	return bytes, true
}

@(private = "file")
cborSkipValue :: proc(cursor: ^CborCursor, depth: int) -> bool {
	if depth > CBOR_SKIP_MAX_DEPTH {
		return false
	}
	start := cursor.offset
	major, argument, ok := cborReadHead(cursor)
	if !ok {
		return false
	}
	switch major {
	case 0, 1, 7:
		// Integers, simple values and floats: the head is the whole item.
		return true
	case 2, 3:
		cursor.offset = start
		_, stringOK := cborReadString(cursor, major)
		return stringOK
	case 4, 5:
		// Every item takes at least one byte, which bounds the count by what is left.
		items := argument
		if major == 5 {
			if items > u64(cborRemaining(cursor)) {
				return false
			}
			items *= 2
		}
		if items > u64(cborRemaining(cursor)) {
			return false
		}
		for _ in 0 ..< items {
			if !cborSkipValue(cursor, depth + 1) {
				return false
			}
		}
		return true
	case 6:
		return cborSkipValue(cursor, depth + 1)
	}
	return false
}

// The "content" text of a CBOR map that is exactly data, or false.
@(private = "file")
cborFindContent :: proc(data: []u8) -> (content: []u8, ok: bool) {
	cursor := CborCursor {
		data = data,
	}
	major, count, headOK := cborReadHead(&cursor)
	if !headOK || major != 5 || count > CBOR_PLAINTEXT_MAX_KEYS {
		return nil, false
	}
	keys: [CBOR_PLAINTEXT_MAX_KEYS]string
	found := false
	for index in 0 ..< int(count) {
		key, keyOK := cborReadString(&cursor, 3)
		if !keyOK {
			return nil, false
		}
		keys[index] = string(key)
		for earlier in keys[:index] {
			if earlier == keys[index] {
				return nil, false
			}
		}
		if keys[index] == "content" {
			content, found = cborReadString(&cursor, 3)
			if !found {
				return nil, false
			}
		} else if !cborSkipValue(&cursor, 1) {
			return nil, false
		}
	}
	if !found || cursor.offset != len(data) {
		return nil, false
	}
	return content, true
}

// Seals content as a DirectMessage envelope with exactly two wraps, the sender's first, so the
// sender can read its own history. senderIdentityPrivateKey must belong to
// aadFields.senderIdentityPublicKey.
sealDirectMessage :: proc(
	aadFields: DirectMessageAADFields,
	content: string,
	senderEncryptionPublicKey: EncryptionPublicKeyBytes,
	recipientEncryptionPublicKey: EncryptionPublicKeyBytes,
	senderIdentityPrivateKey: IdentityPrivateKeyBytes,
	dst: []u8,
) -> (
	n: int,
	err: E2EEError,
) {
	signerPublicKey, ok := identityPublicKeyFromPrivateKey(senderIdentityPrivateKey)
	if !ok || signerPublicKey != aadFields.senderIdentityPublicKey {
		return 0, .BadSigningKey
	}
	plaintext: [DIRECT_MESSAGE_PLAINTEXT_MAX_SIZE]u8
	defer crypto.zero_explicit(&plaintext, size_of(plaintext))
	plaintextLength, encodeOK := encodeSealedDirectMessagePlaintext(content, plaintext[:])
	if !encodeOK {
		return 0, .BadPlaintext
	}
	aad := makeDirectMessageAAD(aadFields)
	recipients := [2]EnvelopeRecipient {
		{userID = aadFields.senderUserID, encryptionPublicKey = senderEncryptionPublicKey},
		{userID = aadFields.recipientUserID, encryptionPublicKey = recipientEncryptionPublicKey},
	}
	return sealEnvelope(
		.DirectMessage,
		aad[:],
		plaintext[:plaintextLength],
		recipients[:],
		senderIdentityPrivateKey,
		dst,
	)
}

// The server's check of a ClientSealedDirectMessage (design 4.5): size, version, kind, exactly
// two wraps naming the sender and the recipient, and the signature against the sender's
// identity key (aadFields.senderIdentityPublicKey). It learns nothing about the content.
verifyDirectMessageEnvelope :: proc(
	data: []u8,
	aadFields: DirectMessageAADFields,
) -> E2EEError {
	envelope := decodeSealedEnvelope(data) or_return
	aad := makeDirectMessageAAD(aadFields)
	verifySealedEnvelopeSignature(envelope, aad[:], aadFields.senderIdentityPublicKey) or_return
	if envelope.kind != .DirectMessage {
		return .WrongKind
	}
	return checkDirectMessageWraps(envelope, aadFields)
}

// Opens a direct message envelope as ownUserID (the sender or the recipient) and decodes its
// plaintext. aadFields.senderIdentityPublicKey must be the client's pin for the sender: the
// signature is checked against it. Free the result with SealedDirectMessagePlaintext_deinit.
openDirectMessage :: proc(
	data: []u8,
	aadFields: DirectMessageAADFields,
	ownUserID: int,
	ownKeyPair: EncryptionKeyPair,
	allocator := context.allocator,
) -> (
	plaintext: SealedDirectMessagePlaintext,
	err: E2EEError,
) {
	envelope := decodeSealedEnvelope(data) or_return
	aad := makeDirectMessageAAD(aadFields)
	verifySealedEnvelopeSignature(envelope, aad[:], aadFields.senderIdentityPublicKey) or_return
	if envelope.kind != .DirectMessage {
		return {}, .WrongKind
	}
	checkDirectMessageWraps(envelope, aadFields) or_return
	buffer: [SEALED_ENVELOPE_MAX_BYTES]u8
	defer crypto.zero_explicit(&buffer, size_of(buffer))
	opened := openVerifiedEnvelope(envelope, aad[:], ownUserID, ownKeyPair, buffer[:]) or_return
	return decodeSealedDirectMessagePlaintext(opened, allocator)
}

// ---------------------------------------------------------------------------------------------
// Signed plaintext fallback direct messages (design 4.6).

PlaintextDirectMessageFields :: struct {
	serverIdentityPublicKey: IdentityPublicKeyBytes,
	senderUserID:            int,
	recipientUserID:         int,
	clientMessageID:         ClientMessageID,
}

PLAINTEXT_DIRECT_MESSAGE_FIELDS_SIZE :: AUTH_IDENTITY_PUBLIC_KEY_SIZE + 8 + 8 +
	CLIENT_MESSAGE_ID_SIZE

// Signs "haychat-dm-plain-v1" || serverIdentityPublicKey (32) || senderUserId (i64)
// || recipientUserId (i64) || clientMessageId (16) || content. content must be
// 1..CHAT_MESSAGE_MAX_BYTES bytes.
signPlaintextDirectMessage :: proc(
	fields: PlaintextDirectMessageFields,
	content: string,
	senderIdentityPrivateKey: IdentityPrivateKeyBytes,
) -> (
	SignatureBytes,
	bool,
) {
	if len(content) == 0 || len(content) > CHAT_MESSAGE_MAX_BYTES {
		return {}, false
	}
	prefix := makePlaintextDirectMessagePrefix(fields)
	return signWithDomain(
		senderIdentityPrivateKey,
		PLAINTEXT_DIRECT_MESSAGE_DOMAIN,
		prefix[:],
		transmute([]u8)content,
	)
}

// True when signature is the sender's (senderIdentityPublicKey, the client's pin) over these
// fields and content.
verifyPlaintextDirectMessage :: proc(
	fields: PlaintextDirectMessageFields,
	content: string,
	senderIdentityPublicKey: IdentityPublicKeyBytes,
	signature: SignatureBytes,
) -> bool {
	if len(content) == 0 || len(content) > CHAT_MESSAGE_MAX_BYTES {
		return false
	}
	prefix := makePlaintextDirectMessagePrefix(fields)
	result := verifyWithDomain(
		senderIdentityPublicKey,
		PLAINTEXT_DIRECT_MESSAGE_DOMAIN,
		prefix[:],
		transmute([]u8)content,
		signature,
	)
	return result == .None
}

// ---------------------------------------------------------------------------------------------
// Signed plaintext room messages (protocol 22, #90): every message in an unencrypted room is
// signed by its sender, so a server cannot write one in anyone's name.

PlaintextRoomMessageFields :: struct {
	serverIdentityPublicKey: IdentityPublicKeyBytes,
	roomID:                  int,
	senderUserID:            int,
	clientMessageID:         ClientMessageID,
}

PLAINTEXT_ROOM_MESSAGE_FIELDS_SIZE :: AUTH_IDENTITY_PUBLIC_KEY_SIZE + 8 + 8 +
	CLIENT_MESSAGE_ID_SIZE

// Signs "haychat-room-plain-v1" || serverIdentityPublicKey (32) || roomId (i64)
// || senderUserId (i64) || clientMessageId (16) || content. content must be
// 1..CHAT_MESSAGE_MAX_BYTES bytes, the room ID and sender positive and clientMessageId set.
signPlaintextRoomMessage :: proc(
	fields: PlaintextRoomMessageFields,
	content: string,
	senderIdentityPrivateKey: IdentityPrivateKeyBytes,
) -> (
	SignatureBytes,
	bool,
) {
	if !plaintextRoomMessageInputsValid(fields, content) {
		return {}, false
	}
	prefix := makePlaintextRoomMessagePrefix(fields)
	return signWithDomain(
		senderIdentityPrivateKey,
		PLAINTEXT_ROOM_MESSAGE_DOMAIN,
		prefix[:],
		transmute([]u8)content,
	)
}

// True when signature is the sender's (senderIdentityPublicKey: the session's for the server,
// the pin for a client) over these fields and content.
verifyPlaintextRoomMessage :: proc(
	fields: PlaintextRoomMessageFields,
	content: string,
	senderIdentityPublicKey: IdentityPublicKeyBytes,
	signature: SignatureBytes,
) -> bool {
	if !plaintextRoomMessageInputsValid(fields, content) {
		return false
	}
	prefix := makePlaintextRoomMessagePrefix(fields)
	result := verifyWithDomain(
		senderIdentityPublicKey,
		PLAINTEXT_ROOM_MESSAGE_DOMAIN,
		prefix[:],
		transmute([]u8)content,
		signature,
	)
	return result == .None
}

@(private = "file")
plaintextRoomMessageInputsValid :: proc(
	fields: PlaintextRoomMessageFields,
	content: string,
) -> bool {
	return(
		len(content) > 0 &&
		len(content) <= CHAT_MESSAGE_MAX_BYTES &&
		fields.roomID > 0 &&
		fields.senderUserID > 0 &&
		clientMessageIDIsSet(fields.clientMessageID) \
	)
}

@(private = "file")
makePlaintextRoomMessagePrefix :: proc(
	fields: PlaintextRoomMessageFields,
) -> [PLAINTEXT_ROOM_MESSAGE_FIELDS_SIZE]u8 {
	fields := fields
	prefix: [PLAINTEXT_ROOM_MESSAGE_FIELDS_SIZE]u8
	writer := e2eeWriter(prefix[:])
	e2eeWriteBytes(&writer, fields.serverIdentityPublicKey[:])
	e2eeWriteInt(&writer, fields.roomID)
	e2eeWriteInt(&writer, fields.senderUserID)
	e2eeWriteBytes(&writer, fields.clientMessageID[:])
	return prefix
}

// ---------------------------------------------------------------------------------------------
// Sender chains (design 6.3).

// messageKey_i = HKDF-SHA256(ikm = chainKey_i, salt = none, info = "haychat-room-msg-v1")
deriveSenderMessageKey :: proc(chainKey: ChainKey) -> MessageKey {
	chainKey := chainKey
	defer crypto.zero_explicit(&chainKey, size_of(chainKey))
	messageKey: MessageKey
	info := SENDER_CHAIN_MESSAGE_INFO
	hkdf.extract_and_expand(.SHA256, nil, chainKey[:], transmute([]u8)info, messageKey[:])
	return messageKey
}

// chainKey_{i+1} = HKDF-SHA256(ikm = chainKey_i, salt = none, info = "haychat-room-chain-v1")
advanceSenderChainKey :: proc(chainKey: ChainKey) -> ChainKey {
	chainKey := chainKey
	defer crypto.zero_explicit(&chainKey, size_of(chainKey))
	next: ChainKey
	info := SENDER_CHAIN_STEP_INFO
	hkdf.extract_and_expand(.SHA256, nil, chainKey[:], transmute([]u8)info, next[:])
	return next
}

// messageKey_index from the chain key at startIndex (chainKey_0 with startIndex 0, or the key a
// distribution carried). False when index is before startIndex or at or past
// SENDER_CHAIN_MAX_MESSAGES; at most SENDER_CHAIN_MAX_MESSAGES - 1 steps otherwise.
deriveSenderChainMessageKey :: proc(
	startChainKey: ChainKey,
	startIndex: u32,
	index: u32,
) -> (
	MessageKey,
	bool,
) {
	if index < startIndex || index >= SENDER_CHAIN_MAX_MESSAGES {
		return {}, false
	}
	chainKey := startChainKey
	defer crypto.zero_explicit(&chainKey, size_of(chainKey))
	for _ in startIndex ..< index {
		chainKey = advanceSenderChainKey(chainKey)
	}
	return deriveSenderMessageKey(chainKey), true
}

// The sending side of one chain. startKey is what the distribution carries (startIndex 0);
// currentKey steps forward with every message so sending costs one derivation per message.
SenderChain :: struct {
	chainID:     ChainID,
	startKey:    ChainKey, // chainKey_0
	currentKey:  ChainKey, // chainKey_nextIndex
	nextIndex:   u32,
	createdAt:   i64, // Unix seconds
}

SenderChain_create :: proc(createdAtUnixSeconds: i64) -> (chain: SenderChain, ok: bool) {
	if !generateRandomBytes(chain.chainID[:]) || !generateRandomBytes(chain.startKey[:]) {
		SenderChain_wipe(&chain)
		return {}, false
	}
	chain.currentKey = chain.startKey
	chain.createdAt = createdAtUnixSeconds
	return chain, true
}

// The index and key for the next message, advancing the chain. False once the chain has sealed
// SENDER_CHAIN_MAX_MESSAGES messages: start a new chain.
SenderChain_nextMessageKey :: proc(
	chain: ^SenderChain,
) -> (
	index: u32,
	key: MessageKey,
	ok: bool,
) {
	if chain.nextIndex >= SENDER_CHAIN_MAX_MESSAGES {
		return 0, {}, false
	}
	index = chain.nextIndex
	key = deriveSenderMessageKey(chain.currentKey)
	chain.currentKey = advanceSenderChainKey(chain.currentKey)
	chain.nextIndex += 1
	return index, key, true
}

// True when the chain must not seal another message: it is used up or SENDER_CHAIN_MAX_AGE old.
// The chain also ends with its epoch, which the caller tracks.
SenderChain_needsReplacement :: proc(chain: SenderChain, nowUnixSeconds: i64) -> bool {
	exhausted := chain.nextIndex >= SENDER_CHAIN_MAX_MESSAGES
	expired := nowUnixSeconds - chain.createdAt >= SENDER_CHAIN_MAX_AGE_SECONDS
	// A clock that went back cannot prove the chain's age, so it is replaced too.
	clockWentBack := nowUnixSeconds < chain.createdAt
	return exhausted || expired || clockWentBack
}

SenderChain_wipe :: proc(chain: ^SenderChain) {
	crypto.zero_explicit(chain, size_of(chain^))
}

// ---------------------------------------------------------------------------------------------
// Sender key distribution (design 6.4).

SENDER_KEY_DISTRIBUTION_VERSION :: u8(1)
SENDER_KEY_DISTRIBUTION_SIZE :: 1 + 8 + 8 + CHAIN_ID_SIZE + 4 + E2EE_KEY_SIZE

SenderKeyDistribution :: struct {
	roomID:     int,
	epoch:      int,
	chainID:    ChainID,
	startIndex: u32,
	chainKey:   ChainKey, // the chain key at startIndex
}

encodeSenderKeyDistribution :: proc(
	distribution: SenderKeyDistribution,
	dst: []u8,
) -> (
	n: int,
	err: E2EEError,
) {
	distribution := distribution
	checkSenderKeyDistribution(distribution) or_return
	if len(dst) < SENDER_KEY_DISTRIBUTION_SIZE {
		return 0, .BufferTooSmall
	}
	writer := e2eeWriter(dst[:SENDER_KEY_DISTRIBUTION_SIZE])
	e2eeWriteU8(&writer, SENDER_KEY_DISTRIBUTION_VERSION)
	e2eeWriteInt(&writer, distribution.roomID)
	e2eeWriteInt(&writer, distribution.epoch)
	e2eeWriteBytes(&writer, distribution.chainID[:])
	e2eeWriteU32(&writer, distribution.startIndex)
	e2eeWriteBytes(&writer, distribution.chainKey[:])
	return SENDER_KEY_DISTRIBUTION_SIZE, .None
}

decodeSenderKeyDistribution :: proc(
	data: []u8,
) -> (
	distribution: SenderKeyDistribution,
	err: E2EEError,
) {
	if len(data) < SENDER_KEY_DISTRIBUTION_SIZE {
		return {}, .Truncated
	}
	if len(data) > SENDER_KEY_DISTRIBUTION_SIZE {
		return {}, .TrailingBytes
	}
	if data[0] != SENDER_KEY_DISTRIBUTION_VERSION {
		return {}, .UnsupportedVersion
	}
	reader := e2eeReader(data[1:])
	distribution.roomID = e2eeReadInt(&reader)
	distribution.epoch = e2eeReadInt(&reader)
	copy(distribution.chainID[:], e2eeReadBytes(&reader, CHAIN_ID_SIZE))
	distribution.startIndex = e2eeReadU32(&reader)
	copy(distribution.chainKey[:], e2eeReadBytes(&reader, E2EE_KEY_SIZE))
	if err = checkSenderKeyDistribution(distribution); err != .None {
		crypto.zero_explicit(&distribution, size_of(distribution))
		return {}, err
	}
	return distribution, .None
}

// Seals a chain to every recipient (every member of the epoch as the verified log shows them,
// the sender included) as one SenderKey envelope. The AAD is built from aadFields; the
// distribution names the same room, epoch and chain.
sealSenderKeyDistribution :: proc(
	aadFields: RoomKeyAADFields,
	startIndex: u32,
	chainKey: ChainKey,
	recipients: []EnvelopeRecipient,
	senderIdentityPrivateKey: IdentityPrivateKeyBytes,
	dst: []u8,
) -> (
	n: int,
	err: E2EEError,
) {
	if aadFields.senderUserID <= 0 {
		return 0, .BadSenderUserID
	}
	plaintext: [SENDER_KEY_DISTRIBUTION_SIZE]u8
	defer crypto.zero_explicit(&plaintext, size_of(plaintext))
	encodeSenderKeyDistribution(
		SenderKeyDistribution {
			roomID = aadFields.roomID,
			epoch = aadFields.epoch,
			chainID = aadFields.chainID,
			startIndex = startIndex,
			chainKey = chainKey,
		},
		plaintext[:],
	) or_return
	aad := makeRoomKeyAAD(aadFields)
	return sealEnvelope(
		.SenderKey,
		aad[:],
		plaintext[:],
		recipients,
		senderIdentityPrivateKey,
		dst,
	)
}

// Opens a SenderKey envelope sealed by aadFields.senderUserID, whose pinned identity key is
// senderIdentityPublicKey, and checks that the distribution names the AAD's room, epoch and
// chain. The caller also checks that the sender is a member of that epoch in its verified log.
openSenderKeyDistribution :: proc(
	data: []u8,
	aadFields: RoomKeyAADFields,
	senderIdentityPublicKey: IdentityPublicKeyBytes,
	ownUserID: int,
	ownKeyPair: EncryptionKeyPair,
) -> (
	distribution: SenderKeyDistribution,
	err: E2EEError,
) {
	aad := makeRoomKeyAAD(aadFields)
	buffer: [SEALED_ENVELOPE_MAX_BYTES]u8
	defer crypto.zero_explicit(&buffer, size_of(buffer))
	opened := openEnvelope(
		data,
		.SenderKey,
		aad[:],
		senderIdentityPublicKey,
		ownUserID,
		ownKeyPair,
		buffer[:],
	) or_return
	distribution, err = decodeSenderKeyDistribution(opened)
	if err != .None {
		return {}, .BadPlaintext
	}
	if distribution.roomID != aadFields.roomID ||
	   distribution.epoch != aadFields.epoch ||
	   distribution.chainID != aadFields.chainID {
		crypto.zero_explicit(&distribution, size_of(distribution))
		return {}, .MismatchedKeyDistribution
	}
	return distribution, .None
}

// ---------------------------------------------------------------------------------------------
// Forwarded chains (design 6.6, Full history rooms).

// Seals a chain the forwarder holds (startIndex and the chain key there, as the forwarder
// received it) to one recipient as a RoomKeyForward envelope, signed by the forwarder. The
// plaintext is the SenderKeyDistribution layout and names the AAD's room, epoch and chain.
// The forwarder is never the chain's sender: a sender re-seals its own chain as SenderKey.
sealRoomKeyForward :: proc(
	aadFields: RoomKeyForwardAADFields,
	startIndex: u32,
	chainKey: ChainKey,
	recipientEncryptionPublicKey: EncryptionPublicKeyBytes,
	forwarderIdentityPrivateKey: IdentityPrivateKeyBytes,
	dst: []u8,
) -> (
	n: int,
	err: E2EEError,
) {
	checkRoomKeyForwardFields(aadFields) or_return
	plaintext: [SENDER_KEY_DISTRIBUTION_SIZE]u8
	defer crypto.zero_explicit(&plaintext, size_of(plaintext))
	encodeSenderKeyDistribution(
		SenderKeyDistribution {
			roomID = aadFields.roomID,
			epoch = aadFields.epoch,
			chainID = aadFields.chainID,
			startIndex = startIndex,
			chainKey = chainKey,
		},
		plaintext[:],
	) or_return
	aad := makeRoomKeyForwardAAD(aadFields)
	recipients := [1]EnvelopeRecipient {
		{userID = aadFields.recipientUserID, encryptionPublicKey = recipientEncryptionPublicKey},
	}
	return sealEnvelope(
		.RoomKeyForward,
		aad[:],
		plaintext[:],
		recipients[:],
		forwarderIdentityPrivateKey,
		dst,
	)
}

// Checks a decoded RoomKeyForward envelope without opening it, as the server does: the kind,
// exactly one wrap and that it names aadFields.recipientUserID, the fields, and the signature
// against the forwarder's identity key over the forward AAD.
verifyRoomKeyForwardEnvelope :: proc(
	envelope: SealedEnvelope,
	aadFields: RoomKeyForwardAADFields,
	forwarderIdentityPublicKey: IdentityPublicKeyBytes,
) -> E2EEError {
	checkRoomKeyForwardFields(aadFields) or_return
	aad := makeRoomKeyForwardAAD(aadFields)
	verifySealedEnvelopeSignature(envelope, aad[:], forwarderIdentityPublicKey) or_return
	if envelope.kind != .RoomKeyForward {
		return .WrongKind
	}
	if envelope.wrapCount != 1 ||
	   envelopeWrapUserID(envelope.wraps, 0) != aadFields.recipientUserID {
		return .WrongRecipients
	}
	return .None
}

// Opens a RoomKeyForward envelope for aadFields.recipientUserID (this profile) with its key
// pair. Order: structure, the signature against the forwarder's pinned identity key, the kind,
// the single wrap, the body, and that the plaintext names the AAD's room, epoch and chain. The
// caller also checks, in its verified log, that the room has Full history, that the original
// sender was a member of the epoch, and that the forwarder may forward to it.
openRoomKeyForward :: proc(
	data: []u8,
	aadFields: RoomKeyForwardAADFields,
	forwarderIdentityPublicKey: IdentityPublicKeyBytes,
	ownKeyPair: EncryptionKeyPair,
) -> (
	distribution: SenderKeyDistribution,
	err: E2EEError,
) {
	envelope := decodeSealedEnvelope(data) or_return
	verifyRoomKeyForwardEnvelope(envelope, aadFields, forwarderIdentityPublicKey) or_return
	aad := makeRoomKeyForwardAAD(aadFields)
	buffer: [SEALED_ENVELOPE_MAX_BYTES]u8
	defer crypto.zero_explicit(&buffer, size_of(buffer))
	opened := openVerifiedEnvelope(
		envelope,
		aad[:],
		aadFields.recipientUserID,
		ownKeyPair,
		buffer[:],
	) or_return
	distribution, err = decodeSenderKeyDistribution(opened)
	if err != .None {
		return {}, .BadPlaintext
	}
	if distribution.roomID != aadFields.roomID ||
	   distribution.epoch != aadFields.epoch ||
	   distribution.chainID != aadFields.chainID {
		crypto.zero_explicit(&distribution, size_of(distribution))
		return {}, .MismatchedKeyDistribution
	}
	return distribution, .None
}

// ---------------------------------------------------------------------------------------------
// Voice keys (e2ee-voice-design.md 3.1, protocol 21).

VOICE_KEY_PLAINTEXT_VERSION :: u8(1)
VOICE_KEY_PLAINTEXT_SIZE :: 1 + 8 + 8 + VOICE_SESSION_ID_SIZE + 4 + 8 + E2EE_KEY_SIZE

@(private = "file")
encodeVoiceKeyPlaintext :: proc(
	fields: VoiceKeyAADFields,
	voiceKey: VoiceKey,
) -> [VOICE_KEY_PLAINTEXT_SIZE]u8 {
	fields := fields
	voiceKey := voiceKey
	defer crypto.zero_explicit(&voiceKey, size_of(voiceKey))
	plaintext: [VOICE_KEY_PLAINTEXT_SIZE]u8
	writer := e2eeWriter(plaintext[:])
	e2eeWriteU8(&writer, VOICE_KEY_PLAINTEXT_VERSION)
	e2eeWriteInt(&writer, fields.roomID)
	e2eeWriteInt(&writer, fields.epoch)
	e2eeWriteBytes(&writer, fields.voiceSessionID[:])
	e2eeWriteU32(&writer, fields.generation)
	e2eeWriteU64(&writer, u64(fields.createdAtUnix))
	e2eeWriteBytes(&writer, voiceKey[:])
	return plaintext
}

@(private = "file")
checkVoiceKeyFields :: proc(fields: VoiceKeyAADFields) -> E2EEError {
	if fields.roomID <= 0 {
		return .BadRoomID
	}
	if fields.epoch <= 0 {
		return .BadEpoch
	}
	if fields.senderUserID <= 0 {
		return .BadSenderUserID
	}
	return .None
}

// Seals voiceKey for every recipient (the members of aadFields.epoch in the sender's verified
// log, each with the encryption key pinned for them, the sender excluded) as one VoiceKey
// envelope signed by the sender. A recipient that is the sender is refused (WrongRecipients):
// a speaker never needs its own key back.
sealVoiceKey :: proc(
	aadFields: VoiceKeyAADFields,
	voiceKey: VoiceKey,
	recipients: []EnvelopeRecipient,
	senderIdentityPrivateKey: IdentityPrivateKeyBytes,
	dst: []u8,
) -> (
	n: int,
	err: E2EEError,
) {
	checkVoiceKeyFields(aadFields) or_return
	for recipient in recipients {
		if recipient.userID == aadFields.senderUserID {
			return 0, .WrongRecipients
		}
	}
	plaintext := encodeVoiceKeyPlaintext(aadFields, voiceKey)
	defer crypto.zero_explicit(&plaintext, size_of(plaintext))
	aad := makeVoiceKeyAAD(aadFields)
	return sealEnvelope(
		.VoiceKey,
		aad[:],
		plaintext[:],
		recipients,
		senderIdentityPrivateKey,
		dst,
	)
}

// Checks a decoded VoiceKey envelope without opening it, as the server does: the fields, the
// signature against the sender's identity key over the voice key AAD, the kind, and that no
// wrap names the sender. The wrap count is already bounded by decodeSealedEnvelope
// (SEALED_ENVELOPE_MAX_WRAPS, which is ENCRYPTED_ROOM_MEMBERS_MAX).
verifyVoiceKeyEnvelope :: proc(
	envelope: SealedEnvelope,
	aadFields: VoiceKeyAADFields,
	senderIdentityPublicKey: IdentityPublicKeyBytes,
) -> E2EEError {
	checkVoiceKeyFields(aadFields) or_return
	aad := makeVoiceKeyAAD(aadFields)
	verifySealedEnvelopeSignature(envelope, aad[:], senderIdentityPublicKey) or_return
	if envelope.kind != .VoiceKey {
		return .WrongKind
	}
	if _, wrapsSender := SealedEnvelope_findWrap(envelope, aadFields.senderUserID); wrapsSender {
		return .WrongRecipients
	}
	return .None
}

// Opens a VoiceKey envelope for ownUserID (this profile) with its key pair. Order: structure,
// the signature against the sender's PINNED identity key, the kind and the wraps, this
// recipient's wrap, the body, and that the plaintext repeats every AAD field. The caller also
// checks, in its verified log, that the sender is a member of the epoch, and the key's
// freshness (e2ee-voice-design.md 4.2, 4.3). Every failure is final for the envelope.
openVoiceKey :: proc(
	data: []u8,
	aadFields: VoiceKeyAADFields,
	senderIdentityPublicKey: IdentityPublicKeyBytes,
	ownUserID: int,
	ownKeyPair: EncryptionKeyPair,
) -> (
	voiceKey: VoiceKey,
	err: E2EEError,
) {
	envelope := decodeSealedEnvelope(data) or_return
	verifyVoiceKeyEnvelope(envelope, aadFields, senderIdentityPublicKey) or_return
	aad := makeVoiceKeyAAD(aadFields)
	buffer: [SEALED_ENVELOPE_MAX_BYTES]u8
	defer crypto.zero_explicit(&buffer, size_of(buffer))
	opened := openVerifiedEnvelope(envelope, aad[:], ownUserID, ownKeyPair, buffer[:]) or_return
	if len(opened) != VOICE_KEY_PLAINTEXT_SIZE {
		return {}, .BadPlaintext
	}
	if opened[0] != VOICE_KEY_PLAINTEXT_VERSION {
		return {}, .BadPlaintext
	}
	reader := e2eeReader(opened[1:])
	roomID := e2eeReadInt(&reader)
	epoch := e2eeReadInt(&reader)
	voiceSessionID: VoiceSessionID
	copy(voiceSessionID[:], e2eeReadBytes(&reader, VOICE_SESSION_ID_SIZE))
	generation := e2eeReadU32(&reader)
	createdAtUnix := i64(e2eeReadU64(&reader))
	copy(voiceKey[:], e2eeReadBytes(&reader, E2EE_KEY_SIZE))
	if reader.failed ||
	   roomID != aadFields.roomID ||
	   epoch != aadFields.epoch ||
	   voiceSessionID != aadFields.voiceSessionID ||
	   generation != aadFields.generation ||
	   createdAtUnix != aadFields.createdAtUnix {
		crypto.zero_explicit(&voiceKey, size_of(voiceKey))
		return {}, .MismatchedVoiceKey
	}
	return voiceKey, .None
}

// ---------------------------------------------------------------------------------------------
// Sealed room messages (design 6.5).

SEALED_ROOM_MESSAGE_VERSION :: u8(1)
SEALED_ROOM_MESSAGE_HEADER_SIZE :: 1 + 8 + CHAIN_ID_SIZE + 4 + E2EE_NONCE_SIZE + 4
SEALED_ROOM_MESSAGE_OVERHEAD :: SEALED_ROOM_MESSAGE_HEADER_SIZE + E2EE_TAG_SIZE +
	AUTH_SIGNATURE_SIZE

// A decoded room message. ciphertext and signedBytes borrow the bytes it was decoded from.
SealedRoomMessage :: struct {
	version:     u8,
	header:      RoomMessageHeader,
	nonce:       E2EENonce,
	ciphertext:  []u8, // padded plaintext and tag
	signature:   SignatureBytes,
	signedBytes: []u8, // every byte before the signature
}

sealedRoomMessageSize :: proc(plaintextLength: int) -> int {
	return SEALED_ROOM_MESSAGE_OVERHEAD + paddedLength(plaintextLength)
}

// Seals plaintext (the same CBOR as a direct message, encodeSealedDirectMessagePlaintext) under
// messageKey, the key of header.index in the sender's chain, and signs it. On failure dst
// holds no partial message. dst must not overlap plaintext.
sealRoomMessage :: proc(
	roomContext: RoomMessageContext,
	header: RoomMessageHeader,
	messageKey: MessageKey,
	plaintext: []u8,
	senderIdentityPrivateKey: IdentityPrivateKeyBytes,
	dst: []u8,
) -> (
	n: int,
	err: E2EEError,
) {
	nonce: E2EENonce
	if !generateRandomBytes(nonce[:]) {
		return 0, .RandomUnavailable
	}
	return sealRoomMessageWithNonce(
		roomContext,
		header,
		messageKey,
		plaintext,
		senderIdentityPrivateKey,
		nonce,
		dst,
	)
}

// sealRoomMessage with its nonce supplied, for known-answer tests only.
@(private)
sealRoomMessageWithNonce :: proc(
	roomContext: RoomMessageContext,
	header: RoomMessageHeader,
	messageKey: MessageKey,
	plaintext: []u8,
	senderIdentityPrivateKey: IdentityPrivateKeyBytes,
	nonce: E2EENonce,
	dst: []u8,
) -> (
	n: int,
	err: E2EEError,
) {
	checkRoomMessageInputs(roomContext, header) or_return
	total := sealedRoomMessageSize(len(plaintext))
	if total > SEALED_ROOM_MESSAGE_MAX_BYTES {
		return 0, .PlaintextTooLarge
	}
	if len(dst) < total {
		return 0, .BufferTooSmall
	}
	header := header
	nonce := nonce
	messageKey := messageKey
	defer crypto.zero_explicit(&messageKey, size_of(messageKey))
	aad := makeRoomMessageAAD(roomContext, header)
	out := dst[:total]
	writer := e2eeWriter(out)
	e2eeWriteU8(&writer, SEALED_ROOM_MESSAGE_VERSION)
	e2eeWriteInt(&writer, header.epoch)
	e2eeWriteBytes(&writer, header.chainID[:])
	e2eeWriteU32(&writer, header.index)
	e2eeWriteBytes(&writer, nonce[:])
	paddedSize := paddedLength(len(plaintext))
	e2eeWriteU32(&writer, u32(paddedSize + E2EE_TAG_SIZE))
	body := out[writer.offset:writer.offset + paddedSize]
	tag := out[writer.offset + paddedSize:writer.offset + paddedSize + E2EE_TAG_SIZE]
	_, _ = padPlaintext(plaintext, body)
	e2eeSeal(messageKey[:], nonce, aad[:], body, tag, body)
	writer.offset += paddedSize + E2EE_TAG_SIZE

	signature, signOK := signWithDomain(
		senderIdentityPrivateKey,
		ROOM_MESSAGE_SIGNATURE_DOMAIN,
		aad[:],
		out[:writer.offset],
	)
	if !signOK {
		crypto.zero_explicit(raw_data(out), len(out))
		return 0, .BadSigningKey
	}
	e2eeWriteBytes(&writer, signature[:])
	assert(writer.offset == total, "sealed room message size mismatch")
	return total, .None
}

// Reads a room message's structure. The result borrows data. A reader decodes first to learn
// which chain and index the message needs, then calls openRoomMessage with that key.
decodeSealedRoomMessage :: proc(data: []u8) -> (message: SealedRoomMessage, err: E2EEError) {
	if len(data) > SEALED_ROOM_MESSAGE_MAX_BYTES {
		return {}, .TooLarge
	}
	if len(data) < SEALED_ROOM_MESSAGE_HEADER_SIZE {
		return {}, .Truncated
	}
	message.version = data[0]
	if message.version != SEALED_ROOM_MESSAGE_VERSION {
		return {}, .UnsupportedVersion
	}
	reader := e2eeReader(data[:SEALED_ROOM_MESSAGE_HEADER_SIZE])
	reader.offset = 1
	message.header.epoch = e2eeReadInt(&reader)
	copy(message.header.chainID[:], e2eeReadBytes(&reader, CHAIN_ID_SIZE))
	message.header.index = e2eeReadU32(&reader)
	copy(message.nonce[:], e2eeReadBytes(&reader, E2EE_NONCE_SIZE))
	ciphertextLength := int(e2eeReadU32(&reader))
	end := SEALED_ROOM_MESSAGE_HEADER_SIZE + ciphertextLength + AUTH_SIGNATURE_SIZE
	if len(data) < end {
		return {}, .Truncated
	}
	if len(data) > end {
		return {}, .TrailingBytes
	}
	if message.header.epoch <= 0 {
		return {}, .BadEpoch
	}
	if message.header.index >= SENDER_CHAIN_MAX_MESSAGES {
		return {}, .BadIndex
	}
	if !ciphertextLengthIsValid(ciphertextLength) {
		return {}, .BadCiphertextLength
	}
	signatureStart := SEALED_ROOM_MESSAGE_HEADER_SIZE + ciphertextLength
	message.ciphertext = data[SEALED_ROOM_MESSAGE_HEADER_SIZE:signatureStart]
	message.signedBytes = data[:signatureStart]
	copy(message.signature[:], data[signatureStart:end])
	return message, .None
}

// Checks a decoded room message's signature against the sender's pinned identity key. The
// server can call this too: it knows the context.
verifyRoomMessageSignature :: proc(
	message: SealedRoomMessage,
	roomContext: RoomMessageContext,
	senderIdentityPublicKey: IdentityPublicKeyBytes,
) -> E2EEError {
	checkRoomMessageInputs(roomContext, message.header) or_return
	aad := makeRoomMessageAAD(roomContext, message.header)
	return verifyWithDomain(
		senderIdentityPublicKey,
		ROOM_MESSAGE_SIGNATURE_DOMAIN,
		aad[:],
		message.signedBytes,
		message.signature,
	)
}

// Verifies the signature first, then opens the body with messageKey (the key of
// message.header.index in the sender's chain) into dst, which needs len(ciphertext) - 16 bytes,
// and strips the padding. Returns the plaintext as a slice of dst.
openRoomMessage :: proc(
	message: SealedRoomMessage,
	roomContext: RoomMessageContext,
	senderIdentityPublicKey: IdentityPublicKeyBytes,
	messageKey: MessageKey,
	dst: []u8,
) -> (
	plaintext: []u8,
	err: E2EEError,
) {
	paddedSize := len(message.ciphertext) - E2EE_TAG_SIZE
	if paddedSize <= 0 {
		return nil, .BadCiphertextLength
	}
	if len(dst) < paddedSize {
		return nil, .BufferTooSmall
	}
	verifyRoomMessageSignature(message, roomContext, senderIdentityPublicKey) or_return
	messageKey := messageKey
	defer crypto.zero_explicit(&messageKey, size_of(messageKey))
	aad := makeRoomMessageAAD(roomContext, message.header)
	body := dst[:paddedSize]
	if !e2eeOpen(
		messageKey[:],
		message.nonce,
		aad[:],
		message.ciphertext[:paddedSize],
		message.ciphertext[paddedSize:],
		body,
	) {
		return nil, .BadCiphertext
	}
	unpadded, padErr := unpadPlaintext(body)
	if padErr != .None {
		crypto.zero_explicit(raw_data(body), len(body))
		return nil, padErr
	}
	return unpadded, .None
}

// ---------------------------------------------------------------------------------------------
// Safety numbers (design 3.5).

SAFETY_NUMBER_GROUPS :: 12
SAFETY_NUMBER_GROUP_DIGITS :: 5
// Twelve groups of five digits separated by single spaces.
SAFETY_NUMBER_TEXT_SIZE :: SAFETY_NUMBER_GROUPS * (SAFETY_NUMBER_GROUP_DIGITS + 1) - 1

// Each group is 0..99999.
SafetyNumber :: [SAFETY_NUMBER_GROUPS]u32

// SHA-512("haychat-safety-number-v1" || min(a, b) || max(a, b)), keys compared bytewise; each of
// the first twelve 5-byte chunks, read big-endian, mod 100000. Symmetric in a and b.
computeSafetyNumber :: proc(a, b: IdentityPublicKeyBytes) -> SafetyNumber {
	a := a
	b := b
	first, second := a[:], b[:]
	if bytesCompare(first, second) > 0 {
		first, second = second, first
	}
	input: [len(SAFETY_NUMBER_DOMAIN) + 2 * AUTH_IDENTITY_PUBLIC_KEY_SIZE]u8
	writer := e2eeWriter(input[:])
	e2eeWriteString(&writer, SAFETY_NUMBER_DOMAIN)
	e2eeWriteBytes(&writer, first)
	e2eeWriteBytes(&writer, second)
	digest: [64]u8
	crypto_hash.hash_bytes_to_buffer(.SHA512, input[:], digest[:])

	number: SafetyNumber
	for group in 0 ..< SAFETY_NUMBER_GROUPS {
		chunk: u64
		for byteValue in digest[group * 5:group * 5 + 5] {
			chunk = chunk << 8 | u64(byteValue)
		}
		number[group] = u32(chunk % 100_000)
	}
	return number
}

// "12345 67890 ..." in ASCII; string(text[:]) is the display form.
formatSafetyNumber :: proc(number: SafetyNumber) -> [SAFETY_NUMBER_TEXT_SIZE]u8 {
	text: [SAFETY_NUMBER_TEXT_SIZE]u8
	offset := 0
	for group, groupIndex in number {
		if groupIndex > 0 {
			text[offset] = ' '
			offset += 1
		}
		value := group
		for digit := SAFETY_NUMBER_GROUP_DIGITS - 1; digit >= 0; digit -= 1 {
			text[offset + digit] = '0' + u8(value % 10)
			value /= 10
		}
		offset += SAFETY_NUMBER_GROUP_DIGITS
	}
	return text
}

// ---------------------------------------------------------------------------------------------
// The member log (design 6.2).

RoomLogAction :: enum u8 {
	Create        = 1,
	Add           = 2,
	Remove        = 3,
	AddManager    = 4,
	RemoveManager = 5,
	Leave         = 6,
	SetAccess     = 7,
}

// The log's own wire values. They follow the schema numbers of design 9.2 (1 Public, 2 Member
// invite, 3 Admin invite; 1 From join, 2 Full), but an encrypted room is never Public.
RoomLogAccess :: enum u8 {
	MemberInvite = 2,
	AdminInvite  = 3,
}

RoomLogHistoryVisibility :: enum u8 {
	FromJoin = 1,
	Full     = 2,
}

RoomLogManager :: struct {
	userID:      int,
	identityKey: IdentityPublicKeyBytes,
}

// Create and SetAccess only. On SetAccess, historyVisibility repeats the room's (it never
// changes), creatorJoins is false and managers is empty.
RoomLogSettings :: struct {
	access:            RoomLogAccess,
	historyVisibility: RoomLogHistoryVisibility,
	creatorJoins:      bool,
	// Borrowed: the caller's slice when encoding, the decoder's buffer when decoding.
	managers:          []RoomLogManager,
}

RoomLogEntry :: struct {
	roomID:            int,
	version:           int,
	prevHash:          RoomLogHash,
	action:            RoomLogAction,
	targetUserID:      int,
	targetIdentityKey: IdentityPublicKeyBytes,
	actorUserID:       int, // 0 for a server removal
	actorIdentityKey:  IdentityPublicKeyBytes, // zeros for a server removal
	createdAt:         u64, // Unix seconds
	settings:          RoomLogSettings, // read only for Create and SetAccess
	signature:         SignatureBytes, // zeros for a server removal
}

// The head a client keeps per room in its key store. version 0 means none.
RoomLogHead :: struct {
	version: int,
	hash:    RoomLogHash,
}

RoomLogError :: enum u8 {
	None,
	// Encoding.
	BufferTooSmall,
	TooLarge, // over ROOM_LOG_ENTRY_MAX_BYTES
	Truncated,
	TrailingBytes,
	UnsupportedFormat,
	UnknownAction,
	BadRoomID, // not positive
	BadVersion, // below 1
	BadUserID, // a negative actor, a non-positive target or manager
	BadTarget, // SetAccess with a target, or another action without one
	BadSettings, // settings on the wrong action, missing, or with fields their action forbids
	BadAccess,
	BadHistoryVisibility,
	TooManyManagers,
	DuplicateManager,
	BadSigningKey, // signRoomLogEntry: the private key does not decode
	// Replay.
	WrongRoom,
	VersionNotNext, // version is not the head's plus one
	BadPrevHash,
	FirstEntryNotCreate,
	UnexpectedCreate, // a Create after version 1
	Unsigned, // an action that needs a signature has actor 0
	MalformedUnsigned, // a server Remove with an actor key or a signature
	BadActorKey, // the actor's identity key is not a valid Ed25519 key
	BadSignature,
	PinMismatch, // a named identity key differs from the client's pin
	IdentityKeyMismatch, // the log names one user with two identity keys
	CreatorNotTarget, // Create's target is not its actor
	CreatorNotManager, // Create does not name its creator as a manager
	NotAuthorized, // the actor may not make this change
	AlreadyMember,
	NotMember,
	AlreadyManager,
	NotManager,
	LastManager, // removing the last manager while the room has members
	RoomFull, // an Add past ENCRYPTED_ROOM_MEMBERS_MAX
	LeaveNotSelf, // a Leave signed by someone other than its target
	HistoryVisibilityChanged, // a SetAccess with another history visibility
	EmptyLog,
	Fork, // the entry at the known head's version has another hash
	Rollback, // the log ends before the known head
}

ROOM_LOG_ENTRY_FORMAT :: u8(1)
// Everything up to and including the hasSettings byte.
ROOM_LOG_ENTRY_FIXED_SIZE :: 1 + 8 + 8 + ROOM_LOG_HASH_SIZE + 1 + 8 +
	AUTH_IDENTITY_PUBLIC_KEY_SIZE + 8 + AUTH_IDENTITY_PUBLIC_KEY_SIZE + 8 + 1
ROOM_LOG_SETTINGS_FIXED_SIZE :: 1 + 1 + 1 + 2
ROOM_LOG_MANAGER_SIZE :: 8 + AUTH_IDENTITY_PUBLIC_KEY_SIZE
ROOM_LOG_ENTRY_MIN_BYTES :: ROOM_LOG_ENTRY_FIXED_SIZE + AUTH_SIGNATURE_SIZE
ROOM_LOG_ENTRY_MAX_BYTES :: ROOM_LOG_ENTRY_FIXED_SIZE + ROOM_LOG_SETTINGS_FIXED_SIZE +
	ROOM_LOG_MANAGERS_MAX * ROOM_LOG_MANAGER_SIZE + AUTH_SIGNATURE_SIZE

roomLogActionHasSettings :: proc(action: RoomLogAction) -> bool {
	return action == .Create || action == .SetAccess
}

roomLogEntrySize :: proc(entry: RoomLogEntry) -> int {
	size := ROOM_LOG_ENTRY_MIN_BYTES
	if roomLogActionHasSettings(entry.action) {
		size += ROOM_LOG_SETTINGS_FIXED_SIZE + len(entry.settings.managers) * ROOM_LOG_MANAGER_SIZE
	}
	return size
}

// Writes entry, signature included as it stands, into dst. Refuses an entry that the decoder
// would refuse, so nothing malformed can be produced. The server writes its own unsigned Remove
// with this (actor 0, zero key, zero signature).
encodeRoomLogEntry :: proc(entry: RoomLogEntry, dst: []u8) -> (n: int, err: RoomLogError) {
	checkRoomLogEntryShape(entry) or_return
	total := roomLogEntrySize(entry)
	if len(dst) < total {
		return 0, .BufferTooSmall
	}
	writeRoomLogEntryUnsigned(entry, dst[:total])
	signature := entry.signature
	copy(dst[total - AUTH_SIGNATURE_SIZE:total], signature[:])
	return total, .None
}

// Sets entry.actorIdentityKey to the key of actorIdentityPrivateKey and entry.signature to that
// key's signature over "haychat-room-log-v1" || serverIdentityPublicKey || the entry's bytes
// before the signature. The caller sets every other field (actorUserID included) first.
signRoomLogEntry :: proc(
	entry: ^RoomLogEntry,
	serverIdentityPublicKey: IdentityPublicKeyBytes,
	actorIdentityPrivateKey: IdentityPrivateKeyBytes,
) -> RoomLogError {
	actorKey, ok := identityPublicKeyFromPrivateKey(actorIdentityPrivateKey)
	if !ok {
		return .BadSigningKey
	}
	entry.actorIdentityKey = actorKey
	checkRoomLogEntryShape(entry^) or_return
	if entry.actorUserID == 0 {
		return .Unsigned
	}
	buffer: [ROOM_LOG_ENTRY_MAX_BYTES]u8
	total := roomLogEntrySize(entry^)
	writeRoomLogEntryUnsigned(entry^, buffer[:total])
	serverKey := serverIdentityPublicKey
	signature, signOK := signWithDomain(
		actorIdentityPrivateKey,
		ROOM_LOG_SIGNATURE_DOMAIN,
		serverKey[:],
		buffer[:total - AUTH_SIGNATURE_SIZE],
	)
	if !signOK {
		return .BadSigningKey
	}
	entry.signature = signature
	return .None
}

// Decodes an entry's structure. managers receives Create's manager list
// (ROOM_LOG_MANAGERS_MAX entries always suffice) and entry.settings.managers is a slice of it.
// Verifies no signature: replay does that.
decodeRoomLogEntry :: proc(
	data: []u8,
	managers: []RoomLogManager,
) -> (
	entry: RoomLogEntry,
	err: RoomLogError,
) {
	if len(data) > ROOM_LOG_ENTRY_MAX_BYTES {
		return {}, .TooLarge
	}
	if len(data) < ROOM_LOG_ENTRY_MIN_BYTES {
		return {}, .Truncated
	}
	if data[0] != ROOM_LOG_ENTRY_FORMAT {
		return {}, .UnsupportedFormat
	}
	reader := e2eeReader(data[:len(data) - AUTH_SIGNATURE_SIZE])
	reader.offset = 1
	entry.roomID = e2eeReadInt(&reader)
	entry.version = e2eeReadInt(&reader)
	copy(entry.prevHash[:], e2eeReadBytes(&reader, ROOM_LOG_HASH_SIZE))
	actionByte := e2eeReadU8(&reader)
	if actionByte < u8(RoomLogAction.Create) || actionByte > u8(RoomLogAction.SetAccess) {
		return {}, .UnknownAction
	}
	entry.action = RoomLogAction(actionByte)
	entry.targetUserID = e2eeReadInt(&reader)
	copy(entry.targetIdentityKey[:], e2eeReadBytes(&reader, AUTH_IDENTITY_PUBLIC_KEY_SIZE))
	entry.actorUserID = e2eeReadInt(&reader)
	copy(entry.actorIdentityKey[:], e2eeReadBytes(&reader, AUTH_IDENTITY_PUBLIC_KEY_SIZE))
	entry.createdAt = e2eeReadU64(&reader)
	hasSettings := e2eeReadU8(&reader)
	if hasSettings > 1 || (hasSettings == 1) != roomLogActionHasSettings(entry.action) {
		return {}, .BadSettings
	}
	if hasSettings == 1 {
		settingsBytes := e2eeReadBytes(&reader, ROOM_LOG_SETTINGS_FIXED_SIZE)
		if reader.failed {
			return {}, .Truncated
		}
		if settingsBytes[0] != u8(RoomLogAccess.MemberInvite) &&
		   settingsBytes[0] != u8(RoomLogAccess.AdminInvite) {
			return {}, .BadAccess
		}
		if settingsBytes[1] != u8(RoomLogHistoryVisibility.FromJoin) &&
		   settingsBytes[1] != u8(RoomLogHistoryVisibility.Full) {
			return {}, .BadHistoryVisibility
		}
		if settingsBytes[2] > 1 {
			return {}, .BadSettings
		}
		entry.settings.access = RoomLogAccess(settingsBytes[0])
		entry.settings.historyVisibility = RoomLogHistoryVisibility(settingsBytes[1])
		entry.settings.creatorJoins = settingsBytes[2] == 1
		managerCount := int(endian.unchecked_get_u16le(settingsBytes[3:5]))
		if managerCount > ROOM_LOG_MANAGERS_MAX {
			return {}, .TooManyManagers
		}
		if managerCount > len(managers) {
			return {}, .BufferTooSmall
		}
		for index in 0 ..< managerCount {
			managers[index].userID = e2eeReadInt(&reader)
			copy(
				managers[index].identityKey[:],
				e2eeReadBytes(&reader, AUTH_IDENTITY_PUBLIC_KEY_SIZE),
			)
		}
		entry.settings.managers = managers[:managerCount]
	}
	if reader.failed {
		return {}, .Truncated
	}
	if reader.offset != len(reader.data) {
		return {}, .TrailingBytes
	}
	copy(entry.signature[:], data[len(data) - AUTH_SIGNATURE_SIZE:])
	checkRoomLogEntryShape(entry) or_return
	return entry, .None
}

// SHA-256 over the entry's full bytes, signature included: the next entry's prevHash.
hashRoomLogEntry :: proc(data: []u8) -> RoomLogHash {
	return RoomLogHash(hashBytes(data))
}

// Looks up the client's pin for userID. pinned is false when the client has no pin, which is a
// first use: replay accepts the key the log names and reports it in RoomLogState.identities,
// and the caller pins it after the replay succeeds. A lookup must not change pins itself.
RoomLogPinLookup :: #type proc(userData: rawptr, userID: int) -> (
	identityKey: IdentityPublicKeyBytes,
	pinned: bool,
)

RoomLogContext :: struct {
	serverIdentityPublicKey: IdentityPublicKeyBytes,
	lookupPin:               RoomLogPinLookup, // nil: no pins (every key is a first use)
	pinUserData:             rawptr,
}

// The state a verified log proves. Free it with RoomLogState_deinit.
RoomLogState :: struct {
	roomID:            int,
	version:           int, // the head's version: the room's current epoch; 0 before Create
	headHash:          RoomLogHash,
	access:            RoomLogAccess,
	historyVisibility: RoomLogHistoryVisibility,
	members:           map[int]IdentityPublicKeyBytes,
	managers:          map[int]IdentityPublicKeyBytes,
	// Every user the log has named (target, actor or manager) with the key it named. The caller
	// pins the ones it had no pin for.
	identities:        map[int]IdentityPublicKeyBytes,
}

RoomLogState_init :: proc(roomID: int, allocator := context.allocator) -> RoomLogState {
	return RoomLogState {
		roomID = roomID,
		members = make(map[int]IdentityPublicKeyBytes, allocator),
		managers = make(map[int]IdentityPublicKeyBytes, allocator),
		identities = make(map[int]IdentityPublicKeyBytes, allocator),
	}
}

RoomLogState_deinit :: proc(state: ^RoomLogState) {
	delete(state.members)
	delete(state.managers)
	delete(state.identities)
	state^ = {}
}

RoomLogState_head :: proc(state: RoomLogState) -> RoomLogHead {
	return RoomLogHead{version = state.version, hash = state.headHash}
}

RoomLogState_isMember :: proc(state: RoomLogState, userID: int) -> bool {
	return userID in state.members
}

RoomLogState_isManager :: proc(state: RoomLogState, userID: int) -> bool {
	return userID in state.managers
}

// Checks that data is the valid next entry for state without changing state, and returns it
// decoded (settings.managers is cleared: it pointed into a buffer of this procedure; the
// managers are in the state after RoomLogState_apply). A client can run it on an entry before
// sending it, and the server on an entry before storing it.
RoomLogState_validate :: proc(
	state: ^RoomLogState,
	data: []u8,
	ctx: RoomLogContext,
) -> (
	entry: RoomLogEntry,
	err: RoomLogError,
) {
	managers: [ROOM_LOG_MANAGERS_MAX]RoomLogManager
	entry = validateRoomLogEntry(state, data, ctx, managers[:]) or_return
	entry.settings.managers = nil
	return entry, .None
}

// Validates data as the next entry and applies it. On failure state is unchanged. A live entry
// whose version is the head's own is a duplicate when hashRoomLogEntry(data) == state.headHash
// and a fork otherwise; this procedure refuses both with VersionNotNext.
RoomLogState_apply :: proc(
	state: ^RoomLogState,
	data: []u8,
	ctx: RoomLogContext,
) -> (
	entry: RoomLogEntry,
	err: RoomLogError,
) {
	managers: [ROOM_LOG_MANAGERS_MAX]RoomLogManager
	entry = validateRoomLogEntry(state, data, ctx, managers[:]) or_return

	switch entry.action {
	case .Create:
		state.access = entry.settings.access
		state.historyVisibility = entry.settings.historyVisibility
		for manager in entry.settings.managers {
			state.managers[manager.userID] = manager.identityKey
			state.identities[manager.userID] = manager.identityKey
		}
		if entry.settings.creatorJoins {
			state.members[entry.actorUserID] = entry.actorIdentityKey
		}
	case .Add:
		state.members[entry.targetUserID] = entry.targetIdentityKey
	case .Remove, .Leave:
		delete_key(&state.members, entry.targetUserID)
	case .AddManager:
		state.managers[entry.targetUserID] = entry.targetIdentityKey
	case .RemoveManager:
		delete_key(&state.managers, entry.targetUserID)
	case .SetAccess:
		state.access = entry.settings.access
	}
	if entry.targetUserID != 0 {
		state.identities[entry.targetUserID] = entry.targetIdentityKey
	}
	if entry.actorUserID != 0 {
		state.identities[entry.actorUserID] = entry.actorIdentityKey
	}
	state.version = entry.version
	state.headHash = hashRoomLogEntry(data)
	entry.settings.managers = nil
	return entry, .None
}

// Replays a whole log (every entry from version 1, in order) and returns the state it proves.
// With knownHead (the head verified earlier, from the key store), a log whose entry at that
// version has another hash is a Fork and a log that ends before it is a Rollback. On failure the
// state is freed and failedIndex names the entry (len(entries) for a Rollback).
replayRoomLog :: proc(
	roomID: int,
	entries: [][]u8,
	ctx: RoomLogContext,
	knownHead := RoomLogHead{},
	allocator := context.allocator,
) -> (
	state: RoomLogState,
	err: RoomLogError,
	failedIndex: int,
) {
	if len(entries) == 0 {
		return {}, .EmptyLog, 0
	}
	state = RoomLogState_init(roomID, allocator)
	for data, index in entries {
		if _, applyErr := RoomLogState_apply(&state, data, ctx); applyErr != .None {
			RoomLogState_deinit(&state)
			return {}, applyErr, index
		}
		if knownHead.version > 0 &&
		   state.version == knownHead.version &&
		   state.headHash != knownHead.hash {
			RoomLogState_deinit(&state)
			return {}, .Fork, index
		}
	}
	if knownHead.version > state.version {
		RoomLogState_deinit(&state)
		return {}, .Rollback, len(entries)
	}
	return state, .None, 0
}

@(private = "file")
validateRoomLogEntry :: proc(
	state: ^RoomLogState,
	data: []u8,
	ctx: RoomLogContext,
	managers: []RoomLogManager,
) -> (
	entry: RoomLogEntry,
	err: RoomLogError,
) {
	entry = decodeRoomLogEntry(data, managers) or_return
	if entry.roomID != state.roomID {
		return {}, .WrongRoom
	}
	if entry.version != state.version + 1 {
		return {}, .VersionNotNext
	}
	if entry.prevHash != state.headHash {
		return {}, .BadPrevHash
	}
	if state.version == 0 && entry.action != .Create {
		return {}, .FirstEntryNotCreate
	}
	if state.version > 0 && entry.action == .Create {
		return {}, .UnexpectedCreate
	}

	// The signature. Only a Remove may be unsigned, and then it carries no actor at all.
	zeroKey: IdentityPublicKeyBytes
	zeroSignature: SignatureBytes
	signed := entry.actorUserID != 0
	if !signed {
		if entry.action != .Remove {
			return {}, .Unsigned
		}
		if entry.actorIdentityKey != zeroKey || entry.signature != zeroSignature {
			return {}, .MalformedUnsigned
		}
	} else {
		serverKey := ctx.serverIdentityPublicKey
		#partial switch verifyWithDomain(
			entry.actorIdentityKey,
			ROOM_LOG_SIGNATURE_DOMAIN,
			serverKey[:],
			data[:len(data) - AUTH_SIGNATURE_SIZE],
			entry.signature,
		) {
		case .None:
		case .BadSenderKey:
			return {}, .BadActorKey
		case:
			return {}, .BadSignature
		}
	}

	// Every identity key the entry names must agree with the log so far, with the client's pins
	// and with the entry's other mentions of the same user.
	named: [ROOM_LOG_MANAGERS_MAX + 2]RoomLogManager
	namedCount := 0
	if signed {
		named[namedCount] = {entry.actorUserID, entry.actorIdentityKey}
		namedCount += 1
	}
	if entry.targetUserID != 0 {
		named[namedCount] = {entry.targetUserID, entry.targetIdentityKey}
		namedCount += 1
	}
	if entry.action == .Create {
		for manager in entry.settings.managers {
			named[namedCount] = manager
			namedCount += 1
		}
	}
	for mention, index in named[:namedCount] {
		for earlier in named[:index] {
			if earlier.userID == mention.userID && earlier.identityKey != mention.identityKey {
				return {}, .IdentityKeyMismatch
			}
		}
		if known, found := state.identities[mention.userID]; found {
			if known != mention.identityKey {
				return {}, .IdentityKeyMismatch
			}
		}
		if ctx.lookupPin != nil {
			pin, pinned := ctx.lookupPin(ctx.pinUserData, mention.userID)
			if pinned && pin != mention.identityKey {
				return {}, .PinMismatch
			}
		}
	}

	actorIsManager := signed && entry.actorUserID in state.managers
	actorIsMember := signed && entry.actorUserID in state.members
	switch entry.action {
	case .Create:
		if entry.targetUserID != entry.actorUserID {
			return {}, .CreatorNotTarget
		}
		creatorListed := false
		for manager in entry.settings.managers {
			if manager.userID == entry.actorUserID {
				creatorListed = true
			}
		}
		if !creatorListed {
			return {}, .CreatorNotManager
		}
	case .Add:
		if entry.targetUserID in state.members {
			return {}, .AlreadyMember
		}
		if !actorIsManager && !(state.access == .MemberInvite && actorIsMember) {
			return {}, .NotAuthorized
		}
		if len(state.members) >= ENCRYPTED_ROOM_MEMBERS_MAX {
			return {}, .RoomFull
		}
	case .Remove:
		if signed && !actorIsManager {
			return {}, .NotAuthorized
		}
		if entry.targetUserID not_in state.members {
			return {}, .NotMember
		}
	case .AddManager:
		if !actorIsManager {
			return {}, .NotAuthorized
		}
		if entry.targetUserID in state.managers {
			return {}, .AlreadyManager
		}
		if len(state.managers) >= ROOM_LOG_MANAGERS_MAX {
			return {}, .TooManyManagers
		}
	case .RemoveManager:
		if !actorIsManager {
			return {}, .NotAuthorized
		}
		if entry.targetUserID not_in state.managers {
			return {}, .NotManager
		}
		if len(state.managers) == 1 && len(state.members) > 0 {
			return {}, .LastManager
		}
	case .Leave:
		if entry.actorUserID != entry.targetUserID {
			return {}, .LeaveNotSelf
		}
		if entry.targetUserID not_in state.members {
			return {}, .NotMember
		}
	case .SetAccess:
		if !actorIsManager {
			return {}, .NotAuthorized
		}
		if entry.settings.historyVisibility != state.historyVisibility {
			return {}, .HistoryVisibilityChanged
		}
	}
	return entry, .None
}

// The structural rules shared by the encoder and the decoder.
@(private = "file")
checkRoomLogEntryShape :: proc(entry: RoomLogEntry) -> RoomLogError {
	if entry.action < .Create || entry.action > .SetAccess {
		return .UnknownAction
	}
	if entry.roomID <= 0 {
		return .BadRoomID
	}
	if entry.version < 1 {
		return .BadVersion
	}
	if entry.actorUserID < 0 {
		return .BadUserID
	}
	zeroKey: IdentityPublicKeyBytes
	if entry.action == .SetAccess {
		if entry.targetUserID != 0 || entry.targetIdentityKey != zeroKey {
			return .BadTarget
		}
	} else if entry.targetUserID == 0 {
		return .BadTarget
	} else if entry.targetUserID < 0 {
		return .BadUserID
	}
	if !roomLogActionHasSettings(entry.action) {
		return .None
	}
	settings := entry.settings
	if settings.access != .MemberInvite && settings.access != .AdminInvite {
		return .BadAccess
	}
	if settings.historyVisibility != .FromJoin && settings.historyVisibility != .Full {
		return .BadHistoryVisibility
	}
	if len(settings.managers) > ROOM_LOG_MANAGERS_MAX {
		return .TooManyManagers
	}
	if entry.action == .SetAccess {
		if settings.creatorJoins || len(settings.managers) != 0 {
			return .BadSettings
		}
		return .None
	}
	if len(settings.managers) == 0 {
		return .BadSettings
	}
	for manager, index in settings.managers {
		if manager.userID <= 0 {
			return .BadUserID
		}
		for other in settings.managers[:index] {
			if other.userID == manager.userID {
				return .DuplicateManager
			}
		}
	}
	return .None
}

// Writes every field but the signature, and zeros in its place. out is exactly the entry size.
@(private = "file")
writeRoomLogEntryUnsigned :: proc(entry: RoomLogEntry, out: []u8) {
	entry := entry
	writer := e2eeWriter(out)
	e2eeWriteU8(&writer, ROOM_LOG_ENTRY_FORMAT)
	e2eeWriteInt(&writer, entry.roomID)
	e2eeWriteInt(&writer, entry.version)
	e2eeWriteBytes(&writer, entry.prevHash[:])
	e2eeWriteU8(&writer, u8(entry.action))
	e2eeWriteInt(&writer, entry.targetUserID)
	e2eeWriteBytes(&writer, entry.targetIdentityKey[:])
	e2eeWriteInt(&writer, entry.actorUserID)
	e2eeWriteBytes(&writer, entry.actorIdentityKey[:])
	e2eeWriteU64(&writer, entry.createdAt)
	if roomLogActionHasSettings(entry.action) {
		e2eeWriteU8(&writer, 1)
		e2eeWriteU8(&writer, u8(entry.settings.access))
		e2eeWriteU8(&writer, u8(entry.settings.historyVisibility))
		e2eeWriteU8(&writer, entry.settings.creatorJoins ? 1 : 0)
		e2eeWriteU16(&writer, u16(len(entry.settings.managers)))
		for manager in entry.settings.managers {
			manager := manager
			e2eeWriteInt(&writer, manager.userID)
			e2eeWriteBytes(&writer, manager.identityKey[:])
		}
	} else {
		e2eeWriteU8(&writer, 0)
	}
	for index in writer.offset ..< len(out) {
		out[index] = 0
	}
	assert(writer.offset + AUTH_SIGNATURE_SIZE == len(out), "room log entry size mismatch")
}

// ---------------------------------------------------------------------------------------------
// Internals.

@(private = "file")
envelopeKindIsValid :: proc(kind: u8) -> bool {
	return kind >= u8(EnvelopeKind.DirectMessage) && kind <= u8(EnvelopeKind.VoiceKey)
}

@(private = "file")
ciphertextLengthIsValid :: proc(length: int) -> bool {
	padded := length - E2EE_TAG_SIZE
	return padded >= E2EE_PADDING_BLOCK && padded % E2EE_PADDING_BLOCK == 0
}

@(private = "file")
envelopeWrapUserID :: proc(wraps: []u8, index: int) -> int {
	start := index * KEY_WRAP_SIZE
	return int(i64(endian.unchecked_get_u64le(wraps[start:start + 8])))
}

@(private = "file")
checkDirectMessageWraps :: proc(
	envelope: SealedEnvelope,
	aadFields: DirectMessageAADFields,
) -> E2EEError {
	if envelope.wrapCount != 2 || aadFields.senderUserID == aadFields.recipientUserID {
		return .WrongRecipients
	}
	_, hasSender := SealedEnvelope_findWrap(envelope, aadFields.senderUserID)
	_, hasRecipient := SealedEnvelope_findWrap(envelope, aadFields.recipientUserID)
	if !hasSender || !hasRecipient {
		return .WrongRecipients
	}
	return .None
}

@(private = "file")
checkSenderKeyDistribution :: proc(distribution: SenderKeyDistribution) -> E2EEError {
	if distribution.roomID <= 0 {
		return .BadRoomID
	}
	if distribution.epoch <= 0 {
		return .BadEpoch
	}
	if distribution.startIndex >= SENDER_CHAIN_MAX_MESSAGES {
		return .BadIndex
	}
	return .None
}

@(private = "file")
checkRoomKeyForwardFields :: proc(fields: RoomKeyForwardAADFields) -> E2EEError {
	if fields.roomID <= 0 {
		return .BadRoomID
	}
	if fields.epoch <= 0 {
		return .BadEpoch
	}
	if fields.senderUserID <= 0 {
		return .BadSenderUserID
	}
	if fields.forwarderUserID <= 0 || fields.forwarderUserID == fields.senderUserID {
		return .BadForwarderUserID
	}
	if fields.recipientUserID <= 0 {
		return .BadRecipientUserID
	}
	if fields.recipientUserID == fields.forwarderUserID {
		return .DuplicateRecipient
	}
	return .None
}

@(private = "file")
checkRoomMessageInputs :: proc(
	roomContext: RoomMessageContext,
	header: RoomMessageHeader,
) -> E2EEError {
	if roomContext.roomID <= 0 {
		return .BadRoomID
	}
	if roomContext.senderUserID <= 0 {
		return .BadSenderUserID
	}
	if header.epoch <= 0 {
		return .BadEpoch
	}
	if header.index >= SENDER_CHAIN_MAX_MESSAGES {
		return .BadIndex
	}
	return .None
}

@(private = "file")
directMessageContentIsValid :: proc(content: string) -> bool {
	if len(content) == 0 || len(content) > CHAT_MESSAGE_MAX_BYTES {
		return false
	}
	return utf8.valid_string(content)
}

@(private = "file")
makePlaintextDirectMessagePrefix :: proc(
	fields: PlaintextDirectMessageFields,
) -> [PLAINTEXT_DIRECT_MESSAGE_FIELDS_SIZE]u8 {
	fields := fields
	prefix: [PLAINTEXT_DIRECT_MESSAGE_FIELDS_SIZE]u8
	writer := e2eeWriter(prefix[:])
	e2eeWriteBytes(&writer, fields.serverIdentityPublicKey[:])
	e2eeWriteInt(&writer, fields.senderUserID)
	e2eeWriteInt(&writer, fields.recipientUserID)
	e2eeWriteBytes(&writer, fields.clientMessageID[:])
	return prefix
}

// wrapKey_R = HKDF-SHA256(ikm = X25519(ephemeralPrivate, R), salt = ephemeralPublic || R,
// info = "haychat-e2ee-wrap-v1" || kind || AAD), and wrapped = XChaCha20-Poly1305(wrapKey_R,
// 0^24, K) with no AAD. False for a recipient key of small order.
@(private = "file")
envelopeWrapKey :: proc(
	kind: EnvelopeKind,
	aad: []u8,
	ephemeralPrivateKey: EncryptionPrivateKeyBytes,
	ephemeralPublicKey: EncryptionPublicKeyBytes,
	recipientPublicKey: EncryptionPublicKeyBytes,
	messageKey: MessageKey,
	wrapped: []u8,
) -> bool {
	ephemeralPrivateKey := ephemeralPrivateKey
	recipientPublicKey := recipientPublicKey
	messageKey := messageKey
	defer crypto.zero_explicit(&ephemeralPrivateKey, size_of(ephemeralPrivateKey))
	defer crypto.zero_explicit(&messageKey, size_of(messageKey))
	sharedSecret: [ENCRYPTION_PUBLIC_KEY_SIZE]u8
	defer crypto.zero_explicit(&sharedSecret, size_of(sharedSecret))
	x25519.scalarmult(sharedSecret[:], ephemeralPrivateKey[:], recipientPublicKey[:])
	if crypto.is_zero_constant_time(sharedSecret[:]) == 1 {
		return false
	}
	wrapKey := deriveEnvelopeWrapKey(
		sharedSecret,
		ephemeralPublicKey,
		recipientPublicKey,
		kind,
		aad,
	)
	defer crypto.zero_explicit(&wrapKey, size_of(wrapKey))
	zeroNonce: E2EENonce
	e2eeSeal(
		wrapKey[:],
		zeroNonce,
		nil,
		wrapped[:E2EE_KEY_SIZE],
		wrapped[E2EE_KEY_SIZE:KEY_WRAP_WRAPPED_KEY_SIZE],
		messageKey[:],
	)
	return true
}

@(private = "file")
unwrapEnvelopeKey :: proc(
	envelope: SealedEnvelope,
	wrap: KeyWrap,
	aad: []u8,
	recipientKeyPair: EncryptionKeyPair,
	messageKey: ^MessageKey,
) -> E2EEError {
	recipientKeyPair := recipientKeyPair
	wrap := wrap
	defer EncryptionKeyPair_wipe(&recipientKeyPair)
	ephemeralKey := envelope.ephemeralKey
	sharedSecret: [ENCRYPTION_PUBLIC_KEY_SIZE]u8
	defer crypto.zero_explicit(&sharedSecret, size_of(sharedSecret))
	x25519.scalarmult(sharedSecret[:], recipientKeyPair.privateKey[:], ephemeralKey[:])
	if crypto.is_zero_constant_time(sharedSecret[:]) == 1 {
		return .BadEphemeralKey
	}
	wrapKey := deriveEnvelopeWrapKey(
		sharedSecret,
		envelope.ephemeralKey,
		recipientKeyPair.publicKey,
		envelope.kind,
		aad,
	)
	defer crypto.zero_explicit(&wrapKey, size_of(wrapKey))
	zeroNonce: E2EENonce
	if !e2eeOpen(
		wrapKey[:],
		zeroNonce,
		nil,
		wrap.wrappedKey[:E2EE_KEY_SIZE],
		wrap.wrappedKey[E2EE_KEY_SIZE:],
		messageKey^[:],
	) {
		return .BadWrap
	}
	return .None
}

@(private)
deriveEnvelopeWrapKey :: proc(
	sharedSecret: [ENCRYPTION_PUBLIC_KEY_SIZE]u8,
	ephemeralPublicKey: EncryptionPublicKeyBytes,
	recipientPublicKey: EncryptionPublicKeyBytes,
	kind: EnvelopeKind,
	aad: []u8,
) -> [E2EE_KEY_SIZE]u8 {
	sharedSecret := sharedSecret
	ephemeralPublicKey := ephemeralPublicKey
	recipientPublicKey := recipientPublicKey
	defer crypto.zero_explicit(&sharedSecret, size_of(sharedSecret))
	salt: [2 * ENCRYPTION_PUBLIC_KEY_SIZE]u8
	copy(salt[:ENCRYPTION_PUBLIC_KEY_SIZE], ephemeralPublicKey[:])
	copy(salt[ENCRYPTION_PUBLIC_KEY_SIZE:], recipientPublicKey[:])
	info: [len(ENVELOPE_WRAP_INFO) + 1 + E2EE_AAD_MAX_BYTES]u8
	assert(len(aad) <= E2EE_AAD_MAX_BYTES, "envelope AAD too long")
	writer := e2eeWriter(info[:])
	e2eeWriteString(&writer, ENVELOPE_WRAP_INFO)
	e2eeWriteU8(&writer, u8(kind))
	e2eeWriteBytes(&writer, aad)
	wrapKey: [E2EE_KEY_SIZE]u8
	hkdf.extract_and_expand(.SHA256, salt[:], sharedSecret[:], info[:writer.offset], wrapKey[:])
	return wrapKey
}

// XChaCha20-Poly1305 seal of plaintext into ciphertext (same length; may alias exactly).
@(private = "file")
e2eeSeal :: proc(
	key: []u8,
	nonce: E2EENonce,
	aad: []u8,
	ciphertext: []u8,
	tag: []u8,
	plaintext: []u8,
) {
	nonce := nonce
	ctx: chacha20poly1305.Context
	chacha20poly1305.init_xchacha(&ctx, key)
	defer chacha20poly1305.reset(&ctx)
	chacha20poly1305.seal(&ctx, ciphertext, tag, nonce[:], aad, plaintext)
}

// XChaCha20-Poly1305 open of ciphertext into plaintext (same length; may alias exactly).
@(private = "file")
e2eeOpen :: proc(
	key: []u8,
	nonce: E2EENonce,
	aad: []u8,
	ciphertext: []u8,
	tag: []u8,
	plaintext: []u8,
) -> bool {
	nonce := nonce
	ctx: chacha20poly1305.Context
	chacha20poly1305.init_xchacha(&ctx, key)
	defer chacha20poly1305.reset(&ctx)
	return chacha20poly1305.open(&ctx, plaintext, nonce[:], aad, ciphertext, tag)
}

// The longest byte string any of these procedures signs: a domain, an AAD (or the server key,
// or a plaintext message's fields) and an envelope's bytes before the signature.
@(private = "file")
E2EE_SIGNED_BYTES_MAX :: 32 + E2EE_AAD_MAX_BYTES + SEALED_ENVELOPE_MAX_BYTES

@(private = "file")
signWithDomain :: proc(
	privateKey: IdentityPrivateKeyBytes,
	domain: string,
	aad: []u8,
	body: []u8,
) -> (
	SignatureBytes,
	bool,
) {
	buffer: [E2EE_SIGNED_BYTES_MAX]u8
	total := len(domain) + len(aad) + len(body)
	if total > len(buffer) {
		return {}, false
	}
	writer := e2eeWriter(buffer[:total])
	e2eeWriteString(&writer, domain)
	e2eeWriteBytes(&writer, aad)
	e2eeWriteBytes(&writer, body)
	return signBytes(privateKey, buffer[:total])
}

@(private = "file")
verifyWithDomain :: proc(
	publicKeyBytes: IdentityPublicKeyBytes,
	domain: string,
	aad: []u8,
	body: []u8,
	signature: SignatureBytes,
) -> E2EEError {
	publicKey, ok := identityPublicKeyFromBytes(publicKeyBytes)
	if !ok {
		return .BadSenderKey
	}
	defer ed25519.public_key_clear(&publicKey)
	buffer: [E2EE_SIGNED_BYTES_MAX]u8
	total := len(domain) + len(aad) + len(body)
	if total > len(buffer) {
		return .TooLarge
	}
	writer := e2eeWriter(buffer[:total])
	e2eeWriteString(&writer, domain)
	e2eeWriteBytes(&writer, aad)
	e2eeWriteBytes(&writer, body)
	signatureCopy := signature
	if !ed25519.verify(&publicKey, buffer[:total], signatureCopy[:]) {
		return .BadSignature
	}
	return .None
}

@(private = "file")
bytesCompare :: proc(a, b: []u8) -> int {
	for index in 0 ..< min(len(a), len(b)) {
		if a[index] != b[index] {
			return a[index] < b[index] ? -1 : 1
		}
	}
	return len(a) - len(b)
}

// A cursor over a buffer whose size the caller has already checked; writes are unchecked
// beyond the slice bounds check.
@(private = "file")
E2EEWriter :: struct {
	buffer: []u8,
	offset: int,
}

@(private = "file")
e2eeWriter :: proc(buffer: []u8) -> E2EEWriter {
	return E2EEWriter{buffer = buffer}
}

@(private = "file")
e2eeWriteU8 :: proc(writer: ^E2EEWriter, value: u8) {
	writer.buffer[writer.offset] = value
	writer.offset += 1
}

@(private = "file")
e2eeWriteU16 :: proc(writer: ^E2EEWriter, value: u16) {
	endian.unchecked_put_u16le(writer.buffer[writer.offset:writer.offset + 2], value)
	writer.offset += 2
}

@(private = "file")
e2eeWriteU32 :: proc(writer: ^E2EEWriter, value: u32) {
	endian.unchecked_put_u32le(writer.buffer[writer.offset:writer.offset + 4], value)
	writer.offset += 4
}

@(private = "file")
e2eeWriteU64 :: proc(writer: ^E2EEWriter, value: u64) {
	endian.unchecked_put_u64le(writer.buffer[writer.offset:writer.offset + 8], value)
	writer.offset += 8
}

@(private = "file")
e2eeWriteInt :: proc(writer: ^E2EEWriter, value: int) {
	e2eeWriteU64(writer, u64(i64(value)))
}

@(private = "file")
e2eeWriteBytes :: proc(writer: ^E2EEWriter, bytes: []u8) {
	copy(writer.buffer[writer.offset:writer.offset + len(bytes)], bytes)
	writer.offset += len(bytes)
}

@(private = "file")
e2eeWriteString :: proc(writer: ^E2EEWriter, text: string) {
	copy(writer.buffer[writer.offset:writer.offset + len(text)], text)
	writer.offset += len(text)
}

// A cursor that records a short read in failed and returns zeros from then on, so a decoder
// can read every field and check once.
@(private = "file")
E2EEReader :: struct {
	data:   []u8,
	offset: int,
	failed: bool,
}

@(private = "file", rodata)
E2EE_READER_ZEROS: [64]u8

@(private = "file")
e2eeReader :: proc(data: []u8) -> E2EEReader {
	return E2EEReader{data = data}
}

@(private = "file")
e2eeReadBytes :: proc(reader: ^E2EEReader, count: int) -> []u8 {
	if reader.failed || len(reader.data) - reader.offset < count {
		reader.failed = true
		assert(count <= len(E2EE_READER_ZEROS), "e2ee reader field too long")
		return E2EE_READER_ZEROS[:count]
	}
	bytes := reader.data[reader.offset:reader.offset + count]
	reader.offset += count
	return bytes
}

@(private = "file")
e2eeReadU8 :: proc(reader: ^E2EEReader) -> u8 {
	return e2eeReadBytes(reader, 1)[0]
}

@(private = "file")
e2eeReadU32 :: proc(reader: ^E2EEReader) -> u32 {
	return endian.unchecked_get_u32le(e2eeReadBytes(reader, 4))
}

@(private = "file")
e2eeReadU64 :: proc(reader: ^E2EEReader) -> u64 {
	return endian.unchecked_get_u64le(e2eeReadBytes(reader, 8))
}

@(private = "file")
e2eeReadInt :: proc(reader: ^E2EEReader) -> int {
	return int(i64(e2eeReadU64(reader)))
}
