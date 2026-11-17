package server

import "../common"
import "core:encoding/cbor"
import "core:fmt"
import "core:sync"
import "core:testing"

// Router tests for voice keys in encrypted rooms (protocol 21, voice.odin): joins, the checks
// on ClientVoiceKey, fan-out, the keys a joiner gets, when keys are forgotten, and key
// requests. They reuse the voice harness of router_voice_test.odin with real identity keys, so
// the envelopes are signed as clients sign them. alice is user 42 (peer 1), bob 43 (peer 2),
// carol 44 (peer 3); room 9 is encrypted at log version 3 with all three as members.

@(private = "file")
VOICE_KEYS_TEST_ROOM :: 9
@(private = "file")
VOICE_KEYS_TEST_EPOCH :: 3

@(private = "file")
RouterVoiceKeysTest :: struct {
	h:       RouterTestHarness,
	clients: [3]RouterVoiceTestClient,
	keys:    [3]common.IdentityPrivateKeyBytes,
}

@(private = "file")
routerVoiceKeysTestInit :: proc(test: ^RouterVoiceKeysTest) {
	test.h = routerTestHarness_init()
	for index in 0 ..< 3 {
		test.clients[index] = RouterVoiceTestClient {
			peerID = u32(index + 1),
			userID = 42 + index,
		}
	}
	for &client, index in test.clients {
		test.h.state.connectedPeers[client.peerID] = true
		client.transport = routerCompleteHandshake(
			&test.h,
			client.peerID,
			client.userID,
			fmt.tprintf("voice-key-user-%d", client.userID),
			identityPrivateKeyOut = &test.keys[index],
		)
		drain := routerVoiceTestDrain(&test.h, test.clients[:])
		RouterVoiceTestDrain_deinit(&drain)
	}
}

@(private = "file")
routerVoiceKeysTestDeinit :: proc(test: ^RouterVoiceKeysTest) {
	routerVoiceTestDisconnectAll(test.clients[:])
	routerTestHarness_deinit(&test.h)
}

// Joins client to roomID's voice and answers the membership check for an encrypted room at
// logVersion (or a plain room when encrypted is false).
@(private = "file")
routerVoiceKeysTestJoin :: proc(
	test: ^RouterVoiceKeysTest,
	index: int,
	encrypted := true,
	logVersion := VOICE_KEYS_TEST_EPOCH,
	roomID := VOICE_KEYS_TEST_ROOM,
) -> RouterVoiceTestDrain {
	routerVoiceTestSendJoin(&test.h, &test.clients[index], roomID)
	return routerVoiceKeysTestAnswerJoin(test, encrypted, logVersion)
}

// Answers the pending join's membership check, as routerVoiceKeysTestJoin does.
@(private = "file")
routerVoiceKeysTestAnswerJoin :: proc(
	test: ^RouterVoiceKeysTest,
	encrypted := true,
	logVersion := VOICE_KEYS_TEST_EPOCH,
) -> RouterVoiceTestDrain {
	query := routerPollDatabaseQuery(&test.h)
	defer IPC__database_query_request_deinit(query.request)
	userIDs := make([dynamic]int, 0, 3)
	append(&userIDs, 42, 43, 44)
	MainRouterState_handleDatabaseResult(
		&test.h.pm,
		&test.h.state,
		query.request_id,
		common.DatabaseQueryResponse {
			success = true,
			result = common.DatabaseRoomMemberListResult {
				userIDs = userIDs,
				roomFound = true,
				roomType = .ChatAndVoice,
				encrypted = encrypted,
				logVersion = encrypted ? logVersion : 0,
			},
		},
	)
	return routerVoiceTestDrain(&test.h, test.clients[:])
}

