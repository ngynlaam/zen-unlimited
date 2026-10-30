#!/usr/bin/env bash
# tests/test-issue-9.sh — TDD seam tests for ngynlaam/zen-unlimited#9.
# Seams only: `bin/zen auto --once` CLI + ledger/queue files. Fake STATE_DIR,
# fixture sqlite DB, no signals (WARP_ROTATE never reached). Outside behavior
# only: feed queue + DB rows, read V rows and report text.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
ZEN="$REPO/bin/zen"
PASS=0; FAIL=0
. "$(dirname "$0")/helper.sh"

# mkdb <file> <ms-epoch>... — fixture DB with one provider.quota row per epoch.
mkdb() {
  local f=$1; shift
  rm -f "$f"
  sqlite3 "$f" "CREATE TABLE session_message(session_id TEXT,type TEXT,data TEXT,time_created INTEGER);"
  local ms
  for ms in "$@"; do
    sqlite3 "$f" "INSERT INTO session_message VALUES('s1','assistant','{\"error\":{\"type\":\"provider.quota\"}}',$ms);"
  done
}

fresh_case() {
  CASE_DIR=$(mktemp -d /tmp/opencode/issue-9.XXXXXX)
  export STATE_DIR=$CASE_DIR SIGNAL_DIR=$CASE_DIR/signals DB_FILE=$CASE_DIR/fix.db
  export ROTATE_NOTIFY=0 WARP_ROTATE=/bin/true
  export ZEN_FREE_MODELS="muse-spark-1.3-contributor-free"
  unset OUTCOME_WINDOW_S
  mkdir -p "$SIGNAL_DIR"
}


NOW=$(date +%s)

# 1. New V rows count only the fixed window after the rotate (default 600s).
fresh_case
EP=$((NOW - 630))
mkdb "$DB_FILE" $(( (EP+10)*1000 )) $(( (EP+100)*1000 )) \
  $(( (EP+650)*1000 )) $(( (EP+660)*1000 )) $(( (EP+670)*1000 ))
printf '%s\t%s\t%s\t%s\t%s\n' "$EP" "429-signal(3)" "none" "none" "no" > "$CASE_DIR/outcome_queue"
timeout 30 "$ZEN" auto --once >/dev/null 2>&1
VNEW=$(grep -c "^V" "$CASE_DIR/rotations.tsv" 2>/dev/null || echo 0)
check "one new V row" 1 "$VNEW"
VLINE=$(grep "^V" "$CASE_DIR/rotations.tsv" 2>/dev/null || echo none)
check "windowed count excludes outside rows" "V $EP 2 600" \
  "$(echo "$VLINE" | awk -F'\t' '{print $1, $2, $4, $5}')"
check "queue drained" "absent" "$([ -s "$CASE_DIR/outcome_queue" ] && echo present || echo absent)"

# 2. Old 4-field V rows keep prior meaning, byte-identical.
fresh_case
EPOLD=$((NOW - 900))
printf 'R\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$EPOLD" "2026-10-07" "429-signal(3)" "none" "none" "no" "0" > "$CASE_DIR/rotations.tsv"
printf 'V\t%s\t%s\t%s\n' "$EPOLD" 300 5 >> "$CASE_DIR/rotations.tsv"
BEFORE=$(cat "$CASE_DIR/rotations.tsv")
: > "$CASE_DIR/outcome_queue"
timeout 30 "$ZEN" auto --once >/dev/null 2>&1
check "old rows untouched" "$BEFORE" "$(cat "$CASE_DIR/rotations.tsv")"

# 3. Mixed ledger report reads both forms true.
fresh_case
EP2=$((NOW - 900))
printf 'R\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$EP2" "2026-10-07" "429-signal(3)" "none" "none" "no" "0" > "$CASE_DIR/rotations.tsv"
printf 'V\t%s\t%s\t%s\n' "$EP2" 300 5 >> "$CASE_DIR/rotations.tsv"
printf 'V\t%s\t%s\t%s\t%s\n' "$EP2" 610 2 600 >> "$CASE_DIR/rotations.tsv"
printf '%s\t%s\t%s\n' "$EP2" "2026-10-07" "2a09:bac5::1" > "$CASE_DIR/edge_timeline.tsv"
mkdb "$DB_FILE" $((EP2*1000))
OUT=$(DAYS=7 timeout 30 "$ZEN" report 2>&1 || true)
check "report shows legacy cumulative 5" 1 "$(echo "$OUT" | grep -c "legacy cumulative.*: 5" || true)"
check "report shows windowed 600s count 2" 1 "$(echo "$OUT" | grep -c "windowed 600s.*: 2" || true)"

rm -rf /tmp/opencode/issue-9.*
suite_done "issue-9"
