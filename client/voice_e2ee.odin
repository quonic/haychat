package client

import "../common"
import "core:crypto"
import "core:fmt"
import "core:slice"
import "core:time"

// End-to-end encrypted voice in encrypted rooms (protocol 21, e2ee-voice-design.md 3, 4 and 7):
// the UI thread's half. It makes this participant's voice keys, seals them to the verified
// log's members with their PINNED encryption keys, opens the other participants' keys with
// their PINNED identity keys, applies the freshness rules, and pushes the results into the
// voice engine (voice_engine.odin), which seals and opens the frames.
//
// Rules:
//
// - Speaking: a key is 32 random bytes per voice session (a random voiceSessionID per join)
//   and generation (one more on every rotation), sealed as one VoiceKey envelope with a wrap
//   for every member of the current epoch in the verified log whose pin matches the identity
//   the log names, this account excluded, and sent as ClientVoiceKey. The engine gets the key
//   only after the envelope went out, and frames wait until then. A new generation is made when
//   the join is acknowledged, whenever an engine is (re)opened (a device change), when the
//   verified log reaches a new epoch (the old key is cleared from the engine at once), every
//   VOICE_KEY_ROTATE_SECONDS, and on a member's ServerVoiceKeyRequest (at most once every
//   VOICE_KEY_REQUEST_INTERVAL_SECONDS). A member whose key is still being fetched holds the
//   rotation back until it arrives; one without a usable key gets no wrap and asks later.
// - Listening: a ServerVoiceKey is accepted only when the sender was a member of its epoch in
//   the verified log and is pinned with the identity the log names; the epoch is the verified
//   one (a later one waits for the log, an earlier one is refused unless the log moved on less
//   than VOICE_EPOCH_GRACE_SECONDS ago); its creation time is within VOICE_KEY_MAX_AGE_SECONDS
//   before and VOICE_KEY_MAX_FUTURE_SECONDS after this clock; it is newer than the last key
//   accepted from that sender (a higher generation of the same session, or a session made no
//   earlier); and the envelope opens with the sender's pin and this profile's key. Every
//   failure to open is final for that envelope. A listener keeps two keys per speaker (current
//   and previous); old-epoch keys go VOICE_EPOCH_GRACE_SECONDS after the epoch moved on. A
//   participant without a usable key for VOICE_KEY_MISSING_REQUEST_MS is asked once
//   (ClientRequestVoiceKey) and shown as "Waiting for <name>'s voice key".
// - Voice keys live only in memory, here and in the engine: never in the key store or
//   config.json. They are wiped when replaced, when voice ends, and when the engine stops.
// - The room's encryption decides, never the server: an engine started for an encrypted room
//   (RoomSummary.encrypted, which never changes) never sends or plays plaintext.

VOICE_KEY_MISSING_REQUEST_MS :: 2000
// Keys waiting for the log or a pin; a sender's newer key replaces its older one.
VOICE_E2EE_PENDING_MAX :: 64

VOICE_E2EE_ENCRYPTED_NOTE :: "Voice is end-to-end encrypted"
VOICE_E2EE_SETTING_UP_NOTE :: "Setting up encryption…"
VOICE_E2EE_WAITING_FORMAT :: "Waiting for %s's voice key"
VOICE_E2EE_CLOCK_NOTE :: "Clock out of sync"

// Why a voice key was refused (the harness's voice_key events name them).
VoiceKeyRefusal :: enum u8 {
	None,
	LogFailed, // the room's member log failed verification
	NotMember, // the sender was not a member of the key's epoch
	NoPin, // the sender is not pinned with the identity the log names
	OldEpoch, // an epoch before the verified one, after the grace
	TooOld, // made more than VOICE_KEY_MAX_AGE_SECONDS ago by this clock
	TooNew, // made more than VOICE_KEY_MAX_FUTURE_SECONDS ahead of this clock
	NotNewer, // not newer than the last key accepted from the sender
	NoWrap, // no wrap for this account (sealed before its key was known)
	Failed, // the envelope did not open (error says why); final
	Duplicate, // the key already accepted
}

VOICE_KEY_REFUSAL_NAMES := [VoiceKeyRefusal]string {
	.None      = "",
	.LogFailed = "log_failed",
	.NotMember = "not_member",
	.NoPin     = "no_pin",
	.OldEpoch  = "old_epoch",
	.TooOld    = "too_old",
	.TooNew    = "too_new",
	.NotNewer  = "not_newer",
	.NoWrap    = "no_wrap",
	.Failed    = "failed",
	.Duplicate = "duplicate",
}

