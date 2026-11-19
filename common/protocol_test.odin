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
	{.ClientLeaveRoom, 36},
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
	// Retired placeholders (attachments plan D24): never sent, pinned so nothing reuses them.
	{.ClientUploadFile, 123},
	{.ServerUploadFileResponse, 124},
	{.ClientDownloadFile, 125},
	{.ServerDownloadFileResponse, 126},
	{.ClientDeleteFile, 127},
	{.ServerDeleteFileResponse, 128},
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
	{.ClientFetchRoomMembers, 157},
	{.ServerRoomMembers, 158},
	{.ClientAdminListRooms, 159},
	{.ServerAdminRooms, 160},
	{.ClientPublishEncryptionKey, 161},
	{.ClientFetchUserKeys, 162},
	{.ServerUserKeys, 163},
	{.ServerUserKeyChanged, 164},
	{.ClientSealedDirectMessage, 165},
	{.ServerSealedDirectMessage, 166},
	{.ClientAppendRoomLog, 167},
	{.ClientFetchRoomLog, 168},
	{.ServerRoomLog, 169},
	{.ClientRoomKeyEnvelope, 170},
	{.ServerRoomKeyEnvelope, 171},
	{.ClientFetchRoomKeys, 172},
	{.ServerRoomKeys, 173},
	{.ClientRequestRoomKey, 174},
	{.ServerRoomKeyRequest, 175},
	{.ClientVoiceKey, 176},
	{.ServerVoiceKey, 177},
	{.ClientRequestVoiceKey, 178},
	{.ServerVoiceKeyRequest, 179},
	{.ClientAdminListRoles, 180},
	{.ServerRoleList, 181},
	{.ClientAdminSaveRole, 182},
	{.ClientAdminDeleteRole, 183},
	{.ClientAdminSetUserRoles, 184},
	{.ServerRoleUpdated, 185},
	{.ServerRoleDeleted, 186},
	{.ClientAdminSetRoomPermissions, 187},
	{.ClientAdminFetchRoomPermissions, 188},
	{.ServerAdminRoomPermissions, 189},
	// Protocol 25 (#43 G1): registration.
	{.ServerRegistrationRequired, 190},
	{.ClientAdminSetRegistrationMode, 191},
	{.ServerRegistrationMode, 192},
	{.ClientCreateInvite, 193},
	{.ServerInviteCreated, 194},
	{.ClientListInvites, 195},
	{.ServerInviteList, 196},
	{.ClientRevokeInvite, 197},
	{.ClientListRegistrationRequests, 198},
	{.ServerRegistrationRequests, 199},
	{.ClientDecideRegistration, 200},
	{.ServerRegistrationRequestUpdated, 201},
	{.ClientAdminSetRestricted, 202},
	// Protocol 26 (attachments F1).
	{.ClientAttachmentUploadBegin, 203},
	{.ServerAttachmentUploadReady, 204},
	{.ClientAttachmentUploadResume, 205},
	{.ClientAttachmentUploadFinish, 206},
	{.ServerAttachmentUploadDone, 207},
	{.ClientAttachmentDownload, 208},
	{.ServerAttachmentDownloadBegin, 209},
	{.ClientAttachmentCancel, 210},
	{.ServerAttachmentRefused, 211},
	// Protocol 28 (attachments F3).
	{.ClientAdminAttachmentUsage, 212},
	{.ServerAdminAttachmentUsage, 213},
	{.ClientAdminRemoveAttachment, 214},
	{.ServerAttachmentRemoved, 215},
	// Protocol 29 (#138: the attachment removal log).
	{.ClientAdminListAttachmentRemovals, 216},
	{.ServerAdminAttachmentRemovals, 217},
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
		int(AdminAction.SetRestricted) == 10 && int(AdminAction.RemoveAttachment) == 11,
		fmt.tprintf(
			"expected AdminAction SetRestricted 10 and RemoveAttachment 11, got %d and %d",
			int(AdminAction.SetRestricted),
			int(AdminAction.RemoveAttachment),
		),
	)
	assert(
		int(SessionEndedKind.Kicked) == 0 && int(SessionEndedKind.Banned) == 1,
		"expected SessionEndedKind to stay Kicked 0, Banned 1",
	)
	// Protocol 15, and rooms.access / rooms.history_visibility in the database.
	assert(
		int(RoomAccess.Public) == 1 &&
		int(RoomAccess.MemberInvite) == 2 &&
		int(RoomAccess.AdminInvite) == 3 &&
		int(RoomAccess.Role) == 4,
		"expected RoomAccess to stay Public 1, MemberInvite 2, AdminInvite 3, Role 4",
	)
	assert(
		int(RoomHistoryVisibility.FromJoin) == 1 && int(RoomHistoryVisibility.Full) == 2,
		"expected RoomHistoryVisibility to stay FromJoin 1, Full 2",
	)
}

@(test)
testRoomAccessModesAndHistoryVisibility :: proc(t: ^testing.T) {
	_ = t
	for access in RoomAccess {
		assert(roomAccessIsSupported(access), fmt.tprintf("expected %v supported", access))
	}
	assert(
		!roomAccessIsSupported(RoomAccess(0)) && !roomAccessIsSupported(RoomAccess(5)),
		"expected 0 and 5 to be no access mode",
	)
	assert(
		!roomHistoryVisibilityIsSupported(RoomHistoryVisibility(0)) &&
		!roomHistoryVisibilityIsSupported(RoomHistoryVisibility(3)),
		"expected 0 and 3 to be no history setting",
	)
	assert(
		roomEffectiveHistoryVisibility(.Public, .FromJoin) == .Full &&
		roomEffectiveHistoryVisibility(.MemberInvite, .FromJoin) == .FromJoin &&
		roomEffectiveHistoryVisibility(.AdminInvite, .Full) == .Full,
		"expected Public rooms to read full history and invite rooms their own setting",
	)
}

