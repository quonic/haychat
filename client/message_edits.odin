package client

import "../common"
import "core:crypto"
import "core:encoding/cbor"
import "core:fmt"
import "core:strings"

// Editing and deleting messages (protocol 30, #76, docs/plan/2026-11-19-message-edit-delete.md).
//
// The server keeps every edit and tombstone; history pages and live messages carry the latest
// edit (StoredChatMessage.lastEdit / StoredDirectMessage.lastEdit) and the count (D14), and
// ServerRoomMessageEdited, ServerRoomMessageDeleted and their DM twins arrive live. The client
// never trusts them on their own:
//
// - an edit is shown only once its signature verified against the author's PINNED identity key
//   (this profile's own for itself; State_directIdentityFor), over this server, the
//   conversation, the author and the message's own client message ID, so the server can neither
//   forge one nor move it to another message. One that fails keeps the last good version on
//   screen and is marked (MessageEditStatus.Failed, "An edit could not be verified"); one whose
//   author is not pinned yet waits (Pending) and is checked again when keys change.
// - a sealed edit (#76 M2, an encrypted conversation) is opened like a new sealed message of
//   the same author: a room's on the author's chain (State_roomSealedEditOpen, room_chains.odin:
//   the verified log, the author's membership of the edit's epoch, the signature against the
//   pin before any key is looked for, then the chain key), a DM's envelope with this profile's
//   key against both pins (messageEditOpenDirect). Its plaintext must name the original
//   ("replaces" equal to the message's client message ID), carry no files, and be empty only
//   when the message has files (messageEditCheckOpened). One whose chain key or log has not
//   arrived waits (Pending) and is opened again when it does (State_roomChainsReopenPending).
//   Every failure is final for that edit and never retried (MessageEditView.checkedEditID).
// - a copy of an edit (the same client message ID as the version shown, an earlier edit in the
//   list, or the message itself; for a room also the same chain position) is a replay: Failed.
// - a tombstone always hides the content (D6). It reads "Message deleted" when its signature
//   verifies against the author's pin, and "Removed by the server" otherwise: an admin's
//   moderation, a missing signature or one that does not verify.
// - the cached edit list (ClientFetchMessageEdits, fetched once per session on demand) is
//   checked edit by edit the same way; a sealed edit's opened text replaces its (empty)
//   content in the list.
//
// Sending: State_editRoomMessage, State_deleteRoomMessage, State_editDirectMessage,
// State_deleteDirectMessage and State_fetchMessageEdits sign with this profile's identity key and
// go through messageChangeSendBridge (tests swap it under messageChangeSendBridgeTestMutex).
// Nothing changes locally until the server's notice arrives. A sealed room message's edit goes
// through the room's sender chain queue (State_roomChainsSendEdit: the next index of the
// current chain, distributed like a new message's), a sealed DM's as an envelope to the pinned
// keys (State_directSendEdit); deletes are signed everywhere, encrypted conversations included.

MESSAGE_DELETED_TEXT :: "Message deleted"
MESSAGE_REMOVED_BY_SERVER_TEXT :: "Removed by the server"
MESSAGE_EDITED_SUFFIX :: " (edited)"
MESSAGE_EDIT_PENDING_SUFFIX :: " (edited, not verified yet)"
MESSAGE_EDIT_FAILED_SUFFIX :: " (An edit could not be verified)"
MESSAGE_EDIT_NOT_OPENED_MESSAGE :: "That message could not be opened, so it cannot be edited"
MESSAGE_EDIT_NOT_OWN_MESSAGE :: "You can only edit your own messages"
MESSAGE_DELETE_NOT_OWN_MESSAGE :: "You can only delete your own messages"
MESSAGE_DELETE_ADMIN_ONLY_MESSAGE :: "Only admins can delete other people's messages"
MESSAGE_NOT_LOADED_MESSAGE :: "That message is not loaded"
MESSAGE_ALREADY_DELETED_TEXT :: "That message was deleted"

// What the client concluded about a message's latest edit.
MessageEditStatus :: enum u8 {
	None, // Never edited, or not looked at yet
	Verified, // shownContent is the latest edit, signed by the author
	// Waiting for the author's pin, or (a sealed edit) the room's log or the chain's key
	Pending,
	Failed, // The latest edit did not verify; shownContent is the last good version
}

// Why an edit Failed (MessageEditView.failure; None otherwise).
MessageEditFailure :: enum u8 {
	None,
	Signature, // Not signed by the author over this message (or unsigned)
	NoKey, // No identity key to check it with, and none can arrive
	Kind, // A plaintext edit of a sealed message or a sealed edit of a plaintext one (D11)
	Sealed, // The sealed edit did not decode, verify or open (sealedError)
	NotEdit, // A sealed plaintext without "replaces"
	Moved, // "replaces" names another message
	Attachments, // The edit carries files (D9)
	Empty, // Empty text, but the message has no files
	Replayed, // A copy of an earlier edit, or of a message
	NotMember, // Room: the author was not a member of the edit's epoch
	BadIndex, // Room: the index is outside the chain
	LogFailed, // Room: the member log failed verification
}

MessageDeleteStatus :: enum u8 {
	None,
	Author, // Signed by the author (verified against the pin): "Message deleted"
	Server, // No valid author signature (D6): "Removed by the server"
}

// The client's view of a message's edits and tombstone, kept on RoomMessageEntry and
// DirectMessageEntry next to the server's fields (editCount, lastEdit, deleted, deletion).
// shownContent and shownAt are owned; shownContent is wiped before it is freed. edits is the
// cached list (ClientFetchMessageEdits, oldest first) with editStatuses its verdicts.
//
// #76 M2: failure (and for a sealed edit sealedError) says why the latest edit Failed;
// checkedEditID is the edit status and failure are about, so a failure is never checked again;
// shownEditClientID is the shown edit's client message ID (a copy under another ID is a
// replay).
MessageEditView :: struct {
	shownContent:      string,
	shownAt:           string,
	shownEditID:       int,
	shownEditClientID: common.ClientMessageID,
	status:            MessageEditStatus,
	failure:           MessageEditFailure,
	sealedError:       common.E2EEError,
	checkedEditID:     int,
	deleteStatus:      MessageDeleteStatus,
	// D13: this message was counted unread live, so its delete may take the count back.
	countedUnread:     bool,
	edits:             [dynamic]common.MessageEdit,
	editStatuses:      [dynamic]MessageEditStatus,
	editsLoaded:       bool,
	editsLoading:      bool,
}

MessageEditView_clearEdits :: proc(view: ^MessageEditView) {
	for &edit in view.edits {
		wipeString(edit.content)
		common.MessageEdit_deinit(&edit)
	}
	delete(view.edits)
	view.edits = nil
	delete(view.editStatuses)
	view.editStatuses = nil
	view.editsLoaded = false
	view.editsLoading = false
}

MessageEditView_deinit :: proc(view: ^MessageEditView) {
	wipeString(view.shownContent)
	delete(view.shownContent)
	delete(view.shownAt)
	MessageEditView_clearEdits(view)
	view^ = {}
}

// The text a transcript shows for a message's content, with its edit marker (allocator for the
// marked text; the original is borrowed when there is no edit).
messageEditShownText :: proc(
	content: string,
	view: MessageEditView,
	editCount: int,
	allocator := context.temp_allocator,
) -> string {
	shown := content
	if len(view.shownContent) > 0 || view.shownEditID > 0 {
		shown = view.shownContent
	}
	switch view.status {
	case .Verified:
		return fmt.aprintf("%s%s", shown, MESSAGE_EDITED_SUFFIX, allocator = allocator)
	case .Pending:
		return fmt.aprintf("%s%s", shown, MESSAGE_EDIT_PENDING_SUFFIX, allocator = allocator)
	case .Failed:
		return fmt.aprintf("%s%s", shown, MESSAGE_EDIT_FAILED_SUFFIX, allocator = allocator)
	case .None:
	}
	if editCount > 0 && view.shownEditID > 0 {
		return fmt.aprintf("%s%s", shown, MESSAGE_EDITED_SUFFIX, allocator = allocator)
	}
	return shown
}

