package server

import "../common"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:testing"

// Router tests for room access modes (router_room_access.odin, protocol 15) with stubbed
// database results: the rules themselves run in SQL (database_room_access_test.odin). Peers:
// admin alice (1, user 42), two sessions of bob (2 and 3, user 43), and carol (4, user 44).

routerRoomAccessTestClients :: proc() -> [4]RouterVoiceTestClient {
	return [4]RouterVoiceTestClient {
		{peerID = 1, userID = 42},
		{peerID = 2, userID = 43},
		{peerID = 3, userID = 43},
		{peerID = 4, userID = 44},
	}
}

// Sends a room member request from client and returns the statement it queued.
routerRoomAccessTestSend :: proc(
	h: ^RouterTestHarness,
	client: ^RouterVoiceTestClient,
	messageType: common.MessageType,
	payload: any,
) -> (
	DatabaseQuery,
	common.DatabaseRoomMemberActionRequest,
) {
	routerTestSendSealed(h, &client.transport, client.peerID, messageType, payload)
	query := routerPollDatabaseQuery(h)
	request, ok := query.request.(common.DatabaseRoomMemberActionRequest)
	assert(ok, fmt.tprintf("expected %v to queue one room statement, got %v", messageType, query))
	return query, request
}

routerRoomAccessTestAnswer :: proc(
	h: ^RouterTestHarness,
	query: DatabaseQuery,
	outcome: common.DatabaseRoomMemberOutcome,
	changed := false,
	members: []int = nil,
) {
	memberUserIDs := make([dynamic]int)
	append(&memberUserIDs, ..members)
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		query.request_id,
		common.DatabaseQueryResponse {
			success = true,
			result = common.DatabaseRoomMemberActionResult {
				outcome = outcome,
				changed = changed,
				access = .MemberInvite,
				memberUserIDs = memberUserIDs,
			},
		},
	)
}

routerRoomAccessTestExpectError :: proc(
	drain: ^RouterVoiceTestDrain,
	peerID: u32,
	message: string,
) {
	refusal := routerAdminTestDecode(
		drain,
		peerID,
		.ServerProtocolError,
		common.ProtocolErrorResponse,
	)
	defer delete(refusal.message)
	assert(
		refusal.message == message,
		fmt.tprintf("expected %q for peer %d, got %q", message, peerID, refusal.message),
	)
}

@(test)
testRoomAccessRouterAddFansOutToMembersAndTheTarget :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)
	clients := routerRoomAccessTestClients()
	routerVoiceTestConnect(&h, clients[:])
	defer routerVoiceTestDisconnectAll(clients[:])

	// bob (a member of Member invite room 7) invites carol.
	query, request := routerRoomAccessTestSend(
		&h,
		&clients[1],
		.ClientAddRoomMember,
		common.ClientRoomMembershipPayload{roomId = 7, userId = 44},
	)
	defer IPC__database_query_request_deinit(query.request)
	assert(
		request.action == .Add &&
		request.actorUserId == 43 &&
		request.roomId == 7 &&
		request.targetUserId == 44,
		fmt.tprintf("expected bob's add of carol to room 7, got %v", request),
	)
	routerRoomAccessTestAnswer(&h, query, .Applied, changed = true, members = {43, 44})
	routerTestExpectNoDatabaseQuery(&h, "expected the add to need one statement")

	drain := routerVoiceTestDrain(&h, clients[:])
	defer RouterVoiceTestDrain_deinit(&drain)
	added := routerAdminTestDecode(
		&drain,
		2,
		.ServerRoomMemberAdded,
		common.ServerRoomMutationPayload,
	)
	defer delete(added.room.name)
	defer delete(added.room.description)
	assert(
		added.roomId == 7 && added.userId == 44 && added.changed,
		fmt.tprintf("expected bob told carol was added, got %v", added),
	)
	assert(
		routerAdminTestCount(&drain, 3, .ServerRoomMemberAdded) == 0,
		"expected the result only for the session that asked",
	)
	// Members after the change (bob's two sessions and carol) learn it; alice is not a member.
	for peerID in ([]u32{2, 3, 4}) {
		change := routerAdminTestDecode(
			&drain,
			peerID,
			.ServerRoomMembershipChanged,
			common.ServerRoomMembershipChangedPayload,
		)
		assert(
			change.roomId == 7 && change.joined && change.userId == 44,
			fmt.tprintf("expected peer %d to hear carol joined 7, got %v", peerID, change),
		)
	}
	assert(
		routerAdminTestCount(&drain, 1, .ServerRoomMembershipChanged) == 0,
		"expected nothing for alice, who is not in the room and did not ask",
	)
}

