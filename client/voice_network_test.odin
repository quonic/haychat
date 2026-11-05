#+feature dynamic-literals
package client

import "../common"
import "core:fmt"
import "core:sync"
import "core:testing"
import "core:time"
import "vendor:ENet"

// ── Helpers ───────────────────────────────────────────────────────

voiceDatagramSendBridgeTestMutex: sync.Mutex
VOICE_DATAGRAM_TEST_CAPACITY :: 8
voiceDatagramTestCaptured: [VOICE_DATAGRAM_TEST_CAPACITY][common.VOICE_DATAGRAM_MAX_SIZE]u8
voiceDatagramTestLengths: [VOICE_DATAGRAM_TEST_CAPACITY]int
voiceDatagramTestCount: int
voiceDatagramTestReturnValue: bool

voiceDatagramSendBridgeTestStub :: proc(
	transport: ^ClientServerTransport,
	datagram: []u8,
) -> bool {
	if voiceDatagramTestCount < VOICE_DATAGRAM_TEST_CAPACITY {
		voiceDatagramTestLengths[voiceDatagramTestCount] = copy(
			voiceDatagramTestCaptured[voiceDatagramTestCount][:],
			datagram,
		)
	}
	voiceDatagramTestCount += 1
	return voiceDatagramTestReturnValue
}

// Builds a client transport and the server's matching state for one established session,
// with the connection marked Established in session generation 1.
@(private = "file")
testVoiceTransportPair :: proc(
	serverID: int,
) -> (
	config: Config,
	transport: ClientServerTransport,
	serverTransport: common.TransportState,
) {
	server := Server {
		id   = serverID,
		name = "Voice Net",
		host = "localhost",
		port = common.DEFAULT_SERVER_PORT,
	}
	config = testConfigWithServers({server})
	ok: bool
	transport, serverTransport, ok = buildEstablishedTransportPair(server, config)
	assert(ok, "expected transport pair setup to succeed")
	transport.connection.status = .Established
	transport.sessionGeneration = 1
	return
}

// Seals plaintext as the server would for this client.
@(private = "file")
testSealForClient :: proc(
	serverTransport: ^common.TransportState,
	plaintext: []u8,
	dst: []u8,
) -> []u8 {
	length, ok := common.sealVoiceDatagram(
		&serverTransport.voiceSend,
		serverTransport.sessionID,
		plaintext,
		dst,
	)
	assert(ok, "expected the server-side seal to succeed")
	return dst[:length]
}

@(private = "file")
testSealServerFrame :: proc(
	serverTransport: ^common.TransportState,
	frame: common.ServerVoiceFrame,
	dst: []u8,
) -> []u8 {
	plaintext: [common.SERVER_VOICE_FRAME_MAX_SIZE]u8
	length, ok := common.encodeServerVoiceFrame(frame, plaintext[:])
	assert(ok, "expected the server frame to encode")
	return testSealForClient(serverTransport, plaintext[:length], dst)
}

// An opened engine that accepts inbound frames and is never stepped.
@(private = "file")
testOpenedInboundEngine :: proc() -> ^VoiceEngine {
	engine := VoiceEngine_create(
		{source = {kind = .Silence}, sink = {kind = .Null}, unpaced = true},
	)
	assert(VoiceEngine_open(engine), "expected a silence/null engine to open")
	return engine
}

TEST_VOICE_OPUS := [?]u8{0xF8, 0x01, 0x02, 0x03, 0x04}

// ── Receive path ──────────────────────────────────────────────────

