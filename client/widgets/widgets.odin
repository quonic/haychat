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
	Image,
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

PanelAnchor :: enum {
	TopLeft,
	Top,
	TopRight,
	Right,
	BottomRight,
	Bottom,
	BottomLeft,
	Left,
}

PanelSideMode :: enum {
	Fixed,
	Stretch,
}

PanelChildrenLayout :: enum {
	None,
	Vertical,
	Horizontal,
}

Button :: struct {
	id:           u32,
	parent:       u32, // ID of the parent panel (if any) to which this label belongs
	text:         string,
	position:     raylib.Vector2,
	size:         raylib.Vector2,
	color:        raylib.Color, // Background color of the button
	textColor:    raylib.Color, // Color of the button text
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

Image :: struct {
	id:           u32,
	parent:       u32, // ID of the parent panel (if any) to which this image belongs
	texture:      raylib.Texture,
	sourceRect:   raylib.Rectangle, // Source rectangle in texture space; zero rect draws full texture
	position:     raylib.Vector2,
	size:         raylib.Vector2,
	enabled:      bool, // Whether the image is enabled for interaction (e.g., hovering)
	mouseEntered: bool,
	mouseLeave:   bool,
	mouseClicked: bool,
	onClick:      proc(),
	onHover:      proc(),
	onLeave:      proc(),
	draw:         proc(), // Custom draw function for the image
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
	color:        raylib.Color, // Background color of the label
	textColor:    raylib.Color, // Color of the label text
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
	color:               raylib.Color, // Background color of the text entry field
	textColor:           raylib.Color, // Color of the text in the text entry field
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
	color:        raylib.Color, // Background color of the text area
	textColor:    raylib.Color, // Color of the text in the text area
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
	resolvedPosition: raylib.Vector2,
	resolvedSize:     raylib.Vector2,
	anchor:           PanelAnchor,
	sideMode:         PanelSideMode,
	childrenLayout:   PanelChildrenLayout,
	scrollOffset:     f32, // Current scroll offset for the panel when the content exceeds the visible area
	scrollTopPadding: f32, // Top padding reserved for titles or headers in scrollable area
	shape:            Shape, // Only Rectangle or RoundedRectangle for panels
	roundness:        f32, // Only used for RoundedRectangle shape
	font:             raylib.Font, // Optional custom font for the button text
	fontSize:         f32, // Font size for the button text
	fontSpacing:      f32, // Additional spacing between characters in the button text
	color:            raylib.Color, // Background color of the panel
	textColor:        raylib.Color, // Color of the text in the panel
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
		#partial switch w in widget {
		case Panel:
			if w.id == id {
				return &widget.(Panel)
			}
		case:
		}
	}
	return nil
}

findButtonByID :: proc(id: u32) -> ^Button {
	for &widget in widgets {
		#partial switch w in widget {
		case Button:
			if w.id == id {
				return &widget.(Button)
			}
		case:
		}
	}
	return nil
}

findImageByID :: proc(id: u32) -> ^Image {
	for &widget in widgets {
		#partial switch w in widget {
		case Image:
			if w.id == id {
				return &widget.(Image)
			}
		case:
		}
	}
	return nil
}

findLabelByID :: proc(id: u32) -> ^Label {
	for &widget in widgets {
		#partial switch w in widget {
		case Label:
			if w.id == id {
				return &widget.(Label)
			}
		case:
		}
	}
	return nil
}

findTextEntryFieldByID :: proc(id: u32) -> ^TextEntryField {
	for &widget in widgets {
		#partial switch w in widget {
		case TextEntryField:
			if w.id == id {
				return &widget.(TextEntryField)
			}
		case:
		}
	}
	return nil
}

findTextAreaByID :: proc(id: u32) -> ^TextArea {
	for &widget in widgets {
		#partial switch w in widget {
		case TextArea:
			if w.id == id {
				return &widget.(TextArea)
			}
		case:
		}
	}
	return nil
}

// Proc Union to add a widget to the global widgets array by reference
add :: proc {
	addButton,
	addImage,
	addLabel,
	addPanel,
	addTextEntryField,
	addTextArea,
}

addButton :: proc(button: Button) {
	append(&widgets, Widget(button))
}

addImage :: proc(image: Image) {
	append(&widgets, Widget(image))
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
		switch w in widget {
		case Button:
			if w.parent == 0 {
				drawButton(&widget.(Button))
			}
		case Image:
			if w.parent == 0 {
				drawImage(&widget.(Image))
			}
		case Label:
			if w.parent == 0 {
				drawLabel(&widget.(Label))
			}
		case Panel:
			if w.parent == 0 {
				drawPanel(&widget.(Panel))
			}
		case TextEntryField:
			if w.parent == 0 {
				drawTextEntryField(&widget.(TextEntryField))
			}
		case TextArea:
			if w.parent == 0 {
				drawTextArea(&widget.(TextArea))
			}
		case:
		}
	}
	raylib.EndScissorMode()
}

