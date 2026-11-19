package common

import "core:fmt"
import "core:strings"

// Editing and deleting messages (protocol 30, issue #76,
// docs/plan/2026-11-19-message-edit-delete.md).
//
// The author edits and deletes their own room and direct messages; admins delete any room
// message (D1, D5). An edit keeps the message's ID, attachments (D9) and kind: an edit of a
// plaintext message is plaintext, signed under "haychat-room-edit-v1" or "haychat-dm-edit-v1",
// and an edit of a sealed message is sealed (D11): a SealedRoomMessage on the sender's current
// chain or a sealDirectMessage envelope, whose clientMessageId is the edit's. Every author
// delete is signed ("haychat-room-delete-v1", "haychat-dm-delete-v1"; D6); an admin's room
// delete carries no signature and clients show it as "Removed by the server". A delete leaves a
// tombstone with the message's ID, sender, timestamp, clientMessageId and chain position (D2,
// D7) and erases its content, sealed bytes, signature, files (D8) and every edit.
//
// History pages and live messages carry the latest version (lastEdit) and the edit count (D14);
// the whole list comes from ClientFetchMessageEdits, oldest first.

// Most edits one message may have (D12). Edits have no time limit.
MESSAGE_EDITS_MAX :: 100

// One version of an edited message. id is the edit's own row ID (increasing per message);
// clientMessageId the edit's random ID, never the original's; timestamp PostgreSQL timestamptz
// text. A plaintext edit has content (1..CHAT_MESSAGE_MAX_BYTES bytes, or empty when the message
// has attachments) and the author's signature; a sealed one has sealed bytes (a room's
// SealedRoomMessage or a direct message's envelope, byte for byte) and an empty content and
// zero signature. Every string and the bytes are owned once decoded (MessageEdit_deinit).
MessageEdit :: struct {
	id:              int,
	clientMessageId: ClientMessageID,
	timestamp:       string,
	content:         string,
	signature:       SignatureBytes,
	sealed:          []u8,
}

MessageEdit_deinit :: proc(edit: ^MessageEdit) {
	delete(edit.timestamp)
	delete(edit.content)
	delete(edit.sealed)
	edit^ = {}
}

// A deep copy of edit with allocator.
MessageEdit_clone :: proc(edit: MessageEdit, allocator := context.allocator) -> MessageEdit {
	copied := edit
	copied.timestamp = strings.clone(edit.timestamp, allocator)
	copied.content = strings.clone(edit.content, allocator)
	copied.sealed = nil
	if len(edit.sealed) > 0 {
		copied.sealed = make([]u8, len(edit.sealed), allocator)
		copy(copied.sealed, edit.sealed)
	}
	return copied
}

MessageEdits_deinit :: proc(edits: ^[dynamic]MessageEdit) {
	for &edit in edits {
		MessageEdit_deinit(&edit)
	}
	delete(edits^)
	edits^ = nil
}

// Whether edit holds a version (an empty edit is "no edits").
messageEditIsSet :: proc(edit: MessageEdit) -> bool {
	return edit.id > 0
}

// How a message was deleted. A signature by the author (signRoomMessageDelete or
// signDirectMessageDelete over the message's clientMessageId) makes it the author's delete; a
// zero signature is an admin's moderation, and clients show both that and a signature that does
// not verify against the author's pin as "Removed by the server" (D6). deletedAt is owned.
MessageDeletion :: struct {
	deletedAt: string,
	signature: SignatureBytes,
}

MessageDeletion_deinit :: proc(deletion: ^MessageDeletion) {
	delete(deletion.deletedAt)
	deletion^ = {}
}

MessageDeletion_clone :: proc(
	deletion: MessageDeletion,
	allocator := context.allocator,
) -> MessageDeletion {
	copied := deletion
	copied.deletedAt = strings.clone(deletion.deletedAt, allocator)
	return copied
}

