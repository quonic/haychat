package server

import "../common"
import "core:encoding/cbor"

// Room access modes (protocol 15): ClientAddRoomMember, ClientRemoveRoomMember,
// ClientLeaveRoom, ClientFetchRoomMembers and ClientAdminListRooms. Each request is checked for
// shape here and becomes one statement (database_room_access.odin) that checks the requester
// against the room's mode and makes the change, so the router never decides who may do what.
// It only fans the result out:
//
// - A refusal is a ServerProtocolError with a sentence for people; the session stays up.
// - Add and Remove answer the requester with ServerRoomMemberAdded / ServerRoomMemberRemoved.
// - A change sends ServerRoomMembershipChanged{roomId, joined, userId} to every session of the
//   account that joined or left, of the room's members after the change, and to the session
//   that asked, so open member lists refresh. A removal or leave first takes the account out
//   of the room's voice.
// - Fetch answers with ServerRoomMembers, the admin list with ServerAdminRooms.

ROOM_MEMBERSHIP_INVALID_MESSAGE :: "Invalid room membership request"
ROOM_NOT_MEMBER_MESSAGE :: "Not a room member"
ROOM_NOT_FOUND_MESSAGE :: "Room not found"
ROOM_UNKNOWN_USER_MESSAGE :: "Unknown user"
ROOM_PUBLIC_ADD_MESSAGE :: "Public rooms include every account"
ROOM_PUBLIC_LEAVE_MESSAGE :: "You cannot leave a public room"
ROOM_ADMIN_REQUIRED_MESSAGE :: "Admin permission required"
VOICE_LEFT_LEFT_ROOM :: "left the room"

@(private = "file")
MainRouterState_enqueueRoomMemberAction :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	action: common.RoomMemberAction,
	roomID: int,
	targetUserID: int,
) {
	targetUserID := targetUserID
	session, ok := MainRouterState_getPeerSession(state, peerID)
	if !ok || !session.isAuthenticated {
		MainRouterState_sendProtocolError(pm, state, peerID, "Unauthenticated room request")
		return
	}
	// Leave and Fetch act on the requester.
	if action == .Leave || action == .Fetch {
		targetUserID = session.authenticatedUserID
	}
	MainRouterState_enqueueChannelDatabaseRequest(
		pm,
		state,
		peerID,
		common.DatabaseRoomMemberActionRequest {
			action = action,
			actorUserId = session.authenticatedUserID,
			roomId = roomID,
			targetUserId = targetUserID,
			serverIdentityPublicKey = state.serverIdentityPublicKey,
		},
		PendingDBRequest {
			requestType = .RoomMemberAction,
			roomID = roomID,
			targetUserID = targetUserID,
			roomMemberAction = action,
		},
	)
}

// ClientAddRoomMember (action Add) and ClientRemoveRoomMember (Remove).
MainRouterState_handleClientRoomMembershipMutation :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	payload: []u8,
	action: common.RoomMemberAction,
) {
	req: common.ClientRoomMembershipPayload
	if cbor.unmarshal(payload, &req) != nil || req.roomId <= 0 || req.userId <= 0 {
		MainRouterState_sendProtocolError(pm, state, peerID, ROOM_MEMBERSHIP_INVALID_MESSAGE)
		return
	}
	MainRouterState_enqueueRoomMemberAction(pm, state, peerID, action, req.roomId, req.userId)
}

MainRouterState_handleClientLeaveRoom :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	payload: []u8,
) {
	req: common.ClientLeaveRoomPayload
	if cbor.unmarshal(payload, &req) != nil || req.roomId <= 0 {
		MainRouterState_sendProtocolError(pm, state, peerID, ROOM_MEMBERSHIP_INVALID_MESSAGE)
		return
	}
	MainRouterState_enqueueRoomMemberAction(pm, state, peerID, .Leave, req.roomId, 0)
}

MainRouterState_handleClientFetchRoomMembers :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	payload: []u8,
) {
	req: common.ClientFetchRoomMembersPayload
	if cbor.unmarshal(payload, &req) != nil || req.roomId <= 0 {
		MainRouterState_sendProtocolError(pm, state, peerID, ROOM_MEMBERSHIP_INVALID_MESSAGE)
		return
	}
	MainRouterState_enqueueRoomMemberAction(pm, state, peerID, .Fetch, req.roomId, 0)
}

MainRouterState_handleClientAdminListRooms :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	payload: []u8,
) {
	req: common.ClientAdminListRoomsPayload
	if cbor.unmarshal(payload, &req) != nil {
		MainRouterState_sendProtocolError(pm, state, peerID, "Invalid admin room list request")
		return
	}
	userID, ok := MainRouterState_authenticatedUserForAdminRequest(pm, state, peerID)
	if !ok {
		return
	}
	MainRouterState_enqueueChannelDatabaseRequest(
		pm,
		state,
		peerID,
		common.DatabaseAdminRoomListRequest{actorUserId = userID},
		PendingDBRequest{requestType = .AdminListRooms},
	)
}

// The sentence for a refused room member statement.
MainRouterState_roomMemberRefusalMessage :: proc(
	action: common.RoomMemberAction,
	outcome: common.DatabaseRoomMemberOutcome,
) -> string {
	switch outcome {
	case .AdminRequired:
		return ROOM_ADMIN_REQUIRED_MESSAGE
	case .NotMember:
		return ROOM_NOT_MEMBER_MESSAGE
	case .UnknownRoom:
		return ROOM_NOT_FOUND_MESSAGE
	case .UnknownUser:
		return ROOM_UNKNOWN_USER_MESSAGE
	case .PublicRoom:
		return action == .Leave ? ROOM_PUBLIC_LEAVE_MESSAGE : ROOM_PUBLIC_ADD_MESSAGE
	case .EncryptedRoom:
		return common.ROOM_LOG_REQUIRED_MESSAGE
	case .LogDamaged:
		return common.ROOM_LOG_DAMAGED_MESSAGE
	case .Applied:
	}
	return ""
}

