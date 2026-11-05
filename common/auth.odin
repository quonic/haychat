package common

import "core:crypto"
import "core:crypto/chacha20poly1305"
import "core:crypto/ecdh"
import "core:crypto/ed25519"
import crypto_hash "core:crypto/hash"
import "core:crypto/hkdf"
import "core:crypto/x25519"
import "core:encoding/cbor"
import "core:encoding/endian"
import encoding_hex "core:encoding/hex"
import "core:strings"

AUTH_IDENTITY_PRIVATE_KEY_SIZE :: ed25519.PRIVATE_KEY_SIZE
AUTH_IDENTITY_PUBLIC_KEY_SIZE :: ed25519.PUBLIC_KEY_SIZE
AUTH_SIGNATURE_SIZE :: ed25519.SIGNATURE_SIZE
KEY_EXCHANGE_PRIVATE_KEY_SIZE :: x25519.SCALAR_SIZE
KEY_EXCHANGE_PUBLIC_KEY_SIZE :: x25519.POINT_SIZE
SHARED_SECRET_SIZE :: x25519.POINT_SIZE
SESSION_ID_SIZE :: 16
AUTH_CHALLENGE_SIZE :: 32
TRANSPORT_KEY_SIZE :: chacha20poly1305.KEY_SIZE
TRANSPORT_NONCE_SIZE :: chacha20poly1305.XIV_SIZE
TRANSPORT_TAG_SIZE :: chacha20poly1305.TAG_SIZE
// sessionID || channel || sequence (LE). Binding the channel means a packet sealed for one
// channel can never be opened as a packet of another, even with the same sequence.
TRANSPORT_AAD_SIZE :: SESSION_ID_SIZE + 1 + 8
FINGERPRINT_SIZE :: 32

// HKDF info for the transport key schedule. Protocol 9 changed the key schedule from two keys
// (no info) to four, so the label names the version; a peer on the old schedule derives
// different keys and cannot open anything.
TRANSPORT_HKDF_INFO :: "haychat transport v2"
TRANSPORT_KEY_COUNT :: 4

// How far behind the highest accepted voice sequence a datagram may arrive. 64 frames are
// 1.28 s of voice at 50 packets per second, longer than any jitter buffer waits.
REPLAY_WINDOW_SIZE :: 64

// Voice datagram envelope (voice-rooms-design.md 3.3): kind (1) || sequence LE (8) ||
// ciphertext (n) || tag (16). The nonce is derived from the sequence and never sent.
VOICE_DATAGRAM_KIND_FRAME :: u8(0x01)
VOICE_DATAGRAM_HEADER_SIZE :: 1 + 8
VOICE_DATAGRAM_OVERHEAD :: VOICE_DATAGRAM_HEADER_SIZE + TRANSPORT_TAG_SIZE

IdentityPrivateKeyBytes :: [AUTH_IDENTITY_PRIVATE_KEY_SIZE]u8
IdentityPublicKeyBytes :: [AUTH_IDENTITY_PUBLIC_KEY_SIZE]u8
SignatureBytes :: [AUTH_SIGNATURE_SIZE]u8
KeyExchangePrivateKeyBytes :: [KEY_EXCHANGE_PRIVATE_KEY_SIZE]u8
KeyExchangePublicKeyBytes :: [KEY_EXCHANGE_PUBLIC_KEY_SIZE]u8
SharedSecretBytes :: [SHARED_SECRET_SIZE]u8
SessionID :: [SESSION_ID_SIZE]u8
AuthChallengeBytes :: [AUTH_CHALLENGE_SIZE]u8
TransportKey :: [TRANSPORT_KEY_SIZE]u8
TransportNonce :: [TRANSPORT_NONCE_SIZE]u8
TransportTag :: [TRANSPORT_TAG_SIZE]u8
TransportAAD :: [TRANSPORT_AAD_SIZE]u8
FingerprintBytes :: [FINGERPRINT_SIZE]u8

SessionRole :: enum u8 {
	Client,
	Server,
}

HandshakePhase :: enum u8 {
	Disconnected,
	ClientHelloSent,
	ServerHelloSent,
	AwaitingChallengeResponse,
	AwaitingAuthResult,
	Established,
	Failed,
}

PeerTrustState :: enum u8 {
	Unknown,
	Trusted,
	Changed,
}

// The transport channels that carry encrypted traffic. The values are the ENet channel IDs:
// the server's NetworkChannel.Chat and NetworkChannel.Voice and the client's
// STARTUP_AUTH_CHANNEL_CHAT use the same numbers (both sides assert it at compile time).
TransportChannel :: enum u8 {
	Control = 1, // reliable and ordered; every CBOR packet
	Voice   = 2, // unsequenced datagrams; voice frames only
}

// One key per channel and direction. Separate keys per channel give domain separation: the
// voice channel's deterministic nonces and the control channel's random nonces never share
// a key, so they cannot collide.
TransportKeySet :: struct {
	clientToServer: [TransportChannel]TransportKey,
	serverToClient: [TransportChannel]TransportKey,
}

DirectionalTransportKeys :: struct {
	sendKey:    [TransportChannel]TransportKey,
	receiveKey: [TransportChannel]TransportKey,
}

