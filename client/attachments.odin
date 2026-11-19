package client

// Attachments on messages (protocol 27, docs/plan/2026-11-19-file-attachments.md F2, D12-D18).
//
// Uploading (the composer side, which F4's file chips drive): State_uploadAttachment checks the
// server's limits from ServerAuthSuccess (D18; ServerConnection.attachmentLimits), picks the
// conversation's encryption (an encrypted room, or a direct conversation that is or will be
// encrypted, uploads sealed; State_attachmentShouldEncrypt), names the file from its path and
// hands it to the transfer worker. State_popTransferEvent pops the worker's events and keeps
// every finished upload as an UploadedAttachment (State.attachmentUploads): its blob ID, the
// stored size and hash and, when sealed, the file key and the file's own size. Sending a message
// with attachments names those blob IDs (State_sendChannelChat, State_sendDirectMessageTo, the
// harness's --attach); the references go out signed (plaintext, v2 label) or inside the seal
// with only blob IDs and sizes outside. An upload is forgotten once this account's own message
// listing it comes back from the server.
//
// Receiving: every shown message keeps the files the client checked as MessageFile entries
// (RoomMessageEntry.files, DirectMessageEntry.files), which the harness prints and F4 draws:
// a plaintext message's from its references once the v2 signature verified, a sealed
// message's from the list inside the seal. A sealed message whose outer list (what the server
// bound) is not the inner one, or whose stored size does not fit the sealed file's layout, keeps
// no files and sets filesChanged ("This message's attachments were changed on the server").
//
// Downloading: State_downloadMessageAttachment downloads file index of a message into a path
// and has the worker check the stored size and hash (and decrypt) against what the message
// says; a failed check deletes the part file (common.ATTACHMENT_CHANGED_MESSAGE).
//
// Nothing here writes to disk but the file the user saved, and file keys never reach disk.

import "../common"
import "core:crypto"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:unicode/utf8"

// One file of a shown message, as the client checked it. name and mediaType are owned; key is
// set only for an encrypted file and wiped by MessageFile_deinit.
MessageFile :: struct {
	blobId:     common.AttachmentBlobID,
	storedSize: u64, // what the server stores and sends
	fileSize:   u64, // the file's own size (storedSize for a plaintext file)
	sha256:     common.AttachmentSHA256, // the stored blob's, from the signed or sealed message
	name:       string,
	mediaType:  string,
	encrypted:  bool,
	key:        common.AttachmentFileKey,
	removed:    bool, // F3: an admin removed the file (the server's tombstone flag)
}

MessageFile_deinit :: proc(file: ^MessageFile) {
	delete(file.name)
	delete(file.mediaType)
	crypto.zero_explicit(&file.key, size_of(file.key))
	file^ = {}
}

MessageFiles_deinit :: proc(files: ^[dynamic]MessageFile) {
	for &file in files {
		MessageFile_deinit(&file)
	}
	delete(files^)
	files^ = nil
}

// The files of a plaintext message whose v2 signature verified over refs (owned copies).
messageFilesFromPlain :: proc(refs: []common.AttachmentRef) -> [dynamic]MessageFile {
	if len(refs) == 0 {
		return nil
	}
	files := make([dynamic]MessageFile, 0, len(refs))
	for ref in refs {
		append(
			&files,
			MessageFile {
				blobId = ref.blobId,
				storedSize = ref.size,
				fileSize = ref.size,
				sha256 = ref.sha256,
				name = strings.clone(ref.name),
				mediaType = strings.clone(ref.mediaType),
				removed = ref.removed,
			},
		)
	}
	return files
}

// The files of an opened sealed message: inner is the list inside the seal (trusted, the
// sender's), outer what the server bound. They must name the same blobs in the same order, and
// each stored size must be the one the sealed file's size gives (D12); otherwise changed is
// true and there are no files. removed comes from the outer list.
messageFilesFromSealed :: proc(
	outer: []common.AttachmentRef,
	inner: []common.SealedAttachment,
) -> (
	files: [dynamic]MessageFile,
	changed: bool,
) {
	if len(outer) != len(inner) {
		return nil, true
	}
	for attachment, index in inner {
		layout, layoutOK := common.attachmentEncryptedLayout(attachment.size)
		if outer[index].blobId != attachment.blobId ||
		   !layoutOK ||
		   outer[index].size != layout.storedSize {
			return nil, true
		}
	}
	if len(inner) == 0 {
		return nil, false
	}
	files = make([dynamic]MessageFile, 0, len(inner))
	for attachment, index in inner {
		append(
			&files,
			MessageFile {
				blobId = attachment.blobId,
				storedSize = outer[index].size,
				fileSize = attachment.size,
				sha256 = attachment.sha256,
				name = strings.clone(attachment.name),
				mediaType = strings.clone(attachment.mediaType),
				encrypted = true,
				key = attachment.key,
				removed = outer[index].removed,
			},
		)
	}
	return files, false
}

