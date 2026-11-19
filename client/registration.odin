package client

import "../common"
import "core:crypto"
import "core:fmt"
import "core:slice"
import "core:strings"

// Registration in the client (protocol 25, #43 G2, plan D12-D19).
//
// Signing up: a key without an account gets ServerRegistrationRequired; the transport is then
// active and registering (connection.odin), and State shows the sign-up screen
// (view_registration.odin) for that server: the invite code field, the reason field in
// Invite + approval mode, and Sign up, which sends one sealed ClientRegister. The answer is
// Created (the normal Connected path, registered set), Pending (the waiting screen with Check
// again, which reconnects and never resends the code), Refused (shown; the user fixes the code
// and tries again in the same session) or Declined (like a ban, D16). A session the server
// ends is never retried on its own. The code lives only in SignUpForm.code, in memory, and is
// wiped after the answer or when the screen goes away; it is never logged or saved.
//
// Administering: approvers (ApproveRegistrations) fetch ClientListRegistrationRequests after
// every Connected for the badge (D18: a count, no pop-up), which every
// ServerRegistrationRequestUpdated keeps current; inviters (CreateInvites) create, list and
// revoke codes; admins change the mode and lift restrictions. Revoke, decide, mode and
// restriction are admin actions (admin.odin), so their answers show as the Admin section's
// status; invite creation is answered by ServerInviteCreated, the only time the code is sent.

// What the sign-up screen shows for one server (ServerConnection.signUp).
SignUpPhase :: enum u8 {
	None, // Signed in, or never asked to sign up
	Required, // The server wants a code (and in approval mode a reason)
	Submitting, // A ClientRegister is waiting for its answer
	Pending, // The request waits for an approver
	Refused, // The last ClientRegister was refused; signUpMessage says why
	Declined, // An approver declined the request (D16: like a ban)
	Ended, // The server ended the sign-up session; Start again reconnects
}

// The sign-up screen's fields. One for the whole State: only the selected server's screen is
// drawn, and the code is wiped when another server's screen takes the form.
SignUpForm :: struct {
	serverID: int,
	// Edited in place by the text inputs. code is wiped (zeroed) before it is cleared or freed.
	code:     [dynamic]u8,
	reason:   [dynamic]u8,
	// A local check that kept the request from going out. Owned.
	error:    string,
}

// Zeroes a buffer's bytes and empties it.
wipeBuffer :: proc(buffer: ^[dynamic]u8) {
	if len(buffer) > 0 {
		crypto.zero_explicit(raw_data(buffer[:]), len(buffer))
	}
	clear(buffer)
}

SignUpForm_deinit :: proc(form: ^SignUpForm) {
	wipeBuffer(&form.code)
	delete(form.code)
	delete(form.reason)
	delete(form.error)
	form^ = {}
}

@(private = "file")
SignUpForm_setError :: proc(form: ^SignUpForm, message: string) {
	delete(form.error)
	form.error = strings.clone(message)
}

// Forgets the code (and the reason) the user typed or a link filled in.
State_wipeSignUpForm :: proc(state: ^State) {
	form := &state.signUpForm
	wipeBuffer(&form.code)
	clear(&form.reason)
	SignUpForm_setError(form, "")
}

// The form for serverID: another server's leftovers (its code included) are wiped first.
State_signUpFormFor :: proc(state: ^State, serverID: int) -> ^SignUpForm {
	form := &state.signUpForm
	if form.serverID != serverID {
		State_wipeSignUpForm(state)
		form.serverID = serverID
	}
	return form
}

// Fills the code field (an invite link, D19). code is borrowed.
State_prefillSignUpCode :: proc(state: ^State, serverID: int, code: string) {
	form := State_signUpFormFor(state, serverID)
	wipeBuffer(&form.code)
	append(&form.code, code)
	SignUpForm_setError(form, "")
}

// What a person typed or pasted as a code, without spaces, tabs, line breaks and dashes, in
// upper case, in allocator. parseInviteCode accepts it in any case either way; this is what
// the field shows after a paste and what goes out.
normalizeInviteCodeInput :: proc(text: string, allocator := context.temp_allocator) -> string {
	builder := strings.builder_make(allocator)
	for r in text {
		switch r {
		case ' ', '\t', '\r', '\n', '-':
			continue
		case 'a' ..= 'z':
			strings.write_rune(&builder, r - 'a' + 'A')
		case:
			strings.write_rune(&builder, r)
		}
	}
	return strings.to_string(builder)
}

// Replaces the field's text with its normalized form (Paste, and before sending).
State_normalizeSignUpCode :: proc(state: ^State, serverID: int) {
	form := State_signUpFormFor(state, serverID)
	normalized := normalizeInviteCodeInput(string(form.code[:]))
	defer {
		bytes := transmute([]u8)normalized
		crypto.zero_explicit(raw_data(bytes), len(bytes))
	}
	wipeBuffer(&form.code)
	append(&form.code, normalized)
}

// Pastes text into the code field, normalized. text is borrowed.
State_pasteSignUpCode :: proc(state: ^State, serverID: int, text: string) {
	form := State_signUpFormFor(state, serverID)
	wipeBuffer(&form.code)
	append(&form.code, text)
	State_normalizeSignUpCode(state, serverID)
}

