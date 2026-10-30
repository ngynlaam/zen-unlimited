#!/usr/bin/env bash
# tests/test-issue-11.sh — TDD seam tests for ngynlaam/zen-unlimited#11.
# Seams only: `bin/zen auto --once` CLI + signal log file. Fake STATE_DIR,
# fake rotator (warp-cli never runs). A held round must pause per the
# Retry-After hint (capped), or per the short fallback when hint is absent.
# Wall time of one --once round is the observable. No private names asserted.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
ZEN="$REPO/bin/zen"
PASS=0; FAIL=0
. "$(dirname "$0")/helper.sh"

CASE_DIR=$(mktemp -d /tmp/opencode/issue-11.XXXXXX)
export STATE_DIR=$CASE_DIR SIGNAL_DIR=$CASE_DIR/signals DB_FILE=$CASE_DIR/none.db
export ROTATE_NOTIFY=0 ZEN_FREE_MODELS="m1"
mkdir -p "$SIGNAL_DIR"
FAKE_ROT=$CASE_DIR/fake-rotator
{ echo '#!/bin/sh'; echo "echo rotated >> \"$CASE_DIR/rot.log\""; echo 'exit 0'; } > "$FAKE_ROT"
chmod +x "$FAKE_ROT"
export WARP_ROTATE=$FAKE_ROT
SIG=$SIGNAL_DIR/zen-quota.log
echo "2026-10-07T18:00:00 history-model 429 rate limit exceeded" > "$SIG"
timeout 30 "$ZEN" auto --once >/dev/null 2>&1

# round <hint> <n> — feed n fresh 429 lines (hint "" = absent, else retry-after
# value), run one round, print "rc elapsed_seconds".
round() {
  local hint=$1 n=$2 i line
  for ((i=1; i<=n; i++)); do
    if [ -n "$hint" ]; then line="2026-10-07T19:00:0$i m1 429 rate limit exceeded retry-after $hint";
    else line="2026-10-07T19:00:0$i m1 429 rate limit exceeded"; fi
    echo "$line" >> "$SIG"
  done
  local t0 t1 rc
  t0=$(date +%s)
  timeout 40 "$ZEN" auto --once >/dev/null 2>&1; rc=$?
  t1=$(date +%s)
  echo "$rc $((t1 - t0))"
}
calls() { grep -c . "$CASE_DIR/rot.log" 2>/dev/null || echo 0; }


read -r rc el < <(round "" 3)
check "first burst rotates" 0 "$rc"
check_range "rotate path does not wait" 0 8 "$el"

read -r rc el < <(round 30 2)
check "large hint held by dedupe" 2 "$rc"
check_range "large hint waits at most the cap" 9 20 "$el"

# Truncate so the next round carries no stale hint in the tail.
: > "$SIG"
read -r rc el < <(round "" 2)
check "missing hint held by dedupe" 2 "$rc"
# Fallback is 1s (was 3s): 0 retry-after hints in 326 signal lines and 0 in
# the plugin log, so the fallback binds on ~every backoff sleep.
check_range "missing hint waits fallback only" 0 4 "$el"

read -r rc el < <(round 0 2)
check "zero hint held by dedupe" 2 "$rc"
check_range "zero hint waits fallback only" 0 4 "$el"

check "holds never rotated" 1 "$(calls)"

# --- lone-429 guard in proxy mode: backoff first, rotate on the 2nd 429 ----
# Proxy-pool rotates never clear quota, so a lone proxy 429 must back off
# (rc 2, no rotator call, single-429 log line) and only the 2nd signal in the
# window may cut the tunnel. Fresh fake state, seeded proxy mode cache.
PCASE=$(mktemp -d /tmp/opencode/issue-11-proxy.XXXXXX)
export STATE_DIR=$PCASE SIGNAL_DIR=$PCASE/signals DB_FILE=$PCASE/none.db
export ROTATE_NOTIFY=0 ZEN_FREE_MODELS="m1"
mkdir -p "$SIGNAL_DIR"
{ echo '#!/bin/sh'; echo "echo rotated >> \"$PCASE/rot.log\""; echo 'exit 0'; } > "$PCASE/fake-rotator"
chmod +x "$PCASE/fake-rotator"
export WARP_ROTATE=$PCASE/fake-rotator
SIG=$SIGNAL_DIR/zen-quota.log
echo "2026-10-07T18:00:00 history-model 429 rate limit exceeded" > "$SIG"
echo "proxy $(date +%s)" > "$PCASE/mode_cache"
timeout 30 "$ZEN" auto --once >/dev/null 2>&1
pcalls() { grep -c . "$PCASE/rot.log" 2>/dev/null || echo 0; }

echo "2026-10-07T19:00:01 m1 429 rate limit exceeded" >> "$SIG"
timeout 40 "$ZEN" auto --once >/dev/null 2>&1; rc=$?
check "lone proxy 429 holds" 2 "$rc"
check "lone proxy 429 never rotates" 0 "$(pcalls)"
check "lone proxy 429 backs off" 1 "$(grep -c "single-429 backoff" "$PCASE/auto.log" 2>/dev/null || true)"

echo "proxy $(date +%s)" > "$PCASE/mode_cache"
echo "2026-10-07T19:00:02 m1 429 rate limit exceeded" >> "$SIG"
timeout 40 "$ZEN" auto --once >/dev/null 2>&1; rc=$?
check "second proxy 429 rotates" 0 "$rc"
check "second proxy 429 cuts once" 1 "$(pcalls)"

rm -rf /tmp/opencode/issue-11.*
suite_done "issue-11"
