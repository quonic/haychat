#+feature dynamic-literals
package client

import "../common"
import "core:encoding/cbor"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

// Tests for the admin actions on the client (protocol 14): transport decoding of the new
// server messages, the State updates they make, kicked and banned connections, the request
// actions through adminSendBridge, and the harness commands and events.

adminSendBridgeTestMutex: sync.Mutex
adminSendBridgeTestCount: int
adminSendBridgeTestLast: AdminRequest
adminSendBridgeTestNickname: string
adminSendBridgeTestReason: string
adminSendBridgeTestRoleName: string

adminSendBridgeTestStub :: proc(transport: ^ClientServerTransport, request: AdminRequest) -> bool {
	adminSendBridgeTestCount += 1
	adminSendBridgeTestLast = request
	delete(adminSendBridgeTestNickname)
	delete(adminSendBridgeTestReason)
	adminSendBridgeTestNickname = strings.clone(request.nickname)
	adminSendBridgeTestReason = strings.clone(request.reason)
	adminSendBridgeTestLast.nickname = adminSendBridgeTestNickname
	adminSendBridgeTestLast.reason = adminSendBridgeTestReason
	delete(adminSendBridgeTestRoleName)
	adminSendBridgeTestRoleName = strings.clone(request.roleName)
	adminSendBridgeTestLast.roleName = adminSendBridgeTestRoleName
	return true
}

// Swaps in the stub; call with adminSendBridgeTestMutex held and run testAdminRestore after.
testAdminUseStub :: proc() {
	adminSendBridgeTestCount = 0
	adminSendBridgeTestLast = {}
	adminSendBridge = adminSendBridgeTestStub
}

testAdminRestore :: proc() {
	adminSendBridge = ClientServerTransport_sendAdminRequest
	delete(adminSendBridgeTestNickname)
	delete(adminSendBridgeTestReason)
	delete(adminSendBridgeTestRoleName)
	adminSendBridgeTestNickname = ""
	adminSendBridgeTestReason = ""
	adminSendBridgeTestRoleName = ""
	adminSendBridgeTestLast = {}
}

// Decodes one server message the way the worker does after opening it. The caller deinits
// the event.
testAdminTranslate :: proc(
	transport: ^ClientServerTransport,
	messageType: common.MessageType,
	payload: any,
) -> ClientTransportRuntimeEvent {
	payloadBytes, err := cbor.marshal(payload)
	assert(err == nil, fmt.tprintf("expected %v to encode", messageType))
	defer delete(payloadBytes)
	event, ok := ClientServerTransport_translateRuntimeOpenedPacket(
		transport,
		common.Packet{messageType = messageType, payload = payloadBytes},
	)
	assert(ok, fmt.tprintf("expected %v to become an event", messageType))
	return event
}

testAdminTransport :: proc(serverID: int) -> ClientServerTransport {
	return ClientServerTransport {
		serverID = serverID,
		transport = common.TransportState_init(.Client),
		authenticatedUserID = 7,
	}
}

