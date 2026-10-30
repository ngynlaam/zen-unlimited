# lib/auto.sh — Decision Module: policy daemon (sourced, never executed).
# Needs lib/state.sh first (shared state + helpers).

# --- AUTO section (ex bin/warp-auto, verbatim) ---
# warp-auto — when the configured Zen free model reports a fresh 429, reset the
# WARP egress session (disconnect -> connect) before OpenCode retries.
#
# EVENT-DRIVEN, not polled. inotifywait watches the dedicated Zen signal
# directory and OpenCode logs; the session DB is a filtered fallback.
#
# A fresh signal from the Zen hook means rotate immediately. The hook filters
# to the configured free model. Generic provider and subagent log text does not
# trigger WARP changes. Every fresh 429 rotate-signal requests a new rotation.
#
# Two sources of rate limits: a dedicated signal from the Zen hook and an exact
# model-filtered OpenCode DB fallback. The fallback is deduplicated against a
# recent hook signal. Generic app logs are not a source for WARP rotation.
#
# Deliberately NO timer and NO predictive rotation. auto.log showed 10 rate
# limits in 28h *while already rotating every 30 min*, so rotating early does
# not prevent 429s — it only adds a ~5s window where :44444 is unreachable.
#
# Env knobs: LOG_FILE, LOG_DIR, STATE_DIR, SIGNAL_DIR, ZEN_SIGNAL_FILE,
#            WARP_ROTATE, DB_FILE, ZEN_AGGRESSIVE,
#            BURST_COUNT, BURST_WINDOW, COOLDOWN, MAX_STUCK,
#            ROTATE_BACKOFF, FALLBACK_POLL, ACTIVE_PLUGIN_LOGS, DB_OVERLAP,
#            HOOK_DEDUPE_WINDOW, ROTATE_NOTIFY, ROTATE_NOTIFY_GAP, STUCK_PARK,
#            LEDGER, OUTCOME_WAIT, OUTCOME_ENABLE, ZEN_STORM_MAX, ZEN_STORM_WINDOW,
#            DEDUPE_WINDOW, QUOTA_PARK, MAX_WINDOW_FAILS, RETRY_AFTER_CAP,
#            TUNNEL_DEDUPE_WINDOW, TUNNEL_QUOTA_PARK, MODE_TTL,
#            PROXY_PROBE_HOST, PROXY_PROBE_PORT
#
# What is measured, and where:
#   auto.log       human-readable narrative, trimmed to 2MB (~1.5 days)
#   rotations.tsv  durable: every rotate + a V verdict with the 429 count that
#                  followed it. This is the only file that answers "did the
#                  rotate actually clear the rate limit?"


# mode_now — "proxy" when the listener is reachable, else "tunnel".
# Cached for MODE_TTL so a round with many decision logs probes at most once.
mode_now() {
  local c_m='' c_t=0 t age
  if [ -f "$MODE_CACHE_FILE" ]; then
    read -r c_m c_t < "$MODE_CACHE_FILE" 2>/dev/null || { c_m=''; c_t=0; }
    case "$c_t" in ''|*[!0-9]*) c_t=0;; esac
    t=$(now)
    age=$(( t - c_t ))
    if [ "$age" -lt "$MODE_TTL" ] && { [ "$c_m" = "proxy" ] || [ "$c_m" = "tunnel" ]; }; then
      printf '%s' "$c_m"; return 0
    fi
  fi
  if proxy_alive; then c_m="proxy"; else c_m="tunnel"; fi
  echo "$c_m $(now)" > "$MODE_CACHE_FILE" 2>/dev/null || true
  printf '%s' "$c_m"
}

# _mode_val <tunnel-val> <proxy-val> — per-mode branch shared by the eff_*
# storm-guard helpers below. Tunnel rotates short and often; proxy keeps the
# long values because rotating there is useless.
_mode_val() {
  if [ "$(mode_now)" = "tunnel" ]; then echo "$1"; else echo "$2"; fi
}
# eff_dedupe_window / eff_quota_park — per-mode storm-guard values.
eff_dedupe_window() { _mode_val "$TUNNEL_DEDUPE_WINDOW" "$DEDUPE_WINDOW"; }
eff_quota_park() { _mode_val "$TUNNEL_QUOTA_PARK" "$QUOTA_PARK"; }
eff_quota_rotates() { _mode_val 1 0; }
# eff_single_guard — backoff-first on a lone 429 in BOTH modes. Tunnel keeps
# its existing hold (unchanged); proxy gains it because proxy-pool rotates
# never clear quota (A/B verdict) yet proxy paid a 7s cut per lone-429 blip —
# proxy is where the guard matters most.
# Aggressive profile (ZEN_AGGRESSIVE=1): guard off in both modes — a lone 429
# rotates immediately, no backoff-first.
eff_single_guard()  { [ "${ZEN_AGGRESSIVE:-0}" = "1" ] && { echo 0; return 0; }; _mode_val 1 1; }

# ip48 — /48 prefix of an IPv6 address (first 3 hextets, lower-cased).
ip48() {
  local ip="${1:-}"
  [ -n "$ip" ] || return 1
  echo "$ip" | tr 'A-F' 'a-f' | cut -d: -f1-3
}

# dedupe_key_now [model] — (model, route-label, /48, minute). Route comes from
# the last known edge. Defaults to the bound model, else the legacy "zen".
dedupe_key_now() {
  local ip p48 minute
  ip=$(cat "$EDGE_LAST_FILE" 2>/dev/null || echo '')
  p48=$(ip48 "$ip" 2>/dev/null || echo "unknown")
  minute=$(date '+%Y%m%d%H%M')
  printf '%s:%s:%s' "${1:-${MKEY:-zen}}" "${p48:-unknown}" "$minute"
}

# retry_after_secs — Retry-After hint from the fresh Zen signal tail, capped.
# Falls back to 0 (caller uses a fixed short backoff instead of sleeping long).
retry_after_secs() {
  local raw v
  raw=$(tail -n 20 "$ZEN_SIGNAL_FILE" 2>/dev/null \
    | grep -oiE 'retry-after[^0-9]{0,10}[0-9]+' | grep -oE '[0-9]+' | tail -1)
  case "$raw" in ''|*[!0-9]*) echo 0; return 0;; esac
  v=$raw
  [ "$v" -gt "$RETRY_AFTER_CAP" ] && v=$RETRY_AFTER_CAP
  echo "$v"
}

# wait_hint <secs> — pause honoring the server hint. The value arrives capped
# (RETRY_AFTER_CAP, locked) with a short fallback (1s) when the hint is
# absent, so no long sleep ever blocks a cure. Once per round at most: several
# held models share one pause instead of stacking sleeps.
# Fallback 3->1s (2026-10-11 fast-retest): 17 no-hint 3s sleeps on 10-11, each
# blinding the event loop up to 3s before the next signal is processed. A
# real server hint still sleeps its (capped) value; only the arbitrary
# no-hint beat shrinks. Quota-park durations elsewhere are untouched.
wait_hint() {
  local s=${1:-1}
  case "$s" in ''|*[!0-9]*) s=1;; esac
  [ "$s" -gt 0 ] || s=1
  [ "${_WAITED_ROUND:-0}" = "1" ] && return 0
  _WAITED_ROUND=1
  log "waiting ${s}s per Retry-After hint (capped)"
  sleep "$s"
}

# --- model routing table (issue #13) -------------------------------------------
# Each model family reaches its right upstream path: the muse-spark family and
# kin (gpt/grok) use the responses path, everything else uses chat. jev is
# NEVER routed — it stays off chat routes even when listed as free. Family
# prefixes only; the default is chat for the rest.
# model_path <id> prints responses|chat|off (always rc 0; it is a lookup).
model_path() {
  local id
  id=$(printf '%s' "${1:-}" | tr 'A-Z' 'a-z')
  case "$id" in
    jev|jev-*) echo off;;
    muse-spark*|gpt-*|grok-*) echo responses;;
    *) echo chat;;
  esac
}

# is_quota_line <text> — rc 0 when the text is quota-exhausted (no-rotate class).
is_quota_line() {
  printf '%s\n' "${1:-}" | grep -qiE "$QUOTA_TEXT"
}

# quota_parked — rc 0 while a quota backoff/park is active.
quota_parked() {
  local until now_ts
  until=$(state_get quota_until 0)
  case "$until" in ''|*[!0-9]*) return 1;; esac
  now_ts=$(now)
  [ "$now_ts" -lt "$until" ]
}

# window_fails — read/increment/reset the consecutive-failed-windows counter.
window_fails() { cat "$WINDOW_FAIL_FILE" 2>/dev/null || echo 0; }
window_fail_inc() {
  local n; n=$(window_fails)
  case "$n" in ''|*[!0-9]*) n=0;; esac
  n=$((n + 1)); echo "$n" > "$WINDOW_FAIL_FILE"; echo "$n"
}
window_fail_reset() { echo 0 > "$WINDOW_FAIL_FILE"; }

# --- edge timeline ---------------------------------------------------------
# The missing link. Measured: neither the journal nor auto.log ever records the
# IPv6 edge address, so the ONLY place an edge appeared was inside a rotate.
# That made it impossible to answer the central question — "is this rate limit
# tied to the edge I am on?" — because a 429 arriving while no rotate happened
# had no known IP attached to it. Everything else (429 counts, request volume)
# is already in opencode.db; without this file the 429s and the IP cannot be
# joined and no conclusion is reachable.
#
# One row per OBSERVED CHANGE, not per poll: an edge that stays put for six
# hours is one row, so the file stays small and a query is a simple range join.
# Egress IP is read from the proxy, so it reflects the same path the traffic
# takes (measured: both -4 and -6 through :44444 return the IPv6 address).
EDGE_LOG="${EDGE_LOG:-$STATE_DIR/edge_timeline.tsv}"
EDGE_POLL="${EDGE_POLL:-60}"       # seconds between egress probes (idle check)
EDGE_PROBE_TIMEOUT="${EDGE_PROBE_TIMEOUT:-5}"
EDGE_ENABLE="${EDGE_ENABLE:-1}"
EDGE_LAST_FILE="$STATE_DIR/edge_last"
EDGE_PROBED_FILE="$STATE_DIR/edge_probed"   # epoch of the last egress probe
EDGE_ROUTE_FILE="$STATE_DIR/edge_route"      # last observed serving route

# edge_now — current egress IPv6, proxy first then system-tunnel fallback.
# Same env name and default as warp-rotate's PROXY, so one PROBE_PROXY override
# points both at the same place instead of silently probing a dead port.
# Timeline covers BOTH routes: when :44444 is dead the serving route is the
# system tunnel (direct, --noproxy '*'), and that address is what gets
# recorded — never a stale proxy reading.
edge_now() {
  local ip trace
  ip=$(curl -s -m "$EDGE_PROBE_TIMEOUT" -x "${PROBE_PROXY:-${PROXY:-http://127.0.0.1:44444}}" \
    https://api64.ipify.org 2>/dev/null | tr -d '[:space:]')
  # NOTE: record_edge captures this via $(edge_now), i.e. a subshell, so a
  # plain global assignment would be invisible to the caller (the old
  # "via unknown" bug). Persist the route to a file as well — file writes
  # survive the subshell; the global stays for direct (non-subshell) callers.
  case "$ip" in *:*[0-9a-fA-F]*)
    EDGE_ROUTE_NOW="local-proxy"
    printf '%s' "local-proxy" > "$EDGE_ROUTE_FILE" 2>/dev/null || true
    printf '%s' "$ip"; return 0;;
  esac
  trace=$(env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u http_proxy -u https_proxy \
    -u all_proxy curl --noproxy '*' -s -m "$EDGE_PROBE_TIMEOUT" \
    https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null)
  case "$trace" in *warp=on*|*warp=plus*|*gateway=on*)
    ip=$(sed -n 's/^ip=//p' <<< "$trace" | head -1 | tr -d '[:space:]')
    case "$ip" in *:*[0-9a-fA-F]*)
      EDGE_ROUTE_NOW="system-tunnel"
      printf '%s' "system-tunnel" > "$EDGE_ROUTE_FILE" 2>/dev/null || true
      printf '%s' "$ip"; return 0;;
    esac
    ;;
  esac
  return 1
}

