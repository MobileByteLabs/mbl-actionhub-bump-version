#!/usr/bin/env bash
# bump.sh — compute next version, edit properties file, open PR, optionally auto-merge
#
# Required env (set by action.yml or tests):
#   PUBLISHED, PROPS_PATH, PROPS_KEY, BUMP_TYPE, BASE_BRANCH, BRANCH_PREFIX,
#   PR_TITLE_TPL, AUTO_MERGE, DELETE_BRANCH, GIT_USER_NAME, GIT_USER_EMAIL,
#   INPUT_TOKEN, DEFAULT_TOKEN
# Optional (test mode):
#   GITHUB_OUTPUT, BUMP_DRY_RUN, BUMP_TEST_GITHUB_REPOSITORY, BUMP_TEST_GITHUB_REF_NAME

set -euo pipefail

: "${PUBLISHED:?required}"
: "${PROPS_PATH:=gradle.properties}"
: "${PROPS_KEY:?required}"
: "${BUMP_TYPE:=patch}"
: "${BASE_BRANCH:=}"
: "${BRANCH_PREFIX:=chore/bump-version}"
: "${PR_TITLE_TPL:=chore(version): bump {key} to {next} (post-release)}"
: "${AUTO_MERGE:=true}"
: "${DELETE_BRANCH:=true}"
: "${GIT_USER_NAME:=github-actions[bot]}"
: "${GIT_USER_EMAIL:=41898282+github-actions[bot]@users.noreply.github.com}"
: "${INPUT_TOKEN:=}"
: "${DEFAULT_TOKEN:=}"
: "${GITHUB_OUTPUT:=/dev/null}"
: "${BUMP_DRY_RUN:=false}"

TOKEN="${INPUT_TOKEN:-$DEFAULT_TOKEN}"
REPO="${BUMP_TEST_GITHUB_REPOSITORY:-${GITHUB_REPOSITORY:-}}"
REF_NAME="${BUMP_TEST_GITHUB_REF_NAME:-${GITHUB_REF_NAME:-}}"
BASE="${BASE_BRANCH:-$REF_NAME}"

# ── helpers ─────────────────────────────────────────────────────────────────

# Accepts SemVer 2.0.0 (X.Y.Z, optionally followed by -pre.release identifiers
# and/or +build.metadata) per https://semver.org/spec/v2.0.0.html#backus-naur-form-grammar.
is_semver() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$ ]]; }

# Strip pre-release + build metadata: 2.0.0-alpha.1+build.5 -> 2.0.0
strip_prerelease() { echo "${1%%[-+]*}"; }

# Recognised SemVer pre-release suffixes (period-separated counter form):
# -alpha.N, -beta.N, -rc.N. Other suffixes (-snapshot.1, -pre.1, ...) fall
# through to the historical strip-and-patch-bump path (documented in README).
PRERELEASE_REGEX='^([0-9]+\.[0-9]+\.[0-9]+)-(alpha|beta|rc)\.([0-9]+)$'

# Sets bash globals PRE_BASE, PRE_KIND, PRE_NUM when the input has a recognised
# pre-release suffix; returns 0. Returns 1 (and leaves globals empty) otherwise.
parse_prerelease() {
  PRE_BASE=""; PRE_KIND=""; PRE_NUM=""
  if [[ "$1" =~ $PRERELEASE_REGEX ]]; then
    PRE_BASE="${BASH_REMATCH[1]}"
    PRE_KIND="${BASH_REMATCH[2]}"
    PRE_NUM="${BASH_REMATCH[3]}"
    return 0
  fi
  return 1
}

bump_semver() {
  local input="$1"
  local kind="$2"

  # Pre-release-aware path — detect -alpha.N / -beta.N / -rc.N + branch on kind.
  # See README "Pre-release-aware bumping" for the full matrix.
  if parse_prerelease "$input"; then
    case "$kind" in
      # Continue the same pre-release line: alpha.N -> alpha.N+1, etc.
      # Triggered for the default 'patch' bump-type on a pre-release input so
      # the v2.x alpha/beta/rc cycle continues correctly across publishes.
      patch)
        echo "${PRE_BASE}-${PRE_KIND}.$((PRE_NUM + 1))"
        return
        ;;
      # Graduate the pre-release into the GA-shaped version it prefigured:
      # 2.2.0-rc.5 -> 2.2.0. Cut the final GA publish from the last rc by
      # setting next-bump-type to this value on the publish workflow.
      prerelease-graduate)
        echo "${PRE_BASE}"
        return
        ;;
      # major / minor on a pre-release strip the suffix + bump as if the
      # current GA-shaped version were PRE_BASE. So 2.2.0-alpha.5 minor
      # -> 2.3.0 (the alpha line is consumed by the new minor cut).
      major|minor)
        ;;
      *)
        # Unknown bump-type -> fall through to the historical patch-bump path
        # below for backwards-compatibility with consumers that pass exotic
        # kind values.
        ;;
    esac
  fi

  # No recognised pre-release suffix OR major/minor on a pre-release ->
  # historical "strip + integer bump" path (unchanged from v1.x consumers).
  local v
  v="$(strip_prerelease "$input")"
  local major minor patch
  IFS=. read -r major minor patch <<<"$v"
  case "$kind" in
    major) echo "$((major + 1)).0.0" ;;
    minor) echo "${major}.$((minor + 1)).0" ;;
    patch|*) echo "${major}.${minor}.$((patch + 1))" ;;
  esac
}

# ── 1. validate + compute next ──────────────────────────────────────────────

PUB="${PUBLISHED#v}"
if ! is_semver "$PUB"; then
  echo "::error::published-version '${PUBLISHED}' is not valid SemVer 2.0.0 (X.Y.Z or X.Y.Z-pre.release[+build])"
  exit 1
