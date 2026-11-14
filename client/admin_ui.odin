package client

import "../common"
import "core:fmt"
import "core:slice"

// The admin's controls for accounts and rooms (plan P4): the Admin section of Server settings
// (view_server_settings.odin) and the admin entries of the user context menus
// (context_menu.odin). Both are offered only to admins (State_isServerAdmin) and send through
// the protocol 14 actions in admin.odin, so the server still checks the role and every guard.
//
// What the server refuses (plan decision D6) is disabled here with a sentence saying why:
// kicking, banning or removing the admin role of yourself, kicking or banning another admin
// (remove the role first), and making a banned account an admin. Renaming yourself is allowed.
// The last-admin guard needs no rule of its own: an admin who is not you is never the last one.
//
// Actions that need input (Rename: a new name and the lock; Kick and Ban: an optional reason)
// open an inline confirmation under the member in the Admin section. A menu cannot hold a text
// field, so its Rename…, Kick… and Ban… open Server settings → Admin with that confirmation
// already open (State_openAdminConfirm). Make admin, Remove admin and Unban act at once.

AdminConfirmKind :: enum u8 {
	None,
	Rename,
	Kick,
	Ban,
}

// The confirmation open under one member in the Admin section. text is edited in place by its
// text input.
AdminConfirm :: struct {
	kind:     AdminConfirmKind,
	userID:   int,
	// Rename: the new name (empty changes only the lock). Kick and Ban: the reason.
	text:     [dynamic]u8,
	// Rename: lock the name so the account's own sign-ins cannot change it (D3). On by
	// default; off with an empty name unlocks the current name.
	lockName: bool,
	// The view scrolls the member's row into view on its next frame (opened from a menu).
	scrollTo: bool,
}

AdminConfirm_deinit :: proc(confirm: ^AdminConfirm) {
	delete(confirm.text)
	confirm^ = {}
}

// One admin control for one account: its label and whether it can be used, with the reason
// when it cannot. Strings are static.
AdminControl :: struct {
	label:   string,
	enabled: bool,
	reason:  string,
}

// The admin controls for one account, from the server's user directory.
AdminUserControls :: struct {
	userID:   int,
	isSelf:   bool,
	isAdmin:  bool,
	isBanned: bool,
	isOnline: bool,
	rename:   AdminControl,
	// "Make admin" or "Remove admin"; grant says which.
	role:     AdminControl,
	grant:    bool,
	kick:     AdminControl,
	// "Ban…" or "Unban"; banning says which.
	ban:      AdminControl,
	banning:  bool,
}

ADMIN_REASON_SELF_REVOKE :: "You cannot remove your own admin role."
ADMIN_REASON_SELF_KICK :: "You cannot kick yourself."
ADMIN_REASON_SELF_BAN :: "You cannot ban yourself."
ADMIN_REASON_ADMIN_KICK :: "Remove their admin role before kicking them."
ADMIN_REASON_ADMIN_BAN :: "Remove their admin role before banning them."
ADMIN_REASON_BANNED_GRANT :: "Unban the account before making it an admin."

// The controls for userID on serverID, or false when the server's directory does not list the
// account (the flags come from its UserSummary).
buildAdminUserControls :: proc(
	state: ^State,
	serverID, userID: int,
) -> (
	controls: AdminUserControls,
	known: bool,
) {
	index := State_serverDirectCacheIndex(state^, serverID)
	if index < 0 || userID <= 0 {
		return
	}
	cache := &state.serverDirectCaches[index]
	userIndex := ServerDirectCache_userIndex(cache^, userID)
	if userIndex < 0 {
		return
	}
	user := cache.users[userIndex]
	return adminUserControls(user, userID == State_selfUserID(state, serverID)), true
}