// ── Requests ──────────────────────────────────────────────────────

RegistrationRequestKind :: enum u8 {
	Register,
	CreateInvite,
	ListInvites,
	ListRequests,
}

// One registration request. Strings are borrowed; roleIDs is a fixed array so the request
// stays comparable (tests compare requests).
RegistrationRequest :: struct {
	kind:             RegistrationRequestKind,
	// Register.
	code:             string,
	reason:           string,
	// CreateInvite.
	note:             string,
	expiresInSeconds: int,
	maxUses:          int,
	roleIDs:          [common.SERVER_ROLES_MAX]int,
	roleIDCount:      int,
	roomID:           int,
	skipApproval:     bool,
	// ListRequests.
	includeDecided:   bool,
}

RegistrationSendBridge :: #type proc(
	transport: ^ClientServerTransport,
	request: RegistrationRequest,
) -> bool

// Tests swap this to observe requests without a live session, under
// registrationSendBridgeTestMutex.
registrationSendBridge: RegistrationSendBridge = ClientServerTransport_sendRegistrationRequest

ClientServerTransport_sendRegistrationRequest :: proc(
	transport: ^ClientServerTransport,
	request: RegistrationRequest,
) -> bool {
	switch request.kind {
	case .Register:
		return ClientServerTransport_sendRegister(transport, request.code, request.reason)
	case .CreateInvite:
		roleIDs := request.roleIDs
		return ClientServerTransport_createInvite(
			transport,
			request.note,
			request.expiresInSeconds,
			request.maxUses,
			roleIDs[:request.roleIDCount],
			request.roomID,
			request.skipApproval,
		)
	case .ListInvites:
		return ClientServerTransport_listInvites(transport)
	case .ListRequests:
		return ClientServerTransport_listRegistrationRequests(transport, request.includeDecided)
	}
	return false
}

// Sends one request through the bridge under the worker lock. Returns "" when the transport
// took it, otherwise the reason (static or in the temp allocator).
@(private = "file")
State_sendRegistrationRequest :: proc(
	state: ^State,
	serverID: int,
	request: RegistrationRequest,
) -> string {
	transportIndex := State_selectedTransportIndexForServerID(state^, serverID)
	if transportIndex < 0 {
		return "No server transport selected"
	}
	connectionIndex := State_serverConnectionIndex(state^, serverID)
	if connectionIndex < 0 {
		return NOT_CONNECTED_MESSAGE
	}
	status := state.serverConnections[connectionIndex].status
	if (request.kind == .Register && status != .Registering) ||
	   (request.kind != .Register && status != .Established) {
		return NOT_CONNECTED_MESSAGE
	}
	transport := &state.serverTransports[transportIndex]
	ClientNetworkWorker_lock(state.networkWorker)
	sent := registrationSendBridge(transport, request)
	sendError := sent ? "" : strings.clone(transport.lastError, context.temp_allocator)
	ClientNetworkWorker_unlock(state.networkWorker)
	if !sent {
		return len(sendError) > 0 ? sendError : "Failed to send the request"
	}
	return ""
}

// ── Signing up ───────────────────────────────────────────────────

SIGN_UP_CODE_INVALID_LOCAL ::
	"An invite code has 32 letters and digits (dashes and spaces do not matter)."
SIGN_UP_CODE_REQUIRED_LOCAL :: "Enter the invite code you were given."
SIGN_UP_REASON_INVALID_LOCAL ::
	"The reason must be at most 500 characters, without control characters other than line breaks."

// Checks the form the way the server will. Returns "" when it may go out. code is the
// normalized field.
validateSignUp :: proc(mode: common.RegistrationMode, code, reason: string) -> string {
	if len(code) == 0 {
		// Only an Open server signs up without a code (the account is then plain).
		if mode != .Open {
			return SIGN_UP_CODE_REQUIRED_LOCAL
		}
	} else if _, ok := common.parseInviteCode(code); !ok {
		return SIGN_UP_CODE_INVALID_LOCAL
	}
	// An empty reason may go out in Invite + approval mode too: a code with Skip approval
	// needs none, and only the server knows the code (REGISTRATION_REASON_REQUIRED_MESSAGE).
	if !common.registrationTextIsValid(reason, 0, common.REGISTRATION_REASON_MAX_CHARS) {
		return SIGN_UP_REASON_INVALID_LOCAL
	}
	return ""
}

