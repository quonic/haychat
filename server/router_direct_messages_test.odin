package server

import "../common"
import "core:encoding/cbor"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:testing"

// Router tests for direct messages, the user directory, and presence. They reuse the harness
// in router_test.odin. Each client transport accepts only the next sequence number, so every
// packet a test session is sent must be opened in order, presence notices included.

RouterTestPeer :: struct {
	peerID:    u32,
	transport: ^common.TransportState,
}

routerTestSendSealed :: proc(
	h: ^RouterTestHarness,
	transport: ^common.TransportState,
	peerID: u32,
	messageType: common.MessageType,
	payload: any,
) {
	sealedPacket, sealOK := common.sealPacketForSession(transport, messageType, payload)
	assert(sealOK, fmt.tprintf("expected %v packet sealing to succeed", messageType))
	defer delete(sealedPacket.payload)
	sealedPacketBytes := routerEncodePacketBytes(sealedPacket)
	defer delete(sealedPacketBytes)
	MainRouterState_handleNetworkDataReceived(
		&h.pm,
		&h.state,
		NetworkDataReceived{peerId = peerID, channel = .Chat, data = sealedPacketBytes},
	)
}

// Opens the next queued network message with the transport of the peer it is addressed to.
// The caller frees the returned packet's payload.
routerTestReceive :: proc(h: ^RouterTestHarness, peers: []RouterTestPeer) -> (u32, common.Packet) {
	send := routerPollNetworkSend(h)
	defer delete(send.data)
	outerPacket := routerDecodePacketBytes(send.data)
	defer delete(outerPacket.payload)
	for peer in peers {
		if peer.peerID == send.peerId {
			innerPacket, openOK := common.openPacketForSession(peer.transport, outerPacket)
			assert(openOK, fmt.tprintf("expected peer %d to decrypt its message", send.peerId))
			return send.peerId, innerPacket
		}
	}
	assert(false, fmt.tprintf("expected no message for peer %d", send.peerId))
	return send.peerId, {}
}

routerTestExpectNoNetworkMessage :: proc(h: ^RouterTestHarness, why: string) {
	_, err := IPC_Client_poll(h.networkFd)
	assert(err != nil, why)
}

routerTestExpectNoDatabaseQuery :: proc(h: ^RouterTestHarness, why: string) {
	_, err := IPC_Client_poll(h.databaseFd)
	assert(err != nil, why)
}

routerTestReceivePresence :: proc(
	h: ^RouterTestHarness,
	peers: []RouterTestPeer,
) -> (
	u32,
	common.ServerUserPresencePayload,
) {
	peerID, packet := routerTestReceive(h, peers)
	defer delete(packet.payload)
	assert(
		packet.messageType == .ServerUserPresence,
		fmt.tprintf("expected ServerUserPresence for peer %d, got %v", peerID, packet.messageType),
	)
	presence: common.ServerUserPresencePayload
	assert(cbor.unmarshal(packet.payload, &presence) == nil, "expected presence decode to succeed")
	return peerID, presence
}

// Consumes a presence notice the test does not inspect, freeing its nickname.
routerTestSkipPresence :: proc(h: ^RouterTestHarness, peers: []RouterTestPeer) {
	_, presence := routerTestReceivePresence(h, peers)
	delete(presence.nickname)
}

routerTestExpectProtocolError :: proc(
	h: ^RouterTestHarness,
	peers: []RouterTestPeer,
	expectedMessage: string,
) {
	peerID, packet := routerTestReceive(h, peers)
	defer delete(packet.payload)
	assert(
		packet.messageType == .ServerProtocolError,
		fmt.tprintf("expected ServerProtocolError for peer %d, got %v", peerID, packet.messageType),
	)
	errorPayload: common.ProtocolErrorResponse
	assert(
		cbor.unmarshal(packet.payload, &errorPayload) == nil,
		"expected protocol error decode to succeed",
	)
	defer delete(errorPayload.message)
	assert(
		errorPayload.message == expectedMessage,
		fmt.tprintf("expected protocol error %q, got %q", expectedMessage, errorPayload.message),
	)
}

