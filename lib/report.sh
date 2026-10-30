# lib/report.sh — Observer Module: read-only report (sourced).

zen_report_main() {
  STATE_DIR="${STATE_DIR:-$HOME/.local/share/warp-rotate}"
  DB_FILE="${DB_FILE:-$HOME/.local/share/opencode/opencode.db}"
  DAYS="${DAYS:-7}"
  EDGE_LOG="$STATE_DIR/edge_timeline.tsv"
  LEDGER="$STATE_DIR/rotations.tsv"
  AUTO_LOG="$STATE_DIR/auto.log"
  SIG_FILE="${ZEN_SIGNAL_FILE:-$STATE_DIR/signals/zen-quota.log}"
  QUEUE="$STATE_DIR/outcome_queue"

  command -v sqlite3 >/dev/null 2>&1 || { echo "need sqlite3"; exit 1; }
  command -v python3  >/dev/null 2>&1 || { echo "need python3"; exit 1; }
  [ -f "$DB_FILE" ] || { echo "no DB at $DB_FILE"; exit 1; }

  echo "=== warp-report (read-only) ==="
  echo "db:    $DB_FILE"
  echo "edges: $([ -f "$EDGE_LOG" ] && wc -l < "$EDGE_LOG" || echo 'no edge_timeline.tsv yet') rows"
  echo "rotates: $([ -f "$LEDGER" ] && grep -c '^R' "$LEDGER" || echo 0) rows"
  echo

  exec python3 - "$DB_FILE" "$EDGE_LOG" "$LEDGER" "$DAYS" "$AUTO_LOG" "$SIG_FILE" "$QUEUE" <<'PY'
import sqlite3, sys, os, re, datetime
from collections import defaultdict

db, edge_log, ledger, days = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)

# A rate limit is error.type='provider.quota' on an assistant row. Matching the
# message text instead also counts rows where the phrase merely appears in
# quoted log output, which is why this uses the typed field.
Q = "json_extract(data,'$.error.type')='provider.quota'"
OK = ("json_extract(data,'$.error.type') IS NULL AND "
      "json_extract(data,'$.finish') IN ('stop','tool-calls')")

print("=== 1. Real rate-limit rate, per day ===")
print(f"{'date':<12} {'quota':>7} {'ok':>8} {'rate':>8}")
rows = con.execute(f"""
 SELECT date(time_created/1000,'unixepoch','localtime'),
        SUM({Q}), SUM({OK})
 FROM session_message WHERE type='assistant'
 GROUP BY 1 ORDER BY 1 DESC LIMIT ?""", (days,)).fetchall()
tot_q = tot_o = 0
for d, q, o in rows:
    q = q or 0; o = o or 0; tot_q += q; tot_o += o
    print(f"{d:<12} {q:>7} {o:>8} {q/max(1,q+o):>7.2%}")
print(f"{'TOTAL':<12} {tot_q:>7} {tot_o:>8} {tot_q/max(1,tot_q+tot_o):>7.2%}")
print()

# error types, so a quota problem is not confused with an auth or network one
print("=== error.type breakdown (assistant rows) ===")
for t, n in con.execute("""
 SELECT json_extract(data,'$.error.type'), COUNT(*)
 FROM session_message WHERE type='assistant'
   AND json_extract(data,'$.error.type') IS NOT NULL
 GROUP BY 1 ORDER BY 2 DESC"""):
    print(f"  {t:<28} {n}")
print()

# ---- edge timeline -----------------------------------------------------------
segs = []   # (epoch, ip)
if os.path.exists(edge_log):
    for line in open(edge_log, errors="replace"):
        p = line.rstrip("\n").split("\t")
        if len(p) >= 3 and p[0].isdigit():
            segs.append((int(p[0]), p[2]))
    segs.sort()
if not segs:
    print("=== 2/3. Skipped: edge_timeline.tsv has no usable rows yet ===")
    print("    It is written by warp-auto as the edge changes. Give it a day of")
    print("    normal use, then re-run this report.")
