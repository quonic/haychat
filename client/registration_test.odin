#+feature dynamic-literals
package client

import "../common"
import "core:encoding/cbor"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:testing"

// Registration in the client (protocol 25, #43 G2): the registering transport, the sign-up
// phases in State, the approver badge, the invite form, and the harness commands and events.

// A valid code, as formatInviteCode spells one.
REGISTRATION_TEST_CODE :: "0123-4567-89AB-CDEF-GHJK-MNPQ-RSTV-WXYZ"

registrationSendBridgeTestMutex: sync.Mutex
// Requests the stub saw for registrationTestServerID; other tests' sends (another server's
// Connected asks for the badge count) are ignored.
registrationTestServerID: int
registrationTestRequests: [dynamic]RegistrationRequest
registrationTestCodes: [dynamic]string
registrationTestReasons: [dynamic]string

registrationSendBridgeTestStub :: proc(
	transport: ^ClientServerTransport,
	request: RegistrationRequest,
) -> bool {
	if transport.serverID != registrationTestServerID {
		return false
	}
	recorded := request
	code := strings.clone(request.code)
	reason := strings.clone(request.reason)
	append(&registrationTestCodes, code)
	append(&registrationTestReasons, reason)
	recorded.code = code
	recorded.reason = reason
	recorded.note = ""
	append(&registrationTestRequests, recorded)
	return true
}

// Swaps in the stub for serverID; call with registrationSendBridgeTestMutex held and run
// testRegistrationRestore after.
testRegistrationUseStub :: proc(serverID: int) {
	registrationTestServerID = serverID
	registrationSendBridge = registrationSendBridgeTestStub
}

testRegistrationRestore :: proc() {
	registrationSendBridge = ClientServerTransport_sendRegistrationRequest
	registrationTestServerID = 0
	for text in registrationTestCodes {
		delete(text)
	}
	for text in registrationTestReasons {
		delete(text)
	}
	delete(registrationTestCodes)
	delete(registrationTestReasons)
	delete(registrationTestRequests)
	registrationTestCodes = nil
	registrationTestReasons = nil
	registrationTestRequests = nil
}

testRegistrationServer :: proc(serverID: int) -> Server {
	return Server {
		id = serverID,
		name = "Signup",
		short_name = "S",
		host = "chat.example",
		port = 4000,
		pinned_server_public_key = strings.repeat("ab", 32, context.temp_allocator),
		pinned_server_fingerprint = strings.repeat("cd", 32, context.temp_allocator),
	}
}

testApplyRegistrationRequired :: proc(
	state: ^State,
	serverID: int,
	mode: common.RegistrationMode,
	status: common.RegistrationRequestStatus = .None,
) {
	event := ClientTransportRuntimeEvent {
		kind                      = .RegistrationRequired,
		serverID                  = serverID,
		registrationMode          = mode,
		registrationRequestStatus = status,
		message                   = strings.clone(common.REGISTRATION_REQUIRED_MESSAGE),
	}
	State_applyRuntimeEvent(state, &event)
	ClientTransportRuntimeEvent_deinit(&event)
}

testApplyRegisterResult :: proc(
	state: ^State,
	serverID: int,
	status: common.RegisterStatus,
	message: string,
) {
	event := ClientTransportRuntimeEvent {
		kind           = .RegistrationResult,
		serverID       = serverID,
		registerStatus = status,
		message        = strings.clone(message),
	}
	if status == .Declined {
		event.failureKind = .RegistrationDeclined
	}
	State_applyRuntimeEvent(state, &event)
	ClientTransportRuntimeEvent_deinit(&event)
}

// Seals one server packet and hands it to the registering session's handler.
testDeliverRegistering :: proc(
	transport: ^ClientServerTransport,
	serverTransport: ^common.TransportState,
	messageType: common.MessageType,
	payload: any,
) -> (
	ClientTransportRuntimeEvent,
	bool,
) {
	sealedPacket, sealOK := common.sealPacketForSession(serverTransport, messageType, payload)
	assert(sealOK, fmt.tprintf("expected the server to seal %v", messageType))
	defer delete(sealedPacket.payload)
	bytes, bytesOK := common.marshalPacket(sealedPacket)
	assert(bytesOK, "expected the sealed packet to marshal")
	defer delete(bytes)
	return ClientServerTransport_handleRegisteringPacketBytes(transport, {}, bytes)
}

