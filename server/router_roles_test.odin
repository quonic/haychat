package server

import "../common"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:testing"

// Router tests for roles (router_roles.odin, protocol 23): the shape checks, the statements
// queued, and who hears what. The guards run in SQL (database_roles_test.odin). Admin alice is
// peer 1 and bob has two sessions, peers 2 and 3 (routerAdminTestClients).

// Sends a role request from client and returns the statement it queued.
@(private = "file")
routerRoleTestSend :: proc(
	h: ^RouterTestHarness,
	client: ^RouterVoiceTestClient,
	messageType: common.MessageType,
	payload: any,
) -> (
	DatabaseQuery,
	common.DatabaseRoleRequest,
) {
	routerTestSendSealed(h, &client.transport, client.peerID, messageType, payload)
	query := routerPollDatabaseQuery(h)
	request, ok := query.request.(common.DatabaseRoleRequest)
	assert(ok, fmt.tprintf("expected %v to queue one role statement, got %v", messageType, query))
	return query, request
}

// Answers a role statement; every owned field is allocated here.
@(private = "file")
routerRoleTestAnswer :: proc(
	h: ^RouterTestHarness,
	query: DatabaseQuery,
	outcome: common.DatabaseAdminOutcome,
	changed := false,
	role: common.RoleSummary = {},
	user: common.UserSummary = {},
	affected: []common.DatabaseAccountPermissions = nil,
) {
	result := common.DatabaseRoleResult {
		outcome = outcome,
		changed = changed,
		role    = common.RoleSummary_clone(role),
		user    = common.UserSummary_clone(user),
	}
	result.affected = make([dynamic]common.DatabaseAccountPermissions)
	for account in affected {
		copy := account
		copy.nickname = strings.clone(account.nickname)
		append(&result.affected, copy)
	}
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		query.request_id,
		common.DatabaseQueryResponse{success = true, result = result},
	)
}

@(private = "file")
routerRoleTestExpectRefused :: proc(
	h: ^RouterTestHarness,
	clients: []RouterVoiceTestClient,
	message: string,
) {
	drain := routerVoiceTestDrain(h, clients)
	defer RouterVoiceTestDrain_deinit(&drain)
	refusal := routerAdminTestDecode(
		&drain,
		1,
		.ServerProtocolError,
		common.ProtocolErrorResponse,
	)
	defer delete(refusal.message)
	assert(
		refusal.message == message && len(drain.packets) == 1,
		fmt.tprintf(
			"expected only %q for alice, got %q in %v",
			message,
			refusal.message,
			drain.packets,
		),
	)
}

