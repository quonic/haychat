#+build linux
package hotkey

// The part of libdbus-1 the portal backend (and its test's mock portal) uses, loaded at
// runtime so a system without it still starts the client. client/dbus links libdbus-1 at
// build time instead, which would make it a hard dependency, so it is not used here.
// One connection is only ever used from one thread.

import "core:c"
import "core:dynlib"

@(private)
DBUS_LIBRARY :: "libdbus-1.so.3"

@(private)
DBusConnection :: struct {}
@(private)
DBusMessage :: struct {}

@(private)
DBusError :: struct {
	name:     cstring,
	message:  cstring,
	dummy:    c.uint,
	padding1: rawptr,
}

// Layout of DBusMessageIter (dbus-message.h); only libdbus reads the fields.
@(private)
DBusMessageIter :: struct {
	dummy1:  rawptr,
	dummy2:  rawptr,
	dummy3:  u32,
	dummy4:  c.int,
	dummy5:  c.int,
	dummy6:  c.int,
	dummy7:  c.int,
	dummy8:  c.int,
	dummy9:  c.int,
	dummy10: c.int,
	dummy11: c.int,
	pad1:    c.int,
	pad2:    rawptr,
	pad3:    rawptr,
}

@(private)
DBUS_BUS_SESSION :: 0
@(private)
DBUS_MESSAGE_TYPE_METHOD_CALL :: 1
@(private)
DBUS_MESSAGE_TYPE_SIGNAL :: 4
@(private)
DBUS_NAME_FLAG_DO_NOT_QUEUE :: 4
@(private)
DBUS_TIMEOUT_DEFAULT :: -1

@(private)
DBusType :: enum c.int {
	Invalid    = 0,
	Byte       = 'y',
	Boolean    = 'b',
	Uint32     = 'u',
	Uint64     = 't',
	String     = 's',
	ObjectPath = 'o',
	Array      = 'a',
	Variant    = 'v',
	Struct     = 'r',
	DictEntry  = 'e',
}

// Field names are the C names without the "dbus_" prefix (dynlib.initialize_symbols).
@(private)
DBusSymbols :: struct {
	error_init:                         proc "c" (error: ^DBusError),
	error_free:                         proc "c" (error: ^DBusError),
	error_is_set:                       proc "c" (error: ^DBusError) -> b32,
	bus_get_private:                    proc "c" (
		type: c.int,
		error: ^DBusError,
	) -> ^DBusConnection,
	connection_open_private:            proc "c" (
		address: cstring,
		error: ^DBusError,
	) -> ^DBusConnection,
	bus_register:                       proc "c" (
		connection: ^DBusConnection,
		error: ^DBusError,
	) -> b32,
	bus_get_unique_name:                proc "c" (connection: ^DBusConnection) -> cstring,
	bus_add_match:                      proc "c" (
		connection: ^DBusConnection,
		rule: cstring,
		error: ^DBusError,
	),
	bus_request_name:                   proc "c" (
		connection: ^DBusConnection,
		name: cstring,
		flags: c.uint,
		error: ^DBusError,
	) -> c.int,
	connection_set_exit_on_disconnect:  proc "c" (connection: ^DBusConnection, exit: b32),
	connection_close:                   proc "c" (connection: ^DBusConnection),
	connection_unref:                   proc "c" (connection: ^DBusConnection),
	connection_read_write:              proc "c" (
		connection: ^DBusConnection,
		timeoutMilliseconds: c.int,
	) -> b32,
	connection_pop_message:             proc "c" (connection: ^DBusConnection) -> ^DBusMessage,
	connection_send:                    proc "c" (
		connection: ^DBusConnection,
		message: ^DBusMessage,
		serial: ^u32,
	) -> b32,
	connection_flush:                   proc "c" (connection: ^DBusConnection),
	connection_send_with_reply_and_block: proc "c" (
		connection: ^DBusConnection,
		message: ^DBusMessage,
		timeoutMilliseconds: c.int,
		error: ^DBusError,
	) -> ^DBusMessage,
	message_new_method_call:            proc "c" (
		destination, path, iface, method: cstring,
	) -> ^DBusMessage,
	message_new_method_return:          proc "c" (call: ^DBusMessage) -> ^DBusMessage,
	message_new_signal:                 proc "c" (path, iface, name: cstring) -> ^DBusMessage,
	message_new_error:                  proc "c" (
		replyTo: ^DBusMessage,
		name, text: cstring,
	) -> ^DBusMessage,
	message_set_destination:            proc "c" (
		message: ^DBusMessage,
		destination: cstring,
	) -> b32,
	message_unref:                      proc "c" (message: ^DBusMessage),
	message_get_type:                   proc "c" (message: ^DBusMessage) -> c.int,
	message_get_path:                   proc "c" (message: ^DBusMessage) -> cstring,
	message_get_interface:              proc "c" (message: ^DBusMessage) -> cstring,
	message_get_member:                 proc "c" (message: ^DBusMessage) -> cstring,
	message_get_sender:                 proc "c" (message: ^DBusMessage) -> cstring,
	message_iter_init:                  proc "c" (
		message: ^DBusMessage,
		iter: ^DBusMessageIter,
	) -> b32,
	message_iter_init_append:           proc "c" (message: ^DBusMessage, iter: ^DBusMessageIter),
	message_iter_append_basic:          proc "c" (
		iter: ^DBusMessageIter,
		type: DBusType,
		value: rawptr,
	) -> b32,
	message_iter_open_container:        proc "c" (
		iter: ^DBusMessageIter,
		type: DBusType,
		signature: cstring,
		sub: ^DBusMessageIter,
	) -> b32,
	message_iter_close_container:       proc "c" (
		iter: ^DBusMessageIter,
		sub: ^DBusMessageIter,
	) -> b32,
	message_iter_get_arg_type:          proc "c" (iter: ^DBusMessageIter) -> DBusType,
	message_iter_get_basic:             proc "c" (iter: ^DBusMessageIter, value: rawptr),
	message_iter_recurse:               proc "c" (iter: ^DBusMessageIter, sub: ^DBusMessageIter),
	message_iter_next:                  proc "c" (iter: ^DBusMessageIter) -> b32,
	__handle:                           dynlib.Library,
}

