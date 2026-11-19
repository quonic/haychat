package client

// Headless attachment commands (protocol 26, attachments F1; docs/testing-harness.md
// "Attachments"): attach-upload, attach-resume, attach-download and attach-cancel drive the
// transfer worker (attachment_transfer.odin), whose results arrive as attachment_progress,
// attachment_done and attachment_error events. chat-latency measures how long the server takes
// to echo this client's own room messages, for the transfer latency proof.
//
// Protocol 27 (F2): attach-upload goes through State_uploadAttachment (attachments.odin), which
// checks the server's limits and seals the file for an encrypted conversation; send, dm and
// dm-plain take --attach BLOB for finished uploads; attach-download ROOM_ID|@USER_ID MESSAGE_ID
// INDEX OUT saves a message's file, checked against the message and decrypted.
//
// Protocol 28 (F3): attach-usage and attach-remove BLOB [REASON...] (admins), answered by
// attachment_usage and admin_result attachment-remove; every reader of a removed file's
// message hears attachment_removed (after State marked its files removed).
//
// Protocol 29 (#138): attachment_removed also names the message (chatMessageID or
// directMessageID); attach-removals [BEFORE_ID] (admins) asks for a page of the removal log,
// answered by attachment_removals.

import "../common"
import "core:fmt"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"

HeadlessAttachmentRequestJSON :: struct {
	ok:              bool,
	cmd:             string,
	id:              int,
	serverID:        int,
	roomID:          int,
	recipientUserID: int,
	blobID:          string,
	path:            string,
	encrypted:       bool, // attach-upload: the file is sealed (protocol 27)
	messageID:       int, // attach-download by message
	index:           int,
}

HeadlessAttachmentProgressJSON :: struct {
	event:     string,
	serverID:  int,
	id:        int,
	direction: string,
	blobID:    string,
	bytes:     u64,
	total:     u64,
}

// size and sha256 are the stored bytes'; protocol 27 adds whether they are the encrypted format
// and the file's own size (the plaintext written for a decrypted download).
HeadlessAttachmentDoneJSON :: struct {
	event:     string,
	serverID:  int,
	id:        int,
	direction: string,
	blobID:    string,
	size:      u64,
	sha256:    string,
	path:      string,
	elapsedMS: i64,
	encrypted: bool,
	fileSize:  u64,
}

HeadlessAttachmentErrorJSON :: struct {
	event:     string,
	serverID:  int,
	id:        int,
	direction: string,
	blobID:    string,
	bytes:     u64,
	total:     u64,
	path:      string,
	error:     string,
}

HeadlessChatLatencyJSON :: struct {
	ok:       bool,
	cmd:      string,
	roomID:   int,
	count:    int,
	received: int,
	p50MS:    f64,
	p95MS:    f64,
	maxMS:    f64,
	meanMS:   f64,
}

// The probe chat-latency runs: when each of its messages went out, by content.
HeadlessLatencyProbe :: struct {
	active:  bool,
	sentAt:  map[string]time.Tick,
	samples: [dynamic]f64,
}

HeadlessLatencyProbe_deinit :: proc(probe: ^HeadlessLatencyProbe) {
	for key in probe.sentAt {
		delete(key)
	}
	delete(probe.sentAt)
	delete(probe.samples)
	probe^ = {}
}

@(private = "file")
headlessTransferDirection :: proc(direction: ClientTransferDirection) -> string {
	return direction == .Upload ? "upload" : "download"
}

@(private = "file")
headlessBlobHex :: proc(event: ClientTransferEvent) -> string {
	if !event.hasBlobId {
		return ""
	}
	blobId := event.blobId
	return headlessHex(blobId[:], context.temp_allocator)
}

