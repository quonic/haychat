package ui

// Layout is done by cutting rectangles: each cut removes a strip from one side of a rect and
// returns it, so screens are described top-down without a retained layout tree.

Rect :: struct {
	x, y, w, h: f32,
}

Vec2 :: [2]f32

cutLeft :: proc(r: ^Rect, amount: f32) -> Rect {
	amount := clamp(amount, 0, r.w)
	cut := Rect{r.x, r.y, amount, r.h}
	r.x += amount
	r.w -= amount
	return cut
}

cutRight :: proc(r: ^Rect, amount: f32) -> Rect {
	amount := clamp(amount, 0, r.w)
	r.w -= amount
	return Rect{r.x + r.w, r.y, amount, r.h}
}

cutTop :: proc(r: ^Rect, amount: f32) -> Rect {
	amount := clamp(amount, 0, r.h)
	cut := Rect{r.x, r.y, r.w, amount}
	r.y += amount
	r.h -= amount
	return cut
}

cutBottom :: proc(r: ^Rect, amount: f32) -> Rect {
	amount := clamp(amount, 0, r.h)
	r.h -= amount
	return Rect{r.x, r.y + r.h, r.w, amount}
}

// Shrinks a rect by padding on every side, never producing a negative size.
shrink :: proc(r: Rect, padding: f32) -> Rect {
	return shrinkXY(r, padding, padding)
}

shrinkXY :: proc(r: Rect, paddingX, paddingY: f32) -> Rect {
	paddingX := min(paddingX, r.w / 2)
	paddingY := min(paddingY, r.h / 2)
	return Rect{r.x + paddingX, r.y + paddingY, r.w - paddingX * 2, r.h - paddingY * 2}
}

contains :: proc(r: Rect, p: Vec2) -> bool {
	return p.x >= r.x && p.y >= r.y && p.x < r.x + r.w && p.y < r.y + r.h
}

intersect :: proc(a, b: Rect) -> Rect {
	x0 := max(a.x, b.x)
	y0 := max(a.y, b.y)
	x1 := min(a.x + a.w, b.x + b.w)
	y1 := min(a.y + a.h, b.y + b.h)
	return Rect{x0, y0, max(0, x1 - x0), max(0, y1 - y0)}
}
