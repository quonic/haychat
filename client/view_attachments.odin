package client

import "../common"
import "core:fmt"
import "ui"
import SDL "vendor:sdl3"

// Draws the attachments UI from attachment_ui.odin (attachments plan F4). Widget IDs for GUI
// automation, rooms first and direct conversations second (server ID, then the room ID or the
// peer's user ID):
//
// - the paperclip: room-attach / dm-attach (server, conversation);
// - a chip: room-file-chip / dm-file-chip and its remove button room-file-chip-remove /
//   dm-file-chip-remove (server, conversation, the chip's index from 0);
// - the draft's Send button, shown while it has files: room-send / dm-send (server,
//   conversation); while the gate is shut it is drawn disabled with no widget, and the reason
//   is the line under the chips;
// - a file card: room-file / dm-file, its Save… room-file-save / dm-file-save and, while it
//   saves, Cancel room-file-cancel / dm-file-cancel (server, conversation, message ID, the
//   file's index);
// - the Remove attachment confirmation: attachment-remove-dialog (the overlay),
//   attachment-remove-reason, attachment-remove-confirm and attachment-remove-cancel (server);
// - Admin → Storage: admin-storage-refresh (server).
// - Removed files (protocol 29): admin-removals-refresh and admin-removals-more (Load more)
//   (server).
//
// Automation cannot drive the native dialogs: `attach-file PATH` and `save-path PATH` answer
// them (ui_script.odin).

COMPOSER_CHIP_WIDTH :: 220
COMPOSER_CHIP_PROGRESS_HEIGHT :: 3
ATTACHMENT_REMOVE_DIALOG_WIDTH :: 460
// The card's icon: a page, never a preview of the file (D19, D23).
FILE_CARD_ICON :: "📄"
COMPOSER_ATTACH_ICON :: "📎"

// Transcript unit keys (transcriptUnits): eight per message. Slot 0 is the sender header, 1 the
// text, 2..5 the file cards, 6 the changed-list notice.
TRANSCRIPT_SLOT_SENDER :: 0
TRANSCRIPT_SLOT_TEXT :: 1
TRANSCRIPT_SLOT_FIRST_CARD :: 2
TRANSCRIPT_SLOT_FILES_CHANGED :: 6

transcriptUnitKey :: proc(messageID, slot: int) -> u64 {
	return u64(i64(messageID * 8 + slot))
}

transcriptUnitDecode :: proc(key: u64) -> (messageID, slot: int) {
	value := i64(key)
	return int(value >> 3), int(value & 7)
}

// The widget names of a conversation kind's file controls.
@(private = "file")
fileWidgetName :: proc(kind: common.ReadMarkerKind, room, direct: string) -> string {
	return kind == .Room ? room : direct
}

