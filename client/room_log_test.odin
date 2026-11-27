package client

import "../common"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:testing"

// Client tests for encrypted rooms' member logs (protocol 18, room_log.odin, design 6.2, 12.3):
// alice (an admin) creates an encrypted room through the form's path, signs its Create entry,
// adds bob, and both clients replay and apply the log against their pins. A fake server that
// adds an unsigned member, rewrites a verified entry (fork), drops entries (rollback) or names
// another key is refused for good; the managers' rule, the key store head and the members
// view model are checked too.

ROOM_LOG_TEST_SERVER :: 974
ROOM_LOG_TEST_ALICE :: 31
ROOM_LOG_TEST_BOB :: 32
ROOM_LOG_TEST_CAROL :: 33
ROOM_LOG_TEST_ROOM :: 41

roomLogSendBridgeTestMutex: sync.Mutex

// What the stubbed bridge saw for ROOM_LOG_TEST_SERVER: appended entries (owned copies) and
// the afterVersion of each fetch.
@(private = "file")
roomLogTestAppends: [dynamic][]u8
@(private = "file")
roomLogTestFetches: [dynamic]int

@(private = "file")
roomLogTestBridge :: proc(transport: ^ClientServerTransport, request: RoomLogRequest) -> bool {
	if transport.serverID != ROOM_LOG_TEST_SERVER {
		return false
	}
	switch request.kind {
	case .Append:
		entry := make([]u8, len(request.entry))
		copy(entry, request.entry)
		append(&roomLogTestAppends, entry)
	case .Fetch:
		append(&roomLogTestFetches, request.afterVersion)
	}
	return true
}

@(private = "file")
roomLogTestFetchBridge :: proc(transport: ^ClientServerTransport, userIDs: []int) -> bool {
	return transport.serverID == ROOM_LOG_TEST_SERVER
}

@(private = "file")
roomLogTestPublishBridge :: proc(
	transport: ^ClientServerTransport,
	bundle: common.EncryptionKeyBundle,
) -> bool {
	return transport.serverID == ROOM_LOG_TEST_SERVER
}

@(private = "file")
roomLogTestBegin :: proc() {
	sync.mutex_lock(&roomLogSendBridgeTestMutex)
	sync.mutex_lock(&roomAdminSendBridgeTestMutex)
	sync.mutex_lock(&e2eeSendBridgeTestMutex)
	roomLogSendBridge = roomLogTestBridge
	testRoomAdminUseStub()
	e2eeFetchBridge = roomLogTestFetchBridge
	e2eePublishBridge = roomLogTestPublishBridge
}

@(private = "file")
roomLogTestEnd :: proc() {
	roomLogTestClear()
	delete(roomLogTestAppends)
	roomLogTestAppends = nil
	delete(roomLogTestFetches)
	roomLogTestFetches = nil
	roomLogSendBridge = ClientServerTransport_sendRoomLogRequest
	testRoomAdminRestore()
	e2eeFetchBridge = ClientServerTransport_fetchUserKeys
	e2eePublishBridge = ClientServerTransport_publishEncryptionKey
	sync.mutex_unlock(&e2eeSendBridgeTestMutex)
	sync.mutex_unlock(&roomAdminSendBridgeTestMutex)
	sync.mutex_unlock(&roomLogSendBridgeTestMutex)
}

@(private = "file")
roomLogTestClear :: proc() {
	for entry in roomLogTestAppends {
		delete(entry)
	}
	clear(&roomLogTestAppends)
	clear(&roomLogTestFetches)
}

// The last appended entry, in the temp allocator.
@(private = "file")
roomLogTestLastAppend :: proc() -> []u8 {
	assert(len(roomLogTestAppends) > 0, "expected an entry to have been sent")
	last := roomLogTestAppends[len(roomLogTestAppends) - 1]
	entry := make([]u8, len(last), context.temp_allocator)
	copy(entry, last)
	return entry
}

// A connected state for selfUserID with serverKey pinned and fresh keys, in memory.
@(private = "file")
roomLogTestState :: proc(
	serverKey: common.IdentityPublicKeyBytes,
	selfUserID: int,
	isAdmin: bool,
) -> State {
	server := testDirectServer(ROOM_LOG_TEST_SERVER)
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
	testApplyConnectedAs(&state, ROOM_LOG_TEST_SERVER, selfUserID, isAdmin)
	return state
}

