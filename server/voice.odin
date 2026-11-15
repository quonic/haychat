package server

import "../common"
import "core:encoding/cbor"

// The voice control plane (voice-rooms-design.md 4.2). The router is the single source of truth
// for who is in which room's voice session: joining needs the database membership check, and
// the participant list goes to room members over the reliable channel. Every change is pushed
// to the network thread as a full NetworkVoiceRoute, and the VoiceRelay there moves the frames
// (voice_relay.odin). The router never sees a frame and never touches voice crypto after it
// hands a session's voice halves over at auth success.
//
// One voice session per user (Q2, protocol 13): a voice session belongs to a client session,
// but an account has at most one, so a participant list names each user once. A join the user
// asked for takes voice over from the account's other session (ServerVoiceLeft "joined voice on
// another device"). The client's automatic re-join after a reconnect (ClientJoinVoice.rejoin)
// replaces only a session with the same device ID, a stale one the server has not timed out
// yet, and is refused while another device is in voice, so a laptop coming back from a network
// drop never pulls voice away from the phone the user switched to.

// Reasons sent to people in ServerVoiceJoinRejected and ServerVoiceLeft.
VOICE_REJECT_NOT_AUTHENTICATED :: "not authenticated"
VOICE_REJECT_INVALID_ROOM :: "invalid room"
VOICE_REJECT_DISABLED :: "voice is disabled"
VOICE_REJECT_NOT_MEMBER :: "not a room member"
VOICE_REJECT_FULL :: "voice room is full"
VOICE_REJECT_UNAVAILABLE :: "voice is unavailable, try again"
VOICE_REJECT_INVALID_DEVICE :: "invalid voice device ID"
VOICE_REJECT_ACTIVE_ON_OTHER_DEVICE :: "voice is active on another device"
VOICE_LEFT_JOINED_OTHER_ROOM :: "joined another voice room"
VOICE_LEFT_REMOVED_FROM_ROOM :: "removed from the room"
VOICE_LEFT_ROOM_DELETED :: "the room was deleted"
VOICE_LEFT_JOINED_ON_OTHER_DEVICE :: "joined voice on another device"
// Protocol 14: a join of a text-only room is refused, and editing a room to text-only removes
// its participants, with the same sentence.
VOICE_REJECT_TEXT_ONLY :: "voice is disabled in this room"
VOICE_LEFT_TEXT_ONLY :: VOICE_REJECT_TEXT_ONLY

VoiceParticipantState :: struct {
	peerID:   u32,
	userID:   int,
	muted:    bool,
	deafened: bool,
	// The device ID the session joined with. Compared only when an automatic re-join of the
	// same user arrives, never sent to anyone.
	deviceID: common.VoiceDeviceID,
}

VoiceRoomState :: struct {
	roomID:        int,
	participants:  [dynamic]VoiceParticipantState, // small: linear scans are fine
	// Who hears about this room's participant changes. Leaves, mute changes and disconnects
	// use this cached member list instead of asking the database again (the design left the
	// choice to this step): a leave or a disconnect must fan out even while the database is
	// slow or restarting, and a mute toggle should not cost a query. The cache is exact for
	// every event the router sees: each join check replaces it with the database's list, a
	// room list or an added member adds the user (a new account joins every room, and its
	// client lists rooms before it can see this one), and a member removal takes the user out.
	memberUserIDs: [dynamic]int,
}

VoiceRoomState_deinit :: proc(room: ^VoiceRoomState) {
	delete(room.participants)
	delete(room.memberUserIDs)
	room^ = {}
}

// Frees every voice room and both maps. MainRouterState_deinit and the network-stop reset use it.
MainRouterState_voiceFreeState :: proc(state: ^MainRouterState) {
	for _, &room in state.voiceRooms {
		VoiceRoomState_deinit(&room)
	}
	delete(state.voiceRooms)
	delete(state.peerVoiceRoom)
	state.voiceRooms = nil
	state.peerVoiceRoom = nil
}

