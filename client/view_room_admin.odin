package client

import "../common"
import "core:fmt"
import "ui"

// The admin's room form, drawn in the main pane in place of the room (see room_admin.odin).
// It is laid out like the settings screen: a centred column of labelled fields and a row of
// buttons. "+ New room" in the sidebar opens it empty; "Edit room" in the room header opens it
// filled, with a Delete button that needs a second click.
//
// Widget IDs for GUI automation: room-editor-name and room-editor-description (server and room
// ID, 0 while creating), room-type N (N the protocol's type number: 1 text, 2 voice, 3 both),
// room-access N (1 Public, 2 Member invite, 3 Admin invite), room-history N (1 From join,
// 2 Full; Create only), room-editor-join (Create), room-editor-encrypt and
// room-editor-manager (user ID) (Create, protocol 18), room-editor-members (Edit),
// room-editor-submit, room-editor-cancel, room-editor-delete. The Members page
// (view_room_members.odin) has its own.
//
// Protocol 24: room-access 4 (Roles), room-editor-access-role (role ID) for a Role room's access
// roles, and room-editor-permissions (Edit) opening the Permissions page, whose IDs are
// room-permission (role ID, 0 for Everyone; permission bit 0 send, 1 speak, 2 manage members,
// 3 edit room), room-permissions-save and room-permissions-back.

ROOM_EDITOR_COLUMN_WIDTH :: 480
ROOM_EDITOR_SECTION_GAP :: 20
ROOM_EDITOR_LABEL_GAP :: 6
ROOM_EDITOR_BUTTON_WIDTH :: 120

@(private = "file")
roomEditorLabel :: proc(ctx: ^ui.Context, column: ^ui.Rect, text: string) {
	ui.label(ctx, ui.cutTop(column, ui.lineHeight(ctx)), text, ctx.theme.fgMuted, .Bold)
	_ = ui.cutTop(column, ui.dp(ctx, ROOM_EDITOR_LABEL_GAP))
}

@(private = "file")
roomEditorWrapped :: proc(ctx: ^ui.Context, column: ^ui.Rect, text: string, color: ui.Color) {
	height := ui.wrappedTextHeight(ctx, text, column.w)
	ui.wrappedLabel(ctx, ui.cutTop(column, height), text, color)
}

// A single-line field. Returns true when Enter was pressed in it.
@(private = "file")
roomEditorField :: proc(
	ctx: ^ui.Context,
	column: ^ui.Rect,
	id: ui.ID,
	buffer: ^[dynamic]u8,
	placeholder: string,
	maxBytes: int,
) -> bool {
	r := ui.cutTop(column, ui.textInputHeight(ctx, id, buffer[:], column.w))
	result := ui.textInput(ctx, id, r, buffer, placeholder, maxBytes)
	// Names and descriptions are one line; Shift+Enter would otherwise insert a newline.
	for index := len(buffer) - 1; index >= 0; index -= 1 {
		if buffer[index] == '\n' || buffer[index] == '\r' {
			ordered_remove(buffer, index)
		}
	}
	return result.submitted
}

// A row of equal option buttons; returns the index clicked, or -1. ids names each option's
// widget ID (idOf(name, ids[i])).
@(private = "file")
roomEditorSelector :: proc(
	ctx: ^ui.Context,
	column: ^ui.Rect,
	name: string,
	labels: []string,
	ids: []int,
	selected: int,
	enabled := true,
) -> int {
	clicked := -1
	row := ui.cutTop(column, ui.dp(ctx, ROW_HEIGHT))
	gap := ui.dp(ctx, PANEL_PADDING)
	optionW := (row.w - gap * f32(len(labels) - 1)) / f32(len(labels))
	for label, index in labels {
		rect := ui.cutLeft(&row, optionW)
		_ = ui.cutLeft(&row, gap)
		isSelected := index == selected
		options := ui.ButtonOptions {
			align      = .Center,
			selected   = isSelected,
			color      = isSelected ? ctx.theme.onPrimary : ctx.theme.fg,
			background = isSelected ? ctx.theme.primary : ctx.theme.hover,
		}
		if isSelected {
			options.font = .Bold
		}
		if !enabled && !isSelected {
			options.color = ctx.theme.fgMuted
		}
		if ui.button(ctx, ui.idOf(name, ids[index]), rect, label, options) && enabled {
			clicked = index
		}
	}
	return clicked
}