// ClientEditRoomMessage: the author edits messageId in roomId. clientMessageId is the edit's own
// new random ID; originalClientMessageId repeats the message's, which the signature covers and
// the server checks against the stored message. A plaintext edit carries content and signature
// (signRoomMessageEdit, checked against the session's identity key); a sealed one (an encrypted
// room) carries sealed, a SealedRoomMessage at the room's current epoch on the sender's chain,
// whose signature the server checks like a new sealed message's, with an empty content.
//
// The server refuses (ServerProtocolError, each naming the message: messageRefusal) an edit by
// anyone but the sender, of a deleted message, of a message the author can no longer read, in a
// room where the author may not send now (D10: membership, SendMessages, a chat room type, an
// encrypted room's current log version), of another kind than the message (D11), past
// MESSAGE_EDITS_MAX (D12), and a clientMessageId or chain index the sender used before for a
// message or an edit.
ClientEditRoomMessagePayload :: struct {
	roomId:                  int,
	messageId:               int,
	originalClientMessageId: ClientMessageID,
	clientMessageId:         ClientMessageID,
	content:                 string,
	signature:               SignatureBytes,
	sealed:                  []u8,
}

ClientEditRoomMessagePayload_deinit :: proc(payload: ^ClientEditRoomMessagePayload) {
	delete(payload.content)
	delete(payload.sealed)
	payload.content = ""
	payload.sealed = nil
}

// ServerRoomMessageEdited: a stored edit, to every session of each account that may read the
// message (room members past the From join cut). editCount is the message's count after it.
ServerRoomMessageEditedPayload :: struct {
	roomId:    int,
	messageId: int,
	senderId:  int,
	editCount: int,
	edit:      MessageEdit,
}

ServerRoomMessageEditedPayload_deinit :: proc(payload: ^ServerRoomMessageEditedPayload) {
	MessageEdit_deinit(&payload.edit)
	payload^ = {}
}

// ClientDeleteRoomMessage: the author deletes messageId with signature (signRoomMessageDelete
// over originalClientMessageId), or an admin deletes any room message with a zero signature
// (moderation, D5; DATABASE_ACTOR_IS_ADMIN_SQL in the statement). An author's delete needs only
// that the author can still read the message.
ClientDeleteRoomMessagePayload :: struct {
	roomId:                  int,
	messageId:               int,
	originalClientMessageId: ClientMessageID,
	signature:               SignatureBytes,
}

// ServerRoomMessageDeleted: to every reader, like ServerRoomMessageEdited (and to the admin who
// asked). senderId is the message's sender, whose pin checks deletion.signature.
ServerRoomMessageDeletedPayload :: struct {
	roomId:    int,
	messageId: int,
	senderId:  int,
	deletion:  MessageDeletion,
}

ServerRoomMessageDeletedPayload_deinit :: proc(payload: ^ServerRoomMessageDeletedPayload) {
	MessageDeletion_deinit(&payload.deletion)
	payload^ = {}
}

// ClientEditDirectMessage: the sender edits messageId of the conversation with peerUserId. A
// plaintext edit carries content and signature (signDirectMessageEdit); a sealed one an
// envelope (sealDirectMessage, whose AAD names the edit's clientMessageId and both identity
// keys), stored only while the recipient keeps the key it was sealed to (D10). Refusals as for
// ClientEditRoomMessage, plus the DM rules (restricted accounts).
ClientEditDirectMessagePayload :: struct {
	peerUserId:              int,
	messageId:               int,
	originalClientMessageId: ClientMessageID,
	clientMessageId:         ClientMessageID,
	content:                 string,
	signature:               SignatureBytes,
	envelope:                []u8,
}

ClientEditDirectMessagePayload_deinit :: proc(payload: ^ClientEditDirectMessagePayload) {
	delete(payload.content)
	delete(payload.envelope)
	payload.content = ""
	payload.envelope = nil
}

