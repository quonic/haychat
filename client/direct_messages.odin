package client

import "../common"
import "core:crypto"
import "core:strings"

// Direct messages, the user directory, and presence, per configured server.
//
// The server is the source of truth for all of it. A sent message is never added locally: the
// server echoes every stored message to every session of both users (the sender's included),
// and that echo is what lands in the cache. Peer user IDs are only unique within one server,
// so every cache is keyed by (serverID, peerUserID), like room caches are keyed by
// (serverID, roomID).

DirectMessageSendBridge :: proc(transport: ^ClientServerTransport, send: DirectMessageSend) -> bool

// Tests swap this to observe sends without a live session.
directMessageSendBridge: DirectMessageSendBridge = ClientServerTransport_sendDirectMessage

// What the client concluded about one direct message (protocol 17, e2ee-design.md 4.5, 4.6;
// direct_messages_e2ee.odin decides it). Every message must be signed by its sender (#82): one
// whose signature was not verified against the sender's pin (or this profile's own key) is
// Hidden and never shown, whatever the reason.
DirectMessageProtection :: enum u8 {
	// Waiting for a pinned key to check it with (a fetch is on its way): a placeholder, never
	// the content, until the signature is checked.
	Pending,
	Signed, // Plaintext fallback signed by the sender's pinned key: "Unencrypted"
	Encrypted, // An envelope opened with the pinned keys: a lock
	// An envelope whose signature verified but which could not be opened, or a replay: "This
	// message could not be decrypted"
	Failed,
	// Not shown: no signature, a signature that does not verify, no pin to verify it with, or
	// an envelope that failed at or before its signature check (failure says why)
	Hidden,
}

// Why a message is Failed or Hidden, for the harness's decryptError and the tests.
DirectMessageFailure :: enum u8 {
	None,
	NoKey, // Hidden: the server has no key for the sender and none was ever pinned
	OwnKey, // Failed: this profile has no valid encryption key (the signature verified)
	Envelope, // The envelope did not verify (Hidden) or open (Failed); envelopeError says why
	Replayed, // Failed: another message from the same sender carries the same client message ID
	Unsigned, // Hidden: plaintext without a signature (from before protocol 17, or inserted)
	BadSignature, // Hidden: plaintext whose signature does not verify against the pin
}

DirectMessageSecurity :: struct {
	protection:    DirectMessageProtection,
	failure:       DirectMessageFailure,
	envelopeError: common.E2EEError,
}

// One cached direct message: the server's fields, with content holding the opened plaintext of
// an encrypted message (empty when it could not be opened), and what the client checked. Every
// string and the envelope are owned; content is wiped before it is freed.
DirectMessageEntry :: struct {
	using message: common.StoredDirectMessage,
	security:      DirectMessageSecurity,
	// Protocol 27 (attachments.odin): the files the client checked, and whether a sealed
	// message's attachment list was changed on the server.
	files:         [dynamic]MessageFile,
	filesChanged:  bool,
}

// A conversation list entry: the server's summary, with lastContent holding the opened preview
// of an encrypted newest message, and what the client checked about that message.
DirectConversationEntry :: struct {
	using summary: common.DirectConversationSummary,
	security:      DirectMessageSecurity,
}

// One conversation with one peer on one server.
DirectConversationCache :: struct {
	peerUserID:           int,
	messages:             [dynamic]DirectMessageEntry, // Owned, ordered by ID
	draft:                [dynamic]u8, // Client-local, edited in place by the composer
	initialHistoryLoaded: bool,
	isLoadingHistory:     bool,
	oldestMessageID:      int,
	hasOlder:             bool,
	// The conversation's last mark-read (read_state.odin). Its marker and unread count are
	// the server's and live in the conversation's DirectConversationSummary.
	readSend:             ReadMarkerSendState,
	// Messages accepted while the peer's key was still being fetched (design 7.2): sent, in
	// order, as soon as encryption is possible, or put back into the draft when it is not.
	// Owned and wiped before they are freed.
	queued:               [dynamic]string,
	// The plaintext fallback (design 4.6): the "Send without encryption" switch, whether its
	// first-time confirmation was accepted, and whether that confirmation is showing. Never
	// saved; off again when the conversation closes or encryption becomes possible.
	fallbackOn:           bool,
	fallbackConfirmed:    bool,
	fallbackConfirmOpen:  bool,
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
	conversations:        [dynamic]DirectConversationEntry,
	conversationsLoaded:  bool,
	conversationsLoading: bool,
	caches:               [dynamic]DirectConversationCache,
}

