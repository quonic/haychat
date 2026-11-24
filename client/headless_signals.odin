package client

// SIGTERM and SIGINT in the headless harness (#36). With SDL audio open, SDL used to install
// its own handlers, which turn either signal into an SDL quit event that the harness loop never
// reads, so the process kept running. The harness now installs its own handlers before
// anything else (SDL keeps a handler it did not install, and SDL_HINT_NO_SIGNAL_HANDLERS tells
// it not to try): a signal only sets a flag, and the command loop, `wait`, `sleep` and the
// startup connect wait stop on it, so the harness leaves voice, closes the session and frees
// everything as on `quit`, and exits with code 0.

import "base:intrinsics"
import "core:c/libc"
import SDL "vendor:sdl3"

// The signal that asked the harness to stop, or 0.
@(private = "file")
headlessStopSignal: libc.sig_atomic_t

@(private = "file")
headlessStopSignalHandler :: proc "c" (sig: libc.int) {
	intrinsics.atomic_store(&headlessStopSignal, libc.sig_atomic_t(sig))
}

HeadlessSignalHandlers :: struct {
	term:      proc "c" (_: libc.int),
	interrupt: proc "c" (_: libc.int),
}

// Installs the harness's SIGTERM and SIGINT handlers and returns the ones they replaced (for
// tests, which put the test runner's back).
headlessSignalsInstall :: proc() -> (previous: HeadlessSignalHandlers) {
	previous.term = libc.signal(libc.SIGTERM, headlessStopSignalHandler)
	previous.interrupt = libc.signal(libc.SIGINT, headlessStopSignalHandler)
	return
}

headlessSignalsRestore :: proc(previous: HeadlessSignalHandlers) {
	_ = libc.signal(libc.SIGTERM, previous.term)
	_ = libc.signal(libc.SIGINT, previous.interrupt)
}

// For headlessMain: the handlers, and SDL told to leave signals alone.
headlessSignalsSetUp :: proc() {
	_ = SDL.SetHint(SDL.HINT_NO_SIGNAL_HANDLERS, "1")
	_ = headlessSignalsInstall()
}

// The signal that asked the harness to stop (SIGTERM or SIGINT), or 0 while none has.
headlessStopRequested :: proc() -> int {
	return int(intrinsics.atomic_load(&headlessStopSignal))
}

// The signal that asked this harness to stop, or 0: the process's request, while the harness
// watches signals (headlessMain), or what a test set.
headlessHarnessStopSignal :: proc(harness: ^HeadlessHarness) -> int {
	if harness.stopSignal == 0 && harness.watchSignals {
		harness.stopSignal = headlessStopRequested()
	}
	return harness.stopSignal
}

// Forgets a stop request (tests only).
headlessStopRequestClear :: proc() {
	intrinsics.atomic_store(&headlessStopSignal, 0)
}

headlessSignalName :: proc(sig: int) -> string {
	switch sig {
	case libc.SIGTERM:
		return "SIGTERM"
	case libc.SIGINT:
		return "SIGINT"
	}
	return "a signal"
}
