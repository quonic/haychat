package client

import "../common"
import "core:fmt"
import "core:strings"
import SDL "vendor:sdl3"
import "ui"

// Registration screens (protocol 25, #43 G2): the sign-up screen in the main pane, the invite
// link confirmation over everything, and the Admin section's Registration, Invites and Sign-up
// requests parts (drawn by viewAdminSection through viewRegistrationAdmin).
//
// Widget IDs for GUI automation (all with the server ID first):
// - Sign-up screen: signup-code (the field), signup-paste, signup-reason (approval mode),
//   signup-submit ("Sign up"), signup-check-again ("Check again"), signup-start-again
//   ("Start again").
// - Link confirmation: link-confirm ("Join" or "Continue") and link-cancel ("Cancel" or
//   "Close"), with no server ID.
// - Server settings: server-settings-invite-code (Use an invite code).
// - Admin → Registration: admin-registration-mode (then 1 Open, 2 Invite only, 3 Invite +
//   approval).
// - Admin → Invites: admin-invite-new ("New invite…"); in the form admin-invite-note,
//   admin-invite-expiry (index: 0 1 hour, 1 1 day, 2 7 days, 3 30 days, 4 never),
//   admin-invite-uses (index: 0 one, 1 five, 2 25, 3 100, 4 no limit), admin-invite-role
//   (role ID), admin-invite-room (room ID), admin-invite-skip, admin-invite-create ("Create
//   code"), admin-invite-cancel; the code shown once: admin-invite-copy ("Copy"),
//   admin-invite-copy-link ("Copy link"), admin-invite-done ("Done"); per code
//   admin-invite-revoke (invite ID).
// - Admin → Sign-up requests (the badge reads "N pending"): admin-request-approve and
//   admin-request-decline (request ID), then admin-request-reason, admin-request-decline-confirm
//   ("Decline") and admin-request-decline-cancel.
// - Admin → Members: admin-member-unrestrict ("Lift restriction", user ID).

SIGN_UP_COLUMN_WIDTH :: 460
SIGN_UP_REASON_HEIGHT :: 96
LINK_DIALOG_WIDTH :: 460

// ── Sign-up screen ────────────────────────────────────────────────

