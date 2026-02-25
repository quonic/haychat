package widgets


import "core:fmt"
import "core:strings"
import "vendor:raylib"

panelContainerRect :: proc(panel: ^Panel) -> raylib.Rectangle {
	if panel.parent != 0 {
		parentPanel := findPanelByID(panel.parent)
		if parentPanel != nil {
			return raylib.Rectangle {
				x = parentPanel.resolvedPosition.x,
				y = parentPanel.resolvedPosition.y,
				width = parentPanel.resolvedSize.x,
				height = parentPanel.resolvedSize.y,
			}
		}
	}

	return raylib.Rectangle {
		x = 0,
		y = 0,
		width = f32(raylib.GetScreenWidth()),
		height = f32(raylib.GetScreenHeight()),
	}
}

resolvePanelLayout :: proc(panel: ^Panel) {
	container := panelContainerRect(panel)
	resolvedPosition := panel.position
	resolvedSize := panel.size

	switch panel.anchor {
	case .TopLeft:
		resolvedPosition.x = container.x + panel.position.x
		resolvedPosition.y = container.y + panel.position.y
	case .Top:
		resolvedPosition.x = container.x + (container.width - panel.size.x) / 2 + panel.position.x
		resolvedPosition.y = container.y + panel.position.y
		if panel.sideMode == .Stretch {
			resolvedPosition.x = container.x + panel.position.x
			resolvedSize.x = container.width - panel.position.x * 2
		}
	case .TopRight:
		resolvedPosition.x = container.x + container.width - panel.size.x - panel.position.x
		resolvedPosition.y = container.y + panel.position.y
	case .Right:
		resolvedPosition.x = container.x + container.width - panel.size.x - panel.position.x
		resolvedPosition.y = container.y + (container.height - panel.size.y) / 2 + panel.position.y
		if panel.sideMode == .Stretch {
			resolvedPosition.y = container.y + panel.position.y
			resolvedSize.y = container.height - panel.position.y * 2
		}
	case .BottomRight:
		resolvedPosition.x = container.x + container.width - panel.size.x - panel.position.x
		resolvedPosition.y = container.y + container.height - panel.size.y - panel.position.y
	case .Bottom:
		resolvedPosition.x = container.x + (container.width - panel.size.x) / 2 + panel.position.x
		resolvedPosition.y = container.y + container.height - panel.size.y - panel.position.y
		if panel.sideMode == .Stretch {
			resolvedPosition.x = container.x + panel.position.x
			resolvedSize.x = container.width - panel.position.x * 2
		}
	case .BottomLeft:
		resolvedPosition.x = container.x + panel.position.x
		resolvedPosition.y = container.y + container.height - panel.size.y - panel.position.y
	case .Left:
		resolvedPosition.x = container.x + panel.position.x
		resolvedPosition.y = container.y + (container.height - panel.size.y) / 2 + panel.position.y
		if panel.sideMode == .Stretch {
			resolvedPosition.y = container.y + panel.position.y
			resolvedSize.y = container.height - panel.position.y * 2
		}
	}

	if resolvedSize.x < 0 {
		resolvedSize.x = 0
	}
	if resolvedSize.y < 0 {
		resolvedSize.y = 0
	}

	panel.resolvedPosition = resolvedPosition
	panel.resolvedSize = resolvedSize
}

PanelChildLayoutMetrics :: struct {
	position: raylib.Vector2,
	size:     raylib.Vector2,
}

panelChildPositionAndSize :: proc(child: Widget) -> (raylib.Vector2, raylib.Vector2) {
	switch c in child {
	case Button:
		return c.position, c.size
	case Image:
		return c.position, c.size
	case Label:
		return c.position, c.size
	case Panel:
		return c.position, c.size
	case TextEntryField:
		return c.position, c.size
	case TextArea:
		return c.position, c.size
	case:
	}

	return {}, {}
}

resolvePanelChildLayout :: proc(
	panel: ^Panel,
	child: Widget,
	flowOffset: ^f32,
) -> PanelChildLayoutMetrics {
	position, size := panelChildPositionAndSize(child)

	switch panel.childrenLayout {
	case .None:
	case .Vertical:
		position = {0, flowOffset^}
		size.x = panel.resolvedSize.x
		flowOffset^ += size.y + panel.childSpacing
	case .Horizontal:
		position = {flowOffset^, 0}
		size.y = panel.resolvedSize.y
		flowOffset^ += size.x + panel.childSpacing
	}

	return PanelChildLayoutMetrics{position = position, size = size}
}

