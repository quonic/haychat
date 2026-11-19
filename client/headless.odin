package client

// Headless harness: `client --headless` runs the client without SDL so an agent or a shell
// script can act as a user. It reuses State, the actions, the transport and the network
// worker; only the presentation differs. Commands arrive one per line on stdin, and every
// command result and runtime event leaves as one JSON object per line on stdout. Diagnostics
// go to stderr. See docs/testing-harness.md for the protocol.

import "../common"
import "core:bufio"
import "core:encoding/json"
import "core:fmt"
import "core:io"
import "core:os"
import "core:reflect"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

HEADLESS_FLAG :: "--headless"
HEADLESS_EXIT_OK :: 0
HEADLESS_EXIT_ERROR :: 1
HEADLESS_EXIT_CONNECT_FAILED :: 2
HEADLESS_DEFAULT_WAIT_MS :: 5000
// How long startup waits for the first connection before giving up with exit code 2.
HEADLESS_DEFAULT_CONNECT_TIMEOUT_MS :: 15000
// Upper bound for `wait` and `sleep`, so a typo cannot park a scripted client for days.
HEADLESS_MAX_WAIT_MS :: 10 * 60 * 1000
HEADLESS_POLL_INTERVAL :: 5 * time.Millisecond
HEADLESS_MAX_ARGS :: 4
HEADLESS_DISPLAY_NAME_MIN :: 3
HEADLESS_DISPLAY_NAME_MAX :: 32
HEADLESS_USAGE ::
	"usage: client --headless [--name NAME] [--server HOST:PORT] [--config-dir DIR]\n" +
	"                         [--connect-timeout MS] [--register]\n" +
	"                         [--invite-code CODE [--reason TEXT]]\n" +
	"  --name NAME            display name (3-32 bytes); saved to the profile\n" +
	"  --server HOST:PORT     the profile's only server; saved to the profile\n" +
	"  --config-dir DIR       config root for this profile (like XDG_CONFIG_HOME)\n" +
	"  --connect-timeout MS   how long to wait for the first connection (default 15000)\n" +
	"  --register             sign up with an invite code even on an Open server\n" +
	"  --invite-code CODE     sends CODE (- for none) when the server asks to sign up;\n" +
	"                         implies --register; --reason TEXT goes with it\n" +
	"Commands are read from stdin; type `help` for the list."

// ── Options ───────────────────────────────────────────────────────

HeadlessOptions :: struct {
	// All strings are borrowed from the argument list.
	name:       string,
	serverHost: string,
	serverPort: i32,
	hasServer:        bool,
	configDir:        string,
	connectTimeoutMS: int,
	// Protocol 25 (headless_registration.odin): connect with registering set, and the code
	// (and reason) to send when the server asks to sign up.
	register:         bool,
	inviteCode:       string,
	reason:           string,
}

headlessRequested :: proc(args: []string) -> bool {
	for arg in args {
		if arg == HEADLESS_FLAG {
			return true
		}
	}
	return false
}

// Splits HOST:PORT at the last colon. Brackets around an IPv6 host are removed. The host is
// borrowed from value.
headlessParseServerAddress :: proc(value: string) -> (host: string, port: i32, ok: bool) {
	separator := strings.last_index_byte(value, ':')
	if separator <= 0 || separator == len(value) - 1 {
		return "", 0, false
	}
	host = value[:separator]
	if len(host) >= 2 && host[0] == '[' && host[len(host) - 1] == ']' {
		host = host[1:len(host) - 1]
	}
	parsedPort, portOK := strconv.parse_int(value[separator + 1:], 10)
	if !portOK || parsedPort < 1 || parsedPort > 65535 || len(host) == 0 {
		return "", 0, false
	}
	return host, i32(parsedPort), true
}

// Parses the arguments after the program name. Returns a static error message on failure.
headlessParseOptions :: proc(args: []string) -> (options: HeadlessOptions, err: string) {
	options.connectTimeoutMS = HEADLESS_DEFAULT_CONNECT_TIMEOUT_MS
	for index := 0; index < len(args); index += 1 {
		arg := args[index]
		if arg == HEADLESS_FLAG {
			continue
		}
		if arg == "--register" {
			options.register = true
			continue
		}
		flag := arg
		value := ""
		hasValue := false
		if equals := strings.index_byte(arg, '='); equals > 0 && strings.has_prefix(arg, "--") {
			flag = arg[:equals]
			value = arg[equals + 1:]
			hasValue = true
		}
		switch flag {
		case "--name", "--server", "--config-dir", "--connect-timeout", "--invite-code", "--reason":
		case:
			return {}, "unknown argument"
		}
		if !hasValue {
			if index + 1 >= len(args) {
				return {}, "missing value for an option"
			}
			index += 1
			value = args[index]
		}
		switch flag {
		case "--name":
			if len(value) < HEADLESS_DISPLAY_NAME_MIN || len(value) > HEADLESS_DISPLAY_NAME_MAX {
				return {}, "--name must be between 3 and 32 bytes"
			}
			options.name = value
		case "--server":
			host, port, ok := headlessParseServerAddress(value)
			if !ok {
				return {}, "--server must be HOST:PORT with a port from 1 to 65535"
			}
			options.serverHost = host
			options.serverPort = port
			options.hasServer = true
		case "--config-dir":
			if len(value) == 0 {
				return {}, "--config-dir must not be empty"
			}
			options.configDir = value
		case "--connect-timeout":
			timeoutMS, ok := headlessParseNumber(value, HEADLESS_MAX_WAIT_MS)
			if !ok || timeoutMS == 0 {
				return {}, "--connect-timeout must be from 1 to 600000 milliseconds"
			}
			options.connectTimeoutMS = timeoutMS
		case "--invite-code":
			if len(value) == 0 || len(value) > common.INVITE_CODE_TEXT_MAX_BYTES {
				return {}, "--invite-code must be a code (or - for none) of at most 64 bytes"
			}
			options.inviteCode = value
			options.register = true
		case "--reason":
			options.reason = value
		}
	}
	if len(options.reason) > 0 && len(options.inviteCode) == 0 {
		return {}, "--reason needs --invite-code"
	}
	return options, ""
}

// Applies --name and --server to config. A headless profile has exactly one server: the entry
// matching --server is kept with its pinned key, anything else is replaced by a fresh entry
// without a pin. Without --server the profile's saved servers are used as they are; there is
// no built-in default, so a profile with neither fails to connect with a clear message.
// Returns true when config changed and should be saved.
headlessApplyOptions :: proc(config: ^Config, options: HeadlessOptions) -> bool {
	changed := false
	if len(options.name) > 0 && options.name != config.display_name {
		delete(config.display_name)
		config.display_name = strings.clone(options.name)
		changed = true
	}

	if !options.hasServer {
		return changed
	}
	host := options.serverHost
	port := options.serverPort

	keepIndex := -1
	for server, index in config.servers {
		if server.host == host && server.port == port {
			keepIndex = index
			break
		}
	}
	if keepIndex == 0 && len(config.servers) == 1 {
		return changed
	}

	kept: Server
	if keepIndex >= 0 {
		kept = config.servers[keepIndex]
		config.servers[keepIndex] = {}
	} else {
		serverID := 1
		if len(config.servers) > 0 {
			serverID = config.servers[0].id
		}
		name := fmt.aprintf("%s:%d", host, port)
		kept = Server {
			id         = serverID,
			name       = name,
			short_name = getShortServerName(name),
			host       = strings.clone(host),
			port       = port,
		}
	}
	for index in 0 ..< len(config.servers) {
		Server_deinit(&config.servers[index])
	}
	clear(&config.servers)
	append(&config.servers, kept)
	return true
}

// Points loadConfig and saveConfig at dir by setting the variable they read the config root
// from. On Linux that is XDG_CONFIG_HOME, so the profile lives in DIR/haychat/config.json.
headlessUseConfigDir :: proc(dir: string) -> bool {
	if err := os.make_directory_all(dir); err != nil && !os.exists(dir) {
		fmt.eprintln("[Error] Failed to create config directory:", dir, err)
		return false
	}
	when ODIN_OS == .Windows {
		key :: "APPDATA"
	} else {
		key :: "XDG_CONFIG_HOME"
	}
	if err := os.set_env(key, dir); err != nil {
		fmt.eprintln("[Error] Failed to set", key, err)
		return false
	}
	return true
}

// ── Event rendering ───────────────────────────────────────────────

// Kinds an agent can `wait` for. The connection lifecycle kinds come from the network worker's
// connect state machine, so they keep arriving after startup (for example a reconnect after the
// server restarts).
HeadlessEventKind :: enum {
	Connecting,
	Connected,
	ConnectFailed,
	RoomChat,
	RoomList,
	RoomHistory,
	RoomMembership,
	RoomEdited,
	RoomDeleted,
	ProtocolError,
	Disconnected,
	DirectMessage,
	DirectHistory,
	UserList,
	Conversations,
	Presence,
	RoomCreated,
	ReadMarker,
	VoiceParticipants,
	VoiceJoinRejected,
	VoiceLeft,
	// Admin actions (protocol 14).
	UserUpdated,
	AccountUpdated,
	AdminResult,
	SessionEnded,
	// Room access modes (protocol 15).
	RoomMembers,
	AdminRooms,
	RoomMemberResult,
	// Account encryption keys (protocol 16): one per account a ServerUserKeys or
	// ServerUserKeyChanged told this client about, after it was applied.
	UserKeys,
	// Encrypted direct messages (protocol 17): a message from history that waited for a key and
	// is now opened (or settled), and queued messages that went out or back into the draft.
	DirectOpened,
	DirectQueue,
	// Encrypted rooms (protocol 18): a room's member log after the client applied what arrived.
	RoomLog,
	// Sender chains (protocol 19, headless_room_chains.odin): a history message that waited for
	// its key or the log and is now opened (or settled), a key envelope handled, a key request
	// answered or refused, and queued messages that went out or back into the draft.
	RoomOpened,
	RoomKey,
	RoomKeyRequest,
	RoomQueue,
	// Derived by the harness (headless_voice.odin), not runtime events.
	VoiceSpeaking,
	VoiceStatus,
	// Encrypted voice (protocol 21, headless_voice.odin): a voice key sent, accepted or
	// refused, or a key request sent or received.
	VoiceKey,
	// Roles (protocol 23, headless_roles.odin).
	RoleList,
	RoleUpdated,
	RoleDeleted,
	// Room permissions (protocol 24, headless_room_permissions.odin).
	RoomPermissions,
	// Registration (protocol 25, headless_registration.odin).
	RegistrationRequired,
	RegistrationResult,
	RegistrationMode,
	InviteCreated,
	InviteList,
	RegistrationRequests,
	RegistrationRequest,
	LinkPending,
	// Attachments (protocol 26, headless_attachments.odin): the transfer worker's events.
	AttachmentProgress,
	AttachmentDone,
	AttachmentError,
	// Attachment moderation (protocol 28, headless_attachments.odin): ServerAttachmentRemoved
	// and ServerAdminAttachmentUsage.
	AttachmentRemoved,
	AttachmentUsage,
	// Protocol 29 (#138): ServerAdminAttachmentRemovals, a page of the removal log.
	AttachmentRemovals,
	// Protocol 30 (#76, headless_message_edits.odin): an edit, a tombstone and an edit list,
	// printed after State checked them.
	MessageEdited,
	MessageDeleted,
	MessageEdits,
}

HEADLESS_EVENT_NAMES := [HeadlessEventKind]string {
	.Connecting     = "connecting",
	.Connected      = "connected",
	.ConnectFailed  = "connect_failed",
	.RoomChat       = "room_chat",
	.RoomList       = "room_list",
	.RoomHistory    = "room_history",
	.RoomMembership = "room_membership",
	.RoomEdited     = "room_edited",
	.RoomDeleted    = "room_deleted",
	.ProtocolError  = "protocol_error",
	.Disconnected   = "disconnected",
	.DirectMessage  = "direct_message",
	.DirectHistory  = "direct_history",
	.UserList       = "user_list",
	.Conversations  = "conversations",
	.Presence       = "presence",
	.RoomCreated    = "room_created",
	.ReadMarker     = "read_marker",
	.VoiceParticipants = "voice_participants",
	.VoiceJoinRejected = "voice_join_rejected",
	.VoiceLeft      = "voice_left",
	.UserUpdated    = "user_updated",
	.AccountUpdated = "account_updated",
	.AdminResult    = "admin_result",
	.SessionEnded   = "session_ended",
	.RoomMembers    = "room_members",
	.AdminRooms     = "admin_rooms",
	.RoomMemberResult = "room_member_result",
	.UserKeys       = "user_keys",
	.DirectOpened   = "direct_opened",
	.DirectQueue    = "direct_queue",
	.RoomLog        = "room_log",
	.RoomOpened     = "room_opened",
	.RoomKey        = "room_key",
	.RoomKeyRequest = "room_key_request",
	.RoomQueue      = "room_queue",
	.VoiceSpeaking  = "voice_speaking",
	.VoiceStatus    = "voice_status",
	.VoiceKey       = "voice_key",
	.RoleList       = "role_list",
	.RoleUpdated    = "role_updated",
	.RoleDeleted    = "role_deleted",
	.RoomPermissions = "room_permissions",
	.RegistrationRequired = "registration_required",
	.RegistrationResult = "registration_result",
	.RegistrationMode = "registration_mode",
	.InviteCreated  = "invite_created",
	.InviteList     = "invite_list",
	.RegistrationRequests = "registration_requests",
	.RegistrationRequest = "registration_request",
	.LinkPending    = "link_pending",
	.AttachmentProgress = "attachment_progress",
	.AttachmentDone = "attachment_done",
	.AttachmentError = "attachment_error",
	.AttachmentRemoved = "attachment_removed",
	.AttachmentUsage = "attachment_usage",
	.AttachmentRemovals = "attachment_removals",
	.MessageEdited  = "message_edited",
	.MessageDeleted = "message_deleted",
	.MessageEdits   = "message_edits",
}

headlessEventKindFromName :: proc(name: string) -> (HeadlessEventKind, bool) {
	for eventName, kind in HEADLESS_EVENT_NAMES {
		if eventName == name {
			return kind, true
		}
	}
	return {}, false
}

// isAdmin is the server's ServerAuthSuccess flag for this session: whether room management
// is offered. A role an admin changes from a client arrives as account_updated (protocol 14);
// one changed in the database shows on the next connection (`reconnect`). nickname is the
// account's name on the server, which an admin may have set and locked (nicknameLocked).
// permissions (protocol 23) are the account's effective server permissions
// (HEADLESS_PERMISSION_NAMES; every one for an admin).
HeadlessConnectedJSON :: struct {
	event:          string,
	serverID:       int,
	userID:         int,
	nickname:       string,
	isAdmin:        bool,
	nicknameLocked: bool,
	permissions:    []string,
	// Protocol 25: the server's registration mode (open, invite, approval), whether the account
	// is restricted, and whether this connection is the end of a sign-up (registered).
	registrationMode: string,
	isRestricted:   bool,
	registered:     bool,
}

// ServerUserUpdated: an admin changed an account's role, ban, or name (protocol 14). user is
// the account's full directory entry (HeadlessDirectoryUserJSON).
HeadlessUserUpdatedJSON :: struct {
	event:    string,
	serverID: int,
	user:     HeadlessDirectoryUserJSON,
}

// One directory entry in user_list and user_updated. identityPublicKey is the server's
// identity key for the account in hex ("" for none) and hasEncryptionKey whether it published
// a bundle (protocol 16). keyState is this client's state for the account's key when the line
// was printed, before the event was applied (e2eeKeyStateName: unknown, not_set_up,
// unverified, verified, key_changed, not_provided, invalid_key); user_keys reports changes.
HeadlessDirectoryUserJSON :: struct {
	id:                int,
	nickname:          string,
	isOnline:          bool,
	identityPublicKey: string,
	hasEncryptionKey:  bool,
	keyState:          string,
	isAdmin:           bool,
	isBanned:          bool,
	// Protocol 23: every role the account holds, the admin role included.
	roleIds:           []int,
	// Protocol 25: a restricted account (plan D11).
	isRestricted:      bool,
}

// data in lowercase hex, allocated with allocator.
headlessHex :: proc(data: []u8, allocator := context.allocator) -> string {
	context.allocator = allocator
	return common.encodeBytesToHex(data)
}

// The directory entry's JSON shape. identityPublicKey is allocated with allocator.
headlessDirectoryUser :: proc(
	user: common.UserSummary,
	state: ^State,
	serverID: int,
	allocator := context.allocator,
) -> HeadlessDirectoryUserJSON {
	keyState := E2EEKeyState.Unknown
	if state != nil {
		keyState = State_e2eePeerKeyInfo(state, serverID, user.id).state
	}
	identity := user.identityPublicKey
	identityHex := ""
	if identity != {} {
		identityHex = headlessHex(identity[:], allocator)
	}
	return HeadlessDirectoryUserJSON {
		id = user.id,
		nickname = user.nickname,
		isOnline = user.isOnline,
		identityPublicKey = identityHex,
		hasEncryptionKey = user.hasEncryptionKey,
		keyState = e2eeKeyStateName(keyState),
		isAdmin = user.isAdmin,
		isBanned = user.isBanned,
		roleIds = user.roleIds[:],
		isRestricted = user.isRestricted,
	}
}

// user_keys: what this client now knows about an account's key (e2ee_state.odin), after a
// ServerUserKeys or ServerUserKeyChanged was applied, and the answer to `verify` and
// `trust-key`. identityPublicKey and encryptionPublicKey are the PINNED keys in hex ("" without
// a pin), never the server's; safetyNumber is "" without a key to compare (in key_changed it is
// the new key's, which `verify` would trust). notice is "set_up_again" after a new encryption
// key under the same identity key, else "". message is the sentence the GUI shows, or "".
HeadlessUserKeysJSON :: struct {
	event:               string,
	serverID:            int,
	userID:              int,
	nickname:            string,
	keyState:            string,
	canEncrypt:          bool,
	verified:            bool,
	hasPin:              bool,
	identityPublicKey:   string,
	encryptionPublicKey: string,
	createdAt:           u64,
	safetyNumber:        string,
	notice:              string,
	message:             string,
}