// Sends ServerRoomMembershipChanged{roomID, joined, userID} to every session of userID, of the
// accounts in memberUserIDs, and to requesterPeerID.
MainRouterState_sendRoomMembershipChange :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	roomID, userID: int,
	joined: bool,
	memberUserIDs: []int,
	requesterPeerID: u32,
) {
	payload := common.ServerRoomMembershipChangedPayload {
		roomId = roomID,
		joined = joined,
		userId = userID,
	}
	for recipientPeerID, recipientSession in state.peerSessions {
		if !recipientSession.isAuthenticated {
			continue
		}
		recipientUserID := recipientSession.authenticatedUserID
		if recipientPeerID == requesterPeerID ||
		   recipientUserID == userID ||
		   MainRouterState_hasRecipientUserID(memberUserIDs, recipientUserID) {
			MainRouterState_sendPeerMessage(
				pm,
				state,
				recipientPeerID,
				.ServerRoomMembershipChanged,
				payload,
			)
		}
	}
}

// Accounts a room switched to Public just added: each of their sessions refreshes its room
// list, and the room's voice fan-out includes them.
MainRouterState_roomMembersAdded :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	roomID: int,
	userIDs: []int,
) {
	if len(userIDs) == 0 {
		return
	}
	for userID in userIDs {
		MainRouterState_voiceNoteRoomMember(state, roomID, userID)
	}
	for recipientPeerID, recipientSession in state.peerSessions {
		if recipientSession.isAuthenticated &&
		   MainRouterState_hasRecipientUserID(userIDs, recipientSession.authenticatedUserID) {
			MainRouterState_sendPeerMessage(
				pm,
				state,
				recipientPeerID,
				.ServerRoomMembershipChanged,
				common.ServerRoomMembershipChangedPayload {
					roomId = roomID,
					joined = true,
					userId = recipientSession.authenticatedUserID,
				},
			)
		}
	}
}

MainRouterState_handleRoomMemberActionResult :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	request: PendingDBRequest,
	response: common.DatabaseQueryResponse,
) {
	result, resultOK := response.result.(common.DatabaseRoomMemberActionResult)
	if MainRouterState_databaseFailed(pm, state, request.peerID, response, resultOK) {
		return
	}
	action := request.roomMemberAction
	if result.outcome != .Applied {
		MainRouterState_sendProtocolError(
			pm,
			state,
			request.peerID,
			MainRouterState_roomMemberRefusalMessage(action, result.outcome),
		)
		return
	}
	switch action {
	case .Fetch:
		MainRouterState_sendPeerMessage(
			pm,
			state,
			request.peerID,
			.ServerRoomMembers,
			common.ServerRoomMembersPayload {
				roomId = request.roomID,
				userIds = result.memberUserIDs,
			},
		)
		return
	case .Add:
		MainRouterState_sendPeerMessage(
			pm,
			state,
			request.peerID,
			.ServerRoomMemberAdded,
			common.ServerRoomMutationPayload {
				roomId = request.roomID,
				userId = request.targetUserID,
				changed = result.changed,
			},
		)
		if result.changed {
			MainRouterState_voiceNoteRoomMember(state, request.roomID, request.targetUserID)
		}
	case .Remove:
		MainRouterState_sendPeerMessage(
			pm,
			state,
			request.peerID,
			.ServerRoomMemberRemoved,
			common.ServerRoomMutationPayload {
				roomId = request.roomID,
				userId = request.targetUserID,
				changed = result.changed,
			},
		)
		if result.changed {
			MainRouterState_voiceEvictUser(
				pm,
				state,
				request.roomID,
				request.targetUserID,
				VOICE_LEFT_REMOVED_FROM_ROOM,
			)
		}
		// Protocol 18: the unsigned Remove entry the server wrote for an encrypted room.
		if len(result.logEntry) > 0 {
			MainRouterState_sendRoomLogEntry(
				pm,
				state,
				request.roomID,
				result.logVersion,
				result.logEntry,
				result.memberUserIDs[:],
				result.managerUserIDs[:],
				request.targetUserID,
				request.peerID,
			)
		}
	case .Leave:
		if result.changed {
			MainRouterState_voiceEvictUser(
				pm,
				state,
				request.roomID,
				request.targetUserID,
				VOICE_LEFT_LEFT_ROOM,
			)
		}
	}
	if result.changed {
		MainRouterState_sendRoomMembershipChange(
			pm,
			state,
			request.roomID,
			request.targetUserID,
			action == .Add,
			result.memberUserIDs[:],
			request.peerID,
		)
	}
}

MainRouterState_handleAdminRoomListResult :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	request: PendingDBRequest,
	response: common.DatabaseQueryResponse,
) {
	result, resultOK := response.result.(common.DatabaseAdminRoomListResult)
	if MainRouterState_databaseFailed(pm, state, request.peerID, response, resultOK) {
		return
	}
	if !result.allowed {
		MainRouterState_sendAdminRequired(pm, state, request.peerID)
		return
	}
	MainRouterState_sendPeerMessage(
		pm,
		state,
		request.peerID,
		.ServerAdminRooms,
		common.ServerAdminRoomsPayload{rooms = result.rooms},
	)
}
