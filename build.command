#!/bin/bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT/build"
APP_VERSION="0.6.6"
APP_BUILD="19"
# Publish bundles only after their icons, metadata and signatures are complete.
APP_STAGE="$BUILD_DIR/.app-staging"
CHARGECAP_APP="$APP_STAGE/ChargeCap.app"
UNINSTALLER_APP="$APP_STAGE/Uninstall ChargeCap.app"
VENDOR_DIR="$ROOT/Vendor"
BATT_BIN="$VENDOR_DIR/batt"
BATT_VERSION_FILE="$VENDOR_DIR/batt-version"
BATT_VERSION="$(/bin/cat "$BATT_VERSION_FILE" | /usr/bin/tr -d '\r\n')"

pause_on_error() {
  local failed_status="${1:-1}"
  trap - ERR
  printf '\n构建失败（退出码 %s）。请查看上方错误信息。\n' "$failed_status" >&2
  if [[ -t 0 ]]; then
    read -r -p "按回车退出..." _ || true
  fi
  exit "$failed_status"
}
trap 'pause_on_error "$?"' ERR

if [[ "$(/usr/bin/uname -m)" != "arm64" ]]; then
  echo "当前构建脚本面向 Apple Silicon（arm64）Mac。检测到架构：$(/usr/bin/uname -m)"
  echo "请在目标 M1/M2/M3/M4 Mac 上构建，或自行扩展 Intel 构建目标。"
  exit 2
fi

if ! command -v xcrun >/dev/null 2>&1; then
  echo "未检测到 Xcode Command Line Tools。请先安装 Xcode Command Line Tools。"
  echo "可在终端运行：xcode-select --install"
  exit 3
fi

if ! command -v curl >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
  echo "构建需要 macOS 自带的 curl 和 Python 3。"
  exit 4
fi

mkdir -p "$BUILD_DIR" "$VENDOR_DIR"

# Include the applicable GNU GPL-2.0 license (batt v0.8.0 uses GPL-2.0).
# This must not be replaced by the old (incorrect) Apache license file.
# Keep the license in the archive so the build can proceed
# without reaching raw.githubusercontent.com. The batt release itself still
# needs GitHub network access unless Vendor/batt is already cached.
if ! /usr/bin/grep -q 'GNU GENERAL PUBLIC LICENSE' "$VENDOR_DIR/BATT-LICENSE.txt" 2>/dev/null; then
  echo "缺少完整上游许可证 Vendor/BATT-LICENSE.txt，已停止构建。" >&2
  exit 9
fi

if [[ ! -x "$BATT_BIN" ]]; then
  echo "未发现本地缓存的 batt，正在获取官方固定版本：$BATT_VERSION"
  TMP_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/chargecap-build.XXXXXX")"
  API_JSON="$TMP_DIR/release.json"
  META_FILE="$TMP_DIR/asset-meta.txt"
  ARCHIVE="$TMP_DIR/batt-release.tar.gz"

  if ! /usr/bin/curl --fail --location --silent --show-error --retry 2 \
    --connect-timeout 10 --max-time 90 \
    -H 'Accept: application/vnd.github+json' \
    -H 'User-Agent: ChargeCap-build' \
    "https://api.github.com/repos/charlie0129/batt/releases/tags/$BATT_VERSION" \
    -o "$API_JSON"; then
    echo "无法连接 GitHub API。可在网络正常时重试，或自行将官方 arm64 batt 放到 Vendor/batt 后重新构建。" >&2
    exit 12
  fi

  /usr/bin/python3 - "$API_JSON" "$META_FILE" <<'PY'
import json, sys
from urllib.parse import urlparse

with open(sys.argv[1], "r", encoding="utf-8") as f:
    release = json.load(f)
assets = release.get("assets", [])
candidates = [a for a in assets if "darwin" in a.get("name", "").lower()
              and "arm64" in a.get("name", "").lower()
              and a.get("name", "").lower().endswith((".tar.gz", ".tgz"))]
if len(candidates) != 1:
    raise SystemExit("官方 Release 中未能唯一确定 darwin/arm64 的 tar.gz 资产：" + ", ".join(a.get("name", "") for a in candidates))
a = candidates[0]
u = urlparse(a.get("browser_download_url", ""))
if u.scheme != "https" or u.netloc != "github.com" or not u.path.startswith("/charlie0129/batt/releases/download/"):
    raise SystemExit("Release 资产 URL 不符合预期，已中止构建")
