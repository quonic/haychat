package client

import "../common"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:testing"

// Client tests for signed plaintext room messages (protocol 22, #90): a message is shown only
// when its sender's signature verifies against the sender's pin, waits without its text while
// the sender's key is fetched, and is never shown, counted or retried otherwise.

ROOM_SIGNATURE_TEST_SERVER :: 981
ROOM_SIGNATURE_TEST_SELF :: 40
ROOM_SIGNATURE_TEST_PEER :: 41
ROOM_SIGNATURE_TEST_STRANGER :: 42

// Fetches the stubbed bridge saw for ROOM_SIGNATURE_TEST_SERVER. Guarded by
// e2eeSendBridgeTestMutex.
@(private = "file")
roomSignatureTestFetches: [dynamic]int

@(private = "file")
roomSignatureTestFetchBridge :: proc(transport: ^ClientServerTransport, userIDs: []int) -> bool {
	if transport.serverID != ROOM_SIGNATURE_TEST_SERVER {
		return false
	}
	append(&roomSignatureTestFetches, ..userIDs)
	return true
}

// A profile of its own for the peer: its identity signs, its bundle is what the server hands
// out.
@(private = "file")
RoomSignatureTestPeer :: struct {
	config: Config,
	bundle: common.UserKeyBundle,
}

@(private = "file")
roomSignatureTestPeer :: proc(userID: int) -> RoomSignatureTestPeer {
	privateKey, publicKey, ok := common.generateIdentityKeyPair()
	assert(ok, "expected a peer identity key")
	peer := RoomSignatureTestPeer {
		config = Config {
			private_key = common.identityPrivateKeyToHex(privateKey),
			public_key = common.identityPublicKeyToHex(publicKey),
		},
	}
	assert(ensureEncryptionKey(&peer.config), "expected a peer encryption key")
	keyPair, bundle, keyOK := Config_encryptionKey(peer.config)
	common.EncryptionKeyPair_wipe(&keyPair)
	assert(keyOK, "expected the peer's bundle")
	peer.bundle = common.UserKeyBundle {
		userId              = userID,
		identityPublicKey   = bundle.identityPublicKey,
		encryptionPublicKey = bundle.encryptionPublicKey,
		createdAt           = bundle.createdAt,
		signature           = bundle.signature,
	}
	return peer
}

// A live plaintext message from senderID, signed by signer (nil: unsigned).
@(private = "file")
roomSignatureTestDeliver :: proc(
	state: ^State,
	senderID, messageID: int,
	content: string,
	signer: ^Config,
	serverKey: common.IdentityPublicKeyBytes,
) {
	event := ClientTransportRuntimeEvent {
		kind           = .RoomChatReceived,
		serverID       = ROOM_SIGNATURE_TEST_SERVER,
		roomID         = common.GENERAL_ROOM_ID,
		senderID       = senderID,
		senderNickname = strings.clone("sender"),
		messageID      = messageID,
		timestamp      = strings.clone("t"),
		message        = strings.clone(content),
	}
	if signer != nil {
		privateKey, ok := common.identityPrivateKeyFromHex(signer.private_key)
		assert(ok, "expected the signer's identity key")
		event.clientMessageID = testMessageClientID(messageID, 3)
		event.signature, ok = common.signPlaintextRoomMessage(
			common.PlaintextRoomMessageFields {
				serverIdentityPublicKey = serverKey,
				roomID = common.GENERAL_ROOM_ID,
				senderUserID = senderID,
				clientMessageID = event.clientMessageID,
			},
			content,
			privateKey,
		)
		assert(ok, "expected the test message to sign")
	}
	State_applyRuntimeEvent(state, &event)
	ClientTransportRuntimeEvent_deinit(&event)
}

@(private = "file")
roomSignatureTestEntry :: proc(state: ^State, messageID: int) -> ^RoomMessageEntry {
	cache := State_serverRoomCache(state, ROOM_SIGNATURE_TEST_SERVER)
	room := ServerRoomCache_roomCache(cache, common.GENERAL_ROOM_ID)
	for &entry in room.messages {
		if entry.id == messageID {
			return &entry
		}
	}
	return nil
}

@(private = "file")
roomSignatureTestLines :: proc(state: ^State) -> []int {
	ids := make([dynamic]int, context.temp_allocator)
	for line in buildRoomView(state).lines {
		append(&ids, line.messageID)
	}
	return ids[:]
}