// Why this participant made a new key.
VoiceKeyRotation :: enum u8 {
	Join,
	Engine, // a reopened engine (State_voiceRestartEngine)
	Epoch, // the verified log reached a new epoch
	Timer, // VOICE_KEY_ROTATE_SECONDS passed
	Request, // a member asked
	Keys, // a member's key arrived that the rotation waited for
}

VOICE_KEY_ROTATION_NAMES := [VoiceKeyRotation]string {
	.Join    = "join",
	.Engine  = "engine",
	.Epoch   = "epoch",
	.Timer   = "timer",
	.Request = "request",
	.Keys    = "keys",
}

// What the headless harness prints as voice_key events (recordNotes).
VoiceKeyNoteKind :: enum u8 {
	Sent, // this participant sent a new key (rotation says why)
	Accepted, // another participant's key was accepted
	Refused, // another participant's key was refused (refusal, error)
	Requested, // this participant asked userID for a key
	RequestReceived, // userID asked this participant for a key
}

VoiceKeyNote :: struct {
	kind:       VoiceKeyNoteKind,
	serverID:   int,
	roomID:     int,
	userID:     int, // the key's sender, or the requester
	epoch:      int,
	generation: u32,
	rotation:   VoiceKeyRotation,
	refusal:    VoiceKeyRefusal,
	error:      common.E2EEError,
}

VoiceE2EEKeyStats :: struct {
	sent:             u64,
	accepted:         u64,
	refused:          [VoiceKeyRefusal]u64,
	requestsSent:     u64,
	requestsReceived: u64,
}

// One accepted key of a speaker, in memory only.
VoiceE2EESpeakerKey :: struct {
	set:            bool,
	epoch:          int,
	voiceSessionID: common.VoiceSessionID,
	generation:     u32,
	createdAt:      i64,
	key:            common.VoiceKey,
}

VoiceE2EESpeaker :: struct {
	userID:           int,
	current:          VoiceE2EESpeakerKey,
	previous:         VoiceE2EESpeakerKey,
	// The last key accepted from this speaker in this voice session, which later keys must be
	// newer than; kept when the keys themselves are wiped.
	hasAccepted:      bool,
	acceptedSession:  common.VoiceSessionID,
	acceptedGen:      u32,
	acceptedAt:       i64,
	// Since when no usable key (0: one is held), and whether it was asked for since.
	missingSinceMS:   i64,
	requested:        bool,
	// The last refusal, for the participant's note ("Clock out of sync").
	lastRefusal:      VoiceKeyRefusal,
}

VoiceE2EEState :: struct {
	// Set while an encrypted room's engine runs (State_voiceE2EEEngineStarted).
	active:              bool,
	serverID:            int,
	roomID:              int,
	selfUserID:          int,
	// This participant's voice session and its next generation.
	voiceSessionID:      common.VoiceSessionID,
	nextGeneration:      u32,
	// The key the engine sends with now (none while hasSendKey is false), and when it was made.
	hasSendKey:          bool,
	sendEpoch:           int,
	sendGeneration:      u32,
	sendCreatedAtMS:     i64,
	// A rotation waits for the verified log or for members' keys.
	rotatePending:       bool,
	pendingRotation:     VoiceKeyRotation,
	// When this participant last rotated because a member asked (0: never).
	lastRequestRotateMS: i64,
	// The verified epoch this side has reached, when it did, and the epoch before it (for the
	// grace of 4.2). graceUntilMS is 0 when no grace runs.
	epoch:               int,
	graceEpoch:          int,
	graceUntilMS:        i64,
	speakers:            [dynamic]VoiceE2EESpeaker,
	// Keys that wait for the verified log or a pin (owned).
	pending:             [dynamic]common.ServerVoiceKeyPayload,
	stats:               VoiceE2EEKeyStats,
	// voice-key-rotate SECONDS (harness only): the rotation period; 0 is the default.
	rotateSeconds:       int,
	// Tests: a fixed clock in milliseconds since the Unix epoch (0: the real clock).
	nowOverrideMS:       i64,
	// The harness records notes and prints them as voice_key events.
	recordNotes:         bool,
	notes:               [dynamic]VoiceKeyNote,
}

@(private = "file")
VoiceE2EESpeakerKey_wipe :: proc(key: ^VoiceE2EESpeakerKey) {
	crypto.zero_explicit(key, size_of(key^))
}

@(private = "file")
VoiceE2EESpeaker_wipe :: proc(speaker: ^VoiceE2EESpeaker) {
	VoiceE2EESpeakerKey_wipe(&speaker.current)
	VoiceE2EESpeakerKey_wipe(&speaker.previous)
}

