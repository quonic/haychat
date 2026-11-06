package server

import "../common"
import "core:fmt"
import "core:sync"
import "core:testing"

// Router tests for one voice session per user (Q2, protocol 13): a manual join takes voice over
// from the account's other session, and an automatic re-join replaces only a session of the
// same device. They use the helpers in router_voice_test.odin. Checks inside the shared router
// mutex use testing.expect, so a failure reports instead of stopping the run with the mutex
// held.

// The index of the first packet of messageType to peerID, or -1.
@(private = "file")
singleSessionPacketIndex :: proc(
	drain: ^RouterVoiceTestDrain,
	peerID: u32,
	messageType: common.MessageType,
) -> int {
	for entry, index in drain.packets {
		if entry.peerID == peerID && entry.packet.messageType == messageType {
			return index
		}
	}
	return -1
}

// How many entries in participants name userID.
@(private = "file")
singleSessionCountUser :: proc(payload: common.ServerVoiceParticipantsPayload, userID: int) -> int {
	count := 0
	for participant in payload.participants {
		if participant.userId == userID {
			count += 1
		}
	}
	return count
}

@(test)
testVoiceRouterManualJoinFromAnotherDeviceTakesVoiceOver :: proc(t: ^testing.T) {
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)
	h.config.voiceMaxParticipants = 2

	// User 42 on two devices (peers 1 and 2) and user 43 (peer 3).
	clients := [?]RouterVoiceTestClient {
		{peerID = 1, userID = 42},
		{peerID = 2, userID = 42},
		{peerID = 3, userID = 43},
	}
	routerVoiceTestConnect(&h, clients[:])
	defer routerVoiceTestDisconnectAll(clients[:])
	members := []int{42, 43}

	routerVoiceTestJoin(&h, &clients[0], 7, members)
	routerVoiceTestJoin(&h, &clients[2], 7, members)
	drain := routerVoiceTestDrain(&h, clients[:])
	RouterVoiceTestDrain_deinit(&drain)

	// Peer 2 joins room 8 by hand: peer 1 leaves room 7 first, with the takeover reason, and
	// both rooms get their route and participant update.
	routerVoiceTestJoin(&h, &clients[1], 8, members)
	drain = routerVoiceTestDrain(&h, clients[:])
	roomID, reason, left := routerVoiceTestReason(&drain, 1, .ServerVoiceLeft)
	testing.expectf(
		t,
		left && roomID == 7 && reason == VOICE_LEFT_JOINED_ON_OTHER_DEVICE,
		"expected peer 1 to leave room 7 for another device, got %v %d %q",
		left,
		roomID,
		reason,
	)
	_, _, joinerLeft := routerVoiceTestReason(&drain, 2, .ServerVoiceLeft)
	testing.expect(t, !joinerLeft, "expected no ServerVoiceLeft for the joining session")
	oldRoute, oldRouted := routerVoiceTestLastRoute(&drain, 7)
	testing.expect(
		t,
		oldRouted && routerVoiceTestRouteHas(oldRoute, 3),
		"expected room 7 routed to user 43 only",
	)
	newRoute, newRouted := routerVoiceTestLastRoute(&drain, 8)
	testing.expect(
		t,
		newRouted && routerVoiceTestRouteHas(newRoute, 2),
		"expected room 8 routed to the new device only",
	)
	leftIndex := singleSessionPacketIndex(&drain, 1, .ServerVoiceLeft)
	firstListIndex := singleSessionPacketIndex(&drain, 2, .ServerVoiceParticipants)
	testing.expectf(
		t,
		leftIndex >= 0 && leftIndex < firstListIndex,
		"expected the old device removed before any participant update, got %d and %d",
		leftIndex,
		firstListIndex,
	)
	for peerID in ([]u32{1, 2, 3}) {
		old, oldFound := routerVoiceTestParticipants(&drain, peerID, 7)
		testing.expectf(
			t,
			oldFound && len(old.participants) == 1 && old.participants[0].userId == 43,
			"expected peer %d to see only user 43 in room 7, got %v",
			peerID,
			old,
		)
		common.ServerVoiceParticipantsPayload_deinit(&old)
		new, newFound := routerVoiceTestParticipants(&drain, peerID, 8)
		testing.expectf(
			t,
			newFound &&
			len(new.participants) == 1 &&
			singleSessionCountUser(new, 42) == 1 &&
			new.recipientJoined == (peerID == 2),
			"expected peer %d to see user 42 once in room 8, joined only on peer 2, got %v",
			peerID,
			new,
		)
		common.ServerVoiceParticipantsPayload_deinit(&new)
	}
	testing.expect(t, 1 not_in h.state.peerVoiceRoom, "expected peer 1 out of voice")
	testing.expect(t, h.state.peerVoiceRoom[2] == 8, "expected peer 2 in room 8")
	RouterVoiceTestDrain_deinit(&drain)

	// User 43 follows to room 8, which is now full.
	routerVoiceTestJoin(&h, &clients[2], 8, members)
	drain = routerVoiceTestDrain(&h, clients[:])
	RouterVoiceTestDrain_deinit(&drain)

	// Peer 1 takes voice back in the same, full room: the session it replaces frees its place,
	// and the room gets one update that shows the replacement, never the user twice or not at
	// all.
	routerVoiceTestJoin(&h, &clients[0], 8, members)
	drain = routerVoiceTestDrain(&h, clients[:])
	defer RouterVoiceTestDrain_deinit(&drain)
	roomID, reason, left = routerVoiceTestReason(&drain, 2, .ServerVoiceLeft)
	testing.expectf(
		t,
		left && roomID == 8 && reason == VOICE_LEFT_JOINED_ON_OTHER_DEVICE,
		"expected peer 2 to leave room 8 for another device, got %v %d %q",
		left,
		roomID,
		reason,
	)
	_, _, rejected := routerVoiceTestReason(&drain, 1, .ServerVoiceJoinRejected)
	testing.expect(t, !rejected, "expected the takeover of a full room to be accepted")
	route, routed := routerVoiceTestLastRoute(&drain, 8)
	testing.expect(
		t,
		routed && routerVoiceTestRouteHas(route, 1, 3),
		"expected room 8 routed to peer 1 and user 43",
	)
	testing.expectf(
		t,
		len(drain.routes) == 1,
		"expected one route update, got %d",
		len(drain.routes),
	)
	recipients := routerVoiceTestRecipients(&drain, .ServerVoiceParticipants)
	testing.expectf(
		t,
		routerVoiceTestSamePeers(recipients[:], {1, 2, 3}),
		"expected one participant update for each session, got %v",
		recipients,
	)
	for peerID in ([]u32{1, 2, 3}) {
		list, found := routerVoiceTestParticipants(&drain, peerID, 8)
		testing.expectf(
			t,
			found &&
			len(list.participants) == 2 &&
			singleSessionCountUser(list, 42) == 1 &&
			list.recipientJoined == (peerID != 2),
			"expected peer %d to see user 42 once beside user 43, got %v",
			peerID,
			list,
		)
		common.ServerVoiceParticipantsPayload_deinit(&list)
	}
	testing.expect(t, 2 not_in h.state.peerVoiceRoom, "expected peer 2 out of voice")
	testing.expect(t, h.state.peerVoiceRoom[1] == 8, "expected peer 1 in room 8")
}

