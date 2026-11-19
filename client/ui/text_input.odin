package ui

import "core:math"
import "core:strings"
import SDL "vendor:sdl3"
import ttf "vendor:sdl3/ttf"

// A multiline text input that edits a caller-owned buffer in place. Enter submits and
// Shift+Enter inserts a newline. The input grows with its content up to TEXT_INPUT_MAX_LINES
// and scrolls after that.

TEXT_INPUT_MAX_LINES :: 8

TextInputResult :: struct {
	changed:   bool,
	submitted: bool, // Enter was pressed with non-blank content
	// Enter was pressed, blank content or not (a message with only files may be sent).
	entered:   bool,
	// Escape was pressed (an inline edit cancels on it).
	escaped:   bool,
	// Up was pressed without modifiers while the buffer was empty (the composer edits the
	// newest own message on it).
	upInEmpty: bool,
}

// Context menus on text inputs. A right press on an input focuses it (keeping its selection)
// and is reported by textInputContextMenuRequested, so the caller can open a menu for it
// without every screen wiring its inputs. The menu's commands are queued with
// textInputCommand and applied by the input itself the next time it is drawn, since only it
// has the buffer.
TextMenuCommand :: enum u8 {
	None,
	Cut,
	Copy,
	Paste,
	SelectAll,
}

// What a text input's menu needs to know to enable its entries.
TextFieldFacts :: struct {
	hasSelection: bool,
	hasText:      bool,
}

TextMenuState :: struct {
	requested:    ID, // The input right-clicked this frame, 0 for none
	requestFrame: u64,
	watched:      ID, // The input whose facts are recorded each frame
	facts:        TextFieldFacts,
	factsFrame:   u64, // The frame the watched input was last drawn in
	commandID:    ID,
	command:      TextMenuCommand,
}

// The text input that was right-clicked this frame, if any. Call it after the inputs are drawn.
textInputContextMenuRequested :: proc(ctx: ^Context) -> (id: ID, ok: bool) {
	menu := &ctx.textMenu
	if menu.requested == 0 || menu.requestFrame != ctx.frame {
		return 0, false
	}
	return menu.requested, true
}

// The facts of a right-clicked input, and whether it was drawn this frame (an input that is
// no longer on screen has nothing to act on).
textInputFacts :: proc(ctx: ^Context, id: ID) -> (facts: TextFieldFacts, drawn: bool) {
	menu := &ctx.textMenu
	if menu.watched != id || menu.factsFrame != ctx.frame {
		return {}, false
	}
	return menu.facts, true
}

// Queues a menu command for the input with id; it is applied when the input is next drawn.
textInputCommand :: proc(ctx: ^Context, id: ID, command: TextMenuCommand) {
	ctx.textMenu.commandID = id
	ctx.textMenu.command = command
	requestFrame(ctx)
}

// Gives the input with id keyboard focus with the caret at the end, e.g. after text was added
// to its buffer from outside.
focusTextInput :: proc(ctx: ^Context, id: ID) {
	ctx.focus = id
	ctx.editOwner = 0
	ctx.caretBlinkStartMS = ctx.nowMS
	requestFrame(ctx)
}

clipboardHasText :: proc() -> bool {
	return SDL.HasClipboardText()
}

@(private = "file")
textInputApplyCommand :: proc(
	ctx: ^Context,
	buf: ^[dynamic]u8,
	command: TextMenuCommand,
	maxBytes: int,
) -> (
	changed: bool,
) {
	st := &ctx.edit
	switch command {
	case .None:
	case .Cut, .Copy:
		if TextEdit_hasSelection(st^) {
			setClipboardText(TextEdit_selectedText(buf[:], st^))
			if command == .Cut {
				changed = TextEdit_deleteSelection(st, buf)
			}
		}
	case .Paste:
		pasted := sanitizeInsertText(getClipboardText(), true)
		changed = TextEdit_insert(st, buf, pasted, maxBytes)
	case .SelectAll:
		TextEdit_selectAll(st, buf[:])
	}
	return
}

@(private = "file")
textInputKey :: proc(id: ID) -> u64 {
	return hashString(u64(id), "text")
}

