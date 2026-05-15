#!/usr/bin/env bash
# Tests for bump.sh — uses BUMP_DRY_RUN=true to short-circuit before any
# git/gh operations, so we only validate computation + output writing.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUMP="${SCRIPT_DIR}/../bump.sh"

PASS_FILE="$(mktemp)"; FAIL_FILE="$(mktemp)"; NAMES_FILE="$(mktemp)"
echo 0 > "$PASS_FILE"; echo 0 > "$FAIL_FILE"
trap 'rm -f "$PASS_FILE" "$FAIL_FILE" "$NAMES_FILE"' EXIT

bump_pass() { echo $(( $(cat "$PASS_FILE") + 1 )) > "$PASS_FILE"; }
bump_fail() { echo $(( $(cat "$FAIL_FILE") + 1 )) > "$FAIL_FILE"; echo "$1" >> "$NAMES_FILE"; }

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  ✓ ${name}"; bump_pass
  else
    echo "  ✗ ${name}: expected '${expected}', got '${actual}'"; bump_fail "${name}"
  fi
}

run_dry() {
  local out
  out="$(mktemp)"
  GITHUB_OUTPUT="$out" BUMP_DRY_RUN=true bash "$BUMP" >/dev/null 2>&1 || true
  cat "$out"
  rm -f "$out"
}

run_dry_capture() {
  local out err rc
  out="$(mktemp)"; err="$(mktemp)"
  GITHUB_OUTPUT="$out" BUMP_DRY_RUN=true bash "$BUMP" >/dev/null 2>"$err" && rc=$? || rc=$?
  echo "RC=${rc}"
  cat "$err"
  rm -f "$out" "$err"
}

# ── Test 1: patch bump ───────────────────────────────────────────────────────
echo "Test 1: patch bump 3.2.3 → 3.2.4"
{
  unset PUBLISHED PROPS_KEY BUMP_TYPE
  export PUBLISHED="3.2.3"
  export PROPS_KEY="kmptoolkit.version"
  export BUMP_TYPE="patch"
  out=$(run_dry)
  assert_eq "patch/next"   "next=3.2.4" "$(echo "$out" | grep '^next=')"
  assert_eq "patch/branch" "branch=chore/bump-version-3.2.4" "$(echo "$out" | grep '^branch=')"
  assert_eq "patch/skipped" "skipped=false" "$(echo "$out" | grep '^skipped=')"
}

# ── Test 2: minor bump ───────────────────────────────────────────────────────
echo "Test 2: minor bump 3.2.3 → 3.3.0"
{
  unset PUBLISHED PROPS_KEY BUMP_TYPE
  export PUBLISHED="3.2.3" PROPS_KEY="lib.version" BUMP_TYPE="minor"
  out=$(run_dry)
  assert_eq "minor/next" "next=3.3.0" "$(echo "$out" | grep '^next=')"
}

# ── Test 3: major bump ───────────────────────────────────────────────────────
echo "Test 3: major bump 3.2.3 → 4.0.0"
{
  unset PUBLISHED PROPS_KEY BUMP_TYPE
  export PUBLISHED="3.2.3" PROPS_KEY="lib.version" BUMP_TYPE="major"
  out=$(run_dry)
  assert_eq "major/next" "next=4.0.0" "$(echo "$out" | grep '^next=')"
}

# ── Test 4: leading 'v' in published ─────────────────────────────────────────
echo "Test 4: 'v3.2.3' input strips leading v"
{
  unset PUBLISHED PROPS_KEY BUMP_TYPE
  export PUBLISHED="v3.2.3" PROPS_KEY="x.version" BUMP_TYPE="patch"
  out=$(run_dry)
  assert_eq "vstripped/next" "next=3.2.4" "$(echo "$out" | grep '^next=')"
}

# ── Test 5: invalid published version → fail ─────────────────────────────────
echo "Test 5: invalid published → fail"
{
  unset PUBLISHED PROPS_KEY BUMP_TYPE
  export PUBLISHED="not-a-version" PROPS_KEY="x" BUMP_TYPE="patch"
  err_file=$(mktemp); GITHUB_OUTPUT=/dev/null BUMP_DRY_RUN=true bash "$BUMP" >/dev/null 2>"$err_file" && rc=$? || rc=$?
  assert_eq "invalid/rc" "1" "$rc"
  rm -f "$err_file"
}

# ── Test 6: missing properties-key → fail at env check ───────────────────────
echo "Test 6: missing PROPS_KEY → fail"
{
  unset PUBLISHED PROPS_KEY BUMP_TYPE
  export PUBLISHED="3.2.3" BUMP_TYPE="patch"
  err_file=$(mktemp); GITHUB_OUTPUT=/dev/null BUMP_DRY_RUN=true bash "$BUMP" >/dev/null 2>"$err_file" && rc=$? || rc=$?
  assert_eq "no-key/rc" "1" "$rc"
  rm -f "$err_file"
}

# ── Test 7: PR title template substitution ───────────────────────────────────
echo "Test 7: PR title placeholders substitute correctly"
{
  unset PUBLISHED PROPS_KEY BUMP_TYPE PR_TITLE_TPL
  export PUBLISHED="3.2.3" PROPS_KEY="kmptoolkit.version" BUMP_TYPE="patch"
  export PR_TITLE_TPL="Bump {key}: {published} → {next}"
  log=$(BUMP_DRY_RUN=true bash "$BUMP" 2>&1 | grep "PR title")
  assert_eq "title/sub" "PR title: Bump kmptoolkit.version: 3.2.3 → 3.2.4" "$log"
}

