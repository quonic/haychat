package server

import "../common"
import "core:encoding/cbor"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:testing"

// Router tests for sender chains in encrypted rooms (protocol 19, router_room_keys.odin and the
// sealed path of MainRouterState_handleClientChatMessage) with stubbed database results; the
// statements run against PostgreSQL in database_room_keys_test.odin. alice is user 42 (peer
// 1), bob 43 (peer 2) and carol 44 (peer 3), each with a real identity key.

@(private = "file")
RouterRoomKeysTest :: struct {
	h:          RouterTestHarness,
	keys:       [3]common.IdentityPrivateKeyBytes,
	transports: [3]common.TransportState,
	peers:      [3]RouterTestPeer,
}

@(private = "file")
routerRoomKeysTestInit :: proc(test: ^RouterRoomKeysTest) {
	test.h = routerTestHarness_init()
	for index in 0 ..< 3 {
		peerID := u32(index + 1)
		test.h.state.connectedPeers[peerID] = true
	}
	for index in 0 ..< 3 {
		peerID := u32(index + 1)
		test.transports[index] = routerCompleteHandshake(
			&test.h,
			peerID,
			42 + index,
			identityPrivateKeyOut = &test.keys[index],
		)
		test.peers[index] = RouterTestPeer{peerID, &test.transports[index]}
		// Every earlier session hears that this one came online.
		for _ in 0 ..< index {
			routerTestSkipPresence(&test.h, test.peers[:index + 1])
		}
	}
	routerTestExpectNoNetworkMessage(&test.h, "expected only presence notices so far")
}

@(private = "file")
routerRoomKeysTestDeinit :: proc(test: ^RouterRoomKeysTest) {
	routerTestHarness_deinit(&test.h)
}

@(private = "file")
routerRoomKeysTestFill :: proc(fill: u8) -> (id: [16]u8) {
	for index in 0 ..< len(id) {
		id[index] = fill + u8(index)
	}
	return
}

// A sealed room message by senderKey for (room, senderID); the caller frees it.
@(private = "file")
routerRoomKeysTestMessage :: proc(
	test: ^RouterRoomKeysTest,
	senderKey: common.IdentityPrivateKeyBytes,
	roomID, senderID: int,
	clientMessageID: common.ClientMessageID,
	header: common.RoomMessageHeader,
) -> []u8 {
	messageKey: common.MessageKey
	messageKey[0] = 1
	plaintext: [64]u8
	n, ok := common.encodeSealedDirectMessagePlaintext("hello", plaintext[:])
	assert(ok, "expected the plaintext to encode")
	buffer: [common.SEALED_ROOM_MESSAGE_MAX_BYTES]u8
	size, err := common.sealRoomMessage(
		common.RoomMessageContext {
			serverIdentityPublicKey = test.h.state.serverIdentityPublicKey,
			roomID = roomID,
			senderUserID = senderID,
			clientMessageID = clientMessageID,
		},
		header,
		messageKey,
		plaintext[:n],
		senderKey,
		buffer[:],
	)
	assert(err == .None, fmt.tprintf("expected the message to seal, got %v", err))
	sealed := make([]u8, size)
	copy(sealed, buffer[:size])
	return sealed
}