// The protocol 15 payloads survive CBOR, and the owned ones free cleanly.
@(test)
testRoomAccessPayloadsRoundTrip :: proc(t: ^testing.T) {
	_ = t
	{
		encoded, err := cbor.marshal(
			ClientCreateRoomPayload {
				name = "secret",
				roomType = .Chat,
				access = .AdminInvite,
				historyVisibility = .Full,
				creatorJoins = true,
			},
		)
		assert(err == nil, "expected ClientCreateRoomPayload encoding to succeed")
		defer delete(encoded)
		decoded: ClientCreateRoomPayload
		assert(cbor.unmarshal(encoded, &decoded) == nil, "expected the create to decode")
		defer delete(decoded.name)
		defer delete(decoded.description)
		assert(
			decoded.access == .AdminInvite &&
			decoded.historyVisibility == .Full &&
			decoded.creatorJoins,
			fmt.tprintf("expected the access fields to survive, got %v", decoded),
		)
	}
	{
		userIDs := make([dynamic]int)
		defer delete(userIDs)
		append(&userIDs, 3, 5)
		encoded, err := cbor.marshal(ServerRoomMembersPayload{roomId = 9, userIds = userIDs})
		assert(err == nil, "expected ServerRoomMembersPayload encoding to succeed")
		defer delete(encoded)
		decoded: ServerRoomMembersPayload
		assert(cbor.unmarshal(encoded, &decoded) == nil, "expected the members to decode")
		defer ServerRoomMembersPayload_deinit(&decoded)
		assert(
			decoded.roomId == 9 &&
			len(decoded.userIds) == 2 &&
			decoded.userIds[0] == 3 &&
			decoded.userIds[1] == 5,
			fmt.tprintf("expected room 9 with 3 and 5, got %v", decoded),
		)
	}
	{
		rooms := make([dynamic]AdminRoomSummary)
		defer delete(rooms)
		append(
			&rooms,
			AdminRoomSummary {
				room = {id = 4, name = "ops", access = .AdminInvite, historyVisibility = .FromJoin},
				memberCount = 2,
			},
		)
		encoded, err := cbor.marshal(ServerAdminRoomsPayload{rooms = rooms})
		assert(err == nil, "expected ServerAdminRoomsPayload encoding to succeed")
		defer delete(encoded)
		decoded: ServerAdminRoomsPayload
		assert(cbor.unmarshal(encoded, &decoded) == nil, "expected the admin rooms to decode")
		defer ServerAdminRoomsPayload_deinit(&decoded)
		assert(
			len(decoded.rooms) == 1 &&
			decoded.rooms[0].room.name == "ops" &&
			decoded.rooms[0].room.access == .AdminInvite &&
			!decoded.rooms[0].isMember &&
			decoded.rooms[0].memberCount == 2,
			fmt.tprintf("expected the ops room, got %v", decoded),
		)
	}
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
	defer ServerChatMessagePayload_deinit(&decoded)
	assert(
		decoded.senderNickname == original.senderNickname,
		fmt.tprintf("expected nickname %q, got %q", original.senderNickname, decoded.senderNickname),
	)
	assert(decoded.senderId == original.senderId, "expected sender ID to survive the round trip")
}

@(test)
testProtocolVersionIsEighteenForEncryptedRoomLogs :: proc(t: ^testing.T) {
	_ = t
	// 8 added ServerAuthSuccess.isAdmin; 9 changed the transport key schedule; 10 added the
	// voice control messages and the kind-bound voice AAD; 11 added read markers; 12 added
	// ServerVoiceParticipants.recipientJoined; 13 added ClientJoinVoice.rejoin and deviceId for
	// one voice session per user; 14 added the admin actions, ServerAuthSuccess.nickname and
	// nicknameLocked, UserSummary.isAdmin and isBanned, and room types; 15 added room access
	// modes, history visibility, member fetches, leaving, and the admin room list; 16 added
	// the account encryption keys (ClientPublishEncryptionKey, ClientFetchUserKeys,
	// ServerUserKeys, ServerUserKeyChanged) and UserSummary.identityPublicKey and
	// hasEncryptionKey; 17 added encrypted direct messages (ClientSealedDirectMessage,
	// ServerSealedDirectMessage), the envelope, client message ID and signature fields of
	// stored messages and conversation summaries, and the signed plaintext fallback; 18 added
	// encrypted rooms and their member log (ClientAppendRoomLog, ClientFetchRoomLog,
	// ServerRoomLog, RoomSummary.encrypted and logVersion, ClientCreateRoomPayload.encrypted,
	// ClientEditRoomPayload.encrypted); 19 added sender chains in encrypted rooms (sealed and
	// clientMessageId on chat messages, ClientRoomKeyEnvelope, ServerRoomKeyEnvelope,
	// ClientFetchRoomKeys, ServerRoomKeys, ClientRequestRoomKey, ServerRoomKeyRequest); 20 added
	// Full history in encrypted rooms (RoomKeyForward envelopes: ClientRoomKeyEnvelope.senderId,
	// RoomKeyEnvelope.forwarderId, ServerRoomKeyRequest.senderId, and key requests relayed to
	// every member); 21 added end-to-end encrypted voice in encrypted rooms (ClientVoiceKey,
	// ServerVoiceKey, ClientRequestVoiceKey, ServerVoiceKeyRequest, the VoiceKey envelope kind and
	// sealed voice payloads); 22 signs every plaintext room message (signature in
	// ClientChatMessage, ServerChatMessage and StoredChatMessage, #90), so peers on 21 or older
	// cannot talk to this build; 23 added roles and server permissions (#95: ServerPermission,
	// RoleSummary, UserSummary.roleIds, permissions in ServerAuthSuccess and
	// ServerAccountUpdated, ClientAdminListRoles ... ServerRoleDeleted, the SaveRole, DeleteRole
	// and SetUserRoles admin actions) and retired the old role placeholders; 24 added room
	// permissions and role rooms (#96: RoomPermission, RoomSummary.myPermissions,
	// RoomAccess.Role, accessRoleIds on ClientCreateRoom and ClientEditRoom,
	// ClientAdminSetRoomPermissions, ClientAdminFetchRoomPermissions, ServerAdminRoomPermissions);
	// 25 added registration (#43 G1: ServerRegistrationRequired, ClientAuthRequest.registering,
	// encrypted ClientRegister{inviteCode, reason} and ServerRegisterResponse{status, message,
	// auth}, invites, sign-up requests, the registration mode, restricted accounts:
	// UserSummary.isRestricted, registrationMode and isRestricted in ServerAuthSuccess, and
	// ClientAdminSetRegistrationMode ... ClientAdminSetRestricted); 26 added attachment
	// transfers (F1: transport v3 with the file channel's keys, ENet channel 5,
	// ClientAttachmentUploadBegin ... ServerAttachmentRefused, the binary chunks of
	// attachment_wire.odin) and retired ClientUploadFile ... ServerDeleteFileResponse; 27 put
	// attachments on messages (F2: AttachmentRef on every room and direct message payload and
	// DirectConversationSummary.lastAttachments, the v2 plaintext signatures, the sealed
	// "attachments" key, RoomPermission.AttachFiles and ServerAuthSuccess.attachments); 28 added
	// attachment moderation (F3: ClientAdminAttachmentUsage ... ServerAttachmentRemoved,
	// AdminAction.RemoveAttachment and ServerAdminActionResult.blobId); 29 added the removal log
	// (#138: ClientAdminListAttachmentRemovals, ServerAdminAttachmentRemovals, and
	// chatMessageId and directMessageId in ServerAttachmentRemoved).
	assert(
		protocolVersion == 29,
		fmt.tprintf("expected protocol version 29 for attachments, got %d", protocolVersion),
	)
}