// The send half of one channel. active is false until TransportState_activate fills the key,
// and again after a wipe, so a zeroed state can never seal with the all-zero key.
ChannelSendState :: struct {
	key:          TransportKey,
	nextSequence: u64,
	active:       bool,
}

ControlReceiveState :: struct {
	key:          TransportKey,
	nextSequence: u64, // strict: reliable and ordered, so any gap is an attack or a bug
	active:       bool,
}

// Sliding replay window over the most recent REPLAY_WINDOW_SIZE sequences.
ReplayWindow :: struct {
	highest: u64, // highest accepted sequence
	bitmap:  u64, // bit i set: sequence (highest - i) was accepted
	hasAny:  bool,
}

ReplayCheckResult :: enum u8 {
	Fresh, // not seen, and inside or ahead of the window
	Duplicate, // already accepted
	TooOld, // at or below highest - REPLAY_WINDOW_SIZE
}

VoiceOpenResult :: enum u8 {
	Ok,
	Malformed, // short datagram, unknown kind, or a destination buffer that is too small
	Replayed,
	TooOld,
	BadTag,
	Inactive, // no voice key: never activated, or the state was taken or wiped
}

// Why voice datagrams were dropped. A bad voice datagram is counted, never fatal: ENet does
// not authenticate datagrams, so tearing the session down would let a spoofer disconnect
// people.
VoiceReceiveStats :: struct {
	accepted:  u64,
	malformed: u64,
	replayed:  u64,
	tooOld:    u64,
	badTag:    u64,
	inactive:  u64,
}

VoiceReceiveState :: struct {
	key:    TransportKey,
	window: ReplayWindow,
	stats:  VoiceReceiveStats,
	active: bool,
}

// Each channel half is its own struct so that different threads can own them: the control
// halves stay with the code that runs the handshake (the server router, the client network
// worker), and the voice halves move to whoever handles voice (TransportState_takeVoiceState).
TransportState :: struct {
	role:           SessionRole,
	phase:          HandshakePhase,
	peerTrustState: PeerTrustState,
	sessionID:      SessionID,
	controlSend:    ChannelSendState,
	controlReceive: ControlReceiveState,
	// Moved out to the thread that owns voice after activation; see
	// TransportState_takeVoiceState.
	voiceSend:      ChannelSendState,
	voiceReceive:   VoiceReceiveState,
}

HandshakeTranscript :: struct {
	serverHelloProof: ServerHelloProof,
	clientAuthProof:  ClientAuthProof,
}

generateRandomBytes :: proc(dst: []u8) -> bool {
	if !crypto.HAS_RAND_BYTES {
		return false
	}

	crypto.rand_bytes(dst)
	return true
}

generateSessionID :: proc() -> (SessionID, bool) {
	sessionID: SessionID
	if !generateRandomBytes(sessionID[:]) {
		return {}, false
	}
	return sessionID, true
}

generateAuthChallenge :: proc() -> (AuthChallengeBytes, bool) {
	challenge: AuthChallengeBytes
	if !generateRandomBytes(challenge[:]) {
		return {}, false
	}
	return challenge, true
}

generateTransportNonce :: proc() -> (TransportNonce, bool) {
	nonce: TransportNonce
	if !generateRandomBytes(nonce[:]) {
		return {}, false
	}
	return nonce, true
}

generateIdentityKeyPair :: proc() -> (IdentityPrivateKeyBytes, IdentityPublicKeyBytes, bool) {
	privateKey: ed25519.Private_Key
	defer ed25519.private_key_clear(&privateKey)

	if !ed25519.private_key_generate(&privateKey) {
		return {}, {}, false
	}

	privateKeyBytes: IdentityPrivateKeyBytes
	publicKeyBytes: IdentityPublicKeyBytes
	ed25519.private_key_bytes(&privateKey, privateKeyBytes[:])
	ed25519.private_key_public_bytes(&privateKey, publicKeyBytes[:])

	return privateKeyBytes, publicKeyBytes, true
}

identityPrivateKeyFromBytes :: proc(
	privateKeyBytes: IdentityPrivateKeyBytes,
) -> (
	ed25519.Private_Key,
	bool,
) {
	privateKeyBytesCopy := privateKeyBytes
	privateKey: ed25519.Private_Key
	if !ed25519.private_key_set_bytes(&privateKey, privateKeyBytesCopy[:]) {
		return {}, false
	}
	return privateKey, true
}

identityPublicKeyFromBytes :: proc(
	publicKeyBytes: IdentityPublicKeyBytes,
) -> (
	ed25519.Public_Key,
	bool,
) {
	publicKeyBytesCopy := publicKeyBytes
	publicKey: ed25519.Public_Key
	if !ed25519.public_key_set_bytes(&publicKey, publicKeyBytesCopy[:]) {
		return {}, false
	}
	return publicKey, true
}

identityPublicKeyBytes :: proc(publicKey: ^ed25519.Public_Key) -> IdentityPublicKeyBytes {
	publicKeyBytes: IdentityPublicKeyBytes
	ed25519.public_key_bytes(publicKey, publicKeyBytes[:])
	return publicKeyBytes
}

