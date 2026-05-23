package client

import "core:os"
import "core:strings"
import "shared:skald"

update :: proc(s: State, m: Msg) -> (State, skald.Command(Msg)) {
	out := s
	switch m.kind {
	case .SwitchToFriendsList:
		out.view_friends_list = true
	case .SwitchToDMs:
		out.view_dms = true
	case .SwitchToServer:
		out.view_dms = false
		out.selected_server_id = m.id
	case .UpdateWindowSize:
		out.window_width = f32(m.window_vector.x)
		out.window_height = f32(m.window_vector.y)
	case .UpdateChatInputValue:
		out.dm_chat_draft = strings.clone(m.new_value)
	case .SendChatMessage:
		// Handle sending chat message, such as by appending the new message to the current DM chat and clearing the chat input draft
		new_message := skald.span(
			strings.concatenate({"\n", s.config.display_name, ": ", m.new_value}),
			skald.theme_dark().color.fg,
		)
		append(&out.current_dm_chat, new_message)
		out.dm_chat_draft = ""
	case .RecieveChatMessage:
		// Handle receiving a new chat message, such as by appending it to the current DM chat
		sender_name := "Friend" // In a real implementation, you would look up the sender's name based on the message data
		new_message := skald.span(
			strings.concatenate({"\n", sender_name, ": ", m.new_value}),
			skald.theme_dark().color.fg,
		)
		append(&out.current_dm_chat, new_message)
	case .New_Conversation:
		// Handle starting a new conversation, such as by clearing the current DM chat and resetting the selected server or friend
		out.current_dm_chat = [dynamic]skald.Text_Span{}
		out.selected_server_id = 0
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