// The answer to `verify` and `trust-key`: the same fields after ok and cmd.
HeadlessUserKeysResultJSON :: struct {
	ok:                  bool,
	cmd:                 string,
	serverID:            int,
	userID:              int,
	nickname:            string,
	keyState:            string,
	canEncrypt:          bool,
	verified:            bool,
	hasPin:              bool,
	identityPublicKey:   string,
	encryptionPublicKey: string,
	createdAt:           u64,
	safetyNumber:        string,
	notice:              string,
	message:             string,
}

// ServerAccountUpdated: an admin changed this account's role or name while it is connected.
HeadlessAccountUpdatedJSON :: struct {
	event:          string,
	serverID:       int,
	isAdmin:        bool,
	nickname:       string,
	nicknameLocked: bool,
	permissions:    []string,
	isRestricted:   bool,
}

// ServerAdminActionResult: this session's admin request succeeded. action is "role", "rename",
// "kick" or "ban" (an unban is a ban), or (protocol 23) "role-save", "role-delete" or
// "role-assign"; userID is the target and roleID the role a role-save or role-delete named.
// Protocol 25: "invite-revoke" (inviteID), "registration-mode", "registration-decide"
// (requestID) and "restricted" (userID).
HeadlessAdminResultJSON :: struct {
	event:     string,
	serverID:  int,
	action:    string,
	userID:    int,
	message:   string,
	roleID:    int,
	inviteID:  int,
	requestID: int,
	// Protocol 28: the attachment an attachment-remove removed (hex), left out for every other
	// action so their lines stay as they were.
	blobID:    string `json:"blobID,omitempty"`,
}

// ServerSessionEnded: an admin kicked or banned this account and the server ended the session.
// kind is "kicked" or "banned", message the explanation the GUI shows, reason the admin's
// (may be empty). The harness does not reconnect on its own (retryable is always false):
// `reconnect` connects again, and a banned account gets connect_failed with failure "Banned".
HeadlessSessionEndedJSON :: struct {
	event:     string,
	serverID:  int,
	kind:      string,
	message:   string,
	reason:    string,
	retryable: bool,
}

HEADLESS_ADMIN_ACTION_NAMES := [common.AdminAction]string {
	.SetRole = "role",
	.Rename  = "rename",
	.Kick    = "kick",
	.Ban     = "ban",
	.SaveRole = "role-save",
	.DeleteRole = "role-delete",
	.SetUserRoles = "role-assign",
	.RevokeInvite = "invite-revoke",
	.SetRegistrationMode = "registration-mode",
	.DecideRegistration = "registration-decide",
	.SetRestricted = "restricted",
	.RemoveAttachment = "attachment-remove",
}

// The words room-create and room-edit take for a room type, and what room_created,
// room_edited and room_list report as roomType (the protocol's number: 1 text, 2 voice, 3
// both).
headlessParseRoomType :: proc(word: string) -> (common.RoomType, bool) {
	switch word {
	case "text", "chat":
		return .Chat, true
	case "voice":
		return .Voice, true
	case "both":
		return .ChatAndVoice, true
	}
	return .ChatAndVoice, false
}

HeadlessConnectingJSON :: struct {
	event:    string,
	serverID: int,
	// Attempts since the last connected or disconnected event, starting at 1.
	attempt:  int,
}

// failure names the ClientConnectFailureKind, or a harness-only reason (NoServer, Timeout).
// message is the explanation the GUI shows; detail is the raw transport or server reason.
// retryable is true when the worker will try again (retryInMS from now); false means no further
// attempt happens until something changes.
HeadlessConnectFailedJSON :: struct {
	event:     string,
	serverID:  int,
	message:   string,
	detail:    string,
	failure:   string,
	retryable: bool,
	retryInMS: int,
}

HeadlessDisconnectedJSON :: struct {
	event:     string,
	serverID:  int,
	message:   string,
	retryInMS: int,
}

HeadlessMessageEventJSON :: struct {
	event:    string,
	serverID: int,
	message:  string,
}

// Protocol 19: encrypted is whether the message is sealed, protection what the client
// concluded (plain, pending, encrypted, failed, hidden), decryptError why it failed, is hidden
// or waits ("log", "no_key", "sender_key"), epoch its chain's epoch (0 for plaintext); content
// the opened or verified text, empty otherwise. Protocol 22 (#90): plain means the sender's
// signature verified; a hidden message (no valid signature) is one the window does not show.
//
// Protocol 27: attachments are the files the client checked (attachments.odin MessageFile; empty
// until the message opened or verified), attachmentsChanged that a sealed message's outer list
// is not the one inside the seal (its files are then unavailable).
HeadlessRoomChatJSON :: struct {
	event:              string,
	serverID:           int,
	roomID:             int,
	messageID:          int,
	senderID:           int,
	senderNickname:     string,
	timestamp:          string,
	// Protocol 30 (headless_message_edits.odin): the server's edit count, whether it was
	// edited, what the client concluded about the latest edit (none, verified, pending,
	// failed), and a tombstone and whether it reads "Removed by the server". content is the
	// latest verified version.
	editCount:          int,
	edited:             bool,
	editStatus:         string,
	deleted:            bool,
	removedByServer:    bool,
	attachments:        []HeadlessAttachmentJSON,
	attachmentsChanged: bool,
	encrypted:          bool,
	decryptError:       string,
	epoch:              int,
	protection:         string,
	content:            string,
}

// One checked file of a message (protocol 27): its blob ID, the stored size and the file's own
// size, the stored blob's hash, name, media type, whether it is encrypted, and whether an admin
// removed it (F3). attach-download ROOM_ID|@USER_ID MESSAGE_ID INDEX OUT saves it.
HeadlessAttachmentJSON :: struct {
	blobID:    string,
	size:      u64,
	fileSize:  u64,
	sha256:    string,
	name:      string,
	mediaType: string,
	encrypted: bool,
	removed:   bool,
}

// The JSON of a message's checked files (temp).
headlessAttachmentsJSON :: proc(files: []MessageFile) -> []HeadlessAttachmentJSON {
	if len(files) == 0 {
		return nil
	}
	list := make([]HeadlessAttachmentJSON, len(files), context.temp_allocator)
	for file, index in files {
		blobId := file.blobId
		sha := file.sha256
		list[index] = HeadlessAttachmentJSON {
			blobID    = headlessHex(blobId[:], context.temp_allocator),
			size      = file.storedSize,
			fileSize  = file.fileSize,
			sha256    = headlessHex(sha[:], context.temp_allocator),
			name      = file.name,
			mediaType = file.mediaType,
			encrypted = file.encrypted,
			removed   = file.removed,
		}
	}
	return list
}

HeadlessRoomListJSON :: struct {
	event:    string,
	serverID: int,
	rooms:    []HeadlessRoomJSON,
}

HeadlessHistoryMessageJSON :: struct {
	id:                 int,
	senderID:           int,
	senderNickname:     string,
	timestamp:          string,
	// Protocol 30 (headless_message_edits.odin): the server's edit count, whether it was
	// edited, what the client concluded about the latest edit (none, verified, pending,
	// failed), and a tombstone and whether it reads "Removed by the server". content is the
	// latest verified version.
	editCount:          int,
	edited:             bool,
	editStatus:         string,
	deleted:            bool,
	removedByServer:    bool,
	attachments:        []HeadlessAttachmentJSON,
	attachmentsChanged: bool,
	encrypted:          bool,
	decryptError:       string,
	epoch:              int,
	protection:         string,
	content:            string,
}

HeadlessRoomHistoryJSON :: struct {
	event:    string,
	serverID: int,
	roomID:   int,
	hasOlder: bool,
	messages: []HeadlessHistoryMessageJSON,
}

// userID (protocol 15) is the account that joined or left: yours, or another member's when you
// are in the room (or asked for the change).
HeadlessRoomMembershipJSON :: struct {
	event:    string,
	serverID: int,
	roomID:   int,
	joined:   bool,
	userID:   int,
}

// roomType is the protocol's number: 1 text, 2 voice, 3 both (protocol 14). access is 1
// Public, 2 Member invite, 3 Admin invite, and historyVisibility 1 From join, 2 Full (always 2
// for a Public room) (protocol 15). isMember is set on room_created: false for a room created
// without joining it. encrypted and logVersion (protocol 18) are the server's: whether the room
// is encrypted and its member log's newest version (room_log says what the client verified).
HeadlessRoomEditedJSON :: struct {
	event:             string,
	serverID:          int,
	roomID:            int,
	name:              string,
	description:       string,
	roomType:          int,
	access:            int,
	historyVisibility: int,
	isMember:          bool,
	encrypted:         bool,
	logVersion:        int,
}

// room_created: room_edited's fields and (protocol 24) this account's permissions in the new
// room. ServerEditRoom carries none, so room_edited has no such field.
HeadlessRoomCreatedJSON :: struct {
	event:             string,
	serverID:          int,
	roomID:            int,
	name:              string,
	description:       string,
	roomType:          int,
	access:            int,
	historyVisibility: int,
	isMember:          bool,
	encrypted:         bool,
	logVersion:        int,
	myPermissions:     []string,
}

// An encrypted room's member log as this client verified it (protocol 18), printed after each
// ServerRoomLog was applied and for room-log. status is unknown, loading, verified or failed;
// logVersion and headHash the verified head (the epoch); serverLogVersion the server's newest;
// members and managers (ascending) what the verified log proves; logError the rule that failed
// (empty unless failed) and warning the sentence the GUI shows; events one line per verified
// change ("alice added carol").
HeadlessRoomLogJSON :: struct {
	event:             string,
	serverID:          int,
	roomID:            int,
	status:            string,
	logVersion:        int,
	serverLogVersion:  int,
	headHash:          string,
	access:            int,
	historyVisibility: int,
	members:           []int,
	managers:          []int,
	logError:          string,
	warning:           string,
	events:            []string,
}

// room-log-entry: a signed (or, with unsigned, an unsigned) entry built on the verified head,
// as hex, not sent; for proofs that insert entries behind the server's back.
HeadlessRoomLogEntryJSON :: struct {
	ok:       bool,
	cmd:      string,
	serverID: int,
	roomID:   int,
	version:  int,
	entry:    string,
}

// ServerRoomMembers: the room's members, ascending.
HeadlessRoomMembersJSON :: struct {
	event:    string,
	serverID: int,
	roomID:   int,
	userIDs:  []int,
}

// ServerAdminRooms: every room on the server, with the admin's membership and member count.
HeadlessAdminRoomsJSON :: struct {
	event:    string,
	serverID: int,
	rooms:    []HeadlessAdminRoomJSON,
}

// The answer to this session's room-add (added true) or room-remove: changed false when the
// account already was (or was not) a member.
HeadlessRoomMemberResultJSON :: struct {
	event:    string,
	serverID: int,
	roomID:   int,
	userID:   int,
	added:    bool,
	changed:  bool,
}

HeadlessRoomEventJSON :: struct {
	event:    string,
	serverID: int,
	roomID:   int,
}

// A direct message, live or from history. The conversation's peer is recipientID when
// senderID is the viewer's own userID (from `connected`), otherwise senderID.
//
// Protocol 17: printed after State opened it (content is the plaintext of an encrypted
// message). encrypted: it is an envelope; signed: its signature verified against the sender's
// pin (every opened envelope, and a valid plaintext fallback); decryptError: why an envelope
// could not be opened or why it is hidden ("no_key", "own_key", "replayed", "unsigned",
// "bad_signature", or the E2EEError), otherwise ""; protection: pending, signed, encrypted,
// failed or hidden. A hidden message (#82: its sender's signature was not verified) is one the
// window does not show; its content is always empty, as is a pending one's. A live message
// waiting for its sender's key is printed once it opened.
HeadlessDirectMessageJSON :: struct {
	event:              string,
	serverID:           int,
	id:                 int,
	senderID:           int,
	senderNickname:     string,
	recipientID:        int,
	recipientNickname:  string,
	timestamp:          string,
	// Protocol 30 (headless_message_edits.odin): the server's edit count, whether it was
	// edited, what the client concluded about the latest edit (none, verified, pending,
	// failed), and a tombstone and whether it reads "Removed by the server". content is the
	// latest verified version.
	editCount:          int,
	edited:             bool,
	editStatus:         string,
	deleted:            bool,
	removedByServer:    bool,
	// Protocol 27, as in HeadlessRoomChatJSON.
	attachments:        []HeadlessAttachmentJSON,
	attachmentsChanged: bool,
	encrypted:          bool,
	signed:             bool,
	decryptError:       string,
	protection:         string,
	content:            string,
}

HeadlessDirectHistoryMessageJSON :: struct {
	id:                 int,
	senderID:           int,
	senderNickname:     string,
	recipientID:        int,
	recipientNickname:  string,
	timestamp:          string,
	// Protocol 30 (headless_message_edits.odin): the server's edit count, whether it was
	// edited, what the client concluded about the latest edit (none, verified, pending,
	// failed), and a tombstone and whether it reads "Removed by the server". content is the
	// latest verified version.
	editCount:          int,
	edited:             bool,
	editStatus:         string,
	deleted:            bool,
	removedByServer:    bool,
	attachments:        []HeadlessAttachmentJSON,
	attachmentsChanged: bool,
	encrypted:          bool,
	signed:             bool,
	decryptError:       string,
	protection:         string,
	content:            string,
}

// Queued messages (protocol 17): state "sent" (count of them went out encrypted) or
// "refused" (they went back into the draft; reason says why).
HeadlessDirectQueueJSON :: struct {
	event:      string,
	serverID:   int,
	peerUserID: int,
	state:      string,
	count:      int,
	reason:     string,
}

HeadlessDirectHistoryJSON :: struct {
	event:      string,
	serverID:   int,
	peerUserID: int,
	hasOlder:   bool,
	messages:   []HeadlessDirectHistoryMessageJSON,
}

HeadlessUserListJSON :: struct {
	event:    string,
	serverID: int,
	users:    []HeadlessDirectoryUserJSON,
}

// unreadCount and lastReadMessageId are the read state (protocol 11): from the server's list,
// moved by read_marker events, plus the peer's live messages counted since.
//
// Protocol 17: lastContent is the opened preview; encrypted, signed, decryptError and
// protection describe the newest message as in direct_message, and conversationEncrypted is
// the key store's no-downgrade flag for the peer.
HeadlessConversationJSON :: struct {
	peerUserID:            int,
	peerNickname:          string,
	lastMessageID:         int,
	lastSenderID:          int,
	lastTimestamp:         string,
	encrypted:             bool,
	signed:                bool,
	decryptError:          string,
	protection:            string,
	conversationEncrypted: bool,
	lastContent:           string,
	lastReadMessageId:     int,
	unreadCount:           int,
}

HeadlessConversationsJSON :: struct {
	event:         string,
	serverID:      int,
	conversations: []HeadlessConversationJSON,
}

// ServerReadMarker: this account marked a conversation read, on this session or another one.
// kind is "room" (conversationID is a room ID) or "dm" (a peer user ID).
HeadlessReadMarkerJSON :: struct {
	event:             string,
	serverID:          int,
	kind:              string,
	conversationID:    int,
	lastReadMessageId: int,
	unreadCount:       int,
}

// One voice participant. The server lists each user at most once (protocol 13).
HeadlessVoiceParticipantJSON :: struct {
	userID:   int,
	nickname: string,
	muted:    bool,
	deafened: bool,
}

// ServerVoiceParticipants: a room's full voice participant set, sent for every room this
// account is in whenever it changes (an empty list means nobody is in its voice any more).
HeadlessVoiceParticipantsJSON :: struct {
	event:           string,
	serverID:        int,
	roomID:          int,
	// Whether this session itself is in the room's voice (the server's per-session flag).
	recipientJoined: bool,
	participants:    []HeadlessVoiceParticipantJSON,
}

// ServerVoiceJoinRejected and ServerVoiceLeft: the server's reason for refusing a join or
// removing this session from a room's voice.
HeadlessVoiceReasonJSON :: struct {
	event:    string,
	serverID: int,
	roomID:   int,
	reason:   string,
}

HEADLESS_READ_MARKER_KIND_NAMES := [common.ReadMarkerKind]string {
	.Room   = "room",
	.Direct = "dm",
}

HeadlessPresenceJSON :: struct {
	event:    string,
	serverID: int,
	userID:   int,
	nickname: string,
	isOnline: bool,
}

// Converts conversation entries to their JSON shape. Strings stay borrowed; free the slice
// with allocator. state (optional) gives the no-downgrade flag.
headlessConversationsJSON :: proc(
	conversations: []DirectConversationEntry,
	state: ^State = nil,
	serverID := 0,
	allocator := context.allocator,
) -> []HeadlessConversationJSON {
	result := make([]HeadlessConversationJSON, len(conversations), allocator)
	for conversation, index in conversations {
		fields := headlessDirectSecurity(conversation.security, len(conversation.lastEnvelope) > 0)
		result[index] = {
			peerUserID        = conversation.peerUserId,
			peerNickname      = conversation.peerNickname,
			lastMessageID     = conversation.lastMessageID,
			lastSenderID      = conversation.lastSenderId,
			lastTimestamp     = conversation.lastTimestamp,
			lastContent       = headlessDirectContent(
				conversation.security,
				conversation.lastContent,
			),
			encrypted         = fields.encrypted,
			signed            = fields.signed,
			decryptError      = fields.decryptError,
			protection        = fields.protection,
			lastReadMessageId = conversation.lastReadMessageId,
			unreadCount       = conversation.unreadCount,
		}
		if state != nil {
			result[index].conversationEncrypted = State_directConversationEncrypted(
				state,
				serverID,
				conversation.peerUserId,
			)
		}
	}
	return result
}

HeadlessDirectSecurityFields :: struct {
	encrypted:    bool,
	signed:       bool,
	decryptError: string,
	protection:   string,
}

HEADLESS_DIRECT_PROTECTION_NAMES := [DirectMessageProtection]string {
	.Pending   = "pending",
	.Signed    = "signed",
	.Encrypted = "encrypted",
	.Failed    = "failed",
	.Hidden    = "hidden",
}