viewSignUp :: proc(state: ^State, ctx: ^ui.Context, r: ui.Rect) {
	view := buildSignUpView(state)
	if !view.visible {
		return
	}
	serverID := view.serverID
	area := r
	viewHeader(ctx, &area, view.title)
	padding := ui.dp(ctx, 24)
	width := min(area.w - padding * 2, ui.dp(ctx, SIGN_UP_COLUMN_WIDTH))
	column := ui.Rect{area.x + (area.w - width) / 2, area.y + padding, width, area.h - padding}
	gap := ui.dp(ctx, SETTINGS_LABEL_GAP)
	rowH := ui.dp(ctx, ROW_HEIGHT + 4)

	serverSettingsWrapped(ctx, &column, view.text, ctx.theme.fg)
	_ = ui.cutTop(&column, gap * 3)

	submit, paste, checkAgain, startAgain := false, false, false, false
	if view.showForm {
		form := State_signUpFormFor(state, serverID)
		serverSettingsLabel(ctx, &column, view.codeOptional ? "Invite code (optional)" : "Invite code")
		codeID := ui.idOf("signup-code", serverID)
		pasteW := ui.dp(ctx, SERVER_SETTINGS_BUTTON_WIDTH)
		fieldH := ui.textInputHeight(ctx, codeID, form.code[:], width - pasteW - gap)
		fields := ui.cutTop(&column, max(fieldH, rowH))
		pasteRect := ui.cutRight(&fields, pasteW)
		_ = ui.cutRight(&fields, gap)
		if serverSettingsField(
			ctx,
			fields,
			codeID,
			&form.code,
			"XXXX-XXXX-XXXX-…",
			common.INVITE_CODE_TEXT_MAX_BYTES,
		) {
			submit = true
		}
		paste = serverSettingsButton(
			ctx,
			&pasteRect,
			ui.idOf("signup-paste", serverID),
			"Paste",
			.Plain,
		)
		_ = ui.cutTop(&column, gap)
		serverSettingsWrapped(
			ctx,
			&column,
			"Dashes and spaces do not matter. The code goes only to this server, encrypted.",
			ctx.theme.fgMuted,
		)
		if view.showReason {
			_ = ui.cutTop(&column, gap * 3)
			serverSettingsLabel(ctx, &column, "Why you are signing up")
			reasonID := ui.idOf("signup-reason", serverID)
			reasonH := max(
				ui.textInputHeight(ctx, reasonID, form.reason[:], width),
				ui.dp(ctx, SIGN_UP_REASON_HEIGHT),
			)
			_ = ui.textInput(
				ctx,
				reasonID,
				ui.cutTop(&column, reasonH),
				&form.reason,
				"Who you are, for the people who approve sign-ups (up to 500 characters)",
				common.REGISTRATION_REASON_MAX_CHARS * 4,
			)
		}
		_ = ui.cutTop(&column, gap * 2)
		serverSettingsWrapped(ctx, &column, view.nameNote, ctx.theme.fgMuted)
	}
	if len(view.error) > 0 {
		_ = ui.cutTop(&column, gap * 2)
		serverSettingsWrapped(ctx, &column, view.error, ctx.theme.danger)
	}
	_ = ui.cutTop(&column, gap * 3)
	buttons := ui.cutTop(&column, rowH)
	if view.showForm {
		submitID := ui.idOf("signup-submit", serverID)
		if view.submitEnabled {
			if serverSettingsButton(ctx, &buttons, submitID, view.submitLabel, .Primary) {
				submit = true
			}
		} else {
			_ = adminButton(ctx, &buttons, submitID, AdminControl{label = view.submitLabel})
		}
	}
	if view.showCheckAgain {
		label := view.reconnecting ? "Checking…" : "Check again"
		id := ui.idOf("signup-check-again", serverID)
		if view.reconnecting {
			_ = adminButton(ctx, &buttons, id, AdminControl{label = label})
		} else {
			checkAgain = serverSettingsButton(ctx, &buttons, id, label, .Primary)
		}
	}
	if view.showStartAgain {
		label := view.reconnecting ? "Connecting…" : "Start again"
		id := ui.idOf("signup-start-again", serverID)
		if view.reconnecting {
			_ = adminButton(ctx, &buttons, id, AdminControl{label = label})
		} else {
			startAgain = serverSettingsButton(ctx, &buttons, id, label, .Primary)
		}
	}

	switch {
	case paste:
		State_pasteSignUpCode(state, serverID, ui.getClipboardText())
	case submit && view.submitEnabled:
		State_submitSignUp(state, serverID)
	case checkAgain, startAgain:
		State_signUpReconnect(state, serverID)
	}
}

// ── Link confirmation ─────────────────────────────────────────────

viewLinkConfirm :: proc(state: ^State, ctx: ^ui.Context) {
	view := buildLinkConfirmView(state)
	if !view.visible {
		return
	}
	overlayID := ui.idOf("link-dialog")
	for event in ui.overlayEvents(ctx, overlayID) {
		if key, isKey := event.(ui.KeyPress); isKey && key.key == SDL.K_ESCAPE {
			State_cancelPendingLink(state)
			return
		}
	}
	padding := ui.dp(ctx, PANEL_PADDING * 2)
	window := ctx.windowRect
	width := min(ui.dp(ctx, LINK_DIALOG_WIDTH), window.w - padding * 2)
	textW := width - padding * 2
	rowH := ui.dp(ctx, ROW_HEIGHT)
	gap := ui.dp(ctx, PANEL_PADDING)
	titleH := ui.wrappedTextHeight(ctx, view.title, textW, .Bold)
	textH := ui.wrappedTextHeight(ctx, view.text, textW)
	fingerprintH: f32 = 0
	if len(view.fingerprint) > 0 {
		fingerprintH = ui.wrappedTextHeight(ctx, view.fingerprint, textW) + gap
	}
	height := padding * 2 + titleH + gap + textH + gap + fingerprintH + rowH
	rect := ui.Rect {
		window.x + (window.w - width) / 2,
		window.y + max((window.h - height) / 2, 0),
		width,
		height,
	}
	ui.beginOverlay(ctx, overlayID, rect)
	defer ui.endOverlay(ctx)
	ui.fillRoundedRect(ctx, rect, ui.dp(ctx, ctx.theme.cornerRadius), ctx.theme.elevated)
	ui.strokeRect(ctx, rect, ctx.theme.border)
	content := ui.shrink(rect, padding)
	ui.wrappedLabel(ctx, ui.cutTop(&content, titleH), view.title, ctx.theme.fg, .Bold)
	_ = ui.cutTop(&content, gap)
	ui.wrappedLabel(ctx, ui.cutTop(&content, textH), view.text, ctx.theme.fg)
	_ = ui.cutTop(&content, gap)
	if len(view.fingerprint) > 0 {
		ui.wrappedLabel(
			ctx,
			ui.cutTop(&content, fingerprintH - gap),
			view.fingerprint,
			ctx.theme.fgMuted,
		)
		_ = ui.cutTop(&content, gap)
	}
	row := ui.cutTop(&content, rowH)
	confirm := false
	if view.canConfirm {
		confirm = serverSettingsButton(
			ctx,
			&row,
			ui.idOf("link-confirm"),
			view.confirmLabel,
			.Primary,
		)
	}
	cancel := serverSettingsButton(
		ctx,
		&row,
		ui.idOf("link-cancel"),
		view.canConfirm ? "Cancel" : "Close",
		.Plain,
	)
	switch {
	case confirm:
		State_confirmPendingLink(state)
	case cancel:
		State_cancelPendingLink(state)
	}
}

