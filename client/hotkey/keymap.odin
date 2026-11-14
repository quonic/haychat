package hotkey

// SDL keycodes to what each backend needs: a Windows virtual-key code, an X11 keysym, and
// the xkb keysym name the portal takes in a preferred trigger. Pure tables, so they are
// tested on every platform.

import SDL "vendor:sdl3"

// A key that SDL names by scancode (modifiers, F-keys, navigation, keypad).
@(private)
KeyMapping :: struct {
	key:     SDL.Keycode,
	vk:      u8,
	keysym:  u32,
	// A second keysym tried when the first has no keycode (Right Alt is AltGr on many
	// layouts).
	keysym2: u32,
	xkbName: string,
	// A modifier on its own is not a trigger the portal accepts, so none is proposed.
	modifier: bool,
}

@(private)
KEY_MAPPINGS := [?]KeyMapping {
	{key = SDL.K_LCTRL, vk = 0xA2, keysym = 0xffe3, xkbName = "Control_L", modifier = true},
	{key = SDL.K_RCTRL, vk = 0xA3, keysym = 0xffe4, xkbName = "Control_R", modifier = true},
	{key = SDL.K_LSHIFT, vk = 0xA0, keysym = 0xffe1, xkbName = "Shift_L", modifier = true},
	{key = SDL.K_RSHIFT, vk = 0xA1, keysym = 0xffe2, xkbName = "Shift_R", modifier = true},
	{key = SDL.K_LALT, vk = 0xA4, keysym = 0xffe9, xkbName = "Alt_L", modifier = true},
	{
		key = SDL.K_RALT,
		vk = 0xA5,
		keysym = 0xffea,
		keysym2 = 0xfe03,
		xkbName = "Alt_R",
		modifier = true,
	},
	{key = SDL.K_LGUI, vk = 0x5B, keysym = 0xffeb, xkbName = "Super_L", modifier = true},
	{key = SDL.K_RGUI, vk = 0x5C, keysym = 0xffec, xkbName = "Super_R", modifier = true},
	{key = SDL.K_APPLICATION, vk = 0x5D, keysym = 0xff67, xkbName = "Menu"},
	{key = SDL.K_CAPSLOCK, vk = 0x14, keysym = 0xffe5, xkbName = "Caps_Lock"},
	{key = SDL.K_F1, vk = 0x70, keysym = 0xffbe, xkbName = "F1"},
	{key = SDL.K_F2, vk = 0x71, keysym = 0xffbf, xkbName = "F2"},
	{key = SDL.K_F3, vk = 0x72, keysym = 0xffc0, xkbName = "F3"},
	{key = SDL.K_F4, vk = 0x73, keysym = 0xffc1, xkbName = "F4"},
	{key = SDL.K_F5, vk = 0x74, keysym = 0xffc2, xkbName = "F5"},
	{key = SDL.K_F6, vk = 0x75, keysym = 0xffc3, xkbName = "F6"},
	{key = SDL.K_F7, vk = 0x76, keysym = 0xffc4, xkbName = "F7"},
	{key = SDL.K_F8, vk = 0x77, keysym = 0xffc5, xkbName = "F8"},
	{key = SDL.K_F9, vk = 0x78, keysym = 0xffc6, xkbName = "F9"},
	{key = SDL.K_F10, vk = 0x79, keysym = 0xffc7, xkbName = "F10"},
	{key = SDL.K_F11, vk = 0x7A, keysym = 0xffc8, xkbName = "F11"},
	{key = SDL.K_F12, vk = 0x7B, keysym = 0xffc9, xkbName = "F12"},
	{key = SDL.K_F13, vk = 0x7C, keysym = 0xffca, xkbName = "F13"},
	{key = SDL.K_F14, vk = 0x7D, keysym = 0xffcb, xkbName = "F14"},
	{key = SDL.K_F15, vk = 0x7E, keysym = 0xffcc, xkbName = "F15"},
	{key = SDL.K_F16, vk = 0x7F, keysym = 0xffcd, xkbName = "F16"},
	{key = SDL.K_F17, vk = 0x80, keysym = 0xffce, xkbName = "F17"},
	{key = SDL.K_F18, vk = 0x81, keysym = 0xffcf, xkbName = "F18"},
	{key = SDL.K_F19, vk = 0x82, keysym = 0xffd0, xkbName = "F19"},
	{key = SDL.K_F20, vk = 0x83, keysym = 0xffd1, xkbName = "F20"},
	{key = SDL.K_F21, vk = 0x84, keysym = 0xffd2, xkbName = "F21"},
	{key = SDL.K_F22, vk = 0x85, keysym = 0xffd3, xkbName = "F22"},
	{key = SDL.K_F23, vk = 0x86, keysym = 0xffd4, xkbName = "F23"},
	{key = SDL.K_F24, vk = 0x87, keysym = 0xffd5, xkbName = "F24"},
	{key = SDL.K_PRINTSCREEN, vk = 0x2C, keysym = 0xff61, xkbName = "Print"},
	{key = SDL.K_SCROLLLOCK, vk = 0x91, keysym = 0xff14, xkbName = "Scroll_Lock"},
	{key = SDL.K_PAUSE, vk = 0x13, keysym = 0xff13, xkbName = "Pause"},
	{key = SDL.K_INSERT, vk = 0x2D, keysym = 0xff63, xkbName = "Insert"},
	{key = SDL.K_HOME, vk = 0x24, keysym = 0xff50, xkbName = "Home"},
	{key = SDL.K_PAGEUP, vk = 0x21, keysym = 0xff55, xkbName = "Prior"},
	{key = SDL.K_END, vk = 0x23, keysym = 0xff57, xkbName = "End"},
	{key = SDL.K_PAGEDOWN, vk = 0x22, keysym = 0xff56, xkbName = "Next"},
	{key = SDL.K_RIGHT, vk = 0x27, keysym = 0xff53, xkbName = "Right"},
	{key = SDL.K_LEFT, vk = 0x25, keysym = 0xff51, xkbName = "Left"},
	{key = SDL.K_DOWN, vk = 0x28, keysym = 0xff54, xkbName = "Down"},
	{key = SDL.K_UP, vk = 0x26, keysym = 0xff52, xkbName = "Up"},
	{key = SDL.K_NUMLOCKCLEAR, vk = 0x90, keysym = 0xff7f, xkbName = "Num_Lock"},
	{key = SDL.K_KP_DIVIDE, vk = 0x6F, keysym = 0xffaf, xkbName = "KP_Divide"},
	{key = SDL.K_KP_MULTIPLY, vk = 0x6A, keysym = 0xffaa, xkbName = "KP_Multiply"},
	{key = SDL.K_KP_MINUS, vk = 0x6D, keysym = 0xffad, xkbName = "KP_Subtract"},
	{key = SDL.K_KP_PLUS, vk = 0x6B, keysym = 0xffab, xkbName = "KP_Add"},
	// Windows has one virtual key for both Enter keys.
	{key = SDL.K_KP_ENTER, vk = 0x0D, keysym = 0xff8d, xkbName = "KP_Enter"},
	{key = SDL.K_KP_0, vk = 0x60, keysym = 0xffb0, xkbName = "KP_0"},
	{key = SDL.K_KP_1, vk = 0x61, keysym = 0xffb1, xkbName = "KP_1"},
	{key = SDL.K_KP_2, vk = 0x62, keysym = 0xffb2, xkbName = "KP_2"},
	{key = SDL.K_KP_3, vk = 0x63, keysym = 0xffb3, xkbName = "KP_3"},
	{key = SDL.K_KP_4, vk = 0x64, keysym = 0xffb4, xkbName = "KP_4"},
	{key = SDL.K_KP_5, vk = 0x65, keysym = 0xffb5, xkbName = "KP_5"},
	{key = SDL.K_KP_6, vk = 0x66, keysym = 0xffb6, xkbName = "KP_6"},
	{key = SDL.K_KP_7, vk = 0x67, keysym = 0xffb7, xkbName = "KP_7"},
	{key = SDL.K_KP_8, vk = 0x68, keysym = 0xffb8, xkbName = "KP_8"},
	{key = SDL.K_KP_9, vk = 0x69, keysym = 0xffb9, xkbName = "KP_9"},
	{key = SDL.K_KP_PERIOD, vk = 0x6E, keysym = 0xffae, xkbName = "KP_Decimal"},
}

