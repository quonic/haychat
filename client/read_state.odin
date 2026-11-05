package client

import "../common"
import "core:time"

// Read state (protocol 11). The server keeps a read marker per account and room and per
// account and direct conversation, and it is the source of truth for unread counts: the room
// list (RoomSummary) and the conversation list (DirectConversationSummary) arrive with each
// conversation's marker and count, and ServerReadMarker moves them, on every session of the
// account, whenever any of them marks something read.
//
// Between those, the client counts live messages itself: a message from someone else that
// arrives in a conversation that is not being viewed, with an ID above the marker, adds one.
// The user's own messages never count.
//
// "Viewed" means the conversation is the one shown in the main pane of the selected server,
// and State.windowFocused is set: only the GUI sets it, from SDL window focus, so the headless
// harness never views anything and never marks read by itself. While a conversation is
// viewed, State_updateReadMarkers marks it read up to its newest loaded message, at most once
// per READ_MARKER_MIN_INTERVAL per conversation and only when that ID moved past both the
// marker and what was last sent. The client never lowers a count on its own: the badge clears
// when the server's ServerReadMarker arrives, which is also what clears it on other devices.

READ_MARKER_MIN_INTERVAL :: time.Second

ReadMarkerSendBridge :: proc(
	transport: ^ClientServerTransport,
	kind: common.ReadMarkerKind,
	conversationID: int,
	messageID: int,
) -> bool

// Tests swap this (under readMarkerSendBridgeTestMutex) to observe sends without a session.
readMarkerSendBridge: ReadMarkerSendBridge = ClientServerTransport_markRead

// When a conversation's mark-read last went out, kept per room and per direct conversation
// cache. Cleared on every connection change, so a new session sends again.
ReadMarkerSendState :: struct {
	sentMessageID: int,
	sentAt:        time.Tick,
}

// The room's summary in the selected server's room list, or nil when the room is not listed.
// Valid until the room list next changes.
State_roomSummary :: proc(state: ^State, serverID, roomID: int) -> ^common.RoomSummary {
	index := State_serverRoomCacheIndex(state^, serverID)
	if index < 0 {
		return nil
	}
	rooms := &state.server_room_caches[index].rooms
	for roomIndex in 0 ..< len(rooms) {
		if rooms[roomIndex].id == roomID {
			return &rooms[roomIndex]
		}
	}
	return nil
}

// The conversation's summary in the server's conversation list, or nil when none is listed.
// Valid until the conversation list next changes.
State_directSummary :: proc(
	state: ^State,
	serverID, peerUserID: int,
) -> ^common.DirectConversationSummary {
	index := State_serverDirectCacheIndex(state^, serverID)
	if index < 0 {
		return nil
	}
	cache := &state.serverDirectCaches[index]
	if conversationIndex := ServerDirectCache_conversationIndex(cache^, peerUserID);
	   conversationIndex >= 0 {
		return &cache.conversations[conversationIndex]
	}
	return nil
}

// Whether the user is looking at this conversation right now (see the top of this file).
State_isConversationViewed :: proc(
	state: ^State,
	kind: common.ReadMarkerKind,
	serverID, conversationID: int,
) -> bool {
	if !state.windowFocused ||
	   state.settingsOpen ||
	   conversationID <= 0 ||
	   serverID != state.selected_server_id ||
	   State_roomEditorVisible(state) {
		return false
	}
	switch kind {
	case .Room:
		return state.selected_dm_peer_id == 0 && state.selected_channel_id == conversationID
	case .Direct:
		return state.selected_dm_peer_id == conversationID
	}
	return false
}

