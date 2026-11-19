package client

import "../common"
import "core:fmt"
import "core:slice"
import "core:strings"

// View models are pure snapshots of State that the immediate-mode view draws from. Keeping
// them free of SDL lets tests check what the UI would show without opening a window.

TranscriptLine :: struct {
	messageID:    int,
	senderUserID: int,
	senderLabel:  string, // Borrowed from the room cache, or allocated with the view allocator
	isSelf:       bool,
	content:      string, // Borrowed from the room cache
	// Direct messages (protocol 17): the encryption badge drawn at the right of the message
	// ("🔒", "Unencrypted", …; empty for none) and its tone, and whether content is a
	// placeholder ("This message could not be decrypted") drawn muted.
	badge:        string,
	badgeTone:    E2EEIndicatorTone,
	placeholder:  bool,
	// Attachments (F4): a card per checked file (buildFileCardViews), or filesChanged when the
	// server's list is not the sender's ("This message's attachments were changed on the
	// server", and no cards). A message with files may have no text: content is then empty and
	// only the cards are drawn.
	cards:        []FileCardView,
	filesChanged: bool,
	// Protocol 30 (#76 M3): the "(edited)" marker after the text (messageEditMarker; empty
	// when never edited), drawn in the warning colour when the latest edit failed, and whether
	// the line is a tombstone ("Message deleted" / "Removed by the server", muted italic).
	marker:       string,
	markerFailed: bool,
	tombstone:    bool,
}

RoomView :: struct {
	hasSelectedRoom:  bool,
	// Admins get an "Edit room" control in the room header.
	canEditRoom:      bool,
	// False for a voice-only room (protocol 14): no composer, voiceOnlyNote instead.
	allowsChat:       bool,
	voiceOnlyNote:    string,
	// Protocol 18: an encrypted room, and whether its member log failed.
	encrypted:        bool,
	logFailed:        bool,
	hasOlder:         bool,
	isLoadingHistory: bool,
	lines:            []TranscriptLine,
	status:           string, // Borrowed from State
}

ROOM_VOICE_ONLY_NOTE :: "This room is voice only"

