package client

import "../common"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:testing"

// Client tests for sender chains in encrypted rooms (protocol 19, room_chains.odin, design
// 6.3-6.6, 12.3): alice and bob share an encrypted room whose log both verified; alice's first
// message waits for her chain's distribution, bob opens it from the distribution, a stale
// epoch sends again with a new chain, a missing chain is fetched and then requested, the sender
// answers only members of that epoch, and every failure is final. The bridge records what each
// state sent; the test plays the server.

ROOM_CHAIN_TEST_SERVER :: 975
ROOM_CHAIN_TEST_ALICE :: 51
ROOM_CHAIN_TEST_BOB :: 52
ROOM_CHAIN_TEST_CAROL :: 53
ROOM_CHAIN_TEST_ROOM :: 61

roomChainSendBridgeTestMutex: sync.Mutex

// One request a state sent, with owned bytes.
@(private = "file")
RoomChainTestSent :: struct {
	request: RoomChainRequest,
	userID:  int, // The sending session's account
}

@(private = "file")
roomChainTestSent: [dynamic]RoomChainTestSent

@(private = "file")
roomChainTestBridge :: proc(transport: ^ClientServerTransport, request: RoomChainRequest) -> bool {
	if transport.serverID != ROOM_CHAIN_TEST_SERVER {
		return false
	}
	copied := request
	if len(request.bytes) > 0 {
		copied.bytes = make([]u8, len(request.bytes))
		copy(copied.bytes, request.bytes)
	}
	append(&roomChainTestSent, RoomChainTestSent{copied, transport.authenticatedUserID})
	return true
}

@(private = "file")
roomChainTestLogBridge :: proc(transport: ^ClientServerTransport, request: RoomLogRequest) -> bool {
	return transport.serverID == ROOM_CHAIN_TEST_SERVER
}

@(private = "file")
roomChainTestFetchBridge :: proc(transport: ^ClientServerTransport, userIDs: []int) -> bool {
	return transport.serverID == ROOM_CHAIN_TEST_SERVER
}

@(private = "file")
roomChainTestPublishBridge :: proc(
	transport: ^ClientServerTransport,
	bundle: common.EncryptionKeyBundle,
) -> bool {
	return transport.serverID == ROOM_CHAIN_TEST_SERVER
}

@(private = "file")
roomChainTestBegin :: proc() {
	sync.mutex_lock(&roomChainSendBridgeTestMutex)
	sync.mutex_lock(&roomLogSendBridgeTestMutex)
	sync.mutex_lock(&e2eeSendBridgeTestMutex)
	roomChainSendBridge = roomChainTestBridge
	roomLogSendBridge = roomChainTestLogBridge
	e2eeFetchBridge = roomChainTestFetchBridge
	e2eePublishBridge = roomChainTestPublishBridge
}

@(private = "file")
roomChainTestClear :: proc() {
	for sent in roomChainTestSent {
		delete(sent.request.bytes)
	}
	clear(&roomChainTestSent)
}

@(private = "file")
roomChainTestEnd :: proc() {
	roomChainTestClear()
	delete(roomChainTestSent)
	roomChainTestSent = nil
	roomChainSendBridge = ClientServerTransport_sendRoomChainRequest
	roomLogSendBridge = ClientServerTransport_sendRoomLogRequest
	e2eeFetchBridge = ClientServerTransport_fetchUserKeys
	e2eePublishBridge = ClientServerTransport_publishEncryptionKey
	sync.mutex_unlock(&e2eeSendBridgeTestMutex)
	sync.mutex_unlock(&roomLogSendBridgeTestMutex)
	sync.mutex_unlock(&roomChainSendBridgeTestMutex)
}

// The requests of kind sent so far, oldest first (borrowed).
@(private = "file")
roomChainTestOfKind :: proc(kind: RoomChainRequestKind) -> []RoomChainTestSent {
	found := make([dynamic]RoomChainTestSent, 0, 4, context.temp_allocator)
	for sent in roomChainTestSent {
		if sent.request.kind == kind {
			append(&found, sent)
		}
	}
	return found[:]
}

@(private = "file")
roomChainTestLast :: proc(kind: RoomChainRequestKind) -> RoomChainTestSent {
	found := roomChainTestOfKind(kind)
	assert(len(found) > 0, fmt.tprintf("expected a %v request", kind))
	return found[len(found) - 1]
}

