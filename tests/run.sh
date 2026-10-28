#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cp -R "$ROOT/Resources/en.lproj" "$ROOT/Resources/zh-Hans.lproj" "$TMP/"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$TMP/ModuleCache}"
export SWIFT_MODULECACHE_PATH="${SWIFT_MODULECACHE_PATH:-$TMP/ModuleCache}"
swiftc "$ROOT/Sources/ChargeModeCore.swift" "$ROOT/Sources/AppLocalization.swift" "$ROOT/Sources/ChargeModeCoreTests.swift" -o "$TMP/coretests"
"$TMP/coretests"
swiftc -parse-as-library "$ROOT/Sources/ChargeModeCore.swift" "$ROOT/Sources/AppLocalization.swift" \
    "$ROOT/tests/LocalizationTests.swift" -o "$TMP/localizationtests"
"$TMP/localizationtests"
swiftc "$ROOT/Sources/ChargeModeCore.swift" "$ROOT/Sources/AppLocalization.swift" "$ROOT/Sources/DischargeControl.swift" \
    "$ROOT/tests/DischargeControlTests.swift" -o "$TMP/dischargetests"
"$TMP/dischargetests"
if [[ "$(uname -s)" == Darwin ]]; then
    swift "$ROOT/Scripts/GenerateAppIcon.swift" "$ROOT/Assets/MauLeafIcon-1024.png" "$TMP/AppIcon.iconset"
    swiftc -parse-as-library "$ROOT/tests/AppIconTests.swift" -o "$TMP/appicontests"
    "$TMP/appicontests" "$TMP/AppIcon.iconset"
    swiftc -parse-as-library -framework ServiceManagement "$ROOT/Sources/ChargeModeCore.swift" "$ROOT/Sources/AppLocalization.swift" \
        "$ROOT/Sources/LoginItemSettings.swift" "$ROOT/tests/LoginItemSettingsTests.swift" -o "$TMP/loginitemtests"
    "$TMP/loginitemtests"
    swiftc -parse-as-library -D MAULEAF_TESTING \
        "$ROOT/Sources/MauLeaf.swift" "$ROOT/Sources/ChargeModeCore.swift" "$ROOT/Sources/AppLocalization.swift" \
        "$ROOT/Sources/DischargeControl.swift" "$ROOT/Sources/PowerRefreshController.swift" "$ROOT/Sources/LoginItemSettings.swift" \
        "$ROOT/tests/ChargeManagerTests.swift" -o "$TMP/managertests"
    "$TMP/managertests"
    swiftc -parse-as-library "$ROOT/Sources/ChargeModeCore.swift" "$ROOT/Sources/AppLocalization.swift" "$ROOT/Sources/PowerRefreshController.swift" \
        "$ROOT/tests/PowerRefreshTests.swift" -o "$TMP/powertests"
    "$TMP/powertests"
    LAYOUT_APP="$TMP/LayoutTests.app"
    mkdir -p "$LAYOUT_APP/Contents/MacOS" "$LAYOUT_APP/Contents/Resources"
    cp -R "$ROOT/Resources/en.lproj" "$ROOT/Resources/zh-Hans.lproj" "$LAYOUT_APP/Contents/Resources/"
    cp "$ROOT/Assets/MenuBarLeafTemplate.png" "$LAYOUT_APP/Contents/Resources/"
    cat > "$LAYOUT_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>dev.mauriceliang.MauLeafLayoutTests</string><key>CFBundleExecutable</key><string>layouttests</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
PLIST
    swiftc -parse-as-library -D MAULEAF_TESTING -D MAULEAF_LAYOUT_TESTING \
        "$ROOT/Sources/MauLeaf.swift" "$ROOT/Sources/ChargeModeCore.swift" "$ROOT/Sources/AppLocalization.swift" \
        "$ROOT/Sources/DischargeControl.swift" "$ROOT/Sources/PowerRefreshController.swift" "$ROOT/Sources/LoginItemSettings.swift" \
        "$ROOT/tests/ChargeManagerTests.swift" "$ROOT/tests/FeedbackLayoutTests.swift" "$ROOT/tests/BatteryRingRenderingTests.swift" -o "$LAYOUT_APP/Contents/MacOS/layouttests"
    "$LAYOUT_APP/Contents/MacOS/layouttests" "$ROOT/build/ui-verification"
fi
swiftc -frontend -parse "$ROOT/Sources/MauLeaf.swift" "$ROOT/Sources/OnceChargeAgent.swift" "$ROOT/Sources/MauLeafOnceHelper.swift" "$ROOT/Sources/UninstallMauLeaf.swift" "$ROOT/Sources/DischargeControl.swift" "$ROOT/Sources/DischargeAgent.swift" "$ROOT/Sources/PowerRefreshController.swift" "$ROOT/Sources/LoginItemSettings.swift"
bash -n "$ROOT/Scripts/ci/package-macos.sh"
echo "Source parsing and build script checks passed"
