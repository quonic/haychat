package client

// Voice state and actions (voice-rooms-design.md 5.1). The UI thread owns all of it. Voice is
// active on at most one server at a time; the server is the source of truth for who is in
// voice (ServerVoiceParticipants), and the client never shows itself joined before the server
// lists it.
//
//   Idle ──State_joinVoice──▶ Joining ──participants that list this user──▶ Joined
//   Joining ──VoiceJoinRejected──▶ Idle (want cleared, lastError = reason)
//   Joined ──VoiceLeft / room deleted──▶ Idle (want cleared, lastError = reason)
//   Joining/Joined ──Disconnected──▶ Idle (want kept) ──Connected──▶ Joining (re-join)
//
// One voice session per user (protocol 13): a join the user asked for (State_joinVoice) takes
// voice over from this account's other device, which gets VoiceLeft "joined voice on another
// device". The re-join on Connected is sent with rejoin set and the profile's device ID, and
// the server refuses it with "voice is active on another device" while another device is in
// voice, so coming back from a network drop never pulls voice away from the device the user
// moved to. Both reasons end in Idle with the want cleared and show in the voice bar.
//   Joined ──engine cannot start──▶ Unavailable (want cleared, leave sent; chat unaffected)
//
// Encrypted rooms (protocol 21, voice_e2ee.odin): voice is end to end encrypted. A join needs
// the room's verified member log and this profile's encryption key (State_voiceE2EEJoinBlocker);
// the engine is created sealing and opening (VoiceEngineConfig.encryption), and every engine
// start makes a new voice key generation.
//
// The engine runs only while Joined. Starting it binds it to the server's transport
// (voice_network.odin), and stopping clears that binding under the worker lock before the
// engine is destroyed, so the worker and the voice thread never use a freed engine.

import "../common"
import "core:fmt"
import "core:strings"
import "core:time"
import "hotkey"
import "opus"

VoiceSessionStatus :: enum u8 {
	Idle, // not in voice; wantVoiceRoomID may still ask for a re-join on the next Connected
	Joining, // ClientJoinVoice sent, waiting for a participant list that lists this user
	Joined, // the server listed this user and the engine runs
	Unavailable, // libopus or the audio device failed; lastError says why
}

// One room's voice participants as the server last listed them. Owned.
VoiceRoomParticipants :: struct {
	serverID:     int,
	roomID:       int,
	participants: [dynamic]common.VoiceParticipant,
}

ClientVoiceState :: struct {
	status:           VoiceSessionStatus,
	// Where voice is active, or wanted while waiting to re-join. 0 when not in voice.
	serverID:         int,
	roomID:           int,
	// The user's choices; they survive leaving and are sent with every join.
	muted:            bool,
	deafened:         bool,
	// Push-to-talk as the engine sees it: the window's key or the global hotkey
	// (State_voiceSyncPushToTalk). The harness and tests set it directly.
	pushToTalkHeld:   bool,
	// The push-to-talk key as the window's own key events last left it (app.odin).
	pushToTalkWindowHeld: bool,
	// Global push-to-talk (client/hotkey): owned, created by the GUI only, nil elsewhere.
	globalPushToTalk: ^hotkey.Monitor,
	// The monitor's report as of the last State_voiceSyncPushToTalk, for the settings view.
	globalReport:     hotkey.StatusReport,
	// Owned. Why voice last stopped or failed; empty after a successful join.
	lastError:        string,
	// Every room with anyone in voice, joined or not, on every server, for the sidebar.
	roomParticipants: [dynamic]VoiceRoomParticipants,
	// The room to re-join after a reconnect, on serverID. Cleared by a leave, a rejection, a
	// server-side removal, or an engine failure.
	wantVoiceRoomID:  int,
	// Non-nil only while Joined. engine's outbound userdata is link.
	engine:           ^VoiceEngine,
	link:             ^ClientVoiceLink,
	// The config each new engine starts from (its strings owned here). The GUI uses devices
	// and voice activity; tests and the harness swap in tone, file, silence and null.
	engineTemplate:   VoiceEngineConfig,
	// What the last frame showed of the engine-driven voice state (State_voiceVisualKey).
	drawnVisual:      VoiceVisualKey,
	// Protocol 21: the room voice is in (or wanted in) is encrypted, as RoomSummary said when it
	// was joined; it never changes, and a re-join after a reconnect keeps it. Its keys.
	encrypted:        bool,
	e2ee:             VoiceE2EEState,
}

