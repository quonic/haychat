package server

import "../common"
import "core:encoding/cbor"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:testing"

// Router tests for the admin actions (router_admin.odin, protocol 14) and room types. They
// reuse the harnesses of router_test.odin and router_voice_test.odin, with stubbed database
// results: the guards themselves run in SQL (database_admin_test.odin).

ROUTER_ADMIN_TEST_ADMIN :: 42
ROUTER_ADMIN_TEST_TARGET :: 43

// Admin alice (peer 1) and two sessions of bob (peers 2 and 3), with every presence notice
// consumed.
routerAdminTestClients :: proc() -> [3]RouterVoiceTestClient {
	return [3]RouterVoiceTestClient {
		{peerID = 1, userID = ROUTER_ADMIN_TEST_ADMIN},
		{peerID = 2, userID = ROUTER_ADMIN_TEST_TARGET},
		{peerID = 3, userID = ROUTER_ADMIN_TEST_TARGET},
	}
}

// Sends an admin request from client and returns the statement it queued.
routerAdminTestSend :: proc(
	h: ^RouterTestHarness,
	client: ^RouterVoiceTestClient,
	messageType: common.MessageType,
	payload: any,
) -> (
	DatabaseQuery,
	common.DatabaseAdminUserRequest,
) {
	routerTestSendSealed(h, &client.transport, client.peerID, messageType, payload)
	query := routerPollDatabaseQuery(h)
	request, ok := query.request.(common.DatabaseAdminUserRequest)
	assert(ok, fmt.tprintf("expected %v to queue one admin statement, got %v", messageType, query))
	return query, request
}

// Answers an admin statement. user's nickname and previous are cloned.
routerAdminTestAnswer :: proc(
	h: ^RouterTestHarness,
	query: DatabaseQuery,
	outcome: common.DatabaseAdminOutcome,
	changed := false,
	user: common.UserSummary = {},
	nicknameLocked := false,
	previous := "",
) {
	result := common.DatabaseAdminUserResult {
		outcome          = outcome,
		changed          = changed,
		user             = user,
		nicknameLocked   = nicknameLocked,
		previousNickname = strings.clone(previous),
	}
	result.user.nickname = strings.clone(user.nickname)
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		query.request_id,
		common.DatabaseQueryResponse{success = true, result = result},
	)
}

routerAdminTestCount :: proc(
	drain: ^RouterVoiceTestDrain,
	peerID: u32,
	messageType: common.MessageType,
) -> int {
	count := 0
	for entry in drain.packets {
		if entry.peerID == peerID && entry.packet.messageType == messageType {
			count += 1
		}
	}
	return count
}

// The first payload of messageType peerID got, decoded into T. The caller frees it.
routerAdminTestDecode :: proc(
	drain: ^RouterVoiceTestDrain,
	peerID: u32,
	messageType: common.MessageType,
	$T: typeid,
) -> T {
	for entry in drain.packets {
		if entry.peerID == peerID && entry.packet.messageType == messageType {
			value: T
			assert(
				cbor.unmarshal(entry.packet.payload, &value) == nil,
				fmt.tprintf("expected %v for peer %d to decode", messageType, peerID),
			)
			return value
		}
	}
	assert(false, fmt.tprintf("expected %v for peer %d", messageType, peerID))
	return {}
}

routerAdminTestExpectResult :: proc(
	drain: ^RouterVoiceTestDrain,
	action: common.AdminAction,
	userID: int,
	message: string,
) {
	result := routerAdminTestDecode(
		drain,
		1,
		.ServerAdminActionResult,
		common.ServerAdminActionResultPayload,
	)
	defer common.ServerAdminActionResultPayload_deinit(&result)
	assert(
		result.action == action && result.userId == userID && result.message == message,
		fmt.tprintf("expected %v of %d with %q, got %v", action, userID, message, result),
	)
	assert(
		routerAdminTestCount(drain, 2, .ServerAdminActionResult) == 0 &&
		routerAdminTestCount(drain, 3, .ServerAdminActionResult) == 0,
		"expected the result only for the session that asked",
	)
}

