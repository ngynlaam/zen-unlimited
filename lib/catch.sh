# lib/catch.sh — Observer Module: live transient-error catcher (sourced).
# Needs lib/state.sh first (shared state + proxy_alive).
#
# Watches four sources read-only for transient transport resets
# (ECONNRESET/TRANSPORT/ECONNREFUSED/Retry-due, plus typed DB rows) and writes
# one incident bundle per hit under $STATE_DIR/catch/<epoch>.log: the hit
# line, ±15s context from all sources, recent rotate rows, proxy-listener
# state.
#
# Read-only toward every source (byte cursors in its own catch.off.* files,
# ms cursor catch.off.db for the DB); the only writes are its own bundles +
# watch.log, both under $CATCH_DIR. Never decides, never rotates, never
# touches parks/ledger.
#
# Env knobs (all overridable so tests stay hermetic):
#   CATCH_OPENCODE_LOG — OpenCode log holding ECONNRESET lines
#   CATCH_RETRY_LOG    — zen-quota-retry.log
#   CATCH_AUTO_LOG     — warp-rotate auto.log
#   CATCH_DB_FILE      — opencode session DB (transport/invalid-request rows)
#   CATCH_DIR          — bundle dir (default $STATE_DIR/catch)
#   CATCH_PATTERN      — ERE hit pattern (matched case-insensitively)
#   CATCH_CTX          — context window seconds each side (default 15)
#   CATCH_POLL         — watch-loop poll seconds (default 5)
#   CATCH_ROTATE_ROWS  — recent R rows per bundle (default 5)

CATCH_OPENCODE_LOG="${CATCH_OPENCODE_LOG:-$LOG_DIR/opencode.log}"
CATCH_RETRY_LOG="${CATCH_RETRY_LOG:-$HOME/.local/state/opencode/zen-quota-retry.log}"
CATCH_AUTO_LOG="${CATCH_AUTO_LOG:-$STATE_DIR/auto.log}"
CATCH_DB_FILE="${CATCH_DB_FILE:-${DB_FILE:-$HOME/.local/share/opencode/opencode.db}}"
CATCH_DIR="${CATCH_DIR:-$STATE_DIR/catch}"
CATCH_PATTERN="${CATCH_PATTERN:-ECONNRESET|TRANSPORT|ECONNREFUSED|RETRY.DUE|RETRYING IN}"
CATCH_CTX="${CATCH_CTX:-15}"
CATCH_POLL="${CATCH_POLL:-5}"
CATCH_ROTATE_ROWS="${CATCH_ROTATE_ROWS:-5}"

# catch_tag <path> — stable cursor tag per source file.
catch_tag() {
  case "$1" in
    "$CATCH_OPENCODE_LOG") printf 'opencode';;
    "$CATCH_RETRY_LOG") printf 'retry';;
    *) printf 'auto';;
  esac
}

# catch_epoch <line> — epoch of a source line, or empty when unparseable.
# Handles all three live prefixes: timestamp=<ISO>, leading <ISO>, leading
# "%F %T". Pure parse, no side effects.
catch_epoch() {
  local line=$1 ts=""
  if [[ "$line" =~ timestamp=([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.+-]+Z?) ]]; then
    ts=${BASH_REMATCH[1]}
  elif [[ "$line" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.+-]+Z?) ]]; then
    ts=${BASH_REMATCH[1]}
  elif [[ "$line" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}) ]]; then
    ts=${BASH_REMATCH[1]}
  else
    return 1
  fi
  date -d "$ts" +%s 2>/dev/null || return 1
}

# catch_new_lines <file> <tag> — print bytes appended since the last pass,
# then advance the cursor. Never writes to the source.
catch_new_lines() {
  local file=$1 tag=$2 size off
  [ -f "$file" ] || return 0
  size=$(stat -c %s "$file" 2>/dev/null || echo 0)
  off=$(cat "$CATCH_DIR/catch.off.$tag" 2>/dev/null || echo 0)
  case "$off" in ''|*[!0-9]*) off=0;; esac
  [ "$size" -lt "$off" ] && off=0   # rotated or truncated
  if [ "$size" -gt "$off" ]; then
    tail -c +$((off + 1)) "$file" 2>/dev/null
  fi
  echo "$size" > "$CATCH_DIR/catch.off.$tag"
}

# catch_selftrigger <line> — rc 0 when the line merely quotes the pattern
# inside spawning-process command args (our own greps/scans echoed by the
# tool runner), never a real reset. Those lines must not fire; they stay
# usable as context. Typed DB rows are exempt (the typed field decides).
catch_selftrigger() {
  local lo
  lo=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
  case "$lo" in
    *spawning*process*) ;;
    *) return 1;;
  esac
  case "$lo" in
    *args=*) return 0;;
    *) return 1;;
  esac
}

