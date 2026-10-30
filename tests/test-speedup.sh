#!/usr/bin/env bash
# tests/test-speedup.sh — TDD seam tests for the rotate/switch speedup pass.
# Evidence (ledger numbers, not guesses):
#   rotations.tsv: 339 R, up-window 204x4s + 254x5s (2s poll quantization),
#     down-window 460x2s (DOWN_HOLD=2 user floor, untouched);
#   stream-drain: 13 deferred rotates 2026-10-07..11, 13/13 drain timeouts,
#     0 clean drains (auto.log grep; report §11 "stream-drain: none recorded
#     yet"), so the wait never avoids a mid-stream cut — the cure is only
#     delayed. Default drain is 1s (bounded defer shape kept, dead wait cut);
#   0 retry-after hints in 326 signal lines and 0 in the plugin log, so the
#     daemon `|| ra=1` fallback binds on ~every backoff sleep (was 3s).
# Seams only: sourced functions + `bin/zen auto --once` CLI. Fake STATE_DIR,
# fake rotator, fake warp-cli on PATH (real tunnel never touched).
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
ZEN="$REPO/bin/zen"
PASS=0; FAIL=0
. "$(dirname "$0")/helper.sh"

# --- 1. stuck-stream drain bound: default must stall ~1s, not ~3s ------------
# Live proof the wait never pays: 13/13 deferred rotates timed out with the
# stream still open (0 clean drains, across the 30s/10s/3s eras), then
# rotated anyway.
DRAIN_CASE=$(mktemp -d /tmp/opencode/speedup-drain.XXXXXX)
export STATE_DIR=$DRAIN_CASE SIGNAL_DIR=$DRAIN_CASE/signals DB_FILE=$DRAIN_CASE/none.db
export ROTATE_NOTIFY=0
mkdir -p "$SIGNAL_DIR"
unset ZEN_DRAIN_S   # exercise the shipped default, not an override
# shellcheck disable=SC1091
. "$REPO/lib/state.sh"
# shellcheck disable=SC1091
. "$REPO/lib/auto.sh"
touch "$STATE_DIR/stream_open"   # stream that never drains
t0=$(date +%s)
stream_drain_wait "speedup-probe" >/dev/null 2>&1
el=$(( $(date +%s) - t0 ))
check_range "stuck-stream drain bound" 1 4 "$el"
rm -rf "$DRAIN_CASE"
# lib defaults are now loaded with the drain default baked in; later cases
# that need other ZEN_DRAIN_S values export them explicitly (as before).

# --- 2. missing-hint backoff: dedupe-held round must cost ~1s, not ~3s -------
SPD=$(mktemp -d /tmp/opencode/speedup-fallback.XXXXXX)
export STATE_DIR=$SPD SIGNAL_DIR=$SPD/signals DB_FILE=$SPD/none.db
export ROTATE_NOTIFY=0 ZEN_FREE_MODELS="m1"
mkdir -p "$SIGNAL_DIR"
FAKE_ROT=$SPD/fake-rotator
{ echo '#!/bin/sh'; echo "echo rotated >> \"$SPD/rot.log\""; echo 'exit 0'; } > "$FAKE_ROT"
chmod +x "$FAKE_ROT"
export WARP_ROTATE=$FAKE_ROT
SIG=$SIGNAL_DIR/zen-quota.log
echo "2026-10-07T18:00:00 history-model 429 rate limit exceeded" > "$SIG"
timeout 30 "$ZEN" auto --once >/dev/null 2>&1
for i in 1 2 3; do echo "2026-10-07T19:00:0$i m1 429 rate limit exceeded" >> "$SIG"; done
timeout 40 "$ZEN" auto --once >/dev/null 2>&1
for i in 4 5; do echo "2026-10-07T19:01:0$i m1 429 rate limit exceeded" >> "$SIG"; done
t0=$(date +%s)
timeout 40 "$ZEN" auto --once >/dev/null 2>&1; rc=$?
el=$(( $(date +%s) - t0 ))
check "missing-hint round held by dedupe" 2 "$rc"
check_range "missing-hint backoff costs fallback only" 0 3 "$el"
rm -rf "$SPD" /tmp/opencode/speedup-fallback.*

# --- 3. wait_connected: 1s polls detect a ready tunnel ~2x faster ------------
CONN_CASE=$(mktemp -d /tmp/opencode/speedup-conn.XXXXXX)
mkdir -p "$CONN_CASE/fakebin"
cat > "$CONN_CASE/fakebin/warp-cli" <<EOF
#!/bin/sh
C="$CONN_CASE/calls"; n=0; [ -f "\$C" ] && n=\$(cat "\$C")
n=\$((n + 1)); echo "\$n" > "\$C"
if [ "\$n" -ge 3 ]; then echo "Status: Connected"; else echo "Status: Disconnected"; fi
EOF
chmod +x "$CONN_CASE/fakebin/warp-cli"
PATH="$CONN_CASE/fakebin:$PATH"
# shellcheck disable=SC1091
. "$REPO/lib/rotate.sh"
rm -f "$CONN_CASE/calls"
t0=$(date +%s)
wait_connected >/dev/null 2>&1; rc=$?
el=$(( $(date +%s) - t0 ))
check "wait_connected succeeds" 0 "$rc"
check_range "wait_connected detects ready tunnel fast" 1 3 "$el"
rm -rf "$CONN_CASE"

# --- 4. bg edge-probe timeout default is the short bound ----------------------
check "edge probe timeout default" 5 "${EDGE_PROBE_TIMEOUT:-unset}"

suite_done "speedup"
