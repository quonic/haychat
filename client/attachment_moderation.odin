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
		   payload.recipientId < 0 ||
		   payload.chatMessageId < 0 ||
		   payload.directMessageId < 0 ||
		   (payload.chatMessageId > 0 && payload.directMessageId > 0) {
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
	case .ServerAdminAttachmentRemovals:
		payload: common.ServerAdminAttachmentRemovalsPayload
		// The blob IDs are fixed-size byte fields: decode them through the heap.
		valid :=
			cbor.unmarshal(innerPacket.payload, &payload, temp_allocator = context.allocator) ==
				nil &&
			payload.beforeId >= 0 &&
			len(payload.entries) <= common.ATTACHMENT_REMOVALS_PAGE_MAX
		for entry, index in payload.entries {
			if !valid {
				break
			}
			// Newest first, and older than the cursor.
			valid =
				common.attachmentRemovalEntryIsValid(entry) &&
				(payload.beforeId == 0 || entry.id < payload.beforeId) &&
				(index == 0 || entry.id < payload.entries[index - 1].id)
		}
		if !valid {
			common.ServerAdminAttachmentRemovalsPayload_deinit(&payload)
			return ClientServerTransport_invalidPayloadEvent(
					transport,
					"invalid attachment removals payload",
				),
				true
		}
		return ClientTransportRuntimeEvent {
				kind = .AttachmentRemovalsReceived,
				serverID = transport.serverID,
				attachmentRemovals = payload,
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

ClientServerTransport_requestAttachmentRemovals :: proc(
	transport: ^ClientServerTransport,
	beforeID: int,
) -> bool {
	return ClientServerTransport_sendEncryptedRuntimeMessage(
		transport,
		.ClientAdminListAttachmentRemovals,
		common.ClientAdminListAttachmentRemovalsPayload{beforeId = beforeID},
	)
}

// ── State (UI thread) ────────────────────────────────────────────

// Removes a file from the server (admins): its message stays and lists it as removed. reason is
// optional (at most 500 bytes, no control characters): the server logs it and (protocol 29)
// keeps it in the removal log, which only admins can list. Returns "" when the request went
// out, otherwise why not (static or temp). The answer lands in State.adminRequest (action
// RemoveAttachment, blobID).
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

// Asks for a page of the removal log (admins, protocol 29): beforeID 0 for the newest page,
// otherwise the oldest entry ID held (Load more). The answer arrives as
// AttachmentRemovalsReceived. Returns "" when the request went out.
State_requestAttachmentRemovals :: proc(state: ^State, serverID: int, beforeID := 0) -> string {
	transportIndex := State_selectedTransportIndexForServerID(state^, serverID)
	if transportIndex < 0 {
		return "No server transport selected"
	}
	if !State_isServerConnected(state, serverID) {
		return NOT_CONNECTED_MESSAGE
	}
	transport := &state.serverTransports[transportIndex]
	ClientNetworkWorker_lock(state.networkWorker)
	sent := ClientServerTransport_requestAttachmentRemovals(transport, max(beforeID, 0))
	ClientNetworkWorker_unlock(state.networkWorker)
	if !sent {
		return "Failed to send the removed files request"
	}
	if index := State_serverConnectionIndex(state^, serverID); index >= 0 {
		state.serverConnections[index].attachmentRemovalsPending = true
	}
	return ""
}

// Load more: the page before the oldest entry held. Returns "" when the request went out.
State_requestMoreAttachmentRemovals :: proc(state: ^State, serverID: int) -> string {
	index := State_serverConnectionIndex(state^, serverID)
	if index < 0 {
		return NOT_CONNECTED_MESSAGE
	}
	connection := &state.serverConnections[index]
	if len(connection.attachmentRemovals) == 0 || !connection.attachmentRemovalsHasMore {
		return State_requestAttachmentRemovals(state, serverID)
	}
	oldest := connection.attachmentRemovals[len(connection.attachmentRemovals) - 1].id
	return State_requestAttachmentRemovals(state, serverID, oldest)
}

// The removal log entries held for serverID (borrowed, newest first), whether a page arrived
// in this session, whether older entries follow, and whether a request is waiting.
State_attachmentRemovals :: proc(
	state: ^State,
	serverID: int,
) -> (
	entries: []common.AttachmentRemovalEntry,
	loaded: bool,
	hasMore: bool,
	pending: bool,
) {
	index := State_serverConnectionIndex(state^, serverID)
	if index < 0 {
		return
	}
	connection := &state.serverConnections[index]
	return connection.attachmentRemovals[:],
		connection.hasAttachmentRemovals,
		connection.attachmentRemovalsHasMore,
		connection.attachmentRemovalsPending
}

// AttachmentRemovalsReceived: a first page (beforeId 0) replaces the list; a later page adds
// the entries older than the oldest held, so a page boundary neither drops nor repeats one.
// Takes the entries.
State_attachmentRemovalsReceived :: proc(
	state: ^State,
	serverID: int,
	page: ^common.ServerAdminAttachmentRemovalsPayload,
) {
	defer common.ServerAdminAttachmentRemovalsPayload_deinit(page)
	index := State_serverConnectionIndex(state^, serverID)
	if index < 0 {
		return
	}
	connection := &state.serverConnections[index]
	connection.attachmentRemovalsPending = false
	if page.beforeId == 0 {
		common.AttachmentRemovalEntries_deinit(&connection.attachmentRemovals)
		connection.attachmentRemovals = page.entries
		page.entries = nil
	} else {
		held := connection.attachmentRemovals[:]
		oldest := len(held) > 0 ? held[len(held) - 1].id : max(int)
		for &entry in page.entries {
			if entry.id < oldest {
				append(&connection.attachmentRemovals, entry)
				oldest = entry.id
				entry = {}
			}
		}
	}
	connection.hasAttachmentRemovals = true
	connection.attachmentRemovalsHasMore = page.hasMore
}

// A removal this admin made (ServerAdminActionResult RemoveAttachment): a removal log already
// on screen shows it at once.
State_attachmentRemovalApplied :: proc(state: ^State, serverID: int) {
	index := State_serverConnectionIndex(state^, serverID)
	if index < 0 || !state.serverConnections[index].hasAttachmentRemovals {
		return
	}
	_ = State_requestAttachmentRemovals(state, serverID)
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

// The index of messageID among messages ordered by ID, or -1.
@(private = "file")
attachmentMessageIndex :: proc(messages: []$T, messageID: int) -> int {
	low, high := 0, len(messages)
	for low < high {
		middle := low + (high - low) / 2
		if messages[middle].id < messageID {
			low = middle + 1
		} else {
			high = middle
		}
	}
	if low < len(messages) && messages[low].id == messageID {
		return low
	}
	return -1
}

// How State_attachmentRemoved found the file's message (for tests).
AttachmentRemovedLookup :: enum u8 {
	// The notice named the message (protocol 29) and only that entry was looked at.
	Direct,
	// The notice named none (an unbound blob, or an older server): every cache was scanned.
	Scan,
}

// ServerAttachmentRemoved: an admin removed blobID. Since protocol 29 the notice names the
// message (chatMessageId in roomId, or directMessageId with the other side of senderId and
// recipientId), so only that entry is marked; a notice naming none (a blob no message holds)
// falls back to scanning every room and direct message cache of the server. Returns how many
// shown files were marked and which way it looked.
State_attachmentRemoved :: proc(
	state: ^State,
	serverID: int,
	notice: common.ServerAttachmentRemovedPayload,
) -> (
	marked: int,
	lookup: AttachmentRemovedLookup,
) {
	blobID := notice.blobId
	storedSize: u64 = 0
	lookup = .Scan
	if notice.chatMessageId > 0 || notice.directMessageId > 0 {
		lookup = .Direct
	}
	markRoom := proc(entry: ^RoomMessageEntry, blobID: common.AttachmentBlobID) -> (u64, bool) {
		attachmentMarkRefsRemoved(entry.attachments[:], blobID)
		return attachmentMarkFilesRemoved(entry.files[:], blobID)
	}
	markDirect := proc(
		entry: ^DirectMessageEntry,
		blobID: common.AttachmentBlobID,
	) -> (
		u64,
		bool,
	) {
		attachmentMarkRefsRemoved(entry.attachments[:], blobID)
		return attachmentMarkFilesRemoved(entry.files[:], blobID)
	}
	if index := State_serverRoomCacheIndex(state^, serverID);
	   index >= 0 && notice.directMessageId == 0 {
		cache := &state.server_room_caches[index]
		for &room in cache.roomCaches {
			if lookup == .Direct {
				if room.roomID != notice.roomId {
					continue
				}
				entryIndex := attachmentMessageIndex(room.messages[:], notice.chatMessageId)
				if entryIndex < 0 {
					break
				}
				if size, found := markRoom(&room.messages[entryIndex], blobID); found {
					marked += 1
					storedSize = size
				}
				break
			}
			for &entry in room.messages {
				if size, found := markRoom(&entry, blobID); found {
					marked += 1
					storedSize = size
				}
			}
		}
	}
	if index := State_serverDirectCacheIndex(state^, serverID);
	   index >= 0 && notice.chatMessageId == 0 {
		cache := &state.serverDirectCaches[index]
		// The conversation is with the other side of the message.
		peerUserID := notice.senderId
		if peerUserID == State_selfUserID(state, serverID) {
			peerUserID = notice.recipientId
		}
		for &conversation in cache.caches {
			if lookup == .Direct {
				if conversation.peerUserID != peerUserID {
					continue
				}
				entryIndex := attachmentMessageIndex(
					conversation.messages[:],
					notice.directMessageId,
				)
				if entryIndex >= 0 {
					if size, found := markDirect(&conversation.messages[entryIndex], blobID);
					   found {
						marked += 1
						storedSize = size
					}
				}
				break
			}
			for &entry in conversation.messages {
				if size, found := markDirect(&entry, blobID); found {
					marked += 1
					storedSize = size
				}
			}
		}
		for &conversation in cache.conversations {
			if lookup == .Direct && conversation.peerUserId != peerUserID {
				continue
			}
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
	return
}