// Loads libdbus-1 into symbols. message gets the reason on failure.
@(private)
dbusLoad :: proc(symbols: ^DBusSymbols, message: []u8) -> (int, bool) {
	_, loaded := dynlib.initialize_symbols(symbols, DBUS_LIBRARY, "dbus_")
	if loaded && dbusSymbolsComplete(symbols) {
		return 0, true
	}
	length := len(bprint(message, "%s not found (%s)", DBUS_LIBRARY, dynlib.last_error()))
	if symbols.__handle != nil {
		_ = dynlib.unload_library(symbols.__handle)
	}
	symbols^ = {}
	return length, false
}

@(private)
dbusUnload :: proc(symbols: ^DBusSymbols) {
	if symbols.__handle != nil {
		_ = dynlib.unload_library(symbols.__handle)
	}
	symbols^ = {}
}

@(private)
dbusSymbolsComplete :: proc(symbols: ^DBusSymbols) -> bool {
	// Every field before __handle is a procedure pointer.
	count :: (size_of(DBusSymbols) - size_of(dynlib.Library)) / size_of(rawptr)
	#assert(offset_of(DBusSymbols, __handle) == count * size_of(rawptr))
	pointers := cast([^]rawptr)rawptr(symbols)
	for index in 0 ..< count {
		if pointers[index] == nil {
			return false
		}
	}
	return true
}

// ── Writing message arguments ─────────────────────────────────────

// Appends arguments to a message. Containers nest up to 11 deep; any failed append makes
// ok false, and the message must then not be sent.
@(private)
DBusWriter :: struct {
	symbols: ^DBusSymbols,
	stack:   [12]DBusMessageIter,
	depth:   int,
	ok:      bool,
}

@(private)
dbusWriter :: proc(symbols: ^DBusSymbols, message: ^DBusMessage) -> (writer: DBusWriter) {
	writer.symbols = symbols
	writer.ok = true
	symbols.message_iter_init_append(message, &writer.stack[0])
	return
}

@(private)
DBusWriter_top :: proc(writer: ^DBusWriter) -> ^DBusMessageIter {
	return &writer.stack[writer.depth]
}

