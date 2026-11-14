package client

import "../common"
import "core:fmt"
import "core:time"
import "ui"

// Screens are drawn immediately each frame from State. Widgets report clicks and edits through
// their return values, and the view answers by calling State actions directly.

RAIL_WIDTH :: 64
SIDEBAR_WIDTH :: 240
HEADER_HEIGHT :: 48
ROW_HEIGHT :: 32
ROW_SPACING :: 2
MESSAGE_GROUP_GAP :: 12
MESSAGE_LINE_GAP :: 2
COMPOSER_PADDING :: 12
PANEL_PADDING :: 8

viewApp :: proc(state: ^State, ctx: ^ui.Context) {
	// The Voice settings section holds the device lists and the microphone test only while
	// it is on screen.
	voicePanelVisible :=
		state.settingsOpen &&
		!State_needsFirstRunSetup(state.config) &&
		state.settings.tab == .Voice
	State_setVoiceSettingsVisible(state, voicePanelVisible)
	State_voiceSettingsFrame(state)
	// Meters and speaking indicators change without any event. The frame loop polls them
	// (app.odin) and redraws only when they would look different from this frame.
	state.voice.drawnVisual = State_voiceVisualKey(state)
	root := ctx.windowRect
	// First run has nothing to show beside the form, so it takes the whole window.
	if state.settingsOpen && State_needsFirstRunSetup(state.config) {
		viewSettings(state, ctx, root)
		return
	}
	rail := ui.cutLeft(&root, ui.dp(ctx, RAIL_WIDTH))
	ui.fillRect(ctx, rail, ctx.theme.bg)
	viewRail(state, ctx, rail)
	if state.settingsOpen {
		viewSettings(state, ctx, root)
		return
	}

	sidebar := ui.cutLeft(&root, ui.dp(ctx, SIDEBAR_WIDTH))
	ui.fillRect(ctx, sidebar, ctx.theme.surface)
	viewVerticalBorder(ctx, sidebar)
	// One snapshot per frame, so the footer and the banner always agree. The sidebar goes
	// first, so a click there shows its room or conversation in the same frame.
	banner := buildConnectionBanner(state, time.tick_now())
	viewSidebar(state, ctx, sidebar, &banner)
	if State_serverSettingsVisible(state) {
		viewServerSettings(state, ctx, root, &banner)
	} else if State_roomEditorVisible(state) {
		viewRoomEditor(state, ctx, root, &banner)
	} else if state.selected_dm_peer_id != 0 {
		viewDirectChat(state, ctx, root, &banner)
	} else {
		viewRoomChat(state, ctx, root, &banner)
	}
}

@(private = "file")
viewVerticalBorder :: proc(ctx: ^ui.Context, r: ui.Rect) {
	width := max(1, ui.dp(ctx, 1))
	ui.fillRect(ctx, ui.Rect{r.x + r.w - width, r.y, width, r.h}, ctx.theme.border)
}

// A button at the right end of a panel header. Empty text draws nothing.
HeaderAction :: struct {
	text:    string,
	id:      ui.ID,
	primary: bool,
}

// Draws a panel header with a title and optional muted subtitle, then a divider under it.
// With actionText, a button sits at the right end; returns whether it was clicked.
viewHeader :: proc(
	ctx: ^ui.Context,
	area: ^ui.Rect,
	title: string,
	subtitle: string = "",
	actionText: string = "",
	actionID: ui.ID = 0,
) -> bool {
	actions := [1]HeaderAction{{text = actionText, id = actionID}}
	return viewHeaderWithActions(ctx, area, title, subtitle, actions[:]) == 0
}

