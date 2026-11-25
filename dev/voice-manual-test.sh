#!/usr/bin/env bash
set -euo pipefail

# Manual voice test kit on a host with PipeWire (voice-rooms-design.md 6.3, 6.4 and H8).
# It measures what voice does on real audio devices, through SDL's PipeWire driver, the real
# server relay and the default settings, using only virtual devices it creates and removes:
#
#   HC-MT-Feed  null sink the kit plays test material into (pw-cat)
#   HC-MT-Mic   virtual microphone (module-remap-source on HC-MT-Feed's monitor); client A
#               captures it with `voice-source device:HC-MT-Mic`
#   HC-MT-B-Out null sink client B plays into with `voice-sink device:HC-MT-B-Out`
#   HC-MT-Probe stereo null sink: HC-MT-Mic is linked into its left channel and HC-MT-B-Out's
#               monitor into its right (pw-link), and one pw-record of it puts what A heard
#               and what B played on the same clock
#
# Phases, each with both clients' voice-stats before and after:
#
#   tone     a 440 Hz sine at amplitude 0.5 for 6 s; dev/tools/voice-check reports frequency,
#            level and SNR of what B played, and the analysis counts playout dropouts
#   speech   espeak-ng sentences (skipped without espeak-ng) at several peak levels over a
#            pink noise floor, with A on voice activity: speech frames heard, words with
#            clipped starts or ends, and background sent beyond the hangover
#   taps     5 ms taps (a keyboard, a knock) 1.007 s apart on voice activity: how many open
#            the gate, each for at least the hangover
#   bursts   300 ms 1 kHz bursts 1.507 s apart on voice activity: the delay at a talk spurt's
#            start, which includes the gate's attack and the jitter buffer's pre-roll
#   clicks   a click train (5 ms at 1 kHz, every second) with A's gate held open: the
#            steady-state mouth-to-ear delay, p50 and p95
#
# Safety: nothing is played on or recorded from a real device. Every stream the kit starts
# (pw-cat, pw-record, the two clients) names its virtual target and sets
# node.dont-fallback, so a missing target is an error and never the default device. The
# clients run on SDL's pipewire driver only, and the kit checks with pactl that A captures
# HC-MT-Mic and B plays into HC-MT-B-Out before any sound is played. The default sink and
# source are recorded first and put back if loading a module changed them, and the exit trap
# stops every process and unloads every module the kit loaded, then checks that the module
# list is as it was.
#
# Usage: dev/voice-manual-test.sh [HOST:PORT]   (default 127.0.0.1:12345; any running server)
#
# Environment:
#   HAYCHAT_VOICE_MANUAL_ROOM           room to join (default 1; ignored when encrypted)
#   HAYCHAT_VOICE_MANUAL_ENCRYPTED=1    measure an encrypted room's voice (protocol 21: sealed
#                                       frames, constant bitrate) instead: A is made an admin
#                                       and creates an encrypted Admin invite room with B in it
#   HAYCHAT_VOICE_MANUAL_PSQL           psql command for making A an admin in encrypted mode
#                                       (default "<repo>/dev.sh psql", the dev pod's database)
#   HAYCHAT_VOICE_MANUAL_LEVELS         speech peak levels in dBFS (default "-6 -18 -30")
#   HAYCHAT_VOICE_MANUAL_NOISE_DB       pink noise floor under the speech, RMS dBFS (default -60)
#   HAYCHAT_VOICE_MANUAL_THRESHOLD_DB   A's voice activity threshold (default: the client's)
#   HAYCHAT_VOICE_MANUAL_NOISE_SUPPRESSION=1  noise suppression on A's microphone (voice-noise
#                                       on, #170: WebRTC's suppressor where WebRTC audio
#                                       processing loads, else RNNoise; `rnnoise` keeps
#                                       RNNoise, as #170's measurements had it; default 0, the
#                                       harness's default, so runs compare)
#   HAYCHAT_VOICE_MANUAL_ECHO_CANCELLATION=1  AEC3 on A's microphone (voice-echo on, #171;
#                                       default 0). A plays into a null sink, so there is no
#                                       echo to cancel: this measures what the canceller costs
#                                       speech, the gate and the delay on real devices
#   HAYCHAT_VOICE_MANUAL_CLICKS         clicks in the latency train (default 20)
#   HAYCHAT_VOICE_MANUAL_PHASES         phases to run (default "tone speech taps bursts clicks")
#   HAYCHAT_VOICE_MANUAL_CLIENT         use this client binary instead of building one, for
#                                       example one built with a changed constant to compare
#   HAYCHAT_VOICE_MANUAL_KEEP=1         keep the work directory (recordings, logs)
#
# Needs pactl, pw-cat, pw-record, pw-link and sox. espeak-ng adds the speech
# phase; python3 with numpy adds the speech, burst and latency analysis. docs/voice-manual-test.md
# explains the output and what good numbers look like.