signBytes :: proc(
	privateKeyBytes: IdentityPrivateKeyBytes,
	payload: []u8,
) -> (
	SignatureBytes,
	bool,
) {
	privateKey, ok := identityPrivateKeyFromBytes(privateKeyBytes)
	if !ok {
		return {}, false
	}
	defer ed25519.private_key_clear(&privateKey)

	signature: SignatureBytes
	ed25519.sign(&privateKey, payload, signature[:])
	return signature, true
}

verifySignature :: proc(
	publicKeyBytes: IdentityPublicKeyBytes,
	payload: []u8,
	signature: SignatureBytes,
) -> bool {
	publicKey, ok := identityPublicKeyFromBytes(publicKeyBytes)
	if !ok {
		return false
	}
	defer ed25519.public_key_clear(&publicKey)

	signatureBytesCopy := signature
	return ed25519.verify(&publicKey, payload, signatureBytesCopy[:])
}

generateKeyExchangeKeyPair :: proc() -> (ecdh.Private_Key, KeyExchangePublicKeyBytes, bool) {
	privateKey: ecdh.Private_Key
	if !ecdh.private_key_generate(&privateKey, .X25519) {
		return {}, {}, false
	}

	publicKeyBytes: KeyExchangePublicKeyBytes
	ecdh.private_key_public_bytes(&privateKey, publicKeyBytes[:])
	return privateKey, publicKeyBytes, true
}

keyExchangePublicKeyFromBytes :: proc(
	publicKeyBytes: KeyExchangePublicKeyBytes,
) -> (
	ecdh.Public_Key,
	bool,
) {
	publicKeyBytesCopy := publicKeyBytes
	publicKey: ecdh.Public_Key
	if !ecdh.public_key_set_bytes(&publicKey, .X25519, publicKeyBytesCopy[:]) {
		return {}, false
	}
	return publicKey, true
}

keyExchangePublicKeyBytes :: proc(publicKey: ^ecdh.Public_Key) -> KeyExchangePublicKeyBytes {
	publicKeyBytes: KeyExchangePublicKeyBytes
	ecdh.public_key_bytes(publicKey, publicKeyBytes[:])
	return publicKeyBytes
}

deriveSharedSecret :: proc(
	privateKey: ^ecdh.Private_Key,
	peerPublicKeyBytes: KeyExchangePublicKeyBytes,
) -> (
	SharedSecretBytes,
	bool,
) {
	peerPublicKey, ok := keyExchangePublicKeyFromBytes(peerPublicKeyBytes)
	if !ok {
		return {}, false
	}
	defer ecdh.public_key_clear(&peerPublicKey)

	sharedSecret: SharedSecretBytes
	if !ecdh.ecdh(privateKey, &peerPublicKey, sharedSecret[:]) {
		return {}, false
	}

	return sharedSecret, true
}

hashBytes :: proc(data: []u8) -> FingerprintBytes {
	digest: FingerprintBytes
	crypto_hash.hash_bytes_to_buffer(.SHA256, data, digest[:])
	return digest
}

hashCborValue :: proc(value: any) -> (FingerprintBytes, bool) {
	encoded, err := cbor.marshal(value)
	if err != nil {
		return {}, false
	}
	defer delete(encoded)

	return hashBytes(encoded), true
}

buildServerHelloProof :: proc(
	sessionID: SessionID,
	nickname: string,
	clientIdentityPublicKey: IdentityPublicKeyBytes,
	clientEphemeralPublicKey: KeyExchangePublicKeyBytes,
	serverIdentityPublicKey: IdentityPublicKeyBytes,
	serverEphemeralPublicKey: KeyExchangePublicKeyBytes,
) -> ServerHelloProof {
	return ServerHelloProof {
		version = protocolVersion,
		sessionID = sessionID,
		nickname = nickname,
		clientIdentityPublicKey = clientIdentityPublicKey,
		clientEphemeralPublicKey = clientEphemeralPublicKey,
		serverIdentityPublicKey = serverIdentityPublicKey,
		serverEphemeralPublicKey = serverEphemeralPublicKey,
	}
}

signServerHello :: proc(
	privateKeyBytes: IdentityPrivateKeyBytes,
	proof: ServerHelloProof,
) -> (
	ServerHello,
	bool,
) {
	proofHash, hashOK := hashCborValue(proof)
	if !hashOK {
		return {}, false
	}

	signature, signOK := signBytes(privateKeyBytes, proofHash[:])
	if !signOK {
		return {}, false
	}

	return ServerHello {
			version = proof.version,
			sessionID = proof.sessionID,
			serverIdentityPublicKey = proof.serverIdentityPublicKey,
			serverEphemeralPublicKey = proof.serverEphemeralPublicKey,
			signature = signature,
		},
		true
}

