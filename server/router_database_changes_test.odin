package server

import "../common"
import "core:encoding/cbor"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:testing"

// Database change notifications in the router (#116, router_database_changes.odin): a
// restriction changed in the database reaches the sessions like an admin's, exactly once, and
// a resync after the listener connected reads only what differs. The database is stubbed; the
// listener and the trigger run against PostgreSQL in database_notifications_test.odin.

// One network message a session was sent, opened with its transport. payload is owned.
RouterChangeTestMessage :: struct {
	peerID:      u32,
	messageType: common.MessageType,
	payload:     []u8,
}

RouterChangeTestMessages_deinit :: proc(messages: ^[dynamic]RouterChangeTestMessage) {
	for message in messages {
		delete(message.payload)
	}
	delete(messages^)
}

// Opens every queued network message with its peer's transport, in order.
routerChangeTestCollect :: proc(
	h: ^RouterTestHarness,
	peers: []RouterTestPeer,
) -> [dynamic]RouterChangeTestMessage {
	messages := make([dynamic]RouterChangeTestMessage)
	for {
		msg, err := IPC_Client_poll(h.networkFd)
		if err != nil {
			return messages
		}
		if send, isSend := msg.(NetworkSendData); isSend {
			outer := routerDecodePacketBytes(send.data)
			for peer in peers {
				if peer.peerID == send.peerId {
					inner, openOK := common.openPacketForSession(peer.transport, outer)
					assert(openOK, fmt.tprintf("expected peer %d to open its message", peer.peerID))
					append(
						&messages,
						RouterChangeTestMessage {
							peerID = peer.peerID,
							messageType = inner.messageType,
							payload = inner.payload,
						},
					)
				}
			}
			delete(outer.payload)
		}
		IPC__message_deinit(&msg)
	}
}

// How many of messages went to peerID with messageType.
routerChangeTestCount :: proc(
	messages: []RouterChangeTestMessage,
	peerID: u32,
	messageType: common.MessageType,
) -> int {
	count := 0
	for message in messages {
		if message.peerID == peerID && message.messageType == messageType {
			count += 1
		}
	}
	return count
}

// Every queued database query, each dropped with its pending request; returns how many there
// were of each kind of interest.
RouterChangeTestQueries :: struct {
	total:     int,
	listUsers: int,
	shared:    int,
}

routerChangeTestDropQueries :: proc(h: ^RouterTestHarness) -> RouterChangeTestQueries {
	counts: RouterChangeTestQueries
	for {
		msg, err := IPC_Client_poll(h.databaseFd)
		if err != nil {
			return counts
		}
		if query, isQuery := msg.(DatabaseQuery); isQuery {
			counts.total += 1
			#partial switch _ in query.request {
			case common.DatabaseUserDirectoryRequest:
				counts.listUsers += 1
			case common.DatabaseSharedRoomsRequest:
				counts.shared += 1
			}
			if pending, found := h.state.pendingDatabaseRequests[query.request_id]; found {
				PendingDBRequest_deinit(pending)
				delete_key(&h.state.pendingDatabaseRequests, query.request_id)
			}
		}
		IPC__message_deinit(&msg)
	}
}

// The account a SetRestricted statement or DATABASE_RESTRICTED_CHANGES_SQL reports. Owned.
routerChangeTestAccount :: proc(
	userID: int,
	nickname: string,
	restricted: bool,
	addedRoomIDs: []int = nil,
) -> common.DatabaseAdminUserResult {
	return common.DatabaseAdminUserResult {
		outcome = .Applied,
		changed = true,
		user = {id = userID, nickname = strings.clone(nickname), isRestricted = restricted},
		previousNickname = strings.clone(nickname),
		addedRoomIDs = slice.clone_to_dynamic(addedRoomIDs),
	}
}

