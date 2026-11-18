package client

import "../common"
import "core:fmt"
import "core:strings"
import "ui"

// The Server settings screen (server_settings.odin), drawn in the main pane in place of the
// room. A scrolling centred column like the settings screen: Profile and Server share one
// Save button; the Voice section, the key and Remove server (last, below Voice) act at once.
//
// Widget IDs for GUI automation (all take the server ID; the voice ones also the user ID):
// server-settings (the sidebar header's gear), server-settings-name, -label, -short, -host,
// -port, -save, -close, -forget-key, -remove, server-voice-volume, server-voice-mute.
//
// The Admin section (admins only, admin_ui.odin), all with the server ID and then the user or
// room ID: admin-member-rename, admin-member-role (Make admin / Remove admin),
// admin-member-kick, admin-member-ban (Ban… / Unban); the open confirmation's
// admin-confirm-text, admin-confirm-lock (Rename only), admin-confirm, admin-confirm-cancel;
// admin-room-edit, admin-room-delete, and admin-room-create (server ID only).
//
// Roles (protocol 23, roles.odin; admins): admin-member-roles (the member's Roles… button,
// server and user ID), admin-member-role-toggle (server, user and role ID),
// admin-member-roles-close (server, user ID); admin-role-new (server ID), admin-role-edit
// (server, role ID), and in the open role form admin-role-name, admin-role-permission (server,
// role ID, then the ServerPermission value), admin-role-save, admin-role-delete and
// admin-role-cancel (server, role ID; 0 for a new role). Holders of ManageRooms or
// ManageRoomMembers see the section with the room list only.

SERVER_SETTINGS_COLUMN_WIDTH :: 520
SERVER_SETTINGS_SHORT_WIDTH :: 96
SERVER_SETTINGS_BUTTON_WIDTH :: 120
SERVER_SETTINGS_MUTE_WIDTH :: 132
SERVER_SETTINGS_VOLUME_TEXT_WIDTH :: 56
// Percent steps of the volume sliders.
SERVER_SETTINGS_VOLUME_STEP :: f32(0.05)

@(private = "file")
serverSettingsLabel :: proc(ctx: ^ui.Context, column: ^ui.Rect, text: string) {
	ui.label(ctx, ui.cutTop(column, ui.lineHeight(ctx)), text, ctx.theme.fgMuted, .Bold)
	_ = ui.cutTop(column, ui.dp(ctx, SETTINGS_LABEL_GAP))
}

@(private = "file")
serverSettingsHeading :: proc(ctx: ^ui.Context, column: ^ui.Rect, text: string) {
	ui.label(ctx, ui.cutTop(column, ui.lineHeight(ctx, .Bold) * 1.4), text, ctx.theme.fg, .Bold)
	ui.divider(ctx, ui.cutTop(column, max(1, ui.dp(ctx, 1))))
	_ = ui.cutTop(column, ui.dp(ctx, SETTINGS_LABEL_GAP * 2))
}

@(private = "file")
serverSettingsWrapped :: proc(ctx: ^ui.Context, column: ^ui.Rect, text: string, color: ui.Color) {
	if len(text) == 0 {
		return
	}
	height := ui.wrappedTextHeight(ctx, text, column.w)
	ui.wrappedLabel(ctx, ui.cutTop(column, height), text, color)
}

// A single-line field in r. Returns true when Enter was pressed in it.
@(private = "file")
serverSettingsField :: proc(
	ctx: ^ui.Context,
	r: ui.Rect,
	id: ui.ID,
	buffer: ^[dynamic]u8,
	placeholder: string,
	maxBytes: int,
) -> bool {
	result := ui.textInput(ctx, id, r, buffer, placeholder, maxBytes)
	// One line; Shift+Enter would otherwise insert a newline.
	for index := len(buffer) - 1; index >= 0; index -= 1 {
		if buffer[index] == '\n' || buffer[index] == '\r' {
			ordered_remove(buffer, index)
		}
	}
	return result.submitted
}

@(private = "file")
ServerSettingsButtonStyle :: enum u8 {
	Primary,
	Plain,
	Danger,
	DangerArmed,
}

@(private = "file")
serverSettingsButton :: proc(
	ctx: ^ui.Context,
	row: ^ui.Rect,
	id: ui.ID,
	text: string,
	style: ServerSettingsButtonStyle,
) -> bool {
	width := max(
		ui.dp(ctx, SERVER_SETTINGS_BUTTON_WIDTH),
		ui.textSize(ui.textGet(ctx, 0, .Bold, text)).x + ui.dp(ctx, ctx.theme.padding * 4),
	)
	rect := ui.cutLeft(row, width)
	_ = ui.cutLeft(row, ui.dp(ctx, PANEL_PADDING))
	options := ui.ButtonOptions {
		align = .Center,
	}
	switch style {
	case .Primary:
		options.font = .Bold
		options.color = ctx.theme.onPrimary
		options.background = ctx.theme.primary
	case .Plain:
		options.background = ctx.theme.hover
	case .Danger:
		options.color = ctx.theme.danger
		options.background = ctx.theme.hover
	case .DangerArmed:
		options.font = .Bold
		options.color = ctx.theme.onPrimary
		options.background = ctx.theme.danger
	}
	return ui.button(ctx, id, rect, text, options)
}

// What the Voice section asks for this frame.
@(private = "file")
ServerVoiceRowAction :: struct {
	userID:      int,
	setVolume:   bool,
	volume:      f32,
	persist:     bool,
	toggleMute:  bool,
	muted:       bool,
}

