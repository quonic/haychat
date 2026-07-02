#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "$0")" >/dev/null 2>&1 && pwd)
bootstrap_sql_path="$script_dir/server/sql/auth_bootstrap.sql"

export HAYCHAT_LOG_DIR=${HAYCHAT_LOG_DIR:-$script_dir/logs}
export HAYCHAT_FILE_STORAGE_PATH=${HAYCHAT_FILE_STORAGE_PATH:-$script_dir/storage}
export HAYCHAT_DATABASE_URL=${HAYCHAT_DATABASE_URL:-localhost}
export HAYCHAT_DATABASE_PORT=${HAYCHAT_DATABASE_PORT:-5432}
export HAYCHAT_DATABASE_USER=${HAYCHAT_DATABASE_USER:-haychat}
export HAYCHAT_DATABASE_PASS=${HAYCHAT_DATABASE_PASS:-haychat}
export HAYCHAT_DATABASE_NAME=${HAYCHAT_DATABASE_NAME:-haychat}

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
	PGPASSWORD="$HAYCHAT_DATABASE_PASS" \
		psql \
			-v ON_ERROR_STOP=1 \
			-h "$HAYCHAT_DATABASE_URL" \
			-p "$HAYCHAT_DATABASE_PORT" \
			-U "$HAYCHAT_DATABASE_USER" \
			-d "$HAYCHAT_DATABASE_NAME" \
			-f "$bootstrap_sql_path"
}

run_server() {
	if ! command -v odin >/dev/null 2>&1; then
		echo "odin is required to start the server" >&2
		exit 1
	fi

	cd "$script_dir"
	odin run server
}

command_name=${1:-start}

case "$command_name" in
	bootstrap)
		run_bootstrap
		;;
	start)
		run_server
		;;
	bootstrap-start)
		run_bootstrap
		run_server
		;;
	*)
		echo "Usage: $0 [bootstrap|start|bootstrap-start]" >&2
		exit 1
		;;
esac