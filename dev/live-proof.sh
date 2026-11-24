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
# Usage: dev/live-proof.sh [--all | --harness | --admin | --access | --e2ee | --registration |
#                          --attachments | --edits | --voice | --ui | --sql | test_name...]
#   (no arguments)  the startup auth proof
#   --all           also the two-client room chat, direct message and voice proofs, the headless
#                   harness smoke test, the admin proof, the room access proof, the encryption
#                   key proof, the registration proof, the message edit proof, the two-process
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
#   --registration  only the registration proof (dev/registration-proof.sh): Invite only,
#                   invite codes (an inviter's, expired, revoked and used up), an invite link,
#                   Invite + approval (approved live and declined), a room code that makes a
#                   restricted account, and the admin key on a fresh database
#   --attachments   only the attachment proof (dev/attachment-proof.sh): a 25 MiB upload and
#                   download between client processes while both measure their chat echo
#                   latency against a baseline, a resume after a reconnect, a cancel, files on
#                   a room message, an encrypted direct message and an encrypted room, an
#                   admin removal mid-download and the deploy/sql helpers; then, on a second
#                   server with small limits, size and quota refusals, a non-member, a From
#                   join newcomer, AttachFiles taken away, an uploader killed mid-file, and a
#                   deleted room's files gone after the startup sweep
#   --edits         only the message edit proof (dev/message-edit-proof.sh, protocol 30): room
#                   and direct message edits and deletes between three headless clients, the
#                   edit history, refusals of someone else's message and of a forged edit, an
#                   admin's delete shown as removed by the server, a From join newcomer hearing
#                   nothing of older messages, and a deleted message's file refused
#   --voice         only the voice proof between two headless client processes
#                   (dev/voice-proof.sh): a tone through the server into a file sink, checked
#                   with dev/tools/voice-check, then the same through SDL's disk audio driver,
#                   through injected loss, and one voice session per user (two profiles with
#                   one identity key and different device IDs: the second join takes over),
#                   then encrypted voice in an encrypted room (three clients, a removal and
#                   timed key rotations)
#   --ui            only the GUI automation smoke test (dev/ui-smoke.sh): the real window on
#                   SDL's offscreen video driver, driven by --ui-script; screenshots go to
#                   HAYCHAT_UI_SCREENSHOT_DIR when it is set
#   --sql           only the server proofs: database-backed server tests that run the
#                   user identity, direct message, and default room statements against this
#                   database, the same tests with the first failing on purpose (only it may
#                   fail, and the run must exit), and the check that a failed startup exits
#                   with status 1
#   test_name...    the given client test procedures, e.g. client.testFoo
#
# Every step runs under `timeout` (run_step below), so a hung client, proof or test binary fails
# the run within minutes instead of using up CI's job limit. The limits are generous (several
# times a normal run, compile included): client tests 20 minutes, the harness, admin, access,
# edit and registration proofs 10, the voice, GUI and attachment proofs 15, the encryption proof 20, the SQL proof
# 20, its failing run 2, and the failed startup check 1. HAYCHAT_LIVE_STEP_TIMEOUT_SECS replaces every limit
# (for a slow machine, or a short one while debugging). A step that times out prints "[live]
# STEP timed out after N s" and the run fails; timeout signals the step's whole process group,
# then kills it 30 seconds later if it is still there.

repo_dir=$(cd -- "$(dirname -- "$0")/.." >/dev/null 2>&1 && pwd)
ready_timeout_secs=${HAYCHAT_SERVER_READY_TIMEOUT_SECS:-60}

