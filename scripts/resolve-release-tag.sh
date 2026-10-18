#!/bin/bash
set -euo pipefail
: "${DT_RELEASE_TAG:?DT_RELEASE_TAG is required}"
: "${GH_REPO:?GH_REPO is required}"
if [[ ! "$DT_RELEASE_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo 'Invalid stable release tag.' >&2
  exit 1
fi
# Read the tag namespace explicitly, never an ambiguous branch-or-tag name.
dt_object="$(gh api "repos/$GH_REPO/git/ref/tags/$DT_RELEASE_TAG" --jq '.object | [.type, .sha] | @tsv')"
IFS=$'\t' read -r dt_type dt_sha <<< "$dt_object"
for ((dt_depth=0; dt_depth<16; dt_depth++)); do
  [[ "$dt_sha" =~ ^[0-9a-f]{40}$ ]] || { echo 'Invalid Git object SHA.' >&2; exit 1; }
  if [[ "$dt_type" == commit ]]; then
    if [[ -n "${DT_EXPECTED_COMMIT:-}" && "$dt_sha" != "$DT_EXPECTED_COMMIT" ]]; then
      echo 'The remote tag moved; refusing to publish a different commit.' >&2
      exit 1
    fi
    printf '%s\n' "$dt_sha"
    exit 0
  fi
  [[ "$dt_type" == tag ]] || { echo 'Release tag must resolve to a commit.' >&2; exit 1; }
  dt_object="$(gh api "repos/$GH_REPO/git/tags/$dt_sha" --jq '.object | [.type, .sha] | @tsv')"
  IFS=$'\t' read -r dt_type dt_sha <<< "$dt_object"
done
echo 'Tag nesting exceeds the supported depth.' >&2
exit 1
