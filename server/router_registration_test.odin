package server

import "../common"
import "core:crypto/ecdh"
import "core:encoding/cbor"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

// Registration in the router (protocol 25, #43 G1): the D12 handshake, the registering gate,
// the D13 limits, live completion (D14) and the D17 presence filter. The database is stubbed:
// each test answers the queued DatabaseQuery itself.

// A client that got ServerRegistrationRequired: its active transport and identity key.
RouterRegistrationTestClient :: struct {
	peerID:    u32,
	transport: common.TransportState,
	publicKey: common.IdentityPublicKeyBytes,
}

// Runs ClientHello .. ClientAuthRequest for peerID (registering as given), answers the identity
// statement with needsRegistration, and checks the plaintext ServerRegistrationRequired.
@(private = "file")
routerRegistrationTestBegin :: proc(
	h: ^RouterTestHarness,
	peerID: u32,
	nickname := "applicant",
	registering := true,
	mode := common.RegistrationMode.InviteOnly,
	status := common.RegistrationRequestStatus.None,
	expectRequired := true,
) -> RouterRegistrationTestClient {
	if _, ok := h.state.peerSessions[peerID]; !ok {
		h.state.connectedPeers[peerID] = true
		MainRouterState_setPeerSession(&h.state, peerID, RouterPeerSession_init())
	}
	clientPrivateKey, clientPublicKey, identityOK := common.generateIdentityKeyPair()
	assert(identityOK, "expected a client identity key")
	ephemeralPrivate, ephemeralPublic, ephemeralOK := common.generateKeyExchangeKeyPair()
	assert(ephemeralOK, "expected a client ephemeral key")
	defer ecdh.private_key_clear(&ephemeralPrivate)

	hello := common.ClientHello {
		version                  = common.protocolVersion,
		nickname                 = nickname,
		clientIdentityPublicKey  = clientPublicKey,
		clientEphemeralPublicKey = ephemeralPublic,
	}
	helloBytes, helloOK := common.buildPacketBytes(.ClientHello, hello)
	assert(helloOK, "expected ClientHello to encode")
	defer delete(helloBytes)
	MainRouterState_handleNetworkDataReceived(
		&h.pm,
		&h.state,
		NetworkDataReceived{peerId = peerID, channel = .Chat, data = helloBytes},
	)
	serverHelloSend := routerPollNetworkSend(h)
	defer delete(serverHelloSend.data)
	serverHelloPacket := routerDecodePacketBytes(serverHelloSend.data)
	defer delete(serverHelloPacket.payload)
	serverHello: common.ServerHello
	assert(cbor.unmarshal(serverHelloPacket.payload, &serverHello) == nil, "expected ServerHello")
	challengeSend := routerPollNetworkSend(h)
	defer delete(challengeSend.data)
	challengePacket := routerDecodePacketBytes(challengeSend.data)
	defer delete(challengePacket.payload)
	challenge: common.ServerAuthChallengePayload
	assert(cbor.unmarshal(challengePacket.payload, &challenge) == nil, "expected a challenge")

	proof := common.buildClientAuthProof(
		challenge.sessionID,
		challenge.challenge,
		nickname,
		clientPublicKey,
		ephemeralPublic,
		serverHello.serverIdentityPublicKey,
		serverHello.serverEphemeralPublicKey,
	)
	authRequest, signOK := common.signClientAuthRequest(clientPrivateKey, proof)
	assert(signOK, "expected ClientAuthRequest to sign")
	authRequest.registering = registering
	authBytes, authOK := common.buildPacketBytes(.ClientAuthRequest, authRequest)
	assert(authOK, "expected ClientAuthRequest to encode")
	defer delete(authBytes)
	MainRouterState_handleNetworkDataReceived(
		&h.pm,
		&h.state,
		NetworkDataReceived{peerId = peerID, channel = .Chat, data = authBytes},
	)

	identityQuery := routerPollDatabaseQuery(h)
	defer IPC__database_query_request_deinit(identityQuery.request)
	identityRequest, identityOK2 := identityQuery.request.(common.DatabaseUserIdentityRequest)
	assert(
		identityOK2 && identityRequest.registering == registering,
		"expected the identity statement to carry registering",
	)
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		identityQuery.request_id,
		common.DatabaseQueryResponse {
			success = true,
			result = common.DatabaseUserIdentityResult {
				needsRegistration = true,
				registrationMode = mode,
				requestStatus = status,
				decisionReason = status == .Declined ? strings.clone("full") : "",
			},
		},
	)

	client := RouterRegistrationTestClient {
		peerID    = peerID,
		publicKey = clientPublicKey,
	}
	if !expectRequired {
		return client
	}
	requiredSend := routerPollNetworkSend(h)
	defer delete(requiredSend.data)
	requiredPacket := routerDecodePacketBytes(requiredSend.data)
	defer delete(requiredPacket.payload)
	assert(
		requiredPacket.messageType == .ServerRegistrationRequired,
		fmt.tprintf("expected plaintext ServerRegistrationRequired, got %v", requiredPacket),
	)
	required: common.ServerRegistrationRequiredPayload
	assert(cbor.unmarshal(requiredPacket.payload, &required) == nil, "expected its payload")
	defer common.ServerRegistrationRequiredPayload_deinit(&required)
	assert(
		required.mode == mode && required.status == status && len(required.message) > 0,
		fmt.tprintf("expected the mode and status, got %v", required),
	)

	sharedSecret, secretOK := common.deriveSharedSecret(
		&ephemeralPrivate,
		serverHello.serverEphemeralPublicKey,
	)
	assert(secretOK, "expected a shared secret")
	serverProof := common.buildServerHelloProof(
		challenge.sessionID,
		nickname,
		clientPublicKey,
		ephemeralPublic,
		serverHello.serverIdentityPublicKey,
		serverHello.serverEphemeralPublicKey,
	)
	transcript, transcriptOK := common.deriveHandshakeTranscriptHash(serverProof, proof)
	assert(transcriptOK, "expected a transcript hash")
	keys := common.deriveDirectionalTransportKeys(
		.Client,
		challenge.sessionID,
		sharedSecret,
		transcript,
	)
	client.transport = common.TransportState_init(.Client)
	common.TransportState_activate(&client.transport, challenge.sessionID, keys, .Trusted)
	common.DirectionalTransportKeys_wipe(&keys)
	session, _ := MainRouterState_getPeerSession(&h.state, peerID)
	assert(
		session.isRegistering && !session.isAuthenticated,
		"expected the session to be registering",
	)
	return client
}