else:
    T0 = segs[0][0]
    def edge_at(t):
        cur = None
        for ep, ip in segs:
            if ep <= t: cur = ip
            else: break
        return cur

    ev = [(t/1000, 'q') for (t,) in con.execute(
          f"SELECT time_created FROM session_message WHERE type='assistant' AND {Q}")]
    ok = [(t/1000, 'o') for (t,) in con.execute(
          f"SELECT time_created FROM session_message WHERE type='assistant' AND {OK}")]

    print(f"=== 2. Coverage ===")
    print(f"  edge timeline: {datetime.datetime.fromtimestamp(segs[0][0])} -> "
          f"{datetime.datetime.fromtimestamp(segs[-1][0])}  ({len(segs)} segments)")
    inw_e = sum(1 for t, _ in ev if t >= T0)
    inw_o = sum(1 for t, _ in ok if t >= T0)
    print(f"  quota events inside that window: {inw_e}   successes: {inw_o}")
    if inw_e + inw_o == 0:
        print("  no traffic in the window yet — nothing to attribute.")
    print()

    print("=== 3. Rate limits per edge (window covered by the timeline) ===")
    per = defaultdict(lambda: [0, 0])
    for t, _ in ev:
        if t >= T0:
            e = edge_at(t)
            if e: per[e][0] += 1
    for t, _ in ok:
        if t >= T0:
            e = edge_at(t)
            if e: per[e][1] += 1
    print(f"{'edge':<42} {'quota':>6} {'ok':>7} {'rate':>8}")
    for e, (q, o) in sorted(per.items(), key=lambda kv: (-kv[1][0], kv[0])):
        print(f"{e:<42} {q:>6} {o:>7} {q/max(1,q+o):>7.2%}")
    print()
    print("  Read: an edge with a high rate on real traffic volume is a bad edge.")
    print("  One edge per row is a short sample; only trust edges with o >= 20.")
    print()

    # ---- rotate effectiveness ------------------------------------------------
    print("=== 4. Did rotating actually stop the rate limits? ===")
    R = []
    if os.path.exists(ledger):
        for line in open(ledger, errors="replace"):
            p = line.rstrip("\n").split("\t")
            if p and p[0] == "R" and len(p) >= 7:
                R.append({"ep": int(p[1]), "why": p[3], "before": p[4],
                          "after": p[5], "changed": p[6] == "yes"})
        R.sort(key=lambda r: r["ep"])

    # Compare quota event rates before/after each rotate. Counting every later
    # quota as a rotate failure is misleading: it ignores how active the user
    # was, and overlapping rotate windows reuse the same events. Use a bounded
    # window and report numerator/denominator; this remains observational, not
    # causal evidence.
    WINDOW = 120
    qtimes = sorted(t for t, _ in ev)
    def count_between(a, b):
        return sum(a < t <= b for t in qtimes)

    rows2 = []
    for i, r in enumerate(R):
        end = min(r["ep"] + WINDOW,
                  R[i + 1]["ep"] if i + 1 < len(R) else r["ep"] + WINDOW)
        pre_a, pre_b = r["ep"] - WINDOW, r["ep"]
        post_a, post_b = r["ep"] + 7, end
        pre_n = count_between(pre_a, pre_b)
        post_n = count_between(post_a, post_b) if post_b > post_a else 0
        pre_rate, post_rate = pre_n / WINDOW, post_n / max(1, post_b - post_a)
        rows2.append((r, pre_n, post_n, post_b - post_a, pre_rate, post_rate))
    if rows2:
        print("  Per-rotate comparison: previous 120s vs post-reconnect window (up to 120s)")
        print("  rate is quota errors/second; inspect counts because windows may have little traffic")
        for r, pn, qn, dur, pr, qr in rows2:
            print(f"  {datetime.datetime.fromtimestamp(r['ep'])} edge_changed={r['changed']} "
                  f"pre={pn}/120s ({pr:.4f}/s) post={qn}/{dur}s ({qr:.4f}/s) reason={r['why']}")
        print("\n  Compare several rotates with similar request volume; a single window cannot establish causality.")
    else:
        print("  no rotate records yet")
    print()
    Vr = []
    if os.path.exists(ledger):
        for line in open(ledger, errors="replace"):
            p = line.rstrip("\n").split("\t")
            if p and p[0] == "V" and len(p) >= 4 and p[1].isdigit():
                rec = {"ep": int(p[1]), "n": p[3]}
                rec["window"] = int(p[4]) if len(p) >= 5 and p[4].isdigit() else None
                Vr.append(rec)
        Vr.sort(key=lambda r: r["ep"])
    if Vr:
        print("  Verdicts per rotate (V rows, newest last):")
        for v in Vr:
            ts = datetime.datetime.fromtimestamp(v["ep"])
            if v["window"] is None:
                print(f"  {ts} legacy cumulative since rotate: {v['n']}")
            else:
                print(f"  {ts} windowed {v['window']}s after rotate: {v['n']}")
        print()
    print("  Legacy 4-field V rows count all 429s since the rotate; windowed 5-field V rows count only the Ns after it. Old rows are never rewritten.")
    print("  Only provider.quota is counted here; 400 invalid-request, 403/auth, and transport are separate outcomes.")

