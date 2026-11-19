package common

// The encrypted attachment format (protocol 27, docs/plan/2026-11-19-file-attachments.md D12,
// D13). In encrypted rooms and encrypted direct messages the server stores only this, and the
// file key, the file's size, its name and its media type travel inside the sealed message
// (SealedAttachment, e2ee.odin). Pure procedures on caller buffers, like e2ee.odin: no globals,
// no I/O, no protocol messages.
//
// Stored blob, version 1:
//
//   offset  size  field
//   0       1     version = 1
//   1       4     chunkBytes u32 LE = ATTACHMENT_E2EE_CHUNK_BYTES (65536; nothing else opens)
//   5       ...   chunk_0 || chunk_1 || ... || chunk_{n-1}
//
//   padded    = file || zero bytes up to attachmentPadme(size) (Padmé, D13)
//   n         = max(1, ceil(len(padded) / chunkBytes))
//   chunk_i   = XChaCha20-Poly1305(fileKey, nonce_i, padded[i*chunkBytes : (i+1)*chunkBytes],
//                                  AAD_i): ciphertext || tag (16); every chunk but the last
//               holds chunkBytes of plaintext, the last the rest (0 bytes only for an empty
//               file, whose padded length is 0)
//   nonce_i   = i u64 LE || 16 zero bytes
//   AAD_i     = "haychat-attachment-v1" || version u8 || chunkBytes u32 LE || i u64 LE
//               || last u8 (1 for chunk n-1, else 0)
//
//   storedSize = 5 + len(padded) + 16 * n (attachmentEncryptedLayout).
//
// The file key is 32 random bytes, fresh per file and used for exactly one blob, so a counter
// nonce is safe as long as each chunk is encrypted once (D12): AttachmentSealer seals each
// chunk once and the client keeps every sealed chunk until the server acknowledged it. The
// index in the nonce and the AAD stops a swap of chunks, the last flag and the layout (which
// the opener computes from the sealed size) stop truncation and extension.
//
// Opening (AttachmentOpener) authenticates chunk by chunk, so a client writes only
// authenticated bytes to its part file; it checks that every padding byte is zero and, at the
// end, the SHA-256 of the whole stored blob against the one in the sealed message. Every failure
// is final ("This attachment was changed on the server"), never retried with anything else.
//
// The Padmé function (Nikitin et al., "Reducing Metadata Leakage from Encrypted Files and
// Communication with PURBs", 2019) rounds a length L >= 2 up so that only the top
// floor(log2(floor(log2 L))) + 1 bits are free: E = floor(log2 L), S = floor(log2 E) + 1,
// mask = 2^(E - S) - 1, padme(L) = (L + mask) & ~mask. Lengths 0 and 1 are their own. The
// overhead is at most 12% and it leaks O(log log L) bits of the size.

import "base:intrinsics"
import "core:crypto"
import "core:crypto/chacha20poly1305"
import "core:crypto/sha2"
import "core:encoding/endian"

ATTACHMENT_E2EE_VERSION :: u8(1)
ATTACHMENT_E2EE_CHUNK_BYTES :: 64 * 1024
ATTACHMENT_E2EE_HEADER_SIZE :: 1 + 4
ATTACHMENT_E2EE_TAG_SIZE :: chacha20poly1305.TAG_SIZE
// One sealed chunk at its largest: a full chunk of plaintext and its tag.
ATTACHMENT_E2EE_SEALED_CHUNK_MAX :: ATTACHMENT_E2EE_CHUNK_BYTES + ATTACHMENT_E2EE_TAG_SIZE
// What one AttachmentSealer_next writes at most: the header (chunk 0 only) and a chunk.
ATTACHMENT_E2EE_SEAL_OUTPUT_MAX :: ATTACHMENT_E2EE_HEADER_SIZE + ATTACHMENT_E2EE_SEALED_CHUNK_MAX
ATTACHMENT_FILE_KEY_SIZE :: 32
// The largest file the format describes; far above any server's HAYCHAT_ATTACHMENT_MAX_BYTES.
ATTACHMENT_E2EE_MAX_FILE_BYTES :: u64(1) << 40

ATTACHMENT_E2EE_AAD_DOMAIN :: "haychat-attachment-v1"
ATTACHMENT_E2EE_AAD_SIZE :: len(ATTACHMENT_E2EE_AAD_DOMAIN) + 1 + 4 + 8 + 1

