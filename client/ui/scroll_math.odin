package ui

// Scroll position logic, kept free of SDL so it can be unit tested.
//
// Areas that follow the bottom (chat transcripts) stay pinned to the newest content until the
// user scrolls up. While unpinned, the first visible item is remembered by key, so content
// inserted above it (an older history page) does not move what the user is reading.

SCROLL_STICK_EPSILON :: 2

ScrollState :: struct {
	offset:        f32,
	contentH:      f32,
	viewH:         f32,
	initialized:   bool,
	stick:         bool, // Pinned to the bottom; only used by areas that follow the bottom
	anchorKey:     u64,
	anchorDelta:   f32, // Viewport top minus the anchor item's top
	hasAnchor:     bool,
	pendingDelta:  f32, // Offset change requested by a scrollbar drag, applied next frame
	lastUsedFrame: u64,
}

ScrollItem :: struct {
	key:  u64,
	y, h: f32, // Position relative to the top of the content
}

scrollMaxOffset :: proc(contentH, viewH: f32) -> f32 {
	return max(0, contentH - viewH)
}

// Resolves this frame's offset. delta is the requested change in offset from wheel or drag
// input (positive scrolls toward the end). items must be sorted by y; they are only needed by
// areas that follow the bottom.
scrollResolve :: proc(
	s: ^ScrollState,
	items: []ScrollItem,
	contentH, viewH: f32,
	delta: f32,
	followBottom: bool,
) {
	s.contentH = contentH
	s.viewH = viewH
	maxOffset := scrollMaxOffset(contentH, viewH)
	if !s.initialized {
		s.initialized = true
		s.stick = followBottom
	}

	if followBottom {
		if s.stick {
			s.offset = maxOffset
		} else if s.hasAnchor {
			for item in items {
				if item.key == s.anchorKey {
					s.offset = item.y + s.anchorDelta
					break
				}
			}
		}
	}

	s.offset = clamp(s.offset + delta, 0, maxOffset)

	if followBottom {
		if delta != 0 {
			s.stick = s.offset >= maxOffset - SCROLL_STICK_EPSILON
		}
		s.hasAnchor = false
		for item in items {
			if item.y + item.h > s.offset {
				s.anchorKey = item.key
				s.anchorDelta = s.offset - item.y
				s.hasAnchor = true
				break
			}
		}
	}
}

// Jumps an area that follows the bottom back to the newest content.
scrollToBottom :: proc(s: ^ScrollState) {
	s.stick = true
}
