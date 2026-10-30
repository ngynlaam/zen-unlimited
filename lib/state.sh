# lib/state.sh — shared state defaults + shared helpers (sourced, never executed).
# Order: core state/env defaults, then log/trim/probe helpers.

LOG_DIR="${LOG_DIR:-$HOME/.local/share/opencode/log}"
LOG_FILE="${LOG_FILE:-$LOG_DIR/opencode.log}"
STATE_DIR="${STATE_DIR:-$HOME/.local/share/warp-rotate}"
SIGNAL_DIR="${SIGNAL_DIR:-$STATE_DIR/signals}"
ZEN_SIGNAL_FILE="${ZEN_SIGNAL_FILE:-$SIGNAL_DIR/zen-quota.log}"
STATE_FILE="$STATE_DIR/last_rotate"      # epoch of last rotate
PENDING_FILE="$STATE_DIR/need_rotate"    # latched rate limit waiting for a rotate
BURST_FILE="$STATE_DIR/burst"            # epochs of recent rate-limit signals
FREE403_FILE="$STATE_DIR/last_403"       # epoch of last 403 notice (spam guard)
STUCK_FILE="$STATE_DIR/stuck_edge"       # consecutive rotates that landed on the same IPv6
STUCK_UNTIL_FILE="$STATE_DIR/stuck_until"  # epoch before which a same-edge rotate is a no-op
STATE_FAIL_FILE="$STATE_DIR/last_failed" # epoch of last FAILED rotate (backoff)
BACKOFF_LOGGED_FILE="$STATE_DIR/backoff_logged"  # stamp of the logged backoff notice
AUTO_LOG="$STATE_DIR/auto.log"
# Durable rotate ledger. auto.log is trimmed to MAX_LOG_BYTES and, measured,
# kept only ~1.5 days of rotates against 30 days of 429s in the DB — so the two
# could not be joined and "did the rotate actually clear the rate limit?" was
# unanswerable. The ledger is tiny, append-only, and barely trimmed, and it
# carries the OUTCOME measured afterwards so causality is recoverable offline.
LEDGER_FILE="${LEDGER:-$STATE_DIR/rotations.tsv}"
OUTCOME_QUEUE="$STATE_DIR/outcome_queue"   # rotates still waiting for a verdict
MAX_LEDGER_BYTES=$((512 * 1024))
LEDGER_KEEP=5000
WARP_ROTATE="${WARP_ROTATE:-__zen_internal_rotate}"

BURST_COUNT="${BURST_COUNT:-3}"          # signals inside BURST_WINDOW -> urgent
BURST_WINDOW="${BURST_WINDOW:-120}"     # seconds that counts as "in a row"
COOLDOWN="${COOLDOWN:-0}"                # min seconds between two rotates.
                                       # 0 keeps a fresh Zen hook signal immediate.
                                       # The plugin sends a signal for every 429 attempt.
ROTATE_BACKOFF="${ROTATE_BACKOFF:-${RETRY_BACKOFF:-300}}"  # wait before rotating again after a FAILED rotate (RETRY_BACKOFF stays as fallback alias)
MAX_STUCK="${MAX_STUCK:-1}"              # rotates allowed on an UNCHANGED IPv6 edge
                                       # before giving up. 1 = stop at the first
                                       # repeat. Measured 2026-10-04: 3 of 30
                                       # rotates returned the same IPv6, and at 2
                                       # the daemon cut the tunnel twice for one
                                       # rate limit (17:02:18 then 17:02:28, second
                                       # one a no-op) — a second 7s outage that
                                       # could not help. Raising this trades live
                                       # requests for retries that mostly land on
                                       # the same edge anyway.
