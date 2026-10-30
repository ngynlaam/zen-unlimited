#!/usr/bin/env bash
# tests/test-issue-13.sh — TDD seam tests for ngynlaam/zen-unlimited#13.
# Seams only: `bin/zen auto --route-test <model-id>` CLI (prints
# responses|chat|off). Fake STATE_DIR, no signals, warp-cli never runs.
# Static fixtures pin each family; a live probe resolves the real catalog
# when reachable (skips cleanly offline). No private names asserted.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
ZEN="$REPO/bin/zen"
PASS=0; FAIL=0
. "$(dirname "$0")/helper.sh"

CASE_DIR=$(mktemp -d /tmp/opencode/issue-13.XXXXXX)
export STATE_DIR=$CASE_DIR SIGNAL_DIR=$CASE_DIR/signals DB_FILE=$CASE_DIR/none.db
export ROTATE_NOTIFY=0 ZEN_FREE_MODELS="muse-spark-1.3-contributor-free"
mkdir -p "$SIGNAL_DIR"

route() { timeout 30 "$ZEN" auto --route-test "$1" 2>/dev/null; }


# Static fixtures: each family hits its right path.
check "muse-spark uses responses" responses "$(route muse-spark-1.3-contributor-free)"
check "muse-spark 1.2 uses responses" responses "$(route muse-spark-1.2)"
check "gpt kin uses responses" responses "$(route gpt-5-codex)"
check "grok kin uses responses" responses "$(route grok-4.7)"
check "deepseek uses chat" chat "$(route deepseek-v4-flash)"
check "space-bunny uses chat" chat "$(route space-bunny-free)"
check "unknown uses chat" chat "$(route unknown-model-xyz)"
check "jev-free stays off" off "$(route jev-1.13-free)"
check "jev bare stays off" off "$(route jev-1.13)"

# Live probe: every catalog id resolves per the same rule.
CATALOG=$(curl -s -m 8 "https://opencode.ai/zen/v1/models?free=true" 2>/dev/null || echo "")
if [ -z "$CATALOG" ] || ! printf '%s' "$CATALOG" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
  echo "SKIP: live probe offline, static fixtures rule"
else
  IDS=$(printf '%s' "$CATALOG" | python3 -c 'import json,sys; print(" ".join(m["id"] for m in json.load(sys.stdin)["data"]))')
  bad=0; n=0
  for id in $IDS; do
    n=$((n + 1))
    case "$id" in
      jev|jev-*) want=off;;
      muse-spark*|gpt-*|grok-*) want=responses;;
      *) want=chat;;
    esac
    got=$(route "$id")
    [ "$got" = "$want" ] || { echo "  live mismatch: $id want $want got $got"; bad=$((bad + 1)); }
  done
  if [ "$bad" -eq 0 ]; then PASS=$((PASS+1)); echo "PASS: live probe all $n catalog ids resolve";
  else FAIL=$((FAIL+1)); echo "FAIL: live probe $bad/$n mismatches"; fi
fi

rm -rf /tmp/opencode/issue-13.*
suite_done "issue-13"
