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
	// Protocol 25 (D17): only to sessions that may see the account (router_registration.odin).
	MainRouterState_sendAboutUser(
		pm,
		state,
		userID,
		MainRouterState_userIsRestricted(state, userID),
		excludePeerID,
		MainRouterVisibilityPayload {
			presence = {userId = userID, nickname = nickname, isOnline = isOnline},
		},
	)
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
	MainRouterState_attachmentsEndSession(pm, state, peerID)
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

// ClientDirectMessage, the signed plaintext fallback (protocol 17, e2ee-design.md 4.6): the
// signature must verify against the session's own identity key over this server's identity
// key, both user IDs, the client message ID and the content, so the server cannot be handed a
// message the sender did not write, and the stored row can be checked by both clients later.
// An unsigned message (every client before protocol 17) is refused: no such client can connect
// after the protocol bump anyway.
//
// Fixed-size byte fields decode through CBOR's temporary allocator, so it is the heap here.
MainRouterState_handleClientDirectMessage :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	payload: []u8,
) {
	req: common.ClientDirectMessagePayload
	err := cbor.unmarshal(payload, &req, temp_allocator = context.allocator)
	defer delete(req.content)
	if err != nil {
		MainRouterState_sendProtocolError(pm, state, peerID, "Invalid ClientDirectMessage payload")
		return
	}
	if req.recipientUserId <= 0 ||
	   len(req.content) == 0 ||
	   len(req.content) > common.CHAT_MESSAGE_MAX_BYTES ||
	   !common.clientMessageIDIsSet(req.clientMessageId) {
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
	session, _ := MainRouterState_getPeerSession(state, peerID)
	if !common.verifyPlaintextDirectMessage(
		common.PlaintextDirectMessageFields {
			serverIdentityPublicKey = state.serverIdentityPublicKey,
			senderUserID = senderID,
			recipientUserID = req.recipientUserId,
			clientMessageID = req.clientMessageId,
		},
		req.content,
		session.clientIdentityPublicKey,
		req.signature,
	) {
		MainRouterState_sendProtocolError(
			pm,
			state,
			peerID,
			common.DIRECT_MESSAGE_SIGNATURE_INVALID_MESSAGE,
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
			clientMessageId = req.clientMessageId,
			signature = req.signature,
		},
		PendingDBRequest{requestType = .PostDirectMessage, targetUserID = req.recipientUserId},
	)
}

// ClientSealedDirectMessage (protocol 17, e2ee-design.md 4.5): the router checks what it can
// without the database (the shape, the size and the envelope's structure), and the database
// worker checks the signature against both accounts' identity keys before it stores the
// envelope byte for byte (databaseCheckSealedDirectMessage). The recipient's key lives only in
// the database, so that check runs there, next to the insert that requires the same key.
MainRouterState_handleClientSealedDirectMessage :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	payload: []u8,
) {
	req: common.ClientSealedDirectMessagePayload
	err := cbor.unmarshal(payload, &req, temp_allocator = context.allocator)
	defer common.ClientSealedDirectMessagePayload_deinit(&req)
	if err != nil {
		MainRouterState_sendProtocolError(
			pm,
			state,
			peerID,
			"Invalid ClientSealedDirectMessage payload",
		)
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
	if req.recipientUserId <= 0 ||
	   !common.clientMessageIDIsSet(req.clientMessageId) ||
	   len(req.envelope) == 0 ||
	   len(req.envelope) > common.SEALED_ENVELOPE_MAX_BYTES {
		MainRouterState_sendProtocolError(
			pm,
			state,
			peerID,
			common.SEALED_DIRECT_MESSAGE_INVALID_MESSAGE,
		)
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
	if envelope, decodeErr := common.decodeSealedEnvelope(req.envelope);
	   decodeErr != .None || envelope.kind != .DirectMessage || envelope.wrapCount != 2 {
		MainRouterState_sendProtocolError(
			pm,
			state,
			peerID,
			common.SEALED_DIRECT_MESSAGE_INVALID_MESSAGE,
		)
		return
	}
	session, _ := MainRouterState_getPeerSession(state, peerID)
	request := common.DatabasePostDirectMessageRequest {
		senderId                = senderID,
		recipientId             = req.recipientUserId,
		clientMessageId         = req.clientMessageId,
		envelope                = req.envelope,
		serverIdentityPublicKey = state.serverIdentityPublicKey,
		senderIdentityPublicKey = session.clientIdentityPublicKey,
	}
	// The request takes the decoded envelope; the database side frees it.
	req.envelope = nil
	MainRouterState_enqueueChannelDatabaseRequest(
		pm,
		state,
		peerID,
		request,
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
	userID, ok := MainRouterState_authenticatedUserID(
		pm,
		state,
		peerID,
		"Unauthenticated user list request",
	)
	if !ok {
		return
	}
	MainRouterState_enqueueChannelDatabaseRequest(
		pm,
		state,
		peerID,
		common.DatabaseUserDirectoryRequest{viewerUserId = userID},
		PendingDBRequest{requestType = .ListUsers},
	)
}

// The message is already stored, so it goes to every live session of both users, the sending
// session included: that echo is how the sender learns the message ID and timestamp. An
// encrypted message goes out as ServerSealedDirectMessage with the envelope exactly as stored,
// a plaintext one as ServerDirectMessage with its signature.
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
	refusal := ""
	switch posted.outcome {
	case .Stored:
	case .UnknownRecipient:
		refusal = "Unknown direct message recipient"
	case .InvalidEnvelope:
		refusal = common.SEALED_DIRECT_MESSAGE_INVALID_MESSAGE
	case .Duplicate:
		refusal = common.DIRECT_MESSAGE_DUPLICATE_MESSAGE
	case .Restricted:
		refusal = common.DIRECT_MESSAGE_RESTRICTED_MESSAGE
	}
	if len(refusal) > 0 {
		MainRouterState_sendProtocolError(pm, state, request.peerID, refusal)
		return
	}
	stored := posted.storedMessage
	plainPayload := common.ServerDirectMessagePayload {
		id                = stored.id,
		senderId          = stored.senderId,
		senderNickname    = stored.senderNickname,
		recipientId       = stored.recipientId,
		recipientNickname = stored.recipientNickname,
		timestamp         = stored.timestamp,
		content           = stored.content,
		clientMessageId   = stored.clientMessageId,
		signature         = stored.signature,
	}
	sealedPayload := common.ServerSealedDirectMessagePayload {
		id                = stored.id,
		senderId          = stored.senderId,
		senderNickname    = stored.senderNickname,
		recipientId       = stored.recipientId,
		recipientNickname = stored.recipientNickname,
		timestamp         = stored.timestamp,
		clientMessageId   = stored.clientMessageId,
		envelope          = stored.envelope,
	}
	for recipientPeerID, recipientSession in state.peerSessions {
		if !recipientSession.isAuthenticated ||
		   (recipientSession.authenticatedUserID != stored.senderId &&
				   recipientSession.authenticatedUserID != stored.recipientId) {
			continue
		}
		if len(stored.envelope) > 0 {
			MainRouterState_sendPeerMessage(
				pm,
				state,
				recipientPeerID,
				.ServerSealedDirectMessage,
				sealedPayload,
			)
		} else {
			MainRouterState_sendPeerMessage(
				pm,
				state,
				recipientPeerID,
				.ServerDirectMessage,
				plainPayload,
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