// Builds the selected room's view without creating caches. Lines borrow message content from
// the room cache, so the result is only valid until State next changes.
buildRoomView :: proc(state: ^State, allocator := context.temp_allocator) -> (view: RoomView) {
	view.status = state.chat_status_message
	view.allowsChat = true
	serverCacheIndex := State_serverRoomCacheIndex(state^, state.selected_server_id)
	if serverCacheIndex < 0 {
		return
	}
	serverCache := &state.server_room_caches[serverCacheIndex]
	view.hasSelectedRoom = ServerRoomCache_roomIsJoined(serverCache, state.selected_channel_id)
	// Protocol 24: ManageRooms, or the room's EditRoom.
	view.canEditRoom =
		view.hasSelectedRoom &&
		State_canEditRoom(state, state.selected_server_id, state.selected_channel_id)
	view.allowsChat =
		!view.hasSelectedRoom ||
		State_roomAllowsChat(state, state.selected_server_id, state.selected_channel_id)
	if !view.allowsChat {
		view.voiceOnlyNote = ROOM_VOICE_ONLY_NOTE
	} else if view.hasSelectedRoom &&
	   !State_hasRoomPermission(
		   state,
		   state.selected_server_id,
		   state.selected_channel_id,
		   .SendMessages,
	   ) {
		// Protocol 24: a read-only room for this account.
		view.allowsChat = false
		view.voiceOnlyNote = ROOM_SEND_NOT_PERMITTED_NOTE
	}
	// Protocol 18: an encrypted room shows its verified member list changes as event lines,
	// placed among the messages by time. Protocol 19: its messages are sealed; the composer
	// gives way to a note when this account cannot send there (a failed log, a log not set up,
	// not a member of the log).
	logLines: []TranscriptLine
	logTimes: []i64
	serverID := state.selected_server_id
	if view.hasSelectedRoom && State_roomIsEncrypted(state, serverID, state.selected_channel_id) {
		view.encrypted = true
		log := State_findRoomLog(state, serverID, state.selected_channel_id)
		if note := State_roomChainsComposerNote(state, serverID, state.selected_channel_id);
		   len(note) > 0 && view.allowsChat {
			view.allowsChat = false
			view.voiceOnlyNote = note
		}
		if log != nil && log.status == .Failed {
			view.logFailed = true
		}
		if log != nil {
			logLines = make([]TranscriptLine, len(log.events), allocator)
			logTimes = make([]i64, len(log.events), allocator)
			for line, index in log.events {
				logLines[index] = TranscriptLine {
					messageID   = -line.version,
					senderLabel = "Member list",
					content     = strings.clone(
						State_roomLogEventText(state, serverID, line),
						allocator,
					),
					placeholder = true,
				}
				logTimes[index] = i64(line.createdAt)
			}
		}
	}
	view.lines = logLines
	roomCacheIndex := ServerRoomCache_roomCacheIndex(serverCache^, state.selected_channel_id)
	if roomCacheIndex < 0 {
		return
	}
	roomCache := &serverCache.roomCaches[roomCacheIndex]
	view.hasOlder = roomCache.hasOlder
	view.isLoadingHistory = roomCache.isLoadingHistory

	// The worker writes the transport's user ID, so read the UI thread's copy instead.
	selfUserID := State_selfUserID(state, serverID)

	lines := make([dynamic]TranscriptLine, 0, len(logLines) + len(roomCache.messages), allocator)
	nextLog := 0
	for message in roomCache.messages {
		// Member list changes made before this message come first.
		if seconds, ok := parseServerTimestampUnix(message.timestamp); ok {
			for nextLog < len(logLines) && logTimes[nextLog] <= seconds {
				append(&lines, logLines[nextLog])
				nextLog += 1
			}
		}
		// A message without its sender's valid signature leaves no line at all (#90).
		if !roomMessageShown(message.security) {
			continue
		}
		isSelf := selfUserID != 0 && message.senderId == selfUserID
		// A sender without a user row has no nickname; fall back to the user ID.
		senderLabel := "You"
		if !isSelf {
			senderLabel = message.senderNickname
			if len(senderLabel) == 0 {
				senderLabel = fmt.aprintf("User %d", message.senderId, allocator = allocator)
			}
		}
		text, placeholder, badge := roomMessageDisplay(state, serverID, message, allocator)
		line := TranscriptLine {
			messageID    = message.id,
			senderUserID = message.senderId,
			senderLabel  = senderLabel,
			isSelf       = isSelf,
			content      = text,
			badge        = badge,
			placeholder  = placeholder,
			tombstone    = message.deleted,
		}
		if !placeholder {
			line.marker, line.markerFailed = messageEditMarker(
				message.edit,
				message.editCount,
				message.deleted,
			)
		}
		if !placeholder {
			line.filesChanged = message.filesChanged
			line.cards = buildFileCardViews(
				state,
				serverID,
				.Room,
				state.selected_channel_id,
				message.id,
				message.files[:],
				allocator,
			)
		}
		append(&lines, line)
	}
	for nextLog < len(logLines) {
		append(&lines, logLines[nextLog])
		nextLog += 1
	}
	view.lines = lines[:]
	return
}

// One row of the selected server's sidebar, top to bottom: the channels, then the
// "Direct Messages" section (recent conversations), then the "Members" section (every other
// account, online first, then alphabetical).
SidebarRowKind :: enum u8 {
	SectionHeader,
	Channel,
	Conversation,
	Member,
	Placeholder, // A muted line such as "No conversations yet"
	// A user in the voice of the Channel row above it (voice_view_model.odin), indented.
	VoiceParticipant,
}

// A control drawn at the right of a section header.
SidebarRowAction :: enum u8 {
	None,
	NewRoom, // "+ New room" on the Channels header, for admins only
}

