package client

import "../common"
import "core:strings"

// Actions mutate State in place. The immediate-mode view calls them directly in response to
// input, and State_applyRuntimeEvent calls them for events queued by the network worker.

State_clearChatStatus :: proc(state: ^State) {
	if len(state.chat_status_message) == 0 {
		return
	}
	delete(state.chat_status_message)
	state.chat_status_message = ""
}

State_setChatStatus :: proc(state: ^State, message: string) {
	State_clearChatStatus(state)
	if len(message) == 0 {
		return
	}
	state.chat_status_message = strings.clone(message)
}

State_selectedTransport :: proc(state: ^State) -> (^ClientServerTransport, bool) {
	if state.selected_transport_index < 0 ||
	   state.selected_transport_index >= len(state.serverTransports) {
		return nil, false
	}

	return &state.serverTransports[state.selected_transport_index], true
}

RoomCache_deinit :: proc(cache: ^RoomCache) {
	for message in cache.messages {
		delete(message.senderNickname)
		delete(message.timestamp)
		delete(message.content)
	}
	delete(cache.messages)
	delete(cache.draft)
	cache^ = {}
}

ServerRoomCache_deinit :: proc(cache: ^ServerRoomCache) {
	for room in cache.rooms {
		delete(room.name)
		delete(room.description)
	}
	delete(cache.rooms)
	for index in 0 ..< len(cache.roomCaches) {
		RoomCache_deinit(&cache.roomCaches[index])
	}
	delete(cache.roomCaches)
	cache^ = {}
}

State_serverRoomCache :: proc(state: ^State, serverID: int) -> ^ServerRoomCache {
	for index in 0 ..< len(state.server_room_caches) {
		if state.server_room_caches[index].serverID == serverID {
			return &state.server_room_caches[index]
		}
	}
	append(&state.server_room_caches, ServerRoomCache{serverID = serverID})
	return &state.server_room_caches[len(state.server_room_caches) - 1]
}

State_serverRoomCacheIndex :: proc(state: State, serverID: int) -> int {
	for index in 0 ..< len(state.server_room_caches) {
		if state.server_room_caches[index].serverID == serverID {
			return index
		}
	}
	return -1
}

ServerRoomCache_roomCacheIndex :: proc(cache: ServerRoomCache, roomID: int) -> int {
	for index in 0 ..< len(cache.roomCaches) {
		if cache.roomCaches[index].roomID == roomID {
			return index
		}
	}
	return -1
}

ServerRoomCache_roomIsJoined :: proc(cache: ^ServerRoomCache, roomID: int) -> bool {
	for room in cache.rooms {
		if room.id == roomID {
			return true
		}
	}
	return false
}

ServerRoomCache_roomCache :: proc(cache: ^ServerRoomCache, roomID: int) -> ^RoomCache {
	for index in 0 ..< len(cache.roomCaches) {
		if cache.roomCaches[index].roomID == roomID {
			return &cache.roomCaches[index]
		}
	}
	append(&cache.roomCaches, RoomCache{roomID = roomID})
	return &cache.roomCaches[len(cache.roomCaches) - 1]
}

ServerRoomCache_removeRoom :: proc(cache: ^ServerRoomCache, roomID: int) {
	for index in 0 ..< len(cache.rooms) {
		if cache.rooms[index].id == roomID {
			delete(cache.rooms[index].name)
			delete(cache.rooms[index].description)
			unordered_remove(&cache.rooms, index)
			break
		}
	}
	for index in 0 ..< len(cache.roomCaches) {
		if cache.roomCaches[index].roomID == roomID {
			RoomCache_deinit(&cache.roomCaches[index])
			unordered_remove(&cache.roomCaches, index)
			break
		}
	}
}