// The harness fields for what the client concluded about a message. Strings are static.
headlessDirectSecurity :: proc(
	security: DirectMessageSecurity,
	hasEnvelope: bool,
) -> HeadlessDirectSecurityFields {
	fields := HeadlessDirectSecurityFields {
		encrypted  = hasEnvelope,
		signed     = security.protection == .Signed || security.protection == .Encrypted,
		protection = HEADLESS_DIRECT_PROTECTION_NAMES[security.protection],
	}
	if security.protection == .Failed || security.protection == .Hidden {
		switch security.failure {
		case .None, .Envelope:
			fields.decryptError = headlessE2EEErrorName(security.envelopeError)
		case .NoKey:
			fields.decryptError = "no_key"
		case .OwnKey:
			fields.decryptError = "own_key"
		case .Replayed:
			fields.decryptError = "replayed"
		case .Unsigned:
			fields.decryptError = "unsigned"
		case .BadSignature:
			fields.decryptError = "bad_signature"
		}
	}
	return fields
}

// The text the harness prints for a message: only what the window would show as content.
headlessDirectContent :: proc(security: DirectMessageSecurity, content: string) -> string {
	#partial switch security.protection {
	case .Signed, .Encrypted:
		return content
	}
	return ""
}

headlessE2EEErrorName :: proc(err: common.E2EEError) -> string {
	names := reflect.enum_field_names(common.E2EEError)
	values := reflect.enum_field_values(common.E2EEError)
	for value, index in values {
		if common.E2EEError(value) == err {
			return names[index]
		}
	}
	return "unknown"
}

// The JSON of a direct message as State holds it: the cached entry when there is one (opened
// content and what was checked), otherwise the message as it came. Strings stay borrowed.
headlessDirectMessageFields :: proc(
	state: ^State,
	serverID: int,
	message: common.StoredDirectMessage,
) -> HeadlessDirectHistoryMessageJSON {
	entry := DirectMessageEntry {
		message = message,
		security = {protection = .Pending},
	}
	if len(message.envelope) == 0 && message.signature == {} {
		entry.security = {protection = .Hidden, failure = .Unsigned}
	}
	if cached := headlessCachedDirectEntry(state, serverID, message); cached != nil {
		entry = cached^
	}
	fields := headlessDirectSecurity(entry.security, len(entry.envelope) > 0)
	return HeadlessDirectHistoryMessageJSON {
		id = entry.id,
		senderID = entry.senderId,
		senderNickname = entry.senderNickname,
		recipientID = entry.recipientId,
		recipientNickname = entry.recipientNickname,
		timestamp = entry.timestamp,
		encrypted = fields.encrypted,
		signed = fields.signed,
		decryptError = fields.decryptError,
		protection = fields.protection,
		content = headlessDirectContent(entry.security, headlessEditedContent(
			entry.content,
			entry.edit,
			entry.deleted,
		)),
		attachments = headlessAttachmentsJSON(entry.files[:]),
		attachmentsChanged = entry.filesChanged,
		editCount = entry.editCount,
		edited = entry.editCount > 0,
		editStatus = HEADLESS_EDIT_STATUS_NAMES[entry.edit.status],
		deleted = entry.deleted,
		removedByServer = entry.deleted && entry.edit.deleteStatus != .Author,
	}
}

headlessCachedDirectEntry :: proc(
	state: ^State,
	serverID: int,
	message: common.StoredDirectMessage,
) -> ^DirectMessageEntry {
	if state == nil {
		return nil
	}
	index := State_serverDirectCacheIndex(state^, serverID)
	peerUserID := directMessagePeerUserID(message, State_selfUserID(state, serverID))
	if index < 0 || peerUserID <= 0 {
		return nil
	}
	cache := &state.serverDirectCaches[index]
	conversationIndex := ServerDirectCache_conversationCacheIndex(cache^, peerUserID)
	if conversationIndex < 0 {
		return nil
	}
	return DirectConversationCache_entry(&cache.caches[conversationIndex], message.id)
}

// What rendering needs beyond the event itself. The harness fills it in; zero values are fine
// for tests (now defaults to the current time).
HeadlessRenderInfo :: struct {
	attempt:     int, // For .Connecting
	displayName: string, // Names the user in a NameUnavailable explanation
	now:         time.Tick, // Reference for retryInMS
	// For each account's keyState in user_list and user_updated; nil prints "unknown".
	state:       ^State,
}

// Milliseconds from now until at, never negative; 0 when at is unset.
headlessMillisecondsUntil :: proc(at, now: time.Tick) -> int {
	if at == {} {
		return 0
	}
	return max(int(time.duration_milliseconds(time.tick_diff(now, at))), 0)
}

// Marshals value as one compact JSON object. The result is allocated with allocator.
headlessMarshal :: proc(value: any, allocator := context.allocator) -> string {
	data, err := json.marshal(value, allocator = allocator)
	if err != nil {
		fmt.eprintln("[Error] Failed to encode JSON output:", err)
		return strings.clone(`{"event":"internal_error"}`, allocator)
	}
	return string(data)
}

// Renders a runtime event as one JSON line without the newline. It reads the event's payload,
// so it must run before State_applyRuntimeEvent moves fields out. ok is false for events that
// are not reported (.None).
headlessRenderRuntimeEvent :: proc(
	event: ^ClientTransportRuntimeEvent,
	info := HeadlessRenderInfo{},
	allocator := context.allocator,
) -> (
	line: string,
	kind: HeadlessEventKind,
	ok: bool,
) {
	now := info.now
	if now == {} {
		now = time.tick_now()
	}
	switch event.kind {
	case .None:
		return "", {}, false
	case .UserKeysReceived, .UserKeyChanged:
		// Printed as user_keys after State applied them (headlessHandleRuntimeEvent).
		return "", {}, false
	case .RoomLogReceived:
		// Printed as room_log after State verified it (headlessWriteRoomLogNotes).
		return "", {}, false
	case .RoomKeyEnvelopeReceived, .RoomKeysReceived, .RoomKeyRequested:
		// Printed as room_key and room_key_request after State handled them.
		return "", {}, false
	case .MessageEdited, .MessageDeleted, .MessageEditsReceived:
		// Printed as message_edited, message_deleted and message_edits after State checked
		// them (headless_message_edits.odin).
		return "", {}, false
	case .RoleListReceived, .RoleUpdated, .RoleDeleted:
		return headlessRenderRoleEvent(event, allocator)
	case .RoomPermissionsReceived:
		return headlessRenderRoomPermissionsEvent(event, allocator)
	case .AttachmentRemoved, .AttachmentUsageReceived, .AttachmentRemovalsReceived:
		return headlessRenderAttachmentModerationEvent(event, allocator)
	case .RegistrationRequired,
	     .RegistrationResult,
	     .RegistrationModeChanged,
	     .InviteCreated,
	     .InviteList,
	     .RegistrationRequests,
	     .RegistrationRequestUpdated:
		return headlessRenderRegistrationEvent(event, info, allocator)
	case .VoiceKeyReceived, .VoiceKeyRequested:
		// Printed as voice_key after State handled them (headlessPollVoice).
		return "", {}, false
	case .RoomChatReceived:
		// The harness prints room messages after State opened them (headlessWriteRoomChat).
		if info.state != nil {
			return "", {}, false
		}
		// Without a State nothing was checked (protocol 22): pending, with no content.
		kind = .RoomChat
		fields := headlessRoomSecurity({protection = .Pending}, len(event.sealed) > 0)
		line = headlessMarshal(
			HeadlessRoomChatJSON {
				event = HEADLESS_EVENT_NAMES[kind],
				serverID = event.serverID,
				roomID = event.roomID,
				messageID = event.messageID,
				senderID = event.senderID,
				senderNickname = event.senderNickname,
				timestamp = event.timestamp,
				editStatus = HEADLESS_EDIT_STATUS_NAMES[.None],
				encrypted = fields.encrypted,
				decryptError = fields.decryptError,
				protection = fields.protection,
				content = "",
			},
			allocator,
		)
	case .RoomListReceived:
		kind = .RoomList
		line = headlessMarshal(
			HeadlessRoomListJSON {
				event = HEADLESS_EVENT_NAMES[kind],
				serverID = event.serverID,
				rooms = headlessRooms(event.rooms[:]),
			},
			allocator,
		)
	case .RoomHistoryReceived:
		if info.state != nil {
			return "", {}, false
		}
		kind = .RoomHistory
		messages := make([]HeadlessHistoryMessageJSON, len(event.messages), allocator)
		defer delete(messages, allocator)
		for message, index in event.messages {
			messages[index] = headlessRoomMessageFields(nil, event.serverID, message)
		}
		line = headlessMarshal(
			HeadlessRoomHistoryJSON {
				event = HEADLESS_EVENT_NAMES[kind],
				serverID = event.serverID,
				roomID = event.roomID,
				hasOlder = event.hasOlder,
				messages = messages,
			},
			allocator,
		)
	case .RoomMembershipChanged:
		kind = .RoomMembership
		line = headlessMarshal(
			HeadlessRoomMembershipJSON {
				event = HEADLESS_EVENT_NAMES[kind],
				serverID = event.serverID,
				roomID = event.roomID,
				joined = event.joined,
				userID = event.peerUserID,
			},
			allocator,
		)
	case .RoomEdited:
		kind = .RoomEdited
		line = headlessMarshal(
			HeadlessRoomEditedJSON {
				event = HEADLESS_EVENT_NAMES[kind],
				serverID = event.serverID,
				roomID = event.roomID,
				name = event.room.name,
				description = event.room.description,
				roomType = int(event.room.roomType),
				access = int(event.room.access),
				historyVisibility = int(event.room.historyVisibility),
				encrypted = event.room.encrypted,
				logVersion = event.room.logVersion,
			},
			allocator,
		)
	case .RoomCreated:
		kind = .RoomCreated
		line = headlessMarshal(
			HeadlessRoomCreatedJSON {
				event = HEADLESS_EVENT_NAMES[kind],
				serverID = event.serverID,
				roomID = event.room.id,
				name = event.room.name,
				description = event.room.description,
				roomType = int(event.room.roomType),
				access = int(event.room.access),
				historyVisibility = int(event.room.historyVisibility),
				isMember = event.isMember,
				encrypted = event.room.encrypted,
				logVersion = event.room.logVersion,
				myPermissions = headlessRoomPermissionNames(event.room.myPermissions),
			},
			allocator,
		)
	case .RoomMembersReceived:
		kind = .RoomMembers
		line = headlessMarshal(
			HeadlessRoomMembersJSON {
				event = HEADLESS_EVENT_NAMES[kind],
				serverID = event.serverID,
				roomID = event.roomID,
				userIDs = event.userIDs[:],
			},
			allocator,
		)
	case .AdminRoomsReceived:
		kind = .AdminRooms
		line = headlessMarshal(
			HeadlessAdminRoomsJSON {
				event = HEADLESS_EVENT_NAMES[kind],
				serverID = event.serverID,
				rooms = headlessAdminRooms(event.adminRooms[:]),
			},
			allocator,
		)
	case .RoomMemberResult:
		kind = .RoomMemberResult
		line = headlessMarshal(
			HeadlessRoomMemberResultJSON {
				event = HEADLESS_EVENT_NAMES[kind],
				serverID = event.serverID,
				roomID = event.roomID,
				userID = event.peerUserID,
				added = event.joined,
				changed = event.changed,
			},
			allocator,
		)
	case .RoomDeleted:
		kind = .RoomDeleted
		line = headlessMarshal(
			HeadlessRoomEventJSON {
				event = HEADLESS_EVENT_NAMES[kind],
				serverID = event.serverID,
				roomID = event.roomID,
			},
			allocator,
		)
	case .ProtocolError:
		kind = .ProtocolError
		line = headlessMarshal(
			HeadlessMessageEventJSON {
				event = HEADLESS_EVENT_NAMES[kind],
				serverID = event.serverID,
				message = event.message,
			},
			allocator,
		)
	case .Connecting:
		kind = .Connecting
		line = headlessMarshal(
			HeadlessConnectingJSON {
				event = HEADLESS_EVENT_NAMES[kind],
				serverID = event.serverID,
				attempt = max(info.attempt, 1),
			},
			allocator,
		)
	case .Connected:
		kind = .Connected
		line = headlessMarshal(
			HeadlessConnectedJSON {
				event = HEADLESS_EVENT_NAMES[kind],
				serverID = event.serverID,
				userID = event.userID,
				nickname = event.nickname,
				isAdmin = event.isAdmin,
				nicknameLocked = event.nicknameLocked,
				permissions = headlessPermissionNames(event.permissions),
				registrationMode = headlessRegistrationModeName(event.registrationMode),
				isRestricted = event.isRestricted,
				registered = event.registered,
			},
			allocator,
		)
	case .ConnectFailed:
		kind = .ConnectFailed
		message := describeConnectFailure(
			event.failureKind,
			event.message,
			info.displayName,
			event.serverFingerprint,
			allocator,
		)
		defer delete(message, allocator)
		line = headlessMarshal(
			HeadlessConnectFailedJSON {
				event = HEADLESS_EVENT_NAMES[kind],
				serverID = event.serverID,
				message = message,
				detail = event.message,
				failure = fmt.tprintf("%v", event.failureKind),
				retryable = event.retryable,
				retryInMS = event.retryable ? headlessMillisecondsUntil(event.retryAt, now) : 0,
			},
			allocator,
		)
	case .Disconnected:
		kind = .Disconnected
		line = headlessMarshal(
			HeadlessDisconnectedJSON {
				event = HEADLESS_EVENT_NAMES[kind],
				serverID = event.serverID,
				message = event.message,
				retryInMS = headlessMillisecondsUntil(event.retryAt, now),
			},
			allocator,
		)
	case .DirectMessageReceived, .DirectHistoryReceived, .DirectConversationsReceived:
		// Printed after State opened them (headlessHandleRuntimeEvent): what matters is the
		// plaintext and what the client checked, not the envelope the server sent.
		return "", {}, false
	case .UserListReceived:
		kind = .UserList
		users := make([]HeadlessDirectoryUserJSON, len(event.users), context.temp_allocator)
		for user, index in event.users {
			users[index] = headlessDirectoryUser(
				user,
				info.state,
				event.serverID,
				context.temp_allocator,
			)
		}
		line = headlessMarshal(
			HeadlessUserListJSON {
				event = HEADLESS_EVENT_NAMES[kind],
				serverID = event.serverID,
				users = users,
			},
			allocator,
		)
	case .ReadMarkerReceived:
		kind = .ReadMarker
		marker := event.readMarker
		line = headlessMarshal(
			HeadlessReadMarkerJSON {
				event = HEADLESS_EVENT_NAMES[kind],
				serverID = event.serverID,
				kind = HEADLESS_READ_MARKER_KIND_NAMES[marker.kind],
				conversationID = marker.conversationId,
				lastReadMessageId = marker.lastReadMessageId,
				unreadCount = marker.unreadCount,
			},
			allocator,
		)
	case .VoiceParticipants:
		kind = .VoiceParticipants
		participants := make(
			[]HeadlessVoiceParticipantJSON,
			len(event.voiceParticipants),
			allocator,
		)
		defer delete(participants, allocator)
		for participant, index in event.voiceParticipants {
			participants[index] = {
				userID   = participant.userId,
				nickname = participant.nickname,
				muted    = participant.muted,
				deafened = participant.deafened,
			}
		}
		line = headlessMarshal(
			HeadlessVoiceParticipantsJSON {
				event = HEADLESS_EVENT_NAMES[kind],
				serverID = event.serverID,
				roomID = event.roomID,
				recipientJoined = event.voiceRecipientJoined,
				participants = participants,
			},
			allocator,
		)
	case .VoiceJoinRejected, .VoiceLeft:
		kind = event.kind == .VoiceLeft ? .VoiceLeft : .VoiceJoinRejected
		line = headlessMarshal(
			HeadlessVoiceReasonJSON {
				event = HEADLESS_EVENT_NAMES[kind],
				serverID = event.serverID,
				roomID = event.roomID,
				reason = event.message,
			},
			allocator,
		)
	case .UserUpdated:
		kind = .UserUpdated
		line = headlessMarshal(
			HeadlessUserUpdatedJSON {
				event = HEADLESS_EVENT_NAMES[kind],
				serverID = event.serverID,
				user = headlessDirectoryUser(
					event.user,
					info.state,
					event.serverID,
					context.temp_allocator,
				),
			},
			allocator,
		)
	case .AccountUpdated:
		kind = .AccountUpdated
		line = headlessMarshal(
			HeadlessAccountUpdatedJSON {
				event = HEADLESS_EVENT_NAMES[kind],
				serverID = event.serverID,
				isAdmin = event.isAdmin,
				nickname = event.nickname,
				nicknameLocked = event.nicknameLocked,
				permissions = headlessPermissionNames(event.permissions),
				isRestricted = event.isRestricted,
			},
			allocator,
		)
	case .AdminActionResult:
		kind = .AdminResult
		line = headlessMarshal(
			HeadlessAdminResultJSON {
				event = HEADLESS_EVENT_NAMES[kind],
				serverID = event.serverID,
				action = HEADLESS_ADMIN_ACTION_NAMES[event.adminAction],
				userID = event.peerUserID,
				message = event.message,
				roleID = event.roleID,
				inviteID = event.inviteID,
				requestID = event.requestID,
				blobID = headlessAdminResultBlob(event.blobID),
			},
			allocator,
		)
	case .SessionEnded:
		kind = .SessionEnded
		message := describeConnectFailure(event.failureKind, event.message, "", "", allocator)
		defer delete(message, allocator)
		line = headlessMarshal(
			HeadlessSessionEndedJSON {
				event = HEADLESS_EVENT_NAMES[kind],
				serverID = event.serverID,
				kind = event.failureKind == .Banned ? "banned" : "kicked",
				message = message,
				reason = event.detail,
				retryable = event.retryable,
			},
			allocator,
		)
	case .UserPresenceChanged:
		kind = .Presence
		line = headlessMarshal(
			HeadlessPresenceJSON {
				event = HEADLESS_EVENT_NAMES[kind],
				serverID = event.serverID,
				userID = event.user.id,
				nickname = event.user.nickname,
				isOnline = event.user.isOnline,
			},
			allocator,
		)
	}
	return line, kind, true
}

