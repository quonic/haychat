package client

import "../common"
import "core:fmt"
import "core:slice"

// View models are pure snapshots of State that the immediate-mode view draws from. Keeping
// them free of SDL lets tests check what the UI would show without opening a window.

TranscriptLine :: struct {
	messageID:   int,
	senderLabel: string, // Borrowed from the room cache, or allocated with the view allocator
	isSelf:      bool,
	content:     string, // Borrowed from the room cache
}

RoomView :: struct {
	hasSelectedRoom:  bool,
	// Admins get an "Edit room" control in the room header.
	canEditRoom:      bool,
	hasOlder:         bool,
	isLoadingHistory: bool,
	lines:            []TranscriptLine,
	status:           string, // Borrowed from State
}

// Builds the selected room's view without creating caches. Lines borrow message content from
// the room cache, so the result is only valid until State next changes.
buildRoomView :: proc(state: ^State, allocator := context.temp_allocator) -> (view: RoomView) {
	view.status = state.chat_status_message
	serverCacheIndex := State_serverRoomCacheIndex(state^, state.selected_server_id)
	if serverCacheIndex < 0 {
		return
	}
	serverCache := &state.server_room_caches[serverCacheIndex]
	view.hasSelectedRoom = ServerRoomCache_roomIsJoined(serverCache, state.selected_channel_id)
	view.canEditRoom =
		view.hasSelectedRoom && State_isServerAdmin(state, state.selected_server_id)
	roomCacheIndex := ServerRoomCache_roomCacheIndex(serverCache^, state.selected_channel_id)
	if roomCacheIndex < 0 {
		return
	}
	roomCache := &serverCache.roomCaches[roomCacheIndex]
	view.hasOlder = roomCache.hasOlder
	view.isLoadingHistory = roomCache.isLoadingHistory

	// The worker writes the transport's user ID, so read the UI thread's copy instead.
	selfUserID := State_selfUserID(state, state.selected_server_id)

	lines := make([]TranscriptLine, len(roomCache.messages), allocator)
	for message, index in roomCache.messages {
		isSelf := selfUserID != 0 && message.senderId == selfUserID
		// A sender without a user row has no nickname; fall back to the user ID.
		senderLabel := "You"
		if !isSelf {
			senderLabel = message.senderNickname
			if len(senderLabel) == 0 {
				senderLabel = fmt.aprintf("User %d", message.senderId, allocator = allocator)
			}
		}
		lines[index] = TranscriptLine {
			messageID   = message.id,
			senderLabel = senderLabel,
			isSelf      = isSelf,
			content     = message.content,
		}
	}
	view.lines = lines
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

	// Only an admin can create rooms; the server refuses everyone else anyway.
	channelsAction := State_isServerAdmin(state, serverID) ? SidebarRowAction.NewRoom : .None
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
		append(
			&rows,
			SidebarRow {
				kind = .Channel,
				id = room.id,
				label = fmt.aprintf("# %s", room.name, allocator = allocator),
				description = room.description,
				selected = inRoom && room.id == state.selected_channel_id,
				unreadCount = room.unreadCount,
			},
		)
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
	hasOlder:         bool,
	isLoadingHistory: bool,
	lines:            []TranscriptLine,
	status:           string, // Borrowed from State
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
		return
	}
	cache := &state.serverDirectCaches[cacheIndex]
	view.peerLabel = userLabel(
		ServerDirectCache_peerNickname(cache, peerUserID),
		peerUserID,
		allocator,
	)
	view.peerOnline = ServerDirectCache_peerIsOnline(cache, peerUserID)
	conversationIndex := ServerDirectCache_conversationCacheIndex(cache^, peerUserID)
	if conversationIndex < 0 {
		return
	}
	conversation := &cache.caches[conversationIndex]
	view.hasOlder = conversation.hasOlder
	view.isLoadingHistory = conversation.isLoadingHistory

	selfUserID := State_selfUserID(state, serverID)
	lines := make([]TranscriptLine, len(conversation.messages), allocator)
	for message, index in conversation.messages {
		isSelf := selfUserID != 0 && message.senderId == selfUserID
		senderLabel := "You"
		if !isSelf {
			senderLabel = userLabel(message.senderNickname, message.senderId, allocator)
		}
		lines[index] = TranscriptLine {
			messageID   = message.id,
			senderLabel = senderLabel,
			isSelf      = isSelf,
			content     = message.content,
		}
	}
	view.lines = lines
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
	error:         string,
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
	if !State_roomEditorVisible(state) {
		return
	}
	editor := &state.roomEditor
	view.visible = true
	view.isCreate = editor.mode == .Create
	view.busy = editor.pending != .None
	view.error = editor.error
	if view.isCreate {
		view.title = "New room"
		view.submitLabel = editor.pending == .Create ? "Creating…" : "Create"
		return
	}
	view.title = "Edit room"
	if index := State_serverRoomCacheIndex(state^, editor.serverID); index >= 0 {
		for room in state.server_room_caches[index].rooms {
			if room.id == editor.roomID {
				view.title = fmt.aprintf("Edit #%s", room.name, allocator = allocator)
				break
			}
		}
	}
	view.submitLabel = editor.pending == .Save ? "Saving…" : "Save"
	view.showDelete = true
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
	return
}
