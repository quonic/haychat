package server

import "../common"
import "core:encoding/cbor"
import "core:strings"

// Direct messages, the user directory, and presence.
//
// A user is online while at least one of their sessions is authenticated. Presence is derived
// from state.peerSessions rather than stored, so it cannot drift from the sessions themselves:
// a ServerUserPresence goes out when the count of a user's authenticated sessions goes from
// zero to one (auth success) or from one to zero (disconnect or protocol violation).

MainRouterState_countAuthenticatedSessions :: proc(state: ^MainRouterState, userID: int) -> int {
	count := 0
	for _, session in state.peerSessions {
		if session.isAuthenticated && session.authenticatedUserID == userID {
			count += 1
		}
	}
	return count
}

MainRouterState_isUserOnline :: proc(state: ^MainRouterState, userID: int) -> bool {
	return MainRouterState_countAuthenticatedSessions(state, userID) > 0
}

// Sends a presence change to every authenticated session except excludePeerID, which is the
// session that caused the change: a newly authenticated session knows it is online, and an
// ending session is about to go away.
MainRouterState_broadcastPresence :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	userID: int,
	nickname: string,
	isOnline: bool,
	excludePeerID: u32,
) {
	payload := common.ServerUserPresencePayload {
		userId   = userID,
		nickname = nickname,
		isOnline = isOnline,
	}
	for recipientPeerID, recipientSession in state.peerSessions {
		if recipientSession.isAuthenticated && recipientPeerID != excludePeerID {
			MainRouterState_sendPeerMessage(
				pm,
				state,
				recipientPeerID,
				.ServerUserPresence,
				payload,
			)
		}
	}
}

// Call after a session of userID stopped counting as authenticated (it was removed or failed).
// Announces the user offline when that was their last authenticated session.
MainRouterState_noteSessionEnded :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	userID: int,
	nickname: string,
) {
	if userID <= 0 || MainRouterState_isUserOnline(state, userID) {
		return
	}
	MainRouterState_broadcastPresence(pm, state, userID, nickname, false, peerID)
}

// Handles NetworkPeerDisconnected: drops the peer's session and pending requests, then
// announces its user offline if no other session of that user is still authenticated.
MainRouterState_handlePeerDisconnected :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
) {
	session, ok := MainRouterState_getPeerSession(state, peerID)
	wasAuthenticated := ok && session.isAuthenticated
	userID := session.authenticatedUserID
	// The session's nickname is freed with the session, so keep a copy for the broadcast.
	nickname: string
	if wasAuthenticated {
		nickname = strings.clone(session.clientNickname)
	}
	defer delete(nickname)

	delete_key(&state.connectedPeers, peerID)
	MainRouterState_removePendingRequestsForPeer(state, peerID)
	// While the session still exists, so the remaining participants keep their nicknames and
	// the departing session is skipped. The relay already forgot the peer on the network
	// thread.
	MainRouterState_voiceLeave(pm, state, peerID, skipSelf = true)
	MainRouterState_removePeerSession(state, peerID)
	if wasAuthenticated {
		MainRouterState_noteSessionEnded(pm, state, peerID, userID, nickname)
	}
}

MainRouterState_authenticatedUserID :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	unauthenticatedMessage: string,
) -> (
	int,
	bool,
) {
	session, ok := MainRouterState_getPeerSession(state, peerID)
	if !ok || !session.isAuthenticated {
		MainRouterState_sendProtocolError(pm, state, peerID, unauthenticatedMessage)
		return 0, false
	}
	return session.authenticatedUserID, true
}

MainRouterState_handleClientDirectMessage :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	payload: []u8,
) {
	req: common.ClientDirectMessagePayload
	err := cbor.unmarshal(payload, &req)
	defer delete(req.content)
	if err != nil {
		MainRouterState_sendProtocolError(pm, state, peerID, "Invalid ClientDirectMessage payload")
		return
	}
	if req.recipientUserId <= 0 ||
	   len(req.content) == 0 ||
	   len(req.content) > common.CHAT_MESSAGE_MAX_BYTES {
		MainRouterState_sendProtocolError(pm, state, peerID, "Invalid direct message")
		return
	}
	senderID, ok := MainRouterState_authenticatedUserID(
		pm,
		state,
		peerID,
		"Unauthenticated direct message",
	)
	if !ok {
		return
	}
	if req.recipientUserId == senderID {
		MainRouterState_sendProtocolError(
			pm,
			state,
			peerID,
			"Cannot send a direct message to yourself",
		)
		return
	}

	MainRouterState_enqueueChannelDatabaseRequest(
		pm,
		state,
		peerID,
		common.DatabasePostDirectMessageRequest {
			senderId = senderID,
			recipientId = req.recipientUserId,
			content = strings.clone(req.content),
		},
		PendingDBRequest{requestType = .PostDirectMessage, targetUserID = req.recipientUserId},
	)
}

MainRouterState_handleClientFetchDirectHistory :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	payload: []u8,
) {
	req: common.ClientFetchDirectHistoryPayload
	if cbor.unmarshal(payload, &req) != nil ||
	   req.peerUserId <= 0 ||
	   req.beforeMessageID < 0 ||
	   req.limit < 1 ||
	   req.limit > common.HISTORY_PAGE_MAX_MESSAGES {
		MainRouterState_sendProtocolError(pm, state, peerID, "Invalid direct history request")
		return
	}
	userID, ok := MainRouterState_authenticatedUserID(
		pm,
		state,
		peerID,
		"Unauthenticated direct history request",
	)
	if !ok {
		return
	}
	if req.peerUserId == userID {
		MainRouterState_sendProtocolError(
			pm,
			state,
			peerID,
			"Cannot fetch direct history with yourself",
		)
		return
	}

	MainRouterState_enqueueChannelDatabaseRequest(
		pm,
		state,
		peerID,
		common.DatabaseDirectHistoryRequest {
			userId = userID,
			peerUserId = req.peerUserId,
			beforeMessageID = req.beforeMessageID,
			limit = req.limit,
		},
		PendingDBRequest{requestType = .GetDirectHistory, targetUserID = req.peerUserId},
	)
}

