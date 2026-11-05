package server

import "../common"
import "core:encoding/cbor"
import "core:fmt"
import "core:sync"
import "core:testing"

// Router tests for the voice control plane (voice.odin). They reuse the harness in
// router_test.odin with stubbed database results. Every client transport accepts only the next
// sequence number, so a test drains the network queue in order and opens each packet with the
// transport of the peer it is addressed to (routerVoiceTestDrain).

RouterVoiceTestClient :: struct {
	peerID:    u32,
	userID:    int,
	transport: common.TransportState,
}

RouterVoiceTestPacket :: struct {
	peerID: u32,
	packet: common.Packet, // the decrypted inner packet; payload owned
}

// Everything the router queued for the network thread, in order.
RouterVoiceTestDrain :: struct {
	packets:     [dynamic]RouterVoiceTestPacket,
	routes:      [dynamic]NetworkVoiceRoute, // members owned
	resets:      int,
	disconnects: [dynamic]u32,
}

RouterVoiceTestDrain_deinit :: proc(drain: ^RouterVoiceTestDrain) {
	for entry in drain.packets {
		delete(entry.packet.payload)
	}
	for route in drain.routes {
		delete(route.members)
	}
	delete(drain.packets)
	delete(drain.routes)
	delete(drain.disconnects)
}

routerVoiceTestFindClient :: proc(
	clients: []RouterVoiceTestClient,
	peerID: u32,
) -> ^RouterVoiceTestClient {
	for &client in clients {
		if client.peerID == peerID {
			return &client
		}
	}
	return nil
}

routerVoiceTestDrain :: proc(
	h: ^RouterTestHarness,
	clients: []RouterVoiceTestClient,
) -> RouterVoiceTestDrain {
	drain: RouterVoiceTestDrain
	for {
		msg, err := IPC_Client_poll(h.networkFd)
		if err != nil {
			break
		}
		#partial switch &m in msg {
		case NetworkSendData:
			client := routerVoiceTestFindClient(clients, m.peerId)
			assert(client != nil, fmt.tprintf("expected no packet for peer %d", m.peerId))
			outer := routerDecodePacketBytes(m.data)
			inner, openOK := common.openPacketForSession(&client.transport, outer)
			delete(outer.payload)
			assert(openOK, fmt.tprintf("expected peer %d to open its packet", m.peerId))
			append(&drain.packets, RouterVoiceTestPacket{peerID = m.peerId, packet = inner})
			IPC__message_deinit(&msg)
		case NetworkVoiceRoute:
			append(&drain.routes, m)
		case NetworkVoiceReset:
			drain.resets += 1
		case NetworkDisconnectPeer:
			append(&drain.disconnects, m.peerId)
		case:
			assert(false, fmt.tprintf("expected no other network message, got %v", msg))
		}
	}
	return drain
}

// Authenticates each client in order, consuming the presence notices the earlier ones get.
routerVoiceTestConnect :: proc(h: ^RouterTestHarness, clients: []RouterVoiceTestClient) {
	for &client in clients {
		h.state.connectedPeers[client.peerID] = true
		client.transport = routerCompleteHandshake(
			h,
			client.peerID,
			client.userID,
			fmt.tprintf("voice-user-%d", client.userID),
		)
		drain := routerVoiceTestDrain(h, clients)
		RouterVoiceTestDrain_deinit(&drain)
	}
}

routerVoiceTestDisconnectAll :: proc(clients: []RouterVoiceTestClient) {
	for &client in clients {
		common.TransportState_deinit(&client.transport)
	}
}

