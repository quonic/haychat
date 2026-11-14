package client

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:unicode/utf8"

// Server settings: one screen per configured server, in the main pane like the room form
// (view_server_settings.odin), with settings that apply to that server only. They are kept in
// the server's entry in config.json (decision D1 of docs/plan/2026-11-14-admin-settings-menus.md),
// so they are local to this profile and never sent anywhere except the name:
//
//   - Profile: the display name on this server (Server.display_name); empty uses the global
//     one. The transport signs in with it (Server_displayName), so changing it renames the
//     account on this server only and reconnects only this server.
//   - Server: the label and short label (the rail button), host and port, the pinned key
//     fingerprint with Forget key, and Remove server.
//   - Voice: a volume (0 to 200 %) and Mute for me per user (user_voice.odin), applied to the
//     running voice engine at once.
//   - Admin (admins only, admin_ui.odin): the server's accounts with Rename, the admin role,
//     Kick and Ban, and its rooms with their type, Edit, Delete and Create.
//
// State_openServerSettings opens it for a server (the sidebar header's gear and the rail
// button's context menu). Switching servers or rooms, opening a conversation, the room form or
// the general settings closes it, and so does removing its server.

SERVER_LABEL_MAX_BYTES :: 64
// The rail button is small: two or three letters fit.
SERVER_SHORT_LABEL_MAX_BYTES :: 8
SERVER_SHORT_LABEL_MAX_RUNES :: 3

ServerSettingsForm :: struct {
	open:             bool,
	serverID:         int,
	// Edited in place by the text inputs; filled from the config on open and after a save.
	displayName:      [dynamic]u8,
	label:            [dynamic]u8,
	shortLabel:       [dynamic]u8,
	host:             [dynamic]u8,
	port:             [dynamic]u8,
	// Forget key and Remove server take two clicks: the first arms the button.
	confirmForgetKey: bool,
	confirmRemove:    bool,
	error:            string, // Owned
	notice:           string, // Owned; what the last save did
	// The Admin section's confirmation (admin_ui.odin), open under one member.
	adminConfirm:     AdminConfirm,
	// The view's content height last frame, for its scroll area.
	contentH:         f32,
	// Set when the screen opens: the view starts it at the top rather than where an earlier
	// visit left it.
	scrollToTop:      bool,
}

ServerSettingsForm_deinit :: proc(form: ^ServerSettingsForm) {
	delete(form.displayName)
	delete(form.label)
	delete(form.shortLabel)
	delete(form.host)
	delete(form.port)
	delete(form.error)
	delete(form.notice)
	AdminConfirm_deinit(&form.adminConfirm)
	form^ = {}
}

@(private = "file")
ServerSettingsForm_setMessages :: proc(form: ^ServerSettingsForm, errorText, noticeText: string) {
	delete(form.error)
	delete(form.notice)
	form.error = strings.clone(errorText)
	form.notice = strings.clone(noticeText)
}

@(private = "file")
serverSettingsSetBuffer :: proc(buffer: ^[dynamic]u8, value: string) {
	clear(buffer)
	append(buffer, value)
}

// Fills the fields from the server's config entry and disarms both confirmations.
@(private = "file")
ServerSettingsForm_load :: proc(form: ^ServerSettingsForm, server: Server) {
	serverSettingsSetBuffer(&form.displayName, server.display_name)
	serverSettingsSetBuffer(&form.label, server.name)
	serverSettingsSetBuffer(&form.shortLabel, server.short_name)
	serverSettingsSetBuffer(&form.host, server.host)
	serverSettingsSetBuffer(&form.port, fmt.tprintf("%d", server.port))
	form.confirmForgetKey = false
	form.confirmRemove = false
}

// Whether the screen is open on the selected server, which is when the main pane shows it.
State_serverSettingsVisible :: proc(state: ^State) -> bool {
	return state.serverSettings.open && state.serverSettings.serverID == state.selected_server_id
}

// Opens serverID's settings, switching to that server first when another one is shown. The
// room form and the general settings close; an open conversation stays selected underneath,
// so closing the screen goes back to it. Returns false for a server that is not configured.
State_openServerSettings :: proc(state: ^State, serverID: int) -> bool {
	if _, ok := State_serverConfig(state, serverID); !ok {
		return false
	}
	State_closeSettings(state)
	if state.settingsOpen {
		// First-run setup cannot be left yet.
		return false
	}
	if serverID != state.selected_server_id {
		State_switchToServer(state, serverID)
	}
	State_closeRoomEditor(state)
	server, _ := State_serverConfig(state, serverID)
	form := &state.serverSettings
	form.open = true
	form.serverID = serverID
	form.scrollToTop = true
	ServerSettingsForm_load(form, server^)
	ServerSettingsForm_setMessages(form, "", "")
	State_cancelAdminConfirm(state)
	State_clearAdminRequestStatus(state)
	// The Admin section lists every room, also those the admin is not in (protocol 15).
	State_requestAdminRooms(state, serverID)
	return true
}

