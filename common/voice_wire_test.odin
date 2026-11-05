package common

import "core:encoding/cbor"
import "core:fmt"
import "core:testing"

@(private = "file")
testOpusBytes :: proc(buffer: []u8) -> []u8 {
	for index in 0 ..< len(buffer) {
		buffer[index] = u8(index * 7 + 3)
	}
	return buffer
}

@(test)
testVoiceFrameSizes :: proc(t: ^testing.T) {
	_ = t
	assert(CLIENT_VOICE_FRAME_HEADER_SIZE == 9, "expected a 9-byte client frame header")
	assert(SERVER_VOICE_FRAME_HEADER_SIZE == 13, "expected a 13-byte server frame header")
	assert(VOICE_OPUS_MAX_BYTES == 512, "expected at most 512 Opus bytes per frame")
	assert(VOICE_FRAME_SAMPLES == 960, "expected 960 samples (20 ms at 48 kHz) per frame")
	assert(VOICE_FRAME_FLAG_END_OF_SPURT == 0x01, "expected END_OF_SPURT to be bit 0")
	assert(VOICE_FRAME_FLAG_FEC_PRESENT == 0x02, "expected FEC_PRESENT to be bit 1")
	assert(
		VOICE_DATAGRAM_MAX_SIZE == 25 + 13 + 512,
		fmt.tprintf("expected a 550-byte largest datagram, got %d", VOICE_DATAGRAM_MAX_SIZE),
	)
}

@(test)
testClientVoiceFrameLayoutAndRoundTrip :: proc(t: ^testing.T) {
	_ = t
	opusStorage: [60]u8
	opus := testOpusBytes(opusStorage[:])
	frame := ClientVoiceFrame {
		roomId        = 0x04030201,
		frameSequence = 0x08070605,
		flags         = VOICE_FRAME_FLAG_END_OF_SPURT | VOICE_FRAME_FLAG_FEC_PRESENT,
		opus          = opus,
	}
	buffer: [CLIENT_VOICE_FRAME_MAX_SIZE]u8
	n, ok := encodeClientVoiceFrame(frame, buffer[:])
	assert(ok && n == 9 + 60, fmt.tprintf("expected a 69-byte client frame, got %d (%v)", n, ok))
	expectedHeader := [9]u8{1, 2, 3, 4, 5, 6, 7, 8, 0x03}
	for index in 0 ..< 9 {
		assert(
			buffer[index] == expectedHeader[index],
			fmt.tprintf(
				"expected client header byte %d to be %d, got %d",
				index,
				expectedHeader[index],
				buffer[index],
			),
		)
	}
	assert(string(buffer[9:n]) == string(opus), "expected the Opus bytes after the header")

	decoded, result := decodeClientVoiceFrame(buffer[:n])
	assert(result == .Ok, fmt.tprintf("expected the client frame to decode, got %v", result))
	assert(
		decoded.roomId == frame.roomId &&
		decoded.frameSequence == frame.frameSequence &&
		decoded.flags == frame.flags,
		fmt.tprintf("expected %v, got %v", frame, decoded),
	)
	assert(string(decoded.opus) == string(opus), "expected the Opus payload to survive")
	assert(
		raw_data(decoded.opus) == &buffer[9],
		"expected the decoded Opus slice to borrow the input buffer, not copy it",
	)
}