// Prints the transfer worker's queued events and counts them for `wait`.
headlessDrainTransferEvents :: proc(harness: ^HeadlessHarness) {
	for {
		event, ok := State_popTransferEvent(&harness.state)
		if !ok {
			return
		}
		direction := headlessTransferDirection(event.direction)
		switch event.kind {
		case .Progress:
			headlessWriteJSON(
				harness,
				HeadlessAttachmentProgressJSON {
					event = HEADLESS_EVENT_NAMES[.AttachmentProgress],
					serverID = event.serverID,
					id = event.id,
					direction = direction,
					blobID = headlessBlobHex(event),
					bytes = event.bytes,
					total = event.total,
				},
			)
			headlessRecordEvent(harness, .AttachmentProgress)
		case .Done:
			sha := event.sha256
			headlessWriteJSON(
				harness,
				HeadlessAttachmentDoneJSON {
					event = HEADLESS_EVENT_NAMES[.AttachmentDone],
					serverID = event.serverID,
					id = event.id,
					direction = direction,
					blobID = headlessBlobHex(event),
					size = event.total,
					sha256 = headlessHex(sha[:], context.temp_allocator),
					path = event.path,
					elapsedMS = event.elapsedMS,
					encrypted = event.encrypted,
					fileSize = event.fileSize,
				},
			)
			headlessRecordEvent(harness, .AttachmentDone)
		case .Error:
			headlessWriteJSON(
				harness,
				HeadlessAttachmentErrorJSON {
					event = HEADLESS_EVENT_NAMES[.AttachmentError],
					serverID = event.serverID,
					id = event.id,
					direction = direction,
					blobID = headlessBlobHex(event),
					bytes = event.bytes,
					total = event.total,
					path = event.path,
					error = event.message,
				},
			)
			headlessRecordEvent(harness, .AttachmentError)
		}
		ClientTransferEvent_deinit(&event)
	}
}

@(private = "file")
headlessTransferWorker :: proc(
	harness: ^HeadlessHarness,
	command: ^HeadlessParsedCommand,
) -> ^ClientTransferWorker {
	worker := State_transferWorker(&harness.state)
	if worker == nil || harness.state.selected_server_id == 0 {
		headlessWriteError(harness, command.name, NOT_CONNECTED_MESSAGE)
		return nil
	}
	return worker
}

@(private = "file")
headlessParseBlob :: proc(
	harness: ^HeadlessHarness,
	command: ^HeadlessParsedCommand,
	text: string,
) -> (
	common.AttachmentBlobID,
	bool,
) {
	blobId, ok := attachmentBlobIDFromHex(text)
	if !ok {
		headlessWriteError(harness, command.name, "BLOB must be 32 hex characters")
	}
	return blobId, ok
}

// attach-upload ROOM|@USER [--unchecked] FILE...
headlessCommandAttachUpload :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	target := command.args[0]
	roomID, recipientID := 0, 0
	ok := false
	if strings.has_prefix(target, "@") {
		recipientID, ok = headlessParseNumber(target[1:])
	} else {
		roomID, ok = headlessParseNumber(target)
	}
	path := strings.trim_space(command.args[1])
	// --unchecked skips the client's size and quota checks (D18), so a proof can show the
	// server refusing the upload itself.
	checkLimits := true
	if strings.has_prefix(path, "--unchecked ") {
		checkLimits = false
		path = strings.trim_space(path[len("--unchecked "):])
	}
	if !ok || (roomID == 0 && recipientID == 0) || len(path) == 0 {
		headlessWriteError(
			harness,
			command.name,
			"usage: attach-upload ROOM_ID|@USER_ID [--unchecked] FILE",
		)
		return
	}
	if headlessTransferWorker(harness, command) == nil {
		return
	}
	serverID := harness.state.selected_server_id
	id, uploadError := State_uploadAttachment(
		&harness.state,
		serverID,
		roomID,
		recipientID,
		path,
		checkLimits,
	)
	if len(uploadError) > 0 {
		headlessWriteError(harness, command.name, uploadError)
		return
	}
	pending := harness.state.attachmentPendingUploads
	encrypted := pending[len(pending) - 1].encrypted
	headlessWriteJSON(
		harness,
		HeadlessAttachmentRequestJSON {
			ok = true,
			cmd = command.name,
			id = id,
			serverID = serverID,
			roomID = roomID,
			recipientUserID = recipientID,
			path = path,
			encrypted = encrypted,
		},
	)
}

