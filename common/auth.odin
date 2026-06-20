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
TRANSPORT_AAD_SIZE :: SESSION_ID_SIZE + 8
FINGERPRINT_SIZE :: 32

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

TransportKeySet :: struct {
	clientToServer: TransportKey,
	serverToClient: TransportKey,
}

DirectionalTransportKeys :: struct {
	sendKey:    TransportKey,
	receiveKey: TransportKey,
}

TransportState :: struct {
	role:                SessionRole,
	phase:               HandshakePhase,
	peerTrustState:      PeerTrustState,
	sessionID:           SessionID,
	sendKey:             TransportKey,
	receiveKey:          TransportKey,
	nextSendSequence:    u64,
	nextReceiveSequence: u64,
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
	clientIdentityPublicKey: IdentityPublicKeyBytes,
	clientEphemeralPublicKey: KeyExchangePublicKeyBytes,
	serverIdentityPublicKey: IdentityPublicKeyBytes,
	serverEphemeralPublicKey: KeyExchangePublicKeyBytes,
) -> ServerHelloProof {
	return ServerHelloProof {
		version = protocolVersion,
		sessionID = sessionID,
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
	clientIdentityPublicKey: IdentityPublicKeyBytes,
	clientEphemeralPublicKey: KeyExchangePublicKeyBytes,
	serverIdentityPublicKey: IdentityPublicKeyBytes,
	serverEphemeralPublicKey: KeyExchangePublicKeyBytes,
) -> ClientAuthProof {
	return ClientAuthProof {
		sessionID = sessionID,
		challenge = challenge,
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
	decoded, ok := encoding_hex.decode(transmute([]u8)hexValue)
	if !ok {
		return false
	}
	defer delete(decoded)

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

deriveTransportKeySet :: proc(
	sessionID: SessionID,
	sharedSecret: SharedSecretBytes,
	transcriptHash: FingerprintBytes,
) -> TransportKeySet {
	sessionIDCopy := sessionID
	sharedSecretCopy := sharedSecret
	transcriptHashCopy := transcriptHash

	salt: [SESSION_ID_SIZE + FINGERPRINT_SIZE]u8
	copy(salt[:SESSION_ID_SIZE], sessionIDCopy[:])
	copy(salt[SESSION_ID_SIZE:], transcriptHashCopy[:])

	okm: [TRANSPORT_KEY_SIZE * 2]u8
	defer crypto.zero_explicit(&okm, size_of(okm))

	hkdf.extract_and_expand(.SHA256, salt[:], sharedSecretCopy[:], nil, okm[:])

	keySet: TransportKeySet
	copy(keySet.clientToServer[:], okm[:TRANSPORT_KEY_SIZE])
	copy(keySet.serverToClient[:], okm[TRANSPORT_KEY_SIZE:])
	return keySet
}

deriveDirectionalTransportKeys :: proc(
	role: SessionRole,
	sessionID: SessionID,
	sharedSecret: SharedSecretBytes,
	transcriptHash: FingerprintBytes,
) -> DirectionalTransportKeys {
	keySet := deriveTransportKeySet(sessionID, sharedSecret, transcriptHash)
	keys: DirectionalTransportKeys

	switch role {
	case .Client:
		copy(keys.sendKey[:], keySet.clientToServer[:])
		copy(keys.receiveKey[:], keySet.serverToClient[:])
	case .Server:
		copy(keys.sendKey[:], keySet.serverToClient[:])
		copy(keys.receiveKey[:], keySet.clientToServer[:])
	case:
	}

	return keys
}

makeTransportAAD :: proc(sessionID: SessionID, sequence: u64) -> TransportAAD {
	sessionIDCopy := sessionID
	aad: TransportAAD
	copy(aad[:SESSION_ID_SIZE], sessionIDCopy[:])
	endian.unchecked_put_u64le(aad[SESSION_ID_SIZE:], sequence)
	return aad
}

sealTransportPayload :: proc(
	key: TransportKey,
	sessionID: SessionID,
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
	ciphertext := make([dynamic]u8, len(plaintext))
	tag: TransportTag
	aad := makeTransportAAD(sessionID, sequence)
	ctx: chacha20poly1305.Context
	chacha20poly1305.init_xchacha(&ctx, keyCopy[:])
	defer chacha20poly1305.reset(&ctx)

	chacha20poly1305.seal(&ctx, ciphertext[:], tag[:], nonce[:], aad[:], plaintext)
	return nonce, tag, ciphertext[:], true
}

openTransportPayload :: proc(
	key: TransportKey,
	sessionID: SessionID,
	sequence: u64,
	nonce: TransportNonce,
	tag: TransportTag,
	ciphertext: []u8,
) -> (
	[]u8,
	bool,
) {
	keyCopy := key
	nonceCopy := nonce
	tagCopy := tag
	plaintext := make([dynamic]u8, len(ciphertext))
	aad := makeTransportAAD(sessionID, sequence)
	ctx: chacha20poly1305.Context
	chacha20poly1305.init_xchacha(&ctx, keyCopy[:])
	defer chacha20poly1305.reset(&ctx)

	if !chacha20poly1305.open(&ctx, plaintext[:], nonceCopy[:], aad[:], ciphertext, tagCopy[:]) {
		delete(plaintext)
		return nil, false
	}

	return plaintext[:], true
}

TransportState_init :: proc(role: SessionRole) -> TransportState {
	return TransportState{role = role, phase = .Disconnected, peerTrustState = .Unknown}
}

TransportState_activate :: proc(
	state: ^TransportState,
	sessionID: SessionID,
	keys: DirectionalTransportKeys,
	peerTrustState: PeerTrustState,
) {
	keysCopy := keys
	state.phase = .Established
	state.peerTrustState = peerTrustState
	state.sessionID = sessionID
	copy(state.sendKey[:], keysCopy.sendKey[:])
	copy(state.receiveKey[:], keysCopy.receiveKey[:])
	state.nextSendSequence = 0
	state.nextReceiveSequence = 0
}

TransportState_reset :: proc(state: ^TransportState) {
	role := state.role
	state^ = TransportState_init(role)
}

TransportState_canEncrypt :: proc(state: ^TransportState) -> bool {
	return state.phase == .Established
}

TransportState_nextSendSequence :: proc(state: ^TransportState) -> (u64, bool) {
	if !TransportState_canEncrypt(state) {
		return 0, false
	}

	sequence := state.nextSendSequence
	state.nextSendSequence += 1
	return sequence, true
}

TransportState_acceptReceiveSequence :: proc(state: ^TransportState, sequence: u64) -> bool {
	if !TransportState_canEncrypt(state) {
		return false
	}
	if sequence != state.nextReceiveSequence {
		return false
	}

	state.nextReceiveSequence += 1
	return true
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
		state.sendKey,
		state.sessionID,
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
	if !TransportState_acceptReceiveSequence(state, envelope.sequence) {
		return {}, false
	}

	innerPacketBytes, ok := openTransportPayload(
		state.receiveKey,
		state.sessionID,
		envelope.sequence,
		envelope.nonce,
		envelope.tag,
		envelope.ciphertext,
	)
	if !ok {
		return {}, false
	}
	defer delete(innerPacketBytes)

	innerPacket: Packet
	if cbor.unmarshal(innerPacketBytes, &innerPacket) != nil {
		return {}, false
	}

	return innerPacket, true
}
