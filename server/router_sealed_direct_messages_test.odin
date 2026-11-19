package server

import "../common"
import "core:encoding/cbor"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:testing"

// Router tests for encrypted direct messages and the signed plaintext fallback (protocol 17,
// e2ee-design.md 4.5, 4.6). The envelope's signature is checked by the database worker
// (databaseCheckSealedDirectMessage, tested in database_encrypted_direct_messages_test.odin);
// the router checks shape and structure and fans out what was stored.

// A valid DirectMessage envelope from alice (the key given) to an invented recipient key. The
// caller frees it.
@(private = "file")
routerTestEnvelope :: proc(
	h: ^RouterTestHarness,
	senderKey: common.IdentityPrivateKeyBytes,
	senderID, recipientID: int,
	clientMessageID: common.ClientMessageID,
	content: string,
) -> []u8 {
	senderPublic, publicOK := common.identityPublicKeyFromPrivateKey(senderKey)
	assert(publicOK, "expected the sender's public key")
	_, recipientIdentity, recipientOK := common.generateIdentityKeyPair()
	assert(recipientOK, "expected a recipient identity key")
	senderEncryption, _ := common.generateEncryptionKeyPair()
	recipientEncryption, _ := common.generateEncryptionKeyPair()
	buffer: [common.SEALED_ENVELOPE_MAX_BYTES]u8
	n, err := common.sealDirectMessage(
		common.DirectMessageAADFields {
			serverIdentityPublicKey = h.state.serverIdentityPublicKey,
			senderUserID = senderID,
			recipientUserID = recipientID,
			senderIdentityPublicKey = senderPublic,
			recipientIdentityPublicKey = recipientIdentity,
			clientMessageID = clientMessageID,
		},
		content,
		senderEncryption.publicKey,
		recipientEncryption.publicKey,
		senderKey,
		buffer[:],
	)
	assert(err == .None, fmt.tprintf("expected sealing to succeed, got %v", err))
	envelope := make([]u8, n)
	copy(envelope, buffer[:n])
	return envelope
}

@(private = "file")
routerTestMessageID :: proc(fill: u8) -> common.ClientMessageID {
	id: common.ClientMessageID
	for index in 0 ..< len(id) {
		id[index] = fill + u8(index)
	}
	return id
}

@(test)
testMainRouterSealedDirectMessageReachesBothUsersByteForByte :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)

	senderPeerID := u32(1)
	recipientPeerID := u32(2)
	bystanderPeerID := u32(3)
	h.state.connectedPeers[recipientPeerID] = true
	h.state.connectedPeers[bystanderPeerID] = true
	senderKey: common.IdentityPrivateKeyBytes
	senderTransport := routerCompleteHandshake(
		&h,
		senderPeerID,
		42,
		identityPrivateKeyOut = &senderKey,
	)
	peers := [?]RouterTestPeer{{senderPeerID, &senderTransport}, {recipientPeerID, nil}, {
			bystanderPeerID,
			nil,
		}}
	recipientTransport := routerCompleteHandshake(&h, recipientPeerID, 43)
	peers[1].transport = &recipientTransport
	routerTestSkipPresence(&h, peers[:])
	bystanderTransport := routerCompleteHandshake(&h, bystanderPeerID, 44)
	peers[2].transport = &bystanderTransport
	routerTestSkipPresence(&h, peers[:])
	routerTestSkipPresence(&h, peers[:])
	routerTestExpectNoNetworkMessage(&h, "expected only the presence notices so far")

	clientMessageID := routerTestMessageID(7)
	envelope := routerTestEnvelope(&h, senderKey, 42, 43, clientMessageID, "sealed")
	defer delete(envelope)
	routerTestSendSealed(
		&h,
		&senderTransport,
		senderPeerID,
		.ClientSealedDirectMessage,
		common.ClientSealedDirectMessagePayload {
			recipientUserId = 43,
			clientMessageId = clientMessageID,
			envelope = envelope,
		},
	)
	postQuery := routerPollDatabaseQuery(&h)
	defer IPC__database_query_request_deinit(postQuery.request)
	request, requestOK := postQuery.request.(common.DatabasePostDirectMessageRequest)
	senderSession, _ := MainRouterState_getPeerSession(&h.state, senderPeerID)
	assert(
		requestOK &&
		request.senderId == 42 &&
		request.recipientId == 43 &&
		request.content == "" &&
		string(request.envelope) == string(envelope) &&
		request.clientMessageId == clientMessageID &&
		request.serverIdentityPublicKey == h.state.serverIdentityPublicKey &&
		request.senderIdentityPublicKey == senderSession.clientIdentityPublicKey,
		fmt.tprintf("expected the envelope with the keys to check it, got %v", request),
	)

	storedEnvelope := make([]u8, len(envelope))
	copy(storedEnvelope, envelope)
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		postQuery.request_id,
		common.DatabaseQueryResponse {
			success = true,
			result = common.DatabasePostDirectMessageResult {
				outcome = .Stored,
				storedMessage = {
					id = 90,
					senderId = 42,
					senderNickname = strings.clone("alice"),
					recipientId = 43,
					recipientNickname = strings.clone("bob"),
					timestamp = strings.clone("2026-11-14 10:00:00+00"),
					content = strings.clone(""),
					clientMessageId = clientMessageID,
					envelope = storedEnvelope,
				},
			},
		},
	)
	seen := map[u32]bool{}
	defer delete(seen)
	for _ in 0 ..< 2 {
		peerID, packet := routerTestReceive(&h, peers[:])
		defer delete(packet.payload)
		assert(
			packet.messageType == .ServerSealedDirectMessage,
			fmt.tprintf("expected ServerSealedDirectMessage, got %v", packet.messageType),
		)
		assert(peerID != bystanderPeerID, "expected nothing for other accounts")
		payload: common.ServerSealedDirectMessagePayload
		assert(
			cbor.unmarshal(packet.payload, &payload, temp_allocator = context.allocator) == nil,
			"expected the sealed message to decode",
		)
		defer common.ServerSealedDirectMessagePayload_deinit(&payload)
		assert(
			payload.id == 90 &&
			payload.senderId == 42 &&
			payload.recipientId == 43 &&
			payload.clientMessageId == clientMessageID &&
			string(payload.envelope) == string(envelope),
			fmt.tprintf("expected the envelope exactly as sent, got %v", payload),
		)
		seen[peerID] = true
	}
	assert(seen[senderPeerID] && seen[recipientPeerID], "expected both users' sessions")
	routerTestExpectNoNetworkMessage(&h, "expected one copy per session")
}