@(test)
testVoiceRouterAutomaticRejoinNeverTakesVoiceFromAnotherDevice :: proc(t: ^testing.T) {
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)

	// A laptop (peer 1) is in voice; the phone the user switched from comes back (peer 2) and
	// re-joins on its own with its own device ID.
	clients := [?]RouterVoiceTestClient{{peerID = 1, userID = 42}, {peerID = 2, userID = 42}}
	routerVoiceTestConnect(&h, clients[:])
	defer routerVoiceTestDisconnectAll(clients[:])
	routerVoiceTestJoin(&h, &clients[0], 7, {42})
	drain := routerVoiceTestDrain(&h, clients[:])
	RouterVoiceTestDrain_deinit(&drain)

	routerVoiceTestJoin(&h, &clients[1], 7, {42}, rejoin = true)
	drain = routerVoiceTestDrain(&h, clients[:])
	defer RouterVoiceTestDrain_deinit(&drain)
	roomID, reason, rejected := routerVoiceTestReason(&drain, 2, .ServerVoiceJoinRejected)
	testing.expectf(
		t,
		rejected && roomID == 7 && reason == VOICE_REJECT_ACTIVE_ON_OTHER_DEVICE,
		"expected the re-join refused for another device, got %v %d %q",
		rejected,
		roomID,
		reason,
	)
	testing.expectf(
		t,
		len(drain.packets) == 1 && len(drain.routes) == 0,
		"expected only the refusal and no route change, got %d packets and %d routes",
		len(drain.packets),
		len(drain.routes),
	)
	testing.expect(t, h.state.peerVoiceRoom[1] == 7, "expected peer 1 still in room 7")
	testing.expect(t, 2 not_in h.state.peerVoiceRoom, "expected peer 2 not in voice")
}

