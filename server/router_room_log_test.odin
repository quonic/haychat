package server

import "../common"
import "core:encoding/cbor"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:testing"

// Router tests for encrypted rooms' member logs (router_room_log.odin, protocol 18) with
// stubbed database results; the rules run in the database worker (database_room_log_test.odin).
// Peers: admin alice (1, user 42), two sessions of bob (2 and 3, user 43), and carol (4, user
// 44), as in router_room_access_test.odin.

@(private = "file")
routerRoomLogTestAppend :: proc(
	h: ^RouterTestHarness,
	client: ^RouterVoiceTestClient,
	roomID: int,
	entry: []u8,
) -> (
	DatabaseQuery,
	common.DatabaseAppendRoomLogRequest,
) {
	routerTestSendSealed(
		h,
		&client.transport,
		client.peerID,
		.ClientAppendRoomLog,
		common.ClientAppendRoomLogPayload{roomId = roomID, entry = entry},
	)
	query := routerPollDatabaseQuery(h)
	request, ok := query.request.(common.DatabaseAppendRoomLogRequest)
	assert(ok, fmt.tprintf("expected an append to queue one request, got %v", query))
	return query, request
}

@(private = "file")
routerRoomLogTestIDs :: proc(ids: []int) -> [dynamic]int {
	list := make([dynamic]int)
	append(&list, ..ids)
	return list
}

@(private = "file")
routerRoomLogTestEntry :: proc(fill: u8) -> []u8 {
	entry := make([]u8, 210)
	for index in 0 ..< len(entry) {
		entry[index] = fill + u8(index)
	}
	return entry
}

@(test)
testRoomLogRouterAppendFansOutToMembersManagersAndTarget :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)
	clients := routerRoomAccessTestClients()
	routerVoiceTestConnect(&h, clients[:])
	defer routerVoiceTestDisconnectAll(clients[:])

	// bob signs the addition of carol to encrypted room 9, whose manager alice is not a member.
	entry := routerRoomLogTestEntry(3)
	defer delete(entry)
	query, request := routerRoomLogTestAppend(&h, &clients[1], 9, entry)
	defer IPC__database_query_request_deinit(query.request)
	assert(
		request.actorUserId == 43 &&
		request.roomId == 9 &&
		string(request.entry) == string(entry) &&
		request.serverIdentityPublicKey == h.state.serverIdentityPublicKey,
		fmt.tprintf("expected bob's entry for room 9 with the server key, got %v", request),
	)
	stored := make([]u8, len(entry))
	copy(stored, entry)
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		query.request_id,
		common.DatabaseQueryResponse {
			success = true,
			result = common.DatabaseAppendRoomLogResult {
				outcome = .Applied,
				entry = stored,
				version = 4,
				action = .Add,
				targetUserId = 44,
				membershipChanged = true,
				memberUserIDs = routerRoomLogTestIDs({43, 44}),
				managerUserIDs = routerRoomLogTestIDs({42}),
				access = .MemberInvite,
			},
		},
	)
	routerTestExpectNoDatabaseQuery(&h, "expected the append to need one request")

	drain := routerVoiceTestDrain(&h, clients[:])
	defer RouterVoiceTestDrain_deinit(&drain)
	// Every session of the members (bob twice, carol) and of the manager (alice) gets it.
	for peerID in ([]u32{1, 2, 3, 4}) {
		log := routerAdminTestDecode(&drain, peerID, .ServerRoomLog, common.ServerRoomLogPayload)
		defer common.ServerRoomLogPayload_deinit(&log)
		assert(
			log.roomId == 9 &&
			log.afterVersion == 3 &&
			log.headVersion == 4 &&
			len(log.entries) == 1 &&
			string(log.entries[0]) == string(entry),
			fmt.tprintf("expected peer %d to get the entry at version 4, got %v", peerID, log),
		)
	}
	// Members after the change and the requester hear that carol joined; alice, a manager who
	// is not a member, learns it from the log only.
	for peerID in ([]u32{2, 3, 4}) {
		change := routerAdminTestDecode(
			&drain,
			peerID,
			.ServerRoomMembershipChanged,
			common.ServerRoomMembershipChangedPayload,
		)
		assert(
			change.roomId == 9 && change.joined && change.userId == 44,
			fmt.tprintf("expected peer %d to hear carol joined 9, got %v", peerID, change),
		)
	}
	assert(
		routerAdminTestCount(&drain, 1, .ServerRoomMembershipChanged) == 0,
		"expected no membership change for alice",
	)
}

