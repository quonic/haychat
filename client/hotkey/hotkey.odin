package hotkey

// Global push-to-talk (issue 45): follows one key while another window has focus. A Monitor
// runs one backend on its own thread:
//
//   - Windows: GetAsyncKeyState polling (hotkey_windows.odin)
//   - X11:     XQueryKeymap polling, libX11 loaded at runtime (x11_linux.odin)
//   - Portal:  the XDG GlobalShortcuts portal over D-Bus, libdbus-1 loaded at runtime
//              (portal_linux.odin); the desktop owns the trigger, the user picks it there
//
// The polling backends read only the state of the one configured key, and only while the
// monitor is armed. The portal backend sets nothing up, and shows no desktop dialog, before
// the first arm. Like client/opus this package must not import HayChat types, and nothing
// in it may stop the client from starting: every system library is loaded with core:dynlib.

import "base:runtime"
import "core:fmt"
import "core:sync"
import "core:thread"
import "core:time"
import SDL "vendor:sdl3"

Backend :: enum u8 {
	None, // no global hotkey on this system
	Windows,
	X11,
	Portal,
}

Status :: enum u8 {
	Idle, // not armed yet, or the backend is None
	Starting, // the portal session is being set up or waits for the desktop's dialog
	Active,
	KeyUnsupported, // the configured key has no mapping on this backend
	Unavailable, // the backend cannot run here; StatusReport.message says why
}

// How often a polling backend reads the key while armed.
POLL_INTERVAL :: 10 * time.Millisecond
// How long the worker sleeps between checks while it is not armed or has nothing to do. A
// change of armed, key or stop wakes it at once.
IDLE_WAIT :: 100 * time.Millisecond
REPORT_TEXT_BYTES :: 256

// What the monitor last reported, copied out by report(). Text lives in fixed buffers.
StatusReport :: struct {
	backend:       Backend,
	status:        Status,
	messageBuffer: [REPORT_TEXT_BYTES]u8,
	messageLength: int,
	// Portal: the trigger the desktop assigned (its trigger_description), "" while unknown.
	triggerBuffer: [REPORT_TEXT_BYTES]u8,
	triggerLength: int,
	// Portal version 2 or later: requestConfigure opens the desktop's shortcut dialog.
	canConfigure:  bool,
}

StatusReport_message :: proc(report: ^StatusReport) -> string {
	return string(report.messageBuffer[:report.messageLength])
}

StatusReport_trigger :: proc(report: ^StatusReport) -> string {
	return string(report.triggerBuffer[:report.triggerLength])
}

// Called on the monitor's thread whenever held() changes or the status report changes.
ChangeProc :: #type proc(userdata: rawptr)

Options :: struct {
	// Portal: connect to this D-Bus address instead of the session bus (tests).
	busAddress: string,
	// X11: open this display instead of $DISPLAY (tests).
	display:    string,
}

Monitor :: struct {
	backend:          Backend,
	options:          Options, // strings owned
	onChange:         ChangeProc,
	userdata:         rawptr,
	worker:           ^thread.Thread,
	wake:             sync.Sema,
	// Written by the owner, read by the worker (atomics).
	stopping:         bool,
	armed:            bool,
	key:              SDL.Keycode,
	configureWanted:  bool,
	// Written by the worker (atomic).
	held:             bool,
	reportMutex:      sync.Mutex,
	report:           StatusReport,
}

// The backend for this system. Linux picks the portal on a Wayland session (an X11 client
// sees the keyboard there only while an X11 window has focus) and X11 when only DISPLAY is
// set.
defaultBackend :: proc() -> Backend {
	return platformDefaultBackend()
}