VOICE_DEFAULT_ENGINE_TEMPLATE :: VoiceEngineConfig {
	source = {kind = .Device},
	sink = {kind = .Device},
	gateMode = .VoiceActivity,
}

VOICE_INVALID_ROOM_MESSAGE :: "invalid voice room"

VoiceRoomParticipants_deinit :: proc(entry: ^VoiceRoomParticipants) {
	for &participant in entry.participants {
		common.VoiceParticipant_deinit(&participant)
	}
	delete(entry.participants)
	entry^ = {}
}

@(private = "file")
VoiceEngineConfig_deleteStrings :: proc(config: ^VoiceEngineConfig) {
	delete(config.source.path)
	delete(config.source.deviceName)
	delete(config.sink.path)
	delete(config.sink.deviceName)
	config.source.path = ""
	config.source.deviceName = ""
	config.sink.path = ""
	config.sink.deviceName = ""
}

// Frees everything but the engine, which State_voiceShutdown stops first.
ClientVoiceState_deinit :: proc(voice: ^ClientVoiceState) {
	for &entry in voice.roomParticipants {
		VoiceRoomParticipants_deinit(&entry)
	}
	delete(voice.roomParticipants)
	delete(voice.lastError)
	VoiceEngineConfig_deleteStrings(&voice.engineTemplate)
	VoiceE2EEState_deinit(&voice.e2ee)
	voice^ = {}
}

@(private = "file")
ClientVoiceState_setError :: proc(voice: ^ClientVoiceState, message: string) {
	delete(voice.lastError)
	voice.lastError = strings.clone(message)
}

// Takes ownership of message^ and clears it.
@(private = "file")
ClientVoiceState_takeError :: proc(voice: ^ClientVoiceState, message: ^string) {
	delete(voice.lastError)
	voice.lastError = message^
	message^ = ""
}

// Sets the config new engines start from. Strings are cloned; the outbound seam is always
// replaced by the network send path. Takes effect at the next join. config may be a copy of
// the current template with one part changed: its strings are cloned before the old ones go.
State_setVoiceEngineTemplate :: proc(state: ^State, config: VoiceEngineConfig) {
	next := config
	next.source.path = strings.clone(config.source.path)
	next.source.deviceName = strings.clone(config.source.deviceName)
	next.sink.path = strings.clone(config.sink.path)
	next.sink.deviceName = strings.clone(config.sink.deviceName)
	next.onOutbound = nil
	next.outboundUserdata = nil
	VoiceEngineConfig_deleteStrings(&state.voice.engineTemplate)
	state.voice.engineTemplate = next
}

// The participants the server last listed for a room, or nil when nobody is in its voice.
// Borrowed until the next voice event.
State_voiceRoomParticipants :: proc(
	state: ^State,
	serverID, roomID: int,
) -> []common.VoiceParticipant {
	index := State_voiceRoomParticipantsIndex(state, serverID, roomID)
	if index < 0 {
		return nil
	}
	return state.voice.roomParticipants[index].participants[:]
}

@(private = "file")
State_voiceRoomParticipantsIndex :: proc(state: ^State, serverID, roomID: int) -> int {
	for entry, index in state.voice.roomParticipants {
		if entry.serverID == serverID && entry.roomID == roomID {
			return index
		}
	}
	return -1
}

