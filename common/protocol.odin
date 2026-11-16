package common

import "core:time/datetime"

// The common protocol that both the server and client will use to communicate.
// This includes things like message formats, enums, and transport handshake data.
// It must remain shared between the client and server.

ProtocolVersion :: u32
protocolVersion: ProtocolVersion = 22
GENERAL_ROOM_ID :: int(1)
// Largest room or direct message the server accepts, in bytes of UTF-8 content.
CHAT_MESSAGE_MAX_BYTES :: 4000
// Largest page a room or direct history request may ask for; limit must be 1..this.
HISTORY_PAGE_MAX_MESSAGES :: 50
// Most conversations ServerDirectConversations lists, newest first.
DIRECT_CONVERSATIONS_MAX :: 100
// Room names are 1..ROOM_NAME_MAX_BYTES bytes and descriptions at most
// ROOM_DESCRIPTION_MAX_BYTES; the server refuses anything else with "Invalid room metadata".
ROOM_NAME_MAX_BYTES :: 64
ROOM_DESCRIPTION_MAX_BYTES :: 256
// Unread counts are capped: a room or conversation with this many unread messages or more may
// report exactly this many, and clients show it as "99+". It keeps the list queries cheap.
UNREAD_COUNT_CAP :: 100
// Display names (ClientHello.nickname, ClientAdminRenameUser.nickname) are 3..32 bytes.
NICKNAME_MIN_BYTES :: 3
NICKNAME_MAX_BYTES :: 32
// Kick and ban reasons (protocol 14) are at most this many bytes; users.ban_reason is
// VARCHAR(256).
ADMIN_REASON_MAX_BYTES :: 256

// Packet is the logical application packet format.
// Handshake packets are encoded directly as Packet values.
// After authentication succeeds, application packets are encoded as Packet values,
// encrypted, and carried inside EncryptedPacket.
Packet :: struct {
	messageType: MessageType,
	payload:     []u8,
}

EncryptedPacket :: struct {
	sessionID:  SessionID,
	sequence:   u64,
	nonce:      TransportNonce,
	tag:        TransportTag,
	ciphertext: []u8,
}

ClientHello :: struct {
	version:                  ProtocolVersion,
	nickname:                 string,
	clientIdentityPublicKey:  IdentityPublicKeyBytes,
	clientEphemeralPublicKey: KeyExchangePublicKeyBytes,
}

ServerHelloProof :: struct {
	version:                  ProtocolVersion,
	sessionID:                SessionID,
	nickname:                 string,
	clientIdentityPublicKey:  IdentityPublicKeyBytes,
	clientEphemeralPublicKey: KeyExchangePublicKeyBytes,
	serverIdentityPublicKey:  IdentityPublicKeyBytes,
	serverEphemeralPublicKey: KeyExchangePublicKeyBytes,
}

ServerHello :: struct {
	version:                  ProtocolVersion,
	sessionID:                SessionID,
	serverIdentityPublicKey:  IdentityPublicKeyBytes,
	serverEphemeralPublicKey: KeyExchangePublicKeyBytes,
	signature:                SignatureBytes,
}

ClientRegisterRequest :: struct {
	nickname: string,
}

ServerRegisterResponsePayload :: struct {
	success: bool,
	message: string,
	userId:  int,
}

ClientAuthProof :: struct {
	sessionID:                SessionID,
	challenge:                AuthChallengeBytes,
	nickname:                 string,
	clientIdentityPublicKey:  IdentityPublicKeyBytes,
	clientEphemeralPublicKey: KeyExchangePublicKeyBytes,
	serverIdentityPublicKey:  IdentityPublicKeyBytes,
	serverEphemeralPublicKey: KeyExchangePublicKeyBytes,
}

ServerAuthChallengePayload :: struct {
	sessionID: SessionID,
	challenge: AuthChallengeBytes,
}

ClientAuthRequestPayload :: struct {
	sessionID: SessionID,
	signature: SignatureBytes,
}

// isAdmin (protocol 8) tells the client whether the account holds the server's admin role at
// the moment it signed in, so it can offer room management. It is a hint for the UI only: the
// server checks the role again on every admin request. A role an admin changes from a client
// while the account is connected arrives as ServerAccountUpdated (protocol 14); one changed
// directly in the database shows up on the next connection.
//
// nickname and nicknameLocked (protocol 14): the account's name on this server, and whether an
// admin set it. While it is locked, a sign-in keeps the account's name whatever ClientHello
// asked for, so nickname can differ from the one the client sent. message and nickname are
// owned once decoded.
ServerAuthSuccessPayload :: struct {
	userId:         int,
	message:        string,
	isAdmin:        bool,
	nickname:       string,
	nicknameLocked: bool,
}

ServerAuthFailurePayload :: struct {
	message: string,
}

NicknameChange :: struct {
	userId:      int, // ID of the user changing their nickname, included in the message from the client to the server, and in the notification from the server to all clients
	newNickname: string, // The new nickname that the user wants to use
}

Roles :: struct {
	userId: int, // ID of the user whose roles are being queried or modified
	roles:  [dynamic]Role, // List of roles that the user has been assigned, included in the response from the server to the client when the client requests their roles
}

Permissions :: struct {
	userId:      int, // ID of the user whose permissions are being queried or modified
	resource:    string, // Name of the resource for which permissions are being queried or modified (e.g. "room:general", "forum:123", etc.)
	permissions: [dynamic]string, // List of permissions for the user on the specified resource (e.g. "canJoinRoom", "canPostInRoom", etc.), included in the response from the server to the client when the client requests their permissions for a resource
}

Role :: struct {
	id:          int, // Unique ID of the role
	name:        string, // Name of the role (e.g. "admin", "moderator", "member", etc.)
	permissions: [dynamic]string, // List of permissions that this role grants to users who have been assigned this role
}

User :: struct {
	id:            int, // Unique ID of the user
	authPublicKey: IdentityPublicKeyBytes, // User's long-lived identity public key
	nickname:      string, // User's nickname
	color:         string, // User color in hex format for client display
	roles:         [dynamic]Role, // List of roles that the user has been assigned
	currentRoom:   int, // ID of the room the user is currently in, or -1 when not in a room
}