// ── Command results ───────────────────────────────────────────────

HeadlessOKJSON :: struct {
	ok:  bool,
	cmd: string,
}

HeadlessErrorJSON :: struct {
	ok:    bool,
	cmd:   string,
	error: string,
}

// connection is "connecting", "connected", "retrying" (retryInMS until the next attempt),
// "failed" (stopped until `reconnect`), or "none" when no server is selected.
HeadlessStatusJSON :: struct {
	ok:             bool,
	cmd:            string,
	connection:     string,
	connected:      bool,
	retryInMS:      int,
	serverID:       int,
	server:         string,
	userID:         int,
	nickname:       string,
	isAdmin:        bool,
	nicknameLocked: bool,
	// Protocol 23: the account's effective server permissions.
	permissions:    []string,
	selectedRoomID: int,
	lastError:      string,
	// Protocol 25 (headless_registration.odin): the sign-up screen's phase (none, required,
	// submitting, pending, refused, declined, ended) and the server's sentence for it, the
	// registration mode, whether the account is restricted, and the approver badge (D18).
	signUp:         string,
	signUpMessage:  string,
	registrationMode: string,
	isRestricted:   bool,
	pendingRegistrations: int,
}

HeadlessRoomsJSON :: struct {
	ok:       bool,
	cmd:      string,
	serverID: int,
	loaded:   bool,
	loading:  bool,
	rooms:    []HeadlessRoomJSON,
}

HeadlessHistoryJSON :: struct {
	ok:              bool,
	cmd:             string,
	serverID:        int,
	roomID:          int,
	beforeMessageID: int,
}

HeadlessServerResultJSON :: struct {
	ok:       bool,
	cmd:      string,
	serverID: int,
}

// Protocol 19: encrypted for a room whose messages are sealed, queued while the sender chain is
// being set up (the message goes out later; room_queue says so).
HeadlessSendJSON :: struct {
	ok:        bool,
	cmd:       string,
	serverID:  int,
	roomID:    int,
	encrypted: bool,
	queued:    bool,
}

// One account in `users`: the directory entry plus the read state of the direct conversation
// with it (both 0 when there is none), and its admin role and ban (protocol 14).
HeadlessUserJSON :: struct {
	id:                int,
	nickname:          string,
	isOnline:          bool,
	lastReadMessageId: int,
	unreadCount:       int,
	// Protocol 16: as in HeadlessDirectoryUserJSON, keyState as of now.
	identityPublicKey: string,
	hasEncryptionKey:  bool,
	keyState:          string,
	isAdmin:           bool,
	isBanned:          bool,
	roleIds:           []int, // Protocol 23
	isRestricted:      bool, // Protocol 25
}

HeadlessUsersJSON :: struct {
	ok:       bool,
	cmd:      string,
	serverID: int,
	loaded:   bool,
	loading:  bool,
	users:    []HeadlessUserJSON,
}

HeadlessConversationsResultJSON :: struct {
	ok:            bool,
	cmd:           string,
	serverID:      int,
	loaded:        bool,
	loading:       bool,
	conversations: []HeadlessConversationJSON,
}

// The result of room-create, room-edit, and room-delete: the request went out. roomID is 0 for
// room-create; the server's answer arrives as a room_created, room_edited, or room_deleted
// event, or as a protocol_error (for example "Admin permission required"). roomType is the
// protocol's number (1 text, 2 voice, 3 both; 0 for room-delete).
HeadlessRoomRequestJSON :: struct {
	ok:                bool,
	cmd:               string,
	serverID:          int,
	roomID:            int,
	name:              string,
	description:       string,
	roomType:          int,
	// Protocol 15: room-create and room-edit echo the access mode; room-create also the
	// history setting and whether you join.
	access:            int,
	historyVisibility: int,
	creatorJoins:      bool,
}

// room-members, room-add, room-remove, room-leave and admin-rooms: the request went out. The
// answer is room_members, room_member_result (and room_membership), admin_rooms, or a
// protocol_error naming the refusal.
HeadlessRoomMemberRequestJSON :: struct {
	ok:       bool,
	cmd:      string,
	serverID: int,
	roomID:   int,
	userID:   int,
}

// The result of admin-role, admin-rename, admin-kick, admin-ban, and admin-unban: the request
// went out. The answer arrives as admin_result (with user_updated, account_updated, or the
// target's session_ended) or as a protocol_error naming the refusal.
HeadlessAdminRequestJSON :: struct {
	ok:       bool,
	cmd:      string,
	serverID: int,
	userID:   int,
}

// dm and dm-plain: the message went out (encrypted says how) or, for dm while the peer's key
// is still being fetched, was queued; a queued message is sent, or refused, with a
// direct_queue event once the key state is known.
HeadlessDirectSendJSON :: struct {
	ok:         bool,
	cmd:        string,
	serverID:   int,
	peerUserID: int,
	encrypted:  bool,
	queued:     bool,
}

HeadlessDirectHistoryRequestJSON :: struct {
	ok:              bool,
	cmd:             string,
	serverID:        int,
	peerUserID:      int,
	beforeMessageID: int,
}

// `read`: the mark-read went out. The server answers with a read_marker event on every session
// of the account when the marker moved, and with nothing when it did not.
HeadlessReadJSON :: struct {
	ok:             bool,
	cmd:            string,
	serverID:       int,
	kind:           string,
	conversationID: int,
	messageID:      int,
}

HeadlessWaitJSON :: struct {
	ok:       bool,
	cmd:      string,
	event:    string,
	waitedMS: int,
}

HeadlessSleepJSON :: struct {
	ok:  bool,
	cmd: string,
	ms:  int,
}

HeadlessHelpCommandJSON :: struct {
	usage:   string,
	summary: string,
}

HeadlessHelpJSON :: struct {
	ok:       bool,
	cmd:      string,
	commands: []HeadlessHelpCommandJSON,
	events:   []string,
}

// ── Command table ─────────────────────────────────────────────────

HeadlessCommandProc :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand)

// Whether the rest of the line after the positional arguments is one more argument, kept
// verbatim (inner spaces included). Not combined with optionalArgs.
HeadlessTextArgument :: enum u8 {
	None,
	Required,
	Optional,
}

HeadlessCommand :: struct {
	name:         string,
	args:         int, // Required positional arguments
	optionalArgs: int, // Optional positional arguments after the required ones
	text:         HeadlessTextArgument,
	usage:        string,
	summary:      string,
	run:          HeadlessCommandProc,
}

// Every command the harness understands. Adding one is a row here plus its handler.
HEADLESS_COMMANDS := [?]HeadlessCommand {
	{"status", 0, 0, .None, "status",
		"connection status, user, nickname, admin flag, selected server", headlessCommandStatus},
	{"reconnect", 0, 0, .None, "reconnect",
		"connects again now, without waiting for the next retry (also after a failure)",
		headlessCommandReconnect},
	{"rooms", 0, 0, .None, "rooms", "joined rooms from the cache; requests them if not loaded",
		headlessCommandRooms},
	{"history", 1, 1, .None, "history ROOM_ID [BEFORE_MESSAGE_ID]",
		"requests a history page; it arrives as a room_history event", headlessCommandHistory},
	{"send", 1, 0, .Required, "send ROOM_ID [--attach BLOB]... TEXT...",
		"sends the rest of the line to a room, with the uploads --attach names (protocol 27; " +
		"the text may then be empty)", headlessCommandSend},
	{"users", 0, 0, .None, "users",
		"every account with its online flag, from the cache; requests it if not loaded",
		headlessCommandUsers},
	{"conversations", 0, 0, .None, "conversations",
		"recent direct conversations, newest first; requests them if not loaded",
		headlessCommandConversations},
	{"dm", 1, 0, .Required, "dm USER_ID [--attach BLOB]... TEXT...",
		"sends the rest of the line as an encrypted direct message (queued while the key is " +
		"fetched, refused when encryption is not possible)", headlessCommandDirectMessage},
	{"dm-plain", 1, 0, .Required, "dm-plain USER_ID [--attach BLOB]... TEXT...",
		"sends a signed plaintext direct message through the Send without encryption switch, " +
		"only when encryption is not possible", headlessCommandDirectPlain},
	{"dm-history", 1, 1, .None, "dm-history USER_ID [BEFORE_MESSAGE_ID]",
		"requests a page of a direct conversation; it arrives as a direct_history event",
		headlessCommandDirectHistory},
	{"room-create", 2, 0, .Optional,
		"room-create TYPE[,public|member-invite|admin-invite|roles=ID+ID][,from-join|full]" +
		"[,no-join][,encrypted][,managers=ID+ID|managers=none] NAME [DESCRIPTION...]",
		"admins: creates a room (TYPE text|voice|both); it arrives as room_created; " +
		"encrypted names every admin as a manager unless managers= says otherwise",
		headlessCommandRoomCreate},
	{"room-edit", 3, 0, .Optional,
		"room-edit ROOM_ID TYPE[,public|member-invite|admin-invite|roles=ID+ID] NAME " +
		"[DESCRIPTION...]",
		"admins: sets a room's type, access, name, and description (empty without one)",
		headlessCommandRoomEdit},
	{"room-members", 1, 0, .None, "room-members ROOM_ID",
		"members and admins: the room's members; they arrive as room_members",
		headlessCommandRoomMembers},
	{"room-add", 2, 0, .None, "room-add ROOM_ID USER_ID",
		"adds an account to a room as its mode allows; answered by room_member_result",
		headlessCommandRoomAdd},
	{"room-remove", 2, 0, .None, "room-remove ROOM_ID USER_ID",
		"admins: removes an account from a room; answered by room_member_result",
		headlessCommandRoomRemove},
	{"room-leave", 1, 0, .None, "room-leave ROOM_ID",
		"leaves a non-public room (encrypted: a signed Leave); answered by room_membership",
		headlessCommandRoomLeave},
	{"room-log", 1, 0, .None, "room-log ROOM_ID",
		"an encrypted room's verified member log as room_log; fetches what is missing",
		headlessCommandRoomLog},
	{"room-manager", 3, 0, .None, "room-manager ROOM_ID USER_ID on|off",
		"managers: names an account a manager of an encrypted room, or stops doing so",
		headlessCommandRoomManager},
	{"room-access", 2, 0, .None, "room-access ROOM_ID member-invite|admin-invite",
		"manager admins: switches an encrypted room's mode with a signed SetAccess",
		headlessCommandRoomAccess},
	{"room-keys", 1, 1, .None, "room-keys ROOM_ID [fetch]",
		"an encrypted room's sender chains this profile holds (no keys) and its sending state; fetch asks the server for them again",
		headlessCommandRoomKeys},
	{"room-log-entry", 3, 1, .None,
		"room-log-entry ROOM_ID add|remove|add-manager|remove-manager|leave USER_ID [unsigned]",
		"prints a signed (or unsigned) entry on the verified head as hex without sending it",
		headlessCommandRoomLogEntry},
	{"room-permissions", 1, 0, .None, "room-permissions ROOM_ID",
		"ManageRooms or the room's edit-room: asks for its grants; they arrive as " +
		"room_permissions", headlessCommandRoomPermissions},
	{"room-permissions-set", 2, 0, .Optional,
		"room-permissions-set ROOM_ID EVERYONE|none [ROLE_ID=PERMISSIONS...]",
		"replaces a room's grants; PERMISSIONS is a comma list of send, speak, " +
		"manage-members, edit-room, attach-files; answered by room_permissions",
		headlessCommandRoomPermissionsSet},
	{"admin-rooms", 0, 0, .None, "admin-rooms",
		"admins: every room, joined or not; it arrives as admin_rooms",
		headlessCommandAdminRooms},
	{"room-delete", 1, 0, .None, "room-delete ROOM_ID",
		"admins: deletes a room and its history; it arrives as room_deleted",
		headlessCommandRoomDelete},
	{"admin-role", 2, 0, .None, "admin-role USER_ID on|off",
		"admins: grants or revokes the admin role; answered by admin_result",
		headlessCommandAdminRole},
	{"admin-rename", 2, 0, .Optional, "admin-rename USER_ID lock|unlock [NAME...]",
		"admins: renames an account (no NAME: only the lock); locked names survive sign-in",
		headlessCommandAdminRename},
	{"admin-kick", 1, 0, .Optional, "admin-kick USER_ID [REASON...]",
		"admins: ends every session of an account", headlessCommandAdminKick},
	{"admin-ban", 1, 0, .Optional, "admin-ban USER_ID [REASON...]",
		"admins: bans an account and ends its sessions", headlessCommandAdminBan},
	{"admin-unban", 1, 0, .None, "admin-unban USER_ID", "admins: lifts a ban",
		headlessCommandAdminUnban},
	{"roles-list", 0, 0, .None, "roles-list",
		"the server's roles from the cache; asks for them (role_list) when they have not arrived",
		headlessCommandRolesList},
	{"roles-save", 2, 0, .Required, "roles-save ROLE_ID PERMISSIONS|none NAME...",
		"admins: creates (ROLE_ID 0) or edits a role; PERMISSIONS is a comma list of " +
		"manage-rooms, manage-room-members, create-invites, approve-registrations",
		headlessCommandRolesSave},
	{"roles-delete", 1, 0, .None, "roles-delete ROLE_ID",
		"admins: deletes a role; its holders lose it", headlessCommandRolesDelete},
	{"roles-assign", 2, 0, .None, "roles-assign USER_ID ROLE_ID,ROLE_ID|none",
		"admins: makes the list every role of the account other than admin",
		headlessCommandRolesAssign},
	{"register", 1, 0, .Optional, "register CODE|-|form [REASON...]",
		"while registering: signs up with an invite code (- for none, Open servers only; " +
		"form for the one an invite link filled in); " +
		"answered by registration_result, or connected when the account was made",
		headlessCommandRegister},
	{"invite-create", 1, 0, .Optional,
		"invite-create -|expires=SECONDS,uses=N,roles=ID+ID,room=ID,skip-approval [NOTE...]",
		"create-invites: makes an invite code (default one day, one use; roles, room and " +
		"skip-approval are for admins); the code and link arrive once as invite_created",
		headlessCommandInviteCreate},
	{"invite-list", 0, 0, .None, "invite-list",
		"create-invites: the codes from the cache (admins every one); asks for them " +
		"(invite_list)", headlessCommandInviteList},
	{"invite-revoke", 1, 0, .None, "invite-revoke INVITE_ID",
		"revokes a code (admins any, others their own); answered by admin_result",
		headlessCommandInviteRevoke},
	{"registration-list", 0, 1, .None, "registration-list [all]",
		"approvers: sign-up requests from the cache and the pending count; asks for them " +
		"(registration_requests); all includes decided ones", headlessCommandRegistrationList},
	{"registration-decide", 2, 0, .Optional,
		"registration-decide REQUEST_ID approve|decline [REASON...]",
		"approvers: decides a pending request; answered by admin_result and " +
		"registration_request", headlessCommandRegistrationDecide},
	{"registration-mode", 1, 0, .None, "registration-mode open|invite|approval",
		"admins: sets how people sign up; everyone hears registration_mode",
		headlessCommandRegistrationMode},
	{"restrict", 2, 0, .None, "restrict USER_ID on|off",
		"admins: restricts an account or lifts it (off joins the Public rooms); admin_result",
		headlessCommandRestrict},
	{"link-open", 1, 0, .None, "link-open URL",
		"reads a haychat:// join or invite link as the GUI would (link_pending); nothing " +
		"connects until link-confirm", headlessCommandLinkOpen},
	{"link-confirm", 0, 0, .None, "link-confirm",
		"follows the open link: adds or matches the server, pins its key, connects (an " +
		"invite with registering set and the code in the sign-up form)",
		headlessCommandLinkConfirm},
	{"link-cancel", 0, 0, .None, "link-cancel", "drops the open link and its code",
		headlessCommandLinkCancel},
	{"user-keys", 1, 0, .None, "user-keys USER_ID",
		"fetches an account's encryption key bundle; the answer is a user_keys event",
		headlessCommandUserKeys},
	{"verify", 1, 0, .None, "verify USER_ID",
		"marks an account's key verified (compare safetyNumber first); trusts a changed key",
		headlessCommandVerify},
	{"trust-key", 1, 0, .None, "trust-key USER_ID",
		"pins an account's changed key, unverified (Trust the new key)", headlessCommandTrustKey},
	{"read", 2, 1, .None, "read room|dm ID [MESSAGE_ID]",
		"marks a room or conversation read (default: up to its newest loaded message)",
		headlessCommandRead},
	{"voice-join", 1, 0, .None, "voice-join ROOM_ID",
		"joins a room's voice; done at voice_status joined", headlessCommandVoiceJoin},
	{"voice-leave", 0, 0, .None, "voice-leave", "leaves voice", headlessCommandVoiceLeave},
	{"voice-source", 1, 0, .None, "voice-source tone:HZ[:AMP]|file:PATH|silence|device[:NAME]",
		"what the next join sends (files: raw F32LE mono 48 kHz)", headlessCommandVoiceSource},
	{"voice-sink", 1, 0, .None, "voice-sink file:PATH|null|device[:NAME]",
		"where the next join plays (files: raw F32LE mono 48 kHz)", headlessCommandVoiceSink},
	{"voice-gate", 1, 1, .None, "voice-gate vad [THRESHOLD_DB]|ptt|open",
		"voice activity, push-to-talk, or always sending", headlessCommandVoiceGate},
	{"voice-mute", 1, 0, .None, "voice-mute on|off", "stops sending and tells the server",
		headlessCommandVoiceMute},
	{"voice-deafen", 1, 0, .None, "voice-deafen on|off", "stops playback and tells the server",
		headlessCommandVoiceDeafen},
	{"voice-ptt", 1, 0, .None, "voice-ptt down|up", "presses or releases push-to-talk",
		headlessCommandVoicePushToTalk},
	{"voice-volume", 2, 0, .None, "voice-volume USER_ID PERCENT",
		"plays that user at 0 to 200 % on this server, for this client only",
		headlessCommandVoiceVolume},
	{"voice-mute-user", 2, 0, .None, "voice-mute-user USER_ID on|off",
		"stops or resumes playing that user's voice, for this client only",
		headlessCommandVoiceMuteUser},
	{"voice-stats", 0, 0, .None, "voice-stats",
		"engine, jitter, speaker and network voice counters", headlessCommandVoiceStats},
	{"voice-flush", 0, 0, .None, "voice-flush",
		"replies once the file sink's audio so far is on disk", headlessCommandVoiceFlush},
	{"voice-key-rotate", 1, 0, .None, "voice-key-rotate SECONDS",
		"rotates this client's voice key in encrypted rooms every SECONDS (default 1800)",
		headlessCommandVoiceKeyRotate},
	{"attach-upload", 1, 0, .Required, "attach-upload ROOM_ID|@USER_ID [--unchecked] FILE...",
		"uploads a file to a room or a direct conversation; attachment_progress, then " +
		"attachment_done with its blobID (or attachment_error); --unchecked leaves the size " +
		"and quota checks to the server", headlessCommandAttachUpload},
	{"attach-resume", 1, 0, .None, "attach-resume BLOB",
		"continues an upload this process started at the offset the server acknowledged",
		headlessCommandAttachResume},
	{"attach-download", 1, 0, .Required,
		"attach-download BLOB OUT... | attach-download ROOM_ID|@USER_ID MESSAGE_ID INDEX OUT...",
		"downloads a blob to OUT (through OUT.part), or file INDEX of a message, checked " +
		"against the message and decrypted (protocol 27); attachment_done carries its sha256",
		headlessCommandAttachDownload},
	{"attach-cancel", 1, 0, .None, "attach-cancel BLOB",
		"stops an upload (which cannot be resumed after) or a download; attachment_error " +
		"cancelled", headlessCommandAttachCancel},
	{"attach-usage", 0, 0, .None, "attach-usage",
		"admins: the server's attachment storage use; answered by attachment_usage " +
		"(usedBytes, capacityBytes, freeBytes and the top 100 accounts)",
		headlessCommandAttachUsage},
	{"attach-remove", 1, 0, .Optional, "attach-remove BLOB [REASON...]",
		"admins: removes an attachment (its message stays and lists it as removed); answered " +
		"by admin_result attachment-remove, and readers hear attachment_removed",
		headlessCommandAttachRemove},
	{"attach-removals", 0, 1, .None, "attach-removals [BEFORE_ID]",
		"admins: a page of the attachment removal log, newest first (BEFORE_ID: the oldest " +
		"id held, for the next page); answered by attachment_removals (entries, hasMore)",
		headlessCommandAttachRemovals},
	{"msg-edit", 2, 0, .Optional, "msg-edit ROOM_ID MESSAGE_ID [--forge] [--unchecked] TEXT...",
		"edits your room message (signed; protocol 30); answered by message_edited, or a " +
		"protocol_error. --forge sends a bad signature, --unchecked skips the local own-message " +
		"check, both so a proof sees the server refuse", headlessCommandMessageEdit},
	{"msg-delete", 2, 1, .None, "msg-delete ROOM_ID MESSAGE_ID [admin|unchecked]",
		"deletes your room message (signed), or with admin any room message as an admin " +
		"(unsigned moderation); answered by message_deleted", headlessCommandMessageDelete},
	{"dm-edit", 2, 0, .Optional, "dm-edit USER_ID MESSAGE_ID [--forge] [--unchecked] TEXT...",
		"edits your direct message to USER_ID (signed); answered by message_edited",
		headlessCommandDirectEdit},
	{"dm-delete", 2, 1, .None, "dm-delete USER_ID MESSAGE_ID [unchecked]",
		"deletes your direct message to USER_ID (signed); answered by message_deleted",
		headlessCommandDirectDelete},
	{"msg-edits", 3, 0, .None, "msg-edits room|dm ID MESSAGE_ID",
		"fetches a message's edit history, oldest first; answered by message_edits",
		headlessCommandMessageEdits},
	{"chat-latency", 2, 1, .None, "chat-latency ROOM_ID COUNT [INTERVAL_MS]",
		"sends COUNT room messages INTERVAL_MS apart (default 50) and reports their echo " +
		"times (p50MS, p95MS, maxMS, meanMS)", headlessCommandChatLatency},
	{"wait", 1, 1, .None, "wait EVENT_KIND [TIMEOUT_MS]",
		"waits for an unconsumed event of that kind (default 5000 ms)", headlessCommandWait},
	{"sleep", 1, 0, .None, "sleep MS", "keeps servicing the connection for MS milliseconds",
		headlessCommandSleep},
	{"help", 0, 0, .None, "help", "lists commands and event kinds", headlessCommandHelp},
	{"quit", 0, 0, .None, "quit", "disconnects and exits with code 0", headlessCommandQuit},
}