# How long to stop rotating after a rotate came back on the SAME IPv6.
# This was 120, and that value caused the very problem the park was built to
# prevent: it parked the daemon for two full minutes even while fresh 429s
# kept arriving, so the user waited on a tunnel nobody was resetting.
# Measured 2026-10-04: of 70 fast-failures (median 12s between 429s), 39 had
# NO rotation at all in between — the daemon was parked, not failing. It also
# announced the park by notification, which DND swallowed, so from the outside
# it just looked hung. 10s still breaks the repeat-cut loop the park exists
# for, without turning a live rate limit into a two-minute stall.
STUCK_PARK="${STUCK_PARK:-10}"          # seconds to stop rotating after a same-edge repeat
FALLBACK_POLL="${FALLBACK_POLL:-30}"     # safety net if inotifywait dies
# The retry hook is the authoritative source for the one Zen free model routed
# through WARP. The DB remains a fallback, but its row can arrive after the
# hook has already rotated for that same 429.
HOOK_DEDUPE_WINDOW="${HOOK_DEDUPE_WINDOW:-45}"
# How long after a rotate to ask "did it work?". The measurement itself: count
# the 429s recorded in the DB after this many seconds and store that as the
# verdict, so a rotate that cut the tunnel and changed nothing is visible as
# such instead of looking like a success in auto.log.
OUTCOME_WAIT="${OUTCOME_WAIT:-120}"
OUTCOME_ENABLE="${OUTCOME_ENABLE:-1}"
# Fixed window a verdict covers: new V rows count 429s inside [rotate,
# rotate+OUTCOME_WINDOW_S] only, so old traffic cannot stain new rows. A verdict
# is due once the window completes (or OUTCOME_WAIT passes, whichever is later).
# Old 4-field V rows keep their cumulative-since meaning and are never rewritten.
OUTCOME_WINDOW_S="${OUTCOME_WINDOW_S:-600}"

# --- storm guards: dedupe + quota split --------------------------------------
# Dedupe: at most 1 rotate per DEDUPE_WINDOW per (model, route, minute) key.
# 429s inside the window only backoff (Retry-After capped, else fixed) — they
# must NOT cut the tunnel again. 3 consecutive deduped windows still seeing
# 429s means the edge is not helping: park QUOTA_PARK with a quota-window
# notice instead of hammering. Key uses route-label + /48 prefix, NEVER a full
# /128 (rotates ~5 min) and NEVER IPv4 (pool stuck on 104.28.219.201).
DEDUPE_WINDOW="${DEDUPE_WINDOW:-90}"      # seconds: 1 rotate per 60-120s window
QUOTA_PARK="${QUOTA_PARK:-600}"           # 10 min park after repeated windows fail
MAX_WINDOW_FAILS="${MAX_WINDOW_FAILS:-3}" # consecutive failed windows -> park
RETRY_AFTER_CAP="${RETRY_AFTER_CAP:-10}"  # cap honored Retry-After (already policy)
DEDUPE_FILE="$STATE_DIR/dedupe_stamp"     # epoch of last rotate for dedupe
DEDUPE_KEY_FILE="$STATE_DIR/dedupe_key"   # last (model,route,prefix,minute) key
WINDOW_FAIL_FILE="$STATE_DIR/window_fails" # consecutive deduped windows with 429s
QUOTA_UNTIL_FILE="$STATE_DIR/quota_until" # epoch: quota backoff/park until
FINGERPRINT_LOG="${FINGERPRINT_LOG:-$STATE_DIR/reject_fingerprints.log}"
# Quota-exhausted text (mirrors upstream QUOTA_TEXT): balance/budget spent —
# backoff only, NEVER rotate. Only RateLimit/throttle/transient rotates.
QUOTA_TEXT='insufficient quota|insufficient_quota|quota exceeded|budget exceeded|usage limit|limit exhausted|out of credit|billing.*exceeded'

# --- mode-aware policy: proxy vs tunnel --------------------------------------
# The opencode.ai limiter keys on route-identity/pool, not on key/window.
# Measured: proxy mode (listener :44444 alive) — rotates change IPv6 but the
# 429 persists (dirty pool, rotating is useless + costs a tunnel blip).
# Tunnel mode (listener dead, system tunnel serves) — ≤2 rotates clear even a
# "quota"-worded 429, so quota-text is NOT key-exhaustion here and the
# upstream-v2 "quota never rotates" rule is WRONG in tunnel mode.
# Proxy branch keeps every current behavior (dedupe 90s, quota backoff +
# 600s park, quota-text no-rotate). Tunnel branch rotates short and often.
TUNNEL_DEDUPE_WINDOW="${TUNNEL_DEDUPE_WINDOW:-25}"  # seconds: 1 rotate per ~20-30s
TUNNEL_QUOTA_PARK="${TUNNEL_QUOTA_PARK:-90}"        # short park after failed windows (60-120s)
MODE_TTL="${MODE_TTL:-30}"                          # seconds: cache for mode_now per poll
PROXY_PROBE_HOST="${PROXY_PROBE_HOST:-127.0.0.1}"
PROXY_PROBE_PORT="${PROXY_PROBE_PORT:-44444}"
MODE_CACHE_FILE="$STATE_DIR/mode_cache"

