package client

// Attachment moderation (protocol 28, docs/plan/2026-11-19-file-attachments.md F3, D22). Admins
// only, with no assignable permission; the server checks the admin role in the statement, so
// the client only decides which controls to offer (State_isServerAdmin).
//
// - Removal: State_removeAttachment sends ClientAdminRemoveAttachment through the admin request
//   tracker (State.adminRequest, admin.odin): the answer is ServerAdminActionResult
//   {RemoveAttachment, userId = the owner, blobId}, or a ServerProtocolError while pending.
// - Usage: State_requestAttachmentUsage sends ClientAdminAttachmentUsage; the answer
//   (ServerAdminAttachmentUsage) is kept per server in ServerConnection.attachmentUsage
//   (State_attachmentUsage).
// - Every session of each account that may read a removed file's message gets
//   ServerAttachmentRemoved: State_attachmentRemoved marks the file removed in every room and
//   direct message cache of that server (MessageFile.removed and the message's own reference,
//   so a message opened later shows it removed too, and the conversation list's preview),
//   forgets an unsent upload of it, gives this account's quota the bytes back, and ends any
//   download of it in the transfer worker (ATTACHMENT_REMOVED_MESSAGE). A file card learns it
//   was removed from MessageFile.removed (State_messageFiles), and
//   State_downloadMessageAttachment refuses it. Removals made in SQL reach clients only with
//   the next history fetch, whose references carry removed.

import "../common"
import "core:encoding/cbor"

// ── Transport (network worker) ───────────────────────────────────

ClientServerTransport_translateAttachmentModerationPacket :: proc(
	transport: ^ClientServerTransport,
	innerPacket: common.Packet,
) -> (
	ClientTransportRuntimeEvent,
	bool,
) {
	#partial switch innerPacket.messageType {
	case .ServerAttachmentRemoved:
		payload: common.ServerAttachmentRemovedPayload
		// Fixed-size byte fields decode through the temporary allocator; use the heap.
		if cbor.unmarshal(innerPacket.payload, &payload, temp_allocator = context.allocator) !=
			   nil ||
		   !common.attachmentBlobIDIsSet(payload.blobId) ||
		   payload.roomId < 0 ||
		   payload.senderId < 0 ||
		   payload.recipientId < 0 {
			return ClientServerTransport_invalidPayloadEvent(
					transport,
					"invalid attachment removal payload",
				),
				true
		}
		return ClientTransportRuntimeEvent {
				kind = .AttachmentRemoved,
				serverID = transport.serverID,
				attachmentRemoved = payload,
			},
			true
	case .ServerAdminAttachmentUsage:
		payload: common.ServerAdminAttachmentUsagePayload
		if cbor.unmarshal(innerPacket.payload, &payload) != nil ||
		   len(payload.accounts) > common.ATTACHMENT_USAGE_ACCOUNTS_MAX {
			common.ServerAdminAttachmentUsagePayload_deinit(&payload)
			return ClientServerTransport_invalidPayloadEvent(
					transport,
					"invalid attachment usage payload",
				),
				true
		}
		return ClientTransportRuntimeEvent {
				kind = .AttachmentUsageReceived,
				serverID = transport.serverID,
				attachmentUsage = payload,
			},
			true
	}
	return {}, false
}

ClientServerTransport_removeAttachment :: proc(
	transport: ^ClientServerTransport,
	blobID: common.AttachmentBlobID,
	reason: string,
) -> bool {
	return ClientServerTransport_sendEncryptedRuntimeMessage(
		transport,
		.ClientAdminRemoveAttachment,
		common.ClientAdminRemoveAttachmentPayload{blobId = blobID, reason = reason},
	)
}

ClientServerTransport_requestAttachmentUsage :: proc(transport: ^ClientServerTransport) -> bool {
	return ClientServerTransport_sendEncryptedRuntimeMessage(
		transport,
		.ClientAdminAttachmentUsage,
		common.ClientAdminAttachmentUsagePayload{},
	)
}

// ── State (UI thread) ────────────────────────────────────────────

// Removes a file from the server (admins): its message stays and lists it as removed. reason is
// optional (at most 500 bytes, no control characters), logged on the server and never shown to
// anyone. Returns "" when the request went out, otherwise why not (static or temp). The answer
// lands in State.adminRequest (action RemoveAttachment, blobID).
State_removeAttachment :: proc(
	state: ^State,
	serverID: int,
	blobID: common.AttachmentBlobID,
	reason := "",
) -> string {
	return State_sendAdminRequest(
		state,
		serverID,
		AdminRequest{action = .RemoveAttachment, blobID = blobID, reason = reason},
	)
}

// Asks for the server's storage use (admins). The answer arrives as AttachmentUsageReceived and
// is kept in ServerConnection.attachmentUsage. Returns "" when the request went out.
State_requestAttachmentUsage :: proc(state: ^State, serverID: int) -> string {
	transportIndex := State_selectedTransportIndexForServerID(state^, serverID)
	if transportIndex < 0 {
		return "No server transport selected"
	}
	if !State_isServerConnected(state, serverID) {
		return NOT_CONNECTED_MESSAGE
	}
	transport := &state.serverTransports[transportIndex]
	ClientNetworkWorker_lock(state.networkWorker)
	sent := ClientServerTransport_requestAttachmentUsage(transport)
	ClientNetworkWorker_unlock(state.networkWorker)
	if !sent {
		return "Failed to send the storage usage request"
	}
	if index := State_serverConnectionIndex(state^, serverID); index >= 0 {
		state.serverConnections[index].attachmentUsagePending = true
	}
	return ""
}

