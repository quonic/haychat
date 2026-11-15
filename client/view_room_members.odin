package client

import "../common"
import "core:fmt"
import "ui"

// A room's Members page (room_members.odin), drawn in the main pane like the room form: the
// room's access mode and history setting, its members (Remove for admins), the accounts that
// are not members (Add, when this account may add), and Leave room for a member of a
// non-public room.
//
// Widget IDs for GUI automation (server ID, room ID, then the account's user ID):
// room-members-remove, room-members-add, room-members-leave and room-members-edit (server and
// room ID), room-members-close. Encrypted rooms (protocol 18) add Managers and Admins sections
// with room-members-make-manager and room-members-remove-manager (user ID), and
// room-members-access (server and room ID) for a manager who is an admin.

@(private = "file")
roomMembersWrapped :: proc(ctx: ^ui.Context, column: ^ui.Rect, text: string, color: ui.Color) {
	if len(text) == 0 {
		return
	}
	height := ui.wrappedTextHeight(ctx, text, column.w)
	ui.wrappedLabel(ctx, ui.cutTop(column, height), text, color)
}

@(private = "file")
RoomMembersClick :: struct {
	kind:   enum u8 {
		None,
		Add,
		Remove,
		Leave,
		Edit,
		Close,
		MakeManager,
		RemoveManager,
		SetAccess,
	},
	userID: int,
}

// An encrypted room's row label: the name, (manager), and the key state.
@(private = "file")
roomMembersEncryptedLabel :: proc(row: RoomMemberRow) -> RoomMemberRow {
	labelled := row
	manager := row.isManager ? " (manager)" : ""
	if len(row.keyState) > 0 {
		labelled.label = fmt.tprintf("%s%s · %s", row.label, manager, row.keyState)
	} else {
		labelled.label = fmt.tprintf("%s%s", row.label, manager)
	}
	return labelled
}

// The Managers and Admins sections of an encrypted room's page, and its access switch.
@(private = "file")
roomMembersEncryptedSections :: proc(
	ctx: ^ui.Context,
	column: ^ui.Rect,
	view: RoomMembersView,
	serverID, roomID: int,
	click: ^RoomMembersClick,
) {
	sectionGap := ui.dp(ctx, ROOM_EDITOR_SECTION_GAP)
	labelGap := ui.dp(ctx, ROOM_EDITOR_LABEL_GAP)
	heading :: proc(ctx: ^ui.Context, column: ^ui.Rect, text: string) {
		ui.label(ctx, ui.cutTop(column, ui.lineHeight(ctx)), text, ctx.theme.fgMuted, .Bold)
	}
	_ = ui.cutTop(column, sectionGap)
	heading(ctx, column, "Managers")
	_ = ui.cutTop(column, labelGap)
	roomMembersWrapped(
		ctx,
		column,
		"Managers sign who joins and leaves; a manager who is not a member reads nothing.",
		ctx.theme.fgMuted,
	)
	_ = ui.cutTop(column, labelGap)
	for manager in view.managers {
		if roomMembersRow(
			ctx,
			column,
			roomMembersEncryptedLabel(manager),
			ui.idOf("room-members-remove-manager", serverID, roomID, manager.userID),
			manager.canRemoveManager ? "Remove manager" : "",
			true,
			!view.busy,
		) {
			click^ = {kind = .RemoveManager, userID = manager.userID}
		}
	}
	_ = ui.cutTop(column, sectionGap)
	heading(ctx, column, "Admins")
	_ = ui.cutTop(column, labelGap)
	roomMembersWrapped(
		ctx,
		column,
		"Admins run the server. Only those who are managers can add people here.",
		ctx.theme.fgMuted,
	)
	_ = ui.cutTop(column, labelGap)
	for admin in view.admins {
		if roomMembersRow(
			ctx,
			column,
			roomMembersEncryptedLabel(admin),
			ui.idOf("room-members-make-manager", serverID, roomID, admin.userID),
			admin.canMakeManager ? "Make manager" : "",
			false,
			!view.busy,
		) {
			click^ = {kind = .MakeManager, userID = admin.userID}
		}
	}
	if view.canSetAccess {
		_ = ui.cutTop(column, sectionGap)
		rect := ui.cutTop(column, ui.dp(ctx, ROW_HEIGHT))
		rect.w = min(rect.w, ui.dp(ctx, 260))
		label := view.otherAccess == .MemberInvite ? "Let members invite" : "Only admins invite"
		if ui.button(
			   ctx,
			   ui.idOf("room-members-access", serverID, roomID),
			   rect,
			   label,
			   ui.ButtonOptions{align = .Center, background = ctx.theme.hover},
		   ) &&
		   !view.busy {
			click^ = {kind = .SetAccess}
		}
	}
}

