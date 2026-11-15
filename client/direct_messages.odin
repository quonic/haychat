package client

import "../common"
import "core:strings"

// Direct messages, the user directory, and presence, per configured server.
//
// The server is the source of truth for all of it. A sent message is never added locally: the
// server echoes every stored message to every session of both users (the sender's included),
// and that echo is what lands in the cache. Peer user IDs are only unique within one server,
// so every cache is keyed by (serverID, peerUserID), like room caches are keyed by
// (serverID, roomID).

DirectMessageSendBridge :: proc(
	transport: ^ClientServerTransport,
	recipientUserID: int,
	content: string,
) -> bool

// Tests swap this to observe sends without a live session.
directMessageSendBridge: DirectMessageSendBridge = ClientServerTransport_sendDirectMessage

// One conversation with one peer on one server.
DirectConversationCache :: struct {
	peerUserID:           int,
	messages:             [dynamic]common.StoredDirectMessage, // Owned, ordered by ID
	draft:                [dynamic]u8, // Client-local, edited in place by the composer
	initialHistoryLoaded: bool,
	isLoadingHistory:     bool,
	oldestMessageID:      int,
	hasOlder:             bool,
	// The conversation's last mark-read (read_state.odin). Its marker and unread count are
	// the server's and live in the conversation's DirectConversationSummary.
	readSend:             ReadMarkerSendState,
}

// Everything direct-message related for one server. Every string and array is owned.
ServerDirectCache :: struct {
	serverID:             int,
	// Every account on the server, the signed-in user included, in the server's order (by
	// nickname). Presence events update isOnline, and the nickname after a rename, in place.
	users:                [dynamic]common.UserSummary,
	usersLoaded:          bool,
	usersLoading:         bool,
	// Most recent first. The server's list is replaced on every fetch; a live message moves
	// (or adds) its conversation to the top.
	conversations:        [dynamic]common.DirectConversationSummary,
	conversationsLoaded:  bool,
	conversationsLoading: bool,
	caches:               [dynamic]DirectConversationCache,
}

DirectConversationCache_deinit :: proc(cache: ^DirectConversationCache) {
	StoredDirectMessages_deinit(&cache.messages)
	delete(cache.draft)
	cache^ = {}
}

ServerDirectCache_deinit :: proc(cache: ^ServerDirectCache) {
	UserSummaries_deinit(&cache.users)
	DirectConversationSummaries_deinit(&cache.conversations)
	for index in 0 ..< len(cache.caches) {
		DirectConversationCache_deinit(&cache.caches[index])
	}
	delete(cache.caches)
	cache^ = {}
}

State_serverDirectCacheIndex :: proc(state: State, serverID: int) -> int {
	for index in 0 ..< len(state.serverDirectCaches) {
		if state.serverDirectCaches[index].serverID == serverID {
			return index
		}
	}
	return -1
}

// Returns the server's direct-message cache, creating it. The pointer is valid until the next
// server cache is added or removed.
State_serverDirectCache :: proc(state: ^State, serverID: int) -> ^ServerDirectCache {
	if index := State_serverDirectCacheIndex(state^, serverID); index >= 0 {
		return &state.serverDirectCaches[index]
	}
	append(&state.serverDirectCaches, ServerDirectCache{serverID = serverID})
	return &state.serverDirectCaches[len(state.serverDirectCaches) - 1]
}

State_removeServerDirectCache :: proc(state: ^State, serverID: int) {
	if index := State_serverDirectCacheIndex(state^, serverID); index >= 0 {
		ServerDirectCache_deinit(&state.serverDirectCaches[index])
		ordered_remove(&state.serverDirectCaches, index)
	}
	if serverID == state.selected_server_id {
		state.selected_dm_peer_id = 0
	}
}

ServerDirectCache_conversationCacheIndex :: proc(cache: ServerDirectCache, peerUserID: int) -> int {
	for index in 0 ..< len(cache.caches) {
		if cache.caches[index].peerUserID == peerUserID {
			return index
		}
	}
	return -1
}