// Drops all voice state when the network service stops: every peer is disconnected with it, so
// there is nobody to tell. NetworkVoiceReset makes the network thread forget its sessions and
// routes too, including any that are still queued from before the stop.
MainRouterState_voiceReset :: proc(pm: ^ProcessManager, state: ^MainRouterState) {
	MainRouterState_voiceFreeState(state)
	state.voiceRooms = make(map[int]VoiceRoomState)
	state.peerVoiceRoom = make(map[u32]int)
	IPC_Server_send(&pm.config.networkSocket, pm.config.networkFd, NetworkVoiceReset{})
}

MainRouterState_voiceCounts :: proc(state: ^MainRouterState) -> (rooms: int, participants: int) {
	for _, room in state.voiceRooms {
		participants += len(room.participants)
	}
	return len(state.voiceRooms), participants
}

// Moves a session's voice halves to the network thread right after ServerAuthSuccess. send and
// receive are wiped here, and the local message copy after it is queued, so the queued message
// is the only copy until the relay takes it over.
MainRouterState_sendVoiceSessionOpen :: proc(
	pm: ^ProcessManager,
	peerID: u32,
	userID: int,
	sessionID: common.SessionID,
	send: ^common.ChannelSendState,
	receive: ^common.VoiceReceiveState,
) {
	msg := NetworkVoiceSessionOpen {
		peerId    = peerID,
		userId    = userID,
		sessionID = sessionID,
		send      = send^,
		receive   = receive^,
	}
	common.ChannelSendState_wipe(send)
	common.VoiceReceiveState_wipe(receive)
	IPC_Server_send(&pm.config.networkSocket, pm.config.networkFd, msg)
	common.ChannelSendState_wipe(&msg.send)
	common.VoiceReceiveState_wipe(&msg.receive)
}

// Sends the network thread roomID's complete recipient set; an empty set removes the room.
MainRouterState_voiceSendRoute :: proc(pm: ^ProcessManager, state: ^MainRouterState, roomID: int) {
	members: []NetworkVoiceRouteMember
	if room, ok := state.voiceRooms[roomID]; ok && len(room.participants) > 0 {
		members = make([]NetworkVoiceRouteMember, len(room.participants))
		for participant, index in room.participants {
			members[index] = NetworkVoiceRouteMember {
				peerId   = participant.peerID,
				muted    = participant.muted,
				deafened = participant.deafened,
			}
		}
	}
	IPC_Server_send(
		&pm.config.networkSocket,
		pm.config.networkFd,
		NetworkVoiceRoute{roomId = roomID, members = members},
	)
}

// Whether peerID's own session is in roomID's voice: what ServerVoiceParticipants tells that
// session in recipientJoined, so a client completes its join only on its own acknowledgement.
MainRouterState_voicePeerIsInRoom :: proc(
	state: ^MainRouterState,
	peerID: u32,
	roomID: int,
) -> bool {
	inRoomID, inVoice := state.peerVoiceRoom[peerID]
	return inVoice && inRoomID == roomID
}

// Builds roomID's full participant set. The nicknames are borrowed from the peer sessions, so
// the caller frees only the array (delete(payload.participants)), right after sending.
// recipientJoined is left false; senders set it per recipient session.
MainRouterState_voiceBuildParticipants :: proc(
	state: ^MainRouterState,
	room: VoiceRoomState,
) -> common.ServerVoiceParticipantsPayload {
	payload := common.ServerVoiceParticipantsPayload {
		roomId       = room.roomID,
		participants = make([dynamic]common.VoiceParticipant, 0, len(room.participants)),
	}
	for participant in room.participants {
		session, _ := MainRouterState_getPeerSession(state, participant.peerID)
		append(
			&payload.participants,
			common.VoiceParticipant {
				userId = participant.userID,
				nickname = session.clientNickname,
				muted = participant.muted,
				deafened = participant.deafened,
			},
		)
	}
	return payload
}