// Opens the next ServerRegisterResponse for client.
@(private = "file")
routerRegistrationTestResponse :: proc(
	h: ^RouterTestHarness,
	client: ^RouterRegistrationTestClient,
) -> common.ServerRegisterResponsePayload {
	packet := routerTestOpenInnerPacket(h, &client.transport)
	defer delete(packet.payload)
	assert(
		packet.messageType == .ServerRegisterResponse,
		fmt.tprintf("expected a sealed ServerRegisterResponse, got %v", packet.messageType),
	)
	response: common.ServerRegisterResponsePayload
	assert(cbor.unmarshal(packet.payload, &response) == nil, "expected its payload")
	return response
}

@(private = "file")
routerRegistrationTestRegister :: proc(
	h: ^RouterTestHarness,
	client: ^RouterRegistrationTestClient,
	code: string,
	reason := "",
) {
	routerTestSendSealed(
		h,
		&client.transport,
		client.peerID,
		.ClientRegister,
		common.ClientRegisterRequest{inviteCode = code, reason = reason},
	)
}

@(private = "file")
routerRegistrationTestCode :: proc() -> (common.InviteCodeBytes, string) {
	code, ok := common.generateInviteCode()
	assert(ok, "expected a random code")
	return code, common.formatInviteCode(code)
}

// D12: an unknown key on an Invite only server is told to register in plaintext, the
// transport is active on both sides, nothing but ClientRegister and Ping is accepted, and a
// plaintext ClientRegister is refused.
@(test)
testRegistrationHandshakeGatesTheSession :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)

	client := routerRegistrationTestBegin(&h, 1, registering = false)
	defer common.TransportState_deinit(&client.transport)
	// A Ping is accepted and answered with nothing.
	routerTestSendSealed(&h, &client.transport, 1, .Ping, common.ClientListRoomsPayload{})
	routerTestExpectNoNetworkMessage(&h, "a Ping while registering")
	routerTestExpectNoDatabaseQuery(&h, "a Ping while registering")
	// Anything else ends the session with a sealed protocol error.
	routerTestSendSealed(
		&h,
		&client.transport,
		1,
		.ClientListRooms,
		common.ClientListRoomsPayload{},
	)
	refusal := routerTestOpenInnerPacket(&h, &client.transport)
	defer delete(refusal.payload)
	assert(refusal.messageType == .ServerProtocolError, "expected a sealed protocol error")
	disconnect := routerPollDisconnect(&h)
	assert(disconnect.peerId == 1, "expected the registering session disconnected")
	routerTestExpectNoDatabaseQuery(&h, "an application packet while registering")

	// A plaintext ClientRegister never reaches the database.
	h.state.connectedPeers[2] = true
	MainRouterState_setPeerSession(&h.state, 2, RouterPeerSession_init())
	plain, plainOK := common.buildPacketBytes(
		.ClientRegister,
		common.ClientRegisterRequest{inviteCode = "ABCD"},
	)
	assert(plainOK, "expected the plaintext packet to encode")
	defer delete(plain)
	MainRouterState_handleNetworkDataReceived(
		&h.pm,
		&h.state,
		NetworkDataReceived{peerId = 2, channel = .Chat, data = plain},
	)
	plainError := routerPollNetworkSend(&h)
	delete(plainError.data)
	assert(routerPollDisconnect(&h).peerId == 2, "expected a plaintext ClientRegister refused")
	routerTestExpectNoDatabaseQuery(&h, "a plaintext ClientRegister")
	assert(
		!MainRouterState_isPlaintextHandshakeResponse(.ServerRegisterResponse) &&
		MainRouterState_isPlaintextHandshakeResponse(.ServerRegistrationRequired),
		"expected ServerRegisterResponse sealed and ServerRegistrationRequired plaintext",
	)
}

