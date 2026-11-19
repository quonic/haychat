package ui

import "core:strings"

// Selection model for the transcript widget, kept free of SDL so it can be unit tested.
// Positions name a unit by key rather than index, so a selection survives older history being
// inserted above it.

TranscriptUnit :: struct {
	key:       u64, // Stable across frames, for example derived from a message ID
	text:      string,
	font:      FontID,
	color:     Color,
	gapBefore: f32, // Logical points of space above this unit
	copySep:   string, // Appended after this unit when a copied selection continues past it
	// A short label drawn at the right of the unit's first line (for example an encryption
	// badge). It is not part of the unit's text: never selected or copied. Empty for none.
	badge:      string,
	badgeColor: Color,
	// A card drawn instead of text (a message's file): name, details, a status line, an
	// optional progress bar and up to two buttons. A card unit's text is empty, so it is never
	// selected or copied. nil for a text unit.
	card:       ^TranscriptCard,
}

TRANSCRIPT_CARD_MAX_ACTIONS :: 2

TranscriptCardAction :: struct {
	id:      ID, // the button's widget ID
	label:   string,
	primary: bool,
}

TranscriptCard :: struct {
	id:           ID, // the card's own widget ID, recorded for automation (never a press)
	icon:         string, // drawn in a square at the left; empty for none
	title:        string,
	detail:       string,
	status:       string, // empty for none
	statusColor:  Color,
	muted:        bool, // title and details drawn muted (a removed file)
	showProgress: bool,
	progress:     f32, // 0..1
	actions:      [TRANSCRIPT_CARD_MAX_ACTIONS]TranscriptCardAction,
	actionCount:  int,
}

TranscriptPos :: struct {
	unitKey: u64,
	offset:  int,
}

TranscriptSelection :: struct {
	ownerID: ID,
	anchor:  TranscriptPos,
	focus:   TranscriptPos,
}

transcriptUnitIndex :: proc(units: []TranscriptUnit, key: u64) -> int {
	for unit, index in units {
		if unit.key == key {
			return index
		}
	}
	return -1
}

// Returns the selection's start and end in document order. ok is false when either end no
// longer exists or the selection is empty.
transcriptSelectionRange :: proc(
	units: []TranscriptUnit,
	sel: TranscriptSelection,
) -> (
	startIndex, startOffset, endIndex, endOffset: int,
	ok: bool,
) {
	anchorIndex := transcriptUnitIndex(units, sel.anchor.unitKey)
	focusIndex := transcriptUnitIndex(units, sel.focus.unitKey)
	if anchorIndex < 0 || focusIndex < 0 {
		return
	}
	anchorOffset := clamp(sel.anchor.offset, 0, len(units[anchorIndex].text))
	focusOffset := clamp(sel.focus.offset, 0, len(units[focusIndex].text))
	if anchorIndex < focusIndex || (anchorIndex == focusIndex && anchorOffset <= focusOffset) {
		startIndex, startOffset, endIndex, endOffset =
			anchorIndex, anchorOffset, focusIndex, focusOffset
	} else {
		startIndex, startOffset, endIndex, endOffset =
			focusIndex, focusOffset, anchorIndex, anchorOffset
	}
	ok = startIndex != endIndex || startOffset != endOffset
	return
}

// Returns the byte range of unit index selected by sel, or ok=false when it is not selected.
transcriptUnitSelection :: proc(
	units: []TranscriptUnit,
	sel: TranscriptSelection,
	index: int,
) -> (
	lo, hi: int,
	ok: bool,
) {
	startIndex, startOffset, endIndex, endOffset, hasRange := transcriptSelectionRange(units, sel)
	if !hasRange || index < startIndex || index > endIndex {
		return
	}
	lo = index == startIndex ? startOffset : 0
	hi = index == endIndex ? endOffset : len(units[index].text)
	return lo, hi, hi > lo
}

// Builds the text to copy for a selection, joining units with their copy separators.
transcriptSelectionText :: proc(
	units: []TranscriptUnit,
	sel: TranscriptSelection,
	allocator := context.temp_allocator,
) -> string {
	startIndex, startOffset, endIndex, endOffset, ok := transcriptSelectionRange(units, sel)
	if !ok {
		return ""
	}
	builder := strings.builder_make(allocator)
	for index in startIndex ..= endIndex {
		text := units[index].text
		lo := index == startIndex ? startOffset : 0
		hi := index == endIndex ? endOffset : len(text)
		strings.write_string(&builder, text[lo:hi])
		if index < endIndex {
			strings.write_string(&builder, units[index].copySep)
		}
	}
	return strings.to_string(builder)
}
