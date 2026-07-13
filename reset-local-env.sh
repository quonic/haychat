#!/usr/bin/env bash
set -euo pipefail

# reset-local-env.sh — Repeatable local reset of HayChat runtime state and fixtures.
#
# Resets (idempotent, safe to run on already-clean state):
#   1. Server logs   — contents of logs/
#   2. File storage  — contents of storage/
#   3. Server identity keys — storage/server_identity.json
#   4. Test runtime dir — .haychat-test-server/
#   5. Database seed  — re-runs server/sql/auth_bootstrap.sql (hayseed/id=1, haypeer/id=2)
#   6. Client config  — ~/.config/haychat/config.json (or $XDG_CONFIG_HOME/haychat/config.json)
#
# Does NOT reset:
#   - Drops the database or schemas (that is HC-203's job)
#   - Stops running servers
#   - Removes the repository or installed dependencies

repo_dir=$(cd -- "$(dirname -- "$0")" >/dev/null 2>&1 && pwd)
bootstrap_sql_path="$repo_dir/server/sql/auth_bootstrap.sql"

# DB connection env vars (same defaults as run-test-server.sh)
export HAYCHAT_DATABASE_URL=${HAYCHAT_DATABASE_URL:-localhost}
export HAYCHAT_DATABASE_PORT=${HAYCHAT_DATABASE_PORT:-5432}
export HAYCHAT_DATABASE_USER=${HAYCHAT_DATABASE_USER:-haychat}
export HAYCHAT_DATABASE_PASS=${HAYCHAT_DATABASE_PASS:-haychat}
export HAYCHAT_DATABASE_NAME=${HAYCHAT_DATABASE_NAME:-haychat}

# Resolve XDG config base
config_base="${XDG_CONFIG_HOME:-$HOME/.config}"
client_config_path="$config_base/haychat/config.json"

dry_run=false

# ── Argument parsing ──────────────────────────────────────────────

usage() {
	cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Reset local HayChat runtime state and fixtures to a known clean state.

Options:
  --dry-run   Print what would be done without making changes
  --help      Show this help message and exit

Each step is idempotent — running on an already-clean state succeeds silently.
Does NOT drop the database, drop schemas, or stop running servers.
EOF
}

for arg in "$@"; do
	case "$arg" in
		--dry-run) dry_run=true ;;
		--help)    usage; exit 0 ;;
		*) echo "Unknown option: $arg" >&2; usage >&2; exit 1 ;;
	esac
done

# ── Helper ────────────────────────────────────────────────────────

do_reset() {
	local target="$1"
	shift

	echo "==> Resetting $target"
	if $dry_run; then
		echo "    (dry-run, skipping)"
		return 0
	fi

	"$@"
}

# ── Step 1: Server logs ──────────────────────────────────────────

do_reset "server logs" find "$repo_dir/logs" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
mkdir -p -- "$repo_dir/logs"

# ── Step 2: File storage ─────────────────────────────────────────

do_reset "file storage" find "$repo_dir/storage" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
mkdir -p -- "$repo_dir/storage"

# ── Step 3: Server identity keys ─────────────────────────────────

do_reset "server identity keys" rm -f -- "$repo_dir/storage/server_identity.json"

# ── Step 4: Test runtime dir ─────────────────────────────────────

do_reset "test runtime dir" rm -rf -- "$repo_dir/.haychat-test-server"

# ── Step 5: Database seed reset ──────────────────────────────────

if $dry_run; then
	if command -v psql >/dev/null 2>&1; then
		echo "==> [dry-run] Resetting database seed"
		echo "    Would re-run: psql -h $HAYCHAT_DATABASE_URL -p $HAYCHAT_DATABASE_PORT -U $HAYCHAT_DATABASE_USER -d $HAYCHAT_DATABASE_NAME -f $bootstrap_sql_path"
	else
		echo "==> [dry-run] Resetting database seed — SKIPPED (psql not found)"
	fi
else
	if ! command -v psql >/dev/null 2>&1; then
		echo "==> Resetting database seed — SKIPPED (psql not found)"
	else
		if [[ ! -f "$bootstrap_sql_path" ]]; then
			echo "==> Resetting database seed — SKIPPED (bootstrap SQL not found: $bootstrap_sql_path)"
		else
			echo "==> Resetting database seed"
			if PGPASSWORD="$HAYCHAT_DATABASE_PASS" \
				psql \
					-v ON_ERROR_STOP=1 \
					-h "$HAYCHAT_DATABASE_URL" \
					-p "$HAYCHAT_DATABASE_PORT" \
					-U "$HAYCHAT_DATABASE_USER" \
					-d "$HAYCHAT_DATABASE_NAME" \
					-f "$bootstrap_sql_path"; then
				echo "Database seed reset complete."
			else
				echo "==> Database seed reset failed. Check credentials and server connectivity." >&2
			fi
		fi
	fi
fi

# ── Step 6: Client config reset ──────────────────────────────────

do_reset "client config" rm -f -- "$client_config_path"

# ── Summary ───────────────────────────────────────────────────────

if $dry_run; then
	echo
	echo "==> Dry run complete. No changes were made."
else
	echo
	echo "==> Reset complete. All runtime state cleared."
fi
