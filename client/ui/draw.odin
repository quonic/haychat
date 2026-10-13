package ui

import "core:math"
import SDL "vendor:sdl3"

ROUNDED_CORNER_SEGMENTS :: 5

setDrawColor :: proc(ctx: ^Context, color: Color) {
	_ = SDL.SetRenderDrawColor(ctx.renderer, color.r, color.g, color.b, color.a)
}

toFRect :: proc(r: Rect) -> SDL.FRect {
	return SDL.FRect{r.x, r.y, r.w, r.h}
}

fillRect :: proc(ctx: ^Context, r: Rect, color: Color) {
	if r.w <= 0 || r.h <= 0 || color.a == 0 {
		return
	}
	setDrawColor(ctx, color)
	rect := toFRect(r)
	_ = SDL.RenderFillRect(ctx.renderer, &rect)
}

strokeRect :: proc(ctx: ^Context, r: Rect, color: Color) {
	if r.w <= 0 || r.h <= 0 || color.a == 0 {
		return
	}
	setDrawColor(ctx, color)
	rect := toFRect(r)
	_ = SDL.RenderRect(ctx.renderer, &rect)
}

fillRoundedRect :: proc(ctx: ^Context, r: Rect, radius: f32, color: Color) {
	radius := min(radius, r.w / 2, r.h / 2)
	if radius < 1 {
		fillRect(ctx, r, color)
		return
	}
	if r.w <= 0 || r.h <= 0 || color.a == 0 {
		return
	}
	// A triangle fan around the center, written out as a triangle list.
	fcolor := SDL.FColor {
		f32(color.r) / 255,
		f32(color.g) / 255,
		f32(color.b) / 255,
		f32(color.a) / 255,
	}
	corners := [4]Vec2 {
		{r.x + r.w - radius, r.y + radius},
		{r.x + r.w - radius, r.y + r.h - radius},
		{r.x + radius, r.y + r.h - radius},
		{r.x + radius, r.y + radius},
	}
	perimeter: [4 * (ROUNDED_CORNER_SEGMENTS + 1)]Vec2
	count := 0
	for corner, cornerIndex in corners {
		startAngle := f32(cornerIndex) * math.PI / 2 - math.PI / 2
		for segment in 0 ..= ROUNDED_CORNER_SEGMENTS {
			angle := startAngle + f32(segment) / ROUNDED_CORNER_SEGMENTS * math.PI / 2
			perimeter[count] = corner + Vec2{math.cos(angle), math.sin(angle)} * radius
			count += 1
		}
	}
	center := Vec2{r.x + r.w / 2, r.y + r.h / 2}
	vertices: [len(perimeter) * 3]SDL.Vertex
	for index in 0 ..< count {
		next := perimeter[(index + 1) % count]
		vertices[index * 3 + 0] = SDL.Vertex{position = {center.x, center.y}, color = fcolor}
		vertices[index * 3 + 1] = SDL.Vertex {
			position = {perimeter[index].x, perimeter[index].y},
			color    = fcolor,
		}
		vertices[index * 3 + 2] = SDL.Vertex{position = {next.x, next.y}, color = fcolor}
	}
	_ = SDL.RenderGeometry(ctx.renderer, nil, &vertices[0], i32(count * 3), nil, 0)
}

// Restricts drawing and hit testing to r, intersected with the current clip.
pushClip :: proc(ctx: ^Context, r: Rect) {
	clip := r
	if len(ctx.clipStack) > 0 {
		clip = intersect(ctx.clipStack[len(ctx.clipStack) - 1], r)
	}
	append(&ctx.clipStack, clip)
	applyClip(ctx, clip)
}

popClip :: proc(ctx: ^Context) {
	pop(&ctx.clipStack)
	if len(ctx.clipStack) > 0 {
		applyClip(ctx, ctx.clipStack[len(ctx.clipStack) - 1])
	} else {
		_ = SDL.SetRenderClipRect(ctx.renderer, nil)
	}
}

currentClip :: proc(ctx: ^Context) -> Rect {
	if len(ctx.clipStack) > 0 {
		return ctx.clipStack[len(ctx.clipStack) - 1]
	}
	return ctx.windowRect
}

@(private = "file")
applyClip :: proc(ctx: ^Context, clip: Rect) {
	x0 := math.floor(clip.x)
	y0 := math.floor(clip.y)
	rect := SDL.Rect {
		i32(x0),
		i32(y0),
		i32(math.ceil(clip.x + clip.w) - x0),
		i32(math.ceil(clip.y + clip.h) - y0),
	}
	_ = SDL.SetRenderClipRect(ctx.renderer, &rect)
}
