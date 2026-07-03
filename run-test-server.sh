#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "$0")" >/dev/null 2>&1 && pwd)
bootstrap_sql_path="$script_dir/server/sql/auth_bootstrap.sql"
runtime_dir="${HAYCHAT_RUNTIME_DIR:-$script_dir/.haychat-test-server}"
server_pid_path="$runtime_dir/server.pid"
server_log_path="$runtime_dir/server.log"
server_bin_path="$runtime_dir/server.bin"
server_ready_timeout_secs="${HAYCHAT_SERVER_READY_TIMEOUT_SECS:-15}"

export HAYCHAT_LOG_DIR=${HAYCHAT_LOG_DIR:-$script_dir/logs}
export HAYCHAT_FILE_STORAGE_PATH=${HAYCHAT_FILE_STORAGE_PATH:-$script_dir/storage}
export HAYCHAT_DATABASE_URL=${HAYCHAT_DATABASE_URL:-localhost}
export HAYCHAT_DATABASE_PORT=${HAYCHAT_DATABASE_PORT:-5432}
export HAYCHAT_DATABASE_USER=${HAYCHAT_DATABASE_USER:-haychat}
export HAYCHAT_DATABASE_PASS=${HAYCHAT_DATABASE_PASS:-haychat}
export HAYCHAT_DATABASE_NAME=${HAYCHAT_DATABASE_NAME:-haychat}

mkdir -p "$runtime_dir"

ensure_runtime_dir() {
	mkdir -p "$runtime_dir"
}

server_is_running() {
	if [[ ! -f "$server_pid_path" ]]; then
		return 1
	fi

	local pid
	pid=$(<"$server_pid_path")
	if [[ -z "$pid" ]]; then
		return 1
	fi

	if ! kill -0 "$pid" >/dev/null 2>&1; then
		return 1
	fi

	if [[ -f "$server_bin_path" && -e "/proc/$pid/exe" ]]; then
		local expected_bin_path actual_bin_path
		expected_bin_path=$(readlink -f -- "$server_bin_path" 2>/dev/null || printf '%s\n' "$server_bin_path")
		actual_bin_path=$(readlink -f -- "/proc/$pid/exe" 2>/dev/null || true)
		if [[ -z "$actual_bin_path" || "$actual_bin_path" != "$expected_bin_path" ]]; then
			return 1
		fi
	fi

	return 0
}

clear_server_state() {
	rm -f "$server_pid_path"
}

stop_server() {
	if ! server_is_running; then
		clear_server_state
		return 0
	fi

	local pid
	pid=$(<"$server_pid_path")

	kill -INT "$pid" >/dev/null 2>&1 || true
	for _ in $(seq 1 50); do
		if ! kill -0 "$pid" >/dev/null 2>&1; then
			clear_server_state
			return 0
		fi
		sleep 0.1
	done

	echo "Server did not stop after SIGINT; forcing termination" >&2
	kill -TERM "$pid" >/dev/null 2>&1 || true
	for _ in $(seq 1 20); do
		if ! kill -0 "$pid" >/dev/null 2>&1; then
			clear_server_state
			return 0
		fi
		sleep 0.1
	done

	echo "Server did not stop after SIGTERM; killing process" >&2
	kill -KILL "$pid" >/dev/null 2>&1 || true
	clear_server_state
}

wait_for_server_ready() {
	local timeout_secs=${1:-$server_ready_timeout_secs}
	local deadline=$((SECONDS + timeout_secs))

	if [[ ! -f "$server_log_path" ]]; then
		echo "server log not found: $server_log_path" >&2
		return 1
	fi

	if ! server_is_running; then
		echo "Server is not running" >&2
		clear_server_state
		return 1
	fi

	while (( SECONDS < deadline )); do
		if ! server_is_running; then
			echo "Server exited before reporting readiness" >&2
			if [[ -f "$server_log_path" ]]; then
				tail -n 50 "$server_log_path" >&2 || true
			fi
			clear_server_state
			return 1
		fi

		if grep -Fq "=== Server Running ===" "$server_log_path"; then
			echo "Server is ready"
			return 0
		fi

		if grep -Fq "[Startup]" "$server_log_path"; then
			echo "Server failed during startup:" >&2
			grep -F "[Startup]" "$server_log_path" >&2 || true
			return 1
		fi

		sleep 0.1
	done

	echo "Timed out waiting for server readiness after ${timeout_secs}s" >&2
	if [[ -f "$server_log_path" ]]; then
		tail -n 50 "$server_log_path" >&2 || true
	fi
	return 1
}