// Sign up: sends the form's code and reason as one sealed ClientRegister. Returns "" when it
// went out; otherwise the reason, which the form also shows.
State_submitSignUp :: proc(state: ^State, serverID: int) -> string {
	connectionIndex := State_serverConnectionIndex(state^, serverID)
	if connectionIndex < 0 || state.serverConnections[connectionIndex].status != .Registering {
		return NOT_CONNECTED_MESSAGE
	}
	connection := &state.serverConnections[connectionIndex]
	if connection.signUp == .Submitting {
		return "Waiting for the server's answer."
	}
	if connection.signUp == .Pending {
		return common.REGISTRATION_PENDING_MESSAGE
	}
	State_normalizeSignUpCode(state, serverID)
	form := State_signUpFormFor(state, serverID)
	reason := strings.trim_space(string(form.reason[:]))
	if connection.registrationMode != .InviteApproval {
		reason = ""
	}
	if errorMessage := validateSignUp(connection.registrationMode, string(form.code[:]), reason);
	   len(errorMessage) > 0 {
		SignUpForm_setError(form, errorMessage)
		return errorMessage
	}
	errorMessage := State_sendRegistrationRequest(
		state,
		serverID,
		RegistrationRequest{kind = .Register, code = string(form.code[:]), reason = reason},
	)
	if len(errorMessage) > 0 {
		SignUpForm_setError(form, errorMessage)
		return errorMessage
	}
	SignUpForm_setError(form, "")
	connection = State_serverConnection(state, serverID)
	connection.signUp = .Submitting
	return ""
}

// Check again (pending) and Start again (ended): a new connection, which asks the server for
// the request's state. The code is not sent again; a still-pending request comes back as
// ServerRegistrationRequired{Pending}, an approved one signs in.
State_signUpReconnect :: proc(state: ^State, serverID: int) {
	State_retryConnection(state, serverID)
}

@(private = "file")
ServerConnection_setSignUp :: proc(
	connection: ^ServerConnection,
	phase: SignUpPhase,
	message: string,
) {
	connection.signUp = phase
	delete(connection.signUpMessage)
	connection.signUpMessage = strings.clone(message)
}

// ServerRegistrationRequired: the transport is registering. Takes nothing from the event (its
// message is cloned).
State_registrationRequired :: proc(state: ^State, event: ^ClientTransportRuntimeEvent) {
	connection := State_serverConnection(state, event.serverID)
	connection.status = .Registering
	connection.failureKind = .None
	connection.retryable = false
	connection.lastAttemptFailed = false
	connection.userID = 0
	connection.isAdmin = false
	connection.permissions = {}
	connection.registrationMode = event.registrationMode
	connection.signUpRequestStatus = event.registrationRequestStatus
	delete(connection.detail)
	connection.detail = ""
	phase := SignUpPhase.Required
	if event.registrationRequestStatus == .Pending {
		phase = .Pending
	}
	ServerConnection_setSignUp(connection, phase, event.message)
	if phase == .Pending {
		// The code went out with an earlier session; it is not needed again.
		State_wipeSignUpFormFor(state, event.serverID)
	}
	// The worker pinned the server's key on first use; remember it, as Connected does.
	if len(event.serverPublicKey) > 0 {
		if server, ok := State_serverConfig(state, event.serverID); ok {
			Server_setPins(server, event.serverPublicKey, event.serverFingerprint)
			State_saveConfig(state)
		}
	}
}

// ServerRegisterResponse other than Created. Takes the event's message for a failure.
State_registrationResult :: proc(state: ^State, event: ^ClientTransportRuntimeEvent) {
	switch event.registerStatus {
	case .Pending:
		connection := State_serverConnection(state, event.serverID)
		message := len(event.message) > 0 ? event.message : common.REGISTRATION_PENDING_MESSAGE
		ServerConnection_setSignUp(connection, .Pending, message)
		connection.signUpRequestStatus = .Pending
		State_wipeSignUpFormFor(state, event.serverID)
	case .Refused:
		// The code stays, so the user can fix it. A pending request stays pending: the
		// refusal is then the server ending the session ("Sign-up took too long").
		connection := State_serverConnection(state, event.serverID)
		if connection.signUp != .Pending {
			ServerConnection_setSignUp(connection, .Refused, event.message)
		}
	case .Declined:
		message := strings.clone(event.message, context.temp_allocator)
		State_connectionFailed(state, event)
		connection := State_serverConnection(state, event.serverID)
		ServerConnection_setSignUp(connection, .Declined, message)
		connection.signUpRequestStatus = .Declined
		State_wipeSignUpFormFor(state, event.serverID)
	case .Created:
	// Created arrives as Connected (registered set).
	}
}

// Called from State_connectionEstablished and State_connectionFailed: what the connection
// change means for the sign-up screen.
State_registrationConnectionChanged :: proc(state: ^State, event: ^ClientTransportRuntimeEvent) {
	connection := State_serverConnection(state, event.serverID)
	#partial switch event.kind {
	case .Connected:
		connection.registrationMode = event.registrationMode
		connection.isRestricted = event.isRestricted
		connection.signUpRequestStatus = .None
		ServerConnection_setSignUp(connection, .None, "")
		State_wipeSignUpFormFor(state, event.serverID)
		if event.registered {
			State_setChatStatus(state, "Welcome! Your account on this server was created.")
		}
	case .ConnectFailed, .SessionEnded, .RegistrationResult:
		#partial switch connection.failureKind {
		case .RegistrationPending:
			ServerConnection_setSignUp(connection, .Pending, common.REGISTRATION_PENDING_MESSAGE)
		case .RegistrationRequired:
			ServerConnection_setSignUp(connection, .Ended, connection.detail)
			State_wipeSignUpFormFor(state, event.serverID)
		case .RegistrationDeclined:
			ServerConnection_setSignUp(connection, .Declined, connection.detail)
			State_wipeSignUpFormFor(state, event.serverID)
		case:
		// Check again or Start again could not reach the server: the screen stays, with
		// the reason (buildSignUpView), and the banner's retry still runs.
		}
	case .Disconnected:
		if connection.signUp != .None {
			ServerConnection_setSignUp(connection, .None, "")
			State_wipeSignUpFormFor(state, event.serverID)
		}
	}
}

