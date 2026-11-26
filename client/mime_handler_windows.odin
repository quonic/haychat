package client

// The Windows half of schemeRegistrationStatus (mime-handler.odin, #169): the open command
// and the "URL Protocol" value under HKEY_CURRENT_USER\Software\Classes\haychat, read with
// RegGetValueW (no reg.exe). Never called by a test.

import win32 "core:sys/windows"

// Whether the haychat:// handler already points at this executable (see SchemeRegistrationStatus).
schemeRegistrationStatus :: proc(
	exe: string,
	plan: SchemeRegistrationPlan,
) -> SchemeRegistrationStatus {
	classKey := win32.utf8_to_wstring(SCHEME_WINDOWS_SUBKEY, context.temp_allocator)
	commandKey := win32.utf8_to_wstring(
		SCHEME_WINDOWS_SUBKEY + "\\shell\\open\\command",
		context.temp_allocator,
	)
	urlProtocol := win32.utf8_to_wstring("URL Protocol", context.temp_allocator)
	// A path longer than this cannot be the command plan writes for a usable executable path,
	// and an ERROR_MORE_DATA answer registers again.
	buffer: [2048]u16
	size := win32.DWORD(size_of(buffer))
	if win32.RegGetValueW(
		   win32.HKEY_CURRENT_USER,
		   commandKey,
		   nil,
		   win32.RRF_RT_REG_SZ,
		   nil,
		   &buffer[0],
		   &size,
	   ) !=
	   0 {
		return .Stale
	}
	// size counts bytes, with the terminating NUL.
	units := int(size) / size_of(u16)
	for units > 0 && buffer[units - 1] == 0 {
		units -= 1
	}
	openCommand, convertErr := win32.wstring_to_utf8(
		win32.wstring(&buffer[0]),
		units,
		context.temp_allocator,
	)
	if convertErr != nil {
		return .Stale
	}
	protocolSize: win32.DWORD
	hasURLProtocol :=
		win32.RegGetValueW(
			win32.HKEY_CURRENT_USER,
			classKey,
			urlProtocol,
			win32.RRF_RT_REG_SZ,
			nil,
			nil,
			&protocolSize,
		) ==
		0
	_ = plan
	return schemeRegistrationCurrentWindows(exe, openCommand, hasURLProtocol) ? .Current : .Stale
}
