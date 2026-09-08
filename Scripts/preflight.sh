#!/bin/bash
# Pre-merge gate: debug build, a FRESH release build, then the full test suite.
#
# Exists because a release-configuration warning shipped in v3.6.2 that nothing in the development
# loop could see: `swift build` and `swift test` are both DEBUG, and `-c release` is otherwise
# compiled only inside the packaging scripts.
#
# The release build uses its own throwaway scratch directory. An earlier version reused the
# package's existing release output and printed "0 warnings" having compiled NOTHING — the same
# false-confidence pattern this gate exists to catch, reproduced inside the gate. It never touches
# `.build/release`, which is a symlink into shared build output.
#
# Warnings are REPORTED, not fatal: making them fatal today would fail on a known-benign warning
# deliberately deferred to a maintenance PR, and a gate that must be bypassed on day one teaches
# people to bypass it.
set -uo pipefail

cd "$(dirname "$0")/.." || { echo "preflight: cannot cd to repo root — aborting"; exit 2; }
log=$(mktemp -t preflight) || { echo "preflight: mktemp failed — aborting"; exit 2; }
relscratch=$(mktemp -d -t preflight-release) || { echo "preflight: mktemp -d failed — aborting"; exit 2; }
trap 'rm -rf "$relscratch"' EXIT

echo "== 1/3  debug build =="
if ! swift build 2>&1 | tee "$log.debug"; then
    echo "   DEBUG BUILD FAILED — stopping now, not running the 30-minute suite"
    exit 1
fi
echo "   warnings emitted by the debug build: $(grep -cE 'warning:' "$log.debug")"

echo "== 2/3  RELEASE build, fresh scratch (the check that was missing) =="
if ! swift build -c release --scratch-path "$relscratch" 2>&1 | tee "$log.release"; then
    echo "   RELEASE BUILD FAILED — stopping now, not running the 30-minute suite"
    exit 1
fi
relwarn=$(grep -E "warning:" "$log.release" | sed 's/.*Sources/Sources/' | sort -u)
if [ -n "$relwarn" ]; then
    # "emitted by the release build" — reading this log cannot establish that a warning is
    # release-ONLY; that would need a comparison against the debug log's warnings.
    echo "   warnings emitted by the release build:"
    echo "$relwarn" | sed 's/^/     /'
else
    echo "   warnings emitted by the release build: 0"
fi

status=0
echo "== 3/3  full test suite (debug, INCREMENTAL) =="
# Not piped into grep: under `pipefail` a non-matching grep would mark the step failed, conflating
# "the suite failed" with "my pattern missed". Capture swift test's own status, then read the log.
swift test > "$log.test" 2>&1
test_status=$?
summary=$(grep -E "Executed [0-9]+ tests" "$log.test" | tail -1)
if [ -n "$summary" ]; then
    echo "  $summary"
else
    echo "   (no test-summary line found in the log — reporting the exit status instead)"
fi
if [ $test_status -ne 0 ]; then
    echo "   TEST SUITE FAILED (exit $test_status)"
    grep -E "error:" "$log.test" | sed 's/.*Tests\./     /' | cut -c1-140 | sort -u | head
    status=1
fi

skips=$(grep -E "skipped \(" "$log.test" | sed 's/.*Tests\.//' | sed 's/\].*//' | sort -u)
if [ -n "$skips" ]; then
    echo "   skipped (these did NOT run):"
    echo "$skips" | sed 's/^/     /'
else
    echo "   skipped: none"
fi
# Coverage of the memory measurement is read from its ACTUAL result, not assumed: it runs when
# LAS_RUN_MEMORY_TEST is set.
mem="testWatcherSteadyStateAndPeakOverlapResidentMemory"
if grep -qE "$mem.*' skipped" "$log.test"; then
    echo "   the watcher memory measurement was SKIPPED — no memory results from this run."
elif grep -qE "$mem.*' passed" "$log.test"; then
    echo "   the watcher memory measurement RAN and passed in this suite."
elif grep -qE "$mem.*' failed" "$log.test"; then
    echo "   the watcher memory measurement RAN and FAILED."
else
    echo "   the watcher memory measurement was not present in this run's output."
fi

echo
if [ $status -eq 0 ]; then
    echo "PREFLIGHT PASSED — review the release-build warnings above."
else
    echo "PREFLIGHT FAILED"
fi
exit $status
