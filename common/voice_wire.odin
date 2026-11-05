package common

import "core:encoding/endian"

// Voice frame plaintexts (voice-rooms-design.md 3.3). These are the bytes sealed inside a voice
// datagram (sealVoiceDatagram/openVoiceDatagram) on ENet channel 2. They are binary and never
// CBOR: a CBOR envelope would cost more than the Opus payload, 50 times a second per speaker,
// and the relay and the voice thread must not allocate per frame. All integers are
// little-endian.
//
//   ClientVoiceFrame (client -> server)     ServerVoiceFrame (server -> client)
//   offset size field                       offset size field
//   0      4    roomId         u32          0      4    roomId         u32
//   4      4    frameSequence  u32          4      4    senderUserId   u32
//   8      1    flags          u8           8      4    frameSequence  u32
//   9      m    opus (1..512 bytes)         12     1    flags          u8
//                                           13     m    opus (1..512 bytes)
//
// There is no length field: the Opus payload runs to the end of the plaintext, whose length
// the AEAD authenticates.

// Flag bits. Readers test single bits and ignore the others, so a later sender may define new
// bits without breaking older receivers. Decoders keep the flags byte as sent.
VOICE_FRAME_FLAG_END_OF_SPURT :: u8(1 << 0) // the last frame before the sender's gate closed
VOICE_FRAME_FLAG_FEC_PRESENT :: u8(1 << 1) // informational: the encoder had in-band FEC on

// Largest Opus payload a frame may carry. 20 ms at 24 kbit/s is about 60 bytes; 512 leaves
// room for any bitrate HayChat would use and keeps every datagram far below ENet's MTU.
VOICE_OPUS_MAX_BYTES :: 512

CLIENT_VOICE_FRAME_HEADER_SIZE :: 4 + 4 + 1
SERVER_VOICE_FRAME_HEADER_SIZE :: 4 + 4 + 4 + 1
CLIENT_VOICE_FRAME_MAX_SIZE :: CLIENT_VOICE_FRAME_HEADER_SIZE + VOICE_OPUS_MAX_BYTES
SERVER_VOICE_FRAME_MAX_SIZE :: SERVER_VOICE_FRAME_HEADER_SIZE + VOICE_OPUS_MAX_BYTES
// Largest sealed voice datagram in either direction, for sizing fixed buffers.
VOICE_DATAGRAM_MAX_SIZE :: VOICE_DATAGRAM_OVERHEAD + SERVER_VOICE_FRAME_MAX_SIZE

// Every voice frame is 20 ms of 48 kHz audio. frameSequence counts these ticks, so a frame's
// media timestamp is frameSequence * VOICE_FRAME_SAMPLES.
VOICE_SAMPLE_RATE :: 48_000
VOICE_FRAME_SAMPLES :: VOICE_SAMPLE_RATE / 50

// opus borrows the buffer the frame was decoded from (or will be encoded from): it is only
// valid while that buffer is, and must be copied to outlive it.
ClientVoiceFrame :: struct {
	roomId:        u32,
	frameSequence: u32, // the sender's 20 ms tick counter; wraps, compare with wrapping math
	flags:         u8,
	opus:          []u8,
}

// opus borrows the buffer the frame was decoded from; see ClientVoiceFrame.
ServerVoiceFrame :: struct {
	roomId:        u32,
	senderUserId:  u32,
	frameSequence: u32, // copied from the sender's ClientVoiceFrame unchanged
	flags:         u8,
	opus:          []u8,
}

// Why a frame failed to decode. The relay counts drops by reason, so this is an enum rather
// than a bool.
VoiceFrameDecodeResult :: enum u8 {
	Ok,
	Truncated, // shorter than the header
	EmptyOpus, // a header and no Opus bytes
	OpusTooLarge, // more than VOICE_OPUS_MAX_BYTES of Opus
}

@(private = "file")
voiceFrameCheckOpusLength :: proc(length: int) -> VoiceFrameDecodeResult {
	if length == 0 {
		return .EmptyOpus
	}
	if length > VOICE_OPUS_MAX_BYTES {
		return .OpusTooLarge
	}
	return .Ok
}

// Writes frame into dst and returns the byte count. Fails, writing nothing, when the Opus
// payload is empty or over VOICE_OPUS_MAX_BYTES, or when dst is shorter than
// CLIENT_VOICE_FRAME_HEADER_SIZE + len(frame.opus). Allocates nothing. dst may overlap
// frame.opus: the Opus bytes are moved before the header is written.
encodeClientVoiceFrame :: proc(frame: ClientVoiceFrame, dst: []u8) -> (n: int, ok: bool) {
	if voiceFrameCheckOpusLength(len(frame.opus)) != .Ok {
		return 0, false
	}
	total := CLIENT_VOICE_FRAME_HEADER_SIZE + len(frame.opus)
	if len(dst) < total {
		return 0, false
	}

	copy(dst[CLIENT_VOICE_FRAME_HEADER_SIZE:total], frame.opus)
	endian.unchecked_put_u32le(dst[0:4], frame.roomId)
	endian.unchecked_put_u32le(dst[4:8], frame.frameSequence)
	dst[8] = frame.flags
	return total, true
}