@(test)
testAdminServerMessagesBecomeRuntimeEvents :: proc(t: ^testing.T) {
	transport := testAdminTransport(950)
	defer ClientServerTransport_deinit(&transport)

	{
		event := testAdminTranslate(
			&transport,
			.ServerUserUpdated,
			common.ServerUserUpdatedPayload {
				user = {id = 9, nickname = "bob", isOnline = true, isAdmin = true},
			},
		)
		defer ClientTransportRuntimeEvent_deinit(&event)
		testing.expect(
			t,
			event.kind == .UserUpdated &&
			event.serverID == 950 &&
			event.user.id == 9 &&
			event.user.nickname == "bob" &&
			event.user.isOnline &&
			event.user.isAdmin,
			fmt.tprintf("expected bob's directory entry, got %v", event),
		)
	}
	{
		event := testAdminTranslate(
			&transport,
			.ServerAccountUpdated,
			common.ServerAccountUpdatedPayload {
				isAdmin = true,
				nickname = "renamed",
				nicknameLocked = true,
			},
		)
		defer ClientTransportRuntimeEvent_deinit(&event)
		testing.expect(
			t,
			event.kind == .AccountUpdated &&
			event.isAdmin &&
			event.nickname == "renamed" &&
			event.nicknameLocked &&
			event.userID == 7,
			fmt.tprintf("expected this account made an admin and renamed, got %v", event),
		)
	}
	{
		event := testAdminTranslate(
			&transport,
			.ServerAdminActionResult,
			common.ServerAdminActionResultPayload {
				action = .Kick,
				userId = 9,
				message = "Kicked bob",
			},
		)
		defer ClientTransportRuntimeEvent_deinit(&event)
		testing.expect(
			t,
			event.kind == .AdminActionResult &&
			event.adminAction == .Kick &&
			event.peerUserID == 9 &&
			event.message == "Kicked bob",
			fmt.tprintf("expected the kick result, got %v", event),
		)
	}
	// Payloads that do not decode or make no sense are protocol errors.
	{
		event := testAdminTranslate(
			&transport,
			.ServerUserUpdated,
			common.ServerUserUpdatedPayload{user = {id = 0, nickname = "nobody"}},
		)
		defer ClientTransportRuntimeEvent_deinit(&event)
		testing.expect(
			t,
			event.kind == .ProtocolError,
			"expected a user update without an ID refused",
		)
	}
	{
		BadResult :: struct {
			action:  int,
			userId:  int,
			message: string,
		}
		event := testAdminTranslate(
			&transport,
			.ServerAdminActionResult,
			BadResult{action = 99, userId = 1, message = "?"},
		)
		defer ClientTransportRuntimeEvent_deinit(&event)
		testing.expect(t, event.kind == .ProtocolError, "expected an unknown action refused")
	}
}

@(test)
testSessionEndedStopsTheConnectionUntilRetry :: proc(t: ^testing.T) {
	Case :: struct {
		kind:    common.SessionEndedKind,
		reason:  string,
		message: string,
		failure: ClientConnectFailureKind,
	}
	cases := [?]Case {
		{.Kicked, "cool off", "You were kicked from this server: cool off", .Kicked},
		{.Kicked, "", "You were kicked from this server", .Kicked},
		{.Banned, "spam", "This account is banned from this server: spam", .Banned},
	}
	for testCase in cases {
		transport := testAdminTransport(951)
		defer ClientServerTransport_deinit(&transport)
		transport.connection.status = .Established
		event := testAdminTranslate(
			&transport,
			.ServerSessionEnded,
			common.ServerSessionEndedPayload{kind = testCase.kind, reason = testCase.reason},
		)
		defer ClientTransportRuntimeEvent_deinit(&event)
		testing.expect(
			t,
			event.kind == .SessionEnded &&
			event.failureKind == testCase.failure &&
			!event.retryable &&
			event.message == testCase.message &&
			event.detail == testCase.reason,
			fmt.tprintf("expected %v to end the session, got %v", testCase.kind, event),
		)
		// The worker stops here: no automatic reconnect a second later undoes the kick.
		testing.expect(
			t,
			transport.connection.status == .Failed && transport.transport.phase == .Failed,
			fmt.tprintf("expected the connection stopped, got %v", transport.connection.status),
		)
		ClientServerTransport_requestConnect(&transport, {})
		testing.expect(
			t,
			transport.connection.status == .Disconnected,
			"expected Retry to connect again",
		)
	}

	// The server's refusal of a banned sign-in, with or without a reason, is not retried either.
	for message in ([]string {
			SERVER_BANNED_MESSAGE,
			"This account is banned from this server: spam",
		}) {
		kind := classifyConnectFailure(message)
		testing.expect(
			t,
			kind == .Banned && !connectFailureIsRetryable(kind),
			fmt.tprintf("expected %q to be a ban that is not retried, got %v", message, kind),
		)
	}
	testing.expect(
		t,
		classifyConnectFailure(CLIENT_KICKED_MESSAGE) == .Kicked &&
		!connectFailureIsRetryable(.Kicked),
		"expected a kick not to be retried",
	)
}