// A SenderKey envelope by senderKey for (room, epoch, senderID, chain) with wraps for
// recipients; the caller frees it.
@(private = "file")
routerRoomKeysTestEnvelope :: proc(
	test: ^RouterRoomKeysTest,
	senderKey: common.IdentityPrivateKeyBytes,
	roomID, epoch, senderID: int,
	chainID: common.ChainID,
	recipients: []int,
	kind := common.EnvelopeKind.SenderKey,
) -> []u8 {
	wraps := make([]common.EnvelopeRecipient, len(recipients))
	defer delete(wraps)
	for userID, index in recipients {
		keyPair, ok := common.generateEncryptionKeyPair()
		assert(ok, "expected a recipient key")
		wraps[index] = {userID, keyPair.publicKey}
	}
	fields := common.RoomKeyAADFields {
		serverIdentityPublicKey = test.h.state.serverIdentityPublicKey,
		roomID                  = roomID,
		epoch                   = epoch,
		senderUserID            = senderID,
		chainID                 = chainID,
	}
	buffer: [common.SEALED_ENVELOPE_MAX_BYTES]u8
	n: int
	err: common.E2EEError
	if kind == .SenderKey {
		chainKey: common.ChainKey
		chainKey[0] = 9
		n, err = common.sealSenderKeyDistribution(fields, 0, chainKey, wraps, senderKey, buffer[:])
	} else {
		aad := common.makeRoomKeyAAD(fields)
		plaintext := [4]u8{1, 2, 3, 4}
		n, err = common.sealEnvelope(kind, aad[:], plaintext[:], wraps, senderKey, buffer[:])
	}
	assert(err == .None, fmt.tprintf("expected the envelope to seal, got %v", err))
	envelope := make([]u8, n)
	copy(envelope, buffer[:n])
	return envelope
}

