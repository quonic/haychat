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
# Usage: dev/live-proof.sh [--all | --harness | --admin | --access | --e2ee | --voice | --ui |
#                          --sql | test_name...]
#   (no arguments)  the startup auth proof
#   --all           also the two-client room chat, direct message and voice proofs, the headless
#                   harness smoke test, the admin proof, the room access proof, the encryption
#                   key proof, the two-process
#                   voice proof, the GUI automation smoke test, the server SQL proofs, and the
#                   startup failure exit check (what CI and `./dev.sh ci` run)
#   --harness       only the headless harness smoke test (dev/harness-smoke.sh)
#   --admin         only the admin proof between two headless clients (dev/admin-proof.sh):
#                   a role change pushed live, a locked rename that survives a reconnect, a
#                   kick, a ban that refuses the next sign-in and its unban, and a room made
#                   text-only that ends its voice and refuses joins
#   --access        only the room access proof between three headless clients
#                   (dev/room-access-proof.sh): Admin invite, Member invite with From join and
#                   Full history, leaving, removing, and a room the admin creates without
#                   joining it and still manages
#   --e2ee          only the encryption key proof between headless clients
#                   (dev/e2ee-proof.sh): bundles published and pinned on first use, matching
#                   safety numbers, a verified pin that survives a restart, and a key swapped
#                   in the database that shows as a key change until it is trusted
#   --voice         only the voice proof between two headless client processes
#                   (dev/voice-proof.sh): a tone through the server into a file sink, checked
#                   with dev/tools/voice-check, then the same through SDL's disk audio driver,
#                   through injected loss, and one voice session per user (two profiles with
#                   one identity key and different device IDs: the second join takes over)
#   --ui            only the GUI automation smoke test (dev/ui-smoke.sh): the real window on
#                   SDL's offscreen video driver, driven by --ui-script; screenshots go to
#                   HAYCHAT_UI_SCREENSHOT_DIR when it is set
#   --sql           only the server proofs: database-backed server tests that run the
#                   user identity, direct message, and default room statements against this
#                   database, and the check that a failed startup exits with status 1
#   test_name...    the given client test procedures, e.g. client.testFoo

repo_dir=$(cd -- "$(dirname -- "$0")/.." >/dev/null 2>&1 && pwd)
ready_timeout_secs=${HAYCHAT_SERVER_READY_TIMEOUT_SECS:-60}

STARTUP_AUTH_TEST=client.testClientServerTransportCanEstablishLiveStartupAuthOverENet
ROOM_CHAT_TEST=client.testClientServerTransportCanSendLiveRoomChatBetweenTwoAuthenticatedClients
DIRECT_MESSAGE_TEST=client.testClientServerTransportCanExchangeLiveDirectMessagesBetweenTwoClients
VOICE_TEST=client.testClientVoiceLiveToneReachesSecondClientThroughServer
SQL_TESTS=server.testDirectMessageStatementsAgainstPostgreSQL
SQL_TESTS+=,server.testDefaultRoomStatementAgainstPostgreSQL
SQL_TESTS+=,server.testUserIdentityStatementAgainstPostgreSQL
SQL_TESTS+=,server.testMigrationsCreateFreshSchemaAgainstPostgreSQL
SQL_TESTS+=,server.testMigrationsAdoptRC1SchemaAgainstPostgreSQL
SQL_TESTS+=,server.testMigrationsAdoptProtocol7RoomsAgainstPostgreSQL
SQL_TESTS+=,server.testMigrationsRefuseNewerSchemaAgainstPostgreSQL
SQL_TESTS+=,server.testMigrationsRefuseUnrecognisedSchemaAgainstPostgreSQL
SQL_TESTS+=,server.testMigrationsRollBackFailedMigrationAgainstPostgreSQL
SQL_TESTS+=,server.testMigrationsApplyNewMigrationOnceAgainstPostgreSQL
SQL_TESTS+=,server.testMigrationsRefuseInconsistentVersionsAgainstPostgreSQL
SQL_TESTS+=,server.testReadMarkersMigrationOnFreshSchemaAgainstPostgreSQL
SQL_TESTS+=,server.testReadMarkersMigrationBackfillsRC1AgainstPostgreSQL
SQL_TESTS+=,server.testReadMarkersMigrationUpgradesVersion1AgainstPostgreSQL
SQL_TESTS+=,server.testRoomUnreadRulesAgainstPostgreSQL
SQL_TESTS+=,server.testMarkRoomReadMovesForwardClampsAndChecksMembershipAgainstPostgreSQL
SQL_TESTS+=,server.testDirectUnreadAndMarkReadAgainstPostgreSQL
SQL_TESTS+=,server.testAdminIdentityLockAndBanAgainstPostgreSQL
SQL_TESTS+=,server.testAdminActionStatementsAgainstPostgreSQL
SQL_TESTS+=,server.testRoomTypeStatementsAgainstPostgreSQL
SQL_TESTS+=,server.testAdminMigrationUpgradesVersion2AgainstPostgreSQL
SQL_TESTS+=,server.testRoomAccessModeRulesAgainstPostgreSQL
SQL_TESTS+=,server.testRoomAccessFromJoinHistoryAgainstPostgreSQL
SQL_TESTS+=,server.testRoomAccessMigrationUpgradesVersion3AgainstPostgreSQL
SQL_TESTS+=,server.testUserEncryptionKeyStatementsAgainstPostgreSQL
SQL_TESTS+=,server.testUserEncryptionKeysMigrationUpgradesVersion4AgainstPostgreSQL

