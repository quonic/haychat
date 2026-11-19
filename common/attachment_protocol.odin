package common

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
	// May the requester download the blob? F1: only its owner, and only once it is Ready or
	// Bound. F2 replaces the check with D10's.
	DownloadCheck,
	// Deletes the rows the sweeper may delete (stale uploads, unbound blobs past the pending
	// window, unbound tombstones, bound blobs whose message is gone; never a row younger than an
	// hour) and returns their blob IDs and states, so the storage worker deletes their files.
	Sweep,
	// The state of each blob ID in blobIds that has a row (the startup orphan scan).
	Known,
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
	// Sweep: the deleted rows. Known: the rows found. Owned.
	blobs:    [dynamic]DatabaseAttachmentBlob,
}
