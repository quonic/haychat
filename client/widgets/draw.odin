package widgets


import "core:fmt"
import "core:strings"
import "vendor:raylib"

drawButton :: proc(button: ^Button) {
	// Call the custom draw function if it exists
	if button.draw != nil {
		button.draw()
		return
	}

	// If no font is set, use the default font
	if button.font == {} {
		button.font = WidgetDefaultFont
	}

	buttonPosition := button.position
	if button.parent != 0 {
		parentPanel := findPanelByID(button.parent)
		if parentPanel != nil {
			// Adjust button position based on the parent panel's position
			buttonPosition.x += parentPanel.position.x
			buttonPosition.y += parentPanel.position.y
		}
	}

	// Default drawing logic based on shape
	switch button.shape {
	case .Rectangle:
		raylib.DrawRectangleV(buttonPosition, button.size, raylib.RED)
	case .RoundedRectangle:
		raylib.DrawRectangleRounded(
			raylib.Rectangle {
				x = buttonPosition.x,
				y = buttonPosition.y,
				width = button.size.x,
				height = button.size.y,
			},
			button.roundness,
			0, // Segments for rounded corners (0 for auto)
			raylib.BLUE,
		)
	case .Circle:
		radius := f32(button.size.x) / 2 // Assuming size.x is diameter
		raylib.DrawCircleV(buttonPosition, radius, raylib.GREEN)
	}

	// Draw the button text centered within the button
	textSize := raylib.MeasureTextEx(
		button.font,
		fmt.caprint(button.text),
		button.fontSize,
		button.fontSpacing,
	)
	textPosition := raylib.Vector2 {
		buttonPosition.x + (button.size.x - textSize.x) / 2,
		buttonPosition.y + (button.size.y - textSize.y) / 2, // Center vertically based on font size
	}
	raylib.DrawTextEx(
		button.font,
		fmt.caprint(button.text),
		textPosition,
		button.fontSize,
		button.fontSpacing,
		raylib.WHITE,
	)
}

drawLabel :: proc(label: ^Label) {
	// Call the custom draw function if it exists
	if label.draw != nil {
		label.draw()
		return
	}

	// If no font is set, use the default font
	if label.font == {} {
		label.font = WidgetDefaultFont
	}

	labelPosition := label.position
	if label.parent != 0 {
		parentPanel := findPanelByID(label.parent)
		if parentPanel != nil {
			// Adjust label position based on the parent panel's position
			labelPosition.x += parentPanel.position.x
			labelPosition.y += parentPanel.position.y
		}
	}

	// Default drawing logic based on shape
	switch label.shape {
	case .Rectangle:
		raylib.DrawRectangleV(labelPosition, label.size, raylib.DARKGRAY)
	case .RoundedRectangle:
		raylib.DrawRectangleRounded(
			raylib.Rectangle {
				x = labelPosition.x,
				y = labelPosition.y,
				width = label.size.x,
				height = label.size.y,
			},
			label.roundness,
			0, // Segments for rounded corners (0 for auto)
			raylib.GRAY,
		)
	case .Circle:
		radius := f32(label.size.x) / 2 // Assuming size.x is diameter
		raylib.DrawCircleV(labelPosition, radius, raylib.LIGHTGRAY)
	}

	// Draw the label text centered within the label
	textSize := raylib.MeasureTextEx(
		label.font,
		fmt.caprint(label.text),
		label.fontSize,
		label.fontSpacing,
	)
	textPosition := raylib.Vector2 {
		labelPosition.x + (label.size.x - textSize.x) / 2,
		labelPosition.y + (label.size.y - textSize.y) / 2, // Center vertically based on font size
	}
	raylib.DrawTextEx(
		label.font,
		fmt.caprint(label.text),
		textPosition,
		label.fontSize,
		label.fontSpacing,
		raylib.WHITE,
	)
}

