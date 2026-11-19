package client

// The attachments UI (attachments plan F4, D18, D19, D22): composer chips, the send gate, file
// cards' saves, the Remove attachment confirmation and Admin → Storage. Everything here is State
// and pure view models; the drawing is in view_attachments.odin and the native dialogs in
// file_dialog.odin.
//
// - Composer: State_composerAddFile starts an upload for the conversation on screen (refused at
//   once, as a failed chip with the reason, when it is too large or over the quota) and adds a
//   ComposerFile chip; State_pollTransfers moves the transfer worker's events onto the chips
//   (progress, done, the error), and State_composerRemoveFile cancels an upload or forgets a
//   finished one (the server sweeps the unbound blob). State_composerSend sends the draft with
//   the chips' blob IDs, refused with the gate's reason while an upload runs, failed, or was
//   made with other encryption than the conversation now has (the DM "Send without encryption"
//   switch); the chips go once the message went out or was queued.
// - File cards: buildFileCardViews draws a message's files from State_messageFiles and the
//   save each one has (AttachmentSave): Save… asks where (State_beginAttachmentSave, then the
//   dialog's answer State_attachmentSaveChosen), the download goes through PATH.part and is
//   checked, and the card shows its progress, Cancel, "Saved as NAME" or the failure.
// - Remove attachment (admins): State_openAttachmentRemoveDialog opens a confirmation with an
//   optional reason; its answer is State.adminRequest (action RemoveAttachment, blobID).
// - Admin → Storage: buildAdminStorageView from State_attachmentUsage, names from the user list.
//
// The client never opens, runs or previews a file (D19): there is no Open button and no image
// decoding.

import "../common"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:unicode/utf8"

ATTACHMENT_UNAVAILABLE_TEXT :: "Attachment unavailable"
ATTACHMENT_FILES_MAX_TEXT :: "A message can carry at most 4 files"
ATTACHMENT_SAVE_CHOOSING_TEXT :: "Choose where to save it…"
ATTACHMENT_REMOVE_TITLE :: "Remove attachment"

// ── Composer chips ───────────────────────────────────────────────

ComposerFileStatus :: enum u8 {
	Uploading,
	Ready, // uploaded; the message can name it
	Failed, // refused before the upload or failed during it (error says why)
}

// One file in a conversation's draft. name and error are owned.
ComposerFile :: struct {
	serverID:   int,
	roomID:     int, // a room's draft, or 0
	peerUserID: int, // a direct conversation's draft, or 0
	transferID: int, // 0 for a file refused before its upload
	name:       string,
	fileSize:   u64, // the file's own size, 0 when it could not be read
	bytes:      u64, // stored bytes the server acknowledged
	total:      u64, // stored bytes to upload
	status:     ComposerFileStatus,
	error:      string,
	blobId:     common.AttachmentBlobID,
	hasBlobId:  bool,
	encrypted:  bool, // uploaded sealed
}

ComposerFile_deinit :: proc(file: ^ComposerFile) {
	delete(file.name)
	delete(file.error)
	file^ = {}
}

State_attachmentUIDeinit :: proc(state: ^State) {
	for &file in state.composerFiles {
		ComposerFile_deinit(&file)
	}
	delete(state.composerFiles)
	state.composerFiles = nil
	for &save in state.attachmentSaves {
		AttachmentSave_deinit(&save)
	}
	delete(state.attachmentSaves)
	state.attachmentSaves = nil
	AttachmentRemoveDialog_deinit(&state.attachmentRemoveDialog)
	if FileDialogQueue_destroy(state.fileDialogs) {
		state.fileDialogs = nil
	}
}

// The queue the native dialogs and automation answer into, made on first use.
State_fileDialogs :: proc(state: ^State) -> ^FileDialogQueue {
	if state.fileDialogs == nil {
		state.fileDialogs = FileDialogQueue_create()
	}
	return state.fileDialogs
}

// The chips of one conversation's draft, in the order they were added (borrowed; valid until
// the chips change).
State_composerFiles :: proc(
	state: ^State,
	serverID, roomID, peerUserID: int,
	allocator := context.temp_allocator,
) -> []^ComposerFile {
	files := make([dynamic]^ComposerFile, 0, common.ATTACHMENTS_PER_MESSAGE_MAX, allocator)
	for &file in state.composerFiles {
		if file.serverID == serverID &&
		   file.roomID == max(roomID, 0) &&
		   file.peerUserID == max(peerUserID, 0) {
			append(&files, &file)
		}
	}
	return files[:]
}

// The room or direct conversation on screen, whose composer a picked or dropped file goes to.
State_currentComposer :: proc(state: ^State) -> (serverID, roomID, peerUserID: int, ok: bool) {
	if state.settingsOpen ||
	   State_serverSettingsVisible(state) ||
	   State_roomEditorVisible(state) ||
	   State_signUpVisible(state) {
		return
	}
	serverID = state.selected_server_id
	if state.selected_dm_peer_id != 0 {
		return serverID, 0, state.selected_dm_peer_id, serverID != 0
	}
	if state.selected_channel_id == 0 {
		return
	}
	return serverID, state.selected_channel_id, 0, serverID != 0
}

