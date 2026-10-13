package ui

import SDL "vendor:sdl3"

SCROLL_WHEEL_STEP :: 48 // Logical points per wheel notch
SCROLLBAR_MIN_THUMB :: 24

Align :: enum u8 {
	Left,
	Center,
	Right,
}

// Draws a single line of text vertically centered in r and clipped to it.
label :: proc(
	ctx: ^Context,
	r: Rect,
	str: string,
	color: Color,
	font: FontID = .Regular,
	align: Align = .Left,
) {
	if len(str) == 0 || r.w <= 0 || r.h <= 0 {
		return
	}
	text := textGet(ctx, 0, font, str)
	size := textSize(text)
	height := max(size.y, lineHeight(ctx, font))
	x := r.x
	switch align {
	case .Left:
	case .Center:
		x += (r.w - size.x) / 2
	case .Right:
		x += r.w - size.x
	}
	pushClip(ctx, r)
	drawText(ctx, text, Vec2{x, r.y + (r.h - height) / 2}, color)
	popClip(ctx)
}

// Measures text wrapped to width, for laying out multi-line labels.
wrappedTextHeight :: proc(ctx: ^Context, str: string, width: f32, font: FontID = .Regular) -> f32 {
	return textHeight(ctx, textGet(ctx, 0, font, str, width))
}

// Draws text wrapped to the width of r, starting at its top.
wrappedLabel :: proc(ctx: ^Context, r: Rect, str: string, color: Color, font: FontID = .Regular) {
	if len(str) == 0 {
		return
	}
	pushClip(ctx, r)
	drawText(ctx, textGet(ctx, 0, font, str, r.w), Vec2{r.x, r.y}, color)
	popClip(ctx)
}

// A one pixel line along the top of r.
divider :: proc(ctx: ^Context, r: Rect) {
	fillRect(ctx, Rect{r.x, r.y, r.w, max(1, dp(ctx, 1))}, ctx.theme.border)
}

ButtonOptions :: struct {
	selected: bool,
	align:    Align,
	font:     FontID,
	color:    Maybe(Color), // Label color; the theme foreground by default
}

// A flat button that highlights on hover. Returns true when clicked.
button :: proc(
	ctx: ^Context,
	id: ID,
	r: Rect,
	text: string,
	options: ButtonOptions = {},
) -> bool {
	it := interact(ctx, id, r)
	background := Color{}
	if options.selected {
		background = ctx.theme.selected
	}
	if it.hovered {
		background = it.held ? ctx.theme.pressed : ctx.theme.hover
		ctx.wantCursor = .POINTER
	}
	fillRoundedRect(ctx, r, dp(ctx, ctx.theme.cornerRadius), background)
	color := options.color.? or_else ctx.theme.fg
	label(ctx, shrinkXY(r, dp(ctx, ctx.theme.padding), 0), text, color, options.font, options.align)
	return it.clicked
}

// Shows text next to anchor after the pointer has rested on it for a moment.
tooltip :: proc(ctx: ^Context, id: ID, anchor: Rect, text: string) {
	if !mouseOver(ctx, anchor) || ctx.active != 0 {
		return
	}
	ctx.hoverSeen = true
	if ctx.hoverOwner != id {
		ctx.hoverOwner = id
		ctx.hoverStartMS = ctx.nowMS
	}
	showAt := ctx.hoverStartMS + TOOLTIP_DELAY_MS
	if ctx.nowMS >= showAt {
		ctx.tooltip = TooltipRequest{text, anchor}
	} else {
		requestFrameAt(ctx, showAt)
	}
}