// The last storage use the server reported on serverID (borrowed), and whether one arrived in
// this session.
State_attachmentUsage :: proc(
	state: ^State,
	serverID: int,
) -> (
	usage: ^common.ServerAdminAttachmentUsagePayload,
	ok: bool,
) {
	index := State_serverConnectionIndex(state^, serverID)
	if index < 0 || !state.serverConnections[index].hasAttachmentUsage {
		return nil, false
	}
	return &state.serverConnections[index].attachmentUsage, true
}

// AttachmentUsageReceived: keeps the usage (takes the accounts).
State_attachmentUsageReceived :: proc(
	state: ^State,
	serverID: int,
	usage: ^common.ServerAdminAttachmentUsagePayload,
) {
	index := State_serverConnectionIndex(state^, serverID)
	if index < 0 {
		return
	}
	connection := &state.serverConnections[index]
	common.ServerAdminAttachmentUsagePayload_deinit(&connection.attachmentUsage)
	connection.attachmentUsage = usage^
	connection.hasAttachmentUsage = true
	connection.attachmentUsagePending = false
	usage.accounts = nil
}

// Marks blobID removed in refs; true when it was there.
@(private = "file")
attachmentMarkRefsRemoved :: proc(
	refs: []common.AttachmentRef,
	blobID: common.AttachmentBlobID,
) -> bool {
	found := false
	for &ref in refs {
		if ref.blobId == blobID {
			ref.removed = true
			found = true
		}
	}
	return found
}

// Marks blobID removed in files; the file's stored size when it was there.
@(private = "file")
attachmentMarkFilesRemoved :: proc(
	files: []MessageFile,
	blobID: common.AttachmentBlobID,
) -> (
	storedSize: u64,
	found: bool,
) {
	for &file in files {
		if file.blobId == blobID {
			file.removed = true
			storedSize = file.storedSize
			found = true
		}
	}
	return
}

// A cached message seen again (a history page fetched once more): the files the server now
// lists as removed become removed here too. Only false to true, and only the server's flag,
// which no signature covers.
messageAttachmentsNoteRemoved :: proc(
	refs: []common.AttachmentRef,
	files: []MessageFile,
	incoming: []common.AttachmentRef,
) {
	for ref in incoming {
		if !ref.removed {
			continue
		}
		attachmentMarkRefsRemoved(refs, ref.blobId)
		attachmentMarkFilesRemoved(files, ref.blobId)
	}
}

// ServerAttachmentRemoved: an admin removed blobID. Returns how many shown files were marked.
State_attachmentRemoved :: proc(
	state: ^State,
	serverID: int,
	notice: common.ServerAttachmentRemovedPayload,
) -> int {
	blobID := notice.blobId
	marked := 0
	storedSize: u64 = 0
	if index := State_serverRoomCacheIndex(state^, serverID); index >= 0 {
		cache := &state.server_room_caches[index]
		for &room in cache.roomCaches {
			for &entry in room.messages {
				attachmentMarkRefsRemoved(entry.attachments[:], blobID)
				if size, found := attachmentMarkFilesRemoved(entry.files[:], blobID); found {
					marked += 1
					storedSize = size
				}
			}
		}
	}
	if index := State_serverDirectCacheIndex(state^, serverID); index >= 0 {
		cache := &state.serverDirectCaches[index]
		for &conversation in cache.caches {
			for &entry in conversation.messages {
				attachmentMarkRefsRemoved(entry.attachments[:], blobID)
				if size, found := attachmentMarkFilesRemoved(entry.files[:], blobID); found {
					marked += 1
					storedSize = size
				}
			}
		}
		for &conversation in cache.conversations {
			attachmentMarkRefsRemoved(conversation.lastAttachments[:], blobID)
		}
	}
	// An unsent upload of this account: it can no longer be sent.
	for index := len(state.attachmentUploads) - 1; index >= 0; index -= 1 {
		upload := &state.attachmentUploads[index]
		if upload.serverID == serverID && upload.blobId == blobID {
			storedSize = upload.storedSize
			UploadedAttachment_deinit(upload)
			ordered_remove(&state.attachmentUploads, index)
		}
	}
	// This account's own file no longer counts toward its quota (D22).
	if notice.senderId > 0 && notice.senderId == State_selfUserID(state, serverID) {
		if index := State_serverConnectionIndex(state^, serverID); index >= 0 {
			limits := &state.serverConnections[index].attachmentLimits
			limits.usedBytes = limits.usedBytes > storedSize ? limits.usedBytes - storedSize : 0
		}
	}
	if state.transferWorker != nil {
		ClientTransferWorker_abandonDownloads(
			state.transferWorker,
			serverID,
			blobID,
			common.ATTACHMENT_REMOVED_MESSAGE,
		)
	}
	return marked
}
