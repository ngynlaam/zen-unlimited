#!/usr/bin/env bash
# tests/test-catch.sh — hermetic tests for `bin/zen catch` (Observer).
# Seams only: `bin/zen catch --once/--self-test` CLI over fixture files.
# Fake STATE_DIR + fixture source logs (never live files), fixture ledger.
# No sleeps (only --once/--self-test, never the watch loop), no tunnel touch
# (one localhost TCP probe for listener state only), no live-state writes.
set -u
# Fixture wall-clock stamps use UTC+7, independent of the host time zone.
export TZ=UTC-7
REPO="$(cd "$(dirname "$0")/.." && pwd)"
ZEN="$REPO/bin/zen"
PASS=0; FAIL=0
. "$(dirname "$0")/helper.sh"

CASE_DIR=$(mktemp -d /tmp/opencode/catch.XXXXXX)
export STATE_DIR=$CASE_DIR
export CATCH_OPENCODE_LOG=$CASE_DIR/opencode.log
export CATCH_RETRY_LOG=$CASE_DIR/retry.log
export CATCH_AUTO_LOG=$CASE_DIR/auto.log
export CATCH_DIR=$CASE_DIR/catch
export CATCH_DB_FILE=$CASE_DIR/none.db
export ROTATE_NOTIFY=0

# --- fixture ledger: two R rows ---
printf 'R\t%s\t2026-10-07 19:00:00\t429-signal(2):m1\t2a09:bac5:1::1\t2a09:bac5:2::9\tyes\t0\tprimary\n' 1000 > "$CASE_DIR/rotations.tsv"
printf 'R\t%s\t2026-10-07 20:00:00\t429-burst(3):m1\t2a09:bac5:2::9\t2a09:bac5:2::9\tno\t0\tprimary\n' 2000 >> "$CASE_DIR/rotations.tsv"
echo "proxy 1700000000" > "$CASE_DIR/mode_cache"

# --- fixture sources: one hit (19:00:00), near context, far lines ---
cat > "$CASE_DIR/opencode.log" <<'LOG'
timestamp=2026-10-07T18:59:50.000Z level=INFO run=abc message="request start" role=server
timestamp=2026-10-07T19:00:00.421Z level=WARN run=abc message="mcp http request failed" errors="[{\"code\":\"ECONNRESET\"}]" role=server
timestamp=2026-10-07T19:05:00.000Z level=INFO run=abc message="unrelated ok" role=server
LOG
cat > "$CASE_DIR/retry.log" <<'LOG'
2026-10-07T19:00:10.123Z retry attempt=2 backoff=3s
2026-10-07T18:00:00.000Z plugin setup active
LOG
# NOTE: auto.log stamps are LOCAL wall-clock; opencode/retry logs are UTC.
# 19:00:00Z == 02:00:00+07, so the near auto line is 01:59:55 local.
cat > "$CASE_DIR/auto.log" <<'LOG'
2026-10-08 01:00:00 daemon start
2026-10-08 01:59:55 rotate done mode=proxy
LOG

OUT=$(timeout 60 "$ZEN" catch --once 2>&1); rc=$?
check "once exits 0" 0 "$rc"
NBUNDLES=$(printf '%s' "$OUT" | grep -c "$CASE_DIR/catch/" || true)
check "one hit writes one bundle" 1 "$NBUNDLES"
BUNDLE=$(printf '%s' "$OUT" | head -1)
check "bundle file exists" "present" "$([ -f "$BUNDLE" ] && echo present || echo absent)"
check "bundle holds the hit line twice (hit + own context)" 2 "$(grep -c 'ECONNRESET' "$BUNDLE" || true)"
check "bundle has opencode context" 1 "$(grep -c 'request start' "$BUNDLE" || true)"
check "bundle has retry context" 1 "$(grep -c 'retry attempt=2' "$BUNDLE" || true)"
check "bundle has auto context" 1 "$(grep -c 'rotate done mode=proxy' "$BUNDLE" || true)"
check "bundle drops far opencode line" 0 "$(grep -c 'unrelated ok' "$BUNDLE" || true)"
check "bundle drops far auto line" 0 "$(grep -c 'daemon start' "$BUNDLE" || true)"
check "bundle carries recent rotates" 1 "$(grep -c '429-burst(3):m1' "$BUNDLE" || true)"
check "bundle carries listener state" 1 "$(grep -c 'listener :44444:' "$BUNDLE" || true)"

# --- cursors: a quiet pass writes nothing ---
OUT2=$(timeout 60 "$ZEN" catch --once 2>&1)
check "quiet pass writes nothing" "" "$OUT2"

# --- same-second double hit: two bundles, second suffixed ---
cat >> "$CASE_DIR/opencode.log" <<'LOG'
timestamp=2026-10-07T19:10:00.100Z level=WARN run=abc message="fail one" errors="[{\"code\":\"ECONNRESET\"}]" role=server
timestamp=2026-10-07T19:10:00.900Z level=WARN run=abc message="fail two" errors="[{\"code\":\"ECONNREFUSED\"}]" role=server
LOG
OUT3=$(timeout 60 "$ZEN" catch --once 2>&1)
check "two hits write two bundles" 2 "$(printf '%s' "$OUT3" | grep -c "$CASE_DIR/catch/" || true)"
check "collision suffix used" 1 "$(printf '%s' "$OUT3" | grep -c -- '-1\.log' || true)"
check "three bundles total" 3 "$(ls "$CASE_DIR/catch/"*.log | wc -l)"

