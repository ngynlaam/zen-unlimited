#!/usr/bin/env bash
# tests/test-choreo.sh — TDD seam tests for the aggressive 429 retry choreography.
# Seams only: `bin/zen auto --once` CLI + signal log file. Fake STATE_DIR,
# fake rotator with scripted ready (instant rc 0, no EDGE line) + scripted
# 429 stream (background appender during the settle window). Fake mode cache
# (mode_now never probes). Warp-cli never runs, no tunnel touches.
#   defaults        — pacing is DOWN_HOLD 2s / POST_UP 2s / SETTLE 3s / MAX 3.
#   clean cycle     — one rotate, ready mark, clean stop, timing bounds.
#   still-429       — 429 inside the window repeats IMMEDIATELY (2 cuts).
#   escape          — 3 consecutive fruitless cycles fall back to quota-park.
#   tuned unchanged — no ZEN_AGGRESSIVE means no choreo lines, lone holds.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
ZEN="$REPO/bin/zen"
PASS=0; FAIL=0
. "$(dirname "$0")/helper.sh"

# fresh_choreo <tag> — new fake state + instant fake rotator + seeded cursors
# + tunnel mode cache. Sets CHD. Caller appends fresh 429 lines, then runs
# `bin/zen auto --once` with the wanted ZEN_CHOREO_* overrides.
fresh_choreo() {
  CHD=$(mktemp -d /tmp/opencode/choreo-"$1".XXXXXX)
  mkdir -p "$CHD/signals"
  { echo '#!/bin/sh'; echo "echo rotated >> \"$CHD/rot.log\""; echo 'exit 0'; } > "$CHD/fake-rotator"
  chmod +x "$CHD/fake-rotator"
  echo "2026-10-07T18:00:00 history-model 429 rate limit exceeded" > "$CHD/signals/zen-quota.log"
  echo "tunnel $(date +%s)" > "$CHD/mode_cache"
  STATE_DIR=$CHD SIGNAL_DIR=$CHD/signals DB_FILE=$CHD/none.db \
    ROTATE_NOTIFY=0 ZEN_FREE_MODELS="m1" WARP_ROTATE=$CHD/fake-rotator \
    timeout 30 "$ZEN" auto --once >/dev/null 2>&1
  echo "tunnel $(date +%s)" > "$CHD/mode_cache"
}

calls() { grep -c . "$1/rot.log" 2>/dev/null || echo 0; }
sigline() { echo "2026-10-07T19:00:0$1 m1 429 rate limit exceeded"; }

# --- 1. pacing defaults (sourced, no daemon) ---------------------------------
VALS=$(bash -c '. "$0/lib/state.sh"; . "$0/lib/rotate.sh"; printf "%s %s %s %s %s" "$DOWN_HOLD" "$ZEN_CHOREO_POST_UP_S" "$ZEN_CHOREO_SETTLE_S" "$ZEN_CHOREO_MAX" "$ZEN_PROFILE"' "$REPO")
check "choreo pacing defaults 2/2/3/3" "2 2 3 3 tuned" "$VALS"
OVR=$(ZEN_CHOREO_POST_UP_S=0 ZEN_CHOREO_SETTLE_S=1 ZEN_CHOREO_MAX=2 bash -c '. "$0/lib/state.sh"; printf "%s %s %s" "$ZEN_CHOREO_POST_UP_S" "$ZEN_CHOREO_SETTLE_S" "$ZEN_CHOREO_MAX"' "$REPO")
check "choreo pacing overrides win" "0 1 2" "$OVR"

# --- 2. clean cycle: one cut, ready mark, clean stop, timing bounds ----------
fresh_choreo clean
sigline 1 >> "$CHD/signals/zen-quota.log"
t0=$(date +%s)
STATE_DIR=$CHD SIGNAL_DIR=$CHD/signals DB_FILE=$CHD/none.db \
  ROTATE_NOTIFY=0 ZEN_FREE_MODELS="m1" WARP_ROTATE=$CHD/fake-rotator \
  ZEN_AGGRESSIVE=1 ZEN_CHOREO_POST_UP_S=1 ZEN_CHOREO_SETTLE_S=1 \
  timeout 40 "$ZEN" auto --once >/dev/null 2>&1; rc=$?
el=$(( $(date +%s) - t0 ))
check "clean cycle rotates (rc 0)" 0 "$rc"
check "clean cycle cuts once then stops" 1 "$(calls "$CHD")"
check_range "clean cycle timing bounds (1+1 pacing)" 2 6 "$el"
check "clean cycle marks ready" 1 "$(grep -c "choreo: ready" "$CHD/auto.log" 2>/dev/null || true)"
check "clean cycle stops on clean window" 1 "$(grep -c "clean .* window after cycle 1" "$CHD/auto.log" 2>/dev/null || true)"
rm -rf "$CHD"