@(test)
testRoomAccessRouterRefusalsNameTheRule :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)
	clients := routerRoomAccessTestClients()
	routerVoiceTestConnect(&h, clients[:])
	defer routerVoiceTestDisconnectAll(clients[:])

	Case :: struct {
		messageType: common.MessageType,
		payload:     any,
		outcome:     common.DatabaseRoomMemberOutcome,
		message:     string,
	}
	add := common.ClientRoomMembershipPayload {
		roomId = 7,
		userId = 44,
	}
	leave := common.ClientLeaveRoomPayload {
		roomId = 7,
	}
	fetch := common.ClientFetchRoomMembersPayload {
		roomId = 7,
	}
	cases := [?]Case {
		{.ClientAddRoomMember, add, .PublicRoom, ROOM_PUBLIC_ADD_MESSAGE},
		{.ClientAddRoomMember, add, .AdminRequired, ROOM_ADMIN_REQUIRED_MESSAGE},
		{.ClientAddRoomMember, add, .NotMember, ROOM_NOT_MEMBER_MESSAGE},
		{.ClientAddRoomMember, add, .UnknownUser, ROOM_UNKNOWN_USER_MESSAGE},
		{.ClientRemoveRoomMember, add, .AdminRequired, ROOM_ADMIN_REQUIRED_MESSAGE},
		{.ClientRemoveRoomMember, add, .UnknownRoom, ROOM_NOT_FOUND_MESSAGE},
		{.ClientLeaveRoom, leave, .PublicRoom, ROOM_PUBLIC_LEAVE_MESSAGE},
		{.ClientLeaveRoom, leave, .NotMember, ROOM_NOT_MEMBER_MESSAGE},
		{.ClientFetchRoomMembers, fetch, .NotMember, ROOM_NOT_MEMBER_MESSAGE},
	}
	for testCase in cases {
		query, _ := routerRoomAccessTestSend(
			&h,
			&clients[3],
			testCase.messageType,
			testCase.payload,
		)
		routerRoomAccessTestAnswer(&h, query, testCase.outcome)
		IPC__database_query_request_deinit(query.request)
		drain := routerVoiceTestDrain(&h, clients[:])
		routerRoomAccessTestExpectError(&drain, 4, testCase.message)
		assert(
			len(drain.packets) == 1,
			fmt.tprintf("expected only the refusal for %v, got %v", testCase, drain.packets),
		)
		RouterVoiceTestDrain_deinit(&drain)
	}
	// A malformed request never reaches the database.
	routerTestSendSealed(
		&h,
		&clients[3].transport,
		4,
		.ClientLeaveRoom,
		common.ClientLeaveRoomPayload{roomId = 0},
	)
	routerTestExpectNoDatabaseQuery(&h, "expected a leave of room 0 refused in the router")
	drain := routerVoiceTestDrain(&h, clients[:])
	defer RouterVoiceTestDrain_deinit(&drain)
	routerRoomAccessTestExpectError(&drain, 4, ROOM_MEMBERSHIP_INVALID_MESSAGE)
}

