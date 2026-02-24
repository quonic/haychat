package widgets

import "core:fmt"
import "vendor:raylib"

WidgetDefaultFont: raylib.Font

init :: proc() {
	WidgetDefaultFont = raylib.GetFontDefault()
}

// The base Widget struct and a dynamic array to hold all widgets in the client application.
Widget :: union {
	Button,
	Label,
	Panel,
	TextEntryField,
	TextArea,
	// Add more widget types as needed
}

widgets: [dynamic]Widget

Shape :: enum {
	Rectangle,
	RoundedRectangle,
	Circle,
	// Add more shapes as needed
}

Button :: struct {
	id:           u32,
	parent:       u32, // ID of the parent panel (if any) to which this label belongs
	text:         string,
	position:     raylib.Vector2,
	size:         raylib.Vector2,
	shape:        Shape,
	roundness:    f32, // Only used for RoundedRectangle shape
	font:         raylib.Font, // Optional custom font for the button text
	fontSize:     f32, // Font size for the button text
	fontSpacing:  f32, // Additional spacing between characters in the button text
	enabled:      bool, // Whether the button is enabled or disabled (grayed out)
	mouseEntered: bool,
	mouseLeave:   bool,
	mouseClicked: bool,
	onClick:      proc(),
	onHover:      proc(),
	onLeave:      proc(),
	draw:         proc(), // Custom draw function for the button
}

Label :: struct {
	id:           u32,
	parent:       u32, // ID of the parent panel (if any) to which this label belongs
	text:         string,
	position:     raylib.Vector2,
	size:         raylib.Vector2,
	shape:        Shape,
	roundness:    f32, // Only used for RoundedRectangle shape
	font:         raylib.Font, // Optional custom font for the button text
	fontSize:     f32, // Font size for the button text
	fontSpacing:  f32, // Additional spacing between characters in the button text
	enabled:      bool, // Whether the label is enabled for interaction (e.g., hovering)
	mouseEntered: bool,
	mouseLeave:   bool,
	mouseClicked: bool,
	onClick:      proc(),
	onHover:      proc(),
	onLeave:      proc(),
	draw:         proc(), // Custom draw function for the label
}

// TextEntryField is used for text input
TextEntryField :: struct {
	id:                  u32,
	parent:              u32, // ID of the parent panel (if any) to which this label belongs
	text:                string,
	position:            raylib.Vector2,
	size:                raylib.Vector2,
	shape:               Shape,
	roundness:           f32, // Only used for RoundedRectangle shape
	font:                raylib.Font, // Optional custom font for the button text
	fontSize:            f32, // Font size for the button text
	fontSpacing:         f32, // Additional spacing between characters in the button text
	enabled:             bool, // Whether the text entry field is enabled for input
	padding:             f32, // Padding inside the text entry field for better readability
	mouseEntered:        bool,
	mouseLeave:          bool,
	mouseClicked:        bool,
	cursorVisible:       bool, // Whether to show the text cursor (caret) in the text entry field
	cursorBlinkInterval: f32, // Interval for cursor blinking (e.g., 0.5 seconds)
	cursorPosition:      i32, // Current position of the cursor in the text
	textSumitted:        bool, // Whether the text has been submitted (e.g., by pressing Enter)
	onClick:             proc(),
	onSubmit:            proc(), // Called when the user presses Enter while the text entry field is focused
	onHover:             proc(),
	onLeave:             proc(),
	draw:                proc(), // Custom draw function for the text entry field
}

// TextArea is used for displaying multi-line text, such as chat messages or server descriptions
TextArea :: struct {
	id:           u32,
	parent:       u32, // ID of the parent panel (if any) to which this label belongs
	text:         [dynamic]string,
	position:     raylib.Vector2,
	size:         raylib.Vector2,
	shape:        Shape,
	roundness:    f32, // Only used for RoundedRectangle shape
	font:         raylib.Font, // Optional custom font for the button text
	fontSize:     f32, // Font size for the button text
	fontSpacing:  f32, // Additional spacing between characters in the button text
	enabled:      bool, // Whether the text area is enabled for interaction (e.g., scrolling)
	padding:      f32, // Padding inside the text area for better readability
	scrollOffset: f32, // Current scroll offset for the text area when the content exceeds the visible area
	mouseEntered: bool,
	mouseLeave:   bool,
	mouseClicked: bool,
	onClick:      proc(),
	onHover:      proc(),
	onLeave:      proc(),
	draw:         proc(), // Custom draw function for the text area
}