// ── Uploads ──────────────────────────────────────────────────────

// A finished upload this client may send with a message. name and mediaType are owned; key is
// set for an encrypted upload and wiped by UploadedAttachment_deinit.
UploadedAttachment :: struct {
	serverID:        int,
	roomID:          int,
	recipientUserID: int,
	blobId:          common.AttachmentBlobID,
	encrypted:       bool,
	key:             common.AttachmentFileKey,
	fileSize:        u64,
	storedSize:      u64,
	sha256:          common.AttachmentSHA256,
	name:            string,
	mediaType:       string,
}

UploadedAttachment_deinit :: proc(upload: ^UploadedAttachment) {
	delete(upload.name)
	delete(upload.mediaType)
	crypto.zero_explicit(&upload.key, size_of(upload.key))
	upload^ = {}
}

// An upload the worker is running: what the message will need once it is done.
PendingAttachmentUpload :: struct {
	transferID:      int,
	serverID:        int,
	roomID:          int,
	recipientUserID: int,
	encrypted:       bool,
	blobId:          common.AttachmentBlobID,
	hasBlobId:       bool,
	name:            string, // owned
	mediaType:       string, // owned
}

State_attachmentsDeinit :: proc(state: ^State) {
	for &upload in state.attachmentUploads {
		UploadedAttachment_deinit(&upload)
	}
	delete(state.attachmentUploads)
	state.attachmentUploads = nil
	for &pending in state.attachmentPendingUploads {
		delete(pending.name)
		delete(pending.mediaType)
	}
	delete(state.attachmentPendingUploads)
	state.attachmentPendingUploads = nil
}

// The server's limits from sign-in, the stored bytes counted up by this client's own uploads
// since (D18). Zero (disabled) when the server is not connected.
State_attachmentLimits :: proc(state: ^State, serverID: int) -> common.AttachmentLimits {
	index := State_serverConnectionIndex(state^, serverID)
	if index < 0 || state.serverConnections[index].status != .Established {
		return {}
	}
	return state.serverConnections[index].attachmentLimits
}

// Whether a file for this conversation is uploaded sealed: an encrypted room's are, and a direct
// conversation's are when its messages are or will be encrypted (not through the plaintext
// switch, and not while encryption is impossible).
State_attachmentShouldEncrypt :: proc(
	state: ^State,
	serverID, roomID, recipientUserID: int,
) -> bool {
	if roomID > 0 {
		return State_roomIsEncrypted(state, serverID, roomID)
	}
	conversation := ServerDirectCache_conversationCache(
		State_serverDirectCache(state, serverID),
		recipientUserID,
	)
	mode := directSendMode(
		State_e2eePeerKeyInfo(state, serverID, recipientUserID),
		conversation.fallbackOn,
	)
	return mode == .Encrypt || mode == .Queue
}

// The name a file is attached under: its path's last element, made to pass
// attachmentNameIsValid (control characters and separators become '_', at most
// ATTACHMENT_NAME_MAX_BYTES bytes cut at a character boundary). Temp.
attachmentNameFromPath :: proc(path: string) -> string {
	base := filepath.base(path)
	builder := strings.builder_make(context.temp_allocator)
	for r in base {
		replaced := r
		if r < 0x20 || (r >= 0x7F && r <= 0x9F) || r == '/' || r == '\\' || r == utf8.RUNE_ERROR {
			replaced = '_'
		}
		bytes, width := utf8.encode_rune(replaced)
		if strings.builder_len(builder) + width > common.ATTACHMENT_NAME_MAX_BYTES {
			break
		}
		strings.write_bytes(&builder, bytes[:width])
	}
	name := strings.to_string(builder)
	if !common.attachmentNameIsValid(name) {
		return "file"
	}
	return name
}

@(private = "file")
ATTACHMENT_MEDIA_TYPES := [?][2]string {
	{".txt", "text/plain"},
	{".md", "text/markdown"},
	{".csv", "text/csv"},
	{".html", "text/html"},
	{".json", "application/json"},
	{".pdf", "application/pdf"},
	{".zip", "application/zip"},
	{".gz", "application/gzip"},
	{".png", "image/png"},
	{".jpg", "image/jpeg"},
	{".jpeg", "image/jpeg"},
	{".gif", "image/gif"},
	{".webp", "image/webp"},
	{".svg", "image/svg+xml"},
	{".mp3", "audio/mpeg"},
	{".ogg", "audio/ogg"},
	{".opus", "audio/opus"},
	{".wav", "audio/wav"},
	{".mp4", "video/mp4"},
	{".webm", "video/webm"},
}