panelChildrenContentBoundsY :: proc(panel: ^Panel) -> (f32, f32) {
	minContentY := f32(0)
	maxContentY := f32(0)
	flowOffset := f32(0)

	for &child in panel.children {
		layoutMetrics := resolvePanelChildLayout(panel, child, &flowOffset)
		if layoutMetrics.position.y < minContentY {
			minContentY = layoutMetrics.position.y
		}
		bottom := layoutMetrics.position.y + layoutMetrics.size.y
		if bottom > maxContentY {
			maxContentY = bottom
		}
	}

	return minContentY, maxContentY
}

drawImage :: proc(image: ^Image) {
	if image.draw != nil {
		image.draw()
		return
	}

	imagePosition := image.position
	if image.parent != 0 {
		parentPanel := findPanelByID(image.parent)
		if parentPanel != nil {
			imagePosition.x += parentPanel.resolvedPosition.x
			imagePosition.y += parentPanel.resolvedPosition.y
		}
	}

	sourceRect := image.sourceRect
	if sourceRect.width == 0 || sourceRect.height == 0 {
		sourceRect = raylib.Rectangle {
			x      = 0,
			y      = 0,
			width  = f32(image.texture.width),
			height = f32(image.texture.height),
		}
	}

	destinationRect := raylib.Rectangle {
		x      = imagePosition.x,
		y      = imagePosition.y,
		width  = image.size.x,
		height = image.size.y,
	}

	raylib.DrawTexturePro(
		image.texture,
		sourceRect,
		destinationRect,
		raylib.Vector2{},
		0,
		raylib.WHITE,
	)
}

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
			buttonPosition.x += parentPanel.resolvedPosition.x
			buttonPosition.y += parentPanel.resolvedPosition.y
		}
	}

	// Default drawing logic based on shape
	switch button.shape {
	case .Rectangle:
		raylib.DrawRectangleV(buttonPosition, button.size, button.color)
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
			button.color,
		)
	case .Circle:
		radius := f32(button.size.x) / 2 // Assuming size.x is diameter
		raylib.DrawCircleV(buttonPosition, radius, button.color)
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
		button.textColor,
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
			labelPosition.x += parentPanel.resolvedPosition.x
			labelPosition.y += parentPanel.resolvedPosition.y
		}
	}

	// Default drawing logic based on shape
	switch label.shape {
	case .Rectangle:
		raylib.DrawRectangleV(labelPosition, label.size, label.color)
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
			label.color,
		)
	case .Circle:
		radius := f32(label.size.x) / 2 // Assuming size.x is diameter
		raylib.DrawCircleV(labelPosition, radius, label.color)
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
		label.textColor,
	)
}

