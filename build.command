#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
  echo "MauLeaf Preview 5 本地构建仅支持 Apple Silicon Mac（arm64）。" >&2
  exit 2
fi

VERSION="$(/usr/bin/tr -d '[:space:]' < VERSION)"
if [[ ! "$VERSION" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
  echo "VERSION 文件必须是语义版本号，例如 0.8.0。" >&2
  exit 2
fi

MAJOR="${BASH_REMATCH[1]}"
MINOR="${BASH_REMATCH[2]}"
PATCH="${BASH_REMATCH[3]}"
BUILD_NUMBER=$((10#$MAJOR * 1000000 + 10#$MINOR * 1000 + 10#$PATCH))

export RELEASE_VERSION="$VERSION"
export RELEASE_LABEL="$VERSION"
export BUILD_NUMBER
export TARGET_ARCH="arm64"
export RUNNER_TEMP="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"

echo "Building MauLeaf $VERSION for Apple Silicon arm64..."
bash Scripts/ci/package-macos.sh
echo "Build complete: $ROOT/dist/MauLeaf-$VERSION-macos-arm64.dmg"