viewServerSettings :: proc(
	state: ^State,
	ctx: ^ui.Context,
	r: ui.Rect,
	banner: ^ConnectionBanner,
) {
	view := buildServerSettingsView(state)
	if !view.visible {
		return
	}
	form := &state.serverSettings
	serverID := view.serverID
	area := r
	closeID := ui.idOf("server-settings-close", serverID)
	closeClicked := viewHeader(ctx, &area, view.title, "", "Close", closeID)
	viewConnectionBanner(state, ctx, &area, banner)

	padding := ui.dp(ctx, 24)
	width := min(area.w - padding * 2, ui.dp(ctx, SERVER_SETTINGS_COLUMN_WIDTH))
	scrollID := ui.idOf("server-settings-scroll", serverID)
	if form.scrollToTop {
		ui.scrollState(ctx, scrollID)^ = {}
		form.scrollToTop = false
	}
	offset := ui.scrollBegin(ctx, scrollID, area, form.contentH)
	column := ui.Rect {
		area.x + (area.w - width) / 2,
		area.y + padding - offset,
		width,
		max(f32(1e6), area.h),
	}
	top := column.y
	sectionGap := ui.dp(ctx, SETTINGS_SECTION_GAP)
	gap := ui.dp(ctx, PANEL_PADDING)
	rowH := ui.dp(ctx, ROW_HEIGHT)
	submitted := false

	// ── Profile ──
	serverSettingsHeading(ctx, &column, "Profile")
	if view.nameLocked {
		// An admin renamed this account and locked the name (D3): the server keeps it
		// whatever name this client signs in with, so there is nothing to edit here.
		serverSettingsLabel(ctx, &column, "Name on this server")
		lockedRect := ui.cutTop(&column, ui.lineHeight(ctx, .Bold))
		ui.label(ctx, lockedRect, view.lockedName, ctx.theme.fg, .Bold)
		_ = ui.cutTop(&column, ui.dp(ctx, SETTINGS_LABEL_GAP))
		serverSettingsWrapped(ctx, &column, SERVER_SETTINGS_LOCKED_NAME_NOTE, ctx.theme.fgMuted)
	} else {
		serverSettingsLabel(ctx, &column, "Display name on this server")
		nameID := ui.idOf("server-settings-name", serverID)
		nameRect := ui.cutTop(
			&column,
			ui.textInputHeight(ctx, nameID, form.displayName[:], width),
		)
		namePlaceholder := fmt.tprintf("Your name everywhere else: %s", view.globalName)
		if serverSettingsField(
			ctx,
			nameRect,
			nameID,
			&form.displayName,
			namePlaceholder,
			DISPLAY_NAME_MAX_BYTES,
		) {
			submitted = true
		}
		_ = ui.cutTop(&column, ui.dp(ctx, SETTINGS_LABEL_GAP))
		serverSettingsWrapped(
			ctx,
			&column,
			"Leave it empty to use your name from Settings. Changing it renames you on this " +
			"server only and reconnects to it.",
			ctx.theme.fgMuted,
		)
	}
	_ = ui.cutTop(&column, sectionGap)

	// ── Server ──
	serverSettingsHeading(ctx, &column, "Server")
	{
		labels := ui.cutTop(&column, ui.lineHeight(ctx))
		shortW := ui.dp(ctx, SERVER_SETTINGS_SHORT_WIDTH)
		shortLabelRect := ui.cutRight(&labels, shortW)
		_ = ui.cutRight(&labels, gap)
		ui.label(ctx, labels, "Label", ctx.theme.fgMuted, .Bold)
		ui.label(ctx, shortLabelRect, "Short label", ctx.theme.fgMuted, .Bold)
		_ = ui.cutTop(&column, ui.dp(ctx, SETTINGS_LABEL_GAP))
		labelID := ui.idOf("server-settings-label", serverID)
		shortID := ui.idOf("server-settings-short", serverID)
		fieldH := ui.textInputHeight(ctx, labelID, form.label[:], width - shortW - gap)
		fields := ui.cutTop(&column, fieldH)
		shortRect := ui.cutRight(&fields, shortW)
		_ = ui.cutRight(&fields, gap)
		if serverSettingsField(
			ctx,
			fields,
			labelID,
			&form.label,
			"The server's address",
			SERVER_LABEL_MAX_BYTES,
		) {
			submitted = true
		}
		if serverSettingsField(
			ctx,
			shortRect,
			shortID,
			&form.shortLabel,
			"Auto",
			SERVER_SHORT_LABEL_MAX_BYTES,
		) {
			submitted = true
		}
		_ = ui.cutTop(&column, ui.dp(ctx, SETTINGS_LABEL_GAP))
		serverSettingsWrapped(
			ctx,
			&column,
			"The label names the server in headers; the short label (up to 3 characters) is " +
			"its rail button. Empty fields are filled in from the address.",
			ctx.theme.fgMuted,
		)
		_ = ui.cutTop(&column, sectionGap)
	}
	{
		serverSettingsLabel(ctx, &column, "Address")
		hostID := ui.idOf("server-settings-host", serverID)
		portID := ui.idOf("server-settings-port", serverID)
		portW := ui.dp(ctx, SETTINGS_PORT_WIDTH)
		fieldH := ui.textInputHeight(ctx, hostID, form.host[:], width - portW - gap)
		fields := ui.cutTop(&column, fieldH)
		portRect := ui.cutRight(&fields, portW)
		_ = ui.cutRight(&fields, gap)
		if serverSettingsField(
			ctx,
			fields,
			hostID,
			&form.host,
			"Host name or IP address",
			SERVER_HOST_MAX_BYTES,
		) {
			submitted = true
		}
		if serverSettingsField(ctx, portRect, portID, &form.port, "Port", SERVER_PORT_MAX_BYTES) {
			submitted = true
		}
		_ = ui.cutTop(&column, ui.dp(ctx, SETTINGS_LABEL_GAP))
		serverSettingsWrapped(
			ctx,
			&column,
			"A new address is a new server to HayChat: it reconnects, and the key is pinned " +
			"again on the first connection.",
			ctx.theme.fgMuted,
		)
	}
	if len(view.error) > 0 {
		_ = ui.cutTop(&column, ui.dp(ctx, PANEL_PADDING))
		serverSettingsWrapped(ctx, &column, view.error, ctx.theme.danger)
	} else if len(view.notice) > 0 {
		_ = ui.cutTop(&column, ui.dp(ctx, PANEL_PADDING))
		serverSettingsWrapped(ctx, &column, view.notice, ctx.theme.success)
	}
	_ = ui.cutTop(&column, sectionGap)
	saveRow := ui.cutTop(&column, ui.dp(ctx, ROW_HEIGHT + 4))
	saveID := ui.idOf("server-settings-save", serverID)
	if serverSettingsButton(ctx, &saveRow, saveID, "Save", .Primary) {
		submitted = true
	}
	_ = ui.cutTop(&column, sectionGap)

	// ── Voice ──
	serverSettingsHeading(ctx, &column, "Voice")
	serverSettingsWrapped(ctx, &column, view.voiceNote, ctx.theme.fgMuted)
	_ = ui.cutTop(&column, ui.dp(ctx, SETTINGS_LABEL_GAP * 2))
	voiceAction: ServerVoiceRowAction
	for row in view.voiceUsers {
		line := ui.cutTop(&column, rowH)
		muteW := ui.dp(ctx, SERVER_SETTINGS_MUTE_WIDTH)
		muteRect := ui.cutRight(&line, muteW)
		_ = ui.cutRight(&line, gap)
		valueRect := ui.cutRight(&line, ui.dp(ctx, SERVER_SETTINGS_VOLUME_TEXT_WIDTH))
		_ = ui.cutRight(&line, gap)
		nameW := min(line.w * 0.4, ui.dp(ctx, 160))
		nameRect := ui.cutLeft(&line, nameW)
		_ = ui.cutLeft(&line, gap)
		{
			ui.pushClip(ctx, nameRect)
			defer ui.popClip(ctx)
			nameText := row.label
			if row.inVoice {
				nameText = fmt.tprintf("%s %s", VOICE_SPEAKER_ICON, row.label)
			}
			nameColor := row.isOnline || row.inVoice ? ctx.theme.fg : ctx.theme.fgMuted
			ui.label(ctx, nameRect, nameText, nameColor)
		}
		trackH := ui.dp(ctx, VOICE_SLIDER_HEIGHT)
		track := ui.Rect{line.x, line.y + (line.h - trackH) / 2, line.w, trackH}
		slider := ui.slider(
			ctx,
			ui.idOf("server-voice-volume", serverID, row.userID),
			track,
			row.volume,
			0,
			SERVER_USER_VOICE_VOLUME_MAX,
			SERVER_SETTINGS_VOLUME_STEP,
		)
		percent := int(slider.value * 100 + 0.5)
		valueColor := row.muted ? ctx.theme.fgMuted : ctx.theme.fg
		ui.label(ctx, valueRect, fmt.tprintf("%d %%", percent), valueColor, align = .Center)
		muteOptions := ui.ButtonOptions {
			align      = .Center,
			selected   = row.muted,
			color      = row.muted ? ctx.theme.danger : ctx.theme.fgMuted,
			background = ctx.theme.hover,
		}
		muteText := row.muted ? "Muted for me" : "Mute for me"
		muteID := ui.idOf("server-voice-mute", serverID, row.userID)
		if ui.button(ctx, muteID, muteRect, muteText, muteOptions) {
			voiceAction = {userID = row.userID, toggleMute = true, muted = !row.muted}
		}
		if slider.changed || slider.released {
			voiceAction = {
				userID    = row.userID,
				setVolume = true,
				volume    = slider.value,
				// Saved once, when the slider is let go, not on every frame of a drag.
				persist   = slider.released,
			}
		}
		_ = ui.cutTop(&column, ui.dp(ctx, ROW_SPACING * 2))
	}

	_ = ui.cutTop(&column, sectionGap)

	// ── Admin (admins only) ──
	adminAction: AdminSectionAction
	if view.admin.visible {
		adminAction = viewAdminSection(state, ctx, &column, view.admin, serverID, area, scrollID)
		_ = ui.cutTop(&column, sectionGap)
	}

	// ── Key and removal, last: rarely needed and not undone by Close ──
	serverSettingsLabel(ctx, &column, "Server key")
	fingerprintText := "No key pinned yet. The next connection pins the key the server presents."
	if view.hasPinnedKey {
		fingerprintText = fmt.tprintf(
			"Fingerprint: %s",
			len(view.fingerprint) > 0 ? view.fingerprint : "unknown",
		)
	}
	serverSettingsWrapped(ctx, &column, fingerprintText, ctx.theme.fg)
	forgetClicked := false
	if view.hasPinnedKey {
		_ = ui.cutTop(&column, ui.dp(ctx, SETTINGS_LABEL_GAP))
		serverSettingsWrapped(
			ctx,
			&column,
			"Forget the key only when the server was reinstalled on purpose. A key that " +
			"changed unexpectedly can mean someone is impersonating the server.",
			ctx.theme.fgMuted,
		)
		_ = ui.cutTop(&column, ui.dp(ctx, SETTINGS_LABEL_GAP))
		keyRow := ui.cutTop(&column, ui.dp(ctx, ROW_HEIGHT + 4))
		forgetClicked = serverSettingsButton(
			ctx,
			&keyRow,
			ui.idOf("server-settings-forget-key", serverID),
			view.forgetKeyLabel,
			form.confirmForgetKey ? .DangerArmed : .Danger,
		)
	}
	_ = ui.cutTop(&column, sectionGap)
	serverSettingsLabel(ctx, &column, "Remove")
	serverSettingsWrapped(
		ctx,
		&column,
		"Removes the server from this device. Your account stays on the server.",
		ctx.theme.fgMuted,
	)
	_ = ui.cutTop(&column, ui.dp(ctx, SETTINGS_LABEL_GAP))
	removeRow := ui.cutTop(&column, ui.dp(ctx, ROW_HEIGHT + 4))
	removeClicked := serverSettingsButton(
		ctx,
		&removeRow,
		ui.idOf("server-settings-remove", serverID),
		view.removeLabel,
		form.confirmRemove ? .DangerArmed : .Danger,
	)
	_ = ui.cutTop(&column, sectionGap)

	contentH := column.y + sectionGap - top
	ui.scrollEnd(ctx, scrollID, area)
	if contentH != form.contentH {
		form.contentH = contentH
		ui.requestFrame(ctx)
	}

	// Actions run last: they can replace the config strings and the lists drawn above.
	switch {
	case voiceAction.setVolume:
		State_setUserVoiceVolume(
			state,
			serverID,
			voiceAction.userID,
			voiceAction.volume,
			voiceAction.persist,
		)
	case voiceAction.toggleMute:
		State_setUserVoiceMuted(state, serverID, voiceAction.userID, voiceAction.muted)
	}
	switch adminAction.kind {
	case .None:
	case .OpenConfirm:
		State_openAdminConfirm(state, serverID, adminAction.confirmKind, adminAction.userID)
	case .CancelConfirm:
		State_cancelAdminConfirm(state)
	case .SubmitConfirm:
		State_submitAdminConfirm(state)
	case .ToggleLock:
		State_toggleAdminConfirmLock(state)
	case .SetRole:
		State_adminSetRole(state, serverID, adminAction.userID, adminAction.grant)
	case .Unban:
		State_adminUnban(state, serverID, adminAction.userID)
	case .EditRoom:
		State_openRoomEditor(state, adminAction.roomID)
		return
	case .DeleteRoom:
		State_openRoomEditorForDelete(state, adminAction.roomID)
		return
	case .CreateRoom:
		State_openRoomCreator(state)
		return
	case .RoomMembers:
		State_openRoomMembers(state, serverID, adminAction.roomID)
		return
	case .OpenMemberRoles:
		if state.serverSettings.memberRolesUserID == adminAction.userID {
			State_closeMemberRoles(state)
		} else {
			State_openMemberRoles(state, serverID, adminAction.userID)
		}
	case .CloseMemberRoles:
		State_closeMemberRoles(state)
	case .ToggleMemberRole:
		State_toggleMemberRole(state, serverID, adminAction.userID, adminAction.roleID)
	case .OpenRoleEditor:
		State_openRoleEditor(state, serverID, adminAction.roleID)
	case .CloseRoleEditor:
		State_closeRoleEditor(state)
	case .SubmitRoleEditor:
		State_submitRoleEditor(state)
	case .DeleteRole:
		State_deleteRoleEditorRole(state)
	case .ToggleRolePermission:
		State_toggleRoleEditorPermission(state, adminAction.permission)
	}
	switch {
	case closeClicked:
		State_closeServerSettings(state)
	case removeClicked:
		State_serverSettingsRemoveServer(state)
	case forgetClicked:
		State_serverSettingsForgetKey(state)
	case submitted:
		State_applyServerSettings(state)
	}
}