@(test)
testRoomAccessRouterLeaveFetchAndAdminList :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)
	clients := routerRoomAccessTestClients()
	routerVoiceTestConnect(&h, clients[:])
	defer routerVoiceTestDisconnectAll(clients[:])

	// bob leaves room 7, which carol stays in: the statement acts on bob whatever is sent.
	{
		query, request := routerRoomAccessTestSend(
			&h,
			&clients[1],
			.ClientLeaveRoom,
			common.ClientLeaveRoomPayload{roomId = 7},
		)
		defer IPC__database_query_request_deinit(query.request)
		assert(
			request.action == .Leave && request.actorUserId == 43 && request.targetUserId == 43,
			fmt.tprintf("expected bob leaving, got %v", request),
		)
		routerRoomAccessTestAnswer(&h, query, .Applied, changed = true, members = {44})
		drain := routerVoiceTestDrain(&h, clients[:])
		defer RouterVoiceTestDrain_deinit(&drain)
		for peerID in ([]u32{2, 3, 4}) {
			change := routerAdminTestDecode(
				&drain,
				peerID,
				.ServerRoomMembershipChanged,
				common.ServerRoomMembershipChangedPayload,
			)
			assert(
				change.roomId == 7 && !change.joined && change.userId == 43,
				fmt.tprintf("expected peer %d to hear bob left 7, got %v", peerID, change),
			)
		}
		assert(
			routerAdminTestCount(&drain, 1, .ServerRoomMembershipChanged) == 0,
			"expected nothing for alice",
		)
	}

	// carol fetches the members: only her session gets them.
	{
		query, request := routerRoomAccessTestSend(
			&h,
			&clients[3],
			.ClientFetchRoomMembers,
			common.ClientFetchRoomMembersPayload{roomId = 7},
		)
		defer IPC__database_query_request_deinit(query.request)
		assert(
			request.action == .Fetch && request.actorUserId == 44,
			fmt.tprintf("expected carol's fetch, got %v", request),
		)
		routerRoomAccessTestAnswer(&h, query, .Applied, members = {44})
		drain := routerVoiceTestDrain(&h, clients[:])
		defer RouterVoiceTestDrain_deinit(&drain)
		members := routerAdminTestDecode(
			&drain,
			4,
			.ServerRoomMembers,
			common.ServerRoomMembersPayload,
		)
		defer common.ServerRoomMembersPayload_deinit(&members)
		assert(
			members.roomId == 7 && len(members.userIds) == 1 && members.userIds[0] == 44,
			fmt.tprintf("expected room 7 with carol, got %v", members),
		)
		assert(len(drain.packets) == 1, "expected the members only for carol")
	}

	// The admin list: refused to a non-admin, every room to an admin.
	{
		routerTestSendSealed(
			&h,
			&clients[3].transport,
			4,
			.ClientAdminListRooms,
			common.ClientAdminListRoomsPayload{},
		)
		query := routerPollDatabaseQuery(&h)
		defer IPC__database_query_request_deinit(query.request)
		request, ok := query.request.(common.DatabaseAdminRoomListRequest)
		assert(ok && request.actorUserId == 44, fmt.tprintf("expected carol's list, got %v", query))
		MainRouterState_handleDatabaseResult(
			&h.pm,
			&h.state,
			query.request_id,
			common.DatabaseQueryResponse {
				success = true,
				result = common.DatabaseAdminRoomListResult{isAdmin = false},
			},
		)
		drain := routerVoiceTestDrain(&h, clients[:])
		defer RouterVoiceTestDrain_deinit(&drain)
		routerRoomAccessTestExpectError(&drain, 4, ROOM_ADMIN_REQUIRED_MESSAGE)
	}
	{
		routerTestSendSealed(
			&h,
			&clients[0].transport,
			1,
			.ClientAdminListRooms,
			common.ClientAdminListRoomsPayload{},
		)
		query := routerPollDatabaseQuery(&h)
		defer IPC__database_query_request_deinit(query.request)
		rooms := make([dynamic]common.AdminRoomSummary)
		append(
			&rooms,
			common.AdminRoomSummary {
				room = {
					id = 7,
					name = strings.clone("secret"),
					description = strings.clone(""),
					access = .AdminInvite,
					historyVisibility = .FromJoin,
				},
				memberCount = 1,
			},
		)
		MainRouterState_handleDatabaseResult(
			&h.pm,
			&h.state,
			query.request_id,
			common.DatabaseQueryResponse {
				success = true,
				result = common.DatabaseAdminRoomListResult{isAdmin = true, rooms = rooms},
			},
		)
		drain := routerVoiceTestDrain(&h, clients[:])
		defer RouterVoiceTestDrain_deinit(&drain)
		list := routerAdminTestDecode(&drain, 1, .ServerAdminRooms, common.ServerAdminRoomsPayload)
		defer common.ServerAdminRoomsPayload_deinit(&list)
		assert(
			len(list.rooms) == 1 &&
			list.rooms[0].room.name == "secret" &&
			list.rooms[0].room.access == .AdminInvite &&
			!list.rooms[0].isMember,
			fmt.tprintf("expected the secret room for alice, got %v", list),
		)
	}
}

