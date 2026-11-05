#+feature dynamic-literals
package client

import "../common"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:testing"
import "opus"

voiceControlSendBridgeTestMutex: sync.Mutex
VOICE_CONTROL_TEST_CAPACITY :: 16
voiceControlTestRequests: [VOICE_CONTROL_TEST_CAPACITY]VoiceControlRequest
voiceControlTestCount: int
voiceControlTestReturnValue: bool

voiceControlSendBridgeTestStub :: proc(
	transport: ^ClientServerTransport,
	request: VoiceControlRequest,
) -> bool {
	if voiceControlTestCount < VOICE_CONTROL_TEST_CAPACITY {
		voiceControlTestRequests[voiceControlTestCount] = request
	}
	voiceControlTestCount += 1
	return voiceControlTestReturnValue
}

// Swaps in the stub; call with the mutex held and run testVoiceControlRestore when done.
@(private = "file")
testVoiceControlUseStub :: proc() {
	voiceControlTestCount = 0
	voiceControlTestReturnValue = true
	voiceControlSendBridge = voiceControlSendBridgeTestStub
}

@(private = "file")
testVoiceControlRestore :: proc() {
	voiceControlSendBridge = ClientServerTransport_sendVoiceControl
}

// The last request sent, or a zero request when none was.
@(private = "file")
testVoiceLastRequest :: proc() -> VoiceControlRequest {
	if voiceControlTestCount == 0 || voiceControlTestCount > VOICE_CONTROL_TEST_CAPACITY {
		return {}
	}
	return voiceControlTestRequests[voiceControlTestCount - 1]
}

TEST_VOICE_SELF_USER_ID :: 3

// A state signed in as user 3 on serverID, whose engines use silence and a null sink, so a
// join starts a real (quiet) engine thread with no audio device.
@(private = "file")
testVoiceState :: proc(serverID: int) -> State {
	server := Server {
		id   = serverID,
		name = fmt.tprintf("Voice %d", serverID),
		host = "localhost",
		port = 1,
	}
	state := testUpdateStateForServer(server)
	testApplyConnected(&state, serverID, TEST_VOICE_SELF_USER_ID)
	State_setVoiceEngineTemplate(
		&state,
		{source = {kind = .Silence}, sink = {kind = .Null}, gateMode = .VoiceActivity},
	)
	return state
}

// A participant list as this session would get it when it is one of the participants
// whenever the list names this user, the common case of a single device.
@(private = "file")
testApplyVoiceParticipants :: proc(state: ^State, serverID, roomID: int, userIDs: ..int) {
	recipientJoined := false
	for userID in userIDs {
		if userID == TEST_VOICE_SELF_USER_ID {
			recipientJoined = true
		}
	}
	testApplyVoiceParticipantsFor(state, serverID, roomID, recipientJoined, ..userIDs)
}

// A participant list with the server's per-session flag given explicitly, for the case where
// the list names this user on another device (recipientJoined false).
@(private = "file")
testApplyVoiceParticipantsFor :: proc(
	state: ^State,
	serverID, roomID: int,
	recipientJoined: bool,
	userIDs: ..int,
) {
	event := ClientTransportRuntimeEvent {
		kind                 = .VoiceParticipants,
		serverID             = serverID,
		roomID               = roomID,
		voiceRecipientJoined = recipientJoined,
	}
	for userID in userIDs {
		append(
			&event.voiceParticipants,
			common.VoiceParticipant {
				userId = userID,
				nickname = strings.clone(fmt.tprintf("user-%d", userID)),
			},
		)
	}
	State_applyRuntimeEvent(state, &event)
	ClientTransportRuntimeEvent_deinit(&event)
}

@(private = "file")
testApplyVoiceReason :: proc(
	state: ^State,
	kind: ClientTransportRuntimeEventKind,
	serverID, roomID: int,
	reason: string,
) {
	event := ClientTransportRuntimeEvent {
		kind     = kind,
		serverID = serverID,
		roomID   = roomID,
		message  = strings.clone(reason),
	}
	State_applyRuntimeEvent(state, &event)
	ClientTransportRuntimeEvent_deinit(&event)
}

