package server

import "../common"
import "core:fmt"
import "core:testing"

// The relay's encrypted path (protocol 21, e2ee-voice-design.md 6): a route marked encrypted
// forwards sealed payloads byte for byte, without the Opus TOC check it cannot make, drops
// payloads that are not sealed, and applies the frame size limit to the Opus bytes inside. The
// unencrypted tests in voice_relay_test.odin run unchanged.

// A sealed payload with opusLength bytes of ciphertext: the version byte, a key ID, then bytes
// the relay cannot read.
@(private = "file")
voiceRelayE2EETestPayload :: proc(opusLength: int, buffer: []u8) -> []u8 {
	total := opusLength + common.VOICE_E2EE_OVERHEAD
	payload := buffer[:total]
	payload[0] = common.VOICE_E2EE_VERSION
	payload[1] = 7
	for index in 2 ..< total {
		payload[index] = u8(index * 31 + 5)
	}
	return payload
}

// Sends payload as alice's frame and returns what bob got (empty when nothing reached him).
@(private = "file")
voiceRelayE2EETestRelay :: proc(
	relay: ^VoiceRelay,
	sink: ^VoiceRelayTestSink,
	alice, bob: ^VoiceRelayTestClient,
	sequence: u32,
	payload: []u8,
	out: []u8,
) -> []u8 {
	before := len(sink.sent)
	buffer: [common.VOICE_DATAGRAM_MAX_SIZE]u8
	datagram := voiceRelayTestSealFrame(alice, 9, sequence, 0x02, payload, buffer[:])
	VoiceRelay_handleDatagram(relay, alice.peerId, datagram)
	if len(sink.sent) == before {
		return nil
	}
	sent := sink.sent[len(sink.sent) - 1]
	assert(sent.peerId == bob.peerId, "expected the frame to go to bob")
	plaintext: [common.SERVER_VOICE_FRAME_MAX_SIZE]u8
	n, openResult := common.openVoiceDatagram(
		&bob.transport.voiceReceive,
		bob.sessionID,
		sent.data[:sent.length],
		plaintext[:],
	)
	assert(openResult == .Ok, fmt.tprintf("expected bob to open the datagram, got %v", openResult))
	frame, frameResult := common.decodeServerVoiceFrame(plaintext[:n])
	assert(frameResult == .Ok, "expected a server frame")
	assert(
		frame.roomId == 9 &&
		frame.senderUserId == u32(alice.userId) &&
		frame.frameSequence == sequence &&
		frame.flags == 0x02,
		fmt.tprintf("expected the header copied unchanged, got %v", frame),
	)
	return out[:copy(out, frame.opus)]
}