// Reads a ClientVoiceFrame from data. Allocates nothing: frame.opus is a slice of data, valid
// only while data is.
decodeClientVoiceFrame :: proc(
	data: []u8,
) -> (
	frame: ClientVoiceFrame,
	result: VoiceFrameDecodeResult,
) {
	if len(data) < CLIENT_VOICE_FRAME_HEADER_SIZE {
		return {}, .Truncated
	}
	result = voiceFrameCheckOpusLength(len(data) - CLIENT_VOICE_FRAME_HEADER_SIZE)
	if result != .Ok {
		return {}, result
	}

	frame = ClientVoiceFrame {
		roomId        = endian.unchecked_get_u32le(data[0:4]),
		frameSequence = endian.unchecked_get_u32le(data[4:8]),
		flags         = data[8],
		opus          = data[CLIENT_VOICE_FRAME_HEADER_SIZE:],
	}
	return frame, .Ok
}

// Writes frame into dst; the same rules as encodeClientVoiceFrame, with
// SERVER_VOICE_FRAME_HEADER_SIZE. The relay can decode a ClientVoiceFrame and encode the
// ServerVoiceFrame into the same buffer.
encodeServerVoiceFrame :: proc(frame: ServerVoiceFrame, dst: []u8) -> (n: int, ok: bool) {
	if voiceFrameCheckOpusLength(len(frame.opus)) != .Ok {
		return 0, false
	}
	total := SERVER_VOICE_FRAME_HEADER_SIZE + len(frame.opus)
	if len(dst) < total {
		return 0, false
	}

	copy(dst[SERVER_VOICE_FRAME_HEADER_SIZE:total], frame.opus)
	endian.unchecked_put_u32le(dst[0:4], frame.roomId)
	endian.unchecked_put_u32le(dst[4:8], frame.senderUserId)
	endian.unchecked_put_u32le(dst[8:12], frame.frameSequence)
	dst[12] = frame.flags
	return total, true
}

// Reads a ServerVoiceFrame from data. Allocates nothing: frame.opus is a slice of data, valid
// only while data is.
decodeServerVoiceFrame :: proc(
	data: []u8,
) -> (
	frame: ServerVoiceFrame,
	result: VoiceFrameDecodeResult,
) {
	if len(data) < SERVER_VOICE_FRAME_HEADER_SIZE {
		return {}, .Truncated
	}
	result = voiceFrameCheckOpusLength(len(data) - SERVER_VOICE_FRAME_HEADER_SIZE)
	if result != .Ok {
		return {}, result
	}

	frame = ServerVoiceFrame {
		roomId        = endian.unchecked_get_u32le(data[0:4]),
		senderUserId  = endian.unchecked_get_u32le(data[4:8]),
		frameSequence = endian.unchecked_get_u32le(data[8:12]),
		flags         = data[12],
		opus          = data[SERVER_VOICE_FRAME_HEADER_SIZE:],
	}
	return frame, .Ok
}

// The longest packet RFC 6716 allows (R5 in section 3.4), in 48 kHz samples: 120 ms.
OPUS_PACKET_MAX_SAMPLES :: 5760

// Duration of one Opus frame for each TOC configuration (RFC 6716 section 3.1, table 2), in
// 48 kHz samples: 120 = 2.5 ms, 240 = 5 ms, 480 = 10 ms, 960 = 20 ms, 1920 = 40 ms,
// 2880 = 60 ms.
@(private = "file")
OPUS_CONFIG_FRAME_SAMPLES := [32]int {
	// 0..11: SILK-only, narrowband, mediumband and wideband: 10, 20, 40, 60 ms each.
	480, 960, 1920, 2880,
	480, 960, 1920, 2880,
	480, 960, 1920, 2880,
	// 12..15: hybrid, super-wideband and fullband: 10, 20 ms each.
	480, 960,
	480, 960,
	// 16..31: CELT-only, narrowband, wideband, super-wideband, fullband: 2.5, 5, 10, 20 ms.
	120, 240, 480, 960,
	120, 240, 480, 960,
	120, 240, 480, 960,
	120, 240, 480, 960,
}

// Returns the duration of an Opus packet in 48 kHz samples from its TOC byte (RFC 6716
// section 3.1) and, for frame-count code 3, its frame-count byte. It reads nothing else and
// does not prove that the frames themselves decode; libopus does that on the receiver. ok is
// false for an empty packet, a code 3 packet without its count byte or with zero frames, and
// a packet longer than 120 ms.
opusPacketDurationSamples :: proc(opus: []u8) -> (samples: int, ok: bool) {
	if len(opus) == 0 {
		return 0, false
	}

	toc := opus[0]
	config := int(toc >> 3)
	frameSamples := OPUS_CONFIG_FRAME_SAMPLES[config]
	// Bit 2 is the stereo flag, which does not change the duration.
	frameCount: int
	switch toc & 0x03 {
	case 0:
		frameCount = 1
	case 1, 2:
		frameCount = 2 // two frames, of equal (code 1) or different (code 2) size
	case 3:
		if len(opus) < 2 {
			return 0, false
		}
		// Frame-count byte: bit 7 VBR, bit 6 padding, bits 0..5 the frame count M.
		frameCount = int(opus[1] & 0x3F)
		if frameCount == 0 {
			return 0, false
		}
	}

	samples = frameSamples * frameCount
	if samples > OPUS_PACKET_MAX_SAMPLES {
		return 0, false
	}
	return samples, true
}

// The relay's TOC check: true only for an Opus packet of exactly 20 ms at 48 kHz, the one
// frame size HayChat sends. The server needs no libopus for this.
opusPacketIsVoiceFrameDuration :: proc(opus: []u8) -> bool {
	samples, ok := opusPacketDurationSamples(opus)
	return ok && samples == VOICE_FRAME_SAMPLES
}