MainRouterState_handleClientListDirectConversations :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	payload: []u8,
) {
	req: common.ClientListDirectConversationsPayload
	if cbor.unmarshal(payload, &req) != nil {
		MainRouterState_sendProtocolError(
			pm,
			state,
			peerID,
			"Invalid ClientListDirectConversations payload",
		)
		return
	}
	userID, ok := MainRouterState_authenticatedUserID(
		pm,
		state,
		peerID,
		"Unauthenticated direct conversation list request",
	)
	if !ok {
		return
	}
	MainRouterState_enqueueChannelDatabaseRequest(
		pm,
		state,
		peerID,
		common.DatabaseDirectConversationListRequest{userId = userID},
		PendingDBRequest{requestType = .ListDirectConversations},
	)
}

MainRouterState_handleClientListUsers :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	payload: []u8,
) {
	req: common.ClientListUsersPayload
	if cbor.unmarshal(payload, &req) != nil {
		MainRouterState_sendProtocolError(pm, state, peerID, "Invalid ClientUserList payload")
		return
	}
	if _, ok := MainRouterState_authenticatedUserID(
		pm,
		state,
		peerID,
		"Unauthenticated user list request",
	); !ok {
		return
	}
	MainRouterState_enqueueChannelDatabaseRequest(
		pm,
		state,
		peerID,
		common.DatabaseUserDirectoryRequest{},
		PendingDBRequest{requestType = .ListUsers},
	)
}

// The message is already stored, so it goes to every live session of both users, the sending
// session included: that echo is how the sender learns the message ID and timestamp.
MainRouterState_handlePostDirectMessageResult :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	request: PendingDBRequest,
	response: common.DatabaseQueryResponse,
) {
	posted, postedOK := response.result.(common.DatabasePostDirectMessageResult)
	if MainRouterState_databaseFailed(pm, state, request.peerID, response, postedOK) {
		return
	}
	if !posted.recipientExists {
		MainRouterState_sendProtocolError(
			pm,
			state,
			request.peerID,
			"Unknown direct message recipient",
		)
		return
	}
	stored := posted.storedMessage
	directPayload := common.ServerDirectMessagePayload {
		id                = stored.id,
		senderId          = stored.senderId,
		senderNickname    = stored.senderNickname,
		recipientId       = stored.recipientId,
		recipientNickname = stored.recipientNickname,
		timestamp         = stored.timestamp,
		content           = stored.content,
	}
	for recipientPeerID, recipientSession in state.peerSessions {
		if recipientSession.isAuthenticated &&
		   (recipientSession.authenticatedUserID == stored.senderId ||
				   recipientSession.authenticatedUserID == stored.recipientId) {
			MainRouterState_sendPeerMessage(
				pm,
				state,
				recipientPeerID,
				.ServerDirectMessage,
				directPayload,
			)
		}
	}
}

MainRouterState_handleDirectHistoryResult :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	request: PendingDBRequest,
	response: common.DatabaseQueryResponse,
) {
	history, historyOK := response.result.(common.DatabaseDirectHistoryResult)
	if MainRouterState_databaseFailed(pm, state, request.peerID, response, historyOK) {
		return
	}
	if !history.peerExists {
		MainRouterState_sendProtocolError(pm, state, request.peerID, "Unknown user")
		return
	}
	MainRouterState_sendPeerMessage(
		pm,
		state,
		request.peerID,
		.ServerDirectHistory,
		common.ServerDirectHistoryPayload {
			peerUserId = request.targetUserID,
			messages = history.messages,
			hasOlder = history.hasOlder,
		},
	)
}

MainRouterState_handleDirectConversationListResult :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	request: PendingDBRequest,
	response: common.DatabaseQueryResponse,
) {
	list, listOK := response.result.(common.DatabaseDirectConversationListResult)
	if MainRouterState_databaseFailed(pm, state, request.peerID, response, listOK) {
		return
	}
	MainRouterState_sendPeerMessage(
		pm,
		state,
		request.peerID,
		.ServerDirectConversations,
		common.ServerDirectConversationsPayload{conversations = list.conversations},
	)
}

// The database lists accounts; whether each is online is only known here, from the sessions.
MainRouterState_handleUserDirectoryResult :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	request: PendingDBRequest,
	response: common.DatabaseQueryResponse,
) {
	directory, directoryOK := response.result.(common.DatabaseUserDirectoryResult)
	if MainRouterState_databaseFailed(pm, state, request.peerID, response, directoryOK) {
		return
	}
	onlineUserIDs := make(map[int]bool)
	defer delete(onlineUserIDs)
	for _, session in state.peerSessions {
		if session.isAuthenticated {
			onlineUserIDs[session.authenticatedUserID] = true
		}
	}
	// The response still owns the array; this only sets flags in place before it is freed.
	for &user in directory.users {
		user.isOnline = onlineUserIDs[user.id]
	}
	MainRouterState_sendPeerMessage(
		pm,
		state,
		request.peerID,
		.ServerUserList,
		common.ServerUserListPayload{users = directory.users},
	)
}