// viewHeader with several buttons, laid out from the right end in order. Returns the index of
// the one clicked, or -1.
viewHeaderWithActions :: proc(
	ctx: ^ui.Context,
	area: ^ui.Rect,
	title: string,
	subtitle: string,
	actions: []HeaderAction,
) -> int {
	header := ui.cutTop(area, ui.dp(ctx, HEADER_HEIGHT))
	content := ui.shrinkXY(header, ui.dp(ctx, 16), 0)
	actionClicked := -1
	for action, index in actions {
		if len(action.text) == 0 {
			continue
		}
		buttonH := ui.dp(ctx, ROW_HEIGHT)
		buttonW := ui.textSize(ui.textGet(ctx, 0, .Regular, action.text)).x
		buttonW += ui.dp(ctx, ctx.theme.padding * 4)
		slot := ui.cutRight(&content, buttonW)
		_ = ui.cutRight(&content, ui.dp(ctx, PANEL_PADDING))
		button := ui.Rect{slot.x, slot.y + (slot.h - buttonH) / 2, slot.w, buttonH}
		actionOptions := ui.ButtonOptions {
			align      = .Center,
			color      = ctx.theme.fgMuted,
			background = ctx.theme.hover,
		}
		if action.primary {
			actionOptions.color = ctx.theme.onPrimary
			actionOptions.background = ctx.theme.primary
		}
		if ui.button(ctx, action.id, button, action.text, actionOptions) {
			actionClicked = index
		}
	}
	{
		// A long title or subtitle must not run under the action button.
		ui.pushClip(ctx, content)
		defer ui.popClip(ctx)
		ui.label(ctx, content, title, ctx.theme.fg, .Bold)
		if len(subtitle) > 0 {
			titleWidth := ui.textSize(ui.textGet(ctx, 0, .Bold, title)).x
			subtitleArea := content
			_ = ui.cutLeft(&subtitleArea, titleWidth + ui.dp(ctx, 12))
			ui.label(ctx, subtitleArea, subtitle, ctx.theme.fgMuted)
		}
	}
	ui.divider(ctx, ui.cutTop(area, max(1, ui.dp(ctx, 1))))
	return actionClicked
}

// Server rail: one button per configured server, and settings at the bottom. Direct messages
// belong to one server, so they live in that server's sidebar rather than on the rail.
@(private = "file")
viewRail :: proc(state: ^State, ctx: ^ui.Context, r: ui.Rect) {
	area := ui.shrink(r, ui.dp(ctx, PANEL_PADDING))
	size := area.w
	spacing := ui.dp(ctx, 6)
	options := ui.ButtonOptions {
		align = .Center,
		font  = .Bold,
	}

	// Settings sits at the bottom, below the scrolling server list.
	settingsID := ui.idOf("rail-settings")
	settingsButton := ui.cutBottom(&area, size)
	ui.divider(ctx, ui.cutBottom(&area, spacing))
	_ = ui.cutBottom(&area, spacing)
	settingsOptions := options
	settingsOptions.selected = state.settingsOpen
	settingsClicked := ui.button(ctx, settingsID, settingsButton, "⚙", settingsOptions)
	ui.tooltip(ctx, settingsID, settingsButton, "Settings")

	scrollID := ui.idOf("rail-servers")
	servers := state.config.servers[:]
	contentH := f32(len(servers)) * (size + spacing)
	offset := ui.scrollBegin(ctx, scrollID, area, contentH)
	clickedServerID := 0
	clicked := false
	y := area.y - offset
	for server in servers {
		id := ui.idOf("rail-server", server.id)
		buttonRect := ui.Rect{area.x, y, area.w, size}
		options.selected = !state.settingsOpen && state.selected_server_id == server.id
		if ui.button(ctx, id, buttonRect, server.short_name, options) {
			clickedServerID = server.id
			clicked = true
		}
		viewServerStatusDot(state, ctx, buttonRect, server.id)
		ui.tooltip(ctx, id, buttonRect, server.name)
		y += size + spacing
	}
	ui.scrollEnd(ctx, scrollID, area)

	// Actions run after the loop because they can reallocate the server list being drawn.
	if clicked {
		State_closeSettings(state)
		State_switchToServer(state, clickedServerID)
	} else if settingsClicked {
		if state.settingsOpen {
			State_closeSettings(state)
		} else {
			State_openSettings(state)
		}
	}
}

@(private = "file")
connectionStatusColor :: proc(ctx: ^ui.Context, status: ClientConnectionStatus) -> ui.Color {
	switch status {
	case .Established:
		return ctx.theme.success
	case .Failed:
		return ctx.theme.danger
	case .Idle, .Connecting, .Handshaking, .Disconnected:
	}
	return ctx.theme.warning
}

