#!/usr/bin/env bash
set -euo pipefail

# Live voice proof between two client processes (voice-rooms-design.md 6.2, H7). It builds
# the client and dev/tools/voice-check, starts headless clients with isolated profiles against
# a running server, and drives them over named pipes (dev/harness-lib.sh):
#
#   1. file path:   B records into a file sink and joins room 1; A sends a 440 Hz tone at 0.5
#                   amplitude with an open gate and joins too. Both must be acknowledged
#                   (voice_participants with recipientJoined, then voice_status joined), and B
#                   must hear A speaking (voice_speaking). After a few seconds A reports its
#                   voice-stats and leaves; B must see A stop and drop out of the room's list,
#                   then reports its own stats and flushes its file. voice-check must find the
#                   tone in B's file, and the counters must show nothing lost on loopback:
#                   A sent at least 95 % of the frames its time in voice calls for, B received
#                   at least 95 % of what A sent, and FEC plus PLC stayed under 2 % of that.
#   2. SDL devices: the same through SDL's audio devices on its disk driver, which needs no
#                   audio server: C captures a 440 Hz file through `voice-source device`
#                   (SDL_AUDIO_DISK_INPUT_FILE) and D plays through `voice-sink device`
#                   (SDL_AUDIO_DISK_OUTPUT_FILE, F32 stereo). voice-check must find the tone in
#                   D's output, and D must have received 95 % of what C sent.
#
# dev/live-proof.sh --voice runs it against its throwaway server (and --all, so CI does too).
# HAYCHAT_VOICE_PROOF_SECONDS sets how long A talks while both are joined (default 4).
#
# Usage: dev/voice-proof.sh [HOST:PORT]   (default 127.0.0.1:12345)

repo_dir=$(cd -- "$(dirname -- "$0")/.." >/dev/null 2>&1 && pwd)
server_address=${1:-127.0.0.1:12345}
room_id=1
command_timeout_secs=15
talk_seconds=${HAYCHAT_VOICE_PROOF_SECONDS:-4}
tone_hz=440
tone_amplitude=0.5
smoke_label=voice

work_dir=$(mktemp -d -t haychat-voice.XXXXXX)
client_bin="$work_dir/haychat-client"
check_bin="$work_dir/voice-check"
run_tag=$(date +%s%N)

declare -A client_pid=()
declare -A client_fd=()

on_exit() {
	local status=$? client
	for client in "${!client_pid[@]}"; do
		kill "${client_pid[$client]}" 2>/dev/null || true
	done
	if [[ $status -ne 0 ]]; then
		print_client_output
	fi
	rm -rf -- "$work_dir"
	exit "$status"
}
trap on_exit EXIT

# shellcheck source=dev/harness-lib.sh
source "$repo_dir/dev/harness-lib.sh"

# json_number JSON KEY: the first number under "KEY" in a compact JSON line. The flat summary
# fields of voice-stats come before the nested counters, so the first match is the summary's.
json_number() {
	local pattern="\"$2\":(-?[0-9]+(\\.[0-9]+)?)"
	[[ "$1" =~ $pattern ]] || fail "no \"$2\" in: $1"
	printf '%s\n' "${BASH_REMATCH[1]}"
}

# connected_user_id CLIENT: the userID from the client's first connected line.
connected_user_id() {
	local line
	line=$(wait_for_line "$1" '{"event":"connected",' 0) || fail "client $1 never connected"
	json_number "$line" userID
}

# expect_event CLIENT REGEX START WHAT: waits for an event line after START, echoes it.
expect_event() {
	local client=$1 pattern=$2 start=$3 what=$4 line
	line=$(wait_for_match "$client" "$pattern" "$start") || fail "client $client: $what"
	echo "    $client< $line"
}