// Why files cannot be attached in this conversation now (static or temp), or "".
State_composerAttachBlocked :: proc(state: ^State, serverID, roomID, peerUserID: int) -> string {
	limits := State_attachmentLimits(state, serverID)
	if !limits.enabled {
		if State_isServerConnected(state, serverID) {
			return common.ATTACHMENTS_DISABLED_MESSAGE
		}
		return NOT_CONNECTED_MESSAGE
	}
	if roomID > 0 {
		if !State_roomAllowsChat(state, serverID, roomID) {
			return ROOM_VOICE_ONLY_NOTE
		}
		if !State_hasRoomPermission(state, serverID, roomID, .SendMessages) {
			return ROOM_SEND_NOT_PERMITTED_NOTE
		}
		if !State_hasRoomPermission(state, serverID, roomID, .AttachFiles) {
			return common.ATTACHMENT_SEND_NOT_PERMITTED_MESSAGE
		}
	}
	if len(State_composerFiles(state, serverID, roomID, peerUserID)) >=
	   common.ATTACHMENTS_PER_MESSAGE_MAX {
		return ATTACHMENT_FILES_MAX_TEXT
	}
	return ""
}

// Adds path to a conversation's draft and starts its upload. A file the server's limits refuse
// (too large, over the quota) or that cannot be read becomes a failed chip with the reason; a
// file that cannot be attached here at all (no AttachFiles, already four files, attachments
// off) adds nothing, and the reason is returned (static or temp) for the status line.
State_composerAddFile :: proc(
	state: ^State,
	serverID, roomID, peerUserID: int,
	path: string,
) -> string {
	if (roomID > 0) == (peerUserID > 0) {
		return common.ATTACHMENT_INVALID_REQUEST_MESSAGE
	}
	if blocked := State_composerAttachBlocked(state, serverID, roomID, peerUserID);
	   len(blocked) > 0 {
		return blocked
	}
	file := ComposerFile {
		serverID   = serverID,
		roomID     = roomID,
		peerUserID = peerUserID,
		name       = strings.clone(attachmentNameFromPath(path)),
		status     = .Uploading,
	}
	if handle, err := os.open(path, {.Read}); err == nil {
		if size, sizeErr := os.file_size(handle); sizeErr == nil && size > 0 {
			file.fileSize = u64(size)
		}
		os.close(handle)
	}
	transferID, errorMessage := State_uploadAttachment(state, serverID, roomID, peerUserID, path)
	if len(errorMessage) > 0 {
		file.status = .Failed
		file.error = strings.clone(errorMessage)
	} else {
		file.transferID = transferID
		file.encrypted = State_attachmentShouldEncrypt(state, serverID, roomID, peerUserID)
		file.total = file.fileSize
		if file.encrypted {
			if layout, ok := common.attachmentEncryptedLayout(file.fileSize); ok {
				file.total = layout.storedSize
			}
		}
	}
	append(&state.composerFiles, file)
	return ""
}

// Removes chip index (of State_composerFiles) from the draft: an upload still running is
// cancelled, a finished one is forgotten (the server sweeps its unbound blob).
State_composerRemoveFile :: proc(state: ^State, serverID, roomID, peerUserID, index: int) {
	files := State_composerFiles(state, serverID, roomID, peerUserID)
	if index < 0 || index >= len(files) {
		return
	}
	file := files[index]
	switch file.status {
	case .Uploading:
		if worker := state.transferWorker; worker != nil && file.transferID != 0 {
			ClientTransferWorker_cancelTransfer(worker, serverID, file.transferID)
		}
		for pendingIndex := len(state.attachmentPendingUploads) - 1;
		    pendingIndex >= 0;
		    pendingIndex -= 1 {
			pending := &state.attachmentPendingUploads[pendingIndex]
			if pending.serverID == serverID && pending.transferID == file.transferID {
				delete(pending.name)
				delete(pending.mediaType)
				ordered_remove(&state.attachmentPendingUploads, pendingIndex)
			}
		}
	case .Ready:
		State_forgetUploadedAttachment(state, serverID, file.blobId)
	case .Failed:
	}
	for &candidate, candidateIndex in state.composerFiles {
		if &candidate == file {
			ComposerFile_deinit(&candidate)
			ordered_remove(&state.composerFiles, candidateIndex)
			break
		}
	}
}

// Drops a finished upload this client will not send.
State_forgetUploadedAttachment :: proc(
	state: ^State,
	serverID: int,
	blobId: common.AttachmentBlobID,
) {
	for index := len(state.attachmentUploads) - 1; index >= 0; index -= 1 {
		upload := &state.attachmentUploads[index]
		if upload.serverID == serverID && upload.blobId == blobId {
			UploadedAttachment_deinit(upload)
			ordered_remove(&state.attachmentUploads, index)
		}
	}
}

