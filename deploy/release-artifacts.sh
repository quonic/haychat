#!/usr/bin/env bash
set -euo pipefail

# Builds the HayChat release archives: the server binary, the Linux client, and (with
# --windows) the Windows client, cross-built from Linux. Runs where the pinned Odin toolchain
# is on PATH: the dev image (`./dev.sh shell`) or the release workflow's Fedora 44 job.
#
# Usage:
#   deploy/release-artifacts.sh VERSION OUT_DIR [--windows]
#   deploy/release-artifacts.sh --check-licences
#   deploy/release-artifacts.sh --stage-licences server|linux|windows DIR
#
# Output in OUT_DIR:
#   haychat-server-VERSION-linux-x86_64.tar.gz    server binary, SQL helpers, deploy docs,
#                                                 notices, licences
#   haychat-client-VERSION-linux-x86_64.tar.gz    client binary, the echo canceller wrapper
#                                                 (libhaychat-webrtc-apm.so), README.txt,
#                                                 notices, licences
#   haychat-client-VERSION-windows-x86_64.zip     client.exe, SDL3, libopus, RNNoise and
#                                                 WebRTC audio processing DLLs, README.txt,
#                                                 notices, licences
#   SHA256SUMS
#
# Every archive carries THIRD_PARTY_NOTICES.txt and the licence texts its contents need (the
# *_LICENCES tables below). --check-licences verifies, without building anything or needing
# the Windows SDK, that every licence source exists in the repository and the pinned Odin
# toolchain, that SDL3.dll and SDL3_ttf.dll are still the builds THIRD_PARTY_NOTICES.md
# describes, that rnnoise.dll and haychat-webrtc-apm.dll (built from source by
# deploy/build-windows-rnnoise.sh and deploy/build-windows-webrtc-apm.sh) and the Linux
# libhaychat-webrtc-apm.so are named where they ship, and that the required credits are
# present; ./check.sh runs it, and every build
# runs it first. --stage-licences copies one artifact's notices and
# licences into DIR, which is what the builds below and deploy/Containerfile use.
#
# --windows needs two things the dev image does not have:
#   - git-lfs: the pinned Odin checkout holds vendor/sdl3/SDL3.dll, SDL3.lib, the SDL3_ttf
#     files and vendor/sdl3/mixer/libopus-0.dll as Git LFS pointers; they are fetched on first
#     use (dnf install git-lfs).
#   - A Windows SDK and MSVC CRT in "winsysroot" layout. Set HAYCHAT_WINDOWS_SDK_ROOT to one,
#     or set HAYCHAT_ACCEPT_MSVC_LICENSE=1 to download them with xwin
#     (https://github.com/Jake-Shadle/xwin), which accepts Microsoft's licence terms for the
#     Visual Studio build tools and Windows SDK on your behalf. The download is about 1 GB
#     and is cached in HAYCHAT_XWIN_CACHE (default ~/.cache/haychat-xwin).
# It also downloads the pinned RNNoise source release (deploy/build-windows-rnnoise.sh, cached in
# HAYCHAT_RNNOISE_CACHE) and the pinned webrtc-audio-processing and abseil releases
# (deploy/build-windows-webrtc-apm.sh, cached in HAYCHAT_WEBRTC_APM_CACHE), and builds
# rnnoise.dll and haychat-webrtc-apm.dll with the same sysroot.
#
# The Linux client's libhaychat-webrtc-apm.so (#171) is built against the system's
# webrtc-audio-processing 2.x headers (deploy/build-linux-webrtc-apm.sh; the dev image's
# webrtc-audio-processing-devel), so building needs those, and running needs that library.

XWIN_VERSION=0.10.0
XWIN_SHA256=d870eb4b2f390878af6da1ccd3cf321d22fcb72720984853b4be732ae597fc88

# The FreeType credit names the year of the FreeType inside SDL3_ttf.dll (FreeType 2.13.2,
# 2023, read with TTF_GetFreeTypeVersion under Wine). A different DLL may carry a different
# FreeType, so a change of its hash fails --check-licences until someone re-checks the version,
# updates the year in THIRD_PARTY_NOTICES.md and deploy/client-README-windows.txt, and pins
# the new hash here.
SDL3_TTF_DLL_SHA256=95a20af07f194f057b6e778bee0ce608d3c90c3dbd64a4b5120dc4879f43a6be

