#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
: "${RELEASE_VERSION:?missing version}"
: "${TARGET_ARCH:?missing arch}"
: "${BUILD_NUMBER:?missing build number}"
RELEASE_LABEL="${RELEASE_LABEL:-$RELEASE_VERSION}"
RELEASE_LABEL="${RELEASE_LABEL#v}"
[[ "$RELEASE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 2
[[ "$RELEASE_LABEL" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-preview\.[0-9]+)?$ ]] || exit 2
[[ "$TARGET_ARCH" == arm64 ]] || {
  echo "MauLeaf Preview 5 supports Apple Silicon arm64 builds only." >&2
  exit 2
}
[[ "$(uname -m)" == arm64 ]] || {
  echo "The packaging runner must be Apple Silicon arm64." >&2
  exit 2
}

STAGE="$RUNNER_TEMP/mauleaf-arm64"
APP="$STAGE/MauLeaf.app"
rm -rf "$STAGE"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" dist

write_plist() {
  cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
<key>CFBundleExecutable</key><string>MauLeaf</string>
<key>CFBundleIdentifier</key><string>com.local.chargecap</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundleLocalizations</key><array><string>zh-Hans</string><string>en</string></array>
<key>CFBundleName</key><string>MauLeaf</string>
<key>CFBundleDisplayName</key><string>MauLeaf</string>
<key>CFBundleIconFile</key><string>MauLeaf.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$RELEASE_VERSION</string>
<key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
}
write_plist

FLAGS=(-parse-as-library -O -target arm64-apple-macos13.0)
xcrun swiftc "${FLAGS[@]}" -framework SwiftUI -framework AppKit -framework Combine -framework Foundation \
  Sources/MauLeaf.swift Sources/AppLocalization.swift Sources/BatteryStatusReader.swift Sources/FirmwareLimitCore.swift \
  Sources/FirmwareLimitHelperProtocol.swift Sources/FirmwareLimitHelperClient.swift \
  -o "$APP/Contents/MacOS/MauLeaf"

NATIVE="$APP/Contents/Resources/MauLeafNativeControl"
mkdir -p "$NATIVE"
xcrun swiftc -O -parse-as-library -target arm64-apple-macos13.0 \
  -framework IOKit -framework Security \
  Sources/FirmwareLimitCore.swift Sources/FirmwareLimitReconciliation.swift \
  Sources/BatteryStatusReader.swift Sources/SystemFirmwareReader.swift Sources/FirmwareLimitRuntime.swift Sources/FirmwareLimitSMCTransport.swift \
  Sources/FirmwareLimitHelperProtocol.swift Sources/FirmwareLimitHelperService.swift \
  Sources/FirmwareLimitHelperMain.swift \
  -o "$NATIVE/MauLeafFirmwareHelper"
chmod 755 "$NATIVE/MauLeafFirmwareHelper"
codesign --force --sign - --identifier com.local.chargecap.firmware-helper "$NATIVE/MauLeafFirmwareHelper"
codesign --verify --strict "$NATIVE/MauLeafFirmwareHelper"
cp Support/com.local.chargecap.firmware-helper.plist "$NATIVE/"
cp Scripts/install-native-firmware-helper.sh Scripts/uninstall-native-firmware-helper.sh "$NATIVE/"
chmod 755 "$NATIVE/"*.sh

xcrun swift Scripts/GenerateAppIcon.swift Assets/MauLeafIcon-1024.png "$STAGE/MauLeaf.iconset"
iconutil -c icns "$STAGE/MauLeaf.iconset" -o "$STAGE/MauLeaf.icns"
cp "$STAGE/MauLeaf.icns" "$APP/Contents/Resources/MauLeaf.icns"
cp Assets/MauLeafIcon-1024.png "$APP/Contents/Resources/MauLeafIcon.png"
cp Assets/MenuBarLeafTemplate.png "$APP/Contents/Resources/MenuBarLeafTemplate.png"
cp LICENSE "$APP/Contents/Resources/MauLeaf-LICENSE.txt"
cp LICENSES/ChargeCap-Original-MIT.txt "$APP/Contents/Resources/ChargeCap-Original-MIT.txt"
cp -R Resources/en.lproj Resources/zh-Hans.lproj "$APP/Contents/Resources/"
cat > "$APP/Contents/Resources/THIRD_PARTY_NOTICES.txt" <<'NOTICE'
MauLeaf uses its own native AppleSMC firmware controller.
No third-party charging-control executable or firmware bundle is included.
The native privileged helper is built from this repository's source code.
NOTICE

codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
[[ " $(lipo -archs "$APP/Contents/MacOS/MauLeaf") " == *" arm64 "* ]] || exit 5
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")" == "$RELEASE_VERSION" ]] || exit 5

mkdir -p "$STAGE/dmg"
ditto "$APP" "$STAGE/dmg/MauLeaf.app"
NAME="MauLeaf-$RELEASE_LABEL-macos-arm64.dmg"
ln -s /Applications "$STAGE/dmg/Applications"
hdiutil create -quiet -volname "MauLeaf $RELEASE_LABEL" -srcfolder "$STAGE/dmg" -format UDZO -ov "dist/$NAME"
hdiutil verify "dist/$NAME"