// ServerDirectMessageEdited: to every session of both sides.
ServerDirectMessageEditedPayload :: struct {
	senderId:    int,
	recipientId: int,
	messageId:   int,
	editCount:   int,
	edit:        MessageEdit,
}

ServerDirectMessageEditedPayload_deinit :: proc(payload: ^ServerDirectMessageEditedPayload) {
	MessageEdit_deinit(&payload.edit)
	payload^ = {}
}

// ClientDeleteDirectMessage: only the sender deletes a direct message (D5), always signed
// (signDirectMessageDelete).
ClientDeleteDirectMessagePayload :: struct {
	peerUserId:              int,
	messageId:               int,
	originalClientMessageId: ClientMessageID,
	signature:               SignatureBytes,
}

// ServerDirectMessageDeleted: to every session of both sides.
ServerDirectMessageDeletedPayload :: struct {
	senderId:    int,
	recipientId: int,
	messageId:   int,
	deletion:    MessageDeletion,
}

ServerDirectMessageDeletedPayload_deinit :: proc(payload: ^ServerDirectMessageDeletedPayload) {
	MessageDeletion_deinit(&payload.deletion)
	payload^ = {}
}

// Which conversation ClientFetchMessageEdits names: a room (conversationId the room ID) or a
// direct conversation (conversationId the peer's user ID). The values are the wire format.
MessageEditsKind :: enum u8 {
	None   = 0,
	Room   = 1,
	Direct = 2,
}

// ClientFetchMessageEdits: every edit of messageId, for whoever may read it.
ClientFetchMessageEditsPayload :: struct {
	kind:           MessageEditsKind,
	conversationId: int,
	messageId:      int,
}

// ServerMessageEdits: the edits oldest first (the original is the message itself, not part of
// the list); empty for a message without edits and for a deleted one.
ServerMessageEditsPayload :: struct {
	kind:           MessageEditsKind,
	conversationId: int,
	messageId:      int,
	edits:          [dynamic]MessageEdit,
}

ServerMessageEditsPayload_deinit :: proc(payload: ^ServerMessageEditsPayload) {
	MessageEdits_deinit(&payload.edits)
	payload^ = {}
}

// Refusals of an edit, a delete or an edit fetch, as ServerProtocolError messages. The server
// names the message they refuse (messageRefusal), so clients match them by prefix.
MESSAGE_EDIT_INVALID_MESSAGE :: "Invalid message edit"
MESSAGE_DELETE_INVALID_MESSAGE :: "Invalid message delete"
MESSAGE_EDIT_SIGNATURE_INVALID_MESSAGE :: "Invalid message edit signature"
MESSAGE_DELETE_SIGNATURE_INVALID_MESSAGE :: "Invalid message delete signature"
MESSAGE_NOT_FOUND_MESSAGE :: "Message not found"
MESSAGE_NOT_AUTHOR_MESSAGE :: "You can only edit or delete your own messages"
MESSAGE_ALREADY_DELETED_MESSAGE :: "This message was deleted"
MESSAGE_EDIT_KIND_MESSAGE :: "An edit must be sealed exactly when its message is"
MESSAGE_EDITS_LIMIT_MESSAGE :: "This message cannot be edited again"
MESSAGE_EDIT_DUPLICATE_MESSAGE :: "Duplicate message edit"

// The refusal text for messageID: base followed by " (message N)" (allocator).
messageRefusal :: proc(base: string, messageID: int, allocator := context.allocator) -> string {
	return fmt.aprintf("%s (message %d)", base, messageID, allocator = allocator)
}

// The shape a plaintext edit's content must have before the server looks at the message: at
// most CHAT_MESSAGE_MAX_BYTES bytes. Whether it may be empty depends on the message's
// attachments, which only the database knows (D9).
messageEditContentLengthIsValid :: proc(contentLength: int) -> bool {
	return contentLength >= 0 && contentLength <= CHAT_MESSAGE_MAX_BYTES
}