@(private = "file")
roomChainTestState :: proc(serverKey: common.IdentityPublicKeyBytes, selfUserID: int) -> State {
	server := testDirectServer(ROOM_CHAIN_TEST_SERVER)
	serverHex := common.identityPublicKeyToHex(serverKey)
	defer delete(serverHex)
	fingerprintHex := common.fingerprintToHex(common.fingerprintIdentityPublicKey(serverKey))
	defer delete(fingerprintHex)
	server.pinned_server_public_key = serverHex
	server.pinned_server_fingerprint = fingerprintHex
	state := testUpdateStateForServer(server)
	delete(state.config.private_key)
	delete(state.config.public_key)
	state.config.private_key = ""
	state.config.public_key = ""
	ensureIdentityKeys(&state.config)
	ensureEncryptionKey(&state.config)
	testApplyConnectedAs(&state, ROOM_CHAIN_TEST_SERVER, selfUserID, selfUserID == ROOM_CHAIN_TEST_ALICE)
	// The worker's transport carries the account too, for the bridge.
	state.serverTransports[0].authenticatedUserID = selfUserID
	state.recordRoomChainNotes = true
	return state
}

@(private = "file")
roomChainTestBundle :: proc(state: ^State, userID: int) -> common.UserKeyBundle {
	keyPair, bundle, ok := Config_encryptionKey(state.config)
	common.EncryptionKeyPair_wipe(&keyPair)
	assert(ok, "expected the test profile to have an encryption key")
	return common.UserKeyBundle {
		userId = userID,
		identityPublicKey = bundle.identityPublicKey,
		encryptionPublicKey = bundle.encryptionPublicKey,
		createdAt = bundle.createdAt,
		signature = bundle.signature,
	}
}

@(private = "file")
roomChainTestApply :: proc(state: ^State, event: ^ClientTransportRuntimeEvent) {
	State_applyRuntimeEvent(state, event)
	ClientTransportRuntimeEvent_deinit(event)
}

@(private = "file")
roomChainTestPin :: proc(state: ^State, bundles: ..common.UserKeyBundle) {
	event := ClientTransportRuntimeEvent {
		kind     = .UserKeysReceived,
		serverID = ROOM_CHAIN_TEST_SERVER,
	}
	append(&event.userKeys, ..bundles)
	roomChainTestApply(state, &event)
}

@(private = "file")
roomChainTestName :: proc(userID: int) -> string {
	switch userID {
	case ROOM_CHAIN_TEST_ALICE:
		return "alice"
	case ROOM_CHAIN_TEST_BOB:
		return "bob"
	}
	return "carol"
}

@(private = "file")
roomChainTestListRoom :: proc(state: ^State, logVersion: int) {
	event := ClientTransportRuntimeEvent {
		kind     = .RoomListReceived,
		serverID = ROOM_CHAIN_TEST_SERVER,
	}
	append(
		&event.rooms,
		common.RoomSummary {
			id = ROOM_CHAIN_TEST_ROOM,
			name = strings.clone("secret"),
			description = strings.clone(""),
			roomType = .ChatAndVoice,
			access = .AdminInvite,
			historyVisibility = .FromJoin,
			encrypted = true,
			logVersion = logVersion,
		},
	)
	roomChainTestApply(state, &event)
}

@(private = "file")
roomChainTestDeliverLog :: proc(state: ^State, afterVersion, headVersion: int, entries: ..[]u8) {
	event := ClientTransportRuntimeEvent {
		kind            = .RoomLogReceived,
		serverID        = ROOM_CHAIN_TEST_SERVER,
		roomID          = ROOM_CHAIN_TEST_ROOM,
		logAfterVersion = afterVersion,
		logHeadVersion  = headVersion,
	}
	for entry in entries {
		copied := make([]u8, len(entry))
		copy(copied, entry)
		append(&event.logEntries, copied)
	}
	roomChainTestApply(state, &event)
}