// Sends ClientJoinVoice and answers the membership check with memberUserIDs.
routerVoiceTestJoin :: proc(
	h: ^RouterTestHarness,
	client: ^RouterVoiceTestClient,
	roomID: int,
	memberUserIDs: []int,
	muted := false,
	deafened := false,
) {
	routerTestSendSealed(
		h,
		&client.transport,
		client.peerID,
		.ClientJoinVoice,
		common.ClientJoinVoicePayload{roomId = roomID, muted = muted, deafened = deafened},
	)
	query := routerPollDatabaseQuery(h)
	defer IPC__database_query_request_deinit(query.request)
	memberRequest, ok := query.request.(common.DatabaseRoomMemberListRequest)
	assert(
		ok && memberRequest.roomId == roomID,
		fmt.tprintf("expected a member check for room %d, got %v", roomID, query.request),
	)
	userIDs := make([dynamic]int, 0, len(memberUserIDs))
	append(&userIDs, ..memberUserIDs)
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		query.request_id,
		common.DatabaseQueryResponse {
			success = true,
			result = common.DatabaseRoomMemberListResult{userIDs = userIDs},
		},
	)
}

routerVoiceTestLeave :: proc(h: ^RouterTestHarness, client: ^RouterVoiceTestClient) {
	routerTestSendSealed(
		h,
		&client.transport,
		client.peerID,
		.ClientLeaveVoice,
		common.ClientLeaveVoicePayload{},
	)
}

// The peers that got a packet of messageType, in order.
routerVoiceTestRecipients :: proc(
	drain: ^RouterVoiceTestDrain,
	messageType: common.MessageType,
) -> [dynamic]u32 {
	recipients := make([dynamic]u32, context.temp_allocator)
	for entry in drain.packets {
		if entry.packet.messageType == messageType {
			append(&recipients, entry.peerID)
		}
	}
	return recipients
}

routerVoiceTestSamePeers :: proc(got: []u32, want: []u32) -> bool {
	if len(got) != len(want) {
		return false
	}
	for peerID in want {
		found := false
		for candidate in got {
			found = found || candidate == peerID
		}
		if !found {
			return false
		}
	}
	return true
}

// Decodes the participants peerID got for roomID last. The caller frees them.
routerVoiceTestParticipants :: proc(
	drain: ^RouterVoiceTestDrain,
	peerID: u32,
	roomID: int,
) -> (
	payload: common.ServerVoiceParticipantsPayload,
	found: bool,
) {
	for index := len(drain.packets) - 1; index >= 0; index -= 1 {
		entry := drain.packets[index]
		if entry.peerID != peerID || entry.packet.messageType != .ServerVoiceParticipants {
			continue
		}
		candidate: common.ServerVoiceParticipantsPayload
		assert(cbor.unmarshal(entry.packet.payload, &candidate) == nil, "expected decode")
		if candidate.roomId == roomID {
			return candidate, true
		}
		common.ServerVoiceParticipantsPayload_deinit(&candidate)
	}
	return {}, false
}

// Decodes the single reason-bearing payload (join rejected or left) peerID got.
routerVoiceTestReason :: proc(
	drain: ^RouterVoiceTestDrain,
	peerID: u32,
	messageType: common.MessageType,
) -> (
	roomID: int,
	reason: string,
	found: bool,
) {
	for entry in drain.packets {
		if entry.peerID != peerID || entry.packet.messageType != messageType {
			continue
		}
		payload: common.ServerVoiceLeftPayload // same fields as ServerVoiceJoinRejectedPayload
		assert(cbor.unmarshal(entry.packet.payload, &payload) == nil, "expected decode")
		reasonCopy := fmt.tprintf("%s", payload.reason)
		common.ServerVoiceLeftPayload_deinit(&payload)
		return payload.roomId, reasonCopy, true
	}
	return 0, "", false
}

routerVoiceTestLastRoute :: proc(
	drain: ^RouterVoiceTestDrain,
	roomID: int,
) -> (
	NetworkVoiceRoute,
	bool,
) {
	for index := len(drain.routes) - 1; index >= 0; index -= 1 {
		if drain.routes[index].roomId == roomID {
			return drain.routes[index], true
		}
	}
	return {}, false
}

routerVoiceTestRouteHas :: proc(route: NetworkVoiceRoute, peerIDs: ..u32) -> bool {
	if len(route.members) != len(peerIDs) {
		return false
	}
	for peerID in peerIDs {
		found := false
		for member in route.members {
			found = found || member.peerId == peerID
		}
		if !found {
			return false
		}
	}
	return true
}

