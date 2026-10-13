package ui

import "core:testing"

@(test)
testCutsSplitRectsWithoutOverflow :: proc(t: ^testing.T) {
	r := Rect{0, 0, 100, 50}
	left := cutLeft(&r, 30)
	testing.expect(t, left == Rect{0, 0, 30, 50}, "expected cutLeft to return the left strip")
	testing.expect(t, r == Rect{30, 0, 70, 50}, "expected cutLeft to shrink the source")

	bottom := cutBottom(&r, 10)
	testing.expect(t, bottom == Rect{30, 40, 70, 10}, "expected cutBottom to return the bottom")
	testing.expect(t, r == Rect{30, 0, 70, 40}, "expected cutBottom to shrink the height")

	tooMuch := cutTop(&r, 1000)
	testing.expectf(t, tooMuch.h == 40 && r.h == 0, "expected cuts to clamp, got %v", tooMuch)
	testing.expect(t, shrink(Rect{0, 0, 4, 4}, 10).w == 0, "expected shrink to stop at zero")
}

@(test)
testTextEditStepsWholeGraphemes :: proc(t: ^testing.T) {
	buf: [dynamic]u8
	defer delete(buf)
	append(&buf, "a👍🏽é")
	st := TextEditState{caret = len(buf), anchor = len(buf)}

	TextEdit_moveLeft(&st, buf[:], false, false)
	testing.expectf(t, st.caret == 1 + 8, "expected caret before é, got %d", st.caret)
	TextEdit_moveLeft(&st, buf[:], false, false)
	testing.expectf(t, st.caret == 1, "expected the skin-tone emoji as one step, got %d", st.caret)

	TextEdit_moveRight(&st, buf[:], false, true)
	testing.expect(
		t,
		TextEdit_selectedText(buf[:], st) == "👍🏽",
		"expected shift-right to select the whole emoji",
	)

	TextEdit_deleteBackward(&st, &buf, false)
	testing.expectf(t, string(buf[:]) == "aé", "expected selection delete, got %q", string(buf[:]))
	TextEdit_setCaret(&st, len(buf), false)
	TextEdit_deleteBackward(&st, &buf, false)
	testing.expectf(t, string(buf[:]) == "a", "expected é removed whole, got %q", string(buf[:]))
}

@(test)
testTextEditWordMovementAndDeletion :: proc(t: ^testing.T) {
	buf: [dynamic]u8
	defer delete(buf)
	append(&buf, "hello, big world")
	st := TextEditState{caret = len(buf), anchor = len(buf)}

	TextEdit_moveLeft(&st, buf[:], true, false)
	testing.expectf(t, st.caret == 11, "expected start of 'world', got %d", st.caret)
	TextEdit_moveLeft(&st, buf[:], true, false)
	testing.expectf(t, st.caret == 7, "expected start of 'big', got %d", st.caret)
	TextEdit_moveRight(&st, buf[:], true, false)
	testing.expectf(t, st.caret == 10, "expected end of 'big', got %d", st.caret)

	TextEdit_setCaret(&st, len(buf), false)
	TextEdit_deleteBackward(&st, &buf, true)
	testing.expectf(t, string(buf[:]) == "hello, big ", "got %q", string(buf[:]))
	TextEdit_setCaret(&st, 0, false)
	TextEdit_deleteForward(&st, &buf, true)
	testing.expectf(t, string(buf[:]) == ", big ", "got %q", string(buf[:]))
}

@(test)
testTextEditInsertReplacesSelectionAndRespectsLimit :: proc(t: ^testing.T) {
	buf: [dynamic]u8
	defer delete(buf)
	append(&buf, "hello world")
	st := TextEditState{caret = 11, anchor = 6}

	TextEdit_insert(&st, &buf, "there", 0)
	testing.expectf(t, string(buf[:]) == "hello there", "got %q", string(buf[:]))
	testing.expect(t, st.caret == 11 && st.anchor == 11, "expected caret after the insert")

	// Only one byte of room: the two-byte é must not be split.
	TextEdit_insert(&st, &buf, "é", 12)
	testing.expectf(t, string(buf[:]) == "hello there", "expected no split, got %q", buf[:])
	TextEdit_insert(&st, &buf, "!é", 12)
	testing.expectf(t, string(buf[:]) == "hello there!", "expected partial insert, got %q", buf[:])
}

