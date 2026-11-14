#!/usr/bin/env bash
set -euo pipefail

# dev.sh — the HayChat development environment, run in podman containers.
#
# The host needs only podman. Every command runs in the dev image (dev/Containerfile: Fedora 44,
# pinned Odin, shared libraries) and works on a snapshot of the working tree: tracked files plus
# untracked files that are not ignored. Host leftovers such as logs/, storage/, built binaries,
# and ~/.config/haychat never reach a container, and no command touches them.
#
# Run `./dev.sh help` for the command list.

repo_dir=$(cd -- "$(dirname -- "$0")" >/dev/null 2>&1 && pwd)
dev_dir="$repo_dir/dev"

IMAGE_REPO=localhost/haychat-dev
RELEASE_IMAGE=localhost/haychat-server:dev
POSTGRES_IMAGE=${HAYCHAT_DEV_POSTGRES_IMAGE:-docker.io/library/postgres:17}

# The long-lived dev environment: one pod holding PostgreSQL and the server, which share the
# pod's network namespace and reach each other on 127.0.0.1.
POD=haychat-dev
DB_CONTAINER=$POD-db
SERVER_CONTAINER=$POD-server
DB_VOLUME=$POD-pgdata
STATE_VOLUME=$POD-state
CLIENT_VOLUME_PREFIX=$POD-client-

HOST_PORT=${HAYCHAT_DEV_PORT:-12345}
ENV_FILE=${HAYCHAT_DEV_ENV_FILE:-$repo_dir/.env}
READY_TIMEOUT_SECS=${HAYCHAT_SERVER_READY_TIMEOUT_SECS:-120}

# The database only exists inside a pod and is never published, so fixed credentials are fine.
DB_USER=haychat
DB_PASS=haychat
DB_NAME=haychat

STATE_DIR=/var/lib/haychat
SERVER_PORT=12345

# Server settings dev.sh owns because the pod wiring depends on them. The same keys in the
# env file are ignored.
FORCED_SERVER_KEYS=(
	HAYCHAT_DATABASE_URL
	HAYCHAT_DATABASE_PORT
	HAYCHAT_DATABASE_USER
	HAYCHAT_DATABASE_PASS
	HAYCHAT_DATABASE_NAME
	HAYCHAT_LISTEN_ADDR
	HAYCHAT_LISTEN_PORT
	HAYCHAT_LOG_DIR
	HAYCHAT_FILE_STORAGE_PATH
	HAYCHAT_SERVER_IDENTITY_FILE
)

