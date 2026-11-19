package server

import "../common"
import "core:crypto/sha2"
import "core:fmt"
import "core:os"
import "core:testing"
import "core:time"

// The storage worker's state machine on a temporary blob directory (storage.odin).

@(private = "file")
storageTestDir :: proc(prefix: string) -> string {
	// The helper allocates its path pieces; they live as long as the test.
	allocator := context.allocator
	context.allocator = context.temp_allocator
	dir := routerTestCreateTempDir(prefix)
	context.allocator = allocator
	for name in ([]string{ATTACHMENT_INCOMING_DIR_NAME, ATTACHMENT_BLOBS_DIR_NAME}) {
		path := fmt.tprintf("%s/%s", dir, name)
		assert(os.make_directory(path, os.perm(0o700)) == nil, "expected a blob subdirectory")
	}
	return dir
}

@(private = "file")
storageTestPlenty :: proc(dir: string) -> (i64, bool) {
	_ = dir
	return 1 << 40, true
}

@(private = "file")
storageTestNearlyFull :: proc(dir: string) -> (i64, bool) {
	_ = dir
	return 1000, true
}

@(private = "file")
storageTestLater :: proc "contextless" () -> time.Time {
	return time.time_add(time.now(), 2 * time.Hour)
}

@(private = "file")
storageTestBlob :: proc(seed: u8) -> common.AttachmentBlobID {
	blobId: common.AttachmentBlobID
	for index in 0 ..< len(blobId) {
		blobId[index] = seed + u8(index)
	}
	return blobId
}

@(private = "file")
storageTestData :: proc(size: int, seed: u8) -> []u8 {
	data := make([]u8, size)
	for index in 0 ..< size {
		data[index] = u8(index * 7) ~ seed
	}
	return data
}

@(private = "file")
storageTestHash :: proc(data: []u8) -> common.AttachmentSHA256 {
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, data)
	digest: common.AttachmentSHA256
	sha2.final(&ctx, digest[:])
	return digest
}

@(private = "file")
storageTestOpen :: proc(
	worker: ^StorageWorker,
	blobId: common.AttachmentBlobID,
	size: u64,
	resume := false,
	minFree := i64(0),
) -> StorageUploadOpened {
	result, answered := StorageWorker_handle(
		worker,
		StorageUploadOpen{blobId = blobId, size = size, minFreeBytes = minFree, resume = resume},
	)
	assert(answered, "expected an open to be answered")
	opened, ok := result.(StorageUploadOpened)
	assert(ok, fmt.tprintf("expected StorageUploadOpened, got %v", result))
	return opened
}

// Writes data in chunks from offset, each through the worker, and checks every answer.
@(private = "file")
storageTestWrite :: proc(
	worker: ^StorageWorker,
	blobId: common.AttachmentBlobID,
	data: []u8,
	offset: u64,
) {
	position := offset
	for position < u64(len(data)) {
		end := min(position + common.ATTACHMENT_CHUNK_BYTES, u64(len(data)))
		chunk := make([]u8, end - position)
		copy(chunk, data[position:end])
		request := StorageUploadWrite {
			blobId = blobId,
			offset = position,
			data   = chunk,
		}
		result, answered := StorageWorker_handle(worker, request)
		StorageRequest_deinit(request)
		written, ok := result.(StorageUploadWritten)
		assert(
			answered && ok && written.ok && written.offset == position,
			fmt.tprintf("expected the chunk at %d written, got %v", position, result),
		)
		position = end
	}
}

@(private = "file")
storageTestFinish :: proc(
	worker: ^StorageWorker,
	blobId: common.AttachmentBlobID,
	size: u64,
	sha: common.AttachmentSHA256,
) -> StorageUploadFinished {
	result, answered := StorageWorker_handle(
		worker,
		StorageUploadFinish{blobId = blobId, size = size, sha256 = sha},
	)
	finished, ok := result.(StorageUploadFinished)
	assert(answered && ok, fmt.tprintf("expected StorageUploadFinished, got %v", result))
	return finished
}

@(private = "file")
storageTestMode :: proc(path: string) -> int {
	info, err := os.stat(path, context.temp_allocator)
	assert(err == nil, fmt.tprintf("expected %q to exist", path))
	return int(transmute(u32)info.mode) & 0o777
}

