package client

import "../common"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:testing"

// Client tests for encrypted voice's key handling (protocol 21, voice_e2ee.odin, design 4 and
// 11.3): alice and bob share an encrypted room whose log both verified at epoch 2 (alice
// created it and added bob); carol has a profile but is not a member until a test adds her at
// epoch 3. Both join voice with real (silent) engines; the voice control bridge records what
// each state sent, and the test plays the server.

@(private = "file")
VOICE_KEY_TEST_SERVER :: 977
@(private = "file")
VOICE_KEY_TEST_ALICE :: 71
@(private = "file")
VOICE_KEY_TEST_BOB :: 72
@(private = "file")
VOICE_KEY_TEST_CAROL :: 73
@(private = "file")
VOICE_KEY_TEST_ROOM :: 81
@(private = "file")
VOICE_KEY_TEST_NOW_MS :: i64(1_763_200_000_000)

// One voice control request a state sent, with owned envelope bytes.
@(private = "file")
VoiceKeyTestSent :: struct {
	request: VoiceControlRequest,
	userID:  int,
}

@(private = "file")
voiceKeyTestSent: [dynamic]VoiceKeyTestSent

@(private = "file")
voiceKeyTestBridge :: proc(
	transport: ^ClientServerTransport,
	request: VoiceControlRequest,
) -> bool {
	if transport.serverID != VOICE_KEY_TEST_SERVER {
		return false
	}
	copied := request
	copied.deviceID = ""
	if len(request.envelope) > 0 {
		copied.envelope = make([]u8, len(request.envelope))
		copy(copied.envelope, request.envelope)
	}
	append(&voiceKeyTestSent, VoiceKeyTestSent{copied, transport.authenticatedUserID})
	return true
}

@(private = "file")
voiceKeyTestLogBridge :: proc(transport: ^ClientServerTransport, request: RoomLogRequest) -> bool {
	return transport.serverID == VOICE_KEY_TEST_SERVER
}

@(private = "file")
voiceKeyTestFetchBridge :: proc(transport: ^ClientServerTransport, userIDs: []int) -> bool {
	return transport.serverID == VOICE_KEY_TEST_SERVER
}

@(private = "file")
voiceKeyTestPublishBridge :: proc(
	transport: ^ClientServerTransport,
	bundle: common.EncryptionKeyBundle,
) -> bool {
	return transport.serverID == VOICE_KEY_TEST_SERVER
}

@(private = "file")
voiceKeyTestBegin :: proc() {
	sync.mutex_lock(&voiceControlSendBridgeTestMutex)
	sync.mutex_lock(&roomLogSendBridgeTestMutex)
	sync.mutex_lock(&e2eeSendBridgeTestMutex)
	voiceControlSendBridge = voiceKeyTestBridge
	roomLogSendBridge = voiceKeyTestLogBridge
	e2eeFetchBridge = voiceKeyTestFetchBridge
	e2eePublishBridge = voiceKeyTestPublishBridge
}

@(private = "file")
voiceKeyTestClear :: proc() {
	for sent in voiceKeyTestSent {
		delete(sent.request.envelope)
	}
	clear(&voiceKeyTestSent)
}

@(private = "file")
voiceKeyTestEnd :: proc() {
	voiceKeyTestClear()
	delete(voiceKeyTestSent)
	voiceKeyTestSent = nil
	voiceControlSendBridge = ClientServerTransport_sendVoiceControl
	roomLogSendBridge = ClientServerTransport_sendRoomLogRequest
	e2eeFetchBridge = ClientServerTransport_fetchUserKeys
	e2eePublishBridge = ClientServerTransport_publishEncryptionKey
	sync.mutex_unlock(&e2eeSendBridgeTestMutex)
	sync.mutex_unlock(&roomLogSendBridgeTestMutex)
	sync.mutex_unlock(&voiceControlSendBridgeTestMutex)
}

// The voice key requests userID's state sent, oldest first (borrowed).
@(private = "file")
voiceKeyTestKeysFrom :: proc(userID: int) -> []VoiceKeyTestSent {
	found := make([dynamic]VoiceKeyTestSent, 0, 4, context.temp_allocator)
	for sent in voiceKeyTestSent {
		if sent.request.kind == .Key && sent.userID == userID {
			append(&found, sent)
		}
	}
	return found[:]
}