// The tombstone's text (D6).
messageDeletedText :: proc(view: MessageEditView) -> string {
	if view.deleteStatus == .Author {
		return MESSAGE_DELETED_TEXT
	}
	return MESSAGE_REMOVED_BY_SERVER_TEXT
}

// ── Verification (pure) ──────────────────────────────────────────

// What an edit or delete of one message is checked against.
MessageChangeCheck :: struct {
	kind:                    common.MessageEditsKind,
	serverIdentityPublicKey: common.IdentityPublicKeyBytes,
	conversationID:          int, // The room, or the direct message's recipient
	senderUserID:            int,
	original:                common.ClientMessageID,
	// The author's pinned identity key (own key for this profile), nil without one.
	senderIdentity:          Maybe(common.IdentityPublicKeyBytes),
	// A pin may still arrive (the bundle is being fetched).
	identityMayArrive:       bool,
	// The message itself is sealed: its edits must be sealed too (D11).
	sealed:                  bool,
	// #76 M2: the message has files, so an edit's text may be empty (D9).
	hasAttachments:          bool,
	// A sealed DM edit: the recipient's pinned identity key (own key when this profile is the
	// recipient), nil without one, and whether one may still arrive.
	recipientIdentity:       Maybe(common.IdentityPublicKeyBytes),
	recipientMayArrive:      bool,
	// A sealed room edit: the message's own chain position, which no edit may repeat.
	originalHeader:          common.RoomMessageHeader,
}

// One edit's verdict and, once Verified, its text (owned: MessageEditVerdict_wipe frees it).
MessageEditVerdict :: struct {
	status:      MessageEditStatus,
	failure:     MessageEditFailure,
	sealedError: common.E2EEError,
	content:     string,
	// A sealed room edit, once decoded: its chain position.
	header:      common.RoomMessageHeader,
}

MessageEditVerdict_wipe :: proc(verdict: ^MessageEditVerdict) {
	wipeString(verdict.content)
	delete(verdict.content)
	verdict.content = ""
}

@(private = "file")
messageEditFailed :: proc(
	failure: MessageEditFailure,
	sealedError := common.E2EEError.None,
) -> MessageEditVerdict {
	return {status = .Failed, failure = failure, sealedError = sealedError}
}

// One plaintext edit's verdict (pure). A sealed edit is Pending here: opening it needs the
// conversation's keys (State_messageEditVerdict). A plaintext edit of a sealed message (D11),
// one with the message's own ID, and an empty one of a message without files fail.
messageEditCheck :: proc(check: MessageChangeCheck, edit: common.MessageEdit) -> MessageEditStatus {
	return messageEditCheckPlain(check, edit).status
}

@(private = "file")
messageEditCheckPlain :: proc(
	check: MessageChangeCheck,
	edit: common.MessageEdit,
) -> MessageEditVerdict {
	if len(edit.sealed) > 0 {
		if !check.sealed {
			return messageEditFailed(.Kind)
		}
		return {status = .Pending}
	}
	if check.sealed {
		return messageEditFailed(.Kind)
	}
	if edit.signature == {} {
		return messageEditFailed(.Signature)
	}
	if edit.clientMessageId == check.original {
		return messageEditFailed(.Replayed)
	}
	if len(edit.content) == 0 && !check.hasAttachments {
		return messageEditFailed(.Empty)
	}
	identity, hasIdentity := check.senderIdentity.?
	if !hasIdentity {
		if check.identityMayArrive {
			return {status = .Pending}
		}
		return messageEditFailed(.NoKey)
	}
	fields := common.MessageChangeFields {
		serverIdentityPublicKey = check.serverIdentityPublicKey,
		conversationID          = check.conversationID,
		senderUserID            = check.senderUserID,
		original                = check.original,
		edit                    = edit.clientMessageId,
	}
	verified := false
	if check.kind == .Room {
		verified = common.verifyRoomMessageEdit(fields, edit.content, identity, edit.signature)
	} else {
		verified = common.verifyDirectMessageEdit(fields, edit.content, identity, edit.signature)
	}
	if !verified {
		return messageEditFailed(.Signature)
	}
	return {status = .Verified, content = strings.clone(edit.content)}
}

// The checks an opened sealed edit's plaintext must pass (pure): it names the original, has no
// files, is empty only when the message has files, and is not under the message's own ID.
// Takes the plaintext's content into the verdict when it passes; the caller frees opened.
messageEditCheckOpened :: proc(
	check: MessageChangeCheck,
	edit: common.MessageEdit,
	opened: ^common.SealedDirectMessagePlaintext,
) -> MessageEditVerdict {
	switch {
	case !opened.hasReplaces:
		return messageEditFailed(.NotEdit)
	case opened.replaces != check.original:
		return messageEditFailed(.Moved)
	case len(opened.attachments) > 0:
		return messageEditFailed(.Attachments)
	case len(opened.content) == 0 && !check.hasAttachments:
		return messageEditFailed(.Empty)
	case edit.clientMessageId == check.original:
		return messageEditFailed(.Replayed)
	}
	verdict := MessageEditVerdict {
		status  = .Verified,
		content = opened.content,
	}
	opened.content = ""
	return verdict
}

// Opens a sealed DM edit (pure): the envelope bound to the edit's client message ID and both
// pinned identity keys, signed by the author, opened with this profile's key pair. Pending
// while a pin may still arrive; every other failure is final.
messageEditOpenDirect :: proc(
	check: MessageChangeCheck,
	keys: DirectOpenKeys,
	edit: common.MessageEdit,
) -> MessageEditVerdict {
	sender, hasSender := check.senderIdentity.?
	recipient, hasRecipient := check.recipientIdentity.?
	if !keys.ready || !hasSender || !hasRecipient {
		if (!hasSender && !check.identityMayArrive) ||
		   (!hasRecipient && !check.recipientMayArrive) {
			return messageEditFailed(.NoKey)
		}
		return {status = .Pending}
	}
	aadFields := common.DirectMessageAADFields {
		serverIdentityPublicKey    = keys.serverIdentityPublicKey,
		senderUserID               = check.senderUserID,
		recipientUserID            = check.conversationID,
		senderIdentityPublicKey    = sender,
		recipientIdentityPublicKey = recipient,
		clientMessageID            = edit.clientMessageId,
	}
	if !keys.hasOwnKeyPair {
		return messageEditFailed(.Sealed, .NoWrapForRecipient)
	}
	opened, err := common.openDirectMessage(
		edit.sealed,
		aadFields,
		keys.ownUserID,
		keys.ownKeyPair,
	)
	defer {
		wipeString(opened.content)
		common.SealedDirectMessagePlaintext_deinit(&opened)
	}
	if err != .None {
		return messageEditFailed(.Sealed, err)
	}
	return messageEditCheckOpened(check, edit, &opened)
}

// One edit's verdict with the keys it needs: a plaintext edit checked against the pin, a
// sealed DM edit opened with this profile's key, a sealed room edit opened on its chain.
State_messageEditVerdict :: proc(
	state: ^State,
	serverID: int,
	check: MessageChangeCheck,
	edit: common.MessageEdit,
) -> MessageEditVerdict {
	if len(edit.sealed) == 0 || !check.sealed {
		return messageEditCheckPlain(check, edit)
	}
	if check.kind == .Room {
		return State_roomSealedEditOpen(state, serverID, check, edit)
	}
	keys := State_directOpenKeys(state, serverID)
	defer DirectOpenKeys_wipe(&keys)
	return messageEditOpenDirect(check, keys, edit)
}

// Whether edit repeats one of earlier (the same client message ID, or for a sealed room edit
// the same chain position as one of their headers).
@(private = "file")
messageEditRepeats :: proc(
	edit: common.MessageEdit,
	header: common.RoomMessageHeader,
	earlier: []common.MessageEdit,
	earlierHeaders: []common.RoomMessageHeader,
) -> bool {
	for other, index in earlier {
		if other.clientMessageId == edit.clientMessageId {
			return true
		}
		if index < len(earlierHeaders) &&
		   header.chainID != {} &&
		   earlierHeaders[index] == header {
			return true
		}
	}
	return false
}

