# Validation limits

## Safe execution

Run target code only in an enforced networkless sandbox. Mount repository
source read-only. Give the sandbox private writable scratch paths, including
`/tmp/opencode` and `/tmp`, and a private `HOME`. Do not expose live OpenCode
logs, databases, state, credentials, services, or WARP control sockets. A fake
rotator is not a network boundary: policy paths can still probe the network.
If this isolation is not available, inspect source and report tests as skipped.

Several scripts remove fixture paths with broad globs. Run suites serially in
private scratch space. Do not run them in shared host temporary directories.
Set fixture `LOG_DIR` and `LOG_FILE` before tests: many suites set fake state
but inherit the default OpenCode log path. Check inherited environment values
and redirect all other inputs to fixtures. For manual dry runs, use
`WARP_ROTATE=/bin/true` and `ROTATE_NOTIFY=0`. Tests that assert rotate calls
use their own fake executable instead.

The commands below run *inside* that sandbox, from the repository root.
They do not create the sandbox.

## Current checks

The canonical entry point is `bash tests/run.sh` ([source](../../tests/run.sh)).
[CI](../../.github/workflows/tests.yml) runs the same command in a networkless
Bubblewrap sandbox with registry checks disabled. Local use of the runner
does not create a sandbox. The runner checks dependencies, shell
syntax, optional JavaScript syntax, and all shell suites serially. It blocks
installed `warp-cli` and `systemctl` through PATH guards and disables registry
requests by default. These guards do not replace the sandbox. Keep
`ZEN_TEST_LIVE_REGISTRY` unset for offline validation. The runner also requires
Git and Python 3; Node.js and Bats are optional. See its dependency loop for
the exact executable list.

There is no package-manager test runner. The shell suites use Bash and Linux
tools: GNU coreutils (including `timeout`, `date`, and `mktemp`), `grep`, `sed`,
`awk`, `find`, and `flock` from util-linux. Install `sqlite3` with JSON support
for database fixtures and report checks. `curl` and Python 3 support optional
registry checks. `inotifywait` from inotify-tools enables the event-wait path;
without it, the daemon uses its fallback. Live WARP and OpenCode are not needed
for fixture tests. No JavaScript plugin behavior test suite is supplied.

Select a related suite with `bash tests/<name>.sh`. The current shell suites
are:

| Files | Area |
|---|---|
| `test-rules.sh` | Direct policy rules with fixture state |
| `test-aggressive.sh`, `test-choreo.sh`, `test-speedup.sh` | Profiles, retry timing, and readiness |
| `test-issue-8.sh` | Model filtering and signal/database behavior |
| `test-issue-9.sh` | Outcome ledger and report fixtures |
| `test-issue-10.sh`, `test-issue-11.sh` | Policy guards and backoff |
| `test-issue-12.sh` | Bounded stream drain |
| `test-issue-13.sh` | Model route classification |
| `test-issue-14.sh` | Primary and secondary rotate adapters |
| `test-observability.sh` | Report views over fixtures |
| `test-catch.sh` | Transport-reset bundles over fixture logs |
| `test-review-fixes.sh` | Database filtering and policy regressions |

To run the standard checks inside the sandbox:

```sh
bash tests/run.sh
```

Registry checks in `test-issue-8.sh` require `ZEN_TEST_LIVE_REGISTRY=1`.
Keep it unset for offline checks.
`test-issue-13.sh` also has a
public registry probe. The runner disables registry requests by default;
network isolation must also block them. Record offline skips separately from
fixture results. Some database checks in `test-catch.sh`
skip if `sqlite3` is absent; this does not prove database behavior.

`tests/helper.sh` is sourced by suites, not run on its own.
`tests/policy.bats` contains three skipped placeholders. Running
`bats tests/policy.bats` is not policy coverage. Bats is optional, not a
dependency of the shell suites. `tests/timing-probe.sh` is a diagnostic
prototype, not a regression suite. It probes mode, uses a fixed temporary
path, and reads a ledger under `HOME`; exclude it from routine validation.

## Report limits

State which commands ran, their exit results, and each skipped path. Syntax
checks do not prove behavior. Fixture tests do not prove live reconnects,
installed service behavior, current provider catalog values, or OpenCode plugin
compatibility. Keep these claims separate. Live checks need a separate task
and explicit user permission; never change real logs to create test events.
