package server

import "../common"
import "core:crypto/sha2"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/linux"
import "core:time"

// The storage worker (protocol 26, attachments plan D4, D5): a service thread that does every
// attachment file operation and the running SHA-256 of each upload. It never talks to
// PostgreSQL; the router asks the database worker what is allowed and this worker what is on
// disk. Its queue is the IPC ring for IPC_Endpoint_Kind.Storage, and every command it answers
// comes back to the router as a StorageResponse with the command's request ID.
//
// Layout under HAYCHAT_ATTACHMENT_DIR (made by attachmentDirectoryPreflightError at startup):
//
//   incoming/<32 hex>.part    an upload in progress, appended in order
//   blobs/<2 hex>/<32 hex>    a finished blob, renamed in after fsync, directory fsynced
//
// Names come only from the server's random blob IDs, never from client data. Files are 0600
// and directories 0700. StorageWorker_handle is the whole state machine and needs no thread,
// so storage_test.odin drives it on a temporary directory.

// Files the startup scan may delete are at least this old, so a file whose row is being
// created right now is never mistaken for an orphan.
STORAGE_ORPHAN_MIN_AGE :: time.Hour
STORAGE_IDLE_WAIT :: 100 * time.Millisecond

StorageUploadOpen :: struct {
	blobId:       common.AttachmentBlobID,
	size:         u64,
	// Begin: refuse unless the volume keeps this much free after the upload (D21).
	minFreeBytes: i64,
	// Resume: open the existing part file and rebuild its hash instead of creating it.
	resume:       bool,
}

StorageUploadWrite :: struct {
	blobId: common.AttachmentBlobID,
	offset: u64,
	data:   []u8, // owned
}

StorageUploadFinish :: struct {
	blobId: common.AttachmentBlobID,
	size:   u64,
	sha256: common.AttachmentSHA256,
}

// Closes an upload's file. discard deletes the part file too (a cancel); otherwise it stays
// for a resume (a disconnect). Never answered.
StorageUploadClose :: struct {
	blobId:  common.AttachmentBlobID,
	discard: bool,
}

StorageRead :: struct {
	blobId: common.AttachmentBlobID,
	offset: u64,
	length: int,
}

// Deletes the files of rows the sweeper deleted (whatever their state, both names).
StorageDeleteBlobs :: struct {
	blobs: [dynamic]common.DatabaseAttachmentBlob, // owned
}

// Lists the files old enough to be orphans; deletes and logs files whose names are not ours.
StorageScan :: struct {}

StorageFile :: struct {
	blobId: common.AttachmentBlobID,
	isPart: bool,
}

// Deletes and logs these files (orphans: no row, or a row in a state that has no such file).
StorageDeleteOrphans :: struct {
	files: [dynamic]StorageFile, // owned
}

// The free bytes on the blob directory's volume (protocol 28, ServerAdminAttachmentUsage).
StorageFreeSpace :: struct {}

StorageRequest :: union {
	StorageUploadOpen,
	StorageUploadWrite,
	StorageUploadFinish,
	StorageUploadClose,
	StorageRead,
	StorageDeleteBlobs,
	StorageScan,
	StorageDeleteOrphans,
	StorageFreeSpace,
}

StorageUploadOpened :: struct {
	blobId:   common.AttachmentBlobID,
	ok:       bool,
	full:     bool, // refused by the free-disk reserve
	received: u64, // bytes already in the part file (0 for a new one)
}

StorageUploadWritten :: struct {
	blobId: common.AttachmentBlobID,
	offset: u64,
	length: int,
	ok:     bool,
}

StorageUploadFinished :: struct {
	blobId:   common.AttachmentBlobID,
	ok:       bool,
	mismatch: bool, // the size or hash differed; the part file is deleted
}

