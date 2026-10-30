# zen-unlimited

Mode-aware OpenCode launcher and WARP rotation daemon. In proxy mode,
OpenCode uses `127.0.0.1:44444`, except for the `NO_PROXY` hosts below.
In tunnel mode, the launcher clears proxy variables and uses the system route.
It does not prove that the system route uses WARP.

**Compatibility limit:** OpenCode's [V2 server plugin documentation](https://opencode.ai/v2/docs/build/plugins/server)
defines the `{ id, setup(ctx) }` plugin format, `ctx.session.hook("retry")`,
and `event.decision`. The retry API is documented. This plugin also replaces
`globalThis.fetch` at module import time for routing. That interception and
its timing depend on undocumented implementation details; check routing on
your OpenCode build before relying on it.

License: [MIT](LICENSE). For changes, read [CONTRIBUTING.md](CONTRIBUTING.md).

## Module map

| Module | File | Interface |
|---|---|---|
| Plugin (Signal Adapter) | `plugins/zen-warp.js` | OpenCode hook appends one signal line to the signals log. No policy logic. |
| Decision (policy daemon) | `bin/zen auto` | Reads signal log + DB fallback, decides rotate / hold / park. Default with no args. Flags: `--once`, `--detect-test`, `--edge-test`, `--wait-test`, `--route-test`. |
| Actuator (rotate) | `bin/zen rotate` | Runs `warp-cli` disconnect/connect cycle, then probes egress. No flags, env-driven. |
| Observer (report) | `bin/zen report` | Read-only use of DB + edge timeline + ledger. No flags, env-driven. |
| Observer (catch) | `bin/zen catch` | Bundles transient transport resets from 3 logs into `$STATE_DIR/catch/`. No flags for watch; `--once`, `--self-test`. |
| Routing (launcher) | `bin/zen launch` | Starts OpenCode with proxy env set. Passes args through. `ZEN_LAUNCH_PROXY=off` runs direct. |

Thin rollback wrappers `bin/warp-auto`, `bin/warp-rotate`,
`bin/warp-report`, `bin/opencode2-warp` each run the matching `bin/zen`
subcommand. The optional systemd service starts the installed `warp-auto`.

Seams: signal log files (`signals/`, `$STATE_DIR/signals/`) between Plugin
and Decision; state files under `$STATE_DIR` between daemon rounds;
`rotations.tsv` ledger between Decision and Observer; one internal rotate
call (Decision to Actuator, no new process).

## Route table

| Path | What uses it |
|---|---|
| WARP via `127.0.0.1:44444` | Zen inference, and other OpenCode HTTPS except `NO_PROXY` |
| Direct (no proxy) | Loopback hosts `localhost,127.0.0.1,::1` + remote MCP hosts (`mcp.cloudflare.com`, `mcp.context7.com`, `mcp.grep.app`) — override with `ZEN_LAUNCH_NO_PROXY` |

The launcher sets one proxy environment for OpenCode. `NO_PROXY` excludes
the listed MCP hosts from that local proxy. It does not bypass a system
WARP tunnel. Actual request routing also depends on the plugin and build.

## Prerequisites and safety

- Linux with Bash, GNU core utilities, `curl`, `grep`, `ip` and `ss`
  (iproute2), `sqlite3`, and `python3`. `inotifywait` (inotify-tools) is
  optional; the daemon has a polling fallback. User systemd is optional.
- OpenCode must be installed. Put `opencode` on `PATH`, or set
  `ZEN_OPENCODE_BIN` to its executable path for `zen launch`.
- Install Cloudflare WARP separately. Register it as required by your WARP
  installation. The same user that runs the daemon must have permission to
  run `warp-cli status`, `disconnect`, and `connect` without a password prompt.
  The installer does not configure WARP, grant permissions, or use `sudo`.
- For local proxy mode, configure WARP to listen on `127.0.0.1:44444`.
  On CLI versions with these commands, setup uses `warp-cli mode proxy` and
  `warp-cli proxy port 44444`, then `warp-cli connect`. Check your installed
  `warp-cli --help` first. A system tunnel is also supported; a missing proxy
  listener alone is not proof that a tunnel is connected.

**Warning:** WARP mode changes, connect/disconnect commands, and daemon
rotations can interrupt active network requests. Do setup only when you accept
this interruption. Do not run these commands only to test an installation.
The installer does not start a service. Starting the daemon opts in to automatic
WARP disconnect/connect cycles, including cuts of active requests.