Panel :: struct {
	id:               u32,
	parent:           u32, // ID of the parent panel (if any) to which this label belongs
	title:            string,
	position:         raylib.Vector2,
	size:             raylib.Vector2,
	scrollOffset:     f32, // Current scroll offset for the panel when the content exceeds the visible area
	scrollTopPadding: f32, // Top padding reserved for titles or headers in scrollable area
	shape:            Shape, // Only Rectangle or RoundedRectangle for panels
	roundness:        f32, // Only used for RoundedRectangle shape
	font:             raylib.Font, // Optional custom font for the button text
	fontSize:         f32, // Font size for the button text
	fontSpacing:      f32, // Additional spacing between characters in the button text
	mouseEntered:     bool,
	mouseLeave:       bool,
	mouseClicked:     bool,
	onClick:          proc(),
	onHover:          proc(),
	onLeave:          proc(),
	children:         [dynamic]Widget, // Panels can contain other widgets
	childSpacing:     f32, // Spacing between child widgets within the panel
	draw:             proc(), // Custom draw function for the panel
}

// Function to calculate the top padding for the scrollable area of a panel based on whether it has a title and the font size.
// This ensures that if a panel has a title, the scrollable content starts below the title, preventing overlap.
panelTitleScrollTopPadding :: proc(panel: ^Panel) -> f32 {
	if panel.title == "" {
		return 0
	}
	font := panel.font
	if font == {} {
		font = WidgetDefaultFont
	}
	textSize := raylib.MeasureTextEx(
		font,
		fmt.caprint(panel.title),
		panel.fontSize,
		panel.fontSpacing,
	)
	return textSize.y + panel.fontSize / 2
}

// Functions to find widgets by their unique ID. These functions return a pointer to the widget if found, or nil if not found.
findPanelByID :: proc(id: u32) -> ^Panel {
	for &widget in widgets {
		if typeid_of(type_of(widget)) == Panel {
			if widget.(Panel).id == id {
				return &widget.(Panel)
			}
		}
	}
	return nil
}

findButtonByID :: proc(id: u32) -> ^Button {
	for &widget in widgets {
		if typeid_of(type_of(widget)) == Button {
			if widget.(Button).id == id {
				return &widget.(Button)
			}
		}
	}
	return nil
}

findLabelByID :: proc(id: u32) -> ^Label {
	for &widget in widgets {
		if typeid_of(type_of(widget)) == Label {
			if widget.(Label).id == id {
				return &widget.(Label)
			}
		}
	}
	return nil
}

findTextEntryFieldByID :: proc(id: u32) -> ^TextEntryField {
	for &widget in widgets {
		if typeid_of(type_of(widget)) == TextEntryField {
			if widget.(TextEntryField).id == id {
				return &widget.(TextEntryField)
			}
		}
	}
	return nil
}

findTextAreaByID :: proc(id: u32) -> ^TextArea {
	for &widget in widgets {
		if typeid_of(type_of(widget)) == TextArea {
			if widget.(TextArea).id == id {
				return &widget.(TextArea)
			}
		}
	}
	return nil
}

// Proc Union to add a widget to the global widgets array by reference
add :: proc {
	addButton,
	addLabel,
	addPanel,
	addTextEntryField,
	addTextArea,
}

addButton :: proc(button: Button) {
	append(&widgets, Widget(button))
}

addLabel :: proc(label: Label) {
	append(&widgets, Widget(label))
}

addPanel :: proc(panel: Panel) {
	append(&widgets, Widget(panel))
}

addTextEntryField :: proc(textEntryField: TextEntryField) {
	append(&widgets, Widget(textEntryField))
}

addTextArea :: proc(textArea: TextArea) {
	append(&widgets, Widget(textArea))
}

addChild :: proc(parentPanelID: u32, childWidget: Widget) {
	parentPanel := findPanelByID(parentPanelID)
	if parentPanel != nil {
		append(&parentPanel.children, childWidget)
	}
}

// Main draw function that iterates through all widgets and calls their respective draw functions
draw :: proc() {
	raylib.BeginScissorMode(0, 0, raylib.GetScreenWidth(), raylib.GetScreenHeight())
	for &widget in widgets {
		switch typeid_of(type_of(widget)) {
		case Button:
			if widget.(Button).parent == 0 {
				drawButton(&widget.(Button))
			}
		case Label:
			if widget.(Label).parent == 0 {
				drawLabel(&widget.(Label))
			}
		case Panel:
			if widget.(Panel).parent == 0 {
				drawPanel(&widget.(Panel))
			}
		case TextEntryField:
			if widget.(TextEntryField).parent == 0 {
				drawTextEntryField(&widget.(TextEntryField))
			}
		case TextArea:
			if widget.(TextArea).parent == 0 {
				drawTextArea(&widget.(TextArea))
			}
		}
	}
	raylib.EndScissorMode()
}

getChidrenTotalHeight :: proc(panel: ^Panel) -> f32 {
	totalHeight := f32(0)
	for &child in panel.children {
		switch typeid_of(type_of(child)) {
		case Button:
			totalHeight += child.(Button).size.y + panel.childSpacing
		case Label:
			totalHeight += child.(Label).size.y + panel.childSpacing
		case Panel:
			totalHeight += child.(Panel).size.y + panel.childSpacing
		case TextEntryField:
			totalHeight += child.(TextEntryField).size.y + panel.childSpacing
		case TextArea:
			totalHeight += child.(TextArea).size.y + panel.childSpacing
		}
	}
	return totalHeight
}