@(test)
testMainRouterDirectMessageReachesEverySessionOfBothUsers :: proc(t: ^testing.T) {
	_ = t

	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)

	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)

	senderPeerID := u32(1)
	recipientPeerID := u32(2)
	senderSecondPeerID := u32(3)
	bystanderPeerID := u32(4)
	unauthenticatedPeerID := u32(5)
	for peerID in ([]u32{recipientPeerID, senderSecondPeerID, bystanderPeerID}) {
		h.state.connectedPeers[peerID] = true
	}
	h.state.connectedPeers[unauthenticatedPeerID] = true
	MainRouterState_setPeerSession(&h.state, unauthenticatedPeerID, RouterPeerSession_init())

	senderTransport := routerCompleteHandshake(&h, senderPeerID, 42)
	peers := [?]RouterTestPeer {
		{senderPeerID, &senderTransport},
		{recipientPeerID, nil},
		{senderSecondPeerID, nil},
		{bystanderPeerID, nil},
	}
	recipientTransport := routerCompleteHandshake(&h, recipientPeerID, 43)
	peers[1].transport = &recipientTransport
	routerTestSkipPresence(&h, peers[:])
	senderSecondTransport := routerCompleteHandshake(&h, senderSecondPeerID, 42)
	peers[2].transport = &senderSecondTransport
	bystanderTransport := routerCompleteHandshake(&h, bystanderPeerID, 44)
	peers[3].transport = &bystanderTransport
	for _ in 0 ..< 3 {
		routerTestSkipPresence(&h, peers[:])
	}
	routerTestExpectNoNetworkMessage(&h, "expected only the presence notices so far")

	routerTestSendSealed(
		&h,
		&senderTransport,
		senderPeerID,
		.ClientDirectMessage,
		common.ClientDirectMessagePayload{recipientUserId = 43, content = "psst"},
	)
	postQuery := routerPollDatabaseQuery(&h)
	defer IPC__database_query_request_deinit(postQuery.request)
	postRequest, postRequestOK := postQuery.request.(common.DatabasePostDirectMessageRequest)
	assert(postRequestOK, "expected a direct message to be one post-direct-message request")
	assert(
		postRequest.senderId == 42 &&
		postRequest.recipientId == 43 &&
		postRequest.content == "psst",
		fmt.tprintf("expected the authenticated sender and the content, got %v", postRequest),
	)

	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		postQuery.request_id,
		common.DatabaseQueryResponse {
			success = true,
			result = common.DatabasePostDirectMessageResult {
				recipientExists = true,
				storedMessage = {
					id = 77,
					senderId = 42,
					senderNickname = strings.clone("alice"),
					recipientId = 43,
					recipientNickname = strings.clone("bob"),
					timestamp = strings.clone("2026-11-05 10:00:00+00"),
					content = strings.clone("psst"),
				},
			},
		},
	)
	routerTestExpectNoDatabaseQuery(&h, "expected a direct message to need one database trip")

	seen := map[u32]bool{}
	defer delete(seen)
	for _ in 0 ..< 3 {
		peerID, packet := routerTestReceive(&h, peers[:])
		defer delete(packet.payload)
		assert(
			packet.messageType == .ServerDirectMessage,
			fmt.tprintf("expected ServerDirectMessage, got %v", packet.messageType),
		)
		assert(
			peerID != bystanderPeerID,
			"expected a direct message not to reach other users' sessions",
		)
		directPayload: common.ServerDirectMessagePayload
		assert(
			cbor.unmarshal(packet.payload, &directPayload) == nil,
			"expected direct message decode to succeed",
		)
		defer {
			delete(directPayload.senderNickname)
			delete(directPayload.recipientNickname)
			delete(directPayload.timestamp)
			delete(directPayload.content)
		}
		assert(
			directPayload.id == 77 &&
			directPayload.senderId == 42 &&
			directPayload.recipientId == 43 &&
			directPayload.senderNickname == "alice" &&
			directPayload.recipientNickname == "bob" &&
			directPayload.content == "psst",
			fmt.tprintf("expected the stored direct message fields, got %v", directPayload),
		)
		seen[peerID] = true
	}
	assert(seen[senderPeerID], "expected the sending session to get the echo")
	assert(seen[senderSecondPeerID], "expected the sender's other session to get the message")
	assert(seen[recipientPeerID], "expected the recipient to get the message")
	routerTestExpectNoNetworkMessage(&h, "expected exactly one copy per session of both users")
}

