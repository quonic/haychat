#!/usr/bin/env bash
set -euo pipefail

# Builds rnnoise.dll, the Windows client's noise suppression library (#170, client/rnnoise),
# from the pinned RNNoise 0.2 source release. Like the client itself it is cross-built from
# Linux: clang-cl and lld-link (the dev image's clang and lld packages) against a Windows SDK
# and MSVC CRT in "winsysroot" layout. deploy/release-artifacts.sh --windows calls it with the
# sysroot it found or downloaded.
#
# Usage: deploy/build-windows-rnnoise.sh SYSROOT OUT_DIR
#
# The release tarball, unlike the git tag, carries src/rnnoise_data.c: the default model,
# compiled into the DLL (about 1.4 MB of weights), so no model file ships or loads at run time.
# x86 run-time CPU detection is on, as in Fedora's build, so the SSE4.1 and AVX2 kernels are
# used where the CPU has them. The CRT is linked statically (/MT): the DLL needs only the
# Universal CRT that Windows 10 and later include, not a Visual C++ redistributable.
#
# Reproducible: the tarball is checked against RNNOISE_SHA256 below, the sources and flags are
# fixed, and /Brepro leaves timestamps out of the objects and the DLL, so one clang and one
# sysroot give the same bytes every time (the script prints the DLL's sha256). The licence in
# the tarball must match deploy/licenses/rnnoise-COPYING.txt, which the archive ships.
#
# HAYCHAT_RNNOISE_CACHE keeps the downloaded tarball (default ~/.cache/haychat-rnnoise).

RNNOISE_VERSION=0.2
RNNOISE_SHA256=90fce4b00b9ff24c08dbfe31b82ffd43bae383d85c5535676d28b0a2b11c0d37
RNNOISE_URL="https://github.com/xiph/rnnoise/releases/download/v$RNNOISE_VERSION"
RNNOISE_URL+="/rnnoise-$RNNOISE_VERSION.tar.gz"

# The sources of librnnoise in the release's Makefile.am, with its x86 RTCD files.
RNNOISE_SOURCES=(
	src/denoise.c
	src/rnn.c
	src/pitch.c
	src/kiss_fft.c
	src/celt_lpc.c
	src/nnet.c
	src/nnet_default.c
	src/parse_lpcnet_weights.c
	src/rnnoise_data.c
	src/rnnoise_tables.c
	src/x86/x86_dnn_map.c
	src/x86/x86cpu.c
)
# The public API of include/rnnoise.h, exported by name.
RNNOISE_EXPORTS=(
	rnnoise_get_size
	rnnoise_get_frame_size
	rnnoise_init
	rnnoise_create
	rnnoise_destroy
	rnnoise_process_frame
	rnnoise_model_from_buffer
	rnnoise_model_from_file
	rnnoise_model_from_filename
	rnnoise_model_free
)

repo_dir=$(cd -- "$(dirname -- "$0")/.." >/dev/null 2>&1 && pwd)

die() {
	echo "build-windows-rnnoise.sh: $*" >&2
	exit 1
}

[[ $# -eq 2 ]] || die "usage: deploy/build-windows-rnnoise.sh SYSROOT OUT_DIR"
sysroot=$1
out_dir=$2
[[ -d "$sysroot/VC" ]] || die "SYSROOT has no VC directory: $sysroot"
for tool in clang-cl lld-link llvm-readobj curl sha256sum tar; do
	command -v "$tool" >/dev/null 2>&1 || die "$tool is not on PATH"
done

cache=${HAYCHAT_RNNOISE_CACHE:-$HOME/.cache/haychat-rnnoise}
tarball="$cache/rnnoise-$RNNOISE_VERSION.tar.gz"
mkdir -p "$cache"
if [[ ! -f "$tarball" ]] || ! echo "$RNNOISE_SHA256  $tarball" | sha256sum -c --quiet - 2>/dev/null
then
	echo "==> Downloading RNNoise $RNNOISE_VERSION" >&2
	curl -fsSL -o "$tarball.part" "$RNNOISE_URL"
	mv "$tarball.part" "$tarball"
fi
echo "$RNNOISE_SHA256  $tarball" | sha256sum -c --quiet - \
	|| die "the RNNoise download does not match the pinned checksum"

work_dir=$(mktemp -d -t haychat-rnnoise.XXXXXX)
trap 'rm -rf "$work_dir"' EXIT
tar -xzf "$tarball" -C "$work_dir"
src_dir="$work_dir/rnnoise-$RNNOISE_VERSION"
# sha256sum rather than cmp: the dev image has no diffutils.
[[ "$(sha256sum <"$src_dir/COPYING")" == \
	"$(sha256sum <"$repo_dir/deploy/licenses/rnnoise-COPYING.txt")" ]] \
	|| die "RNNoise's COPYING differs from deploy/licenses/rnnoise-COPYING.txt; update it"

# WIN32 + RNNOISE_BUILD + DLL_EXPORT make include/rnnoise.h mark the API dllexport; the .def
# file below names it as well, so nothing else is exported.
cflags=(
	--target=x86_64-pc-windows-msvc
	/winsysroot "$sysroot"
	/nologo /c /O2 /MT /Brepro /W0
	/DNDEBUG /DWIN32 /DRNNOISE_BUILD /DDLL_EXPORT
	/DRNN_ENABLE_X86_RTCD
	"/I$src_dir/include" "/I$src_dir/src"
	"/clang:-ffile-prefix-map=$src_dir=rnnoise-$RNNOISE_VERSION"
)
objects=()
compile() {
	local source=$1
	shift
	local object="$work_dir/obj/${source//\//_}.obj"
	mkdir -p "$work_dir/obj"
	# `--` ends the options, so a path that starts like a clang-cl option (/wo..., /U...)
	# stays a source file.
	clang-cl "${cflags[@]}" "$@" "/Fo$object" -- "$src_dir/$source"
	objects+=("$object")
}
echo "==> Compiling RNNoise $RNNOISE_VERSION for Windows (x86-64)" >&2
for source in "${RNNOISE_SOURCES[@]}"; do
	compile "$source"
done
compile src/x86/nnet_sse4_1.c /clang:-msse4.1
compile src/x86/nnet_avx2.c /clang:-mavx /clang:-mfma /clang:-mavx2

{
	echo "LIBRARY rnnoise.dll"
	echo "EXPORTS"
	printf '\t%s\n' "${RNNOISE_EXPORTS[@]}"
} >"$work_dir/rnnoise.def"
mkdir -p "$out_dir"
lld-link /nologo /dll /machine:x64 /Brepro /opt:ref /opt:icf "/winsysroot:$sysroot" \
	"/def:$work_dir/rnnoise.def" "/out:$work_dir/rnnoise.dll" "/implib:$work_dir/rnnoise.lib" \
	"${objects[@]}"

# Every export the client calls must be there (client/rnnoise SYMBOL_NAMES).
exports=$(llvm-readobj --coff-exports "$work_dir/rnnoise.dll")
for name in "${RNNOISE_EXPORTS[@]}"; do
	grep -q "Name: $name\$" <<<"$exports" || die "rnnoise.dll does not export $name"
done
cp "$work_dir/rnnoise.dll" "$out_dir/rnnoise.dll"
echo "==> rnnoise.dll: $(sha256sum "$out_dir/rnnoise.dll" | cut -d' ' -f1)" >&2
