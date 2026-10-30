#!/usr/bin/env bash
# tests/test-aggressive.sh — TDD seam tests for the aggressive profile.
# Seams only: `bin/zen auto --once` CLI + signal log file. Fake STATE_DIR,
# fake rotator (warp-cli never runs), seeded tunnel mode cache (mode_now never
# probes). No sleeps beyond the short backoff fallback, no tunnel touches.
#   off (default)     — lone 429 backs off (rc 2, no rotator call).
#   on (ZEN_AGGRESSIVE=1) — lone 429 rotates immediately (rc 0, one call).
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
ZEN="$REPO/bin/zen"
PASS=0; FAIL=0
. "$(dirname "$0")/helper.sh"

# fresh_case <var-prefix> [extra-env...] — new fake state + fake rotator +
# seeded cursors + tunnel mode cache. Sets CASE_<p>, SIG_<p>, ROT_<p>.
fresh_case() {
  local p=$1
  local d; d=$(mktemp -d /tmp/opencode/aggr-"$p".XXXXXX)
  eval "CASE_$p=\$d"
  mkdir -p "$d/signals"
  { echo '#!/bin/sh'; echo "echo rotated >> \"$d/rot.log\""; echo 'exit 0'; } > "$d/fake-rotator"
  chmod +x "$d/fake-rotator"
  echo "2026-10-07T18:00:00 history-model 429 rate limit exceeded" > "$d/signals/zen-quota.log"
  echo "tunnel $(date +%s)" > "$d/mode_cache"
  STATE_DIR=$d SIGNAL_DIR=$d/signals DB_FILE=$d/none.db \
    ROTATE_NOTIFY=0 ZEN_FREE_MODELS="m1" WARP_ROTATE=$d/fake-rotator \
    ${2:-} timeout 30 "$ZEN" auto --once >/dev/null 2>&1
}

calls() { grep -c . "$1/rot.log" 2>/dev/null || echo 0; }

# --- default (off): lone 429 holds -------------------------------------------
fresh_case off
OFF=$CASE_off
echo "tunnel $(date +%s)" > "$OFF/mode_cache"
echo "2026-10-07T19:00:01 m1 429 rate limit exceeded" >> "$OFF/signals/zen-quota.log"
STATE_DIR=$OFF SIGNAL_DIR=$OFF/signals DB_FILE=$OFF/none.db \
  ROTATE_NOTIFY=0 ZEN_FREE_MODELS="m1" WARP_ROTATE=$OFF/fake-rotator \
  timeout 40 "$ZEN" auto --once >/dev/null 2>&1; rc=$?
check "tuned lone 429 holds" 2 "$rc"
check "tuned lone 429 never rotates" 0 "$(calls "$OFF")"
check "tuned lone 429 backs off" 1 "$(grep -c "single-429 backoff" "$OFF/auto.log" 2>/dev/null || true)"

# --- aggressive on: lone 429 rotates immediately ------------------------------
fresh_case on
ON=$CASE_on
echo "tunnel $(date +%s)" > "$ON/mode_cache"
echo "2026-10-07T19:00:01 m1 429 rate limit exceeded" >> "$ON/signals/zen-quota.log"
STATE_DIR=$ON SIGNAL_DIR=$ON/signals DB_FILE=$ON/none.db \
  ROTATE_NOTIFY=0 ZEN_FREE_MODELS="m1" WARP_ROTATE=$ON/fake-rotator ZEN_AGGRESSIVE=1 \
  timeout 40 "$ZEN" auto --once >/dev/null 2>&1; rc=$?
check "aggressive lone 429 rotates" 0 "$rc"
check "aggressive lone 429 cuts once" 1 "$(calls "$ON")"
check "aggressive never backoffs lone" 0 "$(grep -c "single-429 backoff" "$ON/auto.log" 2>/dev/null || true)"

# --- aggressive on: lone proxy 429 also rotates (guard off in both modes) -----
PON=$(mktemp -d /tmp/opencode/aggr-proxy.XXXXXX)
mkdir -p "$PON/signals"
{ echo '#!/bin/sh'; echo "echo rotated >> \"$PON/rot.log\""; echo 'exit 0'; } > "$PON/fake-rotator"
chmod +x "$PON/fake-rotator"
echo "2026-10-07T18:00:00 history-model 429 rate limit exceeded" > "$PON/signals/zen-quota.log"
echo "proxy $(date +%s)" > "$PON/mode_cache"
STATE_DIR=$PON SIGNAL_DIR=$PON/signals DB_FILE=$PON/none.db \
  ROTATE_NOTIFY=0 ZEN_FREE_MODELS="m1" WARP_ROTATE=$PON/fake-rotator ZEN_AGGRESSIVE=1 \
  timeout 30 "$ZEN" auto --once >/dev/null 2>&1
echo "proxy $(date +%s)" > "$PON/mode_cache"
echo "2026-10-07T19:00:01 m1 429 rate limit exceeded" >> "$PON/signals/zen-quota.log"
STATE_DIR=$PON SIGNAL_DIR=$PON/signals DB_FILE=$PON/none.db \
  ROTATE_NOTIFY=0 ZEN_FREE_MODELS="m1" WARP_ROTATE=$PON/fake-rotator ZEN_AGGRESSIVE=1 \
  timeout 40 "$ZEN" auto --once >/dev/null 2>&1; rc=$?
check "aggressive lone proxy 429 rotates" 0 "$rc"
check "aggressive lone proxy 429 cuts once" 1 "$(calls "$PON")"

# --- aggressive value map (sourced, no daemon) --------------------------------
VALS=$(env -u ZEN_STORM_MAX ZEN_AGGRESSIVE=1 STATE_DIR=$ON SIGNAL_DIR=$ON/signals bash -c \
  '. "$0/lib/state.sh"; . "$0/lib/auto.sh"; echo "$BURST_COUNT $DEDUPE_WINDOW $QUOTA_PARK $TUNNEL_DEDUPE_WINDOW $TUNNEL_QUOTA_PARK $STUCK_PARK $MAX_STUCK $ZEN_PROFILE $(eff_single_guard) $ZEN_STORM_MAX $ZEN_STORM_WINDOW"' \
  "$REPO")
check "aggressive value map" "1 10 120 10 30 10 1 aggressive 0 6 600" "$VALS"

# Verify the cap behavior for defaults and explicit operator values, including 0.
for profile in 0 1; do
  for override in unset 0 2 7; do
    expected=$override
    if [ "$override" = unset ]; then
      expected=0
      [ "$profile" = 1 ] && expected=6
    fi
    RESULT=$(env -u ZEN_STORM_MAX ZEN_AGGRESSIVE=$profile STATE_DIR=$ON \
      SIGNAL_DIR=$ON/signals bash -c '
        [ "$1" = unset ] || export ZEN_STORM_MAX=$1
        . "$0/lib/state.sh"; . "$0/lib/auto.sh"
        : > "$STORM_FILE"
        for ((i=0; i<6; i++)); do date +%s >> "$STORM_FILE"; done
        storm_capped >/dev/null; capped=$?
        printf "%s %s" "$ZEN_STORM_MAX" "$capped"
      ' "$REPO" "$override")
    capped=0
    { [ "$expected" = 0 ] || [ "$expected" -gt 6 ]; } && capped=1
    check "storm cap profile=$profile override=$override" "$expected $capped" "$RESULT"
  done
done

rm -rf /tmp/opencode/aggr-*
suite_done "aggressive"