repo_dir=$(cd -- "$(dirname -- "$0")/.." >/dev/null 2>&1 && pwd)
server_address=${1:-127.0.0.1:12345}
room_id=${HAYCHAT_VOICE_MANUAL_ROOM:-1}
encrypted=${HAYCHAT_VOICE_MANUAL_ENCRYPTED:-0}
psql_command=${HAYCHAT_VOICE_MANUAL_PSQL:-"$repo_dir/dev.sh psql"}
speech_levels=${HAYCHAT_VOICE_MANUAL_LEVELS:-"-6 -18 -30"}
noise_db=${HAYCHAT_VOICE_MANUAL_NOISE_DB:--60}
threshold_db=${HAYCHAT_VOICE_MANUAL_THRESHOLD_DB:-}
noise_suppression=${HAYCHAT_VOICE_MANUAL_NOISE_SUPPRESSION:-0}
echo_cancellation=${HAYCHAT_VOICE_MANUAL_ECHO_CANCELLATION:-0}
click_count=${HAYCHAT_VOICE_MANUAL_CLICKS:-20}
client_override=${HAYCHAT_VOICE_MANUAL_CLIENT:-}
phases=" ${HAYCHAT_VOICE_MANUAL_PHASES:-tone speech taps bursts clicks} "
keep_work=${HAYCHAT_VOICE_MANUAL_KEEP:-0}
command_timeout_secs=20
smoke_label=voice-manual
tone_hz=440
# The gate's default threshold and hangover, for the analysis: read from the client source,
# so a change of either default is measured without editing this script.
gate_source="$repo_dir/client/voice_gate.odin"
default_threshold=$(sed -n 's/^VOICE_VAD_DEFAULT_THRESHOLD_DB :: f32(\(-\{0,1\}[0-9.]*\))$/\1/p' \
	"$gate_source")
hangover_frames=$(sed -n 's/^VOICE_VAD_HANGOVER_FRAMES :: \([0-9][0-9]*\)$/\1/p' "$gate_source")
# Nothing is set up yet, so a mismatch (a renamed or reformatted constant) just stops here.
if [[ -z "$default_threshold" || -z "$hangover_frames" ]]; then
	echo "voice-manual-test: VOICE_VAD_DEFAULT_THRESHOLD_DB or VOICE_VAD_HANGOVER_FRAMES" \
		"not found in $gate_source; update the sed patterns here" >&2
	exit 2
fi
gate_threshold=${threshold_db:-$default_threshold}
gate_hangover_ms=$((hangover_frames * 20))
tone_amplitude=0.5

feed_sink=hc_mt_feed
mic_source=hc_mt_mic
b_sink=hc_mt_b_out
probe_sink=hc_mt_probe
mic_name=HC-MT-Mic
b_out_name=HC-MT-B-Out
no_fallback='node.dont-fallback = true'

work_dir=$(mktemp -d -t haychat-voice-manual.XXXXXX)
client_bin="$work_dir/haychat-client"
check_bin="$work_dir/voice-check"
analyze="$repo_dir/dev/tools/voice-manual-analyze.py"
run_tag=$(date +%s%N)

declare -A client_pid=()
declare -A client_fd=()
loaded_modules=()
helper_pids=()
default_sink=""
default_source=""
modules_before=""

# module_ids: the loaded module indices, one per line, sorted. `pactl list short modules`
# prints multi-line arguments for some modules, so only lines that start with an index count.
module_ids() {
	pactl list short modules | awk -F'\t' '/^[0-9]+\t/ {print $1}' | sort -n
}

# kit_nodes_exist: whether any sink or source named hc_mt_* exists.
kit_nodes_exist() {
	{ pactl list short sinks; pactl list short sources; } |
		awk -F'\t' 'BEGIN { found = 1 } $2 ~ /^hc_mt_/ { found = 0 } END { exit found }'
}

# restore_defaults: puts back the default sink and source recorded at the start.
restore_defaults() {
	local now
	now=$(pactl get-default-sink 2>/dev/null || true)
	if [[ -n "$default_sink" && "$now" != "$default_sink" ]]; then
		echo "==> [voice-manual] default sink changed to $now, restoring $default_sink" >&2
		pactl set-default-sink "$default_sink" || true
	fi
	now=$(pactl get-default-source 2>/dev/null || true)
	if [[ -n "$default_source" && "$now" != "$default_source" ]]; then
		echo "==> [voice-manual] default source changed to $now, restoring $default_source" >&2
		pactl set-default-source "$default_source" || true
	fi
}

# stop_process PID: waits up to 5 s for PID to exit, then kills it.
stop_process() {
	local pid=$1 tries
	for ((tries = 0; tries < 50; tries++)); do
		kill -0 "$pid" 2>/dev/null || break
		sleep 0.1
	done
	kill -KILL "$pid" 2>/dev/null || true
	wait "$pid" 2>/dev/null || true
}