verifyServerHello :: proc(serverHello: ServerHello, clientHello: ClientHello) -> bool {
	proof := buildServerHelloProof(
		serverHello.sessionID,
		clientHello.nickname,
		clientHello.clientIdentityPublicKey,
		clientHello.clientEphemeralPublicKey,
		serverHello.serverIdentityPublicKey,
		serverHello.serverEphemeralPublicKey,
	)
	proof.version = serverHello.version

	proofHash, hashOK := hashCborValue(proof)
	if !hashOK {
		return false
	}

	return verifySignature(
		serverHello.serverIdentityPublicKey,
		proofHash[:],
		serverHello.signature,
	)
}

buildClientAuthProof :: proc(
	sessionID: SessionID,
	challenge: AuthChallengeBytes,
	nickname: string,
	clientIdentityPublicKey: IdentityPublicKeyBytes,
	clientEphemeralPublicKey: KeyExchangePublicKeyBytes,
	serverIdentityPublicKey: IdentityPublicKeyBytes,
	serverEphemeralPublicKey: KeyExchangePublicKeyBytes,
) -> ClientAuthProof {
	return ClientAuthProof {
		sessionID = sessionID,
		challenge = challenge,
		nickname = nickname,
		clientIdentityPublicKey = clientIdentityPublicKey,
		clientEphemeralPublicKey = clientEphemeralPublicKey,
		serverIdentityPublicKey = serverIdentityPublicKey,
		serverEphemeralPublicKey = serverEphemeralPublicKey,
	}
}

deriveHandshakeTranscriptHash :: proc(
	serverHelloProof: ServerHelloProof,
	clientAuthProof: ClientAuthProof,
) -> (
	FingerprintBytes,
	bool,
) {
	return hashCborValue(
		HandshakeTranscript {
			serverHelloProof = serverHelloProof,
			clientAuthProof = clientAuthProof,
		},
	)
}

signClientAuthRequest :: proc(
	privateKeyBytes: IdentityPrivateKeyBytes,
	proof: ClientAuthProof,
) -> (
	ClientAuthRequestPayload,
	bool,
) {
	proofHash, hashOK := hashCborValue(proof)
	if !hashOK {
		return {}, false
	}

	signature, signOK := signBytes(privateKeyBytes, proofHash[:])
	if !signOK {
		return {}, false
	}

	return ClientAuthRequestPayload{sessionID = proof.sessionID, signature = signature}, true
}

verifyClientAuthRequestSignature :: proc(
	publicKeyBytes: IdentityPublicKeyBytes,
	proof: ClientAuthProof,
	request: ClientAuthRequestPayload,
) -> bool {
	requestSessionID := request.sessionID
	proofSessionID := proof.sessionID
	if !constantTimeEqual(requestSessionID[:], proofSessionID[:]) {
		return false
	}

	proofHash, hashOK := hashCborValue(proof)
	if !hashOK {
		return false
	}

	return verifySignature(publicKeyBytes, proofHash[:], request.signature)
}

marshalCborValue :: proc(value: any) -> ([]u8, bool) {
	encoded, err := cbor.marshal(value)
	if err != nil {
		return nil, false
	}
	return encoded, true
}

fingerprintIdentityPublicKey :: proc(publicKeyBytes: IdentityPublicKeyBytes) -> FingerprintBytes {
	publicKeyBytesCopy := publicKeyBytes
	return hashBytes(publicKeyBytesCopy[:])
}

constantTimeEqual :: proc(a, b: []u8) -> bool {
	if len(a) != len(b) {
		return false
	}
	return crypto.compare_constant_time(a, b) == 1
}

encodeBytesToHex :: proc(data: []u8) -> string {
	encoded, err := encoding_hex.encode(data)
	if err != nil {
		return ""
	}
	defer delete(encoded)

	value, cloneErr := strings.clone_from_bytes(encoded)
	if cloneErr != nil {
		return ""
	}
	return value
}

decodeHexIntoBuffer :: proc(hexValue: string, dst: []u8) -> bool {
	// decode allocates its output even when the input turns out to be invalid hex.
	decoded, ok := encoding_hex.decode(transmute([]u8)hexValue)
	defer delete(decoded)
	if !ok {
		return false
	}

	if len(decoded) != len(dst) {
		return false
	}

	copy(dst, decoded)
	return true
}

identityPrivateKeyToHex :: proc(privateKeyBytes: IdentityPrivateKeyBytes) -> string {
	privateKeyBytesCopy := privateKeyBytes
	return encodeBytesToHex(privateKeyBytesCopy[:])
}

identityPublicKeyToHex :: proc(publicKeyBytes: IdentityPublicKeyBytes) -> string {
	publicKeyBytesCopy := publicKeyBytes
	return encodeBytesToHex(publicKeyBytesCopy[:])
}

fingerprintToHex :: proc(fingerprint: FingerprintBytes) -> string {
	fingerprintCopy := fingerprint
	return encodeBytesToHex(fingerprintCopy[:])
}

identityPrivateKeyFromHex :: proc(hexValue: string) -> (IdentityPrivateKeyBytes, bool) {
	privateKeyBytes: IdentityPrivateKeyBytes
	if !decodeHexIntoBuffer(hexValue, privateKeyBytes[:]) {
		return {}, false
	}
	return privateKeyBytes, true
}