@(test)
testRegistrationRequiredActivatesTheTransportAndSendsRegistering :: proc(t: ^testing.T) {
	server := testRegistrationServer(1201)
	server.pinned_server_public_key = ""
	server.pinned_server_fingerprint = ""
	server.use_invite_code = true
	config := testConfigWithServers({server})
	defer Config_deinit(&config)
	transport, message, ok := ClientServerTransport_init(config.servers[0], config)
	assert(ok, message)
	defer ClientServerTransport_deinit(&transport)
	testing.expect(t, transport.registering, "expected Use an invite code to set registering")

	serverPrivateKey, serverPublicKey, identityOK := common.generateIdentityKeyPair()
	assert(identityOK, "expected a server identity key")
	helloBytes, helloOK := ClientServerTransport_beginHandshake(&transport)
	delete(helloBytes)
	assert(helloOK, "expected ClientHello to encode")
	_, serverEphemeralPublicKey, _ := common.generateKeyExchangeKeyPair()
	sessionID, _ := common.generateSessionID()
	serverHelloBytes, _ := buildServerHelloPacketBytes(
		&transport,
		serverPrivateKey,
		serverPublicKey,
		serverEphemeralPublicKey,
		sessionID,
	)
	defer delete(serverHelloBytes)
	_, helloHandled := ClientServerTransport_handleIncomingPacket(&transport, serverHelloBytes)
	assert(helloHandled, "expected ServerHello to be accepted")
	challenge, _ := common.generateAuthChallenge()
	challengeBytes, _ := common.buildPacketBytes(
		.ServerAuthChallenge,
		common.ServerAuthChallengePayload{sessionID = transport.sessionID, challenge = challenge},
	)
	defer delete(challengeBytes)
	challengeResult, challengeOK := ClientServerTransport_handleIncomingPacket(
		&transport,
		challengeBytes,
	)
	assert(challengeOK && challengeResult.hasResponse, "expected a ClientAuthRequest")
	defer delete(challengeResult.responsePacketBytes)
	outer: common.Packet
	assert(cbor.unmarshal(challengeResult.responsePacketBytes, &outer) == nil, "expected a packet")
	defer delete(outer.payload)
	authRequest: common.ClientAuthRequestPayload
	assert(cbor.unmarshal(outer.payload, &authRequest) == nil, "expected an auth request")
	testing.expect(t, authRequest.registering, "expected ClientAuthRequest.registering set")

	// The plaintext notice activates the transport exactly as ServerAuthSuccess would.
	requiredBytes, _ := common.buildPacketBytes(
		.ServerRegistrationRequired,
		common.ServerRegistrationRequiredPayload {
			mode = .InviteApproval,
			status = .None,
			message = common.REGISTRATION_APPROVAL_REQUIRED_MESSAGE,
		},
	)
	defer delete(requiredBytes)
	result, requiredOK := ClientServerTransport_handleIncomingPacket(&transport, requiredBytes)
	defer common.ServerRegistrationRequiredPayload_deinit(&result.registration)
	testing.expect(t, requiredOK && result.hasRegistration, "expected the registration notice")
	testing.expect(
		t,
		result.registration.mode == .InviteApproval &&
		result.registration.message == common.REGISTRATION_APPROVAL_REQUIRED_MESSAGE,
		"expected the notice's mode and message",
	)
	testing.expect(
		t,
		common.TransportState_canEncrypt(&transport.transport) && !transport.pendingKeysReady,
		"expected the transport to be active with the handshake keys wiped",
	)
	testing.expect(t, transport.authenticatedUserID == 0, "expected no account yet")

	// A second notice (or a success) after that is out of order.
	again, againOK := ClientServerTransport_handleIncomingPacket(&transport, requiredBytes)
	common.ServerRegistrationRequiredPayload_deinit(&again.registration)
	testing.expect(t, !againOK, "expected a second notice to fail the handshake")
}

@(test)
testRegisteringSessionAnswersBecomeEvents :: proc(t: ^testing.T) {
	server := testRegistrationServer(1202)
	config := testConfigWithServers({server})
	defer Config_deinit(&config)
	transport, serverTransport, _ := buildEstablishedTransportPair(config.servers[0], config)
	defer ClientServerTransport_deinit(&transport)
	defer common.TransportState_deinit(&serverTransport)
	transport.authenticatedUserID = 0
	transport.connection.status = .Registering
	transport.registerInFlight = true

	// Refused: the session stays registering, with the reason kept.
	event, ok := testDeliverRegistering(
		&transport,
		&serverTransport,
		.ServerRegisterResponse,
		common.ServerRegisterResponsePayload {
			status = .Refused,
			message = common.INVITE_CODE_INVALID_MESSAGE,
		},
	)
	testing.expect(
		t,
		ok &&
		event.kind == .RegistrationResult &&
		event.registerStatus == .Refused &&
		event.message == common.INVITE_CODE_INVALID_MESSAGE &&
		transport.connection.status == .Registering &&
		!transport.registerInFlight,
		"expected a refusal to keep the session registering",
	)
	ClientTransportRuntimeEvent_deinit(&event)

	// Pending, then the session ends: a failure that waits for Check again.
	event, ok = testDeliverRegistering(
		&transport,
		&serverTransport,
		.ServerRegisterResponse,
		common.ServerRegisterResponsePayload {
			status = .Pending,
			message = common.REGISTRATION_PENDING_MESSAGE,
		},
	)
	testing.expect(
		t,
		ok && event.registerStatus == .Pending && transport.registrationPending,
		"expected Pending",
	)
	ClientTransportRuntimeEvent_deinit(&event)

	// Approved live: Created takes the account and is the normal Connected.
	auth := common.ServerAuthSuccessPayload {
		userId           = 31,
		message          = "ok",
		nickname         = "carol",
		permissions      = {.CreateInvites},
		registrationMode = .InviteApproval,
		isRestricted     = true,
	}
	event, ok = testDeliverRegistering(
		&transport,
		&serverTransport,
		.ServerRegisterResponse,
		common.ServerRegisterResponsePayload{status = .Created, message = "ok", auth = auth},
	)
	testing.expect(
		t,
		ok &&
		event.kind == .Connected &&
		event.registered &&
		event.userID == 31 &&
		event.nickname == "carol" &&
		event.permissions == {.CreateInvites} &&
		event.registrationMode == .InviteApproval &&
		event.isRestricted &&
		transport.connection.status == .Established &&
		!transport.registrationPending,
		fmt.tprintf("expected Created to connect, got %v", event.kind),
	)
	ClientTransportRuntimeEvent_deinit(&event)
}