// The controls for one directory entry; isSelf is whether it is the signed-in account. Pure.
adminUserControls :: proc(user: common.UserSummary, isSelf: bool) -> (controls: AdminUserControls) {
	controls.userID = user.id
	controls.isSelf = isSelf
	controls.isAdmin = user.isAdmin
	controls.isBanned = user.isBanned
	controls.isOnline = user.isOnline

	controls.rename = {label = "Rename…", enabled = true}

	controls.grant = !user.isAdmin
	if controls.grant {
		controls.role = {label = "Make admin", enabled = !user.isBanned}
		if user.isBanned {
			controls.role.reason = ADMIN_REASON_BANNED_GRANT
		}
	} else {
		controls.role = {label = "Remove admin", enabled = !controls.isSelf}
		if controls.isSelf {
			controls.role.reason = ADMIN_REASON_SELF_REVOKE
		}
	}

	controls.kick = {label = "Kick…", enabled = true}
	switch {
	case controls.isSelf:
		controls.kick = {label = "Kick…", reason = ADMIN_REASON_SELF_KICK}
	case user.isAdmin:
		controls.kick = {label = "Kick…", reason = ADMIN_REASON_ADMIN_KICK}
	}

	controls.banning = !user.isBanned
	if controls.banning {
		controls.ban = {label = "Ban…", enabled = true}
		switch {
		case controls.isSelf:
			controls.ban = {label = "Ban…", reason = ADMIN_REASON_SELF_BAN}
		case user.isAdmin:
			controls.ban = {label = "Ban…", reason = ADMIN_REASON_ADMIN_BAN}
		}
	} else {
		controls.ban = {label = "Unban", enabled = true}
	}
	return
}

@(private = "file")
adminConfirmAction :: proc(kind: AdminConfirmKind) -> common.AdminAction {
	switch kind {
	case .Kick:
		return .Kick
	case .Ban:
		return .Ban
	case .Rename, .None:
	}
	return .Rename
}

// Whether the controls allow opening kind's confirmation.
@(private = "file")
adminConfirmAllowed :: proc(controls: AdminUserControls, kind: AdminConfirmKind) -> bool {
	switch kind {
	case .Rename:
		return controls.rename.enabled
	case .Kick:
		return controls.kick.enabled
	case .Ban:
		return controls.ban.enabled && controls.banning
	case .None:
	}
	return false
}

// Opens kind's confirmation for userID in Server settings → Admin, opening the screen on
// serverID first unless it is already shown there (so fields being edited are kept). Returns
// false for a non-admin, an account the directory does not list, or a disabled control.
State_openAdminConfirm :: proc(
	state: ^State,
	serverID: int,
	kind: AdminConfirmKind,
	userID: int,
) -> bool {
	if !State_isServerAdmin(state, serverID) {
		return false
	}
	controls, known := buildAdminUserControls(state, serverID, userID)
	if !known || !adminConfirmAllowed(controls, kind) {
		return false
	}
	if !State_serverSettingsVisible(state) || state.serverSettings.serverID != serverID {
		if !State_openServerSettings(state, serverID) {
			return false
		}
	}
	confirm := &state.serverSettings.adminConfirm
	confirm.kind = kind
	confirm.userID = userID
	clear(&confirm.text)
	confirm.lockName = true
	confirm.scrollTo = true
	return true
}

State_cancelAdminConfirm :: proc(state: ^State) {
	confirm := &state.serverSettings.adminConfirm
	confirm.kind = .None
	confirm.userID = 0
	clear(&confirm.text)
	confirm.lockName = false
	confirm.scrollTo = false
}

// Rename: toggles the lock.
State_toggleAdminConfirmLock :: proc(state: ^State) {
	confirm := &state.serverSettings.adminConfirm
	if confirm.kind == .Rename {
		confirm.lockName = !confirm.lockName
	}
}

// Confirm: sends the open confirmation's request. The confirmation closes once the transport
// took it; the server's answer is shown with the Admin section (AdminSectionView.status). A
// request that could not go out leaves it open with the reason as the status.
State_submitAdminConfirm :: proc(state: ^State) -> bool {
	form := &state.serverSettings
	confirm := &form.adminConfirm
	if !form.open || confirm.kind == .None {
		return false
	}
	serverID, userID, kind := form.serverID, confirm.userID, confirm.kind
	controls, known := buildAdminUserControls(state, serverID, userID)
	if !State_isServerAdmin(state, serverID) || !known || !adminConfirmAllowed(controls, kind) {
		State_adminRequestFailed(
			state,
			serverID,
			adminConfirmAction(kind),
			userID,
			"This action is not available for that account any more.",
		)
		return false
	}
	text := string(confirm.text[:])
	errorMessage: string
	switch kind {
	case .Rename:
		errorMessage = State_sendAdminRenameUser(state, serverID, userID, text, confirm.lockName)
	case .Kick:
		errorMessage = State_sendAdminKickUser(state, serverID, userID, text)
	case .Ban:
		errorMessage = State_sendAdminBanUser(state, serverID, userID, true, text)
	case .None:
	}
	if len(errorMessage) > 0 {
		State_adminRequestFailed(state, serverID, adminConfirmAction(kind), userID, errorMessage)
		return false
	}
	State_cancelAdminConfirm(state)
	return true
}

