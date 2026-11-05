# shellcheck shell=bash
# The globals below are set by the sourcing script, and client_pid/client_fd are associative
# arrays declared there, which shellcheck cannot see from this file; last_result is read there.
# shellcheck disable=SC2154,SC2004,SC2034

# Helpers shared by dev/harness-smoke.sh and dev/ui-smoke.sh for driving headless clients
# (docs/testing-harness.md) from bash. Source it after setting:
#   work_dir              scratch directory; client NAME writes NAME.out and NAME.err there
#   client_bin            the built client binary
#   server_address        HOST:PORT the clients connect to
#   command_timeout_secs  how long each wait may take
#   client_pid, client_fd associative arrays (declare -A), filled by start_client
# and optionally smoke_label (the tag in FAIL lines) and watched_pid, another process whose
# exit ends every wait early (ui-smoke.sh watches its GUI client this way).

# watched_process_alive: false, with a message, once $watched_pid has exited.
watched_process_alive() {
	if [[ -n "${watched_pid:-}" ]] && ! kill -0 "$watched_pid" 2>/dev/null; then
		echo "process $watched_pid exited while waiting" >&2
		return 1
	fi
	return 0
}

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

fail() {
	echo "==> [${smoke_label:-harness}] FAIL: $*" >&2
	exit 1
}

# start_client NAME NICKNAME [PROFILE]: starts a headless client with its own profile
# directory (profile-NAME, or profile-PROFILE to reuse another client's identity). Its stdin
# is a named pipe held open on a file descriptor, so the client keeps running between
# commands; closing it would be EOF, which the harness treats as quit.
start_client() {
	local client=$1 nickname=$2 profile=${3:-$1} fd
	mkfifo "$work_dir/$client.in"
	"$client_bin" --headless --name "$nickname" --server "$server_address" \
		--config-dir "$work_dir/profile-$profile" \
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
		watched_process_alive || return 1
		sleep 0.1
	done
	echo "client $client timed out after ${command_timeout_secs}s waiting for: $text" >&2
	return 1
}

# wait_for_match CLIENT REGEX [START_LINE]: like wait_for_line, for an extended regex.
wait_for_match() {
	local client=$1 pattern=$2 start=${3:-0} line
	local deadline=$((SECONDS + command_timeout_secs))
	while ((SECONDS < deadline)); do
		line=$(tail -n "+$((start + 1))" "$work_dir/$client.out" | grep -E -m1 -- "$pattern" |
			grep '}$' || true)
		if [[ -n "$line" ]]; then
			printf '%s\n' "$line"
			return 0
		fi
		if ! kill -0 "${client_pid[$client]}" 2>/dev/null; then
			echo "client $client exited while waiting for: $pattern" >&2
			return 1
		fi
		watched_process_alive || return 1
		sleep 0.1
	done
	echo "client $client timed out after ${command_timeout_secs}s waiting for: $pattern" >&2
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