@(test)
testMainRouterAdminSetRolePushesTheRoleToTheTarget :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)
	clients := routerAdminTestClients()
	routerVoiceTestConnect(&h, clients[:])
	defer routerVoiceTestDisconnectAll(clients[:])

	query, request := routerAdminTestSend(
		&h,
		&clients[0],
		.ClientAdminSetRole,
		common.ClientAdminSetRolePayload{userId = ROUTER_ADMIN_TEST_TARGET, isAdmin = true},
	)
	defer IPC__database_query_request_deinit(query.request)
	assert(
		request.action == .SetRole &&
		request.actorUserId == ROUTER_ADMIN_TEST_ADMIN &&
		request.targetUserId == ROUTER_ADMIN_TEST_TARGET &&
		request.isAdmin,
		fmt.tprintf("expected a grant by the authenticated admin, got %v", request),
	)
	routerAdminTestAnswer(
		&h,
		query,
		.Applied,
		changed = true,
		user = {id = ROUTER_ADMIN_TEST_TARGET, nickname = "voice-user-43", isAdmin = true},
	)
	routerTestExpectNoDatabaseQuery(&h, "expected the role change to need one statement")

	drain := routerVoiceTestDrain(&h, clients[:])
	defer RouterVoiceTestDrain_deinit(&drain)
	routerAdminTestExpectResult(
		&drain,
		.SetRole,
		ROUTER_ADMIN_TEST_TARGET,
		"voice-user-43 is an admin",
	)
	for peerID in ([]u32{1, 2, 3}) {
		assert(
			routerAdminTestCount(&drain, peerID, .ServerUserUpdated) == 1,
			fmt.tprintf("expected peer %d to get ServerUserUpdated once", peerID),
		)
		update := routerAdminTestDecode(
			&drain,
			peerID,
			.ServerUserUpdated,
			common.ServerUserUpdatedPayload,
		)
		defer common.ServerUserUpdatedPayload_deinit(&update)
		assert(
			update.user.id == ROUTER_ADMIN_TEST_TARGET &&
			update.user.isAdmin &&
			update.user.isOnline &&
			!update.user.isBanned,
			fmt.tprintf("expected bob online and admin, got %v", update.user),
		)
	}
	// #41: both of bob's sessions learn it without reconnecting; alice's account did not change.
	assert(
		routerAdminTestCount(&drain, 1, .ServerAccountUpdated) == 0,
		"expected no account update for the admin who asked",
	)
	for peerID in ([]u32{2, 3}) {
		account := routerAdminTestDecode(
			&drain,
			peerID,
			.ServerAccountUpdated,
			common.ServerAccountUpdatedPayload,
		)
		defer common.ServerAccountUpdatedPayload_deinit(&account)
		assert(
			account.isAdmin && account.nickname == "voice-user-43" && !account.nicknameLocked,
			fmt.tprintf("expected peer %d to hear it is an admin, got %v", peerID, account),
		)
	}
	assert(len(drain.packets) == 6, fmt.tprintf("expected 6 packets, got %d", len(drain.packets)))

	// A grant that changed nothing (already an admin) answers the admin and tells nobody.
	repeatQuery, _ := routerAdminTestSend(
		&h,
		&clients[0],
		.ClientAdminSetRole,
		common.ClientAdminSetRolePayload{userId = ROUTER_ADMIN_TEST_TARGET, isAdmin = true},
	)
	defer IPC__database_query_request_deinit(repeatQuery.request)
	routerAdminTestAnswer(
		&h,
		repeatQuery,
		.Applied,
		user = {id = ROUTER_ADMIN_TEST_TARGET, nickname = "voice-user-43", isAdmin = true},
	)
	again := routerVoiceTestDrain(&h, clients[:])
	defer RouterVoiceTestDrain_deinit(&again)
	assert(
		len(again.packets) == 1 && again.packets[0].packet.messageType == .ServerAdminActionResult,
		fmt.tprintf("expected only the result for a no-op grant, got %v", again.packets),
	)
}