// attach-resume BLOB
headlessCommandAttachResume :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	blobId, ok := headlessParseBlob(harness, command, command.args[0])
	if !ok {
		return
	}
	worker := headlessTransferWorker(harness, command)
	if worker == nil {
		return
	}
	serverID := harness.state.selected_server_id
	id := ClientTransferWorker_resume(worker, serverID, blobId)
	headlessWriteJSON(
		harness,
		HeadlessAttachmentRequestJSON {
			ok = true,
			cmd = command.name,
			id = id,
			serverID = serverID,
			blobID = command.args[0],
		},
	)
}

// attach-download BLOB OUT... (the raw blob, F1: only the owner's unbound one), or
// attach-download ROOM_ID|@USER_ID MESSAGE_ID INDEX OUT... (protocol 27: file INDEX of a cached
// message, checked and decrypted).
headlessCommandAttachDownload :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	if len(command.args[0]) != 2 * common.ATTACHMENT_BLOB_ID_SIZE {
		headlessAttachDownloadMessage(harness, command)
		return
	}
	blobId, ok := headlessParseBlob(harness, command, command.args[0])
	if !ok {
		return
	}
	path := strings.trim_space(command.args[1])
	if len(path) == 0 {
		headlessWriteError(harness, command.name, "usage: attach-download BLOB OUT")
		return
	}
	worker := headlessTransferWorker(harness, command)
	if worker == nil {
		return
	}
	serverID := harness.state.selected_server_id
	id := ClientTransferWorker_download(worker, serverID, blobId, path)
	headlessWriteJSON(
		harness,
		HeadlessAttachmentRequestJSON {
			ok = true,
			cmd = command.name,
			id = id,
			serverID = serverID,
			blobID = command.args[0],
			path = path,
		},
	)
}

// attach-cancel BLOB
headlessCommandAttachCancel :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	blobId, ok := headlessParseBlob(harness, command, command.args[0])
	if !ok {
		return
	}
	worker := headlessTransferWorker(harness, command)
	if worker == nil {
		return
	}
	serverID := harness.state.selected_server_id
	id := ClientTransferWorker_cancel(worker, serverID, blobId)
	headlessWriteJSON(
		harness,
		HeadlessAttachmentRequestJSON {
			ok = true,
			cmd = command.name,
			id = id,
			serverID = serverID,
			blobID = command.args[0],
		},
	)
}

// Notes the echo of one of chat-latency's messages (called for every room_chat).
headlessLatencyProbeSaw :: proc(harness: ^HeadlessHarness, content: string) {
	probe := &harness.latency
	if !probe.active {
		return
	}
	if sentAt, ok := probe.sentAt[content]; ok {
		append(&probe.samples, time.duration_milliseconds(time.tick_since(sentAt)))
		key, _ := delete_key(&probe.sentAt, content)
		delete(key)
	}
}

@(private = "file")
headlessPercentile :: proc(sorted: []f64, fraction: f64) -> f64 {
	if len(sorted) == 0 {
		return 0
	}
	index := int(fraction * f64(len(sorted) - 1) + 0.5)
	return sorted[clamp(index, 0, len(sorted) - 1)]
}

