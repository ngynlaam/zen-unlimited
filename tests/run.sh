#!/usr/bin/env bash
# Safe test entrypoint: bash tests/run.sh (from any directory).
# Requires Bash, Git, coreutils, util-linux, grep, sed, awk, sqlite3, Python 3.
# Optional: bats for policy.bats; Node.js for JavaScript syntax checks.
# ZEN_TEST_LIVE_REGISTRY=1 enables live catalog probes and requires curl.
# Run serially: some existing suites remove shared fixture prefixes.
# timing-probe.sh is diagnostic only and is never executed here.
set -uo pipefail
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd -- "$REPO" || exit 1
missing=0
for dep in bash git timeout mktemp date stat cut tr sort uniq wc cat mkdir chmod rm touch sleep dirname flock grep sed awk sqlite3 python3; do
  if ! command -v "$dep" >/dev/null 2>&1; then
    printf 'ERROR: missing required dependency: %s\n' "$dep" >&2
    missing=1
  fi
done
if [[ ${ZEN_TEST_LIVE_REGISTRY:-0} == 1 ]] && ! command -v curl >/dev/null 2>&1; then
  echo 'ERROR: live registry probes require curl' >&2
  missing=1
fi
(( missing == 0 )) || exit 2
mkdir -p /tmp/opencode
guard=$(mktemp -d /tmp/opencode/test-runner.XXXXXX) || exit 2
trap 'rm -rf -- "$guard"' EXIT
# Never call installed network/service control commands. Individual tests may
# prepend their own fake adapters. This does not replace a network sandbox.
for cmd in warp-cli systemctl; do
  printf '#!/bin/sh\necho "ERROR: real %s blocked by test runner" >&2\nexit 125\n' "$cmd" > "$guard/$cmd"
  chmod +x "$guard/$cmd"
done
if [[ ${ZEN_TEST_LIVE_REGISTRY:-0} != 1 ]]; then
  printf '#!/bin/sh\nexit 7\n' > "$guard/curl"
  chmod +x "$guard/curl"
  echo 'SKIP: live catalog requests disabled (ZEN_TEST_LIVE_REGISTRY=1 enables them)'
fi
export PATH="$guard:$PATH"
failed=0; passed=0; skipped=0
# Check tracked and new shell files, including shell entrypoints without .sh.
files=$(git ls-files --cached --others --exclude-standard) || exit 2
while IFS= read -r file; do
  [[ -f $file ]] || continue
  [[ $file == *.bats ]] && continue
  IFS= read -r first < "$file" || true
  if [[ $file == *.sh || $first =~ ^\#!.*(bash|/sh|\ sh)([[:space:]]|$) ]]; then
    if ! bash -n "$file"; then
      printf 'FAIL: shell syntax: %s\n' "$file"
      failed=$((failed + 1))
    fi
  fi
done <<< "$files"
if (( failed > 0 )); then
  echo "FAIL: $failed shell syntax checks; suites not started"
  exit 1
fi
echo 'PASS: shell syntax checks'
if command -v node >/dev/null 2>&1 && node --input-type=module --check </dev/null >/dev/null 2>&1; then
  while IFS= read -r file; do
    [[ $file == *.js && -f $file ]] || continue
    if node --input-type=module --check < "$file"; then
      printf 'PASS: JavaScript syntax: %s\n' "$file"
    else
      printf 'FAIL: JavaScript syntax: %s\n' "$file"
      failed=$((failed + 1))
    fi
  done <<< "$files"
else
  echo 'SKIP: JavaScript syntax (Node.js module syntax check unavailable)'
  skipped=$((skipped + 1))
fi
for suite in tests/test-*.sh; do
  printf '\nRUN: %s\n' "$suite"
  if bash "$suite"; then
    passed=$((passed + 1))
  else
    printf 'FAIL: suite %s\n' "$suite"
    failed=$((failed + 1))
  fi
done
if command -v bats >/dev/null 2>&1; then
  echo 'RUN: tests/policy.bats (currently contains skipped policy stubs)'
  if bats tests/policy.bats; then passed=$((passed + 1)); else failed=$((failed + 1)); fi
else
  echo 'SKIP: tests/policy.bats (install bats to run; policy tests are stubs)'
  skipped=$((skipped + 1))
fi
echo 'SKIP: tests/timing-probe.sh (manual diagnostic, not a test suite)'
skipped=$((skipped + 1))
printf '\nRESULT: passed suites=%d failures=%d skipped groups=%d (see suite output for assertion skips)\n' "$passed" "$failed" "$skipped"
(( failed == 0 ))
