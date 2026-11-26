#!/usr/bin/env bash
set -euo pipefail

# Builds haychat-webrtc-apm.dll, the Windows client's echo canceller and noise suppressor
# (#171, client/webrtcapm): HayChat's C wrapper (client/webrtcapm/native) linked statically
# with webrtc-audio-processing 2.1 (WebRTC's audio processing module, AEC3) and the abseil it
# needs, built from their pinned source releases. Like the client and rnnoise.dll it is
# cross-built from Linux: Meson drives clang-cl, llvm-lib and lld-link (the dev image's clang,
# llvm, lld, meson and ninja-build packages) against a Windows SDK and MSVC CRT in
# "winsysroot" layout. deploy/release-artifacts.sh --windows calls it with the sysroot it found
# or downloaded.
#
# Usage: deploy/build-windows-webrtc-apm.sh SYSROOT OUT_DIR
#
# Sources: the webrtc-audio-processing release tarball (checked against WEBRTC_APM_SHA256)
# and, from its subprojects/abseil-cpp.wrap, the abseil release tarball and Meson WrapDB patch
# (checked against the pins below, which must equal the wrap file's own hashes). Meson runs
# with --wrap-mode=nodownload, so nothing else is fetched. Two edits to the extracted source,
# both checked: matched_filter_avx2.cc reads vector lanes MSVC's way under _MSC_VER, which
# clang-cl also defines but does not support (clang's vector subscripts work there), and
# WEBRTC_ENABLE_SYMBOL_EXPORT is dropped so the static objects carry no dllexport and the DLL
# exports only the wrapper's functions (the .def file below).
#
# Static CRT (/MT) as for rnnoise.dll: the DLL needs only Windows' own DLLs (KERNEL32, WINMM),
# not a Visual C++ redistributable. Reproducible: the sources and flags are fixed, the build
# tree has the same layout every time, and /Brepro leaves timestamps out of the objects and the
# DLL, so one clang and one sysroot give the same bytes (the script prints the DLL's sha256).
# The licences in the sources must match the copies in deploy/licenses/, which the archive
# ships.
#
# HAYCHAT_WEBRTC_APM_CACHE keeps the downloads (default ~/.cache/haychat-webrtc-apm).

WEBRTC_APM_VERSION=2.1
WEBRTC_APM_SHA256=ae9302824b2038d394f10213cab05312c564a038434269f11dbf68f511f9f9fe
WEBRTC_APM_URL="https://freedesktop.org/software/pulseaudio/webrtc-audio-processing"
WEBRTC_APM_URL+="/webrtc-audio-processing-$WEBRTC_APM_VERSION.tar.xz"
ABSEIL_VERSION=20240722.0
ABSEIL_SHA256=f50e5ac311a81382da7fa75b97310e4b9006474f9560ac46f54a9967f07d4ae3
ABSEIL_URL="https://github.com/abseil/abseil-cpp/releases/download/$ABSEIL_VERSION"
ABSEIL_URL+="/abseil-cpp-$ABSEIL_VERSION.tar.gz"
ABSEIL_PATCH=abseil-cpp_20240722.0-3_patch.zip
ABSEIL_PATCH_SHA256=12dd8df1488a314c53e3751abd2750cf233b830651d168b6a9f15e7d0cf71f7b
ABSEIL_PATCH_URL="https://wrapdb.mesonbuild.com/v2/abseil-cpp_20240722.0-3/get_patch"

# The wrapper's C API (client/webrtcapm SYMBOL_NAMES), exported by name.
APM_EXPORTS=(
	haychat_apm_abi_version
	haychat_apm_built_version
	haychat_apm_create
	haychat_apm_destroy
	haychat_apm_apply_config
	haychat_apm_reset
	haychat_apm_process_render
	haychat_apm_process_capture
	haychat_apm_set_stream_delay_ms
	haychat_apm_get_stats
)
# The licences of what the DLL contains, as SOURCE (in the extracted tree):COPY (in
# deploy/licenses/). The third-party files of WebRTC's tree are checked as one concatenation.
WEBRTC_THIRD_PARTY_LICENCES=(
	webrtc/common_audio/third_party/ooura/LICENSE
	webrtc/common_audio/third_party/spl_sqrt_floor/LICENSE
	webrtc/modules/third_party/fft/LICENSE
	webrtc/third_party/pffft/LICENSE
	webrtc/third_party/rnnoise/COPYING
)

repo_dir=$(cd -- "$(dirname -- "$0")/.." >/dev/null 2>&1 && pwd)
licence_dir="$repo_dir/deploy/licenses"

die() {
	echo "build-windows-webrtc-apm.sh: $*" >&2
	exit 1
}

