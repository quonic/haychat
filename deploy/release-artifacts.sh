#!/usr/bin/env bash
set -euo pipefail

# Builds the HayChat release archives: the server binary, the Linux client, and (with
# --windows) the Windows client, cross-built from Linux. Runs where the pinned Odin toolchain
# is on PATH: the dev image (`./dev.sh shell`) or the release workflow's Fedora 44 job.
#
# Usage: deploy/release-artifacts.sh VERSION OUT_DIR [--windows]
#
# Output in OUT_DIR:
#   haychat-server-VERSION-linux-x86_64.tar.gz    server binary, SQL helpers, deploy docs
#   haychat-client-VERSION-linux-x86_64.tar.gz    client binary, README.txt, licences
#   haychat-client-VERSION-windows-x86_64.zip     client.exe, SDL3 DLLs, README.txt, licences
#   SHA256SUMS
#
# --windows needs two things the dev image does not have:
#   - git-lfs: the pinned Odin checkout holds vendor/sdl3/SDL3.dll and SDL3.lib as Git LFS
#     pointers; they are fetched on first use (dnf install git-lfs).
#   - A Windows SDK and MSVC CRT in "winsysroot" layout. Set HAYCHAT_WINDOWS_SDK_ROOT to one,
#     or set HAYCHAT_ACCEPT_MSVC_LICENSE=1 to download them with xwin
#     (https://github.com/Jake-Shadle/xwin), which accepts Microsoft's licence terms for the
#     Visual Studio build tools and Windows SDK on your behalf. The download is about 1 GB
#     and is cached in HAYCHAT_XWIN_CACHE (default ~/.cache/haychat-xwin).

XWIN_VERSION=0.10.0
XWIN_SHA256=d870eb4b2f390878af6da1ccd3cf321d22fcb72720984853b4be732ae597fc88

repo_dir=$(cd -- "$(dirname -- "$0")/.." >/dev/null 2>&1 && pwd)

die() {
	echo "release-artifacts.sh: $*" >&2
	exit 1
}

log_step() {
	echo "==> $*"
}