// ── Admin section ─────────────────────────────────────────────────

RegistrationAdminActionKind :: enum u8 {
	None,
	SetMode,
	OpenInviteForm,
	CloseInviteForm,
	SubmitInviteForm,
	SetExpiry,
	SetUses,
	ToggleRole,
	SetRoom,
	ToggleSkip,
	CopyCode,
	CopyLink,
	DismissCreated,
	Revoke,
	Approve,
	OpenDecline,
	CancelDecline,
	SubmitDecline,
}

RegistrationAdminAction :: struct {
	kind: RegistrationAdminActionKind,
	id:   int,
	mode: common.RegistrationMode,
}

// A row of choice buttons (the picked one primary). Returns the clicked choice's ID, or -1.
@(private = "file")
viewChoiceRow :: proc(
	ctx: ^ui.Context,
	column: ^ui.Rect,
	idName: string,
	serverID: int,
	choices: []AdminInviteChoice,
) -> int {
	clicked := -1
	row := ui.cutTop(column, ui.dp(ctx, ROW_HEIGHT))
	for choice in choices {
		id := ui.idOf(idName, serverID, choice.id)
		width := ui.textSize(ui.textGet(ctx, 0, .Regular, choice.label)).x
		width += ui.dp(ctx, ctx.theme.padding * 3)
		if width > row.w && row.w < column.w {
			_ = ui.cutTop(column, ui.dp(ctx, ROW_SPACING))
			row = ui.cutTop(column, ui.dp(ctx, ROW_HEIGHT))
		}
		if !choice.enabled {
			_ = adminButton(ctx, &row, id, AdminControl{label = choice.label})
			continue
		}
		if choice.checked {
			rect := ui.cutLeft(&row, width)
			_ = ui.cutLeft(&row, ui.dp(ctx, PANEL_PADDING / 2))
			options := ui.ButtonOptions {
				align      = .Center,
				font       = .Bold,
				color      = ctx.theme.onPrimary,
				background = ctx.theme.primary,
			}
			if ui.button(ctx, id, rect, choice.label, options) {
				clicked = choice.id
			}
		} else if adminButton(ctx, &row, id, AdminControl{label = choice.label, enabled = true}) {
			clicked = choice.id
		}
	}
	return clicked
}

// A section label with a badge on its right ("2 pending"), when count > 0.
viewLabelWithBadge :: proc(ctx: ^ui.Context, column: ^ui.Rect, text: string, count: int) {
	line := ui.cutTop(column, ui.dp(ctx, ROW_HEIGHT))
	textW := ui.textSize(ui.textGet(ctx, 0, .Bold, text)).x
	label := ui.cutLeft(&line, textW + ui.dp(ctx, PANEL_PADDING))
	ui.label(ctx, label, text, ctx.theme.fgMuted, .Bold)
	if count > 0 {
		adminBadge(ctx, &line, pendingBadgeText(count), ctx.theme.danger)
	}
	_ = ui.cutTop(column, ui.dp(ctx, SETTINGS_LABEL_GAP))
}

// The badge's text (D18): a count, no pop-up. In the temp allocator.
pendingBadgeText :: proc(count: int) -> string {
	return fmt.tprintf("%d pending", count)
}