// A small dot in the corner of a rail button: green connected, amber connecting or waiting
// to reconnect, red stopped.
@(private = "file")
viewServerStatusDot :: proc(state: ^State, ctx: ^ui.Context, button: ui.Rect, serverID: int) {
	index := State_serverConnectionIndex(state^, serverID)
	if index < 0 {
		return
	}
	diameter := ui.dp(ctx, 10)
	ring := max(1, ui.dp(ctx, 2))
	dot := ui.Rect {
		button.x + button.w - diameter,
		button.y + button.h - diameter,
		diameter,
		diameter,
	}
	ui.fillRoundedRect(ctx, dot, diameter / 2, ctx.theme.bg)
	color := connectionStatusColor(ctx, state.serverConnections[index].status)
	inner := ui.shrink(dot, ring)
	ui.fillRoundedRect(ctx, inner, inner.w / 2, color)
}

// The muted one-line status at the bottom of the channel list, e.g. "Connected as alice".
@(private = "file")
viewConnectionFooter :: proc(
	state: ^State,
	ctx: ^ui.Context,
	area: ^ui.Rect,
	banner: ^ConnectionBanner,
) {
	if !banner.hasServer {
		return
	}
	footer := ui.cutBottom(area, ui.dp(ctx, ROW_HEIGHT + PANEL_PADDING))
	ui.divider(ctx, ui.Rect{footer.x, footer.y, footer.w, 1})
	content := ui.shrinkXY(footer, ui.dp(ctx, 16), 0)
	dotSize := ui.dp(ctx, 8)
	dot := ui.Rect{content.x, content.y + (content.h - dotSize) / 2, dotSize, dotSize}
	connection := State_serverConnection(state, state.selected_server_id)
	ui.fillRoundedRect(ctx, dot, dotSize / 2, connectionStatusColor(ctx, connection.status))
	_ = ui.cutLeft(&content, dotSize + ui.dp(ctx, 8))
	ui.label(ctx, content, banner.summary, ctx.theme.fgMuted)
	if banner.refreshIn > 0 {
		ui.requestFrameAt(ctx, ctx.nowMS + u64(time.duration_milliseconds(banner.refreshIn)) + 1)
	}
}

// The explanation shown above the room while the selected server is not connected, with the
// actions that can fix it. Draws nothing while connected.
viewConnectionBanner :: proc(
	state: ^State,
	ctx: ^ui.Context,
	area: ^ui.Rect,
	banner: ^ConnectionBanner,
) {
	if len(banner.text) == 0 {
		return
	}
	padding := ui.dp(ctx, COMPOSER_PADDING)
	accentW := ui.dp(ctx, 3)
	textW := area.w - padding * 4 - accentW
	textH := ui.wrappedTextHeight(ctx, banner.text, textW)
	hasActions := banner.showRetry || banner.showTrustKey || banner.showSettings
	actionsH := hasActions ? ui.dp(ctx, ROW_HEIGHT) + ui.dp(ctx, PANEL_PADDING) : 0
	outer := ui.cutTop(area, textH + actionsH + padding * 3)
	box := ui.shrinkXY(outer, padding, 0)
	box.y += padding
	box.h -= padding
	ui.fillRoundedRect(ctx, box, ui.dp(ctx, ctx.theme.cornerRadius), ctx.theme.elevated)
	accent := banner.tone == .Error ? ctx.theme.danger : ctx.theme.warning
	ui.fillRect(ctx, ui.Rect{box.x, box.y, accentW, box.h}, accent)

	content := ui.shrinkXY(box, padding, padding / 2)
	_ = ui.cutLeft(&content, accentW)
	ui.wrappedLabel(ctx, ui.cutTop(&content, textH), banner.text, ctx.theme.fg)
	if banner.refreshIn > 0 {
		ui.requestFrameAt(ctx, ctx.nowMS + u64(time.duration_milliseconds(banner.refreshIn)) + 1)
	}
	if !hasActions {
		return
	}

	_ = ui.cutTop(&content, ui.dp(ctx, PANEL_PADDING))
	row := ui.cutTop(&content, ui.dp(ctx, ROW_HEIGHT))
	serverID := state.selected_server_id
	retry, trust, settings := false, false, false
	if banner.showTrustKey {
		trustID := ui.idOf("banner-trust", serverID)
		trust = viewBannerButton(ctx, &row, trustID, "Trust the new key", true)
	}
	if banner.showSettings {
		settingsID := ui.idOf("banner-settings", serverID)
		settings = viewBannerButton(ctx, &row, settingsID, "Open settings", true)
	}
	if banner.showRetry {
		// Retry is the main action unless a more specific fix is offered.
		retryPrimary := !banner.showTrustKey && !banner.showSettings
		retryID := ui.idOf("banner-retry", serverID)
		retry = viewBannerButton(ctx, &row, retryID, "Retry now", retryPrimary)
	}
	switch {
	case trust:
		State_trustNewServerKey(state, serverID)
	case settings:
		State_openNameSettings(state, serverID)
	case retry:
		State_retryConnection(state, serverID)
	}
}

