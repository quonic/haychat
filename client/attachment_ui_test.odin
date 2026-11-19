package client

import "../common"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"

// The attachments UI (attachments plan F4, attachment_ui.odin): chips and the send gate, the
// names a save suggests (D19), the file cards' states and failure texts, the Remove attachment
// confirmation (admins), Admin → Storage, the card's context menu, and the file dialog queue
// automation answers through.

@(private = "file")
UI_TEST_SERVER :: ATTACHMENT_TEST_SERVER

@(private = "file")
uiTestChip :: proc(
	state: ^State,
	roomID, peerUserID, transferID: int,
	status: ComposerFileStatus,
	encrypted := false,
) {
	append(
		&state.composerFiles,
		ComposerFile {
			serverID = UI_TEST_SERVER,
			roomID = roomID,
			peerUserID = peerUserID,
			transferID = transferID,
			name = strings.clone(fmt.tprintf("file-%d.txt", transferID)),
			fileSize = 2048,
			total = 2048,
			status = status,
			encrypted = encrypted,
		},
	)
}

@(test)
testSuggestedSaveNamesAreSanitized :: proc(t: ^testing.T) {
	_ = t
	defer free_all(context.temp_allocator)
	cases := [?][2]string {
		{"notes.txt", "notes.txt"},
		{"../../etc/passwd", "_.._etc_passwd"},
		{"a\\b/c.txt", "a_b_c.txt"},
		{"C:\\boot.ini", "C__boot.ini"},
		{".bashrc", "bashrc"},
		{"...hidden.", "hidden"},
		{"  spaced  ", "spaced"},
		{"line\nbreak\x7f.txt", "line_break_.txt"},
		{"what?*<>|\".txt", "what______.txt"},
		{"CON", "_CON"},
		{"con.txt", "_con.txt"},
		{"Lpt9.tar.gz", "_Lpt9.tar.gz"},
		{"COM0", "_COM0"},
		{"console.txt", "console.txt"},
		{"nul .txt", "_nul .txt"},
		{"", "attachment"},
		{"....", "attachment"},
		{"héllo wörld.pdf", "héllo wörld.pdf"},
	}
	for entry in cases {
		got := attachmentSuggestedSaveName(entry[0])
		assert(
			got == entry[1],
			fmt.tprintf("expected %q to be offered as %q, got %q", entry[0], entry[1], got),
		)
	}
	long := strings.repeat("é", 200, context.temp_allocator)
	cut := attachmentSuggestedSaveName(long)
	assert(
		len(cut) <= common.ATTACHMENT_NAME_MAX_BYTES && len(cut) % 2 == 0,
		fmt.tprintf("expected a long name cut at a character boundary, got %d bytes", len(cut)),
	)
}

@(test)
testComposerSendGateWaitsForUploads :: proc(t: ^testing.T) {
	_ = t
	defer free_all(context.temp_allocator)
	file :: proc(status: ComposerFileStatus, encrypted := false) -> ^ComposerFile {
		result := new(ComposerFile, context.temp_allocator)
		result^ = ComposerFile {
			status    = status,
			encrypted = encrypted,
		}
		return result
	}
	blocked, reason := composerSendGate(nil, false)
	assert(!blocked && reason == "", "expected no files to leave Send alone")
	ready := []^ComposerFile{file(.Ready), file(.Ready)}
	blocked, reason = composerSendGate(ready, false)
	assert(!blocked, "expected finished uploads to allow Send")
	one := []^ComposerFile{file(.Ready), file(.Uploading)}
	blocked, reason = composerSendGate(one, false)
	assert(
		blocked && reason == "Waiting for 1 upload to finish…",
		fmt.tprintf("expected one upload waited for, got %q", reason),
	)
	two := []^ComposerFile{file(.Uploading), file(.Uploading), file(.Failed)}
	blocked, reason = composerSendGate(two, false)
	assert(
		blocked && reason == "Waiting for 2 uploads to finish…",
		fmt.tprintf("expected uploads to come before failures, got %q", reason),
	)
	failed := []^ComposerFile{file(.Ready), file(.Failed)}
	blocked, reason = composerSendGate(failed, false)
	assert(
		blocked && reason == "Remove the file that could not be uploaded to send",
		fmt.tprintf("expected a failed upload to keep Send shut, got %q", reason),
	)
	// The DM switch changed after the upload: the file has the wrong encryption.
	sealed := []^ComposerFile{file(.Ready, encrypted = true)}
	blocked, reason = composerSendGate(sealed, false)
	assert(
		blocked && reason == "A file was uploaded encrypted; remove it and attach it again",
		fmt.tprintf("expected an encrypted upload refused for a plaintext message, got %q", reason),
	)
	blocked, reason = composerSendGate(ready, true)
	assert(
		blocked && reason == "A file was uploaded unencrypted; remove it and attach it again",
		fmt.tprintf("expected a plaintext upload refused for a sealed message, got %q", reason),
	)
}