@(test)
testVoiceRelayForwardsSealedPayloadsUnchangedInEncryptedRooms :: proc(t: ^testing.T) {
	_ = t
	sink: VoiceRelayTestSink
	relay: VoiceRelay
	voiceRelayTestInit(&relay, &sink, maxFrameBytes = 64)
	defer voiceRelayTestDeinit(&relay, &sink)
	alice := voiceRelayTestOpenPeer(&relay, 1, 42)
	bob := voiceRelayTestOpenPeer(&relay, 2, 43)
	defer VoiceRelayTestClient_deinit(&alice)
	defer VoiceRelayTestClient_deinit(&bob)
	members := [2]NetworkVoiceRouteMember{{peerId = 1}, {peerId = 2}}
	VoiceRelay_applyRoute(&relay, 9, members[:], encrypted = true)

	buffer: [common.VOICE_OPUS_MAX_BYTES]u8
	out: [common.VOICE_OPUS_MAX_BYTES]u8
	// No TOC check: the first ciphertext byte describes no 20 ms packet, and it still goes.
	payload := voiceRelayE2EETestPayload(40, buffer[:])
	got := voiceRelayE2EETestRelay(&relay, &sink, &alice, &bob, 1, payload, out[:])
	assert(string(got) == string(payload), "expected the sealed payload byte for byte")

	// The size limit counts the Opus bytes inside: 64 fits (82 bytes on the wire), 65 does not.
	payload = voiceRelayE2EETestPayload(64, buffer[:])
	got = voiceRelayE2EETestRelay(&relay, &sink, &alice, &bob, 2, payload, out[:])
	assert(string(got) == string(payload), "expected 64 Opus bytes to be forwarded")
	payload = voiceRelayE2EETestPayload(65, buffer[:])
	got = voiceRelayE2EETestRelay(&relay, &sink, &alice, &bob, 3, payload, out[:])
	assert(got == nil && relay.stats.drops[.Oversize] == 1, "expected 65 Opus bytes dropped")

	// Not sealed: plaintext Opus, the overhead alone, and another version.
	plain := VOICE_RELAY_TEST_OPUS
	got = voiceRelayE2EETestRelay(&relay, &sink, &alice, &bob, 4, plain[:], out[:])
	assert(got == nil, "expected plaintext Opus never to reach a listener")
	payload = voiceRelayE2EETestPayload(0, buffer[:])
	got = voiceRelayE2EETestRelay(&relay, &sink, &alice, &bob, 5, payload, out[:])
	assert(got == nil, "expected a payload without Opus bytes dropped")
	payload = voiceRelayE2EETestPayload(20, buffer[:])
	payload[0] = 2
	got = voiceRelayE2EETestRelay(&relay, &sink, &alice, &bob, 6, payload, out[:])
	assert(got == nil, "expected a version 2 payload dropped")
	assert(
		relay.stats.drops[.NotSealed] == 3 && relay.stats.drops[.BadDuration] == 0,
		fmt.tprintf("expected three NotSealed drops and no TOC check, got %v", relay.stats.drops),
	)
	assert(VoiceRelay_hasPeer(&relay, 1), "expected the sender to stay connected")

	// The mute check still applies.
	muted := [2]NetworkVoiceRouteMember{{peerId = 1, muted = true}, {peerId = 2}}
	VoiceRelay_applyRoute(&relay, 9, muted[:], encrypted = true)
	payload = voiceRelayE2EETestPayload(20, buffer[:])
	got = voiceRelayE2EETestRelay(&relay, &sink, &alice, &bob, 7, payload, out[:])
	assert(got == nil && relay.stats.drops[.Muted] == 1, "expected a muted sender dropped")

	// The same room routed unencrypted is back to the TOC check (a 40 ms packet is refused).
	VoiceRelay_applyRoute(&relay, 9, members[:])
	fortyMS := [4]u8{0x10, 1, 2, 3}
	got = voiceRelayE2EETestRelay(&relay, &sink, &alice, &bob, 8, fortyMS[:], out[:])
	assert(got == nil && relay.stats.drops[.BadDuration] == 1, "expected the TOC check back")
	got = voiceRelayE2EETestRelay(&relay, &sink, &alice, &bob, 9, plain[:], out[:])
	assert(string(got) == string(plain[:]), "expected plain Opus relayed in a plain room")
}

@(test)
testVoiceRelayEncryptedFlagFollowsTheRoute :: proc(t: ^testing.T) {
	_ = t
	sink: VoiceRelayTestSink
	relay: VoiceRelay
	voiceRelayTestInit(&relay, &sink)
	defer voiceRelayTestDeinit(&relay, &sink)
	alice := voiceRelayTestOpenPeer(&relay, 1, 42)
	defer VoiceRelayTestClient_deinit(&alice)
	members := [1]NetworkVoiceRouteMember{{peerId = 1}}
	VoiceRelay_applyRoute(&relay, 9, members[:], encrypted = true)
	assert(relay.peers[1].encrypted, "expected the peer marked as in an encrypted room")
	// Moving to a plain room clears it; an empty route does too.
	VoiceRelay_applyRoute(&relay, 10, members[:])
	assert(!relay.peers[1].encrypted && relay.peers[1].roomId == 10, "expected a plain room")
	VoiceRelay_applyRoute(&relay, 10, members[:], encrypted = true)
	VoiceRelay_applyRoute(&relay, 10, nil, encrypted = true)
	assert(!relay.peers[1].encrypted && relay.peers[1].roomId == 0, "expected no room")
}