// The media type a file is labelled with, from its extension (D16: only a label; never
// trusted for anything else).
attachmentMediaTypeFor :: proc(name: string) -> string {
	extension := strings.to_lower(filepath.ext(name), context.temp_allocator)
	for entry in ATTACHMENT_MEDIA_TYPES {
		if entry[0] == extension {
			return entry[1]
		}
	}
	return common.ATTACHMENT_DEFAULT_MEDIA_TYPE
}

// Starts uploading path to a room (roomID) or a direct conversation (recipientUserID), sealed
// when the conversation is encrypted. Refuses early what the server's limits would refuse
// (D18). Returns the transfer ID its events carry, or why it cannot start (static or temp).
State_uploadAttachment :: proc(
	state: ^State,
	serverID, roomID, recipientUserID: int,
	path: string,
) -> (
	transferID: int,
	errorMessage: string,
) {
	if (roomID > 0) == (recipientUserID > 0) {
		return 0, common.ATTACHMENT_INVALID_REQUEST_MESSAGE
	}
	limits := State_attachmentLimits(state, serverID)
	if !limits.enabled {
		if State_isServerConnected(state, serverID) {
			return 0, common.ATTACHMENTS_DISABLED_MESSAGE
		}
		return 0, NOT_CONNECTED_MESSAGE
	}
	encrypted := State_attachmentShouldEncrypt(state, serverID, roomID, recipientUserID)
	if recipientUserID > 0 && !encrypted {
		conversation := ServerDirectCache_conversationCache(
			State_serverDirectCache(state, serverID),
			recipientUserID,
		)
		if !conversation.fallbackOn {
			info := State_e2eePeerKeyInfo(state, serverID, recipientUserID)
			return 0, e2eeKeyStateText(info, State_e2eeUserName(state, serverID, recipientUserID))
		}
	}
	file, openErr := os.open(path, {.Read})
	if openErr != nil {
		return 0, "Cannot read the file"
	}
	size, sizeErr := os.file_size(file)
	os.close(file)
	if sizeErr != nil || size < 0 {
		return 0, "Cannot read the file"
	}
	stored := u64(size)
	if encrypted {
		layout, layoutOK := common.attachmentEncryptedLayout(u64(size))
		if !layoutOK {
			return 0, common.ATTACHMENT_TOO_LARGE_MESSAGE
		}
		stored = layout.storedSize
	} else if size == 0 {
		return 0, "The file is empty"
	}
	if stored > limits.maxBytes {
		return 0, common.ATTACHMENT_TOO_LARGE_MESSAGE
	}
	if limits.quotaBytes > 0 && limits.usedBytes + stored > limits.quotaBytes {
		return 0, common.ATTACHMENT_QUOTA_MESSAGE
	}
	worker := State_transferWorker(state)
	if worker == nil {
		return 0, NOT_CONNECTED_MESSAGE
	}
	name := attachmentNameFromPath(path)
	transferID = ClientTransferWorker_upload(
		worker,
		serverID,
		roomID,
		recipientUserID,
		path,
		encrypted,
	)
	append(
		&state.attachmentPendingUploads,
		PendingAttachmentUpload {
			transferID = transferID,
			serverID = serverID,
			roomID = roomID,
			recipientUserID = recipientUserID,
			encrypted = encrypted,
			name = strings.clone(name),
			mediaType = strings.clone(attachmentMediaTypeFor(name)),
		},
	)
	return transferID, ""
}

