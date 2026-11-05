package common

import "core:encoding/cbor"
import "core:fmt"
import "core:testing"

// Wire values of every MessageType member the client or server sends or dispatches today.
// MessageType numbers itself automatically, so inserting or removing a member upstream of
// these silently renumbers them and breaks every peer built from the old enum. Add a member
// here when it goes on the wire; never edit an existing value.
PINNED_MESSAGE_TYPE_VALUES := [?]struct {
	messageType: MessageType,
	value:       int,
} {
	{.None, 0},
	{.ClientHello, 12},
	{.ServerHello, 13},
	{.ClientRegister, 14},
	{.ServerRegisterResponse, 15},
	{.ServerAuthChallenge, 16},
	{.ClientAuthRequest, 17},
	{.ServerAuthSuccess, 18},
	{.ServerAuthFailure, 19},
	{.EncryptedPacket, 20},
	{.ClientListRooms, 44},
	{.ServerListRooms, 45},
	{.ClientFetchRoomHistory, 46},
	{.ServerRoomHistory, 47},
	{.ClientCreateRoom, 51},
	{.ServerCreateRoom, 52},
	{.ClientDeleteRoom, 53},
	{.ServerDeleteRoom, 54},
	{.ClientEditRoom, 55},
	{.ServerEditRoom, 56},
	{.ClientAddRoomMember, 57},
	{.ClientRemoveRoomMember, 58},
	{.ServerRoomMemberAdded, 59},
	{.ServerRoomMemberRemoved, 60},
	{.ServerRoomMembershipChanged, 61},
	{.ClientChatMessage, 62},
	{.ServerChatMessage, 63},
	{.ClientDirectMessage, 68},
	{.ServerDirectMessage, 69},
	{.ClientUserList, 106},
	{.ServerUserList, 107},
	{.ClientStoreFile, 120},
	{.ServerStoreFileResponse, 121},
	{.ServerProtocolError, 122},
	{.ClientFetchDirectHistory, 136},
	{.ServerDirectHistory, 137},
	{.ClientListDirectConversations, 138},
	{.ServerDirectConversations, 139},
	{.ServerUserPresence, 140},
}

@(test)
testMessageTypeWireValuesArePinned :: proc(t: ^testing.T) {
	_ = t
	for pinned in PINNED_MESSAGE_TYPE_VALUES {
		actual := int(pinned.messageType)
		assert(
			actual == pinned.value,
			fmt.tprintf(
				"expected MessageType.%v to stay %d on the wire, got %d",
				pinned.messageType,
				pinned.value,
				actual,
			),
		)
	}
}

@(test)
testStoredChatMessageCarriesSenderNicknameOverCBOR :: proc(t: ^testing.T) {
	_ = t
	original := ServerChatMessagePayload {
		id             = 7,
		senderId       = 3,
		senderNickname = "hay-user",
		roomId         = GENERAL_ROOM_ID,
		timestamp      = "2026-11-05 00:00:00+00",
		content        = "hello",
	}
	encoded, encodeErr := cbor.marshal(original)
	assert(encodeErr == nil, "expected chat payload encoding to succeed")
	defer delete(encoded)

	decoded: ServerChatMessagePayload
	assert(cbor.unmarshal(encoded, &decoded) == nil, "expected chat payload decoding to succeed")
	defer {
		delete(decoded.senderNickname)
		delete(decoded.timestamp)
		delete(decoded.content)
	}
	assert(
		decoded.senderNickname == original.senderNickname,
		fmt.tprintf("expected nickname %q, got %q", original.senderNickname, decoded.senderNickname),
	)
	assert(decoded.senderId == original.senderId, "expected sender ID to survive the round trip")
}

@(test)
testProtocolVersionIsSevenForDirectMessages :: proc(t: ^testing.T) {
	_ = t
	assert(
		protocolVersion == 7,
		fmt.tprintf("expected protocol version 7 for direct messages, got %d", protocolVersion),
	)
}