// Make admin (isAdmin true) or Remove admin, from the Admin section or a menu. Returns false,
// with the reason recorded as the Admin section's status, when nothing was sent.
State_adminSetRole :: proc(state: ^State, serverID, userID: int, isAdmin: bool) -> bool {
	controls, known := buildAdminUserControls(state, serverID, userID)
	if !State_isServerAdmin(state, serverID) ||
	   !known ||
	   !controls.role.enabled ||
	   controls.grant != isAdmin {
		return false
	}
	if errorMessage := State_sendAdminSetRole(state, serverID, userID, isAdmin);
	   len(errorMessage) > 0 {
		State_adminRequestFailed(state, serverID, .SetRole, userID, errorMessage)
		return false
	}
	return true
}

// Unban, from the Admin section or a menu.
State_adminUnban :: proc(state: ^State, serverID, userID: int) -> bool {
	controls, known := buildAdminUserControls(state, serverID, userID)
	if !State_isServerAdmin(state, serverID) || !known || controls.banning {
		return false
	}
	if errorMessage := State_sendAdminBanUser(state, serverID, userID, false, "");
	   len(errorMessage) > 0 {
		State_adminRequestFailed(state, serverID, .Ban, userID, errorMessage)
		return false
	}
	return true
}

// "Text", "Voice" or "Text and voice".
roomTypeLabel :: proc(roomType: common.RoomType) -> string {
	#partial switch roomType {
	case .Chat:
		return "Text"
	case .Voice:
		return "Voice"
	}
	return "Text and voice"
}

// A room's type for what the client shows: an unsupported one (never sent by a protocol 14
// server) counts as text and voice, like a room the cache does not have.
roomTypeShown :: proc(roomType: common.RoomType) -> common.RoomType {
	return common.roomTypeIsSupported(roomType) ? roomType : .ChatAndVoice
}

// Whether the room takes chat (has a composer) and voice (offers Join voice).
State_roomAllowsChat :: proc(state: ^State, serverID, roomID: int) -> bool {
	return common.roomTypeAllowsChat(roomTypeShown(State_roomType(state, serverID, roomID)))
}

State_roomAllowsVoice :: proc(state: ^State, serverID, roomID: int) -> bool {
	return common.roomTypeAllowsVoice(roomTypeShown(State_roomType(state, serverID, roomID)))
}

// ── View model ────────────────────────────────────────────────────

AdminMemberRow :: struct {
	using controls: AdminUserControls,
	label:          string, // Borrowed from State, or in the view allocator
}

AdminRoomRow :: struct {
	roomID:    int,
	label:     string, // "# name", in the view allocator
	typeLabel: string, // Static
}

AdminStatusTone :: enum u8 {
	None,
	Pending,
	Success,
	Error,
}

// The open confirmation, as the view draws it under its member's row.
AdminConfirmView :: struct {
	kind:         AdminConfirmKind,
	userID:       int,
	title:        string, // "Rename bob", "Kick bob", "Ban bob"
	fieldLabel:   string,
	placeholder:  string,
	note:         string,
	confirmLabel: string,
	danger:       bool,
	maxBytes:     int,
	showLock:     bool,
	lockLabel:    string,
}

AdminSectionView :: struct {
	visible:    bool,
	note:       string,
	// Every account of the server's directory, you included, by name (adminMemberLess), so a
	// row stays where it is when its account goes offline or is banned.
	members:    []AdminMemberRow,
	rooms:      []AdminRoomRow,
	confirm:    AdminConfirmView,
	// The last admin request on this server: waiting, the server's sentence, or the refusal.
	// The view draws it under statusUserID's row, where the admin is looking, or above the
	// table when that account is not listed.
	status:       string,
	statusTone:   AdminStatusTone,
	statusUserID: int,
}

// By name (as memberLess orders equal online states), then by ID: unlike the sidebar, the
// Admin table does not put online accounts first, so its rows do not move under the pointer.
@(private = "file")
adminMemberLess :: proc(a, b: common.UserSummary) -> bool {
	a, b := a, b
	a.isOnline = false
	b.isOnline = false
	return memberLess(a, b)
}

