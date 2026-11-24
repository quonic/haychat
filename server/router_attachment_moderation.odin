package server

import "../common"
import "core:fmt"
import "core:strings"

// Attachment moderation (protocol 28, attachments plan F3, D22). Admins only, with no
// assignable permission; the database statement checks the admin role (DATABASE_ACTOR_IS_ADMIN_SQL)
// in the same statement as the read or the change, so the router only shapes and fans out:
//
// - ClientAdminRemoveAttachment -> DATABASE_ATTACHMENT_REMOVE_SQL (a Ready or Bound blob becomes
//   a Removed tombstone with every signed field and its message link kept) -> every active
//   download of the blob ends with ServerAttachmentRefused{ATTACHMENT_REMOVED_MESSAGE}, the
//   storage worker deletes the file (StorageDeleteBlobs), every session of each account that may
//   read the message gets ServerAttachmentRemoved (protocol 29: with the message's ID), and the
//   admin ServerAdminActionResult. The reason is logged with the blob, the admin and the owner,
//   and (protocol 29) kept in the removal log the same statement writes; only admins list it.
// - ClientAdminListAttachmentRemovals{beforeId} (protocol 29, #138) ->
//   DATABASE_ATTACHMENT_REMOVALS_SQL -> ServerAdminAttachmentRemovals{beforeId, entries,
//   hasMore}, newest first and paged by row ID like history.
// - ClientAdminAttachmentUsage -> DATABASE_ATTACHMENT_USAGE_SQL -> StorageFreeSpace (statfs on
//   the blob directory) -> ServerAdminAttachmentUsage.
// - Hourly (and at startup), DATABASE_ATTACHMENT_TOMBSTONE_FILES_SQL lists the newest bound
//   tombstones and the storage worker deletes their files again: a removal made in SQL
//   (deploy/sql/remove-attachment.sql) cannot reach the storage worker or the clients, so its
//   file goes within the hour and clients see it on their next history fetch.
//
// Both requests are .Attachment database requests, which survive the admin's disconnect: a
// removal the database applied always deletes its file and tells the readers, and only the
// answer to the admin is checked against the session it was made for.

ATTACHMENT_REMOVED_RESULT_MESSAGE :: "Removed the attachment"

MainRouterState_handleClientAdminRemoveAttachment :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	payload: []u8,
) {
	userID, ok := MainRouterState_authenticatedUserForAdminRequest(pm, state, peerID)
	if !ok {
		return
	}
	session, _ := MainRouterState_getPeerSession(state, peerID)
	req: common.ClientAdminRemoveAttachmentPayload
	defer common.ClientAdminRemoveAttachmentPayload_deinit(&req)
	if !attachmentDecode(payload, &req) || !common.attachmentBlobIDIsSet(req.blobId) {
		MainRouterState_sendProtocolError(pm, state, peerID, ADMIN_INVALID_REQUEST_MESSAGE)
		return
	}
	if !common.attachmentRemoveReasonIsValid(req.reason) {
		MainRouterState_sendProtocolError(
			pm,
			state,
			peerID,
			common.ATTACHMENT_REMOVE_REASON_INVALID_MESSAGE,
		)
		return
	}
	attachmentDatabaseSend(
		pm,
		state,
		peerID,
		common.DatabaseAttachmentRequest {
			action = .Remove,
			userId = userID,
			blobId = req.blobId,
			reason = strings.clone(req.reason),
		},
		PendingDBRequest {
			sessionID = session.transport.sessionID,
			targetUserID = userID,
			description = req.reason,
		},
	)
	// The pending request owns the reason now (the database request has its own copy).
	req.reason = ""
}

MainRouterState_handleClientAdminListAttachmentRemovals :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	payload: []u8,
) {
	userID, ok := MainRouterState_authenticatedUserForAdminRequest(pm, state, peerID)
	if !ok {
		return
	}
	session, _ := MainRouterState_getPeerSession(state, peerID)
	req: common.ClientAdminListAttachmentRemovalsPayload
	if !attachmentDecode(payload, &req) || req.beforeId < 0 {
		MainRouterState_sendProtocolError(pm, state, peerID, ADMIN_INVALID_REQUEST_MESSAGE)
		return
	}
	attachmentDatabaseSend(
		pm,
		state,
		peerID,
		common.DatabaseAttachmentRequest {
			action = .Removals,
			userId = userID,
			beforeId = req.beforeId,
			limit = common.ATTACHMENT_REMOVALS_PAGE_MAX,
		},
		PendingDBRequest {
			sessionID = session.transport.sessionID,
			targetUserID = userID,
			attachmentBeforeID = req.beforeId,
		},
	)
}