HeadlessParseError :: enum {
	None,
	Empty, // Blank line or a `#` comment
	UnknownCommand,
	BadArguments,
}

// Arguments are borrowed from the parsed line.
HeadlessParsedCommand :: struct {
	command:  ^HeadlessCommand, // nil unless the command name is known
	name:     string,
	args:     [HEADLESS_MAX_ARGS]string,
	argCount: int,
}

@(private = "file")
isHeadlessSpace :: proc(c: byte) -> bool {
	return c == ' ' || c == '\t'
}

@(private = "file")
headlessNextWord :: proc(rest: ^string) -> string {
	value := strings.trim_left(rest^, " \t")
	end := 0
	for end < len(value) && !isHeadlessSpace(value[end]) {
		end += 1
	}
	rest^ = value[end:]
	return value[:end]
}

headlessParseCommand :: proc(
	commands: []HeadlessCommand,
	line: string,
) -> (
	parsed: HeadlessParsedCommand,
	err: HeadlessParseError,
) {
	rest := strings.trim(line, " \t\r\n")
	if len(rest) == 0 || rest[0] == '#' {
		return parsed, .Empty
	}
	parsed.name = headlessNextWord(&rest)
	for index in 0 ..< len(commands) {
		if commands[index].name == parsed.name {
			parsed.command = &commands[index]
			break
		}
	}
	if parsed.command == nil {
		return parsed, .UnknownCommand
	}
	command := parsed.command
	positional := command.args + command.optionalArgs
	assert(
		positional + int(command.text != .None) <= HEADLESS_MAX_ARGS,
		"too many command args",
	)
	for parsed.argCount < positional {
		word := headlessNextWord(&rest)
		if len(word) == 0 {
			break
		}
		parsed.args[parsed.argCount] = word
		parsed.argCount += 1
	}
	rest = strings.trim_left(rest, " \t")
	if parsed.argCount < command.args {
		return parsed, .BadArguments
	}
	if command.text != .None {
		if len(rest) > 0 {
			parsed.args[parsed.argCount] = rest
			parsed.argCount += 1
		} else if command.text == .Required {
			return parsed, .BadArguments
		}
	} else if len(rest) > 0 {
		return parsed, .BadArguments
	}
	return parsed, .None
}

// Parses a non-negative integer argument that must not exceed maxValue.
headlessParseNumber :: proc(value: string, maxValue: int = max(int)) -> (int, bool) {
	parsed, ok := strconv.parse_int(value, 10)
	if !ok || parsed < 0 || parsed > maxValue {
		return 0, false
	}
	return parsed, true
}

// ── Harness ───────────────────────────────────────────────────────

HeadlessHarness :: struct {
	state:         State,
	out:           io.Writer, // JSON lines only
	commands:      []HeadlessCommand,
	// Events that arrived and have not been consumed by `wait` yet, per kind.
	pendingEvents:   [HeadlessEventKind]int,
	// Connecting events per server since its last connected or disconnected event.
	connectAttempts: map[int]int,
	// What voice_status and voice_speaking last reported (headless_voice.odin).
	voice:           HeadlessVoiceTracker,
	running:         bool,
	// Where the key stores go (keystore.odin); empty keeps them in memory (tests). Borrowed.
	keyStoreDir:     string,
	// Live direct messages (server ID, message ID) still waiting for their sender's key, to be
	// printed as direct_message once they open.
	owedDirectMessages: map[[2]int]bool,
	// Live room messages (server ID, message ID) still waiting for a key or the log, printed as
	// room_chat once they open.
	owedRoomMessages: map[[2]int]bool,
	// --invite-code and --reason (borrowed from the arguments), sent once on the first
	// registration_required (headless_registration.odin); answered tells startup to stop
	// waiting.
	autoInviteCode:       string,
	autoReason:           string,
	autoRegisterSent:     bool,
	autoRegisterAnswered: bool,
	// chat-latency's probe (headless_attachments.odin).
	latency:              HeadlessLatencyProbe,
}

HeadlessHarness_deinit :: proc(harness: ^HeadlessHarness) {
	HeadlessLatencyProbe_deinit(&harness.latency)
	State_deinit(&harness.state)
	delete(harness.connectAttempts)
	harness.connectAttempts = nil
	delete(harness.owedDirectMessages)
	harness.owedDirectMessages = nil
	delete(harness.owedRoomMessages)
	harness.owedRoomMessages = nil
}

// Writes one line followed by a newline in a single write, so lines never interleave.
headlessWriteLine :: proc(harness: ^HeadlessHarness, line: string) {
	buffer := make([]u8, len(line) + 1)
	defer delete(buffer)
	copy(buffer, line)
	buffer[len(line)] = '\n'
	_, _ = io.write(harness.out, buffer)
}

headlessWriteJSON :: proc(harness: ^HeadlessHarness, value: any) {
	line := headlessMarshal(value)
	defer delete(line)
	headlessWriteLine(harness, line)
}

headlessWriteError :: proc(harness: ^HeadlessHarness, cmd: string, message: string) {
	headlessWriteJSON(harness, HeadlessErrorJSON{ok = false, cmd = cmd, error = message})
}

headlessRecordEvent :: proc(harness: ^HeadlessHarness, kind: HeadlessEventKind) {
	harness.pendingEvents[kind] += 1
}

// Prints a runtime event, counts it for `wait`, then applies it to State exactly as the GUI
// does. The caller still owns the event and must deinit it.
headlessHandleRuntimeEvent :: proc(harness: ^HeadlessHarness, event: ^ClientTransportRuntimeEvent) {
	info := HeadlessRenderInfo {
		displayName = harness.state.config.display_name,
		state       = &harness.state,
	}
	// A server with a display name of its own signs in with that one.
	if server, ok := State_serverConfig(&harness.state, event.serverID); ok {
		info.displayName = Server_displayName(server^, harness.state.config)
	}
	if event.kind == .RoomChatReceived {
		headlessLatencyProbeSaw(harness, event.message)
	}
	#partial switch event.kind {
	case .Connecting:
		harness.connectAttempts[event.serverID] += 1
		info.attempt = harness.connectAttempts[event.serverID]
	case .Connected, .Disconnected:
		delete_key(&harness.connectAttempts, event.serverID)
	}
	// A sign-up that made the account (protocol 25): registration_result created, then
	// connected.
	if event.kind == .Connected && event.registered {
		headlessWriteRegistrationCreated(harness, event)
	}
	#partial switch event.kind {
	case .RegistrationResult, .Connected, .ConnectFailed:
		harness.autoRegisterAnswered = harness.autoRegisterSent
	}
	line, kind, ok := headlessRenderRuntimeEvent(event, info)
	if ok {
		headlessWriteLine(harness, line)
		delete(line)
		headlessRecordEvent(harness, kind)
	}
	State_applyRuntimeEvent(&harness.state, event)
	// Key and direct message events are reported from State after they were applied: what
	// matters is what the client concluded (pinned, changed, refused, opened), not what the
	// server sent.
	#partial switch event.kind {
	case .DirectMessageReceived:
		headlessWriteDirectMessageEvent(harness, event.serverID, event.directMessage)
	case .DirectHistoryReceived:
		headlessWriteDirectHistoryEvent(harness, event)
	case .DirectConversationsReceived:
		headlessWriteConversationsEvent(harness, event.serverID)
	case .RoomChatReceived:
		headlessWriteRoomChat(harness, event)
	case .RoomHistoryReceived:
		headlessWriteRoomHistory(harness, event)
	case .UserKeysReceived:
		for bundle in event.userKeys {
			headlessWriteUserKeysEvent(harness, event.serverID, bundle.userId)
		}
		for userID in event.missingUserIDs {
			headlessWriteUserKeysEvent(harness, event.serverID, userID)
		}
	case .UserKeyChanged:
		headlessWriteUserKeysEvent(harness, event.serverID, event.userKey.userId)
	case .MessageEdited, .MessageDeleted, .MessageEditsReceived:
		headlessWriteMessageEditEvent(harness, event)
	}
	if event.kind == .RegistrationRequired {
		headlessAutoRegister(harness, event)
	}
	headlessWriteDirectNotes(harness)
	headlessWriteRoomLogNotes(harness)
	headlessWriteRoomChainNotes(harness)
	// Applying a voice event can start or stop the engine; report that right after it.
	headlessPollVoice(harness)
}

// A live direct message, once it is open: one still waiting for its sender's key is owed and
// printed when it opens (headlessWriteDirectNotes).
headlessWriteDirectMessageEvent :: proc(
	harness: ^HeadlessHarness,
	serverID: int,
	message: common.StoredDirectMessage,
) {
	if cached := headlessCachedDirectEntry(&harness.state, serverID, message);
	   cached != nil && cached.security.protection == .Pending {
		harness.owedDirectMessages[{serverID, message.id}] = true
		return
	}
	headlessWriteDirectMessageLine(harness, .DirectMessage, serverID, message)
}

headlessWriteDirectMessageLine :: proc(
	harness: ^HeadlessHarness,
	kind: HeadlessEventKind,
	serverID: int,
	message: common.StoredDirectMessage,
) {
	fields := headlessDirectMessageFields(&harness.state, serverID, message)
	headlessWriteJSON(
		harness,
		HeadlessDirectMessageJSON {
			event = HEADLESS_EVENT_NAMES[kind],
			serverID = serverID,
			id = fields.id,
			senderID = fields.senderID,
			senderNickname = fields.senderNickname,
			recipientID = fields.recipientID,
			recipientNickname = fields.recipientNickname,
			timestamp = fields.timestamp,
			encrypted = fields.encrypted,
			signed = fields.signed,
			decryptError = fields.decryptError,
			protection = fields.protection,
			content = fields.content,
			attachments = fields.attachments,
			attachmentsChanged = fields.attachmentsChanged,
			editCount = fields.editCount,
			edited = fields.edited,
			editStatus = fields.editStatus,
			deleted = fields.deleted,
			removedByServer = fields.removedByServer,
		},
	)
	headlessRecordEvent(harness, kind)
}

headlessWriteDirectHistoryEvent :: proc(
	harness: ^HeadlessHarness,
	event: ^ClientTransportRuntimeEvent,
) {
	messages := make([]HeadlessDirectHistoryMessageJSON, len(event.directMessages))
	defer delete(messages)
	for message, index in event.directMessages {
		messages[index] = headlessDirectMessageFields(&harness.state, event.serverID, message)
	}
	headlessWriteJSON(
		harness,
		HeadlessDirectHistoryJSON {
			event = HEADLESS_EVENT_NAMES[.DirectHistory],
			serverID = event.serverID,
			peerUserID = event.peerUserID,
			hasOlder = event.hasOlder,
			messages = messages,
		},
	)
	headlessRecordEvent(harness, .DirectHistory)
}

headlessWriteConversationsEvent :: proc(harness: ^HeadlessHarness, serverID: int) {
	cache := State_serverDirectCache(&harness.state, serverID)
	conversations := headlessConversationsJSON(cache.conversations[:], &harness.state, serverID)
	defer delete(conversations)
	headlessWriteJSON(
		harness,
		HeadlessConversationsJSON {
			event = HEADLESS_EVENT_NAMES[.Conversations],
			serverID = serverID,
			conversations = conversations,
		},
	)
	headlessRecordEvent(harness, .Conversations)
}

// Prints what State recorded after the event or command that caused it: messages opened once
// their key arrived (an owed live message as direct_message, a history one as direct_opened),
// and what became of queued messages (direct_queue).
headlessWriteDirectNotes :: proc(harness: ^HeadlessHarness) {
	state := &harness.state
	for note in state.directNotes {
		switch note.kind {
		case .Opened:
			entry := headlessNoteEntry(state, note)
			if entry == nil {
				continue
			}
			kind := HeadlessEventKind.DirectOpened
			if harness.owedDirectMessages[{note.serverID, note.messageID}] {
				delete_key(&harness.owedDirectMessages, [2]int{note.serverID, note.messageID})
				kind = .DirectMessage
			}
			headlessWriteDirectMessageLine(harness, kind, note.serverID, entry.message)
		case .Queued:
		case .QueueSent, .QueueRefused:
			value := HeadlessDirectQueueJSON {
				event      = HEADLESS_EVENT_NAMES[.DirectQueue],
				serverID   = note.serverID,
				peerUserID = note.peerUserID,
				state      = "sent",
				count      = note.messageID,
			}
			if note.kind == .QueueRefused {
				value.state = "refused"
				value.count = 0
				value.reason = state.chat_status_message
			}
			headlessWriteJSON(harness, value)
			headlessRecordEvent(harness, .DirectQueue)
		}
	}
	clear(&state.directNotes)
}

@(private = "file")
headlessNoteEntry :: proc(state: ^State, note: DirectNote) -> ^DirectMessageEntry {
	index := State_serverDirectCacheIndex(state^, note.serverID)
	if index < 0 {
		return nil
	}
	cache := &state.serverDirectCaches[index]
	conversationIndex := ServerDirectCache_conversationCacheIndex(cache^, note.peerUserID)
	if conversationIndex < 0 {
		return nil
	}
	return DirectConversationCache_entry(&cache.caches[conversationIndex], note.messageID)
}