@(private = "file")
State_voiceRemoveRoomParticipants :: proc(state: ^State, serverID, roomID: int) {
	if index := State_voiceRoomParticipantsIndex(state, serverID, roomID); index >= 0 {
		VoiceRoomParticipants_deinit(&state.voice.roomParticipants[index])
		ordered_remove(&state.voice.roomParticipants, index)
	}
}

@(private = "file")
State_voiceRemoveServerParticipants :: proc(state: ^State, serverID: int) {
	for index := len(state.voice.roomParticipants) - 1; index >= 0; index -= 1 {
		if state.voice.roomParticipants[index].serverID == serverID {
			VoiceRoomParticipants_deinit(&state.voice.roomParticipants[index])
			ordered_remove(&state.voice.roomParticipants, index)
		}
	}
}

// The engine's counters and speakers while Joined (for the voice bar and the harness).
State_voiceEngineSnapshot :: proc(state: ^State) -> (VoiceEngineSnapshot, bool) {
	if state.voice.engine == nil {
		return {}, false
	}
	return VoiceEngine_snapshot(state.voice.engine), true
}

// Whether the session is in voice or on its way in, so a leave or a state change must reach
// the server.
@(private = "file")
State_voiceIsActive :: proc(state: ^State) -> bool {
	return state.voice.status == .Joining || state.voice.status == .Joined
}

// Sends one voice control message on serverID. On failure the error is a temp string.
State_voiceSendControl :: proc(
	state: ^State,
	serverID: int,
	request: VoiceControlRequest,
) -> (
	sent: bool,
	sendError: string,
) {
	transportIndex := State_selectedTransportIndexForServerID(state^, serverID)
	if transportIndex < 0 {
		return false, "No server transport for voice"
	}
	if !State_isServerConnected(state, serverID) {
		return false, NOT_CONNECTED_MESSAGE
	}
	transport := &state.serverTransports[transportIndex]
	// The worker may replace lastError at any time, so copy it while holding the lock.
	ClientNetworkWorker_lock(state.networkWorker)
	sent = voiceControlSendBridge(transport, request)
	if !sent {
		sendError = strings.clone(transport.lastError, context.temp_allocator)
	}
	ClientNetworkWorker_unlock(state.networkWorker)
	if !sent && len(sendError) == 0 {
		sendError = "Failed to send the voice request"
	}
	return
}

// rejoin is true only for the automatic re-join after a reconnect (State_voiceConnected).
@(private = "file")
State_voiceSendJoin :: proc(
	state: ^State,
	serverID, roomID: int,
	rejoin: bool,
) -> (
	bool,
	string,
) {
	return State_voiceSendControl(
		state,
		serverID,
		VoiceControlRequest {
			kind = .Join,
			roomID = roomID,
			muted = state.voice.muted,
			deafened = state.voice.deafened,
			rejoin = rejoin,
			deviceID = state.config.device_id,
		},
	)
}

