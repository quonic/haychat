package common

import "core:crypto/hash"
import "core:fmt"
import "core:testing"

// The encrypted attachment format (common/attachment_e2ee.odin). Vectors from
// dev/tools/e2ee-vectors.py (attachment_vectors), an independent implementation.

@(private = "file")
KAT_ATTACHMENT_SMALL_BLOB :: "0100000100cd20f8564b570340df92ace38e3964b6f2fd47dbd74533d9ee612cd8"
@(private = "file")
KAT_ATTACHMENT_LARGE_STORED_SIZE :: 151605
@(private = "file")
KAT_ATTACHMENT_LARGE_DATA_SHA256 ::
	"fc489c58cae3f2da764e0c44ca338a95a75e90e297a59e5a2981804948881e71"
@(private = "file")
KAT_ATTACHMENT_LARGE_BLOB_SHA256 ::
	"25e4a0e8442616ecc63fd3b3d437c2dc7dbdf1957e6f2a2c5127c1b4b7ccce5f"

@(private = "file")
testAttachmentKey :: proc() -> AttachmentFileKey {
	label := "haychat-e2ee-test-attachment-key-1"
	return AttachmentFileKey(hashBytes(transmute([]u8)label))
}

// The 150000 deterministic bytes of the large vector: SHA-256 of numbered labels.
@(private = "file")
testAttachmentLargeData :: proc() -> []u8 {
	data := make([]u8, 150000, context.temp_allocator)
	offset := 0
	for index := 0; offset < len(data); index += 1 {
		label := fmt.tprintf("haychat-e2ee-test-attachment-data-%d", index)
		digest := hashBytes(transmute([]u8)label)
		offset += copy(data[offset:], digest[:])
	}
	return data
}

@(private = "file")
testHexBytes :: proc(text: string) -> []u8 {
	bytes := make([]u8, len(text) / 2, context.temp_allocator)
	assert(decodeHexIntoBuffer(text, bytes), "expected valid test hex")
	return bytes
}

// Seals a whole file with AttachmentSealer into one buffer and returns it with its hash.
@(private = "file")
testSealAttachment :: proc(
	key: AttachmentFileKey,
	file: []u8,
) -> (
	blob: []u8,
	digest: AttachmentSHA256,
) {
	sealer, err := AttachmentSealer_init(key, u64(len(file)))
	assert(err == .None, "expected the sealer to start")
	defer AttachmentSealer_wipe(&sealer)
	blob = make([]u8, int(sealer.layout.storedSize), context.temp_allocator)
	scratch := make([]u8, ATTACHMENT_E2EE_CHUNK_BYTES, context.temp_allocator)
	out := make([]u8, ATTACHMENT_E2EE_SEAL_OUTPUT_MAX, context.temp_allocator)
	offset, consumed := 0, 0
	for {
		count, done := AttachmentSealer_nextFileBytes(&sealer)
		if done {
			break
		}
		n, sealErr := AttachmentSealer_next(&sealer, file[consumed:consumed + count], scratch, out)
		assert(sealErr == .None, fmt.tprintf("expected a chunk to seal, got %v", sealErr))
		offset += copy(blob[offset:], out[:n])
		consumed += count
	}
	assert(offset == len(blob), "expected the layout's stored size")
	finishErr: AttachmentE2EEError
	digest, finishErr = AttachmentSealer_finish(&sealer)
	assert(finishErr == .None, "expected the sealer to finish")
	return
}

