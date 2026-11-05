#!/usr/bin/env bash
set -euo pipefail

# Live end-to-end proof: builds the server, starts it against the PostgreSQL database named by
# HAYCHAT_DATABASE_*, waits until it reports readiness, runs the live client tests against it
# on 127.0.0.1:12345, and stops the server again.
#
# It runs inside the dev image (`./dev.sh live`, `./dev.sh ci`) or the Forgejo CI job
# container, both of which provide odin on PATH and a reachable database. The server's logs,
# storage, and identity key live in a throwaway directory, so every run starts from scratch.
#
# Usage: dev/live-proof.sh [--all | test_name...]
#   (no arguments)  the startup auth proof
#   --all           also the two-client room chat proof (see README "Known Limitations")
#   test_name...    the given client test procedures, e.g. client.testFoo

repo_dir=$(cd -- "$(dirname -- "$0")/.." >/dev/null 2>&1 && pwd)
ready_timeout_secs=${HAYCHAT_SERVER_READY_TIMEOUT_SECS:-60}

STARTUP_AUTH_TEST=client.testClientServerTransportCanEstablishLiveStartupAuthOverENet
ROOM_CHAT_TEST=client.testClientServerTransportCanSendLiveRoomChatBetweenTwoAuthenticatedClients

tests=("$STARTUP_AUTH_TEST")
if [[ $# -gt 0 ]]; then
	if [[ "$1" == "--all" ]]; then
		tests=("$STARTUP_AUTH_TEST" "$ROOM_CHAT_TEST")
	else
		tests=("$@")
	fi
fi

runtime_dir=$(mktemp -d -t haychat-live.XXXXXX)
server_bin="$runtime_dir/server"
server_log="$runtime_dir/server.log"
server_pid=""

export HAYCHAT_LOG_DIR="$runtime_dir/logs"
export HAYCHAT_FILE_STORAGE_PATH="$runtime_dir/storage"
export HAYCHAT_SERVER_IDENTITY_FILE="$runtime_dir/storage/server_identity.json"

stop_server() {
	if [[ -z "$server_pid" ]] || ! kill -0 "$server_pid" 2>/dev/null; then
		return 0
	fi

	# SIGINT lets the server shut its worker processes down cleanly.
	kill -INT "$server_pid" 2>/dev/null || true
	for _ in $(seq 1 50); do
		kill -0 "$server_pid" 2>/dev/null || return 0
		sleep 0.1
	done
	echo "Server did not stop after SIGINT; killing it" >&2
	kill -KILL "$server_pid" 2>/dev/null || true
}

print_server_log() {
	echo "---- server log ($server_log) ----" >&2
	cat "$server_log" >&2 || true
	echo "---- end server log ----" >&2
}

on_exit() {
	local status=$?
	stop_server
	if [[ $status -ne 0 ]]; then
		print_server_log
	fi
	rm -rf -- "$runtime_dir"
	exit "$status"
}
trap on_exit EXIT

wait_for_server_ready() {
	local deadline=$((SECONDS + ready_timeout_secs))
	while ((SECONDS < deadline)); do
		if ! kill -0 "$server_pid" 2>/dev/null; then
			echo "Server exited before reporting readiness" >&2
			return 1
		fi
		if grep -Fq "=== Server Running ===" "$server_log"; then
			return 0
		fi
		if grep -Fq "[Startup]" "$server_log"; then
			echo "Server failed during startup" >&2
			return 1
		fi
		sleep 0.1
	done
	echo "Timed out waiting for server readiness after ${ready_timeout_secs}s" >&2
	return 1
}

# The server's web admin needs io_uring, which seccomp, SELinux, or the io_uring_disabled
# sysctl can each block. Report all three so an nbio acquire failure is easy to place.
report_sandbox() {
	local seccomp selinux io_uring_disabled
	seccomp=$(awk '/^Seccomp:/ { print ($2 == 0 ? "off" : "filtered") }' /proc/self/status)
	selinux=$(tr -d '\0' </proc/self/attr/current 2>/dev/null || echo "n/a")
	io_uring_disabled=$(cat /proc/sys/kernel/io_uring_disabled 2>/dev/null || echo "n/a")
	echo "==> [live] sandbox: seccomp=${seccomp:-n/a} selinux=${selinux:-n/a}" \
		"io_uring_disabled=${io_uring_disabled}"
}

cd "$repo_dir"
report_sandbox

echo "==> [live] building server"
odin build server -out:"$server_bin"

database_target="${HAYCHAT_DATABASE_USER:-haychat}@${HAYCHAT_DATABASE_URL:-localhost}"
database_target+=":${HAYCHAT_DATABASE_PORT:-5432}/${HAYCHAT_DATABASE_NAME:-haychat}"
echo "==> [live] starting server against $database_target"
"$server_bin" >"$server_log" 2>&1 &
server_pid=$!
wait_for_server_ready
echo "==> [live] server is ready"

test_names=$(IFS=,; echo "${tests[*]}")
echo "==> [live] running ${test_names}"
HAYCHAT_LIVE_STARTUP_AUTH=1 odin test client \
	-define:ODIN_TEST_FANCY=false \
	-define:ODIN_TEST_NAMES="$test_names"

echo "==> [live] passed"