SidebarRow :: struct {
	kind:        SidebarRowKind,
	action:      SidebarRowAction,
	id:          int, // Room ID for Channel, peer user ID for Conversation and Member
	label:       string, // Borrowed from State, or allocated with the view allocator
	description: string, // Channel tooltip; borrowed
	selected:    bool,
	isOnline:    bool,
	// The server's unread count for a Channel or Conversation (read_state.odin), plus the live
	// messages counted since; the view shows "99+" from 100 on.
	unreadCount: int,
	// Channel: how many users are in the room's voice (0 hides the voice indicator).
	voiceUsers:  int,
	// VoiceParticipant: id is the user ID, roomID the room the row sits under.
	roomID:      int,
	voice:       VoiceParticipantRow,
	// Conversation and Member: this client's state for the account's encryption key
	// (e2ee_state.odin), shown by e2eeKeyIndicator.
	keyState:    E2EEKeyState,
	// Conversation: the newest message is plaintext that deserves the Unencrypted badge
	// (directPreviewUnencrypted), shown unless the key changed.
	previewUnencrypted: bool,
	// Conversation: what the newest message reads as (State_directPreviewText: its latest
	// version, or the tombstone's sentence), shown in the row's tooltip. #76 M3.
	preview:            string,
}

// Fallback label for an account the client has no nickname for.
userLabel :: proc(nickname: string, userID: int, allocator := context.temp_allocator) -> string {
	if len(nickname) > 0 {
		return nickname
	}
	return fmt.aprintf("User %d", userID, allocator = allocator)
}

// ASCII case-insensitive ordering, so "bob" and "Bob" sort together without allocating.
@(private = "file")
lessFolded :: proc(a, b: string) -> bool {
	for index in 0 ..< min(len(a), len(b)) {
		ca, cb := a[index], b[index]
		if ca >= 'A' && ca <= 'Z' {
			ca += 'a' - 'A'
		}
		if cb >= 'A' && cb <= 'Z' {
			cb += 'a' - 'A'
		}
		if ca != cb {
			return ca < cb
		}
	}
	return len(a) < len(b)
}

// Online members first, then alphabetical by nickname, then by ID for equal names.
memberLess :: proc(a, b: common.UserSummary) -> bool {
	if a.isOnline != b.isOnline {
		return a.isOnline
	}
	if a.nickname != b.nickname {
		if lessFolded(a.nickname, b.nickname) {
			return true
		}
		if lessFolded(b.nickname, a.nickname) {
			return false
		}
		return a.nickname < b.nickname
	}
	return a.id < b.id
}

// Every account in the directory except selfUserID, sorted for the Members section. The
// summaries borrow their nicknames from the directory.
sortedMembers :: proc(
	users: []common.UserSummary,
	selfUserID: int,
	allocator := context.temp_allocator,
) -> []common.UserSummary {
	members := make([dynamic]common.UserSummary, 0, len(users), allocator)
	for user in users {
		if user.id != selfUserID {
			append(&members, user)
		}
	}
	slice.sort_by(members[:], memberLess)
	return members[:]
}