with open(sys.argv[2], "w", encoding="utf-8") as f:
    f.write(a["name"] + "\n")
    f.write(a["browser_download_url"] + "\n")
    f.write((a.get("digest") or "") + "\n")
    checksum = next((x.get("browser_download_url", "") for x in assets
                     if any(k in x.get("name", "").lower() for k in ("checksum", "sha256"))
                     and x.get("name", "").lower().endswith((".txt", ".sum"))), "")
    f.write(checksum + "\n")
PY

  ASSET_NAME="$(/usr/bin/sed -n '1p' "$META_FILE")"
  ASSET_URL="$(/usr/bin/sed -n '2p' "$META_FILE")"
  ASSET_DIGEST="$(/usr/bin/sed -n '3p' "$META_FILE")"
  CHECKSUM_URL="$(/usr/bin/sed -n '4p' "$META_FILE")"
  echo "下载：$ASSET_NAME"
  if ! /usr/bin/curl --fail --location --silent --show-error --retry 2 --connect-timeout 10 "$ASSET_URL" -o "$ARCHIVE"; then
    echo "batt 官方发布包下载失败。请检查网络或使用已经校验的 Vendor/batt。" >&2
    exit 13
  fi

  EXPECTED_SHA=""
  if [[ "$ASSET_DIGEST" == sha256:* ]]; then
    EXPECTED_SHA="${ASSET_DIGEST#sha256:}"
  elif [[ -n "$CHECKSUM_URL" ]]; then
    CHECKSUM_FILE="$TMP_DIR/checksums.txt"
    /usr/bin/curl --fail --location --silent --show-error --retry 3 "$CHECKSUM_URL" -o "$CHECKSUM_FILE"
    EXPECTED_SHA="$(/usr/bin/python3 - "$CHECKSUM_FILE" "$ASSET_NAME" <<'PY'
import sys
name = sys.argv[2]
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    parts = line.strip().split()
    if len(parts) >= 2 and parts[-1].lstrip("*") == name and len(parts[0]) == 64:
        print(parts[0].lower())
        break
PY
)"
  fi
  if [[ -n "$EXPECTED_SHA" ]]; then
    ACTUAL_SHA="$(/usr/bin/shasum -a 256 "$ARCHIVE" | /usr/bin/awk '{print $1}')"
    EXPECTED_SHA="$(printf '%s' "$EXPECTED_SHA" | /usr/bin/tr '[:upper:]' '[:lower:]')"
    if [[ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]]; then
      echo "SHA-256 校验失败，已中止构建。"
      exit 5
    fi
    echo "SHA-256 校验通过。"
  else
    echo "警告：该 Release 未提供可识别的 SHA-256 摘要，构建继续但无法进行独立摘要校验。"
  fi

  /usr/bin/python3 - "$ARCHIVE" "$BATT_BIN" <<'PY'
import os, sys, tarfile
archive, destination = sys.argv[1:]
with tarfile.open(archive, "r:gz") as tf:
    candidates = [m for m in tf.getmembers()
                  if os.path.basename(m.name.rstrip("/")) == "batt"
                  and m.isfile() and not m.issym() and not m.islnk()]
    if len(candidates) != 1:
        raise SystemExit("归档中没有唯一的普通 batt 可执行文件")
    member = candidates[0]
    stream = tf.extractfile(member)
    if stream is None:
        raise SystemExit("无法读取 batt 二进制")
    data = stream.read()
    if not data or len(data) > 100 * 1024 * 1024:
        raise SystemExit("batt 二进制大小异常")
    with open(destination, "wb") as out:
        out.write(data)
os.chmod(destination, 0o755)
PY
  rm -rf "$TMP_DIR"
fi

if [[ ! -x "$BATT_BIN" ]]; then
  echo "Vendor/batt 不存在或不可执行。"
  exit 6
fi
if ! /usr/bin/file "$BATT_BIN" | /usr/bin/grep -q 'arm64'; then
  echo "Vendor/batt 不是可识别的 Apple Silicon arm64 可执行文件：$(/usr/bin/file "$BATT_BIN")"
  exit 7
fi

BATT_SHA="$(/usr/bin/shasum -a 256 "$BATT_BIN" | /usr/bin/awk '{print $1}')"
if [[ -f "$VENDOR_DIR/batt.sha256" ]]; then
  CACHED_SHA="$(/bin/cat "$VENDOR_DIR/batt.sha256" | /usr/bin/tr -d '\r\n')"
  if [[ "$CACHED_SHA" != "$BATT_SHA" ]]; then
    echo "Vendor/batt 与缓存 SHA-256 不一致。请检查二进制来源或删除 Vendor/batt 后重新构建。"
    exit 8
  fi
