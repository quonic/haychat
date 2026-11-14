package common

import "core:time/datetime"

// The common protocol that both the server and client will use to communicate.
// This includes things like message formats, enums, and transport handshake data.
// It must remain shared between the client and server.

ProtocolVersion :: u32
protocolVersion: ProtocolVersion = 14
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

ClientChatMessagePayload :: struct {
	roomId:  int,
	content: string,
}

ServerChatMessagePayload :: struct {
	id:             int,
	senderId:       int,
	senderNickname: string, // Sender's nickname when the message was stored or read
	roomId:         int,
	timestamp:      string,
	content:        string,
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
	id:             int,
	senderId:       int,
	senderNickname: string, // Joined from users; empty if the sender has no row
	roomId:         int,
	timestamp:      string,
	content:        string,
}

ServerRoomHistoryPayload :: struct {
	roomId:   int,
	messages: [dynamic]StoredChatMessage,
	hasOlder: bool,
}

// Room management is for accounts with the admin server role; anyone else gets
// ServerProtocolError "Admin permission required". ServerCreateRoom answers the creator with
// the new room, and every authenticated session gets ServerRoomMembershipChanged{joined} (rooms
// are open, so every account is a member). ServerEditRoom and ServerDeleteRoom go to the
// room's members and to the admin who asked.
//
// roomType (protocol 14) must be Chat, Voice or ChatAndVoice; anything else is refused like
// bad metadata. A voice-only room refuses chat messages ("Chat is disabled in this room"), and
// a text-only room refuses voice joins ("voice is disabled in this room"); editing a room to
// text-only removes its voice participants with ServerVoiceLeft.
ClientCreateRoomPayload :: struct {
	name:        string,
	description: string,
	roomType:    RoomType,
}

ClientEditRoomPayload :: struct {
	roomId:      int,
	name:        string,
	description: string,
	roomType:    RoomType,
}

ClientDeleteRoomPayload :: struct {
	roomId: int,
}

ClientRoomMembershipPayload :: struct {
	roomId: int,
	userId: int,
}

ServerRoomMembershipChangedPayload :: struct {
	roomId: int,
	joined: bool,
}

ServerRoomMutationPayload :: struct {
	room:    RoomSummary,
	roomId:  int,
	userId:  int,
	changed: bool,
}

// Direct messages are per server, between any two accounts, and stored server side in plain
// text (they are not end-to-end encrypted). Every string and dynamic array below is an owned
// CBOR allocation once decoded; free it or transfer it, as with room chat.

// ClientDirectMessage. The server rejects an empty or oversized message, a message to the
// sender's own account, and a recipient that does not exist, with ServerProtocolError.
ClientDirectMessagePayload :: struct {
	recipientUserId: int,
	content:         string, // 1..CHAT_MESSAGE_MAX_BYTES bytes of UTF-8
}

// One persisted direct message. Nicknames are the accounts' current nicknames, joined from
// users when the message is stored or read. timestamp is PostgreSQL timestamptz text.
StoredDirectMessage :: struct {
	id:                int, // Stable, increasing, and the history pagination cursor
	senderId:          int,
	senderNickname:    string,
	recipientId:       int,
	recipientNickname: string,
	timestamp:         string,
	content:           string,
}

// ServerDirectMessage: sent once the message is stored, to every authenticated session of
// both the sender and the recipient. The sender sees its own message only through this echo,
// so a client should not append a sent message locally. The conversation's peer is
// recipientId when senderId is the viewer's own ID, otherwise senderId.
ServerDirectMessagePayload :: struct {
	id:                int,
	senderId:          int,
	senderNickname:    string,
	recipientId:       int,
	recipientNickname: string,
	timestamp:         string,
	content:           string,
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
	DatabaseAddRoomMemberRequest,
	DatabaseRemoveRoomMemberRequest,
	DatabasePostDirectMessageRequest,
	DatabaseDirectHistoryRequest,
	DatabaseDirectConversationListRequest,
	DatabaseUserDirectoryRequest,
	DatabaseMarkReadRequest,
	DatabaseAdminUserRequest,
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
DatabasePostRoomChatMessageRequest :: struct {
	roomId:   int,
	senderId: int,
	content:  string,
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

DatabaseCreateRoomRequest :: struct {
	creatorUserId: int,
	name:          string,
	description:   string,
	roomType:      RoomType,
}

DatabaseEditRoomRequest :: struct {
	roomId:      int,
	name:        string,
	description: string,
	roomType:    RoomType,
}

DatabaseDeleteRoomRequest :: struct {
	roomId: int,
}

DatabaseRoomMemberMutationRequest :: struct {
	roomId: int,
	userId: int,
}

DatabaseAddRoomMemberRequest :: distinct DatabaseRoomMemberMutationRequest
DatabaseRemoveRoomMemberRequest :: distinct DatabaseRoomMemberMutationRequest

// Checks that the recipient exists and is not the sender, stores the message, and reads both
// nicknames in one statement, so the check and the insert cannot race.
DatabasePostDirectMessageRequest :: struct {
	senderId:    int,
	recipientId: int,
	content:     string,
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
DatabaseRoomMemberListResult :: struct {
	userIDs:   [dynamic]int,
	roomFound: bool,
	roomType:  RoomType,
}

// When isMember is false, or chatDisabled is true (a voice-only room, protocol 14), nothing was
// stored and the other fields are empty.
DatabasePostRoomChatMessageResult :: struct {
	isMember:         bool,
	chatDisabled:     bool,
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

DatabaseRoomMutationResult :: struct {
	room:    RoomSummary,
	changed: bool,
}

// When recipientExists is false nothing was stored and storedMessage is empty. It is false
// for an unknown recipient and for a message addressed to the sender.
DatabasePostDirectMessageResult :: struct {
	recipientExists: bool,
	storedMessage:   StoredDirectMessage,
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

ProtocolErrorResponse :: struct {
	message: string,
}
