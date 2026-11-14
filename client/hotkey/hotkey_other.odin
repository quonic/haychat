#+build !windows
#+build !linux
package hotkey

// No global hotkey backend on this platform: every monitor reports Unavailable.

import SDL "vendor:sdl3"

@(private)
Poller :: struct {}

@(private)
NativeKey :: int

@(private)
platformDefaultBackend :: proc() -> Backend {
	return .None
}

@(private)
pollerOpen :: proc(poller: ^Poller, monitor: ^Monitor, message: []u8) -> (int, bool) {
	return len(bprint(message, "no global hotkey support on this platform")), false
}

@(private)
pollerClose :: proc(poller: ^Poller) {}

@(private)
pollerResolve :: proc(poller: ^Poller, key: SDL.Keycode) -> (NativeKey, bool) {
	return 0, false
}

@(private)
pollerKeyDown :: proc(poller: ^Poller, key: NativeKey) -> bool {
	return false
}

@(private)
portalRun :: proc(monitor: ^Monitor) {
	setStatus(monitor, .Unavailable, "the GlobalShortcuts portal exists only on Linux")
}