@(test)
testMainRouterRejectsInvalidDirectMessages :: proc(t: ^testing.T) {
	_ = t

	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)

	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)

	peerID := u32(1)
	transport := routerCompleteHandshake(&h, peerID, 42)
	peers := [?]RouterTestPeer{{peerID, &transport}}

	tooLong := strings.repeat("x", common.CHAT_MESSAGE_MAX_BYTES + 1)
	defer delete(tooLong)
	invalidCases := [?]struct {
		payload:  common.ClientDirectMessagePayload,
		expected: string,
	} {
		{{recipientUserId = 42, content = "me"}, "Cannot send a direct message to yourself"},
		{{recipientUserId = 0, content = "nobody"}, "Invalid direct message"},
		{{recipientUserId = -3, content = "nobody"}, "Invalid direct message"},
		{{recipientUserId = 43, content = ""}, "Invalid direct message"},
		{{recipientUserId = 43, content = tooLong}, "Invalid direct message"},
	}
	for invalid in invalidCases {
		routerTestSendSealed(&h, &transport, peerID, .ClientDirectMessage, invalid.payload)
		routerTestExpectProtocolError(&h, peers[:], invalid.expected)
		routerTestExpectNoDatabaseQuery(&h, "expected an invalid direct message to be refused")
	}

	// A recipient the database does not know is refused after the single post statement.
	routerTestSendSealed(
		&h,
		&transport,
		peerID,
		.ClientDirectMessage,
		common.ClientDirectMessagePayload{recipientUserId = 999, content = "hello?"},
	)
	postQuery := routerPollDatabaseQuery(&h)
	defer IPC__database_query_request_deinit(postQuery.request)
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		postQuery.request_id,
		common.DatabaseQueryResponse {
			success = true,
			result = common.DatabasePostDirectMessageResult{recipientExists = false},
		},
	)
	routerTestExpectProtocolError(&h, peers[:], "Unknown direct message recipient")
	routerTestExpectNoNetworkMessage(&h, "expected an unknown recipient to fan out nothing")

	session, ok := MainRouterState_getPeerSession(&h.state, peerID)
	assert(ok && session.isAuthenticated, "expected refused direct messages to keep the session")
}

@(test)
testMainRouterRejectsUnauthenticatedDirectMessageRequests :: proc(t: ^testing.T) {
	_ = t

	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)

	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)

	// The handlers are reached only after decryption, so call them directly to prove they
	// still refuse a session that is not authenticated.
	peerID := u32(1)
	directBytes, directErr := cbor.marshal(
		common.ClientDirectMessagePayload{recipientUserId = 43, content = "hi"},
	)
	assert(directErr == nil, "expected direct message payload encoding to succeed")
	defer delete(directBytes)
	historyBytes, historyErr := cbor.marshal(
		common.ClientFetchDirectHistoryPayload{peerUserId = 43, limit = 10},
	)
	assert(historyErr == nil, "expected direct history payload encoding to succeed")
	defer delete(historyBytes)
	emptyBytes, emptyErr := cbor.marshal(common.ClientListUsersPayload{})
	assert(emptyErr == nil, "expected empty payload encoding to succeed")
	defer delete(emptyBytes)

	MainRouterState_handleClientDirectMessage(&h.pm, &h.state, peerID, directBytes)
	routerTestExpectPlaintextProtocolError(&h, "Unauthenticated direct message")
	MainRouterState_handleClientFetchDirectHistory(&h.pm, &h.state, peerID, historyBytes)
	routerTestExpectPlaintextProtocolError(&h, "Unauthenticated direct history request")
	MainRouterState_handleClientListDirectConversations(&h.pm, &h.state, peerID, emptyBytes)
	routerTestExpectPlaintextProtocolError(&h, "Unauthenticated direct conversation list request")
	MainRouterState_handleClientListUsers(&h.pm, &h.state, peerID, emptyBytes)
	routerTestExpectPlaintextProtocolError(&h, "Unauthenticated user list request")
	routerTestExpectNoDatabaseQuery(&h, "expected unauthenticated requests to stay local")
}

routerTestExpectPlaintextProtocolError :: proc(h: ^RouterTestHarness, expected: string) {
	send := routerPollNetworkSend(h)
	defer delete(send.data)
	packet := routerDecodePacketBytes(send.data)
	defer delete(packet.payload)
	assert(
		packet.messageType == .ServerProtocolError,
		fmt.tprintf("expected %q as a protocol error, got %v", expected, packet.messageType),
	)
	errorPayload: common.ProtocolErrorResponse
	assert(cbor.unmarshal(packet.payload, &errorPayload) == nil, "expected error decode")
	defer delete(errorPayload.message)
	assert(
		errorPayload.message == expected,
		fmt.tprintf("expected %q, got %q", expected, errorPayload.message),
	)
}

