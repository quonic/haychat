#+build linux
package hotkey

// X11: XQueryKeymap reads the server's key state whichever window has focus. libX11 is
// loaded at runtime, so a Wayland-only system never needs it. The monitor opens its own
// display connection, used only on its own thread.

import "core:c"
import "core:dynlib"
import "core:os"
import SDL "vendor:sdl3"

@(private)
X11_LIBRARY :: "libX11.so.6"

// Field names are the C names without the "X" prefix (dynlib.initialize_symbols).
@(private)
X11Symbols :: struct {
	OpenDisplay:     proc "c" (name: cstring) -> rawptr,
	CloseDisplay:    proc "c" (display: rawptr) -> c.int,
	QueryKeymap:     proc "c" (display: rawptr, keys: [^]u8) -> c.int,
	KeysymToKeycode: proc "c" (display: rawptr, keysym: c.ulong) -> u8,
	__handle:        dynlib.Library,
}

@(private)
Poller :: struct {
	x11:     X11Symbols,
	display: rawptr,
}

// An X11 keycode (8..255).
@(private)
NativeKey :: u8

@(private)
platformDefaultBackend :: proc() -> Backend {
	if envIsSet("WAYLAND_DISPLAY") {
		return .Portal
	}
	if envIsSet("DISPLAY") {
		return .X11
	}
	return .None
}

@(private)
envIsSet :: proc(name: string) -> bool {
	value := os.get_env(name, context.temp_allocator)
	return len(value) > 0
}

@(private)
pollerOpen :: proc(poller: ^Poller, monitor: ^Monitor, message: []u8) -> (int, bool) {
	_, loaded := dynlib.initialize_symbols(&poller.x11, X11_LIBRARY, "X")
	if !loaded ||
	   poller.x11.OpenDisplay == nil ||
	   poller.x11.CloseDisplay == nil ||
	   poller.x11.QueryKeymap == nil ||
	   poller.x11.KeysymToKeycode == nil {
		length := len(bprint(message, "%s not found (%s)", X11_LIBRARY, dynlib.last_error()))
		if poller.x11.__handle != nil {
			_ = dynlib.unload_library(poller.x11.__handle)
		}
		poller.x11 = {}
		return length, false
	}
	name: cstring = nil
	nameBuffer: [REPORT_TEXT_BYTES]u8
	if len(monitor.options.display) > 0 {
		name = cstringIn(nameBuffer[:], monitor.options.display)
	}
	poller.display = poller.x11.OpenDisplay(name)
	if poller.display == nil {
		length := len(bprint(message, "cannot open the X display"))
		_ = dynlib.unload_library(poller.x11.__handle)
		poller.x11 = {}
		return length, false
	}
	return 0, true
}

@(private)
pollerClose :: proc(poller: ^Poller) {
	if poller.display != nil {
		_ = poller.x11.CloseDisplay(poller.display)
	}
	if poller.x11.__handle != nil {
		_ = dynlib.unload_library(poller.x11.__handle)
	}
	poller^ = {}
}

@(private)
pollerResolve :: proc(poller: ^Poller, key: SDL.Keycode) -> (NativeKey, bool) {
	first, second := x11Keysyms(key)
	for keysym in ([2]u32{first, second}) {
		if keysym == 0 {
			continue
		}
		if keycode := poller.x11.KeysymToKeycode(poller.display, c.ulong(keysym)); keycode != 0 {
			return keycode, true
		}
	}
	return 0, false
}

@(private)
pollerKeyDown :: proc(poller: ^Poller, key: NativeKey) -> bool {
	// One bit per keycode, keycode 8 * byte + bit.
	keys: [32]u8
	_ = poller.x11.QueryKeymap(poller.display, &keys[0])
	return keys[key / 8] & (1 << (key % 8)) != 0
}