@(test)
testServerVoiceFrameLayoutAndRoundTrip :: proc(t: ^testing.T) {
	_ = t
	opusStorage: [VOICE_OPUS_MAX_BYTES]u8
	opus := testOpusBytes(opusStorage[:])
	frame := ServerVoiceFrame {
		roomId        = 0x04030201,
		senderUserId  = 0x0C0B0A09,
		frameSequence = 0x08070605,
		flags         = VOICE_FRAME_FLAG_FEC_PRESENT,
		opus          = opus,
	}
	buffer: [SERVER_VOICE_FRAME_MAX_SIZE]u8
	n, ok := encodeServerVoiceFrame(frame, buffer[:])
	assert(
		ok && n == SERVER_VOICE_FRAME_MAX_SIZE,
		fmt.tprintf("expected a %d-byte server frame, got %d", SERVER_VOICE_FRAME_MAX_SIZE, n),
	)
	expectedHeader := [13]u8{1, 2, 3, 4, 9, 10, 11, 12, 5, 6, 7, 8, 0x02}
	for index in 0 ..< 13 {
		assert(
			buffer[index] == expectedHeader[index],
			fmt.tprintf(
				"expected server header byte %d to be %d, got %d",
				index,
				expectedHeader[index],
				buffer[index],
			),
		)
	}

	decoded, result := decodeServerVoiceFrame(buffer[:n])
	assert(result == .Ok, fmt.tprintf("expected the server frame to decode, got %v", result))
	assert(
		decoded.roomId == frame.roomId &&
		decoded.senderUserId == frame.senderUserId &&
		decoded.frameSequence == frame.frameSequence &&
		decoded.flags == frame.flags,
		fmt.tprintf("expected %v, got %v", frame, decoded),
	)
	assert(string(decoded.opus) == string(opus), "expected the full 512-byte payload to survive")
	assert(raw_data(decoded.opus) == &buffer[13], "expected the Opus slice to borrow the input")
}

// What the relay does: decode a client frame and re-frame it for recipients in place.
@(test)
testServerVoiceFrameEncodesInPlaceOverAClientFrame :: proc(t: ^testing.T) {
	_ = t
	opusStorage: [40]u8
	opus := testOpusBytes(opusStorage[:])
	buffer: [SERVER_VOICE_FRAME_MAX_SIZE]u8
	clientLength, clientOK := encodeClientVoiceFrame(
		ClientVoiceFrame{roomId = 7, frameSequence = 99, flags = 1, opus = opus},
		buffer[:],
	)
	assert(clientOK, "expected the client frame to encode")
	inbound, inboundResult := decodeClientVoiceFrame(buffer[:clientLength])
	assert(inboundResult == .Ok, "expected the client frame to decode")

	serverLength, serverOK := encodeServerVoiceFrame(
		ServerVoiceFrame {
			roomId = inbound.roomId,
			senderUserId = 42,
			frameSequence = inbound.frameSequence,
			flags = inbound.flags,
			opus = inbound.opus,
		},
		buffer[:],
	)
	assert(serverOK, "expected re-framing over the client frame's own buffer to succeed")
	outbound, outboundResult := decodeServerVoiceFrame(buffer[:serverLength])
	assert(outboundResult == .Ok, "expected the re-framed server frame to decode")
	assert(
		outbound.roomId == 7 &&
		outbound.senderUserId == 42 &&
		outbound.frameSequence == 99 &&
		outbound.flags == 1,
		fmt.tprintf("expected room 7, sender 42, frame 99, flags 1; got %v", outbound),
	)
	assert(string(outbound.opus) == string(opus), "expected the Opus bytes to survive the move")
}