@(test)
testStorageWorkerStoresAndReadsABlob :: proc(t: ^testing.T) {
	_ = t
	dir := storageTestDir("haychat_storage_store")
	defer os.remove_all(dir)
	worker := StorageWorker_init(dir)
	defer StorageWorker_deinit(&worker)
	worker.freeBytes = storageTestPlenty

	blobId := storageTestBlob(1)
	data := storageTestData(3 * common.ATTACHMENT_CHUNK_BYTES + 100, 5)
	defer delete(data)
	opened := storageTestOpen(&worker, blobId, u64(len(data)))
	assert(opened.ok && opened.received == 0, fmt.tprintf("expected a new upload, got %v", opened))
	part := storagePartPath(&worker, blobId)
	defer delete(part)
	assert(storageTestMode(part) == 0o600, "expected the part file to be mode 0600")

	// A second begin of the same blob cannot create its file again.
	again := storageTestOpen(&worker, blobId, u64(len(data)))
	assert(!again.ok, "expected a begin of an open upload refused")

	storageTestWrite(&worker, blobId, data, 0)
	finished := storageTestFinish(&worker, blobId, u64(len(data)), storageTestHash(data))
	assert(
		finished.ok && !finished.mismatch,
		fmt.tprintf("expected a stored blob, got %v", finished),
	)
	assert(!os.exists(part), "expected the part file to be renamed away")
	stored := storageBlobPath(&worker, blobId)
	defer delete(stored)
	assert(os.exists(stored), "expected the blob under blobs/<2 hex>/<hex>")
	assert(storageTestMode(stored) == 0o600, "expected the blob to be mode 0600")
	shard := fmt.tprintf("%s/%s/%s", dir, ATTACHMENT_BLOBS_DIR_NAME, "01")
	assert(storageTestMode(shard) == 0o700, "expected the shard directory to be mode 0700")

	for offset := u64(0); offset < u64(len(data)); offset += common.ATTACHMENT_CHUNK_BYTES {
		length := int(min(u64(common.ATTACHMENT_CHUNK_BYTES), u64(len(data)) - offset))
		result, _ := StorageWorker_handle(
			&worker,
			StorageRead{blobId = blobId, offset = offset, length = length},
		)
		read, ok := result.(StorageReadData)
		assert(ok && read.ok && len(read.data) == length, "expected a full chunk read back")
		for value, index in read.data {
			assert(value == data[int(offset) + index], "expected the stored bytes back")
		}
		StorageResult_deinit(result)
	}
	tooLong, _ := StorageWorker_handle(
		&worker,
		StorageRead{blobId = blobId, offset = 0, length = common.ATTACHMENT_CHUNK_BYTES + 1},
	)
	assert(!tooLong.(StorageReadData).ok, "expected a read longer than a chunk refused")
}

@(test)
testStorageWorkerRefusesBadWritesAndAMismatch :: proc(t: ^testing.T) {
	_ = t
	dir := storageTestDir("haychat_storage_mismatch")
	defer os.remove_all(dir)
	worker := StorageWorker_init(dir)
	defer StorageWorker_deinit(&worker)
	worker.freeBytes = storageTestPlenty

	blobId := storageTestBlob(2)
	data := storageTestData(1000, 9)
	defer delete(data)
	assert(storageTestOpen(&worker, blobId, 1000).ok, "expected a new upload")

	for bad in ([]struct {
			offset: u64,
			length: int,
		}{{offset = 10, length = 10}, {offset = 0, length = 1001}}) {
		chunk := make([]u8, bad.length)
		request := StorageUploadWrite {
			blobId = blobId,
			offset = bad.offset,
			data   = chunk,
		}
		result, _ := StorageWorker_handle(&worker, request)
		StorageRequest_deinit(request)
		assert(!result.(StorageUploadWritten).ok, fmt.tprintf("expected %v refused", bad))
	}

	storageTestWrite(&worker, blobId, data, 0)
	wrong := storageTestHash(data)
	wrong[0] ~= 1
	finished := storageTestFinish(&worker, blobId, 1000, wrong)
	assert(finished.mismatch && !finished.ok, "expected a hash mismatch")
	part := storagePartPath(&worker, blobId)
	defer delete(part)
	stored := storageBlobPath(&worker, blobId)
	defer delete(stored)
	assert(!os.exists(part) && !os.exists(stored), "expected a mismatch to delete the upload")

	// A short upload is a mismatch too.
	short := storageTestBlob(3)
	assert(storageTestOpen(&worker, short, 1000).ok, "expected a new upload")
	storageTestWrite(&worker, short, data[:500], 0)
	shortFinished := storageTestFinish(&worker, short, 1000, storageTestHash(data))
	assert(shortFinished.mismatch, "expected an incomplete upload to mismatch")
}

