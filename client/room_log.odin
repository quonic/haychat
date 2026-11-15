package client

import "../common"
import "core:crypto"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:time"

// Encrypted rooms' member logs (protocol 18, e2ee-design.md 6.1, 6.2). The server's
// room_members decides access to sends and history, but never who an encrypted room's keys
// go to: that is the verified log's member list, which only this file builds.
//
// Verification:
//
// - A room's log is fetched whole (ClientFetchRoomLog after version 0, page by page) the first
//   time this session needs it, and replayed with common.RoomLogState_apply against this
//   profile's pins (E1, key store): every identity key an entry names must equal the pin for
//   that user, and this profile's own key for itself. The head this profile verified before
//   (key store format 3) must be in the log with the same hash (else Fork) and the log must
//   reach it (else Rollback).
// - After that, entries are applied one by one as they arrive (live ServerRoomLog or a fetch
//   after the verified version). An entry at the verified version must hash to the verified
//   head; earlier ones are skipped (the hash chain binds them); a gap fetches what is missing.
// - Users the log names without a pin are fetched (State_e2eeRequestUserKeys), which pins them
//   on first use through E1; once their keys arrive the identities the log accepted are checked
//   against the new pins (State_roomLogsPinsChanged). An account that never published a bundle
//   stays unpinned: the log's own consistency and the stored head hold its key.
// - Every failure is fatal for the room until the client restarts: status Failed, the warning
//   ROOM_LOG_CHANGED_WARNING on the room and its Members page, no signing, nothing retried or
//   accepted later. A restart replays the whole log again, against the same stored head.
//
// Signing (State_roomLogAppend): an entry is built on the verified head, checked locally with
// RoomLogState_validate (unless the caller is the harness, which wants the server's refusal),
// signed with this profile's identity key over the pinned server key, and sent. Nothing changes
// locally until the server's ServerRoomLog echo arrives and verifies like any other entry.
//
// For E4b (sender chains): State_roomLogVerified gives the verified RoomLogState of a room
// (members per epoch = its version), State_roomLogEpoch its current epoch, and
// State.roomLogChanged is called after every verified change (nil by default).

ROOM_LOG_CHANGED_WARNING :: "This room's member list was changed on the server"
ENCRYPTED_ROOM_PENDING_NOTE :: "Encrypted room messages arrive in a later update"
ROOM_LOG_NOT_SET_UP_NOTE :: "This encrypted room's member list has not been set up yet"

RoomLogStatus :: enum u8 {
	Unknown, // Never fetched in this session
	Loading, // A whole-log fetch is collecting pages
	Verified, // state holds the verified log (version 0: the creator has not set it up yet)
	Failed, // Fatal: failure says why; never retried in this run
}

// One verified change, for the room's event lines (roomLogEventText). Who did what is kept,
// not the text, so names follow renames.
RoomLogEventLine :: struct {
	version:         int,
	action:          common.RoomLogAction,
	actorUserID:     int, // 0 for the server
	targetUserID:    int,
	actorWasManager: bool,
	access:          common.RoomLogAccess, // Create and SetAccess
	managerCount:    int, // Create
	createdAt:       u64,
}

RoomLogRoom :: struct {
	roomID:        int,
	status:        RoomLogStatus,
	state:         common.RoomLogState,
	failure:       common.RoomLogError,
	failedVersion: int,
	events:        [dynamic]RoomLogEventLine,
	// A whole-log fetch's pages so far (owned), replayed once the last one arrived.
	collecting:    [dynamic][]u8,
	fetching:      bool,
	serverHead:    int,
}

RoomLogRoom_deinit :: proc(room: ^RoomLogRoom) {
	common.RoomLogState_deinit(&room.state)
	delete(room.events)
	RoomLogRoom_clearCollecting(room)
	delete(room.collecting)
	room^ = {}
}

RoomLogRoom_clearCollecting :: proc(room: ^RoomLogRoom) {
	for entry in room.collecting {
		delete(entry)
	}
	clear(&room.collecting)
}

ServerRoomLogs :: struct {
	serverID:        int,
	// The pinned server key the logs were verified with; a new pin starts over.
	serverPublicKey: common.IdentityPublicKeyBytes,
	rooms:           [dynamic]RoomLogRoom,
}

ServerRoomLogs_deinit :: proc(logs: ^ServerRoomLogs) {
	for &room in logs.rooms {
		RoomLogRoom_deinit(&room)
	}
	delete(logs.rooms)
	logs^ = {}
}

// An encrypted room being created: ClientCreateRoom went out (or waits for managers' keys),
// and the Create entry is signed once ServerCreateRoom names the room.
RoomLogPendingCreate :: struct {
	serverID:     int,
	name:         string, // Owned, as sent (validated)
	description:  string, // Owned
	roomType:     common.RoomType,
	access:       common.RoomAccess,
	history:      common.RoomHistoryVisibility,
	creatorJoins: bool,
	managers:     [dynamic]int, // Owned; this account first
	sent:         bool,
}

RoomLogPendingCreate_deinit :: proc(pending: ^RoomLogPendingCreate) {
	delete(pending.name)
	delete(pending.description)
	delete(pending.managers)
	pending^ = {}
}

// A signed change that waits for its target's key (an Add or AddManager of an unpinned user).
RoomLogPendingAction :: struct {
	serverID:     int,
	roomID:       int,
	action:       common.RoomLogAction,
	targetUserID: int,
	checkRights:  bool,
}

// What the headless harness prints after the event that caused it (recordRoomLogNotes).
RoomLogNote :: struct {
	serverID: int,
	roomID:   int,
}

// Hooks for E4b: called after a room's verified log changed (replayed, advanced, or failed).
RoomLogChangedProc :: #type proc(state: ^State, serverID, roomID: int)

// ── Sending ──────────────────────────────────────────────────────

RoomLogRequestKind :: enum u8 {
	Append,
	Fetch,
}

RoomLogRequest :: struct {
	kind:         RoomLogRequestKind,
	roomID:       int,
	afterVersion: int,
	entry:        []u8, // Borrowed for the call
}

RoomLogSendBridge :: #type proc(transport: ^ClientServerTransport, request: RoomLogRequest) -> bool

// Tests swap it under roomLogSendBridgeTestMutex.
roomLogSendBridge: RoomLogSendBridge = ClientServerTransport_sendRoomLogRequest

