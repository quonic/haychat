package ui

import "core:c"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"
import SDL "vendor:sdl3"
import ttf "vendor:sdl3/ttf"

// Cached TTF_Text objects. Shaping and wrapping are the expensive part of drawing text, so a
// text object is reused for as long as its widget keeps asking for it.

TEXT_CACHE_MAX_IDLE_FRAMES :: 300
TEXT_CACHE_MAX_ENTRIES :: 4096

TextEntry :: struct {
	text:          ^ttf.Text,
	str:           string, // Owned copy of the laid out string
	font:          FontID,
	wrapW:         i32,
	mayHaveEmoji:  bool,
	lastUsedFrame: u64,
}

EmojiTexture :: struct {
	texture:       ^SDL.Texture,
	w, h:          f32,
	lastUsedFrame: u64,
}

// A laid out text object for the current frame. str is borrowed from the cache entry.
Text :: struct {
	ptr:          ^ttf.Text,
	str:          string,
	font:         FontID,
	mayHaveEmoji: bool,
}

// Returns a laid out text object. key identifies the widget part that owns the text, so a
// changing string updates one object instead of creating a new one per edit. A key of 0 uses
// the string itself as the key. wrapW <= 0 wraps only at newlines.
textGet :: proc(ctx: ^Context, key: u64, font: FontID, str: string, wrapW: f32 = 0) -> Text {
	wrap := wrapW > 0 ? i32(wrapW) : 0
	key := key
	if key == 0 {
		key = hashString(hashInt(u64(font) + 1, int(wrap)), str)
	}
	entry, found := &ctx.texts[key]
	if !found {
		text := ttf.CreateText(ctx.engine, ctx.fonts[font], raw_data(str), uint(len(str)))
		if text == nil {
			return Text{font = font}
		}
		_ = ttf.SetTextWrapWidth(text, wrap)
		ctx.texts[key] = TextEntry {
			text          = text,
			str           = strings.clone(str),
			font          = font,
			wrapW         = wrap,
			mayHaveEmoji  = mayHaveEmoji(str),
			lastUsedFrame = ctx.frame,
		}
		entry = &ctx.texts[key]
		return Text{entry.text, entry.str, font, entry.mayHaveEmoji}
	}
	entry.lastUsedFrame = ctx.frame
	if entry.font != font {
		_ = ttf.SetTextFont(entry.text, ctx.fonts[font])
		entry.font = font
	}
	if entry.str != str {
		_ = ttf.SetTextString(entry.text, raw_data(str), uint(len(str)))
		delete(entry.str)
		entry.str = strings.clone(str)
		entry.mayHaveEmoji = mayHaveEmoji(str)
	}
	if entry.wrapW != wrap {
		_ = ttf.SetTextWrapWidth(entry.text, wrap)
		entry.wrapW = wrap
	}
	return Text{entry.text, entry.str, font, entry.mayHaveEmoji}
}

// Emoji live outside the BMP or in the U+2xxx symbol blocks, so any lead byte from 0xE2 up
// may start one.
@(private = "file")
mayHaveEmoji :: proc(str: string) -> bool {
	for index in 0 ..< len(str) {
		if str[index] >= 0xe2 {
			return true
		}
	}
	return false
}

textSize :: proc(text: Text) -> Vec2 {
	w, h: c.int
	if text.ptr != nil {
		_ = ttf.GetTextSize(text.ptr, &w, &h)
	}
	return Vec2{f32(w), f32(h)}
}

// Height of laid out text, counting a trailing empty line (after a final newline) that
// GetTextSize leaves out. Empty text still occupies one line.
textHeight :: proc(ctx: ^Context, text: Text) -> f32 {
	height := textSize(text).y
	if text.ptr != nil && len(text.str) > 0 {
		sub: ttf.SubString
		if ttf.GetTextSubString(text.ptr, c.int(len(text.str)), &sub) {
			height = max(height, f32(sub.rect.y + sub.rect.h))
		}
	}
	return max(height, lineHeight(ctx, text.font))
}

drawText :: proc(ctx: ^Context, text: Text, pos: Vec2, color: Color) {
	if text.ptr == nil {
		return
	}
	_ = ttf.SetTextColor(text.ptr, color.r, color.g, color.b, color.a)
	_ = ttf.DrawRendererText(text.ptr, pos.x, pos.y)
	if text.mayHaveEmoji {
		drawColorGlyphs(ctx, text, pos)
	}
}

// SDL3_ttf 3.2's renderer text engine lays out color glyphs (emoji) but emits no draw
// operation for them, so they render as blank space. Clusters with no glyph operation are
// rendered here through the surface renderer, which does support color glyphs. If a later
// SDL3_ttf draws them itself, every cluster has an operation and this does nothing.
@(private = "file")
drawColorGlyphs :: proc(ctx: ^Context, text: Text, pos: Vec2) {
	data := text.ptr.internal
	if data == nil || data.num_clusters == 0 {
		return
	}
	str := text.str
	covered := make([]bool, len(str) + 1, context.temp_allocator)
	for index in 0 ..< data.num_ops {
		op := &data.ops[index]
		if op.cmd == .COPY {
			offset := int(op.copy.text_offset)
			if offset >= 0 && offset < len(covered) {
				covered[offset] = true
			}
		}
	}
	clip := currentClip(ctx)
	for index in 0 ..< data.num_clusters {
		cluster := data.clusters[index]
		offset := int(cluster.offset)
		length := int(cluster.length)
		if length == 0 || cluster.rect.w <= 0 || offset + length > len(str) || covered[offset] {
			continue
		}
		clusterText := str[offset:offset + length]
		r, _ := utf8.decode_rune_in_string(clusterText)
		if unicode.is_space(r) || r < 0x80 {
			continue
		}
		dest := Rect {
			pos.x + f32(cluster.rect.x),
			pos.y + f32(cluster.rect.y),
			f32(cluster.rect.w),
			f32(cluster.rect.h),
		}
		if intersect(dest, clip).h <= 0 {
			continue
		}
		glyph := emojiTexture(ctx, text.font, clusterText)
		if glyph == nil || glyph.texture == nil {
			continue
		}
		target := SDL.FRect {
			dest.x + (dest.w - glyph.w) / 2,
			dest.y + (dest.h - glyph.h) / 2,
			glyph.w,
			glyph.h,
		}
		_ = SDL.RenderTexture(ctx.renderer, glyph.texture, nil, &target)
	}
}

