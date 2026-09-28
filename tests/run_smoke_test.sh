#!/bin/bash
# Smoke-test an installed xezim-bin tree.
#
# Usage: XEZIM_PREFIX=<unpacked xezim/ dir> tests/run_smoke_test.sh
#   (or with xezim on PATH and XEZIM_PREFIX unset: the prefix is derived from it)
# Optional: EXPECT_TAG=<upstream tag> -- `xezim -V` must name it.
#
# Covers what packaging can break, not simulator semantics (upstream's own suite
# does that): the binary runs and carries its build stamp, the shipped include/
# compiles DPI code that xezim can load, the bundled UVM elaborates and runs
# with UVM's DPI-C served natively, and sv-parse runs.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$SCRIPT_DIR/smoke_test_work"

if [ -z "${XEZIM_PREFIX:-}" ]; then
    XEZIM_PREFIX="$(cd "$(dirname "$(command -v xezim)")/.." && pwd)"
fi
XEZIM="$XEZIM_PREFIX/bin/xezim"
[ -x "$XEZIM" ] || { echo "ERROR: $XEZIM not found" >&2; exit 1; }

rm -rf "$WORK"; mkdir -p "$WORK"; cd "$WORK"

fail() { echo "FAIL: $*" >&2; [ -f out.log ] && cat out.log >&2; exit 1; }

# Some platforms have no `timeout` (macOS); the tests all finish in seconds.
run() { if command -v timeout >/dev/null 2>&1; then timeout 300 "$@"; else "$@"; fi; }

echo "=== 1. version stamp"
"$XEZIM" -V | tee out.log
grep -q unknown out.log && fail "build stamp missing (git not visible at build time?)"
if [ -n "${EXPECT_TAG:-}" ]; then
    grep -qF "$EXPECT_TAG" out.log || fail "-V does not name tag $EXPECT_TAG"
fi

echo "=== 2. hello world"
run "$XEZIM" "$SCRIPT_DIR/smoke.sv" > out.log 2>&1 || fail "xezim exited $?"
grep -q "Hello World" out.log || fail "no 'Hello World' in output"

echo "=== 3. DPI-C via shipped include/"
cc -shared -fPIC -I "$XEZIM_PREFIX/include" "$SCRIPT_DIR/dpi/dpi_add.c" -o dpi_add.so
run "$XEZIM" --dpi-lib ./dpi_add.so "$SCRIPT_DIR/dpi/dpi_smoke.sv" > out.log 2>&1 || fail "xezim exited $?"
grep -q "DPI OK" out.log || fail "DPI call did not return 42"

echo "=== 4. bundled UVM"
UVM="$XEZIM_PREFIX/share/uvm"
run "$XEZIM" --simulate -s top -I "$UVM/src" "$UVM/src/uvm_pkg.sv" \
    "$SCRIPT_DIR/uvm/uvm_smoke.sv" > out.log 2>&1 || fail "xezim exited $?"
grep -q "UVM smoke test running" out.log || fail "UVM test did not run"
grep -qE "UVM_ERROR *: *0" out.log || fail "UVM reported errors"
grep -qE "UVM_FATAL *: *0" out.log || fail "UVM reported fatals"

echo "=== 5. sv-parse"
"$XEZIM_PREFIX/bin/sv-parse" "$SCRIPT_DIR/smoke.sv" > out.log 2>&1 || fail "sv-parse exited $?"

cd "$SCRIPT_DIR"; rm -rf "$WORK"
echo "=== Smoke test PASSED"
