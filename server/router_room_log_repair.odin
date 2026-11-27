package server

import "../common"
import "core:encoding/cbor"
import "core:fmt"

// Repairing a damaged member log (protocol 35, #196; database_room_log_repair.odin decides):
//
// - ClientAdminRoomLogStatus{roomId} -> the stored log replayed -> ServerAdminRoomLogStatus to
//   the requester.
// - ClientAdminTruncateRoomLog{roomId, toVersion} -> one transaction -> ServerAdminActionResult
//   {TruncateRoomLog, roomId} to the requester, a [RoomLog] line, and the fan-out of
//   MainRouterState_roomLogTruncated: the room's voice ends (its keys name later epochs, and
//   its members may have changed), ServerRoomLog{afterVersion = headVersion = toVersion, no
//   entries} goes to every session of the members and managers before and after it and to
//   the requester, and ServerRoomMembershipChanged to each member the rebuild added or removed
//   (with ServerAdminRoomChanged for room managers).
//
// Both are .RoomLogRepair requests, which outlive the requester's disconnect like
// .MessageChange: a truncation the database applied is always fanned out, and only the answer
// is checked against the session that asked.

ROOM_LOG_TRUNCATED_RESULT_MESSAGE :: "Truncated the member log"

// A peer ID no session has: ENet's peer IDs index the host's peer array.
ROUTER_NO_PEER_ID :: max(u32)

// Why a truncation ends the room's voice.
VOICE_LEFT_ROOM_LOG_REPAIRED :: "the room's member list was repaired"

MainRouterState_handleClientAdminRoomLogStatus :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	payload: []u8,
) {
	userID, ok := MainRouterState_authenticatedUserForAdminRequest(pm, state, peerID)
	if !ok {
		return
	}
	session, _ := MainRouterState_getPeerSession(state, peerID)
	req: common.ClientAdminRoomLogStatusPayload
	if cbor.unmarshal(payload, &req) != nil || req.roomId < 0 {
		MainRouterState_sendProtocolError(pm, state, peerID, ADMIN_INVALID_REQUEST_MESSAGE)
		return
	}
	MainRouterState_enqueueChannelDatabaseRequest(
		pm,
		state,
		peerID,
		common.DatabaseRoomLogRepairRequest {
			action = .Status,
			actorUserId = userID,
			roomId = req.roomId,
			serverIdentityPublicKey = state.serverIdentityPublicKey,
		},
		PendingDBRequest {
			requestType = .RoomLogRepair,
			sessionID = session.transport.sessionID,
			roomID = req.roomId,
			targetUserID = userID,
		},
	)
}

MainRouterState_handleClientAdminTruncateRoomLog :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	payload: []u8,
) {
	userID, ok := MainRouterState_authenticatedUserForAdminRequest(pm, state, peerID)
	if !ok {
		return
	}
	session, _ := MainRouterState_getPeerSession(state, peerID)
	req: common.ClientAdminTruncateRoomLogPayload
	if cbor.unmarshal(payload, &req) != nil || req.roomId <= 0 || req.toVersion < 0 {
		MainRouterState_sendProtocolError(pm, state, peerID, ADMIN_INVALID_REQUEST_MESSAGE)
		return
	}
	MainRouterState_enqueueChannelDatabaseRequest(
		pm,
		state,
		peerID,
		common.DatabaseRoomLogRepairRequest {
			action = .Truncate,
			actorUserId = userID,
			roomId = req.roomId,
			toVersion = req.toVersion,
			serverIdentityPublicKey = state.serverIdentityPublicKey,
		},
		PendingDBRequest {
			requestType = .RoomLogRepair,
			sessionID = session.transport.sessionID,
			roomID = req.roomId,
			targetUserID = userID,
			adminAction = .TruncateRoomLog,
		},
	)
}

// The sentence for a refused status or truncation.
MainRouterState_roomLogRepairRefusal :: proc(outcome: common.DatabaseRoomLogRepairOutcome) -> string {
	switch outcome {
	case .NotAdmin:
		return "Admin permission required"
	case .UnknownRoom:
		return ROOM_NOT_FOUND_MESSAGE
	case .NotEncrypted:
		return common.ROOM_LOG_NOT_ENCRYPTED_MESSAGE
	case .NotDamaged:
		return common.ROOM_LOG_REPAIR_NOT_DAMAGED_MESSAGE
	case .WrongVersion:
		return common.ROOM_LOG_REPAIR_WRONG_VERSION_MESSAGE
	case .NothingToKeep:
		return common.ROOM_LOG_REPAIR_NOTHING_TO_KEEP_MESSAGE
	case .Applied:
	}
	return ""
}

