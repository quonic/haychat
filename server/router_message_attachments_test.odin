package server

import "../common"
import "core:encoding/cbor"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:testing"

// Attachments on messages in the router (protocol 27, attachments plan F2): the shape checks
// and the v2 signature before the database, the binding refusals' sentences, the fanout of
// the bound references, and the limits ServerAuthSuccess announces.

@(private = "file")
routerAttachmentTestRefs :: proc() -> [2]common.AttachmentRef {
	refs: [2]common.AttachmentRef
	for index in 0 ..< 2 {
		for byteIndex in 0 ..< common.ATTACHMENT_BLOB_ID_SIZE {
			refs[index].blobId[byteIndex] = u8(index * 16 + byteIndex + 1)
		}
		refs[index].sha256[0] = u8(index + 1)
		refs[index].size = u64(100 * (index + 1))
		refs[index].mediaType = "text/plain"
	}
	refs[0].name = "a.txt"
	refs[1].name = "b.txt"
	return refs
}

// A plaintext room message with attachments, signed with the v2 label by identityKey.
@(private = "file")
routerAttachmentTestChat :: proc(
	h: ^RouterTestHarness,
	identityKey: common.IdentityPrivateKeyBytes,
	roomID, userID: int,
	content: string,
	refs: []common.AttachmentRef,
	attachments: ^[dynamic]common.AttachmentRef,
) -> common.ClientChatMessagePayload {
	chat := common.ClientChatMessagePayload {
		roomId  = roomID,
		content = content,
	}
	assert(common.generateRandomBytes(chat.clientMessageId[:]), "expected a random message ID")
	chat.clientMessageId[0] |= 1
	signature, ok := common.signPlaintextRoomMessage(
		common.PlaintextRoomMessageFields {
			serverIdentityPublicKey = h.state.serverIdentityPublicKey,
			roomID = roomID,
			senderUserID = userID,
			clientMessageID = chat.clientMessageId,
		},
		content,
		identityKey,
		refs,
	)
	assert(ok, "expected the v2 room message to sign")
	chat.signature = signature
	attachments^ = make([dynamic]common.AttachmentRef, context.temp_allocator)
	append(attachments, ..refs)
	chat.attachments = attachments^
	return chat
}