@(test)
testKickedAndBannedConnectionsExplainThemselves :: proc(t: ^testing.T) {
	server := testRoomAdminServer(952)
	state := testUpdateStateForServer(server)
	defer State_deinit(&state)
	testApplyConnectedAs(&state, server.id, 3, false)

	ended := ClientTransportRuntimeEvent {
		kind        = .SessionEnded,
		serverID    = server.id,
		message     = strings.clone("You were kicked from this server: cool off"),
		detail      = strings.clone("cool off"),
		failureKind = .Kicked,
	}
	State_applyRuntimeEvent(&state, &ended)
	ClientTransportRuntimeEvent_deinit(&ended)
	connection := State_serverConnection(&state, server.id)
	testing.expect(
		t,
		connection.status == .Failed && connection.failureKind == .Kicked && !connection.retryable,
		fmt.tprintf("expected the kick to stop the connection, got %v", connection^),
	)
	banner := buildConnectionBanner(&state, time.tick_now())
	testing.expect(
		t,
		banner.tone == .Error &&
		banner.summary == "Kicked" &&
		banner.showRetry &&
		strings.contains(banner.text, "An admin removed you from this server") &&
		strings.contains(banner.text, "cool off") &&
		strings.contains(banner.text, "Press Retry"),
		fmt.tprintf("expected the kick explained, got %v", banner),
	)

	failed := ClientTransportRuntimeEvent {
		kind        = .ConnectFailed,
		serverID    = server.id,
		message     = strings.clone(SERVER_BANNED_MESSAGE),
		failureKind = .Banned,
	}
	State_applyRuntimeEvent(&state, &failed)
	ClientTransportRuntimeEvent_deinit(&failed)
	banner = buildConnectionBanner(&state, time.tick_now())
	testing.expect(
		t,
		banner.summary == "Banned" &&
		banner.showRetry &&
		strings.contains(banner.text, "This account is banned from this server") &&
		!strings.contains(banner.text, "reason") &&
		strings.contains(banner.text, "lift the ban"),
		fmt.tprintf("expected the ban explained, got %v", banner),
	)
}

