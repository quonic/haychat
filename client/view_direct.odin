package client

import "core:fmt"
import "ui"

// The direct conversation pane: the peer's name, online state and whether messages are
// encrypted, the transcript with each message's encryption badge, and a composer, laid out
// like the room pane. It is shown instead of the room while a conversation is open
// (State.selected_dm_peer_id); clicking a channel in the sidebar goes back.
//
// When encryption is not possible (protocol 17, design 4.6) the composer is replaced by a
// banner saying why, with the "Send without encryption" switch; with the switch on, the
// composer comes back under a red "Unencrypted: the server can read this" label and a "Send
// unencrypted" button. Widget IDs (server ID, peer user ID): dm-input, dm-fallback-switch,
// dm-fallback-confirm, dm-fallback-cancel, dm-send-unencrypted, dm-load-older, dm-transcript.
viewDirectChat :: proc(state: ^State, ctx: ^ui.Context, r: ui.Rect, banner: ^ConnectionBanner) {
	view := buildDirectConversationView(state)
	area := r
	viewHeader(ctx, &area, view.peerLabel, view.subtitle)
	viewConnectionBanner(state, ctx, &area, banner)

	serverID := state.selected_server_id
	peerUserID := view.peerUserID
	viewE2EEKeyBanner(state, ctx, &area, serverID, peerUserID)
	composer := view.composer
	action := DirectComposerAction.None
	attachClicked := false
	chips := ComposerChipsAction {
		removeIndex = -1,
	}
	if draft := State_selectedDirectDraft(state); draft != nil {
		switch composer.mode {
		case .Encrypted, .SettingUp, .Fallback:
			inputID := ui.idOf("dm-input", serverID, peerUserID)
			// Files follow the conversation's encryption, the Send without encryption switch
			// included (F4).
			attach := buildComposerAttachmentsView(state, serverID, 0, peerUserID)
			result: ui.TextInputResult
			result, attachClicked = viewComposer(
				ctx,
				&area,
				inputID,
				draft,
				composer.placeholder,
				view.status,
				attach,
				ui.idOf("dm-attach", serverID, peerUserID),
			)
			if result.submitted || (result.entered && len(attach.chips) > 0) {
				action = .Send
			}
			chips = viewComposerChips(ctx, &area, attach, serverID, .Direct, peerUserID)
			if chips.send {
				action = .Send
				chips.send = false
			}
			if composer.mode == .SettingUp {
				viewComposerNoteLine(ctx, &area, composer.note, ctx.theme.fgMuted)
			}
			if composer.mode == .Fallback {
				if viewDirectFallbackSendRow(ctx, &area, composer, serverID, peerUserID) {
					action = .Send
				}
				viewComposerNoteLine(ctx, &area, composer.warningLabel, ctx.theme.danger)
			}
		case .Blocked, .Confirm:
			if len(view.status) > 0 {
				viewComposerStatusOnly(ctx, &area, view.status)
			}
		}
		if composer.showSwitch {
			bannerAction := viewDirectEncryptionBanner(ctx, &area, composer, serverID, peerUserID)
			if bannerAction != .None {
				action = bannerAction
			}
		}
	} else if len(view.status) > 0 {
		viewComposerStatusOnly(ctx, &area, view.status)
	}
	// Actions run after drawing the composer, like the rest of the pane.
	viewRunComposerAttachments(state, ctx, serverID, 0, peerUserID, attachClicked, chips)
	switch action {
	case .None:
	case .Send:
		State_composerSend(state, serverID, 0, peerUserID)
	case .SwitchOn:
		State_setDirectFallback(state, serverID, peerUserID, true)
	case .SwitchOff:
		State_setDirectFallback(state, serverID, peerUserID, false)
	case .Confirm:
		State_confirmDirectFallback(state, serverID, peerUserID)
	case .Cancel:
		State_cancelDirectFallback(state, serverID, peerUserID)
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
			ui.idOf("dm-load-older", serverID, peerUserID),
			historyRow,
			"Load older messages",
			{align = .Center, color = ctx.theme.primary},
		) {
			State_loadOlderDirectHistory(state)
		}
	}

	emptyText := fmt.tprintf("No messages with %s yet. Say hi!", view.peerLabel)
	if view.isLoadingHistory {
		emptyText = "Loading messages…"
	}
	transcript := ui.transcript(
		ctx,
		ui.idOf("dm-transcript", serverID, peerUserID),
		area,
		transcriptUnits(ctx, view.lines, serverID, .Direct, peerUserID),
		emptyText,
	)
	viewTranscriptContextMenu(state, ctx, transcript, serverID, .Direct, peerUserID)
	viewTranscriptCardAction(state, ctx, transcript, view.lines, serverID, .Direct, peerUserID)
}