@(test)
testRoomLogRouterRefusalsAndFetch :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)
	clients := routerRoomAccessTestClients()
	routerVoiceTestConnect(&h, clients[:])
	defer routerVoiceTestDisconnectAll(clients[:])

	// An empty entry never reaches the database.
	routerTestSendSealed(
		&h,
		&clients[3].transport,
		4,
		.ClientAppendRoomLog,
		common.ClientAppendRoomLogPayload{roomId = 9},
	)
	routerTestExpectNoDatabaseQuery(&h, "expected an empty entry refused in the router")
	{
		drain := routerVoiceTestDrain(&h, clients[:])
		defer RouterVoiceTestDrain_deinit(&drain)
		routerRoomAccessTestExpectError(&drain, 4, common.ROOM_LOG_INVALID_MESSAGE)
	}

	refusals := []struct {
		outcome:  common.RoomLogAppendOutcome,
		logError: common.RoomLogError,
		message:  string,
	} {
		{.NotMember, .None, ROOM_NOT_MEMBER_MESSAGE},
		{.NotEncrypted, .None, common.ROOM_LOG_NOT_ENCRYPTED_MESSAGE},
		{.Conflict, .VersionNotNext, common.ROOM_LOG_CONFLICT_MESSAGE},
		{.NotAuthorized, .NotAuthorized, common.ROOM_LOG_NOT_AUTHORIZED_MESSAGE},
		{.RoomFull, .RoomFull, common.ENCRYPTED_ROOM_FULL_MESSAGE},
		{.Damaged, .None, common.ROOM_LOG_DAMAGED_MESSAGE},
		{.Invalid, .BadSignature, "Invalid member list entry (BadSignature)"},
	}
	entry := routerRoomLogTestEntry(9)
	defer delete(entry)
	for refusal in refusals {
		query, _ := routerRoomLogTestAppend(&h, &clients[3], 9, entry)
		defer IPC__database_query_request_deinit(query.request)
		MainRouterState_handleDatabaseResult(
			&h.pm,
			&h.state,
			query.request_id,
			common.DatabaseQueryResponse {
				success = true,
				result = common.DatabaseAppendRoomLogResult {
					outcome = refusal.outcome,
					logError = refusal.logError,
				},
			},
		)
		drain := routerVoiceTestDrain(&h, clients[:])
		defer RouterVoiceTestDrain_deinit(&drain)
		routerRoomAccessTestExpectError(&drain, 4, refusal.message)
		assert(
			routerAdminTestCount(&drain, 2, .ServerRoomLog) == 0,
			"expected nothing for anyone else",
		)
	}

	// A fetch answers the requester only, after the version it asked for.
	routerTestSendSealed(
		&h,
		&clients[1].transport,
		2,
		.ClientFetchRoomLog,
		common.ClientFetchRoomLogPayload{roomId = 9, afterVersion = 2},
	)
	query := routerPollDatabaseQuery(&h)
	defer IPC__database_query_request_deinit(query.request)
	fetch, fetchOK := query.request.(common.DatabaseFetchRoomLogRequest)
	assert(
		fetchOK && fetch.actorUserId == 43 && fetch.roomId == 9 && fetch.afterVersion == 2,
		fmt.tprintf("expected bob's fetch after version 2, got %v", query),
	)
	entries := make([dynamic][]u8)
	first := make([]u8, len(entry))
	copy(first, entry)
	append(&entries, first)
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		query.request_id,
		common.DatabaseQueryResponse {
			success = true,
			result = common.DatabaseFetchRoomLogResult {
				outcome = .Applied,
				entries = entries,
				headVersion = 3,
			},
		},
	)
	drain := routerVoiceTestDrain(&h, clients[:])
	defer RouterVoiceTestDrain_deinit(&drain)
	log := routerAdminTestDecode(&drain, 2, .ServerRoomLog, common.ServerRoomLogPayload)
	defer common.ServerRoomLogPayload_deinit(&log)
	assert(
		log.roomId == 9 && log.afterVersion == 2 && log.headVersion == 3 && len(log.entries) == 1,
		fmt.tprintf("expected the page after version 2, got %v", log),
	)
	assert(
		routerAdminTestCount(&drain, 3, .ServerRoomLog) == 0,
		"expected the answer only for the session that asked",
	)
}