# record_edge — append a row only when the edge actually changed.
# Columns: epoch, iso, ipv6. A first observation seeds the file and writes no
# row beyond it; an unreadable probe never overwrites a known edge, because a
# blank must not look like "the edge moved to unknown".
record_edge() {
  [ "$EDGE_ENABLE" = "1" ] || return 0
  local ip last t probed
  # Rate-limit the probe. The daemon wakes on every log write, and an
  # active session touches opencode.log many times a minute; probing on every
  # wakeup cost ~774ms of blocking curl each time for a value that changes
  # roughly hourly. EDGE_POLL is the floor between probes. A rotate still
  # records its own edges, so the timeline does not depend on this cadence.
  probed=$(cat "$EDGE_PROBED_FILE" 2>/dev/null || echo 0)
  case "$probed" in ''|*[!0-9]*) probed=0;; esac
  if [ $(( $(now) - probed )) -lt "$EDGE_POLL" ]; then return 0; fi
  echo "$(now)" > "$EDGE_PROBED_FILE"
  EDGE_ROUTE_NOW=""
  ip=$(edge_now) || return 0
  case "$ip" in ''|*[!0-9a-fA-F:]*) return 0;; esac
  last=$(cat "$EDGE_LAST_FILE" 2>/dev/null || echo '')
  if [ "$ip" = "$last" ]; then return 0; fi
  t=$(now)
  # no header needed: the first data row is the file's own starting point.
  # Row covers whichever route served (local-proxy OR system-tunnel) — the
  # timeline is not proxy-route-only. Route + /48 go to auto.log for joins.
  printf '%s\t%s\t%s\n' "$t" "$(date '+%F %T')" "$ip" >> "$EDGE_LOG"
  echo "$ip" > "$EDGE_LAST_FILE"
  trim_edge_log
  _p48=$(ip48 "$ip" 2>/dev/null || echo "?")
  _route="${EDGE_ROUTE_NOW:-}"
  [ -n "$_route" ] || _route=$(cat "$EDGE_ROUTE_FILE" 2>/dev/null || echo '')
  if [ -z "$_route" ]; then
    if proxy_alive; then _route="local-proxy"; else _route="system-tunnel"; fi
  fi
  log "edge $last -> $ip (/${_p48:-?} via ${_route:-unknown})"
}

MAX_EDGE_BYTES=$((1024 * 1024))
MAX_LOG_BYTES=$((2 * 1024 * 1024))

# Real rate limits only. The previous /\b429\b/ also matched http.span=429 (a
# trace span id) and MCP "requires a login" failures — neither is a 429.
PATTERN='rate limit exceeded|retry-after|status[=: ]+429'

# Provider rejections that look like rate limits but are NOT fixed by a new IP.
# Measured on this machine: a 403 "free tier can only be used from within
# OpenCode" comes and goes on its own — identical client, identical proxy, same
# session, OK at 13:24 and 13:36, 403 at 13:25. Rotating the egress address
# cannot clear it, so these are recorded only, never rotated on.
PATTERN_403="free tier can only be used|provider\\.auth|UnsupportedProxyProtocol"
FREE403_NOTIFY_GAP=1800   # at most one desktop notification per 30 minutes

# --- free-tier predicate (issue #15; replaces the issue #8 catalog) ------------
# One predicate decides which model ids may rotate. NO NETWORK in the gate
# path: the boot-time catalog is gone.
#
# WHY (measured 2026-10-17, issue #15): the old design learned the free set at
# boot from https://opencode.ai/zen/v1/models?free=true with a static
# fallback, and both halves failed:
#   - The catalog filter is dead: ?free=true returned all 85 ids (mostly paid,
#     missing most free ids) — the filter is ignored server-side.
#   - The boot fetch failed on 10/10 mornings Oct 8-17 (the daemon starts
#     before the network is up), so the stale static fallback was in force at
#     boot and deepseek-v4.1-flash-free signals (14 on 2026-10-17) were
#     dropped — no rotation happened when it was most needed.
#   - Registry cross-check (models.opencode.ai/api.json, provider opencode):
#     44 models cost 0/0; 42 end with -free; the only two exceptions are
#     big-pickle and grok-code (the constant set below).
# Hence the rule: -free (non-jev) OR declared suffixless OR env extra. See
# WARP-AUTO.md §16.
ZEN_FREE_SUFFIXLESS="${ZEN_FREE_SUFFIXLESS:-big-pickle grok-code}"
# ^ registry-verified 0/0 cost 2026-10-17; update ONLY with registry evidence
#   (tests/test-issue-8.sh live probe fails loudly on drift).
# ZEN_FREE_MODELS: ADDITIVE extra ids (space-separated). It never narrows the
# suffix rule and never bypasses the jev guard.
ZEN_FREE_MODELS="${ZEN_FREE_MODELS:-}"

# is_free_model <id> — rc 0 iff the id may rotate. jev-* (and bare jev) NEVER
# match. Charset guard: the id is inlined into SQL literals by
# free_model_sql, so only [A-Za-z0-9._+/-] is accepted.
is_free_model() {
  local id="${1:-}"
  case "$id" in jev-*|jev) return 1;; esac
  case "$id" in ''|*[!a-zA-Z0-9._+/-]*) return 1;; esac
  case "$id" in *-free) return 0;; esac
  case " ${ZEN_FREE_SUFFIXLESS:-} " in *" $id "*) return 0;; esac
  case " ${ZEN_FREE_MODELS:-} " in *" $id "*) return 0;; esac
  return 1
}

# keep_free_signals — stdin signal lines -> only those whose $2 model id is
# free. The signal Interface carries "<ISO8601> <model-id> 429 ...".
keep_free_signals() {
  local line rest mid
  while IFS= read -r line; do
    rest=${line#* }
    mid=${rest%% *}
    if is_free_model "$mid"; then printf '%s\n' "$line"; fi
  done
}

# free_model_sql — self-contained SQL boolean fragment; use as `AND (...)`.
# ONE predicate, TWO spellings: this must accept EXACTLY the ids is_free_model
# accepts (parity requirement, issue #15 review). Consequences:
#   - the suffixless set is read from $ZEN_FREE_SUFFIXLESS, like the bash
#     side — never hardcoded, or an operator override widens one spelling
#     only;
#   - a charset clause mirrors the bash charset guard: GLOB '*-free' alone
#     matches ids like a*b-free, which is_free_model rejects — then
#     detect_429_db counts rows db_model_counts drops and the
#     rows-sum-to-total invariant breaks (the remainder path rotates on a
#     phantom row);
#   - per-id guards skip empty/jev/charset-invalid ids, so a quote can never
#     reach the SQL, and an empty set leaves a valid fragment (no dangling
#     OR: the OR chain is built only from surviving ids).
free_model_sql() {
  local id sfx_lit="" ex_lit=""
  for id in ${ZEN_FREE_SUFFIXLESS:-}; do
    case "$id" in jev-*|jev|'') continue;; *[!a-zA-Z0-9._+/-]*) continue;; esac
    sfx_lit="$sfx_lit OR json_extract(data,'\$.model.id') = '$id'"
  done
  for id in ${ZEN_FREE_MODELS:-}; do
    case "$id" in jev-*|jev|'') continue;; *[!a-zA-Z0-9._+/-]*) continue;; esac
    ex_lit="$ex_lit OR json_extract(data,'\$.model.id') = '$id'"
  done
  printf "NOT json_extract(data,'\$.model.id') GLOB 'jev-*' AND NOT json_extract(data,'\$.model.id') GLOB '*[^A-Za-z0-9._+/-]*' AND ( json_extract(data,'\$.model.id') GLOB '*-free'%s%s )" "$sfx_lit" "$ex_lit"
}

# --- per-model backoff keys (issue #10) ---------------------------------------
# Dedupe, burst, and park keys carry the model ID: one hot model parks alone
# while a calm model still rotates. Key VALUES (windows, caps, parks) are
# locked and unchanged — only the keying is per model.
# bind_model <id> scopes every backoff key file below to one model. "" means
# the legacy shared files (DB fallback and quota-text paths keep them, so
# their behavior is byte-identical to before). MKEY carries the context for
# log lines and key content.
MKEY=""
bind_model() {
  MKEY="${1:-}"
  local seg=""
  if [ -n "$MKEY" ]; then
    seg=".$(printf '%s' "$MKEY" | tr -c 'a-zA-Z0-9._-' '_')"
  fi
  PENDING_FILE="$STATE_DIR/need_rotate$seg"
  BURST_FILE="$STATE_DIR/burst$seg"
  DEDUPE_FILE="$STATE_DIR/dedupe_stamp$seg"
  DEDUPE_KEY_FILE="$STATE_DIR/dedupe_key$seg"
  WINDOW_FAIL_FILE="$STATE_DIR/window_fails$seg"
  QUOTA_UNTIL_FILE="$STATE_DIR/quota_until$seg"
  STORM_FILE="$STATE_DIR/storm$seg"
  STUCK_FILE="$STATE_DIR/stuck_edge$seg"
  STUCK_UNTIL_FILE="$STATE_DIR/stuck_until$seg"
  STATE_FAIL_FILE="$STATE_DIR/last_failed$seg"
  BACKOFF_LOGGED_FILE="$STATE_DIR/backoff_logged$seg"
}

# signal_model_counts — "model count" lines for free models in unread signal
# bytes. PEEK ONLY: the 429 cursor is never advanced here (detect_429_new
# owns that). Same filters as the count path, so the rows sum to its total.
signal_model_counts() {
  local f size off
  for f in $(active_429_logs); do
    size=$(stat -c %s "$f" 2>/dev/null || echo 0)
    off=$(cat "$STATE_DIR/$(offset_name "$f").429" 2>/dev/null || echo 0)
    case "$off" in ''|*[!0-9]*) off=0;; esac
    [ "$size" -lt "$off" ] && off=0
    [ "$size" -gt "$off" ] || continue
    tail -c +$((off + 1)) "$f" 2>/dev/null \
      | grep -v 'spawning process' | keep_free_signals | grep -iE "$PATTERN" \
      | awk '{print $2}' || true
  done | sort | uniq -c | awk '{print $2, $1}'
}

# pending_model <file> — model id latched in a pending file ("" for legacy
# epoch-stamped files, which fail the free check and stay shared).
pending_model() {
  local id
  id=$(head -c 128 "$1" 2>/dev/null | tr -d '[:space:]')
  if is_free_model "$id"; then printf '%s' "$id"; fi
}

# fold_rc <best-so-far> <rc> — combine per-model round outcomes on stdout:
# a rotate (0) wins, else a hold (2) beats nothing-to-do (1).
fold_rc() {
  local best=${1:-1} r=${2:-1}
  if [ "$r" -eq 0 ]; then echo 0; return 0; fi
  if [ "$r" -eq 2 ] && [ "$best" -ne 0 ]; then echo 2; else echo "$best"; fi
}

# decide_signal_models <model-counts> <sig> — run one bound handle_signal per
# free model plus the legacy remainder, return the folded rc (0/1/2).
decide_signal_models() {
  local model_counts=$1 sig=$2 mc_mid mc_n counted=0 best=1 r
  while read -r mc_mid mc_n; do
    [ -n "$mc_mid" ] || continue
    case "$mc_n" in ''|*[!0-9]*|0) continue;; esac
    counted=$((counted + mc_n))
    handle_signal "$mc_n" "$mc_mid"; r=$?
    best=$(fold_rc "$best" "$r")
  done <<< "$model_counts"
  if [ "$counted" -lt "$sig" ]; then
    handle_signal "$((sig - counted))"; r=$?
    best=$(fold_rc "$best" "$r")
  fi
  return "$best"
}