identityPublicKeyFromHex :: proc(hexValue: string) -> (IdentityPublicKeyBytes, bool) {
	publicKeyBytes: IdentityPublicKeyBytes
	if !decodeHexIntoBuffer(hexValue, publicKeyBytes[:]) {
		return {}, false
	}
	return publicKeyBytes, true
}

// Expands the handshake secret into four keys, in this fixed order: control client→server,
// control server→client, voice client→server, voice server→client. Client and server must
// agree on the order byte for byte; testTransportKeyDerivationVector pins it.
deriveTransportKeySet :: proc(
	sessionID: SessionID,
	sharedSecret: SharedSecretBytes,
	transcriptHash: FingerprintBytes,
) -> TransportKeySet {
	sessionIDCopy := sessionID
	sharedSecretCopy := sharedSecret
	transcriptHashCopy := transcriptHash
	defer crypto.zero_explicit(&sharedSecretCopy, size_of(sharedSecretCopy))

	salt: [SESSION_ID_SIZE + FINGERPRINT_SIZE]u8
	copy(salt[:SESSION_ID_SIZE], sessionIDCopy[:])
	copy(salt[SESSION_ID_SIZE:], transcriptHashCopy[:])

	okm: [TRANSPORT_KEY_SIZE * TRANSPORT_KEY_COUNT]u8
	defer crypto.zero_explicit(&okm, size_of(okm))

	info := TRANSPORT_HKDF_INFO
	hkdf.extract_and_expand(
		.SHA256,
		salt[:],
		sharedSecretCopy[:],
		transmute([]u8)info,
		okm[:],
	)

	keySet: TransportKeySet
	copy(keySet.clientToServer[.Control][:], okm[0 * TRANSPORT_KEY_SIZE:1 * TRANSPORT_KEY_SIZE])
	copy(keySet.serverToClient[.Control][:], okm[1 * TRANSPORT_KEY_SIZE:2 * TRANSPORT_KEY_SIZE])
	copy(keySet.clientToServer[.Voice][:], okm[2 * TRANSPORT_KEY_SIZE:3 * TRANSPORT_KEY_SIZE])
	copy(keySet.serverToClient[.Voice][:], okm[3 * TRANSPORT_KEY_SIZE:4 * TRANSPORT_KEY_SIZE])
	return keySet
}

deriveDirectionalTransportKeys :: proc(
	role: SessionRole,
	sessionID: SessionID,
	sharedSecret: SharedSecretBytes,
	transcriptHash: FingerprintBytes,
) -> DirectionalTransportKeys {
	keySet := deriveTransportKeySet(sessionID, sharedSecret, transcriptHash)
	defer crypto.zero_explicit(&keySet, size_of(keySet))
	keys: DirectionalTransportKeys

	switch role {
	case .Client:
		keys.sendKey = keySet.clientToServer
		keys.receiveKey = keySet.serverToClient
	case .Server:
		keys.sendKey = keySet.serverToClient
		keys.receiveKey = keySet.clientToServer
	case:
	}

	return keys
}

// Wipes keys that were derived but not (or no longer) needed, such as the client's pending
// keys after activation.
DirectionalTransportKeys_wipe :: proc(keys: ^DirectionalTransportKeys) {
	crypto.zero_explicit(keys, size_of(keys^))
}

makeTransportAAD :: proc(
	sessionID: SessionID,
	channel: TransportChannel,
	sequence: u64,
) -> TransportAAD {
	sessionIDCopy := sessionID
	aad: TransportAAD
	copy(aad[:SESSION_ID_SIZE], sessionIDCopy[:])
	aad[SESSION_ID_SIZE] = u8(channel)
	endian.unchecked_put_u64le(aad[SESSION_ID_SIZE + 1:], sequence)
	return aad
}

// Voice only: the XChaCha20 24-byte nonce is channel (1) || sequence LE (8) || zeros (15).
//
// Why this nonce never repeats under a key: every voice key belongs to exactly one session
// and one direction (HKDF over a fresh X25519 secret and the session's transcript, then split
// by channel and direction), and the only sender under that key is that direction's
// ChannelSendState. Its counter starts at 0 on activation, only ever increments, and refuses
// to wrap (ChannelSendState_nextSequence), so each (key, sequence) pair is used at most once.
// A sealed state is never copied back after TransportState_takeVoiceState zeroes the source,
// so two senders cannot share a counter. The control channel uses random nonces, but under
// a different key, so it cannot collide with these. The channel byte is redundant with the
// key separation; it is there so a future channel that reuses this scheme stays distinct.
makeVoiceNonce :: proc(channel: TransportChannel, sequence: u64) -> TransportNonce {
	nonce: TransportNonce
	nonce[0] = u8(channel)
	endian.unchecked_put_u64le(nonce[1:9], sequence)
	return nonce
}