// Protocol 22 (#90): a plaintext room message carries its client message ID and signature in
// both directions and in history pages.
@(test)
testSignedRoomMessagePayloadsRoundTrip :: proc(t: ^testing.T) {
	_ = t
	id: ClientMessageID
	id[3] = 9
	signature: SignatureBytes
	signature[0] = 1
	signature[63] = 0xfe
	{
		original := ClientChatMessagePayload {
			roomId          = 3,
			content         = "hello",
			clientMessageId = id,
			signature       = signature,
		}
		data, err := cbor.marshal(original)
		assert(err == nil, "expected ClientChatMessagePayload encoding to succeed")
		defer delete(data)
		decoded: ClientChatMessagePayload
		assert(
			cbor.unmarshal(data, &decoded, temp_allocator = context.allocator) == nil,
			"expected the client chat payload to decode",
		)
		defer ClientChatMessagePayload_deinit(&decoded)
		assert(
			decoded.content == "hello" &&
			decoded.clientMessageId == id &&
			decoded.signature == signature,
			fmt.tprintf("expected the signed client message unchanged, got %v", decoded),
		)
	}
	{
		original := ServerChatMessagePayload {
			id              = 5,
			roomId          = 3,
			senderId        = 2,
			content         = "hello",
			clientMessageId = id,
			signature       = signature,
		}
		data, err := cbor.marshal(original)
		assert(err == nil, "expected ServerChatMessagePayload encoding to succeed")
		defer delete(data)
		decoded: ServerChatMessagePayload
		assert(
			cbor.unmarshal(data, &decoded, temp_allocator = context.allocator) == nil,
			"expected the server chat payload to decode",
		)
		defer ServerChatMessagePayload_deinit(&decoded)
		assert(
			decoded.clientMessageId == id && decoded.signature == signature,
			fmt.tprintf("expected the signed server message unchanged, got %v", decoded),
		)
	}
	{
		original := ServerRoomHistoryPayload {
			roomId   = 3,
			messages = make([dynamic]StoredChatMessage, 0, 1),
		}
		defer delete(original.messages)
		append(
			&original.messages,
			StoredChatMessage {
				id = 5,
				senderId = 2,
				roomId = 3,
				content = "hello",
				clientMessageId = id,
				signature = signature,
			},
		)
		data, err := cbor.marshal(original)
		assert(err == nil, "expected ServerRoomHistoryPayload encoding to succeed")
		defer delete(data)
		decoded: ServerRoomHistoryPayload
		assert(
			cbor.unmarshal(data, &decoded, temp_allocator = context.allocator) == nil,
			"expected the history page to decode",
		)
		defer {
			for &message in decoded.messages {
				StoredChatMessage_deinit(&message)
			}
			delete(decoded.messages)
		}
		assert(
			len(decoded.messages) == 1 &&
			decoded.messages[0].clientMessageId == id &&
			decoded.messages[0].signature == signature,
			"expected the stored message's signature unchanged",
		)
	}
}

// Protocol 19: sealed chat messages and key envelopes carry their bytes as byte strings,
// unchanged, and own them once decoded.
@(test)
testRoomChainPayloadsCarryBytesUnchanged :: proc(t: ^testing.T) {
	sealed := []u8{1, 2, 3, 0xff}
	id: ClientMessageID
	id[0] = 7
	{
		original := ServerChatMessagePayload {
			id = 5,
			roomId = 3,
			senderId = 2,
			clientMessageId = id,
			sealed = sealed,
		}
		data, err := cbor.marshal(original)
		assert(err == nil, "expected ServerChatMessagePayload encoding to succeed")
		defer delete(data)
		decoded: ServerChatMessagePayload
		assert(cbor.unmarshal(data, &decoded) == nil, "expected chat payload to decode")
		defer ServerChatMessagePayload_deinit(&decoded)
		assert(string(decoded.sealed) == string(sealed), "expected sealed bytes unchanged")
		assert(decoded.clientMessageId == id, "expected the client message ID unchanged")
	}
	{
		chainID: ChainID
		chainID[15] = 9
		original := ServerRoomKeysPayload {
			roomId    = 3,
			envelopes = make([dynamic]RoomKeyEnvelope, 0, 1),
			hasMore   = true,
		}
		defer delete(original.envelopes)
		append(
			&original.envelopes,
			RoomKeyEnvelope {
				id = 11,
				roomId = 3,
				epoch = 2,
				senderId = 4,
				chainId = chainID,
				envelope = sealed,
				forwarderId = 6,
			},
		)
		data, err := cbor.marshal(original)
		assert(err == nil, "expected ServerRoomKeysPayload encoding to succeed")
		defer delete(data)
		decoded: ServerRoomKeysPayload
		assert(cbor.unmarshal(data, &decoded) == nil, "expected room keys payload to decode")
		defer ServerRoomKeysPayload_deinit(&decoded)
		assert(len(decoded.envelopes) == 1, "expected one envelope")
		got := decoded.envelopes[0]
		assert(
			got.id == 11 && got.epoch == 2 && got.senderId == 4 && got.chainId == chainID,
			"expected the envelope's fields unchanged",
		)
		assert(got.forwarderId == 6, "expected the forwarder unchanged (protocol 20)")
		assert(string(got.envelope) == string(sealed), "expected envelope bytes unchanged")
		assert(decoded.hasMore, "expected hasMore unchanged")
	}
}