// A VoiceKey payload signed by signer for sender's fields, with wraps for wrapUserIDs.
@(private = "file")
routerVoiceKeysTestPayload :: proc(
	test: ^RouterVoiceKeysTest,
	signer: common.IdentityPrivateKeyBytes,
	senderID: int,
	generation: u32,
	wrapUserIDs: []int,
	epoch := VOICE_KEYS_TEST_EPOCH,
	roomID := VOICE_KEYS_TEST_ROOM,
	kind := common.EnvelopeKind.VoiceKey,
) -> common.ClientVoiceKeyPayload {
	payload := common.ClientVoiceKeyPayload {
		roomId     = roomID,
		epoch      = epoch,
		generation = generation,
		createdAt  = 1_763_078_400 + i64(generation),
	}
	payload.voiceSessionId[0] = u8(senderID)
	wraps := make([]common.EnvelopeRecipient, len(wrapUserIDs))
	defer delete(wraps)
	for userID, index in wrapUserIDs {
		keyPair, ok := common.generateEncryptionKeyPair()
		assert(ok, "expected a recipient key")
		wraps[index] = {userID, keyPair.publicKey}
	}
	fields := common.VoiceKeyAADFields {
		serverIdentityPublicKey = test.h.state.serverIdentityPublicKey,
		roomID                  = roomID,
		epoch                   = epoch,
		senderUserID            = senderID,
		voiceSessionID          = payload.voiceSessionId,
		generation              = generation,
		createdAtUnix           = payload.createdAt,
	}
	buffer: [common.SEALED_ENVELOPE_MAX_BYTES]u8
	n: int
	err: common.E2EEError
	voiceKey: common.VoiceKey
	voiceKey[0] = u8(generation) + 1
	if kind == .VoiceKey {
		n, err = common.sealVoiceKey(fields, voiceKey, wraps, signer, buffer[:])
	} else {
		aad := common.makeVoiceKeyAAD(fields)
		plaintext := [4]u8{1, 2, 3, 4}
		n, err = common.sealEnvelope(kind, aad[:], plaintext[:], wraps, signer, buffer[:])
	}
	assert(err == .None, fmt.tprintf("expected the voice key to seal, got %v", err))
	payload.envelope = make([]u8, n)
	copy(payload.envelope, buffer[:n])
	return payload
}

@(private = "file")
routerVoiceKeysTestSend :: proc(
	test: ^RouterVoiceKeysTest,
	index: int,
	payload: ^common.ClientVoiceKeyPayload,
) -> RouterVoiceTestDrain {
	routerTestSendSealed(
		&test.h,
		&test.clients[index].transport,
		test.clients[index].peerID,
		.ClientVoiceKey,
		payload^,
	)
	common.ClientVoiceKeyPayload_deinit(payload)
	return routerVoiceTestDrain(&test.h, test.clients[:])
}

// The ServerVoiceKey payloads peerID got, in order. The caller frees them.
@(private = "file")
routerVoiceKeysTestKeysFor :: proc(
	drain: ^RouterVoiceTestDrain,
	peerID: u32,
) -> [dynamic]common.ServerVoiceKeyPayload {
	keys := make([dynamic]common.ServerVoiceKeyPayload, context.temp_allocator)
	for entry in drain.packets {
		if entry.peerID != peerID || entry.packet.messageType != .ServerVoiceKey {
			continue
		}
		payload: common.ServerVoiceKeyPayload
		assert(
			cbor.unmarshal(entry.packet.payload, &payload, temp_allocator = context.allocator) ==
			nil,
			"expected a ServerVoiceKey to decode",
		)
		append(&keys, payload)
	}
	return keys
}

@(private = "file")
routerVoiceKeysTestFreeKeys :: proc(keys: ^[dynamic]common.ServerVoiceKeyPayload) {
	for &key in keys {
		common.ServerVoiceKeyPayload_deinit(&key)
	}
}

// The single protocol error peerID got in drain.
@(private = "file")
routerVoiceKeysTestError :: proc(drain: ^RouterVoiceTestDrain, peerID: u32) -> string {
	message := ""
	count := 0
	for entry in drain.packets {
		if entry.peerID != peerID || entry.packet.messageType != .ServerProtocolError {
			continue
		}
		payload: common.ProtocolErrorResponse
		assert(cbor.unmarshal(entry.packet.payload, &payload) == nil, "expected an error")
		message = fmt.tprintf("%s", payload.message)
		delete(payload.message)
		count += 1
	}
	assert(count <= 1, "expected at most one protocol error")
	return message
}

