package server

import "../common"
import "core:fmt"
import "core:sync"
import "core:testing"

// Router and relay tests for room permissions and role rooms (protocol 24, #96): the requests
// queued, who hears what, the room lists resent after a change, and the speak flag the relay
// reads. The rules themselves run in SQL (database_room_permissions_test.odin). Admin alice is
// peer 1 and bob has two sessions, peers 2 and 3 (routerAdminTestClients).

// Pops the room list statements a resend queued and checks they are one per session of
// userID, for exactly peerIDs. The requests stay pending, like any unanswered one.
routerTestExpectRoomListResends :: proc(h: ^RouterTestHarness, userID: int, peerIDs: []u32) {
	got := make([dynamic]u32, context.temp_allocator)
	for {
		msg, err := IPC_Client_poll(h.databaseFd)
		if err != nil {
			break
		}
		query, isQuery := msg.(DatabaseQuery)
		assert(isQuery, fmt.tprintf("expected only database queries, got %v", msg))
		request, isList := query.request.(common.DatabaseRoomListRequest)
		assert(
			isList && request.userId == userID,
			fmt.tprintf("expected a room list for user %d, got %v", userID, query.request),
		)
		pending := h.state.pendingDatabaseRequests[query.request_id]
		assert(pending.requestType == .ListRooms, "expected the resend to answer as ListRooms")
		append(&got, pending.peerID)
		IPC__database_query_request_deinit(query.request)
	}
	assert(
		routerVoiceTestSamePeers(got[:], peerIDs),
		fmt.tprintf("expected room lists for peers %v, got %v", peerIDs, got[:]),
	)
}

// Answers a pending room list statement for peerID with one room and permissions.
@(private = "file")
routerRoomPermissionsTestAnswerList :: proc(
	h: ^RouterTestHarness,
	peerID: u32,
	roomID: int,
	permissions: common.RoomPermissions,
) {
	requestID: u64
	for id, pending in h.state.pendingDatabaseRequests {
		if pending.peerID == peerID && pending.requestType == .ListRooms {
			requestID = id
		}
	}
	assert(requestID != 0, fmt.tprintf("expected a pending room list for peer %d", peerID))
	rooms := make([dynamic]common.RoomSummary)
	append(
		&rooms,
		common.RoomSummary {
			id = roomID,
			name = fmt.aprintf("room-%d", roomID),
			description = fmt.aprintf(""),
			roomType = .ChatAndVoice,
			access = .Public,
			historyVisibility = .Full,
			myPermissions = permissions,
		},
	)
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		requestID,
		common.DatabaseQueryResponse {
			success = true,
			result = common.DatabaseRoomListResult{rooms = rooms},
		},
	)
}

@(private = "file")
routerRoomPermissionsTestMember :: proc(
	route: NetworkVoiceRoute,
	peerID: u32,
) -> (
	NetworkVoiceRouteMember,
	bool,
) {
	for member in route.members {
		if member.peerId == peerID {
			return member, true
		}
	}
	return {}, false
}

// A join without SpeakInVoice is accepted, and the route tells the relay to drop the session's
// frames; a room list that grants it again clears the flag, so live changes reach the relay.
@(test)
testMainRouterVoiceJoinWithoutSpeakIsHeardByNobody :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)
	clients := routerAdminTestClients()
	routerVoiceTestConnect(&h, clients[:])
	defer routerVoiceTestDisconnectAll(clients[:])
	members := []int{ROUTER_ADMIN_TEST_ADMIN, ROUTER_ADMIN_TEST_TARGET}

	// Alice may speak; bob's room grants him only SendMessages.
	routerVoiceTestSendJoin(&h, &clients[0], 5)
	routerRoomPermissionsTestAnswerMemberCheck(&h, 5, members, common.ROOM_PERMISSIONS_ALL)
	routerVoiceTestSendJoin(&h, &clients[1], 5)
	routerRoomPermissionsTestAnswerMemberCheck(&h, 5, members, {.SendMessages})
	drain := routerVoiceTestDrain(&h, clients[:])
	defer RouterVoiceTestDrain_deinit(&drain)
	route, routeOK := routerVoiceTestLastRoute(&drain, 5)
	assert(routeOK && routerVoiceTestRouteHas(route, 1, 2), "expected alice and bob routed")
	alice, _ := routerRoomPermissionsTestMember(route, 1)
	bob, _ := routerRoomPermissionsTestMember(route, 2)
	assert(
		!alice.speakDenied && bob.speakDenied && !bob.muted,
		fmt.tprintf("expected only bob's frames dropped, got %v", route.members),
	)
	assert(
		len(routerVoiceTestRecipients(&drain, .ServerVoiceJoinRejected)) == 0,
		"expected bob's join accepted",
	)

	// A grant change resends bob's room list; its SpeakInVoice reaches the relay.
	MainRouterState_resendRoomLists(&h.pm, &h.state, []int{ROUTER_ADMIN_TEST_TARGET})
	routerRoomPermissionsTestAnswerList(&h, 2, 5, common.ROOM_PERMISSIONS_DEFAULT)
	after := routerVoiceTestDrain(&h, clients[:])
	defer RouterVoiceTestDrain_deinit(&after)
	route, routeOK = routerVoiceTestLastRoute(&after, 5)
	assert(routeOK, "expected a new route once bob may speak")
	bob, _ = routerRoomPermissionsTestMember(route, 2)
	assert(!bob.speakDenied, fmt.tprintf("expected bob heard again, got %v", route.members))
	assert(
		len(routerVoiceTestRecipients(&after, .ServerListRooms)) == 1,
		"expected bob's session to get its room list",
	)

	// The same permissions again change nothing: no route is sent.
	MainRouterState_resendRoomLists(&h.pm, &h.state, []int{ROUTER_ADMIN_TEST_TARGET})
	routerRoomPermissionsTestAnswerList(&h, 2, 5, common.ROOM_PERMISSIONS_DEFAULT)
	routerRoomPermissionsTestAnswerList(&h, 3, 5, common.ROOM_PERMISSIONS_DEFAULT)
	same := routerVoiceTestDrain(&h, clients[:])
	defer RouterVoiceTestDrain_deinit(&same)
	assert(len(same.routes) == 0, "expected no route when the speak flag did not move")
}