// Builds the selected server's sidebar rows. Labels borrow from State, so the result is only
// valid until State next changes.
buildSidebarRows :: proc(
	state: ^State,
	allocator := context.temp_allocator,
) -> (
	rows: [dynamic]SidebarRow,
) {
	rows = make([dynamic]SidebarRow, allocator)
	serverID := state.selected_server_id
	connected := State_isServerConnected(state, serverID)
	inRoom := state.selected_dm_peer_id == 0

	// Only holders of ManageRooms (protocol 23) can create rooms; the server refuses everyone
	// else anyway.
	channelsAction :=
		State_hasPermission(state, serverID, .ManageRooms) ? SidebarRowAction.NewRoom : .None
	append(
		&rows,
		SidebarRow{kind = .SectionHeader, label = "Channels", action = channelsAction},
	)
	rooms: []common.RoomSummary
	roomsLoading := false
	if index := State_serverRoomCacheIndex(state^, serverID); index >= 0 {
		rooms = state.server_room_caches[index].rooms[:]
		roomsLoading = state.server_room_caches[index].roomsLoading
	}
	for room in rooms {
		participants := buildVoiceParticipantRows(state, serverID, room.id, allocator)
		append(
			&rows,
			SidebarRow {
				kind = .Channel,
				id = room.id,
				label = fmt.aprintf("# %s", room.name, allocator = allocator),
				description = room.description,
				selected = inRoom && room.id == state.selected_channel_id,
				unreadCount = room.unreadCount,
				voiceUsers = len(participants),
			},
		)
		// Rooms the user is not in voice of show their participants too.
		for participant in participants {
			append(
				&rows,
				SidebarRow {
					kind = .VoiceParticipant,
					id = participant.userID,
					roomID = room.id,
					label = participant.label,
					voice = participant,
				},
			)
		}
	}
	if len(rooms) == 0 {
		text := roomsLoading ? "Loading channels…" : "No channels"
		if !connected {
			text = "Waiting for the server…"
		}
		append(&rows, SidebarRow{kind = .Placeholder, label = text})
	}

	// No cache yet means nothing was requested yet: the server is not connected.
	cacheIndex := State_serverDirectCacheIndex(state^, serverID)
	if cacheIndex < 0 {
		waiting := connected ? "Loading…" : "Waiting for the server…"
		append(&rows, SidebarRow{kind = .SectionHeader, label = "Direct Messages"})
		append(&rows, SidebarRow{kind = .Placeholder, label = waiting})
		append(&rows, SidebarRow{kind = .SectionHeader, label = "Members"})
		append(&rows, SidebarRow{kind = .Placeholder, label = waiting})
		return
	}
	cache := &state.serverDirectCaches[cacheIndex]
	selfUserID := State_selfUserID(state, serverID)

	append(&rows, SidebarRow{kind = .SectionHeader, label = "Direct Messages"})
	conversationCount := 0
	for conversation in cache.conversations {
		if conversation.peerUserId == selfUserID {
			continue
		}
		peerUserID := conversation.peerUserId
		append(
			&rows,
			SidebarRow {
				kind = .Conversation,
				id = peerUserID,
				label = userLabel(
					ServerDirectCache_peerNickname(cache, peerUserID),
					peerUserID,
					allocator,
				),
				selected = state.selected_dm_peer_id == peerUserID,
				isOnline = ServerDirectCache_peerIsOnline(cache, peerUserID),
				unreadCount = conversation.unreadCount,
				keyState = State_e2eePeerKeyInfo(state, serverID, peerUserID).state,
				// A tombstone (#76) carries no text, so it is never "Unencrypted".
				previewUnencrypted = !conversation.lastDeleted &&
					directPreviewUnencrypted(
						conversation.security,
						len(conversation.lastEnvelope) > 0,
					),
				preview = State_directPreviewText(state, serverID, conversation, allocator),
			},
		)
		conversationCount += 1
	}
	if conversationCount == 0 {
		text := cache.conversationsLoading ? "Loading…" : "No conversations yet"
		append(&rows, SidebarRow{kind = .Placeholder, label = text})
	}

	append(&rows, SidebarRow{kind = .SectionHeader, label = "Members"})
	members := sortedMembers(cache.users[:], selfUserID, allocator)
	for member in members {
		append(
			&rows,
			SidebarRow {
				kind = .Member,
				id = member.id,
				label = userLabel(member.nickname, member.id, allocator),
				selected = state.selected_dm_peer_id == member.id,
				isOnline = member.isOnline,
				keyState = State_e2eePeerKeyInfo(state, serverID, member.id).state,
			},
		)
	}
	if len(members) == 0 {
		text := cache.usersLoading ? "Loading members…" : "No other members yet"
		append(&rows, SidebarRow{kind = .Placeholder, label = text})
	}
	return
}

DirectConversationView :: struct {
	hasPeer:          bool,
	peerUserID:       int,
	peerLabel:        string,
	peerOnline:       bool,
	// The header's second line: online state, and whether messages are end-to-end encrypted.
	subtitle:         string,
	hasOlder:         bool,
	isLoadingHistory: bool,
	lines:            []TranscriptLine,
	status:           string, // Borrowed from State
	composer:         DirectComposerView,
}

