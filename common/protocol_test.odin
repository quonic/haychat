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
	{.ClientJoinVoice, 141},
	{.ClientLeaveVoice, 142},
	{.ClientVoiceState, 143},
	{.ServerVoiceParticipants, 144},
	{.ServerVoiceJoinRejected, 145},
	{.ServerVoiceLeft, 146},
	{.ClientMarkRead, 147},
	{.ServerReadMarker, 148},
	{.ClientAdminSetRole, 149},
	{.ClientAdminRenameUser, 150},
	{.ClientAdminKickUser, 151},
	{.ClientAdminBanUser, 152},
	{.ServerAdminActionResult, 153},
	{.ServerUserUpdated, 154},
	{.ServerAccountUpdated, 155},
	{.ServerSessionEnded, 156},
}

// Enums carried as numbers inside payloads (protocol 14). Like MessageType, their values are
// the wire format: never renumber them.
@(test)
testPayloadEnumWireValuesArePinned :: proc(t: ^testing.T) {
	_ = t
	assert(
		int(RoomType.Container) == 0 &&
		int(RoomType.Chat) == 1 &&
		int(RoomType.Voice) == 2 &&
		int(RoomType.ChatAndVoice) == 3 &&
		int(RoomType.Forum) == 4,
		"expected RoomType to stay Container 0, Chat 1, Voice 2, ChatAndVoice 3, Forum 4",
	)
	assert(
		int(AdminAction.SetRole) == 0 &&
		int(AdminAction.Rename) == 1 &&
		int(AdminAction.Kick) == 2 &&
		int(AdminAction.Ban) == 3,
		"expected AdminAction to stay SetRole 0, Rename 1, Kick 2, Ban 3",
	)
	assert(
		int(SessionEndedKind.Kicked) == 0 && int(SessionEndedKind.Banned) == 1,
		"expected SessionEndedKind to stay Kicked 0, Banned 1",
	)
}

@(test)
testOnlyChatVoiceAndBothRoomTypesAreSupported :: proc(t: ^testing.T) {
	_ = t
	Case :: struct {
		roomType:  RoomType,
		supported: bool,
		chat:      bool,
		voice:     bool,
	}
	cases := [?]Case {
		{.Container, false, false, false},
		{.Chat, true, true, false},
		{.Voice, true, false, true},
		{.ChatAndVoice, true, true, true},
		{.Forum, false, false, false},
		{RoomType(9), false, false, false},
	}
	for testCase in cases {
		assert(
			roomTypeIsSupported(testCase.roomType) == testCase.supported &&
			roomTypeAllowsChat(testCase.roomType) == testCase.chat &&
			roomTypeAllowsVoice(testCase.roomType) == testCase.voice,
			fmt.tprintf("expected %v to be %v", testCase.roomType, testCase),
		)
	}
}

