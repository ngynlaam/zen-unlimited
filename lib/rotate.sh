# lib/rotate.sh — Actuator Module: warp-cli cycle + egress probe (sourced).
# Needs lib/state.sh first.

# --- ROTATE section (ex bin/warp-rotate, verbatim) ---
# warp-rotate: reset the Cloudflare WARP egress session (WarpProxy on :44444).
#
# What a rotate proves on this machine:
#   - warp-cli completed a disconnect/connect cycle and the selected WARP route
#     serves traffic again. This does NOT prove that a provider quota cleared.
#   - Traffic leaves over IPv6. Measured 2026-10-03: curl -4, curl -6 and
#     a default curl through :44444 all return the SAME IPv6 address
#     (2a09:bac5:d446:16dc::247:9). The 104.28.x.x IPv4 address exists on the
#     interface but carries no traffic, so judging a rotate by IPv4 movement
#     is judging the one family that does not matter. IPv4 sits in a pool of
#     ~6 addresses and gets stuck on 104.28.219.201; IPv6 changed on every
#     single rotation measured.
#
# A changed IPv6 address is useful evidence that egress changed. It is not the
# success test and it does not guarantee a new Cloudflare data center or a
# cleared provider quota. IPv4 is reported for information only.

PROXY="${PROXY:-http://127.0.0.1:44444}"
TRACE_URL="https://www.cloudflare.com/cdn-cgi/trace"
IP4_URL="https://api.ipify.org"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-3}"
# How long the tunnel is deliberately left DOWN. The user chose this 2s reset
# step. It interrupts traffic using this WARP route. OpenCode's retry hook now
# handles quota responses directly, so this TCP outage is not required to make
# the model retry and is not proof that the quota will clear.
DOWN_HOLD="${DOWN_HOLD:-2}"
# After reconnecting, a route can respond before WARP carries traffic. Check
# either the local HTTP proxy or the system WARP tunnel before reporting done.
READY_TRIES="${READY_TRIES:-20}"

# Never inherit a proxy from the environment: the WARP proxy is passed
# explicitly and an inherited HTTP_PROXY would route through it twice.
CURL=(env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u http_proxy -u https_proxy \
      -u all_proxy curl)

# egress_prefix48 — first /48 (3 hextets) of an IPv6 address, lower-cased.
# A full /128 rotates every ~5 min and an IPv4 pool is stuck on
# 104.28.219.201, so neither is a usable dedupe/identity key — /48 is.
egress_prefix48() {
  local ip="${1:-}"
  [ -n "$ip" ] || return 1
  echo "$ip" | tr 'A-F' 'a-f' | cut -d: -f1-3
}

# (HTTP liveness for the rotate path is proxy_alive http; see AUTO section.)

# egress_probe_both — log BOTH paths (direct vs via-proxy) with /48 prefixes.
# Called for diagnostics; never fails the rotate (rc 0 always).
egress_probe_both() {
  local via_direct via_proxy p48
  via_direct=$("${CURL[@]}" --noproxy '*' -s -m 5 "$TRACE_URL" 2>/dev/null \
    | sed -n 's/^ip=//p' | head -1)
  via_proxy=$("${CURL[@]}" -s -m 5 -x "$PROXY" "$TRACE_URL" 2>/dev/null \
    | sed -n 's/^ip=//p' | head -1)
  if [ -n "$via_direct" ]; then
    p48=""
    case "$via_direct" in *:*:*) p48=$(egress_prefix48 "$via_direct" 2>/dev/null || echo "?");; esac
    echo "egress direct (no proxy): ${via_direct}${p48:+ (/$p48)}"
  else
    echo "egress direct (no proxy): unreachable"
  fi
  if [ -n "$via_proxy" ]; then
    p48=""
    case "$via_proxy" in *:*:*) p48=$(egress_prefix48 "$via_proxy" 2>/dev/null || echo "?");; esac
    echo "egress via-proxy (:44444): ${via_proxy}${p48:+ (/$p48)}"
  else
    echo "egress via-proxy (:44444): unreachable (proxy down, route=system-tunnel)"
  fi
  return 0
}

