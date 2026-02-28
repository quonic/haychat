package widgets

import "base:runtime"
import hm "core:container/handle_map"
import "core:fmt"
import "core:strings"
import "vendor:raylib"

Handle :: hm.Handle32

Widget :: struct {
	// Common properties
	handle:                  Handle,
	parent:                  Handle,
	type:                    WidgetType,
	rectangle:               raylib.Rectangle,
	anchor:                  Anchor,
	sideMode:                SideMode,
	fontPath:                string,
	fontSize:                f32,
	fontSpacing:             f32,
	title:                   string,
	focused:                 bool,

	// Appearance
	shape:                   Shape,
	roundness:               f32,
	forgroundColor:          raylib.Color,
	backgroundColor:         raylib.Color,
	enabled:                 bool,
	visible:                 bool,

	// Event handlers
	onClick:                 EventHandler,
	onHover:                 EventHandler,
	onLeave:                 EventHandler,
	onSubmit:                EventHandler,

	// Panel-specific properties
	childrenLayout:          Layout,
	childSpacing:            f32,
	children:                [dynamic]Handle,

	// Button-specific properties
	buttonType:              ButtonType,
	toggled:                 bool,

	// Image-specific properties
	imageScale:              f32,
	imagePath:               string,
	rotation:                f32,

	// Text-specific properties
	textAlignment:           Anchor,
	text:                    cstring,
	textColor:               raylib.Color,
	// Input-specific properties
	isInput:                 bool,
	isInputFocused:          bool,
	cursorBlinkTimer:        f32,
	shouldLoseFocusOnSubmit: bool,
	cursorPosition:          i32,
	submittedText:           cstring,
	// Multiline text-specific properties
	isMultiline:             bool,
}

ButtonType :: enum {
	Default,
	Toggle,
}

WidgetType :: enum {
	Panel,
	Button,
	Image,
	Text,
}

Layout :: enum {
	Horizontal,
	Vertical,
	Overlay,
}

Anchor :: enum {
	TopLeft,
	TopCenter,
	TopRight,
	CenterLeft,
	Center,
	CenterRight,
	BottomLeft,
	BottomCenter,
	BottomRight,
}

SideMode :: enum {
	Fixed,
	Stretch,
}

Shape :: enum {
	Rectangle,
	RoundedRectangle,
	Circle,
}

WidgetMap: hm.Dynamic_Handle_Map(Widget, Handle)

WidgetDefaultFont: raylib.Font

init :: proc(fontPath: string = "") {
	if fontPath != "" {
		WidgetDefaultFont = raylib.LoadFont(strings.clone_to_cstring(fontPath))
	} else {
		WidgetDefaultFont = raylib.GetFontDefault()
	}
	hm.dynamic_init(&WidgetMap, context.allocator)
	hm.dynamic_init(&EventMap, context.allocator)
	registerGlobalEventHandlers()
}

close :: proc() {
	hm.dynamic_destroy(&WidgetMap)
	hm.dynamic_destroy(&EventMap)
}

addWidget :: proc(widget: Widget) -> (handle: Handle, err: runtime.Allocator_Error) {
	w := widget
	if w.fontPath != "" {
		font := raylib.LoadFont(strings.clone_to_cstring(w.fontPath))
		if font.texture.id == 0 {
			fmt.eprintfln("[WIDGETS] Failed to load font from path: %s", w.fontPath)
			return {}, runtime.Allocator_Error.Invalid_Argument
		}
	}
	if w.fontSpacing <= 0 {
		w.fontSpacing = 2
	}
	handle, err = hm.add(&WidgetMap, w)
	if err != nil {
		fmt.eprintfln("[WIDGETS] Failed to create widget: %v", err)
		return
	}
	return
}

getWidget :: proc(handle: Handle) -> (widget: ^Widget, ok: bool) {
	widget, ok = hm.get(&WidgetMap, handle)
	return
}

removeWidget :: proc(handle: Handle) -> (found: bool, err: runtime.Allocator_Error) {
	found, err = hm.remove(&WidgetMap, handle)
	return
}

getTopLevelWidgets :: proc() -> (widgets: [dynamic]^Widget) {
	widgets = make([dynamic]^Widget, hm.dynamic_len(WidgetMap))
	it := hm.iterator_make(&WidgetMap)
	for widget, handle in hm.iterate(&it) {
		if widget.parent == {} {
			append(&widgets, widget)
		}
	}
	return
}