// Builds the open conversation's view without creating caches. Lines borrow from the cache,
// so the result is only valid until State next changes.
buildDirectConversationView :: proc(
	state: ^State,
	allocator := context.temp_allocator,
) -> (
	view: DirectConversationView,
) {
	view.status = state.chat_status_message
	peerUserID := state.selected_dm_peer_id
	if peerUserID == 0 {
		return
	}
	view.hasPeer = true
	view.peerUserID = peerUserID
	serverID := state.selected_server_id
	cacheIndex := State_serverDirectCacheIndex(state^, serverID)
	if cacheIndex < 0 {
		view.peerLabel = userLabel("", peerUserID, allocator)
		view.composer = buildDirectComposerView(
			state,
			serverID,
			peerUserID,
			view.peerLabel,
			allocator,
		)
		view.subtitle = "Offline"
		return
	}
	cache := &state.serverDirectCaches[cacheIndex]
	view.peerLabel = userLabel(
		ServerDirectCache_peerNickname(cache, peerUserID),
		peerUserID,
		allocator,
	)
	view.peerOnline = ServerDirectCache_peerIsOnline(cache, peerUserID)
	view.composer = buildDirectComposerView(
		state,
		serverID,
		peerUserID,
		view.peerLabel,
		allocator,
	)
	view.subtitle = view.peerOnline ? "Online" : "Offline"
	if view.composer.encrypted {
		view.subtitle = DIRECT_HEADER_OFFLINE_ENCRYPTED
		if view.peerOnline {
			view.subtitle = DIRECT_HEADER_ONLINE_ENCRYPTED
		}
	}
	cache = &state.serverDirectCaches[cacheIndex]
	conversationIndex := ServerDirectCache_conversationCacheIndex(cache^, peerUserID)
	if conversationIndex < 0 {
		return
	}
	conversation := &cache.caches[conversationIndex]
	view.hasOlder = conversation.hasOlder
	view.isLoadingHistory = conversation.isLoadingHistory

	selfUserID := State_selfUserID(state, serverID)
	// Messages that are not shown (#82) leave no line at all.
	lines := make([dynamic]TranscriptLine, 0, len(conversation.messages), allocator)
	for message in conversation.messages {
		if !directMessageShown(message.security) {
			continue
		}
		isSelf := selfUserID != 0 && message.senderId == selfUserID
		senderLabel := "You"
		if !isSelf {
			senderLabel = userLabel(message.senderNickname, message.senderId, allocator)
		}
		badge, tone := directMessageBadge(message.security, len(message.envelope) > 0)
		if message.deleted {
			// A tombstone is one muted line: no badge (D7).
			badge = ""
		}
		content, placeholder := directMessageText(message)
		line := TranscriptLine {
			messageID    = message.id,
			senderUserID = message.senderId,
			senderLabel  = senderLabel,
			isSelf       = isSelf,
			content      = content,
			badge        = badge,
			badgeTone    = tone,
			placeholder  = placeholder,
			tombstone    = message.deleted,
		}
		if !placeholder {
			line.marker, line.markerFailed = messageEditMarker(
				message.edit,
				message.editCount,
				message.deleted,
			)
		}
		if !placeholder {
			line.filesChanged = message.filesChanged
			line.cards = buildFileCardViews(
				state,
				serverID,
				.Direct,
				peerUserID,
				message.id,
				message.files[:],
				allocator,
			)
		}
		append(&lines, line)
	}
	view.lines = lines[:]
	return
}

// What the room form shows. Strings are static or borrowed from State.
RoomEditorView :: struct {
	visible:       bool,
	isCreate:      bool,
	title:         string, // "New room" or "Edit #name"
	submitLabel:   string, // "Create" or "Save"; "Creating…"/"Saving…" while waiting
	showDelete:    bool,
	deleteLabel:   string, // "Delete room", then "Confirm delete"
	// Set while a request is out; the buttons do nothing until the server answers.
	busy:          bool,
	// Shown above the buttons when editing #general (room 1), which is special only in that
	// the server recreates it on its next start when no rooms are left.
	generalNotice: string,
	// The type selector (protocol 14): the chosen type and what it means.
	roomType:      common.RoomType,
	typeNote:      string,
	// Edit to text-only of a room with people in its voice: they are removed.
	typeWarning:   string,
	// Access (protocol 15): the chosen mode and what it means, and what a change in an edit
	// does (everyone added, or nobody removed).
	access:        common.RoomAccess,
	accessNote:    string,
	accessWarning: string,
	// History for new members: chosen in Create (not for Public rooms, which always show the
	// whole history), shown in Edit.
	history:       common.RoomHistoryVisibility,
	historyNote:   string,
	historyLocked: bool,
	// Join this room (Create): the toggle's label; joinLocked for a Public room, which always
	// includes its creator.
	creatorJoins:  bool,
	joinLabel:     string,
	joinNote:      string,
	joinLocked:    bool,
	// Encrypt this room (protocol 18, Create): offered for invite modes, checked by default
	// (Q9); the managers (every admin the client sees, Q10, the creator always) with whether
	// each can be named yet (a pinned key) and why not. Edit: whether the room is encrypted,
	// which fixes its access here.
	showEncrypt:   bool,
	encrypted:     bool,
	encryptLabel:  string,
	encryptNote:   string,
	managers:      []RoomEditorManagerRow,
	encryptedRoom: bool,
	error:         string,
	// Protocol 24: a Role room's access roles (every role but admin, checked when chosen), and
	// whether this account may change the access at all (ManageRooms; the room's EditRoom
	// covers only the name, description and type). showPermissions offers the Permissions page
	// (Edit).
	showAccessRoles: bool,
	accessRoles:     []RoomEditorRoleRow,
	accessRolesNote: string,
	accessLocked:    bool,
	showPermissions: bool,
}