SERVER_SETTINGS_LOCKED_NAME_NOTE ::
	"Set by an admin of this server. It stays this way whatever name you choose in Settings."

// What the Admin section asks for this frame; viewServerSettings runs it after drawing.
@(private = "file")
AdminSectionActionKind :: enum u8 {
	None,
	OpenConfirm,
	CancelConfirm,
	SubmitConfirm,
	ToggleLock,
	SetRole,
	Unban,
	EditRoom,
	DeleteRoom,
	CreateRoom,
	RoomMembers,
	// Protocol 23 (roles.odin).
	OpenMemberRoles,
	CloseMemberRoles,
	ToggleMemberRole,
	OpenRoleEditor,
	CloseRoleEditor,
	SubmitRoleEditor,
	DeleteRole,
	ToggleRolePermission,
}

@(private = "file")
AdminSectionAction :: struct {
	kind:        AdminSectionActionKind,
	confirmKind: AdminConfirmKind,
	userID:      int,
	roomID:      int,
	grant:       bool,
	roleID:      int,
	permission:  common.ServerPermission,
}

// A small button laid out from the left of row. A disabled control is drawn muted, never
// clicks, and says why in its tooltip.
@(private = "file")
adminButton :: proc(
	ctx: ^ui.Context,
	row: ^ui.Rect,
	id: ui.ID,
	control: AdminControl,
	danger := false,
) -> bool {
	width := ui.textSize(ui.textGet(ctx, 0, .Regular, control.label)).x
	width += ui.dp(ctx, ctx.theme.padding * 3)
	rect := ui.cutLeft(row, width)
	_ = ui.cutLeft(row, ui.dp(ctx, PANEL_PADDING / 2))
	if !control.enabled {
		ui.fillRoundedRect(ctx, rect, ui.dp(ctx, ctx.theme.cornerRadius), ctx.theme.surface)
		ui.label(ctx, rect, control.label, ctx.theme.fgMuted, align = .Center)
		if len(control.reason) > 0 {
			ui.tooltip(ctx, id, rect, control.reason)
		}
		return false
	}
	options := ui.ButtonOptions {
		align      = .Center,
		color      = danger ? ctx.theme.danger : ctx.theme.fg,
		background = ctx.theme.hover,
	}
	return ui.button(ctx, id, rect, control.label, options)
}