@(test)
testStorageWorkerResumesAtTheStoredLength :: proc(t: ^testing.T) {
	_ = t
	dir := storageTestDir("haychat_storage_resume")
	defer os.remove_all(dir)
	worker := StorageWorker_init(dir)
	defer StorageWorker_deinit(&worker)
	worker.freeBytes = storageTestPlenty

	blobId := storageTestBlob(4)
	data := storageTestData(5 * common.ATTACHMENT_CHUNK_BYTES, 3)
	defer delete(data)
	assert(storageTestOpen(&worker, blobId, u64(len(data))).ok, "expected a new upload")
	storageTestWrite(&worker, blobId, data[:2 * common.ATTACHMENT_CHUNK_BYTES], 0)
	// The session ends: the file is closed and kept.
	_, answered := StorageWorker_handle(&worker, StorageUploadClose{blobId = blobId})
	assert(!answered, "expected a close to take no answer")

	resumed := storageTestOpen(&worker, blobId, u64(len(data)), resume = true)
	assert(
		resumed.ok && resumed.received == 2 * common.ATTACHMENT_CHUNK_BYTES,
		fmt.tprintf("expected the resume at the stored length, got %v", resumed),
	)
	storageTestWrite(&worker, blobId, data, resumed.received)
	finished := storageTestFinish(&worker, blobId, u64(len(data)), storageTestHash(data))
	assert(finished.ok, "expected the rebuilt hash to match the whole file")

	// A resume of a blob without a part file, or with a size its file exceeds, is refused.
	missing := storageTestOpen(&worker, storageTestBlob(5), 10, resume = true)
	assert(!missing.ok, "expected a resume without a part file refused")
	other := storageTestBlob(6)
	assert(storageTestOpen(&worker, other, 100).ok, "expected a new upload")
	storageTestWrite(&worker, other, data[:100], 0)
	StorageWorker_handle(&worker, StorageUploadClose{blobId = other})
	smaller := storageTestOpen(&worker, other, 50, resume = true)
	assert(!smaller.ok, "expected a part file larger than the size refused")

	// A cancel deletes the part file.
	StorageWorker_handle(&worker, StorageUploadClose{blobId = other, discard = true})
	part := storagePartPath(&worker, other)
	defer delete(part)
	assert(!os.exists(part), "expected a discarded upload's part file deleted")
}

@(test)
testStorageWorkerKeepsTheFreeDiskReserve :: proc(t: ^testing.T) {
	_ = t
	dir := storageTestDir("haychat_storage_reserve")
	defer os.remove_all(dir)
	worker := StorageWorker_init(dir)
	defer StorageWorker_deinit(&worker)
	worker.freeBytes = storageTestNearlyFull

	refused := storageTestOpen(&worker, storageTestBlob(7), 600, minFree = 500)
	assert(!refused.ok && refused.full, "expected the reserve to refuse the upload")
	part := storagePartPath(&worker, storageTestBlob(7))
	defer delete(part)
	assert(!os.exists(part), "expected no part file for a refused upload")
	fits := storageTestOpen(&worker, storageTestBlob(8), 400, minFree = 500)
	assert(fits.ok, "expected an upload that leaves the reserve free")

	// The real statfs works on the directory.
	free, freeOK := storageFreeBytes(dir)
	assert(freeOK && free > 0, "expected statfs to report free space")
}