@(test)
testComposerChipsFollowTheirUploads :: proc(t: ^testing.T) {
	_ = t
	defer free_all(context.temp_allocator)
	server := testDirectServer(UI_TEST_SERVER)
	state := testUpdateStateForServer(server)
	defer State_deinit(&state)
	testPrepareRoomSend(&state, UI_TEST_SERVER, ATTACHMENT_TEST_SELF)
	State_serverConnection(&state, UI_TEST_SERVER).attachmentLimits = {
		enabled  = true,
		maxBytes = 4,
	}
	dir := configTestCreateTempDir("haychat_attachment_chips")
	defer os.remove_all(dir)
	path := fmt.tprintf("%s/five.bin", dir)
	assert(
		os.write_entire_file_from_bytes(path, transmute([]u8)string("12345"), os.perm(0o600)) ==
		nil,
		"expected a file",
	)

	// Too large for the server's limit: refused before the upload, kept as a failed chip.
	reason := State_composerAddFile(&state, UI_TEST_SERVER, common.GENERAL_ROOM_ID, 0, path)
	assert(reason == "", fmt.tprintf("expected the file added as a chip, got %q", reason))
	chips := State_composerFiles(&state, UI_TEST_SERVER, common.GENERAL_ROOM_ID, 0)
	assert(
		len(chips) == 1 &&
		chips[0].status == .Failed &&
		chips[0].error == common.ATTACHMENT_TOO_LARGE_MESSAGE &&
		chips[0].name == "five.bin" &&
		chips[0].fileSize == 5,
		fmt.tprintf("expected a failed chip saying the file is too large, got %v", chips),
	)
	view := buildComposerAttachmentsView(&state, UI_TEST_SERVER, common.GENERAL_ROOM_ID, 0)
	assert(
		view.showAttach &&
		view.canAttach &&
		len(view.chips) == 1 &&
		view.chips[0].failed &&
		view.chips[0].detail == common.ATTACHMENT_TOO_LARGE_MESSAGE &&
		view.sendBlocked,
		fmt.tprintf("expected the failed chip to keep Send shut, got %v", view),
	)
	// Another conversation's draft does not see it.
	assert(
		len(State_composerFiles(&state, UI_TEST_SERVER, 2, 0)) == 0 &&
		len(State_composerFiles(&state, UI_TEST_SERVER, 0, ATTACHMENT_TEST_PEER)) == 0,
		"expected chips to belong to their conversation",
	)
	assert(
		!State_composerSend(&state, UI_TEST_SERVER, common.GENERAL_ROOM_ID, 0),
		"expected Send refused while a file failed",
	)
	State_composerRemoveFile(&state, UI_TEST_SERVER, common.GENERAL_ROOM_ID, 0, 0)
	assert(
		len(State_composerFiles(&state, UI_TEST_SERVER, common.GENERAL_ROOM_ID, 0)) == 0,
		"expected the chip removed",
	)

	// Transfer events move onto the chip they belong to.
	uiTestChip(&state, common.GENERAL_ROOM_ID, 0, 7, .Uploading)
	uiTestChip(&state, common.GENERAL_ROOM_ID, 0, 8, .Uploading)
	progress := ClientTransferEvent {
		kind      = .Progress,
		direction = .Upload,
		id        = 7,
		serverID  = UI_TEST_SERVER,
		bytes     = 1024,
		total     = 2048,
	}
	State_attachmentUITransferEvent(&state, &progress)
	view = buildComposerAttachmentsView(&state, UI_TEST_SERVER, common.GENERAL_ROOM_ID, 0)
	assert(
		len(view.chips) == 2 &&
		view.chips[0].progress == 0.5 &&
		view.chips[0].detail == "50% of 2.0 KB" &&
		view.chips[1].progress == 0 &&
		view.sendBlocked &&
		view.gateReason == "Waiting for 2 uploads to finish…",
		fmt.tprintf("expected the first chip half done, got %v", view),
	)
	done := ClientTransferEvent {
		kind      = .Done,
		direction = .Upload,
		id        = 7,
		serverID  = UI_TEST_SERVER,
		hasBlobId = true,
		bytes     = 2048,
		total     = 2048,
	}
	done.blobId[0] = 0x77
	State_attachmentUITransferEvent(&state, &done)
	failure := ClientTransferEvent {
		kind      = .Error,
		direction = .Upload,
		id        = 8,
		serverID  = UI_TEST_SERVER,
		message   = common.ATTACHMENT_QUOTA_MESSAGE,
	}
	State_attachmentUITransferEvent(&state, &failure)
	chips = State_composerFiles(&state, UI_TEST_SERVER, common.GENERAL_ROOM_ID, 0)
	assert(
		chips[0].status == .Ready &&
		chips[0].hasBlobId &&
		chips[0].blobId[0] == 0x77 &&
		chips[1].status == .Failed &&
		chips[1].error == common.ATTACHMENT_QUOTA_MESSAGE,
		fmt.tprintf("expected one chip ready and one failed, got %v", chips),
	)
	view = buildComposerAttachmentsView(&state, UI_TEST_SERVER, common.GENERAL_ROOM_ID, 0)
	assert(
		view.chips[0].detail == "2.0 KB" &&
		view.chips[0].progress < 0 &&
		view.gateReason == "Remove the file that could not be uploaded to send",
		fmt.tprintf("expected the failure to keep Send shut, got %v", view),
	)
	State_composerRemoveFile(&state, UI_TEST_SERVER, common.GENERAL_ROOM_ID, 0, 1)
	blocked, _ := State_composerSendGate(&state, UI_TEST_SERVER, common.GENERAL_ROOM_ID, 0)
	assert(!blocked, "expected Send open once the failed chip is gone")

	// Four files at most: a fifth is refused with the reason, and nothing is added.
	uiTestChip(&state, common.GENERAL_ROOM_ID, 0, 9, .Ready)
	uiTestChip(&state, common.GENERAL_ROOM_ID, 0, 10, .Ready)
	uiTestChip(&state, common.GENERAL_ROOM_ID, 0, 11, .Ready)
	fifth := State_composerAddFile(&state, UI_TEST_SERVER, common.GENERAL_ROOM_ID, 0, path)
	view = buildComposerAttachmentsView(&state, UI_TEST_SERVER, common.GENERAL_ROOM_ID, 0)
	assert(
		fifth == ATTACHMENT_FILES_MAX_TEXT &&
		len(view.chips) == 4 &&
		!view.canAttach &&
		view.attachReason == ATTACHMENT_FILES_MAX_TEXT,
		fmt.tprintf("expected a fifth file refused, got %q and %v", fifth, view),
	)

	// Without AttachFiles the paperclip is disabled with the reason, and nothing is added.
	room := State_roomSummary(&state, UI_TEST_SERVER, common.GENERAL_ROOM_ID)
	if room != nil {
		room.myPermissions = {.SendMessages}
		denied := State_composerAddFile(&state, UI_TEST_SERVER, common.GENERAL_ROOM_ID, 0, path)
		assert(
			denied == common.ATTACHMENT_SEND_NOT_PERMITTED_MESSAGE,
			fmt.tprintf("expected files refused without AttachFiles, got %q", denied),
		)
	}
	// The transfer worker stops (a reconfigure): uploads still running fail, and their transfer
	// IDs, which a new worker hands out again, no longer match anything.
	uiTestChip(&state, 0, ATTACHMENT_TEST_PEER, 12, .Uploading)
	State_stopTransfers(&state)
	dmChips := State_composerFiles(&state, UI_TEST_SERVER, 0, ATTACHMENT_TEST_PEER)
	assert(
		len(dmChips) == 1 &&
		dmChips[0].status == .Failed &&
		dmChips[0].transferID == 0 &&
		dmChips[0].error == "The connection was lost; try again",
		fmt.tprintf("expected the running upload failed by the stop, got %v", dmChips),
	)
	// Attachments off: no paperclip at all.
	State_serverConnection(&state, UI_TEST_SERVER).attachmentLimits = {}
	view = buildComposerAttachmentsView(&state, UI_TEST_SERVER, 0, ATTACHMENT_TEST_PEER)
	assert(!view.showAttach && !view.canAttach, "expected no paperclip while attachments are off")
}

