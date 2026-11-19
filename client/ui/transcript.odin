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
TRANSCRIPT_CARD_MAX_WIDTH :: 460 // Logical points
TRANSCRIPT_CARD_PROGRESS_HEIGHT :: 4

// What happened in the transcript this frame. A right press on a unit is reported with that
// unit's key, so the caller can open a context menu for it; a press between units or below
// the last one is not reported.
TranscriptResult :: struct {
	contextMenu:   bool,
	unitKey:       u64,
	// The transcript's selected text when the right press came, in the temp allocator, or ""
	// when nothing in this transcript is selected.
	selectionText: string,
	// A card's button was clicked: the card unit's key and the action's index.
	cardClicked:   bool,
	cardKey:       u64,
	cardAction:    int,
}

// The height of a card: a title line, a detail line, the status line and the progress bar
// when there are any, with padding around.
@(private = "file")
transcriptCardHeight :: proc(ctx: ^Context, card: ^TranscriptCard) -> f32 {
	padding := dp(ctx, ctx.theme.padding)
	height := lineHeight(ctx, .Bold) + lineHeight(ctx)
	if len(card.status) > 0 {
		height += lineHeight(ctx)
	}
	if card.showProgress {
		height += dp(ctx, TRANSCRIPT_CARD_PROGRESS_HEIGHT) + dp(ctx, 4)
	}
	buttonH := lineHeight(ctx) + dp(ctx, 10)
	return max(height, buttonH) + padding * 2
}

// Draws a card at rect and its buttons. Returns the index of the button clicked, or -1.
@(private = "file")
transcriptDrawCard :: proc(ctx: ^Context, card: ^TranscriptCard, rect: Rect) -> int {
	radius := dp(ctx, ctx.theme.cornerRadius)
	fillRoundedRect(ctx, rect, radius, ctx.theme.border)
	fillRoundedRect(ctx, shrink(rect, max(1, dp(ctx, 1))), radius, ctx.theme.surface)
	automationWidget(ctx, card.id, rect)
	padding := dp(ctx, ctx.theme.padding)
	inner := shrink(rect, padding)
	clicked := -1
	if card.actionCount > 0 {
		buttonH := lineHeight(ctx) + dp(ctx, 10)
		for index := card.actionCount - 1; index >= 0; index -= 1 {
			action := card.actions[index]
			width := textSize(textGet(ctx, 0, .Bold, action.label)).x + padding * 3
			slot := cutRight(&inner, width)
			_ = cutRight(&inner, padding / 2)
			buttonRect := Rect{slot.x, slot.y + (slot.h - buttonH) / 2, slot.w, buttonH}
			options := ButtonOptions {
				align      = .Center,
				font       = .Bold,
				background = ctx.theme.hover,
			}
			if action.primary {
				options.background = ctx.theme.primary
				options.color = ctx.theme.onPrimary
			}
			if button(ctx, action.id, buttonRect, action.label, options) {
				clicked = index
			}
		}
	}
	if len(card.icon) > 0 {
		iconW := lineHeight(ctx) * 2
		iconRect := cutLeft(&inner, iconW)
		_ = cutLeft(&inner, padding)
		label(ctx, iconRect, card.icon, ctx.theme.fgMuted, .Regular, .Center)
	}
	pushClip(ctx, inner)
	defer popClip(ctx)
	titleColor := card.muted ? ctx.theme.fgMuted : ctx.theme.fg
	label(ctx, cutTop(&inner, lineHeight(ctx, .Bold)), card.title, titleColor, .Bold)
	label(ctx, cutTop(&inner, lineHeight(ctx)), card.detail, ctx.theme.fgMuted)
	if len(card.status) > 0 {
		label(ctx, cutTop(&inner, lineHeight(ctx)), card.status, card.statusColor)
	}
	if card.showProgress {
		_ = cutTop(&inner, dp(ctx, 4))
		bar := cutTop(&inner, dp(ctx, TRANSCRIPT_CARD_PROGRESS_HEIGHT))
		levelMeter(ctx, bar, card.progress, {color = ctx.theme.primary})
	}
	return clicked
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
		if unit.card != nil {
			height := transcriptCardHeight(ctx, unit.card)
			layouts[index] = UnitLayout{y = y, h = height}
			items[index] = ScrollItem{unit.key, y, height}
			y += height
			continue
		}
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
	offset := scrollBegin(ctx, id, r, contentH, items, followBottom = true)
	origin := Vec2{r.x + paddingX, r.y - offset}
	clip := currentClip(ctx)

	// Cards go first: their buttons take a press before the transcript's selection does.
	overCard := false
	cardW := min(wrapW, dp(ctx, TRANSCRIPT_CARD_MAX_WIDTH))
	for unit, index in units {
		if unit.card == nil {
			continue
		}
		layout := layouts[index]
		top := origin.y + layout.y
		if top + layout.h < clip.y || top > clip.y + clip.h {
			continue
		}
		cardRect := Rect{origin.x, top, cardW, layout.h}
		overCard ||= mouseOver(ctx, cardRect)
		if action := transcriptDrawCard(ctx, unit.card, cardRect); action >= 0 {
			result.cardClicked = true
			result.cardKey = unit.key
			result.cardAction = action
		}
	}

	it := interact(ctx, id, inputRect)
	if it.hovered && !overCard {
		ctx.wantCursor = .TEXT
	}

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

	hasSelection := ctx.selection.ownerID == id
	for unit, index in units {
		if unit.card != nil {
			continue
		}
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
			if units[index].card != nil {
				return TranscriptPos{units[index].key, 0}
			}
			local := Vec2{max(0, p.x - origin.x), localY - layout.y}
			return TranscriptPos{units[index].key, textOffsetAtPoint(layout.text, local)}
		}
	}
	last := units[len(units) - 1]
	return TranscriptPos{last.key, len(last.text)}
}