@(test)
testVoiceRouterJoinRequiresRoomMembership :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)

	clients := [?]RouterVoiceTestClient{{peerID = 1, userID = 42}, {peerID = 2, userID = 43}}
	routerVoiceTestConnect(&h, clients[:])
	defer routerVoiceTestDisconnectAll(clients[:])

	// Not a member: rejected, no route, nobody else told.
	routerVoiceTestJoin(&h, &clients[0], 7, {43})
	drain := routerVoiceTestDrain(&h, clients[:])
	roomID, reason, rejected := routerVoiceTestReason(&drain, 1, .ServerVoiceJoinRejected)
	assert(
		rejected && roomID == 7 && reason == VOICE_REJECT_NOT_MEMBER,
		fmt.tprintf("expected not a member for room 7, got %q for %d", reason, roomID),
	)
	assert(len(drain.routes) == 0 && len(drain.packets) == 1, "expected only the rejection")
	assert(len(h.state.voiceRooms) == 0, "expected no voice room for a rejected join")
	RouterVoiceTestDrain_deinit(&drain)

	// A member: a route for the network thread, and the participants for every member.
	routerVoiceTestJoin(&h, &clients[0], 7, {42, 43}, muted = true)
	drain = routerVoiceTestDrain(&h, clients[:])
	defer RouterVoiceTestDrain_deinit(&drain)
	route, routed := routerVoiceTestLastRoute(&drain, 7)
	assert(routed && routerVoiceTestRouteHas(route, 1), "expected a route with the joiner")
	assert(route.members[0].muted, "expected the route to carry the joiner's mute flag")
	recipients := routerVoiceTestRecipients(&drain, .ServerVoiceParticipants)
	assert(
		routerVoiceTestSamePeers(recipients[:], {1, 2}),
		fmt.tprintf("expected participants for both members, got %v", recipients),
	)
	participants, found := routerVoiceTestParticipants(&drain, 2, 7)
	defer common.ServerVoiceParticipantsPayload_deinit(&participants)
	assert(found && len(participants.participants) == 1, "expected one participant")
	participant := participants.participants[0]
	assert(
		participant.userId == 42 &&
		participant.nickname == "voice-user-42" &&
		participant.muted &&
		!participant.deafened,
		fmt.tprintf("expected user 42 muted with its nickname, got %v", participant),
	)
}

@(test)
testVoiceRouterRejectsFullRoomsDisabledVoiceAndBadRooms :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)
	h.config.voiceMaxParticipants = 1

	clients := [?]RouterVoiceTestClient{{peerID = 1, userID = 42}, {peerID = 2, userID = 43}}
	routerVoiceTestConnect(&h, clients[:])
	defer routerVoiceTestDisconnectAll(clients[:])

	routerVoiceTestJoin(&h, &clients[0], 7, {42, 43})
	drain := routerVoiceTestDrain(&h, clients[:])
	RouterVoiceTestDrain_deinit(&drain)

	routerVoiceTestJoin(&h, &clients[1], 7, {42, 43})
	drain = routerVoiceTestDrain(&h, clients[:])
	_, reason, rejected := routerVoiceTestReason(&drain, 2, .ServerVoiceJoinRejected)
	assert(rejected && reason == VOICE_REJECT_FULL, fmt.tprintf("expected full, got %q", reason))
	assert(len(drain.routes) == 0, "expected no route change for a full room")
	RouterVoiceTestDrain_deinit(&drain)

	// Disabled voice and a bad room ID are refused without asking the database.
	h.config.voiceEnabled = false
	routerTestSendSealed(
		&h,
		&clients[1].transport,
		2,
		.ClientJoinVoice,
		common.ClientJoinVoicePayload{roomId = 8},
	)
	routerTestExpectNoDatabaseQuery(&h, "expected no member check while voice is disabled")
	drain = routerVoiceTestDrain(&h, clients[:])
	_, reason, rejected = routerVoiceTestReason(&drain, 2, .ServerVoiceJoinRejected)
	assert(rejected && reason == VOICE_REJECT_DISABLED, fmt.tprintf("got %q", reason))
	RouterVoiceTestDrain_deinit(&drain)

	h.config.voiceEnabled = true
	routerTestSendSealed(
		&h,
		&clients[1].transport,
		2,
		.ClientJoinVoice,
		common.ClientJoinVoicePayload{roomId = 0},
	)
	routerTestExpectNoDatabaseQuery(&h, "expected no member check for room 0")
	drain = routerVoiceTestDrain(&h, clients[:])
	_, reason, rejected = routerVoiceTestReason(&drain, 2, .ServerVoiceJoinRejected)
	assert(rejected && reason == VOICE_REJECT_INVALID_ROOM, fmt.tprintf("got %q", reason))
	RouterVoiceTestDrain_deinit(&drain)

	// A database failure during the check is a rejection too, not a protocol error.
	routerTestSendSealed(
		&h,
		&clients[1].transport,
		2,
		.ClientJoinVoice,
		common.ClientJoinVoicePayload{roomId = 8},
	)
	query := routerPollDatabaseQuery(&h)
	IPC__database_query_request_deinit(query.request)
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		query.request_id,
		common.DatabaseQueryResponse{success = false},
	)
	drain = routerVoiceTestDrain(&h, clients[:])
	defer RouterVoiceTestDrain_deinit(&drain)
	_, reason, rejected = routerVoiceTestReason(&drain, 2, .ServerVoiceJoinRejected)
	assert(rejected && reason == VOICE_REJECT_UNAVAILABLE, fmt.tprintf("got %q", reason))
}

