package common

import "core:strings"
import "core:unicode/utf8"

// Attachment control messages and database IPC (protocol 26, attachments plan F1). The control
// messages are CBOR on the control channel; the chunks are binary on channel 5
// (attachment_wire.odin). Every refusal is a ServerAttachmentRefused naming the request ID (for
// a begin) or the blob ID, with one of the sentences below.

// Refusal sentences. Clients may match them; never reword one.
ATTACHMENTS_DISABLED_MESSAGE :: "Attachments are disabled on this server"
ATTACHMENT_INVALID_REQUEST_MESSAGE :: "Invalid attachment request"
ATTACHMENT_TOO_LARGE_MESSAGE :: "Attachment is too large"
ATTACHMENT_QUOTA_MESSAGE :: "Attachment storage quota exceeded"
ATTACHMENT_RATE_MESSAGE :: "Attachment upload limit reached; try again later"
ATTACHMENT_STORAGE_FULL_MESSAGE :: "Server storage is full"
ATTACHMENT_NOT_MEMBER_MESSAGE :: "Not a room member"
ATTACHMENT_ENCRYPTION_MISMATCH_MESSAGE :: "Attachment encryption does not match the room"
ATTACHMENT_UNKNOWN_RECIPIENT_MESSAGE :: "Unknown direct message recipient"
ATTACHMENT_TOO_MANY_UPLOADS_MESSAGE :: "Too many uploads at once"
ATTACHMENT_TOO_MANY_DOWNLOADS_MESSAGE :: "Too many downloads at once"
ATTACHMENT_NOT_FOUND_MESSAGE :: "Attachment not found"
ATTACHMENT_ALREADY_ACTIVE_MESSAGE :: "Attachment transfer already in progress"
ATTACHMENT_INCOMPLETE_MESSAGE :: "Upload is incomplete"
ATTACHMENT_MISMATCH_MESSAGE :: "Upload did not match"
ATTACHMENT_FLOW_MESSAGE :: "Attachment chunk out of order"
ATTACHMENT_STORAGE_ERROR_MESSAGE :: "Server storage error"
ATTACHMENT_UNAVAILABLE_MESSAGE :: "Attachments are unavailable"

// Where a blob is in its life (attachments.state). Stored as a number; never renumber.
AttachmentState :: enum u8 {
	Uploading = 0,
	Ready     = 1, // stored and hashed, not yet bound to a message
	Bound     = 2, // bound to exactly one message (F2)
	Removed   = 3, // the file is gone; a tombstone (cancelled, mismatched, or removed by an admin)
}

// Exactly one of roomId and recipientUserId is positive. size is the exact number of bytes
// the client will upload (ciphertext in encrypted conversations). requestId is the client's,
// echoed in the ready or refused answer.
ClientAttachmentUploadBeginPayload :: struct {
	requestId:       u32,
	roomId:          int,
	recipientUserId: int,
	size:            u64,
	encrypted:       bool,
}

// The answer to a begin (requestId set) or a resume (requestId 0): send chunks in order from
// received, at most windowChunks unacknowledged chunks of at most chunkBytes each.
ServerAttachmentUploadReadyPayload :: struct {
	requestId:    u32,
	blobId:       AttachmentBlobID,
	received:     u64,
	chunkBytes:   int,
	windowChunks: int,
}

ClientAttachmentUploadResumePayload :: struct {
	blobId: AttachmentBlobID,
}

// Sent once every chunk is acknowledged. The server compares the hash of what it stored.
ClientAttachmentUploadFinishPayload :: struct {
	blobId: AttachmentBlobID,
	sha256: AttachmentSHA256,
}

ServerAttachmentUploadDonePayload :: struct {
	blobId: AttachmentBlobID,
	size:   u64,
	sha256: AttachmentSHA256,
}

// Download a blob from offset (a resumed download starts where the last one stopped).
ClientAttachmentDownloadPayload :: struct {
	blobId: AttachmentBlobID,
	offset: u64,
}

// DownloadChunk packets from offset to size follow on channel 5; acknowledge each one.
ServerAttachmentDownloadBeginPayload :: struct {
	blobId: AttachmentBlobID,
	size:   u64,
	offset: u64,
}