@(test)
testRegisteringSessionDeclineAndEndAreNotRetried :: proc(t: ^testing.T) {
	server := testRegistrationServer(1203)
	config := testConfigWithServers({server})
	defer Config_deinit(&config)
	{
		transport, serverTransport, _ := buildEstablishedTransportPair(config.servers[0], config)
		defer ClientServerTransport_deinit(&transport)
		defer common.TransportState_deinit(&serverTransport)
		transport.connection.status = .Registering
		declined := strings.concatenate({common.REGISTRATION_DECLINED_MESSAGE, ": not now"})
		defer delete(declined)
		event, ok := testDeliverRegistering(
			&transport,
			&serverTransport,
			.ServerRegisterResponse,
			common.ServerRegisterResponsePayload{status = .Declined, message = declined},
		)
		testing.expect(
			t,
			ok &&
			event.kind == .RegistrationResult &&
			event.registerStatus == .Declined &&
			event.failureKind == .RegistrationDeclined &&
			!event.retryable &&
			transport.connection.status == .Failed,
			"expected a decline to stop the transport without a retry",
		)
		testing.expect(
			t,
			classifyConnectFailure(event.message) == .RegistrationDeclined,
			"expected the decline's sentence to classify as a decline",
		)
		ClientTransportRuntimeEvent_deinit(&event)
	}
	{
		transport, _, _ := buildEstablishedTransportPair(config.servers[0], config)
		defer ClientServerTransport_deinit(&transport)
		transport.connection.status = .Registering
		transport.registrationPending = true
		event := ClientServerTransport_registrationEnded(&transport, {}, "gone")
		testing.expect(
			t,
			event.failureKind == .RegistrationPending &&
			!event.retryable &&
			transport.connection.status == .Failed &&
			classifyConnectFailure(event.message) == .RegistrationPending,
			"expected a pending session that ended to wait for Check again",
		)
		ClientTransportRuntimeEvent_deinit(&event)
	}
	{
		transport, _, _ := buildEstablishedTransportPair(config.servers[0], config)
		defer ClientServerTransport_deinit(&transport)
		transport.connection.status = .Registering
		transport.registrationRefusal = strings.clone(common.REGISTRATION_TIMED_OUT_MESSAGE)
		event := ClientServerTransport_registrationEnded(&transport, {}, "gone")
		testExpectString(
			t,
			event.message,
			"Sign-up ended: Sign-up took too long",
			"the ended sign-up's message",
		)
		testing.expect(
			t,
			event.failureKind == .RegistrationRequired && !event.retryable,
			"expected an ended sign-up not to be retried",
		)
		ClientTransportRuntimeEvent_deinit(&event)
	}
	testing.expect(
		t,
		classifyConnectFailure(common.REGISTRATION_BUSY_MESSAGE) == .RegistrationBusy &&
		connectFailureIsRetryable(.RegistrationBusy),
		"expected the busy refusal to be retried",
	)

	// Nothing but ClientRegister goes out while registering, and that only while registering.
	transport, _, _ := buildEstablishedTransportPair(config.servers[0], config)
	defer ClientServerTransport_deinit(&transport)
	transport.connection.status = .Established
	testing.expect(
		t,
		!ClientServerTransport_sendRegister(&transport, REGISTRATION_TEST_CODE, ""),
		"expected no ClientRegister on an established session",
	)
	transport.connection.status = .Registering
	testing.expect(
		t,
		!ClientServerTransport_requestRoomList(&transport),
		"expected no runtime request while registering",
	)
}

@(test)
testRegistrationAdminPacketsBecomeEvents :: proc(t: ^testing.T) {
	transport := testAdminTransport(1204)
	defer ClientServerTransport_deinit(&transport)
	{
		event := testAdminTranslate(
			&transport,
			.ServerRegistrationMode,
			common.ServerRegistrationModePayload{mode = .InviteOnly},
		)
		testing.expect(
			t,
			event.kind == .RegistrationModeChanged && event.registrationMode == .InviteOnly,
			"expected the mode broadcast",
		)
		ClientTransportRuntimeEvent_deinit(&event)
	}
	{
		event := testAdminTranslate(
			&transport,
			.ServerInviteCreated,
			common.ServerInviteCreatedPayload {
				invite = {id = 5, note = "for carol", maxUses = 1},
				code = REGISTRATION_TEST_CODE,
			},
		)
		testing.expect(
			t,
			event.kind == .InviteCreated &&
			event.invite.id == 5 &&
			event.invite.note == "for carol" &&
			event.inviteCode == REGISTRATION_TEST_CODE,
			"expected the created invite with its code",
		)
		ClientTransportRuntimeEvent_deinit(&event)
	}
	{
		requests := [dynamic]common.RegistrationRequestSummary {
			{id = 3, nickname = "dave", reason = "friend", status = .Pending},
		}
		defer delete(requests)
		event := testAdminTranslate(
			&transport,
			.ServerRegistrationRequests,
			common.ServerRegistrationRequestsPayload{requests = requests, pendingCount = 4},
		)
		testing.expect(
			t,
			event.kind == .RegistrationRequests &&
			len(event.registrationRequests) == 1 &&
			event.registrationRequests[0].nickname == "dave" &&
			event.pendingCount == 4,
			"expected the request list with the pending count",
		)
		ClientTransportRuntimeEvent_deinit(&event)
	}
	{
		event := testAdminTranslate(
			&transport,
			.ServerRegistrationRequestUpdated,
			common.ServerRegistrationRequestUpdatedPayload {
				request = {id = 3, nickname = "dave", status = .Approved},
				pendingCount = 3,
			},
		)
		testing.expect(
			t,
			event.kind == .RegistrationRequestUpdated &&
			event.registrationRequest.status == .Approved &&
			event.pendingCount == 3,
			"expected the request update",
		)
		ClientTransportRuntimeEvent_deinit(&event)
	}
	{
		event := testAdminTranslate(
			&transport,
			.ServerAdminActionResult,
			common.ServerAdminActionResultPayload {
				action = .RevokeInvite,
				message = "Revoked",
				inviteId = 5,
			},
		)
		testing.expect(
			t,
			event.kind == .AdminActionResult &&
			event.adminAction == .RevokeInvite &&
			event.inviteID == 5,
			"expected the revoke answer with the invite ID",
		)
		ClientTransportRuntimeEvent_deinit(&event)
	}
	{
		event := testAdminTranslate(
			&transport,
			.ServerAccountUpdated,
			common.ServerAccountUpdatedPayload{nickname = "erin", isRestricted = true},
		)
		testing.expect(
			t,
			event.kind == .AccountUpdated && event.isRestricted,
			"expected the account update to carry the restriction",
		)
		ClientTransportRuntimeEvent_deinit(&event)
	}
}