// Tells the network thread and every live session of every room member about roomID's current
// participants, then drops the room if nobody is left. The empty set still goes out, so clients
// clear the room. skipPeerID (0 for none) is a session that is going away and must not be sent
// anything.
MainRouterState_voiceRoomChanged :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	roomID: int,
	skipPeerID: u32 = 0,
) {
	MainRouterState_voiceSendRoute(pm, state, roomID)
	room, ok := &state.voiceRooms[roomID]
	if !ok {
		return
	}

	payload := MainRouterState_voiceBuildParticipants(state, room^)
	defer delete(payload.participants)
	for recipientPeerID, recipientSession in state.peerSessions {
		if recipientPeerID != skipPeerID &&
		   recipientSession.isAuthenticated &&
		   MainRouterState_hasRecipientUserID(
			   room.memberUserIDs[:],
			   recipientSession.authenticatedUserID,
		   ) {
			payload.recipientJoined = MainRouterState_voicePeerIsInRoom(
				state,
				recipientPeerID,
				roomID,
			)
			MainRouterState_sendPeerMessage(
				pm,
				state,
				recipientPeerID,
				.ServerVoiceParticipants,
				payload,
			)
		}
	}

	if len(room.participants) == 0 {
		VoiceRoomState_deinit(room)
		delete_key(&state.voiceRooms, roomID)
	}
}

// peerID's participant entry, if it is in voice.
MainRouterState_voiceFindParticipant :: proc(
	state: ^MainRouterState,
	peerID: u32,
) -> (
	participant: VoiceParticipantState,
	found: bool,
) {
	roomID, inVoice := state.peerVoiceRoom[peerID]
	if !inVoice {
		return {}, false
	}
	room, ok := state.voiceRooms[roomID]
	if !ok {
		return {}, false
	}
	for candidate in room.participants {
		if candidate.peerID == peerID {
			return candidate, true
		}
	}
	return {}, false
}

// Takes peerID out of its voice room without telling anyone, and reports which room it was in.
MainRouterState_voiceRemoveParticipant :: proc(
	state: ^MainRouterState,
	peerID: u32,
) -> (
	roomID: int,
	removed: bool,
) {
	roomID, removed = state.peerVoiceRoom[peerID]
	if !removed {
		return 0, false
	}
	delete_key(&state.peerVoiceRoom, peerID)
	if room, ok := &state.voiceRooms[roomID]; ok {
		for index := 0; index < len(room.participants); index += 1 {
			if room.participants[index].peerID == peerID {
				ordered_remove(&room.participants, index)
				index -= 1
			}
		}
	}
	return roomID, true
}

// Ends peerID's voice session, if it has one, and fans the change out. A session that is going
// away (disconnect, protocol violation) passes skipSelf, so it is sent nothing.
MainRouterState_voiceLeave :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	skipSelf := false,
) {
	roomID, removed := MainRouterState_voiceRemoveParticipant(state, peerID)
	if !removed {
		return
	}
	MainRouterState_voiceRoomChanged(pm, state, roomID, peerID if skipSelf else 0)
}

MainRouterState_voiceAddMemberUserID :: proc(room: ^VoiceRoomState, userID: int) {
	if !MainRouterState_hasRecipientUserID(room.memberUserIDs[:], userID) {
		append(&room.memberUserIDs, userID)
	}
}

// Records that userID is a member of roomID, if that room has voice. See memberUserIDs.
MainRouterState_voiceNoteRoomMember :: proc(state: ^MainRouterState, roomID: int, userID: int) {
	if room, ok := &state.voiceRooms[roomID]; ok {
		MainRouterState_voiceAddMemberUserID(room, userID)
	}
}

MainRouterState_sendVoiceJoinRejected :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	roomID: int,
	reason: string,
) {
	MainRouterState_sendPeerMessage(
		pm,
		state,
		peerID,
		.ServerVoiceJoinRejected,
		common.ServerVoiceJoinRejectedPayload{roomId = roomID, reason = reason},
	)
}

MainRouterState_sendVoiceLeft :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	roomID: int,
	reason: string,
) {
	MainRouterState_sendPeerMessage(
		pm,
		state,
		peerID,
		.ServerVoiceLeft,
		common.ServerVoiceLeftPayload{roomId = roomID, reason = reason},
	)
}

