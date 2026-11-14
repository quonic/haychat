package ui

import "core:fmt"
import "core:math"
import "core:strings"
import SDL "vendor:sdl3"
import ttf "vendor:sdl3/ttf"

CARET_BLINK_MS :: 530
TOOLTIP_DELAY_MS :: 500
NO_DEADLINE :: max(u64)

// Embedded font files. The bytes must outlive the context, so #load data is ideal.
FontData :: struct {
	regular: []u8,
	bold:    []u8,
	emoji:   []u8,
}

TooltipRequest :: struct {
	text:   string,
	anchor: Rect,
}

// Context holds everything the immediate-mode UI keeps between frames. Widgets are plain
// procedures that draw directly and report interactions through their return values.
Context :: struct {
	window:            ^SDL.Window,
	renderer:          ^SDL.Renderer,
	engine:            ^ttf.TextEngine,
	fontData:          FontData,
	fonts:             [FontID]^ttf.Font,
	emojiFonts:        [FontID]^ttf.Font, // Fallbacks, sized to match each main font
	theme:             Theme,
	scale:             f32, // Render pixels per logical point
	pixelDensity:      f32, // Render pixels per window coordinate
	frame:             u64,
	nowMS:             u64,
	windowRect:        Rect,
	input:             Input,
	clipStack:         [dynamic]Rect,
	active:            ID, // Widget holding the mouse press
	focus:             ID, // Widget receiving keyboard input
	focusDrawn:        bool,
	pressConsumed:     bool,
	rightPressTaken:   bool, // A widget took this frame's right press (contextMenuRequested)
	scrolls:           map[ID]ScrollState,
	texts:             map[u64]TextEntry,
	emojiTextures:     map[string]EmojiTexture,
	edit:              TextEditState,
	editOwner:         ID,
	preedit:           string, // IME composition text, owned
	caretBlinkStartMS: u64,
	textInputWanted:   bool,
	textInputActive:   bool,
	textInputArea:     SDL.Rect,
	selection:         TranscriptSelection,
	scrollDragGrab:    f32, // Where the scrollbar thumb was grabbed, relative to its top
	hoverOwner:        ID,
	hoverStartMS:      u64,
	hoverSeen:         bool,
	tooltip:           TooltipRequest,
	cursors:           [SDL.SystemCursor]^SDL.Cursor,
	wantCursor:        SDL.SystemCursor,
	currentCursor:     SDL.SystemCursor,
	nextDeadlineMS:    u64, // When the next frame must be drawn without new input
	needsFrame:        bool, // Draw another frame immediately
	automation:        ^Automation, // Scripted-driver records; nil unless enableAutomation ran
	overlay:           OverlayState, // The modal layer drawn on top (overlay.odin)
	menu:              MenuState, // The open popup menu's highlight (menu.odin)
	textMenu:          TextMenuState, // A text input's context menu requests (text_input.odin)
}

init :: proc(
	ctx: ^Context,
	window: ^SDL.Window,
	renderer: ^SDL.Renderer,
	fontData: FontData,
) -> (
	ok: bool,
) {
	ctx.window = window
	ctx.renderer = renderer
	ctx.fontData = fontData
	ctx.theme = themeDark()
	ctx.engine = ttf.CreateRendererTextEngine(renderer)
	if ctx.engine == nil {
		fmt.eprintln("[Error] Failed to create the text engine:", SDL.GetError())
		return false
	}
	ctx.scale = 0
	ctx.currentCursor = .DEFAULT
	if !rescale(ctx) {
		return false
	}
	ctx.needsFrame = true
	return true
}

destroy :: proc(ctx: ^Context) {
	if ctx.textInputActive {
		_ = SDL.StopTextInput(ctx.window)
	}
	closeFonts(ctx)
	if ctx.engine != nil {
		ttf.DestroyRendererTextEngine(ctx.engine)
	}
	for cursor in ctx.cursors {
		if cursor != nil {
			SDL.DestroyCursor(cursor)
		}
	}
	delete(ctx.texts)
	delete(ctx.emojiTextures)
	delete(ctx.scrolls)
	delete(ctx.clipStack)
	delete(ctx.input.events)
	delete(ctx.overlay.events)
	delete(ctx.preedit)
	Automation_destroy(ctx.automation)
	ctx^ = {}
}

// Reopens fonts when the display scale changes so text stays crisp. Returns false when the
// fonts cannot be opened.
rescale :: proc(ctx: ^Context) -> bool {
	scale := SDL.GetWindowDisplayScale(ctx.window)
	if scale <= 0 {
		scale = 1
	}
	ctx.pixelDensity = SDL.GetWindowPixelDensity(ctx.window)
	if ctx.pixelDensity <= 0 {
		ctx.pixelDensity = 1
	}
	if scale == ctx.scale && ctx.fonts[.Regular] != nil {
		return true
	}
	ctx.scale = scale
	closeFonts(ctx)
	return openFonts(ctx)
}

