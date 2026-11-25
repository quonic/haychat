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
#   1b. noise suppression (#170): N sends tone bursts over white noise (voice-check
#                   --write-noisy-tone: 440 Hz at 0.5 amplitude, 1.5 s on and 1 s off, over
#                   -34 dBFS of noise) from a file with an open gate, once with `voice-noise off`
#                   and once with `voice-noise on`, and M records each. voice-check must find the
#                   tone in both recordings; the noise floor between the bursts must stay at or
#                   above -50 dBFS without RNNoise (the noise really travels; Opus leaves about
#                   -42 dBFS of it) and fall to -60 dBFS or below with it, and N's voice-stats
#                   must report noise suppression off and then active, with RNNoise's time per
#                   20 ms frame.
#   2. SDL devices: the same through SDL's audio devices on its disk driver, which needs no
#                   audio server: C captures a 440 Hz file through `voice-source device`
#                   (SDL_AUDIO_DISK_INPUT_FILE) and D plays through `voice-sink device`
#                   (SDL_AUDIO_DISK_OUTPUT_FILE, F32 stereo). voice-check must find the tone in
#                   D's output, and D must have received 95 % of what C sent.
#   3. faults:      the file path again, but F is a client built with
#                   -define:HAYCHAT_TEST_FAULTS=true that drops 5 % of the frames it receives
#                   and delays each kept one by 0-20 ms (HAYCHAT_TEST_VOICE_LOSS and
#                   HAYCHAT_TEST_VOICE_JITTER_MS, client/voice_faults.odin), with a fixed seed.
#                   The pass criteria of voice-rooms-design.md 6.5: voice-check finds the tone
#                   in F's file; FEC plus PLC matches the frames lost (the injected drops plus
#                   any late frames) within 3 frames plus 10 % of the drops; F never heard more
#                   than 2 frames in a row inside the spurt as neither decoded nor rebuilt by
#                   FEC (maxGapRun); and F received at least 95 % of what E sent and the hook
#                   did not drop.
#   4. one session per user (protocol 13): G and H share one identity key (H's profile is a
#                   copy of G's) but have different device IDs (the copy's `device_id` is
#                   changed in its config.json). G joins room 1, then H joins room 1: G must get
#                   voice_left "joined voice on another device" and go idle without a re-join,
#                   and both must see a participant list that names the user exactly once,
#                   joined only on H.
#   5. encrypted (protocol 21, e2ee-voice-design.md 11.4): admin EA creates an encrypted Admin
#                   invite room for text and voice and adds EB and EC; all three join its voice
#                   and each reports voice_status encrypted and a voice_key accepted from both
#                   others. EA sends the tone; EB and EC record it, voice-check finds it in both
#                   files, and their engines opened frames without a bad tag. EA removes EC: EC
#                   is evicted from voice, EA and EB each accept the other's key at the new
#                   epoch, and the tone keeps reaching EB. After `voice-key-rotate 5` on EA, EB
#                   accepts at least one timed rotation and the tone still reaches it. The relay
#                   forwarded sealed payloads only (the server's NotSealed counter is not read
#                   here: the engines' counters show every frame opened).
#
# dev/live-proof.sh --voice runs it against its throwaway server (and --all, so CI does too).
# HAYCHAT_VOICE_PROOF_SECONDS sets how long A talks while both are joined (default 4), and
# HAYCHAT_VOICE_PROOF_FAULT_SECONDS how long E talks (default 8, so 5 % is about 20 frames).
# HAYCHAT_VOICE_PROOF_FAULTS=0 skips the faults stage; HAYCHAT_TEST_VOICE_SEED changes its
# loss pattern (default 1). HAYCHAT_VOICE_PROOF_NOISE=0 skips the noise suppression stage, and
# HAYCHAT_VOICE_PROOF_NOISE_SECONDS sets how long N talks in it (default 6, over two bursts).
# HAYCHAT_VOICE_PROOF_ENCRYPTED=0 skips the encrypted stage, which
# needs psql (through the HAYCHAT_DATABASE_* variables) to make EA an admin.
#
# Usage: dev/voice-proof.sh [HOST:PORT]   (default 127.0.0.1:12345)