@(test)
testMainRouterAdminRenameUpdatesSessionsPresenceAndVoice :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)
	clients := routerAdminTestClients()
	routerVoiceTestConnect(&h, clients[:])
	defer routerVoiceTestDisconnectAll(clients[:])
	// Bob is in voice in room 5, so the voice list must show the new name too.
	routerVoiceTestJoin(&h, &clients[1], 5, {ROUTER_ADMIN_TEST_ADMIN, ROUTER_ADMIN_TEST_TARGET})
	joined := routerVoiceTestDrain(&h, clients[:])
	RouterVoiceTestDrain_deinit(&joined)

	query, request := routerAdminTestSend(
		&h,
		&clients[0],
		.ClientAdminRenameUser,
		common.ClientAdminRenameUserPayload {
			userId = ROUTER_ADMIN_TEST_TARGET,
			nickname = "renamed-bob",
			locked = true,
		},
	)
	defer IPC__database_query_request_deinit(query.request)
	assert(
		request.action == .Rename && request.nickname == "renamed-bob" && request.locked,
		fmt.tprintf("expected a locked rename to renamed-bob, got %v", request),
	)
	routerAdminTestAnswer(
		&h,
		query,
		.Applied,
		changed = true,
		user = {id = ROUTER_ADMIN_TEST_TARGET, nickname = "renamed-bob"},
		nicknameLocked = true,
		previous = "voice-user-43",
	)

	drain := routerVoiceTestDrain(&h, clients[:])
	defer RouterVoiceTestDrain_deinit(&drain)
	routerAdminTestExpectResult(
		&drain,
		.Rename,
		ROUTER_ADMIN_TEST_TARGET,
		"Renamed voice-user-43 to renamed-bob; the name is locked",
	)
	for peerID in ([]u32{2, 3}) {
		session, _ := MainRouterState_getPeerSession(&h.state, peerID)
		assert(
			session.clientNickname == "renamed-bob",
			fmt.tprintf(
				"expected peer %d's session renamed, got %q",
				peerID,
				session.clientNickname,
			),
		)
		account := routerAdminTestDecode(
			&drain,
			peerID,
			.ServerAccountUpdated,
			common.ServerAccountUpdatedPayload,
		)
		defer common.ServerAccountUpdatedPayload_deinit(&account)
		assert(
			!account.isAdmin && account.nickname == "renamed-bob" && account.nicknameLocked,
			fmt.tprintf("expected peer %d to hear its locked name, got %v", peerID, account),
		)
	}
	// Like a rename at sign-in, everyone who sees bob online hears the new name.
	for peerID in ([]u32{1, 2, 3}) {
		presence := routerAdminTestDecode(
			&drain,
			peerID,
			.ServerUserPresence,
			common.ServerUserPresencePayload,
		)
		defer delete(presence.nickname)
		assert(
			presence.userId == ROUTER_ADMIN_TEST_TARGET &&
			presence.nickname == "renamed-bob" &&
			presence.isOnline,
			fmt.tprintf(
				"expected peer %d to see bob online as renamed-bob, got %v",
				peerID,
				presence,
			),
		)
		assert(
			routerAdminTestCount(&drain, peerID, .ServerUserUpdated) == 1,
			fmt.tprintf("expected peer %d to get the directory update", peerID),
		)
		participants, found := routerVoiceTestParticipants(&drain, peerID, 5)
		defer common.ServerVoiceParticipantsPayload_deinit(&participants)
		assert(
			found &&
			len(participants.participants) == 1 &&
			participants.participants[0].nickname == "renamed-bob",
			fmt.tprintf("expected peer %d's voice list to show renamed-bob", peerID),
		)
	}
}