// Joins roomID's voice on serverID: leaves any current voice session first (on whichever
// server), sends ClientJoinVoice and waits in Joining. Returns false, with lastError set, when
// the request could not go out or voice cannot work here at all (no libopus).
State_joinVoice :: proc(state: ^State, serverID, roomID: int) -> bool {
	if roomID <= 0 {
		ClientVoiceState_setError(&state.voice, VOICE_INVALID_ROOM_MESSAGE)
		return false
	}
	if !State_isServerConnected(state, serverID) {
		ClientVoiceState_setError(&state.voice, NOT_CONNECTED_MESSAGE)
		return false
	}
	if State_voiceIsActive(state) || state.voice.wantVoiceRoomID != 0 {
		State_leaveVoice(state)
	}
	// Protocol 21: an encrypted room's voice needs its verified member list and this profile's
	// encryption key before anything goes out.
	encrypted := State_roomIsEncrypted(state, serverID, roomID)
	if encrypted {
		if blocker := State_voiceE2EEJoinBlocker(state, serverID, roomID); len(blocker) > 0 {
			if blocker == VOICE_E2EE_SETTING_UP_NOTE {
				State_requestRoomLog(state, serverID, roomID)
			}
			ClientVoiceState_setError(&state.voice, blocker)
			return false
		}
	}
	// Without libopus the engine can never start, so do not join the server's voice only to
	// leave it again.
	if !opus.load() {
		state.voice.status = .Unavailable
		ClientVoiceState_setError(
			&state.voice,
			fmt.tprintf("Voice unavailable: %s", opus.loadError()),
		)
		return false
	}
	sent, sendError := State_voiceSendJoin(state, serverID, roomID, rejoin = false)
	if !sent {
		state.voice.status = .Idle
		ClientVoiceState_setError(&state.voice, sendError)
		return false
	}
	state.voice.status = .Joining
	state.voice.serverID = serverID
	state.voice.roomID = roomID
	state.voice.wantVoiceRoomID = roomID
	state.voice.encrypted = encrypted
	ClientVoiceState_setError(&state.voice, "")
	return true
}

// Leaves voice: tells the server when the session is in voice, stops the engine, and forgets
// the re-join. Also clears an Unavailable error.
State_leaveVoice :: proc(state: ^State) {
	if State_voiceIsActive(state) {
		// A failed leave needs no retry: the server drops voice with the session anyway.
		_, _ = State_voiceSendControl(state, state.voice.serverID, {kind = .Leave})
	}
	State_voiceStopEngine(state)
	state.voice.status = .Idle
	state.voice.serverID = 0
	state.voice.roomID = 0
	state.voice.wantVoiceRoomID = 0
	ClientVoiceState_setError(&state.voice, "")
}

@(private = "file")
State_voiceSendState :: proc(state: ^State) {
	if !State_voiceIsActive(state) {
		return
	}
	sent, sendError := State_voiceSendControl(
		state,
		state.voice.serverID,
		VoiceControlRequest {
			kind = .State,
			muted = state.voice.muted,
			deafened = state.voice.deafened,
		},
	)
	if !sent {
		ClientVoiceState_setError(&state.voice, sendError)
	}
}

// Mute closes the engine's gate at once (no audio leaves after this call), then tells the
// server, which stops relaying the session's frames and shows it muted.
State_setVoiceMuted :: proc(state: ^State, muted: bool) {
	if state.voice.muted == muted {
		return
	}
	state.voice.muted = muted
	if state.voice.engine != nil {
		VoiceEngine_setMuted(state.voice.engine, muted)
	}
	State_voiceSendState(state)
}

// Deafen stops playback at once, then tells the server, which stops relaying to the session.
State_setVoiceDeafened :: proc(state: ^State, deafened: bool) {
	if state.voice.deafened == deafened {
		return
	}
	state.voice.deafened = deafened
	if state.voice.engine != nil {
		VoiceEngine_setDeafened(state.voice.engine, deafened)
	}
	State_voiceSendState(state)
}

// Records whether the push-to-talk key is held (the GUI sets it while its window has focus).
// The server is not told: the gate is local.
State_setVoicePushToTalk :: proc(state: ^State, held: bool) {
	state.voice.pushToTalkHeld = held
	if state.voice.engine != nil {
		VoiceEngine_setPushToTalk(state.voice.engine, held)
	}
}

