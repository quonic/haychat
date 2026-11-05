package ui

import "core:math"

// Level meters and sliders. Both are generic: callers map their own units (decibels, gains)
// onto a fraction or a value range, so the toolkit knows nothing about audio.

// Where value sits between low and high, as 0..1. A range with no width gives 0.
rangeFraction :: proc(value, low, high: f32) -> f32 {
	if high <= low {
		return 0
	}
	return clamp((value - low) / (high - low), 0, 1)
}

// The value a slider over track takes with the pointer at x: clamped to low..high and rounded
// to the nearest multiple of step from low (no rounding when step is 0 or less).
sliderValueAt :: proc(track: Rect, x: f32, low, high, step: f32) -> f32 {
	if track.w <= 0 || high <= low {
		return low
	}
	value := low + (high - low) * clamp((x - track.x) / track.w, 0, 1)
	if step > 0 {
		value = low + math.round((value - low) / step) * step
	}
	return clamp(value, low, high)
}

LevelMeterOptions :: struct {
	color:          Maybe(Color), // The filled part; the theme's success color by default
	// A marker drawn across the meter at this fraction (for example a gate threshold).
	markerFraction: Maybe(f32),
	markerColor:    Maybe(Color), // The theme's foreground by default
}

// A horizontal bar filled to fraction (0..1) of r, with an optional marker line.
levelMeter :: proc(ctx: ^Context, r: Rect, fraction: f32, options: LevelMeterOptions = {}) {
	if r.w <= 0 || r.h <= 0 {
		return
	}
	radius := min(r.h / 2, dp(ctx, ctx.theme.cornerRadius))
	// The border color keeps the empty track visible on surface and elevated panels alike.
	fillRoundedRect(ctx, r, radius, ctx.theme.border)
	filled := clamp(fraction, 0, 1) * r.w
	if filled >= 1 {
		color := options.color.? or_else ctx.theme.success
		fillRoundedRect(ctx, Rect{r.x, r.y, filled, r.h}, min(radius, filled / 2), color)
	}
	if marker, hasMarker := options.markerFraction.?; hasMarker {
		width := max(1, dp(ctx, 2))
		x := r.x + clamp(marker, 0, 1) * r.w - width / 2
		markerColor := options.markerColor.? or_else ctx.theme.fg
		fillRect(ctx, Rect{clamp(x, r.x, r.x + r.w - width), r.y, width, r.h}, markerColor)
	}
}

SliderResult :: struct {
	value:    f32,
	changed:  bool, // value differs from the one passed in
	dragging: bool, // the pointer holds the slider
	released: bool, // the pointer let go of the slider this frame
}

SLIDER_TRACK_HEIGHT :: 4
SLIDER_KNOB_SIZE :: 14

// A horizontal slider over r for value in low..high, snapped to step. Pressing anywhere on it
// jumps to that position, and dragging follows the pointer. The caller keeps the value.
slider :: proc(
	ctx: ^Context,
	id: ID,
	r: Rect,
	value, low, high: f32,
	step: f32 = 0,
) -> (
	result: SliderResult,
) {
	result.value = clamp(value, low, high)
	knob := dp(ctx, SLIDER_KNOB_SIZE)
	// The knob's centre travels between the ends of the track, so it never leaves r.
	track := Rect{r.x + knob / 2, r.y, max(0, r.w - knob), r.h}
	it := interact(ctx, id, r)
	if it.hovered || it.held {
		ctx.wantCursor = .POINTER
	}
	if it.held {
		result.dragging = true
		result.value = sliderValueAt(track, ctx.input.mousePos.x, low, high, step)
		if ctx.input.mouseReleased[.Left] {
			result.released = true
		}
	}
	result.changed = result.value != value

	trackH := max(1, dp(ctx, SLIDER_TRACK_HEIGHT))
	trackY := r.y + (r.h - trackH) / 2
	fraction := rangeFraction(result.value, low, high)
	fillRoundedRect(ctx, Rect{track.x, trackY, track.w, trackH}, trackH / 2, ctx.theme.border)
	fillRoundedRect(
		ctx,
		Rect{track.x, trackY, fraction * track.w, trackH},
		trackH / 2,
		ctx.theme.primary,
	)
	knobRect := Rect{track.x + fraction * track.w - knob / 2, r.y + (r.h - knob) / 2, knob, knob}
	knobColor := it.held || it.hovered ? ctx.theme.onPrimary : ctx.theme.fg
	fillRoundedRect(ctx, knobRect, knob / 2, knobColor)
	return
}
