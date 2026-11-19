package client

// Headless attachment commands (protocol 26, attachments F1; docs/testing-harness.md
// "Attachments"): attach-upload, attach-resume, attach-download and attach-cancel drive the
// transfer worker (attachment_transfer.odin), whose results arrive as attachment_progress,
// attachment_done and attachment_error events. chat-latency measures how long the server takes
// to echo this client's own room messages, for the transfer latency proof.

import "../common"
import "core:fmt"
import "core:slice"
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
	worker := harness.state.transferWorker
	for {
		event, ok := ClientTransferWorker_popEvent(worker)
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

// attach-upload ROOM|@USER FILE...
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
	if !ok || (roomID == 0 && recipientID == 0) || len(path) == 0 {
		headlessWriteError(harness, command.name, "usage: attach-upload ROOM_ID|@USER_ID FILE")
		return
	}
	worker := headlessTransferWorker(harness, command)
	if worker == nil {
		return
	}
	serverID := harness.state.selected_server_id
	id := ClientTransferWorker_upload(worker, serverID, roomID, recipientID, path)
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

// attach-download BLOB OUT...
headlessCommandAttachDownload :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
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