// Applies the server's latest edit to view: a verified one replaces what is shown, a failed one
// keeps the last good version, a pending one waits. A failure is final: the same edit is never
// checked again.
State_messageEditViewApply :: proc(
	state: ^State,
	serverID: int,
	view: ^MessageEditView,
	check: MessageChangeCheck,
	lastEdit: common.MessageEdit,
) {
	if !common.messageEditIsSet(lastEdit) {
		return
	}
	if lastEdit.id == view.checkedEditID && view.status != .Pending {
		return
	}
	verdict := State_messageEditVerdict(state, serverID, check, lastEdit)
	defer MessageEditVerdict_wipe(&verdict)
	messageEditViewTake(view, check, lastEdit, &verdict)
}

// messageEditViewApply with a verdict already reached (pure but for allocation): records it,
// marks a copy of the shown edit or of the message's position a replay, and shows a verified
// edit. Takes verdict.content.
messageEditViewTake :: proc(
	view: ^MessageEditView,
	check: MessageChangeCheck,
	lastEdit: common.MessageEdit,
	verdict: ^MessageEditVerdict,
) {
	if verdict.status == .Verified {
		replayed :=
			(view.shownEditID > 0 &&
				lastEdit.id != view.shownEditID &&
				lastEdit.clientMessageId == view.shownEditClientID) ||
			(verdict.header.chainID != {} && verdict.header == check.originalHeader)
		if replayed {
			MessageEditVerdict_wipe(verdict)
			verdict^ = messageEditFailed(.Replayed)
		}
	}
	view.status = verdict.status
	view.failure = verdict.failure
	view.sealedError = verdict.sealedError
	view.checkedEditID = lastEdit.id
	if verdict.status != .Verified {
		return
	}
	wipeString(view.shownContent)
	delete(view.shownContent)
	delete(view.shownAt)
	view.shownContent = verdict.content
	verdict.content = ""
	view.shownAt = strings.clone(lastEdit.timestamp)
	view.shownEditID = lastEdit.id
	view.shownEditClientID = lastEdit.clientMessageId
}

// Checks every edit of a loaded list that has no final verdict yet (None or Pending), oldest
// first: a sealed one's opened text replaces its content in the list, and a copy of an earlier
// edit (or of the message's own position) fails as a replay.
State_messageEditListCheck :: proc(
	state: ^State,
	serverID: int,
	view: ^MessageEditView,
	check: MessageChangeCheck,
) {
	if !view.editsLoaded && len(view.edits) == 0 {
		return
	}
	headers := make([]common.RoomMessageHeader, len(view.edits), context.temp_allocator)
	for &edit, index in view.edits {
		if len(edit.sealed) > 0 && check.kind == .Room {
			if decoded, err := common.decodeSealedRoomMessage(edit.sealed); err == .None {
				headers[index] = decoded.header
			}
		}
		status := view.editStatuses[index]
		if status == .Verified || status == .Failed {
			continue
		}
		verdict := State_messageEditVerdict(state, serverID, check, edit)
		defer MessageEditVerdict_wipe(&verdict)
		if verdict.status == .Verified &&
		   (messageEditRepeats(edit, headers[index], view.edits[:index], headers[:index]) ||
				   (headers[index].chainID != {} && headers[index] == check.originalHeader)) {
			MessageEditVerdict_wipe(&verdict)
			verdict = messageEditFailed(.Replayed)
		}
		view.editStatuses[index] = verdict.status
		if verdict.status == .Verified && len(edit.sealed) > 0 {
			wipeString(edit.content)
			delete(edit.content)
			edit.content = verdict.content
			verdict.content = ""
		}
	}
}

// Whether a view still has an edit waiting (the latest or one of the list).
messageEditViewHasPending :: proc(view: MessageEditView) -> bool {
	if view.status == .Pending {
		return true
	}
	for status in view.editStatuses {
		if status == .Pending || status == .None {
			return true
		}
	}
	return false
}

// A tombstone's verdict (D6): Author only for a signature that verifies against the pin.
messageDeleteCheck :: proc(
	check: MessageChangeCheck,
	deletion: common.MessageDeletion,
) -> MessageDeleteStatus {
	identity, hasIdentity := check.senderIdentity.?
	if deletion.signature == {} || !hasIdentity {
		return .Server
	}
	fields := common.MessageChangeFields {
		serverIdentityPublicKey = check.serverIdentityPublicKey,
		conversationID          = check.conversationID,
		senderUserID            = check.senderUserID,
		original                = check.original,
	}
	verified := false
	if check.kind == .Room {
		verified = common.verifyRoomMessageDelete(fields, identity, deletion.signature)
	} else {
		verified = common.verifyDirectMessageDelete(fields, identity, deletion.signature)
	}
	return verified ? .Author : .Server
}

// ── State: checking cached entries ───────────────────────────────

// The identity a room member's edits and deletes are checked against: this profile's own, the
// pin, or (an encrypted room) the key the verified member log names.
@(private = "file")
State_messageSenderIdentity :: proc(
	state: ^State,
	serverID, roomID, senderID: int,
	keys: DirectOpenKeys,
) -> Maybe(common.IdentityPublicKeyBytes) {
	if identity, ok := State_directIdentityFor(state, serverID, keys, senderID).?; ok {
		return identity
	}
	if roomID > 0 {
		if verified := State_roomLogVerified(state, serverID, roomID); verified != nil {
			if identity, ok := verified.identities[senderID]; ok {
				return identity
			}
		}
	}
	return nil
}

@(private = "file")
State_roomMessageCheck :: proc(
	state: ^State,
	serverID, roomID: int,
	entry: RoomMessageEntry,
) -> MessageChangeCheck {
	keys := State_directOpenKeys(state, serverID)
	defer DirectOpenKeys_wipe(&keys)
	return MessageChangeCheck {
		kind = .Room,
		serverIdentityPublicKey = keys.serverIdentityPublicKey,
		conversationID = roomID,
		senderUserID = entry.senderId,
		original = entry.clientMessageId,
		senderIdentity = State_messageSenderIdentity(state, serverID, roomID, entry.senderId, keys),
		identityMayArrive = State_directKeyMayArrive(state, serverID, entry.senderId),
		sealed = len(entry.sealed) > 0 || State_roomIsEncrypted(state, serverID, roomID),
		hasAttachments = len(entry.attachments) > 0,
		originalHeader = entry.security.header,
	}
}

@(private = "file")
State_directMessageCheck :: proc(
	state: ^State,
	serverID: int,
	entry: DirectMessageEntry,
) -> MessageChangeCheck {
	keys := State_directOpenKeys(state, serverID)
	defer DirectOpenKeys_wipe(&keys)
	return MessageChangeCheck {
		kind = .Direct,
		serverIdentityPublicKey = keys.serverIdentityPublicKey,
		conversationID = entry.recipientId,
		senderUserID = entry.senderId,
		original = entry.clientMessageId,
		senderIdentity = State_directIdentityFor(state, serverID, keys, entry.senderId),
		identityMayArrive = State_directKeyMayArrive(state, serverID, entry.senderId),
		sealed = len(entry.envelope) > 0,
		hasAttachments = len(entry.attachments) > 0,
		recipientIdentity = State_directIdentityFor(state, serverID, keys, entry.recipientId),
		recipientMayArrive = State_directKeyMayArrive(state, serverID, entry.recipientId),
	}
}

// Erases a deleted room message's content in place (D7): text, sealed bytes, signature, files
// and edits. The ID, sender, time and client message ID stay.
roomEntryTombstone :: proc(entry: ^RoomMessageEntry) {
	wipeString(entry.content)
	delete(entry.content)
	entry.content = ""
	if len(entry.sealed) > 0 {
		delete(entry.sealed)
		entry.sealed = nil
	}
	entry.signature = {}
	common.AttachmentRefs_deinit(&entry.attachments)
	MessageFiles_deinit(&entry.files)
	entry.filesChanged = false
	common.MessageEdit_deinit(&entry.lastEdit)
	entry.editCount = 0
	counted := entry.edit.countedUnread
	deleteStatus := entry.edit.deleteStatus
	MessageEditView_deinit(&entry.edit)
	entry.edit.countedUnread = counted
	entry.edit.deleteStatus = deleteStatus
}

