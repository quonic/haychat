package server

import "../common"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

// The startup scan's guards against a wrong restore order (#131, router_attachments.odin
// attachmentOrphanGuard): the router runs the whole scan (StorageScan, Known, then
// StorageDeleteOrphans or nothing) against a real storage worker on a temporary directory, and
// the database is answered by hand.

@(private = "file")
orphanTestLater :: proc "contextless" () -> time.Time {
	return time.time_add(time.now(), 2 * time.Hour)
}

@(private = "file")
orphanTestPlenty :: proc(dir: string) -> (i64, bool) {
	_ = dir
	return 1 << 40, true
}

@(private = "file")
orphanTestBlob :: proc(index: int) -> common.AttachmentBlobID {
	blobId: common.AttachmentBlobID
	for &b in blobId {
		b = 0xAB
	}
	blobId[0] = u8(index >> 8)
	blobId[1] = u8(index)
	return blobId
}

@(private = "file")
orphanTestPollStorage :: proc(h: ^RouterTestHarness) -> (StorageCommand, bool) {
	msg, err := IPC_Client_poll(h.pm.config.storageFd)
	if err != nil {
		return {}, false
	}
	command, ok := msg.(StorageCommand)
	assert(ok, fmt.tprintf("expected a StorageCommand, got %v", msg))
	return command, true
}

// Hands a router storage command to the worker and its answer back to the router.
@(private = "file")
orphanTestRunStorage :: proc(
	h: ^RouterTestHarness,
	worker: ^StorageWorker,
	command: StorageCommand,
) -> StorageResult {
	result, _ := StorageWorker_handle(worker, command.request)
	StorageRequest_deinit(command.request)
	return result
}

OrphanScanCase :: struct {
	files:      int, // blob files older than an hour
	rows:       int, // of them, the first ones with a Ready row
	swept:      int, // of them, the last ones whose rows the startup sweep deletes meanwhile
	tableEmpty: bool,
	allowPurge: bool,
}

OrphanScanOutcome :: struct {
	deleteSent: bool, // the router sent StorageDeleteOrphans
	deleted:    int, // files that request deleted
	left:       int, // blob files left on disk
	kept:       u64, // AttachmentRouterStats.orphansKept
	found:      u64, // AttachmentRouterStats.orphansFound
}

