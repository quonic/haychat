package client

import "core:c/libc"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

@(test)
testProfileLockRefusesASecondHolderUntilReleased :: proc(t: ^testing.T) {
	_ = t
	defer free_all(context.temp_allocator)
	dir := configTestCreateTempDir("haychat_profile_lock")
	defer os.remove_all(dir)

	first, firstResult, firstDetail := profileLockAcquire(dir)
	assert(
		firstResult == .Acquired && first.held,
		fmt.tprintf("expected the first lock to be taken, got: %s", firstDetail),
	)
	lockPath := profileLockPath(dir, context.temp_allocator)
	assert(os.exists(lockPath), "expected the lock file in the profile directory")

	// A second open of the file stands in for a second process: the lock belongs to the open
	// file (flock) or handle (LockFileEx), not to the process.
	second, secondResult, _ := profileLockAcquire(dir)
	assert(secondResult == .AlreadyRunning, "expected a second lock on the profile to be refused")
	assert(!second.held, "expected a refused lock not to be held")
	profileLockRelease(&second)

	profileLockRelease(&first)
	assert(!first.held, "expected a released lock not to be held")
	profileLockRelease(&first)

	again, againResult, _ := profileLockAcquire(dir)
	assert(againResult == .Acquired, "expected the lock to be taken again after its release")
	profileLockRelease(&again)

	// Another profile directory has its own lock.
	otherDir := configTestCreateTempDir("haychat_profile_lock_other")
	defer os.remove_all(otherDir)
	held, heldResult, _ := profileLockAcquire(dir)
	other, otherResult, _ := profileLockAcquire(otherDir)
	assert(
		heldResult == .Acquired && otherResult == .Acquired,
		"expected two profiles to be locked at once",
	)
	profileLockRelease(&other)
	profileLockRelease(&held)
}

@(test)
testProfileLockFailsWithoutTheDirectory :: proc(t: ^testing.T) {
	_ = t
	defer free_all(context.temp_allocator)
	dir := configTestCreateTempDir("haychat_profile_lock_missing")
	defer os.remove_all(dir)
	missing := strings.concatenate({dir, "/missing"}, context.temp_allocator)
	lock, result, detail := profileLockAcquire(missing)
	assert(result == .Failed, "expected no lock in a directory that does not exist")
	assert(!lock.held, "expected a failed lock not to be held")
	assert(len(detail) > 0, "expected a failed lock to say why")
}

@(test)
testProfileLockMessage :: proc(t: ^testing.T) {
	_ = t
	assert(
		PROFILE_LOCK_HELD_MESSAGE == "HayChat is already running with this profile",
		"expected the message the GUI, the harness and ui-script show for a locked profile",
	)
	assert(PROFILE_LOCK_FILE_NAME == "haychat.lock", "expected the lock file's name")
}

@(test)
testHeadlessSignalSetsTheStopRequest :: proc(t: ^testing.T) {
	_ = t
	headlessStopRequestClear()
	assert(headlessStopRequested() == 0, "expected no stop request before a signal")
	previous := headlessSignalsInstall()
	raised := libc.raise(libc.SIGTERM)
	// The test runner's own handlers go back at once.
	headlessSignalsRestore(previous)
	assert(raised == 0, "expected raise(SIGTERM) to succeed")
	stop := headlessStopRequested()
	headlessStopRequestClear()
	assert(stop == libc.SIGTERM, "expected SIGTERM to be the stop request")
	assert(headlessSignalName(stop) == "SIGTERM", "expected the signal's name")
	assert(headlessSignalName(libc.SIGINT) == "SIGINT", "expected SIGINT's name")
}

@(test)
testHeadlessStopSignalEndsWaitAndSleep :: proc(t: ^testing.T) {
	_ = t
	defer free_all(context.temp_allocator)
	builder := strings.builder_make()
	harness := testHeadlessHarness(&builder, 1)
	defer testHeadlessHarnessDeinit(&harness, &builder)

	// Tests never watch the process's signals: a stop request elsewhere changes nothing here.
	assert(!harness.watchSignals, "expected a test harness not to watch signals")
	harness.stopSignal = libc.SIGTERM
	headlessHandleLine(&harness, "wait connected 600000")
	testExpectString(
		t,
		testHeadlessTakeOutput(&builder),
		`{"ok":false,"cmd":"wait","error":"stopped by SIGTERM while waiting for connected"}` +
		"\n",
		"the wait a signal ended",
	)
	headlessHandleLine(&harness, "sleep 600000")
	testExpectString(
		t,
		testHeadlessTakeOutput(&builder),
		`{"ok":true,"cmd":"sleep","ms":600000}` + "\n",
		"the sleep a signal ended",
	)
}