// Drops every chip of a conversation's draft without touching the uploads (a sent message
// names them; the server binds them).
@(private = "file")
State_composerClearFiles :: proc(state: ^State, serverID, roomID, peerUserID: int) {
	for index := len(state.composerFiles) - 1; index >= 0; index -= 1 {
		file := &state.composerFiles[index]
		if file.serverID == serverID &&
		   file.roomID == max(roomID, 0) &&
		   file.peerUserID == max(peerUserID, 0) {
			ComposerFile_deinit(file)
			ordered_remove(&state.composerFiles, index)
		}
	}
}

// Whether the draft's files keep Send disabled, and the sentence that says why (temp or
// static). encryptNow is whether the conversation's messages are sealed now: a file uploaded
// the other way cannot go with them.
composerSendGate :: proc(files: []^ComposerFile, encryptNow: bool) -> (blocked: bool, reason: string) {
	uploading, failed, mismatched := 0, 0, 0
	for file in files {
		switch file.status {
		case .Uploading:
			uploading += 1
		case .Failed:
			failed += 1
		case .Ready:
			if file.encrypted != encryptNow {
				mismatched += 1
			}
		}
	}
	switch {
	case uploading == 1:
		return true, "Waiting for 1 upload to finish…"
	case uploading > 1:
		return true, fmt.tprintf("Waiting for %d uploads to finish…", uploading)
	case failed == 1:
		return true, "Remove the file that could not be uploaded to send"
	case failed > 1:
		return true, "Remove the files that could not be uploaded to send"
	case mismatched > 0 && encryptNow:
		return true, "A file was uploaded unencrypted; remove it and attach it again"
	case mismatched > 0:
		return true, "A file was uploaded encrypted; remove it and attach it again"
	}
	return false, ""
}

// The gate of one conversation's draft (see composerSendGate).
State_composerSendGate :: proc(
	state: ^State,
	serverID, roomID, peerUserID: int,
) -> (
	blocked: bool,
	reason: string,
) {
	files := State_composerFiles(state, serverID, roomID, peerUserID)
	if len(files) == 0 {
		return false, ""
	}
	encryptNow := State_attachmentShouldEncrypt(state, serverID, roomID, peerUserID)
	return composerSendGate(files, encryptNow)
}

// Sends the conversation's draft with its files (Enter, or the Send button). Refused with the
// gate's reason while a file keeps it shut; the chips go once the message went out or was
// queued. roomID must be the selected room (State_sendChannelChat sends the selected room's
// draft); a direct conversation is named by peerUserID.
State_composerSend :: proc(state: ^State, serverID, roomID, peerUserID: int) -> bool {
	if blocked, reason := State_composerSendGate(state, serverID, roomID, peerUserID); blocked {
		State_setChatStatus(state, reason)
		return false
	}
	files := State_composerFiles(state, serverID, roomID, peerUserID)
	blobIds := make([dynamic]common.AttachmentBlobID, 0, len(files), context.temp_allocator)
	for file in files {
		append(&blobIds, file.blobId)
	}
	sent := false
	if peerUserID > 0 {
		sent = State_sendDirectMessageTo(state, serverID, peerUserID, blobIds[:])
	} else {
		sent = State_sendChannelChat(state, attachments = blobIds[:])
	}
	if sent {
		State_composerClearFiles(state, serverID, roomID, peerUserID)
	}
	return sent
}

// ── Saves ────────────────────────────────────────────────────────

// File index of message messageID in a room (kind Room, conversationID the room) or a direct
// conversation (kind Direct, conversationID the peer).
AttachmentFileRef :: struct {
	serverID:       int,
	kind:           common.ReadMarkerKind,
	conversationID: int,
	messageID:      int,
	index:          int,
}

@(private = "file")
attachmentRefRoomPeer :: proc(ref: AttachmentFileRef) -> (roomID, peerUserID: int) {
	if ref.kind == .Room {
		return ref.conversationID, 0
	}
	return 0, ref.conversationID
}

// The file ref names (borrowed from State), and whether its message lists it.
State_attachmentFile :: proc(state: ^State, ref: AttachmentFileRef) -> (^MessageFile, bool) {
	roomID, peerUserID := attachmentRefRoomPeer(ref)
	files, changed, found := State_messageFiles(
		state,
		ref.serverID,
		roomID,
		peerUserID,
		ref.messageID,
	)
	if !found || changed || ref.index < 0 || ref.index >= len(files) {
		return nil, false
	}
	return &files[ref.index], true
}

AttachmentSaveStatus :: enum u8 {
	Choosing, // the save dialog is open
	Saving,
	Saved,
	Failed,
}