// Opens blob in pieces of step bytes; returns the file and the first error.
@(private = "file")
testOpenAttachment :: proc(
	key: AttachmentFileKey,
	plainSize: u64,
	blob: []u8,
	expected: AttachmentSHA256,
	step: int,
	storedSize := -1,
) -> (
	file: []u8,
	err: AttachmentE2EEError,
) {
	buffer := make([]u8, ATTACHMENT_E2EE_SEALED_CHUNK_MAX, context.temp_allocator)
	out := make([]u8, ATTACHMENT_E2EE_CHUNK_BYTES, context.temp_allocator)
	stored := storedSize >= 0 ? u64(storedSize) : u64(len(blob))
	opener: AttachmentOpener
	opener, err = AttachmentOpener_init(key, plainSize, stored, buffer)
	if err != .None {
		return nil, err
	}
	defer AttachmentOpener_wipe(&opener)
	result := make([dynamic]u8, context.temp_allocator)
	for start := 0; start < len(blob); start += step {
		piece := blob[start:min(start + step, len(blob))]
		for len(piece) > 0 {
			consumed, produced, feedErr := AttachmentOpener_feed(&opener, piece, out)
			if feedErr != .None {
				return nil, feedErr
			}
			append(&result, ..out[:produced])
			piece = piece[consumed:]
		}
	}
	if finishErr := AttachmentOpener_finish(&opener, expected); finishErr != .None {
		return nil, finishErr
	}
	return result[:], .None
}

@(test)
testAttachmentPadme :: proc(t: ^testing.T) {
	_ = t
	// The values dev/tools/e2ee-vectors.py prints.
	cases := [?][2]u64 {
		{0, 0},
		{1, 1},
		{2, 2},
		{9, 10},
		{100, 104},
		{1000, 1024},
		{65536, 65536},
		{70000, 71680},
		{1234567, 1245184},
		{26214400, 26214400},
	}
	for c in cases {
		assert(
			attachmentPadme(c[0]) == c[1],
			fmt.tprintf("expected padme(%d) = %d, got %d", c[0], c[1], attachmentPadme(c[0])),
		)
	}
	// Never shorter, idempotent, and at most 12% longer.
	for size := u64(1); size < 1 << 26; size = size * 3 / 2 + 1 {
		padded := attachmentPadme(size)
		assert(padded >= size && attachmentPadme(padded) == padded, "expected padme to round up")
		assert(
			f64(padded - size) <= 0.12 * f64(size) + 1,
			fmt.tprintf("expected at most 12%% overhead for %d, got %d", size, padded),
		)
	}
}

@(test)
testAttachmentLayout :: proc(t: ^testing.T) {
	_ = t
	empty, ok := attachmentEncryptedLayout(0)
	assert(ok && empty.chunkCount == 1 && empty.storedSize == 21, "expected one empty chunk")
	exact, _ := attachmentEncryptedLayout(2 * ATTACHMENT_E2EE_CHUNK_BYTES)
	assert(
		exact.chunkCount == 2 && exact.storedSize == 5 + 2 * ATTACHMENT_E2EE_SEALED_CHUNK_MAX,
		"expected two full chunks",
	)
	large, _ := attachmentEncryptedLayout(150000)
	assert(
		large.paddedSize == 151552 &&
		large.chunkCount == 3 &&
		large.storedSize == KAT_ATTACHMENT_LARGE_STORED_SIZE,
		fmt.tprintf("expected the large vector's layout, got %v", large),
	)
	assert(
		attachmentChunkPlainLength(large, 2) == 151552 - 2 * ATTACHMENT_E2EE_CHUNK_BYTES,
		"expected a shorter last chunk",
	)
	_, ok = attachmentEncryptedLayout(ATTACHMENT_E2EE_MAX_FILE_BYTES + 1)
	assert(!ok, "expected a file over the format's limit to be refused")
}