// Stops this session's upload of the blob (which then cannot be resumed) or its download.
ClientAttachmentCancelPayload :: struct {
	blobId: AttachmentBlobID,
}

// message is owned once decoded.
ServerAttachmentRefusedPayload :: struct {
	requestId: u32,
	blobId:    AttachmentBlobID,
	message:   string,
}

ServerAttachmentRefusedPayload_deinit :: proc(payload: ^ServerAttachmentRefusedPayload) {
	delete(payload.message)
	payload.message = ""
}

// ── Database IPC ──────────────────────────────────────────────────

DatabaseAttachmentAction :: enum u8 {
	// The begin statement (D11, D21): membership and Send (room) or the direct message
	// recipient and visibility checks, quota, hourly rate, capacity and size, and the insert.
	Begin,
	// The owner's Uploading blob: its declared size and the bytes recorded so far.
	Resume,
	// Records an upload's progress (received, last_chunk_at).
	Progress,
	// Marks an Uploading blob Ready with its hash.
	Finish,
	// Makes the owner's Uploading blob a Removed tombstone (a cancel or a hash mismatch).
	Abandon,
	// Deletes a blob that was never written to (the storage worker refused it at begin).
	DeleteNew,
	// May the requester download the blob? D10 (protocol 27): whoever may read its message's
	// history, or its owner before it is bound; never a Removed blob.
	DownloadCheck,
	// Deletes the rows the sweeper may delete (stale uploads, unbound blobs past the pending
	// window, unbound tombstones, bound blobs whose message is gone; never a row younger than an
	// hour) and returns their blob IDs and states, so the storage worker deletes their files.
	Sweep,
	// The state of each blob ID in blobIds that has a row (the startup orphan scan).
	Known,
	// Protocol 28 (F3, D22): an admin (userId, checked in the statement) makes a Ready or Bound
	// blob a Removed tombstone, keeping every signed field and the message link; the result
	// names the owner, the conversation and every account that may read the message.
	Remove,
	// Protocol 28: storage use (admins only, checked in the statement): the stored bytes and the
	// top ATTACHMENT_USAGE_ACCOUNTS_MAX accounts by bytes, tombstones excluded.
	Usage,
	// Protocol 28: the newest bound tombstones (limit), whose files the hourly pass deletes
	// again. A removal made in SQL (deploy/sql/remove-attachment.sql) cannot delete the file
	// itself; the storage worker's delete is idempotent.
	TombstoneFiles,
}

DatabaseAttachmentRequest :: struct {
	action:          DatabaseAttachmentAction,
	userId:          int, // the owner, or the requester of a download
	blobId:          AttachmentBlobID,
	// Begin.
	roomId:          int,
	recipientUserId: int,
	encrypted:       bool,
	// Begin: the declared size. Progress: received. Finish: the stored size.
	size:            u64,
	sha256:          AttachmentSHA256,
	// Begin's limits, from the server configuration (0 = none, but maxBytes).
	maxBytes:        i64,
	quotaBytes:      i64,
	bytesPerHour:    i64,
	capacityBytes:   i64,
	// Sweep: the pending window, the most rows per pass, and blobs with a live transfer.
	pendingHours:    int,
	limit:           int,
	// Sweep: blobs never to sweep (live transfers). Known: the blobs to look up. Owned.
	blobIds:         [dynamic]AttachmentBlobID,
}

DatabaseAttachmentOutcome :: enum u8 {
	Applied, // the action happened (begin: the blob was created)
	NotFound, // no such blob for this user in the state the action needs
	NotMember,
	SendDenied,
	ChatDisabled, // a voice-only room takes no messages, so no attachments either
	EncryptionMismatch,
	UnknownRecipient, // a direct message recipient that does not exist, or the requester
	Restricted, // a direct message recipient the requester may not meet (D17)
	TooLarge,
	QuotaExceeded,
	RateExceeded,
	CapacityExceeded,
	// Protocol 27 (D20): the requester may send in the room but lacks AttachFiles.
	AttachDenied,
	// Protocol 28: the requester of Remove or Usage is not an admin.
	NotAdmin,
	// Protocol 28: DownloadCheck of a blob an admin removed, by an account that may read its
	// message (it learns nothing its history does not show).
	Removed,
}

