package client

// The Windows half of profile_lock.odin: LockFileEx on the lock file.

import "core:fmt"
import win "core:sys/windows"

// Opens (creating it) and locks the first byte of path without waiting. The handle is not
// inheritable (no security attributes), so a child process never keeps the lock.
profileLockAcquirePath :: proc(
	path: string,
) -> (
	lock: ProfileLock,
	result: ProfileLockResult,
	detail: string,
) {
	handle := win.CreateFileW(
		win.utf8_to_wstring(path, context.temp_allocator),
		win.GENERIC_READ | win.GENERIC_WRITE,
		win.FILE_SHARE_READ | win.FILE_SHARE_WRITE | win.FILE_SHARE_DELETE,
		nil,
		win.OPEN_ALWAYS,
		win.FILE_ATTRIBUTE_NORMAL,
		nil,
	)
	if handle == win.INVALID_HANDLE_VALUE {
		return {}, .Failed, fmt.tprintf("cannot open %s: error %d", path, win.GetLastError())
	}
	// Byte-range locks belong to the handle, so a second handle in this process conflicts
	// with the first just as another process would (the tests rely on it).
	overlapped: win.OVERLAPPED
	if !win.LockFileEx(
		handle,
		win.LOCKFILE_EXCLUSIVE_LOCK | win.LOCKFILE_FAIL_IMMEDIATELY,
		0,
		1,
		0,
		&overlapped,
	) {
		lockErr := win.GetLastError()
		win.CloseHandle(handle)
		if lockErr == win.ERROR_LOCK_VIOLATION {
			return {}, .AlreadyRunning, ""
		}
		return {}, .Failed, fmt.tprintf("cannot lock %s: error %d", path, lockErr)
	}
	return {held = true, handle = uintptr(handle)}, .Acquired, ""
}

profileLockClose :: proc(handle: uintptr) {
	win.CloseHandle(win.HANDLE(handle))
}
