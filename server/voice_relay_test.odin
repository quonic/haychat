package server

import "../common"
import "core:fmt"
import "core:testing"
import "vendor:ENet"

// VoiceRelay tests. The relay's send and clock are injected (voice_relay.odin), so these run
// without ENet: the sink records every datagram the relay hands out, and the test clock moves
// only when a test says so. Each test peer gets real voice keys, so a datagram a recipient gets
// is opened with that recipient's own client-side receive state, as a client would.

VoiceRelayTestSent :: struct {
	peerId: u32,
	length: int,
	data:   [common.VOICE_DATAGRAM_MAX_SIZE]u8,
}

VoiceRelayTestSink :: struct {
	sent:      [dynamic]VoiceRelayTestSent,
	nowNanos:  i64,
	failSends: bool,
}

voiceRelayTestSend :: proc(userData: rawptr, peerId: u32, datagram: []u8) -> bool {
	sink := cast(^VoiceRelayTestSink)userData
	if sink.failSends {
		return false
	}
	entry := VoiceRelayTestSent {
		peerId = peerId,
		length = len(datagram),
	}
	copy(entry.data[:], datagram)
	append(&sink.sent, entry)
	return true
}

voiceRelayTestClock :: proc(userData: rawptr) -> i64 {
	sink := cast(^VoiceRelayTestSink)userData
	return sink.nowNanos
}

// The client side of one relay peer: the voice halves a client keeps.
VoiceRelayTestClient :: struct {
	peerId:    u32,
	userId:    int,
	sessionID: common.SessionID,
	transport: common.TransportState,
}

VoiceRelayTestClient_deinit :: proc(client: ^VoiceRelayTestClient) {
	common.TransportState_deinit(&client.transport)
}

VOICE_RELAY_TEST_OPUS := [?]u8{0xF8, 0x11, 0x22, 0x33} // TOC config 31, code 0: CELT FB 20 ms

voiceRelayTestInit :: proc(
	relay: ^VoiceRelay,
	sink: ^VoiceRelayTestSink,
	maxPacketsPerSecond := 1000,
	maxFrameBytes := 512,
) {
	VoiceRelay_init(
		relay,
		VoiceRelayConfig {
			maxPacketsPerSecond = maxPacketsPerSecond,
			maxFrameBytes = maxFrameBytes,
		},
		voiceRelayTestSend,
		voiceRelayTestClock,
		sink,
	)
}

voiceRelayTestDeinit :: proc(relay: ^VoiceRelay, sink: ^VoiceRelayTestSink) {
	VoiceRelay_deinit(relay)
	delete(sink.sent)
}

// Derives a matching server and client key set, hands the server's voice halves to the relay as
// the router would, and returns the client side.
voiceRelayTestOpenPeer :: proc(
	relay: ^VoiceRelay,
	peerId: u32,
	userId: int,
) -> VoiceRelayTestClient {
	sessionID, sessionOK := common.generateSessionID()
	assert(sessionOK, "expected a session ID")
	sharedSecret: common.SharedSecretBytes
	transcriptHash: common.FingerprintBytes
	assert(common.generateRandomBytes(sharedSecret[:]), "expected a shared secret")
	assert(common.generateRandomBytes(transcriptHash[:]), "expected a transcript hash")

	serverKeys := common.deriveDirectionalTransportKeys(
		.Server,
		sessionID,
		sharedSecret,
		transcriptHash,
	)
	clientKeys := common.deriveDirectionalTransportKeys(
		.Client,
		sessionID,
		sharedSecret,
		transcriptHash,
	)
	defer common.DirectionalTransportKeys_wipe(&serverKeys)
	defer common.DirectionalTransportKeys_wipe(&clientKeys)

	server := common.TransportState_init(.Server)
	common.TransportState_activate(&server, sessionID, serverKeys, .Trusted)
	defer common.TransportState_deinit(&server)
	client := VoiceRelayTestClient {
		peerId    = peerId,
		userId    = userId,
		sessionID = sessionID,
		transport = common.TransportState_init(.Client),
	}
	common.TransportState_activate(&client.transport, sessionID, clientKeys, .Trusted)

	send, receive := common.TransportState_takeVoiceState(&server)
	msg := NetworkVoiceSessionOpen {
		peerId    = peerId,
		userId    = userId,
		sessionID = sessionID,
		send      = send,
		receive   = receive,
	}
	common.ChannelSendState_wipe(&send)
	common.VoiceReceiveState_wipe(&receive)
	VoiceRelay_openSession(relay, &msg)
	assert(
		!msg.send.active && !msg.receive.active,
		"expected openSession to wipe the keys in the message it took them from",
	)
	return client
}

