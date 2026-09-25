#!/usr/bin/env bash
# Add the shared CI pipeline to a repository.
#
# Usage: scripts/add-to-repo.sh <path-to-repo> [options]
#
# Options:
#   --dir <folder>   Project folder inside the repo (where package.json,
#                    pyproject.toml or Gemfile lives). Default: repo root.
#   --type <type>    node, python or ruby. Detected automatically if omitted.
#   --force          Overwrite existing .github/workflows/ci.yml and
#                    .github/dependabot.yml.
#
# Example: scripts/add-to-repo.sh ../Directors-notes --dir app
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
templates="$here/../templates"

usage() {
  sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

repo=""
dir="."
type=""
force=false
while [ $# -gt 0 ]; do
  case "$1" in
    --dir) dir="$2"; shift 2 ;;
    --type) type="$2"; shift 2 ;;
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

if [ -z "$type" ]; then
  if [ -f "$project/package.json" ]; then
    type=node
  elif [ -f "$project/pyproject.toml" ] || [ -f "$project/requirements.txt" ] || [ -f "$project/setup.py" ]; then
    type=python
  elif [ -f "$project/Gemfile" ]; then
    type=ruby
  else
    echo "Could not detect the project type in $project; pass --type node|python|ruby" >&2
    exit 1
  fi
fi

case "$type" in
  node) template=ci-node.yml; ecosystem=npm; languages='["javascript-typescript", "actions"]' ;;
  python) template=ci-security-only.yml; ecosystem=pip; languages='["python", "actions"]' ;;
  ruby) template=ci-security-only.yml; ecosystem=bundler; languages='["ruby", "actions"]' ;;
  *) echo "Unsupported type: $type (expected node, python or ruby)" >&2; exit 1 ;;
esac

dependabot_dir="/"
[ "$dir" = "." ] || dependabot_dir="/$dir"

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
    "$src" >"$dest"
  echo "  write  $2"
}

echo "Adding $type CI to $repo (project folder: $dir)"
write "$template" .github/workflows/ci.yml
write dependabot.yml .github/dependabot.yml

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