// Answers a voice join's member check with the joiner's room permissions (protocol 24).
@(private = "file")
routerRoomPermissionsTestAnswerMemberCheck :: proc(
	h: ^RouterTestHarness,
	roomID: int,
	memberUserIDs: []int,
	permissions: common.RoomPermissions,
) {
	query := routerPollDatabaseQuery(h)
	defer IPC__database_query_request_deinit(query.request)
	memberRequest, ok := query.request.(common.DatabaseRoomMemberListRequest)
	assert(
		ok && memberRequest.roomId == roomID && memberRequest.userId > 0,
		fmt.tprintf("expected a member check naming the joiner, got %v", query.request),
	)
	userIDs := make([dynamic]int, 0, len(memberUserIDs))
	append(&userIDs, ..memberUserIDs)
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		query.request_id,
		common.DatabaseQueryResponse {
			success = true,
			result = common.DatabaseRoomMemberListResult {
				userIDs = userIDs,
				roomFound = true,
				roomType = .ChatAndVoice,
				permissions = permissions,
			},
		},
	)
}

// The relay drops the frames of a member whose route says speakDenied, counts them, and still
// sends that member everyone else's frames.
@(test)
testVoiceRelayDropsFramesOfAMemberWithoutSpeak :: proc(t: ^testing.T) {
	_ = t
	sink: VoiceRelayTestSink
	relay: VoiceRelay
	voiceRelayTestInit(&relay, &sink)
	defer voiceRelayTestDeinit(&relay, &sink)
	alice := voiceRelayTestOpenPeer(&relay, 1, 42)
	bob := voiceRelayTestOpenPeer(&relay, 2, 43)
	defer VoiceRelayTestClient_deinit(&alice)
	defer VoiceRelayTestClient_deinit(&bob)
	voiceRelayTestRoute(&relay, 7, {peerId = 1}, {peerId = 2, speakDenied = true})

	buffer: [common.VOICE_DATAGRAM_MAX_SIZE]u8
	send :: proc(
		relay: ^VoiceRelay,
		client: ^VoiceRelayTestClient,
		sequence: u32,
		buffer: []u8,
	) {
		datagram := voiceRelayTestSealFrame(
			client,
			7,
			sequence,
			0,
			VOICE_RELAY_TEST_OPUS[:],
			buffer,
		)
		VoiceRelay_handleDatagram(relay, client.peerId, datagram)
	}
	send(&relay, &bob, 1, buffer[:])
	assert(
		relay.stats.drops[.NoSpeakPermission] == 1 && len(sink.sent) == 0,
		fmt.tprintf("expected bob's frame dropped, got %v", relay.stats),
	)
	send(&relay, &alice, 1, buffer[:])
	assert(
		len(sink.sent) == 1 && sink.sent[0].peerId == 2,
		"expected alice's frame to reach bob, who still listens",
	)

	// A new route that lets bob speak forwards his frames again.
	voiceRelayTestRoute(&relay, 7, {peerId = 1}, {peerId = 2})
	send(&relay, &bob, 2, buffer[:])
	assert(
		relay.stats.drops[.NoSpeakPermission] == 1 &&
		len(sink.sent) == 2 &&
		sink.sent[1].peerId == 1,
		fmt.tprintf("expected bob heard once he may speak, got %v", relay.stats),
	)
}