// Draws the frame's tooltip on top of everything else, kept inside the window.
drawTooltip :: proc(ctx: ^Context) {
	if len(ctx.tooltip.text) == 0 {
		return
	}
	text := textGet(ctx, 0, .Regular, ctx.tooltip.text)
	size := textSize(text)
	padding := dp(ctx, 6)
	anchor := ctx.tooltip.anchor
	box := Rect {
		anchor.x + anchor.w + dp(ctx, 6),
		anchor.y + (anchor.h - size.y) / 2 - padding,
		size.x + padding * 2,
		size.y + padding * 2,
	}
	box.x = clamp(box.x, 0, max(0, ctx.windowRect.w - box.w))
	box.y = clamp(box.y, 0, max(0, ctx.windowRect.h - box.h))
	_ = SDL.SetRenderClipRect(ctx.renderer, nil)
	fillRoundedRect(ctx, box, dp(ctx, ctx.theme.cornerRadius), ctx.theme.border)
	fillRoundedRect(
		ctx,
		shrink(box, max(1, dp(ctx, 1))),
		dp(ctx, ctx.theme.cornerRadius),
		ctx.theme.elevated,
	)
	drawText(ctx, text, Vec2{box.x + padding, box.y + padding}, ctx.theme.fg)
}

@(private = "file")
scrollThumbRect :: proc(ctx: ^Context, scroll: ^ScrollState, r: Rect) -> (Rect, bool) {
	maxOffset := scrollMaxOffset(scroll.contentH, scroll.viewH)
	if maxOffset <= 0 || r.h <= 0 {
		return {}, false
	}
	width := dp(ctx, ctx.theme.scrollbarW)
	thumbH := min(r.h, max(dp(ctx, SCROLLBAR_MIN_THUMB), r.h * r.h / scroll.contentH))
	thumbY := r.y + (r.h - thumbH) * scroll.offset / maxOffset
	return Rect{r.x + r.w - width - dp(ctx, 2), thumbY, width, thumbH}, true
}

// Begins a scrolling region over r whose content is contentH pixels tall. Returns the offset
// to subtract from content positions. Areas that follow the bottom pass their items (see
// scrollResolve). Every scrollBegin must be matched by scrollEnd.
scrollBegin :: proc(
	ctx: ^Context,
	id: ID,
	r: Rect,
	contentH: f32,
	items: []ScrollItem = nil,
	followBottom := false,
) -> f32 {
	scroll := scrollState(ctx, id)
	delta := scroll.pendingDelta
	scroll.pendingDelta = 0
	if ctx.input.wheel.y != 0 && mouseOver(ctx, r) {
		delta -= ctx.input.wheel.y * dp(ctx, SCROLL_WHEEL_STEP)
		// Only the innermost area under the pointer scrolls.
		ctx.input.wheel.y = 0
	}
	scrollResolve(scroll, items, contentH, r.h, delta, followBottom)

	// The thumb is handled before the content so a drag on it is not taken by a widget below.
	if thumb, hasThumb := scrollThumbRect(ctx, scroll, r); hasThumb {
		thumbID := ID(hashString(u64(id), "scrollbar"))
		grabArea := Rect{thumb.x - dp(ctx, 4), thumb.y, thumb.w + dp(ctx, 6), thumb.h}
		it := interact(ctx, thumbID, grabArea)
		if it.pressed {
			ctx.scrollDragGrab = ctx.input.mousePos.y - thumb.y
		}
		if it.held {
			track := r.h - thumb.h
			if track > 0 {
				maxOffset := scrollMaxOffset(scroll.contentH, scroll.viewH)
				target := (ctx.input.mousePos.y - ctx.scrollDragGrab - r.y) / track * maxOffset
				scroll.pendingDelta = clamp(target, 0, maxOffset) - scroll.offset
				if scroll.pendingDelta != 0 {
					requestFrame(ctx)
				}
			}
		}
	}

	pushClip(ctx, r)
	return scroll.offset
}

scrollEnd :: proc(ctx: ^Context, id: ID, r: Rect) {
	popClip(ctx)
	scroll := scrollState(ctx, id)
	if thumb, hasThumb := scrollThumbRect(ctx, scroll, r); hasThumb {
		thumbID := ID(hashString(u64(id), "scrollbar"))
		color := ctx.theme.scrollbar
		if ctx.active == thumbID {
			color = ctx.theme.fgMuted
		}
		fillRoundedRect(ctx, thumb, thumb.w / 2, color)
	}
}

// Moves a scroll area by delta pixels on the next frame.
scrollBy :: proc(ctx: ^Context, id: ID, delta: f32) {
	scroll := scrollState(ctx, id)
	scroll.pendingDelta += delta
	requestFrame(ctx)
}