// A small pill after a member's name ("Admin", "Banned"), laid out from the left of row.
@(private = "file")
adminBadge :: proc(ctx: ^ui.Context, row: ^ui.Rect, text: string, color: ui.Color) {
	badgeH := ui.dp(ctx, 18)
	badgeW := ui.textSize(ui.textGet(ctx, 0, .Bold, text)).x + ui.dp(ctx, 12)
	slot := ui.cutLeft(row, badgeW)
	_ = ui.cutLeft(row, ui.dp(ctx, 6))
	badge := ui.Rect{slot.x, slot.y + (slot.h - badgeH) / 2, badgeW, badgeH}
	ui.fillRoundedRect(ctx, badge, badgeH / 2, color)
	ui.label(ctx, badge, text, ctx.theme.onPrimary, .Bold, .Center)
}

// Draws the Admin section into column and returns what was clicked. scrollID and area are the
// screen's scroll area, which it scrolls to an open confirmation that a menu asked for.
@(private = "file")
viewAdminSection :: proc(
	state: ^State,
	ctx: ^ui.Context,
	column: ^ui.Rect,
	view: AdminSectionView,
	serverID: int,
	area: ui.Rect,
	scrollID: ui.ID,
) -> (
	action: AdminSectionAction,
) {
	form := &state.serverSettings
	gap := ui.dp(ctx, PANEL_PADDING)
	rowH := ui.dp(ctx, ROW_HEIGHT)
	serverSettingsHeading(ctx, column, "Admin")
	serverSettingsWrapped(ctx, column, view.note, ctx.theme.fgMuted)
	statusOnRow := false
	for member in view.members {
		statusOnRow ||= member.userID == view.statusUserID
	}
	if !statusOnRow {
		viewAdminStatus(ctx, column, view)
	}
	_ = ui.cutTop(column, ui.dp(ctx, SETTINGS_LABEL_GAP * 2))

	if view.showMembers {
		serverSettingsLabel(ctx, column, "Members")
	}
	for member in view.members {
		rowTop := column.y
		// Line 1: online dot, name, badges.
		{
			line := ui.cutTop(column, rowH)
			dotSize := ui.dp(ctx, 8)
			dot := ui.Rect{line.x, line.y + (line.h - dotSize) / 2, dotSize, dotSize}
			dotColor := member.isOnline ? ctx.theme.success : ctx.theme.border
			ui.fillRoundedRect(ctx, dot, dotSize / 2, dotColor)
			_ = ui.cutLeft(&line, dotSize + gap)
			badgesW: f32 = 0
			if member.isAdmin {
				badgesW += ui.textSize(ui.textGet(ctx, 0, .Bold, "Admin")).x + ui.dp(ctx, 18)
			}
			if member.isBanned {
				badgesW += ui.textSize(ui.textGet(ctx, 0, .Bold, "Banned")).x + ui.dp(ctx, 18)
			}
			nameW := min(ui.textSize(ui.textGet(ctx, 0, .Bold, member.label)).x, line.w - badgesW)
			nameRect := ui.cutLeft(&line, max(0, nameW))
			_ = ui.cutLeft(&line, gap)
			{
				ui.pushClip(ctx, nameRect)
				defer ui.popClip(ctx)
				nameColor := member.isOnline ? ctx.theme.fg : ctx.theme.fgMuted
				ui.label(ctx, nameRect, member.label, nameColor, .Bold)
			}
			if member.isAdmin {
				adminBadge(ctx, &line, "Admin", ctx.theme.primary)
			}
			if member.isBanned {
				adminBadge(ctx, &line, "Banned", ctx.theme.danger)
			}
		}
		// Protocol 23: its roles other than admin, under the name.
		if len(member.roleNames) > 0 {
			line := ui.cutTop(column, ui.lineHeight(ctx))
			_ = ui.cutLeft(&line, ui.dp(ctx, 8) + gap)
			names := strings.join(member.roleNames, ", ", context.temp_allocator)
			text := fmt.tprintf("Roles: %s", names)
			ui.pushClip(ctx, line)
			ui.label(ctx, line, text, ctx.theme.fgMuted)
			ui.popClip(ctx)
		}
		// Line 2: the controls.
		{
			line := ui.cutTop(column, rowH)
			_ = ui.cutLeft(&line, ui.dp(ctx, 8) + gap)
			userID := member.userID
			if adminButton(
				ctx,
				&line,
				ui.idOf("admin-member-rename", serverID, userID),
				member.rename,
			) {
				action = {kind = .OpenConfirm, confirmKind = .Rename, userID = userID}
			}
			roleID := ui.idOf("admin-member-role", serverID, userID)
			if adminButton(ctx, &line, roleID, member.role) {
				action = {kind = .SetRole, userID = userID, grant = member.grant}
			}
			if adminButton(
				ctx,
				&line,
				ui.idOf("admin-member-kick", serverID, userID),
				member.kick,
				danger = true,
			) {
				action = {kind = .OpenConfirm, confirmKind = .Kick, userID = userID}
			}
			if adminButton(
				ctx,
				&line,
				ui.idOf("admin-member-ban", serverID, userID),
				member.ban,
				danger = member.banning,
			) {
				if member.banning {
					action = {kind = .OpenConfirm, confirmKind = .Ban, userID = userID}
				} else {
					action = {kind = .Unban, userID = userID}
				}
			}
			if adminButton(
				ctx,
				&line,
				ui.idOf("admin-member-roles", serverID, userID),
				member.rolesControl,
			) {
				action = {kind = .OpenMemberRoles, userID = userID}
			}
		}
		if member.rolesOpen {
			_ = ui.cutTop(column, ui.dp(ctx, SETTINGS_LABEL_GAP))
			if rolesAction := viewAdminMemberRoles(ctx, column, member, serverID);
			   rolesAction.kind != .None {
				action = rolesAction
			}
			if form.adminConfirm.scrollTo {
				adminScrollIntoView(ctx, form, scrollID, area, rowTop, column.y)
			}
		}
		if statusOnRow && member.userID == view.statusUserID {
			_ = ui.cutTop(column, ui.dp(ctx, ROW_SPACING))
			viewAdminStatus(ctx, column, view, ui.dp(ctx, 8) + gap)
		}
		if view.confirm.kind != .None && view.confirm.userID == member.userID {
			_ = ui.cutTop(column, ui.dp(ctx, SETTINGS_LABEL_GAP))
			if confirmAction := viewAdminConfirm(state, ctx, column, view.confirm, serverID);
			   confirmAction.kind != .None {
				action = confirmAction
			}
			// Opened from a menu: bring the member and the confirmation into view.
			if form.adminConfirm.scrollTo {
				adminScrollIntoView(ctx, form, scrollID, area, rowTop, column.y)
			}
		}
		_ = ui.cutTop(column, ui.dp(ctx, SETTINGS_LABEL_GAP * 2))
	}
	if view.showMembers && len(view.members) == 0 {
		serverSettingsWrapped(
			ctx,
			column,
			"The member list has not arrived yet.",
			ctx.theme.fgMuted,
		)
	}

	if view.showRoles {
		_ = ui.cutTop(column, ui.dp(ctx, SETTINGS_SECTION_GAP))
		if rolesAction := viewAdminRoles(state, ctx, column, view, serverID);
		   rolesAction.kind != .None {
			action = rolesAction
		}
	}

	if !view.showRooms {
		return
	}
	_ = ui.cutTop(column, ui.dp(ctx, SETTINGS_SECTION_GAP))
	{
		header := ui.cutTop(column, rowH)
		createControl := AdminControl{label = "Create room…", enabled = view.canManageRooms}
		if !view.canManageRooms {
			createControl.reason = ADMIN_ROOMS_MANAGE_REASON
		}
		createW := ui.textSize(ui.textGet(ctx, 0, .Regular, createControl.label)).x
		createW += ui.dp(ctx, ctx.theme.padding * 3)
		createRect := header
		_ = ui.cutLeft(&createRect, header.w - createW)
		if adminButton(ctx, &createRect, ui.idOf("admin-room-create", serverID), createControl) {
			action = {kind = .CreateRoom}
		}
		ui.label(ctx, header, "Rooms", ctx.theme.fgMuted, .Bold)
		_ = ui.cutTop(column, ui.dp(ctx, SETTINGS_LABEL_GAP))
	}
	for room in view.rooms {
		line := ui.cutTop(column, rowH)
		membersControl := AdminControl{label = "Members…", enabled = view.canManageRoomMembers}
		editControl := AdminControl{label = "Edit…", enabled = view.canManageRooms}
		deleteControl := AdminControl{label = "Delete…", enabled = view.canManageRooms}
		if !view.canManageRoomMembers {
			membersControl.reason = ADMIN_ROOMS_MEMBERS_REASON
		}
		if !view.canManageRooms {
			editControl.reason = ADMIN_ROOMS_MANAGE_REASON
			deleteControl.reason = ADMIN_ROOMS_MANAGE_REASON
		}
		buttonsW :=
			ui.textSize(ui.textGet(ctx, 0, .Regular, membersControl.label)).x +
			ui.textSize(ui.textGet(ctx, 0, .Regular, editControl.label)).x +
			ui.textSize(ui.textGet(ctx, 0, .Regular, deleteControl.label)).x +
			ui.dp(ctx, ctx.theme.padding * 9 + PANEL_PADDING * 2)
		buttons := ui.cutRight(&line, buttonsW)
		membersID := ui.idOf("admin-room-members", serverID, room.roomID)
		if adminButton(ctx, &buttons, membersID, membersControl) {
			action = {kind = .RoomMembers, roomID = room.roomID}
		}
		editID := ui.idOf("admin-room-edit", serverID, room.roomID)
		if adminButton(ctx, &buttons, editID, editControl) {
			action = {kind = .EditRoom, roomID = room.roomID}
		}
		if adminButton(
			ctx,
			&buttons,
			ui.idOf("admin-room-delete", serverID, room.roomID),
			deleteControl,
			danger = true,
		) {
			action = {kind = .DeleteRoom, roomID = room.roomID}
		}
		_ = ui.cutRight(&line, gap)
		typeW := ui.textSize(ui.textGet(ctx, 0, .Regular, room.typeLabel)).x
		typeRect := ui.cutRight(&line, typeW)
		_ = ui.cutRight(&line, gap)
		ui.label(ctx, typeRect, room.typeLabel, ctx.theme.fgMuted)
		{
			ui.pushClip(ctx, line)
			defer ui.popClip(ctx)
			ui.label(ctx, line, room.label, room.isMember ? ctx.theme.fg : ctx.theme.fgMuted)
		}
		if len(room.accessLabel) > 0 {
			accessLine := ui.cutTop(column, ui.lineHeight(ctx))
			_ = ui.cutLeft(&accessLine, ui.dp(ctx, 12))
			ui.label(ctx, accessLine, room.accessLabel, ctx.theme.fgMuted)
		}
		_ = ui.cutTop(column, ui.dp(ctx, ROW_SPACING * 2))
	}
	if len(view.rooms) == 0 {
		serverSettingsWrapped(ctx, column, "No rooms yet.", ctx.theme.fgMuted)
	}
	return
}