@(private = "file")
VoiceE2EEState_clearPending :: proc(e2ee: ^VoiceE2EEState) {
	for &payload in e2ee.pending {
		common.ServerVoiceKeyPayload_deinit(&payload)
	}
	clear(&e2ee.pending)
}

// Ends the voice session's keys: every key wiped, pending ones freed. Keeps the statistics, the
// harness settings and the notes.
VoiceE2EEState_reset :: proc(e2ee: ^VoiceE2EEState) {
	for &speaker in e2ee.speakers {
		VoiceE2EESpeaker_wipe(&speaker)
	}
	clear(&e2ee.speakers)
	VoiceE2EEState_clearPending(e2ee)
	crypto.zero_explicit(&e2ee.voiceSessionID, size_of(e2ee.voiceSessionID))
	e2ee.active = false
	e2ee.serverID = 0
	e2ee.roomID = 0
	e2ee.selfUserID = 0
	e2ee.nextGeneration = 0
	e2ee.hasSendKey = false
	e2ee.sendEpoch = 0
	e2ee.sendGeneration = 0
	e2ee.sendCreatedAtMS = 0
	e2ee.rotatePending = false
	e2ee.lastRequestRotateMS = 0
	e2ee.epoch = 0
	e2ee.graceEpoch = 0
	e2ee.graceUntilMS = 0
}

VoiceE2EEState_deinit :: proc(e2ee: ^VoiceE2EEState) {
	VoiceE2EEState_reset(e2ee)
	delete(e2ee.speakers)
	delete(e2ee.pending)
	delete(e2ee.notes)
	e2ee^ = {}
}

@(private = "file")
State_voiceE2EENote :: proc(state: ^State, note: VoiceKeyNote) {
	e2ee := &state.voice.e2ee
	if e2ee.recordNotes {
		append(&e2ee.notes, note)
	}
}

// Milliseconds since the Unix epoch by this client's clock (or the tests' fixed one).
State_voiceE2EENowMS :: proc(state: ^State) -> i64 {
	if state.voice.e2ee.nowOverrideMS != 0 {
		return state.voice.e2ee.nowOverrideMS
	}
	return time.to_unix_nanoseconds(time.now()) / 1_000_000
}

@(private = "file")
State_voiceE2EERotateMS :: proc(state: ^State) -> i64 {
	seconds := state.voice.e2ee.rotateSeconds
	if seconds <= 0 {
		seconds = common.VOICE_KEY_ROTATE_SECONDS
	}
	return i64(seconds) * 1000
}

// Whether voice on serverID, roomID is the encrypted session this file manages.
@(private = "file")
State_voiceE2EEIsActiveIn :: proc(state: ^State, serverID, roomID: int) -> bool {
	e2ee := &state.voice.e2ee
	return e2ee.active && e2ee.serverID == serverID && e2ee.roomID == roomID
}

// ── Joining ──────────────────────────────────────────────────────

// Why this profile cannot join roomID's encrypted voice now, or "" when it can (design 7.2):
// the verified log must be loaded and name this account a member, and the profile must have a
// valid encryption key. Static strings.
State_voiceE2EEJoinBlocker :: proc(state: ^State, serverID, roomID: int) -> string {
	if _, _, keyOK := Config_encryptionKey(state.config); !keyOK {
		return ROOM_NO_ENCRYPTION_KEY_NOTE
	}
	log := State_findRoomLog(state, serverID, roomID)
	if log != nil && log.status == .Failed {
		return ROOM_LOG_CHANGED_WARNING
	}
	verified := State_roomLogVerified(state, serverID, roomID)
	if verified == nil || verified.version == 0 {
		return VOICE_E2EE_SETTING_UP_NOTE
	}
	if !common.RoomLogState_isMember(verified^, State_selfUserID(state, serverID)) {
		return ROOM_NOT_A_LOG_MEMBER_NOTE
	}
	return ""
}

// What an encrypted room's engine is created with: the server's pinned key, the room and this
// account. ok is false (with a reason) when the server key or the account is not known yet.
State_voiceE2EEEngineEncryption :: proc(
	state: ^State,
	serverID, roomID: int,
) -> (
	encryption: VoiceEngineEncryption,
	reason: string,
	ok: bool,
) {
	keys := State_roomChainKeys(state, serverID)
	defer RoomChainKeys_wipe(&keys)
	if !keys.ready || keys.ownUserID <= 0 {
		return {}, VOICE_E2EE_SETTING_UP_NOTE, false
	}
	return VoiceEngineEncryption {
			enabled = true,
			serverIdentityPublicKey = keys.serverIdentityPublicKey,
			roomID = roomID,
			selfUserID = keys.ownUserID,
		},
		"",
		true
}