StorageReadData :: struct {
	blobId:  common.AttachmentBlobID,
	offset:  u64,
	data:    []u8, // owned
	ok:      bool,
	missing: bool, // the blob's file does not exist (ENOENT), not another read error (#132)
	// With missing: the blob directory looked intact when the file was not found (blobs/ is a
	// readable directory with at least one entry, and the blob's shard directory exists), so
	// the file itself is gone rather than the volume. Only then does the router mark the row
	// removed (#132 follow-up); a missing or empty blobs/ or shard directory while the row
	// exists means a mount or restore problem, and nothing is marked.
	blobDirectoryIntact: bool,
}

StorageBlobsDeleted :: struct {
	deleted: int,
}

StorageScanResult :: struct {
	files: [dynamic]StorageFile, // owned
}

StorageOrphansDeleted :: struct {
	deleted: int,
}

StorageFreeSpaceResult :: struct {
	freeBytes: i64,
	ok:        bool,
}

StorageResult :: union {
	StorageUploadOpened,
	StorageUploadWritten,
	StorageUploadFinished,
	StorageReadData,
	StorageBlobsDeleted,
	StorageScanResult,
	StorageOrphansDeleted,
	StorageFreeSpaceResult,
}

// Router -> storage worker. requestId 0 asks for no answer.
StorageCommand :: struct {
	requestId: u64,
	request:   StorageRequest,
}

// Storage worker -> router.
StorageResponse :: struct {
	requestId: u64,
	result:    StorageResult,
}

// Exhaustive on purpose: a new variant must decide what it owns.
StorageRequest_deinit :: proc(request: StorageRequest) {
	switch r in request {
	case StorageUploadWrite:
		delete(r.data)
	case StorageDeleteBlobs:
		delete(r.blobs)
	case StorageDeleteOrphans:
		delete(r.files)
	case StorageUploadOpen,
	     StorageUploadFinish,
	     StorageUploadClose,
	     StorageRead,
	     StorageScan,
	     StorageFreeSpace:
	case nil:
	}
}

StorageResult_deinit :: proc(result: StorageResult) {
	switch r in result {
	case StorageReadData:
		delete(r.data)
	case StorageScanResult:
		delete(r.files)
	case StorageUploadOpened,
	     StorageUploadWritten,
	     StorageUploadFinished,
	     StorageBlobsDeleted,
	     StorageOrphansDeleted,
	     StorageFreeSpaceResult:
	case nil:
	}
}

@(private = "file")
StorageUpload :: struct {
	file:    ^os.File,
	written: u64,
	size:    u64,
	hash:    sha2.Context_256,
}

// Free bytes on the volume that holds dir; tests replace it.
StorageFreeBytesProc :: #type proc(dir: string) -> (i64, bool)

StorageWorker :: struct {
	dir:       string, // borrowed
	uploads:   map[common.AttachmentBlobID]^StorageUpload,
	freeBytes: StorageFreeBytesProc,
	// The time the scan compares file ages with; tests replace it.
	now:       proc "contextless" () -> time.Time,
}

StorageWorker_init :: proc(dir: string) -> StorageWorker {
	return StorageWorker {
		dir = dir,
		uploads = make(map[common.AttachmentBlobID]^StorageUpload),
		freeBytes = storageFreeBytes,
		now = time.now,
	}
}

StorageWorker_deinit :: proc(worker: ^StorageWorker) {
	for _, upload in worker.uploads {
		os.close(upload.file)
		free(upload)
	}
	delete(worker.uploads)
	worker.uploads = nil
}

// statvfs(2) through statfs: the blocks an unprivileged process may use.
storageFreeBytes :: proc(dir: string) -> (i64, bool) {
	path, err := strings.clone_to_cstring(dir)
	if err != nil {
		return 0, false
	}
	defer delete(path)
	stats: linux.Stat_FS
	if linux.statfs(path, &stats) != nil {
		return 0, false
	}
	blockSize := i64(stats.frsize) if stats.frsize > 0 else i64(stats.bsize)
	return i64(stats.bavail) * blockSize, true
}