// ClientJoinVoice: cheap checks here, then the database membership check. The rest happens in
// MainRouterState_handleJoinVoiceMemberCheckResult.
MainRouterState_handleClientJoinVoice :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	payload: []u8,
) {
	req: common.ClientJoinVoicePayload
	defer common.ClientJoinVoicePayload_deinit(&req)
	if cbor.unmarshal(payload, &req) != nil {
		MainRouterState_sendProtocolError(pm, state, peerID, "Invalid ClientJoinVoice payload")
		return
	}
	session, ok := MainRouterState_getPeerSession(state, peerID)
	if !ok || !session.isAuthenticated {
		MainRouterState_sendVoiceJoinRejected(
			pm,
			state,
			peerID,
			req.roomId,
			VOICE_REJECT_NOT_AUTHENTICATED,
		)
		return
	}
	if !pm.config.voiceEnabled {
		MainRouterState_sendVoiceJoinRejected(pm, state, peerID, req.roomId, VOICE_REJECT_DISABLED)
		return
	}
	if req.roomId <= 0 {
		MainRouterState_sendVoiceJoinRejected(
			pm,
			state,
			peerID,
			req.roomId,
			VOICE_REJECT_INVALID_ROOM,
		)
		return
	}
	// A malformed device ID is the client's mistake, not an attack worth a disconnect: refuse
	// the join and keep the session.
	deviceID, deviceOK := common.voiceDeviceIDFromHex(req.deviceId)
	if !deviceOK {
		MainRouterState_sendVoiceJoinRejected(
			pm,
			state,
			peerID,
			req.roomId,
			VOICE_REJECT_INVALID_DEVICE,
		)
		return
	}
	MainRouterState_enqueueChannelDatabaseRequest(
		pm,
		state,
		peerID,
		common.DatabaseRoomMemberListRequest{roomId = req.roomId},
		PendingDBRequest {
			requestType = .JoinVoiceMemberCheck,
			roomID = req.roomId,
			voiceMuted = req.muted,
			voiceDeafened = req.deafened,
			voiceRejoin = req.rejoin,
			voiceDeviceID = deviceID,
		},
	)
}