// D13: a Created sign-up authenticates the session without a second handshake; the code goes
// to the database only as its hash.
@(test)
testRegistrationCreatedAuthenticatesTheSession :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)

	client := routerRegistrationTestBegin(&h, 1, nickname = "carol")
	defer common.TransportState_deinit(&client.transport)
	code, text := routerRegistrationTestCode()
	defer delete(text)
	lowered := strings.to_lower(text)
	defer delete(lowered)
	routerRegistrationTestRegister(&h, &client, lowered, "hi")
	query := routerPollDatabaseQuery(&h)
	defer IPC__database_query_request_deinit(query.request)
	register, registerOK := query.request.(common.DatabaseRegisterRequest)
	assert(
		registerOK &&
		register.hasCode &&
		register.codeHash == common.inviteCodeHash(code) &&
		register.nickname == "carol" &&
		register.reason == "hi" &&
		register.publicKey == client.publicKey,
		fmt.tprintf("expected the sign-up with the code's hash, got %v", query.request),
	)
	// A second ClientRegister while the first is in the database is a violation, not a race.
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		query.request_id,
		common.DatabaseQueryResponse {
			success = true,
			result = common.DatabaseRegisterResult {
				outcome = .Created,
				userId = 77,
				nickname = strings.clone("carol"),
				permissions = {.CreateInvites},
				registrationMode = .InviteOnly,
				isRestricted = true,
			},
		},
	)
	response := routerRegistrationTestResponse(&h, &client)
	defer common.ServerRegisterResponsePayload_deinit(&response)
	assert(
		response.status == .Created &&
		response.auth.userId == 77 &&
		response.auth.nickname == "carol" &&
		response.auth.isRestricted &&
		response.auth.registrationMode == .InviteOnly &&
		.CreateInvites in response.auth.permissions,
		fmt.tprintf("expected Created with the sign-in fields, got %v", response),
	)
	voice := routerPollVoiceSessionOpen(&h)
	common.ChannelSendState_wipe(&voice.send)
	common.VoiceReceiveState_wipe(&voice.receive)
	session, _ := MainRouterState_getPeerSession(&h.state, 1)
	assert(
		session.isAuthenticated && !session.isRegistering && session.authenticatedUserID == 77,
		"expected the session authenticated",
	)
	assert(MainRouterState_userIsRestricted(&h.state, 77), "expected the restricted set updated")

	// The same transport now carries application packets.
	routerTestSendSealed(
		&h,
		&client.transport,
		1,
		.ClientListRooms,
		common.ClientListRoomsPayload{},
	)
	rooms := routerPollDatabaseQuery(&h)
	defer IPC__database_query_request_deinit(rooms.request)
	_, roomsOK := rooms.request.(common.DatabaseRoomListRequest)
	assert(roomsOK, "expected the room list after Created")
}

// D13: refusals keep the session registering until the fifth, malformed codes never reach the
// database, and a session older than REGISTER_SESSION_SECONDS is ended.
@(test)
testRegistrationAttemptAndTimeLimits :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)

	client := routerRegistrationTestBegin(&h, 1)
	defer common.TransportState_deinit(&client.transport)
	for attempt in 1 ..= common.REGISTER_ATTEMPTS_MAX {
		routerRegistrationTestRegister(&h, &client, "not-a-code")
		response := routerRegistrationTestResponse(&h, &client)
		defer common.ServerRegisterResponsePayload_deinit(&response)
		assert(
			response.status == .Refused && response.message == common.INVITE_CODE_INVALID_MESSAGE,
			fmt.tprintf("expected attempt %d refused generically, got %v", attempt, response),
		)
		routerTestExpectNoDatabaseQuery(&h, "a malformed code")
	}
	assert(routerPollDisconnect(&h).peerId == 1, "expected the fifth refusal to disconnect")

	// A reason past 500 characters is refused before the database too.
	long := strings.repeat("x", common.REGISTRATION_REASON_MAX_CHARS + 1)
	defer delete(long)
	other := routerRegistrationTestBegin(&h, 2)
	defer common.TransportState_deinit(&other.transport)
	_, text := routerRegistrationTestCode()
	defer delete(text)
	routerRegistrationTestRegister(&h, &other, text, long)
	tooLong := routerRegistrationTestResponse(&h, &other)
	defer common.ServerRegisterResponsePayload_deinit(&tooLong)
	assert(tooLong.status == .Refused, "expected a long reason refused")
	routerTestExpectNoDatabaseQuery(&h, "a long reason")

	// Time: the sweep ends a session past its ten minutes.
	MainRouterState_expireRegisteringSessions(&h.pm, &h.state, time.tick_now())
	routerTestExpectNoNetworkMessage(&h, "a young registering session")
	later := time.tick_add(time.tick_now(), (common.REGISTER_SESSION_SECONDS + 1) * time.Second)
	MainRouterState_expireRegisteringSessions(&h.pm, &h.state, later)
	expired := routerRegistrationTestResponse(&h, &other)
	defer common.ServerRegisterResponsePayload_deinit(&expired)
	assert(
		expired.status == .Refused && expired.message == common.REGISTRATION_TIMED_OUT_MESSAGE,
		"expected the timed out session told",
	)
	assert(routerPollDisconnect(&h).peerId == 2, "expected the timed out session disconnected")
}