// Draws Registration, Invites and Sign-up requests into column; returns what was clicked.
viewRegistrationAdmin :: proc(
	state: ^State,
	ctx: ^ui.Context,
	column: ^ui.Rect,
	view: RegistrationAdminView,
	serverID: int,
) -> (
	action: RegistrationAdminAction,
) {
	rowH := ui.dp(ctx, ROW_HEIGHT)
	gap := ui.dp(ctx, PANEL_PADDING)
	labelGap := ui.dp(ctx, SETTINGS_LABEL_GAP)
	sectionGap := ui.dp(ctx, SETTINGS_SECTION_GAP)

	if view.showMode {
		serverSettingsLabel(ctx, column, "Registration")
		choices := make([]AdminInviteChoice, len(REGISTRATION_MODES), context.temp_allocator)
		for mode, index in REGISTRATION_MODES {
			choices[index] = {
				id      = int(mode),
				label   = registrationModeLabel(mode),
				checked = view.mode == mode,
				enabled = true,
			}
		}
		if picked := viewChoiceRow(ctx, column, "admin-registration-mode", serverID, choices);
		   picked > 0 && common.RegistrationMode(picked) != view.mode {
			action = {kind = .SetMode, mode = common.RegistrationMode(picked)}
		}
		_ = ui.cutTop(column, labelGap)
		serverSettingsWrapped(ctx, column, registrationModeText(view.mode), ctx.theme.fgMuted)
		_ = ui.cutTop(column, sectionGap)
	}

	if view.showInvites {
		{
			header := ui.cutTop(column, rowH)
			newControl := AdminControl{label = "New invite…", enabled = !view.form.open}
			newW := ui.textSize(ui.textGet(ctx, 0, .Regular, newControl.label)).x
			newW += ui.dp(ctx, ctx.theme.padding * 3)
			newRect := header
			_ = ui.cutLeft(&newRect, header.w - newW)
			if adminButton(ctx, &newRect, ui.idOf("admin-invite-new", serverID), newControl) {
				action = {kind = .OpenInviteForm}
			}
			ui.label(ctx, header, "Invites", ctx.theme.fgMuted, .Bold)
			_ = ui.cutTop(column, labelGap)
		}
		if len(view.createdCode) > 0 {
			if created := viewCreatedInvite(ctx, column, view, serverID); created.kind != .None {
				action = created
			}
			_ = ui.cutTop(column, labelGap * 2)
		}
		if view.form.open {
			if formAction := viewInviteForm(state, ctx, column, view.form, serverID);
			   formAction.kind != .None {
				action = formAction
			}
			_ = ui.cutTop(column, labelGap * 2)
		}
		if len(view.createError) > 0 {
			serverSettingsWrapped(ctx, column, view.createError, ctx.theme.danger)
			_ = ui.cutTop(column, labelGap)
		}
		for invite in view.invites {
			line := ui.cutTop(column, rowH)
			if invite.canRevoke {
				control := AdminControl{label = "Revoke", enabled = true}
				revokeW := ui.textSize(ui.textGet(ctx, 0, .Regular, control.label)).x
				revokeW += ui.dp(ctx, ctx.theme.padding * 3)
				buttons := ui.cutRight(&line, revokeW)
				_ = ui.cutRight(&line, gap)
				revokeID := ui.idOf("admin-invite-revoke", serverID, invite.inviteID)
				if adminButton(ctx, &buttons, revokeID, control, danger = true) {
					action = {kind = .Revoke, id = invite.inviteID}
				}
			}
			ui.pushClip(ctx, line)
			color := invite.revoked ? ctx.theme.fgMuted : ctx.theme.fg
			ui.label(ctx, line, invite.label, color, .Bold)
			ui.popClip(ctx)
			detailH := ui.wrappedTextHeight(ctx, invite.detail, column.w - ui.dp(ctx, 12))
			detail := ui.cutTop(column, detailH)
			_ = ui.cutLeft(&detail, ui.dp(ctx, 12))
			ui.wrappedLabel(ctx, detail, invite.detail, ctx.theme.fgMuted)
			_ = ui.cutTop(column, ui.dp(ctx, ROW_SPACING * 2))
		}
		if len(view.invites) == 0 {
			text := view.invitesLoaded ? "No invite codes yet." : "The invite list has not arrived yet."
			serverSettingsWrapped(ctx, column, text, ctx.theme.fgMuted)
		}
		_ = ui.cutTop(column, sectionGap)
	}

	if view.showRequests {
		viewLabelWithBadge(ctx, column, "Sign-up requests", view.pendingCount)
		for request in view.requests {
			line := ui.cutTop(column, rowH)
			if request.pending {
				approve := AdminControl{label = "Approve", enabled = true}
				decline := AdminControl{label = "Decline…", enabled = !request.decisionOpen}
				buttonsW :=
					ui.textSize(ui.textGet(ctx, 0, .Regular, approve.label)).x +
					ui.textSize(ui.textGet(ctx, 0, .Regular, decline.label)).x +
					ui.dp(ctx, ctx.theme.padding * 6 + PANEL_PADDING)
				buttons := ui.cutRight(&line, buttonsW)
				_ = ui.cutRight(&line, gap)
				approveID := ui.idOf("admin-request-approve", serverID, request.requestID)
				if adminButton(ctx, &buttons, approveID, approve) {
					action = {kind = .Approve, id = request.requestID}
				}
				declineID := ui.idOf("admin-request-decline", serverID, request.requestID)
				if adminButton(ctx, &buttons, declineID, decline, danger = true) {
					action = {kind = .OpenDecline, id = request.requestID}
				}
			} else {
				statusW := ui.textSize(ui.textGet(ctx, 0, .Regular, request.statusLabel)).x
				statusRect := ui.cutRight(&line, statusW)
				_ = ui.cutRight(&line, gap)
				ui.label(ctx, statusRect, request.statusLabel, ctx.theme.fgMuted)
			}
			ui.pushClip(ctx, line)
			ui.label(ctx, line, request.label, ctx.theme.fg, .Bold)
			ui.popClip(ctx)
			indent := ui.dp(ctx, 12)
			if len(request.reason) > 0 {
				reasonH := ui.wrappedTextHeight(ctx, request.reason, column.w - indent)
				reasonRect := ui.cutTop(column, reasonH)
				_ = ui.cutLeft(&reasonRect, indent)
				ui.wrappedLabel(ctx, reasonRect, request.reason, ctx.theme.fg)
			}
			detailH := ui.wrappedTextHeight(ctx, request.detail, column.w - indent)
			detail := ui.cutTop(column, detailH)
			_ = ui.cutLeft(&detail, indent)
			ui.wrappedLabel(ctx, detail, request.detail, ctx.theme.fgMuted)
			if request.decisionOpen {
				_ = ui.cutTop(column, labelGap)
				if declineAction := viewDeclineForm(state, ctx, column, serverID, request.requestID);
				   declineAction.kind != .None {
					action = declineAction
				}
			}
			_ = ui.cutTop(column, ui.dp(ctx, ROW_SPACING * 2))
		}
		if len(view.requests) == 0 {
			text := view.requestsLoaded ? "No sign-up requests." : "The request list has not arrived yet."
			serverSettingsWrapped(ctx, column, text, ctx.theme.fgMuted)
		}
		_ = ui.cutTop(column, sectionGap)
	}
	return
}