usage() {
	cat <<EOF
Usage: ./dev.sh <command> [args]

Checks (each run uses fresh containers and a throwaway database):
  check                 compile checks and leak-checked test suites (./check.sh)
  live [--all|--harness|--admin|--voice|--ui|--sql|NAME...]
                        live server + client proof against a throwaway database; --admin
                        runs the two-client admin proof, --voice the two-process voice
                        proof, --ui drives the real window offscreen (screenshots: see below)
  ci                    check, then live: exactly what Forgejo CI runs

Dev environment (pod "$POD": PostgreSQL + server, state kept in volumes):
  up                    build the server from the working tree and start the pod
  restart               rebuild the server from the working tree and restart it
  down                  stop and remove the pod (data volumes are kept)
  reset                 down, then delete the dev database, server state, and client profiles
  status                show containers and ports
  logs [-f]             server output
  seed                  load server/sql/auth_bootstrap.sql (admin, haypeer, #general)
  psql [ARGS...]        psql shell on the dev database
  client [PROFILE]      run a client window in the pod (Wayland or X11); each profile has
                        its own identity key and config, and a new profile's display name
                        is the profile name (default profile: "default")
  key [PROFILE]         print a client profile's public key (for HAYCHAT_ADMIN_PUBLIC_KEY)

Toolchain:
  image [--pull]        (re)build the dev image; other commands build it when missing
  release-image [--smoke]
                        build the production server image (deploy/Containerfile) as
                        $RELEASE_IMAGE; --smoke also runs it against a
                        throwaway database and connects a headless client (deploy/README.md)
  shell                 interactive shell in the dev image with the repo mounted at /src
                        read-write (changes made there land in your working tree)
                        (shell CMD [ARGS...] runs one command there instead)

Environment:
  HAYCHAT_DEV_PORT          host UDP port for client connections (default 12345)
  HAYCHAT_DEV_ENV_FILE      server overrides file (default .env, see .env.example)
  HAYCHAT_DEV_POSTGRES_IMAGE  PostgreSQL image (default docker.io/library/postgres:17)
  HAYCHAT_DEV_UI_SCREENSHOTS  host directory that keeps \`live --ui\` screenshots (BMP);
                            without it they vanish with the throwaway container
EOF
}

die() {
	echo "dev.sh: $*" >&2
	exit 1
}

log_step() {
	echo "==> $*"
}

require_podman() {
	command -v podman >/dev/null 2>&1 || die "podman is required (dnf install podman)"
}

# ── Image ─────────────────────────────────────────────────────────

# The image tag is a hash of everything that goes into the image, so changing a package or
# an Odin pin produces a new tag and the next command rebuilds.
image_tag() {
	cat "$dev_dir/Containerfile" "$dev_dir/install-packages.sh" "$dev_dir/bootstrap-odin.sh" \
		| sha256sum | cut -c1-12
}

image_ref() {
	echo "$IMAGE_REPO:$(image_tag)"
}

build_image() {
	local ref
	ref=$(image_ref)
	log_step "Building dev image $ref"
	podman build "$@" -t "$ref" -f "$dev_dir/Containerfile" "$dev_dir"

	# Drop images built from older inputs; they are never used again.
	local old
	while IFS= read -r old; do
		if [[ -n "$old" && "$old" != "$ref" ]]; then
			podman rmi "$old" >/dev/null 2>&1 || true
		fi
	done < <(podman images --format '{{.Repository}}:{{.Tag}}' --filter "reference=$IMAGE_REPO")
}

ensure_image() {
	if ! podman image exists "$(image_ref)"; then
		build_image
	fi
}

# ── Source snapshot ───────────────────────────────────────────────

# Writes a tar of the working tree to stdout: tracked files (with uncommitted edits) plus
# untracked files that .gitignore does not exclude. Deleted tracked files are skipped.
source_snapshot() {
	(
		cd "$repo_dir"
		git ls-files -z --cached --others --exclude-standard \
			| while IFS= read -r -d '' path; do
				if [[ -e "$path" || -L "$path" ]]; then
					printf '%s\0' "$path"
				fi
			done \
			| tar --null --no-recursion -T - -cf -
	)
}

# ── Containers ────────────────────────────────────────────────────

pod_exists() {
	podman pod exists "$1"
}

container_running() {
	[[ "$(podman inspect -f '{{.State.Running}}' "$1" 2>/dev/null || true)" == "true" ]]
}

# start_database POD CONTAINER VOLUME|""  (no volume: the data lives in a tmpfs)
start_database() {
	local pod=$1 container=$2 volume=$3
	# shellcheck disable=SC2054  # the commas belong to the --tmpfs option value
	local storage_args=(--tmpfs /var/lib/postgresql/data:rw,size=512m)
	if [[ -n "$volume" ]]; then
		storage_args=(-v "$volume:/var/lib/postgresql/data")
	fi

	podman run -d --pod "$pod" --name "$container" \
		-e POSTGRES_USER="$DB_USER" \
		-e POSTGRES_PASSWORD="$DB_PASS" \
		-e POSTGRES_DB="$DB_NAME" \
		"${storage_args[@]}" \
		"$POSTGRES_IMAGE" >/dev/null
}

wait_for_database() {
	local container=$1
	local deadline=$((SECONDS + 60))
	# Probe over TCP: the image's first-boot init runs a socket-only server that would
	# otherwise look ready before the real one starts.
	until podman exec "$container" pg_isready -q -h 127.0.0.1 -U "$DB_USER" -d "$DB_NAME"; do
		if ! container_running "$container"; then
			podman logs "$container" >&2 || true
			die "PostgreSQL container $container exited"
		fi
		if ((SECONDS >= deadline)); then
			podman logs "$container" >&2 || true
			die "PostgreSQL did not become ready within 60s"
		fi
		sleep 0.5
	done
}

database_env_args() {
	printf '%s\0' \
		-e "HAYCHAT_DATABASE_URL=127.0.0.1" \
		-e "HAYCHAT_DATABASE_PORT=5432" \
		-e "HAYCHAT_DATABASE_USER=$DB_USER" \
		-e "HAYCHAT_DATABASE_PASS=$DB_PASS" \
		-e "HAYCHAT_DATABASE_NAME=$DB_NAME"
}

# Reads HAYCHAT_* overrides from the env file (KEY=VALUE lines, optional `export ` prefix)
# into the server_env_args array, skipping the keys dev.sh owns.
load_server_overrides() {
	server_env_args=()
	[[ -f "$ENV_FILE" ]] || return 0

	local line key value ignored=()
	while IFS= read -r line || [[ -n "$line" ]]; do
		line=${line#"${line%%[![:space:]]*}"}
		[[ -z "$line" || "$line" == \#* ]] && continue
		line=${line#export }
		[[ "$line" == *=* ]] || continue
		key=${line%%=*}
		value=${line#*=}
		[[ "$key" =~ ^HAYCHAT_[A-Z0-9_]+$ ]] || continue
		if [[ " ${FORCED_SERVER_KEYS[*]} " == *" $key "* ]]; then
			ignored+=("$key")
			continue
		fi
		# Strip one level of matching quotes.
		if [[ "$value" =~ ^\"(.*)\"$ || "$value" =~ ^\'(.*)\'$ ]]; then
			value=${BASH_REMATCH[1]}
		fi
		server_env_args+=(-e "$key=$value")
	done <"$ENV_FILE"

	if [[ ${#ignored[@]} -gt 0 ]]; then
		echo "    (ignoring ${#ignored[@]} pod-wiring keys from $ENV_FILE; see .env.example)"
	fi
}

# The server's output can contain NUL bytes, so it is searched with grep -a rather than
# captured into a variable.
server_output_has() {
	podman logs "$1" 2>&1 | grep -aFq -- "$2"
}

wait_for_server_ready() {
	local container=$1
	local deadline=$((SECONDS + READY_TIMEOUT_SECS))
	while ((SECONDS < deadline)); do
		if server_output_has "$container" "=== Server Running ==="; then
			return 0
		fi
		if server_output_has "$container" "[Startup]"; then
			podman logs "$container" 2>&1 | grep -a -v '^\[Shutdown\]' >&2 || true
			die "server failed during startup"
		fi
		if ! container_running "$container"; then
			podman logs "$container" >&2 || true
			die "server container exited before reporting readiness"
		fi
		sleep 0.5
	done
	podman logs --tail 50 "$container" >&2 || true
	die "server did not report readiness within ${READY_TIMEOUT_SECS}s"
}

# Builds the server from the working tree into the state volume. Runs before the running
# server is touched, so a compile error leaves the current server up.
build_server() {
	local image=$1
	log_step "Building the server from the working tree"
	source_snapshot | podman run --rm -i --init -v "$STATE_VOLUME:$STATE_DIR" "$image" \
		bash -c 'tar -xf - -C /work && mkdir -p "$0/bin" &&
			odin build server -out:"$0/bin/server"' "$STATE_DIR"
}

start_server() {
	local image=$1
	local db_args=()
	mapfile -d '' db_args < <(database_env_args)
	load_server_overrides

	log_step "Starting the server"
	podman run -d --pod "$POD" --name "$SERVER_CONTAINER" --init \
		--stop-signal SIGINT --stop-timeout 10 \
		-v "$STATE_VOLUME:$STATE_DIR" \
		-w "$STATE_DIR" \
		"${server_env_args[@]}" \
		"${db_args[@]}" \
		-e "HAYCHAT_LISTEN_ADDR=0.0.0.0" \
		-e "HAYCHAT_LISTEN_PORT=$SERVER_PORT" \
		-e "HAYCHAT_LOG_DIR=$STATE_DIR/logs" \
		-e "HAYCHAT_FILE_STORAGE_PATH=$STATE_DIR/storage" \
		-e "HAYCHAT_SERVER_IDENTITY_FILE=$STATE_DIR/storage/server_identity.json" \
		"$image" "$STATE_DIR/bin/server" >/dev/null
	wait_for_server_ready "$SERVER_CONTAINER"
	log_step "Server is ready"
}

require_dev_pod() {
	pod_exists "$POD" || die "the dev environment is not running; start it with ./dev.sh up"
}

# run_snapshot_in_pod POD [podman run options...] -- COMMAND [ARGS...]
# Runs the bash snippet COMMAND (with ARGS as "$@") in a fresh dev container inside POD,
# from /work holding the source snapshot.
run_snapshot_in_pod() {
	local pod=$1
	shift
	local run_args=()
	while [[ $# -gt 0 && "$1" != "--" ]]; do
		run_args+=("$1")
		shift
	done
	shift
	local db_args=()
	mapfile -d '' db_args < <(database_env_args)
	# dev/live-proof.sh has its own readiness default; pass the timeout only when it is set.
	if [[ -n "${HAYCHAT_SERVER_READY_TIMEOUT_SECS:-}" ]]; then
		run_args+=(-e "HAYCHAT_SERVER_READY_TIMEOUT_SECS=$HAYCHAT_SERVER_READY_TIMEOUT_SECS")
	fi

	source_snapshot | podman run --rm -i --init --pod "$pod" \
		"${db_args[@]}" "${run_args[@]}" "$(image_ref)" \
		bash -c 'tar -xf - -C /work && exec bash -c "$0" dev.sh "$@"' "$@"
}

# ── Commands ──────────────────────────────────────────────────────

cmd_check() {
	ensure_image
	log_step "Running ./check.sh in a fresh container"
	source_snapshot | podman run --rm -i --init "$(image_ref)" \
		bash -c 'tar -xf - -C /work && ./check.sh'
}

# with_throwaway_pod COMMAND...  runs COMMAND with $throwaway_pod holding a ready database
# that is destroyed afterwards. The pod publishes no ports, so it never conflicts with the
# dev environment or a host server.
with_throwaway_pod() {
	ensure_image
	throwaway_pod="haychat-test-$$"
	trap 'podman pod rm -f -t 5 "$throwaway_pod" >/dev/null 2>&1 || true' EXIT
	podman pod create --name "$throwaway_pod" >/dev/null
	log_step "Starting throwaway PostgreSQL in pod $throwaway_pod"
	start_database "$throwaway_pod" "$throwaway_pod-db" ""
	wait_for_database "$throwaway_pod-db"
	"$@"
}

cmd_live() {
	with_throwaway_pod run_live_proof "$@"
}

run_live_proof() {
	local run_args=()
	# The GUI smoke test's screenshots live in the container unless a host directory is
	# mounted for them.
	if [[ -n "${HAYCHAT_DEV_UI_SCREENSHOTS:-}" ]]; then
		mkdir -p -- "$HAYCHAT_DEV_UI_SCREENSHOTS"
		# Like `shell`, labelling is disabled rather than relabelling the user's directory
		# with :z; without either, SELinux denies the container's writes to it.
		run_args+=(--security-opt label=disable)
		run_args+=(-v "$(cd -- "$HAYCHAT_DEV_UI_SCREENSHOTS" && pwd):/screenshots")
		run_args+=(-e HAYCHAT_UI_SCREENSHOT_DIR=/screenshots)
	fi
	run_snapshot_in_pod "$throwaway_pod" "${run_args[@]}" -- 'dev/live-proof.sh "$@"' "$@"
}

cmd_ci() {
	with_throwaway_pod run_ci
}

run_ci() {
	log_step "Running ./check.sh and dev/live-proof.sh --all"
	run_snapshot_in_pod "$throwaway_pod" -- './check.sh && dev/live-proof.sh --all'
}

cmd_up() {
	ensure_image
	if pod_exists "$POD"; then
		if container_running "$SERVER_CONTAINER"; then
			echo "The dev environment is already running. Use ./dev.sh restart to rebuild."
			return 0
		fi
		podman pod start "$POD" >/dev/null
	else
		# Only the client port is published; PostgreSQL stays inside the pod.
		log_step "Creating pod $POD (client port UDP $HOST_PORT)"
		podman pod create --name "$POD" -p "$HOST_PORT:$SERVER_PORT/udp" >/dev/null
		start_database "$POD" "$DB_CONTAINER" "$DB_VOLUME"
	fi
	wait_for_database "$DB_CONTAINER"

	build_server "$(image_ref)"
	podman rm -f -t 10 "$SERVER_CONTAINER" >/dev/null 2>&1 || true
	start_server "$(image_ref)"
	echo
	cmd_status
}

cmd_restart() {
	require_dev_pod
	ensure_image
	build_server "$(image_ref)"
	log_step "Stopping the old server"
	podman rm -f -t 10 "$SERVER_CONTAINER" >/dev/null 2>&1 || true
	if ! container_running "$DB_CONTAINER"; then
		podman start "$DB_CONTAINER" >/dev/null
	fi
	wait_for_database "$DB_CONTAINER"
	start_server "$(image_ref)"
}

cmd_down() {
	if pod_exists "$POD"; then
		log_step "Removing pod $POD (volumes kept)"
		podman pod rm -f -t 10 "$POD" >/dev/null
	else
		echo "The dev environment is not running."
	fi
}

cmd_reset() {
	cmd_down
	local volumes=("$DB_VOLUME" "$STATE_VOLUME")
	local volume
	while IFS= read -r volume; do
		[[ -n "$volume" ]] && volumes+=("$volume")
	done < <(podman volume ls -q --filter "name=^$CLIENT_VOLUME_PREFIX")

	for volume in "${volumes[@]}"; do
		if podman volume exists "$volume"; then
			log_step "Deleting volume $volume"
			podman volume rm -f "$volume" >/dev/null
		fi
	done
	echo "Reset complete. The next ./dev.sh up starts with an empty database and a new" \
		"server key."
}

cmd_status() {
	if ! pod_exists "$POD"; then
		echo "The dev environment is not running."
		return 0
	fi
	podman ps -a --filter "pod=$POD" --format 'table {{.Names}}\t{{.Status}}'
	echo
	echo "Client connections: localhost:$HOST_PORT (UDP)"
	echo "Server status:      ./dev.sh logs | grep -F '[Status]' | tail -n 1"
}

cmd_logs() {
	require_dev_pod
	podman logs "$@" "$SERVER_CONTAINER"
}

cmd_seed() {
	require_dev_pod
	container_running "$SERVER_CONTAINER" \
		|| die "the server creates the schema the seed needs; run ./dev.sh up first"
	log_step "Loading server/sql/auth_bootstrap.sql"
	podman exec -i "$DB_CONTAINER" \
		psql -q -v ON_ERROR_STOP=1 -U "$DB_USER" -d "$DB_NAME" \
		<"$repo_dir/server/sql/auth_bootstrap.sql" >/dev/null
	echo "Seeded admin (ID 1), haypeer (ID 2), and #general."
}

cmd_psql() {
	require_dev_pod
	local tty_args=(-i)
	[[ -t 0 ]] && tty_args=(-it)
	podman exec "${tty_args[@]}" "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" "$@"
}

cmd_client() {
	local profile=${1:-default}
	[[ "$profile" =~ ^[A-Za-z0-9_.-]+$ ]] || die "profile names may use letters, digits, . _ -"
	require_dev_pod
	ensure_image

	# Hand the host display to the container. Wayland is preferred; X11 needs the socket and,
	# when set, the Xauthority file.
	local display_args=()
	local runtime_dir=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
	if [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
		local socket=$WAYLAND_DISPLAY
		[[ "$socket" == /* ]] || socket="$runtime_dir/$socket"
		[[ -S "$socket" ]] || die "Wayland socket not found: $socket"
		display_args+=(
			-v "$socket:/run/haychat/wayland-0"
			-e XDG_RUNTIME_DIR=/run/haychat
			-e WAYLAND_DISPLAY=wayland-0
			-e SDL_VIDEO_DRIVER=wayland
		)
	elif [[ -n "${DISPLAY:-}" ]]; then
		display_args+=(-v /tmp/.X11-unix:/tmp/.X11-unix -e "DISPLAY=$DISPLAY")
		if [[ -n "${XAUTHORITY:-}" && -f "$XAUTHORITY" ]]; then
			display_args+=(-v "$XAUTHORITY:/run/haychat/Xauthority:ro"
				-e XAUTHORITY=/run/haychat/Xauthority)
		fi
	else
		die "no display found: set WAYLAND_DISPLAY or DISPLAY"
	fi
	if [[ -e /dev/dri ]]; then
		display_args+=(--device /dev/dri)
	fi

	log_step "Building and starting client profile \"$profile\""
	# The client runs inside the dev pod, so its default server (localhost:12345) is the dev
	# server. Its config and identity key live in a per-profile volume. A new profile starts
	# from a config holding its display name and the dev server, so it skips the client's
	# first-run screen; the client generates the identity key. The server binds each nickname
	# to the first key it sees, so profiles need distinct names. The container runs without
	# SELinux confinement so it can use the host display socket.
	# shellcheck disable=SC2016  # the snippet expands inside the container
	run_snapshot_in_pod "$POD" \
		--security-opt label=disable \
		-v "$CLIENT_VOLUME_PREFIX$profile:/config" \
		-e XDG_CONFIG_HOME=/config \
		"${display_args[@]}" \
		-- 'config=/config/haychat/config.json
			if [[ ! -f "$config" ]]; then
				mkdir -p "${config%/*}"
				server="{\"id\": 1, \"name\": \"Dev Server\", \"short_name\": \"DS\","
				server+=" \"host\": \"localhost\", \"port\": 12345}"
				printf "{\"display_name\": \"%s\", \"servers\": [%s]}\n" "$1" "$server" \
					>"$config"
			fi
			odin build client -out:/tmp/haychat-client && exec /tmp/haychat-client' \
		"$profile"
}

cmd_key() {
	local profile=${1:-default}
	local volume="$CLIENT_VOLUME_PREFIX$profile"
	podman volume exists "$volume" \
		|| die "client profile \"$profile\" does not exist; run ./dev.sh client $profile first"
	ensure_image
	podman run --rm -v "$volume:/config:ro" "$(image_ref)" \
		sed -n 's/.*"public_key"[[:space:]]*:[[:space:]]*"\([0-9A-Fa-f]*\)".*/\1/p' \
		/config/haychat/config.json
}

cmd_image() {
	local build_args=()
	for arg in "$@"; do
		case "$arg" in
			--pull) build_args+=(--pull=always --no-cache) ;;
			*) die "unknown image option: $arg" ;;
		esac
	done
	build_image "${build_args[@]}"
}

cmd_release_image() {
	local smoke=false arg
	for arg in "$@"; do
		case "$arg" in
			--smoke) smoke=true ;;
			*) die "unknown release-image option: $arg" ;;
		esac
	done
	log_step "Building the production server image $RELEASE_IMAGE"
	# The context is the repository root, filtered by .containerignore.
	podman build -f "$repo_dir/deploy/Containerfile" -t "$RELEASE_IMAGE" "$repo_dir"
	if $smoke; then
		with_throwaway_pod smoke_release_image
	fi
}

# Runs the production image in the throwaway pod the way deploy/README.md does, checks that a
# headless client from the dev image connects and sees the #general room the server creates,
# and gives that account the admin role with deploy/sql/make-admin.sql.
smoke_release_image() {
	local server="$throwaway_pod-server" name db_args=()
	name="smoke-$(date +%s)"
	mapfile -d '' db_args < <(database_env_args)
	log_step "Starting $RELEASE_IMAGE in pod $throwaway_pod"
	podman run -d --pod "$throwaway_pod" --name "$server" --init \
		"${db_args[@]}" "$RELEASE_IMAGE" >/dev/null
	wait_for_server_ready "$server"

	# shellcheck disable=SC2016  # the snippet expands inside the container
	local client='odin build client -out:/tmp/haychat-client >&2 &&
		printf "%s\n" "wait room_list 10000" quit |
		/tmp/haychat-client --headless --name "$1" --server 127.0.0.1:12345 \
			--config-dir /tmp/profile'
	log_step "Connecting headless client $name: its room list must hold #general"
	run_snapshot_in_pod "$throwaway_pod" -- "$client" "$name" | grep -F '"name":"general"' \
		|| die "the headless client did not connect or saw no #general"
	log_step "Making $name an admin with deploy/sql/make-admin.sql"
	podman exec -i "$throwaway_pod-db" psql -q -U "$DB_USER" -d "$DB_NAME" -v owner="$name" \
		<"$repo_dir/deploy/sql/make-admin.sql"
	log_step "Release image smoke test passed"
}

cmd_shell() {
	ensure_image
	# With arguments, run them as one command without a terminal (dev/voice-manual-test.sh
	# builds the client this way on a host without a working odin).
	local tty_args=(-it) shell_command=(bash)
	if [[ $# -gt 0 ]]; then
		tty_args=()
		shell_command=("$@")
	fi
	# SELinux labelling is disabled rather than relabelling the repository with :z.
	podman run --rm "${tty_args[@]}" --init --security-opt label=disable \
		-v "$repo_dir:/src" -w /src "$(image_ref)" "${shell_command[@]}"
}

main() {
	local command=${1:-help}
	[[ $# -gt 0 ]] && shift

	case "$command" in
		help | -h | --help) usage; return 0 ;;
	esac

	require_podman
	case "$command" in
		check) cmd_check "$@" ;;
		live) cmd_live "$@" ;;
		ci) cmd_ci "$@" ;;
		up) cmd_up "$@" ;;
		restart) cmd_restart "$@" ;;
		down) cmd_down "$@" ;;
		reset) cmd_reset "$@" ;;
		status) cmd_status "$@" ;;
		logs) cmd_logs "$@" ;;
		seed) cmd_seed "$@" ;;
		psql) cmd_psql "$@" ;;
		client) cmd_client "$@" ;;
		key) cmd_key "$@" ;;
		image) cmd_image "$@" ;;
		release-image) cmd_release_image "$@" ;;
		shell) cmd_shell "$@" ;;
		*)
			echo "Unknown command: $command" >&2
			usage >&2
			exit 1
			;;
	esac
}

main "$@"