@(test)
testMainRouterDirectHistoryIsPagedPerConversation :: proc(t: ^testing.T) {
	_ = t

	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)

	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)

	peerID := u32(1)
	transport := routerCompleteHandshake(&h, peerID, 42)
	peers := [?]RouterTestPeer{{peerID, &transport}}

	routerTestSendSealed(
		&h,
		&transport,
		peerID,
		.ClientFetchDirectHistory,
		common.ClientFetchDirectHistoryPayload{peerUserId = 43, beforeMessageID = 90, limit = 20},
	)
	historyQuery := routerPollDatabaseQuery(&h)
	defer IPC__database_query_request_deinit(historyQuery.request)
	historyRequest, historyRequestOK := historyQuery.request.(common.DatabaseDirectHistoryRequest)
	assert(historyRequestOK, "expected a direct history fetch to be one history request")
	assert(
		historyRequest.userId == 42 &&
		historyRequest.peerUserId == 43 &&
		historyRequest.beforeMessageID == 90 &&
		historyRequest.limit == 20,
		fmt.tprintf("expected the requester, peer, cursor, and limit, got %v", historyRequest),
	)

	messages := make([dynamic]common.StoredDirectMessage)
	append(
		&messages,
		common.StoredDirectMessage {
			id = 61,
			senderId = 43,
			senderNickname = strings.clone("bob"),
			recipientId = 42,
			recipientNickname = strings.clone("alice"),
			timestamp = strings.clone("t61"),
			content = strings.clone("older"),
		},
		common.StoredDirectMessage {
			id = 62,
			senderId = 42,
			senderNickname = strings.clone("alice"),
			recipientId = 43,
			recipientNickname = strings.clone("bob"),
			timestamp = strings.clone("t62"),
			content = strings.clone("newer"),
		},
	)
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		historyQuery.request_id,
		common.DatabaseQueryResponse {
			success = true,
			result = common.DatabaseDirectHistoryResult {
				peerExists = true,
				messages = messages,
				hasOlder = true,
			},
		},
	)
	_, historyPacket := routerTestReceive(&h, peers[:])
	defer delete(historyPacket.payload)
	assert(
		historyPacket.messageType == .ServerDirectHistory,
		fmt.tprintf("expected ServerDirectHistory, got %v", historyPacket.messageType),
	)
	historyPayload: common.ServerDirectHistoryPayload
	assert(
		cbor.unmarshal(historyPacket.payload, &historyPayload) == nil,
		"expected direct history decode to succeed",
	)
	defer {
		for message in historyPayload.messages {
			IPC__stored_direct_message_deinit(message)
		}
		delete(historyPayload.messages)
	}
	assert(
		historyPayload.peerUserId == 43 && historyPayload.hasOlder,
		fmt.tprintf("expected peer 43 with older messages, got %v", historyPayload),
	)
	assert(
		len(historyPayload.messages) == 2 &&
		historyPayload.messages[0].id == 61 &&
		historyPayload.messages[1].id == 62 &&
		historyPayload.messages[0].senderNickname == "bob",
		fmt.tprintf("expected the page oldest first, got %v", historyPayload.messages),
	)

	invalidRequests := [?]struct {
		payload:  common.ClientFetchDirectHistoryPayload,
		expected: string,
	} {
		{{peerUserId = 43, limit = 0}, "Invalid direct history request"},
		{
			{peerUserId = 43, limit = common.HISTORY_PAGE_MAX_MESSAGES + 1},
			"Invalid direct history request",
		},
		{{peerUserId = 0, limit = 10}, "Invalid direct history request"},
		{{peerUserId = 43, beforeMessageID = -1, limit = 10}, "Invalid direct history request"},
		{{peerUserId = 42, limit = 10}, "Cannot fetch direct history with yourself"},
	}
	for invalid in invalidRequests {
		routerTestSendSealed(&h, &transport, peerID, .ClientFetchDirectHistory, invalid.payload)
		routerTestExpectProtocolError(&h, peers[:], invalid.expected)
		routerTestExpectNoDatabaseQuery(&h, "expected an invalid history request to be refused")
	}

	routerTestSendSealed(
		&h,
		&transport,
		peerID,
		.ClientFetchDirectHistory,
		common.ClientFetchDirectHistoryPayload{peerUserId = 999, limit = 10},
	)
	unknownQuery := routerPollDatabaseQuery(&h)
	defer IPC__database_query_request_deinit(unknownQuery.request)
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		unknownQuery.request_id,
		common.DatabaseQueryResponse {
			success = true,
			result = common.DatabaseDirectHistoryResult{peerExists = false},
		},
	)
	routerTestExpectProtocolError(&h, peers[:], "Unknown user")
}

