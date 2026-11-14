#+feature dynamic-literals
package client

import "../common"
import "core:encoding/cbor"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:testing"

directMessageSendBridgeTestMutex: sync.Mutex
directMessageSendBridgeTestRecipientID: int
directMessageSendBridgeTestContent: string
directMessageSendBridgeTestReturnValue: bool

directMessageSendBridgeTestStub :: proc(
	transport: ^ClientServerTransport,
	recipientUserID: int,
	content: string,
) -> bool {
	directMessageSendBridgeTestRecipientID = recipientUserID
	delete(directMessageSendBridgeTestContent)
	directMessageSendBridgeTestContent = strings.clone(content)
	return directMessageSendBridgeTestReturnValue
}

testDirectServer :: proc(id: int) -> Server {
	return Server {
		id = id,
		name = fmt.tprintf("DM Server %d", id),
		host = "localhost",
		port = common.DEFAULT_SERVER_PORT,
	}
}

// Applies a live direct message the way the frame loop does, including the event cleanup.
testApplyDirectMessage :: proc(
	state: ^State,
	serverID, messageID, senderID, recipientID: int,
	content: string,
	senderNickname := "",
	recipientNickname := "",
) {
	event := ClientTransportRuntimeEvent {
		kind = .DirectMessageReceived,
		serverID = serverID,
		directMessage = common.StoredDirectMessage {
			id = messageID,
			senderId = senderID,
			senderNickname = strings.clone(senderNickname),
			recipientId = recipientID,
			recipientNickname = strings.clone(recipientNickname),
			timestamp = strings.clone("t"),
			content = strings.clone(content),
		},
	}
	State_applyRuntimeEvent(state, &event)
	ClientTransportRuntimeEvent_deinit(&event)
}

// Applies a history page whose messages alternate between selfUserID and peerUserID.
testApplyDirectHistory :: proc(
	state: ^State,
	serverID, selfUserID, peerUserID: int,
	hasOlder: bool,
	messageIDs: ..int,
) {
	event := ClientTransportRuntimeEvent {
		kind       = .DirectHistoryReceived,
		serverID   = serverID,
		peerUserID = peerUserID,
		hasOlder   = hasOlder,
	}
	for id in messageIDs {
		senderID, recipientID := peerUserID, selfUserID
		if id % 2 == 0 {
			senderID, recipientID = selfUserID, peerUserID
		}
		append(
			&event.directMessages,
			common.StoredDirectMessage {
				id = id,
				senderId = senderID,
				senderNickname = strings.clone("sender"),
				recipientId = recipientID,
				recipientNickname = strings.clone("recipient"),
				timestamp = strings.clone("t"),
				content = fmt.aprintf("message %d", id),
			},
		)
	}
	State_applyRuntimeEvent(state, &event)
	ClientTransportRuntimeEvent_deinit(&event)
}

testApplyUserList :: proc(state: ^State, serverID: int, users: ..common.UserSummary) {
	event := ClientTransportRuntimeEvent {
		kind     = .UserListReceived,
		serverID = serverID,
	}
	for user in users {
		append(
			&event.users,
			common.UserSummary {
				id = user.id,
				nickname = strings.clone(user.nickname),
				isOnline = user.isOnline,
				isAdmin = user.isAdmin,
				isBanned = user.isBanned,
			},
		)
	}
	State_applyRuntimeEvent(state, &event)
	ClientTransportRuntimeEvent_deinit(&event)
}

testApplyConversations :: proc(state: ^State, serverID: int, peers: ..common.UserSummary) {
	event := ClientTransportRuntimeEvent {
		kind     = .DirectConversationsReceived,
		serverID = serverID,
	}
	for peer, index in peers {
		append(
			&event.conversations,
			common.DirectConversationSummary {
				peerUserId = peer.id,
				peerNickname = strings.clone(peer.nickname),
				lastMessageID = 100 - index,
				lastSenderId = peer.id,
				lastTimestamp = strings.clone("t"),
				lastContent = strings.clone("last"),
			},
		)
	}
	State_applyRuntimeEvent(state, &event)
	ClientTransportRuntimeEvent_deinit(&event)
}