else
  printf '%s\n' "$BATT_SHA" > "$VENDOR_DIR/batt.sha256"
fi
echo "内置 batt 版本：$BATT_VERSION"
echo "内置 batt SHA-256：$BATT_SHA"

rm -rf "$CHARGECAP_APP" "$UNINSTALLER_APP"
mkdir -p "$CHARGECAP_APP/Contents/MacOS" "$CHARGECAP_APP/Contents/Resources"
mkdir -p "$UNINSTALLER_APP/Contents/MacOS" "$UNINSTALLER_APP/Contents/Resources"

cp "$BATT_BIN" "$CHARGECAP_APP/Contents/Resources/batt"
cp "$BATT_BIN" "$UNINSTALLER_APP/Contents/Resources/batt"
chmod 755 "$CHARGECAP_APP/Contents/Resources/batt" "$UNINSTALLER_APP/Contents/Resources/batt"
printf '%s\n' "$BATT_VERSION" > "$CHARGECAP_APP/Contents/Resources/batt-version.txt"
printf '%s\n' "$BATT_VERSION" > "$UNINSTALLER_APP/Contents/Resources/batt-version.txt"
printf '%s\n' "$BATT_SHA" > "$CHARGECAP_APP/Contents/Resources/batt-sha256.txt"
printf '%s\n' "$BATT_SHA" > "$UNINSTALLER_APP/Contents/Resources/batt-sha256.txt"

cat > "$CHARGECAP_APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
  <key>CFBundleExecutable</key><string>ChargeCap</string>
  <key>CFBundleIdentifier</key><string>com.local.chargecap</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>ChargeCap</string>
  <key>CFBundleIconFile</key><string>ChargeCap.icns</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
  <key>CFBundleVersion</key><string>$APP_BUILD</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST

cat > "$UNINSTALLER_APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
  <key>CFBundleExecutable</key><string>UninstallChargeCap</string>
  <key>CFBundleIdentifier</key><string>com.local.chargecap.uninstaller</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>Uninstall ChargeCap</string>
  <key>CFBundleIconFile</key><string>ChargeCap.icns</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
  <key>CFBundleVersion</key><string>$APP_BUILD</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST

xcrun swiftc -parse-as-library -O -target arm64-apple-macos13.0 \
  -framework SwiftUI -framework AppKit -framework Combine -framework Foundation -framework IOKit \
  "$ROOT/Sources/ChargeCap.swift" "$ROOT/Sources/ChargeModeCore.swift" "$ROOT/Sources/OnceChargeAgent.swift" \
  "$ROOT/Sources/DischargeControl.swift" "$ROOT/Sources/DischargeAgent.swift" \
  "$ROOT/Sources/PowerRefreshController.swift" -o "$CHARGECAP_APP/Contents/MacOS/ChargeCap"

xcrun swiftc -parse-as-library -O -target arm64-apple-macos13.0 \
  -framework SwiftUI -framework AppKit -framework Combine -framework Foundation \
  "$ROOT/Sources/UninstallChargeCap.swift" "$ROOT/Sources/ChargeModeCore.swift" \
  "$ROOT/Sources/DischargeControl.swift" "$ROOT/Sources/DischargeAgent.swift" -o "$UNINSTALLER_APP/Contents/MacOS/UninstallChargeCap"

# Standalone user LaunchAgent helper: keeps a one-time charge task alive after
# the menu-bar UI exits. Its executable is copied to the user's Application
# Support directory only when the user explicitly starts a one-time charge.
xcrun swiftc -parse-as-library -O -target arm64-apple-macos13.0 \
  -framework Foundation \
  "$ROOT/Sources/ChargeCapOnceHelper.swift" "$ROOT/Sources/ChargeModeCore.swift" "$ROOT/Sources/DischargeControl.swift" \
  -o "$CHARGECAP_APP/Contents/Resources/ChargeCapOnceHelper"
chmod 755 "$CHARGECAP_APP/Contents/Resources/ChargeCapOnceHelper"

# Create Finder .icns using built-in macOS tools (no third-party icon builders).
ICON_SOURCE="$ROOT/Assets/ChargeCapIcon-1024.png"
ICONSET="$BUILD_DIR/ChargeCap.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for spec in "16:icon_16x16.png" "32:icon_16x16@2x.png" "32:icon_32x32.png" "64:icon_32x32@2x.png" "128:icon_128x128.png" "256:icon_128x128@2x.png" "256:icon_256x256.png" "512:icon_256x256@2x.png" "512:icon_512x512.png" "1024:icon_512x512@2x.png"; do
  size="${spec%%:*}"
  name="${spec#*:}"
  /usr/bin/sips -s format png -z "$size" "$size" "$ICON_SOURCE" --out "$ICONSET/$name" >/dev/null