ADMIN_ROOMS_MANAGE_REASON :: "Needs a role that manages rooms."
ADMIN_ROOMS_MEMBERS_REASON :: "Needs a role that manages room members."

// A checkbox row: a box, ticked when checked, and the label, the whole row one button. A
// disabled one is drawn muted and never clicks.
@(private = "file")
adminCheckbox :: proc(
	ctx: ^ui.Context,
	column: ^ui.Rect,
	id: ui.ID,
	label: string,
	checked, enabled: bool,
) -> bool {
	row := ui.cutTop(column, ui.dp(ctx, ROW_HEIGHT))
	clicked := false
	if enabled {
		clicked = ui.button(ctx, id, row, "", ui.ButtonOptions{align = .Left})
	}
	size := ui.dp(ctx, 16)
	pad := ui.dp(ctx, ctx.theme.padding)
	box := ui.Rect{row.x + pad, row.y + (row.h - size) / 2, size, size}
	radius := ui.dp(ctx, 3)
	ui.fillRoundedRect(ctx, box, radius, enabled ? ctx.theme.fgMuted : ctx.theme.border)
	inner := ui.shrink(box, max(1, ui.dp(ctx, 2)))
	ui.fillRoundedRect(ctx, inner, radius, checked ? ctx.theme.primary : ctx.theme.elevated)
	text := row
	_ = ui.cutLeft(&text, pad + size + ui.dp(ctx, 8))
	ui.label(ctx, text, label, enabled ? ctx.theme.fg : ctx.theme.fgMuted)
	return clicked
}