// A member log signed by alice: Create (alice joins and manages), then Add for each of adds.
// The entries are in the temp allocator.
@(private = "file")
roomChainTestLog :: proc(
	serverKey: common.IdentityPublicKeyBytes,
	alice: ^State,
	adds: []^State,
	addIDs: []int,
) -> [][]u8 {
	privateKey, _ := common.identityPrivateKeyFromHex(alice.config.private_key)
	alicePublic, _ := common.identityPublicKeyFromHex(alice.config.public_key)
	entries := make([dynamic][]u8, 0, 1 + len(adds), context.temp_allocator)
	prevHash: common.RoomLogHash
	for version in 1 ..= 1 + len(adds) {
		entry := common.RoomLogEntry {
			roomID      = ROOM_CHAIN_TEST_ROOM,
			version     = version,
			prevHash    = prevHash,
			actorUserID = ROOM_CHAIN_TEST_ALICE,
			createdAt   = 1_731_600_000 + u64(version),
		}
		managers := [1]common.RoomLogManager{{ROOM_CHAIN_TEST_ALICE, alicePublic}}
		if version == 1 {
			entry.action = .Create
			entry.targetUserID = ROOM_CHAIN_TEST_ALICE
			entry.targetIdentityKey = alicePublic
			entry.settings = {
				access            = .AdminInvite,
				historyVisibility = .FromJoin,
				creatorJoins      = true,
				managers          = managers[:],
			}
		} else {
			target := adds[version - 2]
			targetKey, _ := common.identityPublicKeyFromHex(target.config.public_key)
			entry.action = .Add
			entry.targetUserID = addIDs[version - 2]
			entry.targetIdentityKey = targetKey
		}
		assert(
			common.signRoomLogEntry(&entry, serverKey, privateKey) == .None,
			"expected the log entry to sign",
		)
		buffer: [common.ROOM_LOG_ENTRY_MAX_BYTES]u8
		n, err := common.encodeRoomLogEntry(entry, buffer[:])
		assert(err == .None, "expected the log entry to encode")
		data := make([]u8, n, context.temp_allocator)
		copy(data, buffer[:n])
		append(&entries, data)
		prevHash = common.hashRoomLogEntry(data)
	}
	return entries[:]
}

// alice and bob, pinned to each other, both verifying the room's log at version 2 (alice
// created it, bob added).
@(private = "file")
RoomChainTestPair :: struct {
	serverKey: common.IdentityPublicKeyBytes,
	alice:     State,
	bob:       State,
	log:       [][]u8,
}

@(private = "file")
roomChainTestPair :: proc() -> (pair: RoomChainTestPair) {
	_, pair.serverKey, _ = common.generateIdentityKeyPair()
	pair.alice = roomChainTestState(pair.serverKey, ROOM_CHAIN_TEST_ALICE)
	pair.bob = roomChainTestState(pair.serverKey, ROOM_CHAIN_TEST_BOB)
	roomChainTestPin(&pair.alice, roomChainTestBundle(&pair.bob, ROOM_CHAIN_TEST_BOB))
	roomChainTestPin(&pair.bob, roomChainTestBundle(&pair.alice, ROOM_CHAIN_TEST_ALICE))
	adds := [1]^State{&pair.bob}
	pair.log = roomChainTestLog(pair.serverKey, &pair.alice, adds[:], {ROOM_CHAIN_TEST_BOB})
	for state in ([]^State{&pair.alice, &pair.bob}) {
		roomChainTestListRoom(state, 2)
		roomChainTestDeliverLog(state, 0, 2, ..pair.log)
		assert(
			State_roomLogEpoch(state, ROOM_CHAIN_TEST_SERVER, ROOM_CHAIN_TEST_ROOM) == 2,
			"expected the log verified at epoch 2",
		)
	}
	return
}

@(private = "file")
roomChainTestPairDeinit :: proc(pair: ^RoomChainTestPair) {
	State_deinit(&pair.alice)
	State_deinit(&pair.bob)
}

// The server's ServerRoomKeyEnvelope of sent (a KeyEnvelope request) to state.
@(private = "file")
roomChainTestDeliverEnvelope :: proc(state: ^State, sent: RoomChainTestSent, id: int) {
	event := ClientTransportRuntimeEvent {
		kind     = .RoomKeyEnvelopeReceived,
		serverID = ROOM_CHAIN_TEST_SERVER,
		roomID   = sent.request.roomID,
	}
	envelope := make([]u8, len(sent.request.bytes))
	copy(envelope, sent.request.bytes)
	append(
		&event.roomKeyEnvelopes,
		common.RoomKeyEnvelope {
			id = id,
			roomId = sent.request.roomID,
			epoch = sent.request.epoch,
			senderId = sent.userID,
			chainId = sent.request.chainID,
			envelope = envelope,
		},
	)
	roomChainTestApply(state, &event)
}