fi

NEXT=$(bump_semver "$PUB" "$BUMP_TYPE")
BRANCH="${BRANCH_PREFIX}-${NEXT}"
PR_TITLE="${PR_TITLE_TPL//\{key\}/$PROPS_KEY}"
PR_TITLE="${PR_TITLE//\{next\}/$NEXT}"
PR_TITLE="${PR_TITLE//\{published\}/$PUB}"

echo "Computed: ${PUB} → ${NEXT} (${BUMP_TYPE})"
echo "Branch:   ${BRANCH}"
echo "Base:     ${BASE}"
echo "PR title: ${PR_TITLE}"

{
  echo "next=${NEXT}"
  echo "branch=${BRANCH}"
} >> "$GITHUB_OUTPUT"

# ── 2. dry-run short-circuit (used by tests) ────────────────────────────────

if [ "${BUMP_DRY_RUN}" = "true" ]; then
  {
    echo "skipped=false"
    echo "pr_url="
    echo "pr_number="
  } >> "$GITHUB_OUTPUT"
  echo "DRY RUN — exiting before any git/gh operations."
  exit 0
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "::error::gh CLI is required but not installed on this runner"
  exit 1
fi

if [ -z "$TOKEN" ]; then
  echo "::error::no token available (neither inputs.github-token nor github.token)"
  exit 1
fi

if [ -z "$REPO" ] || [ -z "$BASE" ]; then
  echo "::error::cannot determine repo or base branch (REPO='${REPO}', BASE='${BASE}')"
  exit 1
fi

if [ ! -f "$PROPS_PATH" ]; then
  echo "::error::properties file not found at ${PROPS_PATH}"
  exit 1
fi

if ! grep -qE "^[[:space:]]*${PROPS_KEY}[[:space:]]*=" "$PROPS_PATH"; then
  echo "::error::key '${PROPS_KEY}' not found in ${PROPS_PATH}"
  exit 1
fi

# ── 3. skip if branch already exists on origin ──────────────────────────────

if git ls-remote --exit-code --heads origin "$BRANCH" >/dev/null 2>&1; then
  echo "::warning::Branch ${BRANCH} already exists on origin — skipping."
  {
    echo "skipped=true"
    echo "pr_url="
    echo "pr_number="
  } >> "$GITHUB_OUTPUT"
  exit 0
fi

# ── 4. update file ──────────────────────────────────────────────────────────

# Use a python one-liner to avoid sed delim issues with dotted keys.
python3 - "$PROPS_PATH" "$PROPS_KEY" "$NEXT" <<'PY'
import re, sys, pathlib
path, key, new = sys.argv[1], sys.argv[2], sys.argv[3]
p = pathlib.Path(path)
text = p.read_text()
pattern = re.compile(rf'^([ \t]*{re.escape(key)}[ \t]*=).*$', re.M)
if not pattern.search(text):
    sys.stderr.write(f"::error::key '{key}' not found in {path}\n")
    sys.exit(1)
new_text = pattern.sub(rf'\g<1>{new}', text, count=1)
p.write_text(new_text)
PY

echo "── diff ──"
git --no-pager diff "$PROPS_PATH" || true

# ── 5. branch + commit + push ───────────────────────────────────────────────

git config user.name  "$GIT_USER_NAME"
git config user.email "$GIT_USER_EMAIL"
git switch -c "$BRANCH"
git add "$PROPS_PATH"

COMMIT_MSG="chore(version): bump ${PROPS_KEY} to ${NEXT} after release of ${PUB}

Auto-opened by mbl-actionhub-bump-version. Sets ${PROPS_KEY}=${NEXT}
so the next release run has a valid sanity-check value
(${NEXT} > ${PUB} on Maven Central)."
git commit -m "$COMMIT_MSG"

# Push using the provided token explicitly (don't rely on stored credentials).
PUSH_URL="https://x-access-token:${TOKEN}@github.com/${REPO}.git"
git push "$PUSH_URL" "HEAD:refs/heads/${BRANCH}"

# ── 6. open PR + best-effort auto-merge ─────────────────────────────────────

PR_BODY="Auto-opened by [mbl-actionhub-bump-version](https://github.com/MobileByteLabs/mbl-actionhub-bump-version) after a successful release of \`v${PUB}\`.

- **Bump type:** \`${BUMP_TYPE}\`
- **From:** \`${PUB}\` (just published)
- **To:** \`${NEXT}\` (next release target)
- **File:** \`${PROPS_PATH}\` → \`${PROPS_KEY}=${NEXT}\`

Sets the next sanity-check value so the next publish run can proceed (\`${NEXT} > ${PUB}\` on Maven Central).

If you want a different bump type (minor/major) for the next cycle, close this PR and bump manually."

export GH_TOKEN="$TOKEN"
PR_URL=$(gh pr create \
  --repo "$REPO" \
  --base "$BASE" \
  --head "$BRANCH" \
  --title "$PR_TITLE" \
  --body "$PR_BODY")

echo "Opened: ${PR_URL}"
PR_NUMBER="${PR_URL##*/}"

if [ "$AUTO_MERGE" = "true" ]; then
  MERGE_ARGS=(--auto --squash)
  if [ "$DELETE_BRANCH" = "true" ]; then
    MERGE_ARGS+=(--delete-branch)
  fi
  if ! gh pr merge "$PR_URL" "${MERGE_ARGS[@]}" 2>&1 | tee /tmp/gh-merge.log; then
    echo "::warning::Could not enable auto-merge on ${PR_URL} — likely repo setting or branch protection. PR stays open for human action."
  fi
fi

{
  echo "skipped=false"
  echo "pr_url=${PR_URL}"
  echo "pr_number=${PR_NUMBER}"
} >> "$GITHUB_OUTPUT"