// D13: at most REGISTERING_SESSIONS_MAX sessions register at once.
@(test)
testRegistrationCapsConcurrentSessions :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)

	for index in 0 ..< common.REGISTERING_SESSIONS_MAX {
		session := RouterPeerSession_init()
		session.isRegistering = true
		session.registeringSince = time.tick_now()
		MainRouterState_setPeerSession(&h.state, u32(1000 + index), session)
	}
	client := routerRegistrationTestBegin(&h, 1, expectRequired = false)
	busy := routerPollNetworkSend(&h)
	defer delete(busy.data)
	packet := routerDecodePacketBytes(busy.data)
	defer delete(packet.payload)
	failure: common.ServerAuthFailurePayload
	assert(cbor.unmarshal(packet.payload, &failure) == nil, "expected an auth failure")
	defer delete(failure.message)
	assert(
		packet.messageType == .ServerAuthFailure &&
		failure.message == common.REGISTRATION_BUSY_MESSAGE,
		fmt.tprintf("expected the busy refusal, got %v %q", packet.messageType, failure.message),
	)
	assert(routerPollDisconnect(&h).peerId == client.peerID, "expected the extra one disconnected")
}

// D14, D18: a pending request reaches approvers with the count, and approving it completes the
// still-connected applicant live through the identity statement.
@(test)
testRegistrationApprovalCompletesTheApplicantLive :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)

	approverTransport := routerCompleteHandshake(&h, 1, userID = 5, nickname = "approver")
	defer common.TransportState_deinit(&approverTransport)
	if session, ok := &h.state.peerSessions[1]; ok {
		session.permissions = {.ApproveRegistrations}
	}
	client := routerRegistrationTestBegin(
		&h,
		2,
		nickname = "dave",
		mode = .InviteApproval,
	)
	defer common.TransportState_deinit(&client.transport)
	_, text := routerRegistrationTestCode()
	defer delete(text)
	routerRegistrationTestRegister(&h, &client, text, "I know alice")
	query := routerPollDatabaseQuery(&h)
	IPC__database_query_request_deinit(query.request)
	summary := common.RegistrationRequestSummary {
		id                = 9,
		nickname          = strings.clone("dave"),
		reason            = strings.clone("I know alice"),
		status            = .Pending,
		identityPublicKey = client.publicKey,
	}
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		query.request_id,
		common.DatabaseQueryResponse {
			success = true,
			result = common.DatabaseRegisterResult {
				outcome = .Pending,
				request = summary,
				pendingCount = 1,
			},
		},
	)
	// The approver hears first (the fan-out runs before the applicant's answer).
	updated := routerTestOpenInnerPacket(&h, &approverTransport)
	defer delete(updated.payload)
	assert(updated.messageType == .ServerRegistrationRequestUpdated, "expected the approver told")
	notice: common.ServerRegistrationRequestUpdatedPayload
	assert(cbor.unmarshal(updated.payload, &notice) == nil, "expected the notice payload")
	defer common.ServerRegistrationRequestUpdatedPayload_deinit(&notice)
	assert(notice.pendingCount == 1 && notice.request.id == 9, "expected the count and request")
	pending := routerRegistrationTestResponse(&h, &client)
	defer common.ServerRegisterResponsePayload_deinit(&pending)
	assert(pending.status == .Pending, "expected the applicant to wait")

	// The approver approves.
	routerTestSendSealed(
		&h,
		&approverTransport,
		1,
		.ClientDecideRegistration,
		common.ClientDecideRegistrationPayload{id = 9, approve = true},
	)
	decide := routerPollDatabaseQuery(&h)
	IPC__database_query_request_deinit(decide.request)
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		decide.request_id,
		common.DatabaseQueryResponse {
			success = true,
			result = common.DatabaseRegistrationRequestsResult {
				outcome = .Applied,
				request = {
					id = 9,
					nickname = strings.clone("dave"),
					status = .Approved,
					identityPublicKey = client.publicKey,
				},
			},
		},
	)
	result := routerTestOpenInnerPacket(&h, &approverTransport)
	delete(result.payload)
	assert(result.messageType == .ServerAdminActionResult, "expected the approver's answer")
	again := routerTestOpenInnerPacket(&h, &approverTransport)
	delete(again.payload)
	assert(again.messageType == .ServerRegistrationRequestUpdated, "expected the badge update")

	identity := routerPollDatabaseQuery(&h)
	defer IPC__database_query_request_deinit(identity.request)
	identityRequest, identityOK := identity.request.(common.DatabaseUserIdentityRequest)
	assert(
		identityOK && identityRequest.publicKey == client.publicKey && identityRequest.registering,
		"expected the applicant's identity statement re-run",
	)
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		identity.request_id,
		common.DatabaseQueryResponse {
			success = true,
			result = common.DatabaseUserIdentityResult {
				userId = 88,
				nickname = strings.clone("dave"),
				registrationMode = .InviteApproval,
			},
		},
	)
	created := routerRegistrationTestResponse(&h, &client)
	defer common.ServerRegisterResponsePayload_deinit(&created)
	assert(created.status == .Created && created.auth.userId == 88, "expected dave completed")
	voice := routerPollVoiceSessionOpen(&h)
	common.ChannelSendState_wipe(&voice.send)
	common.VoiceReceiveState_wipe(&voice.receive)
	presence := routerTestOpenInnerPacket(&h, &approverTransport)
	delete(presence.payload)
	assert(presence.messageType == .ServerUserPresence, "expected dave announced online")
}