STARTUP_AUTH_TEST=client.testClientServerTransportCanEstablishLiveStartupAuthOverENet
ROOM_CHAT_TEST=client.testClientServerTransportCanSendLiveRoomChatBetweenTwoAuthenticatedClients
DIRECT_MESSAGE_TEST=client.testClientServerTransportCanExchangeLiveDirectMessagesBetweenTwoClients
VOICE_TEST=client.testClientVoiceLiveToneReachesSecondClientThroughServer
# The first SQL test fails on purpose in a second run (see the SQL proof below).
SQL_FAILURE_TEST=server.testAbandonedSQLTestReleasesItsConnectionAgainstPostgreSQL
SQL_TESTS=$SQL_FAILURE_TEST
SQL_TESTS+=,server.testDirectMessageStatementsAgainstPostgreSQL
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
SQL_TESTS+=,server.testEncryptedDirectMessageStatementsAgainstPostgreSQL
SQL_TESTS+=,server.testEncryptedDirectMessagesMigrationUpgradesVersion5AgainstPostgreSQL
SQL_TESTS+=,server.testRoomLogAppendRulesAgainstPostgreSQL
SQL_TESTS+=,server.testRoomLogFullRoomAgainstPostgreSQL
SQL_TESTS+=,server.testRoomLogMigrationUpgradesVersion6AgainstPostgreSQL
SQL_TESTS+=,server.testRoomSenderChainStatementsAgainstPostgreSQL
SQL_TESTS+=,server.testRoomSenderChainsMigrationUpgradesVersion7AgainstPostgreSQL
SQL_TESTS+=,server.testRoomKeyForwardStatementsAgainstPostgreSQL
SQL_TESTS+=,server.testRoomKeyForwardsMigrationUpgradesVersion8AgainstPostgreSQL
SQL_TESTS+=,server.testSignedMessagesMigrationUpgradesVersion9AgainstPostgreSQL
SQL_TESTS+=,server.testRolesMigrationUpgradesVersion10AgainstPostgreSQL
SQL_TESTS+=,server.testRoleStatementsAgainstPostgreSQL
SQL_TESTS+=,server.testRolePermissionsInOtherStatementsAgainstPostgreSQL
SQL_TESTS+=,server.testRoomPermissionsMigrationUpgradesVersion11AgainstPostgreSQL
SQL_TESTS+=,server.testRoomPermissionChecksAgainstPostgreSQL
SQL_TESTS+=,server.testEncryptedRoomPermissionsAgainstPostgreSQL
SQL_TESTS+=,server.testRoleRoomMembershipAgainstPostgreSQL
SQL_TESTS+=,server.testRegistrationMigrationUpgradesVersion12AgainstPostgreSQL
SQL_TESTS+=,server.testRegisterStatementAgainstPostgreSQL
SQL_TESTS+=,server.testIdentityRegistrationPathsAgainstPostgreSQL
SQL_TESTS+=,server.testInviteStatementsAgainstPostgreSQL
SQL_TESTS+=,server.testRegistrationRequestStatementsAgainstPostgreSQL
SQL_TESTS+=,server.testRestrictedAccountsAgainstPostgreSQL
SQL_TESTS+=,server.testRoomCodeRequestWhoseRoomChangedAgainstPostgreSQL
SQL_TESTS+=,server.testAttachmentsMigrationUpgradesVersion13AgainstPostgreSQL
SQL_TESTS+=,server.testAttachmentBeginStatementAgainstPostgreSQL
SQL_TESTS+=,server.testAttachmentUploadStepsAgainstPostgreSQL
SQL_TESTS+=,server.testAttachmentSweeperAgainstPostgreSQL
SQL_TESTS+=,server.testAttachmentsOnMessagesMigrationUpgradesVersion14AgainstPostgreSQL
SQL_TESTS+=,server.testAttachmentBindingInRoomMessagesAgainstPostgreSQL
SQL_TESTS+=,server.testAttachmentBindingInDirectMessagesAgainstPostgreSQL
SQL_TESTS+=,server.testAttachmentDownloadCheckAgainstPostgreSQL
SQL_TESTS+=,server.testAttachmentRoomDeletionSweepsItsFilesAgainstPostgreSQL
SQL_TESTS+=,server.testAttachmentRemovalAgainstPostgreSQL
SQL_TESTS+=,server.testAttachmentUsageAgainstPostgreSQL
SQL_TESTS+=,server.testAttachmentSQLRemovalFileIsDeletedByTheHourlyPassAgainstPostgreSQL
SQL_TESTS+=,server.testAttachmentRemovalsMigrationUpgradesVersion15AgainstPostgreSQL
SQL_TESTS+=,server.testAttachmentRemovalLogAgainstPostgreSQL
SQL_TESTS+=,server.testAttachmentRemovalLogListingAgainstPostgreSQL
SQL_TESTS+=,server.testMessageEditsMigrationUpgradesVersion16AgainstPostgreSQL
SQL_TESTS+=,server.testRoomMessageEditsAndDeletesAgainstPostgreSQL
SQL_TESTS+=,server.testMessageDeleteRemovesItsFilesAgainstPostgreSQL
SQL_TESTS+=,server.testDirectMessageEditsAndDeletesAgainstPostgreSQL