testDirectCache :: proc(state: ^State, serverID, peerUserID: int) -> ^DirectConversationCache {
	return ServerDirectCache_conversationCache(
		State_serverDirectCache(state, serverID),
		peerUserID,
	)
}

testDirectMessageIDs :: proc(cache: ^DirectConversationCache) -> string {
	builder := strings.builder_make(context.temp_allocator)
	for message, index in cache.messages {
		if index > 0 {
			strings.write_byte(&builder, ',')
		}
		strings.write_int(&builder, message.id)
	}
	return strings.to_string(builder)
}

@(test)
testDirectCachesAreScopedByServerAndPeer :: proc(t: ^testing.T) {
	serverA := testDirectServer(601)
	serverB := testDirectServer(602)
	state := testStateWithServers({serverA, serverB})
	defer State_deinit(&state)
	testApplyConnected(&state, serverA.id, 7)
	testApplyConnected(&state, serverB.id, 7)

	// The same peer ID on two servers is two different accounts.
	testApplyDirectMessage(&state, serverA.id, 1, 10, 7, "from A's user 10", "ann", "me")
	testApplyDirectMessage(&state, serverB.id, 1, 10, 7, "from B's user 10", "bea", "me")
	testApplyDirectMessage(&state, serverA.id, 2, 11, 7, "from A's user 11", "cal", "me")

	cacheA10 := testDirectCache(&state, serverA.id, 10)
	testing.expectf(
		t,
		len(cacheA10.messages) == 1 && cacheA10.messages[0].content == "from A's user 10",
		"expected server A's conversation with user 10 to hold only its own message, got %v",
		cacheA10.messages,
	)
	cacheB10 := testDirectCache(&state, serverB.id, 10)
	testing.expectf(
		t,
		len(cacheB10.messages) == 1 && cacheB10.messages[0].content == "from B's user 10",
		"expected server B's conversation with user 10 to hold only its own message, got %v",
		cacheB10.messages,
	)
	cacheA11 := testDirectCache(&state, serverA.id, 11)
	testing.expect(t, len(cacheA11.messages) == 1, "expected one message with user 11")

	// Drafts belong to their conversation too.
	testSetDraft(&testDirectCache(&state, serverA.id, 10).draft, "draft for A/10")
	testSetDraft(&testDirectCache(&state, serverB.id, 10).draft, "draft for B/10")
	testExpectString(
		t,
		string(testDirectCache(&state, serverA.id, 10).draft[:]),
		"draft for A/10",
		"server A's draft",
	)
	testExpectString(
		t,
		string(testDirectCache(&state, serverB.id, 10).draft[:]),
		"draft for B/10",
		"server B's draft",
	)

	// A message for a server that is not configured is dropped.
	testApplyDirectMessage(&state, 999, 3, 10, 7, "nowhere")
	testing.expect(
		t,
		State_serverDirectCacheIndex(state, 999) < 0,
		"expected no cache for an unknown server",
	)
}

@(test)
testDirectHistoryMergesPagesByMessageID :: proc(t: ^testing.T) {
	server := testDirectServer(603)
	state := testStateWithServers({server})
	defer State_deinit(&state)
	testApplyConnected(&state, server.id, 7)

	// Newest page, then a live message, then an overlapping older page.
	testApplyDirectHistory(&state, server.id, 7, 10, true, 3, 4, 5)
	cache := testDirectCache(&state, server.id, 10)
	testing.expect(t, cache.initialHistoryLoaded, "expected the first page to mark it loaded")
	testing.expect(t, cache.hasOlder, "expected the newest page to report older messages")
	testing.expect(t, cache.oldestMessageID == 3, "expected the oldest loaded ID to be 3")

	testApplyDirectMessage(&state, server.id, 6, 10, 7, "live")
	testApplyDirectMessage(&state, server.id, 6, 10, 7, "live")
	testApplyDirectHistory(&state, server.id, 7, 10, false, 1, 2, 3)
	cache = testDirectCache(&state, server.id, 10)
	testExpectString(t, testDirectMessageIDs(cache), "1,2,3,4,5,6", "the merged message IDs")
	testing.expect(t, !cache.hasOlder, "expected the oldest page to clear hasOlder")
	testing.expect(t, cache.oldestMessageID == 1, "expected the oldest loaded ID to be 1")

	// The newest page again (after a reconnect) must not bring "Load older" back.
	testApplyDirectHistory(&state, server.id, 7, 10, true, 4, 5, 6)
	cache = testDirectCache(&state, server.id, 10)
	testExpectString(t, testDirectMessageIDs(cache), "1,2,3,4,5,6", "the IDs after a reload")
	testing.expect(t, !cache.hasOlder, "expected a reloaded newest page to keep hasOlder false")

	view := buildDirectConversationView(&state)
	testing.expect(t, !view.hasPeer, "expected no conversation view while a room is open")
	state.selected_dm_peer_id = 10
	view = buildDirectConversationView(&state)
	testing.expect(t, len(view.lines) == 6, "expected the open conversation's six lines")
	testExpectString(t, view.lines[0].senderLabel, "sender", "the peer's sender label")
	testExpectString(t, view.lines[1].senderLabel, "You", "the label of the user's own line")
	testing.expect(t, view.lines[1].isSelf, "expected the user's own line to be marked")
}