@(test)
testVoiceFrameDecodeRejectsTruncatedEmptyAndOversize :: proc(t: ^testing.T) {
	_ = t
	opusStorage: [20]u8
	opus := testOpusBytes(opusStorage[:])
	clientBuffer: [CLIENT_VOICE_FRAME_MAX_SIZE + 1]u8
	clientLength, _ := encodeClientVoiceFrame(
		ClientVoiceFrame{roomId = 1, opus = opus},
		clientBuffer[:],
	)
	serverBuffer: [SERVER_VOICE_FRAME_MAX_SIZE + 1]u8
	serverLength, _ := encodeServerVoiceFrame(
		ServerVoiceFrame{roomId = 1, opus = opus},
		serverBuffer[:],
	)

	// There is no length field, so every prefix is either too short, empty, or a valid frame
	// with a shorter payload; the AEAD around the frame is what rules out real truncation.
	for length in 0 ..= clientLength {
		frame, result := decodeClientVoiceFrame(clientBuffer[:length])
		expected := VoiceFrameDecodeResult.Ok
		if length < CLIENT_VOICE_FRAME_HEADER_SIZE {
			expected = .Truncated
		} else if length == CLIENT_VOICE_FRAME_HEADER_SIZE {
			expected = .EmptyOpus
		}
		assert(
			result == expected,
			fmt.tprintf("expected a %d-byte client frame: %v, got %v", length, expected, result),
		)
		if result == .Ok {
			assert(
				len(frame.opus) == length - CLIENT_VOICE_FRAME_HEADER_SIZE,
				fmt.tprintf("expected %d Opus bytes, got %d", length - 9, len(frame.opus)),
			)
		} else {
			assert(frame.opus == nil, "expected a failed decode to return no Opus slice")
		}
	}
	for length in 0 ..= serverLength {
		frame, result := decodeServerVoiceFrame(serverBuffer[:length])
		expected := VoiceFrameDecodeResult.Ok
		if length < SERVER_VOICE_FRAME_HEADER_SIZE {
			expected = .Truncated
		} else if length == SERVER_VOICE_FRAME_HEADER_SIZE {
			expected = .EmptyOpus
		}
		assert(
			result == expected,
			fmt.tprintf("expected a %d-byte server frame: %v, got %v", length, expected, result),
		)
		if result != .Ok {
			assert(frame.opus == nil, "expected a failed decode to return no Opus slice")
		}
	}

	// One byte over the Opus maximum, in both directions.
	_, result := decodeClientVoiceFrame(clientBuffer[:CLIENT_VOICE_FRAME_MAX_SIZE + 1])
	assert(result == .OpusTooLarge, fmt.tprintf("expected client OpusTooLarge, got %v", result))
	_, result = decodeClientVoiceFrame(clientBuffer[:CLIENT_VOICE_FRAME_MAX_SIZE])
	assert(result == .Ok, "expected exactly 512 Opus bytes to decode")
	_, result = decodeServerVoiceFrame(serverBuffer[:SERVER_VOICE_FRAME_MAX_SIZE + 1])
	assert(result == .OpusTooLarge, fmt.tprintf("expected server OpusTooLarge, got %v", result))
	_, result = decodeServerVoiceFrame(serverBuffer[:SERVER_VOICE_FRAME_MAX_SIZE])
	assert(result == .Ok, "expected exactly 512 Opus bytes to decode")
}

@(test)
testVoiceFrameEncodeRejectsBadPayloadsAndSmallBuffers :: proc(t: ^testing.T) {
	_ = t
	oversizeStorage: [VOICE_OPUS_MAX_BYTES + 1]u8
	oversize := testOpusBytes(oversizeStorage[:])
	buffer: [SERVER_VOICE_FRAME_MAX_SIZE + 8]u8

	n, ok := encodeClientVoiceFrame(ClientVoiceFrame{roomId = 1}, buffer[:])
	assert(!ok && n == 0, "expected an empty Opus payload to be refused")
	n, ok = encodeClientVoiceFrame(ClientVoiceFrame{roomId = 1, opus = oversize}, buffer[:])
	assert(!ok && n == 0, "expected a 513-byte Opus payload to be refused")
	n, ok = encodeServerVoiceFrame(ServerVoiceFrame{roomId = 1}, buffer[:])
	assert(!ok && n == 0, "expected an empty Opus payload to be refused")
	n, ok = encodeServerVoiceFrame(ServerVoiceFrame{roomId = 1, opus = oversize}, buffer[:])
	assert(!ok && n == 0, "expected a 513-byte Opus payload to be refused")

	opus := oversize[:10]
	small: [CLIENT_VOICE_FRAME_HEADER_SIZE + 10]u8
	for &value in small {
		value = 0xEE
	}
	n, ok = encodeClientVoiceFrame(
		ClientVoiceFrame{roomId = 1, opus = opus},
		small[:len(small) - 1],
	)
	assert(!ok && n == 0, "expected a client buffer one byte short to be refused")
	for value in small {
		assert(value == 0xEE, "expected a refused encode to write nothing")
	}
	n, ok = encodeClientVoiceFrame(ClientVoiceFrame{roomId = 1, opus = opus}, small[:])
	assert(ok && n == len(small), "expected an exactly sized client buffer to be enough")

	serverSmall: [SERVER_VOICE_FRAME_HEADER_SIZE + 10]u8
	n, ok = encodeServerVoiceFrame(
		ServerVoiceFrame{roomId = 1, opus = opus},
		serverSmall[:len(serverSmall) - 1],
	)
	assert(!ok && n == 0, "expected a server buffer one byte short to be refused")
	n, ok = encodeServerVoiceFrame(ServerVoiceFrame{roomId = 1, opus = opus}, serverSmall[:])
	assert(ok && n == len(serverSmall), "expected an exactly sized server buffer to be enough")
}