@(test)
testStorageWorkerScanFindsOldFilesAndDeletesOrphans :: proc(t: ^testing.T) {
	_ = t
	dir := storageTestDir("haychat_storage_scan")
	defer os.remove_all(dir)
	worker := StorageWorker_init(dir)
	defer StorageWorker_deinit(&worker)
	worker.freeBytes = storageTestPlenty

	data := storageTestData(64, 1)
	defer delete(data)
	stored := storageTestBlob(0x10)
	assert(storageTestOpen(&worker, stored, 64).ok, "expected a new upload")
	storageTestWrite(&worker, stored, data, 0)
	assert(storageTestFinish(&worker, stored, 64, storageTestHash(data)).ok, "expected a blob")
	partial := storageTestBlob(0x20)
	assert(storageTestOpen(&worker, partial, 64).ok, "expected a new upload")
	StorageWorker_handle(&worker, StorageUploadClose{blobId = partial})
	open := storageTestBlob(0x30)
	assert(storageTestOpen(&worker, open, 64).ok, "expected an upload left open")
	stray := fmt.tprintf("%s/%s/notes.txt", dir, ATTACHMENT_INCOMING_DIR_NAME)
	assert(os.write_entire_file_from_bytes(stray, data) == nil, "expected a stray file")

	// Everything is younger than an hour: nothing is a candidate yet, nothing is deleted.
	young, _ := StorageWorker_handle(&worker, StorageScan{})
	assert(len(young.(StorageScanResult).files) == 0, "expected no young file listed")
	StorageResult_deinit(young)
	assert(os.exists(stray), "expected a young stray file kept")

	worker.now = storageTestLater
	result, _ := StorageWorker_handle(&worker, StorageScan{})
	defer StorageResult_deinit(result)
	files := result.(StorageScanResult).files
	assert(len(files) == 2, fmt.tprintf("expected the blob and the closed part, got %v", files))
	foundStored, foundPartial := false, false
	for file in files {
		foundStored |= file.blobId == stored && !file.isPart
		foundPartial |= file.blobId == partial && file.isPart
	}
	assert(foundStored && foundPartial, fmt.tprintf("expected both files listed, got %v", files))
	assert(!os.exists(stray), "expected an old stray file deleted by the scan")

	orphans := make([dynamic]StorageFile)
	append(&orphans, StorageFile{blobId = partial, isPart = true})
	append(&orphans, StorageFile{blobId = open, isPart = true})
	request := StorageDeleteOrphans {
		files = orphans,
	}
	deleted, _ := StorageWorker_handle(&worker, request)
	StorageRequest_deinit(request)
	assert(
		deleted.(StorageOrphansDeleted).deleted == 1,
		"expected the closed part deleted and the open upload kept",
	)
	partialPath := storagePartPath(&worker, partial)
	defer delete(partialPath)
	assert(!os.exists(partialPath), "expected the orphan part file gone")

	blobs := make([dynamic]common.DatabaseAttachmentBlob)
	append(&blobs, common.DatabaseAttachmentBlob{blobId = stored, state = .Ready})
	sweep := StorageDeleteBlobs {
		blobs = blobs,
	}
	swept, _ := StorageWorker_handle(&worker, sweep)
	StorageRequest_deinit(sweep)
	assert(swept.(StorageBlobsDeleted).deleted == 1, "expected the swept blob's file deleted")
	storedPath := storageBlobPath(&worker, stored)
	defer delete(storedPath)
	assert(!os.exists(storedPath), "expected the swept blob gone")
}

// Protocol 28: the free space an admin's ServerAdminAttachmentUsage reports comes from the
// worker's freeBytes on the blob directory, and an unreadable volume says so.
@(test)
testStorageReportsFreeSpace :: proc(t: ^testing.T) {
	_ = t
	worker := StorageWorker_init("/nonexistent-haychat-blob-dir")
	defer StorageWorker_deinit(&worker)
	worker.freeBytes = proc(dir: string) -> (i64, bool) {
		assert(dir == "/nonexistent-haychat-blob-dir", "expected the blob directory asked")
		return 5 << 30, true
	}
	result, answered := StorageWorker_handle(&worker, StorageFreeSpace{})
	free, ok := result.(StorageFreeSpaceResult)
	assert(
		answered && ok && free.ok && free.freeBytes == 5 << 30,
		fmt.tprintf("expected 5 GiB free, got %v", result),
	)
	worker.freeBytes = storageFreeBytes
	result, answered = StorageWorker_handle(&worker, StorageFreeSpace{})
	free = result.(StorageFreeSpaceResult)
	assert(
		answered && !free.ok && free.freeBytes == 0,
		fmt.tprintf("expected an unreadable volume reported, got %v", result),
	)
}