@(test)
testRoomChainsRouterSealedMessageIsCheckedAndFannedOutByteForByte :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	test: RouterRoomKeysTest
	routerRoomKeysTestInit(&test)
	defer routerRoomKeysTestDeinit(&test)
	h := &test.h

	clientMessageID := common.ClientMessageID(routerRoomKeysTestFill(7))
	chainID := common.ChainID(routerRoomKeysTestFill(30))
	header := common.RoomMessageHeader {
		epoch   = 3,
		chainID = chainID,
		index   = 5,
	}
	sealed := routerRoomKeysTestMessage(&test, test.keys[0], 9, 42, clientMessageID, header)
	defer delete(sealed)
	routerTestSendSealed(
		h,
		&test.transports[0],
		1,
		.ClientChatMessage,
		common.ClientChatMessagePayload {
			roomId = 9,
			clientMessageId = clientMessageID,
			sealed = sealed,
		},
	)
	query := routerPollDatabaseQuery(h)
	request, requestOK := query.request.(common.DatabasePostRoomChatMessageRequest)
	assert(
		requestOK &&
		request.roomId == 9 &&
		request.senderId == 42 &&
		request.content == "" &&
		string(request.sealed) == string(sealed) &&
		request.clientMessageId == clientMessageID &&
		request.epoch == 3 &&
		request.chainId == chainID &&
		request.chainIndex == 5,
		fmt.tprintf("expected the sealed message with its chain position, got %v", request),
	)
	IPC__database_query_request_deinit(query.request)
	stored := make([]u8, len(sealed))
	copy(stored, sealed)
	recipients := make([dynamic]int)
	append(&recipients, 42, 43)
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		query.request_id,
		common.DatabaseQueryResponse {
			success = true,
			result = common.DatabasePostRoomChatMessageResult {
				isMember = true,
				storedMessage = {
					id = 70,
					senderId = 42,
					senderNickname = strings.clone("alice"),
					roomId = 9,
					timestamp = strings.clone("2026-11-14 10:00:00+00"),
					content = strings.clone(""),
					clientMessageId = clientMessageID,
					sealed = stored,
				},
				recipientUserIDs = recipients,
			},
		},
	)
	seen := map[u32]bool{}
	defer delete(seen)
	for _ in 0 ..< 2 {
		peerID, packet := routerTestReceive(h, test.peers[:])
		defer delete(packet.payload)
		assert(packet.messageType == .ServerChatMessage, "expected ServerChatMessage")
		payload: common.ServerChatMessagePayload
		assert(
			cbor.unmarshal(packet.payload, &payload, temp_allocator = context.allocator) == nil,
			"expected the chat message to decode",
		)
		defer common.ServerChatMessagePayload_deinit(&payload)
		assert(
			payload.id == 70 &&
			payload.content == "" &&
			payload.clientMessageId == clientMessageID &&
			string(payload.sealed) == string(sealed),
			fmt.tprintf("expected the sealed bytes exactly as sent, got %v", payload),
		)
		seen[peerID] = true
	}
	assert(seen[1] && seen[2] && !seen[3], "expected the members' sessions only")
	routerTestExpectNoNetworkMessage(h, "expected one copy per member session")

	// What the router can check stays local: a message signed by bob's key for alice, one for
	// another room or client message ID than it was sealed for, no client message ID, content
	// next to sealed bytes, garbage and a truncated message.
	forged := routerRoomKeysTestMessage(&test, test.keys[1], 9, 42, clientMessageID, header)
	defer delete(forged)
	garbage := make([]u8, 200)
	defer delete(garbage)
	otherID := common.ClientMessageID(routerRoomKeysTestFill(90))
	cases := [?]common.ClientChatMessagePayload {
		{roomId = 9, clientMessageId = clientMessageID, sealed = forged},
		{roomId = 8, clientMessageId = clientMessageID, sealed = sealed},
		{roomId = 9, clientMessageId = otherID, sealed = sealed},
		{roomId = 9, sealed = sealed},
		{roomId = 9, content = "plain", clientMessageId = clientMessageID, sealed = sealed},
		{roomId = 9, clientMessageId = clientMessageID, sealed = garbage},
		{roomId = 9, clientMessageId = clientMessageID, sealed = sealed[:len(sealed) - 1]},
	}
	for refused in cases {
		routerTestSendSealed(h, &test.transports[0], 1, .ClientChatMessage, refused)
		routerTestExpectProtocolError(h, test.peers[:], common.SEALED_ROOM_MESSAGE_INVALID_MESSAGE)
		routerTestExpectNoDatabaseQuery(h, "expected an invalid sealed message to stay local")
	}

	// What only the database decides comes back as its sentence, and nothing fans out.
	outcomes := [?]struct {
		result:   common.DatabasePostRoomChatMessageResult,
		expected: string,
	} {
		{{isMember = true, staleEpoch = true}, common.ROOM_KEY_OUT_OF_DATE_MESSAGE},
		{{isMember = true, duplicate = true}, common.ROOM_MESSAGE_DUPLICATE_MESSAGE},
		{{isMember = true, notEncrypted = true}, common.SEALED_ROOM_MESSAGE_NOT_ENCRYPTED_MESSAGE},
		{{isMember = true, encryptedRoom = true}, common.ENCRYPTED_ROOM_CHAT_MESSAGE},
		{{isMember = false}, "Not a room member"},
	}
	for refused in outcomes {
		routerTestSendSealed(
			h,
			&test.transports[0],
			1,
			.ClientChatMessage,
			common.ClientChatMessagePayload {
				roomId = 9,
				clientMessageId = clientMessageID,
				sealed = sealed,
			},
		)
		refusedQuery := routerPollDatabaseQuery(h)
		IPC__database_query_request_deinit(refusedQuery.request)
		MainRouterState_handleDatabaseResult(
			&h.pm,
			&h.state,
			refusedQuery.request_id,
			common.DatabaseQueryResponse{success = true, result = refused.result},
		)
		routerTestExpectProtocolError(h, test.peers[:], refused.expected)
		routerTestExpectNoNetworkMessage(h, "expected a refused message to fan out nothing")
	}
}