@(test)
testInviteCodeFieldIsTrimmedAndCheckedBeforeSending :: proc(t: ^testing.T) {
	testExpectString(
		t,
		normalizeInviteCodeInput(" 0123-4567 89ab\tcdef-\nGHJK "),
		"0123456789ABCDEFGHJK",
		"the normalized code",
	)
	testing.expect(
		t,
		validateSignUp(.InviteOnly, "", "") == SIGN_UP_CODE_REQUIRED_LOCAL,
		"expected a code to be required on an invite server",
	)
	testing.expect(
		t,
		validateSignUp(.Open, "", "") == "",
		"expected an Open server to accept no code",
	)
	testing.expect(
		t,
		validateSignUp(.InviteOnly, "ABC", "") == SIGN_UP_CODE_INVALID_LOCAL,
		"expected a short code to be refused locally",
	)
	normalized := normalizeInviteCodeInput(REGISTRATION_TEST_CODE)
	testing.expect(
		t,
		validateSignUp(.InviteApproval, normalized, "") == SIGN_UP_REASON_REQUIRED_LOCAL,
		"expected approval mode to need a reason",
	)
	testing.expect(
		t,
		validateSignUp(.InviteApproval, normalized, "I am Bob's sister") == "",
		"expected a code and a reason to pass",
	)
	testing.expect(
		t,
		validateSignUp(
			.InviteApproval,
			normalized,
			strings.repeat("x", 501, context.temp_allocator),
		) ==
		SIGN_UP_REASON_INVALID_LOCAL,
		"expected a reason over 500 characters to be refused",
	)
}

@(test)
testSignUpFlowThroughTheBridge :: proc(t: ^testing.T) {
	sync.mutex_lock(&registrationSendBridgeTestMutex)
	defer sync.mutex_unlock(&registrationSendBridgeTestMutex)
	testRegistrationUseStub(1205)
	defer testRegistrationRestore()

	state := testUpdateStateForServer(testRegistrationServer(1205))
	defer State_deinit(&state)
	testing.expect(t, !State_signUpVisible(&state), "expected no sign-up screen before asked")

	testApplyRegistrationRequired(&state, 1205, .InviteApproval)
	connection := State_serverConnection(&state, 1205)
	testing.expect(
		t,
		connection.status == .Registering && connection.signUp == .Required,
		"expected the registering state",
	)
	view := buildSignUpView(&state)
	testing.expect(
		t,
		view.visible && view.showForm && view.showReason && view.submitEnabled,
		"expected the code and reason fields in approval mode",
	)

	// A bad code never goes out.
	State_pasteSignUpCode(&state, 1205, "nope")
	testing.expect(
		t,
		State_submitSignUp(&state, 1205) == SIGN_UP_CODE_INVALID_LOCAL &&
		len(registrationTestRequests) == 0,
		"expected a malformed code to stay local",
	)

	// A pasted code is trimmed; the reason goes with it.
	State_pasteSignUpCode(&state, 1205, " 0123-4567-89ab-cdef ghjk-mnpq-rstv-wxyz ")
	testExpectString(
		t,
		string(state.signUpForm.code[:]),
		"0123456789ABCDEFGHJKMNPQRSTVWXYZ",
		"the pasted code",
	)
	append(&state.signUpForm.reason, "  Bob's sister  ")
	testExpectString(t, State_submitSignUp(&state, 1205), "", "the sign-up send")
	testing.expect(
		t,
		len(registrationTestRequests) == 1 &&
		registrationTestRequests[0].kind == .Register &&
		registrationTestRequests[0].code == "0123456789ABCDEFGHJKMNPQRSTVWXYZ" &&
		registrationTestRequests[0].reason == "Bob's sister",
		"expected one ClientRegister with the trimmed code and reason",
	)
	testing.expect(
		t,
		State_serverConnection(&state, 1205).signUp == .Submitting &&
		len(State_submitSignUp(&state, 1205)) > 0 &&
		len(registrationTestRequests) == 1,
		"expected one sign-up at a time",
	)

	// Refused keeps the code, so the user can fix it.
	testApplyRegisterResult(&state, 1205, .Refused, common.INVITE_CODE_INVALID_MESSAGE)
	view = buildSignUpView(&state)
	testing.expect(
		t,
		view.phase == .Refused &&
		view.error == common.INVITE_CODE_INVALID_MESSAGE &&
		len(state.signUpForm.code) > 0,
		"expected the refusal shown with the code kept",
	)

	// Pending wipes the code and shows the waiting screen.
	testExpectString(t, State_submitSignUp(&state, 1205), "", "the second sign-up")
	testApplyRegisterResult(&state, 1205, .Pending, common.REGISTRATION_PENDING_MESSAGE)
	view = buildSignUpView(&state)
	testing.expect(
		t,
		view.phase == .Pending && !view.showForm && len(state.signUpForm.code) == 0,
		"expected the waiting screen and the code gone",
	)

	// The session ends while pending: Check again, which reconnects without sending again.
	ended := ClientTransportRuntimeEvent {
		kind        = .ConnectFailed,
		serverID    = 1205,
		message     = strings.clone(common.REGISTRATION_PENDING_MESSAGE),
		failureKind = .RegistrationPending,
	}
	State_applyRuntimeEvent(&state, &ended)
	ClientTransportRuntimeEvent_deinit(&ended)
	view = buildSignUpView(&state)
	testing.expect(
		t,
		view.visible && view.showCheckAgain && view.phase == .Pending,
		"expected Check again after the session ended",
	)
	State_signUpReconnect(&state, 1205)
	testing.expect(
		t,
		State_signUpVisible(&state) && buildSignUpView(&state).reconnecting,
		"expected the waiting screen to stay while it connects",
	)
	testing.expect(t, len(registrationTestRequests) == 2, "expected Check again to send nothing")

	// Approved: the account exists, the screen goes.
	testApplyConnected(&state, 1205, 41)
	testing.expect(
		t,
		!State_signUpVisible(&state) && State_serverConnection(&state, 1205).signUp == .None,
		"expected the sign-up screen to go once connected",
	)
}