on_exit() {
	local status=$? client pid index after fd id leftover
	trap - EXIT INT TERM
	for pid in "${helper_pids[@]}"; do
		kill "$pid" 2>/dev/null || true
	done
	# Stop clients the way the harness expects: EOF on stdin. Since #36 SIGTERM would do as
	# well, but HAYCHAT_VOICE_MANUAL_CLIENT may be an older build whose headless loop never read
	# the SDL quit event SIGTERM became while SDL audio was open. SIGKILL is the fallback for
	# one that does not exit within 5 s.
	for client in "${!client_pid[@]}"; do
		fd=${client_fd[$client]}
		exec {fd}>&- 2>/dev/null || true
	done
	for client in "${!client_pid[@]}"; do
		stop_process "${client_pid[$client]}"
	done
	for pid in "${helper_pids[@]}"; do
		stop_process "$pid"
	done
	if [[ $status -ne 0 ]] && ((${#client_pid[@]} > 0)); then
		print_client_output
	fi
	# Unload in reverse order: the remap source before the sink it reads.
	for ((index = ${#loaded_modules[@]} - 1; index >= 0; index--)); do
		pactl unload-module "${loaded_modules[index]}" 2>/dev/null ||
			echo "==> [voice-manual] could not unload module ${loaded_modules[index]}" >&2
	done
	if [[ -n "$modules_before" ]]; then
		restore_defaults
		after=$(module_ids)
		# The kit's own modules must be gone and no hc_mt_ node may remain. Other programs
		# may load or unload modules meanwhile (a game streaming server adds null sinks, for
		# example); that is reported but is not the kit's to undo.
		leftover=""
		for id in "${loaded_modules[@]}"; do
			grep -qx "$id" <<<"$after" && leftover+=" $id"
		done
		if kit_nodes_exist; then
			leftover+=" (hc_mt_ nodes)"
		fi
		if [[ -n "$leftover" ]]; then
			echo "==> [voice-manual] WARNING: still loaded:$leftover" >&2
			status=1
		elif [[ "$after" == "$modules_before" ]]; then
			echo "==> [voice-manual] cleanup: unloaded ${#loaded_modules[@]} modules;" \
				"module list and default devices are as before"
		else
			echo "==> [voice-manual] cleanup: unloaded ${#loaded_modules[@]} modules;" \
				"default devices are as before; other programs changed modules meanwhile:"
			diff <(printf '%s\n' "$modules_before") <(printf '%s\n' "$after") |
				sed -n 's/^[<>] /    /p' || true
		fi
	fi
	if [[ "$keep_work" == 1 ]]; then
		echo "==> [voice-manual] kept $work_dir"
	else
		rm -rf -- "$work_dir"
	fi
	exit "$status"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# shellcheck source=dev/harness-lib.sh
source "$repo_dir/dev/harness-lib.sh"

note() {
	echo "==> [voice-manual] $*"
}

# json_number JSON KEY: the first number under "KEY" (the flat voice-stats summary comes
# first, so this is the summary's value).
json_number() {
	local pattern="\"$2\":(-?[0-9]+(\\.[0-9]+)?)"
	[[ "$1" =~ $pattern ]] || fail "no \"$2\" in: $1"
	printf '%s\n' "${BASH_REMATCH[1]}"
}

# json_nested OBJECT KEY JSON: a number under "KEY" inside the "OBJECT":{...} part.
json_nested() {
	local pattern="\"$1\":\\{[^}]*\"$2\":(-?[0-9]+(\\.[0-9]+)?)"
	[[ "$3" =~ $pattern ]] || fail "no \"$1\".\"$2\" in: $3"
	printf '%s\n' "${BASH_REMATCH[1]}"
}

# load_module ARGS...: loads a module, remembers it for the exit trap, and puts the defaults
# back if PipeWire moved them to the new node.
load_module() {
	local id
	id=$(pactl load-module "$@") || fail "pactl load-module $* failed"
	loaded_modules+=("$id")
	restore_defaults
}

node_index() {
	local kind=$1 name=$2
	pactl list short "$kind" | awk -F'\t' -v name="$name" '$2 == name {print $1; exit}'
}

# stream_target KIND PID: the sink (KIND sink-inputs) or source (KIND source-outputs) index
# the process PID's stream is connected to, empty if it has none. PipeWire puts the process
# ID on the stream's client objects, not on the stream, so match the stream's Client.
stream_target() {
	local kind=$1 pid=$2 clients
	clients=$(pactl list clients | awk -v pid="$pid" '
		/^Client #/ { client = substr($2, 2) }
		index($0, "application.process.id = \"" pid "\"") { printf " %s", client }')
	pactl list "$kind" | awk -v clients="$clients " '
		/^(Sink Input|Source Output) #/ { client = "" }
		/^[[:space:]]+Client: [0-9]+$/ { client = $2 }
		/^[[:space:]]+(Sink|Source): [0-9]+$/ {
			if (client != "" && index(clients, " " client " ")) { print $2; exit }
		}'
}

# expect_routed CLIENT KIND NODE_KIND NODE_NAME: fails (and the trap stops everything) unless
# the client's stream is connected to the named virtual node. Waits up to 5 s for the
# stream to appear, because the engine opens its devices just after the join completes.
expect_routed() {
	local client=$1 kind=$2 node_kind=$3 node_name=$4 expected actual="" tries
	expected=$(node_index "$node_kind" "$node_name")
	[[ -n "$expected" ]] || fail "$node_name is not loaded"
	for ((tries = 0; tries < 50; tries++)); do
		actual=$(stream_target "$kind" "${client_pid[$client]}")
		[[ -n "$actual" ]] && break
		sleep 0.1
	done
	[[ "$actual" == "$expected" ]] ||
		fail "client $client's stream is on ${actual:-nothing}, not $node_name ($expected)"
	echo "    $client's stream is on $node_name (#$expected)"
}

# to_raw WAV RAW [CHANNEL]: converts a WAV to raw F32LE, all channels or only CHANNEL (1-based).
to_raw() {
	local wav=$1 raw=$2 channel=${3:-}
	if [[ -n "$channel" ]]; then
		sox -V1 "$wav" -t raw -e floating-point -b 32 -L "$raw" remix "$channel"
	else
		sox -V1 "$wav" -t raw -e floating-point -b 32 -L "$raw"
	fi
}

# phase NAME: whether NAME is one of the phases to run.
phase() {
	[[ "$phases" == *" $1 "* ]]
}

have() {
	command -v "$1" >/dev/null 2>&1
}

have_numpy() {
	have python3 && python3 -I -c 'import numpy' 2>/dev/null
}

# analyze SUBCOMMAND ARGS...: runs the numpy analysis and sets analysis_result to its RESULT
# line (empty without numpy or on a failure, which is reported but does not stop the run).
analyze() {
	local output
	analysis_result=""
	if [[ "$numpy_ok" != true ]]; then
		echo "    (analysis skipped: python3 with numpy is not available)"
		return 0
	fi
	if output=$(python3 -I "$analyze" "$@" 2>&1); then :; else
		echo "    (analysis reported a failure)"
	fi
	printf '%s\n' "$output" | grep -v '^RESULT ' || true
	analysis_result=$(printf '%s\n' "$output" | grep '^RESULT ' | tail -n 1 || true)
}

result_value() {
	local pattern="(^| )$1=([^ ]+)"
	[[ "$analysis_result" =~ $pattern ]] && printf '%s\n' "${BASH_REMATCH[2]}" || echo "n/a"
}

# start_probe NAME: starts recording the probe sink (left: A's mic, right: B's output).
start_probe() {
	probe_wav="$work_dir/probe-$1.wav"
	pw-record --target "$probe_sink" -P "{ $no_fallback stream.capture.sink = true }" \
		--rate 48000 --channels 2 --format f32 "$probe_wav" \
		2>"$work_dir/probe-$1.err" &
	probe_pid=$!
	helper_pids+=("$probe_pid")
	sleep 0.5
	kill -0 "$probe_pid" 2>/dev/null || fail "pw-record of $probe_sink did not start"
}

stop_probe() {
	kill -INT "$probe_pid" 2>/dev/null || true
	wait "$probe_pid" 2>/dev/null || true
}

# play FILE: plays a WAV into the feed sink and waits for it to finish. pw-cat runs in the
# background because bash runs a trap only after a foreground child exits, and `wait`
# returns at once on a signal, so Ctrl-C cleans up without waiting for the material to end.
play() {
	local pid status=0
	pw-cat --playback --target "$feed_sink" -P "{ $no_fallback }" "$1" &
	pid=$!
	helper_pids+=("$pid")
	wait "$pid" || status=$?
	((status == 0)) || fail "pw-cat could not play $1 into $feed_sink"
}

# stats_pair: both clients' voice-stats into a_stats and b_stats. Both must still be in the
# voice session they joined: a reconnect (a server restart) starts a new engine with fresh
# counters, and the phase's numbers would be meaningless.
stats_pair() {
	a_stats=$(client_command a voice-stats) || fail "no voice-stats from a"
	b_stats=$(client_command b voice-stats) || fail "no voice-stats from b"
	if [[ "$a_stats" != *'"status":"joined"'* || "$b_stats" != *'"status":"joined"'* ]] ||
		grep -q '"event":"disconnected"' "$work_dir/a.out" "$work_dir/b.out"; then
		fail "a client left voice or lost its connection during the run (server restart?)"
	fi
}

# report_delta LABEL: prints what changed in the counters since the stats in a_before/b_before.
report_delta() {
	local label=$1 sent gated dropped received fec plc late spurts
	stats_pair
	sent=$(($(json_number "$a_stats" sent) - $(json_number "$a_before" sent)))
	gated=$(($(json_nested engine framesGated "$a_stats") -
		$(json_nested engine framesGated "$a_before")))
	dropped=$(($(json_nested engine captureDropped "$a_stats") -
		$(json_nested engine captureDropped "$a_before")))
	received=$(($(json_number "$b_stats" received) - $(json_number "$b_before" received)))
	fec=$(($(json_number "$b_stats" fec) - $(json_number "$b_before" fec)))
	plc=$(($(json_number "$b_stats" plc) - $(json_number "$b_before" plc)))
	late=$(($(json_number "$b_stats" late) - $(json_number "$b_before" late)))
	spurts=$(($(json_nested jitter spurts "$b_stats") - $(json_nested jitter spurts "$b_before")))
	echo "    $label counters: A sent $sent, gated $gated, capture dropped $dropped;" \
		"B received $received," \
		"FEC $fec, PLC $plc, late $late, spurts $spurts;" \
		"B jitter $(json_number "$b_stats" jitterMS) ms, depth $(json_number "$b_stats" depth)"
	delta_sent=$sent delta_gated=$gated delta_received=$received delta_fec=$fec
	delta_plc=$plc delta_late=$late delta_spurts=$spurts
}

begin_phase() {
	stats_pair
	a_before=$a_stats
	b_before=$b_stats
}

expect_event() {
	local client=$1 pattern=$2 start=$3 what=$4 line
	line=$(wait_for_match "$client" "$pattern" "$start") || fail "client $client: $what"
	echo "    $client< $line"
}

# set_vad_gate: A on voice activity, at HAYCHAT_VOICE_MANUAL_THRESHOLD_DB or the default.
set_vad_gate() {
	if [[ -n "$threshold_db" ]]; then
		expect_ok a voice-gate vad "$threshold_db"
	else
		expect_ok a voice-gate vad
	fi
}

join_voice() {
	local client=$1 start
	start=$(wc -l <"$work_dir/$client.out")
	expect_ok "$client" voice-join "$room_id"
	expect_event "$client" "^\\{\"event\":\"voice_status\",.*\"status\":\"joined\"," "$start" \
		"voice never reached joined"
	if [[ "$encrypted" == 1 ]]; then
		expect_event "$client" "^\\{\"event\":\"voice_status\",.*\"encrypted\":true," "$start" \
			"voice_status does not say encrypted"
	fi
}

# -------------------------------------------------------------------------------------------
# Encrypted mode (HAYCHAT_VOICE_MANUAL_ENCRYPTED=1, e2ee-voice-design.md 8 and 11.4).

connected_user_id() {
	local line
	line=$(wait_for_line "$1" '{"event":"connected",' 0) || fail "client $1 never connected"
	json_number "$line" userID
}

# make_admin_here NICKNAME: gives the account NICKNAME the admin role through
# HAYCHAT_VOICE_MANUAL_PSQL (the dev pod's database by default; it is not published to the
# host, so plain psql would reach a different database).
make_admin_here() {
	local -a command
	read -r -a command <<<"$psql_command"
	"${command[@]}" -q -X -v ON_ERROR_STOP=1 -v owner="$1" \
		<"$repo_dir/deploy/sql/make-admin.sql" >/dev/null ||
		fail "could not make $1 an admin with: $psql_command (is the dev pod up?)"
	echo "    made $1 an admin (deploy/sql/make-admin.sql)"
}

# room_log_at CLIENT VERSION START: waits for CLIENT's verified log of the room at VERSION.
room_log_at() {
	local pattern="^\\{\"event\":\"room_log\",\"serverID\":[0-9]+,\"roomID\":$room_id,"
	pattern+="\"status\":\"verified\",\"logVersion\":$2,"
	expect_event "$1" "$pattern" "$3" "the encrypted room's log never verified at version $2"
}

# setup_encrypted_room: A (already an admin) creates an encrypted Admin invite room with B in
# it, and room_id becomes that room. Both clients have verified the log when it returns.
setup_encrypted_room() {
	local user_b start bstart created
	user_b=$(connected_user_id b)
	expect_ok a wait room_list 5000
	expect_ok b wait room_list 5000
	start=$(wc -l <"$work_dir/a.out")
	expect_ok a user-keys "$user_b"
	expect_event a "^\\{\"event\":\"user_keys\",.*\"userID\":$user_b," "$start" \
		"A got no keys for B"
	start=$(wc -l <"$work_dir/a.out")
	expect_ok a room-create "both,admin-invite,encrypted,managers=none" "voice-mt-e2ee-$run_tag"
	created=$(wait_for_match a \
		"^\\{\"event\":\"room_created\",.*\"name\":\"voice-mt-e2ee-$run_tag\"" "$start") ||
		fail "A never got room_created for the encrypted room"
	[[ "$created" =~ \"roomID\":([0-9]+) ]] || fail "no roomID in: $created"
	room_id=${BASH_REMATCH[1]}
	room_log_at a 1 "$start"
	bstart=$(wc -l <"$work_dir/b.out")
	expect_ok a room-add "$room_id" "$user_b"
	room_log_at a 2 "$start"
	room_log_at b 2 "$bstart"
	note "encrypted room $room_id (voice-mt-e2ee-$run_tag), A and B verified its log"
}

# expect_voice_key CLIENT USER START: CLIENT accepted a voice key from USER after START.
expect_voice_key() {
	local pattern="^\\{\"event\":\"voice_key\",\"serverID\":[0-9]+,\"roomID\":$room_id,"
	pattern+="\"kind\":\"accepted\",\"userID\":$2,"
	expect_event "$1" "$pattern" "$3" "no voice key accepted from user $2"
}

# e2ee_summary: B's sealed-frame counters for the whole run.
e2ee_summary() {
	local stats
	stats=$(client_command b voice-stats) || fail "no voice-stats from b"
	[[ "$stats" == *'"e2ee":{"encrypted":true,'* ]] ||
		fail "B's voice-stats do not say encrypted: $stats"
	local line
	line="encrypted: B opened $(json_number "$stats" framesOpened) frames;"
	line+=" bad tag $(json_number "$stats" dropBadTag),"
	line+=" no key $(json_number "$stats" dropNoKey),"
	line+=" unknown key ID $(json_number "$stats" dropUnknownKeyID),"
	line+=" keys accepted $(json_number "$stats" keysAccepted)"
	summary+=("$line")
}

# -------------------------------------------------------------------------------------------
cd "$repo_dir"

for tool in pactl pw-cat pw-record pw-link; do
	have "$tool" || fail "$tool is required (PipeWire's tools and pactl)"
done
have sox || fail "sox is required to make the test material and convert recordings"
pactl info | grep -q 'on PipeWire' || fail "pactl does not report a PipeWire server"
numpy_ok=false
have_numpy && numpy_ok=true
speech_ok=false
have espeak-ng && speech_ok=true
[[ "$numpy_ok" == true ]] ||
	note "python3 with numpy not found: latency and speech analysis are skipped"
[[ "$speech_ok" == true ]] || note "espeak-ng not found: the speech phase is skipped"

default_sink=$(pactl get-default-sink)
default_source=$(pactl get-default-source)
modules_before=$(module_ids)
! kit_nodes_exist ||
	fail "an hc_mt_ node already exists (another run, or a leftover; see docs/voice-manual-test.md)"
if [[ "$encrypted" == 1 ]]; then
	note "server $server_address, an encrypted room made for this run"
else
	note "server $server_address, room $room_id"
fi
note "default sink $default_sink, default source $default_source (left alone)"
note "PipeWire $(pactl info | sed -n 's/^Server Name: .*PipeWire \(.*\))$/\1/p')," \
	"$(pw-metadata -n settings 0 2>/dev/null |
		sed -n "s/.*key:'clock.quantum' value:'\([0-9]*\)'.*/quantum \1/p")," \
	"$(pw-metadata -n settings 0 2>/dev/null |
		sed -n "s/.*key:'clock.min-quantum' value:'\([0-9]*\)'.*/min-quantum \1/p")"

note "building the client and dev/tools/voice-check"
if [[ -n "$client_override" ]]; then
	cp -- "$client_override" "$client_bin"
	echo "    using $client_override"
elif have odin && odin build client -out:"$client_bin" 2>"$work_dir/build.err"; then
	:
else
	# The host has no working odin: build in the dev image. The repository is mounted at
	# /src there, so the binary goes into an ignored directory of the checkout first.
	echo "    host odin failed or is missing, building in the dev image (./dev.sh shell)"
	cat "$work_dir/build.err" 2>/dev/null || true
	mkdir -p "$repo_dir/.headless-profiles"
	"$repo_dir/dev.sh" shell odin build client -out:.headless-profiles/voice-manual-client ||
		fail "could not build the client"
	mv -- "$repo_dir/.headless-profiles/voice-manual-client" "$client_bin"
fi
# The voice-noise and voice-echo settings use WebRTC audio processing (#171) when its wrapper
# sits next to the client; it needs the host's libwebrtc-audio-processing-2.so.1 at runtime.
if [[ -n "${HAYCHAT_WEBRTC_APM_LIBRARY:-}" ]]; then
	:
elif deploy/build-linux-webrtc-apm.sh "$work_dir" 2>>"$work_dir/build.err"; then
	:
else
	mkdir -p "$repo_dir/.headless-profiles/voice-manual-apm"
	if "$repo_dir/dev.sh" shell deploy/build-linux-webrtc-apm.sh \
		.headless-profiles/voice-manual-apm; then
		mv -- "$repo_dir/.headless-profiles/voice-manual-apm/libhaychat-webrtc-apm.so" \
			"$work_dir/"
	else
		echo "    could not build libhaychat-webrtc-apm.so: echo cancellation is unavailable"
	fi
	rm -rf -- "$repo_dir/.headless-profiles/voice-manual-apm"
fi
if have odin && odin build dev/tools/voice-check -out:"$check_bin" 2>>"$work_dir/build.err"; then
	:
else
	"$repo_dir/dev.sh" shell odin build dev/tools/voice-check \
		-out:.headless-profiles/voice-manual-check || fail "could not build voice-check"
	mv -- "$repo_dir/.headless-profiles/voice-manual-check" "$check_bin"
fi

note "making the test material"
tone_wav="$work_dir/tone.wav"
sox -n -r 48000 -c 1 -b 16 "$tone_wav" synth 6 sine "$tone_hz" vol "$tone_amplitude"
clicks_wav="$work_dir/clicks.wav"
sox -n -r 48000 -c 1 -b 16 "$work_dir/click.wav" synth 0.005 sine 1000 vol 0.5 pad 0 0.995
sox "$work_dir/click.wav" "$clicks_wav" repeat "$((click_count - 1))"
# Taps are the clicks 1.007 s apart: 7 ms more than a multiple of the 20 ms capture frame,
# so successive taps fall at every position within a frame. Whether a 5 ms tap opens the
# gate depends on that position (a tap across a frame boundary makes two loud frames), and
# with clicks a whole second apart every tap of a run would land at the same one.
taps_wav="$work_dir/taps.wav"
sox -n -r 48000 -c 1 -b 16 "$work_dir/tap.wav" synth 0.005 sine 1000 vol 0.5 pad 0 1.002
sox "$work_dir/tap.wav" "$taps_wav" repeat "$((click_count - 1))"
bursts_wav="$work_dir/bursts.wav"
sox -n -r 48000 -c 1 -b 16 "$work_dir/burst.wav" synth 0.3 sine 1000 vol 0.5 pad 0 1.207
sox "$work_dir/burst.wav" "$bursts_wav" repeat 9
if [[ "$speech_ok" == true ]]; then
	sentences=(
		"The quick brown fox jumps over the lazy dog."
		"Can you hear me now?"
		"Six thick thistle sticks."
		"She sells sea shells by the sea shore."
		"Testing, one, two, three."
		"Please call Stella and ask her to bring these things with her from the store."
	)
	parts=()
	for index in "${!sentences[@]}"; do
		espeak-ng -w "$work_dir/s$index.raw.wav" "${sentences[index]}"
		# 1.5 s of silence after every sentence: longer than the hangover, so each sentence
		# is its own talk spurt and the pauses show whether background noise gets through.
		sox "$work_dir/s$index.raw.wav" -r 48000 -c 1 -b 32 -e floating-point \
			"$work_dir/s$index.wav" pad 0.5 1.5
		parts+=("$work_dir/s$index.wav")
	done
	sox "${parts[@]}" "$work_dir/speech-clean.wav"
	speech_seconds=$(soxi -D "$work_dir/speech-clean.wav")
	sox -n -r 48000 -c 1 -b 32 -e floating-point "$work_dir/noise-raw.wav" \
		synth "$speech_seconds" pinknoise
	noise_rms=$(sox "$work_dir/noise-raw.wav" -n stat 2>&1 | awk '/RMS +amplitude/ {print $3}')
	noise_gain=$(awk -v rms="$noise_rms" -v target="$noise_db" \
		'BEGIN { printf "%.2f", target - 20 * log(rms) / log(10) }')
	sox "$work_dir/noise-raw.wav" "$work_dir/noise.wav" gain "$noise_gain"
fi

note "creating the virtual devices"
load_module module-null-sink sink_name="$feed_sink" \
	sink_properties=device.description=HC-MT-Feed
load_module module-remap-source master="$feed_sink.monitor" source_name="$mic_source" \
	source_properties=device.description="$mic_name"
load_module module-null-sink sink_name="$b_sink" sink_properties=device.description="$b_out_name"
load_module module-null-sink sink_name="$probe_sink" channels=2 \
	channel_map=front-left,front-right sink_properties=device.description=HC-MT-Probe
mic_port=$(pw-link -o | grep -m1 "^$mic_source:.*FL$" || true)
[[ -n "$mic_port" ]] || mic_port=$(pw-link -o | grep -m1 "^$mic_source:" || true)
b_port=$(pw-link -o | grep -m1 "^$b_sink:monitor_FL$" || true)
[[ -n "$mic_port" && -n "$b_port" ]] || fail "could not find the virtual devices' ports"
pw-link "$mic_port" "$probe_sink:playback_FL" || fail "could not link $mic_port to the probe"
pw-link "$b_port" "$probe_sink:playback_FR" || fail "could not link $b_port to the probe"
echo "    $mic_port -> probe left, $b_port -> probe right"

note "starting headless clients A (speaks into $mic_name) and B (plays into $b_out_name)"
# SDL's PipeWire driver only: the pulseaudio and alsa drivers would ignore the PipeWire
# properties below. PIPEWIRE_NODE targets the virtual node and node.dont-fallback makes a
# missing node an error instead of the default device, whatever name SDL resolves.
if [[ "$encrypted" == 1 ]]; then
	# A signs in once without audio so its account exists, becomes an admin, and comes back
	# with the same profile: a role changed in the database applies at the next sign-in.
	note "encrypted mode: making A an admin"
	start_client a0 "voice-mt-a-$run_tag" a
	expect_connected a0
	stop_client a0
	make_admin_here "voice-mt-a-$run_tag"
fi
export SDL_AUDIO_DRIVER=pipewire PIPEWIRE_PROPS="{ $no_fallback }"
export PIPEWIRE_NODE=$mic_source
start_client a "voice-mt-a-$run_tag"
export PIPEWIRE_NODE=$b_sink
start_client b "voice-mt-b-$run_tag"
unset SDL_AUDIO_DRIVER PIPEWIRE_PROPS PIPEWIRE_NODE
expect_connected a
expect_connected b
if [[ "$encrypted" == 1 ]]; then
	[[ "$(wait_for_line a '{"event":"connected",' 0)" == *'"isAdmin":true'* ]] ||
		fail "A is not an admin after make-admin.sql"
	setup_encrypted_room
	user_a=$(connected_user_id a)
	user_b=$(connected_user_id b)
	b_key_start=$(wc -l <"$work_dir/b.out")
	a_key_start=$(wc -l <"$work_dir/a.out")
fi
expect_ok a voice-source "device:$mic_name"
expect_ok a voice-sink null
expect_ok b voice-source silence
expect_ok b voice-sink "device:$b_out_name"
if [[ "$noise_suppression" == 1 ]]; then
	expect_ok a voice-noise on
	note "noise suppression: on (A's microphone)"
elif [[ "$noise_suppression" == rnnoise ]]; then
	expect_ok a voice-noise rnnoise
	note "noise suppression: RNNoise (A's microphone)"
else
	expect_ok a voice-noise off
fi
if [[ "$echo_cancellation" == 1 ]]; then
	expect_ok a voice-echo on
	note "echo cancellation: on (AEC3 on A's microphone)"
else
	expect_ok a voice-echo off
fi
set_vad_gate
join_voice b
expect_routed b sink-inputs sinks "$b_sink"
join_voice a
expect_routed a source-outputs sources "$mic_source"
if [[ "$encrypted" == 1 ]]; then
	expect_voice_key b "$user_a" "$b_key_start"
	expect_voice_key a "$user_b" "$a_key_start"
fi

# Summary lines in phase order.
noise_state=off
[[ "$noise_suppression" == 1 ]] && noise_state=on
[[ "$noise_suppression" == rnnoise ]] && noise_state=rnnoise
echo_state=off
[[ "$echo_cancellation" == 1 ]] && echo_state=on
summary=("noise suppression on A: $noise_state" "echo cancellation on A: $echo_state")

# record_phase NAME FILE: plays FILE into A's microphone with the probe recording around it,
# and prints the counters that changed.
record_phase() {
	begin_phase
	start_probe "$1"
	play "$2"
	# B plays a few hundred milliseconds behind A.
	sleep 1
	stop_probe
	report_delta "$1"
}

run_tone() {
	local check line
	note "tone: ${tone_hz} Hz at amplitude $tone_amplitude for 6 s, voice activity gate"
	record_phase tone "$tone_wav"
	to_raw "$probe_wav" "$work_dir/tone-b.f32" 2
	to_raw "$probe_wav" "$work_dir/tone-probe.f32"
	check=$("$check_bin" "$work_dir/tone-b.f32" --freq "$tone_hz" --tolerance 5 \
		--min-seconds 4 --amplitude "$tone_amplitude" 2>&1) && tone_pass=pass || tone_pass=FAIL
	printf '%s\n' "$check" | sed 's/^/    /'
	analyze tone "$work_dir/tone-probe.f32"
	line="tone: voice-check $tone_pass:"
	line+=" $(printf '%s\n' "$check" | sed -n 's/^[^:]*: [A-Z]* [^:]*: //p')"
	line+="; dropouts $(result_value dropouts); A sent $delta_sent, B received $delta_received,"
	line+=" FEC $delta_fec, PLC $delta_plc, late $delta_late"
	summary+=("$line")
}

run_speech() {
	local level line
	to_raw "$work_dir/speech-clean.wav" "$work_dir/speech-clean.f32"
	for level in $speech_levels; do
		note "speech: ${#sentences[@]} espeak-ng sentences at peak $level dBFS over" \
			"$noise_db dBFS pink noise, voice activity at $gate_threshold dBFS"
		sox -V1 "$work_dir/speech-clean.wav" "$work_dir/speech-level.wav" gain -n "$level"
		sox -V1 -m -v 1 "$work_dir/speech-level.wav" -v 1 "$work_dir/noise.wav" \
			"$work_dir/speech-play.wav"
		# The analysis compares against the clean speech at the same gain.
		to_raw "$work_dir/speech-level.wav" "$work_dir/speech-ref.f32"
		record_phase "speech$level" "$work_dir/speech-play.wav"
		to_raw "$probe_wav" "$work_dir/speech-probe.f32"
		analyze speech "$work_dir/speech-probe.f32" --clean "$work_dir/speech-ref.f32" \
			--threshold "$gate_threshold" --hangover-ms "$gate_hangover_ms"
		line="speech peak $level dBFS (speech $(result_value level) dBFS): heard"
		line+=" $(result_value speechPassedPct) % of speech frames,"
		line+=" starts clipped $(result_value startClipped)/$(result_value words)"
		line+=" (mean $(result_value meanStartClipMS) ms),"
		line+=" ends clipped $(result_value endClipped),"
		line+=" background sent $(result_value noisePassedMS) ms;"
		line+=" A sent $delta_sent gated $delta_gated, B spurts $delta_spurts,"
		line+=" FEC $delta_fec PLC $delta_plc"
		summary+=("$line")
	done
}

run_taps() {
	note "taps: $click_count taps (5 ms at 1 kHz, 1.007 s apart) on voice activity"
	record_phase taps "$taps_wav"
	summary+=("taps: $delta_spurts of $click_count taps opened the gate; A sent $delta_sent frames")
}

run_bursts() {
	local line
	note "bursts: ten 300 ms 1 kHz bursts, voice activity gate (delay at a spurt's start)"
	record_phase bursts "$bursts_wav"
	to_raw "$probe_wav" "$work_dir/bursts-probe.f32"
	analyze latency "$work_dir/bursts-probe.f32" --min-quiet 0.5
	line="bursts: spurt-start delay p50 $(result_value p50) ms, p95 $(result_value p95) ms"
	line+=" ($(result_value heard)/$(result_value sent) heard), B spurts $delta_spurts"
	summary+=("$line")
}

run_clicks() {
	local line
	note "clicks: $click_count clicks (5 ms at 1 kHz, 1 s apart) with A's gate held open"
	expect_ok a voice-gate open
	# Let the open gate start a spurt and the jitter buffer settle before the first click.
	sleep 1
	record_phase clicks "$clicks_wav"
	to_raw "$probe_wav" "$work_dir/clicks-probe.f32"
	analyze latency "$work_dir/clicks-probe.f32"
	line="clicks: mouth-to-ear p50 $(result_value p50) ms, p95 $(result_value p95) ms"
	line+=" ($(result_value heard)/$(result_value sent) heard), B late $delta_late,"
	line+=" FEC $delta_fec PLC $delta_plc, depth $(json_number "$b_stats" depth)"
	summary+=("$line")
	set_vad_gate
}

tone_pass=skipped
phase tone && run_tone
if phase speech; then
	if [[ "$speech_ok" == true ]]; then
		run_speech
	else
		summary+=("speech: skipped (no espeak-ng)")
	fi
fi
phase taps && run_taps
phase bursts && run_bursts
phase clicks && run_clicks

[[ "$encrypted" != 1 ]] || e2ee_summary
expect_ok a voice-leave
expect_ok b voice-leave
stop_client a
stop_client b

note "summary"
for line in "${summary[@]}"; do
	echo "    $line"
done
[[ "$tone_pass" != FAIL ]] || fail "voice-check rejected the tone B played"
note "done"