// Seals a ClientVoiceFrame as client would send it.
voiceRelayTestSealFrame :: proc(
	client: ^VoiceRelayTestClient,
	roomId: u32,
	frameSequence: u32,
	flags: u8,
	opus: []u8,
	dst: []u8,
) -> []u8 {
	plaintext: [common.CLIENT_VOICE_FRAME_MAX_SIZE]u8
	n, ok := common.encodeClientVoiceFrame(
		common.ClientVoiceFrame {
			roomId = roomId,
			frameSequence = frameSequence,
			flags = flags,
			opus = opus,
		},
		plaintext[:],
	)
	assert(ok, "expected the test frame to encode")
	return voiceRelayTestSealPlaintext(client, plaintext[:n], dst)
}

// Seals arbitrary plaintext, for frames the encoder refuses to write.
voiceRelayTestSealPlaintext :: proc(
	client: ^VoiceRelayTestClient,
	plaintext: []u8,
	dst: []u8,
) -> []u8 {
	sealedLength, sealOK := common.sealVoiceDatagram(
		&client.transport.voiceSend,
		client.sessionID,
		plaintext,
		dst,
	)
	assert(sealOK, "expected the client to seal its datagram")
	return dst[:sealedLength]
}

// Sends one ordinary frame from client and returns how many datagrams the relay handed out.
voiceRelayTestSendFrame :: proc(
	relay: ^VoiceRelay,
	sink: ^VoiceRelayTestSink,
	client: ^VoiceRelayTestClient,
	roomId: u32,
) -> int {
	before := len(sink.sent)
	buffer: [common.VOICE_DATAGRAM_MAX_SIZE]u8
	datagram := voiceRelayTestSealFrame(client, roomId, 1, 0, VOICE_RELAY_TEST_OPUS[:], buffer[:])
	VoiceRelay_handleDatagram(relay, client.peerId, datagram)
	return len(sink.sent) - before
}

voiceRelayTestRoute :: proc(relay: ^VoiceRelay, roomId: int, members: ..NetworkVoiceRouteMember) {
	VoiceRelay_applyRoute(relay, roomId, members)
}

voiceRelayTestRoomMembers :: proc(relay: ^VoiceRelay, roomId: int) -> []u32 {
	members, ok := relay.rooms[roomId]
	if !ok {
		return nil
	}
	return members[:]
}

voiceRelayTestTotalDrops :: proc(relay: ^VoiceRelay) -> u64 {
	total: u64
	for reason in VoiceRelayDropReason {
		total += relay.stats.drops[reason]
	}
	return total
}

