package server

import "../common"
import "core:fmt"
import "core:strings"
import "core:time"

// Files missing from storage (#132 follow-up). The server is not a backup of uploaded files:
// when a download finds a Ready or Bound blob's file gone (the storage worker's read answers
// StorageReadData.missing, ENOENT), the reader is refused with "Attachment not found" (#132) and
// the row becomes the same Removed tombstone an admin removal leaves
// (DATABASE_ATTACHMENT_MARK_MISSING_SQL: signed fields and message link kept, an
// attachment_removals row with no admin and ATTACHMENT_MISSING_REMOVAL_REASON), its readers
// get ServerAttachmentRemoved, and later downloads are refused at the check without a disk
// read. Guards keep a mount problem from turning many rows into tombstones at once:
//
// - The storage worker marks a missing read blobDirectoryIntact only when blobs/ is a readable
//   directory with entries and the blob's shard directory exists. Otherwise the router marks
//   nothing and logs a warning each time.
// - At most ATTACHMENT_MISSING_MARKS_PER_WINDOW marks per ATTACHMENT_MISSING_MARK_WINDOW (the
//   window starts at the first mark after the last one ended, and the count lives in memory, so
//   a restart starts a new one). Past it the router marks nothing, logs once per window, and
//   keeps refusing with "Attachment not found".
//
// What is not marked stays exactly as #132 left it: the download check passes the row and each
// later download reads the disk again.

ATTACHMENT_MISSING_MARKS_PER_WINDOW :: 10
ATTACHMENT_MISSING_MARK_WINDOW :: time.Hour

AttachmentMissingGuard :: struct {
	windowStart: time.Tick,
	marks:       int, // marks sent in the window, answered or not
	capLogged:   bool, // the cap's warning was logged in this window
	// Marks the database has not answered, so a second download of the same blob does not
	// spend another mark. Owned (RouterAttachmentState_deinit).
	marking:     map[common.AttachmentBlobID]bool,
}

AttachmentMissingDecision :: enum u8 {
	Mark, // send the mark (counted in the window)
	AlreadyMarking, // a mark of this blob is in the database already
	StorageSuspect, // the blob directory does not look intact: mark nothing
	CapReached, // the window's marks are spent: mark nothing
}

// Decides whether a missing file's row may be marked now, and counts the mark when it may.
// logCap is true the first time in a window that the cap stops a mark.
attachmentMissingDecide :: proc(
	guard: ^AttachmentMissingGuard,
	blobId: common.AttachmentBlobID,
	blobDirectoryIntact: bool,
	now: time.Tick,
) -> (
	decision: AttachmentMissingDecision,
	logCap: bool,
) {
	if !blobDirectoryIntact {
		return .StorageSuspect, false
	}
	if blobId in guard.marking {
		return .AlreadyMarking, false
	}
	if guard.marks == 0 ||
	   time.tick_diff(guard.windowStart, now) >= ATTACHMENT_MISSING_MARK_WINDOW {
		guard.windowStart = now
		guard.marks = 0
		guard.capLogged = false
	}
	if guard.marks >= ATTACHMENT_MISSING_MARKS_PER_WINDOW {
		logCap = !guard.capLogged
		guard.capLogged = true
		return .CapReached, logCap
	}
	guard.marks += 1
	guard.marking[blobId] = true
	return .Mark, false
}

// A download found blobId's file missing (the reader was refused already): marks its row a
// Removed tombstone when the guards allow it.
MainRouterState_attachmentFileMissing :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	blobId: common.AttachmentBlobID,
	blobDirectoryIntact: bool,
	now: time.Tick,
) {
	decision, logCap := attachmentMissingDecide(
		&state.attachments.missing,
		blobId,
		blobDirectoryIntact,
		now,
	)
	switch decision {
	case .Mark:
		attachmentDatabaseSend(
			pm,
			state,
			0,
			common.DatabaseAttachmentRequest {
				action = .MarkMissing,
				blobId = blobId,
				reason = strings.clone(ATTACHMENT_MISSING_REMOVAL_REASON),
			},
			{},
		)
	case .AlreadyMarking:
	case .StorageSuspect:
		fmt.printfln(
			"[Attachments] WARNING: the blob directory looks absent or incomplete (no " +
			"readable blobs/ with entries, or no shard directory for attachment %s): not " +
			"marking it removed. Check that HAYCHAT_ATTACHMENT_DIR is mounted.",
			storageBlobHex(blobId, context.temp_allocator),
		)
	case .CapReached:
		if logCap {
			fmt.printfln(
				"[Attachments] WARNING: %d attachments whose files are missing from storage " +
				"were marked removed within an hour; marking no more until the hour ends " +
				"(downloads of missing files are still refused). Check " +
				"HAYCHAT_ATTACHMENT_DIR.",
				ATTACHMENT_MISSING_MARKS_PER_WINDOW,
			)
		}
	}
}

// The mark's answer: when applied, every download of the blob ends and each reader the
// statement named hears ServerAttachmentRemoved, as for an admin's removal. The file is already
// gone, so no StorageDeleteBlobs follows (should it come back, the hourly tombstone pass and
// the startup scan delete it). NotFound (an admin removal, a message delete or a sweep came
// first) changes nothing.
MainRouterState_attachmentMarkMissingResult :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	request: PendingDBRequest,
	result: common.DatabaseAttachmentResult,
) {
	blobId := request.blobID
	delete_key(&state.attachments.missing.marking, blobId)
	if result.outcome != .Applied {
		return
	}
	removal := result.removal
	fmt.printfln(
		"[Attachments] Attachment %s of user %d marked removed: %s",
		storageBlobHex(blobId, context.temp_allocator),
		removal.ownerUserId,
		ATTACHMENT_MISSING_REMOVAL_REASON,
	)
	MainRouterState_attachmentCancelDownloads(pm, state, blobId, common.ATTACHMENT_REMOVED_MESSAGE)
	MainRouterState_attachmentSendRemoved(pm, state, blobId, removal)
}
