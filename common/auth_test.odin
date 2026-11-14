package common

import "core:crypto/chacha20poly1305"
import "core:crypto/ecdh"
import "core:encoding/endian"
import "core:encoding/cbor"
import "core:fmt"
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
	defer ServerAuthSuccessPayload_deinit(&payload)
	assert(payload.userId == 42, "expected decrypted payload user ID to match original value")
	assert(payload.message == "ok", "expected decrypted payload message to match original value")

	_, replayOK := openPacketForSession(&serverState, sealedPacket)
	assert(!replayOK, "expected replayed packet to be rejected by sequence checks")
}

// Fixed handshake outputs for the transport key tests: session ID 00..0f, shared secret
// 20..3f, transcript hash 40..5f.
@(private = "file")
testFixedKeyInputs :: proc() -> (SessionID, SharedSecretBytes, FingerprintBytes) {
	sessionID: SessionID
	sharedSecret: SharedSecretBytes
	transcriptHash: FingerprintBytes
	for index in 0 ..< SESSION_ID_SIZE {
		sessionID[index] = u8(index)
	}
	for index in 0 ..< SHARED_SECRET_SIZE {
		sharedSecret[index] = u8(0x20 + index)
	}
	for index in 0 ..< FINGERPRINT_SIZE {
		transcriptHash[index] = u8(0x40 + index)
	}
	return sessionID, sharedSecret, transcriptHash
}

// A client and a server transport activated from the fixed inputs, as after a handshake.
@(private = "file")
testActivatedTransportPair :: proc() -> (client: TransportState, server: TransportState) {
	sessionID, sharedSecret, transcriptHash := testFixedKeyInputs()
	clientKeys := deriveDirectionalTransportKeys(.Client, sessionID, sharedSecret, transcriptHash)
	serverKeys := deriveDirectionalTransportKeys(.Server, sessionID, sharedSecret, transcriptHash)
	client = TransportState_init(.Client)
	server = TransportState_init(.Server)
	TransportState_activate(&client, sessionID, clientKeys, .Trusted)
	TransportState_activate(&server, sessionID, serverKeys, .Trusted)
	return client, server
}

@(private = "file")
testBytesAreZero :: proc(data: []u8) -> bool {
	for value in data {
		if value != 0 {
			return false
		}
	}
	return true
}

@(private = "file")
testStructIsZero :: proc(value: ^$T) -> bool {
	return testBytesAreZero(([^]u8)(value)[:size_of(T)])
}

@(private = "file")
testKeyFromHex :: proc(hexValue: string) -> TransportKey {
	key: TransportKey
	ok := decodeHexIntoBuffer(hexValue, key[:])
	assert(ok, fmt.tprintf("expected test vector %q to be a 32-byte hex key", hexValue))
	return key
}

@(private = "file")
testKeysEqual :: proc(a, b: TransportKey) -> bool {
	aCopy, bCopy := a, b
	return constantTimeEqual(aCopy[:], bCopy[:])
}

// Seals one voice datagram from send and returns it in a fixed buffer.
@(private = "file")
testSealVoice :: proc(
	send: ^ChannelSendState,
	sessionID: SessionID,
	plaintext: []u8,
) -> (
	datagram: [128]u8,
	length: int,
) {
	n, ok := sealVoiceDatagram(send, sessionID, plaintext, datagram[:])
	assert(ok, "expected sealing a voice datagram to succeed")
	return datagram, n
}

// Opens a voice datagram with a transport's own voice receive half and session ID.
@(private = "file")
testOpenVoice :: proc(
	state: ^TransportState,
	datagram: []u8,
	dst: []u8,
) -> (
	int,
	VoiceOpenResult,
) {
	return openVoiceDatagram(&state.voiceReceive, state.sessionID, datagram, dst)
}

// Opens voice ciphertext with an explicit nonce and AAD, bypassing openVoiceDatagram, so tests
// can show which inputs the tag binds.
@(private = "file")
testOpenVoiceRaw :: proc(
	key: TransportKey,
	nonce: TransportNonce,
	aad: []u8,
	ciphertext: []u8,
	tag: []u8,
) -> bool {
	keyCopy, nonceCopy := key, nonce
	opened: [128]u8
	ctx: chacha20poly1305.Context
	chacha20poly1305.init_xchacha(&ctx, keyCopy[:])
	defer chacha20poly1305.reset(&ctx)
	return chacha20poly1305.open(&ctx, opened[:len(ciphertext)], nonceCopy[:], aad, ciphertext, tag)
}