// The server's ServerChatMessage of sent (a SealedMessage request) to state.
@(private = "file")
roomChainTestDeliverMessage :: proc(
	state: ^State,
	sent: RoomChainTestSent,
	id: int,
	timestamp := "2024-11-14 16:00:05+00",
) {
	sealed := make([]u8, len(sent.request.bytes))
	copy(sealed, sent.request.bytes)
	event := ClientTransportRuntimeEvent {
		kind            = .RoomChatReceived,
		serverID        = ROOM_CHAIN_TEST_SERVER,
		roomID          = sent.request.roomID,
		senderID        = sent.userID,
		senderNickname  = strings.clone(roomChainTestName(sent.userID)),
		messageID       = id,
		timestamp       = strings.clone(timestamp),
		message         = strings.clone(""),
		clientMessageID = sent.request.clientMessageID,
		sealed          = sealed,
	}
	roomChainTestApply(state, &event)
}

@(private = "file")
roomChainTestEntry :: proc(state: ^State, messageID: int) -> ^RoomMessageEntry {
	cache := State_serverRoomCache(state, ROOM_CHAIN_TEST_SERVER)
	roomCache := ServerRoomCache_roomCache(cache, ROOM_CHAIN_TEST_ROOM)
	for &entry in roomCache.messages {
		if entry.id == messageID {
			return &entry
		}
	}
	return nil
}

@(private = "file")
roomChainTestSend :: proc(state: ^State, text: string) {
	state.selected_server_id = ROOM_CHAIN_TEST_SERVER
	state.selected_transport_index = 0
	state.selected_channel_id = ROOM_CHAIN_TEST_ROOM
	draft := State_selectedRoomDraft(state)
	clear(draft)
	append(draft, ..transmute([]u8)text)
	State_sendChannelChat(state)
}

@(test)
testRoomChainsFirstMessageWaitsForItsDistributionThenOpens :: proc(t: ^testing.T) {
	roomChainTestBegin()
	defer roomChainTestEnd()
	defer free_all(context.temp_allocator)
	pair := roomChainTestPair()
	defer roomChainTestPairDeinit(&pair)
	alice, bob := &pair.alice, &pair.bob

	// The first send starts a chain and distributes it; the message waits.
	roomChainTestSend(alice, "hello room")
	assert(
		len(State_selectedRoomDraft(alice)) == 0 &&
		alice.chat_status_message == DIRECT_SETTING_UP_TEXT,
		"expected the draft cleared and the message waiting for encryption",
	)
	assert(len(roomChainTestOfKind(.SealedMessage)) == 0, "expected no message before the key")
	distribution := roomChainTestLast(.KeyEnvelope)
	assert(
		distribution.request.roomID == ROOM_CHAIN_TEST_ROOM && distribution.request.epoch == 2,
		"expected the distribution for epoch 2",
	)
	decoded, decodeErr := common.decodeSealedEnvelope(distribution.request.bytes)
	assert(
		decodeErr == .None &&
		decoded.kind == .SenderKey &&
		decoded.wrapCount == 2 &&
		common.SealedEnvelope_wrap(decoded, 0).recipientUserID == ROOM_CHAIN_TEST_ALICE &&
		common.SealedEnvelope_wrap(decoded, 1).recipientUserID == ROOM_CHAIN_TEST_BOB,
		"expected one SenderKey envelope with a wrap for each member, the sender included",
	)

	// The server's echo lets the message go out, sealed under index 0.
	roomChainTestDeliverEnvelope(alice, distribution, 1)
	message := roomChainTestLast(.SealedMessage)
	sealed, sealedErr := common.decodeSealedRoomMessage(message.request.bytes)
	assert(
		sealedErr == .None &&
		sealed.header.epoch == 2 &&
		sealed.header.index == 0 &&
		sealed.header.chainID == distribution.request.chainID,
		fmt.tprintf("expected index 0 of the distributed chain, got %v", sealed.header),
	)
	assert(alice.chat_status_message == "", "expected the setting-up status cleared")

	// bob takes the distribution and opens the message; alice reads her own from her store.
	roomChainTestDeliverEnvelope(bob, distribution, 1)
	assert(
		KeyStore_roomChainCount(bob.e2ee[0].store, ROOM_CHAIN_TEST_ROOM) == 1,
		"expected bob to hold alice's chain",
	)
	for state in ([]^State{alice, bob}) {
		roomChainTestDeliverMessage(state, message, 100)
		entry := roomChainTestEntry(state, 100)
		assert(
			entry != nil &&
			entry.security.protection == .Encrypted &&
			entry.content == "hello room",
			fmt.tprintf("expected the message opened, got %v", entry^),
		)
	}
	room := State_roomChainRoom(alice, ROOM_CHAIN_TEST_SERVER, ROOM_CHAIN_TEST_ROOM)
	assert(len(room.inFlight) == 0 && len(room.queued) == 0, "expected the echo to settle it")

	// The view shows a lock, and the second message uses the next index of the same chain.
	bob.selected_server_id = ROOM_CHAIN_TEST_SERVER
	bob.selected_channel_id = ROOM_CHAIN_TEST_ROOM
	view := buildRoomView(bob)
	found := false
	for line in view.lines {
		if line.messageID == 100 {
			found = line.badge == "🔒" && line.content == "hello room" && !line.placeholder
		}
	}
	assert(found && view.encrypted && view.allowsChat, "expected the opened line with a lock")
	roomChainTestSend(alice, "second")
	next := roomChainTestLast(.SealedMessage)
	nextSealed, _ := common.decodeSealedRoomMessage(next.request.bytes)
	assert(
		nextSealed.header.index == 1 &&
		nextSealed.header.chainID == distribution.request.chainID &&
		len(roomChainTestOfKind(.KeyEnvelope)) == 1,
		"expected index 1 of the same chain, without a new distribution",
	)

	// A copy of the first message under another ID is a replay.
	roomChainTestDeliverMessage(bob, message, 101)
	replayed := roomChainTestEntry(bob, 101)
	assert(
		replayed.security.protection == .Failed && replayed.security.failure == .Replayed,
		"expected the copy marked as a replay",
	)
	assert(roomChainTestEntry(bob, 100).content == "hello room", "expected the original kept")
}