// D17: presence about a restricted account reaches unrestricted accounts only after the
// database says they share a room; approvers get it at once.
@(test)
testRestrictedPresenceIsFilteredPerRecipient :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)

	bob := routerCompleteHandshake(&h, 1, userID = 2, nickname = "bob")
	defer common.TransportState_deinit(&bob)
	h.state.connectedPeers[2] = true
	MainRouterState_setPeerSession(&h.state, 2, RouterPeerSession_init())
	carol := routerCompleteHandshake(&h, 2, userID = 3, nickname = "carol")
	defer common.TransportState_deinit(&carol)
	carolOnline := routerTestOpenInnerPacket(&h, &bob)
	delete(carolOnline.payload)
	h.state.connectedPeers[3] = true
	MainRouterState_setPeerSession(&h.state, 3, RouterPeerSession_init())
	approver := routerCompleteHandshake(&h, 3, userID = 4, nickname = "approver")
	defer common.TransportState_deinit(&approver)
	// The approver's presence goes to bob and carol in map order.
	for _ in 0 ..< 2 {
		send := routerPollNetworkSend(&h)
		defer delete(send.data)
		outer := routerDecodePacketBytes(send.data)
		defer delete(outer.payload)
		online, openOK := common.openPacketForSession(send.peerId == 1 ? &bob : &carol, outer)
		assert(openOK, "expected the approver's presence")
		delete(online.payload)
	}
	if session, ok := &h.state.peerSessions[3]; ok {
		session.permissions = {.ApproveRegistrations}
	}

	// erin is restricted: the approver hears at once, bob and carol wait for the database.
	h.state.connectedPeers[4] = true
	MainRouterState_setPeerSession(&h.state, 4, RouterPeerSession_init())
	erin := routerCompleteHandshake(&h, 4, userID = 5, nickname = "erin", isRestricted = true)
	defer common.TransportState_deinit(&erin)
	direct := routerTestOpenInnerPacket(&h, &approver)
	delete(direct.payload)
	assert(direct.messageType == .ServerUserPresence, "expected the approver told at once")
	routerTestExpectNoNetworkMessage(&h, "presence before the database answered")
	check := routerPollDatabaseQuery(&h)
	defer IPC__database_query_request_deinit(check.request)
	shared, sharedOK := check.request.(common.DatabaseSharedRoomsRequest)
	assert(
		sharedOK && shared.userId == 5 && len(shared.candidateUserIds) == 2,
		fmt.tprintf("expected bob and carol checked, got %v", check.request),
	)
	answer := make([dynamic]int)
	append(&answer, 2)
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		check.request_id,
		common.DatabaseQueryResponse {
			success = true,
			result = common.DatabaseSharedRoomsResult{userIds = answer},
		},
	)
	bobPresence := routerTestOpenInnerPacket(&h, &bob)
	defer delete(bobPresence.payload)
	assert(bobPresence.messageType == .ServerUserPresence, "expected bob, a room mate, told")
	routerTestExpectNoNetworkMessage(&h, "presence to carol, who shares no room")
}

// A ClientRegister's answer outlives its peer (approvers still hear of a request), so it must
// never complete another session that got the same peer ID.
@(test)
testRegistrationAnswerIgnoresAReusedPeerID :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)

	first := routerRegistrationTestBegin(&h, 1)
	defer common.TransportState_deinit(&first.transport)
	_, text := routerRegistrationTestCode()
	defer delete(text)
	routerRegistrationTestRegister(&h, &first, text)
	query := routerPollDatabaseQuery(&h)
	IPC__database_query_request_deinit(query.request)
	MainRouterState_handlePeerDisconnected(&h.pm, &h.state, 1)
	h.state.connectedPeers[1] = true
	MainRouterState_setPeerSession(&h.state, 1, RouterPeerSession_init())
	second := routerRegistrationTestBegin(&h, 1)
	defer common.TransportState_deinit(&second.transport)
	if session, ok := &h.state.peerSessions[1]; ok {
		session.registerInFlight = true
	}
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		query.request_id,
		common.DatabaseQueryResponse {
			success = true,
			result = common.DatabaseRegisterResult {
				outcome = .Created,
				userId = 70,
				nickname = strings.clone("applicant"),
			},
		},
	)
	routerTestExpectNoNetworkMessage(&h, "an answer for another key")
	session, _ := MainRouterState_getPeerSession(&h.state, 1)
	assert(!session.isAuthenticated && session.isRegistering, "expected the new session untouched")
}

// Opens and drops every queued network message (the fan-outs a test does not look at), each
// with its peer's transport so later messages still open in order.
@(private = "file")
routerRegistrationTestDrainNetwork :: proc(h: ^RouterTestHarness, peers: []RouterTestPeer) {
	for {
		msg, err := IPC_Client_poll(h.networkFd)
		if err != nil {
			return
		}
		if send, isSend := msg.(NetworkSendData); isSend {
			outer := routerDecodePacketBytes(send.data)
			for peer in peers {
				if peer.peerID == send.peerId {
					inner, openOK := common.openPacketForSession(peer.transport, outer)
					assert(openOK, fmt.tprintf("expected peer %d to open its message", peer.peerID))
					delete(inner.payload)
				}
			}
			delete(outer.payload)
		}
		IPC__message_deinit(&msg)
	}
}