MessageType :: enum {
	None = 0, // Placeholder for uninitialized message type, should not be used in actual messages

	// Connection management
	Ping = 10, // Simple ping message to check if the connection is alive, includes a timestamp that the recipient should include in the response to measure latency
	Pong, // Response to Ping message, includes the timestamp from the original Ping message for latency measurement

	// Authentication & Session Management
	ClientHello, // Starts the transport handshake with identity and ephemeral keys
	ServerHello, // Returns the server identity, ephemeral key, session ID, and proof
	ClientRegister, // Optional pre-auth registration request carrying nickname data
	ServerRegisterResponse, // Registration result for a ClientRegister request
	ServerAuthChallenge, // Signed challenge that the client must answer to authenticate
	ClientAuthRequest, // Challenge response signed by the client's long-lived identity key
	ServerAuthSuccess, // Authentication succeeded and encrypted application traffic may begin
	ServerAuthFailure, // Authentication failed and the session should be closed
	EncryptedPacket, // Outer encrypted transport envelope for all post-auth application packets

	// User Management
	ClientChangeNickname, // Request to change a user's nickname (only allowed for certain admin users or the user themselves), includes user ID and new nickname
	ServerNicknameChange, // Notification of a nickname change, includes old and new nickname
	ClientGetNickname, // Request to get a user's nickname, includes user ID
	ClientGetRoles, // Request to get a user's roles, includes user ID
	ServerUserRoles, // Response to ClientGetRoles, includes list of role names that the user has been assigned
	ClientGetPermissions, // Request to get a user's permissions of the requested resource, includes user ID and resource name
	ServerUserPermissions, // Response to ClientGetPermissions, includes list of permissions for the requested resource (e.g. canJoinRoom, canPostInRoom, etc.)
	ClientAddRole, // Request to add a role to a user, includes user ID and role name (only allowed for certain admin users)
	ServerAddedRole, // Notification that a role has been added to a user, includes role name
	ClientRemoveRole, // Request to remove a role from a user, includes user ID and role name (only allowed for certain admin users)
	ServerRemovedRole, // Notification that a role has been removed from a user, includes role name
	ClientSetPermissions, // Request to set a user's permissions for a resource, includes user ID, resource name and list of permissions (only allowed for certain admin users)
	ServerSetPermissions, // Notification that a user's permissions for a resource have been changed, includes resource name and new list of permissions

	// Room Management
	ClientRequestJoinRoom, // Request to join a chat room, includes room name
	ServerRoomJoin, // Notification of a user joining a room, includes room name and nickname
	ClientLeaveRoom, // Client states that they are leaving a room, includes room name. No more messages from that client will be accepted for that room until they send another ClientRequestJoinRoom
	ServerRoomLeave, // Notification of a user leaving a room, includes room name and nickname
	ClientRequestCreateRoom, // Request to create a chat room, includes room name
	ServerRoomCreate, // Notification of a room being created, includes room name
	ClientRequestDeleteRoom, // Request to delete a chat room, includes room name
	ServerRoomDelete, // Notification of a room being deleted, includes room name
	ClientGetRoomDetails, // Request to get details about a room, includes room name
	ServerRoomDetails, // Response to ClientGetRoomDetails, includes room details such as room name, list of participants, etc.
	ClientListRooms, // Request a list of available chat rooms
	ServerListRooms, // Response to ClientListRooms, includes list of rooms and their details (e.g. name, type, number of participants, etc.)
	ClientFetchRoomHistory, // Request a cursor-paginated page of persisted room messages
	ServerRoomHistory, // Response containing a cursor-paginated page of persisted room messages
	ClientChangeRoomPermissions, // Request to change a room's permissions (e.g. who can join, who can post, etc.), includes room name and new permissions
	ServerRoomPermissions, // Response to ClientChangeRoomPermissions, includes room name and new permissions
	ServerRoomPermissionsChange, // Notification of a room's permissions changing, includes room name and new permissions
	ClientCreateRoom, // Request to create a room (only allowed for certain admin users), includes room name and type
	ServerCreateRoom, // Notification of a room being created, includes room name and type
	ClientDeleteRoom, // Request to delete a room (only allowed for certain admin users), includes room name
	ServerDeleteRoom, // Notification of a room being deleted, includes room name
	ClientEditRoom, // Request to edit a room's details (only allowed for certain admin users), includes room name and new details (e.g. new name, new type, etc.)
	ServerEditRoom, // Notification of a room's details being edited, includes room name and new details (e.g. new name, new type, etc.)
	ClientAddRoomMember, // Request to add a member to a room (only allowed for certain admin users)
	ClientRemoveRoomMember, // Request to remove a member from a room (only allowed for certain admin users)
	ServerRoomMemberAdded, // Result of an admin request to add a room member
	ServerRoomMemberRemoved, // Result of an admin request to remove a room member
	ServerRoomMembershipChanged, // Notification that the authenticated user's room membership changed

	// Messaging
	ClientChatMessage, // Chat message sent from client to server
	ServerChatMessage, // Chat message broadcasted from server to clients
	// Retired placeholders, never sent: voice frames are binary datagrams on ENet channel 2
	// (common/voice_wire.odin) and have no MessageType. Kept so that the members after them,
	// ClientDirectMessage and ServerDirectMessage among them, keep their wire values.
	ClientVoiceData,
	ServerVoiceData,
	ClientVideoData, // Video data sent from client to server
	ServerVideoData, // Video data broadcasted from server to clients
	ClientDirectMessage, // ClientDirectMessagePayload: send a direct message to one account
	ServerDirectMessage, // ServerDirectMessagePayload: a stored direct message, to both users
	ServerNotification, // Server notification (e.g. user joined/left, new message, server shutdown, etc.), includes message string

	// Forum Management
	ClientCreateForumPost, // Request to create a forum post, includes room name and post content
	ServerForumPostCreated, // Notification of a forum post being created, includes room name, post ID, author user ID and post content
	ClientCreateForumComment, // Request to create a forum comment, includes room name, post ID and comment content
	ServerForumCommentCreated, // Notification of a forum comment being created, includes room name, post ID, comment ID, author user ID and comment content
	ClientListForumPosts, // Request a list of forum posts in a room, includes room name
	ServerForumPostsList, // Response to ClientListForumPosts, includes room name and list of forum posts with their details (e.g. post ID, author user ID, content, etc.)
	ClientListForumComments, // Request a list of comments for a forum post, includes room name and post ID
	ServerForumCommentsList, // Response to ClientListForumComments, includes room name, post ID and list of comments for that post with their details (e.g. comment ID, author user ID, content, etc.)
	ClientDeleteForumPost, // Request to delete a forum post, includes room name and post ID
	ServerForumPostDeleted, // Notification of a forum post being deleted, includes room name and post ID
	ClientDeleteForumComment, // Request to delete a forum comment, includes room name, post ID and comment ID
	ServerForumCommentDeleted, // Notification of a forum comment being deleted, includes room name, post ID and comment ID
	ClientEditForumPost, // Request to edit a forum post, includes room name, post ID and new content
	ServerForumPostEdited, // Notification of a forum post being edited, includes room name, post ID and new content
	ClientEditForumComment, // Request to edit a forum comment, includes room name, post ID, comment ID and new content
	ServerForumCommentEdited, // Notification of a forum comment being edited, includes room name, post ID, comment ID and new content
	ClientUpvoteForumPost, // Request to upvote a forum post, includes room name and post ID
	ServerForumPostUpvoted, // Notification of a forum post being upvoted, includes room name, post ID and user ID of the voter
	ClientDownvoteForumPost, // Request to downvote a forum post, includes room name and post ID
	ServerForumPostDownvoted, // Notification of a forum post being downvoted, includes room name, post ID and user ID of the voter
	ClientUpvoteForumComment, // Request to upvote a forum comment, includes room name, post ID and comment ID
	ServerForumCommentUpvoted, // Notification of a forum comment being upvoted, includes room name, post ID, comment ID and user ID of the voter
	ClientDownvoteForumComment, // Request to downvote a forum comment, includes room name, post ID and comment ID
	ServerForumCommentDownvoted, // Notification of a forum comment being downvoted, includes room name, post ID, comment ID and user ID of the voter
	ClientChangeForumPostPermissions, // Request to change permissions for a forum post, includes room name, post ID and new permissions
	ServerForumPostPermissionsChange, // Notification of a forum post's permissions changing, includes room name, post ID and new permissions
	ClientChangeForumCommentPermissions, // Request to change permissions for a forum comment, includes room name, post ID, comment ID and new permissions
	ServerForumCommentPermissionsChange, // Notification of a forum comment's permissions changing, includes room name, post ID, comment ID and new permissions
	ClientListForumPostPermissions, // Request a list of permissions for a forum post, includes room name and post ID
	ClientListForumCommentPermissions, // Request a list of permissions for a forum comment, includes room name, post ID and comment ID
	ClientListUserPermissions, // Request a list of permissions for a user, includes user ID
	ClientModerateForumPost, // Request to moderate a forum post (e.g. delete, edit, etc.), includes room name, post ID and moderation action
	ClientModerateForumComment, // Request to moderate a forum comment (e.g. delete, edit, etc.), includes room name, post ID, comment ID and moderation action

	// Admin Management & Control
	ClientServerStatus, // Request current server status (e.g. uptime, number of connected clients, etc.)
	ServerServerStatus, // Response to ClientServerStatus, includes current server status (e.g. uptime, number of connected clients, etc.)
	ClientUserList, // ClientListUsersPayload: request every account on the server
	ServerUserList, // ServerUserListPayload: every account with its online flag
	ClientEvents, // Request recent server events (e.g. for displaying in the client UI)
	ServerEvents, // Response to ClientEvents, includes recent server events (e.g. for displaying in the client UI)
	ClientKickUser, // Request to kick a user from the server, includes user ID and reason (only allowed for certain admin users)
	ServerKickUser, // Response to ClientKickUser, includes success/failure and reason if failure
	ClientBanUser, // Request to ban a user from the server, includes user ID and reason (only allowed for certain admin users)
	ServerBanUser, // Response to ClientBanUser, includes success/failure and reason if failure
	ClientUnbanUser, // Request to unban a user from the server, includes user ID (only allowed for certain admin users)
	ServerUnbanUser, // Response to ClientUnbanUser, includes success/failure and reason if failure
	ClientRestartServer, // Request to restart the server (only allowed for certain admin users)
	ServerRestartServer, // Response to ClientRestartServer, includes success/failure and reason if failure
	ClientShutdownServer, // Request to shutdown the server (only allowed for certain admin users)
	ServerShutdownServer, // Response to ClientShutdownServer, includes success/failure and reason if failure

	// File Management
	ClientStoreFile, // Request to store file content on server
	ServerStoreFileResponse, // Response to ClientStoreFile, includes success/failure and stored hash name
	ServerProtocolError, // Generic protocol decode/validation error response

	// File Management
	// Upload operations
	ClientUploadFile, // Request to upload a file, includes file metadata (e.g. filename, size, etc.) and file data
	ServerUploadFileResponse, // Response to ClientUploadFile, includes success/failure and reason if failure, and file URL if success

	// Download operations
	ClientDownloadFile, // Request to download a file, includes file ID
	ServerDownloadFileResponse, // Response to ClientDownloadFile, includes success/failure and reason if failure, and file data if success

	// Delete operations
	ClientDeleteFile, // Request to delete a file, includes file ID
	ServerDeleteFileResponse, // Response to ClientDeleteFile, includes success/failure and reason if failure, and file ID if success

	// Server Status Notifications (server-only, no client counterpart)
	ServerRestart, // Notification of the server restarting, includes estimated downtime
	ServerShutdown, // Notification of the server shutting down, includes estimated downtime

	// Error Messages (server-only, no client counterpart)
	ServerError, // Generic error message, includes error string
	ServerDenied, // Generic denied message for when a client tries to perform an action they don't have permission for, includes reason string
	ServerInternalError, // Generic internal error message for when something goes wrong on the server, includes error string
	ServerValidationError, // Generic validation error message for when the client sends invalid data, includes error string
	ServerAuthenticationError, // Generic authentication error message for when there is an authentication issue (e.g. invalid session token, failed signature verification, etc.), includes error string

	// Direct messages (protocol 7). Appended after every older member so no existing wire
	// value moves; ClientDirectMessage, ServerDirectMessage, ClientUserList and ServerUserList
	// above complete the set.
	ClientFetchDirectHistory, // ClientFetchDirectHistoryPayload: page of a conversation
	ServerDirectHistory, // ServerDirectHistoryPayload: response to ClientFetchDirectHistory
	ClientListDirectConversations, // ClientListDirectConversationsPayload: recent conversations
	ServerDirectConversations, // ServerDirectConversationsPayload: latest message per peer
	ServerUserPresence, // ServerUserPresencePayload: a user came online or went offline

	// Voice control (protocol 10), CBOR on the reliable control channel. The frames themselves
	// are binary datagrams on ENet channel 2 (common/voice_wire.odin).
	ClientJoinVoice, // ClientJoinVoicePayload: join one room's voice session
	ClientLeaveVoice, // ClientLeaveVoicePayload: leave the current voice session
	ClientVoiceState, // ClientVoiceStatePayload: mute or deafen changed while joined
	ServerVoiceParticipants, // ServerVoiceParticipantsPayload: a room's full participant set
	ServerVoiceJoinRejected, // ServerVoiceJoinRejectedPayload: a ClientJoinVoice was refused
	ServerVoiceLeft, // ServerVoiceLeftPayload: the server removed this session from voice

	// Read state (protocol 11), appended so no existing wire value moves.
	ClientMarkRead, // ClientMarkReadPayload: mark a room or conversation read up to a message
	ServerReadMarker, // ServerReadMarkerPayload: a read marker moved, to every session of the user

	// Admin actions on accounts (protocol 14), appended so no existing wire value moves. The
	// older ClientKickUser, ClientBanUser and ClientUnbanUser placeholders above were never
	// sent and stay unused.
	ClientAdminSetRole, // ClientAdminSetRolePayload: grant or revoke the admin role
	ClientAdminRenameUser, // ClientAdminRenameUserPayload: rename an account, lock its name
	ClientAdminKickUser, // ClientAdminKickUserPayload: end every session of an account
	ClientAdminBanUser, // ClientAdminBanUserPayload: ban or unban an account
	ServerAdminActionResult, // ServerAdminActionResultPayload: an admin action succeeded
	ServerUserUpdated, // ServerUserUpdatedPayload: an account's directory entry changed
	ServerAccountUpdated, // ServerAccountUpdatedPayload: this account's role or name changed
	ServerSessionEnded, // ServerSessionEndedPayload: the server is about to end this session

	// Room access modes (protocol 15), appended so no existing wire value moves. ClientLeaveRoom,
	// ClientAddRoomMember and ClientRemoveRoomMember above complete the set.
	ClientFetchRoomMembers, // ClientFetchRoomMembersPayload: a room's members (members, admins)
	ServerRoomMembers, // ServerRoomMembersPayload: answer to ClientFetchRoomMembers
	ClientAdminListRooms, // ClientAdminListRoomsPayload: admins: every room, joined or not
	ServerAdminRooms, // ServerAdminRoomsPayload: answer to ClientAdminListRooms
	// Account encryption keys (protocol 16, e2ee-design.md 3.1-3.2), appended so no existing
	// wire value moves.
	ClientPublishEncryptionKey, // ClientPublishEncryptionKeyPayload: this profile's bundle
	ClientFetchUserKeys, // ClientFetchUserKeysPayload: request accounts' bundles
	ServerUserKeys, // ServerUserKeysPayload: response to ClientFetchUserKeys
	ServerUserKeyChanged, // ServerUserKeyChangedPayload: an account published a new bundle
	// Encrypted direct messages (protocol 17, e2ee-design.md 4.5), appended so no existing wire
	// value moves. ClientDirectMessage and ServerDirectMessage carry the signed plaintext
	// fallback (4.6).
	ClientSealedDirectMessage, // ClientSealedDirectMessagePayload: an encrypted direct message
	ServerSealedDirectMessage, // ServerSealedDirectMessagePayload: a stored encrypted one
	// Encrypted rooms and their member log (protocol 18, e2ee-design.md 6.1-6.2), appended so no
	// existing wire value moves.
	ClientAppendRoomLog, // ClientAppendRoomLogPayload: a signed member log entry
	ClientFetchRoomLog, // ClientFetchRoomLogPayload: a room's member log after a version
	ServerRoomLog, // ServerRoomLogPayload: log entries, the answer and the live fan-out
	// Sender chains in encrypted rooms (protocol 19, e2ee-design.md 6.3-6.6), appended so no
	// existing wire value moves. Sealed room messages ride on ClientChatMessage and
	// ServerChatMessage (their sealed and clientMessageId fields).
	ClientRoomKeyEnvelope, // ClientRoomKeyEnvelopePayload: a SenderKey envelope for one chain
	ServerRoomKeyEnvelope, // ServerRoomKeyEnvelopePayload: a stored one, to its recipients
	ClientFetchRoomKeys, // ClientFetchRoomKeysPayload: the stored envelopes with a wrap for me
	ServerRoomKeys, // ServerRoomKeysPayload: answer to ClientFetchRoomKeys, one page
	ClientRequestRoomKey, // ClientRequestRoomKeyPayload: ask a chain's sender to re-seal it
	ServerRoomKeyRequest, // ServerRoomKeyRequestPayload: the request, relayed to the sender
	// End-to-end encrypted voice in encrypted rooms (protocol 21, e2ee-voice-design.md 3.2),
	// appended so no existing wire value moves. Voice frames stay binary on channel 2.
	ClientVoiceKey, // ClientVoiceKeyPayload: this participant's VoiceKey envelope
	ServerVoiceKey, // ServerVoiceKeyPayload: another participant's current VoiceKey envelope
	ClientRequestVoiceKey, // ClientRequestVoiceKeyPayload: ask a speaker for a new voice key
	ServerVoiceKeyRequest, // ServerVoiceKeyRequestPayload: the request, relayed to the speaker
}

