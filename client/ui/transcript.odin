package ui

import SDL "vendor:sdl3"

// A read-only, selectable list of wrapped text units that follows new content at the bottom.
// Selection works across units like a text document: drag to select, double-click for a word,
// triple-click for a whole unit, Ctrl+A to select everything, and Ctrl+C to copy.

@(private = "file")
UnitLayout :: struct {
	text:  Text,
	badge: Text,
	y, h:  f32,
}

TRANSCRIPT_DRAG_SCROLL_STEP :: 12 // Logical points per frame while drag-selecting past an edge

// What happened in the transcript this frame. A right press on a unit is reported with that
// unit's key, so the caller can open a context menu for it; a press between units or below
// the last one is not reported.
TranscriptResult :: struct {
	contextMenu:   bool,
	unitKey:       u64,
	// The transcript's selected text when the right press came, in the temp allocator, or ""
	// when nothing in this transcript is selected.
	selectionText: string,
}

transcript :: proc(
	ctx: ^Context,
	id: ID,
	r: Rect,
	units: []TranscriptUnit,
	emptyText: string = "",
) -> (
	result: TranscriptResult,
) {
	padding := dp(ctx, ctx.theme.padding)
	paddingX := padding * 2
	scrollbarSpace := dp(ctx, ctx.theme.scrollbarW + 4)
	wrapW := max(1, r.w - paddingX - scrollbarSpace)

	// Lay out every unit so the content height and scroll anchors are known before drawing.
	layouts := make([]UnitLayout, len(units), context.temp_allocator)
	items := make([]ScrollItem, len(units), context.temp_allocator)
	y := padding
	for unit, index in units {
		y += dp(ctx, unit.gapBefore)
		// A badge takes its width (and a gap) off the unit's wrap width.
		badge: Text
		unitWrapW := wrapW
		if len(unit.badge) > 0 {
			badge = textGet(ctx, 0, .Regular, unit.badge)
			unitWrapW = max(1, wrapW - textSize(badge).x - padding)
		}
		text := textGet(ctx, hashInt(u64(id), int(unit.key)), unit.font, unit.text, unitWrapW)
		height := max(textHeight(ctx, text), textHeight(ctx, badge))
		layouts[index] = UnitLayout{text, badge, y, height}
		items[index] = ScrollItem{unit.key, y, height}
		y += height
	}
	contentH := y + padding

	focused := hasFocus(ctx, id)
	inputRect := Rect{r.x, r.y, r.w - scrollbarSpace, r.h}
	it := interact(ctx, id, inputRect)
	if it.hovered {
		ctx.wantCursor = .TEXT
	}

	offset := scrollBegin(ctx, id, r, contentH, items, followBottom = true)
	origin := Vec2{r.x + paddingX, r.y - offset}

	if len(units) == 0 && len(emptyText) > 0 {
		emptyRow := Rect{r.x + paddingX, r.y + padding, r.w - paddingX * 2, lineHeight(ctx)}
		label(ctx, emptyRow, emptyText, ctx.theme.fgMuted)
	}

	if it.pressed && len(units) > 0 {
		takeFocus(ctx, id)
		focused = true
		position := transcriptHitTest(ctx, units, layouts, origin, ctx.input.mousePos)
		extend := keyHasShift(SDL.GetModState()) && ctx.selection.ownerID == id
		switch {
		case ctx.input.clickCount >= 3:
			ctx.selection = TranscriptSelection {
				ownerID = id,
				anchor  = {position.unitKey, 0},
				focus   = {position.unitKey, len(unitText(units, position.unitKey))},
			}
		case ctx.input.clickCount == 2:
			lo, hi := wordBounds(unitText(units, position.unitKey), position.offset)
			ctx.selection = TranscriptSelection {
				ownerID = id,
				anchor  = {position.unitKey, lo},
				focus   = {position.unitKey, hi},
			}
		case extend:
			ctx.selection.focus = position
		case:
			ctx.selection = TranscriptSelection {
				ownerID = id,
				anchor  = position,
				focus   = position,
			}
		}
	} else if it.held && !it.pressed && len(units) > 0 && ctx.input.clickCount < 2 {
		// Dragging past the top or bottom edge keeps selecting and scrolls the transcript.
		mouse := ctx.input.mousePos
		step := dp(ctx, TRANSCRIPT_DRAG_SCROLL_STEP)
		if mouse.y < r.y {
			scrollBy(ctx, id, -step)
		} else if mouse.y > r.y + r.h {
			scrollBy(ctx, id, step)
		}
		ctx.selection.focus = transcriptHitTest(ctx, units, layouts, origin, mouse)
		requestFrame(ctx)
	}

	if contextMenuRequested(ctx, id, inputRect) {
		localY := ctx.input.mousePos.y - origin.y
		for layout, index in layouts {
			if localY >= layout.y && localY < layout.y + layout.h {
				result.contextMenu = true
				result.unitKey = units[index].key
				break
			}
		}
		if result.contextMenu && ctx.selection.ownerID == id {
			result.selectionText = transcriptSelectionText(units, ctx.selection)
		}
	}

	if focused {
		for event in ctx.input.events {
			key, isKey := event.(KeyPress)
			if !isKey || !keyHasCtrl(key.mod) {
				continue
			}
			switch key.key {
			case SDL.K_A:
				if len(units) > 0 {
					last := units[len(units) - 1]
					ctx.selection = TranscriptSelection {
						ownerID = id,
						anchor  = {units[0].key, 0},
						focus   = {last.key, len(last.text)},
					}
				}
			case SDL.K_C:
				if ctx.selection.ownerID == id {
					if text := transcriptSelectionText(units, ctx.selection); len(text) > 0 {
						setClipboardText(text)
					}
				}
			}
		}
	}

	clip := currentClip(ctx)
	hasSelection := ctx.selection.ownerID == id
	for unit, index in units {
		layout := layouts[index]
		top := origin.y + layout.y
		if top + layout.h < clip.y || top > clip.y + clip.h {
			continue
		}
		position := Vec2{origin.x, top}
		if hasSelection {
			if lo, hi, selected := transcriptUnitSelection(units, ctx.selection, index); selected {
				fillTextRange(ctx, layout.text, position, lo, hi, ctx.theme.selection)
			}
		}
		drawText(ctx, layout.text, position, unit.color)
		if ctx.automation != nil {
			drawn := Rect{position.x, position.y, max(1, textSize(layout.text).x), layout.h}
			automationText(ctx, drawn, unit.text)
		}
		if len(unit.badge) > 0 {
			badgeSize := textSize(layout.badge)
			badgePosition := Vec2{origin.x + wrapW - badgeSize.x, top}
			drawText(ctx, layout.badge, badgePosition, unit.badgeColor)
			if ctx.automation != nil {
				drawn := Rect{badgePosition.x, top, max(1, badgeSize.x), badgeSize.y}
				automationText(ctx, drawn, unit.badge)
			}
		}
	}

	scrollEnd(ctx, id, r)
	return
}

@(private = "file")
unitText :: proc(units: []TranscriptUnit, key: u64) -> string {
	index := transcriptUnitIndex(units, key)
	return index >= 0 ? units[index].text : ""
}

// Maps a point to the nearest text position. Points above or below all units clamp to the
// start or end of the transcript, and points in the gap between units go to the next unit.
@(private = "file")
transcriptHitTest :: proc(
	ctx: ^Context,
	units: []TranscriptUnit,
	layouts: []UnitLayout,
	origin: Vec2,
	p: Vec2,
) -> TranscriptPos {
	if len(units) == 0 {
		return {}
	}
	localY := p.y - origin.y
	if localY < layouts[0].y {
		return TranscriptPos{units[0].key, 0}
	}
	for layout, index in layouts {
		if localY < layout.y {
			return TranscriptPos{units[index].key, 0}
		}
		if localY < layout.y + layout.h {
			local := Vec2{max(0, p.x - origin.x), localY - layout.y}
			return TranscriptPos{units[index].key, textOffsetAtPoint(layout.text, local)}
		}
	}
	last := units[len(units) - 1]
	return TranscriptPos{last.key, len(last.text)}
}
