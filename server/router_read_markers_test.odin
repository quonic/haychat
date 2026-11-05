package server

import "../common"
import "core:encoding/cbor"
import "core:fmt"
import "core:sync"
import "core:testing"

// Router tests for ClientMarkRead. They reuse the harnesses of router_test.odin and
// router_direct_messages_test.odin.

// Sends a mark-read from peerID and returns the database request it queued.
routerTestMarkRead :: proc(
	h: ^RouterTestHarness,
	transport: ^common.TransportState,
	peerID: u32,
	payload: common.ClientMarkReadPayload,
) -> DatabaseQuery {
	routerTestSendSealed(h, transport, peerID, .ClientMarkRead, payload)
	return routerPollDatabaseQuery(h)
}

routerTestAnswerMarkRead :: proc(
	h: ^RouterTestHarness,
	query: DatabaseQuery,
	result: common.DatabaseMarkReadResult,
) {
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		query.request_id,
		common.DatabaseQueryResponse{success = true, result = result},
	)
}

// Two sessions of user 42 (peers 1 and 3) and one of user 43 (peer 2), with the presence
// notice for 43 consumed.
RouterReadMarkerTestSessions :: struct {
	first:  common.TransportState,
	other:  common.TransportState,
	second: common.TransportState,
}

routerTestReadMarkerSessions :: proc(
	h: ^RouterTestHarness,
	sessions: ^RouterReadMarkerTestSessions,
) {
	h.state.connectedPeers[2] = true
	h.state.connectedPeers[3] = true
	sessions.first = routerCompleteHandshake(h, 1, 42)
	sessions.other = routerCompleteHandshake(h, 2, 43)
	peers := [?]RouterTestPeer{{1, &sessions.first}, {2, &sessions.other}}
	routerTestSkipPresence(h, peers[:])
	// A second session of an account that is already online announces nothing.
	sessions.second = routerCompleteHandshake(h, 3, 42)
	routerTestExpectNoNetworkMessage(h, "expected no presence for a second session of user 42")
}

@(test)
testMainRouterMarkReadFansOutToEverySessionOfTheUser :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)
	sessions: RouterReadMarkerTestSessions
	routerTestReadMarkerSessions(&h, &sessions)
	peers := [?]RouterTestPeer {
		{1, &sessions.first},
		{2, &sessions.other},
		{3, &sessions.second},
	}

	Case :: struct {
		kind:           common.ReadMarkerKind,
		conversationID: int,
	}
	for testCase in ([]Case{{.Room, common.GENERAL_ROOM_ID}, {.Direct, 43}}) {
		query := routerTestMarkRead(
			&h,
			&sessions.first,
			1,
			{kind = testCase.kind, conversationId = testCase.conversationID, messageId = 90},
		)
		defer IPC__database_query_request_deinit(query.request)
		request, requestOK := query.request.(common.DatabaseMarkReadRequest)
		assert(
			requestOK &&
			request == common.DatabaseMarkReadRequest {
					userId = 42,
					kind = testCase.kind,
					conversationId = testCase.conversationID,
					messageId = 90,
				},
			fmt.tprintf("expected one mark-read for the authenticated user, got %v", query.request),
		)
		routerTestAnswerMarkRead(
			&h,
			query,
			{allowed = true, changed = true, lastReadMessageId = 88, unreadCount = 2},
		)
		routerTestExpectNoDatabaseQuery(&h, "expected a mark-read to need one database trip")

		seen := map[u32]bool{}
		defer delete(seen)
		for _ in 0 ..< 2 {
			peerID, packet := routerTestReceive(&h, peers[:])
			defer delete(packet.payload)
			assert(
				packet.messageType == .ServerReadMarker,
				fmt.tprintf("expected ServerReadMarker, got %v", packet.messageType),
			)
			assert(peerID != 2, "expected the marker not to reach another user's session")
			marker: common.ServerReadMarkerPayload
			assert(cbor.unmarshal(packet.payload, &marker) == nil, "expected marker decode")
			expected := common.ServerReadMarkerPayload {
				kind              = testCase.kind,
				conversationId    = testCase.conversationID,
				lastReadMessageId = 88,
				unreadCount       = 2,
			}
			assert(marker == expected, fmt.tprintf("expected %v, got %v", expected, marker))
			seen[peerID] = true
		}
		assert(seen[1], "expected the session that marked read to get the marker")
		assert(seen[3], "expected the user's other session to get the marker")
		routerTestExpectNoNetworkMessage(&h, "expected exactly one marker per session of user 42")
	}
}

