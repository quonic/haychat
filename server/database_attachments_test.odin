package server

import "../common"
import "core:fmt"
import "core:os"
import "core:testing"
import "shared:pg"

// The attachment statements against a migrated schema of their own (HAYCHAT_DATABASE_SQL_TEST=1,
// database_attachments.odin): every refusal of the begin statement, the upload steps, the F1
// download check, the sweeper's rules and the startup scan's lookup.

@(private = "file")
AttachmentSQLTestLimits :: struct {
	maxBytes, quota, perHour, capacity: i64,
}

ATTACHMENT_SQL_TEST_DEFAULT_LIMITS :: AttachmentSQLTestLimits {
	maxBytes = 1_000_000,
}

@(private = "file")
attachmentSQLTestBlob :: proc() -> common.AttachmentBlobID {
	blobId: common.AttachmentBlobID
	assert(common.generateRandomBytes(blobId[:]), "expected a random blob ID")
	blobId[0] |= 1
	return blobId
}

@(private = "file")
attachmentSQLTestRun :: proc(
	conn: pg.Conn,
	request: common.DatabaseAttachmentRequest,
) -> common.DatabaseAttachmentResult {
	response := databaseExecuteRequest(conn, request)
	assert(response.success, fmt.tprintf("expected %v to run: %s", request.action, response.message))
	result, ok := response.result.(common.DatabaseAttachmentResult)
	assert(ok, "expected an attachment result")
	copied := result
	copied.blobs = make([dynamic]common.DatabaseAttachmentBlob, context.temp_allocator)
	append(&copied.blobs, ..result.blobs[:])
	IPC__database_query_response_deinit(response)
	return copied
}

@(private = "file")
attachmentSQLTestBegin :: proc(
	conn: pg.Conn,
	userID: int,
	size: u64,
	roomID := 0,
	recipientID := 0,
	encrypted := false,
	limits := ATTACHMENT_SQL_TEST_DEFAULT_LIMITS,
	blobOut: ^common.AttachmentBlobID = nil,
) -> common.DatabaseAttachmentOutcome {
	blobId := attachmentSQLTestBlob()
	if blobOut != nil {
		blobOut^ = blobId
	}
	result := attachmentSQLTestRun(
		conn,
		common.DatabaseAttachmentRequest {
			action = .Begin,
			userId = userID,
			blobId = blobId,
			roomId = roomID,
			recipientUserId = recipientID,
			encrypted = encrypted,
			size = size,
			maxBytes = limits.maxBytes,
			quotaBytes = limits.quota,
			bytesPerHour = limits.perHour,
			capacityBytes = limits.capacity,
		},
	)
	return result.outcome
}

@(private = "file")
attachmentSQLTestAction :: proc(
	conn: pg.Conn,
	action: common.DatabaseAttachmentAction,
	userID: int,
	blobId: common.AttachmentBlobID,
	size: u64 = 0,
) -> common.DatabaseAttachmentResult {
	return attachmentSQLTestRun(
		conn,
		common.DatabaseAttachmentRequest{action = action, userId = userID, blobId = blobId, size = size},
	)
}

@(private = "file")
attachmentSQLTestHex :: proc(blobId: common.AttachmentBlobID) -> string {
	id := blobId
	hex := common.encodeBytesToHex(id[:])
	defer delete(hex)
	return fmt.tprintf("%s", hex)
}

@(private = "file")
attachmentSQLTestState :: proc(conn: pg.Conn, blobId: common.AttachmentBlobID) -> string {
	return databaseAdminTestValue(
		conn,
		fmt.tprintf(
			"SELECT COALESCE((SELECT state::text FROM attachments WHERE blob_id = " +
			"decode('%s', 'hex')), 'none')",
			attachmentSQLTestHex(blobId),
		),
	)
}

@(private = "file")
attachmentSQLTestAge :: proc(
	conn: pg.Conn,
	blobId: common.AttachmentBlobID,
	createdHoursAgo, lastChunkHoursAgo: int,
) {
	databaseDefaultRoomTestExec(
		conn,
		"age an attachment",
		fmt.tprintf(
			"UPDATE attachments SET created_at = now() - make_interval(hours => %d), " +
			"last_chunk_at = now() - make_interval(hours => %d) WHERE blob_id = decode('%s', 'hex')",
			createdHoursAgo,
			lastChunkHoursAgo,
			attachmentSQLTestHex(blobId),
		),
	)
}