# --- 3. still-429 in window repeats IMMEDIATELY (no dedupe/backoff) ----------
fresh_choreo repeat
sigline 1 >> "$CHD/signals/zen-quota.log"
( sleep 1; sigline 2 >> "$CHD/signals/zen-quota.log" ) &
STATE_DIR=$CHD SIGNAL_DIR=$CHD/signals DB_FILE=$CHD/none.db \
  ROTATE_NOTIFY=0 ZEN_FREE_MODELS="m1" WARP_ROTATE=$CHD/fake-rotator \
  ZEN_AGGRESSIVE=1 ZEN_CHOREO_POST_UP_S=0 ZEN_CHOREO_SETTLE_S=2 \
  timeout 40 "$ZEN" auto --once >/dev/null 2>&1; rc=$?
wait 2>/dev/null || true
check "still-429 cycle repeats (rc 0 after 2nd clean)" 0 "$rc"
check "still-429 cuts twice" 2 "$(calls "$CHD")"
check "still-429 logs immediate repeat" 1 "$(grep -c "repeating immediately, no dedupe/backoff" "$CHD/auto.log" 2>/dev/null || true)"
check "repeat has no dedupe hold between cycles" 0 "$(grep -c "dedupe hit" "$CHD/auto.log" 2>/dev/null || true)"
rm -rf "$CHD"

# --- 4. escape: 3 consecutive fruitless cycles fall back to quota-park --------
fresh_choreo escape
sigline 1 >> "$CHD/signals/zen-quota.log"
( sleep 0.5; sigline 2 >> "$CHD/signals/zen-quota.log"
  sleep 1; sigline 3 >> "$CHD/signals/zen-quota.log"
  sleep 1; sigline 4 >> "$CHD/signals/zen-quota.log" ) &
STATE_DIR=$CHD SIGNAL_DIR=$CHD/signals DB_FILE=$CHD/none.db \
  ROTATE_NOTIFY=0 ZEN_FREE_MODELS="m1" WARP_ROTATE=$CHD/fake-rotator \
  ZEN_AGGRESSIVE=1 ZEN_CHOREO_POST_UP_S=0 ZEN_CHOREO_SETTLE_S=1 \
  timeout 60 "$ZEN" auto --once >/dev/null 2>&1; rc=$?
wait 2>/dev/null || true
check "escape parks (rc 2)" 2 "$rc"
check "escape cuts exactly 3 times" 3 "$(calls "$CHD")"
check "escape discloses hatch in log" 1 "$(grep -c "escape hatch after 3 consecutive fruitless" "$CHD/auto.log" 2>/dev/null || true)"
check "escape sets quota park in future" 1 "$({ latest=0; for f in "$CHD"/quota_until*; do [ -f "$f" ] || continue; v=$(cat "$f" 2>/dev/null || echo 0); case "$v" in ''|*[!0-9]*) continue;; esac; [ "$v" -gt "$latest" ] && latest=$v; done; [ "$latest" -gt "$(date +%s)" ] && echo 1 || echo 0; })"
check "escape keeps latch for after park" "present" "$(compgen -G "$CHD/need_rotate*" > /dev/null && echo present || echo absent)"
rm -rf "$CHD"

# --- 5. tuned path unchanged: no choreo lines, lone 429 holds ----------------
fresh_choreo tuned
sigline 1 >> "$CHD/signals/zen-quota.log"
STATE_DIR=$CHD SIGNAL_DIR=$CHD/signals DB_FILE=$CHD/none.db \
  ROTATE_NOTIFY=0 ZEN_FREE_MODELS="m1" WARP_ROTATE=$CHD/fake-rotator \
  timeout 40 "$ZEN" auto --once >/dev/null 2>&1; rc=$?
check "tuned lone 429 still holds" 2 "$rc"
check "tuned never rotates lone" 0 "$(calls "$CHD")"
check "tuned log has no choreo lines" 0 "$(grep -c "choreo:" "$CHD/auto.log" 2>/dev/null || true)"
rm -rf "$CHD"

# --- 7. readiness gate: probe-passes-early ends post-up wait early ---------
fresh_choreo earlyready
sigline 1 >> "$CHD/signals/zen-quota.log"
( sleep 0.5; touch "$CHD/ready" ) &
t0=$(date +%s)
STATE_DIR=$CHD SIGNAL_DIR=$CHD/signals DB_FILE=$CHD/none.db \
  ROTATE_NOTIFY=0 ZEN_FREE_MODELS="m1" WARP_ROTATE=$CHD/fake-rotator \
  ZEN_AGGRESSIVE=1 ZEN_CHOREO_POST_UP_S=3 ZEN_CHOREO_SETTLE_S=0 ZEN_CHOREO_READY_FILE=$CHD/ready \
  timeout 40 "$ZEN" auto --once >/dev/null 2>&1; rc=$?
