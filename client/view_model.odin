package client

import "core:fmt"

// View models are pure snapshots of State that the immediate-mode view draws from. Keeping
// them free of SDL lets tests check what the UI would show without opening a window.

TranscriptLine :: struct {
	messageID:   int,
	senderLabel: string, // Borrowed from the room cache, or allocated with the view allocator
	isSelf:      bool,
	content:     string, // Borrowed from the room cache
}

RoomView :: struct {
	hasSelectedRoom:  bool,
	hasOlder:         bool,
	isLoadingHistory: bool,
	lines:            []TranscriptLine,
	status:           string, // Borrowed from State
}

// Builds the selected room's view without creating caches. Lines borrow message content from
// the room cache, so the result is only valid until State next changes.
buildRoomView :: proc(state: ^State, allocator := context.temp_allocator) -> (view: RoomView) {
	view.status = state.chat_status_message
	serverCacheIndex := State_serverRoomCacheIndex(state^, state.selected_server_id)
	if serverCacheIndex < 0 {
		return
	}
	serverCache := &state.server_room_caches[serverCacheIndex]
	view.hasSelectedRoom = ServerRoomCache_roomIsJoined(serverCache, state.selected_channel_id)
	roomCacheIndex := ServerRoomCache_roomCacheIndex(serverCache^, state.selected_channel_id)
	if roomCacheIndex < 0 {
		return
	}
	roomCache := &serverCache.roomCaches[roomCacheIndex]
	view.hasOlder = roomCache.hasOlder
	view.isLoadingHistory = roomCache.isLoadingHistory

	// authenticatedUserID is written during startup auth, before the network worker starts,
	// so reading it here without the worker lock is safe.
	selfUserID := 0
	if transport, ok := State_selectedTransport(state); ok {
		selfUserID = transport.authenticatedUserID
	}

	lines := make([]TranscriptLine, len(roomCache.messages), allocator)
	for message, index in roomCache.messages {
		isSelf := selfUserID != 0 && message.senderId == selfUserID
		// A sender without a user row has no nickname; fall back to the user ID.
		senderLabel := "You"
		if !isSelf {
			senderLabel = message.senderNickname
			if len(senderLabel) == 0 {
				senderLabel = fmt.aprintf("User %d", message.senderId, allocator = allocator)
			}
		}
		lines[index] = TranscriptLine {
			messageID   = message.id,
			senderLabel = senderLabel,
			isSelf      = isSelf,
			content     = message.content,
		}
	}
	view.lines = lines
	return
}

// Status indicator shown before a friend's name in the DM list.
friendStatusLabel :: proc(status: FriendStatus) -> string {
	switch status {
	case .Online:
		return "🟢"
	case .Offline:
		return "🔴"
	case .Idle:
		return "🟡"
	case .DoNotDisturb:
		return "⛔"
	case .Busy, .Away:
		return "⚪"
	}
	return "⚪"
}