// Room types on the wire since protocol 14 (RoomSummary.roomType, ClientCreateRoom,
// ClientEditRoom, and rooms.room_type in the database). Only Chat, Voice and ChatAndVoice are
// accepted (roomTypeIsSupported); Container and Forum are refused. The values are pinned in
// protocol_test.odin.
RoomType :: enum {
	Container, // A room that can contain other rooms but cannot have participants or messages itself, used for organizational purposes (e.g. "Games" category that contains "Chess", "Poker", etc.)
	Chat,
	Voice,
	ChatAndVoice,
	Forum,
}

// Whether a room may have this type today: Chat, Voice or ChatAndVoice.
roomTypeIsSupported :: proc(roomType: RoomType) -> bool {
	#partial switch roomType {
	case .Chat, .Voice, .ChatAndVoice:
		return true
	}
	return false
}

// Whether a room of this type takes chat messages (a voice-only room does not).
roomTypeAllowsChat :: proc(roomType: RoomType) -> bool {
	return roomType == .Chat || roomType == .ChatAndVoice
}

// Whether a room of this type has a voice session (a text-only room does not).
roomTypeAllowsVoice :: proc(roomType: RoomType) -> bool {
	return roomType == .Voice || roomType == .ChatAndVoice
}

// Who may join a room (protocol 15, rooms.access). Public rooms include every account: new
// accounts join them and a new Public room includes everyone. Member invite rooms take whoever a
// member or an admin adds; Admin invite rooms only whom an admin adds. In every mode only
// admins remove members, any member of a non-public room may leave it, and admins rename,
// edit and delete it. The values are the database's and the wire's; they are pinned in
// protocol_test.odin.
RoomAccess :: enum u8 {
	Public       = 1,
	MemberInvite = 2,
	AdminInvite  = 3,
}

roomAccessIsSupported :: proc(access: RoomAccess) -> bool {
	return access == .Public || access == .MemberInvite || access == .AdminInvite
}

// What a new member of a room reads (protocol 15, rooms.history_visibility), chosen when the
// room is created and fixed afterwards. From join: only messages sent after the member was
// added (room_members.joined_at; someone removed and added again counts from the second
// addition). Full: everything the room has. A Public room always reads as Full.
RoomHistoryVisibility :: enum u8 {
	FromJoin = 1,
	Full     = 2,
}

roomHistoryVisibilityIsSupported :: proc(visibility: RoomHistoryVisibility) -> bool {
	return visibility == .FromJoin || visibility == .Full
}

// The history a room's new members read: a Public room always has Full history.
roomEffectiveHistoryVisibility :: proc(
	access: RoomAccess,
	visibility: RoomHistoryVisibility,
) -> RoomHistoryVisibility {
	return access == .Public ? .Full : visibility
}

Rooms :: struct {
	rooms: [dynamic]int, // List of available rooms, included in the response from the server to the client when the client requests a list of rooms
}

Room :: struct {
	id:           int, // Unique ID of the room, client sends -1 if creating a new room, server includes the assigned ID in the response
	name:         string,
	children:     [dynamic]Room, // List of child rooms
	roomType:     RoomType,
	participants: [dynamic]int, // List of client IDs in the room, only used for Chat, Voice and ChatAndVoice room types
	permissions:  RoomPermissions, // Permissions for the room (e.g. who can join, who can post, etc.)
	forums:       [dynamic]ForumPost, // List of forum posts in the room (only used for Forum room type), only used for Forum room types
	is_temporary: bool, // Whether the room is temporary (i.e. should be deleted when the last participant leaves), only used for Chat, Voice and ChatAndVoice room types
}

RoomPermissions :: struct {
	groupsCanJoin:  [dynamic]int, // List of group IDs that can join the room, if empty then anyone can join
	groupsCanChat:  [dynamic]int, // List of group IDs that can chat in the room, if empty then anyone can chat
	groupsCanVoice: [dynamic]int, // List of group IDs that can use voice in the room, if empty then anyone can use voice
	groupsCanPost:  [dynamic]int, // List of group IDs that can post in the room, if empty then anyone can post
}

ForumPost :: struct {
	id:        int,
	authorId:  int,
	timestamp: datetime.DateTime, // Time the message was sent, only used by the server when sending to clients, when receiving from clients this can be set to the current time on the server
	content:   string,
	comments:  [dynamic]ForumComment,
}

ForumComment :: struct {
	id:        int,
	authorId:  int,
	timestamp: datetime.DateTime, // Time the message was sent, only used by the server when sending to clients, when receiving from clients this can be set to the current time on the server
	content:   string,
}

Message :: struct {
	id:        int,
	senderId:  int,
	roomId:    int,
	timestamp: datetime.DateTime, // Time the message was sent, only used by the server when sending to clients, when receiving from clients this can be set to the current time on the server
	content:   string,
}

// A room message. Every room message is signed by its sender (protocol 22, #90). In an
// unencrypted room it is content (1..CHAT_MESSAGE_MAX_BYTES bytes), a clientMessageId (16
// random bytes, never all zero) and signature, signPlaintextRoomMessage over this server's
// identity key, the room, the sender and clientMessageId, with no sealed bytes. The server
// refuses a plaintext message without a valid signature by the session's identity key
// (ROOM_MESSAGE_SIGNATURE_INVALID_MESSAGE) and a clientMessageId the sender used before
// (ROOM_MESSAGE_DUPLICATE_MESSAGE). In an encrypted room (protocol 19, e2ee-design.md 6.5)
// content is empty, signature is zero and sealed is a common/e2ee.odin SealedRoomMessage
// (at most SEALED_ROOM_MESSAGE_MAX_BYTES), carried as a CBOR byte string and stored byte for
// byte, whose AAD names this server, the room, the sender, its chain position and
// clientMessageId, and which carries its own signature. The server refuses a sealed message
// whose epoch is not the room's current log version (ROOM_KEY_OUT_OF_DATE_MESSAGE), whose
// signature does not verify against the sender's identity key, or whose clientMessageId or
// chain index the sender used before (ROOM_MESSAGE_DUPLICATE_MESSAGE); plaintext in an
// encrypted room and sealed bytes in an unencrypted one are refused too.
ClientChatMessagePayload :: struct {
	roomId:          int,
	content:         string,
	clientMessageId: ClientMessageID,
	sealed:          []u8,
	signature:       SignatureBytes, // Protocol 22: a plaintext message's; zero when sealed
}

ClientChatMessagePayload_deinit :: proc(payload: ^ClientChatMessagePayload) {
	delete(payload.content)
	delete(payload.sealed)
	payload.content = ""
	payload.sealed = nil
}

ServerChatMessagePayload :: struct {
	id:              int,
	senderId:        int,
	senderNickname:  string, // Sender's nickname when the message was stored or read
	roomId:          int,
	timestamp:       string,
	content:         string,
	// As in ClientChatMessagePayload (protocol 19, 22). Clients show a message only when its
	// signature verifies against the sender's pinned identity key.
	clientMessageId: ClientMessageID,
	sealed:          []u8,
	signature:       SignatureBytes,
}

ServerChatMessagePayload_deinit :: proc(payload: ^ServerChatMessagePayload) {
	delete(payload.senderNickname)
	delete(payload.timestamp)
	delete(payload.content)
	delete(payload.sealed)
	payload^ = {}
}

// lastReadMessageId and unreadCount (protocol 11) are the requester's read state, filled only
// in ServerListRooms. Every other payload that embeds a RoomSummary (ServerCreateRoom,
// ServerEditRoom, ServerRoomMutationPayload) carries zero values there; a client keeps the
// read state it already has for that room.
RoomSummary :: struct {
	id:                int,
	name:              string,
	description:       string,
	// The newest message ID the requester marked read, 0 when they never marked this room.
	lastReadMessageId: int,
	// Messages from other users after the marker (without a marker: created after the
	// requester joined the room), capped at UNREAD_COUNT_CAP.
	unreadCount:       int,
	// Text, voice, or both (protocol 14). Every payload that embeds a RoomSummary carries it.
	roomType:          RoomType,
	// Who may join (protocol 15), and the history new members read: Full for every Public
	// room, whatever was chosen at creation. Every payload that embeds a RoomSummary carries
	// them.
	access:            RoomAccess,
	historyVisibility: RoomHistoryVisibility,
	// Encrypted (protocol 18): fixed at creation; an encrypted room is never Public. logVersion
	// is the version of the newest entry the server stored in the room's member log (0 for an
	// unencrypted room, and for an encrypted one whose creator has not appended Create yet). It
	// tells a client whether its verified log is behind; it proves nothing (e2ee-design.md 6.2).
	encrypted:         bool,
	logVersion:        int,
}

ClientListRoomsPayload :: struct {}

ServerListRoomsPayload :: struct {
	rooms: [dynamic]RoomSummary,
}

ClientFetchRoomHistoryPayload :: struct {
	roomId:          int,
	beforeMessageID: int,
	limit:           int,
}

StoredChatMessage :: struct {
	id:              int,
	senderId:        int,
	senderNickname:  string, // Joined from users; empty if the sender has no row
	roomId:          int,
	timestamp:       string,
	content:         string,
	// As in ClientChatMessagePayload: a plaintext message has content, clientMessageId and
	// signature (protocol 22); a sealed one has clientMessageId, sealed and an empty content
	// (protocol 19).
	clientMessageId: ClientMessageID,
	sealed:          []u8,
	signature:       SignatureBytes,
}

StoredChatMessage_deinit :: proc(message: ^StoredChatMessage) {
	delete(message.senderNickname)
	delete(message.timestamp)
	delete(message.content)
	delete(message.sealed)
	message^ = {}
}

ServerRoomHistoryPayload :: struct {
	roomId:   int,
	messages: [dynamic]StoredChatMessage,
	hasOlder: bool,
}

// Room management is for accounts with the admin server role; anyone else gets
// ServerProtocolError "Admin permission required". ServerCreateRoom answers the creator with
// the new room, and every session of every member gets ServerRoomMembershipChanged{joined} (for
// a Public room every account, for an invite room the creator when they joined).
// ServerEditRoom and ServerDeleteRoom go to the room's members and to the admin who asked.
//
// roomType (protocol 14) must be Chat, Voice or ChatAndVoice; anything else is refused like
// bad metadata. A voice-only room refuses chat messages ("Chat is disabled in this room"), and
// a text-only room refuses voice joins ("voice is disabled in this room"); editing a room to
// text-only removes its voice participants with ServerVoiceLeft.
//
// Access modes (protocol 15): access is Public, MemberInvite or AdminInvite and
// historyVisibility FromJoin or Full (a Public room is always Full, whatever is sent). A Public
// room includes every account. An invite room includes only its creator, and only when
// creatorJoins is set: an admin who clears it creates a room they are not a member of, which
// they still manage (add, remove, edit, delete) from the Admin section. CBOR leaves a missing
// bool false, so clients always send creatorJoins (the create form starts with it on).
//
// Encrypted rooms (protocol 18, e2ee-design.md 6.1): encrypted needs Member invite or Admin
// invite (a Public one is refused with ENCRYPTED_ROOM_PUBLIC_MESSAGE). The server creates the
// room with no members at all and answers ServerCreateRoom (isMember false, logVersion 0): the
// room ID is part of every signed log entry, so the creator's client can sign the log's Create
// entry only now. It sends it with ClientAppendRoomLog; that entry names the managers and says
// whether the creator joins (creatorJoins here is ignored for an encrypted room), and the
// server adds the creator to room_members from it. Until then the room has no members and
// takes no messages; an admin can delete it.
ClientCreateRoomPayload :: struct {
	name:              string,
	description:       string,
	roomType:          RoomType,
	access:            RoomAccess,
	historyVisibility: RoomHistoryVisibility,
	creatorJoins:      bool,
	encrypted:         bool,
}

// access (protocol 15) changes the room's mode; the history setting cannot change. Switching a
// room to Public adds every account to it (each gets ServerRoomMembershipChanged); switching
// away from Public keeps every member.
//
// encrypted (protocol 18) must be the room's own flag, which never changes: an edit that would
// clear or set it is refused with ENCRYPTED_ROOM_FLAG_MESSAGE. An encrypted room's access
// changes only through a signed SetAccess log entry, so an edit with another access is refused
// with ENCRYPTED_ROOM_ACCESS_MESSAGE.
ClientEditRoomPayload :: struct {
	roomId:      int,
	name:        string,
	description: string,
	roomType:    RoomType,
	access:      RoomAccess,
	encrypted:   bool,
}