@(private = "file")
openFontBytes :: proc(data: []u8, size: f32) -> ^ttf.Font {
	stream := SDL.IOFromConstMem(raw_data(data), uint(len(data)))
	if stream == nil {
		return nil
	}
	return ttf.OpenFontIO(stream, true, size)
}

@(private = "file")
openFonts :: proc(ctx: ^Context) -> bool {
	size := ctx.theme.fontSize * ctx.scale
	for fontID in FontID {
		data := fontID == .Bold ? ctx.fontData.bold : ctx.fontData.regular
		ctx.fonts[fontID] = openFontBytes(data, size)
		if ctx.fonts[fontID] == nil {
			fmt.eprintln("[Error] Failed to open the UI font:", SDL.GetError())
			return false
		}
		if len(ctx.fontData.emoji) > 0 {
			ctx.emojiFonts[fontID] = openFontBytes(ctx.fontData.emoji, size)
			if ctx.emojiFonts[fontID] != nil {
				_ = ttf.AddFallbackFont(ctx.fonts[fontID], ctx.emojiFonts[fontID])
			}
		}
	}
	return true
}

// Text objects and emoji textures depend on the fonts, so they are released first.
@(private = "file")
closeFonts :: proc(ctx: ^Context) {
	clearTextCaches(ctx)
	for fontID in FontID {
		if ctx.fonts[fontID] != nil {
			ttf.CloseFont(ctx.fonts[fontID])
			ctx.fonts[fontID] = nil
		}
		if ctx.emojiFonts[fontID] != nil {
			ttf.CloseFont(ctx.emojiFonts[fontID])
			ctx.emojiFonts[fontID] = nil
		}
	}
}

// Converts logical points to render pixels.
dp :: proc(ctx: ^Context, value: f32) -> f32 {
	return math.round(value * ctx.scale)
}

lineHeight :: proc(ctx: ^Context, font: FontID = .Regular) -> f32 {
	return f32(ttf.GetFontLineSkip(ctx.fonts[font]))
}

idOf :: proc(name: string, values: ..int) -> ID {
	hash := hashString(0, name)
	for value in values {
		hash = hashInt(hash, value)
	}
	return ID(hash)
}

// Asks the loop to draw a frame no later than deadlineMS.
requestFrameAt :: proc(ctx: ^Context, deadlineMS: u64) {
	ctx.nextDeadlineMS = min(ctx.nextDeadlineMS, deadlineMS)
}

requestFrame :: proc(ctx: ^Context) {
	ctx.needsFrame = true
}

beginFrame :: proc(ctx: ^Context) {
	ctx.frame += 1
	ctx.nowMS = u64(SDL.GetTicks())
	ctx.needsFrame = false
	ctx.nextDeadlineMS = NO_DEADLINE
	ctx.focusDrawn = false
	ctx.pressConsumed = false
	ctx.rightPressTaken = false
	ctx.textInputWanted = false
	ctx.hoverSeen = false
	ctx.tooltip = {}
	ctx.wantCursor = .DEFAULT
	clear(&ctx.clipStack)
	if ctx.automation != nil {
		Automation_clearFrame(ctx.automation)
	}
	// After pressConsumed is reset: a press outside an open overlay is consumed here.
	overlayBeginFrame(ctx)

	w, h: i32
	_ = SDL.GetRenderOutputSize(ctx.renderer, &w, &h)
	ctx.windowRect = Rect{0, 0, f32(w), f32(h)}
	_ = SDL.SetRenderClipRect(ctx.renderer, nil)
	setDrawColor(ctx, ctx.theme.bg)
	_ = SDL.RenderClear(ctx.renderer)
}

endFrame :: proc(ctx: ^Context) {
	input := &ctx.input
	// A press that no widget claimed clears keyboard focus, like clicking empty space.
	if input.mousePressed[.Left] && !ctx.pressConsumed {
		ctx.focus = 0
	}
	if !input.mouseDown[.Left] {
		ctx.active = 0
	}
	// Focus belongs to a widget that is no longer on screen.
	if ctx.focus != 0 && !ctx.focusDrawn {
		ctx.focus = 0
	}
	if !ctx.hoverSeen {
		ctx.hoverOwner = 0
	}

	drawTooltip(ctx)
	updateTextInput(ctx)
	updateCursor(ctx)
	evictCaches(ctx)
	if ctx.automation != nil {
		automationCapture(ctx)
	}
	_ = SDL.RenderPresent(ctx.renderer)

	// Hover and press state settle one frame after input, so draw once more after any input.
	if input.hadEvents {
		ctx.needsFrame = true
	}
}