viewRoomEditor :: proc(state: ^State, ctx: ^ui.Context, r: ui.Rect, banner: ^ConnectionBanner) {
	if state.roomEditor.mode == .Members {
		viewRoomMembers(state, ctx, r, banner)
		return
	}
	if state.roomEditor.mode == .Permissions {
		viewRoomPermissions(state, ctx, r, banner)
		return
	}
	view := buildRoomEditorView(state)
	if !view.visible {
		return
	}
	editor := &state.roomEditor
	area := r
	viewHeader(ctx, &area, view.title)
	viewConnectionBanner(state, ctx, &area, banner)

	padding := ui.dp(ctx, 24)
	width := min(area.w - padding * 2, ui.dp(ctx, ROOM_EDITOR_COLUMN_WIDTH))
	scrollID := ui.idOf("room-editor-scroll", editor.serverID, editor.roomID)
	offset := ui.scrollBegin(ctx, scrollID, area, editor.contentH)
	column := ui.Rect {
		area.x + (area.w - width) / 2,
		area.y + padding - offset,
		width,
		max(f32(1e6), area.h),
	}
	top := column.y

	sectionGap := ui.dp(ctx, ROOM_EDITOR_SECTION_GAP)
	intro := "Choose who can join the room and what new members can read."
	if !view.isCreate {
		intro = "Renaming or describing a room shows the change to everyone at once."
	}
	roomEditorWrapped(ctx, &column, intro, ctx.theme.fgMuted)
	_ = ui.cutTop(&column, sectionGap)

	serverID, roomID := editor.serverID, editor.roomID
	submitted := false
	roomEditorLabel(ctx, &column, "Name")
	nameID := ui.idOf("room-editor-name", serverID, roomID)
	nameMax := common.ROOM_NAME_MAX_BYTES
	if roomEditorField(ctx, &column, nameID, &editor.name, "e.g. random", nameMax) {
		submitted = true
	}
	_ = ui.cutTop(&column, ui.dp(ctx, ROOM_EDITOR_LABEL_GAP))
	roomEditorWrapped(
		ctx,
		&column,
		"1 to 64 bytes. It is shown as #name; a leading # is dropped.",
		ctx.theme.fgMuted,
	)
	_ = ui.cutTop(&column, sectionGap)

	roomEditorLabel(ctx, &column, "Description (optional)")
	descriptionID := ui.idOf("room-editor-description", serverID, roomID)
	descriptionMax := common.ROOM_DESCRIPTION_MAX_BYTES
	descriptionPlaceholder := "What the room is for"
	if roomEditorField(
		ctx,
		&column,
		descriptionID,
		&editor.description,
		descriptionPlaceholder,
		descriptionMax,
	) {
		submitted = true
	}

	_ = ui.cutTop(&column, sectionGap)
	roomEditorLabel(ctx, &column, "Type")
	typeClicked := -1
	{
		labels: [len(ROOM_EDITOR_TYPES)]string
		ids: [len(ROOM_EDITOR_TYPES)]int
		selected := -1
		for roomType, index in ROOM_EDITOR_TYPES {
			labels[index] = roomTypeLabel(roomType)
			ids[index] = int(roomType)
			if roomType == view.roomType {
				selected = index
			}
		}
		typeClicked = roomEditorSelector(ctx, &column, "room-type", labels[:], ids[:], selected)
	}
	_ = ui.cutTop(&column, ui.dp(ctx, ROOM_EDITOR_LABEL_GAP))
	roomEditorWrapped(ctx, &column, view.typeNote, ctx.theme.fgMuted)
	if len(view.typeWarning) > 0 {
		_ = ui.cutTop(&column, ui.dp(ctx, ROOM_EDITOR_LABEL_GAP))
		roomEditorWrapped(ctx, &column, view.typeWarning, ctx.theme.warning)
	}

	// Who can join (protocol 15).
	_ = ui.cutTop(&column, sectionGap)
	roomEditorLabel(ctx, &column, "Who can join")
	accessClicked := -1
	{
		labels: [len(ROOM_EDITOR_ACCESS_MODES)]string
		ids: [len(ROOM_EDITOR_ACCESS_MODES)]int
		selected := -1
		for access, index in ROOM_EDITOR_ACCESS_MODES {
			labels[index] = roomAccessLabel(access)
			ids[index] = int(access)
			if access == view.access {
				selected = index
			}
		}
		accessClicked = roomEditorSelector(
			ctx,
			&column,
			"room-access",
			labels[:],
			ids[:],
			selected,
			enabled = !view.accessLocked,
		)
	}
	_ = ui.cutTop(&column, ui.dp(ctx, ROOM_EDITOR_LABEL_GAP))
	roomEditorWrapped(ctx, &column, view.accessNote, ctx.theme.fgMuted)
	// Protocol 24: a Role room's access roles.
	accessRoleClicked := 0
	if view.showAccessRoles {
		_ = ui.cutTop(&column, ui.dp(ctx, ROOM_EDITOR_LABEL_GAP))
		for role in view.accessRoles {
			line := ui.cutTop(&column, ui.dp(ctx, ROW_HEIGHT))
			options := ui.ButtonOptions {
				selected   = role.checked,
				background = ctx.theme.hover,
				color      = view.accessLocked ? ctx.theme.fgMuted : ctx.theme.fg,
			}
			prefix := role.checked ? "[x] " : "[ ] "
			if ui.button(
				   ctx,
				   ui.idOf("room-editor-access-role", role.roleID),
				   line,
				   fmt.tprintf("%s%s", prefix, role.label),
				   options,
			   ) &&
			   !view.accessLocked {
				accessRoleClicked = role.roleID
			}
			_ = ui.cutTop(&column, ui.dp(ctx, ROW_SPACING))
		}
		if len(view.accessRolesNote) > 0 {
			roomEditorWrapped(ctx, &column, view.accessRolesNote, ctx.theme.fgMuted)
		}
	}
	if view.encryptedRoom {
		_ = ui.cutTop(&column, ui.dp(ctx, ROOM_EDITOR_LABEL_GAP))
		roomEditorWrapped(
			ctx,
			&column,
			"This room is encrypted: its managers change who can invite from its Members page.",
			ctx.theme.fgMuted,
		)
	}
	if len(view.accessWarning) > 0 {
		_ = ui.cutTop(&column, ui.dp(ctx, ROOM_EDITOR_LABEL_GAP))
		roomEditorWrapped(ctx, &column, view.accessWarning, ctx.theme.warning)
	}

	// History for new members: chosen once, here; shown in Edit.
	_ = ui.cutTop(&column, sectionGap)
	roomEditorLabel(ctx, &column, "History for new members")
	historyClicked := -1
	if view.isCreate {
		labels: [len(ROOM_EDITOR_HISTORY_OPTIONS)]string
		ids: [len(ROOM_EDITOR_HISTORY_OPTIONS)]int
		selected := -1
		for history, index in ROOM_EDITOR_HISTORY_OPTIONS {
			labels[index] = roomHistoryLabel(history)
			ids[index] = int(history)
			if history == view.history {
				selected = index
			}
		}
		historyClicked = roomEditorSelector(
			ctx,
			&column,
			"room-history",
			labels[:],
			ids[:],
			selected,
			enabled = !view.historyLocked,
		)
		_ = ui.cutTop(&column, ui.dp(ctx, ROOM_EDITOR_LABEL_GAP))
	} else {
		roomEditorWrapped(
			ctx,
			&column,
			roomHistoryLabel(view.history),
			ctx.theme.fg,
		)
	}
	roomEditorWrapped(ctx, &column, view.historyNote, ctx.theme.fgMuted)

	joinClicked := false
	membersClicked := false
	permissionsClicked := false
	encryptClicked := false
	managerClicked := 0
	if view.isCreate {
		_ = ui.cutTop(&column, sectionGap)
		row := ui.cutTop(&column, ui.dp(ctx, ROW_HEIGHT))
		joinRect := ui.cutLeft(&row, min(row.w, ui.dp(ctx, 200)))
		joinOptions := ui.ButtonOptions {
			align      = .Center,
			selected   = view.creatorJoins,
			background = ctx.theme.hover,
			color      = view.joinLocked ? ctx.theme.fgMuted : ctx.theme.fg,
		}
		if ui.button(ctx, ui.idOf("room-editor-join"), joinRect, view.joinLabel, joinOptions) &&
		   !view.joinLocked {
			joinClicked = true
		}
		_ = ui.cutTop(&column, ui.dp(ctx, ROOM_EDITOR_LABEL_GAP))
		roomEditorWrapped(ctx, &column, view.joinNote, ctx.theme.fgMuted)

		// Encrypt this room and its managers (protocol 18).
		_ = ui.cutTop(&column, sectionGap)
		encryptRow := ui.cutTop(&column, ui.dp(ctx, ROW_HEIGHT))
		encryptRect := ui.cutLeft(&encryptRow, min(encryptRow.w, ui.dp(ctx, 220)))
		encryptOptions := ui.ButtonOptions {
			align      = .Center,
			selected   = view.encrypted,
			background = ctx.theme.hover,
			color      = view.showEncrypt ? ctx.theme.fg : ctx.theme.fgMuted,
		}
		if ui.button(
			   ctx,
			   ui.idOf("room-editor-encrypt"),
			   encryptRect,
			   view.encryptLabel,
			   encryptOptions,
		   ) &&
		   view.showEncrypt {
			encryptClicked = true
		}
		_ = ui.cutTop(&column, ui.dp(ctx, ROOM_EDITOR_LABEL_GAP))
		roomEditorWrapped(ctx, &column, view.encryptNote, ctx.theme.fgMuted)
		if view.encrypted {
			_ = ui.cutTop(&column, sectionGap)
			roomEditorLabel(ctx, &column, "Managers")
			roomEditorWrapped(
				ctx,
				&column,
				"Managers can add and remove people and other managers. Every admin you see " +
				"is listed; you always are one.",
				ctx.theme.fgMuted,
			)
			_ = ui.cutTop(&column, ui.dp(ctx, ROOM_EDITOR_LABEL_GAP))
			for manager in view.managers {
				line := ui.cutTop(&column, ui.dp(ctx, ROW_HEIGHT))
				label := manager.label
				if len(manager.note) > 0 {
					label = fmt.tprintf("%s · %s", manager.label, manager.note)
				}
				options := ui.ButtonOptions {
					selected   = manager.checked,
					background = ctx.theme.hover,
					color      = ctx.theme.fgMuted,
				}
				if manager.ready && !manager.locked {
					options.color = ctx.theme.fg
				}
				prefix := manager.checked ? "[x] " : "[ ] "
				if ui.button(
					   ctx,
					   ui.idOf("room-editor-manager", manager.userID),
					   line,
					   fmt.tprintf("%s%s", prefix, label),
					   options,
				   ) &&
				   manager.ready &&
				   !manager.locked {
					managerClicked = manager.userID
				}
				_ = ui.cutTop(&column, ui.dp(ctx, ROW_SPACING))
			}
		}
	} else {
		_ = ui.cutTop(&column, sectionGap)
		row := ui.cutTop(&column, ui.dp(ctx, ROW_HEIGHT))
		membersRect := ui.cutLeft(&row, min(row.w, ui.dp(ctx, 160)))
		membersOptions := ui.ButtonOptions {
			align      = .Center,
			background = ctx.theme.hover,
		}
		membersClicked = ui.button(
			ctx,
			ui.idOf("room-editor-members"),
			membersRect,
			"Members…",
			membersOptions,
		)
		if view.showPermissions {
			_ = ui.cutLeft(&row, ui.dp(ctx, PANEL_PADDING))
			permissionsRect := ui.cutLeft(&row, min(row.w, ui.dp(ctx, 160)))
			permissionsClicked = ui.button(
				ctx,
				ui.idOf("room-editor-permissions"),
				permissionsRect,
				"Permissions…",
				membersOptions,
			)
		}
	}

	if len(view.generalNotice) > 0 {
		_ = ui.cutTop(&column, sectionGap)
		roomEditorWrapped(ctx, &column, view.generalNotice, ctx.theme.warning)
	}
	if len(view.error) > 0 {
		_ = ui.cutTop(&column, ui.dp(ctx, PANEL_PADDING * 2))
		roomEditorWrapped(ctx, &column, view.error, ctx.theme.danger)
	}
	_ = ui.cutTop(&column, sectionGap)

	buttons := ui.cutTop(&column, ui.dp(ctx, ROW_HEIGHT + 4))
	buttonW := ui.dp(ctx, ROOM_EDITOR_BUTTON_WIDTH)
	gap := ui.dp(ctx, PANEL_PADDING)
	submitOptions := ui.ButtonOptions {
		align      = .Center,
		font       = .Bold,
		color      = ctx.theme.onPrimary,
		background = ctx.theme.primary,
	}
	submitRect := ui.cutLeft(&buttons, buttonW)
	if ui.button(ctx, ui.idOf("room-editor-submit"), submitRect, view.submitLabel, submitOptions) {
		submitted = true
	}
	_ = ui.cutLeft(&buttons, gap)
	cancelOptions := ui.ButtonOptions {
		align      = .Center,
		background = ctx.theme.hover,
	}
	cancelRect := ui.cutLeft(&buttons, buttonW)
	cancelClicked := ui.button(
		ctx,
		ui.idOf("room-editor-cancel"),
		cancelRect,
		"Cancel",
		cancelOptions,
	)
	deleteClicked := false
	if view.showDelete {
		deleteOptions := ui.ButtonOptions {
			align = .Center,
			color = ctx.theme.danger,
		}
		if editor.confirmDelete {
			deleteOptions.color = ctx.theme.onPrimary
			deleteOptions.background = ctx.theme.danger
		}
		deleteRect := ui.cutRight(&buttons, ui.dp(ctx, 140))
		deleteClicked = ui.button(
			ctx,
			ui.idOf("room-editor-delete"),
			deleteRect,
			view.deleteLabel,
			deleteOptions,
		)
	}

	_ = ui.cutTop(&column, sectionGap)
	contentH := column.y - top
	ui.scrollEnd(ctx, scrollID, area)
	if contentH != editor.contentH {
		editor.contentH = contentH
		ui.requestFrame(ctx)
	}

	// Actions run last: a send can change the room list drawn in the sidebar.
	switch {
	case typeClicked >= 0:
		State_setRoomEditorType(state, ROOM_EDITOR_TYPES[typeClicked])
	case accessClicked >= 0:
		State_setRoomEditorAccess(state, ROOM_EDITOR_ACCESS_MODES[accessClicked])
	case accessRoleClicked > 0:
		State_toggleRoomEditorAccessRole(state, accessRoleClicked)
	case permissionsClicked:
		State_openRoomPermissions(state, editor.serverID, editor.roomID)
	case historyClicked >= 0:
		State_setRoomEditorHistory(state, ROOM_EDITOR_HISTORY_OPTIONS[historyClicked])
	case joinClicked:
		State_toggleRoomEditorCreatorJoins(state)
	case encryptClicked:
		State_toggleRoomEditorEncrypted(state)
	case managerClicked > 0:
		State_toggleRoomEditorManager(state, managerClicked)
	case membersClicked:
		State_openRoomMembers(state, editor.serverID, editor.roomID)
	case cancelClicked:
		State_closeRoomEditor(state)
	case deleteClicked:
		State_deleteRoomFromEditor(state)
	case submitted:
		State_submitRoomEditor(state)
	}
}