MainRouterState_handleClientAdminAttachmentUsage :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	payload: []u8,
) {
	_ = payload
	userID, ok := MainRouterState_authenticatedUserForAdminRequest(pm, state, peerID)
	if !ok {
		return
	}
	session, _ := MainRouterState_getPeerSession(state, peerID)
	attachmentDatabaseSend(
		pm,
		state,
		peerID,
		common.DatabaseAttachmentRequest {
			action = .Usage,
			userId = userID,
			limit = common.ATTACHMENT_USAGE_ACCOUNTS_MAX,
		},
		PendingDBRequest{sessionID = session.transport.sessionID, targetUserID = userID},
	)
}

// Ends every active download of blobId with ServerAttachmentRefused{message}. Reads the
// storage worker still answers find no transfer and are dropped.
MainRouterState_attachmentCancelDownloads :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	blobId: common.AttachmentBlobID,
	message: string,
) -> int {
	keys := make([dynamic]AttachmentDownloadKey, 0, 4)
	defer delete(keys)
	for key in state.attachments.downloads {
		if key.blobId == blobId {
			append(&keys, key)
		}
	}
	for key in keys {
		download := state.attachments.downloads[key]
		attachmentRefuse(pm, state, key.peerID, download.sessionID, 0, blobId, message)
		attachmentRemoveDownload(state, key)
	}
	return len(keys)
}

MainRouterState_attachmentRemoveResult :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	request: PendingDBRequest,
	result: common.DatabaseAttachmentResult,
) {
	_, live := attachmentSession(state, request.peerID, request.sessionID)
	switch result.outcome {
	case .Applied:
	case .NotAdmin:
		if live {
			MainRouterState_sendAdminRequired(pm, state, request.peerID)
		}
		return
	case .NotFound,
	     .NotMember,
	     .SendDenied,
	     .ChatDisabled,
	     .EncryptionMismatch,
	     .UnknownRecipient,
	     .Restricted,
	     .TooLarge,
	     .QuotaExceeded,
	     .RateExceeded,
	     .CapacityExceeded,
	     .AttachDenied,
	     .Removed:
		if live {
			MainRouterState_sendProtocolError(
				pm,
				state,
				request.peerID,
				common.ATTACHMENT_NOT_FOUND_MESSAGE,
			)
		}
		return
	}
	blobId := request.blobID
	removal := result.removal
	hex := storageBlobHex(blobId)
	defer delete(hex)
	if len(request.description) > 0 {
		fmt.printfln(
			"[Admin] Attachment %s of user %d removed by user %d: %s",
			hex,
			removal.ownerUserId,
			request.targetUserID,
			request.description,
		)
	} else {
		fmt.printfln(
			"[Admin] Attachment %s of user %d removed by user %d",
			hex,
			removal.ownerUserId,
			request.targetUserID,
		)
	}

	// Downloads first, so no chunk read after the delete reaches anyone, then the file.
	MainRouterState_attachmentCancelDownloads(pm, state, blobId, common.ATTACHMENT_REMOVED_MESSAGE)
	blobs := make([dynamic]common.DatabaseAttachmentBlob, 0, 1)
	append(&blobs, common.DatabaseAttachmentBlob{blobId = blobId, state = .Removed})
	attachmentStorageSend(
		pm,
		state,
		StorageDeleteBlobs{blobs = blobs},
		AttachmentPendingStorage{kind = .DeleteBlobs},
	)

	MainRouterState_attachmentSendRemoved(pm, state, blobId, removal)
	if live {
		MainRouterState_sendPeerMessage(
			pm,
			state,
			request.peerID,
			.ServerAdminActionResult,
			common.ServerAdminActionResultPayload {
				action = .RemoveAttachment,
				userId = removal.ownerUserId,
				message = ATTACHMENT_REMOVED_RESULT_MESSAGE,
				blobId = blobId,
			},
		)
	}
}