@(test)
testMainRouterRoleSaveFansOutToEverySession :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)
	clients := routerAdminTestClients()
	routerVoiceTestConnect(&h, clients[:])
	defer routerVoiceTestDisconnectAll(clients[:])

	query, request := routerRoleTestSend(
		&h,
		&clients[0],
		.ClientAdminSaveRole,
		common.ClientAdminSaveRolePayload{name = "room keepers", permissions = {.ManageRooms}},
	)
	defer IPC__database_query_request_deinit(query.request)
	assert(
		request.action == .Save &&
		request.actorUserId == ROUTER_ADMIN_TEST_ADMIN &&
		request.roleId == 0 &&
		request.name == "room keepers" &&
		request.permissions == {.ManageRooms},
		fmt.tprintf("expected a create by alice, got %v", request),
	)
	// Bob holds the role being saved: his sessions hear their new set.
	routerRoleTestAnswer(
		&h,
		query,
		.Applied,
		changed = true,
		role = {id = 7, name = "room keepers", permissions = {.ManageRooms}, position = 1},
		affected = {
			{
				userId = ROUTER_ADMIN_TEST_TARGET,
				nickname = "voice-user-43",
				permissions = {.ManageRooms},
			},
		},
	)
	routerTestExpectNoDatabaseQuery(&h, "expected a role save to need one statement")

	drain := routerVoiceTestDrain(&h, clients[:])
	defer RouterVoiceTestDrain_deinit(&drain)
	result := routerAdminTestDecode(
		&drain,
		1,
		.ServerAdminActionResult,
		common.ServerAdminActionResultPayload,
	)
	defer common.ServerAdminActionResultPayload_deinit(&result)
	assert(
		result.action == .SaveRole &&
		result.roleId == 7 &&
		result.message == "Created the role room keepers",
		fmt.tprintf("expected the create answered, got %v", result),
	)
	for peerID in ([]u32{1, 2, 3}) {
		updated := routerAdminTestDecode(
			&drain,
			peerID,
			.ServerRoleUpdated,
			common.ServerRoleUpdatedPayload,
		)
		defer common.ServerRoleUpdatedPayload_deinit(&updated)
		assert(
			updated.role.id == 7 &&
			updated.role.name == "room keepers" &&
			updated.role.permissions == {.ManageRooms},
			fmt.tprintf("expected peer %d to hear the role, got %v", peerID, updated.role),
		)
	}
	assert(
		routerAdminTestCount(&drain, 1, .ServerAccountUpdated) == 0,
		"expected no account update for alice",
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
			!account.isAdmin &&
			account.nickname == "voice-user-43" &&
			account.permissions == {.ManageRooms},
			fmt.tprintf("expected peer %d to hear ManageRooms, got %v", peerID, account),
		)
	}
	assert(len(drain.packets) == 6, fmt.tprintf("expected 6 packets, got %d", len(drain.packets)))

	// An unchanged save answers alice and tells nobody.
	repeatQuery, _ := routerRoleTestSend(
		&h,
		&clients[0],
		.ClientAdminSaveRole,
		common.ClientAdminSaveRolePayload {
			roleId = 7,
			name = "room keepers",
			permissions = {.ManageRooms},
		},
	)
	defer IPC__database_query_request_deinit(repeatQuery.request)
	routerRoleTestAnswer(
		&h,
		repeatQuery,
		.Applied,
		role = {id = 7, name = "room keepers", permissions = {.ManageRooms}},
	)
	again := routerVoiceTestDrain(&h, clients[:])
	defer RouterVoiceTestDrain_deinit(&again)
	assert(
		len(again.packets) == 1 && again.packets[0].packet.messageType == .ServerAdminActionResult,
		fmt.tprintf("expected only the result for a no-op save, got %v", again.packets),
	)

	// A refusal is a protocol error for alice alone.
	refusedQuery, _ := routerRoleTestSend(
		&h,
		&clients[0],
		.ClientAdminSaveRole,
		common.ClientAdminSaveRolePayload{roleId = 1, name = "boss", permissions = {}},
	)
	defer IPC__database_query_request_deinit(refusedQuery.request)
	routerRoleTestAnswer(&h, refusedQuery, .BuiltinRole)
	routerRoleTestExpectRefused(
		&h,
		clients[:],
		"The admin role cannot be renamed or given fewer permissions",
	)
}