@(test)
testVoiceRouterAutomaticRejoinReplacesTheSameDevicesStaleSession :: proc(t: ^testing.T) {
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)

	// Peer 1 is the session a network drop left behind; peer 2 is the same device after it
	// reconnected, before the server timed peer 1 out.
	clients := [?]RouterVoiceTestClient {
		{peerID = 1, userID = 42},
		{peerID = 2, userID = 42},
		{peerID = 3, userID = 43},
	}
	routerVoiceTestConnect(&h, clients[:])
	defer routerVoiceTestDisconnectAll(clients[:])
	device := "c0ffee00c0ffee00c0ffee00c0ffee00"
	members := []int{42, 43}
	routerVoiceTestJoin(&h, &clients[0], 7, members, deviceID = device)
	routerVoiceTestJoin(&h, &clients[2], 7, members)
	drain := routerVoiceTestDrain(&h, clients[:])
	RouterVoiceTestDrain_deinit(&drain)

	routerVoiceTestJoin(&h, &clients[1], 7, members, rejoin = true, deviceID = device)
	drain = routerVoiceTestDrain(&h, clients[:])
	defer RouterVoiceTestDrain_deinit(&drain)
	_, _, rejected := routerVoiceTestReason(&drain, 2, .ServerVoiceJoinRejected)
	testing.expect(t, !rejected, "expected the same device's re-join accepted")
	roomID, reason, left := routerVoiceTestReason(&drain, 1, .ServerVoiceLeft)
	testing.expectf(
		t,
		left && roomID == 7 && reason == VOICE_LEFT_JOINED_ON_OTHER_DEVICE,
		"expected the stale session removed, got %v %d %q",
		left,
		roomID,
		reason,
	)
	route, routed := routerVoiceTestLastRoute(&drain, 7)
	testing.expect(
		t,
		routed && routerVoiceTestRouteHas(route, 2, 3),
		"expected room 7 routed to the new session and user 43",
	)
	list, found := routerVoiceTestParticipants(&drain, 2, 7)
	defer common.ServerVoiceParticipantsPayload_deinit(&list)
	testing.expectf(
		t,
		found && list.recipientJoined && singleSessionCountUser(list, 42) == 1,
		"expected the new session joined and user 42 listed once, got %v",
		list,
	)
	testing.expect(t, 1 not_in h.state.peerVoiceRoom, "expected the stale session out of voice")
	testing.expect(t, h.state.peerVoiceRoom[2] == 7, "expected the new session in room 7")
}