repo_dir=$(cd -- "$(dirname -- "$0")/.." >/dev/null 2>&1 && pwd)
server_address=${1:-127.0.0.1:12345}
room_id=1
command_timeout_secs=15
talk_seconds=${HAYCHAT_VOICE_PROOF_SECONDS:-4}
fault_talk_seconds=${HAYCHAT_VOICE_PROOF_FAULT_SECONDS:-8}
run_faults=${HAYCHAT_VOICE_PROOF_FAULTS:-1}
run_encrypted=${HAYCHAT_VOICE_PROOF_ENCRYPTED:-1}
run_noise=${HAYCHAT_VOICE_PROOF_NOISE:-1}
noise_talk_seconds=${HAYCHAT_VOICE_PROOF_NOISE_SECONDS:-6}
fault_loss=0.05
fault_jitter_ms=20
fault_seed=${HAYCHAT_TEST_VOICE_SEED:-1}
tone_hz=440
tone_amplitude=0.5
smoke_label=voice

work_dir=$(mktemp -d -t haychat-voice.XXXXXX)
client_bin="$work_dir/haychat-client"
plain_client_bin=$client_bin
faults_client_bin="$work_dir/haychat-client-faults"
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

# join_voice CLIENT [ROOM_ID]: voice-join the room (default room 1) and wait for the server's
# acknowledgement of this session (recipientJoined) and the engine running (voice_status
# joined).
join_voice() {
	local client=$1 room=${2:-$room_id} start acked
	start=$(wc -l <"$work_dir/$client.out")
	expect_ok "$client" voice-join "$room"
	acked="^\\{\"event\":\"voice_participants\",\"serverID\":[0-9]+,"
	acked+="\"roomID\":$room,\"recipientJoined\":true,"
	expect_event "$client" "$acked" "$start" "no voice_participants acknowledging the join"
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
		"depth $(json_number "$listener_stats" depth)," \
		"jitter buffer delay $(json_number "$listener_stats" playoutDelayMS) ms" \
		"(max $(json_number "$listener_stats" playoutDelayMaxMS) ms)"
}

# check_fault_counters: the 6.5 criteria on speaker_stats and listener_stats for the faults
# stage.
check_fault_counters() {
	local sent received fec plc late injected gap expected tolerance repaired
	sent=$(json_number "$speaker_stats" sent)
	received=$(json_number "$listener_stats" received)
	fec=$(json_number "$listener_stats" fec)
	plc=$(json_number "$listener_stats" plc)
	late=$(json_number "$listener_stats" late)
	injected=$(json_number "$listener_stats" injectedLoss)
	gap=$(json_number "$listener_stats" maxGapRun)
	((injected > 0)) || fail "[faults] the fault hook dropped nothing: is F a faults build?"
	expect_ratio "[faults] frames received or dropped by the hook of those sent" \
		"$((received + injected))" "$sent" 95
	# Every dropped or late frame is repaired once, by FEC or PLC. The stats are read while E
	# still talks, so a drop of the last few frames may not have been played yet, and a drop
	# of the spurt's very first frame is pre-roll, not a repair: hence the slack.
	expected=$((injected + late))
	repaired=$((fec + plc))
	tolerance=$((3 + injected / 10))
	if ((repaired < expected - tolerance || repaired > expected + tolerance)); then
		fail "[faults] FEC $fec + PLC $plc = $repaired, expected $expected (dropped $injected" \
			"+ late $late) within $tolerance"
	fi
	echo "    [faults] FEC $fec + PLC $plc = $repaired for $injected dropped + $late late" \
		"(tolerance $tolerance)"
	((gap <= 2)) || fail "[faults] $gap frames in a row were concealed or silent (limit 2)"
	echo "    [faults] longest unrepaired run inside the spurt: $gap frames (limit 2)"
	echo "==> [voice] faults counters: sent $sent, received $received, dropped $injected," \
		"FEC $fec, PLC $plc, late $late, silent $(json_number "$listener_stats" silent)," \
		"max gap $gap, jitter $(json_number "$listener_stats" jitterMS) ms," \
		"depth $(json_number "$listener_stats" depth)," \
		"jitter buffer delay $(json_number "$listener_stats" playoutDelayMS) ms" \
		"(max $(json_number "$listener_stats" playoutDelayMaxMS) ms)"
}

