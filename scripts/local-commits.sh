#!/usr/bin/env bash
# Enumerate git repos one level under each directory and list commits authored
# by the repo's own configured identity since the given epoch.
# Usage: local-commits.sh <sinceEpochSeconds> <dir...>
# Output: one line per commit, tab-separated: sha, epoch, subject, repo path.
set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "usage: local-commits.sh <sinceEpochSeconds> <dir...>" >&2
  exit 1
fi

since="$1"
shift

for dir in "$@"; do
  [ -d "$dir" ] || continue
  for child in "$dir"/*; do
    [ -e "$child/.git" ] || continue
    # Repos without a configured identity have no "own commits" to report.
    email="$(git -C "$child" config user.email 2>/dev/null || true)"
    [ -n "$email" ] || continue
    # A broken or unreadable repo must never fail the whole scan.
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      printf '%s\t%s\n' "$line" "$(cd "$child" && pwd)"
    done < <(git -C "$child" log --all --no-merges --since="@$since" \
      --author="$email" --max-count=500 --pretty=tformat:'%H%x09%ct%x09%s' 2>/dev/null || true)
  done
done