@(test)
testRoomChainsRouterKeyEnvelopeGoesToItsWrapsOnly :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	test: RouterRoomKeysTest
	routerRoomKeysTestInit(&test)
	defer routerRoomKeysTestDeinit(&test)
	h := &test.h

	chainID := common.ChainID(routerRoomKeysTestFill(40))
	envelope := routerRoomKeysTestEnvelope(&test, test.keys[0], 9, 2, 42, chainID, {42, 43})
	defer delete(envelope)
	routerTestSendSealed(
		h,
		&test.transports[0],
		1,
		.ClientRoomKeyEnvelope,
		common.ClientRoomKeyEnvelopePayload {
			roomId = 9,
			epoch = 2,
			chainId = chainID,
			envelope = envelope,
		},
	)
	query := routerPollDatabaseQuery(h)
	request, requestOK := query.request.(common.DatabaseStoreRoomKeyEnvelopeRequest)
	assert(
		requestOK &&
		request.senderId == 42 &&
		request.roomId == 9 &&
		request.epoch == 2 &&
		request.chainId == chainID &&
		string(request.envelope) == string(envelope) &&
		len(request.recipientUserIDs) == 2 &&
		request.recipientUserIDs[0] == 42 &&
		request.recipientUserIDs[1] == 43,
		fmt.tprintf("expected the envelope with its wraps' users, got %v", request),
	)
	IPC__database_query_request_deinit(query.request)
	stored := make([]u8, len(envelope))
	copy(stored, envelope)
	recipients := make([dynamic]int)
	append(&recipients, 42, 43)
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		query.request_id,
		common.DatabaseQueryResponse {
			success = true,
			result = common.DatabaseStoreRoomKeyEnvelopeResult {
				outcome = .Stored,
				stored = {
					id = 5,
					roomId = 9,
					epoch = 2,
					senderId = 42,
					chainId = chainID,
					envelope = stored,
				},
				recipientUserIDs = recipients,
			},
		},
	)
	seen := map[u32]bool{}
	defer delete(seen)
	for _ in 0 ..< 2 {
		peerID, packet := routerTestReceive(h, test.peers[:])
		defer delete(packet.payload)
		assert(packet.messageType == .ServerRoomKeyEnvelope, "expected ServerRoomKeyEnvelope")
		payload: common.ServerRoomKeyEnvelopePayload
		assert(
			cbor.unmarshal(packet.payload, &payload, temp_allocator = context.allocator) == nil,
			"expected the envelope to decode",
		)
		defer common.ServerRoomKeyEnvelopePayload_deinit(&payload)
		got := payload.envelope
		assert(
			got.id == 5 &&
			got.senderId == 42 &&
			got.epoch == 2 &&
			got.chainId == chainID &&
			string(got.envelope) == string(envelope),
			fmt.tprintf("expected the envelope exactly as sent, got %v", got),
		)
		seen[peerID] = true
	}
	assert(seen[1] && seen[2] && !seen[3], "expected only the wraps' accounts")
	routerTestExpectNoNetworkMessage(h, "expected one copy per recipient session")

	// Signed by another key, sealed for another epoch, room or chain than claimed, of another
	// kind, or garbage: refused before the database.
	forged := routerRoomKeysTestEnvelope(&test, test.keys[1], 9, 2, 42, chainID, {42, 43})
	defer delete(forged)
	directKind := routerRoomKeysTestEnvelope(
		&test,
		test.keys[0],
		9,
		2,
		42,
		chainID,
		{42, 43},
		.DirectMessage,
	)
	defer delete(directKind)
	otherChain := common.ChainID(routerRoomKeysTestFill(41))
	garbage := make([]u8, 300)
	defer delete(garbage)
	cases := [?]common.ClientRoomKeyEnvelopePayload {
		{roomId = 9, epoch = 2, chainId = chainID, envelope = forged},
		{roomId = 9, epoch = 3, chainId = chainID, envelope = envelope},
		{roomId = 8, epoch = 2, chainId = chainID, envelope = envelope},
		{roomId = 9, epoch = 2, chainId = otherChain, envelope = envelope},
		{roomId = 9, epoch = 2, chainId = chainID, envelope = directKind},
		{roomId = 9, epoch = 2, chainId = chainID, envelope = garbage},
		{roomId = 9, epoch = 0, chainId = chainID, envelope = envelope},
	}
	for refused in cases {
		routerTestSendSealed(h, &test.transports[0], 1, .ClientRoomKeyEnvelope, refused)
		routerTestExpectProtocolError(h, test.peers[:], common.ROOM_KEY_ENVELOPE_INVALID_MESSAGE)
		routerTestExpectNoDatabaseQuery(h, "expected an invalid envelope to stay local")
	}

	// bob forwarding alice's envelope as his own fails her signature too.
	routerTestSendSealed(
		h,
		&test.transports[1],
		2,
		.ClientRoomKeyEnvelope,
		common.ClientRoomKeyEnvelopePayload {
			roomId = 9,
			epoch = 2,
			chainId = chainID,
			envelope = envelope,
		},
	)
	routerTestExpectProtocolError(h, test.peers[:], common.ROOM_KEY_ENVELOPE_INVALID_MESSAGE)
	routerTestExpectNoDatabaseQuery(h, "expected a replayed envelope to stay local")

	// The database's refusals become sentences.
	outcomes := [?]struct {
		outcome:  common.RoomKeyEnvelopeOutcome,
		expected: string,
	} {
		{.StaleEpoch, common.ROOM_KEY_OUT_OF_DATE_MESSAGE},
		{.WrongRecipients, common.ROOM_KEY_ENVELOPE_INVALID_MESSAGE},
		{.NotMember, "Not a room member"},
		{.NotEncrypted, common.ROOM_LOG_NOT_ENCRYPTED_MESSAGE},
	}
	for refused in outcomes {
		routerTestSendSealed(
			h,
			&test.transports[0],
			1,
			.ClientRoomKeyEnvelope,
			common.ClientRoomKeyEnvelopePayload {
				roomId = 9,
				epoch = 2,
				chainId = chainID,
				envelope = envelope,
			},
		)
		refusedQuery := routerPollDatabaseQuery(h)
		IPC__database_query_request_deinit(refusedQuery.request)
		MainRouterState_handleDatabaseResult(
			&h.pm,
			&h.state,
			refusedQuery.request_id,
			common.DatabaseQueryResponse {
				success = true,
				result = common.DatabaseStoreRoomKeyEnvelopeResult{outcome = refused.outcome},
			},
		)
		routerTestExpectProtocolError(h, test.peers[:], refused.expected)
		routerTestExpectNoNetworkMessage(h, "expected a refused envelope to fan out nothing")
	}
}