// The engine of an encrypted room started. A new join (restart false) starts a new voice
// session; a reopened engine (State_voiceRestartEngine) keeps it. Either way the engine gets
// every speaker key held and this participant makes a new generation, so no key is ever used
// by two engines.
State_voiceE2EEEngineStarted :: proc(state: ^State, restart: bool) {
	e2ee := &state.voice.e2ee
	serverID := state.voice.serverID
	roomID := state.voice.roomID
	if !restart || !State_voiceE2EEIsActiveIn(state, serverID, roomID) {
		VoiceE2EEState_reset(e2ee)
		sessionID, ok := common.generateVoiceSessionID()
		if !ok {
			return // the engine sends nothing without a key
		}
		e2ee.voiceSessionID = sessionID
		e2ee.active = true
		e2ee.serverID = serverID
		e2ee.roomID = roomID
		e2ee.selfUserID = State_selfUserID(state, serverID)
		if verified := State_roomLogVerified(state, serverID, roomID); verified != nil {
			e2ee.epoch = verified.version
		}
	}
	e2ee.hasSendKey = false
	for &speaker in e2ee.speakers {
		State_voiceE2EEPushSpeaker(state, &speaker)
	}
	State_voiceE2EERotate(state, restart ? .Engine : .Join)
}

// Voice ended (left, refused, removed, the session lost): every key goes.
State_voiceE2EEEnd :: proc(state: ^State) {
	VoiceE2EEState_reset(&state.voice.e2ee)
}

// ── Speaking ─────────────────────────────────────────────────────

// Makes, seals, sends and installs a new generation. Waits (rotatePending) for the verified
// log or for members' keys being fetched; a member that is not in the verified log any more,
// or a log that failed, stops this participant's frames.
State_voiceE2EERotate :: proc(state: ^State, rotation: VoiceKeyRotation) {
	e2ee := &state.voice.e2ee
	engine := state.voice.engine
	if !e2ee.active || engine == nil {
		return
	}
	serverID := e2ee.serverID
	roomID := e2ee.roomID
	log := State_findRoomLog(state, serverID, roomID)
	if log != nil && log.status == .Failed {
		VoiceEngine_clearSendKey(engine)
		e2ee.hasSendKey = false
		e2ee.rotatePending = false
		return
	}
	verified := State_roomLogVerified(state, serverID, roomID)
	if verified == nil {
		e2ee.rotatePending = true
		e2ee.pendingRotation = rotation
		State_requestRoomLog(state, serverID, roomID)
		return
	}
	selfUserID := e2ee.selfUserID
	if verified.version == 0 || !common.RoomLogState_isMember(verified^, selfUserID) {
		// Not a member of the epoch: nobody may get a key from this account.
		VoiceEngine_clearSendKey(engine)
		e2ee.hasSendKey = false
		e2ee.rotatePending = false
		return
	}
	members := make([dynamic]int, 0, len(verified.members), context.temp_allocator)
	for userID in verified.members {
		if userID != selfUserID {
			append(&members, userID)
		}
	}
	slice.sort(members[:])
	recipients := make([dynamic]common.EnvelopeRecipient, 0, len(members))
	defer delete(recipients)
	fetch := make([dynamic]int, 0, 4, context.temp_allocator)
	for userID in members {
		info := State_e2eePeerKeyInfo(state, serverID, userID)
		if info.canEncrypt && info.identityPublicKey == verified.members[userID] {
			append(&recipients, common.EnvelopeRecipient{userID, info.encryptionPublicKey})
		} else if info.blockReason == .Pending {
			append(&fetch, userID)
		}
	}
	if len(fetch) > 0 {
		State_e2eeRequestUserKeys(state, serverID, fetch[:])
		e2ee.rotatePending = true
		e2ee.pendingRotation = rotation
		return
	}
	e2ee.rotatePending = false
	epoch := verified.version
	if len(recipients) == 0 {
		// Nobody else can hear this room: no key to send.
		VoiceEngine_clearSendKey(engine)
		e2ee.hasSendKey = false
		e2ee.sendEpoch = epoch
		return
	}
	identityPrivateKey, privateOK := common.identityPrivateKeyFromHex(state.config.private_key)
	defer crypto.zero_explicit(&identityPrivateKey, size_of(identityPrivateKey))
	encryption := engine.config.encryption
	if !privateOK {
		return
	}
	voiceKey, keyOK := common.generateVoiceKey()
	defer common.VoiceKey_wipe(&voiceKey)
	if !keyOK {
		return
	}
	nowMS := State_voiceE2EENowMS(state)
	generation := e2ee.nextGeneration
	e2ee.nextGeneration += 1
	fields := common.VoiceKeyAADFields {
		serverIdentityPublicKey = encryption.serverIdentityPublicKey,
		roomID                  = roomID,
		epoch                   = epoch,
		senderUserID            = selfUserID,
		voiceSessionID          = e2ee.voiceSessionID,
		generation              = generation,
		createdAtUnix           = nowMS / 1000,
	}
	buffer: [common.SEALED_ENVELOPE_MAX_BYTES]u8
	n, err := common.sealVoiceKey(fields, voiceKey, recipients[:], identityPrivateKey, buffer[:])
	if err != .None {
		return
	}
	sent, _ := State_voiceSendControl(
		state,
		serverID,
		VoiceControlRequest {
			kind = .Key,
			roomID = roomID,
			epoch = epoch,
			voiceSessionID = e2ee.voiceSessionID,
			generation = generation,
			createdAt = fields.createdAtUnix,
			envelope = buffer[:n],
		},
	)
	if !sent {
		// Not connected: the engine stops with the session, and the next one starts over.
		VoiceEngine_clearSendKey(engine)
		e2ee.hasSendKey = false
		return
	}
	VoiceEngine_setSendKey(
		engine,
		VoiceEngineKey {
			set = true,
			epoch = epoch,
			voiceSessionID = e2ee.voiceSessionID,
			generation = generation,
			key = voiceKey,
		},
	)
	e2ee.hasSendKey = true
	e2ee.sendEpoch = epoch
	e2ee.sendGeneration = generation
	e2ee.sendCreatedAtMS = nowMS
	e2ee.stats.sent += 1
	State_voiceE2EENote(
		state,
		{
			kind = .Sent,
			serverID = serverID,
			roomID = roomID,
			userID = selfUserID,
			epoch = epoch,
			generation = generation,
			rotation = rotation,
		},
	)
}