@(test)
testFileCardsShowTheirSaves :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&e2eeSendBridgeTestMutex)
	defer sync.mutex_unlock(&e2eeSendBridgeTestMutex)
	e2eeFetchBridge = attachmentTestFetchBridge
	defer free_all(context.temp_allocator)
	server := testDirectServer(UI_TEST_SERVER)
	state := testUpdateStateForServer(server)
	defer State_deinit(&state)
	testPrepareRoomSend(&state, UI_TEST_SERVER, ATTACHMENT_TEST_SELF)
	serverKey, peerKey := testMessageSigner(&state, UI_TEST_SERVER, ATTACHMENT_TEST_PEER)
	refs := attachmentTestRefs()
	attachmentTestDeliver(&state, 40, "", peerKey, serverKey, refs[:], refs[:])
	entry := attachmentTestEntry(&state, 40)
	assert(entry != nil && len(entry.files) == 2, "expected the message with its two files")

	ref := AttachmentFileRef{UI_TEST_SERVER, .Room, common.GENERAL_ROOM_ID, 40, 0}
	cards := buildFileCardViews(&state, UI_TEST_SERVER, .Room, common.GENERAL_ROOM_ID, 40, entry.files[:])
	assert(
		len(cards) == 2 &&
		cards[0].state == .Idle &&
		cards[0].detail == "1000 bytes · text/plain" &&
		cards[0].canSave &&
		!cards[0].canCancel,
		fmt.tprintf("expected two idle cards with Save…, got %v", cards),
	)
	// A message with only files is drawn as its cards (D15): the room view keeps no text.
	view := buildRoomView(&state)
	foundLine := false
	for line in view.lines {
		if line.messageID == 40 {
			foundLine = true
			assert(
				line.content == "" && len(line.cards) == 2 && !line.filesChanged,
				fmt.tprintf("expected a files-only line, got %v", line),
			)
		}
	}
	assert(foundLine, "expected the message in the room view")

	// Save…: the dialog is open, the suggested name is the sanitized one.
	name, beginError := State_beginAttachmentSave(&state, ref)
	assert(beginError == "" && name == "a.txt", fmt.tprintf("expected a.txt, got %q %q", name, beginError))
	_, again := State_beginAttachmentSave(&state, ref)
	assert(again != "", "expected a second Save… refused while the dialog is open")
	cards = buildFileCardViews(&state, UI_TEST_SERVER, .Room, common.GENERAL_ROOM_ID, 40, entry.files[:])
	assert(
		cards[0].state == .Choosing && !cards[0].canSave && cards[1].state == .Idle,
		fmt.tprintf("expected only the first card choosing, got %v", cards),
	)
	// Closed without a choice: the card is as before.
	State_attachmentSaveDialogClosed(&state, ref)
	assert(State_attachmentSave(&state, ref) == nil, "expected a cancelled dialog to leave no save")

	// Chosen, but no transfer worker in a test: the card shows why.
	_, _ = State_beginAttachmentSave(&state, ref)
	State_attachmentSaveChosen(&state, ref, "/tmp/haychat-test-a.txt")
	cards = buildFileCardViews(&state, UI_TEST_SERVER, .Room, common.GENERAL_ROOM_ID, 40, entry.files[:])
	assert(
		cards[0].state == .Failed && cards[0].status == NOT_CONNECTED_MESSAGE && cards[0].canSave,
		fmt.tprintf("expected the save to fail without a worker, got %v", cards[0]),
	)

	// Saving, with progress and Cancel, then each ending.
	save := State_attachmentSave(&state, ref)
	save.status = .Saving
	save.transferID = 21
	progress := ClientTransferEvent {
		kind      = .Progress,
		direction = .Download,
		id        = 21,
		serverID  = UI_TEST_SERVER,
		bytes     = 250,
		total     = 1000,
	}
	State_attachmentUITransferEvent(&state, &progress)
	cards = buildFileCardViews(&state, UI_TEST_SERVER, .Room, common.GENERAL_ROOM_ID, 40, entry.files[:])
	assert(
		cards[0].state == .Saving &&
		cards[0].status == "Saving… 25%" &&
		cards[0].progress == 0.25 &&
		cards[0].canCancel &&
		!cards[0].canSave,
		fmt.tprintf("expected the card saving with Cancel, got %v", cards[0]),
	)
	changed := ClientTransferEvent {
		kind      = .Error,
		direction = .Download,
		id        = 21,
		serverID  = UI_TEST_SERVER,
		message   = common.ATTACHMENT_CHANGED_MESSAGE,
	}
	State_attachmentUITransferEvent(&state, &changed)
	cards = buildFileCardViews(&state, UI_TEST_SERVER, .Room, common.GENERAL_ROOM_ID, 40, entry.files[:])
	assert(
		cards[0].state == .Failed && cards[0].status == common.ATTACHMENT_CHANGED_MESSAGE,
		fmt.tprintf("expected the D19 sentence, got %v", cards[0]),
	)
	save = State_attachmentSave(&state, ref)
	save.status = .Saving
	delete(save.path)
	save.path = strings.clone("/home/me/Downloads/a.txt")
	finished := ClientTransferEvent {
		kind      = .Done,
		direction = .Download,
		id        = 21,
		serverID  = UI_TEST_SERVER,
		bytes     = 1000,
		total     = 1000,
	}
	State_attachmentUITransferEvent(&state, &finished)
	cards = buildFileCardViews(&state, UI_TEST_SERVER, .Room, common.GENERAL_ROOM_ID, 40, entry.files[:])
	assert(
		cards[0].state == .Saved && cards[0].status == "Saved as a.txt" && cards[0].canSave,
		fmt.tprintf("expected the card saved, got %v", cards[0]),
	)
	// Cancel ends the save without a failure.
	save = State_attachmentSave(&state, ref)
	save.status = .Saving
	State_cancelAttachmentSave(&state, ref)
	assert(State_attachmentSave(&state, ref) == nil, "expected Cancel without a worker to drop it")

	// The worker's failures, as a card says them.
	assert(
		attachmentSaveErrorText(common.ATTACHMENT_NOT_FOUND_MESSAGE) == ATTACHMENT_UNAVAILABLE_TEXT,
		"expected a missing file to read as unavailable",
	)
	assert(
		attachmentSaveErrorText(common.ATTACHMENT_REMOVED_MESSAGE) ==
		common.ATTACHMENT_REMOVED_MESSAGE,
		"expected the removal sentence unchanged",
	)
	assert(
		attachmentSaveErrorText("cannot create the file") == "Cannot create the file",
		"expected other reasons with a capital letter",
	)

	// A removed file: its card says so and offers no Save…; the menu's Save… is disabled.
	removed := ClientTransportRuntimeEvent {
		kind              = .AttachmentRemoved,
		serverID          = UI_TEST_SERVER,
		attachmentRemoved = {blobId = refs[1].blobId, roomId = common.GENERAL_ROOM_ID},
	}
	State_applyRuntimeEvent(&state, &removed)
	ClientTransportRuntimeEvent_deinit(&removed)
	cards = buildFileCardViews(&state, UI_TEST_SERVER, .Room, common.GENERAL_ROOM_ID, 40, entry.files[:])
	assert(
		cards[1].state == .Removed &&
		cards[1].status == common.ATTACHMENT_REMOVED_MESSAGE &&
		!cards[1].canSave,
		fmt.tprintf("expected the removed card, got %v", cards[1]),
	)
	_, removedSave := State_beginAttachmentSave(
		&state,
		AttachmentFileRef{UI_TEST_SERVER, .Room, common.GENERAL_ROOM_ID, 40, 1},
	)
	assert(removedSave == common.ATTACHMENT_REMOVED_MESSAGE, "expected a removed file not saved")

	// The card's context menu: Save… and Copy file name; Remove attachment… for admins only.
	State_openContextMenu(
		&state,
		AttachmentMenuTarget{UI_TEST_SERVER, .Room, common.GENERAL_ROOM_ID, 40, 0},
		{},
	)
	menu := buildContextMenu(&state, {})
	assert(
		menu.visible &&
		len(menu.entries) == 2 &&
		menu.entries[0].action == .SaveAttachment &&
		menu.entries[0].enabled &&
		menu.entries[1].action == .CopyFileName,
		fmt.tprintf("expected Save… and Copy file name for a member, got %v", menu.entries),
	)
	effect := State_runContextMenuAction(&state, .CopyFileName, {})
	assert(effect.copyText == "a.txt", fmt.tprintf("expected the file name copied, got %q", effect.copyText))
	State_serverConnection(&state, UI_TEST_SERVER).isAdmin = true
	State_openContextMenu(
		&state,
		AttachmentMenuTarget{UI_TEST_SERVER, .Room, common.GENERAL_ROOM_ID, 40, 1},
		{},
	)
	menu = buildContextMenu(&state, {})
	assert(
		len(menu.entries) == 3 &&
		!menu.entries[0].enabled &&
		menu.entries[2].action == .RemoveAttachment &&
		!menu.entries[2].enabled,
		fmt.tprintf("expected a removed file's Save… and Remove disabled, got %v", menu.entries),
	)
	State_closeContextMenu(&state)
	// A file the message does not have closes the menu.
	State_openContextMenu(
		&state,
		AttachmentMenuTarget{UI_TEST_SERVER, .Room, common.GENERAL_ROOM_ID, 40, 2},
		{},
	)
	menu = buildContextMenu(&state, {})
	assert(!menu.visible, "expected a menu on a missing file to close")
	State_closeContextMenu(&state)
}