DatabaseAttachmentBlob :: struct {
	blobId: AttachmentBlobID,
	state:  AttachmentState,
}

DatabaseAttachmentResult :: struct {
	action:   DatabaseAttachmentAction,
	outcome:  DatabaseAttachmentOutcome,
	size:     u64,
	received: u64,
	sha256:   AttachmentSHA256,
	// Sweep: the deleted rows. Known: the rows found. TombstoneFiles: the tombstones. Owned.
	blobs:    [dynamic]DatabaseAttachmentBlob,
	// Remove (protocol 28): the blob's owner, its conversation as ServerAttachmentRemoved names
	// it, the message it was bound to (0 for none), and the accounts that may read it (owned).
	removal:  DatabaseAttachmentRemoval,
	// Usage (protocol 28): every stored byte (tombstones excluded) and the top accounts (owned).
	usedBytes: u64,
	accounts: [dynamic]AttachmentAccountUsage,
}

DatabaseAttachmentRemoval :: struct {
	ownerUserId:     int,
	roomId:          int,
	senderId:        int,
	recipientId:     int,
	chatMessageId:   int,
	directMessageId: int,
	readerUserIds:   [dynamic]int,
}

// ── Attachments on messages (protocol 27, attachments plan F2: D14-D16, D18) ──────────────

// Most attachments one message carries (D16), a wire constant.
ATTACHMENTS_PER_MESSAGE_MAX :: 4
// A file name: 1..ATTACHMENT_NAME_MAX_BYTES bytes of UTF-8 with no control characters and no
// path separators (attachmentNameIsValid). A media type: 1..ATTACHMENT_MEDIA_TYPE_MAX_BYTES
// bytes of ASCII "type/subtype" (attachmentMediaTypeIsValid), declared by the sender and never
// trusted for anything but the label on a file card.
ATTACHMENT_NAME_MAX_BYTES :: 255
ATTACHMENT_MEDIA_TYPE_MAX_BYTES :: 100
// The media type a client sends when it knows nothing better.
ATTACHMENT_DEFAULT_MEDIA_TYPE :: "application/octet-stream"

// One file on a message. A plaintext message (an unencrypted room, or the direct message
// fallback) fills every field but removed and signs them (signPlaintextRoomMessage and
// signPlaintextDirectMessage, v2 labels): size and sha256 are the stored bytes', which are the
// file's. A sealed message (an encrypted room or direct message) fills only blobId and size, the
// stored ciphertext's; the file key, the hash, the name and the media type travel inside the
// seal (SealedAttachment, e2ee.odin). removed is the server's (attachments.state Removed, F3:
// an admin removed the file) and is never signed; a removed attachment cannot be downloaded.
// name and mediaType are owned once decoded (AttachmentRef_deinit).
AttachmentRef :: struct {
	blobId:    AttachmentBlobID,
	size:      u64,
	sha256:    AttachmentSHA256,
	name:      string,
	mediaType: string,
	removed:   bool,
}

AttachmentRef_deinit :: proc(ref: ^AttachmentRef) {
	delete(ref.name)
	delete(ref.mediaType)
	ref.name = ""
	ref.mediaType = ""
}

// Frees every reference's strings and the array itself.
AttachmentRefs_deinit :: proc(refs: ^[dynamic]AttachmentRef) {
	for &ref in refs {
		AttachmentRef_deinit(&ref)
	}
	delete(refs^)
	refs^ = nil
}

// A deep copy of refs with allocator (nil for none).
AttachmentRefs_clone :: proc(
	refs: []AttachmentRef,
	allocator := context.allocator,
) -> [dynamic]AttachmentRef {
	if len(refs) == 0 {
		return nil
	}
	cloned := make([dynamic]AttachmentRef, 0, len(refs), allocator)
	for ref in refs {
		copied := ref
		copied.name = strings.clone(ref.name, allocator)
		copied.mediaType = strings.clone(ref.mediaType, allocator)
		append(&cloned, copied)
	}
	return cloned
}