@(test)
testDirectMessagesSetUnreadAndMoveConversationToTop :: proc(t: ^testing.T) {
	server := testDirectServer(604)
	state := testStateWithServers({server})
	defer State_deinit(&state)
	testApplyConnected(&state, server.id, 7)
	testApplyConversations(
		&state,
		server.id,
		{id = 10, nickname = "ann"},
		{id = 11, nickname = "bob"},
	)

	// A message from bob while no conversation is open: unread, and bob moves to the top.
	testApplyDirectMessage(&state, server.id, 200, 11, 7, "hi", "bob", "me")
	cache := State_serverDirectCache(&state, server.id)
	testing.expect(
		t,
		cache.conversations[0].peerUserId == 11 && cache.conversations[0].lastMessageID == 200,
		"expected bob's conversation to move to the top with the new message",
	)
	testExpectString(t, cache.conversations[0].lastContent, "hi", "the latest content")
	testing.expect(
		t,
		State_directSummary(&state, server.id, 11).unreadCount == 1,
		"expected a message in a closed conversation to count as unread",
	)

	// The user's own echo (sent from another session) is never unread, and a new peer is
	// added to the top under the recipient's nickname.
	testApplyDirectMessage(&state, server.id, 201, 7, 12, "hello cy", "me", "cy")
	cache = State_serverDirectCache(&state, server.id)
	testing.expect(t, len(cache.conversations) == 3, "expected cy's conversation to be added")
	testing.expect(t, cache.conversations[0].peerUserId == 12, "expected cy at the top")
	testExpectString(t, cache.conversations[0].peerNickname, "cy", "the new peer's nickname")
	testing.expect(
		t,
		State_directSummary(&state, server.id, 12).unreadCount == 0,
		"expected the user's own message not to count as unread",
	)

	rows := buildSidebarRows(&state)
	foundUnread := false
	for row in rows {
		if row.kind == .Conversation && row.id == 11 {
			foundUnread = row.unreadCount == 1
		}
	}
	testing.expect(t, foundUnread, "expected the sidebar to show bob's unread message")

	// Opening the conversation does not clear the badge by itself; the server's marker does.
	// While the window has focus, a message in the open conversation stays read.
	state.windowFocused = true
	State_openDirectConversation(&state, server.id, 11)
	testing.expect(t, state.selected_dm_peer_id == 11, "expected bob's conversation to open")
	testApplyDirectMessage(&state, server.id, 202, 11, 7, "still here", "bob", "me")
	testing.expect(
		t,
		State_directSummary(&state, server.id, 11).unreadCount == 1,
		"expected a message in the viewed conversation not to count as unread",
	)

	// An older message than the listed one leaves the order alone.
	testApplyDirectMessage(&state, server.id, 50, 10, 7, "old", "ann", "me")
	cache = State_serverDirectCache(&state, server.id)
	testing.expect(t, cache.conversations[0].peerUserId == 11, "expected bob to stay on top")
}