// Every admin payload survives CBOR with its owned strings (protocol 14).
@(test)
testAdminPayloadsRoundTripOverCBOR :: proc(t: ^testing.T) {
	_ = t
	{
		encoded, err := cbor.marshal(ClientAdminSetRolePayload{userId = 7, isAdmin = true})
		assert(err == nil, "expected ClientAdminSetRolePayload encoding to succeed")
		defer delete(encoded)
		decoded: ClientAdminSetRolePayload
		assert(cbor.unmarshal(encoded, &decoded) == nil, "expected set-role decoding")
		assert(
			decoded == ClientAdminSetRolePayload{userId = 7, isAdmin = true},
			fmt.tprintf("expected user 7 made admin, got %v", decoded),
		)
	}
	{
		original := ClientAdminRenameUserPayload {
			userId   = 7,
			nickname = "renamed",
			locked   = true,
		}
		encoded, err := cbor.marshal(original)
		assert(err == nil, "expected ClientAdminRenameUserPayload encoding to succeed")
		defer delete(encoded)
		decoded: ClientAdminRenameUserPayload
		assert(cbor.unmarshal(encoded, &decoded) == nil, "expected rename decoding")
		defer ClientAdminRenameUserPayload_deinit(&decoded)
		assert(
			decoded.userId == 7 && decoded.nickname == "renamed" && decoded.locked,
			fmt.tprintf("expected user 7 renamed and locked, got %v", decoded),
		)
	}
	{
		encoded, err := cbor.marshal(ClientAdminKickUserPayload{userId = 7, reason = "calm down"})
		assert(err == nil, "expected ClientAdminKickUserPayload encoding to succeed")
		defer delete(encoded)
		decoded: ClientAdminKickUserPayload
		assert(cbor.unmarshal(encoded, &decoded) == nil, "expected kick decoding")
		defer ClientAdminKickUserPayload_deinit(&decoded)
		assert(
			decoded.userId == 7 && decoded.reason == "calm down",
			fmt.tprintf("expected user 7 kicked, got %v", decoded),
		)
	}
	{
		encoded, err := cbor.marshal(
			ClientAdminBanUserPayload{userId = 7, banned = true, reason = "spam"},
		)
		assert(err == nil, "expected ClientAdminBanUserPayload encoding to succeed")
		defer delete(encoded)
		decoded: ClientAdminBanUserPayload
		assert(cbor.unmarshal(encoded, &decoded) == nil, "expected ban decoding")
		defer ClientAdminBanUserPayload_deinit(&decoded)
		assert(
			decoded.userId == 7 && decoded.banned && decoded.reason == "spam",
			fmt.tprintf("expected user 7 banned for spam, got %v", decoded),
		)
	}
	{
		original := ServerAdminActionResultPayload {
			action  = .Ban,
			userId  = 7,
			message = "bob is banned",
		}
		encoded, err := cbor.marshal(original)
		assert(err == nil, "expected ServerAdminActionResultPayload encoding to succeed")
		defer delete(encoded)
		decoded: ServerAdminActionResultPayload
		assert(cbor.unmarshal(encoded, &decoded) == nil, "expected admin result decoding")
		defer ServerAdminActionResultPayload_deinit(&decoded)
		assert(
			decoded.action == .Ban && decoded.userId == 7 && decoded.message == "bob is banned",
			fmt.tprintf("expected the ban result, got %v", decoded),
		)
	}
	{
		original := ServerUserUpdatedPayload {
			user = {id = 7, nickname = "bob", isOnline = true, isAdmin = true, isBanned = false},
		}
		encoded, err := cbor.marshal(original)
		assert(err == nil, "expected ServerUserUpdatedPayload encoding to succeed")
		defer delete(encoded)
		decoded: ServerUserUpdatedPayload
		assert(cbor.unmarshal(encoded, &decoded) == nil, "expected user update decoding")
		defer ServerUserUpdatedPayload_deinit(&decoded)
		assert(
			decoded.user.id == 7 &&
			decoded.user.nickname == "bob" &&
			decoded.user.isOnline &&
			decoded.user.isAdmin &&
			!decoded.user.isBanned,
			fmt.tprintf("expected bob online and admin, got %v", decoded),
		)
	}
	{
		original := ServerAccountUpdatedPayload {
			isAdmin        = true,
			nickname       = "bob",
			nicknameLocked = true,
		}
		encoded, err := cbor.marshal(original)
		assert(err == nil, "expected ServerAccountUpdatedPayload encoding to succeed")
		defer delete(encoded)
		decoded: ServerAccountUpdatedPayload
		assert(cbor.unmarshal(encoded, &decoded) == nil, "expected account update decoding")
		defer ServerAccountUpdatedPayload_deinit(&decoded)
		assert(
			decoded.isAdmin && decoded.nickname == "bob" && decoded.nicknameLocked,
			fmt.tprintf("expected an admin with a locked name, got %v", decoded),
		)
	}
	for kind in SessionEndedKind {
		encoded, err := cbor.marshal(ServerSessionEndedPayload{kind = kind, reason = "bye"})
		assert(err == nil, "expected ServerSessionEndedPayload encoding to succeed")
		defer delete(encoded)
		decoded: ServerSessionEndedPayload
		assert(cbor.unmarshal(encoded, &decoded) == nil, "expected session end decoding")
		defer ServerSessionEndedPayload_deinit(&decoded)
		assert(
			decoded.kind == kind && decoded.reason == "bye",
			fmt.tprintf("expected %v with reason bye, got %v", kind, decoded),
		)
	}
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
testProtocolVersionIsFourteenForAdminActionsAndRoomTypes :: proc(t: ^testing.T) {
	_ = t
	// 8 added ServerAuthSuccess.isAdmin; 9 changed the transport key schedule; 10 added the
	// voice control messages and the kind-bound voice AAD; 11 added read markers; 12 added
	// ServerVoiceParticipants.recipientJoined; 13 added ClientJoinVoice.rejoin and deviceId for
	// one voice session per user; 14 added the admin actions, ServerAuthSuccess.nickname and
	// nicknameLocked, UserSummary.isAdmin and isBanned, and room types, so peers on 13 or
	// older cannot talk to this build.
	assert(
		protocolVersion == 14,
		fmt.tprintf(
			"expected protocol version 14 for admin actions and room types, got %d",
			protocolVersion,
		),
	)
}

// The join's new fields survive CBOR, and an older join without them decodes with rejoin false
// and no device ID, which the server then refuses.
@(test)
testClientJoinVoiceCarriesRejoinAndDeviceID :: proc(t: ^testing.T) {
	_ = t
	original := ClientJoinVoicePayload {
		roomId   = 7,
		muted    = true,
		rejoin   = true,
		deviceId = "00112233445566778899aabbccddeeff",
	}
	encoded, encodeErr := cbor.marshal(original)
	assert(encodeErr == nil, fmt.tprintf("expected the join to encode, got %v", encodeErr))
	defer delete(encoded)
	decoded: ClientJoinVoicePayload
	assert(cbor.unmarshal(encoded, &decoded) == nil, "expected the join to decode")
	defer ClientJoinVoicePayload_deinit(&decoded)
	assert(
		decoded.roomId == 7 && decoded.muted && !decoded.deafened && decoded.rejoin &&
		decoded.deviceId == original.deviceId,
		fmt.tprintf("expected the join to survive the round trip, got %v", decoded),
	)

	OldJoin :: struct {
		roomId:   int,
		muted:    bool,
		deafened: bool,
	}
	oldEncoded, oldErr := cbor.marshal(OldJoin{roomId = 3})
	assert(oldErr == nil, "expected the old join to encode")
	defer delete(oldEncoded)
	old: ClientJoinVoicePayload
	assert(cbor.unmarshal(oldEncoded, &old) == nil, "expected the old join to decode")
	defer ClientJoinVoicePayload_deinit(&old)
	assert(
		old.roomId == 3 && !old.rejoin && !voiceDeviceIDIsValid(old.deviceId),
		fmt.tprintf("expected no rejoin and no valid device ID, got %v", old),
	)
}

// The retired voice placeholders must stay where they are: removing them would renumber
// ClientDirectMessage and ServerDirectMessage, which follow them and are on the wire.
@(test)
testRetiredVoiceDataPlaceholdersKeepTheirPlace :: proc(t: ^testing.T) {
	_ = t
	assert(
		int(MessageType.ClientVoiceData) == 64 && int(MessageType.ServerVoiceData) == 65,
		fmt.tprintf(
			"expected the retired voice placeholders at 64 and 65, got %d and %d",
			int(MessageType.ClientVoiceData),
			int(MessageType.ServerVoiceData),
		),
	)
}

@(test)
testAuthSuccessCarriesTheAdminFlagOverCBOR :: proc(t: ^testing.T) {
	_ = t
	for isAdmin in ([]bool{true, false}) {
		encoded, encodeErr := cbor.marshal(
			ServerAuthSuccessPayload {
				userId = 4,
				message = "ok",
				isAdmin = isAdmin,
				nickname = "alice",
				nicknameLocked = !isAdmin,
			},
		)
		assert(encodeErr == nil, "expected ServerAuthSuccessPayload encoding to succeed")
		defer delete(encoded)
		decoded: ServerAuthSuccessPayload
		assert(
			cbor.unmarshal(encoded, &decoded) == nil,
			"expected ServerAuthSuccessPayload decoding to succeed",
		)
		defer ServerAuthSuccessPayload_deinit(&decoded)
		assert(
			decoded.userId == 4 &&
			decoded.message == "ok" &&
			decoded.isAdmin == isAdmin &&
			decoded.nickname == "alice" &&
			decoded.nicknameLocked == !isAdmin,
			fmt.tprintf("expected user 4, \"ok\", isAdmin %v, alice; got %v", isAdmin, decoded),
		)
	}
}

@(test)
testRoomManagementPayloadsRoundTripOverCBOR :: proc(t: ^testing.T) {
	_ = t
	{
		encoded, encodeErr := cbor.marshal(
			ClientCreateRoomPayload{name = "random", description = "Off topic", roomType = .Voice},
		)
		assert(encodeErr == nil, "expected ClientCreateRoomPayload encoding to succeed")
		defer delete(encoded)
		decoded: ClientCreateRoomPayload
		assert(cbor.unmarshal(encoded, &decoded) == nil, "expected create decoding to succeed")
		defer delete(decoded.name)
		defer delete(decoded.description)
		assert(
			decoded.name == "random" &&
			decoded.description == "Off topic" &&
			decoded.roomType == .Voice,
			fmt.tprintf("expected random/Off topic as a voice room, got %v", decoded),
		)
	}
	{
		encoded, encodeErr := cbor.marshal(
			ClientEditRoomPayload{roomId = 3, name = "lounge", description = "", roomType = .Chat},
		)
		assert(encodeErr == nil, "expected ClientEditRoomPayload encoding to succeed")
		defer delete(encoded)
		decoded: ClientEditRoomPayload
		assert(cbor.unmarshal(encoded, &decoded) == nil, "expected edit decoding to succeed")
		defer delete(decoded.name)
		defer delete(decoded.description)
		assert(
			decoded.roomId == 3 &&
			decoded.name == "lounge" &&
			decoded.description == "" &&
			decoded.roomType == .Chat,
			fmt.tprintf("expected room 3 renamed lounge, got %v", decoded),
		)
	}
	{
		encoded, encodeErr := cbor.marshal(ClientDeleteRoomPayload{roomId = 3})
		assert(encodeErr == nil, "expected ClientDeleteRoomPayload encoding to succeed")
		defer delete(encoded)
		decoded: ClientDeleteRoomPayload
		assert(cbor.unmarshal(encoded, &decoded) == nil, "expected delete decoding to succeed")
		assert(decoded.roomId == 3, fmt.tprintf("expected room 3, got %v", decoded))
	}
	{
		original := ServerRoomMutationPayload {
			room = {id = 5, name = "random", description = "Off topic", roomType = .Chat},
			roomId = 5,
			userId = 2,
			changed = true,
		}
		encoded, encodeErr := cbor.marshal(original)
		assert(encodeErr == nil, "expected ServerRoomMutationPayload encoding to succeed")
		defer delete(encoded)
		decoded: ServerRoomMutationPayload
		assert(cbor.unmarshal(encoded, &decoded) == nil, "expected mutation decoding to succeed")
		defer delete(decoded.room.name)
		defer delete(decoded.room.description)
		assert(
			decoded.room.id == 5 &&
			decoded.room.name == "random" &&
			decoded.room.description == "Off topic" &&
			decoded.room.roomType == .Chat &&
			decoded.roomId == 5 &&
			decoded.userId == 2 &&
			decoded.changed,
			fmt.tprintf("expected the created room to survive the round trip, got %v", decoded),
		)
	}
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
	append(&users, UserSummary{id = 3, nickname = "alice", isOnline = true, isAdmin = true})
	append(&users, UserSummary{id = 9, nickname = "bob", isOnline = false, isBanned = true})
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
		decoded.users[0].isAdmin &&
		!decoded.users[0].isBanned &&
		decoded.users[1].id == 9 &&
		!decoded.users[1].isOnline &&
		!decoded.users[1].isAdmin &&
		decoded.users[1].isBanned,
		fmt.tprintf("expected admin alice online and banned bob offline, got %v", decoded.users),
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
			lastReadMessageId = 10,
			unreadCount = 2,
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
		summary.lastContent == "see you" &&
		summary.lastReadMessageId == 10 &&
		summary.unreadCount == 2,
		fmt.tprintf("expected the conversation summary to survive, got %v", summary),
	)
}