@(test)
testDeclinedSignUpIsShownLikeABan :: proc(t: ^testing.T) {
	state := testUpdateStateForServer(testRegistrationServer(1206))
	defer State_deinit(&state)
	testApplyRegistrationRequired(&state, 1206, .InviteOnly)
	State_prefillSignUpCode(&state, 1206, REGISTRATION_TEST_CODE)
	message := strings.concatenate({common.REGISTRATION_DECLINED_MESSAGE, ": not today"})
	defer delete(message)
	testApplyRegisterResult(&state, 1206, .Declined, message)
	connection := State_serverConnection(&state, 1206)
	testing.expect(
		t,
		connection.status == .Failed &&
		!connection.retryable &&
		connection.failureKind == .RegistrationDeclined &&
		connection.signUp == .Declined &&
		len(state.signUpForm.code) == 0,
		"expected a decline to stop the connection and wipe the code",
	)
	view := buildSignUpView(&state)
	testing.expect(
		t,
		view.visible && view.showStartAgain && view.text == message,
		"expected the decline's reason with Start again",
	)
	banner := buildConnectionBanner(&state, {})
	testExpectString(t, banner.summary, "Sign-up declined", "the footer for a decline")

	// A pending request found at sign-in goes straight to the waiting screen.
	testApplyRegistrationRequired(&state, 1206, .InviteApproval, .Pending)
	testing.expect(
		t,
		State_serverConnection(&state, 1206).signUp == .Pending,
		"expected a pending request to show the waiting screen",
	)
}

@(test)
testApproverBadgeFollowsTheServerCount :: proc(t: ^testing.T) {
	sync.mutex_lock(&registrationSendBridgeTestMutex)
	defer sync.mutex_unlock(&registrationSendBridgeTestMutex)
	testRegistrationUseStub(1207)
	defer testRegistrationRestore()

	state := testUpdateStateForServer(testRegistrationServer(1207))
	defer State_deinit(&state)
	connected := ClientTransportRuntimeEvent {
		kind        = .Connected,
		serverID    = 1207,
		userID      = 2,
		nickname    = strings.clone("approver"),
		permissions = {.ApproveRegistrations},
	}
	State_applyRuntimeEvent(&state, &connected)
	ClientTransportRuntimeEvent_deinit(&connected)
	testing.expect(
		t,
		len(registrationTestRequests) == 1 &&
		registrationTestRequests[0].kind == .ListRequests &&
		!registrationTestRequests[0].includeDecided,
		"expected an approver to ask for the count after connecting (D18)",
	)

	list := ClientTransportRuntimeEvent {
		kind         = .RegistrationRequests,
		serverID     = 1207,
		pendingCount = 2,
	}
	append(
		&list.registrationRequests,
		common.RegistrationRequestSummary {
			id = 8,
			nickname = strings.clone("dave"),
			reason = strings.clone("friend"),
			status = .Pending,
		},
	)
	State_applyRuntimeEvent(&state, &list)
	ClientTransportRuntimeEvent_deinit(&list)
	testing.expect(t, State_pendingRegistrationCount(&state, 1207) == 2, "expected the count")
	testExpectString(t, serverSettingsGearText(&state, 1207), "⚙ 2", "the gear's badge")

	updated := ClientTransportRuntimeEvent {
		kind                = .RegistrationRequestUpdated,
		serverID            = 1207,
		pendingCount        = 1,
		registrationRequest = {id = 8, nickname = strings.clone("dave"), status = .Approved},
	}
	State_applyRuntimeEvent(&state, &updated)
	ClientTransportRuntimeEvent_deinit(&updated)
	admin := buildRegistrationAdminView(&state, 1207)
	testing.expect(
		t,
		admin.showRequests &&
		!admin.showInvites &&
		!admin.showMode &&
		admin.pendingCount == 1 &&
		len(admin.requests) == 1 &&
		!admin.requests[0].pending &&
		admin.requests[0].statusLabel == "Approved",
		"expected the update to replace the request and the count",
	)
	testExpectString(t, pendingBadgeText(admin.pendingCount), "1 pending", "the badge text")
	section := buildAdminSectionView(&state, 1207)
	testing.expect(
		t,
		section.visible && section.pendingCount == 1 && !section.showMembers,
		"expected the Admin section for an approver with the badge",
	)

	// The permission goes: so does the badge.
	lost := ClientTransportRuntimeEvent {
		kind     = .AccountUpdated,
		serverID = 1207,
		nickname = strings.clone("approver"),
	}
	State_applyRuntimeEvent(&state, &lost)
	ClientTransportRuntimeEvent_deinit(&lost)
	testing.expect(
		t,
		State_pendingRegistrationCount(&state, 1207) == 0 &&
		serverSettingsGearText(&state, 1207) == "⚙",
		"expected no badge without ApproveRegistrations",
	)
}