directEntryTombstone :: proc(entry: ^DirectMessageEntry) {
	wipeString(entry.content)
	delete(entry.content)
	entry.content = ""
	if len(entry.envelope) > 0 {
		delete(entry.envelope)
		entry.envelope = nil
	}
	entry.signature = {}
	common.AttachmentRefs_deinit(&entry.attachments)
	MessageFiles_deinit(&entry.files)
	entry.filesChanged = false
	common.MessageEdit_deinit(&entry.lastEdit)
	entry.editCount = 0
	counted := entry.edit.countedUnread
	deleteStatus := entry.edit.deleteStatus
	MessageEditView_deinit(&entry.edit)
	entry.edit.countedUnread = counted
	entry.edit.deleteStatus = deleteStatus
}

// Settles a cached room message's tombstone, or its latest edit once the message itself is
// shown. Called after every open (State_roomOpenEntry) and when keys change.
State_roomEntrySettleEdits :: proc(state: ^State, serverID, roomID: int, entry: ^RoomMessageEntry) {
	if entry.deleted {
		check := State_roomMessageCheck(state, serverID, roomID, entry^)
		roomEntryTombstone(entry)
		entry.edit.deleteStatus = messageDeleteCheck(check, entry.deletion)
		return
	}
	#partial switch entry.security.protection {
	case .Plain, .Encrypted:
	case:
		return
	}
	check := State_roomMessageCheck(state, serverID, roomID, entry^)
	if common.messageEditIsSet(entry.lastEdit) {
		State_messageEditViewApply(state, serverID, &entry.edit, check, entry.lastEdit)
	}
	State_messageEditListCheck(state, serverID, &entry.edit, check)
}

State_directEntrySettleEdits :: proc(state: ^State, serverID: int, entry: ^DirectMessageEntry) {
	if entry.deleted {
		check := State_directMessageCheck(state, serverID, entry^)
		directEntryTombstone(entry)
		entry.edit.deleteStatus = messageDeleteCheck(check, entry.deletion)
		return
	}
	#partial switch entry.security.protection {
	case .Signed, .Encrypted:
	case:
		return
	}
	check := State_directMessageCheck(state, serverID, entry^)
	if common.messageEditIsSet(entry.lastEdit) {
		State_messageEditViewApply(state, serverID, &entry.edit, check, entry.lastEdit)
	}
	State_messageEditListCheck(state, serverID, &entry.edit, check)
}

// Whether an entry's verdicts may change when keys arrive: an edit waiting for the author's
// pin (or a sealed one for its keys), or a signed tombstone read as the server's for want of
// one.
@(private = "file")
messageEditViewWaits :: proc(view: MessageEditView, deleted: bool, signed: bool) -> bool {
	if deleted {
		return signed && view.deleteStatus == .Server
	}
	return messageEditViewHasPending(view)
}

// Keys changed on serverID: checks again every edit and signed tombstone that waited for one.
State_messageEditsKeysChanged :: proc(state: ^State, serverID: int) {
	if cacheIndex := State_serverRoomCacheIndex(state^, serverID); cacheIndex >= 0 {
		for &roomCache in state.server_room_caches[cacheIndex].roomCaches {
			for &entry in roomCache.messages {
				if messageEditViewWaits(entry.edit, entry.deleted, entry.deletion.signature != {}) {
					if entry.deleted {
						entry.edit.deleteStatus = messageDeleteCheck(
							State_roomMessageCheck(state, serverID, roomCache.roomID, entry),
							entry.deletion,
						)
					} else {
						State_roomEntrySettleEdits(state, serverID, roomCache.roomID, &entry)
					}
				}
			}
		}
	}
	if index := State_serverDirectCacheIndex(state^, serverID); index >= 0 {
		for &conversation in state.serverDirectCaches[index].caches {
			for &entry in conversation.messages {
				if messageEditViewWaits(entry.edit, entry.deleted, entry.deletion.signature != {}) {
					if entry.deleted {
						entry.edit.deleteStatus = messageDeleteCheck(
							State_directMessageCheck(state, serverID, entry),
							entry.deletion,
						)
					} else {
						State_directEntrySettleEdits(state, serverID, &entry)
					}
				}
			}
		}
	}
}

// A history page brought a message already cached: the server is the source of truth for its
// latest edit, count and tombstone (an edit or delete this session missed).
State_roomEntryMergeServer :: proc(
	state: ^State,
	serverID, roomID: int,
	entry: ^RoomMessageEntry,
	message: common.StoredChatMessage,
) {
	if entry.deleted {
		return
	}
	if message.deleted {
		entry.deleted = true
		common.MessageDeletion_deinit(&entry.deletion)
		entry.deletion = common.MessageDeletion_clone(message.deletion)
		State_roomEntrySettleEdits(state, serverID, roomID, entry)
		return
	}
	if message.editCount > entry.editCount && common.messageEditIsSet(message.lastEdit) {
		common.MessageEdit_deinit(&entry.lastEdit)
		entry.lastEdit = common.MessageEdit_clone(message.lastEdit)
		entry.editCount = message.editCount
		State_roomEntrySettleEdits(state, serverID, roomID, entry)
	}
}

State_directEntryMergeServer :: proc(
	state: ^State,
	serverID: int,
	entry: ^DirectMessageEntry,
	message: common.StoredDirectMessage,
) {
	if entry.deleted {
		return
	}
	if message.deleted {
		entry.deleted = true
		common.MessageDeletion_deinit(&entry.deletion)
		entry.deletion = common.MessageDeletion_clone(message.deletion)
		State_directEntrySettleEdits(state, serverID, entry)
		return
	}
	if message.editCount > entry.editCount && common.messageEditIsSet(message.lastEdit) {
		common.MessageEdit_deinit(&entry.lastEdit)
		entry.lastEdit = common.MessageEdit_clone(message.lastEdit)
		entry.editCount = message.editCount
		State_directEntrySettleEdits(state, serverID, entry)
	}
}

// The cached room entry messageID, or nil.
State_roomMessageEntry :: proc(
	state: ^State,
	serverID, roomID, messageID: int,
) -> ^RoomMessageEntry {
	cacheIndex := State_serverRoomCacheIndex(state^, serverID)
	if cacheIndex < 0 {
		return nil
	}
	serverCache := &state.server_room_caches[cacheIndex]
	roomIndex := ServerRoomCache_roomCacheIndex(serverCache^, roomID)
	if roomIndex < 0 {
		return nil
	}
	for &entry in serverCache.roomCaches[roomIndex].messages {
		if entry.id == messageID {
			return &entry
		}
	}
	return nil
}

// The cached direct message messageID of the conversation with peerUserID, or nil.
State_directMessageEntry :: proc(
	state: ^State,
	serverID, peerUserID, messageID: int,
) -> ^DirectMessageEntry {
	index := State_serverDirectCacheIndex(state^, serverID)
	if index < 0 {
		return nil
	}
	cache := &state.serverDirectCaches[index]
	conversationIndex := ServerDirectCache_conversationCacheIndex(cache^, peerUserID)
	if conversationIndex < 0 {
		return nil
	}
	return DirectConversationCache_entry(&cache.caches[conversationIndex], messageID)
}

// ── State: live notices ──────────────────────────────────────────

