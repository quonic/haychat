package server

import "../common"
import "core:encoding/cbor"
import "core:fmt"
import "core:strings"

// Editing and deleting messages (protocol 30, #76, docs/plan/2026-11-19-message-edit-delete.md).
// The router checks the shape of each request and every signature it can check against the
// session's identity key (the account's users.public_key):
//
// - a plaintext edit's signature (verifyRoomMessageEdit, verifyDirectMessageEdit) and an
//   author delete's (verifyRoomMessageDelete, verifyDirectMessageDelete), both over the
//   originalClientMessageId the client names, which the statement then compares with the
//   message's own;
// - a sealed room edit like a new sealed message (MainRouterState_checkSealedRoomMessage: its
//   structure and signature over this server, the room, the account, its chain position and the
//   edit's client message ID); the statement checks the epoch;
// - a sealed direct message edit's envelope structure; the database worker verifies it against
//   the recipient's identity key, as for a new sealed direct message.
//
// Everything else is checked in the statement that makes the change
// (database_message_edits.odin). An applied edit goes to every session of each reader
// (ServerRoomMessageEdited, ServerDirectMessageEdited), a delete likewise
// (ServerRoomMessageDeleted, ServerDirectMessageDeleted) after its files' downloads ended, the
// storage worker was told to delete them and the readers heard ServerAttachmentRemoved for each
// (D8), and an edit fetch answers only the requester (ServerMessageEdits). The requests are
// .MessageChange database requests that survive their peer's disconnect: a delete the database
// applied always deletes its files and tells the readers, and only the answer to the requester is
// checked against the session it was made for.

MainRouterState_handleClientEditRoomMessage :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	payload: []u8,
) {
	req: common.ClientEditRoomMessagePayload
	err := cbor.unmarshal(payload, &req, temp_allocator = context.allocator)
	defer common.ClientEditRoomMessagePayload_deinit(&req)
	if err != nil {
		MainRouterState_sendProtocolError(pm, state, peerID, common.MESSAGE_EDIT_INVALID_MESSAGE)
		return
	}
	session, ok := MainRouterState_getPeerSession(state, peerID)
	if !ok || !session.isAuthenticated {
		MainRouterState_sendProtocolError(pm, state, peerID, "Unauthenticated message edit")
		return
	}
	if req.roomId <= 0 ||
	   req.messageId <= 0 ||
	   !common.clientMessageIDIsSet(req.originalClientMessageId) ||
	   !common.clientMessageIDIsSet(req.clientMessageId) ||
	   req.clientMessageId == req.originalClientMessageId ||
	   !common.messageEditContentLengthIsValid(len(req.content)) {
		MainRouterState_sendMessageRefusal(
			pm,
			state,
			peerID,
			common.MESSAGE_EDIT_INVALID_MESSAGE,
			req.messageId,
		)
		return
	}
	request := common.DatabaseMessageChangeRequest {
		action                  = .EditRoom,
		actorUserId             = session.authenticatedUserID,
		roomId                  = req.roomId,
		messageId               = req.messageId,
		originalClientMessageId = req.originalClientMessageId,
		clientMessageId         = req.clientMessageId,
	}
	if len(req.sealed) > 0 {
		// D11: a sealed edit is a sealed message on the sender's current chain, checked as one.
		message, valid := MainRouterState_checkSealedRoomMessage(
			state,
			common.ClientChatMessagePayload {
				roomId = req.roomId,
				content = req.content,
				clientMessageId = req.clientMessageId,
				sealed = req.sealed,
			},
			session.authenticatedUserID,
			session.clientIdentityPublicKey,
		)
		if !valid || req.signature != {} {
			MainRouterState_sendMessageRefusal(
				pm,
				state,
				peerID,
				common.SEALED_ROOM_MESSAGE_INVALID_MESSAGE,
				req.messageId,
			)
			return
		}
		request.epoch = message.header.epoch
		request.chainId = message.header.chainID
		request.chainIndex = int(message.header.index)
		request.content = strings.clone("")
		request.sealed = req.sealed
		req.sealed = nil
	} else {
		if !common.verifyRoomMessageEdit(
			common.MessageChangeFields {
				serverIdentityPublicKey = state.serverIdentityPublicKey,
				conversationID = req.roomId,
				senderUserID = session.authenticatedUserID,
				original = req.originalClientMessageId,
				edit = req.clientMessageId,
			},
			req.content,
			session.clientIdentityPublicKey,
			req.signature,
		) {
			MainRouterState_sendMessageRefusal(
				pm,
				state,
				peerID,
				common.MESSAGE_EDIT_SIGNATURE_INVALID_MESSAGE,
				req.messageId,
			)
			return
		}
		request.content = strings.clone(req.content)
		request.signature = req.signature
	}
	MainRouterState_sendMessageChange(pm, state, peerID, session, request)
}

