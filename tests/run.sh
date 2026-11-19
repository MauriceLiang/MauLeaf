#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cp -R "$ROOT/Resources/en.lproj" "$ROOT/Resources/zh-Hans.lproj" "$TMP/"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$TMP/ModuleCache}"
export SWIFT_MODULECACHE_PATH="${SWIFT_MODULECACHE_PATH:-$TMP/ModuleCache}"

swiftc "$ROOT/Sources/BatteryStatusReader.swift" "$ROOT/tests/BatteryStatusReaderTests.swift" -o "$TMP/batterystatusreadertests"
"$TMP/batterystatusreadertests"

swiftc "$ROOT/Sources/FirmwareLimitCore.swift" "$ROOT/tests/FirmwareLimitCoreTests.swift" -o "$TMP/firmwarelimitcoretests"
"$TMP/firmwarelimitcoretests"

swiftc "$ROOT/Sources/FirmwareLimitCore.swift" "$ROOT/Sources/FirmwareLimitReconciliation.swift" \
    "$ROOT/tests/FirmwareLimitReconciliationTests.swift" -o "$TMP/firmwarereconciliationtests"
"$TMP/firmwarereconciliationtests"

swiftc -parse-as-library "$ROOT/Sources/AppLocalization.swift" \
    "$ROOT/tests/LocalizationTests.swift" -o "$TMP/localizationtests"
"$TMP/localizationtests"

if [[ "$(uname -s)" == Darwin ]]; then
    swiftc -parse-as-library -framework IOKit -framework Security \
        "$ROOT/Sources/BatteryStatusReader.swift" "$ROOT/Sources/FirmwareLimitCore.swift" \
        "$ROOT/Sources/FirmwareLimitReconciliation.swift" \
        "$ROOT/Sources/FirmwareLimitRuntime.swift" \
        "$ROOT/Sources/FirmwareLimitSMCTransport.swift" \
        "$ROOT/Sources/FirmwareLimitHelperProtocol.swift" \
        "$ROOT/Sources/FirmwareLimitHelperService.swift" \
        "$ROOT/tests/FirmwareLimitHelperServiceTests.swift" \
        -o "$TMP/firmwarehelpertests"
    "$TMP/firmwarehelpertests"

    swiftc -parse-as-library -D MAULEAF_TESTING \
        -framework SwiftUI -framework AppKit -framework Combine \
        "$ROOT/Sources/MauLeaf.swift" "$ROOT/Sources/AppLocalization.swift" \
        "$ROOT/Sources/BatteryStatusReader.swift" "$ROOT/Sources/FirmwareLimitCore.swift" "$ROOT/Sources/FirmwareLimitHelperProtocol.swift" \
        "$ROOT/Sources/FirmwareLimitHelperClient.swift" \
        "$ROOT/tests/NativeFirmwareBackendFixture.swift" "$ROOT/tests/ChargeManagerTests.swift" \
        -o "$TMP/managertests"
    "$TMP/managertests"

    swift "$ROOT/Scripts/GenerateAppIcon.swift" "$ROOT/Assets/MauLeafIcon-1024.png" "$TMP/AppIcon.iconset"
    swiftc -parse-as-library "$ROOT/tests/AppIconTests.swift" -o "$TMP/appicontests"
    "$TMP/appicontests" "$TMP/AppIcon.iconset"

    LAYOUT_APP="$TMP/LayoutTests.app"
    mkdir -p "$LAYOUT_APP/Contents/MacOS" "$LAYOUT_APP/Contents/Resources"
    cp -R "$ROOT/Resources/en.lproj" "$ROOT/Resources/zh-Hans.lproj" "$LAYOUT_APP/Contents/Resources/"
    cp "$ROOT/Assets/MenuBarLeafTemplate.png" "$LAYOUT_APP/Contents/Resources/"
    cat > "$LAYOUT_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>dev.mauriceliang.MauLeafLayoutTests</string><key>CFBundleExecutable</key><string>layouttests</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
PLIST
    swiftc -parse-as-library -D MAULEAF_TESTING -D MAULEAF_LAYOUT_TESTING \
        -framework SwiftUI -framework AppKit -framework Combine \
        "$ROOT/Sources/MauLeaf.swift" "$ROOT/Sources/AppLocalization.swift" \
        "$ROOT/Sources/BatteryStatusReader.swift" "$ROOT/Sources/FirmwareLimitCore.swift" "$ROOT/Sources/FirmwareLimitHelperProtocol.swift" \
        "$ROOT/Sources/FirmwareLimitHelperClient.swift" \
        "$ROOT/tests/NativeFirmwareBackendFixture.swift" "$ROOT/tests/FeedbackLayoutTests.swift" \
        "$ROOT/tests/BatteryRingRenderingTests.swift" -o "$LAYOUT_APP/Contents/MacOS/layouttests"
    "$LAYOUT_APP/Contents/MacOS/layouttests" "$ROOT/build/ui-verification"
fi

swiftc -frontend -parse \
    "$ROOT/Sources/MauLeaf.swift" "$ROOT/Sources/AppLocalization.swift" \
    "$ROOT/Sources/BatteryStatusReader.swift" "$ROOT/Sources/FirmwareLimitCore.swift" "$ROOT/Sources/FirmwareLimitReconciliation.swift" \
    "$ROOT/Sources/FirmwareLimitRuntime.swift" "$ROOT/Sources/FirmwareLimitSMCTransport.swift" \
    "$ROOT/Sources/FirmwareLimitHelperProtocol.swift" "$ROOT/Sources/FirmwareLimitHelperClient.swift" \
    "$ROOT/Sources/FirmwareLimitHelperService.swift" "$ROOT/Sources/FirmwareLimitHelperMain.swift"

if grep -RniE 'BattCommand|BattStatus|invokeBatt|locateBatt|batt-version|BATT-LICENSE|/usr/local/bin/batt|batt-v0\\.8' \
    "$ROOT/Sources" "$ROOT/Scripts/ci/package-macos.sh" \
    "$ROOT/Scripts/install-native-firmware-helper.sh" \
    "$ROOT/Scripts/uninstall-native-firmware-helper.sh" \
    "$ROOT/.github/workflows/build-release.yml" "$ROOT/Support"; then
    echo "Legacy batt backend references must not ship in the native-only preview" >&2
    exit 1
fi
if grep -Eq 'componentSetupSection|installBackend|uninstallBackend' "$ROOT/Sources/MauLeaf.swift"; then
    echo "The legacy component installer UI must not return" >&2
    exit 1
fi
grep -Fq '@Published private(set) var menuBarLeafStyle: MenuBarLeafStyle = .green' "$ROOT/Sources/MauLeaf.swift"
bash -n "$ROOT/Scripts/ci/package-macos.sh"
bash -n "$ROOT/Scripts/install-native-firmware-helper.sh"
bash -n "$ROOT/Scripts/uninstall-native-firmware-helper.sh"
if [[ "$(uname -s)" == Darwin ]]; then
    plutil -lint "$ROOT/Support/com.local.chargecap.firmware-helper.plist"
fi
echo "Native-only source parsing, tests and packaging checks passed"
