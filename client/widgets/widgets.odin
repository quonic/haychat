package widgets

import "core:fmt"
import "vendor:raylib"

WidgetDefaultFont: raylib.Font

// Initialize the widgets system, setting up any necessary resources or state.
// At the moment only initializes the default font.
init :: proc() {
	WidgetDefaultFont = raylib.GetFontDefault()
}

// The base Widget struct and a dynamic array to hold all widgets in the client application.
Widget :: union {
	Button,
	Image,
	Label,
	Spacer,
	FlexSpacer,
	Panel,
	TextEntryField,
	TextArea,
	// Add more widget types as needed
}

// Global array to hold all widgets in the application.
widgets: [dynamic]Widget
childWidgets: [dynamic]Widget

// Enums and structs for widget properties and types

// Shape types for widgets
Shape :: enum {
	Rectangle,
	RoundedRectangle,
	Circle,
	// Add more shapes as needed
}

// Anchor points for panels to determine how they should be positioned relative to the window or parent panel when resizing occurs.
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

// Side mode for panels to determine how they should stretch or maintain fixed size along the sides of the window or parent panel.
// - Fixed: The panel maintains its size and position relative to the anchor point, regardless of window resizing.
// - Stretch: The panel stretches along the sides of the window or parent panel, maintaining its position relative to the anchor point but adjusting its size to fill the available space.
PanelSideMode :: enum {
	Fixed,
	Stretch,
}

// Layout mode for how child widgets are arranged within a panel.
PanelChildrenLayout :: enum {
	None,
	Vertical,
	Horizontal,
}

// Button
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

// Image is used for displaying images and has the same functionality as a button.
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

// Label is used for displaying text
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

// Spacer is an invisible widget used to create space between other widgets in a panel layout.
// You define its size to control how much space it takes up.
Spacer :: struct {
	id:       u32,
	parent:   u32,
	position: raylib.Vector2,
	size:     raylib.Vector2,
}