// ServerRoomMessageEdited / ServerDirectMessageEdited: takes event.messageEdit. A message
// this session has not loaded is left to its next history page.
State_messageEdited :: proc(state: ^State, event: ^ClientTransportRuntimeEvent) {
	edit := event.messageEdit
	event.messageEdit = {}
	defer {
		wipeString(edit.content)
		common.MessageEdit_deinit(&edit)
	}
	if event.editKind == .Room {
		// #76 M2: a sealed edit this session sent leaves the chain's in-flight list.
		State_roomChainsMessageEchoed(
			state,
			event.serverID,
			event.roomID,
			event.senderID,
			edit.clientMessageId,
		)
		entry := State_roomMessageEntry(state, event.serverID, event.roomID, event.messageID)
		if entry == nil || entry.deleted || entry.senderId != event.senderID {
			return
		}
		State_messageEditRecord(
			&entry.message.lastEdit,
			&entry.message.editCount,
			&entry.edit,
			edit,
			event.editCount,
		)
		State_roomEntrySettleEdits(state, event.serverID, event.roomID, entry)
		// A sealed edit waiting for its chain or the log fetches or asks for it.
		State_roomChainsEditsFollowUp(state, event.serverID, event.roomID)
		return
	}
	peerUserID := directMessagePeerUserID(
		common.StoredDirectMessage{senderId = event.senderID, recipientId = event.peerUserID},
		State_selfUserID(state, event.serverID),
	)
	entry := State_directMessageEntry(state, event.serverID, peerUserID, event.messageID)
	if entry != nil && !entry.deleted && entry.senderId == event.senderID {
		State_messageEditRecord(
			&entry.message.lastEdit,
			&entry.message.editCount,
			&entry.edit,
			edit,
			event.editCount,
		)
		State_directEntrySettleEdits(state, event.serverID, entry)
	}
	State_directPreviewEdited(
		state,
		event.serverID,
		peerUserID,
		event.messageID,
		entry,
		edit,
		event.editCount,
	)
}

// Records a newer edit as the message's latest and in a loaded edit list.
@(private = "file")
State_messageEditRecord :: proc(
	lastEdit: ^common.MessageEdit,
	editCount: ^int,
	view: ^MessageEditView,
	edit: common.MessageEdit,
	count: int,
) {
	if edit.id <= lastEdit.id {
		return
	}
	common.MessageEdit_deinit(lastEdit)
	lastEdit^ = common.MessageEdit_clone(edit)
	editCount^ = max(count, editCount^ + 1)
	if view.editsLoaded {
		append(&view.edits, common.MessageEdit_clone(edit))
		append(&view.editStatuses, MessageEditStatus.None)
	}
}

// The conversation list's preview of the edited message, when it is the conversation's latest.
@(private = "file")
State_directPreviewEdited :: proc(
	state: ^State,
	serverID, peerUserID, messageID: int,
	entry: ^DirectMessageEntry,
	edit: common.MessageEdit,
	count: int,
) {
	cache := State_serverDirectCache(state, serverID)
	index := ServerDirectCache_conversationIndex(cache^, peerUserID)
	if index < 0 || cache.conversations[index].lastMessageID != messageID {
		return
	}
	summary := &cache.conversations[index]
	if summary.lastDeleted || edit.id <= summary.lastEdit.id {
		return
	}
	common.MessageEdit_deinit(&summary.lastEdit)
	summary.lastEdit = common.MessageEdit_clone(edit)
	summary.lastEditCount = count
	if entry != nil && entry.edit.status == .Verified && entry.edit.shownEditID == edit.id {
		wipeString(summary.lastContent)
		delete(summary.lastContent)
		summary.lastContent = strings.clone(entry.edit.shownContent)
		return
	}
	// #76 M2: a preview whose message is not loaded checks (or opens) the edit itself.
	if entry == nil {
		keys := State_directOpenKeys(state, serverID)
		defer DirectOpenKeys_wipe(&keys)
		State_directPreviewSettleEdits(state, serverID, keys, summary)
	}
}

// ServerRoomMessageDeleted / ServerDirectMessageDeleted: takes event.messageDeletion. The
// cached message becomes a tombstone; one this client counted unread live is taken back out of
// the count (D13), the only time the client lowers a count itself.
State_messageDeleted :: proc(state: ^State, event: ^ClientTransportRuntimeEvent) {
	deletion := event.messageDeletion
	event.messageDeletion = {}
	defer common.MessageDeletion_deinit(&deletion)
	if event.editKind == .Room {
		entry := State_roomMessageEntry(state, event.serverID, event.roomID, event.messageID)
		if entry == nil || entry.deleted || entry.senderId != event.senderID {
			return
		}
		entry.deleted = true
		common.MessageDeletion_deinit(&entry.deletion)
		entry.deletion = common.MessageDeletion_clone(deletion)
		counted := entry.edit.countedUnread
		State_roomEntrySettleEdits(state, event.serverID, event.roomID, entry)
		if summary := State_roomSummary(state, event.serverID, event.roomID);
		   counted && summary != nil && summary.unreadCount > 0 &&
		   event.messageID > summary.lastReadMessageId {
			summary.unreadCount -= 1
		}
		return
	}
	peerUserID := directMessagePeerUserID(
		common.StoredDirectMessage{senderId = event.senderID, recipientId = event.peerUserID},
		State_selfUserID(state, event.serverID),
	)
	counted := false
	if entry := State_directMessageEntry(state, event.serverID, peerUserID, event.messageID);
	   entry != nil && !entry.deleted && entry.senderId == event.senderID {
		entry.deleted = true
		common.MessageDeletion_deinit(&entry.deletion)
		entry.deletion = common.MessageDeletion_clone(deletion)
		counted = entry.edit.countedUnread
		State_directEntrySettleEdits(state, event.serverID, entry)
	}
	cache := State_serverDirectCache(state, event.serverID)
	index := ServerDirectCache_conversationIndex(cache^, peerUserID)
	if index < 0 {
		return
	}
	summary := &cache.conversations[index]
	if counted && summary.unreadCount > 0 && event.messageID > summary.lastReadMessageId {
		summary.unreadCount -= 1
	}
	if summary.lastMessageID == event.messageID && !summary.lastDeleted {
		summary.lastDeleted = true
		common.MessageDeletion_deinit(&summary.lastDeletion)
		summary.lastDeletion = common.MessageDeletion_clone(deletion)
		directPreviewTombstone(summary)
	}
}

// Erases a conversation preview's content (its newest message was deleted).
directPreviewTombstone :: proc(summary: ^DirectConversationEntry) {
	wipeString(summary.lastContent)
	delete(summary.lastContent)
	summary.lastContent = ""
	delete(summary.lastEnvelope)
	summary.lastEnvelope = nil
	summary.lastSignature = {}
	common.AttachmentRefs_deinit(&summary.lastAttachments)
	common.MessageEdit_deinit(&summary.lastEdit)
	summary.lastEditCount = 0
	summary.security = {protection = .Signed}
}

// A conversation preview once its newest message opened: the tombstone, or its latest edit
// when that verifies (State_openDirectPreview).
State_directPreviewSettleEdits :: proc(
	state: ^State,
	serverID: int,
	keys: DirectOpenKeys,
	summary: ^DirectConversationEntry,
) {
	if summary.lastDeleted {
		directPreviewTombstone(summary)
		return
	}
	#partial switch summary.security.protection {
	case .Signed, .Encrypted:
	case:
		return
	}
	if !common.messageEditIsSet(summary.lastEdit) {
		return
	}
	recipientID := summary.peerUserId
	if summary.lastSenderId == summary.peerUserId {
		recipientID = keys.ownUserID
	}
	check := MessageChangeCheck {
		kind                    = .Direct,
		serverIdentityPublicKey = keys.serverIdentityPublicKey,
		conversationID          = recipientID,
		senderUserID            = summary.lastSenderId,
		original                = summary.lastClientMessageId,
		senderIdentity          = State_directIdentityFor(
			state,
			serverID,
			keys,
			summary.lastSenderId,
		),
		sealed                  = len(summary.lastEnvelope) > 0,
		hasAttachments          = len(summary.lastAttachments) > 0,
		recipientIdentity       = State_directIdentityFor(state, serverID, keys, recipientID),
	}
	// #76 M2: a sealed edit opens with this profile's key, like the preview's message.
	verdict: MessageEditVerdict
	if len(summary.lastEdit.sealed) > 0 && check.sealed {
		verdict = messageEditOpenDirect(check, keys, summary.lastEdit)
	} else {
		verdict = messageEditCheckPlain(check, summary.lastEdit)
	}
	defer MessageEditVerdict_wipe(&verdict)
	if verdict.status == .Verified {
		wipeString(summary.lastContent)
		delete(summary.lastContent)
		summary.lastContent = verdict.content
		verdict.content = ""
	}
}