# drain_pending_latches <m> <dw> <qp> — fire every latched model (each pending
# file carries its model id; legacy epoch-stamped files stay shared), return
# the folded rc. No pending file at all means nothing to do (1).
drain_pending_latches() {
  local m=$1 dw=$2 qp=$3 _pf _mid _lr best=1 any=0
  while IFS= read -r _pf; do
    [ -f "$_pf" ] || continue
    any=1
    _mid=$(pending_model "$_pf")
    bind_model "$_mid"
    handle_latch "$m" "$dw" "$qp"; _lr=$?
    best=$(fold_rc "$best" "$_lr")
  done < <(state_family need_rotate)
  [ "$any" -eq 0 ] && return 1
  return "$best"
}

# _pending_exists — any latch, legacy or per-model (wakeup timing only).
_pending_exists() {
  state_family need_rotate | grep -q .
}





# resolve_outcomes — grade rotates whose verdict window has completed.
# R rows are written by do_rotate; a new V row lands here with the number of
# 429s inside [rotate, rotate+OUTCOME_WINDOW_S]. A rotate followed by 0 is a
# rotate that helped; one followed by many is a 2s tunnel cut that bought
# nothing, and that is the number that decides whether rotating on a fresh
# edge is worth doing at all.
# Old 4-field V rows (V ep elapsed count) keep their cumulative-since meaning
# and are never rewritten; new rows carry the window as a 5th field so the
# report reads both forms true.
# Runs on the daemon's wakeups, not on a timer of its own.
resolve_outcomes() {
  [ "$OUTCOME_ENABLE" = "1" ] || return 0
  state_has outcome_queue || return 0
  [ -f "${DB_FILE:-}" ] || return 0
  local t ep reason before after changed cnt due _qt
  t=$(now)
  due=${OUTCOME_WINDOW_S:-600}
  if [ "${OUTCOME_WAIT:-120}" -gt "$due" ]; then due=$OUTCOME_WAIT; fi
  _qt="$(state_path outcome_queue)"; _qt="$_qt.tmp"
  : > "$_qt"
  while IFS=$'\t' read -r ep reason before after changed; do
    case "$ep" in ''|*[!0-9]*) continue;; esac
    if [ "$(( t - ep ))" -lt "$due" ]; then
      printf '%s\t%s\t%s\t%s\t%s\n' "$ep" "$reason" "$before" "$after" "$changed" \
        >> "$_qt"
      continue
    fi
    # Count real rate limits, not text matches. data LIKE '%Rate limit
    # exceeded%' also fires on log text quoted inside user/synthetic/system
    # messages and on rows whose error is a different provider type, so it
    # over-counted: measured 96 vs 79 over the same 24h window. error.type is
    # the typed field OpenCode itself writes, and matches what warp-report
    # counts, so a V row and a report line mean the same thing.
    cnt=$(sqlite3 "$DB_FILE" \
      "SELECT COUNT(*) FROM session_message
         WHERE type='assistant'
           AND json_extract(data,'\$.error.type')='provider.quota'
           AND time_created > $((ep * 1000))
           AND time_created <= $(((ep + ${OUTCOME_WINDOW_S:-600}) * 1000));" \
      2>/dev/null | tr -d '[:space:]')
    case "$cnt" in ''|*[!0-9]*) ledger_verdict V "$ep" "$(( t - ep ))" unknown;;
      *) ledger_verdict V "$ep" "$(( t - ep ))" "$cnt" "${OUTCOME_WINDOW_S:-600}";;
    esac
  done < "$(state_path outcome_queue)"
  mv "$_qt" "$(state_path outcome_queue)"
}


# matches_429 <line|stdin> — rc 0 if the line is a rate-limit signal.
matches_429() {
  if [ $# -gt 0 ]; then printf '%s\n' "$1" | grep -qiE "$PATTERN"
  else grep -qiE "$PATTERN"; fi
}

# --- burst bookkeeping -------------------------------------------------------
# record_signal: stamp this round as N rate-limit signals ago.
record_signal() {
  local n=$1 ts _bt; ts=$(now)
  _bt="$(state_path burst)"; _bt="$_bt.tmp"
  : > "$_bt"
  local i=0
  while [ "$i" -lt "$n" ] && [ "$i" -lt 50 ]; do
    echo "$ts" >> "$_bt"; i=$((i + 1))
  done
  state_has burst && cat "$(state_path burst)" >> "$_bt"
  tail -50 "$_bt" > "$(state_path burst)"
  mv "$_bt" "$(state_path burst)"
}

# burst_count: how many rate-limit signals landed inside BURST_WINDOW.
burst_count() {
  local ts cutoff n=0
  cutoff=$(( $(now) - BURST_WINDOW ))
  state_has burst || { echo 0; return 0; }
  while read -r ts; do
    case "$ts" in ''|*[!0-9]*) continue;; esac
    [ "$ts" -ge "$cutoff" ] && n=$((n + 1))
  done < "$(state_path burst)"
  echo "$n"
}

clear_burst() { : > "$(state_path burst)"; }

# --- log scanning ------------------------------------------------------------
# These files remain useful for informational 403 tracking and historical
# diagnostics. They are not trusted as 429 triggers because their text can
# describe failures from unrelated providers or subagents.
ACTIVE_PLUGIN_LOGS="${ACTIVE_PLUGIN_LOGS:-3}"   # newest N plugin logs to scan

# active_logs — the files worth scanning for informational errors.
# DB_FILE is the fallback source of exact-model 429 records.
DB_FILE="${DB_FILE:-$HOME/.local/share/opencode/opencode.db}"
active_logs() {
  [ -f "$LOG_FILE" ] && printf '%s\n' "$LOG_FILE"
  [ -f "$ZEN_SIGNAL_FILE" ] && printf '%s\n' "$ZEN_SIGNAL_FILE"
  # newest N plugin logs. The :-3 guard matters: an empty value would make
  # head fail and silently yield zero watched files.
  ls -1t "$LOG_DIR"/oh-my-opencode-slim.*.log 2>/dev/null \
    | head -n "${ACTIVE_PLUGIN_LOGS:-3}" \
    | while IFS= read -r f; do
        [ -f "$f" ] && printf '%s\n' "$f"
      done
}

# 429 rotations are limited to free Zen model ids (is_free_model's predicate).
# Scanning generic app and subagent logs also catches unrelated providers and
# can cut the user's WARP route for an error that WARP cannot affect.
active_429_logs() {
  [ -f "$ZEN_SIGNAL_FILE" ] && printf '%s\n' "$ZEN_SIGNAL_FILE"
}

# offset_name <path> — stable per-file cursor filename
offset_name() {
  printf 'off.%s' "$(basename "$1" .log)"
}

# scan_new <pattern> <cursor-tag> — count matching lines in bytes appended since
# the last scan, then advance every cursor. Never writes to the logs.
scan_new() {
  local pattern=$1 tag=$2 total=0 f size off n watched
  if [ "$tag" = "429" ]; then
    watched=$(active_429_logs)
  elif [ "$tag" = "quota" ]; then
    watched=$(active_429_logs)   # quota-exhausted is Zen-scoped, like 429
  else
    watched=$(active_logs)
  fi
  if [ -z "$watched" ]; then
    # A missing signal file is normal before the plugin sends its first event.
    [ "$tag" = "429" ] && { echo 0; return 0; }
    log "scan_new: no log files found under $LOG_DIR — watching NOTHING"
    echo 0
    return 1
  fi
  for f in $watched; do
    size=$(stat -c %s "$f" 2>/dev/null || echo 0)
    off=$(cat "$STATE_DIR/$(offset_name "$f").$tag" 2>/dev/null || echo 0)
    case "$off" in ''|*[!0-9]*) off=0;; esac
    [ "$size" -lt "$off" ] && off=0        # rotated or truncated
    if [ "$size" -gt "$off" ]; then
      # opencode logs every bash tool call as "spawning process", including our
      # own greps containing the words we match on — not provider errors.
      if [ "$tag" = "429" ]; then
        # Signal lines carry the model id in $2: only free models count.
        # Unknown ids and jev-* are ignored here, never rotated on.
        n=$(tail -c +$((off + 1)) "$f" 2>/dev/null \
            | grep -v 'spawning process' | keep_free_signals | grep -icE "$pattern" || true)
      else
        n=$(tail -c +$((off + 1)) "$f" 2>/dev/null \
            | grep -v 'spawning process' | grep -icE "$pattern" || true)
      fi
      case "$n" in ''|*[!0-9]*) n=0;; esac
      total=$((total + n))
    fi
    echo "$size" > "$STATE_DIR/$(offset_name "$f").$tag"
  done
  echo "$total"
}

# detect_429_new — count rate-limit lines in newly appended bytes.
detect_429_new() { scan_new "$PATTERN" 429; }

# detect_429_db — count 429 rows in the OpenCode session DB.
#
# Why this has to exist: a large share of rate limits never reach ANY log file.
# Measured 2026-10-04 13:29:33 and 13:34:59 — both present in session_message,
# both completely absent from opencode.log and every plugin log. A daemon that
# only tails log files is structurally blind to those, which is precisely how
# someone watches "Rate limit exceeded" sit on screen while nothing happens.
#
# Cursor is max(time_created) in MILLISECONDS (the column is ms, not seconds —
# get this wrong and every row looks centuries old). Rows are written shortly
# after the HTTP response, and the poll runs on every log event, so a plain
# max-cursor does not miss them in practice. No overlap rewind on purpose: an
# overlap would re-report the same rows forever and, with a short COOLDOWN,
# rotate the tunnel in a loop.
DB_OVERLAP="${DB_OVERLAP:-0}"

# QUOTA_ERR_FILTER — typed error field shared by the DB quota queries
# (detect_429_db, db_model_counts, db_quota_hit). The typed field, not message
# text, decides: text matching over-counts quoted log lines (see detect_429_db).
QUOTA_ERR_FILTER="json_extract(data,'\$.error.type') IN ('provider.quota','provider.rate-limit')"

detect_429_db() {
  local cur n hi
  if [ ! -f "$DB_FILE" ]; then echo 0; return 0; fi
  cur=$(cat "$STATE_DIR/db.429.cursor" 2>/dev/null || echo 0)
  case "$cur" in ''|*[!0-9]*) cur=0;; esac
  # Match the typed field, not the message text. data LIKE '%Rate limit
  # exceeded%' also matches log text quoted inside user/synthetic/system
  # messages, so it counted 96 rows where 79 were real rate limits over the
  # same 24h. That matters twice here: it inflates the signal count, and — worse
  # — the cursor below advances on a match that is not a rate limit at all, so
  # a later genuine one can fall behind the cursor and never be counted.
  n=$(sqlite3 "$DB_FILE" \
        "SELECT count(*) FROM session_message
          WHERE type='assistant'
            AND CASE WHEN json_valid(data) THEN
              json_extract(data,'\$.model.providerID')='opencode'
              AND ($(free_model_sql))
              AND $QUOTA_ERR_FILTER
            ELSE 0 END
            AND time_created > $cur;" 2>/dev/null) || n=''
  case "$n" in ''|*[!0-9]*) n=0;; esac
  hi=$(sqlite3 "$DB_FILE" \
        "SELECT coalesce(max(time_created),0) FROM session_message
          WHERE type='assistant'
            AND CASE WHEN json_valid(data) THEN
              json_extract(data,'\$.model.providerID')='opencode'
              AND ($(free_model_sql))
              AND $QUOTA_ERR_FILTER
            ELSE 0 END
            AND time_created > $cur;" 2>/dev/null) || hi=''
  case "$hi" in ''|*[!0-9]*) hi=0;; esac
  if [ "$hi" -gt "$cur" ]; then
    echo $((hi - DB_OVERLAP)) > "$STATE_DIR/db.429.cursor"
  fi
  echo "$n"
}