// A bordered box of height boxH cut from column, returning its padded inside.
@(private = "file")
adminBox :: proc(ctx: ^ui.Context, column: ^ui.Rect, boxH: f32) -> ui.Rect {
	padding := ui.dp(ctx, PANEL_PADDING * 1.5)
	box := ui.cutTop(column, boxH)
	ui.fillRoundedRect(ctx, box, ui.dp(ctx, ctx.theme.cornerRadius), ctx.theme.border)
	ui.fillRoundedRect(
		ctx,
		ui.shrink(box, max(1, ui.dp(ctx, 1))),
		ui.dp(ctx, ctx.theme.cornerRadius),
		ctx.theme.elevated,
	)
	return ui.shrink(box, padding)
}

// The role picker under a member: one checkbox per role other than admin, and Done.
@(private = "file")
viewAdminMemberRoles :: proc(
	ctx: ^ui.Context,
	column: ^ui.Rect,
	member: AdminMemberRow,
	serverID: int,
) -> (
	action: AdminSectionAction,
) {
	padding := ui.dp(ctx, PANEL_PADDING * 1.5)
	labelGap := ui.dp(ctx, SETTINGS_LABEL_GAP)
	rowH := ui.dp(ctx, ROW_HEIGHT)
	boxH := padding * 2 + ui.lineHeight(ctx, .Bold) + labelGap
	boxH += f32(len(member.roles)) * rowH + labelGap * 2 + rowH
	inner := adminBox(ctx, column, boxH)
	title := fmt.tprintf("Roles of %s", member.label)
	ui.label(ctx, ui.cutTop(&inner, ui.lineHeight(ctx, .Bold)), title, ctx.theme.fg, .Bold)
	_ = ui.cutTop(&inner, labelGap)
	userID := member.userID
	for role in member.roles {
		if adminCheckbox(
			ctx,
			&inner,
			ui.idOf("admin-member-role-toggle", serverID, userID, role.roleID),
			role.name,
			role.held,
			true,
		) {
			action = {kind = .ToggleMemberRole, userID = userID, roleID = role.roleID}
		}
	}
	_ = ui.cutTop(&inner, labelGap * 2)
	buttons := ui.cutTop(&inner, rowH)
	if serverSettingsButton(
		ctx,
		&buttons,
		ui.idOf("admin-member-roles-close", serverID, userID),
		"Done",
		.Plain,
	) {
		action = {kind = .CloseMemberRoles, userID = userID}
	}
	return
}