// Signs in admin (peer 1, account 1, every permission), bob (peer 2, account 2) and erin
// (peer 3, account 5), and drops what their sign-ins sent and asked.
@(private = "file")
routerChangeTestSignIn :: proc(h: ^RouterTestHarness, transports: ^[3]common.TransportState) {
	accounts := [3]struct {
		peerID:   u32,
		userID:   int,
		nickname: string,
		isAdmin:  bool,
	}{{1, 1, "admin", true}, {2, 2, "bob", false}, {3, 5, "erin", false}}
	peers: [3]RouterTestPeer
	for account, index in accounts {
		peers[index] = RouterTestPeer {
			peerID    = account.peerID,
			transport = &transports[index],
		}
	}
	for account, index in accounts {
		if account.peerID != 1 {
			h.state.connectedPeers[account.peerID] = true
			MainRouterState_setPeerSession(&h.state, account.peerID, RouterPeerSession_init())
		}
		transports[index] = routerCompleteHandshake(
			h,
			account.peerID,
			userID = account.userID,
			nickname = account.nickname,
			isAdmin = account.isAdmin,
		)
		collected := routerChangeTestCollect(h, peers[:index + 1])
		RouterChangeTestMessages_deinit(&collected)
		routerChangeTestDropQueries(h)
	}
	if session, ok := &h.state.peerSessions[1]; ok {
		session.permissions = common.serverPermissionsFromMask(-1)
	}
	h.state.restrictedUsersLoaded = true
}

// Hands the router a notification for ids on the Restricted channel, as the main loop does,
// and returns the read it asked for.
@(private = "file")
routerChangeTestNotify :: proc(
	h: ^RouterTestHarness,
	ids: []int,
) -> (
	DatabaseQuery,
	common.DatabaseRestrictedChangesRequest,
) {
	running := mainLoopHandleMessage(
		&h.pm,
		&h.state,
		DatabaseChangeNotification{channel = .Restricted, ids = slice.clone_to_dynamic(ids)},
	)
	assert(running, "expected the main loop to keep running")
	query := routerPollDatabaseQuery(h)
	request, requestOK := query.request.(common.DatabaseRestrictedChangesRequest)
	assert(requestOK, fmt.tprintf("expected the accounts read again, got %v", query.request))
	return query, request
}

@(private = "file")
routerChangeTestAnswer :: proc(
	h: ^RouterTestHarness,
	query: DatabaseQuery,
	accounts: []common.DatabaseAdminUserResult,
) {
	result := common.DatabaseRestrictedChangesResult {
		accounts = slice.clone_to_dynamic(accounts),
	}
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		query.request_id,
		common.DatabaseQueryResponse{success = true, result = result},
	)
}