# THIRD_PARTY_NOTICES.md lists the third-party code inside SDL3.dll (SDL 3.4.18: HIDAPI,
# yuv2rgb, fdlibm and others), read from that SDL's source and the VisualC/SDL/SDL.vcxproj
# that builds the release DLL. A new SDL may bundle other code, so a change of the DLL's hash
# fails --check-licences until someone re-checks that list and the licence texts in
# deploy/licenses/, and pins the new hash here. Check src/audio/wasapi/SDL_wasapi.c of the new
# SDL too: while the stream role code there is under `#if 0`, the client's "Communications"
# role (voiceSDLStreamRole) does nothing on Windows; once it is live, SDL's capture gets
# Windows' communications processing and the in-app noise suppression and echo canceller must
# not run on top of it (docs/plan/2026-11-25-wasapi-communications-capture.md).
SDL3_DLL_SHA256=2b4b128d8d510cc2d442693cf848c050d700d43dc667afe9e5fd82b0570d667e
FREETYPE_CREDIT="Portions of this software are copyright © 2023 The FreeType Project"
TWEMOJI_CREDIT="Twemoji by Twitter, Inc. and contributors"

# Licence files per artifact, as SOURCE:DEST. SOURCE is repo:PATH (in this repository) or
# odin:PATH (in the pinned Odin root); DEST is relative to the artifact's top folder.
# THIRD_PARTY_NOTICES.md says why each artifact needs each file.
SERVER_LICENCES=(
	repo:LICENSE:LICENSE
	repo:THIRD_PARTY_NOTICES.md:THIRD_PARTY_NOTICES.txt
	odin:LICENSE:licenses/Odin-LICENSE.txt
	odin:base/runtime/LICENSE-compiler-rt.txt:licenses/compiler-rt-LICENSE.txt
	odin:shared/pg/LICENSE:licenses/pg-LICENSE.txt
)
LINUX_CLIENT_LICENCES=(
	repo:LICENSE:LICENSE.txt
	repo:THIRD_PARTY_NOTICES.md:THIRD_PARTY_NOTICES.txt
	repo:client/assets/fonts/InterVariable-OFL.txt:licenses/InterVariable-OFL.txt
	repo:client/assets/fonts/Twemoji-Mozilla-CCBY.txt:licenses/Twemoji-Mozilla-CCBY.txt
	odin:LICENSE:licenses/Odin-LICENSE.txt
	odin:base/runtime/LICENSE-compiler-rt.txt:licenses/compiler-rt-LICENSE.txt
	odin:vendor/ENet/LICENSE:licenses/ENet-LICENSE.txt
	# libhaychat-webrtc-apm.so compiles in WebRTC's header code; the library itself is the
	# system's.
	repo:deploy/licenses/webrtc-LICENSE.txt:licenses/webrtc-LICENSE.txt
	repo:deploy/licenses/webrtc-PATENTS.txt:licenses/webrtc-PATENTS.txt
)
# The Windows client also ships the DLLs (and the code inside them) and links ENet statically.
WINDOWS_CLIENT_LICENCES=(
	"${LINUX_CLIENT_LICENCES[@]}"
	odin:vendor/sdl3/LICENSE.txt:licenses/SDL3-LICENSE.txt
	odin:vendor/sdl3/ttf/LICENSE.txt:licenses/SDL3_ttf-LICENSE.txt
	odin:vendor/sdl3/ttf/LICENSE.freetype.txt:licenses/LICENSE.freetype.txt
	odin:vendor/sdl3/ttf/LICENSE.harfbuzz.txt:licenses/LICENSE.harfbuzz.txt
	odin:vendor/sdl3/ttf/LICENSE.plutosvg.txt:licenses/LICENSE.plutosvg.txt
	odin:vendor/sdl3/ttf/LICENSE.plutovg.txt:licenses/LICENSE.plutovg.txt
	odin:vendor/sdl3/mixer/LICENSE.opus.txt:licenses/opus-LICENSE.txt
	repo:deploy/licenses/hidapi-LICENSE-bsd.txt:licenses/hidapi-LICENSE-bsd.txt
	repo:deploy/licenses/yuv2rgb-LICENSE.txt:licenses/yuv2rgb-LICENSE.txt
	repo:deploy/licenses/rnnoise-COPYING.txt:licenses/rnnoise-LICENSE.txt
	repo:deploy/licenses/webrtc-third-party.txt:licenses/webrtc-third-party.txt
	repo:deploy/licenses/abseil-LICENSE.txt:licenses/abseil-LICENSE.txt
)