@(test)
testDirectMessagePayloadsRoundTripOverCBOR :: proc(t: ^testing.T) {
	_ = t
	sent := ClientDirectMessagePayload {
		recipientUserId = 9,
		content         = "psst",
	}
	sentBytes, sentErr := cbor.marshal(sent)
	assert(sentErr == nil, "expected ClientDirectMessagePayload encoding to succeed")
	defer delete(sentBytes)
	decodedSent: ClientDirectMessagePayload
	assert(
		cbor.unmarshal(sentBytes, &decodedSent) == nil,
		"expected ClientDirectMessagePayload decoding to succeed",
	)
	defer delete(decodedSent.content)
	assert(
		decodedSent.recipientUserId == 9 && decodedSent.content == "psst",
		fmt.tprintf("expected recipient 9 and %q, got %v", sent.content, decodedSent),
	)

	original := ServerDirectMessagePayload {
		id                = 11,
		senderId          = 3,
		senderNickname    = "alice",
		recipientId       = 9,
		recipientNickname = "bob",
		timestamp         = "2026-11-05 00:00:00+00",
		content           = "hello bob",
	}
	encoded, encodeErr := cbor.marshal(original)
	assert(encodeErr == nil, "expected ServerDirectMessagePayload encoding to succeed")
	defer delete(encoded)
	decoded: ServerDirectMessagePayload
	assert(
		cbor.unmarshal(encoded, &decoded) == nil,
		"expected ServerDirectMessagePayload decoding to succeed",
	)
	defer {
		delete(decoded.senderNickname)
		delete(decoded.recipientNickname)
		delete(decoded.timestamp)
		delete(decoded.content)
	}
	assert(
		decoded.id == 11 && decoded.senderId == 3 && decoded.recipientId == 9,
		fmt.tprintf("expected IDs 11/3/9 to survive, got %v", decoded),
	)
	assert(
		decoded.senderNickname == "alice" && decoded.recipientNickname == "bob",
		fmt.tprintf("expected nicknames alice/bob, got %v", decoded),
	)
	assert(decoded.content == "hello bob", fmt.tprintf("expected content, got %q", decoded.content))
}

@(test)
testDirectHistoryPayloadsRoundTripOverCBOR :: proc(t: ^testing.T) {
	_ = t
	request := ClientFetchDirectHistoryPayload {
		peerUserId      = 9,
		beforeMessageID = 40,
		limit           = 20,
	}
	requestBytes, requestErr := cbor.marshal(request)
	assert(requestErr == nil, "expected ClientFetchDirectHistoryPayload encoding to succeed")
	defer delete(requestBytes)
	decodedRequest: ClientFetchDirectHistoryPayload
	assert(
		cbor.unmarshal(requestBytes, &decodedRequest) == nil,
		"expected ClientFetchDirectHistoryPayload decoding to succeed",
	)
	assert(decodedRequest == request, fmt.tprintf("expected %v, got %v", request, decodedRequest))

	messages := make([dynamic]StoredDirectMessage, context.temp_allocator)
	append(
		&messages,
		StoredDirectMessage {
			id = 5,
			senderId = 9,
			senderNickname = "bob",
			recipientId = 3,
			recipientNickname = "alice",
			timestamp = "t5",
			content = "five",
		},
	)
	history := ServerDirectHistoryPayload {
		peerUserId = 9,
		messages   = messages,
		hasOlder   = true,
	}
	encoded, encodeErr := cbor.marshal(history)
	assert(encodeErr == nil, "expected ServerDirectHistoryPayload encoding to succeed")
	defer delete(encoded)
	decoded: ServerDirectHistoryPayload
	assert(
		cbor.unmarshal(encoded, &decoded) == nil,
		"expected ServerDirectHistoryPayload decoding to succeed",
	)
	defer {
		for message in decoded.messages {
			delete(message.senderNickname)
			delete(message.recipientNickname)
			delete(message.timestamp)
			delete(message.content)
		}
		delete(decoded.messages)
	}
	assert(
		decoded.peerUserId == 9 && decoded.hasOlder && len(decoded.messages) == 1,
		fmt.tprintf("expected peer 9, hasOlder, and one message, got %v", decoded),
	)
	assert(
		decoded.messages[0].id == 5 &&
		decoded.messages[0].recipientNickname == "alice" &&
		decoded.messages[0].content == "five",
		fmt.tprintf("expected stored message 5 to survive, got %v", decoded.messages[0]),
	)
}

