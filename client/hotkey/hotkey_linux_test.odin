#+build linux
package hotkey

// The Linux backends against real servers: the X11 poller on an Xvfb display, with XTest
// pressing the key, and the portal client against a mock GlobalShortcuts portal served on a
// private dbus-daemon. Without Xvfb, libXtst or dbus-daemon the tests are skipped with a
// warning, unless HAYCHAT_REQUIRE_HOTKEY_TESTS=1 (check.sh sets it) makes that a failure.

import "core:c"
import "core:dynlib"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import SDL "vendor:sdl3"

HOTKEY_TEST_REQUIRE_ENV :: "HAYCHAT_REQUIRE_HOTKEY_TESTS"
HOTKEY_TEST_WAIT :: 3 * time.Second

@(private = "file")
hotkeyTestPrerequisite :: proc(t: ^testing.T, available: bool, what: string) -> bool {
	if available {
		return true
	}
	if os.get_env(HOTKEY_TEST_REQUIRE_ENV, context.temp_allocator) == "1" {
		testing.fail_now(t, fmt.tprintf("%s is required (%s=1)", what, HOTKEY_TEST_REQUIRE_ENV))
	}
	log.warnf(
		"skipped: %s is not available (set %s=1 to require it)",
		what,
		HOTKEY_TEST_REQUIRE_ENV,
	)
	return false
}

// Polls condition every 5 ms until it holds or HOTKEY_TEST_WAIT passes.
@(private = "file")
waitUntil :: proc(condition: proc(data: rawptr) -> bool, data: rawptr) -> bool {
	deadline := time.tick_now()
	for time.tick_since(deadline) < HOTKEY_TEST_WAIT {
		if condition(data) {
			return true
		}
		time.sleep(5 * time.Millisecond)
	}
	return condition(data)
}

@(private = "file")
monitorIsHeld :: proc(data: rawptr) -> bool {
	return held((^Monitor)(data))
}

@(private = "file")
monitorIsReleased :: proc(data: rawptr) -> bool {
	return !held((^Monitor)(data))
}

@(private = "file")
monitorIsActive :: proc(data: rawptr) -> bool {
	return report((^Monitor)(data)).status == .Active
}

@(private = "file")
monitorIsSettled :: proc(data: rawptr) -> bool {
	status := report((^Monitor)(data)).status
	return status == .Active || status == .Unavailable || status == .KeyUnsupported
}

@(private = "file")
ChangeCounter :: struct {
	count: int,
}

@(private = "file")
countChange :: proc(userdata: rawptr) {
	counter := (^ChangeCounter)(userdata)
	sync.atomic_add(&counter.count, 1)
}

@(private = "file")
startProcess :: proc(command: []string) -> (os.Process, bool) {
	process, err := os.process_start({command = command})
	return process, err == nil
}

@(private = "file")
stopProcess :: proc(process: os.Process) {
	_ = os.process_kill(process)
	_, _ = os.process_wait(process)
}

// ── X11 ───────────────────────────────────────────────────────────

@(private = "file")
XTestSymbols :: struct {
	TestFakeKeyEvent: proc "c" (
		display: rawptr,
		keycode: c.uint,
		isPress: b32,
		delay: c.ulong,
	) -> c.int,
	__handle:         dynlib.Library,
}

@(private = "file")
XLibSymbols :: struct {
	OpenDisplay:     proc "c" (name: cstring) -> rawptr,
	CloseDisplay:    proc "c" (display: rawptr) -> c.int,
	KeysymToKeycode: proc "c" (display: rawptr, keysym: c.ulong) -> u8,
	Flush:           proc "c" (display: rawptr) -> c.int,
	__handle:        dynlib.Library,
}