drawPanel :: proc(panel: ^Panel) {
	// Call the custom draw function if it exists
	if panel.draw != nil {
		panel.draw()
		return
	}

	originalPanelPosition := panel.position
	if panel.parent != 0 {
		parentPanel := findPanelByID(panel.parent)
		if parentPanel != nil {
			panel.position.x += parentPanel.position.x
			panel.position.y += parentPanel.position.y
		}
	}
	defer panel.position = originalPanelPosition

	// If no font is set, use the default font
	if panel.font == {} {
		panel.font = WidgetDefaultFont
	}
	if panel.scrollTopPadding <= 0 && panel.title != "" {
		panel.scrollTopPadding = panelTitleScrollTopPadding(panel)
	}

	// Default drawing logic based on shape
	switch panel.shape {
	case .Rectangle:
		raylib.DrawRectangleV(panel.position, panel.size, raylib.DARKGRAY)
	case .RoundedRectangle:
		raylib.DrawRectangleRounded(
			raylib.Rectangle {
				x = panel.position.x,
				y = panel.position.y,
				width = panel.size.x,
				height = panel.size.y,
			},
			panel.roundness,
			0, // Segments for rounded corners (0 for auto)
			raylib.GRAY,
		)
	case .Circle:
		radius := f32(panel.size.x) / 2 // Assuming size.x is diameter
		raylib.DrawCircleV(panel.position, radius, raylib.LIGHTGRAY)
	}

	maxContentY := f32(0)
	minContentY := f32(0)

	for &child in panel.children {
		switch c in child {
		case Button:
			button := child.(Button)
			if button.position.y < minContentY {
				minContentY = button.position.y
			}
			bottom := button.position.y + button.size.y
			if bottom > maxContentY {
				maxContentY = bottom
			}
		case Label:
			label := child.(Label)
			if label.position.y < minContentY {
				minContentY = label.position.y
			}
			bottom := label.position.y + label.size.y
			if bottom > maxContentY {
				maxContentY = bottom
			}
		case Panel:
			childPanel := child.(Panel)
			if childPanel.position.y < minContentY {
				minContentY = childPanel.position.y
			}
			bottom := childPanel.position.y + childPanel.size.y
			if bottom > maxContentY {
				maxContentY = bottom
			}
		case TextEntryField:
			entryField := child.(TextEntryField)
			if entryField.position.y < minContentY {
				minContentY = entryField.position.y
			}
			bottom := entryField.position.y + entryField.size.y
			if bottom > maxContentY {
				maxContentY = bottom
			}
		case TextArea:
			textArea := child.(TextArea)
			if textArea.position.y < minContentY {
				minContentY = textArea.position.y
			}
			bottom := textArea.position.y + textArea.size.y
			if bottom > maxContentY {
				maxContentY = bottom
			}
		}
	}

	visibleTopPadding := panel.scrollTopPadding
	visibleHeight := panel.size.y - visibleTopPadding
	if visibleHeight < 0 {
		visibleHeight = 0
	}
	contentHeight := maxContentY - minContentY
	if contentHeight > visibleHeight {
		minScrollOffset := minContentY - visibleTopPadding
		maxScrollOffset := maxContentY - panel.size.y
		if panel.scrollOffset < minScrollOffset {
			panel.scrollOffset = minScrollOffset
		} else if panel.scrollOffset > maxScrollOffset {
			panel.scrollOffset = maxScrollOffset
		}
	} else {
		panel.scrollOffset = 0
	}

	// Draw the panel title centered at the top of the panel
	if panel.title != "" {
		textSize := raylib.MeasureTextEx(
			panel.font,
			fmt.caprint(panel.title),
			panel.fontSize,
			panel.fontSpacing,
		)
		textPosition := raylib.Vector2 {
			panel.position.x + (panel.size.x - textSize.x) / 2,
			panel.position.y + panel.fontSize / 2, // Position at the top with some padding
		}
		raylib.DrawTextEx(
			panel.font,
			fmt.caprint(panel.title),
			textPosition,
			panel.fontSize,
			panel.fontSpacing,
			raylib.WHITE,
		)
	}

	// Draw child widgets contained within the panel
	scissorY := panel.position.y + visibleTopPadding
	scissorHeight := panel.size.y - visibleTopPadding
	if scissorHeight < 0 {
		scissorHeight = 0
	}
	raylib.BeginScissorMode(
		i32(panel.position.x),
		i32(scissorY),
		i32(panel.size.x),
		i32(scissorHeight),
	)
	defer raylib.EndScissorMode()
	applyScroll := panel.scrollOffset != 0
	for &child in panel.children {
		switch c in child {
		case Button:
			button := &child.(Button)
			if applyScroll {
				button.position.y -= panel.scrollOffset
			}
			drawButton(button)
			if applyScroll {
				button.position.y += panel.scrollOffset
			}
		case Label:
			label := &child.(Label)
			if applyScroll {
				label.position.y -= panel.scrollOffset
			}
			drawLabel(label)
			if applyScroll {
				label.position.y += panel.scrollOffset
			}
		case Panel:
			childPanel := &child.(Panel)
			if applyScroll {
				childPanel.position.y -= panel.scrollOffset
			}
			drawPanel(childPanel)
			if applyScroll {
				childPanel.position.y += panel.scrollOffset
			}
		case TextEntryField:
			entryField := &child.(TextEntryField)
			if applyScroll {
				entryField.position.y -= panel.scrollOffset
			}
			drawTextEntryField(entryField)
			if applyScroll {
				entryField.position.y += panel.scrollOffset
			}
		case TextArea:
			textArea := &child.(TextArea)
			if applyScroll {
				textArea.position.y -= panel.scrollOffset
			}
			if f32(len(textArea.text)) *
				   raylib.MeasureTextEx(textArea.font, "sample", textArea.fontSize, textArea.fontSpacing).y >
			   textArea.size.y {
				drawTextAreaWithScrolling(textArea, textArea.scrollOffset) // Pass the current scroll offset for the text area
			} else {
				drawTextArea(textArea)
			}
			if applyScroll {
				textArea.position.y += panel.scrollOffset
			}
		// Add more widget types as needed
		}
	}
}