@(test)
testMembersListOnlineFirstThenAlphabeticalWithoutSelf :: proc(t: ^testing.T) {
	server := testDirectServer(605)
	state := testStateWithServers({server})
	defer State_deinit(&state)
	testApplyConnected(&state, server.id, 7)
	testApplyUserList(
		&state,
		server.id,
		{id = 7, nickname = "Tester", isOnline = true},
		{id = 3, nickname = "carol"},
		{id = 4, nickname = "Bob", isOnline = true},
		{id = 5, nickname = "alice"},
		{id = 6, nickname = "dave", isOnline = true},
	)

	builder := strings.builder_make(context.temp_allocator)
	for row in buildSidebarRows(&state) {
		if row.kind == .Member {
			fmt.sbprintf(&builder, "%s:%v ", row.label, row.isOnline)
		}
	}
	testExpectString(
		t,
		strings.to_string(builder),
		"Bob:true dave:true alice:false carol:false ",
		"the member order",
	)

	headers := 0
	for row in buildSidebarRows(&state) {
		if row.kind == .SectionHeader {
			headers += 1
		}
	}
	testing.expect(t, headers == 3, "expected Channels, Direct Messages, and Members headers")
}

@(test)
testPresenceUpdatesTheDirectory :: proc(t: ^testing.T) {
	server := testDirectServer(606)
	state := testStateWithServers({server})
	defer State_deinit(&state)
	testApplyConnected(&state, server.id, 7)
	testApplyUserList(&state, server.id, {id = 3, nickname = "carol", isOnline = true})

	offline := ClientTransportRuntimeEvent {
		kind = .UserPresenceChanged,
		serverID = server.id,
		user = {id = 3, nickname = strings.clone("carol"), isOnline = false},
	}
	State_applyRuntimeEvent(&state, &offline)
	ClientTransportRuntimeEvent_deinit(&offline)
	cache := State_serverDirectCache(&state, server.id)
	testing.expect(
		t,
		len(cache.users) == 1 && !cache.users[0].isOnline,
		"expected presence to mark carol offline in place",
	)

	// An account created after the list was fetched is added.
	online := ClientTransportRuntimeEvent {
		kind = .UserPresenceChanged,
		serverID = server.id,
		user = {id = 8, nickname = strings.clone("newcomer"), isOnline = true},
	}
	State_applyRuntimeEvent(&state, &online)
	testing.expect(t, len(online.user.nickname) == 0, "expected the nickname to move to State")
	ClientTransportRuntimeEvent_deinit(&online)
	cache = State_serverDirectCache(&state, server.id)
	testing.expect(
		t,
		len(cache.users) == 2 && cache.users[1].nickname == "newcomer" && cache.users[1].isOnline,
		"expected presence for an unknown account to add it as online",
	)

	// A refreshed list replaces the directory.
	testApplyUserList(&state, server.id, {id = 3, nickname = "carol", isOnline = true})
	cache = State_serverDirectCache(&state, server.id)
	testing.expect(
		t,
		len(cache.users) == 1 && cache.users[0].isOnline && cache.usersLoaded,
		"expected the user list to replace the directory",
	)
}

@(test)
testPresenceRenamesTheDirectoryAndConversation :: proc(t: ^testing.T) {
	server := testDirectServer(613)
	state := testStateWithServers({server})
	defer State_deinit(&state)
	testApplyConnected(&state, server.id, 7)
	testApplyUserList(
		&state,
		server.id,
		{id = 7, nickname = "me", isOnline = true},
		{id = 3, nickname = "carol", isOnline = true},
	)
	testApplyConversations(&state, server.id, {id = 3, nickname = "carol"})
	testApplyDirectMessage(&state, server.id, 101, 3, 7, "hi", "carol", "me")

	// The server announces a rename as presence carrying the account's new nickname.
	renamed := ClientTransportRuntimeEvent {
		kind = .UserPresenceChanged,
		serverID = server.id,
		user = {id = 3, nickname = strings.clone("carol-renamed"), isOnline = true},
	}
	State_applyRuntimeEvent(&state, &renamed)
	ClientTransportRuntimeEvent_deinit(&renamed)

	cache := State_serverDirectCache(&state, server.id)
	userIndex := ServerDirectCache_userIndex(cache^, 3)
	conversationIndex := ServerDirectCache_conversationIndex(cache^, 3)
	testing.expect(
		t,
		len(cache.users) == 2 &&
		userIndex >= 0 &&
		cache.users[userIndex].nickname == "carol-renamed",
		fmt.tprintf("expected carol renamed in the directory, got %v", cache.users),
	)
	testing.expect(
		t,
		conversationIndex >= 0 &&
		cache.conversations[conversationIndex].peerNickname == "carol-renamed",
		fmt.tprintf("expected carol renamed in the conversations, got %v", cache.conversations),
	)

	// The sidebar reads the new name for both the conversation and the member row.
	rows := buildSidebarRows(&state)
	labels := 0
	for row in rows {
		if (row.kind == .Conversation || row.kind == .Member) && row.id == 3 {
			testing.expect(
				t,
				row.label == "carol-renamed",
				fmt.tprintf("expected the %v row renamed, got %q", row.kind, row.label),
			)
			labels += 1
		}
	}
	testing.expect(t, labels == 2, "expected a conversation row and a member row for carol")

	// Cached messages keep the nickname they were sent with.
	conversation := &cache.caches[ServerDirectCache_conversationCacheIndex(cache^, 3)]
	testing.expect(
		t,
		len(conversation.messages) == 1 && conversation.messages[0].senderNickname == "carol",
		"expected the cached message to keep its sender nickname",
	)
}

