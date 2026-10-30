#!/usr/bin/env bash
# tests/test-observability.sh — hermetic tests for report views 11-16.
# Seams only: `bin/zen report` CLI over fixture files. Fake STATE_DIR + fixture
# DB (never the live one), crafted auto.log / rotations.tsv / edge timeline /
# signal log / outcome_queue / mode_cache. No tunnel touch (report is
# read-only), no live-state writes. Asserts each new view reads fixtures true.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
ZEN="$REPO/bin/zen"
PASS=0; FAIL=0
. "$(dirname "$0")/helper.sh"

CASE_DIR=$(mktemp -d /tmp/opencode/observability.XXXXXX)
export STATE_DIR=$CASE_DIR DB_FILE=$CASE_DIR/obs.db DAYS=30
export SIGNAL_DIR=$STATE_DIR/signals
export ROTATE_NOTIFY=0
mkdir -p "$STATE_DIR/signals"

NOW=$(date +%s)
NOWMS=$((NOW * 1000))

# --- fixture DB: ok + quota + transport rows (assistant turns) ---
sqlite3 "$DB_FILE" "CREATE TABLE session_message(session_id TEXT,type TEXT,data TEXT,time_created INTEGER);"
sqlite3 "$DB_FILE" "INSERT INTO session_message VALUES('s1','assistant','{\"finish\":\"stop\",\"tokens\":{\"input\":10,\"output\":5},\"time\":{\"completed\":$((NOWMS+2000))}}',$NOWMS);"
sqlite3 "$DB_FILE" "INSERT INTO session_message VALUES('s1','assistant','{\"error\":{\"type\":\"provider.quota\"},\"model\":{\"id\":\"m1\"}}',$((NOWMS+1000)));"
sqlite3 "$DB_FILE" "INSERT INTO session_message VALUES('s2','assistant','{\"error\":{\"type\":\"provider.transport\"},\"model\":{\"id\":\"m1\"}}',$((NOWMS+2000)));"

# --- fixture edge timeline: two segments ---
printf '%s\t2026-10-07 19:00:00\t2a09:bac5:1::1\n' "$((NOW-3600))" > "$STATE_DIR/edge_timeline.tsv"
printf '%s\t2026-10-07 20:00:00\t2a09:bac5:2::9\n' "$((NOW-60))" >> "$STATE_DIR/edge_timeline.tsv"

# --- fixture ledger: one R + legacy V + windowed V ---
printf 'R\t%s\t2026-10-07 20:00:00\t429-signal(2):m1\t2a09:bac5:1::1\t2a09:bac5:2::9\tyes\t0\tprimary\n' "$((NOW-600))" > "$STATE_DIR/rotations.tsv"
printf 'V\t%s\t180\t2\n' "$((NOW-400))" >> "$STATE_DIR/rotations.tsv"
printf 'V\t%s\t700\t0\t600\n' "$((NOW-300))" >> "$STATE_DIR/rotations.tsv"

# --- fixture auto.log: every pattern each new view parses ---
cat > "$STATE_DIR/auto.log" <<'LOG'
2026-10-07 19:00:01 rotate start (429-signal(2):m1) mode=tunnel
2026-10-07 19:00:02   down-window: 2s (selected WARP route was down; held 2s)
2026-10-07 19:00:08   up-window: 7s (Connected at 5s, local-proxy route serving)
2026-10-07 19:00:08 rotate done mode=tunnel
2026-10-07 19:01:00 dedupe hit key=m1:2a09:bac5:20261007 age=5s (window 25s) — backoff 3s, no rotate (fail 1/3) mode=tunnel
2026-10-07 19:02:00 single-429 backoff 3s: first 429 in 120s window (burst=1) — no rotate, waiting for a 2nd signal mode=tunnel
2026-10-07 19:03:00 quota-window: 3 consecutive windows still 429 — parking 90s instead of hammering mode=tunnel
2026-10-07 19:04:00 saw 2 rate-limit line(s) during same-edge park (until 123) — latched, park kept mode=tunnel
2026-10-07 19:05:00 route path: responses for model m1 (reason 429-signal(2):m1)
2026-10-07 19:06:00 holding: quota park until 123 — backoff, no rotate mode=proxy
2026-10-07 19:07:00 edge 2a09:bac5:1::1 -> 2a09:bac5:2::9 (/2a09:bac5:2 via system-tunnel)
2026-10-07 19:08:00 stream drained after 2s, rotating (429-signal(1):m1)
2026-10-07 19:09:00 retry failed: ECONNRESET on attempt 3 mode=tunnel
LOG