// Returns the conversation cache for peerUserID, creating it. The pointer is valid until the
// next conversation cache of this server is added.
ServerDirectCache_conversationCache :: proc(
	cache: ^ServerDirectCache,
	peerUserID: int,
) -> ^DirectConversationCache {
	if index := ServerDirectCache_conversationCacheIndex(cache^, peerUserID); index >= 0 {
		return &cache.caches[index]
	}
	append(&cache.caches, DirectConversationCache{peerUserID = peerUserID})
	return &cache.caches[len(cache.caches) - 1]
}

ServerDirectCache_userIndex :: proc(cache: ServerDirectCache, userID: int) -> int {
	for index in 0 ..< len(cache.users) {
		if cache.users[index].id == userID {
			return index
		}
	}
	return -1
}

ServerDirectCache_conversationIndex :: proc(cache: ServerDirectCache, peerUserID: int) -> int {
	for index in 0 ..< len(cache.conversations) {
		if cache.conversations[index].peerUserId == peerUserID {
			return index
		}
	}
	return -1
}

// The peer's nickname from the directory, then from the conversation list; empty when the
// client knows neither. Borrowed from the cache.
ServerDirectCache_peerNickname :: proc(cache: ^ServerDirectCache, peerUserID: int) -> string {
	if index := ServerDirectCache_userIndex(cache^, peerUserID); index >= 0 {
		if nickname := cache.users[index].nickname; len(nickname) > 0 {
			return nickname
		}
	}
	if index := ServerDirectCache_conversationIndex(cache^, peerUserID); index >= 0 {
		return cache.conversations[index].peerNickname
	}
	return ""
}

ServerDirectCache_peerIsOnline :: proc(cache: ^ServerDirectCache, peerUserID: int) -> bool {
	index := ServerDirectCache_userIndex(cache^, peerUserID)
	return index >= 0 && cache.users[index].isOnline
}

// Merges a borrowed message into the cache by ID, cloning its strings. Duplicates (a history
// page overlapping a live echo, or two overlapping pages) are dropped. Returns true when the
// message was new.
DirectConversationCache_mergeMessage :: proc(
	cache: ^DirectConversationCache,
	message: common.StoredDirectMessage,
) -> bool {
	if message.id <= 0 {
		return false
	}
	insertIndex := len(cache.messages)
	for index := len(cache.messages) - 1; index >= 0; index -= 1 {
		existingID := cache.messages[index].id
		if existingID == message.id {
			return false
		}
		if existingID < message.id {
			break
		}
		insertIndex = index
	}
	clone := common.StoredDirectMessage {
		id                = message.id,
		senderId          = message.senderId,
		senderNickname    = strings.clone(message.senderNickname),
		recipientId       = message.recipientId,
		recipientNickname = strings.clone(message.recipientNickname),
		timestamp         = strings.clone(message.timestamp),
		content           = strings.clone(message.content),
	}
	inject_at(&cache.messages, insertIndex, clone)
	if cache.oldestMessageID == 0 || message.id < cache.oldestMessageID {
		cache.oldestMessageID = message.id
	}
	return true
}

// The other side of a message from the viewer's point of view, or 0 when the viewer is on
// neither side (which the server never sends).
directMessagePeerUserID :: proc(message: common.StoredDirectMessage, selfUserID: int) -> int {
	switch selfUserID {
	case 0:
		return 0
	case message.senderId:
		return message.recipientId
	case message.recipientId:
		return message.senderId
	}
	return 0
}