// One account's row: online dot, name, and an optional button at the right.
@(private = "file")
roomMembersRow :: proc(
	ctx: ^ui.Context,
	column: ^ui.Rect,
	row: RoomMemberRow,
	buttonID: ui.ID,
	buttonLabel: string,
	danger: bool,
	enabled: bool,
) -> bool {
	line := ui.cutTop(column, ui.dp(ctx, ROW_HEIGHT))
	gap := ui.dp(ctx, PANEL_PADDING)
	clicked := false
	if len(buttonLabel) > 0 {
		buttonW := ui.textSize(ui.textGet(ctx, 0, .Regular, buttonLabel)).x
		buttonW += ui.dp(ctx, ctx.theme.padding * 3)
		buttonRect := ui.cutRight(&line, buttonW)
		options := ui.ButtonOptions {
			align      = .Center,
			background = ctx.theme.hover,
			color      = danger ? ctx.theme.danger : ctx.theme.fg,
		}
		if !enabled {
			options.color = ctx.theme.fgMuted
		}
		clicked = ui.button(ctx, buttonID, buttonRect, buttonLabel, options) && enabled
		_ = ui.cutRight(&line, gap)
	}
	dotSize := ui.dp(ctx, 8)
	dot := ui.Rect{line.x, line.y + (line.h - dotSize) / 2, dotSize, dotSize}
	ui.fillRoundedRect(
		ctx,
		dot,
		dotSize / 2,
		row.isOnline ? ctx.theme.success : ctx.theme.border,
	)
	_ = ui.cutLeft(&line, dotSize + gap)
	ui.pushClip(ctx, line)
	ui.label(ctx, line, row.label, row.isOnline ? ctx.theme.fg : ctx.theme.fgMuted)
	ui.popClip(ctx)
	_ = ui.cutTop(column, ui.dp(ctx, ROW_SPACING))
	return clicked
}

