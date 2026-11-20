#!/usr/bin/env bash
# Run only after an official stable Release has been successfully published.
# Never remove old stable versions, open/unmerged branches or orphaned recovery code.
set -euo pipefail

: "${GH_TOKEN:?GitHub token with contents:write is required}"
: "${GITHUB_REPOSITORY:?GitHub repository context is required}"
STABLE_TAG="${1:?Provide the stable release tag}"
[[ "$STABLE_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "Refusing cleanup for non-stable tag: $STABLE_TAG" >&2
  exit 2
}

REPO="$GITHUB_REPOSITORY"
[[ "$REPO" == "MauriceLiang/MauLeaf" ]] || {
  echo "Refusing cleanup outside MauLeaf: $REPO" >&2
  exit 2
}

echo "Verifying $STABLE_TAG before deleting any preview assets or branches..."
stable_json="$(gh release view "$STABLE_TAG" --repo "$REPO" --json tagName,isPrerelease,assets)"
[[ "$(jq -r '.tagName' <<< "$stable_json")" == "$STABLE_TAG" ]] || exit 3
[[ "$(jq -r '.isPrerelease' <<< "$stable_json")" == "false" ]] || exit 3
jq -e --arg dmg "MauLeaf-${STABLE_TAG#v}-macos-arm64.dmg" \
  '.assets | any(.name == $dmg and .size > 0)' <<< "$stable_json" >/dev/null
jq -e '.assets | any(.name == "SHA256SUMS.txt" and .size > 0)' \
  <<< "$stable_json" >/dev/null

# Only previews for THIS stable version are superseded.
release_tags="$(gh api --paginate "repos/$REPO/releases?per_page=100" \
  --jq '.[] | select(.prerelease == true) | .tag_name')"
preview_removed=0
while IFS= read -r tag; do
  [[ "$tag" == "$STABLE_TAG-preview."* ]] || continue
  echo "Removing superseded preview release and tag: $tag"
  gh release delete "$tag" --repo "$REPO" --yes --cleanup-tag
  preview_removed=$((preview_removed + 1))
done <<< "$release_tags"

# Remove preview tags with no published Release (e.g. failed builds).
orphan_refs="$(gh api "repos/$REPO/git/matching-refs/tags/$STABLE_TAG-preview." \
  --jq '.[].ref')"
orphan_removed=0
while IFS= read -r ref; do
  [[ "$ref" == "refs/tags/$STABLE_TAG-preview."* ]] || continue
  echo "Removing orphan preview tag: $ref"
  gh api -X DELETE "repos/$REPO/git/refs/tags/${ref#refs/tags/}" >/dev/null
  orphan_removed=$((orphan_removed + 1))
done <<< "$orphan_refs"

# The branch must still match the exact head SHA of a merged PR. Preserve
# branches with unmerged work or commits added after a PR was merged.
merged_heads="$(gh api --paginate "repos/$REPO/pulls?state=closed&per_page=100" \
  --jq '.[] | select(.merged_at != null and .head.repo.full_name == "MauriceLiang/MauLeaf") | [.head.ref,.head.sha] | @tsv')"
branches="$(gh api --paginate "repos/$REPO/branches?per_page=100" \
  --jq '.[] | [.name,.commit.sha] | @tsv')"
branch_removed=0
branch_kept=0
while IFS=$'\t' read -r name sha; do
  [[ -n "$name" && -n "$sha" ]] || continue
  [[ "$name" != "main" ]] || continue
  if awk -F $'\t' -v branch="$name" -v sha="$sha" \
       '$1 == branch && $2 == sha { found = 1 } END { exit !found }' <<< "$merged_heads"; then
    echo "Removing merged, unchanged branch: $name"
    gh api -X DELETE "repos/$REPO/git/refs/heads/$name" >/dev/null
    branch_removed=$((branch_removed + 1))
  else
    echo "Preserving branch with unmerged or changed work: $name"
    branch_kept=$((branch_kept + 1))
  fi
done <<< "$branches"

echo "Cleanup completed. Preview releases: $preview_removed; orphan tags: $orphan_removed; merged branches: $branch_removed; preserved non-main branches: $branch_kept."