repo_dir=$(cd -- "$(dirname -- "$0")/.." >/dev/null 2>&1 && pwd)

die() {
	echo "release-artifacts.sh: $*" >&2
	exit 1
}

log_step() {
	echo "==> $*"
}

usage_error() {
	die "usage: deploy/release-artifacts.sh VERSION OUT_DIR [--windows]" \
		"| --check-licences | --stage-licences server|linux|windows DIR"
}

resolve_odin_root() {
	if [[ -n "${ODIN_ROOT:-}" ]]; then
		echo "$ODIN_ROOT"
		return 0
	fi
	command -v odin >/dev/null 2>&1 || die "odin is not on PATH (run inside ./dev.sh shell)"
	odin root
}

is_lfs_pointer() {
	head -c 64 "$1" | grep -q '^version https://git-lfs'
}

# Prints the licence table of one artifact, one SOURCE:DEST entry per line.
licence_table() {
	case "$1" in
		server) printf '%s\n' "${SERVER_LICENCES[@]}" ;;
		linux) printf '%s\n' "${LINUX_CLIENT_LICENCES[@]}" ;;
		windows) printf '%s\n' "${WINDOWS_CLIENT_LICENCES[@]}" ;;
		*) die "unknown artifact: $1 (server, linux, or windows)" ;;
	esac
}

licence_source_path() {
	local source=$1
	case "$source" in
		repo:*) echo "$repo_dir/${source#repo:}" ;;
		odin:*) echo "$odin_root/${source#odin:}" ;;
		*) die "bad licence source: $source" ;;
	esac
}

# Prints one line per problem with ARTIFACT's licence sources. A licence file that is
# missing, empty, or a Git LFS placeholder would otherwise ship broken or not at all.
licence_table_problems() {
	local artifact=$1 entry source path
	while IFS= read -r entry; do
		source=${entry%:*}
		path=$(licence_source_path "$source")
		if [[ ! -f "$path" ]]; then
			echo "$artifact: missing $path"
		elif [[ ! -s "$path" ]]; then
			echo "$artifact: empty $path"
		elif is_lfs_pointer "$path"; then
			echo "$artifact: $path is a Git LFS pointer, not the licence text"
		fi
	done < <(licence_table "$artifact")
}

# SHA-256 of a file, or of the file a Git LFS pointer stands for (its oid), so the check
# works on a checkout whose DLLs were never fetched.
content_sha256() {
	local path=$1
	if is_lfs_pointer "$path"; then
		sed -n 's/^oid sha256:\([0-9a-f]\{64\}\)$/\1/p' "$path"
	else
		sha256sum "$path" | cut -d' ' -f1
	fi
}

# Prints a problem when a shipped DLL is missing or is not the build THIRD_PARTY_NOTICES.md
# describes; ADVICE says what to re-check before pinning the new hash.
pinned_dll_problem() {
	local path=$1 expected_sha=$2 advice=$3 sha
	if [[ ! -f "$path" ]]; then
		echo "windows: missing $path"
		return 0
	fi
	sha=$(content_sha256 "$path")
	if [[ "$sha" != "$expected_sha" ]]; then
		echo "windows: ${path##*/} changed (sha256 $sha): $advice"
	fi
}

