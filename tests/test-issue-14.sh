#!/usr/bin/env bash
# tests/test-issue-14.sh — TDD seam tests for ngynlaam/zen-unlimited#14.
# Seams only: `bin/zen auto --once` CLI + ledger R rows. Fake STATE_DIR and
# TWO fake adapters (never warp-cli): WARP_ROTATE=primary,
# ZEN_ROTATE_SECONDARY=secondary. Each fake logs its calls and exits its
# scripted code. No private names asserted: only rc, call logs, R-row path.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
ZEN="$REPO/bin/zen"
PASS=0; FAIL=0
. "$(dirname "$0")/helper.sh"

# fresh_case <primary_rc> <secondary_rc> — new fake state, scripted adapters.
fresh_case() {
  CASE_DIR=$(mktemp -d /tmp/opencode/issue-14.XXXXXX)
  export STATE_DIR=$CASE_DIR SIGNAL_DIR=$CASE_DIR/signals DB_FILE=$CASE_DIR/none.db
  export ROTATE_NOTIFY=0 ZEN_FREE_MODELS="m1"
  mkdir -p "$SIGNAL_DIR"
  { echo '#!/bin/sh'; echo "echo primary >> \"$CASE_DIR/calls.log\""; echo "exit $1"; } > "$CASE_DIR/primary"
  { echo '#!/bin/sh'; echo "echo secondary >> \"$CASE_DIR/calls.log\""; echo "exit $2"; } > "$CASE_DIR/secondary"
  chmod +x "$CASE_DIR/primary" "$CASE_DIR/secondary"
  export WARP_ROTATE=$CASE_DIR/primary ZEN_ROTATE_SECONDARY=$CASE_DIR/secondary
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

rpath() { awk -F'\t' '/^R/{print $9}' "$CASE_DIR/rotations.tsv" 2>/dev/null || echo none; }
called() { grep -cx "$1" "$CASE_DIR/calls.log" 2>/dev/null || true; }

# A. Dead primary fails over to secondary; the row notes the path.
fresh_case 1 0
feed m1 3
timeout 30 "$ZEN" auto --once >/dev/null 2>&1; rc=$?
check "failover rotates" 0 "$rc"
check "primary attempted" 1 "$(called primary)"
check "secondary attempted" 1 "$(called secondary)"
check "row notes secondary" "secondary" "$(rpath)"

# B. Healthy primary stays; secondary never runs; the row notes primary.
fresh_case 0 0
feed m1 3
timeout 30 "$ZEN" auto --once >/dev/null 2>&1; rc=$?
check "healthy primary rotates" 0 "$rc"
check "primary ran" 1 "$(called primary)"
check "secondary never ran" 0 "$(called secondary)"
check "row notes primary" "primary" "$(rpath)"

# C. Both dead: no rotate, both adapters attempted.
fresh_case 1 1
feed m1 3
timeout 30 "$ZEN" auto --once >/dev/null 2>&1; rc=$?
check "both dead holds" 2 "$rc"
check "both adapters attempted" 2 "$(grep -c . "$CASE_DIR/calls.log" 2>/dev/null || true)"

rm -rf /tmp/opencode/issue-14.*
suite_done "issue-14"