// ServerMessageEdits: takes event.messageEdits as the message's cached list and checks each.
State_messageEditsReceived :: proc(state: ^State, event: ^ClientTransportRuntimeEvent) {
	edits := event.messageEdits
	event.messageEdits = nil
	view: ^MessageEditView
	check: MessageChangeCheck
	if event.editKind == .Room {
		if entry := State_roomMessageEntry(state, event.serverID, event.roomID, event.messageID);
		   entry != nil && !entry.deleted {
			view = &entry.edit
			check = State_roomMessageCheck(state, event.serverID, event.roomID, entry^)
		}
	} else {
		if entry := State_directMessageEntry(
			state,
			event.serverID,
			event.peerUserID,
			event.messageID,
		); entry != nil && !entry.deleted {
			view = &entry.edit
			check = State_directMessageCheck(state, event.serverID, entry^)
		}
	}
	if view == nil {
		for &edit in edits {
			wipeString(edit.content)
		}
		common.MessageEdits_deinit(&edits)
		return
	}
	MessageEditView_clearEdits(view)
	view.edits = edits
	view.editStatuses = make([dynamic]MessageEditStatus, len(edits))
	view.editsLoaded = true
	view.editsLoading = false
	State_messageEditListCheck(state, event.serverID, view, check)
	// #76 M2: sealed edits still waiting fetch or ask for their chains.
	if event.editKind == .Room {
		State_roomChainsEditsFollowUp(state, event.serverID, event.roomID)
	}
}

// ── State: sending ───────────────────────────────────────────────

// One edit, delete or edit fetch ready to go out, borrowed for the send.
MessageChangeSend :: struct {
	messageType:  common.MessageType,
	roomEdit:     common.ClientEditRoomMessagePayload,
	roomDelete:   common.ClientDeleteRoomMessagePayload,
	directEdit:   common.ClientEditDirectMessagePayload,
	directDelete: common.ClientDeleteDirectMessagePayload,
	fetch:        common.ClientFetchMessageEditsPayload,
}

MessageChangeSendBridge :: proc(transport: ^ClientServerTransport, send: MessageChangeSend) -> bool

// Tests swap this to observe sends without a live session.
messageChangeSendBridge: MessageChangeSendBridge = ClientServerTransport_sendMessageChange

ClientServerTransport_sendMessageChange :: proc(
	transport: ^ClientServerTransport,
	send: MessageChangeSend,
) -> bool {
	#partial switch send.messageType {
	case .ClientEditRoomMessage:
		return ClientServerTransport_sendEncryptedRuntimeMessage(
			transport,
			send.messageType,
			send.roomEdit,
		)
	case .ClientDeleteRoomMessage:
		return ClientServerTransport_sendEncryptedRuntimeMessage(
			transport,
			send.messageType,
			send.roomDelete,
		)
	case .ClientEditDirectMessage:
		return ClientServerTransport_sendEncryptedRuntimeMessage(
			transport,
			send.messageType,
			send.directEdit,
		)
	case .ClientDeleteDirectMessage:
		return ClientServerTransport_sendEncryptedRuntimeMessage(
			transport,
			send.messageType,
			send.directDelete,
		)
	case .ClientFetchMessageEdits:
		return ClientServerTransport_sendEncryptedRuntimeMessage(
			transport,
			send.messageType,
			send.fetch,
		)
	}
	return false
}

// Sends through the bridge under the worker lock. "" on success, else why (static or the
// transport's error, copied to the temp allocator).
@(private = "file")
State_sendMessageChange :: proc(state: ^State, serverID: int, send: MessageChangeSend) -> string {
	transportIndex := State_selectedTransportIndexForServerID(state^, serverID)
	if transportIndex < 0 || !State_isServerConnected(state, serverID) {
		return NOT_CONNECTED_MESSAGE
	}
	transport := &state.serverTransports[transportIndex]
	ClientNetworkWorker_lock(state.networkWorker)
	defer ClientNetworkWorker_unlock(state.networkWorker)
	if messageChangeSendBridge(transport, send) {
		return ""
	}
	if len(transport.lastError) > 0 {
		return strings.clone(transport.lastError, context.temp_allocator)
	}
	return "Could not send the request"
}

// This profile's identity key and the pinned server key, for signing. "" or why not.
@(private = "file")
State_messageChangeSigner :: proc(
	state: ^State,
	serverID: int,
) -> (
	selfUserID: int,
	serverKey: common.IdentityPublicKeyBytes,
	privateKey: common.IdentityPrivateKeyBytes,
	errorMessage: string,
) {
	selfUserID = State_selfUserID(state, serverID)
	e2ee, storeOK := State_e2eeEnsureStore(state, serverID)
	if selfUserID <= 0 || !storeOK || e2ee == nil {
		return 0, {}, {}, NOT_CONNECTED_MESSAGE
	}
	key, ok := common.identityPrivateKeyFromHex(state.config.private_key)
	if !ok {
		return 0, {}, {}, "This profile has no valid identity key"
	}
	return selfUserID, e2ee.store.serverPublicKey, key, ""
}

// A fresh random client message ID for an edit (never all zero).
@(private = "file")
messageEditNewID :: proc() -> (common.ClientMessageID, bool) {
	id: common.ClientMessageID
	if !common.generateRandomBytes(id[:]) {
		return {}, false
	}
	id[0] |= 1
	return id, true
}

// The author edits room message messageID to content (protocol 30): a plaintext message's edit
// is signed, an encrypted room's is sealed on this session's sender chain (#76 M2,
// State_roomChainsSendEdit), so it may wait for the chain's distribution. forgeSignature (a
// test hook for the live proof) sends a signature or seal the server must refuse, and
// checkRights false (the harness) skips the own-message check so the server's refusal shows.
// "" on success (sent or queued), else why.
State_editRoomMessage :: proc(
	state: ^State,
	serverID, roomID, messageID: int,
	content: string,
	forgeSignature := false,
	checkRights := true,
) -> string {
	entry := State_roomMessageEntry(state, serverID, roomID, messageID)
	if entry == nil {
		return MESSAGE_NOT_LOADED_MESSAGE
	}
	if entry.deleted {
		return MESSAGE_ALREADY_DELETED_TEXT
	}
	sealed := len(entry.sealed) > 0 || State_roomIsEncrypted(state, serverID, roomID)
	if sealed && (len(entry.sealed) == 0 || entry.security.protection != .Encrypted) {
		// A message that is not shown opened cannot be edited: D11 needs a sealed one.
		return MESSAGE_EDIT_NOT_OPENED_MESSAGE
	}
	if len(content) > common.CHAT_MESSAGE_MAX_BYTES {
		return "Message is too long"
	}
	if len(content) == 0 && len(entry.attachments) == 0 {
		return "Cannot send an empty message"
	}
	selfUserID, serverKey, privateKey, signerError := State_messageChangeSigner(state, serverID)
	defer crypto.zero_explicit(&privateKey, size_of(privateKey))
	if len(signerError) > 0 {
		return signerError
	}
	if checkRights && entry.senderId != selfUserID {
		return MESSAGE_EDIT_NOT_OWN_MESSAGE
	}
	if sealed {
		return State_roomChainsSendEdit(
			state,
			serverID,
			roomID,
			messageID,
			entry.clientMessageId,
			content,
			forge = forgeSignature,
		)
	}
	editID, idOK := messageEditNewID()
	if !idOK {
		return "Could not prepare the edit"
	}
	signature, signOK := common.signRoomMessageEdit(
		common.MessageChangeFields {
			serverIdentityPublicKey = serverKey,
			conversationID = roomID,
			senderUserID = selfUserID,
			original = entry.clientMessageId,
			edit = editID,
		},
		content,
		privateKey,
	)
	if !signOK {
		return "Could not sign the edit"
	}
	if forgeSignature {
		signature[0] ~= 0x01
	}
	return State_sendMessageChange(
		state,
		serverID,
		MessageChangeSend {
			messageType = .ClientEditRoomMessage,
			roomEdit = common.ClientEditRoomMessagePayload {
				roomId = roomID,
				messageId = messageID,
				originalClientMessageId = entry.clientMessageId,
				clientMessageId = editID,
				content = content,
				signature = signature,
			},
		},
	)
}