@(test)
testMainRouterListsDirectConversations :: proc(t: ^testing.T) {
	_ = t

	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)

	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)

	peerID := u32(1)
	transport := routerCompleteHandshake(&h, peerID, 42)
	peers := [?]RouterTestPeer{{peerID, &transport}}

	routerTestSendSealed(
		&h,
		&transport,
		peerID,
		.ClientListDirectConversations,
		common.ClientListDirectConversationsPayload{},
	)
	listQuery := routerPollDatabaseQuery(&h)
	defer IPC__database_query_request_deinit(listQuery.request)
	listRequest, listRequestOK := listQuery.request.(common.DatabaseDirectConversationListRequest)
	assert(
		listRequestOK && listRequest.userId == 42,
		"expected the conversation list to be scoped to the authenticated user",
	)

	conversations := make([dynamic]common.DirectConversationSummary)
	append(
		&conversations,
		common.DirectConversationSummary {
			peerUserId = 44,
			peerNickname = strings.clone("carol"),
			lastMessageID = 80,
			lastSenderId = 44,
			lastTimestamp = strings.clone("t80"),
			lastContent = strings.clone("newest"),
		},
		common.DirectConversationSummary {
			peerUserId = 43,
			peerNickname = strings.clone("bob"),
			lastMessageID = 62,
			lastSenderId = 42,
			lastTimestamp = strings.clone("t62"),
			lastContent = strings.clone("older"),
		},
	)
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		listQuery.request_id,
		common.DatabaseQueryResponse {
			success = true,
			result = common.DatabaseDirectConversationListResult{conversations = conversations},
		},
	)
	_, listPacket := routerTestReceive(&h, peers[:])
	defer delete(listPacket.payload)
	assert(
		listPacket.messageType == .ServerDirectConversations,
		fmt.tprintf("expected ServerDirectConversations, got %v", listPacket.messageType),
	)
	listPayload: common.ServerDirectConversationsPayload
	assert(
		cbor.unmarshal(listPacket.payload, &listPayload) == nil,
		"expected conversation list decode to succeed",
	)
	defer {
		for conversation in listPayload.conversations {
			delete(conversation.peerNickname)
			delete(conversation.lastTimestamp)
			delete(conversation.lastContent)
		}
		delete(listPayload.conversations)
	}
	assert(
		len(listPayload.conversations) == 2 &&
		listPayload.conversations[0].peerUserId == 44 &&
		listPayload.conversations[0].lastContent == "newest" &&
		listPayload.conversations[1].peerNickname == "bob" &&
		listPayload.conversations[1].lastSenderId == 42,
		fmt.tprintf("expected the database order and fields, got %v", listPayload.conversations),
	)
}

