#+build linux
package hotkey

// Wayland: the XDG GlobalShortcuts portal. A Wayland client cannot read keys sent to another
// window, so the desktop owns the shortcut: on the first arm the monitor registers the app
// ID, creates a portal session and binds one shortcut, proposing the configured key as its
// preferred trigger. The desktop asks the user to accept it (or choose another) and then
// sends Activated and Deactivated signals for press and release. The session lives as long
// as the monitor, so the dialog appears once per run at most; the desktop remembers the
// choice for the app ID. Disarming only makes the monitor ignore the signals.

import "core:sync"

@(private)
PORTAL_BUS_NAME :: "org.freedesktop.portal.Desktop"
@(private)
PORTAL_OBJECT_PATH :: "/org/freedesktop/portal/desktop"
@(private)
PORTAL_SHORTCUTS :: "org.freedesktop.portal.GlobalShortcuts"
@(private)
PORTAL_REQUEST :: "org.freedesktop.portal.Request"
@(private)
PORTAL_SESSION :: "org.freedesktop.portal.Session"
@(private)
PORTAL_REGISTRY :: "org.freedesktop.host.portal.Registry"
@(private)
DBUS_PROPERTIES :: "org.freedesktop.DBus.Properties"
@(private)
DBUS_LOCAL :: "org.freedesktop.DBus.Local"
// The same ID as SDL_SetAppMetadata in app.odin; the desktop keys the shortcut by it.
PORTAL_APP_ID :: "chat.haychat.client"
PORTAL_SHORTCUT_ID :: "push-to-talk"
PORTAL_SHORTCUT_DESCRIPTION :: "HayChat push-to-talk"
@(private)
PORTAL_CALL_TIMEOUT_MS :: 10_000
// How long one pass of the signal loop waits for the bus before it checks the owner's flags.
@(private)
PORTAL_PUMP_WAIT_MS :: 100

@(private)
PortalClient :: struct {
	dbus:          DBusSymbols,
	connection:    ^DBusConnection,
	version:       u32,
	sessionBuffer: [REPORT_TEXT_BYTES]u8,
	sessionLength: int,
	tokenCounter:  int,
	disconnected:  bool,
}

@(private)
PortalClient_session :: proc(client: ^PortalClient) -> string {
	return string(client.sessionBuffer[:client.sessionLength])
}

@(private)
portalRun :: proc(monitor: ^Monitor) {
	setStatus(monitor, .Idle)
	for !isStopping(monitor) && !isArmed(monitor) {
		waitForOwner(monitor, IDLE_WAIT)
	}
	if isStopping(monitor) {
		return
	}
	client: PortalClient
	defer portalClose(&client)
	message: [REPORT_TEXT_BYTES]u8
	setStatus(monitor, .Starting, "connecting to the desktop portal")
	length, ok := portalConnect(&client, monitor, message[:])
	if ok {
		setStatus(monitor, .Starting, "starting a shortcut session")
		length, ok = portalCreateSession(&client, monitor, message[:])
	}
	if ok {
		setStatus(monitor, .Starting, "waiting for the desktop to accept the shortcut")
		length, ok = portalBindShortcut(&client, monitor, message[:])
	}
	if !ok {
		if !isStopping(monitor) {
			setStatus(monitor, .Unavailable, "%s", string(message[:length]))
		}
		for !isStopping(monitor) {
			waitForOwner(monitor, IDLE_WAIT)
		}
		return
	}
	setStatus(monitor, .Active)
	for !isStopping(monitor) && !client.disconnected {
		if !isArmed(monitor) {
			setHeld(monitor, false)
		}
		if sync.atomic_exchange(&monitor.configureWanted, false) {
			portalConfigure(&client)
		}
		_ = portalPump(&client, monitor, "")
	}
	setHeld(monitor, false)
	if client.disconnected && !isStopping(monitor) {
		setStatus(monitor, .Unavailable, "the desktop portal connection closed")
		for !isStopping(monitor) {
			waitForOwner(monitor, IDLE_WAIT)
		}
	}
}