@(private = "file")
voiceKeyTestLastKey :: proc(userID: int) -> VoiceKeyTestSent {
	found := voiceKeyTestKeysFrom(userID)
	assert(len(found) > 0, fmt.tprintf("expected a voice key from user %d", userID))
	return found[len(found) - 1]
}

@(private = "file")
voiceKeyTestCount :: proc(kind: VoiceControlRequestKind, userID: int) -> int {
	count := 0
	for sent in voiceKeyTestSent {
		if sent.request.kind == kind && sent.userID == userID {
			count += 1
		}
	}
	return count
}

@(private = "file")
voiceKeyTestState :: proc(serverKey: common.IdentityPublicKeyBytes, selfUserID: int) -> State {
	server := testDirectServer(VOICE_KEY_TEST_SERVER)
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
	testApplyConnectedAs(&state, VOICE_KEY_TEST_SERVER, selfUserID, false)
	state.serverTransports[0].authenticatedUserID = selfUserID
	state.selected_server_id = VOICE_KEY_TEST_SERVER
	state.selected_transport_index = 0
	State_setVoiceEngineTemplate(
		&state,
		{source = {kind = .Silence}, sink = {kind = .Null}, gateMode = .VoiceActivity},
	)
	state.voice.e2ee.recordNotes = true
	state.voice.e2ee.nowOverrideMS = VOICE_KEY_TEST_NOW_MS
	return state
}

@(private = "file")
voiceKeyTestApply :: proc(state: ^State, event: ^ClientTransportRuntimeEvent) {
	State_applyRuntimeEvent(state, event)
	ClientTransportRuntimeEvent_deinit(event)
}