@(test)
testVoiceKeysRouterJoinsEncryptedRoomsAndRelaysKeys :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	test: RouterVoiceKeysTest
	routerVoiceKeysTestInit(&test)
	defer routerVoiceKeysTestDeinit(&test)
	defer free_all(context.temp_allocator)

	// alice joins the encrypted room: accepted, with an encrypted route.
	drain := routerVoiceKeysTestJoin(&test, 0)
	_, rejected, wasRejected := routerVoiceTestReason(&drain, 1, .ServerVoiceJoinRejected)
	assert(!wasRejected, fmt.tprintf("expected the encrypted join accepted, got %q", rejected))
	assert(
		len(drain.routes) == 1 && drain.routes[0].encrypted,
		"expected an encrypted route for the relay",
	)
	RouterVoiceTestDrain_deinit(&drain)

	// Her key goes nowhere yet: nobody else is in voice.
	payload := routerVoiceKeysTestPayload(&test, test.keys[0], 42, 0, {43, 44})
	drain = routerVoiceKeysTestSend(&test, 0, &payload)
	assert(len(drain.packets) == 0, "expected no packet for a key with no other participant")
	RouterVoiceTestDrain_deinit(&drain)

	// bob joins: his acknowledgement, then alice's key, and nothing for carol.
	drain = routerVoiceKeysTestJoin(&test, 1)
	ackIndex, keyIndex := -1, -1
	for entry, index in drain.packets {
		if entry.peerID != 2 {
			continue
		}
		if entry.packet.messageType == .ServerVoiceParticipants && ackIndex < 0 {
			ackIndex = index
		}
		if entry.packet.messageType == .ServerVoiceKey {
			keyIndex = index
		}
	}
	assert(ackIndex >= 0 && keyIndex > ackIndex, "expected alice's key right after bob's ack")
	keys := routerVoiceKeysTestKeysFor(&drain, 2)
	assert(
		len(keys) == 1 &&
		keys[0].senderId == 42 &&
		keys[0].roomId == VOICE_KEYS_TEST_ROOM &&
		keys[0].epoch == VOICE_KEYS_TEST_EPOCH &&
		keys[0].generation == 0 &&
		keys[0].voiceSessionId[0] == 42,
		fmt.tprintf("expected alice's stored key for bob, got %v", keys[:]),
	)
	routerVoiceKeysTestFreeKeys(&keys)
	assert(len(routerVoiceTestRecipients(&drain, .ServerVoiceKey)) == 1, "expected one key")
	RouterVoiceTestDrain_deinit(&drain)

	// bob's key reaches alice only; alice's next key replaces her first.
	payload = routerVoiceKeysTestPayload(&test, test.keys[1], 43, 0, {42, 44})
	drain = routerVoiceKeysTestSend(&test, 1, &payload)
	recipients := routerVoiceTestRecipients(&drain, .ServerVoiceKey)
	assert(
		len(recipients) == 1 && recipients[0] == 1,
		fmt.tprintf("expected bob's key for alice only, got %v", recipients[:]),
	)
	RouterVoiceTestDrain_deinit(&drain)
	payload = routerVoiceKeysTestPayload(&test, test.keys[0], 42, 1, {43, 44})
	drain = routerVoiceKeysTestSend(&test, 0, &payload)
	recipients = routerVoiceTestRecipients(&drain, .ServerVoiceKey)
	assert(len(recipients) == 1 && recipients[0] == 2, "expected alice's new key for bob")
	RouterVoiceTestDrain_deinit(&drain)

	// carol joins: one key per other participant, the latest of each.
	drain = routerVoiceKeysTestJoin(&test, 2)
	keys = routerVoiceKeysTestKeysFor(&drain, 3)
	assert(len(keys) == 2, fmt.tprintf("expected two keys for carol, got %d", len(keys)))
	for key in keys {
		assert(
			(key.senderId == 42 && key.generation == 1) ||
			(key.senderId == 43 && key.generation == 0),
			fmt.tprintf("expected each participant's latest key, got %v", key),
		)
		assert(len(key.envelope) > 0, "expected the envelope carried")
	}
	routerVoiceKeysTestFreeKeys(&keys)
	RouterVoiceTestDrain_deinit(&drain)
}