@(test)
testUserDirectoryAndPresencePayloadsRoundTripOverCBOR :: proc(t: ^testing.T) {
	_ = t
	users := make([dynamic]UserSummary, context.temp_allocator)
	append(&users, UserSummary{id = 3, nickname = "alice", isOnline = true})
	append(&users, UserSummary{id = 9, nickname = "bob", isOnline = false})
	encoded, encodeErr := cbor.marshal(ServerUserListPayload{users = users})
	assert(encodeErr == nil, "expected ServerUserListPayload encoding to succeed")
	defer delete(encoded)
	decoded: ServerUserListPayload
	assert(
		cbor.unmarshal(encoded, &decoded) == nil,
		"expected ServerUserListPayload decoding to succeed",
	)
	defer {
		for user in decoded.users {
			delete(user.nickname)
		}
		delete(decoded.users)
	}
	assert(len(decoded.users) == 2, fmt.tprintf("expected 2 users, got %d", len(decoded.users)))
	assert(
		decoded.users[0].nickname == "alice" &&
		decoded.users[0].isOnline &&
		decoded.users[1].id == 9 &&
		!decoded.users[1].isOnline,
		fmt.tprintf("expected alice online and bob offline, got %v", decoded.users),
	)

	presence := ServerUserPresencePayload {
		userId   = 9,
		nickname = "bob",
		isOnline = true,
	}
	presenceBytes, presenceErr := cbor.marshal(presence)
	assert(presenceErr == nil, "expected ServerUserPresencePayload encoding to succeed")
	defer delete(presenceBytes)
	decodedPresence: ServerUserPresencePayload
	assert(
		cbor.unmarshal(presenceBytes, &decodedPresence) == nil,
		"expected ServerUserPresencePayload decoding to succeed",
	)
	defer delete(decodedPresence.nickname)
	assert(
		decodedPresence.userId == 9 &&
		decodedPresence.nickname == "bob" &&
		decodedPresence.isOnline,
		fmt.tprintf("expected bob online, got %v", decodedPresence),
	)

	// Empty request payloads must still encode, since every packet carries a payload.
	emptyBytes, emptyErr := cbor.marshal(ClientListUsersPayload{})
	assert(emptyErr == nil, "expected ClientListUsersPayload encoding to succeed")
	delete(emptyBytes)
	emptyBytes, emptyErr = cbor.marshal(ClientListDirectConversationsPayload{})
	assert(emptyErr == nil, "expected ClientListDirectConversationsPayload encoding to succeed")
	delete(emptyBytes)
}

@(test)
testDirectConversationsPayloadRoundTripsOverCBOR :: proc(t: ^testing.T) {
	_ = t
	conversations := make([dynamic]DirectConversationSummary, context.temp_allocator)
	append(
		&conversations,
		DirectConversationSummary {
			peerUserId = 9,
			peerNickname = "bob",
			lastMessageID = 12,
			lastSenderId = 3,
			lastTimestamp = "t12",
			lastContent = "see you",
		},
	)
	encoded, encodeErr := cbor.marshal(
		ServerDirectConversationsPayload{conversations = conversations},
	)
	assert(encodeErr == nil, "expected ServerDirectConversationsPayload encoding to succeed")
	defer delete(encoded)
	decoded: ServerDirectConversationsPayload
	assert(
		cbor.unmarshal(encoded, &decoded) == nil,
		"expected ServerDirectConversationsPayload decoding to succeed",
	)
	defer {
		for conversation in decoded.conversations {
			delete(conversation.peerNickname)
			delete(conversation.lastTimestamp)
			delete(conversation.lastContent)
		}
		delete(decoded.conversations)
	}
	assert(
		len(decoded.conversations) == 1,
		fmt.tprintf("expected one conversation, got %d", len(decoded.conversations)),
	)
	summary := decoded.conversations[0]
	assert(
		summary.peerUserId == 9 &&
		summary.peerNickname == "bob" &&
		summary.lastMessageID == 12 &&
		summary.lastSenderId == 3 &&
		summary.lastContent == "see you",
		fmt.tprintf("expected the conversation summary to survive, got %v", summary),
	)
}
