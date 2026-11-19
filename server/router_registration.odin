package server

import "../common"
import "core:crypto"
import "core:encoding/cbor"
import "core:fmt"
import "core:strings"
import "core:time"

// Registration in the router (protocol 25, #43 G1, plan D7-D17). The rules live in the
// statements of database_registration.odin; the router checks shapes, keeps the registering
// session state, and fans out.
//
// Handshake (D12): a ClientAuthRequest whose identity statement reports needsRegistration gets
// the plaintext ServerRegistrationRequired instead of ServerAuthSuccess. The server's transport
// is already active (handleClientAuthRequest activates it before the identity lookup), so the
// session becomes registering (RouterPeerSession.isRegistering): sendPeerMessage seals for it,
// and MainRouterState_handleRegisteringPacket accepts only encrypted ClientRegister and Ping.
// The invite code therefore never travels in plaintext.
//
// Limits (D13): common.REGISTER_ATTEMPTS_MAX answered ClientRegisters and
// common.REGISTER_SESSION_SECONDS per session (MainRouterState_expireRegisteringSessions, run
// by the main loop and on every registering packet), one ClientRegister in flight at a time,
// and at most common.REGISTERING_SESSIONS_MAX registering sessions at once (more are refused
// with ServerAuthFailure REGISTRATION_BUSY_MESSAGE, which clients retry later).
//
// Created completes the session through MainRouterState_completeAuthentication with a sender
// that answers ServerRegisterResponse{Created, auth} instead of ServerAuthSuccess, so the
// session is authenticated without a second handshake. Pending keeps it registering; an
// approval re-runs the identity statement for every registering session of that key (D14),
// which completes it the same way, and a decline answers Declined and disconnects.
//
// Restricted visibility (D17): presence, ServerUserUpdated and ServerUserKeyChanged about an
// account go through MainRouterState_sendAboutUser. A recipient sees the account at once when
// it is the account, holds ApproveRegistrations (admins hold every permission), or neither of
// the two is restricted; otherwise the database decides (DATABASE_SHARED_ROOMS_SQL: a shared
// room, or an admin on either side) before the message goes out. Which accounts are restricted
// is MainRouterState.restrictedUserIDs, loaded from the database when the router starts and
// kept current by every path that changes users.restricted (sign-in, sign-up, an admin's
// ClientAdminSetRestricted); a change made directly in the database needs a restart.

// What MainRouterState_sendAboutUser sends.
MainRouterVisibilityKind :: enum u8 {
	Presence,
	UserUpdated,
	KeyChanged,
}

// One message about an account. Borrowed when passed in; a pending database check holds an
// owned copy (MainRouterVisibilityPayload_clone).
MainRouterVisibilityPayload :: struct {
	kind:      MainRouterVisibilityKind,
	presence:  common.ServerUserPresencePayload,
	user:      common.UserSummary,
	keyBundle: common.UserKeyBundle,
}

MainRouterVisibilityPayload_clone :: proc(
	payload: MainRouterVisibilityPayload,
) -> MainRouterVisibilityPayload {
	copy := payload
	copy.presence.nickname = strings.clone(payload.presence.nickname)
	if payload.kind == .UserUpdated {
		copy.user = common.UserSummary_clone(payload.user)
	} else {
		copy.user = {}
	}
	return copy
}

MainRouterVisibilityPayload_deinit :: proc(payload: ^MainRouterVisibilityPayload) {
	delete(payload.presence.nickname)
	payload.presence.nickname = ""
	common.UserSummary_deinit(&payload.user)
}

@(private = "file")
MainRouterState_sendVisibilityPayload :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	payload: MainRouterVisibilityPayload,
) {
	switch payload.kind {
	case .Presence:
		MainRouterState_sendPeerMessage(pm, state, peerID, .ServerUserPresence, payload.presence)
	case .UserUpdated:
		MainRouterState_sendPeerMessage(
			pm,
			state,
			peerID,
			.ServerUserUpdated,
			common.ServerUserUpdatedPayload{user = payload.user},
		)
	case .KeyChanged:
		MainRouterState_sendPeerMessage(
			pm,
			state,
			peerID,
			.ServerUserKeyChanged,
			common.ServerUserKeyChangedPayload{bundle = payload.keyBundle},
		)
	}
}

MainRouterState_userIsRestricted :: proc(state: ^MainRouterState, userID: int) -> bool {
	return state.restrictedUserIDs[userID]
}

MainRouterState_setUserRestricted :: proc(state: ^MainRouterState, userID: int, restricted: bool) {
	if userID <= 0 {
		return
	}
	if restricted {
		state.restrictedUserIDs[userID] = true
	} else {
		delete_key(&state.restrictedUserIDs, userID)
	}
}

// Whether session sees subjectUserID without asking the database (D17). false means the
// database decides.
MainRouterState_seesUserAtOnce :: proc(
	state: ^MainRouterState,
	session: RouterPeerSession,
	subjectUserID: int,
	subjectRestricted: bool,
) -> bool {
	if session.authenticatedUserID == subjectUserID ||
	   .ApproveRegistrations in session.permissions {
		return true
	}
	viewerRestricted := MainRouterState_userIsRestricted(state, session.authenticatedUserID)
	return !subjectRestricted && !viewerRestricted
}