# --- DB source: typed transport/invalid-request rows bundle, quota ignored ---
# Pre-seeded ms cursor makes the old row history (never bundled); the quota
# row is filtered by the typed SQL predicate and must never bundle either.
EXPECTED=3
if command -v sqlite3 >/dev/null 2>&1; then
  export CATCH_DB_FILE=$CASE_DIR/catch.db
  sqlite3 "$CATCH_DB_FILE" "CREATE TABLE session_message(session_id TEXT,type TEXT,data TEXT,time_created INTEGER);"
  T_OLD=$(date -d "2026-10-07T18:00:00Z" +%s%3N)
  T_T1=$(date -d "2026-10-07T19:00:05Z" +%s%3N)
  T_Q=$(date -d "2026-10-07T19:00:06Z" +%s%3N)
  T_INV=$(date -d "2026-10-07T19:20:00Z" +%s%3N)
  sqlite3 "$CATCH_DB_FILE" "INSERT INTO session_message VALUES('s1','assistant','{\"error\":{\"type\":\"provider.transport\"}}',$T_OLD);"
  sqlite3 "$CATCH_DB_FILE" "INSERT INTO session_message VALUES('s1','assistant','{\"error\":{\"type\":\"provider.quota\"}}',$T_Q);"
  sqlite3 "$CATCH_DB_FILE" "INSERT INTO session_message VALUES('s1','assistant','{\"error\":{\"type\":\"provider.invalid-request\"}}',$T_INV);"
  sqlite3 "$CATCH_DB_FILE" "INSERT INTO session_message VALUES('s1','assistant','{\"error\":{\"type\":\"provider.transport\"}}',$T_T1);"
  echo "$T_OLD" > "$CASE_DIR/catch/catch.off.db"
  OUTDB=$(timeout 60 "$ZEN" catch --once 2>&1)
  check "db hits write two bundles" 2 "$(printf '%s' "$OUTDB" | grep -c "$CASE_DIR/catch/" || true)"
  BDB1=$(printf '%s' "$OUTDB" | sed -n 1p); BDB2=$(printf '%s' "$OUTDB" | sed -n 2p)
  check "transport bundle header from db" 1 "$(grep -c '=== catch .* source=db ===' "$BDB1" || true)"
  check "transport type in hit + context" 2 "$(grep -c 'error.type=provider.transport' "$BDB1" || true)"
  check "invalid-request bundle header from db" 1 "$(grep -c '=== catch .* source=db ===' "$BDB2" || true)"
  check "invalid-request type in hit + context" 2 "$(grep -c 'error.type=provider.invalid-request' "$BDB2" || true)"
  check "quota row never bundles" 0 "$(grep -h -c 'provider.quota' "$BDB1" "$BDB2" 2>/dev/null | awk '{s+=$1} END {print s+0}')"
  check "db bundle carries rotates" 1 "$(grep -c '429-burst(3):m1' "$BDB1" || true)"
  check "db cursor advanced to newest" "$T_INV" "$(cat "$CASE_DIR/catch/catch.off.db")"
  check "db quiet pass writes nothing" "" "$(timeout 60 "$ZEN" catch --once 2>&1)"
  EXPECTED=5
else
  echo "SKIP: db catch asserts (no sqlite3)"
fi

# --- self-trigger guard: pattern quoted in spawning-process args never fires,
# while a genuine reset on the next line still does ---
cat >> "$CASE_DIR/opencode.log" <<'LOG'
timestamp=2026-10-07T19:30:00.000Z level=INFO run=abc message="spawning process" command=/usr/bin/bash args="[\"-c grep -rn ECONNRESET logs\"]" role=server
LOG
check "self-trigger writes nothing" "" "$(timeout 60 "$ZEN" catch --once 2>&1)"
cat >> "$CASE_DIR/opencode.log" <<'LOG'
timestamp=2026-10-07T19:31:00.000Z level=WARN run=abc message="mcp http request failed" errors="[{\"code\":\"ECONNRESET\"}]" role=server
LOG
OUTC=$(timeout 60 "$ZEN" catch --once 2>&1)
check "genuine hit still fires" 1 "$(printf '%s' "$OUTC" | grep -c "$CASE_DIR/catch/" || true)"
EXPECTED=$((EXPECTED + 1))

# --- missing sources: tolerated, rc 0, no bundles ---
export CATCH_OPENCODE_LOG=$CASE_DIR/nope1.log CATCH_RETRY_LOG=$CASE_DIR/nope2.log CATCH_AUTO_LOG=$CASE_DIR/nope3.log
export CATCH_DB_FILE=$CASE_DIR/nope4.db
OUT4=$(timeout 60 "$ZEN" catch --once 2>&1); rc=$?
check "missing files exit 0" 0 "$rc"
check "missing files write nothing" "" "$OUT4"

# --- self-test: synthetic bundle, sources untouched ---
export CATCH_DIR=$CASE_DIR/throwaway
OUT5=$(timeout 60 "$ZEN" catch --self-test 2>&1); rc=$?
check "self-test exits 0" 0 "$rc"
STB=$(printf '%s' "$OUT5" | head -1)
check "self-test bundle exists" "present" "$([ -f "$STB" ] && echo present || echo absent)"
check "self-test marker inside (header + body)" 2 "$(grep -c 'SELFTEST' "$STB" || true)"
check "self-test has listener state" 1 "$(grep -c 'listener :44444:' "$STB" || true)"
check "real catch dir bundle count" "$EXPECTED" "$(ls "$CASE_DIR/catch/"*.log | wc -l)"

rm -rf /tmp/opencode/catch.*
suite_done "catch"
