package client

// One client process per profile directory (#81). Two processes on one profile would each save
// the key store (keystore.odin) and config.json from their own memory, and the last save would
// win: pins, verified log heads, received chains and the no-downgrade flags could be lost.
// So every client that uses a profile (the GUI, --ui-script and --headless) first takes an
// exclusive lock on PROFILE_LOCK_FILE_NAME in the profile directory: flock on Linux, LockFileEx
// on Windows. The operating system drops the lock when the process ends, a crash included, so
// there is no PID in the file and no stale-lock logic. The file itself stays; it is empty.
//
// A second GUI start that only hands a haychat:// link to the running window (main,
// schemeHandler) does so before it would take the lock, so the hand-off still works.

import "core:fmt"
import "core:strings"

PROFILE_LOCK_FILE_NAME :: "haychat.lock"
// What a second client on the same profile says, in the GUI, the harness and ui-script.
PROFILE_LOCK_HELD_MESSAGE :: "HayChat is already running with this profile"

ProfileLockResult :: enum {
	Acquired,
	// Another open of the lock file (another process, or another lock in this one) holds it.
	AlreadyRunning,
	// The lock file could not be opened or locked for another reason (detail says why).
	Failed,
}

// A held lock is an open file; releasing (or the process ending) closes it.
ProfileLock :: struct {
	held:   bool,
	handle: uintptr,
}

// The lock file's path in profileDir. Allocated with allocator.
profileLockPath :: proc(profileDir: string, allocator := context.allocator) -> string {
	when ODIN_OS == .Windows {
		separator :: "\\"
	} else {
		separator :: "/"
	}
	return strings.concatenate({profileDir, separator, PROFILE_LOCK_FILE_NAME}, allocator)
}

// Takes the exclusive lock in profileDir, which must exist, without waiting. detail is a
// temp-allocated reason when result is Failed.
profileLockAcquire :: proc(
	profileDir: string,
) -> (
	lock: ProfileLock,
	result: ProfileLockResult,
	detail: string,
) {
	path := profileLockPath(profileDir, context.temp_allocator)
	return profileLockAcquirePath(path)
}

// Releases a held lock (closing the file releases it); a lock not held is left alone.
profileLockRelease :: proc(lock: ^ProfileLock) {
	if !lock.held {
		return
	}
	profileLockClose(lock.handle)
	lock^ = {}
}

// This process's lock, held until it exits.
@(private = "file")
processProfileLock: ProfileLock

// Takes this process's lock on the current profile directory (getConfigDir, after
// --config-dir), creating the directory first. AlreadyRunning means another client uses the
// profile and this one must not start. A lock that cannot be taken for another reason (a file
// system without locks) is only a warning: the client runs as it did before #81. Calling it
// again once the lock is held returns Acquired.
profileLockTakeForProcess :: proc() -> ProfileLockResult {
	if processProfileLock.held {
		return .Acquired
	}
	initConfigHome()
	if !ensureConfigDirExists() {
		// loadConfig reports this again and fails; there is nothing to lock.
		return .Failed
	}
	profileDir := getConfigDir()
	defer delete(profileDir)
	lock, result, detail := profileLockAcquire(profileDir)
	switch result {
	case .Acquired:
		processProfileLock = lock
	case .AlreadyRunning:
		fmt.eprintfln("[Error] %s (%s)", PROFILE_LOCK_HELD_MESSAGE, profileDir)
	case .Failed:
		fmt.eprintln(
			"[Warning] Could not lock the profile; another client on it could overwrite its",
			"key store:",
			detail,
		)
	}
	return result
}

// Releases this process's lock (only needed where the process goes on without the profile).
profileLockReleaseForProcess :: proc() {
	profileLockRelease(&processProfileLock)
}