# ---- every request, not just the failures -----------------------------------
# The daemon only reacts to quota errors, so without this the invisible half of
# the picture is missing: how many requests ran, how long they took, what they
# cost in tokens, and which model/provider served them. That is what turns "we
# saw N rate limits" into "N out of M requests, median latency L".
print()
print("=== 5. Every request (assistant turns), by day ===")
print(f"{'date':<12} {'reqs':>7} {'ok':>7} {'fail':>6} {'err%':>6} {'med lat':>9} {'tok in':>10} {'tok out':>10}")
q_all = """SELECT date(time_created/1000,'unixepoch','localtime') d,
 COUNT(*),
 SUM(json_extract(data,'$.error.type') IS NULL),
 SUM(json_extract(data,'$.error.type') IS NOT NULL)
 FROM session_message WHERE type='assistant' GROUP BY d ORDER BY d DESC LIMIT ?"""
for d, tot, okc, ec in con.execute(q_all, (days,)):
    tot = tot or 0; okc = okc or 0; ec = ec or 0
    lat = con.execute("""
      SELECT time_created/1000, json_extract(data,'$.time.completed')/1000
      FROM session_message WHERE type='assistant'
        AND date(time_created/1000,'unixepoch','localtime')=?
        AND json_extract(data,'$.time.completed') IS NOT NULL""", (d,)).fetchall()
    lats = sorted(c - s for s, c in lat if c > s)
    med = f"{lats[len(lats)//2]:.1f}s" if lats else "-"
    ti, to = con.execute("""
      SELECT coalesce(SUM(json_extract(data,'$.tokens.input')),0),
             coalesce(SUM(json_extract(data,'$.tokens.output')),0)
      FROM session_message WHERE type='assistant'
        AND date(time_created/1000,'unixepoch','localtime')=?""", (d,)).fetchone()
    print(f"{d:<12} {tot:>7} {okc:>7} {ec:>6} {ec/max(1,tot):>6.1%} {med:>9} {ti:>10} {to:>10}")
print()
print("  lat = time.completed - time.created. A day with a high median and no")
print("  quota errors is slow, not rate-limited — a different problem entirely.")
print()

print("=== 6. Where requests fail, by error type (window) ===")
print(f"{'error.type':<28} {'n':>6} {'model':<34}")
for et, n, mdl in con.execute("""
  SELECT json_extract(data,'$.error.type'),
         COUNT(*), coalesce(json_extract(data,'$.model.id'),'-')
  FROM session_message WHERE type='assistant'
    AND json_extract(data,'$.error.type') IS NOT NULL
  GROUP BY 1,3 ORDER BY 2 DESC LIMIT 12"""):
    print(f"  {et:<26} {n:>6} {mdl:<34}")
print()
print("  provider.quota    -> rate limit, the one the daemon acts on")
print("  provider.transport-> ECONNRESET; a rotate cuts live requests, and WARP")
print("                      also changes edge on its own (see WARP-AUTO.md 5.9)")
print("  provider.auth     -> 403 free tier, rotates cannot help")
print()