@(private = "file")
viewCreatedInvite :: proc(
	ctx: ^ui.Context,
	column: ^ui.Rect,
	view: RegistrationAdminView,
	serverID: int,
) -> (
	action: RegistrationAdminAction,
) {
	padding := ui.dp(ctx, PANEL_PADDING * 1.5)
	labelGap := ui.dp(ctx, SETTINGS_LABEL_GAP)
	rowH := ui.dp(ctx, ROW_HEIGHT)
	note := "Copy the code or the link now: it is shown only once and cannot be shown again."
	innerW := column.w - padding * 2
	noteH := ui.wrappedTextHeight(ctx, note, innerW)
	detailH := ui.wrappedTextHeight(ctx, view.createdDetail, innerW)
	boxH :=
		padding * 2 +
		ui.lineHeight(ctx, .Bold) * 1.4 +
		labelGap +
		detailH +
		labelGap +
		noteH +
		labelGap * 2 +
		rowH
	inner := adminBox(ctx, column, boxH)
	ui.label(
		ctx,
		ui.cutTop(&inner, ui.lineHeight(ctx, .Bold) * 1.4),
		view.createdCode,
		ctx.theme.fg,
		.Bold,
	)
	_ = ui.cutTop(&inner, labelGap)
	ui.wrappedLabel(ctx, ui.cutTop(&inner, detailH), view.createdDetail, ctx.theme.fgMuted)
	_ = ui.cutTop(&inner, labelGap)
	ui.wrappedLabel(ctx, ui.cutTop(&inner, noteH), note, ctx.theme.warning)
	_ = ui.cutTop(&inner, labelGap * 2)
	buttons := ui.cutTop(&inner, rowH)
	if serverSettingsButton(ctx, &buttons, ui.idOf("admin-invite-copy", serverID), "Copy", .Primary) {
		action = {kind = .CopyCode}
	}
	if serverSettingsButton(
		ctx,
		&buttons,
		ui.idOf("admin-invite-copy-link", serverID),
		"Copy link",
		.Plain,
	) {
		action = {kind = .CopyLink}
	}
	if serverSettingsButton(ctx, &buttons, ui.idOf("admin-invite-done", serverID), "Done", .Plain) {
		action = {kind = .DismissCreated}
	}
	return
}