@(test)
testRoomChainsNewRunNeverReusesAnIndex :: proc(t: ^testing.T) {
	roomChainTestBegin()
	defer roomChainTestEnd()
	defer free_all(context.temp_allocator)
	pair := roomChainTestPair()
	defer roomChainTestPairDeinit(&pair)
	alice := &pair.alice

	roomChainTestSend(alice, "first run")
	first := roomChainTestLast(.KeyEnvelope)
	roomChainTestDeliverEnvelope(alice, first, 1)
	firstMessage := roomChainTestLast(.SealedMessage)

	// A second state on the same profile (a restart, or a copy of the profile) keeps the stored
	// chain for reading but starts its own chain to send.
	again := roomChainTestState(pair.serverKey, ROOM_CHAIN_TEST_ALICE)
	defer State_deinit(&again)
	Config_deinit(&again.config)
	again.config = Config_clone(alice.config)
	e2ee, _ := State_e2eeEnsureStore(&again, ROOM_CHAIN_TEST_SERVER)
	for chain in alice.e2ee[0].store.roomChains {
		KeyStore_addRoomChain(&e2ee.store, chain)
	}
	roomChainTestPin(&again, roomChainTestBundle(&pair.bob, ROOM_CHAIN_TEST_BOB))
	roomChainTestListRoom(&again, 2)
	roomChainTestDeliverLog(&again, 0, 2, ..pair.log)
	roomChainTestSend(&again, "second run")
	second := roomChainTestLast(.KeyEnvelope)
	assert(
		second.request.chainID != first.request.chainID,
		"expected a new chain in the new run",
	)
	roomChainTestDeliverEnvelope(&again, second, 2)
	secondMessage := roomChainTestLast(.SealedMessage)
	a, _ := common.decodeSealedRoomMessage(firstMessage.request.bytes)
	b, _ := common.decodeSealedRoomMessage(secondMessage.request.bytes)
	assert(
		a.header.chainID != b.header.chainID,
		"expected two runs never to seal under one chain and index",
	)
	// The new run still opens the first run's message from the stored chain.
	roomChainTestDeliverMessage(&again, firstMessage, 200)
	assert(
		roomChainTestEntry(&again, 200).content == "first run",
		"expected the stored chain to open the earlier run's message",
	)
}

