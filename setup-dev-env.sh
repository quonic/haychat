#!/usr/bin/env bash
set -euo pipefail

# Bootstraps the supported Linux-first HayChat development environment.
# Supported host flow: Ubuntu/Debian with apt and systemd.

repo_dir=$(cd -- "$(dirname -- "$0")" >/dev/null 2>&1 && pwd)
odin_root=${HAYCHAT_ODIN_ROOT:-$HOME/Odin}
skald_root=${HAYCHAT_SKALD_ROOT:-$HOME/Skald}
local_bin_dir=${HAYCHAT_LOCAL_BIN_DIR:-$HOME/.local/bin}
default_db_user=${HAYCHAT_DATABASE_USER:-haychat}
default_db_pass=${HAYCHAT_DATABASE_PASS:-haychat}
default_db_name=${HAYCHAT_DATABASE_NAME:-haychat}
default_db_host=${HAYCHAT_DATABASE_URL:-localhost}
default_db_port=${HAYCHAT_DATABASE_PORT:-5432}

required_packages_dnf=(
	git
	git-lfs
	clang
	llvm
	llvm-devel
	lld
	pkg-config
	libpq-devel
	enet-devel
	postgresql
	postgresql-contrib
	postgresql-devel
	postgresql-server
	libX11-devel
	libXcursor-devel
	libXrandr-devel
	libXi-devel
	mesa-libGL-devel
	alsa-lib-devel
	dbus-devel
)

required_packages_apt=(
	git
	git-lfs
	clang
	llvm
	llvm-dev
	lld
	pkg-config
	libpq-dev
	enet-dev
	postgresql
	postgresql-client
	libx11-dev
	libxcursor-dev
	libxrandr-dev
	libxi-dev
	libgl1-mesa-dev
	libasound2-dev
	libdbus-1-dev
)

log_step() {
	echo
	echo "==> $1"
}

require_linux() {
	if [[ "$(uname -s)" != "Linux" ]]; then
		echo "This bootstrap path is supported only on Linux." >&2
		exit 1
	fi
}

require_apt() {
	if ! command -v apt-get >/dev/null 2>&1; then
		echo "Unsupported package manager for the supported bootstrap path." >&2
		echo "Use Ubuntu or Debian with apt-get for reproducible local setup." >&2
		return 1
	fi
	return 0
}

require_dnf() {
	if ! command -v dnf >/dev/null 2>&1; then
		echo "Unsupported package manager for the supported bootstrap path." >&2
		echo "Use Fedora or RHEL with dnf for reproducible local setup." >&2
		return 1
	fi
	return 0
}

require_sudo() {
	if ! command -v sudo >/dev/null 2>&1; then
		echo "sudo is required for package and PostgreSQL provisioning." >&2
		exit 1
	fi
}

clone_or_update_repo() {
	local repo_url=$1
	local dest_dir=$2
	local branch=${3:-}

	if [[ -d "$dest_dir/.git" ]]; then
		echo "Updating $dest_dir"
		git -C "$dest_dir" pull --ff-only
		return
	fi

	mkdir -p "$(dirname -- "$dest_dir")"
	echo "Cloning $repo_url into $dest_dir"
	git clone "$repo_url" "$dest_dir"
	git lfs install
	git lfs pull

	if [[ -n "$branch" ]]; then
		git -C "$dest_dir" checkout "$branch"
	fi
}

install_packages() {
	log_step "Installing OS packages for the supported Linux-first flow"
	if command -v apt-get >/dev/null 2>&1; then
		sudo apt-get update
		sudo apt-get install -y "${required_packages_apt[@]}"
	elif command -v dnf >/dev/null 2>&1; then
		sudo dnf install -y "${required_packages_dnf[@]}"
	else
		echo "Unsupported package manager. Use apt or dnf." >&2
		exit 1
	fi
}

bootstrap_odin() {
	log_step "Cloning and building Odin"
	clone_or_update_repo "https://github.com/odin-lang/Odin.git" "$odin_root"

	(
		cd "$odin_root"
		./build_odin.sh
	)
	# Skald uses vendor:stb, whose static libraries are not committed for Linux.
	(
		cd "$odin_root/vendor/stb/src"
		CC=${CC:-clang} AR=${AR:-llvm-ar} ./build_stb.sh
	)

	mkdir -p "$local_bin_dir"
	ln -sf "$odin_root/odin" "$local_bin_dir/odin"

	echo "Odin binary linked to $local_bin_dir/odin"
	case ":$PATH:" in
		*":$local_bin_dir:"*)
			;;
		*)
			echo "Add $local_bin_dir to PATH before running HayChat commands." >&2
			;;
	esac
}

bootstrap_shared_libraries() {
	log_step "Preparing Odin shared libraries used by HayChat"
	clone_or_update_repo "https://github.com/laytan/odin-postgresql.git" "$odin_root/shared/pg"
	clone_or_update_repo "https://github.com/laytan/odin-http.git" "$odin_root/shared/odin-http"
	clone_or_update_repo "https://github.com/BuLEEto/Skald.git" "$skald_root"

	mkdir -p "$odin_root/shared"
	ln -sfn "$skald_root/skald" "$odin_root/shared/skald"
}

bootstrap_postgres() {
	log_step "Starting PostgreSQL and provisioning the default HayChat database"

	if command -v systemctl >/dev/null 2>&1; then
		sudo systemctl enable --now postgresql
	fi

	role_exists=$(sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${default_db_user}'")
	if [[ "$role_exists" == "1" ]]; then
		alter_role="ALTER ROLE ${default_db_user} WITH LOGIN PASSWORD '${default_db_pass}';"
		sudo -u postgres psql -v ON_ERROR_STOP=1 postgres -c "$alter_role"
	else
		create_role="CREATE ROLE ${default_db_user} LOGIN PASSWORD '${default_db_pass}';"
		sudo -u postgres psql -v ON_ERROR_STOP=1 postgres -c "$create_role"
	fi

	db_exists=$(sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${default_db_name}'")
	if [[ "$db_exists" == "1" ]]; then
		create_db=""
		grant_privileges="GRANT ALL PRIVILEGES ON DATABASE ${default_db_name} TO ${default_db_user};"
		sudo -u postgres psql -v ON_ERROR_STOP=1 postgres -c "$grant_privileges"
	else
		create_db="CREATE DATABASE ${default_db_name} OWNER ${default_db_user};"
		sudo -u postgres psql -v ON_ERROR_STOP=1 postgres -c "$create_db"
		grant_privileges="GRANT ALL PRIVILEGES ON DATABASE ${default_db_name} TO ${default_db_user};"
		sudo -u postgres psql -v ON_ERROR_STOP=1 postgres -c "$grant_privileges"
	fi
}

print_summary() {
	log_step "Bootstrap complete"
	echo "Supported handoff model: source-based, internal-only tester flow"
	echo "Supported bootstrap host: Ubuntu/Debian Linux"
	echo "Default database target: ${default_db_user}@${default_db_host}:${default_db_port}/${default_db_name}"
	echo
	echo "Recommended next commands:"
	echo "  odin check server"
	echo "  odin check client -target:linux_amd64"
	echo "  odin check client -target:windows_amd64"
	echo "  ./run-test-server.sh bootstrap-start-background"
	echo
	echo "Repository root: $repo_dir"
	echo "Odin root: $odin_root"
}

main() {
	require_linux
	require_apt || require_dnf || { echo "Unsupported package manager. Use apt or dnf." >&2; exit 1; }
	require_sudo
	install_packages
	bootstrap_odin
	bootstrap_shared_libraries
	bootstrap_postgres
	print_summary
}

main "$@"
