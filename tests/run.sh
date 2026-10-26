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
    swiftc -parse-as-library -D MAULEAF_TESTING -D MAULEAF_LAYOUT_TESTING \
        "$ROOT/Sources/MauLeaf.swift" "$ROOT/Sources/ChargeModeCore.swift" "$ROOT/Sources/AppLocalization.swift" \
        "$ROOT/Sources/DischargeControl.swift" "$ROOT/Sources/PowerRefreshController.swift" "$ROOT/Sources/LoginItemSettings.swift" \
        "$ROOT/tests/ChargeManagerTests.swift" "$ROOT/tests/FeedbackLayoutTests.swift" -o "$TMP/layouttests"
    "$TMP/layouttests"
fi
swiftc -frontend -parse "$ROOT/Sources/MauLeaf.swift" "$ROOT/Sources/OnceChargeAgent.swift" "$ROOT/Sources/MauLeafOnceHelper.swift" "$ROOT/Sources/UninstallMauLeaf.swift" "$ROOT/Sources/DischargeControl.swift" "$ROOT/Sources/DischargeAgent.swift" "$ROOT/Sources/PowerRefreshController.swift" "$ROOT/Sources/LoginItemSettings.swift"
bash -n "$ROOT/build.command"
echo "Source parsing and build script checks passed"