// The highest message ID loaded for the conversation, or 0 when nothing is loaded.
State_newestLoadedMessageID :: proc(
	state: ^State,
	kind: common.ReadMarkerKind,
	serverID, conversationID: int,
) -> int {
	switch kind {
	case .Room:
		cacheIndex := State_serverRoomCacheIndex(state^, serverID)
		if cacheIndex < 0 {
			return 0
		}
		cache := &state.server_room_caches[cacheIndex]
		if index := ServerRoomCache_roomCacheIndex(cache^, conversationID); index >= 0 {
			messages := cache.roomCaches[index].messages[:]
			if len(messages) > 0 {
				return messages[len(messages) - 1].id
			}
		}
	case .Direct:
		cacheIndex := State_serverDirectCacheIndex(state^, serverID)
		if cacheIndex < 0 {
			return 0
		}
		cache := &state.serverDirectCaches[cacheIndex]
		if index := ServerDirectCache_conversationCacheIndex(cache^, conversationID); index >= 0 {
			messages := cache.caches[index].messages[:]
			if len(messages) > 0 {
				return messages[len(messages) - 1].id
			}
		}
	}
	return 0
}

// The conversation's marker as the client knows it: 0 when the list does not show it.
State_lastReadMessageID :: proc(
	state: ^State,
	kind: common.ReadMarkerKind,
	serverID, conversationID: int,
) -> int {
	switch kind {
	case .Room:
		if summary := State_roomSummary(state, serverID, conversationID); summary != nil {
			return summary.lastReadMessageId
		}
	case .Direct:
		if summary := State_directSummary(state, serverID, conversationID); summary != nil {
			return summary.lastReadMessageId
		}
	}
	return 0
}

// The send bookkeeping of the conversation's cache, creating the cache. The pointer is valid
// until that server's caches next change.
State_readMarkerSendState :: proc(
	state: ^State,
	kind: common.ReadMarkerKind,
	serverID, conversationID: int,
) -> ^ReadMarkerSendState {
	switch kind {
	case .Room:
		cache := State_serverRoomCache(state, serverID)
		return &ServerRoomCache_roomCache(cache, conversationID).readSend
	case .Direct:
		cache := State_serverDirectCache(state, serverID)
		return &ServerDirectCache_conversationCache(cache, conversationID).readSend
	}
	return nil
}

// Sends ClientMarkRead for the conversation up to messageID and records it for the throttle.
// Returns false when nothing went out, and with reportFailure also sets the chat status to
// why. The automatic path (State_updateReadMarkers) passes false: a send that keeps failing
// would otherwise overwrite the status line about once a second, hiding the message the user
// needs, such as the connection state. The answer arrives as ServerReadMarker (or a protocol
// error); nothing changes locally until then.
State_markConversationRead :: proc(
	state: ^State,
	kind: common.ReadMarkerKind,
	serverID, conversationID, messageID: int,
	now: time.Tick,
	reportFailure := true,
) -> bool {
	if conversationID <= 0 || messageID <= 0 {
		if reportFailure {
			State_setChatStatus(state, "Nothing to mark read")
		}
		return false
	}
	transportIndex := State_selectedTransportIndexForServerID(state^, serverID)
	if transportIndex < 0 || !State_isServerConnected(state, serverID) {
		if reportFailure {
			State_setChatStatus(state, "Not connected to the server")
		}
		return false
	}
	transport := &state.serverTransports[transportIndex]
	// A failed attempt also waits out the interval, so a broken send is not retried every
	// frame; only a sent one counts as sent.
	send := State_readMarkerSendState(state, kind, serverID, conversationID)
	send.sentAt = now
	ClientNetworkWorker_lock(state.networkWorker)
	sent := readMarkerSendBridge(transport, kind, conversationID, messageID)
	reported := false
	if !sent && reportFailure && len(transport.lastError) > 0 {
		State_setChatStatus(state, transport.lastError)
		reported = true
	}
	ClientNetworkWorker_unlock(state.networkWorker)
	if !sent {
		// Whatever the status said before is not this failure's reason.
		if reportFailure && !reported {
			State_setChatStatus(state, "Failed to mark read")
		}
		return false
	}
	send = State_readMarkerSendState(state, kind, serverID, conversationID)
	send.sentMessageID = max(send.sentMessageID, messageID)
	return true
}

// Marks the viewed conversation read when it has news (see the top of this file). Call it
// after applying events and after user actions; the GUI calls it once per loop iteration.
// Returns how long until a throttled mark-read may go out, so the caller wakes up for it, or
// -1 when nothing is waiting.
State_updateReadMarkers :: proc(state: ^State, now: time.Tick) -> time.Duration {
	return State_markViewedConversation(state, now, ignoreThrottle = false)
}

