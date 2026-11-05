package ui

import "core:strings"
import SDL "vendor:sdl3"

// Automation support for scripted UI drivers (the client's --ui-script mode). While
// ctx.automation is set, every frame records the strings its widgets draw and the rects that
// widgets hit-test, so a driver can find "the button labelled X" and click its centre, wait
// until a text appears, or capture the rendered frame. With ctx.automation nil (the normal
// app) every hook is a single nil check.

// One string drawn in the last frame. rect is the visible part of the area it was drawn in,
// in render pixels; the string lives in Automation.textBytes at [offset, offset + length).
DrawnText :: struct {
	offset: int,
	length: int,
	rect:   Rect,
}

// The visible hit-test area a widget passed to interact in the last frame, in render pixels.
WidgetRect :: struct {
	id:   ID,
	rect: Rect,
}

CaptureStatus :: enum u8 {
	None,
	Pending, // Taken at the end of the next frame, before it is presented
	Done,
	Failed,
}

Automation :: struct {
	// Per-frame records, cleared at the start of every frame. The strings are copied because
	// widgets often draw temp-allocated text that is freed before a driver looks at it.
	textBytes:     [dynamic]u8,
	texts:         [dynamic]DrawnText,
	widgets:       [dynamic]WidgetRect,
	capturePath:   string, // Owned
	captureStatus: CaptureStatus,
	captureError:  string, // Owned
}

// Turns recording on. destroy frees it.
enableAutomation :: proc(ctx: ^Context) {
	if ctx.automation == nil {
		ctx.automation = new(Automation)
	}
}

Automation_destroy :: proc(automation: ^Automation) {
	if automation == nil {
		return
	}
	delete(automation.textBytes)
	delete(automation.texts)
	delete(automation.widgets)
	delete(automation.capturePath)
	delete(automation.captureError)
	free(automation)
}

Automation_clearFrame :: proc(automation: ^Automation) {
	clear(&automation.textBytes)
	clear(&automation.texts)
	clear(&automation.widgets)
}

// Records str as drawn in r, clipped to clip. Text that is entirely clipped away (scrolled out
// of a list, for example) is not on screen and is not recorded.
Automation_recordText :: proc(automation: ^Automation, r: Rect, clip: Rect, str: string) {
	visible := intersect(r, clip)
	if len(str) == 0 || visible.w <= 0 || visible.h <= 0 {
		return
	}
	offset := len(automation.textBytes)
	append(&automation.textBytes, str)
	append(&automation.texts, DrawnText{offset, len(str), visible})
}

Automation_recordWidget :: proc(automation: ^Automation, id: ID, r: Rect, clip: Rect) {
	visible := intersect(r, clip)
	if visible.w <= 0 || visible.h <= 0 {
		return
	}
	append(&automation.widgets, WidgetRect{id, visible})
}

Automation_text :: proc(automation: ^Automation, drawn: DrawnText) -> string {
	return string(automation.textBytes[drawn.offset:drawn.offset + drawn.length])
}

// Returns how many times text was drawn in the last frame.
Automation_countText :: proc(automation: ^Automation, text: string) -> int {
	count := 0
	for drawn in automation.texts {
		if Automation_text(automation, drawn) == text {
			count += 1
		}
	}
	return count
}

rectCentre :: proc(r: Rect) -> Vec2 {
	return Vec2{r.x + r.w / 2, r.y + r.h / 2}
}

@(private = "file")
Automation_overWidget :: proc(automation: ^Automation, p: Vec2) -> bool {
	for widget in automation.widgets {
		if contains(widget.rect, p) {
			return true
		}
	}
	return false
}

// Finds where to click to hit the widget showing text: the centre of the most recently drawn
// occurrence that lies on a widget, so a sidebar row wins over a header that repeats its
// label. Falls back to the most recent occurrence when none lies on a widget.
Automation_findText :: proc(automation: ^Automation, text: string) -> (Rect, bool) {
	fallback := -1
	#reverse for drawn, index in automation.texts {
		if Automation_text(automation, drawn) != text {
			continue
		}
		if Automation_overWidget(automation, rectCentre(drawn.rect)) {
			return drawn.rect, true
		}
		if fallback < 0 {
			fallback = index
		}
	}
	if fallback < 0 {
		return {}, false
	}
	return automation.texts[fallback].rect, true
}

// Finds the most recently drawn hit-test area of the widget with id.
Automation_findWidget :: proc(automation: ^Automation, id: ID) -> (Rect, bool) {
	#reverse for widget in automation.widgets {
		if widget.id == id {
			return widget.rect, true
		}
	}
	return {}, false
}

// Asks for the next frame to be written to path as a BMP file before it is presented. The
// result is read with captureResult once that frame has been drawn.
requestCapture :: proc(ctx: ^Context, path: string) {
	automation := ctx.automation
	if automation == nil {
		return
	}
	delete(automation.capturePath)
	delete(automation.captureError)
	automation.capturePath = strings.clone(path)
	automation.captureError = ""
	automation.captureStatus = .Pending
	requestFrame(ctx)
}

// Returns the state of the last requested capture. message is borrowed and set on failure.
captureResult :: proc(ctx: ^Context) -> (status: CaptureStatus, message: string) {
	if ctx.automation == nil {
		return .None, ""
	}
	return ctx.automation.captureStatus, ctx.automation.captureError
}

// Reads back the finished frame. Called by endFrame before RenderPresent, because the back
// buffer is undefined after presenting.
@(private)
automationCapture :: proc(ctx: ^Context) {
	automation := ctx.automation
	if automation.captureStatus != .Pending {
		return
	}
	automation.captureStatus = .Failed
	surface := SDL.RenderReadPixels(ctx.renderer, nil)
	if surface == nil {
		automation.captureError = strings.clone_from_cstring(SDL.GetError())
		return
	}
	defer SDL.DestroySurface(surface)
	path := strings.clone_to_cstring(automation.capturePath, context.temp_allocator)
	if !SDL.SaveBMP(surface, path) {
		automation.captureError = strings.clone_from_cstring(SDL.GetError())
		return
	}
	automation.captureStatus = .Done
}

// Hooks for the widgets. Each costs one nil check while automation is off.

@(private)
automationText :: #force_inline proc(ctx: ^Context, r: Rect, str: string) {
	if ctx.automation != nil {
		Automation_recordText(ctx.automation, r, currentClip(ctx), str)
	}
}

@(private)
automationWidget :: #force_inline proc(ctx: ^Context, id: ID, r: Rect) {
	if ctx.automation != nil {
		Automation_recordWidget(ctx.automation, id, r, currentClip(ctx))
	}
}
