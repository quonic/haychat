package client

import "../common"
import "core:time"
import "ui"

// Draws the open context menu (context_menu.odin) on top of the frame. viewApp defers it, so it
// runs after every screen has drawn and recorded its right-clicks. The chosen action runs after
// the menu is drawn, because it can change what the menu was built from.
viewContextMenu :: proc(state: ^State, ctx: ^ui.Context) {
	menu := &state.contextMenu
	// Every text input reports its own right-clicks; no screen has to wire them.
	if inputID, ok := ui.textInputContextMenuRequested(ctx); ok {
		State_requestContextMenu(state, TextFieldMenuTarget{inputID}, ctx.input.mousePos)
	}
	if menu.pending != nil {
		// A right press outside an open menu replaces it with the new one at once.
		State_openContextMenu(state, menu.pending, menu.pendingPosition, menu.pendingSelection)
		menu.pending = nil
		menu.pendingSelection = ""
	}
	if menu.target == nil {
		return
	}

	facts := ContextMenuFacts {
		clipboardHasText = ui.clipboardHasText(),
	}
	if target, isText := menu.target.(TextFieldMenuTarget); isText {
		facts.textField, facts.textFieldDrawn = ui.textInputFacts(ctx, target.inputID)
	}
	view := buildContextMenu(state, facts)
	if !view.visible {
		// What the menu was about is gone.
		State_closeContextMenu(state)
		return
	}
	items := make([dynamic]ui.MenuItem, 0, len(view.entries) + 4, context.temp_allocator)
	// The entry behind each item, -1 for a separator.
	itemEntries := make([dynamic]int, 0, len(view.entries) + 4, context.temp_allocator)
	for entry, entryIndex in view.entries {
		if entry.separatorBefore && len(items) > 0 {
			append(&items, ui.MenuItem{separator = true})
			append(&itemEntries, -1)
		}
		key := int(entry.action)
		if entry.roomID > 0 {
			key = CONTEXT_MENU_ROOM_KEY_BASE + entry.roomID
		}
		append(&itemEntries, entryIndex)
		append(
			&items,
			ui.MenuItem {
				key = key,
				label = entry.label,
				enabled = entry.enabled,
				danger = entry.danger,
				slider = entry.slider,
				value = entry.value,
				low = 0,
				high = SERVER_USER_VOICE_VOLUME_MAX,
				step = SERVER_SETTINGS_VOLUME_STEP,
			},
		)
	}
	result := ui.menu(ctx, ui.idOf("context-menu", menu.serial), menu.position, items[:])
	if result.sliderIndex >= 0 {
		// The volume applies while it is dragged and is saved when it is let go; the menu
		// stays open either way.
		State_setContextMenuVolume(state, result.slider.value, result.slider.released)
		ui.requestFrame(ctx)
	} else if result.clicked >= 0 {
		entry := view.entries[itemEntries[result.clicked]]
		effect := State_runContextMenuAction(state, entry.action, time.tick_now(), entry.roomID)
		if len(effect.copyText) > 0 {
			ui.setClipboardText(effect.copyText)
		}
		if effect.textCommand != .None {
			ui.textInputCommand(ctx, effect.textInputID, effect.textCommand)
		}
		if effect.focusInput != 0 {
			ui.focusTextInput(ctx, effect.focusInput)
		}
		if ref, save := effect.saveFile.?; save {
			viewSaveAttachment(state, ctx, ref)
		}
		ui.requestFrame(ctx)
	} else if result.dismissed {
		State_closeContextMenu(state)
		ui.requestFrame(ctx)
	}
}

// Records a right-click on a sidebar row (view.odin's viewSidebar), with the row's widget ID.
viewSidebarRowContextMenu :: proc(
	state: ^State,
	ctx: ^ui.Context,
	serverID: int,
	row: SidebarRow,
	rect: ui.Rect,
) {
	target: ContextMenuTarget
	id: ui.ID
	switch row.kind {
	case .Channel:
		id = ui.idOf("channel", serverID, row.id)
		target = ChannelMenuTarget{serverID, row.id}
	case .Conversation:
		id = ui.idOf("dm-conversation", serverID, row.id)
		target = ConversationMenuTarget{serverID, row.id}
	case .Member:
		id = ui.idOf("dm-member", serverID, row.id)
		target = MemberMenuTarget{serverID, row.id}
	case .VoiceParticipant:
		id = ui.idOf("voice-participant", serverID, row.roomID, row.id)
		target = VoiceParticipantMenuTarget{serverID, row.roomID, row.id}
	case .SectionHeader, .Placeholder:
		return
	}
	if ui.contextMenuRequested(ctx, id, rect) {
		State_requestContextMenu(state, target, ctx.input.mousePos)
	}
}

// Records a right-click on a server's rail button (view.odin's viewRail).
viewServerContextMenu :: proc(
	state: ^State,
	ctx: ^ui.Context,
	id: ui.ID,
	serverID: int,
	rect: ui.Rect,
) {
	if ui.contextMenuRequested(ctx, id, rect) {
		State_requestContextMenu(state, ServerMenuTarget{serverID}, ctx.input.mousePos)
	}
}

// Records a right-click on a transcript built by transcriptUnits: the unit key names the
// message and its slot (transcriptUnitDecode): the sender header, the message itself (its text
// or the changed-list notice), or one of its file cards.
viewTranscriptContextMenu :: proc(
	state: ^State,
	ctx: ^ui.Context,
	result: ui.TranscriptResult,
	serverID: int,
	kind: common.ReadMarkerKind,
	conversationID: int,
) {
	if !result.contextMenu {
		return
	}
	messageID, slot := transcriptUnitDecode(result.unitKey)
	target: ContextMenuTarget
	switch {
	case slot == TRANSCRIPT_SLOT_SENDER:
		target = SenderMenuTarget{serverID, kind, conversationID, messageID}
	case slot >= TRANSCRIPT_SLOT_FIRST_CARD && slot < TRANSCRIPT_SLOT_FILES_CHANGED:
		index := slot - TRANSCRIPT_SLOT_FIRST_CARD
		target = AttachmentMenuTarget{serverID, kind, conversationID, messageID, index}
	case:
		target = MessageMenuTarget{serverID, kind, conversationID, messageID}
	}
	State_requestContextMenu(state, target, ctx.input.mousePos, result.selectionText)
}