@(test)
testX11PollerFollowsTheConfiguredKeyOnXvfb :: proc(t: ^testing.T) {
	xvfbFound := os.exists("/usr/bin/Xvfb")
	xlib: XLibSymbols
	xtest: XTestSymbols
	_, xlibOK := dynlib.initialize_symbols(&xlib, "libX11.so.6", "X")
	_, xtestOK := dynlib.initialize_symbols(&xtest, "libXtst.so.6", "X")
	defer if xlib.__handle != nil {
		_ = dynlib.unload_library(xlib.__handle)
	}
	defer if xtest.__handle != nil {
		_ = dynlib.unload_library(xtest.__handle)
	}
	if !hotkeyTestPrerequisite(t, xvfbFound && xlibOK && xtestOK, "Xvfb with libX11 and libXtst") {
		return
	}

	// A display number no other test run is using.
	displayNumber := 0
	for number in 91 ..< 140 {
		if !os.exists(fmt.tprintf("/tmp/.X%d-lock", number)) &&
		   !os.exists(fmt.tprintf("/tmp/.X11-unix/X%d", number)) {
			displayNumber = number
			break
		}
	}
	assert(displayNumber != 0, "no free X display number between :91 and :139")
	displayName := fmt.tprintf(":%d", displayNumber)
	xvfb, started := startProcess({"/usr/bin/Xvfb", displayName, "-nolisten", "tcp", "-noreset"})
	assert(started, "Xvfb did not start")
	defer stopProcess(xvfb)

	displayC := strings.clone_to_cstring(displayName, context.temp_allocator)
	display: rawptr
	start := time.tick_now()
	for display == nil && time.tick_since(start) < HOTKEY_TEST_WAIT {
		display = xlib.OpenDisplay(displayC)
		if display == nil {
			time.sleep(20 * time.Millisecond)
		}
	}
	assert(display != nil, fmt.tprintf("cannot open Xvfb display %s", displayName))
	defer _ = xlib.CloseDisplay(display)
	controlL := u32(xlib.KeysymToKeycode(display, 0xffe3))
	assert(controlL != 0, "Xvfb's keymap has no Control_L")

	counter: ChangeCounter
	monitor := create(.X11, countChange, &counter, {display = displayName})
	defer destroy(monitor)
	setKey(monitor, SDL.K_LCTRL)
	time.sleep(30 * time.Millisecond)
	assert(report(monitor).status == .Idle, "the poller opens nothing before it is armed")

	setArmed(monitor, true)
	assert(waitUntil(monitorIsActive, monitor), fmt.tprintf("want Active, got %v", report(monitor)))
	assert(!held(monitor), "Left Ctrl is not held yet")

	_ = xtest.TestFakeKeyEvent(display, c.uint(controlL), true, 0)
	_ = xlib.Flush(display)
	assert(waitUntil(monitorIsHeld, monitor), "pressing Left Ctrl on the display must hold it")
	_ = xtest.TestFakeKeyEvent(display, c.uint(controlL), false, 0)
	_ = xlib.Flush(display)
	assert(waitUntil(monitorIsReleased, monitor), "releasing Left Ctrl must release it")

	// Disarming while the key is down releases at once.
	_ = xtest.TestFakeKeyEvent(display, c.uint(controlL), true, 0)
	_ = xlib.Flush(display)
	assert(waitUntil(monitorIsHeld, monitor), "Left Ctrl held again")
	setArmed(monitor, false)
	assert(waitUntil(monitorIsReleased, monitor), "disarming must release a held key")
	_ = xtest.TestFakeKeyEvent(display, c.uint(controlL), false, 0)
	_ = xlib.Flush(display)

	// Another key is followed after the change, and a key the keymap lacks is unsupported.
	setArmed(monitor, true)
	setKey(monitor, SDL.K_F24)
	time.sleep(50 * time.Millisecond)
	assert(waitUntil(monitorIsSettled, monitor), "the poller settles on the new key")
	setKey(monitor, SDL.K_MUTE)
	time.sleep(50 * time.Millisecond)
	assert(
		report(monitor).status == .KeyUnsupported,
		fmt.tprintf("an unmapped key: want KeyUnsupported, got %v", report(monitor).status),
	)
	assert(sync.atomic_load(&counter.count) > 0, "changes are reported through onChange")
}