@(test)
testSendDirectMessageWaitsForTheServerEcho :: proc(t: ^testing.T) {
	sync.mutex_lock(&directMessageSendBridgeTestMutex)
	defer sync.mutex_unlock(&directMessageSendBridgeTestMutex)

	server := testDirectServer(607)
	state := testStateWithServers({server})
	defer State_deinit(&state)
	testApplyConnected(&state, server.id, 7)

	original := directMessageSendBridge
	directMessageSendBridge = directMessageSendBridgeTestStub
	defer directMessageSendBridge = original
	defer {
		delete(directMessageSendBridgeTestContent)
		directMessageSendBridgeTestContent = ""
	}

	State_openDirectConversation(&state, server.id, 10)
	testSetDraft(State_selectedDirectDraft(&state), "hello\tthere")
	directMessageSendBridgeTestReturnValue = false
	State_sendDirectMessage(&state)
	testExpectString(
		t,
		string(State_selectedDirectDraft(&state)[:]),
		"hello\tthere",
		"the draft after a rejected send",
	)
	testing.expect(t, len(state.chat_status_message) > 0, "expected a rejected send's status")

	directMessageSendBridgeTestReturnValue = true
	State_sendDirectMessage(&state)
	testing.expect(
		t,
		directMessageSendBridgeTestRecipientID == 10,
		"expected the message to go to the open conversation's peer",
	)
	testExpectString(t, directMessageSendBridgeTestContent, "hello    there", "the sent text")
	testing.expect(
		t,
		len(State_selectedDirectDraft(&state)) == 0,
		"expected an accepted send to clear the draft",
	)
	testing.expect(
		t,
		len(testDirectCache(&state, server.id, 10).messages) == 0,
		"expected nothing in the transcript until the server echoes the message",
	)

	// Blank drafts and messages to oneself never reach the transport.
	directMessageSendBridgeTestRecipientID = 0
	testSetDraft(State_selectedDirectDraft(&state), "   ")
	State_sendDirectMessage(&state)
	testing.expect(t, directMessageSendBridgeTestRecipientID == 0, "expected no blank send")
	testSetDraft(&testDirectCache(&state, server.id, 7).draft, "me")
	State_sendDirectMessageTo(&state, server.id, 7)
	testing.expect(t, directMessageSendBridgeTestRecipientID == 0, "expected no self send")
}

@(test)
testDirectConversationKeepsTheRoomSelection :: proc(t: ^testing.T) {
	serverA := testDirectServer(608)
	serverB := testDirectServer(609)
	state := testStateWithServers({serverA, serverB})
	defer State_deinit(&state)
	testApplyConnected(&state, serverA.id, 7)
	State_switchToChannel(&state, serverA.id, 2)

	State_openDirectConversation(&state, serverA.id, 10)
	testing.expect(t, state.selected_dm_peer_id == 10, "expected the conversation to open")
	testing.expect(t, state.selected_channel_id == 2, "expected the room selection to stay")
	State_openDirectConversation(&state, serverA.id, 7)
	testing.expect(t, state.selected_dm_peer_id == 10, "expected no conversation with oneself")

	State_switchToChannel(&state, serverA.id, 2)
	testing.expect(t, state.selected_dm_peer_id == 0, "expected a room click to close it")

	State_openDirectConversation(&state, serverA.id, 10)
	State_switchToServer(&state, serverB.id)
	testing.expect(
		t,
		state.selected_dm_peer_id == 0,
		"expected switching servers to close the conversation, whose peer ID is per server",
	)
}