# Event line prefixes, as extended regexes.
participants_acked="^\\{\"event\":\"voice_participants\",\"serverID\":[0-9]+,"
participants_acked+="\"roomID\":$room_id,\"recipientJoined\":true,"
speaking_prefix="^\\{\"event\":\"voice_speaking\",\"serverID\":[0-9]+,\"roomID\":$room_id,"

# join_voice CLIENT: voice-join room 1 and wait for the server's acknowledgement of this
# session (recipientJoined) and the engine running (voice_status joined).
join_voice() {
	local client=$1 start
	start=$(wc -l <"$work_dir/$client.out")
	expect_ok "$client" voice-join "$room_id"
	expect_event "$client" "$participants_acked" "$start" \
		"no voice_participants acknowledging the join"
	expect_event "$client" "^\\{\"event\":\"voice_status\",.*\"status\":\"joined\"," "$start" \
		"voice never reached joined"
}

# expect_ratio WHAT ACTUAL EXPECTED PERCENT: ACTUAL must be at least PERCENT % of EXPECTED.
expect_ratio() {
	local what=$1 actual=$2 expected=$3 percent=$4
	if ((actual * 100 < expected * percent)); then
		fail "$what: $actual is under $percent % of $expected"
	fi
	echo "    $what: $actual of $expected (needs $percent %)"
}

# expect_low_repair WHAT FEC PLC RECEIVED: FEC plus PLC under 2 % of RECEIVED (at least 2).
expect_low_repair() {
	local what=$1 fec=$2 plc=$3 received=$4 limit
	limit=$((received / 50))
	((limit >= 2)) || limit=2
	if ((fec + plc > limit)); then
		fail "$what: FEC $fec + PLC $plc is over $limit for $received frames on loopback"
	fi
	echo "    $what: FEC $fec + PLC $plc (limit $limit)"
}

# talk SPEAKER LISTENER SPEAKER_USER LISTENER_USER: the speaker joins after the listener, the
# listener must hear it, and after talk_seconds both report their stats and the speaker
# leaves. Sets speaker_stats and listener_stats.
talk() {
	local speaker=$1 listener=$2 speaker_user=$3 listener_user=$4 start
	join_voice "$listener"
	start=$(wc -l <"$work_dir/$listener.out")
	join_voice "$speaker"
	expect_event "$listener" "${participants_acked}.*\"userID\":$speaker_user," "$start" \
		"never listed $speaker in the room's voice"
	expect_event "$listener" \
		"${speaking_prefix}\"userID\":$speaker_user,\"speaking\":true,\"self\":false\\}$" \
		"$start" "never heard $speaker speaking"
	sleep "$talk_seconds"
	# Both counters while the speaker still talks: a leave stops its frames without an
	# end-of-spurt flag, so the listener conceals the last few (PLC, then silence) and those
	# would count as repairs although nothing was lost.
	expect_ok "$speaker" voice-stats
	speaker_stats=$last_result
	expect_ok "$listener" voice-stats
	listener_stats=$last_result
	start=$(wc -l <"$work_dir/$listener.out")
	expect_ok "$speaker" voice-leave
	expect_event "$listener" \
		"${speaking_prefix}\"userID\":$speaker_user,\"speaking\":false,\"self\":false\\}$" \
		"$start" "never saw $speaker stop speaking"
	# Only the listener is left in the room's voice: one participant object, its own.
	expect_event "$listener" \
		"${participants_acked}\"participants\":\\[\\{\"userID\":$listener_user,[^{}]*\\}\\]\\}$" \
		"$start" "still lists $speaker in the room's voice after it left"
}

