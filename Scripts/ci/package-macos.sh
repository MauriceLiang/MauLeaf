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
[[ "$TARGET_ARCH" == arm64 || "$TARGET_ARCH" == x86_64 ]] || exit 2
[[ "$(uname -m)" == "$TARGET_ARCH" ]] || exit 2

STAGE="$RUNNER_TEMP/mauleaf-$TARGET_ARCH"
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

FLAGS=(-parse-as-library -O -target "$TARGET_ARCH-apple-macos13.0")
if [[ "$TARGET_ARCH" == x86_64 ]]; then FLAGS+=(-D MAULEAF_INTEL_EXPERIMENTAL); fi
xcrun swiftc "${FLAGS[@]}" -framework SwiftUI -framework AppKit -framework Combine -framework Foundation \
  Sources/MauLeaf.swift Sources/AppLocalization.swift Sources/BatteryStatusReader.swift Sources/FirmwareLimitCore.swift \
  Sources/FirmwareLimitHelperProtocol.swift Sources/FirmwareLimitHelperClient.swift \
  -o "$APP/Contents/MacOS/MauLeaf"

if [[ "$TARGET_ARCH" == arm64 ]]; then
  NATIVE="$APP/Contents/Resources/MauLeafNativeControl"
  mkdir -p "$NATIVE"
  xcrun swiftc -O -parse-as-library -target arm64-apple-macos13.0 \
    -framework IOKit -framework Security \
    Sources/FirmwareLimitCore.swift Sources/FirmwareLimitReconciliation.swift \
    Sources/BatteryStatusReader.swift Sources/FirmwareLimitRuntime.swift Sources/FirmwareLimitSMCTransport.swift \
    Sources/FirmwareLimitHelperProtocol.swift Sources/FirmwareLimitHelperService.swift \
    Sources/FirmwareLimitHelperMain.swift \
    -o "$NATIVE/MauLeafFirmwareHelper"
  chmod 755 "$NATIVE/MauLeafFirmwareHelper"
  codesign --force --sign - --identifier com.local.chargecap.firmware-helper "$NATIVE/MauLeafFirmwareHelper"
  codesign --verify --strict "$NATIVE/MauLeafFirmwareHelper"
  cp Support/com.local.chargecap.firmware-helper.plist "$NATIVE/"
  cp Scripts/install-native-firmware-helper.sh Scripts/uninstall-native-firmware-helper.sh "$NATIVE/"
  chmod 755 "$NATIVE/"*.sh
fi

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
[[ " $(lipo -archs "$APP/Contents/MacOS/MauLeaf") " == *" $TARGET_ARCH "* ]] || exit 5
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")" == "$RELEASE_VERSION" ]] || exit 5

mkdir -p "$STAGE/dmg"
ditto "$APP" "$STAGE/dmg/MauLeaf.app"
if [[ "$TARGET_ARCH" == arm64 ]]; then
  NAME="MauLeaf-$RELEASE_LABEL-macos-arm64.dmg"
else
  NAME="MauLeaf-$RELEASE_LABEL-macos-x86_64-EXPERIMENTAL.dmg"
  cat > "$STAGE/dmg/INTEL-EXPERIMENTAL-READ-ME.txt" <<'NOTICE'
Intel EXPERIMENTAL, UNTESTED, READ-ONLY preview / Intel 未测试只读实验版

The developer does not have an Intel Mac. This build has NOT been
installed, launched or tested on real Intel hardware. Actual operation,
accuracy and stability are unknown. It contains no privileged native
firmware helper and does not provide charging controls.

开发者没有 Intel Mac 实机，未进行安装、启动或运行测试。此版本不包含
原生固件服务，仅展示电池状态，不提供充电控制。
NOTICE
fi
ln -s /Applications "$STAGE/dmg/Applications"
hdiutil create -quiet -volname "MauLeaf $RELEASE_LABEL" -srcfolder "$STAGE/dmg" -format UDZO -ov "dist/$NAME"
hdiutil verify "dist/$NAME"