print("=== 7. Which model carries the rate limits ===")
for mdl, q, okc in con.execute(f"""
  SELECT coalesce(json_extract(data,'$.model.id'),'unknown'),
         SUM({Q}), SUM({OK})
  FROM session_message WHERE type='assistant'
  GROUP BY 1 ORDER BY 2 DESC"""):
    q = q or 0; okc = okc or 0
    print(f"  {mdl:<40} quota={q:<6} ok={okc:<7} rate={q/max(1,q+okc):.2%}")
print()
print("  If one model carries nearly all the quota errors, switching model for a")
print("  while is cheaper than rotating the tunnel, which costs a live request.")
print()

print("=== 8. Retries: how many attempts before a request settled ===")
for at, n in con.execute("""
  SELECT json_extract(data,'$.retry.attempt'), COUNT(*)
  FROM session_message WHERE type='assistant'
    AND json_extract(data,'$.retry.attempt') IS NOT NULL
  GROUP BY 1 ORDER BY 1"""):
    print(f"  attempt {at}: {n} requests")
print()
print("  A request that needed 5-8 attempts is one where several calls were lost")
print("  before the tunnel was up. This is the visible cost of cutting :44444.")

# ---- the retry chain, resolved ---------------------------------------------
# A row carrying `retry` records an attempt that FAILED; retry.at is when that
# failed attempt happened, which is later than the row's own time_created. The
# outcome of the chain lives on the NEXT assistant row, so the pair has to be
# joined to know whether the retry actually rescued anything.
print()
print("=== 9. What happened after a retry (chain outcome) ===")
rows = con.execute("""
  SELECT time_created,
         json_extract(data,'$.retry.at'),
         json_extract(data,'$.retry.attempt'),
         json_extract(data,'$.retry.error.type')
  FROM session_message WHERE type='assistant'
    AND json_extract(data,'$.retry') IS NOT NULL
    AND json_extract(data,'$.error.type') IS NOT NULL
  ORDER BY time_created""").fetchall()
if rows:
    tally, ages, total = {}, [], []
    for tc, rat, att, et in rows:
        nxt = con.execute("""
          SELECT time_created, json_extract(data,'$.error.type'),
                 json_extract(data,'$.finish')
          FROM session_message WHERE type='assistant'
            AND time_created BETWEEN ? AND ? ORDER BY time_created LIMIT 1""",
            (rat, rat + 60000)).fetchone()
        if not nxt:
            key = "nothing within 60s"
        elif nxt[1]:
            key = nxt[1]
        else:
            key = f"recovered ({nxt[2]})"
        tally[key] = tally.get(key, 0) + 1
        if rat and rat > tc:
            ages.append((rat - tc) / 1000.0)
        if nxt:
            total.append((nxt[0] - tc) / 1000.0)
    for k, v in sorted(tally.items(), key=lambda kv: -kv[1]):
        print(f"  {k:<28} {v:>5}  ({v/len(rows):.0%})")
    print()
    if ages:
        s = sorted(ages)
        print(f"  request age when the retry fired: median {s[len(s)//2]:.1f}s")
    if total:
        s = sorted(total)
        print(f"  first attempt -> final outcome: median {s[len(s)//2]:.0f}s, "
              f"max {s[-1]:.0f}s, {sum(s)/3600:.1f}h total over {len(s)} requests")
    print()
    print("  Read: 'recovered' means the retry rescued the request and cost only")
    print("  time. A transport failure that ends as provider.quota means the retry")
    print("  ran, and then hit the rate limit anyway — the tunnel was cut for")
    print("  nothing. That pairing is the clearest sign that rotating is harmful.")
else:
    print("  no retry markers recorded")
print()

