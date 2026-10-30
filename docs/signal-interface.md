# Rotate-signal Interface

One append-only text file carries 429 signals from the OpenCode plugin layer
to the policy daemon. Writers append lines; the daemon (`bin/zen auto`)
advances per-file byte cursors and never rewrites the file.

File: `$STATE_DIR/signals/zen-quota.log`
(`SIGNAL_DIR` / `ZEN_SIGNAL_FILE` env overrides keep tests hermetic.)

## Line format

```
<ISO8601> <model-id> <trigger-text>
```

| Field | Position | Rule | Daemon reader |
|---|---|---|---|
| Timestamp | `$1` | ISO8601, parseable by `date -d` | `recent_zen_hook_signal` (hook-dedupe window) |
| Model | `$2` | Single token; must satisfy the free-tier predicate (see `lib/auto.sh` `is_free_model`): ends with `-free` (non-jev), or is a declared suffixless free id (`big-pickle`, `grok-code`); `ZEN_FREE_MODELS` adds extra ids | `keep_free_signals`, `signal_model_counts` |
| Trigger | rest of line | Must match `rate limit exceeded\|retry-after\|status[=: ]+429` (case-insensitive) | `scan_new` with `PATTERN` |
| Hint | anywhere in line | Optional `retry-after N` (N in seconds); honored capped, else a short fixed backoff | `retry_after_secs` |

The daemon is authoritative on the model: a line whose `$2` does not satisfy
the free-tier predicate is dropped even when the trigger text matches. Writers
pass the event model through; they do not decide.

## Examples

Live session-retry hook (after writer sync):

```
2026-10-07T19:00:01.123Z muse-spark-1.3-contributor-free rate limit exceeded status=429 source=zen-session-retry-hook retry-after=5
```

Seam-test fixture (same shape, fixed clock):

```
2026-10-07T19:00:01 m1 429 rate limit exceeded retry-after 5
```

## Writer reference

- `zen-quota-retry.js` `rotateForQuota` (home config, live path): builds the
  line from the hook event — timestamp, `event.model.id`, trigger text,
  `retry-after` in seconds when the provider sent one. Writer only: no
  rotate, no decision, no cooldown.
- `plugins/zen-warp.js` `emitSignal` (repo + home copy, identical):
  `<ISO8601> <model-id> 429[ retry-after=N]`. Note: a bare line without
  `retry-after` matches no `PATTERN` alternative, so only hint-carrying
  lines count. Unchanged by this contract.

**Writer-side gate.** `zen-quota-retry.js` bakes in its own copy of the free
predicate (`FREE_SUFFIXLESS` = `{big-pickle, grok-code}`, plus `-free`,
non-jev) and does not read the daemon's `ZEN_FREE_MODELS` /
`ZEN_FREE_SUFFIXLESS` — separate process, separate env. A new suffixless
zero-cost model therefore needs the constant updated in BOTH
`zen-quota-retry.js` and the daemon (`ZEN_FREE_SUFFIXLESS`);
`ZEN_FREE_MODELS` widens the daemon side only. The live registry probe in
`tests/test-issue-8.sh` fails loudly the moment a new suffixless zero-cost id
appears (drift detector), which is how either side gets found.

## Reader reference (`lib/auto.sh`)

- `active_429_logs` — the signal file is the only 429 log source.
- `scan_new` / `detect_429_new` — count new matching lines, advance cursors.
- `keep_free_signals` / `signal_model_counts` — per-model attribution peek.
- `recent_zen_hook_signal` — hook-dedupe window off `$1`.
- `retry_after_secs` — capped hint off the line tail.
- `seed_cursors` — cold start skips history (no replay of old lines).

No contract test: this file is the contract (user choice).
