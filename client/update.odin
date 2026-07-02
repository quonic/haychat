package client

import "core:os"
import "core:strings"
import "shared:skald"

update :: proc(s: State, m: Msg) -> (State, skald.Command(Msg)) {
	out := s
	switch m.kind {
	case .SwitchToFriendsList:
		out.view_friends_list = true
		out.view_dms = true
	case .SwitchToDMs:
		out.view_dms = true
		out.view_friends_list = false
	case .SwitchToServer:
		out.view_dms = false
		out.view_friends_list = false
		out.selected_server_id = m.id
		out.selected_transport_index = State_selectedTransportIndexForServerID(out, m.id)
	case .SwitchToChannel:
		out.view_dms = false
		out.view_friends_list = false
		out.selected_server_id = m.id
		out.selected_transport_index = State_selectedTransportIndexForServerID(out, m.id)
		out.selected_channel_id = m.channel_id
	case .UpdateWindowSize:
		out.window_width = f32(m.window_vector.x)
		out.window_height = f32(m.window_vector.y)
	case .UpdateChatInputValue:
		out.dm_chat_draft, _ = strings.replace(strings.clone(m.new_value), "\t", "    ", -1) // Replace tabs with spaces for consistent formatting in the chat input
	case .UpdateChannelChatInputValue:
		out.chat_input_draft, _ = strings.replace(strings.clone(m.new_value), "\t", "    ", -1) // Replace tabs with spaces for consistent formatting in the chat input
	case .SendChatMessage:
		// Handle sending chat message, such as by appending the new message to the current DM chat and clearing the chat input draft
		append(&out.current_dm_chat, skald.span("\n", skald.theme_dark().color.fg)) // Newline
		append(
			&out.current_dm_chat,
			skald.span_bold(
				strings.concatenate({s.config.display_name, ": "}),
				skald.theme_dark().color.fg,
			),
		)
		new_message, _ := strings.replace(strings.clone(m.new_value), "\t", "    ", -1) // Replace tabs with spaces for consistent formatting in the chat message
		append(&out.current_dm_chat, skald.span(new_message, skald.theme_dark().color.fg))
		out.dm_chat_draft = ""
	case .SendChannelChatMessage:
		// Handle sending channel chat message, such as by appending the new message to the current chat messages and clearing the chat input draft
		append(&out.current_chat_messages, skald.span("\n", skald.theme_dark().color.fg)) // Newline
		append(
			&out.current_chat_messages,
			skald.span_bold(
				strings.concatenate({s.config.display_name, ": "}),
				skald.theme_dark().color.fg,
			),
		)
		new_message, _ := strings.replace(strings.clone(m.new_value), "\t", "    ", -1) // Replace tabs with spaces for consistent formatting in the chat message
		append(&out.current_chat_messages, skald.span(new_message, skald.theme_dark().color.fg))
		out.chat_input_draft = ""
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
		// Handle receiving a new channel chat message, such as by appending it to the current chat messages
		sender_name := "Friend" // In a real implementation, you would look up the sender's name based on the message data
		append(&out.current_chat_messages, skald.span("\n", skald.theme_dark().color.fg)) // Newline
		append(
			&out.current_chat_messages,
			skald.span_bold(strings.concatenate({sender_name, ": "}), skald.theme_dark().color.fg),
		)
		new_message, _ := strings.replace(strings.clone(m.new_value), "\t", "    ", -1) // Replace tabs with spaces for consistent formatting in the chat message
		append(&out.current_chat_messages, skald.span(new_message, skald.theme_dark().color.fg))
	case .New_Conversation:
		// Handle starting a new conversation, such as by clearing the current DM chat and resetting the selected server or friend
		out.current_dm_chat = [dynamic]skald.Text_Span{}
		out.selected_server_id = 0
		out.selected_transport_index = -1
		out.view_dms = true
		out.view_friends_list = false
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
