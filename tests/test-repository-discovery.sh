#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
for name in zh-overview zh-limit-expanded en-overview en-limit-expanded; do
  asset="$ROOT/docs/screenshots/$name.webp"
  test -s "$asset" || { echo "Missing screenshot: $asset" >&2; exit 1; }
  # RIFF/WebP file signature. Avoid dependency on ImageMagick or PIL in CI.
  test "$(head -c 4 "$asset")" = "RIFF" || { echo "Not RIFF: $name" >&2; exit 1; }
  test "$(dd if="$asset" bs=1 skip=8 count=4 2>/dev/null)" = "WEBP" || {
    echo "Not WebP: $name" >&2; exit 1;
  }
done

for pair in 'README.md:zh-overview' 'README.md:zh-limit-expanded' 'README.en.md:en-overview' 'README.en.md:en-limit-expanded'; do
  doc="${pair%%:*}"
  shot="${pair##*:}"
  grep -Fq "docs/screenshots/$shot.webp" "$ROOT/$doc" || {
    echo "README missing screenshot: $shot" >&2; exit 1;
  }
done

for doc in README.md README.en.md; do
  grep -Fq 'releases/latest' "$ROOT/$doc"
  grep -Fq 'docs/COMPATIBILITY.md' "$ROOT/$doc"
  grep -Fq 'diagnose-mauleaf.sh' "$ROOT/$doc"
  grep -Fq 'MacBookPro18,1' "$ROOT/$doc"
  grep -Fq 'mBoot-20457.41.3' "$ROOT/$doc"
done
test -s "$ROOT/docs/REPOSITORY_DISCOVERY.md"
test -s "$ROOT/docs/COMPATIBILITY.md"
echo "Repository discovery and README screenshots: PASS"