@(test)
testRoomListCarriesReadStateOverCBOR :: proc(t: ^testing.T) {
	_ = t
	rooms := make([dynamic]RoomSummary, context.temp_allocator)
	append(
		&rooms,
		RoomSummary {
			id = GENERAL_ROOM_ID,
			name = "general",
			description = "General discussion",
			lastReadMessageId = 41,
			unreadCount = UNREAD_COUNT_CAP,
			roomType = .Voice,
		},
	)
	encoded, encodeErr := cbor.marshal(ServerListRoomsPayload{rooms = rooms})
	assert(encodeErr == nil, "expected ServerListRoomsPayload encoding to succeed")
	defer delete(encoded)
	decoded: ServerListRoomsPayload
	assert(
		cbor.unmarshal(encoded, &decoded) == nil,
		"expected ServerListRoomsPayload decoding to succeed",
	)
	defer {
		for room in decoded.rooms {
			delete(room.name)
			delete(room.description)
		}
		delete(decoded.rooms)
	}
	assert(len(decoded.rooms) == 1, fmt.tprintf("expected one room, got %d", len(decoded.rooms)))
	room := decoded.rooms[0]
	assert(
		room.id == GENERAL_ROOM_ID &&
		room.name == "general" &&
		room.lastReadMessageId == 41 &&
		room.unreadCount == UNREAD_COUNT_CAP &&
		room.roomType == .Voice,
		fmt.tprintf("expected the room's read state and type to survive, got %v", room),
	)
}