ClientServerTransport_sendRoomLogRequest :: proc(
	transport: ^ClientServerTransport,
	request: RoomLogRequest,
) -> bool {
	switch request.kind {
	case .Append:
		return ClientServerTransport_appendRoomLog(transport, request.roomID, request.entry)
	case .Fetch:
		return ClientServerTransport_fetchRoomLog(transport, request.roomID, request.afterVersion)
	}
	return false
}

@(private = "file")
State_sendRoomLogRequest :: proc(state: ^State, serverID: int, request: RoomLogRequest) -> string {
	transportIndex := State_selectedTransportIndexForServerID(state^, serverID)
	if transportIndex < 0 {
		return "No server transport selected"
	}
	if !State_isServerConnected(state, serverID) {
		return NOT_CONNECTED_MESSAGE
	}
	transport := &state.serverTransports[transportIndex]
	ClientNetworkWorker_lock(state.networkWorker)
	sent := roomLogSendBridge(transport, request)
	sendError := sent ? "" : strings.clone(transport.lastError, context.temp_allocator)
	ClientNetworkWorker_unlock(state.networkWorker)
	if sent {
		return ""
	}
	if len(sendError) > 0 {
		return sendError
	}
	return "Failed to send the member list request"
}

// ── Lookup ───────────────────────────────────────────────────────

State_roomLogsIndex :: proc(state: State, serverID: int) -> int {
	for logs, index in state.roomLogs {
		if logs.serverID == serverID {
			return index
		}
	}
	return -1
}

State_roomLogs :: proc(state: ^State, serverID: int) -> ^ServerRoomLogs {
	if index := State_roomLogsIndex(state^, serverID); index >= 0 {
		return &state.roomLogs[index]
	}
	append(&state.roomLogs, ServerRoomLogs{serverID = serverID})
	return &state.roomLogs[len(state.roomLogs) - 1]
}

// The room's log state, or nil when this session has none. Borrowed from State.
State_findRoomLog :: proc(state: ^State, serverID, roomID: int) -> ^RoomLogRoom {
	index := State_roomLogsIndex(state^, serverID)
	if index < 0 {
		return nil
	}
	for &room in state.roomLogs[index].rooms {
		if room.roomID == roomID {
			return &room
		}
	}
	return nil
}

@(private = "file")
State_roomLogRoom :: proc(state: ^State, serverID, roomID: int) -> ^RoomLogRoom {
	if room := State_findRoomLog(state, serverID, roomID); room != nil {
		return room
	}
	logs := State_roomLogs(state, serverID)
	append(&logs.rooms, RoomLogRoom{roomID = roomID})
	return &logs.rooms[len(logs.rooms) - 1]
}

// Whether the client knows roomID as encrypted (its room list or, for admins, the list of
// every room).
State_roomIsEncrypted :: proc(state: ^State, serverID, roomID: int) -> bool {
	if room := State_knownRoom(state, serverID, roomID); room != nil {
		return room.encrypted
	}
	return false
}

// The verified log of an encrypted room for E4b: members and managers (with the keys the log
// names, which match the pins) at its current epoch (state.version). nil unless Verified.
State_roomLogVerified :: proc(state: ^State, serverID, roomID: int) -> ^common.RoomLogState {
	room := State_findRoomLog(state, serverID, roomID)
	if room == nil || room.status != .Verified {
		return nil
	}
	return &room.state
}

// The room's current epoch (its verified log version), 0 unless Verified.
State_roomLogEpoch :: proc(state: ^State, serverID, roomID: int) -> int {
	if verified := State_roomLogVerified(state, serverID, roomID); verified != nil {
		return verified.version
	}
	return 0
}

// The sentence for a failed log, with the rule that failed.
roomLogFailureText :: proc(room: ^RoomLogRoom, allocator := context.temp_allocator) -> string {
	if room == nil || room.status != .Failed {
		return ""
	}
	return fmt.aprintf(
		"%s (%v at version %d).",
		ROOM_LOG_CHANGED_WARNING,
		room.failure,
		room.failedVersion,
		allocator = allocator,
	)
}

// ── Pins ─────────────────────────────────────────────────────────

@(private = "file")
RoomLogPinSource :: struct {
	state:     ^State,
	serverID:  int,
	ownUserID: int,
	ownKey:    common.IdentityPublicKeyBytes,
	hasOwnKey: bool,
}

// This profile's own key for itself, the key store's pin for everyone else.
@(private = "file")
roomLogLookupPin :: proc(
	userData: rawptr,
	userID: int,
) -> (
	identityKey: common.IdentityPublicKeyBytes,
	pinned: bool,
) {
	source := (^RoomLogPinSource)(userData)
	if source.hasOwnKey && userID == source.ownUserID {
		return source.ownKey, true
	}
	index := State_e2eeServerIndex(source.state^, source.serverID)
	if index < 0 {
		return {}, false
	}
	if pin, ok := KeyStore_pin(&source.state.e2ee[index].store, userID); ok {
		return pin.identityPublicKey, true
	}
	return {}, false
}

@(private = "file")
State_roomLogPinSource :: proc(state: ^State, serverID: int) -> RoomLogPinSource {
	source := RoomLogPinSource {
		state     = state,
		serverID  = serverID,
		ownUserID = State_selfUserID(state, serverID),
	}
	source.ownKey, source.hasOwnKey = common.identityPublicKeyFromHex(state.config.public_key)
	return source
}

// The context to verify serverID's logs with, or ok false while the server has no pinned key.
@(private = "file")
State_roomLogContext :: proc(
	state: ^State,
	serverID: int,
	source: ^RoomLogPinSource,
) -> (
	ctx: common.RoomLogContext,
	ok: bool,
) {
	e2ee, storeOK := State_e2eeEnsureStore(state, serverID)
	if !storeOK || e2ee == nil {
		return {}, false
	}
	return common.RoomLogContext {
			serverIdentityPublicKey = e2ee.store.serverPublicKey,
			lookupPin = roomLogLookupPin,
			pinUserData = source,
		},
		true
}

// ── Receiving ────────────────────────────────────────────────────

// Asks for the part of roomID's log this session lacks: the whole log the first time, else
// what follows the verified version. A Failed room is never fetched again.
State_requestRoomLog :: proc(state: ^State, serverID, roomID: int) -> string {
	room := State_roomLogRoom(state, serverID, roomID)
	if room.status == .Failed || room.fetching {
		return ""
	}
	afterVersion := 0
	if room.status == .Verified {
		afterVersion = room.state.version
	} else {
		RoomLogRoom_clearCollecting(room)
		room.status = .Loading
	}
	errorMessage := State_sendRoomLogRequest(
		state,
		serverID,
		{kind = .Fetch, roomID = roomID, afterVersion = afterVersion},
	)
	if len(errorMessage) == 0 {
		room.fetching = true
	} else if room.status == .Loading {
		room.status = .Unknown
	}
	return errorMessage
}