cd "$repo_dir"
echo "==> [voice] building the client and dev/tools/voice-check"
odin build client -out:"$client_bin"
odin build dev/tools/voice-check -out:"$check_bin"
if [[ "$run_faults" == 1 ]]; then
	odin build client -define:HAYCHAT_TEST_FAULTS=true -out:"$faults_client_bin"
	# The hook must be absent from the normal build: its environment names are not in it.
	if grep -q HAYCHAT_TEST_VOICE_LOSS "$plain_client_bin"; then
		fail "the normal client build contains the voice fault hook"
	fi
	grep -q HAYCHAT_TEST_VOICE_LOSS "$faults_client_bin" ||
		fail "the HAYCHAT_TEST_FAULTS build lacks the voice fault hook"
fi
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

if [[ "$run_noise" == 1 ]]; then
	echo "==> [voice] noise suppression: N sends tone bursts over noise, without and with RNNoise"
	noisy_file="$work_dir/noisy.f32"
	"$check_bin" --write-noisy-tone "$noisy_file" --freq "$tone_hz" \
		--seconds "$((noise_talk_seconds + 30))" --amplitude "$tone_amplitude" >/dev/null
	saved_talk_seconds=$talk_seconds
	talk_seconds=$noise_talk_seconds
	for noise_mode in off on; do
		# Client names cannot repeat within a run (their pipes stay), so each mode has its own.
		speaker="n$noise_mode"
		listener="m$noise_mode"
		start_client "$speaker" "voice-n-$noise_mode-$run_tag"
		start_client "$listener" "voice-m-$noise_mode-$run_tag"
		expect_connected "$speaker"
		expect_connected "$listener"
		user_n=$(connected_user_id "$speaker")
		user_m=$(connected_user_id "$listener")
		noise_sink="$work_dir/m-$noise_mode.f32"
		expect_ok "$speaker" voice-source "file:$noisy_file"
		expect_ok "$speaker" voice-gate open
		expect_ok "$speaker" voice-noise "$noise_mode"
		expect_ok "$listener" voice-sink "file:$noise_sink"
		talk "$speaker" "$listener" "$user_n" "$user_m"
		expect_ok "$listener" voice-flush
		if [[ "$noise_mode" == on ]]; then
			[[ "$speaker_stats" == *'"noiseSuppression":"active"'* ]] \
				|| fail "[noise] N does not report RNNoise active: $speaker_stats"
			floor_limit=(--max-floor -60)
			echo "    [noise] RNNoise on N: $(json_number "$speaker_stats" denoisedFrames)" \
				"frames, $(json_number "$speaker_stats" denoiseMeanUS) us per 20 ms frame" \
				"(max $(json_number "$speaker_stats" denoiseMaxUS) us)"
		else
			[[ "$speaker_stats" == *'"noiseSuppression":"off"'* ]] \
				|| fail "[noise] N does not report noise suppression off: $speaker_stats"
			floor_limit=(--min-floor -50)
		fi
		"$check_bin" "$noise_sink" --freq "$tone_hz" --tolerance 5 --min-seconds 1 \
			--amplitude "$tone_amplitude" "${floor_limit[@]}" \
			|| fail "[noise] voice-check rejected M's recording with RNNoise $noise_mode"
		check_counters "noise $noise_mode"
		expect_ok "$listener" voice-leave
		stop_client "$speaker"
		stop_client "$listener"
	done
	talk_seconds=$saved_talk_seconds
	echo "==> [voice] noise suppression passed"