@(test)
testVoiceRelayForwardsToEveryOtherParticipantWithTheirOwnKeys :: proc(t: ^testing.T) {
	_ = t
	sink: VoiceRelayTestSink
	relay: VoiceRelay
	voiceRelayTestInit(&relay, &sink)
	defer voiceRelayTestDeinit(&relay, &sink)

	alice := voiceRelayTestOpenPeer(&relay, 1, 42)
	bob := voiceRelayTestOpenPeer(&relay, 2, 43)
	carol := voiceRelayTestOpenPeer(&relay, 3, 44)
	defer VoiceRelayTestClient_deinit(&alice)
	defer VoiceRelayTestClient_deinit(&bob)
	defer VoiceRelayTestClient_deinit(&carol)
	voiceRelayTestRoute(&relay, 7, {peerId = 1}, {peerId = 2}, {peerId = 3})

	buffer: [common.VOICE_DATAGRAM_MAX_SIZE]u8
	datagram := voiceRelayTestSealFrame(
		&alice,
		7,
		1234,
		common.VOICE_FRAME_FLAG_END_OF_SPURT,
		VOICE_RELAY_TEST_OPUS[:],
		buffer[:],
	)
	VoiceRelay_handleDatagram(&relay, alice.peerId, datagram)

	assert(
		len(sink.sent) == 2,
		fmt.tprintf("expected one datagram for each other participant, got %d", len(sink.sent)),
	)
	recipients := [2]^VoiceRelayTestClient{&bob, &carol}
	for &sent, index in sink.sent {
		recipient := recipients[index]
		assert(
			sent.peerId == recipient.peerId,
			fmt.tprintf(
				"expected datagram %d for peer %d, got %d",
				index,
				recipient.peerId,
				sent.peerId,
			),
		)
		assert(sent.peerId != alice.peerId, "expected no echo to the sender")
		plaintext: [common.SERVER_VOICE_FRAME_MAX_SIZE]u8
		n, openResult := common.openVoiceDatagram(
			&recipient.transport.voiceReceive,
			recipient.sessionID,
			sent.data[:sent.length],
			plaintext[:],
		)
		assert(
			openResult == .Ok,
			fmt.tprintf("expected peer %d to open its datagram, got %v", sent.peerId, openResult),
		)
		frame, frameResult := common.decodeServerVoiceFrame(plaintext[:n])
		assert(frameResult == .Ok, fmt.tprintf("expected a server frame, got %v", frameResult))
		assert(
			frame.roomId == 7 &&
			frame.senderUserId == 42 &&
			frame.frameSequence == 1234 &&
			frame.flags == common.VOICE_FRAME_FLAG_END_OF_SPURT,
			fmt.tprintf("expected room 7, sender 42, sequence 1234, END_OF_SPURT, got %v", frame),
		)
		assert(
			string(frame.opus) == string(VOICE_RELAY_TEST_OPUS[:]),
			"expected the Opus bytes unchanged",
		)
		// Another recipient's datagram does not open under this recipient's key (bad tag, or
		// a replay once the other recipient has opened its own datagram of that sequence).
		other := recipients[1 - index]
		_, crossResult := common.openVoiceDatagram(
			&other.transport.voiceReceive,
			other.sessionID,
			sent.data[:sent.length],
			plaintext[:],
		)
		assert(crossResult != .Ok, "expected each datagram to be sealed for its recipient")
	}
	assert(
		relay.stats.datagramsIn == 1 &&
		relay.stats.framesRelayed == 1 &&
		relay.stats.datagramsOut == 2 &&
		voiceRelayTestTotalDrops(&relay) == 0,
		fmt.tprintf("expected 1 in, 1 relayed, 2 out, no drops, got %v", relay.stats),
	)
}

@(test)
testVoiceRelaySkipsDeafenedPeersAndDropsMutedSenders :: proc(t: ^testing.T) {
	_ = t
	sink: VoiceRelayTestSink
	relay: VoiceRelay
	voiceRelayTestInit(&relay, &sink)
	defer voiceRelayTestDeinit(&relay, &sink)

	alice := voiceRelayTestOpenPeer(&relay, 1, 42)
	bob := voiceRelayTestOpenPeer(&relay, 2, 43)
	carol := voiceRelayTestOpenPeer(&relay, 3, 44)
	defer VoiceRelayTestClient_deinit(&alice)
	defer VoiceRelayTestClient_deinit(&bob)
	defer VoiceRelayTestClient_deinit(&carol)
	voiceRelayTestRoute(&relay, 7, {peerId = 1}, {peerId = 2, deafened = true}, {peerId = 3})

	sent := voiceRelayTestSendFrame(&relay, &sink, &alice, 7)
	assert(sent == 1 && sink.sent[0].peerId == 3, "expected only carol to hear alice")

	// A deafened peer may still talk.
	sent = voiceRelayTestSendFrame(&relay, &sink, &bob, 7)
	assert(sent == 2, fmt.tprintf("expected the deafened peer to be heard, got %d", sent))

	voiceRelayTestRoute(&relay, 7, {peerId = 1, muted = true}, {peerId = 2}, {peerId = 3})
	sent = voiceRelayTestSendFrame(&relay, &sink, &alice, 7)
	assert(sent == 0, "expected a muted sender's frame to go nowhere")
	assert(relay.stats.drops[.Muted] == 1, "expected the muted frame to be counted")
	assert(VoiceRelay_hasPeer(&relay, 1), "expected the muted peer to stay connected")
}