@(test)
testMainRouterAdminKickEndsEverySessionOfTheTarget :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)
	clients := routerAdminTestClients()
	routerVoiceTestConnect(&h, clients[:])
	defer routerVoiceTestDisconnectAll(clients[:])
	routerVoiceTestJoin(&h, &clients[2], 5, {ROUTER_ADMIN_TEST_ADMIN, ROUTER_ADMIN_TEST_TARGET})
	joined := routerVoiceTestDrain(&h, clients[:])
	RouterVoiceTestDrain_deinit(&joined)

	query, request := routerAdminTestSend(
		&h,
		&clients[0],
		.ClientAdminKickUser,
		common.ClientAdminKickUserPayload{userId = ROUTER_ADMIN_TEST_TARGET, reason = "cool off"},
	)
	defer IPC__database_query_request_deinit(query.request)
	assert(request.action == .Kick, fmt.tprintf("expected a kick, got %v", request))
	routerAdminTestAnswer(
		&h,
		query,
		.Applied,
		user = {id = ROUTER_ADMIN_TEST_TARGET, nickname = "voice-user-43"},
	)

	drain := routerVoiceTestDrain(&h, clients[:])
	defer RouterVoiceTestDrain_deinit(&drain)
	routerAdminTestExpectResult(&drain, .Kick, ROUTER_ADMIN_TEST_TARGET, "Kicked voice-user-43")
	for peerID in ([]u32{2, 3}) {
		ended := routerAdminTestDecode(
			&drain,
			peerID,
			.ServerSessionEnded,
			common.ServerSessionEndedPayload,
		)
		defer common.ServerSessionEndedPayload_deinit(&ended)
		assert(
			ended.kind == .Kicked && ended.reason == "cool off",
			fmt.tprintf("expected peer %d to be told it was kicked, got %v", peerID, ended),
		)
		session, _ := MainRouterState_getPeerSession(&h.state, peerID)
		assert(!session.isAuthenticated, fmt.tprintf("expected peer %d signed out", peerID))
		_, inVoice := h.state.peerVoiceRoom[peerID]
		assert(!inVoice, fmt.tprintf("expected peer %d out of voice", peerID))
	}
	assert(
		routerVoiceTestSamePeers(drain.disconnects[:], {2, 3}),
		fmt.tprintf("expected both of bob's sessions disconnected, got %v", drain.disconnects),
	)
	// Alice saw bob's voice session end and bob go offline, once.
	participants, found := routerVoiceTestParticipants(&drain, 1, 5)
	defer common.ServerVoiceParticipantsPayload_deinit(&participants)
	assert(found && len(participants.participants) == 0, "expected room 5's voice to empty")
	presence := routerAdminTestDecode(
		&drain,
		1,
		.ServerUserPresence,
		common.ServerUserPresencePayload,
	)
	defer delete(presence.nickname)
	assert(
		presence.userId == ROUTER_ADMIN_TEST_TARGET && !presence.isOnline,
		fmt.tprintf("expected bob offline, got %v", presence),
	)
	assert(
		routerAdminTestCount(&drain, 1, .ServerUserPresence) == 1,
		"expected one offline notice for bob",
	)
	assert(
		!MainRouterState_isUserOnline(&h.state, ROUTER_ADMIN_TEST_TARGET),
		"expected bob offline",
	)
	session, _ := MainRouterState_getPeerSession(&h.state, 1)
	assert(session.isAuthenticated, "expected the admin to stay signed in")
}

