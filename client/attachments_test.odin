package client

import "../common"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"

// Attachments on messages in the client (protocol 27, attachments.odin): files are kept only
// for messages whose signature (v2) or seal covers them, a sealed message's outer list must be
// its inner one, uploads are named, labelled and checked against the server's limits before
// they start, and a message names only this conversation's uploads with its own encryption.

ATTACHMENT_TEST_SERVER :: 982
ATTACHMENT_TEST_SELF :: 50
ATTACHMENT_TEST_PEER :: 51

@(private = "file")
attachmentTestFetchBridge :: proc(transport: ^ClientServerTransport, userIDs: []int) -> bool {
	_ = userIDs
	return transport.serverID == ATTACHMENT_TEST_SERVER
}

@(private = "file")
attachmentTestRefs :: proc() -> [2]common.AttachmentRef {
	refs: [2]common.AttachmentRef
	for index in 0 ..< 2 {
		for byteIndex in 0 ..< common.ATTACHMENT_BLOB_ID_SIZE {
			refs[index].blobId[byteIndex] = u8(0x40 + index * 16 + byteIndex)
		}
		refs[index].sha256[7] = u8(index + 9)
		refs[index].size = u64(1000 * (index + 1))
		refs[index].mediaType = "text/plain"
	}
	refs[0].name = "a.txt"
	refs[1].name = "b.txt"
	return refs
}

// A live plaintext room message from the peer listing listed, signed by privateKey over
// signedRefs (the v2 label when there are any).
@(private = "file")
attachmentTestDeliver :: proc(
	state: ^State,
	messageID: int,
	content: string,
	privateKey: common.IdentityPrivateKeyBytes,
	serverKey: common.IdentityPublicKeyBytes,
	signedRefs: []common.AttachmentRef,
	listed: []common.AttachmentRef,
) {
	event := ClientTransportRuntimeEvent {
		kind            = .RoomChatReceived,
		serverID        = ATTACHMENT_TEST_SERVER,
		roomID          = common.GENERAL_ROOM_ID,
		senderID        = ATTACHMENT_TEST_PEER,
		senderNickname  = strings.clone("peer"),
		messageID       = messageID,
		timestamp       = strings.clone("t"),
		message         = strings.clone(content),
		clientMessageID = testMessageClientID(messageID, 5),
		attachments     = common.AttachmentRefs_clone(listed),
	}
	signature, ok := common.signPlaintextRoomMessage(
		common.PlaintextRoomMessageFields {
			serverIdentityPublicKey = serverKey,
			roomID = common.GENERAL_ROOM_ID,
			senderUserID = ATTACHMENT_TEST_PEER,
			clientMessageID = event.clientMessageID,
		},
		content,
		privateKey,
		signedRefs,
	)
	assert(ok, "expected the test message to sign")
	event.signature = signature
	State_applyRuntimeEvent(state, &event)
	ClientTransportRuntimeEvent_deinit(&event)
}

@(private = "file")
attachmentTestEntry :: proc(state: ^State, messageID: int) -> ^RoomMessageEntry {
	cache := State_serverRoomCache(state, ATTACHMENT_TEST_SERVER)
	room := ServerRoomCache_roomCache(cache, common.GENERAL_ROOM_ID)
	for &entry in room.messages {
		if entry.id == messageID {
			return &entry
		}
	}
	return nil
}