# --- storm cap: max rotates per rolling window --------------------------------
# Six rotates in two minutes (2026-10-11, aggressive BURST=1 with no single
# guard) cut the :44444 proxy ~7s each; every MCP remote rides that proxy, so
# they died in a row. Sparse lone-429 rotates are intended; storms are the
# pathology. Past the cap: latch + storm-park log, no cut, until the window
# slides. Tuned default is OFF (0) so its decisions stay byte-identical; the
# aggressive profile defaults to 6 per 600s. Same knobs tune both paths.
# Set the tuned default after profile selection to keep operator overrides.
ZEN_STORM_WINDOW="${ZEN_STORM_WINDOW:-600}"
STORM_FILE="$STATE_DIR/storm"   # epochs of recent rotates (per-model via bind_model)

# --- aggressive profile (user-confirmed override of the tuned values) --------
# ZEN_AGGRESSIVE=1: rotate on the first signal, short storm guards.
# Default off (tuned values above stay). Forced assignment (not :-) so the
# profile wins over any previously tuned env. Shape/state files untouched.
# Map: quota park proxy 600->120s, tunnel 90->30s; dedupe proxy 90->10s,
# tunnel 25->10s; BURST_COUNT->1; single-429 guard off (see eff_single_guard);
# stuck park stays 10s, MAX_STUCK stays 1, DOWN_HOLD stays 2s.
# Dedupe 30->10s (2026-10-11 fast-retest): 11 dedupe holds on 10-11 deferred
# repeat cuts up to 30s each (e.g. 18:33:15 hold -> 18:34:08 cut, 53s). The
# storm cap bounds total cuts while repeat-429 retests run up to 20s earlier.
ZEN_PROFILE="tuned"
if [ "${ZEN_AGGRESSIVE:-0}" = "1" ]; then
  ZEN_PROFILE="aggressive"
  BURST_COUNT=1
  DEDUPE_WINDOW=10
  QUOTA_PARK=120
  TUNNEL_DEDUPE_WINDOW=10
  TUNNEL_QUOTA_PARK=30
  # Allow quick edge search after repeated provider rate limits. Keep a
  # rolling ceiling to protect live traffic, but do not park for ten minutes.
  ZEN_STORM_MAX="${ZEN_STORM_MAX:-6}"
  ZEN_STORM_WINDOW=600
  STUCK_PARK=10
  MAX_STUCK=1
  DOWN_HOLD=2
fi
ZEN_STORM_MAX="${ZEN_STORM_MAX:-0}"

# --- retry choreography pacing (caps, aggressive path only) --------------------
# Aggressive 429 choreography per cycle (tuned path never reads these):
#   hold-new-requests pause (existing stream drain, ZEN_DRAIN_S, no new sleep)
#   -> warp down -> wait DOWN_HOLD (2s, existing) -> warp up
#   (wait_connected/wait_ready probes already inside reconnect stay as-is)
#   -> post-up readiness-gated wait (cap POST_UP 2s: poll the same probes,
#   proceed the moment they pass) -> mark ready -> settle success-gated watch
#   (cap SETTLE 3s: stop on first 429 or on no-429 plus a new Zen OK row;
#   fallback first-429-or-cap when no success evidence is daemon-observable).
# MAX = consecutive fruitless cycles (each followed by 429 in its window)
# before the safety escape hatch falls back to the quota-park path.
ZEN_CHOREO_POST_UP_S="${ZEN_CHOREO_POST_UP_S:-2}"
ZEN_CHOREO_SETTLE_S="${ZEN_CHOREO_SETTLE_S:-3}"
ZEN_CHOREO_MAX="${ZEN_CHOREO_MAX:-3}"

# proxy_alive [http] — rc 0 when the local listener serves. Default is one
# short TCP connect (cheap enough to call on every decision round via
# mode_now); "http" runs a real HTTP probe through the proxy, which the
# rotate path needs so a dead :44444 is never reported as serving.
proxy_alive() {
  if [ "${1:-}" = "http" ]; then
    local code
    code=$("${CURL[@]}" -s -m 2 -o /dev/null -w '%{http_code}' \
      -x "$PROXY" "$TRACE_URL" 2>/dev/null) || return 1
    [ "$code" != "000" ] && [ -n "$code" ]
  else
    timeout 1 bash -c "cat < /dev/null > /dev/tcp/${PROXY_PROBE_HOST}/${PROXY_PROBE_PORT}" 2>/dev/null
  fi
}