@(test)
testInviteFormAndCreatedCode :: proc(t: ^testing.T) {
	sync.mutex_lock(&registrationSendBridgeTestMutex)
	defer sync.mutex_unlock(&registrationSendBridgeTestMutex)
	testRegistrationUseStub(1208)
	defer testRegistrationRestore()

	// A non-admin inviter: plain codes within 7 days only (D10).
	{
		form := InviteForm {
			expiryIndex  = 4,
			usesIndex    = 2,
			roleIDCount  = 1,
			roomID       = 7,
			skipApproval = true,
		}
		form.roleIDs[0] = 3
		request := inviteFormRequest(form, false)
		testing.expect(
			t,
			request.roleIDCount == 0 && request.roomID == 0 && !request.skipApproval &&
			request.maxUses == 25,
			"expected a non-admin's request to drop the admin-only fields",
		)
		testing.expect(
			t,
			validateInviteRequest(request, false) == common.INVITE_EXPIRY_REQUIRED_MESSAGE,
			"expected a never-expiring code to be refused for a non-admin",
		)
		testing.expect(
			t,
			!inviteExpiryAllowed(4, false) && inviteExpiryAllowed(2, false) &&
			!inviteExpiryAllowed(3, false) && inviteExpiryAllowed(4, true),
			"expected non-admins to be offered expiries of at most 7 days",
		)
	}

	state := testUpdateStateForServer(testRegistrationServer(1208))
	defer State_deinit(&state)
	testApplyConnectedAs(&state, 1208, 2, true)
	clear(&registrationTestRequests)
	State_openInviteForm(&state, 1208)
	append(&state.inviteForm.note, "for carol")
	State_toggleInviteFormRole(&state, 4)
	State_toggleInviteFormSkipApproval(&state)
	testExpectString(t, State_submitInviteForm(&state), "", "the invite create")
	testing.expect(
		t,
		len(registrationTestRequests) == 1 &&
		registrationTestRequests[0].kind == .CreateInvite &&
		registrationTestRequests[0].expiresInSeconds == 24 * 60 * 60 &&
		registrationTestRequests[0].maxUses == 1 &&
		registrationTestRequests[0].roleIDCount == 1 &&
		registrationTestRequests[0].roleIDs[0] == 4 &&
		registrationTestRequests[0].skipApproval,
		"expected an admin's code with its role and skip approval",
	)

	created := ClientTransportRuntimeEvent {
		kind       = .InviteCreated,
		serverID   = 1208,
		invite     = {id = 9, note = strings.clone("for carol"), maxUses = 1},
		inviteCode = strings.clone(REGISTRATION_TEST_CODE),
	}
	State_applyRuntimeEvent(&state, &created)
	ClientTransportRuntimeEvent_deinit(&created)
	admin := buildRegistrationAdminView(&state, 1208)
	key := strings.repeat("ab", 32, context.temp_allocator)
	testExpectString(t, admin.createdCode, REGISTRATION_TEST_CODE, "the code shown once")
	testExpectString(
		t,
		admin.createdLink,
		fmt.tprintf("haychat://chat.example:4000/invite/%s?key=%s", REGISTRATION_TEST_CODE, key),
		"the invite link",
	)
	testing.expect(
		t,
		!admin.form.open && len(admin.invites) == 1 && admin.invites[0].canRevoke,
		"expected the form closed and the code listed",
	)
	State_dismissCreatedInvite(&state, 1208)
	testing.expect(
		t,
		len(buildRegistrationAdminView(&state, 1208).createdCode) == 0,
		"expected Done to forget the code",
	)

	// A refused create shows the server's sentence.
	State_openInviteForm(&state, 1208)
	testExpectString(t, State_submitInviteForm(&state), "", "the second create")
	refusal := ClientTransportRuntimeEvent {
		kind     = .ProtocolError,
		serverID = 1208,
		message  = strings.clone(common.INVITE_TOO_MANY_MESSAGE),
	}
	State_applyRuntimeEvent(&state, &refusal)
	ClientTransportRuntimeEvent_deinit(&refusal)
	testExpectString(
		t,
		buildRegistrationAdminView(&state, 1208).createError,
		common.INVITE_TOO_MANY_MESSAGE,
		"the refused create",
	)
}

@(test)
testRegistrationAdminActionsGoThroughTheAdminBridge :: proc(t: ^testing.T) {
	sync.mutex_lock(&adminSendBridgeTestMutex)
	defer sync.mutex_unlock(&adminSendBridgeTestMutex)
	testAdminUseStub()
	defer testAdminRestore()

	state := testUpdateStateForServer(testRegistrationServer(1209))
	defer State_deinit(&state)
	testApplyConnectedAs(&state, 1209, 2, true)

	testExpectString(t, State_setRegistrationMode(&state, 1209, .InviteOnly), "", "the mode")
	testing.expect(
		t,
		adminSendBridgeTestLast.action == .SetRegistrationMode &&
		adminSendBridgeTestLast.mode == .InviteOnly,
		"expected SetRegistrationMode",
	)
	testExpectString(t, State_revokeInvite(&state, 1209, 5), "", "the revoke")
	testing.expect(
		t,
		adminSendBridgeTestLast.action == .RevokeInvite && adminSendBridgeTestLast.inviteID == 5,
		"expected RevokeInvite",
	)
	State_openDecisionForm(&state, 8)
	append(&state.decisionForm.reason, " not now ")
	testExpectString(t, State_submitDecline(&state, 1209), "", "the decline")
	testing.expect(
		t,
		adminSendBridgeTestLast.action == .DecideRegistration &&
		adminSendBridgeTestLast.requestID == 8 &&
		!adminSendBridgeTestLast.flag &&
		adminSendBridgeTestReason == "not now",
		"expected a decline with its trimmed reason",
	)
	testExpectString(t, State_setRestricted(&state, 1209, 12, false), "", "the lift")
	testing.expect(
		t,
		adminSendBridgeTestLast.action == .SetRestricted &&
		adminSendBridgeTestLast.userID == 12 &&
		!adminSendBridgeTestLast.flag,
		"expected SetRestricted off",
	)
	testing.expect(
		t,
		len(State_decideRegistration(&state, 1209, 0, true, "")) > 0 &&
		len(State_setRegistrationMode(&state, 1209, {})) > 0,
		"expected malformed requests to stay local",
	)

	// The answer to a decline closes its reason field.
	result := ClientTransportRuntimeEvent {
		kind        = .AdminActionResult,
		serverID    = 1209,
		adminAction = .DecideRegistration,
		requestID   = 8,
		message     = strings.clone("Declined"),
	}
	State_applyRuntimeEvent(&state, &result)
	ClientTransportRuntimeEvent_deinit(&result)
	testing.expect(t, state.decisionForm.requestID == 0, "expected the decline form closed")

	// Lift restriction is offered for a restricted account only.
	restricted := adminUserControls(common.UserSummary{id = 12, isRestricted = true}, false)
	plain := adminUserControls(common.UserSummary{id = 13}, false)
	testing.expect(
		t,
		restricted.isRestricted && restricted.restriction.enabled &&
		restricted.restriction.label == "Lift restriction" &&
		len(plain.restriction.label) == 0,
		"expected Lift restriction only for a restricted account",
	)
}