@(private = "file")
emojiTexture :: proc(ctx: ^Context, font: FontID, cluster: string) -> ^EmojiTexture {
	key := strings.concatenate({font == .Bold ? "b" : "r", cluster}, context.temp_allocator)
	if glyph, found := &ctx.emojiTextures[key]; found {
		glyph.lastUsedFrame = ctx.frame
		return glyph
	}
	glyph := EmojiTexture {
		lastUsedFrame = ctx.frame,
	}
	surface := ttf.RenderText_Blended(
		ctx.fonts[font],
		raw_data(cluster),
		uint(len(cluster)),
		SDL.Color{255, 255, 255, 255},
	)
	if surface != nil {
		glyph.texture = SDL.CreateTextureFromSurface(ctx.renderer, surface)
		glyph.w = f32(surface.w)
		glyph.h = f32(surface.h)
		SDL.DestroySurface(surface)
	}
	// Failures are cached too, so a glyph that cannot render is not retried every frame.
	ctx.emojiTextures[strings.clone(key)] = glyph
	return &ctx.emojiTextures[key]
}

clearTextCaches :: proc(ctx: ^Context) {
	for _, entry in ctx.texts {
		ttf.DestroyText(entry.text)
		delete(entry.str)
	}
	clear(&ctx.texts)
	for key, glyph in ctx.emojiTextures {
		if glyph.texture != nil {
			SDL.DestroyTexture(glyph.texture)
		}
		delete(key)
	}
	clear(&ctx.emojiTextures)
}

evictTextCaches :: proc(ctx: ^Context) {
	maxIdle := u64(TEXT_CACHE_MAX_IDLE_FRAMES)
	if len(ctx.texts) > TEXT_CACHE_MAX_ENTRIES {
		maxIdle = 1
	}
	// Keys are collected first because deleting while iterating a map is not safe.
	staleTexts := make([dynamic]u64, context.temp_allocator)
	for key, entry in ctx.texts {
		if ctx.frame - entry.lastUsedFrame > maxIdle {
			append(&staleTexts, key)
		}
	}
	for key in staleTexts {
		entry := ctx.texts[key]
		ttf.DestroyText(entry.text)
		delete(entry.str)
		delete_key(&ctx.texts, key)
	}
	staleGlyphs := make([dynamic]string, context.temp_allocator)
	for key, glyph in ctx.emojiTextures {
		if ctx.frame - glyph.lastUsedFrame > TEXT_CACHE_MAX_IDLE_FRAMES {
			append(&staleGlyphs, key)
		}
	}
	for key in staleGlyphs {
		glyph := ctx.emojiTextures[key]
		if glyph.texture != nil {
			SDL.DestroyTexture(glyph.texture)
		}
		ownedKey, _ := delete_key(&ctx.emojiTextures, key)
		delete(ownedKey)
	}
}

// Returns the caret position for byte offset in text, relative to the text origin.
caretRect :: proc(ctx: ^Context, text: Text, offset: int) -> Rect {
	sub: ttf.SubString
	if text.ptr != nil && ttf.GetTextSubString(text.ptr, c.int(offset), &sub) {
		x := f32(sub.rect.x)
		// A right-to-left cluster starts at its right edge.
		if ttf.Direction(sub.flags.direction) == .RTL {
			x += f32(sub.rect.w)
		}
		return Rect{x, f32(sub.rect.y), max(1, dp(ctx, 1)), f32(sub.rect.h)}
	}
	return Rect{0, 0, max(1, dp(ctx, 1)), lineHeight(ctx, text.font)}
}

// Returns the byte offset nearest to point p (relative to the text origin), choosing the
// side of the cluster under p that p is closer to.
textOffsetAtPoint :: proc(text: Text, p: Vec2) -> int {
	sub: ttf.SubString
	if text.ptr == nil || !ttf.GetTextSubStringForPoint(text.ptr, c.int(p.x), c.int(p.y), &sub) {
		return 0
	}
	if sub.length > 0 && p.x > f32(sub.rect.x) + f32(sub.rect.w) / 2 {
		return int(sub.offset + sub.length)
	}
	return int(sub.offset)
}

// Fills the boxes covering bytes [lo, hi) of text, offset by origin.
fillTextRange :: proc(ctx: ^Context, text: Text, origin: Vec2, lo, hi: int, color: Color) {
	if text.ptr == nil || hi <= lo {
		return
	}
	count: c.int
	rects := ttf.GetTextSubStringsForRange(text.ptr, c.int(lo), c.int(hi - lo), &count)
	if rects == nil {
		return
	}
	defer SDL.free(rects)
	for index in 0 ..< count {
		sub := rects[index]
		width := f32(sub.rect.w)
		// Selected newlines have no width; show a sliver so the selection reads as continuous.
		if width == 0 {
			width = dp(ctx, 4)
		}
		fillRect(
			ctx,
			Rect{origin.x + f32(sub.rect.x), origin.y + f32(sub.rect.y), width, f32(sub.rect.h)},
			color,
		)
	}
}