// A room list or the admin's list of every room arrived: fetch the logs of encrypted rooms
// this session has not verified up to the server's version.
State_roomLogsRoomsListed :: proc(state: ^State, serverID: int) {
	index := State_serverRoomCacheIndex(state^, serverID)
	if index < 0 {
		return
	}
	cache := &state.server_room_caches[index]
	State_roomLogsCheckServerKey(state, serverID)
	check :: proc(state: ^State, serverID: int, room: common.RoomSummary) {
		if !room.encrypted {
			return
		}
		log := State_roomLogRoom(state, serverID, room.id)
		log.serverHead = max(log.serverHead, room.logVersion)
		switch log.status {
		case .Failed, .Loading:
		case .Unknown:
			State_requestRoomLog(state, serverID, room.id)
		case .Verified:
			// A list can be older than entries that arrived since (the cached room list after
			// a live entry), so a lower version is no evidence; a log that really ends before
			// the verified head is refused when it is replayed (Rollback).
			if room.logVersion > log.state.version {
				State_requestRoomLog(state, serverID, room.id)
			}
		}
	}
	// Copies: a check can append to the room list caches' neighbours, never to these arrays.
	for room in cache.rooms {
		check(state, serverID, room)
	}
	for entry in cache.adminRooms {
		check(state, serverID, entry.room)
	}
}

// A new server pin (Trust the new key) starts every log of that server over.
@(private = "file")
State_roomLogsCheckServerKey :: proc(state: ^State, serverID: int) {
	e2ee, ok := State_e2eeEnsureStore(state, serverID)
	if !ok || e2ee == nil {
		return
	}
	logs := State_roomLogs(state, serverID)
	if logs.serverPublicKey == e2ee.store.serverPublicKey {
		return
	}
	if logs.serverPublicKey == {} {
		logs.serverPublicKey = e2ee.store.serverPublicKey
		return
	}
	for &room in logs.rooms {
		RoomLogRoom_deinit(&room)
	}
	clear(&logs.rooms)
	logs.serverPublicKey = e2ee.store.serverPublicKey
}

// Requests in flight died with the session.
State_roomLogsConnectionReset :: proc(state: ^State, serverID: int) {
	index := State_roomLogsIndex(state^, serverID)
	if index < 0 {
		return
	}
	for &room in state.roomLogs[index].rooms {
		room.fetching = false
		if room.status == .Loading {
			RoomLogRoom_clearCollecting(&room)
			room.status = .Unknown
		}
	}
}

// A protocol error may answer a fetch ("Not a room member"), so fetches in flight end.
State_roomLogsProtocolError :: proc(state: ^State, serverID: int) {
	State_roomLogsConnectionReset(state, serverID)
}

// ServerRoomLog: takes the entries (event.logEntries) and clears the event's array.
State_receiveRoomLog :: proc(state: ^State, event: ^ClientTransportRuntimeEvent) {
	if State_selectedTransportIndexForServerID(state^, event.serverID) < 0 {
		return
	}
	serverID, roomID := event.serverID, event.roomID
	State_roomLogsCheckServerKey(state, serverID)
	room := State_roomLogRoom(state, serverID, roomID)
	room.serverHead = max(room.serverHead, event.logHeadVersion)
	State_roomLogNote(state, serverID, roomID)
	switch room.status {
	case .Failed:
		return
	case .Unknown:
		// A live entry before this session fetched anything: fetch the whole log instead.
		State_requestRoomLog(state, serverID, roomID)
		return
	case .Loading:
		if !room.fetching || event.logAfterVersion != len(room.collecting) {
			return // A live entry while the whole log is on its way, which will include it
		}
		for entry in event.logEntries {
			append(&room.collecting, entry)
		}
		clear(&event.logEntries)
		if event.hasOlder {
			room.fetching = false
			State_requestRoomLogPage(state, serverID, room)
			return
		}
		room.fetching = false
		State_roomLogReplayCollected(state, serverID, room)
	case .Verified:
		if event.logAfterVersion <= room.state.version {
			room.fetching = false
		}
		State_roomLogApplyEntries(state, serverID, room, event.logEntries[:])
	}
	room = State_findRoomLog(state, serverID, roomID)
	if room != nil && room.status == .Verified && room.state.version < room.serverHead {
		State_requestRoomLog(state, serverID, roomID)
	}
}

// The next page of a whole-log fetch.
@(private = "file")
State_requestRoomLogPage :: proc(state: ^State, serverID: int, room: ^RoomLogRoom) {
	errorMessage := State_sendRoomLogRequest(
		state,
		serverID,
		{kind = .Fetch, roomID = room.roomID, afterVersion = len(room.collecting)},
	)
	if len(errorMessage) == 0 {
		room.fetching = true
		return
	}
	RoomLogRoom_clearCollecting(room)
	room.status = .Unknown
}

// Applies one verified entry to the room (already validated): notes its event line.
@(private = "file")
roomLogEventFor :: proc(
	before: ^common.RoomLogState,
	data: []u8,
) -> (
	line: RoomLogEventLine,
	ok: bool,
) {
	managers: [common.ROOM_LOG_MANAGERS_MAX]common.RoomLogManager
	entry, err := common.decodeRoomLogEntry(data, managers[:])
	if err != .None {
		return {}, false
	}
	return RoomLogEventLine {
			version = entry.version,
			action = entry.action,
			actorUserID = entry.actorUserID,
			targetUserID = entry.targetUserID,
			actorWasManager = entry.actorUserID in before.managers,
			access = entry.settings.access,
			managerCount = len(entry.settings.managers),
			createdAt = entry.createdAt,
		},
		true
}