// Returns true when the message was new to the cache.
RoomCache_mergeMessage :: proc(cache: ^RoomCache, message: common.StoredChatMessage) -> bool {
	if message.id <= 0 {
		return false
	}
	for existing in cache.messages {
		if existing.id == message.id {
			return false
		}
	}
	clone := common.StoredChatMessage {
		id             = message.id,
		senderId       = message.senderId,
		senderNickname = strings.clone(message.senderNickname),
		roomId         = message.roomId,
		timestamp      = strings.clone(message.timestamp),
		content        = strings.clone(message.content),
	}
	insertIndex := len(cache.messages)
	for index in 0 ..< len(cache.messages) {
		if message.id < cache.messages[index].id {
			insertIndex = index
			break
		}
	}
	append(&cache.messages, clone)
	for index := len(cache.messages) - 1; index > insertIndex; index -= 1 {
		cache.messages[index] = cache.messages[index - 1]
	}
	cache.messages[insertIndex] = clone
	if cache.oldestMessageID == 0 || message.id < cache.oldestMessageID {
		cache.oldestMessageID = message.id
	}
	return true
}

// Requests are skipped while the server is not connected; the Connected event requests the
// room list again, and the room list requests the selected room's history.
State_requestRoomList :: proc(state: ^State, serverID: int) {
	transportIndex := State_selectedTransportIndexForServerID(state^, serverID)
	if transportIndex < 0 || !State_isServerConnected(state, serverID) {
		return
	}
	cache := State_serverRoomCache(state, serverID)
	if cache.roomsLoading {
		return
	}
	transport := &state.serverTransports[transportIndex]
	ClientNetworkWorker_lock(state.networkWorker)
	defer ClientNetworkWorker_unlock(state.networkWorker)
	if ClientServerTransport_requestRoomList(transport) {
		cache.roomsLoading = true
	} else if len(transport.lastError) > 0 {
		State_setChatStatus(state, transport.lastError)
	}
}

State_requestRoomHistory :: proc(state: ^State, serverID: int, roomID: int, beforeMessageID: int) {
	cache := State_serverRoomCache(state, serverID)
	roomCache := ServerRoomCache_roomCache(cache, roomID)
	if roomCache.isLoadingHistory {
		return
	}
	transportIndex := State_selectedTransportIndexForServerID(state^, serverID)
	if transportIndex < 0 || !State_isServerConnected(state, serverID) {
		return
	}
	transport := &state.serverTransports[transportIndex]
	ClientNetworkWorker_lock(state.networkWorker)
	defer ClientNetworkWorker_unlock(state.networkWorker)
	if ClientServerTransport_requestRoomHistory(transport, roomID, beforeMessageID, 50) {
		roomCache.isLoadingHistory = true
	} else if len(transport.lastError) > 0 {
		State_setChatStatus(state, transport.lastError)
	}
}

// Returns an owned copy of value with tabs expanded for consistent input rendering.
normalizeTabs :: proc(value: string) -> string {
	normalized, allocated := strings.replace_all(value, "\t", "    ")
	if !allocated {
		return strings.clone(value)
	}
	return normalized
}

// Returns the draft buffer of the selected room, or nil when no room is selected. The pointer
// is only valid until the room caches are next modified.
State_selectedRoomDraft :: proc(state: ^State) -> ^[dynamic]u8 {
	if state.selected_channel_id == 0 {
		return nil
	}
	cache := State_serverRoomCache(state, state.selected_server_id)
	return &ServerRoomCache_roomCache(cache, state.selected_channel_id).draft
}

// Peer user IDs belong to one server, so switching servers closes any open conversation and
// the room editor.
State_switchToServer :: proc(state: ^State, serverID: int) {
	State_closeRoomEditor(state)
	state.selected_dm_peer_id = 0
	state.selected_server_id = serverID
	state.selected_transport_index = State_selectedTransportIndexForServerID(state^, serverID)
	state.selected_channel_id = 0
	State_requestRoomList(state, serverID)
	State_clearChatStatus(state)
}