@(test)
testRoomLogRouterServerRemovalSendsTheEntry :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)
	clients := routerRoomAccessTestClients()
	routerVoiceTestConnect(&h, clients[:])
	defer routerVoiceTestDisconnectAll(clients[:])

	// alice (admin) removes bob from encrypted room 9, whose only other member is carol and
	// whose manager is carol.
	query, request := routerRoomAccessTestSend(
		&h,
		&clients[0],
		.ClientRemoveRoomMember,
		common.ClientRoomMembershipPayload{roomId = 9, userId = 43},
	)
	defer IPC__database_query_request_deinit(query.request)
	assert(
		request.serverIdentityPublicKey == h.state.serverIdentityPublicKey,
		"expected the removal to carry the server key for the log replay",
	)
	entry := routerRoomLogTestEntry(5)
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		query.request_id,
		common.DatabaseQueryResponse {
			success = true,
			result = common.DatabaseRoomMemberActionResult {
				outcome = .Applied,
				changed = true,
				access = .AdminInvite,
				memberUserIDs = routerRoomLogTestIDs({44}),
				logEntry = entry,
				logVersion = 6,
				managerUserIDs = routerRoomLogTestIDs({44}),
			},
		},
	)
	drain := routerVoiceTestDrain(&h, clients[:])
	defer RouterVoiceTestDrain_deinit(&drain)
	removed := routerAdminTestDecode(
		&drain,
		1,
		.ServerRoomMemberRemoved,
		common.ServerRoomMutationPayload,
	)
	defer delete(removed.room.name)
	defer delete(removed.room.description)
	assert(removed.changed && removed.userId == 43, "expected alice told bob was removed")
	// alice (who asked), bob (removed, both sessions) and carol (member and manager).
	for peerID in ([]u32{1, 2, 3, 4}) {
		log := routerAdminTestDecode(&drain, peerID, .ServerRoomLog, common.ServerRoomLogPayload)
		defer common.ServerRoomLogPayload_deinit(&log)
		assert(
			log.headVersion == 6 && log.afterVersion == 5 && len(log.entries) == 1,
			fmt.tprintf("expected peer %d to get the server's Remove, got %v", peerID, log),
		)
	}
}

@(test)
testRoomLogRouterRefusesPlaintextInEncryptedRooms :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)
	clients := routerRoomAccessTestClients()
	routerVoiceTestConnect(&h, clients[:])
	defer routerVoiceTestDisconnectAll(clients[:])

	// An encrypted Public room is refused before the admin check.
	routerTestSendSealed(
		&h,
		&clients[0].transport,
		1,
		.ClientCreateRoom,
		common.ClientCreateRoomPayload {
			name = "open-secret",
			roomType = .Chat,
			access = .Public,
			historyVisibility = .Full,
			creatorJoins = true,
			encrypted = true,
		},
	)
	routerTestExpectNoDatabaseQuery(&h, "expected an encrypted Public room refused at once")
	{
		drain := routerVoiceTestDrain(&h, clients[:])
		defer RouterVoiceTestDrain_deinit(&drain)
		routerRoomAccessTestExpectError(&drain, 1, common.ENCRYPTED_ROOM_PUBLIC_MESSAGE)
	}

	// The database's verdict on a chat message in an encrypted room becomes the sentence.
	routerTestSendSealed(
		&h,
		&clients[1].transport,
		2,
		.ClientChatMessage,
		routerTestSignedChat(&h, clients[1].identityKey, 9, clients[1].userID, "hello"),
	)
	query := routerPollDatabaseQuery(&h)
	defer IPC__database_query_request_deinit(query.request)
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		query.request_id,
		common.DatabaseQueryResponse {
			success = true,
			result = common.DatabasePostRoomChatMessageResult {
				isMember = true,
				encryptedRoom = true,
			},
		},
	)
	{
		drain := routerVoiceTestDrain(&h, clients[:])
		defer RouterVoiceTestDrain_deinit(&drain)
		routerRoomAccessTestExpectError(&drain, 2, common.ENCRYPTED_ROOM_CHAT_MESSAGE)
		assert(
			routerAdminTestCount(&drain, 4, .ServerChatMessage) == 0,
			"expected no chat message fanned out",
		)
	}

	// A protocol 15 add to an encrypted room names the member log.
	addQuery, _ := routerRoomAccessTestSend(
		&h,
		&clients[0],
		.ClientAddRoomMember,
		common.ClientRoomMembershipPayload{roomId = 9, userId = 44},
	)
	defer IPC__database_query_request_deinit(addQuery.request)
	routerRoomAccessTestAnswer(&h, addQuery, .EncryptedRoom)
	drain := routerVoiceTestDrain(&h, clients[:])
	defer RouterVoiceTestDrain_deinit(&drain)
	routerRoomAccessTestExpectError(&drain, 1, common.ROOM_LOG_REQUIRED_MESSAGE)
}