@(test)
testTransportKeyDerivationVector :: proc(t: ^testing.T) {
	_ = t
	sessionID, sharedSecret, transcriptHash := testFixedKeyInputs()
	keySet := deriveTransportKeySet(sessionID, sharedSecret, transcriptHash)

	// HKDF-SHA256(salt = sessionID || transcriptHash, ikm = sharedSecret,
	// info = "haychat transport v2", 128 bytes), computed independently of this code.
	// If this changes, clients and servers built before and after cannot talk to each other.
	expected := [4]string {
		"b61f34905912bd0a3563f2a98da9047f6a63617595f75b3e39430a889b229715",
		"1119af6ed5b5e6d64131f7d6f21d229a22c79db63aab12ceac32e6896f02cded",
		"18cd20a8194a863c5aecd517167e0faffaab419b3c53af147adeb6dcf3cf2233",
		"f528d73c05708f63d0d7e98235beb415fba03a33f5192db7c8dbffbe4b725890",
	}
	derived := [4]TransportKey {
		keySet.clientToServer[.Control],
		keySet.serverToClient[.Control],
		keySet.clientToServer[.Voice],
		keySet.serverToClient[.Voice],
	}
	names := [4]string {
		"control client->server",
		"control server->client",
		"voice client->server",
		"voice server->client",
	}
	for index in 0 ..< 4 {
		assert(
			testKeysEqual(derived[index], testKeyFromHex(expected[index])),
			fmt.tprintf("expected the %s key to match the fixed test vector", names[index]),
		)
	}

	clientKeys := deriveDirectionalTransportKeys(.Client, sessionID, sharedSecret, transcriptHash)
	serverKeys := deriveDirectionalTransportKeys(.Server, sessionID, sharedSecret, transcriptHash)
	for channel in TransportChannel {
		assert(
			testKeysEqual(clientKeys.sendKey[channel], keySet.clientToServer[channel]),
			fmt.tprintf("expected the client to send with the %v client->server key", channel),
		)
		assert(
			testKeysEqual(clientKeys.receiveKey[channel], keySet.serverToClient[channel]),
			fmt.tprintf("expected the client to receive with the %v server->client key", channel),
		)
		assert(
			testKeysEqual(clientKeys.sendKey[channel], serverKeys.receiveKey[channel]),
			fmt.tprintf("expected client send and server receive %v keys to match", channel),
		)
		assert(
			testKeysEqual(serverKeys.sendKey[channel], clientKeys.receiveKey[channel]),
			fmt.tprintf("expected server send and client receive %v keys to match", channel),
		)
	}
}

@(test)
testTransportKeysAreDistinct :: proc(t: ^testing.T) {
	_ = t
	sessionID, sharedSecret, transcriptHash := testFixedKeyInputs()
	randomSessionID, sessionIDOK := generateSessionID()
	assert(sessionIDOK, "expected session ID generation to succeed")

	for id in ([]SessionID{sessionID, randomSessionID}) {
		keySet := deriveTransportKeySet(id, sharedSecret, transcriptHash)
		keys := [4]TransportKey {
			keySet.clientToServer[.Control],
			keySet.serverToClient[.Control],
			keySet.clientToServer[.Voice],
			keySet.serverToClient[.Voice],
		}
		for a in 0 ..< 4 {
			assert(!testBytesAreZero(keys[a][:]), fmt.tprintf("expected key %d to be non-zero", a))
			for b in a + 1 ..< 4 {
				assert(
					!testKeysEqual(keys[a], keys[b]),
					fmt.tprintf("expected derived keys %d and %d to differ", a, b),
				)
			}
		}
	}

	otherSessionKeys := deriveTransportKeySet(randomSessionID, sharedSecret, transcriptHash)
	fixedKeys := deriveTransportKeySet(sessionID, sharedSecret, transcriptHash)
	assert(
		!testKeysEqual(otherSessionKeys.clientToServer[.Voice], fixedKeys.clientToServer[.Voice]),
		"expected a different session ID to derive a different voice key",
	)
}

@(test)
testTransportNonceAndAADLayout :: proc(t: ^testing.T) {
	_ = t
	assert(u8(TransportChannel.Control) == 1, "expected the control channel to be ENet channel 1")
	assert(u8(TransportChannel.Voice) == 2, "expected the voice channel to be ENet channel 2")
	assert(TRANSPORT_NONCE_SIZE == 24, "expected a 24-byte XChaCha20 nonce")
	assert(TRANSPORT_AAD_SIZE == 25, "expected a 25-byte AAD (session, channel, sequence)")
	assert(VOICE_DATAGRAM_OVERHEAD == 25, "expected 25 bytes of voice envelope overhead")

	nonce := makeVoiceNonce(.Voice, 0x0807060504030201)
	expectedNonce := TransportNonce{0 = 2, 1 = 1, 2 = 2, 3 = 3, 4 = 4, 5 = 5, 6 = 6, 7 = 7, 8 = 8}
	assert(
		nonce == expectedNonce,
		fmt.tprintf("expected nonce channel || sequence LE || zeros, got %v", nonce),
	)
	controlNonce := makeVoiceNonce(.Control, 0x0807060504030201)
	assert(controlNonce[0] == 1, "expected the nonce to start with the channel byte")

	sessionID, _, _ := testFixedKeyInputs()
	aad := makeTransportAAD(sessionID, .Voice, 0x0807060504030201)
	for index in 0 ..< SESSION_ID_SIZE {
		assert(
			aad[index] == u8(index),
			fmt.tprintf("expected AAD byte %d to be the session ID", index),
		)
	}
	assert(aad[SESSION_ID_SIZE] == 2, "expected the AAD channel byte after the session ID")
	for index in 0 ..< 8 {
		assert(
			aad[SESSION_ID_SIZE + 1 + index] == u8(index + 1),
			fmt.tprintf("expected AAD sequence byte %d to be little-endian", index),
		)
	}

	// The voice AAD is the transport AAD with the datagram's kind byte appended (protocol 10).
	assert(VOICE_AAD_SIZE == 26, "expected a 26-byte voice AAD (session, channel, sequence, kind)")
	voiceAAD := makeVoiceAAD(sessionID, .Voice, 0x0807060504030201, VOICE_DATAGRAM_KIND_FRAME)
	assert(
		string(voiceAAD[:TRANSPORT_AAD_SIZE]) == string(aad[:]),
		"expected the voice AAD to start with the transport AAD",
	)
	assert(
		voiceAAD[TRANSPORT_AAD_SIZE] == VOICE_DATAGRAM_KIND_FRAME,
		"expected the voice AAD to end with the kind byte",
	)
	otherKind := makeVoiceAAD(sessionID, .Voice, 0x0807060504030201, 0x02)
	assert(otherKind[TRANSPORT_AAD_SIZE] == 0x02, "expected the kind byte to come from the caller")
}

