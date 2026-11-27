package client

import "../common"
import "core:strings"

// Admin actions on accounts (protocol 14): grant or revoke the admin role, rename an account
// and lock its name, kick, ban and unban. Like room management, the client only decides which
// controls to offer (State_isServerAdmin); the server checks the role and every guard in the
// database (no kick or ban of yourself or of another admin, no revoke of the last admin) and
// answers with ServerAdminActionResult (.AdminActionResult) or a ServerProtocolError.
//
// State.adminRequest remembers the last request per State, so a screen (P4) can show its
// answer: a protocol error on that server while it is pending is taken as its refusal, the way
// the room editor does, and a connection change ends the wait.

// One admin request. Strings are borrowed. It stays comparable (tests compare requests), so
// SetUserRoles' IDs are a fixed array with a count.
AdminRequest :: struct {
	action:      common.AdminAction,
	userID:      int,
	// SetRole: grant or revoke. Rename: the lock. Ban: ban or unban.
	flag:        bool,
	// Rename: the new name, or empty to change only the lock.
	nickname:    string,
	// Kick and ban: the reason, at most common.ADMIN_REASON_MAX_BYTES.
	reason:      string,
	// Protocol 23 (roles.odin). SaveRole: roleID (0 creates), roleName, permissions and
	// position. DeleteRole: roleID. SetUserRoles: userID and roleIDs[:roleIDCount].
	roleID:      int,
	roleName:    string,
	permissions: common.ServerPermissions,
	position:    int,
	roleIDs:     [common.SERVER_ROLES_MAX]int,
	roleIDCount: int,
	// Protocol 25 (registration.odin). RevokeInvite: inviteID. SetRegistrationMode: mode.
	// DecideRegistration: requestID, flag (approve) and reason (0..500 characters).
	// SetRestricted: userID and flag (restricted).
	inviteID:    int,
	requestID:   int,
	mode:        common.RegistrationMode,
	// Protocol 28 (attachment_moderation.odin). RemoveAttachment: blobID and reason (0..500
	// bytes, no control characters).
	blobID:      common.AttachmentBlobID,
	// Protocol 35 (room_log_repair.odin). TruncateRoomLog: roomID and toVersion.
	roomID:      int,
	toVersion:   int,
}

AdminSendBridge :: #type proc(transport: ^ClientServerTransport, request: AdminRequest) -> bool

// Tests swap this to observe requests without a live session, under adminSendBridgeTestMutex.
adminSendBridge: AdminSendBridge = ClientServerTransport_sendAdminRequest

ClientServerTransport_sendAdminRequest :: proc(
	transport: ^ClientServerTransport,
	request: AdminRequest,
) -> bool {
	switch request.action {
	case .SetRole:
		return ClientServerTransport_adminSetRole(transport, request.userID, request.flag)
	case .Rename:
		return ClientServerTransport_adminRenameUser(
			transport,
			request.userID,
			request.nickname,
			request.flag,
		)
	case .Kick:
		return ClientServerTransport_adminKickUser(transport, request.userID, request.reason)
	case .Ban:
		return ClientServerTransport_adminBanUser(
			transport,
			request.userID,
			request.flag,
			request.reason,
		)
	case .SaveRole:
		return ClientServerTransport_adminSaveRole(
			transport,
			request.roleID,
			request.roleName,
			request.permissions,
			request.position,
		)
	case .DeleteRole:
		return ClientServerTransport_adminDeleteRole(transport, request.roleID)
	case .SetUserRoles:
		roleIDs := request.roleIDs
		return ClientServerTransport_adminSetUserRoles(
			transport,
			request.userID,
			roleIDs[:request.roleIDCount],
		)
	case .RevokeInvite:
		return ClientServerTransport_revokeInvite(transport, request.inviteID)
	case .SetRegistrationMode:
		return ClientServerTransport_setRegistrationMode(transport, request.mode)
	case .DecideRegistration:
		return ClientServerTransport_decideRegistration(
			transport,
			request.requestID,
			request.flag,
			request.reason,
		)
	case .SetRestricted:
		return ClientServerTransport_setRestricted(transport, request.userID, request.flag)
	case .RemoveAttachment:
		return ClientServerTransport_removeAttachment(transport, request.blobID, request.reason)
	case .TruncateRoomLog:
		return ClientServerTransport_truncateRoomLog(transport, request.roomID, request.toVersion)
	}
	return false
}