@(test)
testRemoveAttachmentConfirmation :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&e2eeSendBridgeTestMutex)
	defer sync.mutex_unlock(&e2eeSendBridgeTestMutex)
	e2eeFetchBridge = attachmentTestFetchBridge
	defer free_all(context.temp_allocator)
	server := testDirectServer(UI_TEST_SERVER)
	state := testUpdateStateForServer(server)
	defer State_deinit(&state)
	testPrepareRoomSend(&state, UI_TEST_SERVER, ATTACHMENT_TEST_SELF)
	serverKey, peerKey := testMessageSigner(&state, UI_TEST_SERVER, ATTACHMENT_TEST_PEER)
	refs := attachmentTestRefs()
	attachmentTestDeliver(&state, 41, "with files", peerKey, serverKey, refs[:], refs[:])
	ref := AttachmentFileRef{UI_TEST_SERVER, .Room, common.GENERAL_ROOM_ID, 41, 0}

	// Not an admin: the confirmation does not open.
	assert(!State_openAttachmentRemoveDialog(&state, ref), "expected members not to remove files")
	State_serverConnection(&state, UI_TEST_SERVER).isAdmin = true
	assert(State_openAttachmentRemoveDialog(&state, ref), "expected an admin's confirmation")
	view := buildAttachmentRemoveDialogView(&state)
	assert(
		view.visible &&
		!view.done &&
		view.title == ATTACHMENT_REMOVE_TITLE &&
		strings.contains(view.text, "a.txt") &&
		view.status == "",
		fmt.tprintf("expected the confirmation for a.txt, got %v", view),
	)
	// A reason with a control character is refused before anything is sent.
	append(&state.attachmentRemoveDialog.reason, "spam\x01")
	State_submitAttachmentRemoveDialog(&state)
	view = buildAttachmentRemoveDialogView(&state)
	assert(
		!state.attachmentRemoveDialog.sent &&
		view.statusError &&
		view.status == common.ATTACHMENT_REMOVE_REASON_INVALID_MESSAGE,
		fmt.tprintf("expected the reason refused, got %v", view),
	)
	// The server's answer, as the admin request tracker holds it (a submit that went out
	// clears the local refusal first).
	delete(state.attachmentRemoveDialog.error)
	state.attachmentRemoveDialog.error = ""
	state.attachmentRemoveDialog.sent = true
	state.adminRequest = AdminRequestState {
		serverID = UI_TEST_SERVER,
		action   = .RemoveAttachment,
		blobID   = refs[0].blobId,
		pending  = true,
	}
	view = buildAttachmentRemoveDialogView(&state)
	assert(view.busy && view.status == "Waiting for the server…", "expected the dialog waiting")
	state.adminRequest.pending = false
	state.adminRequest.error = strings.clone(common.ATTACHMENT_NOT_FOUND_MESSAGE)
	view = buildAttachmentRemoveDialogView(&state)
	assert(
		view.statusError && view.status == common.ATTACHMENT_NOT_FOUND_MESSAGE && !view.done,
		fmt.tprintf("expected the refusal shown, got %v", view),
	)
	delete(state.adminRequest.error)
	state.adminRequest.error = ""
	state.adminRequest.result = strings.clone("Removed the attachment")
	view = buildAttachmentRemoveDialogView(&state)
	assert(view.done, "expected the dialog done once the server removed the file")
	State_closeAttachmentRemoveDialog(&state)
	assert(!state.attachmentRemoveDialog.open, "expected the dialog closed")
	// The file is already removed: the confirmation does not open.
	removed := ClientTransportRuntimeEvent {
		kind              = .AttachmentRemoved,
		serverID          = UI_TEST_SERVER,
		attachmentRemoved = {blobId = refs[0].blobId, roomId = common.GENERAL_ROOM_ID},
	}
	State_applyRuntimeEvent(&state, &removed)
	ClientTransportRuntimeEvent_deinit(&removed)
	assert(!State_openAttachmentRemoveDialog(&state, ref), "expected no removal of a removed file")
}