DirectComposerAction :: enum u8 {
	None,
	Send,
	SwitchOn,
	SwitchOff,
	Confirm,
	Cancel,
}

// One line of wrapped text along the bottom of area (above what was cut before it).
viewComposerNoteLine :: proc(ctx: ^ui.Context, area: ^ui.Rect, text: string, color: ui.Color) {
	if len(text) == 0 {
		return
	}
	padding := ui.dp(ctx, COMPOSER_PADDING)
	textH := ui.wrappedTextHeight(ctx, text, area.w - padding * 2)
	line := ui.cutBottom(area, textH)
	ui.wrappedLabel(ctx, ui.shrinkXY(line, padding, 0), text, color)
}

// The "Send unencrypted" button under the label, right-aligned. Returns whether it was clicked.
@(private = "file")
viewDirectFallbackSendRow :: proc(
	ctx: ^ui.Context,
	area: ^ui.Rect,
	composer: DirectComposerView,
	serverID, peerUserID: int,
) -> bool {
	padding := ui.dp(ctx, COMPOSER_PADDING)
	row := ui.shrinkXY(ui.cutBottom(area, ui.dp(ctx, ROW_HEIGHT) + padding), padding, 0)
	width :=
		ui.textSize(ui.textGet(ctx, 0, .Bold, composer.sendLabel)).x +
		ui.dp(ctx, ctx.theme.padding * 4)
	button := ui.cutRight(&row, width)
	button.h = ui.dp(ctx, ROW_HEIGHT)
	return ui.button(
		ctx,
		ui.idOf("dm-send-unencrypted", serverID, peerUserID),
		button,
		composer.sendLabel,
		{align = .Center, font = .Bold, background = ctx.theme.danger, color = ctx.theme.onPrimary},
	)
}

// The banner above the composer when encryption is not possible: why, and the switch (or, the
// first time, its confirmation). Returns what was clicked.
@(private = "file")
viewDirectEncryptionBanner :: proc(
	ctx: ^ui.Context,
	area: ^ui.Rect,
	composer: DirectComposerView,
	serverID, peerUserID: int,
) -> DirectComposerAction {
	padding := ui.dp(ctx, COMPOSER_PADDING)
	accentW := ui.dp(ctx, 3)
	textW := area.w - padding * 4 - accentW
	text := composer.mode == .Confirm ? composer.confirmText : composer.note
	textH := ui.wrappedTextHeight(ctx, text, textW)
	rowH := ui.dp(ctx, ROW_HEIGHT)
	outer := ui.cutBottom(area, textH + rowH + ui.dp(ctx, PANEL_PADDING) + padding * 3)
	box := ui.shrinkXY(outer, padding, 0)
	box.y += padding
	box.h -= padding
	ui.fillRoundedRect(ctx, box, ui.dp(ctx, ctx.theme.cornerRadius), ctx.theme.elevated)
	ui.fillRect(ctx, ui.Rect{box.x, box.y, accentW, box.h}, ctx.theme.warning)
	content := ui.shrinkXY(box, padding, padding / 2)
	_ = ui.cutLeft(&content, accentW)
	ui.wrappedLabel(ctx, ui.cutTop(&content, textH), text, ctx.theme.fg)
	_ = ui.cutTop(&content, ui.dp(ctx, PANEL_PADDING))
	row := ui.cutTop(&content, rowH)
	if composer.mode == .Confirm {
		if viewDirectBannerButton(
			ctx,
			&row,
			ui.idOf("dm-fallback-confirm", serverID, peerUserID),
			composer.confirmLabel,
			true,
		) {
			return .Confirm
		}
		if viewDirectBannerButton(
			ctx,
			&row,
			ui.idOf("dm-fallback-cancel", serverID, peerUserID),
			composer.cancelLabel,
			false,
		) {
			return .Cancel
		}
		return .None
	}
	label := fmt.tprintf("%s: %s", composer.switchLabel, composer.switchOn ? "On" : "Off")
	if viewDirectBannerButton(
		ctx,
		&row,
		ui.idOf("dm-fallback-switch", serverID, peerUserID),
		label,
		composer.switchOn,
	) {
		return composer.switchOn ? .SwitchOff : .SwitchOn
	}
	return .None
}

@(private = "file")
viewDirectBannerButton :: proc(
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
