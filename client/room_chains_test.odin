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
// answers only members of that epoch, and every failure is final. Protocol 20 (Full history,
// design 6.6): the inviter forwards what it holds, other members answer key requests, a
// forward is checked against the forwarder and the log, and From join rooms never forward.
// The bridge records what each state sent; the test plays the server.

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
roomChainTestListRoom :: proc(
	state: ^State,
	logVersion: int,
	history := common.RoomHistoryVisibility.FromJoin,
) {
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
			historyVisibility = history,
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
	history := common.RoomLogHistoryVisibility.FromJoin,
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
				historyVisibility = history,
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

// The server's ServerRoomKeyEnvelope of sent (a KeyEnvelope request) to state. A forward
// (senderUserID set) is stored with the sending session as its forwarder.
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
			senderId = sent.request.senderUserID > 0 ? sent.request.senderUserID : sent.userID,
			chainId = sent.request.chainID,
			envelope = envelope,
			forwarderId = sent.request.senderUserID > 0 ? sent.userID : 0,
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
		senderID       = ROOM_CHAIN_TEST_ALICE,
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
		senderID       = ROOM_CHAIN_TEST_ALICE,
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

	// A flipped byte in the body fails the signature for good: nobody is known to have sent
	// it, so it is not shown at all (#90).
	tampered := message
	tampered.request.bytes = make([]u8, len(message.request.bytes), context.temp_allocator)
	copy(tampered.request.bytes, message.request.bytes)
	tampered.request.bytes[80] ~= 1
	roomChainTestDeliverMessage(bob, tampered, 400)
	failed := roomChainTestEntry(bob, 400)
	assert(
		failed.security.protection == .Hidden &&
		failed.security.failure == .Sealed &&
		failed.security.sealedError == .BadSignature &&
		!roomMessageShown(failed.security),
		fmt.tprintf("expected a bad signature hidden, got %v", failed.security),
	)
	State_switchToChannel(bob, ROOM_CHAIN_TEST_SERVER, ROOM_CHAIN_TEST_ROOM)
	for line in buildRoomView(bob).lines {
		assert(line.messageID != 400, "expected the hidden message left out of the transcript")
	}

	// The same bytes under bob's name: signed by alice, so they do not verify as his.
	asBob := message
	asBob.userID = ROOM_CHAIN_TEST_BOB
	roomChainTestDeliverMessage(alice, asBob, 401)
	assert(
		roomChainTestEntry(alice, 401).security.protection == .Hidden,
		"expected a message moved to another sender hidden",
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
		notSealed.security.protection == .Hidden &&
		notSealed.security.failure == .NotSealed &&
		notSealed.content == "",
		"expected plaintext in an encrypted room hidden",
	)

	// Reopening never changes a refusal.
	State_roomChainsReopenPending(bob, ROOM_CHAIN_TEST_SERVER, ROOM_CHAIN_TEST_ROOM)
	assert(roomChainTestEntry(bob, 400).security.protection == .Hidden, "expected it final")
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

// ── Full history (protocol 20, design 6.6) ───────────────────────

ROOM_CHAIN_TEST_DAVE :: 54

// alice, bob and carol, pinned to each other. The log (signed by alice) creates the room with
// history, adds bob (epoch 2) and carol (epoch 3); alice and bob verified it up to epoch 2 and
// both hold alice's chain (alpha, "alice before carol") and bob's (beta, "bob before carol").
@(private = "file")
RoomChainTestTrio :: struct {
	serverKey: common.IdentityPublicKeyBytes,
	history:   common.RoomHistoryVisibility,
	alice:     State,
	bob:       State,
	carol:     State,
	log:       [][]u8,
	alpha:     RoomChainTestSent,
	beta:      RoomChainTestSent,
	fromAlice: RoomChainTestSent,
	fromBob:   RoomChainTestSent,
}

@(private = "file")
roomChainTestTrio :: proc(history: common.RoomHistoryVisibility) -> (trio: RoomChainTestTrio) {
	_, trio.serverKey, _ = common.generateIdentityKeyPair()
	trio.history = history
	trio.alice = roomChainTestState(trio.serverKey, ROOM_CHAIN_TEST_ALICE)
	trio.bob = roomChainTestState(trio.serverKey, ROOM_CHAIN_TEST_BOB)
	trio.carol = roomChainTestState(trio.serverKey, ROOM_CHAIN_TEST_CAROL)
	aliceBundle := roomChainTestBundle(&trio.alice, ROOM_CHAIN_TEST_ALICE)
	bobBundle := roomChainTestBundle(&trio.bob, ROOM_CHAIN_TEST_BOB)
	carolBundle := roomChainTestBundle(&trio.carol, ROOM_CHAIN_TEST_CAROL)
	roomChainTestPin(&trio.alice, bobBundle, carolBundle)
	roomChainTestPin(&trio.bob, aliceBundle, carolBundle)
	roomChainTestPin(&trio.carol, aliceBundle, bobBundle)
	adds := [2]^State{&trio.bob, &trio.carol}
	trio.log = roomChainTestLog(
		trio.serverKey,
		&trio.alice,
		adds[:],
		{ROOM_CHAIN_TEST_BOB, ROOM_CHAIN_TEST_CAROL},
		common.RoomLogHistoryVisibility(u8(history)),
	)
	for state in ([]^State{&trio.alice, &trio.bob}) {
		roomChainTestListRoom(state, 2, history)
		roomChainTestDeliverLog(state, 0, 2, ..trio.log[:2])
	}
	roomChainTestSend(&trio.alice, "alice before carol")
	trio.alpha = roomChainTestLast(.KeyEnvelope)
	roomChainTestDeliverEnvelope(&trio.alice, trio.alpha, 1)
	roomChainTestDeliverEnvelope(&trio.bob, trio.alpha, 1)
	trio.fromAlice = roomChainTestLast(.SealedMessage)
	roomChainTestSend(&trio.bob, "bob before carol")
	trio.beta = roomChainTestLast(.KeyEnvelope)
	roomChainTestDeliverEnvelope(&trio.bob, trio.beta, 2)
	roomChainTestDeliverEnvelope(&trio.alice, trio.beta, 2)
	trio.fromBob = roomChainTestLast(.SealedMessage)
	assert(
		trio.alpha.userID == ROOM_CHAIN_TEST_ALICE && trio.beta.userID == ROOM_CHAIN_TEST_BOB,
		"expected one distribution from each",
	)
	assert(
		KeyStore_roomChainCount(trio.alice.e2ee[0].store, ROOM_CHAIN_TEST_ROOM) == 2,
		"expected alice to hold both chains",
	)
	return
}

@(private = "file")
roomChainTestTrioDeinit :: proc(trio: ^RoomChainTestTrio) {
	State_deinit(&trio.alice)
	State_deinit(&trio.bob)
	State_deinit(&trio.carol)
}

// carol verifies the whole log, her own addition included.
@(private = "file")
roomChainTestCarolJoins :: proc(trio: ^RoomChainTestTrio) {
	roomChainTestListRoom(&trio.carol, 3, trio.history)
	roomChainTestDeliverLog(&trio.carol, 0, 3, ..trio.log)
	assert(
		State_roomLogEpoch(&trio.carol, ROOM_CHAIN_TEST_SERVER, ROOM_CHAIN_TEST_ROOM) == 3,
		"expected carol to verify the log at epoch 3",
	)
}

// A RoomKeyForward of (epoch, senderID's chain chainID from startIndex at chainKey) signed by
// signer and sent by forwarderID's session, sealed to recipient (borrowed until the next clear).
@(private = "file")
roomChainTestForge :: proc(
	serverKey: common.IdentityPublicKeyBytes,
	signer: ^State,
	forwarderID, epoch, senderID: int,
	chainID: common.ChainID,
	startIndex: u32,
	chainKey: common.ChainKey,
	recipient: ^State,
	recipientID: int,
) -> RoomChainTestSent {
	privateKey, _ := common.identityPrivateKeyFromHex(signer.config.private_key)
	bundle := roomChainTestBundle(recipient, recipientID)
	buffer: [common.SEALED_ENVELOPE_MAX_BYTES]u8
	n, err := common.sealRoomKeyForward(
		common.RoomKeyForwardAADFields {
			serverIdentityPublicKey = serverKey,
			roomID = ROOM_CHAIN_TEST_ROOM,
			epoch = epoch,
			senderUserID = senderID,
			chainID = chainID,
			forwarderUserID = forwarderID,
			recipientUserID = recipientID,
		},
		startIndex,
		chainKey,
		bundle.encryptionPublicKey,
		privateKey,
		buffer[:],
	)
	assert(err == .None, fmt.tprintf("expected the forged forward to seal, got %v", err))
	bytes := make([]u8, n, context.temp_allocator)
	copy(bytes, buffer[:n])
	return RoomChainTestSent {
		request = {
			kind = .KeyEnvelope,
			roomID = ROOM_CHAIN_TEST_ROOM,
			epoch = epoch,
			senderUserID = senderID,
			chainID = chainID,
			bytes = bytes,
		},
		userID = forwarderID,
	}
}

// The last note of kind in state (nil when none).
@(private = "file")
roomChainTestLastNote :: proc(state: ^State, kind: RoomChainNoteKind) -> ^RoomChainNote {
	for index := len(state.roomChainNotes) - 1; index >= 0; index -= 1 {
		if state.roomChainNotes[index].kind == kind {
			return &state.roomChainNotes[index]
		}
	}
	return nil
}

@(private = "file")
roomChainTestAsk :: proc(
	state: ^State,
	senderID, requesterID: int,
	chainID: common.ChainID,
	epoch := 2,
) {
	asked := ClientTransportRuntimeEvent {
		kind           = .RoomKeyRequested,
		serverID       = ROOM_CHAIN_TEST_SERVER,
		roomID         = ROOM_CHAIN_TEST_ROOM,
		roomKeyEpoch   = epoch,
		roomKeyChainID = chainID,
		peerUserID     = requesterID,
		senderID       = senderID,
	}
	roomChainTestApply(state, &asked)
}

@(test)
testRoomChainsFullHistoryInviterForwardsWhatItHolds :: proc(t: ^testing.T) {
	roomChainTestBegin()
	defer roomChainTestEnd()
	defer free_all(context.temp_allocator)
	trio := roomChainTestTrio(.Full)
	defer roomChainTestTrioDeinit(&trio)
	alice, bob, carol := &trio.alice, &trio.bob, &trio.carol

	// alice's Add of carol verifies: she seals both chains to carol, her own as a SenderKey
	// re-seal and bob's as a RoomKeyForward, each with carol's wrap only.
	before := len(roomChainTestOfKind(.KeyEnvelope))
	roomChainTestDeliverLog(alice, 2, 3, trio.log[2])
	forwards := roomChainTestOfKind(.KeyEnvelope)[before:]
	assert(len(forwards) == 2, fmt.tprintf("expected two chains forwarded, got %d", len(forwards)))
	own, _ := common.decodeSealedEnvelope(forwards[0].request.bytes)
	other, _ := common.decodeSealedEnvelope(forwards[1].request.bytes)
	assert(
		forwards[0].userID == ROOM_CHAIN_TEST_ALICE &&
		forwards[0].request.senderUserID == 0 &&
		forwards[0].request.chainID == trio.alpha.request.chainID &&
		forwards[0].request.epoch == 2 &&
		own.kind == .SenderKey &&
		own.wrapCount == 1 &&
		common.SealedEnvelope_wrap(own, 0).recipientUserID == ROOM_CHAIN_TEST_CAROL,
		"expected alice's own chain re-sealed to carol as a SenderKey envelope",
	)
	assert(
		forwards[1].userID == ROOM_CHAIN_TEST_ALICE &&
		forwards[1].request.senderUserID == ROOM_CHAIN_TEST_BOB &&
		forwards[1].request.chainID == trio.beta.request.chainID &&
		other.kind == .RoomKeyForward &&
		other.wrapCount == 1 &&
		common.SealedEnvelope_wrap(other, 0).recipientUserID == ROOM_CHAIN_TEST_CAROL,
		"expected bob's chain forwarded to carol as a RoomKeyForward",
	)
	note := roomChainTestLastNote(alice, .Answered)
	assert(
		note != nil &&
		note.outcome == .Stored &&
		note.peerID == ROOM_CHAIN_TEST_CAROL &&
		note.forwarderID == ROOM_CHAIN_TEST_ALICE &&
		note.ref.senderUserID == ROOM_CHAIN_TEST_BOB,
		"expected alice's note of the forward",
	)

	// bob verifies the same Add but did not sign it: he forwards nothing.
	before = len(roomChainTestOfKind(.KeyEnvelope))
	roomChainTestDeliverLog(bob, 2, 3, trio.log[2])
	assert(len(roomChainTestOfKind(.KeyEnvelope)) == before, "expected bob to forward nothing")

	// carol takes both and reads the older messages, each verified against its real sender.
	roomChainTestCarolJoins(&trio)
	roomChainTestDeliverEnvelope(carol, forwards[0], 10)
	roomChainTestDeliverEnvelope(carol, forwards[1], 11)
	key := roomChainTestLastNote(carol, .Key)
	assert(
		key != nil && key.outcome == .Stored && key.forwarderID == ROOM_CHAIN_TEST_ALICE,
		"expected carol to store the forward from alice",
	)
	assert(
		KeyStore_roomChainCount(carol.e2ee[0].store, ROOM_CHAIN_TEST_ROOM) == 2,
		"expected carol to hold both older chains",
	)
	roomChainTestDeliverMessage(carol, trio.fromAlice, 500)
	roomChainTestDeliverMessage(carol, trio.fromBob, 501)
	for expected in ([]struct {
			id:   int,
			text: string,
		}{{500, "alice before carol"}, {501, "bob before carol"}}) {
		entry := roomChainTestEntry(carol, expected.id)
		assert(
			entry != nil &&
			entry.security.protection == .Encrypted &&
			entry.content == expected.text,
			fmt.tprintf("expected carol to open %q, got %v", expected.text, entry.security),
		)
	}
	// bob's message presented as alice's still fails: the forwarder gave access, not authorship.
	asAlice := trio.fromBob
	asAlice.userID = ROOM_CHAIN_TEST_ALICE
	roomChainTestDeliverMessage(carol, asAlice, 502)
	assert(
		roomChainTestEntry(carol, 502).security.protection != .Encrypted,
		"expected a message moved to another sender to stay closed",
	)
}

@(test)
testRoomChainsFullHistoryAnyMemberAnswersKeyRequests :: proc(t: ^testing.T) {
	roomChainTestBegin()
	defer roomChainTestEnd()
	defer free_all(context.temp_allocator)
	trio := roomChainTestTrio(.Full)
	defer roomChainTestTrioDeinit(&trio)
	carol := &trio.carol

	// alice after a restart: the same profile and chains, the whole log replayed (so no
	// forwards of her own Add, which an earlier run sent).
	again := roomChainTestState(trio.serverKey, ROOM_CHAIN_TEST_ALICE)
	defer State_deinit(&again)
	Config_deinit(&again.config)
	again.config = Config_clone(trio.alice.config)
	e2ee, _ := State_e2eeEnsureStore(&again, ROOM_CHAIN_TEST_SERVER)
	for chain in trio.alice.e2ee[0].store.roomChains {
		KeyStore_addRoomChain(&e2ee.store, chain)
	}
	roomChainTestPin(
		&again,
		roomChainTestBundle(&trio.bob, ROOM_CHAIN_TEST_BOB),
		roomChainTestBundle(carol, ROOM_CHAIN_TEST_CAROL),
	)
	roomChainTestListRoom(&again, 3, .Full)
	before := len(roomChainTestOfKind(.KeyEnvelope))
	roomChainTestDeliverLog(&again, 0, 3, ..trio.log)
	assert(len(roomChainTestOfKind(.KeyEnvelope)) == before, "expected no forward on a replay")

	// carol meets bob's message without its key: she fetches, finds nothing, and asks.
	roomChainTestCarolJoins(&trio)
	roomChainTestDeliverMessage(carol, trio.fromBob, 600)
	waiting := roomChainTestEntry(carol, 600)
	assert(
		waiting.security.protection == .Pending && waiting.security.wait == .Key,
		"expected bob's message waiting for its key",
	)
	page := ClientTransportRuntimeEvent {
		kind     = .RoomKeysReceived,
		serverID = ROOM_CHAIN_TEST_SERVER,
		roomID   = ROOM_CHAIN_TEST_ROOM,
	}
	roomChainTestApply(carol, &page)
	requests := len(roomChainTestOfKind(.RequestKey))
	request := roomChainTestLast(.RequestKey)
	assert(
		request.userID == ROOM_CHAIN_TEST_CAROL &&
		request.request.senderUserID == ROOM_CHAIN_TEST_BOB &&
		request.request.chainID == trio.beta.request.chainID,
		"expected carol to ask for bob's chain",
	)
	// A member comes online: the request goes out again, since that member may hold it.
	presence := ClientTransportRuntimeEvent {
		kind     = .UserPresenceChanged,
		serverID = ROOM_CHAIN_TEST_SERVER,
		user     = {id = ROOM_CHAIN_TEST_ALICE, nickname = strings.clone("alice"), isOnline = true},
	}
	roomChainTestApply(carol, &presence)
	assert(
		len(roomChainTestOfKind(.RequestKey)) == requests + 1,
		"expected the request again when alice came online",
	)
	// Someone who is not a member coming online asks nothing again.
	outsider := ClientTransportRuntimeEvent {
		kind     = .UserPresenceChanged,
		serverID = ROOM_CHAIN_TEST_SERVER,
		user     = {id = ROOM_CHAIN_TEST_DAVE, nickname = strings.clone("dave"), isOnline = true},
	}
	roomChainTestApply(carol, &outsider)
	assert(len(roomChainTestOfKind(.RequestKey)) == requests + 1, "expected no request for dave")

	// alice, not the sender, answers with a RoomKeyForward of bob's chain to carol.
	roomChainTestAsk(&again, ROOM_CHAIN_TEST_BOB, ROOM_CHAIN_TEST_CAROL, trio.beta.request.chainID)
	answer := roomChainTestLast(.KeyEnvelope)
	decoded, _ := common.decodeSealedEnvelope(answer.request.bytes)
	assert(
		answer.userID == ROOM_CHAIN_TEST_ALICE &&
		answer.request.senderUserID == ROOM_CHAIN_TEST_BOB &&
		decoded.kind == .RoomKeyForward &&
		decoded.wrapCount == 1,
		"expected alice to forward bob's chain",
	)
	roomChainTestDeliverEnvelope(carol, answer, 20)
	opened := roomChainTestEntry(carol, 600)
	assert(
		opened.security.protection == .Encrypted && opened.content == "bob before carol",
		"expected bob's message to open with alice's forward",
	)
	// Asked again (bob also answered, or the request came twice): nothing more is sent.
	sent := len(roomChainTestOfKind(.KeyEnvelope))
	roomChainTestAsk(&again, ROOM_CHAIN_TEST_BOB, ROOM_CHAIN_TEST_CAROL, trio.beta.request.chainID)
	assert(len(roomChainTestOfKind(.KeyEnvelope)) == sent, "expected one answer per chain")
	// A second copy reaching carol (bob's answer) is a duplicate, and changes nothing.
	roomChainTestDeliverEnvelope(carol, answer, 21)
	assert(roomChainTestLastNote(carol, .Key).outcome == .Duplicate, "expected a duplicate")

	// A chain alice does not hold, and a requester who is not a member, get nothing.
	unknown := common.ChainID{}
	unknown[0] = 0xee
	roomChainTestAsk(&again, ROOM_CHAIN_TEST_BOB, ROOM_CHAIN_TEST_CAROL, unknown)
	assert(roomChainTestLastNote(&again, .Answered).outcome == .NotHeld, "expected not held")
	roomChainTestAsk(&again, ROOM_CHAIN_TEST_BOB, ROOM_CHAIN_TEST_DAVE, trio.beta.request.chainID)
	assert(roomChainTestLastNote(&again, .Answered).outcome == .Refused, "expected dave refused")
	assert(len(roomChainTestOfKind(.KeyEnvelope)) == sent, "expected no envelope for either")
}

@(test)
testRoomChainsFullHistoryForwardsAreChecked :: proc(t: ^testing.T) {
	roomChainTestBegin()
	defer roomChainTestEnd()
	defer free_all(context.temp_allocator)
	trio := roomChainTestTrio(.Full)
	defer roomChainTestTrioDeinit(&trio)
	carol := &trio.carol
	roomChainTestCarolJoins(&trio)
	roomChainTestDeliverMessage(carol, trio.fromBob, 700)
	held, _ := KeyStore_roomChain(
		&trio.alice.e2ee[0].store,
		ROOM_CHAIN_TEST_ROOM,
		2,
		ROOM_CHAIN_TEST_BOB,
		trio.beta.request.chainID,
	)
	betaKey, betaStart := held.chainKey, held.startIndex

	// Signed by bob but presented as alice's forward: the signature is checked against alice.
	byBob := roomChainTestForge(
		trio.serverKey,
		&trio.bob,
		ROOM_CHAIN_TEST_ALICE,
		2,
		ROOM_CHAIN_TEST_BOB,
		trio.beta.request.chainID,
		betaStart,
		betaKey,
		carol,
		ROOM_CHAIN_TEST_CAROL,
	)
	roomChainTestDeliverEnvelope(carol, byBob, 30)
	note := roomChainTestLastNote(carol, .Key)
	assert(
		note.outcome == .Failed && note.error == .BadSignature,
		fmt.tprintf("expected a bad signature, got %v %v", note.outcome, note.error),
	)
	// From dave, who was never a member: not allowed, whatever he signed.
	dave := roomChainTestState(trio.serverKey, ROOM_CHAIN_TEST_DAVE)
	defer State_deinit(&dave)
	byDave := roomChainTestForge(
		trio.serverKey,
		&dave,
		ROOM_CHAIN_TEST_DAVE,
		2,
		ROOM_CHAIN_TEST_BOB,
		trio.beta.request.chainID,
		betaStart,
		betaKey,
		carol,
		ROOM_CHAIN_TEST_CAROL,
	)
	roomChainTestDeliverEnvelope(carol, byDave, 31)
	assert(roomChainTestLastNote(carol, .Key).outcome == .NotAllowed, "expected dave refused")
	// A chain of carol's own in epoch 2, when she was not a member: its sender fails the log.
	carolsChain := trio.beta.request.chainID
	carolsChain[0] ~= 0x55
	notMember := roomChainTestForge(
		trio.serverKey,
		&trio.alice,
		ROOM_CHAIN_TEST_ALICE,
		2,
		ROOM_CHAIN_TEST_CAROL,
		carolsChain,
		0,
		betaKey,
		carol,
		ROOM_CHAIN_TEST_CAROL,
	)
	roomChainTestDeliverEnvelope(carol, notMember, 32)
	assert(
		roomChainTestLastNote(carol, .Key).outcome == .NotMember,
		"expected a chain whose sender was not a member of its epoch refused",
	)
	assert(
		KeyStore_roomChainCount(carol.e2ee[0].store, ROOM_CHAIN_TEST_ROOM) == 0,
		"expected carol to hold nothing yet",
	)
	assert(
		roomChainTestEntry(carol, 700).security.protection == .Pending,
		"expected bob's message still waiting",
	)
	// The genuine forward from alice opens it.
	genuine := roomChainTestForge(
		trio.serverKey,
		&trio.alice,
		ROOM_CHAIN_TEST_ALICE,
		2,
		ROOM_CHAIN_TEST_BOB,
		trio.beta.request.chainID,
		betaStart,
		betaKey,
		carol,
		ROOM_CHAIN_TEST_CAROL,
	)
	roomChainTestDeliverEnvelope(carol, genuine, 33)
	assert(
		roomChainTestEntry(carol, 700).content == "bob before carol",
		"expected the genuine forward to open bob's message",
	)
}

@(test)
testRoomChainsFromJoinNeverForwards :: proc(t: ^testing.T) {
	roomChainTestBegin()
	defer roomChainTestEnd()
	defer free_all(context.temp_allocator)
	trio := roomChainTestTrio(.FromJoin)
	defer roomChainTestTrioDeinit(&trio)
	alice, carol := &trio.alice, &trio.carol

	// alice signs carol's Add in a From join room: nothing older goes to carol.
	before := len(roomChainTestOfKind(.KeyEnvelope))
	roomChainTestDeliverLog(alice, 2, 3, trio.log[2])
	assert(len(roomChainTestOfKind(.KeyEnvelope)) == before, "expected no forward in From join")
	// Nor on request: not bob's chain, and not her own from before carol joined.
	roomChainTestAsk(alice, ROOM_CHAIN_TEST_BOB, ROOM_CHAIN_TEST_CAROL, trio.beta.request.chainID)
	assert(roomChainTestLastNote(alice, .Answered).outcome == .Refused, "expected refused")
	roomChainTestAsk(
		alice,
		ROOM_CHAIN_TEST_ALICE,
		ROOM_CHAIN_TEST_CAROL,
		trio.alpha.request.chainID,
	)
	assert(roomChainTestLastNote(alice, .Answered).outcome == .Refused, "expected refused")
	assert(len(roomChainTestOfKind(.KeyEnvelope)) == before, "expected no envelope at all")

	// A forward reaching carol anyway (a client that broke the rule) is not taken.
	roomChainTestCarolJoins(&trio)
	held, _ := KeyStore_roomChain(
		&alice.e2ee[0].store,
		ROOM_CHAIN_TEST_ROOM,
		2,
		ROOM_CHAIN_TEST_BOB,
		trio.beta.request.chainID,
	)
	forged := roomChainTestForge(
		trio.serverKey,
		alice,
		ROOM_CHAIN_TEST_ALICE,
		2,
		ROOM_CHAIN_TEST_BOB,
		trio.beta.request.chainID,
		held.startIndex,
		held.chainKey,
		carol,
		ROOM_CHAIN_TEST_CAROL,
	)
	roomChainTestDeliverEnvelope(carol, forged, 40)
	assert(
		roomChainTestLastNote(carol, .Key).outcome == .NotAllowed,
		"expected a forward in a From join room refused",
	)
	assert(
		KeyStore_roomChainCount(carol.e2ee[0].store, ROOM_CHAIN_TEST_ROOM) == 0,
		"expected carol to hold no older chain",
	)
}