@(test)
testMainRouterAdminBanEndsSessionsAndUnbanUpdatesTheDirectory :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)
	clients := routerAdminTestClients()
	routerVoiceTestConnect(&h, clients[:])
	defer routerVoiceTestDisconnectAll(clients[:])

	query, request := routerAdminTestSend(
		&h,
		&clients[0],
		.ClientAdminBanUser,
		common.ClientAdminBanUserPayload {
			userId = ROUTER_ADMIN_TEST_TARGET,
			banned = true,
			reason = "spam",
		},
	)
	defer IPC__database_query_request_deinit(query.request)
	assert(
		request.action == .Ban && request.banned && request.reason == "spam",
		fmt.tprintf("expected a ban for spam, got %v", request),
	)
	routerAdminTestAnswer(
		&h,
		query,
		.Applied,
		changed = true,
		user = {id = ROUTER_ADMIN_TEST_TARGET, nickname = "voice-user-43", isBanned = true},
	)
	drain := routerVoiceTestDrain(&h, clients[:])
	defer RouterVoiceTestDrain_deinit(&drain)
	routerAdminTestExpectResult(&drain, .Ban, ROUTER_ADMIN_TEST_TARGET, "Banned voice-user-43")
	for peerID in ([]u32{2, 3}) {
		ended := routerAdminTestDecode(
			&drain,
			peerID,
			.ServerSessionEnded,
			common.ServerSessionEndedPayload,
		)
		defer common.ServerSessionEndedPayload_deinit(&ended)
		assert(
			ended.kind == .Banned && ended.reason == "spam",
			fmt.tprintf("expected peer %d to be told it was banned, got %v", peerID, ended),
		)
		assert(
			routerAdminTestCount(&drain, peerID, .ServerUserUpdated) == 0,
			"expected nothing after ServerSessionEnded for a banned session",
		)
	}
	assert(routerVoiceTestSamePeers(drain.disconnects[:], {2, 3}), "expected both disconnected")
	update := routerAdminTestDecode(&drain, 1, .ServerUserUpdated, common.ServerUserUpdatedPayload)
	defer common.ServerUserUpdatedPayload_deinit(&update)
	assert(
		update.user.isBanned && !update.user.isOnline,
		fmt.tprintf("expected the admin to see bob banned and offline, got %v", update.user),
	)

	// The unban only updates the directory; the reason is dropped before the database.
	unbanQuery, unbanRequest := routerAdminTestSend(
		&h,
		&clients[0],
		.ClientAdminBanUser,
		common.ClientAdminBanUserPayload {
			userId = ROUTER_ADMIN_TEST_TARGET,
			banned = false,
			reason = "ignored",
		},
	)
	defer IPC__database_query_request_deinit(unbanQuery.request)
	assert(
		unbanRequest.action == .Ban && !unbanRequest.banned && unbanRequest.reason == "",
		fmt.tprintf("expected an unban without a reason, got %v", unbanRequest),
	)
	routerAdminTestAnswer(
		&h,
		unbanQuery,
		.Applied,
		changed = true,
		user = {id = ROUTER_ADMIN_TEST_TARGET, nickname = "voice-user-43"},
	)
	unban := routerVoiceTestDrain(&h, clients[:])
	defer RouterVoiceTestDrain_deinit(&unban)
	routerAdminTestExpectResult(&unban, .Ban, ROUTER_ADMIN_TEST_TARGET, "Unbanned voice-user-43")
	assert(
		len(unban.packets) == 2 && len(unban.disconnects) == 0,
		fmt.tprintf("expected the result and one directory update, got %v", unban.packets),
	)
	lifted := routerAdminTestDecode(&unban, 1, .ServerUserUpdated, common.ServerUserUpdatedPayload)
	defer common.ServerUserUpdatedPayload_deinit(&lifted)
	assert(!lifted.user.isBanned, "expected bob unbanned in the directory")
}

