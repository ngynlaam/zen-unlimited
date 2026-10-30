#!/usr/bin/env bash
# tests/test-issue-10.sh — TDD seam tests for ngynlaam/zen-unlimited#10.
# Seams only: `bin/zen auto --once` CLI + signal log file. Fake STATE_DIR,
# fake rotator (warp-cli never runs). Rounds share one state dir so parks
# build up; each round feeds fixture lines for one model and reads rc plus
# the rotator call count. No private names asserted.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
ZEN="$REPO/bin/zen"
PASS=0; FAIL=0
. "$(dirname "$0")/helper.sh"

export ZEN_FREE_MODELS="hot-model calm-model"
hermetic_case "issue-10"

# round <model> <n> — feed n fresh 429 lines, run one decision round, print rc.
round() {
  local m=$1 n=$2 i
  for ((i=1; i<=n; i++)); do
    echo "2026-10-07T19:00:0$i $m 429 rate limit exceeded retry-after 5" >> "$SIG"
  done
  timeout 30 "$ZEN" auto --once >/dev/null 2>&1
  echo $?
}
calls() { grep -c . "$CASE_DIR/rot.log" 2>/dev/null || echo 0; }


rc=$(round hot-model 3)
check "hot first burst rotates" 0 "$rc"
check "one rotator call" 1 "$(calls)"

rc=$(round hot-model 2)
check "hot second burst held by dedupe" 2 "$rc"
rc=$(round hot-model 2)
check "hot third burst held by dedupe" 2 "$rc"
rc=$(round hot-model 2)
check "hot parked after repeated windows" 2 "$rc"
check "park caused no extra rotate" 1 "$(calls)"

rc=$(round calm-model 3)
check "calm rotates while hot parked" 0 "$rc"
check "calm rotate called rotator" 2 "$(calls)"

rc=$(round hot-model 2)
check "hot still parked after calm rotate" 2 "$rc"
check "hot hold caused no rotate" 2 "$(calls)"

rm -rf /tmp/opencode/issue-10.*
suite_done "issue-10"