storageBlobHex :: proc(blobId: common.AttachmentBlobID, allocator := context.allocator) -> string {
	id := blobId
	hex := common.encodeBytesToHex(id[:])
	if allocator == context.allocator {
		return hex
	}
	defer delete(hex)
	return strings.clone(hex, allocator)
}

// incoming/<hex>.part, allocated.
storagePartPath :: proc(worker: ^StorageWorker, blobId: common.AttachmentBlobID) -> string {
	hex := storageBlobHex(blobId)
	defer delete(hex)
	return fmt.aprintf("%s/%s/%s.part", worker.dir, ATTACHMENT_INCOMING_DIR_NAME, hex)
}

// blobs/<2 hex>/<hex>, allocated.
storageBlobPath :: proc(worker: ^StorageWorker, blobId: common.AttachmentBlobID) -> string {
	hex := storageBlobHex(blobId)
	defer delete(hex)
	return fmt.aprintf("%s/%s/%s/%s", worker.dir, ATTACHMENT_BLOBS_DIR_NAME, hex[:2], hex)
}

@(private = "file")
storageCloseUpload :: proc(worker: ^StorageWorker, blobId: common.AttachmentBlobID) {
	if upload, ok := worker.uploads[blobId]; ok {
		os.close(upload.file)
		free(upload)
		delete_key(&worker.uploads, blobId)
	}
}

// fsyncs a directory, so a rename into it survives a crash.
@(private = "file")
storageSyncDirectory :: proc(path: string) -> bool {
	dir, err := os.open(path, {.Read})
	if err != nil {
		return false
	}
	defer os.close(dir)
	return os.sync(dir) == nil
}

// Handles one command. Returns the answer, or false when the command takes none.
StorageWorker_handle :: proc(
	worker: ^StorageWorker,
	request: StorageRequest,
) -> (
	result: StorageResult,
	answered: bool,
) {
	switch r in request {
	case StorageUploadOpen:
		return storageUploadOpen(worker, r), true
	case StorageUploadWrite:
		return storageUploadWrite(worker, r), true
	case StorageUploadFinish:
		return storageUploadFinish(worker, r), true
	case StorageUploadClose:
		storageCloseUpload(worker, r.blobId)
		if r.discard {
			path := storagePartPath(worker, r.blobId)
			defer delete(path)
			_ = os.remove(path)
		}
		return nil, false
	case StorageRead:
		return storageRead(worker, r), true
	case StorageDeleteBlobs:
		deleted := 0
		for blob in r.blobs {
			storageCloseUpload(worker, blob.blobId)
			part := storagePartPath(worker, blob.blobId)
			stored := storageBlobPath(worker, blob.blobId)
			if os.remove(part) == nil {
				deleted += 1
			}
			if os.remove(stored) == nil {
				deleted += 1
			}
			delete(part)
			delete(stored)
		}
		return StorageBlobsDeleted{deleted = deleted}, true
	case StorageScan:
		return storageScan(worker), true
	case StorageFreeSpace:
		freeBytes, ok := worker.freeBytes(worker.dir)
		return StorageFreeSpaceResult{freeBytes = ok ? max(freeBytes, 0) : 0, ok = ok}, true
	case StorageDeleteOrphans:
		deleted := 0
		for file in r.files {
			if _, open := worker.uploads[file.blobId]; open && file.isPart {
				continue
			}
			path: string
			if file.isPart {
				path = storagePartPath(worker, file.blobId)
			} else {
				path = storageBlobPath(worker, file.blobId)
			}
			if os.remove(path) == nil {
				deleted += 1
				fmt.printfln("[Storage] Deleted orphan attachment file %s", path)
			}
			delete(path)
		}
		return StorageOrphansDeleted{deleted = deleted}, true
	case nil:
	}
	return nil, false
}

