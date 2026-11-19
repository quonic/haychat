package client

import "../common"
import "core:fmt"
import "ui"
import SDL "vendor:sdl3"

// Draws the edit and delete UI from message_edit_ui.odin (#76 M3). Widget IDs for GUI
// automation, rooms first and direct conversations second (server ID, then the room ID or the
// peer's user ID):
//
// - the inline edit field: room-edit-input / dm-edit-input, and the bar's ×: room-edit-cancel /
//   dm-edit-cancel (server, conversation);
// - a message's "(edited)" marker: room-edited / dm-edited (server, conversation, message ID);
// - the Delete message… confirmation: message-delete-dialog (the overlay),
//   message-delete-confirm and message-delete-cancel (server);
// - the menu entries: menu-item with the ContextMenuAction value (EditMessage, DeleteMessage,
//   AdminDeleteMessage).

MESSAGE_DELETE_DIALOG_WIDTH :: 460
EDIT_HISTORY_WIDTH :: 380
// The share of the window's height the history may take before older edits are left out.
EDIT_HISTORY_MAX_HEIGHT_SHARE :: 0.7

@(private = "file")
editWidgetName :: proc(kind: common.ReadMarkerKind, room, direct: string) -> string {
	return kind == .Room ? room : direct
}

// The inline edit's field ID in a conversation.
messageEditInputID :: proc(
	serverID: int,
	kind: common.ReadMarkerKind,
	conversationID: int,
) -> ui.ID {
	name := editWidgetName(kind, "room-edit-input", "dm-edit-input")
	return ui.idOf(name, serverID, conversationID)
}

// Draws the inline edit in the composer's place when one is open in this conversation: the
// "Editing message" bar with its ×, the status, and the edit field. Returns false (drawing
// nothing) when no edit is open here, so the caller draws its composer.
viewMessageEditComposer :: proc(
	state: ^State,
	ctx: ^ui.Context,
	area: ^ui.Rect,
	serverID: int,
	kind: common.ReadMarkerKind,
	conversationID: int,
) -> bool {
	State_messageEditPoll(state)
	editor := State_messageEditIn(state, serverID, kind, conversationID)
	if editor == nil {
		return false
	}
	padding := ui.dp(ctx, COMPOSER_PADDING)
	inputID := messageEditInputID(serverID, kind, conversationID)
	if editor.focusPending {
		editor.focusPending = false
		ui.focusTextInput(ctx, inputID)
	}
	inputW := area.w - padding * 2
	inputH := ui.textInputHeight(ctx, inputID, editor.text[:], inputW)
	inputRect := ui.shrink(ui.cutBottom(area, inputH + padding * 2), padding)
	result := ui.textInput(
		ctx,
		inputID,
		inputRect,
		&editor.text,
		MESSAGE_EDIT_PLACEHOLDER,
		common.CHAT_MESSAGE_MAX_BYTES,
	)

	if len(editor.status) > 0 {
		statusH := ui.wrappedTextHeight(ctx, editor.status, inputW)
		statusArea := ui.cutBottom(area, statusH)
		color := editor.statusError ? ctx.theme.danger : ctx.theme.fgMuted
		ui.wrappedLabel(ctx, ui.shrinkXY(statusArea, padding, 0), editor.status, color)
	}

	// The bar: a strip over the field with what is going on and how to leave it.
	barH := ui.dp(ctx, ROW_HEIGHT)
	bar := ui.shrinkXY(ui.cutBottom(area, barH), padding, 0)
	radius := ui.dp(ctx, ctx.theme.cornerRadius)
	ui.fillRoundedRect(ctx, bar, radius, ctx.theme.surface)
	content := ui.shrinkXY(bar, ui.dp(ctx, PANEL_PADDING), 0)
	cancelRect := ui.cutRight(&content, barH)
	cancelClicked := ui.button(
		ctx,
		ui.idOf(
			editWidgetName(kind, "room-edit-cancel", "dm-edit-cancel"),
			serverID,
			conversationID,
		),
		cancelRect,
		"×",
		{align = .Center, color = ctx.theme.fgMuted},
	)
	titleW := ui.textSize(ui.textGet(ctx, 0, .Bold, MESSAGE_EDIT_BAR_TITLE)).x
	ui.label(ctx, ui.cutLeft(&content, titleW), MESSAGE_EDIT_BAR_TITLE, ctx.theme.primary, .Bold)
	_ = ui.cutLeft(&content, ui.dp(ctx, PANEL_PADDING * 2))
	ui.label(ctx, content, MESSAGE_EDIT_BAR_HINT, ctx.theme.fgMuted)

	// After drawing: each may close the editor.
	switch {
	case cancelClicked || result.escaped:
		State_cancelMessageEdit(state)
		ui.requestFrame(ctx)
	case result.entered:
		State_submitMessageEdit(state)
		ui.requestFrame(ctx)
	}
	return true
}