# db_model_counts — "model count" lines for quota rows newer than the DB
# cursor, peeked WITHOUT advancing it (detect_429_db owns that, same as the
# signal peek). Named free models thread their own keys; rows lacking a model
# print as "- N" and keep the legacy shared keys; other ids are dropped
# (detect excludes them too, so the rows still sum to its total).
db_model_counts() {
  local cur out id n shared=0
  [ -f "${DB_FILE:-}" ] || return 0
  cur=$(cat "$STATE_DIR/db.429.cursor" 2>/dev/null || echo 0)
  case "$cur" in ''|*[!0-9]*) cur=0;; esac
  out=$(sqlite3 "$DB_FILE" \
    "SELECT COALESCE(json_extract(data,'\$.model.id'),''), COUNT(*) FROM session_message
       WHERE type='assistant'
         AND CASE WHEN json_valid(data) THEN
           $QUOTA_ERR_FILTER
         ELSE 0 END
         AND time_created > $cur GROUP BY 1;" 2>/dev/null) || return 0
  while IFS='|' read -r id n; do
    case "$n" in ''|*[!0-9]*|0) continue;; esac
    if [ -z "$id" ]; then shared=$((shared + n)); continue; fi
    is_free_model "$id" || continue
    printf '%s %s\n' "$id" "$n"
  done <<< "$out"
  # Shared bucket uses "-" (never a model id): a bare " N" line would
  # misparse in `read mid count` (the count lands in the wrong field).
  [ "$shared" -gt 0 ] && printf -- '- %s\n' "$shared"
  return 0
}

# db_quota_hit — rc 0 when a recent Zen quota/rate-limit DB row carries
# quota-exhausted text (spent budget, not a throttle). The typed error field
# cannot tell them apart, so the message body decides: quota -> backoff only.
db_quota_hit() {
  local n
  [ -f "${DB_FILE:-}" ] || return 1
  n=$(sqlite3 "$DB_FILE" \
    "SELECT count(*) FROM session_message
       WHERE type='assistant'
         AND CASE WHEN json_valid(data) THEN
           json_extract(data,'\$.model.providerID')='opencode'
           AND ($(free_model_sql))
           AND $QUOTA_ERR_FILTER
         ELSE 0 END
         AND time_created > $(( $(now) - 300 )) * 1000
         AND lower(coalesce(json_extract(data,'\$.error.message'),json_extract(data,'\$.error.data'),data,'')) GLOB '*insufficient quota*';" \
    2>/dev/null) || n=0
  # GLOB covers one canonical spelling; the broader grep covers the rest via
  # the raw row text. Two cheap queries beat one clever one here.
  case "$n" in ''|*[!0-9]*) n=0;; esac
  [ "$n" -gt 0 ] && return 0
  n=$(sqlite3 "$DB_FILE" \
    "SELECT count(*) FROM session_message
       WHERE type='assistant'
         AND CASE WHEN json_valid(data) THEN
           json_extract(data,'\$.model.providerID')='opencode'
           AND ($(free_model_sql))
           AND $QUOTA_ERR_FILTER
         ELSE 0 END
         AND time_created > $(( $(now) - 300 )) * 1000
         AND (lower(data) LIKE '%quota exceeded%'
            OR lower(data) LIKE '%budget exceeded%'
            OR lower(data) LIKE '%usage limit%'
            OR lower(data) LIKE '%limit exhausted%');" \
    2>/dev/null) || n=0
  case "$n" in ''|*[!0-9]*) n=0;; esac
  [ "$n" -gt 0 ]
}

# A Zen hook signal is written before the retry waits for the daemon. The
# matching database row can appear after the hook has already caused a rotate.
recent_zen_hook_signal() {
  local raw epoch age
  [ -f "$ZEN_SIGNAL_FILE" ] || return 1
  raw=$(tail -n 1 "$ZEN_SIGNAL_FILE" 2>/dev/null | cut -d ' ' -f 1)
  [ -n "$raw" ] || return 1
  epoch=$(date -d "$raw" +%s 2>/dev/null || echo 0)
  case "$epoch" in ''|*[!0-9]*) return 1;; esac
  age=$(( $(now) - epoch ))
  [ "$age" -ge 0 ] && [ "$age" -le "$HOOK_DEDUPE_WINDOW" ]
}

# notify_rot <key> <urgency> <title> <body>
# Desktop notification for the rotate lifecycle. Measured reason this exists:
# a rotate is not always immediate. With COOLDOWN in the way the daemon holds
# the rate limit on a latch, and the user stares at "Rate limit exceeded" with
# no signal that anything is happening. Silence looked like a broken daemon.
#
# The gap is PER KEY, not global, on purpose. A rotate emits "starting" and
# "done" seconds apart; a single shared timestamp would let the first one
# swallow the second and you would only ever learn the outcome, never the fact
# that a tunnel is currently being cut while your request is in flight.
ROTATE_NOTIFY_GAP="${ROTATE_NOTIFY_GAP:-60}"   # seconds per notification key
ROTATE_NOTIFY="${ROTATE_NOTIFY:-1}"             # 0 = desktop notifications off

notify_rot() {
  local key=$1 urgency=$2 title=$3 body=$4 stamp last ts err
  [ "${ROTATE_NOTIFY:-1}" = "1" ] || return 0
  if ! command -v notify-send >/dev/null 2>&1; then
    log "notify SKIPPED ($key): notify-send not installed"
    return 0
  fi
  stamp="$STATE_DIR/notify.$key"
  ts=$(now)

  # "done" is never gap-limited: it is the ONLY proof a rotate completed, and it
  # carries the new address. With COOLDOWN=0 rotates run back to back, and
  # measured two rotates 24s apart where the second rotated and reported nothing.
  # "start" is the redundant half — same event, announced twice — so it is the
  # one that gets throttled. A failed and stuck-edge "done" stays critical.
  if [ "$key" != "done" ]; then
    last=$(cat "$stamp" 2>/dev/null || echo 0)
    case "$last" in ''|*[!0-9]*) last=0;; esac
    if [ $((ts - last)) -lt "$ROTATE_NOTIFY_GAP" ]; then
      log "notify suppressed ($key): ${ROTATE_NOTIFY_GAP}s gap not elapsed"
      return 0
    fi
  fi

  # Stamp only AFTER a successful send. Writing it first means a failed send
  # looks identical to a delivered one on the next round, and the rotation goes
  # silently unreported — measured: the daemon rotated and the stamp existed but
  # no notification appeared, with nothing anywhere to tell which half happened.

  if err=$(notify-send -a "zen" -u "$urgency" --expire-time=10000 \
             "$title" "$body" 2>&1); then
    echo "$ts" > "$stamp"
    log "notify sent ($key): $title"
  else
    log "notify FAILED ($key): rc=$? ${err:-no stderr}"
  fi
}

# note_403_new — provider rejections that a new IP cannot fix. Recorded only.
note_403_new() { scan_new "$PATTERN_403" 403; }

# report_403 <count> — log every occurrence, notify at most every 30 min.
# Never rotates. Also appends a checklist fingerprint row to
# $FINGERPRINT_LOG (UA / session / tools / stream) so a later 403 can be
# told apart from a new failure mode instead of lumped as "the same 403".
report_403() {
  local n=$1 last ts fp_line sig_tail m
  [ "${n:-0}" -gt 0 ] || return 0
  m=$(mode_now)
  ts=$(now)
  log "note: $n provider-rejection line(s) (403/auth) — NOT rotating, these clear on their own and a new IP does not help mode=$m"
  sig_tail=$(tail -n 5 "$ZEN_SIGNAL_FILE" 2>/dev/null | tr '\n' '|' | cut -c1-300)
  fp_line=$(printf '%s\t403x%s\tua=%s\tsession=%s\ttools=%s\tstream=%s\tsig=%s' \
    "$(date '+%F %T')" "$n" "${UA_HINT:-unknown}" "${SESSION_HINT:-unknown}" \
    "${TOOLS_HINT:-unknown}" "${STREAM_HINT:-unknown}" "$sig_tail")
  printf '%s\n' "$fp_line" >> "$FINGERPRINT_LOG" 2>/dev/null || true
  last=$(cat "$FREE403_FILE" 2>/dev/null || echo 0)
  case "$last" in ''|*[!0-9]*) last=0;; esac
  if [ $((ts - last)) -ge "$FREE403_NOTIFY_GAP" ]; then
    echo "$ts" > "$FREE403_FILE"
    command -v notify-send >/dev/null 2>&1 && \
      notify-send "OpenCode 403 (không phải 429)" \
        "Bị provider từ chối $n lần. Xoay IP không giúp ích — thường tự hết." \
        >/dev/null 2>&1
  fi
}

# --- rotate ------------------------------------------------------------------
# cooling_down — rc 0 if a rotate happened less than COOLDOWN seconds ago.
# COOLDOWN=0 disables the gate entirely (rc 1 always). Doing it here rather than
# at each call site keeps the default readable: the daemon rotates the moment it
# sees a 429, and every caller keeps its existing shape.
cooling_down() {
  local last
  [ "${COOLDOWN:-0}" -gt 0 ] 2>/dev/null || return 1
  last=$(state_get last_rotate 0)
  case "$last" in ''|*[!0-9]*) return 1;; esac
  [ $(( $(now) - last )) -lt "$COOLDOWN" ]
}

# rotate_blocked — rc 0 if a rotate just failed and ROTATE_BACKOFF has not passed.
# Without this, a stuck IPv4 pool would make the daemon reconnect in a tight
# loop, cutting the proxy every few seconds without ever changing the address.
rotate_blocked() {
  local last; last=$(state_get last_failed 0)
  case "$last" in ''|*[!0-9]*) return 1;; esac
  [ $(( $(now) - last )) -lt "$ROTATE_BACKOFF" ]
}

# --- stream guard (issue #12) ---------------------------------------------------
# A rotate never cuts mid-stream: while a stream is open the rotate waits, up
# to a bounded drain, then runs after drain or timeout. The stream-open signal
# is the flag file below (touched by whatever produces the stream, removed on
# drain); its absence means no stream and this guard is a no-op.
ZEN_STREAM_FILE="${ZEN_STREAM_FILE:-$STATE_DIR/stream_open}"
# Bounded drain default is 1s, not 3s. Measured 2026-10-07..11: 13 deferred
# rotates, 13/13 drain timeouts, 0 clean drains — the wait never avoids a
# mid-stream cut (the rotate runs anyway), it only delays the cure, across
# the 30s, 10s AND 3s eras (3/3 timeouts at 3s on 2026-10-11 alone). The
# defer-then-timeout shape is unchanged; only the dead wait is shorter.
ZEN_DRAIN_S="${ZEN_DRAIN_S:-1}"
# db_stream_open — rc 0 when the newest assistant row looks in-flight: recent
# and carrying neither finish nor error. Rows written only on completion always
# carry one of those, so this never fires for them (identical to no guard).
# A crashed stream leaves a stale row; the 300s bound keeps orphans from
# deferring rotates forever (the drain timeout bounds each wait regardless).
db_stream_open() {
  local n
  [ -f "${DB_FILE:-}" ] || return 1
  n=$(sqlite3 "$DB_FILE" \
    "SELECT COUNT(*) FROM session_message
       WHERE type='assistant'
         AND time_created = (SELECT MAX(time_created) FROM session_message WHERE type='assistant')
         AND time_created > $(( $(now) - 300 )) * 1000
         AND json_extract(data,'\$.finish') IS NULL
         AND json_extract(data,'\$.error.type') IS NULL;" 2>/dev/null) || return 1
  case "$n" in ''|*[!0-9]*) return 1;; esac
  [ "$n" -gt 0 ]
}
stream_open() {
  [ -f "${ZEN_STREAM_FILE:-$STATE_DIR/stream_open}" ] && return 0
  db_stream_open
}

# stream_drain_wait <reason> — hold the rotate while a stream is open, polling
# each second up to ZEN_DRAIN_S. Logs deferred, then drained or timeout, so a
# deferred rotate is visible as deferred, never silent and never mid-stream.
stream_drain_wait() {
  local reason=$1 drain waited=0
  stream_open || return 0
  drain=${ZEN_DRAIN_S:-1}
  case "$drain" in ''|*[!0-9]*) drain=1;; esac
  log "deferred: stream open, waiting up to ${drain}s for drain before rotate ($reason)"
  while stream_open && [ "$waited" -lt "$drain" ]; do
    sleep 1
    waited=$((waited + 1))
  done
  if stream_open; then
    log "drain timeout after ${drain}s with stream still open, rotating ($reason)"
  else
    log "stream drained after ${waited}s, rotating ($reason)"
  fi
}