// The user_keys shape for userID on serverID, from State. Strings in the temp allocator.
headlessUserKeys :: proc(harness: ^HeadlessHarness, serverID, userID: int) -> HeadlessUserKeysJSON {
	state := &harness.state
	info := State_e2eePeerKeyInfo(state, serverID, userID)
	name := State_e2eeUserName(state, serverID, userID)
	safetyNumber, _ := State_e2eeSafetyNumber(state, serverID, userID)
	value := HeadlessUserKeysJSON {
		serverID     = serverID,
		userID       = userID,
		nickname     = name,
		keyState     = e2eeKeyStateName(info.state),
		canEncrypt   = info.canEncrypt,
		verified     = info.verified,
		hasPin       = info.hasPin,
		createdAt    = info.createdAt,
		safetyNumber = safetyNumber,
		notice       = info.notice == .KeySetUpAgain ? "set_up_again" : "",
		message      = e2eeKeyStateText(info, name),
	}
	if info.hasPin {
		identity := info.identityPublicKey
		encryption := info.encryptionPublicKey
		value.identityPublicKey = headlessHex(identity[:], context.temp_allocator)
		value.encryptionPublicKey = headlessHex(encryption[:], context.temp_allocator)
	}
	return value
}

headlessWriteUserKeysEvent :: proc(harness: ^HeadlessHarness, serverID, userID: int) {
	if userID <= 0 || userID == State_selfUserID(&harness.state, serverID) {
		return
	}
	value := headlessUserKeys(harness, serverID, userID)
	value.event = HEADLESS_EVENT_NAMES[.UserKeys]
	headlessWriteJSON(harness, value)
	headlessRecordEvent(harness, .UserKeys)
}

// user-keys USER_ID: asks the server for the account's bundle; the answer is a user_keys event.
headlessCommandUserKeys :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	userID, ok := headlessParseNumber(command.args[0])
	state := &harness.state
	serverID := state.selected_server_id
	if !ok || userID <= 0 || userID == State_selfUserID(state, serverID) {
		headlessWriteError(harness, command.name, "usage: user-keys USER_ID (not yourself)")
		return
	}
	if !State_isServerConnected(state, serverID) {
		headlessWriteError(harness, command.name, NOT_CONNECTED_MESSAGE)
		return
	}
	ids := [1]int{userID}
	requested := State_e2eeRequestUserKeys(state, serverID, ids[:]) > 0
	headlessWriteJSON(
		harness,
		HeadlessUserKeysRequestJSON {
			ok = true,
			cmd = command.name,
			serverID = serverID,
			userID = userID,
			requested = requested,
		},
	)
}

// requested is false when a fetch for the account was already on its way; its user_keys event
// still comes.
HeadlessUserKeysRequestJSON :: struct {
	ok:        bool,
	cmd:       string,
	serverID:  int,
	userID:    int,
	requested: bool,
}

// verify USER_ID: Mark as verified, after comparing the safety number (the reply carries it).
// In key_changed it trusts the new key and marks it verified, like the dialog.
headlessCommandVerify :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	headlessKeyAction(harness, command, true)
}

// trust-key USER_ID: Trust the new key in key_changed, unverified.
headlessCommandTrustKey :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	headlessKeyAction(harness, command, false)
}

@(private = "file")
headlessKeyAction :: proc(
	harness: ^HeadlessHarness,
	command: ^HeadlessParsedCommand,
	verify: bool,
) {
	userID, ok := headlessParseNumber(command.args[0])
	state := &harness.state
	serverID := state.selected_server_id
	if !ok || userID <= 0 || userID == State_selfUserID(state, serverID) {
		headlessWriteError(
			harness,
			command.name,
			fmt.tprintf("usage: %s USER_ID (not yourself)", command.name),
		)
		return
	}
	done := verify ? State_e2eeMarkVerified(state, serverID, userID) : State_e2eeTrustNewKey(
		state,
		serverID,
		userID,
	)
	if !done {
		info := State_e2eePeerKeyInfo(state, serverID, userID)
		reason := fmt.tprintf(
			"refused in key state %s%s",
			e2eeKeyStateName(info.state),
			info.state == .KeyChanged && !info.hasOfferedKey ? "; waiting for the new key" : "",
		)
		headlessWriteError(harness, command.name, reason)
		return
	}
	value := headlessUserKeys(harness, serverID, userID)
	headlessWriteJSON(
		harness,
		HeadlessUserKeysResultJSON {
			ok = true,
			cmd = command.name,
			serverID = value.serverID,
			userID = value.userID,
			nickname = value.nickname,
			keyState = value.keyState,
			canEncrypt = value.canEncrypt,
			verified = value.verified,
			hasPin = value.hasPin,
			identityPublicKey = value.identityPublicKey,
			encryptionPublicKey = value.encryptionPublicKey,
			createdAt = value.createdAt,
			safetyNumber = value.safetyNumber,
			notice = value.notice,
			message = value.message,
		},
	)
}

headlessDrainEvents :: proc(harness: ^HeadlessHarness) {
	for _ in 0 ..< CHAT_RUNTIME_MAX_EVENTS_PER_FRAME {
		event, hasEvent := ClientNetworkWorker_popEvent(harness.state.networkWorker)
		if !hasEvent {
			break
		}
		headlessHandleRuntimeEvent(harness, &event)
		ClientTransportRuntimeEvent_deinit(&event)
	}
	// Speaking changes without any event, and commands change the voice status.
	headlessPollVoice(harness)
	headlessDrainTransferEvents(harness)
}

headlessHandleLine :: proc(harness: ^HeadlessHarness, line: string) {
	parsed, err := headlessParseCommand(harness.commands, line)
	switch err {
	case .Empty:
	case .UnknownCommand:
		headlessWriteError(harness, parsed.name, "unknown command; send `help` for the list")
	case .BadArguments:
		message := strings.concatenate({"usage: ", parsed.command.usage})
		defer delete(message)
		headlessWriteError(harness, parsed.name, message)
	case .None:
		parsed.command.run(harness, &parsed)
		headlessWriteDirectNotes(harness)
		headlessWriteRoomLogNotes(harness)
	}
}

// Writes a connect_failed line that the harness itself produces (no runtime event behind it)
// and counts it for `wait`.
headlessWriteConnectFailed :: proc(
	harness: ^HeadlessHarness,
	serverID: int,
	message, detail, failure: string,
) {
	headlessWriteJSON(
		harness,
		HeadlessConnectFailedJSON {
			event = HEADLESS_EVENT_NAMES[.ConnectFailed],
			serverID = serverID,
			message = message,
			detail = detail,
			failure = failure,
		},
	)
	headlessRecordEvent(harness, .ConnectFailed)
}

// Builds the state, starts the network worker, and waits until the selected server is
// connected. This is the only place that knows how the client connects. The worker drives the
// connect state machine (connection.odin) and reports every step as a runtime event, which is
// printed and applied like any other, so `connecting` and `connect_failed` lines for retried
// attempts show up here too. Returns false, after a connect_failed line, when there is no
// server, when a failure stops retrying, or when timeout passes first.
headlessConnectAndWait :: proc(
	harness: ^HeadlessHarness,
	config: Config,
	timeout: time.Duration,
) -> bool {
	harness.state = State_initFromConfig(config)
	state := &harness.state
	state.recordDirectNotes = true
	state.recordRoomLogNotes = true
	state.recordRoomChainNotes = true
	state.voice.e2ee.recordNotes = true
	// The key store is written like the GUI writes it (keystore.odin), so a profile run twice
	// keeps its pins.
	if len(harness.keyStoreDir) > 0 {
		state.keyStoreDir = strings.clone(harness.keyStoreDir)
	}
	// No audio device unless a script asks for one (voice-source and voice-sink device): a
	// harness client in voice records nothing and plays nothing, and never initialises SDL.
	State_setVoiceEngineTemplate(
		state,
		{source = {kind = .Silence}, sink = {kind = .Null}, gateMode = .VoiceActivity},
	)
	serverID := state.selected_server_id
	_, hasTransport := State_selectedTransport(state)
	connectionIndex := State_serverConnectionIndex(state^, serverID)
	if !hasTransport || connectionIndex < 0 {
		headlessWriteConnectFailed(harness, 0, "no server is configured", "", "NoServer")
		return false
	}
	// A server whose config cannot work (such as a corrupt identity key) is failed before the
	// worker starts, so no runtime event will report it.
	if connection := state.serverConnections[connectionIndex]; connection.status == .Failed {
		message := describeConnectFailure(
			connection.failureKind,
			connection.detail,
			state.config.display_name,
			"",
		)
		failure := fmt.tprintf("%v", connection.failureKind)
		headlessWriteConnectFailed(harness, serverID, message, connection.detail, failure)
		return false
	}

	State_startNetwork(state)
	start := time.tick_now()
	for {
		headlessDrainEvents(harness)
		free_all(context.temp_allocator)
		// Applying events can add connection entries, so look the index up again.
		connectionIndex = State_serverConnectionIndex(state^, serverID)
		if connectionIndex >= 0 {
			#partial switch state.serverConnections[connectionIndex].status {
			case .Established:
				return true
			case .Registering:
				// Signing up (protocol 25): the script goes on with `register`, or, with
				// --invite-code, once the server answered the code.
				if len(harness.autoInviteCode) == 0 || harness.autoRegisterAnswered {
					return true
				}
			case .Failed:
				// The worker's connect_failed event (retryable false) is already printed.
				return false
			}
		}
		if time.tick_since(start) >= timeout {
			break
		}
		time.sleep(HEADLESS_POLL_INTERVAL)
	}

	address := ""
	if server, ok := State_serverConfig(state, serverID); ok {
		address = fmt.tprintf("%s:%d", server.host, server.port)
	}
	detail := ""
	if connectionIndex >= 0 {
		detail = state.serverConnections[connectionIndex].detail
	}
	message := fmt.tprintf(
		"timed out after %d ms connecting to %s",
		int(time.duration_milliseconds(timeout)),
		address,
	)
	headlessWriteConnectFailed(harness, serverID, message, detail, "Timeout")
	return false
}

// Keeps draining network events for duration, so the session stays serviced and every event
// is still printed while a command blocks.
headlessPumpFor :: proc(harness: ^HeadlessHarness, duration: time.Duration) {
	start := time.tick_now()
	for {
		headlessDrainEvents(harness)
		if time.tick_since(start) >= duration {
			return
		}
		time.sleep(HEADLESS_POLL_INTERVAL)
	}
}

// ── Command handlers ──────────────────────────────────────────────

// Reports State's mirror of the connection, the same source the GUI's status line uses, so it
// needs no worker lock.
headlessCommandStatus :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	state := &harness.state
	result := HeadlessStatusJSON {
		ok             = true,
		cmd            = command.name,
		connection     = "none",
		serverID       = state.selected_server_id,
		selectedRoomID = state.selected_channel_id,
	}
	if server, ok := State_serverConfig(state, state.selected_server_id); ok {
		result.server = fmt.tprintf("%s:%d", server.host, server.port)
	}
	if index := State_serverConnectionIndex(state^, state.selected_server_id); index >= 0 {
		connection := &state.serverConnections[index]
		switch connection.status {
		case .Idle, .Connecting, .Handshaking:
			result.connection = "connecting"
		case .Established:
			result.connection = "connected"
			result.connected = true
			result.userID = connection.userID
			result.nickname = connection.nickname
			result.isAdmin = connection.isAdmin
			result.nicknameLocked = connection.nicknameLocked
			result.permissions = headlessPermissionNames(
				State_serverPermissions(state, state.selected_server_id),
			)
		case .Disconnected:
			result.connection = "retrying"
			result.retryInMS = headlessMillisecondsUntil(connection.retryAt, time.tick_now())
		case .Failed:
			result.connection = "failed"
		case .Registering:
			result.connection = "registering"
		}
		result.lastError = connection.detail
		result.signUp = HEADLESS_SIGN_UP_PHASE_NAMES[connection.signUp]
		result.signUpMessage = connection.signUpMessage
		result.registrationMode = headlessRegistrationModeName(connection.registrationMode)
		result.isRestricted = connection.isRestricted
		result.pendingRegistrations = State_pendingRegistrationCount(
			state,
			state.selected_server_id,
		)
	}
	headlessWriteJSON(harness, result)
}

// "Retry now": drops any session in progress and connects at once. The outcome arrives as
// connecting and then connected or connect_failed events.
headlessCommandReconnect :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	state := &harness.state
	serverID := state.selected_server_id
	if _, ok := State_selectedTransport(state); !ok {
		headlessWriteError(harness, command.name, "no server is configured")
		return
	}
	State_retryConnection(state, serverID)
	// A server whose config cannot work stays failed; retrying it cannot help.
	if index := State_serverConnectionIndex(state^, serverID); index >= 0 {
		if connection := &state.serverConnections[index]; connection.status == .Failed {
			message := connection.detail
			if len(message) == 0 {
				message = "the server's config cannot be used to connect"
			}
			headlessWriteError(harness, command.name, message)
			return
		}
	}
	headlessWriteJSON(
		harness,
		HeadlessServerResultJSON{ok = true, cmd = command.name, serverID = serverID},
	)
}

headlessCommandRooms :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	state := &harness.state
	serverID := state.selected_server_id
	cache := State_serverRoomCache(state, serverID)
	if !cache.roomsLoaded && !cache.roomsLoading {
		State_requestRoomList(state, serverID)
		// Requesting can append a server cache, so look it up again.
		cache = State_serverRoomCache(state, serverID)
	}
	headlessWriteJSON(
		harness,
		HeadlessRoomsJSON {
			ok = true,
			cmd = command.name,
			serverID = serverID,
			loaded = cache.roomsLoaded,
			loading = cache.roomsLoading,
			rooms = headlessRooms(cache.rooms[:]),
		},
	)
}

headlessCommandHistory :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	roomID, roomOK := headlessParseNumber(command.args[0])
	beforeMessageID, beforeOK := 0, true
	if command.argCount > 1 {
		beforeMessageID, beforeOK = headlessParseNumber(command.args[1])
	}
	if !roomOK || roomID == 0 || !beforeOK {
		headlessWriteError(harness, command.name, "usage: " + "history ROOM_ID [BEFORE_MESSAGE_ID]")
		return
	}
	state := &harness.state
	serverID := state.selected_server_id
	roomCache := ServerRoomCache_roomCache(State_serverRoomCache(state, serverID), roomID)
	// An agent asks explicitly, so always send. The GUI's in-flight guard would otherwise
	// swallow the request forever after an error reply, which does not name the room.
	roomCache.isLoadingHistory = false
	State_clearChatStatus(state)
	State_requestRoomHistory(state, serverID, roomID, beforeMessageID)
	roomCache = ServerRoomCache_roomCache(State_serverRoomCache(state, serverID), roomID)
	if !roomCache.isLoadingHistory {
		message := state.chat_status_message
		if len(message) == 0 {
			message = "failed to request room history"
		}
		headlessWriteError(harness, command.name, message)
		return
	}
	headlessWriteJSON(
		harness,
		HeadlessHistoryJSON {
			ok = true,
			cmd = command.name,
			serverID = serverID,
			roomID = roomID,
			beforeMessageID = beforeMessageID,
		},
	)
}

// Sends through State_sendChannelChat, the same action the GUI composer uses: the text goes
// into the room's draft and the room becomes the selected one.
headlessCommandSend :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	roomID, roomOK := headlessParseNumber(command.args[0])
	if !roomOK || roomID == 0 {
		headlessWriteError(harness, command.name, "usage: send ROOM_ID TEXT...")
		return
	}
	blobIds, text, attachOK := headlessTakeAttachOptions(harness, command, command.args[1])
	if !attachOK {
		return
	}
	state := &harness.state
	State_closeDirectConversation(state)
	state.selected_channel_id = roomID
	draft := State_selectedRoomDraft(state)
	clear(draft)
	append(draft, ..transmute([]u8)text)
	State_clearChatStatus(state)
	// Protocol 24: the server, not the harness, refuses a room without SendMessages.
	State_sendChannelChat(state, checkPermission = false, attachments = blobIds)

	draft = State_selectedRoomDraft(state)
	if len(draft) > 0 || headlessAttachmentsOnlyFailed(state, text, blobIds) {
		// Leave nothing behind for the next send to the same room.
		clear(draft)
		message := state.chat_status_message
		if len(message) == 0 {
			message = "failed to send room chat message"
		}
		headlessWriteError(harness, command.name, message)
		return
	}
	encrypted := State_roomIsEncrypted(state, state.selected_server_id, roomID)
	queued := false
	if encrypted {
		queued = len(State_roomChainRoom(state, state.selected_server_id, roomID).queued) > 0
	}
	headlessWriteJSON(
		harness,
		HeadlessSendJSON {
			ok = true,
			cmd = command.name,
			serverID = state.selected_server_id,
			roomID = roomID,
			encrypted = encrypted,
			queued = queued,
		},
	)
}

headlessCommandUsers :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	state := &harness.state
	serverID := state.selected_server_id
	cache := State_serverDirectCache(state, serverID)
	if !cache.usersLoaded && !cache.usersLoading {
		State_requestUserList(state, serverID)
		cache = State_serverDirectCache(state, serverID)
	}
	users := make([]HeadlessUserJSON, len(cache.users))
	defer delete(users)
	for user, index in cache.users {
		users[index] = {
			id       = user.id,
			nickname = user.nickname,
			isOnline = user.isOnline,
			isAdmin  = user.isAdmin,
			isBanned = user.isBanned,
			roleIds  = user.roleIds[:],
			isRestricted = user.isRestricted,
		}
		directory := headlessDirectoryUser(user, state, serverID, context.temp_allocator)
		users[index].identityPublicKey = directory.identityPublicKey
		users[index].hasEncryptionKey = directory.hasEncryptionKey
		users[index].keyState = directory.keyState
		if summary := State_directSummary(state, serverID, user.id); summary != nil {
			users[index].lastReadMessageId = summary.lastReadMessageId
			users[index].unreadCount = summary.unreadCount
		}
	}
	headlessWriteJSON(
		harness,
		HeadlessUsersJSON {
			ok = true,
			cmd = command.name,
			serverID = serverID,
			loaded = cache.usersLoaded,
			loading = cache.usersLoading,
			users = users,
		},
	)
}

