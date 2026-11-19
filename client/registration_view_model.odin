package client

import "../common"
import "core:fmt"
import "core:mem"
import "core:strings"

// View models for registration (protocol 25, #43 G2): the sign-up screen and the Admin
// section's Registration, Invites and Sign-up requests parts. Pure reads of State; strings
// borrow from State or the view allocator, so a view is valid only until State next changes.

// ── Sign-up screen ────────────────────────────────────────────────

SignUpView :: struct {
	visible:        bool,
	serverID:       int,
	phase:          SignUpPhase,
	title:          string,
	// What the server said (or what this phase means), and the name the account will get.
	text:           string,
	nameNote:       string,
	// Required, Submitting and Refused: the code field, and the reason in approval mode.
	showForm:       bool,
	showReason:     bool,
	codeOptional:   bool,
	submitLabel:    string,
	submitEnabled:  bool,
	// A refusal (the server's) or a local check; drawn in the danger colour.
	error:          string,
	// Pending: Check again. Declined and Ended: Start again.
	showCheckAgain: bool,
	showStartAgain: bool,
	// Check again or Start again is connecting.
	reconnecting:   bool,
}

SIGN_UP_PENDING_TEXT ::
	"Your sign-up request is waiting for approval. Someone who approves sign-ups on this " +
	"server has to accept it; you can close HayChat meanwhile. Check again connects and asks " +
	"the server, without sending your code again."
SIGN_UP_ENDED_TEXT :: "The sign-up ended before your account was made"

registrationModeText :: proc(mode: common.RegistrationMode) -> string {
	switch mode {
	case .Open:
		return "Anyone may sign up on this server; an invite code can give you roles or a room."
	case .InviteOnly:
		return common.REGISTRATION_REQUIRED_MESSAGE
	case .InviteApproval:
		return common.REGISTRATION_APPROVAL_REQUIRED_MESSAGE
	}
	return ""
}

registrationModeLabel :: proc(mode: common.RegistrationMode) -> string {
	switch mode {
	case .Open:
		return "Open"
	case .InviteOnly:
		return "Invite only"
	case .InviteApproval:
		return "Invite + approval"
	}
	return "Unknown"
}

REGISTRATION_MODES := [?]common.RegistrationMode{.Open, .InviteOnly, .InviteApproval}

buildSignUpView :: proc(state: ^State, allocator := context.temp_allocator) -> (view: SignUpView) {
	if !State_signUpVisible(state) {
		return
	}
	serverID := state.selected_server_id
	server, ok := State_serverConfig(state, serverID)
	index := State_serverConnectionIndex(state^, serverID)
	if !ok || index < 0 {
		return
	}
	connection := state.serverConnections[index]
	view.visible = true
	view.serverID = serverID
	view.phase = connection.signUp
	view.reconnecting =
		connection.status == .Connecting ||
		connection.status == .Handshaking ||
		connection.status == .Disconnected
	form := &state.signUpForm
	formError := form.serverID == serverID ? form.error : ""
	switch connection.signUp {
	case .None:
		view.visible = false
	case .Required, .Submitting, .Refused:
		view.title = fmt.aprintf("Sign up on %s", server.name, allocator = allocator)
		view.text = connection.signUpMessage
		if len(view.text) == 0 || connection.signUp == .Refused {
			view.text = registrationModeText(connection.registrationMode)
		}
		view.showForm = connection.status == .Registering
		view.showReason = connection.registrationMode == .InviteApproval
		view.codeOptional = connection.registrationMode == .Open
		view.submitLabel = connection.signUp == .Submitting ? "Signing up…" : "Sign up"
		view.submitEnabled = connection.signUp != .Submitting && connection.status == .Registering
		view.error = formError
		if connection.signUp == .Refused {
			view.error = connection.signUpMessage
		}
		view.nameNote = fmt.aprintf(
			"You will sign up as %s. Change the name in Server settings before signing up if " +
			"you want another one here.",
			Server_displayName(server^, state.config),
			allocator = allocator,
		)
		if connection.status != .Registering {
			// The session went away under the form (the connection dropped).
			view.showStartAgain = true
			view.error = connection.detail
		}
	case .Pending:
		view.title = strings.clone("Waiting for approval", allocator)
		view.text = SIGN_UP_PENDING_TEXT
		view.showCheckAgain = connection.status != .Registering
	case .Declined:
		view.title = strings.clone("Sign-up declined", allocator)
		view.text = connection.signUpMessage
		if len(view.text) == 0 {
			view.text = common.REGISTRATION_DECLINED_MESSAGE
		}
		view.showStartAgain = true
	case .Ended:
		view.title = fmt.aprintf("Sign up on %s", server.name, allocator = allocator)
		reason := strings.trim_prefix(connection.signUpMessage, CLIENT_REGISTRATION_ENDED_MESSAGE)
		reason = strings.trim_prefix(reason, ": ")
		view.text = fmt.aprintf(
			"%s: %s. Start again to enter a code once more.",
			SIGN_UP_ENDED_TEXT,
			len(reason) > 0 ? reason : CLIENT_REGISTRATION_CLOSED_REASON,
			allocator = allocator,
		)
		view.showStartAgain = true
	}
	// Check again or Start again could not reach the server: say why under the buttons.
	#partial switch connection.signUp {
	case .Pending, .Declined, .Ended:
		#partial switch connection.failureKind {
		case .RegistrationPending, .RegistrationDeclined, .RegistrationRequired, .None:
		case:
			if connection.lastAttemptFailed && len(connection.detail) > 0 {
				view.error = describeConnectFailure(
					connection.failureKind,
					connection.detail,
					Server_displayName(server^, state.config),
					"",
					allocator,
				)
			}
		}
	}
	return
}