RoomEditorRoleRow :: struct {
	roleID:  int,
	label:   string, // Borrowed from State
	checked: bool,
}

RoomEditorManagerRow :: struct {
	userID:  int,
	label:   string, // In the view allocator
	checked: bool,
	locked:  bool, // The creator, always a manager
	ready:   bool, // A pinned key; otherwise note says why it cannot be named
	note:    string,
}

// The room types the form offers, in the selector's order.
ROOM_EDITOR_TYPES := [3]common.RoomType{.Chat, .Voice, .ChatAndVoice}

// What a room type means, for the form.
roomTypeNote :: proc(roomType: common.RoomType) -> string {
	#partial switch roomType {
	case .Chat:
		return "Messages only. The room has no voice and no Join voice button."
	case .Voice:
		return "Voice only. The room has no composer; its earlier messages stay readable."
	}
	return "Messages and voice."
}

ROOM_EDITOR_GENERAL_NOTICE ::
	"This is #general, the room every new account sees first. Deleting it is allowed; the " +
	"server creates a new #general on its next start only if no rooms are left."

// Builds the room form for the selected server, or a view with visible false when the form is
// closed or belongs to another server.
buildRoomEditorView :: proc(
	state: ^State,
	allocator := context.temp_allocator,
) -> (
	view: RoomEditorView,
) {
	if !State_roomEditorVisible(state) || state.roomEditor.mode == .Members {
		return
	}
	editor := &state.roomEditor
	view.visible = true
	view.isCreate = editor.mode == .Create
	view.busy = editor.pending != .None
	view.error = editor.error
	view.roomType = roomTypeShown(editor.roomType)
	view.typeNote = roomTypeNote(view.roomType)
	view.access = roomAccessShown(editor.access)
	view.accessNote = roomAccessNote(view.access)
	if view.access == .Role {
		view.showAccessRoles = true
		view.accessRoles = buildRoomEditorRoleRows(state, allocator)
		switch {
		case editor.mode == .Edit && !editor.accessRolesLoaded:
			view.accessRolesNote = "Loading the room's roles…"
		case len(view.accessRoles) == 0:
			view.accessRolesNote = "Create a role in Server settings → Admin → Roles first."
		case len(editor.accessRoleIDs) == 0:
			view.accessRolesNote = "Choose at least one role."
		}
	}
	view.history = common.roomEffectiveHistoryVisibility(view.access, editor.history)
	view.historyNote = roomHistoryNote(view.access, view.history)
	if view.isCreate {
		view.title = "New room"
		view.submitLabel = editor.pending == .Create ? "Creating…" : "Create"
		view.historyLocked = view.access == .Public
		view.joinLocked = view.access == .Public
		view.creatorJoins = editor.creatorJoins || view.joinLocked
		view.joinLabel = view.creatorJoins ? "Join this room: on" : "Join this room: off"
		switch {
		case view.joinLocked:
			view.joinNote = "A public room includes everyone, you too."
		case view.creatorJoins:
			view.joinNote = "You are a member and see its messages."
		case:
			view.joinNote =
				"You are not a member: you do not see its messages, but you can still add " +
				"and remove members and delete it from Server settings → Admin."
		}
		view.showEncrypt = view.access != .Public && view.access != .Role
		view.encrypted = editor.encrypted && view.showEncrypt
		view.encryptLabel = view.encrypted ? "Encrypt this room: on" : "Encrypt this room: off"
		switch {
		case view.access == .Role:
			view.encryptNote =
				"Role rooms are not encrypted: their members change with roles, which the " +
				"member list cannot sign."
		case !view.showEncrypt:
			view.encryptNote = "Public rooms are not encrypted: anyone can join them."
		case view.encrypted:
			view.encryptNote =
				"Messages are end-to-end encrypted. Managers sign who joins; the server cannot " +
				"add a reader. This cannot be turned off later."
		case:
			view.encryptNote = "The server can read this room's messages."
		}
		if view.encrypted {
			view.managers = buildRoomEditorManagerRows(state, allocator)
		}
		return
	}
	if room := State_knownRoom(state, editor.serverID, editor.roomID); room != nil {
		view.encryptedRoom = room.encrypted
	}
	view.historyLocked = true
	view.showPermissions = true
	view.accessLocked =
		view.encryptedRoom || !State_hasPermission(state, editor.serverID, .ManageRooms)
	view.title = "Edit room"
	room := State_knownRoom(state, editor.serverID, editor.roomID)
	if room != nil {
		view.title = fmt.aprintf("Edit #%s", room.name, allocator = allocator)
		current := roomAccessShown(room.access)
		switch {
		case view.access == current:
		case view.access == .Public:
			view.accessWarning = "Saving adds every account on the server to the room."
		case current == .Public:
			view.accessWarning =
				"Everyone in the room stays a member; new accounts no longer join it."
		}
	}
	view.submitLabel = editor.pending == .Save ? "Saving…" : "Save"
	// Protocol 24: deleting a room stays with ManageRooms.
	view.showDelete = State_hasPermission(state, editor.serverID, .ManageRooms)
	switch {
	case editor.pending == .Delete:
		view.deleteLabel = "Deleting…"
	case editor.confirmDelete:
		view.deleteLabel = "Confirm delete"
	case:
		view.deleteLabel = "Delete room"
	}
	if editor.roomID == common.GENERAL_ROOM_ID {
		view.generalNotice = ROOM_EDITOR_GENERAL_NOTICE
	}
	inVoice := len(State_voiceRoomParticipants(state, editor.serverID, editor.roomID))
	if !common.roomTypeAllowsVoice(view.roomType) && inVoice > 0 {
		view.typeWarning = fmt.aprintf(
			"%d %s in this room's voice will be removed from it when you save.",
			inVoice,
			inVoice == 1 ? "person" : "people",
			allocator = allocator,
		)
	}
	return
}

