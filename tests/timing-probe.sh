#!/usr/bin/env bash
# tests/timing-probe.sh — THROWAWAY prototype for issue 6 (per-second rotate timing).
# Zero tunnel touch: fake STATE_DIR, WARP_ROTATE=/bin/true, no warp-cli call.
# Times real bin/zen auto-section functions (extracted, not copied) stage by stage.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
FAKE=/tmp/zen-timing-fake
export STATE_DIR=$FAKE SIGNAL_DIR=$FAKE/signals DB_FILE=$FAKE/none.db \
  WARP_ROTATE=/bin/true ROTATE_NOTIFY=0
rm -rf "$FAKE"; mkdir -p "$SIGNAL_DIR"
SIG="$SIGNAL_DIR/zen-quota.log"
for i in $(seq 1 200); do echo "2026-10-07T18:00:00 hist-model 429 rate limit exceeded" >> "$SIG"; done

# Load the real auto-section (functions + defaults) from lib/. Nothing executes:
# the libs hold only assignments and definitions; main/dispatch live in bin/zen.
eval "$(cat "$REPO/lib/state.sh" "$REPO/lib/auto.sh")"

ms() { echo $(( ($2 - $1) / 1000000 )); }
t0=$(date +%s%N); seed_cursors >/dev/null 2>&1; t1=$(date +%s%N); S_SEED=$(ms "$t0" "$t1")
for i in 1 2 3; do echo "2026-10-07T19:00:0$i live-model 429 rate limit exceeded retry-after 5" >> "$SIG"; done
t0=$(date +%s%N); N_SCAN=$(detect_429_new); t1=$(date +%s%N); S_SCAN=$(ms "$t0" "$t1")
t0=$(date +%s%N); N_DB=$(detect_429_db); t1=$(date +%s%N); S_DB=$(ms "$t0" "$t1")
rm -f "$MODE_CACHE_FILE"
t0=$(date +%s%N); M1=$(mode_now); t1=$(date +%s%N); S_MODE_COLD=$(ms "$t0" "$t1")
t0=$(date +%s%N); M2=$(mode_now); t1=$(date +%s%N); S_MODE_HIT=$(ms "$t0" "$t1")
for i in 4 5 6; do echo "2026-10-07T19:01:0$i live-model 429 rate limit exceeded retry-after 5" >> "$SIG"; done
t0=$(date +%s%N); check_once >/dev/null 2>&1; RC=$?; t1=$(date +%s%N); S_DECIDE=$(ms "$t0" "$t1")
t0=$(date +%s%N)
printf 'R\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(now)" "2026-10-07" "timing-probe" "none" "none" "no" "0" >> "$LEDGER_FILE"
t1=$(date +%s%N); S_LEDGER=$(ms "$t0" "$t1")

echo "== per-stage ms (fake state, /bin/true rotator) =="
printf '%-14s %6s   %s\n' STAGE MS NOTE
printf '%-14s %6s   %s\n' seed "$S_SEED" "cursor init"
printf '%-14s %6s   %s\n' scan "$S_SCAN" "detect_429_new -> $N_SCAN line(s)"
printf '%-14s %6s   %s\n' db-detect "$S_DB" "detect_429_db -> $N_DB row(s), missing-file path"
printf '%-14s %6s   %s\n' mode-cold "$S_MODE_COLD" "mode_now -> $M1 (localhost probe)"
printf '%-14s %6s   %s\n' mode-hit "$S_MODE_HIT" "mode_now -> $M2 (cached)"
printf '%-14s %6s   %s\n' decide "$S_DECIDE" "check_once rc=$RC (signal->/bin/true->fake ledger)"
printf '%-14s %6s   %s\n' ledger "$S_LEDGER" "one R-row append"
echo "== real ledger stats (read-only) =="
awk -F'\t' '$1=="R"{n++; if(p>0){g=$2-p; s+=g; if(g>m)m=g} p=$2; if($7=="no")st++}
  END{if(n>1)printf "R=%d mean_gap=%.0fs max_gap=%.0fs stuck_share=%.2f\n",n,s/(n-1),m,st/n; else printf "R=%d (too few rows)\n",n}' \
  "$HOME/.local/share/warp-rotate/rotations.tsv"
rm -rf "$FAKE"
