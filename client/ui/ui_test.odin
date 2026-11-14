package ui

import "core:testing"
import SDL "vendor:sdl3"

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

@(test)
testAutomationFindsDrawnTextOnWidgetsFirst :: proc(t: ^testing.T) {
	automation := new(Automation)
	defer Automation_destroy(automation)
	window := Rect{0, 0, 800, 600}

	// A sidebar row (a button) and a header that repeats its label, drawn after it.
	rowID := idOf("channel", 1, 1)
	row := Rect{70, 60, 200, 30}
	Automation_recordWidget(automation, rowID, row, window)
	Automation_recordText(automation, shrinkXY(row, 8, 0), window, "# general")
	Automation_recordText(automation, Rect{320, 10, 300, 30}, window, "# general")
	Automation_recordText(automation, Rect{320, 50, 300, 30}, window, "hello")

	found, ok := Automation_findText(automation, "# general")
	assert(ok, "expected '# general' to be found")
	assert(contains(row, rectCentre(found)), "expected the sidebar row, not the later header")
	found, ok = Automation_findText(automation, "hello")
	assert(ok && found == Rect{320, 50, 300, 30}, "expected text off widgets as a fallback")
	_, ok = Automation_findText(automation, "missing")
	assert(!ok, "expected an undrawn text not to be found")
	assert(Automation_countText(automation, "# general") == 2, "expected two '# general'")

	widget, widgetOK := Automation_findWidget(automation, idOf("channel", 1, 1))
	assert(widgetOK && widget == row, "expected the widget rect by its idOf name")
	_, widgetOK = Automation_findWidget(automation, idOf("channel", 1, 2))
	assert(!widgetOK, "expected another ID not to match")

	Automation_clearFrame(automation)
	assert(Automation_countText(automation, "hello") == 0, "expected a new frame to start empty")
}

@(test)
testAutomationSkipsClippedTextAndKeepsVisiblePart :: proc(t: ^testing.T) {
	automation := new(Automation)
	defer Automation_destroy(automation)
	list := Rect{0, 100, 200, 100}

	// A row scrolled out of the list is not on screen.
	Automation_recordText(automation, Rect{0, 20, 200, 30}, list, "hidden")
	// A row half out of the list keeps only its visible part.
	Automation_recordText(automation, Rect{0, 180, 200, 40}, list, "edge")
	Automation_recordWidget(automation, 7, Rect{0, 0, 10, 10}, list)

	assert(Automation_countText(automation, "hidden") == 0, "expected clipped text dropped")
	edge, ok := Automation_findText(automation, "edge")
	assert(ok && edge == Rect{0, 180, 200, 20}, "expected the visible part of the row")
	assert(len(automation.widgets) == 0, "expected a clipped widget dropped")
	assert(len(automation.textBytes) == len("edge"), "expected only recorded text copied")
}

@(test)
testRangeFractionClampsAndHandlesEmptyRanges :: proc(t: ^testing.T) {
	testing.expect(t, rangeFraction(-45, -80, 0) == 35.0 / 80.0, "expected -45 in -80..0 at 35/80")
	testing.expect(t, rangeFraction(-100, -80, 0) == 0, "expected values below the range at 0")
	testing.expect(t, rangeFraction(10, -80, 0) == 1, "expected values above the range at 1")
	testing.expect(t, rangeFraction(5, 3, 3) == 0, "expected an empty range to give 0")
}

@(test)
testSliderValueAtMapsSnapsAndClamps :: proc(t: ^testing.T) {
	track := Rect{100, 0, 200, 10}
	value := sliderValueAt(track, 200, 0, 2, 0)
	testing.expectf(t, value == 1, "expected the middle of 0..2 to be 1, got %v", value)
	value = sliderValueAt(track, 151, -80, 0, 1)
	testing.expectf(t, value == -60, "expected a quarter of -80..0 snapped to -60, got %v", value)
	value = sliderValueAt(track, 0, 12000, 64000, 1000)
	testing.expectf(t, value == 12000, "expected left of the track to clamp to low, got %v", value)
	value = sliderValueAt(track, 1000, 12000, 64000, 1000)
	testing.expectf(t, value == 64000, "expected right of the track to clamp, got %v", value)
	value = sliderValueAt(Rect{0, 0, 0, 10}, 5, 1, 2, 0)
	testing.expectf(t, value == 1, "expected an empty track to give low, got %v", value)
}

@(test)
testMenuPlaceKeepsTheMenuInsideTheWindow :: proc(t: ^testing.T) {
	window := Rect{0, 0, 800, 600}
	size := Vec2{200, 120}

	placed := menuPlace(Vec2{100, 50}, size, window)
	assert(placed == Rect{100, 50, 200, 120}, "expected the top-left corner at the anchor")

	placed = menuPlace(Vec2{700, 50}, size, window)
	testing.expectf(t, placed.x == 500, "expected a flip to the left of the anchor, got %v", placed)

	placed = menuPlace(Vec2{100, 550}, size, window)
	testing.expectf(t, placed.y == 430, "expected a flip above the anchor, got %v", placed)

	placed = menuPlace(Vec2{790, 590}, size, window)
	testing.expectf(t, placed == Rect{590, 470, 200, 120}, "expected both flips, got %v", placed)

	// Flipping would cross the other edge: the menu is clamped inside instead.
	placed = menuPlace(Vec2{150, 550}, Vec2{200, 580}, window)
	testing.expectf(t, placed.y == 0 && placed.x == 150, "expected clamped at the top: %v", placed)

	// Larger than the window: pinned to its top-left corner.
	placed = menuPlace(Vec2{400, 300}, Vec2{900, 700}, window)
	testing.expectf(t, placed.x == 0 && placed.y == 0, "expected pinned at the corner: %v", placed)

	offset := Rect{64, 0, 400, 300}
	placed = menuPlace(Vec2{70, 10}, Vec2{500, 50}, offset)
	testing.expectf(t, placed.x == 64, "expected clamped to the bounds' left edge, got %v", placed)
}