# _trim_file <file> <max-bytes> <keep-lines> — keep the last N lines once the
# file grows past the byte cap. Shared by the edge/auto/ledger trims.
_trim_file() {
  local _f=$1 _max=$2 _keep=$3 _sz
  _sz=$(stat -c %s "$_f" 2>/dev/null || echo 0)
  [ "$_sz" -gt "$_max" ] || return 0
  tail -"$_keep" "$_f" > "$_f.tmp" 2>/dev/null && mv "$_f.tmp" "$_f"
}
trim_edge_log() { _trim_file "$EDGE_LOG" "$MAX_EDGE_BYTES" 20000; }

log() { echo "$(date '+%F %T') $*" >> "$AUTO_LOG"; }
trim_log() { _trim_file "$AUTO_LOG" "$MAX_LOG_BYTES" 500; }
trim_ledger() { _trim_file "$LEDGER_FILE" "$MAX_LEDGER_BYTES" "$LEDGER_KEEP"; }

# ledger_verdict <R|V> <fields...> — the one writer for verdict-ledger rows,
# shared by the rotate record path and the auto outcome path. Shapes locked:
#   R <epoch> <iso> <reason> <before> <after> <changed> <rc> <path>  (9 cols;
#     old readers index fixed columns and ignore the trailing path)
#   V <ep> <elapsed> <count> [window]  (no window = legacy 4-field row,
#     cumulative-since meaning, never rewritten)
ledger_verdict() {
  local kind=$1; shift
  if [ "$kind" = "R" ]; then
    printf 'R\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" >> "$LEDGER_FILE"
  elif [ $# -ge 4 ]; then
    printf 'V\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$LEDGER_FILE"
  else
    printf 'V\t%s\t%s\t%s\n' "$1" "$2" "$3" >> "$LEDGER_FILE"
  fi
  trim_ledger
}

# --- state Interface ---------------------------------------------------------
# get/set/append/clear/has over key files under $STATE_DIR. Keys resolve
# through the bound *FILE vars (bind_model scopes them per model), so the key
# layout lives here alone and callers never spell $STATE_DIR for keys.
# Line semantics: set/append write one newline-terminated line. Every reader
# strips whitespace already (command substitution, head|tr), so the only
# on-disk delta is a trailing newline on latch/dedupe-key files no one reads
# back raw.
#   state_get <key> [default] — print content, or default when unreadable
#   state_set <key> <value>   — overwrite with one line
#   state_append <key> <value>— append one line
#   state_clear <key>         — remove the key file
#   state_has <key>           — rc 0 when the key file exists
#   state_path <key>          — print the bound file (bulk ops, tmp siblings)
#   state_family <need_rotate|stuck_until> — print existing family files
# Keys: last_rotate need_rotate burst last_failed stuck_edge stuck_until
#   quota_until dedupe_stamp dedupe_key storm outcome_queue. Ledger files stay
#   behind ledger_verdict; cursors/edge/mode/notify/lock files stay direct.
state_path() {
  case "$1" in
    last_rotate) printf '%s' "$STATE_FILE";;
    need_rotate) printf '%s' "$PENDING_FILE";;
    burst) printf '%s' "$BURST_FILE";;
    last_failed) printf '%s' "$STATE_FAIL_FILE";;
    stuck_edge) printf '%s' "$STUCK_FILE";;
    stuck_until) printf '%s' "$STUCK_UNTIL_FILE";;
    quota_until) printf '%s' "$QUOTA_UNTIL_FILE";;
    dedupe_stamp) printf '%s' "$DEDUPE_FILE";;
    dedupe_key) printf '%s' "$DEDUPE_KEY_FILE";;
    storm) printf '%s' "$STORM_FILE";;
    outcome_queue) printf '%s' "$OUTCOME_QUEUE";;
    *) return 1;;
  esac
}
state_get() { cat "$(state_path "$1")" 2>/dev/null || printf '%s' "${2:-}"; }
state_set() { printf '%s\n' "$2" > "$(state_path "$1")"; }
state_append() { printf '%s\n' "$2" >> "$(state_path "$1")"; }
state_clear() { rm -f "$(state_path "$1")"; }
state_has() { [ -f "$(state_path "$1")" ]; }
state_family() {
  local _f
  case "$1" in
    need_rotate)
      [ -f "$STATE_DIR/need_rotate" ] && printf '%s\n' "$STATE_DIR/need_rotate";;
    stuck_until) ;;
    *) return 1;;
  esac
  for _f in "$STATE_DIR/$1".*; do [ -f "$_f" ] && printf '%s\n' "$_f"; done
}

now() { date +%s; }