@(test)
testPlaintextRoomMessagesNeedTheirSendersSignature :: proc(t: ^testing.T) {
	sync.mutex_lock(&e2eeSendBridgeTestMutex)
	defer sync.mutex_unlock(&e2eeSendBridgeTestMutex)
	e2eeFetchBridge = roomSignatureTestFetchBridge
	defer {
		e2eeFetchBridge = ClientServerTransport_fetchUserKeys
		delete(roomSignatureTestFetches)
		roomSignatureTestFetches = nil
	}
	defer free_all(context.temp_allocator)

	server := testDirectServer(ROOM_SIGNATURE_TEST_SERVER)
	state := testUpdateStateForServer(server)
	defer State_deinit(&state)
	testPrepareRoomSend(&state, ROOM_SIGNATURE_TEST_SERVER, ROOM_SIGNATURE_TEST_SELF)
	serverKey, _ := testMessageSigner(&state, ROOM_SIGNATURE_TEST_SERVER, ROOM_SIGNATURE_TEST_SELF)
	peer := roomSignatureTestPeer(ROOM_SIGNATURE_TEST_PEER)
	defer Config_deinit(&peer.config)
	clear(&roomSignatureTestFetches)

	// The peer is not pinned yet: the message waits for its key without showing its text, and
	// the key is fetched.
	roomSignatureTestDeliver(&state, ROOM_SIGNATURE_TEST_PEER, 10, "hello", &peer.config, serverKey)
	waiting := roomSignatureTestEntry(&state, 10)
	assert(
		waiting.security == {protection = .Pending, wait = .Sender},
		fmt.tprintf("expected the message to wait for the sender's key, got %v", waiting.security),
	)
	text, placeholder, _ := roomMessageDisplay(&state, ROOM_SIGNATURE_TEST_SERVER, waiting^)
	assert(
		placeholder && text == DIRECT_CHECKING_TEXT,
		fmt.tprintf("expected a placeholder instead of the text, got %q", text),
	)
	assert(
		len(roomSignatureTestFetches) == 1 &&
		roomSignatureTestFetches[0] == ROOM_SIGNATURE_TEST_PEER,
		fmt.tprintf("expected a fetch of the sender's key, got %v", roomSignatureTestFetches),
	)

	// The bundle arrives and is pinned: the message is checked and shown.
	keys := ClientTransportRuntimeEvent {
		kind     = .UserKeysReceived,
		serverID = ROOM_SIGNATURE_TEST_SERVER,
	}
	append(&keys.userKeys, peer.bundle)
	State_applyRuntimeEvent(&state, &keys)
	ClientTransportRuntimeEvent_deinit(&keys)
	opened := roomSignatureTestEntry(&state, 10)
	assert(
		opened.security.protection == .Plain && opened.content == "hello",
		fmt.tprintf("expected the message shown once the key was pinned, got %v", opened^),
	)

	// Unsigned, signed by another key, or with changed text: never shown, and not unread.
	unreadBefore := State_roomSummary(
		&state,
		ROOM_SIGNATURE_TEST_SERVER,
		common.GENERAL_ROOM_ID,
	)
	countBefore := unreadBefore == nil ? 0 : unreadBefore.unreadCount
	other := roomSignatureTestPeer(ROOM_SIGNATURE_TEST_PEER)
	defer Config_deinit(&other.config)
	roomSignatureTestDeliver(&state, ROOM_SIGNATURE_TEST_PEER, 11, "unsigned", nil, serverKey)
	roomSignatureTestDeliver(
		&state,
		ROOM_SIGNATURE_TEST_PEER,
		12,
		"forged",
		&other.config,
		serverKey,
	)
	unsigned := roomSignatureTestEntry(&state, 11)
	forged := roomSignatureTestEntry(&state, 12)
	assert(
		unsigned.security == {protection = .Hidden, failure = .Unsigned} &&
		unsigned.content == "",
		fmt.tprintf("expected the unsigned message hidden, got %v", unsigned^),
	)
	assert(
		forged.security == {protection = .Hidden, failure = .BadSignature} &&
		forged.content == "",
		fmt.tprintf("expected the forged message hidden, got %v", forged^),
	)
	if summary := State_roomSummary(&state, ROOM_SIGNATURE_TEST_SERVER, common.GENERAL_ROOM_ID);
	   summary != nil {
		assert(
			summary.unreadCount == countBefore,
			fmt.tprintf("expected hidden messages not counted, got %d", summary.unreadCount),
		)
	}
	State_switchToChannel(&state, ROOM_SIGNATURE_TEST_SERVER, common.GENERAL_ROOM_ID)
	lines := roomSignatureTestLines(&state)
	assert(
		len(lines) == 1 && lines[0] == 10,
		fmt.tprintf("expected only the signed message in the transcript, got %v", lines),
	)

	// The same signed message again under a later ID is a replay.
	replayEvent := ClientTransportRuntimeEvent {
		kind           = .RoomChatReceived,
		serverID       = ROOM_SIGNATURE_TEST_SERVER,
		roomID         = common.GENERAL_ROOM_ID,
		senderID       = ROOM_SIGNATURE_TEST_PEER,
		messageID      = 13,
		timestamp      = strings.clone("t"),
		message        = strings.clone("hello"),
		clientMessageID = opened.clientMessageId,
		signature      = opened.signature,
	}
	State_applyRuntimeEvent(&state, &replayEvent)
	ClientTransportRuntimeEvent_deinit(&replayEvent)
	replay := roomSignatureTestEntry(&state, 13)
	assert(
		replay.security.protection == .Failed && replay.security.failure == .Replayed,
		fmt.tprintf("expected the copy marked replayed, got %v", replay.security),
	)

	// A sender the server has no key for, and never had: nobody can check it, so it is hidden.
	stranger := roomSignatureTestPeer(ROOM_SIGNATURE_TEST_STRANGER)
	defer Config_deinit(&stranger.config)
	roomSignatureTestDeliver(
		&state,
		ROOM_SIGNATURE_TEST_STRANGER,
		14,
		"who am I",
		&stranger.config,
		serverKey,
	)
	missing := ClientTransportRuntimeEvent {
		kind     = .UserKeysReceived,
		serverID = ROOM_SIGNATURE_TEST_SERVER,
	}
	append(&missing.missingUserIDs, ROOM_SIGNATURE_TEST_STRANGER)
	State_applyRuntimeEvent(&state, &missing)
	ClientTransportRuntimeEvent_deinit(&missing)
	settled := roomSignatureTestEntry(&state, 14)
	assert(
		settled.security == {protection = .Hidden, failure = .NoKey} && settled.content == "",
		fmt.tprintf("expected a message without a key hidden, got %v", settled^),
	)

	// This profile's own messages verify against its own key.
	testApplyRoomChat(
		&state,
		ROOM_SIGNATURE_TEST_SERVER,
		common.GENERAL_ROOM_ID,
		ROOM_SIGNATURE_TEST_SELF,
		15,
		"mine",
	)
	assert(
		roomSignatureTestEntry(&state, 15).security.protection == .Plain,
		"expected this profile's own message verified with its own key",
	)
	_ = t
}
