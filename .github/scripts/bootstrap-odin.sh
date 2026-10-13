#!/usr/bin/env bash
set -euo pipefail

# Builds Odin and installs the shared libraries HayChat uses, pinned to known-good commits so
# CI matches the toolchain developers validate against. Update the pins together.
#
# Usage: bootstrap-odin.sh [odin_root]   (default: $HOME/Odin)

ODIN_COMMIT=6cfdf2bb3a84ff1f6bb29ac45ef58aee3b203eba
PG_COMMIT=9d82bb88e99fd2d47aac57c00e9e6f9aabf48238
ODIN_HTTP_COMMIT=fac113fbd828aad3d71479a534b5de4358b6a07b

odin_root=${1:-$HOME/Odin}

checkout_pinned() {
	local repo_url=$1
	local dest_dir=$2
	local commit=$3

	if [[ ! -d "$dest_dir/.git" ]]; then
		git init -q "$dest_dir"
		git -C "$dest_dir" remote add origin "$repo_url"
	fi
	if [[ "$(git -C "$dest_dir" rev-parse HEAD 2>/dev/null || true)" == "$commit" ]]; then
		return
	fi
	git -C "$dest_dir" fetch -q --depth 1 origin "$commit"
	git -C "$dest_dir" checkout -q --force FETCH_HEAD
}

checkout_pinned https://github.com/odin-lang/Odin.git "$odin_root" "$ODIN_COMMIT"
if [[ ! -x "$odin_root/odin" ]]; then
	(cd "$odin_root" && ./build_odin.sh release)
fi

mkdir -p "$odin_root/shared"
checkout_pinned https://github.com/laytan/odin-postgresql.git "$odin_root/shared/pg" "$PG_COMMIT"
checkout_pinned https://github.com/laytan/odin-http.git "$odin_root/shared/odin-http" \
	"$ODIN_HTTP_COMMIT"

"$odin_root/odin" version