// The last save of one file of a message. path and error are owned.
AttachmentSave :: struct {
	file:       AttachmentFileRef,
	blobId:     common.AttachmentBlobID,
	transferID: int,
	status:     AttachmentSaveStatus,
	bytes:      u64,
	total:      u64,
	path:       string,
	error:      string,
	cancelling: bool,
}

AttachmentSave_deinit :: proc(save: ^AttachmentSave) {
	delete(save.path)
	delete(save.error)
	save^ = {}
}

@(private = "file")
State_attachmentSaveIndex :: proc(state: ^State, ref: AttachmentFileRef) -> int {
	for save, index in state.attachmentSaves {
		if save.file == ref {
			return index
		}
	}
	return -1
}

// The save of ref's file, or nil (borrowed).
State_attachmentSave :: proc(state: ^State, ref: AttachmentFileRef) -> ^AttachmentSave {
	if index := State_attachmentSaveIndex(state, ref); index >= 0 {
		return &state.attachmentSaves[index]
	}
	return nil
}

@(private = "file")
State_dropAttachmentSave :: proc(state: ^State, ref: AttachmentFileRef) {
	if index := State_attachmentSaveIndex(state, ref); index >= 0 {
		AttachmentSave_deinit(&state.attachmentSaves[index])
		ordered_remove(&state.attachmentSaves, index)
	}
}

// The name a saved file is offered under (D19): the attachment's name without path separators,
// control characters or characters Windows refuses, without leading dots or trailing dots and
// spaces, never a Windows reserved device name, at most 255 bytes. Temp.
attachmentSuggestedSaveName :: proc(name: string) -> string {
	builder := strings.builder_make(context.temp_allocator)
	for r in name {
		replaced := r
		switch {
		case r < 0x20 || (r >= 0x7F && r <= 0x9F) || r == utf8.RUNE_ERROR:
			replaced = '_'
		case strings.contains_rune("/\\:*?\"<>|", r):
			replaced = '_'
		}
		bytes, width := utf8.encode_rune(replaced)
		if strings.builder_len(builder) + width > common.ATTACHMENT_NAME_MAX_BYTES {
			break
		}
		strings.write_bytes(&builder, bytes[:width])
	}
	result := strings.to_string(builder)
	result = strings.trim_left(result, ". ")
	result = strings.trim_right(result, ". ")
	if len(result) == 0 {
		return "attachment"
	}
	stem := result
	if dot := strings.index_byte(result, '.'); dot >= 0 {
		stem = result[:dot]
	}
	stem = strings.trim_right(stem, " ")
	if attachmentIsWindowsReservedName(stem) {
		return strings.concatenate({"_", result}, context.temp_allocator)
	}
	return result
}

@(private = "file")
attachmentIsWindowsReservedName :: proc(stem: string) -> bool {
	for reserved in ([?]string{"CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$"}) {
		if strings.equal_fold(stem, reserved) {
			return true
		}
	}
	if len(stem) == 4 && stem[3] >= '0' && stem[3] <= '9' {
		prefix := stem[:3]
		return strings.equal_fold(prefix, "COM") || strings.equal_fold(prefix, "LPT")
	}
	return false
}

// Save… on a card: checks the file can be saved, records that the dialog is open, and returns
// the name to suggest (temp). errorMessage (static) says why not.
State_beginAttachmentSave :: proc(
	state: ^State,
	ref: AttachmentFileRef,
) -> (
	suggestedName: string,
	errorMessage: string,
) {
	file, ok := State_attachmentFile(state, ref)
	if !ok {
		return "", ATTACHMENT_UNAVAILABLE_TEXT
	}
	if file.removed {
		return "", common.ATTACHMENT_REMOVED_MESSAGE
	}
	if save := State_attachmentSave(state, ref); save != nil {
		if save.status == .Saving || save.status == .Choosing {
			return "", "This file is already being saved"
		}
		State_dropAttachmentSave(state, ref)
	}
	append(&state.attachmentSaves, AttachmentSave{file = ref, blobId = file.blobId})
	return attachmentSuggestedSaveName(file.name), ""
}

// The save dialog answered with path: the download starts (through PATH.part, checked against
// the message). A save that cannot start shows why on its card.
State_attachmentSaveChosen :: proc(state: ^State, ref: AttachmentFileRef, path: string) {
	save := State_attachmentSave(state, ref)
	if save == nil {
		return
	}
	roomID, peerUserID := attachmentRefRoomPeer(ref)
	transferID, errorMessage := State_downloadMessageAttachment(
		state,
		ref.serverID,
		roomID,
		peerUserID,
		ref.messageID,
		ref.index,
		path,
	)
	save = State_attachmentSave(state, ref)
	delete(save.path)
	save.path = strings.clone(path)
	if len(errorMessage) > 0 {
		save.status = .Failed
		delete(save.error)
		save.error = strings.clone(attachmentSaveErrorText(errorMessage))
		return
	}
	save.transferID = transferID
	save.status = .Saving
}

