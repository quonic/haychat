package client

import "../common"
import "core:fmt"
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
	root := ctx.windowRect
	rail := ui.cutLeft(&root, ui.dp(ctx, RAIL_WIDTH))
	ui.fillRect(ctx, rail, ctx.theme.bg)
	viewRail(state, ctx, rail)

	sidebar := ui.cutLeft(&root, ui.dp(ctx, SIDEBAR_WIDTH))
	ui.fillRect(ctx, sidebar, ctx.theme.surface)
	viewVerticalBorder(ctx, sidebar)
	if state.view_dms {
		viewDMList(state, ctx, sidebar)
		viewDMChat(state, ctx, root)
	} else {
		viewChannelList(state, ctx, sidebar)
		viewRoomChat(state, ctx, root)
	}
}

@(private = "file")
viewVerticalBorder :: proc(ctx: ^ui.Context, r: ui.Rect) {
	width := max(1, ui.dp(ctx, 1))
	ui.fillRect(ctx, ui.Rect{r.x + r.w - width, r.y, width, r.h}, ctx.theme.border)
}

// Draws a panel header with a title and optional muted subtitle, then a divider under it.
@(private = "file")
viewHeader :: proc(ctx: ^ui.Context, area: ^ui.Rect, title: string, subtitle: string = "") {
	header := ui.cutTop(area, ui.dp(ctx, HEADER_HEIGHT))
	content := ui.shrinkXY(header, ui.dp(ctx, 16), 0)
	ui.label(ctx, content, title, ctx.theme.fg, .Bold)
	if len(subtitle) > 0 {
		titleWidth := ui.textSize(ui.textGet(ctx, 0, .Bold, title)).x
		subtitleArea := content
		_ = ui.cutLeft(&subtitleArea, titleWidth + ui.dp(ctx, 12))
		ui.label(ctx, subtitleArea, subtitle, ctx.theme.fgMuted)
	}
	ui.divider(ctx, ui.cutTop(area, max(1, ui.dp(ctx, 1))))
}

// Server rail: a direct-messages toggle, then one button per configured server.
@(private = "file")
viewRail :: proc(state: ^State, ctx: ^ui.Context, r: ui.Rect) {
	area := ui.shrink(r, ui.dp(ctx, PANEL_PADDING))
	size := area.w
	spacing := ui.dp(ctx, 6)

	dmID := ui.idOf("rail-dms")
	dmButton := ui.cutTop(&area, size)
	options := ui.ButtonOptions {
		selected = state.view_dms,
		align    = .Center,
		font     = .Bold,
	}
	if ui.button(ctx, dmID, dmButton, "DM", options) {
		State_showDMs(state)
	}
	ui.tooltip(ctx, dmID, dmButton, "Direct messages")
	_ = ui.cutTop(&area, spacing)
	ui.divider(ctx, ui.cutTop(&area, spacing))

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
		options.selected = !state.view_dms && state.selected_server_id == server.id
		if ui.button(ctx, id, buttonRect, server.short_name, options) {
			clickedServerID = server.id
			clicked = true
		}
		ui.tooltip(ctx, id, buttonRect, server.name)
		y += size + spacing
	}
	ui.scrollEnd(ctx, scrollID, area)

	if clicked {
		State_switchToServer(state, clickedServerID)
	}
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

// Lays out rows of equal height inside a scroll area and returns the row rects in order.
@(private = "file")
listRows :: proc(ctx: ^ui.Context, area: ui.Rect, offset: f32, count: int) -> []ui.Rect {
	rows := make([]ui.Rect, count, context.temp_allocator)
	rowH := ui.dp(ctx, ROW_HEIGHT)
	spacing := ui.dp(ctx, ROW_SPACING)
	for index in 0 ..< count {
		rows[index] = ui.Rect{area.x, area.y - offset + f32(index) * (rowH + spacing), area.w, rowH}
	}
	return rows
}

@(private = "file")
listContentHeight :: proc(ctx: ^ui.Context, count: int) -> f32 {
	return f32(count) * (ui.dp(ctx, ROW_HEIGHT) + ui.dp(ctx, ROW_SPACING))
}

@(private = "file")
viewChannelList :: proc(state: ^State, ctx: ^ui.Context, r: ui.Rect) {
	area := r
	viewHeader(ctx, &area, selectedServerName(state))
	list := ui.shrink(area, ui.dp(ctx, PANEL_PADDING))

	rooms: []common.RoomSummary
	roomsLoading := false
	if cacheIndex := State_serverRoomCacheIndex(state^, state.selected_server_id);
	   cacheIndex >= 0 {
		rooms = state.server_room_caches[cacheIndex].rooms[:]
		roomsLoading = state.server_room_caches[cacheIndex].roomsLoading
	}
	if len(rooms) == 0 {
		emptyText := roomsLoading ? "Loading channels…" : "No channels"
		ui.label(
			ctx,
			ui.cutTop(&list, ui.dp(ctx, ROW_HEIGHT)),
			emptyText,
			ctx.theme.fgMuted,
		)
		return
	}

	scrollID := ui.idOf("channel-list", state.selected_server_id)
	offset := ui.scrollBegin(ctx, scrollID, list, listContentHeight(ctx, len(rooms)))
	clickedRoomID := 0
	for row, index in listRows(ctx, list, offset, len(rooms)) {
		room := rooms[index]
		selected := room.id == state.selected_channel_id
		options := ui.ButtonOptions {
			selected = selected,
			color    = selected ? ctx.theme.fg : ctx.theme.fgMuted,
		}
		id := ui.idOf("channel", state.selected_server_id, room.id)
		if ui.button(ctx, id, row, fmt.tprintf("# %s", room.name), options) {
			clickedRoomID = room.id
		}
		if len(room.description) > 0 {
			ui.tooltip(ctx, id, row, room.description)
		}
	}
	ui.scrollEnd(ctx, scrollID, list)

	// Actions run after the loop because they can reallocate the room caches being drawn.
	if clickedRoomID != 0 {
		State_switchToChannel(state, state.selected_server_id, clickedRoomID)
	}
}

