package client

import "ui"
import SDL "vendor:sdl3"

// Draws the encryption key UI from e2ee_view_model.odin. Widget IDs for automation:
// verify-dialog (the overlay), verify-mark, verify-close (server ID, user ID); key-banner-verify,
// key-banner-trust, key-banner-dismiss (server ID, peer user ID).

VERIFY_DIALOG_WIDTH :: 460

// Draws a row's key indicator at the right of content and takes its width.
viewKeyIndicator :: proc(ctx: ^ui.Context, content: ^ui.Rect, keyState: E2EEKeyState) {
	text, tone := e2eeKeyIndicator(keyState)
	if len(text) == 0 {
		return
	}
	color := ctx.theme.fgMuted
	switch tone {
	case .Muted:
	case .Good:
		color = ctx.theme.success
	case .Warning:
		color = ctx.theme.warning
	case .Danger:
		color = ctx.theme.danger
	}
	width := ui.textSize(ui.textGet(ctx, 0, .Regular, text)).x + ui.dp(ctx, 6)
	if width > content.w / 2 {
		return
	}
	area := ui.cutRight(content, width)
	ui.label(ctx, area, text, color, .Regular, .Right)
}

// The key banner above a direct conversation (buildE2EEKeyBanner).
viewE2EEKeyBanner :: proc(
	state: ^State,
	ctx: ^ui.Context,
	area: ^ui.Rect,
	serverID, peerUserID: int,
) {
	view := buildE2EEKeyBanner(state, serverID, peerUserID)
	if !view.visible {
		return
	}
	padding := ui.dp(ctx, COMPOSER_PADDING)
	accentW := ui.dp(ctx, 3)
	textW := area.w - padding * 4 - accentW
	textH := ui.wrappedTextHeight(ctx, view.text, textW)
	hasActions := view.showVerify || view.showTrust || view.showDismiss
	actionsH := hasActions ? ui.dp(ctx, ROW_HEIGHT) + ui.dp(ctx, PANEL_PADDING) : 0
	outer := ui.cutTop(area, textH + actionsH + padding * 3)
	box := ui.shrinkXY(outer, padding, 0)
	box.y += padding
	box.h -= padding
	ui.fillRoundedRect(ctx, box, ui.dp(ctx, ctx.theme.cornerRadius), ctx.theme.elevated)
	accent := view.tone == .Warning ? ctx.theme.danger : ctx.theme.primary
	ui.fillRect(ctx, ui.Rect{box.x, box.y, accentW, box.h}, accent)

	content := ui.shrinkXY(box, padding, padding / 2)
	_ = ui.cutLeft(&content, accentW)
	ui.wrappedLabel(ctx, ui.cutTop(&content, textH), view.text, ctx.theme.fg)
	if !hasActions {
		return
	}
	_ = ui.cutTop(&content, ui.dp(ctx, PANEL_PADDING))
	row := ui.cutTop(&content, ui.dp(ctx, ROW_HEIGHT))
	verify, trust, dismiss := false, false, false
	if view.showVerify {
		verify = viewE2EEButton(
			ctx,
			&row,
			ui.idOf("key-banner-verify", serverID, peerUserID),
			"Verify",
			true,
		)
	}
	if view.showTrust {
		trust = viewE2EEButton(
			ctx,
			&row,
			ui.idOf("key-banner-trust", serverID, peerUserID),
			"Trust the new key",
			false,
		)
	}
	if view.showDismiss {
		dismiss = viewE2EEButton(
			ctx,
			&row,
			ui.idOf("key-banner-dismiss", serverID, peerUserID),
			"Dismiss",
			false,
		)
	}
	switch {
	case verify:
		State_openVerifyDialog(state, serverID, peerUserID)
	case trust:
		State_e2eeTrustNewKey(state, serverID, peerUserID)
	case dismiss:
		State_e2eeDismissNotice(state, serverID, peerUserID)
	}
}

// The Verify encryption… dialog: a modal overlay in the middle of the window. Esc, Close, or a
// click outside closes it.
viewVerifyDialog :: proc(state: ^State, ctx: ^ui.Context) {
	view := buildVerifyDialogView(state)
	if !view.visible {
		if state.verifyDialog.open {
			State_closeVerifyDialog(state)
		}
		return
	}
	overlayID := ui.idOf("verify-dialog", view.serverID, view.userID)
	if ui.overlayPressedOutside(ctx, overlayID) {
		State_closeVerifyDialog(state)
		return
	}
	for event in ui.overlayEvents(ctx, overlayID) {
		if key, isKey := event.(ui.KeyPress); isKey && key.key == SDL.K_ESCAPE {
			State_closeVerifyDialog(state)
			return
		}
	}

	padding := ui.dp(ctx, PANEL_PADDING * 2)
	window := ctx.windowRect
	width := min(ui.dp(ctx, VERIFY_DIALOG_WIDTH), window.w - padding * 2)
	textW := width - padding * 2
	rowH := ui.dp(ctx, ROW_HEIGHT)
	explanationH := ui.wrappedTextHeight(ctx, view.explanation, textW)
	stateH := ui.wrappedTextHeight(ctx, view.stateText, textW)
	numberRows := len(view.safetyNumber) > 0 ? 3 : 1
	height :=
		padding * 2 +
		rowH +
		ui.dp(ctx, PANEL_PADDING) +
		f32(numberRows) * rowH +
		ui.dp(ctx, PANEL_PADDING) +
		explanationH +
		ui.dp(ctx, PANEL_PADDING) +
		stateH +
		ui.dp(ctx, PANEL_PADDING) +
		rowH
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
	_ = ui.cutTop(&content, ui.dp(ctx, PANEL_PADDING))
	if len(view.safetyNumber) > 0 {
		for numberRow in view.safetyNumberRows {
			ui.label(ctx, ui.cutTop(&content, rowH), numberRow, ctx.theme.fg, .Bold, .Center)
		}
	} else {
		ui.label(
			ctx,
			ui.cutTop(&content, rowH),
			"No key to compare yet",
			ctx.theme.fgMuted,
			.Regular,
			.Center,
		)
	}
	_ = ui.cutTop(&content, ui.dp(ctx, PANEL_PADDING))
	ui.wrappedLabel(ctx, ui.cutTop(&content, explanationH), view.explanation, ctx.theme.fgMuted)
	_ = ui.cutTop(&content, ui.dp(ctx, PANEL_PADDING))
	stateColor := view.stateTone == .Warning ? ctx.theme.warning : ctx.theme.fg
	ui.wrappedLabel(ctx, ui.cutTop(&content, stateH), view.stateText, stateColor)
	_ = ui.cutTop(&content, ui.dp(ctx, PANEL_PADDING))
	row := ui.cutTop(&content, rowH)

	closeClicked := viewE2EEButton(
		ctx,
		&row,
		ui.idOf("verify-close", view.serverID, view.userID),
		"Close",
		false,
	)
	markClicked := false
	if view.markEnabled {
		markClicked = viewE2EEButton(
			ctx,
			&row,
			ui.idOf("verify-mark", view.serverID, view.userID),
			view.markLabel,
			true,
		)
	} else if view.markLabel == "Verified" {
		ui.label(ctx, row, view.markLabel, ctx.theme.success, .Bold)
	}
	switch {
	case markClicked:
		State_verifyDialogMarkVerified(state)
	case closeClicked:
		State_closeVerifyDialog(state)
	}
}

// Lays out one button from the left of row and returns whether it was clicked.
@(private = "file")
viewE2EEButton :: proc(
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
