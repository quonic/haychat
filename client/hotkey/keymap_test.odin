package hotkey

import "core:fmt"
import "core:testing"
import "core:time"
import SDL "vendor:sdl3"

@(test)
testWindowsVirtualKeysForModifiersLettersAndPunctuation :: proc(t: ^testing.T) {
	vk, layoutNeeded, ok := windowsVirtualKey(SDL.K_LCTRL)
	assert(
		ok && vk == 0xA2 && !layoutNeeded,
		fmt.tprintf("Left Ctrl: want VK_LCONTROL, got %x", vk),
	)
	vk, layoutNeeded, ok = windowsVirtualKey(SDL.K_F13)
	assert(ok && vk == 0x7C, fmt.tprintf("F13: want VK_F13, got %x", vk))
	vk, layoutNeeded, ok = windowsVirtualKey(SDL.Keycode('v'))
	assert(ok && vk == 'V' && !layoutNeeded, fmt.tprintf("v: want 'V', got %x", vk))
	vk, layoutNeeded, ok = windowsVirtualKey(SDL.Keycode('7'))
	assert(ok && vk == '7' && !layoutNeeded, fmt.tprintf("7: want '7', got %x", vk))
	vk, layoutNeeded, ok = windowsVirtualKey(SDL.Keycode(','))
	assert(ok && vk == 0xBC && layoutNeeded, "comma: want VK_OEM_COMMA with a layout lookup")
	vk, layoutNeeded, ok = windowsVirtualKey(SDL.K_SPACE)
	assert(ok && vk == 0x20 && !layoutNeeded, "Space: want VK_SPACE")
	_, _, ok = windowsVirtualKey(SDL.K_MUTE)
	assert(!ok, "an unmapped scancode key must be unsupported")
}

@(test)
testX11KeysymsForModifiersAndCharacters :: proc(t: ^testing.T) {
	first, second := x11Keysyms(SDL.K_LCTRL)
	assert(first == 0xffe3 && second == 0, fmt.tprintf("Left Ctrl: want Control_L, got %x", first))
	first, second = x11Keysyms(SDL.K_RALT)
	assert(
		first == 0xffea && second == 0xfe03,
		"Right Alt: want Alt_R, then ISO_Level3_Shift for AltGr layouts",
	)
	first, _ = x11Keysyms(SDL.Keycode('a'))
	assert(first == 'a', fmt.tprintf("a: want keysym 0x61, got %x", first))
	first, _ = x11Keysyms(SDL.Keycode(0xe9))
	assert(first == 0xe9, "é: Latin-1 keysyms equal the code point")
	first, _ = x11Keysyms(SDL.Keycode(0x20ac))
	assert(first == 0x010020ac, fmt.tprintf("€: want a Unicode keysym, got %x", first))
	first, _ = x11Keysyms(SDL.K_RETURN)
	assert(first == 0xff0d, "Return: want the Return keysym, not the control character")
	first, _ = x11Keysyms(SDL.K_MUTE)
	assert(first == 0, "an unmapped scancode key has no keysym")
}

@(test)
testPortalPreferredTriggers :: proc(t: ^testing.T) {
	assert(portalPreferredTrigger(SDL.K_LCTRL) == "", "a modifier alone is not proposed")
	assert(portalPreferredTrigger(SDL.K_F13) == "F13", "F13 is proposed as F13")
	assert(portalPreferredTrigger(SDL.Keycode('v')) == "v", "v is proposed as v")
	assert(portalPreferredTrigger(SDL.Keycode(',')) == "comma", "comma has its xkb name")
	assert(portalPreferredTrigger(SDL.K_SPACE) == "space", "Space has its xkb name")
	assert(portalPreferredTrigger(SDL.K_KP_ENTER) == "KP_Enter", "keypad Enter has its xkb name")
	assert(portalPreferredTrigger(SDL.K_MUTE) == "", "an unmapped key is not proposed")
}

@(test)
testMonitorWithoutABackendStaysIdleAndReleased :: proc(t: ^testing.T) {
	monitor := create(.None, nil, nil)
	defer destroy(monitor)
	setKey(monitor, SDL.K_LCTRL)
	setArmed(monitor, true)
	time.sleep(20 * time.Millisecond)
	snapshot := report(monitor)
	assert(snapshot.backend == .None, "backend None is reported")
	assert(snapshot.status == .Idle, fmt.tprintf("want Idle, got %v", snapshot.status))
	assert(!held(monitor), "nothing is ever held without a backend")
	// Every entry point accepts nil, so the client can call them before a monitor exists.
	setArmed(nil, true)
	setKey(nil, SDL.K_F1)
	requestConfigure(nil)
	assert(!held(nil), "a nil monitor is never held")
	destroy(nil)
}