// What the client shows for every failure of a downloaded attachment's checks (D19, D12).
ATTACHMENT_CHANGED_MESSAGE :: "This attachment was changed on the server"
// What the client shows when a sealed message's outer attachment list differs from the one
// inside the seal.
ATTACHMENT_LIST_CHANGED_MESSAGE :: "This message's attachments were changed on the server"

AttachmentFileKey :: distinct [ATTACHMENT_FILE_KEY_SIZE]u8

AttachmentE2EEError :: enum u8 {
	None,
	BufferTooSmall,
	TooLarge, // a file over ATTACHMENT_E2EE_MAX_FILE_BYTES
	BadLayout, // the stored size is not the one the file's size gives
	UnsupportedVersion,
	BadChunkSize, // a header chunkBytes other than ATTACHMENT_E2EE_CHUNK_BYTES
	BadChunk, // a chunk's tag does not verify (wrong key, swapped, flipped, wrong last flag)
	BadPadding, // a padding byte is not zero
	Truncated, // the stored bytes end before the last chunk
	TrailingBytes, // more bytes than the layout has
	BadHash, // the whole blob's SHA-256 differs from the sealed one
	OutOfOrder, // a chunk sealed out of order, or after the last
	RandomUnavailable,
}

// The shape of one encrypted blob, computed from the file's size alone.
AttachmentLayout :: struct {
	plainSize:  u64, // the file
	paddedSize: u64, // attachmentPadme(plainSize)
	chunkCount: u64, // >= 1
	storedSize: u64, // what the server stores and the outer AttachmentRef.size says
}

// Padmé (D13): the padded length of a plaintext of length size (see the top of this file).
attachmentPadme :: proc(size: u64) -> u64 {
	if size < 2 {
		return size
	}
	e := u64(63 - intrinsics.count_leading_zeros(size)) // floor(log2 size)
	s := u64(63 - intrinsics.count_leading_zeros(e)) + 1 // floor(log2 e) + 1
	mask := (u64(1) << (e - s)) - 1
	return (size + mask) & ~mask
}

// The layout of a file of plainSize bytes; false for a file over ATTACHMENT_E2EE_MAX_FILE_BYTES.
attachmentEncryptedLayout :: proc(plainSize: u64) -> (layout: AttachmentLayout, ok: bool) {
	if plainSize > ATTACHMENT_E2EE_MAX_FILE_BYTES {
		return {}, false
	}
	layout.plainSize = plainSize
	layout.paddedSize = attachmentPadme(plainSize)
	layout.chunkCount = max(
		u64(1),
		(layout.paddedSize + ATTACHMENT_E2EE_CHUNK_BYTES - 1) / ATTACHMENT_E2EE_CHUNK_BYTES,
	)
	layout.storedSize =
		ATTACHMENT_E2EE_HEADER_SIZE + layout.paddedSize + ATTACHMENT_E2EE_TAG_SIZE * layout.chunkCount
	return layout, true
}

// How many padded plaintext bytes chunk index holds (0 only for an empty file).
attachmentChunkPlainLength :: proc(layout: AttachmentLayout, index: u64) -> int {
	if index >= layout.chunkCount {
		return 0
	}
	start := index * ATTACHMENT_E2EE_CHUNK_BYTES
	return int(min(u64(ATTACHMENT_E2EE_CHUNK_BYTES), layout.paddedSize - start))
}

// AAD_i = "haychat-attachment-v1" || version || chunkBytes u32 LE || index u64 LE || last.
makeAttachmentChunkAAD :: proc(index: u64, last: bool) -> [ATTACHMENT_E2EE_AAD_SIZE]u8 {
	aad: [ATTACHMENT_E2EE_AAD_SIZE]u8
	offset := copy(aad[:], ATTACHMENT_E2EE_AAD_DOMAIN)
	aad[offset] = ATTACHMENT_E2EE_VERSION
	offset += 1
	endian.unchecked_put_u32le(aad[offset:], ATTACHMENT_E2EE_CHUNK_BYTES)
	offset += 4
	endian.unchecked_put_u64le(aad[offset:], index)
	offset += 8
	aad[offset] = last ? 1 : 0
	return aad
}