// Seals an edit of the encrypted direct message messageID (its client message ID original) as a
// DirectMessage envelope to this profile's and the peer's PINNED keys (#76 M2), bound to the
// edit's own client message ID editID, and sends it. The peer's key must allow encryption now
// (D10: the server stores it only while the recipient keeps that key); an edit never falls back
// to plaintext (D11) and is never queued. "" on success, else why (static or temp).
@(private = "file")
State_directSendEdit :: proc(
	state: ^State,
	serverID, peerUserID, messageID: int,
	original, editID: common.ClientMessageID,
	content: string,
	privateKey: common.IdentityPrivateKeyBytes,
	forge: bool,
) -> string {
	keys := State_directOpenKeys(state, serverID)
	defer DirectOpenKeys_wipe(&keys)
	if !keys.ready {
		return NOT_CONNECTED_MESSAGE
	}
	if !keys.hasOwnKeyPair {
		return ROOM_NO_ENCRYPTION_KEY_NOTE
	}
	info := State_e2eePeerKeyInfo(state, serverID, peerUserID)
	if !info.canEncrypt {
		if info.blockReason == .Pending {
			ids := [1]int{peerUserID}
			State_e2eeRequestUserKeys(state, serverID, ids[:])
			return DIRECT_SETTING_UP_TEXT
		}
		return e2eeKeyStateText(info, State_e2eeUserName(state, serverID, peerUserID))
	}
	envelope: [common.SEALED_ENVELOPE_MAX_BYTES]u8
	defer crypto.zero_explicit(&envelope, size_of(envelope))
	n, err := common.sealDirectMessage(
		common.DirectMessageAADFields {
			serverIdentityPublicKey = keys.serverIdentityPublicKey,
			senderUserID = keys.ownUserID,
			recipientUserID = peerUserID,
			senderIdentityPublicKey = keys.ownIdentityPublicKey,
			recipientIdentityPublicKey = info.identityPublicKey,
			clientMessageID = editID,
		},
		content,
		keys.ownKeyPair.publicKey,
		info.encryptionPublicKey,
		privateKey,
		envelope[:],
		nil,
		original,
	)
	if err != .None {
		return "Could not encrypt the edit"
	}
	if forge {
		envelope[n - 1] ~= 0x01
	}
	return State_sendMessageChange(
		state,
		serverID,
		MessageChangeSend {
			messageType = .ClientEditDirectMessage,
			directEdit = common.ClientEditDirectMessagePayload {
				peerUserId = peerUserID,
				messageId = messageID,
				originalClientMessageId = original,
				clientMessageId = editID,
				envelope = envelope[:n],
			},
		},
	)
}

// Deletes room message messageID: the author's signed delete (encrypted rooms too), or with
// asAdmin an admin's unsigned moderation delete (D5). checkRights false (the harness) sends what
// the server must refuse. "" on success, else why.
State_deleteRoomMessage :: proc(
	state: ^State,
	serverID, roomID, messageID: int,
	asAdmin := false,
	checkRights := true,
) -> string {
	if asAdmin {
		if checkRights && !State_isServerAdmin(state, serverID) {
			return MESSAGE_DELETE_ADMIN_ONLY_MESSAGE
		}
		return State_sendMessageChange(
			state,
			serverID,
			MessageChangeSend {
				messageType = .ClientDeleteRoomMessage,
				roomDelete = common.ClientDeleteRoomMessagePayload {
					roomId = roomID,
					messageId = messageID,
				},
			},
		)
	}
	entry := State_roomMessageEntry(state, serverID, roomID, messageID)
	if entry == nil {
		return MESSAGE_NOT_LOADED_MESSAGE
	}
	if entry.deleted {
		return MESSAGE_ALREADY_DELETED_TEXT
	}
	selfUserID, serverKey, privateKey, signerError := State_messageChangeSigner(state, serverID)
	defer crypto.zero_explicit(&privateKey, size_of(privateKey))
	if len(signerError) > 0 {
		return signerError
	}
	if checkRights && entry.senderId != selfUserID {
		return MESSAGE_DELETE_NOT_OWN_MESSAGE
	}
	signature, signOK := common.signRoomMessageDelete(
		common.MessageChangeFields {
			serverIdentityPublicKey = serverKey,
			conversationID = roomID,
			senderUserID = selfUserID,
			original = entry.clientMessageId,
		},
		privateKey,
	)
	if !signOK {
		return "Could not sign the delete"
	}
	return State_sendMessageChange(
		state,
		serverID,
		MessageChangeSend {
			messageType = .ClientDeleteRoomMessage,
			roomDelete = common.ClientDeleteRoomMessagePayload {
				roomId = roomID,
				messageId = messageID,
				originalClientMessageId = entry.clientMessageId,
				signature = signature,
			},
		},
	)
}

// The sender edits direct message messageID of the conversation with peerUserID: a signed
// plaintext edit of a plaintext message, an envelope to the pinned keys for an encrypted one
// (#76 M2, State_directSendEdit). "" on success, else why.
State_editDirectMessage :: proc(
	state: ^State,
	serverID, peerUserID, messageID: int,
	content: string,
	forgeSignature := false,
	checkRights := true,
) -> string {
	entry := State_directMessageEntry(state, serverID, peerUserID, messageID)
	if entry == nil {
		return MESSAGE_NOT_LOADED_MESSAGE
	}
	if entry.deleted {
		return MESSAGE_ALREADY_DELETED_TEXT
	}
	sealed := len(entry.envelope) > 0
	if sealed && entry.security.protection != .Encrypted {
		return MESSAGE_EDIT_NOT_OPENED_MESSAGE
	}
	if len(content) > common.CHAT_MESSAGE_MAX_BYTES {
		return "Message is too long"
	}
	if len(content) == 0 && len(entry.attachments) == 0 {
		return "Cannot send an empty message"
	}
	selfUserID, serverKey, privateKey, signerError := State_messageChangeSigner(state, serverID)
	defer crypto.zero_explicit(&privateKey, size_of(privateKey))
	if len(signerError) > 0 {
		return signerError
	}
	if checkRights && entry.senderId != selfUserID {
		return MESSAGE_EDIT_NOT_OWN_MESSAGE
	}
	editID, idOK := messageEditNewID()
	if !idOK {
		return "Could not prepare the edit"
	}
	if sealed {
		return State_directSendEdit(
			state,
			serverID,
			peerUserID,
			messageID,
			entry.clientMessageId,
			editID,
			content,
			privateKey,
			forgeSignature,
		)
	}
	signature, signOK := common.signDirectMessageEdit(
		common.MessageChangeFields {
			serverIdentityPublicKey = serverKey,
			conversationID = peerUserID,
			senderUserID = selfUserID,
			original = entry.clientMessageId,
			edit = editID,
		},
		content,
		privateKey,
	)
	if !signOK {
		return "Could not sign the edit"
	}
	if forgeSignature {
		signature[0] ~= 0x01
	}
	return State_sendMessageChange(
		state,
		serverID,
		MessageChangeSend {
			messageType = .ClientEditDirectMessage,
			directEdit = common.ClientEditDirectMessagePayload {
				peerUserId = peerUserID,
				messageId = messageID,
				originalClientMessageId = entry.clientMessageId,
				clientMessageId = editID,
				content = content,
				signature = signature,
			},
		},
	)
}