@(private = "file")
storageUploadOpen :: proc(worker: ^StorageWorker, request: StorageUploadOpen) -> StorageResult {
	refused := StorageUploadOpened {
		blobId = request.blobId,
	}
	if upload, open := worker.uploads[request.blobId]; open {
		// A resume while the last session's file is still open (its close is still queued, or
		// it never came): continue from what is written.
		if !request.resume || upload.size != request.size {
			return refused
		}
		return StorageUploadOpened{blobId = request.blobId, ok = true, received = upload.written}
	}
	path := storagePartPath(worker, request.blobId)
	defer delete(path)
	upload := new(StorageUpload)
	upload.size = request.size
	sha2.init_256(&upload.hash)
	if !request.resume {
		if freeBytes, freeOK := worker.freeBytes(worker.dir);
		   !freeOK || freeBytes - i64(request.size) < request.minFreeBytes {
			free(upload)
			refused.full = true
			return refused
		}
		file, err := os.open(path, {.Write, .Create, .Excl}, os.perm(0o600))
		if err != nil {
			free(upload)
			return refused
		}
		upload.file = file
	} else {
		file, err := os.open(path, {.Read, .Write})
		if err != nil {
			free(upload)
			return refused
		}
		upload.file = file
		length, sizeErr := os.file_size(file)
		if sizeErr != nil || length < 0 || u64(length) > request.size {
			os.close(file)
			free(upload)
			return refused
		}
		// Rebuild the running hash from what is already stored (D9).
		buffer := make([]u8, common.ATTACHMENT_CHUNK_BYTES)
		defer delete(buffer)
		offset := i64(0)
		for offset < length {
			n, readErr := os.read_at(file, buffer[:min(i64(len(buffer)), length - offset)], offset)
			if readErr != nil || n <= 0 {
				os.close(file)
				free(upload)
				return refused
			}
			sha2.update(&upload.hash, buffer[:n])
			offset += i64(n)
		}
		upload.written = u64(length)
	}
	worker.uploads[request.blobId] = upload
	return StorageUploadOpened{blobId = request.blobId, ok = true, received = upload.written}
}

@(private = "file")
storageUploadWrite :: proc(worker: ^StorageWorker, request: StorageUploadWrite) -> StorageResult {
	written := StorageUploadWritten {
		blobId = request.blobId,
		offset = request.offset,
		length = len(request.data),
	}
	upload, open := worker.uploads[request.blobId]
	if !open ||
	   request.offset != upload.written ||
	   len(request.data) == 0 ||
	   upload.written + u64(len(request.data)) > upload.size {
		return written
	}
	n, err := os.write_at(upload.file, request.data, i64(request.offset))
	if err != nil || n != len(request.data) {
		return written
	}
	sha2.update(&upload.hash, request.data)
	upload.written += u64(n)
	written.ok = true
	return written
}

@(private = "file")
storageUploadFinish :: proc(worker: ^StorageWorker, request: StorageUploadFinish) -> StorageResult {
	finished := StorageUploadFinished {
		blobId = request.blobId,
	}
	upload, open := worker.uploads[request.blobId]
	if !open {
		return finished
	}
	part := storagePartPath(worker, request.blobId)
	defer delete(part)
	digest: common.AttachmentSHA256
	sha2.final(&upload.hash, digest[:])
	expected := request.sha256
	if upload.written != request.size ||
	   upload.size != request.size ||
	   !common.constantTimeEqual(digest[:], expected[:]) {
		storageCloseUpload(worker, request.blobId)
		_ = os.remove(part)
		finished.mismatch = true
		return finished
	}
	syncOK := os.sync(upload.file) == nil
	storageCloseUpload(worker, request.blobId)
	if !syncOK {
		return finished
	}
	hex := storageBlobHex(request.blobId)
	defer delete(hex)
	shard := fmt.aprintf("%s/%s/%s", worker.dir, ATTACHMENT_BLOBS_DIR_NAME, hex[:2])
	defer delete(shard)
	if !os.exists(shard) {
		if os.make_directory(shard, os.perm(0o700)) != nil && !os.exists(shard) {
			return finished
		}
		parent := fmt.aprintf("%s/%s", worker.dir, ATTACHMENT_BLOBS_DIR_NAME)
		defer delete(parent)
		storageSyncDirectory(parent)
	}
	stored := storageBlobPath(worker, request.blobId)
	defer delete(stored)
	if os.rename(part, stored) != nil {
		return finished
	}
	finished.ok = storageSyncDirectory(shard)
	return finished
}