@(test)
testX11PollerReportsAMissingDisplay :: proc(t: ^testing.T) {
	monitor := create(.X11, nil, nil, {display = ":139.7"})
	defer destroy(monitor)
	setKey(monitor, SDL.K_LCTRL)
	setArmed(monitor, true)
	assert(waitUntil(monitorIsSettled, monitor), "the poller gives up on a display it cannot open")
	snapshot := report(monitor)
	assert(
		snapshot.status == .Unavailable,
		fmt.tprintf("want Unavailable, got %v", snapshot.status),
	)
	assert(len(StatusReport_message(&snapshot)) > 0, "Unavailable carries a reason")
}

// ── Mock GlobalShortcuts portal ───────────────────────────────────

@(private = "file")
MOCK_SESSION_PATH :: "/org/freedesktop/portal/desktop/session/1_1/haychat"
@(private = "file")
MOCK_TRIGGER :: "Ctrl+Space"

@(private = "file")
MockEmit :: enum i32 {
	None,
	Activate,
	Deactivate,
	ActivateOtherShortcut,
	ShortcutsChanged,
}

@(private = "file")
MockPortal :: struct {
	dbus:             DBusSymbols,
	connection:       ^DBusConnection,
	worker:           ^thread.Thread,
	stopping:         bool,
	// Behaviour, set before the monitor arms.
	version:          u32, // 0: the GlobalShortcuts interface is missing
	bindResponse:     u32, // 0 success, 1 cancelled
	// Commands from the test (atomic).
	emit:             MockEmit,
	// What the client did (mutex).
	mutex:            sync.Mutex,
	registeredAppID:  [128]u8,
	createCalls:      int,
	bindCalls:        int,
	configureCalls:   int,
	closeCalls:       int,
	preferredTrigger: [128]u8,
	client:           [128]u8,
	requestCounter:   int,
}

@(private = "file")
mockText :: proc(buffer: []u8) -> string {
	return string(buffer[:cstringLength(buffer)])
}

@(private = "file")
mockRecord :: proc(mock: ^MockPortal, field: ^int) {
	sync.mutex_lock(&mock.mutex)
	field^ += 1
	sync.mutex_unlock(&mock.mutex)
}

@(private = "file")
mockCount :: proc(mock: ^MockPortal, field: ^int) -> int {
	sync.mutex_lock(&mock.mutex)
	defer sync.mutex_unlock(&mock.mutex)
	return field^
}

// A Response signal (u code, a{sv} results) on path, sent only to the caller.
@(private = "file")
mockRespond :: proc(
	mock: ^MockPortal,
	call: ^DBusMessage,
	path: string,
	code: u32,
	writeResults: proc(writer: ^DBusWriter),
) {
	dbus := &mock.dbus
	reply := dbus.message_new_method_return(call)
	writer := dbusWriter(dbus, reply)
	DBusWriter_string(&writer, path, .ObjectPath)
	_ = dbus.connection_send(mock.connection, reply, nil)
	dbus.message_unref(reply)

	pathBuffer: [256]u8
	signal := dbus.message_new_signal(
		cstringIn(pathBuffer[:], path),
		PORTAL_REQUEST,
		"Response",
	)
	_ = dbus.message_set_destination(signal, dbus.message_get_sender(call))
	writer = dbusWriter(dbus, signal)
	DBusWriter_u32(&writer, code)
	DBusWriter_open(&writer, .Array, "{sv}")
	if code == 0 {
		writeResults(&writer)
	}
	DBusWriter_close(&writer)
	_ = dbus.connection_send(mock.connection, signal, nil)
	dbus.message_unref(signal)
}

@(private = "file")
mockWriteSession :: proc(writer: ^DBusWriter) {
	DBusWriter_entryString(writer, "session_handle", MOCK_SESSION_PATH, .ObjectPath)
}

@(private = "file")
mockWriteShortcutList :: proc(writer: ^DBusWriter) {
	DBusWriter_open(writer, .Array, "(sa{sv})")
	DBusWriter_open(writer, .Struct)
	DBusWriter_string(writer, PORTAL_SHORTCUT_ID)
	DBusWriter_open(writer, .Array, "{sv}")
	DBusWriter_entryString(writer, "trigger_description", MOCK_TRIGGER)
	DBusWriter_close(writer)
	DBusWriter_close(writer)
	DBusWriter_close(writer)
}