# catch_db_hits <ctx-file> — append "epoch<TAB>db<TAB>line" rows for new
# assistant rows whose typed error is provider.transport/invalid-request.
# Cursor is max(time_created) in MILLISECONDS in catch.off.db (same unit as
# the daemon's db.429.cursor). Cold start seeds at now and fires nothing:
# history is not incidents. Missing DB or sqlite3 → tolerate, rc 0.
catch_db_hits() {
  local ctx=$1 curfile=$CATCH_DIR/catch.off.db cur hi ms et ep
  [ -f "$CATCH_DB_FILE" ] || return 0
  command -v sqlite3 >/dev/null 2>&1 || return 0
  cur=$(cat "$curfile" 2>/dev/null || echo "")
  case "$cur" in ''|*[!0-9]*) cur="";; esac
  if [ -z "$cur" ]; then
    hi=$(sqlite3 "$CATCH_DB_FILE" \
      "SELECT coalesce(max(time_created),0) FROM session_message;" 2>/dev/null) || return 0
    case "$hi" in ''|*[!0-9]*) return 0;; esac
    echo "$hi" > "$curfile"
    return 0
  fi
  while IFS='|' read -r ms et; do
    case "$ms" in ''|*[!0-9]*) continue;; esac
    ep=$((ms / 1000))
    printf '%s\tdb\ttimestamp=%s source=db session_message error.type=%s time_created=%s\n' \
      "$ep" "$(date -d "@$ep" '+%Y-%m-%dT%H:%M:%SZ')" "$et" "$ms" >> "$ctx"
    hi=$ms
  done < <(sqlite3 "$CATCH_DB_FILE" \
    "SELECT time_created, json_extract(data,'\$.error.type') FROM session_message
       WHERE type='assistant'
         AND CASE WHEN json_valid(data) THEN
           json_extract(data,'\$.error.type') IN ('provider.transport','provider.invalid-request')
         ELSE 0 END
         AND time_created > $cur ORDER BY time_created;" 2>/dev/null)
  case "${hi:-}" in ''|*[!0-9]*) hi=$cur;; esac
  [ "$hi" -gt "$cur" ] && echo "$hi" > "$curfile"
  return 0
}

# catch_listener_state — proxy-listener snapshot for a bundle (reads only).
catch_listener_state() {
  local cache="(missing)"
  [ -f "$STATE_DIR/mode_cache" ] && cache=$(cat "$STATE_DIR/mode_cache" 2>/dev/null || echo "(unreadable)")
  echo "mode_cache: $cache"
  if proxy_alive; then
    echo "listener :44444: open (proxy serves)"
  else
    echo "listener :44444: closed (system-tunnel serves)"
  fi
}

# catch_bundle <hit-epoch> <hit-tag> <hit-line> <ctx-file> — write one bundle.
# <ctx-file> holds "epoch<TAB>tag<TAB>line" rows for this pass; context is the
# ±CATCH_CTX slice. Recent R rows + listener state appended read-only.
catch_bundle() {
  local hep=$1 htag=$2 hline=$3 ctx=$4 lo hi ep bundle n=0
  lo=$((hep - CATCH_CTX)); hi=$((hep + CATCH_CTX))
  ep=$hep
  bundle="$CATCH_DIR/$ep.log"
  while [ -f "$bundle" ]; do
    n=$((n + 1)); bundle="$CATCH_DIR/$ep-$n.log"
  done
  {
    echo "=== catch $(date -d "@$hep" '+%F %T') source=$htag ==="
    echo "--- hit ---"
    printf '%s\n' "$hline"
    echo "--- context ${CATCH_CTX}s each way (all sources) ---"
    while IFS=$'\t' read -r cep ctag cline; do
      case "$cep" in ''|*[!0-9]*) continue;; esac
      if [ "$cep" -ge "$lo" ] && [ "$cep" -le "$hi" ]; then
        printf '[%s] %s\n' "$ctag" "$cline"
      fi
    done < "$ctx"
    echo "--- recent rotates (last $CATCH_ROTATE_ROWS R rows) ---"
    if [ -f "$LEDGER_FILE" ]; then
      grep -a '^R' "$LEDGER_FILE" 2>/dev/null | tail -"$CATCH_ROTATE_ROWS" || true
    else
      echo "(no ledger yet)"
    fi
    echo "--- proxy-listener state ---"
    catch_listener_state
  } > "$bundle"
  printf '%s\n' "$bundle"
}