drawTextEntryField :: proc(textEntryField: ^TextEntryField) {
	// Call the custom draw function if it exists
	if textEntryField.draw != nil {
		textEntryField.draw()
		return
	}

	// If no font is set, use the default font
	if textEntryField.font == {} {
		textEntryField.font = WidgetDefaultFont
	}

	textEntryFieldPosition := textEntryField.position
	if textEntryField.parent != 0 {
		parentPanel := findPanelByID(textEntryField.parent)
		if parentPanel != nil {
			// Adjust text entry field position based on the parent panel's position
			textEntryFieldPosition.x += parentPanel.position.x
			textEntryFieldPosition.y += parentPanel.position.y
		}
	}

	// Default drawing logic based on shape
	switch textEntryField.shape {
	case .Rectangle:
		raylib.DrawRectangleV(textEntryFieldPosition, textEntryField.size, raylib.DARKGRAY)
	case .RoundedRectangle:
		raylib.DrawRectangleRounded(
			raylib.Rectangle {
				x = textEntryFieldPosition.x,
				y = textEntryFieldPosition.y,
				width = textEntryField.size.x,
				height = textEntryField.size.y,
			},
			textEntryField.roundness,
			0, // Segments for rounded corners (0 for auto)
			raylib.GRAY,
		)
	case .Circle:
		radius := f32(textEntryField.size.x) / 2 // Assuming size.x is diameter
		raylib.DrawCircleV(textEntryFieldPosition, radius, raylib.LIGHTGRAY)
	}

	// Draw the current text in the entry field with padding
	textPosition := raylib.Vector2 {
		textEntryFieldPosition.x + textEntryField.padding, // Add some padding from the left edge
		textEntryFieldPosition.y + (textEntryField.size.y - textEntryField.fontSize) / 2, // Center vertically based on font size
	}
	raylib.DrawTextEx(
		textEntryField.font,
		fmt.caprint(textEntryField.text),
		textPosition,
		textEntryField.fontSize,
		textEntryField.fontSpacing,
		raylib.WHITE,
	)
}