@(private = "file")
roomLogTestBundle :: proc(state: ^State, userID: int) -> common.UserKeyBundle {
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

// Pins every bundle in state (as the server's ServerUserKeys answer would).
@(private = "file")
roomLogTestPin :: proc(state: ^State, bundles: ..common.UserKeyBundle) {
	event := ClientTransportRuntimeEvent {
		kind     = .UserKeysReceived,
		serverID = ROOM_LOG_TEST_SERVER,
	}
	append(&event.userKeys, ..bundles)
	State_applyRuntimeEvent(state, &event)
	ClientTransportRuntimeEvent_deinit(&event)
}

// The user directory: the admins among users, each with a published bundle.
@(private = "file")
roomLogTestDirectory :: proc(state: ^State, admins: []int, users: ..int) {
	event := ClientTransportRuntimeEvent {
		kind     = .UserListReceived,
		serverID = ROOM_LOG_TEST_SERVER,
	}
	for userID in users {
		isAdmin := false
		for admin in admins {
			isAdmin = isAdmin || admin == userID
		}
		append(
			&event.users,
			common.UserSummary {
				id = userID,
				nickname = strings.clone(roomLogTestName(userID)),
				isAdmin = isAdmin,
				// Every account published a bundle, as the server reports it.
				hasEncryptionKey = true,
			},
		)
	}
	State_applyRuntimeEvent(state, &event)
	ClientTransportRuntimeEvent_deinit(&event)
}

@(private = "file")
roomLogTestName :: proc(userID: int) -> string {
	switch userID {
	case ROOM_LOG_TEST_ALICE:
		return "alice"
	case ROOM_LOG_TEST_BOB:
		return "bob"
	case ROOM_LOG_TEST_CAROL:
		return "carol"
	}
	return "erin"
}

// The encrypted room as the server lists it.
@(private = "file")
roomLogTestListRoom :: proc(state: ^State, logVersion: int, member: bool) {
	event := ClientTransportRuntimeEvent {
		kind     = .RoomListReceived,
		serverID = ROOM_LOG_TEST_SERVER,
	}
	append(
		&event.rooms,
		common.RoomSummary {
			id = common.GENERAL_ROOM_ID,
			name = strings.clone("general"),
			description = strings.clone(""),
			roomType = .ChatAndVoice,
			access = .Public,
			historyVisibility = .Full,
		},
	)
	if member {
		append(
			&event.rooms,
			common.RoomSummary {
				id = ROOM_LOG_TEST_ROOM,
				name = strings.clone("secret"),
				description = strings.clone(""),
				roomType = .ChatAndVoice,
				access = .AdminInvite,
				historyVisibility = .FromJoin,
				encrypted = true,
				logVersion = logVersion,
			},
		)
	}
	State_applyRuntimeEvent(state, &event)
	ClientTransportRuntimeEvent_deinit(&event)
}

// Applies ServerRoomLog with entries (copied) after afterVersion.
@(private = "file")
roomLogTestDeliver :: proc(state: ^State, afterVersion, headVersion: int, entries: ..[]u8) {
	event := ClientTransportRuntimeEvent {
		kind            = .RoomLogReceived,
		serverID        = ROOM_LOG_TEST_SERVER,
		roomID          = ROOM_LOG_TEST_ROOM,
		logAfterVersion = afterVersion,
		logHeadVersion  = headVersion,
	}
	for entry in entries {
		copied := make([]u8, len(entry))
		copy(copied, entry)
		append(&event.logEntries, copied)
	}
	State_applyRuntimeEvent(state, &event)
	ClientTransportRuntimeEvent_deinit(&event)
}

// ServerCreateRoom for the encrypted room (version 0, no members yet).
@(private = "file")
roomLogTestCreated :: proc(state: ^State) {
	event := ClientTransportRuntimeEvent {
		kind = .RoomCreated,
		serverID = ROOM_LOG_TEST_SERVER,
		room = {
			id = ROOM_LOG_TEST_ROOM,
			name = strings.clone("secret"),
			description = strings.clone(""),
			roomType = .ChatAndVoice,
			access = .AdminInvite,
			historyVisibility = .FromJoin,
			encrypted = true,
		},
	}
	State_applyRuntimeEvent(state, &event)
	ClientTransportRuntimeEvent_deinit(&event)
}

@(private = "file")
roomLogTestStatus :: proc(state: ^State) -> RoomLogStatus {
	if room := State_findRoomLog(state, ROOM_LOG_TEST_SERVER, ROOM_LOG_TEST_ROOM); room != nil {
		return room.status
	}
	return .Unknown
}

// alice creates the room and signs Create; returns the Create entry (temp).
@(private = "file")
roomLogTestCreateRoom :: proc(alice: ^State) -> []u8 {
	errorMessage := State_sendCreateRoom(
		alice,
		ROOM_LOG_TEST_SERVER,
		"secret",
		"",
		.ChatAndVoice,
		.AdminInvite,
		.FromJoin,
		true,
		true,
		nil,
	)
	assert(len(errorMessage) == 0, fmt.tprintf("expected the create to go out: %s", errorMessage))
	assert(
		roomAdminSendBridgeTestCount == 1 && roomAdminSendBridgeTestKind == .Create,
		"expected ClientCreateRoom sent at once (alice is the only manager)",
	)
	roomLogTestCreated(alice)
	return roomLogTestLastAppend()
}

@(test)
testRoomLogCreateAddAndReplay :: proc(t: ^testing.T) {
	roomLogTestBegin()
	defer roomLogTestEnd()
	defer free_all(context.temp_allocator)
	_, serverKey, _ := common.generateIdentityKeyPair()
	alice := roomLogTestState(serverKey, ROOM_LOG_TEST_ALICE, true)
	defer State_deinit(&alice)
	bob := roomLogTestState(serverKey, ROOM_LOG_TEST_BOB, false)
	defer State_deinit(&bob)
	roomLogTestDirectory(&alice, {ROOM_LOG_TEST_ALICE}, ROOM_LOG_TEST_ALICE, ROOM_LOG_TEST_BOB)
	roomLogTestDirectory(&bob, {ROOM_LOG_TEST_ALICE}, ROOM_LOG_TEST_ALICE, ROOM_LOG_TEST_BOB)
	aliceBundle := roomLogTestBundle(&alice, ROOM_LOG_TEST_ALICE)
	bobBundle := roomLogTestBundle(&bob, ROOM_LOG_TEST_BOB)

	create := roomLogTestCreateRoom(&alice)
	managers: [common.ROOM_LOG_MANAGERS_MAX]common.RoomLogManager
	decoded, decodeErr := common.decodeRoomLogEntry(create, managers[:])
	assert(
		decodeErr == .None &&
		decoded.action == .Create &&
		decoded.roomID == ROOM_LOG_TEST_ROOM &&
		decoded.version == 1 &&
		decoded.actorUserID == ROOM_LOG_TEST_ALICE &&
		decoded.settings.access == .AdminInvite &&
		decoded.settings.creatorJoins &&
		len(decoded.settings.managers) == 1,
		fmt.tprintf("expected alice's Create with herself as manager, got %v", decoded),
	)
	// The server's echo verifies against alice's own key.
	roomLogTestDeliver(&alice, 0, 1, create)
	verified := State_roomLogVerified(&alice, ROOM_LOG_TEST_SERVER, ROOM_LOG_TEST_ROOM)
	assert(
		verified != nil &&
		verified.version == 1 &&
		common.RoomLogState_isMember(verified^, ROOM_LOG_TEST_ALICE) &&
		common.RoomLogState_isManager(verified^, ROOM_LOG_TEST_ALICE),
		"expected alice's verified log at version 1 with her as member and manager",
	)
	head := KeyStore_roomHead(alice.e2ee[0].store, ROOM_LOG_TEST_ROOM)
	assert(head.version == 1, "expected the verified head in alice's key store")

	// Adding bob needs his pin: the add waits for it, then goes out.
	assert(
		len(State_addRoomMember(&alice, ROOM_LOG_TEST_SERVER, ROOM_LOG_TEST_ROOM,
			ROOM_LOG_TEST_BOB)) == 0,
		"expected the add queued",
	)
	assert(len(roomLogTestAppends) == 1, "expected nothing sent before bob's key arrived")
	roomLogTestPin(&alice, bobBundle)
	assert(len(roomLogTestAppends) == 2, "expected the add sent once bob was pinned")
	add := roomLogTestLastAppend()
	roomLogTestDeliver(&alice, 1, 2, add)
	assert(
		State_roomLogEpoch(&alice, ROOM_LOG_TEST_SERVER, ROOM_LOG_TEST_ROOM) == 2,
		"expected alice at epoch 2",
	)

	// bob, with nothing verified, fetches the whole log when the room is listed, replays it
	// against his pins (alice pinned on first use), and stores the head.
	roomLogTestPin(&bob, aliceBundle)
	roomLogTestListRoom(&bob, 2, true)
	assert(
		len(roomLogTestFetches) > 0 && roomLogTestFetches[len(roomLogTestFetches) - 1] == 0,
		"expected bob to fetch the whole log",
	)
	roomLogTestDeliver(&bob, 0, 2, create, add)
	bobLog := State_roomLogVerified(&bob, ROOM_LOG_TEST_SERVER, ROOM_LOG_TEST_ROOM)
	assert(
		bobLog != nil &&
		bobLog.version == 2 &&
		common.RoomLogState_isMember(bobLog^, ROOM_LOG_TEST_BOB),
		"expected bob's verified log to name him a member",
	)
	room := State_findRoomLog(&bob, ROOM_LOG_TEST_SERVER, ROOM_LOG_TEST_ROOM)
	assert(len(room.events) == 2, "expected one event line per entry")
	assert(
		State_roomLogEventText(&bob, ROOM_LOG_TEST_SERVER, room.events[1]) == "alice added bob",
		fmt.tprintf("expected the add's line, got %q",
			State_roomLogEventText(&bob, ROOM_LOG_TEST_SERVER, room.events[1])),
	)
	// A duplicate of the head is ignored.
	roomLogTestDeliver(&bob, 1, 2, add)
	assert(roomLogTestStatus(&bob) == .Verified, "expected a duplicate head to change nothing")

	// bob is a member but not a manager of an Admin invite room: nothing to add, leave allowed.
	rights := roomLogRights(&bob, ROOM_LOG_TEST_SERVER, ROOM_LOG_TEST_ROOM)
	assert(
		!rights.canAdd && rights.canLeave && !rights.canManageManagers,
		fmt.tprintf("expected bob to leave but not add, got %v", rights),
	)

	// The encrypted room takes sealed messages (protocol 19) and encrypted voice (protocol 21).
	assert(
		State_roomAllowsChat(&bob, ROOM_LOG_TEST_SERVER, ROOM_LOG_TEST_ROOM) &&
		State_roomAllowsVoice(&bob, ROOM_LOG_TEST_SERVER, ROOM_LOG_TEST_ROOM),
		"expected chat and voice on in an encrypted room",
	)
}

@(test)
testRoomLogRefusesWhatTheServerForges :: proc(t: ^testing.T) {
	roomLogTestBegin()
	defer roomLogTestEnd()
	defer free_all(context.temp_allocator)
	_, serverKey, _ := common.generateIdentityKeyPair()
	alice := roomLogTestState(serverKey, ROOM_LOG_TEST_ALICE, true)
	defer State_deinit(&alice)
	carol := roomLogTestState(serverKey, ROOM_LOG_TEST_CAROL, false)
	defer State_deinit(&carol)
	roomLogTestDirectory(&alice, {ROOM_LOG_TEST_ALICE}, ROOM_LOG_TEST_ALICE, ROOM_LOG_TEST_CAROL)
	create := roomLogTestCreateRoom(&alice)
	roomLogTestDeliver(&alice, 0, 1, create)
	head := KeyStore_roomHead(alice.e2ee[0].store, ROOM_LOG_TEST_ROOM)

	// An unsigned Add of carol, written by the server: refused for good.
	carolBundle := roomLogTestBundle(&carol, ROOM_LOG_TEST_CAROL)
	forged := common.RoomLogEntry {
		roomID            = ROOM_LOG_TEST_ROOM,
		version           = 2,
		prevHash          = head.hash,
		action            = .Add,
		targetUserID      = ROOM_LOG_TEST_CAROL,
		targetIdentityKey = carolBundle.identityPublicKey,
		createdAt         = 1,
	}
	buffer: [common.ROOM_LOG_ENTRY_MAX_BYTES]u8
	n, err := common.encodeRoomLogEntry(forged, buffer[:])
	assert(err == .None, "expected the forged entry to encode")
	roomLogTestDeliver(&alice, 1, 2, buffer[:n])
	room := State_findRoomLog(&alice, ROOM_LOG_TEST_SERVER, ROOM_LOG_TEST_ROOM)
	assert(
		room.status == .Failed && room.failure == .Unsigned,
		fmt.tprintf("expected the unsigned add refused, got %v %v", room.status, room.failure),
	)
	assert(
		alice.chat_status_message == ROOM_LOG_CHANGED_WARNING,
		"expected the member-list warning",
	)
	// Nothing is signed or fetched any more, and later entries change nothing.
	sentBefore := len(roomLogTestAppends)
	fetchesBefore := len(roomLogTestFetches)
	errorMessage, _ := State_roomLogAppend(
		&alice,
		ROOM_LOG_TEST_SERVER,
		ROOM_LOG_TEST_ROOM,
		.Leave,
	)
	assert(errorMessage == ROOM_LOG_CHANGED_WARNING, "expected signing refused")
	roomLogTestListRoom(&alice, 3, true)
	assert(
		len(roomLogTestAppends) == sentBefore && len(roomLogTestFetches) == fetchesBefore,
		"expected a failed log never to be fetched or signed again",
	)
	view := buildRoomView(&alice)
	_ = view
	alice.selected_channel_id = ROOM_LOG_TEST_ROOM
	view = buildRoomView(&alice)
	assert(
		!view.allowsChat && view.logFailed && view.voiceOnlyNote == ROOM_LOG_CHANGED_WARNING,
		"expected the room's composer replaced by the warning",
	)
}

@(test)
testRoomLogDetectsForksRollbacksAndKeySwaps :: proc(t: ^testing.T) {
	roomLogTestBegin()
	defer roomLogTestEnd()
	defer free_all(context.temp_allocator)
	_, serverKey, _ := common.generateIdentityKeyPair()
	alice := roomLogTestState(serverKey, ROOM_LOG_TEST_ALICE, true)
	defer State_deinit(&alice)
	bob := roomLogTestState(serverKey, ROOM_LOG_TEST_BOB, false)
	defer State_deinit(&bob)
	carol := roomLogTestState(serverKey, ROOM_LOG_TEST_CAROL, false)
	defer State_deinit(&carol)
	roomLogTestDirectory(&alice, {ROOM_LOG_TEST_ALICE}, ROOM_LOG_TEST_ALICE, ROOM_LOG_TEST_BOB,
		ROOM_LOG_TEST_CAROL)
	bobBundle := roomLogTestBundle(&bob, ROOM_LOG_TEST_BOB)
	carolBundle := roomLogTestBundle(&carol, ROOM_LOG_TEST_CAROL)
	aliceBundle := roomLogTestBundle(&alice, ROOM_LOG_TEST_ALICE)
	roomLogTestPin(&alice, bobBundle, carolBundle)

	create := roomLogTestCreateRoom(&alice)
	roomLogTestDeliver(&alice, 0, 1, create)
	State_addRoomMember(&alice, ROOM_LOG_TEST_SERVER, ROOM_LOG_TEST_ROOM, ROOM_LOG_TEST_BOB)
	addBob := roomLogTestLastAppend()
	roomLogTestDeliver(&alice, 1, 2, addBob)

	// bob verifies versions 1-2 and stores the head.
	roomLogTestPin(&bob, aliceBundle)
	roomLogTestListRoom(&bob, 2, true)
	roomLogTestDeliver(&bob, 0, 2, create, addBob)
	assert(roomLogTestStatus(&bob) == .Verified, "expected bob to verify the log")
	storedHead := KeyStore_roomHead(bob.e2ee[0].store, ROOM_LOG_TEST_ROOM)
	assert(storedHead.version == 2, "expected bob's head stored at version 2")

	// A fresh session for bob (same key store) gets a log whose version 2 is another entry.
	{
		roomLogTestClear()
		State_removeServerRoomLogs(&bob, ROOM_LOG_TEST_SERVER)
		// alice signs a different version 2 (an AddManager of bob) the server could present.
		roomLogTestClear()
		State_findRoomLog(&alice, ROOM_LOG_TEST_SERVER, ROOM_LOG_TEST_ROOM).state.version = 1
		State_findRoomLog(&alice, ROOM_LOG_TEST_SERVER, ROOM_LOG_TEST_ROOM).state.headHash =
			common.hashRoomLogEntry(create)
		delete_key(
			&State_findRoomLog(&alice, ROOM_LOG_TEST_SERVER, ROOM_LOG_TEST_ROOM).state.members,
			ROOM_LOG_TEST_BOB,
		)
		errorMessage, _ := State_roomLogAppend(
			&alice,
			ROOM_LOG_TEST_SERVER,
			ROOM_LOG_TEST_ROOM,
			.AddManager,
			ROOM_LOG_TEST_BOB,
		)
		assert(len(errorMessage) == 0, fmt.tprintf("expected a second version 2: %s", errorMessage))
		fork := roomLogTestLastAppend()
		roomLogTestListRoom(&bob, 2, true)
		roomLogTestDeliver(&bob, 0, 2, create, fork)
		room := State_findRoomLog(&bob, ROOM_LOG_TEST_SERVER, ROOM_LOG_TEST_ROOM)
		assert(
			room.status == .Failed && room.failure == .Fork,
			fmt.tprintf("expected a fork, got %v %v", room.status, room.failure),
		)
	}
	// Another fresh session gets only version 1: a rollback.
	{
		State_removeServerRoomLogs(&bob, ROOM_LOG_TEST_SERVER)
		roomLogTestListRoom(&bob, 1, true)
		room := State_findRoomLog(&bob, ROOM_LOG_TEST_SERVER, ROOM_LOG_TEST_ROOM)
		assert(room != nil && room.status == .Loading, "expected a whole-log fetch")
		roomLogTestDeliver(&bob, 0, 1, create)
		room = State_findRoomLog(&bob, ROOM_LOG_TEST_SERVER, ROOM_LOG_TEST_ROOM)
		assert(
			room.status == .Failed && room.failure == .Rollback,
			fmt.tprintf("expected a rollback, got %v %v", room.status, room.failure),
		)
	}
	// carol pinned alice under another key: alice's Create does not verify for her.
	{
		_, otherKey, _ := common.generateIdentityKeyPair()
		swapped := aliceBundle
		swapped.identityPublicKey = otherKey
		KeyStore_setPin(
			&carol.e2ee[0].store,
			KeyPin{userID = ROOM_LOG_TEST_ALICE, identityPublicKey = otherKey},
		)
		roomLogTestListRoom(&carol, 1, true)
		roomLogTestDeliver(&carol, 0, 1, create)
		room := State_findRoomLog(&carol, ROOM_LOG_TEST_SERVER, ROOM_LOG_TEST_ROOM)
		assert(
			room.status == .Failed && room.failure == .PinMismatch,
			fmt.tprintf("expected a pin mismatch, got %v %v", room.status, room.failure),
		)
	}
}

@(test)
testRoomLogManagersAndTheMembersPage :: proc(t: ^testing.T) {
	roomLogTestBegin()
	defer roomLogTestEnd()
	defer free_all(context.temp_allocator)
	_, serverKey, _ := common.generateIdentityKeyPair()
	ERIN :: 34
	alice := roomLogTestState(serverKey, ROOM_LOG_TEST_ALICE, true)
	defer State_deinit(&alice)
	erin := roomLogTestState(serverKey, ERIN, true)
	defer State_deinit(&erin)
	bob := roomLogTestState(serverKey, ROOM_LOG_TEST_BOB, false)
	defer State_deinit(&bob)
	admins := []int{ROOM_LOG_TEST_ALICE, ERIN}
	roomLogTestDirectory(&alice, admins, ROOM_LOG_TEST_ALICE, ROOM_LOG_TEST_BOB, ERIN)
	roomLogTestDirectory(&erin, admins, ROOM_LOG_TEST_ALICE, ROOM_LOG_TEST_BOB, ERIN)
	aliceBundle := roomLogTestBundle(&alice, ROOM_LOG_TEST_ALICE)
	erinBundle := roomLogTestBundle(&erin, ERIN)
	bobBundle := roomLogTestBundle(&bob, ROOM_LOG_TEST_BOB)

	// The form lists every admin as a manager; erin is not pinned yet, so the create waits.
	candidates := State_roomLogAdminCandidates(&alice, ROOM_LOG_TEST_SERVER)
	assert(
		len(candidates) == 2 && candidates[0] == ROOM_LOG_TEST_ALICE && candidates[1] == ERIN,
		fmt.tprintf("expected alice then erin, got %v", candidates),
	)
	errorMessage := State_sendCreateRoom(
		&alice,
		ROOM_LOG_TEST_SERVER,
		"secret",
		"",
		.ChatAndVoice,
		.AdminInvite,
		.FromJoin,
		false,
		true,
		{ERIN},
	)
	assert(len(errorMessage) == 0, errorMessage)
	assert(roomAdminSendBridgeTestCount == 0, "expected the create to wait for erin's key")
	roomLogTestPin(&alice, erinBundle, bobBundle)
	assert(roomAdminSendBridgeTestCount == 1, "expected the create sent once erin was pinned")
	roomLogTestCreated(&alice)
	create := roomLogTestLastAppend()
	roomLogTestDeliver(&alice, 0, 1, create)
	verified := State_roomLogVerified(&alice, ROOM_LOG_TEST_SERVER, ROOM_LOG_TEST_ROOM)
	assert(
		verified != nil &&
		len(verified.members) == 0 &&
		common.RoomLogState_isManager(verified^, ROOM_LOG_TEST_ALICE) &&
		common.RoomLogState_isManager(verified^, ERIN),
		"expected a room without members managed by alice and erin",
	)

	// erin, a manager who is not a member, adds bob; it shows as "erin added bob".
	roomLogTestPin(&erin, aliceBundle, bobBundle)
	roomLogTestListRoom(&erin, 1, false)
	{
		// erin is an admin, so her list of every room includes it.
		event := ClientTransportRuntimeEvent {
			kind     = .AdminRoomsReceived,
			serverID = ROOM_LOG_TEST_SERVER,
		}
		append(
			&event.adminRooms,
			common.AdminRoomSummary {
				room = {
					id = ROOM_LOG_TEST_ROOM,
					name = strings.clone("secret"),
					description = strings.clone(""),
					roomType = .ChatAndVoice,
					access = .AdminInvite,
					historyVisibility = .FromJoin,
					encrypted = true,
					logVersion = 1,
				},
			},
		)
		State_applyRuntimeEvent(&erin, &event)
		ClientTransportRuntimeEvent_deinit(&event)
	}
	roomLogTestDeliver(&erin, 0, 1, create)
	assert(roomLogTestStatus(&erin) == .Verified, "expected erin to verify the log")
	assert(
		len(State_addRoomMember(&erin, ROOM_LOG_TEST_SERVER, ROOM_LOG_TEST_ROOM,
			ROOM_LOG_TEST_BOB)) == 0,
		"expected erin's add sent",
	)
	add := roomLogTestLastAppend()
	roomLogTestDeliver(&erin, 1, 2, add)
	roomLogTestDeliver(&alice, 1, 2, add)
	erinLog := State_findRoomLog(&erin, ROOM_LOG_TEST_SERVER, ROOM_LOG_TEST_ROOM)
	assert(
		State_roomLogEventText(&erin, ROOM_LOG_TEST_SERVER, erinLog.events[1]) == "erin added bob",
		"expected erin's add as an event line",
	)

	// alice removes erin as a manager: erin, still an admin, may no longer add, and is told
	// whom to ask.
	errorMessage, _ = State_roomLogAppend(
		&alice,
		ROOM_LOG_TEST_SERVER,
		ROOM_LOG_TEST_ROOM,
		.RemoveManager,
		ERIN,
	)
	assert(len(errorMessage) == 0, errorMessage)
	removeManager := roomLogTestLastAppend()
	roomLogTestDeliver(&erin, 2, 3, removeManager)
	roomLogTestDeliver(&alice, 2, 3, removeManager)
	rights := roomLogRights(&erin, ROOM_LOG_TEST_SERVER, ROOM_LOG_TEST_ROOM)
	assert(
		!rights.canAdd && rights.addNote == "Only this room's managers can add members; ask alice.",
		fmt.tprintf("expected erin told to ask alice, got %v", rights),
	)
	errorMessage, _ = State_roomLogAppend(
		&erin,
		ROOM_LOG_TEST_SERVER,
		ROOM_LOG_TEST_ROOM,
		.Add,
		ROOM_LOG_TEST_ALICE,
	)
	assert(
		errorMessage == "Only this room's managers can add members; ask alice.",
		fmt.tprintf("expected the local refusal, got %q", errorMessage),
	)
	// As an admin who is not a manager erin's removal goes to the server (unsigned Remove).
	assert(
		rights.canRemove && rights.removeViaServer,
		"expected erin to remove through the server",
	)

	// The Members page lists the log's members, its managers and the admins apart.
	State_resetRoomEditor(&alice, .Members, ROOM_LOG_TEST_SERVER, ROOM_LOG_TEST_ROOM)
	view := buildRoomMembersView(&alice)
	assert(
		view.encrypted &&
		len(view.members) == 1 &&
		view.members[0].userID == ROOM_LOG_TEST_BOB &&
		len(view.managers) == 1 &&
		view.managers[0].userID == ROOM_LOG_TEST_ALICE &&
		!view.managers[0].canRemoveManager &&
		len(view.admins) == 2 &&
		view.canAdd,
		fmt.tprintf("expected bob, manager alice (the last one) and two admins, got %v", view),
	)
	assert(view.members[0].keyState == "Not verified", "expected bob's key state shown")
}

// The server's unsigned entry of action on target after state's verified head (temp).
@(private = "file")
roomLogTestServerEntry :: proc(
	state: ^State,
	action: common.RoomLogAction,
	target: common.UserKeyBundle,
) -> []u8 {
	verified := State_roomLogVerified(state, ROOM_LOG_TEST_SERVER, ROOM_LOG_TEST_ROOM)
	assert(verified != nil, "expected a verified log to follow")
	entry := common.RoomLogEntry {
		roomID            = ROOM_LOG_TEST_ROOM,
		version           = verified.version + 1,
		prevHash          = verified.headHash,
		action            = action,
		targetUserID      = target.userId,
		targetIdentityKey = target.identityPublicKey,
		createdAt         = 1,
	}
	buffer: [common.ROOM_LOG_ENTRY_MAX_BYTES]u8
	n, err := common.encodeRoomLogEntry(entry, buffer[:])
	assert(err == .None, "expected the server's entry to encode")
	data := make([]u8, n, context.temp_allocator)
	copy(data, buffer[:n])
	return data
}

// Protocol 33 (#195): a ban of the room's only manager. bob replays the server's Remove and
// RemoveManager of alice (one ServerRoomLog), keeps the room with no manager, may still talk,
// and is told nobody can add.
@(test)
testRoomLogServerRemovesTheLastManager :: proc(t: ^testing.T) {
	roomLogTestBegin()
	defer roomLogTestEnd()
	defer free_all(context.temp_allocator)
	_, serverKey, _ := common.generateIdentityKeyPair()
	alice := roomLogTestState(serverKey, ROOM_LOG_TEST_ALICE, true)
	defer State_deinit(&alice)
	bob := roomLogTestState(serverKey, ROOM_LOG_TEST_BOB, false)
	defer State_deinit(&bob)
	roomLogTestDirectory(&alice, {ROOM_LOG_TEST_ALICE}, ROOM_LOG_TEST_ALICE, ROOM_LOG_TEST_BOB)
	roomLogTestDirectory(&bob, {ROOM_LOG_TEST_ALICE}, ROOM_LOG_TEST_ALICE, ROOM_LOG_TEST_BOB)
	aliceBundle := roomLogTestBundle(&alice, ROOM_LOG_TEST_ALICE)
	bobBundle := roomLogTestBundle(&bob, ROOM_LOG_TEST_BOB)

	create := roomLogTestCreateRoom(&alice)
	roomLogTestDeliver(&alice, 0, 1, create)
	roomLogTestPin(&alice, bobBundle)
	assert(
		len(State_addRoomMember(&alice, ROOM_LOG_TEST_SERVER, ROOM_LOG_TEST_ROOM,
			ROOM_LOG_TEST_BOB)) == 0,
		"expected alice's add sent",
	)
	add := roomLogTestLastAppend()
	roomLogTestPin(&bob, aliceBundle)
	roomLogTestListRoom(&bob, 2, true)
	roomLogTestDeliver(&bob, 0, 2, create, add)
	assert(roomLogTestStatus(&bob) == .Verified, "expected bob to verify the log")

	// The ban: alice out of the members, then out of the managers. The RemoveManager follows
	// the Remove's hash, worked out on a replay of its own.
	removeCopy := roomLogTestServerEntry(&bob, .Remove, aliceBundle)
	scratch := common.RoomLogState_init(ROOM_LOG_TEST_ROOM)
	defer common.RoomLogState_deinit(&scratch)
	ctx := common.RoomLogContext {
		serverIdentityPublicKey = serverKey,
	}
	for entry in ([][]u8{create, add, removeCopy}) {
		_, err := common.RoomLogState_apply(&scratch, entry, ctx)
		assert(err == .None, fmt.tprintf("expected the scratch replay, got %v", err))
	}
	demotion := common.RoomLogEntry {
		roomID            = ROOM_LOG_TEST_ROOM,
		version           = 4,
		prevHash          = scratch.headHash,
		action            = .RemoveManager,
		targetUserID      = ROOM_LOG_TEST_ALICE,
		targetIdentityKey = aliceBundle.identityPublicKey,
		createdAt         = 1,
	}
	buffer: [common.ROOM_LOG_ENTRY_MAX_BYTES]u8
	n, encodeErr := common.encodeRoomLogEntry(demotion, buffer[:])
	assert(encodeErr == .None, "expected the RemoveManager to encode")
	roomLogTestDeliver(&bob, 2, 4, removeCopy, buffer[:n])

	room := State_findRoomLog(&bob, ROOM_LOG_TEST_SERVER, ROOM_LOG_TEST_ROOM)
	assert(
		room.status == .Verified &&
		room.state.version == 4 &&
		len(room.state.managers) == 0 &&
		len(room.state.members) == 1 &&
		common.RoomLogState_isMember(room.state, ROOM_LOG_TEST_BOB),
		fmt.tprintf("expected bob alone with no manager at version 4, got %v %v", room.status,
			room.failure),
	)
	assert(
		State_roomLogEventText(&bob, ROOM_LOG_TEST_SERVER, room.events[3]) ==
		"the server removed alice as a manager",
		fmt.tprintf("expected the server's line, got %q",
			State_roomLogEventText(&bob, ROOM_LOG_TEST_SERVER, room.events[3])),
	)
	assert(
		KeyStore_roomHead(bob.e2ee[0].store, ROOM_LOG_TEST_ROOM).version == 4,
		"expected the new head stored",
	)

	// bob still talks, may leave, and adds nobody.
	assert(
		State_roomAllowsChat(&bob, ROOM_LOG_TEST_SERVER, ROOM_LOG_TEST_ROOM),
		"expected chat still allowed",
	)
	rights := roomLogRights(&bob, ROOM_LOG_TEST_SERVER, ROOM_LOG_TEST_ROOM)
	assert(
		!rights.canAdd &&
		rights.canLeave &&
		!rights.canManageManagers &&
		rights.addNote == ROOM_LOG_NO_MANAGER_NOTE,
		fmt.tprintf("expected bob to leave but not add, and told why, got %v", rights),
	)
	sentBefore := len(roomLogTestAppends)
	errorMessage, _ := State_roomLogAppend(
		&bob,
		ROOM_LOG_TEST_SERVER,
		ROOM_LOG_TEST_ROOM,
		.Add,
		ROOM_LOG_TEST_ALICE,
	)
	assert(
		errorMessage == ROOM_LOG_NO_MANAGER_NOTE && len(roomLogTestAppends) == sentBefore,
		fmt.tprintf("expected the add refused locally, got %q", errorMessage),
	)
	State_resetRoomEditor(&bob, .Members, ROOM_LOG_TEST_SERVER, ROOM_LOG_TEST_ROOM)
	view := buildRoomMembersView(&bob)
	assert(
		view.encrypted &&
		len(view.managers) == 0 &&
		len(view.members) == 1 &&
		!view.canAdd &&
		view.addNote == ROOM_LOG_NO_MANAGER_NOTE,
		fmt.tprintf("expected the Members page with no manager, got %v", view),
	)
}
