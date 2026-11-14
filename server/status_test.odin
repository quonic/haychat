package server

import "core:fmt"
import "core:strings"
import "core:testing"

@(test)
testServerStatusLineListsVoiceCounters :: proc(t: ^testing.T) {
	_ = t
	snapshot := ServerStatusSnapshot {
		uptime            = 42,
		connectedPeers    = 3,
		networkRunning    = true,
		databaseRunning   = true,
		voiceRooms        = 2,
		voiceParticipants = 5,
	}
	snapshot.voiceRelay.datagramsIn = 100
	snapshot.voiceRelay.framesRelayed = 90
	snapshot.voiceRelay.datagramsOut = 360
	snapshot.voiceRelay.drops[.RateLimited] = 7
	snapshot.voiceRelay.drops[.BadTag] = 3
	text := formatServerStatus(snapshot)
	defer delete(text)

	assert(
		!strings.contains(text, "\n"),
		fmt.tprintf("expected the status to be one line, got:\n%s", text),
	)
	assert(
		strings.has_prefix(text, "uptime=42 "),
		fmt.tprintf("expected the status to start with uptime=42, got %q", text),
	)
	pairs := strings.split(text, " ")
	defer delete(pairs)
	for pair in ([]string {
			"connected_peers=3",
			"network_running=true",
			"database_running=true",
			"network_restart_pending=false",
			"database_restart_pending=false",
			"shutdown_requested=false",
			"voice_rooms=2",
			"voice_participants=5",
			"voice_frames_in=100",
			"voice_frames_relayed=90",
			"voice_frames_out=360",
			"voice_send_failures=0",
			"voice_drops_rate_limited=7",
			"voice_drops_bad_tag=3",
			"voice_drops_bad_duration=0",
		}) {
		found := false
		for candidate in pairs {
			if candidate == pair {
				found = true
				break
			}
		}
		assert(found, fmt.tprintf("expected the status to include %q, got %q", pair, text))
	}
	assert(
		!strings.contains(text, "web_admin"),
		fmt.tprintf("expected no web admin keys in the status, got %q", text),
	)
	assert(
		len(pairs) == 13 + len(VoiceRelayDropReason),
		fmt.tprintf(
			"expected 13 process and voice pairs plus one per drop reason, got %d in %q",
			len(pairs),
			text,
		),
	)
}