drawTextArea :: proc(textArea: ^TextArea) {
	// Call the custom draw function if it exists
	if textArea.draw != nil {
		textArea.draw()
		return
	}

	// If no font is set, use the default font
	if textArea.font == {} {
		textArea.font = WidgetDefaultFont
	}

	textAreaPosition := textArea.position
	if textArea.parent != 0 {
		parentPanel := findPanelByID(textArea.parent)
		if parentPanel != nil {
			// Adjust text area position based on the parent panel's position
			textAreaPosition.x += parentPanel.position.x
			textAreaPosition.y += parentPanel.position.y
		}
	}

	// Default drawing logic based on shape
	switch textArea.shape {
	case .Rectangle:
		raylib.DrawRectangleV(textAreaPosition, textArea.size, raylib.DARKGRAY)
	case .RoundedRectangle:
		raylib.DrawRectangleRounded(
			raylib.Rectangle {
				x = textAreaPosition.x,
				y = textAreaPosition.y,
				width = textArea.size.x,
				height = textArea.size.y,
			},
			textArea.roundness,
			0, // Segments for rounded corners (0 for auto)
			raylib.GRAY,
		)
	case .Circle:
		radius := f32(textArea.size.x) / 2 // Assuming size.x is diameter
		raylib.DrawCircleV(textAreaPosition, radius, raylib.LIGHTGRAY)
	}

	// Draw each line of text within the text area with proper spacing
	lineHeight := textArea.fontSize + textArea.fontSpacing
	for line, i in textArea.text {
		linePosition := raylib.Vector2 {
			textAreaPosition.x + textArea.padding, // Add some padding from the left edge
			textAreaPosition.y + textArea.padding + f32(i) * lineHeight, // Position each line with spacing
		}
		raylib.DrawTextEx(
			textArea.font,
			fmt.caprint(line),
			linePosition,
			textArea.fontSize,
			textArea.fontSpacing,
			raylib.WHITE,
		)
	}
}

drawTextAreaWithScrolling :: proc(textArea: ^TextArea, scrollOffset: f32) {
	// Call the custom draw function if it exists
	if textArea.draw != nil {
		textArea.draw()
		return
	}

	// If no font is set, use the default font
	if textArea.font == {} {
		textArea.font = WidgetDefaultFont
	}

	textAreaPosition := textArea.position
	if textArea.parent != 0 {
		parentPanel := findPanelByID(textArea.parent)
		if parentPanel != nil {
			// Adjust text area position based on the parent panel's position
			textAreaPosition.x += parentPanel.position.x
			textAreaPosition.y += parentPanel.position.y
		}
	}

	// Default drawing logic based on shape
	switch textArea.shape {
	case .Rectangle:
		raylib.DrawRectangleV(textAreaPosition, textArea.size, raylib.DARKGRAY)
	case .RoundedRectangle:
		raylib.DrawRectangleRounded(
			raylib.Rectangle {
				x = textAreaPosition.x,
				y = textAreaPosition.y,
				width = textArea.size.x,
				height = textArea.size.y,
			},
			textArea.roundness,
			0, // Segments for rounded corners (0 for auto)
			raylib.GRAY,
		)
	case .Circle:
		radius := f32(textArea.size.x) / 2 // Assuming size.x is diameter
		raylib.DrawCircleV(textAreaPosition, radius, raylib.LIGHTGRAY)
	}

	// Draw each line of text within the text area with proper spacing and scrolling offset
	lineHeight := textArea.fontSize + textArea.fontSpacing
	raylib.BeginScissorMode(
		i32(textAreaPosition.x),
		i32(textAreaPosition.y),
		i32(textArea.size.x),
		i32(textArea.size.y),
	)
	defer raylib.EndScissorMode()
	for line, i in textArea.text {
		linePosition := raylib.Vector2 {
			textAreaPosition.x + textArea.padding, // Add some padding from the left edge
			textAreaPosition.y + textArea.padding + f32(i) * lineHeight - scrollOffset, // Position each line with spacing and apply scroll offset
		}
		raylib.DrawTextEx(
			textArea.font,
			fmt.caprint(line),
			linePosition,
			textArea.fontSize,
			textArea.fontSpacing,
			raylib.WHITE,
		)
	}
}