do_rotate() {
  local reason="$1" line rc=0 m ip6_before="" ip6_after=""
  m=$(mode_now)
  stream_drain_wait "$reason"
  log "route path: $(model_path "$MKEY") for model ${MKEY:-shared} (reason $reason)"
  log "rotate start ($reason) mode=$m"
  notify_rot start low "WARP rotation started" \
    "Zen free model returned 429 ($reason). WARP is reconnecting; OpenCode will retry after its backoff."
  rotate_pick_path                                  # step 1 (was inline below)
  rc=0; rotate_run_adapter "$ROTATE_FIRST" || rc=$?   # step 2 (was out=$(...))
  if [ "$rc" -ne 0 ] && { [ "$ROTATE_SECOND" = "primary" ] || [ -n "${ZEN_ROTATE_SECONDARY:-}" ]; }; then
    log "$ROTATE_FIRST egress failed (rc=$rc), failing over to $ROTATE_SECOND"
    rc=0; rotate_run_adapter "$ROTATE_SECOND" || rc=$?
    if [ "$rc" -eq 0 ]; then
      EGRESS_PATH=$ROTATE_SECOND
      [ "$ROTATE_SECOND" = "secondary" ] && log "secondary egress took the rotate"
    fi
  fi
  log "egress path: $EGRESS_PATH (reason $reason)"
  while IFS= read -r line || [ -n "$line" ]; do log "  $line"; done < "$ROTATE_OUT"
  # Herestring-of-empty fed one blank line; an empty Adapter file must too.
  [ -s "$ROTATE_OUT" ] || log "  "

  rotate_record_verdict "$reason" "$rc"              # step 3 (was inline below)
  ip6_before=$ROTATE_BEFORE6
  ip6_after=$ROTATE_AFTER6
  if [ "$rc" -eq 0 ] && [ -n "$ip6_before" ] && [ "$ip6_before" = "$ip6_after" ]; then
    # IPv6 is the only family that actually carries traffic here (measured:
    # curl -4 and -6 through :44444 both return IPv6). Same address back means
    # the same Cloudflare edge, so the session was reset but the egress did not
    # move. Rotating again usually lands on the same edge — measured 10% of the
    # time, and when it happens the retry is a pure extra outage for the user's
    # in-flight request. So the default MAX_STUCK=1 stops here and says so.
    # NOTE: judging this on IPv4 was wrong. IPv4 sits in a ~6-address pool and
    # repeats constantly while IPv6 moves every time, so an IPv4 test marked
    # genuinely useful rotations as ineffective and blocked them.
    local stuck; stuck=$(state_get stuck_edge 0)
    case "$stuck" in ''|*[!0-9]*) stuck=0;; esac
    stuck=$((stuck + 1)); state_set stuck_edge "$stuck"
    state_set last_rotate "$(now)"
    state_clear last_failed
    clear_burst
    if [ "$stuck" -ge "$MAX_STUCK" ]; then
      # Do NOT just clear the latch. Clearing it is what made this useless:
      # a fresh 429 one second later re-armed handle_signal, the daemon rotated
      # again, landed on the same edge, and repeated. Measured with MAX_STUCK=1:
      # 6 consecutive 429s cut the tunnel 6 times. The edge is not going to
      # move on its own, so park instead — a cooldown is the ONLY thing that
      # makes "stop" mean stop.
      state_set stuck_until "$(( $(now) + STUCK_PARK ))"
      log "rotate stopped: IPv6 edge stuck on $ip6_after — parked ${STUCK_PARK}s, no more tunnel cuts for this edge mode=$m"
      state_clear need_rotate
      notify_rot done critical "WARP egress did not change" \
        "WARP returned the same IPv6 route. Rotations are paused for ${STUCK_PARK}s to protect active requests. The 429 may need to clear on its own."
      return 2
    fi
    log "rotate on the same IPv6 edge ($ip6_after), attempt $stuck/$MAX_STUCK mode=$m"
  elif [ "$rc" -eq 0 ]; then
    state_set stuck_edge 0
  fi

  if [ "$rc" -ne 0 ]; then
    # The rotator exits non-zero only when WARP never came back up — traffic
    # through :44444 is actually down. A repeated egress address is NOT a
    # failure: the tunnel reset is what clears a rate limit, and the address
    # pool is small by design. Do not stamp last_rotate and do not clear the
    # latch, but back off so a dead tunnel is not retried every poll.
    state_set last_failed "$(now)"
    rm -f "$BACKOFF_LOGGED_FILE"
    log "rotate FAILED (rc=$rc) — WARP did not come up, another rotate allowed after ${ROTATE_BACKOFF}s mode=$m"
    notify_rot failed critical "WARP reconnect failed" \
      "The WARP route did not reconnect (exit $rc). Another attempt is allowed in ${ROTATE_BACKOFF}s."
    return 1
  fi

  state_set last_rotate "$(now)"
  state_clear last_failed
  state_clear need_rotate
  clear_burst
  log "rotate done mode=$m"
  if [ -n "$ip6_after" ]; then
    notify_rot done normal "WARP route ready" \
      "Egress IPv6: ${ip6_after:-unknown}. OpenCode will retry automatically."
  else
    notify_rot done normal "WARP route ready" \
      "The WARP session was reset. OpenCode will retry automatically."
  fi
  return 0
}

# --- decision rules ------------------------------------------------------------
# Small pure-ish rule functions with a clear Interface, shared by
# handle_signal (fresh 429s: latch + log on hold) and handle_latch (pending
# latch: silent hold). Rules only check state and account fails; each caller
# keeps its own side effects (latch text, log lines, waits, notifies).
# All are instant (file reads only, no sleeps) — see tests/test-rules.sh.

# park_active — print the stuck-edge park-until epoch and rc 0 while the park
# is active (marker in the future). rc 1 (silent) when missing, corrupt, or
# expired. Never clears: handle_signal drops corrupt markers itself,
# handle_latch keeps them — that difference stays at the callers.
park_active() {
  local park
  park=$(state_get stuck_until 0)
  case "$park" in ''|*[!0-9]*) return 1;; esac
  [ "$park" -gt "$(now)" ] || return 1
  printf '%s' "$park"
}

# park_expire — clear an expired park marker and grant a fresh stuck budget.
# rc 0 when it expired something; rc 1 (no-op) when missing, corrupt, or
# still active. Call after park_active says held.
park_expire() {
  local park
  park=$(state_get stuck_until 0)
  case "$park" in ''|*[!0-9]*) return 1;; esac
  [ "$park" -gt 0 ] || return 1
  [ "$park" -gt "$(now)" ] && return 1
  state_clear stuck_until
  state_set stuck_edge 0
}

# window_inside <window-secs> — print the dedupe age and rc 0 when the last
# rotate stamp is inside the window (429s here only backoff, never rotate).
# rc 1 when missing, corrupt, zero, or outside the window.
window_inside() {
  local dw=$1 stamp age
  stamp=$(state_get dedupe_stamp 0)
  case "$stamp" in ''|*[!0-9]*) return 1;; esac
  [ "$stamp" -gt 0 ] || return 1
  age=$(( $(now) - stamp ))
  [ "$age" -lt "$dw" ] || return 1
  printf '%s' "$age"
}

# window_note_fail <quota-park-secs> — count one failed window (429s
# survived a full dedupe window after a rotate). At MAX_WINDOW_FAILS
# consecutive fails set the quota park and reset the counter. Prints the new
# fail count; rc 1 when it just parked (the caller logs + notifies, so the
# log order stays exactly as before), rc 0 otherwise.
window_note_fail() {
  local qp=$1 fails
  fails=$(window_fail_inc)
  if [ "$fails" -ge "$MAX_WINDOW_FAILS" ]; then
    state_set quota_until "$(( $(now) + qp ))"
    window_fail_reset
    printf '%s' "$fails"
    return 1
  fi
  printf '%s' "$fails"
}

# single_guard_hold — rc 0 when a lone 429 must only backoff, in BOTH modes:
# fewer than 2 signals inside BURST_WINDOW (an isolated blip clears on the
# client's own retry; rotating costs a ~7s blip, and in proxy mode the rotate
# cannot clear quota anyway). Pure check, no side effects.
single_guard_hold() {
  [ "$(eff_single_guard)" = 1 ] || return 1
  [ "$(burst_count)" -lt 2 ]
}

# --- storm cap: max rotates per rolling window --------------------------------
# Six rotates in two minutes cut the :44444 proxy ~7s each and every MCP
# remote died in a row. Sparse lone-429 rotates are intended; storms are the
# pathology. Past the cap the signal latches with a storm-park log and no
# cut, until the window slides (the next signal/latch re-checks).
# Per-model keys: the storm file is bound by bind_model like burst/dedupe.
# Tuned default ZEN_STORM_MAX=0 means OFF: capped never fires and record
# never writes, so the tuned decision path stays byte-identical.
# storm_count — rotates inside ZEN_STORM_WINDOW (echoes 0 when off/missing).
storm_count() {
  local cutoff n=0 ts
  [ "${ZEN_STORM_MAX:-0}" -gt 0 ] 2>/dev/null || { echo 0; return 0; }
  cutoff=$(( $(now) - ${ZEN_STORM_WINDOW:-600} ))
  state_has storm || { echo 0; return 0; }
  while read -r ts; do
    case "$ts" in ''|*[!0-9]*) continue;; esac
    [ "$ts" -ge "$cutoff" ] && n=$((n + 1))
  done < "$(state_path storm)"
  echo "$n"
}

# storm_capped — rc 0 + print wait secs when rotates in window >= MAX.
# rc 1 when off, under cap, or file missing. Pure check, no side effects.
storm_capped() {
  local max=${ZEN_STORM_MAX:-0} win=${ZEN_STORM_WINDOW:-600} cutoff n=0 ts oldest=0
  case "$max" in ''|*[!0-9]*) return 1;; esac
  [ "$max" -gt 0 ] 2>/dev/null || return 1
  case "$win" in ''|*[!0-9]*) win=600;; esac
  cutoff=$(( $(now) - win ))
  state_has storm || return 1
  while read -r ts; do
    case "$ts" in ''|*[!0-9]*) continue;; esac
    [ "$ts" -ge "$cutoff" ] || continue
    n=$((n + 1))
    if [ "$oldest" -eq 0 ] || [ "$ts" -lt "$oldest" ]; then oldest=$ts; fi
  done < "$(state_path storm)"
  [ "$n" -ge "$max" ] || return 1
  printf '%s' "$(( oldest + win - $(now) ))"
}

# storm_record — append one rotate epoch, keep last 20. No-op when off, so
# the tuned path neither writes nor reads storm state.
storm_record() {
  [ "${ZEN_STORM_MAX:-0}" -gt 0 ] 2>/dev/null || return 0
  echo "$(now)" >> "$(state_path storm)"
  tail -20 "$(state_path storm)" > "$(state_path storm).tmp" 2>/dev/null \
    && mv "$(state_path storm).tmp" "$(state_path storm)"
}

# --- aggressive retry choreography (ZEN_AGGRESSIVE=1 only) ----------------------
# User-specified pacing per cycle (aggressive path only; tuned never calls here):
#   hold-new-requests pause (= existing stream_drain_wait inside do_rotate,
#     bounded by ZEN_DRAIN_S, no new sleep) -> warp down -> wait DOWN_HOLD 2s
#   (existing, inside reconnect) -> warp up (wait_connected + wait_ready
#   readiness probes already inside reconnect stay as-is) -> post-up
#   readiness-gated wait (cap ZEN_CHOREO_POST_UP_S 2s: poll the same probes
#   after up, proceed the moment they pass, never slower than the old fixed
#   sleep) -> mark ready (client retries flow at once) -> settle success-gated
#   watch (cap ZEN_CHOREO_SETTLE_S 3s: stop on first 429 or on no-429 plus a
#   new Zen OK row; fallback first-429-or-cap when no success evidence is
#   daemon-observable).
# A 429 inside the window repeats the cycle IMMEDIATELY (no dedupe/backoff
# between cycles). A clean window stops and normal watch resumes.
# Safety escape hatch (disclosed in log + README, never silent): after
# ZEN_CHOREO_MAX consecutive fruitless cycles (each followed by 429 within
# its window), fall back to the existing quota-park path (quota_until =
# now + per-mode park, latch kept). This bounds the 7s-outage churn; the
# storm cap (3/600) stays as the outer bound and is checked every cycle.
# choreo_probe_ready — one-shot egress-readiness check with the existing
# readiness probes (warp-cli Connected like wait_connected, egress serving
# like wait_ready/egress_ipv6). Test seam first: ZEN_CHOREO_READY_FILE set
# means ready iff that file exists (fake state, no tunnel touch).
# Production (unset) runs the real probes. rc 0 ready, 1 not yet.
choreo_probe_ready() {
  if [ -n "${ZEN_CHOREO_READY_FILE:-}" ]; then
    [ -f "$ZEN_CHOREO_READY_FILE" ] && return 0 || return 1
  fi
  warp-cli status 2>/dev/null | grep -q 'Connected' || return 1
  egress_ipv6 >/dev/null 2>&1
}