Compatibility evidence is limited, not a supported-version matrix. A comment
in `plugins/zen-quota-retry.js` claims that import-time fetch interception was
early enough on OpenCode `v2.0.15`. This is a source comment, not a test result
verified for this release. Historical proxy and tunnel observations in
`WARP-AUTO.md` do not establish current plugin compatibility. Repository tests
use fake state and rotators for policy checks. These do not establish minimum
OpenCode, Bun, WARP, Steam, or Linux versions, or guarantee routing on another
build.

## Install

Get the source first (requires Git):

```sh
git clone https://github.com/ngynlaam/zen-unlimited.git
cd zen-unlimited
```

1. Run `./install.sh`.
   - `plugins/zen-warp.js` goes to `~/.config/opencode/plugins/zen-warp.js`.
   - `plugins/zen-quota-retry.js` goes to `~/.config/opencode/plugins/zen-quota-retry.js`.
   - `bin/zen` and wrappers go to `~/.local/share/warp-rotate/bin/`.
   - `lib/*.sh` go to `~/.local/share/warp-rotate/lib/` (`bin/zen`
     sources `../lib`, so install keeps the pair together).
   - State files stay in place. Install never copies or resets them.
    - The optional `bin/steam-warp` is also installed when present. See
      [Steam instructions](docs/steam-warp.md).
    - Both plugins are required. A missing plugin stops installation before copying.
    - `PLUGIN_DST` and `BIN_DST` change the targets. Libraries must stay in
      the `lib` directory next to `BIN_DST`; `LIB_DST` cannot change this layout.
2. Start OpenCode with `~/.local/share/warp-rotate/bin/zen launch`.
   Use `~/.local/share/warp-rotate/bin/zen report` for a read-only report.
   The installed directory is not added to `PATH`. Restart OpenCode after
   plugin updates or route changes so it loads the new plugins and environment.

### Optional user service

Review `systemd/warp-auto.service` before use. It uses the default install
path and the tuned profile, not the aggressive profile. For a custom install,
change `ExecStart`. Add a service `PATH` override if your tools are elsewhere.
After you accept automatic network interruptions, run:

```sh
mkdir -p ~/.config/systemd/user
cp systemd/warp-auto.service ~/.config/systemd/user/warp-auto.service
systemctl --user daemon-reload
systemctl --user enable --now warp-auto.service
```

These steps are opt-in and are never run by `install.sh`. For an existing
service, inspect its unit before an update. Restart it after installed code
changes to load the new code. A new daemon can rotate immediately if a 429
is pending. Use `systemctl --user disable --now warp-auto.service` to stop
automatic rotation; this does not disconnect WARP.

## Trade-off

Each rotate interrupts the WARP path. Local measurements recorded about
7 seconds, but the duration depends on connection and readiness checks.
Active requests can fail and need a retry. Rotation does not guarantee that
a 429 clears. Policy decides whether to rotate or park; see the current
defaults in `lib/state.sh`. `NO_PROXY` bypasses the local proxy, not the
system tunnel, so tunnel rotations can also interrupt those hosts.

## Aggressive profile

`ZEN_AGGRESSIVE=1` rotates on the first 429 (no lone-429 backoff) with
shorter storm guards: dedupe proxy 90→10s, tunnel 25→10s; quota park proxy
600→120s, tunnel 90→30s; `BURST_COUNT`→1. Stuck park stays 10s,
`MAX_STUCK` stays 1, `DOWN_HOLD` stays 2s. Default off keeps the tuned
values. The daemon start line in `auto.log` records `profile=tuned` or
`profile=aggressive`. The systemd unit enables it via
`Environment=ZEN_AGGRESSIVE=1` only if you add that setting yourself.

### Retry choreography (aggressive path only)

On an actionable 429 the aggressive path runs one immediate-repeat cycle
at a time with this pacing (tuned path unchanged):

| Step | Wait | What |
|---|---|---|
| Hold-new-requests pause | bounded drain (`ZEN_DRAIN_S`, default 1s, already inside `do_rotate`) | no new cut mid-stream |
| Warp down | `DOWN_HOLD` 2s (existing) | selected WARP route confirmed down |
| Warp up | readiness probes already inside `reconnect` (`wait_connected` + `wait_ready` stay as-is) | tunnel back |
| Post-up wait | `ZEN_CHOREO_POST_UP_S` 2s cap, readiness-gated (was: fixed 2s sleep) | poll the same probes after up; proceed the moment they pass, never slower than the old sleep. `ready-by-probe` vs `ready-by-cap` in `auto.log` |
| Mark ready | — | `choreo: ready` in `auto.log`: client retries flow at once |
| Settle window | `ZEN_CHOREO_SETTLE_S` 3s cap, success-gated (was: fixed 3s sleep) | stop early on the first 429 (repeat) or on no-429 plus a new Zen OK row in the DB; with no DB success evidence observable the daemon falls back to first-429-or-cap and says so. `stopped-by-success` vs `stopped-by-cap` vs `repeat-on-429` in `auto.log` |