@(test)
testVoiceKeysRouterRefusesBadKeys :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	test: RouterVoiceKeysTest
	routerVoiceKeysTestInit(&test)
	defer routerVoiceKeysTestDeinit(&test)
	defer free_all(context.temp_allocator)

	// Not in voice yet.
	payload := routerVoiceKeysTestPayload(&test, test.keys[0], 42, 0, {43})
	drain := routerVoiceKeysTestSend(&test, 0, &payload)
	assert(
		routerVoiceKeysTestError(&drain, 1) == common.VOICE_KEY_INVALID_MESSAGE,
		"expected a key from outside voice refused",
	)
	RouterVoiceTestDrain_deinit(&drain)

	drain = routerVoiceKeysTestJoin(&test, 0)
	RouterVoiceTestDrain_deinit(&drain)
	drain = routerVoiceKeysTestJoin(&test, 1)
	RouterVoiceTestDrain_deinit(&drain)

	Refusal :: struct {
		payload:  common.ClientVoiceKeyPayload,
		expected: string,
	}
	refusals := [?]Refusal {
		// Signed by bob's identity key, not the session's.
		{
			routerVoiceKeysTestPayload(&test, test.keys[1], 42, 0, {43}),
			common.VOICE_KEY_INVALID_MESSAGE,
		},
		// Signed for another sender ID.
		{
			routerVoiceKeysTestPayload(&test, test.keys[0], 43, 0, {44}),
			common.VOICE_KEY_INVALID_MESSAGE,
		},
		// Another envelope kind under the voice key AAD.
		{
			routerVoiceKeysTestPayload(&test, test.keys[0], 42, 0, {43}, kind = .SenderKey),
			common.VOICE_KEY_INVALID_MESSAGE,
		},
		// A stale epoch, and one the room has not reached.
		{
			routerVoiceKeysTestPayload(&test, test.keys[0], 42, 0, {43}, epoch = 2),
			common.VOICE_KEY_OUT_OF_DATE_MESSAGE,
		},
		{
			routerVoiceKeysTestPayload(&test, test.keys[0], 42, 0, {43}, epoch = 4),
			common.VOICE_KEY_INVALID_MESSAGE,
		},
		// Another room than the session's voice room.
		{
			routerVoiceKeysTestPayload(&test, test.keys[0], 42, 0, {43}, roomID = 10),
			common.VOICE_KEY_INVALID_MESSAGE,
		},
	}
	for &refusal, index in refusals {
		drain = routerVoiceKeysTestSend(&test, 0, &refusal.payload)
		got := routerVoiceKeysTestError(&drain, 1)
		assert(
			got == refusal.expected,
			fmt.tprintf("refusal %d: expected %q, got %q", index, refusal.expected, got),
		)
		assert(
			len(routerVoiceTestRecipients(&drain, .ServerVoiceKey)) == 0,
			fmt.tprintf("refusal %d: expected nothing relayed", index),
		)
		assert(len(drain.disconnects) == 0, "expected the session to stay")
		RouterVoiceTestDrain_deinit(&drain)
	}
	// A tampered signature.
	payload = routerVoiceKeysTestPayload(&test, test.keys[0], 42, 0, {43})
	payload.envelope[len(payload.envelope) - 1] ~= 1
	drain = routerVoiceKeysTestSend(&test, 0, &payload)
	assert(
		routerVoiceKeysTestError(&drain, 1) == common.VOICE_KEY_INVALID_MESSAGE,
		"expected a bad signature refused",
	)
	RouterVoiceTestDrain_deinit(&drain)
	// The stored state is untouched: carol's join brings no key.
	drain = routerVoiceKeysTestJoin(&test, 2)
	assert(len(routerVoiceTestRecipients(&drain, .ServerVoiceKey)) == 0, "expected no key stored")
	RouterVoiceTestDrain_deinit(&drain)
}