// The protocol 18 log payloads carry entries as byte strings, unchanged, and own them once
// decoded.
@(test)
testRoomLogPayloadsCarryEntriesAsByteStrings :: proc(t: ^testing.T) {
	_ = t
	first := make([]u8, 210)
	defer delete(first)
	second := make([]u8, 230)
	defer delete(second)
	for index in 0 ..< len(first) {
		first[index] = u8(index * 5 + 1)
	}
	for index in 0 ..< len(second) {
		second[index] = u8(index * 3 + 2)
	}
	{
		original := ClientAppendRoomLogPayload {
			roomId = 7,
			entry  = first,
		}
		encoded, err := cbor.marshal(original)
		assert(err == nil, "expected ClientAppendRoomLogPayload encoding to succeed")
		defer delete(encoded)
		assert(protocolTestContains(encoded, first), "expected the entry verbatim")
		decoded: ClientAppendRoomLogPayload
		assert(cbor.unmarshal(encoded, &decoded) == nil, "expected append decoding")
		defer ClientAppendRoomLogPayload_deinit(&decoded)
		assert(
			decoded.roomId == 7 && string(decoded.entry) == string(first),
			fmt.tprintf("expected every field to survive, got room %d", decoded.roomId),
		)
	}
	{
		entries := make([dynamic][]u8, 0, 2)
		defer delete(entries)
		append(&entries, first, second)
		original := ServerRoomLogPayload {
			roomId       = 7,
			afterVersion = 3,
			entries      = entries,
			headVersion  = 5,
			hasMore      = true,
		}
		encoded, err := cbor.marshal(original)
		assert(err == nil, "expected ServerRoomLogPayload encoding to succeed")
		defer delete(encoded)
		assert(
			protocolTestContains(encoded, first) && protocolTestContains(encoded, second),
			"expected both entries verbatim",
		)
		decoded: ServerRoomLogPayload
		assert(cbor.unmarshal(encoded, &decoded) == nil, "expected room log decoding")
		defer ServerRoomLogPayload_deinit(&decoded)
		assert(
			decoded.roomId == 7 &&
			decoded.afterVersion == 3 &&
			decoded.headVersion == 5 &&
			decoded.hasMore &&
			len(decoded.entries) == 2 &&
			string(decoded.entries[0]) == string(first) &&
			string(decoded.entries[1]) == string(second),
			fmt.tprintf("expected every field to survive, got %d entries", len(decoded.entries)),
		)
	}
	{
		original := RoomSummary {
			id         = 4,
			name       = "secret",
			access     = .AdminInvite,
			encrypted  = true,
			logVersion = 9,
		}
		encoded, err := cbor.marshal(original)
		assert(err == nil, "expected RoomSummary encoding to succeed")
		defer delete(encoded)
		decoded: RoomSummary
		assert(cbor.unmarshal(encoded, &decoded) == nil, "expected RoomSummary decoding")
		defer delete(decoded.name)
		defer delete(decoded.description)
		assert(
			decoded.encrypted && decoded.logVersion == 9,
			"expected encrypted and logVersion to survive",
		)
	}
}

// The protocol 17 payloads survive CBOR: the envelope is one byte string whose bytes appear
// unchanged in the encoding (never re-encoded), and the fixed-size fields are byte strings.
@(test)
testDirectMessagePayloadsCarryEnvelopesAsByteStrings :: proc(t: ^testing.T) {
	_ = t
	envelope := make([]u8, 300)
	defer delete(envelope)
	for index in 0 ..< len(envelope) {
		envelope[index] = u8(index * 7 + 3)
	}
	clientMessageID: ClientMessageID
	for index in 0 ..< len(clientMessageID) {
		clientMessageID[index] = u8(0xA0 + index)
	}
	{
		original := ClientSealedDirectMessagePayload {
			recipientUserId = 9,
			clientMessageId = clientMessageID,
			envelope        = envelope,
		}
		encoded, err := cbor.marshal(original)
		assert(err == nil, "expected ClientSealedDirectMessagePayload encoding to succeed")
		defer delete(encoded)
		assert(
			protocolTestContains(encoded, envelope) &&
			protocolTestContains(encoded, clientMessageID[:]),
			"expected the envelope and the client message ID verbatim in the encoding",
		)
		assert(
			len(encoded) < len(envelope) + 80,
			fmt.tprintf("expected byte strings, got %d bytes", len(encoded)),
		)
		decoded: ClientSealedDirectMessagePayload
		assert(cbor.unmarshal(encoded, &decoded) == nil, "expected sealed message decoding")
		defer ClientSealedDirectMessagePayload_deinit(&decoded)
		assert(
			decoded.recipientUserId == 9 &&
			decoded.clientMessageId == clientMessageID &&
			string(decoded.envelope) == string(envelope),
			fmt.tprintf("expected every field to survive, got %v", decoded),
		)
	}
	{
		original := ServerSealedDirectMessagePayload {
			id                = 5,
			senderId          = 2,
			senderNickname    = "alice",
			recipientId       = 3,
			recipientNickname = "bob",
			timestamp         = "2026-11-14 10:00:00+00",
			clientMessageId   = clientMessageID,
			envelope          = envelope,
		}
		encoded, err := cbor.marshal(original)
		assert(err == nil, "expected ServerSealedDirectMessagePayload encoding to succeed")
		defer delete(encoded)
		decoded: ServerSealedDirectMessagePayload
		assert(cbor.unmarshal(encoded, &decoded) == nil, "expected server sealed decoding")
		defer ServerSealedDirectMessagePayload_deinit(&decoded)
		assert(
			decoded.id == 5 &&
			decoded.senderNickname == "alice" &&
			decoded.clientMessageId == clientMessageID &&
			string(decoded.envelope) == string(envelope),
			fmt.tprintf("expected every field to survive, got %v", decoded),
		)
	}
	{
		signature: SignatureBytes
		for index in 0 ..< len(signature) {
			signature[index] = u8(index + 1)
		}
		original := ClientDirectMessagePayload {
			recipientUserId = 4,
			content         = "plain",
			clientMessageId = clientMessageID,
			signature       = signature,
		}
		encoded, err := cbor.marshal(original)
		assert(err == nil, "expected ClientDirectMessagePayload encoding to succeed")
		defer delete(encoded)
		decoded: ClientDirectMessagePayload
		assert(cbor.unmarshal(encoded, &decoded) == nil, "expected plaintext decoding")
		defer delete(decoded.content)
		assert(
			decoded.content == "plain" &&
			decoded.clientMessageId == clientMessageID &&
			decoded.signature == signature,
			fmt.tprintf("expected the signature fields to survive, got %v", decoded),
		)
	}
	assert(!clientMessageIDIsSet({}), "expected the zero client message ID to mean none")
	assert(clientMessageIDIsSet(clientMessageID), "expected a random ID to be set")
}