// Wipes the form when it belongs to serverID.
State_wipeSignUpFormFor :: proc(state: ^State, serverID: int) {
	if state.signUpForm.serverID == serverID {
		State_wipeSignUpForm(state)
	}
}

// Whether the selected server shows the sign-up screen instead of its rooms.
State_signUpVisible :: proc(state: ^State) -> bool {
	index := State_serverConnectionIndex(state^, state.selected_server_id)
	if index < 0 {
		return false
	}
	connection := state.serverConnections[index]
	// It stays up while Check again or Start again connects, until the server answers.
	return connection.signUp != .None && connection.status != .Established
}

// ── Administering ─────────────────────────────────────────────────

// The invite code shown once after it was created (D9): with its link (D19). Owned; the code
// and the link are wiped when they go.
CreatedInvite :: struct {
	invite: common.InviteSummary,
	code:   string,
	link:   string,
}

CreatedInvite_deinit :: proc(created: ^CreatedInvite) {
	common.InviteSummary_deinit(&created.invite)
	common.wipeAndDeleteString(&created.code)
	common.wipeAndDeleteString(&created.link)
	created^ = {}
}

// One server's invites and sign-up requests, for the Admin section.
ServerRegistrationCache :: struct {
	serverID:        int,
	invites:         [dynamic]common.InviteSummary,
	invitesLoaded:   bool,
	invitesLoading:  bool,
	requests:        [dynamic]common.RegistrationRequestSummary,
	requestsLoaded:  bool,
	requestsLoading: bool,
	// The server's pending count (D18), from ServerRegistrationRequests and every
	// ServerRegistrationRequestUpdated.
	pendingCount:    int,
	created:         CreatedInvite,
	createPending:   bool,
	// The refusal of the last create, owned.
	createError:     string,
}

@(private = "file")
ServerRegistrationCache_clearInvites :: proc(cache: ^ServerRegistrationCache) {
	for &invite in cache.invites {
		common.InviteSummary_deinit(&invite)
	}
	clear(&cache.invites)
}

@(private = "file")
ServerRegistrationCache_clearRequests :: proc(cache: ^ServerRegistrationCache) {
	for &request in cache.requests {
		common.RegistrationRequestSummary_deinit(&request)
	}
	clear(&cache.requests)
}

ServerRegistrationCache_deinit :: proc(cache: ^ServerRegistrationCache) {
	ServerRegistrationCache_clearInvites(cache)
	delete(cache.invites)
	ServerRegistrationCache_clearRequests(cache)
	delete(cache.requests)
	CreatedInvite_deinit(&cache.created)
	delete(cache.createError)
	cache^ = {}
}

State_serverRegistrationCacheIndex :: proc(state: ^State, serverID: int) -> int {
	for cache, index in state.serverRegistrations {
		if cache.serverID == serverID {
			return index
		}
	}
	return -1
}

// The server's cache, created when missing. Valid until the next cache is added or removed.
State_serverRegistrationCache :: proc(state: ^State, serverID: int) -> ^ServerRegistrationCache {
	if index := State_serverRegistrationCacheIndex(state, serverID); index >= 0 {
		return &state.serverRegistrations[index]
	}
	append(&state.serverRegistrations, ServerRegistrationCache{serverID = serverID})
	return &state.serverRegistrations[len(state.serverRegistrations) - 1]
}

State_deinitRegistration :: proc(state: ^State) {
	for &cache in state.serverRegistrations {
		ServerRegistrationCache_deinit(&cache)
	}
	delete(state.serverRegistrations)
	state.serverRegistrations = nil
	SignUpForm_deinit(&state.signUpForm)
	InviteForm_deinit(&state.inviteForm)
	DecisionForm_deinit(&state.decisionForm)
	State_deinitPendingLink(state)
}

// The D18 badge: pending sign-up requests on serverID, for approvers only (0 otherwise).
State_pendingRegistrationCount :: proc(state: ^State, serverID: int) -> int {
	if !State_hasPermission(state, serverID, .ApproveRegistrations) {
		return 0
	}
	index := State_serverRegistrationCacheIndex(state, serverID)
	if index < 0 {
		return 0
	}
	return max(0, state.serverRegistrations[index].pendingCount)
}

// The server's registration mode as this session last heard it (0 before sign-in).
State_registrationMode :: proc(state: ^State, serverID: int) -> common.RegistrationMode {
	index := State_serverConnectionIndex(state^, serverID)
	if index < 0 {
		return {}
	}
	return state.serverConnections[index].registrationMode
}

