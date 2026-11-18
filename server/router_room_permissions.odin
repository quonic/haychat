package server

import "../common"
import "core:encoding/cbor"

// Room permissions and role rooms (protocol 24, #96). ClientAdminFetchRoomPermissions and
// ClientAdminSetRoomPermissions are checked for shape here and become one
// DatabaseRoomPermissionsRequest, whose statement (database_room_permissions.odin) checks
// ManageRooms or the room's EditRoom, and for a set every changed bit, in the same statement as
// the change. The router fans out:
//
// - ServerAdminRoomPermissions (the grants after it) to the session that asked; a refusal is a
//   ServerProtocolError sentence.
// - A fresh ServerListRooms to every session of the room's members after a set that changed
//   something, because their RoomSummary.myPermissions may have changed. Each ServerListRooms
//   the router sends also moves the account's voice sessions' speak flag
//   (MainRouterState_voiceUpdateSpeakPermissions), so the relay follows grant and role changes.
//
// Role changes (router_roles.odin) and admin grants (router_admin.odin) resend the room lists
// of the accounts whose room permissions they may have changed with
// MainRouterState_resendRoomLists, and fan the Role room memberships they changed out with
// MainRouterState_sendRoleRoomMembershipChanges.

MainRouterState_handleClientAdminSetRoomPermissions :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	payload: []u8,
) {
	req: common.ClientAdminSetRoomPermissionsPayload
	defer common.ClientAdminSetRoomPermissionsPayload_deinit(&req)
	if cbor.unmarshal(payload, &req) != nil || !common.roomPermissionsRequestIsValid(req) {
		MainRouterState_sendProtocolError(
			pm,
			state,
			peerID,
			common.ROOM_PERMISSIONS_INVALID_MESSAGE,
		)
		return
	}
	actorUserID, ok := MainRouterState_authenticatedUserForAdminRequest(pm, state, peerID)
	if !ok {
		return
	}
	roles := make([dynamic]common.RoomRoleGrant, 0, len(req.roles))
	append(&roles, ..req.roles[:])
	MainRouterState_enqueueChannelDatabaseRequest(
		pm,
		state,
		peerID,
		common.DatabaseRoomPermissionsRequest {
			action = .Set,
			actorUserId = actorUserID,
			roomId = req.roomId,
			everyone = req.everyone,
			roles = roles,
		},
		PendingDBRequest {
			requestType = .RoomPermissions,
			roomID = req.roomId,
			roomPermissionsAction = .Set,
		},
	)
}

MainRouterState_handleClientAdminFetchRoomPermissions :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	payload: []u8,
) {
	req: common.ClientAdminFetchRoomPermissionsPayload
	if cbor.unmarshal(payload, &req) != nil || req.roomId <= 0 {
		MainRouterState_sendProtocolError(
			pm,
			state,
			peerID,
			common.ROOM_PERMISSIONS_INVALID_MESSAGE,
		)
		return
	}
	actorUserID, ok := MainRouterState_authenticatedUserForAdminRequest(pm, state, peerID)
	if !ok {
		return
	}
	MainRouterState_enqueueChannelDatabaseRequest(
		pm,
		state,
		peerID,
		common.DatabaseRoomPermissionsRequest {
			action = .Fetch,
			actorUserId = actorUserID,
			roomId = req.roomId,
		},
		PendingDBRequest {
			requestType = .RoomPermissions,
			roomID = req.roomId,
			roomPermissionsAction = .Fetch,
		},
	)
}

// The sentence for a refused room permissions statement.
MainRouterState_roomPermissionsRefusalMessage :: proc(
	outcome: common.DatabaseRoomPermissionsOutcome,
) -> string {
	switch outcome {
	case .NotPermitted:
		return ROOM_MANAGEMENT_REQUIRED_MESSAGE
	case .UnknownRoom:
		return ROOM_NOT_FOUND_MESSAGE
	case .UnknownRole:
		return ROLE_INVALID_REQUEST_MESSAGE
	case .NotGrantable:
		return common.ROOM_PERMISSIONS_NOT_GRANTABLE_MESSAGE
	case .Applied:
	}
	return ""
}

MainRouterState_handleRoomPermissionsResult :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	request: PendingDBRequest,
	response: common.DatabaseQueryResponse,
) {
	result, resultOK := response.result.(common.DatabaseRoomPermissionsResult)
	if MainRouterState_databaseFailed(pm, state, request.peerID, response, resultOK) {
		return
	}
	if result.outcome != .Applied {
		MainRouterState_sendProtocolError(
			pm,
			state,
			request.peerID,
			MainRouterState_roomPermissionsRefusalMessage(result.outcome),
		)
		return
	}
	MainRouterState_sendPeerMessage(
		pm,
		state,
		request.peerID,
		.ServerAdminRoomPermissions,
		common.ServerAdminRoomPermissionsPayload {
			roomId = request.roomID,
			everyone = result.everyone,
			roles = result.roles,
			accessRoleIds = result.accessRoleIds,
			myPermissions = result.myPermissions,
		},
	)
	if request.roomPermissionsAction == .Set && result.changed {
		MainRouterState_resendRoomLists(pm, state, result.memberUserIDs[:])
	}
}

// Sends every authenticated session of userIDs a fresh ServerListRooms (each its own room list
// statement, answered like a ClientListRooms), because their room permissions may have changed.
MainRouterState_resendRoomLists :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	userIDs: []int,
) {
	if len(userIDs) == 0 {
		return
	}
	for recipientPeerID, recipientSession in state.peerSessions {
		if !recipientSession.isAuthenticated ||
		   !MainRouterState_hasRecipientUserID(userIDs, recipientSession.authenticatedUserID) {
			continue
		}
		MainRouterState_enqueueChannelDatabaseRequest(
			pm,
			state,
			recipientPeerID,
			common.DatabaseRoomListRequest{userId = recipientSession.authenticatedUserID},
			PendingDBRequest{requestType = .ListRooms},
		)
	}
}

// Fans out the Role room memberships a role change made (protocol 24): a leave first takes the
// account out of the room's voice, a join puts it in the voice member cache, and either sends
// ServerRoomMembershipChanged to the account, the room's members after it, and the requester,
// exactly like a protocol 15 add or removal.
MainRouterState_sendRoleRoomMembershipChanges :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	changes: []common.DatabaseRoomMembershipChange,
	requesterPeerID: u32,
) {
	for change in changes {
		if change.joined {
			MainRouterState_voiceNoteRoomMember(state, change.roomId, change.userId)
		} else {
			MainRouterState_voiceEvictUser(
				pm,
				state,
				change.roomId,
				change.userId,
				VOICE_LEFT_REMOVED_FROM_ROOM,
			)
		}
		MainRouterState_sendRoomMembershipChange(
			pm,
			state,
			change.roomId,
			change.userId,
			change.joined,
			change.memberUserIDs[:],
			requesterPeerID,
		)
	}
}