@(test)
testMainRouterRefusesInvalidSealedDirectMessages :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)

	peerID := u32(1)
	senderKey: common.IdentityPrivateKeyBytes
	transport := routerCompleteHandshake(&h, peerID, 42, identityPrivateKeyOut = &senderKey)
	peers := [?]RouterTestPeer{{peerID, &transport}}

	clientMessageID := routerTestMessageID(3)
	envelope := routerTestEnvelope(&h, senderKey, 42, 43, clientMessageID, "x")
	defer delete(envelope)
	oversized := make([]u8, common.SEALED_ENVELOPE_MAX_BYTES + 1)
	defer delete(oversized)
	garbage := make([]u8, 200)
	defer delete(garbage)
	for index in 0 ..< len(garbage) {
		garbage[index] = u8(index)
	}
	truncated := envelope[:len(envelope) - 1]
	cases := [?]struct {
		payload:  common.ClientSealedDirectMessagePayload,
		expected: string,
	} {
		{{43, clientMessageID, nil, nil}, common.SEALED_DIRECT_MESSAGE_INVALID_MESSAGE},
		{{43, {}, envelope, nil}, common.SEALED_DIRECT_MESSAGE_INVALID_MESSAGE},
		{{0, clientMessageID, envelope, nil}, common.SEALED_DIRECT_MESSAGE_INVALID_MESSAGE},
		{{43, clientMessageID, oversized, nil}, common.SEALED_DIRECT_MESSAGE_INVALID_MESSAGE},
		{{43, clientMessageID, garbage, nil}, common.SEALED_DIRECT_MESSAGE_INVALID_MESSAGE},
		{{43, clientMessageID, truncated, nil}, common.SEALED_DIRECT_MESSAGE_INVALID_MESSAGE},
		{{42, clientMessageID, envelope, nil}, "Cannot send a direct message to yourself"},
	}
	for refused in cases {
		routerTestSendSealed(&h, &transport, peerID, .ClientSealedDirectMessage, refused.payload)
		routerTestExpectProtocolError(&h, peers[:], refused.expected)
		routerTestExpectNoDatabaseQuery(&h, "expected a malformed envelope to stay local")
	}

	// What only the database can decide comes back as a refusal, and nothing fans out.
	outcomes := [?]struct {
		outcome:  common.DirectMessagePostOutcome,
		expected: string,
	} {
		{.InvalidEnvelope, common.SEALED_DIRECT_MESSAGE_INVALID_MESSAGE},
		{.Duplicate, common.DIRECT_MESSAGE_DUPLICATE_MESSAGE},
		{.UnknownRecipient, "Unknown direct message recipient"},
	}
	for refused in outcomes {
		routerTestSendSealed(
			&h,
			&transport,
			peerID,
			.ClientSealedDirectMessage,
			common.ClientSealedDirectMessagePayload{43, clientMessageID, envelope, nil},
		)
		query := routerPollDatabaseQuery(&h)
		MainRouterState_handleDatabaseResult(
			&h.pm,
			&h.state,
			query.request_id,
			common.DatabaseQueryResponse {
				success = true,
				result = common.DatabasePostDirectMessageResult{outcome = refused.outcome},
			},
		)
		IPC__database_query_request_deinit(query.request)
		routerTestExpectProtocolError(&h, peers[:], refused.expected)
		routerTestExpectNoNetworkMessage(&h, "expected a refused envelope to fan out nothing")
	}
	session, ok := MainRouterState_getPeerSession(&h.state, peerID)
	assert(ok && session.isAuthenticated, "expected refusals to keep the session")

	// Unauthenticated sessions are refused before anything else.
	unauthenticated := u32(9)
	h.state.connectedPeers[unauthenticated] = true
	MainRouterState_setPeerSession(&h.state, unauthenticated, RouterPeerSession_init())
	bytes, err := cbor.marshal(
		common.ClientSealedDirectMessagePayload{43, clientMessageID, envelope, nil},
	)
	assert(err == nil, "expected the payload to encode")
	defer delete(bytes)
	MainRouterState_handleClientSealedDirectMessage(&h.pm, &h.state, unauthenticated, bytes)
	routerTestExpectPlaintextProtocolError(&h, "Unauthenticated direct message")
	routerTestExpectNoDatabaseQuery(&h, "expected an unauthenticated envelope to stay local")
}