@(private = "file")
attachmentChunkNonce :: proc(index: u64) -> [chacha20poly1305.XIV_SIZE]u8 {
	nonce: [chacha20poly1305.XIV_SIZE]u8
	endian.unchecked_put_u64le(nonce[:], index)
	return nonce
}

// Seals padded plaintext chunk index (exactly attachmentChunkPlainLength bytes) into dst as
// ciphertext || tag. Used through AttachmentSealer, which seals every chunk once and in order.
sealAttachmentChunk :: proc(
	key: AttachmentFileKey,
	layout: AttachmentLayout,
	index: u64,
	plaintext: []u8,
	dst: []u8,
) -> (
	n: int,
	err: AttachmentE2EEError,
) {
	if index >= layout.chunkCount || len(plaintext) != attachmentChunkPlainLength(layout, index) {
		return 0, .OutOfOrder
	}
	total := len(plaintext) + ATTACHMENT_E2EE_TAG_SIZE
	if len(dst) < total {
		return 0, .BufferTooSmall
	}
	key := key
	nonce := attachmentChunkNonce(index)
	aad := makeAttachmentChunkAAD(index, index == layout.chunkCount - 1)
	ctx: chacha20poly1305.Context
	chacha20poly1305.init_xchacha(&ctx, key[:])
	defer chacha20poly1305.reset(&ctx)
	chacha20poly1305.seal(
		&ctx,
		dst[:len(plaintext)],
		dst[len(plaintext):total],
		nonce[:],
		aad[:],
		plaintext,
	)
	return total, .None
}

// Opens sealed chunk index (ciphertext || tag) into dst, which gets attachmentChunkPlainLength
// bytes. Nothing is written to dst unless the tag verifies.
openAttachmentChunk :: proc(
	key: AttachmentFileKey,
	layout: AttachmentLayout,
	index: u64,
	sealed: []u8,
	dst: []u8,
) -> (
	n: int,
	err: AttachmentE2EEError,
) {
	if index >= layout.chunkCount {
		return 0, .TrailingBytes
	}
	plainLength := attachmentChunkPlainLength(layout, index)
	if len(sealed) != plainLength + ATTACHMENT_E2EE_TAG_SIZE {
		return 0, .BadLayout
	}
	if len(dst) < plainLength {
		return 0, .BufferTooSmall
	}
	key := key
	nonce := attachmentChunkNonce(index)
	aad := makeAttachmentChunkAAD(index, index == layout.chunkCount - 1)
	ctx: chacha20poly1305.Context
	chacha20poly1305.init_xchacha(&ctx, key[:])
	defer chacha20poly1305.reset(&ctx)
	if !chacha20poly1305.open(
		&ctx,
		dst[:plainLength],
		nonce[:],
		aad[:],
		sealed[:plainLength],
		sealed[plainLength:],
	) {
		crypto.zero_explicit(raw_data(dst), plainLength)
		return 0, .BadChunk
	}
	return plainLength, .None
}

// A random file key (D12).
generateAttachmentFileKey :: proc() -> (key: AttachmentFileKey, ok: bool) {
	if !crypto.HAS_RAND_BYTES {
		return {}, false
	}
	crypto.rand_bytes(key[:])
	return key, key != AttachmentFileKey{}
}

// Seals one file chunk by chunk, each chunk exactly once and in order, and hashes what it
// writes: the stored blob's SHA-256, which the sealed message carries.
AttachmentSealer :: struct {
	key:       AttachmentFileKey,
	layout:    AttachmentLayout,
	nextIndex: u64,
	fileBytes: u64, // file bytes consumed so far
	hash:      sha2.Context_256,
}

AttachmentSealer_init :: proc(
	key: AttachmentFileKey,
	plainSize: u64,
) -> (
	sealer: AttachmentSealer,
	err: AttachmentE2EEError,
) {
	layout, ok := attachmentEncryptedLayout(plainSize)
	if !ok {
		return {}, .TooLarge
	}
	sealer.key = key
	sealer.layout = layout
	sha2.init_256(&sealer.hash)
	return sealer, .None
}

// How many file bytes the next chunk takes (it pads the rest with zeros), 0 once the file is
// used up; done is true once every chunk is sealed.
AttachmentSealer_nextFileBytes :: proc(sealer: ^AttachmentSealer) -> (count: int, done: bool) {
	if sealer.nextIndex >= sealer.layout.chunkCount {
		return 0, true
	}
	return int(
		min(u64(ATTACHMENT_E2EE_CHUNK_BYTES), sealer.layout.plainSize - sealer.fileBytes),
	), false
}

