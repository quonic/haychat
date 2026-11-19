package common

import "core:encoding/cbor"
import "core:fmt"
import "core:testing"

@(test)
testAttachmentWireLayoutIsPinned :: proc(t: ^testing.T) {
	_ = t
	assert(
		u8(AttachmentPacketKind.UploadChunk) == 1 &&
		u8(AttachmentPacketKind.UploadAck) == 2 &&
		u8(AttachmentPacketKind.DownloadChunk) == 3 &&
		u8(AttachmentPacketKind.DownloadAck) == 4,
		"expected AttachmentPacketKind to stay UploadChunk 1, UploadAck 2, DownloadChunk 3, " +
		"DownloadAck 4",
	)
	assert(ATTACHMENT_PACKET_HEADER_SIZE == 25, "expected kind || blobId || offset (25 bytes)")
	assert(ATTACHMENT_CHUNK_BYTES == 65536, "expected 64 KiB chunks")
	assert(ATTACHMENT_WINDOW_CHUNKS == 8, "expected an 8-chunk window")
	assert(
		ATTACHMENT_UPLOADS_PER_SESSION_MAX == 2 && ATTACHMENT_DOWNLOADS_PER_SESSION_MAX == 4,
		"expected at most 2 uploads and 4 downloads per session",
	)
	assert(
		int(AttachmentState.Uploading) == 0 &&
		int(AttachmentState.Ready) == 1 &&
		int(AttachmentState.Bound) == 2 &&
		int(AttachmentState.Removed) == 3,
		"expected AttachmentState to stay Uploading 0, Ready 1, Bound 2, Removed 3",
	)

	blobId: AttachmentBlobID
	for index in 0 ..< ATTACHMENT_BLOB_ID_SIZE {
		blobId[index] = u8(0x10 + index)
	}
	data := [?]u8{0xDE, 0xAD}
	encoded: [64]u8
	n, ok := encodeAttachmentPacket(
		AttachmentPacket {
			kind = .UploadChunk,
			blobId = blobId,
			offset = 0x0807060504030201,
			data = data[:],
		},
		encoded[:],
	)
	assert(ok && n == 27, fmt.tprintf("expected a 27-byte chunk, got %d", n))
	expected := [27]u8 {
		1,
		0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17,
		0x18, 0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F,
		1, 2, 3, 4, 5, 6, 7, 8,
		0xDE, 0xAD,
	}
	for value, index in expected {
		assert(
			encoded[index] == value,
			fmt.tprintf("expected byte %d to be %x, got %x", index, value, encoded[index]),
		)
	}
}

@(test)
testAttachmentPacketsRoundTrip :: proc(t: ^testing.T) {
	_ = t
	blobId: AttachmentBlobID
	blobId[0] = 7
	blobId[15] = 9
	chunk := make([]u8, ATTACHMENT_CHUNK_BYTES)
	defer delete(chunk)
	for index in 0 ..< len(chunk) {
		chunk[index] = u8(index * 31)
	}
	buffer := make([]u8, ATTACHMENT_PACKET_MAX_SIZE)
	defer delete(buffer)
	for kind in AttachmentPacketKind {
		packet := AttachmentPacket {
			kind   = kind,
			blobId = blobId,
			offset = 3 * ATTACHMENT_CHUNK_BYTES,
		}
		if attachmentPacketKindIsChunk(kind) {
			packet.data = chunk
		}
		n, ok := encodeAttachmentPacket(packet, buffer)
		assert(ok, fmt.tprintf("expected %v to encode", kind))
		decoded, result := decodeAttachmentPacket(buffer[:n])
		assert(result == .Ok, fmt.tprintf("expected %v to decode, got %v", kind, result))
		assert(
			decoded.kind == kind && decoded.blobId == blobId && decoded.offset == packet.offset,
			fmt.tprintf("expected %v's header to round-trip, got %v", kind, decoded),
		)
		assert(len(decoded.data) == len(packet.data), fmt.tprintf("expected %v's data", kind))
		if len(decoded.data) > 0 {
			assert(
				raw_data(decoded.data) == raw_data(buffer[ATTACHMENT_PACKET_HEADER_SIZE:]),
				"expected decoded data to borrow the input",
			)
		}
	}
}

