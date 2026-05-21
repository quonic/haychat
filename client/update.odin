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
		new_message := skald.span(m.new_value, skald.theme_dark().color.fg)
		append(&out.current_dm_chat, skald.span("\n", skald.theme_dark().color.fg)) // Add a newline after the message
		append(&out.current_dm_chat, new_message)
		out.dm_chat_draft = ""
	case .None:
	}
	return out, {}
}