ClientDeleteRoomPayload :: struct {
	roomId: int,
}

// ClientAddRoomMember and ClientRemoveRoomMember (protocol 15 rules). An add is allowed to an
// admin in a Member invite or Admin invite room, and to a member in a Member invite room; adds
// to Public rooms are refused ("Public rooms include every account"). Only admins remove
// members, in every mode. The requester gets ServerRoomMemberAdded or ServerRoomMemberRemoved
// (ServerRoomMutationPayload with roomId, userId, and changed false when nothing moved: the
// account already was, or was not, a member). Refusals are ServerProtocolError: "Admin
// permission required", "Not a room member", "Room not found", "Unknown user".
ClientRoomMembershipPayload :: struct {
	roomId: int,
	userId: int,
}

// ClientLeaveRoom (protocol 15): the requester leaves a non-public room. Leaving a Public room
// is refused ("You cannot leave a public room"), and so is a room the requester is not in.
ClientLeaveRoomPayload :: struct {
	roomId: int,
}

// ServerRoomMembershipChanged: userId (protocol 15) joined or left roomId. Sent to every
// session of userId, and for adds, removals and leaves also to the sessions of the room's
// other members and of the requester, so an open member list can refresh. A client refreshes
// its room list when userId is its own account.
ServerRoomMembershipChangedPayload :: struct {
	roomId: int,
	joined: bool,
	userId: int,
}

// isMember (protocol 15) is set on ServerCreateRoom: whether the creator is a member of the new
// room (false for an invite room created without joining). Other payloads leave it false.
ServerRoomMutationPayload :: struct {
	room:     RoomSummary,
	roomId:   int,
	userId:   int,
	changed:  bool,
	isMember: bool,
}

// ClientFetchRoomMembers (protocol 15): the room's members, for its members and for admins
// (members or not). Anyone else is refused with "Not a room member".
ClientFetchRoomMembersPayload :: struct {
	roomId: int,
}

// ServerRoomMembers: every member's user ID, ascending. userIds is owned once decoded.
ServerRoomMembersPayload :: struct {
	roomId:  int,
	userIds: [dynamic]int,
}

ServerRoomMembersPayload_deinit :: proc(payload: ^ServerRoomMembersPayload) {
	delete(payload.userIds)
	payload.userIds = nil
}

// ClientAdminListRooms (protocol 15): admins only ("Admin permission required" otherwise).
ClientAdminListRoomsPayload :: struct {}

// One room as the Admin section lists it. room carries no read state.
AdminRoomSummary :: struct {
	room:        RoomSummary,
	isMember:    bool, // Whether the requesting admin is a member
	memberCount: int,
}

// ServerAdminRooms: every room on the server, by name, whether the admin is in it or not.
// Every string and the array are owned once decoded.
ServerAdminRoomsPayload :: struct {
	rooms: [dynamic]AdminRoomSummary,
}

ServerAdminRoomsPayload_deinit :: proc(payload: ^ServerAdminRoomsPayload) {
	for &entry in payload.rooms {
		delete(entry.room.name)
		delete(entry.room.description)
	}
	delete(payload.rooms)
	payload.rooms = nil
}

// Encrypted rooms and their member log (protocol 18, e2ee-design.md 6.1, 6.2). A log entry is
// common/e2ee.odin's RoomLogEntry binary layout, carried as a CBOR byte string and stored byte
// for byte, so its signed bytes never depend on a CBOR encoder.
//
// The server validates every appended entry with RoomLogState_validate against the head it
// stored (it has no pins: every identity key an entry names must be the named account's
// users.public_key), applies its own rules of design 5.1 on top (an Add needs the server's
// permission, an admin or a member of a Member invite room, as well as a valid signature; a
// SetAccess needs an admin), and stores it and applies it to room_members in one transaction.
// An entry whose version or prevHash does not follow the head is refused
// (ROOM_LOG_CONFLICT_MESSAGE), which serialises concurrent appends: the client fetches the log
// and tries again. An admin's ClientRemoveRoomMember on an encrypted room makes the server
// write an unsigned Remove itself. ClientAddRoomMember and ClientLeaveRoom are refused for
// encrypted rooms (ROOM_LOG_REQUIRED_MESSAGE); their members change only through the log.
//
// The server stores what clients sign but proves nothing by it: clients replay the log against
// their own pins and refuse a log that forks or rolls back what they verified before.

// ClientAppendRoomLog: one entry, signed by the requester (its actorUserId must be the
// session's account). Every accepted entry is fanned out as ServerRoomLog; refusals are
// ServerProtocolError with a sentence.
ClientAppendRoomLogPayload :: struct {
	roomId: int,
	entry:  []u8,
}

ClientAppendRoomLogPayload_deinit :: proc(payload: ^ClientAppendRoomLogPayload) {
	delete(payload.entry)
	payload.entry = nil
}

// ClientFetchRoomLog: the entries after afterVersion (0 for the whole log), at most
// ROOM_LOG_FETCH_MAX_ENTRIES of them. Allowed to the room's members, its managers (named by
// the log) and admins; anyone else gets "Not a room member", whether the room exists or not.
ClientFetchRoomLogPayload :: struct {
	roomId:       int,
	afterVersion: int,
}

// ServerRoomLog: entries afterVersion+1 .. afterVersion+len(entries), in order, and the
// server's head version. The answer to ClientFetchRoomLog (hasMore when more entries follow
// the last one sent), and the fan-out of each appended entry (afterVersion its version - 1) to
// every session of the room's members and managers after it, of the account it removed or
// that left, and to the session that sent it. entries and each entry are owned once decoded.
ServerRoomLogPayload :: struct {
	roomId:       int,
	afterVersion: int,
	entries:      [dynamic][]u8,
	headVersion:  int,
	hasMore:      bool,
}

ServerRoomLogPayload_deinit :: proc(payload: ^ServerRoomLogPayload) {
	for entry in payload.entries {
		delete(entry)
	}
	delete(payload.entries)
	payload.entries = nil
}

ROOM_LOG_FETCH_MAX_ENTRIES :: 128

ENCRYPTED_ROOM_PUBLIC_MESSAGE :: "Public rooms cannot be encrypted"
ENCRYPTED_ROOM_FLAG_MESSAGE :: "A room's encryption cannot change after it is created"
ENCRYPTED_ROOM_ACCESS_MESSAGE :: "An encrypted room's access changes through its member list"
ENCRYPTED_ROOM_FULL_MESSAGE :: "This encrypted room is full"
// A plaintext message to an encrypted room (protocol 19: only sealed messages are stored there).
ENCRYPTED_ROOM_CHAT_MESSAGE :: "This room is encrypted: messages must be sealed"
ROOM_LOG_REQUIRED_MESSAGE :: "This room is encrypted: its members change through its member list"
ROOM_LOG_INVALID_MESSAGE :: "Invalid member list entry"
ROOM_LOG_CONFLICT_MESSAGE :: "The member list changed on the server; try again"
ROOM_LOG_NOT_AUTHORIZED_MESSAGE :: "You may not make this change to the member list"
ROOM_LOG_NOT_ENCRYPTED_MESSAGE :: "This room is not encrypted"
ROOM_LOG_DAMAGED_MESSAGE :: "This room's member list is damaged on the server"

// Sender chains in encrypted rooms (protocol 19, e2ee-design.md 6.3-6.6). Each member that
// sends in an epoch (a member log version) seals its chain to every member of that epoch as
// its verified log shows them: one common/e2ee.odin SealedEnvelope of kind SenderKey with a
// wrap per member, signed by the sender, whose AAD (makeRoomKeyAAD) names this server, the
// room, the epoch, the sender and the chain. Envelopes are carried as CBOR byte strings and
// stored byte for byte, once per chain (and once more per answer to a key request).
//
// The server checks an envelope's structure, kind and signature against the sender's
// identity key, that the sender is a member, that every wrap names a current member, and that
// epoch is the room's current log version; an older epoch is accepted only for a chain it
// already stores (a re-seal answering ClientRequestRoomKey). It delivers each stored envelope
// to the sessions of the accounts its wraps name, and ClientFetchRoomKeys returns only the
// envelopes with a wrap for the requester, so nothing of another room or recipient leaks.
//
// Full history (protocol 20, e2ee-design.md 6.6): in an encrypted room whose history
// visibility is Full, a member may forward a chain someone else sent (a RoomKeyForward
// envelope: senderId names the chain's sender, one wrap for one current member, signed by the
// forwarding session under makeRoomKeyForwardAAD) for a chain the server already stores, in any
// epoch. A forward is refused in From join rooms (ROOM_KEY_FORWARD_NOT_ALLOWED_MESSAGE) and
// dropped without an answer when the recipient already has a wrap for that chain. Stored
// forwards carry forwarderId and are fetched and delivered like re-seals. In those rooms
// ClientRequestRoomKey goes to every online member, not only the chain's sender.

// ClientRoomKeyEnvelope: one SenderKey envelope for (roomId, epoch, the sender, chainId), the
// sender being the session's account. Protocol 20: with senderId set (another account), a
// RoomKeyForward envelope of senderId's chain that the session's account forwards. Refused with
// ROOM_KEY_ENVELOPE_INVALID_MESSAGE, ROOM_KEY_OUT_OF_DATE_MESSAGE,
// ROOM_KEY_FORWARD_NOT_ALLOWED_MESSAGE or "Not a room member".
ClientRoomKeyEnvelopePayload :: struct {
	roomId:   int,
	epoch:    int,
	chainId:  ChainID,
	envelope: []u8,
	senderId: int, // Protocol 20: the chain's sender for a RoomKeyForward; 0 for a SenderKey
}

ClientRoomKeyEnvelopePayload_deinit :: proc(payload: ^ClientRoomKeyEnvelopePayload) {
	delete(payload.envelope)
	payload.envelope = nil
}

// One stored envelope. id is the server's row ID, the fetch cursor. senderId is the chain's
// sender. forwarderId (protocol 20) is 0 for a SenderKey envelope, which senderId sealed, and
// the forwarding account for a RoomKeyForward envelope. envelope is owned once decoded.
RoomKeyEnvelope :: struct {
	id:          int,
	roomId:      int,
	epoch:       int,
	senderId:    int,
	chainId:     ChainID,
	envelope:    []u8,
	forwarderId: int,
}

RoomKeyEnvelope_deinit :: proc(envelope: ^RoomKeyEnvelope) {
	delete(envelope.envelope)
	envelope.envelope = nil
}

// ServerRoomKeyEnvelope: a stored envelope, sent live to every session of the accounts its
// wraps name (the sender's own included when it sealed a wrap for itself).
ServerRoomKeyEnvelopePayload :: struct {
	envelope: RoomKeyEnvelope,
}

ServerRoomKeyEnvelopePayload_deinit :: proc(payload: ^ServerRoomKeyEnvelopePayload) {
	RoomKeyEnvelope_deinit(&payload.envelope)
}

// ClientFetchRoomKeys: the room's stored envelopes with a wrap for the requester, with epoch
// at least sinceEpoch and ID above afterId (0 for the first page), oldest first, at most
// ROOM_KEYS_FETCH_MAX_ENVELOPES. For members only ("Not a room member" otherwise, whether the
// room exists or not).
ClientFetchRoomKeysPayload :: struct {
	roomId:     int,
	sinceEpoch: int,
	afterId:    int,
}

// ServerRoomKeys: one page; hasMore when more follow the last one (fetch again after its id).
ServerRoomKeysPayload :: struct {
	roomId:     int,
	sinceEpoch: int,
	afterId:    int,
	envelopes:  [dynamic]RoomKeyEnvelope,
	hasMore:    bool,
}

ServerRoomKeysPayload_deinit :: proc(payload: ^ServerRoomKeysPayload) {
	for &envelope in payload.envelopes {
		RoomKeyEnvelope_deinit(&envelope)
	}
	delete(payload.envelopes)
	payload.envelopes = nil
}

// ClientRequestRoomKey: the requester met a message of senderId's chain chainId in epoch and
// holds no key for it. The server checks that the requester is a member of the encrypted room
// and that it stores an envelope for that chain. In a From join room it relays the request to
// every session of senderId (who must be a member too) as ServerRoomKeyRequest; in a Full
// history room (protocol 20) to every session of every other member, so whoever holds the chain
// can forward it. Nothing is answered to the requester. Each client decides whether to answer
// from its verified log (room_chains.odin).
ClientRequestRoomKeyPayload :: struct {
	roomId:   int,
	epoch:    int,
	senderId: int,
	chainId:  ChainID,
}