# ---- dead sessions -----------------------------------------------------------
# A failure that repeats to the end of a session and never recovers is a
# different animal from a 429 or a dropped socket: the request payload itself
# is rejected, so retrying, rotating the tunnel or waiting does not clear it.
# Those sessions are dead until they are forked or compacted, and a rotate in
# the meantime buys nothing.
print("=== 10. Dead sessions: failure run at the tail that never recovered ===")
rows = con.execute("""
  WITH w AS (
    SELECT session_id, time_created,
           json_extract(data,'$.error.type') AS et,
           json_extract(data,'$.model.id')  AS mdl
    FROM session_message WHERE type='assistant'
  ),
  lastok AS (
    SELECT session_id, MAX(time_created) AS t FROM w WHERE et IS NULL GROUP BY session_id
  )
  SELECT w.session_id, COUNT(*), MIN(w.time_created), MAX(w.time_created),
         coalesce(max(w.et),'-'), coalesce(max(w.mdl),'-')
  FROM w JOIN lastok USING(session_id)
  WHERE w.et IS NOT NULL AND w.time_created > lastok.t
  GROUP BY w.session_id
  HAVING COUNT(*) >= 3
  ORDER BY MAX(w.time_created) DESC
  LIMIT 15""").fetchall()
if rows:
    print(f"{'session':<26} {'fails':>5} {'first':<20} {'last':<20} "
          f"{'error.type':<26} model")
    for sid, n, t0, t1, et, mdl in rows:
        f = lambda t: datetime.datetime.fromtimestamp(t/1000).strftime("%m-%d %H:%M:%S")
        print(f"{sid:<26} {n:>5} {f(t0):<20} {f(t1):<20} {et:<26} {mdl}")
    print()
    print("  These sessions failed every turn after their last good one. A rotate")
    print("  cannot help them: nothing about the egress changes. The recovery is")
    print("  /fork or /compact in that session, or a new session. If the error.type")
    print("  is provider.invalid-request the upstream returned HTTP 400 on the")
    print("  request body — the message is 'The request contains invalid")
    print("  parameters', and OpenCode does not retry it.")
else:
    print("  none: every session recovered or had fewer than 3 trailing failures")
print()

# ---- tuning observability: read-only views over existing files ---------------
# Sections 11-16 close the tuning blind spots without writing anything new:
# every number below parses files the daemon already keeps (auto.log narrative,
# V-row elapsed, mode= tags, route-path lines, DB transport rows, the plugin
# signal log, the outcome queue). No writer changed, no shape changed, so old
# reports still read new files and these views read old files true.
_auto = sys.argv[5] if len(sys.argv) > 5 else ""
_sigf = sys.argv[6] if len(sys.argv) > 6 else ""
_quef = sys.argv[7] if len(sys.argv) > 7 else ""
alog = []
if _auto and os.path.exists(_auto):
    alog = open(_auto, errors="replace").read().splitlines()

print("=== 11. Rotate latency: start->done, down/up windows ===")
_starts, _pairs, _downs, _ups, _drains, _defers = [], [], [], [], [], []
for _line in alog:
    _lm = re.match(r"(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) (.*)$", _line)
    if not _lm:
        continue
    try:
        _ep = int(datetime.datetime.strptime(_lm.group(1), "%Y-%m-%d %H:%M:%S").timestamp())
    except ValueError:
        continue
    _msg = _lm.group(2)
    if "rotate start" in _msg:
        _starts.append(_ep)
    elif _msg.startswith("rotate done") or _msg.startswith("rotate stopped") \
            or _msg.startswith("rotate FAILED"):
        if _starts:
            _pairs.append(_ep - _starts.pop(0))
    _d = re.search(r"down-window:\s*(\d+)s", _msg)
    if _d:
        _downs.append(int(_d.group(1)))
    _u = re.search(r"up-window:\s*(\d+)s", _msg)
    if _u:
        _ups.append(int(_u.group(1)))
    _dr = re.search(r"stream drained after (\d+)s", _msg)
    if _dr:
        _drains.append(int(_dr.group(1)))
    if "deferred: stream open" in _msg:
        _defers.append(_ep)
def _stat(_name, _xs):
    if not _xs:
        print(f"  {_name}: none recorded yet")
    else:
        _s = sorted(_xs)
        print(f"  {_name}: n={len(_xs)} median={_s[len(_s)//2]}s max={_s[-1]}s")
if not alog:
    print("  no auto.log yet — nothing to time")