// Sends payload about subjectUserID to every authenticated session (but excludePeerID) that
// may see it (D17). Sessions the router cannot decide for are asked of the database in one
// DatabaseSharedRoomsRequest, and get the message when it answers.
MainRouterState_sendAboutUser :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	subjectUserID: int,
	subjectRestricted: bool,
	excludePeerID: u32,
	payload: MainRouterVisibilityPayload,
) {
	candidates := make([dynamic]int)
	for recipientPeerID, recipientSession in state.peerSessions {
		if !recipientSession.isAuthenticated || recipientPeerID == excludePeerID {
			continue
		}
		if MainRouterState_seesUserAtOnce(
			state,
			recipientSession,
			subjectUserID,
			subjectRestricted,
		) {
			MainRouterState_sendVisibilityPayload(pm, state, recipientPeerID, payload)
		} else if !MainRouterState_hasRecipientUserID(
			candidates[:],
			recipientSession.authenticatedUserID,
		) {
			append(&candidates, recipientSession.authenticatedUserID)
		}
	}
	if len(candidates) == 0 {
		delete(candidates)
		return
	}
	MainRouterState_enqueueChannelDatabaseRequest(
		pm,
		state,
		0,
		common.DatabaseSharedRoomsRequest{userId = subjectUserID, candidateUserIds = candidates},
		PendingDBRequest {
			requestType = .VisibleRecipients,
			targetUserID = subjectUserID,
			visibility = MainRouterVisibilityPayload_clone(payload),
			excludePeerID = excludePeerID,
		},
	)
}

MainRouterState_handleVisibleRecipientsResult :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	request: PendingDBRequest,
	response: common.DatabaseQueryResponse,
) {
	shared, sharedOK := response.result.(common.DatabaseSharedRoomsResult)
	if !response.success || !sharedOK {
		return
	}
	for recipientPeerID, recipientSession in state.peerSessions {
		if recipientSession.isAuthenticated &&
		   recipientPeerID != request.excludePeerID &&
		   MainRouterState_hasRecipientUserID(
			   shared.userIds[:],
			   recipientSession.authenticatedUserID,
		   ) {
			MainRouterState_sendVisibilityPayload(pm, state, recipientPeerID, request.visibility)
		}
	}
}

// Sends every authenticated session of userIDs a fresh ServerUserList (their view changed).
MainRouterState_resendUserLists :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	userIDs: []int,
) {
	for recipientPeerID, recipientSession in state.peerSessions {
		if !recipientSession.isAuthenticated ||
		   !MainRouterState_hasRecipientUserID(userIDs, recipientSession.authenticatedUserID) {
			continue
		}
		MainRouterState_enqueueChannelDatabaseRequest(
			pm,
			state,
			recipientPeerID,
			common.DatabaseUserDirectoryRequest {
				viewerUserId = recipientSession.authenticatedUserID,
			},
			PendingDBRequest{requestType = .ListUsers},
		)
	}
}

// Sends every authenticated session a fresh ServerUserList.
MainRouterState_resendAllUserLists :: proc(pm: ^ProcessManager, state: ^MainRouterState) {
	for recipientPeerID, recipientSession in state.peerSessions {
		if recipientSession.isAuthenticated {
			MainRouterState_enqueueChannelDatabaseRequest(
				pm,
				state,
				recipientPeerID,
				common.DatabaseUserDirectoryRequest {
					viewerUserId = recipientSession.authenticatedUserID,
				},
				PendingDBRequest{requestType = .ListUsers},
			)
		}
	}
}

// D17: userID joined or left a room whose members after it are memberUserIDs. When a restricted
// account is on either side, the accounts whose view changed get a fresh ServerUserList: every
// member when userID is restricted, otherwise the restricted members, and userID itself when
// any of them is. Without restricted accounts this does nothing.
MainRouterState_noteMembershipVisibility :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	userID: int,
	memberUserIDs: []int,
) {
	if len(state.restrictedUserIDs) == 0 {
		return
	}
	changedRestricted := MainRouterState_userIsRestricted(state, userID)
	anyRestricted := changedRestricted
	affected := make([dynamic]int)
	defer delete(affected)
	for memberUserID in memberUserIDs {
		if memberUserID == userID {
			continue
		}
		memberRestricted := MainRouterState_userIsRestricted(state, memberUserID)
		anyRestricted ||= memberRestricted
		if changedRestricted || memberRestricted {
			append(&affected, memberUserID)
		}
	}
	if anyRestricted {
		append(&affected, userID)
	}
	MainRouterState_resendUserLists(pm, state, affected[:])
}

// Asks the database for every restricted account; the main loop calls it once at start.
MainRouterState_loadRestrictedUsers :: proc(pm: ^ProcessManager, state: ^MainRouterState) {
	MainRouterState_enqueueChannelDatabaseRequest(
		pm,
		state,
		0,
		common.DatabaseRestrictedUsersRequest{},
		PendingDBRequest{requestType = .LoadRestrictedUsers},
	)
}