@(private = "file")
mockWriteShortcuts :: proc(writer: ^DBusWriter) {
	DBusWriter_open(writer, .DictEntry)
	DBusWriter_string(writer, "shortcuts")
	DBusWriter_open(writer, .Variant, "a(sa{sv})")
	mockWriteShortcutList(writer)
	DBusWriter_close(writer)
	DBusWriter_close(writer)
}

@(private = "file")
mockReplyEmpty :: proc(mock: ^MockPortal, call: ^DBusMessage) {
	reply := mock.dbus.message_new_method_return(call)
	_ = mock.dbus.connection_send(mock.connection, reply, nil)
	mock.dbus.message_unref(reply)
}

@(private = "file")
mockHandleCall :: proc(mock: ^MockPortal, call: ^DBusMessage) {
	dbus := &mock.dbus
	iface := string(dbus.message_get_interface(call))
	member := string(dbus.message_get_member(call))
	sync.mutex_lock(&mock.mutex)
	_ = cstringIn(mock.client[:], string(dbus.message_get_sender(call)))
	sync.mutex_unlock(&mock.mutex)
	args: DBusMessageIter
	hasArgs := dbus.message_iter_init(call, &args)
	switch {
	case iface == PORTAL_REGISTRY && member == "Register":
		if hasArgs {
			appID, _ := dbusReadString(dbus, &args)
			sync.mutex_lock(&mock.mutex)
			_ = cstringIn(mock.registeredAppID[:], appID)
			sync.mutex_unlock(&mock.mutex)
		}
		mockReplyEmpty(mock, call)
	case iface == DBUS_PROPERTIES && member == "Get":
		if mock.version == 0 {
			reply := dbus.message_new_error(
				call,
				"org.freedesktop.DBus.Error.UnknownInterface",
				"No such interface",
			)
			_ = dbus.connection_send(mock.connection, reply, nil)
			dbus.message_unref(reply)
			return
		}
		reply := dbus.message_new_method_return(call)
		writer := dbusWriter(dbus, reply)
		DBusWriter_open(&writer, .Variant, "u")
		DBusWriter_u32(&writer, mock.version)
		DBusWriter_close(&writer)
		_ = dbus.connection_send(mock.connection, reply, nil)
		dbus.message_unref(reply)
	case iface == PORTAL_SHORTCUTS && member == "CreateSession":
		mockRecord(mock, &mock.createCalls)
		mock.requestCounter += 1
		path := fmt.tprintf("/org/freedesktop/portal/desktop/request/1_1/r%d", mock.requestCounter)
		mockRespond(mock, call, path, 0, mockWriteSession)
	case iface == PORTAL_SHORTCUTS && member == "BindShortcuts":
		mockRecord(mock, &mock.bindCalls)
		// (o session, a(sa{sv}) shortcuts, ...): note the proposed trigger.
		if hasArgs && dbus.message_iter_next(&args) {
			list, item: DBusMessageIter
			dbus.message_iter_recurse(&args, &list)
			dbus.message_iter_recurse(&list, &item)
			value: DBusMessageIter
			if dbus.message_iter_next(&item) &&
			   dbusFindEntry(dbus, &item, "preferred_trigger", &value) {
				trigger, _ := dbusReadString(dbus, &value)
				sync.mutex_lock(&mock.mutex)
				_ = cstringIn(mock.preferredTrigger[:], trigger)
				sync.mutex_unlock(&mock.mutex)
			}
		}
		mock.requestCounter += 1
		path := fmt.tprintf("/org/freedesktop/portal/desktop/request/1_1/r%d", mock.requestCounter)
		mockRespond(mock, call, path, mock.bindResponse, mockWriteShortcuts)
	case iface == PORTAL_SHORTCUTS && member == "ConfigureShortcuts":
		mockRecord(mock, &mock.configureCalls)
		mockReplyEmpty(mock, call)
	case iface == PORTAL_SESSION && member == "Close":
		mockRecord(mock, &mock.closeCalls)
		mockReplyEmpty(mock, call)
	case:
		mockReplyEmpty(mock, call)
	}
}