// The sender deletes direct message messageID (always signed, D5). checkRights false sends a
// delete of the peer's message, which the server refuses. "" on success, else why.
State_deleteDirectMessage :: proc(
	state: ^State,
	serverID, peerUserID, messageID: int,
	checkRights := true,
) -> string {
	entry := State_directMessageEntry(state, serverID, peerUserID, messageID)
	if entry == nil {
		return MESSAGE_NOT_LOADED_MESSAGE
	}
	if entry.deleted {
		return MESSAGE_ALREADY_DELETED_TEXT
	}
	selfUserID, serverKey, privateKey, signerError := State_messageChangeSigner(state, serverID)
	defer crypto.zero_explicit(&privateKey, size_of(privateKey))
	if len(signerError) > 0 {
		return signerError
	}
	if checkRights && entry.senderId != selfUserID {
		return MESSAGE_DELETE_NOT_OWN_MESSAGE
	}
	signature, signOK := common.signDirectMessageDelete(
		common.MessageChangeFields {
			serverIdentityPublicKey = serverKey,
			conversationID = peerUserID,
			senderUserID = selfUserID,
			original = entry.clientMessageId,
		},
		privateKey,
	)
	if !signOK {
		return "Could not sign the delete"
	}
	return State_sendMessageChange(
		state,
		serverID,
		MessageChangeSend {
			messageType = .ClientDeleteDirectMessage,
			directDelete = common.ClientDeleteDirectMessagePayload {
				peerUserId = peerUserID,
				messageId = messageID,
				originalClientMessageId = entry.clientMessageId,
				signature = signature,
			},
		},
	)
}

// Asks for messageID's edit list (D14: once per session, on demand; force asks again).
// conversationID is the room or the peer's user ID. "" on success (or already loaded or
// loading), else why.
State_fetchMessageEdits :: proc(
	state: ^State,
	serverID: int,
	kind: common.MessageEditsKind,
	conversationID, messageID: int,
	force := false,
) -> string {
	view: ^MessageEditView
	if kind == .Room {
		if entry := State_roomMessageEntry(state, serverID, conversationID, messageID);
		   entry != nil {
			view = &entry.edit
		}
	} else if kind == .Direct {
		if entry := State_directMessageEntry(state, serverID, conversationID, messageID);
		   entry != nil {
			view = &entry.edit
		}
	} else {
		return "Unknown conversation kind"
	}
	if view != nil && !force && (view.editsLoaded || view.editsLoading) {
		return ""
	}
	sent := State_sendMessageChange(
		state,
		serverID,
		MessageChangeSend {
			messageType = .ClientFetchMessageEdits,
			fetch = common.ClientFetchMessageEditsPayload {
				kind = kind,
				conversationId = conversationID,
				messageId = messageID,
			},
		},
	)
	if len(sent) == 0 && view != nil {
		view.editsLoading = true
	}
	return sent
}

// The cached edit list of a message, oldest first, with each edit's verdict; loaded false until
// ServerMessageEdits arrived. Borrowed until the entry changes.
State_messageEdits :: proc(
	state: ^State,
	serverID: int,
	kind: common.MessageEditsKind,
	conversationID, messageID: int,
) -> (
	edits: []common.MessageEdit,
	statuses: []MessageEditStatus,
	loaded: bool,
) {
	view: ^MessageEditView
	if kind == .Room {
		if entry := State_roomMessageEntry(state, serverID, conversationID, messageID);
		   entry != nil {
			view = &entry.edit
		}
	} else {
		if entry := State_directMessageEntry(state, serverID, conversationID, messageID);
		   entry != nil {
			view = &entry.edit
		}
	}
	if view == nil {
		return nil, nil, false
	}
	return view.edits[:], view.editStatuses[:], view.editsLoaded
}

// Marks a live message counted unread (D13), so its delete can take the count back.
State_messageNoteCountedUnread :: proc(
	state: ^State,
	serverID: int,
	kind: common.MessageEditsKind,
	conversationID, messageID: int,
) {
	if kind == .Room {
		if entry := State_roomMessageEntry(state, serverID, conversationID, messageID);
		   entry != nil {
			entry.edit.countedUnread = true
		}
		return
	}
	if entry := State_directMessageEntry(state, serverID, conversationID, messageID); entry != nil {
		entry.edit.countedUnread = true
	}
}

// ── Transport: decoding the notices ──────────────────────────────

// The protocol 30 server packets as runtime events (MessageEdited, MessageDeleted,
// MessageEditsReceived). Fixed-size byte fields decode through the heap.
ClientServerTransport_translateMessageEditPacket :: proc(
	transport: ^ClientServerTransport,
	innerPacket: common.Packet,
) -> (
	ClientTransportRuntimeEvent,
	bool,
) {
	event := ClientTransportRuntimeEvent {
		serverID = transport.serverID,
	}
	#partial switch innerPacket.messageType {
	case .ServerRoomMessageEdited:
		payload: common.ServerRoomMessageEditedPayload
		if cbor.unmarshal(innerPacket.payload, &payload, temp_allocator = context.allocator) !=
			   nil ||
		   payload.roomId <= 0 ||
		   payload.messageId <= 0 ||
		   !common.messageEditIsSet(payload.edit) {
			common.ServerRoomMessageEditedPayload_deinit(&payload)
			return ClientServerTransport_invalidPayloadEvent(
					transport,
					"invalid message edit payload",
				),
				true
		}
		event.kind = .MessageEdited
		event.editKind = .Room
		event.roomID = payload.roomId
		event.messageID = payload.messageId
		event.senderID = payload.senderId
		event.editCount = payload.editCount
		event.messageEdit = payload.edit
	case .ServerDirectMessageEdited:
		payload: common.ServerDirectMessageEditedPayload
		if cbor.unmarshal(innerPacket.payload, &payload, temp_allocator = context.allocator) !=
			   nil ||
		   payload.messageId <= 0 ||
		   !common.messageEditIsSet(payload.edit) {
			common.ServerDirectMessageEditedPayload_deinit(&payload)
			return ClientServerTransport_invalidPayloadEvent(
					transport,
					"invalid message edit payload",
				),
				true
		}
		event.kind = .MessageEdited
		event.editKind = .Direct
		event.messageID = payload.messageId
		event.senderID = payload.senderId
		event.peerUserID = payload.recipientId
		event.editCount = payload.editCount
		event.messageEdit = payload.edit
	case .ServerRoomMessageDeleted:
		payload: common.ServerRoomMessageDeletedPayload
		if cbor.unmarshal(innerPacket.payload, &payload, temp_allocator = context.allocator) !=
			   nil ||
		   payload.roomId <= 0 ||
		   payload.messageId <= 0 {
			common.ServerRoomMessageDeletedPayload_deinit(&payload)
			return ClientServerTransport_invalidPayloadEvent(
					transport,
					"invalid message delete payload",
				),
				true
		}
		event.kind = .MessageDeleted
		event.editKind = .Room
		event.roomID = payload.roomId
		event.messageID = payload.messageId
		event.senderID = payload.senderId
		event.messageDeletion = payload.deletion
	case .ServerDirectMessageDeleted:
		payload: common.ServerDirectMessageDeletedPayload
		if cbor.unmarshal(innerPacket.payload, &payload, temp_allocator = context.allocator) !=
			   nil ||
		   payload.messageId <= 0 {
			common.ServerDirectMessageDeletedPayload_deinit(&payload)
			return ClientServerTransport_invalidPayloadEvent(
					transport,
					"invalid message delete payload",
				),
				true
		}
		event.kind = .MessageDeleted
		event.editKind = .Direct
		event.messageID = payload.messageId
		event.senderID = payload.senderId
		event.peerUserID = payload.recipientId
		event.messageDeletion = payload.deletion
	case .ServerMessageEdits:
		payload: common.ServerMessageEditsPayload
		if cbor.unmarshal(innerPacket.payload, &payload, temp_allocator = context.allocator) !=
			   nil ||
		   (payload.kind != .Room && payload.kind != .Direct) ||
		   payload.messageId <= 0 ||
		   len(payload.edits) > common.MESSAGE_EDITS_MAX {
			common.ServerMessageEditsPayload_deinit(&payload)
			return ClientServerTransport_invalidPayloadEvent(
					transport,
					"invalid message edits payload",
				),
				true
		}
		event.kind = .MessageEditsReceived
		event.editKind = payload.kind
		if payload.kind == .Room {
			event.roomID = payload.conversationId
		} else {
			event.peerUserID = payload.conversationId
		}
		event.messageID = payload.messageId
		event.messageEdits = payload.edits
	case:
		return {}, false
	}
	return event, true
}