@(test)
testRoomMessageFilesNeedTheirSendersSignature :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&e2eeSendBridgeTestMutex)
	defer sync.mutex_unlock(&e2eeSendBridgeTestMutex)
	e2eeFetchBridge = attachmentTestFetchBridge
	defer e2eeFetchBridge = ClientServerTransport_fetchUserKeys
	defer free_all(context.temp_allocator)

	server := testDirectServer(ATTACHMENT_TEST_SERVER)
	state := testUpdateStateForServer(server)
	defer State_deinit(&state)
	testPrepareRoomSend(&state, ATTACHMENT_TEST_SERVER, ATTACHMENT_TEST_SELF)
	serverKey, peerKey := testMessageSigner(&state, ATTACHMENT_TEST_SERVER, ATTACHMENT_TEST_PEER)

	refs := attachmentTestRefs()
	// The v2 signature covers the list: the message is shown with both files.
	attachmentTestDeliver(&state, 30, "", peerKey, serverKey, refs[:], refs[:])
	shown := attachmentTestEntry(&state, 30)
	assert(
		shown != nil && shown.security.protection == .Plain && len(shown.files) == 2,
		fmt.tprintf("expected the message shown with its files, got %v", shown^),
	)
	assert(
		shown.files[0].name == "a.txt" &&
		shown.files[0].storedSize == 1000 &&
		shown.files[0].fileSize == 1000 &&
		shown.files[0].sha256 == refs[0].sha256 &&
		!shown.files[0].encrypted &&
		shown.files[1].blobId == refs[1].blobId,
		"expected the files as the message signed them",
	)
	text := messageTextWithFiles(shown.content, shown.files[:], shown.filesChanged)
	assert(
		strings.contains(text, "Attachment: a.txt (1000 bytes)") &&
		strings.contains(text, "Attachment: b.txt"),
		fmt.tprintf("expected a line per file in the transcript text, got %q", text),
	)
	files, changed, found := State_messageFiles(
		&state,
		ATTACHMENT_TEST_SERVER,
		common.GENERAL_ROOM_ID,
		0,
		30,
	)
	assert(found && !changed && len(files) == 2, "expected State_messageFiles to find them")

	// A list the server changed, or added to a v1 message, fails the signature: not shown.
	tampered := refs
	tampered[1].name = "c.txt"
	attachmentTestDeliver(&state, 31, "two", peerKey, serverKey, refs[:], tampered[:])
	attachmentTestDeliver(&state, 32, "plain", peerKey, serverKey, nil, refs[:1])
	attachmentTestDeliver(&state, 33, "dropped", peerKey, serverKey, refs[:], refs[:1])
	for messageID in ([]int{31, 32, 33}) {
		entry := attachmentTestEntry(&state, messageID)
		assert(
			entry != nil &&
			entry.security == {protection = .Hidden, failure = .BadSignature} &&
			len(entry.files) == 0,
			fmt.tprintf("expected message %d hidden without files, got %v", messageID, entry^),
		)
	}
	_, _, hiddenFound := State_messageFiles(
		&state,
		ATTACHMENT_TEST_SERVER,
		common.GENERAL_ROOM_ID,
		0,
		31,
	)
	assert(!hiddenFound, "expected no files for a hidden message")
	_, downloadError := State_downloadMessageAttachment(
		&state,
		ATTACHMENT_TEST_SERVER,
		common.GENERAL_ROOM_ID,
		0,
		31,
		0,
		"/nonexistent/out",
	)
	assert(downloadError == "Unknown message", "expected a hidden message's file refused")
}

@(test)
testSealedMessageFilesMustMatchTheOuterList :: proc(t: ^testing.T) {
	_ = t
	refs := attachmentTestRefs()
	inner: [2]common.SealedAttachment
	outer: [2]common.AttachmentRef
	for index in 0 ..< 2 {
		inner[index] = common.SealedAttachment {
			blobId    = refs[index].blobId,
			key       = {0 = u8(index + 1)},
			sha256    = refs[index].sha256,
			size      = refs[index].size,
			name      = refs[index].name,
			mediaType = refs[index].mediaType,
		}
		layout, _ := common.attachmentEncryptedLayout(refs[index].size)
		outer[index] = {
			blobId = refs[index].blobId,
			size   = layout.storedSize,
		}
	}
	outer[1].removed = true
	files, changed := messageFilesFromSealed(outer[:], inner[:])
	defer MessageFiles_deinit(&files)
	assert(!changed && len(files) == 2, "expected matching lists to give both files")
	assert(
		files[0].encrypted &&
		files[0].key == inner[0].key &&
		files[0].fileSize == 1000 &&
		files[0].storedSize == outer[0].size &&
		files[1].removed,
		"expected the sealed fields, the stored size and the server's removed flag",
	)
	// The server listed other blobs, another order, more or fewer, or another size.
	swapped := [2]common.AttachmentRef{outer[1], outer[0]}
	fewer := outer[:1]
	resized := outer
	resized[0].size += 16
	other := outer
	other[1].blobId[0] ~= 0xFF
	for wrong, index in ([][]common.AttachmentRef{swapped[:], fewer, resized[:], other[:], nil}) {
		changedFiles, wasChanged := messageFilesFromSealed(wrong, inner[:])
		assert(
			wasChanged && len(changedFiles) == 0,
			fmt.tprintf("expected outer list %d marked changed without files", index),
		)
	}
	// A message without files has none on either side.
	none, noneChanged := messageFilesFromSealed(nil, nil)
	assert(!noneChanged && len(none) == 0, "expected no files and no change")
	changedText := messageTextWithFiles("hi", nil, true)
	assert(
		changedText == "hi\n" + common.ATTACHMENT_LIST_CHANGED_MESSAGE,
		fmt.tprintf("expected the changed sentence, got %q", changedText),
	)
}