// What ServerAuthSuccess announces (D18): whether uploads are on, the largest stored blob, the
// account quota (0 = none) and how much of it the account uses now. A client refuses a file
// that is too large or over quota before it uploads; the server enforces every limit anyway.
AttachmentLimits :: struct {
	enabled:    bool,
	maxBytes:   u64,
	quotaBytes: u64,
	usedBytes:  u64,
}

// Refusals of a message with attachments (protocol 27), as ServerProtocolError messages.
// Clients may match them; never reword one.
ATTACHMENT_REFS_INVALID_MESSAGE :: "Invalid message attachments"
ATTACHMENT_BIND_REFUSED_MESSAGE :: "An attachment cannot be sent with this message"
ATTACHMENT_SEND_NOT_PERMITTED_MESSAGE :: "You cannot attach files in this room"

// A file name a message may carry (D16): 1..ATTACHMENT_NAME_MAX_BYTES bytes of valid UTF-8,
// no control character (C0, DEL or C1), no '/' or '\\', and not "." or "..". A client still
// sanitizes the name it suggests when saving (D19).
attachmentNameIsValid :: proc(name: string) -> bool {
	if len(name) == 0 || len(name) > ATTACHMENT_NAME_MAX_BYTES || !utf8.valid_string(name) {
		return false
	}
	if name == "." || name == ".." {
		return false
	}
	for r in name {
		if r < 0x20 || (r >= 0x7F && r <= 0x9F) || r == '/' || r == '\\' {
			return false
		}
	}
	return true
}

// A media type a message may carry (D16): 1..ATTACHMENT_MEDIA_TYPE_MAX_BYTES bytes of
// "type/subtype", each side a non-empty run of letters, digits and !#$&^_.+-, with no
// parameters.
attachmentMediaTypeIsValid :: proc(mediaType: string) -> bool {
	if len(mediaType) == 0 || len(mediaType) > ATTACHMENT_MEDIA_TYPE_MAX_BYTES {
		return false
	}
	slash := strings.index_byte(mediaType, '/')
	if slash <= 0 || slash == len(mediaType) - 1 {
		return false
	}
	for index in 0 ..< len(mediaType) {
		c := mediaType[index]
		if index == slash {
			continue
		}
		switch c {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9':
		case '!', '#', '$', '&', '^', '_', '.', '+', '-':
		case:
			return false
		}
	}
	return true
}

// The shape every message's attachment list must have, checked by the router before the
// database and by clients before they show a message: at most ATTACHMENTS_PER_MESSAGE_MAX, each
// with a set blob ID (no two alike) and a positive size, and removed false (only the server
// sets it, on what it sends). A plaintext message's (sealed false) references carry a set hash, a
// valid name and a valid media type; a sealed message's carry none of the three, which travel
// inside the seal. fromServer allows removed.
attachmentRefsAreValid :: proc(refs: []AttachmentRef, sealed: bool, fromServer := false) -> bool {
	if len(refs) > ATTACHMENTS_PER_MESSAGE_MAX {
		return false
	}
	for ref, index in refs {
		if !attachmentBlobIDIsSet(ref.blobId) || ref.size == 0 || (ref.removed && !fromServer) {
			return false
		}
		for earlier in refs[:index] {
			if earlier.blobId == ref.blobId {
				return false
			}
		}
		if sealed {
			if ref.sha256 != {} || len(ref.name) != 0 || len(ref.mediaType) != 0 {
				return false
			}
		} else if ref.sha256 == {} ||
		   !attachmentNameIsValid(ref.name) ||
		   !attachmentMediaTypeIsValid(ref.mediaType) {
			return false
		}
	}
	return true
}

// Whether a message's text is acceptable with this many attachments (D15): 1..
// CHAT_MESSAGE_MAX_BYTES bytes, or empty when the message has 1..ATTACHMENTS_PER_MESSAGE_MAX
// attachments.
messageContentLengthIsValid :: proc(contentLength: int, attachmentCount: int) -> bool {
	if contentLength > CHAT_MESSAGE_MAX_BYTES ||
	   attachmentCount < 0 ||
	   attachmentCount > ATTACHMENTS_PER_MESSAGE_MAX {
		return false
	}
	return contentLength > 0 || attachmentCount > 0
}