@(test)
testVoiceKeysRouterRefusesKeysInPlainRooms :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	test: RouterVoiceKeysTest
	routerVoiceKeysTestInit(&test)
	defer routerVoiceKeysTestDeinit(&test)
	defer free_all(context.temp_allocator)

	drain := routerVoiceKeysTestJoin(&test, 0, encrypted = false)
	assert(len(drain.routes) == 1 && !drain.routes[0].encrypted, "expected a plain route")
	RouterVoiceTestDrain_deinit(&drain)
	drain = routerVoiceKeysTestJoin(&test, 1, encrypted = false)
	RouterVoiceTestDrain_deinit(&drain)
	payload := routerVoiceKeysTestPayload(&test, test.keys[0], 42, 0, {43})
	drain = routerVoiceKeysTestSend(&test, 0, &payload)
	assert(
		routerVoiceKeysTestError(&drain, 1) == common.VOICE_KEY_INVALID_MESSAGE,
		"expected a voice key in a plain room refused",
	)
	assert(len(routerVoiceTestRecipients(&drain, .ServerVoiceKey)) == 0, "expected no relay")
	RouterVoiceTestDrain_deinit(&drain)
}

@(test)
testVoiceKeysRouterForgetsKeys :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	test: RouterVoiceKeysTest
	routerVoiceKeysTestInit(&test)
	defer routerVoiceKeysTestDeinit(&test)
	defer free_all(context.temp_allocator)
	room := VOICE_KEYS_TEST_ROOM

	storedKeys :: proc(test: ^RouterVoiceKeysTest) -> int {
		room, ok := test.h.state.voiceRooms[VOICE_KEYS_TEST_ROOM]
		return ok ? len(room.keys) : 0
	}
	sendKey :: proc(test: ^RouterVoiceKeysTest, index: int, epoch := VOICE_KEYS_TEST_EPOCH) {
		userID := 42 + index
		others := make([dynamic]int, 0, 2, context.temp_allocator)
		for other in 42 ..< 45 {
			if other != userID {
				append(&others, other)
			}
		}
		payload := routerVoiceKeysTestPayload(test, test.keys[index], userID, 0, others[:], epoch)
		drain := routerVoiceKeysTestSend(test, index, &payload)
		assert(routerVoiceKeysTestError(&drain, u32(index + 1)) == "", "expected the key accepted")
		RouterVoiceTestDrain_deinit(&drain)
	}

	for index in 0 ..< 3 {
		drain := routerVoiceKeysTestJoin(&test, index)
		RouterVoiceTestDrain_deinit(&drain)
		sendKey(&test, index)
	}
	assert(storedKeys(&test) == 3, "expected three stored keys")

	// A leave forgets the leaver's key.
	routerVoiceTestLeave(&test.h, &test.clients[2])
	drain := routerVoiceTestDrain(&test.h, test.clients[:])
	RouterVoiceTestDrain_deinit(&drain)
	assert(storedKeys(&test) == 2, "expected carol's key forgotten when she left")

	// An eviction (removed from the room) forgets it too.
	reason := VOICE_LEFT_REMOVED_FROM_ROOM
	MainRouterState_voiceEvictUser(&test.h.pm, &test.h.state, room, 43, reason)
	drain = routerVoiceTestDrain(&test.h, test.clients[:])
	RouterVoiceTestDrain_deinit(&drain)
	assert(storedKeys(&test) == 1, "expected bob's key forgotten on eviction")

	// A log append moves the epoch: alice's epoch 3 key goes, and so does a late epoch 3 key.
	drain = routerVoiceKeysTestJoin(&test, 2)
	RouterVoiceTestDrain_deinit(&drain)
	MainRouterState_voiceLogAdvanced(&test.h.state, room, VOICE_KEYS_TEST_EPOCH + 1)
	assert(storedKeys(&test) == 0, "expected the old epoch's keys dropped on a log append")
	payload := routerVoiceKeysTestPayload(&test, test.keys[0], 42, 1, {43, 44})
	drain = routerVoiceKeysTestSend(&test, 0, &payload)
	assert(
		routerVoiceKeysTestError(&drain, 1) == common.VOICE_KEY_OUT_OF_DATE_MESSAGE,
		"expected an epoch 3 key out of date after the append",
	)
	RouterVoiceTestDrain_deinit(&drain)
	sendKey(&test, 0, VOICE_KEYS_TEST_EPOCH + 1)
	assert(storedKeys(&test) == 1, "expected the new epoch's key stored")

	// A disconnect forgets it.
	MainRouterState_voiceLeave(&test.h.pm, &test.h.state, 1, skipSelf = true)
	drain = routerVoiceTestDrain(&test.h, test.clients[:])
	RouterVoiceTestDrain_deinit(&drain)
	assert(storedKeys(&test) == 0, "expected alice's key forgotten when her session went")
}

