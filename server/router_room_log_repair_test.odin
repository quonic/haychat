package server

import "../common"
import "core:fmt"
import "core:sync"
import "core:testing"

// Router tests for member log repair (router_room_log_repair.odin, protocol 33, #196) with
// stubbed database results; the rules run in the database worker (database_room_log_test.odin).
// Peers: admin alice (1, user 42), two sessions of bob (2 and 3, user 43), and carol (4, user
// 44), as in router_room_access_test.odin.

@(private = "file")
routerRoomLogRepairTestIDs :: proc(ids: []int) -> [dynamic]int {
	list := make([dynamic]int)
	append(&list, ..ids)
	return list
}

@(private = "file")
routerRoomLogRepairTestSend :: proc(
	h: ^RouterTestHarness,
	client: ^RouterVoiceTestClient,
	messageType: common.MessageType,
	payload: any,
) -> (
	DatabaseQuery,
	common.DatabaseRoomLogRepairRequest,
) {
	routerTestSendSealed(h, &client.transport, client.peerID, messageType, payload)
	query := routerPollDatabaseQuery(h)
	request, ok := query.request.(common.DatabaseRoomLogRepairRequest)
	assert(ok, fmt.tprintf("expected one repair request, got %v", query))
	return query, request
}

// A status goes to the database with the server key and comes back only to the session that
// asked; malformed requests and refusals are protocol errors.
@(test)
testRoomLogRepairRouterStatusAndRefusals :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)
	clients := routerRoomAccessTestClients()
	routerVoiceTestConnect(&h, clients[:])
	defer routerVoiceTestDisconnectAll(clients[:])
	alicePeers := [?]RouterTestPeer{{1, &clients[0].transport}}

	routerTestSendSealed(
		&h,
		&clients[0].transport,
		1,
		.ClientAdminRoomLogStatus,
		common.ClientAdminRoomLogStatusPayload{roomId = -1},
	)
	routerTestExpectProtocolError(&h, alicePeers[:], ADMIN_INVALID_REQUEST_MESSAGE)
	routerTestSendSealed(
		&h,
		&clients[0].transport,
		1,
		.ClientAdminTruncateRoomLog,
		common.ClientAdminTruncateRoomLogPayload{roomId = 0, toVersion = 2},
	)
	routerTestExpectProtocolError(&h, alicePeers[:], ADMIN_INVALID_REQUEST_MESSAGE)
	routerTestExpectNoDatabaseQuery(&h, "expected malformed requests refused before the database")

	query, request := routerRoomLogRepairTestSend(
		&h,
		&clients[0],
		.ClientAdminRoomLogStatus,
		common.ClientAdminRoomLogStatusPayload{},
	)
	assert(
		request.action == .Status &&
		request.actorUserId == 42 &&
		request.roomId == 0 &&
		request.serverIdentityPublicKey == h.state.serverIdentityPublicKey,
		fmt.tprintf("expected alice's status of every room with the server key, got %v", request),
	)
	statuses := make([dynamic]common.RoomLogStatus)
	append(
		&statuses,
		common.RoomLogStatus {
			roomId = 9,
			storedVersion = 6,
			entryCount = 6,
			goodVersion = 4,
			failingVersion = 5,
			error = .BadSignature,
		},
	)
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		query.request_id,
		common.DatabaseQueryResponse {
			success = true,
			result = common.DatabaseRoomLogRepairResult {
				outcome = .Applied,
				statuses = statuses,
				checkedRooms = 3,
				damagedRooms = 1,
			},
		},
	)
	drain := routerVoiceTestDrain(&h, clients[:])
	defer RouterVoiceTestDrain_deinit(&drain)
	status := routerAdminTestDecode(
		&drain,
		1,
		.ServerAdminRoomLogStatus,
		common.ServerAdminRoomLogStatusPayload,
	)
	defer common.ServerAdminRoomLogStatusPayload_deinit(&status)
	assert(
		status.roomId == 0 &&
		status.checkedRooms == 3 &&
		status.damagedRooms == 1 &&
		len(status.rooms) == 1 &&
		status.rooms[0].goodVersion == 4 &&
		status.rooms[0].error == .BadSignature,
		fmt.tprintf("expected the damaged room's status, got %v", status),
	)
	for peerID in ([]u32{2, 3, 4}) {
		assert(
			routerAdminTestCount(&drain, peerID, .ServerAdminRoomLogStatus) == 0,
			fmt.tprintf("expected peer %d to get no status", peerID),
		)
	}

	// The statement refuses bob: the sentence says why.
	refusedQuery, _ := routerRoomLogRepairTestSend(
		&h,
		&clients[1],
		.ClientAdminTruncateRoomLog,
		common.ClientAdminTruncateRoomLogPayload{roomId = 9, toVersion = 4},
	)
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		refusedQuery.request_id,
		common.DatabaseQueryResponse {
			success = true,
			result = common.DatabaseRoomLogRepairResult{outcome = .NotAdmin},
		},
	)
	bobPeers := [?]RouterTestPeer{{2, &clients[1].transport}}
	routerTestExpectProtocolError(&h, bobPeers[:], "Admin permission required")
}