// Starts a monitor on its own thread. It reports Idle and touches no system library until
// it is armed. onChange may be nil.
create :: proc(
	backend: Backend,
	onChange: ChangeProc,
	userdata: rawptr,
	options := Options{},
) -> ^Monitor {
	monitor := new(Monitor)
	monitor.backend = backend
	monitor.onChange = onChange
	monitor.userdata = userdata
	monitor.options.busAddress = cloneString(options.busAddress)
	monitor.options.display = cloneString(options.display)
	monitor.report.backend = backend
	if backend == .None {
		return monitor
	}
	monitor.worker = thread.create_and_start_with_data(monitor, monitorRun, context)
	return monitor
}

// Stops the worker (releasing the key) and frees the monitor.
destroy :: proc(monitor: ^Monitor) {
	if monitor == nil {
		return
	}
	if monitor.worker != nil {
		sync.atomic_store(&monitor.stopping, true)
		sync.sema_post(&monitor.wake)
		thread.join(monitor.worker)
		thread.destroy(monitor.worker)
	}
	delete(monitor.options.busAddress)
	delete(monitor.options.display)
	free(monitor)
}

// Armed: follow the key. Disarmed: report it released and stop reading it.
setArmed :: proc(monitor: ^Monitor, armed: bool) {
	if monitor == nil || sync.atomic_exchange(&monitor.armed, armed) == armed {
		return
	}
	sync.sema_post(&monitor.wake)
}

// The SDL keycode to follow. The portal uses it only as the preferred trigger of its first
// bind; after that the desktop's shortcut settings decide.
setKey :: proc(monitor: ^Monitor, key: SDL.Keycode) {
	if monitor == nil || sync.atomic_exchange(&monitor.key, key) == key {
		return
	}
	sync.sema_post(&monitor.wake)
}

// Whether the key is held. Always false while disarmed.
held :: proc(monitor: ^Monitor) -> bool {
	return monitor != nil && sync.atomic_load(&monitor.held)
}

report :: proc(monitor: ^Monitor) -> (copied: StatusReport) {
	if monitor == nil {
		return
	}
	sync.mutex_lock(&monitor.reportMutex)
	copied = monitor.report
	sync.mutex_unlock(&monitor.reportMutex)
	return
}

// Portal version 2: asks the desktop to show its dialog for changing the shortcut.
requestConfigure :: proc(monitor: ^Monitor) {
	if monitor == nil {
		return
	}
	sync.atomic_store(&monitor.configureWanted, true)
	sync.sema_post(&monitor.wake)
}

// ── Worker side ───────────────────────────────────────────────────

// The thread inherits the creator's context, whose temp allocator is the creator thread's
// arena. core:dynlib converts names with the temp allocator, so the worker gets an arena of
// its own (backed by the creator's allocator, so leak checks see it) for its whole life.
@(private)
withOwnTempAllocator :: proc(body: proc(data: rawptr), data: rawptr) {
	temp: runtime.Default_Temp_Allocator
	runtime.default_temp_allocator_init(&temp, 4096, context.allocator)
	defer runtime.default_temp_allocator_destroy(&temp)
	context.temp_allocator = runtime.default_temp_allocator(&temp)
	body(data)
}

@(private)
monitorRun :: proc(data: rawptr) {
	withOwnTempAllocator(monitorRunBackend, data)
}

@(private)
monitorRunBackend :: proc(data: rawptr) {
	monitor := (^Monitor)(data)
	switch monitor.backend {
	case .None:
	case .Windows, .X11:
		pollingRun(monitor)
	case .Portal:
		portalRun(monitor)
	}
	setHeld(monitor, false)
}

@(private)
isStopping :: proc(monitor: ^Monitor) -> bool {
	return sync.atomic_load(&monitor.stopping)
}

@(private)
isArmed :: proc(monitor: ^Monitor) -> bool {
	return sync.atomic_load(&monitor.armed)
}

// Sleeps up to duration, or until the owner changes armed, the key, or asks to stop.
@(private)
waitForOwner :: proc(monitor: ^Monitor, duration: time.Duration) {
	_ = sync.sema_wait_with_timeout(&monitor.wake, duration)
}

@(private)
notify :: proc(monitor: ^Monitor) {
	if monitor.onChange != nil {
		monitor.onChange(monitor.userdata)
	}
}

