package widgets

import "base:runtime"
import hm "core:container/handle_map"
import "core:fmt"
import "vendor:raylib"

Handle :: hm.Handle32

Widget :: struct {
	// Common properties
	handle:          Handle,
	parent:          Handle,
	zIndex:          i32, // Determines rendering order; lower values are rendered first; must be unique and continuous starting from 0
	type:            WidgetType,
	rectangle:       raylib.Rectangle,
	anchor:          Anchor,
	sideMode:        SideMode,
	fontPath:        string,
	fontSize:        i32,
	fontSpacing:     f32,
	title:           string,
	focused:         bool,

	// Appearance
	shape:           Shape,
	roundness:       f32,
	forgroundColor:  raylib.Color,
	backgroundColor: raylib.Color,
	enabled:         bool,
	visible:         bool,

	// Event handlers
	onClick:         EventHandler,
	onHover:         EventHandler,
	onLeave:         EventHandler,
	onSubmit:        EventHandler,

	// Panel-specific properties
	childrenLayout:  Layout,
	childSpacing:    f32,
	children:        [dynamic]Handle,

	// Button-specific properties
	buttonType:      ButtonType,
	toggled:         bool,

	// Image-specific properties
	imageScale:      f32,
	imagePath:       string,
	rotation:        f32,

	// Text-specific properties
	textAlignment:   Anchor,
	text:            string,
	// Input-specific properties
	isInput:         bool,
	isInputFocused:  bool,
	submittedText:   string,
	// Multiline text-specific properties
	isMultiline:     bool,
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

init :: proc() {
	hm.dynamic_init(&WidgetMap, context.allocator)
}

@(deferred_none = init)
close :: proc() {
	hm.dynamic_destroy(&WidgetMap)
}

addWidget :: proc(widget: Widget) -> (handle: Handle, err: runtime.Allocator_Error) {
	handle, err = hm.add(&WidgetMap, widget)
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

/*
Returns a slice of widget pointers sorted by their zIndex values for rendering.

The zIndex values must be valid (starting at 0 and continuous).

This should not be called every frame.
*/
getSortedWidgets :: proc() -> (widgets: []^Widget, ok: bool) {
	if !_z_index_valid() {
		return
	}
	widgets = make([]^Widget, hm.dynamic_len(WidgetMap))
	it := hm.iterator_make(&WidgetMap)
	for widget, _ in hm.iterate(&it) {
		widgets[widget.zIndex] = widget
	}
	ok = true
	return
}

@(private)
// Check for duplicate zIndex values and that the index starts at 0 and is continuous in the widget map
_z_index_valid :: proc() -> (dups: bool) {
	if hm.dynamic_len(WidgetMap) == 0 {
		return
	}

	// Build a map of zIndex values to check for duplicates and that they start at 0 and are continuous
	zIndexMap := make(map[i32]bool)
	zIndex := make([dynamic]i32)
	defer delete(zIndexMap)
	defer delete(zIndex)

	// Setup iterator
	it := hm.iterator_make(&WidgetMap)

	// Collect zIndex values
	i: i32 = 0
	for widget, _ in hm.iterate(&it) {
		append(&zIndex, widget.zIndex)
		i += 1
	}

	// return early if no widgets to avoid unnecessary checks
	if len(zIndex) == 0 {
		return
	}
	// Check for duplicates and that zIndex starts at 0 and is continuous
	for z, i in zIndex {
		if z != i32(i) {
			fmt.eprintfln("[WIDGETS] Invalid zIndex: expected %d but found %d", i, z)
			return true
		}
	}
	for widget, _ in hm.iterate(&it) {
		if zIndexMap[widget.zIndex] {
			fmt.eprintfln("[WIDGETS] Duplicate zIndex found: %d", widget.zIndex)
			dups = true
		}
		zIndexMap[widget.zIndex] = true
	}
	return
}