DirectMessageEntry_deinit :: proc(entry: ^DirectMessageEntry) {
	wipeString(entry.content)
	StoredDirectMessage_deinit(&entry.message)
	MessageFiles_deinit(&entry.files)
	entry^ = {}
}

DirectMessageEntries_deinit :: proc(entries: ^[dynamic]DirectMessageEntry) {
	for index in 0 ..< len(entries) {
		DirectMessageEntry_deinit(&entries[index])
	}
	delete(entries^)
	entries^ = nil
}

DirectConversationEntry_deinit :: proc(entry: ^DirectConversationEntry) {
	wipeString(entry.lastContent)
	DirectConversationSummary_deinit(&entry.summary)
	entry^ = {}
}

DirectConversationEntries_deinit :: proc(entries: ^[dynamic]DirectConversationEntry) {
	for index in 0 ..< len(entries) {
		DirectConversationEntry_deinit(&entries[index])
	}
	delete(entries^)
	entries^ = nil
}

DirectConversationCache_deinit :: proc(cache: ^DirectConversationCache) {
	DirectMessageEntries_deinit(&cache.messages)
	wipeBytes(cache.draft[:])
	delete(cache.draft)
	for text in cache.queued {
		wipeString(text)
		delete(text)
	}
	delete(cache.queued)
	cache^ = {}
}

ServerDirectCache_deinit :: proc(cache: ^ServerDirectCache) {
	UserSummaries_deinit(&cache.users)
	DirectConversationEntries_deinit(&cache.conversations)
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

// Merges an entry into the cache by ID, taking ownership of it when it is new (and clearing
// the caller's copy); a duplicate (a history page overlapping a live echo, or two overlapping
// pages) is left to the caller to free. Returns true when the entry was new.
//
// A message whose sender and client message ID repeat another cached message's (design 4.2:
// the server replayed an envelope or a signed message under a new ID) marks the later of the
// two Replayed and drops its content, whichever arrived first
// (DirectConversationCache_checkReplay).
DirectConversationCache_mergeEntry :: proc(
	cache: ^DirectConversationCache,
	entry: ^DirectMessageEntry,
) -> bool {
	if entry.id <= 0 {
		return false
	}
	insertIndex := len(cache.messages)
	for index := len(cache.messages) - 1; index >= 0; index -= 1 {
		existingID := cache.messages[index].id
		if existingID == entry.id {
			return false
		}
		if existingID < entry.id {
			break
		}
		insertIndex = index
	}
	inject_at(&cache.messages, insertIndex, entry^)
	entry^ = {}
	if cache.oldestMessageID == 0 || cache.messages[insertIndex].id < cache.oldestMessageID {
		cache.oldestMessageID = cache.messages[insertIndex].id
	}
	DirectConversationCache_checkReplay(cache, insertIndex)
	return true
}

// Compares the entry at index with every other message of its sender: two that both opened (or
// verified) with the same client message ID are a replay, and the later one is marked. A
// message that failed or still waits for a key takes no part, so a forged copy cannot make the
// real message look replayed; one that opens later is checked again (State_directReopenPending).
DirectConversationCache_checkReplay :: proc(cache: ^DirectConversationCache, index: int) {
	entry := &cache.messages[index]
	if !common.clientMessageIDIsSet(entry.clientMessageId) ||
	   !directMessageTakesPartInReplays(entry.security) {
		return
	}
	for &existing, existingIndex in cache.messages {
		if existingIndex == index ||
		   existing.senderId != entry.senderId ||
		   existing.clientMessageId != entry.clientMessageId ||
		   !directMessageTakesPartInReplays(existing.security) {
			continue
		}
		if existing.id > entry.id {
			directMessageMarkReplayed(&existing)
		} else {
			directMessageMarkReplayed(entry)
			return
		}
	}
}

@(private = "file")
directMessageTakesPartInReplays :: proc(security: DirectMessageSecurity) -> bool {
	#partial switch security.protection {
	case .Encrypted, .Signed:
		return true
	}
	return false
}

