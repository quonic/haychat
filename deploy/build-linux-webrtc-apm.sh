#!/usr/bin/env bash
set -euo pipefail

# Builds libhaychat-webrtc-apm.so, the Linux client's echo canceller (#171, client/webrtcapm):
# HayChat's small C wrapper (client/webrtcapm/native) linked against the system's
# webrtc-audio-processing 2.x (pkg-config webrtc-audio-processing-2; Fedora's
# webrtc-audio-processing-devel). The client loads it at runtime, next to haychat-client first,
# so a system without webrtc-audio-processing 2.x keeps voice, without echo cancellation.
#
# Usage: deploy/build-linux-webrtc-apm.sh OUT_DIR
#
# Linked against the system library rather than a bundled copy: it is the library PipeWire's
# echo-cancel module uses, so desktops that run PipeWire's WebRTC echo canceller already have
# it, it gets the distribution's fixes, and the wrapper builds in seconds. The wrapper uses
# only the library's C++ API, whose types are std:: ones (std::optional in the statistics), so
# it does not depend on the abseil version the library was built with.

repo_dir=$(cd -- "$(dirname -- "$0")/.." >/dev/null 2>&1 && pwd)

die() {
	echo "build-linux-webrtc-apm.sh: $*" >&2
	exit 1
}

[[ $# -eq 1 ]] || die "usage: deploy/build-linux-webrtc-apm.sh OUT_DIR"
out_dir=$1
cxx=${CXX:-}
if [[ -z "$cxx" ]]; then
	for candidate in clang++ g++ c++; do
		if command -v "$candidate" >/dev/null 2>&1; then
			cxx=$candidate
			break
		fi
	done
fi
[[ -n "$cxx" ]] || die "no C++ compiler (clang++, g++ or c++) on PATH"
command -v pkg-config >/dev/null 2>&1 || die "pkg-config is not on PATH"
pkg-config --exists 'webrtc-audio-processing-2 >= 2.0' \
	|| die "webrtc-audio-processing-2 (>= 2.0) development files are missing" \
		"(Fedora: dnf install webrtc-audio-processing-devel)"
version=$(pkg-config --modversion webrtc-audio-processing-2)
# The library's headers (and abseil's) as system headers, so their warnings stay out of ours.
read -r -a cflags <<<"$(pkg-config --cflags webrtc-audio-processing-2 | sed 's/-I/-isystem /g')"
read -r -a libs <<<"$(pkg-config --libs webrtc-audio-processing-2)"

src="$repo_dir/client/webrtcapm/native/haychat_webrtc_apm.cc"
mkdir -p "$out_dir"
"$cxx" -std=c++17 -O2 -fPIC -shared -fvisibility=hidden -fno-exceptions -fno-rtti \
	-Wall -Wextra -Wno-unused-parameter \
	"-DHAYCHAT_APM_BUILT_VERSION=\"$version\"" \
	"-ffile-prefix-map=$repo_dir/=" \
	"${cflags[@]}" -o "$out_dir/libhaychat-webrtc-apm.so" "$src" \
	-Wl,--no-undefined -Wl,-soname,libhaychat-webrtc-apm.so -Wl,--as-needed "${libs[@]}"

# Every export the client calls must be there (client/webrtcapm SYMBOL_NAMES).
nm_tool=nm
command -v nm >/dev/null 2>&1 || nm_tool=llvm-nm
exports=$("$nm_tool" -D --defined-only "$out_dir/libhaychat-webrtc-apm.so")
for name in haychat_apm_abi_version haychat_apm_built_version haychat_apm_create \
	haychat_apm_destroy haychat_apm_apply_config haychat_apm_reset haychat_apm_process_render \
	haychat_apm_process_capture haychat_apm_set_stream_delay_ms haychat_apm_get_stats; do
	grep -q " T $name\$" <<<"$exports" || die "libhaychat-webrtc-apm.so does not export $name"
done
echo "==> libhaychat-webrtc-apm.so (webrtc-audio-processing $version): $out_dir" >&2