fi

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
# #36: SIGTERM stops a client whose SDL audio is open (C's capture device, in voice again)
# within seconds and with code 0, its stdin still open. D, out of voice, sees C come and go.
participants_out="^\\{\"event\":\"voice_participants\",\"serverID\":[0-9]+,"
participants_out+="\"roomID\":$room_id,\"recipientJoined\":false,"
d_start=$(wc -l <"$work_dir/d.out")
join_voice c
expect_event d "${participants_out}.*\"userID\":$user_c," "$d_start" \
	"D never listed C in the room's voice again"
d_start=$(wc -l <"$work_dir/d.out")
terminate_client c 10
expect_event d "${participants_out}\"participants\":(\\[\\]|null)\\}$" "$d_start" \
	"D still lists C in the room's voice after SIGTERM"
echo "    C exited with code 0 on SIGTERM with SDL audio open"
stop_client d
echo "==> [voice] SDL devices passed"

if [[ "$run_faults" == 1 ]]; then
	echo "==> [voice] faults: E sends the tone, F receives it through ${fault_loss} loss and" \
		"0-${fault_jitter_ms} ms jitter (seed $fault_seed)"
	start_client e "voice-e-$run_tag"
	client_bin=$faults_client_bin
	export HAYCHAT_TEST_VOICE_LOSS=$fault_loss HAYCHAT_TEST_VOICE_JITTER_MS=$fault_jitter_ms
	export HAYCHAT_TEST_VOICE_SEED=$fault_seed
	start_client f "voice-f-$run_tag"
	unset HAYCHAT_TEST_VOICE_LOSS HAYCHAT_TEST_VOICE_JITTER_MS HAYCHAT_TEST_VOICE_SEED
	client_bin=$plain_client_bin
	expect_connected e
	expect_connected f
	user_e=$(connected_user_id e)
	user_f=$(connected_user_id f)
	fault_sink_file="$work_dir/f.f32"
	expect_ok e voice-source "tone:$tone_hz:$tone_amplitude"
	expect_ok e voice-gate open
	expect_ok f voice-sink "file:$fault_sink_file"
	saved_talk_seconds=$talk_seconds
	talk_seconds=$fault_talk_seconds
	talk e f "$user_e" "$user_f"
	talk_seconds=$saved_talk_seconds
	expect_ok f voice-flush
	"$check_bin" "$fault_sink_file" --freq "$tone_hz" --tolerance 5 \
		--min-seconds "$((fault_talk_seconds - 1))" --amplitude "$tone_amplitude" ||
		fail "[faults] voice-check rejected F's recording"
	check_fault_counters
	expect_ok f voice-leave
	stop_client e
	stop_client f
	echo "==> [voice] faults passed"
fi

echo "==> [voice] one session per user: G and H, one identity, two device IDs"
start_client g "voice-g-$run_tag"
expect_connected g
user_g=$(connected_user_id g)
# loadConfig saved G's profile, device ID included, before G connected. H gets a copy of it:
# the same identity key and, until it is changed here, the same device ID.
copy_profile g h
h_config="$work_dir/profile-h/haychat/config.json"
g_device=$(grep -oE '"device_id":"[0-9a-f]{32}"' "$work_dir/profile-g/haychat/config.json") ||
	fail "[session] G's config.json has no device_id"
h_device_id=$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')
[[ "$h_device_id" =~ ^[0-9a-f]{32}$ ]] || fail "[session] could not make a device ID"
[[ "$g_device" != "\"device_id\":\"$h_device_id\"" ]] || fail "[session] the IDs collided"
sed -i -E "s/\"device_id\":\"[0-9a-f]{32}\"/\"device_id\":\"$h_device_id\"/" "$h_config"
grep -qF "\"device_id\":\"$h_device_id\"" "$h_config" ||
	fail "[session] could not change the copy's device_id"