@(private = "file")
storageRead :: proc(worker: ^StorageWorker, request: StorageRead) -> StorageResult {
	data := StorageReadData {
		blobId = request.blobId,
		offset = request.offset,
	}
	if request.length <= 0 || request.length > common.ATTACHMENT_CHUNK_BYTES {
		return data
	}
	path := storageBlobPath(worker, request.blobId)
	defer delete(path)
	file, err := os.open(path, {.Read})
	if err != nil {
		// A row whose file is gone (a database restored without its blob directory) is told
		// apart from a failing disk, so the reader hears "Attachment not found" (#132).
		data.missing = err == os.General_Error.Not_Exist
		if data.missing {
			data.blobDirectoryIntact = storageBlobDirectoryIntact(worker, request.blobId)
		}
		return data
	}
	defer os.close(file)
	buffer := make([]u8, request.length)
	n, readErr := os.read_at(file, buffer, i64(request.offset))
	if readErr != nil || n <= 0 {
		delete(buffer)
		return data
	}
	data.data = buffer[:n]
	data.ok = true
	return data
}

// Whether a blob whose file was not found sits in a blob directory that looks intact (#132
// follow-up): blobs/ is a directory this worker can read and has at least one entry, and the
// blob's shard directory blobs/<2 hex> exists. Shard directories are never deleted, so a row
// whose file was stored here always has one. A volume that did not mount, a fresh directory
// beside a restored database, or a partial restore fails this, and the router then marks
// nothing.
@(private = "file")
storageBlobDirectoryIntact :: proc(
	worker: ^StorageWorker,
	blobId: common.AttachmentBlobID,
) -> bool {
	blobs := fmt.aprintf("%s/%s", worker.dir, ATTACHMENT_BLOBS_DIR_NAME)
	defer delete(blobs)
	entries, err := os.read_directory_by_path(blobs, 1, context.allocator)
	if err != nil {
		return false
	}
	found := len(entries) > 0
	os.file_info_slice_delete(entries, context.allocator)
	if !found {
		return false
	}
	hex := storageBlobHex(blobId)
	defer delete(hex)
	shard := fmt.aprintf("%s/%s", blobs, hex[:2])
	defer delete(shard)
	return os.is_directory(shard)
}

// Whether name is 32 lowercase hex characters, and the blob ID it spells.
@(private = "file")
storageParseBlobName :: proc(name: string) -> (common.AttachmentBlobID, bool) {
	blobId: common.AttachmentBlobID
	if len(name) != 2 * common.ATTACHMENT_BLOB_ID_SIZE {
		return {}, false
	}
	for c in name {
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
			return {}, false
		}
	}
	ok := common.decodeHexIntoBuffer(name, blobId[:])
	return blobId, ok
}

@(private = "file")
storageOldEnough :: proc(worker: ^StorageWorker, info: os.File_Info) -> bool {
	return time.diff(info.modification_time, worker.now()) >= STORAGE_ORPHAN_MIN_AGE
}