@(test)
testRoomChainsStaleEpochSendsAgainWithANewChain :: proc(t: ^testing.T) {
	roomChainTestBegin()
	defer roomChainTestEnd()
	defer free_all(context.temp_allocator)
	pair := roomChainTestPair()
	defer roomChainTestPairDeinit(&pair)
	alice := &pair.alice
	carol := roomChainTestState(pair.serverKey, ROOM_CHAIN_TEST_CAROL)
	defer State_deinit(&carol)
	roomChainTestPin(alice, roomChainTestBundle(&carol, ROOM_CHAIN_TEST_CAROL))

	roomChainTestSend(alice, "before")
	first := roomChainTestLast(.KeyEnvelope)
	roomChainTestDeliverEnvelope(alice, first, 1)
	roomChainTestSend(alice, "after the add")
	assert(len(roomChainTestOfKind(.SealedMessage)) == 2, "expected both messages sent")

	// The server moved to epoch 3 (carol added) before the second arrived.
	refusal := ClientTransportRuntimeEvent {
		kind     = .ProtocolError,
		serverID = ROOM_CHAIN_TEST_SERVER,
		message  = strings.clone(common.ROOM_KEY_OUT_OF_DATE_MESSAGE),
	}
	roomChainTestApply(alice, &refusal)
	room := State_roomChainRoom(alice, ROOM_CHAIN_TEST_SERVER, ROOM_CHAIN_TEST_ROOM)
	assert(
		len(room.queued) == 2 && room.queued[1] == "after the add" && !room.hasSending,
		"expected the messages in flight queued again in order, the chain dropped",
	)
	adds := [2]^State{&pair.bob, &carol}
	log := roomChainTestLog(
		pair.serverKey,
		alice,
		adds[:],
		{ROOM_CHAIN_TEST_BOB, ROOM_CHAIN_TEST_CAROL},
	)
	roomChainTestDeliverLog(alice, 2, 3, log[2])
	assert(
		State_roomLogEpoch(alice, ROOM_CHAIN_TEST_SERVER, ROOM_CHAIN_TEST_ROOM) == 3,
		"expected alice at epoch 3",
	)
	second := roomChainTestLast(.KeyEnvelope)
	decoded, _ := common.decodeSealedEnvelope(second.request.bytes)
	assert(
		second.request.epoch == 3 &&
		second.request.chainID != first.request.chainID &&
		decoded.wrapCount == 3,
		"expected a new chain in epoch 3 sealed to all three members",
	)
	roomChainTestDeliverEnvelope(alice, second, 2)
	resent := roomChainTestOfKind(.SealedMessage)
	assert(len(resent) == 4, fmt.tprintf("expected both sent again, got %d", len(resent)))
	header, _ := common.decodeSealedRoomMessage(resent[3].request.bytes)
	assert(header.header.epoch == 3 && header.header.index == 1, "expected epoch 3 index 1")
}

