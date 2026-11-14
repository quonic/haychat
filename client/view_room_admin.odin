package client

import "../common"
import "ui"

// The admin's room form, drawn in the main pane in place of the room (see room_admin.odin).
// It is laid out like the settings screen: a centred column of labelled fields and a row of
// buttons. "+ New room" in the sidebar opens it empty; "Edit room" in the room header opens it
// filled, with a Delete button that needs a second click.
//
// Widget IDs for GUI automation: room-editor-name and room-editor-description (server and room
// ID, 0 while creating), room-type N (N the protocol's type number: 1 text, 2 voice, 3 both),
// room-editor-submit, room-editor-cancel, room-editor-delete.

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

viewRoomEditor :: proc(state: ^State, ctx: ^ui.Context, r: ui.Rect, banner: ^ConnectionBanner) {
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
	column := ui.Rect{area.x + (area.w - width) / 2, area.y + padding, width, area.h - padding}
	ui.pushClip(ctx, area)
	defer ui.popClip(ctx)

	sectionGap := ui.dp(ctx, ROOM_EDITOR_SECTION_GAP)
	intro := "Every account on the server is a member of every room."
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
		row := ui.cutTop(&column, ui.dp(ctx, ROW_HEIGHT))
		gap := ui.dp(ctx, PANEL_PADDING)
		optionW := (row.w - gap * f32(len(ROOM_EDITOR_TYPES) - 1)) / f32(len(ROOM_EDITOR_TYPES))
		for roomType, index in ROOM_EDITOR_TYPES {
			rect := ui.cutLeft(&row, optionW)
			_ = ui.cutLeft(&row, gap)
			selected := view.roomType == roomType
			options := ui.ButtonOptions {
				align      = .Center,
				selected   = selected,
				color      = selected ? ctx.theme.onPrimary : ctx.theme.fg,
				background = selected ? ctx.theme.primary : ctx.theme.hover,
			}
			if selected {
				options.font = .Bold
			}
			id := ui.idOf("room-type", int(roomType))
			if ui.button(ctx, id, rect, roomTypeLabel(roomType), options) {
				typeClicked = index
			}
		}
	}
	_ = ui.cutTop(&column, ui.dp(ctx, ROOM_EDITOR_LABEL_GAP))
	roomEditorWrapped(ctx, &column, view.typeNote, ctx.theme.fgMuted)
	if len(view.typeWarning) > 0 {
		_ = ui.cutTop(&column, ui.dp(ctx, ROOM_EDITOR_LABEL_GAP))
		roomEditorWrapped(ctx, &column, view.typeWarning, ctx.theme.warning)
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

	// Actions run last: a send can change the room list drawn in the sidebar.
	switch {
	case typeClicked >= 0:
		State_setRoomEditorType(state, ROOM_EDITOR_TYPES[typeClicked])
	case cancelClicked:
		State_closeRoomEditor(state)
	case deleteClicked:
		State_deleteRoomFromEditor(state)
	case submitted:
		State_submitRoomEditor(state)
	}
}
