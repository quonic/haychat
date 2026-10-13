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

RoomCache_mergeMessage :: proc(cache: ^RoomCache, message: common.StoredChatMessage) {
	if message.id <= 0 {
		return
	}
	for existing in cache.messages {
		if existing.id == message.id {
			return
		}
	}
	clone := common.StoredChatMessage {
		id        = message.id,
		senderId  = message.senderId,
		roomId    = message.roomId,
		timestamp = strings.clone(message.timestamp),
		content   = strings.clone(message.content),
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
}

State_requestRoomList :: proc(state: ^State, serverID: int) {
	transportIndex := State_selectedTransportIndexForServerID(state^, serverID)
	if transportIndex < 0 {
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
	if transportIndex < 0 {
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

State_showDMs :: proc(state: ^State) {
	state.view_dms = true
	state.view_friends_list = false
	State_clearChatStatus(state)
}

State_showFriend :: proc(state: ^State, friendID: int) {
	state.view_dms = true
	state.view_friends_list = true
	state.selected_friend_id = friendID
	State_clearChatStatus(state)
}

State_switchToServer :: proc(state: ^State, serverID: int) {
	state.view_dms = false
	state.view_friends_list = false
	state.selected_server_id = serverID
	state.selected_transport_index = State_selectedTransportIndexForServerID(state^, serverID)
	state.selected_channel_id = 0
	State_requestRoomList(state, serverID)
	State_clearChatStatus(state)
}

State_switchToChannel :: proc(state: ^State, serverID: int, roomID: int) {
	state.view_dms = false
	state.view_friends_list = false
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

// Direct messages have no transport yet; the draft is kept so nothing the user typed is lost.
State_sendDirectMessage :: proc(state: ^State) {
	State_setChatStatus(state, DIRECT_MESSAGES_UNSUPPORTED_STATUS)
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

// Content is borrowed; the room cache keeps its own copy.
State_receiveRoomChat :: proc(
	state: ^State,
	serverID, roomID, senderID, messageID: int,
	timestamp, content: string,
) {
	if State_selectedTransportIndexForServerID(state^, serverID) < 0 {
		return
	}
	cache := State_serverRoomCache(state, serverID)
	roomCache := ServerRoomCache_roomCache(cache, roomID)
	RoomCache_mergeMessage(
		roomCache,
		common.StoredChatMessage {
			id = messageID,
			senderId = senderID,
			roomId = roomID,
			timestamp = timestamp,
			content = content,
		},
	)
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
	if serverID == state.selected_server_id &&
	   !ServerRoomCache_roomIsJoined(cache, state.selected_channel_id) {
		if len(cache.rooms) > 0 {
			state.selected_channel_id = cache.rooms[0].id
			State_requestRoomHistory(state, serverID, state.selected_channel_id, 0)
		} else {
			state.selected_channel_id = 0
		}
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

// Falls back to another joined room when the selected room goes away.
State_fallBackFromRemovedRoom :: proc(state: ^State, serverID, roomID: int) {
	if serverID != state.selected_server_id || roomID != state.selected_channel_id {
		return
	}
	cache := State_serverRoomCache(state, serverID)
	state.selected_channel_id = 0
	if len(cache.rooms) > 0 {
		state.selected_channel_id = cache.rooms[0].id
	}
}

State_roomMembershipChanged :: proc(state: ^State, serverID, roomID: int, joined: bool) {
	if !joined {
		ServerRoomCache_removeRoom(State_serverRoomCache(state, serverID), roomID)
		State_fallBackFromRemovedRoom(state, serverID, roomID)
	}
	State_requestRoomList(state, serverID)
}

// Takes ownership of room when it replaces a joined room and clears the caller's copy;
// otherwise the caller still owns it.
State_roomEdited :: proc(state: ^State, serverID, roomID: int, room: ^common.RoomSummary) {
	cache := State_serverRoomCache(state, serverID)
	for index in 0 ..< len(cache.rooms) {
		if cache.rooms[index].id == roomID {
			delete(cache.rooms[index].name)
			delete(cache.rooms[index].description)
			cache.rooms[index] = room^
			room^ = {}
			return
		}
	}
}

State_roomDeleted :: proc(state: ^State, serverID, roomID: int) {
	ServerRoomCache_removeRoom(State_serverRoomCache(state, serverID), roomID)
	State_fallBackFromRemovedRoom(state, serverID, roomID)
	State_requestRoomList(state, serverID)
}

// Message is borrowed. The loading flag is cleared on the selected room of the reporting
// server's cache, because protocol errors do not say which request failed.
State_transportProtocolError :: proc(state: ^State, serverID: int, message: string) {
	cache := State_serverRoomCache(state, serverID)
	if state.selected_channel_id != 0 {
		ServerRoomCache_roomCache(cache, state.selected_channel_id).isLoadingHistory = false
	}
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
	case .ProtocolError:
		State_transportProtocolError(state, event.serverID, event.message)
	case .Disconnected, .None:
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

State_newConversation :: proc(state: ^State) {
	DMLines_deinit(&state.current_dm_chat)
	state.selected_server_id = 0
	state.selected_transport_index = -1
	state.selected_channel_id = 0
	state.view_dms = true
	state.view_friends_list = false
	State_clearChatStatus(state)
}

// Adds a placeholder friend until a real add-friend flow exists.
State_addFriend :: proc(state: ^State) {
	append(
		&state.config.friends,
		Friend {
			id = len(state.config.friends) + 1,
			display_name = strings.clone("New Friend"),
			public_key = strings.clone("new_friend_public_key"),
			status = .Online,
		},
	)
}