[[ $# -eq 2 ]] || die "usage: deploy/build-windows-webrtc-apm.sh SYSROOT OUT_DIR"
sysroot=$(cd -- "$1" && pwd)
out_dir=$2
[[ -d "$sysroot/VC" ]] || die "SYSROOT has no VC directory: $sysroot"
for tool in clang-cl lld-link llvm-lib llvm-readobj meson ninja curl sha256sum tar python3; do
	command -v "$tool" >/dev/null 2>&1 || die "$tool is not on PATH"
done

cache=${HAYCHAT_WEBRTC_APM_CACHE:-$HOME/.cache/haychat-webrtc-apm}
mkdir -p "$cache"

# fetch URL FILE SHA256: downloads into the cache unless a file with that hash is there.
fetch() {
	local url=$1 file="$cache/$2" sha=$3
	if [[ ! -f "$file" ]] || ! echo "$sha  $file" | sha256sum -c --quiet - 2>/dev/null; then
		echo "==> Downloading $2" >&2
		curl -fsSL -o "$file.part" "$url"
		mv "$file.part" "$file"
	fi
	echo "$sha  $file" | sha256sum -c --quiet - \
		|| die "the download of $2 does not match the pinned checksum"
}
fetch "$WEBRTC_APM_URL" "webrtc-audio-processing-$WEBRTC_APM_VERSION.tar.xz" "$WEBRTC_APM_SHA256"
fetch "$ABSEIL_URL" "abseil-cpp-$ABSEIL_VERSION.tar.gz" "$ABSEIL_SHA256"
fetch "$ABSEIL_PATCH_URL" "$ABSEIL_PATCH" "$ABSEIL_PATCH_SHA256"

work_dir=$(mktemp -d -t haychat-webrtc-apm.XXXXXX)
trap 'rm -rf "$work_dir"' EXIT
# A fixed layout under work_dir: Meson's relative source paths (../src/...) are then the same
# in every build.
mkdir -p "$work_dir/src"
tar -xJf "$cache/webrtc-audio-processing-$WEBRTC_APM_VERSION.tar.xz" -C "$work_dir/src"
src_dir="$work_dir/src/webrtc-audio-processing-$WEBRTC_APM_VERSION"

# The wrap file must name exactly the abseil pinned here.
wrap="$src_dir/subprojects/abseil-cpp.wrap"
grep -qx "source_hash = $ABSEIL_SHA256" "$wrap" || die "abseil-cpp.wrap names another abseil"
grep -qx "patch_hash = $ABSEIL_PATCH_SHA256" "$wrap" \
	|| die "abseil-cpp.wrap names another WrapDB patch"
mkdir -p "$src_dir/subprojects/packagecache"
cp "$cache/abseil-cpp-$ABSEIL_VERSION.tar.gz" "$cache/$ABSEIL_PATCH" \
	"$src_dir/subprojects/packagecache/"

# Licences (sha256sum rather than cmp: the dev image has no diffutils).
same_file() {
	[[ "$(sha256sum <"$1")" == "$(sha256sum <"$2")" ]]
}
same_file "$src_dir/webrtc/LICENSE" "$licence_dir/webrtc-LICENSE.txt" \
	|| die "WebRTC's LICENSE differs from deploy/licenses/webrtc-LICENSE.txt"
same_file "$src_dir/webrtc/PATENTS" "$licence_dir/webrtc-PATENTS.txt" \
	|| die "WebRTC's PATENTS differs from deploy/licenses/webrtc-PATENTS.txt"
for path in "${WEBRTC_THIRD_PARTY_LICENCES[@]}"; do
	printf '==> %s\n\n' "${path#webrtc/}"
	cat "$src_dir/$path"
	printf '\n'
done >"$work_dir/third-party.txt"
same_file "$work_dir/third-party.txt" "$licence_dir/webrtc-third-party.txt" \
	|| die "WebRTC's third-party licences differ from" \
		"deploy/licenses/webrtc-third-party.txt; update it"
tar -xzf "$cache/abseil-cpp-$ABSEIL_VERSION.tar.gz" -C "$work_dir" \
	"abseil-cpp-$ABSEIL_VERSION/LICENSE"
same_file "$work_dir/abseil-cpp-$ABSEIL_VERSION/LICENSE" "$licence_dir/abseil-LICENSE.txt" \
	|| die "abseil's LICENSE differs from deploy/licenses/abseil-LICENSE.txt"

# The two source edits (see the top of this file), each checked.
avx2="$src_dir/webrtc/modules/audio_processing/aec3/matched_filter_avx2.cc"
sed -i 's/^#ifdef _MSC_VER$/#if defined(_MSC_VER) \&\& !defined(__clang__)/' "$avx2"
grep -q '^#if defined(_MSC_VER) && !defined(__clang__)$' "$avx2" \
	|| die "matched_filter_avx2.cc changed; re-check its _MSC_VER lane access"
sed -i "/'-DWEBRTC_ENABLE_SYMBOL_EXPORT',/d" "$src_dir/meson.build"
! grep -q "WEBRTC_ENABLE_SYMBOL_EXPORT" "$src_dir/meson.build" \
	|| die "meson.build still sets WEBRTC_ENABLE_SYMBOL_EXPORT"

# -fuse-ld=lld makes clang-cl link with lld-link itself: Meson 1.11 (the dev image) passes its
# own -fuse-ld after /link, where it does not reach the driver, which then looks for link.exe.
common_flags="'--target=x86_64-pc-windows-msvc', '-fuse-ld=lld', '/winsysroot', '$sysroot'"
cat >"$work_dir/cross.ini" <<EOF
[binaries]
c = ['clang-cl', $common_flags]
cpp = ['clang-cl', $common_flags]
c_ld = ['lld-link', '/winsysroot:$sysroot']
cpp_ld = ['lld-link', '/winsysroot:$sysroot']
ar = 'llvm-lib'

[built-in options]
c_args = ['/Brepro', '/clang:-ffile-prefix-map=$work_dir/=']
cpp_args = ['/Brepro', '/clang:-ffile-prefix-map=$work_dir/=']

[host_machine]
system = 'windows'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
EOF

echo "==> Building webrtc-audio-processing $WEBRTC_APM_VERSION for Windows (x86-64)" >&2
(
	cd "$work_dir"
	meson setup build "src/webrtc-audio-processing-$WEBRTC_APM_VERSION" \
		--cross-file cross.ini --wrap-mode=nodownload \
		-Dbuildtype=release -Db_ndebug=true -Db_vscrt=mt \
		-Ddefault_library=static -Dabseil-cpp:default_library=static >build-setup.log 2>&1 \
		|| { cat build-setup.log >&2; exit 1; }
	ninja -C build >build.log 2>&1 || { tail -40 build.log >&2; exit 1; }
)

echo "==> Linking haychat-webrtc-apm.dll" >&2
# `--` ends clang-cl's options: on Linux a source path such as /workspace/... (the CI
# checkout) otherwise reads as an option (/wo, "warn once") and the file is dropped.
clang-cl --target=x86_64-pc-windows-msvc /winsysroot "$sysroot" \
	/nologo /c /O2 /MT /Brepro /EHsc /std:c++17 /W3 \
	/DNDEBUG /DWEBRTC_WIN /DNOMINMAX "/DHAYCHAT_APM_BUILT_VERSION=\"$WEBRTC_APM_VERSION\"" \
	"/I$src_dir/webrtc" "/I$src_dir/subprojects/abseil-cpp-$ABSEIL_VERSION" \
	"/clang:-ffile-prefix-map=$repo_dir/=" \
	"/Fo$work_dir/haychat_webrtc_apm.obj" \
	-- "$repo_dir/client/webrtcapm/native/haychat_webrtc_apm.cc"
{
	echo "LIBRARY haychat-webrtc-apm.dll"
	echo "EXPORTS"
	printf '\t%s\n' "${APM_EXPORTS[@]}"
} >"$work_dir/haychat-webrtc-apm.def"
# Every static library of the build, in a fixed order.
mapfile -t libraries < <(cd "$work_dir" && find build -name '*.a' | LC_ALL=C sort)
(
	cd "$work_dir"
	lld-link /nologo /dll /machine:x64 /Brepro /opt:ref /opt:icf "/winsysroot:$sysroot" \
		/def:haychat-webrtc-apm.def /out:haychat-webrtc-apm.dll \
		/implib:haychat-webrtc-apm.lib haychat_webrtc_apm.obj "${libraries[@]}" winmm.lib
)

# Every export the client calls, and nothing else.
dll="$work_dir/haychat-webrtc-apm.dll"
exports=$(llvm-readobj --coff-exports "$dll")
for name in "${APM_EXPORTS[@]}"; do
	grep -q "Name: $name\$" <<<"$exports" || die "haychat-webrtc-apm.dll does not export $name"
done
count=$(grep -c "Name: " <<<"$exports")
[[ "$count" -eq ${#APM_EXPORTS[@]} ]] \
	|| die "haychat-webrtc-apm.dll exports $count names, not ${#APM_EXPORTS[@]}"
imports=$(llvm-readobj --coff-imports "$dll" | sed -n 's/^ *Name: \(.*\.dll\)$/\1/Ip' | sort -u)
mkdir -p "$out_dir"
cp "$dll" "$out_dir/haychat-webrtc-apm.dll"
echo "==> haychat-webrtc-apm.dll: $(sha256sum "$dll" | cut -d' ' -f1)," \
	"$(stat -c %s "$dll") bytes, imports $(tr '\n' ' ' <<<"$imports")" >&2
