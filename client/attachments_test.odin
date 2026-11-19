package client

import "../common"
import "core:encoding/cbor"
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

attachmentTestFetchBridge :: proc(transport: ^ClientServerTransport, userIDs: []int) -> bool {
	_ = userIDs
	return transport.serverID == ATTACHMENT_TEST_SERVER
}

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
	// F4: a file card per file, with the name, size and media type and Save….
	cards := buildFileCardViews(&state, ATTACHMENT_TEST_SERVER, .Room, 1, 30, shown.files[:])
	assert(
		len(cards) == 2 &&
		cards[0].title == "a.txt" &&
		strings.has_prefix(cards[0].detail, "1000 bytes · ") &&
		cards[0].canSave &&
		cards[1].title == "b.txt",
		fmt.tprintf("expected a card per file, got %v", cards),
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

// Protocol 28 (F3, attachment_moderation.odin): a file an admin removed keeps its message's v2
// signature (removed is never signed), shows as removed, cannot be downloaded, and a live
// ServerAttachmentRemoved marks it in the caches, forgets an unsent upload of it, and gives
// this account's quota the bytes back.
@(test)
testRemovedAttachmentsStaySignedAndAreMarked :: proc(t: ^testing.T) {
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

	// History after a removal: the second file is listed removed, and the signature over the
	// list still verifies.
	fromHistory := refs
	fromHistory[1].removed = true
	attachmentTestDeliver(&state, 40, "report", peerKey, serverKey, refs[:], fromHistory[:])
	entry := attachmentTestEntry(&state, 40)
	assert(
		entry != nil &&
		entry.security.protection == .Plain &&
		len(entry.files) == 2 &&
		!entry.files[0].removed &&
		entry.files[1].removed &&
		entry.files[1].sha256 == refs[1].sha256 &&
		entry.files[1].name == "b.txt",
		fmt.tprintf("expected the message verified with its second file removed, got %v", entry^),
	)
	cards := buildFileCardViews(&state, ATTACHMENT_TEST_SERVER, .Room, 1, entry.id, entry.files[:])
	assert(
		len(cards) == 2 &&
		cards[0].state == .Idle &&
		cards[1].state == .Removed &&
		cards[1].status == common.ATTACHMENT_REMOVED_MESSAGE &&
		!cards[1].canSave,
		fmt.tprintf("expected the removed file's card without Save…, got %v", cards),
	)
	_, removedError := State_downloadMessageAttachment(
		&state,
		ATTACHMENT_TEST_SERVER,
		common.GENERAL_ROOM_ID,
		0,
		40,
		1,
		"/nonexistent/out",
	)
	assert(
		removedError == common.ATTACHMENT_REMOVED_MESSAGE,
		fmt.tprintf("expected the removed file refused, got %q", removedError),
	)

	// A live removal of the first file, which this account also still has as an unsent upload
	// (the case of an admin removing an unbound blob of the owner).
	connection := State_serverConnection(&state, ATTACHMENT_TEST_SERVER)
	connection.attachmentLimits = {enabled = true, maxBytes = 1 << 20, usedBytes = 5000}
	append(
		&state.attachmentUploads,
		UploadedAttachment {
			serverID = ATTACHMENT_TEST_SERVER,
			roomID = common.GENERAL_ROOM_ID,
			blobId = refs[0].blobId,
			storedSize = 1000,
			name = strings.clone("a.txt"),
			mediaType = strings.clone("text/plain"),
		},
	)
	event := ClientTransportRuntimeEvent {
		kind = .AttachmentRemoved,
		serverID = ATTACHMENT_TEST_SERVER,
		attachmentRemoved = {
			blobId = refs[0].blobId,
			roomId = common.GENERAL_ROOM_ID,
			senderId = ATTACHMENT_TEST_SELF,
		},
	}
	State_applyRuntimeEvent(&state, &event)
	ClientTransportRuntimeEvent_deinit(&event)
	entry = attachmentTestEntry(&state, 40)
	assert(
		entry.files[0].removed && entry.attachments[0].removed && entry.files[1].removed,
		"expected the first file marked removed in the entry and its reference",
	)
	assert(len(state.attachmentUploads) == 0, "expected the unsent upload forgotten")
	limits := State_attachmentLimits(&state, ATTACHMENT_TEST_SERVER)
	assert(
		limits.usedBytes == 4000,
		fmt.tprintf("expected the quota to get 1000 bytes back, got %d", limits.usedBytes),
	)
	// Another account's file gives this account's quota nothing.
	marked := State_attachmentRemoved(
		&state,
		ATTACHMENT_TEST_SERVER,
		{blobId = refs[1].blobId, roomId = common.GENERAL_ROOM_ID, senderId = ATTACHMENT_TEST_PEER},
	)
	assert(marked == 1, fmt.tprintf("expected one shown file marked, got %d", marked))
	limits = State_attachmentLimits(&state, ATTACHMENT_TEST_SERVER)
	assert(limits.usedBytes == 4000, "expected another account's file not to count")

	// A removal made in SQL reaches a client only with history: a page fetched again marks a
	// message already cached.
	attachmentTestDeliver(&state, 41, "again", peerKey, serverKey, refs[:], refs[:])
	assert(!attachmentTestEntry(&state, 41).files[0].removed, "expected the file not removed")
	page := [1]common.StoredChatMessage {
		{
			id = 41,
			roomId = common.GENERAL_ROOM_ID,
			attachments = common.AttachmentRefs_clone(fromHistory[:]),
		},
	}
	page[0].attachments[0].removed = true
	defer common.AttachmentRefs_deinit(&page[0].attachments)
	State_receiveRoomHistory(
		&state,
		ATTACHMENT_TEST_SERVER,
		common.GENERAL_ROOM_ID,
		page[:],
		false,
	)
	again := attachmentTestEntry(&state, 41)
	assert(
		again.files[0].removed && again.files[1].removed && again.attachments[0].removed,
		"expected a history page to mark a cached message's files removed",
	)
}

// The moderation packets decode into their runtime events; a bad one is a protocol error.
@(test)
testAttachmentModerationPacketsTranslate :: proc(t: ^testing.T) {
	_ = t
	transport: ClientServerTransport
	transport.serverID = 7
	defer delete(transport.lastError)
	blobId: common.AttachmentBlobID
	blobId[0] = 0xaa
	payload, err := cbor.marshal(
		common.ServerAttachmentRemovedPayload{blobId = blobId, senderId = 3, recipientId = 4},
	)
	assert(err == nil, "expected the notice to encode")
	event, handled := ClientServerTransport_translateAttachmentModerationPacket(
		&transport,
		common.Packet{messageType = .ServerAttachmentRemoved, payload = payload},
	)
	delete(payload)
	assert(
		handled &&
		event.kind == .AttachmentRemoved &&
		event.serverID == 7 &&
		event.attachmentRemoved.blobId == blobId &&
		event.attachmentRemoved.recipientId == 4,
		fmt.tprintf("expected the removal event, got %v", event),
	)
	ClientTransportRuntimeEvent_deinit(&event)

	unset, unsetErr := cbor.marshal(common.ServerAttachmentRemovedPayload{senderId = 3})
	assert(unsetErr == nil, "expected the notice to encode")
	bad, badHandled := ClientServerTransport_translateAttachmentModerationPacket(
		&transport,
		common.Packet{messageType = .ServerAttachmentRemoved, payload = unset},
	)
	delete(unset)
	assert(badHandled && bad.kind == .ProtocolError, "expected a notice without a blob refused")
	ClientTransportRuntimeEvent_deinit(&bad)

	usage := common.ServerAdminAttachmentUsagePayload {
		usedBytes = 12,
		freeBytes = 99,
		freeBytesKnown = true,
	}
	usage.accounts = make([dynamic]common.AttachmentAccountUsage, 0, 1)
	append(&usage.accounts, common.AttachmentAccountUsage{userId = 2, bytes = 12, count = 1})
	usagePayload, usageErr := cbor.marshal(usage)
	delete(usage.accounts)
	assert(usageErr == nil, "expected the usage to encode")
	usageEvent, usageHandled := ClientServerTransport_translateAttachmentModerationPacket(
		&transport,
		common.Packet{messageType = .ServerAdminAttachmentUsage, payload = usagePayload},
	)
	delete(usagePayload)
	assert(
		usageHandled &&
		usageEvent.kind == .AttachmentUsageReceived &&
		usageEvent.attachmentUsage.usedBytes == 12 &&
		len(usageEvent.attachmentUsage.accounts) == 1,
		fmt.tprintf("expected the usage event, got %v", usageEvent),
	)
	// State keeps it per server and takes the accounts.
	defer free_all(context.temp_allocator)
	server := testDirectServer(7)
	state := testUpdateStateForServer(server)
	defer State_deinit(&state)
	_ = State_serverConnection(&state, 7)
	State_applyRuntimeEvent(&state, &usageEvent)
	ClientTransportRuntimeEvent_deinit(&usageEvent)
	kept, keptOK := State_attachmentUsage(&state, 7)
	assert(
		keptOK && kept.usedBytes == 12 && len(kept.accounts) == 1 && kept.accounts[0].userId == 2,
		"expected the usage kept for the server",
	)
}

// A removal request is checked like the server will before it goes out.
@(test)
testAttachmentRemovalRequestValidation :: proc(t: ^testing.T) {
	_ = t
	assert(
		validateAdminRequest(AdminRequest{action = .RemoveAttachment}) ==
		"No attachment selected.",
		"expected a removal without a blob refused",
	)
	blobId: common.AttachmentBlobID
	blobId[3] = 1
	assert(
		validateAdminRequest(
			AdminRequest{action = .RemoveAttachment, blobID = blobId, reason = "a\tb"},
		) ==
		"The reason must be at most 500 bytes long, without control characters.",
		"expected a reason with a tab refused",
	)
	assert(
		validateAdminRequest(
			AdminRequest{action = .RemoveAttachment, blobID = blobId, reason = "spam"},
		) ==
		"",
		"expected a removal with a reason allowed",
	)
}
