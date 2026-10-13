package ui

import "core:strings"
import "core:unicode"
import "core:unicode/utf8"

// Pure editing operations on a UTF-8 byte buffer. Offsets are byte offsets that always sit on
// grapheme cluster boundaries after an edit, so a caret never splits an emoji or accent.

TextEditState :: struct {
	caret:  int,
	anchor: int, // Other end of the selection; equal to caret when nothing is selected
}

TextEdit_hasSelection :: proc(st: TextEditState) -> bool {
	return st.caret != st.anchor
}

TextEdit_selectionRange :: proc(st: TextEditState) -> (lo, hi: int) {
	return min(st.caret, st.anchor), max(st.caret, st.anchor)
}

TextEdit_selectedText :: proc(buf: []u8, st: TextEditState) -> string {
	lo, hi := TextEdit_selectionRange(st)
	return string(buf[lo:hi])
}

TextEdit_setCaret :: proc(st: ^TextEditState, offset: int, extend: bool) {
	st.caret = offset
	if !extend {
		st.anchor = offset
	}
}

TextEdit_selectAll :: proc(st: ^TextEditState, buf: []u8) {
	st.anchor = 0
	st.caret = len(buf)
}

// Keeps both ends inside the buffer and on rune boundaries. The buffer can change between
// frames (for example when a send clears it), so callers clamp before every use.
TextEdit_clamp :: proc(st: ^TextEditState, buf: []u8) {
	st.caret = runeStartAtOrBefore(buf, clamp(st.caret, 0, len(buf)))
	st.anchor = runeStartAtOrBefore(buf, clamp(st.anchor, 0, len(buf)))
}

runeStartAtOrBefore :: proc(buf: []u8, offset: int) -> int {
	offset := offset
	for offset > 0 && offset < len(buf) && !utf8.rune_start(buf[offset]) {
		offset -= 1
	}
	return offset
}

// Returns the start of the grapheme after offset, or len(str) at the end.
nextGraphemeBoundary :: proc(str: string, offset: int) -> int {
	if offset >= len(str) {
		return len(str)
	}
	it := utf8.decode_grapheme_iterator_make(str)
	for _, grapheme in utf8.decode_grapheme_iterate(&it) {
		if grapheme.byte_index > offset {
			return grapheme.byte_index
		}
	}
	return len(str)
}

// Returns the start of the grapheme before offset, or 0 at the start.
prevGraphemeBoundary :: proc(str: string, offset: int) -> int {
	if offset <= 0 {
		return 0
	}
	previous := 0
	it := utf8.decode_grapheme_iterator_make(str)
	for _, grapheme in utf8.decode_grapheme_iterate(&it) {
		if grapheme.byte_index >= offset {
			break
		}
		previous = grapheme.byte_index
	}
	return previous
}

isWordRune :: proc(r: rune) -> bool {
	return r == '_' || unicode.is_letter(r) || unicode.is_digit(r)
}

// Moves past any non-word runes, then past the following word.
nextWordBoundary :: proc(str: string, offset: int) -> int {
	offset := offset
	for offset < len(str) {
		r, size := utf8.decode_rune_in_string(str[offset:])
		if isWordRune(r) {
			break
		}
		offset += size
	}
	for offset < len(str) {
		r, size := utf8.decode_rune_in_string(str[offset:])
		if !isWordRune(r) {
			break
		}
		offset += size
	}
	return offset
}

// Moves back past any non-word runes, then back to the start of the preceding word.
prevWordBoundary :: proc(str: string, offset: int) -> int {
	offset := offset
	for offset > 0 {
		r, size := utf8.decode_last_rune_in_string(str[:offset])
		if isWordRune(r) {
			break
		}
		offset -= size
	}
	for offset > 0 {
		r, size := utf8.decode_last_rune_in_string(str[:offset])
		if !isWordRune(r) {
			break
		}
		offset -= size
	}
	return offset
}

// Returns the word, whitespace run, or single grapheme under offset, for double-click selection.
wordBounds :: proc(str: string, offset: int) -> (lo, hi: int) {
	if len(str) == 0 {
		return 0, 0
	}
	offset := runeStartAtOrBefore(transmute([]u8)str, clamp(offset, 0, len(str)))
	if offset == len(str) {
		offset = prevGraphemeBoundary(str, offset)
	}
	r, _ := utf8.decode_rune_in_string(str[offset:])
	class := runeClass(r)
	if class == .Other {
		return offset, nextGraphemeBoundary(str, offset)
	}
	lo, hi = offset, offset
	for lo > 0 {
		previous, size := utf8.decode_last_rune_in_string(str[:lo])
		if runeClass(previous) != class {
			break
		}
		lo -= size
	}
	for hi < len(str) {
		next, size := utf8.decode_rune_in_string(str[hi:])
		if runeClass(next) != class {
			break
		}
		hi += size
	}
	return
}