# check_counters LABEL [CHECK_PACING]: the thresholds on speaker_stats and listener_stats.
check_counters() {
	local label=$1 check_pacing=${2:-true} sent joined_ms received fec plc
	sent=$(json_number "$speaker_stats" sent)
	joined_ms=$(json_number "$speaker_stats" joinedMS)
	received=$(json_number "$listener_stats" received)
	fec=$(json_number "$listener_stats" fec)
	plc=$(json_number "$listener_stats" plc)
	if [[ "$check_pacing" == true ]]; then
		expect_ratio "[$label] frames sent for ${joined_ms} ms in voice" "$sent" \
			"$((joined_ms / 20))" 95
	fi
	# The listener's stats come just after the speaker's, so the few frames still in flight
	# or in the jitter buffer are well inside the 5 %.
	expect_ratio "[$label] frames received of those sent" "$received" "$sent" 95
	expect_low_repair "[$label] repaired frames" "$fec" "$plc" "$received"
	echo "==> [voice] $label counters: sent $sent in ${joined_ms} ms, received $received," \
		"FEC $fec, PLC $plc, late $(json_number "$listener_stats" late)," \
		"jitter $(json_number "$listener_stats" jitterMS) ms," \
		"depth $(json_number "$listener_stats" depth)"
}

cd "$repo_dir"
echo "==> [voice] building the client and dev/tools/voice-check"
odin build client -out:"$client_bin"
odin build dev/tools/voice-check -out:"$check_bin"
min_tone_seconds=$((talk_seconds - 1))

echo "==> [voice] file path: A sends a ${tone_hz} Hz tone, B records it into a file"
start_client a "voice-a-$run_tag"
start_client b "voice-b-$run_tag"
expect_connected a
expect_connected b
user_a=$(connected_user_id a)
user_b=$(connected_user_id b)
sink_file="$work_dir/b.f32"
expect_ok a voice-source "tone:$tone_hz:$tone_amplitude"
expect_ok a voice-gate open
expect_ok b voice-sink "file:$sink_file"
talk a b "$user_a" "$user_b"
expect_ok b voice-flush
flushed_bytes=$(json_number "$last_result" bytes)
((flushed_bytes > 0)) || fail "[file] voice-flush reported an empty file"
"$check_bin" "$sink_file" --freq "$tone_hz" --tolerance 5 --min-seconds "$min_tone_seconds" \
	--amplitude "$tone_amplitude" || fail "[file] voice-check rejected B's recording"
check_counters file
expect_ok b voice-leave
stop_client a
stop_client b
echo "==> [voice] file path passed"

echo "==> [voice] SDL devices: C captures through the disk driver, D plays through it"
mic_file="$work_dir/mic.f32"
speaker_file="$work_dir/speaker.f32"
# Longer than C can talk, so the capture never runs out of tone.
"$check_bin" --write-tone "$mic_file" --freq "$tone_hz" --seconds "$((talk_seconds + 30))" \
	--amplitude "$tone_amplitude" >/dev/null
export SDL_AUDIO_DRIVER=disk SDL_AUDIO_DISK_INPUT_FILE="$mic_file"
start_client c "voice-c-$run_tag"
unset SDL_AUDIO_DISK_INPUT_FILE
export SDL_AUDIO_DISK_OUTPUT_FILE="$speaker_file"
start_client d "voice-d-$run_tag"
unset SDL_AUDIO_DRIVER SDL_AUDIO_DISK_OUTPUT_FILE
expect_connected c
expect_connected d
user_c=$(connected_user_id c)
user_d=$(connected_user_id d)
expect_ok c voice-source device
expect_ok c voice-gate open
expect_ok d voice-sink device
talk c d "$user_c" "$user_d"
# The disk driver writes its file while the playback device is open; leaving closes it.
expect_ok d voice-leave
# The disk driver writes the playback device's format: F32 stereo at 48 kHz.
"$check_bin" "$speaker_file" --channels 2 --freq "$tone_hz" --tolerance 5 \
	--min-seconds "$min_tone_seconds" --amplitude "$tone_amplitude" ||
	fail "[device] voice-check rejected D's playback"
# The disk driver paces capture by its own clock, so only the delivery is checked.
check_counters device false
stop_client c
stop_client d
echo "==> [voice] SDL devices passed"

echo "==> [voice] passed"
