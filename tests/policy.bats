#!/usr/bin/env bats
# tests/policy.bats — decision-rule placeholders for the Policy Module.
# Interface under test: bin/zen auto handle_signal / check_once policy.
# These are stubs only: they document intent without executing logic.

@test "COOLDOWN=0 rotates immediately on a fresh 429 signal" {
  skip "stub: not wired yet"
}

@test "403 provider rejection is log-only, never rotates" {
  skip "stub: not wired yet"
}

@test "/48 prefix is the dedupe key, never full /128 or IPv4" {
  skip "stub: not wired yet"
}