MainRouterState_handleRoomLogRepairResult :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	request: PendingDBRequest,
	response: common.DatabaseQueryResponse,
) {
	_, live := MainRouterState_askingSession(state, request.peerID, request.sessionID)
	result, resultOK := response.result.(common.DatabaseRoomLogRepairResult)
	if !response.success || !resultOK {
		if live {
			MainRouterState_databaseFailed(pm, state, request.peerID, response, resultOK)
		}
		return
	}
	if result.outcome != .Applied {
		if live {
			MainRouterState_sendProtocolError(
				pm,
				state,
				request.peerID,
				MainRouterState_roomLogRepairRefusal(result.outcome),
			)
		}
		return
	}
	if request.adminAction != .TruncateRoomLog {
		if live {
			MainRouterState_sendPeerMessage(
				pm,
				state,
				request.peerID,
				.ServerAdminRoomLogStatus,
				common.ServerAdminRoomLogStatusPayload {
					roomId = request.roomID,
					rooms = result.statuses,
					checkedRooms = result.checkedRooms,
					damagedRooms = result.damagedRooms,
				},
			)
		}
		return
	}

	roomID := request.roomID
	toVersion := result.status.goodVersion
	description := roomLogStatusDescription(result.status)
	defer delete(description)
	fmt.printfln(
		"[RoomLog] Admin %d truncated room %d's member log to version %d (%s): deleted %d " +
		"entries, %d room key envelopes, %d sealed messages and %d sealed edits; %d members " +
		"added and %d removed",
		request.targetUserID,
		roomID,
		toVersion,
		description,
		result.deletedEntries,
		result.deletedEnvelopes,
		result.deletedMessages,
		result.deletedEdits,
		len(result.addedUserIDs),
		len(result.removedUserIDs),
	)
	if live {
		MainRouterState_sendPeerMessage(
			pm,
			state,
			request.peerID,
			.ServerAdminActionResult,
			common.ServerAdminActionResultPayload {
				action = .TruncateRoomLog,
				roomId = roomID,
				message = ROOM_LOG_TRUNCATED_RESULT_MESSAGE,
			},
		)
	}
	requesterPeerID, hasRequester := request.peerID, live
	MainRouterState_roomLogTruncated(
		pm,
		state,
		roomID,
		toVersion,
		result,
		requesterPeerID,
		hasRequester,
	)
}

// Fans a truncation of roomID's log to toVersion out (see the top of the file).
MainRouterState_roomLogTruncated :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	roomID, toVersion: int,
	result: common.DatabaseRoomLogRepairResult,
	requesterPeerID: u32,
	hasRequester: bool,
) {
	// Voice keys name the old epoch and the participants may no longer be members: voice ends,
	// and a new join reads the log version again. The version goes back, which
	// MainRouterState_voiceLogAdvanced never does.
	MainRouterState_voiceDisableRoom(pm, state, roomID, VOICE_LEFT_ROOM_LOG_REPAIRED)
	state.roomLogVersions[roomID] = toVersion

	// The router never frees the temporary allocator, so the empty page is on the heap.
	entries := make([dynamic][]u8, 0, 1)
	defer delete(entries)
	payload := common.ServerRoomLogPayload {
		roomId       = roomID,
		afterVersion = toVersion,
		entries      = entries,
		headVersion  = toVersion,
	}
	for recipientPeerID, recipientSession in state.peerSessions {
		if !recipientSession.isAuthenticated {
			continue
		}
		recipientUserID := recipientSession.authenticatedUserID
		if (hasRequester && recipientPeerID == requesterPeerID) ||
		   MainRouterState_hasRecipientUserID(result.formerUserIDs[:], recipientUserID) ||
		   MainRouterState_hasRecipientUserID(result.memberUserIDs[:], recipientUserID) ||
		   MainRouterState_hasRecipientUserID(result.managerUserIDs[:], recipientUserID) {
			MainRouterState_sendPeerMessage(pm, state, recipientPeerID, .ServerRoomLog, payload)
		}
	}

	// ENet reuses peer IDs, so a requester that is gone must not name the peer's new session.
	membershipRequester := hasRequester ? requesterPeerID : ROUTER_NO_PEER_ID
	for userID in result.removedUserIDs {
		MainRouterState_sendRoomMembershipChange(
			pm,
			state,
			roomID,
			userID,
			false,
			result.memberUserIDs[:],
			membershipRequester,
		)
	}
	for userID in result.addedUserIDs {
		MainRouterState_sendRoomMembershipChange(
			pm,
			state,
			roomID,
			userID,
			true,
			result.memberUserIDs[:],
			membershipRequester,
		)
	}
	if len(result.removedUserIDs) == 0 && len(result.addedUserIDs) == 0 {
		MainRouterState_sendAdminRoomChanged(pm, state, roomID, .Members)
	}
}