@(test)
testVoiceRelayDropsPeersOutsideTheRoomAndWrongRoomFrames :: proc(t: ^testing.T) {
	_ = t
	sink: VoiceRelayTestSink
	relay: VoiceRelay
	voiceRelayTestInit(&relay, &sink)
	defer voiceRelayTestDeinit(&relay, &sink)

	alice := voiceRelayTestOpenPeer(&relay, 1, 42)
	bob := voiceRelayTestOpenPeer(&relay, 2, 43)
	outsider := voiceRelayTestOpenPeer(&relay, 3, 44)
	defer VoiceRelayTestClient_deinit(&alice)
	defer VoiceRelayTestClient_deinit(&bob)
	defer VoiceRelayTestClient_deinit(&outsider)
	voiceRelayTestRoute(&relay, 7, {peerId = 1}, {peerId = 2})
	voiceRelayTestRoute(&relay, 8, {peerId = 3})

	// A peer with no voice session at all, such as a connection that never authenticated.
	VoiceRelay_handleDatagram(&relay, 99, []u8{1, 2, 3})
	assert(relay.stats.drops[.UnknownPeer] == 1, "expected an unknown peer to be counted")

	// A peer in another room naming room 7.
	assert(voiceRelayTestSendFrame(&relay, &sink, &outsider, 7) == 0, "expected no relay")
	assert(relay.stats.drops[.WrongRoom] == 1, "expected the wrong room ID to be counted")

	// A peer with a session but in no room.
	voiceRelayTestRoute(&relay, 8)
	assert(voiceRelayTestSendFrame(&relay, &sink, &outsider, 8) == 0, "expected no relay")
	assert(relay.stats.drops[.NotInRoom] == 1, "expected a peer in no room to be counted")

	// A member naming a room it is not in, e.g. a late frame from before a switch.
	assert(voiceRelayTestSendFrame(&relay, &sink, &alice, 8) == 0, "expected no relay")
	assert(relay.stats.drops[.WrongRoom] == 2, "expected the stale room ID to be counted")

	assert(voiceRelayTestSendFrame(&relay, &sink, &alice, 7) == 1, "expected bob to hear alice")
	assert(len(sink.sent) == 1 && sink.sent[0].peerId == 2, "expected nothing for the outsider")
}

@(test)
testVoiceRelayRateLimitsEachPeer :: proc(t: ^testing.T) {
	_ = t
	sink: VoiceRelayTestSink
	relay: VoiceRelay
	// 60 packets per second: a burst of 20, then one token every 1/60 s.
	voiceRelayTestInit(&relay, &sink, maxPacketsPerSecond = 60)
	defer voiceRelayTestDeinit(&relay, &sink)

	alice := voiceRelayTestOpenPeer(&relay, 1, 42)
	bob := voiceRelayTestOpenPeer(&relay, 2, 43)
	defer VoiceRelayTestClient_deinit(&alice)
	defer VoiceRelayTestClient_deinit(&bob)
	voiceRelayTestRoute(&relay, 7, {peerId = 1}, {peerId = 2})

	sink.nowNanos = 1_000_000_000
	for _ in 0 ..< 25 {
		voiceRelayTestSendFrame(&relay, &sink, &alice, 7)
	}
	assert(
		relay.stats.framesRelayed == 20 && relay.stats.drops[.RateLimited] == 5,
		fmt.tprintf("expected a burst of 20 and 5 limited, got %v", relay.stats),
	)
	// Bob has a bucket of his own.
	assert(voiceRelayTestSendFrame(&relay, &sink, &bob, 7) == 1, "expected bob unaffected")

	// Half a second refills 30 tokens, capped at the burst of 20.
	sink.nowNanos += 500_000_000
	for _ in 0 ..< 25 {
		voiceRelayTestSendFrame(&relay, &sink, &alice, 7)
	}
	assert(
		relay.stats.framesRelayed == 41 && relay.stats.drops[.RateLimited] == 10,
		fmt.tprintf("expected the bucket to refill to its burst, got %v", relay.stats),
	)
	assert(VoiceRelay_hasPeer(&relay, 1), "expected a rate-limited peer to stay connected")
}

