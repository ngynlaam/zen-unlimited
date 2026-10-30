#!/usr/bin/env bash
# tests/test-rules.sh — direct rule tests for the decision rules in lib/auto.sh.
# Sources lib functions direct with hermetic fixtures (temp STATE_DIR, seeded
# mode cache so mode_now never probes). No sleeps, no timeouts, no tunnel:
# every assert resolves in milliseconds. The live e2e suites stay as-is.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
. "$(dirname "$0")/helper.sh"

CASE_DIR=$(mktemp -d /tmp/opencode/rules.XXXXXX)
export STATE_DIR=$CASE_DIR SIGNAL_DIR=$CASE_DIR/signals DB_FILE=$CASE_DIR/none.db
export ROTATE_NOTIFY=0
mkdir -p "$SIGNAL_DIR"
# shellcheck disable=SC1091
. "$REPO/lib/state.sh"
# shellcheck disable=SC1091
. "$REPO/lib/auto.sh"

bind_model ""   # shared keys for every case below

# seed_mode <proxy|tunnel> — fresh mode cache so mode_now never probes.
seed_mode() { echo "$1 $(date +%s)" > "$STATE_DIR/mode_cache"; }

# --- park_active ---------------------------------------------------------------
rm -f "$STATE_DIR"/stuck_until*
park_active >/dev/null 2>&1; check "park missing holds nothing" 1 "$?"
state_set stuck_until "$(( $(date +%s) + 3600))"
out=$(park_active); check "park future holds" 0 "$?"
check "park future prints epoch" "$(state_get stuck_until 0)" "$out"
state_set stuck_until "$(( $(date +%s) - 3600))"
park_active >/dev/null 2>&1; check "park past holds nothing" 1 "$?"
printf 'soon' > "$STATE_DIR/stuck_until"
park_active >/dev/null 2>&1; check "park corrupt holds nothing" 1 "$?"

# --- park_expire ---------------------------------------------------------------
state_set stuck_until "$(( $(date +%s) + 3600))"
park_expire >/dev/null 2>&1; check "park future never expires" 1 "$?"
check "park future file kept" "present" "$([ -f "$STATE_DIR/stuck_until" ] && echo present || echo absent)"
state_set stuck_until "$(( $(date +%s) - 3600))"
park_expire >/dev/null 2>&1; check "park past expires" 0 "$?"
check "park past file cleared" "absent" "$([ -f "$STATE_DIR/stuck_until" ] && echo present || echo absent)"
check "park past grants fresh budget" 0 "$(state_get stuck_edge 9)"
rm -f "$STATE_DIR"/stuck_until*
park_expire >/dev/null 2>&1; check "park missing expires nothing" 1 "$?"
printf 'soon' > "$STATE_DIR/stuck_until"
park_expire >/dev/null 2>&1; check "park corrupt expires nothing" 1 "$?"
check "park corrupt file kept" "present" "$([ -f "$STATE_DIR/stuck_until" ] && echo present || echo absent)"

# --- window_inside ---------------------------------------------------------------
rm -f "$STATE_DIR"/dedupe_stamp*
window_inside 90 >/dev/null 2>&1; check "window missing never holds" 1 "$?"
state_set dedupe_stamp "$(date +%s)"
window_inside 90 >/dev/null 2>&1; check "window fresh holds" 0 "$?"
check "window fresh prints age" 0 "$(window_inside 900)"
state_set dedupe_stamp "$(( $(date +%s) - 1000 ))"
window_inside 90 >/dev/null 2>&1; check "window old never holds" 1 "$?"
printf 'soon' > "$STATE_DIR/dedupe_stamp"
window_inside 90 >/dev/null 2>&1; check "window corrupt never holds" 1 "$?"
state_set dedupe_stamp 0
window_inside 90 >/dev/null 2>&1; check "window zero never holds" 1 "$?"

# --- window_note_fail ---------------------------------------------------------------
rm -f "$STATE_DIR"/window_fails* "$STATE_DIR"/quota_until*
out=$(window_note_fail 600 k proxy); rc=$?
check "first fail counts 1" 1 "$out"
check "first fail holds nothing" 0 "$rc"
check "first fail parks nothing" "absent" "$([ -f "$STATE_DIR/quota_until" ] && echo present || echo absent)"
echo 2 > "$STATE_DIR/window_fails"
out=$(window_note_fail 600 k proxy); rc=$?
check "third fail counts 3" 3 "$out"
check "third fail parks" 1 "$rc"
check "park set in future" 1 "$([ "$(state_get quota_until 0)" -gt "$(date +%s)" ] && echo 1 || echo 0)"
check "counter resets after park" 0 "$(cat "$STATE_DIR/window_fails" 2>/dev/null || echo missing)"
out=$(window_note_fail 600 k proxy); rc=$?
check "count restarts at 1" 1 "$out"
check "restart holds nothing" 0 "$rc"

# --- single_guard_hold (both modes: lone 429 backs off, 2nd rotates) -------
seed_mode tunnel
rm -f "$STATE_DIR"/burst*
single_guard_hold >/dev/null 2>&1; check "lone 429 holds in tunnel" 0 "$?"
record_signal 1
single_guard_hold >/dev/null 2>&1; check "first 429 still holds in tunnel" 0 "$?"
record_signal 1
single_guard_hold >/dev/null 2>&1; check "second 429 releases in tunnel" 1 "$?"
seed_mode proxy
rm -f "$STATE_DIR"/burst*
single_guard_hold >/dev/null 2>&1; check "lone 429 holds in proxy" 0 "$?"
record_signal 1
single_guard_hold >/dev/null 2>&1; check "first 429 still holds in proxy" 0 "$?"
record_signal 1
single_guard_hold >/dev/null 2>&1; check "second 429 releases in proxy" 1 "$?"

# --- quota_parked (existing small rule, pinned beside the new ones) ---------------
rm -f "$STATE_DIR"/quota_until*
quota_parked >/dev/null 2>&1; check "no quota park" 1 "$?"
state_set quota_until "$(( $(date +%s) + 600 ))"
quota_parked >/dev/null 2>&1; check "quota park holds" 0 "$?"
state_set quota_until "$(( $(date +%s) - 600 ))"
quota_parked >/dev/null 2>&1; check "quota park expired" 1 "$?"

# --- drain default (aggressive-grade: dead wait 3s -> 1s) ----------------------
# 13/13 deferred rotates ended in drain timeout, 0 clean drains, across the
# 30s/10s/3s eras. Fake state, no daemon, no tunnel: source-only checks.
drain_default=$(unset ZEN_DRAIN_S; . "$REPO/lib/state.sh"; . "$REPO/lib/auto.sh"; printf '%s' "$ZEN_DRAIN_S")
check "drain default is 1s" 1 "$drain_default"
drain_kept=$(ZEN_DRAIN_S=5 bash -c '. "$0/lib/state.sh"; . "$0/lib/auto.sh"; printf "%s" "$ZEN_DRAIN_S"' "$REPO")
check "explicit drain wins" 5 "$drain_kept"

rm -rf /tmp/opencode/rules.*
suite_done "rules"