// Pops the transfer worker's next event for the caller (who owns it), and keeps a finished
// upload (State.attachmentUploads) with what its message will need.
State_popTransferEvent :: proc(state: ^State) -> (event: ClientTransferEvent, ok: bool) {
	event, ok = ClientTransferWorker_popEvent(state.transferWorker)
	if !ok || event.direction != .Upload {
		return
	}
	pendingIndex := -1
	for pending, index in state.attachmentPendingUploads {
		if pending.serverID != event.serverID {
			continue
		}
		if pending.transferID == event.id ||
		   (event.hasBlobId && pending.hasBlobId && pending.blobId == event.blobId) {
			pendingIndex = index
			break
		}
	}
	if pendingIndex < 0 {
		return
	}
	pending := &state.attachmentPendingUploads[pendingIndex]
	if event.hasBlobId && !pending.hasBlobId {
		pending.blobId = event.blobId
		pending.hasBlobId = true
	}
	// A resume runs under a new transfer ID.
	pending.transferID = event.id
	if event.kind != .Done {
		return
	}
	upload := UploadedAttachment {
		serverID        = pending.serverID,
		roomID          = pending.roomID,
		recipientUserID = pending.recipientUserID,
		blobId          = event.blobId,
		encrypted       = event.encrypted,
		key             = event.key,
		fileSize        = event.fileSize,
		storedSize      = event.total,
		sha256          = event.sha256,
		name            = pending.name,
		mediaType       = pending.mediaType,
	}
	append(&state.attachmentUploads, upload)
	ordered_remove(&state.attachmentPendingUploads, pendingIndex)
	if index := State_serverConnectionIndex(state^, event.serverID); index >= 0 {
		state.serverConnections[index].attachmentLimits.usedBytes += event.total
	}
	return
}

// The finished upload blobId on serverID, or nil. Borrowed from State.
State_findUploadedAttachment :: proc(
	state: ^State,
	serverID: int,
	blobId: common.AttachmentBlobID,
) -> ^UploadedAttachment {
	for &upload in state.attachmentUploads {
		if upload.serverID == serverID && upload.blobId == blobId {
			return &upload
		}
	}
	return nil
}

// Forgets the uploads a message of this account listed: the server bound them.
State_attachmentsNoteBound :: proc(state: ^State, serverID: int, refs: []common.AttachmentRef) {
	for ref in refs {
		for index := len(state.attachmentUploads) - 1; index >= 0; index -= 1 {
			upload := &state.attachmentUploads[index]
			if upload.serverID == serverID && upload.blobId == ref.blobId {
				UploadedAttachment_deinit(upload)
				ordered_remove(&state.attachmentUploads, index)
			}
		}
	}
}

// What a message to a room (roomID) or a direct conversation (recipientUserID) lists for the
// uploads blobIds, which must be this client's finished uploads to that conversation with the
// message's encryption: complete references for a plaintext message, blob IDs and sizes plus
// the sealed entries (with their file keys) for a sealed one. Everything is temp; the caller
// wipes the sealed entries' keys. errorMessage (static) says why they cannot be sent.
State_attachmentsForMessage :: proc(
	state: ^State,
	serverID, roomID, recipientUserID: int,
	blobIds: []common.AttachmentBlobID,
	sealed: bool,
) -> (
	refs: []common.AttachmentRef,
	entries: []common.SealedAttachment,
	errorMessage: string,
) {
	if len(blobIds) == 0 {
		return nil, nil, ""
	}
	if len(blobIds) > common.ATTACHMENTS_PER_MESSAGE_MAX {
		return nil, nil, "A message can carry at most 4 files"
	}
	refList := make([]common.AttachmentRef, len(blobIds), context.temp_allocator)
	entryList := make([]common.SealedAttachment, sealed ? len(blobIds) : 0, context.temp_allocator)
	for blobId, index in blobIds {
		for earlier in blobIds[:index] {
			if earlier == blobId {
				return nil, nil, "The same file is attached twice"
			}
		}
		upload := State_findUploadedAttachment(state, serverID, blobId)
		if upload == nil ||
		   upload.roomID != max(roomID, 0) ||
		   upload.recipientUserID != max(recipientUserID, 0) {
			return nil, nil, "That file was not uploaded to this conversation"
		}
		if upload.encrypted != sealed {
			if sealed {
				return nil, nil, "That file was uploaded unencrypted; upload it again"
			}
			return nil, nil, "That file was uploaded encrypted; upload it again"
		}
		refList[index] = common.AttachmentRef {
			blobId = upload.blobId,
			size   = upload.storedSize,
		}
		if sealed {
			entryList[index] = common.SealedAttachment {
				blobId    = upload.blobId,
				key       = upload.key,
				sha256    = upload.sha256,
				size      = upload.fileSize,
				name      = upload.name,
				mediaType = upload.mediaType,
			}
		} else {
			refList[index].sha256 = upload.sha256
			refList[index].name = upload.name
			refList[index].mediaType = upload.mediaType
		}
	}
	return refList, entryList, ""
}

// Wipes the file keys of State_attachmentsForMessage's sealed entries.
attachmentEntriesWipe :: proc(entries: []common.SealedAttachment) {
	for &entry in entries {
		crypto.zero_explicit(&entry.key, size_of(entry.key))
	}
}

// ── Downloads ────────────────────────────────────────────────────

