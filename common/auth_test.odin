package common

import "core:crypto/ecdh"
import "core:encoding/cbor"
import "core:testing"

@(test)
testIdentityKeyEncodingAndSignatures :: proc(t: ^testing.T) {
	_ = t

	privateKeyBytes, publicKeyBytes, ok := generateIdentityKeyPair()
	assert(ok, "expected identity key generation to succeed")

	privateKeyHex := identityPrivateKeyToHex(privateKeyBytes)
	publicKeyHex := identityPublicKeyToHex(publicKeyBytes)
	defer delete(privateKeyHex)
	defer delete(publicKeyHex)

	decodedPrivateKeyBytes, privateKeyDecodeOK := identityPrivateKeyFromHex(privateKeyHex)
	decodedPublicKeyBytes, publicKeyDecodeOK := identityPublicKeyFromHex(publicKeyHex)
	assert(privateKeyDecodeOK, "expected private key hex decode to succeed")
	assert(publicKeyDecodeOK, "expected public key hex decode to succeed")
	assert(
		constantTimeEqual(privateKeyBytes[:], decodedPrivateKeyBytes[:]),
		"expected decoded private key bytes to match original bytes",
	)
	assert(
		constantTimeEqual(publicKeyBytes[:], decodedPublicKeyBytes[:]),
		"expected decoded public key bytes to match original bytes",
	)

	payloadText := "haychat-auth-test"
	payload := transmute([]u8)(payloadText)
	signature, signOK := signBytes(privateKeyBytes, payload)
	assert(signOK, "expected signing to succeed")
	assert(
		verifySignature(publicKeyBytes, payload, signature),
		"expected signature verification to succeed",
	)
}

@(test)
testClientAuthProofBindsNickname :: proc(t: ^testing.T) {
	_ = t

	privateKey, publicKey, identityOK := generateIdentityKeyPair()
	assert(identityOK, "expected client identity key generation to succeed")
	sessionID, sessionIDOK := generateSessionID()
	assert(sessionIDOK, "expected session ID generation to succeed")
	challenge, challengeOK := generateAuthChallenge()
	assert(challengeOK, "expected auth challenge generation to succeed")
	_, ephemeralPublicKey, ephemeralOK := generateKeyExchangeKeyPair()
	assert(ephemeralOK, "expected client ephemeral key generation to succeed")
	_, serverEphemeralPublicKey, serverEphemeralOK := generateKeyExchangeKeyPair()
	assert(serverEphemeralOK, "expected server ephemeral key generation to succeed")

	proof := buildClientAuthProof(
		sessionID,
		challenge,
		"hayseed",
		publicKey,
		ephemeralPublicKey,
		{},
		serverEphemeralPublicKey,
	)
	request, requestOK := signClientAuthRequest(privateKey, proof)
	assert(requestOK, "expected client auth request signing to succeed")
	assert(
		verifyClientAuthRequestSignature(publicKey, proof, request),
		"expected original nickname proof to verify",
	)

	tamperedProof := proof
	tamperedProof.nickname = "other-user"
	assert(
		!verifyClientAuthRequestSignature(publicKey, tamperedProof, request),
		"expected changed nickname to invalidate client auth signature",
	)
}

@(test)
testSharedSecretDerivationMatches :: proc(t: ^testing.T) {
	_ = t

	clientPrivateKey, clientPublicKey, clientOK := generateKeyExchangeKeyPair()
	assert(clientOK, "expected client key exchange generation to succeed")
	defer ecdh.private_key_clear(&clientPrivateKey)

	serverPrivateKey, serverPublicKey, serverOK := generateKeyExchangeKeyPair()
	assert(serverOK, "expected server key exchange generation to succeed")
	defer ecdh.private_key_clear(&serverPrivateKey)

	clientSharedSecret, clientSharedSecretOK := deriveSharedSecret(
		&clientPrivateKey,
		serverPublicKey,
	)
	serverSharedSecret, serverSharedSecretOK := deriveSharedSecret(
		&serverPrivateKey,
		clientPublicKey,
	)
	assert(clientSharedSecretOK, "expected client shared secret derivation to succeed")
	assert(serverSharedSecretOK, "expected server shared secret derivation to succeed")
	assert(
		constantTimeEqual(clientSharedSecret[:], serverSharedSecret[:]),
		"expected both peers to derive the same shared secret",
	)
}

@(test)
testEncryptedPacketRoundTripAndReplayProtection :: proc(t: ^testing.T) {
	_ = t

	clientPrivateKey, clientPublicKey, clientOK := generateKeyExchangeKeyPair()
	assert(clientOK, "expected client key exchange generation to succeed")
	defer ecdh.private_key_clear(&clientPrivateKey)

	serverPrivateKey, serverPublicKey, serverOK := generateKeyExchangeKeyPair()
	assert(serverOK, "expected server key exchange generation to succeed")
	defer ecdh.private_key_clear(&serverPrivateKey)

	clientSharedSecret, clientSharedSecretOK := deriveSharedSecret(
		&clientPrivateKey,
		serverPublicKey,
	)
	serverSharedSecret, serverSharedSecretOK := deriveSharedSecret(
		&serverPrivateKey,
		clientPublicKey,
	)
	assert(clientSharedSecretOK, "expected client shared secret derivation to succeed")
	assert(serverSharedSecretOK, "expected server shared secret derivation to succeed")

	sessionID, sessionIDOK := generateSessionID()
	assert(sessionIDOK, "expected session ID generation to succeed")

	transcriptText := "transport-transcript"
	transcriptHash := hashBytes(transmute([]u8)(transcriptText))
	clientKeys := deriveDirectionalTransportKeys(
		.Client,
		sessionID,
		clientSharedSecret,
		transcriptHash,
	)
	serverKeys := deriveDirectionalTransportKeys(
		.Server,
		sessionID,
		serverSharedSecret,
		transcriptHash,
	)

	clientState := TransportState_init(.Client)
	serverState := TransportState_init(.Server)
	TransportState_activate(&clientState, sessionID, clientKeys, .Trusted)
	TransportState_activate(&serverState, sessionID, serverKeys, .Trusted)

	sealedPacket, sealOK := sealPacketForSession(
		&clientState,
		.ServerAuthSuccess,
		ServerAuthSuccessPayload{userId = 42, message = "ok"},
	)
	assert(sealOK, "expected packet sealing to succeed")
	defer delete(sealedPacket.payload)
	assert(
		sealedPacket.messageType == .EncryptedPacket,
		"expected outer packet to use encrypted packet message type",
	)

	openedPacket, openOK := openPacketForSession(&serverState, sealedPacket)
	assert(openOK, "expected packet opening to succeed")
	defer delete(openedPacket.payload)
	assert(
		openedPacket.messageType == .ServerAuthSuccess,
		"expected inner packet message type to match original type",
	)

	payload: ServerAuthSuccessPayload
	payloadErr := cbor.unmarshal(openedPacket.payload, &payload)
	assert(payloadErr == nil, "expected decrypted payload CBOR decode to succeed")
	defer delete(payload.message)
	assert(payload.userId == 42, "expected decrypted payload user ID to match original value")
	assert(payload.message == "ok", "expected decrypted payload message to match original value")

	_, replayOK := openPacketForSession(&serverState, sealedPacket)
	assert(!replayOK, "expected replayed packet to be rejected by sequence checks")
}
