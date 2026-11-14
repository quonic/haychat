#+build windows
package hotkey

// Windows: GetAsyncKeyState reads the physical state of one virtual key whichever window
// has focus. No hook is installed, so no keystroke passes through HayChat; only the one
// configured key is read, every POLL_INTERVAL while armed.

import win32 "core:sys/windows"
import SDL "vendor:sdl3"

foreign import user32 "system:User32.lib"

@(default_calling_convention = "system")
foreign user32 {
	// The virtual key in the low byte and the shift state in the high byte, or -1.
	VkKeyScanW :: proc(ch: win32.WCHAR) -> win32.SHORT ---
}

@(private)
Poller :: struct {}

@(private)
NativeKey :: win32.INT

@(private)
platformDefaultBackend :: proc() -> Backend {
	return .Windows
}

@(private)
pollerOpen :: proc(poller: ^Poller, monitor: ^Monitor, message: []u8) -> (int, bool) {
	return 0, true
}

@(private)
pollerClose :: proc(poller: ^Poller) {}

@(private)
pollerResolve :: proc(poller: ^Poller, key: SDL.Keycode) -> (NativeKey, bool) {
	vk, layoutNeeded, ok := windowsVirtualKey(key)
	if !ok {
		return 0, false
	}
	if layoutNeeded {
		// The active layout places the character; the shift state in the high byte is
		// ignored, since push-to-talk follows the key itself.
		scan := VkKeyScanW(win32.WCHAR(rune(key)))
		if scan != -1 && scan & 0xff != 0xff {
			return NativeKey(scan & 0xff), true
		}
	}
	return NativeKey(vk), vk != 0
}

@(private)
pollerKeyDown :: proc(poller: ^Poller, key: NativeKey) -> bool {
	// The most significant bit is set while the key is down.
	return u16(win32.GetAsyncKeyState(key)) & 0x8000 != 0
}

@(private)
portalRun :: proc(monitor: ^Monitor) {
	setStatus(monitor, .Unavailable, "the GlobalShortcuts portal exists only on Linux")
}