@(test)
testRoomChainsMissingKeyIsFetchedThenRequestedAndAnsweredForMembersOnly :: proc(t: ^testing.T) {
	roomChainTestBegin()
	defer roomChainTestEnd()
	defer free_all(context.temp_allocator)
	pair := roomChainTestPair()
	defer roomChainTestPairDeinit(&pair)
	alice, bob := &pair.alice, &pair.bob

	roomChainTestSend(alice, "for bob")
	distribution := roomChainTestLast(.KeyEnvelope)
	roomChainTestDeliverEnvelope(alice, distribution, 1)
	message := roomChainTestLast(.SealedMessage)

	// bob never saw the distribution: the message waits, and he fetches the room's envelopes.
	roomChainTestDeliverMessage(bob, message, 300)
	entry := roomChainTestEntry(bob, 300)
	assert(
		entry.security.protection == .Pending && entry.security.wait == .Key,
		"expected the message waiting for its key",
	)
	text, placeholder, _ := roomMessageDisplay(bob, ROOM_CHAIN_TEST_SERVER, entry^)
	assert(
		placeholder && text == "Waiting for this message's key from alice",
		fmt.tprintf("expected the waiting text, got %q", text),
	)
	fetches := roomChainTestOfKind(.FetchKeys)
	assert(len(fetches) == 1 && fetches[0].userID == ROOM_CHAIN_TEST_BOB, "expected bob's fetch")
	page := ClientTransportRuntimeEvent {
		kind     = .RoomKeysReceived,
		serverID = ROOM_CHAIN_TEST_SERVER,
		roomID   = ROOM_CHAIN_TEST_ROOM,
	}
	roomChainTestApply(bob, &page)

	// Nothing for him there: he asks alice.
	request := roomChainTestLast(.RequestKey)
	assert(
		request.userID == ROOM_CHAIN_TEST_BOB &&
		request.request.senderUserID == ROOM_CHAIN_TEST_ALICE &&
		request.request.epoch == 2 &&
		request.request.chainID == distribution.request.chainID,
		"expected bob to request alice's chain",
	)
	asked := ClientTransportRuntimeEvent {
		kind           = .RoomKeyRequested,
		serverID       = ROOM_CHAIN_TEST_SERVER,
		roomID         = ROOM_CHAIN_TEST_ROOM,
		roomKeyEpoch   = 2,
		roomKeyChainID = distribution.request.chainID,
		peerUserID     = ROOM_CHAIN_TEST_BOB,
	}
	roomChainTestApply(alice, &asked)
	answer := roomChainTestLast(.KeyEnvelope)
	decoded, _ := common.decodeSealedEnvelope(answer.request.bytes)
	assert(
		answer.userID == ROOM_CHAIN_TEST_ALICE &&
		answer.request.epoch == 2 &&
		answer.request.chainID == distribution.request.chainID &&
		decoded.wrapCount == 1 &&
		common.SealedEnvelope_wrap(decoded, 0).recipientUserID == ROOM_CHAIN_TEST_BOB,
		"expected alice to re-seal her chain for bob only",
	)
	roomChainTestDeliverEnvelope(bob, answer, 2)
	assert(
		roomChainTestEntry(bob, 300).content == "for bob",
		"expected bob's message to open with the answer",
	)

	// carol is not a member of epoch 2 in alice's log: no answer, whatever the server says.
	carol := roomChainTestState(pair.serverKey, ROOM_CHAIN_TEST_CAROL)
	defer State_deinit(&carol)
	roomChainTestPin(alice, roomChainTestBundle(&carol, ROOM_CHAIN_TEST_CAROL))
	envelopesBefore := len(roomChainTestOfKind(.KeyEnvelope))
	outsider := ClientTransportRuntimeEvent {
		kind           = .RoomKeyRequested,
		serverID       = ROOM_CHAIN_TEST_SERVER,
		roomID         = ROOM_CHAIN_TEST_ROOM,
		roomKeyEpoch   = 2,
		roomKeyChainID = distribution.request.chainID,
		peerUserID     = ROOM_CHAIN_TEST_CAROL,
	}
	roomChainTestApply(alice, &outsider)
	assert(
		len(roomChainTestOfKind(.KeyEnvelope)) == envelopesBefore,
		"expected no envelope for someone who was not a member of that epoch",
	)
}