// Protocol 32 (#72): a ban that removed bob from encrypted room 9 sends the server's Remove and
// the membership change as an admin's removal does, after bob's sessions ended, and names the
// room it could not change (12) in the admin's result.
@(test)
testRoomLogRouterBanSendsRemovalsAndFailedRooms :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)
	clients := routerRoomAccessTestClients()
	routerVoiceTestConnect(&h, clients[:])
	defer routerVoiceTestDisconnectAll(clients[:])

	query, request := routerAdminTestSend(
		&h,
		&clients[0],
		.ClientAdminBanUser,
		common.ClientAdminBanUserPayload{userId = 43, banned = true, reason = "spam"},
	)
	defer IPC__database_query_request_deinit(query.request)
	assert(
		request.serverIdentityPublicKey == h.state.serverIdentityPublicKey,
		"expected the ban to carry the server key for the log replays",
	)
	removals := make([dynamic]common.DatabaseBanRoomRemoval)
	append(
		&removals,
		common.DatabaseBanRoomRemoval {
			roomId = 9,
			logEntry = routerRoomLogTestEntry(7),
			logVersion = 6,
			memberUserIDs = routerRoomLogTestIDs({44}),
			managerUserIDs = routerRoomLogTestIDs({44}),
		},
	)
	result := common.DatabaseAdminUserResult {
		outcome       = .Applied,
		changed       = true,
		user          = {id = 43, nickname = "voice-user-43", isBanned = true},
		banRemovals   = removals,
		failedRoomIDs = routerRoomLogTestIDs({12}),
	}
	result.user.nickname = strings.clone("voice-user-43")
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		query.request_id,
		common.DatabaseQueryResponse{success = true, result = result},
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
	expected :=
		"Banned voice-user-43; removed from 1 encrypted room; " +
		"1 encrypted room could not be changed"
	assert(
		answer.action == .Ban &&
		answer.userId == 43 &&
		answer.message == expected &&
		len(answer.failedRoomIds) == 1 &&
		answer.failedRoomIds[0] == 12,
		fmt.tprintf("expected the ban's result to name room 12, got %v", answer),
	)
	// alice (who asked) and carol (the remaining member and manager) get the Remove and the
	// membership change; bob's sessions ended before it and get neither.
	for peerID in ([]u32{1, 4}) {
		log := routerAdminTestDecode(&drain, peerID, .ServerRoomLog, common.ServerRoomLogPayload)
		defer common.ServerRoomLogPayload_deinit(&log)
		assert(
			log.roomId == 9 &&
			log.headVersion == 6 &&
			log.afterVersion == 5 &&
			len(log.entries) == 1 &&
			log.entries[0][0] == 7,
			fmt.tprintf("expected peer %d to get the server's Remove, got %v", peerID, log),
		)
		changed := routerAdminTestDecode(
			&drain,
			peerID,
			.ServerRoomMembershipChanged,
			common.ServerRoomMembershipChangedPayload,
		)
		assert(
			changed.roomId == 9 && changed.userId == 43 && !changed.joined,
			fmt.tprintf("expected peer %d told bob left room 9, got %v", peerID, changed),
		)
	}
	for peerID in ([]u32{2, 3}) {
		assert(
			routerAdminTestCount(&drain, peerID, .ServerSessionEnded) == 1 &&
			routerAdminTestCount(&drain, peerID, .ServerRoomLog) == 0 &&
			routerAdminTestCount(&drain, peerID, .ServerRoomMembershipChanged) == 0,
			fmt.tprintf("expected bob's peer %d to get only its session's end", peerID),
		)
	}
}