@(test)
testMainRouterRefusesUnsignedAndForgedFallbackDirectMessages :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)

	peerID := u32(1)
	senderKey: common.IdentityPrivateKeyBytes
	transport := routerCompleteHandshake(&h, peerID, 42, identityPrivateKeyOut = &senderKey)
	peers := [?]RouterTestPeer{{peerID, &transport}}
	otherKey, _, otherOK := common.generateIdentityKeyPair()
	assert(otherOK, "expected another identity key")

	unsigned := routerTestPlainDirectMessage(&h, senderKey, 42, 43, "unsigned")
	unsigned.signature = {}
	byOther := routerTestPlainDirectMessage(&h, otherKey, 42, 43, "by someone else")
	changedContent := routerTestPlainDirectMessage(&h, senderKey, 42, 43, "original")
	changedContent.content = "changed"
	changedRecipient := routerTestPlainDirectMessage(&h, senderKey, 42, 44, "to carol")
	changedRecipient.recipientUserId = 43
	changedID := routerTestPlainDirectMessage(&h, senderKey, 42, 43, "id")
	changedID.clientMessageId[0] ~= 0xFF
	for forged in ([]common.ClientDirectMessagePayload {
			unsigned,
			byOther,
			changedContent,
			changedRecipient,
			changedID,
		}) {
		routerTestSendSealed(&h, &transport, peerID, .ClientDirectMessage, forged)
		routerTestExpectProtocolError(&h, peers[:], common.DIRECT_MESSAGE_SIGNATURE_INVALID_MESSAGE)
		routerTestExpectNoDatabaseQuery(&h, "expected a bad signature to be refused early")
	}

	// A signature over another server's key is refused too.
	{
		clientMessageID := routerTestMessageID(40)
		_, otherServer, _ := common.generateIdentityKeyPair()
		signature, _ := common.signPlaintextDirectMessage(
			{otherServer, 42, 43, clientMessageID},
			"other server",
			senderKey,
		)
		routerTestSendSealed(
			&h,
			&transport,
			peerID,
			.ClientDirectMessage,
			common.ClientDirectMessagePayload{43, "other server", clientMessageID, signature, nil},
		)
		routerTestExpectProtocolError(&h, peers[:], common.DIRECT_MESSAGE_SIGNATURE_INVALID_MESSAGE)
		routerTestExpectNoDatabaseQuery(&h, "expected another server's signature to be refused")
	}

	// A duplicate ID found by the database is refused cleanly.
	routerTestSendSealed(
		&h,
		&transport,
		peerID,
		.ClientDirectMessage,
		routerTestPlainDirectMessage(&h, senderKey, 42, 43, "again"),
	)
	query := routerPollDatabaseQuery(&h)
	defer IPC__database_query_request_deinit(query.request)
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		query.request_id,
		common.DatabaseQueryResponse {
			success = true,
			result = common.DatabasePostDirectMessageResult{outcome = .Duplicate},
		},
	)
	routerTestExpectProtocolError(&h, peers[:], common.DIRECT_MESSAGE_DUPLICATE_MESSAGE)
	session, ok := MainRouterState_getPeerSession(&h.state, peerID)
	assert(ok && session.isAuthenticated, "expected refusals to keep the session")
}