// Character keys that are not letters or digits: their US-layout virtual key (used only when
// the active Windows layout cannot place the character) and their xkb name.
@(private)
PunctuationMapping :: struct {
	character: rune,
	vk:        u8,
	xkbName:   string,
}

@(private)
PUNCTUATION_MAPPINGS := [?]PunctuationMapping {
	{' ', 0x20, "space"},
	{';', 0xBA, "semicolon"},
	{'=', 0xBB, "equal"},
	{',', 0xBC, "comma"},
	{'-', 0xBD, "minus"},
	{'.', 0xBE, "period"},
	{'/', 0xBF, "slash"},
	{'`', 0xC0, "grave"},
	{'[', 0xDB, "bracketleft"},
	{'\\', 0xDC, "backslash"},
	{']', 0xDD, "bracketright"},
	{'\'', 0xDE, "apostrophe"},
}

// The SDL keycodes of the control characters SDL gives their own keycodes.
@(private)
CONTROL_MAPPINGS := [?]KeyMapping {
	{key = SDL.K_RETURN, vk = 0x0D, keysym = 0xff0d, xkbName = "Return"},
	{key = SDL.K_TAB, vk = 0x09, keysym = 0xff09, xkbName = "Tab"},
	{key = SDL.K_BACKSPACE, vk = 0x08, keysym = 0xff08, xkbName = "BackSpace"},
	{key = SDL.K_ESCAPE, vk = 0x1B, keysym = 0xff1b, xkbName = "Escape"},
	{key = SDL.K_DELETE, vk = 0x2E, keysym = 0xffff, xkbName = "Delete"},
}

