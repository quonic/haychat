package server

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:time"

// The main thread logs one [Status] line this often, and once more when it shuts down. It is
// the operator's view of the service states and the voice relay counters.
SERVER_STATUS_LOG_INTERVAL :: 5 * time.Minute

// What the [Status] line reports. Rooms and participants come from the router, which owns the
// voice control plane; voiceRelay holds the counters the network thread's relay last published
// (voiceRelayPublishedStats), which start over when the network service restarts.
ServerStatusSnapshot :: struct {
	uptime:                 i64, // seconds since the server started
	connectedPeers:         int,
	networkRunning:         bool,
	databaseRunning:        bool,
	networkRestartPending:  bool,
	databaseRestartPending: bool,
	shutdownRequested:      bool,
	voiceRooms:             int,
	voiceParticipants:      int,
	voiceRelay:             VoiceRelayStats,
	// Protocol 26: the storage worker and the router's attachment counters.
	storageRunning:         bool,
	storageRestartPending:  bool,
	attachmentUploads:      int,
	attachmentDownloads:    int,
	attachments:            AttachmentRouterStats,
}

// Takes a snapshot on the main thread, which owns routerState.
MainRouterState_statusSnapshot :: proc(
	pm: ^ProcessManager,
	state: ^MainRouterState,
) -> ServerStatusSnapshot {
	voiceRooms, voiceParticipants := MainRouterState_voiceCounts(state)
	snapshot := ServerStatusSnapshot {
		uptime            = i64(time.duration_seconds(time.since(pm.startTime))),
		connectedPeers    = len(state.connectedPeers),
		voiceRooms        = voiceRooms,
		voiceParticipants = voiceParticipants,
		voiceRelay        = VoiceRelayStats_load(&voiceRelayPublishedStats),
		attachments       = state.attachments.stats,
	}
	snapshot.attachmentUploads, snapshot.attachmentDownloads = MainRouterState_attachmentCounts(
		state,
	)
	sync.mutex_lock(&pm.processMutex)
	snapshot.networkRunning = pm.networkProcess.isRunning
	snapshot.databaseRunning = pm.databaseProcess.isRunning
	snapshot.networkRestartPending = pm.networkProcess.restartPending
	snapshot.databaseRestartPending = pm.databaseProcess.restartPending
	snapshot.storageRunning = pm.storageProcess.isRunning
	snapshot.storageRestartPending = pm.storageProcess.restartPending
	snapshot.shutdownRequested = pm.shouldShutdown
	sync.mutex_unlock(&pm.processMutex)
	return snapshot
}

// One line of space-separated key=value pairs. The voice pairs follow the process pairs; drops
// are one pair per VoiceRelayDropReason, named voice_drops_<reason in snake case>.
formatServerStatus :: proc(
	snapshot: ServerStatusSnapshot,
	allocator := context.allocator,
) -> string {
	builder := strings.builder_make(allocator)
	fmt.sbprintf(
		&builder,
		"uptime=%d connected_peers=%d network_running=%v database_running=%v " +
		"network_restart_pending=%v database_restart_pending=%v shutdown_requested=%v",
		snapshot.uptime,
		snapshot.connectedPeers,
		snapshot.networkRunning,
		snapshot.databaseRunning,
		snapshot.networkRestartPending,
		snapshot.databaseRestartPending,
		snapshot.shutdownRequested,
	)
	fmt.sbprintf(
		&builder,
		" voice_rooms=%d voice_participants=%d voice_frames_in=%d voice_frames_relayed=%d " +
		"voice_frames_out=%d voice_send_failures=%d",
		snapshot.voiceRooms,
		snapshot.voiceParticipants,
		snapshot.voiceRelay.datagramsIn,
		snapshot.voiceRelay.framesRelayed,
		snapshot.voiceRelay.datagramsOut,
		snapshot.voiceRelay.sendFailures,
	)
	for reason in VoiceRelayDropReason {
		fmt.sbprintf(
			&builder,
			" voice_drops_%s=%d",
			SERVER_STATUS_VOICE_DROP_NAMES[reason],
			snapshot.voiceRelay.drops[reason],
		)
	}
	// Attachments (protocol 26): crypto_ms is the router thread's time in sealFilePacket and
	// openFilePacket, bytes_in and bytes_out the chunk data it opened and sealed.
	fmt.sbprintf(
		&builder,
		" storage_running=%v storage_restart_pending=%v attachment_uploads=%d " +
		"attachment_downloads=%d attachment_bytes_in=%d attachment_bytes_out=%d " +
		"attachment_crypto_ms=%d attachment_blobs_swept=%d attachment_orphans=%d " +
		"attachment_orphans_kept=%d",
		snapshot.storageRunning,
		snapshot.storageRestartPending,
		snapshot.attachmentUploads,
		snapshot.attachmentDownloads,
		snapshot.attachments.bytesIn,
		snapshot.attachments.bytesOut,
		snapshot.attachments.cryptoNanos / 1_000_000,
		snapshot.attachments.blobsSwept,
		snapshot.attachments.orphansFound,
		snapshot.attachments.orphansKept,
	)
	return strings.to_string(builder)
}

SERVER_STATUS_VOICE_DROP_NAMES := [VoiceRelayDropReason]string {
	.UnknownPeer    = "unknown_peer",
	.NotInRoom      = "not_in_room",
	.RateLimited    = "rate_limited",
	.Malformed      = "malformed",
	.Replayed       = "replayed",
	.TooOld         = "too_old",
	.BadTag         = "bad_tag",
	.Inactive       = "inactive",
	.MalformedFrame = "malformed_frame",
	.WrongRoom      = "wrong_room",
	.Muted          = "muted",
	.Oversize       = "oversize",
	.BadDuration    = "bad_duration",
	.NotSealed      = "not_sealed",
	.NoSpeakPermission = "no_speak_permission",
}

// Prints the [Status] line. The text is heap-allocated and freed here, because no server loop
// frees the temporary allocator.
mainLogStatus :: proc(pm: ^ProcessManager, state: ^MainRouterState) {
	text := formatServerStatus(MainRouterState_statusSnapshot(pm, state))
	defer delete(text)
	fmt.printfln("[Status] %s", text)
}