@(test)
testVoiceRelayDropsOversizeMalformedAndNon20msFrames :: proc(t: ^testing.T) {
	_ = t
	sink: VoiceRelayTestSink
	relay: VoiceRelay
	voiceRelayTestInit(&relay, &sink, maxFrameBytes = 64)
	defer voiceRelayTestDeinit(&relay, &sink)

	alice := voiceRelayTestOpenPeer(&relay, 1, 42)
	bob := voiceRelayTestOpenPeer(&relay, 2, 43)
	defer VoiceRelayTestClient_deinit(&alice)
	defer VoiceRelayTestClient_deinit(&bob)
	voiceRelayTestRoute(&relay, 7, {peerId = 1}, {peerId = 2})

	buffer: [common.VOICE_DATAGRAM_MAX_SIZE]u8
	// Over the configured 64 bytes, under the wire limit.
	large: [65]u8
	large[0] = 0xF8
	datagram := voiceRelayTestSealFrame(&alice, 7, 1, 0, large[:], buffer[:])
	VoiceRelay_handleDatagram(&relay, 1, datagram)
	assert(relay.stats.drops[.Oversize] == 1, "expected the configured cap to apply")

	// Over the wire limit: 513 Opus bytes, which encodeClientVoiceFrame refuses to write.
	huge: [common.CLIENT_VOICE_FRAME_HEADER_SIZE + common.VOICE_OPUS_MAX_BYTES + 1]u8
	huge[0] = 7
	huge[common.CLIENT_VOICE_FRAME_HEADER_SIZE] = 0xF8
	datagram = voiceRelayTestSealPlaintext(&alice, huge[:], buffer[:])
	VoiceRelay_handleDatagram(&relay, 1, datagram)
	assert(relay.stats.drops[.Oversize] == 2, "expected the wire limit to apply")

	// A header and no Opus bytes, and a plaintext shorter than the header.
	headerOnly := [common.CLIENT_VOICE_FRAME_HEADER_SIZE]u8{0 = 7}
	datagram = voiceRelayTestSealPlaintext(&alice, headerOnly[:], buffer[:])
	VoiceRelay_handleDatagram(&relay, 1, datagram)
	datagram = voiceRelayTestSealPlaintext(&alice, []u8{7, 0, 0}, buffer[:])
	VoiceRelay_handleDatagram(&relay, 1, datagram)
	assert(relay.stats.drops[.MalformedFrame] == 2, "expected both malformed frames counted")

	// TOC config 0, code 0: 10 ms of SILK. Config 1, code 1: two 20 ms frames, 40 ms.
	for toc in ([]u8{0x00, 0x09}) {
		datagram = voiceRelayTestSealFrame(&alice, 7, 1, 0, []u8{toc, 1, 2}, buffer[:])
		VoiceRelay_handleDatagram(&relay, 1, datagram)
	}
	assert(relay.stats.drops[.BadDuration] == 2, "expected non-20 ms packets counted")

	assert(len(sink.sent) == 0, "expected none of the bad frames to be relayed")
	assert(voiceRelayTestSendFrame(&relay, &sink, &alice, 7) == 1, "expected a good frame after")
}