// A datagram the server sealed for this session reaches the bound engine's inbound queue with
// its sender, sequence, flags and Opus bytes. Every bad datagram is counted by reason, none of
// them ends the session, and nothing is delivered without a live binding for the room.
@(test)
testVoiceReceivePathDeliversServerFramesAndCountsDrops :: proc(t: ^testing.T) {
	if !voiceTestOpusAvailable(t) {
		return
	}
	config, transport, serverTransport := testVoiceTransportPair(301)
	defer Config_deinit(&config)
	defer ClientServerTransport_deinit(&transport)
	engine := testOpenedInboundEngine()
	defer VoiceEngine_destroy(engine)
	transport.voice = {engine = engine, roomID = 3, sessionGeneration = 1}

	buffer: [common.VOICE_DATAGRAM_MAX_SIZE]u8
	frame := common.ServerVoiceFrame {
		roomId        = 3,
		senderUserId  = 9,
		frameSequence = 42,
		flags         = common.VOICE_FRAME_FLAG_END_OF_SPURT,
		opus          = TEST_VOICE_OPUS[:],
	}
	datagram := testSealServerFrame(&serverTransport, frame, buffer[:])
	ClientServerTransport_receiveVoiceDatagram(&transport, datagram)
	stats := &transport.voiceStats
	testing.expectf(
		t,
		stats.framesDelivered == 1 && engine.inboundCount == 1,
		"expected one delivered frame, got %d delivered and %d queued",
		stats.framesDelivered,
		engine.inboundCount,
	)
	queued := engine.inbound[engine.inboundHead]
	testing.expect(
		t,
		queued.senderUserID == 9 &&
		queued.frameSequence == 42 &&
		queued.flags == common.VOICE_FRAME_FLAG_END_OF_SPURT &&
		string(queued.data[:queued.length]) == string(TEST_VOICE_OPUS[:]),
		"expected the queued frame to keep the sender, sequence, flags and Opus bytes",
	)

	// The same datagram again is a replay.
	ClientServerTransport_receiveVoiceDatagram(&transport, datagram)
	// A flipped byte breaks the tag.
	tampered := testSealServerFrame(&serverTransport, frame, buffer[:])
	tampered[len(tampered) - 1] ~= 0xFF
	ClientServerTransport_receiveVoiceDatagram(&transport, tampered)
	// Too short to be a datagram, and an unknown kind.
	ClientServerTransport_receiveVoiceDatagram(&transport, {0x01, 0x02, 0x03})
	unknownKind := testSealServerFrame(&serverTransport, frame, buffer[:])
	unknownKind[0] = 0x7F
	ClientServerTransport_receiveVoiceDatagram(&transport, unknownKind)
	// Opened fine, but not a ServerVoiceFrame: a truncated header, then a header alone.
	header: [common.SERVER_VOICE_FRAME_HEADER_SIZE]u8
	ClientServerTransport_receiveVoiceDatagram(
		&transport,
		testSealForClient(&serverTransport, header[:5], buffer[:]),
	)
	ClientServerTransport_receiveVoiceDatagram(
		&transport,
		testSealForClient(&serverTransport, header[:], buffer[:]),
	)
	// A frame for another room.
	otherRoom := frame
	otherRoom.roomId = 4
	ClientServerTransport_receiveVoiceDatagram(
		&transport,
		testSealServerFrame(&serverTransport, otherRoom, buffer[:]),
	)
	// A binding from an earlier session is dead in this one.
	transport.voice.sessionGeneration = 0
	ClientServerTransport_receiveVoiceDatagram(
		&transport,
		testSealServerFrame(&serverTransport, frame, buffer[:]),
	)
	transport.voice.sessionGeneration = 1
	// A deafened engine refuses frames.
	VoiceEngine_setDeafened(engine, true)
	ClientServerTransport_receiveVoiceDatagram(
		&transport,
		testSealServerFrame(&serverTransport, frame, buffer[:]),
	)
	VoiceEngine_setDeafened(engine, false)

	dropped := stats.receiveDropped
	expected := [ClientVoiceReceiveDropReason]u64 {
		.Malformed      = 2,
		.Replayed       = 1,
		.TooOld         = 0,
		.BadTag         = 1,
		.Inactive       = 0,
		.FrameTruncated = 1,
		.FrameEmpty     = 1,
		.FrameTooLarge  = 0,
		.NotJoined      = 1,
		.WrongRoom      = 1,
		.EngineRefused  = 1,
		.BeforeSession  = 0,
		.WrongChannel   = 0,
	}
	for reason in ClientVoiceReceiveDropReason {
		testing.expectf(
			t,
			dropped[reason] == expected[reason],
			"expected %d datagrams dropped as %v, got %d",
			expected[reason],
			reason,
			dropped[reason],
		)
	}
	testing.expectf(
		t,
		stats.datagramsReceived == 10 && stats.framesDelivered == 1 && engine.inboundCount == 1,
		"expected 10 datagrams seen and still only one delivered, got %d and %d",
		stats.datagramsReceived,
		stats.framesDelivered,
	)
	testing.expect(
		t,
		transport.transport.phase == .Established && transport.connection.status == .Established,
		"expected no voice datagram to end the session",
	)

	// The session's next good frame is still delivered.
	next := frame
	next.frameSequence = 43
	ClientServerTransport_receiveVoiceDatagram(
		&transport,
		testSealServerFrame(&serverTransport, next, buffer[:]),
	)
	testing.expect(t, stats.framesDelivered == 2, "expected a later good frame to be delivered")
	common.TransportState_deinit(&serverTransport)
}