@(test)
testConnectedResetsDirectRequestsForReload :: proc(t: ^testing.T) {
	server := testDirectServer(610)
	state := testStateWithServers({server})
	defer State_deinit(&state)
	testApplyConnected(&state, server.id, 7)
	testApplyDirectHistory(&state, server.id, 7, 10, false, 1)
	cache := State_serverDirectCache(&state, server.id)
	cache.usersLoading = true
	testDirectCache(&state, server.id, 10).isLoadingHistory = true

	testApplyConnected(&state, server.id, 7)
	cache = State_serverDirectCache(&state, server.id)
	testing.expect(t, !cache.usersLoading, "expected a new session to clear usersLoading")
	conversation := testDirectCache(&state, server.id, 10)
	testing.expect(
		t,
		!conversation.isLoadingHistory && !conversation.initialHistoryLoaded,
		"expected a new session to fetch the conversation again when opened",
	)
	testing.expect(t, len(conversation.messages) == 1, "expected loaded messages to stay")
}

@(test)
testClientServerTransportDecodesDirectMessagePayloads :: proc(t: ^testing.T) {
	server := testDirectServer(611)
	config := testConfigWithServers({server})
	defer Config_deinit(&config)
	transport, serverTransport, ok := buildEstablishedTransportPair(server, config)
	assert(ok, "expected transport pair setup to succeed")
	defer ClientServerTransport_deinit(&transport)

	decode :: proc(
		transport: ^ClientServerTransport,
		serverTransport: ^common.TransportState,
		messageType: common.MessageType,
		payload: any,
	) -> ClientTransportRuntimeEvent {
		sealed, sealOK := common.sealPacketForSession(serverTransport, messageType, payload)
		assert(sealOK, "expected the server transport to seal the payload")
		defer delete(sealed.payload)
		packetBytes, bytesOK := common.marshalPacket(sealed)
		assert(bytesOK, "expected the sealed packet to marshal")
		defer delete(packetBytes)
		event, eventOK := ClientServerTransport_handleRuntimePacketBytes(transport, packetBytes)
		assert(eventOK, "expected the runtime handler to surface an event")
		return event
	}

	direct := decode(
		&transport,
		&serverTransport,
		.ServerDirectMessage,
		common.ServerDirectMessagePayload {
			id = 5,
			senderId = 3,
			senderNickname = "ann",
			recipientId = 77,
			recipientNickname = "me",
			timestamp = "ts",
			content = "hi",
		},
	)
	testing.expectf(
		t,
		direct.kind == .DirectMessageReceived &&
		direct.serverID == server.id &&
		direct.directMessage.id == 5 &&
		direct.directMessage.senderId == 3 &&
		direct.directMessage.senderNickname == "ann" &&
		direct.directMessage.recipientId == 77 &&
		direct.directMessage.recipientNickname == "me" &&
		direct.directMessage.timestamp == "ts" &&
		direct.directMessage.content == "hi",
		"expected a decoded direct message, got %v",
		direct,
	)
	ClientTransportRuntimeEvent_deinit(&direct)

	historyMessages := [dynamic]common.StoredDirectMessage {
		{id = 1, senderId = 3, senderNickname = "ann", recipientId = 77, content = "old"},
	}
	defer delete(historyMessages)
	history := decode(
		&transport,
		&serverTransport,
		.ServerDirectHistory,
		common.ServerDirectHistoryPayload {
			peerUserId = 3,
			messages = historyMessages,
			hasOlder = true,
		},
	)
	testing.expectf(
		t,
		history.kind == .DirectHistoryReceived &&
		history.peerUserID == 3 &&
		history.hasOlder &&
		len(history.directMessages) == 1 &&
		history.directMessages[0].content == "old",
		"expected a decoded direct history page, got %v",
		history,
	)
	ClientTransportRuntimeEvent_deinit(&history)

	users := [dynamic]common.UserSummary{{id = 3, nickname = "ann", isOnline = true}}
	defer delete(users)
	userList := decode(
		&transport,
		&serverTransport,
		.ServerUserList,
		common.ServerUserListPayload{users = users},
	)
	testing.expectf(
		t,
		userList.kind == .UserListReceived &&
		len(userList.users) == 1 &&
		userList.users[0].nickname == "ann" &&
		userList.users[0].isOnline,
		"expected a decoded user list, got %v",
		userList,
	)
	ClientTransportRuntimeEvent_deinit(&userList)

	summaries := [dynamic]common.DirectConversationSummary {
		{peerUserId = 3, peerNickname = "ann", lastMessageID = 5, lastSenderId = 77},
	}
	defer delete(summaries)
	conversations := decode(
		&transport,
		&serverTransport,
		.ServerDirectConversations,
		common.ServerDirectConversationsPayload{conversations = summaries},
	)
	testing.expectf(
		t,
		conversations.kind == .DirectConversationsReceived &&
		len(conversations.conversations) == 1 &&
		conversations.conversations[0].peerNickname == "ann" &&
		conversations.conversations[0].lastSenderId == 77,
		"expected a decoded conversation list, got %v",
		conversations,
	)
	ClientTransportRuntimeEvent_deinit(&conversations)

	presence := decode(
		&transport,
		&serverTransport,
		.ServerUserPresence,
		common.ServerUserPresencePayload{userId = 3, nickname = "ann", isOnline = true},
	)
	testing.expectf(
		t,
		presence.kind == .UserPresenceChanged &&
		presence.user.id == 3 &&
		presence.user.nickname == "ann" &&
		presence.user.isOnline,
		"expected a decoded presence change, got %v",
		presence,
	)
	ClientTransportRuntimeEvent_deinit(&presence)

	// A payload of the wrong shape becomes a protocol error and leaves the session usable.
	garbage := decode(&transport, &serverTransport, .ServerUserList, "not a user list")
	testing.expectf(
		t,
		garbage.kind == .ProtocolError && garbage.message == "invalid user list payload",
		"expected an invalid payload to become a protocol error, got %v",
		garbage,
	)
	ClientTransportRuntimeEvent_deinit(&garbage)
	testing.expect(
		t,
		common.TransportState_canEncrypt(&transport.transport),
		"expected an invalid payload to keep the session",
	)
}