@(test)
testMainRouterAdminRefusalsKeepTheSession :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)
	clients := routerAdminTestClients()
	routerVoiceTestConnect(&h, clients[:])
	defer routerVoiceTestDisconnectAll(clients[:])
	peers := [?]RouterTestPeer{{1, &clients[0].transport}}

	Refusal :: struct {
		messageType: common.MessageType,
		payload:     any,
		outcome:     common.DatabaseAdminOutcome,
		message:     string,
	}
	setRoleOff := common.ClientAdminSetRolePayload{userId = ROUTER_ADMIN_TEST_ADMIN}
	setRoleOn := common.ClientAdminSetRolePayload{userId = ROUTER_ADMIN_TEST_TARGET, isAdmin = true}
	rename := common.ClientAdminRenameUserPayload{userId = 43, nickname = "taken", locked = true}
	kick := common.ClientAdminKickUserPayload{userId = ROUTER_ADMIN_TEST_TARGET}
	ban := common.ClientAdminBanUserPayload{userId = ROUTER_ADMIN_TEST_TARGET, banned = true}
	refusals := [?]Refusal {
		{.ClientAdminSetRole, setRoleOn, .NotAdmin, "Admin permission required"},
		{.ClientAdminSetRole, setRoleOn, .UnknownUser, "Unknown user"},
		{.ClientAdminSetRole, setRoleOff, .SelfTarget, "You cannot remove your own admin role"},
		{.ClientAdminSetRole, setRoleOff, .LastAdmin, "The server must keep at least one admin"},
		{
			.ClientAdminSetRole,
			setRoleOn,
			.BannedTarget,
			"Unban the account before making it an admin",
		},
		{
			.ClientAdminRenameUser,
			rename,
			.NicknameTaken,
			"That name is already in use on this server",
		},
		{.ClientAdminKickUser, kick, .SelfTarget, "You cannot kick yourself"},
		{
			.ClientAdminKickUser,
			kick,
			.AdminTarget,
			"Remove the admin role before kicking an admin",
		},
		{.ClientAdminBanUser, ban, .SelfTarget, "You cannot ban yourself"},
		{
			.ClientAdminBanUser,
			ban,
			.AdminTarget,
			"Remove the admin role before banning an admin",
		},
	}
	for refusal in refusals {
		query, _ := routerAdminTestSend(&h, &clients[0], refusal.messageType, refusal.payload)
		defer IPC__database_query_request_deinit(query.request)
		routerAdminTestAnswer(&h, query, refusal.outcome)
		routerTestExpectProtocolError(&h, peers[:], refusal.message)
		routerTestExpectNoNetworkMessage(&h, fmt.tprintf("expected only %q", refusal.message))
	}
	for client in clients {
		session, _ := MainRouterState_getPeerSession(&h.state, client.peerID)
		assert(session.isAuthenticated, "expected every session to stay signed in")
	}

	// Malformed requests never reach the database.
	longReason := strings.repeat("r", common.ADMIN_REASON_MAX_BYTES + 1, context.temp_allocator)
	Invalid :: struct {
		messageType: common.MessageType,
		payload:     any,
	}
	invalid := [?]Invalid {
		{.ClientAdminSetRole, common.ClientAdminSetRolePayload{userId = 0, isAdmin = true}},
		{.ClientAdminRenameUser, common.ClientAdminRenameUserPayload{userId = 43, nickname = "ab"}},
		{
			.ClientAdminRenameUser,
			common.ClientAdminRenameUserPayload {
				userId = 43,
				nickname = strings.repeat("n", 33, context.temp_allocator),
			},
		},
		{.ClientAdminKickUser, common.ClientAdminKickUserPayload{userId = 43, reason = longReason}},
		{
			.ClientAdminBanUser,
			common.ClientAdminBanUserPayload{userId = -1, banned = true},
		},
		{
			.ClientAdminBanUser,
			common.ClientAdminBanUserPayload{userId = 43, banned = true, reason = longReason},
		},
	}
	for request in invalid {
		routerTestSendSealed(
			&h,
			&clients[0].transport,
			clients[0].peerID,
			request.messageType,
			request.payload,
		)
		routerTestExpectProtocolError(&h, peers[:], ADMIN_INVALID_REQUEST_MESSAGE)
		routerTestExpectNoDatabaseQuery(&h, fmt.tprintf("expected %v refused", request.payload))
	}
}