MainRouterState_handleClientDeleteRoomMessage :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	payload: []u8,
) {
	req: common.ClientDeleteRoomMessagePayload
	if cbor.unmarshal(payload, &req, temp_allocator = context.allocator) != nil {
		MainRouterState_sendProtocolError(pm, state, peerID, common.MESSAGE_DELETE_INVALID_MESSAGE)
		return
	}
	session, ok := MainRouterState_getPeerSession(state, peerID)
	if !ok || !session.isAuthenticated {
		MainRouterState_sendProtocolError(pm, state, peerID, "Unauthenticated message delete")
		return
	}
	if req.roomId <= 0 || req.messageId <= 0 {
		MainRouterState_sendMessageRefusal(
			pm,
			state,
			peerID,
			common.MESSAGE_DELETE_INVALID_MESSAGE,
			req.messageId,
		)
		return
	}
	// D5, D6: no signature asks for an admin's moderation delete, which the statement checks.
	adminDelete := req.signature == {}
	if !adminDelete &&
	   !common.verifyRoomMessageDelete(
		   common.MessageChangeFields {
			   serverIdentityPublicKey = state.serverIdentityPublicKey,
			   conversationID = req.roomId,
			   senderUserID = session.authenticatedUserID,
			   original = req.originalClientMessageId,
		   },
		   session.clientIdentityPublicKey,
		   req.signature,
	   ) {
		MainRouterState_sendMessageRefusal(
			pm,
			state,
			peerID,
			common.MESSAGE_DELETE_SIGNATURE_INVALID_MESSAGE,
			req.messageId,
		)
		return
	}
	MainRouterState_sendMessageChange(
		pm,
		state,
		peerID,
		session,
		common.DatabaseMessageChangeRequest {
			action = .DeleteRoom,
			actorUserId = session.authenticatedUserID,
			roomId = req.roomId,
			messageId = req.messageId,
			originalClientMessageId = req.originalClientMessageId,
			signature = req.signature,
			adminDelete = adminDelete,
		},
	)
}

MainRouterState_handleClientEditDirectMessage :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	payload: []u8,
) {
	req: common.ClientEditDirectMessagePayload
	err := cbor.unmarshal(payload, &req, temp_allocator = context.allocator)
	defer common.ClientEditDirectMessagePayload_deinit(&req)
	if err != nil {
		MainRouterState_sendProtocolError(pm, state, peerID, common.MESSAGE_EDIT_INVALID_MESSAGE)
		return
	}
	session, ok := MainRouterState_getPeerSession(state, peerID)
	if !ok || !session.isAuthenticated {
		MainRouterState_sendProtocolError(pm, state, peerID, "Unauthenticated message edit")
		return
	}
	senderID := session.authenticatedUserID
	if req.peerUserId <= 0 ||
	   req.peerUserId == senderID ||
	   req.messageId <= 0 ||
	   !common.clientMessageIDIsSet(req.originalClientMessageId) ||
	   !common.clientMessageIDIsSet(req.clientMessageId) ||
	   req.clientMessageId == req.originalClientMessageId ||
	   !common.messageEditContentLengthIsValid(len(req.content)) {
		MainRouterState_sendMessageRefusal(
			pm,
			state,
			peerID,
			common.MESSAGE_EDIT_INVALID_MESSAGE,
			req.messageId,
		)
		return
	}
	request := common.DatabaseMessageChangeRequest {
		action                  = .EditDirect,
		actorUserId             = senderID,
		peerUserId              = req.peerUserId,
		messageId               = req.messageId,
		originalClientMessageId = req.originalClientMessageId,
		clientMessageId         = req.clientMessageId,
		serverIdentityPublicKey = state.serverIdentityPublicKey,
		senderIdentityPublicKey = session.clientIdentityPublicKey,
	}
	if len(req.envelope) > 0 {
		envelope, decodeErr := common.decodeSealedEnvelope(req.envelope)
		if len(req.content) != 0 ||
		   req.signature != {} ||
		   len(req.envelope) > common.SEALED_ENVELOPE_MAX_BYTES ||
		   decodeErr != .None ||
		   envelope.kind != .DirectMessage ||
		   envelope.wrapCount != 2 {
			MainRouterState_sendMessageRefusal(
				pm,
				state,
				peerID,
				common.SEALED_DIRECT_MESSAGE_INVALID_MESSAGE,
				req.messageId,
			)
			return
		}
		request.content = strings.clone("")
		request.sealed = req.envelope
		req.envelope = nil
	} else {
		if !common.verifyDirectMessageEdit(
			common.MessageChangeFields {
				serverIdentityPublicKey = state.serverIdentityPublicKey,
				conversationID = req.peerUserId,
				senderUserID = senderID,
				original = req.originalClientMessageId,
				edit = req.clientMessageId,
			},
			req.content,
			session.clientIdentityPublicKey,
			req.signature,
		) {
			MainRouterState_sendMessageRefusal(
				pm,
				state,
				peerID,
				common.MESSAGE_EDIT_SIGNATURE_INVALID_MESSAGE,
				req.messageId,
			)
			return
		}
		request.content = strings.clone(req.content)
		request.signature = req.signature
	}
	MainRouterState_sendMessageChange(pm, state, peerID, session, request)
}