// ServerVoiceKeyRequest: requesterUserID, a member of the current epoch, holds no usable key
// of this participant's. Rotating instead of re-sealing keeps one path and also reaches
// members whose keys arrived since; at most once every VOICE_KEY_REQUEST_INTERVAL_SECONDS.
State_voiceE2EEReceiveRequest :: proc(state: ^State, serverID, roomID, requesterUserID: int) {
	if !State_voiceE2EEIsActiveIn(state, serverID, roomID) {
		return
	}
	e2ee := &state.voice.e2ee
	e2ee.stats.requestsReceived += 1
	State_voiceE2EENote(
		state,
		{kind = .RequestReceived, serverID = serverID, roomID = roomID, userID = requesterUserID},
	)
	verified := State_roomLogVerified(state, serverID, roomID)
	if verified == nil || !common.RoomLogState_isMember(verified^, requesterUserID) {
		return
	}
	nowMS := State_voiceE2EENowMS(state)
	interval := i64(common.VOICE_KEY_REQUEST_INTERVAL_SECONDS) * 1000
	if e2ee.lastRequestRotateMS != 0 && nowMS - e2ee.lastRequestRotateMS < interval {
		return
	}
	e2ee.lastRequestRotateMS = nowMS
	State_voiceE2EERotate(state, .Request)
}

// ── Listening ────────────────────────────────────────────────────

@(private = "file")
State_voiceE2EESpeaker :: proc(state: ^State, userID: int) -> ^VoiceE2EESpeaker {
	e2ee := &state.voice.e2ee
	for &speaker in e2ee.speakers {
		if speaker.userID == userID {
			return &speaker
		}
	}
	append(&e2ee.speakers, VoiceE2EESpeaker{userID = userID})
	return &e2ee.speakers[len(e2ee.speakers) - 1]
}

@(private = "file")
voiceE2EEEngineKey :: proc(key: VoiceE2EESpeakerKey) -> VoiceEngineKey {
	if !key.set {
		return {}
	}
	return VoiceEngineKey {
		set = true,
		epoch = key.epoch,
		voiceSessionID = key.voiceSessionID,
		generation = key.generation,
		key = key.key,
	}
}

// Gives the engine speaker's keys as held here.
@(private = "file")
State_voiceE2EEPushSpeaker :: proc(state: ^State, speaker: ^VoiceE2EESpeaker) {
	engine := state.voice.engine
	if engine == nil || speaker.userID <= 0 {
		return
	}
	current := voiceE2EEEngineKey(speaker.current)
	previous := voiceE2EEEngineKey(speaker.previous)
	defer crypto.zero_explicit(&current, size_of(current))
	defer crypto.zero_explicit(&previous, size_of(previous))
	_ = VoiceEngine_setSpeakerKeys(engine, u32(speaker.userID), current, previous)
}