@(private = "file")
orphanTestRun :: proc(c: OrphanScanCase) -> OrphanScanOutcome {
	assert(c.rows + c.swept <= c.files, "expected rows and swept files among the files")
	// The helper allocates its path pieces; they live on the temp allocator.
	allocator := context.allocator
	context.allocator = context.temp_allocator
	dir := routerTestCreateTempDir("haychat_orphan_scan")
	context.allocator = allocator
	defer os.remove_all(dir)
	for name in ([]string{ATTACHMENT_INCOMING_DIR_NAME, ATTACHMENT_BLOBS_DIR_NAME}) {
		sub := fmt.tprintf("%s/%s", dir, name)
		assert(os.make_directory(sub) == nil, "expected the blob directory layout")
	}
	worker := StorageWorker_init(dir)
	defer StorageWorker_deinit(&worker)
	worker.freeBytes = orphanTestPlenty
	paths := make([dynamic]string, 0, c.files)
	defer {
		for path in paths {
			delete(path)
		}
		delete(paths)
	}
	for index in 0 ..< c.files {
		blobId := orphanTestBlob(index)
		path := storageBlobPath(&worker, blobId)
		_ = os.make_directory(fmt.tprintf("%s/%s/%02x", dir, ATTACHMENT_BLOBS_DIR_NAME, blobId[0]))
		assert(
			os.write_entire_file_from_bytes(path, transmute([]u8)string("a blob")) == nil,
			"expected a blob file written",
		)
		append(&paths, path)
	}
	worker.now = orphanTestLater

	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)
	h.pm.config.attachmentsEnabled = true
	h.pm.config.attachmentPendingHours = DEFAULT_ATTACHMENT_PENDING_HOURS
	h.pm.config.attachmentAllowOrphanPurge = c.allowPurge

	// The first tick starts the scan, the sweeper and the tombstone pass.
	MainRouterState_attachmentsTick(&h.pm, &h.state, time.tick_now())
	scanCommand, scanSent := orphanTestPollStorage(&h)
	_, isScan := scanCommand.request.(StorageScan)
	assert(scanSent && isScan, "expected the startup scan first")
	sweep := routerPollDatabaseQuery(&h)
	assert(sweep.request.(common.DatabaseAttachmentRequest).action == .Sweep, "expected a sweep")
	IPC__database_query_request_deinit(sweep.request)
	tombstones := routerPollDatabaseQuery(&h)
	assert(
		tombstones.request.(common.DatabaseAttachmentRequest).action == .TombstoneFiles,
		"expected the tombstone pass",
	)
	IPC__database_query_request_deinit(tombstones.request)
	// The worker scans before it sees the sweep's deletions, as on a real start.
	scanResult := orphanTestRunStorage(&h, &worker, scanCommand)
	assert(
		len(scanResult.(StorageScanResult).files) == c.files,
		fmt.tprintf("expected %d files scanned, got %v", c.files, scanResult),
	)

	// The sweep's answer arrives before the scan's: its rows are gone, then its files.
	swept := make([dynamic]common.DatabaseAttachmentBlob, 0, c.swept)
	for index in c.files - c.swept ..< c.files {
		append(&swept, common.DatabaseAttachmentBlob{blobId = orphanTestBlob(index), state = .Bound})
	}
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		sweep.request_id,
		common.DatabaseQueryResponse {
			success = true,
			result = common.DatabaseAttachmentResult {
				action = .Sweep,
				outcome = .Applied,
				blobs = swept,
			},
		},
	)
	if c.swept > 0 {
		deleteBlobs, sent := orphanTestPollStorage(&h)
		_, isDelete := deleteBlobs.request.(StorageDeleteBlobs)
		assert(sent && isDelete, "expected the swept rows' files deleted")
		StorageResult_deinit(orphanTestRunStorage(&h, &worker, deleteBlobs))
	}

	MainRouterState_handleStorageResponse(
		&h.pm,
		&h.state,
		StorageResponse{requestId = scanCommand.requestId, result = scanResult},
	)
	known := routerPollDatabaseQuery(&h)
	knownRequest := known.request.(common.DatabaseAttachmentRequest)
	assert(
		knownRequest.action == .Known && len(knownRequest.blobIds) == c.files,
		fmt.tprintf("expected Known for every scanned file, got %v", knownRequest.action),
	)
	IPC__database_query_request_deinit(known.request)
	rows := make([dynamic]common.DatabaseAttachmentBlob, 0, c.rows)
	for index in 0 ..< c.rows {
		append(&rows, common.DatabaseAttachmentBlob{blobId = orphanTestBlob(index), state = .Ready})
	}
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		known.request_id,
		common.DatabaseQueryResponse {
			success = true,
			result = common.DatabaseAttachmentResult {
				action = .Known,
				outcome = .Applied,
				blobs = rows,
				tableEmpty = c.tableEmpty,
			},
		},
	)

	outcome: OrphanScanOutcome
	if command, sent := orphanTestPollStorage(&h); sent {
		_, isOrphans := command.request.(StorageDeleteOrphans)
		assert(isOrphans, fmt.tprintf("expected StorageDeleteOrphans, got %v", command.request))
		outcome.deleteSent = true
		result := orphanTestRunStorage(&h, &worker, command)
		outcome.deleted = result.(StorageOrphansDeleted).deleted
		MainRouterState_handleStorageResponse(
			&h.pm,
			&h.state,
			StorageResponse{requestId = command.requestId, result = result},
		)
	}
	_, more := orphanTestPollStorage(&h)
	assert(!more, "expected no further storage command")
	for path in paths {
		if os.exists(path) {
			outcome.left += 1
		}
	}
	outcome.kept = h.state.attachments.stats.orphansKept
	outcome.found = h.state.attachments.stats.orphansFound
	assert(!h.state.attachments.scanPending, "expected the scan over")
	assert(len(h.state.attachments.scanSwept) == 0, "expected the swept blobs forgotten")
	return outcome
}

@(test)
testRouterOrphanScanKeepsEverythingWhenTheTableIsEmpty :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	// Even a single file stays: an empty table beside files is a restore in the wrong order.
	for files in ([]int{1, 3, 40}) {
		outcome := orphanTestRun({files = files, tableEmpty = true})
		assert(
			!outcome.deleteSent && outcome.left == files && outcome.kept == u64(files),
			fmt.tprintf("expected all %d files kept with an empty table, got %v", files, outcome),
		)
		assert(outcome.found == 0, "expected no orphan counted as removed")
	}
}

@(test)
testRouterOrphanScanDeletesOrphansWithinTheFloor :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	// 10 of 12 have no row, far over the share but within the floor: they go.
	outcome := orphanTestRun({files = 12, rows = 2})
	assert(
		outcome.deleteSent &&
		outcome.deleted == ATTACHMENT_ORPHAN_PURGE_FLOOR &&
		outcome.left == 2 &&
		outcome.kept == 0 &&
		outcome.found == u64(ATTACHMENT_ORPHAN_PURGE_FLOOR),
		fmt.tprintf("expected the 10 orphans deleted and 2 files left, got %v", outcome),
	)
	// One stray file beside one known file goes too.
	single := orphanTestRun({files = 2, rows = 1})
	assert(
		single.deleted == 1 && single.left == 1,
		fmt.tprintf("expected the one orphan deleted, got %v", single),
	)
}