// Asks for the sign-up requests (approvers). includeDecided also lists decided ones.
State_requestRegistrationRequests :: proc(
	state: ^State,
	serverID: int,
	includeDecided := false,
) -> string {
	if !State_hasPermission(state, serverID, .ApproveRegistrations) {
		return common.REGISTRATION_APPROVER_REQUIRED_MESSAGE
	}
	errorMessage := State_sendRegistrationRequest(
		state,
		serverID,
		RegistrationRequest{kind = .ListRequests, includeDecided = includeDecided},
	)
	if len(errorMessage) == 0 {
		State_serverRegistrationCache(state, serverID).requestsLoading = true
	}
	return errorMessage
}

// Asks for the invite codes this account may see (inviters: their own; admins: every one).
State_requestInvites :: proc(state: ^State, serverID: int) -> string {
	if !State_hasPermission(state, serverID, .CreateInvites) {
		return common.INVITE_NOT_PERMITTED_MESSAGE
	}
	errorMessage := State_sendRegistrationRequest(
		state,
		serverID,
		RegistrationRequest{kind = .ListInvites},
	)
	if len(errorMessage) == 0 {
		State_serverRegistrationCache(state, serverID).invitesLoading = true
	}
	return errorMessage
}

// A new session: the badge count is fetched again for approvers (D18), the lists on demand.
State_registrationConnected :: proc(state: ^State, serverID: int) {
	cache := State_serverRegistrationCache(state, serverID)
	cache.invitesLoading = false
	cache.requestsLoading = false
	cache.invitesLoaded = false
	cache.requestsLoaded = false
	cache.createPending = false
	if State_hasPermission(state, serverID, .ApproveRegistrations) {
		State_requestRegistrationRequests(state, serverID)
	} else {
		cache.pendingCount = 0
	}
}

// Requests in flight died with the session.
State_registrationConnectionReset :: proc(state: ^State, serverID: int) {
	index := State_serverRegistrationCacheIndex(state, serverID)
	if index < 0 {
		return
	}
	cache := &state.serverRegistrations[index]
	cache.invitesLoading = false
	cache.requestsLoading = false
	if cache.createPending {
		cache.createPending = false
		delete(cache.createError)
		cache.createError = strings.clone(
			"The connection dropped before the server answered. Try again.",
		)
	}
}

// ServerAccountUpdated: the account's permissions or restriction changed.
State_registrationAccountUpdated :: proc(
	state: ^State,
	serverID: int,
	hadApprove, hadInvites: bool,
) {
	approves := State_hasPermission(state, serverID, .ApproveRegistrations)
	invites := State_hasPermission(state, serverID, .CreateInvites)
	cache := State_serverRegistrationCache(state, serverID)
	if approves && !hadApprove {
		State_requestRegistrationRequests(state, serverID)
	}
	if !approves && hadApprove {
		ServerRegistrationCache_clearRequests(cache)
		cache.requestsLoaded = false
		cache.pendingCount = 0
	}
	if !invites && hadInvites {
		ServerRegistrationCache_clearInvites(cache)
		cache.invitesLoaded = false
		CreatedInvite_deinit(&cache.created)
	}
}

// ServerRegistrationMode: takes nothing.
State_registrationModeChanged :: proc(
	state: ^State,
	serverID: int,
	mode: common.RegistrationMode,
) {
	if index := State_serverConnectionIndex(state^, serverID); index >= 0 {
		state.serverConnections[index].registrationMode = mode
	}
}

// ServerInviteList: takes ownership of invites.
State_receiveInviteList :: proc(
	state: ^State,
	serverID: int,
	invites: ^[dynamic]common.InviteSummary,
) {
	if State_selectedTransportIndexForServerID(state^, serverID) < 0 {
		return
	}
	cache := State_serverRegistrationCache(state, serverID)
	ServerRegistrationCache_clearInvites(cache)
	delete(cache.invites)
	cache.invites = invites^
	invites^ = nil
	cache.invitesLoaded = true
	cache.invitesLoading = false
}

// ServerInviteCreated: the code is shown once with its link and Copy buttons. Takes ownership
// of the invite and the code.
State_inviteCreated :: proc(state: ^State, event: ^ClientTransportRuntimeEvent) {
	serverID := event.serverID
	server, ok := State_serverConfig(state, serverID)
	if !ok {
		return
	}
	cache := State_serverRegistrationCache(state, serverID)
	CreatedInvite_deinit(&cache.created)
	cache.created.code = event.inviteCode
	event.inviteCode = ""
	cache.created.link = buildInviteLink(
		server.host,
		server.port,
		cache.created.code,
		server.pinned_server_public_key,
	)
	// The list gets its own copy, newest first.
	listed := InviteSummary_clone(event.invite)
	inject_at(&cache.invites, 0, listed)
	cache.created.invite = event.invite
	event.invite = {}
	cache.createPending = false
	delete(cache.createError)
	cache.createError = ""
	State_closeInviteForm(state)
}

InviteSummary_clone :: proc(
	invite: common.InviteSummary,
	allocator := context.allocator,
) -> common.InviteSummary {
	copy := invite
	copy.note = strings.clone(invite.note, allocator)
	copy.createdByNickname = strings.clone(invite.createdByNickname, allocator)
	copy.createdAt = strings.clone(invite.createdAt, allocator)
	copy.expiresAt = strings.clone(invite.expiresAt, allocator)
	copy.roleIds = slice.clone_to_dynamic(invite.roleIds[:], allocator)
	return copy
}