@(test)
testAttachmentNamesAndMediaTypes :: proc(t: ^testing.T) {
	_ = t
	defer free_all(context.temp_allocator)
	cases := [?][2]string {
		{"/home/a/report.pdf", "report.pdf"},
		{"notes.txt", "notes.txt"},
		{"/tmp/tab\there.txt", "tab_here.txt"},
		{"/tmp/", "file"},
	}
	for c in cases {
		name := attachmentNameFromPath(c[0])
		assert(name == c[1], fmt.tprintf("expected %q named %q, got %q", c[0], c[1], name))
		assert(common.attachmentNameIsValid(name), "expected every name to be valid")
	}
	long := strings.repeat("é", 200, context.temp_allocator)
	cut := attachmentNameFromPath(long)
	assert(
		len(cut) <= common.ATTACHMENT_NAME_MAX_BYTES && common.attachmentNameIsValid(cut),
		"expected a long name cut at a character boundary",
	)
	assert(attachmentMediaTypeFor("photo.JPG") == "image/jpeg", "expected the jpeg label")
	assert(
		attachmentMediaTypeFor("archive.tar.xz") == common.ATTACHMENT_DEFAULT_MEDIA_TYPE,
		"expected the default label for an unknown extension",
	)
	assert(attachmentSizeText(1536) == "1.5 KB", "expected a readable size")
}

@(test)
testMessagesNameOnlyTheirConversationsUploads :: proc(t: ^testing.T) {
	_ = t
	defer free_all(context.temp_allocator)
	state: State
	defer State_attachmentsDeinit(&state)
	refs := attachmentTestRefs()
	append(
		&state.attachmentUploads,
		UploadedAttachment {
			serverID = 7,
			roomID = 3,
			blobId = refs[0].blobId,
			storedSize = 1000,
			fileSize = 1000,
			sha256 = refs[0].sha256,
			name = strings.clone("a.txt"),
			mediaType = strings.clone("text/plain"),
		},
		UploadedAttachment {
			serverID = 7,
			roomID = 3,
			blobId = refs[1].blobId,
			encrypted = true,
			key = {0 = 9},
			storedSize = 2400,
			fileSize = 2000,
			sha256 = refs[1].sha256,
			name = strings.clone("b.txt"),
			mediaType = strings.clone("text/plain"),
		},
	)
	plain, _, plainError := State_attachmentsForMessage(&state, 7, 3, 0, {refs[0].blobId}, false)
	assert(
		plainError == "" &&
		len(plain) == 1 &&
		plain[0].name == "a.txt" &&
		plain[0].sha256 == refs[0].sha256 &&
		plain[0].size == 1000,
		"expected a complete plaintext reference",
	)
	outer, entries, sealedError := State_attachmentsForMessage(
		&state,
		7,
		3,
		0,
		{refs[1].blobId},
		true,
	)
	defer attachmentEntriesWipe(entries)
	assert(
		sealedError == "" &&
		len(outer) == 1 &&
		outer[0].size == 2400 &&
		outer[0].sha256 == {} &&
		outer[0].name == "" &&
		entries[0].key == {0 = 9} &&
		entries[0].size == 2000,
		"expected an outer reference and a sealed entry with the key",
	)
	refusals := [?]struct {
		roomID, recipientID: int,
		blobIds:             []common.AttachmentBlobID,
		sealed:              bool,
		expected:            string,
	} {
		{4, 0, {refs[0].blobId}, false, "That file was not uploaded to this conversation"},
		{0, 9, {refs[0].blobId}, false, "That file was not uploaded to this conversation"},
		{3, 0, {refs[0].blobId}, true, "That file was uploaded unencrypted; upload it again"},
		{3, 0, {refs[1].blobId}, false, "That file was uploaded encrypted; upload it again"},
		{3, 0, {refs[0].blobId, refs[0].blobId}, false, "The same file is attached twice"},
		{3, 0, {{0 = 1}}, false, "That file was not uploaded to this conversation"},
	}
	for refusal in refusals {
		_, _, refused := State_attachmentsForMessage(
			&state,
			7,
			refusal.roomID,
			refusal.recipientID,
			refusal.blobIds,
			refusal.sealed,
		)
		assert(
			refused == refusal.expected,
			fmt.tprintf("expected %q, got %q", refusal.expected, refused),
		)
	}
	// An echo of this account's own message forgets the uploads it bound.
	State_attachmentsNoteBound(&state, 7, plain)
	assert(
		len(state.attachmentUploads) == 1 &&
		State_findUploadedAttachment(&state, 7, refs[0].blobId) == nil,
		"expected the bound upload forgotten",
	)
}