// After a conversation's composer was drawn, with its result: Up in the empty composer edits
// this account's newest editable message there.
viewComposerEditKeys :: proc(
	state: ^State,
	ctx: ^ui.Context,
	result: ui.TextInputResult,
	serverID: int,
	kind: common.ReadMarkerKind,
	conversationID: int,
) {
	if result.upInEmpty {
		if len(State_editNewestOwnMessage(state, serverID, kind, conversationID)) == 0 {
			ui.requestFrame(ctx)
		}
	}
}

// Gives the composer the keyboard back after an inline edit closed (a save or a cancel).
// Called before the composer is drawn.
viewComposerRefocus :: proc(state: ^State, ctx: ^ui.Context, inputID: ui.ID) {
	editor := &state.messageEditComposer
	if editor.active || !editor.refocusComposer {
		return
	}
	editor.refocusComposer = false
	ui.focusTextInput(ctx, inputID)
}

// ── Delete confirmation ──────────────────────────────────────────

// The Delete message… confirmation: a modal in the middle of the window. Esc, Cancel or a click
// outside closes it; it closes by itself once the tombstone arrived.
viewMessageDeleteDialog :: proc(state: ^State, ctx: ^ui.Context) {
	view := buildMessageDeleteDialogView(state)
	if view.done {
		State_closeMessageDeleteDialog(state)
		ui.requestFrame(ctx)
		return
	}
	if !view.visible {
		return
	}
	serverID := view.serverID
	overlayID := ui.idOf("message-delete-dialog", serverID)
	if ui.overlayPressedOutside(ctx, overlayID) {
		State_closeMessageDeleteDialog(state)
		return
	}
	submitted := false
	for event in ui.overlayEvents(ctx, overlayID) {
		key, isKey := event.(ui.KeyPress)
		if !isKey {
			continue
		}
		switch key.key {
		case SDL.K_ESCAPE:
			State_closeMessageDeleteDialog(state)
			return
		case SDL.K_RETURN, SDL.K_KP_ENTER:
			submitted = true
		}
	}

	padding := ui.dp(ctx, PANEL_PADDING * 2)
	window := ctx.windowRect
	width := min(ui.dp(ctx, MESSAGE_DELETE_DIALOG_WIDTH), window.w - padding * 2)
	textW := width - padding * 2
	rowH := ui.dp(ctx, ROW_HEIGHT)
	gap := ui.dp(ctx, PANEL_PADDING)
	textH := ui.wrappedTextHeight(ctx, view.text, textW)
	statusH := len(view.status) > 0 ? ui.wrappedTextHeight(ctx, view.status, textW) : 0
	height := padding * 2 + rowH + gap + textH + gap + statusH + gap + rowH
	rect := ui.Rect {
		window.x + (window.w - width) / 2,
		window.y + max((window.h - height) / 2, 0),
		width,
		height,
	}
	ui.beginOverlay(ctx, overlayID, rect)
	defer ui.endOverlay(ctx)
	radius := ui.dp(ctx, ctx.theme.cornerRadius)
	ui.fillRoundedRect(ctx, rect, radius, ctx.theme.elevated)
	ui.strokeRect(ctx, rect, ctx.theme.border)
	content := ui.shrink(rect, padding)
	ui.label(ctx, ui.cutTop(&content, rowH), view.title, ctx.theme.fg, .Bold)
	_ = ui.cutTop(&content, gap)
	ui.wrappedLabel(ctx, ui.cutTop(&content, textH), view.text, ctx.theme.fgMuted)
	_ = ui.cutTop(&content, gap)
	if statusH > 0 {
		color := view.statusError ? ctx.theme.danger : ctx.theme.fgMuted
		ui.wrappedLabel(ctx, ui.cutTop(&content, statusH), view.status, color)
	}
	_ = ui.cutTop(&content, gap)
	row := ui.cutTop(&content, rowH)
	deleteText := view.busy ? "Deleting…" : "Delete"
	confirmClicked := serverSettingsButton(
		ctx,
		&row,
		ui.idOf("message-delete-confirm", serverID),
		deleteText,
		.DangerArmed,
	)
	cancelClicked := serverSettingsButton(
		ctx,
		&row,
		ui.idOf("message-delete-cancel", serverID),
		"Cancel",
		.Plain,
	)
	switch {
	case cancelClicked:
		State_closeMessageDeleteDialog(state)
	case (confirmClicked || submitted) && !view.busy:
		State_submitMessageDeleteDialog(state)
	}
	ui.requestFrame(ctx)
}