tests=("$STARTUP_AUTH_TEST")
run_harness=false
run_admin=false
run_access=false
run_e2ee=false
run_registration=false
run_attachments=false
run_edits=false
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
			run_registration=true
			run_attachments=true
			run_edits=true
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
		--registration)
			tests=()
			run_registration=true
			;;
		--attachments)
			tests=()
			run_attachments=true
			;;
		--edits)
			tests=()
			run_edits=true
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
# Attachments (protocol 26): the blob directory the attachment proof inspects, and a free-disk
# reserve small enough for a CI runner's temporary directory.
export HAYCHAT_ATTACHMENT_DIR="$runtime_dir/attachments"
export HAYCHAT_ATTACHMENT_MIN_FREE_BYTES=$((64 * 1024 * 1024))

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
	elif [[ "${run_attachments:-false}" == true ]]; then
		# The shutdown [Status] line's attachment pairs: the router thread's time in file
		# crypto (attachment_crypto_ms) for the bytes it sealed and opened.
		echo "==> [live] attachment counters at shutdown:"
		grep -F '[Status]' "$server_log" | tail -n 1 | tr ' ' '\n' |
			grep -E '^(storage_|attachment_)' | sed 's/^/    /' || true
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

# run_step LIMIT_SECS LABEL COMMAND...: runs COMMAND under timeout (see the top of this file).
run_step() {
	local limit=$1 label=$2 status=0
	shift 2
	limit=${HAYCHAT_LIVE_STEP_TIMEOUT_SECS:-$limit}
	timeout --kill-after=30 "$limit" "$@" || status=$?
	if [[ $status -eq 124 || $status -eq 137 ]]; then
		echo "[live] $label timed out after ${limit} s" >&2
	fi
	return "$status"
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
	run_step 1200 "client tests" env HAYCHAT_LIVE_STARTUP_AUTH=1 \
		HAYCHAT_REQUIRE_OPUS="${HAYCHAT_REQUIRE_OPUS:-1}" odin test client \
		-define:ODIN_TEST_FANCY=false \
		-define:ODIN_TEST_NAMES="$test_names"
fi

if [[ "$run_harness" == true ]]; then
	echo "==> [live] running dev/harness-smoke.sh"
	run_step 600 "dev/harness-smoke.sh" dev/harness-smoke.sh 127.0.0.1:12345
fi

if [[ "$run_admin" == true ]]; then
	echo "==> [live] running dev/admin-proof.sh"
	run_step 600 "dev/admin-proof.sh" env HAYCHAT_REQUIRE_OPUS="${HAYCHAT_REQUIRE_OPUS:-1}" \
		dev/admin-proof.sh 127.0.0.1:12345
fi

if [[ "$run_voice" == true ]]; then
	echo "==> [live] running dev/voice-proof.sh"
	run_step 900 "dev/voice-proof.sh" dev/voice-proof.sh 127.0.0.1:12345
fi

if [[ "$run_ui" == true ]]; then
	echo "==> [live] running dev/ui-smoke.sh"
	run_step 900 "dev/ui-smoke.sh" dev/ui-smoke.sh 127.0.0.1:12345
fi

# After the GUI proof, so the Admin section it scrolls through lists only the rooms the earlier
# proofs made.
if [[ "$run_access" == true ]]; then
	echo "==> [live] running dev/room-access-proof.sh"
	run_step 600 "dev/room-access-proof.sh" dev/room-access-proof.sh 127.0.0.1:12345
fi

# After the GUI proof too: its key swap leaves one account without an identity key.
if [[ "$run_e2ee" == true ]]; then
	echo "==> [live] running dev/e2ee-proof.sh"
	run_step 1200 "dev/e2ee-proof.sh" dev/e2ee-proof.sh 127.0.0.1:12345
fi

# After the GUI and encryption proofs: it switches the server's registration mode (and back, also
# when it fails), and its restricted account and requests would change what they list. It runs
# a second server, on a fresh database it creates and drops, from the same binary.
if [[ "$run_registration" == true ]]; then
	echo "==> [live] running dev/registration-proof.sh"
	run_step 600 "dev/registration-proof.sh" env HAYCHAT_SERVER_BIN="$server_bin" \
		dev/registration-proof.sh 127.0.0.1:12345
fi

# After the registration proof, which restores the Open mode the attachment clients sign up in.
# Like it, the attachment proof runs a second server from the same binary, on a fresh database
# it creates and drops (port 12347), with small limits it may restart.
if [[ "$run_attachments" == true ]]; then
	echo "==> [live] running dev/attachment-proof.sh"
	run_step 900 "dev/attachment-proof.sh" env HAYCHAT_SERVER_BIN="$server_bin" \
		dev/attachment-proof.sh 127.0.0.1:12345
fi

# After the attachment proof: its admin deletes messages and files in #general, which no later
# proof reads.
if [[ "$run_edits" == true ]]; then
	echo "==> [live] running dev/message-edit-proof.sh"
	run_step 600 "dev/message-edit-proof.sh" dev/message-edit-proof.sh 127.0.0.1:12345
fi

# Runs last so its accounts (which it deletes again) never meet the client proofs. It shares
# the running server's database, which is safe: its migration run finds the database the server
# just migrated and changes nothing, it touches only accounts it created itself, and the
# migration tests work in schemas of their own that they drop again.
if [[ "$run_sql" == true ]]; then
	echo "==> [live] running server SQL proof ${SQL_TESTS}"
	sql_test_bin="$runtime_dir/server-sql-test"
	run_step 1200 "the server SQL proof" env HAYCHAT_DATABASE_SQL_TEST=1 odin test server \
		-define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true \
		-define:ODIN_TEST_FANCY=false \
		-define:ODIN_TEST_THREADS=1 \
		-define:ODIN_TEST_NAMES="$SQL_TESTS" \
		-keep-executable \
		-out:"$sql_test_bin"

	# A failed assertion ends its test, not the run (#80): the same binary again, with its first
	# test failing while it holds the migration lock, must exit non-zero within seconds, name
	# that test as the only failure, and still pass every later test (each takes the lock). The
	# runner orders tests by name, so the failing one must sort first.
	echo "==> [live] checking that a failed SQL test fails the run and names itself"
	first_sql_test=$(tr ',' '\n' <<<"$SQL_TESTS" | LC_ALL=C sort | head -n 1)
	if [[ "$first_sql_test" != "$SQL_FAILURE_TEST" ]]; then
		echo "Expected $SQL_FAILURE_TEST to sort first, found $first_sql_test" >&2
		exit 1
	fi
	sql_failure_log="$runtime_dir/sql-failure.log"
	sql_failure_status=0
	run_step 120 "the failing SQL test check" env HAYCHAT_DATABASE_SQL_TEST=1 \
		HAYCHAT_DATABASE_SQL_TEST_FAIL=1 "$sql_test_bin" >"$sql_failure_log" 2>&1 ||
		sql_failure_status=$?
	if [[ $sql_failure_status -eq 0 || $sql_failure_status -eq 124 ||
		$sql_failure_status -eq 137 ]] ||
		! grep -Fq " 1 test failed." "$sql_failure_log" ||
		! grep -Eq "^ - ${SQL_FAILURE_TEST}[[:space:]]" "$sql_failure_log" ||
		! grep -Fq "failing on purpose" "$sql_failure_log" ||
		grep -Fq "left undone" "$sql_failure_log"; then
		echo "Expected only $SQL_FAILURE_TEST to fail, and the run to exit (status" \
			"$sql_failure_status):" >&2
		cat "$sql_failure_log" >&2
		exit 1
	fi
	echo "==> [live] the failed SQL test ended only itself (status $sql_failure_status):" \
		"$(grep -F "Finished " "$sql_failure_log")"

	# The operator helpers of deploy/sql (protocol 25, #43): create-invite.sql prints a grouped
	# Crockford base32 code whose sha256 is the only thing stored, and set-registration-mode.sql
	# switches the mode (and back, so nothing after this sees a closed server).
	echo "==> [live] checking deploy/sql/create-invite.sql and set-registration-mode.sql"
	invite_code=$(live_psql -v uses=2 -v days=1 -v note='live proof' \
		-f deploy/sql/create-invite.sql | tail -n 1)
	symbol='[0-9A-HJKMNP-TV-Z]'
	if [[ ! "$invite_code" =~ ^($symbol{4}-){7}$symbol{4}$ ]]; then
		echo "Expected a grouped Crockford base32 code, got '$invite_code'" >&2
		exit 1
	fi
	alphabet=0123456789ABCDEFGHJKMNPQRSTVWXYZ
	bits=""
	for ((index = 0; index < ${#invite_code}; index++)); do
		char=${invite_code:index:1}
		[[ "$char" == "-" ]] && continue
		prefix=${alphabet%%"$char"*}
		value=${#prefix}
		for ((bit = 4; bit >= 0; bit--)); do
			bits+=$(((value >> bit) & 1))
		done
	done
	code_hex=""
	for ((index = 0; index < 160; index += 8)); do
		code_hex+=$(printf '%02x' "$((2#${bits:index:8}))")
	done
	code_hash=$(printf "$(sed 's/../\\x&/g' <<<"$code_hex")" | sha256sum | cut -d' ' -f1)
	stored=$(live_psql -tA -c "SELECT max_uses || ':' || note || ':' || (expires_at IS NOT NULL) \
		FROM invites WHERE code_hash = decode('$code_hash', 'hex')")
	if [[ "$stored" != "2:live proof:true" ]]; then
		echo "Expected the code's sha256 stored with its limits, got '$stored'" >&2
		exit 1
	fi
	live_psql -v mode=invite -f deploy/sql/set-registration-mode.sql >/dev/null
	mode=$(live_psql -tA -c "SELECT registration_mode FROM server_settings")
	live_psql -v mode=open -f deploy/sql/set-registration-mode.sql >/dev/null
	if [[ "$mode" != "2" ]] || live_psql -v mode=closed -f deploy/sql/set-registration-mode.sql \
		>/dev/null 2>&1; then
		echo "Expected set-registration-mode.sql to set invite and refuse 'closed' (got $mode)" >&2
		exit 1
	fi
	echo "==> [live] the deploy SQL helpers work (the code is stored only as its sha256)"
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
		timeout --kill-after=10 60 "$server_bin" >"$failed_log" 2>&1 || failed_status=$?
	if [[ $failed_status -ne 1 ]] || ! grep -aFq "[Startup]" "$failed_log"; then
		echo "Expected a failed startup to print [Startup] and exit 1, got $failed_status" >&2
		cat "$failed_log" >&2 || true
		exit 1
	fi
fi

echo "==> [live] passed"