@(private = "file")
testApplyDisconnected :: proc(state: ^State, serverID: int) {
	event := ClientTransportRuntimeEvent {
		kind     = .Disconnected,
		serverID = serverID,
		message  = strings.clone("connection lost"),
	}
	State_applyRuntimeEvent(state, &event)
	ClientTransportRuntimeEvent_deinit(&event)
}

@(private = "file")
testVoiceTransportEngine :: proc(state: ^State, serverID: int) -> ^VoiceEngine {
	index := State_selectedTransportIndexForServerID(state^, serverID)
	return index < 0 ? nil : state.serverTransports[index].voice.engine
}

// Joining sends ClientJoinVoice and waits: only a participant list for that room that names
// this user makes it Joined and starts the engine, bound to the transport. Mute and deafen
// reach the engine and the server; leave tells the server and tears the engine down.
@(test)
testVoiceJoinMuteDeafenAndLeaveDriveTheState :: proc(t: ^testing.T) {
	if !voiceTestOpusAvailable(t) {
		return
	}
	state := testVoiceState(921)
	defer State_deinit(&state)
	sync.mutex_lock(&voiceControlSendBridgeTestMutex)
	defer sync.mutex_unlock(&voiceControlSendBridgeTestMutex)
	testVoiceControlUseStub()
	defer testVoiceControlRestore()

	testing.expect(t, State_joinVoice(&state, 921, 2), "expected the join to go out")
	join := testVoiceLastRequest()
	testing.expectf(
		t,
		voiceControlTestCount == 1 && join.kind == .Join && join.roomID == 2 && !join.muted,
		"expected ClientJoinVoice{2}, got %d requests, last %v",
		voiceControlTestCount,
		join,
	)
	testing.expect(
		t,
		state.voice.status == .Joining &&
		state.voice.serverID == 921 &&
		state.voice.roomID == 2 &&
		state.voice.wantVoiceRoomID == 2 &&
		state.voice.engine == nil,
		"expected Joining room 2 with no engine yet",
	)

	// Someone else's list for the room, and our own for another room, do not complete it.
	testApplyVoiceParticipants(&state, 921, 2, 9)
	testApplyVoiceParticipants(&state, 921, 5, TEST_VOICE_SELF_USER_ID)
	testing.expect(t, state.voice.status == .Joining, "expected to wait for a list naming us")
	testing.expect(
		t,
		len(State_voiceRoomParticipants(&state, 921, 2)) == 1 &&
		len(State_voiceRoomParticipants(&state, 921, 5)) == 1,
		"expected both rooms' participants kept for the sidebar",
	)

	testApplyVoiceParticipants(&state, 921, 2, 9, TEST_VOICE_SELF_USER_ID)
	testing.expect(
		t,
		state.voice.status == .Joined &&
		state.voice.engine != nil &&
		VoiceEngine_isRunning(state.voice.engine),
		"expected Joined with a running engine",
	)
	testing.expect(
		t,
		testVoiceTransportEngine(&state, 921) == state.voice.engine &&
		state.serverTransports[0].voice.roomID == 2,
		"expected the engine bound to the transport for room 2",
	)
	testing.expect(
		t,
		len(State_voiceRoomParticipants(&state, 921, 2)) == 2,
		"expected the new list to replace the old one",
	)

	State_setVoiceMuted(&state, true)
	muted := testVoiceLastRequest()
	testing.expect(
		t,
		voiceControlTestCount == 2 && muted.kind == .State && muted.muted && !muted.deafened,
		"expected ClientVoiceState{muted}",
	)
	testing.expect(
		t,
		sync.atomic_load(&state.voice.engine.muted),
		"expected the engine's gate muted at once",
	)
	State_setVoiceDeafened(&state, true)
	deafened := testVoiceLastRequest()
	testing.expect(
		t,
		voiceControlTestCount == 3 && deafened.kind == .State && deafened.muted &&
		deafened.deafened,
		"expected ClientVoiceState{muted, deafened}",
	)
	testing.expect(
		t,
		sync.atomic_load(&state.voice.engine.deafened),
		"expected the engine's playback deafened at once",
	)
	State_setVoiceMuted(&state, true)
	testing.expect(t, voiceControlTestCount == 3, "expected no request for an unchanged mute")

	State_leaveVoice(&state)
	testing.expect(
		t,
		voiceControlTestCount == 4 && testVoiceLastRequest().kind == .Leave,
		"expected ClientLeaveVoice",
	)
	testing.expect(
		t,
		state.voice.status == .Idle &&
		state.voice.engine == nil &&
		state.voice.wantVoiceRoomID == 0 &&
		testVoiceTransportEngine(&state, 921) == nil,
		"expected Idle with the engine unbound and gone",
	)
	// Mute and deafen are the user's choices: they stay, and nothing is sent while idle.
	State_setVoiceDeafened(&state, false)
	testing.expect(
		t,
		voiceControlTestCount == 4 && state.voice.muted && !state.voice.deafened,
		"expected local changes only while not in voice",
	)
	testing.expect(t, State_joinVoice(&state, 921, 2), "expected a second join")
	testing.expect(
		t,
		testVoiceLastRequest().kind == .Join && testVoiceLastRequest().muted,
		"expected the join to carry the mute",
	)

	// An empty list means nobody is left in that room's voice.
	testApplyVoiceParticipants(&state, 921, 5)
	testing.expect(
		t,
		State_voiceRoomParticipants(&state, 921, 5) == nil,
		"expected an empty list to remove the room's participants",
	)
}