// Done: forgets the code shown once (D9). It cannot be shown again.
State_dismissCreatedInvite :: proc(state: ^State, serverID: int) {
	if index := State_serverRegistrationCacheIndex(state, serverID); index >= 0 {
		CreatedInvite_deinit(&state.serverRegistrations[index].created)
	}
}

// ServerRegistrationRequests: takes ownership of the requests.
State_receiveRegistrationRequests :: proc(
	state: ^State,
	serverID: int,
	requests: ^[dynamic]common.RegistrationRequestSummary,
	pendingCount: int,
) {
	if State_selectedTransportIndexForServerID(state^, serverID) < 0 {
		return
	}
	cache := State_serverRegistrationCache(state, serverID)
	ServerRegistrationCache_clearRequests(cache)
	delete(cache.requests)
	cache.requests = requests^
	requests^ = nil
	cache.requestsLoaded = true
	cache.requestsLoading = false
	cache.pendingCount = pendingCount
}

// ServerRegistrationRequestUpdated: a request was made or decided. Takes ownership of it.
State_registrationRequestUpdated :: proc(
	state: ^State,
	serverID: int,
	request: ^common.RegistrationRequestSummary,
	pendingCount: int,
) {
	if State_selectedTransportIndexForServerID(state^, serverID) < 0 {
		return
	}
	cache := State_serverRegistrationCache(state, serverID)
	cache.pendingCount = pendingCount
	for &known in cache.requests {
		if known.id == request.id {
			common.RegistrationRequestSummary_deinit(&known)
			known = request^
			request^ = {}
			return
		}
	}
	append(&cache.requests, request^)
	request^ = {}
}

// ServerAdminActionResult for a registration action: a revoked code shows as revoked at once.
State_registrationAdminResult :: proc(
	state: ^State,
	serverID: int,
	action: common.AdminAction,
	inviteID, requestID: int,
) {
	#partial switch action {
	case .RevokeInvite:
		if index := State_serverRegistrationCacheIndex(state, serverID); index >= 0 {
			for &invite in state.serverRegistrations[index].invites {
				if invite.id == inviteID {
					invite.revoked = true
				}
			}
		}
	case .DecideRegistration:
		if state.decisionForm.requestID == requestID {
			DecisionForm_close(&state.decisionForm)
		}
	}
}

// A protocol error while an invite creation is pending is its refusal.
State_registrationProtocolError :: proc(state: ^State, serverID: int, message: string) {
	index := State_serverRegistrationCacheIndex(state, serverID)
	if index >= 0 && state.serverRegistrations[index].createPending {
		cache := &state.serverRegistrations[index]
		cache.createPending = false
		delete(cache.createError)
		cache.createError = strings.clone(
			len(message) > 0 ? message : "The server refused the request.",
		)
	}
	// A refused sign-up request (a registering session's protocol error) ends Submitting.
	if connectionIndex := State_serverConnectionIndex(state^, serverID); connectionIndex >= 0 {
		connection := &state.serverConnections[connectionIndex]
		if connection.status == .Registering && connection.signUp == .Submitting {
			ServerConnection_setSignUp(connection, .Refused, message)
		}
	}
}

// Admin actions (admin.odin): their answers are the Admin section's status.
State_setRegistrationMode :: proc(
	state: ^State,
	serverID: int,
	mode: common.RegistrationMode,
) -> string {
	return State_sendAdminRequest(
		state,
		serverID,
		AdminRequest{action = .SetRegistrationMode, mode = mode},
	)
}

State_revokeInvite :: proc(state: ^State, serverID, inviteID: int) -> string {
	return State_sendAdminRequest(
		state,
		serverID,
		AdminRequest{action = .RevokeInvite, inviteID = inviteID},
	)
}

State_decideRegistration :: proc(
	state: ^State,
	serverID, requestID: int,
	approve: bool,
	reason: string,
) -> string {
	return State_sendAdminRequest(
		state,
		serverID,
		AdminRequest {
			action = .DecideRegistration,
			requestID = requestID,
			flag = approve,
			reason = reason,
		},
	)
}

State_setRestricted :: proc(state: ^State, serverID, userID: int, restricted: bool) -> string {
	return State_sendAdminRequest(
		state,
		serverID,
		AdminRequest{action = .SetRestricted, userID = userID, flag = restricted},
	)
}

// ── The invite form ───────────────────────────────────────────────

// Expiry choices in seconds, 0 for never (admins only, D10).
INVITE_EXPIRY_CHOICES := [?]int{60 * 60, 24 * 60 * 60, 7 * 24 * 60 * 60, 30 * 24 * 60 * 60, 0}
INVITE_EXPIRY_LABELS := [?]string{"1 hour", "1 day", "7 days", "30 days", "Never"}
// Use limits, 0 for none.
INVITE_USES_CHOICES := [?]int{1, 5, 25, 100, 0}
INVITE_USES_LABELS := [?]string{"1 use", "5 uses", "25 uses", "100 uses", "No limit"}
// The default choices: one day, one use.
INVITE_EXPIRY_DEFAULT :: 1
INVITE_USES_DEFAULT :: 0

