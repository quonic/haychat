package server

import "../common"
import "core:encoding/cbor"
import "core:fmt"

// Encrypted rooms' member logs (protocol 18, e2ee-design.md 6.2): ClientAppendRoomLog and
// ClientFetchRoomLog. The router checks a request's shape and hands it to the database worker
// (database_room_log.odin), which decides everything in one transaction; the router only fans
// the result out:
//
// - A refusal is a ServerProtocolError with a sentence; the session stays up.
// - An applied entry goes out as ServerRoomLog to every session of the room's members and
//   managers after it, of the account it added, removed or that left, and to the session that
//   sent it. A membership change also sends ServerRoomMembershipChanged like a protocol 15
//   change, and a removal or leave takes the account out of the room's voice.
// - A fetch is answered with ServerRoomLog to the requester only.
//
// An admin's ClientRemoveRoomMember on an encrypted room arrives through router_room_access.odin
// and ends here too (MainRouterState_sendRoomLogEntry), with the unsigned entry the server wrote.

MainRouterState_handleClientAppendRoomLog :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	payload: []u8,
) {
	req: common.ClientAppendRoomLogPayload
	err := cbor.unmarshal(payload, &req, temp_allocator = context.allocator)
	if err != nil ||
	   req.roomId <= 0 ||
	   len(req.entry) == 0 ||
	   len(req.entry) > common.ROOM_LOG_ENTRY_MAX_BYTES {
		common.ClientAppendRoomLogPayload_deinit(&req)
		MainRouterState_sendProtocolError(pm, state, peerID, common.ROOM_LOG_INVALID_MESSAGE)
		return
	}
	session, ok := MainRouterState_getPeerSession(state, peerID)
	if !ok || !session.isAuthenticated {
		common.ClientAppendRoomLogPayload_deinit(&req)
		MainRouterState_sendProtocolError(pm, state, peerID, "Unauthenticated room request")
		return
	}
	// The entry's ownership moves into the request.
	MainRouterState_enqueueChannelDatabaseRequest(
		pm,
		state,
		peerID,
		common.DatabaseAppendRoomLogRequest {
			actorUserId = session.authenticatedUserID,
			roomId = req.roomId,
			entry = req.entry,
			serverIdentityPublicKey = state.serverIdentityPublicKey,
		},
		PendingDBRequest{requestType = .AppendRoomLog, roomID = req.roomId},
	)
}

MainRouterState_handleClientFetchRoomLog :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	payload: []u8,
) {
	req: common.ClientFetchRoomLogPayload
	if cbor.unmarshal(payload, &req) != nil || req.roomId <= 0 || req.afterVersion < 0 {
		MainRouterState_sendProtocolError(pm, state, peerID, "Invalid room log request")
		return
	}
	session, ok := MainRouterState_getPeerSession(state, peerID)
	if !ok || !session.isAuthenticated {
		MainRouterState_sendProtocolError(pm, state, peerID, "Unauthenticated room request")
		return
	}
	MainRouterState_enqueueChannelDatabaseRequest(
		pm,
		state,
		peerID,
		common.DatabaseFetchRoomLogRequest {
			actorUserId = session.authenticatedUserID,
			roomId = req.roomId,
			afterVersion = req.afterVersion,
		},
		PendingDBRequest {
			requestType = .FetchRoomLog,
			roomID = req.roomId,
			targetUserID = req.afterVersion,
		},
	)
}

// The sentence for a refused append or fetch.
MainRouterState_roomLogRefusalMessage :: proc(outcome: common.RoomLogAppendOutcome) -> string {
	switch outcome {
	case .NotMember:
		return ROOM_NOT_MEMBER_MESSAGE
	case .NotEncrypted:
		return common.ROOM_LOG_NOT_ENCRYPTED_MESSAGE
	case .Invalid:
		return common.ROOM_LOG_INVALID_MESSAGE
	case .Conflict:
		return common.ROOM_LOG_CONFLICT_MESSAGE
	case .NotAuthorized:
		return common.ROOM_LOG_NOT_AUTHORIZED_MESSAGE
	case .RoomFull:
		return common.ENCRYPTED_ROOM_FULL_MESSAGE
	case .Damaged:
		return common.ROOM_LOG_DAMAGED_MESSAGE
	case .Applied:
	}
	return ""
}