@(test)
testVoiceFrameFlagsKeepEveryBit :: proc(t: ^testing.T) {
	_ = t
	opus := []u8{0x08}
	buffer: [SERVER_VOICE_FRAME_MAX_SIZE]u8
	for flags in 0 ..= 255 {
		n, _ := encodeClientVoiceFrame(ClientVoiceFrame{flags = u8(flags), opus = opus}, buffer[:])
		clientFrame, _ := decodeClientVoiceFrame(buffer[:n])
		n, _ = encodeServerVoiceFrame(ServerVoiceFrame{flags = u8(flags), opus = opus}, buffer[:])
		serverFrame, _ := decodeServerVoiceFrame(buffer[:n])
		assert(
			clientFrame.flags == u8(flags) && serverFrame.flags == u8(flags),
			fmt.tprintf("expected flags %d to survive both directions unchanged", flags),
		)
		// Known bits read the same whatever the unknown bits hold.
		endOfSpurt := clientFrame.flags & VOICE_FRAME_FLAG_END_OF_SPURT != 0
		fecPresent := serverFrame.flags & VOICE_FRAME_FLAG_FEC_PRESENT != 0
		assert(endOfSpurt == (flags & 1 != 0), "expected END_OF_SPURT to be bit 0 alone")
		assert(fecPresent == (flags & 2 != 0), "expected FEC_PRESENT to be bit 1 alone")
	}
}

@(test)
testVoiceFrameSequenceWrapsAndExtremeIDs :: proc(t: ^testing.T) {
	_ = t
	opus := []u8{0x08, 0xAA}
	buffer: [SERVER_VOICE_FRAME_MAX_SIZE]u8
	values := []u32{0, 1, 0x7FFF_FFFF, 0x8000_0000, max(u32) - 1, max(u32)}
	for value in values {
		n, ok := encodeClientVoiceFrame(
			ClientVoiceFrame{roomId = value, frameSequence = value, opus = opus},
			buffer[:],
		)
		assert(ok, "expected the client frame to encode")
		clientFrame, _ := decodeClientVoiceFrame(buffer[:n])
		assert(
			clientFrame.roomId == value && clientFrame.frameSequence == value,
			fmt.tprintf("expected client room and frame sequence %d, got %v", value, clientFrame),
		)
		n, ok = encodeServerVoiceFrame(
			ServerVoiceFrame {
				roomId = value,
				senderUserId = value,
				frameSequence = value,
				opus = opus,
			},
			buffer[:],
		)
		assert(ok, "expected the server frame to encode")
		serverFrame, _ := decodeServerVoiceFrame(buffer[:n])
		assert(
			serverFrame.roomId == value &&
			serverFrame.senderUserId == value &&
			serverFrame.frameSequence == value,
			fmt.tprintf("expected server fields %d, got %v", value, serverFrame),
		)
	}

	// A counter that wraps keeps counting: max(u32) is followed by 0, and wrapping
	// subtraction still says the frames are one tick apart.
	last := max(u32)
	next := last + 1
	n, _ := encodeClientVoiceFrame(ClientVoiceFrame{frameSequence = next, opus = opus}, buffer[:])
	wrapped, _ := decodeClientVoiceFrame(buffer[:n])
	assert(wrapped.frameSequence == 0, "expected max(u32) + 1 to go on the wire as 0")
	assert(wrapped.frameSequence - last == 1, "expected wrapping subtraction to give one tick")
}