# choreo_post_up_wait <cap-secs> <reason> — readiness-gated post-up wait.
# Poll choreo_probe_ready every 0.2s; proceed the moment the probes pass,
# capped at cap (never slower than the old fixed sleep — the sleeps, not the
# probes, are capped; after a good rotate the route just served so the first
# probe passes in milliseconds). Logs ready-by-probe vs ready-by-cap.
# rc 0 always.
choreo_post_up_wait() {
  local cap=${1:-2} reason=${2:-} m waited=0 _polls _i
  m=$(mode_now)
  case "$cap" in ''|*[!0-9]*) cap=2;; esac
  log "choreo: warp up, readiness-gated post-up wait up to ${cap}s (probes: wait_connected/wait_ready) ($reason) mode=$m"
  if [ "$cap" -le 0 ] 2>/dev/null; then
    log "choreo: post-up ready-by-probe after 0s (cap ${cap}s, nothing to wait) ($reason) mode=$m"
    return 0
  fi
  if choreo_probe_ready 2>/dev/null; then
    log "choreo: post-up ready-by-probe after 0s (cap ${cap}s) ($reason) mode=$m"
    return 0
  fi
  _polls=$(( cap * 5 ))
  [ "$_polls" -gt 0 ] 2>/dev/null || _polls=10
  _i=0
  while [ "$_i" -lt "$_polls" ]; do
    sleep 0.2
    waited=$(( waited + 1 ))
    if choreo_probe_ready 2>/dev/null; then
      log "choreo: post-up ready-by-probe after ~$(( waited / 5 )).$(( (waited % 5) * 2 ))s (cap ${cap}s) ($reason) mode=$m"
      return 0
    fi
    _i=$(( _i + 1 ))
  done
  log "choreo: post-up ready-by-cap after ${cap}s, probes never passed ($reason) mode=$m"
  return 0
}

# choreo_db_success_since <start-ms> — count new Zen success rows newer than
# the marker. Success is the report's OK definition, Zen-scoped: an assistant
# row for provider opencode on a free model with no error.type and a terminal
# finish (stop/tool-calls). Prints the count, or UNOBSERVABLE (rc 2) when no
# DB success evidence can be read daemon-side (missing DB file or unreadable
# table). Never advances the 429 cursor.
choreo_db_success_since() {
  local start_ms=${1:-0} n mlist
  [ -f "${DB_FILE:-}" ] || { printf 'UNOBSERVABLE'; return 2; }
  # free_model_sql() is never empty (the suffix rule is self-contained), so
  # the old empty-list fallback branch is dead and has been removed.
  mlist=$(free_model_sql)
  n=$(sqlite3 "$DB_FILE" \
    "SELECT COUNT(*) FROM session_message WHERE type='assistant'
       AND CASE WHEN json_valid(data) THEN
         json_extract(data,'\$.model.providerID')='opencode'
         AND ($mlist)
         AND json_extract(data,'\$.error.type') IS NULL
         AND json_extract(data,'\$.finish') IN ('stop','tool-calls')
       ELSE 0 END
       AND time_created > $start_ms;" 2>/dev/null) \
    || { printf 'UNOBSERVABLE'; return 2; }
  case "$n" in ''|*[!0-9]*) printf 'UNOBSERVABLE'; return 2;; esac
  printf '%s' "$n"
}

# choreo_settle_watch <cap-secs> <reason> <cycle> — success-gated settle watch.
# Poll every 0.5s up to cap, accumulating fresh 429s (consuming the signal/DB
# cursors exactly like any detect path, so a counted 429 never fires twice):
# stop early on the first 429 (caller repeats immediately) or when recovery
# is proven (no 429 so far AND a new Zen OK row via choreo_db_success_since).
# When no success evidence is daemon-observable (no DB/table), fall back to
# first-429-or-cap and say so in the log — never pretend a success was seen.
# Prints "<429-count> <stop>" with stop in success|cap|429 (429 exactly when
# the count is > 0). rc 0 always; the caller owns the repeat/clean log lines.
choreo_settle_watch() {
  local cap=${1:-3} reason=${2:-} cyc=${3:-?} m total=0
  local start_ms obs=1 _polls _i s d ok
  m=$(mode_now)
  case "$cap" in ''|*[!0-9]*) cap=3;; esac
  start_ms=$(date +%s%3N 2>/dev/null || echo '')
  case "$start_ms" in ''|*[!0-9]*) start_ms=$(( $(now) * 1000 ));; esac
  ok=$(choreo_db_success_since "$start_ms" 2>/dev/null) || ok="UNOBSERVABLE"
  if [ "$ok" = "UNOBSERVABLE" ]; then obs=0; fi
  log "choreo: settle ${cap}s success-gated watch (stop on first 429 or new Zen OK row; fallback first-429-or-cap when unobservable) ($reason) mode=$m"
  if [ "$cap" -le 0 ] 2>/dev/null; then
    s=$(detect_429_new 2>/dev/null); case "$s" in ''|*[!0-9]*) s=0;; esac
    d=$(detect_429_db 2>/dev/null); case "$d" in ''|*[!0-9]*) d=0;; esac
    total=$(( s + d ))
    if [ "$total" -gt 0 ]; then printf '%s 429' "$total"; return 0; fi
    if [ "$obs" -eq 1 ]; then
      log "choreo: settle stopped-by-cap after 0s with no 429 and no new Zen OK row ($reason) mode=$m"
    else
      log "choreo: settle stopped-by-cap after 0s with no 429 (no success evidence observable: no DB/table at ${DB_FILE:-unset} — fallback first-429-or-cap) ($reason) mode=$m"
    fi
    printf '0 cap'
    return 0
  fi
  _polls=$(( cap * 2 ))
  [ "$_polls" -gt 0 ] 2>/dev/null || _polls=6
  _i=0
  while [ "$_i" -lt "$_polls" ]; do
    sleep 0.5
    _i=$(( _i + 1 ))
    s=$(detect_429_new 2>/dev/null); case "$s" in ''|*[!0-9]*) s=0;; esac
    d=$(detect_429_db 2>/dev/null); case "$d" in ''|*[!0-9]*) d=0;; esac
    total=$(( total + s + d ))
    if [ "$total" -gt 0 ]; then
      printf '%s 429' "$total"
      return 0
    fi
    if [ "$obs" -eq 1 ]; then
      ok=$(choreo_db_success_since "$start_ms" 2>/dev/null) || ok="0"
      case "$ok" in ''|*[!0-9]*) ok=0;; esac
      if [ "$ok" -gt 0 ]; then
        log "choreo: settle stopped-by-success after ~$((_i / 2))s (no 429 and $ok new Zen OK row(s)) ($reason) mode=$m"
        printf '0 success'
        return 0
      fi
    fi
  done
  if [ "$obs" -eq 1 ]; then
    log "choreo: settle stopped-by-cap after ${cap}s with no 429 and no new Zen OK row ($reason) mode=$m"
  else
    log "choreo: settle stopped-by-cap after ${cap}s with no 429 (no success evidence observable: no DB/table at ${DB_FILE:-unset} — fallback first-429-or-cap) ($reason) mode=$m"
  fi
  printf '0 cap'
  return 0
}
# choreo_observe_new — count fresh 429s (signal bytes + DB rows) since the
# last scan. Consumes the cursors like any detect path (detect_429_new /
# detect_429_db own them), so a counted 429 never fires twice.
choreo_observe_new() {
  local s=0 d=0
  s=$(detect_429_new 2>/dev/null); case "$s" in ''|*[!0-9]*) s=0;; esac
  d=$(detect_429_db 2>/dev/null); case "$d" in ''|*[!0-9]*) d=0;; esac
  echo $(( s + d ))
}

# choreo_escape_to_park <quota-park-secs> <fruitless> <reason> — safety hatch:
# park instead of cutting again. Logs the disclosure (not silent), notifies,
# keeps the latch for after the park. Always returns 2 (waiting).
choreo_escape_to_park() {
  local qp=$1 fruitless=$2 reason=$3 m
  m=$(mode_now)
  state_set quota_until "$(( $(now) + qp ))"
  window_fail_reset
  state_set need_rotate "$MKEY"
  log "choreo: escape hatch after $fruitless consecutive fruitless cycles (each followed by 429 in window) — falling back to quota-park ${qp}s path, no more immediate cuts ($reason) mode=$m"
  notify_rot quota critical "Choreography escape: quota park" \
    "429 survived $fruitless immediate rotate cycles. Parking ${qp}s — further cuts would only churn the tunnel."
  return 2
}

# aggressive_choreo <base-reason> <dedupe-key> — run the immediate-repeat
# loop. Caller has already passed every first-cycle guard (quota park, stuck
# park, dedupe, single guard off, cooldown, storm); between cycles none of
# those are re-checked except the storm outer bound. Returns 0 on a clean
# window (rotated, watch resumes), 2 on escape/storm/failure/stuck-stop.
aggressive_choreo() {
  local base_reason=$1 key=$2 m qp
  local post settle max cyc=0 fruitless=0 reason rc new _sw settle_out stop
  m=$(mode_now)
  qp=$(eff_quota_park)
  post=${ZEN_CHOREO_POST_UP_S:-2}; case "$post" in ''|*[!0-9]*) post=2;; esac
  settle=${ZEN_CHOREO_SETTLE_S:-3}; case "$settle" in ''|*[!0-9]*) settle=3;; esac
  max=${ZEN_CHOREO_MAX:-3}; case "$max" in ''|*[!0-9]*) max=3;; esac
  log "choreo: start pacing hold/drain + down ${DOWN_HOLD:-2}s + post-up readiness-gated (cap ${post}s) + settle success-gated (cap ${settle}s), escape after ${max} fruitless ($base_reason) mode=$m"
  while true; do
    cyc=$((cyc + 1))
    reason="${base_reason}-c${cyc}"
    if _sw=$(storm_capped); then
      case "$_sw" in ''|*[!0-9]*) _sw=0;; esac
      state_set need_rotate "$MKEY"
      log "storm-park: $(storm_count) rotates in ${ZEN_STORM_WINDOW}s window >= max ${ZEN_STORM_MAX} — holding ${_sw}s until window slides, no rotate model=${MKEY:-shared} mode=$m"
      return 2
    fi
    log "choreo: hold-new-requests pause before cycle $cyc ($reason) mode=$m"
    do_rotate "$reason"; rc=$?
    state_set dedupe_stamp "$(now)"
    state_set dedupe_key "$key"
    storm_record
    if [ "$rc" -eq 0 ]; then
      window_fail_reset
    elif [ "$rc" -eq 2 ]; then
      return 2
    else
      state_set need_rotate "$MKEY"
      return 2
    fi
    choreo_post_up_wait "$post" "$reason"
    log "choreo: ready — client retries flow at once ($reason) mode=$m"
    settle_out=$(choreo_settle_watch "$settle" "$reason" "$cyc")
    new=${settle_out%% *}; stop=${settle_out##* }
    case "$new" in ''|*[!0-9]*) new=0;; esac
    [ -n "$stop" ] || stop=cap
    if [ "$new" -gt 0 ]; then
      fruitless=$((fruitless + 1))
      log "choreo: still-429 x$new in ${settle}s window after cycle $cyc (fruitless $fruitless/$max) — repeating immediately, no dedupe/backoff (repeat-on-429) mode=$m"
      if [ "$fruitless" -ge "$max" ]; then
        choreo_escape_to_park "$qp" "$fruitless" "$reason"
        return 2
      fi
      key=$(dedupe_key_now)
      continue
    fi
    if [ "$stop" = "success" ]; then
      log "choreo: clean ${settle}s window after cycle $cyc — stopping, normal watch resumes (stopped-by-success) mode=$m"
    else
      log "choreo: clean ${settle}s window after cycle $cyc — stopping, normal watch resumes (stopped-by-cap) mode=$m"
    fi
    return 0
  done
}