@(test)
testVoiceDatagramRoundTripBothDirections :: proc(t: ^testing.T) {
	_ = t
	client, server := testActivatedTransportPair()
	plaintextText := "opus frame bytes"
	plaintext := transmute([]u8)plaintextText

	datagram, length := testSealVoice(&client.voiceSend, client.sessionID, plaintext)
	assert(
		length == len(plaintext) + VOICE_DATAGRAM_OVERHEAD,
		fmt.tprintf("expected a %d-byte datagram, got %d", len(plaintext) + 25, length),
	)
	assert(datagram[0] == VOICE_DATAGRAM_KIND_FRAME, "expected kind 0x01 first")
	assert(
		testBytesAreZero(datagram[1:9]),
		"expected the first datagram to carry sequence 0 in bytes 1..8",
	)

	opened: [128]u8
	n, result := testOpenVoice(&server, datagram[:length], opened[:])
	assert(result == .Ok, fmt.tprintf("expected the server to open the datagram, got %v", result))
	assert(string(opened[:n]) == plaintextText, "expected the opened plaintext to match")
	assert(server.voiceReceive.stats.accepted == 1, "expected one accepted datagram counted")

	// The same voice datagram must not open in the other direction: the keys differ.
	_, result = testOpenVoice(&client, datagram[:length], opened[:])
	assert(result == .BadTag, fmt.tprintf("expected a reflected datagram to fail, got %v", result))

	reply, replyLength := testSealVoice(&server.voiceSend, server.sessionID, plaintext)
	n, result = testOpenVoice(&client, reply[:replyLength], opened[:])
	assert(result == .Ok, fmt.tprintf("expected the client to open the reply, got %v", result))
	assert(string(opened[:n]) == plaintextText, "expected the reply plaintext to match")
	assert(
		client.controlSend.nextSequence == 0 && server.controlReceive.nextSequence == 0,
		"expected voice traffic to leave the control counters alone",
	)
}

@(test)
testControlPacketRoundTripBothDirections :: proc(t: ^testing.T) {
	_ = t
	client, server := testActivatedTransportPair()

	for round in 0 ..< 3 {
		toServer, sealOK := sealPacketForSession(
			&client,
			.ClientListRooms,
			ClientListRoomsPayload{},
		)
		assert(sealOK, "expected sealing a client control packet to succeed")
		defer delete(toServer.payload)
		opened, openOK := openPacketForSession(&server, toServer)
		assert(openOK, fmt.tprintf("expected the server to open control packet %d", round))
		defer delete(opened.payload)
		assert(opened.messageType == .ClientListRooms, "expected the inner message type")

		toClient, replyOK := sealPacketForSession(
			&server,
			.ServerAuthSuccess,
			ServerAuthSuccessPayload{userId = 7, message = "hi"},
		)
		assert(replyOK, "expected sealing a server control packet to succeed")
		defer delete(toClient.payload)
		reply, replyOpenOK := openPacketForSession(&client, toClient)
		assert(replyOpenOK, fmt.tprintf("expected the client to open control packet %d", round))
		defer delete(reply.payload)
		assert(reply.messageType == .ServerAuthSuccess, "expected the reply message type")
	}
	assert(
		client.controlSend.nextSequence == 3 && server.controlReceive.nextSequence == 3,
		"expected three control packets to advance both counters to 3",
	)
	assert(
		client.voiceSend.nextSequence == 0 && !server.voiceReceive.window.hasAny,
		"expected control traffic to leave the voice state alone",
	)
}

