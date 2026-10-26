#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$TMP/ModuleCache}"
export SWIFT_MODULECACHE_PATH="${SWIFT_MODULECACHE_PATH:-$TMP/ModuleCache}"
swiftc "$ROOT/Sources/ChargeModeCore.swift" "$ROOT/Sources/ChargeModeCoreTests.swift" -o "$TMP/coretests"
"$TMP/coretests"
swiftc "$ROOT/Sources/ChargeModeCore.swift" "$ROOT/Sources/DischargeControl.swift" \
    "$ROOT/tests/DischargeControlTests.swift" -o "$TMP/dischargetests"
"$TMP/dischargetests"
if [[ "$(uname -s)" == Darwin ]]; then
    swiftc -parse-as-library -D CHARGECAP_TESTING \
        "$ROOT/Sources/ChargeCap.swift" "$ROOT/Sources/ChargeModeCore.swift" \
        "$ROOT/Sources/DischargeControl.swift" "$ROOT/Sources/PowerRefreshController.swift" \
        "$ROOT/tests/ChargeManagerTests.swift" -o "$TMP/managertests"
    "$TMP/managertests"
    swiftc -parse-as-library "$ROOT/Sources/ChargeModeCore.swift" "$ROOT/Sources/PowerRefreshController.swift" \
        "$ROOT/tests/PowerRefreshTests.swift" -o "$TMP/powertests"
    "$TMP/powertests"
    swiftc -parse-as-library -D CHARGECAP_TESTING -D CHARGECAP_LAYOUT_TESTING \
        "$ROOT/Sources/ChargeCap.swift" "$ROOT/Sources/ChargeModeCore.swift" \
        "$ROOT/Sources/DischargeControl.swift" "$ROOT/Sources/PowerRefreshController.swift" \
        "$ROOT/tests/ChargeManagerTests.swift" "$ROOT/tests/FeedbackLayoutTests.swift" -o "$TMP/layouttests"
    "$TMP/layouttests"
fi
swiftc -frontend -parse "$ROOT/Sources/ChargeCap.swift" "$ROOT/Sources/OnceChargeAgent.swift" "$ROOT/Sources/ChargeCapOnceHelper.swift" "$ROOT/Sources/UninstallChargeCap.swift" "$ROOT/Sources/DischargeControl.swift" "$ROOT/Sources/DischargeAgent.swift" "$ROOT/Sources/PowerRefreshController.swift"
bash -n "$ROOT/build.command"
echo "Source parsing and build script checks passed"