@(private)
keyIsCharacter :: proc(key: SDL.Keycode) -> bool {
	return key != SDL.K_UNKNOWN && key & SDL.K_SCANCODE_MASK == 0
}

@(private)
findMapping :: proc(key: SDL.Keycode) -> (KeyMapping, bool) {
	for mapping in KEY_MAPPINGS {
		if mapping.key == key {
			return mapping, true
		}
	}
	for mapping in CONTROL_MAPPINGS {
		if mapping.key == key {
			return mapping, true
		}
	}
	return {}, false
}

@(private)
findPunctuation :: proc(character: rune) -> (PunctuationMapping, bool) {
	for mapping in PUNCTUATION_MAPPINGS {
		if mapping.character == character {
			return mapping, true
		}
	}
	return {}, false
}

// The Windows virtual key for key. layoutNeeded says the key is a character other than a
// letter or digit, whose virtual key depends on the keyboard layout: the Windows backend
// asks VkKeyScanW first and uses vk (the US layout's) only when that fails.
windowsVirtualKey :: proc(key: SDL.Keycode) -> (vk: u8, layoutNeeded: bool, ok: bool) {
	if mapping, found := findMapping(key); found {
		return mapping.vk, false, true
	}
	if !keyIsCharacter(key) {
		return 0, false, false
	}
	character := rune(key)
	switch character {
	case 'a' ..= 'z':
		return u8(character - 'a' + 'A'), false, true
	case '0' ..= '9':
		return u8(character), false, true
	case ' ':
		return 0x20, false, true
	}
	if mapping, found := findPunctuation(character); found {
		return mapping.vk, true, true
	}
	return 0, true, character < 0x10000
}

// The X11 keysyms for key, most likely first; 0 means none.
x11Keysyms :: proc(key: SDL.Keycode) -> (first, second: u32) {
	if mapping, found := findMapping(key); found {
		return mapping.keysym, mapping.keysym2
	}
	if !keyIsCharacter(key) {
		return 0, 0
	}
	character := u32(key)
	switch {
	case character >= 0x20 && character <= 0x7e, character >= 0xa0 && character <= 0xff:
		return character, 0
	case character > 0xff && character <= 0x10ffff:
		// X11 keysyms for Unicode characters outside Latin-1.
		return 0x01000000 | character, 0
	}
	return 0, 0
}

// The trigger proposed to the portal for key, in the XDG shortcuts format (an xkb keysym
// name). Empty for a modifier on its own or a key without a known name: the desktop's dialog
// then asks the user for one.
portalPreferredTrigger :: proc(key: SDL.Keycode) -> string {
	if mapping, found := findMapping(key); found {
		return mapping.modifier ? "" : mapping.xkbName
	}
	if !keyIsCharacter(key) {
		return ""
	}
	character := rune(key)
	switch character {
	case 'a' ..= 'z', '0' ..= '9':
		return SINGLE_CHARACTER_NAMES[character]
	}
	if mapping, found := findPunctuation(character); found {
		return mapping.xkbName
	}
	return ""
}

// Static strings for the letter and digit keysym names (an xkb name is the character).
@(private)
SINGLE_CHARACTER_NAMES := #partial [128]string {
	'a' = "a",
	'b' = "b",
	'c' = "c",
	'd' = "d",
	'e' = "e",
	'f' = "f",
	'g' = "g",
	'h' = "h",
	'i' = "i",
	'j' = "j",
	'k' = "k",
	'l' = "l",
	'm' = "m",
	'n' = "n",
	'o' = "o",
	'p' = "p",
	'q' = "q",
	'r' = "r",
	's' = "s",
	't' = "t",
	'u' = "u",
	'v' = "v",
	'w' = "w",
	'x' = "x",
	'y' = "y",
	'z' = "z",
	'0' = "0",
	'1' = "1",
	'2' = "2",
	'3' = "3",
	'4' = "4",
	'5' = "5",
	'6' = "6",
	'7' = "7",
	'8' = "8",
	'9' = "9",
}