@(test)
testOverlayBlocksOnlyWidgetsUnderIt :: proc(t: ^testing.T) {
	block := Rect{100, 100, 200, 150}
	assert(overlayBlocks(block, true, false, Vec2{150, 150}), "expected the pointer on it blocked")
	assert(!overlayBlocks(block, true, false, Vec2{50, 150}), "expected outside it not blocked")
	assert(!overlayBlocks(block, true, true, Vec2{150, 150}), "expected its own widgets free")
	assert(!overlayBlocks(block, false, false, Vec2{150, 150}), "expected no block without one")
}

// The frame start with an overlay open: the pointer over it is kept from the widgets under it,
// a left press outside it is consumed and reported, and the keyboard goes to the overlay.
@(test)
testOverlayFrameStartTakesInputFromTheWidgetsUnderIt :: proc(t: ^testing.T) {
	ctx: Context
	defer delete(ctx.input.events)
	defer delete(ctx.overlay.events)
	overlayID := idOf("menu", 1)
	ctx.overlay.nextID = overlayID
	ctx.overlay.next = Rect{100, 100, 200, 150}
	ctx.input.mouseInWindow = true
	ctx.input.mousePos = Vec2{150, 150}
	ctx.input.wheel = Vec2{0, 1}
	append(&ctx.input.events, KeyPress{key = SDL.K_RETURN})
	overlayBeginFrame(&ctx)

	assert(overlayWasOpen(&ctx, overlayID), "expected last frame's overlay open")
	assert(!overlayWasOpen(&ctx, idOf("menu", 2)), "expected a new overlay not counted as open")
	assert(!mouseOver(&ctx, Rect{0, 0, 800, 600}), "expected the row under the menu blocked")
	assert(!contextMenuRequested(&ctx, idOf("row"), Rect{0, 0, 800, 600}), "expected no menu")
	assert(len(ctx.input.events) == 0, "expected the keyboard taken from the widgets")
	assert(len(overlayEvents(&ctx, overlayID)) == 1, "expected the overlay to get the key")
	assert(!ctx.pressConsumed && !overlayPressedOutside(&ctx, overlayID), "expected no press")

	// The overlay closed (nothing drew it this frame): the next frame blocks nothing.
	ctx.input.mousePressed[.Left] = true
	overlayBeginFrame(&ctx)
	assert(mouseOver(&ctx, Rect{0, 0, 800, 600}), "expected nothing blocked once it closed")
	assert(!ctx.pressConsumed, "expected a press with no overlay left to the widgets")

	// Open again, then a left press outside it.
	ctx.overlay.nextID = overlayID
	ctx.overlay.next = Rect{100, 100, 200, 150}
	ctx.input.mousePos = Vec2{20, 20}
	overlayBeginFrame(&ctx)
	assert(ctx.pressConsumed, "expected the press outside consumed")
	assert(overlayPressedOutside(&ctx, overlayID), "expected the press outside reported")

	// A right press outside is reported but left to the widget under it, so a menu can reopen
	// there; only the first widget asking gets it.
	ctx.pressConsumed = false
	ctx.rightPressTaken = false
	ctx.input.mousePressed = {}
	ctx.input.mousePressed[.Right] = true
	ctx.overlay.nextID = overlayID
	ctx.overlay.next = Rect{100, 100, 200, 150}
	overlayBeginFrame(&ctx)
	assert(!ctx.pressConsumed && overlayPressedOutside(&ctx, overlayID), "expected reported")
	assert(contextMenuRequested(&ctx, idOf("row"), Rect{0, 0, 50, 50}), "expected the row's menu")
	assert(!contextMenuRequested(&ctx, idOf("list"), Rect{0, 0, 800, 600}), "expected one taker")
}

@(test)
testMenuHighlightSkipsDisabledItemsAndWraps :: proc(t: ^testing.T) {
	enabled := []bool{true, false, true, true}
	testing.expect(t, menuMoveHot(enabled, -1, 1) == 0, "expected Down to start at the first")
	testing.expect(t, menuMoveHot(enabled, -1, -1) == 3, "expected Up to start at the last")
	testing.expect(t, menuMoveHot(enabled, 0, 1) == 2, "expected the disabled item skipped")
	testing.expect(t, menuMoveHot(enabled, 3, 1) == 0, "expected Down to wrap to the top")
	testing.expect(t, menuMoveHot(enabled, 0, -1) == 3, "expected Up to wrap to the bottom")
	testing.expect(t, menuMoveHot(enabled, 0, 2) == 3, "expected two moves in one frame")
	testing.expect(t, menuMoveHot([]bool{false, false}, -1, 1) == -1, "expected none to land on")
	testing.expect(t, menuMoveHot(nil, -1, 1) == -1, "expected an empty menu to stay empty")
}
