package server

import "../common"
import "core:encoding/cbor"

// Read markers (protocol 11). A client marks a room or a direct conversation read up to a
// message ID; the database moves the marker forward in one statement (database_read_markers.odin)
// and the router tells every live session of that account, the asking one included, so a read
// on one device clears the badge on the others. A refused mark-read (not a member, unknown
// peer) is a ServerProtocolError, never a protocol violation: a room can disappear between the
// client's last room list and its mark-read, and that must not end the session.

MainRouterState_handleClientMarkRead :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	payload: []u8,
) {
	req: common.ClientMarkReadPayload
	if cbor.unmarshal(payload, &req) != nil ||
	   (req.kind != .Room && req.kind != .Direct) ||
	   req.conversationId <= 0 ||
	   req.messageId <= 0 {
		MainRouterState_sendProtocolError(pm, state, peerID, "Invalid mark-read request")
		return
	}
	userID, ok := MainRouterState_authenticatedUserID(
		pm,
		state,
		peerID,
		"Unauthenticated mark-read request",
	)
	if !ok {
		return
	}
	if req.kind == .Direct && req.conversationId == userID {
		MainRouterState_sendProtocolError(
			pm,
			state,
			peerID,
			"Cannot mark a conversation with yourself read",
		)
		return
	}

	pending := PendingDBRequest {
		requestType    = .MarkRead,
		readMarkerKind = req.kind,
	}
	if req.kind == .Room {
		pending.roomID = req.conversationId
	} else {
		pending.targetUserID = req.conversationId
	}
	MainRouterState_enqueueChannelDatabaseRequest(
		pm,
		state,
		peerID,
		common.DatabaseMarkReadRequest {
			userId = userID,
			kind = req.kind,
			conversationId = req.conversationId,
			messageId = req.messageId,
		},
		pending,
	)
}

MainRouterState_handleMarkReadResult :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	request: PendingDBRequest,
	response: common.DatabaseQueryResponse,
) {
	marked, markedOK := response.result.(common.DatabaseMarkReadResult)
	if MainRouterState_databaseFailed(pm, state, request.peerID, response, markedOK) {
		return
	}
	if !marked.allowed {
		message := request.readMarkerKind == .Room ? "Not a room member" : "Unknown user"
		MainRouterState_sendProtocolError(pm, state, request.peerID, message)
		return
	}
	if !marked.changed {
		return
	}
	// A disconnect drops the peer's pending requests, so the asking session is normally still
	// here; the check only guards a session that stopped being authenticated meanwhile.
	session, sessionOK := MainRouterState_getPeerSession(state, request.peerID)
	if !sessionOK || !session.isAuthenticated {
		return
	}
	conversationID := request.roomID
	if request.readMarkerKind == .Direct {
		conversationID = request.targetUserID
	}
	MainRouterState_sendMessageToUserID(
		pm,
		state,
		session.authenticatedUserID,
		.ServerReadMarker,
		common.ServerReadMarkerPayload {
			kind = request.readMarkerKind,
			conversationId = conversationID,
			lastReadMessageId = marked.lastReadMessageId,
			unreadCount = marked.unreadCount,
		},
	)
}