// The save dialog was closed without a choice, or could not open (errorMessage).
State_attachmentSaveDialogClosed :: proc(
	state: ^State,
	ref: AttachmentFileRef,
	errorMessage := "",
) {
	save := State_attachmentSave(state, ref)
	if save == nil || save.status != .Choosing {
		return
	}
	if len(errorMessage) == 0 {
		State_dropAttachmentSave(state, ref)
		return
	}
	save.status = .Failed
	delete(save.error)
	save.error = strings.clone(errorMessage)
}

// Cancel on a card that is saving: the download stops and its part file goes.
State_cancelAttachmentSave :: proc(state: ^State, ref: AttachmentFileRef) {
	save := State_attachmentSave(state, ref)
	if save == nil || save.status != .Saving {
		return
	}
	save.cancelling = true
	if worker := state.transferWorker; worker != nil && save.transferID != 0 {
		ClientTransferWorker_cancelTransfer(worker, ref.serverID, save.transferID)
	} else {
		State_dropAttachmentSave(state, ref)
	}
}

// What a card says about a failed save: the D19/D12 sentences as they are, "Attachment
// unavailable" for a file the server cannot find, and the worker's other reasons with a
// capital letter (temp or static).
attachmentSaveErrorText :: proc(message: string) -> string {
	switch message {
	case common.ATTACHMENT_NOT_FOUND_MESSAGE, common.ATTACHMENT_UNAVAILABLE_MESSAGE:
		return ATTACHMENT_UNAVAILABLE_TEXT
	case "connection lost":
		return "The connection was lost; try again"
	case "":
		return "The file could not be saved"
	}
	if message[0] >= 'a' && message[0] <= 'z' {
		return strings.concatenate(
			{strings.to_upper(message[:1], context.temp_allocator), message[1:]},
			context.temp_allocator,
		)
	}
	return message
}

// ── Transfer events ──────────────────────────────────────────────

// Pops every transfer event (State_popTransferEvent keeps finished uploads) and moves it onto
// the chips and cards. Returns whether anything changed. The GUI calls it every loop pass.
State_pollTransfers :: proc(state: ^State) -> bool {
	changed := false
	for {
		event, ok := State_popTransferEvent(state)
		if !ok {
			break
		}
		State_attachmentUITransferEvent(state, &event)
		ClientTransferEvent_deinit(&event)
		changed = true
	}
	return changed
}

// One transfer event, for the chip or card it belongs to.
State_attachmentUITransferEvent :: proc(state: ^State, event: ^ClientTransferEvent) {
	switch event.direction {
	case .Upload:
		file: ^ComposerFile
		for &candidate in state.composerFiles {
			if candidate.serverID == event.serverID &&
			   candidate.transferID == event.id &&
			   candidate.status == .Uploading {
				file = &candidate
				break
			}
		}
		if file == nil {
			// A chip removed just as its upload finished: nothing will send it.
			if event.kind == .Done && event.hasBlobId {
				State_forgetUploadedAttachment(state, event.serverID, event.blobId)
			}
			return
		}
		if event.hasBlobId {
			file.blobId = event.blobId
			file.hasBlobId = true
		}
		file.bytes = event.bytes
		if event.total > 0 {
			file.total = event.total
		}
		switch event.kind {
		case .Progress:
		case .Done:
			file.status = .Ready
			file.bytes = file.total
			file.encrypted = event.encrypted
		case .Error:
			file.status = .Failed
			delete(file.error)
			file.error = strings.clone(attachmentSaveErrorText(event.message))
		}
	case .Download:
		for &save, index in state.attachmentSaves {
			if save.file.serverID != event.serverID ||
			   save.transferID != event.id ||
			   save.status != .Saving {
				continue
			}
			save.bytes = event.bytes
			if event.total > 0 {
				save.total = event.total
			}
			switch event.kind {
			case .Progress:
			case .Done:
				save.status = .Saved
			case .Error:
				if save.cancelling {
					AttachmentSave_deinit(&save)
					ordered_remove(&state.attachmentSaves, index)
					return
				}
				save.status = .Failed
				delete(save.error)
				save.error = strings.clone(attachmentSaveErrorText(event.message))
			}
			return
		}
	}
}

// The transfer worker stopped (a reconfigure, or the end): its transfers end without events,
// so the chips still uploading and the cards still saving fail here, and their transfer IDs
// are never matched against a new worker's.
State_attachmentUITransfersStopped :: proc(state: ^State) {
	for &file in state.composerFiles {
		if file.status == .Uploading {
			file.status = .Failed
			file.transferID = 0
			delete(file.error)
			file.error = strings.clone(attachmentSaveErrorText("connection lost"))
		}
	}
	for index := len(state.attachmentSaves) - 1; index >= 0; index -= 1 {
		save := &state.attachmentSaves[index]
		if save.status != .Saving {
			continue
		}
		if save.cancelling {
			AttachmentSave_deinit(save)
			ordered_remove(&state.attachmentSaves, index)
			continue
		}
		save.status = .Failed
		save.transferID = 0
		delete(save.error)
		save.error = strings.clone(attachmentSaveErrorText("connection lost"))
	}
}