// #77: a member log append that the router applies while a room's first voice join is still in
// its database check must not be lost. The join's answer carries the older version it read; the
// voice room still takes the newer one, so a key at the new epoch is accepted.
@(test)
testVoiceKeysRouterKeepsAppendDuringFirstJoin :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	test: RouterVoiceKeysTest
	routerVoiceKeysTestInit(&test)
	defer routerVoiceKeysTestDeinit(&test)
	defer free_all(context.temp_allocator)
	newEpoch := VOICE_KEYS_TEST_EPOCH + 1

	// alice asks to join; before the database answers, an append moves the log to epoch 4.
	routerVoiceTestSendJoin(&test.h, &test.clients[0], VOICE_KEYS_TEST_ROOM)
	assert(
		VOICE_KEYS_TEST_ROOM not_in test.h.state.voiceRooms,
		"expected no voice room while the join check is pending",
	)
	entry := [4]u8{1, 2, 3, 4}
	members := [3]int{42, 43, 44}
	MainRouterState_sendRoomLogEntry(
		&test.h.pm,
		&test.h.state,
		VOICE_KEYS_TEST_ROOM,
		newEpoch,
		entry[:],
		members[:],
		nil,
		0,
		0,
	)
	drain := routerVoiceTestDrain(&test.h, test.clients[:])
	RouterVoiceTestDrain_deinit(&drain)

	// The check read epoch 3 before the append.
	drain = routerVoiceKeysTestAnswerJoin(&test, logVersion = VOICE_KEYS_TEST_EPOCH)
	_, rejected, wasRejected := routerVoiceTestReason(&drain, 1, .ServerVoiceJoinRejected)
	assert(!wasRejected, fmt.tprintf("expected the join accepted, got %q", rejected))
	RouterVoiceTestDrain_deinit(&drain)
	room := test.h.state.voiceRooms[VOICE_KEYS_TEST_ROOM]
	assert(
		room.logVersion == newEpoch,
		fmt.tprintf("expected the voice room at log version %d, got %d", newEpoch, room.logVersion),
	)

	// A key at the new epoch is accepted; one at the old epoch is out of date.
	payload := routerVoiceKeysTestPayload(&test, test.keys[0], 42, 0, {43, 44}, epoch = newEpoch)
	drain = routerVoiceKeysTestSend(&test, 0, &payload)
	got := routerVoiceKeysTestError(&drain, 1)
	assert(got == "", fmt.tprintf("expected the epoch %d key accepted, got %q", newEpoch, got))
	RouterVoiceTestDrain_deinit(&drain)
	payload = routerVoiceKeysTestPayload(&test, test.keys[0], 42, 1, {43, 44})
	drain = routerVoiceKeysTestSend(&test, 0, &payload)
	got = routerVoiceKeysTestError(&drain, 1)
	assert(
		got == common.VOICE_KEY_OUT_OF_DATE_MESSAGE,
		fmt.tprintf("expected an epoch %d key out of date, got %q", VOICE_KEYS_TEST_EPOCH, got),
	)
	RouterVoiceTestDrain_deinit(&drain)

	// bob joins with a check that read the new epoch: alice's key reaches him.
	drain = routerVoiceKeysTestJoin(&test, 1, logVersion = newEpoch)
	keys := routerVoiceKeysTestKeysFor(&drain, 2)
	assert(
		len(keys) == 1 && keys[0].senderId == 42 && keys[0].epoch == newEpoch,
		fmt.tprintf("expected alice's epoch %d key for bob, got %v", newEpoch, keys[:]),
	)
	routerVoiceKeysTestFreeKeys(&keys)
	RouterVoiceTestDrain_deinit(&drain)
}