egress_ipv6() {
  local trace ip
  # Measure by the REAL route: if :44444 is dead, the serving route is the
  # system tunnel — never label a dead proxy as "local-proxy".
  if proxy_alive http; then
    trace=$("${CURL[@]}" -s -m 8 -x "$PROXY" "$TRACE_URL" 2>/dev/null)
    ip=$(sed -n 's/^ip=//p' <<< "$trace" | head -1)
    if [ -n "$ip" ]; then
      EGRESS_ROUTE="local-proxy"
      EGRESS_IP="$ip"
      return 0
    fi
  fi
  # Proxy dead or gave nothing: fall through to the system tunnel. Both
  # routines below bypass any proxy explicitly (--noproxy '*').

  # Traffic and DNS mode sends ordinary device traffic through the WARP
  # tunnel. It may not provide the separate local HTTP proxy on :44444.
  trace=$(system_trace 8)
  if is_warp_trace "$trace"; then
    ip=$(sed -n 's/^ip=//p' <<< "$trace" | head -1)
    if [ -n "$ip" ]; then
      EGRESS_ROUTE="system-tunnel"
      EGRESS_IP="$ip"
      return 0
    fi
  fi
  return 1
}

system_trace() {
  local timeout="${1:-8}"
  "${CURL[@]}" --noproxy '*' -s -m "$timeout" "$TRACE_URL" 2>/dev/null
}

is_warp_trace() {
  grep -Eq '^(warp=(on|plus)|gateway=on)$' <<< "${1:-}"
}

egress_ipv4() {
  local ip
  # IPv4 pool is informational only (~6 addrs, stuck on 104.28.219.201) but
  # must not depend solely on a dead :44444 — fall back to a direct probe.
  ip=$("${CURL[@]}" -s -m 10 -x "$PROXY" -4 "$IP4_URL" 2>/dev/null | tr -d '[:space:]')
  if [ -n "$ip" ]; then echo "$ip"; return 0; fi
  "${CURL[@]}" --noproxy '*' -s -m 10 -4 "$IP4_URL" 2>/dev/null | tr -d '[:space:]'
}

wait_connected() {
  local i
  for i in $(seq 1 60); do
    warp-cli status 2>/dev/null | grep -q 'Connected' && return 0
    sleep 1
  done
  return 1
}

# wait_down — confirm that WARP is disconnected and the route used by Zen is
# down. Local proxy mode checks :44444. Full-tunnel mode checks the WARP marker
# on a direct request; normal Internet access can still work after disconnect.
wait_down() {
  local i out trace
  for i in $(seq 1 15); do
    warp-cli status 2>/dev/null | grep -q 'Connected' || {
      if [ "${BEFORE_ROUTE:-}" = "system-tunnel" ]; then
        trace=$(system_trace 3)
        is_warp_trace "$trace" || return 0
      fi
      out=$("${CURL[@]}" -s -m 3 -o /dev/null -w '%{http_code}' -x "$PROXY" "$TRACE_URL" 2>/dev/null)
      # 000 means the local proxy path is unavailable.
      [ "$out" = "000" ] && return 0
    }
    sleep 1
  done
  return 1
}

# wait_ready — first moment a WARP route really serves traffic again.
wait_ready() {
  local i
  for i in $(seq 1 "$READY_TRIES"); do
    if egress_ipv6 >/dev/null; then return 0; fi
    sleep 1
  done
  return 1
}

# reconnect — disconnect, confirm the selected WARP route is down, hold for the
# requested interval, reconnect, and confirm that a WARP route serves traffic.
reconnect() {
  local t0 t_down t_up
  t0=$(date +%s)
  warp-cli disconnect >/dev/null 2>&1
  if ! wait_down; then
    echo "WARN: selected route stayed available after disconnect"
    echo "down-window: NO (route check did not confirm a WARP outage)"
  else
    sleep "$DOWN_HOLD"
    t_down=$(( $(date +%s) - t0 ))
    echo "down-window: ${t_down}s (selected WARP route was down; held ${DOWN_HOLD}s)"
  fi
  warp-cli connect >/dev/null 2>&1
  wait_connected || return 1
  t_up=$(( $(date +%s) - t0 ))
  wait_ready || { echo "WARN: WARP is Connected but no WARP route is serving yet"; return 1; }
  echo "up-window: $(( $(date +%s) - t0 ))s (Connected at ${t_up}s, ${EGRESS_ROUTE} route serving)"
}

# Probe right after connecting because either route can need time to start.
probe_ipv6() {
  local i
  for i in $(seq 1 20); do
    egress_ipv6 && return 0
    sleep 1
  done
  return 1
}