@(private = "file")
State_voiceE2EERefuse :: proc(
	state: ^State,
	payload: ^common.ServerVoiceKeyPayload,
	refusal: VoiceKeyRefusal,
	err: common.E2EEError = .None,
) {
	e2ee := &state.voice.e2ee
	e2ee.stats.refused[refusal] += 1
	if refusal != .Duplicate {
		State_voiceE2EESpeaker(state, payload.senderId).lastRefusal = refusal
	}
	State_voiceE2EENote(
		state,
		{
			kind = .Refused,
			serverID = e2ee.serverID,
			roomID = payload.roomId,
			userID = payload.senderId,
			epoch = payload.epoch,
			generation = payload.generation,
			refusal = refusal,
			error = err,
		},
	)
}

// Moves payload into the pending list (it is cleared), replacing an older one of its sender.
@(private = "file")
State_voiceE2EEHold :: proc(state: ^State, payload: ^common.ServerVoiceKeyPayload) {
	e2ee := &state.voice.e2ee
	for &held in e2ee.pending {
		if held.senderId == payload.senderId {
			common.ServerVoiceKeyPayload_deinit(&held)
			held = payload^
			payload^ = {}
			return
		}
	}
	if len(e2ee.pending) >= VOICE_E2EE_PENDING_MAX {
		common.ServerVoiceKeyPayload_deinit(payload)
		return
	}
	append(&e2ee.pending, payload^)
	payload^ = {}
}

// ServerVoiceKey: takes the payload (it is cleared or left for the caller to free). See the
// rules at the top of this file.
State_voiceE2EEReceiveKey :: proc(
	state: ^State,
	serverID: int,
	payload: ^common.ServerVoiceKeyPayload,
) {
	if !State_voiceE2EEIsActiveIn(state, serverID, payload.roomId) {
		return
	}
	e2ee := &state.voice.e2ee
	roomID := payload.roomId
	senderID := payload.senderId
	if senderID <= 0 || senderID == e2ee.selfUserID {
		return
	}
	log := State_findRoomLog(state, serverID, roomID)
	if log != nil && log.status == .Failed {
		State_voiceE2EERefuse(state, payload, .LogFailed)
		return
	}
	verified := State_roomLogVerified(state, serverID, roomID)
	if verified == nil || payload.epoch > verified.version {
		// Held until the log catches up.
		State_voiceE2EEHold(state, payload)
		State_requestRoomLog(state, serverID, roomID)
		return
	}
	nowMS := State_voiceE2EENowMS(state)
	if payload.epoch < verified.version {
		inGrace :=
			e2ee.graceUntilMS != 0 && nowMS < e2ee.graceUntilMS && payload.epoch >= e2ee.graceEpoch
		if !inGrace {
			State_voiceE2EERefuse(state, payload, .OldEpoch)
			return
		}
	}
	if !State_roomLogWasMember(state, serverID, roomID, senderID, payload.epoch) {
		State_voiceE2EERefuse(state, payload, .NotMember)
		return
	}
	logIdentity, named := verified.identities[senderID]
	info := State_e2eePeerKeyInfo(state, serverID, senderID)
	if !info.hasPin && info.blockReason == .Pending {
		State_voiceE2EEHold(state, payload)
		fetch := [1]int{senderID}
		State_e2eeRequestUserKeys(state, serverID, fetch[:])
		return
	}
	if !named || !info.hasPin || info.identityPublicKey != logIdentity {
		State_voiceE2EERefuse(state, payload, .NoPin)
		return
	}
	nowSeconds := nowMS / 1000
	if payload.createdAt < nowSeconds - common.VOICE_KEY_MAX_AGE_SECONDS {
		State_voiceE2EERefuse(state, payload, .TooOld)
		return
	}
	if payload.createdAt > nowSeconds + common.VOICE_KEY_MAX_FUTURE_SECONDS {
		State_voiceE2EERefuse(state, payload, .TooNew)
		return
	}
	speaker := State_voiceE2EESpeaker(state, senderID)
	if speaker.hasAccepted {
		sameSession := speaker.acceptedSession == payload.voiceSessionId
		if sameSession && payload.generation == speaker.acceptedGen {
			State_voiceE2EERefuse(state, payload, .Duplicate)
			return
		}
		if (sameSession && payload.generation < speaker.acceptedGen) ||
		   (!sameSession && payload.createdAt < speaker.acceptedAt) {
			State_voiceE2EERefuse(state, payload, .NotNewer)
			return
		}
	}
	keys := State_roomChainKeys(state, serverID)
	defer RoomChainKeys_wipe(&keys)
	if !keys.ready || !keys.hasOwnKeyPair {
		State_voiceE2EERefuse(state, payload, .Failed, .NoWrapForRecipient)
		return
	}
	voiceKey, err := common.openVoiceKey(
		payload.envelope,
		common.VoiceKeyAADFields {
			serverIdentityPublicKey = keys.serverIdentityPublicKey,
			roomID = roomID,
			epoch = payload.epoch,
			senderUserID = senderID,
			voiceSessionID = payload.voiceSessionId,
			generation = payload.generation,
			createdAtUnix = payload.createdAt,
		},
		info.identityPublicKey,
		keys.ownUserID,
		keys.ownKeyPair,
	)
	defer common.VoiceKey_wipe(&voiceKey)
	if err == .NoWrapForRecipient {
		State_voiceE2EERefuse(state, payload, .NoWrap)
		return
	}
	if err != .None {
		// Final: never retried, and the failure itself never makes a request.
		State_voiceE2EERefuse(state, payload, .Failed, err)
		speaker = State_voiceE2EESpeaker(state, senderID)
		speaker.requested = true
		return
	}
	speaker = State_voiceE2EESpeaker(state, senderID)
	VoiceE2EESpeakerKey_wipe(&speaker.previous)
	speaker.previous = speaker.current
	speaker.current = VoiceE2EESpeakerKey {
		set            = true,
		epoch          = payload.epoch,
		voiceSessionID = payload.voiceSessionId,
		generation     = payload.generation,
		createdAt      = payload.createdAt,
		key            = voiceKey,
	}
	speaker.hasAccepted = true
	speaker.acceptedSession = payload.voiceSessionId
	speaker.acceptedGen = payload.generation
	speaker.acceptedAt = payload.createdAt
	speaker.missingSinceMS = 0
	speaker.requested = false
	speaker.lastRefusal = .None
	State_voiceE2EEPushSpeaker(state, speaker)
	e2ee.stats.accepted += 1
	State_voiceE2EENote(
		state,
		{
			kind = .Accepted,
			serverID = serverID,
			roomID = roomID,
			userID = senderID,
			epoch = payload.epoch,
			generation = payload.generation,
		},
	)
}

