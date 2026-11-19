package client

import "../common"
import "core:strings"

// Registration in the headless harness (protocol 25, #43 G2, registration.odin). Like the
// other admin commands, the harness checks only what the GUI cannot send at all, so an agent
// sees the server refuse (protocol_error).
//
// Signing up:
// - `--register` makes startup connect with ClientAuthRequestPayload.registering set (Use an
//   invite code), and `--invite-code CODE [--reason TEXT]` also sends that code (and reason)
//   as soon as registration_required arrives (implies --register). Startup then ends once the
//   session is connected, or registering (after the first registration_result when a code was
//   given), so a script can `wait registration_result` or `wait connected`.
// - register CODE|- [REASON...]: one ClientRegister in the registering session (- for no code,
//   which only an Open server accepts). Answered by registration_result, or by connected (with
//   registered true, after a registration_result created) when the account was made.
// - Events: registration_required {mode, status, message}; registration_result {status
//   created|pending|refused|declined, message, userID}; registration_mode {mode}.
//
// Administering:
// - invite-create OPTIONS [NOTE...]: OPTIONS is `-` or a comma list of expires=SECONDS (0
//   never, admins), uses=N (0 no limit), roles=ID+ID, room=ID and skip-approval. Defaults:
//   one day, one use. Answered by invite_created {invite, code, link}, the only time the code
//   is shown.
// - invite-list, invite-revoke ID; registration-list [all], registration-decide ID
//   approve|decline [REASON...]; registration-mode open|invite|approval; restrict USER_ID
//   on|off. Lists answer with the cache and ask for it (invite_list, registration_requests);
//   the others with admin_result. registration_request is ServerRegistrationRequestUpdated
//   {request, pendingCount}; `status` carries pendingRegistrations, the approver badge.
//
// Links (D19): link-open URL shows what the confirmation would (link_pending: kind, server,
// match, error; the code is never printed), link-confirm follows it, link-cancel drops it.

HEADLESS_SIGN_UP_PHASE_NAMES := [SignUpPhase]string {
	.None       = "none",
	.Required   = "required",
	.Submitting = "submitting",
	.Pending    = "pending",
	.Refused    = "refused",
	.Declined   = "declined",
	.Ended      = "ended",
}

HEADLESS_REGISTER_STATUS_NAMES := [common.RegisterStatus]string {
	.Created  = "created",
	.Pending  = "pending",
	.Refused  = "refused",
	.Declined = "declined",
}

HEADLESS_REQUEST_STATUS_NAMES := [common.RegistrationRequestStatus]string {
	.None     = "none",
	.Pending  = "pending",
	.Approved = "approved",
	.Declined = "declined",
}

HEADLESS_LINK_MATCH_NAMES := [LinkServerMatch]string {
	.NewServer  = "new_server",
	.Pinned     = "pinned",
	.Unpinned   = "unpinned",
	.KeyDiffers = "key_differs",
}

headlessRegistrationModeName :: proc(mode: common.RegistrationMode) -> string {
	switch mode {
	case .Open:
		return "open"
	case .InviteOnly:
		return "invite"
	case .InviteApproval:
		return "approval"
	}
	return ""
}

headlessParseRegistrationMode :: proc(word: string) -> (common.RegistrationMode, bool) {
	switch word {
	case "open":
		return .Open, true
	case "invite":
		return .InviteOnly, true
	case "approval":
		return .InviteApproval, true
	}
	return {}, false
}

HeadlessInviteJSON :: struct {
	id:                int,
	note:              string,
	createdBy:         int,
	createdByNickname: string,
	createdAt:         string,
	expiresAt:         string,
	maxUses:           int,
	uses:              int,
	revoked:           bool,
	roleIds:           []int,
	roomId:            int,
	restricted:        bool,
	skipApproval:      bool,
}

headlessInvite :: proc(invite: common.InviteSummary) -> HeadlessInviteJSON {
	return HeadlessInviteJSON {
		id = invite.id,
		note = invite.note,
		createdBy = invite.createdBy,
		createdByNickname = invite.createdByNickname,
		createdAt = invite.createdAt,
		expiresAt = invite.expiresAt,
		maxUses = invite.maxUses,
		uses = invite.uses,
		revoked = invite.revoked,
		roleIds = invite.roleIds[:],
		roomId = invite.roomId,
		restricted = invite.restricted,
		skipApproval = invite.skipApproval,
	}
}

