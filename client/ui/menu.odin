package ui

import SDL "vendor:sdl3"

// A popup menu drawn in an overlay (overlay.odin): a column of items and separators, placed
// at an anchor point and kept inside the window. The caller owns whether the menu is open: it
// draws the menu every frame while it is, and closes it when an item it acted on was clicked
// or menuEnd reports the menu dismissed (Esc, a press outside it, or the window losing focus).
// Up and Down move the highlight over the enabled items and Enter activates it.
//
//     ui.menuBegin(ctx, id, ui.menuPlace(anchor, ui.menuSize(ctx, items), ctx.windowRect))
//     if ui.menuItem(ctx, KEY, "Copy", enabled) { ... }
//     ui.menuSeparator(ctx)
//     dismissed := ui.menuEnd(ctx)
//
// or, with every entry known up front, ui.menu(ctx, id, anchor, items).
//
// A menu can also hold a labelled slider (menuSlider, or a MenuItem with slider set): the label
// above a track, for a value the caller keeps. Moving it does not close the menu, and Up and
// Down skip it.
//
// Each item's widget ID is idOf("menu-item", key), so it is stable however the entries
// around it change, and its label goes through the automation text hook.

MENU_MIN_WIDTH :: 180
MENU_ITEM_HEIGHT :: 28
MENU_SEPARATOR_HEIGHT :: 9
MENU_SLIDER_HEIGHT :: 48
MENU_PADDING :: 4 // Between the border and the items
MENU_MAX_ITEMS :: 32

MenuItem :: struct {
	key:       int, // Stable per entry; names the item's widget ID
	label:     string,
	enabled:   bool,
	danger:    bool, // Drawn in the danger color, for destructive entries
	separator: bool, // A divider line instead of an item; the other fields are ignored
	// A labelled slider (menuSlider) instead of an item: value in low..high, snapped to step.
	slider:    bool,
	value:     f32,
	low:       f32,
	high:      f32,
	step:      f32,
}

MenuResult :: struct {
	clicked:   int, // Index into the items of the one activated this frame, -1 for none
	dismissed: bool, // Esc, a press outside the menu, or the window lost focus
	// The slider item that moved or was let go this frame (index into the items, -1 for
	// none) and what it reported.
	sliderIndex: int,
	slider:      SliderResult,
}

// What the toolkit keeps for the open menu between frames.
MenuState :: struct {
	id:          ID, // The menu the highlight belongs to
	hot:         int, // Highlighted item (counting items only, not separators), -1 for none
	// This frame, between menuBegin and menuEnd.
	rect:        Rect,
	y:           f32,
	count:       int, // Items drawn so far
	enabled:     [MENU_MAX_ITEMS]bool,
	moves:       int, // Net Down presses minus Up presses
	enter:       bool,
	escape:      bool,
	activated:   bool, // An item was clicked or entered
}

// The size of a menu holding items, in render pixels.
menuSize :: proc(ctx: ^Context, items: []MenuItem) -> Vec2 {
	labelW: f32 = 0
	height := dp(ctx, MENU_PADDING) * 2
	for item in items {
		if item.separator {
			height += dp(ctx, MENU_SEPARATOR_HEIGHT)
			continue
		}
		height += dp(ctx, item.slider ? MENU_SLIDER_HEIGHT : MENU_ITEM_HEIGHT)
		labelW = max(labelW, textSize(textGet(ctx, 0, .Regular, item.label)).x)
	}
	width := labelW + dp(ctx, ctx.theme.padding * 2 + MENU_PADDING * 2 + 8)
	return Vec2{max(width, dp(ctx, MENU_MIN_WIDTH)), height}
}

// Places a menu of size with its top-left corner at anchor, flipped to the left of the anchor
// when it would cross the right edge of bounds and above it when it would cross the bottom,
// then clamped inside bounds. Pure, for tests.
menuPlace :: proc(anchor: Vec2, size: Vec2, bounds: Rect) -> Rect {
	r := Rect{anchor.x, anchor.y, size.x, size.y}
	if r.x + r.w > bounds.x + bounds.w {
		r.x = anchor.x - size.x
	}
	if r.y + r.h > bounds.y + bounds.h {
		r.y = anchor.y - size.y
	}
	r.x = clamp(r.x, bounds.x, max(bounds.x, bounds.x + bounds.w - r.w))
	r.y = clamp(r.y, bounds.y, max(bounds.y, bounds.y + bounds.h - r.h))
	return r
}

// Starts drawing the menu with id at r (see menuPlace) in an overlay, and reads this frame's
// keys. Every menuBegin must be matched by menuEnd.
menuBegin :: proc(ctx: ^Context, id: ID, r: Rect) {
	menu := &ctx.menu
	if menu.id != id {
		menu.id = id
		menu.hot = -1
	}
	menu.rect = r
	menu.y = r.y + dp(ctx, MENU_PADDING)
	menu.count = 0
	menu.moves = 0
	menu.enter = false
	menu.escape = false
	menu.activated = false
	for event in overlayEvents(ctx, id) {
		key, isKey := event.(KeyPress)
		if !isKey {
			continue
		}
		switch key.key {
		case SDL.K_DOWN:
			menu.moves += 1
		case SDL.K_UP:
			menu.moves -= 1
		case SDL.K_RETURN, SDL.K_KP_ENTER:
			menu.enter = true
		case SDL.K_ESCAPE:
			menu.escape = true
		}
	}

	beginOverlay(ctx, id, r)
	radius := dp(ctx, ctx.theme.cornerRadius)
	fillRoundedRect(ctx, r, radius, ctx.theme.border)
	fillRoundedRect(ctx, shrink(r, max(1, dp(ctx, 1))), radius, ctx.theme.elevated)
}