// Frame duration per TOC configuration, in tenths of a millisecond, written from RFC 6716
// table 2 independently of OPUS_CONFIG_FRAME_SAMPLES.
@(private = "file")
testOpusConfigFrameTenthsOfMs :: proc(config: int) -> int {
	silk := [4]int{100, 200, 400, 600} // SILK NB, MB, WB
	hybrid := [2]int{100, 200} // hybrid SWB, FB
	celt := [4]int{25, 50, 100, 200} // CELT NB, WB, SWB, FB
	switch {
	case config < 12:
		return silk[config % 4]
	case config < 16:
		return hybrid[config % 2]
	case:
		return celt[config % 4]
	}
}

@(test)
testOpusTOCDurationForEveryConfigAndCode :: proc(t: ^testing.T) {
	_ = t
	twentyMsConfigs := 0
	for config in 0 ..< 32 {
		frameSamples := testOpusConfigFrameTenthsOfMs(config) * 48 / 10
		for stereo in 0 ..< 2 {
			for code in 0 ..< 3 {
				toc := u8(config << 3 | stereo << 2 | code)
				// Trailing bytes stand in for frame data; codes 0..2 read only the TOC.
				packet := []u8{toc, 0xFF, 0xFF}
				frameCount := code == 0 ? 1 : 2
				samples, ok := opusPacketDurationSamples(packet)
				assert(
					ok && samples == frameSamples * frameCount,
					fmt.tprintf(
						"expected config %d code %d to last %d samples, got %d (%v)",
						config,
						code,
						frameSamples * frameCount,
						samples,
						ok,
					),
				)
				// A TOC byte alone is a valid code 0..2 packet header for this check.
				aloneSamples, aloneOK := opusPacketDurationSamples(packet[:1])
				assert(aloneOK && aloneSamples == samples, "expected the TOC byte alone to suffice")
				assert(
					opusPacketIsVoiceFrameDuration(packet) == (samples == 960),
					fmt.tprintf("expected the 20 ms check for config %d code %d", config, code),
				)
				if code == 0 && stereo == 0 && samples == 960 {
					twentyMsConfigs += 1
				}
			}

			// Code 3: M frames from the count byte; bits 6 and 7 (padding, VBR) never matter.
			toc := u8(config << 3 | stereo << 2 | 3)
			for countByte in 0 ..= 255 {
				count := countByte & 0x3F
				samples, ok := opusPacketDurationSamples([]u8{toc, u8(countByte), 0})
				expectedOK := count >= 1 && frameSamples * count <= 5760
				assert(
					ok == expectedOK,
					fmt.tprintf(
						"expected config %d code 3 with %d frames to be valid %v, got %v",
						config,
						count,
						expectedOK,
						ok,
					),
				)
				if expectedOK {
					assert(
						samples == frameSamples * count,
						fmt.tprintf("expected %d samples, got %d", frameSamples * count, samples),
					)
				}
				assert(
					opusPacketIsVoiceFrameDuration([]u8{toc, u8(countByte)}) ==
					(expectedOK && frameSamples * count == 960),
					fmt.tprintf("expected the 20 ms check for config %d M=%d", config, count),
				)
			}
			_, codeThreeAloneOK := opusPacketDurationSamples([]u8{toc})
			assert(!codeThreeAloneOK, "expected a code 3 packet without its count byte to fail")
		}
	}
	assert(
		twentyMsConfigs == 9,
		fmt.tprintf("expected nine configs with 20 ms frames, got %d", twentyMsConfigs),
	)

	_, emptyOK := opusPacketDurationSamples(nil)
	assert(!emptyOK, "expected an empty packet to have no duration")
	assert(!opusPacketIsVoiceFrameDuration(nil), "expected an empty packet to fail the 20 ms check")
}