@(private = "file")
viewInviteForm :: proc(
	state: ^State,
	ctx: ^ui.Context,
	column: ^ui.Rect,
	view: InviteFormView,
	serverID: int,
) -> (
	action: RegistrationAdminAction,
) {
	labelGap := ui.dp(ctx, SETTINGS_LABEL_GAP)
	rowH := ui.dp(ctx, ROW_HEIGHT)
	form := &state.inviteForm
	serverSettingsLabel(ctx, column, "Note (only inviters and admins see it)")
	noteID := ui.idOf("admin-invite-note", serverID)
	noteRect := ui.cutTop(column, ui.textInputHeight(ctx, noteID, form.note[:], column.w))
	if serverSettingsField(
		ctx,
		noteRect,
		noteID,
		&form.note,
		"Who the code is for",
		common.INVITE_NOTE_MAX_BYTES,
	) {
		action = {kind = .SubmitInviteForm}
	}
	_ = ui.cutTop(column, labelGap * 2)
	serverSettingsLabel(ctx, column, "Expires after")
	if picked := viewChoiceRow(ctx, column, "admin-invite-expiry", serverID, view.expiry);
	   picked >= 0 {
		action = {kind = .SetExpiry, id = picked}
	}
	_ = ui.cutTop(column, labelGap * 2)
	serverSettingsLabel(ctx, column, "Uses")
	if picked := viewChoiceRow(ctx, column, "admin-invite-uses", serverID, view.uses);
	   picked >= 0 {
		action = {kind = .SetUses, id = picked}
	}
	if view.isAdmin {
		_ = ui.cutTop(column, labelGap * 2)
		serverSettingsLabel(ctx, column, "Roles the new account gets")
		for role in view.roles {
			if adminCheckbox(
				ctx,
				column,
				ui.idOf("admin-invite-role", serverID, role.id),
				role.label,
				role.checked,
				true,
			) {
				action = {kind = .ToggleRole, id = role.id}
			}
		}
		if len(view.roles) == 0 {
			serverSettingsWrapped(ctx, column, "No roles other than admin.", ctx.theme.fgMuted)
		}
		_ = ui.cutTop(column, labelGap * 2)
		serverSettingsLabel(ctx, column, "Restrict the new account to one room")
		for room in view.rooms {
			if adminCheckbox(
				ctx,
				column,
				ui.idOf("admin-invite-room", serverID, room.id),
				room.label,
				room.checked,
				true,
			) {
				action = {kind = .SetRoom, id = room.id}
			}
		}
		if len(view.rooms) == 0 {
			serverSettingsWrapped(
				ctx,
				column,
				"Only unencrypted Member invite and Admin invite rooms can be chosen.",
				ctx.theme.fgMuted,
			)
		}
		_ = ui.cutTop(column, labelGap * 2)
		if adminCheckbox(
			ctx,
			column,
			ui.idOf("admin-invite-skip", serverID),
			"Skip approval (Invite + approval mode)",
			view.skipApproval,
			true,
		) {
			action = {kind = .ToggleSkip}
		}
	} else {
		_ = ui.cutTop(column, labelGap)
		serverSettingsWrapped(
			ctx,
			column,
			"Your codes expire within 7 days. Admins can also give roles or a room.",
			ctx.theme.fgMuted,
		)
	}
	if len(view.error) > 0 {
		_ = ui.cutTop(column, labelGap)
		serverSettingsWrapped(ctx, column, view.error, ctx.theme.danger)
	}
	_ = ui.cutTop(column, labelGap * 2)
	buttons := ui.cutTop(column, rowH + ui.dp(ctx, 4))
	createID := ui.idOf("admin-invite-create", serverID)
	if view.pending {
		_ = adminButton(ctx, &buttons, createID, AdminControl{label = "Creating…"})
	} else if serverSettingsButton(ctx, &buttons, createID, "Create code", .Primary) {
		action = {kind = .SubmitInviteForm}
	}
	if serverSettingsButton(
		ctx,
		&buttons,
		ui.idOf("admin-invite-cancel", serverID),
		"Cancel",
		.Plain,
	) {
		action = {kind = .CloseInviteForm}
	}
	return
}