@(test)
testVoiceKeysRouterRelaysRateLimitedRequests :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	test: RouterVoiceKeysTest
	routerVoiceKeysTestInit(&test)
	defer routerVoiceKeysTestDeinit(&test)
	defer free_all(context.temp_allocator)

	request :: proc(test: ^RouterVoiceKeysTest, index: int, senderID: int) -> RouterVoiceTestDrain {
		routerTestSendSealed(
			&test.h,
			&test.clients[index].transport,
			test.clients[index].peerID,
			.ClientRequestVoiceKey,
			common.ClientRequestVoiceKeyPayload{roomId = VOICE_KEYS_TEST_ROOM, senderId = senderID},
		)
		return routerVoiceTestDrain(&test.h, test.clients[:])
	}

	drain := routerVoiceKeysTestJoin(&test, 0)
	RouterVoiceTestDrain_deinit(&drain)
	drain = routerVoiceKeysTestJoin(&test, 1)
	RouterVoiceTestDrain_deinit(&drain)

	// From outside voice: dropped.
	drain = request(&test, 2, 42)
	assert(len(drain.packets) == 0, "expected a request from outside voice dropped")
	RouterVoiceTestDrain_deinit(&drain)

	// bob asks alice: relayed to her session, naming bob.
	drain = request(&test, 1, 42)
	assert(len(drain.packets) == 1, "expected one relayed request")
	entry := drain.packets[0]
	assert(
		entry.peerID == 1 && entry.packet.messageType == .ServerVoiceKeyRequest,
		"expected alice",
	)
	relayed: common.ServerVoiceKeyRequestPayload
	assert(cbor.unmarshal(entry.packet.payload, &relayed) == nil, "expected the request to decode")
	assert(
		relayed.roomId == VOICE_KEYS_TEST_ROOM && relayed.requesterId == 43,
		fmt.tprintf("expected bob's request in room 9, got %v", relayed),
	)
	RouterVoiceTestDrain_deinit(&drain)

	// Again at once: rate limited. For someone not in voice, or for himself: dropped.
	drain = request(&test, 1, 42)
	assert(len(drain.packets) == 0, "expected a second request within 10 s dropped")
	RouterVoiceTestDrain_deinit(&drain)
	drain = request(&test, 1, 44)
	assert(len(drain.packets) == 0, "expected a request for a non-participant dropped")
	RouterVoiceTestDrain_deinit(&drain)
	drain = request(&test, 1, 43)
	assert(len(drain.packets) == 0, "expected a request for oneself dropped")
	RouterVoiceTestDrain_deinit(&drain)
	// alice may still ask bob: the limit is per requester and speaker.
	drain = request(&test, 0, 43)
	assert(
		len(drain.packets) == 1 && drain.packets[0].peerID == 2,
		"expected alice's request for bob relayed",
	)
	RouterVoiceTestDrain_deinit(&drain)
}
