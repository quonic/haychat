package widgets

import hm "core:container/handle_map"
import "vendor:raylib"

draw :: proc() {
	topLevelWidgets := getTopLevelWidgets()
	for widget in topLevelWidgets {
		drawWidget(widget)
		if len(widget.children) > 0 {
			drawChildWidgets(widget.handle)
		}
	}
}

drawWidget :: proc(widget: ^Widget) {
	switch widget.shape {
	case Shape.Rectangle:
		drawRectangle(widget)
	case Shape.RoundedRectangle:
		drawRoundedRectangle(widget)
	case Shape.Circle:
		drawCircle(widget)
	}
}

drawChildWidgets :: proc(parentHandle: Handle) {
	it := hm.iterator_make(&WidgetMap)
	for widget, handle in hm.iterate(&it) {
		if widget.parent == parentHandle {
			drawWidget(widget)
			if len(widget.children) > 0 {
				drawChildWidgets(widget.handle)
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
