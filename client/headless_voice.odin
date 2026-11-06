package client

// Voice in the headless harness (voice-rooms-design.md 5.4, docs/testing-harness.md "Voice"):
// the voice-* commands, and the voice_status and voice_speaking events, which the harness
// derives from State.voice and the engine snapshot rather than from runtime events.
//
// A harness client's engine template starts as a silent source, a null sink and voice
// activity, so it never initialises SDL audio unless a script asks for a device.
// voice-source, voice-sink and the gate mode change the template, which the next join uses: a
// running engine keeps what it opened with (the result says so with "pendingRejoin":true), so
// a script changes them before voice-join, or leaves and joins again. Mute, deafen,
// push-to-talk and the gate mode also reach a running engine at once.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:sync"
import "core:time"

// How long voice-flush waits for the voice thread to serve the flush.
HEADLESS_VOICE_FLUSH_TIMEOUT :: 2 * time.Second

HEADLESS_VOICE_STATUS_NAMES := [VoiceSessionStatus]string {
	.Idle        = "idle",
	.Joining     = "joining",
	.Joined      = "joined",
	.Unavailable = "unavailable",
}

// What the harness last reported about voice, so it can print edges.
HeadlessVoiceTracker :: struct {
	status:        VoiceSessionStatus,
	// When status became Joined, for voice-stats' joinedMS.
	joinedAt:      time.Tick,
	// The server and room the speaking flags below belong to.
	serverID:      int,
	roomID:        int,
	selfSpeaking:  bool,
	speakingCount: int,
	speaking:      [VOICE_MAX_SPEAKERS]u32,
	// voice-gate open: push-to-talk mode with the key held for the script.
	gateOpen:      bool,
}

HeadlessVoiceSpeakingEdge :: struct {
	userID:   int,
	speaking: bool,
	isSelf:   bool,
}

// At most every remote speaker stops and as many start, plus this client itself.
HEADLESS_VOICE_MAX_EDGES :: 2 * VOICE_MAX_SPEAKERS + 1

HeadlessVoiceSpeakingEdges :: struct {
	count: int,
	edges: [HEADLESS_VOICE_MAX_EDGES]HeadlessVoiceSpeakingEdge,
}

@(private = "file")
headlessVoiceAddEdge :: proc(edges: ^HeadlessVoiceSpeakingEdges, edge: HeadlessVoiceSpeakingEdge) {
	if edges.count < len(edges.edges) {
		edges.edges[edges.count] = edge
		edges.count += 1
	}
}

// Compares the speaking flags in snapshot (nil when no engine runs, which means nobody is
// heard and this client sends nothing) with the tracker's, records the new ones and returns
// the changes: stops first, then starts, then this client's own edge. A remote speaker's flag
// is its jitter buffer's talk spurt, which ends on the sender's end-of-spurt flag or after 200
// ms without frames, and this client's is whether its gate sends; both already have their own
// hysteresis, so the edges are stable enough to wait on.
headlessVoiceSpeakingUpdate :: proc(
	tracker: ^HeadlessVoiceTracker,
	snapshot: ^VoiceEngineSnapshot,
	selfUserID: int,
) -> (
	edges: HeadlessVoiceSpeakingEdges,
) {
	current: [VOICE_MAX_SPEAKERS]u32
	currentCount := 0
	selfSpeaking := false
	if snapshot != nil {
		for speaker in snapshot.speakers[:snapshot.speakerCount] {
			if speaker.speaking {
				current[currentCount] = speaker.userID
				currentCount += 1
			}
		}
		selfSpeaking = snapshot.transmitting
	}
	for userID in tracker.speaking[:tracker.speakingCount] {
		found := false
		for other in current[:currentCount] {
			found ||= other == userID
		}
		if !found {
			headlessVoiceAddEdge(&edges, {userID = int(userID), speaking = false})
		}
	}
	for userID in current[:currentCount] {
		found := false
		for other in tracker.speaking[:tracker.speakingCount] {
			found ||= other == userID
		}
		if !found {
			headlessVoiceAddEdge(&edges, {userID = int(userID), speaking = true})
		}
	}
	if selfSpeaking != tracker.selfSpeaking {
		headlessVoiceAddEdge(
			&edges,
			{userID = selfUserID, speaking = selfSpeaking, isSelf = true},
		)
	}
	tracker.speaking = current
	tracker.speakingCount = currentCount
	tracker.selfSpeaking = selfSpeaking
	return edges
}