sealTransportPayload :: proc(
	key: TransportKey,
	sessionID: SessionID,
	channel: TransportChannel,
	sequence: u64,
	plaintext: []u8,
) -> (
	TransportNonce,
	TransportTag,
	[]u8,
	bool,
) {
	nonce, ok := generateTransportNonce()
	if !ok {
		return {}, {}, nil, false
	}

	keyCopy := key
	defer crypto.zero_explicit(&keyCopy, size_of(keyCopy))
	ciphertext := make([dynamic]u8, len(plaintext))
	tag: TransportTag
	aad := makeTransportAAD(sessionID, channel, sequence)
	ctx: chacha20poly1305.Context
	chacha20poly1305.init_xchacha(&ctx, keyCopy[:])
	defer chacha20poly1305.reset(&ctx)

	chacha20poly1305.seal(&ctx, ciphertext[:], tag[:], nonce[:], aad[:], plaintext)
	return nonce, tag, ciphertext[:], true
}

openTransportPayload :: proc(
	key: TransportKey,
	sessionID: SessionID,
	channel: TransportChannel,
	sequence: u64,
	nonce: TransportNonce,
	tag: TransportTag,
	ciphertext: []u8,
) -> (
	[]u8,
	bool,
) {
	keyCopy := key
	defer crypto.zero_explicit(&keyCopy, size_of(keyCopy))
	nonceCopy := nonce
	tagCopy := tag
	plaintext := make([dynamic]u8, len(ciphertext))
	aad := makeTransportAAD(sessionID, channel, sequence)
	ctx: chacha20poly1305.Context
	chacha20poly1305.init_xchacha(&ctx, keyCopy[:])
	defer chacha20poly1305.reset(&ctx)

	if !chacha20poly1305.open(&ctx, plaintext[:], nonceCopy[:], aad[:], ciphertext, tagCopy[:]) {
		delete(plaintext)
		return nil, false
	}

	return plaintext[:], true
}

// Pure check: never mutates the window, so a datagram whose tag later fails cannot move it.
ReplayWindow_check :: proc(window: ^ReplayWindow, sequence: u64) -> ReplayCheckResult {
	if !window.hasAny || sequence > window.highest {
		return .Fresh
	}

	behind := window.highest - sequence
	if behind >= REPLAY_WINDOW_SIZE {
		return .TooOld
	}
	if window.bitmap & (u64(1) << behind) != 0 {
		return .Duplicate
	}
	return .Fresh
}

// Records an accepted sequence. Call it only after the AEAD open succeeded, and only for a
// sequence ReplayWindow_check called Fresh; anything else is ignored.
ReplayWindow_commit :: proc(window: ^ReplayWindow, sequence: u64) {
	if ReplayWindow_check(window, sequence) != .Fresh {
		return
	}

	if !window.hasAny {
		window.highest = sequence
		window.bitmap = 1
		window.hasAny = true
		return
	}

	if sequence > window.highest {
		shift := sequence - window.highest
		// Shifting a u64 by 64 or more is not a useful operation; spell out the result.
		if shift >= REPLAY_WINDOW_SIZE {
			window.bitmap = 1
		} else {
			window.bitmap = (window.bitmap << shift) | 1
		}
		window.highest = sequence
		return
	}

	window.bitmap |= u64(1) << (window.highest - sequence)
}

// Hands out the next send sequence. Refuses once the counter reaches max(u64): the counter
// must never wrap, because a wrapped voice counter would reuse a deterministic nonce.
ChannelSendState_nextSequence :: proc(send: ^ChannelSendState) -> (u64, bool) {
	if !send.active || send.nextSequence == max(u64) {
		return 0, false
	}

	sequence := send.nextSequence
	send.nextSequence += 1
	return sequence, true
}

ChannelSendState_wipe :: proc(send: ^ChannelSendState) {
	crypto.zero_explicit(send, size_of(send^))
}

ControlReceiveState_wipe :: proc(receive: ^ControlReceiveState) {
	crypto.zero_explicit(receive, size_of(receive^))
}

VoiceReceiveState_wipe :: proc(receive: ^VoiceReceiveState) {
	crypto.zero_explicit(receive, size_of(receive^))
}

// Reports whether two byte slices share any memory. The AEAD needs its input and output to
// alias exactly or not at all, and the voice procedures never want them to alias.
@(private = "file")
bytesOverlap :: proc(a, b: []u8) -> bool {
	if len(a) == 0 || len(b) == 0 {
		return false
	}
	aStart := uintptr(raw_data(a))
	bStart := uintptr(raw_data(b))
	return aStart < bStart + uintptr(len(b)) && bStart < aStart + uintptr(len(a))
}

// Seals plaintext into dst as a voice datagram: kind || sequence LE || ciphertext || tag.
// Allocates nothing, so the voice thread can call it every 20 ms. dst needs
// len(plaintext) + VOICE_DATAGRAM_OVERHEAD bytes and must not overlap plaintext. Fails without
// consuming a sequence when dst is too small, and fails once the send counter is exhausted.
sealVoiceDatagram :: proc(
	send: ^ChannelSendState,
	sessionID: SessionID,
	plaintext: []u8,
	dst: []u8,
) -> (
	n: int,
	ok: bool,
) {
	if !send.active {
		return 0, false
	}
	total := VOICE_DATAGRAM_OVERHEAD + len(plaintext)
	if len(dst) < total || bytesOverlap(plaintext, dst[:total]) {
		return 0, false
	}

	sequence, sequenceOK := ChannelSendState_nextSequence(send)
	if !sequenceOK {
		return 0, false
	}

	ciphertextEnd := VOICE_DATAGRAM_HEADER_SIZE + len(plaintext)
	dst[0] = VOICE_DATAGRAM_KIND_FRAME
	endian.unchecked_put_u64le(dst[1:VOICE_DATAGRAM_HEADER_SIZE], sequence)

	nonce := makeVoiceNonce(.Voice, sequence)
	aad := makeTransportAAD(sessionID, .Voice, sequence)
	ctx: chacha20poly1305.Context
	chacha20poly1305.init_xchacha(&ctx, send.key[:])
	defer chacha20poly1305.reset(&ctx)

	chacha20poly1305.seal(
		&ctx,
		dst[VOICE_DATAGRAM_HEADER_SIZE:ciphertextEnd],
		dst[ciphertextEnd:total],
		nonce[:],
		aad[:],
		plaintext,
	)
	return total, true
}