// ── Link confirmation ─────────────────────────────────────────────

LinkConfirmView :: struct {
	visible:      bool,
	title:        string,
	text:         string,
	fingerprint:  string,
	confirmLabel: string,
	// Refused links offer only Close.
	canConfirm:   bool,
}

buildLinkConfirmView :: proc(
	state: ^State,
	allocator := context.temp_allocator,
) -> (
	view: LinkConfirmView,
) {
	pending := &state.pendingLink
	if !pending.open {
		return
	}
	view.visible = true
	if len(pending.error) > 0 {
		view.title = strings.clone("This link cannot be used", allocator)
		view.text = pending.error
		return
	}
	link := pending.link
	address := serverLabel(link.host, link.port, allocator)
	if link.hasKey {
		fingerprint := common.fingerprintToHex(common.fingerprintIdentityPublicKey(link.key))
		view.fingerprint = fmt.aprintf(
			"Server key fingerprint: %s",
			fingerprint,
			allocator = allocator,
		)
		delete(fingerprint)
	}
	view.canConfirm = true
	known := pending.match != .NewServer
	switch link.kind {
	case .Join:
		view.title = fmt.aprintf("Join %s?", pending.serverName, allocator = allocator)
		view.confirmLabel = "Join"
		if known {
			view.text = fmt.aprintf(
				"%s (%s) is already in your list. HayChat connects to it.",
				pending.serverName,
				address,
				allocator = allocator,
			)
		} else {
			view.text = fmt.aprintf(
				"HayChat adds %s to your servers and connects to it.",
				address,
				allocator = allocator,
			)
		}
	case .Invite:
		view.title = fmt.aprintf(
			"Sign up on %s with an invite?",
			pending.serverName,
			allocator = allocator,
		)
		view.confirmLabel = "Continue"
		lead := known ? "HayChat connects to" : "HayChat adds"
		view.text = fmt.aprintf(
			"%s %s and fills in the invite code. Nothing is sent until you press Sign up. Open " +
			"links only from people you trust: the code is for this server only.",
			lead,
			address,
			allocator = allocator,
		)
	}
	return
}

// ── Admin section ─────────────────────────────────────────────────

AdminInviteRow :: struct {
	inviteID:  int,
	label:     string, // The note, or "No note"
	detail:    string, // Who made it, uses, expiry, grants (view allocator)
	revoked:   bool,
	canRevoke: bool,
}

AdminRequestRow :: struct {
	requestID:    int,
	label:        string, // The name it asked for
	reason:       string,
	detail:       string, // Code, inviter, when (view allocator)
	pending:      bool,
	statusLabel:  string,
	decisionOpen: bool,
}

AdminInviteChoice :: struct {
	id:      int,
	label:   string,
	checked: bool,
	enabled: bool,
}