@(private = "file")
mockEmitSignal :: proc(mock: ^MockPortal, emit: MockEmit) {
	dbus := &mock.dbus
	member: cstring
	shortcut := PORTAL_SHORTCUT_ID
	#partial switch emit {
	case .Activate:
		member = "Activated"
	case .Deactivate:
		member = "Deactivated"
	case .ActivateOtherShortcut:
		member = "Activated"
		shortcut = "something-else"
	case .ShortcutsChanged:
		member = "ShortcutsChanged"
	case:
		return
	}
	signal := dbus.message_new_signal(PORTAL_OBJECT_PATH, PORTAL_SHORTCUTS, member)
	sync.mutex_lock(&mock.mutex)
	clientBuffer := mock.client
	sync.mutex_unlock(&mock.mutex)
	_ = dbus.message_set_destination(signal, cstring(raw_data(clientBuffer[:])))
	writer := dbusWriter(dbus, signal)
	DBusWriter_string(&writer, MOCK_SESSION_PATH, .ObjectPath)
	if emit == .ShortcutsChanged {
		mockWriteShortcutList(&writer)
	} else {
		DBusWriter_string(&writer, shortcut)
		DBusWriter_u64(&writer, 1234)
		DBusWriter_open(&writer, .Array, "{sv}")
		DBusWriter_close(&writer)
	}
	_ = dbus.connection_send(mock.connection, signal, nil)
	dbus.connection_flush(mock.connection)
	dbus.message_unref(signal)
}

@(private = "file")
mockRun :: proc(data: rawptr) {
	// Its own temp arena: the inherited one belongs to the test's thread.
	withOwnTempAllocator(mockServe, data)
}

@(private = "file")
mockServe :: proc(data: rawptr) {
	mock := (^MockPortal)(data)
	dbus := &mock.dbus
	for !sync.atomic_load(&mock.stopping) {
		if !dbus.connection_read_write(mock.connection, 10) {
			return
		}
		for {
			message := dbus.connection_pop_message(mock.connection)
			if message == nil {
				break
			}
			if dbus.message_get_type(message) == DBUS_MESSAGE_TYPE_METHOD_CALL {
				mockHandleCall(mock, message)
			}
			dbus.message_unref(message)
		}
		if emit := MockEmit(sync.atomic_exchange((^i32)(&mock.emit), 0)); emit != .None {
			mockEmitSignal(mock, emit)
		}
		dbus.connection_flush(mock.connection)
		free_all(context.temp_allocator)
	}
}

@(private = "file")
mockEmitAndWait :: proc(mock: ^MockPortal, emit: MockEmit) {
	sync.atomic_store((^i32)(&mock.emit), i32(emit))
	start := time.tick_now()
	for sync.atomic_load((^i32)(&mock.emit)) != 0 && time.tick_since(start) < HOTKEY_TEST_WAIT {
		time.sleep(2 * time.Millisecond)
	}
}

// A private dbus-daemon and a mock portal on it. ok is false when dbus-daemon or libdbus is
// missing.
@(private = "file")
MockBus :: struct {
	daemon:  os.Process,
	address: string,
	socket:  string,
	mock:    MockPortal,
}