// Replays a whole log (room.collecting) against the pins and the stored head.
@(private = "file")
State_roomLogReplayCollected :: proc(state: ^State, serverID: int, room: ^RoomLogRoom) {
	source := State_roomLogPinSource(state, serverID)
	ctx, ctxOK := State_roomLogContext(state, serverID, &source)
	if !ctxOK {
		RoomLogRoom_clearCollecting(room)
		room.status = .Unknown
		return
	}
	e2eeIndex := State_e2eeServerIndex(state^, serverID)
	known := KeyStore_roomHead(state.e2ee[e2eeIndex].store, room.roomID)
	replayed := common.RoomLogState_init(room.roomID)
	events := make([dynamic]RoomLogEventLine, 0, len(room.collecting))
	failure := common.RoomLogError.None
	failedVersion := 0
	for data, index in room.collecting {
		line, lineOK := roomLogEventFor(&replayed, data)
		if _, err := common.RoomLogState_apply(&replayed, data, ctx); err != .None || !lineOK {
			failure = err != .None ? err : .Truncated
			failedVersion = index + 1
			break
		}
		append(&events, line)
		if known.version > 0 &&
		   replayed.version == known.version &&
		   replayed.headHash != known.hash {
			failure = .Fork
			failedVersion = replayed.version
			break
		}
	}
	if failure == .None && known.version > replayed.version {
		failure = .Rollback
		failedVersion = replayed.version
	}
	RoomLogRoom_clearCollecting(room)
	if failure != .None {
		common.RoomLogState_deinit(&replayed)
		delete(events)
		State_roomLogFail(state, serverID, room, failure, failedVersion)
		return
	}
	common.RoomLogState_deinit(&room.state)
	delete(room.events)
	room.state = replayed
	room.events = events
	room.status = .Verified
	room.failure = .None
	State_roomLogVerifiedChanged(state, serverID, room.roomID)
}

// Applies entries that arrived for a verified room, in order.
@(private = "file")
State_roomLogApplyEntries :: proc(
	state: ^State,
	serverID: int,
	room: ^RoomLogRoom,
	entries: [][]u8,
) {
	source := State_roomLogPinSource(state, serverID)
	ctx, ctxOK := State_roomLogContext(state, serverID, &source)
	if !ctxOK {
		return
	}
	changed := false
	roomID := room.roomID
	for data in entries {
		managers: [common.ROOM_LOG_MANAGERS_MAX]common.RoomLogManager
		decoded, decodeErr := common.decodeRoomLogEntry(data, managers[:])
		if decodeErr != .None {
			State_roomLogFail(state, serverID, room, decodeErr, room.state.version + 1)
			return
		}
		if decoded.version < room.state.version {
			continue // Bound by the hash chain the verified head ends
		}
		if decoded.version == room.state.version {
			if common.hashRoomLogEntry(data) != room.state.headHash {
				State_roomLogFail(state, serverID, room, .Fork, decoded.version)
				return
			}
			continue
		}
		if decoded.version > room.state.version + 1 {
			break // A gap: the fetch after the verified version fills it
		}
		line, _ := roomLogEventFor(&room.state, data)
		if _, err := common.RoomLogState_apply(&room.state, data, ctx); err != .None {
			State_roomLogFail(state, serverID, room, err, decoded.version)
			return
		}
		append(&room.events, line)
		changed = true
	}
	if changed {
		State_roomLogVerifiedChanged(state, serverID, roomID)
	}
}

// After a verified change: store the head, fetch unpinned keys, run what waited, tell E4b.
@(private = "file")
State_roomLogVerifiedChanged :: proc(state: ^State, serverID, roomID: int) {
	room := State_findRoomLog(state, serverID, roomID)
	if room == nil || room.status != .Verified {
		return
	}
	if e2ee, ok := State_e2eeEnsureStore(state, serverID); ok && e2ee != nil {
		if KeyStore_setRoomHead(&e2ee.store, roomID, common.RoomLogState_head(room.state)) {
			State_e2eeSaveStore(state, e2ee)
		}
	}
	// Pin the users the log named on first use (E1 fetches and pins their bundles).
	selfUserID := State_selfUserID(state, serverID)
	unpinned := make([dynamic]int, 0, len(room.state.identities))
	defer delete(unpinned)
	for userID in room.state.identities {
		if userID == selfUserID {
			continue
		}
		if !State_e2eePeerKeyInfo(state, serverID, userID).hasPin {
			append(&unpinned, userID)
		}
	}
	if len(unpinned) > 0 {
		slice.sort(unpinned[:])
		State_e2eeRequestUserKeys(state, serverID, unpinned[:])
	}
	State_roomMembersChanged(state, serverID, roomID)
	State_roomLogRunPendingActions(state, serverID)
	State_roomLogNote(state, serverID, roomID)
	if state.roomLogChanged != nil {
		state.roomLogChanged(state, serverID, roomID)
	}
}

@(private = "file")
State_roomLogFail :: proc(
	state: ^State,
	serverID: int,
	room: ^RoomLogRoom,
	failure: common.RoomLogError,
	failedVersion: int,
) {
	roomID := room.roomID
	common.RoomLogState_deinit(&room.state)
	RoomLogRoom_clearCollecting(room)
	room.status = .Failed
	room.failure = failure
	room.failedVersion = failedVersion
	room.fetching = false
	State_setChatStatus(state, ROOM_LOG_CHANGED_WARNING)
	State_roomLogNote(state, serverID, roomID)
	State_roomMembersChanged(state, serverID, roomID)
	if state.roomLogChanged != nil {
		state.roomLogChanged(state, serverID, roomID)
	}
}

// Keys arrived or a pin changed: every identity a verified log accepted must still be the pin.
State_roomLogsPinsChanged :: proc(state: ^State, serverID: int) {
	index := State_roomLogsIndex(state^, serverID)
	if index < 0 {
		State_roomLogRunPendingCreates(state, serverID)
		return
	}
	source := State_roomLogPinSource(state, serverID)
	for roomIndex := 0; roomIndex < len(state.roomLogs[index].rooms); roomIndex += 1 {
		room := &state.roomLogs[index].rooms[roomIndex]
		if room.status != .Verified {
			continue
		}
		for userID, key in room.state.identities {
			pin, pinned := roomLogLookupPin(&source, userID)
			if pinned && pin != key {
				State_roomLogFail(state, serverID, room, .PinMismatch, room.state.version)
				break
			}
		}
	}
	State_roomLogRunPendingActions(state, serverID)
	State_roomLogRunPendingCreates(state, serverID)
}

@(private = "file")
State_roomLogNote :: proc(state: ^State, serverID, roomID: int) {
	if !state.recordRoomLogNotes {
		return
	}
	for note in state.roomLogNotes {
		if note.serverID == serverID && note.roomID == roomID {
			return
		}
	}
	append(&state.roomLogNotes, RoomLogNote{serverID = serverID, roomID = roomID})
}

// ── Signing ──────────────────────────────────────────────────────