@(test)
testAttachmentPacketsRefuseMalformedInput :: proc(t: ^testing.T) {
	_ = t
	buffer := make([]u8, ATTACHMENT_PACKET_MAX_SIZE + 1)
	defer delete(buffer)
	blobId: AttachmentBlobID
	one := [?]u8{1}

	_, emptyChunk := encodeAttachmentPacket(AttachmentPacket{kind = .UploadChunk}, buffer)
	assert(!emptyChunk, "expected an empty chunk not to encode")
	_, ackData := encodeAttachmentPacket(
		AttachmentPacket{kind = .UploadAck, data = one[:]},
		buffer,
	)
	assert(!ackData, "expected an ack with data not to encode")
	_, unknown := encodeAttachmentPacket(AttachmentPacket{kind = AttachmentPacketKind(9)}, buffer)
	assert(!unknown, "expected an unknown kind not to encode")
	_, small := encodeAttachmentPacket(
		AttachmentPacket{kind = .DownloadChunk, blobId = blobId, data = one[:]},
		buffer[:ATTACHMENT_PACKET_HEADER_SIZE],
	)
	assert(!small, "expected a short destination to fail")

	cases := []struct {
		bytes:    []u8,
		expected: AttachmentDecodeResult,
	} {
		{buffer[:ATTACHMENT_PACKET_HEADER_SIZE - 1], .Truncated},
		{buffer[:ATTACHMENT_PACKET_HEADER_SIZE], .UnknownKind},
	}
	for c in cases {
		_, result := decodeAttachmentPacket(c.bytes)
		assert(result == c.expected, fmt.tprintf("expected %v, got %v", c.expected, result))
	}
	buffer[0] = u8(AttachmentPacketKind.UploadChunk)
	_, empty := decodeAttachmentPacket(buffer[:ATTACHMENT_PACKET_HEADER_SIZE])
	assert(empty == .EmptyChunk, fmt.tprintf("expected EmptyChunk, got %v", empty))
	_, tooLarge := decodeAttachmentPacket(buffer[:ATTACHMENT_PACKET_MAX_SIZE + 1])
	assert(tooLarge == .TooLarge, fmt.tprintf("expected TooLarge, got %v", tooLarge))
	buffer[0] = u8(AttachmentPacketKind.DownloadAck)
	_, dataOnAck := decodeAttachmentPacket(buffer[:ATTACHMENT_PACKET_HEADER_SIZE + 1])
	assert(dataOnAck == .DataOnAck, fmt.tprintf("expected DataOnAck, got %v", dataOnAck))
}

@(test)
testAttachmentControlPayloadsRoundTripOverCBOR :: proc(t: ^testing.T) {
	_ = t
	blobId: AttachmentBlobID
	sha: AttachmentSHA256
	for index in 0 ..< len(blobId) {
		blobId[index] = u8(index + 1)
	}
	for index in 0 ..< len(sha) {
		sha[index] = u8(0xF0 - index)
	}

	begin := ClientAttachmentUploadBeginPayload {
		requestId       = 77,
		recipientUserId = 4,
		size            = 26_214_400,
		encrypted       = true,
	}
	encoded, err := cbor.marshal(begin)
	assert(err == nil, "expected begin to encode")
	decodedBegin: ClientAttachmentUploadBeginPayload
	assert(cbor.unmarshal(encoded, &decodedBegin) == nil, "expected begin to decode")
	delete(encoded)
	assert(decodedBegin == begin, fmt.tprintf("expected begin to round-trip, got %v", decodedBegin))

	ready := ServerAttachmentUploadReadyPayload {
		requestId    = 77,
		blobId       = blobId,
		received     = 65536,
		chunkBytes   = ATTACHMENT_CHUNK_BYTES,
		windowChunks = ATTACHMENT_WINDOW_CHUNKS,
	}
	encoded, err = cbor.marshal(ready)
	assert(err == nil, "expected ready to encode")
	decodedReady: ServerAttachmentUploadReadyPayload
	assert(
		cbor.unmarshal(encoded, &decodedReady, temp_allocator = context.allocator) == nil,
		"expected ready to decode",
	)
	delete(encoded)
	assert(decodedReady == ready, fmt.tprintf("expected ready to round-trip, got %v", decodedReady))

	done := ServerAttachmentUploadDonePayload {
		blobId = blobId,
		size   = 3,
		sha256 = sha,
	}
	encoded, err = cbor.marshal(done)
	assert(err == nil, "expected done to encode")
	decodedDone: ServerAttachmentUploadDonePayload
	assert(
		cbor.unmarshal(encoded, &decodedDone, temp_allocator = context.allocator) == nil,
		"expected done to decode",
	)
	delete(encoded)
	assert(decodedDone == done, fmt.tprintf("expected done to round-trip, got %v", decodedDone))

	refused := ServerAttachmentRefusedPayload {
		requestId = 5,
		blobId    = blobId,
		message   = ATTACHMENT_QUOTA_MESSAGE,
	}
	encoded, err = cbor.marshal(refused)
	assert(err == nil, "expected refused to encode")
	decodedRefused: ServerAttachmentRefusedPayload
	assert(
		cbor.unmarshal(encoded, &decodedRefused, temp_allocator = context.allocator) == nil,
		"expected refused to decode",
	)
	delete(encoded)
	defer ServerAttachmentRefusedPayload_deinit(&decodedRefused)
	assert(
		decodedRefused.requestId == 5 &&
		decodedRefused.blobId == blobId &&
		decodedRefused.message == ATTACHMENT_QUOTA_MESSAGE,
		fmt.tprintf("expected refused to round-trip, got %v", decodedRefused),
	)
}