// An applied truncation: the requester's answer, the head going back to every member, manager
// and former member, the membership changes the rebuild made, the room's voice ended and its
// log version set back. A second truncation answered after the requester's peer ID went to a
// new session still fans out, but answers nobody.
@(test)
testRoomLogRepairRouterTruncationFansOut :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)
	clients := routerRoomAccessTestClients()
	routerVoiceTestConnect(&h, clients[:])
	defer routerVoiceTestDisconnectAll(clients[:])

	// carol is in room 9's voice at epoch 6.
	routerVoiceTestJoin(&h, &clients[3], 9, {43, 44})
	h.state.roomLogVersions[9] = 6
	setup := routerVoiceTestDrain(&h, clients[:])
	RouterVoiceTestDrain_deinit(&setup)

	query, request := routerRoomLogRepairTestSend(
		&h,
		&clients[0],
		.ClientAdminTruncateRoomLog,
		common.ClientAdminTruncateRoomLogPayload{roomId = 9, toVersion = 4},
	)
	assert(
		request.action == .Truncate &&
		request.actorUserId == 42 &&
		request.roomId == 9 &&
		request.toVersion == 4 &&
		request.serverIdentityPublicKey == h.state.serverIdentityPublicKey,
		fmt.tprintf("expected alice's truncation of room 9 to 4, got %v", request),
	)
	// Before: bob and carol members, carol manager. After (version 4): carol and account 50
	// members and managers; bob removed and 50 added.
	truncated := common.DatabaseRoomLogRepairResult {
		outcome = .Applied,
		status = {
			roomId = 9,
			storedVersion = 6,
			entryCount = 6,
			goodVersion = 4,
			failingVersion = 5,
			error = .BadSignature,
		},
		memberUserIDs = routerRoomLogRepairTestIDs({44, 50}),
		managerUserIDs = routerRoomLogRepairTestIDs({44, 50}),
		addedUserIDs = routerRoomLogRepairTestIDs({50}),
		removedUserIDs = routerRoomLogRepairTestIDs({43}),
		formerUserIDs = routerRoomLogRepairTestIDs({43, 44}),
		deletedEntries = 2,
	}
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		query.request_id,
		common.DatabaseQueryResponse{success = true, result = truncated},
	)
	routerTestExpectNoDatabaseQuery(&h, "expected the truncation to need one request")
	assert(
		h.state.roomLogVersions[9] == 4 && 9 not_in h.state.voiceRooms,
		"expected room 9's log version back at 4 and its voice ended",
	)

	drain := routerVoiceTestDrain(&h, clients[:])
	defer RouterVoiceTestDrain_deinit(&drain)
	answer := routerAdminTestDecode(
		&drain,
		1,
		.ServerAdminActionResult,
		common.ServerAdminActionResultPayload,
	)
	defer common.ServerAdminActionResultPayload_deinit(&answer)
	assert(
		answer.action == .TruncateRoomLog &&
		answer.roomId == 9 &&
		answer.message == ROOM_LOG_TRUNCATED_RESULT_MESSAGE,
		fmt.tprintf("expected alice's answer naming room 9, got %v", answer),
	)
	// alice (who asked), bob's two sessions (a former member) and carol get the new head.
	for peerID in ([]u32{1, 2, 3, 4}) {
		log := routerAdminTestDecode(&drain, peerID, .ServerRoomLog, common.ServerRoomLogPayload)
		defer common.ServerRoomLogPayload_deinit(&log)
		assert(
			log.roomId == 9 &&
			log.afterVersion == 4 &&
			log.headVersion == 4 &&
			len(log.entries) == 0 &&
			!log.hasMore,
			fmt.tprintf("expected peer %d to get the head at version 4, got %v", peerID, log),
		)
	}
	// bob hears he left; carol (a member after) hears both changes, the requester too.
	for peerID in ([]u32{2, 3}) {
		changed := routerAdminTestDecode(
			&drain,
			peerID,
			.ServerRoomMembershipChanged,
			common.ServerRoomMembershipChangedPayload,
		)
		assert(
			changed.roomId == 9 && changed.userId == 43 && !changed.joined &&
			routerAdminTestCount(&drain, peerID, .ServerRoomMembershipChanged) == 1,
			fmt.tprintf("expected bob's peer %d told only of his removal, got %v", peerID,
				changed),
		)
	}
	for peerID in ([]u32{1, 4}) {
		assert(
			routerAdminTestCount(&drain, peerID, .ServerRoomMembershipChanged) == 2,
			fmt.tprintf("expected peer %d told of both membership changes", peerID),
		)
	}
	roomID, reason, left := routerVoiceTestReason(&drain, 4, .ServerVoiceLeft)
	assert(
		left && roomID == 9 && reason == VOICE_LEFT_ROOM_LOG_REPAIRED,
		fmt.tprintf("expected carol out of room 9's voice, got %v %q", left, reason),
	)

	// The next truncation's answer arrives after alice's peer ID went to a new session.
	second, _ := routerRoomLogRepairTestSend(
		&h,
		&clients[0],
		.ClientAdminTruncateRoomLog,
		common.ClientAdminTruncateRoomLogPayload{roomId = 11, toVersion = 2},
	)
	session := h.state.peerSessions[1]
	session.sessionID[0] ~= 0xff
	h.state.peerSessions[1] = session
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		second.request_id,
		common.DatabaseQueryResponse {
			success = true,
			result = common.DatabaseRoomLogRepairResult {
				outcome = .Applied,
				status = {roomId = 11, storedVersion = 3, entryCount = 3, goodVersion = 2},
				memberUserIDs = routerRoomLogRepairTestIDs({44}),
				managerUserIDs = routerRoomLogRepairTestIDs({44}),
				formerUserIDs = routerRoomLogRepairTestIDs({44}),
			},
		},
	)
	later := routerVoiceTestDrain(&h, clients[:])
	defer RouterVoiceTestDrain_deinit(&later)
	assert(
		routerAdminTestCount(&later, 1, .ServerAdminActionResult) == 0 &&
		routerAdminTestCount(&later, 1, .ServerRoomLog) == 0 &&
		routerAdminTestCount(&later, 4, .ServerRoomLog) == 1,
		"expected the fan-out to carol only, with no answer to alice's peer's new session",
	)
}