@(private = "file")
RuneClass :: enum {
	Word,
	Space,
	Other,
}

@(private = "file")
runeClass :: proc(r: rune) -> RuneClass {
	if isWordRune(r) {
		return .Word
	}
	if r != '\n' && unicode.is_space(r) {
		return .Space
	}
	return .Other
}

TextEdit_moveLeft :: proc(st: ^TextEditState, buf: []u8, byWord, extend: bool) {
	if TextEdit_hasSelection(st^) && !extend {
		lo, _ := TextEdit_selectionRange(st^)
		TextEdit_setCaret(st, lo, false)
		return
	}
	str := string(buf)
	target := byWord ? prevWordBoundary(str, st.caret) : prevGraphemeBoundary(str, st.caret)
	TextEdit_setCaret(st, target, extend)
}

TextEdit_moveRight :: proc(st: ^TextEditState, buf: []u8, byWord, extend: bool) {
	if TextEdit_hasSelection(st^) && !extend {
		_, hi := TextEdit_selectionRange(st^)
		TextEdit_setCaret(st, hi, false)
		return
	}
	str := string(buf)
	target := byWord ? nextWordBoundary(str, st.caret) : nextGraphemeBoundary(str, st.caret)
	TextEdit_setCaret(st, target, extend)
}

// Removes the selection, if any. Returns true when the buffer changed.
TextEdit_deleteSelection :: proc(st: ^TextEditState, buf: ^[dynamic]u8) -> bool {
	if !TextEdit_hasSelection(st^) {
		return false
	}
	lo, hi := TextEdit_selectionRange(st^)
	remove_range(buf, lo, hi)
	TextEdit_setCaret(st, lo, false)
	return true
}

TextEdit_deleteBackward :: proc(st: ^TextEditState, buf: ^[dynamic]u8, byWord: bool) -> bool {
	if TextEdit_deleteSelection(st, buf) {
		return true
	}
	if st.caret == 0 {
		return false
	}
	str := string(buf[:])
	lo := byWord ? prevWordBoundary(str, st.caret) : prevGraphemeBoundary(str, st.caret)
	remove_range(buf, lo, st.caret)
	TextEdit_setCaret(st, lo, false)
	return true
}

TextEdit_deleteForward :: proc(st: ^TextEditState, buf: ^[dynamic]u8, byWord: bool) -> bool {
	if TextEdit_deleteSelection(st, buf) {
		return true
	}
	if st.caret >= len(buf) {
		return false
	}
	str := string(buf[:])
	hi := byWord ? nextWordBoundary(str, st.caret) : nextGraphemeBoundary(str, st.caret)
	remove_range(buf, st.caret, hi)
	return true
}

// Replaces the selection with text. Text that would grow the buffer past maxBytes is cut at
// the last grapheme boundary that fits; maxBytes <= 0 means unlimited. Returns true when the
// buffer changed.
TextEdit_insert :: proc(
	st: ^TextEditState,
	buf: ^[dynamic]u8,
	text: string,
	maxBytes: int,
) -> bool {
	changed := TextEdit_deleteSelection(st, buf)
	text := text
	if maxBytes > 0 {
		room := max(0, maxBytes - len(buf))
		if len(text) > room {
			// The grapheme containing byte `room` starts at or before it, so this always fits.
			text = text[:prevGraphemeBoundary(text, room + 1)]
		}
	}
	if len(text) == 0 {
		return changed
	}
	inject_at(buf, st.caret, ..transmute([]u8)text)
	TextEdit_setCaret(st, st.caret + len(text), false)
	return true
}

// Prepares pasted or typed text for insertion: line endings become \n (or spaces when
// newlines are not allowed), tabs become four spaces, and other control characters are dropped.
sanitizeInsertText :: proc(
	text: string,
	allowNewlines: bool,
	allocator := context.temp_allocator,
) -> string {
	builder := strings.builder_make(0, len(text), allocator)
	previousWasCR := false
	for r in text {
		switch {
		case r == '\r':
			strings.write_byte(&builder, allowNewlines ? '\n' : ' ')
		case r == '\n':
			if !previousWasCR {
				strings.write_byte(&builder, allowNewlines ? '\n' : ' ')
			}
		case r == '\t':
			strings.write_string(&builder, "    ")
		case r < 0x20 || r == 0x7f:
		// Drop other control characters.
		case:
			strings.write_rune(&builder, r)
		}
		previousWasCR = r == '\r'
	}
	return strings.to_string(builder)
}