// Builds, checks, signs and sends one entry on roomID's verified head (Create: on an empty
// log). checkRights false skips the local check of the log's rules, so the server's refusal
// shows (the harness). Returns "" when it went out, else why not.
@(private = "file")
State_roomLogSignAndSend :: proc(
	state: ^State,
	serverID, roomID: int,
	entry: ^common.RoomLogEntry,
	checkRights: bool,
) -> string {
	buffer: [common.ROOM_LOG_ENTRY_MAX_BYTES]u8
	n, errorMessage := State_roomLogBuildEntry(
		state,
		serverID,
		roomID,
		entry,
		true,
		checkRights,
		buffer[:],
	)
	if len(errorMessage) > 0 {
		return errorMessage
	}
	return State_sendRoomLogRequest(
		state,
		serverID,
		{kind = .Append, roomID = roomID, entry = buffer[:n]},
	)
}

// Fills entry's head fields, signs it (or, unsigned, leaves actor, key and signature zero),
// encodes it into buffer and, with checkRights, checks it against the verified log.
@(private = "file")
State_roomLogBuildEntry :: proc(
	state: ^State,
	serverID, roomID: int,
	entry: ^common.RoomLogEntry,
	sign: bool,
	checkRights: bool,
	buffer: []u8,
) -> (
	n: int,
	errorMessage: string,
) {
	selfUserID := State_selfUserID(state, serverID)
	if selfUserID <= 0 {
		return 0, NOT_CONNECTED_MESSAGE
	}
	source := State_roomLogPinSource(state, serverID)
	ctx, ctxOK := State_roomLogContext(state, serverID, &source)
	if !ctxOK {
		return 0, NOT_CONNECTED_MESSAGE
	}
	base: ^common.RoomLogState
	empty: common.RoomLogState
	if entry.action == .Create {
		empty = common.RoomLogState_init(roomID)
		base = &empty
	} else {
		room := State_findRoomLog(state, serverID, roomID)
		if room == nil || room.status != .Verified {
			if room != nil && room.status == .Failed {
				return 0, ROOM_LOG_CHANGED_WARNING
			}
			State_requestRoomLog(state, serverID, roomID)
			return 0, "The member list is still loading; try again in a moment."
		}
		base = &room.state
	}
	defer common.RoomLogState_deinit(&empty)
	entry.roomID = roomID
	entry.version = base.version + 1
	entry.prevHash = base.headHash
	entry.createdAt = u64(max(time.time_to_unix(time.now()), 0))
	if sign {
		entry.actorUserID = selfUserID
		privateKey, privateOK := common.identityPrivateKeyFromHex(state.config.private_key)
		defer crypto.zero_explicit(&privateKey, size_of(privateKey))
		if !privateOK {
			return 0, "This profile has no valid identity key"
		}
		if err := common.signRoomLogEntry(entry, ctx.serverIdentityPublicKey, privateKey);
		   err != .None {
			return 0, fmt.tprintf("The member list entry could not be signed (%v).", err)
		}
	} else {
		entry.actorUserID = 0
		entry.actorIdentityKey = {}
		entry.signature = {}
	}
	encoded, encodeErr := common.encodeRoomLogEntry(entry^, buffer)
	if encodeErr != .None {
		return 0, fmt.tprintf("The member list entry could not be encoded (%v).", encodeErr)
	}
	if checkRights {
		if _, err := common.RoomLogState_validate(base, buffer[:encoded], ctx); err != .None {
			return 0, State_roomLogRefusalText(state, serverID, roomID, entry^, err)
		}
	}
	return encoded, ""
}

// An entry for the harness's room-log-entry: action on targetUserID (this account for Leave),
// built on the verified head, signed or not, never sent or checked. entry is hex (owned).
State_roomLogEncodeEntry :: proc(
	state: ^State,
	serverID, roomID: int,
	action: common.RoomLogAction,
	targetUserID: int,
	sign: bool,
) -> (
	entryHex: string,
	version: int,
	errorMessage: string,
) {
	entry := common.RoomLogEntry {
		action       = action,
		targetUserID = targetUserID,
	}
	key, ok := State_roomLogIdentityFor(state, serverID, targetUserID)
	if !ok {
		if verified := State_roomLogVerified(state, serverID, roomID); verified != nil {
			key, ok = verified.identities[targetUserID]
		}
	}
	if !ok {
		return "", 0, "No pinned key for that account; fetch it first (user-keys)."
	}
	entry.targetIdentityKey = key
	buffer: [common.ROOM_LOG_ENTRY_MAX_BYTES]u8
	n, buildError := State_roomLogBuildEntry(
		state,
		serverID,
		roomID,
		&entry,
		sign,
		false,
		buffer[:],
	)
	if len(buildError) > 0 {
		return "", 0, buildError
	}
	return common.encodeBytesToHex(buffer[:n]), entry.version, ""
}

// The sentence for a change the verified log refuses.
@(private = "file")
State_roomLogRefusalText :: proc(
	state: ^State,
	serverID, roomID: int,
	entry: common.RoomLogEntry,
	err: common.RoomLogError,
) -> string {
	target := State_roomLogUserName(state, serverID, entry.targetUserID)
	#partial switch err {
	case .NotAuthorized:
		if entry.action == .Add {
			return fmt.tprintf(
				"Only this room's managers can add members; ask %s.",
				State_roomLogManagerNames(state, serverID, roomID),
			)
		}
		return "Only this room's managers can make this change."
	case .AlreadyMember:
		return fmt.tprintf("%s is already a member.", target)
	case .NotMember:
		return fmt.tprintf("%s is not a member.", target)
	case .AlreadyManager:
		return fmt.tprintf("%s is already a manager.", target)
	case .NotManager:
		return fmt.tprintf("%s is not a manager.", target)
	case .LastManager:
		return "The last manager cannot be removed while the room has members."
	case .RoomFull:
		return common.ENCRYPTED_ROOM_FULL_MESSAGE + "."
	case .PinMismatch:
		return fmt.tprintf("%s's key does not match the one you pinned.", target)
	}
	return fmt.tprintf("The member list does not allow this change (%v).", err)
}

// userLabel of an account from the directory.
State_roomLogUserName :: proc(state: ^State, serverID, userID: int) -> string {
	name := ""
	if index := State_serverDirectCacheIndex(state^, serverID); index >= 0 {
		name = ServerDirectCache_peerNickname(&state.serverDirectCaches[index], userID)
	}
	return userLabel(name, userID, context.temp_allocator)
}

