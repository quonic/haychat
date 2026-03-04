package widgets

import hm "core:container/handle_map"
import "core:fmt"
import "vendor:raylib"

draw :: proc() {
	topLevelWidgets := getTopLevelWidgets()
	for widget in topLevelWidgets {
		if widget == nil {
			continue
		}
		drawWidget(widget)
		if len(widget.children) > 0 {
			drawChildWidgets(widget.handle)
		}
	}
}

drawWidget :: proc(widget: ^Widget) {
	if widget == nil || !widget.visible {
		return
	}
	anchorWidget(widget)
	switch widget.shape {
	case Shape.Rectangle:
		drawRectangle(widget)
	case Shape.RoundedRectangle:
		drawRoundedRectangle(widget)
	case Shape.Circle:
		drawCircle(widget)
	}
	if widget.text != "" {
		drawText(widget)
	}
}

anchorWidget :: proc(widget: ^Widget) {
	if widget == nil {
		return
	}
	windowWidth := f32(raylib.GetScreenWidth())
	windowHeight := f32(raylib.GetScreenHeight())
	if parentWidget, ok := hm.get(&WidgetMap, widget.parent); !ok || parentWidget == nil {
		switch widget.anchor {
		case .TopLeft:
			widget.rectangle.x = widget.padding
			widget.rectangle.y = widget.padding
		case .TopCenter:
			widget.rectangle.x = (windowWidth - widget.rectangle.width) / 2
			widget.rectangle.y = widget.padding
		case .TopRight:
			widget.rectangle.x = windowWidth - widget.rectangle.width - widget.padding
			widget.rectangle.y = widget.padding
		case .BottomLeft:
			widget.rectangle.x = widget.padding
			widget.rectangle.y = windowHeight - widget.rectangle.height - widget.padding
		case .BottomCenter:
			widget.rectangle.x = (windowWidth - widget.rectangle.width) / 2
			widget.rectangle.y = windowHeight - widget.rectangle.height - widget.padding
		case .BottomRight:
			widget.rectangle.x = windowWidth - widget.rectangle.width - widget.padding
			widget.rectangle.y = windowHeight - widget.rectangle.height - widget.padding
		case .CenterLeft:
			widget.rectangle.x = widget.padding
			widget.rectangle.y = (windowHeight - widget.rectangle.height) / 2
		case .Center:
			widget.rectangle.x = (windowWidth - widget.rectangle.width) / 2
			widget.rectangle.y = (windowHeight - widget.rectangle.height) / 2
		case .CenterRight:
			widget.rectangle.x = windowWidth - widget.rectangle.width - widget.padding
			widget.rectangle.y = (windowHeight - widget.rectangle.height) / 2
		}
	} else {
		switch widget.anchor {
		case .TopLeft:
			widget.rectangle.x = parentWidget.rectangle.x
			widget.rectangle.y = parentWidget.rectangle.y
		case .TopCenter:
			widget.rectangle.x =
				parentWidget.rectangle.x +
				(parentWidget.rectangle.width - widget.rectangle.width) / 2
			widget.rectangle.y = parentWidget.rectangle.y
		case .TopRight:
			widget.rectangle.x =
				parentWidget.rectangle.x + parentWidget.rectangle.width - widget.rectangle.width
			widget.rectangle.y = parentWidget.rectangle.y
		case .BottomLeft:
			widget.rectangle.x = parentWidget.rectangle.x
			widget.rectangle.y =
				parentWidget.rectangle.y + parentWidget.rectangle.height - widget.rectangle.height
		case .BottomCenter:
			widget.rectangle.x =
				parentWidget.rectangle.x +
				(parentWidget.rectangle.width - widget.rectangle.width) / 2
			widget.rectangle.y =
				parentWidget.rectangle.y + parentWidget.rectangle.height - widget.rectangle.height
		case .BottomRight:
			widget.rectangle.x =
				parentWidget.rectangle.x + parentWidget.rectangle.width - widget.rectangle.width
			widget.rectangle.y =
				parentWidget.rectangle.y + parentWidget.rectangle.height - widget.rectangle.height
		case .CenterLeft:
			widget.rectangle.x = parentWidget.rectangle.x
			widget.rectangle.y =
				parentWidget.rectangle.y +
				(parentWidget.rectangle.height - widget.rectangle.height) / 2
		case .Center:
			widget.rectangle.x =
				parentWidget.rectangle.x +
				(parentWidget.rectangle.width - widget.rectangle.width) / 2
			widget.rectangle.y =
				parentWidget.rectangle.y +
				(parentWidget.rectangle.height - widget.rectangle.height) / 2
		case .CenterRight:
			widget.rectangle.x =
				parentWidget.rectangle.x + parentWidget.rectangle.width - widget.rectangle.width
			widget.rectangle.y =
				parentWidget.rectangle.y +
				(parentWidget.rectangle.height - widget.rectangle.height) / 2
		}
	}
}

drawChildWidgets :: proc(parentHandle: Handle) {
	if parent, ok := hm.get(&WidgetMap, parentHandle); ok {
		it := hm.iterator_make(&WidgetMap)
		for widget, handle in hm.iterate(&it) {
			if widget.parent == parent.handle {
				drawWidget(widget)
				if len(widget.children) > 0 {
					drawChildWidgets(widget.handle)
				}
			}
		}
	}
}

drawRectangle :: proc(widget: ^Widget) {
	raylib.DrawRectanglePro(
		widget.rectangle,
		raylib.Vector2{0, 0},
		widget.rotation,
		widget.backgroundColor,
	)

}

drawRoundedRectangle :: proc(widget: ^Widget) {
	raylib.DrawRectangleRounded(widget.rectangle, 0.2, 0, widget.backgroundColor)
}

drawCircle :: proc(widget: ^Widget) {
	center := raylib.Vector2 {
		widget.rectangle.x + widget.rectangle.width / 2,
		widget.rectangle.y + widget.rectangle.height / 2,
	}
	radius := widget.rectangle.width / 2
	raylib.DrawCircleV(center, radius, widget.backgroundColor)
}

drawText :: proc(widget: ^Widget) {
	textSize := raylib.MeasureTextEx(
		WidgetDefaultFont,
		widget.text,
		widget.fontSize,
		widget.fontSpacing,
	)
	textPosition := raylib.Vector2 {
		widget.rectangle.x + (widget.rectangle.width - textSize.x) / 2,
		widget.rectangle.y + (widget.rectangle.height - textSize.y) / 2,
	}
	raylib.DrawTextEx(
		WidgetDefaultFont,
		widget.text,
		textPosition,
		widget.fontSize,
		widget.fontSpacing,
		widget.textColor,
	)

	half_font_size: i32 = i32(widget.fontSize) / 2
	x_offset: i32 = cast(i32)widget.rectangle.x + half_font_size
	y_offset: i32 = cast(i32)widget.rectangle.y + half_font_size

	cursor_x := x_offset + raylib.MeasureText(widget.text, i32(widget.fontSize))
	_, after_cursor := cstringSplitAt(
		widget.text,
		cast(int)widget.cursorPosition,
		context.temp_allocator,
	)
	cursor_x -= raylib.MeasureText(after_cursor, i32(widget.fontSize))
	cursor_y := y_offset

	if widget.cursorBlinkTimer < 0.5 {
		raylib.DrawRectangle(cursor_x, cursor_y, 2, i32(widget.fontSize), raylib.BLACK)
	}
}