@(test)
testClientServerTransportBuildsDirectMessageRequests :: proc(t: ^testing.T) {
	server := testDirectServer(612)
	config := testConfigWithServers({server})
	defer Config_deinit(&config)
	transport, serverTransport, ok := buildEstablishedTransportPair(server, config)
	assert(ok, "expected transport pair setup to succeed")
	defer ClientServerTransport_deinit(&transport)

	// The packet a send would put on the wire must open on the server side as the request.
	packetBytes, built := ClientServerTransport_buildEncryptedPacketBytes(
		&transport,
		.ClientDirectMessage,
		common.ClientDirectMessagePayload{recipientUserId = 3, content = "hello"},
	)
	assert(built, "expected the direct message packet to build")
	defer delete(packetBytes)
	outer: common.Packet
	assert(cbor.unmarshal(packetBytes, &outer) == nil, "expected the outer packet to decode")
	defer delete(outer.payload)
	inner, openOK := common.openPacketForSession(&serverTransport, outer)
	assert(openOK, "expected the server to open the packet")
	defer delete(inner.payload)
	request: common.ClientDirectMessagePayload
	testing.expect(
		t,
		inner.messageType == .ClientDirectMessage,
		"expected a ClientDirectMessage packet",
	)
	testing.expect(
		t,
		cbor.unmarshal(inner.payload, &request) == nil,
		"expected the request payload to decode",
	)
	defer delete(request.content)
	testing.expect(
		t,
		request.recipientUserId == 3 && request.content == "hello",
		"expected the request to carry the recipient and text",
	)

	// Without a live ENet session the requests report "not connected" without failing it.
	testing.expect(
		t,
		!ClientServerTransport_requestUserList(&transport),
		"expected no user list request without a live session",
	)
	testExpectString(t, transport.lastError, NOT_CONNECTED_MESSAGE, "the request error")
}