@(private = "file")
directMessageMarkReplayed :: proc(entry: ^DirectMessageEntry) {
	wipeString(entry.content)
	delete(entry.content)
	entry.content = ""
	entry.security = {protection = .Failed, failure = .Replayed}
}

// A deep copy of a borrowed message.
StoredDirectMessage_clone :: proc(
	message: common.StoredDirectMessage,
) -> common.StoredDirectMessage {
	clone := message
	clone.senderNickname = strings.clone(message.senderNickname)
	clone.recipientNickname = strings.clone(message.recipientNickname)
	clone.timestamp = strings.clone(message.timestamp)
	clone.content = strings.clone(message.content)
	clone.attachments = common.AttachmentRefs_clone(message.attachments[:])
	clone.envelope = nil
	if len(message.envelope) > 0 {
		clone.envelope = make([]u8, len(message.envelope))
		copy(clone.envelope, message.envelope)
	}
	return clone
}

// Zeroes a string's bytes in place (decrypted text, drafts) before it is freed. Strings are
// read-only to the language, but every one passed here is an owned heap allocation.
wipeString :: proc(text: string) {
	if len(text) > 0 {
		crypto.zero_explicit(raw_data(text), len(text))
	}
}

wipeBytes :: proc(data: []u8) {
	if len(data) > 0 {
		crypto.zero_explicit(raw_data(data), len(data))
	}
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

// Moves the peer's conversation to the top with entry as its latest, adding it when the list
// has none yet, and returns true. An older message than the one listed changes nothing and
// returns false. The summary keeps its read state; the preview is the entry's (opened) content.
ServerDirectCache_noteLatestMessage :: proc(
	cache: ^ServerDirectCache,
	peerUserID: int,
	entry: DirectMessageEntry,
) -> bool {
	peerNickname := entry.recipientNickname
	if entry.senderId == peerUserID {
		peerNickname = entry.senderNickname
	}
	summary: DirectConversationEntry
	if index := ServerDirectCache_conversationIndex(cache^, peerUserID); index >= 0 {
		if cache.conversations[index].lastMessageID >= entry.id {
			return false
		}
		summary = cache.conversations[index]
		ordered_remove(&cache.conversations, index)
		delete(summary.lastTimestamp)
		wipeString(summary.lastContent)
		delete(summary.lastContent)
		delete(summary.lastEnvelope)
		summary.lastEnvelope = nil
		common.AttachmentRefs_deinit(&summary.lastAttachments)
		if len(summary.peerNickname) == 0 {
			delete(summary.peerNickname)
			summary.peerNickname = strings.clone(peerNickname)
		}
	} else {
		summary.peerUserId = peerUserID
		summary.peerNickname = strings.clone(peerNickname)
	}
	summary.lastMessageID = entry.id
	summary.lastSenderId = entry.senderId
	summary.lastTimestamp = strings.clone(entry.timestamp)
	summary.lastContent = strings.clone(entry.content)
	summary.lastClientMessageId = entry.clientMessageId
	summary.lastSignature = entry.signature
	summary.lastAttachments = common.AttachmentRefs_clone(entry.attachments[:])
	if len(entry.envelope) > 0 {
		summary.lastEnvelope = make([]u8, len(entry.envelope))
		copy(summary.lastEnvelope, entry.envelope)
	}
	summary.security = entry.security
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
	// Closing the other conversation turns its plaintext switch off (design 4.6).
	if serverID != state.selected_server_id || state.selected_dm_peer_id != peerUserID {
		State_closeDirectConversation(state)
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

// The message is borrowed; the cache keeps its own, opened copy (direct_messages_e2ee.odin).
// Every new message moves its conversation to the top of the list, and one from the peer that
// is newer than the listed latest and the marker counts as unread unless the conversation is
// viewed (read_state.odin).
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
	// Protocol 27: this account's own message bound these uploads.
	if message.senderId == selfUserID {
		State_attachmentsNoteBound(state, serverID, message.attachments[:])
	}
	keys := State_directOpenKeys(state, serverID)
	defer DirectOpenKeys_wipe(&keys)
	entry := State_openDirectEntry(state, serverID, keys, message)
	cache := State_serverDirectCache(state, serverID)
	conversation := ServerDirectCache_conversationCache(cache, peerUserID)
	if !DirectConversationCache_mergeEntry(conversation, &entry) {
		DirectMessageEntry_deinit(&entry)
		return
	}
	merged := DirectConversationCache_entry(conversation, message.id)
	State_directEntryOpened(state, serverID, peerUserID, merged.security)
	// A message that is not shown (#82) neither moves its conversation nor counts as unread.
	// A message older than the listed latest was already in the list's count.
	if merged.security.protection == .Hidden ||
	   !ServerDirectCache_noteLatestMessage(cache, peerUserID, merged^) {
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

// The cached entry with messageID, or nil. Valid until the conversation's messages change.
DirectConversationCache_entry :: proc(
	cache: ^DirectConversationCache,
	messageID: int,
) -> ^DirectMessageEntry {
	for &entry in cache.messages {
		if entry.id == messageID {
			return &entry
		}
	}
	return nil
}

// Messages are borrowed; each merged message is opened into the conversation cache.
State_receiveDirectHistory :: proc(
	state: ^State,
	serverID, peerUserID: int,
	messages: []common.StoredDirectMessage,
	hasOlder: bool,
) {
	if State_selectedTransportIndexForServerID(state^, serverID) < 0 || peerUserID <= 0 {
		return
	}
	keys := State_directOpenKeys(state, serverID)
	defer DirectOpenKeys_wipe(&keys)
	cache := State_serverDirectCache(state, serverID)
	conversation := ServerDirectCache_conversationCache(cache, peerUserID)
	for message in messages {
		if existing := DirectConversationCache_entry(conversation, message.id); existing != nil {
			// Protocol 28: the server's removed flags, as for rooms (RoomCache_mergeMessage).
			messageAttachmentsNoteRemoved(
				existing.attachments[:],
				existing.files[:],
				message.attachments[:],
			)
			continue
		}
		entry := State_openDirectEntry(state, serverID, keys, message)
		security := entry.security
		cache = State_serverDirectCache(state, serverID)
		conversation = ServerDirectCache_conversationCache(cache, peerUserID)
		if !DirectConversationCache_mergeEntry(conversation, &entry) {
			DirectMessageEntry_deinit(&entry)
			continue
		}
		State_directEntryOpened(state, serverID, peerUserID, security)
		cache = State_serverDirectCache(state, serverID)
		conversation = ServerDirectCache_conversationCache(cache, peerUserID)
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

// Takes ownership of conversations and clears the caller's array. Each newest message is
// opened for its preview (design 4.5) like a message.
State_receiveDirectConversations :: proc(
	state: ^State,
	serverID: int,
	conversations: ^[dynamic]common.DirectConversationSummary,
) {
	if State_selectedTransportIndexForServerID(state^, serverID) < 0 {
		return
	}
	keys := State_directOpenKeys(state, serverID)
	defer DirectOpenKeys_wipe(&keys)
	entries := make([dynamic]DirectConversationEntry, 0, len(conversations))
	for &summary in conversations {
		entry := DirectConversationEntry {
			summary = summary,
		}
		summary = {}
		State_openDirectPreview(state, serverID, keys, &entry)
		append(&entries, entry)
	}
	delete(conversations^)
	conversations^ = nil
	cache := State_serverDirectCache(state, serverID)
	DirectConversationEntries_deinit(&cache.conversations)
	cache.conversations = entries
	cache.conversationsLoaded = true
	cache.conversationsLoading = false
	// One fetch for every preview that waits for a key; the rest only mark their conversation.
	waiting := make([dynamic]int, 0, len(entries))
	defer delete(waiting)
	settle := false
	for entry in entries {
		if entry.security.protection != .Pending {
			State_directEntryOpened(state, serverID, entry.peerUserId, entry.security)
		} else if State_e2eePeerKeyInfo(state, serverID, entry.peerUserId).state == .Unknown {
			append(&waiting, entry.peerUserId)
		} else {
			settle = true
		}
	}
	if len(waiting) > 0 {
		State_e2eeRequestUserKeys(state, serverID, waiting[:])
	}
	if settle {
		State_directReopenPending(state, serverID)
	}
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
		delete(known.roleIds)
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