@(test)
testRestrictionChangedInTheDatabaseReachesSessionsOnce :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)
	transports: [3]common.TransportState
	defer for &transport in transports {
		common.TransportState_deinit(&transport)
	}
	routerChangeTestSignIn(&h, &transports)
	peers := [3]RouterTestPeer {
		{peerID = 1, transport = &transports[0]},
		{peerID = 2, transport = &transports[1]},
		{peerID = 3, transport = &transports[2]},
	}

	// An operator restricts erin with SQL.
	query, request := routerChangeTestNotify(&h, []int{5})
	assert(
		slice.equal(request.userIds[:], []int{5}) && len(request.restrictedUserIds) == 0,
		fmt.tprintf("expected erin read again as unrestricted so far, got %v", request),
	)
	IPC__database_query_request_deinit(query.request)
	routerChangeTestAnswer(&h, query, {routerChangeTestAccount(5, "erin", true)})
	assert(MainRouterState_userIsRestricted(&h.state, 5), "expected erin in the router's set")

	messages := routerChangeTestCollect(&h, peers[:])
	defer RouterChangeTestMessages_deinit(&messages)
	accountUpdates := routerChangeTestCount(messages[:], 3, .ServerAccountUpdated)
	assert(
		accountUpdates == 1,
		fmt.tprintf("expected erin's session told once, got %d: %v", accountUpdates, messages),
	)
	for message in messages {
		if message.peerID == 3 && message.messageType == .ServerAccountUpdated {
			updated: common.ServerAccountUpdatedPayload
			assert(cbor.unmarshal(message.payload, &updated) == nil, "expected its payload")
			defer delete(updated.nickname)
			assert(updated.isRestricted, "expected erin told she is restricted")
		}
		if message.peerID == 1 && message.messageType == .ServerUserUpdated {
			updated: common.ServerUserUpdatedPayload
			assert(cbor.unmarshal(message.payload, &updated) == nil, "expected its payload")
			defer common.UserSummary_deinit(&updated.user)
			assert(
				updated.user.id == 5 && updated.user.isRestricted,
				fmt.tprintf("expected the admin told erin is restricted, got %v", updated.user),
			)
		}
	}
	assert(
		routerChangeTestCount(messages[:], 1, .ServerUserUpdated) == 1 &&
		routerChangeTestCount(messages[:], 2, .ServerUserUpdated) == 0,
		"expected the approver told at once and bob only once the database says he may see her",
	)
	queries := routerChangeTestDropQueries(&h)
	assert(
		queries.shared == 1 && queries.listUsers == 3,
		fmt.tprintf("expected bob's visibility checked and every list resent, got %v", queries),
	)

	// The same change reported again (a resync, or a second notification) sends nothing.
	again, againRequest := routerChangeTestNotify(&h, []int{5})
	assert(
		slice.equal(againRequest.restrictedUserIds[:], []int{5}),
		fmt.tprintf("expected erin named as restricted now, got %v", againRequest),
	)
	IPC__database_query_request_deinit(again.request)
	routerChangeTestAnswer(&h, again, {routerChangeTestAccount(5, "erin", true)})
	routerTestExpectNoNetworkMessage(&h, "a change applied twice")
	routerTestExpectNoDatabaseQuery(&h, "user lists resent for a change applied before")
}

// The router's own ClientAdminSetRestricted fires the trigger too: its notification arrives
// after the action's answer and finds nothing left to do.
@(test)
testAdminRestrictionFansOutOnceWithItsNotification :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)
	transports: [3]common.TransportState
	defer for &transport in transports {
		common.TransportState_deinit(&transport)
	}
	routerChangeTestSignIn(&h, &transports)
	peers := [3]RouterTestPeer {
		{peerID = 1, transport = &transports[0]},
		{peerID = 2, transport = &transports[1]},
		{peerID = 3, transport = &transports[2]},
	}

	routerTestSendSealed(
		&h,
		&transports[0],
		1,
		.ClientAdminSetRestricted,
		common.ClientAdminSetRestrictedPayload{userId = 5, restricted = true},
	)
	action := routerPollDatabaseQuery(&h)
	IPC__database_query_request_deinit(action.request)
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		action.request_id,
		common.DatabaseQueryResponse {
			success = true,
			result = routerChangeTestAccount(5, "erin", true),
		},
	)
	messages := routerChangeTestCollect(&h, peers[:])
	defer RouterChangeTestMessages_deinit(&messages)
	assert(
		routerChangeTestCount(messages[:], 1, .ServerAdminActionResult) == 1 &&
		routerChangeTestCount(messages[:], 3, .ServerAccountUpdated) == 1 &&
		routerChangeTestCount(messages[:], 1, .ServerUserUpdated) == 1,
		fmt.tprintf("expected the admin answered and erin told once, got %v", messages),
	)
	queries := routerChangeTestDropQueries(&h)
	assert(queries.listUsers == 3, fmt.tprintf("expected every list resent, got %v", queries))

	query, request := routerChangeTestNotify(&h, []int{5})
	assert(
		slice.equal(request.restrictedUserIds[:], []int{5}),
		fmt.tprintf("expected erin named as restricted already, got %v", request),
	)
	IPC__database_query_request_deinit(query.request)
	routerChangeTestAnswer(&h, query, {routerChangeTestAccount(5, "erin", true)})
	routerTestExpectNoNetworkMessage(&h, "the admin's change fanned out twice")
	routerTestExpectNoDatabaseQuery(&h, "user lists resent twice for one change")
}