@(test)
testAccountAndUserUpdatesApplyWithoutReconnecting :: proc(t: ^testing.T) {
	server := testRoomAdminServer(953)
	state := testUpdateStateForServer(server)
	defer State_deinit(&state)
	testApplyConnectedAs(&state, server.id, 3, false)
	testing.expect(t, !State_isServerAdmin(&state, server.id), "expected no admin at sign-in")

	// #41: the role and the name change while connected.
	account := ClientTransportRuntimeEvent {
		kind           = .AccountUpdated,
		serverID       = server.id,
		isAdmin        = true,
		nickname       = strings.clone("admin-chose"),
		nicknameLocked = true,
	}
	State_applyRuntimeEvent(&state, &account)
	ClientTransportRuntimeEvent_deinit(&account)
	connection := State_serverConnection(&state, server.id)
	testing.expect(
		t,
		State_isServerAdmin(&state, server.id) &&
		connection.nickname == "admin-chose" &&
		connection.nicknameLocked,
		fmt.tprintf("expected the account updated in place, got %v", connection^),
	)
	rows := buildSidebarRows(&state)
	testing.expect(t, rows[0].action == .NewRoom, "expected the admin controls without a reconnect")

	// Losing the role closes an open room form.
	State_openRoomCreator(&state)
	revoked := ClientTransportRuntimeEvent {
		kind     = .AccountUpdated,
		serverID = server.id,
		nickname = strings.clone("admin-chose"),
	}
	State_applyRuntimeEvent(&state, &revoked)
	ClientTransportRuntimeEvent_deinit(&revoked)
	testing.expect(
		t,
		!State_isServerAdmin(&state, server.id) && state.roomEditor.mode == .Closed,
		"expected the role gone and the room form closed",
	)

	// The directory entry is replaced in place, or added when unknown.
	users := ClientTransportRuntimeEvent {
		kind     = .UserListReceived,
		serverID = server.id,
	}
	append(&users.users, common.UserSummary{id = 3, nickname = strings.clone("me")})
	append(
		&users.users,
		common.UserSummary{id = 9, nickname = strings.clone("bob"), isOnline = true},
	)
	State_applyRuntimeEvent(&state, &users)
	ClientTransportRuntimeEvent_deinit(&users)
	for update in ([]common.UserSummary {
			{id = 9, nickname = "robert", isOnline = true, isBanned = true},
			{id = 11, nickname = "carol", isAdmin = true},
		}) {
		event := ClientTransportRuntimeEvent {
			kind     = .UserUpdated,
			serverID = server.id,
			user     = update,
		}
		event.user.nickname = strings.clone(update.nickname)
		State_applyRuntimeEvent(&state, &event)
		ClientTransportRuntimeEvent_deinit(&event)
	}
	cache := State_serverDirectCache(&state, server.id)
	testing.expect(t, len(cache.users) == 3, fmt.tprintf("expected 3 users, got %v", cache.users))
	bob := cache.users[ServerDirectCache_userIndex(cache^, 9)]
	carol := cache.users[ServerDirectCache_userIndex(cache^, 11)]
	testing.expect(
		t,
		bob.nickname == "robert" && bob.isBanned && bob.isOnline && !bob.isAdmin,
		fmt.tprintf("expected bob renamed and banned, got %v", bob),
	)
	testing.expect(t, carol.nickname == "carol" && carol.isAdmin, "expected carol added")
}