// Seals the next chunk from fileBytes (exactly AttachmentSealer_nextFileBytes of the file)
// into dst: the header first for chunk 0, then ciphertext || tag. scratch holds the padded
// plaintext (at least ATTACHMENT_E2EE_CHUNK_BYTES) and is wiped afterwards. dst needs
// ATTACHMENT_E2EE_SEAL_OUTPUT_MAX.
AttachmentSealer_next :: proc(
	sealer: ^AttachmentSealer,
	fileBytes: []u8,
	scratch: []u8,
	dst: []u8,
) -> (
	n: int,
	err: AttachmentE2EEError,
) {
	expected, done := AttachmentSealer_nextFileBytes(sealer)
	if done || len(fileBytes) != expected {
		return 0, .OutOfOrder
	}
	plainLength := attachmentChunkPlainLength(sealer.layout, sealer.nextIndex)
	if len(scratch) < plainLength || len(dst) < ATTACHMENT_E2EE_SEAL_OUTPUT_MAX {
		return 0, .BufferTooSmall
	}
	offset := 0
	if sealer.nextIndex == 0 {
		dst[0] = ATTACHMENT_E2EE_VERSION
		endian.unchecked_put_u32le(dst[1:], ATTACHMENT_E2EE_CHUNK_BYTES)
		offset = ATTACHMENT_E2EE_HEADER_SIZE
	}
	padded := scratch[:plainLength]
	copy(padded, fileBytes)
	for index in len(fileBytes) ..< plainLength {
		padded[index] = 0
	}
	sealedLength, sealErr := sealAttachmentChunk(
		sealer.key,
		sealer.layout,
		sealer.nextIndex,
		padded,
		dst[offset:],
	)
	crypto.zero_explicit(raw_data(padded), len(padded))
	if sealErr != .None {
		return 0, sealErr
	}
	offset += sealedLength
	sha2.update(&sealer.hash, dst[:offset])
	sealer.nextIndex += 1
	sealer.fileBytes += u64(len(fileBytes))
	return offset, .None
}

// The stored blob's SHA-256 once every chunk is sealed.
AttachmentSealer_finish :: proc(
	sealer: ^AttachmentSealer,
) -> (
	digest: AttachmentSHA256,
	err: AttachmentE2EEError,
) {
	if sealer.nextIndex != sealer.layout.chunkCount {
		return {}, .OutOfOrder
	}
	hash := sealer.hash
	sha2.final(&hash, digest[:])
	return digest, .None
}

AttachmentSealer_wipe :: proc(sealer: ^AttachmentSealer) {
	crypto.zero_explicit(sealer, size_of(sealer^))
}

// Opens a downloaded blob as it arrives, in any slicing of its bytes. buffer collects one
// sealed chunk and must hold ATTACHMENT_E2EE_SEALED_CHUNK_MAX bytes; it borrows the caller's.
AttachmentOpener :: struct {
	key:          AttachmentFileKey,
	layout:       AttachmentLayout,
	buffer:       []u8,
	buffered:     int,
	header:       [ATTACHMENT_E2EE_HEADER_SIZE]u8,
	headerLength: int,
	index:        u64, // the next chunk to open
	plainOffset:  u64, // padded plaintext bytes opened so far
	received:     u64, // stored bytes consumed so far
	failed:       AttachmentE2EEError,
	hash:         sha2.Context_256,
}

// Starts opening a blob of a file of plainSize bytes (from the sealed message) whose stored
// size is storedSize (the outer reference's, or the download's): they must agree with the
// layout, else BadLayout.
AttachmentOpener_init :: proc(
	key: AttachmentFileKey,
	plainSize: u64,
	storedSize: u64,
	buffer: []u8,
) -> (
	opener: AttachmentOpener,
	err: AttachmentE2EEError,
) {
	layout, ok := attachmentEncryptedLayout(plainSize)
	if !ok {
		return {}, .TooLarge
	}
	if layout.storedSize != storedSize {
		return {}, .BadLayout
	}
	if len(buffer) < ATTACHMENT_E2EE_SEALED_CHUNK_MAX {
		return {}, .BufferTooSmall
	}
	opener.key = key
	opener.layout = layout
	opener.buffer = buffer
	sha2.init_256(&opener.hash)
	return opener, .None
}