// Opens the next message for one of peers, checks it is a ServerUserUpdated about the new
// account userID, and returns the recipient and the summary (owned).
@(private = "file")
routerRegistrationTestUserUpdated :: proc(
	h: ^RouterTestHarness,
	peers: []RouterTestPeer,
	userID: int,
) -> (
	u32,
	common.UserSummary,
) {
	recipient, packet := routerTestReceive(h, peers)
	defer delete(packet.payload)
	assert(
		packet.messageType == .ServerUserUpdated,
		fmt.tprintf("expected ServerUserUpdated before presence, got %v", packet.messageType),
	)
	updated: common.ServerUserUpdatedPayload
	assert(cbor.unmarshal(packet.payload, &updated) == nil, "expected its payload")
	assert(
		updated.user.id == userID,
		fmt.tprintf("expected the summary of %d, got %v", userID, updated.user),
	)
	return recipient, updated.user
}

@(private = "file")
routerRegistrationTestPresence :: proc(
	h: ^RouterTestHarness,
	peers: []RouterTestPeer,
	userID: int,
) -> u32 {
	recipient, packet := routerTestReceive(h, peers)
	defer delete(packet.payload)
	assert(
		packet.messageType == .ServerUserPresence,
		fmt.tprintf("expected ServerUserPresence, got %v", packet.messageType),
	)
	presence: common.ServerUserPresencePayload
	assert(cbor.unmarshal(packet.payload, &presence) == nil, "expected its payload")
	defer delete(presence.nickname)
	assert(presence.userId == userID && presence.isOnline, "expected the new account online")
	return recipient
}

// #102: an account the server just created reaches every session allowed to see it (D17) as a
// full ServerUserUpdated (identity key, roles, restriction) before its presence, and reaches no
// session that may not see it.
@(test)
testNewAccountReachesOthersWithItsFullSummary :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)

	bob, carol, approver, dave, frank: common.TransportState
	peers := []RouterTestPeer {
		{peerID = 1, transport = &bob},
		{peerID = 2, transport = &carol},
		{peerID = 3, transport = &approver},
		{peerID = 4, transport = &dave},
		{peerID = 5, transport = &frank},
	}
	bob = routerCompleteHandshake(&h, 1, userID = 2, nickname = "bob")
	defer common.TransportState_deinit(&bob)
	h.state.connectedPeers[2] = true
	MainRouterState_setPeerSession(&h.state, 2, RouterPeerSession_init())
	carol = routerCompleteHandshake(&h, 2, userID = 3, nickname = "carol")
	defer common.TransportState_deinit(&carol)
	routerRegistrationTestDrainNetwork(&h, peers)
	h.state.connectedPeers[3] = true
	MainRouterState_setPeerSession(&h.state, 3, RouterPeerSession_init())
	approver = routerCompleteHandshake(&h, 3, userID = 4, nickname = "approver")
	defer common.TransportState_deinit(&approver)
	routerRegistrationTestDrainNetwork(&h, peers)
	if session, ok := &h.state.peerSessions[3]; ok {
		session.permissions = {.ApproveRegistrations}
	}

	// A returning account is announced by presence only.
	h.state.connectedPeers[4] = true
	MainRouterState_setPeerSession(&h.state, 4, RouterPeerSession_init())
	dave = routerCompleteHandshake(&h, 4, userID = 9, nickname = "dave")
	defer common.TransportState_deinit(&dave)
	for _ in 0 ..< 3 {
		routerRegistrationTestPresence(&h, peers, 9)
	}
	routerTestExpectNoNetworkMessage(&h, "anything but presence for a returning account")

	// frank is new and unrestricted: everyone hears his full summary, then his presence.
	h.state.connectedPeers[5] = true
	MainRouterState_setPeerSession(&h.state, 5, RouterPeerSession_init())
	frank = routerCompleteHandshake(
		&h,
		5,
		userID = 6,
		nickname = "frank",
		created = true,
		roleIDs = []int{7, 11},
	)
	defer common.TransportState_deinit(&frank)
	frankSession, _ := MainRouterState_getPeerSession(&h.state, 5)
	toldFrank: [4]bool
	for _ in 0 ..< 4 {
		recipient, user := routerRegistrationTestUserUpdated(&h, peers, 6)
		defer common.UserSummary_deinit(&user)
		assert(
			user.nickname == "frank" &&
			user.isOnline &&
			!user.isAdmin &&
			!user.isRestricted &&
			!user.hasEncryptionKey &&
			user.identityPublicKey == frankSession.clientIdentityPublicKey &&
			len(user.roleIds) == 2 &&
			user.roleIds[0] == 7 &&
			user.roleIds[1] == 11,
			fmt.tprintf("expected frank's full summary, got %v", user),
		)
		toldFrank[recipient - 1] = true
	}
	assert(toldFrank == {true, true, true, true}, "expected every other session told once")
	for _ in 0 ..< 4 {
		routerRegistrationTestPresence(&h, peers, 6)
	}
	routerTestExpectNoNetworkMessage(&h, "more about frank")
	routerTestExpectNoDatabaseQuery(&h, "a visibility check for an unrestricted account")

	// erin is new and restricted: the approver hears at once; the others only when the
	// database says they share a room, which only bob does.
	h.state.connectedPeers[6] = true
	MainRouterState_setPeerSession(&h.state, 6, RouterPeerSession_init())
	erin := routerCompleteHandshake(
		&h,
		6,
		userID = 5,
		nickname = "erin",
		isRestricted = true,
		created = true,
	)
	defer common.TransportState_deinit(&erin)
	recipient, user := routerRegistrationTestUserUpdated(&h, peers, 5)
	assert(
		recipient == 3 && user.isRestricted && user.isOnline,
		fmt.tprintf("expected the approver told erin is restricted, got %v", user),
	)
	common.UserSummary_deinit(&user)
	assert(routerRegistrationTestPresence(&h, peers, 5) == 3, "expected the approver's presence")
	routerTestExpectNoNetworkMessage(&h, "erin before the database answered")
	for kind in ([]common.MessageType{.ServerUserUpdated, .ServerUserPresence}) {
		check := routerPollDatabaseQuery(&h)
		defer IPC__database_query_request_deinit(check.request)
		shared, sharedOK := check.request.(common.DatabaseSharedRoomsRequest)
		assert(
			sharedOK && shared.userId == 5 && len(shared.candidateUserIds) == 4,
			fmt.tprintf("expected bob, carol, dave and frank checked, got %v", check.request),
		)
		answer := make([dynamic]int)
		append(&answer, 2)
		MainRouterState_handleDatabaseResult(
			&h.pm,
			&h.state,
			check.request_id,
			common.DatabaseQueryResponse {
				success = true,
				result = common.DatabaseSharedRoomsResult{userIds = answer},
			},
		)
		recipientPeer, packet := routerTestReceive(&h, peers)
		defer delete(packet.payload)
		assert(
			recipientPeer == 1 && packet.messageType == kind,
			fmt.tprintf("expected bob to get %v, got %v", kind, packet.messageType),
		)
		if kind == .ServerUserUpdated {
			updated: common.ServerUserUpdatedPayload
			assert(cbor.unmarshal(packet.payload, &updated) == nil, "expected its payload")
			defer common.UserSummary_deinit(&updated.user)
			assert(updated.user.id == 5 && updated.user.isRestricted, "expected erin restricted")
		}
		routerTestExpectNoNetworkMessage(&h, "erin to the accounts that share no room with her")
	}
}