// ── View models ──────────────────────────────────────────────────

// One chip as the composer draws it. Strings are borrowed or temp.
ComposerChipView :: struct {
	name:     string,
	detail:   string, // "8.0 MB", "45% of 8.0 MB", or the error
	failed:   bool,
	progress: f32, // 0..1 while uploading, -1 otherwise
}

// The composer's attachment controls: the paperclip, the chips and the send gate.
ComposerAttachmentsView :: struct {
	showAttach:   bool, // false while attachments are off or the server is not connected
	canAttach:    bool,
	attachReason: string, // why the paperclip is disabled (its tooltip)
	chips:        []ComposerChipView,
	sendBlocked:  bool,
	gateReason:   string,
}

buildComposerAttachmentsView :: proc(
	state: ^State,
	serverID, roomID, peerUserID: int,
	allocator := context.temp_allocator,
) -> (
	view: ComposerAttachmentsView,
) {
	view.showAttach = State_attachmentLimits(state, serverID).enabled
	view.attachReason = State_composerAttachBlocked(state, serverID, roomID, peerUserID)
	view.canAttach = len(view.attachReason) == 0
	files := State_composerFiles(state, serverID, roomID, peerUserID)
	chips := make([]ComposerChipView, len(files), allocator)
	for file, index in files {
		chip := ComposerChipView {
			name     = file.name,
			progress = -1,
		}
		size := attachmentSizeText(file.fileSize)
		switch file.status {
		case .Uploading:
			fraction: f32 = 0
			if file.total > 0 {
				fraction = clamp(f32(f64(file.bytes) / f64(file.total)), 0, 1)
			}
			chip.progress = fraction
			chip.detail = fmt.aprintf("%d%% of %s", int(fraction * 100), size, allocator = allocator)
		case .Ready:
			chip.detail = size
		case .Failed:
			chip.failed = true
			chip.detail = file.error
		}
		chips[index] = chip
	}
	view.chips = chips
	view.sendBlocked, view.gateReason = State_composerSendGate(
		state,
		serverID,
		roomID,
		peerUserID,
	)
	return
}

FileCardState :: enum u8 {
	Idle,
	Choosing,
	Saving,
	Saved,
	Failed,
	Removed,
}

// One file card in the transcript. Strings are borrowed from State or temp.
FileCardView :: struct {
	index:     int,
	title:     string, // the file's name
	detail:    string, // "8.0 MB · text/plain"
	status:    string, // the save's progress or result, or the removal
	state:     FileCardState,
	progress:  f32, // 0..1 while saving
	canSave:   bool,
	canCancel: bool,
}

// The cards of a shown message's files (files from State_messageFiles), each with its save.
buildFileCardViews :: proc(
	state: ^State,
	serverID: int,
	kind: common.ReadMarkerKind,
	conversationID, messageID: int,
	files: []MessageFile,
	allocator := context.temp_allocator,
) -> []FileCardView {
	if len(files) == 0 {
		return nil
	}
	cards := make([]FileCardView, len(files), allocator)
	for file, index in files {
		card := FileCardView {
			index   = index,
			title   = file.name,
			detail  = fmt.aprintf(
				"%s · %s",
				attachmentSizeText(file.fileSize),
				file.mediaType,
				allocator = allocator,
			),
			canSave = true,
		}
		if file.removed {
			card.state = .Removed
			card.status = common.ATTACHMENT_REMOVED_MESSAGE
			card.canSave = false
			cards[index] = card
			continue
		}
		ref := AttachmentFileRef{serverID, kind, conversationID, messageID, index}
		if save := State_attachmentSave(state, ref); save != nil {
			switch save.status {
			case .Choosing:
				card.state = .Choosing
				card.status = ATTACHMENT_SAVE_CHOOSING_TEXT
				card.canSave = false
			case .Saving:
				fraction: f32 = 0
				if save.total > 0 {
					fraction = clamp(f32(f64(save.bytes) / f64(save.total)), 0, 1)
				}
				card.state = .Saving
				card.progress = fraction
				card.status = fmt.aprintf(
					"Saving… %d%%",
					int(fraction * 100),
					allocator = allocator,
				)
				card.canSave = false
				card.canCancel = !save.cancelling
			case .Saved:
				card.state = .Saved
				card.status = fmt.aprintf(
					"Saved as %s",
					filepath.base(save.path),
					allocator = allocator,
				)
			case .Failed:
				card.state = .Failed
				card.status = save.error
			}
		}
		cards[index] = card
	}
	return cards
}

// ── Remove attachment (admins) ───────────────────────────────────