@(test)
testReadMarkerPayloadsRoundTripOverCBOR :: proc(t: ^testing.T) {
	_ = t
	for kind in ReadMarkerKind {
		markBytes, markErr := cbor.marshal(
			ClientMarkReadPayload{kind = kind, conversationId = 7, messageId = 99},
		)
		assert(markErr == nil, "expected ClientMarkReadPayload encoding to succeed")
		defer delete(markBytes)
		mark: ClientMarkReadPayload
		assert(
			cbor.unmarshal(markBytes, &mark) == nil,
			"expected ClientMarkReadPayload decoding to succeed",
		)
		assert(
			mark == ClientMarkReadPayload{kind = kind, conversationId = 7, messageId = 99},
			fmt.tprintf("expected the mark-read request to survive, got %v", mark),
		)

		original := ServerReadMarkerPayload {
			kind              = kind,
			conversationId    = 7,
			lastReadMessageId = 98,
			unreadCount       = 3,
		}
		markerBytes, markerErr := cbor.marshal(original)
		assert(markerErr == nil, "expected ServerReadMarkerPayload encoding to succeed")
		defer delete(markerBytes)
		marker: ServerReadMarkerPayload
		assert(
			cbor.unmarshal(markerBytes, &marker) == nil,
			"expected ServerReadMarkerPayload decoding to succeed",
		)
		assert(marker == original, fmt.tprintf("expected %v to survive, got %v", original, marker))
	}
	// The kind is a fixed wire value, like MessageType.
	assert(int(ReadMarkerKind.Room) == 0, "expected ReadMarkerKind.Room to stay 0 on the wire")
	assert(int(ReadMarkerKind.Direct) == 1, "expected ReadMarkerKind.Direct to stay 1 on the wire")
}