// Lays out one banner button from the left of row and returns whether it was clicked.
@(private = "file")
viewBannerButton :: proc(
	ctx: ^ui.Context,
	row: ^ui.Rect,
	id: ui.ID,
	text: string,
	primary: bool,
) -> bool {
	width := ui.textSize(ui.textGet(ctx, 0, .Bold, text)).x + ui.dp(ctx, ctx.theme.padding * 4)
	rect := ui.cutLeft(row, width)
	_ = ui.cutLeft(row, ui.dp(ctx, PANEL_PADDING))
	options := ui.ButtonOptions {
		align = .Center,
		font  = .Bold,
	}
	if primary {
		options.background = ctx.theme.primary
		options.color = ctx.theme.onPrimary
	} else {
		options.background = ctx.theme.hover
	}
	return ui.button(ctx, id, rect, text, options)
}

@(private = "file")
selectedServerName :: proc(state: ^State) -> string {
	for server in state.config.servers {
		if server.id == state.selected_server_id {
			return server.name
		}
	}
	return "Channels"
}

@(private = "file")
selectedRoom :: proc(state: ^State) -> (common.RoomSummary, bool) {
	cacheIndex := State_serverRoomCacheIndex(state^, state.selected_server_id)
	if cacheIndex < 0 {
		return {}, false
	}
	for room in state.server_room_caches[cacheIndex].rooms {
		if room.id == state.selected_channel_id {
			return room, true
		}
	}
	return {}, false
}

SECTION_GAP :: 12

@(private = "file")
sidebarRowHeight :: proc(ctx: ^ui.Context, row: SidebarRow, index: int) -> f32 {
	height := ui.dp(ctx, ROW_HEIGHT)
	if row.kind == .SectionHeader && index > 0 {
		height += ui.dp(ctx, SECTION_GAP)
	}
	return height
}

// The selected server's sidebar: channels, recent direct conversations, and members, in one
// scrolling list (see buildSidebarRows).
@(private = "file")
viewSidebar :: proc(state: ^State, ctx: ^ui.Context, r: ui.Rect, banner: ^ConnectionBanner) {
	area := r
	// The gear opens this server's own settings (server_settings.odin).
	settingsID := ui.idOf("server-settings", state.selected_server_id)
	settingsText := banner.hasServer ? "⚙" : ""
	serverName := selectedServerName(state)
	openSettings := viewHeader(ctx, &area, serverName, "", settingsText, settingsID)
	// Last, after the rows are drawn, since it closes the room form.
	defer if openSettings {
		State_openServerSettings(state, state.selected_server_id)
	}
	viewConnectionFooter(state, ctx, &area, banner)
	// Voice can be active on another server than the one shown, so the bar is always drawn.
	viewVoiceBar(state, ctx, &area)
	list := ui.shrink(area, ui.dp(ctx, PANEL_PADDING))
	if !banner.hasServer {
		return
	}

	rows := buildSidebarRows(state)
	spacing := ui.dp(ctx, ROW_SPACING)
	contentH: f32 = 0
	for row, index in rows {
		contentH += sidebarRowHeight(ctx, row, index) + spacing
	}

	serverID := state.selected_server_id
	scrollID := ui.idOf("sidebar", serverID)
	offset := ui.scrollBegin(ctx, scrollID, list, contentH)
	clickedKind := SidebarRowKind.Placeholder
	clickedID := 0
	clickedAction := SidebarRowAction.None
	y := list.y - offset
	for row, index in rows {
		height := sidebarRowHeight(ctx, row, index)
		rowH := ui.dp(ctx, ROW_HEIGHT)
		// A section header's extra gap sits above it.
		rowRect := ui.Rect{list.x, y + height - rowH, list.w, rowH}
		y += height + spacing
		if rowRect.y + rowRect.h < list.y || rowRect.y > list.y + list.h {
			continue
		}
		if viewSidebarRow(ctx, serverID, row, rowRect) {
			clickedKind = row.kind
			clickedID = row.id
			clickedAction = row.action
		}
	}
	ui.scrollEnd(ctx, scrollID, list)

	// Actions run after the loop because they can reallocate the caches being drawn.
	switch clickedKind {
	case .Channel:
		State_switchToChannel(state, serverID, clickedID)
	case .Conversation, .Member:
		State_openDirectConversation(state, serverID, clickedID)
	case .SectionHeader:
		if clickedAction == .NewRoom {
			State_openRoomCreator(state)
		}
	case .Placeholder, .VoiceParticipant:
	}
}