@(test)
testMainRouterRefusesABannedSignIn :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)

	for reason in ([]string{"", "spam"}) {
		h := routerTestHarness_init()
		defer routerTestHarness_deinit(&h)
		peerID := u32(1)
		MainRouterState_sendDatabaseRequest(
			&h.pm,
			&h.state,
			peerID,
			.ResolveUserIdentity,
			common.DatabaseUserIdentityRequest{nickname = strings.clone("banned-user")},
		)
		identityQuery := routerPollDatabaseQuery(&h)
		defer IPC__database_query_request_deinit(identityQuery.request)
		MainRouterState_handleDatabaseResult(
			&h.pm,
			&h.state,
			identityQuery.request_id,
			common.DatabaseQueryResponse {
				success = true,
				result = common.DatabaseUserIdentityResult {
					userId = 43,
					nickname = strings.clone("banned-user"),
					banned = true,
					banReason = strings.clone(reason),
				},
			},
		)
		failureSend := routerPollNetworkSend(&h)
		defer delete(failureSend.data)
		failurePacket := routerDecodePacketBytes(failureSend.data)
		defer delete(failurePacket.payload)
		assert(failurePacket.messageType == .ServerAuthFailure, "expected the sign-in refused")
		failure: common.ServerAuthFailurePayload
		assert(cbor.unmarshal(failurePacket.payload, &failure) == nil, "expected failure decode")
		defer delete(failure.message)
		expected := SERVER_BANNED_MESSAGE
		if len(reason) > 0 {
			expected = "This account is banned from this server: spam"
		}
		assert(
			failure.message == expected,
			fmt.tprintf("expected %q, got %q", expected, failure.message),
		)
		disconnect := routerPollDisconnect(&h)
		assert(disconnect.peerId == peerID, "expected the banned peer disconnected")
		routerTestExpectNoNetworkMessage(&h, "expected no auth success or presence")
		session, _ := MainRouterState_getPeerSession(&h.state, peerID)
		assert(
			!session.isAuthenticated && session.transport.phase == .Failed,
			"expected the banned session to stay signed out",
		)
	}
}

@(test)
testMainRouterSignInTakesTheAccountsLockedName :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)
	transport := routerCompleteHandshake(
		&h,
		1,
		43,
		"asked-for-name",
		accountNickname = "admin-chosen",
		nicknameLocked = true,
	)
	defer common.TransportState_deinit(&transport)
	session, _ := MainRouterState_getPeerSession(&h.state, 1)
	assert(
		session.clientNickname == "admin-chosen",
		fmt.tprintf("expected the session to take the locked name, got %q", session.clientNickname),
	)
}

@(test)
testMainRouterRoomTypesAreValidatedAndEnforced :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)
	clients := routerAdminTestClients()
	routerVoiceTestConnect(&h, clients[:])
	defer routerVoiceTestDisconnectAll(clients[:])
	peers := [?]RouterTestPeer{{1, &clients[0].transport}, {2, &clients[1].transport}}

	// Only text, voice, and both are accepted.
	for roomType in ([]common.RoomType{.Container, .Forum, common.RoomType(9)}) {
		routerTestSendSealed(
			&h,
			&clients[0].transport,
			1,
			.ClientCreateRoom,
			common.ClientCreateRoomPayload {
				name = "lobby",
				roomType = roomType,
				access = .Public,
				historyVisibility = .FromJoin,
			},
		)
		routerTestExpectProtocolError(&h, peers[:], "Invalid room metadata")
		routerTestSendSealed(
			&h,
			&clients[0].transport,
			1,
			.ClientEditRoom,
			common.ClientEditRoomPayload {
				roomId = 5,
				name = "lobby",
				roomType = roomType,
				access = .Public,
			},
		)
		routerTestExpectProtocolError(&h, peers[:], "Invalid room edit")
		routerTestExpectNoDatabaseQuery(&h, fmt.tprintf("expected %v refused", roomType))
	}
	routerTestSendSealed(
		&h,
		&clients[0].transport,
		1,
		.ClientCreateRoom,
		common.ClientCreateRoomPayload {
			name = "lobby",
			roomType = .Voice,
			access = .Public,
			historyVisibility = .FromJoin,
			creatorJoins = true,
		},
	)
	create := routerPollDatabaseQuery(&h)
	defer IPC__database_query_request_deinit(create.request)
	createRequest, createOK := create.request.(common.DatabaseCreateRoomRequest)
	assert(
		createOK && createRequest.roomType == .Voice,
		fmt.tprintf("expected a voice room created, got %v", create.request),
	)

	// A text-only room refuses a voice join after the membership check.
	routerVoiceTestSendJoin(&h, &clients[1], 7)
	routerVoiceTestAnswerMemberCheck(
		&h,
		7,
		{ROUTER_ADMIN_TEST_ADMIN, ROUTER_ADMIN_TEST_TARGET},
		.Chat,
	)
	refused := routerVoiceTestDrain(&h, clients[:])
	defer RouterVoiceTestDrain_deinit(&refused)
	_, reason, found := routerVoiceTestReason(&refused, 2, .ServerVoiceJoinRejected)
	assert(
		found && reason == VOICE_REJECT_TEXT_ONLY,
		fmt.tprintf("expected the text-only join refused, got %q", reason),
	)
	_, inVoice := h.state.peerVoiceRoom[2]
	assert(!inVoice, "expected the refused join to leave bob out of voice")

	// A voice-only room refuses chat in the post statement.
	routerTestSendSealed(
		&h,
		&clients[1].transport,
		2,
		.ClientChatMessage,
		routerTestSignedChat(&h, clients[1].identityKey, 7, clients[1].userID, "hello"),
	)
	post := routerPollDatabaseQuery(&h)
	defer IPC__database_query_request_deinit(post.request)
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		post.request_id,
		common.DatabaseQueryResponse {
			success = true,
			result = common.DatabasePostRoomChatMessageResult{isMember = true, chatDisabled = true},
		},
	)
	routerTestExpectProtocolError(&h, peers[:], CHAT_DISABLED_MESSAGE)
	routerTestExpectNoNetworkMessage(&h, "expected the refused post to reach nobody")
}