// Builds transcript units for room and direct messages. Consecutive messages from the same
// sender share one sender header; a message's files follow its text as cards.
transcriptUnits :: proc(
	ctx: ^ui.Context,
	lines: []TranscriptLine,
	serverID: int,
	kind: common.ReadMarkerKind,
	conversationID: int,
) -> []ui.TranscriptUnit {
	units := make([dynamic]ui.TranscriptUnit, 0, len(lines) * 2, context.temp_allocator)
	for line, index in lines {
		sameSender := index > 0 && lines[index - 1].senderLabel == line.senderLabel
		if !sameSender {
			append(
				&units,
				ui.TranscriptUnit {
					key = transcriptUnitKey(line.messageID, TRANSCRIPT_SLOT_SENDER),
					text = line.senderLabel,
					font = .Bold,
					color = line.isSelf ? ctx.theme.primary : ctx.theme.fg,
					gapBefore = index > 0 ? MESSAGE_GROUP_GAP : 0,
					copySep = ": ",
				},
			)
		}
		hasFiles := len(line.cards) > 0 || line.filesChanged
		// A message with only files has no text line (D15), but the badge needs one.
		if len(line.content) > 0 || !hasFiles || len(line.badge) > 0 {
			append(
				&units,
				ui.TranscriptUnit {
					key = transcriptUnitKey(line.messageID, TRANSCRIPT_SLOT_TEXT),
					text = line.content,
					font = .Regular,
					color = line.placeholder ? ctx.theme.fgMuted : ctx.theme.fg,
					gapBefore = MESSAGE_LINE_GAP,
					copySep = "\n",
					badge = line.badge,
					badgeColor = e2eeIndicatorColor(ctx, line.badgeTone),
				},
			)
		}
		if line.filesChanged {
			append(
				&units,
				ui.TranscriptUnit {
					key = transcriptUnitKey(line.messageID, TRANSCRIPT_SLOT_FILES_CHANGED),
					text = common.ATTACHMENT_LIST_CHANGED_MESSAGE,
					font = .Regular,
					color = ctx.theme.danger,
					gapBefore = MESSAGE_LINE_GAP,
					copySep = "\n",
				},
			)
		}
		for card in line.cards {
			append(
				&units,
				ui.TranscriptUnit {
					key = transcriptUnitKey(line.messageID, TRANSCRIPT_SLOT_FIRST_CARD + card.index),
					gapBefore = MESSAGE_LINE_GAP * 2,
					card = transcriptCard(ctx, card, serverID, kind, conversationID, line.messageID),
				},
			)
		}
	}
	return units[:]
}

@(private = "file")
transcriptCard :: proc(
	ctx: ^ui.Context,
	card: FileCardView,
	serverID: int,
	kind: common.ReadMarkerKind,
	conversationID, messageID: int,
) -> ^ui.TranscriptCard {
	result := new(ui.TranscriptCard, context.temp_allocator)
	result^ = ui.TranscriptCard {
		id           = ui.idOf(
			fileWidgetName(kind, "room-file", "dm-file"),
			serverID,
			conversationID,
			messageID,
			card.index,
		),
		icon         = FILE_CARD_ICON,
		title        = card.title,
		detail       = card.detail,
		status       = card.status,
		statusColor  = ctx.theme.fgMuted,
		muted        = card.state == .Removed,
		showProgress = card.state == .Saving,
		progress     = card.progress,
	}
	#partial switch card.state {
	case .Saved:
		result.statusColor = ctx.theme.success
	case .Failed:
		result.statusColor = ctx.theme.danger
	case .Removed:
		result.statusColor = ctx.theme.warning
	}
	if card.canSave {
		result.actions[0] = ui.TranscriptCardAction {
			id = ui.idOf(
				fileWidgetName(kind, "room-file-save", "dm-file-save"),
				serverID,
				conversationID,
				messageID,
				card.index,
			),
			label = "Save…",
		}
		result.actionCount = 1
	} else if card.canCancel {
		result.actions[0] = ui.TranscriptCardAction {
			id = ui.idOf(
				fileWidgetName(kind, "room-file-cancel", "dm-file-cancel"),
				serverID,
				conversationID,
				messageID,
				card.index,
			),
			label = "Cancel",
		}
		result.actionCount = 1
	}
	return result
}

// Answers a click on a card's button (ui.transcript's result): Save… or Cancel.
viewTranscriptCardAction :: proc(
	state: ^State,
	ctx: ^ui.Context,
	result: ui.TranscriptResult,
	lines: []TranscriptLine,
	serverID: int,
	kind: common.ReadMarkerKind,
	conversationID: int,
) {
	if !result.cardClicked {
		return
	}
	messageID, slot := transcriptUnitDecode(result.cardKey)
	index := slot - TRANSCRIPT_SLOT_FIRST_CARD
	for line in lines {
		if line.messageID != messageID {
			continue
		}
		for card in line.cards {
			if card.index != index {
				continue
			}
			ref := AttachmentFileRef{serverID, kind, conversationID, messageID, index}
			if card.canSave {
				viewSaveAttachment(state, ctx, ref)
			} else if card.canCancel {
				State_cancelAttachmentSave(state, ref)
			}
			ui.requestFrame(ctx)
			return
		}
	}
}

