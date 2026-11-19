package server

import "../common"
import "core:encoding/cbor"
import "core:fmt"
import "core:strings"

// Roles and server permissions (protocol 23, #95). Requests are checked for shape here and
// become one DatabaseRoleRequest, whose statement (database_roles.odin) checks the requester's
// admin role and the guards in the same statement as the change. The router fans out:
//
// - ServerRoleList to the requester of ClientAdminListRoles (any authenticated account).
// - ServerAdminActionResult (SaveRole, DeleteRole, SetUserRoles) to the session that asked; a
//   refusal is a ServerProtocolError sentence (MainRouterState_adminRefusalMessage).
// - ServerRoleUpdated / ServerRoleDeleted to every authenticated session when a role changed.
// - ServerUserUpdated (the account's UserSummary with its new roleIds) to every authenticated
//   session after SetUserRoles changed something.
// - ServerAccountUpdated to every session of each account whose effective permissions changed.

ROLE_INVALID_REQUEST_MESSAGE :: "Invalid role request"

// Whether a ClientAdminSaveRole is well formed: a valid name, a known role ID or 0, a position
// of 0 or more, and permissions inside SERVER_PERMISSIONS_ALL. Whether it may hold more than
// SERVER_PERMISSIONS_ASSIGNABLE (only the built-in role) is the statement's call, since only the
// database knows which role is built in; the router refuses it outright for a create and for
// anything but the whole set.
roleSaveRequestIsValid :: proc(request: common.ClientAdminSaveRolePayload) -> bool {
	if request.roleId < 0 || request.position < 0 || request.position > 1_000_000 {
		return false
	}
	if !common.roleNameIsValid(request.name) {
		return false
	}
	if request.permissions - common.SERVER_PERMISSIONS_ALL != {} {
		return false
	}
	// Admin-only permissions are only ever sent back whole, for the built-in role; the statement
	// refuses them for any other role (admin_only).
	extra := request.permissions - common.SERVER_PERMISSIONS_ASSIGNABLE
	if extra != {} &&
	   (request.roleId == 0 || request.permissions != common.SERVER_PERMISSIONS_ALL) {
		return false
	}
	return true
}

// Whether a ClientAdminSetUserRoles names a user and at most SERVER_ROLES_MAX distinct positive
// role IDs.
roleSetUserRolesRequestIsValid :: proc(request: common.ClientAdminSetUserRolesPayload) -> bool {
	if request.userId <= 0 || len(request.roleIds) > common.SERVER_ROLES_MAX {
		return false
	}
	for roleID, index in request.roleIds {
		if roleID <= 0 {
			return false
		}
		for other in request.roleIds[:index] {
			if other == roleID {
				return false
			}
		}
	}
	return true
}

@(private = "file")
MainRouterState_enqueueRoleRequest :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	request: common.DatabaseRoleRequest,
	adminAction: common.AdminAction,
) {
	MainRouterState_enqueueChannelDatabaseRequest(
		pm,
		state,
		peerID,
		request,
		PendingDBRequest {
			requestType = .RoleAction,
			targetUserID = request.targetUserId,
			adminAction = adminAction,
			roleAction = request.action,
			roleID = request.roleId,
			name = strings.clone(request.name),
		},
	)
}

MainRouterState_handleClientAdminListRoles :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	payload: []u8,
) {
	req: common.ClientAdminListRolesPayload
	if cbor.unmarshal(payload, &req) != nil {
		MainRouterState_sendProtocolError(pm, state, peerID, ROLE_INVALID_REQUEST_MESSAGE)
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
		common.DatabaseRoleRequest{action = .List, actorUserId = actorUserID},
		PendingDBRequest{requestType = .ListRoles},
	)
}

MainRouterState_handleClientAdminSaveRole :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	payload: []u8,
) {
	req: common.ClientAdminSaveRolePayload
	defer common.ClientAdminSaveRolePayload_deinit(&req)
	if cbor.unmarshal(payload, &req) != nil || !roleSaveRequestIsValid(req) {
		MainRouterState_sendProtocolError(pm, state, peerID, ROLE_INVALID_REQUEST_MESSAGE)
		return
	}
	actorUserID, ok := MainRouterState_authenticatedUserForAdminRequest(pm, state, peerID)
	if !ok {
		return
	}
	MainRouterState_enqueueRoleRequest(
		pm,
		state,
		peerID,
		common.DatabaseRoleRequest {
			action = .Save,
			actorUserId = actorUserID,
			roleId = req.roleId,
			name = strings.clone(req.name),
			permissions = req.permissions,
			position = req.position,
		},
		.SaveRole,
	)
}

MainRouterState_handleClientAdminDeleteRole :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	payload: []u8,
) {
	req: common.ClientAdminDeleteRolePayload
	if cbor.unmarshal(payload, &req) != nil || req.roleId <= 0 {
		MainRouterState_sendProtocolError(pm, state, peerID, ROLE_INVALID_REQUEST_MESSAGE)
		return
	}
	actorUserID, ok := MainRouterState_authenticatedUserForAdminRequest(pm, state, peerID)
	if !ok {
		return
	}
	MainRouterState_enqueueRoleRequest(
		pm,
		state,
		peerID,
		common.DatabaseRoleRequest {
			action = .Delete,
			actorUserId = actorUserID,
			roleId = req.roleId,
		},
		.DeleteRole,
	)
}