MainRouterState_handleClientDeleteDirectMessage :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	payload: []u8,
) {
	req: common.ClientDeleteDirectMessagePayload
	if cbor.unmarshal(payload, &req, temp_allocator = context.allocator) != nil {
		MainRouterState_sendProtocolError(pm, state, peerID, common.MESSAGE_DELETE_INVALID_MESSAGE)
		return
	}
	session, ok := MainRouterState_getPeerSession(state, peerID)
	if !ok || !session.isAuthenticated {
		MainRouterState_sendProtocolError(pm, state, peerID, "Unauthenticated message delete")
		return
	}
	senderID := session.authenticatedUserID
	if req.peerUserId <= 0 || req.peerUserId == senderID || req.messageId <= 0 {
		MainRouterState_sendMessageRefusal(
			pm,
			state,
			peerID,
			common.MESSAGE_DELETE_INVALID_MESSAGE,
			req.messageId,
		)
		return
	}
	// D5: only the author deletes a direct message, always signed.
	if !common.verifyDirectMessageDelete(
		common.MessageChangeFields {
			serverIdentityPublicKey = state.serverIdentityPublicKey,
			conversationID = req.peerUserId,
			senderUserID = senderID,
			original = req.originalClientMessageId,
		},
		session.clientIdentityPublicKey,
		req.signature,
	) {
		MainRouterState_sendMessageRefusal(
			pm,
			state,
			peerID,
			common.MESSAGE_DELETE_SIGNATURE_INVALID_MESSAGE,
			req.messageId,
		)
		return
	}
	MainRouterState_sendMessageChange(
		pm,
		state,
		peerID,
		session,
		common.DatabaseMessageChangeRequest {
			action = .DeleteDirect,
			actorUserId = senderID,
			peerUserId = req.peerUserId,
			messageId = req.messageId,
			originalClientMessageId = req.originalClientMessageId,
			signature = req.signature,
		},
	)
}

MainRouterState_handleClientFetchMessageEdits :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	payload: []u8,
) {
	req: common.ClientFetchMessageEditsPayload
	if cbor.unmarshal(payload, &req) != nil ||
	   (req.kind != .Room && req.kind != .Direct) ||
	   req.conversationId <= 0 ||
	   req.messageId <= 0 {
		MainRouterState_sendProtocolError(pm, state, peerID, "Invalid message edits request")
		return
	}
	session, ok := MainRouterState_getPeerSession(state, peerID)
	if !ok || !session.isAuthenticated {
		MainRouterState_sendProtocolError(
			pm,
			state,
			peerID,
			"Unauthenticated message edits request",
		)
		return
	}
	request := common.DatabaseMessageChangeRequest {
		actorUserId = session.authenticatedUserID,
		messageId   = req.messageId,
	}
	if req.kind == .Room {
		request.action = .FetchRoomEdits
		request.roomId = req.conversationId
	} else {
		if req.conversationId == session.authenticatedUserID {
			MainRouterState_sendProtocolError(pm, state, peerID, "Invalid message edits request")
			return
		}
		request.action = .FetchDirectEdits
		request.peerUserId = req.conversationId
	}
	MainRouterState_sendMessageChange(pm, state, peerID, session, request)
}

