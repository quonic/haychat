package server

import "../common"
import "core:encoding/cbor"

// Sender chains in encrypted rooms (protocol 19, e2ee-design.md 6.4): ClientRoomKeyEnvelope,
// ClientFetchRoomKeys and ClientRequestRoomKey. The router checks what needs no database (the
// shape, the envelope's structure and kind, and its signature against the session's identity
// key over every field of the room key AAD) and the database worker decides the rest in one
// statement (database_room_keys.odin):
//
// - A stored envelope goes out as ServerRoomKeyEnvelope to every session of the accounts its
//   wraps name, and to nobody else.
// - A fetch is answered with ServerRoomKeys to the requester only, with the envelopes that hold
//   a wrap for it.
// - A key request that passes its check (both accounts members of the encrypted room, the
//   chain stored) is relayed as ServerRoomKeyRequest to every session of the chain's sender.
//   One that does not is dropped without an answer: the requester keeps waiting, which is all
//   it could do with a refusal.
//
// Fixed-size byte fields decode through CBOR's temporary allocator, so it is the heap here.

MainRouterState_handleClientRoomKeyEnvelope :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	payload: []u8,
) {
	req: common.ClientRoomKeyEnvelopePayload
	err := cbor.unmarshal(payload, &req, temp_allocator = context.allocator)
	defer common.ClientRoomKeyEnvelopePayload_deinit(&req)
	if err != nil {
		MainRouterState_sendProtocolError(
			pm,
			state,
			peerID,
			common.ROOM_KEY_ENVELOPE_INVALID_MESSAGE,
		)
		return
	}
	session, ok := MainRouterState_getPeerSession(state, peerID)
	if !ok || !session.isAuthenticated {
		MainRouterState_sendProtocolError(pm, state, peerID, "Unauthenticated room request")
		return
	}
	recipients, valid := MainRouterState_checkRoomKeyEnvelope(
		state,
		req,
		session.authenticatedUserID,
		session.clientIdentityPublicKey,
	)
	if !valid {
		MainRouterState_sendProtocolError(
			pm,
			state,
			peerID,
			common.ROOM_KEY_ENVELOPE_INVALID_MESSAGE,
		)
		return
	}
	request := common.DatabaseStoreRoomKeyEnvelopeRequest {
		senderId         = session.authenticatedUserID,
		roomId           = req.roomId,
		epoch            = req.epoch,
		chainId          = req.chainId,
		envelope         = req.envelope,
		recipientUserIDs = recipients,
	}
	// The request takes the decoded envelope; the database side frees it.
	req.envelope = nil
	MainRouterState_enqueueChannelDatabaseRequest(
		pm,
		state,
		peerID,
		request,
		PendingDBRequest{requestType = .StoreRoomKeyEnvelope, roomID = req.roomId},
	)
}

// The router's check of a key envelope (pure but for the server key): a positive room and
// epoch, 1..SEALED_ENVELOPE_MAX_BYTES of a valid SenderKey envelope, and a signature by
// senderIdentityPublicKey over this server, the room, the epoch, senderUserID and the chain.
// Returns the user IDs the wraps name (owned) when it is valid.
MainRouterState_checkRoomKeyEnvelope :: proc(
	state: ^MainRouterState,
	req: common.ClientRoomKeyEnvelopePayload,
	senderUserID: int,
	senderIdentityPublicKey: common.IdentityPublicKeyBytes,
) -> (
	recipients: [dynamic]int,
	valid: bool,
) {
	if req.roomId <= 0 ||
	   req.epoch <= 0 ||
	   len(req.envelope) == 0 ||
	   len(req.envelope) > common.SEALED_ENVELOPE_MAX_BYTES {
		return nil, false
	}
	envelope, decodeErr := common.decodeSealedEnvelope(req.envelope)
	if decodeErr != .None || envelope.kind != .SenderKey {
		return nil, false
	}
	aad := common.makeRoomKeyAAD(
		common.RoomKeyAADFields {
			serverIdentityPublicKey = state.serverIdentityPublicKey,
			roomID = req.roomId,
			epoch = req.epoch,
			senderUserID = senderUserID,
			chainID = req.chainId,
		},
	)
	if common.verifySealedEnvelopeSignature(envelope, aad[:], senderIdentityPublicKey) != .None {
		return nil, false
	}
	recipients = make([dynamic]int, 0, envelope.wrapCount)
	for index in 0 ..< envelope.wrapCount {
		append(&recipients, common.SealedEnvelope_wrap(envelope, index).recipientUserID)
	}
	return recipients, true
}

MainRouterState_handleClientFetchRoomKeys :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	payload: []u8,
) {
	req: common.ClientFetchRoomKeysPayload
	if cbor.unmarshal(payload, &req) != nil ||
	   req.roomId <= 0 ||
	   req.sinceEpoch < 0 ||
	   req.afterId < 0 {
		MainRouterState_sendProtocolError(pm, state, peerID, "Invalid room key request")
		return
	}
	session, ok := MainRouterState_getPeerSession(state, peerID)
	if !ok || !session.isAuthenticated {
		MainRouterState_sendProtocolError(pm, state, peerID, "Unauthenticated room request")
		return
	}
	MainRouterState_enqueueChannelDatabaseRequest(
		pm,
		state,
		peerID,
		common.DatabaseFetchRoomKeysRequest {
			userId = session.authenticatedUserID,
			roomId = req.roomId,
			sinceEpoch = req.sinceEpoch,
			afterId = req.afterId,
		},
		PendingDBRequest{requestType = .FetchRoomKeys, roomID = req.roomId},
	)
}