@(test)
testMainRouterChecksRoomMessageAttachments :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)

	senderPeerID, recipientPeerID := u32(1), u32(2)
	h.state.connectedPeers[recipientPeerID] = true
	senderKey: common.IdentityPrivateKeyBytes
	senderTransport := routerCompleteHandshake(
		&h,
		senderPeerID,
		42,
		identityPrivateKeyOut = &senderKey,
	)
	defer common.TransportState_deinit(&senderTransport)
	recipientTransport := routerCompleteHandshake(&h, recipientPeerID, 43, nickname = "other")
	defer common.TransportState_deinit(&recipientTransport)
	peers := [?]RouterTestPeer {
		{senderPeerID, &senderTransport},
		{recipientPeerID, &recipientTransport},
	}
	// The second sign-in announced the second account to the first.
	_, presence := routerTestReceivePresence(&h, peers[:])
	delete(presence.nickname)

	refs := routerAttachmentTestRefs()
	list: [dynamic]common.AttachmentRef
	signed := routerAttachmentTestChat(&h, senderKey, 1, 42, "", refs[:], &list)

	// Shapes the router refuses before the database: too many, a repeated blob, a bad name, a
	// missing hash, and a plaintext reference marked removed by the client.
	five := make([dynamic]common.AttachmentRef, context.temp_allocator)
	for index in 0 ..< 5 {
		ref := refs[0]
		ref.blobId[0] = u8(200 + index)
		append(&five, ref)
	}
	repeated := make([dynamic]common.AttachmentRef, context.temp_allocator)
	append(&repeated, refs[0], refs[0])
	badName := make([dynamic]common.AttachmentRef, context.temp_allocator)
	append(&badName, refs[0])
	badName[0].name = "../a.txt"
	noHash := make([dynamic]common.AttachmentRef, context.temp_allocator)
	append(&noHash, refs[0])
	noHash[0].sha256 = {}
	removed := make([dynamic]common.AttachmentRef, context.temp_allocator)
	append(&removed, refs[0])
	removed[0].removed = true
	for bad in ([][dynamic]common.AttachmentRef{five, repeated, badName, noHash, removed}) {
		message := signed
		message.attachments = bad
		routerTestSendSealed(&h, &senderTransport, senderPeerID, .ClientChatMessage, message)
		routerTestExpectProtocolError(&h, peers[:], common.ATTACHMENT_REFS_INVALID_MESSAGE)
		routerTestExpectNoDatabaseQuery(&h, "expected bad attachments to stay local")
	}
	// The v2 signature covers the list: a v1 signature, or a dropped attachment, fails.
	v1 := routerTestSignedChat(&h, senderKey, 1, 42, "with files")
	v1.attachments = list
	stripped := signed
	stripped.attachments = make([dynamic]common.AttachmentRef, context.temp_allocator)
	append(&stripped.attachments, refs[0])
	for message in ([]common.ClientChatMessagePayload{v1, stripped}) {
		routerTestSendSealed(&h, &senderTransport, senderPeerID, .ClientChatMessage, message)
		routerTestExpectProtocolError(&h, peers[:], common.ROOM_MESSAGE_SIGNATURE_INVALID_MESSAGE)
		routerTestExpectNoDatabaseQuery(&h, "expected an unsigned list to stay local")
	}
	// Empty content is allowed with attachments only.
	empty := routerTestSignedChat(&h, senderKey, 1, 42, "x")
	empty.content = ""
	routerTestSendSealed(&h, &senderTransport, senderPeerID, .ClientChatMessage, empty)
	routerTestExpectProtocolError(&h, peers[:], "Invalid room chat message")
	// A sealed message's outer list carries no hash or name.
	sealedChat := common.ClientChatMessagePayload {
		roomId          = 1,
		clientMessageId = signed.clientMessageId,
		sealed          = {1, 2, 3},
		attachments     = list,
	}
	routerTestSendSealed(&h, &senderTransport, senderPeerID, .ClientChatMessage, sealedChat)
	routerTestExpectProtocolError(&h, peers[:], common.ATTACHMENT_REFS_INVALID_MESSAGE)

	// The signed message reaches the database with its list.
	refusals := [?]struct {
		result:  common.DatabasePostRoomChatMessageResult,
		message: string,
	} {
		{{isMember = true, attachDenied = true}, common.ATTACHMENT_SEND_NOT_PERMITTED_MESSAGE},
		{{isMember = true, attachmentsRefused = true}, common.ATTACHMENT_BIND_REFUSED_MESSAGE},
	}
	for refusal in refusals {
		routerTestSendSealed(&h, &senderTransport, senderPeerID, .ClientChatMessage, signed)
		query := routerPollDatabaseQuery(&h)
		request, isPost := query.request.(common.DatabasePostRoomChatMessageRequest)
		assert(isPost && len(request.attachments) == 2, "expected the list in the request")
		assert(
			request.attachments[0].blobId == refs[0].blobId &&
			request.attachments[1].name == "b.txt" &&
			request.content == "",
			"expected the references and the empty content passed on",
		)
		IPC__database_query_request_deinit(query.request)
		MainRouterState_handleDatabaseResult(
			&h.pm,
			&h.state,
			query.request_id,
			common.DatabaseQueryResponse{success = true, result = refusal.result},
		)
		routerTestExpectProtocolError(&h, peers[:], refusal.message)
	}

	// A stored message fans out with its references.
	routerTestSendSealed(&h, &senderTransport, senderPeerID, .ClientChatMessage, signed)
	query := routerPollDatabaseQuery(&h)
	IPC__database_query_request_deinit(query.request)
	recipients := make([dynamic]int)
	append(&recipients, 42, 43)
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		query.request_id,
		common.DatabaseQueryResponse {
			success = true,
			result = common.DatabasePostRoomChatMessageResult {
				isMember = true,
				storedMessage = {
					id = 9,
					senderId = 42,
					senderNickname = strings.clone("router-tester"),
					roomId = 1,
					timestamp = strings.clone("now"),
					content = strings.clone(""),
					clientMessageId = signed.clientMessageId,
					signature = signed.signature,
					attachments = common.AttachmentRefs_clone(refs[:]),
				},
				recipientUserIDs = recipients,
			},
		},
	)
	for _ in 0 ..< 2 {
		peerID, packet := routerTestReceive(&h, peers[:])
		defer delete(packet.payload)
		assert(packet.messageType == .ServerChatMessage, "expected the stored message")
		payload: common.ServerChatMessagePayload
		assert(
			cbor.unmarshal(packet.payload, &payload, temp_allocator = context.allocator) == nil,
			"expected the chat message to decode",
		)
		defer common.ServerChatMessagePayload_deinit(&payload)
		assert(
			len(payload.attachments) == 2 &&
			payload.attachments[0].name == "a.txt" &&
			payload.attachments[1].size == 200,
			fmt.tprintf("expected peer %d to receive the attachments", peerID),
		)
	}
}