@(private = "file")
attachmentSQLTestRoom :: proc(conn: pg.Conn, name: string, roomType := 3, encrypted := false) -> int {
	value := databaseAdminTestValue(
		conn,
		fmt.tprintf(
			"INSERT INTO rooms (name, access, room_type, encrypted) VALUES ('%s', 2, %d, %v) " +
			"RETURNING id::text",
			name,
			roomType,
			encrypted,
		),
	)
	id, ok := databaseParseTestInt(value)
	assert(ok, fmt.tprintf("expected a room ID, got %q", value))
	return id
}

@(private = "file")
attachmentSQLTestJoin :: proc(conn: pg.Conn, roomID, userID: int) {
	databaseDefaultRoomTestExec(
		conn,
		"join a room",
		fmt.tprintf("INSERT INTO room_members (room_id, user_id) VALUES (%d, %d)", roomID, userID),
	)
}

// D11, D21: membership, Send, chat, encryption, the direct message recipient and visibility,
// size, quota, the hourly rate and the capacity, each refused by the begin statement itself.
@(test)
testAttachmentBeginStatementAgainstPostgreSQL :: proc(t: ^testing.T) {
	_ = t
	if os.get_env(DATABASE_SQL_TEST_ENV, context.temp_allocator) != "1" {
		return
	}
	conn := databaseAdminTestOpen(t, "attachment_begin")
	alice := databaseAdminTestUser(conn, "att-alice")
	bob := databaseAdminTestUser(conn, "att-bob")
	carol := databaseAdminTestUser(conn, "att-carol")
	dave := databaseAdminTestUser(conn, "att-dave")
	databaseAdminTestGrant(conn, dave)
	databaseDefaultRoomTestExec(
		conn,
		"restrict carol",
		fmt.tprintf("UPDATE users SET restricted = true WHERE id = %d", carol),
	)
	files := attachmentSQLTestRoom(conn, "att-files")
	voiceOnly := attachmentSQLTestRoom(conn, "att-voice", roomType = 2)
	secret := attachmentSQLTestRoom(conn, "att-secret", encrypted = true)
	for room in ([]int{files, voiceOnly, secret}) {
		attachmentSQLTestJoin(conn, room, alice)
	}
	attachmentSQLTestJoin(conn, files, bob)

	blob: common.AttachmentBlobID
	outcome := attachmentSQLTestBegin(conn, alice, 1000, roomID = files, blobOut = &blob)
	assert(outcome == .Applied, fmt.tprintf("expected a member's upload, got %v", outcome))
	assert(attachmentSQLTestState(conn, blob) == "0", "expected the blob Uploading")
	assert(
		attachmentSQLTestBegin(conn, carol, 10, roomID = files) == .NotMember,
		"expected a non-member refused",
	)
	assert(
		attachmentSQLTestBegin(conn, alice, 10, roomID = 999_999) == .NotMember,
		"expected a missing room refused as not a member",
	)

	// Send is required (and AttachFiles from F2 on); an admin holds every room permission.
	databaseDefaultRoomTestExec(
		conn,
		"revoke send",
		fmt.tprintf("UPDATE rooms SET everyone_permissions = 2 WHERE id = %d", files),
	)
	assert(
		attachmentSQLTestBegin(conn, alice, 10, roomID = files) == .SendDenied,
		"expected a member without Send refused",
	)
	attachmentSQLTestJoin(conn, files, dave)
	assert(
		attachmentSQLTestBegin(conn, dave, 10, roomID = files) == .Applied,
		"expected an admin member allowed without the everyone grant",
	)
	databaseDefaultRoomTestExec(
		conn,
		"restore send",
		fmt.tprintf("UPDATE rooms SET everyone_permissions = 3 WHERE id = %d", files),
	)
	assert(
		attachmentSQLTestBegin(conn, alice, 10, roomID = voiceOnly) == .ChatDisabled,
		"expected a voice-only room refused",
	)
	assert(
		attachmentSQLTestBegin(conn, alice, 10, roomID = secret) == .EncryptionMismatch,
		"expected a plaintext upload to an encrypted room refused",
	)
	assert(
		attachmentSQLTestBegin(conn, alice, 10, roomID = secret, encrypted = true) == .Applied,
		"expected an encrypted upload to an encrypted room",
	)
	assert(
		attachmentSQLTestBegin(conn, alice, 10, roomID = files, encrypted = true) ==
		.EncryptionMismatch,
		"expected an encrypted upload to a plaintext room refused",
	)

	// Direct messages: the recipient must exist, not be the owner, and be someone the owner may
	// meet (D17): a restricted account only once a room is shared.
	assert(
		attachmentSQLTestBegin(conn, alice, 10, recipientID = bob) == .Applied,
		"expected an upload to a direct conversation",
	)
	assert(
		attachmentSQLTestBegin(conn, alice, 10, recipientID = 999_999) == .UnknownRecipient,
		"expected an unknown recipient refused",
	)
	assert(
		attachmentSQLTestBegin(conn, alice, 10, recipientID = alice) == .UnknownRecipient,
		"expected an upload to oneself refused",
	)
	assert(
		attachmentSQLTestBegin(conn, alice, 10, recipientID = carol) == .Restricted,
		"expected a restricted recipient without a shared room refused",
	)
	attachmentSQLTestJoin(conn, voiceOnly, carol)
	assert(
		attachmentSQLTestBegin(conn, alice, 10, recipientID = carol) == .Applied,
		"expected a restricted recipient in a shared room allowed",
	)
	assert(
		attachmentSQLTestBegin(conn, alice, 10, roomID = files, recipientID = bob) == .NotFound,
		"expected a room and a recipient at once to store nothing",
	)

	// Size, quota, hourly rate, capacity. A tombstone frees quota but not the hour's rate.
	assert(
		attachmentSQLTestBegin(conn, bob, 1_000_001, roomID = files) == .TooLarge,
		"expected a blob over the size limit refused",
	)
	quota := AttachmentSQLTestLimits {
		maxBytes = 1_000_000,
		quota    = 1000,
	}
	first: common.AttachmentBlobID
	assert(
		attachmentSQLTestBegin(conn, bob, 600, roomID = files, limits = quota, blobOut = &first) ==
		.Applied,
		"expected an upload inside the quota",
	)
	assert(
		attachmentSQLTestBegin(conn, bob, 600, roomID = files, limits = quota) == .QuotaExceeded,
		"expected the declared size reserved against the quota",
	)
	abandoned := attachmentSQLTestAction(conn, .Abandon, bob, first)
	assert(abandoned.outcome == .Applied, "expected the upload abandoned")
	assert(attachmentSQLTestState(conn, first) == "3", "expected a tombstone")
	assert(
		attachmentSQLTestBegin(conn, bob, 600, roomID = files, limits = quota) == .Applied,
		"expected a tombstone to free its quota",
	)
	rate := AttachmentSQLTestLimits {
		maxBytes = 1_000_000,
		perHour  = 1700,
	}
	assert(
		attachmentSQLTestBegin(conn, bob, 600, roomID = files, limits = rate) == .RateExceeded,
		"expected the hour's uploads, tombstones included, counted against the rate",
	)
	databaseDefaultRoomTestExec(
		conn,
		"age bob's uploads",
		fmt.tprintf(
			"UPDATE attachments SET created_at = now() - interval '2 hours' WHERE owner_user_id = %d",
			bob,
		),
	)
	assert(
		attachmentSQLTestBegin(conn, bob, 600, roomID = files, limits = rate) == .Applied,
		"expected last hour's uploads outside the rate",
	)
	stored := databaseAdminTestValue(
		conn,
		"SELECT COALESCE(sum(size), 0)::text FROM attachments WHERE state <> 3",
	)
	total, totalOK := databaseParseTestInt(stored)
	assert(totalOK, "expected the stored total")
	capacity := AttachmentSQLTestLimits {
		maxBytes = 1_000_000,
		capacity = i64(total + 5),
	}
	assert(
		attachmentSQLTestBegin(conn, bob, 5, roomID = files, limits = capacity) == .Applied,
		"expected an upload that fits the capacity",
	)
	assert(
		attachmentSQLTestBegin(conn, bob, 1, roomID = files, limits = capacity) ==
		.CapacityExceeded,
		"expected the capacity refused once full",
	)
}