// Moves the peer's conversation to the top with message as its latest, adding it when the
// list has none yet, and returns true. An older message than the one listed changes nothing
// and returns false. The summary keeps its read state.
ServerDirectCache_noteLatestMessage :: proc(
	cache: ^ServerDirectCache,
	peerUserID: int,
	message: common.StoredDirectMessage,
) -> bool {
	peerNickname := message.recipientNickname
	if message.senderId == peerUserID {
		peerNickname = message.senderNickname
	}
	summary: common.DirectConversationSummary
	if index := ServerDirectCache_conversationIndex(cache^, peerUserID); index >= 0 {
		if cache.conversations[index].lastMessageID >= message.id {
			return false
		}
		summary = cache.conversations[index]
		ordered_remove(&cache.conversations, index)
		delete(summary.lastTimestamp)
		delete(summary.lastContent)
		if len(summary.peerNickname) == 0 {
			delete(summary.peerNickname)
			summary.peerNickname = strings.clone(peerNickname)
		}
	} else {
		summary.peerUserId = peerUserID
		summary.peerNickname = strings.clone(peerNickname)
	}
	summary.lastMessageID = message.id
	summary.lastSenderId = message.senderId
	summary.lastTimestamp = strings.clone(message.timestamp)
	summary.lastContent = strings.clone(message.content)
	inject_at(&cache.conversations, 0, summary)
	return true
}

// True while this conversation is the one selected on the selected server, whether or not the
// window has focus (for that, see State_isConversationViewed).
State_isDirectConversationOpen :: proc(state: ^State, serverID, peerUserID: int) -> bool {
	return(
		peerUserID != 0 &&
		state.selected_server_id == serverID &&
		state.selected_dm_peer_id == peerUserID \
	)
}

// ── Requests ──────────────────────────────────────────────────────

// Like room requests, these are skipped while the server is not connected; Connected asks
// again for the directory and the conversation list.
State_requestUserList :: proc(state: ^State, serverID: int) {
	transportIndex := State_selectedTransportIndexForServerID(state^, serverID)
	if transportIndex < 0 || !State_isServerConnected(state, serverID) {
		return
	}
	cache := State_serverDirectCache(state, serverID)
	if cache.usersLoading {
		return
	}
	transport := &state.serverTransports[transportIndex]
	ClientNetworkWorker_lock(state.networkWorker)
	defer ClientNetworkWorker_unlock(state.networkWorker)
	if ClientServerTransport_requestUserList(transport) {
		cache.usersLoading = true
	} else if len(transport.lastError) > 0 {
		State_setChatStatus(state, transport.lastError)
	}
}

State_requestDirectConversations :: proc(state: ^State, serverID: int) {
	transportIndex := State_selectedTransportIndexForServerID(state^, serverID)
	if transportIndex < 0 || !State_isServerConnected(state, serverID) {
		return
	}
	cache := State_serverDirectCache(state, serverID)
	if cache.conversationsLoading {
		return
	}
	transport := &state.serverTransports[transportIndex]
	ClientNetworkWorker_lock(state.networkWorker)
	defer ClientNetworkWorker_unlock(state.networkWorker)
	if ClientServerTransport_requestDirectConversations(transport) {
		cache.conversationsLoading = true
	} else if len(transport.lastError) > 0 {
		State_setChatStatus(state, transport.lastError)
	}
}

State_requestDirectHistory :: proc(
	state: ^State,
	serverID, peerUserID: int,
	beforeMessageID: int,
) {
	if peerUserID <= 0 {
		return
	}
	cache := State_serverDirectCache(state, serverID)
	conversation := ServerDirectCache_conversationCache(cache, peerUserID)
	if conversation.isLoadingHistory {
		return
	}
	transportIndex := State_selectedTransportIndexForServerID(state^, serverID)
	if transportIndex < 0 || !State_isServerConnected(state, serverID) {
		return
	}
	transport := &state.serverTransports[transportIndex]
	ClientNetworkWorker_lock(state.networkWorker)
	defer ClientNetworkWorker_unlock(state.networkWorker)
	if ClientServerTransport_requestDirectHistory(
		transport,
		peerUserID,
		beforeMessageID,
		common.HISTORY_PAGE_MAX_MESSAGES,
	) {
		conversation.isLoadingHistory = true
	} else if len(transport.lastError) > 0 {
		State_setChatStatus(state, transport.lastError)
	}
}

// ── User actions ──────────────────────────────────────────────────