// ── Edit history ─────────────────────────────────────────────────

// After a transcript was drawn: resting on a message's "(edited)" for
// MESSAGE_EDIT_HISTORY_HOVER_MS opens its history, a click pins it open (a second click on the
// same marker closes it). A popover for another conversation closes.
viewTranscriptEditMarker :: proc(
	state: ^State,
	ctx: ^ui.Context,
	result: ui.TranscriptResult,
	serverID: int,
	kind: common.ReadMarkerKind,
	conversationID: int,
) {
	popover := &state.editHistory
	if popover.open &&
	   (popover.serverID != serverID ||
			   popover.kind != kind ||
			   popover.conversationID != conversationID) {
		State_closeEditHistory(state)
	}
	if popover.open {
		popover.seenFrame = ctx.frame
	}
	if !result.markerHovered {
		return
	}
	messageID, _ := transcriptUnitDecode(result.markerKey)
	markerID := ui.idOf(
		editWidgetName(kind, "room-edited", "dm-edited"),
		serverID,
		conversationID,
		messageID,
	)
	same := popover.open && popover.messageID == messageID
	if result.markerClicked {
		if same && popover.pinned {
			State_closeEditHistory(state)
		} else {
			State_openEditHistory(
				state,
				serverID,
				kind,
				conversationID,
				messageID,
				result.markerRect,
				pinned = true,
			)
			popover.seenFrame = ctx.frame
		}
		ui.requestFrame(ctx)
		return
	}
	if same {
		popover.anchor = result.markerRect
		_ = ui.hoverHeld(ctx, markerID, result.markerRect, 0)
		return
	}
	if ui.hoverHeld(ctx, markerID, result.markerRect, MESSAGE_EDIT_HISTORY_HOVER_MS) {
		State_openEditHistory(
			state,
			serverID,
			kind,
			conversationID,
			messageID,
			result.markerRect,
			pinned = false,
		)
		popover.seenFrame = ctx.frame
		ui.requestFrame(ctx)
	}
}

// At the start of the frame, before any widget: a left press inside the open history goes to
// it (it is drawn last, on top), and a pinned one closes on a press outside it or Esc.
viewEditHistoryBeginFrame :: proc(state: ^State, ctx: ^ui.Context) {
	popover := &state.editHistory
	if !popover.open {
		return
	}
	input := &ctx.input
	inside := input.mouseInWindow && ui.contains(popover.rect, input.mousePos)
	onMarker := input.mouseInWindow && ui.contains(popover.anchor, input.mousePos)
	pressed := input.mousePressed[.Left] || input.mousePressed[.Right]
	if pressed && inside {
		ctx.pressConsumed = true
		return
	}
	if !popover.pinned {
		return
	}
	if pressed && !onMarker {
		State_closeEditHistory(state)
		return
	}
	for event in input.events {
		if key, isKey := event.(ui.KeyPress); isKey && key.key == SDL.K_ESCAPE {
			State_closeEditHistory(state)
			return
		}
	}
}

