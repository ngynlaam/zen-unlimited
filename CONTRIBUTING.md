# Contribute

These rules apply to human and AI contributors. Use simple technical English
for new text. Read [AGENTS.md](AGENTS.md) for the code map and safety rules.

## Change workflow

1. Read the task and inspect `git status --short`. Keep existing changes outside
   the task. Do not reset or overwrite another contributor's work.
2. Read the source for the affected path. Use [CONTEXT.md](CONTEXT.md) for
   terms. Follow [domain rules](docs/agents/domain.md) for design decisions.
   Read the conditional documents in `AGENTS.md` when they apply.
3. Make a small change with a clear purpose. Keep policy, the WARP actuator,
   signal writers, and observers separate. If a data format changes, check
   each producer and consumer. Add a behavior test for an observable change.
4. Select checks from [validation limits](docs/agents/validation.md). Agree on
   who runs them. Do not use installation or a live reconnect as a test.
5. Review the diff for unrelated changes, private data, and stale claims.
   Report files changed, test results, skips, limitations, and open risks.

Issues and specifications use GitHub Issues. Follow
[issue rules](docs/agents/issue-tracker.md) and
[triage labels](docs/agents/triage-labels.md) when applicable. A local file
change is not permission to create issues, commit, push, or publish.

## Public changes

Use synthetic fixtures. Do not include tokens, credentials, prompts, private
host names, live logs, databases, state bundles, or absolute author home paths
in a patch or issue. Review test output before you share it. Replace private
values with clear placeholders; do not claim a placeholder is a working setup.

The selected license is [MIT](LICENSE). Keep its notice with distributed copies.
History changes and publication require explicit approval from the repository
owner. Keep backups private and preserve existing local work.

Repository code is the source for a patch. User installation paths and local
service setup are separate. Historical measurements in `WARP-AUTO.md` do not
prove behavior on another host. A public release needs a separate review of
the whole release content and license; passing tests alone is not release
approval.