// Showing a room replaces whatever the main pane showed, the room editor included.
State_switchToChannel :: proc(state: ^State, serverID: int, roomID: int) {
	State_closeRoomEditor(state)
	state.selected_dm_peer_id = 0
	state.selected_server_id = serverID
	state.selected_transport_index = State_selectedTransportIndexForServerID(state^, serverID)
	if roomID == 0 {
		state.selected_channel_id = common.GENERAL_ROOM_ID
	} else {
		state.selected_channel_id = roomID
	}
	cache := State_serverRoomCache(state, state.selected_server_id)
	roomCache := ServerRoomCache_roomCache(cache, state.selected_channel_id)
	if !roomCache.initialHistoryLoaded {
		State_requestRoomHistory(state, state.selected_server_id, state.selected_channel_id, 0)
	}
	State_clearChatStatus(state)
}

// Sends the selected room's draft. The draft is cleared only once the transport accepted it;
// the message itself appears when the server echoes it back.
State_sendChannelChat :: proc(state: ^State) {
	if state.selected_channel_id == 0 {
		State_setChatStatus(state, "No channel selected")
		return
	}
	draft := State_selectedRoomDraft(state)
	newMessage := normalizeTabs(string(draft[:]))
	defer delete(newMessage)

	transport, transportOK := State_selectedTransport(state)
	if !transportOK {
		State_setChatStatus(state, "No server transport selected")
		return
	}
	if transport.serverID != state.selected_server_id {
		State_setChatStatus(state, "Selected transport does not match the active server")
		return
	}
	// The worker may replace lastError at any time, so copy it while holding the lock.
	ClientNetworkWorker_lock(state.networkWorker)
	sent := roomChatSendBridge(transport, state.selected_channel_id, newMessage)
	sendError := sent ? "" : strings.clone(transport.lastError)
	ClientNetworkWorker_unlock(state.networkWorker)
	defer if !sent do delete(sendError)

	if sent {
		clear(draft)
		State_clearChatStatus(state)
	} else if len(sendError) > 0 {
		State_setChatStatus(state, sendError)
	} else {
		State_setChatStatus(state, "Failed to send room chat message")
	}
}

State_loadOlderRoomHistory :: proc(state: ^State) {
	if state.selected_channel_id == 0 {
		return
	}
	cache := State_serverRoomCache(state, state.selected_server_id)
	roomCache := ServerRoomCache_roomCache(cache, state.selected_channel_id)
	if roomCache.hasOlder && roomCache.oldestMessageID > 0 {
		State_requestRoomHistory(
			state,
			state.selected_server_id,
			state.selected_channel_id,
			roomCache.oldestMessageID,
		)
	}
}

// Strings are borrowed; the room cache keeps its own copies. A new message from someone else
// above the room's marker counts as unread unless the room is viewed (read_state.odin).
State_receiveRoomChat :: proc(
	state: ^State,
	serverID, roomID, senderID, messageID: int,
	senderNickname, timestamp, content: string,
) {
	if State_selectedTransportIndexForServerID(state^, serverID) < 0 {
		return
	}
	cache := State_serverRoomCache(state, serverID)
	roomCache := ServerRoomCache_roomCache(cache, roomID)
	merged := RoomCache_mergeMessage(
		roomCache,
		common.StoredChatMessage {
			id = messageID,
			senderId = senderID,
			senderNickname = senderNickname,
			roomId = roomID,
			timestamp = timestamp,
			content = content,
		},
	)
	if summary := State_roomSummary(state, serverID, roomID);
	   merged &&
	   summary != nil &&
	   readStateCountsMessage(
		   state,
		   .Room,
		   serverID,
		   roomID,
		   senderID,
		   messageID,
		   summary.lastReadMessageId,
	   ) {
		summary.unreadCount = min(summary.unreadCount + 1, common.UNREAD_COUNT_CAP)
	}
	State_clearChatStatus(state)
}