// Joining another room leaves the current one first, on whichever server it is.
@(test)
testVoiceJoinLeavesTheCurrentRoomFirst :: proc(t: ^testing.T) {
	if !voiceTestOpusAvailable(t) {
		return
	}
	state := testVoiceState(922)
	defer State_deinit(&state)
	sync.mutex_lock(&voiceControlSendBridgeTestMutex)
	defer sync.mutex_unlock(&voiceControlSendBridgeTestMutex)
	testVoiceControlUseStub()
	defer testVoiceControlRestore()

	_ = State_joinVoice(&state, 922, 2)
	testApplyVoiceParticipants(&state, 922, 2, TEST_VOICE_SELF_USER_ID)
	testing.expect(t, state.voice.status == .Joined, "expected Joined in room 2")
	testing.expect(t, State_joinVoice(&state, 922, 4), "expected the switch to go out")
	testing.expectf(
		t,
		voiceControlTestCount == 3 &&
		voiceControlTestRequests[1].kind == .Leave &&
		voiceControlTestRequests[2].kind == .Join &&
		voiceControlTestRequests[2].roomID == 4,
		"expected Leave then Join{4}, got %d requests",
		voiceControlTestCount,
	)
	testing.expect(
		t,
		state.voice.status == .Joining &&
		state.voice.roomID == 4 &&
		state.voice.engine == nil &&
		testVoiceTransportEngine(&state, 922) == nil,
		"expected Joining room 4 with the old engine gone",
	)
	// The participant update for the old room that the server sends after the leave does
	// not touch the new join.
	testApplyVoiceParticipants(&state, 922, 2, 9)
	testing.expect(t, state.voice.status == .Joining, "expected still Joining room 4")
}