// "alice, bob" for the room's verified managers (temp).
State_roomLogManagerNames :: proc(state: ^State, serverID, roomID: int) -> string {
	verified := State_roomLogVerified(state, serverID, roomID)
	if verified == nil {
		return "a manager"
	}
	ids := make([dynamic]int, 0, len(verified.managers), context.temp_allocator)
	for userID in verified.managers {
		append(&ids, userID)
	}
	slice.sort(ids[:])
	builder := strings.builder_make(context.temp_allocator)
	for userID, index in ids {
		if index > 0 {
			strings.write_string(&builder, ", ")
		}
		strings.write_string(&builder, State_roomLogUserName(state, serverID, userID))
	}
	return strings.to_string(builder)
}

// The identity key to name userID with: this profile's own, or the pin. ok false without one.
@(private = "file")
State_roomLogIdentityFor :: proc(
	state: ^State,
	serverID, userID: int,
) -> (
	key: common.IdentityPublicKeyBytes,
	ok: bool,
) {
	source := State_roomLogPinSource(state, serverID)
	return roomLogLookupPin(&source, userID)
}

// One signed change of roomID's log: Add, Remove, AddManager, RemoveManager, Leave (target
// this account) or SetAccess (access). A target without a pin is fetched first and the change
// waits for it (queued is true then). Returns "" when it went out or was queued.
State_roomLogAppend :: proc(
	state: ^State,
	serverID, roomID: int,
	action: common.RoomLogAction,
	targetUserID := 0,
	access := common.RoomLogAccess.MemberInvite,
	checkRights := true,
) -> (
	errorMessage: string,
	queued: bool,
) {
	entry := common.RoomLogEntry {
		action = action,
	}
	switch action {
	case .Create:
		return "Rooms are created through the room form.", false
	case .SetAccess:
		verified := State_roomLogVerified(state, serverID, roomID)
		if verified == nil {
			return State_roomLogNotReady(state, serverID, roomID), false
		}
		entry.settings = {
			access            = access,
			historyVisibility = verified.historyVisibility,
		}
	case .Leave:
		selfUserID := State_selfUserID(state, serverID)
		key, ok := State_roomLogIdentityFor(state, serverID, selfUserID)
		if !ok {
			return "This profile has no valid identity key", false
		}
		entry.targetUserID = selfUserID
		entry.targetIdentityKey = key
	case .Add, .Remove, .AddManager, .RemoveManager:
		if targetUserID <= 0 {
			return "No account to change.", false
		}
		key, ok := State_roomLogIdentityFor(state, serverID, targetUserID)
		if !ok {
			// Removals name the key the log already holds; additions need a pin first.
			verified := State_roomLogVerified(state, serverID, roomID)
			known, inLog := common.IdentityPublicKeyBytes{}, false
			if verified != nil {
				known, inLog = verified.identities[targetUserID]
			}
			if inLog && (action == .Remove || action == .RemoveManager) {
				key, ok = known, true
			}
		}
		if !ok {
			info := State_e2eePeerKeyInfo(state, serverID, targetUserID)
			if info.state != .Unknown {
				return fmt.tprintf(
					"%s has no encryption key to pin yet, so they cannot be added.",
					State_roomLogUserName(state, serverID, targetUserID),
				),
				false
			}
			State_e2eeRequestUserKeys(state, serverID, {targetUserID})
			append(
				&state.roomLogPendingActions,
				RoomLogPendingAction {
					serverID = serverID,
					roomID = roomID,
					action = action,
					targetUserID = targetUserID,
					checkRights = checkRights,
				},
			)
			return "", true
		}
		entry.targetUserID = targetUserID
		entry.targetIdentityKey = key
	}
	return State_roomLogSignAndSend(state, serverID, roomID, &entry, checkRights), false
}

@(private = "file")
State_roomLogNotReady :: proc(state: ^State, serverID, roomID: int) -> string {
	if room := State_findRoomLog(state, serverID, roomID); room != nil && room.status == .Failed {
		return ROOM_LOG_CHANGED_WARNING
	}
	State_requestRoomLog(state, serverID, roomID)
	return "The member list is still loading; try again in a moment."
}

// Sends the changes that waited for a key, once their target is pinned or cannot be.
@(private = "file")
State_roomLogRunPendingActions :: proc(state: ^State, serverID: int) {
	for index := 0; index < len(state.roomLogPendingActions); {
		pending := state.roomLogPendingActions[index]
		if pending.serverID != serverID {
			index += 1
			continue
		}
		info := State_e2eePeerKeyInfo(state, serverID, pending.targetUserID)
		if !info.hasPin && info.state == .Unknown {
			index += 1 // Still being fetched
			continue
		}
		if State_roomLogVerified(state, serverID, pending.roomID) == nil {
			index += 1
			continue
		}
		ordered_remove(&state.roomLogPendingActions, index)
		errorMessage, _ := State_roomLogAppend(
			state,
			serverID,
			pending.roomID,
			pending.action,
			pending.targetUserID,
			checkRights = pending.checkRights,
		)
		State_roomLogActionAnswered(state, serverID, pending.roomID, errorMessage)
	}
}

// Shows a change's local refusal on the Members page when it shows the room, else as the chat
// status.
State_roomLogActionAnswered :: proc(state: ^State, serverID, roomID: int, errorMessage: string) {
	if len(errorMessage) == 0 {
		return
	}
	editor := &state.roomEditor
	if editor.mode == .Members && editor.serverID == serverID && editor.roomID == roomID {
		RoomEditor_setError(editor, errorMessage)
		return
	}
	State_setChatStatus(state, errorMessage)
}

// ── Creating ─────────────────────────────────────────────────────

// Every admin this client sees on serverID (the create form's managers, Q10), this account
// first, then by name. Temp.
State_roomLogAdminCandidates :: proc(state: ^State, serverID: int) -> []int {
	ids := make([dynamic]int, 0, context.temp_allocator)
	selfUserID := State_selfUserID(state, serverID)
	if selfUserID > 0 {
		append(&ids, selfUserID)
	}
	if index := State_serverDirectCacheIndex(state^, serverID); index >= 0 {
		users := slice.clone(state.serverDirectCaches[index].users[:], context.temp_allocator)
		slice.sort_by(users, proc(a, b: common.UserSummary) -> bool {
			if a.nickname != b.nickname {
				return a.nickname < b.nickname
			}
			return a.id < b.id
		})
		for user in users {
			if user.isAdmin && user.id != selfUserID && !user.isBanned {
				append(&ids, user.id)
			}
		}
	}
	return ids[:]
}