// Save… (a card's button or its menu): the file's suggested name in the native save dialog, or
// the path automation set with save-path.
viewSaveAttachment :: proc(state: ^State, ctx: ^ui.Context, ref: AttachmentFileRef) {
	name, errorMessage := State_beginAttachmentSave(state, ref)
	if len(errorMessage) > 0 {
		State_setChatStatus(state, errorMessage)
		return
	}
	if path, ok := FileDialogQueue_takeNextSavePath(state.fileDialogs); ok {
		defer delete(path)
		State_attachmentSaveChosen(state, ref, path)
		return
	}
	target := attachmentSaveDialogTarget(ref)
	if dialogError := fileDialogShowSave(State_fileDialogs(state), ctx.window, target, name);
	   len(dialogError) > 0 {
		State_attachmentSaveDialogClosed(state, ref, dialogError)
	}
}

// The paperclip: the native open dialog for this composer (several files may be picked).
viewOpenAttachDialog :: proc(state: ^State, ctx: ^ui.Context, serverID, roomID, peerUserID: int) {
	target := FileDialogTarget {
		serverID   = serverID,
		roomID     = roomID,
		peerUserID = peerUserID,
	}
	if errorMessage := fileDialogShowOpen(State_fileDialogs(state), ctx.window, target);
	   len(errorMessage) > 0 {
		State_setChatStatus(state, errorMessage)
	}
}

// The paperclip at the left of the composer's input, cut from composer. Returns whether it was
// clicked. A disabled one is drawn muted, never clicks, and says why in its tooltip.
viewComposerAttachButton :: proc(
	ctx: ^ui.Context,
	composer: ^ui.Rect,
	view: ComposerAttachmentsView,
	id: ui.ID,
) -> bool {
	if !view.showAttach {
		return false
	}
	size := min(composer.h, ui.dp(ctx, ROW_HEIGHT + 4))
	slot := ui.cutLeft(composer, size)
	_ = ui.cutLeft(composer, ui.dp(ctx, PANEL_PADDING))
	button := ui.Rect{slot.x, slot.y + slot.h - size, size, size}
	if !view.canAttach {
		ui.fillRoundedRect(ctx, button, ui.dp(ctx, ctx.theme.cornerRadius), ctx.theme.surface)
		ui.label(ctx, button, COMPOSER_ATTACH_ICON, ctx.theme.border, align = .Center)
		ui.tooltip(ctx, id, button, view.attachReason)
		return false
	}
	clicked := ui.button(
		ctx,
		id,
		button,
		COMPOSER_ATTACH_ICON,
		{align = .Center, background = ctx.theme.hover},
	)
	ui.tooltip(ctx, id, button, "Attach files (or drop them on the window)")
	return clicked
}

// What the chips row asks for this frame.
ComposerChipsAction :: struct {
	removeIndex: int, // -1 for none
	send:        bool,
}