// Roles: every role with what it allows and how many accounts hold it, New role…, and the
// open role form under its role (or under the header for a new one).
@(private = "file")
viewAdminRoles :: proc(
	state: ^State,
	ctx: ^ui.Context,
	column: ^ui.Rect,
	view: AdminSectionView,
	serverID: int,
) -> (
	action: AdminSectionAction,
) {
	rowH := ui.dp(ctx, ROW_HEIGHT)
	gap := ui.dp(ctx, PANEL_PADDING)
	{
		header := ui.cutTop(column, rowH)
		newControl := AdminControl{label = "New role…", enabled = true}
		newW := ui.textSize(ui.textGet(ctx, 0, .Regular, newControl.label)).x
		newW += ui.dp(ctx, ctx.theme.padding * 3)
		newRect := header
		_ = ui.cutLeft(&newRect, header.w - newW)
		if adminButton(ctx, &newRect, ui.idOf("admin-role-new", serverID), newControl) {
			action = {kind = .OpenRoleEditor}
		}
		ui.label(ctx, header, "Roles", ctx.theme.fgMuted, .Bold)
		_ = ui.cutTop(column, ui.dp(ctx, SETTINGS_LABEL_GAP))
	}
	if view.roleEditor.open && view.roleEditor.roleID == 0 {
		if editorAction := viewAdminRoleEditor(state, ctx, column, view.roleEditor, serverID);
		   editorAction.kind != .None {
			action = editorAction
		}
		_ = ui.cutTop(column, ui.dp(ctx, SETTINGS_LABEL_GAP * 2))
	}
	for role in view.roles {
		line := ui.cutTop(column, rowH)
		editControl := AdminControl{label = "Edit…", enabled = true}
		editW := ui.textSize(ui.textGet(ctx, 0, .Regular, editControl.label)).x
		editW += ui.dp(ctx, ctx.theme.padding * 3)
		buttons := ui.cutRight(&line, editW)
		editID := ui.idOf("admin-role-edit", serverID, role.roleID)
		if adminButton(ctx, &buttons, editID, editControl) {
			action = {kind = .OpenRoleEditor, roleID = role.roleID}
		}
		_ = ui.cutRight(&line, gap)
		holders := fmt.tprintf("%d %s", role.holders, role.holders == 1 ? "account" : "accounts")
		holdersW := ui.textSize(ui.textGet(ctx, 0, .Regular, holders)).x
		holdersRect := ui.cutRight(&line, holdersW)
		_ = ui.cutRight(&line, gap)
		ui.label(ctx, holdersRect, holders, ctx.theme.fgMuted)
		{
			ui.pushClip(ctx, line)
			defer ui.popClip(ctx)
			ui.label(ctx, line, role.name, ctx.theme.fg, .Bold)
		}
		permissionsLine := ui.cutTop(column, ui.lineHeight(ctx))
		_ = ui.cutLeft(&permissionsLine, ui.dp(ctx, 12))
		ui.pushClip(ctx, permissionsLine)
		ui.label(ctx, permissionsLine, role.permissionsLabel, ctx.theme.fgMuted)
		ui.popClip(ctx)
		if view.roleEditor.open && view.roleEditor.roleID == role.roleID {
			_ = ui.cutTop(column, ui.dp(ctx, SETTINGS_LABEL_GAP))
			if editorAction := viewAdminRoleEditor(state, ctx, column, view.roleEditor, serverID);
			   editorAction.kind != .None {
				action = editorAction
			}
		}
		_ = ui.cutTop(column, ui.dp(ctx, ROW_SPACING * 2))
	}
	if len(view.roles) == 0 {
		serverSettingsWrapped(ctx, column, "The role list has not arrived yet.", ctx.theme.fgMuted)
	}
	return
}

// The role form: the name (fixed for the built-in role), one checkbox per delegable
// permission, a note, and Create or Save, Delete… and Cancel.
@(private = "file")
viewAdminRoleEditor :: proc(
	state: ^State,
	ctx: ^ui.Context,
	column: ^ui.Rect,
	view: RoleEditorView,
	serverID: int,
) -> (
	action: AdminSectionAction,
) {
	editor := &state.serverSettings.roleEditor
	padding := ui.dp(ctx, PANEL_PADDING * 1.5)
	labelGap := ui.dp(ctx, SETTINGS_LABEL_GAP)
	rowH := ui.dp(ctx, ROW_HEIGHT)
	innerW := column.w - padding * 2
	roleID := view.roleID
	nameID := ui.idOf("admin-role-name", serverID, roleID)
	inputH := ui.textInputHeight(ctx, nameID, editor.name[:], innerW)
	noteH := ui.wrappedTextHeight(ctx, view.note, innerW)
	boxH := padding * 2 + ui.lineHeight(ctx, .Bold) + labelGap
	if !view.builtin {
		boxH += ui.lineHeight(ctx) + labelGap + inputH + labelGap
	}
	boxH += ui.lineHeight(ctx) + labelGap
	boxH += f32(len(view.permissions)) * rowH + labelGap
	boxH += noteH + labelGap * 2 + rowH
	inner := adminBox(ctx, column, boxH)
	ui.label(ctx, ui.cutTop(&inner, ui.lineHeight(ctx, .Bold)), view.title, ctx.theme.fg, .Bold)
	_ = ui.cutTop(&inner, labelGap)
	if !view.builtin {
		ui.label(ctx, ui.cutTop(&inner, ui.lineHeight(ctx)), "Name", ctx.theme.fgMuted)
		_ = ui.cutTop(&inner, labelGap)
		if serverSettingsField(
			ctx,
			ui.cutTop(&inner, inputH),
			nameID,
			&editor.name,
			"Room keepers",
			common.ROLE_NAME_MAX_BYTES,
		) {
			action = {kind = .SubmitRoleEditor, roleID = roleID}
		}
		_ = ui.cutTop(&inner, labelGap)
	}
	ui.label(ctx, ui.cutTop(&inner, ui.lineHeight(ctx)), "Permissions", ctx.theme.fgMuted)
	_ = ui.cutTop(&inner, labelGap)
	for row in view.permissions {
		if adminCheckbox(
			ctx,
			&inner,
			ui.idOf("admin-role-permission", serverID, roleID, int(row.permission)),
			row.label,
			row.checked,
			row.enabled,
		) {
			action = {kind = .ToggleRolePermission, roleID = roleID, permission = row.permission}
		}
	}
	_ = ui.cutTop(&inner, labelGap)
	serverSettingsWrapped(ctx, &inner, view.note, ctx.theme.fgMuted)
	_ = ui.cutTop(&inner, labelGap * 2)
	buttons := ui.cutTop(&inner, rowH)
	if !view.builtin &&
	   serverSettingsButton(
		   ctx,
		   &buttons,
		   ui.idOf("admin-role-save", serverID, roleID),
		   view.saveLabel,
		   .Primary,
	   ) {
		action = {kind = .SubmitRoleEditor, roleID = roleID}
	}
	if view.canDelete &&
	   serverSettingsButton(
		   ctx,
		   &buttons,
		   ui.idOf("admin-role-delete", serverID, roleID),
		   view.deleteLabel,
		   view.confirmDelete ? .DangerArmed : .Danger,
	   ) {
		action = {kind = .DeleteRole, roleID = roleID}
	}
	if serverSettingsButton(
		ctx,
		&buttons,
		ui.idOf("admin-role-cancel", serverID, roleID),
		view.builtin ? "Close" : "Cancel",
		.Plain,
	) {
		action = {kind = .CloseRoleEditor, roleID = roleID}
	}
	return
}