MainRouterState_handleClientRequestRoomKey :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	payload: []u8,
) {
	req: common.ClientRequestRoomKeyPayload
	err := cbor.unmarshal(payload, &req, temp_allocator = context.allocator)
	session, ok := MainRouterState_getPeerSession(state, peerID)
	if !ok || !session.isAuthenticated {
		MainRouterState_sendProtocolError(pm, state, peerID, "Unauthenticated room request")
		return
	}
	if err != nil ||
	   req.roomId <= 0 ||
	   req.epoch <= 0 ||
	   req.senderId <= 0 ||
	   req.senderId == session.authenticatedUserID {
		MainRouterState_sendProtocolError(
			pm,
			state,
			peerID,
			common.ROOM_KEY_REQUEST_INVALID_MESSAGE,
		)
		return
	}
	MainRouterState_enqueueChannelDatabaseRequest(
		pm,
		state,
		peerID,
		common.DatabaseRoomKeyRequestCheckRequest {
			requesterId = session.authenticatedUserID,
			roomId = req.roomId,
			epoch = req.epoch,
			senderId = req.senderId,
			chainId = req.chainId,
		},
		PendingDBRequest{requestType = .RoomKeyRequestCheck, roomID = req.roomId},
	)
}

// The sentence for a refused envelope.
MainRouterState_roomKeyEnvelopeRefusalMessage :: proc(
	outcome: common.RoomKeyEnvelopeOutcome,
) -> string {
	switch outcome {
	case .NotMember:
		return ROOM_NOT_MEMBER_MESSAGE
	case .NotEncrypted:
		return common.ROOM_LOG_NOT_ENCRYPTED_MESSAGE
	case .StaleEpoch:
		return common.ROOM_KEY_OUT_OF_DATE_MESSAGE
	case .WrongRecipients:
		return common.ROOM_KEY_ENVELOPE_INVALID_MESSAGE
	case .Stored:
	}
	return ""
}

MainRouterState_handleStoreRoomKeyEnvelopeResult :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	request: PendingDBRequest,
	response: common.DatabaseQueryResponse,
) {
	result, resultOK := response.result.(common.DatabaseStoreRoomKeyEnvelopeResult)
	if MainRouterState_databaseFailed(pm, state, request.peerID, response, resultOK) {
		return
	}
	if result.outcome != .Stored {
		MainRouterState_sendProtocolError(
			pm,
			state,
			request.peerID,
			MainRouterState_roomKeyEnvelopeRefusalMessage(result.outcome),
		)
		return
	}
	payload := common.ServerRoomKeyEnvelopePayload {
		envelope = result.stored,
	}
	for recipientPeerID, recipientSession in state.peerSessions {
		if recipientSession.isAuthenticated &&
		   MainRouterState_hasRecipientUserID(
			   result.recipientUserIDs[:],
			   recipientSession.authenticatedUserID,
		   ) {
			MainRouterState_sendPeerMessage(
				pm,
				state,
				recipientPeerID,
				.ServerRoomKeyEnvelope,
				payload,
			)
		}
	}
}

MainRouterState_handleFetchRoomKeysResult :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	request: PendingDBRequest,
	response: common.DatabaseQueryResponse,
) {
	result, resultOK := response.result.(common.DatabaseFetchRoomKeysResult)
	if MainRouterState_databaseFailed(pm, state, request.peerID, response, resultOK) {
		return
	}
	if !result.isMember {
		MainRouterState_sendProtocolError(pm, state, request.peerID, ROOM_NOT_MEMBER_MESSAGE)
		return
	}
	MainRouterState_sendPeerMessage(
		pm,
		state,
		request.peerID,
		.ServerRoomKeys,
		common.ServerRoomKeysPayload {
			roomId = request.roomID,
			sinceEpoch = result.sinceEpoch,
			afterId = result.afterId,
			envelopes = result.envelopes,
			hasMore = result.hasMore,
		},
	)
}

MainRouterState_handleRoomKeyRequestCheckResult :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	request: PendingDBRequest,
	response: common.DatabaseQueryResponse,
) {
	result, resultOK := response.result.(common.DatabaseRoomKeyRequestCheckResult)
	if !response.success || !resultOK || !result.allowed {
		return
	}
	payload := common.ServerRoomKeyRequestPayload {
		roomId      = result.request.roomId,
		epoch       = result.request.epoch,
		chainId     = result.request.chainId,
		requesterId = result.request.requesterId,
	}
	for recipientPeerID, recipientSession in state.peerSessions {
		if recipientSession.isAuthenticated &&
		   recipientSession.authenticatedUserID == result.request.senderId {
			MainRouterState_sendPeerMessage(
				pm,
				state,
				recipientPeerID,
				.ServerRoomKeyRequest,
				payload,
			)
		}
	}
}
