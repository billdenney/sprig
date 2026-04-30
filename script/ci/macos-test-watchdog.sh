#!/usr/bin/env bash
# script/ci/macos-test-watchdog.sh
#
# Run `swift test` under a watchdog so we can diagnose the intermittent
# macos-14 hang documented in SprigctlWatchTests + the post-PR-12
# main-branch CI run (24963305139, which ran 5h50m before timeout).
#
# Strategy
# --------
# 1. `swift test --no-parallel` writes its full output to test.log.
#    Swift-testing's realtime "◇ started / ✔ passed" markers ARE the
#    event stream — at hang time, the last `started` without a matching
#    close names the culprit test.
# 2. While `swift test` runs, the watchdog tracks elapsed time. At fixed
#    elapsed marks (3 / 6 / 9 / 12 min) it captures:
#      - `ps` snapshot of all swift-related processes
#      - last-running test extracted from test.log
#      - `sample <pid>` 3s stack-trace dumps for each xctest / swift-test
#        / SprigPackageTests process
#      - `lsof -p <pid>` for the same set (FSEvents shows up as kqueue
#        descriptors here)
#      - `fs_usage -e -f filesys` 2s capture (filesystem syscalls in flight)
# 3. At 13 min the watchdog terminates the test process so the runner
#    job's `timeout-minutes: 15` doesn't kill us first — that way the
#    "Upload diagnostics" step still gets to run with `if: always()`.
#
# Output: $DIAG_DIR is populated with everything above plus the test log;
# the workflow uploads it as an artifact regardless of pass/fail.
#
# Exit code: matches `swift test`'s, or 124 (timeout convention) if the
# watchdog had to terminate it.

set -uo pipefail

DIAG_DIR="${RUNNER_TEMP:-/tmp}/sprig-macos-diag"
mkdir -p "$DIAG_DIR"

TEST_LOG="$DIAG_DIR/test.log"

echo "==> Diagnostics directory: $DIAG_DIR"
echo "==> Swift test starting at $(date -u +%FT%TZ)"

# `swift test` defaults to --no-parallel; we pass it explicitly for clarity.
# Swift-testing emits realtime per-test markers to stdout:
#   ◇ Test "..." started.
#   ✔ Test "..." passed after 0.001 seconds.
# Those lines ARE our event stream — when a hang occurs, the last
# `◇ started` without a matching `✔/✘` line names the culprit.
swift test --no-parallel > "$TEST_LOG" 2>&1 &
TEST_PID=$!
echo "==> swift test pid=$TEST_PID"

capture_snapshot() {
    local tag="$1"
    local stamp; stamp="$(date -u +%H%M%S)"
    local prefix="$DIAG_DIR/${stamp}-${tag}"

    echo "[watchdog] capture_snapshot tag=$tag pid_pattern=swift-test|xctest|SprigPackageTests"

    # Last test that emitted a `◇ started` without a matching `✔ passed`
    # or `✘ failed` line. This is the most likely culprit when stalled.
    {
        echo "## Last 'started' lines (any without a matching close = suspect)"
        grep -E '^◇ Test ".*" started\.' "$TEST_LOG" 2>/dev/null | tail -10
        echo
        echo "## Last 'passed/failed' lines"
        grep -E '^[✔✘] Test ".*" (passed|failed)' "$TEST_LOG" 2>/dev/null | tail -10
        echo
        echo "## Tail of full log"
        tail -50 "$TEST_LOG" 2>/dev/null
    } > "${prefix}-test-progress.txt"

    ps -axfo pid,ppid,etime,stat,user,command \
        > "${prefix}-ps.txt" 2>/dev/null || true

    # PID list of the test runtime. We look for swift-test (the driver),
    # xctest (the harness on macOS), and SprigPackageTests (the actual
    # test bundle binary) — at least one is always running during a hang.
    local pids
    pids=$(pgrep -f 'swift-test|xctest|SprigPackageTests' 2>/dev/null | sort -u)

    for pid in $pids; do
        # 3-second sample is enough to capture wedged threads while not
        # adding meaningful CPU drag. `-mayDie` so we don't crash the
        # tracee if it's already in a bad state.
        sample "$pid" 3 -mayDie \
            > "${prefix}-sample-${pid}.txt" 2>/dev/null || true
        lsof -p "$pid" \
            > "${prefix}-lsof-${pid}.txt" 2>/dev/null || true
    done

    # 2-second filesystem-syscall trace; FSEvents-related stalls show
    # up as kevent / FSEvents-mach-port traffic on a watched-path PID.
    # Needs root on some macOS versions; suppress errors silently if
    # we don't have it.
    sudo -n fs_usage -w -e -t 2 -f filesys 2>/dev/null \
        > "${prefix}-fs_usage.txt" 2>/dev/null || true
}

ELAPSED=0
TICK=30
SNAPSHOT_AT=(180 360 540 720)
HARD_KILL_AT=780

while kill -0 "$TEST_PID" 2>/dev/null; do
    sleep $TICK
    ELAPSED=$(( ELAPSED + TICK ))
    echo "[watchdog] elapsed=${ELAPSED}s"

    for mark in "${SNAPSHOT_AT[@]}"; do
        if [ "$ELAPSED" -eq "$mark" ]; then
            capture_snapshot "tick${ELAPSED}"
        fi
    done

    if [ "$ELAPSED" -ge "$HARD_KILL_AT" ]; then
        echo "[watchdog] hard-kill: elapsed=${ELAPSED}s exceeds ${HARD_KILL_AT}s"
        capture_snapshot "prekill"
        kill "$TEST_PID" 2>/dev/null || true
        sleep 5
        kill -9 "$TEST_PID" 2>/dev/null || true
        wait "$TEST_PID" 2>/dev/null
        # Tail of the test log helps tie the event stream to the watchdog
        # timeline at a glance.
        tail -200 "$TEST_LOG" > "$DIAG_DIR/test-log-tail.txt" 2>/dev/null || true
        echo "==> Watchdog terminated the test run"
        exit 124
    fi
done

wait "$TEST_PID"
EXIT=$?
echo "==> swift test exited with $EXIT after ${ELAPSED}s"

# Always include a tail of the log + a final ps snapshot so the artifact
# is useful even on a healthy run.
tail -200 "$TEST_LOG" > "$DIAG_DIR/test-log-tail.txt" 2>/dev/null || true
ps -axfo pid,ppid,etime,stat,user,command > "$DIAG_DIR/final-ps.txt" 2>/dev/null || true

exit "$EXIT"
