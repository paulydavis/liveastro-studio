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
# SWIFT COMPILER warnings in the RELEASE build are FATAL, enforced by the compiler
# (-warnings-as-errors), not by matching the log. That flag reaches only swiftc's own diagnostics:
# SwiftPM, the linker and other tools can still emit warnings, which are reported, not fatal.
#
# Log matching would inherit every weakness this gate exists to avoid: it depends on message
# formatting, it cannot tell a real warning from the word "warning" in a path, and it reports clean
# when the step compiled nothing. Making the compiler the authority means a Swift warning is a
# build failure, which this script already stops on.
#
# This was enabled only once the tree was at zero warnings (the GlobalCombine `var it` cleanup).
# Turning it on earlier would have failed on day one, and a gate that must be bypassed immediately
# teaches people to bypass it.
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

echo "== 2/3  RELEASE build, fresh scratch, warnings are errors =="
if ! swift build -c release --scratch-path "$relscratch" -Xswiftc -warnings-as-errors 2>&1 | tee "$log.release"; then
    echo "   RELEASE BUILD FAILED — stopping now, not running the 30-minute suite"
    echo "   (warnings are errors here: a new warning fails this step by design)"
    exit 1
fi
relwarn=$(grep -E "warning:" "$log.release" | sed 's/.*Sources/Sources/' | sort -u)
if [ -n "$relwarn" ]; then
    # Reachable WITH the flag working: `-Xswiftc -warnings-as-errors` governs the Swift compiler's
    # diagnostics, and SwiftPM, the linker and other tools can emit warnings it does not reach.
    # So report the diagnostic and leave the cause to the reader — do not assert the flag failed.
    echo "   warnings reached this step despite -warnings-as-errors (which covers only the Swift"
    echo "   compiler; SwiftPM, the linker and other tools can also emit warnings):"
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