MainRouterState_handleRestrictedUsersResult :: proc(
	state: ^MainRouterState,
	response: common.DatabaseQueryResponse,
) {
	loaded, loadedOK := response.result.(common.DatabaseRestrictedUsersResult)
	if !response.success || !loadedOK {
		fmt.printfln("[Main] Could not load restricted accounts: %s", response.message)
		return
	}
	clear(&state.restrictedUserIDs)
	for userID in loaded.userIds {
		state.restrictedUserIDs[userID] = true
	}
}

// Sets the permissions every session of userID carries (presence filtering and approver
// fan-out read them).
MainRouterState_setUserSessionPermissions :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	userID: int,
	permissions: common.ServerPermissions,
) {
	changed := false
	for _, &session in state.peerSessions {
		if session.isAuthenticated && session.authenticatedUserID == userID {
			seesBefore := .ApproveRegistrations in session.permissions
			session.permissions = permissions
			changed ||= seesBefore != (.ApproveRegistrations in permissions)
		}
	}
	// An approver sees every account (D17), so gaining or losing it changes the list.
	if changed && len(state.restrictedUserIDs) > 0 {
		MainRouterState_resendUserLists(pm, state, []int{userID})
	}
}

// The number of sessions registering now.
MainRouterState_registeringSessionCount :: proc(state: ^MainRouterState) -> int {
	count := 0
	for _, session in state.peerSessions {
		if session.isRegistering {
			count += 1
		}
	}
	return count
}

// The sentence ServerRegistrationRequired carries. Heap allocated.
@(private = "file")
MainRouterState_registrationRequiredMessage :: proc(
	identity: common.DatabaseUserIdentityResult,
) -> string {
	#partial switch identity.requestStatus {
	case .Pending, .Approved:
		return strings.clone(common.REGISTRATION_PENDING_MESSAGE)
	case .Declined:
		if len(identity.decisionReason) > 0 {
			return strings.concatenate(
				{common.REGISTRATION_DECLINED_MESSAGE, ": ", identity.decisionReason},
			)
		}
		return strings.clone(common.REGISTRATION_DECLINED_MESSAGE)
	}
	switch identity.registrationMode {
	case .Open:
		return strings.clone(common.REGISTRATION_OPEN_MESSAGE)
	case .InviteOnly:
		return strings.clone(common.REGISTRATION_REQUIRED_MESSAGE)
	case .InviteApproval:
		return strings.clone(common.REGISTRATION_APPROVAL_REQUIRED_MESSAGE)
	}
	return strings.clone(common.REGISTRATION_REQUIRED_MESSAGE)
}

// The identity statement said the key must sign up (D12): answer ServerRegistrationRequired in
// plaintext and make the session registering. Its transport is already active.
MainRouterState_beginRegistration :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	identity: common.DatabaseUserIdentityResult,
) {
	session, ok := &state.peerSessions[peerID]
	if !ok || session.isAuthenticated || session.isRegistering {
		return
	}
	if MainRouterState_registeringSessionCount(state) >= common.REGISTERING_SESSIONS_MAX {
		MainRouterState_sendAuthFailure(pm, state, peerID, common.REGISTRATION_BUSY_MESSAGE)
		session.transport.phase = .Failed
		MainRouterState_disconnectPeer(pm, peerID)
		return
	}
	message := MainRouterState_registrationRequiredMessage(identity)
	defer delete(message)
	if !MainRouterState_sendPeerMessage(
		pm,
		state,
		peerID,
		.ServerRegistrationRequired,
		common.ServerRegistrationRequiredPayload {
			mode = identity.registrationMode,
			status = identity.requestStatus,
			message = message,
		},
	) {
		MainRouterState_protocolViolation(pm, state, peerID, "Failed to send registration notice")
		return
	}
	if stored, storedOK := &state.peerSessions[peerID]; storedOK {
		stored.isRegistering = true
		stored.registeringSince = time.tick_now()
		stored.registerAttempts = 0
		stored.registerInFlight = false
	}
}

// Sends a registering session ServerRegisterResponse (sealed).
MainRouterState_sendRegisterResponse :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	status: common.RegisterStatus,
	message: string,
) {
	MainRouterState_sendPeerMessage(
		pm,
		state,
		peerID,
		.ServerRegisterResponse,
		common.ServerRegisterResponsePayload{status = status, message = message},
	)
}

// Ends a registering session: a last ServerRegisterResponse, then the disconnect.
MainRouterState_endRegistration :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	status: common.RegisterStatus,
	message: string,
) {
	MainRouterState_sendRegisterResponse(pm, state, peerID, status, message)
	if session, ok := &state.peerSessions[peerID]; ok {
		session.isRegistering = false
		session.transport.phase = .Failed
	}
	MainRouterState_disconnectPeer(pm, peerID)
}