// Lists incoming/*.part and blobs/<2 hex>/* files at least STORAGE_ORPHAN_MIN_AGE old. A file
// in those directories whose name is not one this worker writes is deleted and logged here.
@(private = "file")
storageScan :: proc(worker: ^StorageWorker) -> StorageResult {
	result := StorageScanResult {
		files = make([dynamic]StorageFile),
	}
	incoming := fmt.aprintf("%s/%s", worker.dir, ATTACHMENT_INCOMING_DIR_NAME)
	defer delete(incoming)
	if infos, err := os.read_all_directory_by_path(incoming, context.allocator); err == nil {
		defer os.file_info_slice_delete(infos, context.allocator)
		for info in infos {
			if !storageOldEnough(worker, info) {
				continue
			}
			name := info.name
			if strings.has_suffix(name, ".part") {
				if blobId, ok := storageParseBlobName(name[:len(name) - 5]); ok {
					if _, open := worker.uploads[blobId]; !open {
						append(&result.files, StorageFile{blobId = blobId, isPart = true})
					}
					continue
				}
			}
			storageRemoveStray(info)
		}
	}
	blobs := fmt.aprintf("%s/%s", worker.dir, ATTACHMENT_BLOBS_DIR_NAME)
	defer delete(blobs)
	shards, shardsErr := os.read_all_directory_by_path(blobs, context.allocator)
	if shardsErr != nil {
		return result
	}
	defer os.file_info_slice_delete(shards, context.allocator)
	for shard in shards {
		if shard.type != .Directory || len(shard.name) != 2 {
			continue
		}
		infos, err := os.read_all_directory_by_path(shard.fullpath, context.allocator)
		if err != nil {
			continue
		}
		for info in infos {
			if !storageOldEnough(worker, info) {
				continue
			}
			if blobId, ok := storageParseBlobName(info.name);
			   ok && strings.has_prefix(info.name, shard.name) {
				append(&result.files, StorageFile{blobId = blobId})
				continue
			}
			storageRemoveStray(info)
		}
		os.file_info_slice_delete(infos, context.allocator)
	}
	return result
}

@(private = "file")
storageRemoveStray :: proc(info: os.File_Info) {
	if info.type != .Regular {
		return
	}
	if os.remove(info.fullpath) == nil {
		fmt.printfln("[Storage] Deleted stray attachment file %s", info.fullpath)
	}
}

// Storage service entry point (ProcessType.Storage).
storageServerLoop :: proc(pm: ^ProcessManager) {
	fmt.printfln("[Storage] Storage worker started on %s", pm.config.attachmentDir)
	storageFd, ipcErr := IPC_Client_init(&pm.config.storageSocket)
	if ipcErr != nil {
		fmt.eprintfln("[Storage] Failed to initialize coordinator endpoint: %v", ipcErr)
		return
	}
	sync.atomic_store(&pm.config.storageFd, storageFd)
	defer IPC_Client_deinit(&pm.config.storageSocket)

	worker := StorageWorker_init(pm.config.attachmentDir)
	defer StorageWorker_deinit(&worker)

	running := true
	for running {
		message, err := IPC_Client_poll(storageFd)
		if err != nil {
			IPC_Client_wait(storageFd, STORAGE_IDLE_WAIT)
			continue
		}
		#partial switch msg in message {
		case StorageCommand:
			result, answered := StorageWorker_handle(&worker, msg.request)
			StorageRequest_deinit(msg.request)
			if answered && msg.requestId != 0 {
				response := StorageResponse {
					requestId = msg.requestId,
					result    = result,
				}
				if IPC_Client_send(storageFd, response) != nil {
					StorageResult_deinit(result)
				}
			} else {
				StorageResult_deinit(result)
			}
		case ProcessShutdown:
			fmt.println("[Storage] Received shutdown signal")
			running = false
		case ProcessRestart:
			fmt.println("[Storage] Received restart signal")
			running = false
		case Wake:
		case:
			fmt.eprintln("[Storage] Received unsupported message type")
			stray := message
			IPC__message_deinit(&stray)
		}
	}
	fmt.println("[Storage] Storage worker shutting down")
}
