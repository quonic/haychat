package server

import "../common"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "shared:pg"

// The attachment statements against a migrated schema of their own (HAYCHAT_DATABASE_SQL_TEST=1,
// database_attachments.odin): every refusal of the begin statement, the upload steps, the
// download check (D10, protocol 27), the sweeper's rules and the startup scan's lookup, and
// (protocol 27) binding blobs in the room message insert.

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
	assert(
		response.success,
		fmt.tprintf("expected %v to run: %s", request.action, response.message),
	)
	result, ok := response.result.(common.DatabaseAttachmentResult)
	assert(ok, "expected an attachment result")
	copied := result
	copied.blobs = make([dynamic]common.DatabaseAttachmentBlob, context.temp_allocator)
	append(&copied.blobs, ..result.blobs[:])
	copied.removal.readerUserIds = make([dynamic]int, context.temp_allocator)
	append(&copied.removal.readerUserIds, ..result.removal.readerUserIds[:])
	copied.accounts = make([dynamic]common.AttachmentAccountUsage, context.temp_allocator)
	append(&copied.accounts, ..result.accounts[:])
	copied.removals = make([dynamic]common.AttachmentRemovalEntry, context.temp_allocator)
	for entry in result.removals {
		kept := entry
		kept.removedAt = strings.clone(entry.removedAt, context.temp_allocator)
		kept.reason = strings.clone(entry.reason, context.temp_allocator)
		kept.name = strings.clone(entry.name, context.temp_allocator)
		append(&copied.removals, kept)
	}
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
		common.DatabaseAttachmentRequest {
			action = action,
			userId = userID,
			blobId = blobId,
			size = size,
		},
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
			"last_chunk_at = now() - make_interval(hours => %d) " +
			"WHERE blob_id = decode('%s', 'hex')",
			createdHoursAgo,
			lastChunkHoursAgo,
			attachmentSQLTestHex(blobId),
		),
	)
}