@(private)
portalConnect :: proc(client: ^PortalClient, monitor: ^Monitor, message: []u8) -> (int, bool) {
	if length, ok := dbusLoad(&client.dbus, message); !ok {
		return length, false
	}
	dbus := &client.dbus
	error: DBusError
	dbus.error_init(&error)
	defer dbus.error_free(&error)
	if len(monitor.options.busAddress) > 0 {
		address: [REPORT_TEXT_BYTES]u8
		client.connection = dbus.connection_open_private(
			cstringIn(address[:], monitor.options.busAddress),
			&error,
		)
		if client.connection != nil && !dbus.bus_register(client.connection, &error) {
			dbus.connection_close(client.connection)
			dbus.connection_unref(client.connection)
			client.connection = nil
		}
	} else {
		client.connection = dbus.bus_get_private(DBUS_BUS_SESSION, &error)
	}
	if client.connection == nil {
		return len(bprint(message, "no session bus (%s)", string(error.message))), false
	}
	dbus.connection_set_exit_on_disconnect(client.connection, false)

	// A host (unsandboxed) app tells the portal its app ID first, so the desktop can name it
	// and remember the shortcut. Portals older than 1.19 lack the registry; that is fine.
	if register := dbus.message_new_method_call(
		PORTAL_BUS_NAME,
		PORTAL_OBJECT_PATH,
		PORTAL_REGISTRY,
		"Register",
	); register != nil {
		writer := dbusWriter(dbus, register)
		DBusWriter_string(&writer, PORTAL_APP_ID)
		DBusWriter_open(&writer, .Array, "{sv}")
		DBusWriter_close(&writer)
		if writer.ok {
			reply := portalCall(client, register, nil)
			if reply != nil {
				dbus.message_unref(reply)
			}
		}
		dbus.message_unref(register)
	}

	reason: [REPORT_TEXT_BYTES]u8
	version, versionOK := portalVersion(client, reason[:])
	if !versionOK {
		text := string(reason[:cstringLength(reason[:])])
		return len(bprint(message, "this desktop has no GlobalShortcuts portal (%s)", text)),
			false
	}
	client.version = version

	matchError: DBusError
	dbus.error_init(&matchError)
	defer dbus.error_free(&matchError)
	dbus.bus_add_match(
		client.connection,
		"type='signal',interface='" + PORTAL_REQUEST + "',member='Response'",
		&matchError,
	)
	dbus.bus_add_match(
		client.connection,
		"type='signal',interface='" + PORTAL_SHORTCUTS + "'",
		&matchError,
	)
	if dbus.error_is_set(&matchError) {
		return len(bprint(message, "cannot watch the portal (%s)", string(matchError.message))),
			false
	}
	return 0, true
}

// The GlobalShortcuts interface's version property. Leaves the D-Bus error, NUL-terminated,
// in message when the interface is missing.
@(private)
portalVersion :: proc(client: ^PortalClient, message: []u8) -> (u32, bool) {
	dbus := &client.dbus
	get := dbus.message_new_method_call(PORTAL_BUS_NAME, PORTAL_OBJECT_PATH, DBUS_PROPERTIES, "Get")
	if get == nil {
		_ = cstringIn(message, "out of memory")
		return 0, false
	}
	defer dbus.message_unref(get)
	writer := dbusWriter(dbus, get)
	DBusWriter_string(&writer, PORTAL_SHORTCUTS)
	DBusWriter_string(&writer, "version")
	if !writer.ok {
		_ = cstringIn(message, "out of memory")
		return 0, false
	}
	reply := portalCall(client, get, message)
	if reply == nil {
		return 0, false
	}
	defer dbus.message_unref(reply)
	args, variant: DBusMessageIter
	if !dbus.message_iter_init(reply, &args) || dbus.message_iter_get_arg_type(&args) != .Variant {
		_ = cstringIn(message, "unexpected reply")
		return 0, false
	}
	dbus.message_iter_recurse(&args, &variant)
	version, ok := dbusReadU32(dbus, &variant)
	if !ok {
		_ = cstringIn(message, "unexpected reply")
	}
	return version, ok
}