// An admin who creates an Admin invite room without joining gets ServerCreateRoom with
// isMember false, and nobody is told to refresh a room list.
@(test)
testRoomAccessRouterCreateWithoutJoiningNotifiesNobody :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)
	clients := routerRoomAccessTestClients()
	routerVoiceTestConnect(&h, clients[:])
	defer routerVoiceTestDisconnectAll(clients[:])

	routerTestSendSealed(
		&h,
		&clients[0].transport,
		1,
		.ClientCreateRoom,
		common.ClientCreateRoomPayload {
			name = "ops",
			roomType = .Chat,
			access = .AdminInvite,
			historyVisibility = .Full,
			creatorJoins = false,
		},
	)
	adminQuery := routerPollDatabaseQuery(&h)
	defer IPC__database_query_request_deinit(adminQuery.request)
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		adminQuery.request_id,
		common.DatabaseQueryResponse {
			success = true,
			result = common.DatabaseUserServerAdminResult{isAdmin = true},
		},
	)
	createQuery := routerPollDatabaseQuery(&h)
	defer IPC__database_query_request_deinit(createQuery.request)
	create, createOK := createQuery.request.(common.DatabaseCreateRoomRequest)
	assert(
		createOK &&
		create.access == .AdminInvite &&
		create.historyVisibility == .Full &&
		!create.creatorJoins,
		fmt.tprintf("expected an Admin invite room without the creator, got %v", createQuery),
	)
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		createQuery.request_id,
		common.DatabaseQueryResponse {
			success = true,
			result = common.DatabaseRoomMutationResult {
				changed = true,
				room = {
					id = 12,
					name = strings.clone("ops"),
					description = strings.clone(""),
					roomType = .Chat,
					access = .AdminInvite,
					historyVisibility = .Full,
				},
			},
		},
	)
	drain := routerVoiceTestDrain(&h, clients[:])
	defer RouterVoiceTestDrain_deinit(&drain)
	created := routerAdminTestDecode(&drain, 1, .ServerCreateRoom, common.ServerRoomMutationPayload)
	defer delete(created.room.name)
	defer delete(created.room.description)
	assert(
		created.room.id == 12 && created.room.access == .AdminInvite && !created.isMember,
		fmt.tprintf("expected room 12 created without its creator, got %v", created),
	)
	assert(len(drain.packets) == 1, fmt.tprintf("expected only the answer, got %v", drain.packets))

	// The same room switched to Public adds every account: each session hears it joined.
	routerTestSendSealed(
		&h,
		&clients[0].transport,
		1,
		.ClientEditRoom,
		common.ClientEditRoomPayload{roomId = 12, name = "ops", roomType = .Chat, access = .Public},
	)
	checkQuery := routerPollDatabaseQuery(&h)
	defer IPC__database_query_request_deinit(checkQuery.request)
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		checkQuery.request_id,
		common.DatabaseQueryResponse {
			success = true,
			result = common.DatabaseUserServerAdminResult{isAdmin = true},
		},
	)
	editQuery := routerPollDatabaseQuery(&h)
	defer IPC__database_query_request_deinit(editQuery.request)
	edit, editOK := editQuery.request.(common.DatabaseEditRoomRequest)
	assert(editOK && edit.access == .Public, fmt.tprintf("expected a switch, got %v", editQuery))
	added := make([dynamic]int)
	append(&added, 42, 43, 44)
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		editQuery.request_id,
		common.DatabaseQueryResponse {
			success = true,
			result = common.DatabaseRoomMutationResult {
				changed = true,
				room = {
					id = 12,
					name = strings.clone("ops"),
					description = strings.clone(""),
					roomType = .Chat,
					access = .Public,
					historyVisibility = .Full,
				},
				addedUserIDs = added,
			},
		},
	)
	recipients := routerPollDatabaseQuery(&h)
	IPC__database_query_request_deinit(recipients.request)
	switchDrain := routerVoiceTestDrain(&h, clients[:])
	defer RouterVoiceTestDrain_deinit(&switchDrain)
	for client in clients {
		change := routerAdminTestDecode(
			&switchDrain,
			client.peerID,
			.ServerRoomMembershipChanged,
			common.ServerRoomMembershipChangedPayload,
		)
		assert(
			change.roomId == 12 && change.joined && change.userId == client.userID,
			fmt.tprintf("expected peer %d to join room 12, got %v", client.peerID, change),
		)
	}
}