viewRoomMembers :: proc(state: ^State, ctx: ^ui.Context, r: ui.Rect, banner: ^ConnectionBanner) {
	view := buildRoomMembersView(state)
	if !view.visible {
		return
	}
	editor := &state.roomEditor
	serverID, roomID := editor.serverID, editor.roomID
	area := r
	click: RoomMembersClick
	if viewHeader(
		ctx,
		&area,
		view.title,
		view.accessLabel,
		"Close",
		ui.idOf("room-members-close", serverID, roomID),
	) {
		click = {kind = .Close}
	}
	viewConnectionBanner(state, ctx, &area, banner)

	padding := ui.dp(ctx, 24)
	width := min(area.w - padding * 2, ui.dp(ctx, ROOM_EDITOR_COLUMN_WIDTH))
	scrollID := ui.idOf("room-members-scroll", serverID, roomID)
	offset := ui.scrollBegin(ctx, scrollID, area, editor.contentH)
	column := ui.Rect {
		area.x + (area.w - width) / 2,
		area.y + padding - offset,
		width,
		max(f32(1e6), area.h),
	}
	top := column.y
	sectionGap := ui.dp(ctx, ROOM_EDITOR_SECTION_GAP)
	labelGap := ui.dp(ctx, ROOM_EDITOR_LABEL_GAP)

	roomMembersWrapped(ctx, &column, view.accessNote, ctx.theme.fgMuted)
	_ = ui.cutTop(&column, labelGap)
	roomMembersWrapped(ctx, &column, view.historyNote, ctx.theme.fgMuted)
	if view.busy {
		_ = ui.cutTop(&column, labelGap * 2)
		roomMembersWrapped(ctx, &column, "Waiting for the server…", ctx.theme.fgMuted)
	} else if len(view.notice) > 0 {
		_ = ui.cutTop(&column, labelGap * 2)
		roomMembersWrapped(ctx, &column, view.notice, ctx.theme.success)
	}
	if len(view.error) > 0 {
		_ = ui.cutTop(&column, labelGap * 2)
		roomMembersWrapped(ctx, &column, view.error, ctx.theme.danger)
	}

	// Leave room and Edit room… sit above the lists, which can be long.
	if view.canLeave || view.canEdit {
		_ = ui.cutTop(&column, sectionGap)
		row := ui.cutTop(&column, ui.dp(ctx, ROW_HEIGHT))
		gap := ui.dp(ctx, PANEL_PADDING)
		if view.canEdit {
			rect := ui.cutLeft(&row, min(row.w, ui.dp(ctx, 140)))
			_ = ui.cutLeft(&row, gap)
			options := ui.ButtonOptions {
				align      = .Center,
				background = ctx.theme.hover,
			}
			if ui.button(
				ctx,
				ui.idOf("room-members-edit", serverID, roomID),
				rect,
				"Edit room…",
				options,
			) {
				click = {kind = .Edit}
			}
		}
		if view.canLeave {
			rect := ui.cutLeft(&row, min(row.w, ui.dp(ctx, 140)))
			options := ui.ButtonOptions {
				align = .Center,
				color = ctx.theme.danger,
			}
			if ui.button(
				   ctx,
				   ui.idOf("room-members-leave", serverID, roomID),
				   rect,
				   "Leave room",
				   options,
			   ) &&
			   !view.busy {
				click = {kind = .Leave}
			}
		}
	}

	_ = ui.cutTop(&column, sectionGap)
	if len(view.logWarning) > 0 {
		roomMembersWrapped(ctx, &column, view.logWarning, ctx.theme.danger)
		_ = ui.cutTop(&column, sectionGap)
	}
	ui.label(
		ctx,
		ui.cutTop(&column, ui.lineHeight(ctx)),
		"Members",
		ctx.theme.fgMuted,
		.Bold,
	)
	_ = ui.cutTop(&column, labelGap)
	if view.encrypted && len(view.addNote) > 0 {
		roomMembersWrapped(ctx, &column, view.addNote, ctx.theme.fgMuted)
		_ = ui.cutTop(&column, labelGap)
	}
	if view.loading {
		roomMembersWrapped(ctx, &column, "Loading the member list…", ctx.theme.fgMuted)
	} else if len(view.members) == 0 {
		roomMembersWrapped(ctx, &column, "Nobody is in this room.", ctx.theme.fgMuted)
	}
	for member in view.members {
		label := member.canRemove ? "Remove" : ""
		if roomMembersRow(
			ctx,
			&column,
			view.encrypted ? roomMembersEncryptedLabel(member) : member,
			ui.idOf("room-members-remove", serverID, roomID, member.userID),
			label,
			true,
			!view.busy,
		) {
			click = {kind = .Remove, userID = member.userID}
		}
	}

	if view.encrypted && len(view.logWarning) == 0 && !view.loading {
		roomMembersEncryptedSections(ctx, &column, view, serverID, roomID, &click)
	}

	if view.canAdd && !view.loading {
		_ = ui.cutTop(&column, sectionGap)
		ui.label(
			ctx,
			ui.cutTop(&column, ui.lineHeight(ctx)),
			"Add people",
			ctx.theme.fgMuted,
			.Bold,
		)
		_ = ui.cutTop(&column, labelGap)
		if len(view.candidates) == 0 {
			roomMembersWrapped(
				ctx,
				&column,
				"Every account on the server is already a member.",
				ctx.theme.fgMuted,
			)
		}
		for candidate in view.candidates {
			if roomMembersRow(
				ctx,
				&column,
				candidate,
				ui.idOf("room-members-add", serverID, roomID, candidate.userID),
				"Add",
				false,
				!view.busy,
			) {
				click = {kind = .Add, userID = candidate.userID}
			}
		}
	}

	_ = ui.cutTop(&column, sectionGap)
	contentH := column.y - top
	ui.scrollEnd(ctx, scrollID, area)
	if contentH != editor.contentH {
		editor.contentH = contentH
		ui.requestFrame(ctx)
	}

	// Actions run last: they can replace the lists drawn above.
	switch click.kind {
	case .None:
	case .Add:
		State_addRoomMember(state, serverID, roomID, click.userID)
	case .Remove:
		State_removeRoomMember(state, serverID, roomID, click.userID)
	case .Leave:
		State_leaveRoom(state, serverID, roomID)
	case .Edit:
		State_openRoomEditor(state, roomID)
	case .Close:
		State_closeRoomEditor(state)
	case .MakeManager:
		State_roomLogMemberChange(state, serverID, roomID, .AddManager, click.userID)
	case .RemoveManager:
		State_roomLogMemberChange(state, serverID, roomID, .RemoveManager, click.userID)
	case .SetAccess:
		access := common.RoomLogAccess.AdminInvite
		if view.otherAccess == .MemberInvite {
			access = .MemberInvite
		}
		State_roomLogMemberChange(state, serverID, roomID, .SetAccess, 0, access = access)
	}
}