@(test)
testVoiceRouterJoinWhileInAnotherRoomLeavesItFirst :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)

	clients := [?]RouterVoiceTestClient{{peerID = 1, userID = 42}, {peerID = 2, userID = 43}}
	routerVoiceTestConnect(&h, clients[:])
	defer routerVoiceTestDisconnectAll(clients[:])

	routerVoiceTestJoin(&h, &clients[0], 7, {42, 43})
	routerVoiceTestJoin(&h, &clients[1], 7, {42, 43})
	drain := routerVoiceTestDrain(&h, clients[:])
	RouterVoiceTestDrain_deinit(&drain)

	routerVoiceTestJoin(&h, &clients[0], 8, {42, 43})
	drain = routerVoiceTestDrain(&h, clients[:])
	defer RouterVoiceTestDrain_deinit(&drain)

	roomID, reason, left := routerVoiceTestReason(&drain, 1, .ServerVoiceLeft)
	assert(
		left && roomID == 7 && reason == VOICE_LEFT_JOINED_OTHER_ROOM,
		fmt.tprintf("expected ServerVoiceLeft for room 7, got %q for %d", reason, roomID),
	)
	oldRoute, oldRouted := routerVoiceTestLastRoute(&drain, 7)
	newRoute, newRouted := routerVoiceTestLastRoute(&drain, 8)
	assert(oldRouted && routerVoiceTestRouteHas(oldRoute, 2), "expected only bob left in 7")
	assert(newRouted && routerVoiceTestRouteHas(newRoute, 1), "expected alice in 8")

	for peerID in ([]u32{1, 2}) {
		old, oldFound := routerVoiceTestParticipants(&drain, peerID, 7)
		assert(
			oldFound && len(old.participants) == 1 && old.participants[0].userId == 43,
			fmt.tprintf("expected peer %d to see only bob in 7", peerID),
		)
		common.ServerVoiceParticipantsPayload_deinit(&old)
		new, newFound := routerVoiceTestParticipants(&drain, peerID, 8)
		assert(
			newFound && len(new.participants) == 1 && new.participants[0].userId == 42,
			fmt.tprintf("expected peer %d to see alice in 8", peerID),
		)
		common.ServerVoiceParticipantsPayload_deinit(&new)
	}
	assert(h.state.peerVoiceRoom[1] == 8, "expected alice's session to be in room 8")
}