@(private = "file")
protocolTestContains :: proc(haystack, needle: []u8) -> bool {
	if len(needle) == 0 {
		return true
	}
	for start in 0 ..= len(haystack) - len(needle) {
		if string(haystack[start:start + len(needle)]) == string(needle) {
			return true
		}
	}
	return false
}

// A bundle with every byte distinct, so a field moved into another one shows.
@(private = "file")
protocolTestBundle :: proc(userID: int) -> UserKeyBundle {
	bundle := UserKeyBundle {
		userId    = userID,
		createdAt = 1_731_600_000 + u64(userID),
	}
	for index in 0 ..< len(bundle.identityPublicKey) {
		bundle.identityPublicKey[index] = u8(index + userID)
		bundle.encryptionPublicKey[index] = u8(100 + index + userID)
	}
	for index in 0 ..< len(bundle.signature) {
		bundle.signature[index] = u8(200 + index + userID)
	}
	return bundle
}

// The protocol 16 payloads survive CBOR, with their keys as fixed-size byte strings.
@(test)
testEncryptionKeyPayloadsRoundTripOverCBOR :: proc(t: ^testing.T) {
	_ = t
	bundle := protocolTestBundle(7)
	{
		original := ClientPublishEncryptionKeyPayload {
			encryptionPublicKey = bundle.encryptionPublicKey,
			createdAt           = bundle.createdAt,
			signature           = bundle.signature,
		}
		encoded, err := cbor.marshal(original)
		assert(err == nil, "expected ClientPublishEncryptionKeyPayload encoding to succeed")
		defer delete(encoded)
		decoded: ClientPublishEncryptionKeyPayload
		assert(cbor.unmarshal(encoded, &decoded) == nil, "expected publish decoding")
		assert(decoded == original, fmt.tprintf("expected %v, got %v", original, decoded))
		// 32 and 64 bytes as byte strings, not arrays of numbers.
		assert(
			len(encoded) < 32 + 64 + 64,
			fmt.tprintf("expected the keys as byte strings, got %d bytes", len(encoded)),
		)
	}
	{
		ids := make([dynamic]int, 0, 3)
		defer delete(ids)
		append(&ids, 3, 1, 2)
		encoded, err := cbor.marshal(ClientFetchUserKeysPayload{userIds = ids})
		assert(err == nil, "expected ClientFetchUserKeysPayload encoding to succeed")
		defer delete(encoded)
		decoded: ClientFetchUserKeysPayload
		assert(cbor.unmarshal(encoded, &decoded) == nil, "expected fetch decoding")
		defer ClientFetchUserKeysPayload_deinit(&decoded)
		assert(
			len(decoded.userIds) == 3 &&
			decoded.userIds[0] == 3 &&
			decoded.userIds[1] == 1 &&
			decoded.userIds[2] == 2,
			fmt.tprintf("expected the IDs in order, got %v", decoded.userIds),
		)
	}
	{
		keys := make([dynamic]UserKeyBundle, 0, 2)
		defer delete(keys)
		append(&keys, bundle, protocolTestBundle(9))
		missing := make([dynamic]int, 0, 1)
		defer delete(missing)
		append(&missing, 11)
		encoded, err := cbor.marshal(ServerUserKeysPayload{keys = keys, missingUserIds = missing})
		assert(err == nil, "expected ServerUserKeysPayload encoding to succeed")
		defer delete(encoded)
		decoded: ServerUserKeysPayload
		assert(cbor.unmarshal(encoded, &decoded) == nil, "expected user keys decoding")
		defer ServerUserKeysPayload_deinit(&decoded)
		assert(
			len(decoded.keys) == 2 &&
			decoded.keys[0] == keys[0] &&
			decoded.keys[1] == keys[1] &&
			len(decoded.missingUserIds) == 1 &&
			decoded.missingUserIds[0] == 11,
			fmt.tprintf("expected both bundles and 11 missing, got %v", decoded),
		)
	}
	{
		encoded, err := cbor.marshal(ServerUserKeyChangedPayload{bundle = bundle})
		assert(err == nil, "expected ServerUserKeyChangedPayload encoding to succeed")
		defer delete(encoded)
		decoded: ServerUserKeyChangedPayload
		assert(cbor.unmarshal(encoded, &decoded) == nil, "expected key changed decoding")
		assert(decoded.bundle == bundle, fmt.tprintf("expected %v, got %v", bundle, decoded))
	}
	{
		original := UserSummary {
			id                = 5,
			nickname          = "keys",
			isOnline          = true,
			identityPublicKey = bundle.identityPublicKey,
			hasEncryptionKey  = true,
		}
		encoded, err := cbor.marshal(original)
		assert(err == nil, "expected UserSummary encoding to succeed")
		defer delete(encoded)
		decoded: UserSummary
		assert(cbor.unmarshal(encoded, &decoded) == nil, "expected UserSummary decoding")
		defer delete(decoded.nickname)
		assert(
			decoded.id == 5 &&
			decoded.nickname == "keys" &&
			decoded.identityPublicKey == original.identityPublicKey &&
			decoded.hasEncryptionKey,
			fmt.tprintf("expected the key fields to survive, got %v", decoded),
		)
	}
	// The bundle converts to the verifier's shape field for field.
	converted := UserKeyBundle_toEncryptionKeyBundle(bundle)
	assert(
		converted.identityPublicKey == bundle.identityPublicKey &&
		converted.encryptionPublicKey == bundle.encryptionPublicKey &&
		converted.createdAt == bundle.createdAt &&
		converted.signature == bundle.signature,
		"expected the conversion to keep every field",
	)
}