// Takes stored bytes from data until it has opened one chunk (or used data up). Returns how
// many bytes of data it consumed and how many file bytes it wrote to out (at most
// ATTACHMENT_E2EE_CHUNK_BYTES; padding is checked and never written). Call again with the rest
// of data while consumed < len(data). The first failure sticks.
AttachmentOpener_feed :: proc(
	opener: ^AttachmentOpener,
	data: []u8,
	out: []u8,
) -> (
	consumed: int,
	produced: int,
	err: AttachmentE2EEError,
) {
	if opener.failed != .None {
		return 0, 0, opener.failed
	}
	defer if err != .None {
		opener.failed = err
	}
	if len(out) < ATTACHMENT_E2EE_CHUNK_BYTES {
		return 0, 0, .BufferTooSmall
	}
	if u64(len(data)) > opener.layout.storedSize - opener.received {
		return 0, 0, .TrailingBytes
	}
	if opener.headerLength < ATTACHMENT_E2EE_HEADER_SIZE {
		take := min(len(data), ATTACHMENT_E2EE_HEADER_SIZE - opener.headerLength)
		copy(opener.header[opener.headerLength:], data[:take])
		opener.headerLength += take
		consumed += take
		if opener.headerLength < ATTACHMENT_E2EE_HEADER_SIZE {
			attachmentOpenerHash(opener, data[:consumed])
			return consumed, 0, .None
		}
		if opener.header[0] != ATTACHMENT_E2EE_VERSION {
			return consumed, 0, .UnsupportedVersion
		}
		if endian.unchecked_get_u32le(opener.header[1:]) != ATTACHMENT_E2EE_CHUNK_BYTES {
			return consumed, 0, .BadChunkSize
		}
	}
	sealedLength :=
		attachmentChunkPlainLength(opener.layout, opener.index) + ATTACHMENT_E2EE_TAG_SIZE
	take := min(len(data) - consumed, sealedLength - opener.buffered)
	copy(opener.buffer[opener.buffered:], data[consumed:consumed + take])
	opener.buffered += take
	consumed += take
	attachmentOpenerHash(opener, data[:consumed])
	if opener.buffered < sealedLength {
		return consumed, 0, .None
	}
	plainLength, openErr := openAttachmentChunk(
		opener.key,
		opener.layout,
		opener.index,
		opener.buffer[:sealedLength],
		out,
	)
	opener.buffered = 0
	if openErr != .None {
		return consumed, 0, openErr
	}
	// The bytes past the file's end are padding and must be zero (D13).
	fileLeft := opener.layout.plainSize - opener.plainOffset
	produced = int(min(u64(plainLength), fileLeft))
	for index in produced ..< plainLength {
		if out[index] != 0 {
			crypto.zero_explicit(raw_data(out), plainLength)
			return consumed, 0, .BadPadding
		}
	}
	opener.plainOffset += u64(plainLength)
	opener.index += 1
	return consumed, produced, .None
}

@(private = "file")
attachmentOpenerHash :: proc(opener: ^AttachmentOpener, bytes: []u8) {
	sha2.update(&opener.hash, bytes)
	opener.received += u64(len(bytes))
}

// Checks, once every byte arrived, that the last chunk was opened and that the stored blob's
// SHA-256 is expected (the sealed message's).
AttachmentOpener_finish :: proc(
	opener: ^AttachmentOpener,
	expected: AttachmentSHA256,
) -> AttachmentE2EEError {
	if opener.failed != .None {
		return opener.failed
	}
	if opener.index != opener.layout.chunkCount || opener.received != opener.layout.storedSize {
		opener.failed = .Truncated
		return .Truncated
	}
	digest: AttachmentSHA256
	hash := opener.hash
	sha2.final(&hash, digest[:])
	if digest != expected {
		opener.failed = .BadHash
		return .BadHash
	}
	return .None
}

// Wipes the key and the chunk buffer.
AttachmentOpener_wipe :: proc(opener: ^AttachmentOpener) {
	if len(opener.buffer) > 0 {
		crypto.zero_explicit(raw_data(opener.buffer), len(opener.buffer))
	}
	crypto.zero_explicit(&opener.key, size_of(opener.key))
	opener^ = {}
}