ServerRoomKeyRequestPayload :: struct {
	roomId:      int,
	epoch:       int,
	chainId:     ChainID,
	requesterId: int,
	senderId:    int, // Protocol 20: the chain's sender (the recipient is not always it)
}

ROOM_KEYS_FETCH_MAX_ENVELOPES :: 32

// Refusals of sealed room messages and key envelopes (protocol 19), as ServerProtocolError.
ROOM_KEY_OUT_OF_DATE_MESSAGE :: "Room key is out of date"
SEALED_ROOM_MESSAGE_INVALID_MESSAGE :: "Invalid encrypted room message"
ROOM_MESSAGE_DUPLICATE_MESSAGE :: "Duplicate room message"
// Protocol 22 (#90): a plaintext room message without a valid signature.
ROOM_MESSAGE_SIGNATURE_INVALID_MESSAGE :: "Invalid room message signature"
// Protocol 20: a RoomKeyForward envelope in a room whose history is not Full.
ROOM_KEY_FORWARD_NOT_ALLOWED_MESSAGE :: "This room does not share its history with new members"
ROOM_KEY_ENVELOPE_INVALID_MESSAGE :: "Invalid room key envelope"
ROOM_KEY_REQUEST_INVALID_MESSAGE :: "Invalid room key request"
// A sealed message to a room that is not encrypted.
SEALED_ROOM_MESSAGE_NOT_ENCRYPTED_MESSAGE :: "This room is not encrypted"

// End-to-end encrypted voice (protocol 21, e2ee-voice-design.md 3-4). Each voice participant
// of an encrypted room makes a random voice key per generation, seals it in a VoiceKey envelope
// (common/e2ee.odin) with one wrap per other member of its verified log's current epoch, and
// sends it as ClientVoiceKey before any frame under it. The router (server/voice.odin) checks
// the envelope's structure, kind and signature against the session's identity key over the
// voice key AAD, that the session is in roomId's voice, and that epoch is the room's current
// log version; it keeps the latest one per participant in memory only (never in the database,
// never forwarded to anyone outside the room's voice), sends it to every other session in the
// room's voice as ServerVoiceKey, and hands each joiner every other participant's current key
// right after its ServerVoiceParticipants with recipientJoined. A refusal is a
// ServerProtocolError (VOICE_KEY_OUT_OF_DATE_MESSAGE for a stale epoch, so the client fetches
// the log and rekeys; VOICE_KEY_INVALID_MESSAGE otherwise); the session stays.
//
// voiceSessionId and envelope are CBOR byte strings; createdAt is the key's creation time
// (Unix seconds, the sender's clock), carried because the AAD binds it and the server checks
// the signature. A decoded payload owns envelope: free it with the *_deinit helper.

ClientVoiceKeyPayload :: struct {
	roomId:         int,
	epoch:          int,
	voiceSessionId: VoiceSessionID,
	generation:     u32,
	createdAt:      i64,
	envelope:       []u8,
}

ClientVoiceKeyPayload_deinit :: proc(payload: ^ClientVoiceKeyPayload) {
	delete(payload.envelope)
	payload.envelope = nil
}

// ServerVoiceKey: senderId's current voice key, to the other sessions in the room's voice.
ServerVoiceKeyPayload :: struct {
	roomId:         int,
	senderId:       int,
	epoch:          int,
	voiceSessionId: VoiceSessionID,
	generation:     u32,
	createdAt:      i64,
	envelope:       []u8,
}

ServerVoiceKeyPayload_deinit :: proc(payload: ^ServerVoiceKeyPayload) {
	delete(payload.envelope)
	payload.envelope = nil
}

// ClientRequestVoiceKey: a listener in roomId's voice holds no usable key of senderId's. The
// server passes it to senderId's voice session as ServerVoiceKeyRequest, at most once per
// requester and speaker every VOICE_KEY_REQUEST_INTERVAL_SECONDS, and drops anything else
// silently. The speaker answers by rotating (a new key for every member of its epoch).
ClientRequestVoiceKeyPayload :: struct {
	roomId:   int,
	senderId: int,
}

ServerVoiceKeyRequestPayload :: struct {
	roomId:      int,
	requesterId: int,
}

VOICE_KEY_OUT_OF_DATE_MESSAGE :: "Voice key is out of date"
VOICE_KEY_INVALID_MESSAGE :: "Invalid voice key"

// Direct messages are per server, between any two accounts. Since protocol 17 (e2ee-design.md
// 4.5, 4.6) a message is either end-to-end encrypted (an envelope of common/e2ee.odin's binary
// layout, carried as a CBOR byte string and stored byte for byte) or a signed plaintext
// fallback the server can read. Messages from before protocol 17 had no signature; migration 10
// deleted them, and clients never show a direct message without its sender's valid signature
// (#82). Every string, byte string and dynamic array below is an owned CBOR allocation once
// decoded; free it or transfer it, as with room chat. Fixed-size byte fields (client message
// IDs, signatures) decode through CBOR's temporary allocator.

// ClientDirectMessage: the signed plaintext fallback (design 4.6). signature is
// signPlaintextDirectMessage over the server's identity key, both user IDs, clientMessageId and
// content. The server rejects an empty or oversized message, a zero clientMessageId, a missing
// or wrong signature (DIRECT_MESSAGE_SIGNATURE_INVALID_MESSAGE), a clientMessageId the sender
// used before (DIRECT_MESSAGE_DUPLICATE_MESSAGE), a message to the sender's own account, and a
// recipient that does not exist, with ServerProtocolError.
ClientDirectMessagePayload :: struct {
	recipientUserId: int,
	content:         string, // 1..CHAT_MESSAGE_MAX_BYTES bytes of UTF-8
	clientMessageId: ClientMessageID, // 16 random bytes, never all zero
	signature:       SignatureBytes,
}

// ClientSealedDirectMessage (protocol 17): an encrypted direct message. envelope is a
// sealDirectMessage envelope (at most SEALED_ENVELOPE_MAX_BYTES) whose AAD names this server,
// the sender, the recipient, both identity keys and clientMessageId. The server checks it with
// verifyDirectMessageEnvelope against the identity keys it knows and refuses anything else with
// SEALED_DIRECT_MESSAGE_INVALID_MESSAGE; duplicates, self-addressed messages and unknown
// recipients are refused as for ClientDirectMessage.
ClientSealedDirectMessagePayload :: struct {
	recipientUserId: int,
	clientMessageId: ClientMessageID,
	envelope:        []u8,
}

// One persisted direct message. Nicknames are the accounts' current nicknames, joined from
// users when the message is stored or read. timestamp is PostgreSQL timestamptz text.
//
// Protocol 17: an encrypted message has its envelope and an empty content; a plaintext one has
// content, no envelope, and the sender's signature. clientMessageId is the sender's ID for the
// message. (Rows from before protocol 17, with neither, were deleted by migration 10.)
StoredDirectMessage :: struct {
	id:                int, // Stable, increasing, and the history pagination cursor
	senderId:          int,
	senderNickname:    string,
	recipientId:       int,
	recipientNickname: string,
	timestamp:         string,
	content:           string,
	clientMessageId:   ClientMessageID,
	envelope:          []u8,
	signature:         SignatureBytes,
}

// ServerDirectMessage: a stored plaintext message, sent to every authenticated session of
// both the sender and the recipient. The sender sees its own message only through this echo
// (or ServerSealedDirectMessage for an encrypted one), so a client should not append a sent
// message locally. The conversation's peer is recipientId when senderId is the viewer's own
// ID, otherwise senderId. clientMessageId and signature as in StoredDirectMessage.
ServerDirectMessagePayload :: struct {
	id:                int,
	senderId:          int,
	senderNickname:    string,
	recipientId:       int,
	recipientNickname: string,
	timestamp:         string,
	content:           string,
	clientMessageId:   ClientMessageID,
	signature:         SignatureBytes,
}

// ServerSealedDirectMessage (protocol 17): a stored encrypted message, fanned out like
// ServerDirectMessage. envelope is exactly what the sender sent.
ServerSealedDirectMessagePayload :: struct {
	id:                int,
	senderId:          int,
	senderNickname:    string,
	recipientId:       int,
	recipientNickname: string,
	timestamp:         string,
	clientMessageId:   ClientMessageID,
	envelope:          []u8,
}

// Refusals of a direct message (protocol 17), as ServerProtocolError messages.
DIRECT_MESSAGE_SIGNATURE_INVALID_MESSAGE :: "Invalid direct message signature"
SEALED_DIRECT_MESSAGE_INVALID_MESSAGE :: "Invalid encrypted direct message"
DIRECT_MESSAGE_DUPLICATE_MESSAGE :: "Duplicate direct message"

ServerDirectMessagePayload_deinit :: proc(payload: ^ServerDirectMessagePayload) {
	delete(payload.senderNickname)
	delete(payload.recipientNickname)
	delete(payload.timestamp)
	delete(payload.content)
	payload^ = {}
}

ServerSealedDirectMessagePayload_deinit :: proc(payload: ^ServerSealedDirectMessagePayload) {
	delete(payload.senderNickname)
	delete(payload.recipientNickname)
	delete(payload.timestamp)
	delete(payload.envelope)
	payload^ = {}
}

ClientSealedDirectMessagePayload_deinit :: proc(payload: ^ClientSealedDirectMessagePayload) {
	delete(payload.envelope)
	payload.envelope = nil
}

// Whether a client message ID is set. The all-zero ID means "none" (messages from before
// protocol 17), so a sender never uses it.
clientMessageIDIsSet :: proc(id: ClientMessageID) -> bool {
	return id != ClientMessageID{}
}

// ClientFetchDirectHistory. Paginated exactly like room history: beforeMessageID 0 asks for
// the newest page, and an older page is requested with the oldest loaded message ID. limit
// must be 1..HISTORY_PAGE_MAX_MESSAGES. peerUserId must be another existing account.
ClientFetchDirectHistoryPayload :: struct {
	peerUserId:      int,
	beforeMessageID: int,
	limit:           int,
}

// ServerDirectHistory: messages in both directions between the requester and peerUserId,
// oldest first. hasOlder is true when messages older than messages[0] exist.
ServerDirectHistoryPayload :: struct {
	peerUserId: int,
	messages:   [dynamic]StoredDirectMessage,
	hasOlder:   bool,
}

// ClientUserList: no fields.
ClientListUsersPayload :: struct {}

UserSummary :: struct {
	id:       int,
	nickname: string,
	isOnline: bool, // At least one authenticated session for this account is connected
	// Protocol 14: whether the account holds the admin role, and whether it is banned. Every
	// account sees them; banned accounts stay listed because history names them.
	isAdmin:  bool,
	isBanned: bool,
	// Protocol 16 (e2ee-design.md 3.2): the account's identity key (users.public_key; all zeros
	// for an account that has none, such as a seeded keyless account), and whether it has
	// published an encryption key bundle. A client compares identityPublicKey with its pin and
	// never trusts it on its own; bundles are fetched with ClientFetchUserKeys. ServerUserPresence
	// carries neither, so a directory entry added from presence has zeros until the next list.
	identityPublicKey: IdentityPublicKeyBytes,
	hasEncryptionKey:  bool,
}

// ServerUserList: every account on the server, the requester included, ordered by nickname.
ServerUserListPayload :: struct {
	users: [dynamic]UserSummary,
}

// ClientListDirectConversations: no fields.
ClientListDirectConversationsPayload :: struct {}

// The latest message of one conversation, from the requester's point of view.
DirectConversationSummary :: struct {
	peerUserId:    int,
	peerNickname:  string,
	lastMessageID: int,
	lastSenderId:  int, // Either the requester's ID or peerUserId
	lastTimestamp: string,
	lastContent:   string,
	// Protocol 17: the latest message's client message ID, envelope (owned; empty for a
	// plaintext message, whose lastContent is set) and signature, as in StoredDirectMessage,
	// so the client can open or verify the preview.
	lastClientMessageId: ClientMessageID,
	lastEnvelope:        []u8,
	lastSignature:       SignatureBytes,
	// Read state (protocol 11): the newest message ID the requester marked read in this
	// conversation (0 when never), and the peer's messages after it, capped at
	// UNREAD_COUNT_CAP. Without a marker every message from the peer is unread.
	lastReadMessageId: int,
	unreadCount:       int,
}

