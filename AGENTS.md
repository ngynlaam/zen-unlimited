# Agent instructions

Use ASD-STE100 Simplified Technical English for responses and new text, unless
the user requests a different style.

## Start here

- Before a change, read [CONTRIBUTING.md](CONTRIBUTING.md). Keep existing user changes.
- Before code exploration or architecture work, read [domain rules](docs/agents/domain.md) and [CONTEXT.md](CONTEXT.md).
- For GitHub issue work, read [issue rules](docs/agents/issue-tracker.md). For triage, also read [the five label rules](docs/agents/triage-labels.md).
- Before tests, read [validation limits](docs/agents/validation.md).
- Before installation or service changes, read [README.md](README.md) and the opt-in [service template](systemd/warp-auto.service). For Steam launcher work, read [the Steam guide](docs/steam-warp.md).
- Before WARP behavior changes or diagnosis, read [WARP-AUTO.md](WARP-AUTO.md), starting with section 7. It is local operations history, not a current specification. Check claims against source. For operation, also read [the operations guide](docs/huong-dan-van-hanh.md).
- Before signal changes, read [the signal contract](docs/signal-interface.md) and check both writers and the reader.

## Code map

`bin/zen` loads `lib/state.sh` and dispatches to `lib/auto.sh` (default),
`lib/rotate.sh`, `lib/report.sh`, `lib/launch.sh`, or `lib/catch.sh`.
The four rollback wrappers in `bin/` call the matching `zen` command.
`plugins/zen-warp.js` emits signals; `plugins/zen-quota-retry.js` handles
request routing and retry hooks. Check source for active route and model
rules. `README.md` has the wider module map. Root `opencode-warp*` launchers
are not present.

`install.sh` copies code to user paths. Installed copies are not source.
Default state and log paths in `lib/state.sh` are local runtime data, not
fixtures. Host names, ports, service names, and measured timings in operations
documents can be specific to one machine.

## Safety

Live WARP reconnects cut active requests. Get explicit permission before a
manual reconnect, live rotate, install, or service change. Keep Do Not Disturb
as the user set it. An approved daemon policy does not permit manual probes.

Use a networkless sandbox, a read-only source mount, and private writable
scratch space for tests. For manual dry runs, set fake `STATE_DIR`, `LOG_DIR`,
`LOG_FILE`, `SIGNAL_DIR`, and `DB_FILE`, with `WARP_ROTATE=/bin/true` and
`ROTATE_NOTIFY=0`. Isolate other input paths as needed. These variables alone
do not block probes or isolate all plugin paths. Never add test lines to real
OpenCode logs, change real databases, or reset live state.