// Opens the conversation with peerUserID on serverID in the main pane and fetches its newest
// page unless it is already loaded; the GUI then marks it read (State_updateReadMarkers). The
// selected room is kept, so going back to a room shows the one that was open before.
State_openDirectConversation :: proc(state: ^State, serverID, peerUserID: int) {
	if peerUserID <= 0 || peerUserID == State_selfUserID(state, serverID) {
		return
	}
	if serverID != state.selected_server_id {
		state.selected_server_id = serverID
		state.selected_transport_index = State_selectedTransportIndexForServerID(
			state^,
			serverID,
		)
		state.selected_channel_id = 0
		State_requestRoomList(state, serverID)
	}
	State_closeRoomEditor(state)
	State_closeServerSettings(state)
	state.selected_dm_peer_id = peerUserID
	cache := State_serverDirectCache(state, serverID)
	conversation := ServerDirectCache_conversationCache(cache, peerUserID)
	if !conversation.initialHistoryLoaded {
		State_requestDirectHistory(state, serverID, peerUserID, 0)
	}
	State_clearChatStatus(state)
	// The peer's key state for the conversation's key banner (and E2's encryption): the first
	// bundle seen is pinned, a later one is checked against the pin.
	if State_e2eePeerKeyInfo(state, serverID, peerUserID).state == .Unknown {
		ids := [1]int{peerUserID}
		State_e2eeRequestUserKeys(state, serverID, ids[:])
	}
}

// Returns the draft of the open conversation, or nil when none is open. The pointer is only
// valid until the direct-message caches next change.
State_selectedDirectDraft :: proc(state: ^State) -> ^[dynamic]u8 {
	if state.selected_dm_peer_id == 0 {
		return nil
	}
	cache := State_serverDirectCache(state, state.selected_server_id)
	return &ServerDirectCache_conversationCache(cache, state.selected_dm_peer_id).draft
}

// Sends the open conversation's draft.
State_sendDirectMessage :: proc(state: ^State) {
	if state.selected_dm_peer_id == 0 {
		State_setChatStatus(state, "No conversation selected")
		return
	}
	State_sendDirectMessageTo(state, state.selected_server_id, state.selected_dm_peer_id)
}

// Sends the draft of the conversation with peerUserID on serverID. The draft is cleared only
// once the transport accepted it, and nothing is added to the transcript: the message appears
// when the server echoes it back with its ID and timestamp.
State_sendDirectMessageTo :: proc(state: ^State, serverID, peerUserID: int) {
	if peerUserID <= 0 {
		State_setChatStatus(state, "No conversation selected")
		return
	}
	if peerUserID == State_selfUserID(state, serverID) {
		State_setChatStatus(state, "Cannot send a direct message to yourself")
		return
	}
	transportIndex := State_selectedTransportIndexForServerID(state^, serverID)
	if transportIndex < 0 {
		State_setChatStatus(state, "No server transport selected")
		return
	}
	cache := State_serverDirectCache(state, serverID)
	draft := &ServerDirectCache_conversationCache(cache, peerUserID).draft
	content := normalizeTabs(string(draft[:]))
	defer delete(content)
	if len(strings.trim_space(content)) == 0 {
		State_setChatStatus(state, "Cannot send an empty message")
		return
	}
	if len(content) > common.CHAT_MESSAGE_MAX_BYTES {
		State_setChatStatus(state, "Message is too long")
		return
	}

	transport := &state.serverTransports[transportIndex]
	// The worker may replace lastError at any time, so copy it while holding the lock.
	ClientNetworkWorker_lock(state.networkWorker)
	sent := directMessageSendBridge(transport, peerUserID, content)
	sendError := sent ? "" : strings.clone(transport.lastError)
	ClientNetworkWorker_unlock(state.networkWorker)
	defer if !sent do delete(sendError)

	if sent {
		clear(draft)
		State_clearChatStatus(state)
	} else if len(sendError) > 0 {
		State_setChatStatus(state, sendError)
	} else {
		State_setChatStatus(state, "Failed to send direct message")
	}
}

State_loadOlderDirectHistory :: proc(state: ^State) {
	if state.selected_dm_peer_id == 0 {
		return
	}
	serverID := state.selected_server_id
	cache := State_serverDirectCache(state, serverID)
	conversation := ServerDirectCache_conversationCache(cache, state.selected_dm_peer_id)
	if conversation.hasOlder && conversation.oldestMessageID > 0 {
		State_requestDirectHistory(
			state,
			serverID,
			state.selected_dm_peer_id,
			conversation.oldestMessageID,
		)
	}
}