@(test)
testReplayWindowCheckAndCommit :: proc(t: ^testing.T) {
	_ = t
	window: ReplayWindow
	assert(ReplayWindow_check(&window, 5) == .Fresh, "expected an empty window to accept 5")
	assert(!window.hasAny, "expected check to leave the window untouched")

	ReplayWindow_commit(&window, 5)
	assert(window.highest == 5 && window.bitmap == 1, "expected commit to record 5")
	assert(ReplayWindow_check(&window, 5) == .Duplicate, "expected 5 to be a duplicate")
	assert(ReplayWindow_check(&window, 0) == .Fresh, "expected 0 to fit inside the window")

	ReplayWindow_commit(&window, 100)
	assert(window.highest == 100 && window.bitmap == 1, "expected a jump of 95 to reset the bitmap")
	// The window at 100 covers 37..100: 100 - 36 = 64 behind is too old.
	assert(ReplayWindow_check(&window, 36) == .TooOld, "expected 36 to be outside the window")
	assert(ReplayWindow_check(&window, 37) == .Fresh, "expected 37 to be the oldest fresh slot")
	ReplayWindow_commit(&window, 37)
	assert(ReplayWindow_check(&window, 37) == .Duplicate, "expected 37 to be recorded")
	assert(ReplayWindow_check(&window, 5) == .TooOld, "expected 5 to be outside the window")

	ReplayWindow_commit(&window, 101)
	assert(window.bitmap & 1 == 1 && window.bitmap & 2 == 2, "expected 101 and 100 recorded")
	assert(ReplayWindow_check(&window, 37) == .TooOld, "expected 37 to leave the window at 101")

	// Committing something check would refuse is ignored rather than corrupting the window.
	before := window
	ReplayWindow_commit(&window, 3)
	ReplayWindow_commit(&window, 100)
	assert(window == before, "expected commits of rejected sequences to be ignored")
}

@(test)
testVoiceReplayWindowReorderDuplicateAndAge :: proc(t: ^testing.T) {
	_ = t
	client, server := testActivatedTransportPair()
	payload := []u8{0xAA, 0xBB, 0xCC}

	datagrams: [81][128]u8
	lengths: [81]int
	for index in 0 ..< len(datagrams) {
		datagrams[index], lengths[index] = testSealVoice(
			&client.voiceSend,
			client.sessionID,
			payload,
		)
	}

	opened: [128]u8
	for index in ([]int{3, 1, 2, 0, 5, 4}) {
		_, result := openVoiceDatagram(
			&server.voiceReceive,
			server.sessionID,
			datagrams[index][:lengths[index]],
			opened[:],
		)
		assert(
			result == .Ok,
			fmt.tprintf("expected reordered sequence %d to open, got %v", index, result),
		)
	}
	for index in ([]int{3, 0, 5}) {
		_, result := openVoiceDatagram(
			&server.voiceReceive,
			server.sessionID,
			datagrams[index][:lengths[index]],
			opened[:],
		)
		assert(
			result == .Replayed,
			fmt.tprintf("expected duplicate %d to be replayed, got %v", index, result),
		)
	}

	_, result := testOpenVoice(&server, datagrams[80][:lengths[80]], opened[:])
	assert(result == .Ok, "expected sequence 80 to open")
	_, result = testOpenVoice(&server, datagrams[16][:lengths[16]], opened[:])
	assert(
		result == .TooOld,
		fmt.tprintf("expected 80 - 16 = 64 behind to be too old, got %v", result),
	)
	_, result = testOpenVoice(&server, datagrams[17][:lengths[17]], opened[:])
	assert(result == .Ok, fmt.tprintf("expected 63 behind to be accepted late, got %v", result))
	_, result = testOpenVoice(&server, datagrams[2][:lengths[2]], opened[:])
	assert(result == .TooOld, "expected an old duplicate to be too old")

	stats := server.voiceReceive.stats
	assert(
		stats.accepted == 8 && stats.replayed == 3 && stats.tooOld == 2 && stats.badTag == 0,
		fmt.tprintf("expected 8 accepted, 3 replayed, 2 too old, got %v", stats),
	)
}

@(test)
testForgedVoiceSequenceDoesNotMoveWindow :: proc(t: ^testing.T) {
	_ = t
	client, server := testActivatedTransportPair()
	payload := []u8{1, 2, 3, 4}
	first, firstLength := testSealVoice(&client.voiceSend, client.sessionID, payload)
	second, secondLength := testSealVoice(&client.voiceSend, client.sessionID, payload)

	opened: [128]u8
	_, result := testOpenVoice(&server, first[:firstLength], opened[:])
	assert(result == .Ok, "expected the first datagram to open")

	// An off-path attacker rewrites a real datagram's sequence far ahead. If the window moved
	// before the tag check, every real datagram after this one would be too old.
	forged := second
	endian.unchecked_put_u64le(forged[1:9], 1_000_000)
	_, result = testOpenVoice(&server, forged[:secondLength], opened[:])
	assert(
		result == .BadTag,
		fmt.tprintf("expected the forged datagram to fail its tag, got %v", result),
	)
	assert(
		server.voiceReceive.window.highest == 0 && server.voiceReceive.window.bitmap == 1,
		"expected the forged high sequence to leave the window at 0",
	)

	_, result = testOpenVoice(&server, second[:secondLength], opened[:])
	assert(result == .Ok, "expected the real datagram to open after the forgery")
	assert(server.voiceReceive.stats.badTag == 1, "expected one bad tag counted")
}