@(private = "file")
voiceKeyTestBundle :: proc(state: ^State, userID: int) -> common.UserKeyBundle {
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
voiceKeyTestPin :: proc(state: ^State, bundles: ..common.UserKeyBundle) {
	event := ClientTransportRuntimeEvent {
		kind     = .UserKeysReceived,
		serverID = VOICE_KEY_TEST_SERVER,
	}
	append(&event.userKeys, ..bundles)
	voiceKeyTestApply(state, &event)
}

@(private = "file")
voiceKeyTestListRoom :: proc(state: ^State, logVersion: int) {
	event := ClientTransportRuntimeEvent {
		kind     = .RoomListReceived,
		serverID = VOICE_KEY_TEST_SERVER,
	}
	append(
		&event.rooms,
		common.RoomSummary {
			id = VOICE_KEY_TEST_ROOM,
			name = strings.clone("secret voice"),
			description = strings.clone(""),
			roomType = .ChatAndVoice,
			access = .AdminInvite,
			historyVisibility = .FromJoin,
			encrypted = true,
			logVersion = logVersion,
		},
	)
	voiceKeyTestApply(state, &event)
}

@(private = "file")
voiceKeyTestDeliverLog :: proc(state: ^State, afterVersion, headVersion: int, entries: ..[]u8) {
	event := ClientTransportRuntimeEvent {
		kind            = .RoomLogReceived,
		serverID        = VOICE_KEY_TEST_SERVER,
		roomID          = VOICE_KEY_TEST_ROOM,
		logAfterVersion = afterVersion,
		logHeadVersion  = headVersion,
	}
	for entry in entries {
		copied := make([]u8, len(entry))
		copy(copied, entry)
		append(&event.logEntries, copied)
	}
	voiceKeyTestApply(state, &event)
}

// The member log signed by alice: Create, then an Add of bob, then (version 3) of carol. The
// entries are in the temp allocator.
@(private = "file")
voiceKeyTestLog :: proc(
	serverKey: common.IdentityPublicKeyBytes,
	alice, bob, carol: ^State,
) -> [3][]u8 {
	privateKey, _ := common.identityPrivateKeyFromHex(alice.config.private_key)
	alicePublic, _ := common.identityPublicKeyFromHex(alice.config.public_key)
	entries: [3][]u8
	prevHash: common.RoomLogHash
	targets := [3]^State{alice, bob, carol}
	targetIDs := [3]int{VOICE_KEY_TEST_ALICE, VOICE_KEY_TEST_BOB, VOICE_KEY_TEST_CAROL}
	for version in 1 ..= 3 {
		targetKey, _ := common.identityPublicKeyFromHex(targets[version - 1].config.public_key)
		entry := common.RoomLogEntry {
			roomID            = VOICE_KEY_TEST_ROOM,
			version           = version,
			prevHash          = prevHash,
			actorUserID       = VOICE_KEY_TEST_ALICE,
			createdAt         = 1_731_600_000 + u64(version),
			action            = version == 1 ? .Create : .Add,
			targetUserID      = targetIDs[version - 1],
			targetIdentityKey = targetKey,
		}
		managers := [1]common.RoomLogManager{{VOICE_KEY_TEST_ALICE, alicePublic}}
		if version == 1 {
			entry.settings = {
				access            = .AdminInvite,
				historyVisibility = .FromJoin,
				creatorJoins      = true,
				managers          = managers[:],
			}
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
		entries[version - 1] = data
		prevHash = common.hashRoomLogEntry(data)
	}
	return entries
}

@(private = "file")
VoiceKeyTestTrio :: struct {
	serverKey: common.IdentityPublicKeyBytes,
	alice:     State,
	bob:       State,
	carol:     State,
	log:       [3][]u8,
}

// alice, bob and carol pinned to each other; alice and bob verify the log at version 2.
@(private = "file")
voiceKeyTestTrio :: proc() -> (trio: VoiceKeyTestTrio) {
	_, trio.serverKey, _ = common.generateIdentityKeyPair()
	trio.alice = voiceKeyTestState(trio.serverKey, VOICE_KEY_TEST_ALICE)
	trio.bob = voiceKeyTestState(trio.serverKey, VOICE_KEY_TEST_BOB)
	trio.carol = voiceKeyTestState(trio.serverKey, VOICE_KEY_TEST_CAROL)
	aliceBundle := voiceKeyTestBundle(&trio.alice, VOICE_KEY_TEST_ALICE)
	bobBundle := voiceKeyTestBundle(&trio.bob, VOICE_KEY_TEST_BOB)
	carolBundle := voiceKeyTestBundle(&trio.carol, VOICE_KEY_TEST_CAROL)
	voiceKeyTestPin(&trio.alice, bobBundle, carolBundle)
	voiceKeyTestPin(&trio.bob, aliceBundle, carolBundle)
	voiceKeyTestPin(&trio.carol, aliceBundle, bobBundle)
	trio.log = voiceKeyTestLog(trio.serverKey, &trio.alice, &trio.bob, &trio.carol)
	for state in ([]^State{&trio.alice, &trio.bob}) {
		voiceKeyTestListRoom(state, 2)
		voiceKeyTestDeliverLog(state, 0, 2, trio.log[0], trio.log[1])
		assert(
			State_roomLogEpoch(state, VOICE_KEY_TEST_SERVER, VOICE_KEY_TEST_ROOM) == 2,
			"expected the log verified at epoch 2",
		)
	}
	return
}

@(private = "file")
voiceKeyTestTrioDeinit :: proc(trio: ^VoiceKeyTestTrio) {
	State_deinit(&trio.alice)
	State_deinit(&trio.bob)
	State_deinit(&trio.carol)
}

// Joins state to the room's voice: the join goes out and the server acknowledges it with a
// list of the given participants.
@(private = "file")
voiceKeyTestJoin :: proc(state: ^State, participants: ..int) {
	assert(
		State_joinVoice(state, VOICE_KEY_TEST_SERVER, VOICE_KEY_TEST_ROOM),
		fmt.tprintf("expected the join to go out, got %q", state.voice.lastError),
	)
	event := ClientTransportRuntimeEvent {
		kind                 = .VoiceParticipants,
		serverID             = VOICE_KEY_TEST_SERVER,
		roomID               = VOICE_KEY_TEST_ROOM,
		voiceRecipientJoined = true,
	}
	for userID in participants {
		append(
			&event.voiceParticipants,
			common.VoiceParticipant {
				userId = userID,
				nickname = strings.clone(fmt.tprintf("user-%d", userID)),
			},
		)
	}
	voiceKeyTestApply(state, &event)
	assert(state.voice.status == .Joined && state.voice.engine != nil, "expected voice joined")
}

// The server's ServerVoiceKey of sent (a Key request) to state.
@(private = "file")
voiceKeyTestDeliver :: proc(state: ^State, sent: VoiceKeyTestSent) {
	envelope := make([]u8, len(sent.request.envelope))
	copy(envelope, sent.request.envelope)
	event := ClientTransportRuntimeEvent {
		kind = .VoiceKeyReceived,
		serverID = VOICE_KEY_TEST_SERVER,
		roomID = sent.request.roomID,
		voiceKey = common.ServerVoiceKeyPayload {
			roomId = sent.request.roomID,
			senderId = sent.userID,
			epoch = sent.request.epoch,
			voiceSessionId = sent.request.voiceSessionID,
			generation = sent.request.generation,
			createdAt = sent.request.createdAt,
			envelope = envelope,
		},
	}
	voiceKeyTestApply(state, &event)
}

// A voice key as signer would seal it for sender's fields, wrapped for recipients' profiles.
@(private = "file")
voiceKeyTestCraft :: proc(
	trio: ^VoiceKeyTestTrio,
	signer: ^State,
	senderID, epoch: int,
	session: u8,
	generation: u32,
	createdAt: i64,
	recipients: ..^State,
) -> VoiceKeyTestSent {
	privateKey, _ := common.identityPrivateKeyFromHex(signer.config.private_key)
	wraps := make([dynamic]common.EnvelopeRecipient, 0, len(recipients), context.temp_allocator)
	for recipient in recipients {
		keyPair, _, _ := Config_encryptionKey(recipient.config)
		recipientID := State_selfUserID(recipient, VOICE_KEY_TEST_SERVER)
		append(&wraps, common.EnvelopeRecipient{recipientID, keyPair.publicKey})
		common.EncryptionKeyPair_wipe(&keyPair)
	}
	request := VoiceControlRequest {
		kind       = .Key,
		roomID     = VOICE_KEY_TEST_ROOM,
		epoch      = epoch,
		generation = generation,
		createdAt  = createdAt,
	}
	request.voiceSessionID[0] = session
	key: common.VoiceKey
	key[0] = session
	key[1] = u8(generation)
	buffer: [common.SEALED_ENVELOPE_MAX_BYTES]u8
	n, err := common.sealVoiceKey(
		common.VoiceKeyAADFields {
			serverIdentityPublicKey = trio.serverKey,
			roomID = VOICE_KEY_TEST_ROOM,
			epoch = epoch,
			senderUserID = senderID,
			voiceSessionID = request.voiceSessionID,
			generation = generation,
			createdAtUnix = createdAt,
		},
		key,
		wraps[:],
		privateKey,
		buffer[:],
	)
	assert(err == .None, fmt.tprintf("expected the crafted key to seal, got %v", err))
	request.envelope = make([]u8, n, context.temp_allocator)
	copy(request.envelope, buffer[:n])
	return VoiceKeyTestSent{request, senderID}
}

// The last voice key note of kind on state, and how many there were.
@(private = "file")
voiceKeyTestLastNote :: proc(state: ^State, kind: VoiceKeyNoteKind) -> (VoiceKeyNote, int) {
	last: VoiceKeyNote
	count := 0
	for note in state.voice.e2ee.notes {
		if note.kind == kind {
			last = note
			count += 1
		}
	}
	return last, count
}

// What the engine holds for userID (under its mutex).
@(private = "file")
voiceKeyTestEngineKeys :: proc(state: ^State, userID: int) -> (VoiceEngineSpeakerKeys, bool) {
	engine := state.voice.engine
	sync.mutex_lock(&engine.keyMutex)
	defer sync.mutex_unlock(&engine.keyMutex)
	for keys in engine.speakerKeys[:engine.speakerKeyCount] {
		if int(keys.userID) == userID {
			return keys, true
		}
	}
	return {}, false
}

@(private = "file")
voiceKeyTestSendKey :: proc(state: ^State) -> VoiceEngineKey {
	engine := state.voice.engine
	sync.mutex_lock(&engine.keyMutex)
	defer sync.mutex_unlock(&engine.keyMutex)
	return engine.sendKey
}

@(test)
testVoiceKeysJoinSealsToTheLogAndTheListenerAccepts :: proc(t: ^testing.T) {
	if !voiceTestOpusAvailable(t) {
		return
	}
	voiceKeyTestBegin()
	defer voiceKeyTestEnd()
	defer free_all(context.temp_allocator)
	trio := voiceKeyTestTrio()
	defer voiceKeyTestTrioDeinit(&trio)
	alice, bob, carol := &trio.alice, &trio.bob, &trio.carol

	// carol has no verified log: she cannot join, and is told why.
	voiceKeyTestListRoom(carol, 2)
	assert(
		!State_joinVoice(carol, VOICE_KEY_TEST_SERVER, VOICE_KEY_TEST_ROOM) &&
		carol.voice.lastError == VOICE_E2EE_SETTING_UP_NOTE,
		fmt.tprintf("expected carol held back, got %q", carol.voice.lastError),
	)
	assert(voiceKeyTestCount(.Join, VOICE_KEY_TEST_CAROL) == 0, "expected no join from carol")

	// alice joins: an encrypted engine, and generation 0 of a new session sealed to bob only.
	voiceKeyTestJoin(alice, VOICE_KEY_TEST_ALICE)
	assert(alice.voice.encrypted && alice.voice.engine.config.encryption.enabled, "encrypted")
	sent := voiceKeyTestLastKey(VOICE_KEY_TEST_ALICE)
	assert(
		sent.request.roomID == VOICE_KEY_TEST_ROOM &&
		sent.request.epoch == 2 &&
		sent.request.generation == 0 &&
		sent.request.createdAt == VOICE_KEY_TEST_NOW_MS / 1000,
		fmt.tprintf("expected generation 0 at epoch 2, got %v", sent.request),
	)
	decoded, decodeErr := common.decodeSealedEnvelope(sent.request.envelope)
	assert(
		decodeErr == .None &&
		decoded.kind == .VoiceKey &&
		decoded.wrapCount == 1 &&
		common.SealedEnvelope_wrap(decoded, 0).recipientUserID == VOICE_KEY_TEST_BOB,
		"expected one wrap, for bob: never alice herself, never carol (not a member)",
	)
	sendKey := voiceKeyTestSendKey(alice)
	assert(
		sendKey.set &&
		sendKey.generation == 0 &&
		sendKey.epoch == 2 &&
		sendKey.voiceSessionID == sent.request.voiceSessionID,
		"expected the engine to send under the key that went out",
	)
	note, sentCount := voiceKeyTestLastNote(alice, .Sent)
	assert(sentCount == 1 && note.rotation == .Join, "expected a join rotation noted")

	// bob joins and gets alice's key from the server: accepted and in his engine.
	voiceKeyTestJoin(bob, VOICE_KEY_TEST_ALICE, VOICE_KEY_TEST_BOB)
	voiceKeyTestDeliver(bob, sent)
	accepted, acceptedCount := voiceKeyTestLastNote(bob, .Accepted)
	assert(
		acceptedCount == 1 && accepted.userID == VOICE_KEY_TEST_ALICE && accepted.generation == 0,
		fmt.tprintf("expected bob to accept alice's key, got %v", bob.voice.e2ee.notes[:]),
	)
	keys, held := voiceKeyTestEngineKeys(bob, VOICE_KEY_TEST_ALICE)
	assert(
		held && keys.current.set && keys.current.generation == 0,
		"expected the key in bob's engine",
	)
	assert(
		keys.current.voiceSessionID == sent.request.voiceSessionID && keys.current.epoch == 2,
		"expected the AAD fields with the key",
	)
	aliceNote := State_voiceE2EEParticipantNote(
		bob,
		VOICE_KEY_TEST_SERVER,
		VOICE_KEY_TEST_ROOM,
		VOICE_KEY_TEST_ALICE,
	)
	assert(aliceNote == "", "expected no note on a participant whose key is held")
	// The same key again is a duplicate, not an error.
	voiceKeyTestDeliver(bob, sent)
	refused, _ := voiceKeyTestLastNote(bob, .Refused)
	assert(refused.refusal == .Duplicate, "expected the repeat refused as a duplicate")

	// Voice keys never reach the key store: nothing of the session in its file or config.
	assert(len(bob.voice.e2ee.speakers) >= 1, "expected bob to hold alice's key in memory")
	State_leaveVoice(bob)
	assert(len(bob.voice.e2ee.speakers) == 0 && !bob.voice.e2ee.active, "expected keys gone")
}

@(test)
testVoiceKeysRotateOnEveryTrigger :: proc(t: ^testing.T) {
	if !voiceTestOpusAvailable(t) {
		return
	}
	voiceKeyTestBegin()
	defer voiceKeyTestEnd()
	defer free_all(context.temp_allocator)
	trio := voiceKeyTestTrio()
	defer voiceKeyTestTrioDeinit(&trio)
	alice := &trio.alice

	voiceKeyTestJoin(alice, VOICE_KEY_TEST_ALICE, VOICE_KEY_TEST_BOB)
	first := voiceKeyTestLastKey(VOICE_KEY_TEST_ALICE)
	session := first.request.voiceSessionID

	// A reopened engine (a device change): same session, a new generation, never the old key.
	State_voiceRestartEngine(alice)
	restarted := voiceKeyTestLastKey(VOICE_KEY_TEST_ALICE)
	assert(
		restarted.request.generation == 1 && restarted.request.voiceSessionID == session,
		fmt.tprintf("expected generation 1 of the same session, got %v", restarted.request),
	)
	assert(voiceKeyTestSendKey(alice).generation == 1, "expected the new engine on generation 1")
	note, _ := voiceKeyTestLastNote(alice, .Sent)
	assert(note.rotation == .Engine, "expected an engine rotation")

	// The timer: nothing before the period, a new generation after it.
	State_voiceE2EETick(alice)
	assert(len(voiceKeyTestKeysFrom(VOICE_KEY_TEST_ALICE)) == 2, "expected no early rotation")
	alice.voice.e2ee.nowOverrideMS += i64(common.VOICE_KEY_ROTATE_SECONDS) * 1000
	State_voiceE2EETick(alice)
	timed := voiceKeyTestLastKey(VOICE_KEY_TEST_ALICE)
	assert(timed.request.generation == 2, "expected a timed rotation")
	note, _ = voiceKeyTestLastNote(alice, .Sent)
	assert(note.rotation == .Timer, "expected a timer rotation")

	// A member's request, at most once every 10 seconds; a non-member's is ignored.
	SERVER, ROOM :: VOICE_KEY_TEST_SERVER, VOICE_KEY_TEST_ROOM
	State_voiceE2EEReceiveRequest(alice, SERVER, ROOM, VOICE_KEY_TEST_BOB)
	assert(voiceKeyTestLastKey(VOICE_KEY_TEST_ALICE).request.generation == 3, "request rotation")
	State_voiceE2EEReceiveRequest(alice, SERVER, ROOM, VOICE_KEY_TEST_BOB)
	assert(len(voiceKeyTestKeysFrom(VOICE_KEY_TEST_ALICE)) == 4, "expected the limit to hold")
	alice.voice.e2ee.nowOverrideMS += 11_000
	State_voiceE2EEReceiveRequest(alice, SERVER, ROOM, VOICE_KEY_TEST_CAROL)
	assert(len(voiceKeyTestKeysFrom(VOICE_KEY_TEST_ALICE)) == 4, "expected carol ignored")

	// A new epoch (carol added): the old key leaves the engine, and the new one wraps carol.
	voiceKeyTestDeliverLog(alice, 2, 3, trio.log[2])
	epochKey := voiceKeyTestLastKey(VOICE_KEY_TEST_ALICE)
	assert(
		epochKey.request.epoch == 3 && epochKey.request.generation == 4,
		fmt.tprintf("expected generation 4 at epoch 3, got %v", epochKey.request),
	)
	decoded, _ := common.decodeSealedEnvelope(epochKey.request.envelope)
	_, wrapsCarol := common.SealedEnvelope_findWrap(decoded, VOICE_KEY_TEST_CAROL)
	_, wrapsBob := common.SealedEnvelope_findWrap(decoded, VOICE_KEY_TEST_BOB)
	assert(decoded.wrapCount == 2 && wrapsCarol && wrapsBob, "expected wraps for bob and carol")
	sendKey := voiceKeyTestSendKey(alice)
	assert(sendKey.epoch == 3 && sendKey.generation == 4, "expected the engine at epoch 3")
	note, _ = voiceKeyTestLastNote(alice, .Sent)
	assert(note.rotation == .Epoch, "expected an epoch rotation")

	// "Voice key is out of date": the key leaves the engine until the log moves on.
	State_voiceE2EEProtocolError(alice, VOICE_KEY_TEST_SERVER, common.VOICE_KEY_OUT_OF_DATE_MESSAGE)
	assert(!voiceKeyTestSendKey(alice).set, "expected no send key after an out-of-date refusal")
	assert(alice.voice.e2ee.rotatePending, "expected the rotation to wait for the log")
}

@(test)
testVoiceKeysListenerRefusesWhatTheRulesRefuse :: proc(t: ^testing.T) {
	if !voiceTestOpusAvailable(t) {
		return
	}
	voiceKeyTestBegin()
	defer voiceKeyTestEnd()
	defer free_all(context.temp_allocator)
	trio := voiceKeyTestTrio()
	defer voiceKeyTestTrioDeinit(&trio)
	alice, bob, carol := &trio.alice, &trio.bob, &trio.carol
	voiceKeyTestJoin(bob, VOICE_KEY_TEST_ALICE, VOICE_KEY_TEST_BOB)
	nowSeconds := VOICE_KEY_TEST_NOW_MS / 1000
	A :: VOICE_KEY_TEST_ALICE

	expectRefused :: proc(
		bob: ^State,
		sent: VoiceKeyTestSent,
		refusal: VoiceKeyRefusal,
		what: string,
	) {
		voiceKeyTestDeliver(bob, sent)
		note, _ := voiceKeyTestLastNote(bob, .Refused)
		last := bob.voice.e2ee.notes[len(bob.voice.e2ee.notes) - 1]
		assert(
			last.kind == .Refused && note.refusal == refusal,
			fmt.tprintf("%s: expected %v, got %v", what, refusal, last),
		)
	}
	expectAccepted :: proc(bob: ^State, sent: VoiceKeyTestSent, what: string) {
		voiceKeyTestDeliver(bob, sent)
		last := bob.voice.e2ee.notes[len(bob.voice.e2ee.notes) - 1]
		assert(last.kind == .Accepted, fmt.tprintf("%s: expected accepted, got %v", what, last))
	}

	// Signed with carol's identity in alice's name: alice's pin refuses it, finally.
	wrongPin := voiceKeyTestCraft(&trio, carol, A, 2, 1, 0, nowSeconds, bob)
	expectRefused(bob, wrongPin, .Failed, "wrong pin")
	// From carol, who is not a member of epoch 2.
	expectRefused(
		bob,
		voiceKeyTestCraft(&trio, carol, VOICE_KEY_TEST_CAROL, 2, 2, 0, nowSeconds, bob),
		.NotMember,
		"not a member",
	)
	// Too old, too new.
	old := nowSeconds - common.VOICE_KEY_MAX_AGE_SECONDS - 1
	expectRefused(bob, voiceKeyTestCraft(&trio, alice, A, 2, 3, 0, old, bob), .TooOld, "old")
	future := nowSeconds + common.VOICE_KEY_MAX_FUTURE_SECONDS + 1
	expectRefused(bob, voiceKeyTestCraft(&trio, alice, A, 2, 3, 0, future, bob), .TooNew, "future")
	clockNote := State_voiceE2EEParticipantNote(bob, VOICE_KEY_TEST_SERVER, VOICE_KEY_TEST_ROOM, A)
	assert(clockNote == VOICE_E2EE_CLOCK_NOTE, "expected the clock note on alice")
	// No wrap for bob.
	noWrap := voiceKeyTestCraft(&trio, alice, A, 2, 3, 0, nowSeconds, carol)
	expectRefused(bob, noWrap, .NoWrap, "no wrap")

	// A good key, then the generation rules within its session and against an older session.
	good := voiceKeyTestCraft(&trio, alice, A, 2, 4, 5, nowSeconds, bob)
	expectAccepted(bob, good, "session 4 gen 5")
	expectRefused(
		bob,
		voiceKeyTestCraft(&trio, alice, A, 2, 4, 4, nowSeconds, bob),
		.NotNewer,
		"a lower generation",
	)
	expectRefused(
		bob,
		voiceKeyTestCraft(&trio, alice, A, 2, 9, 0, nowSeconds - 1, bob),
		.NotNewer,
		"an older session",
	)
	expectAccepted(bob, voiceKeyTestCraft(&trio, alice, A, 2, 4, 6, nowSeconds, bob), "gen 6")
	keys, _ := voiceKeyTestEngineKeys(bob, A)
	assert(
		keys.current.generation == 6 && keys.previous.generation == 5,
		"expected the current and the previous key in the engine",
	)

	// A key for epoch 3 waits for bob's log, and is accepted once it arrives.
	epochThree := voiceKeyTestCraft(&trio, alice, A, 3, 4, 7, nowSeconds, bob)
	voiceKeyTestDeliver(bob, epochThree)
	assert(len(bob.voice.e2ee.pending) == 1, "expected the epoch 3 key held")
	voiceKeyTestDeliverLog(bob, 2, 3, trio.log[2])
	last := bob.voice.e2ee.notes[len(bob.voice.e2ee.notes) - 1]
	accepted, _ := voiceKeyTestLastNote(bob, .Accepted)
	assert(
		accepted.epoch == 3 && accepted.generation == 7,
		fmt.tprintf("expected epoch 3, got %v", last),
	)
	assert(len(bob.voice.e2ee.pending) == 0, "expected nothing held any more")

	// Within the grace an epoch 2 key of a newer session is still accepted; after it, refused,
	// and the old epoch's keys are wiped from the engine.
	expectAccepted(bob, voiceKeyTestCraft(&trio, alice, A, 2, 4, 8, nowSeconds, bob), "in grace")
	bob.voice.e2ee.nowOverrideMS += i64(common.VOICE_EPOCH_GRACE_SECONDS) * 1000
	State_voiceE2EETick(bob)
	keys, _ = voiceKeyTestEngineKeys(bob, A)
	assert(
		!keys.current.set || keys.current.epoch == 3,
		"expected epoch 2 keys wiped after the grace",
	)
	assert(
		!keys.previous.set || keys.previous.epoch == 3,
		"expected the previous epoch 2 key wiped too",
	)
	expectRefused(
		bob,
		voiceKeyTestCraft(&trio, alice, A, 2, 4, 9, nowSeconds + 10, bob),
		.OldEpoch,
		"after the grace",
	)
}

@(test)
testVoiceKeysListenerAsksOnceForAMissingKey :: proc(t: ^testing.T) {
	if !voiceTestOpusAvailable(t) {
		return
	}
	voiceKeyTestBegin()
	defer voiceKeyTestEnd()
	defer free_all(context.temp_allocator)
	trio := voiceKeyTestTrio()
	defer voiceKeyTestTrioDeinit(&trio)
	bob := &trio.bob
	voiceKeyTestJoin(bob, VOICE_KEY_TEST_ALICE, VOICE_KEY_TEST_BOB)

	State_voiceE2EETick(bob)
	assert(voiceKeyTestCount(.RequestKey, VOICE_KEY_TEST_BOB) == 0, "expected no request at once")
	note := State_voiceE2EEParticipantNote(
		bob,
		VOICE_KEY_TEST_SERVER,
		VOICE_KEY_TEST_ROOM,
		VOICE_KEY_TEST_ALICE,
	)
	assert(
		strings.has_prefix(note, "Waiting for "),
		fmt.tprintf("expected a waiting note: %q", note),
	)
	bob.voice.e2ee.nowOverrideMS += VOICE_KEY_MISSING_REQUEST_MS
	State_voiceE2EETick(bob)
	State_voiceE2EETick(bob)
	assert(voiceKeyTestCount(.RequestKey, VOICE_KEY_TEST_BOB) == 1, "expected exactly one request")
	for sent in voiceKeyTestSent {
		if sent.request.kind == .RequestKey {
			assert(sent.request.senderID == VOICE_KEY_TEST_ALICE, "expected alice asked")
		}
	}
}