// The chips of the draft and the Send button, above what was cut before (the composer and its
// status), with the gate's reason under them. Draws nothing without files.
viewComposerChips :: proc(
	ctx: ^ui.Context,
	area: ^ui.Rect,
	view: ComposerAttachmentsView,
	serverID: int,
	kind: common.ReadMarkerKind,
	conversationID: int,
) -> (
	action: ComposerChipsAction,
) {
	action.removeIndex = -1
	if len(view.chips) == 0 {
		return
	}
	padding := ui.dp(ctx, COMPOSER_PADDING)
	if view.sendBlocked && len(view.gateReason) > 0 {
		viewComposerNoteLine(ctx, area, view.gateReason, ctx.theme.warning)
	}
	lineH := ui.lineHeight(ctx)
	chipH := ui.lineHeight(ctx, .Bold) + lineH + ui.dp(ctx, PANEL_PADDING + 6)
	row := ui.shrinkXY(ui.cutBottom(area, chipH + padding), padding, 0)
	row.h = chipH

	// Send at the right end of the row.
	sendText := "Send"
	sendW := ui.textSize(ui.textGet(ctx, 0, .Bold, sendText)).x + ui.dp(ctx, ctx.theme.padding * 4)
	sendSlot := ui.cutRight(&row, sendW)
	_ = ui.cutRight(&row, ui.dp(ctx, PANEL_PADDING))
	buttonH := ui.dp(ctx, ROW_HEIGHT)
	sendRect := ui.Rect{sendSlot.x, sendSlot.y + (sendSlot.h - buttonH) / 2, sendSlot.w, buttonH}
	sendID := ui.idOf(fileWidgetName(kind, "room-send", "dm-send"), serverID, conversationID)
	if view.sendBlocked {
		ui.fillRoundedRect(ctx, sendRect, ui.dp(ctx, ctx.theme.cornerRadius), ctx.theme.surface)
		ui.label(ctx, sendRect, sendText, ctx.theme.fgMuted, .Bold, .Center)
		ui.tooltip(ctx, sendID, sendRect, view.gateReason)
	} else if ui.button(
		ctx,
		sendID,
		sendRect,
		sendText,
		{
			align = .Center,
			font = .Bold,
			color = ctx.theme.onPrimary,
			background = ctx.theme.primary,
		},
	) {
		action.send = true
	}

	gap := ui.dp(ctx, PANEL_PADDING)
	count := f32(len(view.chips))
	chipW := min(ui.dp(ctx, COMPOSER_CHIP_WIDTH), (row.w - gap * (count - 1)) / count)
	radius := ui.dp(ctx, ctx.theme.cornerRadius)
	for chip, index in view.chips {
		rect := ui.cutLeft(&row, chipW)
		_ = ui.cutLeft(&row, gap)
		chipID := ui.idOf(
			fileWidgetName(kind, "room-file-chip", "dm-file-chip"),
			serverID,
			conversationID,
			index,
		)
		border := chip.failed ? ctx.theme.danger : ctx.theme.border
		ui.fillRoundedRect(ctx, rect, radius, border)
		ui.fillRoundedRect(ctx, ui.shrink(rect, max(1, ui.dp(ctx, 1))), radius, ctx.theme.elevated)
		inner := ui.shrink(rect, ui.dp(ctx, 6))
		removeSize := ui.dp(ctx, 22)
		removeSlot := ui.cutRight(&inner, removeSize)
		removeRect := ui.Rect{removeSlot.x, removeSlot.y, removeSize, removeSize}
		removeID := ui.idOf(
			fileWidgetName(kind, "room-file-chip-remove", "dm-file-chip-remove"),
			serverID,
			conversationID,
			index,
		)
		if ui.button(ctx, removeID, removeRect, "×", {align = .Center, color = ctx.theme.fgMuted}) {
			action.removeIndex = index
		}
		ui.tooltip(ctx, removeID, removeRect, "Remove from the message")
		// Registers the chip for automation after its remove button, which takes a press
		// first; a press elsewhere on the chip does nothing.
		_ = ui.interact(ctx, chipID, rect)
		{
			ui.pushClip(ctx, inner)
			defer ui.popClip(ctx)
			ui.label(ctx, ui.cutTop(&inner, ui.lineHeight(ctx, .Bold)), chip.name, ctx.theme.fg, .Bold)
			detailColor := chip.failed ? ctx.theme.danger : ctx.theme.fgMuted
			ui.label(ctx, ui.cutTop(&inner, lineH), chip.detail, detailColor)
		}
		if chip.failed {
			ui.tooltip(ctx, chipID, rect, chip.detail)
		}
		if chip.progress >= 0 {
			barH := ui.dp(ctx, COMPOSER_CHIP_PROGRESS_HEIGHT)
			bar := ui.Rect{rect.x + radius, rect.y + rect.h - barH - 2, rect.w - radius * 2, barH}
			ui.levelMeter(ctx, bar, chip.progress, {color = ctx.theme.primary})
		}
	}
	return
}