echo "    copied G's profile for H and gave the copy its own device_id"
start_client h "voice-g-$run_tag" h
expect_connected h
user_h=$(connected_user_id h)
[[ "$user_h" == "$user_g" ]] || fail "[session] H is user $user_h, expected G's user $user_g"
join_voice g
g_start=$(wc -l <"$work_dir/g.out")
h_start=$(wc -l <"$work_dir/h.out")
join_voice h
takeover_reason="joined voice on another device"
voice_left_line="^\\{\"event\":\"voice_left\",\"serverID\":[0-9]+,\"roomID\":$room_id,"
voice_left_line+="\"reason\":\"$takeover_reason\"\\}$"
expect_event g "$voice_left_line" "$g_start" "G was not told that another device took voice"
# Idle with no room to re-join, and the reason the voice bar shows.
idle_line="^\\{\"event\":\"voice_status\",.*\"status\":\"idle\",\"wantRoomID\":0,"
idle_line+="\"error\":\"$takeover_reason\","
expect_event g "$idle_line" "$g_start" "G did not go idle without a re-join"
# One participant object, the shared user, joined on H and not on G.
only_user="\"participants\":\\[\\{\"userID\":$user_g,[^{}]*\\}\\]\\}$"
expect_event h "${participants_acked}${only_user}" "$h_start" \
	"H's list does not name the user exactly once"
participants_elsewhere="^\\{\"event\":\"voice_participants\",\"serverID\":[0-9]+,"
participants_elsewhere+="\"roomID\":$room_id,\"recipientJoined\":false,"
expect_event g "${participants_elsewhere}${only_user}" "$g_start" \
	"G's list does not name the user exactly once, joined on the other device"
if tail -n "+$((g_start + 1))" "$work_dir/g.out" | grep -qF '"status":"joining"'; then
	fail "[session] G tried to join voice again after the takeover"
fi
expect_ok h voice-leave
stop_client g
stop_client h
echo "==> [voice] one session per user passed"

# voice_key_line CLIENT KIND USER_ID EPOCH START: waits for a voice_key event of KIND about
# USER_ID at EPOCH (any epoch when EPOCH is empty) and echoes it.
voice_key_line() {
	local client=$1 kind=$2 user=$3 epoch=$4 start=$5 pattern
	pattern="^\\{\"event\":\"voice_key\",\"serverID\":[0-9]+,\"roomID\":$e2ee_room,"
	pattern+="\"kind\":\"$kind\",\"userID\":$user,\"epoch\":${epoch:-[0-9]+},"
	expect_event "$client" "$pattern" "$start" "no voice_key $kind for user $user"
}

# opened_frames CLIENT: the client's voice-stats framesOpened, after checking that nothing it
# received failed its tag.
opened_frames() {
	local client=$1 opened bad
	expect_ok "$client" voice-stats >/dev/null
	opened=$(json_number "$last_result" framesOpened)
	bad=$(json_number "$last_result" dropBadTag)
	((bad == 0)) || fail "[encrypted] client $client had $bad frames fail their tag"
	[[ "$last_result" == *'"e2ee":{"encrypted":true,'* ]] ||
		fail "[encrypted] client $client's voice-stats do not say encrypted: $last_result"
	echo "    [encrypted] $client: opened $opened," \
		"no key $(json_number "$last_result" dropNoKey)," \
		"unknown key ID $(json_number "$last_result" dropUnknownKeyID)," \
		"keys accepted $(json_number "$last_result" keysAccepted)" >&2
	printf '%s\n' "$opened"
}