run_bootstrap() {
	if ! command -v psql >/dev/null 2>&1; then
		echo "psql is required for database bootstrap" >&2
		exit 1
	fi

	if [[ ! -f "$bootstrap_sql_path" ]]; then
		echo "bootstrap SQL not found: $bootstrap_sql_path" >&2
		exit 1
	fi

	echo "Bootstrapping auth database state from $bootstrap_sql_path"
	if ! PGPASSWORD="$HAYCHAT_DATABASE_PASS" \
		psql \
			-v ON_ERROR_STOP=1 \
			-h "$HAYCHAT_DATABASE_URL" \
			-p "$HAYCHAT_DATABASE_PORT" \
			-U "$HAYCHAT_DATABASE_USER" \
			-d "$HAYCHAT_DATABASE_NAME" \
			-f "$bootstrap_sql_path"; then
		echo "[HC-118][startup] bootstrap failed while preparing auth database state" >&2
		echo "[HC-118][startup] check database permissions and bootstrap prerequisites before retrying" >&2
		return 1
	fi
}

run_server() {
	if ! command -v odin >/dev/null 2>&1; then
		echo "odin is required to start the server" >&2
		exit 1
	fi

	cd "$script_dir"
	odin run server
}

build_server_binary() {
	if ! command -v odin >/dev/null 2>&1; then
		echo "odin is required to build the server" >&2
		exit 1
	fi

	ensure_runtime_dir
	cd "$script_dir"
	odin build server -out:"$server_bin_path"
}

start_server_background() {
	ensure_runtime_dir

	if server_is_running; then
		echo "server already running with PID $(<"$server_pid_path")" >&2
		return 1
	fi

	clear_server_state
	: >"$server_log_path"
	build_server_binary

	cd "$script_dir"
	"$server_bin_path" >>"$server_log_path" 2>&1 &
	local server_pid=$!
	echo "$server_pid" >"$server_pid_path"
	echo "Started server in background with PID $server_pid"
	echo "Server log: $server_log_path"
}

bootstrap_start_server_background() {
	run_bootstrap
	start_server_background
	if ! wait_for_server_ready; then
		stop_server || true
		return 1
	fi
}

run_hc118_gate() {
	if ! command -v odin >/dev/null 2>&1; then
		echo "odin is required to run the HC-118 gate" >&2
		exit 1
	fi

	cd "$script_dir"

	echo "[HC-118][baseline] common: odin test common"
	odin test common

	echo "[HC-118][baseline] server: odin test server"
	odin test server

	echo "[HC-118][baseline] client: odin test client"
	odin test client

	trap 'stop_server >/dev/null 2>&1 || true' EXIT

	echo "[HC-118][startup] bootstrap, start background server, and wait for readiness"
	bootstrap_start_server_background

	echo "[HC-118][connect] running live startup/connect proof"
	echo "[HC-118][auth] verifying both clients authenticate against the live server"
	echo "[HC-118][message] verifying authoritative room-chat delivery"
	HAYCHAT_LIVE_STARTUP_AUTH=1 \
		odin test client \
			-define:ODIN_TEST_NAMES=client.testClientServerTransportCanEstablishLiveStartupAuthOverENet,client.testClientServerTransportCanSendLiveRoomChatBetweenTwoAuthenticatedClients

	trap - EXIT
	stop_server
}

command_name=${1:-start}

case "$command_name" in
	bootstrap)
		run_bootstrap
		;;
	start)
		run_server
		;;
	start-background)
		start_server_background
		;;
	wait-ready)
		wait_for_server_ready "${2:-$server_ready_timeout_secs}"
		;;
	stop)
		stop_server
		;;
	bootstrap-start)
		run_bootstrap
		run_server
		;;
	bootstrap-start-background)
		bootstrap_start_server_background
		;;
	hc118-gate)
		run_hc118_gate
		;;
	*)
		echo "Usage: $0 [bootstrap|start|start-background|wait-ready [timeout_secs]|stop|bootstrap-start|bootstrap-start-background|hc118-gate]" >&2
		exit 1
		;;
esac