// The text shown in the input: the buffer, plus any IME composition at the caret.
@(private = "file")
textInputDisplay :: proc(ctx: ^Context, id: ID, buf: []u8) -> (display: string, preeditAt: int) {
	preeditAt = -1
	if ctx.focus != id || len(ctx.preedit) == 0 || ctx.editOwner != id {
		return string(buf), preeditAt
	}
	caret := clamp(ctx.edit.caret, 0, len(buf))
	display = strings.concatenate(
		{string(buf[:caret]), ctx.preedit, string(buf[caret:])},
		context.temp_allocator,
	)
	return display, caret
}

@(private = "file")
textInputPadding :: proc(ctx: ^Context) -> Vec2 {
	return Vec2{dp(ctx, ctx.theme.padding + 2), dp(ctx, ctx.theme.padding)}
}

// Returns the height the input wants at width, from one line up to TEXT_INPUT_MAX_LINES.
textInputHeight :: proc(ctx: ^Context, id: ID, buf: []u8, width: f32) -> f32 {
	padding := textInputPadding(ctx)
	display, _ := textInputDisplay(ctx, id, buf)
	text := textGet(ctx, textInputKey(id), .Regular, display, max(1, width - padding.x * 2))
	line := lineHeight(ctx)
	contentH := clamp(textHeight(ctx, text), line, line * TEXT_INPUT_MAX_LINES)
	return contentH + padding.y * 2
}