# Checks every artifact's licence sources and the required credits. Needs only the
# repository and the Odin root: no build, no Windows SDK, no Git LFS download.
check_licences() {
	local problems=() line artifact
	for artifact in server linux windows; do
		while IFS= read -r line; do
			problems+=("$line")
		done < <(licence_table_problems "$artifact")
	done

	local sdl_dir="$odin_root/vendor/sdl3" advice
	advice="re-check the third-party code it bundles (THIRD_PARTY_NOTICES.md) and the licence"
	advice+=" texts in deploy/licenses/, and pin the new SDL3_DLL_SHA256"
	line=$(pinned_dll_problem "$sdl_dir/SDL3.dll" "$SDL3_DLL_SHA256" "$advice")
	if [[ -n "$line" ]]; then
		problems+=("$line")
	fi
	advice="check the FreeType version inside it, update the FreeType credit year, and pin"
	advice+=" the new SDL3_TTF_DLL_SHA256"
	line=$(pinned_dll_problem "$sdl_dir/ttf/SDL3_ttf.dll" "$SDL3_TTF_DLL_SHA256" "$advice")
	if [[ -n "$line" ]]; then
		problems+=("$line")
	fi

	local file
	for file in THIRD_PARTY_NOTICES.md deploy/client-README-windows.txt; do
		grep -qF "$FREETYPE_CREDIT" "$repo_dir/$file" \
			|| problems+=("$file lacks the FreeType credit: $FREETYPE_CREDIT")
		# The Windows zip carries rnnoise.dll (built from source, so no hash pin above); both
		# documents must name it with its licence.
		grep -qF "rnnoise.dll" "$repo_dir/$file" \
			|| problems+=("$file does not name rnnoise.dll (RNNoise, BSD-3-Clause)")
		# The same for haychat-webrtc-apm.dll (#171: WebRTC audio processing and abseil).
		grep -qF "haychat-webrtc-apm.dll" "$repo_dir/$file" \
			|| problems+=("$file does not name haychat-webrtc-apm.dll (WebRTC, abseil)")
	done
	for file in THIRD_PARTY_NOTICES.md deploy/client-README-linux.txt; do
		grep -qF "libhaychat-webrtc-apm.so" "$repo_dir/$file" \
			|| problems+=("$file does not name libhaychat-webrtc-apm.so (#171)")
	done
	for file in THIRD_PARTY_NOTICES.md deploy/client-README-windows.txt \
		deploy/client-README-linux.txt; do
		grep -qF "$TWEMOJI_CREDIT" "$repo_dir/$file" \
			|| problems+=("$file lacks the Twemoji attribution: $TWEMOJI_CREDIT")
		grep -qF "THIRD_PARTY_NOTICES" "$repo_dir/$file" \
			|| [[ "$file" == THIRD_PARTY_NOTICES.md ]] \
			|| problems+=("$file does not point to THIRD_PARTY_NOTICES.txt")
	done

	if [[ ${#problems[@]} -gt 0 ]]; then
		printf 'release-artifacts.sh: %s\n' "${problems[@]}" >&2
		die "licence check failed (Odin root $odin_root)"
	fi
	log_step "Licence sources present for the server, Linux client, and Windows client"
}

# Copies ARTIFACT's notices and licence files into DIR (created if needed).
stage_licences() {
	local artifact=$1 dest=$2 problems entry source path
	# Validated here because licence_table runs in a subshell below, where die cannot stop us.
	case "$artifact" in
		server | linux | windows) ;;
		*) die "unknown artifact: $artifact (server, linux, or windows)" ;;
	esac
	problems=$(licence_table_problems "$artifact")
	[[ -z "$problems" ]] || die "$problems"
	while IFS= read -r entry; do
		source=${entry%:*}
		path=$(licence_source_path "$source")
		mkdir -p "$dest/$(dirname -- "${entry##*:}")"
		cp "$path" "$dest/${entry##*:}"
	done < <(licence_table "$artifact")
	if [[ "$artifact" == windows ]]; then
		# Like README.txt: CRLF line ends for Windows text editors.
		sed -i 's/$/\r/' "$dest/THIRD_PARTY_NOTICES.txt"
	fi
}

case "${1:-}" in
	--check-licences)
		[[ $# -eq 1 ]] || usage_error
		odin_root=$(resolve_odin_root)
		check_licences
		exit 0
		;;
	--stage-licences)
		[[ $# -eq 3 ]] || usage_error
		odin_root=$(resolve_odin_root)
		stage_licences "$2" "$3"
		log_step "Staged the $2 notices and licences in $3"
		exit 0
		;;
esac

[[ $# -ge 2 && $# -le 3 ]] || usage_error
version=$1
out_dir=$2
build_windows=false
if [[ $# -eq 3 ]]; then
	[[ "$3" == "--windows" ]] || die "unknown option: $3"
	build_windows=true
fi
[[ "$version" =~ ^[A-Za-z0-9._-]+$ ]] || die "VERSION may use letters, digits, . _ -"

command -v odin >/dev/null 2>&1 || die "odin is not on PATH (run inside ./dev.sh shell)"
odin_root=$(resolve_odin_root)
# Fail before a long build, so a toolchain pin bump can never drop a licence silently.
check_licences
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

# ── Server ────────────────────────────────────────────────────────

log_step "Building the server"
server_dir="$work_dir/haychat-server-$version"
mkdir -p "$server_dir/sql"
odin build server -o:speed -out:"$server_dir/haychat-server"
stage_licences server "$server_dir"
cp deploy/README.md "$server_dir/DEPLOY.md"
cp .env.example "$server_dir/env.example"
cp server/sql/auth_bootstrap.sql deploy/sql/make-admin.sql deploy/sql/create-invite.sql \
	deploy/sql/set-registration-mode.sql deploy/sql/set-restricted.sql \
	deploy/sql/attachment-usage.sql deploy/sql/remove-attachment.sql "$server_dir/sql/"
tar -C "$work_dir" -czf "$out_dir/haychat-server-$version-linux-x86_64.tar.gz" \
	"haychat-server-$version"

# ── Linux client ──────────────────────────────────────────────────

log_step "Building the Linux client"
linux_dir="$work_dir/haychat-$version-linux"
mkdir -p "$linux_dir"
odin build client -o:speed -out:"$linux_dir/haychat-client"
# The echo canceller's wrapper (#171), next to the client, which loads it from there.
"$repo_dir/deploy/build-linux-webrtc-apm.sh" "$linux_dir"
stage_licences linux "$linux_dir"
sed "s/@VERSION@/$version/g" deploy/client-README-linux.txt >"$linux_dir/README.txt"
tar -C "$work_dir" -czf "$out_dir/haychat-client-$version-linux-x86_64.tar.gz" \
	"haychat-$version-linux"

# ── Windows client ────────────────────────────────────────────────

fetch_sdl_lfs_files() {
	local sdl_dir="$odin_root/vendor/sdl3"
	if ! is_lfs_pointer "$sdl_dir/SDL3.dll" && ! is_lfs_pointer "$sdl_dir/SDL3.lib" \
		&& ! is_lfs_pointer "$sdl_dir/ttf/SDL3_ttf.dll" \
		&& ! is_lfs_pointer "$sdl_dir/ttf/SDL3_ttf.lib" \
		&& ! is_lfs_pointer "$sdl_dir/mixer/libopus-0.dll"; then
		return 0
	fi
	command -v git-lfs >/dev/null 2>&1 \
		|| die "$sdl_dir holds Git LFS pointers; install git-lfs (dnf install git-lfs)"
	log_step "Fetching SDL3 and libopus Windows libraries from Git LFS"
	git -C "$odin_root" lfs install --local >/dev/null
	local include="vendor/sdl3/SDL3.dll,vendor/sdl3/SDL3.lib"
	include+=",vendor/sdl3/ttf/SDL3_ttf.dll,vendor/sdl3/ttf/SDL3_ttf.lib"
	include+=",vendor/sdl3/mixer/libopus-0.dll"
	git -C "$odin_root" lfs pull --include "$include"
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
	# libopus-0.dll is the copy Odin ships for SDL3_mixer. The client loads it at runtime for
	# voice, looking next to haychat-client.exe first (client/opus).
	cp "$odin_root/vendor/sdl3/SDL3.dll" "$odin_root/vendor/sdl3/ttf/SDL3_ttf.dll" \
		"$odin_root/vendor/sdl3/mixer/libopus-0.dll" "$windows_dir/"
	# rnnoise.dll (noise suppression, #170) is built from the pinned RNNoise source release
	# with the same sysroot. The client loads it at runtime, next to haychat-client.exe first.
	"$repo_dir/deploy/build-windows-rnnoise.sh" "$sysroot" "$windows_dir"
	# haychat-webrtc-apm.dll (echo cancellation, #171): webrtc-audio-processing and abseil
	# from their pinned source releases, linked statically with HayChat's wrapper.
	"$repo_dir/deploy/build-windows-webrtc-apm.sh" "$sysroot" "$windows_dir"
	stage_licences windows "$windows_dir"
	sed "s/@VERSION@/$version/g" deploy/client-README-windows.txt \
		| sed 's/$/\r/' >"$windows_dir/README.txt"
	rm -f "$out_dir/haychat-client-$version-windows-x86_64.zip"
	make_zip "$out_dir/haychat-client-$version-windows-x86_64.zip" "$windows_dir"
fi

(cd "$out_dir" && sha256sum haychat-*"-$version-"* >SHA256SUMS)
log_step "Release archives in $out_dir:"
cat "$out_dir/SHA256SUMS"
