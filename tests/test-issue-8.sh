#!/usr/bin/env bash
# tests/test-issue-8.sh — TDD seam tests for ngynlaam/zen-unlimited#15
# (replaces the issue #8 catalog tests; same filename, new contract).
# Seams only: `bin/zen auto --once` CLI + signal log file. Fake STATE_DIR,
# fake rotator (warp-cli never runs). A test feeds signal lines and reads
# daemon action (rc + rotator log). No private function is asserted.
#
# Contract under test: the free-tier predicate is self-contained (no network):
#   -free (non-jev) OR declared suffixless id OR ZEN_FREE_MODELS extra.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
ZEN="$REPO/bin/zen"
PASS=0; FAIL=0
. "$(dirname "$0")/helper.sh"

# Hermetic gate: an ambient override (other suites set ZEN_FREE_MODELS) must
# not narrow or widen the predicate around these assertions.
unset ZEN_FREE_MODELS ZEN_FREE_SUFFIXLESS
mkdir -p /tmp/opencode
CASE_DIRS=""

# fresh_case <name> — new fake state dir, seeded cursors, empty rotator log.
fresh_case() {
  CASE_DIR=$(mktemp -d /tmp/opencode/issue-8.XXXXXX)
  CASE_DIRS="$CASE_DIRS $CASE_DIR"
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

# feed <model> — append 3 fresh 429 signal lines for a model id.
feed() {
  local m=$1 i
  for i in 1 2 3; do
    echo "2026-10-07T19:00:0$i $m 429 rate limit exceeded retry-after 5" >> "$SIG"
  done
}

# run_once — one decision round; prints rc.
run_once() {
  timeout 30 "$ZEN" auto --once >/dev/null 2>&1
  echo $?
}

# rotated / rot_absent — what the fake rotator saw in the current case.
rotated()    { cut -d' ' -f1 "$CASE_DIR/rot.log" 2>/dev/null || echo missing; }
rot_absent() { [ -f "$CASE_DIR/rot.log" ] && echo present || echo absent; }

# db_case — fresh case + session_message table + seeded cursors. Rows are
# inserted by db_row afterwards; a following run_once detects them. Mirrors
# tests/test-review-fixes.sh.
db_case() {
  CASE_DIR=$(mktemp -d /tmp/opencode/issue-8.XXXXXX)
  CASE_DIRS="$CASE_DIRS $CASE_DIR"
  export STATE_DIR=$CASE_DIR SIGNAL_DIR=$CASE_DIR/signals DB_FILE=$CASE_DIR/db.sqlite
  export ROTATE_NOTIFY=0
  mkdir -p "$SIGNAL_DIR"
  FAKE_ROT=$CASE_DIR/fake-rotator
  { echo '#!/bin/sh'; echo "echo rotated \"\$@\" >> \"$CASE_DIR/rot.log\""; echo 'exit 0'; } > "$FAKE_ROT"
  chmod +x "$FAKE_ROT"
  export WARP_ROTATE=$FAKE_ROT
  SIG=$SIGNAL_DIR/zen-quota.log
  echo "2026-10-07T18:00:00 history-model 429 rate limit exceeded" > "$SIG"
  sqlite3 "$DB_FILE" "CREATE TABLE session_message(session_id TEXT,type TEXT,data TEXT,time_created INTEGER);"
  timeout 30 "$ZEN" auto --once >/dev/null 2>&1
}

# db_row <model> <ms-epoch> — one typed quota row for a model id.
db_row() {
  local m=$1 ms=$2 data
  if [ -z "$m" ]; then data='{"error":{"type":"provider.quota"}}';
  else data="{\"model\":{\"providerID\":\"opencode\",\"id\":\"$m\"},\"error\":{\"type\":\"provider.quota\"}}"; fi
  sqlite3 "$DB_FILE" "CREATE TABLE IF NOT EXISTS session_message(session_id TEXT,type TEXT,data TEXT,time_created INTEGER);"
  sqlite3 "$DB_FILE" "INSERT INTO session_message VALUES('s1','assistant','$data',$ms);"
}

# nowms — current epoch in milliseconds.
nowms() { date +%s000; }


# a. Free id by suffix. This is the 2026-10-17 regression: the stale static
# fallback did not carry this id, so its 14 signals rotated nothing.
fresh_case
feed deepseek-v4.1-flash-free
rc=$(run_once)
check "suffix-free id rotates" 0 "$rc"
check "suffix-free id called rotator" "rotated" "$(rotated)"

# b. A second suffix-free id: same rule, nothing to learn at boot.
fresh_case
feed muse-spark-1.3-contributor-free
rc=$(run_once)
check "second suffix-free id rotates" 0 "$rc"
check "second suffix-free id called rotator" "rotated" "$(rotated)"

# c. Paid sibling without the -free suffix is NOT free.
fresh_case
feed deepseek-v4.1-flash
rc=$(run_once)
check "paid suffixless sibling ignored" 1 "$rc"
check "paid suffixless sibling never called rotator" "absent" "$(rot_absent)"

# d1. jev id never matches, even with the -free suffix.
fresh_case
feed jev-1.13-free
rc=$(run_once)
check "jev-free ignored" 1 "$rc"
check "jev-free never called rotator" "absent" "$(rot_absent)"

# d2. Bare jev id never matches either.
fresh_case
feed jev-1.13
rc=$(run_once)
check "jev bare ignored" 1 "$rc"
check "jev bare never called rotator" "absent" "$(rot_absent)"

# e. Declared suffixless free id (registry-verified 0/0 cost).
fresh_case
feed big-pickle
rc=$(run_once)
check "suffixless big-pickle rotates" 0 "$rc"
check "suffixless big-pickle called rotator" "rotated" "$(rotated)"

# f1. ZEN_FREE_MODELS is ADDITIVE: an id with no -free suffix rotates.
fresh_case
export ZEN_FREE_MODELS="m1"
feed m1
rc=$(run_once)
check "env extra id rotates" 0 "$rc"
check "env extra id called rotator" "rotated" "$(rotated)"

# f2. ... and the env never bypasses the jev guard, even when a jev id is
# listed there.
fresh_case
export ZEN_FREE_MODELS="m1 jev-1.13-free"
feed jev-1.13-free
rc=$(run_once)
check "env-listed jev ignored" 1 "$rc"
check "env-listed jev never called rotator" "absent" "$(rot_absent)"
unset ZEN_FREE_MODELS

# g. Unknown id is ignored, no crash.
fresh_case
feed not-a-real-model-xyz
rc=$(run_once)
check "unknown model ignored" 1 "$rc"
check "unknown model never called rotator" "absent" "$(rot_absent)"

# g2. Startup names the one predicate (no catalog, no learning).
check "startup free-gate line present" "present" \
  "$(grep -Fq 'free gate: suffix=-free (non-jev) + suffixless=[big-pickle grok-code] + env extra=[none]' "$CASE_DIR/auto.log" 2>/dev/null && echo present || echo absent)"

# --- DB-path cases (issue #15 review): one predicate, two spellings. ---
# The signal path ran above; these drive detect_429_db's SQL fragment
# directly. Two rows per model (burst 2) bypass the lone-429 hold. Overrides
# stay unset around each case so no case leaks env into the next.
unset ZEN_FREE_SUFFIXLESS ZEN_FREE_MODELS

# i1. The exact #15 id via DB rows -> rotate.
db_case
db_row deepseek-v4.1-flash-free "$(nowms)"; db_row deepseek-v4.1-flash-free "$(nowms)"
rc=$(run_once)
check "db: suffix-free id rotates" 0 "$rc"
check "db: suffix-free id called rotator" "rotated" "$(rotated)"

# i2. Paid sibling (no -free suffix) -> ignored.
db_case
db_row deepseek-v4.1-flash "$(nowms)"; db_row deepseek-v4.1-flash "$(nowms)"
rc=$(run_once)
check "db: paid sibling ignored" 1 "$rc"
check "db: paid sibling never called rotator" "absent" "$(rot_absent)"

# i3. Charset-invalid id: GLOB '*-free' matches it while the bash guard
# rejects it. SQL must reject it too — otherwise detect_429_db counts a row
# db_model_counts drops, and the shared-bucket remainder rotates anyway.
db_case
db_row 'a*b-free' "$(nowms)"; db_row 'a*b-free' "$(nowms)"
rc=$(run_once)
check "db: charset-invalid id ignored" 1 "$rc"
check "db: charset-invalid never called rotator" "absent" "$(rot_absent)"

# i4. jev id -> ignored in SQL too.
db_case
db_row jev-1.13-free "$(nowms)"; db_row jev-1.13-free "$(nowms)"
rc=$(run_once)
check "db: jev-free ignored" 1 "$rc"
check "db: jev-free never called rotator" "absent" "$(rot_absent)"

# i5. ZEN_FREE_SUFFIXLESS drives BOTH spellings: a fresh suffixless id must
# rotate via the DB path (hardcoded SQL literals would drop it).
db_case
export ZEN_FREE_SUFFIXLESS="big-pickle grok-code probe-extra"
db_row probe-extra "$(nowms)"; db_row probe-extra "$(nowms)"
rc=$(run_once)
check "db: env suffixless id rotates" 0 "$rc"
check "db: env suffixless id called rotator" "rotated" "$(rotated)"
unset ZEN_FREE_SUFFIXLESS

# i6. ZEN_FREE_MODELS extras reach the SQL env branch.
db_case
export ZEN_FREE_MODELS="m1"
db_row m1 "$(nowms)"; db_row m1 "$(nowms)"
rc=$(run_once)
check "db: env extra id rotates" 0 "$rc"
check "db: env extra id called rotator" "rotated" "$(rotated)"

# i7. ... and the env stays ADDITIVE: a -free id still rotates while the env
# names only m1 (replacement semantics would have dropped it).
db_case
feed deepseek-v4.1-flash-free
rc=$(run_once)
check "env does not narrow suffix rule" 0 "$rc"
check "env does not narrow rotator" "rotated" "$(rotated)"
unset ZEN_FREE_MODELS

# h. Live registry probe (skip cleanly offline). Drift detector for the
# suffix rule: (i) every zero-cost id NOT ending -free is exactly the
# declared pair; (ii) every -free id is zero-cost. Then rotate-sample up to
# 3 extra zero-cost ids through the CLI, each in a fresh case.
REG=""
if [ "${ZEN_TEST_LIVE_REGISTRY:-0}" = 1 ]; then
  REG=$(curl -s -m 10 "https://models.opencode.ai/api.json" 2>/dev/null || echo "")
else
  echo "SKIP: live registry disabled (set ZEN_TEST_LIVE_REGISTRY=1 to enable)"
fi
probe=""
if [ -n "$REG" ]; then
  probe=$(printf '%s' "$REG" | python3 -c '
import json,sys
models=json.load(sys.stdin)["opencode"]["models"]
free=[]; suffixless=[]; paidfree=[]
for mid,m in sorted(models.items()):
    c=m.get("cost") or {}
    if c.get("input")==0 and c.get("output")==0:
        free.append(mid)
        if not mid.endswith("-free"): suffixless.append(mid)
    elif mid.endswith("-free"): paidfree.append(mid)
tested={"deepseek-v4.1-flash-free","muse-spark-1.3-contributor-free","big-pickle"}
pref=["glm-5.3-flash-free","nemotron-3.5-super-vl-free"]
sample=[m for m in pref if m in free]
for m in free:
    if len(sample)>=3: break
    if m in sample or m in tested: continue
    if not all(ch.isalnum() or ch in "._+/-" for ch in m): continue
    sample.append(m)
print("suffixless", " ".join(suffixless))
print("paidfree", " ".join(paidfree))
print("sample", " ".join(sample[:3]))
' 2>/dev/null) || probe=""
fi
if [ "${ZEN_TEST_LIVE_REGISTRY:-0}" != 1 ]; then
  : # The opt-in skip was reported above; it is not a passing assertion.
elif [ -z "$probe" ]; then
  echo "SKIP: live registry probe offline or unparsable (no network / JSON changed)"
  PASS=$((PASS+1))
else
  suffixless=$(printf '%s\n' "$probe" | awk '/^suffixless /{sub(/^suffixless /,""); print}')
  paidfree=$(printf '%s\n' "$probe" | awk '/^paidfree /{sub(/^paidfree /,""); print}')
  sample=$(printf '%s\n' "$probe" | awk '/^sample /{sub(/^sample /,""); print}')

  check "live: suffixless zero-cost set is exactly {big-pickle,grok-code}" \
    "big-pickle grok-code" "$suffixless"
  check "live: no paid id ends with -free" "" "$paidfree"

  n=0
  for id in $sample; do
    n=$((n + 1))
    fresh_case
    feed "$id"
    rc=$(run_once)
    check "live: $id rotates" 0 "$rc"
    check "live: $id called rotator" "rotated" "$(rotated)"
  done
  if [ "$n" -eq 0 ]; then
    FAIL=$((FAIL+1)); echo "FAIL: live probe found no zero-cost id to sample"
  else
    PASS=$((PASS+1)); echo "PASS: live probe sampled $n extra zero-cost ids"
  fi
fi

rm -rf $CASE_DIRS
suite_done "issue-8"
