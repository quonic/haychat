package client

import "core:fmt"
import "ui"

// The first-run and settings screen. On first run it fills the window and asks only for a
// display name and one server; later it opens from the rail's gear button and also lists the
// configured servers so each can be edited or removed.

SETTINGS_COLUMN_WIDTH :: 480
SETTINGS_PORT_WIDTH :: 104
SETTINGS_SECTION_GAP :: 20
SETTINGS_LABEL_GAP :: 6

@(private = "file")
settingsLabel :: proc(ctx: ^ui.Context, column: ^ui.Rect, text: string) {
	ui.label(ctx, ui.cutTop(column, ui.lineHeight(ctx)), text, ctx.theme.fgMuted, .Bold)
	_ = ui.cutTop(column, ui.dp(ctx, SETTINGS_LABEL_GAP))
}

@(private = "file")
settingsWrapped :: proc(ctx: ^ui.Context, column: ^ui.Rect, text: string, color: ui.Color) {
	height := ui.wrappedTextHeight(ctx, text, column.w)
	ui.wrappedLabel(ctx, ui.cutTop(column, height), text, color)
}

// Draws a single-line field. Returns true when Enter was pressed in it.
@(private = "file")
settingsField :: proc(
	ctx: ^ui.Context,
	r: ui.Rect,
	id: ui.ID,
	buffer: ^[dynamic]u8,
	placeholder: string,
	maxBytes: int,
) -> bool {
	result := ui.textInput(ctx, id, r, buffer, placeholder, maxBytes)
	// These fields are single line; Shift+Enter would otherwise insert a newline.
	for index := len(buffer) - 1; index >= 0; index -= 1 {
		if buffer[index] == '\n' || buffer[index] == '\r' {
			ordered_remove(buffer, index)
		}
	}
	return result.submitted
}

