#!/usr/bin/env bash
# tests/helper.sh — shared harness for tests/test-issue-*.sh.
# Sourced (never executed): provides check/check_range over the caller's
# PASS/FAIL counters plus a standard suite footer. Keeps the seam tests to
# outside behavior: feed fixture input, assert rc/files/stdout.
# shellcheck disable=SC2034
_T_HELPER_LOADED=1

check() { # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "PASS: $1";
  else FAIL=$((FAIL+1)); echo "FAIL: $1 (want [$2], got [$3])"; fi
}

check_range() { # check_range <name> <lo> <hi> <actual>
  if [ "$4" -ge "$2" ] && [ "$4" -le "$3" ]; then PASS=$((PASS+1)); echo "PASS: $1 ($4s)";
  else FAIL=$((FAIL+1)); echo "FAIL: $1 (want ${2}-${3}s, got ${4}s)"; fi
}

suite_done() { # suite_done <name> — footer; rc 0 iff no failures.
  echo "$1: pass=$PASS fail=$FAIL"
  [ "$FAIL" -eq 0 ]
}

# Hermetic fixture: hermetic_case <tag> — new tmp STATE_DIR/SIGNAL_DIR/DB,
# fake rotator (warp-cli never runs), seeded cursors, empty rotator log.
# Sets CASE_DIR, SIGNAL_DIR, SIG, FAKE_ROT. Caller owns cleanup
# (rm -rf "$CASE_DIR"); suites that need several cases track CASE_DIRS.
# Seams only: the caller feeds $SIG lines and runs `bin/zen auto --once`.
hermetic_case() { # hermetic_case <tag>
  mkdir -p /tmp/opencode
  CASE_DIR=$(mktemp -d /tmp/opencode/"$1".XXXXXX)
  export STATE_DIR=$CASE_DIR SIGNAL_DIR=$CASE_DIR/signals DB_FILE=$CASE_DIR/none.db
  export ROTATE_NOTIFY=0
  mkdir -p "$SIGNAL_DIR"
  FAKE_ROT=$CASE_DIR/fake-rotator
  { echo '#!/bin/sh'; echo "echo rotated \"\$@\" >> \"$CASE_DIR/rot.log\""; echo 'exit 0'; } > "$FAKE_ROT"
  chmod +x "$FAKE_ROT"
  export WARP_ROTATE=$FAKE_ROT
  SIG=$SIGNAL_DIR/zen-quota.log
  echo "2026-10-07T18:00:00 history-model 429 rate limit exceeded" > "$SIG"
  timeout 30 "$ZEN" auto --once >/dev/null 2>&1
}