// Resume, progress, finish, the F1 download check, delete-new and abandon.
@(test)
testAttachmentUploadStepsAgainstPostgreSQL :: proc(t: ^testing.T) {
	_ = t
	if os.get_env(DATABASE_SQL_TEST_ENV, context.temp_allocator) != "1" {
		return
	}
	conn := databaseAdminTestOpen(t, "attachment_steps")
	alice := databaseAdminTestUser(conn, "att-alice")
	bob := databaseAdminTestUser(conn, "att-bob")
	room := attachmentSQLTestRoom(conn, "att-room")
	attachmentSQLTestJoin(conn, room, alice)
	attachmentSQLTestJoin(conn, room, bob)

	blob: common.AttachmentBlobID
	assert(
		attachmentSQLTestBegin(conn, alice, 5000, roomID = room, blobOut = &blob) == .Applied,
		"expected a new upload",
	)
	progress := attachmentSQLTestAction(conn, .Progress, alice, blob, 2000)
	assert(progress.outcome == .Applied, "expected the progress recorded")
	resumed := attachmentSQLTestAction(conn, .Resume, alice, blob)
	assert(
		resumed.outcome == .Applied && resumed.size == 5000 && resumed.received == 2000,
		fmt.tprintf("expected the resume to see the size and progress, got %v", resumed),
	)
	assert(
		attachmentSQLTestAction(conn, .Resume, bob, blob).outcome == .NotFound,
		"expected nobody but the owner to resume",
	)
	assert(
		attachmentSQLTestAction(conn, .DownloadCheck, alice, blob).outcome == .NotFound,
		"expected an unfinished blob not downloadable",
	)
	assert(
		attachmentSQLTestAction(conn, .DeleteNew, alice, blob).outcome == .NotFound,
		"expected a written-to upload never deleted as new",
	)

	sha: common.AttachmentSHA256
	sha[0] = 0x5a
	wrongSize := attachmentSQLTestRun(
		conn,
		common.DatabaseAttachmentRequest {
			action = .Finish,
			userId = alice,
			blobId = blob,
			size = 4999,
			sha256 = sha,
		},
	)
	assert(wrongSize.outcome == .NotFound, "expected a finish of the wrong size refused")
	finished := attachmentSQLTestRun(
		conn,
		common.DatabaseAttachmentRequest {
			action = .Finish,
			userId = alice,
			blobId = blob,
			size = 5000,
			sha256 = sha,
		},
	)
	assert(finished.outcome == .Applied && finished.size == 5000, "expected the blob Ready")
	assert(attachmentSQLTestState(conn, blob) == "1", "expected state Ready")
	download := attachmentSQLTestAction(conn, .DownloadCheck, alice, blob)
	assert(
		download.outcome == .Applied && download.size == 5000 && download.sha256 == sha,
		fmt.tprintf("expected the owner to download its blob, got %v", download),
	)
	assert(
		attachmentSQLTestAction(conn, .DownloadCheck, bob, blob).outcome == .NotFound,
		"expected F1 to refuse every account but the owner",
	)
	assert(
		attachmentSQLTestAction(conn, .Resume, alice, blob).outcome == .NotFound,
		"expected a finished blob not resumable",
	)
	assert(
		attachmentSQLTestAction(conn, .Abandon, alice, blob).outcome == .NotFound,
		"expected a finished blob not abandoned by a cancel",
	)

	fresh: common.AttachmentBlobID
	assert(
		attachmentSQLTestBegin(conn, alice, 10, roomID = room, blobOut = &fresh) == .Applied,
		"expected a new upload",
	)
	assert(
		attachmentSQLTestAction(conn, .DeleteNew, bob, fresh).outcome == .NotFound,
		"expected only the owner's blob deleted",
	)
	assert(
		attachmentSQLTestAction(conn, .DeleteNew, alice, fresh).outcome == .Applied,
		"expected an unwritten upload deleted",
	)
	assert(attachmentSQLTestState(conn, fresh) == "none", "expected the row gone")
}