// chat-latency ROOM COUNT [INTERVAL_MS]: sends COUNT room messages INTERVAL_MS apart (default
// 50) and reports how long each took to come back as this client's own room_chat: p50, p95,
// max and mean in milliseconds. Waits up to 10 s for the last echoes.
headlessCommandChatLatency :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	roomID, roomOK := headlessParseNumber(command.args[0])
	count, countOK := headlessParseNumber(command.args[1], 10_000)
	interval := 50
	intervalOK := true
	if command.argCount > 2 {
		interval, intervalOK = headlessParseNumber(command.args[2], 60_000)
	}
	if !roomOK || roomID == 0 || !countOK || count == 0 || !intervalOK {
		headlessWriteError(harness, command.name, "usage: chat-latency ROOM_ID COUNT [INTERVAL_MS]")
		return
	}
	state := &harness.state
	probe := &harness.latency
	HeadlessLatencyProbe_deinit(probe)
	probe.active = true
	probe.sentAt = make(map[string]time.Tick)
	probe.samples = make([dynamic]f64)
	nonce := time.tick_now()._nsec
	for index in 0 ..< count {
		content := fmt.aprintf("latency-probe %d %d", nonce, index)
		State_closeDirectConversation(state)
		state.selected_channel_id = roomID
		draft := State_selectedRoomDraft(state)
		clear(draft)
		append(draft, ..transmute([]u8)content)
		probe.sentAt[content] = time.tick_now()
		State_sendChannelChat(state, checkPermission = false)
		clear(State_selectedRoomDraft(state))
		headlessPumpFor(harness, time.Duration(interval) * time.Millisecond)
	}
	deadline := time.tick_now()
	for len(probe.sentAt) > 0 && time.tick_since(deadline) < 10 * time.Second {
		headlessPumpFor(harness, 10 * time.Millisecond)
	}
	sorted := slice.clone(probe.samples[:])
	defer delete(sorted)
	slice.sort(sorted)
	mean := 0.0
	for sample in sorted {
		mean += sample
	}
	if len(sorted) > 0 {
		mean /= f64(len(sorted))
	}
	headlessWriteJSON(
		harness,
		HeadlessChatLatencyJSON {
			ok = true,
			cmd = command.name,
			roomID = roomID,
			count = count,
			received = len(sorted),
			p50MS = headlessPercentile(sorted, 0.50),
			p95MS = headlessPercentile(sorted, 0.95),
			maxMS = len(sorted) > 0 ? sorted[len(sorted) - 1] : 0,
			meanMS = mean,
		},
	)
	HeadlessLatencyProbe_deinit(probe)
}

// Takes the leading "--attach BLOB" options (protocol 27) off text: the blob IDs (temp) and the
// rest of the line. Writes the error and returns false for a malformed option.
headlessTakeAttachOptions :: proc(
	harness: ^HeadlessHarness,
	command: ^HeadlessParsedCommand,
	text: string,
) -> (
	blobIds: []common.AttachmentBlobID,
	rest: string,
	ok: bool,
) {
	list := make([dynamic]common.AttachmentBlobID, context.temp_allocator)
	rest = strings.trim_left_space(text)
	for strings.has_prefix(rest, "--attach") {
		after := strings.trim_left_space(rest[len("--attach"):])
		end := strings.index_byte(after, ' ')
		token := end < 0 ? after : after[:end]
		blobId, parsed := headlessParseBlob(harness, command, token)
		if !parsed {
			return nil, "", false
		}
		append(&list, blobId)
		rest = end < 0 ? "" : strings.trim_left_space(after[end:])
	}
	return list[:], rest, true
}

// Whether a send of attachments without text failed: there is no draft left to tell, so the
// status line says it (anything but the queued message's "Setting up encryption…").
headlessAttachmentsOnlyFailed :: proc(
	state: ^State,
	text: string,
	blobIds: []common.AttachmentBlobID,
) -> bool {
	return(
		len(strings.trim_space(text)) == 0 &&
		len(blobIds) > 0 &&
		len(state.chat_status_message) > 0 &&
		state.chat_status_message != DIRECT_SETTING_UP_TEXT \
	)
}