@(test)
testRouterOrphanScanKeepsOrphansOverTheShareUnlessAllowed :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	// 11 of 30 have no row: over the floor and over 10%.
	over := orphanTestRun({files = 30, rows = 19})
	assert(
		!over.deleteSent && over.left == 30 && over.kept == 11 && over.found == 0,
		fmt.tprintf("expected the 11 orphans kept, got %v", over),
	)
	allowed := orphanTestRun({files = 30, rows = 19, allowPurge = true})
	assert(
		allowed.deleteSent &&
		allowed.deleted == 11 &&
		allowed.left == 19 &&
		allowed.kept == 0 &&
		allowed.found == 11,
		fmt.tprintf("expected the override to delete the 11 orphans, got %v", allowed),
	)
	// The override lifts the empty-table guard too.
	empty := orphanTestRun({files = 5, tableEmpty = true, allowPurge = true})
	assert(
		empty.deleteSent && empty.deleted == 5 && empty.left == 0,
		fmt.tprintf("expected the override to empty the directory, got %v", empty),
	)
}

@(test)
testRouterOrphanScanDeletesAFewOrphansAmongManyFiles :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	// 15 of 200: over the floor, within 10%.
	outcome := orphanTestRun({files = 200, rows = 185})
	assert(
		outcome.deleteSent && outcome.deleted == 15 && outcome.left == 185 && outcome.kept == 0,
		fmt.tprintf("expected the 15 orphans deleted, got %v", outcome),
	)
}

@(test)
testRouterOrphanScanDoesNotCountTheStartupSweepsFiles :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	// The sweep deletes 12 of 30 rows while the scan runs: their files are the sweep's, not
	// orphans, so no guard trips and the scan deletes nothing itself.
	outcome := orphanTestRun({files = 30, rows = 18, swept = 12})
	assert(
		!outcome.deleteSent && outcome.left == 18 && outcome.kept == 0 && outcome.found == 0,
		fmt.tprintf("expected only the sweep's files gone and no warning, got %v", outcome),
	)
	// A real orphan beside the sweep's files still goes.
	mixed := orphanTestRun({files = 30, rows = 17, swept = 12})
	assert(
		mixed.deleteSent && mixed.deleted == 1 && mixed.left == 17 && mixed.kept == 0,
		fmt.tprintf("expected the one orphan deleted, got %v", mixed),
	)
}

@(test)
testAttachmentOrphanGuardBoundsAndWarnings :: proc(t: ^testing.T) {
	_ = t
	assert(
		ATTACHMENT_ORPHAN_PURGE_MAX_SHARE_PERCENT == 10 && ATTACHMENT_ORPHAN_PURGE_FLOOR == 10,
		"expected the documented share (10%) and floor (10 files)",
	)
	cases := []struct {
		scanned, orphans: int,
		tableEmpty:       bool,
		allowPurge:       bool,
		expected:         AttachmentOrphanGuard,
	} {
		{0, 0, true, false, .Delete}, // nothing scanned: nothing to keep
		{5, 0, false, false, .Delete},
		{1, 1, true, false, .KeepEmptyTable},
		{1, 1, true, true, .Delete},
		{11, 11, false, false, .KeepOverShare},
		{11, 10, false, false, .Delete}, // the floor
		{110, 11, false, false, .Delete}, // exactly 10%
		{109, 11, false, false, .KeepOverShare}, // just over 10%
		{109, 11, false, true, .Delete},
	}
	for c in cases {
		guard := attachmentOrphanGuard(c.scanned, c.orphans, c.tableEmpty, c.allowPurge)
		assert(guard == c.expected, fmt.tprintf("expected %v for %v, got %v", c.expected, c, guard))
	}

	empty := attachmentOrphanGuardWarning(.KeepEmptyTable, 7, 7)
	defer delete(empty)
	share := attachmentOrphanGuardWarning(.KeepOverShare, 30, 11)
	defer delete(share)
	for warning in ([]string{empty, share}) {
		assert(
			strings.contains(warning, "deploy/README.md (Restoring)") &&
			strings.contains(warning, "HAYCHAT_ATTACHMENT_ALLOW_ORPHAN_PURGE=1"),
			fmt.tprintf("expected the warning to name the procedure and the override: %q", warning),
		)
	}
	assert(strings.contains(empty, "holds 7 files"), fmt.tprintf("expected the count: %q", empty))
	assert(
		strings.contains(share, "11 of the 30 files") && strings.contains(share, "10%"),
		fmt.tprintf("expected the counts and the share: %q", share),
	)
	assert(attachmentOrphanGuardWarning(.Delete, 1, 1) == "", "expected no warning to delete")
}