@(test)
testMainRouterMarkReadThatMovesNothingSendsNothing :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)
	sessions: RouterReadMarkerTestSessions
	routerTestReadMarkerSessions(&h, &sessions)

	query := routerTestMarkRead(
		&h,
		&sessions.first,
		1,
		{kind = .Room, conversationId = common.GENERAL_ROOM_ID, messageId = 5},
	)
	defer IPC__database_query_request_deinit(query.request)
	routerTestAnswerMarkRead(&h, query, {allowed = true})
	routerTestExpectNoNetworkMessage(&h, "expected a mark-read that moved nothing to send nothing")
}

@(test)
testMainRouterMarkReadRefusesWithoutEndingTheSession :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)
	sessions: RouterReadMarkerTestSessions
	routerTestReadMarkerSessions(&h, &sessions)
	peers := [?]RouterTestPeer {
		{1, &sessions.first},
		{2, &sessions.other},
		{3, &sessions.second},
	}

	// The database refuses: not a member of the room, or no such peer. The asker alone hears
	// why, and stays signed in.
	Refusal :: struct {
		kind:    common.ReadMarkerKind,
		id:      int,
		message: string,
	}
	for refusal in ([]Refusal{{.Room, 7, "Not a room member"}, {.Direct, 99, "Unknown user"}}) {
		query := routerTestMarkRead(
			&h,
			&sessions.first,
			1,
			{kind = refusal.kind, conversationId = refusal.id, messageId = 3},
		)
		defer IPC__database_query_request_deinit(query.request)
		routerTestAnswerMarkRead(&h, query, {})
		routerTestExpectProtocolError(&h, peers[:], refusal.message)
		routerTestExpectNoNetworkMessage(&h, "expected no disconnect and no marker after a refusal")
		session, ok := MainRouterState_getPeerSession(&h.state, 1)
		assert(ok && session.isAuthenticated, "expected the refused session to stay authenticated")
	}

	// Malformed requests never reach the database.
	invalid := [?]common.ClientMarkReadPayload {
		{kind = .Room, conversationId = 0, messageId = 3},
		{kind = .Room, conversationId = 1, messageId = 0},
		{kind = .Direct, conversationId = 43, messageId = -1},
		{kind = common.ReadMarkerKind(7), conversationId = 1, messageId = 3},
	}
	for payload in invalid {
		routerTestSendSealed(&h, &sessions.first, 1, .ClientMarkRead, payload)
		routerTestExpectProtocolError(&h, peers[:], "Invalid mark-read request")
		routerTestExpectNoDatabaseQuery(&h, fmt.tprintf("expected %v to be refused", payload))
	}
	routerTestSendSealed(
		&h,
		&sessions.first,
		1,
		.ClientMarkRead,
		common.ClientMarkReadPayload{kind = .Direct, conversationId = 42, messageId = 3},
	)
	routerTestExpectProtocolError(&h, peers[:], "Cannot mark a conversation with yourself read")
	routerTestExpectNoDatabaseQuery(&h, "expected a self conversation to be refused")
	routerTestExpectNoNetworkMessage(&h, "expected the session to stay up")
}

@(test)
testMainRouterRejectsUnauthenticatedMarkRead :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)

	// The handler is reached only after decryption, so call it directly to prove it still
	// refuses the harness's unauthenticated peer 1.
	markBytes, markErr := cbor.marshal(
		common.ClientMarkReadPayload{kind = .Room, conversationId = 1, messageId = 3},
	)
	assert(markErr == nil, "expected the mark-read payload to encode")
	defer delete(markBytes)
	MainRouterState_handleClientMarkRead(&h.pm, &h.state, 1, markBytes)
	routerTestExpectPlaintextProtocolError(&h, "Unauthenticated mark-read request")
	routerTestExpectNoDatabaseQuery(&h, "expected an unauthenticated mark-read to stop early")
}