// Takes ownership of rooms and clears the caller's array.
State_receiveRoomList :: proc(state: ^State, serverID: int, rooms: ^[dynamic]common.RoomSummary) {
	cache := State_serverRoomCache(state, serverID)
	for room in cache.rooms {
		delete(room.name)
		delete(room.description)
	}
	delete(cache.rooms)
	cache.rooms = rooms^
	rooms^ = nil
	cache.roomsLoaded = true
	cache.roomsLoading = false
	for index := len(cache.roomCaches) - 1; index >= 0; index -= 1 {
		if !ServerRoomCache_roomIsJoined(cache, cache.roomCaches[index].roomID) {
			RoomCache_deinit(&cache.roomCaches[index])
			unordered_remove(&cache.roomCaches, index)
		}
	}
	if serverID != state.selected_server_id {
		return
	}
	if !ServerRoomCache_roomIsJoined(cache, state.selected_channel_id) {
		if len(cache.rooms) > 0 {
			state.selected_channel_id = cache.rooms[0].id
			State_requestRoomHistory(state, serverID, state.selected_channel_id, 0)
		} else {
			state.selected_channel_id = 0
		}
		return
	}
	// The selected room may not have loaded yet (first connect) or may be stale (reconnect).
	roomCache := ServerRoomCache_roomCache(cache, state.selected_channel_id)
	if !roomCache.initialHistoryLoaded {
		State_requestRoomHistory(state, serverID, state.selected_channel_id, 0)
	}
}

// Messages are borrowed; each merged message is cloned into the room cache.
State_receiveRoomHistory :: proc(
	state: ^State,
	serverID, roomID: int,
	messages: []common.StoredChatMessage,
	hasOlder: bool,
) {
	cache := State_serverRoomCache(state, serverID)
	roomCache := ServerRoomCache_roomCache(cache, roomID)
	for message in messages {
		RoomCache_mergeMessage(roomCache, message)
	}
	roomCache.initialHistoryLoaded = true
	roomCache.isLoadingHistory = false
	roomCache.hasOlder = hasOlder
}

// Falls back to another joined room when the selected room goes away: #general while it
// exists, otherwise the first room in the list.
State_fallBackFromRemovedRoom :: proc(state: ^State, serverID, roomID: int) {
	if serverID != state.selected_server_id || roomID != state.selected_channel_id {
		return
	}
	cache := State_serverRoomCache(state, serverID)
	state.selected_channel_id = 0
	if ServerRoomCache_roomIsJoined(cache, common.GENERAL_ROOM_ID) {
		state.selected_channel_id = common.GENERAL_ROOM_ID
	} else if len(cache.rooms) > 0 {
		state.selected_channel_id = cache.rooms[0].id
	}
}

State_roomMembershipChanged :: proc(state: ^State, serverID, roomID: int, joined: bool) {
	if !joined {
		ServerRoomCache_removeRoom(State_serverRoomCache(state, serverID), roomID)
		State_fallBackFromRemovedRoom(state, serverID, roomID)
		State_roomEditorRoomChanged(state, serverID, roomID)
		State_voiceRoomRemoved(state, serverID, roomID)
	}
	State_requestRoomList(state, serverID)
}

// Takes ownership of room when it replaces a joined room and clears the caller's copy;
// otherwise the caller still owns it. ServerEditRoom carries no read state, so the room keeps
// its marker and unread count.
State_roomEdited :: proc(state: ^State, serverID, roomID: int, room: ^common.RoomSummary) {
	// The form would otherwise save over a change it never showed.
	State_roomEditorRoomChanged(state, serverID, roomID)
	cache := State_serverRoomCache(state, serverID)
	for index in 0 ..< len(cache.rooms) {
		if cache.rooms[index].id == roomID {
			delete(cache.rooms[index].name)
			delete(cache.rooms[index].description)
			edited := room^
			edited.lastReadMessageId = cache.rooms[index].lastReadMessageId
			edited.unreadCount = cache.rooms[index].unreadCount
			cache.rooms[index] = edited
			room^ = {}
			return
		}
	}
}

State_roomDeleted :: proc(state: ^State, serverID, roomID: int) {
	State_roomEditorRoomChanged(state, serverID, roomID)
	ServerRoomCache_removeRoom(State_serverRoomCache(state, serverID), roomID)
	State_fallBackFromRemovedRoom(state, serverID, roomID)
	State_voiceRoomRemoved(state, serverID, roomID)
	State_requestRoomList(state, serverID)
}