else:
    _stat("start->done", [p for p in _pairs if p <= 600])
    _orph = sum(1 for p in _pairs if p > 600)
    if _orph:
        print(f"  orphaned pairs (>600s, start lost to log trim): {_orph}")
    _stat("down-window", _downs)
    _stat("up-window", _ups)
    _stat("stream-drain", _drains)
    print(f"  stream deferrals: {len(_defers)}")
    print(f"  unpaired rotate starts (no done line yet): {len(_starts)}")
print()
print("  Read: start->done is the user-visible cut. down-window is the")
print("  deliberate hold; up-window includes reconnect+serve. A high median")
print("  up-window with no quota change is outage without cure.")
print()

print("=== 12. Holds: park/dedupe hits, and signals per model ===")
HOLD_PATS = [
    ("dedupe-hit", ("dedupe hit key=", "inside dedupe window")),
    ("single-guard-hold", ("single-429 backoff",)),
    ("single-guard-expire", ("expired with no 2nd signal",)),
    ("quota-park-hold", ("holding: quota park",)),
    ("same-edge-park-latch", ("during same-edge park",)),
    ("stuck-park-set", ("no more tunnel cuts for this edge",)),
    ("quota-window-park", ("quota-window:",)),
    ("cooldown-latch", ("cooling down",)),
    ("failed-backoff-hold", ("holding off",)),
    ("quota-text-backoff", ("backing off",)),
]
_hold_tot = {k: 0 for k, _ in HOLD_PATS}
_hold_mod = defaultdict(lambda: defaultdict(int))
for _line in alog:
    for _cat, _pats in HOLD_PATS:
        if any(p in _line for p in _pats):
            _hold_tot[_cat] += 1
            _mm = re.search(r"model=([^\s]+)", _line)
            if _mm:
                _mdl = _mm.group(1)
            else:
                _km = re.search(r"key=([^ :\s]+)", _line)
                _mdl = _km.group(1).split(":")[0] if _km else "shared"
            _hold_mod[_cat][_mdl] += 1
            break
_sig_mod, _sig_n = defaultdict(int), 0
_sig_exists = bool(_sigf and os.path.exists(_sigf))
if _sig_exists:
    for _line in open(_sigf, errors="replace"):
        _p = _line.split()
        if len(_p) >= 3:
            _sig_mod[_p[1]] += 1
            _sig_n += 1
if _sig_exists:
    print(f"  plugin signals: {_sig_n} lines")
    for _mdl, _n in sorted(_sig_mod.items(), key=lambda kv: -kv[1])[:10]:
        print(f"    {_mdl:<40} {_n}")
else:
    print("  plugin signals: no signal log yet")
if any(_hold_tot.values()):
    print(f"  {'hold':<22} {'n':>5} per-model")
    for _cat, _ in HOLD_PATS:
        if _hold_tot[_cat]:
            _det = ", ".join(f"{m}={c}" for m, c in sorted(
                _hold_mod[_cat].items(), key=lambda kv: -kv[1]))
            print(f"  {_cat:<22} {_hold_tot[_cat]:>5} {_det}")
else:
    print("  no holds recorded in auto.log yet")
print()
print("  Read: dedupe-hit is the storm guard working (backoff, no cut). A")
print("  model with all the quota errors AND all the holds is parked alone;")
print("  others still rotate. quota-window-park means the edge is not helping.")
print()

print("=== 13. Verdict latency distribution (V rows) ===")
_elapsed, _unknown = [], 0
if os.path.exists(ledger):
    for _line in open(ledger, errors="replace"):
        _p = _line.rstrip("\n").split("\t")
        if _p and _p[0] == "V" and len(_p) >= 4:
            if _p[2].isdigit():
                _elapsed.append(int(_p[2]))
            else:
                _unknown += 1
_buckets = [("<=130s (within wait)", 0, 130), ("131-300s", 131, 300),
            ("301-650s", 301, 650), (">650s", 651, None)]
for _e in _elapsed:
    for _name, _lo, _hi in _buckets:
        if _e >= _lo and (_hi is None or _e <= _hi):
            break