headlessInvites :: proc(
	invites: []common.InviteSummary,
	allocator := context.temp_allocator,
) -> []HeadlessInviteJSON {
	rows := make([]HeadlessInviteJSON, len(invites), allocator)
	for invite, index in invites {
		rows[index] = headlessInvite(invite)
	}
	return rows
}

HeadlessRegistrationRequestJSON :: struct {
	id:                int,
	nickname:          string,
	reason:            string,
	status:            string,
	identityPublicKey: string,
	inviteId:          int,
	inviteNote:        string,
	inviteCreatedBy:   int,
	createdAt:         string,
	decidedBy:         int,
	decidedAt:         string,
	decisionReason:    string,
}

headlessRegistrationRequest :: proc(
	request: common.RegistrationRequestSummary,
	allocator := context.temp_allocator,
) -> HeadlessRegistrationRequestJSON {
	key := request.identityPublicKey
	return HeadlessRegistrationRequestJSON {
		id = request.id,
		nickname = request.nickname,
		reason = request.reason,
		status = HEADLESS_REQUEST_STATUS_NAMES[request.status],
		identityPublicKey = headlessHex(key[:], allocator),
		inviteId = request.inviteId,
		inviteNote = request.inviteNote,
		inviteCreatedBy = request.inviteCreatedBy,
		createdAt = request.createdAt,
		decidedBy = request.decidedBy,
		decidedAt = request.decidedAt,
		decisionReason = request.decisionReason,
	}
}

headlessRegistrationRequests :: proc(
	requests: []common.RegistrationRequestSummary,
	allocator := context.temp_allocator,
) -> []HeadlessRegistrationRequestJSON {
	rows := make([]HeadlessRegistrationRequestJSON, len(requests), allocator)
	for request, index in requests {
		rows[index] = headlessRegistrationRequest(request, allocator)
	}
	return rows
}

HeadlessRegistrationRequiredJSON :: struct {
	event:    string,
	serverID: int,
	mode:     string,
	status:   string,
	message:  string,
}

HeadlessRegistrationResultJSON :: struct {
	event:    string,
	serverID: int,
	status:   string,
	message:  string,
	userID:   int,
}

HeadlessRegistrationModeJSON :: struct {
	event:    string,
	serverID: int,
	mode:     string,
}

HeadlessInviteCreatedJSON :: struct {
	event:    string,
	serverID: int,
	invite:   HeadlessInviteJSON,
	code:     string,
	link:     string,
}

HeadlessInviteListJSON :: struct {
	event:    string,
	serverID: int,
	invites:  []HeadlessInviteJSON,
}

HeadlessRegistrationRequestsJSON :: struct {
	event:        string,
	serverID:     int,
	pendingCount: int,
	requests:     []HeadlessRegistrationRequestJSON,
}

HeadlessRegistrationRequestUpdatedJSON :: struct {
	event:        string,
	serverID:     int,
	pendingCount: int,
	request:      HeadlessRegistrationRequestJSON,
}