// Message is borrowed. The loading flag is cleared on the selected room of the reporting
// server's cache, because protocol errors do not say which request failed.
State_transportProtocolError :: proc(state: ^State, serverID: int, message: string) {
	cache := State_serverRoomCache(state, serverID)
	if state.selected_channel_id != 0 {
		ServerRoomCache_roomCache(cache, state.selected_channel_id).isLoadingHistory = false
	}
	State_directProtocolError(state, serverID)
	State_roomEditorProtocolError(state, serverID, message)
	State_setChatStatus(state, message)
}

// Applies one decoded runtime event. Fields whose ownership moves into State are cleared on
// the event, so the caller must still run ClientTransportRuntimeEvent_deinit afterwards.
State_applyRuntimeEvent :: proc(state: ^State, event: ^ClientTransportRuntimeEvent) {
	switch event.kind {
	case .RoomChatReceived:
		State_receiveRoomChat(
			state,
			event.serverID,
			event.roomID,
			event.senderID,
			event.messageID,
			event.senderNickname,
			event.timestamp,
			event.message,
		)
	case .RoomListReceived:
		State_receiveRoomList(state, event.serverID, &event.rooms)
	case .RoomHistoryReceived:
		State_receiveRoomHistory(
			state,
			event.serverID,
			event.roomID,
			event.messages[:],
			event.hasOlder,
		)
	case .RoomMembershipChanged:
		State_roomMembershipChanged(state, event.serverID, event.roomID, event.joined)
	case .RoomEdited:
		State_roomEdited(state, event.serverID, event.roomID, &event.room)
	case .RoomDeleted:
		State_roomDeleted(state, event.serverID, event.roomID)
	case .RoomCreated:
		State_roomCreated(state, event.serverID, &event.room)
	case .ProtocolError:
		State_transportProtocolError(state, event.serverID, event.message)
	case .Connecting:
		State_connectionStarted(state, event)
	case .Connected:
		State_connectionEstablished(state, event)
	case .ConnectFailed:
		State_connectionFailed(state, event)
	case .Disconnected:
		State_connectionLost(state, event)
	case .DirectMessageReceived:
		State_receiveDirectMessage(state, event.serverID, event.directMessage)
	case .DirectHistoryReceived:
		State_receiveDirectHistory(
			state,
			event.serverID,
			event.peerUserID,
			event.directMessages[:],
			event.hasOlder,
		)
	case .UserListReceived:
		State_receiveUserList(state, event.serverID, &event.users)
	case .DirectConversationsReceived:
		State_receiveDirectConversations(state, event.serverID, &event.conversations)
	case .UserPresenceChanged:
		State_userPresenceChanged(state, event.serverID, &event.user)
	case .ReadMarkerReceived:
		State_receiveReadMarker(state, event.serverID, event.readMarker)
	case .VoiceParticipants:
		State_receiveVoiceParticipants(
			state,
			event.serverID,
			event.roomID,
			&event.voiceParticipants,
			event.voiceRecipientJoined,
		)
	case .VoiceJoinRejected:
		State_voiceJoinRejected(state, event.serverID, event.roomID, &event.message)
	case .VoiceLeft:
		State_voiceLeft(state, event.serverID, event.roomID, &event.message)
	case .None:
	}
}

// Applies queued network events from every server. The network worker does all the ENet
// servicing, so this only consumes already-decoded events and never blocks on I/O. Returns
// true when at least one event was applied.
State_drainNetworkEvents :: proc(state: ^State) -> bool {
	applied := false
	for _ in 0 ..< CHAT_RUNTIME_MAX_EVENTS_PER_FRAME {
		runtimeEvent, hasEvent := ClientNetworkWorker_popEvent(state.networkWorker)
		if !hasEvent {
			break
		}
		State_applyRuntimeEvent(state, &runtimeEvent)
		ClientTransportRuntimeEvent_deinit(&runtimeEvent)
		applied = true
	}
	return applied
}
