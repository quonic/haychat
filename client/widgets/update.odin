package widgets

import hm "core:container/handle_map"
import "core:strings"
import "core:unicode/utf8"
import "vendor:raylib"

// https://github.com/ethanavatar/post_processing_shaders_scratch/blob/30a2a1b8f65d2734341f13deeafef3892cf25c83/text_entry_widget.odin

update :: proc() {
	// Mouse Position
	mousePosition := raylib.GetMousePosition()

	// Mouse Button States
	// Left Button
	mouseLeftButtonDown := raylib.IsMouseButtonDown(.LEFT)
	mouseLeftButtonPressed := raylib.IsMouseButtonPressed(.LEFT)
	mouseLeftButtonReleased := raylib.IsMouseButtonReleased(.LEFT)
	mouseLeftButtonUp := raylib.IsMouseButtonUp(.LEFT)
	// Right Button
	mouseRightButtonDown := raylib.IsMouseButtonDown(.RIGHT)
	mouseRightButtonPressed := raylib.IsMouseButtonPressed(.RIGHT)
	mouseRightButtonReleased := raylib.IsMouseButtonReleased(.RIGHT)
	mouseRightButtonUp := raylib.IsMouseButtonUp(.RIGHT)
	// Middle Button
	mouseMiddleButtonDown := raylib.IsMouseButtonDown(.MIDDLE)
	mouseMiddleButtonPressed := raylib.IsMouseButtonPressed(.MIDDLE)
	mouseMiddleButtonReleased := raylib.IsMouseButtonReleased(.MIDDLE)
	mouseMiddleButtonUp := raylib.IsMouseButtonUp(.MIDDLE)


	it := hm.iterator_make(&WidgetMap)
	for widget, handle in hm.iterate(&it) {
		// Check if mouse is over the widget
		hovering := raylib.CheckCollisionPointRec(mousePosition, widget.rectangle)
		if hovering && mouseLeftButtonPressed {
			ClickEvent(widget.handle, Event{type = .Click})
			if widget.type == .Text && widget.isInput {
				widget.isInputFocused = true
				widget.cursorBlinkTimer = 0
				widget.cursorPosition = cast(i32)len(widget.text)
			}
		} else if hovering {
			HoverEvent(widget.handle, Event{type = .Hover})
		} else {
			LeaveEvent(widget.handle, Event{type = .Leave})
		}
		if widget.isInputFocused {
			// Check for submit (Enter key)
			if raylib.IsKeyPressed(raylib.KeyboardKey.ENTER) {
				widget.submittedText = widget.text
				SubmitEvent(widget.handle, Event{type = .Submit})
			}

			key: raylib.KeyboardKey = getKeyPressedWithRepeats()
			#partial key_handler: switch key {
			case raylib.KeyboardKey.BACKSPACE:
				key_backspace(widget)
			case raylib.KeyboardKey.DELETE:
				key_delete(widget)
			case raylib.KeyboardKey.RIGHT:
				key_right(widget)
			case raylib.KeyboardKey.LEFT:
				key_left(widget)
			case raylib.KeyboardKey.ENTER:
				if widget.shouldLoseFocusOnSubmit {
					widget.isInputFocused = false
				}
			}

			char: rune = raylib.GetCharPressed()
			char_handler: switch cast(i32)char {
			case 0:
				break char_handler
			case:
				if !runeIsAscii(char) {break char_handler}
				widget.text = cstringInsertAt(
					widget.text,
					cast(int)widget.cursorPosition,
					char,
					context.allocator,
				)
				widget.cursorPosition += 1
			}
		}
	}
}

runeIsAscii :: proc(r: rune) -> bool {
	return r < 128
}

@(private)
last_key_pressed: raylib.KeyboardKey = raylib.KeyboardKey.KEY_NULL

getKeyPressedWithRepeats :: proc() -> raylib.KeyboardKey {
	key: raylib.KeyboardKey = raylib.GetKeyPressed()
	if key != raylib.KeyboardKey.KEY_NULL {
		last_key_pressed = key
		return key
	}

	if last_key_pressed == raylib.KeyboardKey.KEY_NULL {
		return raylib.KeyboardKey.KEY_NULL
	}

	if raylib.IsKeyPressedRepeat(last_key_pressed) {
		return last_key_pressed
	}

	if raylib.IsKeyUp(last_key_pressed) {
		last_key_pressed = raylib.KeyboardKey.KEY_NULL
	}

	return raylib.KeyboardKey.KEY_NULL
}

@(private)
key_backspace :: proc(widget: ^Widget) {
	if widget.cursorPosition <= 0 {return}
	widget.cursorPosition -= 1
	widget.text = cstringRemoveAt(widget.text, cast(int)widget.cursorPosition, context.allocator)
}

@(private)
key_delete :: proc(widget: ^Widget) {
	if cast(int)widget.cursorPosition >= len(widget.text) {return}
	widget.text = cstringRemoveAt(widget.text, cast(int)widget.cursorPosition, context.allocator)
}

@(private)
key_right :: proc(widget: ^Widget) {
	if cast(int)widget.cursorPosition >= len(widget.text) {return}
	widget.cursorPosition += 1
}

@(private)
key_left :: proc(widget: ^Widget) {
	if widget.cursorPosition <= 0 {return}
	widget.cursorPosition -= 1
}

cstringSplitAt :: proc(
	cstr: cstring,
	n: int,
	allocator := context.allocator,
) -> (
	cstring,
	cstring,
) {
	if n > len(cstr) {return cstr, ""}
	if n <= 0 {return "", cstr}

	len := len(cstr)
	str := strings.string_from_ptr(cast([^]u8)cstr, len)
	return strings.clone_to_cstring(
		str[0:n],
		allocator,
	), strings.clone_to_cstring(str[n:len], allocator)
}

cstringInsertAt :: proc(
	cstr: cstring,
	n: int,
	insert: rune,
	allocator := context.allocator,
) -> cstring {
	char := [1]rune{insert}
	char_string := utf8.runes_to_string(char[:], context.allocator)
	defer free(raw_data(char_string), context.allocator)

	cstr_insert := strings.unsafe_string_to_cstring(char_string)
	if n > len(cstr) {return cstringConcat(cstr, cstr_insert, allocator)}
	if n <= 0 {return cstringConcat(cstr_insert, cstr, allocator)}

	front, back := cstringSplitAt(cstr, n, context.allocator)
	front_concat := cstringConcat(front, cstr_insert, context.allocator)
	return cstringConcat(front_concat, back, allocator)
}

cstringRemoveAt :: proc(cstr: cstring, n: int, allocator := context.allocator) -> cstring {
	if n >= len(cstr) || n < 0 {return cstr}
	if n == 0 {
		_, back := cstringSplitAt(cstr, 1, context.allocator)
		return back
	}

	front, b := cstringSplitAt(cstr, n, context.allocator)
	defer free(cast(rawptr)front, context.allocator)
	defer free(cast(rawptr)b, context.allocator)

	f, back := cstringSplitAt(cstr, n + 1, context.allocator)
	defer free(cast(rawptr)f, context.allocator)
	defer free(cast(rawptr)back, context.allocator)

	return cstringConcat(front, back, allocator)
}

cstringConcat :: proc(a: cstring, b: cstring, allocator := context.allocator) -> cstring {
	s := [?]string{string(a), string(b)}
	return strings.unsafe_string_to_cstring(strings.concatenate(s[:], allocator))
}