// The Admin section for serverID; visible only to an admin of it. Strings borrow from State
// or the view allocator, so the result is valid only until State next changes.
buildAdminSectionView :: proc(
	state: ^State,
	serverID: int,
	allocator := context.temp_allocator,
) -> (
	view: AdminSectionView,
) {
	if !State_isServerAdmin(state, serverID) {
		return
	}
	view.visible = true
	view.note =
		"Only admins see this section. The server checks every change; renaming locks the " +
		"name so the account cannot change it back."
	selfUserID := State_selfUserID(state, serverID)
	members := make([dynamic]AdminMemberRow, 0, allocator)
	if index := State_serverDirectCacheIndex(state^, serverID); index >= 0 {
		users := slice.clone(state.serverDirectCaches[index].users[:], allocator)
		slice.sort_by(users, adminMemberLess)
		for user in users {
			controls := adminUserControls(user, user.id == selfUserID)
			label := userLabel(user.nickname, user.id, allocator)
			if user.id == selfUserID {
				label = fmt.aprintf("%s (you)", label, allocator = allocator)
			}
			append(&members, AdminMemberRow{controls = controls, label = label})
		}
	}
	view.members = members[:]

	rooms := make([dynamic]AdminRoomRow, 0, allocator)
	if index := State_serverRoomCacheIndex(state^, serverID); index >= 0 {
		for room in state.server_room_caches[index].rooms {
			append(
				&rooms,
				AdminRoomRow {
					roomID = room.id,
					label = fmt.aprintf("# %s", room.name, allocator = allocator),
					typeLabel = roomTypeLabel(roomTypeShown(room.roomType)),
				},
			)
		}
	}
	view.rooms = rooms[:]

	if form := &state.serverSettings; form.open && form.serverID == serverID {
		view.confirm = buildAdminConfirmView(state, serverID, form.adminConfirm, allocator)
	}

	request := &state.adminRequest
	if request.serverID == serverID {
		view.statusUserID = request.userID
		switch {
		case request.pending:
			view.status = "Waiting for the server…"
			view.statusTone = .Pending
		case len(request.error) > 0:
			view.status = request.error
			view.statusTone = .Error
		case len(request.result) > 0:
			view.status = request.result
			view.statusTone = .Success
		}
	}
	return
}

@(private = "file")
buildAdminConfirmView :: proc(
	state: ^State,
	serverID: int,
	confirm: AdminConfirm,
	allocator := context.temp_allocator,
) -> (
	view: AdminConfirmView,
) {
	if confirm.kind == .None {
		return
	}
	name := ""
	if index := State_serverDirectCacheIndex(state^, serverID); index >= 0 {
		name = ServerDirectCache_peerNickname(&state.serverDirectCaches[index], confirm.userID)
	}
	name = userLabel(name, confirm.userID, allocator)
	view.kind = confirm.kind
	view.userID = confirm.userID
	switch confirm.kind {
	case .Rename:
		view.title = fmt.aprintf("Rename %s", name, allocator = allocator)
		view.fieldLabel = "New name"
		view.placeholder = fmt.aprintf("Empty keeps \"%s\"", name, allocator = allocator)
		view.maxBytes = common.NICKNAME_MAX_BYTES
		view.confirmLabel = "Rename"
		view.showLock = true
		view.lockLabel = confirm.lockName ? "Lock name: on" : "Lock name: off"
		if confirm.lockName {
			view.note =
				"A locked name stays whatever name their client signs in with. Leave the " +
				"field empty to lock the name they have now."
		} else {
			view.note =
				"Unlocked, their next sign-in can change the name again. Leave the field " +
				"empty to unlock the name they have now."
		}
	case .Kick:
		view.title = fmt.aprintf("Kick %s", name, allocator = allocator)
		view.fieldLabel = "Reason (optional)"
		view.placeholder = "Shown to them"
		view.maxBytes = common.ADMIN_REASON_MAX_BYTES
		view.confirmLabel = "Kick"
		view.danger = true
		view.note =
			"Ends every session of the account. They can connect again when they press Retry."
	case .Ban:
		view.title = fmt.aprintf("Ban %s", name, allocator = allocator)
		view.fieldLabel = "Reason (optional)"
		view.placeholder = "Shown to them"
		view.maxBytes = common.ADMIN_REASON_MAX_BYTES
		view.confirmLabel = "Ban"
		view.danger = true
		view.note =
			"Ends every session of the account and refuses its sign-in until you unban it. " +
			"Sign-up is open, so they can still join with a new key as a new account."
	case .None:
	}
	return
}