@(test)
testRestrictedDirectoryFollowsTheServer :: proc(t: ^testing.T) {
	state := testUpdateStateForServer(testRegistrationServer(1210))
	defer State_deinit(&state)
	testApplyConnected(&state, 1210, 2)
	// A ServerUserUpdated for an account the directory does not have adds it (D17).
	updated := ClientTransportRuntimeEvent {
		kind     = .UserUpdated,
		serverID = 1210,
		user     = {id = 30, nickname = strings.clone("erin"), isRestricted = true},
	}
	State_applyRuntimeEvent(&state, &updated)
	ClientTransportRuntimeEvent_deinit(&updated)
	cache := State_serverDirectCache(&state, 1210)
	index := ServerDirectCache_userIndex(cache^, 30)
	testing.expect(
		t,
		index >= 0 && cache.users[index].isRestricted,
		"expected the unknown account to be added",
	)
	// The refused DM shows the server's sentence.
	refusal := ClientTransportRuntimeEvent {
		kind     = .ProtocolError,
		serverID = 1210,
		message  = strings.clone(common.DIRECT_MESSAGE_RESTRICTED_MESSAGE),
	}
	State_applyRuntimeEvent(&state, &refusal)
	ClientTransportRuntimeEvent_deinit(&refusal)
	testExpectString(
		t,
		state.chat_status_message,
		"You no longer share a room with this person",
		"the refused DM",
	)
	// The account's own restriction follows ServerAccountUpdated.
	account := ClientTransportRuntimeEvent {
		kind         = .AccountUpdated,
		serverID     = 1210,
		nickname     = strings.clone("Tester"),
		isRestricted = true,
	}
	State_applyRuntimeEvent(&state, &account)
	ClientTransportRuntimeEvent_deinit(&account)
	testing.expect(
		t,
		State_serverConnection(&state, 1210).isRestricted,
		"expected the restriction mirrored",
	)
}

@(test)
testUseInviteCodeSettingSetsRegistering :: proc(t: ^testing.T) {
	state := testUpdateStateForServer(testRegistrationServer(1211))
	defer State_deinit(&state)
	State_setUseInviteCode(&state, 1211, true)
	server, _ := State_serverConfig(&state, 1211)
	index := State_selectedTransportIndexForServerID(state, 1211)
	testing.expect(
		t,
		server.use_invite_code && state.serverTransports[index].registering,
		"expected the setting to reach the config and the transport",
	)
	clone := Server_clone(server^)
	defer Server_deinit(&clone)
	testing.expect(t, clone.use_invite_code, "expected Server_clone to keep the setting")
	State_setUseInviteCode(&state, 1211, false)
	testing.expect(
		t,
		!server.use_invite_code && !state.serverTransports[index].registering,
		"expected the setting off",
	)
}

@(test)
testHeadlessRegistrationCommandsAndEvents :: proc(t: ^testing.T) {
	sync.mutex_lock(&registrationSendBridgeTestMutex)
	defer sync.mutex_unlock(&registrationSendBridgeTestMutex)
	testRegistrationUseStub(1212)
	defer testRegistrationRestore()

	builder := strings.builder_make()
	harness := testHeadlessHarness(&builder, 1212)
	defer testHeadlessHarnessDeinit(&harness, &builder)

	required := ClientTransportRuntimeEvent {
		kind                      = .RegistrationRequired,
		serverID                  = 1212,
		registrationMode          = .InviteApproval,
		registrationRequestStatus = .None,
		message                   = strings.clone(common.REGISTRATION_APPROVAL_REQUIRED_MESSAGE),
	}
	headlessHandleRuntimeEvent(&harness, &required)
	ClientTransportRuntimeEvent_deinit(&required)
	testExpectString(
		t,
		testHeadlessTakeOutput(&builder),
		`{"event":"registration_required","serverID":1212,"mode":"approval","status":"none",` +
		`"message":"This server needs an invite code and approval to sign up"}` + "\n",
		"the registration_required line",
	)

	headlessHandleLine(&harness, "register " + REGISTRATION_TEST_CODE + " Bob's sister")
	testExpectString(
		t,
		testHeadlessTakeOutput(&builder),
		`{"ok":true,"cmd":"register","serverID":1212}` + "\n",
		"the register result",
	)
	testing.expect(
		t,
		len(registrationTestRequests) == 1 &&
		registrationTestRequests[0].reason == "Bob's sister" &&
		registrationTestRequests[0].code == "0123456789ABCDEFGHJKMNPQRSTVWXYZ",
		"expected register to send the code and reason",
	)

	pending := ClientTransportRuntimeEvent {
		kind           = .RegistrationResult,
		serverID       = 1212,
		registerStatus = .Pending,
		message        = strings.clone(common.REGISTRATION_PENDING_MESSAGE),
	}
	headlessHandleRuntimeEvent(&harness, &pending)
	ClientTransportRuntimeEvent_deinit(&pending)
	testExpectString(
		t,
		testHeadlessTakeOutput(&builder),
		`{"event":"registration_result","serverID":1212,"status":"pending",` +
		`"message":"Your sign-up request is waiting for approval","userID":0}` + "\n",
		"the pending line",
	)
	headlessHandleLine(&harness, "status")
	status := testHeadlessTakeOutput(&builder)
	testing.expect(
		t,
		strings.contains(status, `"connection":"registering"`) &&
		strings.contains(status, `"signUp":"pending"`) &&
		strings.contains(status, `"registrationMode":"approval"`),
		fmt.tprintf("expected the registering status, got %s", status),
	)

	created := ClientTransportRuntimeEvent {
		kind             = .Connected,
		serverID         = 1212,
		userID           = 31,
		nickname         = strings.clone("carol"),
		registered       = true,
		registrationMode = .InviteApproval,
	}
	headlessHandleRuntimeEvent(&harness, &created)
	ClientTransportRuntimeEvent_deinit(&created)
	output := testHeadlessTakeOutput(&builder)
	testing.expect(
		t,
		strings.has_prefix(
			output,
			`{"event":"registration_result","serverID":1212,"status":"created","message":"",` +
			`"userID":31}` + "\n" + `{"event":"connected","serverID":1212,"userID":31,`,
		) &&
		strings.contains(
			output,
			`"registrationMode":"approval","isRestricted":false,"registered":true}`,
		),
		fmt.tprintf("expected created then connected, got %s", output),
	)
	testing.expect(
		t,
		harness.pendingEvents[.RegistrationResult] == 2 &&
		harness.pendingEvents[.RegistrationRequired] == 1,
		"expected the events counted for wait",
	)

	// invite-create options, and the invite_created line with its link.
	request, ok := headlessParseInviteOptions("expires=3600,uses=0,roles=2+5,room=7,skip-approval")
	testing.expect(
		t,
		ok &&
		request.expiresInSeconds == 3600 &&
		request.maxUses == 0 &&
		request.roleIDCount == 2 &&
		request.roleIDs[1] == 5 &&
		request.roomID == 7 &&
		request.skipApproval,
		"expected the invite options parsed",
	)
	_, bad := headlessParseInviteOptions("expires=soon")
	testing.expect(t, !bad, "expected a bad option refused")
	defaults, _ := headlessParseInviteOptions("-")
	testing.expect(
		t,
		defaults.expiresInSeconds == 24 * 60 * 60 && defaults.maxUses == 1,
		"expected the defaults: one day, one use",
	)

	invite := ClientTransportRuntimeEvent {
		kind       = .InviteCreated,
		serverID   = 1212,
		invite     = {id = 9, note = strings.clone("for dave"), createdBy = 31, maxUses = 1},
		inviteCode = strings.clone(REGISTRATION_TEST_CODE),
	}
	headlessHandleRuntimeEvent(&harness, &invite)
	ClientTransportRuntimeEvent_deinit(&invite)
	output = testHeadlessTakeOutput(&builder)
	testing.expect(
		t,
		strings.has_prefix(output, `{"event":"invite_created","serverID":1212,"invite":{"id":9,`) &&
		strings.contains(output, `"code":"`+REGISTRATION_TEST_CODE+`"`) &&
		strings.contains(
			output,
			`"link":"haychat://localhost:1/invite/` + REGISTRATION_TEST_CODE + `?key="`,
		),
		fmt.tprintf("expected the invite_created line, got %s", output),
	)

	mode := ClientTransportRuntimeEvent {
		kind             = .RegistrationModeChanged,
		serverID         = 1212,
		registrationMode = .Open,
	}
	headlessHandleRuntimeEvent(&harness, &mode)
	ClientTransportRuntimeEvent_deinit(&mode)
	testExpectString(
		t,
		testHeadlessTakeOutput(&builder),
		`{"event":"registration_mode","serverID":1212,"mode":"open"}` + "\n",
		"the registration_mode line",
	)

	headlessHandleLine(&harness, "registration-decide 3 maybe")
	testing.expect(
		t,
		strings.contains(testHeadlessTakeOutput(&builder), `"ok":false`),
		"expected a bad decision word refused",
	)
	headlessHandleLine(&harness, "registration-mode closed")
	testing.expect(
		t,
		strings.contains(testHeadlessTakeOutput(&builder), `"ok":false`),
		"expected an unknown mode refused",
	)
	headlessHandleLine(&harness, "restrict 0 on")
	testing.expect(
		t,
		strings.contains(testHeadlessTakeOutput(&builder), `"ok":false`),
		"expected a bad account refused",
	)

	// Startup options.
	options, optionsErr := headlessParseOptions(
		{"--headless", "--invite-code", REGISTRATION_TEST_CODE, "--reason", "hello there"},
	)
	testing.expect(
		t,
		optionsErr == "" &&
		options.register &&
		options.inviteCode == REGISTRATION_TEST_CODE &&
		options.reason == "hello there",
		"expected --invite-code to imply --register",
	)
	_, reasonErr := headlessParseOptions({"--reason", "x"})
	testing.expect(t, reasonErr != "", "expected --reason without a code refused")
	registerOnly, _ := headlessParseOptions({"--register"})
	testing.expect(t, registerOnly.register, "expected --register")
}