// Draws one item. Returns true when it was clicked, or Enter was pressed while it was
// highlighted; a disabled item never activates.
menuItem :: proc(
	ctx: ^Context,
	key: int,
	text: string,
	enabled := true,
	danger := false,
) -> bool {
	menu := &ctx.menu
	index := menu.count
	menu.count += 1
	if index < MENU_MAX_ITEMS {
		menu.enabled[index] = enabled
	}
	inset := dp(ctx, MENU_PADDING)
	r := Rect{menu.rect.x + inset, menu.y, menu.rect.w - inset * 2, dp(ctx, MENU_ITEM_HEIGHT)}
	menu.y += r.h

	it := interact(ctx, idOf("menu-item", key), r)
	if it.hovered && enabled {
		menu.hot = index
		ctx.wantCursor = .POINTER
	}
	if menu.hot == index && enabled {
		background := it.held ? ctx.theme.pressed : ctx.theme.hover
		fillRoundedRect(ctx, r, dp(ctx, ctx.theme.cornerRadius), background)
	}
	color := ctx.theme.fg
	if danger {
		color = ctx.theme.danger
	}
	if !enabled {
		color = ctx.theme.fgMuted
	}
	label(ctx, shrinkXY(r, dp(ctx, ctx.theme.padding), 0), text, color)

	activated := enabled && (it.clicked || (menu.enter && menu.hot == index))
	if activated {
		menu.activated = true
	}
	return activated
}

// Draws a labelled slider row: text above a track for value in low..high, snapped to step. Its
// widget ID is idOf("menu-slider", key). It never takes the highlight, so Up and Down skip it,
// and moving it does not count as activating the menu.
menuSlider :: proc(
	ctx: ^Context,
	key: int,
	text: string,
	value, low, high: f32,
	step: f32 = 0,
) -> SliderResult {
	menu := &ctx.menu
	index := menu.count
	menu.count += 1
	if index < MENU_MAX_ITEMS {
		menu.enabled[index] = false
	}
	inset := dp(ctx, MENU_PADDING)
	r := Rect{menu.rect.x + inset, menu.y, menu.rect.w - inset * 2, dp(ctx, MENU_SLIDER_HEIGHT)}
	menu.y += r.h
	content := shrinkXY(r, dp(ctx, ctx.theme.padding), dp(ctx, 4))
	label(ctx, cutTop(&content, lineHeight(ctx)), text, ctx.theme.fg)
	trackH := dp(ctx, SLIDER_KNOB_SIZE + 4)
	track := Rect{content.x, content.y + (content.h - trackH) / 2, content.w, trackH}
	return slider(ctx, idOf("menu-slider", key), track, value, low, high, step)
}

menuSeparator :: proc(ctx: ^Context) {
	menu := &ctx.menu
	height := dp(ctx, MENU_SEPARATOR_HEIGHT)
	inset := dp(ctx, MENU_PADDING) + dp(ctx, ctx.theme.padding)
	divider(ctx, Rect{menu.rect.x + inset, menu.y + height / 2, menu.rect.w - inset * 2, 1})
	menu.y += height
}

// Ends the menu. Returns true when it was dismissed this frame: Esc, a press outside it, or
// the window losing focus. A menu just opened is never dismissed by the press that opened it.
menuEnd :: proc(ctx: ^Context) -> (dismissed: bool) {
	menu := &ctx.menu
	endOverlay(ctx)
	if menu.moves != 0 && !menu.activated {
		enabled := menu.enabled[:min(menu.count, MENU_MAX_ITEMS)]
		menu.hot = menuMoveHot(enabled, menu.hot, menu.moves)
		requestFrame(ctx)
	}
	if menu.hot >= menu.count {
		menu.hot = -1
	}
	return menu.escape || overlayPressedOutside(ctx, menu.id) || ctx.input.focusLost
}

// Moves the highlight by moves enabled items (positive is down), wrapping at either end. From
// no highlight, Down goes to the first enabled item and Up to the last. Pure, for tests.
menuMoveHot :: proc(enabled: []bool, hot: int, moves: int) -> int {
	if len(enabled) == 0 {
		return -1
	}
	anyEnabled := false
	for value in enabled {
		anyEnabled ||= value
	}
	if !anyEnabled {
		return -1
	}
	current := hot
	step := moves > 0 ? 1 : -1
	if current < 0 || current >= len(enabled) {
		current = step > 0 ? -1 : len(enabled)
	}
	for _ in 0 ..< abs(moves) {
		next := current
		for {
			next = (next + step + len(enabled)) % len(enabled)
			if enabled[next] {
				break
			}
		}
		current = next
	}
	return current
}

// A whole menu from a list of entries, placed at anchor inside the window.
menu :: proc(ctx: ^Context, id: ID, anchor: Vec2, items: []MenuItem) -> (result: MenuResult) {
	result.clicked = -1
	result.sliderIndex = -1
	r := menuPlace(anchor, menuSize(ctx, items), ctx.windowRect)
	menuBegin(ctx, id, r)
	for item, index in items {
		if item.separator {
			menuSeparator(ctx)
		} else if item.slider {
			moved := menuSlider(
				ctx,
				item.key,
				item.label,
				item.value,
				item.low,
				item.high,
				item.step,
			)
			if moved.changed || moved.released {
				result.sliderIndex = index
				result.slider = moved
			}
		} else if menuItem(ctx, item.key, item.label, item.enabled, item.danger) {
			result.clicked = index
		}
	}
	result.dismissed = menuEnd(ctx)
	return
}