// One speaking edge. userID is the speaker's account (this client's own when self is true).
HeadlessVoiceSpeakingJSON :: struct {
	event:    string,
	serverID: int,
	roomID:   int,
	userID:   int,
	speaking: bool,
	self:     bool,
}

// A change of State.voice.status. roomID is the room voice is in or being joined, or the one
// a reconnect will re-join (wantRoomID) while idle; error is why voice last stopped or failed.
HeadlessVoiceStatusJSON :: struct {
	event:      string,
	serverID:   int,
	roomID:     int,
	status:     string,
	wantRoomID: int,
	error:      string,
}

headlessRenderVoiceSpeaking :: proc(
	serverID, roomID: int,
	edge: HeadlessVoiceSpeakingEdge,
	allocator := context.allocator,
) -> string {
	return headlessMarshal(
		HeadlessVoiceSpeakingJSON {
			event = HEADLESS_EVENT_NAMES[.VoiceSpeaking],
			serverID = serverID,
			roomID = roomID,
			userID = edge.userID,
			speaking = edge.speaking,
			self = edge.isSelf,
		},
		allocator,
	)
}

headlessRenderVoiceStatus :: proc(
	voice: ^ClientVoiceState,
	allocator := context.allocator,
) -> string {
	return headlessMarshal(
		HeadlessVoiceStatusJSON {
			event = HEADLESS_EVENT_NAMES[.VoiceStatus],
			serverID = voice.serverID,
			roomID = voice.roomID,
			status = HEADLESS_VOICE_STATUS_NAMES[voice.status],
			wantRoomID = voice.wantVoiceRoomID,
			error = voice.lastError,
		},
		allocator,
	)
}

// The account this client is on serverID, or 0 when it is not connected there.
@(private = "file")
headlessVoiceSelfUserID :: proc(state: ^State, serverID: int) -> int {
	if index := State_serverConnectionIndex(state^, serverID); index >= 0 {
		return state.serverConnections[index].userID
	}
	return 0
}

// Prints voice_status when State.voice.status changed and voice_speaking for every edge since
// the last call. Runs after every applied runtime event and on every pass of the loop, so the
// edges keep coming while a command waits or sleeps.
headlessPollVoice :: proc(harness: ^HeadlessHarness) {
	state := &harness.state
	tracker := &harness.voice
	voice := &state.voice
	if voice.status != tracker.status {
		tracker.status = voice.status
		if voice.status == .Joined {
			tracker.joinedAt = time.tick_now()
		}
		line := headlessRenderVoiceStatus(voice)
		headlessWriteLine(harness, line)
		delete(line)
		headlessRecordEvent(harness, .VoiceStatus)
	}

	snapshot: VoiceEngineSnapshot
	snapshotPointer: ^VoiceEngineSnapshot
	if voice.engine != nil {
		snapshot = VoiceEngine_snapshot(voice.engine)
		snapshotPointer = &snapshot
		tracker.serverID = voice.serverID
		tracker.roomID = voice.roomID
	} else if tracker.speakingCount == 0 && !tracker.selfSpeaking {
		return
	}
	edges := headlessVoiceSpeakingUpdate(
		tracker,
		snapshotPointer,
		headlessVoiceSelfUserID(state, tracker.serverID),
	)
	for edge in edges.edges[:edges.count] {
		line := headlessRenderVoiceSpeaking(tracker.serverID, tracker.roomID, edge)
		headlessWriteLine(harness, line)
		delete(line)
		headlessRecordEvent(harness, .VoiceSpeaking)
	}
}

// ── Results ───────────────────────────────────────────────────────

// voice-join and voice-leave: the server and room joined or left (0 when not in voice), and
// the voice status right after the command. A join completes with a voice_participants event
// with recipientJoined true, followed by voice_status "joined".
HeadlessVoiceRoomJSON :: struct {
	ok:       bool,
	cmd:      string,
	serverID: int,
	roomID:   int,
	status:   string,
}

// voice-source, voice-sink, voice-gate, voice-mute, voice-deafen and voice-ptt: the value
// now set. pendingRejoin is true when an engine is running and keeps its old source or sink
// until the next join.
HeadlessVoiceSettingJSON :: struct {
	ok:            bool,
	cmd:           string,
	value:         string,
	pendingRejoin: bool,
}