@(test)
testAdminRequestsGoThroughTheBridgeAndTrackTheAnswer :: proc(t: ^testing.T) {
	sync.mutex_lock(&adminSendBridgeTestMutex)
	defer sync.mutex_unlock(&adminSendBridgeTestMutex)
	testAdminUseStub()
	defer testAdminRestore()

	server := testRoomAdminServer(954)
	state := testUpdateStateForServer(server)
	defer State_deinit(&state)

	// Nothing goes out while not connected, or for a malformed request.
	testExpectString(
		t,
		State_sendAdminSetRole(&state, server.id, 9, true),
		NOT_CONNECTED_MESSAGE,
		"the offline error",
	)
	testApplyConnectedAs(&state, server.id, 3, true)
	testExpectString(
		t,
		State_sendAdminKickUser(&state, server.id, 0, ""),
		"No account selected.",
		"the missing target error",
	)
	testing.expect(
		t,
		strings.has_prefix(
			State_sendAdminRenameUser(&state, server.id, 9, "ab", true),
			"Names must be 3 to 32 bytes",
		),
		"expected a too-short name refused",
	)
	testExpectString(
		t,
		State_sendAdminBanUser(
			&state,
			server.id,
			9,
			true,
			strings.repeat("r", common.ADMIN_REASON_MAX_BYTES + 1, context.temp_allocator),
		),
		"The reason must be at most 256 bytes long.",
		"the long reason error",
	)
	testing.expect(t, adminSendBridgeTestCount == 0, "expected no request for a bad one")

	Sent :: struct {
		send:     proc(state: ^State, serverID: int) -> string,
		expected: AdminRequest,
	}
	sends := [?]Sent {
		{
			proc(state: ^State, serverID: int) -> string {
				return State_sendAdminSetRole(state, serverID, 9, true)
			},
			{action = .SetRole, userID = 9, flag = true},
		},
		{
			proc(state: ^State, serverID: int) -> string {
				return State_sendAdminKickUser(state, serverID, 9, " cool off ")
			},
			{action = .Kick, userID = 9, reason = "cool off"},
		},
		{
			proc(state: ^State, serverID: int) -> string {
				return State_sendAdminBanUser(state, serverID, 9, true, "spam")
			},
			{action = .Ban, userID = 9, flag = true, reason = "spam"},
		},
		{
			proc(state: ^State, serverID: int) -> string {
				return State_sendAdminBanUser(state, serverID, 9, false, "dropped")
			},
			{action = .Ban, userID = 9},
		},
	}
	for entry, index in sends {
		testExpectString(t, entry.send(&state, server.id), "", "the send result")
		testing.expect(
			t,
			adminSendBridgeTestCount == index + 1 && adminSendBridgeTestLast == entry.expected,
			fmt.tprintf("expected %v, got %v", entry.expected, adminSendBridgeTestLast),
		)
	}
	State_sendAdminRenameUser(&state, server.id, 9, " robert ", true)
	testing.expect(
		t,
		adminSendBridgeTestLast.action == .Rename &&
		adminSendBridgeTestLast.nickname == "robert" &&
		adminSendBridgeTestLast.flag,
		fmt.tprintf("expected a trimmed, locked rename, got %v", adminSendBridgeTestLast),
	)
	testing.expect(
		t,
		state.adminRequest.pending &&
		state.adminRequest.action == .Rename &&
		state.adminRequest.userID == 9,
		"expected the rename to wait for the server",
	)

	result := ClientTransportRuntimeEvent {
		kind        = .AdminActionResult,
		serverID    = server.id,
		adminAction = .Rename,
		peerUserID  = 9,
		message     = strings.clone("Renamed bob to robert"),
	}
	State_applyRuntimeEvent(&state, &result)
	ClientTransportRuntimeEvent_deinit(&result)
	testing.expect(
		t,
		!state.adminRequest.pending && state.adminRequest.result == "Renamed bob to robert",
		fmt.tprintf("expected the answer recorded, got %v", state.adminRequest),
	)

	// A protocol error answers a pending request; a dropped connection ends the wait.
	State_sendAdminKickUser(&state, server.id, 3, "")
	refusal := ClientTransportRuntimeEvent {
		kind     = .ProtocolError,
		serverID = server.id,
		message  = strings.clone("You cannot kick yourself"),
	}
	State_applyRuntimeEvent(&state, &refusal)
	ClientTransportRuntimeEvent_deinit(&refusal)
	testing.expect(
		t,
		!state.adminRequest.pending && state.adminRequest.error == "You cannot kick yourself",
		fmt.tprintf("expected the refusal recorded, got %v", state.adminRequest),
	)
	State_sendAdminSetRole(&state, server.id, 9, false)
	lost := ClientTransportRuntimeEvent {
		kind     = .Disconnected,
		serverID = server.id,
		message  = strings.clone("gone"),
	}
	State_applyRuntimeEvent(&state, &lost)
	ClientTransportRuntimeEvent_deinit(&lost)
	testing.expect(
		t,
		!state.adminRequest.pending && strings.contains(state.adminRequest.error, "dropped"),
		fmt.tprintf("expected the wait ended by the disconnect, got %v", state.adminRequest),
	)
}