// Runs the composer's attachment actions after drawing: the paperclip, a chip's remove and
// Send.
viewRunComposerAttachments :: proc(
	state: ^State,
	ctx: ^ui.Context,
	serverID, roomID, peerUserID: int,
	attachClicked: bool,
	chips: ComposerChipsAction,
) {
	switch {
	case attachClicked:
		viewOpenAttachDialog(state, ctx, serverID, roomID, peerUserID)
	case chips.removeIndex >= 0:
		State_composerRemoveFile(state, serverID, roomID, peerUserID, chips.removeIndex)
		State_clearChatStatus(state)
	case chips.send:
		State_composerSend(state, serverID, roomID, peerUserID)
	}
}

// The Remove attachment confirmation: a modal in the middle of the window with an optional
// reason. Esc, Cancel, or a click outside closes it; it closes by itself once the server
// confirmed the removal.
viewAttachmentRemoveDialog :: proc(state: ^State, ctx: ^ui.Context) {
	view := buildAttachmentRemoveDialogView(state)
	if view.done {
		State_closeAttachmentRemoveDialog(state)
		ui.requestFrame(ctx)
		return
	}
	if !view.visible {
		return
	}
	dialog := &state.attachmentRemoveDialog
	serverID := view.serverID
	overlayID := ui.idOf("attachment-remove-dialog", serverID)
	if ui.overlayPressedOutside(ctx, overlayID) {
		State_closeAttachmentRemoveDialog(state)
		return
	}
	for event in ui.overlayEvents(ctx, overlayID) {
		if key, isKey := event.(ui.KeyPress); isKey && key.key == SDL.K_ESCAPE {
			State_closeAttachmentRemoveDialog(state)
			return
		}
	}

	padding := ui.dp(ctx, PANEL_PADDING * 2)
	window := ctx.windowRect
	width := min(ui.dp(ctx, ATTACHMENT_REMOVE_DIALOG_WIDTH), window.w - padding * 2)
	textW := width - padding * 2
	rowH := ui.dp(ctx, ROW_HEIGHT)
	textH := ui.wrappedTextHeight(ctx, view.text, textW)
	statusH := len(view.status) > 0 ? ui.wrappedTextHeight(ctx, view.status, textW) : 0
	gap := ui.dp(ctx, PANEL_PADDING)
	reasonID := ui.idOf("attachment-remove-reason", serverID)
	inputH := ui.textInputHeight(ctx, reasonID, dialog.reason[:], textW)
	height :=
		padding * 2 +
		rowH +
		gap +
		textH +
		gap +
		ui.lineHeight(ctx) +
		inputH +
		gap +
		statusH +
		gap +
		rowH
	rect := ui.Rect {
		window.x + (window.w - width) / 2,
		window.y + max((window.h - height) / 2, 0),
		width,
		height,
	}
	ui.beginOverlay(ctx, overlayID, rect)
	defer ui.endOverlay(ctx)
	ui.overlayKeyboardToWidgets(ctx, overlayID)
	radius := ui.dp(ctx, ctx.theme.cornerRadius)
	ui.fillRoundedRect(ctx, rect, radius, ctx.theme.elevated)
	ui.strokeRect(ctx, rect, ctx.theme.border)
	content := ui.shrink(rect, padding)
	ui.label(ctx, ui.cutTop(&content, rowH), view.title, ctx.theme.fg, .Bold)
	_ = ui.cutTop(&content, gap)
	ui.wrappedLabel(ctx, ui.cutTop(&content, textH), view.text, ctx.theme.fgMuted)
	_ = ui.cutTop(&content, gap)
	ui.label(ctx, ui.cutTop(&content, ui.lineHeight(ctx)), "Reason (optional)", ctx.theme.fgMuted)
	if !dialog.focused {
		dialog.focused = true
		ui.focusTextInput(ctx, reasonID)
	}
	// Enter removes, with or without a reason; the field stays one line.
	reasonResult := ui.textInput(
		ctx,
		reasonID,
		ui.cutTop(&content, inputH),
		&dialog.reason,
		"Why it was removed",
		common.ATTACHMENT_REMOVE_REASON_MAX_BYTES,
	)
	for index := len(dialog.reason) - 1; index >= 0; index -= 1 {
		if dialog.reason[index] == '\n' || dialog.reason[index] == '\r' {
			ordered_remove(&dialog.reason, index)
		}
	}
	submitted := reasonResult.entered
	_ = ui.cutTop(&content, gap)
	if statusH > 0 {
		color := view.statusError ? ctx.theme.danger : ctx.theme.fgMuted
		ui.wrappedLabel(ctx, ui.cutTop(&content, statusH), view.status, color)
	}
	_ = ui.cutTop(&content, gap)
	row := ui.cutTop(&content, rowH)
	confirmClicked := false
	removeText := view.busy ? "Removing…" : "Remove"
	if serverSettingsButton(
		ctx,
		&row,
		ui.idOf("attachment-remove-confirm", serverID),
		removeText,
		.DangerArmed,
	) {
		confirmClicked = true
	}
	cancelClicked := serverSettingsButton(
		ctx,
		&row,
		ui.idOf("attachment-remove-cancel", serverID),
		"Cancel",
		.Plain,
	)
	switch {
	case cancelClicked:
		State_closeAttachmentRemoveDialog(state)
	case (confirmClicked || submitted) && !view.busy:
		State_submitAttachmentRemoveDialog(state)
	}
	ui.requestFrame(ctx)
}