State_closeServerSettings :: proc(state: ^State) {
	form := &state.serverSettings
	form.open = false
	form.serverID = 0
	form.confirmForgetKey = false
	form.confirmRemove = false
	ServerSettingsForm_setMessages(form, "", "")
	State_cancelAdminConfirm(state)
}

// Closes the screen when its server is no longer configured (removed in Settings or here).
State_closeServerSettingsIfServerGone :: proc(state: ^State) {
	if !state.serverSettings.open {
		return
	}
	if _, ok := State_serverConfig(state, state.serverSettings.serverID); !ok {
		State_closeServerSettings(state)
	}
}

// The validated fields of the Profile and Server sections. Strings borrow from the form, or
// are allocated with the temp allocator.
ServerSettingsInput :: struct {
	displayName: string, // "" uses the global display name
	label:       string,
	shortLabel:  string,
	host:        string,
	port:        i32,
}

// A one-line label: no control characters. Returns an empty error when valid.
@(private = "file")
serverSettingsLabelError :: proc(text, what: string, maxBytes: int) -> string {
	for index in 0 ..< len(text) {
		if text[index] < 0x20 || text[index] == 0x7f {
			return fmt.tprintf("The %s cannot contain line breaks or tabs.", what)
		}
	}
	if len(text) > maxBytes {
		return fmt.tprintf("The %s must be at most %d bytes long.", what, maxBytes)
	}
	return ""
}

// Checks the Profile and Server fields. An empty display name means the global one; an empty
// label is the address, and an empty short label is made from the label (getShortServerName),
// so a field cleared by mistake never leaves an empty rail button. Returns an empty error on
// success.
validateServerSettings :: proc(
	displayName, label, shortLabel, host, port: string,
) -> (
	input: ServerSettingsInput,
	errorMessage: string,
) {
	input.displayName = strings.trim_space(displayName)
	if len(input.displayName) > 0 {
		input.displayName, errorMessage = validateDisplayName(input.displayName)
		if len(errorMessage) > 0 {
			return
		}
	}
	hasServer: bool
	input.host, input.port, hasServer, errorMessage = validateServerAddress(host, port, true)
	if len(errorMessage) > 0 {
		return
	}
	input.label = strings.trim_space(label)
	if errorMessage = serverSettingsLabelError(input.label, "label", SERVER_LABEL_MAX_BYTES);
	   len(errorMessage) > 0 {
		return
	}
	input.shortLabel = strings.trim_space(shortLabel)
	if errorMessage = serverSettingsLabelError(
		input.shortLabel,
		"short label",
		SERVER_SHORT_LABEL_MAX_BYTES,
	); len(errorMessage) > 0 {
		return
	}
	if utf8.rune_count_in_string(input.shortLabel) > SERVER_SHORT_LABEL_MAX_RUNES {
		errorMessage = "The short label fits at most 3 characters on the rail."
		return
	}
	return
}

// Save: validates the Profile and Server sections and applies them to the server's config
// entry. A new address or a new effective display name reconnects this server only
// (State_reconfigureNetwork keeps every other server's session); a label alone reconnects
// nothing. Returns false (with the form's error set) when nothing was saved.
State_applyServerSettings :: proc(state: ^State) -> bool {
	form := &state.serverSettings
	server, ok := State_serverConfig(state, form.serverID)
	if !form.open || !ok {
		return false
	}
	form.confirmForgetKey = false
	form.confirmRemove = false
	input, errorMessage := validateServerSettings(
		string(form.displayName[:]),
		string(form.label[:]),
		string(form.shortLabel[:]),
		string(form.host[:]),
		string(form.port[:]),
	)
	if len(errorMessage) == 0 &&
	   State_serverAddressTaken(state, input.host, input.port, form.serverID) {
		errorMessage = "Another server in your list has that address."
	}
	if len(errorMessage) > 0 {
		ServerSettingsForm_setMessages(form, errorMessage, "")
		return false
	}

	// Copies, since the config strings they are compared with are replaced below.
	oldEffectiveName := strings.clone(
		Server_displayName(server^, state.config),
		context.temp_allocator,
	)
	oldName := strings.clone(server.name, context.temp_allocator)
	oldShort := strings.clone(server.short_name, context.temp_allocator)
	shortWasAutomatic := false
	{
		automatic := getShortServerName(oldName)
		defer delete(automatic)
		shortWasAutomatic = oldShort == automatic
	}

	if input.displayName != server.display_name {
		delete(server.display_name)
		server.display_name = strings.clone(input.displayName)
	}
	// Moves the server and lets an automatic label follow the address. A label the user
	// typed in this form wins over that below.
	addressChanged := Server_setAddress(server, input.host, input.port)
	label := input.label
	if len(label) == 0 {
		label = serverLabel(server.host, server.port, context.temp_allocator)
	}
	if label != oldName && label != server.name {
		delete(server.name)
		server.name = strings.clone(label)
	}
	shortLabel := input.shortLabel
	switch {
	case len(shortLabel) == 0:
		shortLabel = getShortServerName(server.name, context.temp_allocator)
	case shortLabel == oldShort && shortWasAutomatic && server.name != oldName:
		// The short label was made from the old label; make it from the new one.
		shortLabel = getShortServerName(server.name, context.temp_allocator)
	}
	if shortLabel != server.short_name {
		delete(server.short_name)
		server.short_name = strings.clone(shortLabel)
	}

	nameChanged := Server_displayName(server^, state.config) != oldEffectiveName
	serverID := form.serverID
	State_saveConfig(state)
	if addressChanged || nameChanged {
		State_reconfigureNetwork(state)
	}
	server, ok = State_serverConfig(state, serverID)
	if !ok {
		return true
	}
	ServerSettingsForm_load(form, server^)
	notice := "Saved."
	if addressChanged || nameChanged {
		notice = "Saved. Reconnecting to this server…"
	}
	ServerSettingsForm_setMessages(form, "", notice)
	return true
}