// Runs the established-session service loop over a real ENet connection on the loopback
// interface: a voice datagram on channel 2 goes to the engine and never becomes a runtime
// event, a packet on channel 3 is counted and dropped, and the control packet sent with them
// still comes out as the only event.
@(test)
testEstablishedSessionRoutesVoiceDatagramsWithoutEvents :: proc(t: ^testing.T) {
	if !voiceTestOpusAvailable(t) {
		return
	}
	testing.set_fail_timeout(t, 30 * time.Second)
	assert(clientEnsureENetInitialized(), "expected ENet to initialise")
	listen := ENet.Address{}
	assert(ENet.address_set_host(&listen, "127.0.0.1") == 0, "expected 127.0.0.1 to resolve")
	serverHost := ENet.host_create(&listen, 2, STARTUP_AUTH_CHANNEL_COUNT, 0, 0)
	assert(serverHost != nil, "expected a loopback ENet server host")
	defer ENet.host_destroy(serverHost)
	target := listen
	target.port = serverHost.address.port
	assert(target.port != 0, "expected the server host to report its bound port")

	config, transport, serverTransport := testVoiceTransportPair(302)
	defer Config_deinit(&config)
	defer ClientServerTransport_deinit(&transport)
	defer common.TransportState_deinit(&serverTransport)
	transport.enetHost = ENet.host_create(nil, 1, STARTUP_AUTH_CHANNEL_COUNT, 0, 0)
	assert(transport.enetHost != nil, "expected a client ENet host")
	transport.enetPeer = ENet.host_connect(
		transport.enetHost,
		&target,
		STARTUP_AUTH_CHANNEL_COUNT,
		0,
	)
	assert(transport.enetPeer != nil, "expected the client to start connecting")

	serverPeer: ^ENet.Peer
	clientConnected := false
	start := time.tick_now()
	for (serverPeer == nil || !clientConnected) && time.tick_since(start) < 5 * time.Second {
		event: ENet.Event
		for ENet.host_service(serverHost, &event, 0) > 0 {
			if event.type == .CONNECT {
				serverPeer = event.peer
			} else if event.type == .RECEIVE {
				ENet.packet_destroy(event.packet)
			}
		}
		for ENet.host_service(transport.enetHost, &event, 0) > 0 {
			if event.type == .CONNECT {
				clientConnected = true
			}
		}
		time.sleep(time.Millisecond)
	}
	assert(serverPeer != nil && clientConnected, "expected the loopback ENet connection")

	engine := testOpenedInboundEngine()
	defer VoiceEngine_destroy(engine)
	transport.voice = {engine = engine, roomID = 3, sessionGeneration = 1}

	buffer: [common.VOICE_DATAGRAM_MAX_SIZE]u8
	datagram := testSealServerFrame(
		&serverTransport,
		{roomId = 3, senderUserId = 9, frameSequence = 7, opus = TEST_VOICE_OPUS[:]},
		buffer[:],
	)
	voicePacket := ENet.packet_create(raw_data(datagram), uint(len(datagram)), {.UNSEQUENCED})
	assert(ENet.peer_send(serverPeer, STARTUP_AUTH_CHANNEL_VOICE, voicePacket) == 0, "voice")
	junk := [?]u8{0xA1, 0x00}
	junkPacket := ENet.packet_create(raw_data(junk[:]), len(junk), {.RELIABLE})
	assert(ENet.peer_send(serverPeer, 3, junkPacket) == 0, "expected channel 3 to send")
	sealed, sealOK := common.sealPacketForSession(
		&serverTransport,
		.ServerVoiceLeft,
		common.ServerVoiceLeftPayload{roomId = 3, reason = "test"},
	)
	assert(sealOK, "expected the control packet to seal")
	controlBytes, bytesOK := common.marshalPacket(sealed)
	delete(sealed.payload)
	assert(bytesOK, "expected the control packet to marshal")
	controlPacket := ENet.packet_create(raw_data(controlBytes), len(controlBytes), {.RELIABLE})
	delete(controlBytes)
	assert(ENet.peer_send(serverPeer, STARTUP_AUTH_CHANNEL_CHAT, controlPacket) == 0, "ctl")
	ENet.host_flush(serverHost)

	eventCount := 0
	gotVoiceLeft := false
	start = time.tick_now()
	for time.tick_since(start) < 5 * time.Second {
		serverEvent: ENet.Event
		for ENet.host_service(serverHost, &serverEvent, 0) > 0 {
			if serverEvent.type == .RECEIVE {
				ENet.packet_destroy(serverEvent.packet)
			}
		}
		event, hasEvent := ClientServerTransport_serviceEstablishedSession(
			&transport,
			time.tick_now(),
		)
		if hasEvent {
			eventCount += 1
			gotVoiceLeft ||= event.kind == .VoiceLeft && event.roomID == 3
			ClientTransportRuntimeEvent_deinit(&event)
		}
		if gotVoiceLeft &&
		   transport.voiceStats.framesDelivered == 1 &&
		   transport.voiceStats.receiveDropped[.WrongChannel] == 1 {
			break
		}
		time.sleep(time.Millisecond)
	}
	testing.expectf(
		t,
		eventCount == 1 && gotVoiceLeft,
		"expected the control packet as the only runtime event, got %d events (VoiceLeft %v)",
		eventCount,
		gotVoiceLeft,
	)
	testing.expectf(
		t,
		transport.voiceStats.framesDelivered == 1 && engine.inboundCount == 1,
		"expected the voice datagram in the engine's queue, got %d delivered, %d queued",
		transport.voiceStats.framesDelivered,
		engine.inboundCount,
	)
	testing.expectf(
		t,
		transport.voiceStats.receiveDropped[.WrongChannel] == 1,
		"expected the channel 3 packet counted, got %d",
		transport.voiceStats.receiveDropped[.WrongChannel],
	)
	testing.expect(
		t,
		ClientServerTransport_isConnected(&transport),
		"expected the session to stay up",
	)
}