MainRouterState_handleClientAdminSetUserRoles :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	payload: []u8,
) {
	req: common.ClientAdminSetUserRolesPayload
	defer common.ClientAdminSetUserRolesPayload_deinit(&req)
	if cbor.unmarshal(payload, &req) != nil || !roleSetUserRolesRequestIsValid(req) {
		MainRouterState_sendProtocolError(pm, state, peerID, ROLE_INVALID_REQUEST_MESSAGE)
		return
	}
	actorUserID, ok := MainRouterState_authenticatedUserForAdminRequest(pm, state, peerID)
	if !ok {
		return
	}
	roleIDs := make([dynamic]int, 0, len(req.roleIds))
	append(&roleIDs, ..req.roleIds[:])
	MainRouterState_enqueueRoleRequest(
		pm,
		state,
		peerID,
		common.DatabaseRoleRequest {
			action = .SetUserRoles,
			actorUserId = actorUserID,
			targetUserId = req.userId,
			roleIds = roleIDs,
		},
		.SetUserRoles,
	)
}

MainRouterState_handleRoleListResult :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	request: PendingDBRequest,
	response: common.DatabaseQueryResponse,
) {
	result, resultOK := response.result.(common.DatabaseRoleResult)
	if MainRouterState_databaseFailed(pm, state, request.peerID, response, resultOK) {
		return
	}
	MainRouterState_sendPeerMessage(
		pm,
		state,
		request.peerID,
		.ServerRoleList,
		common.ServerRoleListPayload{roles = result.roles},
	)
}

// Sends every authenticated session the same message.
@(private = "file")
MainRouterState_sendToEveryAuthenticatedSession :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	messageType: common.MessageType,
	payload: any,
) {
	for recipientPeerID, recipientSession in state.peerSessions {
		if recipientSession.isAuthenticated {
			MainRouterState_sendPeerMessage(pm, state, recipientPeerID, messageType, payload)
		}
	}
}

// Tells each account whose effective permissions changed its new set, on every session.
MainRouterState_sendPermissionsChanged :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	affected: []common.DatabaseAccountPermissions,
) {
	for account in affected {
		MainRouterState_sendMessageToUserID(
			pm,
			state,
			account.userId,
			.ServerAccountUpdated,
			common.ServerAccountUpdatedPayload {
				isAdmin = account.isAdmin,
				nickname = account.nickname,
				nicknameLocked = account.nicknameLocked,
				permissions = account.permissions,
				isRestricted = MainRouterState_userIsRestricted(state, account.userId),
			},
		)
		MainRouterState_setUserSessionPermissions(pm, state, account.userId, account.permissions)
	}
}

// The sentence ServerAdminActionResult carries for a role action. Heap allocated; the caller
// frees it.
@(private = "file")
MainRouterState_roleSuccessMessage :: proc(
	request: PendingDBRequest,
	result: common.DatabaseRoleResult,
) -> string {
	#partial switch request.adminAction {
	case .SaveRole:
		if !result.changed {
			return fmt.aprintf("The role %s is unchanged", result.role.name)
		}
		if request.roleID == 0 {
			return fmt.aprintf("Created the role %s", result.role.name)
		}
		return fmt.aprintf("Saved the role %s", result.role.name)
	case .DeleteRole:
		return strings.clone("Deleted the role")
	case .SetUserRoles:
		if !result.changed {
			return fmt.aprintf("The roles of %s are unchanged", result.user.nickname)
		}
		return fmt.aprintf("Updated the roles of %s", result.user.nickname)
	}
	return strings.clone("Done")
}

MainRouterState_handleRoleActionResult :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	request: PendingDBRequest,
	response: common.DatabaseQueryResponse,
) {
	result, resultOK := response.result.(common.DatabaseRoleResult)
	if MainRouterState_databaseFailed(pm, state, request.peerID, response, resultOK) {
		return
	}
	if result.outcome != .Applied {
		MainRouterState_sendProtocolError(
			pm,
			state,
			request.peerID,
			MainRouterState_adminRefusalMessage(request.adminAction, result.outcome),
		)
		return
	}

	message := MainRouterState_roleSuccessMessage(request, result)
	defer delete(message)
	answer := common.ServerAdminActionResultPayload {
		action  = request.adminAction,
		message = message,
	}
	#partial switch request.roleAction {
	case .Save:
		answer.roleId = result.role.id
	case .Delete:
		answer.roleId = request.roleID
	case .SetUserRoles:
		answer.userId = result.user.id
	}
	MainRouterState_sendPeerMessage(pm, state, request.peerID, .ServerAdminActionResult, answer)
	if !result.changed {
		return
	}

	#partial switch request.roleAction {
	case .Save:
		MainRouterState_sendToEveryAuthenticatedSession(
			pm,
			state,
			.ServerRoleUpdated,
			common.ServerRoleUpdatedPayload{role = result.role},
		)
	case .Delete:
		MainRouterState_sendToEveryAuthenticatedSession(
			pm,
			state,
			.ServerRoleDeleted,
			common.ServerRoleDeletedPayload{roleId = request.roleID},
		)
	case .SetUserRoles:
		MainRouterState_broadcastUserUpdated(pm, state, result.user)
	}
	MainRouterState_sendPermissionsChanged(pm, state, result.affected[:])

	// Protocol 24 (#96): the Role room memberships the statement changed, then fresh room lists
	// for every account whose room permissions may have moved: the target or the deleted role's
	// holders (their role grants), and the accounts whose server permissions changed (those imply
	// room ones).
	MainRouterState_sendRoleRoomMembershipChanges(
		pm,
		state,
		result.membershipChanges[:],
		request.peerID,
	)
	resend := make([dynamic]int, 0, len(result.roomPermissionUserIDs) + len(result.affected))
	defer delete(resend)
	append(&resend, ..result.roomPermissionUserIDs[:])
	for account in result.affected {
		if !MainRouterState_hasRecipientUserID(resend[:], account.userId) {
			append(&resend, account.userId)
		}
	}
	MainRouterState_resendRoomLists(pm, state, resend[:])
}