// Ends registering sessions older than REGISTER_SESSION_SECONDS (D13). now is a parameter so
// tests need no clock.
MainRouterState_expireRegisteringSessions :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	now: time.Tick,
) {
	expired := make([dynamic]u32)
	defer delete(expired)
	for peerID, session in state.peerSessions {
		if session.isRegistering &&
		   time.tick_diff(session.registeringSince, now) >=
			   common.REGISTER_SESSION_SECONDS * time.Second {
			append(&expired, peerID)
		}
	}
	for peerID in expired {
		MainRouterState_endRegistration(
			pm,
			state,
			peerID,
			.Refused,
			common.REGISTRATION_TIMED_OUT_MESSAGE,
		)
	}
}

// An encrypted packet from a registering session: only ClientRegister and Ping (D12).
MainRouterState_handleRegisteringPacket :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	packet: common.Packet,
) {
	if packet.messageType != .EncryptedPacket {
		MainRouterState_protocolViolation(pm, state, peerID, "Encrypted transport required")
		return
	}
	MainRouterState_expireRegisteringSessions(pm, state, time.tick_now())
	session, ok := MainRouterState_getPeerSession(state, peerID)
	if !ok || !session.isRegistering || !common.TransportState_canEncrypt(&session.transport) {
		return
	}
	innerPacket, openOK := common.openPacketForSession(&session.transport, packet)
	if !openOK {
		MainRouterState_protocolViolation(pm, state, peerID, "Failed to open encrypted packet")
		return
	}
	defer delete(innerPacket.payload)
	MainRouterState_setPeerSession(state, peerID, session)
	#partial switch innerPacket.messageType {
	case .ClientRegister:
		MainRouterState_handleClientRegister(pm, state, peerID, innerPacket.payload)
	case .Ping:
	// A keepalive; nothing to answer.
	case:
		MainRouterState_protocolViolation(pm, state, peerID, "Sign up before anything else")
	}
}

MainRouterState_handleClientRegister :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	payload: []u8,
) {
	session, ok := &state.peerSessions[peerID]
	if !ok || !session.isRegistering || session.registerInFlight {
		MainRouterState_protocolViolation(pm, state, peerID, "Unexpected ClientRegister")
		return
	}
	req: common.ClientRegisterRequest
	decodeErr := cbor.unmarshal(payload, &req)
	defer common.ClientRegisterRequest_deinit(&req)
	session.registerAttempts += 1
	refusal := ""
	code: common.InviteCodeBytes
	hasCode := false
	if decodeErr != nil ||
	   len(req.inviteCode) > common.INVITE_CODE_TEXT_MAX_BYTES ||
	   !common.registrationTextIsValid(req.reason, 0, common.REGISTRATION_REASON_MAX_CHARS) {
		refusal = common.REGISTRATION_INVALID_MESSAGE
	} else if len(strings.trim_space(req.inviteCode)) > 0 {
		parsed, parsedOK := common.parseInviteCode(req.inviteCode)
		if !parsedOK {
			refusal = common.INVITE_CODE_INVALID_MESSAGE
		}
		code = parsed
		hasCode = parsedOK
	}
	if len(refusal) > 0 {
		if serverLogLevelIsDebug(pm.config.logLevel) {
			fmt.printfln("[Main] Sign-up refused on peer %d: %s", peerID, refusal)
		}
		MainRouterState_registerRefused(pm, state, peerID, refusal)
		return
	}
	hash := common.inviteCodeHash(code)
	crypto.zero_explicit(&code, size_of(code))
	session.registerInFlight = true
	MainRouterState_enqueueChannelDatabaseRequest(
		pm,
		state,
		peerID,
		common.DatabaseRegisterRequest {
			publicKey = session.clientIdentityPublicKey,
			nickname = strings.clone(session.clientNickname),
			codeHash = hash,
			hasCode = hasCode,
			reason = strings.clone(req.reason),
		},
		PendingDBRequest{requestType = .Register},
	)
}

// A refused ClientRegister: the session stays registering until it has used its attempts.
@(private = "file")
MainRouterState_registerRefused :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	message: string,
) {
	session, ok := MainRouterState_getPeerSession(state, peerID)
	if ok && session.registerAttempts >= common.REGISTER_ATTEMPTS_MAX {
		MainRouterState_endRegistration(pm, state, peerID, .Refused, message)
		return
	}
	MainRouterState_sendRegisterResponse(pm, state, peerID, .Refused, message)
}

// Answers a sign-up with ServerRegisterResponse{Created, auth} in place of ServerAuthSuccess;
// MainRouterState_completeAuthentication's sender.
@(private = "file")
MainRouterState_sendRegisterCreated :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	payload: common.ServerAuthSuccessPayload,
) -> bool {
	return MainRouterState_sendPeerMessage(
		pm,
		state,
		peerID,
		.ServerRegisterResponse,
		common.ServerRegisterResponsePayload{status = .Created, message = "ok", auth = payload},
	)
}