// ── Send path ─────────────────────────────────────────────────────

// An outbound frame is sealed with the session's voice send state into a datagram that the
// server's receive state opens and decodes back to the same frame, named for the joined room.
// Frames for a dead binding are dropped and counted without consuming a sequence.
@(test)
testVoiceSendPathSealsFramesTheServerCanOpen :: proc(t: ^testing.T) {
	config, transport, serverTransport := testVoiceTransportPair(303)
	defer Config_deinit(&config)
	defer ClientServerTransport_deinit(&transport)
	defer common.TransportState_deinit(&serverTransport)
	// Never opened: the send path only compares the pointer.
	engine := VoiceEngine_create({})
	defer VoiceEngine_destroy(engine)
	link := new(ClientVoiceLink)
	defer free(link)
	link.transport = &transport
	link.engine = engine
	link.roomID = 6
	transport.voice = {engine = engine, roomID = 6, sessionGeneration = 1}

	sync.mutex_lock(&voiceDatagramSendBridgeTestMutex)
	defer sync.mutex_unlock(&voiceDatagramSendBridgeTestMutex)
	voiceDatagramSendBridge = voiceDatagramSendBridgeTestStub
	defer voiceDatagramSendBridge = ClientServerTransport_sendVoiceDatagram
	voiceDatagramTestCount = 0
	voiceDatagramTestReturnValue = true

	frames := [?]VoiceOutboundFrame {
		{
			frameSequence = 100,
			flags = common.VOICE_FRAME_FLAG_FEC_PRESENT,
			opus = TEST_VOICE_OPUS[:],
		},
		{
			frameSequence = 101,
			flags = common.VOICE_FRAME_FLAG_END_OF_SPURT,
			opus = TEST_VOICE_OPUS[:3],
		},
	}
	// Through the engine's outbound seam, with no worker (the lock is then a no-op).
	clientVoiceOutbound(link, frames[0])
	testing.expect(
		t,
		ClientServerTransport_sendVoiceFrame(&transport, link, frames[1]),
		"expected a bound frame to be sent",
	)
	testing.expectf(
		t,
		voiceDatagramTestCount == 2 && transport.voiceStats.framesSent == 2,
		"expected two datagrams sent, got %d",
		voiceDatagramTestCount,
	)
	for index in 0 ..< min(voiceDatagramTestCount, len(frames)) {
		datagram := voiceDatagramTestCaptured[index][:voiceDatagramTestLengths[index]]
		plaintext: [common.CLIENT_VOICE_FRAME_MAX_SIZE]u8
		length, result := common.openVoiceDatagram(
			&serverTransport.voiceReceive,
			serverTransport.sessionID,
			datagram,
			plaintext[:],
		)
		testing.expectf(t, result == .Ok, "expected datagram %d to open, got %v", index, result)
		decoded, decodeResult := common.decodeClientVoiceFrame(plaintext[:length])
		want := frames[index]
		testing.expectf(
			t,
			decodeResult == .Ok &&
			decoded.roomId == 6 &&
			decoded.frameSequence == want.frameSequence &&
			decoded.flags == want.flags &&
			string(decoded.opus) == string(want.opus),
			"expected datagram %d to decode back to its frame, got %v",
			index,
			decoded,
		)
	}

	// A binding for another room, from an earlier session, for another engine, or none at all
	// sends nothing; neither does a session that is not established.
	sequenceBefore := transport.transport.voiceSend.nextSequence
	transport.voice.roomID = 7
	ClientServerTransport_sendVoiceFrame(&transport, link, frames[0])
	transport.voice = {engine = engine, roomID = 6, sessionGeneration = 0}
	ClientServerTransport_sendVoiceFrame(&transport, link, frames[0])
	transport.voice = {}
	ClientServerTransport_sendVoiceFrame(&transport, link, frames[0])
	transport.voice = {engine = engine, roomID = 6, sessionGeneration = 1}
	transport.connection.status = .Disconnected
	ClientServerTransport_sendVoiceFrame(&transport, link, frames[0])
	transport.connection.status = .Established
	testing.expectf(
		t,
		transport.voiceStats.sendDropped[.NotJoined] == 4 &&
		transport.transport.voiceSend.nextSequence == sequenceBefore &&
		voiceDatagramTestCount == 2,
		"expected 4 unbound frames dropped without a seal, got %d",
		transport.voiceStats.sendDropped[.NotJoined],
	)

	// ENet refusing the packet is counted and leaves the session alone.
	voiceDatagramTestReturnValue = false
	testing.expect(
		t,
		!ClientServerTransport_sendVoiceFrame(&transport, link, frames[0]),
		"expected a refused send to report failure",
	)
	testing.expect(
		t,
		transport.voiceStats.sendDropped[.SendFailed] == 1 &&
		transport.transport.phase == .Established,
		"expected the failed send counted and the session kept",
	)

	// A reconnect activates new keys and a new generation: the old binding is dead, so a
	// frame from the voice thread can never be sealed into the new session.
	transport.sessionGeneration = 2
	voiceDatagramTestReturnValue = true
	testing.expect(
		t,
		!ClientServerTransport_sendVoiceFrame(&transport, link, frames[0]),
		"expected a binding from the previous session to send nothing",
	)
	testing.expect(
		t,
		transport.voiceStats.sendDropped[.NotJoined] == 5,
		fmt.tprintf(
			"expected 5 NotJoined drops, got %d",
			transport.voiceStats.sendDropped[.NotJoined],
		),
	)
}