// Sends a method call and waits for its reply (owned by the caller). On an error the
// D-Bus message goes NUL-terminated into errorText when it is given.
@(private)
portalCall :: proc(
	client: ^PortalClient,
	call: ^DBusMessage,
	errorText: []u8,
) -> ^DBusMessage {
	dbus := &client.dbus
	error: DBusError
	dbus.error_init(&error)
	defer dbus.error_free(&error)
	reply := dbus.connection_send_with_reply_and_block(
		client.connection,
		call,
		PORTAL_CALL_TIMEOUT_MS,
		&error,
	)
	if reply == nil && errorText != nil {
		text := string(error.message) if dbus.error_is_set(&error) else "no reply"
		_ = cstringIn(errorText, text)
	}
	return reply
}

@(private)
portalNextToken :: proc(client: ^PortalClient, buffer: []u8) -> string {
	client.tokenCounter += 1
	return bprint(buffer, "haychat_%d", client.tokenCounter)
}

// Reads the object path a portal method returns (the Request handle) into buffer.
@(private)
portalReadRequestPath :: proc(
	client: ^PortalClient,
	reply: ^DBusMessage,
	buffer: []u8,
) -> (string, bool) {
	args: DBusMessageIter
	if !client.dbus.message_iter_init(reply, &args) {
		return "", false
	}
	path, ok := dbusReadString(&client.dbus, &args)
	if !ok {
		return "", false
	}
	return string(buffer[:copy(buffer, path)]), true
}

@(private)
portalCreateSession :: proc(
	client: ^PortalClient,
	monitor: ^Monitor,
	message: []u8,
) -> (int, bool) {
	dbus := &client.dbus
	call := dbus.message_new_method_call(
		PORTAL_BUS_NAME,
		PORTAL_OBJECT_PATH,
		PORTAL_SHORTCUTS,
		"CreateSession",
	)
	if call == nil {
		return len(bprint(message, "out of memory")), false
	}
	defer dbus.message_unref(call)
	tokenBuffer: [64]u8
	writer := dbusWriter(dbus, call)
	DBusWriter_open(&writer, .Array, "{sv}")
	DBusWriter_entryString(&writer, "handle_token", portalNextToken(client, tokenBuffer[:]))
	DBusWriter_entryString(&writer, "session_handle_token", "haychat")
	DBusWriter_close(&writer)
	if !writer.ok {
		return len(bprint(message, "out of memory")), false
	}
	response, length, ok := portalRequest(client, monitor, call, "CreateSession", message)
	if !ok {
		return length, false
	}
	defer dbus.message_unref(response)
	results: DBusMessageIter
	portalResponseResults(client, response, &results)
	value: DBusMessageIter
	if dbusFindEntry(dbus, &results, "session_handle", &value) {
		if session, found := dbusReadString(dbus, &value); found {
			client.sessionLength = copy(client.sessionBuffer[:], session)
		}
	}
	if client.sessionLength == 0 {
		return len(bprint(message, "the portal returned no session")), false
	}
	return 0, true
}

@(private)
portalBindShortcut :: proc(
	client: ^PortalClient,
	monitor: ^Monitor,
	message: []u8,
) -> (int, bool) {
	dbus := &client.dbus
	call := dbus.message_new_method_call(
		PORTAL_BUS_NAME,
		PORTAL_OBJECT_PATH,
		PORTAL_SHORTCUTS,
		"BindShortcuts",
	)
	if call == nil {
		return len(bprint(message, "out of memory")), false
	}
	defer dbus.message_unref(call)
	trigger := portalPreferredTrigger(sync.atomic_load(&monitor.key))
	tokenBuffer: [64]u8
	writer := dbusWriter(dbus, call)
	DBusWriter_string(&writer, PortalClient_session(client), .ObjectPath)
	DBusWriter_open(&writer, .Array, "(sa{sv})")
	DBusWriter_open(&writer, .Struct)
	DBusWriter_string(&writer, PORTAL_SHORTCUT_ID)
	DBusWriter_open(&writer, .Array, "{sv}")
	DBusWriter_entryString(&writer, "description", PORTAL_SHORTCUT_DESCRIPTION)
	if len(trigger) > 0 {
		DBusWriter_entryString(&writer, "preferred_trigger", trigger)
	}
	DBusWriter_close(&writer)
	DBusWriter_close(&writer)
	DBusWriter_close(&writer)
	DBusWriter_string(&writer, "") // parent window: none
	DBusWriter_open(&writer, .Array, "{sv}")
	DBusWriter_entryString(&writer, "handle_token", portalNextToken(client, tokenBuffer[:]))
	DBusWriter_close(&writer)
	if !writer.ok {
		return len(bprint(message, "out of memory")), false
	}
	response, length, ok := portalRequest(client, monitor, call, "BindShortcuts", message)
	if !ok {
		return length, false
	}
	defer dbus.message_unref(response)
	results, shortcuts: DBusMessageIter
	portalResponseResults(client, response, &results)
	if dbusFindEntry(dbus, &results, "shortcuts", &shortcuts) {
		portalApplyShortcuts(client, monitor, &shortcuts)
	}
	return 0, true
}