// ── Receive handlers ──────────────────────────────────────────────

// The message is borrowed; the cache keeps its own copy. Every new message moves its
// conversation to the top of the list, and one from the peer that is newer than the listed
// latest and the marker counts as unread unless the conversation is viewed (read_state.odin).
State_receiveDirectMessage :: proc(
	state: ^State,
	serverID: int,
	message: common.StoredDirectMessage,
) {
	if State_selectedTransportIndexForServerID(state^, serverID) < 0 {
		return
	}
	selfUserID := State_selfUserID(state, serverID)
	peerUserID := directMessagePeerUserID(message, selfUserID)
	if peerUserID <= 0 {
		return
	}
	cache := State_serverDirectCache(state, serverID)
	conversation := ServerDirectCache_conversationCache(cache, peerUserID)
	if !DirectConversationCache_mergeMessage(conversation, message) {
		return
	}
	// A message older than the listed latest was already in the list's count.
	if !ServerDirectCache_noteLatestMessage(cache, peerUserID, message) {
		return
	}
	summary := &cache.conversations[0]
	if message.senderId == peerUserID &&
	   readStateCountsMessage(
		   state,
		   .Direct,
		   serverID,
		   peerUserID,
		   message.senderId,
		   message.id,
		   summary.lastReadMessageId,
	   ) {
		summary.unreadCount = min(summary.unreadCount + 1, common.UNREAD_COUNT_CAP)
	}
}

// Messages are borrowed; each merged message is cloned into the conversation cache.
State_receiveDirectHistory :: proc(
	state: ^State,
	serverID, peerUserID: int,
	messages: []common.StoredDirectMessage,
	hasOlder: bool,
) {
	if State_selectedTransportIndexForServerID(state^, serverID) < 0 || peerUserID <= 0 {
		return
	}
	cache := State_serverDirectCache(state, serverID)
	conversation := ServerDirectCache_conversationCache(cache, peerUserID)
	for message in messages {
		DirectConversationCache_mergeMessage(conversation, message)
	}
	// Only a page that reaches the oldest loaded message knows whether anything older exists;
	// the newest page fetched again after a reconnect must not bring back "Load older" once
	// the start of the conversation is loaded.
	if len(messages) == 0 || messages[0].id <= conversation.oldestMessageID {
		conversation.hasOlder = hasOlder
	}
	conversation.initialHistoryLoaded = true
	conversation.isLoadingHistory = false
}

// Takes ownership of users and clears the caller's array.
State_receiveUserList :: proc(state: ^State, serverID: int, users: ^[dynamic]common.UserSummary) {
	if State_selectedTransportIndexForServerID(state^, serverID) < 0 {
		return
	}
	cache := State_serverDirectCache(state, serverID)
	UserSummaries_deinit(&cache.users)
	cache.users = users^
	users^ = nil
	cache.usersLoaded = true
	cache.usersLoading = false
}

// Takes ownership of conversations and clears the caller's array.
State_receiveDirectConversations :: proc(
	state: ^State,
	serverID: int,
	conversations: ^[dynamic]common.DirectConversationSummary,
) {
	if State_selectedTransportIndexForServerID(state^, serverID) < 0 {
		return
	}
	cache := State_serverDirectCache(state, serverID)
	DirectConversationSummaries_deinit(&cache.conversations)
	cache.conversations = conversations^
	conversations^ = nil
	cache.conversationsLoaded = true
	cache.conversationsLoading = false
}