@(test)
testAdminTransportBuildsEachRequest :: proc(t: ^testing.T) {
	server := testRoomAdminServer(956)
	config := testConfigWithServers({server})
	defer Config_deinit(&config)
	transport, serverTransport, ok := buildEstablishedTransportPair(server, config)
	assert(ok, "expected transport pair setup to succeed")
	defer ClientServerTransport_deinit(&transport)

	Case :: struct {
		request:     AdminRequest,
		messageType: common.MessageType,
	}
	cases := [?]Case {
		{{action = .SetRole, userID = 9, flag = true}, .ClientAdminSetRole},
		{{action = .Rename, userID = 9, nickname = "robert", flag = true}, .ClientAdminRenameUser},
		{{action = .Kick, userID = 9, reason = "cool off"}, .ClientAdminKickUser},
		{{action = .Ban, userID = 9, flag = true, reason = "spam"}, .ClientAdminBanUser},
	}
	for testCase in cases {
		// Built the way sendAdminRequest builds them, and opened on the server side.
		payload: any
		#partial switch testCase.request.action {
		case .SetRole:
			payload = common.ClientAdminSetRolePayload{userId = 9, isAdmin = true}
		case .Rename:
			payload = common.ClientAdminRenameUserPayload {
				userId   = 9,
				nickname = "robert",
				locked   = true,
			}
		case .Kick:
			payload = common.ClientAdminKickUserPayload{userId = 9, reason = "cool off"}
		case .Ban:
			payload = common.ClientAdminBanUserPayload{userId = 9, banned = true, reason = "spam"}
		}
		packetBytes, built := ClientServerTransport_buildEncryptedPacketBytes(
			&transport,
			testCase.messageType,
			payload,
		)
		assert(built, "expected the request packet to build")
		defer delete(packetBytes)
		outer: common.Packet
		assert(cbor.unmarshal(packetBytes, &outer) == nil, "expected the outer packet to decode")
		defer delete(outer.payload)
		inner, openOK := common.openPacketForSession(&serverTransport, outer)
		assert(openOK, "expected the server to open the packet")
		defer delete(inner.payload)
		testing.expect(
			t,
			inner.messageType == testCase.messageType,
			fmt.tprintf("expected %v, got %v", testCase.messageType, inner.messageType),
		)
		if testCase.request.action == .Ban {
			request: common.ClientAdminBanUserPayload
			decoded := cbor.unmarshal(inner.payload, &request) == nil
			defer common.ClientAdminBanUserPayload_deinit(&request)
			testing.expect(
				t,
				decoded && request.userId == 9 && request.banned && request.reason == "spam",
				fmt.tprintf("expected the ban to decode, got %v", request),
			)
		}
	}

	// Without a live ENet session every request reports "not connected" without failing it.
	offline := testAdminTransport(957)
	defer ClientServerTransport_deinit(&offline)
	for testCase in cases {
		testing.expect(
			t,
			!ClientServerTransport_sendAdminRequest(&offline, testCase.request),
			fmt.tprintf("expected no %v without a live session", testCase.request.action),
		)
		testExpectString(t, offline.lastError, NOT_CONNECTED_MESSAGE, "the request error")
	}
}