@(test)
testOpusTOCDurationKnownPackets :: proc(t: ^testing.T) {
	_ = t
	// What HayChat's encoder sends: CELT fullband 20 ms (config 31), mono, one frame, and the
	// SILK wideband 20 ms config libopus picks at low bitrates.
	assert(opusPacketIsVoiceFrameDuration([]u8{31 << 3}), "expected config 31 code 0 to be 20 ms")
	assert(opusPacketIsVoiceFrameDuration([]u8{9 << 3}), "expected config 9 code 0 to be 20 ms")
	// Two 10 ms hybrid frames, four 5 ms CELT frames, and eight 2.5 ms CELT frames are 20 ms.
	assert(opusPacketIsVoiceFrameDuration([]u8{12 << 3 | 1}), "expected 2 x 10 ms to be 20 ms")
	assert(opusPacketIsVoiceFrameDuration([]u8{29 << 3 | 3, 4}), "expected 4 x 5 ms to be 20 ms")
	assert(
		opusPacketIsVoiceFrameDuration([]u8{28 << 3 | 3, 0xC0 | 8}),
		"expected 8 x 2.5 ms with the VBR and padding bits set to be 20 ms",
	)
	// 10, 40 and 60 ms packets are refused.
	assert(!opusPacketIsVoiceFrameDuration([]u8{30 << 3}), "expected 10 ms CELT to be refused")
	assert(!opusPacketIsVoiceFrameDuration([]u8{2 << 3}), "expected 40 ms SILK to be refused")
	assert(!opusPacketIsVoiceFrameDuration([]u8{1 << 3 | 1}), "expected 2 x 20 ms to be refused")
	// 120 ms is the most a packet may hold: 2 x 60 ms is valid, 3 x 60 ms is not.
	samples, ok := opusPacketDurationSamples([]u8{3 << 3 | 3, 2})
	assert(ok && samples == 5760, "expected 2 x 60 ms to be a valid 120 ms packet")
	_, ok = opusPacketDurationSamples([]u8{3 << 3 | 3, 3})
	assert(!ok, "expected 3 x 60 ms to exceed the 120 ms limit")
}

@(test)
testVoiceControlPayloadsRoundTripOverCBOR :: proc(t: ^testing.T) {
	_ = t
	join := ClientJoinVoicePayload {
		roomId   = 12,
		muted    = true,
		deafened = false,
	}
	joinBytes, joinErr := cbor.marshal(join)
	assert(joinErr == nil, "expected ClientJoinVoicePayload encoding to succeed")
	defer delete(joinBytes)
	decodedJoin: ClientJoinVoicePayload
	assert(
		cbor.unmarshal(joinBytes, &decodedJoin) == nil,
		"expected ClientJoinVoicePayload to decode",
	)
	assert(decodedJoin == join, fmt.tprintf("expected %v, got %v", join, decodedJoin))

	leaveBytes, leaveErr := cbor.marshal(ClientLeaveVoicePayload{})
	assert(leaveErr == nil, "expected ClientLeaveVoicePayload encoding to succeed")
	defer delete(leaveBytes)
	decodedLeave: ClientLeaveVoicePayload
	assert(
		cbor.unmarshal(leaveBytes, &decodedLeave) == nil,
		"expected ClientLeaveVoicePayload to decode",
	)

	voiceState := ClientVoiceStatePayload {
		muted    = false,
		deafened = true,
	}
	stateBytes, stateErr := cbor.marshal(voiceState)
	assert(stateErr == nil, "expected ClientVoiceStatePayload encoding to succeed")
	defer delete(stateBytes)
	decodedState: ClientVoiceStatePayload
	assert(
		cbor.unmarshal(stateBytes, &decodedState) == nil,
		"expected ClientVoiceStatePayload to decode",
	)
	assert(decodedState == voiceState, fmt.tprintf("expected %v, got %v", voiceState, decodedState))
}