// Updates the directory's online flag and, when the event carries a different nickname (the
// account was renamed: a rename is announced as presence), the account's nickname in the
// directory and in its conversation summary. Cached messages keep the senderNickname they were
// stored with; a history fetch shows the current name, because the server joins it then. An
// account the directory does not list yet (it was created after the list was fetched) is added,
// taking ownership of user's nickname and clearing it; otherwise the caller still owns it.
State_userPresenceChanged :: proc(state: ^State, serverID: int, user: ^common.UserSummary) {
	if State_selectedTransportIndexForServerID(state^, serverID) < 0 || user.id <= 0 {
		return
	}
	cache := State_serverDirectCache(state, serverID)
	if index := ServerDirectCache_conversationIndex(cache^, user.id); index >= 0 {
		summary := &cache.conversations[index]
		if len(user.nickname) > 0 && summary.peerNickname != user.nickname {
			delete(summary.peerNickname)
			summary.peerNickname = strings.clone(user.nickname)
		}
	}
	if index := ServerDirectCache_userIndex(cache^, user.id); index >= 0 {
		known := &cache.users[index]
		known.isOnline = user.isOnline
		if len(user.nickname) > 0 && known.nickname != user.nickname {
			delete(known.nickname)
			known.nickname = user.nickname
			user.nickname = ""
		}
		return
	}
	append(&cache.users, user^)
	user^ = {}
}

// ServerUserUpdated (protocol 14): an admin changed an account's role, ban, or name. The
// directory entry is replaced in place (added when unknown), and a new name also reaches the
// account's conversation summary, like a rename announced as presence. Takes ownership of
// user's nickname and clears it.
State_userUpdated :: proc(state: ^State, serverID: int, user: ^common.UserSummary) {
	if State_selectedTransportIndexForServerID(state^, serverID) < 0 || user.id <= 0 {
		return
	}
	cache := State_serverDirectCache(state, serverID)
	if index := ServerDirectCache_conversationIndex(cache^, user.id); index >= 0 {
		summary := &cache.conversations[index]
		if len(user.nickname) > 0 && summary.peerNickname != user.nickname {
			delete(summary.peerNickname)
			summary.peerNickname = strings.clone(user.nickname)
		}
	}
	if index := ServerDirectCache_userIndex(cache^, user.id); index >= 0 {
		known := &cache.users[index]
		if len(user.nickname) == 0 {
			user.nickname = known.nickname
		} else {
			delete(known.nickname)
		}
		known^ = user^
		user^ = {}
		return
	}
	append(&cache.users, user^)
	user^ = {}
}

// A new session must fetch everything again: requests in flight died with the old one, and
// messages may have arrived while disconnected. Merging by message ID keeps what is loaded.
State_resetDirectRequests :: proc(state: ^State, serverID: int, reloadHistory: bool) {
	index := State_serverDirectCacheIndex(state^, serverID)
	if index < 0 {
		return
	}
	cache := &state.serverDirectCaches[index]
	cache.usersLoading = false
	cache.conversationsLoading = false
	for conversationIndex in 0 ..< len(cache.caches) {
		conversation := &cache.caches[conversationIndex]
		conversation.isLoadingHistory = false
		if reloadHistory {
			conversation.initialHistoryLoaded = false
		}
	}
}

// Called on Connected: refreshes the directory and conversation list, and the newest page of
// the open conversation.
State_requestDirectStateAfterConnect :: proc(state: ^State, serverID: int) {
	State_requestUserList(state, serverID)
	State_requestDirectConversations(state, serverID)
	if serverID == state.selected_server_id && state.selected_dm_peer_id != 0 {
		State_requestDirectHistory(state, serverID, state.selected_dm_peer_id, 0)
	}
}

// Protocol errors do not say which request failed, so the list flags and the open
// conversation's loading flag are cleared to let the next request go out.
State_directProtocolError :: proc(state: ^State, serverID: int) {
	index := State_serverDirectCacheIndex(state^, serverID)
	if index < 0 {
		return
	}
	cache := &state.serverDirectCaches[index]
	cache.usersLoading = false
	cache.conversationsLoading = false
	if serverID != state.selected_server_id || state.selected_dm_peer_id == 0 {
		return
	}
	if conversationIndex := ServerDirectCache_conversationCacheIndex(
		cache^,
		state.selected_dm_peer_id,
	); conversationIndex >= 0 {
		cache.caches[conversationIndex].isLoadingHistory = false
	}
}