headlessCommandConversations :: proc(
	harness: ^HeadlessHarness,
	command: ^HeadlessParsedCommand,
) {
	state := &harness.state
	serverID := state.selected_server_id
	cache := State_serverDirectCache(state, serverID)
	if !cache.conversationsLoaded && !cache.conversationsLoading {
		State_requestDirectConversations(state, serverID)
		cache = State_serverDirectCache(state, serverID)
	}
	conversations := headlessConversationsJSON(cache.conversations[:], state, serverID)
	defer delete(conversations)
	headlessWriteJSON(
		harness,
		HeadlessConversationsResultJSON {
			ok = true,
			cmd = command.name,
			serverID = serverID,
			loaded = cache.conversationsLoaded,
			loading = cache.conversationsLoading,
			conversations = conversations,
		},
	)
}

// Sends through State_sendDirectMessageTo, the action behind the GUI's DM composer: the text
// goes into that conversation's draft. The open conversation does not change. Like the GUI it
// encrypts, queues while the peer's key is being fetched, and is refused when encryption is not
// possible (the plaintext fallback is dm-plain).
headlessCommandDirectMessage :: proc(
	harness: ^HeadlessHarness,
	command: ^HeadlessParsedCommand,
) {
	headlessSendDirect(harness, command, plaintext = false)
}

// dm-plain USER_ID TEXT...: the plaintext fallback (design 4.6) through the same actions as
// the GUI's "Send without encryption" switch: it turns the switch on (accepting the first-time
// confirmation), sends, and turns it off again, as closing the conversation would. Refused
// while encryption to the peer is possible or its key is still being checked.
headlessCommandDirectPlain :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	headlessSendDirect(harness, command, plaintext = true)
}

@(private = "file")
headlessSendDirect :: proc(
	harness: ^HeadlessHarness,
	command: ^HeadlessParsedCommand,
	plaintext: bool,
) {
	usage := plaintext ? "usage: dm-plain USER_ID TEXT..." : "usage: dm USER_ID TEXT..."
	peerUserID, peerOK := headlessParseNumber(command.args[0])
	if !peerOK || peerUserID == 0 {
		headlessWriteError(harness, command.name, usage)
		return
	}
	state := &harness.state
	serverID := state.selected_server_id
	if plaintext {
		result := State_setDirectFallback(state, serverID, peerUserID, true)
		if result == .NeedsConfirmation {
			State_confirmDirectFallback(state, serverID, peerUserID)
		} else if result == .Unavailable {
			info := State_e2eePeerKeyInfo(state, serverID, peerUserID)
			message := "encryption to this user is possible; use dm"
			if info.blockReason == .Pending {
				message = "the user's key is still being checked; try again"
			}
			headlessWriteError(harness, command.name, message)
			return
		}
	}
	defer if plaintext {
		State_setDirectFallback(state, serverID, peerUserID, false)
	}
	conversation := ServerDirectCache_conversationCache(
		State_serverDirectCache(state, serverID),
		peerUserID,
	)
	mode := directSendMode(
		State_e2eePeerKeyInfo(state, serverID, peerUserID),
		conversation.fallbackOn,
	)
	blobIds, text, attachOK := headlessTakeAttachOptions(harness, command, command.args[1])
	if !attachOK {
		return
	}
	if len(blobIds) > 0 && mode == .Queue {
		// A message with files waits for the key in the composer, not in the queue.
		headlessWriteError(
			harness,
			command.name,
			"the user's key is still being checked; try again",
		)
		return
	}
	clear(&conversation.draft)
	append(&conversation.draft, ..transmute([]u8)text)
	State_clearChatStatus(state)
	State_sendDirectMessageTo(state, serverID, peerUserID, blobIds)

	draft := &ServerDirectCache_conversationCache(
		State_serverDirectCache(state, serverID),
		peerUserID,
	).draft
	if len(draft) > 0 || headlessAttachmentsOnlyFailed(state, text, blobIds) {
		// Leave nothing behind for the next message to the same user.
		clear(draft)
		message := state.chat_status_message
		if len(message) == 0 {
			message = "failed to send direct message"
		}
		headlessWriteError(harness, command.name, message)
		return
	}
	headlessWriteJSON(
		harness,
		HeadlessDirectSendJSON {
			ok = true,
			cmd = command.name,
			serverID = serverID,
			peerUserID = peerUserID,
			encrypted = mode == .Encrypt,
			queued = mode == .Queue,
		},
	)
}

headlessCommandDirectHistory :: proc(
	harness: ^HeadlessHarness,
	command: ^HeadlessParsedCommand,
) {
	peerUserID, peerOK := headlessParseNumber(command.args[0])
	beforeMessageID, beforeOK := 0, true
	if command.argCount > 1 {
		beforeMessageID, beforeOK = headlessParseNumber(command.args[1])
	}
	if !peerOK || peerUserID == 0 || !beforeOK {
		headlessWriteError(
			harness,
			command.name,
			"usage: dm-history USER_ID [BEFORE_MESSAGE_ID]",
		)
		return
	}
	state := &harness.state
	serverID := state.selected_server_id
	conversation := ServerDirectCache_conversationCache(
		State_serverDirectCache(state, serverID),
		peerUserID,
	)
	// As with `history`, an explicit request always goes out: error replies do not name the
	// request, so the in-flight guard could otherwise stay set.
	conversation.isLoadingHistory = false
	State_clearChatStatus(state)
	State_requestDirectHistory(state, serverID, peerUserID, beforeMessageID)
	conversation = ServerDirectCache_conversationCache(
		State_serverDirectCache(state, serverID),
		peerUserID,
	)
	if !conversation.isLoadingHistory {
		message := state.chat_status_message
		if len(message) == 0 {
			message = "failed to request direct history"
		}
		headlessWriteError(harness, command.name, message)
		return
	}
	headlessWriteJSON(
		harness,
		HeadlessDirectHistoryRequestJSON {
			ok = true,
			cmd = command.name,
			serverID = serverID,
			peerUserID = peerUserID,
			beforeMessageID = beforeMessageID,
		},
	)
}

// Room management goes through the same actions as the GUI's room form, minus the form: the
// harness does not check the admin flag, so an agent can see the server refuse a non-admin.
@(private = "file")
headlessWriteRoomRequest :: proc(
	harness: ^HeadlessHarness,
	command: ^HeadlessParsedCommand,
	errorMessage: string,
	roomID: int,
	name, description: string,
	roomType: common.RoomType = {},
	options: HeadlessRoomOptions = {},
) {
	if len(errorMessage) > 0 {
		headlessWriteError(harness, command.name, errorMessage)
		return
	}
	headlessWriteJSON(
		harness,
		HeadlessRoomRequestJSON {
			ok = true,
			cmd = command.name,
			serverID = harness.state.selected_server_id,
			roomID = roomID,
			name = name,
			description = description,
			roomType = int(roomType),
			access = int(options.access),
			historyVisibility = int(options.history),
			creatorJoins = options.creatorJoins,
		},
	)
}

// The TYPE[,OPTION...] word of room-create and room-edit (protocol 15). Options: public,
// member-invite, admin-invite; from-join, full (room-create); no-join (room-create).
HeadlessRoomOptions :: struct {
	roomType:     common.RoomType,
	access:       common.RoomAccess,
	hasAccess:    bool,
	history:      common.RoomHistoryVisibility,
	creatorJoins: bool,
	// Protocol 18 (room-create): encrypted, and the managers besides yourself; hasManagers
	// false names every admin the client sees, as the create form does.
	encrypted:    bool,
	hasManagers:  bool,
	managers:     [8]int,
	managerCount: int,
	// Protocol 24: roles=ID+ID makes a Role room whose members are those roles' holders.
	accessRoles:  [common.SERVER_ROLES_MAX]int,
	accessRoleCount: int,
}

headlessParseRoomOptions :: proc(word: string, create: bool) -> (HeadlessRoomOptions, bool) {
	options := HeadlessRoomOptions {
		access       = .Public,
		history      = .FromJoin,
		creatorJoins = true,
	}
	remaining := word
	first := true
	for part in strings.split_iterator(&remaining, ",") {
		if first {
			roomType, ok := headlessParseRoomType(part)
			if !ok {
				return options, false
			}
			options.roomType = roomType
			first = false
			continue
		}
		switch part {
		case "public":
			options.access, options.hasAccess = .Public, true
		case "member-invite":
			options.access, options.hasAccess = .MemberInvite, true
		case "admin-invite":
			options.access, options.hasAccess = .AdminInvite, true
		case "from-join":
			if !create {
				return options, false
			}
			options.history = .FromJoin
		case "full":
			if !create {
				return options, false
			}
			options.history = .Full
		case "no-join":
			if !create {
				return options, false
			}
			options.creatorJoins = false
		case "encrypted":
			if !create {
				return options, false
			}
			options.encrypted = true
		case:
			if strings.has_prefix(part, "roles=") {
				options.access, options.hasAccess = .Role, true
				list := part[len("roles="):]
				for id in strings.split_iterator(&list, "+") {
					roleID, ok := headlessParseNumber(id)
					if !ok || roleID <= 0 || options.accessRoleCount == len(options.accessRoles) {
						return options, false
					}
					options.accessRoles[options.accessRoleCount] = roleID
					options.accessRoleCount += 1
				}
				if options.accessRoleCount == 0 {
					return options, false
				}
				continue
			}
			if !create || !strings.has_prefix(part, "managers=") {
				return options, false
			}
			options.hasManagers = true
			list := part[len("managers="):]
			if list == "none" {
				continue
			}
			for id in strings.split_iterator(&list, "+") {
				userID, ok := headlessParseNumber(id)
				if !ok || userID <= 0 || options.managerCount == len(options.managers) {
					return options, false
				}
				options.managers[options.managerCount] = userID
				options.managerCount += 1
			}
		}
	}
	return options, !first
}

headlessCommandRoomCreate :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	options, optionsOK := headlessParseRoomOptions(command.args[0], true)
	if !optionsOK {
		usage := strings.concatenate({"usage: ", command.command.usage})
		defer delete(usage)
		headlessWriteError(harness, command.name, usage)
		return
	}
	name := command.args[1]
	description := command.argCount > 2 ? command.args[2] : ""
	state := &harness.state
	managers := options.managers[:options.managerCount]
	if options.encrypted && !options.hasManagers {
		managers = State_roomLogAdminCandidates(state, state.selected_server_id)
	}
	errorMessage := State_sendCreateRoom(
		state,
		state.selected_server_id,
		name,
		description,
		options.roomType,
		options.access,
		options.history,
		options.creatorJoins,
		options.encrypted,
		managers,
		options.accessRoles[:options.accessRoleCount],
	)
	cleanName, cleanDescription, _ := validateRoomMetadata(name, description)
	headlessWriteRoomRequest(
		harness,
		command,
		errorMessage,
		0,
		cleanName,
		cleanDescription,
		options.roomType,
		options,
	)
}

headlessCommandRoomEdit :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	roomID, roomOK := headlessParseNumber(command.args[0])
	options, optionsOK := headlessParseRoomOptions(command.args[1], false)
	if !roomOK || roomID == 0 || !optionsOK {
		usage := strings.concatenate({"usage: ", command.command.usage})
		defer delete(usage)
		headlessWriteError(harness, command.name, usage)
		return
	}
	name := command.args[2]
	description := command.argCount > 3 ? command.args[3] : ""
	state := &harness.state
	// Without an access option the room keeps the mode the client knows for it, and a Role
	// room the access roles of its last room_permissions (protocol 24).
	if !options.hasAccess {
		options.access = State_roomAccess(state, state.selected_server_id, roomID)
		if options.access == .Role {
			grants := State_findRoomGrants(state, state.selected_server_id, roomID)
			if grants == nil {
				headlessWriteError(
					harness,
					command.name,
					"run room-permissions ROOM_ID first: a Role room's edit repeats its roles",
				)
				return
			}
			for roleID in grants.accessRoleIDs {
				if options.accessRoleCount < len(options.accessRoles) {
					options.accessRoles[options.accessRoleCount] = roleID
					options.accessRoleCount += 1
				}
			}
		}
	}
	errorMessage := State_sendEditRoom(
		state,
		state.selected_server_id,
		roomID,
		name,
		description,
		options.roomType,
		options.access,
		options.accessRoles[:options.accessRoleCount],
	)
	cleanName, cleanDescription, _ := validateRoomMetadata(name, description)
	options.creatorJoins = false
	options.history = {}
	headlessWriteRoomRequest(
		harness,
		command,
		errorMessage,
		roomID,
		cleanName,
		cleanDescription,
		options.roomType,
		options,
	)
}

// Admin actions on accounts go through the same actions a GUI would use. Like room management,
// the harness does not check the admin flag, so an agent can see the server refuse.
@(private = "file")
headlessWriteAdminRequest :: proc(
	harness: ^HeadlessHarness,
	command: ^HeadlessParsedCommand,
	errorMessage: string,
	userID: int,
) {
	if len(errorMessage) > 0 {
		headlessWriteError(harness, command.name, errorMessage)
		return
	}
	headlessWriteJSON(
		harness,
		HeadlessAdminRequestJSON {
			ok = true,
			cmd = command.name,
			serverID = harness.state.selected_server_id,
			userID = userID,
		},
	)
}

// The USER_ID argument of an admin command, or 0 after an error line.
@(private = "file")
headlessAdminTarget :: proc(
	harness: ^HeadlessHarness,
	command: ^HeadlessParsedCommand,
) -> int {
	userID, ok := headlessParseNumber(command.args[0])
	if !ok || userID == 0 {
		usage := strings.concatenate({"usage: ", command.command.usage})
		defer delete(usage)
		headlessWriteError(harness, command.name, usage)
		return 0
	}
	return userID
}

headlessCommandAdminRole :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	userID := headlessAdminTarget(harness, command)
	if userID == 0 {
		return
	}
	isAdmin: bool
	switch command.args[1] {
	case "on":
		isAdmin = true
	case "off":
		isAdmin = false
	case:
		headlessWriteError(harness, command.name, "usage: admin-role USER_ID on|off")
		return
	}
	state := &harness.state
	errorMessage := State_sendAdminSetRole(state, state.selected_server_id, userID, isAdmin)
	headlessWriteAdminRequest(harness, command, errorMessage, userID)
}

headlessCommandAdminRename :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	userID := headlessAdminTarget(harness, command)
	if userID == 0 {
		return
	}
	locked: bool
	switch command.args[1] {
	case "lock":
		locked = true
	case "unlock":
		locked = false
	case:
		headlessWriteError(
			harness,
			command.name,
			"usage: admin-rename USER_ID lock|unlock [NAME...]",
		)
		return
	}
	nickname := command.argCount > 2 ? command.args[2] : ""
	state := &harness.state
	errorMessage := State_sendAdminRenameUser(
		state,
		state.selected_server_id,
		userID,
		nickname,
		locked,
	)
	headlessWriteAdminRequest(harness, command, errorMessage, userID)
}

headlessCommandAdminKick :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	userID := headlessAdminTarget(harness, command)
	if userID == 0 {
		return
	}
	reason := command.argCount > 1 ? command.args[1] : ""
	state := &harness.state
	errorMessage := State_sendAdminKickUser(state, state.selected_server_id, userID, reason)
	headlessWriteAdminRequest(harness, command, errorMessage, userID)
}

headlessCommandAdminBan :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	userID := headlessAdminTarget(harness, command)
	if userID == 0 {
		return
	}
	reason := command.argCount > 1 ? command.args[1] : ""
	state := &harness.state
	errorMessage := State_sendAdminBanUser(state, state.selected_server_id, userID, true, reason)
	headlessWriteAdminRequest(harness, command, errorMessage, userID)
}

headlessCommandAdminUnban :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	userID := headlessAdminTarget(harness, command)
	if userID == 0 {
		return
	}
	state := &harness.state
	errorMessage := State_sendAdminBanUser(state, state.selected_server_id, userID, false, "")
	headlessWriteAdminRequest(harness, command, errorMessage, userID)
}

// room-members, room-add, room-remove, room-leave and admin-rooms. Like room management, the
// harness checks nothing the server checks, so an agent can see the server refuse.
@(private = "file")
headlessWriteRoomMemberRequest :: proc(
	harness: ^HeadlessHarness,
	command: ^HeadlessParsedCommand,
	errorMessage: string,
	roomID, userID: int,
) {
	if len(errorMessage) > 0 {
		headlessWriteError(harness, command.name, errorMessage)
		return
	}
	headlessWriteJSON(
		harness,
		HeadlessRoomMemberRequestJSON {
			ok = true,
			cmd = command.name,
			serverID = harness.state.selected_server_id,
			roomID = roomID,
			userID = userID,
		},
	)
}

// ROOM_ID and, with withUser, USER_ID; ok false after an error line.
@(private = "file")
headlessRoomMemberArgs :: proc(
	harness: ^HeadlessHarness,
	command: ^HeadlessParsedCommand,
	withUser: bool,
) -> (
	roomID, userID: int,
	ok: bool,
) {
	roomOK, userOK := false, true
	roomID, roomOK = headlessParseNumber(command.args[0])
	if withUser {
		userID, userOK = headlessParseNumber(command.args[1])
		userOK = userOK && userID > 0
	}
	if !roomOK || roomID == 0 || !userOK {
		usage := strings.concatenate({"usage: ", command.command.usage})
		defer delete(usage)
		headlessWriteError(harness, command.name, usage)
		return 0, 0, false
	}
	return roomID, userID, true
}

headlessCommandRoomMembers :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	roomID, _, ok := headlessRoomMemberArgs(harness, command, false)
	if !ok {
		return
	}
	state := &harness.state
	errorMessage := State_fetchRoomMembers(state, state.selected_server_id, roomID)
	headlessWriteRoomMemberRequest(harness, command, errorMessage, roomID, 0)
}

headlessCommandRoomAdd :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	roomID, userID, ok := headlessRoomMemberArgs(harness, command, true)
	if !ok {
		return
	}
	state := &harness.state
	errorMessage := State_addRoomMember(
		state,
		state.selected_server_id,
		roomID,
		userID,
		checkRights = false,
	)
	headlessWriteRoomMemberRequest(harness, command, errorMessage, roomID, userID)
}