// Forget key: the first call arms it, the second clears the pinned key and reconnects this
// server, which then pins whatever key it presents (trust on first use, as for a new
// server). Use it when the server was reinstalled on purpose; a key that changed unexpectedly
// can mean someone is impersonating the server.
State_serverSettingsForgetKey :: proc(state: ^State) {
	form := &state.serverSettings
	server, ok := State_serverConfig(state, form.serverID)
	if !form.open || !ok || len(server.pinned_server_public_key) == 0 {
		return
	}
	form.confirmRemove = false
	if !form.confirmForgetKey {
		form.confirmForgetKey = true
		return
	}
	form.confirmForgetKey = false
	Server_setPins(server, "", "")
	State_saveConfig(state)
	// The transport no longer matches its config entry (ClientServerTransport_matchesConfig
	// compares the pin), so only this server reconnects.
	State_reconfigureNetwork(state)
	ServerSettingsForm_setMessages(
		form,
		"",
		"Key forgotten. The next connection pins the key the server presents.",
	)
}

// Remove server: the first call arms it, the second removes the server from the config and
// disconnects it, which closes this screen.
State_serverSettingsRemoveServer :: proc(state: ^State) {
	form := &state.serverSettings
	if !form.open {
		return
	}
	form.confirmForgetKey = false
	if !form.confirmRemove {
		form.confirmRemove = true
		return
	}
	State_settingsRemoveServer(state, form.serverID)
	State_closeServerSettingsIfServerGone(state)
}

// The button next to a connection banner's name problem: a name chosen for this server only
// is changed in its Server settings, the global one in Settings.
State_openNameSettings :: proc(state: ^State, serverID: int) {
	if server, ok := State_serverConfig(state, serverID); ok && len(server.display_name) > 0 {
		State_openServerSettings(state, serverID)
		return
	}
	State_openSettings(state)
}

// ── View model ────────────────────────────────────────────────────

// One user in the Voice section. label borrows from State or the view allocator.
ServerVoiceUserRow :: struct {
	userID:   int,
	label:    string,
	isOnline: bool,
	// In a voice room of this server right now (the server's participant lists).
	inVoice:  bool,
	volume:   f32, // Linear, 0..SERVER_USER_VOICE_VOLUME_MAX
	muted:    bool,
}

ServerSettingsView :: struct {
	visible:          bool,
	serverID:         int,
	title:            string,
	// The name this client signs in with now, for the Profile placeholder.
	globalName:       string,
	fingerprint:      string, // The pinned key's fingerprint, or "" when none is pinned
	hasPinnedKey:     bool,
	forgetKeyLabel:   string,
	removeLabel:      string,
	connected:        bool,
	// An admin renamed this account and locked the name (protocol 14, D3): the Profile section
	// shows lockedName, the name the server keeps, instead of the field.
	nameLocked:       bool,
	lockedName:       string,
	// Users for the Voice section: those in voice first, then the server's directory order
	// (online first, then by name), then users with a stored setting who are not in the
	// directory (the server is not connected yet).
	voiceUsers:       []ServerVoiceUserRow,
	voiceNote:        string,
	admin:            AdminSectionView,
	error:            string,
	notice:           string,
}