@(test)
testAttachmentVectorsAndRoundTrip :: proc(t: ^testing.T) {
	_ = t
	key := testAttachmentKey()
	small := "hello, file"
	blob, digest := testSealAttachment(key, transmute([]u8)small)
	assert(
		string(blob) == string(testHexBytes(KAT_ATTACHMENT_SMALL_BLOB)),
		"expected the small vector blob",
	)
	file, err := testOpenAttachment(key, u64(len(small)), blob, digest, 7)
	assert(err == .None && string(file) == small, fmt.tprintf("expected it back, got %v", err))

	data := testAttachmentLargeData()
	dataDigest := hash.hash_bytes(.SHA256, data, context.temp_allocator)
	assert(
		string(dataDigest) == string(testHexBytes(KAT_ATTACHMENT_LARGE_DATA_SHA256)),
		"expected the vector's input data",
	)
	large, largeDigest := testSealAttachment(key, data)
	assert(len(large) == KAT_ATTACHMENT_LARGE_STORED_SIZE, "expected the large stored size")
	assert(
		string(largeDigest[:]) == string(testHexBytes(KAT_ATTACHMENT_LARGE_BLOB_SHA256)),
		"expected the large vector's blob hash",
	)
	// Any slicing of the stored bytes opens the same: the wire's 64 KiB, odd sizes, one byte.
	for step in ([?]int{ATTACHMENT_CHUNK_BYTES, 1000, 65541, 1, len(large)}) {
		opened, openErr := testOpenAttachment(key, u64(len(data)), large, largeDigest, step)
		assert(
			openErr == .None && string(opened) == string(data),
			fmt.tprintf("expected step %d to open, got %v", step, openErr),
		)
	}
	emptyBlob, emptyDigest := testSealAttachment(key, nil)
	emptyFile, emptyErr := testOpenAttachment(key, 0, emptyBlob, emptyDigest, 64)
	assert(emptyErr == .None && len(emptyFile) == 0, "expected an empty file to round trip")
}

@(test)
testAttachmentTampering :: proc(t: ^testing.T) {
	_ = t
	key := testAttachmentKey()
	data := testAttachmentLargeData()
	size := u64(len(data))
	blob, digest := testSealAttachment(key, data)
	clone :: proc(source: []u8) -> []u8 {
		copied := make([]u8, len(source), context.temp_allocator)
		copy(copied, source)
		return copied
	}
	expect :: proc(
		name: string,
		key: AttachmentFileKey,
		size: u64,
		blob: []u8,
		digest: AttachmentSHA256,
		want: AttachmentE2EEError,
		storedSize := -1,
	) {
		_, err := testOpenAttachment(key, size, blob, digest, ATTACHMENT_CHUNK_BYTES, storedSize)
		assert(err == want, fmt.tprintf("%s: expected %v, got %v", name, want, err))
	}
	first := ATTACHMENT_E2EE_HEADER_SIZE
	second := first + ATTACHMENT_E2EE_SEALED_CHUNK_MAX

	// A flipped bit anywhere in a chunk, in its tag, and a wrong key.
	flipped := clone(blob)
	flipped[second + 100] ~= 0x01
	expect("flipped ciphertext", key, size, flipped, digest, .BadChunk)
	tag := clone(blob)
	tag[second - 1] ~= 0x80
	expect("flipped tag", key, size, tag, digest, .BadChunk)
	otherKey := key
	otherKey[0] ~= 1
	expect("wrong key", otherKey, size, blob, digest, .BadChunk)

	// Chunks 0 and 1 swapped (both full): the index in the nonce and AAD refuses it.
	swapped := clone(blob)
	copy(swapped[first:second], blob[second:second + ATTACHMENT_E2EE_SEALED_CHUNK_MAX])
	copy(swapped[second:second + ATTACHMENT_E2EE_SEALED_CHUNK_MAX], blob[first:second])
	expect("swapped chunks", key, size, swapped, digest, .BadChunk)

	// Truncation: the last chunk missing (the stored size then disagrees with the layout), or
	// the bytes ending early.
	expect("short stored size", key, size, blob[:second], digest, .BadLayout, second)
	expect("cut short", key, size, blob[:len(blob) - 1], digest, .Truncated, len(blob))
	// Extension: one byte more than the layout.
	longer := make([]u8, len(blob) + 1, context.temp_allocator)
	copy(longer, blob)
	expect("extended", key, size, longer, digest, .TrailingBytes, len(blob))

	// The last flag: a two-chunk file whose first chunk is presented as the last (a file cut
	// after chunk 0 and passed off as smaller) fails, because chunk 0 was sealed with last 0.
	two := data[:2 * ATTACHMENT_E2EE_CHUNK_BYTES - 10]
	twoBlob, twoDigest := testSealAttachment(key, two)
	twoLayout, _ := attachmentEncryptedLayout(u64(len(two)))
	assert(twoLayout.chunkCount == 2, "expected the last flag case to have two chunks")
	oneLayout, _ := attachmentEncryptedLayout(ATTACHMENT_E2EE_CHUNK_BYTES)
	assert(oneLayout.chunkCount == 1, "expected a one-chunk layout")
	cut := twoBlob[:ATTACHMENT_E2EE_HEADER_SIZE + ATTACHMENT_E2EE_SEALED_CHUNK_MAX]
	expect("first chunk as the last", key, ATTACHMENT_E2EE_CHUNK_BYTES, cut, twoDigest, .BadChunk)
	// A chunk sealed with the wrong last flag by hand.
	plain := make([]u8, ATTACHMENT_E2EE_CHUNK_BYTES, context.temp_allocator)
	copy(plain, two)
	wrongLast := clone(twoBlob)
	_, sealErr := sealAttachmentChunk(key, oneLayout, 0, plain, wrongLast[first:])
	assert(sealErr == .None, "expected the hand-sealed chunk")
	expect("wrong last flag", key, u64(len(two)), wrongLast, twoDigest, .BadChunk)

	// Non-zero padding, sealed under the right key and flags, is refused after opening.
	padded := clone(blob)
	layout, _ := attachmentEncryptedLayout(size)
	lastIndex := layout.chunkCount - 1
	lastPlain := make([]u8, attachmentChunkPlainLength(layout, lastIndex), context.temp_allocator)
	lastStart := int(lastIndex) * ATTACHMENT_E2EE_CHUNK_BYTES
	copy(lastPlain, data[lastStart:])
	lastPlain[len(lastPlain) - 1] = 0x01
	lastOffset := first + int(lastIndex) * ATTACHMENT_E2EE_SEALED_CHUNK_MAX
	_, sealErr = sealAttachmentChunk(key, layout, lastIndex, lastPlain, padded[lastOffset:])
	assert(sealErr == .None, "expected the padding case to seal")
	expect("non-zero padding", key, size, padded, digest, .BadPadding)

	// The header: another version, another chunk size.
	version := clone(blob)
	version[0] = 2
	expect("version", key, size, version, digest, .UnsupportedVersion)
	chunkSize := clone(blob)
	chunkSize[2] ~= 0x01
	expect("chunk size", key, size, chunkSize, digest, .BadChunkSize)

	// The whole blob's hash: every chunk opens, but the sealed message names another blob.
	otherDigest := digest
	otherDigest[0] ~= 1
	expect("hash", key, size, blob, otherDigest, .BadHash)
	// The plaintext size from the seal must match the stored size; a smaller size with the
	// same padded length reads a file byte as padding, which is not zero.
	expect("size", key, size - 5000, blob, digest, .BadLayout, len(blob))
	expect("size in the padding", key, size - 1, blob, digest, .BadPadding, len(blob))
}