headlessCommandRoomRemove :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	roomID, userID, ok := headlessRoomMemberArgs(harness, command, true)
	if !ok {
		return
	}
	state := &harness.state
	errorMessage := State_removeRoomMember(
		state,
		state.selected_server_id,
		roomID,
		userID,
		checkRights = false,
	)
	headlessWriteRoomMemberRequest(harness, command, errorMessage, roomID, userID)
}

headlessCommandRoomLeave :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	roomID, _, ok := headlessRoomMemberArgs(harness, command, false)
	if !ok {
		return
	}
	state := &harness.state
	errorMessage := State_leaveRoom(state, state.selected_server_id, roomID, checkRights = false)
	headlessWriteRoomMemberRequest(harness, command, errorMessage, roomID, 0)
}

headlessCommandAdminRooms :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	state := &harness.state
	serverID := state.selected_server_id
	// Sent whatever the admin flag says, so a non-admin sees the server refuse.
	cache := State_serverRoomCache(state, serverID)
	cache.adminRoomsLoading = false
	errorMessage := State_sendAdminRoomList(state, serverID)
	headlessWriteRoomMemberRequest(harness, command, errorMessage, 0, 0)
}

headlessCommandRoomDelete :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	roomID, roomOK := headlessParseNumber(command.args[0])
	if !roomOK || roomID == 0 {
		headlessWriteError(harness, command.name, "usage: room-delete ROOM_ID")
		return
	}
	state := &harness.state
	errorMessage := State_sendDeleteRoom(state, state.selected_server_id, roomID)
	headlessWriteRoomRequest(harness, command, errorMessage, roomID, "", "")
}

// Marks a room or conversation read through State_markConversationRead, the action behind the
// GUI's automatic marking. The harness never marks anything read by itself (it has no window
// focus), so this is the only way an agent clears a badge.
headlessCommandRead :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	usage :: "usage: read room|dm ID [MESSAGE_ID]"
	kind: common.ReadMarkerKind
	switch command.args[0] {
	case "room":
		kind = .Room
	case "dm":
		kind = .Direct
	case:
		headlessWriteError(harness, command.name, usage)
		return
	}
	conversationID, idOK := headlessParseNumber(command.args[1])
	messageID, messageOK := 0, true
	if command.argCount > 2 {
		messageID, messageOK = headlessParseNumber(command.args[2])
	}
	if !idOK || conversationID == 0 || !messageOK || (command.argCount > 2 && messageID == 0) {
		headlessWriteError(harness, command.name, usage)
		return
	}
	state := &harness.state
	serverID := state.selected_server_id
	if command.argCount <= 2 {
		messageID = State_newestLoadedMessageID(state, kind, serverID, conversationID)
		if messageID == 0 {
			headlessWriteError(
				harness,
				command.name,
				"nothing loaded in that conversation; fetch its history first or pass MESSAGE_ID",
			)
			return
		}
	}
	State_clearChatStatus(state)
	if !State_markConversationRead(
		state,
		kind,
		serverID,
		conversationID,
		messageID,
		time.tick_now(),
	) {
		headlessWriteError(harness, command.name, state.chat_status_message)
		return
	}
	headlessWriteJSON(
		harness,
		HeadlessReadJSON {
			ok = true,
			cmd = command.name,
			serverID = serverID,
			kind = HEADLESS_READ_MARKER_KIND_NAMES[kind],
			conversationID = conversationID,
			messageID = messageID,
		},
	)
}

headlessCommandWait :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	kind, kindOK := headlessEventKindFromName(command.args[0])
	if !kindOK {
		headlessWriteError(harness, command.name, "unknown event kind; send `help` for the list")
		return
	}
	timeoutMS, timeoutOK := HEADLESS_DEFAULT_WAIT_MS, true
	if command.argCount > 1 {
		timeoutMS, timeoutOK = headlessParseNumber(command.args[1], HEADLESS_MAX_WAIT_MS)
	}
	if !timeoutOK {
		headlessWriteError(harness, command.name, "TIMEOUT_MS must be from 0 to 600000")
		return
	}
	timeout := time.Duration(timeoutMS) * time.Millisecond
	start := time.tick_now()
	for {
		headlessDrainEvents(harness)
		if harness.pendingEvents[kind] > 0 {
			harness.pendingEvents[kind] -= 1
			waited := int(time.duration_milliseconds(time.tick_since(start)))
			headlessWriteJSON(
				harness,
				HeadlessWaitJSON {
					ok = true,
					cmd = command.name,
					event = HEADLESS_EVENT_NAMES[kind],
					waitedMS = waited,
				},
			)
			return
		}
		if time.tick_since(start) >= timeout {
			message := fmt.tprintf(
				"timed out after %d ms waiting for %s",
				timeoutMS,
				HEADLESS_EVENT_NAMES[kind],
			)
			headlessWriteError(harness, command.name, message)
			return
		}
		time.sleep(HEADLESS_POLL_INTERVAL)
	}
}

headlessCommandSleep :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	durationMS, ok := headlessParseNumber(command.args[0], HEADLESS_MAX_WAIT_MS)
	if !ok {
		headlessWriteError(harness, command.name, "MS must be from 0 to 600000")
		return
	}
	headlessPumpFor(harness, time.Duration(durationMS) * time.Millisecond)
	headlessWriteJSON(harness, HeadlessSleepJSON{ok = true, cmd = command.name, ms = durationMS})
}

headlessCommandHelp :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	commands := make([]HeadlessHelpCommandJSON, len(harness.commands))
	defer delete(commands)
	for entry, index in harness.commands {
		commands[index] = {
			usage   = entry.usage,
			summary = entry.summary,
		}
	}
	events: [len(HeadlessEventKind)]string
	for name, kind in HEADLESS_EVENT_NAMES {
		events[int(kind)] = name
	}
	headlessWriteJSON(
		harness,
		HeadlessHelpJSON{ok = true, cmd = command.name, commands = commands, events = events[:]},
	)
}

headlessCommandQuit :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	headlessWriteJSON(harness, HeadlessOKJSON{ok = true, cmd = command.name})
	harness.running = false
}

// ── Stdin ─────────────────────────────────────────────────────────

// Lines read from stdin by a background thread, so a blocking read never stops the main loop
// from draining network events.
HeadlessInput :: struct {
	mutex:  sync.Mutex,
	lines:  [dynamic]string, // Owned
	closed: bool, // stdin reached EOF or failed
}

// Takes ownership of line.
HeadlessInput_push :: proc(input: ^HeadlessInput, line: string) {
	sync.mutex_lock(&input.mutex)
	defer sync.mutex_unlock(&input.mutex)
	append(&input.lines, line)
}

HeadlessInput_close :: proc(input: ^HeadlessInput) {
	sync.mutex_lock(&input.mutex)
	defer sync.mutex_unlock(&input.mutex)
	input.closed = true
}

// Moves the oldest line to the caller, who then owns it. closed is true only once every
// queued line has been taken and stdin is at EOF.
HeadlessInput_pop :: proc(input: ^HeadlessInput) -> (line: string, ok: bool, closed: bool) {
	sync.mutex_lock(&input.mutex)
	defer sync.mutex_unlock(&input.mutex)
	if len(input.lines) > 0 {
		line = input.lines[0]
		ordered_remove(&input.lines, 0)
		return line, true, false
	}
	return "", false, input.closed
}

HeadlessInput_deinit :: proc(input: ^HeadlessInput) {
	for line in input.lines {
		delete(line)
	}
	delete(input.lines)
	input.lines = nil
}

@(private = "file")
headlessReadStdin :: proc(data: rawptr) {
	input := (^HeadlessInput)(data)
	reader: bufio.Reader
	bufio.reader_init(&reader, os.to_stream(os.stdin))
	defer bufio.reader_destroy(&reader)
	for {
		line, err := bufio.reader_read_string(&reader, '\n')
		if len(line) > 0 {
			HeadlessInput_push(input, strings.clone(strings.trim_right(line, "\r\n")))
		}
		delete(line)
		if err != nil {
			break
		}
	}
	HeadlessInput_close(input)
}

// ── Entry point ───────────────────────────────────────────────────

// Runs the harness until `quit` or EOF on stdin. Returns the process exit code.
headlessMain :: proc(args: []string) -> int {
	// stdout carries only JSON lines. The shared client code prints diagnostics with
	// fmt.println, so route os.stdout to stderr and keep the real stdout for the protocol.
	jsonOut := os.stdout
	os.stdout = os.stderr
	defer os.stdout = jsonOut

	options, optionsErr := headlessParseOptions(args)
	if len(optionsErr) > 0 {
		fmt.eprintln("[Error]", optionsErr)
		fmt.eprintln(HEADLESS_USAGE)
		return HEADLESS_EXIT_ERROR
	}
	if len(options.configDir) > 0 && !headlessUseConfigDir(options.configDir) {
		return HEADLESS_EXIT_ERROR
	}

	config := loadConfig()
	defer Config_deinit(&config)
	if len(config.private_key) == 0 || len(config.public_key) == 0 {
		fmt.eprintln("[Error] Could not load or create the client config and identity key")
		return HEADLESS_EXIT_ERROR
	}
	if headlessApplyOptions(&config, options) {
		saveConfig(config)
	}
	// --register applies to this run only; it is not saved to the profile.
	if options.register {
		for &server in config.servers {
			server.use_invite_code = true
		}
	}
	if len(config.display_name) == 0 {
		fmt.eprintln("[Error] The profile has no display name; pass --name NAME")
		return HEADLESS_EXIT_ERROR
	}

	keyStoreDir := keyStoreDefaultDir()
	defer delete(keyStoreDir)
	harness := HeadlessHarness {
		out         = os.to_writer(jsonOut),
		commands    = HEADLESS_COMMANDS[:],
		running     = true,
		keyStoreDir = keyStoreDir,
		autoInviteCode = options.inviteCode,
		autoReason  = options.reason,
	}
	defer HeadlessHarness_deinit(&harness)
	connectTimeout := time.Duration(options.connectTimeoutMS) * time.Millisecond
	if !headlessConnectAndWait(&harness, config, connectTimeout) {
		return HEADLESS_EXIT_CONNECT_FAILED
	}

	// The reader thread can stay blocked in read() after `quit`, so input is never freed: the
	// process exits right after this returns.
	input := new(HeadlessInput)
	readerThread := thread.create_and_start_with_data(
		input,
		headlessReadStdin,
		init_context = context,
	)
	if readerThread == nil {
		fmt.eprintln("[Error] Failed to start the stdin reader thread")
		return HEADLESS_EXIT_ERROR
	}

	for harness.running {
		headlessDrainEvents(&harness)
		line, hasLine, closed := HeadlessInput_pop(input)
		if hasLine {
			headlessHandleLine(&harness, line)
			delete(line)
		} else if closed {
			fmt.eprintln("[Info] stdin closed; exiting")
			harness.running = false
		} else {
			time.sleep(HEADLESS_POLL_INTERVAL)
		}
		free_all(context.temp_allocator)
	}
	return HEADLESS_EXIT_OK
}

// ── Encrypted rooms (protocol 18) ────────────────────────────────

@(private = "file")
headlessRoomLogStatusName :: proc(status: RoomLogStatus) -> string {
	switch status {
	case .Unknown:
		return "unknown"
	case .Loading:
		return "loading"
	case .Verified:
		return "verified"
	case .Failed:
		return "failed"
	}
	return "unknown"
}

headlessWriteRoomLogEvent :: proc(harness: ^HeadlessHarness, serverID, roomID: int) {
	state := &harness.state
	value := HeadlessRoomLogJSON {
		event    = HEADLESS_EVENT_NAMES[.RoomLog],
		serverID = serverID,
		roomID   = roomID,
		status   = "unknown",
	}
	members := make([dynamic]int, 0, context.temp_allocator)
	managers := make([dynamic]int, 0, context.temp_allocator)
	events := make([dynamic]string, 0, context.temp_allocator)
	headHash := ""
	if log := State_findRoomLog(state, serverID, roomID); log != nil {
		value.status = headlessRoomLogStatusName(log.status)
		value.serverLogVersion = log.serverHead
		if log.status == .Failed {
			value.logError = fmt.tprintf("%v", log.failure)
			value.warning = ROOM_LOG_CHANGED_WARNING
		}
		if log.status == .Verified {
			value.logVersion = log.state.version
			value.access = int(log.state.access)
			value.historyVisibility = int(log.state.historyVisibility)
			hash := log.state.headHash
			if log.state.version > 0 {
				headHash = common.encodeBytesToHex(hash[:])
			}
			for userID in log.state.members {
				append(&members, userID)
			}
			for userID in log.state.managers {
				append(&managers, userID)
			}
			slice.sort(members[:])
			slice.sort(managers[:])
		}
		for line in log.events {
			append(&events, State_roomLogEventText(state, serverID, line))
		}
	}
	defer delete(headHash)
	value.headHash = headHash
	value.members = members[:]
	value.managers = managers[:]
	value.events = events[:]
	headlessWriteJSON(harness, value)
	headlessRecordEvent(harness, .RoomLog)
}

// The rooms whose log changed since the last report, after an event or a command.
headlessWriteRoomLogNotes :: proc(harness: ^HeadlessHarness) {
	state := &harness.state
	for index := 0; index < len(state.roomLogNotes); index += 1 {
		note := state.roomLogNotes[index]
		log := State_findRoomLog(state, note.serverID, note.roomID)
		// A whole-log fetch reports once it is replayed.
		if log != nil && log.status == .Loading {
			continue
		}
		headlessWriteRoomLogEvent(harness, note.serverID, note.roomID)
	}
	for index := len(state.roomLogNotes) - 1; index >= 0; index -= 1 {
		note := state.roomLogNotes[index]
		log := State_findRoomLog(state, note.serverID, note.roomID)
		if log == nil || log.status != .Loading {
			ordered_remove(&state.roomLogNotes, index)
		}
	}
}

headlessCommandRoomLog :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	roomID, ok := headlessParseNumber(command.args[0])
	if !ok || roomID <= 0 {
		headlessWriteError(harness, command.name, "usage: room-log ROOM_ID")
		return
	}
	state := &harness.state
	serverID := state.selected_server_id
	errorMessage := State_requestRoomLog(state, serverID, roomID)
	if len(errorMessage) > 0 {
		headlessWriteError(harness, command.name, errorMessage)
		return
	}
	headlessWriteRoomLogEvent(harness, serverID, roomID)
	headlessWriteRoomLogRequest(harness, command, "", roomID, 0)
}

headlessCommandRoomManager :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	roomID, roomOK := headlessParseNumber(command.args[0])
	userID, userOK := headlessParseNumber(command.args[1])
	on := command.args[2] == "on"
	if !roomOK || !userOK || roomID <= 0 || userID <= 0 || (!on && command.args[2] != "off") {
		headlessWriteError(harness, command.name, "usage: room-manager ROOM_ID USER_ID on|off")
		return
	}
	state := &harness.state
	errorMessage := State_roomLogMemberChange(
		state,
		state.selected_server_id,
		roomID,
		on ? .AddManager : .RemoveManager,
		userID,
		checkRights = false,
	)
	headlessWriteRoomLogRequest(harness, command, errorMessage, roomID, userID)
}

headlessCommandRoomAccess :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	roomID, roomOK := headlessParseNumber(command.args[0])
	access: common.RoomLogAccess
	switch command.args[1] {
	case "member-invite":
		access = .MemberInvite
	case "admin-invite":
		access = .AdminInvite
	case:
		roomOK = false
	}
	if !roomOK || roomID <= 0 {
		headlessWriteError(
			harness,
			command.name,
			"usage: room-access ROOM_ID member-invite|admin-invite",
		)
		return
	}
	state := &harness.state
	errorMessage := State_roomLogMemberChange(
		state,
		state.selected_server_id,
		roomID,
		.SetAccess,
		0,
		checkRights = false,
		access = access,
	)
	headlessWriteRoomLogRequest(harness, command, errorMessage, roomID, 0)
}

@(private = "file")
headlessWriteRoomLogRequest :: proc(
	harness: ^HeadlessHarness,
	command: ^HeadlessParsedCommand,
	errorMessage: string,
	roomID, userID: int,
) {
	if len(errorMessage) > 0 {
		headlessWriteError(harness, command.name, errorMessage)
		return
	}
	headlessWriteJSON(
		harness,
		HeadlessRoomMemberRequestJSON {
			ok = true,
			cmd = command.name,
			serverID = harness.state.selected_server_id,
			roomID = roomID,
			userID = userID,
		},
	)
}

headlessCommandRoomLogEntry :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	usage := "usage: " + "room-log-entry ROOM_ID add|remove|add-manager|remove-manager|leave " +
		"USER_ID [unsigned]"
	roomID, roomOK := headlessParseNumber(command.args[0])
	userID, userOK := headlessParseNumber(command.args[2])
	action: common.RoomLogAction
	switch command.args[1] {
	case "add":
		action = .Add
	case "remove":
		action = .Remove
	case "add-manager":
		action = .AddManager
	case "remove-manager":
		action = .RemoveManager
	case "leave":
		action = .Leave
	case:
		roomOK = false
	}
	unsigned := command.argCount > 3 && command.args[3] == "unsigned"
	if !roomOK || !userOK || roomID <= 0 || userID <= 0 ||
	   (command.argCount > 3 && !unsigned) {
		headlessWriteError(harness, command.name, usage)
		return
	}
	state := &harness.state
	serverID := state.selected_server_id
	entry, version, errorMessage := State_roomLogEncodeEntry(
		state,
		serverID,
		roomID,
		action,
		userID,
		!unsigned,
	)
	if len(errorMessage) > 0 {
		headlessWriteError(harness, command.name, errorMessage)
		return
	}
	defer delete(entry)
	headlessWriteJSON(
		harness,
		HeadlessRoomLogEntryJSON {
			ok = true,
			cmd = command.name,
			serverID = serverID,
			roomID = roomID,
			version = version,
			entry = entry,
		},
	)
}