// The last admin request this client sent and what became of it. Strings are owned.
AdminRequestState :: struct {
	serverID: int,
	action:   common.AdminAction,
	userID:   int,
	// The role a SaveRole or DeleteRole names (protocol 23); a created role's ID once answered.
	roleID:   int,
	// Protocol 25: the code a RevokeInvite and the request a DecideRegistration names.
	inviteID:  int,
	requestID: int,
	// Protocol 28: the attachment a RemoveAttachment names.
	blobID:    common.AttachmentBlobID,
	// Protocol 35: the room a TruncateRoomLog names.
	roomID:    int,
	pending:  bool,
	// The server's sentence for a success (ServerAdminActionResult.message).
	result:   string,
	// The refusal (a ServerProtocolError while pending) or a dropped connection.
	error:    string,
	// Protocol 32 (#72): the encrypted rooms a ban could not remove the account from (owned,
	// ServerAdminActionResult.failedRoomIds); empty for every other answer.
	failedRoomIDs: [dynamic]int,
}

AdminRequestState_deinit :: proc(request: ^AdminRequestState) {
	delete(request.result)
	delete(request.error)
	delete(request.failedRoomIDs)
	request^ = {}
}

@(private = "file")
AdminRequestState_setFailedRooms :: proc(request: ^AdminRequestState, roomIDs: []int) {
	clear(&request.failedRoomIDs)
	if len(roomIDs) > 0 {
		append(&request.failedRoomIDs, ..roomIDs)
	}
}

@(private = "file")
AdminRequestState_setText :: proc(field: ^string, text: string) {
	delete(field^)
	field^ = strings.clone(text)
}

// Checks a request the way the server will, so mistakes get a readable sentence instead of
// "Invalid admin request". Returns "" when it may go out.
validateAdminRequest :: proc(request: AdminRequest) -> string {
	#partial switch request.action {
	case .SaveRole:
		if !common.roleNameIsValid(request.roleName) {
			return "Role names are 3 to 32 characters, without spaces at either end."
		}
		if request.roleID < 0 || request.position < 0 {
			return "That role cannot be saved."
		}
		return ""
	case .DeleteRole:
		if request.roleID <= 0 {
			return "No role selected."
		}
		return ""
	case .RevokeInvite:
		if request.inviteID <= 0 {
			return "No invite code selected."
		}
		return ""
	case .SetRegistrationMode:
		if !common.registrationModeIsSupported(request.mode) {
			return "Choose Open, Invite only or Invite + approval."
		}
		return ""
	case .DecideRegistration:
		if request.requestID <= 0 {
			return "No sign-up request selected."
		}
		if !common.registrationTextIsValid(
			request.reason,
			0,
			common.REGISTRATION_REASON_MAX_CHARS,
		) {
			return "The reason must be at most 500 characters, without control characters."
		}
		return ""
	case .RemoveAttachment:
		if !common.attachmentBlobIDIsSet(request.blobID) {
			return "No attachment selected."
		}
		if !common.attachmentRemoveReasonIsValid(request.reason) {
			return "The reason must be at most 500 bytes long, without control characters."
		}
		return ""
	case .TruncateRoomLog:
		if request.roomID <= 0 {
			return "No room selected."
		}
		if request.toVersion < 1 {
			return "No version of this room's member list replays; delete the room instead."
		}
		return ""
	case .SetUserRoles:
		if request.userID <= 0 {
			return "No account selected."
		}
		if request.roleIDCount < 0 || request.roleIDCount > common.SERVER_ROLES_MAX {
			return "That is more roles than the server keeps."
		}
		return ""
	}
	if request.userID <= 0 {
		return "No account selected."
	}
	#partial switch request.action {
	case .Rename:
		nickname := request.nickname
		if len(nickname) > 0 &&
		   (len(nickname) < common.NICKNAME_MIN_BYTES ||
				   len(nickname) > common.NICKNAME_MAX_BYTES) {
			return "Names must be 3 to 32 bytes long (accented letters and emoji count as 2 to 4)."
		}
		if strings.contains_any(nickname, "\r\n\t") {
			return "The name cannot contain line breaks or tabs."
		}
	case .Kick, .Ban:
		if len(request.reason) > common.ADMIN_REASON_MAX_BYTES {
			return "The reason must be at most 256 bytes long."
		}
	}
	return ""
}