// A rejected join and a server-side removal end voice with the server's reason and clear the
// want, so a reconnect does not join again. A deleted room does the same.
@(test)
testVoiceRejectionRemovalAndDeletionClearTheWant :: proc(t: ^testing.T) {
	if !voiceTestOpusAvailable(t) {
		return
	}
	state := testVoiceState(923)
	defer State_deinit(&state)
	sync.mutex_lock(&voiceControlSendBridgeTestMutex)
	defer sync.mutex_unlock(&voiceControlSendBridgeTestMutex)
	testVoiceControlUseStub()
	defer testVoiceControlRestore()

	_ = State_joinVoice(&state, 923, 2)
	testApplyVoiceReason(&state, .VoiceJoinRejected, 923, 7, "not for this room")
	testing.expect(t, state.voice.status == .Joining, "expected a rejection for room 7 ignored")
	testApplyVoiceReason(&state, .VoiceJoinRejected, 923, 2, "voice room is full")
	testing.expectf(
		t,
		state.voice.status == .Idle &&
		state.voice.wantVoiceRoomID == 0 &&
		state.voice.serverID == 0 &&
		state.voice.lastError == "voice room is full",
		"expected Idle with the reason and no want, got %v %d %q",
		state.voice.status,
		state.voice.wantVoiceRoomID,
		state.voice.lastError,
	)

	_ = State_joinVoice(&state, 923, 2)
	testing.expect(t, state.voice.lastError == "", "expected a new join to clear the error")
	testApplyVoiceParticipants(&state, 923, 2, TEST_VOICE_SELF_USER_ID)
	testApplyVoiceReason(&state, .VoiceLeft, 923, 2, "removed from the room")
	testing.expect(
		t,
		state.voice.status == .Idle &&
		state.voice.wantVoiceRoomID == 0 &&
		state.voice.engine == nil &&
		testVoiceTransportEngine(&state, 923) == nil &&
		state.voice.lastError == "removed from the room",
		"expected the removal to stop the engine, clear the want and keep the reason",
	)

	// Deletion: ServerVoiceLeft arrives first, then ServerDeleteRoom; either alone ends it.
	_ = State_joinVoice(&state, 923, 3)
	testApplyVoiceParticipants(&state, 923, 3, TEST_VOICE_SELF_USER_ID, 9)
	testing.expect(t, state.voice.status == .Joined, "expected Joined in room 3")
	testApplyVoiceReason(&state, .VoiceLeft, 923, 3, "the room was deleted")
	testApplyRoomEvent(&state, .RoomDeleted, 923, 3)
	testing.expect(
		t,
		state.voice.status == .Idle &&
		state.voice.wantVoiceRoomID == 0 &&
		State_voiceRoomParticipants(&state, 923, 3) == nil &&
		state.voice.lastError == "the room was deleted",
		"expected the deleted room's voice and participants gone",
	)
	_ = State_joinVoice(&state, 923, 4)
	testApplyVoiceParticipants(&state, 923, 4, TEST_VOICE_SELF_USER_ID)
	testApplyRoomEvent(&state, .RoomDeleted, 923, 4)
	testing.expect(
		t,
		state.voice.status == .Idle && state.voice.engine == nil,
		"expected a deletion without ServerVoiceLeft to end voice too",
	)
}

// Losing the session stops the engine and drops that server's participant lists but keeps
// the want; the next Connected joins the same room again with the current mute and deafen.
@(test)
testVoiceReconnectRejoinsTheWantedRoom :: proc(t: ^testing.T) {
	if !voiceTestOpusAvailable(t) {
		return
	}
	state := testVoiceState(924)
	defer State_deinit(&state)
	sync.mutex_lock(&voiceControlSendBridgeTestMutex)
	defer sync.mutex_unlock(&voiceControlSendBridgeTestMutex)
	testVoiceControlUseStub()
	defer testVoiceControlRestore()

	_ = State_joinVoice(&state, 924, 2)
	testApplyVoiceParticipants(&state, 924, 2, TEST_VOICE_SELF_USER_ID, 9)
	testApplyVoiceParticipants(&state, 924, 6, 9)
	State_setVoiceDeafened(&state, true)
	testing.expect(t, state.voice.status == .Joined, "expected Joined before the drop")

	testApplyDisconnected(&state, 924)
	testing.expect(
		t,
		state.voice.status == .Idle &&
		state.voice.engine == nil &&
		testVoiceTransportEngine(&state, 924) == nil &&
		state.voice.wantVoiceRoomID == 2 &&
		state.voice.serverID == 924,
		"expected the engine gone and the want kept",
	)
	testing.expect(
		t,
		State_voiceRoomParticipants(&state, 924, 2) == nil &&
		State_voiceRoomParticipants(&state, 924, 6) == nil,
		"expected the server's stale participant lists dropped",
	)
	requestsBefore := voiceControlTestCount
	testing.expect(
		t,
		!State_joinVoice(&state, 924, 5) && voiceControlTestCount == requestsBefore,
		"expected no join while disconnected",
	)
	testing.expect(
		t,
		state.voice.wantVoiceRoomID == 2,
		"expected a refused join to keep the want",
	)

	testApplyConnected(&state, 924, TEST_VOICE_SELF_USER_ID)
	rejoin := testVoiceLastRequest()
	testing.expectf(
		t,
		voiceControlTestCount == requestsBefore + 1 &&
		rejoin.kind == .Join &&
		rejoin.roomID == 2 &&
		rejoin.deafened,
		"expected Connected to re-join room 2 deafened, got %v",
		rejoin,
	)
	testing.expect(t, state.voice.status == .Joining, "expected Joining after the re-join")
	testApplyVoiceParticipants(&state, 924, 2, TEST_VOICE_SELF_USER_ID)
	testing.expect(
		t,
		state.voice.status == .Joined &&
		state.voice.engine != nil &&
		sync.atomic_load(&state.voice.engine.deafened),
		"expected Joined again with a new, deafened engine",
	)

	// After an explicit leave a reconnect joins nothing.
	State_leaveVoice(&state)
	testApplyDisconnected(&state, 924)
	requestsBefore = voiceControlTestCount
	testApplyConnected(&state, 924, TEST_VOICE_SELF_USER_ID)
	testing.expect(
		t,
		voiceControlTestCount == requestsBefore && state.voice.status == .Idle,
		"expected no re-join after a leave",
	)
}

