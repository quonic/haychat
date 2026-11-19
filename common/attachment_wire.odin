package common

// Attachment transfer packets (protocol 26, docs/plan/2026-11-19-file-attachments.md D6-D9).
// They are binary, never CBOR, and travel sealed on ENet channel 5 (sealFilePacket,
// openFilePacket in auth.odin). Layout, all integers little-endian:
//
//   kind u8 || blobId [16]u8 || offset u64 || data
//
// UploadChunk and DownloadChunk carry 1..ATTACHMENT_CHUNK_BYTES bytes of data at offset;
// UploadAck and DownloadAck are the same header with no data and acknowledge the chunk that
// started at offset. Like voice_wire.odin, encoding writes into a caller buffer and decoding
// borrows its input: a decoded packet's data is valid only while the input is.
//
// The control requests (begin, resume, finish, download, cancel and their answers) are
// ordinary CBOR on the control channel; their payloads are in protocol.odin.

import "core:encoding/endian"

ATTACHMENT_BLOB_ID_SIZE :: 16
ATTACHMENT_SHA256_SIZE :: 32
// Largest data field of one chunk, and the chunk size every transfer uses.
ATTACHMENT_CHUNK_BYTES :: 64 * 1024
// Unacknowledged chunks one transfer may have in flight (D8): 512 KiB.
ATTACHMENT_WINDOW_CHUNKS :: 8
// Transfers one session may run at once (D8).
ATTACHMENT_UPLOADS_PER_SESSION_MAX :: 2
ATTACHMENT_DOWNLOADS_PER_SESSION_MAX :: 4

ATTACHMENT_PACKET_HEADER_SIZE :: 1 + ATTACHMENT_BLOB_ID_SIZE + 8
ATTACHMENT_PACKET_MAX_SIZE :: ATTACHMENT_PACKET_HEADER_SIZE + ATTACHMENT_CHUNK_BYTES
// A sealed attachment packet on the wire (the file packet envelope around the largest packet).
ATTACHMENT_SEALED_PACKET_MAX_SIZE :: ATTACHMENT_PACKET_MAX_SIZE + FILE_PACKET_OVERHEAD

AttachmentBlobID :: [ATTACHMENT_BLOB_ID_SIZE]u8
AttachmentSHA256 :: [ATTACHMENT_SHA256_SIZE]u8

// The wire values are pinned by testAttachmentWireLayoutIsPinned; never renumber them.
AttachmentPacketKind :: enum u8 {
	UploadChunk   = 1,
	UploadAck     = 2,
	DownloadChunk = 3,
	DownloadAck   = 4,
}

AttachmentPacket :: struct {
	kind:   AttachmentPacketKind,
	blobId: AttachmentBlobID,
	offset: u64,
	data:   []u8, // chunks only; borrowed from the decoded input or the encode caller
}

AttachmentDecodeResult :: enum u8 {
	Ok,
	Truncated, // shorter than the header
	UnknownKind,
	DataOnAck, // an ack with data after the header
	EmptyChunk, // a chunk without data
	TooLarge, // more than ATTACHMENT_CHUNK_BYTES of data
}

attachmentPacketKindIsChunk :: proc(kind: AttachmentPacketKind) -> bool {
	return kind == .UploadChunk || kind == .DownloadChunk
}

attachmentPacketKindIsKnown :: proc(value: u8) -> bool {
	switch AttachmentPacketKind(value) {
	case .UploadChunk, .UploadAck, .DownloadChunk, .DownloadAck:
		return true
	}
	return false
}

// Whether a blob ID is set at all: the server never hands out the all-zero ID.
attachmentBlobIDIsSet :: proc(blobId: AttachmentBlobID) -> bool {
	for value in blobId {
		if value != 0 {
			return true
		}
	}
	return false
}

// Writes the packet into dst and returns its length. Fails when dst is too small, a chunk's
// data is empty or larger than ATTACHMENT_CHUNK_BYTES, or an ack carries data.
encodeAttachmentPacket :: proc(packet: AttachmentPacket, dst: []u8) -> (n: int, ok: bool) {
	if !attachmentPacketKindIsKnown(u8(packet.kind)) {
		return 0, false
	}
	if attachmentPacketKindIsChunk(packet.kind) {
		if len(packet.data) == 0 || len(packet.data) > ATTACHMENT_CHUNK_BYTES {
			return 0, false
		}
	} else if len(packet.data) != 0 {
		return 0, false
	}
	total := ATTACHMENT_PACKET_HEADER_SIZE + len(packet.data)
	if len(dst) < total {
		return 0, false
	}
	blobId := packet.blobId
	dst[0] = u8(packet.kind)
	copy(dst[1:1 + ATTACHMENT_BLOB_ID_SIZE], blobId[:])
	endian.unchecked_put_u64le(
		dst[1 + ATTACHMENT_BLOB_ID_SIZE:ATTACHMENT_PACKET_HEADER_SIZE],
		packet.offset,
	)
	copy(dst[ATTACHMENT_PACKET_HEADER_SIZE:total], packet.data)
	return total, true
}

// Decodes one packet. The result's data borrows src.
decodeAttachmentPacket :: proc(
	src: []u8,
) -> (
	packet: AttachmentPacket,
	result: AttachmentDecodeResult,
) {
	if len(src) < ATTACHMENT_PACKET_HEADER_SIZE {
		return {}, .Truncated
	}
	if !attachmentPacketKindIsKnown(src[0]) {
		return {}, .UnknownKind
	}
	packet.kind = AttachmentPacketKind(src[0])
	copy(packet.blobId[:], src[1:1 + ATTACHMENT_BLOB_ID_SIZE])
	packet.offset = endian.unchecked_get_u64le(
		src[1 + ATTACHMENT_BLOB_ID_SIZE:ATTACHMENT_PACKET_HEADER_SIZE],
	)
	data := src[ATTACHMENT_PACKET_HEADER_SIZE:]
	if attachmentPacketKindIsChunk(packet.kind) {
		if len(data) == 0 {
			return {}, .EmptyChunk
		}
		if len(data) > ATTACHMENT_CHUNK_BYTES {
			return {}, .TooLarge
		}
		packet.data = data
	} else if len(data) != 0 {
		return {}, .DataOnAck
	}
	return packet, .Ok
}
