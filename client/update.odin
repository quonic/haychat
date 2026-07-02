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
		out.selected_channel_id = common.GENERAL_ROOM_ID
		State_clearVisibleRoomTranscript(&out)
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
		State_clearChatStatus(&out)
	case .UpdateWindowSize:
		out.window_width = f32(m.window_vector.x)
		out.window_height = f32(m.window_vector.y)
	case .UpdateChatInputValue:
		out.dm_chat_draft, _ = strings.replace(strings.clone(m.new_value), "\t", "    ", -1) // Replace tabs with spaces for consistent formatting in the chat input
	case .UpdateChannelChatInputValue:
		out.chat_input_draft, _ = strings.replace(strings.clone(m.new_value), "\t", "    ", -1) // Replace tabs with spaces for consistent formatting in the chat input
	case .SendChatMessage:
		State_setChatStatus(&out, DIRECT_MESSAGES_UNSUPPORTED_STATUS)
	case .SendChannelChatMessage:
		new_message, _ := strings.replace(strings.clone(m.new_value), "\t", "    ", -1)
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
		if m.id != out.selected_server_id || m.channel_id != out.selected_channel_id {
			break
		}
		transport, transportOK := State_selectedTransport(&out)
		if !transportOK || transport.serverID != m.id {
			break
		}
		new_message, _ := strings.replace(strings.clone(m.new_value), "\t", "    ", -1)
		State_appendChannelChatMessage(&out, m.sender_id, new_message)
		State_clearChatStatus(&out)
	case .TransportProtocolError:
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