@(test)
testMainRouterRoleSetUserRolesUpdatesTheDirectoryAndTheAccount :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)
	clients := routerAdminTestClients()
	routerVoiceTestConnect(&h, clients[:])
	defer routerVoiceTestDisconnectAll(clients[:])

	roleIDs := make([dynamic]int, context.temp_allocator)
	append(&roleIDs, 7, 9)
	query, request := routerRoleTestSend(
		&h,
		&clients[0],
		.ClientAdminSetUserRoles,
		common.ClientAdminSetUserRolesPayload{userId = ROUTER_ADMIN_TEST_TARGET, roleIds = roleIDs},
	)
	defer IPC__database_query_request_deinit(query.request)
	assert(
		request.action == .SetUserRoles &&
		request.targetUserId == ROUTER_ADMIN_TEST_TARGET &&
		len(request.roleIds) == 2 &&
		request.roleIds[1] == 9,
		fmt.tprintf("expected bob's two roles, got %v", request),
	)
	userRoles := make([dynamic]int, context.temp_allocator)
	append(&userRoles, 7, 9)
	routerRoleTestAnswer(
		&h,
		query,
		.Applied,
		changed = true,
		user = {id = ROUTER_ADMIN_TEST_TARGET, nickname = "voice-user-43", roleIds = userRoles},
		affected = {
			{
				userId = ROUTER_ADMIN_TEST_TARGET,
				nickname = "voice-user-43",
				permissions = {.ManageRooms, .ManageRoomMembers},
			},
		},
	)

	drain := routerVoiceTestDrain(&h, clients[:])
	defer RouterVoiceTestDrain_deinit(&drain)
	routerAdminTestExpectResult(
		&drain,
		.SetUserRoles,
		ROUTER_ADMIN_TEST_TARGET,
		"Updated the roles of voice-user-43",
	)
	for peerID in ([]u32{1, 2, 3}) {
		update := routerAdminTestDecode(
			&drain,
			peerID,
			.ServerUserUpdated,
			common.ServerUserUpdatedPayload,
		)
		defer common.ServerUserUpdatedPayload_deinit(&update)
		assert(
			update.user.id == ROUTER_ADMIN_TEST_TARGET &&
			update.user.isOnline &&
			len(update.user.roleIds) == 2 &&
			update.user.roleIds[0] == 7,
			fmt.tprintf("expected peer %d to see bob's roles, got %v", peerID, update.user),
		)
	}
	for peerID in ([]u32{2, 3}) {
		account := routerAdminTestDecode(
			&drain,
			peerID,
			.ServerAccountUpdated,
			common.ServerAccountUpdatedPayload,
		)
		defer common.ServerAccountUpdatedPayload_deinit(&account)
		assert(
			account.permissions == {.ManageRooms, .ManageRoomMembers},
			fmt.tprintf("expected peer %d to hear its permissions, got %v", peerID, account),
		)
	}
	assert(len(drain.packets) == 6, fmt.tprintf("expected 6 packets, got %d", len(drain.packets)))
}

@(test)
testMainRouterRoleDeleteTellsEverySessionAndTheHolders :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)
	clients := routerAdminTestClients()
	routerVoiceTestConnect(&h, clients[:])
	defer routerVoiceTestDisconnectAll(clients[:])

	query, request := routerRoleTestSend(
		&h,
		&clients[0],
		.ClientAdminDeleteRole,
		common.ClientAdminDeleteRolePayload{roleId = 7},
	)
	defer IPC__database_query_request_deinit(query.request)
	assert(request.action == .Delete && request.roleId == 7, "expected role 7 deleted")
	routerRoleTestAnswer(
		&h,
		query,
		.Applied,
		changed = true,
		affected = {{userId = ROUTER_ADMIN_TEST_TARGET, nickname = "voice-user-43"}},
	)
	drain := routerVoiceTestDrain(&h, clients[:])
	defer RouterVoiceTestDrain_deinit(&drain)
	for peerID in ([]u32{1, 2, 3}) {
		deleted := routerAdminTestDecode(
			&drain,
			peerID,
			.ServerRoleDeleted,
			common.ServerRoleDeletedPayload,
		)
		assert(deleted.roleId == 7, fmt.tprintf("expected peer %d to hear it", peerID))
	}
	for peerID in ([]u32{2, 3}) {
		account := routerAdminTestDecode(
			&drain,
			peerID,
			.ServerAccountUpdated,
			common.ServerAccountUpdatedPayload,
		)
		defer common.ServerAccountUpdatedPayload_deinit(&account)
		assert(account.permissions == {}, "expected bob left without permissions")
	}
	result := routerAdminTestDecode(
		&drain,
		1,
		.ServerAdminActionResult,
		common.ServerAdminActionResultPayload,
	)
	defer common.ServerAdminActionResultPayload_deinit(&result)
	assert(result.action == .DeleteRole && result.roleId == 7, "expected the delete answered")
	assert(len(drain.packets) == 6, fmt.tprintf("expected 6 packets, got %d", len(drain.packets)))
}