# handle_signal <count> [model] — decide what to do about N fresh rate-limit
# signals for one model ("": legacy shared keys for the DB/quota paths).
handle_signal() {
  local sig=$1 burst rc park quota_until dedupe_age key fails parked ra m dw qp reason
  bind_model "${2:-}"
  # Second lock behind the detect-layer jev guard: an off-path model never
  # reaches the rotator call, even if a future detect change lets one through.
  if [ -n "$MKEY" ] && [ "$(model_path "$MKEY")" = "off" ]; then
    log "refusing signal for off-path model $MKEY (never routed)"
    return 1
  fi
  m=$(mode_now)
  # Per-mode storm guards. Proxy keeps the current values (dedupe 90s, park
  # 600s — rotating is useless there). Tunnel rotates short and often and
  # only ever takes a short breather.
  dw=$(eff_dedupe_window); qp=$(eff_quota_park)
  record_signal "$sig"
  burst=$(burst_count)

  # Active quota park from the cursor-based classifier in check_once: hold.
  if quota_parked; then
    quota_until=$(state_get quota_until 0)
    state_set need_rotate "$MKEY"
    log "holding: quota park until $quota_until — backoff, no rotate mode=$m"
    return 2
  fi

  # Same-edge park is RESPECTED, not deleted: a fresh Zen signal inside the
  # park merges/keeps it (latch for after the park) instead of clearing it.
  # Deleting it here is what made the 10s park meaningless and turned
  # attempts 2..11 into a rotate storm with COOLDOWN=0.
  case "$(state_get stuck_until 0)" in ''|*[!0-9]*)
    # Corrupt marker: drop the file but do NOT treat as "park over, budget
    # fresh" — keep the stuck counter as-is instead of resetting to 0.
    state_clear stuck_until; park=0;;
  esac
  if park=$(park_active); then
    state_set need_rotate "$MKEY"
    log "saw $sig rate-limit line(s) during same-edge park (until $park) — latched, park kept mode=$m"
    return 2
  fi
  park_expire

  # Dedupe: 1 rotate per window per (model, route/48, minute) key.
  # 429s inside the window only backoff (Retry-After capped, else fixed);
  # 3 consecutive failed windows -> park + notify. Window and park are
  # per-mode: proxy keeps 90s/600s, tunnel uses short/short (rotate is the cure).
  key=$(dedupe_key_now)
  if dedupe_age=$(window_inside "$dw"); then
    ra=$(retry_after_secs)
    [ "$ra" -gt 0 ] || ra=1
    state_set need_rotate "$MKEY"
    fails=$(window_note_fail "$qp"); parked=$?
    log "dedupe hit key=$key age=${dedupe_age}s (window ${dw}s) — backoff ${ra}s, no rotate (fail $fails/$MAX_WINDOW_FAILS) mode=$m"
    if [ "$parked" -ne 0 ]; then
      log "quota-window: $MAX_WINDOW_FAILS consecutive windows still 429 — parking ${qp}s instead of hammering mode=$m"
      notify_rot quota critical "Quota window persisting" \
        "429s survived $MAX_WINDOW_FAILS rotate windows on $key. Parking ${qp}s — the edge is not helping."
    fi
    wait_hint "$ra"
    return 2
  fi

  # Single-429 guard (both modes): the FIRST 429 inside BURST_WINDOW only
  # backs off (Retry-After capped, else 1s) and latches — it must NOT cut the
  # tunnel. A lone 429 usually clears on the client's own retry; rotating on
  # it costs every session a ~7s blip (down-window + up-window + full retry),
  # and proxy-pool rotates never clear quota at all. Rotate only with evidence
  # the quota persists: a 2nd signal inside the window (burst>=2 falls through
  # to rotate below) or the latch in check_once still seeing burst>=2 after
  # the dedupe window.
  if single_guard_hold; then
    ra=$(retry_after_secs)
    [ "$ra" -gt 0 ] || ra=1
    state_set need_rotate "$MKEY"
    log "single-429 backoff ${ra}s: first 429 in ${BURST_WINDOW}s window (burst=$burst) — no rotate, waiting for a 2nd signal mode=$m"
    wait_hint "$ra"
    return 2
  fi

  # Only active when COOLDOWN > 0 (not the default — see the COOLDOWN knob).
  if cooling_down; then
    state_set need_rotate "$MKEY"
    log "saw $sig rate-limit line(s) (burst=$burst) but cooling down — latched mode=$m"
    return 2
  fi

  # Storm cap (aggressive default 3 per 600s; tuned off): past the cap the
  # signal latches with no cut until the window slides. Checked last, right
  # before the cut, so holds above never consume storm budget.
  if _storm_wait=$(storm_capped); then
    case "$_storm_wait" in ''|*[!0-9]*) _storm_wait=0;; esac
    state_set need_rotate "$MKEY"
    log "storm-park: $(storm_count) rotates in ${ZEN_STORM_WINDOW}s window >= max ${ZEN_STORM_MAX} — holding ${_storm_wait}s until window slides, no rotate model=${MKEY:-shared} mode=$m"
    return 2
  fi

  # Rotate at once for a fresh hook signal. The request hook waits for this reset
  # and schedules a bounded retry. Repeated 429s in the same episode do not send
  # another hook signal, so they do not repeatedly cut the user's WARP traffic.
  if [ "$burst" -ge "$BURST_COUNT" ]; then
    reason="429-burst($burst)"
  else
    reason="429-signal($sig)"
  fi
  reason="$reason${MKEY:+:$MKEY}"
  if [ "$burst" -ge "$BURST_COUNT" ]; then
    log "burst ($burst signals in ${BURST_WINDOW}s) — rotating immediately (down-window so client retries) model=${MKEY:-shared} mode=$m"
  else
    log "saw $sig rate-limit line(s) — rotating immediately (down-window so client retries) model=${MKEY:-shared} mode=$m"
  fi

  # Aggressive path: immediate-repeat choreography (tuned falls through to
  # the single do_rotate below byte-for-byte unchanged).
  if [ "${ZEN_AGGRESSIVE:-0}" = "1" ]; then
    aggressive_choreo "$reason" "$key"; rc=$?
    return "$rc"
  fi
  do_rotate "$reason"; rc=$?
  # Stamp the dedupe window on every actual rotate (success OR stuck-stop —
  # both cut the tunnel, so both count as "the rotate for this window").
  state_set dedupe_stamp "$(now)"
  state_set dedupe_key "$key"
  storm_record
  if [ "$rc" -eq 0 ]; then window_fail_reset; return 0; fi
  # rc 2 = do_rotate gave up on purpose (IPv6 edge stuck) and already
  # cleared the latch. Re-writing it here would restart the thing it just
  # stopped: measured, one extra live tunnel cut after every give-up, and
  # the notification would claim "stopped" while it was still rotating.
  [ "$rc" -eq 2 ] && return 2
  state_set need_rotate "$MKEY"
  return 2
}

# handle_latch <m> <dw> <qp> — fire one bound model's latched rotate.
# Files are already scoped by bind_model; legacy ("") keeps shared behavior.
handle_latch() {
  local m=$1 dw=$2 qp=$3 rc fb _lkey _lage _lra _lfails _parked
  if [ -n "$MKEY" ] && [ "$(model_path "$MKEY")" = "off" ]; then
    state_clear need_rotate
    log "dropping latched off-path model $MKEY (never routed)"
    return 1
  fi
  # Latch pending and still cooling down: leave it for the next event.
  if cooling_down; then return 2; fi

  # Quota backoff/park active: hold the latch, do not rotate.
  if quota_parked; then return 2; fi

  # A 429 can be latched while a same-edge park is active. Do not rotate during
  # the park; retry once it expires instead of waiting for an unrelated event.
  # Corrupt markers are kept here (only the signal path drops them).
  if park_active >/dev/null; then return 2; fi
  park_expire

  # A previous rotate failed. Wait out the backoff instead of reconnecting every
  # round, which would keep dropping the proxy for nothing.
  if rotate_blocked; then
    # Log once when the backoff starts, not on every wakeup, otherwise a dead
    # tunnel writes a line every poll interval for the whole backoff.
    fb=$(state_get last_failed 0)
    case "$fb" in ''|*[!0-9]*) fb=0;; esac
    if [ ! -f "$BACKOFF_LOGGED_FILE" ] || [ "$fb" -gt "$(cat "$BACKOFF_LOGGED_FILE" 2>/dev/null || echo 0)" ]; then
      echo "$fb" > "$BACKOFF_LOGGED_FILE"
      log "latched rate limit — holding off ${ROTATE_BACKOFF}s after a failed rotate mode=$m"
    fi
    return 2
  fi
  rm -f "$BACKOFF_LOGGED_FILE"

  # Latched rotates are bound by the same per-mode dedupe window: a latch
  # firing inside the window of the last rotate only backoffs (counts as a
  # failed window), otherwise attempts 2..11 each cut the tunnel again.
  _lkey=$(dedupe_key_now)
  if _lage=$(window_inside "$dw"); then
    _lra=$(retry_after_secs)
    [ "$_lra" -gt 0 ] || _lra=1
    _lfails=$(window_note_fail "$qp"); _parked=$?
    log "latched rate limit inside dedupe window (key=$_lkey age=${_lage}s) — backoff ${_lra}s, no rotate (fail $_lfails/$MAX_WINDOW_FAILS) mode=$m"
    if [ "$_parked" -ne 0 ]; then
      log "quota-window: $MAX_WINDOW_FAILS consecutive windows still 429 — parking ${qp}s instead of hammering mode=$m"
      notify_rot quota critical "Quota window persisting" \
        "429s survived $MAX_WINDOW_FAILS rotate windows on $_lkey. Parking ${qp}s — the edge is not helping."
    fi
    wait_hint "$_lra"
    return 2
  fi

  # Single-429 guard (latch half, both modes): a latched first-429 that never
  # saw a 2nd signal inside BURST_WINDOW is an isolated blip — clear it, no
  # rotate. Rotation needs burst>=2 (persistence evidence); the fresh-signal
  # half of this guard lives in handle_signal.
  if single_guard_hold; then
    state_clear need_rotate
    log "latched single-429 expired with no 2nd signal in ${BURST_WINDOW}s — clearing, no rotate mode=$m"
    return 1
  fi

  # Storm cap (same knobs as the signal path): a latched rotate past the cap
  # holds with no cut until the window slides. The latch file stays, so the
  # next round re-checks after the slide.
  if _storm_wait=$(storm_capped); then
    case "$_storm_wait" in ''|*[!0-9]*) _storm_wait=0;; esac
    log "storm-park: $(storm_count) rotates in ${ZEN_STORM_WINDOW}s window >= max ${ZEN_STORM_MAX} — holding ${_storm_wait}s until window slides, no rotate model=${MKEY:-shared} mode=$m"
    return 2
  fi

  log "latched rate limit — rotating immediately model=${MKEY:-shared} mode=$m"
  # Aggressive path: immediate-repeat choreography (tuned falls through to
  # the single do_rotate below byte-for-byte unchanged).
  if [ "${ZEN_AGGRESSIVE:-0}" = "1" ]; then
    aggressive_choreo "429-latched${MKEY:+:$MKEY}" "$_lkey"; rc=$?
    return "$rc"
  fi
  do_rotate "429-latched${MKEY:+:$MKEY}"; rc=$?
  state_set dedupe_stamp "$(now)"
  state_set dedupe_key "$_lkey"
  storm_record
  [ "$rc" -eq 0 ] && return 0
  return 2   # rc 2 = stopped on a stuck edge; latch already cleared
}