[[ $# -ge 2 && $# -le 3 ]] || die "usage: deploy/release-artifacts.sh VERSION OUT_DIR [--windows]"
version=$1
out_dir=$2
build_windows=false
if [[ $# -eq 3 ]]; then
	[[ "$3" == "--windows" ]] || die "unknown option: $3"
	build_windows=true
fi
[[ "$version" =~ ^[A-Za-z0-9._-]+$ ]] || die "VERSION may use letters, digits, . _ -"

command -v odin >/dev/null 2>&1 || die "odin is not on PATH (run inside ./dev.sh shell)"
odin_root=${ODIN_ROOT:-$(odin root)}
mkdir -p "$out_dir"
out_dir=$(cd -- "$out_dir" && pwd)
work_dir=$(mktemp -d -t haychat-release.XXXXXX)
trap 'rm -rf "$work_dir"' EXIT

cd "$repo_dir"

# Writes a zip of DIR's contents (DIR itself as the top folder) to ARCHIVE. Python's zipfile
# module is used because the dev image has python3 but no zip tool.
make_zip() {
	local archive=$1 dir=$2
	(cd "$(dirname -- "$dir")" && python3 -m zipfile -c "$archive" "$(basename -- "$dir")")
}

copy_client_licences() {
	local dest=$1
	mkdir -p "$dest/licenses"
	cp LICENSE "$dest/LICENSE.txt"
	cp client/assets/fonts/InterVariable-OFL.txt client/assets/fonts/Twemoji-Mozilla-CCBY.txt \
		"$dest/licenses/"
	cp "$odin_root/vendor/ENet/LICENSE" "$dest/licenses/ENet-LICENSE.txt"
}

# ── Server ────────────────────────────────────────────────────────

log_step "Building the server"
server_dir="$work_dir/haychat-server-$version"
mkdir -p "$server_dir/sql"
odin build server -o:speed -out:"$server_dir/haychat-server"
cp LICENSE "$server_dir/LICENSE"
cp deploy/README.md "$server_dir/DEPLOY.md"
cp .env.example "$server_dir/env.example"
cp server/sql/auth_bootstrap.sql deploy/sql/make-admin.sql "$server_dir/sql/"
tar -C "$work_dir" -czf "$out_dir/haychat-server-$version-linux-x86_64.tar.gz" \
	"haychat-server-$version"

# ── Linux client ──────────────────────────────────────────────────

log_step "Building the Linux client"
linux_dir="$work_dir/haychat-$version-linux"
mkdir -p "$linux_dir"
odin build client -o:speed -out:"$linux_dir/haychat-client"
copy_client_licences "$linux_dir"
sed "s/@VERSION@/$version/g" deploy/client-README-linux.txt >"$linux_dir/README.txt"
tar -C "$work_dir" -czf "$out_dir/haychat-client-$version-linux-x86_64.tar.gz" \
	"haychat-$version-linux"

# ── Windows client ────────────────────────────────────────────────

is_lfs_pointer() {
	head -c 64 "$1" | grep -q '^version https://git-lfs'
}

fetch_sdl_lfs_files() {
	local sdl_dir="$odin_root/vendor/sdl3"
	if ! is_lfs_pointer "$sdl_dir/SDL3.dll" && ! is_lfs_pointer "$sdl_dir/SDL3.lib" \
		&& ! is_lfs_pointer "$sdl_dir/ttf/SDL3_ttf.dll" \
		&& ! is_lfs_pointer "$sdl_dir/ttf/SDL3_ttf.lib"; then
		return 0
	fi
	command -v git-lfs >/dev/null 2>&1 \
		|| die "$sdl_dir holds Git LFS pointers; install git-lfs (dnf install git-lfs)"
	log_step "Fetching SDL3 Windows libraries from Git LFS"
	git -C "$odin_root" lfs install --local >/dev/null
	git -C "$odin_root" lfs pull --include \
		"vendor/sdl3/SDL3.dll,vendor/sdl3/SDL3.lib,vendor/sdl3/ttf/SDL3_ttf.dll,vendor/sdl3/ttf/SDL3_ttf.lib"
}

windows_sdk_root() {
	if [[ -n "${HAYCHAT_WINDOWS_SDK_ROOT:-}" ]]; then
		[[ -d "$HAYCHAT_WINDOWS_SDK_ROOT/VC" ]] \
			|| die "HAYCHAT_WINDOWS_SDK_ROOT has no VC directory: $HAYCHAT_WINDOWS_SDK_ROOT"
		echo "$HAYCHAT_WINDOWS_SDK_ROOT"
		return 0
	fi
	[[ "${HAYCHAT_ACCEPT_MSVC_LICENSE:-}" == "1" ]] \
		|| die "--windows needs HAYCHAT_WINDOWS_SDK_ROOT, or HAYCHAT_ACCEPT_MSVC_LICENSE=1" \
			"to download the Windows SDK and MSVC CRT with xwin (see the header of this script)"

	local cache=${HAYCHAT_XWIN_CACHE:-$HOME/.cache/haychat-xwin}
	local xwin="$cache/xwin-$XWIN_VERSION/xwin"
	local sysroot="$cache/winsysroot"
	mkdir -p "$cache"
	if [[ ! -x "$xwin" ]]; then
		local name="xwin-$XWIN_VERSION-x86_64-unknown-linux-musl"
		local url="https://github.com/Jake-Shadle/xwin/releases/download/$XWIN_VERSION/$name.tar.gz"
		curl -fsSL -o "$cache/xwin.tar.gz" "$url" >&2
		echo "$XWIN_SHA256  $cache/xwin.tar.gz" | sha256sum -c --quiet - >&2 \
			|| die "xwin download does not match the pinned checksum"
		mkdir -p "$cache/xwin-$XWIN_VERSION"
		tar -xzf "$cache/xwin.tar.gz" -C "$cache/xwin-$XWIN_VERSION" --strip-components=1
		rm -f "$cache/xwin.tar.gz"
	fi
	if [[ ! -d "$sysroot/VC" ]]; then
		echo "==> Downloading the Windows SDK and MSVC CRT with xwin $XWIN_VERSION" >&2
		# lld-link's /winsysroot expects Microsoft's "x64" directory names.
		"$xwin" --accept-license --cache-dir "$cache/downloads" --arch x86_64 \
			splat --use-winsysroot-style --preserve-ms-arch-notation --output "$sysroot" >&2
		rm -rf "$cache/downloads"
	fi
	echo "$sysroot"
}

if $build_windows; then
	log_step "Building the Windows client"
	fetch_sdl_lfs_files
	sysroot=$(windows_sdk_root)
	windows_dir="$work_dir/haychat-$version-windows"
	mkdir -p "$windows_dir"
	odin build client -target:windows_amd64 -o:speed -linker:lld \
		-windows-sdk-root:"$sysroot" -out:"$windows_dir/haychat-client.exe"
	cp "$odin_root/vendor/sdl3/SDL3.dll" "$odin_root/vendor/sdl3/ttf/SDL3_ttf.dll" \
		"$windows_dir/"
	copy_client_licences "$windows_dir"
	cp "$odin_root/vendor/sdl3/LICENSE.txt" "$windows_dir/licenses/SDL3-LICENSE.txt"
	cp "$odin_root/vendor/sdl3/ttf/LICENSE.txt" "$windows_dir/licenses/SDL3_ttf-LICENSE.txt"
	for licence in freetype harfbuzz plutosvg plutovg; do
		cp "$odin_root/vendor/sdl3/ttf/LICENSE.$licence.txt" "$windows_dir/licenses/"
	done
	sed "s/@VERSION@/$version/g" deploy/client-README-windows.txt \
		| sed 's/$/\r/' >"$windows_dir/README.txt"
	rm -f "$out_dir/haychat-client-$version-windows-x86_64.zip"
	make_zip "$out_dir/haychat-client-$version-windows-x86_64.zip" "$windows_dir"
fi

(cd "$out_dir" && sha256sum haychat-*"-$version-"* >SHA256SUMS)
log_step "Release archives in $out_dir:"
cat "$out_dir/SHA256SUMS"