// Looks at the held keys again (the log or pins moved).
@(private = "file")
State_voiceE2EERetryPending :: proc(state: ^State) {
	e2ee := &state.voice.e2ee
	if len(e2ee.pending) == 0 {
		return
	}
	waiting := e2ee.pending
	e2ee.pending = nil
	for &payload in waiting {
		State_voiceE2EEReceiveKey(state, e2ee.serverID, &payload)
		common.ServerVoiceKeyPayload_deinit(&payload)
	}
	delete(waiting)
}

// The verified log of roomID changed (or failed): a new epoch starts the grace for the old
// keys, clears this participant's send key at once and rotates; held keys are looked at again.
State_voiceE2EELogChanged :: proc(state: ^State, serverID, roomID: int) {
	if !State_voiceE2EEIsActiveIn(state, serverID, roomID) {
		return
	}
	e2ee := &state.voice.e2ee
	engine := state.voice.engine
	log := State_findRoomLog(state, serverID, roomID)
	if log != nil && log.status == .Failed {
		// Nothing of this room can be trusted any more: no key is used either way.
		if engine != nil {
			VoiceEngine_clearSendKey(engine)
			VoiceEngine_clearSpeakerKeys(engine)
		}
		for &speaker in e2ee.speakers {
			VoiceE2EESpeaker_wipe(&speaker)
		}
		e2ee.hasSendKey = false
		VoiceE2EEState_clearPending(e2ee)
		return
	}
	verified := State_roomLogVerified(state, serverID, roomID)
	if verified == nil {
		return
	}
	if verified.version > e2ee.epoch {
		if e2ee.epoch > 0 {
			e2ee.graceEpoch = e2ee.epoch
			e2ee.graceUntilMS =
				State_voiceE2EENowMS(state) + i64(common.VOICE_EPOCH_GRACE_SECONDS) * 1000
		}
		e2ee.epoch = verified.version
	}
	State_voiceE2EERetryPending(state)
	if verified.version != e2ee.sendEpoch || !e2ee.hasSendKey || e2ee.rotatePending {
		if engine != nil && e2ee.hasSendKey && verified.version != e2ee.sendEpoch {
			// Frames of the new epoch wait for its key; the old one is never used again.
			VoiceEngine_clearSendKey(engine)
			e2ee.hasSendKey = false
		}
		rotation := e2ee.rotatePending ? e2ee.pendingRotation : VoiceKeyRotation.Epoch
		if verified.version != e2ee.sendEpoch {
			rotation = .Epoch
		}
		State_voiceE2EERotate(state, rotation)
	}
}