@(test)
testRegistrationRequiredKeepsAKeyPinnedOnFirstUse :: proc(t: ^testing.T) {
	server := testRegistrationServer(1213)
	server.pinned_server_public_key = ""
	server.pinned_server_fingerprint = ""
	state := testUpdateStateForServer(server)
	defer State_deinit(&state)
	event := ClientTransportRuntimeEvent {
		kind              = .RegistrationRequired,
		serverID          = 1213,
		registrationMode  = .InviteOnly,
		message           = strings.clone(common.REGISTRATION_REQUIRED_MESSAGE),
		serverPublicKey   = strings.repeat("12", 32),
		serverFingerprint = strings.repeat("34", 32),
	}
	State_applyRuntimeEvent(&state, &event)
	ClientTransportRuntimeEvent_deinit(&event)
	pinned, _ := State_serverConfig(&state, 1213)
	testing.expect(
		t,
		pinned.pinned_server_public_key == strings.repeat("12", 32, context.temp_allocator) &&
		pinned.pinned_server_fingerprint == strings.repeat("34", 32, context.temp_allocator),
		"expected the key pinned during sign-up to reach the config",
	)
}

@(test)
testHeadlessRegisterFormUsesTheLinksCode :: proc(t: ^testing.T) {
	sync.mutex_lock(&registrationSendBridgeTestMutex)
	defer sync.mutex_unlock(&registrationSendBridgeTestMutex)
	testRegistrationUseStub(1214)
	defer testRegistrationRestore()

	builder := strings.builder_make()
	harness := testHeadlessHarness(&builder, 1214)
	defer testHeadlessHarnessDeinit(&harness, &builder)
	testApplyRegistrationRequired(&harness.state, 1214, .InviteOnly)
	State_prefillSignUpCode(&harness.state, 1214, REGISTRATION_TEST_CODE)
	headlessHandleLine(&harness, "register form")
	testExpectString(
		t,
		testHeadlessTakeOutput(&builder),
		`{"ok":true,"cmd":"register","serverID":1214}` + "\n",
		"the register form result",
	)
	testing.expect(
		t,
		len(registrationTestRequests) == 1 &&
		registrationTestRequests[0].code == "0123456789ABCDEFGHJKMNPQRSTVWXYZ" &&
		registrationTestRequests[0].reason == "",
		"expected the form's code sent, without a reason outside approval mode",
	)
}