@(test)
testVoiceAndControlAreChannelBound :: proc(t: ^testing.T) {
	_ = t
	client, server := testActivatedTransportPair()
	plaintextText := "same bytes, same sequence"
	plaintext := transmute([]u8)plaintextText

	// Control packet with sequence 0, sealed with the raw transport procedure so the
	// ciphertext covers the same plaintext as the voice datagram below.
	controlNonce, controlTag, controlCiphertext, sealOK := sealTransportPayload(
		client.controlSend.key,
		client.sessionID,
		.Control,
		0,
		plaintext,
	)
	assert(sealOK, "expected sealing a control payload to succeed")
	defer delete(controlCiphertext)

	voice, voiceLength := testSealVoice(&client.voiceSend, client.sessionID, plaintext)
	voiceCiphertext := voice[VOICE_DATAGRAM_HEADER_SIZE:voiceLength - TRANSPORT_TAG_SIZE]
	voiceTag: TransportTag
	copy(voiceTag[:], voice[voiceLength - TRANSPORT_TAG_SIZE:voiceLength])

	// Control bytes wrapped in the voice envelope do not open on the voice channel.
	wrapped: [128]u8
	wrapped[0] = VOICE_DATAGRAM_KIND_FRAME
	copy(wrapped[VOICE_DATAGRAM_HEADER_SIZE:], controlCiphertext)
	wrappedLength := VOICE_DATAGRAM_HEADER_SIZE + len(controlCiphertext)
	copy(wrapped[wrappedLength:], controlTag[:])
	wrappedLength += TRANSPORT_TAG_SIZE
	opened: [128]u8
	_, result := testOpenVoice(&server, wrapped[:wrappedLength], opened[:])
	assert(
		result == .BadTag,
		fmt.tprintf("expected control bytes to fail on voice, got %v", result),
	)

	// The voice ciphertext does not open with the control key, nor with the control AAD.
	voiceNonce := makeVoiceNonce(.Voice, 0)
	asControl, controlOK := openTransportPayload(
		server.controlReceive.key,
		server.sessionID,
		.Control,
		0,
		voiceNonce,
		voiceTag,
		voiceCiphertext,
	)
	assert(!controlOK && asControl == nil, "expected voice bytes to fail with the control key")
	withControlAAD, controlAADOK := openTransportPayload(
		server.voiceReceive.key,
		server.sessionID,
		.Control,
		0,
		voiceNonce,
		voiceTag,
		voiceCiphertext,
	)
	assert(!controlAADOK && withControlAAD == nil, "expected the AAD channel byte to bind voice")

	// The control ciphertext does not open with the voice key or the voice AAD.
	asVoice, voiceOK := openTransportPayload(
		server.voiceReceive.key,
		server.sessionID,
		.Voice,
		0,
		controlNonce,
		controlTag,
		controlCiphertext,
	)
	assert(!voiceOK && asVoice == nil, "expected control bytes to fail with the voice key")
	withVoiceAAD, voiceAADOK := openTransportPayload(
		server.controlReceive.key,
		server.sessionID,
		.Voice,
		0,
		controlNonce,
		controlTag,
		controlCiphertext,
	)
	assert(!voiceAADOK && withVoiceAAD == nil, "expected the AAD channel byte to bind control")

	// Both still open on their own channel.
	onControl, onControlOK := openTransportPayload(
		server.controlReceive.key,
		server.sessionID,
		.Control,
		0,
		controlNonce,
		controlTag,
		controlCiphertext,
	)
	assert(onControlOK, "expected the control payload to open on the control channel")
	defer delete(onControl)
	assert(string(onControl) == plaintextText, "expected the control plaintext to match")
	n, voiceResult := testOpenVoice(&server, voice[:voiceLength], opened[:])
	assert(voiceResult == .Ok, "expected the voice datagram to open on the voice channel")
	assert(string(opened[:n]) == plaintextText, "expected the voice plaintext to match")
}

