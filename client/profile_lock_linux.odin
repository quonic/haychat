package client

// The Linux half of profile_lock.odin: flock on the lock file.

import "core:fmt"
import "core:strings"
import "core:sys/linux"

// Opens (creating it, mode 0600) and locks path without waiting.
profileLockAcquirePath :: proc(
	path: string,
) -> (
	lock: ProfileLock,
	result: ProfileLockResult,
	detail: string,
) {
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	// CLOEXEC: a child process (xdg-mime, a file dialog helper) must not inherit the lock and
	// keep it after this process ends. NOFOLLOW: never lock through a planted link.
	fd, openErr := linux.open(cpath, {.RDWR, .CREAT, .CLOEXEC, .NOFOLLOW}, {.IRUSR, .IWUSR})
	if openErr != .NONE {
		return {}, .Failed, fmt.tprintf("cannot open %s: %v", path, openErr)
	}
	// flock locks belong to the open file description, so a second open in this process
	// conflicts with the first just as another process would (the tests rely on it).
	if lockErr := linux.flock(fd, {.EX, .NB}); lockErr != .NONE {
		_ = linux.close(fd)
		if lockErr == .EWOULDBLOCK {
			return {}, .AlreadyRunning, ""
		}
		return {}, .Failed, fmt.tprintf("cannot lock %s: %v", path, lockErr)
	}
	return {held = true, handle = uintptr(fd)}, .Acquired, ""
}

profileLockClose :: proc(handle: uintptr) {
	_ = linux.close(linux.Fd(handle))
}