// The files of cached message messageID in roomID (or, with roomID 0, in the direct
// conversation with peerUserID), and whether its attachment list was changed on the server.
// Borrowed from State; nil when the message is not cached or not shown.
State_messageFiles :: proc(
	state: ^State,
	serverID, roomID, peerUserID, messageID: int,
) -> (
	files: []MessageFile,
	changed: bool,
	found: bool,
) {
	if roomID > 0 {
		cacheIndex := State_serverRoomCacheIndex(state^, serverID)
		if cacheIndex < 0 {
			return nil, false, false
		}
		cache := &state.server_room_caches[cacheIndex]
		roomIndex := ServerRoomCache_roomCacheIndex(cache^, roomID)
		if roomIndex < 0 {
			return nil, false, false
		}
		for &entry in cache.roomCaches[roomIndex].messages {
			if entry.id == messageID {
				if !roomMessageShown(entry.security) || entry.security.protection == .Pending {
					return nil, false, false
				}
				return entry.files[:], entry.filesChanged, true
			}
		}
		return nil, false, false
	}
	cache := State_serverDirectCache(state, serverID)
	for &conversation in cache.caches {
		if conversation.peerUserID != peerUserID {
			continue
		}
		for &entry in conversation.messages {
			if entry.id == messageID {
				if !directMessageShown(entry.security) || entry.security.protection == .Pending {
					return nil, false, false
				}
				return entry.files[:], entry.filesChanged, true
			}
		}
	}
	return nil, false, false
}

// Downloads file index of a cached message (see State_messageFiles) into path, checked against
// what the message says and decrypted when it is encrypted. Returns the transfer ID, or why not
// (static).
State_downloadMessageAttachment :: proc(
	state: ^State,
	serverID, roomID, peerUserID, messageID, index: int,
	path: string,
) -> (
	transferID: int,
	errorMessage: string,
) {
	files, changed, found := State_messageFiles(state, serverID, roomID, peerUserID, messageID)
	if !found {
		return 0, "Unknown message"
	}
	if changed {
		return 0, common.ATTACHMENT_LIST_CHANGED_MESSAGE
	}
	if index < 0 || index >= len(files) {
		return 0, "The message has no such file"
	}
	file := files[index]
	if file.removed {
		return 0, "Attachment removed by an admin"
	}
	worker := State_transferWorker(state)
	if worker == nil {
		return 0, NOT_CONNECTED_MESSAGE
	}
	transferID = ClientTransferWorker_downloadVerified(
		worker,
		serverID,
		file.blobId,
		path,
		ClientTransferExpect {
			storedSize = file.storedSize,
			sha256 = file.sha256,
			encrypted = file.encrypted,
			key = file.key,
			fileSize = file.fileSize,
		},
	)
	return transferID, ""
}

// What opening a message says about its files (openDirectMessageContent, room_chains.odin).
MessageFilesResult :: struct {
	files:   [dynamic]MessageFile,
	changed: bool,
}

// A message's text with a line per checked file after it ("Attachment: name (size)"), or the
// changed-list sentence; text unchanged without files. Until F4 draws file cards this keeps a
// message with only files from showing nothing. allocator holds the result.
messageTextWithFiles :: proc(
	text: string,
	files: []MessageFile,
	changed: bool,
	allocator := context.temp_allocator,
) -> string {
	if len(files) == 0 && !changed {
		return text
	}
	builder := strings.builder_make(allocator)
	strings.write_string(&builder, text)
	if changed {
		if len(text) > 0 {
			strings.write_byte(&builder, '\n')
		}
		strings.write_string(&builder, common.ATTACHMENT_LIST_CHANGED_MESSAGE)
	}
	for file, index in files {
		if len(text) > 0 || index > 0 {
			strings.write_byte(&builder, '\n')
		}
		strings.write_string(&builder, "Attachment: ")
		strings.write_string(&builder, file.name)
		strings.write_string(&builder, " (")
		strings.write_string(&builder, attachmentSizeText(file.fileSize))
		strings.write_byte(&builder, ')')
		if file.removed {
			strings.write_string(&builder, ", removed by an admin")
		}
	}
	return strings.to_string(builder)
}

// A size for people: bytes, KB, MB or GB with one decimal (temp).
attachmentSizeText :: proc(size: u64) -> string {
	switch {
	case size < 1024:
		return fmt.tprintf("%d bytes", size)
	case size < 1024 * 1024:
		return fmt.tprintf("%.1f KB", f64(size) / 1024)
	case size < 1024 * 1024 * 1024:
		return fmt.tprintf("%.1f MB", f64(size) / (1024 * 1024))
	}
	return fmt.tprintf("%.1f GB", f64(size) / (1024 * 1024 * 1024))
}
