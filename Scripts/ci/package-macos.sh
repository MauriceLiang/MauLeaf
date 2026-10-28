#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
: "$\{RELEASE_VERSION:?missing version}"
: "$\{TARGET_ARCH:?missing arch}"
: "$\{BUILD_NUMBER:?missing build number}"
[[ "$RELEASE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 2
[[ "$TARGET_ARCH" == arm64 || "$TARGET_ARCH" == x86_64 ]] || exit 2
[[ "$(uname -m)" == "$TARGET_ARCH" ]] || exit 2
STAGE="$RUNNER_TEMP/mauleaf-$TARGET_ARCH"
APP="$STAGE/MauLeaf.app"
UNINSTALLER="$STAGE/Uninstall MauLeaf.app"
rm -rf "$STAGE"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" dist
BATT_VERSION="$(tr -d '\r\n' < Vendor/batt-version)"
[[ "$BATT_VERSION" == v0.8.0 ]] || exit 3
if [[ "$TARGET_ARCH" == arm64 ]]; then
  mkdir -p "$UNINSTALLER/Contents/MacOS" "$UNINSTALLER/Contents/Resources"
  curl -fLsS --retry 3 "https://github.com/charlie0129/batt/releases/download/v0.8.0/batt-v0.8.0-darwin-arm64.tar.gz" -o "$STAGE/batt.tar.gz"
  echo "7c63db14e1063bc087c505a924ac614d7ed3d72dbbbc1f2f6d2e38b682c10f58  $STAGE/batt.tar.gz" | shasum -a 256 -c -
  ENTRY="$(tar -tzf "$STAGE/batt.tar.gz" | grep -E '(^|/)batt$' | head -1)"
  [[ -n "$ENTRY" ]] || exit 4
  tar -xOzf "$STAGE/batt.tar.gz" "$ENTRY" > "$APP/Contents/Resources/batt"
  chmod 755 "$APP/Contents/Resources/batt"
  cp "$APP/Contents/Resources/batt" "$UNINSTALLER/Contents/Resources/batt"
  [[ " $(lipo -archs "$APP/Contents/Resources/batt") " == *" arm64 "* ]] || exit 4
  BATT_SHA="$(shasum -a 256 "$APP/Contents/Resources/batt" | awk '{print $1}')"
  for dir in "$APP" "$UNINSTALLER"; do
    echo "$BATT_VERSION" > "$dir/Contents/Resources/batt-version.txt"
    echo "$BATT_SHA" > "$dir/Contents/Resources/batt-sha256.txt"
  done
fi
write_plist() {
  local path="$1" executable="$2" name="$3" identifier="$4" background="$5"
  cat > "$path/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
<key>CFBundleExecutable</key><string>$executable</string>
<key>CFBundleIdentifier</key><string>$identifier</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundleLocalizations</key><array><string>zh-Hans</string><string>en</string></array>
<key>CFBundleName</key><string>$name</string>
<key>CFBundleDisplayName</key><string>$name</string>
<key>CFBundleIconFile</key><string>MauLeaf.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$RELEASE_VERSION</string>
<key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><$background/>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
}
write_plist "$APP" MauLeaf MauLeaf com.local.chargecap true
if [[ "$TARGET_ARCH" == arm64 ]]; then
  write_plist "$UNINSTALLER" UninstallMauLeaf "Uninstall MauLeaf" com.local.chargecap.uninstaller false
fi
FLAGS=(-parse-as-library -O -target "$TARGET_ARCH-apple-macos13.0")
if [[ "$TARGET_ARCH" == x86_64 ]]; then FLAGS+=(-D MAULEAF_INTEL_EXPERIMENTAL); fi
xcrun swiftc "$\{FLAGS[@]}" -framework SwiftUI -framework AppKit -framework Combine -framework Foundation -framework IOKit -framework ServiceManagement \
 Sources/MauLeaf.swift Sources/ChargeModeCore.swift Sources/AppLocalization.swift Sources/OnceChargeAgent.swift \
 Sources/DischargeControl.swift Sources/DischargeAgent.swift Sources/PowerRefreshController.swift Sources/LoginItemSettings.swift \
 -o "$APP/Contents/MacOS/MauLeaf"
if [[ "$TARGET_ARCH" == arm64 ]]; then
  xcrun swiftc "$\{FLAGS[@]}" -framework SwiftUI -framework AppKit -framework Combine -framework Foundation \
   Sources/UninstallMauLeaf.swift Sources/ChargeModeCore.swift Sources/AppLocalization.swift Sources/DischargeControl.swift Sources/DischargeAgent.swift \
   -o "$UNINSTALLER/Contents/MacOS/UninstallMauLeaf"
  xcrun swiftc "$\{FLAGS[@]}" -framework Foundation \
   Sources/MauLeafOnceHelper.swift Sources/ChargeModeCore.swift Sources/AppLocalization.swift Sources/DischargeControl.swift \
   -o "$APP/Contents/Resources/MauLeafOnceHelper"
fi
xcrun swift Scripts/GenerateAppIcon.swift Assets/MauLeafIcon-1024.png "$STAGE/MauLeaf.iconset"
iconutil -c icns "$STAGE/MauLeaf.iconset" -o "$STAGE/MauLeaf.icns"
for dir in "$APP" "$UNINSTALLER"; do
  [[ -d "$dir" ]] || continue
  cp "$STAGE/MauLeaf.icns" "$dir/Contents/Resources/MauLeaf.icns"
  cp Assets/MauLeafIcon-1024.png "$dir/Contents/Resources/MauLeafIcon.png"
  cp Assets/MenuBarLeafTemplate.png "$dir/Contents/Resources/MenuBarLeafTemplate.png"
  cp LICENSE "$dir/Contents/Resources/MauLeaf-LICENSE.txt"
  cp LICENSES/ChargeCap-Original-MIT.txt "$dir/Contents/Resources/ChargeCap-Original-MIT.txt"
  cp Vendor/BATT-LICENSE.txt "$dir/Contents/Resources/BATT-LICENSE.txt"
done
cp -R Resources/en.lproj Resources/zh-Hans.lproj "$APP/Contents/Resources/"
echo "batt v0.8.0 GPL-2.0; source code archived with the GitHub Release." > "$APP/Contents/Resources/THIRD_PARTY_NOTICES.txt"
if [[ "$TARGET_ARCH" == arm64 ]]; then
  cp "$APP/Contents/Resources/THIRD_PARTY_NOTICES.txt" "$UNINSTALLER/Contents/Resources/"
  codesign --force --sign - "$APP/Contents/Resources/batt"
  codesign --force --sign - "$UNINSTALLER/Contents/Resources/batt"
  codesign --force --sign - "$APP/Contents/Resources/MauLeafOnceHelper"
  codesign --force --sign - "$UNINSTALLER"
fi
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
[[ " $(lipo -archs "$APP/Contents/MacOS/MauLeaf") " == *" $TARGET_ARCH "* ]] || exit 5
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")" == "$RELEASE_VERSION" ]] || exit 5
mkdir -p "$STAGE/dmg"
ditto "$APP" "$STAGE/dmg/MauLeaf.app"
if [[ "$TARGET_ARCH" == arm64 ]]; then
  codesign --verify --deep --strict "$UNINSTALLER"
  ditto "$UNINSTALLER" "$STAGE/dmg/Uninstall MauLeaf.app"
  NAME="MauLeaf-$RELEASE_VERSION-macos-arm64.dmg"
else
  [[ ! -e "$APP/Contents/Resources/batt" ]] || exit 6
  NAME="MauLeaf-$RELEASE_VERSION-macos-x86_64-EXPERIMENTAL.dmg"
  cat > "$STAGE/dmg/INTEL-EXPERIMENTAL-READ-ME.txt" <<'NOTICE'
Intel EXPERIMENTAL read-only preview: battery information only.
Charging controls, batt installation and service removal are DISABLED.
Intel hardware charging compatibility is NOT validated.
Intel 实验预览仅显示电池信息；禁用充电控制与服务安装卸载，兼容性未经验证。
NOTICE
fi
ln -s /Applications "$STAGE/dmg/Applications"
hdiutil create -quiet -volname "MauLeaf $RELEASE_VERSION" -srcfolder "$STAGE/dmg" -format UDZO -ov "dist/$NAME"
hdiutil verify "dist/$NAME"