// The registration events' lines; ok false for other kinds.
headlessRenderRegistrationEvent :: proc(
	event: ^ClientTransportRuntimeEvent,
	info: HeadlessRenderInfo,
	allocator := context.allocator,
) -> (
	line: string,
	kind: HeadlessEventKind,
	ok: bool,
) {
	#partial switch event.kind {
	case .RegistrationRequired:
		kind = .RegistrationRequired
		line = headlessMarshal(
			HeadlessRegistrationRequiredJSON {
				event = HEADLESS_EVENT_NAMES[kind],
				serverID = event.serverID,
				mode = headlessRegistrationModeName(event.registrationMode),
				status = HEADLESS_REQUEST_STATUS_NAMES[event.registrationRequestStatus],
				message = event.message,
			},
			allocator,
		)
		return line, kind, true
	case .RegistrationResult:
		kind = .RegistrationResult
		line = headlessMarshal(
			HeadlessRegistrationResultJSON {
				event = HEADLESS_EVENT_NAMES[kind],
				serverID = event.serverID,
				status = HEADLESS_REGISTER_STATUS_NAMES[event.registerStatus],
				message = event.message,
			},
			allocator,
		)
		return line, kind, true
	case .RegistrationModeChanged:
		kind = .RegistrationMode
		line = headlessMarshal(
			HeadlessRegistrationModeJSON {
				event = HEADLESS_EVENT_NAMES[kind],
				serverID = event.serverID,
				mode = headlessRegistrationModeName(event.registrationMode),
			},
			allocator,
		)
		return line, kind, true
	case .InviteCreated:
		kind = .InviteCreated
		link := ""
		if info.state != nil {
			if server, serverOK := State_serverConfig(info.state, event.serverID); serverOK {
				link = buildInviteLink(
					server.host,
					server.port,
					event.inviteCode,
					server.pinned_server_public_key,
					context.temp_allocator,
				)
			}
		}
		line = headlessMarshal(
			HeadlessInviteCreatedJSON {
				event = HEADLESS_EVENT_NAMES[kind],
				serverID = event.serverID,
				invite = headlessInvite(event.invite),
				code = event.inviteCode,
				link = link,
			},
			allocator,
		)
		return line, kind, true
	case .InviteList:
		kind = .InviteList
		line = headlessMarshal(
			HeadlessInviteListJSON {
				event = HEADLESS_EVENT_NAMES[kind],
				serverID = event.serverID,
				invites = headlessInvites(event.invites[:]),
			},
			allocator,
		)
		return line, kind, true
	case .RegistrationRequests:
		kind = .RegistrationRequests
		line = headlessMarshal(
			HeadlessRegistrationRequestsJSON {
				event = HEADLESS_EVENT_NAMES[kind],
				serverID = event.serverID,
				pendingCount = event.pendingCount,
				requests = headlessRegistrationRequests(event.registrationRequests[:]),
			},
			allocator,
		)
		return line, kind, true
	case .RegistrationRequestUpdated:
		kind = .RegistrationRequest
		line = headlessMarshal(
			HeadlessRegistrationRequestUpdatedJSON {
				event = HEADLESS_EVENT_NAMES[kind],
				serverID = event.serverID,
				pendingCount = event.pendingCount,
				request = headlessRegistrationRequest(event.registrationRequest),
			},
			allocator,
		)
		return line, kind, true
	}
	return "", {}, false
}

// Before a Connected from a sign-up, a registration_result created line.
headlessWriteRegistrationCreated :: proc(harness: ^HeadlessHarness, event: ^ClientTransportRuntimeEvent) {
	headlessWriteJSON(
		harness,
		HeadlessRegistrationResultJSON {
			event = HEADLESS_EVENT_NAMES[.RegistrationResult],
			serverID = event.serverID,
			status = HEADLESS_REGISTER_STATUS_NAMES[.Created],
			userID = event.userID,
		},
	)
	headlessRecordEvent(harness, .RegistrationResult)
}

// --invite-code: the code goes out once, when the first registration_required arrives.
headlessAutoRegister :: proc(harness: ^HeadlessHarness, event: ^ClientTransportRuntimeEvent) {
	if len(harness.autoInviteCode) == 0 || harness.autoRegisterSent ||
	   event.registrationRequestStatus == .Pending {
		return
	}
	harness.autoRegisterSent = true
	state := &harness.state
	code := harness.autoInviteCode == "-" ? "" : harness.autoInviteCode
	State_prefillSignUpCode(state, event.serverID, code)
	form := State_signUpFormFor(state, event.serverID)
	clear(&form.reason)
	append(&form.reason, harness.autoReason)
	if errorMessage := State_submitSignUp(state, event.serverID); len(errorMessage) > 0 {
		headlessWriteError(harness, "register", errorMessage)
		// Nothing will answer; startup stops waiting.
		harness.autoRegisterAnswered = true
	}
}

HeadlessRegisterJSON :: struct {
	ok:       bool,
	cmd:      string,
	serverID: int,
}

headlessCommandRegister :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	state := &harness.state
	serverID := state.selected_server_id
	code := command.args[0] == "-" ? "" : command.args[0]
	State_prefillSignUpCode(state, serverID, code)
	form := State_signUpFormFor(state, serverID)
	clear(&form.reason)
	if command.argCount > 1 {
		append(&form.reason, command.args[1])
	}
	if errorMessage := State_submitSignUp(state, serverID); len(errorMessage) > 0 {
		headlessWriteError(harness, command.name, errorMessage)
		return
	}
	headlessWriteJSON(
		harness,
		HeadlessRegisterJSON{ok = true, cmd = command.name, serverID = serverID},
	)
}

@(private = "file")
headlessRegistrationUsage :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	usage := strings.concatenate({"usage: ", command.command.usage})
	defer delete(usage)
	headlessWriteError(harness, command.name, usage)
}

HeadlessRegistrationRequestJSONResult :: struct {
	ok:        bool,
	cmd:       string,
	serverID:  int,
	inviteID:  int,
	requestID: int,
	userID:    int,
}