tests=("$STARTUP_AUTH_TEST")
run_harness=false
run_admin=false
run_access=false
run_e2ee=false
run_voice=false
run_ui=false
run_sql=false
run_startup_failure=false
if [[ $# -gt 0 ]]; then
	case "$1" in
		--all)
			tests=("$STARTUP_AUTH_TEST" "$ROOM_CHAT_TEST" "$DIRECT_MESSAGE_TEST" "$VOICE_TEST")
			run_harness=true
			run_admin=true
			run_access=true
			run_e2ee=true
			run_voice=true
			run_ui=true
			run_sql=true
			run_startup_failure=true
			;;
		--harness)
			tests=()
			run_harness=true
			;;
		--admin)
			tests=()
			run_admin=true
			;;
		--access)
			tests=()
			run_access=true
			;;
		--e2ee)
			tests=()
			run_e2ee=true
			;;
		--voice)
			tests=()
			run_voice=true
			;;
		--ui)
			tests=()
			run_ui=true
			;;
		--sql)
			tests=()
			run_sql=true
			run_startup_failure=true
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
		if grep -Fq "=== Server Running ===" "$server_log"; then
			return 0
		fi
		# Checked before the exit test: a failed start prints [Startup] and then exits with
		# status 1, and the log line says more than the exit does.
		if grep -Fq "[Startup]" "$server_log"; then
			echo "Server failed during startup" >&2
			return 1
		fi
		if ! kill -0 "$server_pid" 2>/dev/null; then
			echo "Server exited before reporting readiness" >&2
			return 1
		fi
		sleep 0.1
	done
	echo "Timed out waiting for server readiness after ${ready_timeout_secs}s" >&2
	return 1
}

cd "$repo_dir"

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
	# The voice proof needs libopus; as in check.sh, a missing one fails instead of skipping.
	HAYCHAT_LIVE_STARTUP_AUTH=1 HAYCHAT_REQUIRE_OPUS=${HAYCHAT_REQUIRE_OPUS:-1} odin test client \
		-define:ODIN_TEST_FANCY=false \
		-define:ODIN_TEST_NAMES="$test_names"
fi

if [[ "$run_harness" == true ]]; then
	echo "==> [live] running dev/harness-smoke.sh"
	dev/harness-smoke.sh 127.0.0.1:12345
fi

if [[ "$run_admin" == true ]]; then
	echo "==> [live] running dev/admin-proof.sh"
	HAYCHAT_REQUIRE_OPUS=${HAYCHAT_REQUIRE_OPUS:-1} dev/admin-proof.sh 127.0.0.1:12345
fi

if [[ "$run_voice" == true ]]; then
	echo "==> [live] running dev/voice-proof.sh"
	dev/voice-proof.sh 127.0.0.1:12345
fi

if [[ "$run_ui" == true ]]; then
	echo "==> [live] running dev/ui-smoke.sh"
	dev/ui-smoke.sh 127.0.0.1:12345
fi

# After the GUI proof, so the Admin section it scrolls through lists only the rooms the earlier
# proofs made.
if [[ "$run_access" == true ]]; then
	echo "==> [live] running dev/room-access-proof.sh"
	dev/room-access-proof.sh 127.0.0.1:12345
fi

# After the GUI proof too: its key swap leaves one account without an identity key.
if [[ "$run_e2ee" == true ]]; then
	echo "==> [live] running dev/e2ee-proof.sh"
	dev/e2ee-proof.sh 127.0.0.1:12345
fi

# Runs last so its accounts (which it deletes again) never meet the client proofs. It shares
# the running server's database, which is safe: its migration run finds the database the server
# just migrated and changes nothing, it touches only accounts it created itself, and the
# migration tests work in schemas of their own that they drop again.
if [[ "$run_sql" == true ]]; then
	echo "==> [live] running server SQL proof ${SQL_TESTS}"
	HAYCHAT_DATABASE_SQL_TEST=1 odin test server \
		-define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true \
		-define:ODIN_TEST_FANCY=false \
		-define:ODIN_TEST_THREADS=1 \
		-define:ODIN_TEST_NAMES="$SQL_TESTS" \
		-out:"$runtime_dir/server-sql-test"
fi

# A server that cannot start must exit non-zero (systemd Restart=on-failure and scripts depend
# on it) after printing a [Startup] line (what wait_for_server_ready and ./dev.sh look for).
# Nothing listens on port 1, so the database connect fails before any listener starts and this
# second server never meets the running one.
if [[ "$run_startup_failure" == true ]]; then
	echo "==> [live] checking that a failed startup exits with status 1"
	failed_log="$runtime_dir/failed-startup.log"
	failed_status=0
	HAYCHAT_DATABASE_PORT=1 HAYCHAT_LOG_DIR="$runtime_dir/failed-startup-logs" \
		timeout 60 "$server_bin" >"$failed_log" 2>&1 || failed_status=$?
	if [[ $failed_status -ne 1 ]] || ! grep -aFq "[Startup]" "$failed_log"; then
		echo "Expected a failed startup to print [Startup] and exit 1, got $failed_status" >&2
		cat "$failed_log" >&2 || true
		exit 1
	fi
fi

echo "==> [live] passed"