@(test)
testVoiceTamperingBreaksTag :: proc(t: ^testing.T) {
	_ = t
	client, server := testActivatedTransportPair()
	payload := []u8{9, 8, 7, 6, 5, 4, 3, 2, 1}
	datagram, length := testSealVoice(&client.voiceSend, client.sessionID, payload)
	opened: [128]u8

	ciphertext := datagram[VOICE_DATAGRAM_HEADER_SIZE:length - TRANSPORT_TAG_SIZE]
	tag: TransportTag
	copy(tag[:], datagram[length - TRANSPORT_TAG_SIZE:length])

	// Channel byte: the receiver derives the nonce and AAD with channel 2. With channel 1 in
	// the nonce (and the right AAD), or channel 1 in the AAD (and the right nonce), it fails.
	voiceAAD := makeVoiceAAD(server.sessionID, .Voice, 0, VOICE_DATAGRAM_KIND_FRAME)
	controlChannelAAD := makeVoiceAAD(server.sessionID, .Control, 0, VOICE_DATAGRAM_KIND_FRAME)
	assert(
		!testOpenVoiceRaw(
			server.voiceReceive.key,
			makeVoiceNonce(.Control, 0),
			voiceAAD[:],
			ciphertext,
			tag[:],
		),
		"expected the nonce channel byte to bind the tag",
	)
	assert(
		!testOpenVoiceRaw(
			server.voiceReceive.key,
			makeVoiceNonce(.Voice, 0),
			controlChannelAAD[:],
			ciphertext,
			tag[:],
		),
		"expected the AAD channel byte to bind the tag",
	)
	// The kind byte: the protocol 9 AAD without it, or another kind, fails.
	transportAAD := makeTransportAAD(server.sessionID, .Voice, 0)
	assert(
		!testOpenVoiceRaw(
			server.voiceReceive.key,
			makeVoiceNonce(.Voice, 0),
			transportAAD[:],
			ciphertext,
			tag[:],
		),
		"expected the AAD without the kind byte to fail the tag",
	)
	otherKindAAD := makeVoiceAAD(server.sessionID, .Voice, 0, 0x02)
	assert(
		!testOpenVoiceRaw(
			server.voiceReceive.key,
			makeVoiceNonce(.Voice, 0),
			otherKindAAD[:],
			ciphertext,
			tag[:],
		),
		"expected another kind byte in the AAD to fail the tag",
	)
	assert(
		testOpenVoiceRaw(
			server.voiceReceive.key,
			makeVoiceNonce(.Voice, 0),
			voiceAAD[:],
			ciphertext,
			tag[:],
		),
		"expected the datagram to open with the channel 2 nonce and the kind-bound voice AAD",
	)

	// The kind byte itself: an unknown kind is refused before the AEAD.
	unknownKind := datagram
	unknownKind[0] ~= 0x01
	_, unknownKindResult := testOpenVoice(&server, unknownKind[:length], opened[:])
	assert(
		unknownKindResult == .Malformed,
		fmt.tprintf("expected kind 0x00 to be malformed, got %v", unknownKindResult),
	)

	// Every other byte the receiver checks: sequence, ciphertext, tag.
	tagStart := length - TRANSPORT_TAG_SIZE
	for offset in ([]int{1, 8, VOICE_DATAGRAM_HEADER_SIZE, tagStart - 1, tagStart, length - 1}) {
		tampered := datagram
		tampered[offset] ~= 0x01
		_, result := testOpenVoice(&server, tampered[:length], opened[:])
		assert(
			result == .BadTag,
			fmt.tprintf("expected flipping byte %d to fail, got %v", offset, result),
		)
	}

	// Session ID: the receiver binds its own session ID into the AAD.
	otherSessionID := server.sessionID
	otherSessionID[SESSION_ID_SIZE - 1] ~= 0x80
	_, sessionResult := openVoiceDatagram(
		&server.voiceReceive,
		otherSessionID,
		datagram[:length],
		opened[:],
	)
	assert(sessionResult == .BadTag, "expected a different session ID byte to fail the tag")

	assert(!server.voiceReceive.window.hasAny, "expected no tampered datagram to move the window")
	n, result := testOpenVoice(&server, datagram[:length], opened[:])
	assert(result == .Ok, "expected the untouched datagram to open after the tampering")
	assert(n == len(payload), "expected the plaintext length to match")
}

// Only kind 0x01 is accepted today, so the relabelling attack needs a second kind: seal a
// datagram as kind 0x02 with the package-private sealer, then relabel it 0x01. It passes the
// kind check and must fail on the tag, which proves the kind byte is authenticated.
@(test)
testVoiceKindByteIsBoundIntoTheTag :: proc(t: ^testing.T) {
	_ = t
	client, server := testActivatedTransportPair()
	payload := []u8{0x08, 1, 2, 3}
	datagram: [128]u8
	n, ok := sealVoiceDatagramOfKind(
		&client.voiceSend,
		client.sessionID,
		0x02,
		payload,
		datagram[:],
	)
	assert(ok && datagram[0] == 0x02, "expected the test sealer to write kind 0x02")
	opened: [128]u8

	_, result := testOpenVoice(&server, datagram[:n], opened[:])
	assert(result == .Malformed, fmt.tprintf("expected kind 0x02 to be refused, got %v", result))

	relabelled := datagram
	relabelled[0] = VOICE_DATAGRAM_KIND_FRAME
	_, result = testOpenVoice(&server, relabelled[:n], opened[:])
	assert(
		result == .BadTag,
		fmt.tprintf("expected a datagram relabelled 0x02 -> 0x01 to fail its tag, got %v", result),
	)
	assert(!server.voiceReceive.window.hasAny, "expected the relabelled datagram to move nothing")

	// The control: the same sealer with kind 0x01 is exactly sealVoiceDatagram, and opens.
	n, ok = sealVoiceDatagramOfKind(
		&client.voiceSend,
		client.sessionID,
		VOICE_DATAGRAM_KIND_FRAME,
		payload,
		datagram[:],
	)
	assert(ok, "expected sealing kind 0x01 to succeed")
	length: int
	length, result = testOpenVoice(&server, datagram[:n], opened[:])
	assert(result == .Ok, fmt.tprintf("expected kind 0x01 to open, got %v", result))
	assert(string(opened[:length]) == string(payload), "expected the payload to match")
}