// D17: what the sweeper deletes and keeps, and the startup scan's lookup.
@(test)
testAttachmentSweeperAgainstPostgreSQL :: proc(t: ^testing.T) {
	_ = t
	if os.get_env(DATABASE_SQL_TEST_ENV, context.temp_allocator) != "1" {
		return
	}
	conn := databaseAdminTestOpen(t, "attachment_sweep")
	alice := databaseAdminTestUser(conn, "att-alice")
	room := attachmentSQLTestRoom(conn, "att-room")
	attachmentSQLTestJoin(conn, room, alice)

	Case :: struct {
		name:                      string,
		state:                     int, // 0 Uploading, 1 Ready, 2 Bound, 3 Removed
		createdAgo, lastChunkAgo: int,
		bound:                     bool, // bound to a message that still exists
		swept:                     bool,
	}
	cases := []Case {
		{"young upload", 0, 0, 0, false, false},
		{"stale upload", 0, 2, 2, false, true},
		{"active upload", 0, 2, 0, false, false},
		{"upload past the window", 0, 25, 0, false, true},
		{"ready within the window", 1, 2, 2, false, false},
		{"ready past the window", 1, 25, 25, false, true},
		{"bound", 2, 30, 30, true, false},
		{"bound, message gone", 2, 2, 2, false, true},
		{"young tombstone", 3, 0, 0, false, false},
		{"old tombstone", 3, 2, 2, false, true},
		{"bound tombstone", 3, 30, 30, true, false},
	}
	blobs := make([]common.AttachmentBlobID, len(cases), context.temp_allocator)
	for c, index in cases {
		assert(
			attachmentSQLTestBegin(conn, alice, 10, roomID = room, blobOut = &blobs[index]) ==
			.Applied,
			"expected a row",
		)
		messageLink := "NULL"
		if c.bound {
			messageLink = databaseAdminTestValue(
				conn,
				fmt.tprintf(
					"INSERT INTO chat_messages (room_id, sender_user_id, content, " +
					"client_message_id, signature) VALUES (%d, %d, 'file', " +
					DATABASE_TEST_PLAIN_COLUMNS_SQL +
					") RETURNING id::text",
					room,
					alice,
				),
			)
		}
		databaseDefaultRoomTestExec(
			conn,
			"set the state",
			fmt.tprintf(
				"UPDATE attachments SET state = %d, chat_message_id = %s WHERE blob_id = " +
				"decode('%s', 'hex')",
				c.state,
				messageLink,
				attachmentSQLTestHex(blobs[index]),
			),
		)
		attachmentSQLTestAge(conn, blobs[index], c.createdAgo, c.lastChunkAgo)
	}
	// "bound, message gone": its message existed and was deleted, which cleared the link.
	gone := databaseAdminTestValue(
		conn,
		fmt.tprintf(
			"INSERT INTO chat_messages (room_id, sender_user_id, content, client_message_id, " +
			"signature) VALUES (%d, %d, 'gone', " +
			DATABASE_TEST_PLAIN_COLUMNS_SQL +
			") RETURNING id::text",
			room,
			alice,
		),
	)
	databaseDefaultRoomTestExec(
		conn,
		"bind and delete",
		fmt.tprintf(
			"UPDATE attachments SET chat_message_id = %s WHERE blob_id = decode('%s', 'hex'); " +
			"DELETE FROM chat_messages WHERE id = %s",
			gone,
			attachmentSQLTestHex(blobs[7]),
			gone,
		),
	)
	// A blob with a live transfer is never swept, whatever its age.
	excluded := attachmentSQLTestBlob()
	assert(
		attachmentSQLTestBegin(conn, alice, 10, roomID = room, blobOut = &excluded) == .Applied,
		"expected a row",
	)
	attachmentSQLTestAge(conn, excluded, 5, 5)

	exclusions := make([dynamic]common.AttachmentBlobID)
	append(&exclusions, excluded)
	response := databaseExecuteRequest(
		conn,
		common.DatabaseAttachmentRequest {
			action = .Sweep,
			pendingHours = 24,
			limit = 100,
			blobIds = exclusions,
		},
	)
	delete(exclusions)
	assert(response.success, fmt.tprintf("expected the sweep to run: %s", response.message))
	swept := response.result.(common.DatabaseAttachmentResult)
	for c, index in cases {
		found := false
		for blob in swept.blobs {
			if blob.blobId == blobs[index] {
				found = true
				assert(int(blob.state) == c.state, fmt.tprintf("expected %s's state", c.name))
			}
		}
		assert(
			found == c.swept,
			fmt.tprintf("expected %q %s", c.name, c.swept ? "swept" : "kept"),
		)
		assert(
			(attachmentSQLTestState(conn, blobs[index]) == "none") == c.swept,
			fmt.tprintf("expected %q's row %s", c.name, c.swept ? "deleted" : "kept"),
		)
	}
	IPC__database_query_response_deinit(response)
	assert(attachmentSQLTestState(conn, excluded) == "0", "expected the live transfer kept")

	// The startup scan's lookup: only blobs with a row, with their states.
	lookup := make([dynamic]common.AttachmentBlobID)
	append(&lookup, blobs[0], blobs[1], blobs[6], attachmentSQLTestBlob())
	knownResponse := databaseExecuteRequest(
		conn,
		common.DatabaseAttachmentRequest{action = .Known, blobIds = lookup},
	)
	delete(lookup)
	known := knownResponse.result.(common.DatabaseAttachmentResult)
	assert(
		knownResponse.success && len(known.blobs) == 2,
		fmt.tprintf("expected the two rows that remain, got %v", known.blobs),
	)
	for blob in known.blobs {
		assert(
			(blob.blobId == blobs[0] && blob.state == .Uploading) ||
			(blob.blobId == blobs[6] && blob.state == .Bound),
			fmt.tprintf("expected the young upload and the bound blob, got %v", blob),
		)
	}
	IPC__database_query_response_deinit(knownResponse)
}