@(private)
DBusWriter_string :: proc(writer: ^DBusWriter, value: string, type := DBusType.String) {
	buffer: [512]u8
	text := cstringIn(buffer[:], value)
	if !writer.symbols.message_iter_append_basic(DBusWriter_top(writer), type, &text) {
		writer.ok = false
	}
}

@(private)
DBusWriter_u32 :: proc(writer: ^DBusWriter, value: u32) {
	value := value
	if !writer.symbols.message_iter_append_basic(DBusWriter_top(writer), .Uint32, &value) {
		writer.ok = false
	}
}

@(private)
DBusWriter_u64 :: proc(writer: ^DBusWriter, value: u64) {
	value := value
	if !writer.symbols.message_iter_append_basic(DBusWriter_top(writer), .Uint64, &value) {
		writer.ok = false
	}
}

@(private)
DBusWriter_open :: proc(writer: ^DBusWriter, type: DBusType, signature: cstring = nil) {
	if writer.depth + 1 >= len(writer.stack) {
		writer.ok = false
		return
	}
	parent := DBusWriter_top(writer)
	writer.depth += 1
	if !writer.symbols.message_iter_open_container(
		parent,
		type,
		signature,
		DBusWriter_top(writer),
	) {
		writer.ok = false
	}
}

@(private)
DBusWriter_close :: proc(writer: ^DBusWriter) {
	if writer.depth == 0 {
		writer.ok = false
		return
	}
	sub := DBusWriter_top(writer)
	writer.depth -= 1
	if !writer.symbols.message_iter_close_container(DBusWriter_top(writer), sub) {
		writer.ok = false
	}
}

// One a{sv} entry whose value is a string (or object path, with type).
@(private)
DBusWriter_entryString :: proc(
	writer: ^DBusWriter,
	key, value: string,
	type := DBusType.String,
) {
	DBusWriter_open(writer, .DictEntry)
	DBusWriter_string(writer, key)
	DBusWriter_open(writer, .Variant, type == .ObjectPath ? "o" : "s")
	DBusWriter_string(writer, value, type)
	DBusWriter_close(writer)
	DBusWriter_close(writer)
}

// ── Reading message arguments ─────────────────────────────────────

@(private)
dbusReadString :: proc(symbols: ^DBusSymbols, iter: ^DBusMessageIter) -> (string, bool) {
	type := symbols.message_iter_get_arg_type(iter)
	if type != .String && type != .ObjectPath {
		return "", false
	}
	text: cstring
	symbols.message_iter_get_basic(iter, &text)
	return string(text), true
}

@(private)
dbusReadU32 :: proc(symbols: ^DBusSymbols, iter: ^DBusMessageIter) -> (u32, bool) {
	if symbols.message_iter_get_arg_type(iter) != .Uint32 {
		return 0, false
	}
	value: u32
	symbols.message_iter_get_basic(iter, &value)
	return value, true
}

// Finds key in the a{sv} at iter and points value at its variant's content.
@(private)
dbusFindEntry :: proc(
	symbols: ^DBusSymbols,
	iter: ^DBusMessageIter,
	key: string,
	value: ^DBusMessageIter,
) -> bool {
	if symbols.message_iter_get_arg_type(iter) != .Array {
		return false
	}
	entries: DBusMessageIter
	symbols.message_iter_recurse(iter, &entries)
	for symbols.message_iter_get_arg_type(&entries) == .DictEntry {
		entry: DBusMessageIter
		symbols.message_iter_recurse(&entries, &entry)
		name, ok := dbusReadString(symbols, &entry)
		if ok && name == key && symbols.message_iter_next(&entry) {
			if symbols.message_iter_get_arg_type(&entry) != .Variant {
				return false
			}
			symbols.message_iter_recurse(&entry, value)
			return true
		}
		if !symbols.message_iter_next(&entries) {
			break
		}
	}
	return false
}

@(private)
dbusMessageIs :: proc(
	symbols: ^DBusSymbols,
	message: ^DBusMessage,
	type: c.int,
	iface, member: string,
) -> bool {
	if symbols.message_get_type(message) != type {
		return false
	}
	return(
		string(symbols.message_get_interface(message)) == iface &&
		string(symbols.message_get_member(message)) == member \
	)
}