@(private = "file")
mockBusStart :: proc(t: ^testing.T, bus: ^MockBus, version, bindResponse: u32) -> bool {
	message: [REPORT_TEXT_BYTES]u8
	daemonFound := os.exists("/usr/bin/dbus-daemon")
	_, loaded := dbusLoad(&bus.mock.dbus, message[:])
	if !hotkeyTestPrerequisite(t, daemonFound && loaded, "dbus-daemon with libdbus-1") {
		dbusUnload(&bus.mock.dbus)
		return false
	}
	@(static) busCounter: int
	index := sync.atomic_add(&busCounter, 1)
	bus.socket = fmt.aprintf("/tmp/haychat-hotkey-test-%d-%d.bus", os.get_pid(), index)
	bus.address = fmt.aprintf("unix:path=%s", bus.socket)
	started: bool
	bus.daemon, started = startProcess(
		{"/usr/bin/dbus-daemon", "--session", "--nofork", fmt.tprintf("--address=%s", bus.address)},
	)
	assert(started, "dbus-daemon did not start")

	dbus := &bus.mock.dbus
	addressC := strings.clone_to_cstring(bus.address, context.temp_allocator)
	start := time.tick_now()
	for bus.mock.connection == nil && time.tick_since(start) < HOTKEY_TEST_WAIT {
		error: DBusError
		dbus.error_init(&error)
		connection := dbus.connection_open_private(addressC, &error)
		if connection != nil && dbus.bus_register(connection, &error) {
			bus.mock.connection = connection
		} else if connection != nil {
			dbus.connection_close(connection)
			dbus.connection_unref(connection)
		}
		dbus.error_free(&error)
		if bus.mock.connection == nil {
			time.sleep(20 * time.Millisecond)
		}
	}
	assert(bus.mock.connection != nil, "cannot connect to the private dbus-daemon")
	dbus.connection_set_exit_on_disconnect(bus.mock.connection, false)
	error: DBusError
	dbus.error_init(&error)
	_ = dbus.bus_request_name(
		bus.mock.connection,
		PORTAL_BUS_NAME,
		DBUS_NAME_FLAG_DO_NOT_QUEUE,
		&error,
	)
	assert(!dbus.error_is_set(&error), "the mock cannot own the portal's bus name")
	dbus.error_free(&error)
	bus.mock.version = version
	bus.mock.bindResponse = bindResponse
	bus.mock.worker = thread.create_and_start_with_data(&bus.mock, mockRun, context)
	return true
}

@(private = "file")
mockBusStop :: proc(bus: ^MockBus) {
	if bus.mock.worker != nil {
		sync.atomic_store(&bus.mock.stopping, true)
		thread.join(bus.mock.worker)
		thread.destroy(bus.mock.worker)
	}
	if bus.mock.connection != nil {
		bus.mock.dbus.connection_close(bus.mock.connection)
		bus.mock.dbus.connection_unref(bus.mock.connection)
	}
	dbusUnload(&bus.mock.dbus)
	if bus.daemon != {} {
		stopProcess(bus.daemon)
	}
	if len(bus.socket) > 0 {
		_ = os.remove(bus.socket)
	}
	delete(bus.socket)
	delete(bus.address)
}

@(private = "file")
mockCreateCalled :: proc(data: rawptr) -> bool {
	mock := (^MockPortal)(data)
	return mockCount(mock, &mock.createCalls) > 0
}

@(private = "file")
mockConfigureCalled :: proc(data: rawptr) -> bool {
	mock := (^MockPortal)(data)
	return mockCount(mock, &mock.configureCalls) > 0
}

@(private = "file")
mockCloseCalled :: proc(data: rawptr) -> bool {
	mock := (^MockPortal)(data)
	return mockCount(mock, &mock.closeCalls) > 0
}