// Validates and sends one request. Returns "" when the transport accepted it, otherwise the
// reason (static or in the temp allocator).
State_sendAdminRequest :: proc(state: ^State, serverID: int, request: AdminRequest) -> string {
	request := request
	request.nickname = strings.trim_space(request.nickname)
	request.reason = strings.trim_space(request.reason)
	request.roleName = strings.trim_space(request.roleName)
	if errorMessage := validateAdminRequest(request); len(errorMessage) > 0 {
		return errorMessage
	}
	transportIndex := State_selectedTransportIndexForServerID(state^, serverID)
	if transportIndex < 0 {
		return "No server transport selected"
	}
	if !State_isServerConnected(state, serverID) {
		return NOT_CONNECTED_MESSAGE
	}
	transport := &state.serverTransports[transportIndex]
	// The worker may replace lastError at any time, so copy it while holding the lock.
	ClientNetworkWorker_lock(state.networkWorker)
	sent := adminSendBridge(transport, request)
	sendError := sent ? "" : strings.clone(transport.lastError, context.temp_allocator)
	ClientNetworkWorker_unlock(state.networkWorker)
	if !sent {
		return len(sendError) > 0 ? sendError : "Failed to send the admin request"
	}

	tracked := &state.adminRequest
	tracked.serverID = serverID
	tracked.action = request.action
	tracked.userID = request.userID
	tracked.roleID = request.roleID
	tracked.inviteID = request.inviteID
	tracked.requestID = request.requestID
	tracked.blobID = request.blobID
	tracked.roomID = request.roomID
	tracked.pending = true
	AdminRequestState_setText(&tracked.result, "")
	AdminRequestState_setText(&tracked.error, "")
	AdminRequestState_setFailedRooms(tracked, nil)
	return ""
}

// Grants (isAdmin true) or revokes the admin role. The target's sessions get
// ServerAccountUpdated and everyone ServerUserUpdated.
State_sendAdminSetRole :: proc(state: ^State, serverID, userID: int, isAdmin: bool) -> string {
	return State_sendAdminRequest(
		state,
		serverID,
		AdminRequest{action = .SetRole, userID = userID, flag = isAdmin},
	)
}

// Renames an account and sets its name lock (D3). An empty nickname changes only the lock.
State_sendAdminRenameUser :: proc(
	state: ^State,
	serverID, userID: int,
	nickname: string,
	locked: bool,
) -> string {
	return State_sendAdminRequest(
		state,
		serverID,
		AdminRequest{action = .Rename, userID = userID, nickname = nickname, flag = locked},
	)
}

// Ends every session of the account (D5). It can sign in again; its client waits for the user.
State_sendAdminKickUser :: proc(state: ^State, serverID, userID: int, reason: string) -> string {
	return State_sendAdminRequest(
		state,
		serverID,
		AdminRequest{action = .Kick, userID = userID, reason = reason},
	)
}

// Bans (banned true) or unbans the account (D4). A ban ends its sessions and refuses its
// sign-in; an unban drops the reason.
State_sendAdminBanUser :: proc(
	state: ^State,
	serverID, userID: int,
	banned: bool,
	reason: string,
) -> string {
	return State_sendAdminRequest(
		state,
		serverID,
		AdminRequest{action = .Ban, userID = userID, flag = banned, reason = banned ? reason : ""},
	)
}