// An engine that cannot open (here a file source that does not exist) makes voice
// Unavailable with the engine's error, leaves the server's voice, and leaves chat alone. A
// later join can try again.
@(test)
testVoiceIsUnavailableWhenTheEngineCannotStart :: proc(t: ^testing.T) {
	if !voiceTestOpusAvailable(t) {
		return
	}
	state := testVoiceState(925)
	defer State_deinit(&state)
	State_setVoiceEngineTemplate(
		&state,
		{source = {kind = .File, path = "/nonexistent/haychat-voice.f32"}, sink = {kind = .Null}},
	)
	sync.mutex_lock(&voiceControlSendBridgeTestMutex)
	defer sync.mutex_unlock(&voiceControlSendBridgeTestMutex)
	testVoiceControlUseStub()
	defer testVoiceControlRestore()

	_ = State_joinVoice(&state, 925, 2)
	testApplyVoiceParticipants(&state, 925, 2, TEST_VOICE_SELF_USER_ID)
	testing.expectf(
		t,
		state.voice.status == .Unavailable &&
		strings.contains(state.voice.lastError, "voice source") &&
		state.voice.engine == nil &&
		testVoiceTransportEngine(&state, 925) == nil &&
		state.voice.wantVoiceRoomID == 0,
		"expected Unavailable with the engine's error, got %v %q",
		state.voice.status,
		state.voice.lastError,
	)
	testing.expect(
		t,
		testVoiceLastRequest().kind == .Leave,
		"expected the server told to drop the session from voice",
	)
	testing.expect(t, State_isServerConnected(&state, 925), "expected chat to stay connected")

	State_setVoiceEngineTemplate(&state, {source = {kind = .Silence}, sink = {kind = .Null}})
	testing.expect(t, State_joinVoice(&state, 925, 2), "expected a retry from Unavailable")
	testApplyVoiceParticipants(&state, 925, 2, TEST_VOICE_SELF_USER_ID)
	testing.expect(
		t,
		state.voice.status == .Joined && state.voice.lastError == "",
		"expected the retry to join",
	)
}

// Joins need a connected server and a real room, and a join the transport refuses stays Idle
// with the transport's reason.
@(test)
testVoiceJoinNeedsAConnectionAndARoom :: proc(t: ^testing.T) {
	server := Server {
		id   = 926,
		name = "Voice Offline",
		host = "localhost",
		port = 1,
	}
	state := testUpdateStateForServer(server)
	defer State_deinit(&state)
	sync.mutex_lock(&voiceControlSendBridgeTestMutex)
	defer sync.mutex_unlock(&voiceControlSendBridgeTestMutex)
	testVoiceControlUseStub()
	defer testVoiceControlRestore()

	testing.expect(t, !State_joinVoice(&state, 926, 1), "expected no join while offline")
	testing.expect(
		t,
		state.voice.lastError == NOT_CONNECTED_MESSAGE && voiceControlTestCount == 0,
		"expected the not-connected reason and nothing sent",
	)
	testApplyConnected(&state, 926, TEST_VOICE_SELF_USER_ID)
	testing.expect(t, !State_joinVoice(&state, 926, 0), "expected room 0 refused")
	testing.expect(
		t,
		state.voice.lastError == VOICE_INVALID_ROOM_MESSAGE,
		"expected the invalid room reason",
	)

	voiceControlTestReturnValue = false
	joined := State_joinVoice(&state, 926, 1)
	// Without libopus the join stops before sending (Unavailable); with it the stub refuses.
	expectedRequests := opus.load() ? 1 : 0
	testing.expect(
		t,
		!joined &&
		voiceControlTestCount == expectedRequests &&
		(state.voice.status == .Idle || state.voice.status == .Unavailable) &&
		state.voice.wantVoiceRoomID == 0 &&
		len(state.voice.lastError) > 0,
		"expected a refused join to stay out of voice with a reason",
	)
}