// The open Remove attachment confirmation. name and error are owned; reason is the field.
AttachmentRemoveDialog :: struct {
	open:   bool,
	file:   AttachmentFileRef,
	blobId: common.AttachmentBlobID,
	name:   string,
	reason: [dynamic]u8,
	sent:   bool,
	error:  string, // a refusal before anything was sent
	// The view put the keyboard in the reason field once (the dialog's first frame).
	focused: bool,
}

AttachmentRemoveDialog_deinit :: proc(dialog: ^AttachmentRemoveDialog) {
	delete(dialog.name)
	delete(dialog.reason)
	delete(dialog.error)
	dialog^ = {}
}

// Opens the confirmation for ref's file (admins of its server, a file not removed yet).
State_openAttachmentRemoveDialog :: proc(state: ^State, ref: AttachmentFileRef) -> bool {
	if !State_isServerAdmin(state, ref.serverID) {
		return false
	}
	file, ok := State_attachmentFile(state, ref)
	if !ok || file.removed {
		return false
	}
	AttachmentRemoveDialog_deinit(&state.attachmentRemoveDialog)
	state.attachmentRemoveDialog = AttachmentRemoveDialog {
		open   = true,
		file   = ref,
		blobId = file.blobId,
		name   = strings.clone(file.name),
	}
	State_clearAdminRequestStatus(state)
	return true
}

State_closeAttachmentRemoveDialog :: proc(state: ^State) {
	AttachmentRemoveDialog_deinit(&state.attachmentRemoveDialog)
}

// Remove: sends the removal with the reason (optional). The dialog stays open with "Waiting for
// the server…" and closes once the server confirmed (buildAttachmentRemoveDialogView.done).
State_submitAttachmentRemoveDialog :: proc(state: ^State) {
	dialog := &state.attachmentRemoveDialog
	if !dialog.open || dialog.sent {
		return
	}
	reason := strings.trim_space(string(dialog.reason[:]))
	delete(dialog.error)
	dialog.error = ""
	if !common.attachmentRemoveReasonIsValid(reason) {
		dialog.error = strings.clone(common.ATTACHMENT_REMOVE_REASON_INVALID_MESSAGE)
		return
	}
	if errorMessage := State_removeAttachment(state, dialog.file.serverID, dialog.blobId, reason);
	   len(errorMessage) > 0 {
		dialog.error = strings.clone(errorMessage)
		return
	}
	dialog.sent = true
}

AttachmentRemoveDialogView :: struct {
	visible:     bool,
	serverID:    int,
	title:       string,
	text:        string,
	status:      string,
	statusError: bool,
	busy:        bool, // waiting for the server: Remove does nothing
	done:        bool, // the server removed it: the view closes the dialog
}

buildAttachmentRemoveDialogView :: proc(
	state: ^State,
	allocator := context.temp_allocator,
) -> (
	view: AttachmentRemoveDialogView,
) {
	dialog := &state.attachmentRemoveDialog
	if !dialog.open {
		return
	}
	file, ok := State_attachmentFile(state, dialog.file)
	if !ok || !State_isServerAdmin(state, dialog.file.serverID) {
		// The message left the cache or the role went: nothing to confirm any more.
		view.done = true
		return
	}
	view.visible = true
	view.serverID = dialog.file.serverID
	view.title = ATTACHMENT_REMOVE_TITLE
	view.text = fmt.aprintf(
		"Remove %s from the server? The message stays, and everyone who can read it sees " +
		"\"%s\" instead of the file. A reason is optional and goes only to the server's log.",
		dialog.name,
		common.ATTACHMENT_REMOVED_MESSAGE,
		allocator = allocator,
	)
	request := &state.adminRequest
	matches :=
		dialog.sent &&
		request.serverID == dialog.file.serverID &&
		request.action == .RemoveAttachment &&
		request.blobID == dialog.blobId
	switch {
	case len(dialog.error) > 0:
		view.status = dialog.error
		view.statusError = true
	case matches && request.pending:
		view.status = "Waiting for the server…"
		view.busy = true
	case matches && len(request.error) > 0:
		view.status = request.error
		view.statusError = true
	case matches && len(request.result) > 0:
		view.done = true
	case dialog.sent && file.removed:
		view.done = true
	case dialog.sent:
		view.busy = true
		view.status = "Waiting for the server…"
	}
	return
}

// ── Admin → Storage ──────────────────────────────────────────────

AdminStorageRow :: struct {
	userID: int,
	label:  string,
	bytes:  string,
	count:  string,
}

AdminStorageView :: struct {
	hasUsage: bool,
	pending:  bool,
	used:     string,
	capacity: string,
	free:     string,
	accounts: []AdminStorageRow,
}

ADMIN_STORAGE_UNKNOWN_TEXT :: "unknown"