# catch_once — one scan pass over new bytes. Prints new bundle paths, one per
# line; prints nothing when no hits. rc 0 always (missing files are normal).
catch_once() {
  local f tag line hep ctx n=0
  mkdir -p "$CATCH_DIR"
  ctx="$CATCH_DIR/.ctx.$$"
  : > "$ctx"
  # Gather this pass's new lines with epochs (one file per source, tagged).
  for f in "$CATCH_OPENCODE_LOG" "$CATCH_RETRY_LOG" "$CATCH_AUTO_LOG"; do
    tag=$(catch_tag "$f")
    [ -f "$f" ] || continue
    while IFS= read -r line || [ -n "$line" ]; do
      hep=$(catch_epoch "$line") || continue
      printf '%s\t%s\t%s\n' "$hep" "$tag" "$line" >> "$ctx"
    done < <(catch_new_lines "$f" "$tag")
  done
  # New typed DB rows join the same context pool (tag db).
  catch_db_hits "$ctx"
  # One bundle per hit. File hits fire on the pattern unless the line merely
  # quotes it inside spawning-process args (self-trigger, excluded). DB rows
  # fire on the typed error field itself — pattern-exempt by design.
  while IFS=$'\t' read -r hep htag hline || [ -n "$hep" ]; do
    case "$hep" in ''|*[!0-9]*) continue;; esac
    if [ "$htag" = "db" ]; then
      :
    elif printf '%s' "$hline" | grep -qiE "$CATCH_PATTERN"; then
      catch_selftrigger "$hline" && continue
    else
      continue
    fi
    catch_bundle "$hep" "$htag" "$hline" "$ctx"
    n=$((n + 1))
  done < "$ctx"
  rm -f "$ctx"
  return 0
}

# catch_selftest — prove the bundle path works without a real hit: one bundle
# with synthetic SELFTEST content. Used live against a THROWAWAY dir only.
catch_selftest() {
  local bundle
  mkdir -p "$CATCH_DIR"
  bundle="$CATCH_DIR/selftest-$(date +%s).log"
  {
    echo "=== catch SELFTEST $(date '+%F %T') ==="
    echo "--- hit ---"
    echo "SELFTEST synthetic hit (no source file touched)"
    echo "--- recent rotates (last $CATCH_ROTATE_ROWS R rows) ---"
    if [ -f "$LEDGER_FILE" ]; then
      grep -a '^R' "$LEDGER_FILE" 2>/dev/null | tail -"$CATCH_ROTATE_ROWS" || true
    else
      echo "(no ledger yet)"
    fi
    echo "--- proxy-listener state ---"
    catch_listener_state
  } > "$bundle"
  printf '%s\n' "$bundle"
}

catch_usage() {
  echo "usage: zen catch [--once|--self-test]"
  echo "  no args       watch loop: bundle every transient transport reset"
  echo "  --once        one scan pass over new bytes, print new bundles"
  echo "  --self-test   write one synthetic bundle (throwaway dirs only)"
}

zen_catch_main() {
  local _f _new _b
  local -a _watches
  mkdir -p "$STATE_DIR" "$CATCH_DIR"
  case "${1:-}" in
    -h|--help) catch_usage; exit 0;;
    --once) catch_once; exit 0;;
    --self-test) catch_selftest; exit 0;;
    '') :;;
    *) echo "unknown arg: $1"; catch_usage; exit 2;;
  esac

  # Seed cursors at current sizes: history is not incidents, never replay it.
  # (The DB ms cursor cold-starts inside catch_db_hits on the same rule.)
  for _f in "$CATCH_OPENCODE_LOG" "$CATCH_RETRY_LOG" "$CATCH_AUTO_LOG"; do
    [ -f "$_f" ] || continue
    stat -c %s "$_f" > "$CATCH_DIR/catch.off.$(catch_tag "$_f")" 2>/dev/null || true
  done
  echo "$(date '+%F %T') catch watch start (pattern: $CATCH_PATTERN)" >> "$CATCH_DIR/watch.log"

  exec 9>"$CATCH_DIR/lock"
  if ! flock -n 9; then
    echo "catch already running (lock held)"
    exit 1
  fi

  while true; do
    _new=$(catch_once)
    if [ -n "$_new" ]; then
      while IFS= read -r _b; do
        [ -n "$_b" ] || continue
        echo "$(date '+%F %T') incident $(basename "$_b")" >> "$CATCH_DIR/watch.log"
      done <<< "$_new"
    fi
    if command -v inotifywait >/dev/null 2>&1; then
      _watches=()
      for _f in "$CATCH_OPENCODE_LOG" "$CATCH_RETRY_LOG" "$CATCH_AUTO_LOG"; do
        [ -f "$_f" ] && _watches+=("$(dirname "$_f")")
      done
      # DB rows arrive without any watched file changing; its dir closes that gap.
      [ -f "$CATCH_DB_FILE" ] && _watches+=("$(dirname "$CATCH_DB_FILE")")
      if [ "${#_watches[@]}" -gt 0 ]; then
        # shellcheck disable=SC2086
        inotifywait -q -t "$CATCH_POLL" -e modify -e create -e moved_to ${_watches[@]} >/dev/null 2>&1 || true
      else
        sleep "$CATCH_POLL"
      fi
    else
      sleep "$CATCH_POLL"
    fi
  done
}