@(private = "file")
attachmentSQLTestRoom :: proc(
	conn: pg.Conn,
	name: string,
	roomType := 3,
	encrypted := false,
) -> int {
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
	// Protocol 27 (D20): AttachFiles is required too, reported apart from Send.
	databaseDefaultRoomTestExec(
		conn,
		"revoke attach files",
		fmt.tprintf("UPDATE rooms SET everyone_permissions = 3 WHERE id = %d", files),
	)
	assert(
		attachmentSQLTestBegin(conn, alice, 10, roomID = files) == .AttachDenied,
		"expected a member without AttachFiles refused",
	)
	databaseDefaultRoomTestExec(
		conn,
		"restore send and attach files",
		fmt.tprintf("UPDATE rooms SET everyone_permissions = 19 WHERE id = %d", files),
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
	// meet (D17): a restricted account only once a room is shared. One the owner does not know
	// (no shared room, no conversation) is refused as unknown (#103).
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
		attachmentSQLTestBegin(conn, alice, 10, recipientID = carol) == .UnknownRecipient,
		"expected a restricted recipient without a shared room refused as unknown",
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
			"UPDATE attachments SET created_at = now() - interval '2 hours' " +
			"WHERE owner_user_id = %d",
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

// Resume, progress, finish, the owner's download of its unbound blob, delete-new and abandon.
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
		"expected an unbound blob refused to every account but the owner",
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
	assert(!known.tableEmpty, "expected a table with rows not reported empty")
	IPC__database_query_response_deinit(knownResponse)

	// #131: whether the table has any row decides the empty-table guard, even when none of the
	// scanned files has one.
	for empty in ([]bool{false, true}) {
		if empty {
			databaseDefaultRoomTestExec(conn, "empty the table", "DELETE FROM attachments")
		}
		unknown := make([dynamic]common.AttachmentBlobID)
		append(&unknown, attachmentSQLTestBlob(), attachmentSQLTestBlob())
		response := databaseExecuteRequest(
			conn,
			common.DatabaseAttachmentRequest{action = .Known, blobIds = unknown},
		)
		delete(unknown)
		result := response.result.(common.DatabaseAttachmentResult)
		assert(
			response.success && len(result.blobs) == 0 && result.tableEmpty == empty,
			fmt.tprintf("expected no rows and tableEmpty %v, got %v", empty, result),
		)
		IPC__database_query_response_deinit(response)
	}
}

// ── Protocol 27: binding, the D10 download check, room deletion ────────────────

// A Ready blob of owner's in a room or a direct conversation, with its hash.
@(private = "file")
attachmentSQLTestReady :: proc(
	conn: pg.Conn,
	owner: int,
	size: u64,
	roomID := 0,
	recipientID := 0,
	encrypted := false,
) -> (
	blob: common.AttachmentBlobID,
	sha: common.AttachmentSHA256,
) {
	outcome := attachmentSQLTestBegin(
		conn,
		owner,
		size,
		roomID = roomID,
		recipientID = recipientID,
		encrypted = encrypted,
		blobOut = &blob,
	)
	assert(outcome == .Applied, fmt.tprintf("expected the upload to begin, got %v", outcome))
	assert(common.generateRandomBytes(sha[:]), "expected a random hash")
	finished := attachmentSQLTestRun(
		conn,
		common.DatabaseAttachmentRequest {
			action = .Finish,
			userId = owner,
			blobId = blob,
			size = size,
			sha256 = sha,
		},
	)
	assert(finished.outcome == .Applied, "expected the blob Ready")
	return
}

// A plaintext reference to a blob, as a message lists it.
@(private = "file")
attachmentSQLTestRef :: proc(
	blob: common.AttachmentBlobID,
	size: u64,
	sha: common.AttachmentSHA256,
	name := "notes.txt",
	sealed := false,
) -> common.AttachmentRef {
	if sealed {
		return common.AttachmentRef{blobId = blob, size = size}
	}
	return common.AttachmentRef {
		blobId = blob,
		size = size,
		sha256 = sha,
		name = name,
		mediaType = "text/plain",
	}
}

// Posts a room message with refs (plaintext, or sealed at the room's epoch 1) and returns the
// outcome flags and the stored ID.
@(private = "file")
attachmentSQLTestPost :: proc(
	conn: pg.Conn,
	roomID, senderID: int,
	content: string,
	refs: []common.AttachmentRef,
	sealed := false,
) -> (
	posted: common.DatabasePostRoomChatMessageResult,
	messageID: int,
) {
	request := common.DatabasePostRoomChatMessageRequest {
		roomId          = roomID,
		senderId        = senderID,
		content         = strings.clone(content),
		clientMessageId = databaseTestClientMessageID(),
		attachments     = common.AttachmentRefs_clone(refs),
	}
	if sealed {
		request.sealed = make([]u8, 96)
		for index in 0 ..< len(request.sealed) {
			request.sealed[index] = u8(index)
		}
		request.epoch = 1
		assert(common.generateRandomBytes(request.chainId[:]), "expected a chain ID")
	} else {
		request.signature = DATABASE_TEST_SIGNATURE
	}
	defer IPC__database_query_request_deinit(request)
	response := databaseExecuteRequest(conn, request)
	defer IPC__database_query_response_deinit(response)
	result, ok := response.result.(common.DatabasePostRoomChatMessageResult)
	assert(response.success && ok, fmt.tprintf("expected the post to run: %s", response.message))
	assert(
		!result.isMember || result.storedMessage.id == 0 ||
		len(result.storedMessage.attachments) == len(refs),
		"expected the echo to list the bound attachments",
	)
	posted = result
	messageID = result.storedMessage.id
	posted.storedMessage = {}
	posted.recipientUserIDs = nil
	return
}

@(private = "file")
attachmentSQLTestBinding :: proc(conn: pg.Conn, blob: common.AttachmentBlobID) -> string {
	return databaseAdminTestValue(
		conn,
		fmt.tprintf(
			"SELECT state::text || '/' || COALESCE(chat_message_id::text, '-') || '/' || " +
			"COALESCE(direct_message_id::text, '-') || '/' || COALESCE(position::text, '-') || " +
			"'/' || COALESCE(name, '-') || '/' || COALESCE(media_type, '-') || '/' || " +
			"(bound_at IS NOT NULL)::text FROM attachments WHERE blob_id = decode('%s', 'hex')",
			attachmentSQLTestHex(blob),
		),
	)
}

// D1, D11, D15, D20: the room message insert binds the blobs it lists, in the same statement,
// and refuses the whole message when one does not qualify.
@(test)
testAttachmentBindingInRoomMessagesAgainstPostgreSQL :: proc(t: ^testing.T) {
	_ = t
	if os.get_env(DATABASE_SQL_TEST_ENV, context.temp_allocator) != "1" {
		return
	}
	conn := databaseAdminTestOpen(t, "attachment_bind")
	alice := databaseAdminTestUser(conn, "bind-alice")
	bob := databaseAdminTestUser(conn, "bind-bob")
	files := attachmentSQLTestRoom(conn, "bind-files")
	other := attachmentSQLTestRoom(conn, "bind-other")
	secret := attachmentSQLTestRoom(conn, "bind-secret", encrypted = true)
	databaseDefaultRoomTestExec(
		conn,
		"start the encrypted room's log",
		fmt.tprintf("UPDATE rooms SET log_version = 1 WHERE id = %d", secret),
	)
	for room in ([]int{files, other, secret}) {
		attachmentSQLTestJoin(conn, room, alice)
		attachmentSQLTestJoin(conn, room, bob)
	}

	// A plaintext message binds its blob: Bound, linked, positioned, named.
	first, firstSHA := attachmentSQLTestReady(conn, alice, 1000, roomID = files)
	second, secondSHA := attachmentSQLTestReady(conn, alice, 2000, roomID = files)
	refs := [2]common.AttachmentRef {
		attachmentSQLTestRef(first, 1000, firstSHA, "a.txt"),
		attachmentSQLTestRef(second, 2000, secondSHA, "b.txt"),
	}
	posted, messageID := attachmentSQLTestPost(conn, files, alice, "", refs[:])
	assert(
		posted.isMember && messageID > 0,
		fmt.tprintf("expected an attachments-only message stored, got %v", posted),
	)
	assert(
		attachmentSQLTestBinding(conn, first) ==
		fmt.tprintf("2/%d/-/0/a.txt/text/plain/true", messageID),
		fmt.tprintf("expected the first blob bound, got %s", attachmentSQLTestBinding(conn, first)),
	)
	assert(
		attachmentSQLTestBinding(conn, second) ==
		fmt.tprintf("2/%d/-/1/b.txt/text/plain/true", messageID),
		"expected the second blob bound at position 1",
	)
	assert(
		databaseAdminTestValue(
			conn,
			fmt.tprintf(
				"SELECT attachment_count::text || '/' || content FROM chat_messages WHERE id = %d",
				messageID,
			),
		) ==
		"2/",
		"expected the count stored with an empty content",
	)
	// History lists them in order with every field, and the removed flag of a tombstone.
	databaseDefaultRoomTestExec(
		conn,
		"remove the second blob",
		fmt.tprintf(
			"UPDATE attachments SET state = 3 WHERE blob_id = decode('%s', 'hex')",
			attachmentSQLTestHex(second),
		),
	)
	history := databaseExecuteRequest(
		conn,
		common.DatabaseRoomHistoryRequest{roomId = files, userId = bob, limit = 10},
	)
	defer IPC__database_query_response_deinit(history)
	page := history.result.(common.DatabaseRoomHistoryResult)
	assert(len(page.messages) == 1, "expected the message in history")
	listed := page.messages[0].attachments
	assert(
		len(listed) == 2 &&
		listed[0].blobId == first &&
		listed[0].size == 1000 &&
		listed[0].sha256 == firstSHA &&
		listed[0].name == "a.txt" &&
		listed[0].mediaType == "text/plain" &&
		!listed[0].removed &&
		listed[1].blobId == second &&
		listed[1].removed,
		fmt.tprintf("expected both attachments in history, got %v", listed),
	)

	// Refusals: bound twice, someone else's blob, another room, a direct message's blob, an
	// unfinished upload, another size or hash, and a blob listed twice.
	refuse :: proc(conn: pg.Conn, room, sender: int, refs: []common.AttachmentRef, why: string) {
		result, id := attachmentSQLTestPost(conn, room, sender, "x", refs)
		assert(
			result.attachmentsRefused && id == 0,
			fmt.tprintf("expected %s refused, got %v", why, result),
		)
	}
	refuse(conn, files, alice, refs[:1], "a blob bound twice")
	bobs, bobSHA := attachmentSQLTestReady(conn, bob, 10, roomID = files)
	bobRef := [1]common.AttachmentRef{attachmentSQLTestRef(bobs, 10, bobSHA)}
	refuse(conn, files, alice, bobRef[:], "someone else's blob")
	elsewhere, elsewhereSHA := attachmentSQLTestReady(conn, alice, 10, roomID = other)
	elsewhereRef := [1]common.AttachmentRef{attachmentSQLTestRef(elsewhere, 10, elsewhereSHA)}
	refuse(conn, files, alice, elsewhereRef[:], "a blob of another room")
	direct, directSHA := attachmentSQLTestReady(conn, alice, 10, recipientID = bob)
	directRef := [1]common.AttachmentRef{attachmentSQLTestRef(direct, 10, directSHA)}
	refuse(conn, files, alice, directRef[:], "a direct message's blob")
	uploading: common.AttachmentBlobID
	assert(
		attachmentSQLTestBegin(conn, alice, 10, roomID = files, blobOut = &uploading) == .Applied,
		"expected an upload",
	)
	uploadingRef := [1]common.AttachmentRef{attachmentSQLTestRef(uploading, 10, firstSHA)}
	refuse(conn, files, alice, uploadingRef[:], "an unfinished upload")
	fresh, freshSHA := attachmentSQLTestReady(conn, alice, 10, roomID = files)
	wrongSize := [1]common.AttachmentRef{attachmentSQLTestRef(fresh, 11, freshSHA)}
	refuse(conn, files, alice, wrongSize[:], "another size")
	wrongSHA := [1]common.AttachmentRef{attachmentSQLTestRef(fresh, 10, firstSHA)}
	refuse(conn, files, alice, wrongSHA[:], "another hash")
	twice := [2]common.AttachmentRef {
		attachmentSQLTestRef(fresh, 10, freshSHA),
		attachmentSQLTestRef(fresh, 10, freshSHA),
	}
	refuse(conn, files, alice, twice[:], "a blob listed twice")
	assert(attachmentSQLTestState(conn, fresh) == "1", "expected a refused blob still Ready")

	// Encryption must match: a plaintext blob in an encrypted room, an encrypted one in a
	// plaintext room (forced in SQL, since begin refuses both), and a sealed message listing a
	// plaintext blob of its own room.
	encryptedBlob, _ := attachmentSQLTestReady(conn, alice, 500, roomID = secret, encrypted = true)
	plainInSecret, plainSHA := attachmentSQLTestReady(conn, alice, 10, roomID = files)
	databaseDefaultRoomTestExec(
		conn,
		"move a plaintext blob into the encrypted room",
		fmt.tprintf(
			"UPDATE attachments SET room_id = %d WHERE blob_id = decode('%s', 'hex')",
			secret,
			attachmentSQLTestHex(plainInSecret),
		),
	)
	plainOuter := [1]common.AttachmentRef {
		attachmentSQLTestRef(plainInSecret, 10, plainSHA, sealed = true),
	}
	sealedResult, sealedID := attachmentSQLTestPost(
		conn,
		secret,
		alice,
		"",
		plainOuter[:],
		sealed = true,
	)
	assert(
		sealedResult.attachmentsRefused && sealedID == 0,
		fmt.tprintf("expected a sealed message with a plaintext blob refused: %v", sealedResult),
	)
	encryptedInFiles, encryptedSHA := attachmentSQLTestReady(conn, alice, 10, roomID = files)
	databaseDefaultRoomTestExec(
		conn,
		"mark a plaintext room's blob encrypted",
		fmt.tprintf(
			"UPDATE attachments SET encrypted = true WHERE blob_id = decode('%s', 'hex')",
			attachmentSQLTestHex(encryptedInFiles),
		),
	)
	encryptedRef := [1]common.AttachmentRef {
		attachmentSQLTestRef(encryptedInFiles, 10, encryptedSHA),
	}
	refuse(conn, files, alice, encryptedRef[:], "an encrypted blob in a plaintext message")

	// A sealed message binds its encrypted blob; history carries only the ID, size and flag.
	outer := [1]common.AttachmentRef{{blobId = encryptedBlob, size = 500}}
	sealedPosted, sealedMessageID := attachmentSQLTestPost(
		conn,
		secret,
		alice,
		"",
		outer[:],
		sealed = true,
	)
	assert(
		sealedMessageID > 0,
		fmt.tprintf("expected the sealed message stored, got %v", sealedPosted),
	)
	assert(
		attachmentSQLTestBinding(conn, encryptedBlob) ==
		fmt.tprintf("2/%d/-/0/-/-/true", sealedMessageID),
		"expected the encrypted blob bound with no name",
	)
	sealedHistory := databaseExecuteRequest(
		conn,
		common.DatabaseRoomHistoryRequest{roomId = secret, userId = bob, limit = 10},
	)
	defer IPC__database_query_response_deinit(sealedHistory)
	sealedPage := sealedHistory.result.(common.DatabaseRoomHistoryResult)
	sealedListed := sealedPage.messages[len(sealedPage.messages) - 1].attachments
	assert(
		len(sealedListed) == 1 &&
		sealedListed[0].blobId == encryptedBlob &&
		sealedListed[0].size == 500 &&
		sealedListed[0].sha256 == {} &&
		sealedListed[0].name == "" &&
		sealedListed[0].mediaType == "",
		fmt.tprintf("expected only the ID and size of a sealed blob, got %v", sealedListed),
	)

	// Without AttachFiles a message with attachments is refused before binding; one without
	// still posts.
	databaseDefaultRoomTestExec(
		conn,
		"revoke attach files",
		fmt.tprintf("UPDATE rooms SET everyone_permissions = 3 WHERE id = %d", files),
	)
	freshRef := [1]common.AttachmentRef{attachmentSQLTestRef(fresh, 10, freshSHA)}
	denied, deniedID := attachmentSQLTestPost(conn, files, alice, "x", freshRef[:])
	assert(
		denied.attachDenied && deniedID == 0,
		fmt.tprintf("expected attachments refused without AttachFiles, got %v", denied),
	)
	_, textID := attachmentSQLTestPost(conn, files, alice, "just text", nil)
	assert(textID > 0, "expected a text message without AttachFiles")
	assert(attachmentSQLTestState(conn, fresh) == "1", "expected the blob still unbound")
}

// D10: whoever may read a message's history may download its files, and nobody else; the owner
// may download its own unbound blob; a Removed blob is never downloadable.
@(test)
testAttachmentDownloadCheckAgainstPostgreSQL :: proc(t: ^testing.T) {
	_ = t
	if os.get_env(DATABASE_SQL_TEST_ENV, context.temp_allocator) != "1" {
		return
	}
	conn := databaseAdminTestOpen(t, "attachment_download")
	alice := databaseAdminTestUser(conn, "dl-alice")
	bob := databaseAdminTestUser(conn, "dl-bob")
	carol := databaseAdminTestUser(conn, "dl-carol")
	admin := databaseAdminTestUser(conn, "dl-admin")
	databaseAdminTestGrant(conn, admin)
	allowed :: proc(conn: pg.Conn, userID: int, blob: common.AttachmentBlobID) -> bool {
		return attachmentSQLTestAction(conn, .DownloadCheck, userID, blob).outcome == .Applied
	}

	// A Full history room: every member, no outsider, no admin bypass.
	full := attachmentSQLTestRoom(conn, "dl-full")
	databaseDefaultRoomTestExec(
		conn,
		"make the room full history",
		fmt.tprintf("UPDATE rooms SET history_visibility = 2 WHERE id = %d", full),
	)
	attachmentSQLTestJoin(conn, full, alice)
	attachmentSQLTestJoin(conn, full, bob)
	blob, sha := attachmentSQLTestReady(conn, alice, 100, roomID = full)
	assert(allowed(conn, alice, blob), "expected the owner to download its unbound blob")
	assert(!allowed(conn, bob, blob), "expected an unbound blob refused to a member")
	refs := [1]common.AttachmentRef{attachmentSQLTestRef(blob, 100, sha)}
	_, messageID := attachmentSQLTestPost(conn, full, alice, "file", refs[:])
	assert(messageID > 0, "expected the message stored")
	assert(allowed(conn, bob, blob), "expected a member to download a bound blob")
	assert(!allowed(conn, carol, blob), "expected a non-member refused")
	assert(!allowed(conn, admin, blob), "expected an admin outside the room refused (no bypass)")
	download := attachmentSQLTestAction(conn, .DownloadCheck, bob, blob)
	assert(download.size == 100 && download.sha256 == sha, "expected the stored size and hash")
	// A new member of a Full history room reads the old file.
	attachmentSQLTestJoin(conn, full, carol)
	assert(allowed(conn, carol, blob), "expected a Full history newcomer allowed")
	// A removed member loses it.
	databaseDefaultRoomTestExec(
		conn,
		"remove bob",
		fmt.tprintf("DELETE FROM room_members WHERE room_id = %d AND user_id = %d", full, bob),
	)
	assert(!allowed(conn, bob, blob), "expected a removed member refused")

	// A From join room: a newcomer reads only files of messages after it joined.
	fromJoin := attachmentSQLTestRoom(conn, "dl-from-join")
	databaseDefaultRoomTestExec(
		conn,
		"make the room from join",
		fmt.tprintf("UPDATE rooms SET history_visibility = 1 WHERE id = %d", fromJoin),
	)
	attachmentSQLTestJoin(conn, fromJoin, alice)
	databaseDefaultRoomTestExec(
		conn,
		"date alice's join before the old message",
		fmt.tprintf(
			"UPDATE room_members SET joined_at = now() - interval '2 hours' " +
			"WHERE room_id = %d AND user_id = %d",
			fromJoin,
			alice,
		),
	)
	old, oldSHA := attachmentSQLTestReady(conn, alice, 100, roomID = fromJoin)
	oldRefs := [1]common.AttachmentRef{attachmentSQLTestRef(old, 100, oldSHA)}
	_, oldID := attachmentSQLTestPost(conn, fromJoin, alice, "before", oldRefs[:])
	databaseDefaultRoomTestExec(
		conn,
		"date the old message before the newcomer",
		fmt.tprintf(
			"UPDATE chat_messages SET created_at = now() - interval '1 hour' WHERE id = %d",
			oldID,
		),
	)
	attachmentSQLTestJoin(conn, fromJoin, bob)
	assert(!allowed(conn, bob, old), "expected a From join newcomer refused an older file")
	assert(allowed(conn, alice, old), "expected the earlier member allowed")
	recent, recentSHA := attachmentSQLTestReady(conn, alice, 100, roomID = fromJoin)
	recentRefs := [1]common.AttachmentRef{attachmentSQLTestRef(recent, 100, recentSHA)}
	_, recentID := attachmentSQLTestPost(conn, fromJoin, alice, "after", recentRefs[:])
	databaseDefaultRoomTestExec(
		conn,
		"date the newcomer's join before the new message",
		fmt.tprintf(
			"UPDATE room_members SET joined_at = now() - interval '1 minute' " +
			"WHERE room_id = %d AND user_id = %d; UPDATE chat_messages SET created_at = now() " +
			"WHERE id = %d",
			fromJoin,
			bob,
			recentID,
		),
	)
	assert(allowed(conn, bob, recent), "expected a newcomer allowed a newer file")
	// A Public room always reads Full, whatever history_visibility says.
	databaseDefaultRoomTestExec(
		conn,
		"make the from join room public",
		fmt.tprintf("UPDATE rooms SET access = 1 WHERE id = %d", fromJoin),
	)
	assert(allowed(conn, bob, old), "expected a Public room's member allowed every file")

	// A direct message: its sender and recipient only, and still for a restricted recipient
	// whose shared room is gone (D17: direct message history stays readable).
	dmBlob, dmSHA := attachmentSQLTestReady(conn, alice, 100, recipientID = carol)
	dmRefs := [1]common.AttachmentRef{attachmentSQLTestRef(dmBlob, 100, dmSHA)}
	dmRequest := common.DatabasePostDirectMessageRequest {
		senderId        = alice,
		recipientId     = carol,
		content         = strings.clone(""),
		clientMessageId = databaseTestClientMessageID(),
		signature       = DATABASE_TEST_SIGNATURE,
		attachments     = common.AttachmentRefs_clone(dmRefs[:]),
	}
	dmResponse := databaseExecuteRequest(conn, dmRequest)
	IPC__database_query_request_deinit(dmRequest)
	dmPosted := dmResponse.result.(common.DatabasePostDirectMessageResult)
	assert(dmPosted.outcome == .Stored, fmt.tprintf("expected the DM stored, got %v", dmPosted))
	IPC__database_query_response_deinit(dmResponse)
	assert(allowed(conn, alice, dmBlob), "expected the sender allowed")
	assert(allowed(conn, carol, dmBlob), "expected the recipient allowed")
	assert(!allowed(conn, bob, dmBlob), "expected a third account refused")
	assert(!allowed(conn, admin, dmBlob), "expected an admin refused a direct message's file")
	databaseDefaultRoomTestExec(
		conn,
		"restrict carol and drop her rooms",
		fmt.tprintf(
			"UPDATE users SET restricted = true WHERE id = %d; " +
			"DELETE FROM room_members WHERE user_id = %d",
			carol,
			carol,
		),
	)
	assert(allowed(conn, carol, dmBlob), "expected a restricted recipient still allowed")

	// A Removed blob is never downloadable, and neither is an Uploading one.
	databaseDefaultRoomTestExec(
		conn,
		"remove the direct message's blob",
		fmt.tprintf(
			"UPDATE attachments SET state = 3 WHERE blob_id = decode('%s', 'hex')",
			attachmentSQLTestHex(dmBlob),
		),
	)
	assert(!allowed(conn, alice, dmBlob), "expected a removed blob refused to its sender")
	uploading: common.AttachmentBlobID
	assert(
		attachmentSQLTestBegin(conn, alice, 10, roomID = full, blobOut = &uploading) == .Applied,
		"expected an upload",
	)
	assert(!allowed(conn, alice, uploading), "expected an unfinished upload refused")
}

// D17: deleting a room turns its messages' blob links NULL, the sweeper deletes those rows once
// they are an hour old, and the storage worker then deletes their files.
@(test)
testAttachmentRoomDeletionSweepsItsFilesAgainstPostgreSQL :: proc(t: ^testing.T) {
	_ = t
	if os.get_env(DATABASE_SQL_TEST_ENV, context.temp_allocator) != "1" {
		return
	}
	conn := databaseAdminTestOpen(t, "attachment_room_delete")
	alice := databaseAdminTestUser(conn, "del-alice")
	room := attachmentSQLTestRoom(conn, "del-room")
	attachmentSQLTestJoin(conn, room, alice)

	// The blob's file, through the storage worker on a directory of its own.
	allocator := context.allocator
	context.allocator = context.temp_allocator
	dir := routerTestCreateTempDir("haychat_attachment_room_delete")
	context.allocator = allocator
	defer os.remove_all(dir)
	for name in ([]string{ATTACHMENT_INCOMING_DIR_NAME, ATTACHMENT_BLOBS_DIR_NAME}) {
		path := fmt.tprintf("%s/%s", dir, name)
		assert(os.make_directory(path, os.perm(0o700)) == nil, "expected a blob subdirectory")
	}
	worker := StorageWorker_init(dir)
	defer StorageWorker_deinit(&worker)
	worker.freeBytes = proc(dir: string) -> (i64, bool) {
		_ = dir
		return 1 << 40, true
	}
	data := "the file of a room that will be deleted"
	blob: common.AttachmentBlobID
	assert(
		attachmentSQLTestBegin(conn, alice, u64(len(data)), roomID = room, blobOut = &blob) ==
		.Applied,
		"expected the upload to begin",
	)
	opened, _ := StorageWorker_handle(
		&worker,
		StorageUploadOpen{blobId = blob, size = u64(len(data))},
	)
	assert(opened.(StorageUploadOpened).ok, "expected the part file")
	chunk := make([]u8, len(data))
	copy(chunk, data)
	write := StorageUploadWrite {
		blobId = blob,
		data   = chunk,
	}
	written, _ := StorageWorker_handle(&worker, write)
	StorageRequest_deinit(write)
	assert(written.(StorageUploadWritten).ok, "expected the chunk written")
	sha := common.AttachmentSHA256(common.hashBytes(transmute([]u8)data))
	finished, _ := StorageWorker_handle(
		&worker,
		StorageUploadFinish{blobId = blob, size = u64(len(data)), sha256 = sha},
	)
	assert(finished.(StorageUploadFinished).ok, "expected the blob stored")
	ready := attachmentSQLTestRun(
		conn,
		common.DatabaseAttachmentRequest {
			action = .Finish,
			userId = alice,
			blobId = blob,
			size = u64(len(data)),
			sha256 = sha,
		},
	)
	assert(ready.outcome == .Applied, "expected the blob Ready")
	refs := [1]common.AttachmentRef{attachmentSQLTestRef(blob, u64(len(data)), sha)}
	_, messageID := attachmentSQLTestPost(conn, room, alice, "doomed", refs[:])
	assert(messageID > 0, "expected the message stored")
	path := storageBlobPath(&worker, blob)
	defer delete(path)
	assert(os.exists(path), "expected the blob's file stored")

	sweep :: proc(conn: pg.Conn) -> common.DatabaseAttachmentResult {
		return attachmentSQLTestRun(
			conn,
			common.DatabaseAttachmentRequest{action = .Sweep, pendingHours = 24, limit = 100},
		)
	}
	attachmentSQLTestAge(conn, blob, 2, 2)
	assert(len(sweep(conn).blobs) == 0, "expected a bound blob never swept")

	databaseDefaultRoomTestExec(
		conn,
		"delete the room",
		fmt.tprintf("DELETE FROM rooms WHERE id = %d", room),
	)
	assert(
		databaseAdminTestValue(
			conn,
			fmt.tprintf(
				"SELECT (chat_message_id IS NULL AND room_id IS NULL)::text FROM attachments " +
				"WHERE blob_id = decode('%s', 'hex')",
				attachmentSQLTestHex(blob),
			),
		) ==
		"true",
		"expected the blob's message and room links gone with the room",
	)
	swept := sweep(conn)
	assert(
		len(swept.blobs) == 1 && swept.blobs[0].blobId == blob && swept.blobs[0].state == .Bound,
		fmt.tprintf("expected the room's blob swept, got %v", swept.blobs),
	)
	assert(attachmentSQLTestState(conn, blob) == "none", "expected the row deleted")
	blobs := make([dynamic]common.DatabaseAttachmentBlob)
	append(&blobs, ..swept.blobs[:])
	deleteRequest := StorageDeleteBlobs {
		blobs = blobs,
	}
	deleted, _ := StorageWorker_handle(&worker, deleteRequest)
	StorageRequest_deinit(deleteRequest)
	assert(deleted.(StorageBlobsDeleted).deleted == 1, "expected the file deleted")
	assert(!os.exists(path), "expected the blob gone from the directory")
}

// ── Moderation (protocol 28, attachments plan F3, D22) ───────────────────────────────────

@(private = "file")
attachmentSQLTestRemove :: proc(
	conn: pg.Conn,
	userID: int,
	blob: common.AttachmentBlobID,
	reason := "",
) -> common.DatabaseAttachmentResult {
	return attachmentSQLTestRun(
		conn,
		common.DatabaseAttachmentRequest {
			action = .Remove,
			userId = userID,
			blobId = blob,
			reason = strings.clone(reason, context.temp_allocator),
		},
	)
}

@(private = "file")
attachmentSQLTestReaders :: proc(result: common.DatabaseAttachmentResult) -> string {
	builder := strings.builder_make(context.temp_allocator)
	for id, index in result.removal.readerUserIds {
		if index > 0 {
			strings.write_byte(&builder, ',')
		}
		fmt.sbprintf(&builder, "%d", id)
	}
	return strings.to_string(builder)
}

// D22: only an admin removes (a holder of every assignable permission is refused), only a Ready
// or Bound blob, and the tombstone keeps every signed field and its message link, frees the
// quota, and names exactly the accounts that may read the message.
@(test)
testAttachmentRemovalAgainstPostgreSQL :: proc(t: ^testing.T) {
	_ = t
	if os.get_env(DATABASE_SQL_TEST_ENV, context.temp_allocator) != "1" {
		return
	}
	conn := databaseAdminTestOpen(t, "attachment_remove")
	alice := databaseAdminTestUser(conn, "rm-alice")
	bob := databaseAdminTestUser(conn, "rm-bob")
	carol := databaseAdminTestUser(conn, "rm-carol")
	dave := databaseAdminTestUser(conn, "rm-dave")
	admin := databaseAdminTestUser(conn, "rm-admin")
	helper := databaseAdminTestUser(conn, "rm-helper")
	databaseAdminTestGrant(conn, admin)
	databaseDefaultRoomTestExec(
		conn,
		"a role with every assignable permission",
		fmt.tprintf(
			"INSERT INTO server_roles (name, permissions) VALUES ('rm-helpers', %d); " +
			"INSERT INTO user_server_roles (user_id, role_id) " +
			"SELECT %d, id FROM server_roles WHERE name = 'rm-helpers'",
			transmute(u64)common.SERVER_PERMISSIONS_ASSIGNABLE,
			helper,
		),
	)

	// A From join room: alice and bob before the message, carol after it, dave never.
	room := attachmentSQLTestRoom(conn, "rm-room")
	databaseDefaultRoomTestExec(
		conn,
		"make the room from join",
		fmt.tprintf("UPDATE rooms SET history_visibility = 1 WHERE id = %d", room),
	)
	attachmentSQLTestJoin(conn, room, alice)
	attachmentSQLTestJoin(conn, room, bob)
	databaseDefaultRoomTestExec(
		conn,
		"date the early joins",
		fmt.tprintf(
			"UPDATE room_members SET joined_at = now() - interval '2 hours' WHERE room_id = %d",
			room,
		),
	)
	blob, sha := attachmentSQLTestReady(conn, alice, 100, roomID = room)
	refs := [1]common.AttachmentRef{attachmentSQLTestRef(blob, 100, sha, "report.pdf")}
	_, messageID := attachmentSQLTestPost(conn, room, alice, "the report", refs[:])
	assert(messageID > 0, "expected the message stored")
	databaseDefaultRoomTestExec(
		conn,
		"date the message before carol",
		fmt.tprintf(
			"UPDATE chat_messages SET created_at = now() - interval '1 hour' WHERE id = %d",
			messageID,
		),
	)
	attachmentSQLTestJoin(conn, room, carol)
	bound := attachmentSQLTestBinding(conn, blob)

	// The quota sees the blob: alice's 150-byte quota leaves no room for 100 more.
	quota := AttachmentSQLTestLimits {
		maxBytes = 1_000_000,
		quota    = 150,
	}
	assert(
		attachmentSQLTestBegin(conn, alice, 100, roomID = room, limits = quota) == .QuotaExceeded,
		"expected the quota full before the removal",
	)

	// Not an admin, even with every assignable permission: nothing changes.
	for userID in ([]int{alice, bob, helper}) {
		refused := attachmentSQLTestRemove(conn, userID, blob)
		assert(
			refused.outcome == .NotAdmin,
			fmt.tprintf("expected user %d refused as not an admin, got %v", userID, refused),
		)
	}
	assert(attachmentSQLTestState(conn, blob) == "2", "expected the blob still bound")

	removed := attachmentSQLTestRemove(conn, admin, blob)
	assert(
		removed.outcome == .Applied &&
		removed.removal.ownerUserId == alice &&
		removed.removal.roomId == room &&
		removed.removal.senderId == alice &&
		removed.removal.recipientId == 0 &&
		removed.removal.chatMessageId == messageID &&
		removed.removal.directMessageId == 0,
		fmt.tprintf("expected the room message's blob removed, got %v", removed),
	)
	assert(
		attachmentSQLTestReaders(removed) == fmt.tprintf("%d,%d", alice, bob),
		fmt.tprintf(
			"expected only alice and bob as readers (not the From join newcomer, the " +
			"outsider or the admin), got %s",
			attachmentSQLTestReaders(removed),
		),
	)
	// Every signed field and the message link stay; only the state and the removal change.
	after := attachmentSQLTestBinding(conn, blob)
	assert(
		after[1:] == bound[1:] && after[0] == '3',
		fmt.tprintf("expected only the state to change, %s -> %s", bound, after),
	)
	shaHex := common.encodeBytesToHex(sha[:])
	defer delete(shaHex)
	assert(
		databaseAdminTestValue(
			conn,
			fmt.tprintf(
				"SELECT (removed_by_user_id = %d AND removed_at IS NOT NULL AND size = 100 " +
				"AND sha256 = decode('%s', 'hex'))::text FROM attachments " +
				"WHERE blob_id = decode('%s', 'hex')",
				admin,
				shaHex,
				attachmentSQLTestHex(blob),
			),
		) ==
		"true",
		"expected the tombstone to keep its size and hash and name its remover",
	)
	// History still lists the file with every signed field, now removed.
	history := databaseExecuteRequest(
		conn,
		common.DatabaseRoomHistoryRequest{roomId = room, userId = bob, limit = 10},
	)
	defer IPC__database_query_response_deinit(history)
	page := history.result.(common.DatabaseRoomHistoryResult)
	assert(len(page.messages) == 1, "expected the message in history")
	listed := page.messages[0].attachments
	assert(
		len(listed) == 1 &&
		listed[0].blobId == blob &&
		listed[0].size == 100 &&
		listed[0].sha256 == sha &&
		listed[0].name == "report.pdf" &&
		listed[0].mediaType == "text/plain" &&
		listed[0].removed,
		fmt.tprintf("expected the removed file listed with its signed fields, got %v", listed),
	)
	// The quota is free again.
	assert(
		attachmentSQLTestBegin(conn, alice, 100, roomID = room, limits = quota) == .Applied,
		"expected the tombstone to free the quota",
	)
	// A reader's download is refused as removed; anyone else's as not found.
	assert(
		attachmentSQLTestAction(conn, .DownloadCheck, bob, blob).outcome == .Removed,
		"expected a reader told the file was removed",
	)
	assert(
		attachmentSQLTestAction(conn, .DownloadCheck, dave, blob).outcome == .NotFound,
		"expected an outsider told nothing",
	)
	assert(
		attachmentSQLTestAction(conn, .DownloadCheck, carol, blob).outcome == .NotFound,
		"expected a From join newcomer told nothing",
	)

	// Removed, Uploading and unknown blobs are not found.
	assert(
		attachmentSQLTestRemove(conn, admin, blob).outcome == .NotFound,
		"expected a second removal not found",
	)
	uploading: common.AttachmentBlobID
	assert(
		attachmentSQLTestBegin(conn, bob, 10, roomID = room, blobOut = &uploading) == .Applied,
		"expected an upload",
	)
	assert(
		attachmentSQLTestRemove(conn, admin, uploading).outcome == .NotFound,
		"expected an Uploading blob not found",
	)
	assert(attachmentSQLTestState(conn, uploading) == "0", "expected the upload untouched")
	assert(
		attachmentSQLTestRemove(conn, admin, attachmentSQLTestBlob()).outcome == .NotFound,
		"expected an unknown blob not found",
	)

	// A direct message: both sides, and the admin is no reader.
	dmBlob, dmSHA := attachmentSQLTestReady(conn, alice, 50, recipientID = bob)
	dmRefs := [1]common.AttachmentRef{attachmentSQLTestRef(dmBlob, 50, dmSHA)}
	dmRequest := common.DatabasePostDirectMessageRequest {
		senderId        = alice,
		recipientId     = bob,
		content         = strings.clone(""),
		clientMessageId = databaseTestClientMessageID(),
		signature       = DATABASE_TEST_SIGNATURE,
		attachments     = common.AttachmentRefs_clone(dmRefs[:]),
	}
	dmResponse := databaseExecuteRequest(conn, dmRequest)
	IPC__database_query_request_deinit(dmRequest)
	dmPosted := dmResponse.result.(common.DatabasePostDirectMessageResult)
	assert(dmPosted.outcome == .Stored, fmt.tprintf("expected the DM stored, got %v", dmPosted))
	IPC__database_query_response_deinit(dmResponse)
	dmRemoved := attachmentSQLTestRemove(conn, admin, dmBlob)
	assert(
		dmRemoved.outcome == .Applied &&
		dmRemoved.removal.roomId == 0 &&
		dmRemoved.removal.senderId == alice &&
		dmRemoved.removal.recipientId == bob &&
		dmRemoved.removal.directMessageId > 0 &&
		attachmentSQLTestReaders(dmRemoved) == fmt.tprintf("%d,%d", alice, bob),
		fmt.tprintf("expected the direct message's two sides, got %v", dmRemoved),
	)

	// An unbound Ready blob: only its owner, and an admin's own file is removable too.
	loose, _ := attachmentSQLTestReady(conn, bob, 30, roomID = room)
	looseRemoved := attachmentSQLTestRemove(conn, admin, loose)
	assert(
		looseRemoved.outcome == .Applied &&
		looseRemoved.removal.roomId == room &&
		looseRemoved.removal.senderId == bob &&
		looseRemoved.removal.chatMessageId == 0 &&
		attachmentSQLTestReaders(looseRemoved) == fmt.tprintf("%d", bob),
		fmt.tprintf("expected only the owner of an unbound blob, got %v", looseRemoved),
	)
	attachmentSQLTestJoin(conn, room, admin)
	own, _ := attachmentSQLTestReady(conn, admin, 20, roomID = room)
	assert(
		attachmentSQLTestRemove(conn, admin, own).outcome == .Applied,
		"expected an admin to remove its own file",
	)

	// The hourly pass lists the bound tombstones (the room's and the DM's), newest first, and
	// not the unbound ones the sweeper takes with their rows.
	tombstones := attachmentSQLTestRun(
		conn,
		common.DatabaseAttachmentRequest{action = .TombstoneFiles, limit = 10},
	)
	assert(
		len(tombstones.blobs) == 2 &&
		tombstones.blobs[0].blobId == dmBlob &&
		tombstones.blobs[1].blobId == blob &&
		tombstones.blobs[0].state == .Removed,
		fmt.tprintf("expected the two bound tombstones, got %v", tombstones.blobs),
	)
}

// Usage (D22): admins only; tombstones do not count, uploads in progress do.
@(test)
testAttachmentUsageAgainstPostgreSQL :: proc(t: ^testing.T) {
	_ = t
	if os.get_env(DATABASE_SQL_TEST_ENV, context.temp_allocator) != "1" {
		return
	}
	conn := databaseAdminTestOpen(t, "attachment_usage")
	alice := databaseAdminTestUser(conn, "use-alice")
	bob := databaseAdminTestUser(conn, "use-bob")
	admin := databaseAdminTestUser(conn, "use-admin")
	databaseAdminTestGrant(conn, admin)
	room := attachmentSQLTestRoom(conn, "use-room")
	attachmentSQLTestJoin(conn, room, alice)
	attachmentSQLTestJoin(conn, room, bob)
	attachmentSQLTestReady(conn, alice, 100, roomID = room)
	attachmentSQLTestReady(conn, alice, 200, roomID = room)
	gone, _ := attachmentSQLTestReady(conn, alice, 5000, roomID = room)
	attachmentSQLTestReady(conn, bob, 250, roomID = room)
	assert(
		attachmentSQLTestBegin(conn, bob, 40, roomID = room) == .Applied,
		"expected an upload in progress",
	)
	assert(
		attachmentSQLTestRemove(conn, admin, gone).outcome == .Applied,
		"expected the large blob removed",
	)
	usage :: proc(conn: pg.Conn, userID: int, limit := 0) -> common.DatabaseAttachmentResult {
		return attachmentSQLTestRun(
			conn,
			common.DatabaseAttachmentRequest{action = .Usage, userId = userID, limit = limit},
		)
	}
	refused := usage(conn, alice)
	assert(
		refused.outcome == .NotAdmin && len(refused.accounts) == 0 && refused.usedBytes == 0,
		fmt.tprintf("expected a non-admin refused with nothing, got %v", refused),
	)
	listed := usage(conn, admin)
	assert(
		listed.outcome == .Applied &&
		listed.usedBytes == 590 &&
		len(listed.accounts) == 2 &&
		listed.accounts[0].userId == alice &&
		listed.accounts[0].bytes == 300 &&
		listed.accounts[0].count == 2 &&
		listed.accounts[1].userId == bob &&
		listed.accounts[1].bytes == 290 &&
		listed.accounts[1].count == 2,
		fmt.tprintf("expected 590 bytes, alice then bob, got %v", listed),
	)
	top := usage(conn, admin, 1)
	assert(
		len(top.accounts) == 1 && top.accounts[0].userId == alice && top.usedBytes == 590,
		fmt.tprintf("expected the limit to cut the list, not the total, got %v", top),
	)
}

// A removal made in SQL (deploy/sql/remove-attachment.sql) cannot delete the file: the hourly
// pass lists the bound tombstone and the storage worker deletes its file.
@(test)
testAttachmentSQLRemovalFileIsDeletedByTheHourlyPassAgainstPostgreSQL :: proc(t: ^testing.T) {
	_ = t
	if os.get_env(DATABASE_SQL_TEST_ENV, context.temp_allocator) != "1" {
		return
	}
	conn := databaseAdminTestOpen(t, "attachment_sql_remove")
	alice := databaseAdminTestUser(conn, "sqlrm-alice")
	room := attachmentSQLTestRoom(conn, "sqlrm-room")
	attachmentSQLTestJoin(conn, room, alice)

	allocator := context.allocator
	context.allocator = context.temp_allocator
	dir := routerTestCreateTempDir("haychat_attachment_sql_remove")
	context.allocator = allocator
	defer os.remove_all(dir)
	for name in ([]string{ATTACHMENT_INCOMING_DIR_NAME, ATTACHMENT_BLOBS_DIR_NAME}) {
		path := fmt.tprintf("%s/%s", dir, name)
		assert(os.make_directory(path, os.perm(0o700)) == nil, "expected a blob subdirectory")
	}
	worker := StorageWorker_init(dir)
	defer StorageWorker_deinit(&worker)
	worker.freeBytes = proc(dir: string) -> (i64, bool) {
		_ = dir
		return 1 << 40, true
	}
	data := "a file an operator removes in SQL"
	blob: common.AttachmentBlobID
	assert(
		attachmentSQLTestBegin(conn, alice, u64(len(data)), roomID = room, blobOut = &blob) ==
		.Applied,
		"expected the upload to begin",
	)
	opened, _ := StorageWorker_handle(
		&worker,
		StorageUploadOpen{blobId = blob, size = u64(len(data))},
	)
	assert(opened.(StorageUploadOpened).ok, "expected the part file")
	chunk := make([]u8, len(data))
	copy(chunk, data)
	write := StorageUploadWrite {
		blobId = blob,
		data   = chunk,
	}
	written, _ := StorageWorker_handle(&worker, write)
	StorageRequest_deinit(write)
	assert(written.(StorageUploadWritten).ok, "expected the chunk written")
	sha := common.AttachmentSHA256(common.hashBytes(transmute([]u8)data))
	finished, _ := StorageWorker_handle(
		&worker,
		StorageUploadFinish{blobId = blob, size = u64(len(data)), sha256 = sha},
	)
	assert(finished.(StorageUploadFinished).ok, "expected the blob stored")
	ready := attachmentSQLTestRun(
		conn,
		common.DatabaseAttachmentRequest {
			action = .Finish,
			userId = alice,
			blobId = blob,
			size = u64(len(data)),
			sha256 = sha,
		},
	)
	assert(ready.outcome == .Applied, "expected the blob Ready")
	refs := [1]common.AttachmentRef{attachmentSQLTestRef(blob, u64(len(data)), sha)}
	_, messageID := attachmentSQLTestPost(conn, room, alice, "soon gone", refs[:])
	assert(messageID > 0, "expected the message stored")
	path := storageBlobPath(&worker, blob)
	defer delete(path)
	assert(os.exists(path), "expected the blob's file stored")

	// What deploy/sql/remove-attachment.sql does: the tombstone, with no admin and no file
	// deletion.
	databaseDefaultRoomTestExec(
		conn,
		"remove the blob as the operator helper does",
		fmt.tprintf(
			"UPDATE attachments SET state = 3, removed_at = now() " +
			"WHERE blob_id = decode('%s', 'hex') AND state IN (1, 2)",
			attachmentSQLTestHex(blob),
		),
	)
	assert(os.exists(path), "expected the file still there after the SQL removal")
	sweep := attachmentSQLTestRun(
		conn,
		common.DatabaseAttachmentRequest{action = .Sweep, pendingHours = 24, limit = 100},
	)
	assert(len(sweep.blobs) == 0, "expected the bound tombstone's row kept")
	tombstones := attachmentSQLTestRun(
		conn,
		common.DatabaseAttachmentRequest{action = .TombstoneFiles, limit = 10},
	)
	assert(
		len(tombstones.blobs) == 1 && tombstones.blobs[0].blobId == blob,
		fmt.tprintf("expected the tombstone listed, got %v", tombstones.blobs),
	)
	blobs := make([dynamic]common.DatabaseAttachmentBlob)
	append(&blobs, ..tombstones.blobs[:])
	deleteRequest := StorageDeleteBlobs {
		blobs = blobs,
	}
	deleted, _ := StorageWorker_handle(&worker, deleteRequest)
	assert(deleted.(StorageBlobsDeleted).deleted == 1, "expected the file deleted")
	// The next pass deletes nothing more: the delete is idempotent.
	again, _ := StorageWorker_handle(&worker, deleteRequest)
	StorageRequest_deinit(deleteRequest)
	assert(again.(StorageBlobsDeleted).deleted == 0, "expected a second pass to delete nothing")
	assert(!os.exists(path), "expected the blob gone from the directory")
	assert(attachmentSQLTestState(conn, blob) == "3", "expected the tombstone row kept")
}

// ── Removal log (protocol 29, #138) ─────────────────────────────────────────────────────

// The DO block of deploy/sql/remove-attachment.sql, as the file has it: the test runs the
// helper's own code, with the two settings its psql lines set.
ATTACHMENT_SQL_TEST_REMOVE_HELPER :: #load("../deploy/sql/remove-attachment.sql", string)

@(private = "file")
attachmentSQLTestHelperBlock :: proc() -> string {
	helper := ATTACHMENT_SQL_TEST_REMOVE_HELPER
	start := strings.index(helper, "DO $$")
	end := strings.last_index(helper, "$$;")
	assert(start >= 0 && end > start, "expected one DO block in remove-attachment.sql")
	return helper[start:end + 3]
}

// Runs the SQL helper's block for blob with reason; "" when it removed the blob, otherwise the
// error PostgreSQL raised.
@(private = "file")
attachmentSQLTestRunHelper :: proc(
	conn: pg.Conn,
	blob: common.AttachmentBlobID,
	reason: string,
) -> string {
	settings := fmt.tprintf(
		"SELECT set_config('haychat.blob', '%s', false), " +
		"set_config('haychat.reason', '%s', false)",
		attachmentSQLTestHex(blob),
		reason,
	)
	databaseDefaultRoomTestExec(conn, "set the helper's settings", settings)
	// The test's schema lives in a transaction: a refusal must undo only the helper's block.
	databaseDefaultRoomTestExec(conn, "mark the helper's savepoint", "SAVEPOINT helper")
	block, _ := strings.clone_to_cstring(attachmentSQLTestHelperBlock(), context.temp_allocator)
	result := pg.exec(conn, block)
	defer pg.clear(result)
	if pg.result_status(result) == .Command_OK {
		databaseDefaultRoomTestExec(conn, "keep the helper's change", "RELEASE SAVEPOINT helper")
		return ""
	}
	message := strings.clone_from_cstring(pg.result_error_message(result), context.temp_allocator)
	databaseDefaultRoomTestExec(conn, "undo the helper", "ROLLBACK TO SAVEPOINT helper")
	return message
}

// One log row of blob as text: owner/remover/reason/room/direct/encrypted/chat/direct
// message/name ('-' for NULL), or 'none'.
@(private = "file")
attachmentSQLTestLogRow :: proc(conn: pg.Conn, blob: common.AttachmentBlobID) -> string {
	return databaseAdminTestValue(
		conn,
		fmt.tprintf(
			"SELECT COALESCE((SELECT string_agg(owner_user_id || '/' || " +
			"COALESCE(removed_by_user_id::text, '-') || '/' || COALESCE(reason, '-') || '/' || " +
			"COALESCE(room_id::text, '-') || '/' || direct || '/' || encrypted || '/' || " +
			"COALESCE(chat_message_id::text, '-') || '/' || " +
			"COALESCE(direct_message_id::text, '-') || '/' || COALESCE(name, '-'), ';') " +
			"FROM attachment_removals WHERE blob_id = decode('%s', 'hex')), 'none')",
			attachmentSQLTestHex(blob),
		),
	)
}

@(private = "file")
attachmentSQLTestLogCount :: proc(conn: pg.Conn) -> string {
	return databaseAdminTestValue(conn, "SELECT count(*)::text FROM attachment_removals")
}

// #138: the removal statement writes exactly one log row with the reason, in the same
// statement as the tombstone; a refused removal writes none; the SQL helper writes one with no
// admin; and the row outlives the sweeper deleting the tombstone's row.
@(test)
testAttachmentRemovalLogAgainstPostgreSQL :: proc(t: ^testing.T) {
	_ = t
	if os.get_env(DATABASE_SQL_TEST_ENV, context.temp_allocator) != "1" {
		return
	}
	conn := databaseAdminTestOpen(t, "attachment_removal_log")
	alice := databaseAdminTestUser(conn, "log-alice")
	bob := databaseAdminTestUser(conn, "log-bob")
	admin := databaseAdminTestUser(conn, "log-admin")
	databaseAdminTestGrant(conn, admin)
	room := attachmentSQLTestRoom(conn, "log-room")
	attachmentSQLTestJoin(conn, room, alice)
	attachmentSQLTestJoin(conn, room, bob)

	blob, sha := attachmentSQLTestReady(conn, alice, 100, roomID = room)
	refs := [1]common.AttachmentRef{attachmentSQLTestRef(blob, 100, sha, "report.pdf")}
	_, messageID := attachmentSQLTestPost(conn, room, alice, "the report", refs[:])
	assert(messageID > 0, "expected the message stored")

	// Refusals write nothing: a non-admin, an unknown blob, an upload in progress.
	assert(
		attachmentSQLTestRemove(conn, bob, blob, "mine now").outcome == .NotAdmin,
		"expected a non-admin refused",
	)
	assert(
		attachmentSQLTestRemove(conn, admin, attachmentSQLTestBlob(), "gone").outcome ==
		.NotFound,
		"expected an unknown blob not found",
	)
	uploading: common.AttachmentBlobID
	assert(
		attachmentSQLTestBegin(conn, bob, 10, roomID = room, blobOut = &uploading) == .Applied,
		"expected an upload",
	)
	assert(
		attachmentSQLTestRemove(conn, admin, uploading).outcome == .NotFound,
		"expected an upload in progress not found",
	)
	assert(attachmentSQLTestLogCount(conn) == "0", "expected no log row for a refusal")

	removed := attachmentSQLTestRemove(conn, admin, blob, "Reported as spam")
	assert(removed.outcome == .Applied, fmt.tprintf("expected the removal, got %v", removed))
	logged := attachmentSQLTestLogRow(conn, blob)
	assert(
		logged ==
		fmt.tprintf(
			"%d/%d/Reported as spam/%d/false/false/%d/-/report.pdf",
			alice,
			admin,
			room,
			messageID,
		),
		fmt.tprintf("expected one log row with the reason, got %s", logged),
	)
	assert(
		databaseAdminTestValue(
			conn,
			fmt.tprintf(
				"SELECT (r.removed_at = a.removed_at)::text FROM attachment_removals r " +
				"JOIN attachments a ON a.blob_id = r.blob_id WHERE r.blob_id = decode('%s', 'hex')",
				attachmentSQLTestHex(blob),
			),
		) ==
		"true",
		"expected the log row written in the tombstone's statement (one transaction time)",
	)
	assert(
		attachmentSQLTestRemove(conn, admin, blob, "again").outcome == .NotFound &&
		attachmentSQLTestLogCount(conn) == "1",
		"expected a second removal to write no second row",
	)

	// An encrypted file for a direct conversation: no name, direct, and no reason.
	secret, _ := attachmentSQLTestReady(conn, bob, 40, recipientID = alice, encrypted = true)
	assert(
		attachmentSQLTestRemove(conn, admin, secret).outcome == .Applied,
		"expected the encrypted file removed",
	)
	assert(
		attachmentSQLTestLogRow(conn, secret) ==
		fmt.tprintf("%d/%d/-/-/true/true/-/-/-", bob, admin),
		fmt.tprintf(
			"expected an encrypted direct file logged without a name, got %s",
			attachmentSQLTestLogRow(conn, secret),
		),
	)

	// The SQL helper (deploy/sql/remove-attachment.sql): the same tombstone, with a row whose
	// admin is NULL, and its refusals change nothing.
	helped, helpedSHA := attachmentSQLTestReady(conn, bob, 30, roomID = room)
	helpedRefs := [1]common.AttachmentRef{attachmentSQLTestRef(helped, 30, helpedSHA, "b.txt")}
	_, helpedMessage := attachmentSQLTestPost(conn, room, bob, "", helpedRefs[:])
	assert(helpedMessage > 0, "expected bob's message stored")
	failure := attachmentSQLTestRunHelper(conn, helped, "Court order 7")
	assert(failure == "", fmt.tprintf("expected the helper to remove the blob: %s", failure))
	assert(attachmentSQLTestState(conn, helped) == "3", "expected the helper's tombstone")
	assert(
		attachmentSQLTestLogRow(conn, helped) ==
		fmt.tprintf("%d/-/Court order 7/%d/false/false/%d/-/b.txt", bob, room, helpedMessage),
		fmt.tprintf(
			"expected the helper's row with no admin, got %s",
			attachmentSQLTestLogRow(conn, helped),
		),
	)
	again := attachmentSQLTestRunHelper(conn, helped, "")
	assert(
		strings.contains(again, "already removed") && attachmentSQLTestLogCount(conn) == "3",
		fmt.tprintf("expected a second helper run refused with no row, got %q", again),
	)
	plain, _ := attachmentSQLTestReady(conn, bob, 20, roomID = room)
	badReason := attachmentSQLTestRunHelper(
		conn,
		plain,
		strings.repeat("r", 501, context.temp_allocator),
	)
	assert(
		strings.contains(badReason, "at most 500 bytes") &&
		attachmentSQLTestState(conn, plain) == "1" &&
		attachmentSQLTestLogCount(conn) == "3",
		fmt.tprintf("expected a long reason refused with nothing changed, got %q", badReason),
	)
	assert(attachmentSQLTestRunHelper(conn, plain, "") == "", "expected the helper with no reason")
	assert(
		attachmentSQLTestLogRow(conn, plain) ==
		fmt.tprintf("%d/-/-/%d/false/false/-/-/-", bob, room),
		fmt.tprintf(
			"expected an unsent file logged with no reason or name, got %s",
			attachmentSQLTestLogRow(conn, plain),
		),
	)

	// The room goes: its messages with it, then the sweeper deletes the tombstone's row. The
	// log row stays, its room and message links NULL.
	databaseDefaultRoomTestExec(
		conn,
		"delete the room",
		fmt.tprintf("DELETE FROM rooms WHERE id = %d", room),
	)
	attachmentSQLTestAge(conn, blob, 2, 2)
	swept := attachmentSQLTestRun(
		conn,
		common.DatabaseAttachmentRequest{action = .Sweep, pendingHours = 24, limit = 100},
	)
	sweptBlob := false
	for entry in swept.blobs {
		sweptBlob ||= entry.blobId == blob
	}
	assert(sweptBlob, fmt.tprintf("expected the tombstone's row swept, got %v", swept.blobs))
	assert(attachmentSQLTestState(conn, blob) == "none", "expected the attachment row deleted")
	assert(
		attachmentSQLTestLogRow(conn, blob) ==
		fmt.tprintf("%d/%d/Reported as spam/-/false/false/-/-/report.pdf", alice, admin),
		fmt.tprintf(
			"expected the log row kept with its links gone, got %s",
			attachmentSQLTestLogRow(conn, blob),
		),
	)
}

// #138: the log lists only for admins, newest first, paged by row ID without dropping or
// repeating a row at a page boundary.
@(test)
testAttachmentRemovalLogListingAgainstPostgreSQL :: proc(t: ^testing.T) {
	_ = t
	if os.get_env(DATABASE_SQL_TEST_ENV, context.temp_allocator) != "1" {
		return
	}
	conn := databaseAdminTestOpen(t, "attachment_removal_list")
	alice := databaseAdminTestUser(conn, "list-alice")
	admin := databaseAdminTestUser(conn, "list-admin")
	helper := databaseAdminTestUser(conn, "list-helper")
	databaseAdminTestGrant(conn, admin)
	databaseDefaultRoomTestExec(
		conn,
		"a role with every assignable permission",
		fmt.tprintf(
			"INSERT INTO server_roles (name, permissions) VALUES ('list-helpers', %d); " +
			"INSERT INTO user_server_roles (user_id, role_id) " +
			"SELECT %d, id FROM server_roles WHERE name = 'list-helpers'",
			transmute(u64)common.SERVER_PERMISSIONS_ASSIGNABLE,
			helper,
		),
	)
	room := attachmentSQLTestRoom(conn, "list-room")
	attachmentSQLTestJoin(conn, room, alice)

	list :: proc(conn: pg.Conn, userID, beforeID, limit: int) -> common.DatabaseAttachmentResult {
		return attachmentSQLTestRun(
			conn,
			common.DatabaseAttachmentRequest {
				action = .Removals,
				userId = userID,
				beforeId = beforeID,
				limit = limit,
			},
		)
	}
	empty := list(conn, admin, 0, 2)
	assert(
		empty.outcome == .Applied && len(empty.removals) == 0 && !empty.hasMore,
		fmt.tprintf("expected an empty log, got %v", empty),
	)

	REMOVALS :: 5
	blobs: [REMOVALS]common.AttachmentBlobID
	for index in 0 ..< REMOVALS {
		blobs[index], _ = attachmentSQLTestReady(conn, alice, u64(10 + index), roomID = room)
		reason := fmt.tprintf("reason %d", index)
		assert(
			attachmentSQLTestRemove(conn, admin, blobs[index], reason).outcome == .Applied,
			"expected the removal",
		)
	}
	for userID in ([]int{alice, helper}) {
		refused := list(conn, userID, 0, 2)
		assert(
			refused.outcome == .NotAdmin && len(refused.removals) == 0,
			fmt.tprintf("expected user %d refused with nothing, got %v", userID, refused),
		)
	}

	// Pages of two: 5 4 | 3 2 | 1, each strictly older than the last.
	seen := make([dynamic]int, context.temp_allocator)
	cursor := 0
	pages := 0
	for {
		page := list(conn, admin, cursor, 2)
		assert(page.outcome == .Applied, "expected the admin's page")
		pages += 1
		for entry in page.removals {
			assert(
				cursor == 0 || entry.id < cursor,
				fmt.tprintf("expected entry %d older than the cursor %d", entry.id, cursor),
			)
			if len(seen) > 0 {
				assert(entry.id < seen[len(seen) - 1], "expected newest first")
			}
			append(&seen, entry.id)
		}
		if !page.hasMore {
			assert(len(page.removals) == 1, fmt.tprintf("expected a last page of 1, got %v", page))
			break
		}
		assert(len(page.removals) == 2, "expected a full page before hasMore")
		cursor = page.removals[len(page.removals) - 1].id
		assert(pages < 10, "expected the paging to end")
	}
	assert(
		pages == 3 && len(seen) == REMOVALS,
		fmt.tprintf("expected 5 rows in 3 pages, got %v in %d", seen, pages),
	)
	// The newest page names the last removal with every field.
	first := list(conn, admin, 0, 50)
	assert(len(first.removals) == REMOVALS && !first.hasMore, "expected every row on one page")
	newest := first.removals[0]
	assert(
		newest.blobId == blobs[REMOVALS - 1] &&
		newest.ownerUserId == alice &&
		newest.removedByUserId == admin &&
		newest.reason == fmt.tprintf("reason %d", REMOVALS - 1) &&
		newest.roomId == room &&
		!newest.direct &&
		!newest.encrypted &&
		newest.chatMessageId == 0 &&
		newest.directMessageId == 0 &&
		newest.name == "" &&
		len(newest.removedAt) > 0,
		fmt.tprintf("expected the newest removal first, got %v", newest),
	)
	// An exact page boundary: a full page with nothing older says hasMore false.
	exact := list(conn, admin, first.removals[1].id, 3)
	assert(
		len(exact.removals) == 3 && !exact.hasMore,
		fmt.tprintf("expected the last three rows and no more, got %v", exact),
	)
}

// ── Files missing from storage (#132 follow-up) ───────────────────────────────────────────

@(private = "file")
attachmentSQLTestMarkMissing :: proc(
	conn: pg.Conn,
	blob: common.AttachmentBlobID,
) -> common.DatabaseAttachmentResult {
	return attachmentSQLTestRun(
		conn,
		common.DatabaseAttachmentRequest {
			action = .MarkMissing,
			// The executor sends 0 whatever the request says: the mark is the server's.
			userId = 7,
			blobId = blob,
			reason = strings.clone(ATTACHMENT_MISSING_REMOVAL_REASON, context.temp_allocator),
		},
	)
}

// The server's mark of a missing file is the tombstone an admin removal leaves, with no admin:
// a Bound or Ready blob becomes Removed with its signed fields and message link, the statement
// names the readers and writes one removal log row with a NULL admin and the reason, a blob
// already removed (or still uploading) is not found and changes nothing, and the download
// check then refuses the readers without the file.
@(test)
testAttachmentMissingFileMarkAgainstPostgreSQL :: proc(t: ^testing.T) {
	_ = t
	if os.get_env(DATABASE_SQL_TEST_ENV, context.temp_allocator) != "1" {
		return
	}
	conn := databaseAdminTestOpen(t, "attachment_missing_mark")
	alice := databaseAdminTestUser(conn, "miss-alice")
	bob := databaseAdminTestUser(conn, "miss-bob")
	dave := databaseAdminTestUser(conn, "miss-dave")
	admin := databaseAdminTestUser(conn, "miss-admin")
	databaseAdminTestGrant(conn, admin)
	room := attachmentSQLTestRoom(conn, "miss-room")
	attachmentSQLTestJoin(conn, room, alice)
	attachmentSQLTestJoin(conn, room, bob)

	// A Bound blob of a room message: alice and bob read it, dave (no member) does not.
	blob, sha := attachmentSQLTestReady(conn, alice, 100, roomID = room)
	refs := [1]common.AttachmentRef{attachmentSQLTestRef(blob, 100, sha, "report.pdf")}
	_, messageID := attachmentSQLTestPost(conn, room, alice, "the report", refs[:])
	assert(messageID > 0, "expected the message stored")
	bound := attachmentSQLTestBinding(conn, blob)

	marked := attachmentSQLTestMarkMissing(conn, blob)
	assert(
		marked.action == .MarkMissing &&
		marked.outcome == .Applied &&
		marked.removal.ownerUserId == alice &&
		marked.removal.roomId == room &&
		marked.removal.senderId == alice &&
		marked.removal.chatMessageId == messageID &&
		marked.removal.directMessageId == 0,
		fmt.tprintf("expected the bound blob marked, got %v", marked),
	)
	assert(
		attachmentSQLTestReaders(marked) == fmt.tprintf("%d,%d", alice, bob),
		fmt.tprintf(
			"expected alice and bob as readers, not dave, got %s",
			attachmentSQLTestReaders(marked),
		),
	)
	after := attachmentSQLTestBinding(conn, blob)
	assert(
		after[1:] == bound[1:] && after[0] == '3',
		fmt.tprintf("expected only the state to change, %s -> %s", bound, after),
	)
	assert(
		databaseAdminTestValue(
			conn,
			fmt.tprintf(
				"SELECT (removed_by_user_id IS NULL AND removed_at IS NOT NULL)::text " +
				"FROM attachments WHERE blob_id = decode('%s', 'hex')",
				attachmentSQLTestHex(blob),
			),
		) ==
		"true",
		"expected the tombstone to name no remover",
	)
	logged := attachmentSQLTestLogRow(conn, blob)
	assert(
		logged ==
		fmt.tprintf(
			"%d/-/%s/%d/false/false/%d/-/report.pdf",
			alice,
			ATTACHMENT_MISSING_REMOVAL_REASON,
			room,
			messageID,
		),
		fmt.tprintf("expected one log row with no admin and the reason, got %s", logged),
	)
	// Later downloads are refused at the check: a reader hears it was removed.
	for userID in ([]int{alice, bob}) {
		check := attachmentSQLTestAction(conn, .DownloadCheck, userID, blob)
		assert(
			check.outcome == .Removed,
			fmt.tprintf("expected user %d refused as removed, got %v", userID, check),
		)
	}
	assert(
		attachmentSQLTestAction(conn, .DownloadCheck, dave, blob).outcome == .NotFound,
		"expected the outsider still not found",
	)

	// Marked again (a second download's read): not found, no second row.
	again := attachmentSQLTestMarkMissing(conn, blob)
	assert(
		again.outcome == .NotFound &&
		len(again.removal.readerUserIds) == 0 &&
		attachmentSQLTestLogCount(conn) == "1",
		fmt.tprintf("expected a second mark to change nothing, got %v", again),
	)

	// The owner's Ready blob, never bound: marked, the owner its only reader.
	ready, _ := attachmentSQLTestReady(conn, bob, 40, roomID = room)
	readyMarked := attachmentSQLTestMarkMissing(conn, ready)
	assert(
		readyMarked.outcome == .Applied &&
		attachmentSQLTestReaders(readyMarked) == fmt.tprintf("%d", bob) &&
		readyMarked.removal.chatMessageId == 0 &&
		attachmentSQLTestState(conn, ready) == "3",
		fmt.tprintf("expected the ready blob marked for its owner, got %v", readyMarked),
	)
	assert(
		attachmentSQLTestLogRow(conn, ready) ==
		fmt.tprintf("%d/-/%s/%d/false/false/-/-/-", bob, ATTACHMENT_MISSING_REMOVAL_REASON, room),
		fmt.tprintf("expected the ready blob's row, got %s", attachmentSQLTestLogRow(conn, ready)),
	)

	// An admin's removal came first: the mark changes neither the tombstone nor the log.
	removedFirst, _ := attachmentSQLTestReady(conn, alice, 30, roomID = room)
	assert(
		attachmentSQLTestRemove(conn, admin, removedFirst, "spam").outcome == .Applied,
		"expected the admin's removal",
	)
	late := attachmentSQLTestMarkMissing(conn, removedFirst)
	assert(late.outcome == .NotFound, fmt.tprintf("expected the late mark refused, got %v", late))
	assert(
		attachmentSQLTestLogRow(conn, removedFirst) ==
		fmt.tprintf("%d/%d/spam/%d/false/false/-/-/-", alice, admin, room),
		fmt.tprintf(
			"expected only the admin's row, got %s",
			attachmentSQLTestLogRow(conn, removedFirst),
		),
	)

	// An upload in progress and an unknown blob are not found.
	uploading: common.AttachmentBlobID
	assert(
		attachmentSQLTestBegin(conn, bob, 10, roomID = room, blobOut = &uploading) == .Applied,
		"expected an upload",
	)
	assert(
		attachmentSQLTestMarkMissing(conn, uploading).outcome == .NotFound &&
		attachmentSQLTestState(conn, uploading) == "0",
		"expected an upload in progress left alone",
	)
	assert(
		attachmentSQLTestMarkMissing(conn, attachmentSQLTestBlob()).outcome == .NotFound,
		"expected an unknown blob not found",
	)
	assert(attachmentSQLTestLogCount(conn) == "3", "expected three log rows in all")
}
