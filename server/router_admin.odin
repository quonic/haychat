package server

import "../common"
import "core:encoding/cbor"
import "core:fmt"
import "core:strings"

// Admin actions on accounts (protocol 14): ClientAdminSetRole, ClientAdminRenameUser,
// ClientAdminKickUser and ClientAdminBanUser, and the banned sign-in. Each request is checked
// for shape here and then becomes one DatabaseAdminUserRequest, whose statement
// (database_admin.odin) checks the requester's admin role and the guards in the same statement
// as the change. The router only fans the result out:
//
// - ServerAdminActionResult to the session that asked; a refusal is a ServerProtocolError with
//   a sentence for people, and the session stays up.
// - ServerUserUpdated (the target's full UserSummary) to every authenticated session when a role,
//   ban, or name changed.
// - ServerAccountUpdated to every session of the target when its role, name, or name lock
//   changed (#41), so its client updates without reconnecting.
// - Kick and ban: ServerSessionEnded and then a disconnect for every session of the target,
//   which also leave voice and go offline (MainRouterState_endUserSessions).

// The ServerAuthFailure message for a banned account, followed by ": reason" when the ban has
// one. Clients match the prefix (client/connection.odin), so keep it stable.
SERVER_BANNED_MESSAGE :: "This account is banned from this server"

ADMIN_INVALID_REQUEST_MESSAGE :: "Invalid admin request"

// Refuses the sign-in of a banned account: ServerAuthFailure with the ban message, then a
// disconnect. The session never counted as authenticated, so there is no presence to settle.
MainRouterState_refuseBannedSignIn :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	reason: string,
) {
	message := len(reason) > 0 ? fmt.aprintf("%s: %s", SERVER_BANNED_MESSAGE, reason) : ""
	defer delete(message)
	MainRouterState_sendAuthFailure(
		pm,
		state,
		peerID,
		len(message) > 0 ? message : SERVER_BANNED_MESSAGE,
	)
	if session, sessionOK := &state.peerSessions[peerID]; sessionOK {
		session.transport.phase = .Failed
	}
	MainRouterState_disconnectPeer(pm, peerID)
}

// Queues the admin statement for an action that passed its shape checks. nickname and reason
// are borrowed and cloned.
@(private = "file")
MainRouterState_enqueueAdminUserAction :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	action: common.AdminAction,
	targetUserID: int,
	flag: bool,
	nickname: string = "",
	reason: string = "",
) {
	actorUserID, ok := MainRouterState_authenticatedUserForAdminRequest(pm, state, peerID)
	if !ok {
		return
	}
	request := common.DatabaseAdminUserRequest {
		action       = action,
		actorUserId  = actorUserID,
		targetUserId = targetUserID,
		nickname     = strings.clone(nickname),
		reason       = strings.clone(reason),
	}
	#partial switch action {
	case .SetRole:
		request.isAdmin = flag
	case .Rename:
		request.locked = flag
	case .Ban:
		request.banned = flag
	}
	MainRouterState_enqueueChannelDatabaseRequest(
		pm,
		state,
		peerID,
		request,
		PendingDBRequest {
			requestType = .AdminUserAction,
			targetUserID = targetUserID,
			adminAction = action,
			adminFlag = flag,
			name = strings.clone(nickname),
			description = strings.clone(reason),
		},
	)
}

MainRouterState_handleClientAdminSetRole :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	payload: []u8,
) {
	req: common.ClientAdminSetRolePayload
	if cbor.unmarshal(payload, &req) != nil || req.userId <= 0 {
		MainRouterState_sendProtocolError(pm, state, peerID, ADMIN_INVALID_REQUEST_MESSAGE)
		return
	}
	MainRouterState_enqueueAdminUserAction(pm, state, peerID, .SetRole, req.userId, req.isAdmin)
}

MainRouterState_handleClientAdminRenameUser :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	payload: []u8,
) {
	req: common.ClientAdminRenameUserPayload
	defer common.ClientAdminRenameUserPayload_deinit(&req)
	// The same length rule as ClientHello; empty keeps the name and changes only the lock.
	if cbor.unmarshal(payload, &req) != nil ||
	   req.userId <= 0 ||
	   (len(req.nickname) > 0 &&
			   (len(req.nickname) < common.NICKNAME_MIN_BYTES ||
					   len(req.nickname) > common.NICKNAME_MAX_BYTES)) {
		MainRouterState_sendProtocolError(pm, state, peerID, ADMIN_INVALID_REQUEST_MESSAGE)
		return
	}
	MainRouterState_enqueueAdminUserAction(
		pm,
		state,
		peerID,
		.Rename,
		req.userId,
		req.locked,
		nickname = req.nickname,
	)
}

MainRouterState_handleClientAdminKickUser :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	payload: []u8,
) {
	req: common.ClientAdminKickUserPayload
	defer common.ClientAdminKickUserPayload_deinit(&req)
	if cbor.unmarshal(payload, &req) != nil ||
	   req.userId <= 0 ||
	   len(req.reason) > common.ADMIN_REASON_MAX_BYTES {
		MainRouterState_sendProtocolError(pm, state, peerID, ADMIN_INVALID_REQUEST_MESSAGE)
		return
	}
	MainRouterState_enqueueAdminUserAction(
		pm,
		state,
		peerID,
		.Kick,
		req.userId,
		false,
		reason = req.reason,
	)
}

