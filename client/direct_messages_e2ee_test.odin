package client

import "../common"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:testing"

// Client tests for encrypted direct messages (protocol 17, e2ee-design.md 4.5, 4.6, 7.2, 12.3):
// two States (alice and bob) on one server exchange envelopes through the stubbed send bridge,
// with sends queued until a key arrives, no downgrade, the plaintext fallback switch and its
// badges, failures that are final, replays, previews, and the view models.

DM_E2EE_TEST_SERVER :: 973
DM_E2EE_TEST_ALICE :: 21
DM_E2EE_TEST_BOB :: 22
DM_E2EE_TEST_CAROL :: 23

// Fetches the stubbed bridge saw for DM_E2EE_TEST_SERVER. Guarded by e2eeSendBridgeTestMutex.
@(private = "file")
dmTestFetches: [dynamic]int

@(private = "file")
dmTestFetchBridge :: proc(transport: ^ClientServerTransport, userIDs: []int) -> bool {
	// Other tests run in parallel; only this file's server is answered, like E1's tests do.
	if transport.serverID != DM_E2EE_TEST_SERVER {
		return false
	}
	append(&dmTestFetches, ..userIDs)
	return true
}

@(private = "file")
dmTestPublishBridge :: proc(
	transport: ^ClientServerTransport,
	bundle: common.EncryptionKeyBundle,
) -> bool {
	return transport.serverID == DM_E2EE_TEST_SERVER
}

@(private = "file")
dmTestBegin :: proc() {
	sync.mutex_lock(&directMessageSendBridgeTestMutex)
	sync.mutex_lock(&e2eeSendBridgeTestMutex)
	directMessageSendBridge = directMessageSendBridgeTestStub
	directMessageSendBridgeTestReturnValue = true
	e2eeFetchBridge = dmTestFetchBridge
	e2eePublishBridge = dmTestPublishBridge
}

@(private = "file")
dmTestEnd :: proc() {
	directMessageSendBridgeTestReset()
	directMessageSendBridge = ClientServerTransport_sendDirectMessage
	delete(dmTestFetches)
	dmTestFetches = nil
	e2eeFetchBridge = ClientServerTransport_fetchUserKeys
	e2eePublishBridge = ClientServerTransport_publishEncryptionKey
	sync.mutex_unlock(&e2eeSendBridgeTestMutex)
	sync.mutex_unlock(&directMessageSendBridgeTestMutex)
}

// A connected state for selfUserID on DM_E2EE_TEST_SERVER, with serverKey pinned and fresh
// identity and encryption keys. The key store lives in memory.
@(private = "file")
dmTestState :: proc(serverKey: common.IdentityPublicKeyBytes, selfUserID: int) -> State {
	server := testDirectServer(DM_E2EE_TEST_SERVER)
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
	testApplyConnectedAs(&state, DM_E2EE_TEST_SERVER, selfUserID, false)
	clear(&dmTestFetches)
	return state
}