@(test)
testRoomChainsFailuresAreFinal :: proc(t: ^testing.T) {
	roomChainTestBegin()
	defer roomChainTestEnd()
	defer free_all(context.temp_allocator)
	pair := roomChainTestPair()
	defer roomChainTestPairDeinit(&pair)
	alice, bob := &pair.alice, &pair.bob

	roomChainTestSend(alice, "genuine")
	distribution := roomChainTestLast(.KeyEnvelope)
	roomChainTestDeliverEnvelope(alice, distribution, 1)
	roomChainTestDeliverEnvelope(bob, distribution, 1)
	message := roomChainTestLast(.SealedMessage)

	// A flipped byte in the body fails the signature for good.
	tampered := message
	tampered.request.bytes = make([]u8, len(message.request.bytes), context.temp_allocator)
	copy(tampered.request.bytes, message.request.bytes)
	tampered.request.bytes[80] ~= 1
	roomChainTestDeliverMessage(bob, tampered, 400)
	failed := roomChainTestEntry(bob, 400)
	assert(
		failed.security.protection == .Failed &&
		failed.security.failure == .Sealed &&
		failed.security.sealedError == .BadSignature,
		fmt.tprintf("expected a bad signature, got %v", failed.security),
	)
	text, placeholder, _ := roomMessageDisplay(bob, ROOM_CHAIN_TEST_SERVER, failed^)
	assert(placeholder && text == DIRECT_UNDECRYPTABLE_TEXT, "expected the failure shown")

	// The same bytes under bob's name: signed by alice, so they do not verify as his.
	asBob := message
	asBob.userID = ROOM_CHAIN_TEST_BOB
	roomChainTestDeliverMessage(alice, asBob, 401)
	assert(
		roomChainTestEntry(alice, 401).security.protection != .Encrypted,
		"expected a message moved to another sender to stay closed",
	)

	// Plaintext in an encrypted room is never shown as a message.
	plain := ClientTransportRuntimeEvent {
		kind           = .RoomChatReceived,
		serverID       = ROOM_CHAIN_TEST_SERVER,
		roomID         = ROOM_CHAIN_TEST_ROOM,
		senderID       = ROOM_CHAIN_TEST_ALICE,
		senderNickname = strings.clone("alice"),
		messageID      = 402,
		timestamp      = strings.clone("2024-11-14 16:00:00+00"),
		message        = strings.clone("readable by the server"),
	}
	roomChainTestApply(bob, &plain)
	notSealed := roomChainTestEntry(bob, 402)
	assert(
		notSealed.security.failure == .NotSealed && notSealed.content == "",
		"expected plaintext in an encrypted room refused",
	)

	// Reopening never changes a failure.
	State_roomChainsReopenPending(bob, ROOM_CHAIN_TEST_SERVER, ROOM_CHAIN_TEST_ROOM)
	assert(roomChainTestEntry(bob, 400).security.protection == .Failed, "expected it final")
}

@(test)
testKeyStoreKeepsRoomChains :: proc(t: ^testing.T) {
	_, serverKey, _ := common.generateIdentityKeyPair()
	store := KeyStore {
		loaded          = true,
		serverPublicKey = serverKey,
		writable        = true,
	}
	defer KeyStore_deinit(&store)
	chain := KeyStoreRoomChain {
		roomID       = 5,
		epoch        = 3,
		senderUserID = 2,
		startIndex   = 0,
	}
	chain.chainID[0] = 1
	chain.chainKey[0] = 7
	assert(KeyStore_addRoomChain(&store, chain), "expected the chain added")
	assert(!KeyStore_addRoomChain(&store, chain), "expected a second copy refused")
	bad := chain
	bad.epoch = 0
	assert(!KeyStore_addRoomChain(&store, bad), "expected epoch 0 refused")

	data, ok := keyStoreEncode(store)
	assert(ok, "expected the store to encode")
	defer delete(data)
	assert(strings.contains(string(data), `"format": 4`), "expected format 4")
	parsed := keyStoreParse(data, serverKey)
	defer KeyStore_deinit(&parsed)
	got, found := KeyStore_roomChain(&parsed, 5, 3, 2, chain.chainID)
	assert(
		parsed.writable && found && got.chainKey == chain.chainKey && got.startIndex == 0,
		"expected the chain back after a round trip",
	)

	// A damaged chain entry makes the store read-only, so it is never written over.
	damaged, _ := strings.replace(string(data), `"start_index": 0`, `"start_index": 5000`, 1)
	defer delete(damaged)
	broken := keyStoreParse(transmute([]u8)damaged, serverKey)
	defer KeyStore_deinit(&broken)
	assert(!broken.writable, "expected a damaged chain entry to make the store read-only")
}

@(test)
testServerTimestampsParseToUnixSeconds :: proc(t: ^testing.T) {
	cases := [?]struct {
		text:    string,
		seconds: i64,
		ok:      bool,
	} {
		{"1970-01-01 00:00:00+00", 0, true},
		{"2024-11-14 16:00:00.123456+00", 1731600000, true},
		{"2024-11-14 10:00:00-06", 1731600000, true},
		{"2024-11-14 21:30:00+05:30", 1731600000, true},
		{"2024-11-14T16:00:00Z", 0, false},
		{"not a time", 0, false},
	}
	for c in cases {
		seconds, ok := parseServerTimestampUnix(c.text)
		assert(
			ok == c.ok && (!ok || seconds == c.seconds),
			fmt.tprintf("expected %q to parse to %d (%v), got %d (%v)", c.text, c.seconds, c.ok,
				seconds, ok),
		)
	}
}
