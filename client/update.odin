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
	case .None:
	}
	return out, {}
}