// Pins changed (fetched, pushed, trusted): a rotation that waited for members' keys goes on,
// and held keys are looked at again.
State_voiceE2EEKeysChanged :: proc(state: ^State, serverID: int) {
	e2ee := &state.voice.e2ee
	if !e2ee.active || e2ee.serverID != serverID {
		return
	}
	State_voiceE2EERetryPending(state)
	if e2ee.rotatePending {
		State_voiceE2EERotate(state, .Keys)
	}
}

// A ServerProtocolError on serverID: "Voice key is out of date" means the log moved on at the
// server, so it is fetched and the next log change rotates.
State_voiceE2EEProtocolError :: proc(state: ^State, serverID: int, message: string) {
	e2ee := &state.voice.e2ee
	if !e2ee.active || e2ee.serverID != serverID {
		return
	}
	if message == common.VOICE_KEY_OUT_OF_DATE_MESSAGE {
		if engine := state.voice.engine; engine != nil {
			VoiceEngine_clearSendKey(engine)
		}
		e2ee.hasSendKey = false
		e2ee.rotatePending = true
		e2ee.pendingRotation = .Epoch
		State_requestRoomLog(state, serverID, e2ee.roomID)
	}
}

// Periodic work while an encrypted room's voice runs (the frame loop and the harness call it):
// the timed rotation, the end of an epoch's grace, and asking participants without a key.
State_voiceE2EETick :: proc(state: ^State) {
	e2ee := &state.voice.e2ee
	if !e2ee.active || state.voice.engine == nil {
		return
	}
	nowMS := State_voiceE2EENowMS(state)
	if e2ee.hasSendKey && nowMS - e2ee.sendCreatedAtMS >= State_voiceE2EERotateMS(state) {
		State_voiceE2EERotate(state, .Timer)
	}
	if e2ee.graceUntilMS != 0 && nowMS >= e2ee.graceUntilMS {
		e2ee.graceUntilMS = 0
		for &speaker in e2ee.speakers {
			changed := false
			if speaker.previous.set && speaker.previous.epoch < e2ee.epoch {
				VoiceE2EESpeakerKey_wipe(&speaker.previous)
				changed = true
			}
			if speaker.current.set && speaker.current.epoch < e2ee.epoch {
				VoiceE2EESpeakerKey_wipe(&speaker.current)
				changed = true
			}
			if changed {
				State_voiceE2EEPushSpeaker(state, &speaker)
			}
		}
	}
	// Participants without a usable key are asked once, after VOICE_KEY_MISSING_REQUEST_MS.
	for participant in State_voiceRoomParticipants(state, e2ee.serverID, e2ee.roomID) {
		userID := participant.userId
		if userID == e2ee.selfUserID || userID <= 0 {
			continue
		}
		speaker := State_voiceE2EESpeaker(state, userID)
		if speaker.current.set && speaker.current.epoch >= e2ee.epoch {
			speaker.missingSinceMS = 0
			continue
		}
		if speaker.missingSinceMS == 0 {
			speaker.missingSinceMS = nowMS
			continue
		}
		if speaker.requested || nowMS - speaker.missingSinceMS < VOICE_KEY_MISSING_REQUEST_MS {
			continue
		}
		speaker.requested = true
		sent, _ := State_voiceSendControl(
			state,
			e2ee.serverID,
			VoiceControlRequest{kind = .RequestKey, roomID = e2ee.roomID, senderID = userID},
		)
		if sent {
			e2ee.stats.requestsSent += 1
			State_voiceE2EENote(
				state,
				{kind = .Requested, serverID = e2ee.serverID, roomID = e2ee.roomID, userID = userID},
			)
		}
	}
}

// ── View ─────────────────────────────────────────────────────────

// The note on a participant of the joined encrypted room: "" when its key is held, else why
// it cannot be heard (allocator, or static).
State_voiceE2EEParticipantNote :: proc(
	state: ^State,
	serverID, roomID, userID: int,
	allocator := context.temp_allocator,
) -> string {
	e2ee := &state.voice.e2ee
	if !State_voiceE2EEIsActiveIn(state, serverID, roomID) || userID == e2ee.selfUserID {
		return ""
	}
	for speaker in e2ee.speakers {
		if speaker.userID != userID {
			continue
		}
		if speaker.current.set && speaker.current.epoch >= e2ee.epoch {
			return ""
		}
		if speaker.lastRefusal == .TooOld || speaker.lastRefusal == .TooNew {
			return VOICE_E2EE_CLOCK_NOTE
		}
		break
	}
	name := State_e2eeUserName(state, serverID, userID, allocator)
	return fmt.aprintf(VOICE_E2EE_WAITING_FORMAT, name, allocator = allocator)
}