// ServerDirectConversations: the requester's conversations, most recent first, at most
// DIRECT_CONVERSATIONS_MAX of them.
ServerDirectConversationsPayload :: struct {
	conversations: [dynamic]DirectConversationSummary,
}

// ServerUserPresence: sent to every other authenticated session when an account's first
// session authenticates (isOnline true) and when its last authenticated session ends
// (isOnline false). Additional sessions of an already online account send nothing.
ServerUserPresencePayload :: struct {
	userId:   int,
	nickname: string,
	isOnline: bool,
}

// Voice control payloads (protocol 10, voice-rooms-design.md 3.4). Since protocol 13 an
// account has at most one voice session: a join from one of its sessions ends the voice
// session of any other (ServerVoiceLeft "joined voice on another device"), so a participant
// list names each user once.

// ClientJoinVoice: join roomId's voice session, leaving any other one this session is in.
// The server checks room membership and answers with ServerVoiceParticipants (which lists the
// joiner) or ServerVoiceJoinRejected.
//
// rejoin and deviceId (protocol 13): rejoin is false for a join the user asked for, which takes
// voice over from the account's other sessions, and true for the client's automatic re-join
// after a reconnect, which may replace only a session with the same deviceId (a stale one the
// server has not timed out yet) and is refused with "voice is active on another device"
// otherwise. deviceId is the profile's device ID, 32 lowercase hex characters
// (voice_device.odin); the server refuses a join without a valid one. deviceId is owned once
// decoded.
ClientJoinVoicePayload :: struct {
	roomId:   int,
	muted:    bool,
	deafened: bool,
	rejoin:   bool,
	deviceId: string,
}

// ClientLeaveVoice: leave the current voice session. It carries no fields; the server knows
// which room the session is in.
ClientLeaveVoicePayload :: struct {}

// ClientVoiceState: mute or deafen changed while joined.
ClientVoiceStatePayload :: struct {
	muted:    bool,
	deafened: bool,
}

// One voice session in a room. nickname is owned.
VoiceParticipant :: struct {
	userId:   int,
	nickname: string,
	muted:    bool,
	deafened: bool,
}

// ServerVoiceParticipants: the full participant set of roomId, never a delta. Sent to every
// live session of every room member whenever the set or any participant's state changes, and
// to a joiner as the join acknowledgement. participants and each nickname are owned.
ServerVoiceParticipantsPayload :: struct {
	roomId:          int,
	participants:    [dynamic]VoiceParticipant,
	// Whether the session receiving this message is itself in roomId's voice (protocol 12).
	// The server sets it per recipient session. Participants carry user IDs, not sessions, so
	// without it a client could not tell the acknowledgement of its own join from a list that
	// names the same account on another device, or one sent before the server processed the
	// join; it completes a join only on a list with this set.
	recipientJoined: bool,
}

// ServerVoiceJoinRejected: a ClientJoinVoice for roomId was refused. reason is owned and
// meant for people ("not a room member", "voice room is full", "voice is disabled").
ServerVoiceJoinRejectedPayload :: struct {
	roomId: int,
	reason: string,
}

// ServerVoiceLeft: the server removed this session from roomId's voice session: removed from
// the room, the room was deleted, the session joined another room, or another session of the
// account joined voice (protocol 13, "joined voice on another device"). reason is owned.
ServerVoiceLeftPayload :: struct {
	roomId: int,
	reason: string,
}

// Frees what a VoiceParticipant owns and clears it.
VoiceParticipant_deinit :: proc(participant: ^VoiceParticipant) {
	delete(participant.nickname)
	participant.nickname = ""
}

// Frees every participant and the array, and clears the payload.
ServerVoiceParticipantsPayload_deinit :: proc(payload: ^ServerVoiceParticipantsPayload) {
	for &participant in payload.participants {
		VoiceParticipant_deinit(&participant)
	}
	delete(payload.participants)
	payload.participants = nil
}

// Frees the device ID a decoded join owns. CBOR allocates even an empty string, so a decoded
// join is always deinitialized.
ClientJoinVoicePayload_deinit :: proc(payload: ^ClientJoinVoicePayload) {
	delete(payload.deviceId)
	payload.deviceId = ""
}

ServerVoiceJoinRejectedPayload_deinit :: proc(payload: ^ServerVoiceJoinRejectedPayload) {
	delete(payload.reason)
	payload.reason = ""
}

ServerVoiceLeftPayload_deinit :: proc(payload: ^ServerVoiceLeftPayload) {
	delete(payload.reason)
	payload.reason = ""
}

// Read state (protocol 11). The server keeps one read marker per user and room and per user
// and direct conversation, so unread counts survive a restart and follow the account to
// every device. Clients and servers must be rebuilt together: older peers do not know these
// members or the read-state fields of RoomSummary and DirectConversationSummary.
ReadMarkerKind :: enum u8 {
	Room   = 0, // conversationId is a room ID
	Direct = 1, // conversationId is the peer's user ID
}

// ClientMarkRead: the requester has read the conversation up to messageId (> 0). Markers
// only move forward, and the server clamps messageId to the newest message the conversation
// holds. A room needs membership and a direct conversation an existing peer that is not the
// requester; anything else is refused with ServerProtocolError ("Not a room member", "Unknown
// user") and the session stays up.
ClientMarkReadPayload :: struct {
	kind:           ReadMarkerKind,
	conversationId: int,
	messageId:      int,
}

// ServerReadMarker: the requester's marker moved. Sent to every authenticated session of that
// account, the one that asked included, so reading on one device clears the badge on the
// others. A mark-read that moves nothing sends nothing. unreadCount is counted after the
// move, like the list payloads count it.
ServerReadMarkerPayload :: struct {
	kind:              ReadMarkerKind,
	conversationId:    int,
	lastReadMessageId: int,
	unreadCount:       int,
}

// Admin actions on accounts (protocol 14). Every request needs the admin role, which the
// server checks in the database in the same statement as the change. Refusals are
// ServerProtocolError with a sentence for people, and the session stays up:
//
// - "Admin permission required": the requester is not an admin.
// - "Unknown user": no account has userId.
// - The requester as the target of a kick, a ban, or a role revoke (renaming yourself is
//   allowed), another admin as the target of a kick or a ban (revoke the role first), a
//   revoke that would leave the server without an admin, making a banned account an admin,
//   and a rename to a name another account holds.
//
// A success answers the requester with ServerAdminActionResult. A role change, a ban or unban,
// and a rename that changed something send ServerUserUpdated (the account's full UserSummary)
// to every authenticated session, and a role change or rename sends ServerAccountUpdated to
// every session of the target account.

// Which admin action a ServerAdminActionResult answers. An unban is a Ban with banned false.
AdminAction :: enum u8 {
	SetRole = 0,
	Rename  = 1,
	Kick    = 2,
	Ban     = 3,
}

// ClientAdminSetRole: grant (isAdmin true) or revoke the admin role.
ClientAdminSetRolePayload :: struct {
	userId:  int,
	isAdmin: bool,
}

// ClientAdminRenameUser: renames the account and sets its nickname lock. nickname is
// NICKNAME_MIN_BYTES..NICKNAME_MAX_BYTES bytes, or empty to keep the name and change only the
// lock. While locked, a sign-in keeps the account's name whatever the client asks for, so the
// next connection does not undo the rename; locked false gives the name back to the client.
// nickname is owned once decoded.
ClientAdminRenameUserPayload :: struct {
	userId:   int,
	nickname: string,
	locked:   bool,
}

// ClientAdminKickUser: ends every session of the account with ServerSessionEnded{Kicked}. It
// can sign in again at once; its client waits until the user asks. reason is at most
// ADMIN_REASON_MAX_BYTES and owned once decoded.
ClientAdminKickUserPayload :: struct {
	userId: int,
	reason: string,
}

// ClientAdminBanUser: banned true bans the account (users.banned_at, users.ban_reason), ends
// every session of it with ServerSessionEnded{Banned}, and refuses its sign-in with
// ServerAuthFailure "This account is banned from this server" (plus ": reason" when set).
// banned false lifts the ban. Sign-up is open, so a banned person can still connect with a new
// key as a new account. reason is owned once decoded.
ClientAdminBanUserPayload :: struct {
	userId: int,
	banned: bool,
	reason: string,
}

// ServerAdminActionResult: the requester's action succeeded. message is a sentence for people
// and owned once decoded.
ServerAdminActionResultPayload :: struct {
	action:  AdminAction,
	userId:  int,
	message: string,
}

// ServerUserUpdated: an account's directory entry changed (role, ban, or an admin rename), to
// every authenticated session. user.nickname is owned once decoded.
ServerUserUpdatedPayload :: struct {
	user: UserSummary,
}

// ServerAccountUpdated: the receiving session's own account changed role or name (#41), to
// every session of that account. nickname is owned once decoded.
ServerAccountUpdatedPayload :: struct {
	isAdmin:        bool,
	nickname:       string,
	nicknameLocked: bool,
}

// Why the server ended a session.
SessionEndedKind :: enum u8 {
	Kicked = 0,
	Banned = 1,
}

// ServerSessionEnded: sent right before the server disconnects the session. A client treats it
// as a failure that retrying cannot fix until the user asks to connect again. reason is the
// admin's reason (may be empty) and owned once decoded.
ServerSessionEndedPayload :: struct {
	kind:   SessionEndedKind,
	reason: string,
}

// Account encryption keys (protocol 16, e2ee-design.md 2.2, 3.1-3.4). The bundle's signed bytes
// are makeEncryptionKeyBundleSignedBytes in e2ee.odin; every key is a fixed-size CBOR byte
// string.

// ClientPublishEncryptionKey: this profile's encryption key bundle, sent once per session after
// ServerAuthSuccess. The server verifies the signature against the session's identity key and
// stores it in user_encryption_keys: an identical bundle is a no-op, a different valid one
// replaces it and every authenticated session gets ServerUserKeyChanged. A bundle that does not
// verify is refused with ServerProtocolError ENCRYPTION_KEY_INVALID_MESSAGE.
ClientPublishEncryptionKeyPayload :: struct {
	encryptionPublicKey: EncryptionPublicKeyBytes,
	createdAt:           u64, // Unix seconds
	signature:           SignatureBytes,
}

// ClientFetchUserKeys: 1..USER_KEYS_FETCH_MAX positive, distinct account IDs. userIds is owned
// once decoded (ClientFetchUserKeysPayload_deinit). Anything else is refused with
// ServerProtocolError USER_KEYS_INVALID_REQUEST_MESSAGE.
ClientFetchUserKeysPayload :: struct {
	userIds: [dynamic]int,
}

// One account's bundle. identityPublicKey is the account's identity key (users.public_key),
// which the signature must verify against; the client also compares it with its pin.
UserKeyBundle :: struct {
	userId:              int,
	identityPublicKey:   IdentityPublicKeyBytes,
	encryptionPublicKey: EncryptionPublicKeyBytes,
	createdAt:           u64,
	signature:           SignatureBytes,
}

// ServerUserKeys: the bundles of the requested accounts that have one, and missingUserIds, the
// requested accounts that have none (unknown accounts included), so the client can tell "not
// set up yet" and "the server is not providing it" (design 4.6) from an answer that is still
// on its way. Both arrays are owned once decoded (ServerUserKeysPayload_deinit).
ServerUserKeysPayload :: struct {
	keys:           [dynamic]UserKeyBundle,
	missingUserIds: [dynamic]int,
}

// ServerUserKeyChanged: an account stored a bundle it did not have before (a first publish or
// a replacement), to every authenticated session. No owned fields.
ServerUserKeyChangedPayload :: struct {
	bundle: UserKeyBundle,
}

ENCRYPTION_KEY_INVALID_MESSAGE :: "Invalid encryption key"
USER_KEYS_INVALID_REQUEST_MESSAGE :: "Invalid user key request"