@(test)
testMainRouterChecksDirectMessageAttachments :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)

	peerID := u32(1)
	senderKey: common.IdentityPrivateKeyBytes
	transport := routerCompleteHandshake(&h, peerID, 42, identityPrivateKeyOut = &senderKey)
	defer common.TransportState_deinit(&transport)
	peers := [?]RouterTestPeer{{peerID, &transport}}
	refs := routerAttachmentTestRefs()
	clientMessageID := common.ClientMessageID{0 = 7, 15 = 7}
	fields := common.PlaintextDirectMessageFields {
		serverIdentityPublicKey = h.state.serverIdentityPublicKey,
		senderUserID            = 42,
		recipientUserID         = 43,
		clientMessageID         = clientMessageID,
	}
	signature, ok := common.signPlaintextDirectMessage(fields, "", senderKey, refs[:1])
	assert(ok, "expected the v2 direct message to sign")
	list := make([dynamic]common.AttachmentRef, context.temp_allocator)
	append(&list, refs[0])
	direct := common.ClientDirectMessagePayload {
		recipientUserId = 43,
		clientMessageId = clientMessageID,
		signature       = signature,
		attachments     = list,
	}
	// Without the list the empty content is invalid; with another list the signature fails.
	bare := direct
	bare.attachments = nil
	routerTestSendSealed(&h, &transport, peerID, .ClientDirectMessage, bare)
	routerTestExpectProtocolError(&h, peers[:], "Invalid direct message")
	other := make([dynamic]common.AttachmentRef, context.temp_allocator)
	append(&other, refs[1])
	swapped := direct
	swapped.attachments = other
	routerTestSendSealed(&h, &transport, peerID, .ClientDirectMessage, swapped)
	routerTestExpectProtocolError(&h, peers[:], common.DIRECT_MESSAGE_SIGNATURE_INVALID_MESSAGE)
	routerTestExpectNoDatabaseQuery(&h, "expected the refused messages to stay local")

	routerTestSendSealed(&h, &transport, peerID, .ClientDirectMessage, direct)
	query := routerPollDatabaseQuery(&h)
	request, isPost := query.request.(common.DatabasePostDirectMessageRequest)
	assert(
		isPost && len(request.attachments) == 1 && request.attachments[0].name == "a.txt",
		"expected the direct message's list in the request",
	)
	IPC__database_query_request_deinit(query.request)
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		query.request_id,
		common.DatabaseQueryResponse {
			success = true,
			result = common.DatabasePostDirectMessageResult{outcome = .AttachmentsRefused},
		},
	)
	routerTestExpectProtocolError(&h, peers[:], common.ATTACHMENT_BIND_REFUSED_MESSAGE)

	// A sealed direct message's outer list carries only blob IDs and sizes.
	full := make([dynamic]common.AttachmentRef, context.temp_allocator)
	append(&full, refs[0])
	sealed := common.ClientSealedDirectMessagePayload {
		recipientUserId = 43,
		clientMessageId = clientMessageID,
		envelope        = {1, 2, 3},
		attachments     = full,
	}
	routerTestSendSealed(&h, &transport, peerID, .ClientSealedDirectMessage, sealed)
	routerTestExpectProtocolError(&h, peers[:], common.ATTACHMENT_REFS_INVALID_MESSAGE)
	routerTestExpectNoDatabaseQuery(&h, "expected the sealed message to stay local")
}

// D18: ServerAuthSuccess announces the configured limits and the account's stored bytes.
@(test)
testMainRouterAnnouncesAttachmentLimits :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)
	h.pm.config.attachmentsEnabled = true
	h.pm.config.attachmentMaxBytes = 25 << 20
	h.pm.config.attachmentAccountQuotaBytes = 1 << 30
	limits: common.AttachmentLimits
	transport := routerCompleteHandshake(
		&h,
		1,
		42,
		attachmentUsedBytes = 12345,
		attachmentLimitsOut = &limits,
	)
	defer common.TransportState_deinit(&transport)
	assert(
		limits ==
		common.AttachmentLimits {
			enabled = true,
			maxBytes = 25 << 20,
			quotaBytes = 1 << 30,
			usedBytes = 12345,
		},
		fmt.tprintf("expected the configured limits announced, got %v", limits),
	)
}