// Draws one sidebar row and returns whether it was clicked.
@(private = "file")
viewSidebarRow :: proc(ctx: ^ui.Context, serverID: int, row: SidebarRow, rect: ui.Rect) -> bool {
	inset := ui.dp(ctx, ctx.theme.padding)
	switch row.kind {
	case .SectionHeader:
		content := ui.shrinkXY(rect, inset, 0)
		clicked := false
		if row.action == .NewRoom {
			text := "+ New room"
			width := ui.textSize(ui.textGet(ctx, 0, .Regular, text)).x
			width += ui.dp(ctx, ctx.theme.padding * 2)
			button := ui.cutRight(&content, width)
			newRoomOptions := ui.ButtonOptions {
				align = .Center,
				color = ctx.theme.primary,
			}
			clicked = ui.button(ctx, ui.idOf("new-room", serverID), button, text, newRoomOptions)
		}
		ui.label(ctx, content, row.label, ctx.theme.fgMuted, .Bold)
		return clicked
	case .Placeholder:
		ui.label(ctx, ui.shrinkXY(rect, inset, 0), row.label, ctx.theme.fgMuted)
	case .VoiceParticipant:
		viewVoiceParticipantRow(ctx, serverID, row, rect)
	case .Channel:
		id := ui.idOf("channel", serverID, row.id)
		if row.unreadCount <= 0 {
			labelColor := row.selected ? ctx.theme.fg : ctx.theme.fgMuted
			options := ui.ButtonOptions {
				selected = row.selected,
				color    = labelColor,
			}
			clicked: bool
			if row.voiceUsers <= 0 {
				clicked = ui.button(ctx, id, rect, row.label, options)
			} else {
				// The speaker and count take the right end first, and the label is drawn into
				// what is left, so a long room name never runs under them.
				clicked = ui.button(ctx, id, rect, "", {selected = row.selected})
				content := ui.shrinkXY(rect, inset, 0)
				viewChannelVoiceIndicator(ctx, &content, row.voiceUsers)
				ui.label(ctx, content, row.label, labelColor)
			}
			if len(row.description) > 0 {
				ui.tooltip(ctx, id, rect, row.description)
			}
			return clicked
		}
		// Unread: the label is drawn below, bold, so the badge can sit beside it.
		clicked := ui.button(ctx, id, rect, "", {selected = row.selected})
		content := ui.shrinkXY(rect, inset, 0)
		viewSidebarUnreadBadge(ctx, &content, row.unreadCount)
		viewChannelVoiceIndicator(ctx, &content, row.voiceUsers)
		ui.label(ctx, content, row.label, ctx.theme.fg, .Bold)
		tooltip := fmt.tprintf("%d unread", row.unreadCount)
		if len(row.description) > 0 {
			tooltip = fmt.tprintf("%s (%s)", row.description, tooltip)
		}
		ui.tooltip(ctx, id, rect, tooltip)
		return clicked
	case .Conversation, .Member:
		name := row.kind == .Conversation ? "dm-conversation" : "dm-member"
		id := ui.idOf(name, serverID, row.id)
		// The label is drawn below so the dot and the unread badge can sit beside it.
		clicked := ui.button(ctx, id, rect, "", {selected = row.selected})
		content := ui.shrinkXY(rect, inset, 0)

		dotSize := ui.dp(ctx, 8)
		dot := ui.Rect{content.x, content.y + (content.h - dotSize) / 2, dotSize, dotSize}
		dotColor := row.isOnline ? ctx.theme.success : ctx.theme.border
		ui.fillRoundedRect(ctx, dot, dotSize / 2, dotColor)
		_ = ui.cutLeft(&content, dotSize + ui.dp(ctx, 8))

		unread := row.unreadCount > 0
		if unread {
			viewSidebarUnreadBadge(ctx, &content, row.unreadCount)
		}
		color := row.selected || unread || row.isOnline ? ctx.theme.fg : ctx.theme.fgMuted
		ui.label(ctx, content, row.label, color, unread ? .Bold : .Regular)
		status := row.isOnline ? "Online" : "Offline"
		if unread {
			status = fmt.tprintf("%s, %d unread", status, row.unreadCount)
		}
		ui.tooltip(ctx, id, rect, status)
		return clicked
	}
	return false
}