// Tells every session of each account the removal statement named as a reader that the blob
// is a Removed tombstone now (ServerAttachmentRemoved, protocol 29: with the message's ID).
// Shared by an admin's removal and the server's mark of a missing file (#132 follow-up).
MainRouterState_attachmentSendRemoved :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	blobId: common.AttachmentBlobID,
	removal: common.DatabaseAttachmentRemoval,
) {
	notice := common.ServerAttachmentRemovedPayload {
		blobId          = blobId,
		roomId          = removal.roomId,
		senderId        = removal.senderId,
		recipientId     = removal.recipientId,
		chatMessageId   = removal.chatMessageId,
		directMessageId = removal.directMessageId,
	}
	for userID in removal.readerUserIds {
		MainRouterState_sendMessageToUserID(pm, state, userID, .ServerAttachmentRemoved, notice)
	}
}

MainRouterState_attachmentUsageResult :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	request: PendingDBRequest,
	result: common.DatabaseAttachmentResult,
) {
	if _, live := attachmentSession(state, request.peerID, request.sessionID); !live {
		return
	}
	if result.outcome != .Applied {
		MainRouterState_sendAdminRequired(pm, state, request.peerID)
		return
	}
	// The database response frees its own copy; the pending step keeps this one.
	accounts := make([dynamic]common.AttachmentAccountUsage, 0, len(result.accounts))
	append(&accounts, ..result.accounts[:])
	attachmentStorageSend(
		pm,
		state,
		StorageFreeSpace{},
		AttachmentPendingStorage {
			kind = .FreeSpace,
			peerID = request.peerID,
			sessionID = request.sessionID,
			usedBytes = result.usedBytes,
			accounts = accounts,
		},
	)
}

// Answers a removal log page (protocol 29): the entries, newest first, with the cursor the
// request carried. The database response frees the entries after the send.
MainRouterState_attachmentRemovalsResult :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	request: PendingDBRequest,
	result: common.DatabaseAttachmentResult,
) {
	if _, live := attachmentSession(state, request.peerID, request.sessionID); !live {
		return
	}
	if result.outcome != .Applied {
		MainRouterState_sendAdminRequired(pm, state, request.peerID)
		return
	}
	attachmentSend(
		pm,
		state,
		request.peerID,
		request.sessionID,
		.ServerAdminAttachmentRemovals,
		common.ServerAdminAttachmentRemovalsPayload {
			beforeId = request.attachmentBeforeID,
			entries = result.removals,
			hasMore = result.hasMore,
		},
	)
}

// Sends the usage a FreeSpace step carried, with the free space when known, and frees it.
MainRouterState_attachmentSendUsage :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	pending: ^AttachmentPendingStorage,
	freeBytes: u64,
	freeBytesKnown: bool,
) {
	defer AttachmentPendingStorage_deinit(pending)
	attachmentSend(
		pm,
		state,
		pending.peerID,
		pending.sessionID,
		.ServerAdminAttachmentUsage,
		common.ServerAdminAttachmentUsagePayload {
			usedBytes = pending.usedBytes,
			capacityBytes = u64(max(pm.config.attachmentCapacityBytes, 0)),
			freeBytes = freeBytesKnown ? freeBytes : 0,
			freeBytesKnown = freeBytesKnown,
			accounts = pending.accounts,
		},
	)
}

// The hourly tombstone pass: asks for the newest bound tombstones.
MainRouterState_attachmentsTombstonePass :: proc(pm: ^ProcessManager, state: ^MainRouterState) {
	attachmentDatabaseSend(
		pm,
		state,
		0,
		common.DatabaseAttachmentRequest {
			action = .TombstoneFiles,
			limit = ATTACHMENT_TOMBSTONE_FILES_BATCH,
		},
		{},
	)
}

// Deletes the tombstones' files again (idempotent), after ending any download of one: a
// removal made in SQL leaves running downloads the router did not hear about.
MainRouterState_attachmentTombstoneFilesResult :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	result: common.DatabaseAttachmentResult,
) {
	if len(result.blobs) == 0 {
		return
	}
	for blob in result.blobs {
		MainRouterState_attachmentCancelDownloads(
			pm,
			state,
			blob.blobId,
			common.ATTACHMENT_REMOVED_MESSAGE,
		)
	}
	blobs := make([dynamic]common.DatabaseAttachmentBlob, 0, len(result.blobs))
	append(&blobs, ..result.blobs[:])
	attachmentStorageSend(
		pm,
		state,
		StorageDeleteBlobs{blobs = blobs},
		AttachmentPendingStorage{kind = .DeleteTombstones},
	)
}
