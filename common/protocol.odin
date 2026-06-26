package common

import "core:time/datetime"

// The common protocol that both the server and client will use to communicate.
// This includes things like message formats, enums, and transport handshake data.
// It must remain shared between the client and server.

ProtocolVersion :: u32
protocolVersion: ProtocolVersion = 2

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
	clientIdentityPublicKey:  IdentityPublicKeyBytes,
	clientEphemeralPublicKey: KeyExchangePublicKeyBytes,
}

ServerHelloProof :: struct {
	version:                  ProtocolVersion,
	sessionID:                SessionID,
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

ServerAuthSuccessPayload :: struct {
	userId:  int,
	message: string,
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
	ClientChangeRoomPermissions, // Request to change a room's permissions (e.g. who can join, who can post, etc.), includes room name and new permissions
	ServerRoomPermissions, // Response to ClientChangeRoomPermissions, includes room name and new permissions
	ServerRoomPermissionsChange, // Notification of a room's permissions changing, includes room name and new permissions
	ClientCreateRoom, // Request to create a room (only allowed for certain admin users), includes room name and type
	ServerCreateRoom, // Notification of a room being created, includes room name and type
	ClientDeleteRoom, // Request to delete a room (only allowed for certain admin users), includes room name
	ServerDeleteRoom, // Notification of a room being deleted, includes room name
	ClientEditRoom, // Request to edit a room's details (only allowed for certain admin users), includes room name and new details (e.g. new name, new type, etc.)
	ServerEditRoom, // Notification of a room's details being edited, includes room name and new details (e.g. new name, new type, etc.)

	// Messaging
	ClientChatMessage, // Chat message sent from client to server
	ServerChatMessage, // Chat message broadcasted from server to clients
	ClientVoiceData, // Voice data sent from client to server
	ServerVoiceData, // Voice data broadcasted from server to clients
	ClientVideoData, // Video data sent from client to server
	ServerVideoData, // Video data broadcasted from server to clients
	ClientDirectMessage, // Direct message sent from client to server, includes recipient user ID and message content
	ServerDirectMessage, // Direct message sent from server to client, includes sender user ID and message content
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
	ClientUserList, // Request list of currently connected users (e.g. for displaying in the client UI)
	ServerUserList, // Response to ClientUserList, includes list of currently connected users (e.g. for displaying in the client UI)
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
	ClientAuthLookup, // Request auth lookup by nickname for threaded server routing
	ServerAuthLookupResponse, // Response to ClientAuthLookup, includes success/failure and optional DB result
	ClientStoreFile, // Request to store file content on server
	ServerStoreFileResponse, // Response to ClientStoreFile, includes success/failure and stored hash name
	ClientDatabaseQuery, // Request to execute a database query through main router
	ServerDatabaseQueryResponse, // Response to ClientDatabaseQuery, includes success/failure and result text
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
}

RoomType :: enum {
	Container, // A room that can contain other rooms but cannot have participants or messages itself, used for organizational purposes (e.g. "Games" category that contains "Chess", "Poker", etc.)
	Chat,
	Voice,
	ChatAndVoice,
	Forum,
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

VoiceData :: struct {
	senderId:  int,
	roomId:    int,
	timestamp: datetime.DateTime, // Time the voice data was sent, only used by the server when sending to clients, when receiving from clients this can be set to the current time on the server
	data:      []u8, // Raw Opus-encoded voice data
}

VideoData :: struct {
	senderId:  int,
	roomId:    int,
	timestamp: datetime.DateTime, // Time the video data was sent, only used by the server when sending to clients, when receiving from clients this can be set to the current time on the server
	data:      []u8, // Raw VP8-encoded video data
}

ClientAuthLookupRequest :: struct {
	nickname: string,
}

ServerAuthLookupResult :: struct {
	success: bool,
	message: string,
	result:  string,
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

ClientDatabaseQueryRequest :: struct {
	query: string,
}

ServerDatabaseQueryResult :: struct {
	success: bool,
	message: string,
	result:  string,
}

DatabaseQueryType :: enum u8 {
	None = 0,
	AuthLookupByNickname,
	RawSQL,
}

DatabaseAuthLookupRequest :: struct {
	nickname: string,
}

DatabaseRawQueryRequest :: struct {
	query: string,
}

DatabaseQueryRequest :: struct {
	queryType:  DatabaseQueryType,
	authLookup: DatabaseAuthLookupRequest,
	rawSQL:     DatabaseRawQueryRequest,
}

DatabaseQueryResponse :: struct {
	queryType: DatabaseQueryType,
	success:   bool,
	message:   string,
	result:    string,
}

ProtocolErrorResponse :: struct {
	message: string,
}
