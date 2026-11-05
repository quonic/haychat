package ui

Color :: [4]u8

rgb :: proc(hex: u32) -> Color {
	return Color{u8(hex >> 16), u8(hex >> 8), u8(hex), 255}
}

rgba :: proc(hex: u32) -> Color {
	return Color{u8(hex >> 24), u8(hex >> 16), u8(hex >> 8), u8(hex)}
}

FontID :: enum u8 {
	Regular,
	Bold,
}

// Sizes are in logical points; the context scales them by the window's display scale.
Theme :: struct {
	bg:           Color,
	surface:      Color,
	elevated:     Color,
	hover:        Color,
	pressed:      Color,
	selected:     Color,
	border:       Color,
	fg:           Color,
	fgMuted:      Color,
	primary:      Color,
	onPrimary:    Color,
	selection:    Color,
	danger:       Color,
	warning:      Color,
	success:      Color,
	scrollbar:    Color,
	fontSize:     f32,
	padding:      f32,
	spacing:      f32,
	scrollbarW:   f32,
	cornerRadius: f32,
}

themeDark :: proc() -> Theme {
	return Theme {
		bg = rgb(0x0f1115),
		surface = rgb(0x17191e),
		elevated = rgb(0x21242b),
		hover = rgb(0x262a32),
		pressed = rgb(0x2e323a),
		selected = rgb(0x1f3354),
		border = rgb(0x2e323a),
		fg = rgb(0xe6edf3),
		fgMuted = rgb(0x8b95a3),
		primary = rgb(0x3b82f6),
		onPrimary = rgb(0xffffff),
		selection = rgba(0x3b82f659),
		danger = rgb(0xe5484d),
		warning = rgb(0xd29922),
		success = rgb(0x3fb950),
		scrollbar = rgba(0x8b95a366),
		fontSize = 15,
		padding = 8,
		spacing = 2,
		scrollbarW = 6,
		cornerRadius = 4,
	}
}