// Creates and starts the engine for the joined room and binds it to the server's transport.
// On failure voice becomes Unavailable with the engine's error and the server is told to
// drop the session from voice; chat is unaffected.
// resumeSequence and resumeAt continue a stopped engine's media clock (see
// VoiceEngineConfig.resumeSequence); a fresh join leaves them zero. restart is set for
// State_voiceRestartEngine, which keeps an encrypted room's voice session (voice_e2ee.odin).
@(private = "file")
State_voiceStartEngine :: proc(
	state: ^State,
	resumeSequence: u32 = 0,
	resumeAt: time.Tick = {},
	restart := false,
) {
	serverID := state.voice.serverID
	transportIndex := State_selectedTransportIndexForServerID(state^, serverID)
	connectionIndex := State_serverConnectionIndex(state^, serverID)
	if transportIndex < 0 || connectionIndex < 0 {
		state.voice.status = .Unavailable
		state.voice.wantVoiceRoomID = 0
		ClientVoiceState_setError(&state.voice, "No server transport for voice")
		return
	}
	transport := &state.serverTransports[transportIndex]
	link := new(ClientVoiceLink)
	link.worker = state.networkWorker
	link.transport = transport
	link.roomID = state.voice.roomID

	config := state.voice.engineTemplate
	config.onOutbound = clientVoiceOutbound
	config.outboundUserdata = link
	config.resumeSequence = resumeSequence
	config.resumeSequenceAt = resumeAt
	// Protocol 21: an encrypted room's engine seals and opens every frame; once known as
	// encrypted, the room stays so (its flag never changes).
	state.voice.encrypted ||= State_roomIsEncrypted(state, serverID, state.voice.roomID)
	config.encryption = {}
	if state.voice.encrypted {
		encryption, reason, encryptionOK := State_voiceE2EEEngineEncryption(
			state,
			serverID,
			state.voice.roomID,
		)
		if !encryptionOK {
			free(link)
			ClientVoiceState_setError(&state.voice, reason)
			_, _ = State_voiceSendControl(state, serverID, {kind = .Leave})
			state.voice.status = .Unavailable
			state.voice.wantVoiceRoomID = 0
			return
		}
		config.encryption = encryption
	}
	engine := VoiceEngine_create(config)
	link.engine = engine
	VoiceEngine_setMuted(engine, state.voice.muted)
	VoiceEngine_setDeafened(engine, state.voice.deafened)
	VoiceEngine_setPushToTalk(engine, state.voice.pushToTalkHeld)
	// Per-user volumes and local mutes for this server (user_voice.odin), before the first
	// frame plays.
	State_voiceApplyUserVoice(state, engine, serverID)
	if !VoiceEngine_start(engine) {
		ClientVoiceState_setError(&state.voice, VoiceEngine_lastError(engine))
		VoiceEngine_destroy(engine)
		free(link)
		State_voiceE2EEEnd(state)
		_, _ = State_voiceSendControl(state, serverID, {kind = .Leave})
		state.voice.status = .Unavailable
		state.voice.wantVoiceRoomID = 0
		return
	}

	ClientNetworkWorker_lock(state.networkWorker)
	transport.voice = ClientTransportVoiceBinding {
		engine            = engine,
		roomID            = state.voice.roomID,
		sessionGeneration = state.serverConnections[connectionIndex].sessionGeneration,
	}
	ClientNetworkWorker_unlock(state.networkWorker)
	state.voice.engine = engine
	state.voice.link = link
	if config.encryption.enabled {
		State_voiceE2EEEngineStarted(state, restart)
	}
}

// Unbinds and destroys the engine. The binding is cleared under the worker lock first, so
// once the lock is released neither the worker nor the voice thread can reach the engine
// through the transport; VoiceEngine_destroy then joins the voice thread, and only after that
// is the link it sends through freed. Returns the stopped engine's next frameSequence and
// when it stopped, for State_voiceRestartEngine. An encrypted room's voice keys go with it,
// unless keepE2EE (a restart) keeps the voice session's keys for the next engine.
State_voiceStopEngine :: proc(
	state: ^State,
	keepE2EE := false,
) -> (
	nextSequence: u32,
	stoppedAt: time.Tick,
) {
	engine := state.voice.engine
	link := state.voice.link
	if !keepE2EE {
		State_voiceE2EEEnd(state)
	}
	if engine == nil {
		return
	}
	ClientNetworkWorker_lock(link.worker)
	if link.transport.voice.engine == engine {
		link.transport.voice = {}
	}
	ClientNetworkWorker_unlock(link.worker)
	VoiceEngine_stop(engine)
	nextSequence = VoiceEngine_nextSequence(engine)
	stoppedAt = time.tick_now()
	VoiceEngine_destroy(engine)
	free(link)
	state.voice.engine = nil
	state.voice.link = nil
	return
}