@(test)
testWordBoundsSelectsWordsAndSpaces :: proc(t: ^testing.T) {
	str := "say hello  there"
	lo, hi := wordBounds(str, 6)
	testing.expectf(t, str[lo:hi] == "hello", "expected the word, got %q", str[lo:hi])
	lo, hi = wordBounds(str, 9)
	testing.expectf(t, str[lo:hi] == "  ", "expected the space run, got %q", str[lo:hi])
	lo, hi = wordBounds(str, len(str))
	testing.expectf(t, str[lo:hi] == "there", "expected the last word, got %q", str[lo:hi])
}

@(test)
testSanitizeInsertTextNormalizesControlCharacters :: proc(t: ^testing.T) {
	result := sanitizeInsertText("a\r\nb\rc\td\x01", true)
	testing.expectf(t, result == "a\nb\nc    d", "got %q", result)
	singleLine := sanitizeInsertText("a\nb", false)
	testing.expectf(t, singleLine == "a b", "got %q", singleLine)
	free_all(context.temp_allocator)
}

@(test)
testScrollFollowsBottomUntilUserScrollsUp :: proc(t: ^testing.T) {
	s: ScrollState
	items := []ScrollItem{{1, 0, 50}, {2, 50, 50}, {3, 100, 50}}
	scrollResolve(&s, items, 150, 100, 0, true)
	testing.expectf(t, s.offset == 50, "expected a new area to start at the end, got %v", s.offset)

	grown := []ScrollItem{{1, 0, 50}, {2, 50, 50}, {3, 100, 50}, {4, 150, 50}}
	scrollResolve(&s, grown, 200, 100, 0, true)
	testing.expectf(t, s.offset == 100, "expected new content to stay pinned, got %v", s.offset)

	scrollResolve(&s, grown, 200, 100, -40, true)
	testing.expect(t, !s.stick, "expected scrolling up to unpin")
	testing.expectf(t, s.offset == 60, "expected offset 60, got %v", s.offset)

	scrollResolve(&s, grown, 200, 100, 100, true)
	testing.expect(t, s.stick, "expected scrolling back to the end to pin again")
}

@(test)
testScrollKeepsAnchorWhenHistoryIsPrepended :: proc(t: ^testing.T) {
	s: ScrollState
	items := []ScrollItem{{10, 0, 50}, {11, 50, 50}, {12, 100, 50}}
	scrollResolve(&s, items, 150, 100, 0, true)
	scrollResolve(&s, items, 150, 100, -30, true)
	testing.expectf(t, s.offset == 20, "expected offset 20, got %v", s.offset)

	// An older page arrives above everything that was loaded.
	prepended := []ScrollItem{{8, 0, 50}, {9, 50, 50}, {10, 100, 50}, {11, 150, 50}, {12, 200, 50}}
	scrollResolve(&s, prepended, 250, 100, 0, true)
	testing.expectf(
		t,
		s.offset == 120,
		"expected the same message to stay in view after a prepend, got %v",
		s.offset,
	)
}

@(test)
testTranscriptSelectionTextJoinsUnitsInOrder :: proc(t: ^testing.T) {
	units := []TranscriptUnit {
		{key = 1, text = "User 42", copySep = ": "},
		{key = 2, text = "hello there", copySep = "\n"},
		{key = 3, text = "You", copySep = ": "},
		{key = 4, text = "hi", copySep = "\n"},
	}
	// Anchor after focus: the drag went upward.
	sel := TranscriptSelection {
		anchor = {unitKey = 3, offset = 3},
		focus = {unitKey = 2, offset = 6},
	}
	text := transcriptSelectionText(units, sel)
	testing.expectf(t, text == "there\nYou", "got %q", text)

	lo, hi, ok := transcriptUnitSelection(units, sel, 2)
	testing.expect(t, ok && lo == 0 && hi == 3, "expected the whole middle unit to be selected")
	_, _, ok = transcriptUnitSelection(units, sel, 0)
	testing.expect(t, !ok, "expected units outside the range to be unselected")

	missing := TranscriptSelection {
		anchor = {unitKey = 99},
		focus = {unitKey = 2},
	}
	testing.expect(
		t,
		transcriptSelectionText(units, missing) == "",
		"expected a selection whose unit disappeared to copy nothing",
	)
	free_all(context.temp_allocator)
}