@(test)
testMainRouterUserListMarksOnlineUsersFromSessions :: proc(t: ^testing.T) {
	_ = t

	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)

	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)

	peerID := u32(1)
	otherPeerID := u32(2)
	h.state.connectedPeers[otherPeerID] = true
	transport := routerCompleteHandshake(&h, peerID, 42)
	otherTransport := routerCompleteHandshake(&h, otherPeerID, 43)
	peers := [?]RouterTestPeer{{peerID, &transport}, {otherPeerID, &otherTransport}}
	routerTestSkipPresence(&h, peers[:])

	routerTestSendSealed(&h, &transport, peerID, .ClientUserList, common.ClientListUsersPayload{})
	userQuery := routerPollDatabaseQuery(&h)
	defer IPC__database_query_request_deinit(userQuery.request)
	_, userRequestOK := userQuery.request.(common.DatabaseUserDirectoryRequest)
	assert(userRequestOK, "expected ClientUserList to be a user directory request")

	users := make([dynamic]common.UserSummary)
	append(
		&users,
		common.UserSummary{id = 42, nickname = strings.clone("alice")},
		common.UserSummary{id = 43, nickname = strings.clone("bob")},
		common.UserSummary{id = 44, nickname = strings.clone("carol")},
	)
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		userQuery.request_id,
		common.DatabaseQueryResponse {
			success = true,
			result = common.DatabaseUserDirectoryResult{users = users},
		},
	)
	receiverPeerID, userPacket := routerTestReceive(&h, peers[:])
	defer delete(userPacket.payload)
	assert(receiverPeerID == peerID, "expected only the requester to get the user list")
	assert(
		userPacket.messageType == .ServerUserList,
		fmt.tprintf("expected ServerUserList, got %v", userPacket.messageType),
	)
	userPayload: common.ServerUserListPayload
	assert(
		cbor.unmarshal(userPacket.payload, &userPayload) == nil,
		"expected user list decode to succeed",
	)
	defer {
		for user in userPayload.users {
			delete(user.nickname)
		}
		delete(userPayload.users)
	}
	assert(len(userPayload.users) == 3, "expected every account in the user list")
	assert(
		userPayload.users[0].isOnline &&
		userPayload.users[1].isOnline &&
		!userPayload.users[2].isOnline,
		fmt.tprintf("expected 42 and 43 online and 44 offline, got %v", userPayload.users),
	)
	assert(userPayload.users[2].nickname == "carol", "expected offline accounts to keep names")
	routerTestExpectNoNetworkMessage(&h, "expected the user list to go to the requester only")
}

@(test)
testMainRouterAnnouncesPresenceOnFirstSessionAndLastDisconnect :: proc(t: ^testing.T) {
	_ = t

	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)

	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)

	watcherPeerID := u32(1)
	firstPeerID := u32(2)
	secondPeerID := u32(3)
	violatorPeerID := u32(4)
	for peerID in ([]u32{firstPeerID, secondPeerID, violatorPeerID}) {
		h.state.connectedPeers[peerID] = true
	}

	watcherTransport := routerCompleteHandshake(&h, watcherPeerID, 42)
	routerTestExpectNoNetworkMessage(&h, "expected no presence notice with nobody to tell")
	peers := [?]RouterTestPeer {
		{watcherPeerID, &watcherTransport},
		{firstPeerID, nil},
		{secondPeerID, nil},
		{violatorPeerID, nil},
	}

	firstTransport := routerCompleteHandshake(&h, firstPeerID, 43)
	peers[1].transport = &firstTransport
	notifiedPeerID, online := routerTestReceivePresence(&h, peers[:])
	defer delete(online.nickname)
	assert(notifiedPeerID == watcherPeerID, "expected the other user to hear about 43")
	assert(
		online.userId == 43 && online.isOnline && online.nickname == "router-tester",
		fmt.tprintf("expected 43 online with its nickname, got %v", online),
	)
	routerTestExpectNoNetworkMessage(&h, "expected the new session not to hear about itself")

	secondTransport := routerCompleteHandshake(&h, secondPeerID, 43)
	peers[2].transport = &secondTransport
	routerTestExpectNoNetworkMessage(&h, "expected a second session of 43 to announce nothing")

	MainRouterState_handlePeerDisconnected(&h.pm, &h.state, firstPeerID)
	routerTestExpectNoNetworkMessage(&h, "expected 43 to stay online while a session remains")
	_, firstStillThere := h.state.peerSessions[firstPeerID]
	assert(!firstStillThere, "expected the disconnected session to be removed")

	MainRouterState_handlePeerDisconnected(&h.pm, &h.state, secondPeerID)
	offlinePeerID, offline := routerTestReceivePresence(&h, peers[:])
	defer delete(offline.nickname)
	assert(offlinePeerID == watcherPeerID, "expected the remaining user to hear 43 left")
	assert(
		offline.userId == 43 && !offline.isOnline && offline.nickname == "router-tester",
		fmt.tprintf("expected 43 offline with its nickname, got %v", offline),
	)
	routerTestExpectNoNetworkMessage(&h, "expected one offline notice per remaining session")

	// A protocol violation de-authenticates the session before its disconnect event, so the
	// offline notice must go out then, and the later disconnect must not repeat it.
	violatorTransport := routerCompleteHandshake(&h, violatorPeerID, 44)
	peers[3].transport = &violatorTransport
	_, violatorOnline := routerTestReceivePresence(&h, peers[:])
	delete(violatorOnline.nickname)
	MainRouterState_protocolViolation(&h.pm, &h.state, violatorPeerID, "test violation")
	sawError := false
	sawOffline := false
	for _ in 0 ..< 2 {
		peerID, packet := routerTestReceive(&h, peers[:])
		defer delete(packet.payload)
		#partial switch packet.messageType {
		case .ServerProtocolError:
			assert(peerID == violatorPeerID, "expected the violator to get the protocol error")
			sawError = true
		case .ServerUserPresence:
			assert(peerID == watcherPeerID, "expected the watcher to hear the violator left")
			presence: common.ServerUserPresencePayload
			assert(cbor.unmarshal(packet.payload, &presence) == nil, "expected presence decode")
			delete(presence.nickname)
			assert(presence.userId == 44 && !presence.isOnline, "expected 44 offline")
			sawOffline = true
		case:
			assert(false, fmt.tprintf("unexpected message %v", packet.messageType))
		}
	}
	assert(sawError && sawOffline, "expected a protocol error and an offline notice")
	disconnect := routerPollDisconnect(&h)
	assert(disconnect.peerId == violatorPeerID, "expected the violator to be disconnected")
	MainRouterState_handlePeerDisconnected(&h.pm, &h.state, violatorPeerID)
	routerTestExpectNoNetworkMessage(&h, "expected no second offline notice for the violator")
}