// ── Moderation (protocol 28, attachments plan F3, D22) ───────────────────────────────────

// Admins only, with no assignable permission: the server checks the admin role in the statement
// that reads or changes, and refuses anyone else with a ServerProtocolError.

// Most accounts ServerAdminAttachmentUsage lists, by stored bytes.
ATTACHMENT_USAGE_ACCOUNTS_MAX :: 100
// A removal's optional reason: at most this many bytes of UTF-8 with no control characters.
// The server logs it with the blob, the admin and the owner; it is never stored or sent on.
ATTACHMENT_REMOVE_REASON_MAX_BYTES :: 500

// What a removed file's card says, and the refusal of a download cut short by a removal
// (ServerAttachmentRefused). Clients may match it; never reword it.
ATTACHMENT_REMOVED_MESSAGE :: "Attachment removed by an admin"
ATTACHMENT_REMOVE_REASON_INVALID_MESSAGE ::
	"The reason must be at most 500 bytes, without control characters"

// ClientAdminAttachmentUsage: asks for ServerAdminAttachmentUsage.
ClientAdminAttachmentUsagePayload :: struct {}

// One account's stored attachments: bytes and blobs that are not Removed (uploads in progress
// count, since their declared size is reserved).
AttachmentAccountUsage :: struct {
	userId: int,
	bytes:  u64,
	count:  int,
}

// ServerAdminAttachmentUsage: usedBytes is every stored byte that is not a tombstone,
// capacityBytes HAYCHAT_ATTACHMENT_CAPACITY_BYTES (0 = no cap), freeBytes the free space on the
// blob directory's volume (freeBytesKnown false when the server could not read it), and
// accounts the top ATTACHMENT_USAGE_ACCOUNTS_MAX by bytes, largest first (owned once decoded).
ServerAdminAttachmentUsagePayload :: struct {
	usedBytes:      u64,
	capacityBytes:  u64,
	freeBytes:      u64,
	freeBytesKnown: bool,
	accounts:       [dynamic]AttachmentAccountUsage,
}

ServerAdminAttachmentUsagePayload_deinit :: proc(payload: ^ServerAdminAttachmentUsagePayload) {
	delete(payload.accounts)
	payload.accounts = nil
}

// ClientAdminRemoveAttachment: makes a Ready or Bound blob a Removed tombstone and deletes its
// file. The message stays, with every signed field, and lists the file as removed. Answered by
// ServerAdminActionResult{RemoveAttachment, userId = the owner, blobId}, or a
// ServerProtocolError ("Admin permission required", ATTACHMENT_NOT_FOUND_MESSAGE for an
// unknown, Uploading or already Removed blob). reason is optional (attachmentRemoveReasonIsValid)
// and owned once decoded.
ClientAdminRemoveAttachmentPayload :: struct {
	blobId: AttachmentBlobID,
	reason: string,
}

ClientAdminRemoveAttachmentPayload_deinit :: proc(payload: ^ClientAdminRemoveAttachmentPayload) {
	delete(payload.reason)
	payload.reason = ""
}

// ServerAttachmentRemoved: an admin removed blobId. It goes to every session of each account
// that may read the message: a room message's members who may read its history (From join
// members who joined after it get nothing), both sides of a direct message, and the owner of an
// unbound Ready blob. roomId names a room message's room; senderId and recipientId a direct
// message's two sides (senderId is the owner for a room message, and recipientId 0). An unbound
// blob names the conversation it was uploaded to.
ServerAttachmentRemovedPayload :: struct {
	blobId:      AttachmentBlobID,
	roomId:      int,
	senderId:    int,
	recipientId: int,
}

// A removal reason: 0..ATTACHMENT_REMOVE_REASON_MAX_BYTES bytes of valid UTF-8 with no control
// character (C0, DEL or C1), so it fits one log line.
attachmentRemoveReasonIsValid :: proc(reason: string) -> bool {
	if len(reason) > ATTACHMENT_REMOVE_REASON_MAX_BYTES || !utf8.valid_string(reason) {
		return false
	}
	for r in reason {
		if r < 0x20 || (r >= 0x7F && r <= 0x9F) {
			return false
		}
	}
	return true
}