textInput :: proc(
	ctx: ^Context,
	id: ID,
	r: Rect,
	buf: ^[dynamic]u8,
	placeholder: string = "",
	maxBytes: int = 0,
) -> (
	result: TextInputResult,
) {
	padding := textInputPadding(ctx)
	inner := shrinkXY(r, padding.x, padding.y)
	wrapW := max(1, inner.w)
	scroll := scrollState(ctx, id)
	key := textInputKey(id)

	focused := hasFocus(ctx, id)
	if focused && ctx.editOwner != id {
		// Focus moved here from another input: start with the caret at the end.
		ctx.editOwner = id
		ctx.edit = TextEditState{len(buf), len(buf)}
	}
	if ctx.editOwner == id {
		TextEdit_clamp(&ctx.edit, buf[:])
	}

	it := interact(ctx, id, r)
	if it.hovered {
		ctx.wantCursor = .TEXT
	}
	if it.pressed || it.held {
		text := textGet(ctx, key, .Regular, string(buf[:]), wrapW)
		local := ctx.input.mousePos - Vec2{inner.x, inner.y - scroll.offset}
		offset := textOffsetAtPoint(text, local)
		if it.pressed {
			takeFocus(ctx, id)
			focused = true
			if ctx.editOwner != id {
				ctx.editOwner = id
				ctx.edit = TextEditState{offset, offset}
			}
			switch {
			case ctx.input.clickCount >= 3:
				TextEdit_selectAll(&ctx.edit, buf[:])
			case ctx.input.clickCount == 2:
				lo, hi := wordBounds(string(buf[:]), offset)
				ctx.edit = TextEditState{caret = hi, anchor = lo}
			case:
				TextEdit_setCaret(&ctx.edit, offset, keyHasShift(SDL.GetModState()))
			}
		} else if ctx.input.clickCount < 2 {
			TextEdit_setCaret(&ctx.edit, offset, true)
			requestFrame(ctx)
		}
		ctx.caretBlinkStartMS = ctx.nowMS
	}

	if contextMenuRequested(ctx, id, r) {
		// Focus without moving the caret, so the menu acts on the current selection.
		takeFocus(ctx, id)
		focused = true
		if ctx.editOwner != id {
			ctx.editOwner = id
			ctx.edit = TextEditState{len(buf), len(buf)}
		}
		ctx.textMenu.requested = id
		ctx.textMenu.requestFrame = ctx.frame
		ctx.textMenu.watched = id
	}
	if ctx.textMenu.command != .None && ctx.textMenu.commandID == id {
		command := ctx.textMenu.command
		ctx.textMenu.command = .None
		takeFocus(ctx, id)
		focused = true
		if ctx.editOwner != id {
			ctx.editOwner = id
			ctx.edit = TextEditState{len(buf), len(buf)}
		}
		TextEdit_clamp(&ctx.edit, buf[:])
		if textInputApplyCommand(ctx, buf, command, maxBytes) {
			result.changed = true
		}
		ctx.caretBlinkStartMS = ctx.nowMS
	}

	if focused {
		ctx.textInputWanted = true
		keys := textInputHandleKeys(ctx, id, buf, wrapW, maxBytes)
		result.changed ||= keys.changed
		result.submitted = keys.submitted
		result.entered = keys.entered
		result.escaped = keys.escaped
		result.upInEmpty = keys.upInEmpty
	}
	if ctx.textMenu.watched == id {
		ctx.textMenu.facts = TextFieldFacts {
			hasSelection = ctx.editOwner == id && TextEdit_hasSelection(ctx.edit),
			hasText      = len(buf) > 0,
		}
		ctx.textMenu.factsFrame = ctx.frame
	}

	display, preeditAt := textInputDisplay(ctx, id, buf[:])
	text := textGet(ctx, key, .Regular, display, wrapW)
	contentH := textHeight(ctx, text)
	caretOffset := ctx.edit.caret
	if preeditAt >= 0 {
		caretOffset = preeditAt + len(ctx.preedit)
	}
	caret := caretRect(ctx, text, caretOffset)

	// Keep the caret inside the visible part of a scrolled input.
	scroll.contentH = contentH
	scroll.viewH = inner.h
	if focused {
		if caret.y < scroll.offset {
			scroll.offset = caret.y
		} else if caret.y + caret.h > scroll.offset + inner.h {
			scroll.offset = caret.y + caret.h - inner.h
		}
	}
	if ctx.input.wheel.y != 0 && mouseOver(ctx, r) {
		scroll.offset -= ctx.input.wheel.y * dp(ctx, SCROLL_WHEEL_STEP)
		ctx.input.wheel.y = 0
	}
	scroll.offset = clamp(scroll.offset, 0, scrollMaxOffset(contentH, inner.h))

	radius := dp(ctx, ctx.theme.cornerRadius)
	fillRoundedRect(ctx, r, radius, focused ? ctx.theme.primary : ctx.theme.border)
	fillRoundedRect(ctx, shrink(r, max(1, dp(ctx, 1))), radius, ctx.theme.surface)

	pushClip(ctx, inner)
	origin := Vec2{inner.x, inner.y - scroll.offset}
	if focused && preeditAt < 0 && TextEdit_hasSelection(ctx.edit) {
		lo, hi := TextEdit_selectionRange(ctx.edit)
		fillTextRange(ctx, text, origin, lo, hi, ctx.theme.selection)
	}
	if len(display) == 0 && len(placeholder) > 0 {
		// A driver can find an empty input by its placeholder.
		automationText(ctx, inner, placeholder)
		drawText(ctx, textGet(ctx, 0, .Regular, placeholder, wrapW), origin, ctx.theme.fgMuted)
	} else {
		drawText(ctx, text, origin, ctx.theme.fg)
	}
	if preeditAt >= 0 {
		underlineTextRange(ctx, text, origin, preeditAt, preeditAt + len(ctx.preedit))
	}
	if focused {
		elapsed := ctx.nowMS - ctx.caretBlinkStartMS
		phase := elapsed / CARET_BLINK_MS
		if phase % 2 == 0 {
			fillRect(
				ctx,
				Rect{origin.x + caret.x, origin.y + caret.y, caret.w, caret.h},
				ctx.theme.fg,
			)
		}
		requestFrameAt(ctx, ctx.caretBlinkStartMS + (phase + 1) * CARET_BLINK_MS)

		// Tell the IME where the caret is, in window coordinates.
		density := ctx.pixelDensity
		ctx.textInputArea = SDL.Rect {
			i32(math.floor((origin.x + caret.x) / density)),
			i32(math.floor((origin.y + caret.y) / density)),
			i32(math.ceil(max(caret.w, 1) / density)),
			i32(math.ceil(caret.h / density)),
		}
	}
	popClip(ctx)
	return
}

@(private = "file")
underlineTextRange :: proc(ctx: ^Context, text: Text, origin: Vec2, lo, hi: int) {
	start := caretRect(ctx, text, lo)
	end := caretRect(ctx, text, hi)
	thickness := max(1, dp(ctx, 1))
	if start.y == end.y {
		underline := Rect {
			origin.x + start.x,
			origin.y + start.y + start.h - thickness,
			end.x - start.x,
			thickness,
		}
		fillRect(ctx, underline, ctx.theme.fg)
	}
}