@(test)
testAttachmentSealerOrder :: proc(t: ^testing.T) {
	_ = t
	sealer, err := AttachmentSealer_init(testAttachmentKey(), 10)
	assert(err == .None, "expected the sealer")
	defer AttachmentSealer_wipe(&sealer)
	scratch: [ATTACHMENT_E2EE_CHUNK_BYTES]u8
	out := make([]u8, ATTACHMENT_E2EE_SEAL_OUTPUT_MAX, context.temp_allocator)
	file := [10]u8{1, 2, 3, 4, 5, 6, 7, 8, 9, 10}
	_, err = AttachmentSealer_next(&sealer, file[:9], scratch[:], out)
	assert(err == .OutOfOrder, "expected the wrong file byte count to be refused")
	_, err = AttachmentSealer_finish(&sealer)
	assert(err == .OutOfOrder, "expected finish before the last chunk to be refused")
	n, sealErr := AttachmentSealer_next(&sealer, file[:], scratch[:], out)
	assert(sealErr == .None && n == 5 + 10 + 16, fmt.tprintf("expected one chunk, got %d", n))
	assert(scratch == {}, "expected the scratch plaintext to be wiped")
	_, err = AttachmentSealer_next(&sealer, nil, scratch[:], out)
	assert(err == .OutOfOrder, "expected nothing after the last chunk")
	_, err = AttachmentSealer_finish(&sealer)
	assert(err == .None, "expected the sealer to finish")
}