# run_egress <primary|secondary> — run one egress Adapter; stdout is its
# output, rc is its exit. An unset secondary is a hard miss (rc 1, silent).
run_egress() {
  if [ "${1:-primary}" = "secondary" ]; then
    [ -n "${ZEN_ROTATE_SECONDARY:-}" ] || return 1
    "$ZEN_ROTATE_SECONDARY" 2>&1
  elif [ "$WARP_ROTATE" = "__zen_internal_rotate" ]; then
    zen_rotate_main 2>&1
  else
    "$WARP_ROTATE" 2>&1
  fi
}

# --- rotate in three steps ---------------------------------------------------
# pick path -> run Adapter -> record verdict. Data passes between steps in
# ROTATE_* vars, never parsed from log text (the old sed-scrape of the
# human "before/after IPv6:" lines is kept only as a fallback for external
# Adapters that predate the EDGE data line).

# rotate_pick_path — step 1: Adapter order + EGRESS_PATH. Per-model override
# ZEN_PATH_<MODEL> (upper-cased, the rest to _) picks the first-tried Adapter
# for one model; a failed first choice still fails over. Anything else keeps
# the global primary-first policy, so a healthy primary always stays primary.
# Unset ZEN_ROTATE_SECONDARY means single-adapter behavior. MKEY arrives as
# data (bound by the caller), not parsed from anywhere.
rotate_pick_path() {
  local _ovn="" _ovv=""
  ROTATE_FIRST="primary"; ROTATE_SECOND="secondary"
  if [ -n "$MKEY" ]; then
    _ovn=$(printf '%s' "$MKEY" | tr 'a-z' 'A-Z' | tr -c 'A-Z0-9_' '_')
    eval "_ovv=\${ZEN_PATH_$_ovn:-}"
    case "$_ovv" in primary|secondary) ROTATE_FIRST=$_ovv;; esac
  fi
  [ "$ROTATE_FIRST" = "secondary" ] && ROTATE_SECOND="primary"
  EGRESS_PATH="$ROTATE_FIRST"
}