@(test)
testVoiceRouterFansLeaveAndStateOutToEverySessionOfEveryMember :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)

	// User 42 on two devices (peers 1 and 3), user 43, and user 44, who is not a member.
	clients := [?]RouterVoiceTestClient {
		{peerID = 1, userID = 42},
		{peerID = 2, userID = 43},
		{peerID = 3, userID = 42},
		{peerID = 4, userID = 44},
	}
	routerVoiceTestConnect(&h, clients[:])
	defer routerVoiceTestDisconnectAll(clients[:])
	members := []int{42, 43}

	routerVoiceTestJoin(&h, &clients[0], 7, members)
	routerVoiceTestJoin(&h, &clients[2], 7, members)
	drain := routerVoiceTestDrain(&h, clients[:])
	recipients := routerVoiceTestRecipients(&drain, .ServerVoiceParticipants)
	assert(
		routerVoiceTestSamePeers(recipients[:3], {1, 2, 3}) &&
		routerVoiceTestSamePeers(recipients[3:], {1, 2, 3}),
		fmt.tprintf("expected each join to reach peers 1, 2 and 3, got %v", recipients),
	)
	both, found := routerVoiceTestParticipants(&drain, 2, 7)
	assert(
		found &&
		len(both.participants) == 2 &&
		both.participants[0].userId == 42 &&
		both.participants[1].userId == 42,
		"expected the second device as a second participant with the same user ID",
	)
	assert(!both.recipientJoined, "expected user 43, not in voice, told it is not joined")
	common.ServerVoiceParticipantsPayload_deinit(&both)
	// Each device's list says whether that device itself is in voice; both are now.
	for peerID in ([]u32{1, 3}) {
		mine, mineFound := routerVoiceTestParticipants(&drain, peerID, 7)
		assert(
			mineFound && mine.recipientJoined,
			fmt.tprintf("expected peer %d told it is joined", peerID),
		)
		common.ServerVoiceParticipantsPayload_deinit(&mine)
	}
	RouterVoiceTestDrain_deinit(&drain)

	// Mute and deafen: route and participants change; the flags reach every member's sessions.
	routerTestSendSealed(
		&h,
		&clients[0].transport,
		1,
		.ClientVoiceState,
		common.ClientVoiceStatePayload{muted = true, deafened = true},
	)
	routerTestExpectNoDatabaseQuery(&h, "expected a state change to use the cached members")
	drain = routerVoiceTestDrain(&h, clients[:])
	route, routed := routerVoiceTestLastRoute(&drain, 7)
	assert(routed && routerVoiceTestRouteHas(route, 1, 3), "expected both devices routed")
	for member in route.members {
		assert(
			(member.peerId == 1) == (member.muted && member.deafened),
			"expected only peer 1 muted and deafened in the route",
		)
	}
	recipients = routerVoiceTestRecipients(&drain, .ServerVoiceParticipants)
	assert(routerVoiceTestSamePeers(recipients[:], {1, 2, 3}), "expected the state fan-out")
	RouterVoiceTestDrain_deinit(&drain)

	// The same flags again change nothing and send nothing.
	routerTestSendSealed(
		&h,
		&clients[0].transport,
		1,
		.ClientVoiceState,
		common.ClientVoiceStatePayload{muted = true, deafened = true},
	)
	routerTestExpectNoNetworkMessage(&h, "expected an unchanged state to send nothing")

	routerVoiceTestLeave(&h, &clients[0])
	drain = routerVoiceTestDrain(&h, clients[:])
	defer RouterVoiceTestDrain_deinit(&drain)
	route, routed = routerVoiceTestLastRoute(&drain, 7)
	assert(routed && routerVoiceTestRouteHas(route, 3), "expected only the second device left")
	recipients = routerVoiceTestRecipients(&drain, .ServerVoiceParticipants)
	assert(
		routerVoiceTestSamePeers(recipients[:], {1, 2, 3}),
		fmt.tprintf("expected the leave to reach peers 1, 2 and 3, got %v", recipients),
	)
	after, afterFound := routerVoiceTestParticipants(&drain, 1, 7)
	defer common.ServerVoiceParticipantsPayload_deinit(&after)
	assert(afterFound && len(after.participants) == 1, "expected the leaver to see one left")
	// The list still names user 42 (the other device), but tells peer 1 it is not joined: a
	// client must not take that for its own join.
	assert(
		after.participants[0].userId == 42 && !after.recipientJoined,
		"expected the leaver told it is not joined while its other device stays",
	)
	stayed, stayedFound := routerVoiceTestParticipants(&drain, 3, 7)
	defer common.ServerVoiceParticipantsPayload_deinit(&stayed)
	assert(stayedFound && stayed.recipientJoined, "expected the device that stayed told so")
	assert(1 not_in h.state.peerVoiceRoom, "expected peer 1 out of voice")

	// Leaving again, or changing state outside voice, is a no-op.
	routerVoiceTestLeave(&h, &clients[0])
	routerTestSendSealed(
		&h,
		&clients[0].transport,
		1,
		.ClientVoiceState,
		common.ClientVoiceStatePayload{muted = false},
	)
	routerTestExpectNoNetworkMessage(&h, "expected no-ops outside voice")
}