@(private = "file")
serverVoiceRowLess :: proc(a, b: ServerVoiceUserRow) -> bool {
	if a.inVoice != b.inVoice {
		return a.inVoice
	}
	return false
}

// Whether userID is in any voice room of serverID, as the server last listed them.
@(private = "file")
State_userIsInVoiceOnServer :: proc(state: ^State, serverID, userID: int) -> bool {
	for entry in state.voice.roomParticipants {
		if entry.serverID != serverID {
			continue
		}
		for participant in entry.participants {
			if participant.userId == userID {
				return true
			}
		}
	}
	return false
}

// The Voice section's rows for serverID, without the signed-in user. Labels borrow from
// State, so the result is valid only until State next changes.
buildServerVoiceUserRows :: proc(
	state: ^State,
	serverID: int,
	allocator := context.temp_allocator,
) -> []ServerVoiceUserRow {
	server, ok := State_serverConfig(state, serverID)
	if !ok {
		return nil
	}
	selfUserID := State_selfUserID(state, serverID)
	rows := make([dynamic]ServerVoiceUserRow, 0, allocator)
	if index := State_serverDirectCacheIndex(state^, serverID); index >= 0 {
		members := sortedMembers(state.serverDirectCaches[index].users[:], selfUserID, allocator)
		for member in members {
			volume, muted := Server_userVoice(server^, member.id)
			append(
				&rows,
				ServerVoiceUserRow {
					userID = member.id,
					label = userLabel(member.nickname, member.id, allocator),
					isOnline = member.isOnline,
					inVoice = State_userIsInVoiceOnServer(state, serverID, member.id),
					volume = volume,
					muted = muted,
				},
			)
		}
	}
	// Participants the directory does not list yet (a participant list can arrive first).
	for entry in state.voice.roomParticipants {
		if entry.serverID != serverID {
			continue
		}
		for participant in entry.participants {
			listed := participant.userId == selfUserID
			for row in rows {
				listed ||= row.userID == participant.userId
			}
			if listed {
				continue
			}
			volume, muted := Server_userVoice(server^, participant.userId)
			append(
				&rows,
				ServerVoiceUserRow {
					userID = participant.userId,
					label = userLabel(participant.nickname, participant.userId, allocator),
					isOnline = true,
					inVoice = true,
					volume = volume,
					muted = muted,
				},
			)
		}
	}
	// Stored settings for users this client cannot see right now, so they can be reset.
	for entry in server.user_voice {
		listed := entry.user_id == selfUserID
		for row in rows {
			listed ||= row.userID == entry.user_id
		}
		if listed {
			continue
		}
		append(
			&rows,
			ServerVoiceUserRow {
				userID = entry.user_id,
				label = userLabel("", entry.user_id, allocator),
				volume = serverUserVoiceVolume(entry),
				muted = entry.muted,
			},
		)
	}
	// Voice participants first; a stable sort keeps the directory order otherwise.
	slice.stable_sort_by(rows[:], serverVoiceRowLess)
	return rows[:]
}

// Builds the screen for the selected server, or a view with visible false when it is closed
// or open on another server. Strings borrow from State or the view allocator.
buildServerSettingsView :: proc(
	state: ^State,
	allocator := context.temp_allocator,
) -> (
	view: ServerSettingsView,
) {
	if !State_serverSettingsVisible(state) {
		return
	}
	form := &state.serverSettings
	server, ok := State_serverConfig(state, form.serverID)
	if !ok {
		return
	}
	view.visible = true
	view.serverID = form.serverID
	view.title = fmt.aprintf("%s settings", server.name, allocator = allocator)
	view.globalName = state.config.display_name
	view.fingerprint = server.pinned_server_fingerprint
	view.hasPinnedKey = len(server.pinned_server_public_key) > 0
	view.forgetKeyLabel = form.confirmForgetKey ? "Confirm forget key" : "Forget key"
	view.removeLabel = form.confirmRemove ? "Confirm remove" : "Remove server"
	view.connected = State_isServerConnected(state, form.serverID)
	if index := State_serverConnectionIndex(state^, form.serverID); index >= 0 && view.connected {
		connection := &state.serverConnections[index]
		view.nameLocked = connection.nicknameLocked
		view.lockedName = connection.nickname
	}
	view.admin = buildAdminSectionView(state, form.serverID, allocator)
	view.voiceUsers = buildServerVoiceUserRows(state, form.serverID, allocator)
	switch {
	case len(view.voiceUsers) > 0:
		view.voiceNote =
			"Only you hear these changes; the other person and the server are not told. " +
			"Mute for me stops playing their voice on this device."
	case view.connected:
		view.voiceNote = "Nobody else has an account on this server yet."
	case:
		view.voiceNote = "Connect to this server to see its users."
	}
	view.error = form.error
	view.notice = form.notice
	return
}
