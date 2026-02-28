package widgets

import hm "core:container/handle_map"

Event :: struct {
	type: EventType,
	data: [dynamic]any,
}

EventType :: enum {
	Click,
	Hover,
	Leave,
	Submit,
}

CurrentWidgetInFocus: Handle

EventHandler :: proc(widget: Handle, event: Event)

ClickEvent :: proc(widget: Handle, event: Event) {
	widget, _ := hm.dynamic_get(&WidgetMap, widget)
	if !widget.enabled {
		return
	}

	CurrentWidgetInFocus = widget.handle

	if widget.buttonType == ButtonType.Toggle {
		widget.toggled = !widget.toggled
	}
	if widget.onClick != nil {
		widget.onClick(widget.handle, event)
	}

	switch widget.type {
	case WidgetType.Button:
	case WidgetType.Panel:
	case WidgetType.Image:
	case WidgetType.Text:
		if widget.isInput {
			widget.isInputFocused = true
		}
	}
}

HoverEvent :: proc(widget: Handle, event: Event) {
	widget, _ := hm.dynamic_get(&WidgetMap, widget)
	if !widget.enabled {
		return
	}
	if widget.onHover != nil {
		widget.onHover(widget.handle, event)
	}
}

LeaveEvent :: proc(widget: Handle, event: Event) {
	widget, _ := hm.dynamic_get(&WidgetMap, widget)
	if !widget.enabled {
		return
	}
	if widget.onLeave != nil {
		widget.onLeave(widget.handle, event)
	}
}

SubmitEvent :: proc(widget: Handle, event: Event) {
	widget, _ := hm.dynamic_get(&WidgetMap, widget)
	if !widget.enabled {
		return
	}
	if widget.onSubmit != nil {
		widget.onSubmit(widget.handle, event)
	}
}