wait 2>/dev/null || true
el=$(( $(date +%s) - t0 ))
check "ready-gate passes early (rc 0)" 0 "$rc"
check_range "ready-gate ends 3s-capped wait early" 0 2 "$el"
check "ready-gate logs ready-by-probe" 1 "$(grep -c "ready-by-probe" "$CHD/auto.log" 2>/dev/null || true)"
rm -rf "$CHD"

# --- 8. readiness cap: never-ready probe waits the full cap, never more -----
fresh_choreo readycap
sigline 1 >> "$CHD/signals/zen-quota.log"
t0=$(date +%s)
STATE_DIR=$CHD SIGNAL_DIR=$CHD/signals DB_FILE=$CHD/none.db \
  ROTATE_NOTIFY=0 ZEN_FREE_MODELS="m1" WARP_ROTATE=$CHD/fake-rotator \
  ZEN_AGGRESSIVE=1 ZEN_CHOREO_POST_UP_S=1 ZEN_CHOREO_SETTLE_S=0 ZEN_CHOREO_READY_FILE=$CHD/never-there \
  timeout 40 "$ZEN" auto --once >/dev/null 2>&1; rc=$?
el=$(( $(date +%s) - t0 ))
check "ready-cap bounds worst case (rc 0)" 0 "$rc"
check_range "ready-cap waits the full 1s cap" 1 4 "$el"
check "ready-cap logs ready-by-cap" 1 "$(grep -c "ready-by-cap" "$CHD/auto.log" 2>/dev/null || true)"
rm -rf "$CHD"

# --- 9. success gate: new Zen OK row stops the settle watch early -----------
fresh_choreo oksuccess
sigline 1 >> "$CHD/signals/zen-quota.log"
sqlite3 "$CHD/ok.db" "CREATE TABLE session_message(session_id TEXT,type TEXT,data TEXT,time_created INTEGER);"
sqlite3 "$CHD/ok.db" "INSERT INTO session_message VALUES('s0','assistant','{\"finish\":\"stop\",\"model\":{\"providerID\":\"opencode\",\"id\":\"m1\"}}',$(( $(date +%s) * 1000 - 60000)));"
( sleep 1; sqlite3 "$CHD/ok.db" "INSERT INTO session_message VALUES('s1','assistant','{\"finish\":\"stop\",\"model\":{\"providerID\":\"opencode\",\"id\":\"m1\"}}',$(( $(date +%s) * 1000 )));" ) &
t0=$(date +%s)
STATE_DIR=$CHD SIGNAL_DIR=$CHD/signals DB_FILE=$CHD/ok.db \
  ROTATE_NOTIFY=0 ZEN_FREE_MODELS="m1" WARP_ROTATE=$CHD/fake-rotator \
  ZEN_AGGRESSIVE=1 ZEN_CHOREO_POST_UP_S=0 ZEN_CHOREO_SETTLE_S=4 \
  timeout 40 "$ZEN" auto --once >/dev/null 2>&1; rc=$?
wait 2>/dev/null || true
el=$(( $(date +%s) - t0 ))
check "success-gate stops early (rc 0)" 0 "$rc"
check "success-gate cuts once then stops" 1 "$(calls "$CHD")"
check_range "success-gate ends 4s-capped watch early" 0 3 "$el"
check "success-gate logs stopped-by-success" 1 "$(grep -c "settle stopped-by-success" "$CHD/auto.log" 2>/dev/null || true)"
rm -rf "$CHD"

# --- 10. ledger shape locked: R rows keep 9 columns --------------------------
fresh_choreo ledger
sigline 1 >> "$CHD/signals/zen-quota.log"
STATE_DIR=$CHD SIGNAL_DIR=$CHD/signals DB_FILE=$CHD/none.db \
  ROTATE_NOTIFY=0 ZEN_FREE_MODELS="m1" WARP_ROTATE=$CHD/fake-rotator \
  ZEN_AGGRESSIVE=1 ZEN_CHOREO_POST_UP_S=0 ZEN_CHOREO_SETTLE_S=0 \
  timeout 40 "$ZEN" auto --once >/dev/null 2>&1
BAD=$(awk -F'\t' '$1=="R" && NF!=9 {bad++} END{print bad+0}' "$CHD/rotations.tsv" 2>/dev/null || echo 9)
check "ledger R rows keep 9 columns" 0 "$BAD"
rm -rf "$CHD"

rm -rf /tmp/opencode/choreo-*
suite_done "choreo"