ClientFetchUserKeysPayload_deinit :: proc(payload: ^ClientFetchUserKeysPayload) {
	delete(payload.userIds)
	payload.userIds = nil
}

ServerUserKeysPayload_deinit :: proc(payload: ^ServerUserKeysPayload) {
	delete(payload.keys)
	delete(payload.missingUserIds)
	payload.keys = nil
	payload.missingUserIds = nil
}

// The bundle as e2ee.odin's verifier takes it.
UserKeyBundle_toEncryptionKeyBundle :: proc(bundle: UserKeyBundle) -> EncryptionKeyBundle {
	return EncryptionKeyBundle {
		identityPublicKey = bundle.identityPublicKey,
		encryptionPublicKey = bundle.encryptionPublicKey,
		createdAt = bundle.createdAt,
		signature = bundle.signature,
	}
}

// Whether userIds is a valid ClientFetchUserKeys list: 1..USER_KEYS_FETCH_MAX positive,
// distinct IDs. Quadratic in at most 64 entries, so it allocates nothing.
userKeysFetchIsValid :: proc(userIds: []int) -> bool {
	if len(userIds) == 0 || len(userIds) > USER_KEYS_FETCH_MAX {
		return false
	}
	for userID, index in userIds {
		if userID <= 0 {
			return false
		}
		for earlier in userIds[:index] {
			if earlier == userID {
				return false
			}
		}
	}
	return true
}

ServerAuthSuccessPayload_deinit :: proc(payload: ^ServerAuthSuccessPayload) {
	delete(payload.message)
	delete(payload.nickname)
	payload.message = ""
	payload.nickname = ""
}

ClientAdminRenameUserPayload_deinit :: proc(payload: ^ClientAdminRenameUserPayload) {
	delete(payload.nickname)
	payload.nickname = ""
}

ClientAdminKickUserPayload_deinit :: proc(payload: ^ClientAdminKickUserPayload) {
	delete(payload.reason)
	payload.reason = ""
}

ClientAdminBanUserPayload_deinit :: proc(payload: ^ClientAdminBanUserPayload) {
	delete(payload.reason)
	payload.reason = ""
}

ServerAdminActionResultPayload_deinit :: proc(payload: ^ServerAdminActionResultPayload) {
	delete(payload.message)
	payload.message = ""
}

ServerUserUpdatedPayload_deinit :: proc(payload: ^ServerUserUpdatedPayload) {
	delete(payload.user.nickname)
	payload.user.nickname = ""
}

ServerAccountUpdatedPayload_deinit :: proc(payload: ^ServerAccountUpdatedPayload) {
	delete(payload.nickname)
	payload.nickname = ""
}

ServerSessionEndedPayload_deinit :: proc(payload: ^ServerSessionEndedPayload) {
	delete(payload.reason)
	payload.reason = ""
}

VideoData :: struct {
	senderId:  int,
	roomId:    int,
	timestamp: datetime.DateTime, // Time the video data was sent, only used by the server when sending to clients, when receiving from clients this can be set to the current time on the server
	data:      []u8, // Raw VP8-encoded video data
}

ClientStoreFileRequest :: struct {
	filename: string,
	content:  []u8,
}

ServerStoreFileResult :: struct {
	success:        bool,
	message:        string,
	hashedFilename: string,
}

// Database IPC between the server router and its database worker. Requests and results are
// tagged unions, so every switch over them must handle each variant; adding a query without
// routing or cleanup is a compile error rather than a silent leak or dropped reply.
DatabaseQueryRequest :: union {
	DatabaseUserIdentityRequest,
	DatabaseRoomListRequest,
	DatabaseRoomMemberListRequest,
	DatabasePostRoomChatMessageRequest,
	DatabaseRoomHistoryRequest,
	DatabaseUserServerAdminRequest,
	DatabaseCreateRoomRequest,
	DatabaseEditRoomRequest,
	DatabaseDeleteRoomRequest,
	DatabaseRoomMemberActionRequest,
	DatabasePostDirectMessageRequest,
	DatabaseDirectHistoryRequest,
	DatabaseDirectConversationListRequest,
	DatabaseUserDirectoryRequest,
	DatabaseMarkReadRequest,
	DatabaseAdminUserRequest,
	DatabaseAdminRoomListRequest,
	DatabasePublishEncryptionKeyRequest,
	DatabaseFetchUserKeysRequest,
	DatabaseAppendRoomLogRequest,
	DatabaseFetchRoomLogRequest,
	DatabaseStoreRoomKeyEnvelopeRequest,
	DatabaseFetchRoomKeysRequest,
	DatabaseRoomKeyRequestCheckRequest,
}

DatabaseUserIdentityRequest :: struct {
	nickname:          string,
	publicKey:         IdentityPublicKeyBytes,
	// Only this key may claim a keyless account that already holds server roles.
	adminPublicKey:    IdentityPublicKeyBytes,
	hasAdminPublicKey: bool,
}

DatabaseRoomListRequest :: struct {
	userId: int,
}

DatabaseRoomMemberListRequest :: struct {
	roomId: int,
}

// Checks membership, stores the message, and lists recipients in one statement, so the
// membership check and the insert cannot race.
//
// Protocol 19: a sealed message (owned sealed bytes, already checked by the router against the
// sender's identity key) carries its clientMessageId and the chain position the router decoded
// from it; the statement stores it only in an encrypted room whose log version is epoch, and
// the unique indexes refuse a reused clientMessageId or chain index.
DatabasePostRoomChatMessageRequest :: struct {
	roomId:          int,
	senderId:        int,
	content:         string,
	clientMessageId: ClientMessageID,
	sealed:          []u8,
	epoch:           int,
	chainId:         ChainID,
	chainIndex:      int,
	signature:       SignatureBytes, // Protocol 22: a plaintext message's, checked by the router
}

// Protocol 19: one SenderKey envelope (owned) the router checked, with the user IDs its wraps
// name (owned). Protocol 20: forwarderId is the session's account for a RoomKeyForward
// envelope of senderId's chain (one wrap), 0 for a SenderKey envelope sealed by senderId.
DatabaseStoreRoomKeyEnvelopeRequest :: struct {
	senderId:         int,
	roomId:           int,
	epoch:            int,
	chainId:          ChainID,
	envelope:         []u8,
	recipientUserIDs: [dynamic]int,
	forwarderId:      int,
}

// Protocol 19: a page of the envelopes with a wrap for userId.
DatabaseFetchRoomKeysRequest :: struct {
	userId:     int,
	roomId:     int,
	sinceEpoch: int,
	afterId:    int,
}

// Protocol 19: whether requesterId may ask for a stored chain of senderId (protocol 20: and who
// is asked).
DatabaseRoomKeyRequestCheckRequest :: struct {
	requesterId: int,
	roomId:      int,
	epoch:       int,
	senderId:    int,
	chainId:     ChainID,
}

// Returns a history page only when userId is a member of the room.
DatabaseRoomHistoryRequest :: struct {
	roomId:          int,
	userId:          int,
	beforeMessageID: int,
	limit:           int,
}

DatabaseUserServerAdminRequest :: struct {
	userId: int,
}

// Protocol 15: a Public room includes every account (and stores Full history); an invite room
// includes the creator only when creatorJoins is set.
DatabaseCreateRoomRequest :: struct {
	creatorUserId:     int,
	name:              string,
	description:       string,
	roomType:          RoomType,
	access:            RoomAccess,
	historyVisibility: RoomHistoryVisibility,
	creatorJoins:      bool,
	// Protocol 18: an encrypted room starts with no members; its log's Create adds the creator.
	encrypted:         bool,
}

// Switching access to Public adds every account in the same statement. encrypted (protocol
// 18) must match the room's flag, and an encrypted room's access cannot change here; the
// statement refuses both (DatabaseRoomMutationResult.refusal).
DatabaseEditRoomRequest :: struct {
	roomId:      int,
	name:        string,
	description: string,
	roomType:    RoomType,
	access:      RoomAccess,
	encrypted:   bool,
}

DatabaseDeleteRoomRequest :: struct {
	roomId: int,
}

// What a DatabaseRoomMemberActionRequest does (protocol 15). Fetch changes nothing.
RoomMemberAction :: enum u8 {
	Add,
	Remove,
	Leave,
	Fetch,
}

// One statement checks who actorUserId is (admin, member) against the room's access mode, and
// for Add and Remove that targetUserId exists, and makes the change; Leave and Fetch ignore
// targetUserId (Leave acts on the actor).
//
// Protocol 18: Add and Leave are refused for an encrypted room (EncryptedRoom); a Remove of a
// member of an encrypted room makes the worker write the log's unsigned Remove entry and apply
// it in one transaction, for which it replays the stored log against serverIdentityPublicKey.
DatabaseRoomMemberActionRequest :: struct {
	action:                  RoomMemberAction,
	actorUserId:             int,
	roomId:                  int,
	targetUserId:            int,
	serverIdentityPublicKey: IdentityPublicKeyBytes,
}

// Every admin's view of every room.
DatabaseAdminRoomListRequest :: struct {
	actorUserId: int,
}

// Checks that the recipient exists and is not the sender, stores the message, and reads both
// nicknames in one statement, so the check and the insert cannot race.
//
// Protocol 17: a plaintext message (content, owned) carries the signature the router already
// verified; an encrypted one has an empty content and its envelope (owned). For an envelope the
// database worker reads the recipient's identity key, checks the envelope with
// verifyDirectMessageEnvelope (serverIdentityPublicKey, both user IDs, senderIdentityPublicKey
// (the session's), that key and clientMessageId), and stores it only while the recipient still
// has that key, in the same statement as the insert. A clientMessageId the sender used before
// stores nothing (DirectMessagePostOutcome.Duplicate).
DatabasePostDirectMessageRequest :: struct {
	senderId:                int,
	recipientId:             int,
	content:                 string,
	clientMessageId:         ClientMessageID,
	signature:               SignatureBytes,
	envelope:                []u8,
	serverIdentityPublicKey: IdentityPublicKeyBytes,
	senderIdentityPublicKey: IdentityPublicKeyBytes,
}

// Returns a page of the conversation between userId and peerUserId, in both directions.
DatabaseDirectHistoryRequest :: struct {
	userId:          int,
	peerUserId:      int,
	beforeMessageID: int,
	limit:           int,
}

// Returns the latest message per peer for userId, newest first.
DatabaseDirectConversationListRequest :: struct {
	userId: int,
}

// Returns every account. Online flags come from the router, not the database.
DatabaseUserDirectoryRequest :: struct {}

// Checks membership (or the peer), clamps, and moves the marker forward in one statement.
DatabaseMarkReadRequest :: struct {
	userId:         int,
	kind:           ReadMarkerKind,
	conversationId: int,
	messageId:      int,
}

// One admin action on an account (protocol 14). The statement checks that actorUserId holds
// the admin role and applies the guards of the action in the same statement as the change, so
// a role change between a check and the action cannot slip through. isAdmin is for SetRole,
// nickname (owned; empty keeps the name) and locked for Rename, banned for Ban, and reason
// (owned) for Ban.
DatabaseAdminUserRequest :: struct {
	action:       AdminAction,
	actorUserId:  int,
	targetUserId: int,
	isAdmin:      bool,
	nickname:     string,
	locked:       bool,
	banned:       bool,
	reason:       string,
}

// Stores a bundle the router already verified against the session's identity key (protocol
// 15). An identical stored bundle is left alone.
DatabasePublishEncryptionKeyRequest :: struct {
	userId:              int,
	encryptionPublicKey: EncryptionPublicKeyBytes,
	createdAt:           u64,
	signature:           SignatureBytes,
}

// Reads the bundles of userIds (owned), at most USER_KEYS_FETCH_MAX of them.
DatabaseFetchUserKeysRequest :: struct {
	userIds: [dynamic]int,
}

// Protocol 18: one member log entry (owned) that actorUserId sent. The worker locks the room,
// replays its stored log against serverIdentityPublicKey, validates the entry as the next one
// (every identity key it names must be the named account's users.public_key), checks the
// server's own rules, and stores and applies it in one transaction.
DatabaseAppendRoomLogRequest :: struct {
	actorUserId:             int,
	roomId:                  int,
	entry:                   []u8,
	serverIdentityPublicKey: IdentityPublicKeyBytes,
}