@(test)
testVoiceRouterEvictsOnMemberRemovalAndRoomDeletion :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)

	clients := [?]RouterVoiceTestClient {
		{peerID = 1, userID = 42},
		{peerID = 2, userID = 43},
		{peerID = 3, userID = 43},
	}
	routerVoiceTestConnect(&h, clients[:])
	defer routerVoiceTestDisconnectAll(clients[:])
	for &client in clients {
		routerVoiceTestJoin(&h, &client, 7, {42, 43})
	}
	drain := routerVoiceTestDrain(&h, clients[:])
	RouterVoiceTestDrain_deinit(&drain)

	// An admin (peer 1) removed user 43 from room 7: both of 43's sessions leave voice.
	removeID := MainRouterState_generateRequestID(&h.state)
	h.state.pendingDatabaseRequests[removeID] = PendingDBRequest {
		requestID    = removeID,
		peerID       = 1,
		requestType  = .RemoveRoomMember,
		roomID       = 7,
		targetUserID = 43,
	}
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		removeID,
		common.DatabaseQueryResponse {
			success = true,
			result = common.DatabaseRoomMutationResult{changed = true},
		},
	)
	drain = routerVoiceTestDrain(&h, clients[:])
	for peerID in ([]u32{2, 3}) {
		roomID, reason, left := routerVoiceTestReason(&drain, peerID, .ServerVoiceLeft)
		assert(
			left && roomID == 7 && reason == VOICE_LEFT_REMOVED_FROM_ROOM,
			fmt.tprintf("expected peer %d evicted from 7, got %q", peerID, reason),
		)
	}
	route, routed := routerVoiceTestLastRoute(&drain, 7)
	assert(routed && routerVoiceTestRouteHas(route, 1), "expected only peer 1 routed")
	recipients := routerVoiceTestRecipients(&drain, .ServerVoiceParticipants)
	assert(
		routerVoiceTestSamePeers(recipients[:], {1}),
		fmt.tprintf("expected the removed user to hear nothing more, got %v", recipients),
	)
	RouterVoiceTestDrain_deinit(&drain)

	// Room 7 is deleted: the last participant leaves, and nobody gets a participant list.
	deleteID := MainRouterState_generateRequestID(&h.state)
	recipientUserIDs := make([dynamic]int)
	append(&recipientUserIDs, 42)
	h.state.pendingDatabaseRequests[deleteID] = PendingDBRequest {
		requestID        = deleteID,
		peerID           = 1,
		requestType      = .DeleteRoom,
		roomID           = 7,
		recipientUserIDs = recipientUserIDs,
	}
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		deleteID,
		common.DatabaseQueryResponse {
			success = true,
			result = common.DatabaseRoomMutationResult{changed = true},
		},
	)
	drain = routerVoiceTestDrain(&h, clients[:])
	defer RouterVoiceTestDrain_deinit(&drain)
	roomID, reason, left := routerVoiceTestReason(&drain, 1, .ServerVoiceLeft)
	assert(
		left && roomID == 7 && reason == VOICE_LEFT_ROOM_DELETED,
		fmt.tprintf("expected the deletion reason, got %q", reason),
	)
	assert(
		drain.packets[0].packet.messageType == .ServerVoiceLeft,
		"expected ServerVoiceLeft before ServerDeleteRoom",
	)
	route, routed = routerVoiceTestLastRoute(&drain, 7)
	assert(routed && len(route.members) == 0, "expected an empty route for the deleted room")
	assert(
		len(routerVoiceTestRecipients(&drain, .ServerVoiceParticipants)) == 0,
		"expected no participant list for a deleted room",
	)
	assert(len(h.state.voiceRooms) == 0 && len(h.state.peerVoiceRoom) == 0, "expected no voice")
}