@(private = "file")
headlessWriteRegistrationRequest :: proc(
	harness: ^HeadlessHarness,
	command: ^HeadlessParsedCommand,
	errorMessage: string,
	inviteID, requestID, userID: int,
) {
	if len(errorMessage) > 0 {
		headlessWriteError(harness, command.name, errorMessage)
		return
	}
	headlessWriteJSON(
		harness,
		HeadlessRegistrationRequestJSONResult {
			ok = true,
			cmd = command.name,
			serverID = harness.state.selected_server_id,
			inviteID = inviteID,
			requestID = requestID,
			userID = userID,
		},
	)
}

// Parses invite-create's OPTIONS (see the top of the file).
headlessParseInviteOptions :: proc(word: string) -> (request: RegistrationRequest, ok: bool) {
	request.kind = .CreateInvite
	request.expiresInSeconds = INVITE_EXPIRY_CHOICES[INVITE_EXPIRY_DEFAULT]
	request.maxUses = INVITE_USES_CHOICES[INVITE_USES_DEFAULT]
	if word == "-" || word == "default" {
		return request, true
	}
	remaining := word
	for option in strings.split_iterator(&remaining, ",") {
		name, value := option, ""
		if equals := strings.index_byte(option, '='); equals >= 0 {
			name = option[:equals]
			value = option[equals + 1:]
		}
		switch name {
		case "expires":
			seconds, secondsOK := headlessParseNumber(value, common.INVITE_EXPIRY_MAX_SECONDS)
			if !secondsOK {
				return {}, false
			}
			request.expiresInSeconds = seconds
		case "uses":
			uses, usesOK := headlessParseNumber(value, common.INVITE_MAX_USES)
			if !usesOK {
				return {}, false
			}
			request.maxUses = uses
		case "roles":
			ids := strings.split(value, "+", context.temp_allocator)
			for id in ids {
				roleID, roleOK := headlessParseNumber(id)
				if !roleOK || roleID <= 0 || request.roleIDCount >= len(request.roleIDs) {
					return {}, false
				}
				request.roleIDs[request.roleIDCount] = roleID
				request.roleIDCount += 1
			}
		case "room":
			roomID, roomOK := headlessParseNumber(value)
			if !roomOK || roomID <= 0 {
				return {}, false
			}
			request.roomID = roomID
		case "skip-approval":
			if len(value) > 0 {
				return {}, false
			}
			request.skipApproval = true
		case:
			return {}, false
		}
	}
	return request, true
}

headlessCommandInviteCreate :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	request, ok := headlessParseInviteOptions(command.args[0])
	if !ok {
		headlessRegistrationUsage(harness, command)
		return
	}
	if command.argCount > 1 {
		request.note = command.args[1]
	}
	state := &harness.state
	errorMessage := State_createInvite(state, state.selected_server_id, request)
	headlessWriteRegistrationRequest(harness, command, errorMessage, 0, 0, 0)
}

HeadlessInviteListResultJSON :: struct {
	ok:       bool,
	cmd:      string,
	serverID: int,
	loaded:   bool,
	invites:  []HeadlessInviteJSON,
}

headlessCommandInviteList :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	state := &harness.state
	serverID := state.selected_server_id
	if errorMessage := State_requestInvites(state, serverID); len(errorMessage) > 0 {
		headlessWriteError(harness, command.name, errorMessage)
		return
	}
	cache := State_serverRegistrationCache(state, serverID)
	headlessWriteJSON(
		harness,
		HeadlessInviteListResultJSON {
			ok = true,
			cmd = command.name,
			serverID = serverID,
			loaded = cache.invitesLoaded,
			invites = headlessInvites(cache.invites[:]),
		},
	)
}

headlessCommandInviteRevoke :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	inviteID, ok := headlessParseNumber(command.args[0])
	if !ok || inviteID <= 0 {
		headlessRegistrationUsage(harness, command)
		return
	}
	state := &harness.state
	errorMessage := State_revokeInvite(state, state.selected_server_id, inviteID)
	headlessWriteRegistrationRequest(harness, command, errorMessage, inviteID, 0, 0)
}

HeadlessRegistrationListResultJSON :: struct {
	ok:           bool,
	cmd:          string,
	serverID:     int,
	loaded:       bool,
	pendingCount: int,
	requests:     []HeadlessRegistrationRequestJSON,
}