@(private = "file")
viewDeclineForm :: proc(
	state: ^State,
	ctx: ^ui.Context,
	column: ^ui.Rect,
	serverID, requestID: int,
) -> (
	action: RegistrationAdminAction,
) {
	labelGap := ui.dp(ctx, SETTINGS_LABEL_GAP)
	form := &state.decisionForm
	reasonID := ui.idOf("admin-request-reason", serverID, requestID)
	reasonRect := ui.cutTop(column, ui.textInputHeight(ctx, reasonID, form.reason[:], column.w))
	_ = ui.textInput(
		ctx,
		reasonID,
		reasonRect,
		&form.reason,
		"Reason, shown to them (optional)",
		common.REGISTRATION_REASON_MAX_CHARS * 4,
	)
	_ = ui.cutTop(column, labelGap)
	buttons := ui.cutTop(column, ui.dp(ctx, ROW_HEIGHT + 4))
	if serverSettingsButton(
		ctx,
		&buttons,
		ui.idOf("admin-request-decline-confirm", serverID, requestID),
		"Decline",
		.DangerArmed,
	) {
		action = {kind = .SubmitDecline, id = requestID}
	}
	if serverSettingsButton(
		ctx,
		&buttons,
		ui.idOf("admin-request-decline-cancel", serverID, requestID),
		"Cancel",
		.Plain,
	) {
		action = {kind = .CancelDecline}
	}
	return
}

// Runs what viewRegistrationAdmin returned, after the section was drawn.
runRegistrationAdminAction :: proc(
	state: ^State,
	serverID: int,
	action: RegistrationAdminAction,
	view: RegistrationAdminView,
) {
	switch action.kind {
	case .None:
	case .SetMode:
		State_setRegistrationMode(state, serverID, action.mode)
	case .OpenInviteForm:
		State_dismissCreatedInvite(state, serverID)
		State_openInviteForm(state, serverID)
	case .CloseInviteForm:
		State_closeInviteForm(state)
	case .SubmitInviteForm:
		State_submitInviteForm(state)
	case .SetExpiry:
		State_setInviteFormExpiry(state, action.id)
	case .SetUses:
		State_setInviteFormUses(state, action.id)
	case .ToggleRole:
		State_toggleInviteFormRole(state, action.id)
	case .SetRoom:
		State_setInviteFormRoom(state, action.id)
	case .ToggleSkip:
		State_toggleInviteFormSkipApproval(state)
	case .CopyCode:
		ui.setClipboardText(view.createdCode)
	case .CopyLink:
		ui.setClipboardText(view.createdLink)
	case .DismissCreated:
		State_dismissCreatedInvite(state, serverID)
	case .Revoke:
		State_revokeInvite(state, serverID, action.id)
	case .Approve:
		State_decideRegistration(state, serverID, action.id, true, "")
	case .OpenDecline:
		State_openDecisionForm(state, action.id)
	case .CancelDecline:
		DecisionForm_close(&state.decisionForm)
	case .SubmitDecline:
		State_submitDecline(state, serverID)
	}
}

// The sidebar gear with the approver badge (D18): "⚙ 2" while requests are pending.
serverSettingsGearText :: proc(state: ^State, serverID: int) -> string {
	count := State_pendingRegistrationCount(state, serverID)
	if count <= 0 {
		return "⚙"
	}
	return strings.concatenate({"⚙ ", fmt.tprintf("%d", count)}, context.temp_allocator)
}