@(test)
testVoiceRouterDisconnectAndProtocolViolationFanOut :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)

	clients := [?]RouterVoiceTestClient {
		{peerID = 1, userID = 42},
		{peerID = 2, userID = 43},
		{peerID = 3, userID = 44},
	}
	routerVoiceTestConnect(&h, clients[:])
	defer routerVoiceTestDisconnectAll(clients[:])
	for &client in clients {
		routerVoiceTestJoin(&h, &client, 7, {42, 43, 44})
	}
	drain := routerVoiceTestDrain(&h, clients[:])
	RouterVoiceTestDrain_deinit(&drain)

	MainRouterState_handlePeerDisconnected(&h.pm, &h.state, 2)
	drain = routerVoiceTestDrain(&h, clients[:])
	route, routed := routerVoiceTestLastRoute(&drain, 7)
	assert(routed && routerVoiceTestRouteHas(route, 1, 3), "expected peer 2 out of the route")
	recipients := routerVoiceTestRecipients(&drain, .ServerVoiceParticipants)
	assert(
		routerVoiceTestSamePeers(recipients[:], {1, 3}),
		fmt.tprintf("expected the remaining participants told, got %v", recipients),
	)
	assert(
		drain.packets[0].packet.messageType == .ServerVoiceParticipants,
		"expected the voice update before the offline notice",
	)
	RouterVoiceTestDrain_deinit(&drain)

	// A protocol violation ends the session's voice as well, before its disconnect arrives.
	MainRouterState_protocolViolation(&h.pm, &h.state, 3, "test violation")
	drain = routerVoiceTestDrain(&h, clients[:])
	defer RouterVoiceTestDrain_deinit(&drain)
	route, routed = routerVoiceTestLastRoute(&drain, 7)
	assert(routed && routerVoiceTestRouteHas(route, 1), "expected peer 3 out of the route")
	recipients = routerVoiceTestRecipients(&drain, .ServerVoiceParticipants)
	assert(routerVoiceTestSamePeers(recipients[:], {1}), "expected only peer 1 told")
	assert(len(drain.disconnects) == 1 && drain.disconnects[0] == 3, "expected the disconnect")
}

@(test)
testVoiceRouterAuthSuccessHandsTheVoiceHalvesToTheNetworkThread :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)

	voiceOpen: NetworkVoiceSessionOpen
	defer common.ChannelSendState_wipe(&voiceOpen.send)
	defer common.VoiceReceiveState_wipe(&voiceOpen.receive)
	clientTransport := routerCompleteHandshake(&h, 1, 42, voiceOpen = &voiceOpen)
	defer common.TransportState_deinit(&clientTransport)

	// routerCompleteHandshake asserted that the router's copy is zero. The halves that went to
	// the network thread are the server side of the client's voice keys, in both directions.
	session, _ := MainRouterState_getPeerSession(&h.state, 1)
	assert(voiceOpen.sessionID == session.sessionID, "expected the session's ID")
	plaintext := []u8{1, 2, 3, 4, 5}
	sealed: [64]u8
	opened: [64]u8
	n, sealOK := common.sealVoiceDatagram(
		&voiceOpen.send,
		voiceOpen.sessionID,
		plaintext,
		sealed[:],
	)
	assert(sealOK, "expected the relay's send half to seal")
	m, result := common.openVoiceDatagram(
		&clientTransport.voiceReceive,
		clientTransport.sessionID,
		sealed[:n],
		opened[:],
	)
	assert(result == .Ok && string(opened[:m]) == string(plaintext), "expected the client to open")

	n, sealOK = common.sealVoiceDatagram(
		&clientTransport.voiceSend,
		clientTransport.sessionID,
		plaintext,
		sealed[:],
	)
	assert(sealOK, "expected the client to seal")
	m, result = common.openVoiceDatagram(
		&voiceOpen.receive,
		voiceOpen.sessionID,
		sealed[:n],
		opened[:],
	)
	assert(result == .Ok && string(opened[:m]) == string(plaintext), "expected the relay to open")
}