@(test)
testHeadlessAdminCommandsAndEvents :: proc(t: ^testing.T) {
	sync.mutex_lock(&adminSendBridgeTestMutex)
	defer sync.mutex_unlock(&adminSendBridgeTestMutex)
	testAdminUseStub()
	defer testAdminRestore()

	builder := strings.builder_make()
	harness := testHeadlessHarness(&builder, 955)
	defer testHeadlessHarnessDeinit(&harness, &builder)
	testApplyConnectedAs(&harness.state, 955, 3, true)

	Command :: struct {
		line:     string,
		output:   string,
		expected: AdminRequest,
	}
	commands := [?]Command {
		{
			"admin-role 9 on",
			`{"ok":true,"cmd":"admin-role","serverID":955,"userID":9}`,
			{action = .SetRole, userID = 9, flag = true},
		},
		{
			"admin-rename 9 lock new name",
			`{"ok":true,"cmd":"admin-rename","serverID":955,"userID":9}`,
			{action = .Rename, userID = 9, flag = true, nickname = "new name"},
		},
		{
			"admin-rename 9 unlock",
			`{"ok":true,"cmd":"admin-rename","serverID":955,"userID":9}`,
			{action = .Rename, userID = 9},
		},
		{
			"admin-kick 9 cool off",
			`{"ok":true,"cmd":"admin-kick","serverID":955,"userID":9}`,
			{action = .Kick, userID = 9, reason = "cool off"},
		},
		{
			"admin-ban 9 spam",
			`{"ok":true,"cmd":"admin-ban","serverID":955,"userID":9}`,
			{action = .Ban, userID = 9, flag = true, reason = "spam"},
		},
		{
			"admin-unban 9",
			`{"ok":true,"cmd":"admin-unban","serverID":955,"userID":9}`,
			{action = .Ban, userID = 9},
		},
	}
	for command in commands {
		headlessHandleLine(&harness, command.line)
		testExpectString(
			t,
			testHeadlessTakeOutput(&builder),
			fmt.tprintf("%s\n", command.output),
			command.line,
		)
		testing.expect(
			t,
			adminSendBridgeTestLast == command.expected,
			fmt.tprintf(
				"expected %q to send %v, got %v",
				command.line,
				command.expected,
				adminSendBridgeTestLast,
			),
		)
	}
	headlessHandleLine(&harness, "admin-role 9 maybe")
	testExpectString(
		t,
		testHeadlessTakeOutput(&builder),
		`{"ok":false,"cmd":"admin-role","error":"usage: admin-role USER_ID on|off"}` + "\n",
		"the admin-role usage error",
	)
	headlessHandleLine(&harness, "admin-kick nobody")
	testExpectString(
		t,
		testHeadlessTakeOutput(&builder),
		`{"ok":false,"cmd":"admin-kick","error":"usage: admin-kick USER_ID [REASON...]"}` + "\n",
		"the admin-kick usage error",
	)

	Event :: struct {
		event: ClientTransportRuntimeEvent,
		line:  string,
		kind:  HeadlessEventKind,
	}
	events := [?]Event {
		{
			{
				kind = .UserUpdated,
				serverID = 955,
				user = {id = 9, nickname = strings.clone("bob"), isOnline = true, isBanned = true},
			},
			`{"event":"user_updated","serverID":955,"user":{"id":9,"nickname":"bob",` +
			`"isOnline":true,"identityPublicKey":"","hasEncryptionKey":false,` +
			`"keyState":"unknown","isAdmin":false,"isBanned":true,"roleIds":[],` +
			`"isRestricted":false}}`,
			.UserUpdated,
		},
		{
			{
				kind = .AdminActionResult,
				serverID = 955,
				adminAction = .Ban,
				peerUserID = 9,
				message = strings.clone("Banned bob"),
			},
			`{"event":"admin_result","serverID":955,"action":"ban","userID":9,` +
			`"message":"Banned bob","roleID":0,"inviteID":0,"requestID":0}`,
			.AdminResult,
		},
		{
			{
				kind = .AccountUpdated,
				serverID = 955,
				isAdmin = true,
				nickname = strings.clone("Tester"),
				nicknameLocked = true,
			},
			`{"event":"account_updated","serverID":955,"isAdmin":true,"nickname":"Tester",` +
			`"nicknameLocked":true,"permissions":[],"isRestricted":false}`,
			.AccountUpdated,
		},
		{
			{
				kind = .SessionEnded,
				serverID = 955,
				failureKind = .Kicked,
				message = strings.clone("You were kicked from this server: cool off"),
				detail = strings.clone("cool off"),
			},
			`{"event":"session_ended","serverID":955,"kind":"kicked","message":"An admin ` +
			`removed you from this server (reason: cool off). Press Retry to connect again.",` +
			`"reason":"cool off","retryable":false}`,
			.SessionEnded,
		},
	}
	for &entry in events {
		headlessHandleRuntimeEvent(&harness, &entry.event)
		ClientTransportRuntimeEvent_deinit(&entry.event)
		testExpectString(
			t,
			testHeadlessTakeOutput(&builder),
			fmt.tprintf("%s\n", entry.line),
			entry.line,
		)
		testing.expect(
			t,
			harness.pendingEvents[entry.kind] == 1,
			fmt.tprintf("expected %v to count for wait", entry.kind),
		)
	}
	testing.expect(
		t,
		State_serverConnection(&harness.state, 955).status == .Failed,
		"expected session_ended to stop the connection",
	)
}