// Opens a voice datagram into dst: check the replay window, open with the derived nonce, and
// only then commit the window, so a forged datagram cannot move it. Allocates nothing. Every
// outcome is counted in receive.stats; none of them should end the session.
openVoiceDatagram :: proc(
	receive: ^VoiceReceiveState,
	sessionID: SessionID,
	datagram: []u8,
	dst: []u8,
) -> (
	n: int,
	result: VoiceOpenResult,
) {
	n, result = voiceOpenDatagramUncounted(receive, sessionID, datagram, dst)
	switch result {
	case .Ok:
		receive.stats.accepted += 1
	case .Malformed:
		receive.stats.malformed += 1
	case .Replayed:
		receive.stats.replayed += 1
	case .TooOld:
		receive.stats.tooOld += 1
	case .BadTag:
		receive.stats.badTag += 1
	case .Inactive:
		receive.stats.inactive += 1
	}
	return n, result
}

@(private = "file")
voiceOpenDatagramUncounted :: proc(
	receive: ^VoiceReceiveState,
	sessionID: SessionID,
	datagram: []u8,
	dst: []u8,
) -> (
	int,
	VoiceOpenResult,
) {
	if !receive.active {
		return 0, .Inactive
	}
	if len(datagram) < VOICE_DATAGRAM_OVERHEAD || datagram[0] != VOICE_DATAGRAM_KIND_FRAME {
		return 0, .Malformed
	}

	ciphertextLength := len(datagram) - VOICE_DATAGRAM_OVERHEAD
	if len(dst) < ciphertextLength || bytesOverlap(datagram, dst[:ciphertextLength]) {
		return 0, .Malformed
	}

	sequence := endian.unchecked_get_u64le(datagram[1:VOICE_DATAGRAM_HEADER_SIZE])
	switch ReplayWindow_check(&receive.window, sequence) {
	case .Fresh:
	case .Duplicate:
		return 0, .Replayed
	case .TooOld:
		return 0, .TooOld
	}

	ciphertextEnd := VOICE_DATAGRAM_HEADER_SIZE + ciphertextLength
	nonce := makeVoiceNonce(.Voice, sequence)
	aad := makeTransportAAD(sessionID, .Voice, sequence)
	ctx: chacha20poly1305.Context
	chacha20poly1305.init_xchacha(&ctx, receive.key[:])
	defer chacha20poly1305.reset(&ctx)

	if !chacha20poly1305.open(
		&ctx,
		dst[:ciphertextLength],
		nonce[:],
		aad[:],
		datagram[VOICE_DATAGRAM_HEADER_SIZE:ciphertextEnd],
		datagram[ciphertextEnd:],
	) {
		return 0, .BadTag
	}

	ReplayWindow_commit(&receive.window, sequence)
	return ciphertextLength, .Ok
}

TransportState_init :: proc(role: SessionRole) -> TransportState {
	return TransportState{role = role, phase = .Disconnected, peerTrustState = .Unknown}
}

// Fills all four channel halves from the derived keys and starts every counter at zero.
TransportState_activate :: proc(
	state: ^TransportState,
	sessionID: SessionID,
	keys: DirectionalTransportKeys,
	peerTrustState: PeerTrustState,
) {
	keysCopy := keys
	defer DirectionalTransportKeys_wipe(&keysCopy)

	TransportState_wipeKeys(state)
	state.phase = .Established
	state.peerTrustState = peerTrustState
	state.sessionID = sessionID
	state.controlSend = ChannelSendState {
		key    = keysCopy.sendKey[.Control],
		active = true,
	}
	state.controlReceive = ControlReceiveState {
		key    = keysCopy.receiveKey[.Control],
		active = true,
	}
	state.voiceSend = ChannelSendState {
		key    = keysCopy.sendKey[.Voice],
		active = true,
	}
	state.voiceReceive = VoiceReceiveState {
		key    = keysCopy.receiveKey[.Voice],
		active = true,
	}
}

// Moves the voice halves out to the thread that will own them and zeroes them here, so the
// control side can never seal or open voice traffic afterwards (and two copies of one send
// counter can never both be in use).
TransportState_takeVoiceState :: proc(
	state: ^TransportState,
) -> (
	send: ChannelSendState,
	receive: VoiceReceiveState,
) {
	send = state.voiceSend
	receive = state.voiceReceive
	ChannelSendState_wipe(&state.voiceSend)
	VoiceReceiveState_wipe(&state.voiceReceive)
	return send, receive
}