// Turns a registering session into an authenticated one: ServerRegisterResponse{Created} (still
// sealed for a registering session), then everything ServerAuthSuccess brings.
MainRouterState_completeRegistration :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	userID: int,
	isAdmin: bool,
	nickname: string,
	nicknameLocked: bool,
	permissions: common.ServerPermissions,
	registrationMode: common.RegistrationMode,
	isRestricted: bool,
) {
	MainRouterState_setUserRestricted(state, userID, isRestricted)
	MainRouterState_completeAuthentication(
		pm,
		state,
		peerID,
		userID,
		isAdmin = isAdmin,
		nickname = nickname,
		nicknameLocked = nicknameLocked,
		permissions = permissions,
		registrationMode = registrationMode,
		isRestricted = isRestricted,
		sendAuthSuccess = MainRouterState_sendRegisterCreated,
	)
	if session, ok := &state.peerSessions[peerID]; ok {
		session.isRegistering = false
		session.registerInFlight = false
	}
}

// Sends ServerRegistrationRequestUpdated to every approver session (D18).
MainRouterState_sendRegistrationRequestUpdated :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	request: common.RegistrationRequestSummary,
	pendingCount: int,
) {
	payload := common.ServerRegistrationRequestUpdatedPayload {
		request      = request,
		pendingCount = pendingCount,
	}
	for recipientPeerID, recipientSession in state.peerSessions {
		if recipientSession.isAuthenticated &&
		   .ApproveRegistrations in recipientSession.permissions {
			MainRouterState_sendPeerMessage(
				pm,
				state,
				recipientPeerID,
				.ServerRegistrationRequestUpdated,
				payload,
			)
		}
	}
}

MainRouterState_handleRegisterResult :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	request: PendingDBRequest,
	response: common.DatabaseQueryResponse,
) {
	registered, registeredOK := response.result.(common.DatabaseRegisterResult)
	if response.success && registeredOK && registered.outcome == .Pending {
		// Approvers hear of it even when the applicant already left.
		MainRouterState_sendRegistrationRequestUpdated(
			pm,
			state,
			registered.request,
			registered.pendingCount,
		)
	}
	if response.success && registeredOK && registered.outcome == .Created {
		MainRouterState_setUserRestricted(state, registered.userId, registered.isRestricted)
	}
	session, sessionOK := &state.peerSessions[request.peerID]
	if !sessionOK || !session.isRegistering {
		return
	}
	session.registerInFlight = false
	if !response.success || !registeredOK {
		MainRouterState_registerRefused(
			pm,
			state,
			request.peerID,
			common.REGISTRATION_INVALID_MESSAGE,
		)
		return
	}
	if serverLogLevelIsDebug(pm.config.logLevel) {
		fmt.printfln("[Main] Sign-up on peer %d: %v", request.peerID, registered.outcome)
	}
	switch registered.outcome {
	case .Created:
		MainRouterState_completeRegistration(
			pm,
			state,
			request.peerID,
			registered.userId,
			false,
			registered.nickname,
			false,
			registered.permissions,
			registered.registrationMode,
			registered.isRestricted,
		)
	case .Pending, .AlreadyPending:
		MainRouterState_sendRegisterResponse(
			pm,
			state,
			request.peerID,
			.Pending,
			common.REGISTRATION_PENDING_MESSAGE,
		)
	case .InvalidCode:
		MainRouterState_registerRefused(
			pm,
			state,
			request.peerID,
			common.INVITE_CODE_INVALID_MESSAGE,
		)
	case .NameTaken:
		MainRouterState_registerRefused(
			pm,
			state,
			request.peerID,
			common.REGISTRATION_NAME_TAKEN_MESSAGE,
		)
	case .ReasonRequired:
		MainRouterState_registerRefused(
			pm,
			state,
			request.peerID,
			common.REGISTRATION_REASON_REQUIRED_MESSAGE,
		)
	case .HasAccount:
		MainRouterState_registerRefused(
			pm,
			state,
			request.peerID,
			common.REGISTRATION_INVALID_MESSAGE,
		)
	}
}

// The identity statement's answer for a session that is registering: an approval re-ran it
// (D14). A resolved account completes the session; anything else keeps it registering, with
// a refusal when the name is taken now.
MainRouterState_handleRegisteringIdentityResult :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	response: common.DatabaseQueryResponse,
) {
	session, sessionOK := &state.peerSessions[peerID]
	if !sessionOK || !session.isRegistering {
		return
	}
	session.registerInFlight = false
	identity, identityOK := response.result.(common.DatabaseUserIdentityResult)
	if !response.success || !identityOK {
		return
	}
	if identity.userId > 0 && !identity.banned {
		MainRouterState_completeRegistration(
			pm,
			state,
			peerID,
			identity.userId,
			identity.isAdmin,
			identity.nickname,
			identity.nicknameLocked,
			identity.permissions,
			identity.registrationMode,
			identity.isRestricted,
		)
		return
	}
	if identity.userId <= 0 && !identity.needsRegistration {
		MainRouterState_sendRegisterResponse(
			pm,
			state,
			peerID,
			.Refused,
			common.REGISTRATION_NAME_TAKEN_MESSAGE,
		)
	}
}

// Requires an authenticated session; refusals are ServerProtocolError.
@(private = "file")
MainRouterState_registrationActor :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
) -> (
	int,
	bool,
) {
	return MainRouterState_authenticatedUserID(
		pm,
		state,
		peerID,
		"Unauthenticated registration request",
	)
}