@(test)
testVoiceRelayCountsReplayedForgedAndMalformedDatagramsWithoutDisconnecting :: proc(
	t: ^testing.T,
) {
	_ = t
	sink: VoiceRelayTestSink
	relay: VoiceRelay
	voiceRelayTestInit(&relay, &sink)
	defer voiceRelayTestDeinit(&relay, &sink)

	alice := voiceRelayTestOpenPeer(&relay, 1, 42)
	bob := voiceRelayTestOpenPeer(&relay, 2, 43)
	defer VoiceRelayTestClient_deinit(&alice)
	defer VoiceRelayTestClient_deinit(&bob)
	voiceRelayTestRoute(&relay, 7, {peerId = 1}, {peerId = 2})

	first: [common.VOICE_DATAGRAM_MAX_SIZE]u8
	firstDatagram := voiceRelayTestSealFrame(&alice, 7, 1, 0, VOICE_RELAY_TEST_OPUS[:], first[:])
	VoiceRelay_handleDatagram(&relay, 1, firstDatagram)
	VoiceRelay_handleDatagram(&relay, 1, firstDatagram)
	assert(relay.stats.drops[.Replayed] == 1, "expected the replay to be counted")

	// A flipped ciphertext byte, a forged high sequence, and a datagram sealed under bob's key
	// but sent from alice's peer all fail the tag.
	buffer: [common.VOICE_DATAGRAM_MAX_SIZE]u8
	forged := voiceRelayTestSealFrame(&alice, 7, 2, 0, VOICE_RELAY_TEST_OPUS[:], buffer[:])
	forged[common.VOICE_DATAGRAM_HEADER_SIZE] ~= 0x01
	VoiceRelay_handleDatagram(&relay, 1, forged)
	highSequence := voiceRelayTestSealFrame(&alice, 7, 3, 0, VOICE_RELAY_TEST_OPUS[:], buffer[:])
	highSequence[8] = 0x7F // sequence byte 7: far ahead of the window
	VoiceRelay_handleDatagram(&relay, 1, highSequence)
	// Bob's sequence 0 would be a replay in alice's window, so spend it first.
	_ = voiceRelayTestSealFrame(&bob, 7, 1, 0, VOICE_RELAY_TEST_OPUS[:], buffer[:])
	spoofed := voiceRelayTestSealFrame(&bob, 7, 1, 0, VOICE_RELAY_TEST_OPUS[:], buffer[:])
	VoiceRelay_handleDatagram(&relay, 1, spoofed)
	assert(relay.stats.drops[.BadTag] == 3, fmt.tprintf("expected 3 bad tags, got %v", relay.stats))

	// Too short for the envelope, and an unknown kind byte.
	VoiceRelay_handleDatagram(&relay, 1, []u8{common.VOICE_DATAGRAM_KIND_FRAME, 0, 0})
	unknownKind := voiceRelayTestSealFrame(&alice, 7, 4, 0, VOICE_RELAY_TEST_OPUS[:], buffer[:])
	unknownKind[0] = 0x02
	VoiceRelay_handleDatagram(&relay, 1, unknownKind)
	assert(relay.stats.drops[.Malformed] == 2, "expected both malformed datagrams counted")

	// A datagram that falls behind the 64-packet window.
	old: [common.VOICE_DATAGRAM_MAX_SIZE]u8
	oldDatagram := voiceRelayTestSealFrame(&alice, 7, 5, 0, VOICE_RELAY_TEST_OPUS[:], old[:])
	for _ in 0 ..< common.REPLAY_WINDOW_SIZE {
		_ = voiceRelayTestSealFrame(&alice, 7, 6, 0, VOICE_RELAY_TEST_OPUS[:], buffer[:])
	}
	latest := voiceRelayTestSealFrame(&alice, 7, 7, 0, VOICE_RELAY_TEST_OPUS[:], buffer[:])
	VoiceRelay_handleDatagram(&relay, 1, latest)
	VoiceRelay_handleDatagram(&relay, 1, oldDatagram)
	assert(relay.stats.drops[.TooOld] == 1, "expected the stale datagram to be counted")

	// Nothing above ended alice's session: her next frame is relayed.
	assert(VoiceRelay_hasPeer(&relay, 1), "expected no bad datagram to remove the peer")
	assert(voiceRelayTestSendFrame(&relay, &sink, &alice, 7) == 1, "expected alice still heard")
	assert(
		relay.stats.framesRelayed == 3,
		fmt.tprintf("expected the first, latest and last frames relayed, got %v", relay.stats),
	)
}

@(test)
testVoiceRelayDisconnectForgetsThePeerAndItsRouteEntries :: proc(t: ^testing.T) {
	_ = t
	sink: VoiceRelayTestSink
	relay: VoiceRelay
	voiceRelayTestInit(&relay, &sink)
	defer voiceRelayTestDeinit(&relay, &sink)

	alice := voiceRelayTestOpenPeer(&relay, 1, 42)
	bob := voiceRelayTestOpenPeer(&relay, 2, 43)
	defer VoiceRelayTestClient_deinit(&alice)
	defer VoiceRelayTestClient_deinit(&bob)
	voiceRelayTestRoute(&relay, 7, {peerId = 1}, {peerId = 2})

	VoiceRelay_removePeer(&relay, 2)
	assert(!VoiceRelay_hasPeer(&relay, 2), "expected the disconnected peer to be forgotten")
	members := voiceRelayTestRoomMembers(&relay, 7)
	assert(
		len(members) == 1 && members[0] == 1,
		fmt.tprintf("expected only alice left in room 7, got %v", members),
	)
	assert(voiceRelayTestSendFrame(&relay, &sink, &alice, 7) == 0, "expected nobody to hear")
	assert(voiceRelayTestSendFrame(&relay, &sink, &bob, 7) == 0, "expected bob's frames dropped")
	assert(relay.stats.drops[.UnknownPeer] == 1, "expected bob's frame counted as unknown")

	// A route the router built before it heard of the disconnect skips the missing peer.
	voiceRelayTestRoute(&relay, 7, {peerId = 1}, {peerId = 2})
	members = voiceRelayTestRoomMembers(&relay, 7)
	assert(len(members) == 1, fmt.tprintf("expected the stale member skipped, got %v", members))

	VoiceRelay_removePeer(&relay, 1)
	assert(7 not_in relay.rooms, "expected the emptied room to be removed")
	assert(len(relay.peers) == 0, "expected no peers left")
}