@(private = "file")
TransportState_wipeKeys :: proc(state: ^TransportState) {
	ChannelSendState_wipe(&state.controlSend)
	ControlReceiveState_wipe(&state.controlReceive)
	ChannelSendState_wipe(&state.voiceSend)
	VoiceReceiveState_wipe(&state.voiceReceive)
}

// Wipes every key and counter and returns to Disconnected, keeping only the role.
TransportState_reset :: proc(state: ^TransportState) {
	role := state.role
	crypto.zero_explicit(state, size_of(state^))
	state^ = TransportState_init(role)
}

// Wipes the state before its owner goes away. The struct owns no allocations.
TransportState_deinit :: proc(state: ^TransportState) {
	crypto.zero_explicit(state, size_of(state^))
}

TransportState_canEncrypt :: proc(state: ^TransportState) -> bool {
	return state.phase == .Established
}

TransportState_nextSendSequence :: proc(state: ^TransportState) -> (u64, bool) {
	if !TransportState_canEncrypt(state) {
		return 0, false
	}
	return ChannelSendState_nextSequence(&state.controlSend)
}

// Pure check of the strict control counter; openPacketForSession commits it after the tag
// verifies.
TransportState_checkReceiveSequence :: proc(state: ^TransportState, sequence: u64) -> bool {
	if !TransportState_canEncrypt(state) || !state.controlReceive.active {
		return false
	}
	return sequence == state.controlReceive.nextSequence
}

buildPacket :: proc(messageType: MessageType, payload: any) -> (Packet, bool) {
	payloadBytes, err := cbor.marshal(payload)
	if err != nil {
		return {}, false
	}

	return Packet{messageType = messageType, payload = payloadBytes}, true
}

marshalPacket :: proc(packet: Packet) -> ([]u8, bool) {
	packetBytes, err := cbor.marshal(packet)
	if err != nil {
		return nil, false
	}
	return packetBytes, true
}

buildPacketBytes :: proc(messageType: MessageType, payload: any) -> ([]u8, bool) {
	packet, ok := buildPacket(messageType, payload)
	if !ok {
		return nil, false
	}
	defer delete(packet.payload)

	return marshalPacket(packet)
}

sealPacketForSession :: proc(
	state: ^TransportState,
	messageType: MessageType,
	payload: any,
) -> (
	Packet,
	bool,
) {
	if !TransportState_canEncrypt(state) {
		return {}, false
	}

	innerPacket, buildOK := buildPacket(messageType, payload)
	if !buildOK {
		return {}, false
	}
	defer delete(innerPacket.payload)

	innerPacketBytes, marshalOK := marshalPacket(innerPacket)
	if !marshalOK {
		return {}, false
	}
	defer delete(innerPacketBytes)

	sequence, sequenceOK := TransportState_nextSendSequence(state)
	if !sequenceOK {
		return {}, false
	}

	nonce, tag, ciphertext, sealOK := sealTransportPayload(
		state.controlSend.key,
		state.sessionID,
		.Control,
		sequence,
		innerPacketBytes,
	)
	if !sealOK {
		return {}, false
	}

	envelope := EncryptedPacket {
		sessionID  = state.sessionID,
		sequence   = sequence,
		nonce      = nonce,
		tag        = tag,
		ciphertext = ciphertext,
	}

	envelopeBytes, envelopeOK := marshalCborValue(envelope)
	if !envelopeOK {
		delete(ciphertext)
		return {}, false
	}
	delete(ciphertext)

	return Packet{messageType = .EncryptedPacket, payload = envelopeBytes}, true
}

// Opens a control-channel packet. The strict counter accepts only the next sequence.
openPacketForSession :: proc(state: ^TransportState, outerPacket: Packet) -> (Packet, bool) {
	if !TransportState_canEncrypt(state) {
		return {}, false
	}
	if outerPacket.messageType != .EncryptedPacket {
		return {}, false
	}

	envelope: EncryptedPacket
	if cbor.unmarshal(outerPacket.payload, &envelope) != nil {
		return {}, false
	}
	defer delete(envelope.ciphertext)

	if !constantTimeEqual(envelope.sessionID[:], state.sessionID[:]) {
		return {}, false
	}
	// Check first, commit only after the tag verifies, so a forged packet cannot advance the
	// counter. (A forged control packet ends the session anyway, but the order is the same
	// on every channel.)
	if !TransportState_checkReceiveSequence(state, envelope.sequence) {
		return {}, false
	}

	innerPacketBytes, ok := openTransportPayload(
		state.controlReceive.key,
		state.sessionID,
		.Control,
		envelope.sequence,
		envelope.nonce,
		envelope.tag,
		envelope.ciphertext,
	)
	if !ok {
		return {}, false
	}
	defer delete(innerPacketBytes)
	state.controlReceive.nextSequence += 1

	innerPacket: Packet
	if cbor.unmarshal(innerPacketBytes, &innerPacket) != nil {
		return {}, false
	}

	return innerPacket, true
}