InviteFormView :: struct {
	open:         bool,
	isAdmin:      bool,
	expiry:       []AdminInviteChoice, // id is the index into INVITE_EXPIRY_CHOICES
	uses:         []AdminInviteChoice, // id is the index into INVITE_USES_CHOICES
	roles:        []AdminInviteChoice, // id is the role ID (admins)
	rooms:        []AdminInviteChoice, // id is the room ID (admins)
	skipApproval: bool,
	error:        string,
	pending:      bool,
}

RegistrationAdminView :: struct {
	// Admins: the mode picker.
	showMode:      bool,
	mode:          common.RegistrationMode,
	// CreateInvites holders.
	showInvites:   bool,
	invitesLoaded: bool,
	invites:       []AdminInviteRow,
	form:          InviteFormView,
	// The code shown once (D9), with its link (D19).
	createdCode:   string,
	createdLink:   string,
	createdDetail: string,
	createError:   string,
	// ApproveRegistrations holders.
	showRequests:  bool,
	requestsLoaded: bool,
	requests:      []AdminRequestRow,
	pendingCount:  int,
}

@(private = "file")
inviteDetail :: proc(
	state: ^State,
	serverID: int,
	invite: common.InviteSummary,
	allocator := context.temp_allocator,
) -> string {
	builder := strings.builder_make(allocator)
	creator := invite.createdByNickname
	if invite.createdBy == 0 {
		creator = "an operator"
	} else if len(creator) == 0 {
		creator = fmt.tprintf("User %d", invite.createdBy)
	}
	fmt.sbprintf(&builder, "By %s · ", creator)
	if invite.maxUses > 0 {
		fmt.sbprintf(&builder, "%d of %d uses", invite.uses, invite.maxUses)
	} else {
		fmt.sbprintf(&builder, "%d uses, no limit", invite.uses)
	}
	if len(invite.expiresAt) > 0 {
		fmt.sbprintf(&builder, " · expires %s", invite.expiresAt)
	} else {
		strings.write_string(&builder, " · never expires")
	}
	if len(invite.roleIds) > 0 {
		names := make([dynamic]string, 0, context.temp_allocator)
		for roleID in invite.roleIds {
			if role := State_findRole(state, serverID, roleID); role != nil {
				append(&names, role.name)
			}
		}
		if len(names) > 0 {
			joined := strings.join(names[:], ", ", context.temp_allocator)
			fmt.sbprintf(&builder, " · roles: %s", joined)
		}
	}
	if invite.restricted {
		roomName := "a deleted room"
		room := State_knownRoom(state, serverID, invite.roomId)
		if room != nil && invite.roomId > 0 {
			roomName = fmt.tprintf("#%s", room.name)
		}
		fmt.sbprintf(&builder, " · restricted to %s", roomName)
	}
	if invite.skipApproval {
		strings.write_string(&builder, " · skips approval")
	}
	if invite.revoked {
		strings.write_string(&builder, " · revoked")
	}
	return strings.to_string(builder)
}

// Rooms an admin's code may restrict accounts to: unencrypted Member and Admin invite rooms
// (D11; the server refuses others).
@(private = "file")
inviteRoomChoices :: proc(
	state: ^State,
	serverID: int,
	selected: int,
	allocator := context.temp_allocator,
) -> []AdminInviteChoice {
	choices := make([dynamic]AdminInviteChoice, 0, allocator)
	index := State_serverRoomCacheIndex(state^, serverID)
	if index < 0 {
		return choices[:]
	}
	cache := &state.server_room_caches[index]
	add :: proc(
		choices: ^[dynamic]AdminInviteChoice,
		room: common.RoomSummary,
		selected: int,
		allocator: mem.Allocator,
	) {
		if room.encrypted || (room.access != .MemberInvite && room.access != .AdminInvite) {
			return
		}
		for choice in choices {
			if choice.id == room.id {
				return
			}
		}
		append(
			choices,
			AdminInviteChoice {
				id = room.id,
				label = fmt.aprintf("#%s", room.name, allocator = allocator),
				checked = room.id == selected,
				enabled = true,
			},
		)
	}
	for entry in cache.adminRooms {
		add(&choices, entry.room, selected, allocator)
	}
	for room in cache.rooms {
		add(&choices, room, selected, allocator)
	}
	return choices[:]
}