// Sends one stored entry as ServerRoomLog to every session of memberUserIDs, managerUserIDs and
// targetUserID, and to requesterPeerID.
MainRouterState_sendRoomLogEntry :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	roomID, version: int,
	entry: []u8,
	memberUserIDs, managerUserIDs: []int,
	targetUserID: int,
	requesterPeerID: u32,
) {
	// The router never frees the temporary allocator, so this one-element array is on the heap.
	entries := make([dynamic][]u8, 0, 1)
	defer delete(entries)
	append(&entries, entry)
	payload := common.ServerRoomLogPayload {
		roomId       = roomID,
		afterVersion = version - 1,
		entries      = entries,
		headVersion  = version,
	}
	// Protocol 21: voice keys must name the new epoch from now on.
	MainRouterState_voiceLogAdvanced(state, roomID, version)
	for recipientPeerID, recipientSession in state.peerSessions {
		if !recipientSession.isAuthenticated {
			continue
		}
		recipientUserID := recipientSession.authenticatedUserID
		if recipientPeerID == requesterPeerID ||
		   recipientUserID == targetUserID ||
		   MainRouterState_hasRecipientUserID(memberUserIDs, recipientUserID) ||
		   MainRouterState_hasRecipientUserID(managerUserIDs, recipientUserID) {
			MainRouterState_sendPeerMessage(pm, state, recipientPeerID, .ServerRoomLog, payload)
		}
	}
}

MainRouterState_handleAppendRoomLogResult :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	request: PendingDBRequest,
	response: common.DatabaseQueryResponse,
) {
	result, resultOK := response.result.(common.DatabaseAppendRoomLogResult)
	if MainRouterState_databaseFailed(pm, state, request.peerID, response, resultOK) {
		return
	}
	if result.outcome != .Applied {
		message := MainRouterState_roomLogRefusalMessage(result.outcome)
		if result.outcome == .Invalid && result.logError != .None {
			// The rule that refused it helps whoever debugs a client; it reveals nothing the
			// sender does not know.
			detailed := fmt.aprintf("%s (%v)", message, result.logError)
			defer delete(detailed)
			MainRouterState_sendProtocolError(pm, state, request.peerID, detailed)
			return
		}
		MainRouterState_sendProtocolError(pm, state, request.peerID, message)
		return
	}
	roomID := request.roomID
	MainRouterState_sendRoomLogEntry(
		pm,
		state,
		roomID,
		result.version,
		result.entry,
		result.memberUserIDs[:],
		result.managerUserIDs[:],
		result.targetUserId,
		request.peerID,
	)
	if !result.membershipChanged {
		return
	}
	joined := result.action == .Create || result.action == .Add
	if joined {
		MainRouterState_voiceNoteRoomMember(state, roomID, result.targetUserId)
	} else {
		reason := result.action == .Leave ? VOICE_LEFT_LEFT_ROOM : VOICE_LEFT_REMOVED_FROM_ROOM
		MainRouterState_voiceEvictUser(pm, state, roomID, result.targetUserId, reason)
	}
	MainRouterState_sendRoomMembershipChange(
		pm,
		state,
		roomID,
		result.targetUserId,
		joined,
		result.memberUserIDs[:],
		request.peerID,
	)
}

MainRouterState_handleFetchRoomLogResult :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	request: PendingDBRequest,
	response: common.DatabaseQueryResponse,
) {
	result, resultOK := response.result.(common.DatabaseFetchRoomLogResult)
	if MainRouterState_databaseFailed(pm, state, request.peerID, response, resultOK) {
		return
	}
	if result.outcome != .Applied {
		MainRouterState_sendProtocolError(
			pm,
			state,
			request.peerID,
			MainRouterState_roomLogRefusalMessage(result.outcome),
		)
		return
	}
	MainRouterState_sendPeerMessage(
		pm,
		state,
		request.peerID,
		.ServerRoomLog,
		common.ServerRoomLogPayload {
			roomId = request.roomID,
			afterVersion = request.targetUserID,
			entries = result.entries,
			headVersion = result.headVersion,
			hasMore = result.hasMore,
		},
	)
}