# rotate_run_adapter <primary|secondary> — step 2: run one Adapter.
# Human output lands in $ROTATE_OUT (file, for the caller to log); data
# returns in ROTATE_RC / ROTATE_BEFORE6 / ROTATE_AFTER6. Runs in this shell
# (not a subshell) so the internal Adapter's edge vars survive; external
# Adapters speak the data line `EDGE before=<ip> after=<ip>`, else their
# legacy before/after report lines are read so custom rotators keep working.
rotate_run_adapter() {
  local which=${1:-primary} rc=0 data
  ROTATE_RC=1; ROTATE_BEFORE6=""; ROTATE_AFTER6=""
  ROTATE_OUT="$STATE_DIR/adapter.out"
  : > "$ROTATE_OUT"
  run_egress "$which" >"$ROTATE_OUT" 2>&1 || rc=$?
  ROTATE_RC=$rc
  if [ "$which" != "secondary" ] && [ "$WARP_ROTATE" = "__zen_internal_rotate" ]; then
    ROTATE_BEFORE6=$BEFORE6
    ROTATE_AFTER6=$ROTATE_SNAP_AFTER6
  else
    data=$(sed -n 's/^EDGE before=\([0-9a-fA-F:]*\) after=\([0-9a-fA-F:]*\).*/\1 \2/p' \
      "$ROTATE_OUT" | head -1)
    if [ -n "$data" ]; then
      ROTATE_BEFORE6=${data%% *}; ROTATE_AFTER6=${data##* }
    else
      ROTATE_BEFORE6=$(sed -n 's/.*before  IPv6: \([0-9a-fA-F:]*\).*/\1/p' \
        "$ROTATE_OUT" | head -1)
      ROTATE_AFTER6=$(sed -n 's/.*after   IPv6: \([0-9a-fA-F:]*\).*/\1/p' \
        "$ROTATE_OUT" | head -1)
    fi
  fi
  return "$rc"
}

# rotate_record_verdict <reason> <rc> — step 3: R row + outcome-queue entry
# from ROTATE_BEFORE6/_AFTER6 data via the shared ledger_verdict writer.
# Recorded before any early return so a stopped (stuck-edge) rotate is graded
# too — those are exactly the cases that used to look like a success and
# were not. Path rides as a trailing field: old readers index fixed columns
# and ignore the extra, so old reports still read new rows.
rotate_record_verdict() {
  local reason=$1 rc=$2 changed=no
  if [ -n "$ROTATE_BEFORE6" ] && [ -n "$ROTATE_AFTER6" ] \
      && [ "$ROTATE_BEFORE6" != "$ROTATE_AFTER6" ]; then
    changed=yes
  fi
  ledger_verdict R "$(now)" "$(date '+%F %T')" "$reason" \
    "${ROTATE_BEFORE6:-none}" "${ROTATE_AFTER6:-none}" "$changed" "$rc" "$EGRESS_PATH"
  state_append outcome_queue "$(printf '%s\t%s\t%s\t%s\t%s' "$(now)" "$reason" \
    "${ROTATE_BEFORE6:-none}" "${ROTATE_AFTER6:-none}" "$changed")"
}


zen_rotate_main() {
  BEFORE6=""
  BEFORE_ROUTE="unknown"
  # Data export for step 2 (rotate_run_adapter runs this in the same shell):
  # first-attempt after-edge only — later attempts retry on empty output, so
  # the first attempt is what the legacy head -1 scrape would have read.
  ROTATE_SNAP_AFTER6=""
  if egress_ipv6; then
    BEFORE6="$EGRESS_IP"
    BEFORE_ROUTE="$EGRESS_ROUTE"
  fi
  BEFORE48=""
  case "$BEFORE6" in *:*:*) BEFORE48=$(egress_prefix48 "$BEFORE6" 2>/dev/null || echo "");; esac
  BEFORE4=$(egress_ipv4)
  echo "before  IPv6: ${BEFORE6:-unknown}${BEFORE48:+ (/$BEFORE48)}"
  echo "before  route: $BEFORE_ROUTE"
  echo "before  IPv4: ${BEFORE4:-unknown} (info only, pool stuck)"
  egress_probe_both

  CONNECTED=0
  NEWADDR=0
  ATTEMPT=1
  while [ "$ATTEMPT" -le "$MAX_ATTEMPTS" ]; do
    echo "--- reconnect (attempt $ATTEMPT/$MAX_ATTEMPTS) ---"
    if reconnect; then
      CONNECTED=1
    else
      echo "WARN: Warp did not come back and serve within the timeout"
    fi

    AFTER6=""
    AFTER_ROUTE="unknown"
    if probe_ipv6; then
      AFTER6="$EGRESS_IP"
      AFTER_ROUTE="$EGRESS_ROUTE"
    fi
    AFTER48=""
    case "$AFTER6" in *:*:*) AFTER48=$(egress_prefix48 "$AFTER6" 2>/dev/null || echo "");; esac
    AFTER4=$(egress_ipv4)
    echo "after   IPv6: ${AFTER6:-unknown}${AFTER48:+ (/$AFTER48)}"
    echo "after   route: $AFTER_ROUTE"
    echo "after   IPv4: ${AFTER4:-unknown} (info only)"
    [ "$ATTEMPT" -eq 1 ] && ROTATE_SNAP_AFTER6=$AFTER6

    if [ -z "$AFTER6" ] && [ -z "$AFTER4" ]; then
      # WARP route is still down: nothing was fixed, so a retry is worthwhile.
      echo "NOTE: no WARP egress address after reconnect — route is not serving"
    elif [ -n "$BEFORE6" ] && [ -n "$AFTER6" ] && [ "$BEFORE6" != "$AFTER6" ]; then
      # IPv6 is the family that carries traffic. If it moved, the rotate did
      # what it exists to do — land on a different Cloudflare edge.
      NEWADDR=1
      break
    else
      # IPv6 repeated: the session was still reset and the client still got its
      # retry. Deliberately NOT reconnecting again here — every extra cycle drops
      # the proxy a second time, and a second failure mid-retry is worse than
      # landing on the same edge. Reported honestly instead.
      echo "NOTE: tunnel reset done, IPv6 edge repeated — not cycling again (one down-window is enough)"
      break
    fi
    ATTEMPT=$((ATTEMPT + 1))
  done

  echo
  if [ "$CONNECTED" -eq 0 ]; then
    echo "FAILED: WARP did not reconnect with a working traffic route."
    # return, not exit: step 2 runs this in the same shell so the edge data
    # survives. CLI dispatch exits with this rc; do_rotate reads it as before.
    return 1
  fi

  if [ "$NEWADDR" -eq 1 ]; then
    echo "OK: tunnel reset, egress edge changed (IPv6 ${AFTER6:-?}, IPv4 ${AFTER4:-?} unused)"
  else
    echo "OK: tunnel reset, but IPv6 came back to the same edge ${AFTER6:-?}"
    echo "    (IPv4 ${AFTER4:-?}). The session reset still applies; a rate"
    echo "    limit keyed to that edge may need a different provider."
  fi
  return 0
}
