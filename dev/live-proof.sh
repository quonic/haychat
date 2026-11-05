#!/usr/bin/env bash
set -euo pipefail

# Live end-to-end proof: builds the server, starts it against the PostgreSQL database named by
# HAYCHAT_DATABASE_*, waits until it reports readiness, checks that the server created
# #general (room 1) on its own, loads the server/sql/auth_bootstrap.sql fixture (for its admin
# account), runs the live client tests against it on 127.0.0.1:12345, and stops the server.
#
# It runs inside the dev image (`./dev.sh live`, `./dev.sh ci`) or the Forgejo CI job
# container, both of which provide odin on PATH and a reachable database. The server's logs,
# storage, and identity key live in a throwaway directory, so every run starts from scratch.
#
# Usage: dev/live-proof.sh [--all | --harness | --sql | test_name...]
#   (no arguments)  the startup auth proof
#   --all           also the two-client room chat proof, the headless harness smoke test, and
#                   the server SQL proof (what CI and `./dev.sh ci` run)
#   --harness       only the headless harness smoke test (dev/harness-smoke.sh)
#   --sql           only the server SQL proof: database-backed server tests that run the
#                   direct message and default room statements against this database
#   test_name...    the given client test procedures, e.g. client.testFoo

repo_dir=$(cd -- "$(dirname -- "$0")/.." >/dev/null 2>&1 && pwd)
ready_timeout_secs=${HAYCHAT_SERVER_READY_TIMEOUT_SECS:-60}

STARTUP_AUTH_TEST=client.testClientServerTransportCanEstablishLiveStartupAuthOverENet
ROOM_CHAT_TEST=client.testClientServerTransportCanSendLiveRoomChatBetweenTwoAuthenticatedClients
SQL_TESTS=server.testDirectMessageStatementsAgainstPostgreSQL
SQL_TESTS+=,server.testDefaultRoomStatementAgainstPostgreSQL

tests=("$STARTUP_AUTH_TEST")
run_harness=false
run_sql=false
if [[ $# -gt 0 ]]; then
	case "$1" in
		--all)
			tests=("$STARTUP_AUTH_TEST" "$ROOM_CHAT_TEST")
			run_harness=true
			run_sql=true
			;;
		--harness)
			tests=()
			run_harness=true
			;;
		--sql)
			tests=()
			run_sql=true
			;;
		*) tests=("$@") ;;
	esac
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

live_psql() {
	PGPASSWORD="${HAYCHAT_DATABASE_PASS:-haychat}" psql -q -X -v ON_ERROR_STOP=1 \
		-h "${HAYCHAT_DATABASE_URL:-localhost}" -p "${HAYCHAT_DATABASE_PORT:-5432}" \
		-U "${HAYCHAT_DATABASE_USER:-haychat}" -d "${HAYCHAT_DATABASE_NAME:-haychat}" "$@"
}

# The server creates #general on an empty database before it reports readiness, and the chat
# proofs post to it, so check it is there before anything else touches the rooms.
rooms=$(live_psql -tA -c "SELECT string_agg(id || ':' || name, ',') FROM rooms")
if [[ "$rooms" != "1:general" ]]; then
	echo "Expected the server to create #general as room 1, found rooms: ${rooms:-none}" >&2
	exit 1
fi
echo "==> [live] server created #general"

# The room no longer depends on the fixture; it adds the admin and haypeer accounts. It loads
# before any live client connects, and the fixture's room upsert keeps #general as room 1.
echo "==> [live] loading server/sql/auth_bootstrap.sql"
live_psql -f server/sql/auth_bootstrap.sql >/dev/null

if [[ ${#tests[@]} -gt 0 ]]; then
	test_names=$(IFS=,; echo "${tests[*]}")
	echo "==> [live] running ${test_names}"
	HAYCHAT_LIVE_STARTUP_AUTH=1 odin test client \
		-define:ODIN_TEST_FANCY=false \
		-define:ODIN_TEST_NAMES="$test_names"
fi

if [[ "$run_harness" == true ]]; then
	echo "==> [live] running dev/harness-smoke.sh"
	dev/harness-smoke.sh 127.0.0.1:12345
fi

# Runs last so its accounts (which it deletes again) never meet the client proofs. It shares
# the running server's database, which is safe: its schema check finds the schema the server
# just created, and it touches only accounts it created itself.
if [[ "$run_sql" == true ]]; then
	echo "==> [live] running server SQL proof ${SQL_TESTS}"
	HAYCHAT_DATABASE_SQL_TEST=1 odin test server \
		-define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true \
		-define:ODIN_TEST_FANCY=false \
		-define:ODIN_TEST_THREADS=1 \
		-define:ODIN_TEST_NAMES="$SQL_TESTS" \
		-out:"$runtime_dir/server-sql-test"
fi

echo "==> [live] passed"