headlessCommandRegistrationList :: proc(
	harness: ^HeadlessHarness,
	command: ^HeadlessParsedCommand,
) {
	includeDecided := false
	if command.argCount > 0 {
		if command.args[0] != "all" {
			headlessRegistrationUsage(harness, command)
			return
		}
		includeDecided = true
	}
	state := &harness.state
	serverID := state.selected_server_id
	if errorMessage := State_requestRegistrationRequests(state, serverID, includeDecided);
	   len(errorMessage) > 0 {
		headlessWriteError(harness, command.name, errorMessage)
		return
	}
	cache := State_serverRegistrationCache(state, serverID)
	headlessWriteJSON(
		harness,
		HeadlessRegistrationListResultJSON {
			ok = true,
			cmd = command.name,
			serverID = serverID,
			loaded = cache.requestsLoaded,
			pendingCount = State_pendingRegistrationCount(state, serverID),
			requests = headlessRegistrationRequests(cache.requests[:]),
		},
	)
}

headlessCommandRegistrationDecide :: proc(
	harness: ^HeadlessHarness,
	command: ^HeadlessParsedCommand,
) {
	requestID, ok := headlessParseNumber(command.args[0])
	approve := false
	switch command.args[1] {
	case "approve":
		approve = true
	case "decline":
	case:
		ok = false
	}
	if !ok || requestID <= 0 {
		headlessRegistrationUsage(harness, command)
		return
	}
	reason := command.argCount > 2 ? command.args[2] : ""
	state := &harness.state
	errorMessage := State_decideRegistration(
		state,
		state.selected_server_id,
		requestID,
		approve,
		reason,
	)
	headlessWriteRegistrationRequest(harness, command, errorMessage, 0, requestID, 0)
}

headlessCommandRegistrationMode :: proc(
	harness: ^HeadlessHarness,
	command: ^HeadlessParsedCommand,
) {
	mode, ok := headlessParseRegistrationMode(command.args[0])
	if !ok {
		headlessRegistrationUsage(harness, command)
		return
	}
	state := &harness.state
	errorMessage := State_setRegistrationMode(state, state.selected_server_id, mode)
	headlessWriteRegistrationRequest(harness, command, errorMessage, 0, 0, 0)
}

headlessCommandRestrict :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	userID, ok := headlessParseNumber(command.args[0])
	restricted := false
	switch command.args[1] {
	case "on":
		restricted = true
	case "off":
	case:
		ok = false
	}
	if !ok || userID <= 0 {
		headlessRegistrationUsage(harness, command)
		return
	}
	state := &harness.state
	errorMessage := State_setRestricted(state, state.selected_server_id, userID, restricted)
	headlessWriteRegistrationRequest(harness, command, errorMessage, 0, 0, userID)
}

// link_pending: what the confirmation shows. The code is never printed; hasCode says whether
// the link carries one.
HeadlessLinkPendingJSON :: struct {
	event:    string,
	open:     bool,
	kind:     string,
	server:   string,
	host:     string,
	port:     int,
	hasKey:   bool,
	hasCode:  bool,
	match:    string,
	serverID: int,
	error:    string,
}

headlessWriteLinkPending :: proc(harness: ^HeadlessHarness) {
	pending := &harness.state.pendingLink
	headlessWriteJSON(
		harness,
		HeadlessLinkPendingJSON {
			event = HEADLESS_EVENT_NAMES[.LinkPending],
			open = pending.open,
			kind = pending.link.kind == .Invite ? "invite" : "join",
			server = pending.serverName,
			host = pending.link.host,
			port = int(pending.link.port),
			hasKey = pending.link.hasKey,
			hasCode = len(pending.link.code) > 0,
			match = HEADLESS_LINK_MATCH_NAMES[pending.match],
			serverID = pending.serverID,
			error = pending.error,
		},
	)
	headlessRecordEvent(harness, .LinkPending)
}

headlessCommandLinkOpen :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	State_openLink(&harness.state, command.args[0])
	headlessWriteLinkPending(harness)
}

headlessCommandLinkConfirm :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	if !harness.state.pendingLink.open {
		headlessWriteError(harness, command.name, "no link is waiting; use link-open first")
		return
	}
	if errorMessage := State_confirmPendingLink(&harness.state); len(errorMessage) > 0 {
		headlessWriteError(harness, command.name, errorMessage)
		return
	}
	headlessWriteJSON(
		harness,
		HeadlessServerResultJSON {
			ok = true,
			cmd = command.name,
			serverID = harness.state.selected_server_id,
		},
	)
}

headlessCommandLinkCancel :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	State_cancelPendingLink(&harness.state)
	headlessWriteJSON(
		harness,
		HeadlessServerResultJSON {
			ok = true,
			cmd = command.name,
			serverID = harness.state.selected_server_id,
		},
	)
}