// #115: an applicant still connected when the approval re-runs its identity statement, whose
// room went away in between, is answered Declined with the server's reason and disconnected;
// approving such a request is refused with its own sentence.
@(test)
testApprovedRequestWhoseRoomWentAwayIsDeclinedLive :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)

	approverTransport := routerCompleteHandshake(&h, 1, userID = 5, nickname = "approver")
	defer common.TransportState_deinit(&approverTransport)
	if session, ok := &h.state.peerSessions[1]; ok {
		session.permissions = {.ApproveRegistrations}
	}
	client := routerRegistrationTestBegin(&h, 2, nickname = "erin", mode = .InviteApproval)
	defer common.TransportState_deinit(&client.transport)

	// Approving a request whose room is already gone is refused.
	routerTestSendSealed(
		&h,
		&approverTransport,
		1,
		.ClientDecideRegistration,
		common.ClientDecideRegistrationPayload{id = 9, approve = true},
	)
	refusedQuery := routerPollDatabaseQuery(&h)
	IPC__database_query_request_deinit(refusedQuery.request)
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		refusedQuery.request_id,
		common.DatabaseQueryResponse {
			success = true,
			result = common.DatabaseRegistrationRequestsResult{outcome = .RoomUnavailable},
		},
	)
	refusal := routerTestOpenInnerPacket(&h, &approverTransport)
	defer delete(refusal.payload)
	refusalPayload: common.ProtocolErrorResponse
	assert(
		refusal.messageType == .ServerProtocolError &&
		cbor.unmarshal(refusal.payload, &refusalPayload) == nil,
		"expected the approval refused",
	)
	defer delete(refusalPayload.message)
	testing.expect_value(
		t,
		refusalPayload.message,
		common.REGISTRATION_ROOM_UNAVAILABLE_MESSAGE,
	)
	routerTestExpectNoDatabaseQuery(&h, "an identity re-run after a refused approval")

	// An approval that went through, with the room gone before the account was made.
	routerTestSendSealed(
		&h,
		&approverTransport,
		1,
		.ClientDecideRegistration,
		common.ClientDecideRegistrationPayload{id = 9, approve = true},
	)
	decide := routerPollDatabaseQuery(&h)
	IPC__database_query_request_deinit(decide.request)
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		decide.request_id,
		common.DatabaseQueryResponse {
			success = true,
			result = common.DatabaseRegistrationRequestsResult {
				outcome = .Applied,
				request = {
					id = 9,
					nickname = strings.clone("erin"),
					status = .Approved,
					identityPublicKey = client.publicKey,
				},
			},
		},
	)
	result := routerTestOpenInnerPacket(&h, &approverTransport)
	delete(result.payload)
	assert(result.messageType == .ServerAdminActionResult, "expected the approver's answer")
	badge := routerTestOpenInnerPacket(&h, &approverTransport)
	delete(badge.payload)
	assert(badge.messageType == .ServerRegistrationRequestUpdated, "expected the badge update")

	identity := routerPollDatabaseQuery(&h)
	IPC__database_query_request_deinit(identity.request)
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		identity.request_id,
		common.DatabaseQueryResponse {
			success = true,
			result = common.DatabaseUserIdentityResult {
				needsRegistration = true,
				registrationMode = .InviteApproval,
				requestStatus = .Declined,
				decisionReason = strings.clone(common.REGISTRATION_ROOM_GONE_REASON),
			},
		},
	)
	declined := routerRegistrationTestResponse(&h, &client)
	defer common.ServerRegisterResponsePayload_deinit(&declined)
	expected := strings.concatenate(
		{common.REGISTRATION_DECLINED_MESSAGE, ": ", common.REGISTRATION_ROOM_GONE_REASON},
	)
	defer delete(expected)
	assert(
		declined.status == .Declined && declined.message == expected,
		fmt.tprintf("expected Declined with the server's reason, got %v", declined),
	)
	disconnect := routerPollDisconnect(&h)
	assert(disconnect.peerId == 2, "expected the applicant disconnected")
	session, _ := MainRouterState_getPeerSession(&h.state, 2)
	assert(
		!session.isRegistering && !session.isAuthenticated,
		"expected the session ended, not authenticated",
	)
}