// Roles (protocol 23, roles.odin). Admins only, which the server checks with every guard: the
// built-in admin role keeps its name and every permission, and only the delegable permissions
// go to other roles. Every account hears ServerRoleUpdated or ServerRoleDeleted; holders whose
// permissions changed hear ServerAccountUpdated.
State_sendAdminSaveRole :: proc(
	state: ^State,
	serverID, roleID: int,
	name: string,
	permissions: common.ServerPermissions,
	position: int,
) -> string {
	return State_sendAdminRequest(
		state,
		serverID,
		AdminRequest {
			action = .SaveRole,
			roleID = roleID,
			roleName = name,
			permissions = permissions,
			position = position,
		},
	)
}

State_sendAdminDeleteRole :: proc(state: ^State, serverID, roleID: int) -> string {
	return State_sendAdminRequest(
		state,
		serverID,
		AdminRequest{action = .DeleteRole, roleID = roleID},
	)
}

// Makes roleIDs every role of userID other than admin. Everyone hears ServerUserUpdated.
State_sendAdminSetUserRoles :: proc(
	state: ^State,
	serverID, userID: int,
	roleIDs: []int,
) -> string {
	if len(roleIDs) > common.SERVER_ROLES_MAX {
		return "That is more roles than the server keeps."
	}
	request := AdminRequest {
		action      = .SetUserRoles,
		userID      = userID,
		roleIDCount = len(roleIDs),
	}
	copy(request.roleIDs[:], roleIDs)
	return State_sendAdminRequest(state, serverID, request)
}

// ServerAdminActionResult: the pending request succeeded. message is borrowed. roleID is the
// role a role action named (protocol 23), 0 otherwise. failedRoomIDs (borrowed, protocol 32)
// are the encrypted rooms a ban could not remove the account from.
State_adminActionResult :: proc(
	state: ^State,
	serverID: int,
	action: common.AdminAction,
	userID: int,
	message: string,
	roleID := 0,
	inviteID := 0,
	requestID := 0,
	blobID := common.AttachmentBlobID{},
	failedRoomIDs: []int = nil,
	roomID := 0,
) {
	tracked := &state.adminRequest
	if tracked.serverID != serverID {
		return
	}
	tracked.pending = false
	tracked.action = action
	tracked.userID = userID
	tracked.roleID = roleID
	tracked.inviteID = inviteID
	tracked.requestID = requestID
	tracked.blobID = blobID
	tracked.roomID = roomID
	AdminRequestState_setText(&tracked.result, message)
	AdminRequestState_setText(&tracked.error, "")
	AdminRequestState_setFailedRooms(tracked, failedRoomIDs)
}

// A protocol error on the request's server answers it while it is pending.
State_adminProtocolError :: proc(state: ^State, serverID: int, message: string) {
	tracked := &state.adminRequest
	if !tracked.pending || tracked.serverID != serverID {
		return
	}
	tracked.pending = false
	AdminRequestState_setText(
		&tracked.error,
		len(message) > 0 ? message : "The server refused the request.",
	)
}

// The request died with the session.
State_adminConnectionReset :: proc(state: ^State, serverID: int) {
	tracked := &state.adminRequest
	if !tracked.pending || tracked.serverID != serverID {
		return
	}
	tracked.pending = false
	AdminRequestState_setText(
		&tracked.error,
		"The connection dropped before the server answered. Try again.",
	)
}

// A request that never went out (a local check or the transport refused it): recorded like a
// refusal, so the Admin section shows why.
State_adminRequestFailed :: proc(
	state: ^State,
	serverID: int,
	action: common.AdminAction,
	userID: int,
	message: string,
) {
	tracked := &state.adminRequest
	tracked.serverID = serverID
	tracked.action = action
	tracked.userID = userID
	tracked.pending = false
	AdminRequestState_setText(&tracked.result, "")
	AdminRequestState_setText(&tracked.error, message)
	AdminRequestState_setFailedRooms(tracked, nil)
}

// Forgets the last answer (not a pending request), so a screen opened later does not show an
// old one.
State_clearAdminRequestStatus :: proc(state: ^State) {
	tracked := &state.adminRequest
	if tracked.pending {
		return
	}
	AdminRequestState_setText(&tracked.result, "")
	AdminRequestState_setText(&tracked.error, "")
	AdminRequestState_setFailedRooms(tracked, nil)
}