// The Admin section's New invite form.
InviteForm :: struct {
	open:         bool,
	serverID:     int,
	note:         [dynamic]u8,
	expiryIndex:  int,
	usesIndex:    int,
	// Admins only: roles the code grants, the room it restricts to, and skip approval.
	roleIDs:      [common.SERVER_ROLES_MAX]int,
	roleIDCount:  int,
	roomID:       int,
	skipApproval: bool,
	// A local check that kept the request from going out. Owned.
	error:        string,
}

InviteForm_deinit :: proc(form: ^InviteForm) {
	delete(form.note)
	delete(form.error)
	form^ = {}
}

State_openInviteForm :: proc(state: ^State, serverID: int) {
	form := &state.inviteForm
	InviteForm_deinit(form)
	form.open = true
	form.serverID = serverID
	form.expiryIndex = INVITE_EXPIRY_DEFAULT
	form.usesIndex = INVITE_USES_DEFAULT
}

State_closeInviteForm :: proc(state: ^State) {
	InviteForm_deinit(&state.inviteForm)
}

// Whether an expiry choice is allowed: non-admins must expire within 7 days (D10).
inviteExpiryAllowed :: proc(index: int, isAdmin: bool) -> bool {
	if index < 0 || index >= len(INVITE_EXPIRY_CHOICES) {
		return false
	}
	seconds := INVITE_EXPIRY_CHOICES[index]
	if isAdmin {
		return true
	}
	return seconds > 0 && seconds <= common.INVITE_INVITER_EXPIRY_MAX_SECONDS
}

State_setInviteFormExpiry :: proc(state: ^State, index: int) {
	form := &state.inviteForm
	if inviteExpiryAllowed(index, State_isServerAdmin(state, form.serverID)) {
		form.expiryIndex = index
	}
}

State_setInviteFormUses :: proc(state: ^State, index: int) {
	if index >= 0 && index < len(INVITE_USES_CHOICES) {
		state.inviteForm.usesIndex = index
	}
}

State_toggleInviteFormRole :: proc(state: ^State, roleID: int) {
	form := &state.inviteForm
	for index in 0 ..< form.roleIDCount {
		if form.roleIDs[index] == roleID {
			copy(form.roleIDs[index:form.roleIDCount], form.roleIDs[index + 1:form.roleIDCount])
			form.roleIDCount -= 1
			return
		}
	}
	if form.roleIDCount < len(form.roleIDs) {
		form.roleIDs[form.roleIDCount] = roleID
		form.roleIDCount += 1
	}
}

inviteFormHasRole :: proc(form: InviteForm, roleID: int) -> bool {
	form := form
	return slice.contains(form.roleIDs[:form.roleIDCount], roleID)
}

// Picks the room a code restricts its accounts to (0 for none). Admins only.
State_setInviteFormRoom :: proc(state: ^State, roomID: int) {
	state.inviteForm.roomID = state.inviteForm.roomID == roomID ? 0 : roomID
}

State_toggleInviteFormSkipApproval :: proc(state: ^State) {
	state.inviteForm.skipApproval = !state.inviteForm.skipApproval
}

// Builds the ClientCreateInvite of the form. Admin-only fields are dropped for others, so a
// non-admin never sends what the server refuses (D10).
inviteFormRequest :: proc(form: InviteForm, isAdmin: bool) -> RegistrationRequest {
	request := RegistrationRequest {
		kind = .CreateInvite,
		note = strings.trim_space(string(form.note[:])),
	}
	if form.expiryIndex >= 0 && form.expiryIndex < len(INVITE_EXPIRY_CHOICES) {
		request.expiresInSeconds = INVITE_EXPIRY_CHOICES[form.expiryIndex]
	}
	if form.usesIndex >= 0 && form.usesIndex < len(INVITE_USES_CHOICES) {
		request.maxUses = INVITE_USES_CHOICES[form.usesIndex]
	}
	if isAdmin {
		request.roleIDs = form.roleIDs
		request.roleIDCount = form.roleIDCount
		request.roomID = form.roomID
		request.skipApproval = form.skipApproval
	}
	return request
}

// Checks an invite request the way the server will. Returns "" when it may go out.
validateInviteRequest :: proc(request: RegistrationRequest, isAdmin: bool) -> string {
	if !common.registrationTextIsValid(request.note, 0, common.INVITE_NOTE_MAX_BYTES) ||
	   len(request.note) > common.INVITE_NOTE_MAX_BYTES {
		return "The note must be at most 200 bytes on one line."
	}
	if strings.contains_any(request.note, "\n") {
		return "The note must be at most 200 bytes on one line."
	}
	if !isAdmin {
		if request.expiresInSeconds <= 0 ||
		   request.expiresInSeconds > common.INVITE_INVITER_EXPIRY_MAX_SECONDS {
			return common.INVITE_EXPIRY_REQUIRED_MESSAGE
		}
		if request.roleIDCount > 0 || request.roomID != 0 || request.skipApproval {
			return common.INVITE_ADMIN_REQUIRED_MESSAGE
		}
	}
	if request.expiresInSeconds < 0 ||
	   request.expiresInSeconds > common.INVITE_EXPIRY_MAX_SECONDS ||
	   request.maxUses < 0 ||
	   request.maxUses > common.INVITE_MAX_USES {
		return common.INVITE_INVALID_REQUEST_MESSAGE
	}
	return ""
}

