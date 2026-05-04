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