@(test)
testMainRouterRenameAnnouncesNewNicknameToOtherSessions :: proc(t: ^testing.T) {
	_ = t

	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)

	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)

	watcherPeerID := u32(1)
	firstPeerID := u32(2)
	renamedPeerID := u32(3)
	for peerID in ([]u32{firstPeerID, renamedPeerID}) {
		h.state.connectedPeers[peerID] = true
	}

	watcherTransport := routerCompleteHandshake(&h, watcherPeerID, 42)
	peers := [?]RouterTestPeer{{watcherPeerID, &watcherTransport}, {firstPeerID, nil}}
	firstTransport := routerCompleteHandshake(&h, firstPeerID, 43)
	peers[1].transport = &firstTransport
	routerTestSkipPresence(&h, peers[:])

	// A second session of 43 renames the account. 43 is already online, but everyone else,
	// including 43's first session, must still learn the new name; the renamed session itself
	// must not, so its transport is left out of peers and a message to it fails the test.
	_ = routerCompleteHandshake(&h, renamedPeerID, 43, "renamed-tester", renamed = true)
	notified: [2]bool
	for _ in 0 ..< 2 {
		peerID, presence := routerTestReceivePresence(&h, peers[:])
		defer delete(presence.nickname)
		assert(
			presence.userId == 43 && presence.isOnline && presence.nickname == "renamed-tester",
			fmt.tprintf("expected 43 online as renamed-tester, got %v", presence),
		)
		assert(peerID == watcherPeerID || peerID == firstPeerID, "expected another session")
		notified[peerID == watcherPeerID ? 0 : 1] = true
	}
	assert(notified[0] && notified[1], "expected the watcher and 43's first session notified")
	routerTestExpectNoNetworkMessage(&h, "expected no notice to the renamed session")

	firstSession := h.state.peerSessions[firstPeerID]
	assert(
		firstSession.clientNickname == "renamed-tester",
		fmt.tprintf("expected 43's first session renamed, got %q", firstSession.clientNickname),
	)

	// The offline notice after 43's last session ends carries the new name, even when the
	// session that ends last is the one that connected under the old name.
	MainRouterState_handlePeerDisconnected(&h.pm, &h.state, renamedPeerID)
	routerTestExpectNoNetworkMessage(&h, "expected 43 to stay online while a session remains")
	MainRouterState_handlePeerDisconnected(&h.pm, &h.state, firstPeerID)
	offlinePeerID, offline := routerTestReceivePresence(&h, peers[:])
	defer delete(offline.nickname)
	assert(offlinePeerID == watcherPeerID, "expected the watcher to hear 43 left")
	assert(
		offline.userId == 43 && !offline.isOnline && offline.nickname == "renamed-tester",
		fmt.tprintf("expected 43 offline as renamed-tester, got %v", offline),
	)
}