// Sends a portal method that answers with a Request handle and waits for that request's
// Response signal (owned by the caller). Fails on a refused call, a cancelled or failed
// response, a closed bus, or a stop.
@(private)
portalRequest :: proc(
	client: ^PortalClient,
	monitor: ^Monitor,
	call: ^DBusMessage,
	method: string,
	message: []u8,
) -> (
	response: ^DBusMessage,
	length: int,
	ok: bool,
) {
	dbus := &client.dbus
	errorText: [REPORT_TEXT_BYTES]u8
	reply := portalCall(client, call, errorText[:])
	if reply == nil {
		text := string(errorText[:cstringLength(errorText[:])])
		return nil, len(bprint(message, "%s failed (%s)", method, text)), false
	}
	pathBuffer: [REPORT_TEXT_BYTES]u8
	path, pathOK := portalReadRequestPath(client, reply, pathBuffer[:])
	dbus.message_unref(reply)
	if !pathOK {
		return nil, len(bprint(message, "%s returned no request", method)), false
	}
	response = portalPump(client, monitor, path)
	if response == nil {
		return nil, len(bprint(message, "the desktop portal connection closed")), false
	}
	args: DBusMessageIter
	code := u32(2)
	if dbus.message_iter_init(response, &args) {
		code, _ = dbusReadU32(dbus, &args)
	}
	if code != 0 {
		dbus.message_unref(response)
		reason := code == 1 ? "cancelled" : "failed"
		return nil, len(bprint(message, "the desktop %s %s", reason, method)), false
	}
	return response, 0, true
}

// Points results at a Response signal's a{sv}.
@(private)
portalResponseResults :: proc(
	client: ^PortalClient,
	response: ^DBusMessage,
	results: ^DBusMessageIter,
) {
	if client.dbus.message_iter_init(response, results) {
		_ = client.dbus.message_iter_next(results)
	}
}

// Takes the trigger description of our shortcut from an a(sa{sv}) list.
@(private)
portalApplyShortcuts :: proc(client: ^PortalClient, monitor: ^Monitor, list: ^DBusMessageIter) {
	dbus := &client.dbus
	if dbus.message_iter_get_arg_type(list) != .Array {
		return
	}
	items: DBusMessageIter
	dbus.message_iter_recurse(list, &items)
	for dbus.message_iter_get_arg_type(&items) == .Struct {
		item: DBusMessageIter
		dbus.message_iter_recurse(&items, &item)
		if id, ok := dbusReadString(dbus, &item); ok && id == PORTAL_SHORTCUT_ID {
			trigger := ""
			value: DBusMessageIter
			if dbus.message_iter_next(&item) &&
			   dbusFindEntry(dbus, &item, "trigger_description", &value) {
				trigger, _ = dbusReadString(dbus, &value)
			}
			setTrigger(monitor, trigger, client.version >= 2)
			return
		}
		if !dbus.message_iter_next(&items) {
			break
		}
	}
	setTrigger(monitor, "", client.version >= 2)
}

