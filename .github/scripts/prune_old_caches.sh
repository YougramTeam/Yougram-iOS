#!/bin/bash
# Delete the Bazel cache entries this run superseded, but only once all of this run's
# shards are confirmed saved: actions/cache/save only warns when an upload fails.
#
# usage: prune_old_caches.sh <key prefix> <this run's key suffix> <shard count>
set -euo pipefail

prefix="$1"
suffix="$2"
shards="$3"

keys="$(gh cache list --repo "$GITHUB_REPOSITORY" --ref "$GITHUB_REF" --key "$prefix" --limit 200 --json id,key \
  --jq '.[] | "\(.id) \(.key)"')"

saved="$(printf '%s\n' "$keys" | awk -v s="-$suffix" 'length($2) >= length(s) && substr($2, length($2) - length(s) + 1) == s' | wc -l | tr -d ' ')"
if [ "$saved" -ne "$shards" ]; then
  echo "Only $saved of $shards cache shards from this run are stored; keeping the older entries."
  exit 0
fi

printf '%s\n' "$keys" | awk -v s="-$suffix" 'NF == 2 && !(length($2) >= length(s) && substr($2, length($2) - length(s) + 1) == s) { print $1 }' |
while read -r id; do
  if gh cache delete "$id" --repo "$GITHUB_REPOSITORY"; then
    echo "Deleted superseded cache entry $id"
  else
    echo "::warning::Could not delete cache entry $id; GitHub evicts it once the cache is over its limit."
  fi
done