MainRouterState_handleJoinVoiceMemberCheckResult :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	request: PendingDBRequest,
	response: common.DatabaseQueryResponse,
) {
	peerID := request.peerID
	roomID := request.roomID
	session, sessionOK := MainRouterState_getPeerSession(state, peerID)
	if !sessionOK || !session.isAuthenticated {
		return // the session ended while the check ran
	}
	members, membersOK := response.result.(common.DatabaseRoomMemberListResult)
	if !response.success || !membersOK {
		MainRouterState_sendVoiceJoinRejected(pm, state, peerID, roomID, VOICE_REJECT_UNAVAILABLE)
		return
	}
	if !members.roomFound ||
	   !MainRouterState_hasRecipientUserID(members.userIDs[:], session.authenticatedUserID) {
		MainRouterState_sendVoiceJoinRejected(pm, state, peerID, roomID, VOICE_REJECT_NOT_MEMBER)
		return
	}
	// After the membership check, so the refusal tells a non-member nothing about the room.
	if !common.roomTypeAllowsVoice(members.roomType) {
		MainRouterState_sendVoiceJoinRejected(pm, state, peerID, roomID, VOICE_REJECT_TEXT_ONLY)
		return
	}
	// Protocol 18: voice in an encrypted room would be readable by the server; encrypted voice
	// is a later package (E6), so joins are refused until then.
	if members.encrypted {
		MainRouterState_sendVoiceJoinRejected(
			pm,
			state,
			peerID,
			roomID,
			common.ENCRYPTED_ROOM_VOICE_MESSAGE,
		)
		return
	}

	// The account's other session in voice, if any (one at most, but the scan does not rely on
	// it). The decisions come first, before anything changes, so a refused join leaves every
	// session where it was.
	userID := session.authenticatedUserID
	// The router loop never frees the temporary allocator, so this uses the heap and frees
	// itself; a per-join temporary allocation would grow for as long as the server runs.
	otherPeerIDs := make([dynamic]u32, 0, 1)
	defer delete(otherPeerIDs)
	otherInTarget := 0
	for otherPeerID, otherRoomID in state.peerVoiceRoom {
		if otherPeerID == peerID {
			continue
		}
		participant, found := MainRouterState_voiceFindParticipant(state, otherPeerID)
		if !found || participant.userID != userID {
			continue
		}
		// An automatic re-join never takes voice from another device; it replaces only a
		// session of its own device that the server has not seen go yet.
		if request.voiceRejoin && participant.deviceID != request.voiceDeviceID {
			MainRouterState_sendVoiceJoinRejected(
				pm,
				state,
				peerID,
				roomID,
				VOICE_REJECT_ACTIVE_ON_OTHER_DEVICE,
			)
			return
		}
		append(&otherPeerIDs, otherPeerID)
		if otherRoomID == roomID {
			otherInTarget += 1
		}
	}

	currentRoomID, inVoice := state.peerVoiceRoom[peerID]
	if !inVoice || currentRoomID != roomID {
		// Checked before leaving the current room, so a refused switch keeps the session where
		// it was. A session this join replaces frees its place.
		if room, ok := state.voiceRooms[roomID];
		   ok && len(room.participants) - otherInTarget >= pm.config.voiceMaxParticipants {
			MainRouterState_sendVoiceJoinRejected(pm, state, peerID, roomID, VOICE_REJECT_FULL)
			return
		}
	}

	// Take voice over from the account's other session. Its room gets its own route and
	// participant update unless it is the room being joined, whose update below already shows
	// the replacement, so the user never shows twice or drops out of the list in between.
	for otherPeerID in otherPeerIDs {
		otherRoomID, _ := MainRouterState_voiceRemoveParticipant(state, otherPeerID)
		MainRouterState_sendVoiceLeft(
			pm,
			state,
			otherPeerID,
			otherRoomID,
			VOICE_LEFT_JOINED_ON_OTHER_DEVICE,
		)
		if otherRoomID != roomID {
			MainRouterState_voiceRoomChanged(pm, state, otherRoomID)
		}
	}

	if inVoice && currentRoomID != roomID {
		MainRouterState_voiceRemoveParticipant(state, peerID)
		MainRouterState_sendVoiceLeft(
			pm,
			state,
			peerID,
			currentRoomID,
			VOICE_LEFT_JOINED_OTHER_ROOM,
		)
		MainRouterState_voiceRoomChanged(pm, state, currentRoomID)
	}

	if roomID not_in state.voiceRooms {
		state.voiceRooms[roomID] = VoiceRoomState {
			roomID = roomID,
		}
	}
	room := &state.voiceRooms[roomID]
	// A repeated join of the same room only updates the mute and deafen flags.
	found := false
	for &participant in room.participants {
		if participant.peerID == peerID {
			participant.muted = request.voiceMuted
			participant.deafened = request.voiceDeafened
			participant.deviceID = request.voiceDeviceID
			found = true
		}
	}
	if !found {
		append(
			&room.participants,
			VoiceParticipantState {
				peerID = peerID,
				userID = session.authenticatedUserID,
				muted = request.voiceMuted,
				deafened = request.voiceDeafened,
				deviceID = request.voiceDeviceID,
			},
		)
		state.peerVoiceRoom[peerID] = roomID
	}
	clear(&room.memberUserIDs)
	append(&room.memberUserIDs, ..members.userIDs[:])
	MainRouterState_voiceRoomChanged(pm, state, roomID)
}

MainRouterState_handleClientLeaveVoice :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	payload: []u8,
) {
	req: common.ClientLeaveVoicePayload
	if cbor.unmarshal(payload, &req) != nil {
		MainRouterState_sendProtocolError(pm, state, peerID, "Invalid ClientLeaveVoice payload")
		return
	}
	// Leaving when not in voice is a no-op: the client may race a server-side eviction.
	MainRouterState_voiceLeave(pm, state, peerID)
}

MainRouterState_handleClientVoiceState :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	payload: []u8,
) {
	req: common.ClientVoiceStatePayload
	if cbor.unmarshal(payload, &req) != nil {
		MainRouterState_sendProtocolError(pm, state, peerID, "Invalid ClientVoiceState payload")
		return
	}
	roomID, inVoice := state.peerVoiceRoom[peerID]
	if !inVoice {
		return // the client may race an eviction; it re-sends its flags with the next join
	}
	room, ok := &state.voiceRooms[roomID]
	if !ok {
		return
	}
	changed := false
	for &participant in room.participants {
		if participant.peerID == peerID &&
		   (participant.muted != req.muted || participant.deafened != req.deafened) {
			participant.muted = req.muted
			participant.deafened = req.deafened
			changed = true
		}
	}
	if changed {
		MainRouterState_voiceRoomChanged(pm, state, roomID)
	}
}