# room_log_at CLIENT VERSION START: waits for CLIENT's verified log of the encrypted room at
# VERSION.
room_log_at() {
	local pattern="^\\{\"event\":\"room_log\",\"serverID\":[0-9]+,\"roomID\":$e2ee_room,"
	pattern+="\"status\":\"verified\",\"logVersion\":$2,"
	expect_event "$1" "$pattern" "$3" "the encrypted room's log never verified at version $2"
}

if [[ "$run_encrypted" == 1 ]]; then
	echo "==> [voice] encrypted: EA, EB and EC in an encrypted room's voice"
	start_client ea "voice-ea-$run_tag"
	start_client eb "voice-eb-$run_tag"
	start_client ec "voice-ec-$run_tag"
	expect_connected ea
	expect_connected eb
	expect_connected ec
	user_ea=$(connected_user_id ea)
	user_eb=$(connected_user_id eb)
	user_ec=$(connected_user_id ec)
	make_admin "voice-ea-$run_tag"
	expect_ok ea reconnect
	expect_ok ea wait connected 8000
	for client in ea eb ec; do
		expect_ok "$client" wait room_list 5000
	done
	for user in "$user_eb" "$user_ec"; do
		start=$(wc -l <"$work_dir/ea.out")
		expect_ok ea user-keys "$user"
		expect_event ea "^\\{\"event\":\"user_keys\",.*\"userID\":$user," "$start" \
			"EA got no keys for user $user"
	done
	start=$(wc -l <"$work_dir/ea.out")
	expect_ok ea room-create "both,admin-invite,encrypted,managers=none" "voice-e2ee-$run_tag"
	created_line="^\\{\"event\":\"room_created\",.*\"name\":\"voice-e2ee-$run_tag\""
	created=$(wait_for_match ea "$created_line" "$start") ||
		fail "[encrypted] EA never got room_created"
	[[ "$created" =~ \"roomID\":([0-9]+) ]] || fail "[encrypted] no roomID in: $created"
	e2ee_room=${BASH_REMATCH[1]}
	room_log_at ea 1 "$start"
	bstart=$(wc -l <"$work_dir/eb.out")
	expect_ok ea room-add "$e2ee_room" "$user_eb"
	room_log_at ea 2 "$start"
	room_log_at eb 2 "$bstart"
	cstart=$(wc -l <"$work_dir/ec.out")
	expect_ok ea room-add "$e2ee_room" "$user_ec"
	room_log_at ea 3 "$start"
	room_log_at eb 3 "$bstart"
	room_log_at ec 3 "$cstart"

	eb_sink="$work_dir/eb.f32"
	ec_sink="$work_dir/ec.f32"
	expect_ok ea voice-source "tone:$tone_hz:$tone_amplitude"
	expect_ok ea voice-gate open
	expect_ok eb voice-sink "file:$eb_sink"
	expect_ok ec voice-sink "file:$ec_sink"
	declare -A key_start=()
	for client in eb ec ea; do
		key_start[$client]=$(wc -l <"$work_dir/$client.out")
		join_voice "$client" "$e2ee_room"
		expect_event "$client" "^\\{\"event\":\"voice_status\",.*\"encrypted\":true," \
			"${key_start[$client]}" "voice_status does not say encrypted"
	done
	# Each hears both others' keys at epoch 3.
	voice_key_line ea accepted "$user_eb" 3 "${key_start[ea]}"
	voice_key_line ea accepted "$user_ec" 3 "${key_start[ea]}"
	voice_key_line eb accepted "$user_ea" 3 "${key_start[eb]}"
	voice_key_line eb accepted "$user_ec" 3 "${key_start[eb]}"
	voice_key_line ec accepted "$user_ea" 3 "${key_start[ec]}"
	voice_key_line ec accepted "$user_eb" 3 "${key_start[ec]}"
	speaking="^\\{\"event\":\"voice_speaking\",\"serverID\":[0-9]+,\"roomID\":$e2ee_room,"
	speaking+="\"userID\":$user_ea,\"speaking\":true,\"self\":false\\}$"
	expect_event eb "$speaking" "${key_start[eb]}" "EB never heard EA speaking"
	expect_event ec "$speaking" "${key_start[ec]}" "EC never heard EA speaking"
	sleep "$talk_seconds"
	opened_eb=$(opened_frames eb)
	opened_ec=$(opened_frames ec)
	expect_ratio "[encrypted] EB's frames opened for ${talk_seconds} s" "$opened_eb" \
		"$((talk_seconds * 50))" 80
	expect_ratio "[encrypted] EC's frames opened for ${talk_seconds} s" "$opened_ec" \
		"$((talk_seconds * 50))" 80

	echo "==> [voice] encrypted: EA removes EC; EA and EB rotate to the new epoch"
	astart=$(wc -l <"$work_dir/ea.out")
	bstart=$(wc -l <"$work_dir/eb.out")
	cstart=$(wc -l <"$work_dir/ec.out")
	expect_ok ea room-remove "$e2ee_room" "$user_ec"
	removed="^\\{\"event\":\"voice_left\",\"serverID\":[0-9]+,\"roomID\":$e2ee_room,"
	removed+="\"reason\":\"removed from the room\"\\}$"
	expect_event ec "$removed" "$cstart" "EC was not evicted from voice"
	voice_key_line ea accepted "$user_eb" 4 "$astart"
	voice_key_line eb accepted "$user_ea" 4 "$bstart"
	expect_ok ec voice-flush
	"$check_bin" "$ec_sink" --freq "$tone_hz" --tolerance 5 --min-seconds "$min_tone_seconds" \
		--amplitude "$tone_amplitude" || fail "[encrypted] voice-check rejected EC's recording"
	before=$(opened_frames eb)
	sleep "$talk_seconds"
	after=$(opened_frames eb)
	expect_ratio "[encrypted] EB's frames opened after the removal" "$((after - before))" \
		"$((talk_seconds * 50))" 80

	echo "==> [voice] encrypted: a timed rotation every 5 s on EA"
	astart=$(wc -l <"$work_dir/ea.out")
	bstart=$(wc -l <"$work_dir/eb.out")
	expect_ok ea voice-key-rotate 5
	timed="^\\{\"event\":\"voice_key\",\"serverID\":[0-9]+,\"roomID\":$e2ee_room,"
	timed+="\"kind\":\"sent\",\"userID\":$user_ea,\"epoch\":4,\"generation\":([0-9]+),"
	timed+="\"rotation\":\"timer\","
	line=$(wait_for_match ea "$timed" "$astart") || fail "[encrypted] EA never rotated on time"
	echo "    ea< $line"
	[[ "$line" =~ \"generation\":([0-9]+) ]] || fail "[encrypted] no generation in: $line"
	timed_generation=${BASH_REMATCH[1]}
	accepted="^\\{\"event\":\"voice_key\",\"serverID\":[0-9]+,\"roomID\":$e2ee_room,"
	accepted+="\"kind\":\"accepted\",\"userID\":$user_ea,\"epoch\":4,"
	accepted+="\"generation\":$timed_generation,"
	expect_event eb "$accepted" "$bstart" "EB never accepted EA's timed rotation"
	before=$(opened_frames eb)
	sleep "$talk_seconds"
	after=$(opened_frames eb)
	expect_ratio "[encrypted] EB's frames opened across timed rotations" "$((after - before))" \
		"$((talk_seconds * 50))" 80
	expect_ok ea voice-leave
	expect_ok eb voice-flush
	"$check_bin" "$eb_sink" --freq "$tone_hz" --tolerance 5 \
		--min-seconds "$min_tone_seconds" --amplitude "$tone_amplitude" ||
		fail "[encrypted] voice-check rejected EB's recording"
	expect_ok eb voice-leave
	stop_client ea
	stop_client eb
	stop_client ec
	echo "==> [voice] encrypted passed"
fi

echo "==> [voice] passed"