// The answer to the last admin request, inset by indent (under a member's controls).
@(private = "file")
viewAdminStatus :: proc(
	ctx: ^ui.Context,
	column: ^ui.Rect,
	view: AdminSectionView,
	indent: f32 = 0,
) {
	if len(view.status) == 0 {
		return
	}
	color := ctx.theme.fgMuted
	#partial switch view.statusTone {
	case .Success:
		color = ctx.theme.success
	case .Error:
		color = ctx.theme.danger
	}
	_ = ui.cutTop(column, ui.dp(ctx, SETTINGS_LABEL_GAP))
	area := column^
	_ = ui.cutLeft(&area, indent)
	height := ui.wrappedTextHeight(ctx, view.status, area.w)
	ui.wrappedLabel(ctx, ui.Rect{area.x, area.y, area.w, height}, view.status, color)
	_ = ui.cutTop(column, height)
}

// Scrolls the screen so the member row starting at rowTop (screen y) and its confirmation,
// ending at bottom, are in view, and stops asking once they are or the area cannot scroll
// further.
@(private = "file")
adminScrollIntoView :: proc(
	ctx: ^ui.Context,
	form: ^ServerSettingsForm,
	scrollID: ui.ID,
	area: ui.Rect,
	rowTop, bottom: f32,
) {
	margin := ui.dp(ctx, PANEL_PADDING * 2)
	if rowTop >= area.y && bottom <= area.y + area.h {
		form.adminConfirm.scrollTo = false
		return
	}
	scroll := ui.scrollState(ctx, scrollID)
	target := scroll.offset + (rowTop - area.y) - margin
	if bottom - rowTop + margin * 2 < area.h {
		// It fits: show it whole, as low as possible when it is below the view.
		if bottom > area.y + area.h {
			target = scroll.offset + (bottom - (area.y + area.h)) + margin
		}
	}
	target = clamp(target, 0, ui.scrollMaxOffset(form.contentH, area.h))
	if abs(target - scroll.offset) < 1 {
		form.adminConfirm.scrollTo = false
		return
	}
	scroll.pendingDelta = target - scroll.offset
	ui.requestFrame(ctx)
}

// The inline confirmation under a member: a title, the text field (a new name or a reason),
// the lock toggle for a rename, a note, and Confirm / Cancel.
@(private = "file")
viewAdminConfirm :: proc(
	state: ^State,
	ctx: ^ui.Context,
	column: ^ui.Rect,
	view: AdminConfirmView,
	serverID: int,
) -> (
	action: AdminSectionAction,
) {
	confirm := &state.serverSettings.adminConfirm
	padding := ui.dp(ctx, PANEL_PADDING * 1.5)
	labelGap := ui.dp(ctx, SETTINGS_LABEL_GAP)
	rowH := ui.dp(ctx, ROW_HEIGHT)
	innerW := column.w - padding * 2
	userID := view.userID
	textID := ui.idOf("admin-confirm-text", serverID, userID)
	inputH := ui.textInputHeight(ctx, textID, confirm.text[:], innerW)
	noteH := ui.wrappedTextHeight(ctx, view.note, innerW)
	boxH := padding * 2
	boxH += ui.lineHeight(ctx, .Bold) + labelGap
	boxH += ui.lineHeight(ctx) + labelGap + inputH + labelGap
	if view.showLock {
		boxH += rowH + labelGap
	}
	boxH += noteH + labelGap * 2 + rowH
	box := ui.cutTop(column, boxH)
	ui.fillRoundedRect(ctx, box, ui.dp(ctx, ctx.theme.cornerRadius), ctx.theme.border)
	ui.fillRoundedRect(
		ctx,
		ui.shrink(box, max(1, ui.dp(ctx, 1))),
		ui.dp(ctx, ctx.theme.cornerRadius),
		ctx.theme.elevated,
	)
	inner := ui.shrink(box, padding)
	ui.label(ctx, ui.cutTop(&inner, ui.lineHeight(ctx, .Bold)), view.title, ctx.theme.fg, .Bold)
	_ = ui.cutTop(&inner, labelGap)
	ui.label(ctx, ui.cutTop(&inner, ui.lineHeight(ctx)), view.fieldLabel, ctx.theme.fgMuted)
	_ = ui.cutTop(&inner, labelGap)
	if serverSettingsField(
		ctx,
		ui.cutTop(&inner, inputH),
		textID,
		&confirm.text,
		view.placeholder,
		view.maxBytes,
	) {
		action = {kind = .SubmitConfirm, userID = userID}
	}
	_ = ui.cutTop(&inner, labelGap)
	if view.showLock {
		lockRow := ui.cutTop(&inner, rowH)
		lockW := ui.textSize(ui.textGet(ctx, 0, .Regular, view.lockLabel)).x
		lockW += ui.dp(ctx, ctx.theme.padding * 4)
		lockOptions := ui.ButtonOptions {
			align      = .Center,
			selected   = confirm.lockName,
			color      = confirm.lockName ? ctx.theme.fg : ctx.theme.fgMuted,
			background = ctx.theme.hover,
		}
		if ui.button(
			ctx,
			ui.idOf("admin-confirm-lock", serverID, userID),
			ui.cutLeft(&lockRow, lockW),
			view.lockLabel,
			lockOptions,
		) {
			action = {kind = .ToggleLock, userID = userID}
		}
		_ = ui.cutTop(&inner, labelGap)
	}
	serverSettingsWrapped(ctx, &inner, view.note, ctx.theme.fgMuted)
	_ = ui.cutTop(&inner, labelGap * 2)
	buttons := ui.cutTop(&inner, rowH)
	if serverSettingsButton(
		ctx,
		&buttons,
		ui.idOf("admin-confirm", serverID, userID),
		view.confirmLabel,
		view.danger ? .DangerArmed : .Primary,
	) {
		action = {kind = .SubmitConfirm, userID = userID}
	}
	if serverSettingsButton(
		ctx,
		&buttons,
		ui.idOf("admin-confirm-cancel", serverID, userID),
		"Cancel",
		.Plain,
	) {
		action = {kind = .CancelConfirm, userID = userID}
	}
	return
}