// The bundle state's profile publishes, as the server would hand it out for userID.
@(private = "file")
dmTestBundle :: proc(state: ^State, userID: int) -> common.UserKeyBundle {
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
dmTestApplyKeys :: proc(
	state: ^State,
	bundles: []common.UserKeyBundle,
	missing: []int = nil,
) {
	event := ClientTransportRuntimeEvent {
		kind     = .UserKeysReceived,
		serverID = DM_E2EE_TEST_SERVER,
	}
	append(&event.userKeys, ..bundles)
	append(&event.missingUserIDs, ..missing)
	State_applyRuntimeEvent(state, &event)
	ClientTransportRuntimeEvent_deinit(&event)
}

// Applies a message as the server echoes it: sealed when envelope is set, plaintext otherwise.
@(private = "file")
dmTestApplyMessage :: proc(
	state: ^State,
	id, senderID, recipientID: int,
	clientMessageID: common.ClientMessageID,
	envelope: []u8 = nil,
	content := "",
	signature := common.SignatureBytes{},
) {
	event := ClientTransportRuntimeEvent {
		kind = .DirectMessageReceived,
		serverID = DM_E2EE_TEST_SERVER,
		directMessage = {
			id = id,
			senderId = senderID,
			senderNickname = strings.clone("sender"),
			recipientId = recipientID,
			recipientNickname = strings.clone("recipient"),
			timestamp = strings.clone("t"),
			content = strings.clone(content),
			clientMessageId = clientMessageID,
			signature = signature,
		},
	}
	if len(envelope) > 0 {
		event.directMessage.envelope = make([]u8, len(envelope))
		copy(event.directMessage.envelope, envelope)
	}
	State_applyRuntimeEvent(state, &event)
	ClientTransportRuntimeEvent_deinit(&event)
}

// Sends draft from state to peerUserID and returns what went out (envelope copied).
@(private = "file")
dmTestSend :: proc(
	state: ^State,
	peerUserID: int,
	text: string,
) -> (
	send: DirectMessageSend,
	envelope: []u8,
	content: string,
) {
	before := directMessageSendBridgeTestCount
	testSetDraft(&testDirectCache(state, DM_E2EE_TEST_SERVER, peerUserID).draft, text)
	State_sendDirectMessageTo(state, DM_E2EE_TEST_SERVER, peerUserID)
	if directMessageSendBridgeTestCount == before {
		return {}, nil, ""
	}
	send = directMessageSendBridgeTestSend
	envelope = make([]u8, len(directMessageSendBridgeTestEnvelope), context.temp_allocator)
	copy(envelope, directMessageSendBridgeTestEnvelope[:])
	content = strings.clone(directMessageSendBridgeTestContent, context.temp_allocator)
	return
}

@(private = "file")
dmTestEntry :: proc(state: ^State, peerUserID, messageID: int) -> ^DirectMessageEntry {
	return DirectConversationCache_entry(
		testDirectCache(state, DM_E2EE_TEST_SERVER, peerUserID),
		messageID,
	)
}

@(private = "file")
dmTestPair :: proc() -> (alice, bob: State, serverKey: common.IdentityPublicKeyBytes) {
	_, serverKey, _ = common.generateIdentityKeyPair()
	alice = dmTestState(serverKey, DM_E2EE_TEST_ALICE)
	bob = dmTestState(serverKey, DM_E2EE_TEST_BOB)
	return
}

@(test)
testDirectMessagesAreEncryptedBothWaysWithThePinnedKeys :: proc(t: ^testing.T) {
	dmTestBegin()
	defer dmTestEnd()
	defer free_all(context.temp_allocator)
	alice, bob, _ := dmTestPair()
	defer State_deinit(&alice)
	defer State_deinit(&bob)
	aliceBundle := [1]common.UserKeyBundle{dmTestBundle(&alice, DM_E2EE_TEST_ALICE)}
	bobBundle := [1]common.UserKeyBundle{dmTestBundle(&bob, DM_E2EE_TEST_BOB)}
	dmTestApplyKeys(&alice, bobBundle[:])
	dmTestApplyKeys(&bob, aliceBundle[:])

	// A send the transport refuses keeps the draft and says why.
	directMessageSendBridgeTestReturnValue = false
	refused, _, _ := dmTestSend(&alice, DM_E2EE_TEST_BOB, "secret\tplan")
	assert(
		refused.recipientUserID == 0 &&
		string(testDirectCache(&alice, DM_E2EE_TEST_SERVER, DM_E2EE_TEST_BOB).draft[:]) ==
			"secret\tplan" &&
		len(alice.chat_status_message) > 0,
		"expected a refused send to keep the draft",
	)
	directMessageSendBridgeTestReturnValue = true
	send, envelope, _ := dmTestSend(&alice, DM_E2EE_TEST_BOB, "secret\tplan")
	assert(len(envelope) > 0, "expected alice's message to go out as an envelope")
	assert(
		send.recipientUserID == DM_E2EE_TEST_BOB &&
		common.clientMessageIDIsSet(send.clientMessageID),
		fmt.tprintf("expected a client message ID for bob, got %v", send),
	)
	assert(
		!strings.contains(string(envelope), "secret"),
		"expected no plaintext in the envelope",
	)
	assert(
		len(testDirectCache(&alice, DM_E2EE_TEST_SERVER, DM_E2EE_TEST_BOB).draft) == 0 &&
		len(testDirectCache(&alice, DM_E2EE_TEST_SERVER, DM_E2EE_TEST_BOB).messages) == 0,
		"expected the draft cleared and nothing appended before the echo",
	)
	// The echo reaches both; each opens it with its own key (alice through her own wrap).
	for state, index in ([]^State{&alice, &bob}) {
		dmTestApplyMessage(
			state,
			100,
			DM_E2EE_TEST_ALICE,
			DM_E2EE_TEST_BOB,
			send.clientMessageID,
			envelope,
		)
		peer := index == 0 ? DM_E2EE_TEST_BOB : DM_E2EE_TEST_ALICE
		entry := dmTestEntry(state, peer, 100)
		assert(
			entry != nil &&
			entry.security.protection == .Encrypted &&
			entry.content == "secret    plan",
			fmt.tprintf("expected the message opened on side %d, got %v", index, entry),
		)
		assert(
			State_directConversationEncrypted(state, DM_E2EE_TEST_SERVER, peer),
			"expected the conversation marked encrypted",
		)
		badge, tone := directMessageBadge(entry.security, true)
		assert(badge == DIRECT_BADGE_ENCRYPTED && tone == .Good, "expected the lock badge")
	}
	// The preview of the conversation list is the opened text.
	aliceList := State_serverDirectCache(&alice, DM_E2EE_TEST_SERVER)
	assert(
		len(aliceList.conversations) == 1 &&
		aliceList.conversations[0].lastContent == "secret    plan" &&
		aliceList.conversations[0].security.protection == .Encrypted,
		"expected the opened preview",
	)

	// bob answers; alice opens it against her pin for bob.
	reply, replyEnvelope, _ := dmTestSend(&bob, DM_E2EE_TEST_ALICE, "ack")
	assert(len(replyEnvelope) > 0, "expected bob's reply encrypted")
	dmTestApplyMessage(
		&alice,
		101,
		DM_E2EE_TEST_BOB,
		DM_E2EE_TEST_ALICE,
		reply.clientMessageID,
		replyEnvelope,
	)
	opened := dmTestEntry(&alice, DM_E2EE_TEST_BOB, 101)
	assert(
		opened != nil && opened.security.protection == .Encrypted && opened.content == "ack",
		fmt.tprintf("expected alice to open bob's reply, got %v", opened),
	)

	// The pane shows locks and an encrypted header.
	State_openDirectConversation(&alice, DM_E2EE_TEST_SERVER, DM_E2EE_TEST_BOB)
	view := buildDirectConversationView(&alice)
	assert(
		view.composer.mode == .Encrypted &&
		view.composer.encrypted &&
		strings.contains(view.subtitle, "End-to-end encrypted") &&
		len(view.lines) == 2 &&
		view.lines[0].badge == DIRECT_BADGE_ENCRYPTED &&
		view.lines[1].content == "ack",
		fmt.tprintf("expected the encrypted pane, got %v", view),
	)
}

@(test)
testDirectMessageWaitsForTheSendersKeyThenOpens :: proc(t: ^testing.T) {
	dmTestBegin()
	defer dmTestEnd()
	defer free_all(context.temp_allocator)
	alice, bob, _ := dmTestPair()
	defer State_deinit(&alice)
	defer State_deinit(&bob)
	bob.recordDirectNotes = true
	bobBundle := [1]common.UserKeyBundle{dmTestBundle(&bob, DM_E2EE_TEST_BOB)}
	dmTestApplyKeys(&alice, bobBundle[:])
	send, envelope, _ := dmTestSend(&alice, DM_E2EE_TEST_BOB, "first contact")

	// bob never pinned alice: the envelope waits and her key is fetched.
	dmTestApplyMessage(
		&bob,
		200,
		DM_E2EE_TEST_ALICE,
		DM_E2EE_TEST_BOB,
		send.clientMessageID,
		envelope,
	)
	entry := dmTestEntry(&bob, DM_E2EE_TEST_ALICE, 200)
	assert(
		entry != nil && entry.security.protection == .Pending && entry.content == "",
		fmt.tprintf("expected the message to wait for alice's key, got %v", entry),
	)
	assert(
		len(dmTestFetches) == 1 && dmTestFetches[0] == DM_E2EE_TEST_ALICE,
		fmt.tprintf("expected a fetch of alice's key, got %v", dmTestFetches),
	)
	text, placeholder := directMessageText(entry^)
	assert(text == DIRECT_OPENING_TEXT && placeholder, "expected the opening placeholder")

	aliceBundle := [1]common.UserKeyBundle{dmTestBundle(&alice, DM_E2EE_TEST_ALICE)}
	dmTestApplyKeys(&bob, aliceBundle[:])
	entry = dmTestEntry(&bob, DM_E2EE_TEST_ALICE, 200)
	assert(
		entry.security.protection == .Encrypted && entry.content == "first contact",
		fmt.tprintf("expected the message opened once the key arrived, got %v", entry),
	)
	assert(
		len(bob.directNotes) == 1 &&
		bob.directNotes[0].kind == .Opened &&
		bob.directNotes[0].messageID == 200,
		fmt.tprintf("expected an Opened note for the harness, got %v", bob.directNotes),
	)

	// A message from someone the server has no key for, and never had, is settled: it cannot
	// be opened, and nothing is retried.
	carolEnvelope := envelope
	dmTestApplyMessage(&bob, 201, DM_E2EE_TEST_CAROL, DM_E2EE_TEST_BOB, {9 = 9}, carolEnvelope)
	missing := [1]int{DM_E2EE_TEST_CAROL}
	dmTestApplyKeys(&bob, nil, missing[:])
	settled := dmTestEntry(&bob, DM_E2EE_TEST_CAROL, 201)
	assert(
		settled.security.protection == .Failed && settled.security.failure == .NoKey,
		fmt.tprintf("expected a message without a key settled as failed, got %v", settled),
	)
}

@(test)
testDirectMessageFailuresAreFinalAndReplaysAreCaught :: proc(t: ^testing.T) {
	dmTestBegin()
	defer dmTestEnd()
	defer free_all(context.temp_allocator)
	alice, bob, _ := dmTestPair()
	defer State_deinit(&alice)
	defer State_deinit(&bob)
	bobBundle := [1]common.UserKeyBundle{dmTestBundle(&bob, DM_E2EE_TEST_BOB)}
	aliceBundle := [1]common.UserKeyBundle{dmTestBundle(&alice, DM_E2EE_TEST_ALICE)}
	dmTestApplyKeys(&alice, bobBundle[:])
	dmTestApplyKeys(&bob, aliceBundle[:])
	send, envelope, _ := dmTestSend(&alice, DM_E2EE_TEST_BOB, "once")

	// A flipped bit, another client message ID, and another sender ID all fail, shown with
	// the placeholder.
	flipped := make([]u8, len(envelope), context.temp_allocator)
	copy(flipped, envelope)
	flipped[len(flipped) - 10] ~= 0x01
	dmTestApplyMessage(
		&bob,
		300,
		DM_E2EE_TEST_ALICE,
		DM_E2EE_TEST_BOB,
		send.clientMessageID,
		flipped,
	)
	otherID := send.clientMessageID
	otherID[0] ~= 0xFF
	dmTestApplyMessage(&bob, 301, DM_E2EE_TEST_ALICE, DM_E2EE_TEST_BOB, otherID, envelope)
	for id in ([]int{300, 301}) {
		entry := dmTestEntry(&bob, DM_E2EE_TEST_ALICE, id)
		assert(
			entry.security.protection == .Failed &&
			entry.security.failure == .Envelope &&
			entry.security.envelopeError == .BadSignature &&
			entry.content == "",
			fmt.tprintf("expected message %d to fail its signature, got %v", id, entry),
		)
		text, placeholder := directMessageText(entry^)
		assert(text == DIRECT_UNDECRYPTABLE_TEXT && placeholder, "expected the placeholder")
	}
	assert(
		!State_directConversationEncrypted(&bob, DM_E2EE_TEST_SERVER, DM_E2EE_TEST_ALICE),
		"expected failed messages not to mark the conversation encrypted",
	)

	// The original opens; the same envelope again under a later ID is a replay.
	dmTestApplyMessage(
		&bob,
		302,
		DM_E2EE_TEST_ALICE,
		DM_E2EE_TEST_BOB,
		send.clientMessageID,
		envelope,
	)
	dmTestApplyMessage(
		&bob,
		310,
		DM_E2EE_TEST_ALICE,
		DM_E2EE_TEST_BOB,
		send.clientMessageID,
		envelope,
	)
	original := dmTestEntry(&bob, DM_E2EE_TEST_ALICE, 302)
	replay := dmTestEntry(&bob, DM_E2EE_TEST_ALICE, 310)
	assert(
		original.security.protection == .Encrypted && original.content == "once",
		fmt.tprintf("expected the original opened, got %v", original),
	)
	assert(
		replay.security.protection == .Failed &&
		replay.security.failure == .Replayed &&
		replay.content == "",
		fmt.tprintf("expected the later copy marked replayed, got %v", replay),
	)
	// In the other order (a newer page first) the later one is still the replay.
	dmTestApplyMessage(
		&alice,
		410,
		DM_E2EE_TEST_ALICE,
		DM_E2EE_TEST_BOB,
		send.clientMessageID,
		envelope,
	)
	dmTestApplyMessage(
		&alice,
		402,
		DM_E2EE_TEST_ALICE,
		DM_E2EE_TEST_BOB,
		send.clientMessageID,
		envelope,
	)
	assert(
		dmTestEntry(&alice, DM_E2EE_TEST_BOB, 410).security.failure == .Replayed &&
		dmTestEntry(&alice, DM_E2EE_TEST_BOB, 402).security.protection == .Encrypted,
		"expected the higher ID marked replayed whichever came first",
	)

	// A server that swaps bob's identity for carol's: bob's pin is kept, so an envelope that
	// carol signs as "bob" fails against it, and stays failed after carol's key is trusted.
	_, carolKey, _ := common.generateIdentityKeyPair()
	_ = carolKey
	carol := dmTestState(alice.e2ee[0].store.serverPublicKey, DM_E2EE_TEST_BOB)
	defer State_deinit(&carol)
	dmTestApplyKeys(&carol, aliceBundle[:])
	forged, forgedEnvelope, _ := dmTestSend(&carol, DM_E2EE_TEST_ALICE, "I am bob")
	dmTestApplyMessage(
		&alice,
		420,
		DM_E2EE_TEST_BOB,
		DM_E2EE_TEST_ALICE,
		forged.clientMessageID,
		forgedEnvelope,
	)
	forgedEntry := dmTestEntry(&alice, DM_E2EE_TEST_BOB, 420)
	assert(
		forgedEntry.security.protection == .Failed &&
		forgedEntry.security.envelopeError == .BadSignature,
		fmt.tprintf("expected an envelope by another identity key to fail, got %v", forgedEntry),
	)
	carolAsBob := [1]common.UserKeyBundle{dmTestBundle(&carol, DM_E2EE_TEST_BOB)}
	dmTestApplyKeys(&alice, carolAsBob[:])
	assert(
		State_e2eePeerKeyInfo(&alice, DM_E2EE_TEST_SERVER, DM_E2EE_TEST_BOB).state == .KeyChanged,
		"expected bob's key change to show",
	)
	assert(
		State_e2eeTrustNewKey(&alice, DM_E2EE_TEST_SERVER, DM_E2EE_TEST_BOB),
		"expected trust to pin the new key",
	)
	assert(
		dmTestEntry(&alice, DM_E2EE_TEST_BOB, 420).security.protection == .Failed,
		"expected a failed message never to be retried with another key",
	)
}

@(test)
testDirectSendsQueueUntilTheKeyArrivesAndNeverDowngrade :: proc(t: ^testing.T) {
	dmTestBegin()
	defer dmTestEnd()
	defer free_all(context.temp_allocator)
	alice, bob, _ := dmTestPair()
	defer State_deinit(&alice)
	defer State_deinit(&bob)

	// No key yet: the message waits and the composer says so.
	State_openDirectConversation(&alice, DM_E2EE_TEST_SERVER, DM_E2EE_TEST_BOB)
	send, _, _ := dmTestSend(&alice, DM_E2EE_TEST_BOB, "queued one")
	assert(send.recipientUserID == 0, "expected nothing sent before the key is known")
	conversation := testDirectCache(&alice, DM_E2EE_TEST_SERVER, DM_E2EE_TEST_BOB)
	assert(
		len(conversation.queued) == 1 && len(conversation.draft) == 0,
		"expected the message queued and the draft cleared",
	)
	view := buildDirectConversationView(&alice)
	assert(
		view.composer.mode == .SettingUp && view.composer.note == DIRECT_SETTING_UP_TEXT,
		fmt.tprintf("expected Setting up encryption…, got %v", view.composer),
	)
	// The key arrives: the queued message goes out encrypted.
	bobBundle := [1]common.UserKeyBundle{dmTestBundle(&bob, DM_E2EE_TEST_BOB)}
	dmTestApplyKeys(&alice, bobBundle[:])
	assert(
		directMessageSendBridgeTestCount == 1 &&
		len(directMessageSendBridgeTestEnvelope) > 0 &&
		len(testDirectCache(&alice, DM_E2EE_TEST_SERVER, DM_E2EE_TEST_BOB).queued) == 0,
		"expected the queued message sent encrypted once the key arrived",
	)
	assert(
		State_directConversationEncrypted(&alice, DM_E2EE_TEST_SERVER, DM_E2EE_TEST_BOB),
		"expected sending encrypted to mark the conversation",
	)

	// A queued message to someone without a key goes back into the draft, never as plaintext.
	State_openDirectConversation(&alice, DM_E2EE_TEST_SERVER, DM_E2EE_TEST_CAROL)
	dmTestSend(&alice, DM_E2EE_TEST_CAROL, "hello carol")
	testSetDraft(&testDirectCache(&alice, DM_E2EE_TEST_SERVER, DM_E2EE_TEST_CAROL).draft, "more")
	missing := [1]int{DM_E2EE_TEST_CAROL}
	dmTestApplyKeys(&alice, nil, missing[:])
	carolConversation := testDirectCache(&alice, DM_E2EE_TEST_SERVER, DM_E2EE_TEST_CAROL)
	assert(
		directMessageSendBridgeTestCount == 1 &&
		string(carolConversation.draft[:]) == "hello carol\nmore" &&
		len(carolConversation.queued) == 0,
		fmt.tprintf("expected the queued text back in the draft, got %q", carolConversation.draft),
	)
	assert(
		strings.contains(alice.chat_status_message, "has not set up encryption yet"),
		fmt.tprintf("expected the reason, got %q", alice.chat_status_message),
	)
	// Sending now is refused with the reason; the draft stays.
	State_sendDirectMessageTo(&alice, DM_E2EE_TEST_SERVER, DM_E2EE_TEST_CAROL)
	assert(
		directMessageSendBridgeTestCount == 1 && len(carolConversation.draft) > 0,
		"expected a blocked send to send nothing and keep the draft",
	)

	// No downgrade: bob's conversation is encrypted; when the server stops providing his key,
	// sending is blocked like anywhere else, not sent as plaintext.
	missingBob := [1]int{DM_E2EE_TEST_BOB}
	dmTestApplyKeys(&alice, nil, missingBob[:])
	info := State_e2eePeerKeyInfo(&alice, DM_E2EE_TEST_SERVER, DM_E2EE_TEST_BOB)
	assert(info.state == .NotProvided, fmt.tprintf("expected NotProvided, got %v", info.state))
	State_openDirectConversation(&alice, DM_E2EE_TEST_SERVER, DM_E2EE_TEST_BOB)
	blocked, _, _ := dmTestSend(&alice, DM_E2EE_TEST_BOB, "downgrade?")
	assert(blocked.recipientUserID == 0, "expected no plaintext in an encrypted conversation")
	view = buildDirectConversationView(&alice)
	assert(
		view.composer.mode == .Blocked &&
		view.composer.showSwitch &&
		!view.composer.switchOn &&
		strings.contains(view.composer.note, "The server is not providing"),
		fmt.tprintf("expected the blocked composer with the switch off, got %v", view.composer),
	)
}

@(test)
testDirectPlaintextFallbackSwitchAndBadges :: proc(t: ^testing.T) {
	dmTestBegin()
	defer dmTestEnd()
	defer free_all(context.temp_allocator)
	alice, bob, serverKey := dmTestPair()
	defer State_deinit(&alice)
	defer State_deinit(&bob)
	aliceBundle := [1]common.UserKeyBundle{dmTestBundle(&alice, DM_E2EE_TEST_ALICE)}
	dmTestApplyKeys(&bob, aliceBundle[:])
	// alice cannot encrypt to bob: the server has no key for him.
	missing := [1]int{DM_E2EE_TEST_BOB}
	dmTestApplyKeys(&alice, nil, missing[:])
	State_openDirectConversation(&alice, DM_E2EE_TEST_SERVER, DM_E2EE_TEST_BOB)

	// Off by default; the first time it asks for confirmation.
	conversation := testDirectCache(&alice, DM_E2EE_TEST_SERVER, DM_E2EE_TEST_BOB)
	assert(!conversation.fallbackOn, "expected the switch off by default")
	assert(
		State_setDirectFallback(&alice, DM_E2EE_TEST_SERVER, DM_E2EE_TEST_BOB, true) ==
		.NeedsConfirmation,
		"expected the first time to need confirmation",
	)
	view := buildDirectConversationView(&alice)
	assert(
		view.composer.mode == .Confirm && len(view.composer.confirmText) > 0,
		"expected the confirmation",
	)
	State_cancelDirectFallback(&alice, DM_E2EE_TEST_SERVER, DM_E2EE_TEST_BOB)
	assert(!conversation.fallbackOn, "expected Cancel to leave it off")
	State_setDirectFallback(&alice, DM_E2EE_TEST_SERVER, DM_E2EE_TEST_BOB, true)
	assert(
		State_confirmDirectFallback(&alice, DM_E2EE_TEST_SERVER, DM_E2EE_TEST_BOB),
		"expected Turn on",
	)
	view = buildDirectConversationView(&alice)
	assert(
		view.composer.mode == .Fallback &&
		view.composer.warningLabel == DIRECT_FALLBACK_LABEL &&
		view.composer.sendLabel == DIRECT_FALLBACK_SEND_LABEL &&
		view.composer.switchOn,
		fmt.tprintf("expected the fallback composer, got %v", view.composer),
	)

	// It sends a signed plaintext message bob can check.
	send, envelope, content := dmTestSend(&alice, DM_E2EE_TEST_BOB, "please update")
	assert(len(envelope) == 0 && content == "please update", "expected plaintext")
	assert(
		common.verifyPlaintextDirectMessage(
			{serverKey, DM_E2EE_TEST_ALICE, DM_E2EE_TEST_BOB, send.clientMessageID},
			"please update",
			dmTestBundle(&alice, DM_E2EE_TEST_ALICE).identityPublicKey,
			send.signature,
		),
		"expected a valid signature by alice",
	)
	for state, index in ([]^State{&alice, &bob}) {
		dmTestApplyMessage(
			state,
			500,
			DM_E2EE_TEST_ALICE,
			DM_E2EE_TEST_BOB,
			send.clientMessageID,
			content = "please update",
			signature = send.signature,
		)
		peer := index == 0 ? DM_E2EE_TEST_BOB : DM_E2EE_TEST_ALICE
		entry := dmTestEntry(state, peer, 500)
		badge, tone := directMessageBadge(entry.security, false)
		assert(
			entry.security.protection == .Signed &&
			badge == DIRECT_BADGE_UNENCRYPTED &&
			tone == .Warning,
			fmt.tprintf("expected Unencrypted on side %d, got %v", index, entry),
		)
		summary := State_serverDirectCache(state, DM_E2EE_TEST_SERVER).conversations[0]
		assert(
			directPreviewUnencrypted(summary.security, false, false),
			"expected the preview badge on a fallback message",
		)
	}
	// A changed text fails the signature; an unsigned message is from before the upgrade.
	dmTestApplyMessage(
		&bob,
		501,
		DM_E2EE_TEST_ALICE,
		DM_E2EE_TEST_BOB,
		send.clientMessageID ~ {0 = 1},
		content = "please update!",
		signature = send.signature,
	)
	dmTestApplyMessage(&bob, 400, DM_E2EE_TEST_ALICE, DM_E2EE_TEST_BOB, {}, content = "old")
	unverified := dmTestEntry(&bob, DM_E2EE_TEST_ALICE, 501)
	badge, tone := directMessageBadge(unverified.security, false)
	assert(
		unverified.security.protection == .Unverified &&
		badge == DIRECT_BADGE_NOT_VERIFIED &&
		tone == .Danger,
		fmt.tprintf("expected sender not verified, got %v", unverified),
	)
	old := dmTestEntry(&bob, DM_E2EE_TEST_ALICE, 400)
	badge, tone = directMessageBadge(old.security, false)
	assert(
		old.security.protection == .Plain && badge == DIRECT_BADGE_NOT_ENCRYPTED && tone == .Muted,
		fmt.tprintf("expected Not encrypted, got %v", old),
	)

	// Closing the conversation turns the switch off; the confirmation is not asked again.
	State_switchToChannel(&alice, DM_E2EE_TEST_SERVER, common.GENERAL_ROOM_ID)
	assert(!conversation.fallbackOn, "expected closing the conversation to turn it off")
	State_openDirectConversation(&alice, DM_E2EE_TEST_SERVER, DM_E2EE_TEST_BOB)
	assert(
		State_setDirectFallback(&alice, DM_E2EE_TEST_SERVER, DM_E2EE_TEST_BOB, true) == .On,
		"expected no second confirmation in this run",
	)
	// Encryption becomes possible: it turns off by itself and the switch is not offered.
	bobBundle := [1]common.UserKeyBundle{dmTestBundle(&bob, DM_E2EE_TEST_BOB)}
	dmTestApplyKeys(&alice, bobBundle[:])
	assert(!conversation.fallbackOn, "expected the switch off once encryption works")
	assert(
		State_setDirectFallback(&alice, DM_E2EE_TEST_SERVER, DM_E2EE_TEST_BOB, true) ==
		.Unavailable,
		"expected no switch while encryption is possible",
	)
	view = buildDirectConversationView(&alice)
	assert(view.composer.mode == .Encrypted && !view.composer.showSwitch, "expected encryption")

	// A new run (a new State) starts with the switch off: it is never saved.
	again := dmTestState(serverKey, DM_E2EE_TEST_ALICE)
	defer State_deinit(&again)
	dmTestApplyKeys(&again, nil, missing[:])
	assert(
		!testDirectCache(&again, DM_E2EE_TEST_SERVER, DM_E2EE_TEST_BOB).fallbackOn &&
		!testDirectCache(&again, DM_E2EE_TEST_SERVER, DM_E2EE_TEST_BOB).fallbackConfirmed,
		"expected the switch and its confirmation forgotten",
	)
}

@(test)
testDirectPreviewsOpenFromTheConversationList :: proc(t: ^testing.T) {
	dmTestBegin()
	defer dmTestEnd()
	defer free_all(context.temp_allocator)
	alice, bob, _ := dmTestPair()
	defer State_deinit(&alice)
	defer State_deinit(&bob)
	bobBundle := [1]common.UserKeyBundle{dmTestBundle(&bob, DM_E2EE_TEST_BOB)}
	aliceBundle := [1]common.UserKeyBundle{dmTestBundle(&alice, DM_E2EE_TEST_ALICE)}
	dmTestApplyKeys(&alice, bobBundle[:])
	send, envelope, _ := dmTestSend(&alice, DM_E2EE_TEST_BOB, "preview me")

	event := ClientTransportRuntimeEvent {
		kind     = .DirectConversationsReceived,
		serverID = DM_E2EE_TEST_SERVER,
	}
	summary := common.DirectConversationSummary {
		peerUserId          = DM_E2EE_TEST_ALICE,
		peerNickname        = strings.clone("alice"),
		lastMessageID       = 600,
		lastSenderId        = DM_E2EE_TEST_ALICE,
		lastTimestamp       = strings.clone("t"),
		lastContent         = strings.clone(""),
		lastClientMessageId = send.clientMessageID,
		lastEnvelope        = make([]u8, len(envelope)),
	}
	copy(summary.lastEnvelope, envelope)
	append(&event.conversations, summary)
	State_applyRuntimeEvent(&bob, &event)
	ClientTransportRuntimeEvent_deinit(&event)
	preview := State_serverDirectCache(&bob, DM_E2EE_TEST_SERVER).conversations[0]
	assert(
		preview.security.protection == .Pending && len(dmTestFetches) == 1,
		"expected the preview to wait for alice's key",
	)
	dmTestApplyKeys(&bob, aliceBundle[:])
	preview = State_serverDirectCache(&bob, DM_E2EE_TEST_SERVER).conversations[0]
	assert(
		preview.security.protection == .Encrypted && preview.lastContent == "preview me",
		fmt.tprintf("expected the decrypted preview, got %v", preview),
	)
	rows := buildSidebarRows(&bob)
	for row in rows {
		if row.kind == .Conversation {
			assert(!row.previewUnencrypted, "expected no Unencrypted badge on an encrypted preview")
		}
	}
	assert(
		directPreviewUnencrypted({protection = .Plain}, false, true) &&
		!directPreviewUnencrypted({protection = .Plain}, false, false),
		"expected plaintext in an encrypted conversation to get the badge, old plaintext not",
	)
}

@(test)
testDirectSendModeAndComposerAreDecidedByTheKeyState :: proc(t: ^testing.T) {
	cases := [?]struct {
		info:     E2EEPeerKeyInfo,
		fallback: bool,
		expected: DirectSendMode,
	} {
		{{state = .Unverified, canEncrypt = true}, false, .Encrypt},
		{{state = .Verified, canEncrypt = true}, true, .Encrypt},
		{{state = .Unknown, blockReason = .Pending}, true, .Queue},
		{{state = .NotSetUp, blockReason = .NotSetUp}, false, .Blocked},
		{{state = .KeyChanged, blockReason = .KeyChanged}, false, .Blocked},
		{{state = .NotProvided, blockReason = .NotProvided}, true, .Plaintext},
		{{state = .InvalidKey, blockReason = .InvalidKey}, true, .Plaintext},
	}
	for testCase in cases {
		mode := directSendMode(testCase.info, testCase.fallback)
		testing.expect(
			t,
			mode == testCase.expected,
			fmt.tprintf("expected %v for %v, got %v", testCase.expected, testCase.info, mode),
		)
		testing.expect(
			t,
			directFallbackAvailable(testCase.info) ==
			(!testCase.info.canEncrypt && testCase.info.blockReason != .Pending),
			"expected the switch only while encryption is not possible for a known reason",
		)
	}
	for reason in ([]E2EEKeyState{.NotSetUp, .KeyChanged, .NotProvided, .InvalidKey}) {
		info := E2EEPeerKeyInfo {
			state       = reason,
			blockReason = e2eeBlockReasonFor(reason),
		}
		text := directBlockedText(info, "dave")
		testing.expect(
			t,
			strings.contains(text, "dave") && strings.contains(text, "cannot be encrypted"),
			fmt.tprintf("expected a reason for %v, got %q", reason, text),
		)
	}
	free_all(context.temp_allocator)
}