// Queues request as a .MessageChange database request for the session that sent it.
@(private = "file")
MainRouterState_sendMessageChange :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	session: RouterPeerSession,
	request: common.DatabaseMessageChangeRequest,
) {
	MainRouterState_enqueueChannelDatabaseRequest(
		pm,
		state,
		peerID,
		request,
		PendingDBRequest {
			requestType = .MessageChange,
			sessionID = session.transport.sessionID,
			targetUserID = session.authenticatedUserID,
			roomID = request.roomId,
			messageChangeAction = request.action,
			messageID = request.messageId,
			messageChangePeerID = request.peerUserId,
			messageChangeAdmin = request.adminDelete,
		},
	)
}

// Sends ServerProtocolError base, naming messageID (protocol 30: every refusal of an edit or a
// delete names its message).
MainRouterState_sendMessageRefusal :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	base: string,
	messageID: int,
) {
	text := common.messageRefusal(base, messageID)
	defer delete(text)
	MainRouterState_sendProtocolError(pm, state, peerID, text)
}

// The refusal sentence for an outcome that is not Applied.
MainRouterState_messageChangeRefusal :: proc(
	outcome: common.MessageChangeOutcome,
	action: common.DatabaseMessageChangeAction,
) -> string {
	switch outcome {
	case .Applied:
		return ""
	case .NotMember:
		return "Not a room member"
	case .NotFound:
		return common.MESSAGE_NOT_FOUND_MESSAGE
	case .NotAuthor:
		return common.MESSAGE_NOT_AUTHOR_MESSAGE
	case .NotAdmin:
		return "Admin permission required"
	case .Deleted:
		return common.MESSAGE_ALREADY_DELETED_MESSAGE
	case .ChatDisabled:
		return CHAT_DISABLED_MESSAGE
	case .SendDenied:
		return common.ROOM_SEND_NOT_PERMITTED_MESSAGE
	case .Restricted:
		return common.DIRECT_MESSAGE_RESTRICTED_MESSAGE
	case .KindMismatch:
		return common.MESSAGE_EDIT_KIND_MESSAGE
	case .StaleEpoch:
		return common.ROOM_KEY_OUT_OF_DATE_MESSAGE
	case .InvalidEnvelope:
		return common.SEALED_DIRECT_MESSAGE_INVALID_MESSAGE
	case .InvalidContent:
		return common.MESSAGE_EDIT_INVALID_MESSAGE
	case .EditLimit:
		return common.MESSAGE_EDITS_LIMIT_MESSAGE
	case .Duplicate:
		return common.MESSAGE_EDIT_DUPLICATE_MESSAGE
	}
	return common.MESSAGE_NOT_FOUND_MESSAGE
}

