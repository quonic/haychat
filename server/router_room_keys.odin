package server

import "../common"
import "core:encoding/cbor"
import "core:fmt"
import "core:time"

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
// - Full history (protocol 20, design 6.6): a ClientRoomKeyEnvelope whose senderId names
//   another account is a RoomKeyForward of that account's chain, signed by the session under
//   makeRoomKeyForwardAAD, with exactly one wrap (the recipient the AAD names); the database
//   stores it only in a Full history room for a stored chain, and drops it silently when the
//   recipient already holds the chain. In a Full history room a key request goes to every
//   session of every other member, so whoever holds the chain can forward it.
// - Protocol 32 (#78): ClientRejectRoomKeyEnvelope takes the session's account off the wraps of
//   one stored envelope of a chain it did not send (the database checks that in the statement
//   that changes it), so the next forward or re-seal for it is stored. At most
//   ROOM_KEY_REJECTS_PER_MINUTE per session; nothing is answered.
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
	forward := req.senderId != 0 && req.senderId != session.authenticatedUserID
	recipients: [dynamic]int
	valid: bool
	if forward {
		recipients, valid = MainRouterState_checkRoomKeyForward(
			state,
			req,
			session.authenticatedUserID,
			session.clientIdentityPublicKey,
		)
	} else {
		recipients, valid = MainRouterState_checkRoomKeyEnvelope(
			state,
			req,
			session.authenticatedUserID,
			session.clientIdentityPublicKey,
		)
	}
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
	if forward {
		request.senderId = req.senderId
		request.forwarderId = session.authenticatedUserID
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

// The router's check of a forward (protocol 20, pure but for the server key): a positive room,
// epoch and chain sender, 1..SEALED_ENVELOPE_MAX_BYTES of a valid RoomKeyForward envelope with
// one wrap, and a signature by forwarderIdentityPublicKey over this server, the room, the epoch,
// the chain's sender, the chain, forwarderUserID and the wrap's recipient. Returns that
// recipient (owned) when it is valid.
MainRouterState_checkRoomKeyForward :: proc(
	state: ^MainRouterState,
	req: common.ClientRoomKeyEnvelopePayload,
	forwarderUserID: int,
	forwarderIdentityPublicKey: common.IdentityPublicKeyBytes,
) -> (
	recipients: [dynamic]int,
	valid: bool,
) {
	if req.roomId <= 0 ||
	   req.epoch <= 0 ||
	   req.senderId <= 0 ||
	   req.senderId == forwarderUserID ||
	   len(req.envelope) == 0 ||
	   len(req.envelope) > common.SEALED_ENVELOPE_MAX_BYTES {
		return nil, false
	}
	envelope, decodeErr := common.decodeSealedEnvelope(req.envelope)
	if decodeErr != .None || envelope.kind != .RoomKeyForward || envelope.wrapCount != 1 {
		return nil, false
	}
	recipientUserID := common.SealedEnvelope_wrap(envelope, 0).recipientUserID
	fields := common.RoomKeyForwardAADFields {
		serverIdentityPublicKey = state.serverIdentityPublicKey,
		roomID                  = req.roomId,
		epoch                   = req.epoch,
		senderUserID            = req.senderId,
		chainID                 = req.chainId,
		forwarderUserID         = forwarderUserID,
		recipientUserID         = recipientUserID,
	}
	if common.verifyRoomKeyForwardEnvelope(envelope, fields, forwarderIdentityPublicKey) != .None {
		return nil, false
	}
	recipients = make([dynamic]int, 0, 1)
	append(&recipients, recipientUserID)
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

// Protocol 32 (#78): the session rejects its copy of one envelope. Only the session's own
// account is ever taken off a wrap, so the limit is per session and only keeps a client from
// looping: past ROOM_KEY_REJECTS_PER_MINUTE in a minute it is refused.
MainRouterState_handleClientRejectRoomKeyEnvelope :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	peerID: u32,
	payload: []u8,
) {
	req: common.ClientRejectRoomKeyEnvelopePayload
	err := cbor.unmarshal(payload, &req)
	session, ok := &state.peerSessions[peerID]
	if !ok || !session.isAuthenticated {
		MainRouterState_sendProtocolError(pm, state, peerID, "Unauthenticated room request")
		return
	}
	if err != nil || req.envelopeId <= 0 {
		MainRouterState_sendProtocolError(
			pm,
			state,
			peerID,
			common.ROOM_KEY_REQUEST_INVALID_MESSAGE,
		)
		return
	}
	if !MainRouterState_takeRoomKeyReject(session, time.tick_now()) {
		MainRouterState_sendProtocolError(pm, state, peerID, common.ROOM_KEY_REJECT_LIMIT_MESSAGE)
		return
	}
	MainRouterState_enqueueChannelDatabaseRequest(
		pm,
		state,
		peerID,
		common.DatabaseRejectRoomKeyEnvelopeRequest {
			userId = session.authenticatedUserID,
			envelopeId = req.envelopeId,
		},
		PendingDBRequest {
			requestType = .RejectRoomKeyEnvelope,
			targetUserID = session.authenticatedUserID,
		},
	)
}

// Counts one reject against session's limit at now: false when the minute's are used up.
MainRouterState_takeRoomKeyReject :: proc(session: ^RouterPeerSession, now: time.Tick) -> bool {
	if session.roomKeyRejects == 0 ||
	   time.tick_diff(session.roomKeyRejectWindow, now) >= time.Minute {
		session.roomKeyRejectWindow = now
		session.roomKeyRejects = 0
	}
	if session.roomKeyRejects >= common.ROOM_KEY_REJECTS_PER_MINUTE {
		return false
	}
	session.roomKeyRejects += 1
	return true
}

MainRouterState_handleRejectRoomKeyEnvelopeResult :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
	request: PendingDBRequest,
	response: common.DatabaseQueryResponse,
) {
	result, resultOK := response.result.(common.DatabaseRejectRoomKeyEnvelopeResult)
	if !response.success || !resultOK || !result.rejected {
		return
	}
	// No key material, only who rejected which copy, for an operator who wonders why a chain
	// was forwarded again.
	fmt.printfln(
		"[RoomKeys] User %d rejected a key envelope of room %d (epoch %d, sender %d, " +
		"forwarder %d)",
		request.targetUserID,
		result.roomId,
		result.epoch,
		result.senderId,
		result.forwarderId,
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
	case .NotFullHistory:
		return common.ROOM_KEY_FORWARD_NOT_ALLOWED_MESSAGE
	case .Stored, .AlreadyHeld:
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
	if result.outcome == .AlreadyHeld {
		// Another member's forward came first (design 6.6): nothing to store or answer.
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
		senderId    = result.request.senderId,
	}
	for recipientPeerID, recipientSession in state.peerSessions {
		if !recipientSession.isAuthenticated {
			continue
		}
		// From join: only the chain's sender. Full history: every member but the requester.
		asked := recipientSession.authenticatedUserID == result.request.senderId
		if result.fullHistory {
			asked = MainRouterState_hasRecipientUserID(
				result.memberUserIDs[:],
				recipientSession.authenticatedUserID,
			)
		}
		if asked {
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