MainRouterState_handleClientAdminSetRegistrationMode :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	payload: []u8,
) {
	userID, ok := MainRouterState_registrationActor(pm, state, peerID)
	if !ok {
		return
	}
	req: common.ClientAdminSetRegistrationModePayload
	if cbor.unmarshal(payload, &req) != nil || !common.registrationModeIsSupported(req.mode) {
		MainRouterState_sendProtocolError(
			pm,
			state,
			peerID,
			common.REGISTRATION_MODE_INVALID_MESSAGE,
		)
		return
	}
	MainRouterState_enqueueChannelDatabaseRequest(
		pm,
		state,
		peerID,
		common.DatabaseRegistrationModeRequest{actorUserId = userID, mode = req.mode},
		PendingDBRequest{requestType = .RegistrationMode},
	)
}

MainRouterState_handleRegistrationModeResult :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	request: PendingDBRequest,
	response: common.DatabaseQueryResponse,
) {
	result, resultOK := response.result.(common.DatabaseRegistrationModeResult)
	if MainRouterState_databaseFailed(pm, state, request.peerID, response, resultOK) {
		return
	}
	if !result.allowed {
		MainRouterState_sendAdminRequired(pm, state, request.peerID)
		return
	}
	message := fmt.aprintf(
		"%s registration mode: %s",
		result.changed ? "Changed the" : "Kept the",
		MainRouterState_registrationModeName(result.mode),
	)
	defer delete(message)
	MainRouterState_sendPeerMessage(
		pm,
		state,
		request.peerID,
		.ServerAdminActionResult,
		common.ServerAdminActionResultPayload{action = .SetRegistrationMode, message = message},
	)
	if result.changed {
		for recipientPeerID, recipientSession in state.peerSessions {
			if recipientSession.isAuthenticated {
				MainRouterState_sendPeerMessage(
					pm,
					state,
					recipientPeerID,
					.ServerRegistrationMode,
					common.ServerRegistrationModePayload{mode = result.mode},
				)
			}
		}
	}
}

MainRouterState_registrationModeName :: proc(mode: common.RegistrationMode) -> string {
	switch mode {
	case .Open:
		return "open"
	case .InviteOnly:
		return "invite only"
	case .InviteApproval:
		return "invite and approval"
	}
	return "unknown"
}

MainRouterState_handleClientCreateInvite :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	payload: []u8,
) {
	userID, ok := MainRouterState_registrationActor(pm, state, peerID)
	if !ok {
		return
	}
	req: common.ClientCreateInvitePayload
	decodeErr := cbor.unmarshal(payload, &req)
	defer common.ClientCreateInvitePayload_deinit(&req)
	if decodeErr != nil || !common.inviteCreateRequestIsValid(req) {
		MainRouterState_sendProtocolError(pm, state, peerID, common.INVITE_INVALID_REQUEST_MESSAGE)
		return
	}
	code, codeOK := common.generateInviteCode()
	if !codeOK {
		MainRouterState_sendProtocolError(pm, state, peerID, "Could not create an invite code")
		return
	}
	requestID := MainRouterState_generateRequestID(state)
	state.pendingInviteCodes[requestID] = code
	crypto.zero_explicit(&code, size_of(code))
	roleIDs := make([dynamic]int, 0, len(req.roleIds))
	append(&roleIDs, ..req.roleIds[:])
	state.pendingDatabaseRequests[requestID] = PendingDBRequest {
		requestID   = requestID,
		peerID      = peerID,
		requestType = .InviteAction,
	}
	IPC_Server_send(
		&pm.config.databaseSocket,
		pm.config.databaseFd,
		DatabaseQuery {
			request_id = requestID,
			request = common.DatabaseInviteRequest {
				action = .Create,
				actorUserId = userID,
				codeHash = common.inviteCodeHash(state.pendingInviteCodes[requestID]),
				note = strings.clone(req.note),
				expiresInSeconds = req.expiresInSeconds,
				maxUses = req.maxUses,
				roleIds = roleIDs,
				roomId = req.roomId,
				skipApproval = req.skipApproval,
			},
		},
	)
}

// Wipes and forgets the code a pending ClientCreateInvite generated.
MainRouterState_forgetInviteCode :: proc(state: ^MainRouterState, requestID: u64) {
	if code, ok := &state.pendingInviteCodes[requestID]; ok {
		crypto.zero_explicit(code, size_of(code^))
		delete_key(&state.pendingInviteCodes, requestID)
	}
}

MainRouterState_handleClientListInvites :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	payload: []u8,
) {
	userID, ok := MainRouterState_registrationActor(pm, state, peerID)
	if !ok {
		return
	}
	req: common.ClientListInvitesPayload
	if cbor.unmarshal(payload, &req) != nil {
		MainRouterState_sendProtocolError(pm, state, peerID, common.INVITE_INVALID_REQUEST_MESSAGE)
		return
	}
	MainRouterState_enqueueChannelDatabaseRequest(
		pm,
		state,
		peerID,
		common.DatabaseInviteRequest{action = .List, actorUserId = userID},
		PendingDBRequest{requestType = .InviteAction},
	)
}