@(test)
testAdminStorageView :: proc(t: ^testing.T) {
	_ = t
	defer free_all(context.temp_allocator)
	server := testDirectServer(UI_TEST_SERVER)
	state := testUpdateStateForServer(server)
	defer State_deinit(&state)
	testApplyConnected(&state, UI_TEST_SERVER, ATTACHMENT_TEST_SELF)
	view := buildAdminStorageView(&state, UI_TEST_SERVER)
	assert(!view.hasUsage && !view.pending, "expected nothing before the server answered")
	users := ClientTransportRuntimeEvent {
		kind     = .UserListReceived,
		serverID = UI_TEST_SERVER,
	}
	append(&users.users, common.UserSummary{id = 77, nickname = strings.clone("bob")})
	State_applyRuntimeEvent(&state, &users)
	ClientTransportRuntimeEvent_deinit(&users)
	usage := ClientTransportRuntimeEvent {
		kind = .AttachmentUsageReceived,
		serverID = UI_TEST_SERVER,
		attachmentUsage = {usedBytes = 3 * 1024 * 1024, freeBytesKnown = false},
	}
	append(&usage.attachmentUsage.accounts, common.AttachmentAccountUsage{77, 2 * 1024 * 1024, 2})
	append(
		&usage.attachmentUsage.accounts,
		common.AttachmentAccountUsage{ATTACHMENT_TEST_SELF, 1024 * 1024, 1},
	)
	append(&usage.attachmentUsage.accounts, common.AttachmentAccountUsage{99, 10, 1})
	State_applyRuntimeEvent(&state, &usage)
	ClientTransportRuntimeEvent_deinit(&usage)
	view = buildAdminStorageView(&state, UI_TEST_SERVER)
	assert(
		view.hasUsage &&
		view.used == "3.0 MB" &&
		view.capacity == "No limit" &&
		view.free == ADMIN_STORAGE_UNKNOWN_TEXT &&
		len(view.accounts) == 3,
		fmt.tprintf("expected the totals with unknown free space, got %v", view),
	)
	assert(
		view.accounts[0].label == "bob" &&
		view.accounts[0].bytes == "2.0 MB" &&
		view.accounts[0].count == "2 files" &&
		strings.has_suffix(view.accounts[1].label, "(you)") &&
		view.accounts[1].count == "1 file" &&
		view.accounts[2].label == "User 99",
		fmt.tprintf("expected the accounts named from the user list, got %v", view.accounts),
	)
	connection := State_serverConnection(&state, UI_TEST_SERVER)
	connection.attachmentUsage.capacityBytes = 1024 * 1024 * 1024
	connection.attachmentUsage.freeBytes = 512 * 1024 * 1024
	connection.attachmentUsage.freeBytesKnown = true
	view = buildAdminStorageView(&state, UI_TEST_SERVER)
	assert(
		view.capacity == "1.0 GB" && view.free == "512.0 MB",
		fmt.tprintf("expected capacity and free space, got %v", view),
	)
}