getChidrenTotalHeight :: proc(panel: ^Panel) -> f32 {
	if len(panel.children) == 0 {
		return 0
	}

	switch panel.childrenLayout {
	case .Vertical:
		totalHeight := f32(0)
		for child, index in panel.children {
			switch typeid_of(type_of(child)) {
			case Button:
				totalHeight += child.(Button).size.y
			case Image:
				totalHeight += child.(Image).size.y
			case Label:
				totalHeight += child.(Label).size.y
			case Panel:
				totalHeight += child.(Panel).size.y
			case TextEntryField:
				totalHeight += child.(TextEntryField).size.y
			case TextArea:
				totalHeight += child.(TextArea).size.y
			}
			if index < len(panel.children) - 1 {
				totalHeight += panel.childSpacing
			}
		}
		return totalHeight
	case .Horizontal:
		return panel.resolvedSize.y
	case .None:
		minContentY := f32(0)
		maxContentY := f32(0)
		for &child in panel.children {
			switch typeid_of(type_of(child)) {
			case Button:
				if child.(Button).position.y < minContentY {
					minContentY = child.(Button).position.y
				}
				bottom := child.(Button).position.y + child.(Button).size.y
				if bottom > maxContentY {
					maxContentY = bottom
				}
			case Image:
				if child.(Image).position.y < minContentY {
					minContentY = child.(Image).position.y
				}
				bottom := child.(Image).position.y + child.(Image).size.y
				if bottom > maxContentY {
					maxContentY = bottom
				}
			case Label:
				if child.(Label).position.y < minContentY {
					minContentY = child.(Label).position.y
				}
				bottom := child.(Label).position.y + child.(Label).size.y
				if bottom > maxContentY {
					maxContentY = bottom
				}
			case Panel:
				if child.(Panel).position.y < minContentY {
					minContentY = child.(Panel).position.y
				}
				bottom := child.(Panel).position.y + child.(Panel).size.y
				if bottom > maxContentY {
					maxContentY = bottom
				}
			case TextEntryField:
				if child.(TextEntryField).position.y < minContentY {
					minContentY = child.(TextEntryField).position.y
				}
				bottom := child.(TextEntryField).position.y + child.(TextEntryField).size.y
				if bottom > maxContentY {
					maxContentY = bottom
				}
			case TextArea:
				if child.(TextArea).position.y < minContentY {
					minContentY = child.(TextArea).position.y
				}
				bottom := child.(TextArea).position.y + child.(TextArea).size.y
				if bottom > maxContentY {
					maxContentY = bottom
				}
			}
		}
		return maxContentY - minContentY
	}

	return 0
}

main :: proc() {
	raylib.SetConfigFlags({.WINDOW_RESIZABLE})
	raylib.InitWindow(960, 640, "HayChat Widgets Panel Anchor Demo")
	defer raylib.CloseWindow()
	raylib.SetTargetFPS(60)

	init()

	demoPanel := Panel {
		id           = 1,
		title        = "TopLeft Anchor",
		position     = {16, 16},
		size         = {260, 160},
		anchor       = .TopLeft,
		sideMode     = .Fixed,
		shape        = .RoundedRectangle,
		roundness    = 0.2,
		font         = WidgetDefaultFont,
		fontSize     = 18,
		fontSpacing  = 0,
		childSpacing = 8,
	}

	demoLabel := Label {
		id          = 2,
		parent      = 1,
		text        = "Resize the window to verify anchoring.",
		position    = {12, 12},
		size        = {demoPanel.size.x - 24, 30},
		shape       = .Rectangle,
		font        = WidgetDefaultFont,
		fontSize    = 14,
		fontSpacing = 0,
		enabled     = false,
	}

	add(demoPanel)
	addChild(1, Widget(demoLabel))
	demoPanel.anchor = .Top
	demoLabel.text = "Top Anchor"
	add(demoPanel)
	addChild(1, Widget(demoLabel))
	demoPanel.anchor = .TopRight
	demoLabel.text = "TopRight Anchor"
	add(demoPanel)
	addChild(1, Widget(demoLabel))
	demoPanel.anchor = .Right
	demoLabel.text = "Right Anchor"
	add(demoPanel)
	addChild(1, Widget(demoLabel))
	demoPanel.anchor = .BottomRight
	demoLabel.text = "BottomRight Anchor"
	add(demoPanel)
	addChild(1, Widget(demoLabel))
	demoPanel.anchor = .Bottom
	demoLabel.text = "Bottom Anchor"
	add(demoPanel)
	addChild(1, Widget(demoLabel))
	demoPanel.anchor = .BottomLeft
	demoLabel.text = "BottomLeft Anchor"
	add(demoPanel)
	addChild(1, Widget(demoLabel))
	demoPanel.anchor = .Left
	demoLabel.text = "Left Anchor"
	add(demoPanel)
	addChild(1, Widget(demoLabel))

	for !raylib.WindowShouldClose() {
		update()

		raylib.BeginDrawing()
		raylib.ClearBackground(raylib.BLACK)
		draw()
		raylib.EndDrawing()
	}
}