// Protocol 33 (#195): a ban that removed bob from room 9's members and managers (its only
// manager: none is left) and from room 10's managers (he was no member) sends room 9's Remove
// and RemoveManager in one ServerRoomLog with the membership change, and room 10's
// RemoveManager alone without one, and the admin's result counts the manager sets.
@(test)
testRoomLogRouterBanSendsManagerRemovals :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)
	clients := routerRoomAccessTestClients()
	routerVoiceTestConnect(&h, clients[:])
	defer routerVoiceTestDisconnectAll(clients[:])

	query, _ := routerAdminTestSend(
		&h,
		&clients[0],
		.ClientAdminBanUser,
		common.ClientAdminBanUserPayload{userId = 43, banned = true, reason = "spam"},
	)
	defer IPC__database_query_request_deinit(query.request)
	removals := make([dynamic]common.DatabaseBanRoomRemoval)
	append(
		&removals,
		common.DatabaseBanRoomRemoval {
			roomId = 9,
			logEntry = routerRoomLogTestEntry(7),
			logVersion = 6,
			managerLogEntry = routerRoomLogTestEntry(8),
			managerLogVersion = 7,
			memberUserIDs = routerRoomLogTestIDs({44}),
			managerUserIDs = routerRoomLogTestIDs({}),
		},
		common.DatabaseBanRoomRemoval {
			roomId = 10,
			managerLogEntry = routerRoomLogTestEntry(9),
			managerLogVersion = 3,
			memberUserIDs = routerRoomLogTestIDs({44}),
			managerUserIDs = routerRoomLogTestIDs({42}),
		},
	)
	result := common.DatabaseAdminUserResult {
		outcome     = .Applied,
		changed     = true,
		user        = {id = 43, isBanned = true},
		banRemovals = removals,
	}
	result.user.nickname = strings.clone("voice-user-43")
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		query.request_id,
		common.DatabaseQueryResponse{success = true, result = result},
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
	expected :=
		"Banned voice-user-43; removed from 1 encrypted room; " +
		"no longer a manager of 2 encrypted rooms (1 now with no manager)"
	assert(
		answer.action == .Ban && answer.message == expected && len(answer.failedRoomIds) == 0,
		fmt.tprintf("expected the ban's result to count the manager sets, got %v", answer),
	)

	// alice (who asked, and room 10's manager) and carol (a member of both) get both rooms'
	// entries; bob's sessions ended before them.
	for peerID in ([]u32{1, 4}) {
		room9, room10 := 0, 0
		for entry in drain.packets {
			if entry.peerID != peerID || entry.packet.messageType != .ServerRoomLog {
				continue
			}
			log: common.ServerRoomLogPayload
			assert(cbor.unmarshal(entry.packet.payload, &log) == nil, "expected a room log")
			defer common.ServerRoomLogPayload_deinit(&log)
			switch log.roomId {
			case 9:
				room9 += 1
				assert(
					log.afterVersion == 5 &&
					log.headVersion == 7 &&
					len(log.entries) == 2 &&
					log.entries[0][0] == 7 &&
					log.entries[1][0] == 8,
					fmt.tprintf("expected room 9's Remove and RemoveManager, got %v", log),
				)
			case 10:
				room10 += 1
				assert(
					log.afterVersion == 2 &&
					log.headVersion == 3 &&
					len(log.entries) == 1 &&
					log.entries[0][0] == 9,
					fmt.tprintf("expected room 10's RemoveManager, got %v", log),
				)
			case:
				assert(false, fmt.tprintf("expected no other room's log, got %v", log))
			}
		}
		assert(
			room9 == 1 && room10 == 1,
			fmt.tprintf("expected peer %d to get one log per room, got %d %d", peerID, room9,
				room10),
		)
		changed := routerAdminTestDecode(
			&drain,
			peerID,
			.ServerRoomMembershipChanged,
			common.ServerRoomMembershipChangedPayload,
		)
		assert(
			changed.roomId == 9 && changed.userId == 43 && !changed.joined &&
			routerAdminTestCount(&drain, peerID, .ServerRoomMembershipChanged) == 1,
			fmt.tprintf("expected peer %d told only that bob left room 9, got %v", peerID, changed),
		)
	}
	for peerID in ([]u32{2, 3}) {
		assert(
			routerAdminTestCount(&drain, peerID, .ServerRoomLog) == 0,
			fmt.tprintf("expected bob's peer %d to get no room log", peerID),
		)
	}
}