// The participant list names user IDs, not sessions. While this device is joining, a list that
// names this account because of another device, and so says this session is not joined, must
// not complete the join; only the server's acknowledgement of this session's join does.
@(test)
testVoiceJoinWaitsForThisSessionsAcknowledgement :: proc(t: ^testing.T) {
	if !voiceTestOpusAvailable(t) {
		return
	}
	state := testVoiceState(925)
	defer State_deinit(&state)
	sync.mutex_lock(&voiceControlSendBridgeTestMutex)
	defer sync.mutex_unlock(&voiceControlSendBridgeTestMutex)
	testVoiceControlUseStub()
	defer testVoiceControlRestore()

	testing.expect(t, State_joinVoice(&state, 925, 2), "expected the join to go out")
	testApplyVoiceParticipantsFor(&state, 925, 2, false, TEST_VOICE_SELF_USER_ID)
	testing.expect(
		t,
		state.voice.status == .Joining && state.voice.engine == nil,
		"expected another device's list to leave this session Joining with no engine",
	)
	testing.expect(
		t,
		len(State_voiceRoomParticipants(&state, 925, 2)) == 1,
		"expected the other device kept in the room's participants for the sidebar",
	)

	testApplyVoiceParticipantsFor(
		&state,
		925,
		2,
		true,
		TEST_VOICE_SELF_USER_ID,
		TEST_VOICE_SELF_USER_ID,
	)
	testing.expect(
		t,
		state.voice.status == .Joined && state.voice.engine != nil,
		"expected this session's acknowledgement to complete the join",
	)

	// A later list that says this session is not joined does not end it: only ServerVoiceLeft
	// removes a joined session, so a stale list cannot undo a re-join.
	testApplyVoiceParticipantsFor(&state, 925, 2, false, TEST_VOICE_SELF_USER_ID)
	testing.expect(
		t,
		state.voice.status == .Joined && state.voice.engine != nil,
		"expected a list without this session to leave the joined session alone",
	)
	State_leaveVoice(&state)
}

// After a quick leave and re-join of the same room, a list sent before the leave can complete
// the re-join early. If the server then refuses the re-join, the refusal still ends the session.
@(test)
testVoiceRejectionEndsASessionThatAlreadyCountsAsJoined :: proc(t: ^testing.T) {
	if !voiceTestOpusAvailable(t) {
		return
	}
	state := testVoiceState(926)
	defer State_deinit(&state)
	sync.mutex_lock(&voiceControlSendBridgeTestMutex)
	defer sync.mutex_unlock(&voiceControlSendBridgeTestMutex)
	testVoiceControlUseStub()
	defer testVoiceControlRestore()

	testing.expect(t, State_joinVoice(&state, 926, 2), "expected the join to go out")
	testApplyVoiceParticipants(&state, 926, 2, TEST_VOICE_SELF_USER_ID)
	testing.expect(
		t,
		state.voice.status == .Joined && state.voice.engine != nil,
		"expected the (stale) acknowledgement to count as joined",
	)

	testApplyVoiceReason(&state, .VoiceJoinRejected, 926, 2, "voice room is full")
	testing.expect(
		t,
		state.voice.status == .Idle &&
		state.voice.engine == nil &&
		state.voice.wantVoiceRoomID == 0 &&
		testVoiceTransportEngine(&state, 926) == nil,
		"expected the refusal to stop the engine, unbind it and clear the want",
	)
	testing.expectf(
		t,
		state.voice.lastError == "voice room is full",
		"expected the server's reason kept, got %q",
		state.voice.lastError,
	)

	// A refusal for another room changes nothing.
	testing.expect(t, State_joinVoice(&state, 926, 3), "expected a second join to go out")
	testApplyVoiceReason(&state, .VoiceJoinRejected, 926, 2, "stale refusal")
	testing.expect(
		t,
		state.voice.status == .Joining && state.voice.roomID == 3,
		"expected a refusal for another room to leave this join alone",
	)
	State_leaveVoice(&state)
}
