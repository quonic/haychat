#!/usr/bin/env bash
set -euo pipefail

# Runs the compile checks and every test suite the way CI does. Tests fail on any memory
# leak or bad free, so ownership mistakes are caught before review.
#
# Usage: ./check.sh   (needs odin on PATH; `./dev.sh check` runs it in the dev container)

script_dir=$(cd -- "$(dirname -- "$0")" >/dev/null 2>&1 && pwd)
cd "$script_dir"

test_flags=(-define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true -define:ODIN_TEST_FANCY=false)

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

echo "==> odin test client/ui"
odin test client/ui "${test_flags[@]}"

# Router and database tests share process-wide state, so the server suite runs serially.
echo "==> odin test server"
odin test server "${test_flags[@]}" -define:ODIN_TEST_THREADS=1