@(test)
testMainRouterFailedAuthSuccessAnnouncesNoPresence :: proc(t: ^testing.T) {
	_ = t

	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)

	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)

	watcherPeerID := u32(1)
	failingPeerID := u32(2)
	h.state.connectedPeers[failingPeerID] = true
	watcherTransport := routerCompleteHandshake(&h, watcherPeerID, 42)
	routerTestExpectNoNetworkMessage(&h, "expected no presence notice with nobody to tell")

	// A session whose identity just resolved, as the handshake leaves it before auth success.
	h.state.peerSessions[failingPeerID] = RouterPeerSession {
		clientNickname = strings.clone("failing-sender"),
	}
	failingSend :: proc(
		_: ^ProcessManager,
		_: ^MainRouterState,
		_: u32,
		_: int,
		_: bool,
	) -> bool {
		return false
	}
	MainRouterState_completeAuthentication(
		&h.pm,
		&h.state,
		failingPeerID,
		43,
		sendAuthSuccess = failingSend,
	)

	// The session was never announced online, so the violation must not announce it offline:
	// the only messages are its own protocol error and its disconnect.
	errorSend := routerPollNetworkSend(&h)
	defer delete(errorSend.data)
	assert(errorSend.peerId == failingPeerID, "expected only the failing peer to hear back")
	errorPacket := routerDecodePacketBytes(errorSend.data)
	defer delete(errorPacket.payload)
	assert(
		errorPacket.messageType == .ServerProtocolError,
		fmt.tprintf("expected ServerProtocolError, got %v", errorPacket.messageType),
	)
	disconnect := routerPollDisconnect(&h)
	assert(disconnect.peerId == failingPeerID, "expected the failing peer to be disconnected")
	routerTestExpectNoNetworkMessage(&h, "expected no presence notice for a failed auth success")

	session := h.state.peerSessions[failingPeerID]
	assert(
		!session.isAuthenticated && session.authenticatedUserID == 0,
		fmt.tprintf(
			"expected the failed session to stay unauthenticated, got %v as %d",
			session.isAuthenticated,
			session.authenticatedUserID,
		),
	)
	assert(!MainRouterState_isUserOnline(&h.state, 43), "expected 43 not to count as online")

	MainRouterState_handlePeerDisconnected(&h.pm, &h.state, failingPeerID)
	routerTestExpectNoNetworkMessage(&h, "expected its disconnect to announce nothing either")

	// The watcher's transport is untouched: its next packet still opens in sequence.
	peers := [?]RouterTestPeer{{watcherPeerID, &watcherTransport}}
	MainRouterState_sendProtocolError(&h.pm, &h.state, watcherPeerID, "still in sequence")
	routerTestExpectProtocolError(&h, peers[:], "still in sequence")
}

@(test)
testDirectMessageSQLChecksRecipientInOneStatement :: proc(t: ^testing.T) {
	_ = t
	assert(
		strings.contains(DATABASE_POST_DIRECT_MESSAGE_SQL, "id <> $1") &&
		strings.contains(DATABASE_POST_DIRECT_MESSAGE_SQL, "FROM recipient RETURNING"),
		"expected the post statement to insert only for an existing recipient other than self",
	)
	assert(
		strings.contains(DATABASE_GET_DIRECT_HISTORY_SQL, "dm.sender_user_id = $2::bigint AND " +
			"dm.recipient_user_id = $1::bigint"),
		"expected history to include messages in both directions",
	)
	assert(
		strings.contains(DATABASE_LIST_DIRECT_CONVERSATIONS_SQL, "DISTINCT ON (peer_id)"),
		"expected the conversation list to keep one row per peer",
	)
	assert(
		strings.contains(DATABASE_SCHEMA_CREATE_SQL, "TABLE IF NOT EXISTS direct_messages") &&
		strings.contains(DATABASE_SCHEMA_DROP_SQL, "direct_messages"),
		"expected the schema to create and drop the direct messages table",
	)
	assert(
		strings.contains(DATABASE_SCHEMA_VALIDATION_SQL, "direct_messages_by_sender_and_") &&
		strings.contains(DATABASE_SCHEMA_VALIDATION_SQL, "direct_messages_by_recipient_and_"),
		"expected schema validation to require both direct message indexes",
	)
}