@(test)
testVoiceRelayRoutesReplaceTheRoomAndMovePeersBetweenRooms :: proc(t: ^testing.T) {
	_ = t
	sink: VoiceRelayTestSink
	relay: VoiceRelay
	voiceRelayTestInit(&relay, &sink)
	defer voiceRelayTestDeinit(&relay, &sink)

	alice := voiceRelayTestOpenPeer(&relay, 1, 42)
	bob := voiceRelayTestOpenPeer(&relay, 2, 43)
	carol := voiceRelayTestOpenPeer(&relay, 3, 44)
	defer VoiceRelayTestClient_deinit(&alice)
	defer VoiceRelayTestClient_deinit(&bob)
	defer VoiceRelayTestClient_deinit(&carol)
	voiceRelayTestRoute(&relay, 7, {peerId = 1}, {peerId = 2}, {peerId = 3})

	// Carol moves to room 8; the router sends a route for each room. A route for 8 alone moves
	// her out of 7 as well.
	voiceRelayTestRoute(&relay, 8, {peerId = 3})
	members := voiceRelayTestRoomMembers(&relay, 7)
	assert(len(members) == 2, fmt.tprintf("expected carol out of room 7, got %v", members))
	assert(voiceRelayTestSendFrame(&relay, &sink, &alice, 7) == 1, "expected only bob in 7")
	assert(voiceRelayTestSendFrame(&relay, &sink, &carol, 8) == 0, "expected carol alone in 8")

	// Bob leaves room 7: the full replacement drops him.
	voiceRelayTestRoute(&relay, 7, {peerId = 1})
	assert(voiceRelayTestSendFrame(&relay, &sink, &bob, 7) == 0, "expected bob out of voice")
	assert(relay.stats.drops[.NotInRoom] == 1, "expected bob's frame counted as not in a room")

	// An empty route removes the room.
	voiceRelayTestRoute(&relay, 7)
	assert(7 not_in relay.rooms, "expected the empty route to remove room 7")

	// A new session for a peer replaces the old one and leaves its room.
	replacement := voiceRelayTestOpenPeer(&relay, 3, 44)
	defer VoiceRelayTestClient_deinit(&replacement)
	assert(8 not_in relay.rooms, "expected the replaced session to leave room 8")

	VoiceRelay_reset(&relay)
	assert(len(relay.peers) == 0 && len(relay.rooms) == 0, "expected reset to forget everything")
}

@(test)
testVoiceRelayCountsSendFailures :: proc(t: ^testing.T) {
	_ = t
	sink: VoiceRelayTestSink
	relay: VoiceRelay
	voiceRelayTestInit(&relay, &sink)
	defer voiceRelayTestDeinit(&relay, &sink)

	alice := voiceRelayTestOpenPeer(&relay, 1, 42)
	bob := voiceRelayTestOpenPeer(&relay, 2, 43)
	defer VoiceRelayTestClient_deinit(&alice)
	defer VoiceRelayTestClient_deinit(&bob)
	voiceRelayTestRoute(&relay, 7, {peerId = 1}, {peerId = 2})

	sink.failSends = true
	assert(voiceRelayTestSendFrame(&relay, &sink, &alice, 7) == 0, "expected the send to fail")
	assert(
		relay.stats.sendFailures == 1 && relay.stats.datagramsOut == 0,
		fmt.tprintf("expected one send failure, got %v", relay.stats),
	)
}

@(test)
testVoiceRelayPublishesStatsOnlyWhenTheyChange :: proc(t: ^testing.T) {
	_ = t
	sink: VoiceRelayTestSink
	relay: VoiceRelay
	voiceRelayTestInit(&relay, &sink)
	defer voiceRelayTestDeinit(&relay, &sink)

	published: VoiceRelayStats
	VoiceRelay_handleDatagram(&relay, 9, []u8{1})
	VoiceRelay_publishStats(&relay, &published)
	loaded := VoiceRelayStats_load(&published)
	assert(
		loaded.datagramsIn == 1 && loaded.drops[.UnknownPeer] == 1,
		fmt.tprintf("expected the published counters, got %v", loaded),
	)
	assert(!relay.statsDirty, "expected publishing to clear the dirty flag")
}