@(test)
testVoiceParticipantsPayloadRoundTripsAndDeinits :: proc(t: ^testing.T) {
	_ = t
	participants := make([dynamic]VoiceParticipant, context.temp_allocator)
	append(&participants, VoiceParticipant{userId = 3, nickname = "alice", muted = true})
	append(&participants, VoiceParticipant{userId = 9, nickname = "bob", deafened = true})
	original := ServerVoiceParticipantsPayload {
		roomId       = 4,
		participants = participants,
	}
	encoded, encodeErr := cbor.marshal(original)
	assert(encodeErr == nil, "expected ServerVoiceParticipantsPayload encoding to succeed")
	defer delete(encoded)

	// Decoded with the default allocator, so the deinit helper must free every allocation or
	// the leak checker fails the test.
	decoded: ServerVoiceParticipantsPayload
	assert(
		cbor.unmarshal(encoded, &decoded) == nil,
		"expected ServerVoiceParticipantsPayload decoding to succeed",
	)
	assert(
		decoded.roomId == 4 && len(decoded.participants) == 2,
		fmt.tprintf("expected room 4 with two participants, got %v", decoded),
	)
	for participant, index in decoded.participants {
		assert(
			participant == original.participants[index],
			fmt.tprintf("expected %v, got %v", original.participants[index], participant),
		)
	}
	ServerVoiceParticipantsPayload_deinit(&decoded)
	assert(decoded.participants == nil, "expected deinit to clear the participant array")

	// An empty room: everyone left.
	emptyBytes, emptyErr := cbor.marshal(ServerVoiceParticipantsPayload{roomId = 4})
	assert(emptyErr == nil, "expected an empty participant list to encode")
	defer delete(emptyBytes)
	emptyDecoded: ServerVoiceParticipantsPayload
	assert(cbor.unmarshal(emptyBytes, &emptyDecoded) == nil, "expected an empty list to decode")
	assert(len(emptyDecoded.participants) == 0, "expected no participants")
	ServerVoiceParticipantsPayload_deinit(&emptyDecoded)

	// Deinit twice is harmless: the first call clears what it freed.
	ServerVoiceParticipantsPayload_deinit(&emptyDecoded)
}

@(test)
testVoiceRejectedAndLeftPayloadsRoundTripAndDeinit :: proc(t: ^testing.T) {
	_ = t
	rejected := ServerVoiceJoinRejectedPayload {
		roomId = 5,
		reason = "voice room is full",
	}
	rejectedBytes, rejectedErr := cbor.marshal(rejected)
	assert(rejectedErr == nil, "expected ServerVoiceJoinRejectedPayload encoding to succeed")
	defer delete(rejectedBytes)
	decodedRejected: ServerVoiceJoinRejectedPayload
	assert(
		cbor.unmarshal(rejectedBytes, &decodedRejected) == nil,
		"expected ServerVoiceJoinRejectedPayload decoding to succeed",
	)
	assert(
		decodedRejected.roomId == 5 && decodedRejected.reason == rejected.reason,
		fmt.tprintf("expected %v, got %v", rejected, decodedRejected),
	)
	ServerVoiceJoinRejectedPayload_deinit(&decodedRejected)
	assert(decodedRejected.reason == "", "expected deinit to clear the reason")

	left := ServerVoiceLeftPayload {
		roomId = 6,
		reason = "the room was deleted",
	}
	leftBytes, leftErr := cbor.marshal(left)
	assert(leftErr == nil, "expected ServerVoiceLeftPayload encoding to succeed")
	defer delete(leftBytes)
	decodedLeft: ServerVoiceLeftPayload
	assert(
		cbor.unmarshal(leftBytes, &decodedLeft) == nil,
		"expected ServerVoiceLeftPayload decoding to succeed",
	)
	assert(
		decodedLeft.roomId == 6 && decodedLeft.reason == left.reason,
		fmt.tprintf("expected %v, got %v", left, decodedLeft),
	)
	ServerVoiceLeftPayload_deinit(&decodedLeft)
	assert(decodedLeft.reason == "", "expected deinit to clear the reason")
}
