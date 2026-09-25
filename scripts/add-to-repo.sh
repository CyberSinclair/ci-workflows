#!/usr/bin/env bash
# Add the shared CI pipeline to a repository.
#
# Usage: scripts/add-to-repo.sh <path-to-repo> [options]
#
# Options:
#   --dir <folder>   Project folder inside the repo (where package.json,
#                    pxt.json, pyproject.toml or Gemfile lives). Default: root.
#   --type <type>    node, makecode, python or ruby. Detected if omitted.
#   --ref <tag>      Release of ci-workflows to use, e.g. v1.2.0.
#                    Default: the latest vX.Y.Z tag.
#   --force          Overwrite existing .github/workflows/ci.yml and
#                    .github/dependabot.yml.
#
# The generated ci.yml pins the shared workflows to the release's commit
# hash; Dependabot then opens PRs when newer releases are published.
#
# Example: scripts/add-to-repo.sh ../Directors-notes --dir app
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$here/.."
templates="$root/templates"

usage() {
  sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

repo=""
dir="."
type=""
ref=""
force=false
while [ $# -gt 0 ]; do
  case "$1" in
    --dir) dir="$2"; shift 2 ;;
    --type) type="$2"; shift 2 ;;
    --ref) ref="$2"; shift 2 ;;
    --force) force=true; shift ;;
    -h | --help) usage ;;
    -*) echo "Unknown option: $1" >&2; usage 1 ;;
    *) repo="$1"; shift ;;
  esac
done

[ -n "$repo" ] || usage 1
[ -d "$repo/.git" ] || { echo "Not a git repository: $repo" >&2; exit 1; }

# Normalise "./app/" to "app".
dir="${dir#./}"
dir="${dir%/}"
[ -n "$dir" ] || dir="."
project="$repo/$dir"
[ -d "$project" ] || { echo "Folder not found: $project" >&2; exit 1; }

# Files tracked in the project folder (ignores node_modules and other ignored files).
files="$(git -C "$project" ls-files)"
has_file() { grep -Eq "$1" <<<"$files"; }

if [ -z "$type" ]; then
  # pxt.json first: MakeCode projects also ship a Gemfile for GitHub Pages.
  if [ -f "$project/pxt.json" ]; then
    type=makecode
  elif [ -f "$project/package.json" ]; then
    type=node
  elif has_file '\.py$'; then
    type=python
  elif [ -f "$project/Gemfile" ]; then
    type=ruby
  else
    echo "Could not detect the project type in $project; pass --type node|makecode|python|ruby" >&2
    exit 1
  fi
fi

case "$type" in
  node) template=ci-node.yml; ecosystem=npm ;;
  makecode) template=ci-makecode.yml; ecosystem="" ;;
  python)
    template=ci-security-only.yml
    ecosystem=""
    if [ -f "$project/requirements.txt" ] || [ -f "$project/pyproject.toml" ] || [ -f "$project/setup.py" ]; then
      ecosystem=pip
    fi
    ;;
  ruby) template=ci-security-only.yml; ecosystem=bundler ;;
  *) echo "Unsupported type: $type (expected node, makecode, python or ruby)" >&2; exit 1 ;;
esac

# CodeQL fails when asked to scan a language with no source files, so only
# list languages the repo actually contains. The ci.yml added here is
# always scanned as "actions".
all_files="$(git -C "$repo" ls-files)"
languages='"actions"'
grep -Eq '\.(js|jsx|mjs|cjs|ts|tsx)$' <<<"$all_files" && languages="\"javascript-typescript\", $languages"
grep -Eq '\.py$' <<<"$all_files" && languages="\"python\", $languages"
grep -Eq '\.rb$' <<<"$all_files" && languages="\"ruby\", $languages"
languages="[$languages]"

# The repo's default branch, for the push trigger (main, master, ...).
branch="$(git -C "$repo" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
branch="${branch#origin/}"
[ -n "$branch" ] || branch="$(git -C "$repo" branch --show-current)"
[ -n "$branch" ] || branch=main

dependabot_dir="/"
[ "$dir" = "." ] || dependabot_dir="/$dir"

# Pin to a release's commit hash: a tag can be moved, a commit can't.
git -C "$root" fetch --tags --quiet 2>/dev/null || true
if [ -z "$ref" ]; then
  ref="$(git -C "$root" tag --list 'v*.*.*' --sort=-v:refname | head -n 1)"
  [ -n "$ref" ] || { echo "No vX.Y.Z release tag found in ci-workflows; pass --ref" >&2; exit 1; }
fi
sha="$(git -C "$root" rev-list -n 1 "$ref" 2>/dev/null)" ||
  { echo "Unknown ci-workflows release: $ref" >&2; exit 1; }

# write <template> <path in repo>
write() {
  local src="$templates/$1" dest="$repo/$2"
  if [ -e "$dest" ] && [ "$force" != true ]; then
    echo "  skip   $2 (already exists; use --force to overwrite)"
    return
  fi
  mkdir -p "$(dirname "$dest")"
  sed -e "s|__WORKING_DIRECTORY__|$dir|g" \
    -e "s|__CODEQL_LANGUAGES__|$languages|g" \
    -e "s|__ECOSYSTEM__|$ecosystem|g" \
    -e "s|__DEPENDABOT_DIRECTORY__|$dependabot_dir|g" \
    -e "s|__DEFAULT_BRANCH__|$branch|g" \
    -e "s|__CI_WORKFLOWS_SHA__|$sha|g" \
    -e "s|__CI_WORKFLOWS_VERSION__|$ref|g" \
    "$src" >"$dest"
  echo "  write  $2"
}

echo "Adding $type CI to $repo"
echo "  folder: $dir, branch: $branch, CodeQL: $languages, ci-workflows: $ref (${sha:0:7})"
write "$template" .github/workflows/ci.yml
if [ -n "$ecosystem" ]; then
  write dependabot.yml .github/dependabot.yml
else
  write dependabot-actions-only.yml .github/dependabot.yml
fi

if [ "$type" = node ]; then
  echo
  echo "Standard npm scripts (the pipeline runs whichever exist):"
  for script in lint test:unit test:integration test:regression build test:e2e; do
    if node -e "process.exit(require(process.argv[1]).scripts?.['$script'] ? 0 : 1)" "$(cd "$project" && pwd)/package.json" 2>/dev/null; then
      echo "  found    $script"
    else
      echo "  missing  $script"
    fi
  done
fi

echo
echo "Next: commit the new files, push, and follow 'Make the checks required' in the README."