// ── Database IPC (server router ↔ database worker) ───────────────────────────────────────

// Which statement a DatabaseMessageChangeRequest runs.
DatabaseMessageChangeAction :: enum u8 {
	EditRoom,
	DeleteRoom,
	EditDirect,
	DeleteDirect,
	FetchRoomEdits,
	FetchDirectEdits,
}

// One edit, delete or edit fetch of messageId (protocol 30). The router checked the shape and
// every signature it can check against the session's identity key (a plaintext edit's and an
// author delete's, a sealed room edit's seal); the statement checks the rest in the same
// statement as the change (server/database_message_edits.odin). content and sealed (a room
// edit's SealedRoomMessage or a DM edit's envelope) are owned. For a sealed DM edit the worker
// checks the envelope against the recipient's identity key (serverIdentityPublicKey and
// senderIdentityPublicKey, the session's) and stores it only while the recipient keeps that key.
// adminDelete is a room delete without a signature, which needs the admin role.
DatabaseMessageChangeRequest :: struct {
	action:                  DatabaseMessageChangeAction,
	actorUserId:             int,
	roomId:                  int,
	peerUserId:              int,
	messageId:               int,
	originalClientMessageId: ClientMessageID,
	clientMessageId:         ClientMessageID,
	content:                 string,
	signature:               SignatureBytes,
	sealed:                  []u8,
	epoch:                   int,
	chainId:                 ChainID,
	chainIndex:              int,
	adminDelete:             bool,
	serverIdentityPublicKey: IdentityPublicKeyBytes,
	senderIdentityPublicKey: IdentityPublicKeyBytes,
}

DatabaseMessageChangeRequest_deinit :: proc(request: ^DatabaseMessageChangeRequest) {
	delete(request.content)
	delete(request.sealed)
	request.content = ""
	request.sealed = nil
}

// What the statement decided, in the order it checks.
MessageChangeOutcome :: enum u8 {
	Applied,
	NotMember, // Not a member of the room (or the room is gone)
	NotFound, // No such message in this conversation, or one the actor can no longer read
	NotAuthor, // Someone else's message
	NotAdmin, // A delete without a signature by an account without the admin role
	Deleted, // Already a tombstone
	ChatDisabled, // A voice-only room (D10)
	SendDenied, // No SendMessages in the room (D10)
	Restricted, // A restricted account and no shared room (D10, DM)
	KindMismatch, // Plaintext for a sealed message or the other way round (D11)
	StaleEpoch, // A sealed room edit not at the room's current log version (D10)
	InvalidEnvelope, // A sealed DM edit whose envelope does not verify for the recipient's key
	InvalidContent, // An empty plaintext edit of a message without attachments (D9)
	EditLimit, // MESSAGE_EDITS_MAX reached (D12)
	Duplicate, // A clientMessageId or chain index the sender used before
}

// readerUserIds (owned) are the accounts that may read the message: who hears of the change.
// edit (owned) is the stored edit, deletion (owned) the tombstone's, removedBlobs (owned) the
// files a delete made Removed tombstones (D8), edits (owned) a fetch's list, oldest first.
// senderId and recipientId are the message's sides (recipientId only for a DM), and encrypted
// whether the room is.
DatabaseMessageChangeResult :: struct {
	outcome:       MessageChangeOutcome,
	senderId:      int,
	recipientId:   int,
	editCount:     int,
	edit:          MessageEdit,
	deletion:      MessageDeletion,
	readerUserIds: [dynamic]int,
	removedBlobs:  [dynamic]AttachmentBlobID,
	edits:         [dynamic]MessageEdit,
}

DatabaseMessageChangeResult_deinit :: proc(result: ^DatabaseMessageChangeResult) {
	MessageEdit_deinit(&result.edit)
	MessageDeletion_deinit(&result.deletion)
	delete(result.readerUserIds)
	delete(result.removedBlobs)
	MessageEdits_deinit(&result.edits)
	result^ = {}
}