// Channel 2 never reaches the router: handlePeerData hands it to the relay and queues nothing.
@(test)
testHandlePeerDataGivesVoiceDatagramsToTheRelayNotTheRouter :: proc(t: ^testing.T) {
	_ = t
	mainFd, networkFd := networkTestInitNetworkIPC("voice_relay_test_network")
	defer networkTestResetIPCState()
	peerManager := PeerManager_init()
	defer PeerManager_deinit(&peerManager)

	sink: VoiceRelayTestSink
	relay: VoiceRelay
	voiceRelayTestInit(&relay, &sink)
	defer voiceRelayTestDeinit(&relay, &sink)

	enetPeer := ENet.Peer{}
	enetPeer.data = rawptr(uintptr(42))
	packet := networkTestCreatePacket([]u8{1, 2, 3, 4})
	handlePeerData(
		&peerManager,
		&enetPeer,
		packet,
		u8(NetworkChannel.Voice),
		int(networkFd),
		&relay,
	)

	_, err := IPC_Client_poll(mainFd)
	assert(err != nil, "expected no IPC message for a voice datagram")
	assert(
		relay.stats.datagramsIn == 1 && relay.stats.drops[.UnknownPeer] == 1,
		fmt.tprintf("expected the relay to count the datagram, got %v", relay.stats),
	)
}

// The drain hands the voice commands to their handlers and wipes a session's keys afterwards,
// whether or not a handler took them, so none linger in the queue or the popped message.
@(test)
testNetworkDrainHandsVoiceCommandsToTheRelay :: proc(t: ^testing.T) {
	_ = t
	mainFd, networkFd := networkTestInitNetworkIPC("voice_relay_drain_test_network")
	defer networkTestResetIPCState()

	sink: VoiceRelayTestSink
	relay: VoiceRelay
	voiceRelayTestInit(&relay, &sink)
	defer voiceRelayTestDeinit(&relay, &sink)

	session := NetworkVoiceSessionOpen {
		peerId = 5,
		userId = 42,
	}
	session.send = common.ChannelSendState {
		key    = 0xAB,
		active = true,
	}
	session.receive = common.VoiceReceiveState {
		key    = 0xCD,
		active = true,
	}
	members := make([]NetworkVoiceRouteMember, 1)
	members[0] = {peerId = 5, muted = true}
	mainCtx := IPC_Server_Context{}
	IPC_Server_send(&mainCtx, networkFd, session)
	IPC_Server_send(&mainCtx, networkFd, NetworkVoiceRoute{roomId = 7, members = members})
	_ = mainFd

	handlers := NetworkIPCHandlers {
		userData = &relay,
		voiceSessionOpen = proc(userData: rawptr, msg: ^NetworkVoiceSessionOpen) {
			VoiceRelay_openSession(cast(^VoiceRelay)userData, msg)
		},
		voiceRoute = proc(userData: rawptr, msg: NetworkVoiceRoute) {
			VoiceRelay_applyRoute(cast(^VoiceRelay)userData, msg.roomId, msg.members)
		},
		voiceReset = proc(userData: rawptr) {
			VoiceRelay_reset(cast(^VoiceRelay)userData)
		},
	}
	result := networkDrainIPC(networkFd, handlers)
	assert(result.processed == 2, fmt.tprintf("expected two commands, got %v", result))
	peer, ok := relay.peers[5]
	assert(ok && peer.roomId == 7 && peer.muted, "expected the session open and routed, muted")
	assert(peer.send.key[0] == 0xAB, "expected the relay to hold the send key")

	// The queue's slots never keep a copy of the keys once popped.
	networkQueue := &ipcState.network_queue
	for &item in networkQueue.items {
		bytes := ([^]u8)(rawptr(&item))[:size_of(item)]
		for b in bytes {
			assert(b != 0xAB && b != 0xCD, "expected popped slots to hold no key bytes")
		}
	}

	IPC_Server_send(&mainCtx, networkFd, NetworkVoiceReset{})
	networkDrainIPC(networkFd, handlers)
	assert(len(relay.peers) == 0, "expected the reset to forget the session")
}

@(test)
testIPCMessageDeinitWipesVoiceSessionKeys :: proc(t: ^testing.T) {
	_ = t
	msg: Message = NetworkVoiceSessionOpen {
		peerId = 1,
		send = common.ChannelSendState{key = 0xAB, nextSequence = 9, active = true},
		receive = common.VoiceReceiveState{key = 0xCD, active = true},
	}
	payload := &msg.(NetworkVoiceSessionOpen)
	IPC__message_deinit(&msg)
	zeroSend: common.ChannelSendState
	zeroReceive: common.VoiceReceiveState
	assert(
		payload.send == zeroSend && payload.receive == zeroReceive,
		"expected IPC__message_deinit to wipe both voice halves in place",
	)
}
