#!/usr/bin/env bash
set -euo pipefail

# Smoke test for the headless client harness (docs/testing-harness.md). It builds the client,
# starts headless clients against a running server, and drives them over named pipes the way
# an agent would.
#
#   1. single client: connect, `status`, `wait room_list`, `rooms`, then `reconnect` and wait
#      for the worker to connect again
#   2. two clients:   A sends to room 1 and B must print the matching room_chat event
#
# dev/live-proof.sh --harness runs it against its throwaway server. It needs bash and
# coreutils only; JSON lines are matched as text because the harness prints compact JSON
# with a fixed key order.
#
# Usage: dev/harness-smoke.sh [HOST:PORT]   (default 127.0.0.1:12345)

repo_dir=$(cd -- "$(dirname -- "$0")/.." >/dev/null 2>&1 && pwd)
server_address=${1:-127.0.0.1:12345}
room_id=1
command_timeout_secs=10

work_dir=$(mktemp -d -t haychat-harness.XXXXXX)
client_bin="$work_dir/haychat-client"
run_tag=$(date +%s%N)

declare -A client_pid=()
declare -A client_fd=()

print_client_output() {
	local client
	for client in "${!client_pid[@]}"; do
		echo "---- client $client stdout ----" >&2
		cat "$work_dir/$client.out" >&2 || true
		echo "---- client $client stderr ----" >&2
		cat "$work_dir/$client.err" >&2 || true
	done
	echo "---- end client output ----" >&2
}

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

fail() {
	echo "==> [harness] FAIL: $*" >&2
	exit 1
}

# start_client NAME NICKNAME: starts a headless client with its own profile directory. Its
# stdin is a named pipe held open on a file descriptor, so the client keeps running between
# commands; closing it would be EOF, which the harness treats as quit.
start_client() {
	local client=$1 nickname=$2 fd
	mkfifo "$work_dir/$client.in"
	"$client_bin" --headless --name "$nickname" --server "$server_address" \
		--config-dir "$work_dir/profile-$client" \
		--connect-timeout "$((command_timeout_secs * 1000))" \
		<"$work_dir/$client.in" >"$work_dir/$client.out" 2>"$work_dir/$client.err" &
	client_pid[$client]=$!
	exec {fd}>"$work_dir/$client.in"
	client_fd[$client]=$fd
}

# wait_for_line CLIENT FIXED_TEXT [START_LINE]: waits until a complete stdout line after
# START_LINE contains FIXED_TEXT and prints it.
wait_for_line() {
	local client=$1 text=$2 start=${3:-0} line
	local deadline=$((SECONDS + command_timeout_secs))
	while ((SECONDS < deadline)); do
		line=$(tail -n "+$((start + 1))" "$work_dir/$client.out" | grep -F -- "$text" |
			grep -m1 '}$' || true)
		if [[ -n "$line" ]]; then
			printf '%s\n' "$line"
			return 0
		fi
		if ! kill -0 "${client_pid[$client]}" 2>/dev/null; then
			echo "client $client exited while waiting for: $text" >&2
			return 1
		fi
		sleep 0.1
	done
	echo "client $client timed out after ${command_timeout_secs}s waiting for: $text" >&2
	return 1
}

# client_command CLIENT COMMAND...: sends one command line and prints its result line. Results
# are the only lines that start with {"ok": and commands run in order, so the first result
# after the send belongs to this command.
client_command() {
	local client=$1
	shift
	local start
	start=$(wc -l <"$work_dir/$client.out")
	printf '%s\n' "$*" >&"${client_fd[$client]}"
	wait_for_line "$client" '{"ok":' "$start"
}

# expect_ok CLIENT COMMAND...: runs a command and fails unless it reports ok.
expect_ok() {
	local client=$1 result
	shift
	result=$(client_command "$client" "$@") || fail "client $client: no result for \`$*\`"
	echo "    $client> $*"
	echo "    $client< $result"
	[[ "$result" == '{"ok":true,'* ]] || fail "client $client: \`$*\` failed: $result"
	last_result=$result
}

# expect_connected CLIENT: waits for the first `connected` line. A retried attempt prints
# `connecting` and `connect_failed` lines before it; a failure that stops retrying (or the
# --connect-timeout) ends the client with exit code 2 after its last `connect_failed` line.
expect_connected() {
	local client=$1 line failure
	if ! line=$(wait_for_line "$client" '{"event":"connected",' 0); then
		failure=$(grep -F '{"event":"connect_failed",' "$work_dir/$client.out" | tail -n 1 || true)
		fail "client $client could not connect: ${failure:-no connect_failed line}"
	fi
	echo "    $client< $line"
}

stop_client() {
	local client=$1 status=0 fd=${client_fd[$1]}
	expect_ok "$client" quit
	exec {fd}>&-
	wait "${client_pid[$client]}" || status=$?
	unset "client_pid[$client]"
	[[ $status -eq 0 ]] || fail "client $client exited with status $status after quit"
}

cd "$repo_dir"
echo "==> [harness] building the client"
odin build client -out:"$client_bin"

echo "==> [harness] single client: connect, status, rooms"
start_client a "harness-a-$run_tag"
expect_connected a
expect_ok a status
[[ "$last_result" == *'"connected":true'* ]] || fail "client a status is not connected"
expect_ok a wait room_list 5000
expect_ok a rooms
[[ "$last_result" == *'"loaded":true'* ]] || fail "client a rooms are not loaded"
# The first `connected` is still counted for `wait`; take it so the next wait needs a new one.
expect_ok a wait connected 0
expect_ok a reconnect
expect_ok a wait connected 8000
expect_ok a status
[[ "$last_result" == *'"connected":true'* ]] || fail "client a is not connected after reconnect"
echo "==> [harness] single client passed"

# Needs every user to be a member of room 1. On main before the open-rooms change (work
# package A), new users join no rooms, so the server rejects A's message and B sees nothing.
echo "==> [harness] two clients: A sends to room $room_id, B receives it"
start_client b "harness-b-$run_tag"
expect_connected b
expect_ok b wait room_list 5000
message="harness smoke $run_tag"
expect_ok a send "$room_id" "$message"
if ! received=$(client_command b wait room_chat 5000) ||
	[[ "$received" != '{"ok":true,'* ]]; then
	fail "[two-client] client b did not receive a room_chat event within 5 s" \
		"(${received:-no result}); both clients must be members of room $room_id" \
		"(rooms are open, so check that the #general fixture was loaded before they connected)"
fi
chat_line=$(wait_for_line b "\"content\":\"$message\"" 0) ||
	fail "[two-client] client b received a room_chat event without the sent text"
echo "    b< $chat_line"
echo "==> [harness] two clients passed"

stop_client a
stop_client b
echo "==> [harness] passed"