# check_once — one full round. rc 0 rotated, 1 nothing to do, 2 waiting.
check_once() {
  local sig db_sig db_models rc m dw qp
  m=$(mode_now)
  dw=$(eff_dedupe_window); qp=$(eff_quota_park)
  bind_model ""   # legacy shared keys until a branch scopes to one model
  _WAITED_ROUND=0   # one capped hint-pause per round at most (see wait_hint)

  # Always scan for 403s first: they are informational and must never block or
  # trigger a rotate, but they should still be recorded on every round.
  report_403 "$(note_403_new)"

  # Quota-exhausted lines (spent budget/balance) match QUOTA_TEXT but NOT the
  # 429 PATTERN, so they never reach handle_signal via sig — check them here
  # first. In PROXY mode: backoff only, NEVER rotate (a new IP cannot refill a
  # budget). In TUNNEL mode: quota-text ALSO rotates — measured, even a
  # quota-worded 429 clears after ≤2 rotates on the system tunnel, so here
  # every 429 is treated as a throttle and goes through the normal path.
  # Uses its own cursor tag so 429 and quota account the same bytes apart.
  local quota_sig
  quota_sig=$(scan_new "$QUOTA_TEXT" quota)
  if [ "${quota_sig:-0}" -gt 0 ]; then
    if [ "$(eff_quota_rotates)" = 1 ]; then
      log "quota-text x$quota_sig in tunnel mode — treating as throttle, rotating mode=$m"
      handle_signal "$quota_sig"
      return $?
    fi
    local ra; ra=$(retry_after_secs)
    [ "$ra" -gt 0 ] || ra=3
    state_set quota_until "$(( $(now) + ra ))"
    state_set need_rotate "$(date +%s)"
    log "quota-exhausted x$quota_sig (not rate-limit) — backing off ${ra}s, NOT rotating mode=$m"
    return 2
  fi

  # The hook is authoritative because its lines carry the model ID and only
  # free-tier IDs (is_free_model) count. The DB is a fallback for missed hook
  # signals, but can report the same 429 after the hook already caused a
  # rotate. Do not sum those observations.
  # Attribute fresh signals per model BEFORE the count advances the cursor.
  # Each free model decides on its own keys, so a hot model parks alone and a
  # calm model still rotates. A remainder (appended between peek and count)
  # falls back to the legacy shared keys.
  model_counts=$(signal_model_counts)
  sig=$(detect_429_new)
  # Peek DB models before the count advances the cursor (same peek contract
  # as the signal path above).
  db_models=$(db_model_counts)
  db_sig=$(detect_429_db)
  if [ "${sig:-0}" -gt 0 ]; then
    [ "${db_sig:-0}" -gt 0 ] && log "DB also saw $db_sig Zen quota row(s); using hook signal only mode=$m"
    decide_signal_models "$model_counts" "$sig"
    return $?
  fi
  if [ "${db_sig:-0}" -gt 0 ]; then
    if recent_zen_hook_signal; then
      log "DB saw $db_sig Zen quota row(s) inside ${HOOK_DEDUPE_WINDOW}s hook window; treating as the same 429 mode=$m"
      return 1
    fi
    # DB rows carry the error body: quota-exhausted text means backoff only,
    # even though the typed field looks like a rate limit — EXCEPT in tunnel
    # mode, where quota-text rotates like any other 429 (see above).
    if [ "$(eff_quota_rotates)" != 1 ] && db_quota_hit; then
      local ra; ra=$(retry_after_secs)
      [ "$ra" -gt 0 ] || ra=3
      state_set quota_until "$(( $(now) + ra ))"
      state_set need_rotate "$(date +%s)"
      log "DB fallback: quota-exhausted text in recent row(s) — backing off ${ra}s, NOT rotating mode=$m"
      return 2
    fi
    if [ "$(eff_quota_rotates)" = 1 ]; then
      log "DB fallback found $db_sig Zen quota row(s) without a recent hook signal (quota-text treated as throttle) mode=$m"
    else
      log "DB fallback found $db_sig Zen quota row(s) without a recent hook signal mode=$m"
    fi
    # DB rows thread their models like signal lines do: named free models
    # decide on their own keys, model-less rows keep the legacy shared keys,
    # and anything the peek missed (appended between peek and count) falls
    # back to the shared call on the remainder.
    local dm_mid dm_n dcounted=0 dbest=1 dr
    while read -r dm_mid dm_n; do
      case "$dm_n" in ''|*[!0-9]*|0) continue;; esac
      # "-" is the model-less shared bucket (see db_model_counts).
      [ "$dm_mid" = "-" ] && dm_mid=""
      dcounted=$((dcounted + dm_n))
      handle_signal "$dm_n" "$dm_mid"; dr=$?
      dbest=$(fold_rc "$dbest" "$dr")
    done <<< "$db_models"
    if [ "$((db_sig - dcounted))" -gt 0 ]; then
      handle_signal "$((db_sig - dcounted))"; dr=$?
      dbest=$(fold_rc "$dbest" "$dr")
    fi
    return "$dbest"
  fi
  # When there is no fresh signal the round continues ONLY if a latch is
  # pending — that is what lets a held rate limit fire after a park expires.
  # Latches are per model: each pending file carries its model id (legacy
  # epoch-stamped files stay shared), so one parked model never gates another.
  drain_pending_latches "$m" "$dw" "$qp"
  return $?
}

# --- event wait --------------------------------------------------------------
# wait_for_event — block until any watched log changes. Watches the whole
# directory rather than one file: the plugin starts a NEW timestamped log on
# every launch, so a watch pinned to today's plugin log would go deaf after the
# next restart. Falls back to a plain sleep so the daemon never spins.
wait_for_event() {
  local timeout="$FALLBACK_POLL" park remaining _sf _p
  if _pending_exists; then
    park=$(state_get stuck_until 0)
    case "$park" in ''|*[!0-9]*) park=0;; esac
    # Per-model parks shorten the wakeup too: take the latest expiry.
    while IFS= read -r _sf; do
      [ -f "$_sf" ] || continue
      _p=$(cat "$_sf" 2>/dev/null || echo 0)
      case "$_p" in ''|*[!0-9]*) continue;; esac
      [ "$_p" -gt "$park" ] 2>/dev/null && park=$_p
    done < <(state_family stuck_until)
    remaining=$(( park - $(now) ))
    if [ "$remaining" -gt 0 ] && [ "$remaining" -lt "$timeout" ]; then
      timeout="$remaining"
    fi
  fi
  if command -v inotifywait >/dev/null 2>&1 && { [ -d "$LOG_DIR" ] || [ -d "$SIGNAL_DIR" ]; }; then
    # -e modify catches appends; create/moved_to catch a fresh log file.
    # The timeout keeps a periodic wakeup so a missed event cannot stall us.
    local -a watch_dirs=()
    [ -d "$LOG_DIR" ] && watch_dirs+=("$LOG_DIR")
    [ -d "$SIGNAL_DIR" ] && watch_dirs+=("$SIGNAL_DIR")
    inotifywait -q -t "$timeout" -e modify -e create -e moved_to \
      "${watch_dirs[@]}" 2>/dev/null
    return $?
  fi
  sleep "$timeout"
}

auto_usage() {
  echo "usage: zen auto [--once|--detect-test|--edge-test|--wait-test|--route-test]"
  echo "  no args       run the daemon loop (event-driven)"
  echo "  --once        one round, rc 0=rotated 1=nothing 2=waiting"
  echo "  --detect-test rc 0 if a line matches the rate-limit pattern"
  echo "  --edge-test  print the current egress IPv6 through the proxy"
  echo "  --wait-test   block until the log changes, report how long it took"
  echo "  --route-test <model-id>  print responses|chat|off for the model family"
}

# NOTE: the argv dispatch lives BELOW, after every function definition. It used
# to sit here, above seed_cursors(), and the --once branch called seed_cursors
# before bash had reached its definition — "command not found", and the first
# round then counted the whole 429 history. Bash runs top to bottom, so a
# dispatch block must never reference a function defined after it.

# --- first-run state init: skip history, scan only new bytes ---
# One cursor per watched file. Without this a restart would re-scan the whole
# plugin log and fire a rotate on hours-old errors.
seed_cursors() {
  local f
  for f in $(active_logs); do
    local base; base=$(offset_name "$f")
    for tag in 429 403 quota; do
      [ -f "$STATE_DIR/$base.$tag" ] || stat -c %s "$f" > "$STATE_DIR/$base.$tag"
    done
  done
  # Same rule for the DB source: on a cold start, mark "now" as already seen.
  # Without this the first round counts every 429 ever recorded and rotates
  # immediately on boot — the log-file failure mode, reproduced for the DB.
  if [ -f "$DB_FILE" ] && [ ! -f "$STATE_DIR/db.429.cursor" ]; then
    sqlite3 "$DB_FILE" "SELECT coalesce(max(time_created),0) FROM session_message;" \
      2>/dev/null | while IFS= read -r mx; do
        case "$mx" in ''|*[!0-9]*) mx=0;; esac
        echo "$mx" > "$STATE_DIR/db.429.cursor"
      done
    log "init DB cursor: $(cat "$STATE_DIR/db.429.cursor" 2>/dev/null || echo 0) (ms)"
  fi
  log "init cursors: $(active_logs | wc -l) file(s) watched"
}
zen_auto_main() {
  mkdir -p "$STATE_DIR" "$SIGNAL_DIR"
  log "free gate: suffix=-free (non-jev) + suffixless=[${ZEN_FREE_SUFFIXLESS:-none}] + env extra=[${ZEN_FREE_MODELS:-none}]"
  case "${1:-}" in
    -h|--help) auto_usage; exit 0;;
    # Seed first, then one round. Seeding after would replay every 429 ever
    # recorded and rotate on the spot.
    --once) seed_cursors; resolve_outcomes; check_once; exit $?;;
    --detect-test)
      shift
      if [ $# -gt 0 ]; then matches_429 "$*"; else matches_429; fi
      rc=$?; [ $rc -eq 0 ] && echo "TRIGGER-429" || echo "NO-MATCH"; exit $rc;;
    --route-test)
      shift
      model_path "${1:-}"; exit 0;;
    --edge-test)
      ip=$(edge_now)
      echo "edge_now: ${ip:-unknown}"
      exit 0;;
    --wait-test)
      t0=$(date +%s%N)
      wait_for_event >/dev/null 2>&1
      t1=$(date +%s%N)
      echo "woke after $(( (t1 - t0) / 1000000 ))ms"
      exit 0;;
    '') :;;
    *) echo "unknown arg: $1"; auto_usage; exit 2;;
  esac

  seed_cursors
  # The stuck-edge counter describes the last few rotates, not history. Start
  # fresh so a restart is not immediately treated as "the edge never moves".
  state_set stuck_edge 0
  state_has last_rotate || state_set last_rotate "$(date +%s)"

  trim_log
  record_edge   # seed the timeline at startup so the first rotate has a "before"
  log "daemon start pid=$$ profile=${ZEN_PROFILE:-tuned} policy=event-driven,429-only burst>=$BURST_COUNT/${BURST_WINDOW}s cooldown=${COOLDOWN}s stuck_park=${STUCK_PARK}s max_stuck=$MAX_STUCK outcome_wait=${OUTCOME_WAIT}s window=${OUTCOME_WINDOW_S:-600}s ledger=$(basename "$LEDGER_FILE") edge_log=$(basename "$EDGE_LOG") edge_poll=${EDGE_POLL}s mode=$(mode_now) dedupe=${DEDUPE_WINDOW}s/${TUNNEL_DEDUPE_WINDOW}s quota_park=${QUOTA_PARK}s/${TUNNEL_QUOTA_PARK}s"

  exec 9>"$STATE_DIR/lock"
  if ! flock -n 9; then
    log "daemon stop: another instance holds the lock"
    exit 1
  fi

  while true; do
    resolve_outcomes
    record_edge
    check_once || true
    trim_log
    wait_for_event >/dev/null 2>&1 || true
  done
}