@(test)
testUploadsAreCheckedAgainstTheServersLimits :: proc(t: ^testing.T) {
	_ = t
	defer free_all(context.temp_allocator)
	server := testDirectServer(ATTACHMENT_TEST_SERVER)
	state := testUpdateStateForServer(server)
	defer State_deinit(&state)
	testPrepareRoomSend(&state, ATTACHMENT_TEST_SERVER, ATTACHMENT_TEST_SELF)
	dir := configTestCreateTempDir("haychat_attachment_limits")
	defer os.remove_all(dir)
	path := fmt.tprintf("%s/five.bin", dir)
	assert(
		os.write_entire_file_from_bytes(path, transmute([]u8)string("12345"), os.perm(0o600)) ==
		nil,
		"expected a file",
	)
	empty := fmt.tprintf("%s/empty.bin", dir)
	assert(
		os.write_entire_file_from_bytes(empty, nil, os.perm(0o600)) == nil,
		"expected an empty file",
	)

	connection := State_serverConnection(&state, ATTACHMENT_TEST_SERVER)
	connection.attachmentLimits = {enabled = false}
	_, disabled := State_uploadAttachment(&state, ATTACHMENT_TEST_SERVER, 1, 0, path)
	assert(
		disabled == common.ATTACHMENTS_DISABLED_MESSAGE,
		fmt.tprintf("expected uploads refused while disabled, got %q", disabled),
	)
	connection = State_serverConnection(&state, ATTACHMENT_TEST_SERVER)
	connection.attachmentLimits = {enabled = true, maxBytes = 4}
	_, large := State_uploadAttachment(&state, ATTACHMENT_TEST_SERVER, 1, 0, path)
	assert(large == common.ATTACHMENT_TOO_LARGE_MESSAGE, "expected a file over the limit refused")
	connection = State_serverConnection(&state, ATTACHMENT_TEST_SERVER)
	connection.attachmentLimits = {enabled = true, maxBytes = 100, quotaBytes = 10, usedBytes = 6}
	_, quota := State_uploadAttachment(&state, ATTACHMENT_TEST_SERVER, 1, 0, path)
	assert(quota == common.ATTACHMENT_QUOTA_MESSAGE, "expected a file over the quota refused")
	_, emptyError := State_uploadAttachment(&state, ATTACHMENT_TEST_SERVER, 1, 0, empty)
	assert(emptyError == "The file is empty", "expected an empty plaintext file refused")
	_, both := State_uploadAttachment(&state, ATTACHMENT_TEST_SERVER, 1, 2, path)
	assert(both == common.ATTACHMENT_INVALID_REQUEST_MESSAGE, "expected one conversation only")
	_, missing := State_uploadAttachment(&state, ATTACHMENT_TEST_SERVER, 1, 0, "/nonexistent/x")
	assert(missing == "Cannot read the file", "expected an unreadable file refused")
}