A 429 inside the settle window repeats the cycle IMMEDIATELY (no
dedupe/backoff between cycles). A clean window stops and normal watch
resumes. One cycle costs about 7s of WARP-path outage plus rotate
overhead.

Safety escape hatch (disclosed here and in `auto.log`, never silent):
after `ZEN_CHOREO_MAX` (default 3) consecutive fruitless cycles — each one
followed by a 429 inside its own settle window — the daemon falls back to
the existing quota-park path (`quota_until = now + per-mode park`, latch
kept for after the park) instead of cutting the tunnel again. This bounds
the outage churn; the aggressive storm cap (default 6 rotates per 600s) stays as the outer
bound and is checked every cycle.

## Observability

`bin/zen report` is read-only over the DB + state files. No writer changed
for observability: every view below parses files the daemon already keeps.

| Source | What it carries | Report view |
|---|---|---|
| `session_message` (opencode.db) | quota rate, error types, latency, tokens, models, retries, chains, dead sessions | §1, §5–§10, §16 |
| `edge_timeline.tsv` | egress segments for attribution | §2–§3 |
| `rotations.tsv` R rows | reason, before/after, edge change, rc, path | §4 |
| `rotations.tsv` V rows | grading delay + 429 count in window | §4, §13 |
| `auto.log` narrative | start/done, down/up windows, holds, mode tags, route paths | §11, §12, §14–§16 |
| `signals/zen-quota.log` | plugin signal lines per model | §12 |
| `outcome_queue` | rotates awaiting verdict | §13 |
| `mode_cache` | current proxy/tunnel mode | §14 |

Views §11–§16 (tuning blind spots, closed cheapest-first as read-only
parses — no new metric lines were needed, every source already existed):

- §11 rotate latency: start→done pairs, down/up windows, stream drains.
- §12 holds: dedupe/single-guard/quota-park/same-edge/cooldown/fail-backoff
  counts per model, plus plugin signals per model.
- §13 verdict latency distribution (grading delay buckets) + pending queue.
- §14 proxy-listener health: mode=proxy/tunnel per day, route mentions,
  current cache.
- §15 route decisions per model (responses/chat/off refusals).
- §16 transport-error timeline (DB per day + auto.log mentions).

Retry-attempt chains were already covered (§8–§9); the signal Interface
(`docs/signal-interface.md`) is untouched by this change.

## File tree

```
bin/zen                  thin dispatch (usage + source + dispatch)
lib/state.sh             shared state defaults + helpers
lib/auto.sh              decision module (policy daemon)
lib/rotate.sh            actuator module (warp-cli cycle + egress probe)
lib/report.sh            observer module (read-only report)
lib/catch.sh             observer module (live transport-reset bundles)
lib/launch.sh            routing module (launcher)
bin/warp-auto            wrapper -> zen auto (service entry point)
bin/warp-rotate          wrapper -> zen rotate
bin/warp-report          wrapper -> zen report
bin/opencode2-warp       wrapper -> zen launch
bin/steam-warp           optional Steam launcher
plugins/zen-warp.js      signal adapter (OpenCode hook)
plugins/zen-quota-retry.js  routing interception and documented V2 retry hook
systemd/warp-auto.service  opt-in user service template
signals/.keep            empty directory marker, not signal samples
tests/run.sh             test runner (use the documented sandbox)
tests/helper.sh          shared checks + hermetic fixture helper
tests/test-*.sh          seam tests (fake state dir, fake rotator)
tests/test-observability.sh  report views 11-16 over fixture files (no tunnel, no live state)
tests/timing-probe.sh    diagnostic prototype; excluded from the test runner
tests/policy.bats        decision-rule stubs (skipped)
install.sh               installer (plugin + bins, state untouched)
WARP-AUTO.md             append-only ops journal (history, not spec)
```

Use `bin/zen launch` from the source tree, or
`~/.local/share/warp-rotate/bin/zen launch` after installation.
