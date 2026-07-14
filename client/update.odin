package client

import "../common"
import "core:fmt"
import "core:strings"
import "shared:skald"

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
		id = message.id,
		senderId = message.senderId,
		roomId = message.roomId,
		timestamp = strings.clone(message.timestamp),
		content = strings.clone(message.content),
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
	if ClientServerTransport_requestRoomHistory(transport, roomID, beforeMessageID, 50) {
		roomCache.isLoadingHistory = true
	} else if len(transport.lastError) > 0 {
		State_setChatStatus(state, transport.lastError)
	}
}

State_appendChannelChatMessage :: proc(state: ^State, senderID: int, message: string) {
	th := skald.theme_dark()
	senderLabel := fmt.tprintf("User %d", senderID)
	senderColor := th.color.fg

	if transport, ok := State_selectedTransport(state);
	   ok && senderID != 0 && transport.authenticatedUserID == senderID {
		senderLabel = "You"
		senderColor = th.color.primary
	}

	if len(state.current_chat_messages) > 0 {
		append(&state.current_chat_messages, skald.span("\n", th.color.fg))
	}
	append(
		&state.current_chat_messages,
		skald.span_bold(strings.concatenate({senderLabel, ": "}), senderColor),
	)
	append(&state.current_chat_messages, skald.span(message, th.color.fg))
}

State_clearVisibleRoomTranscript :: proc(state: ^State) {
	state.current_chat_messages = [dynamic]skald.Text_Span{}
}