HeadlessVoiceSpeakerJSON :: struct {
	userID:         u32,
	speaking:       bool,
	levelDB:        f32,
	bufferedFrames: int,
	targetDepth:    int,
	jitterMS:       f32,
}

// voice-stats. The flat fields first, for scripts: sent (frames this engine encoded and handed to
// the network), received (frames accepted into the jitter buffers), lost (missing at playout: fec
// + plc + silent), fec, plc, late, and the largest jitterMS and depth over the current speakers;
// maxGapRun (the longest run of frames inside a spurt heard as neither decoded nor FEC-rebuilt),
// playoutDelayMS and playoutDelayMaxMS (mean and largest wait of a received frame between arrival
// and decoding), and injectedLoss (frames the HAYCHAT_TEST_FAULTS hook dropped; 0 in normal
// builds). Then the engine's full counters (VoiceEngineStats and JitterStats), its speakers, and
// the transport's voice counters (ClientVoiceNetworkStats, read under the worker lock). joinedMS
// is the time since the join completed (0 when not joined).
HeadlessVoiceStatsJSON :: struct {
	ok:                bool,
	cmd:               string,
	status:            string,
	serverID:          int,
	roomID:            int,
	running:           bool,
	joinedMS:          int,
	sent:              u64,
	received:          u64,
	lost:              u64,
	fec:               u64,
	plc:               u64,
	late:              u64,
	jitterMS:          f32,
	depth:             int,
	maxGapRun:         u64,
	playoutDelayMS:    f64,
	playoutDelayMaxMS: f64,
	injectedLoss:      u64,
	inputLevelDB:      f32,
	transmitting:      bool,
	frameSequence:     u32,
	engine:            VoiceEngineStats,
	jitter:            JitterStats,
	speakers:          []HeadlessVoiceSpeakerJSON,
	network:           ClientVoiceNetworkStats,
}

// voice-flush: the file sink's path and its size once the flush was served. running is false
// when no engine runs; the file was then closed, complete, when the engine stopped.
HeadlessVoiceFlushJSON :: struct {
	ok:      bool,
	cmd:     string,
	path:    string,
	bytes:   i64,
	seconds: f64,
	running: bool,
}

// Fills the stats result from a snapshot and the transport counters. Pure, for tests; the
// speakers slice is allocated with allocator.
headlessVoiceStatsJSON :: proc(
	voice: ^ClientVoiceState,
	snapshot: ^VoiceEngineSnapshot,
	network: ClientVoiceNetworkStats,
	joinedMS: int,
	allocator := context.allocator,
) -> HeadlessVoiceStatsJSON {
	result := HeadlessVoiceStatsJSON {
		ok       = true,
		cmd      = "voice-stats",
		status   = HEADLESS_VOICE_STATUS_NAMES[voice.status],
		serverID = voice.serverID,
		roomID   = voice.roomID,
		joinedMS = joinedMS,
		network  = network,
	}
	if snapshot == nil {
		return result
	}
	jitter := snapshot.jitter
	result.running = snapshot.running
	result.sent = snapshot.stats.framesSent
	result.received = jitter.received
	result.lost = jitter.fec + jitter.plc + jitter.silent
	result.fec = jitter.fec
	result.plc = jitter.plc
	result.late = jitter.late
	result.maxGapRun = jitter.maxGapRun
	if snapshot.stats.playoutDelayFrames > 0 {
		result.playoutDelayMS =
			snapshot.stats.playoutDelayTotalMS / f64(snapshot.stats.playoutDelayFrames)
	}
	result.playoutDelayMaxMS = snapshot.stats.playoutDelayMaxMS
	result.injectedLoss = snapshot.stats.faultDropped
	result.inputLevelDB = snapshot.inputLevelDB
	result.transmitting = snapshot.transmitting
	result.frameSequence = snapshot.frameSequence
	result.engine = snapshot.stats
	result.jitter = jitter
	result.speakers = make([]HeadlessVoiceSpeakerJSON, snapshot.speakerCount, allocator)
	for speaker, index in snapshot.speakers[:snapshot.speakerCount] {
		result.speakers[index] = {
			userID         = speaker.userID,
			speaking       = speaker.speaking,
			levelDB        = speaker.levelDB,
			bufferedFrames = speaker.bufferedFrames,
			targetDepth    = speaker.targetDepth,
			jitterMS       = speaker.jitterMS,
		}
		result.jitterMS = max(result.jitterMS, speaker.jitterMS)
		result.depth = max(result.depth, speaker.targetDepth)
	}
	return result
}