@(private = "file")
updateTextInput :: proc(ctx: ^Context) {
	if ctx.textInputWanted && !ctx.textInputActive {
		ctx.textInputActive = SDL.StartTextInput(ctx.window)
	} else if !ctx.textInputWanted && ctx.textInputActive {
		_ = SDL.StopTextInput(ctx.window)
		ctx.textInputActive = false
		delete(ctx.preedit)
		ctx.preedit = ""
	}
	if ctx.textInputActive {
		_ = SDL.SetTextInputArea(ctx.window, &ctx.textInputArea, 0)
	}
}

@(private = "file")
updateCursor :: proc(ctx: ^Context) {
	if ctx.wantCursor == ctx.currentCursor {
		return
	}
	if ctx.cursors[ctx.wantCursor] == nil {
		ctx.cursors[ctx.wantCursor] = SDL.CreateSystemCursor(ctx.wantCursor)
	}
	if ctx.cursors[ctx.wantCursor] != nil {
		_ = SDL.SetCursor(ctx.cursors[ctx.wantCursor])
		ctx.currentCursor = ctx.wantCursor
	}
}

@(private = "file")
evictCaches :: proc(ctx: ^Context) {
	staleScrolls := make([dynamic]ID, context.temp_allocator)
	for id, scroll in ctx.scrolls {
		if ctx.frame - scroll.lastUsedFrame > SCROLL_STATE_MAX_IDLE_FRAMES {
			append(&staleScrolls, id)
		}
	}
	for id in staleScrolls {
		delete_key(&ctx.scrolls, id)
	}
	evictTextCaches(ctx)
}

SCROLL_STATE_MAX_IDLE_FRAMES :: 600

// Copies text to the system clipboard.
setClipboardText :: proc(text: string) {
	_ = SDL.SetClipboardText(strings.clone_to_cstring(text, context.temp_allocator))
}

// Returns the clipboard text in the temp allocator.
getClipboardText :: proc() -> string {
	raw := SDL.GetClipboardText()
	if raw == nil {
		return ""
	}
	defer SDL.free(raw)
	return strings.clone_from_cstring(cstring(raw), context.temp_allocator)
}

// Returns true when the mouse is over r, inside the current clip rect, and not over an overlay
// that r is not part of (overlay.odin).
mouseOver :: proc(ctx: ^Context, r: Rect) -> bool {
	if !ctx.input.mouseInWindow {
		return false
	}
	p := ctx.input.mousePos
	if overlayBlocks(ctx.overlay.block, ctx.overlay.blocking, ctx.overlay.drawing, p) {
		return false
	}
	if len(ctx.clipStack) > 0 && !contains(ctx.clipStack[len(ctx.clipStack) - 1], p) {
		return false
	}
	return contains(r, p)
}

Interaction :: struct {
	hovered: bool,
	pressed: bool, // The left button went down on the widget this frame
	held:    bool, // The widget holds the left button
	clicked: bool, // The left button was released over the widget that it was pressed on
}

// Tracks mouse interaction for a widget occupying r.
interact :: proc(ctx: ^Context, id: ID, r: Rect) -> (result: Interaction) {
	input := &ctx.input
	automationWidget(ctx, id, r)
	result.hovered = mouseOver(ctx, r) && (ctx.active == 0 || ctx.active == id)
	if result.hovered && input.mousePressed[.Left] && !ctx.pressConsumed {
		ctx.active = id
		ctx.pressConsumed = true
		result.pressed = true
	}
	if ctx.active == id {
		result.held = true
		if input.mouseReleased[.Left] {
			result.clicked = mouseOver(ctx, r)
		}
	}
	return
}

// Whether a text field had keyboard focus in the last frame. Between frames, while events are
// handled, this is what the user is typing into.
hasTextFocus :: proc(ctx: ^Context) -> bool {
	return ctx.textInputWanted
}

// Marks id as focused this frame; call it from widgets that accept keyboard input.
takeFocus :: proc(ctx: ^Context, id: ID) {
	ctx.focusDrawn = true
	if ctx.focus != id {
		ctx.focus = id
		ctx.caretBlinkStartMS = ctx.nowMS
	}
}

hasFocus :: proc(ctx: ^Context, id: ID) -> bool {
	if ctx.focus == id {
		ctx.focusDrawn = true
		return true
	}
	return false
}

scrollState :: proc(ctx: ^Context, id: ID) -> ^ScrollState {
	_, scroll, _, _ := map_entry(&ctx.scrolls, id)
	scroll.lastUsedFrame = ctx.frame
	return scroll
}