@(test)
testVoiceRouterRoomListSendsActiveParticipants :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)

	clients := [?]RouterVoiceTestClient{{peerID = 1, userID = 42}, {peerID = 2, userID = 43}}
	routerVoiceTestConnect(&h, clients[:])
	defer routerVoiceTestDisconnectAll(clients[:])

	// The join check ran before user 43 existed in room 7, so it only knew user 42.
	routerVoiceTestJoin(&h, &clients[0], 7, {42})
	drain := routerVoiceTestDrain(&h, clients[:])
	RouterVoiceTestDrain_deinit(&drain)

	routerTestSendSealed(
		&h,
		&clients[1].transport,
		2,
		.ClientListRooms,
		common.ClientListRoomsPayload{},
	)
	query := routerPollDatabaseQuery(&h)
	IPC__database_query_request_deinit(query.request)
	rooms := make([dynamic]common.RoomSummary)
	for roomID in ([]int{7, 9}) {
		append(&rooms, common.RoomSummary{id = roomID, name = fmt.aprintf("room-%d", roomID)})
	}
	MainRouterState_handleDatabaseResult(
		&h.pm,
		&h.state,
		query.request_id,
		common.DatabaseQueryResponse {
			success = true,
			result = common.DatabaseRoomListResult{rooms = rooms},
		},
	)
	drain = routerVoiceTestDrain(&h, clients[:])
	assert(
		len(drain.packets) == 2 &&
		drain.packets[0].packet.messageType == .ServerListRooms &&
		drain.packets[1].packet.messageType == .ServerVoiceParticipants,
		"expected the room list followed by room 7's participants only",
	)
	participants, found := routerVoiceTestParticipants(&drain, 2, 7)
	assert(found && len(participants.participants) == 1, "expected alice in room 7")
	common.ServerVoiceParticipantsPayload_deinit(&participants)
	RouterVoiceTestDrain_deinit(&drain)

	// Listing the room made user 43 a recipient of room 7's later changes.
	routerVoiceTestLeave(&h, &clients[0])
	drain = routerVoiceTestDrain(&h, clients[:])
	defer RouterVoiceTestDrain_deinit(&drain)
	recipients := routerVoiceTestRecipients(&drain, .ServerVoiceParticipants)
	assert(
		routerVoiceTestSamePeers(recipients[:], {1, 2}),
		fmt.tprintf("expected the leave to reach both, got %v", recipients),
	)
	assert(len(h.state.voiceRooms) == 0, "expected the empty room to be dropped")
}

@(test)
testVoiceRouterNetworkStopClearsVoiceState :: proc(t: ^testing.T) {
	_ = t
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)

	clients := [?]RouterVoiceTestClient{{peerID = 1, userID = 42}}
	routerVoiceTestConnect(&h, clients[:])
	defer routerVoiceTestDisconnectAll(clients[:])
	routerVoiceTestJoin(&h, &clients[0], 7, {42})
	drain := routerVoiceTestDrain(&h, clients[:])
	RouterVoiceTestDrain_deinit(&drain)

	rooms, participants := MainRouterState_voiceCounts(&h.state)
	assert(rooms == 1 && participants == 1, "expected one room with one participant")

	MainRouterState_prepareForProcessStop(&h.pm, &h.state, .Network, "network restarting")
	drain = routerVoiceTestDrain(&h, clients[:])
	defer RouterVoiceTestDrain_deinit(&drain)
	assert(drain.resets == 1, "expected the network thread told to forget voice")
	assert(
		len(h.state.voiceRooms) == 0 && len(h.state.peerVoiceRoom) == 0,
		"expected the router's voice state cleared",
	)
}