done
/usr/bin/iconutil -c icns "$ICONSET" -o "$BUILD_DIR/ChargeCap.icns"
rm -rf "$ICONSET"
for app_dir in "$CHARGECAP_APP" "$UNINSTALLER_APP"; do
  cp "$BUILD_DIR/ChargeCap.icns" "$app_dir/Contents/Resources/ChargeCap.icns"
  cp "$ICON_SOURCE" "$app_dir/Contents/Resources/ChargeCapIcon.png"
  cp "$ROOT/Assets/MenuBarLeafTemplate.png" "$app_dir/Contents/Resources/MenuBarLeafTemplate.png"
done

for app_dir in "$CHARGECAP_APP" "$UNINSTALLER_APP"; do
  cp "$ROOT/LICENSE" "$app_dir/Contents/Resources/ChargeCap-LICENSE.txt"
  cp "$ROOT/LICENSES/ChargeCap-Original-MIT.txt" "$app_dir/Contents/Resources/ChargeCap-Original-MIT.txt"
  cp "$ROOT/Vendor/BATT-LICENSE.txt" "$app_dir/Contents/Resources/BATT-LICENSE.txt"
done
cat > "$CHARGECAP_APP/Contents/Resources/THIRD_PARTY_NOTICES.txt" <<EOF
ChargeCap is distributed under Apache License 2.0; see ChargeCap-LICENSE.txt.
The original ChargeCap MIT notice is retained in ChargeCap-Original-MIT.txt.

ChargeCap includes the batt command-line utility from charlie0129/batt.
Upstream project: https://github.com/charlie0129/batt
Pinned upstream release: $BATT_VERSION
Upstream source corresponding to this binary: https://github.com/charlie0129/batt/tree/$BATT_VERSION
License for batt v0.8.0: GNU GPL version 2. The complete GPL text is bundled as BATT-LICENSE.txt.
The batt executable is invoked as a separate CLI utility; ChargeCap does not claim authorship of batt.
Bundled binary SHA-256: $BATT_SHA
EOF
cp "$CHARGECAP_APP/Contents/Resources/THIRD_PARTY_NOTICES.txt" "$UNINSTALLER_APP/Contents/Resources/THIRD_PARTY_NOTICES.txt"

/usr/bin/codesign --force --deep --sign - "$CHARGECAP_APP" >/dev/null
/usr/bin/codesign --force --deep --sign - "$UNINSTALLER_APP" >/dev/null

rm -rf "$BUILD_DIR/ChargeCap.app" "$BUILD_DIR/Uninstall ChargeCap.app"
mv "$CHARGECAP_APP" "$BUILD_DIR/ChargeCap.app"
mv "$UNINSTALLER_APP" "$BUILD_DIR/Uninstall ChargeCap.app"
rmdir "$APP_STAGE"
CHARGECAP_APP="$BUILD_DIR/ChargeCap.app"
UNINSTALLER_APP="$BUILD_DIR/Uninstall ChargeCap.app"
# Refresh Launch Services for rebuilt bundles at the same Finder paths.
/usr/bin/touch "$CHARGECAP_APP" "$UNINSTALLER_APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$CHARGECAP_APP" "$UNINSTALLER_APP"

# Create a drag-and-drop disk image containing both apps and an Applications shortcut.
DMG_STAGE="$BUILD_DIR/dmg-staging"
DMG_PATH="$BUILD_DIR/ChargeCap-${APP_VERSION}.dmg"
rm -rf "$DMG_STAGE" "$DMG_PATH"
mkdir -p "$DMG_STAGE"
cp -R "$CHARGECAP_APP" "$DMG_STAGE/ChargeCap.app"
cp -R "$UNINSTALLER_APP" "$DMG_STAGE/Uninstall ChargeCap.app"
ln -s /Applications "$DMG_STAGE/Applications"
/usr/bin/hdiutil create -volname "ChargeCap ${APP_VERSION}" -srcfolder "$DMG_STAGE" -ov -format UDZO "$DMG_PATH" >/dev/null
rm -rf "$DMG_STAGE"

printf '\n构建完成：\n  %s\n  %s\n  %s\n' "$CHARGECAP_APP" "$UNINSTALLER_APP" "$DMG_PATH"
echo "两个应用均内置 batt ${BATT_VERSION}；安装后不再需要联网下载控制组件。"
echo "DMG 内含 Applications 快捷方式，可将两个应用拖入 Applications。"
read -r -p "按回车退出..." _ || true