// A member was removed from roomID: each of their sessions in its voice session is told why and
// leaves, and they no longer hear about the room's participants.
MainRouterState_voiceEvictUser :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	roomID: int,
	userID: int,
	reason: string,
) {
	room, ok := &state.voiceRooms[roomID]
	if !ok {
		return
	}
	for index := 0; index < len(room.memberUserIDs); index += 1 {
		if room.memberUserIDs[index] == userID {
			unordered_remove(&room.memberUserIDs, index)
			index -= 1
		}
	}
	evicted := false
	for index := 0; index < len(room.participants); index += 1 {
		participant := room.participants[index]
		if participant.userID != userID {
			continue
		}
		ordered_remove(&room.participants, index)
		index -= 1
		delete_key(&state.peerVoiceRoom, participant.peerID)
		MainRouterState_sendVoiceLeft(pm, state, participant.peerID, roomID, reason)
		evicted = true
	}
	if evicted {
		MainRouterState_voiceRoomChanged(pm, state, roomID)
	}
}

// userID's name changed (an admin rename, protocol 14): the rooms it is in voice in send their
// participant lists again, which take nicknames from the sessions.
MainRouterState_voiceRefreshUserRooms :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	userID: int,
) {
	// Heap scratch: the router loop never frees the temporary allocator.
	roomIDs := make([dynamic]int, 0, 1)
	defer delete(roomIDs)
	for roomID, room in state.voiceRooms {
		for participant in room.participants {
			if participant.userID == userID {
				append(&roomIDs, roomID)
				break
			}
		}
	}
	for roomID in roomIDs {
		MainRouterState_voiceRoomChanged(pm, state, roomID)
	}
}

// roomID became text-only (protocol 14): every session in its voice session is told why and
// leaves, and the members get the empty participant list, which also drops the room's state
// and route. Unlike a deletion, the room is still there, so its members must see voice end.
MainRouterState_voiceDisableRoom :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	roomID: int,
	reason: string,
) {
	room, ok := &state.voiceRooms[roomID]
	if !ok {
		return
	}
	for participant in room.participants {
		delete_key(&state.peerVoiceRoom, participant.peerID)
		MainRouterState_sendVoiceLeft(pm, state, participant.peerID, roomID, reason)
	}
	clear(&room.participants)
	MainRouterState_voiceRoomChanged(pm, state, roomID)
}

// roomID was deleted: every session in its voice session is told why, and the room's voice
// state and route are dropped. Nobody gets a participant list, because the room is gone.
MainRouterState_voiceEvictRoom :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	roomID: int,
	reason: string,
) {
	room, ok := &state.voiceRooms[roomID]
	if !ok {
		return
	}
	for participant in room.participants {
		delete_key(&state.peerVoiceRoom, participant.peerID)
		MainRouterState_sendVoiceLeft(pm, state, participant.peerID, roomID, reason)
	}
	VoiceRoomState_deinit(room)
	delete_key(&state.voiceRooms, roomID)
	MainRouterState_voiceSendRoute(pm, state, roomID)
}

// After a room list, the client also gets the participants of each of its rooms that has voice,
// so its sidebar is right as soon as it connects. The list proves membership, so the user joins
// those rooms' recipient caches too.
MainRouterState_voiceSendActiveParticipants :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	rooms: []common.RoomSummary,
) {
	session, ok := MainRouterState_getPeerSession(state, peerID)
	if !ok || !session.isAuthenticated {
		return
	}
	for summary in rooms {
		room, roomOK := &state.voiceRooms[summary.id]
		if !roomOK {
			continue
		}
		MainRouterState_voiceAddMemberUserID(room, session.authenticatedUserID)
		payload := MainRouterState_voiceBuildParticipants(state, room^)
		payload.recipientJoined = MainRouterState_voicePeerIsInRoom(state, peerID, summary.id)
		MainRouterState_sendPeerMessage(pm, state, peerID, .ServerVoiceParticipants, payload)
		delete(payload.participants)
	}
}