# ── Test 8: pre-release patch bump — alpha.0 -> alpha.1 (v2.2 bug fix) ──────
echo "Test 8: pre-release patch 2.2.0-alpha.0 -> 2.2.0-alpha.1"
{
  unset PUBLISHED PROPS_KEY BUMP_TYPE
  export PUBLISHED="2.2.0-alpha.0" PROPS_KEY="kmpflavors.version" BUMP_TYPE="patch"
  out=$(run_dry)
  assert_eq "alpha-patch/next"   "next=2.2.0-alpha.1" "$(echo "$out" | grep '^next=')"
  assert_eq "alpha-patch/branch" "branch=chore/bump-version-2.2.0-alpha.1" "$(echo "$out" | grep '^branch=')"
}

# ── Test 9: pre-release patch bump — rc.5 -> rc.6 ─────────────────────────────
echo "Test 9: pre-release patch 2.2.0-rc.5 -> 2.2.0-rc.6"
{
  unset PUBLISHED PROPS_KEY BUMP_TYPE
  export PUBLISHED="2.2.0-rc.5" PROPS_KEY="lib.version" BUMP_TYPE="patch"
  out=$(run_dry)
  assert_eq "rc-patch/next" "next=2.2.0-rc.6" "$(echo "$out" | grep '^next=')"
}

# ── Test 10: prerelease-graduate — rc.5 -> 2.2.0 (drop suffix on GA cut) ─────
echo "Test 10: prerelease-graduate 2.2.0-rc.5 -> 2.2.0"
{
  unset PUBLISHED PROPS_KEY BUMP_TYPE
  export PUBLISHED="2.2.0-rc.5" PROPS_KEY="lib.version" BUMP_TYPE="prerelease-graduate"
  out=$(run_dry)
  assert_eq "graduate/next"   "next=2.2.0" "$(echo "$out" | grep '^next=')"
  assert_eq "graduate/branch" "branch=chore/bump-version-2.2.0" "$(echo "$out" | grep '^branch=')"
}

# ── Test 11: pre-release minor bump — alpha.0 minor consumes the alpha line ─
echo "Test 11: pre-release minor 2.2.0-alpha.0 -> 2.3.0 (alpha line consumed)"
{
  unset PUBLISHED PROPS_KEY BUMP_TYPE
  export PUBLISHED="2.2.0-alpha.0" PROPS_KEY="lib.version" BUMP_TYPE="minor"
  out=$(run_dry)
  assert_eq "pre-minor/next" "next=2.3.0" "$(echo "$out" | grep '^next=')"
}

# ── Test 12: pre-release major bump — alpha.0 major -> 3.0.0 ────────────────
echo "Test 12: pre-release major 2.2.0-alpha.0 -> 3.0.0"
{
  unset PUBLISHED PROPS_KEY BUMP_TYPE
  export PUBLISHED="2.2.0-alpha.0" PROPS_KEY="lib.version" BUMP_TYPE="major"
  out=$(run_dry)
  assert_eq "pre-major/next" "next=3.0.0" "$(echo "$out" | grep '^next=')"
}

# ── Test 13: GA-shaped patch unchanged — historical behaviour preserved ─────
echo "Test 13: GA patch 2.2.0 -> 2.2.1 (historical behaviour preserved)"
{
  unset PUBLISHED PROPS_KEY BUMP_TYPE
  export PUBLISHED="2.2.0" PROPS_KEY="lib.version" BUMP_TYPE="patch"
  out=$(run_dry)
  assert_eq "ga-patch/next" "next=2.2.1" "$(echo "$out" | grep '^next=')"
}

# ── Test 14: unrecognised pre-release suffix falls back to strip+patch ──────
echo "Test 14: unrecognised suffix 2.2.0-snapshot.1 -> 2.2.1 (fallback)"
{
  unset PUBLISHED PROPS_KEY BUMP_TYPE
  export PUBLISHED="2.2.0-snapshot.1" PROPS_KEY="lib.version" BUMP_TYPE="patch"
  out=$(run_dry)
  assert_eq "snapshot-fallback/next" "next=2.2.1" "$(echo "$out" | grep '^next=')"
}

# ── Test 15: prerelease-graduate on GA-shaped version is a no-op fallback ───
echo "Test 15: graduate on non-pre-release 2.2.0 -> 2.2.1 (fallback)"
{
  unset PUBLISHED PROPS_KEY BUMP_TYPE
  export PUBLISHED="2.2.0" PROPS_KEY="lib.version" BUMP_TYPE="prerelease-graduate"
  out=$(run_dry)
  # graduate is meaningless without a pre-release suffix; fall through to
  # patch path (the prerelease-graduate kind is unknown to the legacy case,
  # so it lands on the patch|* default and bumps the patch component).
  assert_eq "graduate-fallback/next" "next=2.2.1" "$(echo "$out" | grep '^next=')"
}

# ── Test 16: beta line — pre-release patch beta.2 -> beta.3 ─────────────────
echo "Test 16: pre-release patch 2.2.0-beta.2 -> 2.2.0-beta.3"
{
  unset PUBLISHED PROPS_KEY BUMP_TYPE
  export PUBLISHED="2.2.0-beta.2" PROPS_KEY="lib.version" BUMP_TYPE="patch"
  out=$(run_dry)
  assert_eq "beta-patch/next" "next=2.2.0-beta.3" "$(echo "$out" | grep '^next=')"
}

# ── summary ──────────────────────────────────────────────────────────────────
echo ""
echo "──────────────────────────────────────────────"
PASS=$(cat "$PASS_FILE"); FAIL=$(cat "$FAIL_FILE")
echo "Results: ${PASS} passed, ${FAIL} failed"
if [ "$FAIL" -gt 0 ]; then
  printf "Failed tests:\n"
  while IFS= read -r n; do echo "  - ${n}"; done < "$NAMES_FILE"
  exit 1
fi