@(test)
testMainRouterEditToTextOnlyEndsTheRoomsVoice :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)
	clients := routerAdminTestClients()
	routerVoiceTestConnect(&h, clients[:])
	defer routerVoiceTestDisconnectAll(clients[:])
	members := []int{ROUTER_ADMIN_TEST_ADMIN, ROUTER_ADMIN_TEST_TARGET}
	routerVoiceTestJoin(&h, &clients[1], 5, members)
	joined := routerVoiceTestDrain(&h, clients[:])
	RouterVoiceTestDrain_deinit(&joined)

	routerTestSendSealed(
		&h,
		&clients[0].transport,
		1,
		.ClientEditRoom,
		common.ClientEditRoomPayload{roomId = 5, name = "lobby", roomType = .Chat, access = .Public},
	)
	edit := routerPollDatabaseQuery(&h)
	defer IPC__database_query_request_deinit(edit.request)
	editRequest, editOK := edit.request.(common.DatabaseEditRoomRequest)
	assert(editOK && editRequest.roomType == .Chat, "expected the edit to carry the new type")
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		edit.request_id,
		common.DatabaseQueryResponse {
			success = true,
			result = common.DatabaseRoomMutationResult {
				changed = true,
				room = {
					id = 5,
					name = strings.clone("lobby"),
					description = strings.clone(""),
					roomType = .Chat,
				},
			},
		},
	)
	recipients := routerPollDatabaseQuery(&h)
	defer IPC__database_query_request_deinit(recipients.request)

	drain := routerVoiceTestDrain(&h, clients[:])
	defer RouterVoiceTestDrain_deinit(&drain)
	_, reason, found := routerVoiceTestReason(&drain, 2, .ServerVoiceLeft)
	assert(
		found && reason == VOICE_LEFT_TEXT_ONLY,
		fmt.tprintf("expected bob removed from voice, got %q", reason),
	)
	_, inVoice := h.state.peerVoiceRoom[2]
	assert(!inVoice && 5 not_in h.state.voiceRooms, "expected room 5's voice state gone")
	route, routeOK := routerVoiceTestLastRoute(&drain, 5)
	assert(routeOK && len(route.members) == 0, "expected room 5's route emptied")
	for peerID in ([]u32{1, 2, 3}) {
		participants, listed := routerVoiceTestParticipants(&drain, peerID, 5)
		defer common.ServerVoiceParticipantsPayload_deinit(&participants)
		assert(
			listed && len(participants.participants) == 0,
			fmt.tprintf("expected peer %d to see room 5's voice end", peerID),
		)
	}
	edited := routerAdminTestDecode(&drain, 1, .ServerEditRoom, common.ServerRoomMutationPayload)
	defer delete(edited.room.name)
	defer delete(edited.room.description)
	assert(edited.room.roomType == .Chat, "expected the admin's answer to carry the new type")
}