// Reopens the joined engine from the current template (a new device, or a device that came
// or went), keeping the session joined: the server is not told, and mute, deafen and
// push-to-talk carry over. If the new engine cannot start, voice becomes Unavailable exactly
// as on a join. The new engine continues the old one's frameSequence: listeners are still in
// its spurt, and a sender that started over at 0 would have its frames dropped as late until
// that spurt timed out.
State_voiceRestartEngine :: proc(state: ^State) {
	if state.voice.status != .Joined || state.voice.engine == nil {
		return
	}
	// The new engine gets a new voice key generation (voice_e2ee.odin), so no key is ever used
	// by two engines.
	nextSequence, stoppedAt := State_voiceStopEngine(state, keepE2EE = true)
	State_voiceStartEngine(state, nextSequence, stoppedAt, restart = true)
}

// Stops the engine without telling the server, for shutdown.
State_voiceShutdown :: proc(state: ^State) {
	State_voiceStopEngine(state)
	if State_voiceIsActive(state) {
		state.voice.status = .Idle
	}
}

// Before the network stops for a transport rebuild (State_reconfigureNetwork): leave the
// server's voice, since the session itself may survive the rebuild, and keep the want so
// State_voiceResumeAfterReconfigure can join again.
State_voiceSuspendForReconfigure :: proc(state: ^State) {
	if State_voiceIsActive(state) {
		_, _ = State_voiceSendControl(state, state.voice.serverID, {kind = .Leave})
	}
	State_voiceShutdown(state)
}

// After a transport rebuild: forget voice on a server that is gone, and re-join on one whose
// session survived (a server that reconnects re-joins on its Connected event instead).
State_voiceResumeAfterReconfigure :: proc(state: ^State) {
	for index := len(state.voice.roomParticipants) - 1; index >= 0; index -= 1 {
		entry := &state.voice.roomParticipants[index]
		if _, ok := State_serverConfig(state, entry.serverID); !ok {
			VoiceRoomParticipants_deinit(entry)
			ordered_remove(&state.voice.roomParticipants, index)
		}
	}
	if state.voice.serverID == 0 {
		return
	}
	if _, ok := State_serverConfig(state, state.voice.serverID); !ok {
		State_leaveVoice(state)
		return
	}
	if State_isServerConnected(state, state.voice.serverID) {
		State_voiceConnected(state, state.voice.serverID)
	}
}

// Takes ownership of participants^ (it is cleared). Replaces the room's list; an empty list
// removes it. A list for the room being joined completes the join only when the server says
// this session is in it (recipientJoined): a list that merely names this user may be about the
// same account on another device, or may have been sent before the server processed the join.
// A list saying this session is not in voice never ends a joined session: the server sends
// ServerVoiceLeft for every removal, and a list from before a quick leave and re-join of the
// same room would otherwise undo the re-join.
State_receiveVoiceParticipants :: proc(
	state: ^State,
	serverID, roomID: int,
	participants: ^[dynamic]common.VoiceParticipant,
	recipientJoined: bool,
) {
	State_voiceRemoveRoomParticipants(state, serverID, roomID)
	if len(participants) > 0 {
		append(
			&state.voice.roomParticipants,
			VoiceRoomParticipants {
				serverID = serverID,
				roomID = roomID,
				participants = participants^,
			},
		)
	} else {
		delete(participants^)
	}
	participants^ = nil

	if state.voice.status == .Joining &&
	   state.voice.serverID == serverID &&
	   state.voice.roomID == roomID &&
	   recipientJoined {
		state.voice.status = .Joined
		State_voiceStartEngine(state)
	}
}

