#!/usr/bin/env bash
# tests/test-issue-12.sh — TDD seam tests for ngynlaam/zen-unlimited#12.
# Seams only: `bin/zen auto --once` CLI + signal log + stream flag file.
# Fake STATE_DIR, fake rotator (warp-cli never runs). The stream-open signal
# is a flag file the tests own ($STATE_DIR/stream_open unless ZEN_STREAM_FILE
# overrides). No private names asserted: only rc, rotator calls, log lines.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
ZEN="$REPO/bin/zen"
PASS=0; FAIL=0
. "$(dirname "$0")/helper.sh"

fresh_case() {
  CASE_DIR=$(mktemp -d /tmp/opencode/issue-12.XXXXXX)
  export STATE_DIR=$CASE_DIR SIGNAL_DIR=$CASE_DIR/signals DB_FILE=$CASE_DIR/none.db
  export ROTATE_NOTIFY=0 ZEN_FREE_MODELS="m1" ZEN_STREAM_FILE=$CASE_DIR/stream_open
  unset ZEN_DRAIN_S
  mkdir -p "$SIGNAL_DIR"
  FAKE_ROT=$CASE_DIR/fake-rotator
  { echo '#!/bin/sh'; echo "echo rotated >> \"$CASE_DIR/rot.log\""; echo 'exit 0'; } > "$FAKE_ROT"
  chmod +x "$FAKE_ROT"
  export WARP_ROTATE=$FAKE_ROT
  SIG=$SIGNAL_DIR/zen-quota.log
  echo "2026-10-07T18:00:00 history-model 429 rate limit exceeded" > "$SIG"
  timeout 30 "$ZEN" auto --once >/dev/null 2>&1
}

feed() {
  local m=$1 n=$2 i
  for ((i=1; i<=n; i++)); do
    echo "2026-10-07T19:00:0$i $m 429 rate limit exceeded" >> "$SIG"
  done
}


# A. Mid-stream 429 defers (log line, no cut), then rotates after drain.
fresh_case
export ZEN_DRAIN_S=5
touch "$ZEN_STREAM_FILE"
feed m1 3
timeout 30 "$ZEN" auto --once >/dev/null 2>&1 &
ROTPID=$!
for ((i=1; i<=10; i++)); do
  grep -q "deferred: stream open" "$CASE_DIR/auto.log" 2>/dev/null && break
  sleep 1
done
check "mid-stream defers with log line" 1 "$(grep -c "deferred: stream open" "$CASE_DIR/auto.log" 2>/dev/null || true)"
check "no cut lands mid-stream" "absent" "$([ -f "$CASE_DIR/rot.log" ] && echo present || echo absent)"
rm -f "$ZEN_STREAM_FILE"
wait "$ROTPID"; rc=$?
check "deferred rotate runs after drain" 0 "$rc"
check "drain logged" 1 "$(grep -c "stream drained after" "$CASE_DIR/auto.log" 2>/dev/null || true)"
check "rotator called after drain" "present" "$([ -f "$CASE_DIR/rot.log" ] && echo present || echo absent)"

# B. Stream that never drains still rotates after the bounded timeout.
fresh_case
export ZEN_DRAIN_S=3
touch "$ZEN_STREAM_FILE"
feed m1 3
t0=$(date +%s)
timeout 30 "$ZEN" auto --once >/dev/null 2>&1; rc=$?
t1=$(date +%s)
check "timeout rotate runs" 0 "$rc"
check "timeout logged" 1 "$(grep -c "drain timeout after" "$CASE_DIR/auto.log" 2>/dev/null || true)"
el=$((t1 - t0))
if [ "$el" -ge 3 ] && [ "$el" -le 15 ]; then PASS=$((PASS+1)); echo "PASS: drain wait bounded (${el}s)";
else FAIL=$((FAIL+1)); echo "FAIL: drain wait bounded (want 3-15s, got ${el}s)"; fi

# C. No stream open: rotate path has no added wait.
fresh_case
feed m1 3
t0=$(date +%s)
timeout 30 "$ZEN" auto --once >/dev/null 2>&1; rc=$?
t1=$(date +%s)
check "no-stream rotates" 0 "$rc"
el=$((t1 - t0))
if [ "$el" -le 8 ]; then PASS=$((PASS+1)); echo "PASS: no-stream has no added wait (${el}s)";
else FAIL=$((FAIL+1)); echo "FAIL: no-stream has no added wait (want <=8s, got ${el}s)"; fi
check "no-stream never defers" 0 "$(grep -c "deferred: stream open" "$CASE_DIR/auto.log" 2>/dev/null || true)"

# D. Default drain (unset): stuck stream still rotates after ~1s, not 3s.
# Aggressive-grade: the default wait is 1s (13/13 timeouts, 0 clean drains).
fresh_case
unset ZEN_DRAIN_S
touch "$ZEN_STREAM_FILE"
feed m1 3
t0=$(date +%s)
timeout 30 "$ZEN" auto --once >/dev/null 2>&1; rc=$?
t1=$(date +%s)
check "default-drain timeout rotate runs" 0 "$rc"
check "default-drain waits 1s" 1 "$(grep -c "drain timeout after 1s" "$CASE_DIR/auto.log" 2>/dev/null || true)"
el=$((t1 - t0))
if [ "$el" -ge 1 ] && [ "$el" -le 12 ]; then PASS=$((PASS+1)); echo "PASS: default drain bounded (${el}s)";
else FAIL=$((FAIL+1)); echo "FAIL: default drain bounded (want 1-12s, got ${el}s)"; fi

rm -rf /tmp/opencode/issue-12.*
suite_done "issue-12"