@(test)
testMainRouterRoleListAnswersAnyAccount :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)
	clients := routerAdminTestClients()
	routerVoiceTestConnect(&h, clients[:])
	defer routerVoiceTestDisconnectAll(clients[:])

	query, request := routerRoleTestSend(
		&h,
		&clients[1],
		.ClientAdminListRoles,
		common.ClientAdminListRolesPayload{},
	)
	defer IPC__database_query_request_deinit(query.request)
	assert(request.action == .List, "expected a list")
	roles := make([dynamic]common.RoleSummary)
	append(
		&roles,
		common.RoleSummary {
			id = 1,
			name = strings.clone("admin"),
			permissions = common.SERVER_PERMISSIONS_ALL,
			builtin = true,
		},
	)
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		query.request_id,
		common.DatabaseQueryResponse {
			success = true,
			result = common.DatabaseRoleResult{outcome = .Applied, roles = roles},
		},
	)
	drain := routerVoiceTestDrain(&h, clients[:])
	defer RouterVoiceTestDrain_deinit(&drain)
	list := routerAdminTestDecode(&drain, 2, .ServerRoleList, common.ServerRoleListPayload)
	defer common.ServerRoleListPayload_deinit(&list)
	assert(
		len(drain.packets) == 1 && len(list.roles) == 1 && list.roles[0].builtin,
		fmt.tprintf("expected only bob's session to get the list, got %v", drain.packets),
	)
}

// Malformed requests never reach the database.
@(test)
testMainRouterRoleRequestsAreCheckedForShape :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)
	clients := routerAdminTestClients()
	routerVoiceTestConnect(&h, clients[:])
	defer routerVoiceTestDisconnectAll(clients[:])

	saves := [?]common.ClientAdminSaveRolePayload {
		{name = "x", permissions = {.ManageRooms}},
		{name = " padded", permissions = {.ManageRooms}},
		{name = "kickers", permissions = {.KickUsers}},
		{name = "everything", permissions = common.SERVER_PERMISSIONS_ALL},
		{roleId = 4, name = "most", permissions = {.ManageRooms, .BanUsers}},
		{roleId = -1, name = "negative"},
		{name = "lower", position = -2},
	}
	for save in saves {
		routerTestSendSealed(&h, &clients[0].transport, 1, .ClientAdminSaveRole, save)
		routerTestExpectNoDatabaseQuery(&h, fmt.tprintf("expected %v refused", save))
		routerRoleTestExpectRefused(&h, clients[:], ROLE_INVALID_REQUEST_MESSAGE)
	}

	duplicate := make([dynamic]int, context.temp_allocator)
	append(&duplicate, 7, 7)
	tooMany := make([dynamic]int, context.temp_allocator)
	for index in 0 ..= common.SERVER_ROLES_MAX {
		append(&tooMany, index + 1)
	}
	zero := make([dynamic]int, context.temp_allocator)
	append(&zero, 0)
	sets := [?]common.ClientAdminSetUserRolesPayload {
		{userId = ROUTER_ADMIN_TEST_TARGET, roleIds = duplicate},
		{userId = ROUTER_ADMIN_TEST_TARGET, roleIds = tooMany},
		{userId = ROUTER_ADMIN_TEST_TARGET, roleIds = zero},
		{userId = 0},
	}
	for set in sets {
		routerTestSendSealed(&h, &clients[0].transport, 1, .ClientAdminSetUserRoles, set)
		routerTestExpectNoDatabaseQuery(&h, "expected a malformed role set refused")
		routerRoleTestExpectRefused(&h, clients[:], ROLE_INVALID_REQUEST_MESSAGE)
	}
	routerTestSendSealed(
		&h,
		&clients[0].transport,
		1,
		.ClientAdminDeleteRole,
		common.ClientAdminDeleteRolePayload{},
	)
	routerTestExpectNoDatabaseQuery(&h, "expected a delete of role 0 refused")
	routerRoleTestExpectRefused(&h, clients[:], ROLE_INVALID_REQUEST_MESSAGE)

	// The built-in role keeps every permission, so a save of exactly that set may name it.
	assert(
		roleSaveRequestIsValid(
			{roleId = 1, name = "admin", permissions = common.SERVER_PERMISSIONS_ALL},
		),
		"expected admin's own save to pass the shape check",
	)
}