// ServerVoiceJoinRejected for the voice room: back to Idle with the server's reason. Takes
// ownership of reason^ when it applies. It also ends a session that already counts as Joined:
// after a quick leave and re-join of the same room, a list sent before the leave can complete
// the re-join before the server has accepted it, and the server's refusal must still win.
State_voiceJoinRejected :: proc(state: ^State, serverID, roomID: int, reason: ^string) {
	if (state.voice.status != .Joining && state.voice.status != .Joined) ||
	   state.voice.serverID != serverID ||
	   state.voice.roomID != roomID {
		return
	}
	State_voiceStopEngine(state)
	state.voice.status = .Idle
	state.voice.serverID = 0
	state.voice.roomID = 0
	state.voice.wantVoiceRoomID = 0
	ClientVoiceState_takeError(&state.voice, reason)
}

// ServerVoiceLeft: the server removed this session from voice (removed from the room, the
// room was deleted, the session joined another room, or another device of this account joined
// voice). Takes ownership of reason^ when it applies to the current voice room. The want is
// cleared, so a voice session taken over by another device is never re-joined from here.
State_voiceLeft :: proc(state: ^State, serverID, roomID: int, reason: ^string) {
	if !State_voiceIsActive(state) ||
	   state.voice.serverID != serverID ||
	   state.voice.roomID != roomID {
		return
	}
	State_voiceStopEngine(state)
	state.voice.status = .Idle
	state.voice.serverID = 0
	state.voice.roomID = 0
	state.voice.wantVoiceRoomID = 0
	ClientVoiceState_takeError(&state.voice, reason)
}

// A room went away (deleted, or this account left it): its participants go, and so does
// voice in it. The server sends ServerVoiceLeft first; this covers a client that missed it.
State_voiceRoomRemoved :: proc(state: ^State, serverID, roomID: int) {
	State_voiceRemoveRoomParticipants(state, serverID, roomID)
	if state.voice.serverID == serverID && state.voice.roomID == roomID {
		State_leaveVoice(state)
	}
}

// The session on serverID ended (lost, or an attempt failed). Voice does not survive a
// session on the server, so the engine stops and every participant list from that server is
// dropped (the next room list brings fresh ones), but the want stays for the re-join.
State_voiceConnectionLost :: proc(state: ^State, serverID: int) {
	State_voiceRemoveServerParticipants(state, serverID)
	if state.voice.serverID != serverID {
		return
	}
	State_voiceStopEngine(state)
	if State_voiceIsActive(state) {
		state.voice.status = .Idle
	}
}

// An admin kicked or banned this account on serverID (D4, D5): its session there ended for
// good, so voice is not re-joined when the user presses Retry later. Unlike a lost session,
// the want goes too, and voice there goes back to Idle on no server.
State_voiceEndedByAdmin :: proc(state: ^State, serverID: int) {
	if state.voice.serverID != serverID {
		return
	}
	State_voiceStopEngine(state)
	state.voice.status = .Idle
	state.voice.serverID = 0
	state.voice.roomID = 0
	state.voice.wantVoiceRoomID = 0
}

// A session on serverID was established: re-join the wanted room. The join is marked as
// automatic, so the server refuses it instead of taking voice from another device.
State_voiceConnected :: proc(state: ^State, serverID: int) {
	if state.voice.serverID != serverID ||
	   state.voice.wantVoiceRoomID == 0 ||
	   state.voice.status != .Idle {
		return
	}
	roomID := state.voice.wantVoiceRoomID
	sent, sendError := State_voiceSendJoin(state, serverID, roomID, rejoin = true)
	if !sent {
		// Keep the want: the next Connected tries again.
		ClientVoiceState_setError(&state.voice, sendError)
		return
	}
	state.voice.status = .Joining
	state.voice.roomID = roomID
}