@(private = "file")
headlessAttachDownloadMessage :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	usage := "usage: attach-download ROOM_ID|@USER_ID MESSAGE_ID INDEX OUT"
	target := command.args[0]
	roomID, peerUserID := 0, 0
	ok := false
	if strings.has_prefix(target, "@") {
		peerUserID, ok = headlessParseNumber(target[1:])
	} else {
		roomID, ok = headlessParseNumber(target)
	}
	rest := strings.trim_space(command.args[1])
	fields: [2]string
	for index in 0 ..< 2 {
		end := strings.index_byte(rest, ' ')
		if end < 0 {
			ok = false
			break
		}
		fields[index] = rest[:end]
		rest = strings.trim_left_space(rest[end:])
	}
	messageID, messageOK := headlessParseNumber(fields[0])
	index, indexOK := headlessParseNumber(fields[1], common.ATTACHMENTS_PER_MESSAGE_MAX - 1)
	path := strings.trim_space(rest)
	if !ok || !messageOK || messageID == 0 || !indexOK || len(path) == 0 {
		headlessWriteError(harness, command.name, usage)
		return
	}
	if headlessTransferWorker(harness, command) == nil {
		return
	}
	serverID := harness.state.selected_server_id
	id, downloadError := State_downloadMessageAttachment(
		&harness.state,
		serverID,
		roomID,
		peerUserID,
		messageID,
		index,
		path,
	)
	if len(downloadError) > 0 {
		headlessWriteError(harness, command.name, downloadError)
		return
	}
	headlessWriteJSON(
		harness,
		HeadlessAttachmentRequestJSON {
			ok = true,
			cmd = command.name,
			id = id,
			serverID = serverID,
			roomID = roomID,
			recipientUserID = peerUserID,
			path = path,
			messageID = messageID,
			index = index,
		},
	)
}

// ── Moderation (protocol 28) ─────────────────────────────────────

// attachment_removed: an admin removed blobID. roomID names a room message's room (or the room
// an unbound blob was uploaded to); senderID and recipientID a direct message's two sides
// (senderID is the owner otherwise). Protocol 29: chatMessageID or directMessageID is the
// message the file was on (0 for none). Printed before State marks the files.
HeadlessAttachmentRemovedJSON :: struct {
	event:           string,
	serverID:        int,
	blobID:          string,
	roomID:          int,
	senderID:        int,
	recipientID:     int,
	chatMessageID:   int,
	directMessageID: int,
}

// One removal log entry (protocol 29): removedByID 0 for a removal made in SQL; name "" for an
// encrypted file (encrypted true) or one never sent.
HeadlessAttachmentRemovalJSON :: struct {
	id:              int,
	blobID:          string,
	ownerID:         int,
	removedByID:     int,
	removedAt:       string,
	reason:          string,
	roomID:          int,
	direct:          bool,
	encrypted:       bool,
	chatMessageID:   int,
	directMessageID: int,
	name:            string,
}

// attachment_removals: a page of the removal log, newest first; beforeID the cursor it answers
// (0 for the newest page) and hasMore whether older entries follow.
HeadlessAttachmentRemovalsJSON :: struct {
	event:    string,
	serverID: int,
	beforeID: int,
	hasMore:  bool,
	entries:  []HeadlessAttachmentRemovalJSON,
}

HeadlessAttachmentUsageAccountJSON :: struct {
	userID: int,
	bytes:  u64,
	count:  int,
}

// attachment_usage: the stored bytes (tombstones excluded), the configured capacity (0 = none),
// the free space on the server's blob volume (freeBytesKnown false when it could not be read)
// and the top accounts by bytes.
HeadlessAttachmentUsageJSON :: struct {
	event:          string,
	serverID:       int,
	usedBytes:      u64,
	capacityBytes:  u64,
	freeBytes:      u64,
	freeBytesKnown: bool,
	accounts:       []HeadlessAttachmentUsageAccountJSON,
}

headlessAdminResultBlob :: proc(blobID: common.AttachmentBlobID) -> string {
	if !common.attachmentBlobIDIsSet(blobID) {
		return ""
	}
	id := blobID
	return headlessHex(id[:], context.temp_allocator)
}

