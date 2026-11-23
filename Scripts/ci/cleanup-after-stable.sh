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

# Only remove preview tags explicitly superseded by this verified stable
# release. The 1.0.0 milestone also absorbs the 0.8.1 and 0.9.1 preview
# sequences; preserve all previously published stable releases and their tags.
preview_prefixes=("$STABLE_TAG-preview.")
if [[ "$STABLE_TAG" == "v1.0.0" ]]; then
  preview_prefixes+=("v0.8.1-preview." "v0.9.1-preview.")
fi
superseded_preview() {
  local tag="$1" prefix
  [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-preview\.[0-9]+$ ]] || return 1
  for prefix in "${preview_prefixes[@]}"; do
    [[ "$tag" == "$prefix"* ]] && return 0
  done
  return 1
}

release_tags="$(gh api --paginate "repos/$REPO/releases?per_page=100" \
  --jq '.[] | select(.prerelease == true) | .tag_name')"
preview_removed=0
while IFS= read -r tag; do
  superseded_preview "$tag" || continue
  echo "Removing superseded preview Release and tag: $tag"
  gh release delete "$tag" --repo "$REPO" --yes --cleanup-tag
  preview_removed=$((preview_removed + 1))
done <<< "$release_tags"

# Remove matching orphan preview tags with no published Release.
orphan_removed=0
for prefix in "${preview_prefixes[@]}"; do
  orphan_refs="$(gh api "repos/$REPO/git/matching-refs/tags/$prefix" --jq '.[].ref')"
  while IFS= read -r ref; do
    [[ "$ref" == refs/tags/* ]] || continue
    superseded_preview "${ref#refs/tags/}" || continue
    echo "Removing orphan preview tag: $ref"
    gh api -X DELETE "repos/$REPO/git/refs/tags/${ref#refs/tags/}" >/dev/null
    orphan_removed=$((orphan_removed + 1))
  done <<< "$orphan_refs"
done

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
  elif [[ "$STABLE_TAG" == "v1.0.0" &&
          "$name" == "diagnostics/power-source-transition" &&
          "$sha" == "b914abdd9c437d56f3621a13e7455b19b54d070c" ]]; then
    # Closed diagnostic PR #44 is preserved in GitHub history and issue #53.
    [[ "$(gh api "repos/$REPO/pulls/44" --jq '.state')" == "closed" ]] || exit 5
    [[ "$(gh api "repos/$REPO/pulls/44" --jq '.merged')" == "false" ]] || exit 5
    [[ "$(gh api "repos/$REPO/pulls/44" --jq '.head.sha')" == "$sha" ]] || exit 5
    [[ "$(gh api "repos/$REPO/issues/53" --jq '.state')" == "open" ]] || exit 5
    echo "Removing superseded diagnostic branch from closed PR #44; issue #53 tracks follow-up"
    gh api -X DELETE "repos/$REPO/git/refs/heads/$name" >/dev/null
    branch_removed=$((branch_removed + 1))
  else
    echo "Preserving branch with unmerged or changed work: $name"
    branch_kept=$((branch_kept + 1))
  fi
done <<< "$branches"

echo "Cleanup completed. Preview releases: $preview_removed; orphan tags: $orphan_removed; merged branches: $branch_removed; preserved non-main branches: $branch_kept."