// Admin → Storage (admins), at the end of the Admin section: used, capacity and free space and
// the accounts by usage. Returns whether Refresh was clicked.
viewAdminStorage :: proc(
	state: ^State,
	ctx: ^ui.Context,
	column: ^ui.Rect,
	serverID: int,
) -> bool {
	view := buildAdminStorageView(state, serverID)
	rowH := ui.dp(ctx, ROW_HEIGHT)
	refresh := false
	{
		header := ui.cutTop(column, rowH)
		refreshControl := AdminControl {
			label   = view.pending ? "Refreshing…" : "Refresh",
			enabled = !view.pending,
		}
		refreshW := ui.textSize(ui.textGet(ctx, 0, .Regular, refreshControl.label)).x
		refreshW += ui.dp(ctx, ctx.theme.padding * 3)
		refreshRect := header
		_ = ui.cutLeft(&refreshRect, header.w - refreshW)
		refresh = adminButton(
			ctx,
			&refreshRect,
			ui.idOf("admin-storage-refresh", serverID),
			refreshControl,
		)
		ui.label(ctx, header, "Storage", ctx.theme.fgMuted, .Bold)
		_ = ui.cutTop(column, ui.dp(ctx, SETTINGS_LABEL_GAP))
	}
	if !view.hasUsage {
		text := view.pending ? "Asking the server…" : "Click Refresh to see the server's storage."
		serverSettingsWrapped(ctx, column, text, ctx.theme.fgMuted)
		return refresh
	}
	labelW := ui.dp(ctx, 140)
	facts := [3][2]string {
		{"Used", view.used},
		{"Capacity", view.capacity},
		{"Free space", view.free},
	}
	for fact in facts {
		line := ui.cutTop(column, ui.lineHeight(ctx) + ui.dp(ctx, 4))
		ui.label(ctx, ui.cutLeft(&line, labelW), fact[0], ctx.theme.fgMuted)
		ui.label(ctx, line, fact[1], ctx.theme.fg)
	}
	_ = ui.cutTop(column, ui.dp(ctx, SETTINGS_LABEL_GAP * 2))
	if len(view.accounts) == 0 {
		serverSettingsWrapped(ctx, column, "No account stores any files.", ctx.theme.fgMuted)
		return refresh
	}
	ui.label(ctx, ui.cutTop(column, ui.lineHeight(ctx)), "By account", ctx.theme.fgMuted, .Bold)
	countW := ui.dp(ctx, 80)
	bytesW := ui.dp(ctx, 100)
	for account in view.accounts {
		line := ui.cutTop(column, ui.lineHeight(ctx) + ui.dp(ctx, 4))
		ui.label(ctx, ui.cutRight(&line, countW), account.count, ctx.theme.fgMuted, align = .Right)
		ui.label(ctx, ui.cutRight(&line, bytesW), account.bytes, ctx.theme.fg, align = .Right)
		ui.pushClip(ctx, line)
		ui.label(ctx, line, account.label, ctx.theme.fg)
		ui.popClip(ctx)
	}
	if !view.pending {
		return refresh
	}
	serverSettingsWrapped(ctx, column, "Asking the server…", ctx.theme.fgMuted)
	return refresh
}