// ── Commands ──────────────────────────────────────────────────────

@(private = "file")
headlessVoiceUsage :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	headlessWriteError(harness, command.name, fmt.tprintf("usage: %s", command.command.usage))
}

@(private = "file")
headlessVoiceWriteSetting :: proc(
	harness: ^HeadlessHarness,
	command: ^HeadlessParsedCommand,
	value: string,
	pendingRejoin := false,
) {
	headlessWriteJSON(
		harness,
		HeadlessVoiceSettingJSON {
			ok = true,
			cmd = command.name,
			value = value,
			pendingRejoin = pendingRejoin,
		},
	)
}

// Parses on or off.
@(private = "file")
headlessParseSwitch :: proc(value: string) -> (on: bool, ok: bool) {
	switch value {
	case "on":
		return true, true
	case "off":
		return false, true
	}
	return false, false
}

headlessCommandVoiceJoin :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	roomID, roomOK := headlessParseNumber(command.args[0])
	if !roomOK || roomID == 0 {
		headlessVoiceUsage(harness, command)
		return
	}
	state := &harness.state
	serverID := state.selected_server_id
	if !State_joinVoice(state, serverID, roomID) {
		message := state.voice.lastError
		if len(message) == 0 {
			message = "failed to join voice"
		}
		headlessWriteError(harness, command.name, message)
		return
	}
	headlessWriteJSON(
		harness,
		HeadlessVoiceRoomJSON {
			ok = true,
			cmd = command.name,
			serverID = serverID,
			roomID = roomID,
			status = HEADLESS_VOICE_STATUS_NAMES[state.voice.status],
		},
	)
}

headlessCommandVoiceLeave :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	state := &harness.state
	serverID := state.voice.serverID
	roomID := state.voice.roomID
	State_leaveVoice(state)
	headlessWriteJSON(
		harness,
		HeadlessVoiceRoomJSON {
			ok = true,
			cmd = command.name,
			serverID = serverID,
			roomID = roomID,
			status = HEADLESS_VOICE_STATUS_NAMES[state.voice.status],
		},
	)
}

headlessCommandVoiceSource :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	source, ok := voiceParseSourceSpec(command.args[0])
	if !ok {
		headlessVoiceUsage(harness, command)
		return
	}
	state := &harness.state
	template := state.voice.engineTemplate
	template.source = source
	State_setVoiceEngineTemplate(state, template)
	headlessVoiceWriteSetting(harness, command, command.args[0], state.voice.engine != nil)
}

headlessCommandVoiceSink :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	sink, ok := voiceParseSinkSpec(command.args[0])
	if !ok {
		headlessVoiceUsage(harness, command)
		return
	}
	state := &harness.state
	template := state.voice.engineTemplate
	template.sink = sink
	State_setVoiceEngineTemplate(state, template)
	headlessVoiceWriteSetting(harness, command, command.args[0], state.voice.engine != nil)
}

// voice-gate vad [THRESHOLD_DB] | ptt | open. open is push-to-talk with the key held for the
// script, so every captured frame is sent (until `voice-ptt up`).
headlessCommandVoiceGate :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	mode: VoiceGateMode
	open := false
	switch command.args[0] {
	case "vad":
		mode = .VoiceActivity
	case "ptt":
		mode = .PushToTalk
	case "open":
		mode = .PushToTalk
		open = true
	case:
		headlessVoiceUsage(harness, command)
		return
	}
	threshold: f32
	if command.argCount > 1 {
		parsed, parsedOK := strconv.parse_f32(command.args[1])
		if mode != .VoiceActivity || !parsedOK || parsed < -100 || parsed >= 0 {
			headlessVoiceUsage(harness, command)
			return
		}
		threshold = parsed
	}
	state := &harness.state
	template := state.voice.engineTemplate
	template.gateMode = mode
	if threshold != 0 {
		template.vadThresholdDB = threshold
	}
	State_setVoiceEngineTemplate(state, template)
	if engine := state.voice.engine; engine != nil {
		VoiceEngine_setGateMode(engine, mode)
		if threshold != 0 {
			VoiceEngine_setVADThreshold(engine, threshold)
		}
	}
	// Leaving open releases the key it held; entering it presses the key.
	if open || harness.voice.gateOpen {
		State_setVoicePushToTalk(state, open)
	}
	harness.voice.gateOpen = open
	headlessVoiceWriteSetting(harness, command, command.args[0])
}