drawPanel :: proc(panel: ^Panel) {
	// Call the custom draw function if it exists
	if panel.draw != nil {
		panel.draw()
		return
	}

	resolvePanelLayout(panel)

	// If no font is set, use the default font
	if panel.font == {} {
		panel.font = WidgetDefaultFont
	}
	if panel.scrollTopPadding <= 0 && panel.title != "" {
		panel.scrollTopPadding = panelTitleScrollTopPadding(panel)
	}

	panelPosition := panel.resolvedPosition
	panelSize := panel.resolvedSize

	// Default drawing logic based on shape
	switch panel.shape {
	case .Rectangle:
		raylib.DrawRectangleV(panelPosition, panelSize, panel.color)
	case .RoundedRectangle:
		raylib.DrawRectangleRounded(
			raylib.Rectangle {
				x = panelPosition.x,
				y = panelPosition.y,
				width = panelSize.x,
				height = panelSize.y,
			},
			panel.roundness,
			0, // Segments for rounded corners (0 for auto)
			panel.color,
		)
	case .Circle:
		radius := f32(panelSize.x) / 2 // Assuming size.x is diameter
		raylib.DrawCircleV(panelPosition, radius, panel.color)
	}

	minContentY, maxContentY := panelChildrenContentBoundsY(panel)

	visibleTopPadding := panel.scrollTopPadding
	visibleHeight := panelSize.y - visibleTopPadding
	if visibleHeight < 0 {
		visibleHeight = 0
	}
	contentHeight := maxContentY - minContentY
	if contentHeight > visibleHeight {
		minScrollOffset := minContentY - visibleTopPadding
		maxScrollOffset := maxContentY - panelSize.y
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
			panelPosition.x + (panelSize.x - textSize.x) / 2,
			panelPosition.y + panel.fontSize / 2, // Position at the top with some padding
		}
		raylib.DrawTextEx(
			panel.font,
			fmt.caprint(panel.title),
			textPosition,
			panel.fontSize,
			panel.fontSpacing,
			panel.textColor,
		)
	}

	// Draw child widgets contained within the panel
	scissorY := panelPosition.y + visibleTopPadding
	scissorHeight := panelSize.y - visibleTopPadding
	if scissorHeight < 0 {
		scissorHeight = 0
	}
	raylib.BeginScissorMode(
		i32(panelPosition.x),
		i32(scissorY),
		i32(panelSize.x),
		i32(scissorHeight),
	)
	defer raylib.EndScissorMode()
	applyScroll := panel.scrollOffset != 0
	layoutFlowOffset := f32(0)
	for &child in panel.children {
		layoutMetrics := resolvePanelChildLayout(panel, child, &layoutFlowOffset)
		switch c in child {
		case Button:
			button := &child.(Button)
			originalPosition := button.position
			originalSize := button.size
			if panel.childrenLayout != .None {
				button.position = layoutMetrics.position
				button.size = layoutMetrics.size
			}
			if applyScroll {
				button.position.y -= panel.scrollOffset
			}
			drawButton(button)
			button.position = originalPosition
			button.size = originalSize
		case Image:
			image := &child.(Image)
			originalPosition := image.position
			originalSize := image.size
			if panel.childrenLayout != .None {
				image.position = layoutMetrics.position
				image.size = layoutMetrics.size
			}
			if applyScroll {
				image.position.y -= panel.scrollOffset
			}
			drawImage(image)
			image.position = originalPosition
			image.size = originalSize
		case Label:
			label := &child.(Label)
			originalPosition := label.position
			originalSize := label.size
			if panel.childrenLayout != .None {
				label.position = layoutMetrics.position
				label.size = layoutMetrics.size
			}
			if applyScroll {
				label.position.y -= panel.scrollOffset
			}
			drawLabel(label)
			label.position = originalPosition
			label.size = originalSize
		case Panel:
			childPanel := &child.(Panel)
			originalPosition := childPanel.position
			originalSize := childPanel.size
			if panel.childrenLayout != .None {
				childPanel.position = layoutMetrics.position
				childPanel.size = layoutMetrics.size
			}
			if applyScroll {
				childPanel.position.y -= panel.scrollOffset
			}
			drawPanel(childPanel)
			childPanel.position = originalPosition
			childPanel.size = originalSize
		case TextEntryField:
			entryField := &child.(TextEntryField)
			originalPosition := entryField.position
			originalSize := entryField.size
			if panel.childrenLayout != .None {
				entryField.position = layoutMetrics.position
				entryField.size = layoutMetrics.size
			}
			if applyScroll {
				entryField.position.y -= panel.scrollOffset
			}
			drawTextEntryField(entryField)
			entryField.position = originalPosition
			entryField.size = originalSize
		case TextArea:
			textArea := &child.(TextArea)
			originalPosition := textArea.position
			originalSize := textArea.size
			if panel.childrenLayout != .None {
				textArea.position = layoutMetrics.position
				textArea.size = layoutMetrics.size
			}
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
			textArea.position = originalPosition
			textArea.size = originalSize
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
			textEntryFieldPosition.x += parentPanel.resolvedPosition.x
			textEntryFieldPosition.y += parentPanel.resolvedPosition.y
		}
	}

	// Default drawing logic based on shape
	switch textEntryField.shape {
	case .Rectangle:
		raylib.DrawRectangleV(textEntryFieldPosition, textEntryField.size, textEntryField.color)
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
			textEntryField.color,
		)
	case .Circle:
		radius := f32(textEntryField.size.x) / 2 // Assuming size.x is diameter
		raylib.DrawCircleV(textEntryFieldPosition, radius, textEntryField.color)
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
		textEntryField.textColor,
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
			textAreaPosition.x += parentPanel.resolvedPosition.x
			textAreaPosition.y += parentPanel.resolvedPosition.y
		}
	}

	// Default drawing logic based on shape
	switch textArea.shape {
	case .Rectangle:
		raylib.DrawRectangleV(textAreaPosition, textArea.size, textArea.color)
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
			textArea.color,
		)
	case .Circle:
		radius := f32(textArea.size.x) / 2 // Assuming size.x is diameter
		raylib.DrawCircleV(textAreaPosition, radius, textArea.color)
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
			textArea.textColor,
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
			textAreaPosition.x += parentPanel.resolvedPosition.x
			textAreaPosition.y += parentPanel.resolvedPosition.y
		}
	}

	// Default drawing logic based on shape
	switch textArea.shape {
	case .Rectangle:
		raylib.DrawRectangleV(textAreaPosition, textArea.size, textArea.color)
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
			textArea.color,
		)
	case .Circle:
		radius := f32(textArea.size.x) / 2 // Assuming size.x is diameter
		raylib.DrawCircleV(textAreaPosition, radius, textArea.color)
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
			textArea.textColor,
		)
	}
}