// A Role room's access role choices (protocol 24): every role but the built-in admin role.
buildRoomEditorRoleRows :: proc(
	state: ^State,
	allocator := context.temp_allocator,
) -> []RoomEditorRoleRow {
	editor := &state.roomEditor
	rows := make([dynamic]RoomEditorRoleRow, 0, allocator)
	for role in State_roles(state, editor.serverID) {
		if role.builtin {
			continue
		}
		append(
			&rows,
			RoomEditorRoleRow {
				roleID = role.id,
				label = role.name,
				checked = slice.contains(editor.accessRoleIDs[:], role.id),
			},
		)
	}
	return rows[:]
}

// The create form's managers (protocol 18): every admin the client sees, this account first.
buildRoomEditorManagerRows :: proc(
	state: ^State,
	allocator := context.temp_allocator,
) -> []RoomEditorManagerRow {
	editor := &state.roomEditor
	selfUserID := State_selfUserID(state, editor.serverID)
	candidates := State_roomLogAdminCandidates(state, editor.serverID)
	rows := make([]RoomEditorManagerRow, len(candidates), allocator)
	for userID, index in candidates {
		name := State_roomLogUserName(state, editor.serverID, userID)
		row := RoomEditorManagerRow {
			userID = userID,
			locked = userID == selfUserID,
			ready  = State_roomLogManagerReady(state, editor.serverID, userID),
		}
		row.label = strings.clone(name, allocator)
		if row.locked {
			row.label = fmt.aprintf("%s (you)", name, allocator = allocator)
		}
		row.checked = true
		for unchecked in editor.uncheckedManagers {
			if unchecked == userID {
				row.checked = false
			}
		}
		if !row.ready {
			info := State_e2eePeerKeyInfo(state, editor.serverID, userID)
			row.note = info.state == .Unknown ? "Fetching key…" : "No usable key"
			row.checked = false
		}
		rows[index] = row
	}
	return rows
}