@(test)
testPortalBindsOnFirstArmAndFollowsActivations :: proc(t: ^testing.T) {
	bus: MockBus
	if !mockBusStart(t, &bus, 2, 0) {
		return
	}
	defer mockBusStop(&bus)

	monitor := create(.Portal, nil, nil, {busAddress = bus.address})
	setKey(monitor, SDL.K_F13)
	time.sleep(50 * time.Millisecond)
	assert(
		mockCount(&bus.mock, &bus.mock.createCalls) == 0,
		"no portal session (and no desktop dialog) before the first arm",
	)
	assert(report(monitor).status == .Idle, "Idle until armed")

	setArmed(monitor, true)
	assert(waitUntil(monitorIsSettled, monitor), "the portal session settles")
	snapshot := report(monitor)
	assert(
		snapshot.status == .Active,
		fmt.tprintf("want Active, got %v (%s)", snapshot.status, StatusReport_message(&snapshot)),
	)
	assert(
		StatusReport_trigger(&snapshot) == MOCK_TRIGGER,
		fmt.tprintf("want the desktop's trigger, got %q", StatusReport_trigger(&snapshot)),
	)
	assert(snapshot.canConfigure, "portal version 2 can open the shortcut dialog")
	sync.mutex_lock(&bus.mock.mutex)
	appID := strings.clone(mockText(bus.mock.registeredAppID[:]), context.temp_allocator)
	trigger := strings.clone(mockText(bus.mock.preferredTrigger[:]), context.temp_allocator)
	sync.mutex_unlock(&bus.mock.mutex)
	assert(appID == PORTAL_APP_ID, fmt.tprintf("want the app ID registered, got %q", appID))
	assert(trigger == "F13", fmt.tprintf("want F13 proposed, got %q", trigger))

	mockEmitAndWait(&bus.mock, .Activate)
	assert(waitUntil(monitorIsHeld, monitor), "Activated holds the key")
	mockEmitAndWait(&bus.mock, .Deactivate)
	assert(waitUntil(monitorIsReleased, monitor), "Deactivated releases it")

	mockEmitAndWait(&bus.mock, .ActivateOtherShortcut)
	time.sleep(50 * time.Millisecond)
	assert(!held(monitor), "another shortcut's activation is ignored")

	mockEmitAndWait(&bus.mock, .Activate)
	assert(waitUntil(monitorIsHeld, monitor), "held again")
	setArmed(monitor, false)
	assert(waitUntil(monitorIsReleased, monitor), "disarming releases at once")
	mockEmitAndWait(&bus.mock, .Activate)
	time.sleep(50 * time.Millisecond)
	assert(!held(monitor), "activations are ignored while disarmed")
	setArmed(monitor, true)
	assert(mockCount(&bus.mock, &bus.mock.bindCalls) == 1, "re-arming binds nothing new")

	requestConfigure(monitor)
	assert(waitUntil(mockConfigureCalled, &bus.mock), "requestConfigure opens the dialog")

	destroy(monitor)
	assert(waitUntil(mockCloseCalled, &bus.mock), "destroy closes the portal session")
}

@(test)
testPortalReportsACancelledBind :: proc(t: ^testing.T) {
	bus: MockBus
	if !mockBusStart(t, &bus, 1, 1) {
		return
	}
	defer mockBusStop(&bus)
	monitor := create(.Portal, nil, nil, {busAddress = bus.address})
	defer destroy(monitor)
	setKey(monitor, SDL.K_LCTRL)
	setArmed(monitor, true)
	assert(waitUntil(monitorIsSettled, monitor), "the portal session settles")
	snapshot := report(monitor)
	assert(
		snapshot.status == .Unavailable,
		fmt.tprintf("want Unavailable, got %v", snapshot.status),
	)
	assert(
		strings.contains(StatusReport_message(&snapshot), "cancelled"),
		fmt.tprintf("want the cancel in the reason, got %q", StatusReport_message(&snapshot)),
	)
	sync.mutex_lock(&bus.mock.mutex)
	trigger := strings.clone(mockText(bus.mock.preferredTrigger[:]), context.temp_allocator)
	sync.mutex_unlock(&bus.mock.mutex)
	assert(trigger == "", "a modifier alone is not proposed as the trigger")
}

@(test)
testPortalReportsAMissingGlobalShortcutsInterface :: proc(t: ^testing.T) {
	bus: MockBus
	if !mockBusStart(t, &bus, 0, 0) {
		return
	}
	defer mockBusStop(&bus)
	monitor := create(.Portal, nil, nil, {busAddress = bus.address})
	defer destroy(monitor)
	setKey(monitor, SDL.K_F13)
	setArmed(monitor, true)
	assert(waitUntil(monitorIsSettled, monitor), "the portal client gives up")
	snapshot := report(monitor)
	assert(
		snapshot.status == .Unavailable,
		fmt.tprintf("want Unavailable, got %v", snapshot.status),
	)
	assert(
		strings.contains(StatusReport_message(&snapshot), "no GlobalShortcuts portal"),
		fmt.tprintf("want a missing-portal reason, got %q", StatusReport_message(&snapshot)),
	)
	assert(mockCount(&bus.mock, &bus.mock.createCalls) == 0, "no session without the interface")
}