@(test)
testFileDialogQueueAnswers :: proc(t: ^testing.T) {
	_ = t
	defer free_all(context.temp_allocator)
	queue := FileDialogQueue_create()
	FileDialogQueue_pushPicked(queue, "/tmp/a.txt")
	FileDialogQueue_pushPicked(queue, "/tmp/b c.txt")
	answers := FileDialogQueue_take(queue)
	assert(
		len(answers) == 1 &&
		answers[0].kind == .Open &&
		answers[0].target.current &&
		len(answers[0].paths) == 2 &&
		answers[0].paths[1] == "/tmp/b c.txt",
		fmt.tprintf("expected the picks as one answer for the composer on screen, got %v", answers),
	)
	for &answer in answers {
		FileDialogAnswer_deinit(&answer)
	}
	delete(answers)
	again := FileDialogQueue_take(queue)
	assert(len(again) == 0, "expected the picks taken once")
	delete(again)
	_, none := FileDialogQueue_takeNextSavePath(queue)
	assert(!none, "expected no save answer before save-path")
	FileDialogQueue_setNextSavePath(queue, "/tmp/first")
	FileDialogQueue_setNextSavePath(queue, "/tmp/out.bin")
	path, ok := FileDialogQueue_takeNextSavePath(queue)
	assert(ok && path == "/tmp/out.bin", fmt.tprintf("expected the last save-path, got %q", path))
	delete(path)
	_, twice := FileDialogQueue_takeNextSavePath(queue)
	assert(!twice, "expected a save-path answer used once")
	FileDialogQueue_pushPicked(queue, "/tmp/left.txt")
	assert(FileDialogQueue_destroy(queue), "expected the queue freed with no dialog open")
}