@(test)
testUserKeysFetchListRules :: proc(t: ^testing.T) {
	_ = t
	full: [USER_KEYS_FETCH_MAX + 1]int
	for index in 0 ..< len(full) {
		full[index] = index + 1
	}
	Case :: struct {
		ids:   []int,
		valid: bool,
	}
	cases := [?]Case {
		{nil, false},
		{[]int{1}, true},
		{[]int{1, 2, 3}, true},
		{full[:USER_KEYS_FETCH_MAX], true},
		{full[:], false},
		{[]int{1, 2, 1}, false},
		{[]int{0}, false},
		{[]int{4, -2}, false},
	}
	for testCase, index in cases {
		assert(
			userKeysFetchIsValid(testCase.ids) == testCase.valid,
			fmt.tprintf("expected case %d (%d IDs) valid=%v", index, len(testCase.ids),
				testCase.valid),
		)
	}
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

// The retired role placeholders (protocol 23) must stay where they are: removing them would
// renumber every member after them.
@(test)
testRetiredRolePlaceholdersKeepTheirPlace :: proc(t: ^testing.T) {
	_ = t
	assert(
		int(MessageType.ClientGetRoles) == 24 &&
		int(MessageType.ServerUserRoles) == 25 &&
		int(MessageType.ClientGetPermissions) == 26 &&
		int(MessageType.ServerUserPermissions) == 27 &&
		int(MessageType.ClientAddRole) == 28 &&
		int(MessageType.ServerAddedRole) == 29 &&
		int(MessageType.ClientRemoveRole) == 30 &&
		int(MessageType.ServerRemovedRole) == 31,
		fmt.tprintf(
			"expected the retired role placeholders at 24..31, got %d..%d",
			int(MessageType.ClientGetRoles),
			int(MessageType.ServerRemovedRole),
		),
	)
}

// Protocol 23 (#95): server permissions are bit numbers on the wire (a u64 bit_set) and in
// server_roles.permissions. Never renumber them.
@(test)
testServerPermissionWireValuesArePinned :: proc(t: ^testing.T) {
	_ = t
	assert(
		int(ServerPermission.ManageRooms) == 0 &&
		int(ServerPermission.ManageRoomMembers) == 1 &&
		int(ServerPermission.CreateInvites) == 2 &&
		int(ServerPermission.ApproveRegistrations) == 3 &&
		int(ServerPermission.ManageRoles) == 4 &&
		int(ServerPermission.ManageRegistration) == 5 &&
		int(ServerPermission.KickUsers) == 6 &&
		int(ServerPermission.BanUsers) == 7 &&
		int(ServerPermission.RenameUsers) == 8,
		"expected ServerPermission to stay ManageRooms 0 .. RenameUsers 8",
	)
	assert(
		serverPermissionsMask(SERVER_PERMISSIONS_ALL) == 511,
		fmt.tprintf(
			"expected every permission to be mask 511, got %d",
			serverPermissionsMask(SERVER_PERMISSIONS_ALL),
		),
	)
	assert(
		serverPermissionsMask(SERVER_PERMISSIONS_ASSIGNABLE) == 15,
		"expected the assignable permissions to be mask 15",
	)
	assert(
		serverPermissionsFromMask(-1) == SERVER_PERMISSIONS_ALL,
		"expected mask -1 (an admin in the database) to read as every permission",
	)
	assert(
		serverPermissionsFromMask(0b11) == ServerPermissions{.ManageRooms, .ManageRoomMembers},
		"expected mask 3 to read as ManageRooms and ManageRoomMembers",
	)
	assert(
		int(AdminAction.SaveRole) == 4 &&
		int(AdminAction.DeleteRole) == 5 &&
		int(AdminAction.SetUserRoles) == 6,
		"expected AdminAction to stay SaveRole 4, DeleteRole 5, SetUserRoles 6",
	)

	// On the wire the set is one unsigned integer, the mask.
	encoded, err := cbor.marshal(
		ServerAccountUpdatedPayload {
			isAdmin = false,
			nickname = "bob",
			permissions = {.ManageRooms, .CreateInvites},
		},
	)
	assert(err == nil, "expected ServerAccountUpdatedPayload encoding to succeed")
	defer delete(encoded)
	decoded: ServerAccountUpdatedPayload
	assert(cbor.unmarshal(encoded, &decoded) == nil, "expected it to decode")
	defer ServerAccountUpdatedPayload_deinit(&decoded)
	assert(
		decoded.permissions == ServerPermissions{.ManageRooms, .CreateInvites} &&
		decoded.nickname == "bob",
		fmt.tprintf("expected ManageRooms and CreateInvites for bob, got %v", decoded),
	)
}

@(test)
testRoleNamesAreValidated :: proc(t: ^testing.T) {
	_ = t
	for name in ([]string{"mod", "Room managers", "Ünïcødé", "abcdefghijklmnopqrstuvwxyz012345"}) {
		assert(roleNameIsValid(name), fmt.tprintf("expected %q to be a valid role name", name))
	}
	for name in ([]string {
			"",
			"ab",
			" mod",
			"mod ",
			"mo\nd",
			"abcdefghijklmnopqrstuvwxyz0123456",
			"éé",
		}) {
		assert(!roleNameIsValid(name), fmt.tprintf("expected %q to be refused", name))
	}
}

@(test)
testRolePayloadsRoundTripOverCBOR :: proc(t: ^testing.T) {
	_ = t
	roles := make([dynamic]RoleSummary, context.temp_allocator)
	append(
		&roles,
		RoleSummary{id = 1, name = "admin", permissions = SERVER_PERMISSIONS_ALL, builtin = true},
		RoleSummary{id = 4, name = "mods", permissions = {.ManageRoomMembers}, position = 2},
	)
	encoded, err := cbor.marshal(ServerRoleListPayload{roles = roles})
	assert(err == nil, "expected ServerRoleListPayload encoding to succeed")
	defer delete(encoded)
	decoded: ServerRoleListPayload
	assert(cbor.unmarshal(encoded, &decoded) == nil, "expected ServerRoleListPayload to decode")
	defer ServerRoleListPayload_deinit(&decoded)
	assert(
		len(decoded.roles) == 2 &&
		decoded.roles[0].builtin &&
		decoded.roles[0].permissions == SERVER_PERMISSIONS_ALL &&
		decoded.roles[1].name == "mods" &&
		decoded.roles[1].permissions == {.ManageRoomMembers} &&
		decoded.roles[1].position == 2,
		fmt.tprintf("expected admin and mods, got %v", decoded.roles),
	)

	roleIDs := make([dynamic]int, context.temp_allocator)
	append(&roleIDs, 4, 7)
	encodedSet, setErr := cbor.marshal(
		ClientAdminSetUserRolesPayload{userId = 9, roleIds = roleIDs},
	)
	assert(setErr == nil, "expected ClientAdminSetUserRolesPayload encoding to succeed")
	defer delete(encodedSet)
	decodedSet: ClientAdminSetUserRolesPayload
	assert(cbor.unmarshal(encodedSet, &decodedSet) == nil, "expected it to decode")
	defer ClientAdminSetUserRolesPayload_deinit(&decodedSet)
	assert(
		decodedSet.userId == 9 && len(decodedSet.roleIds) == 2 && decodedSet.roleIds[1] == 7,
		fmt.tprintf("expected user 9 with roles 4 and 7, got %v", decodedSet),
	)

	user := UserSummary{id = 9, nickname = "bob", roleIds = roleIDs}
	encodedUser, userErr := cbor.marshal(ServerUserUpdatedPayload{user = user})
	assert(userErr == nil, "expected ServerUserUpdatedPayload encoding to succeed")
	defer delete(encodedUser)
	decodedUser: ServerUserUpdatedPayload
	assert(cbor.unmarshal(encodedUser, &decodedUser) == nil, "expected it to decode")
	defer ServerUserUpdatedPayload_deinit(&decodedUser)
	assert(
		len(decodedUser.user.roleIds) == 2 && decodedUser.user.roleIds[0] == 4,
		fmt.tprintf("expected roles 4 and 7 on bob, got %v", decodedUser.user.roleIds),
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
			delete(message.envelope)
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
		for &user in decoded.users {
			UserSummary_deinit(&user)
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
			delete(conversation.lastEnvelope)
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

// Protocol 24 (#96): room permissions are bit numbers on the wire (a u64 bit_set) and in
// rooms.everyone_permissions and room_role_permissions.permissions. Never renumber them.
@(test)
testRoomPermissionWireValuesArePinned :: proc(t: ^testing.T) {
	_ = t
	assert(
		int(RoomPermission.SendMessages) == 0 &&
		int(RoomPermission.SpeakInVoice) == 1 &&
		int(RoomPermission.ManageMembers) == 2 &&
		int(RoomPermission.EditRoom) == 3 &&
		int(RoomPermission.AttachFiles) == 4,
		"expected RoomPermission to stay SendMessages 0, SpeakInVoice 1, ManageMembers 2, " +
		"EditRoom 3, AttachFiles 4",
	)
	assert(
		roomPermissionsMask(ROOM_PERMISSIONS_ALL) == 31 &&
		roomPermissionsMask(ROOM_PERMISSIONS_DEFAULT) == 19,
		"expected every room permission to be mask 31 and the default (send, speak, attach) " +
		"mask 19",
	)
	assert(
		roomPermissionsFromMask(-1) == ROOM_PERMISSIONS_ALL &&
		roomPermissionsFromMask(0b10) == RoomPermissions{.SpeakInVoice},
		"expected mask -1 to read as every room permission and 2 as SpeakInVoice",
	)
}

@(test)
testRoomPermissionPayloadsRoundTripOverCBOR :: proc(t: ^testing.T) {
	_ = t
	roles := make([dynamic]RoomRoleGrant, context.temp_allocator)
	append(&roles, RoomRoleGrant{roleId = 4, permissions = {.SendMessages, .ManageMembers}})
	encoded, err := cbor.marshal(
		ClientAdminSetRoomPermissionsPayload {
			roomId = 7,
			everyone = {.SpeakInVoice},
			roles = roles,
		},
	)
	assert(err == nil, "expected ClientAdminSetRoomPermissionsPayload encoding to succeed")
	defer delete(encoded)
	decoded: ClientAdminSetRoomPermissionsPayload
	assert(cbor.unmarshal(encoded, &decoded) == nil, "expected it to decode")
	defer ClientAdminSetRoomPermissionsPayload_deinit(&decoded)
	assert(
		decoded.roomId == 7 &&
		decoded.everyone == RoomPermissions{.SpeakInVoice} &&
		len(decoded.roles) == 1 &&
		decoded.roles[0].roleId == 4 &&
		decoded.roles[0].permissions == RoomPermissions{.SendMessages, .ManageMembers},
		fmt.tprintf("expected the grants back, got %v", decoded),
	)
	assert(roomPermissionsRequestIsValid(decoded), "expected the request to be valid")
	duplicate := decoded
	duplicate.roles = make([dynamic]RoomRoleGrant, context.temp_allocator)
	append(&duplicate.roles, RoomRoleGrant{roleId = 4}, RoomRoleGrant{roleId = 4})
	assert(!roomPermissionsRequestIsValid(duplicate), "expected a repeated role to be refused")
	duplicate.roles = nil
	duplicate.roomId = 0
	assert(!roomPermissionsRequestIsValid(duplicate), "expected room 0 to be refused")

	accessRoles := make([dynamic]int, context.temp_allocator)
	append(&accessRoles, 4, 9)
	answer, answerErr := cbor.marshal(
		ServerAdminRoomPermissionsPayload {
			roomId = 7,
			everyone = ROOM_PERMISSIONS_DEFAULT,
			roles = roles,
			accessRoleIds = accessRoles,
			myPermissions = ROOM_PERMISSIONS_ALL,
		},
	)
	assert(answerErr == nil, "expected ServerAdminRoomPermissionsPayload encoding to succeed")
	defer delete(answer)
	decodedAnswer: ServerAdminRoomPermissionsPayload
	assert(cbor.unmarshal(answer, &decodedAnswer) == nil, "expected the answer to decode")
	defer ServerAdminRoomPermissionsPayload_deinit(&decodedAnswer)
	assert(
		decodedAnswer.everyone == ROOM_PERMISSIONS_DEFAULT &&
		len(decodedAnswer.accessRoleIds) == 2 &&
		decodedAnswer.accessRoleIds[1] == 9 &&
		decodedAnswer.myPermissions == ROOM_PERMISSIONS_ALL,
		fmt.tprintf("expected the answer back, got %v", decodedAnswer),
	)

	// RoomSummary.myPermissions and a Role room's access roles on create.
	listEncoded, listErr := cbor.marshal(
		RoomSummary{id = 3, name = "ops", access = .Role, myPermissions = {.SpeakInVoice}},
	)
	assert(listErr == nil, "expected RoomSummary encoding to succeed")
	defer delete(listEncoded)
	room: RoomSummary
	assert(cbor.unmarshal(listEncoded, &room) == nil, "expected RoomSummary to decode")
	defer delete(room.name)
	defer delete(room.description)
	assert(
		room.access == .Role && room.myPermissions == RoomPermissions{.SpeakInVoice},
		fmt.tprintf("expected a Role room with SpeakInVoice, got %v", room),
	)
	create, createErr := cbor.marshal(
		ClientCreateRoomPayload{name = "ops", access = .Role, accessRoleIds = accessRoles},
	)
	assert(createErr == nil, "expected ClientCreateRoomPayload encoding to succeed")
	defer delete(create)
	decodedCreate: ClientCreateRoomPayload
	assert(cbor.unmarshal(create, &decodedCreate) == nil, "expected the create to decode")
	defer ClientCreateRoomPayload_deinit(&decodedCreate)
	assert(
		len(decodedCreate.accessRoleIds) == 2 &&
		roomAccessRolesAreValid(decodedCreate.access, decodedCreate.accessRoleIds[:]),
		fmt.tprintf("expected two access roles, got %v", decodedCreate),
	)
	assert(
		!roomAccessRolesAreValid(.Role, nil) &&
		!roomAccessRolesAreValid(.MemberInvite, decodedCreate.accessRoleIds[:]) &&
		roomAccessRolesAreValid(.Public, nil),
		"expected a Role room to need access roles and other rooms to have none",
	)
}

// Protocol 27: attachments ride on every message payload and the auth success limits, and a
// decoded payload owns their strings (freed by the *_deinit helpers).
@(test)
testAttachmentRefsRoundTripOverCBOR :: proc(t: ^testing.T) {
	_ = t
	refs := make([dynamic]AttachmentRef, context.temp_allocator)
	append(
		&refs,
		AttachmentRef {
			blobId = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16},
			size = 1234,
			sha256 = {0 = 0xAA, 31 = 0xBB},
			name = "report.pdf",
			mediaType = "application/pdf",
		},
		AttachmentRef{blobId = {0 = 9, 15 = 9}, size = 77, removed = true},
	)
	message := ServerChatMessagePayload {
		id          = 5,
		senderId    = 2,
		roomId      = 1,
		timestamp   = "now",
		attachments = refs,
	}
	encoded, err := cbor.marshal(message)
	defer delete(encoded)
	assert(err == nil, "expected the chat message with attachments to encode")
	decoded: ServerChatMessagePayload
	decodeErr := cbor.unmarshal(encoded, &decoded, temp_allocator = context.allocator)
	defer ServerChatMessagePayload_deinit(&decoded)
	assert(decodeErr == nil, fmt.tprintf("expected it to decode, got %v", decodeErr))
	assert(len(decoded.attachments) == 2, "expected both attachments back")
	assert(
		decoded.attachments[0].blobId == refs[0].blobId &&
		decoded.attachments[0].sha256 == refs[0].sha256 &&
		decoded.attachments[0].size == 1234 &&
		decoded.attachments[0].name == "report.pdf" &&
		decoded.attachments[0].mediaType == "application/pdf" &&
		!decoded.attachments[0].removed,
		"expected the plaintext reference unchanged",
	)
	assert(
		decoded.attachments[1].removed && decoded.attachments[1].size == 77,
		"expected the removed flag and the size of the sealed reference",
	)

	auth := ServerAuthSuccessPayload {
		userId      = 3,
		message     = "ok",
		nickname    = "alice",
		attachments = {enabled = true, maxBytes = 25 << 20, quotaBytes = 1 << 30, usedBytes = 99},
	}
	authBytes, authErr := cbor.marshal(auth)
	defer delete(authBytes)
	assert(authErr == nil, "expected the auth success to encode")
	authDecoded: ServerAuthSuccessPayload
	assert(cbor.unmarshal(authBytes, &authDecoded) == nil, "expected the auth success to decode")
	defer ServerAuthSuccessPayload_deinit(&authDecoded)
	assert(authDecoded.attachments == auth.attachments, "expected the limits unchanged")

	// A message from a protocol 26 peer (no attachments key) decodes with none.
	Old :: struct {
		recipientUserId: int,
		content:         string,
	}
	old, oldErr := cbor.marshal(Old{recipientUserId = 4, content = "hi"})
	defer delete(old)
	assert(oldErr == nil, "expected the old payload to encode")
	direct: ClientDirectMessagePayload
	assert(
		cbor.unmarshal(old, &direct, temp_allocator = context.allocator) == nil,
		"expected the old direct message to decode",
	)
	defer ClientDirectMessagePayload_deinit(&direct)
	assert(direct.content == "hi" && len(direct.attachments) == 0, "expected no attachments")
}