// Whether userID can be named as a manager now: this account, or a pinned key that is not
// blocked.
State_roomLogManagerReady :: proc(state: ^State, serverID, userID: int) -> bool {
	if userID == State_selfUserID(state, serverID) {
		return true
	}
	info := State_e2eePeerKeyInfo(state, serverID, userID)
	return info.hasPin && (info.state == .Unverified || info.state == .Verified)
}

// Starts creating an encrypted room: the managers' keys are fetched first when needed, then
// ClientCreateRoom goes out (encrypted), and the Create entry follows ServerCreateRoom. The
// name and description are validated by the caller (State_sendCreateRoom).
State_roomLogBeginCreate :: proc(
	state: ^State,
	serverID: int,
	name, description: string,
	roomType: common.RoomType,
	access: common.RoomAccess,
	history: common.RoomHistoryVisibility,
	creatorJoins: bool,
	managers: []int,
) -> string {
	if access != .MemberInvite && access != .AdminInvite {
		return common.ENCRYPTED_ROOM_PUBLIC_MESSAGE + "."
	}
	selfUserID := State_selfUserID(state, serverID)
	if selfUserID <= 0 {
		return NOT_CONNECTED_MESSAGE
	}
	if _, storeOK := State_e2eeEnsureStore(state, serverID); !storeOK {
		return NOT_CONNECTED_MESSAGE
	}
	pending := RoomLogPendingCreate {
		serverID     = serverID,
		name         = strings.clone(name),
		description  = strings.clone(description),
		roomType     = roomType,
		access       = access,
		history      = history,
		creatorJoins = creatorJoins,
		managers     = make([dynamic]int, 0, len(managers) + 1),
	}
	append(&pending.managers, selfUserID)
	for userID in managers {
		if userID > 0 && !slice.contains(pending.managers[:], userID) {
			append(&pending.managers, userID)
		}
	}
	if len(pending.managers) > common.ROOM_LOG_MANAGERS_MAX {
		RoomLogPendingCreate_deinit(&pending)
		return "An encrypted room can name at most 100 managers."
	}
	missing := make([dynamic]int, 0, len(pending.managers), context.temp_allocator)
	for userID in pending.managers {
		if !State_roomLogManagerReady(state, serverID, userID) {
			info := State_e2eePeerKeyInfo(state, serverID, userID)
			if info.state != .Unknown {
				errorMessage := fmt.tprintf(
					"%s cannot be a manager: %s",
					State_roomLogUserName(state, serverID, userID),
					e2eeKeyStateText(info, State_roomLogUserName(state, serverID, userID)),
				)
				RoomLogPendingCreate_deinit(&pending)
				return errorMessage
			}
			append(&missing, userID)
		}
	}
	append(&state.roomLogPendingCreates, pending)
	if len(missing) > 0 {
		State_e2eeRequestUserKeys(state, serverID, missing[:])
		return ""
	}
	return State_roomLogSendPendingCreate(state, len(state.roomLogPendingCreates) - 1)
}

@(private = "file")
State_roomLogSendPendingCreate :: proc(state: ^State, index: int) -> string {
	pending := &state.roomLogPendingCreates[index]
	errorMessage := State_sendRoomAdminCreate(
		state,
		pending.serverID,
		pending.name,
		pending.description,
		pending.roomType,
		pending.access,
		pending.history,
		pending.creatorJoins,
		true,
	)
	if len(errorMessage) > 0 {
		RoomLogPendingCreate_deinit(pending)
		ordered_remove(&state.roomLogPendingCreates, index)
		return errorMessage
	}
	pending.sent = true
	return ""
}

// Keys arrived: creates that waited for their managers go out, or end with the reason.
@(private = "file")
State_roomLogRunPendingCreates :: proc(state: ^State, serverID: int) {
	for index := 0; index < len(state.roomLogPendingCreates); {
		pending := &state.roomLogPendingCreates[index]
		if pending.serverID != serverID || pending.sent {
			index += 1
			continue
		}
		waiting := false
		blocked := ""
		for userID in pending.managers {
			if State_roomLogManagerReady(state, serverID, userID) {
				continue
			}
			info := State_e2eePeerKeyInfo(state, serverID, userID)
			if info.state == .Unknown {
				waiting = true
			} else {
				name := State_roomLogUserName(state, serverID, userID)
				blocked = fmt.tprintf(
					"%s cannot be a manager: %s",
					name,
					e2eeKeyStateText(info, name),
				)
			}
		}
		if waiting && len(blocked) == 0 {
			index += 1
			continue
		}
		if len(blocked) > 0 {
			RoomLogPendingCreate_deinit(pending)
			ordered_remove(&state.roomLogPendingCreates, index)
			State_roomLogCreateFailed(state, serverID, blocked)
			continue
		}
		if errorMessage := State_roomLogSendPendingCreate(state, index); len(errorMessage) > 0 {
			State_roomLogCreateFailed(state, serverID, errorMessage)
			continue
		}
		index += 1
	}
}

@(private = "file")
State_roomLogCreateFailed :: proc(state: ^State, serverID: int, message: string) {
	editor := &state.roomEditor
	if editor.mode == .Create && editor.serverID == serverID && editor.pending == .Create {
		editor.pending = .None
		RoomEditor_setError(editor, message)
		return
	}
	State_setChatStatus(state, message)
}

// ServerCreateRoom for an encrypted room at version 0: if this session asked for it, sign and
// send its Create entry.
State_roomLogRoomCreated :: proc(state: ^State, serverID: int, room: common.RoomSummary) {
	if !room.encrypted || room.logVersion != 0 {
		return
	}
	for index in 0 ..< len(state.roomLogPendingCreates) {
		pending := &state.roomLogPendingCreates[index]
		if pending.serverID != serverID || !pending.sent || pending.name != room.name {
			continue
		}
		managers := make([dynamic]common.RoomLogManager, 0, len(pending.managers))
		defer delete(managers)
		missing := ""
		for userID in pending.managers {
			key, ok := State_roomLogIdentityFor(state, serverID, userID)
			if !ok {
				missing = State_roomLogUserName(state, serverID, userID)
				break
			}
			append(&managers, common.RoomLogManager{userID = userID, identityKey = key})
		}
		entry := common.RoomLogEntry {
			action = .Create,
			settings = {
				access = common.RoomLogAccess(u8(pending.access)),
				historyVisibility = common.RoomLogHistoryVisibility(u8(pending.history)),
				creatorJoins = pending.creatorJoins,
				managers = managers[:],
			},
		}
		errorMessage := ""
		if len(missing) > 0 {
			errorMessage = fmt.tprintf("%s's key is no longer pinned.", missing)
		} else {
			selfUserID := State_selfUserID(state, serverID)
			entry.targetUserID = selfUserID
			entry.targetIdentityKey, _ = State_roomLogIdentityFor(state, serverID, selfUserID)
			errorMessage = State_roomLogSignAndSend(state, serverID, room.id, &entry, true)
		}
		RoomLogPendingCreate_deinit(pending)
		ordered_remove(&state.roomLogPendingCreates, index)
		// The room starts as Verified at version 0 until its Create comes back.
		log := State_roomLogRoom(state, serverID, room.id)
		if log.status == .Unknown {
			common.RoomLogState_deinit(&log.state)
			log.state = common.RoomLogState_init(room.id)
			log.status = .Verified
		}
		if len(errorMessage) > 0 {
			State_setChatStatus(
				state,
				fmt.tprintf("The encrypted room could not be set up: %s", errorMessage),
			)
		}
		return
	}
}