if _elapsed:
    for _name, _lo, _hi in _buckets:
        _c = sum(1 for _e in _elapsed if _e >= _lo and (_hi is None or _e <= _hi))
        print(f"  {_name:<22} {_c:>5}  ({_c/len(_elapsed):.0%})")
    if _unknown:
        print(f"  {'unparseable':<22} {_unknown:>5}")
else:
    print("  no V rows yet — no rotate has been graded")
_pend = 0
if _quef and os.path.exists(_quef):
    _pend = sum(1 for _line in open(_quef, errors="replace") if _line.strip())
print(f"  pending verdicts in outcome_queue: {_pend}")
print()
print("  Read: elapsed is grading delay (rotate -> V row), not outcome. A fat")
print("  >650s tail means verdicts land late and tuning reads stale grades.")
print("  Pending counts rotates still inside their verdict window.")
print()

print("=== 14. Proxy-listener health timeline (mode= tags in auto.log) ===")
_daymode, _via = defaultdict(lambda: [0, 0]), defaultdict(int)
for _line in alog:
    _dm = re.match(r"(\d{4}-\d{2}-\d{2})", _line)
    _mm2 = re.search(r"mode=(proxy|tunnel)", _line)
    if _dm and _mm2:
        if _mm2.group(1) == "proxy":
            _daymode[_dm.group(1)][0] += 1
        else:
            _daymode[_dm.group(1)][1] += 1
    _vm = re.search(r"via (local-proxy|system-tunnel)", _line)
    if _vm:
        _via[_vm.group(1)] += 1
if _daymode:
    print(f"  {'date':<12} {'proxy':>6} {'tunnel':>7}")
    for _d in sorted(_daymode)[-days:]:
        _p, _t = _daymode[_d]
        print(f"  {_d:<12} {_p:>6} {_t:>7}")
else:
    print("  no mode= tags in auto.log yet")
print("  edge-route mentions: " + (", ".join(f"{k}={v}" for k, v in _via.items()) or "none"))
_mcf = os.path.join(os.path.dirname(_auto), "mode_cache") if _auto else ""
_cache = open(_mcf).read().strip() if _mcf and os.path.exists(_mcf) else ""
print(f"  mode_cache now: {_cache or 'missing (next round probes)'}")
print()
print("  Read: tunnel rows mean the system tunnel serves (rotates cure); proxy")
print("  rows mean :44444 serves (rotates are useless there). A flip mid-day")
print("  explains a verdict swing better than any IP delta.")
print()

print("=== 15. Route decisions (model -> path) ===")
_routed = defaultdict(lambda: defaultdict(int))
for _line in alog:
    _rm = re.search(r"route path:\s*(\S+)\s+for model\s+(\S+)", _line)
    if _rm:
        _routed[_rm.group(2)][_rm.group(1)] += 1
if _routed:
    for _mdl in sorted(_routed):
        _det = ", ".join(f"{p}={c}" for p, c in sorted(_routed[_mdl].items()))
        print(f"  {_mdl:<40} {_det}")
else:
    print("  no route-path lines in auto.log yet")
print()
print("  Read: responses vs chat must follow the family table; 'off' rows are")
print("  refusals (jev never routes). A model with quota errors but no route")
print("  line never reached the rotator.")
print()

print("=== 16. Transport errors timeline (ECONNRESET class) ===")
print(f"  {'date':<12} {'transport':>9}")
for _d, _n in con.execute("""
  SELECT date(time_created/1000,'unixepoch','localtime'), COUNT(*)
  FROM session_message WHERE type='assistant'
    AND json_extract(data,'$.error.type')='provider.transport'
  GROUP BY 1 ORDER BY 1 DESC LIMIT ?""", (days,)):
    print(f"  {_d:<12} {_n:>9}")
_tl = sum(1 for _line in alog if "ECONNRESET" in _line
          or "provider.transport" in _line or "transport failure" in _line)
print(f"  auto.log transport mentions: {_tl}")
print()
print("  Read: transport is a cut live request or a WARP blip, not a quota.")
print("  A transport spike right after a rotate is the rotate's own cost.")
PY
}