// Builds transcript units for room messages. Consecutive messages from the same sender share
// one sender header.
@(private = "file")
roomTranscriptUnits :: proc(ctx: ^ui.Context, lines: []TranscriptLine) -> []ui.TranscriptUnit {
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
@(private = "file")
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
viewRoomChat :: proc(state: ^State, ctx: ^ui.Context, r: ui.Rect) {
	view := buildRoomView(state)
	area := r
	room, hasRoom := selectedRoom(state)
	if hasRoom {
		viewHeader(ctx, &area, fmt.tprintf("# %s", room.name), room.description)
	} else {
		viewHeader(ctx, &area, selectedServerName(state))
	}

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
		roomTranscriptUnits(ctx, view.lines),
		emptyText,
	)
}

@(private = "file")
viewComposerStatusOnly :: proc(ctx: ^ui.Context, area: ^ui.Rect, status: string) {
	padding := ui.dp(ctx, COMPOSER_PADDING)
	statusH := ui.wrappedTextHeight(ctx, status, area.w - padding * 2)
	statusArea := ui.cutBottom(area, statusH + padding * 2)
	ui.wrappedLabel(ctx, ui.shrink(statusArea, padding), status, ctx.theme.danger)
}

@(private = "file")
selectedFriend :: proc(state: ^State) -> (Friend, bool) {
	if !state.view_friends_list {
		return {}, false
	}
	for friend in state.config.friends {
		if friend.id == state.selected_friend_id {
			return friend, true
		}
	}
	return {}, false
}

@(private = "file")
viewDMList :: proc(state: ^State, ctx: ^ui.Context, r: ui.Rect) {
	area := r
	viewHeader(ctx, &area, "Direct Messages")
	list := ui.shrink(area, ui.dp(ctx, PANEL_PADDING))

	addFriendRow := ui.cutTop(&list, ui.dp(ctx, ROW_HEIGHT))
	if ui.button(
		ctx,
		ui.idOf("add-friend"),
		addFriendRow,
		"+ Add Friend",
		{color = ctx.theme.primary},
	) {
		State_addFriend(state)
	}
	_ = ui.cutTop(&list, ui.dp(ctx, PANEL_PADDING))

	friends := state.config.friends[:]
	scrollID := ui.idOf("friend-list")
	offset := ui.scrollBegin(ctx, scrollID, list, listContentHeight(ctx, len(friends)))
	clickedFriendID := 0
	clicked := false
	for row, index in listRows(ctx, list, offset, len(friends)) {
		friend := friends[index]
		selected := state.view_friends_list && state.selected_friend_id == friend.id
		text := fmt.tprintf("%s %s", friendStatusLabel(friend.status), friend.display_name)
		if ui.button(ctx, ui.idOf("friend", friend.id), row, text, {selected = selected}) {
			clickedFriendID = friend.id
			clicked = true
		}
	}
	ui.scrollEnd(ctx, scrollID, list)

	if clicked {
		State_showFriend(state, clickedFriendID)
	}
}

@(private = "file")
viewDMChat :: proc(state: ^State, ctx: ^ui.Context, r: ui.Rect) {
	area := r
	friend, hasFriend := selectedFriend(state)
	viewHeader(ctx, &area, hasFriend ? friend.display_name : "Direct Messages")

	result := viewComposer(
		ctx,
		&area,
		ui.idOf("dm-input", state.selected_friend_id),
		&state.dm_chat_draft,
		"Message… (Enter to send, Shift+Enter for newline)",
		state.chat_status_message,
	)
	if result.submitted {
		State_sendDirectMessage(state)
	}

	units := make([]ui.TranscriptUnit, len(state.current_dm_chat) * 2, context.temp_allocator)
	for line, index in state.current_dm_chat {
		units[index * 2] = ui.TranscriptUnit {
			key       = u64(index) * 2,
			text      = line.senderName,
			font      = .Bold,
			color     = ctx.theme.fg,
			gapBefore = index > 0 ? MESSAGE_GROUP_GAP : 0,
			copySep   = ": ",
		}
		units[index * 2 + 1] = ui.TranscriptUnit {
			key       = u64(index) * 2 + 1,
			text      = line.text,
			font      = .Regular,
			color     = ctx.theme.fg,
			gapBefore = MESSAGE_LINE_GAP,
			copySep   = "\n",
		}
	}
	ui.transcript(
		ctx,
		ui.idOf("dm-transcript", state.selected_friend_id),
		area,
		units,
		"Say Hi!",
	)
}