@(test)
testControlChannelBindsTheChannelByte :: proc(t: ^testing.T) {
	_ = t
	client, server := testActivatedTransportPair()
	plaintext := []u8{1, 2, 3}
	nonce, tag, ciphertext, ok := sealTransportPayload(
		client.controlSend.key,
		client.sessionID,
		.Control,
		4,
		plaintext,
	)
	assert(ok, "expected sealing a control payload to succeed")
	defer delete(ciphertext)

	wrongChannel, wrongChannelOK := openTransportPayload(
		server.controlReceive.key,
		server.sessionID,
		.Voice,
		4,
		nonce,
		tag,
		ciphertext,
	)
	assert(!wrongChannelOK && wrongChannel == nil, "expected the channel byte to bind control")
	wrongSequence, wrongSequenceOK := openTransportPayload(
		server.controlReceive.key,
		server.sessionID,
		.Control,
		5,
		nonce,
		tag,
		ciphertext,
	)
	assert(!wrongSequenceOK && wrongSequence == nil, "expected the sequence to bind control")
}

@(test)
testSendCountersRefuseToWrap :: proc(t: ^testing.T) {
	_ = t
	client, server := testActivatedTransportPair()
	payload := []u8{0x42}
	buffer: [64]u8

	client.voiceSend.nextSequence = max(u64) - 1
	n, ok := sealVoiceDatagram(&client.voiceSend, client.sessionID, payload, buffer[:])
	assert(ok, "expected the last usable voice sequence to seal")
	sequence := endian.unchecked_get_u64le(buffer[1:9])
	assert(sequence == max(u64) - 1, fmt.tprintf("expected sequence max-1, got %d", sequence))
	opened: [64]u8
	_, result := testOpenVoice(&server, buffer[:n], opened[:])
	assert(result == .Ok, "expected the last voice sequence to open")

	_, ok = sealVoiceDatagram(&client.voiceSend, client.sessionID, payload, buffer[:])
	assert(!ok, "expected the voice send counter to refuse to wrap")
	_, ok = sealVoiceDatagram(&client.voiceSend, client.sessionID, payload, buffer[:])
	assert(!ok, "expected the voice send counter to stay exhausted")
	assert(client.voiceSend.nextSequence == max(u64), "expected the counter to stay at max")

	client.controlSend.nextSequence = max(u64)
	_, controlOK := sealPacketForSession(&client, .ClientListRooms, ClientListRoomsPayload{})
	assert(!controlOK, "expected the control send counter to refuse to wrap")
	assert(client.controlSend.nextSequence == max(u64), "expected the control counter at max")
}

@(test)
testTakeVoiceStateZeroesTheSource :: proc(t: ^testing.T) {
	_ = t
	client, server := testActivatedTransportPair()
	expectedSendKey := client.voiceSend.key
	expectedReceiveKey := client.voiceReceive.key

	send, receive := TransportState_takeVoiceState(&client)
	assert(send.active && receive.active, "expected the taken voice halves to be active")
	assert(testKeysEqual(send.key, expectedSendKey), "expected the taken send key")
	assert(testKeysEqual(receive.key, expectedReceiveKey), "expected the taken receive key")
	assert(testStructIsZero(&client.voiceSend), "expected the source voice send half zeroed")
	assert(testStructIsZero(&client.voiceReceive), "expected the source voice receive half zeroed")
	assert(client.controlSend.active, "expected the control halves to stay in place")

	payload := []u8{1, 2}
	buffer: [64]u8
	_, staleOK := sealVoiceDatagram(&client.voiceSend, client.sessionID, payload, buffer[:])
	assert(!staleOK, "expected the zeroed source to refuse to seal with an all-zero key")

	n, ok := sealVoiceDatagram(&send, client.sessionID, payload, buffer[:])
	assert(ok, "expected the taken send half to seal")
	opened: [64]u8
	_, result := testOpenVoice(&server, buffer[:n], opened[:])
	assert(result == .Ok, "expected the server to open what the taken half sealed")

	reply, replyOK := sealVoiceDatagram(&server.voiceSend, server.sessionID, payload, buffer[:])
	assert(replyOK, "expected the server to seal a reply")
	_, stale := testOpenVoice(&client, buffer[:reply], opened[:])
	assert(
		stale == .Inactive,
		fmt.tprintf("expected the zeroed half to be inactive, got %v", stale),
	)
	assert(client.voiceReceive.stats.inactive == 1, "expected the inactive drop counted")
	_, result = openVoiceDatagram(&receive, client.sessionID, buffer[:reply], opened[:])
	assert(result == .Ok, "expected the taken receive half to open the reply")

	ChannelSendState_wipe(&send)
	VoiceReceiveState_wipe(&receive)
	assert(testStructIsZero(&send) && testStructIsZero(&receive), "expected wipes to zero")
}