// #104 (D17): restricted erin is a member of invite room 8; an admin edits it to Public, which
// adds bob and carol. erin's sessions and theirs get a fresh ServerUserList, one per session;
// the admin, who was a member already and is not restricted, does not.
@(test)
testRoomMadePublicRefreshesRestrictedUserLists :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)

	admin := routerCompleteHandshake(&h, 1, userID = 1, nickname = "admin", isAdmin = true)
	defer common.TransportState_deinit(&admin)
	sessions := [?]struct {
		peerID:       u32,
		userID:       int,
		nickname:     string,
		isRestricted: bool,
	} {
		{2, 2, "bob", false},
		{3, 3, "carol", false},
		{4, 5, "erin", true},
		{5, 5, "erin", true},
		{6, 7, "dave", false},
	}
	transports: [len(sessions)]common.TransportState
	defer for &transport in transports {
		common.TransportState_deinit(&transport)
	}
	peers := make([dynamic]RouterTestPeer, 0, len(sessions) + 1)
	defer delete(peers)
	append(&peers, RouterTestPeer{peerID = 1, transport = &admin})
	for entry, index in sessions {
		append(&peers, RouterTestPeer{peerID = entry.peerID, transport = &transports[index]})
	}
	// Each sign-in's presence (and the visibility checks it asks for) is dropped before the
	// next handshake, which reads the next queued messages.
	for entry, index in sessions {
		h.state.connectedPeers[entry.peerID] = true
		MainRouterState_setPeerSession(&h.state, entry.peerID, RouterPeerSession_init())
		transports[index] = routerCompleteHandshake(
			&h,
			entry.peerID,
			userID = entry.userID,
			nickname = entry.nickname,
			isRestricted = entry.isRestricted,
		)
		routerRegistrationTestDrainNetwork(&h, peers[:])
		for {
			msg, err := IPC_Client_poll(h.databaseFd)
			if err != nil {
				break
			}
			if query, isQuery := msg.(DatabaseQuery); isQuery {
				if pending, found := h.state.pendingDatabaseRequests[query.request_id]; found {
					PendingDBRequest_deinit(pending)
					delete_key(&h.state.pendingDatabaseRequests, query.request_id)
				}
				IPC__database_query_request_deinit(query.request)
			}
		}
	}

	routerTestSendSealed(
		&h,
		&admin,
		1,
		.ClientEditRoom,
		common.ClientEditRoomPayload {
			roomId = 8,
			name = "lounge",
			description = "",
			roomType = .ChatAndVoice,
			access = .Public,
		},
	)
	edit := routerPollDatabaseQuery(&h)
	IPC__database_query_request_deinit(edit.request)
	added := make([dynamic]int)
	append(&added, 2, 3)
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		edit.request_id,
		common.DatabaseQueryResponse {
			success = true,
			result = common.DatabaseRoomMutationResult {
				room = {
					id = 8,
					name = strings.clone("lounge"),
					description = strings.clone(""),
					roomType = .ChatAndVoice,
					access = .Public,
					historyVisibility = .Full,
				},
				changed = true,
				addedUserIDs = added,
			},
		},
	)
	routerRegistrationTestDrainNetwork(&h, peers[:])
	recipients := routerPollDatabaseQuery(&h)
	IPC__database_query_request_deinit(recipients.request)
	members := make([dynamic]int)
	append(&members, 1, 2, 3, 5)
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		recipients.request_id,
		common.DatabaseQueryResponse {
			success = true,
			result = common.DatabaseRoomMemberListResult{userIDs = members, roomFound = true},
		},
	)
	routerRegistrationTestDrainNetwork(&h, peers[:])

	listed: map[u32]int
	defer delete(listed)
	for {
		msg, err := IPC_Client_poll(h.databaseFd)
		if err != nil {
			break
		}
		query, isQuery := msg.(DatabaseQuery)
		if !isQuery {
			continue
		}
		if directory, isDirectory := query.request.(common.DatabaseUserDirectoryRequest);
		   isDirectory {
			pending := h.state.pendingDatabaseRequests[query.request_id]
			listed[pending.peerID] += 1
			session, _ := MainRouterState_getPeerSession(&h.state, pending.peerID)
			assert(
				directory.viewerUserId == session.authenticatedUserID,
				"expected each list built for its own session's account",
			)
		}
		IPC__database_query_request_deinit(query.request)
	}
	assert(
		len(listed) == 4 &&
		listed[2] == 1 &&
		listed[3] == 1 &&
		listed[4] == 1 &&
		listed[5] == 1,
		fmt.tprintf("expected one fresh list for bob, carol and erin's two sessions, got %v", listed),
	)
}
