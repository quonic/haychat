package ui

import "core:strings"
import SDL "vendor:sdl3"

MouseButton :: enum u8 {
	Left,
	Right,
	Middle,
}

KeyPress :: struct {
	key:    SDL.Keycode,
	mod:    SDL.Keymod,
	repeat: bool,
}

// Keyboard input in arrival order, so typing and editing keys in the same frame apply in the
// order the user pressed them. Text is allocated from the temp allocator.
InputEvent :: union {
	KeyPress,
	string,
}

// Input gathered from SDL events since the previous frame. Coordinates are render pixels.
Input :: struct {
	mousePos:      Vec2,
	mouseInWindow: bool,
	mouseDown:     [MouseButton]bool,
	mousePressed:  [MouseButton]bool,
	mouseReleased: [MouseButton]bool,
	clickCount:    int, // 1 for a single click, 2 for a double click, and so on
	wheel:         Vec2, // In notches; positive y scrolls toward the start
	events:        [dynamic]InputEvent,
	hadEvents:     bool,
}

Input_reset :: proc(input: ^Input) {
	input.mousePressed = {}
	input.mouseReleased = {}
	input.wheel = {}
	clear(&input.events)
	input.hadEvents = false
}

@(private = "file")
mouseButtonFromSDL :: proc(button: u8) -> (MouseButton, bool) {
	switch button {
	case SDL.BUTTON_LEFT:
		return .Left, true
	case SDL.BUTTON_RIGHT:
		return .Right, true
	case SDL.BUTTON_MIDDLE:
		return .Middle, true
	}
	return .Left, false
}

// Records one SDL event. Returns true when the event affects the UI and a frame should be drawn.
handleEvent :: proc(ctx: ^Context, event: ^SDL.Event) -> bool {
	// Window coordinates become render pixels, matching everything the UI draws.
	_ = SDL.ConvertEventToRenderCoordinates(ctx.renderer, event)
	input := &ctx.input
	#partial switch event.type {
	case .MOUSE_MOTION:
		input.mousePos = {event.motion.x, event.motion.y}
		input.mouseInWindow = true
	case .MOUSE_BUTTON_DOWN, .MOUSE_BUTTON_UP:
		button, ok := mouseButtonFromSDL(event.button.button)
		if !ok {
			return false
		}
		input.mousePos = {event.button.x, event.button.y}
		if event.button.down {
			input.mouseDown[button] = true
			input.mousePressed[button] = true
			if button == .Left {
				input.clickCount = int(event.button.clicks)
			}
		} else {
			input.mouseDown[button] = false
			input.mouseReleased[button] = true
		}
	case .MOUSE_WHEEL:
		wheel := Vec2{event.wheel.x, event.wheel.y}
		if event.wheel.direction == .FLIPPED {
			wheel = -wheel
		}
		input.wheel += wheel
		input.mousePos = {event.wheel.mouse_x, event.wheel.mouse_y}
	case .KEY_DOWN:
		append(
			&input.events,
			KeyPress{key = event.key.key, mod = event.key.mod, repeat = event.key.repeat},
		)
	case .TEXT_INPUT:
		text := strings.clone_from_cstring(event.text.text, context.temp_allocator)
		append(&input.events, text)
	case .TEXT_EDITING:
		delete(ctx.preedit)
		ctx.preedit = strings.clone_from_cstring(event.edit.text)
	case .WINDOW_MOUSE_LEAVE:
		input.mouseInWindow = false
	case .WINDOW_FOCUS_LOST:
		// A release that happens outside the window is never reported, so drop held buttons.
		for &down, button in input.mouseDown {
			if down {
				down = false
				input.mouseReleased[button] = true
			}
		}
	case .WINDOW_PIXEL_SIZE_CHANGED, .WINDOW_EXPOSED, .WINDOW_RESIZED:
	case .WINDOW_DISPLAY_SCALE_CHANGED:
		rescale(ctx)
	case:
		return false
	}
	input.hadEvents = true
	return true
}

keyHasCtrl :: proc(mod: SDL.Keymod) -> bool {
	when ODIN_OS == .Darwin {
		return mod & SDL.KMOD_GUI != {}
	} else {
		return mod & SDL.KMOD_CTRL != {}
	}
}

keyHasShift :: proc(mod: SDL.Keymod) -> bool {
	return mod & SDL.KMOD_SHIFT != {}
}
