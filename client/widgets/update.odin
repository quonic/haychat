package widgets

import "core:fmt"
import "core:strings"
import "vendor:raylib"

// Update all widgets
update :: proc() {
	for &widget in widgets {
		switch typeid_of(type_of(widget)) {
		case Button:
			updateWidget(&widget.(Button))
		case Label:
			updateWidget(&widget.(Label))
		case Panel:
			updateWidget(&widget.(Panel))
		case TextEntryField:
			updateWidget(&widget.(TextEntryField))
		case TextArea:
			updateWidget(&widget.(TextArea))
		}
	}
}

updateWidget :: proc {
	updatePanel,
	updateButton,
	updateLabel,
	updateTextEntryField,
	updateTextArea,
}

// Update panel state, such as handling scrolling based on mouse wheel input when the mouse is over the panel, and updating the scroll offset accordingly. This function also ensures that the scroll offset does not exceed the bounds of the content.
updatePanel :: proc(panel: ^Panel) {
	resolvePanelLayout(panel)

	if raylib.CheckCollisionPointRec(
		raylib.GetMousePosition(),
		raylib.Rectangle {
			x = panel.resolvedPosition.x,
			y = panel.resolvedPosition.y,
			width = panel.resolvedSize.x,
			height = panel.resolvedSize.y,
		},
	) {
		if !panel.mouseEntered {
			panel.mouseEntered = true
			if panel.onHover != nil {
				panel.onHover()
			}
		}
	} else {
		if panel.mouseEntered {
			panel.mouseEntered = false
			if panel.onLeave != nil {
				panel.onLeave()
			}
		}
	}

	if panel.mouseEntered && raylib.IsMouseButtonPressed(raylib.MouseButton.LEFT) {
		panel.mouseClicked = true
		if panel.onClick != nil {
			panel.onClick()
		}
	} else {
		panel.mouseClicked = false
	}

	if panel.mouseEntered {
		mouseWheelMove := raylib.GetMouseWheelMove()
		if mouseWheelMove != 0 {
			panel.scrollOffset += mouseWheelMove * 20 // Adjust scroll speed as needed
			// Ensure scroll offset does not go below 0
			if panel.scrollOffset < 0 {
				panel.scrollOffset = 0
			}
			// Ensure scroll offset does not exceed the bounds of the content
			maxScrollOffset :=
				getChidrenTotalHeight(panel) - (panel.resolvedSize.y - panel.scrollTopPadding)
			if panel.scrollOffset > maxScrollOffset {
				panel.scrollOffset = maxScrollOffset
			}
		}
	}
}

updateButton :: proc(button: ^Button) {
	if button.enabled {
		if raylib.CheckCollisionPointRec(
			raylib.GetMousePosition(),
			raylib.Rectangle {
				x = button.position.x,
				y = button.position.y,
				width = button.size.x,
				height = button.size.y,
			},
		) {
			if !button.mouseEntered {
				button.mouseEntered = true
				if button.onHover != nil {
					button.onHover()
				}
			}
		} else {
			if button.mouseEntered {
				button.mouseEntered = false
				if button.onLeave != nil {
					button.onLeave()
				}
			}
		}
		if button.mouseEntered && raylib.IsMouseButtonPressed(raylib.MouseButton.LEFT) {
			button.mouseClicked = true
			if button.onClick != nil {
				button.onClick()
			}
		} else {
			button.mouseClicked = false
		}
	}
}

updateLabel :: proc(label: ^Label) {
	if label.enabled {
		if raylib.CheckCollisionPointRec(
			raylib.GetMousePosition(),
			raylib.Rectangle {
				x = label.position.x,
				y = label.position.y,
				width = label.size.x,
				height = label.size.y,
			},
		) {
			if !label.mouseEntered {
				label.mouseEntered = true
				if label.onHover != nil {
					label.onHover()
				}
			}
		} else {
			if label.mouseEntered {
				label.mouseEntered = false
				if label.onLeave != nil {
					label.onLeave()
				}
			}
		}
		if label.mouseEntered && raylib.IsMouseButtonPressed(raylib.MouseButton.LEFT) {
			label.mouseClicked = true
			if label.onClick != nil {
				label.onClick()
			}
		} else {
			label.mouseClicked = false
		}
	}
}

updateTextEntryField :: proc(textEntryField: ^TextEntryField) {
	// This function handles keyboard input and update the text entry field's text accordingly.
	if textEntryField.enabled {
		if raylib.CheckCollisionPointRec(
			raylib.GetMousePosition(),
			raylib.Rectangle {
				x = textEntryField.position.x,
				y = textEntryField.position.y,
				width = textEntryField.size.x,
				height = textEntryField.size.y,
			},
		) {
			if !textEntryField.mouseEntered {
				textEntryField.mouseEntered = true
				if textEntryField.onHover != nil {
					textEntryField.onHover()
				}
			}
		} else {
			if textEntryField.mouseEntered {
				textEntryField.mouseEntered = false
				if textEntryField.onLeave != nil {
					textEntryField.onLeave()
				}
			}
		}
		if textEntryField.mouseEntered && raylib.IsMouseButtonPressed(raylib.MouseButton.LEFT) {
			textEntryField.mouseClicked = true
		} else {
			textEntryField.mouseClicked = false
		}

		if textEntryField.mouseClicked {
			// Get the pressed key
			shiftPressed: bool
			for key := raylib.GetKeyPressed(); key != .KEY_NULL; key = raylib.GetKeyPressed() {
				if key == .LEFT_SHIFT || key == .RIGHT_SHIFT {
					shiftPressed = true
				} else if key == .BACKSPACE {
					if len(textEntryField.text) > 0 {
						textEntryField.text = textEntryField.text[0:len(textEntryField.text) - 1] // Remove the last character
					}
				} else if shiftPressed && key == .ENTER {
					textEntryField.text = strings.concatenate({textEntryField.text, "\n"}) // Add a new line
				} else if key == .ENTER {
					textEntryField.textSumitted = true
					if textEntryField.onSubmit != nil {
						textEntryField.onSubmit()
					}
				} else if key == .TAB {
					textEntryField.text = strings.concatenate({textEntryField.text, "\t"}) // Add a tab character
				} else {
					char := raylib.GetCharPressed()
					if char != 0 {
						if shiftPressed {
							char = toUpperCase(char)
						}
						textEntryField.text = fmt.aprint(textEntryField.text, char)
					}
				}
			}
		}
	}
}

toUpperCase :: proc(char: rune) -> rune {
	if char >= 97 && char <= 122 { 	// a-z
		return char - 32
	}
	return char
}

updateTextArea :: proc(textArea: ^TextArea) {
	// TextArea is NOT editable, so we don't need to handle keyboard input. We only need to handle mouse hover and click events.
	if textArea.enabled {
		if raylib.CheckCollisionPointRec(
			raylib.GetMousePosition(),
			raylib.Rectangle {
				x = textArea.position.x,
				y = textArea.position.y,
				width = textArea.size.x,
				height = textArea.size.y,
			},
		) {
			if !textArea.mouseEntered {
				textArea.mouseEntered = true
				if textArea.onHover != nil {
					textArea.onHover()
				}
			}
		} else {
			if textArea.mouseEntered {
				textArea.mouseEntered = false
				if textArea.onLeave != nil {
					textArea.onLeave()
				}
			}
		}
		if textArea.mouseEntered && raylib.IsMouseButtonPressed(raylib.MouseButton.LEFT) {
			textArea.mouseClicked = true
			if textArea.onClick != nil {
				textArea.onClick()
			}
		} else {
			textArea.mouseClicked = false
		}
	}
}