# --- fixture signal log + outcome queue + mode cache ---
printf '2026-10-07T19:00:01 m1 429 rate limit exceeded retry-after 5\n2026-10-07T19:00:02 m1 429 rate limit exceeded\n2026-10-07T19:00:03 m2 429 rate limit exceeded\n' > "$STATE_DIR/signals/zen-quota.log"
printf '%s\t429-signal(1):m2\tnone\tnone\tno\n' "$NOW" > "$STATE_DIR/outcome_queue"
echo "tunnel $NOW" > "$STATE_DIR/mode_cache"

OUT=$(timeout 60 "$ZEN" report 2>&1); rc=$?
check "report exits 0 on fixtures" 0 "$rc"

# --- each new view header is present ---
for sec in "=== 11. Rotate latency" "=== 12. Holds" "=== 13. Verdict latency" \
           "=== 14. Proxy-listener health" "=== 15. Route decisions" "=== 16. Transport errors"; do
  check "view present: $sec" 1 "$(printf '%s' "$OUT" | grep -cF "$sec" || true)"
done

# --- 11: one start->done pair, down/up windows, one drain, one defer? (no defer line) ---
check "11 pairs one rotate" 1 "$(printf '%s' "$OUT" | grep -c "start->done: n=1 median=7s max=7s" || true)"
check "11 down-window" 1 "$(printf '%s' "$OUT" | grep -c "down-window: n=1 median=2s max=2s" || true)"
check "11 up-window" 1 "$(printf '%s' "$OUT" | grep -c "up-window: n=1 median=7s max=7s" || true)"
check "11 stream-drain" 1 "$(printf '%s' "$OUT" | grep -c "stream-drain: n=1 median=2s max=2s" || true)"

# --- 12: signal counts per model + hold categories ---
check "12 signals total" 1 "$(printf '%s' "$OUT" | grep -c "plugin signals: 3 lines" || true)"
check "12 dedupe-hit m1" 1 "$(printf '%s' "$OUT" | grep -c "dedupe-hit.*m1=1" || true)"
check "12 single-guard" 1 "$(printf '%s' "$OUT" | grep -c "single-guard-hold" || true)"
check "12 quota-window-park" 1 "$(printf '%s' "$OUT" | grep -c "^  quota-window-park " || true)"
check "12 same-edge-park-latch" 1 "$(printf '%s' "$OUT" | grep -c "same-edge-park-latch" || true)"
check "12 quota-park-hold" 1 "$(printf '%s' "$OUT" | grep -c "quota-park-hold" || true)"

# --- 13: verdict buckets + pending ---
check "13 within-wait bucket" 1 "$(printf '%s' "$OUT" | grep -c "<=130s (within wait)" || true)"
check "13 late bucket" 1 "$(printf '%s' "$OUT" | grep -c "^  >650s *[0-9][0-9]* *(.*%)" || true)"
check "13 pending one" 1 "$(printf '%s' "$OUT" | grep -c "pending verdicts in outcome_queue: 1" || true)"

# --- 14: mode timeline + cache ---
check_range "14 tunnel mentions" 1 50 "$(printf '%s' "$OUT" | grep -c "tunnel" || true)"
check "14 cache" 1 "$(printf '%s' "$OUT" | grep -c "mode_cache now: tunnel" || true)"
check "14 route mentions" 1 "$(printf '%s' "$OUT" | grep -c "system-tunnel=1" || true)"

# --- 15: route decision ---
check "15 responses m1" 1 "$(printf '%s' "$OUT" | grep -c "m1 .*responses=1" || true)"

# --- 16: transport row + auto.log mention ---
check "16 transport section counts" 1 "$(printf '%s' "$OUT" | grep -c "auto.log transport mentions: 1" || true)"

# --- missing-file tolerance: empty state dir still exits 0 ---
EMPTY=$(mktemp -d /tmp/opencode/obs-empty.XXXXXX)
sqlite3 "$EMPTY/e.db" "CREATE TABLE session_message(session_id TEXT,type TEXT,data TEXT,time_created INTEGER);"
check "empty fixtures exit 0" 0 "$(STATE_DIR=$EMPTY SIGNAL_DIR=$EMPTY/signals DB_FILE=$EMPTY/e.db DAYS=7 timeout 60 "$ZEN" report >/dev/null 2>&1; echo $?)"
check "empty shows no-auto.log note" 1 "$(STATE_DIR=$EMPTY DB_FILE=$EMPTY/e.db DAYS=7 timeout 60 "$ZEN" report 2>&1 | grep -c "no auto.log yet" || true)"
rm -rf "$EMPTY"

rm -rf /tmp/opencode/observability.* /tmp/opencode/obs-empty.*
suite_done "observability"