buildRegistrationAdminView :: proc(
	state: ^State,
	serverID: int,
	allocator := context.temp_allocator,
) -> (
	view: RegistrationAdminView,
) {
	isAdmin := State_isServerAdmin(state, serverID)
	view.showMode = isAdmin
	view.mode = State_registrationMode(state, serverID)
	view.showInvites = State_hasPermission(state, serverID, .CreateInvites)
	view.showRequests = State_hasPermission(state, serverID, .ApproveRegistrations)
	view.pendingCount = State_pendingRegistrationCount(state, serverID)
	cacheIndex := State_serverRegistrationCacheIndex(state, serverID)
	if cacheIndex < 0 {
		return
	}
	cache := &state.serverRegistrations[cacheIndex]
	selfUserID := State_selfUserID(state, serverID)
	if view.showInvites {
		view.invitesLoaded = cache.invitesLoaded
		rows := make([dynamic]AdminInviteRow, 0, allocator)
		for invite in cache.invites {
			label := invite.note
			if len(label) == 0 {
				label = "No note"
			}
			append(
				&rows,
				AdminInviteRow {
					inviteID = invite.id,
					label = label,
					detail = inviteDetail(state, serverID, invite, allocator),
					revoked = invite.revoked,
					canRevoke = !invite.revoked && (isAdmin || invite.createdBy == selfUserID),
				},
			)
		}
		view.invites = rows[:]
		view.createdCode = cache.created.code
		view.createdLink = cache.created.link
		if len(cache.created.code) > 0 {
			view.createdDetail = inviteDetail(state, serverID, cache.created.invite, allocator)
		}
		view.createError = cache.createError
		form := &state.inviteForm
		if form.open && form.serverID == serverID {
			view.form = InviteFormView {
				open         = true,
				isAdmin      = isAdmin,
				skipApproval = form.skipApproval,
				error        = form.error,
				pending      = cache.createPending,
			}
			expiry := make([]AdminInviteChoice, len(INVITE_EXPIRY_CHOICES), allocator)
			for label, index in INVITE_EXPIRY_LABELS {
				expiry[index] = {
					id      = index,
					label   = label,
					checked = form.expiryIndex == index,
					enabled = inviteExpiryAllowed(index, isAdmin),
				}
			}
			view.form.expiry = expiry
			uses := make([]AdminInviteChoice, len(INVITE_USES_CHOICES), allocator)
			for label, index in INVITE_USES_LABELS {
				uses[index] = {
					id      = index,
					label   = label,
					checked = form.usesIndex == index,
					enabled = true,
				}
			}
			view.form.uses = uses
			if isAdmin {
				roles := make([dynamic]AdminInviteChoice, 0, allocator)
				for role in State_roles(state, serverID) {
					if role.builtin {
						continue
					}
					append(
						&roles,
						AdminInviteChoice {
							id = role.id,
							label = role.name,
							checked = inviteFormHasRole(form^, role.id),
							enabled = true,
						},
					)
				}
				view.form.roles = roles[:]
				view.form.rooms = inviteRoomChoices(state, serverID, form.roomID, allocator)
			}
		}
	}
	if view.showRequests {
		view.requestsLoaded = cache.requestsLoaded
		rows := make([dynamic]AdminRequestRow, 0, allocator)
		for request in cache.requests {
			builder := strings.builder_make(allocator)
			if len(request.inviteNote) > 0 {
				fmt.sbprintf(&builder, "Code: %s · ", request.inviteNote)
			}
			fmt.sbprintf(&builder, "asked %s", request.createdAt)
			if request.status == .Declined && len(request.decisionReason) > 0 {
				fmt.sbprintf(&builder, " · declined: %s", request.decisionReason)
			}
			statusLabel := ""
			switch request.status {
			case .None, .Pending:
				statusLabel = "Pending"
			case .Approved:
				statusLabel = "Approved"
			case .Declined:
				statusLabel = "Declined"
			}
			append(
				&rows,
				AdminRequestRow {
					requestID = request.id,
					label = len(request.nickname) > 0 ? request.nickname : "(no name)",
					reason = request.reason,
					detail = strings.to_string(builder),
					pending = request.status == .Pending,
					statusLabel = statusLabel,
					decisionOpen = state.decisionForm.requestID == request.id,
				},
			)
		}
		view.requests = rows[:]
	}
	return
}