@(test)
testVoiceRouterAutomaticRejoinWithoutAnotherSessionJoins :: proc(t: ^testing.T) {
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)

	// User 42's other session (peer 3) is connected but not in voice, so it does not count.
	clients := [?]RouterVoiceTestClient {
		{peerID = 1, userID = 42},
		{peerID = 2, userID = 43},
		{peerID = 3, userID = 42},
	}
	routerVoiceTestConnect(&h, clients[:])
	defer routerVoiceTestDisconnectAll(clients[:])
	members := []int{42, 43}
	routerVoiceTestJoin(&h, &clients[1], 7, members)
	drain := routerVoiceTestDrain(&h, clients[:])
	RouterVoiceTestDrain_deinit(&drain)

	routerVoiceTestJoin(&h, &clients[0], 7, members, rejoin = true)
	drain = routerVoiceTestDrain(&h, clients[:])
	defer RouterVoiceTestDrain_deinit(&drain)
	testing.expect(
		t,
		len(routerVoiceTestRecipients(&drain, .ServerVoiceJoinRejected)) == 0 &&
		len(routerVoiceTestRecipients(&drain, .ServerVoiceLeft)) == 0,
		"expected no refusal and nobody removed",
	)
	route, routed := routerVoiceTestLastRoute(&drain, 7)
	testing.expect(
		t,
		routed && routerVoiceTestRouteHas(route, 1, 2),
		"expected room 7 routed to both users",
	)
	list, found := routerVoiceTestParticipants(&drain, 1, 7)
	defer common.ServerVoiceParticipantsPayload_deinit(&list)
	testing.expectf(
		t,
		found && list.recipientJoined && len(list.participants) == 2,
		"expected the re-join acknowledged with both users, got %v",
		list,
	)
}

@(test)
testVoiceRouterRejectsAMalformedDeviceIDWithoutEndingTheSession :: proc(t: ^testing.T) {
	sync.mutex_lock(&routerTestMutex)
	defer sync.mutex_unlock(&routerTestMutex)
	h := routerTestHarness_init()
	defer routerTestHarness_deinit(&h)

	clients := [?]RouterVoiceTestClient{{peerID = 1, userID = 42}}
	routerVoiceTestConnect(&h, clients[:])
	defer routerVoiceTestDisconnectAll(clients[:])

	malformed := [?]string {
		"short",
		"00112233445566778899AABBCCDDEEFF",
		"00112233445566778899aabbccddeefz",
		"00000000000000000000000000000000",
		"00112233445566778899aabbccddeeff00",
	}
	for deviceID in malformed {
		routerVoiceTestSendJoin(&h, &clients[0], 7, deviceID = deviceID)
		routerTestExpectNoDatabaseQuery(&h, "expected no member check for a malformed device ID")
		drain := routerVoiceTestDrain(&h, clients[:])
		roomID, reason, rejected := routerVoiceTestReason(&drain, 1, .ServerVoiceJoinRejected)
		testing.expectf(
			t,
			rejected && roomID == 7 && reason == VOICE_REJECT_INVALID_DEVICE,
			"expected %q refused as an invalid device ID, got %v %q",
			deviceID,
			rejected,
			reason,
		)
		testing.expectf(
			t,
			len(drain.disconnects) == 0 && len(drain.packets) == 1,
			"expected only the refusal for %q and no disconnect",
			deviceID,
		)
		RouterVoiceTestDrain_deinit(&drain)
	}

	// A join without any device ID, as a protocol 12 client would send it, is refused the same.
	routerTestSendSealed(
		&h,
		&clients[0].transport,
		1,
		.ClientJoinVoice,
		common.ClientJoinVoicePayload{roomId = 7},
	)
	routerTestExpectNoDatabaseQuery(&h, "expected no member check without a device ID")
	drain := routerVoiceTestDrain(&h, clients[:])
	_, reason, rejected := routerVoiceTestReason(&drain, 1, .ServerVoiceJoinRejected)
	testing.expectf(
		t,
		rejected && reason == VOICE_REJECT_INVALID_DEVICE,
		"expected a join without a device ID refused, got %v %q",
		rejected,
		reason,
	)
	RouterVoiceTestDrain_deinit(&drain)

	// The session is intact: a valid join goes through.
	session, sessionOK := MainRouterState_getPeerSession(&h.state, 1)
	testing.expect(t, sessionOK && session.isAuthenticated, "expected the session to stay")
	routerVoiceTestJoin(&h, &clients[0], 7, {42})
	drain = routerVoiceTestDrain(&h, clients[:])
	defer RouterVoiceTestDrain_deinit(&drain)
	list, found := routerVoiceTestParticipants(&drain, 1, 7)
	defer common.ServerVoiceParticipantsPayload_deinit(&list)
	testing.expect(t, found && list.recipientJoined, fmt.tprintf("expected the join, got %v", list))
}