@(private = "file")
textInputHandleKeys :: proc(
	ctx: ^Context,
	id: ID,
	buf: ^[dynamic]u8,
	wrapW: f32,
	maxBytes: int,
) -> (
	result: TextInputResult,
) {
	st := &ctx.edit
	composing := len(ctx.preedit) > 0
	for event in ctx.input.events {
		edited := false
		switch e in event {
		case string:
			edited = TextEdit_insert(st, buf, sanitizeInsertText(e, false), maxBytes)
		case KeyPress:
			ctrl := keyHasCtrl(e.mod)
			shift := keyHasShift(e.mod)
			// While the IME composes, it owns editing and navigation keys.
			if composing {
				continue
			}
			switch e.key {
			case SDL.K_LEFT:
				TextEdit_moveLeft(st, buf[:], ctrl, shift)
			case SDL.K_RIGHT:
				TextEdit_moveRight(st, buf[:], ctrl, shift)
			case SDL.K_HOME:
				if ctrl {
					TextEdit_setCaret(st, 0, shift)
				} else {
					lineStart, _ := textInputLineBounds(ctx, id, buf[:], wrapW, st.caret)
					TextEdit_setCaret(st, lineStart, shift)
				}
			case SDL.K_END:
				if ctrl {
					TextEdit_setCaret(st, len(buf), shift)
				} else {
					_, lineEnd := textInputLineBounds(ctx, id, buf[:], wrapW, st.caret)
					TextEdit_setCaret(st, lineEnd, shift)
				}
			case SDL.K_UP, SDL.K_DOWN:
				up := e.key == SDL.K_UP
				if up && len(buf) == 0 && !shift && !ctrl {
					result.upInEmpty = true
				}
				target := textInputVerticalTarget(ctx, id, buf[:], wrapW, st.caret, up)
				TextEdit_setCaret(st, target, shift)
			case SDL.K_BACKSPACE:
				edited = TextEdit_deleteBackward(st, buf, ctrl)
			case SDL.K_DELETE:
				edited = TextEdit_deleteForward(st, buf, ctrl)
			case SDL.K_RETURN, SDL.K_KP_ENTER:
				if shift {
					edited = TextEdit_insert(st, buf, "\n", maxBytes)
				} else {
					result.entered = true
					result.submitted ||= len(strings.trim_space(string(buf[:]))) > 0
				}
			case SDL.K_A:
				if ctrl {
					TextEdit_selectAll(st, buf[:])
				}
			case SDL.K_C, SDL.K_X:
				if ctrl && TextEdit_hasSelection(st^) {
					setClipboardText(TextEdit_selectedText(buf[:], st^))
					if e.key == SDL.K_X {
						edited = TextEdit_deleteSelection(st, buf)
					}
				}
			case SDL.K_V:
				if ctrl {
					pasted := sanitizeInsertText(getClipboardText(), true)
					edited = TextEdit_insert(st, buf, pasted, maxBytes)
				}
			case SDL.K_ESCAPE:
				TextEdit_setCaret(st, st.caret, false)
				result.escaped = true
			}
		}
		if edited {
			result.changed = true
		}
		ctx.caretBlinkStartMS = ctx.nowMS
	}
	return
}

// Returns the byte range of the visual line holding offset, excluding its line break.
@(private = "file")
textInputLineBounds :: proc(
	ctx: ^Context,
	id: ID,
	buf: []u8,
	wrapW: f32,
	offset: int,
) -> (
	lo, hi: int,
) {
	text := textGet(ctx, textInputKey(id), .Regular, string(buf), wrapW)
	if text.ptr == nil {
		return 0, len(buf)
	}
	sub, line: ttf.SubString
	if !ttf.GetTextSubString(text.ptr, i32(offset), &sub) ||
	   !ttf.GetTextSubStringForLine(text.ptr, sub.line_index, &line) {
		return 0, len(buf)
	}
	lo = int(line.offset)
	hi = min(int(line.offset + line.length), len(buf))
	if hi > lo && buf[hi - 1] == '\n' {
		hi -= 1
	}
	return
}

// Returns the offset one visual line above or below offset, keeping the horizontal position.
@(private = "file")
textInputVerticalTarget :: proc(
	ctx: ^Context,
	id: ID,
	buf: []u8,
	wrapW: f32,
	offset: int,
	up: bool,
) -> int {
	text := textGet(ctx, textInputKey(id), .Regular, string(buf), wrapW)
	caret := caretRect(ctx, text, offset)
	if up {
		if caret.y <= 0 {
			return 0
		}
		return textOffsetAtPoint(text, Vec2{caret.x, caret.y - caret.h / 2})
	}
	if caret.y + caret.h >= textHeight(ctx, text) {
		return len(buf)
	}
	return textOffsetAtPoint(text, Vec2{caret.x, caret.y + caret.h * 1.5})
}