MainRouterState_handleClientRevokeInvite :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	payload: []u8,
) {
	userID, ok := MainRouterState_registrationActor(pm, state, peerID)
	if !ok {
		return
	}
	req: common.ClientRevokeInvitePayload
	if cbor.unmarshal(payload, &req) != nil || req.inviteId <= 0 {
		MainRouterState_sendProtocolError(pm, state, peerID, common.INVITE_INVALID_REQUEST_MESSAGE)
		return
	}
	MainRouterState_enqueueChannelDatabaseRequest(
		pm,
		state,
		peerID,
		common.DatabaseInviteRequest {
			action = .Revoke,
			actorUserId = userID,
			inviteId = req.inviteId,
		},
		PendingDBRequest{requestType = .InviteAction, roleID = req.inviteId},
	)
}

MainRouterState_inviteRefusalMessage :: proc(outcome: common.DatabaseInviteOutcome) -> string {
	switch outcome {
	case .NotPermitted:
		return common.INVITE_NOT_PERMITTED_MESSAGE
	case .AdminRequired:
		return common.INVITE_ADMIN_REQUIRED_MESSAGE
	case .ExpiryTooLong:
		return common.INVITE_EXPIRY_REQUIRED_MESSAGE
	case .UnknownRole:
		return common.INVITE_UNKNOWN_ROLE_MESSAGE
	case .BadRoom:
		return common.INVITE_BAD_ROOM_MESSAGE
	case .TooManyInvites:
		return common.INVITE_TOO_MANY_MESSAGE
	case .UnknownInvite:
		return common.INVITE_UNKNOWN_MESSAGE
	case .Applied:
	}
	return ""
}

MainRouterState_handleInviteResult :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	request: PendingDBRequest,
	response: common.DatabaseQueryResponse,
) {
	code, hasCode := state.pendingInviteCodes[request.requestID]
	MainRouterState_forgetInviteCode(state, request.requestID)
	defer crypto.zero_explicit(&code, size_of(code))
	result, resultOK := response.result.(common.DatabaseInviteResult)
	if MainRouterState_databaseFailed(pm, state, request.peerID, response, resultOK) {
		return
	}
	if result.outcome != .Applied {
		MainRouterState_sendProtocolError(
			pm,
			state,
			request.peerID,
			MainRouterState_inviteRefusalMessage(result.outcome),
		)
		return
	}
	switch {
	case hasCode:
		text := common.formatInviteCode(code)
		defer common.wipeAndDeleteString(&text)
		MainRouterState_sendPeerMessage(
			pm,
			state,
			request.peerID,
			.ServerInviteCreated,
			common.ServerInviteCreatedPayload{invite = result.invite, code = text},
		)
	case request.roleID > 0:
		MainRouterState_sendPeerMessage(
			pm,
			state,
			request.peerID,
			.ServerAdminActionResult,
			common.ServerAdminActionResultPayload {
				action = .RevokeInvite,
				inviteId = request.roleID,
				message = result.changed ? "Revoked the invite code" : "Already revoked",
			},
		)
	case:
		MainRouterState_sendPeerMessage(
			pm,
			state,
			request.peerID,
			.ServerInviteList,
			common.ServerInviteListPayload{invites = result.invites},
		)
	}
}

MainRouterState_handleClientListRegistrationRequests :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	payload: []u8,
) {
	userID, ok := MainRouterState_registrationActor(pm, state, peerID)
	if !ok {
		return
	}
	req: common.ClientListRegistrationRequestsPayload
	if cbor.unmarshal(payload, &req) != nil {
		MainRouterState_sendProtocolError(
			pm,
			state,
			peerID,
			common.REGISTRATION_DECISION_INVALID_MESSAGE,
		)
		return
	}
	MainRouterState_enqueueChannelDatabaseRequest(
		pm,
		state,
		peerID,
		common.DatabaseRegistrationRequestsRequest {
			action = .List,
			actorUserId = userID,
			includeDecided = req.includeDecided,
		},
		PendingDBRequest{requestType = .RegistrationRequests},
	)
}

MainRouterState_handleClientDecideRegistration :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	payload: []u8,
) {
	userID, ok := MainRouterState_registrationActor(pm, state, peerID)
	if !ok {
		return
	}
	req: common.ClientDecideRegistrationPayload
	decodeErr := cbor.unmarshal(payload, &req)
	defer common.ClientDecideRegistrationPayload_deinit(&req)
	if decodeErr != nil ||
	   req.id <= 0 ||
	   !common.registrationTextIsValid(req.reason, 0, common.REGISTRATION_REASON_MAX_CHARS) {
		MainRouterState_sendProtocolError(
			pm,
			state,
			peerID,
			common.REGISTRATION_DECISION_INVALID_MESSAGE,
		)
		return
	}
	MainRouterState_enqueueChannelDatabaseRequest(
		pm,
		state,
		peerID,
		common.DatabaseRegistrationRequestsRequest {
			action = .Decide,
			actorUserId = userID,
			requestId = req.id,
			approve = req.approve,
			reason = strings.clone(req.reason),
		},
		PendingDBRequest{requestType = .RegistrationRequests, adminFlag = true},
	)
}