// The text of an unread badge: the count, or "99+" from 100 on (the server caps counts at
// common.UNREAD_COUNT_CAP, so 100 means "100 or more").
unreadBadgeText :: proc(count: int, allocator := context.temp_allocator) -> string {
	if count > 99 {
		return "99+"
	}
	return fmt.aprintf("%d", count, allocator = allocator)
}

// Draws an unread badge at the right of content and takes its width from content.
@(private = "file")
viewSidebarUnreadBadge :: proc(ctx: ^ui.Context, content: ^ui.Rect, count: int) {
	text := unreadBadgeText(count)
	badgeH := ui.dp(ctx, 18)
	textW := ui.textSize(ui.textGet(ctx, 0, .Bold, text)).x
	badgeW := max(badgeH, textW + ui.dp(ctx, 10))
	badgeArea := ui.cutRight(content, badgeW)
	badgeY := badgeArea.y + (badgeArea.h - badgeH) / 2
	badge := ui.Rect{badgeArea.x, badgeY, badgeW, badgeH}
	ui.fillRoundedRect(ctx, badge, badgeH / 2, ctx.theme.primary)
	ui.label(ctx, badge, text, ctx.theme.onPrimary, .Bold, .Center)
	_ = ui.cutRight(content, ui.dp(ctx, 6))
}

// Builds transcript units for room and direct messages. Consecutive messages from the same
// sender share one sender header.
transcriptUnits :: proc(ctx: ^ui.Context, lines: []TranscriptLine) -> []ui.TranscriptUnit {
	units := make([dynamic]ui.TranscriptUnit, 0, len(lines) * 2, context.temp_allocator)
	for line, index in lines {
		sameSender := index > 0 && lines[index - 1].senderLabel == line.senderLabel
		if !sameSender {
			append(
				&units,
				ui.TranscriptUnit {
					key = u64(line.messageID) * 2,
					text = line.senderLabel,
					font = .Bold,
					color = line.isSelf ? ctx.theme.primary : ctx.theme.fg,
					gapBefore = index > 0 ? MESSAGE_GROUP_GAP : 0,
					copySep = ": ",
				},
			)
		}
		append(
			&units,
			ui.TranscriptUnit {
				key = u64(line.messageID) * 2 + 1,
				text = line.content,
				font = .Regular,
				color = ctx.theme.fg,
				gapBefore = MESSAGE_LINE_GAP,
				copySep = "\n",
			},
		)
	}
	return units[:]
}

// Lays out the composer and status line along the bottom of area. Returns the composer result.
viewComposer :: proc(
	ctx: ^ui.Context,
	area: ^ui.Rect,
	inputID: ui.ID,
	draft: ^[dynamic]u8,
	placeholder: string,
	status: string,
) -> ui.TextInputResult {
	padding := ui.dp(ctx, COMPOSER_PADDING)
	inputW := area.w - padding * 2
	inputH := ui.textInputHeight(ctx, inputID, draft[:], inputW)
	composer := ui.shrink(ui.cutBottom(area, inputH + padding * 2), padding)
	result := ui.textInput(
		ctx,
		inputID,
		composer,
		draft,
		placeholder,
		common.CHAT_MESSAGE_MAX_BYTES,
	)

	if len(status) > 0 {
		statusH := ui.wrappedTextHeight(ctx, status, inputW)
		statusArea := ui.cutBottom(area, statusH)
		ui.wrappedLabel(
			ctx,
			ui.shrinkXY(statusArea, padding, 0),
			status,
			ctx.theme.danger,
		)
	}
	return result
}