MainRouterState_handleClientAdminBanUser :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	payload: []u8,
) {
	req: common.ClientAdminBanUserPayload
	defer common.ClientAdminBanUserPayload_deinit(&req)
	if cbor.unmarshal(payload, &req) != nil ||
	   req.userId <= 0 ||
	   len(req.reason) > common.ADMIN_REASON_MAX_BYTES {
		MainRouterState_sendProtocolError(pm, state, peerID, ADMIN_INVALID_REQUEST_MESSAGE)
		return
	}
	// An unban keeps no reason.
	MainRouterState_enqueueAdminUserAction(
		pm,
		state,
		peerID,
		.Ban,
		req.userId,
		req.banned,
		reason = req.banned ? req.reason : "",
	)
}

// The sentence for a refused admin action.
MainRouterState_adminRefusalMessage :: proc(
	action: common.AdminAction,
	outcome: common.DatabaseAdminOutcome,
) -> string {
	switch outcome {
	case .Applied:
		return ""
	case .NotAdmin:
		return "Admin permission required"
	case .UnknownUser:
		return "Unknown user"
	case .SelfTarget:
		#partial switch action {
		case .Kick:
			return "You cannot kick yourself"
		case .Ban:
			return "You cannot ban yourself"
		}
		return "You cannot remove your own admin role"
	case .AdminTarget:
		if action == .SetRestricted {
			return "Admins cannot be restricted"
		}
		if action == .Kick {
			return "Remove the admin role before kicking an admin"
		}
		return "Remove the admin role before banning an admin"
	case .LastAdmin:
		return "The server must keep at least one admin"
	case .NicknameTaken:
		return "That name is already in use on this server"
	case .BannedTarget:
		return "Unban the account before making it an admin"
	case .UnknownRole:
		return "Unknown role"
	case .BuiltinRole:
		if action == .DeleteRole {
			return "The admin role cannot be deleted"
		}
		return "The admin role cannot be renamed or given fewer permissions"
	case .RoleNameTaken:
		return "Another role already has that name"
	case .AdminOnlyPermission:
		return "Only the admin role can hold that permission"
	case .TooManyRoles:
		return "The server already has as many roles as it keeps"
	}
	return "The server refused the admin request"
}

// The sentence ServerAdminActionResult carries for a success. Heap allocated; the caller frees
// it (the router loop never frees the temporary allocator).
@(private = "file")
MainRouterState_adminSuccessMessage :: proc(
	request: PendingDBRequest,
	result: common.DatabaseAdminUserResult,
) -> string {
	nickname := result.user.nickname
	switch request.adminAction {
	case .SetRole:
		if request.adminFlag {
			return fmt.aprintf("%s is an admin", nickname)
		}
		return fmt.aprintf("%s is no longer an admin", nickname)
	case .Rename:
		if result.previousNickname != nickname {
			return fmt.aprintf(
				"Renamed %s to %s%s",
				result.previousNickname,
				nickname,
				result.nicknameLocked ? "; the name is locked" : "",
			)
		}
		if result.nicknameLocked {
			return fmt.aprintf("The name %s is locked", nickname)
		}
		return fmt.aprintf("The name %s is no longer locked", nickname)
	case .Kick:
		return fmt.aprintf("Kicked %s", nickname)
	case .Ban:
		if request.adminFlag {
			return fmt.aprintf("Banned %s", nickname)
		}
		return fmt.aprintf("Unbanned %s", nickname)
	case .SetRestricted:
		if !result.changed {
			return fmt.aprintf(
				"%s is already %s",
				nickname,
				request.adminFlag ? "restricted" : "unrestricted",
			)
		}
		if request.adminFlag {
			return fmt.aprintf("%s is restricted", nickname)
		}
		return fmt.aprintf("%s is no longer restricted", nickname)
	case .SaveRole,
	     .DeleteRole,
	     .SetUserRoles,
	     .RevokeInvite,
	     .SetRegistrationMode,
	     .DecideRegistration:
	}
	return strings.clone("Done")
}

// Sends the target's directory entry to every authenticated session. isOnline comes from the
// sessions, like ServerUserList.
MainRouterState_broadcastUserUpdated :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	user: common.UserSummary,
) {
	updated := user
	updated.isOnline = MainRouterState_isUserOnline(state, user.id)
	// Protocol 25 (D17): only to sessions that may see the account (router_registration.odin).
	MainRouterState_sendAboutUser(
		pm,
		state,
		user.id,
		user.isRestricted,
		0,
		MainRouterVisibilityPayload{kind = .UserUpdated, user = updated},
	)
}