// Protocol 18: the entries after afterVersion, for a member, a manager or an admin.
DatabaseFetchRoomLogRequest :: struct {
	actorUserId:  int,
	roomId:       int,
	afterVersion: int,
}

// message holds the error text when success is false. All strings and arrays are owned.
DatabaseQueryResponse :: struct {
	success: bool,
	message: string,
	result:  DatabaseQueryResult,
}

DatabaseQueryResult :: union {
	DatabaseUserIdentityResult,
	DatabaseRoomListResult,
	DatabaseRoomMemberListResult,
	DatabasePostRoomChatMessageResult,
	DatabaseRoomHistoryResult,
	DatabaseUserServerAdminResult,
	DatabaseRoomMutationResult,
	DatabasePostDirectMessageResult,
	DatabaseDirectHistoryResult,
	DatabaseDirectConversationListResult,
	DatabaseUserDirectoryResult,
	DatabaseMarkReadResult,
	DatabaseAdminUserResult,
	DatabaseRoomMemberActionResult,
	DatabaseAdminRoomListResult,
	DatabasePublishEncryptionKeyResult,
	DatabaseFetchUserKeysResult,
	DatabaseAppendRoomLogResult,
	DatabaseFetchRoomLogResult,
	DatabaseStoreRoomKeyEnvelopeResult,
	DatabaseFetchRoomKeysResult,
	DatabaseRoomKeyRequestCheckResult,
}

// userId is 0 when the identity could not be resolved, for example when the nickname is bound
// to a different key. renamed is true when the key's account took a new nickname on this
// login; previousNickname (owned, empty otherwise) is the nickname it had before.
// isAdmin is whether the resolved account holds the admin server role, read in the same
// statement so ServerAuthSuccess needs no second query.
//
// Protocol 14: nickname (owned) is the account's name after this login, which differs from the
// requested one when an admin locked it (nicknameLocked). banned is true for a banned account,
// with banReason (owned, may be empty); the router refuses its sign-in.
DatabaseUserIdentityResult :: struct {
	userId:           int,
	renamed:          bool,
	previousNickname: string,
	isAdmin:          bool,
	nickname:         string,
	nicknameLocked:   bool,
	banned:           bool,
	banReason:        string,
}

DatabaseRoomListResult :: struct {
	rooms: [dynamic]RoomSummary,
}

// roomFound is false when no room has the requested ID; roomType is the room's type
// (protocol 14), which the voice join check reads.
// encrypted (protocol 18) refuses voice joins until encrypted voice exists (E6).
DatabaseRoomMemberListResult :: struct {
	userIDs:    [dynamic]int,
	roomFound:  bool,
	roomType:   RoomType,
	encrypted:  bool,
	// Protocol 21: the room's member log version (0 for an unencrypted room), the epoch a voice
	// key must name (server/voice.odin).
	logVersion: int,
}

// When isMember is false, or chatDisabled is true (a voice-only room, protocol 14), nothing was
// stored and the other fields are empty.
// encryptedRoom (protocol 18): the room is encrypted, which takes no plaintext message.
// Protocol 19: notEncrypted refuses a sealed message to an unencrypted room, staleEpoch a sealed
// message whose epoch is not the room's log version, duplicate a reused clientMessageId or
// chain index.
DatabasePostRoomChatMessageResult :: struct {
	isMember:         bool,
	chatDisabled:     bool,
	encryptedRoom:    bool,
	notEncrypted:     bool,
	staleEpoch:       bool,
	duplicate:        bool,
	storedMessage:    StoredChatMessage,
	recipientUserIDs: [dynamic]int,
}

DatabaseRoomHistoryResult :: struct {
	isMember: bool,
	messages: [dynamic]StoredChatMessage,
	hasOlder: bool,
}

DatabaseUserServerAdminResult :: struct {
	isAdmin: bool,
}

// Protocol 15: isMember is the creator's membership of a created room; addedUserIDs (owned)
// lists the accounts an edit to Public added.
// Why an edit was refused (protocol 18); None for every other mutation.
RoomEditRefusal :: enum u8 {
	None,
	EncryptionFlag, // The edit would set or clear the room's encrypted flag
	EncryptedAccess, // The edit would change an encrypted room's access
}

// Protocol 15: isMember is the creator's membership of a created room; addedUserIDs (owned)
// lists the accounts an edit to Public added. Protocol 18: refusal says why an edit of an
// existing room changed nothing (changed false).
DatabaseRoomMutationResult :: struct {
	room:         RoomSummary,
	changed:      bool,
	isMember:     bool,
	addedUserIDs: [dynamic]int,
	refusal:      RoomEditRefusal,
}

// How a room member statement ended (protocol 15). Applied means the rules passed (changed says
// whether a row moved); every other value is a refusal and nothing changed.
DatabaseRoomMemberOutcome :: enum u8 {
	Applied,
	AdminRequired, // An Admin invite add or any removal by someone who is not an admin
	NotMember, // A non-admin who is not a member (or the room does not exist, to non-admins)
	UnknownRoom, // To admins: no room has the ID
	UnknownUser, // No account has the target ID
	PublicRoom, // An add to, or a leave of, a Public room
	EncryptedRoom, // Protocol 18: an add or leave of an encrypted room (use the member log)
	LogDamaged, // Protocol 18: an encrypted room's stored log does not replay
}

// memberUserIDs (owned) are the room's members after the action, ascending; access is the
// room's mode. Both are set only when outcome is Applied.
//
// Protocol 18: a removal from an encrypted room also returns the unsigned Remove entry the
// server wrote (logEntry, owned, empty when nothing changed), its version, and the managers the
// log names (managerUserIDs, owned), who get the entry too.
DatabaseRoomMemberActionResult :: struct {
	outcome:        DatabaseRoomMemberOutcome,
	changed:        bool,
	access:         RoomAccess,
	memberUserIDs:  [dynamic]int,
	logEntry:       []u8,
	logVersion:     int,
	managerUserIDs: [dynamic]int,
}

// isAdmin false means the requester is not an admin and rooms is empty. rooms is owned.
DatabaseAdminRoomListResult :: struct {
	isAdmin: bool,
	rooms:   [dynamic]AdminRoomSummary,
}

// How a direct message post ended. Only Stored stored anything.
DirectMessagePostOutcome :: enum u8 {
	Stored,
	UnknownRecipient, // No such account, or the sender itself
	InvalidEnvelope, // The envelope does not verify against the accounts' identity keys
	Duplicate, // The sender already stored a message with this clientMessageId
}

// storedMessage (owned) is set only when outcome is Stored.
DatabasePostDirectMessageResult :: struct {
	outcome:       DirectMessagePostOutcome,
	storedMessage: StoredDirectMessage,
}

// When peerExists is false the peer account does not exist and messages is empty.
DatabaseDirectHistoryResult :: struct {
	peerExists: bool,
	messages:   [dynamic]StoredDirectMessage,
	hasOlder:   bool,
}

DatabaseDirectConversationListResult :: struct {
	conversations: [dynamic]DirectConversationSummary,
}

// isOnline is always false here; the router fills it from its live sessions.
DatabaseUserDirectoryResult :: struct {
	users: [dynamic]UserSummary,
}

// allowed is false when the requester is not a member of the room, or the peer does not exist
// (or is the requester); nothing changed then. changed is false when the marker was already at
// or past the clamped message ID. lastReadMessageId and unreadCount are set only when changed.
DatabaseMarkReadResult :: struct {
	allowed:           bool,
	changed:           bool,
	lastReadMessageId: int,
	unreadCount:       int,
}

// How the admin statement ended. Applied means the guards passed (changed says whether a row
// moved); every other value is a refusal and nothing changed.
DatabaseAdminOutcome :: enum u8 {
	Applied,
	NotAdmin, // The requester does not hold the admin role
	UnknownUser, // No account has the target ID
	SelfTarget, // Kick, ban, or role revoke aimed at the requester
	AdminTarget, // Kick or ban aimed at an admin
	LastAdmin, // The revoke would leave the server without an admin
	NicknameTaken, // Another account holds the new nickname
	BannedTarget, // Granting the admin role to a banned account
}

// user (nickname owned) is the target's directory entry after the action, isOnline false (the
// router fills it in); previousNickname (owned) is its name before a rename. Both are set only
// when outcome is Applied.
DatabaseAdminUserResult :: struct {
	outcome:          DatabaseAdminOutcome,
	changed:          bool,
	user:             UserSummary,
	nicknameLocked:   bool,
	previousNickname: string,
}

// stored is true when the row changed (a first publish or a replacement) and false when the
// stored bundle was already identical; replaced says it was a replacement. bundle is the stored
// bundle with the account's identity key, set when stored is true.
DatabasePublishEncryptionKeyResult :: struct {
	stored:   bool,
	replaced: bool,
	bundle:   UserKeyBundle,
}

// keys holds every requested account with a bundle and missingUserIds the others, unknown
// accounts and accounts without an identity key included. Both arrays are owned.
DatabaseFetchUserKeysResult :: struct {
	keys:           [dynamic]UserKeyBundle,
	missingUserIds: [dynamic]int,
}

// How a member log append ended (protocol 18). Only Applied stored anything.
RoomLogAppendOutcome :: enum u8 {
	Applied,
	NotMember, // No such room, or the requester may not see it
	NotEncrypted, // The room has no member log
	Invalid, // The entry does not decode or the log's rules refuse it (logError says which)
	Conflict, // Its version or prevHash does not follow the stored head
	NotAuthorized, // The server's own rules refuse it, or its actor is not the requester
	RoomFull, // An Add past ENCRYPTED_ROOM_MEMBERS_MAX
	Damaged, // The stored log does not replay
}

// Set when outcome is Applied: the stored entry (owned), its version and action, its target,
// whether a room_members row changed, the room's members and managers after it (owned,
// ascending), and its access after it.
DatabaseAppendRoomLogResult :: struct {
	outcome:           RoomLogAppendOutcome,
	logError:          RoomLogError,
	entry:             []u8,
	version:           int,
	action:            RoomLogAction,
	targetUserId:      int,
	membershipChanged: bool,
	memberUserIDs:     [dynamic]int,
	managerUserIDs:    [dynamic]int,
	access:            RoomAccess,
}

// outcome is Applied, NotMember or NotEncrypted. entries (owned) are in version order.
DatabaseFetchRoomLogResult :: struct {
	outcome:     RoomLogAppendOutcome,
	entries:     [dynamic][]u8,
	headVersion: int,
	hasMore:     bool,
}

// How a key envelope store ended (protocol 19). Only Stored stored anything.
RoomKeyEnvelopeOutcome :: enum u8 {
	Stored,
	NotMember, // No such room, or the sender is not a member
	NotEncrypted,
	StaleEpoch, // epoch is not the log version, and no envelope of the chain is stored
	WrongRecipients, // A wrap names an account that is not a member
	// Protocol 20, forwards only.
	NotFullHistory, // A RoomKeyForward in a room whose history is not Full
	AlreadyHeld, // The recipient already has a wrap for the chain; dropped without an answer
}

// stored (owned) and recipientUserIDs (owned) are set when outcome is Stored.
DatabaseStoreRoomKeyEnvelopeResult :: struct {
	outcome:          RoomKeyEnvelopeOutcome,
	stored:           RoomKeyEnvelope,
	recipientUserIDs: [dynamic]int,
}

// envelopes (owned) are in ID order when isMember. sinceEpoch and afterId echo the request.
DatabaseFetchRoomKeysResult :: struct {
	sinceEpoch: int,
	afterId:    int,
	isMember:  bool,
	envelopes: [dynamic]RoomKeyEnvelope,
	hasMore:   bool,
}

// allowed: the room is encrypted, the requester is a member, an envelope of the chain is
// stored, and (From join) the sender is a member. fullHistory (protocol 20): the room's history
// is Full, and memberUserIDs (owned) are the members to ask, the requester excluded; otherwise
// only the sender is asked. The request's fields come back so the router needs no pending
// state.
DatabaseRoomKeyRequestCheckResult :: struct {
	allowed:       bool,
	request:       DatabaseRoomKeyRequestCheckRequest,
	fullHistory:   bool,
	memberUserIDs: [dynamic]int,
}

ProtocolErrorResponse :: struct {
	message: string,
}