headlessRenderAttachmentModerationEvent :: proc(
	event: ^ClientTransportRuntimeEvent,
	allocator := context.allocator,
) -> (
	line: string,
	kind: HeadlessEventKind,
	ok: bool,
) {
	#partial switch event.kind {
	case .AttachmentRemoved:
		kind = .AttachmentRemoved
		notice := event.attachmentRemoved
		line = headlessMarshal(
			HeadlessAttachmentRemovedJSON {
				event = HEADLESS_EVENT_NAMES[kind],
				serverID = event.serverID,
				blobID = headlessHex(notice.blobId[:], context.temp_allocator),
				roomID = notice.roomId,
				senderID = notice.senderId,
				recipientID = notice.recipientId,
				chatMessageID = notice.chatMessageId,
				directMessageID = notice.directMessageId,
			},
			allocator,
		)
		return line, kind, true
	case .AttachmentRemovalsReceived:
		kind = .AttachmentRemovals
		page := &event.attachmentRemovals
		entries := make(
			[]HeadlessAttachmentRemovalJSON,
			len(page.entries),
			context.temp_allocator,
		)
		for entry, index in page.entries {
			blobID := entry.blobId
			entries[index] = {
				id              = entry.id,
				blobID          = headlessHex(blobID[:], context.temp_allocator),
				ownerID         = entry.ownerUserId,
				removedByID     = entry.removedByUserId,
				removedAt       = entry.removedAt,
				reason          = entry.reason,
				roomID          = entry.roomId,
				direct          = entry.direct,
				encrypted       = entry.encrypted,
				chatMessageID   = entry.chatMessageId,
				directMessageID = entry.directMessageId,
				name            = entry.name,
			}
		}
		line = headlessMarshal(
			HeadlessAttachmentRemovalsJSON {
				event = HEADLESS_EVENT_NAMES[kind],
				serverID = event.serverID,
				beforeID = page.beforeId,
				hasMore = page.hasMore,
				entries = entries,
			},
			allocator,
		)
		return line, kind, true
	case .AttachmentUsageReceived:
		kind = .AttachmentUsage
		usage := &event.attachmentUsage
		accounts := make(
			[]HeadlessAttachmentUsageAccountJSON,
			len(usage.accounts),
			context.temp_allocator,
		)
		for account, index in usage.accounts {
			accounts[index] = {
				userID = account.userId,
				bytes  = account.bytes,
				count  = account.count,
			}
		}
		line = headlessMarshal(
			HeadlessAttachmentUsageJSON {
				event = HEADLESS_EVENT_NAMES[kind],
				serverID = event.serverID,
				usedBytes = usage.usedBytes,
				capacityBytes = usage.capacityBytes,
				freeBytes = usage.freeBytes,
				freeBytesKnown = usage.freeBytesKnown,
				accounts = accounts,
			},
			allocator,
		)
		return line, kind, true
	}
	return "", {}, false
}

// attach-usage
headlessCommandAttachUsage :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	state := &harness.state
	serverID := state.selected_server_id
	if errorMessage := State_requestAttachmentUsage(state, serverID); len(errorMessage) > 0 {
		headlessWriteError(harness, command.name, errorMessage)
		return
	}
	headlessWriteJSON(
		harness,
		HeadlessAttachmentRequestJSON{ok = true, cmd = command.name, serverID = serverID},
	)
}

// attach-remove BLOB [REASON...]
headlessCommandAttachRemove :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	blobId, ok := headlessParseBlob(harness, command, command.args[0])
	if !ok {
		return
	}
	reason := command.argCount > 1 ? command.args[1] : ""
	state := &harness.state
	serverID := state.selected_server_id
	if errorMessage := State_removeAttachment(state, serverID, blobId, reason);
	   len(errorMessage) > 0 {
		headlessWriteError(harness, command.name, errorMessage)
		return
	}
	headlessWriteJSON(
		harness,
		HeadlessAttachmentRequestJSON {
			ok = true,
			cmd = command.name,
			serverID = serverID,
			blobID = command.args[0],
		},
	)
}

// attach-removals [BEFORE_ID]
headlessCommandAttachRemovals :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	beforeID := 0
	if command.argCount > 0 {
		value, ok := strconv.parse_int(command.args[0])
		if !ok || value < 0 {
			headlessWriteError(harness, command.name, "BEFORE_ID must be a removal ID (0 or more)")
			return
		}
		beforeID = value
	}
	state := &harness.state
	serverID := state.selected_server_id
	if errorMessage := State_requestAttachmentRemovals(state, serverID, beforeID);
	   len(errorMessage) > 0 {
		headlessWriteError(harness, command.name, errorMessage)
		return
	}
	headlessWriteJSON(
		harness,
		HeadlessAttachmentRequestJSON{ok = true, cmd = command.name, serverID = serverID},
	)
}
