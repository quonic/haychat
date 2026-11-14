package ui

import SDL "vendor:sdl3"

// An overlay is drawn on top of everything else (a context menu, for example) and is modal
// while it is open:
//
// - The rect it had in the previous frame blocks the pointer for every widget drawn outside
//   it: mouseOver returns false for them while the pointer is inside that rect, so a click on
//   an overlay item never also reaches the row under it, and the wheel never scrolls a list
//   under it. The previous frame's rect is used because the widgets under the overlay are
//   drawn before it.
// - A press outside that rect is reported to the overlay (overlayPressedOutside) so it can
//   close. A left press is consumed there: it never reaches the widget under the pointer. A
//   right press is not, so a context menu can reopen on what was right-clicked.
// - Keyboard input goes to the overlay (overlayEvents) instead of the focused widget, so
//   Enter in a menu never also submits the text field under it.
//
// An overlay that is not drawn in a frame is closed from the next frame on. Draw overlays
// last in the frame, after every widget they cover.

OverlayState :: struct {
	id:           ID, // The overlay drawn last frame, 0 when none
	block:        Rect, // Its rect, which blocks the pointer this frame
	blocking:     bool,
	nextID:       ID, // The overlay drawn this frame
	next:         Rect,
	drawing:      bool, // Between beginOverlay and endOverlay
	pressOutside: bool, // A button went down outside block this frame
	events:       [dynamic]InputEvent, // This frame's keyboard input, taken from the widgets
}

// Whether the overlay drawn last frame, at block, keeps the pointer at p from the widgets
// under it. Pure, for tests.
overlayBlocks :: proc(block: Rect, blocking: bool, drawingOverlay: bool, p: Vec2) -> bool {
	return blocking && !drawingOverlay && contains(block, p)
}

// Called by beginFrame once input for the frame is complete.
@(private)
overlayBeginFrame :: proc(ctx: ^Context) {
	overlay := &ctx.overlay
	overlay.id = overlay.nextID
	overlay.block = overlay.next
	overlay.blocking = overlay.nextID != 0
	overlay.nextID = 0
	overlay.next = {}
	overlay.drawing = false
	overlay.pressOutside = false
	clear(&overlay.events)
	if !overlay.blocking {
		return
	}
	input := &ctx.input
	pressed := input.mousePressed[.Left] || input.mousePressed[.Right] ||
		input.mousePressed[.Middle]
	if pressed && !(input.mouseInWindow && contains(overlay.block, input.mousePos)) {
		overlay.pressOutside = true
		if input.mousePressed[.Left] {
			ctx.pressConsumed = true
		}
	}
	append(&overlay.events, ..input.events[:])
	clear(&input.events)
}

// Starts drawing an overlay with this rect. Widgets drawn until endOverlay are not blocked by
// the overlay and are not clipped by whatever the caller had pushed.
beginOverlay :: proc(ctx: ^Context, id: ID, r: Rect) {
	overlay := &ctx.overlay
	overlay.drawing = true
	overlay.nextID = id
	overlay.next = r
	append(&ctx.clipStack, ctx.windowRect)
	_ = SDL.SetRenderClipRect(ctx.renderer, nil)
}

endOverlay :: proc(ctx: ^Context) {
	ctx.overlay.drawing = false
	popClip(ctx)
}

// Whether the overlay with id was open in the previous frame. A new overlay is not, so the
// press that opened it never counts as a press outside it.
overlayWasOpen :: proc(ctx: ^Context, id: ID) -> bool {
	return ctx.overlay.blocking && ctx.overlay.id == id
}

// Whether a button went down outside the overlay with id this frame (see the top of the file).
overlayPressedOutside :: proc(ctx: ^Context, id: ID) -> bool {
	return overlayWasOpen(ctx, id) && ctx.overlay.pressOutside
}

// The keyboard input the overlay with id took from the widgets this frame.
overlayEvents :: proc(ctx: ^Context, id: ID) -> []InputEvent {
	if !overlayWasOpen(ctx, id) {
		return nil
	}
	return ctx.overlay.events[:]
}

// Whether the right button went down over r this frame, inside the current clip and not under
// an overlay. Only the first widget that asks gets a given press, so nested areas do not both
// open a menu. The caller records what was right-clicked and opens its menu at
// ctx.input.mousePos. r is recorded for automation under id, like interact does.
contextMenuRequested :: proc(ctx: ^Context, id: ID, r: Rect) -> bool {
	automationWidget(ctx, id, r)
	if !ctx.input.mousePressed[.Right] || ctx.rightPressTaken || !mouseOver(ctx, r) {
		return false
	}
	ctx.rightPressTaken = true
	return true
}