// FlexSpacer is a special type of spacer that expands to fill available space in a panel layout, allowing for flexible spacing between widgets.
FlexSpacer :: struct {
	id:       u32,
	parent:   u32,
	position: raylib.Vector2,
	size:     raylib.Vector2,
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

// Panel is a container widget that can hold other widgets, allowing for grouping and layout management.
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
	children:         [dynamic]^Widget, // Panels can contain other widgets
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

// Find a widget by its unique ID.
// This function iterates through the global widgets array and returns a pointer to the widget if found, or nil if not found.
findWidgetByID :: proc(id: u32, $T: typeid) -> ^T {
	for &widget in widgets {
		if widget.(T).id == id {
			return &widget.(T)
		}
	}
	return nil
}

// Proc Union to add a widget to the global widgets array by reference
add :: proc {
	addButton,
	addImage,
	addLabel,
	addSpacer,
	addFlexSpacer,
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

addSpacer :: proc(spacer: Spacer) {
	append(&widgets, Widget(spacer))
}

addFlexSpacer :: proc(flexSpacer: FlexSpacer) {
	append(&widgets, Widget(flexSpacer))
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

// Adds a child widget to a parent panel by finding the panel by its ID and appending the child widget to the panel's children array.
addChild :: proc(parentPanelID: u32, childWidget: ^$T) {
	parentPanel := findWidgetByID(parentPanelID, Panel)
	if parentPanel == nil || childWidget == nil {
		return
	}

	childAsWidget: Widget = childWidget^
	append(&childWidgets, childAsWidget)
	append(&parentPanel.children, &childWidgets[len(childWidgets) - 1])
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
		case Spacer:
		case FlexSpacer:
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

// Gets the total height of all child widgets within a panel, including spacing between them, based on the panel's children layout mode.
// This is used for calculating scrollable content height and determining when to show scrollbars.
getChidrenTotalHeight :: proc(panel: ^Panel) -> f32 {
	if len(panel.children) == 0 {
		return 0
	}

	switch panel.childrenLayout {
	case .Vertical:
		totalHeight := f32(0)
		for child, index in panel.children {
			switch c in child^ {
			case Button:
				totalHeight += c.size.y
			case Image:
				totalHeight += c.size.y
			case Label:
				totalHeight += c.size.y
			case Spacer:
				totalHeight += c.size.y
			case FlexSpacer:
				totalHeight += panelChildFlowAxisSize(panel, child)
			case Panel:
				totalHeight += c.size.y
			case TextEntryField:
				totalHeight += c.size.y
			case TextArea:
				totalHeight += c.size.y
			case:
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
		for child in panel.children {
			switch c in child^ {
			case Button:
				if c.position.y < minContentY {
					minContentY = c.position.y
				}
				bottom := c.position.y + c.size.y
				if bottom > maxContentY {
					maxContentY = bottom
				}
			case Image:
				if c.position.y < minContentY {
					minContentY = c.position.y
				}
				bottom := c.position.y + c.size.y
				if bottom > maxContentY {
					maxContentY = bottom
				}
			case Label:
				if c.position.y < minContentY {
					minContentY = c.position.y
				}
				bottom := c.position.y + c.size.y
				if bottom > maxContentY {
					maxContentY = bottom
				}
			case Spacer:
				if c.position.y < minContentY {
					minContentY = c.position.y
				}
				bottom := c.position.y + c.size.y
				if bottom > maxContentY {
					maxContentY = bottom
				}
			case FlexSpacer:
				if c.position.y < minContentY {
					minContentY = c.position.y
				}
				bottom := c.position.y + c.size.y
				if bottom > maxContentY {
					maxContentY = bottom
				}
			case Panel:
				if c.position.y < minContentY {
					minContentY = c.position.y
				}
				bottom := c.position.y + c.size.y
				if bottom > maxContentY {
					maxContentY = bottom
				}
			case TextEntryField:
				if c.position.y < minContentY {
					minContentY = c.position.y
				}
				bottom := c.position.y + c.size.y
				if bottom > maxContentY {
					maxContentY = bottom
				}
			case TextArea:
				if c.position.y < minContentY {
					minContentY = c.position.y
				}
				bottom := c.position.y + c.size.y
				if bottom > maxContentY {
					maxContentY = bottom
				}
			case:
			}
		}
		return maxContentY - minContentY
	}

	return 0
}

// Example main function demonstrating the use of the widgets system and panel anchoring.
// This creates a demo panel that changes its anchor point and layout based on window resizing,
// allowing you to verify that the anchoring works correctly.
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

	demoSpacer := FlexSpacer {
		id       = 2,
		parent   = 1,
		position = {0, 0},
		size     = {0, 0},
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
	addChild(1, &demoLabel)
	demoPanel.anchor = .Top
	demoLabel.text = "Top Anchor"
	add(demoPanel)
	addChild(1, &demoLabel)
	demoPanel.anchor = .TopRight
	demoLabel.text = "TopRight Anchor"
	add(demoPanel)
	addChild(1, &demoLabel)
	demoPanel.anchor = .Right
	demoLabel.text = "Right Anchor"
	add(demoPanel)
	addChild(1, &demoLabel)
	demoPanel.anchor = .BottomRight
	demoLabel.text = "BottomRight Anchor"
	add(demoPanel)
	addChild(1, &demoLabel)
	demoPanel.anchor = .Bottom
	demoLabel.text = "Bottom Anchor"
	add(demoPanel)
	addChild(1, &demoLabel)
	demoPanel.anchor = .BottomLeft
	demoLabel.text = "BottomLeft Anchor"
	add(demoPanel)
	addChild(1, &demoLabel)
	demoPanel.anchor = .Left
	demoLabel.text = "Left Anchor"
	add(demoPanel)
	addChild(1, &demoLabel)
	addChild(1, &demoSpacer)
	addChild(1, &demoLabel)

	for !raylib.WindowShouldClose() {
		update()

		raylib.BeginDrawing()
		raylib.ClearBackground(raylib.BLACK)
		draw()
		raylib.EndDrawing()
	}
}