// Marks the viewed conversation read right away, ignoring the throttle. The GUI calls it as the
// window loses focus, while the conversation still counts as viewed: a message that arrived
// while it was viewed did not count toward the badge, so it must not stay behind a throttled
// mark-read that would never go out once the window is unfocused.
State_flushReadMarkers :: proc(state: ^State, now: time.Tick) {
	_ = State_markViewedConversation(state, now, ignoreThrottle = true)
}

@(private = "file")
State_markViewedConversation :: proc(
	state: ^State,
	now: time.Tick,
	ignoreThrottle: bool,
) -> time.Duration {
	serverID := state.selected_server_id
	kind := common.ReadMarkerKind.Room
	conversationID := state.selected_channel_id
	if state.selected_dm_peer_id != 0 {
		kind = .Direct
		conversationID = state.selected_dm_peer_id
	}
	if !State_isConversationViewed(state, kind, serverID, conversationID) ||
	   !State_isServerConnected(state, serverID) {
		return -1
	}
	newest := State_newestLoadedMessageID(state, kind, serverID, conversationID)
	if newest <= State_lastReadMessageID(state, kind, serverID, conversationID) {
		return -1
	}
	send := State_readMarkerSendState(state, kind, serverID, conversationID)
	if newest <= send.sentMessageID {
		return -1
	}
	if !ignoreThrottle && send.sentAt != {} {
		elapsed := time.tick_diff(send.sentAt, now)
		if elapsed < READ_MARKER_MIN_INTERVAL {
			return READ_MARKER_MIN_INTERVAL - elapsed
		}
	}
	State_markConversationRead(
		state,
		kind,
		serverID,
		conversationID,
		newest,
		now,
		reportFailure = false,
	)
	return -1
}

// Whether a live message counts toward the conversation's badge: from someone else, above the
// marker, and not viewed.
readStateCountsMessage :: proc(
	state: ^State,
	kind: common.ReadMarkerKind,
	serverID, conversationID: int,
	senderID, messageID, lastReadMessageID: int,
) -> bool {
	selfUserID := State_selfUserID(state, serverID)
	return(
		senderID != selfUserID &&
		messageID > lastReadMessageID &&
		!State_isConversationViewed(state, kind, serverID, conversationID) \
	)
}

// Applies ServerReadMarker: the account marked the conversation read on this or another
// device. A marker that is not newer than the one held changes nothing.
State_receiveReadMarker :: proc(
	state: ^State,
	serverID: int,
	marker: common.ServerReadMarkerPayload,
) {
	if State_selectedTransportIndexForServerID(state^, serverID) < 0 {
		return
	}
	switch marker.kind {
	case .Room:
		if summary := State_roomSummary(state, serverID, marker.conversationId);
		   summary != nil && marker.lastReadMessageId >= summary.lastReadMessageId {
			summary.lastReadMessageId = marker.lastReadMessageId
			summary.unreadCount = marker.unreadCount
		}
	case .Direct:
		if summary := State_directSummary(state, serverID, marker.conversationId);
		   summary != nil && marker.lastReadMessageId >= summary.lastReadMessageId {
			summary.lastReadMessageId = marker.lastReadMessageId
			summary.unreadCount = marker.unreadCount
		}
	}
}

// A new session sends again: a mark-read that went out on the old one may not have arrived.
State_resetReadMarkerSends :: proc(state: ^State, serverID: int) {
	if index := State_serverRoomCacheIndex(state^, serverID); index >= 0 {
		cache := &state.server_room_caches[index]
		for roomIndex in 0 ..< len(cache.roomCaches) {
			cache.roomCaches[roomIndex].readSend = {}
		}
	}
	if index := State_serverDirectCacheIndex(state^, serverID); index >= 0 {
		cache := &state.serverDirectCaches[index]
		for conversationIndex in 0 ..< len(cache.caches) {
			cache.caches[conversationIndex].readSend = {}
		}
	}
}
