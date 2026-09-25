#!/usr/bin/env bash
# Create or update a "Protect default branch" ruleset that requires the
# repository's CI checks to pass before a pull request can merge.
#
# Usage: scripts/protect-branch.sh <owner/repo> [options]
#
# Options:
#   --pr <number>   Take the check names from this pull request.
#                   Default: the latest CI run on the default branch.
#   --workflow <f>  Workflow file for the default-branch lookup.
#                   Default: ci.yml
#   --dry-run       Print the ruleset instead of applying it.
#
# The ruleset applies to the default branch and:
#   - requires changes to go through a pull request (0 approvals, so you
#     can merge your own);
#   - requires every job in the CI run to pass (skipped jobs count as passed);
#   - when CodeQL runs, blocks new high-severity code scanning alerts;
#   - blocks force-pushes and deleting the branch.
#
# Needs the GitHub CLI (gh), logged in as a repo admin, and Node.js.
# Re-run it after adding checks to a repo's CI to update the ruleset.
#
# Example: scripts/protect-branch.sh CyberSinclair/Directors-notes
set -euo pipefail

RULESET_NAME="Protect default branch"
GITHUB_ACTIONS_APP_ID=15368 # Only accept check results reported by GitHub Actions.

usage() {
  sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

repo=""
pr=""
workflow="ci.yml"
dry_run=false
while [ $# -gt 0 ]; do
  case "$1" in
    --pr) pr="$2"; shift 2 ;;
    --workflow) workflow="$2"; shift 2 ;;
    --dry-run) dry_run=true; shift ;;
    -h | --help) usage ;;
    -*) echo "Unknown option: $1" >&2; usage 1 ;;
    *) repo="$1"; shift ;;
  esac
done

[[ "$repo" == */* ]] || usage 1

# gh isn't on Git Bash's PATH straight after installing it on Windows.
gh="${GH:-$(command -v gh || true)}"
[ -n "$gh" ] || [ ! -x "/c/Program Files/GitHub CLI/gh.exe" ] || gh="/c/Program Files/GitHub CLI/gh.exe"
[ -n "$gh" ] || { echo "GitHub CLI (gh) not found; install it or set GH=/path/to/gh" >&2; exit 1; }

if [ -n "$pr" ]; then
  checks="$("$gh" pr checks "$pr" -R "$repo" --json name --jq '.[].name')"
  source="pull request #$pr"
else
  branch="$("$gh" repo view "$repo" --json defaultBranchRef --jq .defaultBranchRef.name)"
  run="$("$gh" run list -R "$repo" --workflow "$workflow" --branch "$branch" --status completed \
    -L 1 --json databaseId --jq '.[0].databaseId // empty' 2>/dev/null || true)"
  [ -n "$run" ] || {
    echo "No completed $workflow run on $branch in $repo. Merge the CI first, or pass --pr <number>." >&2
    exit 1
  }
  checks="$("$gh" run view "$run" -R "$repo" --json jobs --jq '.jobs[].name')"
  source="$workflow run $run on $branch"
fi

# "CodeQL" is code scanning's own summary check (covered by the code scanning
# rule), and "Detect project scripts" only feeds other jobs.
checks="$(grep -v -x -e 'CodeQL' -e '.*Detect project scripts' <<<"$checks" | sort -u || true)"
[ -n "$checks" ] || { echo "No checks found in $source" >&2; exit 1; }

code_scanning=false
grep -q 'CodeQL (' <<<"$checks" && code_scanning=true

ruleset="$(node -e '
  const [name, appId, codeScanning, checks] = process.argv.slice(1);
  const rules = [
    { type: "deletion" },
    { type: "non_fast_forward" },
    { type: "pull_request", parameters: {
        required_approving_review_count: 0,
        dismiss_stale_reviews_on_push: false,
        require_code_owner_review: false,
        require_last_push_approval: false,
        required_review_thread_resolution: false } },
    { type: "required_status_checks", parameters: {
        strict_required_status_checks_policy: false,
        required_status_checks: checks.split("\n").map((context) => ({
          context, integration_id: Number(appId) })) } },
  ];
  if (codeScanning === "true") {
    rules.push({ type: "code_scanning", parameters: { code_scanning_tools: [{
      tool: "CodeQL", security_alerts_threshold: "high_or_higher", alerts_threshold: "errors" }] } });
  }
  console.log(JSON.stringify({
    name, target: "branch", enforcement: "active", bypass_actors: [],
    conditions: { ref_name: { include: ["~DEFAULT_BRANCH"], exclude: [] } },
    rules }, null, 2));
' "$RULESET_NAME" "$GITHUB_ACTIONS_APP_ID" "$code_scanning" "$checks")"

echo "Required checks for $repo (from $source):"
while IFS= read -r check; do echo "  - $check"; done <<<"$checks"
echo "Code scanning rule: $code_scanning"

if [ "$dry_run" = true ]; then
  echo
  echo "$ruleset"
  exit 0
fi

existing="$("$gh" api "repos/$repo/rulesets" --jq ".[] | select(.name == \"$RULESET_NAME\") | .id")"
if [ -n "$existing" ]; then
  "$gh" api -X PUT "repos/$repo/rulesets/$existing" --input - --silent <<<"$ruleset"
  echo "Updated ruleset $existing."
else
  id="$("$gh" api -X POST "repos/$repo/rulesets" --input - --jq .id <<<"$ruleset")"
  echo "Created ruleset $id."
fi