// Creates a code from the form, or from a request the harness built. Returns "" when it went
// out; the answer is ServerInviteCreated or a refusal in the cache's createError.
State_createInvite :: proc(state: ^State, serverID: int, request: RegistrationRequest) -> string {
	if !State_hasPermission(state, serverID, .CreateInvites) {
		return common.INVITE_NOT_PERMITTED_MESSAGE
	}
	request := request
	request.kind = .CreateInvite
	isAdmin := State_isServerAdmin(state, serverID)
	if errorMessage := validateInviteRequest(request, isAdmin); len(errorMessage) > 0 {
		return errorMessage
	}
	errorMessage := State_sendRegistrationRequest(state, serverID, request)
	if len(errorMessage) > 0 {
		return errorMessage
	}
	cache := State_serverRegistrationCache(state, serverID)
	cache.createPending = true
	delete(cache.createError)
	cache.createError = ""
	return ""
}

// Create in the invite form.
State_submitInviteForm :: proc(state: ^State) -> string {
	form := &state.inviteForm
	if !form.open {
		return ""
	}
	request := inviteFormRequest(form^, State_isServerAdmin(state, form.serverID))
	errorMessage := State_createInvite(state, form.serverID, request)
	delete(form.error)
	form.error = strings.clone(errorMessage)
	return errorMessage
}

// ── Decline with a reason ─────────────────────────────────────────

// The reason field under one sign-up request, for Decline… (and an optional note on Approve).
DecisionForm :: struct {
	requestID: int,
	reason:    [dynamic]u8,
}

DecisionForm_deinit :: proc(form: ^DecisionForm) {
	delete(form.reason)
	form^ = {}
}

DecisionForm_close :: proc(form: ^DecisionForm) {
	clear(&form.reason)
	form.requestID = 0
}

State_openDecisionForm :: proc(state: ^State, requestID: int) {
	form := &state.decisionForm
	if form.requestID != requestID {
		clear(&form.reason)
	}
	form.requestID = requestID
}

// Decline in the open reason field.
State_submitDecline :: proc(state: ^State, serverID: int) -> string {
	form := &state.decisionForm
	if form.requestID == 0 {
		return "No sign-up request selected."
	}
	return State_decideRegistration(
		state,
		serverID,
		form.requestID,
		false,
		string(form.reason[:]),
	)
}

// ── Links ─────────────────────────────────────────────────────────

// haychat://host:port/invite/CODE?key=SERVER_PUBLIC_KEY_HEX (D19), in allocator. An IPv6 host
// is put in brackets. The code is the one the server sent (grouped with dashes).
buildInviteLink :: proc(
	host: string,
	port: i32,
	code, serverKeyHex: string,
	allocator := context.allocator,
) -> string {
	hostText := host
	if strings.contains_rune(host, ':') {
		hostText = fmt.tprintf("[%s]", host)
	}
	return fmt.aprintf(
		"%s%s:%d/%s/%s?key=%s",
		HAYCHAT_LINK_SCHEME,
		hostText,
		port,
		HAYCHAT_LINK_INVITE_PATH,
		code,
		serverKeyHex,
		allocator = allocator,
	)
}

// Server settings opened: the invite codes and sign-up requests this account may see.
State_registrationSettingsOpened :: proc(state: ^State, serverID: int) {
	if State_hasPermission(state, serverID, .CreateInvites) {
		State_requestInvites(state, serverID)
	}
	if State_hasPermission(state, serverID, .ApproveRegistrations) {
		State_requestRegistrationRequests(state, serverID)
	}
}

// Server settings closed: the invite form and the decline reason go, and so does a code shown
// once (D9).
State_registrationSettingsClosed :: proc(state: ^State) {
	if state.inviteForm.open {
		State_dismissCreatedInvite(state, state.inviteForm.serverID)
	}
	for &cache in state.serverRegistrations {
		CreatedInvite_deinit(&cache.created)
	}
	State_closeInviteForm(state)
	DecisionForm_close(&state.decisionForm)
}

// Use an invite code (Server settings): sets registering for this server's next connections
// and saves it (Server.use_invite_code). It changes nothing for a key with an account.
State_setUseInviteCode :: proc(state: ^State, serverID: int, on: bool) {
	server, ok := State_serverConfig(state, serverID)
	if !ok || server.use_invite_code == on {
		return
	}
	server.use_invite_code = on
	State_saveConfig(state)
	if transportIndex := State_selectedTransportIndexForServerID(state^, serverID);
	   transportIndex >= 0 {
		ClientNetworkWorker_lock(state.networkWorker)
		ClientServerTransport_setRegistering(&state.serverTransports[transportIndex], on)
		ClientNetworkWorker_unlock(state.networkWorker)
	}
}