// Admin → Storage from the last usage the server reported. The sizes are temp; the rows are in
// allocator.
buildAdminStorageView :: proc(
	state: ^State,
	serverID: int,
	allocator := context.temp_allocator,
) -> (
	view: AdminStorageView,
) {
	if index := State_serverConnectionIndex(state^, serverID); index >= 0 {
		view.pending = state.serverConnections[index].attachmentUsagePending
	}
	usage, ok := State_attachmentUsage(state, serverID)
	if !ok {
		return
	}
	view.hasUsage = true
	view.used = attachmentSizeText(usage.usedBytes)
	view.capacity = "No limit"
	if usage.capacityBytes > 0 {
		view.capacity = attachmentSizeText(usage.capacityBytes)
	}
	view.free = ADMIN_STORAGE_UNKNOWN_TEXT
	if usage.freeBytesKnown {
		view.free = attachmentSizeText(usage.freeBytes)
	}
	cache: ^ServerDirectCache
	if cacheIndex := State_serverDirectCacheIndex(state^, serverID); cacheIndex >= 0 {
		cache = &state.serverDirectCaches[cacheIndex]
	}
	rows := make([]AdminStorageRow, len(usage.accounts), allocator)
	for account, index in usage.accounts {
		nickname := ""
		if cache != nil {
			nickname = ServerDirectCache_peerNickname(cache, account.userId)
		}
		label := userLabel(nickname, account.userId, allocator)
		if account.userId == State_selfUserID(state, serverID) {
			label = fmt.aprintf("%s (you)", label, allocator = allocator)
		}
		rows[index] = AdminStorageRow {
			userID = account.userId,
			label  = label,
			bytes  = attachmentSizeText(account.bytes),
			count  = fmt.aprintf(
				account.count == 1 ? "%d file" : "%d files",
				account.count,
				allocator = allocator,
			),
		}
	}
	view.accounts = rows
	return
}

// ── File dialogs and drops ───────────────────────────────────────

// Takes the native dialogs' and automation's answers and applies them: picked files go to their
// composer (automation's to the one on screen), a save's path starts its download. Returns
// whether anything changed. The GUI calls it every loop pass.
State_pollFileDialogs :: proc(state: ^State) -> bool {
	answers := FileDialogQueue_take(state.fileDialogs)
	defer delete(answers)
	for &answer in answers {
		defer FileDialogAnswer_deinit(&answer)
		target := answer.target
		switch answer.kind {
		case .Open:
			if target.current {
				serverID, roomID, peerUserID, ok := State_currentComposer(state)
				if !ok {
					State_setChatStatus(state, "Open a room or a conversation to attach files")
					continue
				}
				target.serverID, target.roomID, target.peerUserID = serverID, roomID, peerUserID
			}
			if len(answer.error) > 0 {
				State_setChatStatus(
					state,
					fmt.tprintf("The file dialog could not open: %s", answer.error),
				)
				continue
			}
			State_composerAddFiles(
				state,
				target.serverID,
				target.roomID,
				target.peerUserID,
				answer.paths[:],
			)
		case .Save:
			kind := target.roomID > 0 ? common.ReadMarkerKind.Room : common.ReadMarkerKind.Direct
			conversationID := target.roomID > 0 ? target.roomID : target.peerUserID
			ref := AttachmentFileRef {
				target.serverID,
				kind,
				conversationID,
				target.messageID,
				target.index,
			}
			switch {
			case len(answer.error) > 0:
				State_attachmentSaveDialogClosed(
					state,
					ref,
					"The save dialog could not open",
				)
			case len(answer.paths) == 0:
				State_attachmentSaveDialogClosed(state, ref)
			case:
				State_attachmentSaveChosen(state, ref, answer.paths[0])
			}
		}
	}
	return len(answers) > 0
}

// Adds several picked or dropped files to a composer; the first reason a file could not be
// added goes to the status line.
State_composerAddFiles :: proc(state: ^State, serverID, roomID, peerUserID: int, paths: []string) {
	for path in paths {
		if reason := State_composerAddFile(state, serverID, roomID, peerUserID, path);
		   len(reason) > 0 {
			State_setChatStatus(state, reason)
			return
		}
	}
}

// A file dropped on the window (SDL_EVENT_DROP_FILE) goes to the composer on screen.
State_dropFile :: proc(state: ^State, path: string) {
	serverID, roomID, peerUserID, ok := State_currentComposer(state)
	if !ok {
		State_setChatStatus(state, "Open a room or a conversation to attach files")
		return
	}
	paths := [1]string{path}
	State_composerAddFiles(state, serverID, roomID, peerUserID, paths[:])
}

// The target of a save dialog for ref.
attachmentSaveDialogTarget :: proc(ref: AttachmentFileRef) -> FileDialogTarget {
	roomID, peerUserID := attachmentRefRoomPeer(ref)
	return FileDialogTarget {
		serverID = ref.serverID,
		roomID = roomID,
		peerUserID = peerUserID,
		messageID = ref.messageID,
		index = ref.index,
	}
}