// Lifting in the database: the Public rooms the statement joined reach the account and the
// rooms' members, and the router's set drops it.
@(test)
testRestrictionLiftedInTheDatabaseJoinsPublicRooms :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)
	transports: [3]common.TransportState
	defer for &transport in transports {
		common.TransportState_deinit(&transport)
	}
	routerChangeTestSignIn(&h, &transports)
	peers := [3]RouterTestPeer {
		{peerID = 1, transport = &transports[0]},
		{peerID = 2, transport = &transports[1]},
		{peerID = 3, transport = &transports[2]},
	}
	MainRouterState_setUserRestricted(&h.state, 5, true)

	query, request := routerChangeTestNotify(&h, []int{5})
	assert(
		slice.equal(request.restrictedUserIds[:], []int{5}),
		"expected erin named as restricted, so the statement may join her to Public rooms",
	)
	IPC__database_query_request_deinit(query.request)
	routerChangeTestAnswer(&h, query, {routerChangeTestAccount(5, "erin", false, {1})})
	assert(!MainRouterState_userIsRestricted(&h.state, 5), "expected erin out of the set")
	messages := routerChangeTestCollect(&h, peers[:])
	defer RouterChangeTestMessages_deinit(&messages)
	assert(
		routerChangeTestCount(messages[:], 3, .ServerAccountUpdated) == 1 &&
		routerChangeTestCount(messages[:], 3, .ServerRoomMembershipChanged) == 1,
		fmt.tprintf("expected erin told once and of the room she joined, got %v", messages),
	)
	routerChangeTestDropQueries(&h)
}

// The listener's first DatabaseChangeListening fills the set; a later one (a reconnect) reads
// again only the accounts whose restriction differs, and applies them.
@(test)
testChangeListenerResyncReadsWhatDiffers :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)

	load :: proc(h: ^RouterTestHarness, restricted: []int) {
		assert(
			mainLoopHandleMessage(&h.pm, &h.state, DatabaseChangeListening{}),
			"expected the main loop to keep running",
		)
		query := routerPollDatabaseQuery(h)
		_, isLoad := query.request.(common.DatabaseRestrictedUsersRequest)
		assert(isLoad, fmt.tprintf("expected the restricted accounts read, got %v", query.request))
		IPC__database_query_request_deinit(query.request)
		MainRouterState_handleDatabaseResult(
			&h.pm,
			&h.state,
			query.request_id,
			common.DatabaseQueryResponse {
				success = true,
				result = common.DatabaseRestrictedUsersResult {
					userIds = slice.clone_to_dynamic(restricted),
				},
			},
		)
	}

	load(&h, []int{5, 6})
	assert(
		h.state.restrictedUsersLoaded &&
		len(h.state.restrictedUserIDs) == 2 &&
		MainRouterState_userIsRestricted(&h.state, 5) &&
		MainRouterState_userIsRestricted(&h.state, 6),
		"expected the first load to fill the set",
	)
	routerTestExpectNoDatabaseQuery(&h, "a read after the first load")

	// While the listener was away, 5 was lifted and 7 restricted.
	load(&h, []int{6, 7})
	query := routerPollDatabaseQuery(&h)
	request, requestOK := query.request.(common.DatabaseRestrictedChangesRequest)
	assert(
		requestOK &&
		slice.equal(request.userIds[:], []int{5, 7}) &&
		slice.equal(request.restrictedUserIds[:], []int{5}),
		fmt.tprintf("expected 5 and 7 read again, got %v", query.request),
	)
	IPC__database_query_request_deinit(query.request)
	routerChangeTestAnswer(
		&h,
		query,
		{routerChangeTestAccount(5, "five", false), routerChangeTestAccount(7, "seven", true)},
	)
	assert(
		len(h.state.restrictedUserIDs) == 2 &&
		MainRouterState_userIsRestricted(&h.state, 6) &&
		MainRouterState_userIsRestricted(&h.state, 7),
		"expected the set to follow the database",
	)
}