MainRouterState_handleMessageChangeResult :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	request: PendingDBRequest,
	response: common.DatabaseQueryResponse,
) {
	_, live := attachmentSession(state, request.peerID, request.sessionID)
	changed, changedOK := response.result.(common.DatabaseMessageChangeResult)
	if !response.success || !changedOK {
		if live {
			MainRouterState_databaseFailed(pm, state, request.peerID, response, changedOK)
		}
		return
	}
	if changed.outcome != .Applied {
		if live {
			MainRouterState_sendMessageRefusal(
				pm,
				state,
				request.peerID,
				MainRouterState_messageChangeRefusal(changed.outcome, request.messageChangeAction),
				request.messageID,
			)
		}
		return
	}
	switch request.messageChangeAction {
	case .EditRoom:
		notice := common.ServerRoomMessageEditedPayload {
			roomId    = request.roomID,
			messageId = request.messageID,
			senderId  = changed.senderId,
			editCount = changed.editCount,
			edit      = changed.edit,
		}
		MainRouterState_sendToMessageReaders(
			pm,
			state,
			changed.readerUserIds[:],
			request,
			live,
			.ServerRoomMessageEdited,
			notice,
		)
	case .EditDirect:
		notice := common.ServerDirectMessageEditedPayload {
			senderId    = changed.senderId,
			recipientId = changed.recipientId,
			messageId   = request.messageID,
			editCount   = changed.editCount,
			edit        = changed.edit,
		}
		MainRouterState_sendToMessageReaders(
			pm,
			state,
			changed.readerUserIds[:],
			request,
			live,
			.ServerDirectMessageEdited,
			notice,
		)
	case .DeleteRoom:
		if request.messageChangeAdmin {
			fmt.printfln(
				"[Admin] Message %d of user %d in room %d deleted by user %d (%d files)",
				request.messageID,
				changed.senderId,
				request.roomID,
				request.targetUserID,
				len(changed.removedBlobs),
			)
		}
		MainRouterState_messageDeleteRemoveFiles(
			pm,
			state,
			changed,
			common.ServerAttachmentRemovedPayload {
				roomId = request.roomID,
				senderId = changed.senderId,
				chatMessageId = request.messageID,
			},
		)
		notice := common.ServerRoomMessageDeletedPayload {
			roomId    = request.roomID,
			messageId = request.messageID,
			senderId  = changed.senderId,
			deletion  = changed.deletion,
		}
		MainRouterState_sendToMessageReaders(
			pm,
			state,
			changed.readerUserIds[:],
			request,
			live,
			.ServerRoomMessageDeleted,
			notice,
		)
	case .DeleteDirect:
		MainRouterState_messageDeleteRemoveFiles(
			pm,
			state,
			changed,
			common.ServerAttachmentRemovedPayload {
				senderId = changed.senderId,
				recipientId = changed.recipientId,
				directMessageId = request.messageID,
			},
		)
		notice := common.ServerDirectMessageDeletedPayload {
			senderId    = changed.senderId,
			recipientId = changed.recipientId,
			messageId   = request.messageID,
			deletion    = changed.deletion,
		}
		MainRouterState_sendToMessageReaders(
			pm,
			state,
			changed.readerUserIds[:],
			request,
			live,
			.ServerDirectMessageDeleted,
			notice,
		)
	case .FetchRoomEdits, .FetchDirectEdits:
		if !live {
			return
		}
		kind := common.MessageEditsKind.Room
		conversationID := request.roomID
		if request.messageChangeAction == .FetchDirectEdits {
			kind = .Direct
			conversationID = request.messageChangePeerID
		}
		MainRouterState_sendPeerMessage(
			pm,
			state,
			request.peerID,
			.ServerMessageEdits,
			common.ServerMessageEditsPayload {
				kind = kind,
				conversationId = conversationID,
				messageId = request.messageID,
				edits = changed.edits,
			},
		)
	}
}

// Sends payload to every session of each reader, and to the requesting session when its account
// is not one (an admin who deletes a message of a room it is not a member of).
@(private = "file")
MainRouterState_sendToMessageReaders :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	readerUserIDs: []int,
	request: PendingDBRequest,
	live: bool,
	messageType: common.MessageType,
	payload: any,
) {
	for userID in readerUserIDs {
		MainRouterState_sendMessageToUserID(pm, state, userID, messageType, payload)
	}
	if live && !MainRouterState_hasRecipientUserID(readerUserIDs, request.targetUserID) {
		MainRouterState_sendPeerMessage(pm, state, request.peerID, messageType, payload)
	}
}

// D8: a deleted message's files became Removed tombstones in the delete statement. Their
// downloads end (ATTACHMENT_REMOVED_MESSAGE), the storage worker deletes the files, and each
// reader hears ServerAttachmentRemoved for each (notice names the message), so clients give the
// quota back and abandon their downloads exactly as for an admin's removal.
@(private = "file")
MainRouterState_messageDeleteRemoveFiles :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	changed: common.DatabaseMessageChangeResult,
	notice: common.ServerAttachmentRemovedPayload,
) {
	if len(changed.removedBlobs) == 0 {
		return
	}
	blobs := make([dynamic]common.DatabaseAttachmentBlob, 0, len(changed.removedBlobs))
	for blobID in changed.removedBlobs {
		MainRouterState_attachmentCancelDownloads(
			pm,
			state,
			blobID,
			common.ATTACHMENT_REMOVED_MESSAGE,
		)
		append(&blobs, common.DatabaseAttachmentBlob{blobId = blobID, state = .Removed})
	}
	attachmentStorageSend(
		pm,
		state,
		StorageDeleteBlobs{blobs = blobs},
		AttachmentPendingStorage{kind = .DeleteBlobs},
	)
	for blobID in changed.removedBlobs {
		removed := notice
		removed.blobId = blobID
		for userID in changed.readerUserIds {
			MainRouterState_sendMessageToUserID(
				pm,
				state,
				userID,
				.ServerAttachmentRemoved,
				removed,
			)
		}
	}
}