// Ends every authenticated session of userID: each gets ServerSessionEnded{kind, reason}, leaves
// voice, stops counting as authenticated, and is disconnected; then the user is announced
// offline once. Pending database answers for those sessions are dropped, so nothing else is sent
// to a session after its ServerSessionEnded.
MainRouterState_endUserSessions :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	userID: int,
	kind: common.SessionEndedKind,
	reason: string,
) -> int {
	// Collected first: the loop below changes the sessions it would be iterating over. Heap
	// scratch, freed here, because the router loop never frees the temporary allocator.
	peerIDs := make([dynamic]u32, 0, 2)
	defer delete(peerIDs)
	for peerID, session in state.peerSessions {
		if session.isAuthenticated && session.authenticatedUserID == userID {
			append(&peerIDs, peerID)
		}
	}
	if len(peerIDs) == 0 {
		return 0
	}

	nickname: string
	for peerID in peerIDs {
		if len(nickname) == 0 {
			session, _ := MainRouterState_getPeerSession(state, peerID)
			nickname = strings.clone(session.clientNickname)
		}
		MainRouterState_sendPeerMessage(
			pm,
			state,
			peerID,
			.ServerSessionEnded,
			common.ServerSessionEndedPayload{kind = kind, reason = reason},
		)
		// While the session still exists and is authenticated, so the other participants keep
		// its nickname and it is skipped.
		MainRouterState_voiceLeave(pm, state, peerID, skipSelf = true)
		MainRouterState_removePendingRequestsForPeer(state, peerID)
		if session, sessionOK := &state.peerSessions[peerID]; sessionOK {
			session.transport.phase = .Failed
			session.isAuthenticated = false
		}
		MainRouterState_disconnectPeer(pm, peerID)
	}
	defer delete(nickname)
	MainRouterState_noteSessionEnded(pm, state, peerIDs[0], userID, nickname)
	return len(peerIDs)
}

MainRouterState_handleAdminUserResult :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	request: PendingDBRequest,
	response: common.DatabaseQueryResponse,
) {
	result, resultOK := response.result.(common.DatabaseAdminUserResult)
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

	message := MainRouterState_adminSuccessMessage(request, result)
	defer delete(message)
	MainRouterState_sendPeerMessage(
		pm,
		state,
		request.peerID,
		.ServerAdminActionResult,
		common.ServerAdminActionResultPayload {
			action = request.adminAction,
			userId = result.user.id,
			message = message,
		},
	)

	userID := result.user.id
	switch request.adminAction {
	case .SetRole, .Rename:
		if !result.changed {
			return
		}
		renamed := request.adminAction == .Rename && result.previousNickname != result.user.nickname
		if renamed {
			// Like a rename at sign-in: the sessions take the new name, so presence, voice lists
			// and the offline notice carry it.
			MainRouterState_renameUserSessions(state, userID, result.user.nickname)
		}
		MainRouterState_broadcastUserUpdated(pm, state, result.user)
		MainRouterState_sendMessageToUserID(
			pm,
			state,
			userID,
			.ServerAccountUpdated,
			common.ServerAccountUpdatedPayload {
				isAdmin = result.user.isAdmin,
				nickname = result.user.nickname,
				nicknameLocked = result.nicknameLocked,
				permissions = result.permissions,
				isRestricted = result.user.isRestricted,
			},
		)
		MainRouterState_setUserSessionPermissions(pm, state, userID, result.permissions)
		if renamed && MainRouterState_isUserOnline(state, userID) {
			MainRouterState_broadcastPresence(pm, state, userID, result.user.nickname, true, 0)
			MainRouterState_voiceRefreshUserRooms(pm, state, userID)
		}
		// Protocol 24: an admin holds every room permission, so the account's room
		// permissions moved with the role.
		if request.adminAction == .SetRole {
			MainRouterState_resendRoomLists(pm, state, []int{userID})
		}
	case .Kick:
		MainRouterState_endUserSessions(pm, state, userID, .Kicked, request.description)
	case .Ban:
		if request.adminFlag {
			MainRouterState_endUserSessions(pm, state, userID, .Banned, request.description)
		}
		if result.changed {
			MainRouterState_broadcastUserUpdated(pm, state, result.user)
		}
	case .SetRestricted:
		if !result.changed {
			return
		}
		// Protocol 25 (D11, D17): the router's set first, so the fan-outs below filter by it.
		MainRouterState_setUserRestricted(state, userID, result.user.isRestricted)
		MainRouterState_sendMessageToUserID(
			pm,
			state,
			userID,
			.ServerAccountUpdated,
			common.ServerAccountUpdatedPayload {
				isAdmin = result.user.isAdmin,
				nickname = result.user.nickname,
				nicknameLocked = result.nicknameLocked,
				permissions = result.permissions,
				isRestricted = result.user.isRestricted,
			},
		)
		for roomID in result.addedRoomIDs {
			MainRouterState_roomMembersAdded(pm, state, roomID, []int{userID})
		}
		MainRouterState_broadcastUserUpdated(pm, state, result.user)
		// Who sees the account, and whom it sees, changed for everyone.
		MainRouterState_resendAllUserLists(pm, state)
	case .SaveRole,
	     .DeleteRole,
	     .SetUserRoles,
	     .RevokeInvite,
	     .SetRegistrationMode,
	     .DecideRegistration:
	// Role actions are DatabaseRoleRequests (router_roles.odin), registration ones
	// router_registration.odin's.
	}
}