// What Removed files asks for.
AttachmentRemovalsAction :: enum u8 {
	None,
	Refresh,
	LoadMore,
}

// Removed files (admins, protocol 29, #138), after Storage: the removal log newest first, each
// row the file, when, whose, who removed it, where and the reason, with Load more while the
// server has older entries.
viewAttachmentRemovals :: proc(
	state: ^State,
	ctx: ^ui.Context,
	column: ^ui.Rect,
	serverID: int,
) -> AttachmentRemovalsAction {
	view := buildAttachmentRemovalsView(state, serverID)
	rowH := ui.dp(ctx, ROW_HEIGHT)
	action := AttachmentRemovalsAction.None
	{
		header := ui.cutTop(column, rowH)
		refreshControl := AdminControl {
			label   = view.pending ? "Refreshing…" : "Refresh",
			enabled = !view.pending,
		}
		refreshW := ui.textSize(ui.textGet(ctx, 0, .Regular, refreshControl.label)).x
		refreshW += ui.dp(ctx, ctx.theme.padding * 3)
		refreshRect := header
		_ = ui.cutLeft(&refreshRect, header.w - refreshW)
		if adminButton(
			ctx,
			&refreshRect,
			ui.idOf("admin-removals-refresh", serverID),
			refreshControl,
		) {
			action = .Refresh
		}
		ui.label(ctx, header, "Removed files", ctx.theme.fgMuted, .Bold)
		_ = ui.cutTop(column, ui.dp(ctx, SETTINGS_LABEL_GAP))
	}
	if !view.loaded {
		text := view.pending ? "Asking the server…" : "Click Refresh to see removed files."
		serverSettingsWrapped(ctx, column, text, ctx.theme.fgMuted)
		return action
	}
	if len(view.rows) == 0 {
		serverSettingsWrapped(ctx, column, "No file has been removed.", ctx.theme.fgMuted)
		return action
	}
	lineH := ui.lineHeight(ctx) + ui.dp(ctx, 4)
	for row in view.rows {
		first := ui.cutTop(column, lineH)
		timeW := ui.textSize(ui.textGet(ctx, 0, .Regular, row.time)).x + ui.dp(ctx, 8)
		ui.label(ctx, ui.cutRight(&first, timeW), row.time, ctx.theme.fgMuted, align = .Right)
		ui.pushClip(ctx, first)
		ui.label(ctx, first, row.name, ctx.theme.fg, .Bold)
		ui.popClip(ctx)
		serverSettingsWrapped(
			ctx,
			column,
			fmt.tprintf("%s · owner %s · removed by %s", row.place, row.owner, row.removedBy),
			ctx.theme.fgMuted,
		)
		if len(row.reason) > 0 {
			serverSettingsWrapped(
				ctx,
				column,
				fmt.tprintf("Reason: %s", row.reason),
				ctx.theme.fg,
			)
		}
		_ = ui.cutTop(column, ui.dp(ctx, SETTINGS_LABEL_GAP * 2))
	}
	if view.hasMore {
		moreRow := ui.cutTop(column, rowH)
		moreControl := AdminControl {
			label   = view.pending ? "Loading…" : "Load more",
			enabled = !view.pending,
		}
		moreW := ui.textSize(ui.textGet(ctx, 0, .Regular, moreControl.label)).x
		moreW += ui.dp(ctx, ctx.theme.padding * 3)
		moreRect := ui.cutLeft(&moreRow, moreW)
		if adminButton(ctx, &moreRect, ui.idOf("admin-removals-more", serverID), moreControl) {
			action = .LoadMore
		}
	}
	return action
}