@(test)
testVoiceDatagramMalformed :: proc(t: ^testing.T) {
	_ = t
	client, server := testActivatedTransportPair()
	payload := []u8{1, 2, 3, 4, 5, 6, 7, 8}
	datagram, length := testSealVoice(&client.voiceSend, client.sessionID, payload)
	opened: [128]u8

	for truncated in ([]int{0, 1, VOICE_DATAGRAM_HEADER_SIZE, VOICE_DATAGRAM_OVERHEAD - 1}) {
		_, result := testOpenVoice(&server, datagram[:truncated], opened[:])
		assert(
			result == .Malformed,
			fmt.tprintf("expected a %d-byte datagram to be malformed, got %v", truncated, result),
		)
	}

	for kind in ([]u8{0x00, 0x02, 0xFF}) {
		unknown := datagram
		unknown[0] = kind
		_, result := testOpenVoice(&server, unknown[:length], opened[:])
		assert(
			result == .Malformed,
			fmt.tprintf("expected kind %d to be malformed, got %v", kind, result),
		)
	}

	_, smallResult := openVoiceDatagram(
		&server.voiceReceive,
		server.sessionID,
		datagram[:length],
		opened[:len(payload) - 1],
	)
	assert(smallResult == .Malformed, "expected a too-small destination to be malformed")

	// The datagram must not overlap the destination.
	inPlace := datagram
	_, overlapResult := testOpenVoice(&server, inPlace[:length], inPlace[:])
	assert(overlapResult == .Malformed, "expected an overlapping destination to be refused")

	stats := server.voiceReceive.stats
	assert(stats.malformed == 9, fmt.tprintf("expected 9 malformed drops, got %d", stats.malformed))
	assert(
		!server.voiceReceive.window.hasAny,
		"expected malformed datagrams not to move the window",
	)
	_, result := testOpenVoice(&server, datagram[:length], opened[:])
	assert(result == .Ok, "expected the intact datagram to open after the malformed ones")

	// A destination that is too small for sealing fails without consuming a sequence.
	small: [VOICE_DATAGRAM_OVERHEAD + 7]u8
	_, sealOK := sealVoiceDatagram(&client.voiceSend, client.sessionID, payload, small[:])
	assert(!sealOK, "expected sealing into a too-small buffer to fail")
	assert(client.voiceSend.nextSequence == 1, "expected the failed seal to keep the sequence")
	exact: [VOICE_DATAGRAM_OVERHEAD + 8]u8
	n, exactOK := sealVoiceDatagram(&client.voiceSend, client.sessionID, payload, exact[:])
	assert(exactOK && n == len(exact), "expected sealing into an exact-size buffer to succeed")
}

@(test)
testControlOpenChecksBeforeCommitting :: proc(t: ^testing.T) {
	_ = t
	client, server := testActivatedTransportPair()
	sealed, sealOK := sealPacketForSession(&client, .ClientListRooms, ClientListRoomsPayload{})
	assert(sealOK, "expected sealing a control packet to succeed")
	defer delete(sealed.payload)

	envelope: EncryptedPacket
	assert(cbor.unmarshal(sealed.payload, &envelope) == nil, "expected the envelope to decode")
	defer delete(envelope.ciphertext)
	envelope.tag[0] ~= 0x01
	forgedPayload, marshalOK := marshalCborValue(envelope)
	assert(marshalOK, "expected the forged envelope to encode")
	defer delete(forgedPayload)

	_, forgedOK := openPacketForSession(
		&server,
		Packet{messageType = .EncryptedPacket, payload = forgedPayload},
	)
	assert(!forgedOK, "expected a bad tag to be rejected")
	assert(
		server.controlReceive.nextSequence == 0,
		fmt.tprintf(
			"expected a bad tag to leave the control counter at 0, got %d",
			server.controlReceive.nextSequence,
		),
	)

	opened, openOK := openPacketForSession(&server, sealed)
	assert(openOK, "expected the real packet to open after the forgery")
	defer delete(opened.payload)
	assert(server.controlReceive.nextSequence == 1, "expected the real packet to advance to 1")
}

@(test)
testTransportResetWipesEveryChannel :: proc(t: ^testing.T) {
	_ = t
	client, _ := testActivatedTransportPair()
	client.voiceReceive.stats.accepted = 3

	TransportState_reset(&client)
	assert(client.role == .Client, "expected reset to keep the role")
	assert(client.phase == .Disconnected, "expected reset to return to Disconnected")
	assert(testStructIsZero(&client.controlSend), "expected the control send half wiped")
	assert(testStructIsZero(&client.controlReceive), "expected the control receive half wiped")
	assert(testStructIsZero(&client.voiceSend), "expected the voice send half wiped")
	assert(testStructIsZero(&client.voiceReceive), "expected the voice receive half wiped")
	assert(testBytesAreZero(client.sessionID[:]), "expected the session ID cleared")

	_, sealOK := sealPacketForSession(&client, .ClientListRooms, ClientListRoomsPayload{})
	assert(!sealOK, "expected a reset transport to refuse to seal")

	server: TransportState
	_, server = testActivatedTransportPair()
	TransportState_deinit(&server)
	assert(testStructIsZero(&server), "expected deinit to wipe the whole state")
}