viewSettings :: proc(state: ^State, ctx: ^ui.Context, r: ui.Rect) {
	ui.fillRect(ctx, r, ctx.theme.surface)
	firstRun := State_needsFirstRunSetup(state.config)
	form := &state.settings

	padding := ui.dp(ctx, 24)
	width := min(r.w - padding * 2, ui.dp(ctx, SETTINGS_COLUMN_WIDTH))
	column := ui.Rect{r.x + (r.w - width) / 2, r.y + ui.dp(ctx, 56), width, r.h - ui.dp(ctx, 80)}
	ui.pushClip(ctx, r)
	defer ui.popClip(ctx)

	rowH := ui.dp(ctx, ROW_HEIGHT)
	sectionGap := ui.dp(ctx, SETTINGS_SECTION_GAP)
	title := firstRun ? "Welcome to HayChat" : "Settings"
	ui.label(ctx, ui.cutTop(&column, ui.lineHeight(ctx, .Bold) * 1.5), title, ctx.theme.fg, .Bold)
	intro := "Changing your name or a server's address reconnects to that server."
	if firstRun {
		intro = "Choose the name other people will see, then the server to connect to."
	}
	settingsWrapped(ctx, &column, intro, ctx.theme.fgMuted)
	_ = ui.cutTop(&column, sectionGap)

	submitted := false
	inputW := column.w
	settingsLabel(ctx, &column, "Display name")
	nameID := ui.idOf("settings-name")
	nameRect := ui.cutTop(&column, ui.textInputHeight(ctx, nameID, form.displayName[:], inputW))
	nameMax := DISPLAY_NAME_MAX_BYTES
	if settingsField(ctx, nameRect, nameID, &form.displayName, "e.g. alice", nameMax) {
		submitted = true
	}
	_ = ui.cutTop(&column, ui.dp(ctx, SETTINGS_LABEL_GAP))
	settingsWrapped(
		ctx,
		&column,
		"3 to 32 characters. A server reserves a name for the first device that uses it.",
		ctx.theme.fgMuted,
	)
	_ = ui.cutTop(&column, sectionGap)

	// The server list, so an existing server can be picked for editing or a new one added.
	editServerID := -1
	if !firstRun {
		settingsLabel(ctx, &column, "Servers")
		for server in state.config.servers {
			row := ui.cutTop(&column, rowH)
			text := fmt.tprintf("%s   %s:%d", server.name, server.host, server.port)
			selected := form.editingServerID == server.id
			serverButtonID := ui.idOf("settings-server", server.id)
			if ui.button(ctx, serverButtonID, row, text, {selected = selected}) {
				editServerID = server.id
			}
			_ = ui.cutTop(&column, ui.dp(ctx, ROW_SPACING))
		}
		addRow := ui.cutTop(&column, rowH)
		addOptions := ui.ButtonOptions {
			selected = form.editingServerID == 0,
			color    = ctx.theme.primary,
		}
		if ui.button(ctx, ui.idOf("settings-add-server"), addRow, "+ Add server", addOptions) {
			editServerID = 0
		}
		_ = ui.cutTop(&column, sectionGap)
	}

	addressTitle := "Server"
	if !firstRun {
		addressTitle = form.editingServerID == 0 ? "New server" : "Server address"
	}
	settingsLabel(ctx, &column, addressTitle)
	hostID := ui.idOf("settings-host", form.editingServerID)
	portID := ui.idOf("settings-port", form.editingServerID)
	gap := ui.dp(ctx, PANEL_PADDING)
	portW := ui.dp(ctx, SETTINGS_PORT_WIDTH)
	fieldH := ui.textInputHeight(ctx, hostID, form.serverHost[:], inputW - portW - gap)
	fields := ui.cutTop(&column, fieldH)
	portRect := ui.cutRight(&fields, portW)
	_ = ui.cutRight(&fields, gap)
	hostPlaceholder := "Host name or IP address, e.g. chat.example.com"
	hostMax := SERVER_HOST_MAX_BYTES
	if settingsField(ctx, fields, hostID, &form.serverHost, hostPlaceholder, hostMax) {
		submitted = true
	}
	if settingsField(ctx, portRect, portID, &form.serverPort, "Port", SERVER_PORT_MAX_BYTES) {
		submitted = true
	}
	if !firstRun && form.editingServerID == 0 {
		_ = ui.cutTop(&column, ui.dp(ctx, SETTINGS_LABEL_GAP))
		hint := "Leave the host empty to only save your name."
		settingsWrapped(ctx, &column, hint, ctx.theme.fgMuted)
	}

	if len(form.error) > 0 {
		_ = ui.cutTop(&column, ui.dp(ctx, PANEL_PADDING))
		settingsWrapped(ctx, &column, form.error, ctx.theme.danger)
	}
	_ = ui.cutTop(&column, sectionGap)

	buttons := ui.cutTop(&column, ui.dp(ctx, ROW_HEIGHT + 4))
	buttonW := ui.dp(ctx, 120)
	applyText := firstRun ? "Connect" : "Save"
	applyOptions := ui.ButtonOptions {
		align      = .Center,
		font       = .Bold,
		color      = ctx.theme.onPrimary,
		background = ctx.theme.primary,
	}
	applyRect := ui.cutLeft(&buttons, buttonW)
	if ui.button(ctx, ui.idOf("settings-apply"), applyRect, applyText, applyOptions) {
		submitted = true
	}
	closeClicked, removeClicked := false, false
	if !firstRun {
		_ = ui.cutLeft(&buttons, gap)
		cancelOptions := ui.ButtonOptions {
			align      = .Center,
			background = ctx.theme.hover,
		}
		closeClicked = ui.button(
			ctx,
			ui.idOf("settings-cancel"),
			ui.cutLeft(&buttons, buttonW),
			"Cancel",
			cancelOptions,
		)
		if form.editingServerID != 0 {
			removeOptions := ui.ButtonOptions {
				align = .Center,
				color = ctx.theme.danger,
			}
			removeClicked = ui.button(
				ctx,
				ui.idOf("settings-remove"),
				ui.cutRight(&buttons, ui.dp(ctx, 140)),
				"Remove server",
				removeOptions,
			)
		}
	}

	// Actions run last: they can reallocate the server list drawn above.
	switch {
	case submitted:
		State_applySettings(state)
	case closeClicked:
		State_closeSettings(state)
	case removeClicked:
		State_settingsRemoveServer(state, form.editingServerID)
	case editServerID >= 0:
		State_settingsEditServer(state, editServerID)
	}
}
