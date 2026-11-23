#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# The README showcases the four real v1.0 screenshots, organized by
# interface language and expanded/collapsed Power Flow modes.
screenshots=(
  zh-power-compact
  zh-power-flow
  en-power-flow
  en-power-compact
)
for name in "${screenshots[@]}"; do
  asset="$ROOT/docs/screenshots/$name.webp"
  test -s "$asset" || { echo "Missing screenshot: $asset" >&2; exit 1; }
  # RIFF/WebP signature: no ImageMagick or Python dependencies in CI.
  test "$(head -c 4 "$asset")" = "RIFF" || { echo "Not RIFF: $name" >&2; exit 1; }
  test "$(dd if="$asset" bs=1 skip=8 count=4 2>/dev/null)" = "WEBP" || {
    echo "Not WebP: $name" >&2; exit 1;
  }
done

for doc in README.md README.en.md; do
  for shot in "${screenshots[@]}"; do
    [[ "$(grep -Fc "](docs/screenshots/$shot.webp)" "$ROOT/$doc")" -eq 1 ]] || {
      echo "$doc must show $shot exactly once" >&2; exit 1;
    }
  done
  if grep -Eq 'docs/screenshots/(zh|en)-(overview|limit-expanded)\.webp' "$ROOT/$doc"; then
    echo "$doc still references obsolete preview screenshots" >&2
    exit 1
  fi
done

for doc in README.md README.en.md; do
  grep -Fq 'releases/latest' "$ROOT/$doc"
  grep -Fq 'docs/COMPATIBILITY.md' "$ROOT/$doc"
  grep -Fq 'diagnose-mauleaf.sh' "$ROOT/$doc"
  grep -Fq 'MacBookPro18,1' "$ROOT/$doc"
  grep -Fq 'mBoot-20457.41.3' "$ROOT/$doc"
done
# Guidance must remain optional and correctly reflected in both languages.
grep -Fq '### 与 macOS「优化电池充电」一起使用' "$ROOT/README.md"
grep -Fq 'MauLeaf 不会自动修改该系统开关' "$ROOT/README.md"
grep -Fq '### Using MauLeaf with macOS Optimized Battery Charging' "$ROOT/README.en.md"
grep -Fq 'MauLeaf never changes that macOS setting automatically' "$ROOT/README.en.md"
test -s "$ROOT/docs/REPOSITORY_DISCOVERY.md"
test -s "$ROOT/docs/COMPATIBILITY.md"
echo "Repository discovery and README screenshots: PASS"