// Requests in flight died with the session; creates that waited for keys end too.
State_roomLogPendingConnectionReset :: proc(state: ^State, serverID: int) {
	for index := len(state.roomLogPendingCreates) - 1; index >= 0; index -= 1 {
		if state.roomLogPendingCreates[index].serverID == serverID {
			RoomLogPendingCreate_deinit(&state.roomLogPendingCreates[index])
			ordered_remove(&state.roomLogPendingCreates, index)
		}
	}
	for index := len(state.roomLogPendingActions) - 1; index >= 0; index -= 1 {
		if state.roomLogPendingActions[index].serverID == serverID {
			ordered_remove(&state.roomLogPendingActions, index)
		}
	}
}

State_roomLogDeinit :: proc(state: ^State) {
	for &logs in state.roomLogs {
		ServerRoomLogs_deinit(&logs)
	}
	delete(state.roomLogs)
	for &pending in state.roomLogPendingCreates {
		RoomLogPendingCreate_deinit(&pending)
	}
	delete(state.roomLogPendingCreates)
	delete(state.roomLogPendingActions)
	delete(state.roomLogNotes)
}

State_removeServerRoomLogs :: proc(state: ^State, serverID: int) {
	if index := State_roomLogsIndex(state^, serverID); index >= 0 {
		ServerRoomLogs_deinit(&state.roomLogs[index])
		ordered_remove(&state.roomLogs, index)
	}
	State_roomLogPendingConnectionReset(state, serverID)
}

// ── Rights and text ──────────────────────────────────────────────

// What this account may do to an encrypted room's members, from the verified log and the
// admin flag; the server checks again (an add needs its permission and a valid signature).
RoomLogRights :: struct {
	status:            RoomLogStatus,
	isMember:          bool, // In the verified log
	isManager:         bool,
	isAdmin:           bool,
	access:            common.RoomLogAccess,
	canAdd:            bool,
	// Why Add is not offered to an admin who may not sign it.
	addNote:           string,
	canRemove:         bool, // A manager signs; an admin who is not one asks the server
	removeViaServer:   bool,
	canLeave:          bool,
	canManageManagers: bool,
	canSetAccess:      bool,
}

roomLogRights :: proc(state: ^State, serverID, roomID: int) -> (rights: RoomLogRights) {
	rights.isAdmin = State_isServerAdmin(state, serverID)
	room := State_findRoomLog(state, serverID, roomID)
	if room == nil {
		return
	}
	rights.status = room.status
	if room.status != .Verified || room.state.version == 0 {
		rights.canRemove = rights.isAdmin && room.status == .Verified
		rights.removeViaServer = rights.canRemove
		return
	}
	selfUserID := State_selfUserID(state, serverID)
	rights.isMember = common.RoomLogState_isMember(room.state, selfUserID)
	rights.isManager = common.RoomLogState_isManager(room.state, selfUserID)
	rights.access = room.state.access
	memberInvite := room.state.access == .MemberInvite
	// The log's rule and the server's (an admin, or a member of a Member invite room).
	logAllows := rights.isManager || (memberInvite && rights.isMember)
	serverAllows := rights.isAdmin || (memberInvite && rights.isMember)
	rights.canAdd = logAllows && serverAllows
	if rights.canAdd && len(room.state.members) >= common.ENCRYPTED_ROOM_MEMBERS_MAX {
		// The Members page says so before anything is sent (design 6.1).
		rights.canAdd = false
		rights.addNote = common.ENCRYPTED_ROOM_FULL_MESSAGE + "."
	} else if !rights.canAdd && rights.isAdmin {
		rights.addNote = fmt.tprintf(
			"Only this room's managers can add members; ask %s.",
			State_roomLogManagerNames(state, serverID, roomID),
		)
	}
	rights.canRemove = rights.isManager || rights.isAdmin
	rights.removeViaServer = !rights.isManager && rights.isAdmin
	rights.canLeave = rights.isMember
	rights.canManageManagers = rights.isManager
	rights.canSetAccess = rights.isManager && rights.isAdmin
	return
}

// One event line's text (temp): "alice added carol", "the server removed dave", "erin
// (manager) added themselves".
State_roomLogEventText :: proc(state: ^State, serverID: int, line: RoomLogEventLine) -> string {
	actor := State_roomLogUserName(state, serverID, line.actorUserID)
	target := State_roomLogUserName(state, serverID, line.targetUserID)
	switch line.action {
	case .Create:
		return fmt.tprintf(
			"%s created this encrypted room (%s, %d manager%s)",
			actor,
			line.access == .MemberInvite ? "members invite" : "admins invite",
			line.managerCount,
			line.managerCount == 1 ? "" : "s",
		)
	case .Add:
		if line.actorUserID == line.targetUserID {
			if line.actorWasManager {
				return fmt.tprintf("%s (manager) added themselves", actor)
			}
			return fmt.tprintf("%s added themselves", actor)
		}
		return fmt.tprintf("%s added %s", actor, target)
	case .Remove:
		if line.actorUserID == 0 {
			return fmt.tprintf("the server removed %s", target)
		}
		return fmt.tprintf("%s removed %s", actor, target)
	case .AddManager:
		return fmt.tprintf("%s made %s a manager", actor, target)
	case .RemoveManager:
		return fmt.tprintf("%s removed %s as a manager", actor, target)
	case .Leave:
		return fmt.tprintf("%s left", target)
	case .SetAccess:
		if line.access == .MemberInvite {
			return fmt.tprintf("%s let members invite people", actor)
		}
		return fmt.tprintf("%s let only admins who manage the room invite people", actor)
	}
	return ""
}
