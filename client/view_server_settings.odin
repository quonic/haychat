package client

import "core:fmt"
import "ui"

// The Server settings screen (server_settings.odin), drawn in the main pane in place of the
// room. A scrolling centred column like the settings screen: Profile and Server share one
// Save button; the Voice section, the key and Remove server (last, below Voice) act at once.
//
// Widget IDs for GUI automation (all take the server ID; the voice ones also the user ID):
// server-settings (the sidebar header's gear), server-settings-name, -label, -short, -host,
// -port, -save, -close, -forget-key, -remove, server-voice-volume, server-voice-mute.

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
	serverSettingsLabel(ctx, &column, "Display name on this server")
	nameID := ui.idOf("server-settings-name", serverID)
	nameRect := ui.cutTop(&column, ui.textInputHeight(ctx, nameID, form.displayName[:], width))
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