update :: proc(s: State, m: Msg) -> (State, skald.Command(Msg)) {
	out := s
	switch m.kind {
	case .SwitchToFriendsList:
		out.view_friends_list = true
		out.view_dms = true
		State_clearChatStatus(&out)
	case .SwitchToDMs:
		out.view_dms = true
		out.view_friends_list = false
		State_clearChatStatus(&out)
	case .SwitchToServer:
		out.view_dms = false
		out.view_friends_list = false
		out.selected_server_id = m.id
		out.selected_transport_index = State_selectedTransportIndexForServerID(out, m.id)
		out.selected_channel_id = 0
		State_clearVisibleRoomTranscript(&out)
		State_requestRoomList(&out, m.id)
		State_clearChatStatus(&out)
	case .SwitchToChannel:
		out.view_dms = false
		out.view_friends_list = false
		out.selected_server_id = m.id
		out.selected_transport_index = State_selectedTransportIndexForServerID(out, m.id)
		if m.channel_id == 0 {
			out.selected_channel_id = common.GENERAL_ROOM_ID
		} else {
			out.selected_channel_id = m.channel_id
		}
		State_clearVisibleRoomTranscript(&out)
		cache := State_serverRoomCache(&out, out.selected_server_id)
		roomCache := ServerRoomCache_roomCache(cache, out.selected_channel_id)
		if !roomCache.initialHistoryLoaded {
			State_requestRoomHistory(&out, out.selected_server_id, out.selected_channel_id, 0)
		}
		State_clearChatStatus(&out)
	case .UpdateWindowSize:
		out.window_width = f32(m.window_vector.x)
		out.window_height = f32(m.window_vector.y)
	case .UpdateChatInputValue:
		out.dm_chat_draft, _ = strings.replace(strings.clone(m.new_value), "\t", "    ", -1) // Replace tabs with spaces for consistent formatting in the chat input
	case .UpdateChannelChatInputValue:
		out.chat_input_draft, _ = strings.replace(strings.clone(m.new_value), "\t", "    ", -1) // Replace tabs with spaces for consistent formatting in the chat input
		if out.selected_channel_id != 0 {
			cache := State_serverRoomCache(&out, out.selected_server_id)
			roomCache := ServerRoomCache_roomCache(cache, out.selected_channel_id)
			delete(roomCache.draft)
			roomCache.draft = strings.clone(out.chat_input_draft)
		}
	case .SendChatMessage:
		State_setChatStatus(&out, DIRECT_MESSAGES_UNSUPPORTED_STATUS)
	case .SendChannelChatMessage:
		new_message, _ := strings.replace(strings.clone(m.new_value), "\t", "    ", -1)
		if out.selected_channel_id == 0 {
			State_setChatStatus(&out, "No channel selected")
			break
		}
		transport, transportOK := State_selectedTransport(&out)
		if !transportOK {
			State_setChatStatus(&out, "No server transport selected")
			break
		}
		if transport.serverID != out.selected_server_id {
			State_setChatStatus(&out, "Selected transport does not match the active server")
			break
		}
		if roomChatSendBridge(transport, out.selected_channel_id, new_message) {
			out.chat_input_draft = ""
			cache := State_serverRoomCache(&out, out.selected_server_id)
			roomCache := ServerRoomCache_roomCache(cache, out.selected_channel_id)
			delete(roomCache.draft)
			roomCache.draft = ""
			State_clearChatStatus(&out)
		} else if len(transport.lastError) > 0 {
			State_setChatStatus(&out, transport.lastError)
		} else {
			State_setChatStatus(&out, "Failed to send room chat message")
		}
	case .RecieveChatMessage:
		// Handle receiving a new chat message, such as by appending it to the current DM chat
		sender_name := "Friend" // In a real implementation, you would look up the sender's name based on the message data
		append(&out.current_dm_chat, skald.span("\n", skald.theme_dark().color.fg)) // Newline
		append(
			&out.current_dm_chat,
			skald.span_bold(strings.concatenate({sender_name, ": "}), skald.theme_dark().color.fg),
		)
		new_message, _ := strings.replace(strings.clone(m.new_value), "\t", "    ", -1) // Replace tabs with spaces for consistent formatting in the chat message
		append(&out.current_dm_chat, skald.span(new_message, skald.theme_dark().color.fg))
	case .RecieveChannelChatMessage:
		transportIndex := State_selectedTransportIndexForServerID(out, m.id)
		if transportIndex < 0 {
			break
		}
		cache := State_serverRoomCache(&out, m.id)
		roomCache := ServerRoomCache_roomCache(cache, m.channel_id)
		RoomCache_mergeMessage(
			roomCache,
			common.StoredChatMessage {
				id = m.message_id,
				senderId = m.sender_id,
				roomId = m.channel_id,
				timestamp = m.timestamp,
				content = m.new_value,
			},
		)
		if m.id == out.selected_server_id && m.channel_id == out.selected_channel_id {
			new_message, _ := strings.replace(strings.clone(m.new_value), "\t", "    ", -1)
			State_appendChannelChatMessage(&out, m.sender_id, new_message)
		}
		State_clearChatStatus(&out)
	case .RecieveRoomList:
		cache := State_serverRoomCache(&out, m.id)
		for room in cache.rooms {
			delete(room.name)
			delete(room.description)
		}
		delete(cache.rooms)
		cache.rooms = m.rooms
		cache.roomsLoaded = true
		cache.roomsLoading = false
		for index := len(cache.roomCaches) - 1; index >= 0; index -= 1 {
			if !ServerRoomCache_roomIsJoined(cache, cache.roomCaches[index].roomID) {
				RoomCache_deinit(&cache.roomCaches[index])
				unordered_remove(&cache.roomCaches, index)
			}
		}
		if m.id == out.selected_server_id && !ServerRoomCache_roomIsJoined(cache, out.selected_channel_id) {
			if len(cache.rooms) > 0 {
				out.selected_channel_id = cache.rooms[0].id
				State_requestRoomHistory(&out, m.id, out.selected_channel_id, 0)
			} else {
				out.selected_channel_id = 0
			}
		}
	case .RecieveRoomHistory:
		cache := State_serverRoomCache(&out, m.id)
		roomCache := ServerRoomCache_roomCache(cache, m.channel_id)
		for message in m.messages {
			RoomCache_mergeMessage(roomCache, message)
			delete(message.timestamp)
			delete(message.content)
		}
		delete(m.messages)
		roomCache.initialHistoryLoaded = true
		roomCache.isLoadingHistory = false
		roomCache.hasOlder = m.has_older
	case .LoadOlderRoomHistory:
		cache := State_serverRoomCache(&out, out.selected_server_id)
		roomCache := ServerRoomCache_roomCache(cache, out.selected_channel_id)
		if out.selected_channel_id != 0 && roomCache.hasOlder && roomCache.oldestMessageID > 0 {
			State_requestRoomHistory(
				&out,
				out.selected_server_id,
				out.selected_channel_id,
				roomCache.oldestMessageID,
			)
		}
	case .RoomMembershipChanged:
		if !m.joined {
			cache := State_serverRoomCache(&out, m.id)
			ServerRoomCache_removeRoom(cache, m.channel_id)
			if m.id == out.selected_server_id && m.channel_id == out.selected_channel_id {
				out.selected_channel_id = 0
				if len(cache.rooms) > 0 {
					out.selected_channel_id = cache.rooms[0].id
				}
			}
		}
		State_requestRoomList(&out, m.id)
	case .RoomEdited:
		cache := State_serverRoomCache(&out, m.id)
		roomUpdated := false
		for index in 0 ..< len(cache.rooms) {
			if cache.rooms[index].id == m.channel_id {
				delete(cache.rooms[index].name)
				delete(cache.rooms[index].description)
				cache.rooms[index] = m.room
				roomUpdated = true
				break
			}
		}
		if !roomUpdated {
			delete(m.room.name)
			delete(m.room.description)
		}
	case .RoomDeleted:
		cache := State_serverRoomCache(&out, m.id)
		ServerRoomCache_removeRoom(cache, m.channel_id)
		if m.id == out.selected_server_id && m.channel_id == out.selected_channel_id {
			out.selected_channel_id = 0
			if len(cache.rooms) > 0 {
				out.selected_channel_id = cache.rooms[0].id
			}
		}
		State_requestRoomList(&out, m.id)
	case .TransportProtocolError:
		cache := State_serverRoomCache(&out, m.id)
		if out.selected_channel_id != 0 {
			ServerRoomCache_roomCache(cache, out.selected_channel_id).isLoadingHistory = false
		}
		State_setChatStatus(&out, m.new_value)
	case .New_Conversation:
		// Handle starting a new conversation, such as by clearing the current DM chat and resetting the selected server or friend
		out.current_dm_chat = [dynamic]skald.Text_Span{}
		out.selected_server_id = 0
		out.selected_transport_index = -1
		out.selected_channel_id = 0
		out.view_dms = true
		out.view_friends_list = false
		State_clearChatStatus(&out)
	case .AddFriend:
		// Handle adding a new friend, such as by showing a dialog to enter the friend's information and then updating the config with the new friend
		// For this example, we'll just add a dummy friend to demonstrate the functionality
		new_friend := Friend {
			id           = len(s.config.friends) + 1,
			display_name = "New Friend",
			public_key   = "new_friend_public_key",
			status       = .Online, // Set the new friend's status to Online for demonstration purposes
		}
		append(&out.config.friends, new_friend)
	case .None:
	}
	return out, {}
}