// The Permissions page (protocol 24): a row per grant (Everyone, then each role) with a toggle
// per permission, Save and Back. Toggles this account may not grant are drawn muted and do
// nothing.
viewRoomPermissions :: proc(
	state: ^State,
	ctx: ^ui.Context,
	r: ui.Rect,
	banner: ^ConnectionBanner,
) {
	view := buildRoomPermissionsView(state)
	if !view.visible {
		return
	}
	editor := &state.roomEditor
	area := r
	viewHeader(ctx, &area, view.title)
	viewConnectionBanner(state, ctx, &area, banner)

	padding := ui.dp(ctx, 24)
	width := min(area.w - padding * 2, ui.dp(ctx, ROOM_EDITOR_COLUMN_WIDTH + 160))
	scrollID := ui.idOf("room-permissions-scroll", editor.serverID, editor.roomID)
	offset := ui.scrollBegin(ctx, scrollID, area, editor.contentH)
	column := ui.Rect {
		area.x + (area.w - width) / 2,
		area.y + padding - offset,
		width,
		max(f32(1e6), area.h),
	}
	top := column.y
	sectionGap := ui.dp(ctx, ROOM_EDITOR_SECTION_GAP)
	roomEditorWrapped(ctx, &column, view.intro, ctx.theme.fgMuted)
	_ = ui.cutTop(&column, sectionGap)

	toggledRole := -1
	toggledPermission: common.RoomPermission
	if !view.loaded {
		roomEditorWrapped(ctx, &column, "Loading the room's permissions…", ctx.theme.fgMuted)
	} else {
		gap := ui.dp(ctx, PANEL_PADDING)
		labelW := min(column.w * 0.28, ui.dp(ctx, 160))
		cellW := (column.w - labelW - gap * f32(len(ROOM_PERMISSION_ORDER))) /
			f32(len(ROOM_PERMISSION_ORDER))
		header := ui.cutTop(&column, ui.lineHeight(ctx))
		_ = ui.cutLeft(&header, labelW + gap)
		for permission in ROOM_PERMISSION_ORDER {
			cell := ui.cutLeft(&header, cellW)
			_ = ui.cutLeft(&header, gap)
			ui.label(ctx, cell, roomPermissionLabel(permission), ctx.theme.fgMuted, .Bold)
		}
		_ = ui.cutTop(&column, ui.dp(ctx, ROOM_EDITOR_LABEL_GAP))
		for row in view.rows {
			line := ui.cutTop(&column, ui.dp(ctx, ROW_HEIGHT))
			labelRect := ui.cutLeft(&line, labelW)
			_ = ui.cutLeft(&line, gap)
			ui.label(ctx, labelRect, row.label, ctx.theme.fg)
			for cell, index in row.cells {
				cellRect := ui.cutLeft(&line, cellW)
				_ = ui.cutLeft(&line, gap)
				options := ui.ButtonOptions {
					align      = .Center,
					selected   = cell.checked,
					background = cell.checked ? ctx.theme.primary : ctx.theme.hover,
					color      = cell.checked ? ctx.theme.onPrimary : ctx.theme.fg,
				}
				if !cell.enabled {
					options.color = ctx.theme.fgMuted
				}
				permission := ROOM_PERMISSION_ORDER[index]
				if ui.button(
					   ctx,
					   ui.idOf("room-permission", row.roleID, int(permission)),
					   cellRect,
					   cell.checked ? "Allowed" : "—",
					   options,
				   ) &&
				   cell.enabled {
					toggledRole = row.roleID
					toggledPermission = permission
				}
			}
			_ = ui.cutTop(&column, ui.dp(ctx, ROW_SPACING))
		}
	}
	if len(view.notice) > 0 {
		_ = ui.cutTop(&column, sectionGap)
		roomEditorWrapped(ctx, &column, view.notice, ctx.theme.fgMuted)
	}
	if len(view.error) > 0 {
		_ = ui.cutTop(&column, ui.dp(ctx, PANEL_PADDING * 2))
		roomEditorWrapped(ctx, &column, view.error, ctx.theme.danger)
	}
	_ = ui.cutTop(&column, sectionGap)

	buttons := ui.cutTop(&column, ui.dp(ctx, ROW_HEIGHT + 4))
	buttonW := ui.dp(ctx, ROOM_EDITOR_BUTTON_WIDTH)
	saveOptions := ui.ButtonOptions {
		align      = .Center,
		font       = .Bold,
		color      = ctx.theme.onPrimary,
		background = ctx.theme.primary,
	}
	saveClicked := ui.button(
		ctx,
		ui.idOf("room-permissions-save"),
		ui.cutLeft(&buttons, buttonW),
		view.saveLabel,
		saveOptions,
	)
	_ = ui.cutLeft(&buttons, ui.dp(ctx, PANEL_PADDING))
	backClicked := ui.button(
		ctx,
		ui.idOf("room-permissions-back"),
		ui.cutLeft(&buttons, buttonW),
		"Back",
		{align = .Center, background = ctx.theme.hover},
	)

	_ = ui.cutTop(&column, sectionGap)
	contentH := column.y - top
	ui.scrollEnd(ctx, scrollID, area)
	if contentH != editor.contentH {
		editor.contentH = contentH
		ui.requestFrame(ctx)
	}

	switch {
	case toggledRole >= 0:
		State_toggleRoomEditorGrant(state, toggledRole, toggledPermission)
	case saveClicked:
		State_saveRoomEditorPermissions(state)
	case backClicked:
		serverID, roomID := editor.serverID, editor.roomID
		if State_knownRoom(state, serverID, roomID) != nil {
			State_openRoomEditor(state, roomID)
		} else {
			State_closeRoomEditor(state)
		}
	}
}
