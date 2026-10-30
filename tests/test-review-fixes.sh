#!/usr/bin/env bash
# tests/test-review-fixes.sh — seam tests for the code-review fix round.
# Seams only: `bin/zen auto --once` CLI + signal/ledger/log/DB files.
# Fake STATE_DIR, fake rotators (warp-cli never runs). Covers: daemon-owned
# stream producer (DB in-flight row), routing-table decision wiring
# (off-model refusal + path log), per-model egress override, DB model
# threading. No private names asserted.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
ZEN="$REPO/bin/zen"
PASS=0; FAIL=0
. "$(dirname "$0")/helper.sh"

mkcase() { # mkcase <models> — fresh fake state, fake rotator, seeded cursors.
  CASE_DIR=$(mktemp -d /tmp/opencode/review-fix.XXXXXX)
  export STATE_DIR=$CASE_DIR SIGNAL_DIR=$CASE_DIR/signals DB_FILE=$CASE_DIR/fix.db
  export ROTATE_NOTIFY=0 ZEN_FREE_MODELS="$1"
  unset ZEN_DRAIN_S ZEN_PATH_M1 ZEN_STREAM_FILE
  mkdir -p "$SIGNAL_DIR"
  sqlite3 "$DB_FILE" "CREATE TABLE IF NOT EXISTS session_message(session_id TEXT,type TEXT,data TEXT,time_created INTEGER);" 2>/dev/null || true
  FAKE_ROT=$CASE_DIR/fake-rotator
  { echo '#!/bin/sh'; echo "echo rotated >> \"$CASE_DIR/rot.log\""; echo 'exit 0'; } > "$FAKE_ROT"
  chmod +x "$FAKE_ROT"
  export WARP_ROTATE=$FAKE_ROT
  unset ZEN_ROTATE_SECONDARY
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

dbrow() { # dbrow <model-or-empty> <ms-epoch> — one quota row ({} when no model).
  local m=$1 ms=$2 data
  if [ -z "$m" ]; then data='{"error":{"type":"provider.quota"}}';
  else data="{\"model\":{\"providerID\":\"opencode\",\"id\":\"$m\"},\"error\":{\"type\":\"provider.quota\"}}"; fi
  sqlite3 "$DB_FILE" "CREATE TABLE IF NOT EXISTS session_message(session_id TEXT,type TEXT,data TEXT,time_created INTEGER);"
  sqlite3 "$DB_FILE" "INSERT INTO session_message VALUES('s1','assistant','$data',$ms);"
}

nowms() { date +%s000; }

# A. Daemon-owned stream producer: newest row in-flight defers the rotate.
mkcase "m1"
dbrow "" $(( $(nowms) - 3600000 ))
sqlite3 "$DB_FILE" "UPDATE session_message SET data='{\"finish\":\"stop\"}';"
dbrow "" $(( $(nowms) - 5000 ))
sqlite3 "$DB_FILE" "UPDATE session_message SET data='{}' WHERE time_created > $(( $(nowms) - 60000 ));"
feed m1 3
timeout 30 "$ZEN" auto --once >/dev/null 2>&1 &
ROTPID=$!
for ((i=1; i<=10; i++)); do
  grep -q "deferred: stream open" "$CASE_DIR/auto.log" 2>/dev/null && break
  sleep 1
done
check "db in-flight defers with log line" 1 "$(grep -c "deferred: stream open" "$CASE_DIR/auto.log" 2>/dev/null || true)"
check "no cut while db stream open" "absent" "$([ -f "$CASE_DIR/rot.log" ] && echo present || echo absent)"
sqlite3 "$DB_FILE" "UPDATE session_message SET data='{\"finish\":\"stop\"}' WHERE time_created > $(( $(nowms) - 60000 ));"
wait "$ROTPID"; rc=$?
check "rotate runs after db drain" 0 "$rc"

# A2. Control: finished latest row never defers.
mkcase "m1"
dbrow "" $(( $(nowms) - 5000 ))
sqlite3 "$DB_FILE" "UPDATE session_message SET data='{\"finish\":\"stop\"}';"
feed m1 3
t0=$(date +%s)
timeout 30 "$ZEN" auto --once >/dev/null 2>&1; rc=$?
t1=$(date +%s)
check "finished stream rotates" 0 "$rc"
check "finished stream never defers" 0 "$(grep -c "deferred: stream open" "$CASE_DIR/auto.log" 2>/dev/null || true)"
check_range "finished stream is fast" 0 8 "$((t1 - t0))"

# B. Routing wire: off-path model refused at decision, path logged per rotate.
mkcase "jev-1.13-free"
feed jev-1.13-free 3
timeout 30 "$ZEN" auto --once >/dev/null 2>&1; rc=$?
check "off-path model refused" 1 "$rc"
check "off-path never rotates" "absent" "$([ -f "$CASE_DIR/rot.log" ] && echo present || echo absent)"
# NOTE: the refusal holds at the detect layer too (is_free_model drops jev
# first); the decision-layer guard below is the second lock for the same rule.

mkcase "muse-spark-1.3-contributor-free"
feed muse-spark-1.3-contributor-free 3
timeout 30 "$ZEN" auto --once >/dev/null 2>&1; rc=$?
check "responses model rotates" 0 "$rc"
check "chosen path logged" 1 "$(grep -c "route path: responses for model muse-spark-1.3-contributor-free" "$CASE_DIR/auto.log" 2>/dev/null || true)"

# C. Per-model egress override selects the first-tried adapter.
mkcase "m1"
export ZEN_PATH_M1=secondary
{ echo '#!/bin/sh'; echo "echo primary >> \"$CASE_DIR/calls.log\""; echo 'exit 0'; } > "$CASE_DIR/primary"
{ echo '#!/bin/sh'; echo "echo secondary >> \"$CASE_DIR/calls.log\""; echo 'exit 0'; } > "$CASE_DIR/secondary"
chmod +x "$CASE_DIR/primary" "$CASE_DIR/secondary"
export WARP_ROTATE=$CASE_DIR/primary ZEN_ROTATE_SECONDARY=$CASE_DIR/secondary
feed m1 3
timeout 30 "$ZEN" auto --once >/dev/null 2>&1; rc=$?
check "override rotates" 0 "$rc"
check "override tries secondary first" 1 "$(grep -cx secondary "$CASE_DIR/calls.log" 2>/dev/null || true)"
check "primary never tried under override" 0 "$(grep -cx primary "$CASE_DIR/calls.log" 2>/dev/null || true)"
check "row notes override path" "secondary" "$(awk -F'\t' '/^R/{print $9}' "$CASE_DIR/rotations.tsv" 2>/dev/null || echo none)"

# D1. DB rows thread per-model keys: hot dedupe holds DB-driven signals too.
# HOOK_DEDUPE_WINDOW=0 isolates the DB path (else fresh signal lines would
# dismiss these rows as the same 429 — that orthogonal gate is unchanged).
export HOOK_DEDUPE_WINDOW=0
mkcase "hot-model"
feed hot-model 3
timeout 30 "$ZEN" auto --once >/dev/null 2>&1; rc=$?
check "signal rotate stamps hot dedupe" 0 "$rc"
dbrow hot-model "$(nowms)"; dbrow hot-model "$(nowms)"
timeout 30 "$ZEN" auto --once >/dev/null 2>&1; rc=$?
check "db rows honor hot dedupe" 2 "$rc"
check "no extra cut for held db rows" 1 "$(grep -c . "$CASE_DIR/rot.log" 2>/dev/null || true)"

# D2. Multi-model DB rows rotate once per model, reason carries the model.
mkcase "mA mB"
dbrow mA "$(nowms)"; dbrow mA "$(nowms)"; dbrow mB "$(nowms)"; dbrow mB "$(nowms)"
timeout 30 "$ZEN" auto --once >/dev/null 2>&1; rc=$?
check "db multi-model rotates" 0 "$rc"
check "mA row threaded" 1 "$(grep -c ":mA" "$CASE_DIR/rotations.tsv" 2>/dev/null || true)"
check "mB row threaded" 1 "$(grep -c ":mB" "$CASE_DIR/rotations.tsv" 2>/dev/null || true)"

# D3. Model-less DB rows fall back to legacy shared keys (bare reason).
mkcase "m1"
dbrow m1 "$(nowms)"; dbrow m1 "$(nowms)"; dbrow "" "$(nowms)"; dbrow "" "$(nowms)"
timeout 30 "$ZEN" auto --once >/dev/null 2>&1; rc=$?
check "mixed db rows rotate" 0 "$rc"
check "named row threaded" 1 "$(grep -c ":m1" "$CASE_DIR/rotations.tsv" 2>/dev/null || true)"
check "model-less row keeps bare reason" 1 "$(grep -c "429-signal(2)	" "$CASE_DIR/rotations.tsv" 2>/dev/null || true)"

rm -rf /tmp/opencode/review-fix.*
suite_done "review-fixes"