@(private = "file")
viewRoomChat :: proc(state: ^State, ctx: ^ui.Context, r: ui.Rect, banner: ^ConnectionBanner) {
	view := buildRoomView(state)
	area := r
	room, hasRoom := selectedRoom(state)
	editClicked, joinVoiceClicked, leaveVoiceClicked := false, false, false
	if hasRoom {
		editText := view.canEditRoom ? "Edit room" : ""
		editID := ui.idOf("edit-room", state.selected_server_id, room.id)
		title := fmt.tprintf("# %s", room.name)
		voiceAction := roomVoiceHeaderAction(state, state.selected_server_id, room.id)
		voiceText := ""
		switch voiceAction {
		case .Join:
			voiceText = VOICE_JOIN_TEXT
		case .Leave:
			voiceText = VOICE_LEAVE_TEXT
		case .None:
		}
		actions := [2]HeaderAction {
			{
				text = voiceText,
				id = ui.idOf("room-voice", state.selected_server_id, room.id),
				primary = voiceAction == .Join,
			},
			{text = editText, id = editID},
		}
		switch viewHeaderWithActions(ctx, &area, title, room.description, actions[:]) {
		case 0:
			joinVoiceClicked = voiceAction == .Join
			leaveVoiceClicked = voiceAction == .Leave
		case 1:
			editClicked = true
		}
	} else {
		viewHeader(ctx, &area, selectedServerName(state))
	}
	viewConnectionBanner(state, ctx, &area, banner)

	serverID := state.selected_server_id
	roomID := state.selected_channel_id
	if draft := State_selectedRoomDraft(state); draft != nil {
		placeholder := "Message… (Enter to send, Shift+Enter for newline)"
		if hasRoom {
			placeholder = fmt.tprintf(
				"Message #%s (Enter to send, Shift+Enter for newline)",
				room.name,
			)
		}
		inputID := ui.idOf("room-input", serverID, roomID)
		result := viewComposer(ctx, &area, inputID, draft, placeholder, view.status)
		if result.submitted {
			State_sendChannelChat(state)
		}
	} else if len(view.status) > 0 {
		viewComposerStatusOnly(ctx, &area, view.status)
	}

	if view.hasOlder || view.isLoadingHistory {
		historyRow := ui.shrinkXY(
			ui.cutTop(&area, ui.dp(ctx, ROW_HEIGHT + PANEL_PADDING * 2)),
			ui.dp(ctx, COMPOSER_PADDING),
			ui.dp(ctx, PANEL_PADDING),
		)
		if view.isLoadingHistory {
			ui.label(ctx, historyRow, "Loading messages…", ctx.theme.fgMuted, align = .Center)
		} else if ui.button(
			ctx,
			ui.idOf("load-older", serverID, roomID),
			historyRow,
			"Load older messages",
			{align = .Center, color = ctx.theme.primary},
		) {
			State_loadOlderRoomHistory(state)
		}
	}

	emptyText := "No messages yet"
	if !view.hasSelectedRoom {
		emptyText = "No joined channels"
	} else if view.isLoadingHistory {
		emptyText = "Loading messages…"
	}
	ui.transcript(
		ctx,
		ui.idOf("room-transcript", serverID, roomID),
		area,
		transcriptUnits(ctx, view.lines),
		emptyText,
	)

	// Last, so the form replaces the room only from the next frame on.
	switch {
	case editClicked:
		State_openRoomEditor(state, roomID)
	case joinVoiceClicked:
		State_joinVoice(state, serverID, roomID)
	case leaveVoiceClicked:
		State_leaveVoice(state)
	}
}

viewComposerStatusOnly :: proc(ctx: ^ui.Context, area: ^ui.Rect, status: string) {
	padding := ui.dp(ctx, COMPOSER_PADDING)
	statusH := ui.wrappedTextHeight(ctx, status, area.w - padding * 2)
	statusArea := ui.cutBottom(area, statusH + padding * 2)
	ui.wrappedLabel(ctx, ui.shrink(statusArea, padding), status, ctx.theme.danger)
}