MainRouterState_registrationRequestsRefusalMessage :: proc(
	outcome: common.DatabaseRegistrationRequestsOutcome,
) -> string {
	switch outcome {
	case .NotPermitted:
		return common.REGISTRATION_APPROVER_REQUIRED_MESSAGE
	case .UnknownRequest:
		return common.REGISTRATION_UNKNOWN_REQUEST_MESSAGE
	case .AlreadyDecided:
		return common.REGISTRATION_ALREADY_DECIDED_MESSAGE
	case .Applied:
	}
	return ""
}

MainRouterState_handleRegistrationRequestsResult :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	request: PendingDBRequest,
	response: common.DatabaseQueryResponse,
) {
	result, resultOK := response.result.(common.DatabaseRegistrationRequestsResult)
	if MainRouterState_databaseFailed(pm, state, request.peerID, response, resultOK) {
		return
	}
	if result.outcome != .Applied {
		MainRouterState_sendProtocolError(
			pm,
			state,
			request.peerID,
			MainRouterState_registrationRequestsRefusalMessage(result.outcome),
		)
		return
	}
	if !request.adminFlag {
		MainRouterState_sendPeerMessage(
			pm,
			state,
			request.peerID,
			.ServerRegistrationRequests,
			common.ServerRegistrationRequestsPayload {
				requests = result.requests,
				pendingCount = result.pendingCount,
			},
		)
		return
	}
	decided := result.request
	approved := decided.status == .Approved
	message := fmt.aprintf(
		"%s the sign-up of %s",
		approved ? "Approved" : "Declined",
		decided.nickname,
	)
	defer delete(message)
	MainRouterState_sendPeerMessage(
		pm,
		state,
		request.peerID,
		.ServerAdminActionResult,
		common.ServerAdminActionResultPayload {
			action = .DecideRegistration,
			requestId = decided.id,
			message = message,
		},
	)
	MainRouterState_sendRegistrationRequestUpdated(pm, state, decided, result.pendingCount)
	MainRouterState_settleRegisteringApplicants(pm, state, decided)
}

// D14: an approved request completes every still registering session of its key live, by
// re-running the identity statement; a declined one is answered Declined and disconnected.
MainRouterState_settleRegisteringApplicants :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	decided: common.RegistrationRequestSummary,
) {
	peerIDs := make([dynamic]u32)
	defer delete(peerIDs)
	for peerID, session in state.peerSessions {
		applicantKey := session.clientIdentityPublicKey
		decidedKey := decided.identityPublicKey
		if session.isRegistering &&
		   !session.registerInFlight &&
		   common.constantTimeEqual(applicantKey[:], decidedKey[:]) {
			append(&peerIDs, peerID)
		}
	}
	for peerID in peerIDs {
		if decided.status != .Approved {
			message := MainRouterState_declinedMessage(decided.decisionReason)
			defer delete(message)
			MainRouterState_endRegistration(pm, state, peerID, .Declined, message)
			continue
		}
		session, ok := &state.peerSessions[peerID]
		if !ok {
			continue
		}
		session.registerInFlight = true
		MainRouterState_enqueueChannelDatabaseRequest(
			pm,
			state,
			peerID,
			common.DatabaseUserIdentityRequest {
				nickname = strings.clone(session.clientNickname),
				publicKey = session.clientIdentityPublicKey,
				adminPublicKey = state.adminPublicKey,
				hasAdminPublicKey = state.hasAdminPublicKey,
				registering = true,
			},
			PendingDBRequest{requestType = .ResolveUserIdentity},
		)
	}
}

// The sentence a declined applicant sees. Heap allocated.
MainRouterState_declinedMessage :: proc(reason: string) -> string {
	if len(reason) > 0 {
		return strings.concatenate({common.REGISTRATION_DECLINED_MESSAGE, ": ", reason})
	}
	return strings.clone(common.REGISTRATION_DECLINED_MESSAGE)
}

MainRouterState_handleClientAdminSetRestricted :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	payload: []u8,
) {
	userID, ok := MainRouterState_authenticatedUserForAdminRequest(pm, state, peerID)
	if !ok {
		return
	}
	req: common.ClientAdminSetRestrictedPayload
	if cbor.unmarshal(payload, &req) != nil || req.userId <= 0 {
		MainRouterState_sendProtocolError(pm, state, peerID, common.RESTRICTED_INVALID_MESSAGE)
		return
	}
	MainRouterState_enqueueChannelDatabaseRequest(
		pm,
		state,
		peerID,
		common.DatabaseAdminUserRequest {
			action = .SetRestricted,
			actorUserId = userID,
			targetUserId = req.userId,
			restricted = req.restricted,
		},
		PendingDBRequest {
			requestType = .AdminUserAction,
			adminAction = .SetRestricted,
			adminFlag = req.restricted,
		},
	)
}
