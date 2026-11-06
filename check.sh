#!/usr/bin/env bash
set -euo pipefail

# Runs the compile checks and every test suite the way CI does. Tests fail on any memory
# leak or bad free, so ownership mistakes are caught before review.
#
# Usage: ./check.sh   (needs odin on PATH; `./dev.sh check` runs it in the dev container)

script_dir=$(cd -- "$(dirname -- "$0")" >/dev/null 2>&1 && pwd)
cd "$script_dir"

test_flags=(-define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true -define:ODIN_TEST_FANCY=false)

# The Opus and voice engine tests skip when libopus cannot be loaded. CI must not skip them
# silently, so a missing libopus fails the suite here. HAYCHAT_REQUIRE_OPUS=0 allows the skip.
export HAYCHAT_REQUIRE_OPUS=${HAYCHAT_REQUIRE_OPUS:-1}

# Release archives and the server image must carry every licence their contents need. This
# needs only the Odin root, so a pin bump that drops or moves a licence file fails here.
echo "==> deploy/release-artifacts.sh --check-licences"
deploy/release-artifacts.sh --check-licences

echo "==> odin check server"
odin check server

echo "==> odin check client (linux_amd64)"
odin check client -target:linux_amd64

# Checking does not link, so the Windows target is verified from Linux.
echo "==> odin check client (windows_amd64)"
odin check client -target:windows_amd64

echo "==> odin test common"
odin test common "${test_flags[@]}"

echo "==> odin test client"
odin test client "${test_flags[@]}"

# The voice fault hook (client/voice_faults.odin) exists only in a HAYCHAT_TEST_FAULTS build,
# so its unit test runs in one; dev/voice-proof.sh exercises the hook end to end.
echo "==> odin test client (HAYCHAT_TEST_FAULTS, fault hook only)"
fault_tests=client.testVoiceReceiveFaultsAreAbsentFromNormalBuilds
fault_tests+=,client.testVoiceReceiveFaultsDropAndDelayDeterministically
odin test client "${test_flags[@]}" -define:HAYCHAT_TEST_FAULTS=true \
	-define:ODIN_TEST_NAMES="$fault_tests"

echo "==> odin test client/ui"
odin test client/ui "${test_flags[@]}"

echo "==> odin test client/toneanalysis"
odin test client/toneanalysis "${test_flags[@]}"

# The live voice proof's tone checker (dev/voice-proof.sh builds and runs it).
echo "==> odin test dev/tools/voice-check"
odin test dev/tools/voice-check "${test_flags[@]}"

# Router and database tests share process-wide state, so the server suite runs serially.
echo "==> odin test server"
odin test server "${test_flags[@]}" -define:ODIN_TEST_THREADS=1