headlessCommandVoiceMute :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	muted, ok := headlessParseSwitch(command.args[0])
	if !ok {
		headlessVoiceUsage(harness, command)
		return
	}
	State_setVoiceMuted(&harness.state, muted)
	headlessVoiceWriteSetting(harness, command, command.args[0])
}

headlessCommandVoiceDeafen :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	deafened, ok := headlessParseSwitch(command.args[0])
	if !ok {
		headlessVoiceUsage(harness, command)
		return
	}
	State_setVoiceDeafened(&harness.state, deafened)
	headlessVoiceWriteSetting(harness, command, command.args[0])
}

headlessCommandVoicePushToTalk :: proc(
	harness: ^HeadlessHarness,
	command: ^HeadlessParsedCommand,
) {
	held: bool
	switch command.args[0] {
	case "down":
		held = true
	case "up":
		held = false
	case:
		headlessVoiceUsage(harness, command)
		return
	}
	State_setVoicePushToTalk(&harness.state, held)
	headlessVoiceWriteSetting(harness, command, command.args[0])
}

headlessCommandVoiceStats :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	state := &harness.state
	serverID := state.voice.serverID
	if serverID == 0 {
		serverID = state.selected_server_id
	}
	network: ClientVoiceNetworkStats
	if index := State_selectedTransportIndexForServerID(state^, serverID); index >= 0 {
		// The worker and the voice thread update these under the lock.
		ClientNetworkWorker_lock(state.networkWorker)
		network = state.serverTransports[index].voiceStats
		ClientNetworkWorker_unlock(state.networkWorker)
	}
	snapshot: VoiceEngineSnapshot
	snapshotPointer: ^VoiceEngineSnapshot
	if state.voice.engine != nil {
		snapshot = VoiceEngine_snapshot(state.voice.engine)
		snapshotPointer = &snapshot
	}
	joinedMS := 0
	if state.voice.status == .Joined && harness.voice.joinedAt != {} {
		joinedMS = int(time.duration_milliseconds(time.tick_since(harness.voice.joinedAt)))
	}
	result := headlessVoiceStatsJSON(&state.voice, snapshotPointer, network, joinedMS)
	defer delete(result.speakers)
	result.cmd = command.name
	headlessWriteJSON(harness, result)
}

headlessCommandVoiceFlush :: proc(harness: ^HeadlessHarness, command: ^HeadlessParsedCommand) {
	state := &harness.state
	engine := state.voice.engine
	sink := engine != nil ? engine.config.sink : state.voice.engineTemplate.sink
	if sink.kind != .File {
		headlessWriteError(
			harness,
			command.name,
			"voice-flush needs a file sink (voice-sink file:PATH)",
		)
		return
	}
	if engine != nil {
		ticket := VoiceEngine_requestSinkFlush(engine)
		start := time.tick_now()
		for VoiceEngine_sinkFlushCompleted(engine) < ticket {
			if time.tick_since(start) >= HEADLESS_VOICE_FLUSH_TIMEOUT ||
			   !sync.atomic_load(&engine.opened) {
				headlessWriteError(harness, command.name, "the voice engine did not flush its sink")
				return
			}
			time.sleep(HEADLESS_POLL_INTERVAL)
		}
	}
	info, statErr := os.stat(sink.path, context.temp_allocator)
	if statErr != nil {
		headlessWriteError(
			harness,
			command.name,
			fmt.tprintf("cannot read the voice sink %s: %v", sink.path, statErr),
		)
		return
	}
	headlessWriteJSON(
		harness,
		HeadlessVoiceFlushJSON {
			ok = true,
			cmd = command.name,
			path = sink.path,
			bytes = info.size,
			seconds = f64(info.size) / f64(VOICE_FRAME_BYTES) * VOICE_FRAME_MS / 1000,
			running = engine != nil,
		},
	)
}