// The open history, drawn on top of the frame under the anchor (above it when it does not
// fit). One that was opened by hovering closes as soon as the pointer is on neither the marker
// nor the popover. It is built from State every frame, so the list arriving and a sealed edit
// that opens later (each wakes the loop) show up at once.
viewEditHistoryPopover :: proc(state: ^State, ctx: ^ui.Context) {
	popover := &state.editHistory
	if !popover.open {
		return
	}
	if popover.seenFrame != ctx.frame {
		// Its transcript is not on screen (another conversation, Settings, a form).
		State_closeEditHistory(state)
		return
	}
	input := &ctx.input
	if !popover.pinned {
		inside := input.mouseInWindow && ui.contains(popover.rect, input.mousePos)
		onMarker := input.mouseInWindow && ui.contains(popover.anchor, input.mousePos)
		if !inside && !onMarker {
			State_closeEditHistory(state)
			ui.requestFrame(ctx)
			return
		}
	}
	view := buildEditHistoryView(state, popover^)
	if !view.visible {
		State_closeEditHistory(state)
		ui.requestFrame(ctx)
		return
	}

	window := ctx.windowRect
	padding := ui.dp(ctx, PANEL_PADDING)
	gap := ui.dp(ctx, 4)
	width := min(ui.dp(ctx, EDIT_HISTORY_WIDTH), window.w - padding * 2)
	textW := width - padding * 2
	lineH := ui.lineHeight(ctx)
	maxH := window.h * EDIT_HISTORY_MAX_HEIGHT_SHARE

	// Each row: its label and time on one line, then the text or the note (and why it failed).
	rowHeights := make([]f32, len(view.rows), context.temp_allocator)
	for row, index in view.rows {
		height := lineH
		if len(row.content) > 0 {
			height += ui.wrappedTextHeight(ctx, row.content, textW)
		}
		if len(row.note) > 0 {
			height += lineH
		}
		if len(row.detail) > 0 {
			height += ui.wrappedTextHeight(ctx, row.detail, textW)
		}
		rowHeights[index] = height + gap
	}
	fixedH := padding * 2 + lineH + gap
	if len(view.failedNote) > 0 {
		fixedH += lineH
	}
	if view.loading {
		fixedH += lineH
	}
	// Keep the original and as many of the newest edits as fit; say how many were left out.
	first := 1
	total := fixedH
	if len(view.rows) > 0 {
		total += rowHeights[0]
	}
	for index := len(view.rows) - 1; index >= 1; index -= 1 {
		if total + rowHeights[index] + lineH > maxH {
			first = index + 1
			break
		}
		total += rowHeights[index]
	}
	skipped := max(0, first - 1)
	if skipped > 0 {
		total += lineH
	}

	anchor := popover.anchor
	rect := ui.Rect{anchor.x, anchor.y + anchor.h, width, total}
	if rect.y + rect.h > window.y + window.h && anchor.y - total >= window.y {
		rect.y = anchor.y - total
	}
	rect.x = clamp(rect.x, window.x, max(window.x, window.x + window.w - width))
	rect.y = clamp(rect.y, window.y, max(window.y, window.y + window.h - total))
	popover.rect = rect

	radius := ui.dp(ctx, ctx.theme.cornerRadius)
	ui.fillRoundedRect(ctx, rect, radius, ctx.theme.border)
	ui.fillRoundedRect(ctx, ui.shrink(rect, max(1, ui.dp(ctx, 1))), radius, ctx.theme.elevated)
	content := ui.shrink(rect, padding)
	ui.label(ctx, ui.cutTop(&content, lineH), MESSAGE_EDIT_HISTORY_TITLE, ctx.theme.fg, .Bold)
	_ = ui.cutTop(&content, gap)
	if len(view.failedNote) > 0 {
		ui.label(ctx, ui.cutTop(&content, lineH), view.failedNote, ctx.theme.warning)
	}
	if view.loading {
		ui.label(ctx, ui.cutTop(&content, lineH), MESSAGE_EDIT_HISTORY_LOADING, ctx.theme.fgMuted)
	}
	for row, index in view.rows {
		if index > 0 && index < first {
			if index == 1 {
				ui.label(
					ctx,
					ui.cutTop(&content, lineH),
					fmt.tprintf("… %d earlier edits not shown", skipped),
					ctx.theme.fgMuted,
				)
			}
			continue
		}
		// The version's name at the left (the one shown in the transcript in the primary
		// colour) and its time at the right.
		heading := ui.cutTop(&content, lineH)
		headingColor := row.shown ? ctx.theme.primary : ctx.theme.fgMuted
		ui.label(ctx, heading, row.time, ctx.theme.fgMuted, .Regular, .Right)
		ui.label(ctx, heading, row.label, headingColor, .Bold)
		if len(row.content) > 0 {
			height := ui.wrappedTextHeight(ctx, row.content, textW)
			ui.wrappedLabel(ctx, ui.cutTop(&content, height), row.content, ctx.theme.fg)
		}
		if len(row.note) > 0 {
			color := row.failed ? ctx.theme.warning : ctx.theme.fgMuted
			ui.label(ctx, ui.cutTop(&content, lineH), row.note, color, .Italic)
		}
		if len(row.detail) > 0 {
			height := ui.wrappedTextHeight(ctx, row.detail, textW)
			ui.wrappedLabel(ctx, ui.cutTop(&content, height), row.detail, ctx.theme.fgMuted)
		}
		_ = ui.cutTop(&content, gap)
	}
}