@(test)
testRoomChainsRouterFetchAndKeyRequests :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	test: RouterRoomKeysTest
	routerRoomKeysTestInit(&test)
	defer routerRoomKeysTestDeinit(&test)
	h := &test.h
	chainID := common.ChainID(routerRoomKeysTestFill(50))

	// A fetch asks for the requester's own envelopes and is answered to it alone.
	routerTestSendSealed(
		h,
		&test.transports[1],
		2,
		.ClientFetchRoomKeys,
		common.ClientFetchRoomKeysPayload{roomId = 9, sinceEpoch = 1, afterId = 4},
	)
	fetchQuery := routerPollDatabaseQuery(h)
	fetch, fetchOK := fetchQuery.request.(common.DatabaseFetchRoomKeysRequest)
	assert(
		fetchOK &&
		fetch.userId == 43 &&
		fetch.roomId == 9 &&
		fetch.sinceEpoch == 1 &&
		fetch.afterId == 4,
		fmt.tprintf("expected bob's fetch, got %v", fetch),
	)
	envelopes := make([dynamic]common.RoomKeyEnvelope)
	stored := make([]u8, 3)
	stored[0] = 1
	append(
		&envelopes,
		common.RoomKeyEnvelope {
			id = 6,
			roomId = 9,
			epoch = 2,
			senderId = 42,
			chainId = chainID,
			envelope = stored,
		},
	)
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		fetchQuery.request_id,
		common.DatabaseQueryResponse {
			success = true,
			result = common.DatabaseFetchRoomKeysResult {
				sinceEpoch = 1,
				afterId = 4,
				isMember = true,
				envelopes = envelopes,
				hasMore = true,
			},
		},
	)
	peerID, packet := routerTestReceive(h, test.peers[:])
	{
		defer delete(packet.payload)
		assert(peerID == 2 && packet.messageType == .ServerRoomKeys, "expected bob's answer")
		page: common.ServerRoomKeysPayload
		assert(
			cbor.unmarshal(packet.payload, &page, temp_allocator = context.allocator) == nil,
			"expected the page to decode",
		)
		defer common.ServerRoomKeysPayload_deinit(&page)
		assert(
			page.roomId == 9 &&
			page.sinceEpoch == 1 &&
			page.afterId == 4 &&
			page.hasMore &&
			len(page.envelopes) == 1 &&
			page.envelopes[0].id == 6 &&
			page.envelopes[0].chainId == chainID,
			fmt.tprintf("expected the page as stored, got %v", page),
		)
	}
	routerTestExpectNoNetworkMessage(h, "expected the page for bob only")
	routerTestSendSealed(
		h,
		&test.transports[2],
		3,
		.ClientFetchRoomKeys,
		common.ClientFetchRoomKeysPayload{roomId = 9},
	)
	outsiderQuery := routerPollDatabaseQuery(h)
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		outsiderQuery.request_id,
		common.DatabaseQueryResponse {
			success = true,
			result = common.DatabaseFetchRoomKeysResult{isMember = false},
		},
	)
	routerTestExpectProtocolError(h, test.peers[:], "Not a room member")

	// bob asks alice to re-seal her chain: the check runs, and an allowed request reaches
	// alice's session only, naming bob.
	routerTestSendSealed(
		h,
		&test.transports[1],
		2,
		.ClientRequestRoomKey,
		common.ClientRequestRoomKeyPayload {
			roomId = 9,
			epoch = 2,
			senderId = 42,
			chainId = chainID,
		},
	)
	checkQuery := routerPollDatabaseQuery(h)
	check, checkOK := checkQuery.request.(common.DatabaseRoomKeyRequestCheckRequest)
	assert(
		checkOK &&
		check.requesterId == 43 &&
		check.roomId == 9 &&
		check.epoch == 2 &&
		check.senderId == 42 &&
		check.chainId == chainID,
		fmt.tprintf("expected bob's request checked, got %v", check),
	)
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		checkQuery.request_id,
		common.DatabaseQueryResponse {
			success = true,
			result = common.DatabaseRoomKeyRequestCheckResult{allowed = true, request = check},
		},
	)
	requestPeer, requestPacket := routerTestReceive(h, test.peers[:])
	{
		defer delete(requestPacket.payload)
		assert(
			requestPeer == 1 && requestPacket.messageType == .ServerRoomKeyRequest,
			"expected the request relayed to alice",
		)
		relayed: common.ServerRoomKeyRequestPayload
		assert(
			cbor.unmarshal(requestPacket.payload, &relayed, temp_allocator = context.allocator) ==
			nil,
			"expected the request to decode",
		)
		assert(
			relayed.roomId == 9 &&
			relayed.epoch == 2 &&
			relayed.chainId == chainID &&
			relayed.requesterId == 43,
			fmt.tprintf("expected bob's request as asked, got %v", relayed),
		)
	}
	routerTestExpectNoNetworkMessage(h, "expected the request for alice only")

	// A refused check answers nobody; asking oneself is refused at once.
	routerTestSendSealed(
		h,
		&test.transports[1],
		2,
		.ClientRequestRoomKey,
		common.ClientRequestRoomKeyPayload {
			roomId = 9,
			epoch = 2,
			senderId = 42,
			chainId = chainID,
		},
	)
	deniedQuery := routerPollDatabaseQuery(h)
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		deniedQuery.request_id,
		common.DatabaseQueryResponse {
			success = true,
			result = common.DatabaseRoomKeyRequestCheckResult{allowed = false, request = check},
		},
	)
	routerTestExpectNoNetworkMessage(h, "expected a refused key request to reach nobody")
	routerTestSendSealed(
		h,
		&test.transports[1],
		2,
		.ClientRequestRoomKey,
		common.ClientRequestRoomKeyPayload {
			roomId = 9,
			epoch = 2,
			senderId = 43,
			chainId = chainID,
		},
	)
	routerTestExpectProtocolError(h, test.peers[:], common.ROOM_KEY_REQUEST_INVALID_MESSAGE)
	routerTestExpectNoDatabaseQuery(h, "expected a request to oneself to stay local")
}