@(private)
setHeld :: proc(monitor: ^Monitor, held: bool) {
	if sync.atomic_exchange(&monitor.held, held) != held {
		notify(monitor)
	}
}

// Replaces the status and its message (formatted); keeps the trigger.
@(private)
setStatus :: proc(monitor: ^Monitor, status: Status, format := "", args: ..any) {
	buffer: [REPORT_TEXT_BYTES]u8
	text := fmt.bprintf(buffer[:], format, ..args) if len(format) > 0 else ""
	sync.mutex_lock(&monitor.reportMutex)
	changed :=
		monitor.report.status != status ||
		StatusReport_message(&monitor.report) != text
	if changed {
		monitor.report.status = status
		monitor.report.messageLength = copy(monitor.report.messageBuffer[:], text)
	}
	sync.mutex_unlock(&monitor.reportMutex)
	if changed {
		notify(monitor)
	}
}

@(private)
setTrigger :: proc(monitor: ^Monitor, trigger: string, canConfigure: bool) {
	sync.mutex_lock(&monitor.reportMutex)
	changed :=
		StatusReport_trigger(&monitor.report) != trigger ||
		monitor.report.canConfigure != canConfigure
	if changed {
		monitor.report.triggerLength = copy(monitor.report.triggerBuffer[:], trigger)
		monitor.report.canConfigure = canConfigure
	}
	sync.mutex_unlock(&monitor.reportMutex)
	if changed {
		notify(monitor)
	}
}

@(private)
cloneString :: proc(text: string) -> string {
	if len(text) == 0 {
		return ""
	}
	bytes := make([]u8, len(text))
	copy(bytes, text)
	return string(bytes)
}

// The shared loop of the Windows and X11 backends: open on the first arm, resolve the key
// whenever it changes, and read it every POLL_INTERVAL while armed.
@(private)
pollingRun :: proc(monitor: ^Monitor) {
	poller: Poller
	opened, failed := false, false
	defer if opened {
		pollerClose(&poller)
	}
	resolvedKey := SDL.Keycode(0)
	native: NativeKey
	supported := false
	for !isStopping(monitor) {
		if !isArmed(monitor) || failed {
			setHeld(monitor, false)
			if !failed {
				setStatus(monitor, .Idle)
			}
			waitForOwner(monitor, IDLE_WAIT)
			continue
		}
		if !opened {
			message: [REPORT_TEXT_BYTES]u8
			if length, ok := pollerOpen(&poller, monitor, message[:]); !ok {
				failed = true
				setStatus(monitor, .Unavailable, "%s", string(message[:length]))
				continue
			}
			opened = true
			resolvedKey = 0
			supported = false
		}
		key := sync.atomic_load(&monitor.key)
		if key != resolvedKey || monitor.report.status == .Idle {
			resolvedKey = key
			setHeld(monitor, false)
			native, supported = pollerResolve(&poller, key)
			setStatus(monitor, supported ? .Active : .KeyUnsupported)
		}
		if supported {
			setHeld(monitor, pollerKeyDown(&poller, native))
		}
		waitForOwner(monitor, POLL_INTERVAL)
	}
}

// fmt.bprintf into buffer, truncated to fit.
@(private)
bprint :: proc(buffer: []u8, format: string, args: ..any) -> string {
	return fmt.bprintf(buffer, format, ..args)
}

// Copies text into buffer with a terminating NUL (truncating it to fit) and returns it as a
// C string borrowing buffer.
@(private)
cstringIn :: proc(buffer: []u8, text: string) -> cstring {
	if len(buffer) == 0 {
		return nil
	}
	length := copy(buffer[:len(buffer) - 1], text)
	buffer[length] = 0
	return cstring(raw_data(buffer))
}

// The length of the NUL-terminated text at the start of buffer.
@(private)
cstringLength :: proc(buffer: []u8) -> int {
	for value, index in buffer {
		if value == 0 {
			return index
		}
	}
	return len(buffer)
}