@(test)
testPickedFilesGoToTheComposerOnScreen :: proc(t: ^testing.T) {
	_ = t
	defer free_all(context.temp_allocator)
	server := testDirectServer(UI_TEST_SERVER)
	state := testUpdateStateForServer(server)
	defer State_deinit(&state)
	testPrepareRoomSend(&state, UI_TEST_SERVER, ATTACHMENT_TEST_SELF)
	State_serverConnection(&state, UI_TEST_SERVER).attachmentLimits = {
		enabled  = true,
		maxBytes = 1,
	}
	State_switchToChannel(&state, UI_TEST_SERVER, common.GENERAL_ROOM_ID)
	serverID, roomID, peerUserID, ok := State_currentComposer(&state)
	assert(
		ok && serverID == UI_TEST_SERVER && roomID == common.GENERAL_ROOM_ID && peerUserID == 0,
		fmt.tprintf("expected #general on screen, got %d %d %d", serverID, roomID, peerUserID),
	)
	FileDialogQueue_pushPicked(State_fileDialogs(&state), "/nonexistent/picked.txt")
	assert(State_pollFileDialogs(&state), "expected the pick applied")
	chips := State_composerFiles(&state, UI_TEST_SERVER, common.GENERAL_ROOM_ID, 0)
	assert(
		len(chips) == 1 &&
		chips[0].name == "picked.txt" &&
		chips[0].status == .Failed &&
		chips[0].error == "Cannot read the file",
		fmt.tprintf("expected an unreadable pick as a failed chip, got %v", chips),
	)
	// A dropped file goes the same way.
	State_dropFile(&state, "/nonexistent/dropped.txt")
	chips = State_composerFiles(&state, UI_TEST_SERVER, common.GENERAL_ROOM_ID, 0)
	assert(len(chips) == 2 && chips[1].name == "dropped.txt", "expected the dropped file's chip")
	assert(!State_pollFileDialogs(&state), "expected nothing more to apply")
}

@(test)
testTranscriptUnitKeysRoundTrip :: proc(t: ^testing.T) {
	_ = t
	for messageID in ([?]int{0, 1, 41, 1 << 40, -1, -7}) {
		for slot in 0 ..< 8 {
			gotID, gotSlot := transcriptUnitDecode(transcriptUnitKey(messageID, slot))
			assert(
				gotID == messageID && gotSlot == slot,
				fmt.tprintf("expected %d/%d back, got %d/%d", messageID, slot, gotID, gotSlot),
			)
		}
	}
}