// Opens the desktop's dialog for changing the shortcut (portal version 2).
@(private)
portalConfigure :: proc(client: ^PortalClient) {
	if client.version < 2 {
		return
	}
	dbus := &client.dbus
	call := dbus.message_new_method_call(
		PORTAL_BUS_NAME,
		PORTAL_OBJECT_PATH,
		PORTAL_SHORTCUTS,
		"ConfigureShortcuts",
	)
	if call == nil {
		return
	}
	defer dbus.message_unref(call)
	writer := dbusWriter(dbus, call)
	DBusWriter_string(&writer, PortalClient_session(client), .ObjectPath)
	DBusWriter_string(&writer, "")
	DBusWriter_open(&writer, .Array, "{sv}")
	DBusWriter_close(&writer)
	if writer.ok {
		// The dialog may stay open for a long time, so the reply is not awaited.
		_ = dbus.connection_send(client.connection, call, nil)
		dbus.connection_flush(client.connection)
	}
}

// Reads the bus for up to PORTAL_PUMP_WAIT_MS and handles every queued message: shortcut
// signals of our session, and the disconnect. With waitPath set it keeps going (while the
// monitor is not stopped) until the Response signal on that path arrives and returns it.
@(private)
portalPump :: proc(
	client: ^PortalClient,
	monitor: ^Monitor,
	waitPath: string,
) -> ^DBusMessage {
	dbus := &client.dbus
	for {
		if isStopping(monitor) || client.disconnected {
			return nil
		}
		if !dbus.connection_read_write(client.connection, PORTAL_PUMP_WAIT_MS) {
			client.disconnected = true
			return nil
		}
		for {
			message := dbus.connection_pop_message(client.connection)
			if message == nil {
				break
			}
			if len(waitPath) > 0 &&
			   dbusMessageIs(dbus, message, DBUS_MESSAGE_TYPE_SIGNAL, PORTAL_REQUEST, "Response") &&
			   string(dbus.message_get_path(message)) == waitPath {
				return message
			}
			portalHandleMessage(client, monitor, message)
			dbus.message_unref(message)
		}
		if len(waitPath) == 0 {
			return nil
		}
	}
}

@(private)
portalHandleMessage :: proc(client: ^PortalClient, monitor: ^Monitor, message: ^DBusMessage) {
	dbus := &client.dbus
	if dbusMessageIs(dbus, message, DBUS_MESSAGE_TYPE_SIGNAL, DBUS_LOCAL, "Disconnected") {
		client.disconnected = true
		return
	}
	if dbus.message_get_type(message) != DBUS_MESSAGE_TYPE_SIGNAL ||
	   string(dbus.message_get_interface(message)) != PORTAL_SHORTCUTS ||
	   client.sessionLength == 0 {
		return
	}
	args: DBusMessageIter
	if !dbus.message_iter_init(message, &args) {
		return
	}
	session, ok := dbusReadString(dbus, &args)
	if !ok || session != PortalClient_session(client) || !dbus.message_iter_next(&args) {
		return
	}
	member := string(dbus.message_get_member(message))
	switch member {
	case "Activated", "Deactivated":
		id, idOK := dbusReadString(dbus, &args)
		if !idOK || id != PORTAL_SHORTCUT_ID {
			return
		}
		setHeld(monitor, member == "Activated" && isArmed(monitor))
	case "ShortcutsChanged":
		portalApplyShortcuts(client, monitor, &args)
	}
}

@(private)
portalClose :: proc(client: ^PortalClient) {
	dbus := &client.dbus
	if client.connection != nil {
		if client.sessionLength > 0 && !client.disconnected {
			buffer: [REPORT_TEXT_BYTES]u8
			path := cstringIn(buffer[:], PortalClient_session(client))
			close := dbus.message_new_method_call(PORTAL_BUS_NAME, path, PORTAL_SESSION, "Close")
			if close != nil {
				_ = dbus.connection_send(client.connection, close, nil)
				dbus.connection_flush(client.connection)
				dbus.message_unref(close)
			}
		}
		dbus.connection_close(client.connection)
		dbus.connection_unref(client.connection)
	}
	dbusUnload(dbus)
	client^ = {}
}
