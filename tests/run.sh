#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
MAULEAF_ROOT="$ROOT"
source "$ROOT/Scripts/ci/sources.sh"
# Keep cross-file static invariants after moving the original declarations.
APP_AUDIT="$TMP/app-audit.swift"
cat "$ROOT/Sources/App/MauLeafApp.swift" "$ROOT/Sources/MenuBar/MenuBarController.swift" "$ROOT/Sources/MenuBar/MenuBarIcon.swift" "$ROOT/Sources/Views/BatteryStatusRing.swift" "$ROOT/Sources/Views/ContentView.swift" "$ROOT/Sources/Views/OperationFeedbackView.swift" "$ROOT/Sources/Charging/ChargeOperation.swift" "$ROOT/Sources/Charging/ChargeManager.swift" "$ROOT/Sources/Views/SettingsView.swift" > "$APP_AUDIT"
cp -R "$ROOT/Resources/en.lproj" "$ROOT/Resources/zh-Hans.lproj" "$TMP/"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$TMP/ModuleCache}"
export SWIFT_MODULECACHE_PATH="${SWIFT_MODULECACHE_PATH:-$TMP/ModuleCache}"

swiftc "$ROOT/Sources/Power/BatteryStatusReader.swift" "$ROOT/tests/BatteryStatusReaderTests.swift" -o "$TMP/batterystatusreadertests"
"$TMP/batterystatusreadertests"

swiftc "$ROOT/Sources/Power/BatteryStatusReader.swift" "$ROOT/Sources/Power/PowerFlowModel.swift" "$ROOT/tests/PowerFlowModelTests.swift" -o "$TMP/powerflowmodeltests"
"$TMP/powerflowmodeltests"

swiftc "$ROOT/Sources/Charging/AboveLimitPowerPolicy.swift" "$ROOT/tests/AboveLimitPowerPolicyTests.swift" -o "$TMP/abovelimitpowerpolicytests"

swiftc "$ROOT/Sources/Charging/DynamicHoldPolicy.swift" "$ROOT/tests/DynamicHoldPolicyTests.swift" -o "$TMP/dynamicholdpolicytests"
"$TMP/dynamicholdpolicytests"
"$TMP/abovelimitpowerpolicytests"

swiftc "$ROOT/Sources/Firmware/FirmwareLimitCore.swift" "$ROOT/tests/FirmwareLimitCoreTests.swift" -o "$TMP/firmwarelimitcoretests"
"$TMP/firmwarelimitcoretests"

swiftc "$ROOT/Sources/Firmware/FirmwareLimitCore.swift" "$ROOT/Sources/Firmware/FirmwareLimitReconciliation.swift" \
    "$ROOT/tests/FirmwareLimitReconciliationTests.swift" -o "$TMP/firmwarereconciliationtests"
"$TMP/firmwarereconciliationtests"

swiftc -parse-as-library "$ROOT/Sources/Shared/AppLocalization.swift" "$ROOT/Sources/Shared/AppAppearance.swift" \
    "$ROOT/tests/LocalizationTests.swift" -o "$TMP/localizationtests"
"$TMP/localizationtests"

if [[ "$(uname -s)" == Darwin ]]; then
    swiftc -parse-as-library -framework IOKit -framework Security \
        "${MAULEAF_HELPER_SERVICE_SOURCES[@]}" \
        "$ROOT/tests/FirmwareLimitHelperServiceTests.swift" "$ROOT/tests/MagSafeLEDTests.swift" \
        -o "$TMP/firmwarehelpertests"
    "$TMP/firmwarehelpertests"

    swiftc -parse-as-library -D MAULEAF_TESTING \
        -framework SwiftUI -framework AppKit -framework Combine -framework IOKit \
        "${MAULEAF_APP_SOURCES[@]}" \
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
        -framework SwiftUI -framework AppKit -framework Combine -framework IOKit \
        "${MAULEAF_APP_SOURCES[@]}" \
        "$ROOT/tests/NativeFirmwareBackendFixture.swift" "$ROOT/tests/FeedbackLayoutTests.swift" \
        "$ROOT/tests/BatteryRingRenderingTests.swift" -o "$LAYOUT_APP/Contents/MacOS/layouttests"
    "$LAYOUT_APP/Contents/MacOS/layouttests" "$ROOT/build/ui-verification"
fi

bash "$ROOT/tests/HelperReplacementScriptTests.sh" "$ROOT"

swiftc -frontend -parse "${MAULEAF_APP_SOURCES[@]}" \
    "$ROOT/Sources/Firmware/FirmwareLimitSMCTransport.swift" \
    "$ROOT/Sources/Firmware/MagSafeLEDController.swift" "$ROOT/Sources/Helper/MagSafeLEDPolicy.swift" "$ROOT/Sources/Helper/MagSafeLEDObservationReader.swift" \
    "$ROOT/Sources/Helper/FirmwareLimitHelperService.swift" "$MAULEAF_HELPER_MAIN_SOURCE"

if grep -RniE 'BattCommand|BattStatus|invokeBatt|locateBatt|batt-version|BATT-LICENSE|/usr/local/bin/batt|batt-v0\\.8' \
    "$ROOT/Sources" "$ROOT/Scripts/ci/package-macos.sh" \
    "$ROOT/Scripts/install-native-firmware-helper.sh" \
    "$ROOT/Scripts/uninstall-native-firmware-helper.sh" \
    "$ROOT/.github/workflows/build-release.yml" "$ROOT/Support"; then
    echo "Legacy batt backend references must not ship in the native-only preview" >&2
    exit 1
fi
# A raw English response.message from the privileged helper must not leak to
# the user-facing operation toast; preserve the helper text only for logging.
if grep -Fq 'AppText(verbatim: response.message)' "$APP_AUDIT"; then
    echo "Native helper audit messages must not be shown directly in the UI" >&2
    exit 1
fi

# The approved design is one transparent borderless menu-bar panel, with
# exactly one SwiftUI floating card rather than an outer frame + inner tile.
# Charging operations remain in-row; errors still expand inline.
grep -Fq 'private final class MauLeafCardPanel: NSPanel' "$APP_AUDIT"
grep -Fq 'styleMask: [.borderless]' "$APP_AUDIT"
grep -Fq 'panel.isOpaque = false' "$APP_AUDIT"
grep -Fq 'panel.backgroundColor = .clear' "$APP_AUDIT"
grep -Fq 'panel.hasShadow = false' "$APP_AUDIT"
# A native menu-bar card opens/closes immediately: no shape morph,
# entrance animation, delayed dismissal or temporary proxy NSPanel.
grep -Fq 'struct FloatingCardShape: Shape' "$APP_AUDIT"
grep -Fq 'let root = ContentView(manager: manager)' "$APP_AUDIT"
grep -Fq 'panel.makeKeyAndOrderFront(nil)' "$APP_AUDIT"
grep -Fq 'panel.orderOut(nil)' "$APP_AUDIT"
grep -Fq 'panel.hasShadow = false' "$APP_AUDIT"
[[ "$(grep -Fc 'panel = MauLeafCardPanel(' "$APP_AUDIT")" -eq 1 ]]
[[ "$(grep -Fc '.fill(.regularMaterial)' "$APP_AUDIT")" -eq 1 ]]
if grep -Eq 'MenuCardMotion|MenuCardPresentation|AnimatedFloatingCardShape|MenuCardMorphRoot|MenuPanelMorph|MenuPanelEntrance|makeMorphWindow|morphGeneration|morphState|closePanelTowardsLeaf|showPanelFromMenuBar' "$APP_AUDIT"; then
    echo "Menu-bar popup must appear and disappear instantly without morph state" >&2
    exit 1
fi
if grep -Eq 'NSPanel\(contentRect:|NSVisualEffectView\(frame:' "$APP_AUDIT"; then
    echo "No secondary animated popup panel or visual-effect proxy may return" >&2
    exit 1
fi
# Keep the root non-scrollable: wheel and trackpad swipes must not move
# the menu card, but internal controls still expand its intrinsic height.
grep -Fq '.fixedSize(horizontal: false, vertical: true)' "$APP_AUDIT"
grep -Fq '.onPreferenceChange(PanelContentHeightPreferenceKey.self)' "$APP_AUDIT"
if grep -Eq 'ScrollView[[:space:]]*\{|NSScrollView[[:space:]]*\(' "$APP_AUDIT"; then
    echo "Menu bar popup must not contain a scrollable view" >&2
    exit 1
fi
# A SwiftUI disclosure transition alone cannot animate the AppKit window
# height; both layers must share the same 240ms timing and preserve the
# top edge when Settings or Charge limit expands.
grep -Fq 'private let resizeDuration: TimeInterval = 0.24' "$APP_AUDIT"
grep -Fq 'context.duration = resizeDuration' "$APP_AUDIT"
grep -Fq 'panel.animator().setFrame(targetFrame, display: true)' "$APP_AUDIT"
grep -Fq 'y: anchorTop - height' "$APP_AUDIT"
grep -Fq 'accessibilityDisplayShouldReduceMotion' "$APP_AUDIT"
grep -Fq 'reduceMotion ? nil : .easeInOut(duration: 0.24)' "$APP_AUDIT"
[[ "$(grep -Fc 'withAnimation(expansionAnimation)' "$APP_AUDIT")" -eq 2 ]]
[[ "$(grep -Fc '.transition(expansionTransition)' "$APP_AUDIT")" -eq 2 ]]
if grep -Fq 'panel.setContentSize(NSSize(width: panelWidth' "$APP_AUDIT"; then
    echo "Direct size changes bypass the floating card disclosure animation" >&2
    exit 1
fi
if grep -Fq 'titlebarAppearsTransparent' "$APP_AUDIT"; then
    echo "The extra native titlebar/frame must not return" >&2
    exit 1
fi
[[ "$(grep -Fc '.fill(.regularMaterial)' "$APP_AUDIT")" -eq 1 ]]
grep -Fq 'private var groupDivider: some View' "$APP_AUDIT"
if grep -Fq '.background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))' "$APP_AUDIT"; then
    echo "The nested battery status tile must not return" >&2
    exit 1
fi
# Charging operations remain in-row; errors still expand inline.
if grep -Fq '.overlay(alignment: .bottom)' "$APP_AUDIT"; then
    echo "Operation feedback must never overlay the bottom menu controls" >&2
    exit 1
fi
grep -Fq 'OperationFeedbackView(manager: manager)' "$APP_AUDIT"
grep -Fq 'activeOperation?.affectsLimit' "$APP_AUDIT"
grep -Fq 'activeOperation?.affectsFullCharge' "$APP_AUDIT"
# Keep the icon/status overview, direct card controls and inline settings.
POPOVER_SOURCE="$(cat "$ROOT/Sources/Views/ContentView.swift" "$ROOT/Sources/Views/SettingsView.swift")"
if grep -Fq 'BatteryStatusRing(' <<< "$POPOVER_SOURCE"; then
    echo "The oversized battery ring must not return to the compact menu-bar overview" >&2
    exit 1
fi
for required in 'MauLeafPowerFlowView(flow: manager.powerFlow' 'manager.popoverLimitStatus' \
    'manager.popoverFullChargeStatus' 'limitExpanded' 'settingsExpanded' \
    'manager.toggleLimitFromCard()' 'manager.toggleFullChargeFromCard()' \
    'private var limitControls' 'NSApp.terminate(nil)'; do
    if ! grep -Fq "$required" <<< "$POPOVER_SOURCE"; then
        echo "Missing a required compact popover state or action: $required" >&2
        exit 1
    fi
done

# New native controls preserve the three original settings bindings and policy lock.
if grep -Eq 'oneTimeToggleRow|private var limitAction' <<< "$POPOVER_SOURCE"; then
    echo "Old lower charge actions must not return" >&2
    exit 1
fi
grep -Fq 'Toggle(isOn: $manager.showPowerFlow)' <<< "$POPOVER_SOURCE"
grep -Fq 'Toggle(isOn: $manager.removeComponentsOnQuit)' <<< "$POPOVER_SOURCE"
grep -Fq 'Picker("", selection: $manager.language)' <<< "$POPOVER_SOURCE"
grep -Fq 'get: { manager.appearance == .light }' <<< "$POPOVER_SOURCE"
grep -Fq 'set: { manager.appearance = $0 ? .light : .dark }' <<< "$POPOVER_SOURCE"
grep -Fq 'settingsLabel("浅色模式")' <<< "$POPOVER_SOURCE"
grep -Fq 'AppTheme.chargeGreen(in: colorScheme)' <<< "$POPOVER_SOURCE"
grep -Fq 'set: { manager.setDynamicHoldEnabled($0) }' <<< "$POPOVER_SOURCE"
grep -Fq '.disabled(manager.isDynamicHoldSwitchLocked)' <<< "$POPOVER_SOURCE"
grep -Fq 'settingsLabel("显示供电详情")' <<< "$POPOVER_SOURCE"
[[ "$(grep -Fc '.toggleStyle(.switch)' <<< "$POPOVER_SOURCE")" -eq 4 ]]
[[ "$(grep -Fc '.pickerStyle(.segmented)' <<< "$POPOVER_SOURCE")" -eq 0 ]]
[[ "$(grep -Fc '.pickerStyle(.menu)' <<< "$POPOVER_SOURCE")" -eq 1 ]]
if grep -Eq 'powerFlowRefreshSeconds|供电刷新间隔' <<< "$POPOVER_SOURCE"; then
    echo "Manual power refresh controls must not return" >&2
    exit 1
fi
grep -Fq 'if manager.showPowerFlow' <<< "$POPOVER_SOURCE"
grep -Fq 'MauLeafPowerStatusRow(mode: manager.powerFlow.mode' <<< "$POPOVER_SOURCE"
grep -Fq 'MauLeafPowerStatusBadge(mode: flow.mode, language: language)' "$ROOT/Sources/Power/PowerFlowView.swift"
grep -Fq 'MauLeafPowerStatusBadge(mode: mode, language: language)' "$ROOT/Sources/Power/PowerFlowView.swift"
if grep -Fq 'title: "供电状态"' <<< "$POPOVER_SOURCE"; then
    echo "Power source is already shown by the graph and must not be repeated" >&2
    exit 1
fi
if grep -Fq 'Text(manager.text("当前电量"))' <<< "$POPOVER_SOURCE" \
   || grep -Fq '.font(.system(size: 42,' <<< "$POPOVER_SOURCE"; then
    echo "The obsolete oversized battery percentage must not return" >&2
    exit 1
fi
if grep -Eq 'Text\("总输入"\)|Text\("充电功率"\)|powerSummaryRow\(' <<< "$POPOVER_SOURCE"; then
    echo "No extra summary strip below power-flow diagram" >&2
    exit 1
fi
# Read-only power status aligns with the inner text of the two capsule
# buttons (which have 12pt horizontal inset), not their outer borders.
POWER_READONLY_SOURCE="$(sed -n '/\/\/ Power is a read-only measurement/,/\.accessibilityLabel(/p' "$APP_AUDIT")"
grep -Fq '.padding(.trailing, 12)' <<< "$POWER_READONLY_SOURCE"
grep -Fq '.padding(.horizontal, 12)' <<< "$POPOVER_SOURCE"
grep -Fq 'spacing: 3) {' <<< "$POPOVER_SOURCE"
if grep -Eq 'componentSetupSection|installBackend|uninstallBackend' "$APP_AUDIT"; then
    echo "The legacy component installer UI must not return" >&2
    exit 1
fi
# The word "batt" is also the name of Apple's built-in `pmset -g batt`
# status subcommand. Reject legacy backend symbols and paths above, not this
# unrelated native battery-read argument.
if grep -RniE 'MAULEAF_INTEL_EXPERIMENTAL|x86_64|macos-15-intel|EXPERIMENTAL.dmg' \
    "$ROOT/Sources" "$ROOT/Scripts/ci/package-macos.sh" "$ROOT/build.command"; then
    echo "Intel build support must not ship in Preview 5." >&2
    exit 1
fi
! grep -q 'macos-15-intel' "$ROOT/.github/workflows/build-release.yml"
! grep -q 'arch: x86_64' "$ROOT/.github/workflows/build-release.yml"
! grep -q 'EXPERIMENTAL.dmg' "$ROOT/.github/workflows/build-release.yml"
[[ "$(grep -c 'arch: arm64' "$ROOT/.github/workflows/build-release.yml")" -eq 1 ]]
grep -Fq -- '--restore-original-state' "$ROOT/Sources/Helper/FirmwareLimitHelperMain.swift"
grep -Fq 'original-firmware-state.json' "$ROOT/Sources/Helper/FirmwareLimitHelperService.swift"
grep -Fq 'background-recovery.pending' "$ROOT/Support/com.local.chargecap.firmware-helper.plist"
grep -Fq 'restore-original-state.pending' "$ROOT/Sources/Helper/FirmwareLimitHelperService.swift"
grep -Fq '启用限制充电' "$APP_AUDIT"
grep -Fq '关闭限制充电' "$APP_AUDIT"
grep -Fq '@Published private(set) var menuBarLeafStyle: MenuBarLeafStyle = .green' "$APP_AUDIT"
bash -n "$ROOT/Scripts/ci/package-macos.sh"
bash "$ROOT/tests/test-diagnose-mauleaf.sh"
bash "$ROOT/tests/test-repository-discovery.sh"
grep -Fq 'Scripts/diagnose-mauleaf.sh "$NATIVE/"' "$ROOT/Scripts/ci/package-macos.sh"
bash -n "$ROOT/Scripts/ci/cleanup-after-stable.sh"
grep -Fq 'docs/releases/v${BASE_VERSION}.md' "$ROOT/.github/workflows/build-release.yml"
grep -Fq 'cleanup-after-stable.sh' "$ROOT/.github/workflows/build-release.yml"
test -s "$ROOT/docs/releases/v0.8.0.md"
bash -n "$ROOT/build.command"
bash -n "$ROOT/Scripts/install-native-firmware-helper.sh"
bash -n "$ROOT/Scripts/uninstall-native-firmware-helper.sh"
# Normal quit hands a durable job to the Helper; no synchronous restore or administrator prompt.
# Normal quit must never ask the component policy every time.
grep -Fq 'await manager.handoffQuitRecovery()' "$APP_AUDIT"
grep -Fq 'let remove = quitComponentPolicy == .remove' "$APP_AUDIT"
grep -Fq 'enqueueQuitRecovery(removeComponents: remove)' "$APP_AUDIT"
grep -Fq 'quit-recovery.pending' "$ROOT/Support/com.local.chargecap.firmware-helper.plist"
grep -Fq 'try processQuitRecoveryLocked()' "$ROOT/Sources/Helper/FirmwareLimitHelperService.swift"
grep -Fq 'removeComponentsOnQuit ? .remove : .keep' "$APP_AUDIT"
if grep -Fq 'question.runModal()' "$APP_AUDIT"; then
    echo "Normal quit must use the stored policy without a modal chooser" >&2
    exit 1
fi
grep -Fq 'static let powerFlowRefreshInterval: TimeInterval = 2' "$APP_AUDIT"
grep -Fq 'request[42] == 9 || request[42] == 5' "$ROOT/Sources/Power/LivePowerReader.swift"
if grep -Eq 'request\[42\] = 6|kSMCWriteKey' "$ROOT/Sources/Power/LivePowerReader.swift"; then
    echo "Live power sampling must never write SMC" >&2
    exit 1
fi
grep -Fq -- '--keep-components' "$ROOT/Scripts/uninstall-native-firmware-helper.sh"
grep -Fq -- '--remove-components' "$ROOT/Scripts/uninstall-native-firmware-helper.sh"
grep -Fq 'MODE="keep"' "$ROOT/Scripts/uninstall-native-firmware-helper.sh"
# No privilege on launch or read-only refresh, and Keep must never bootout.
if grep -q 'refreshNativeState(allowInstall:' "$APP_AUDIT"; then
    echo "Startup/refresh must remain read-only" >&2
    exit 1
fi
grep -Fq 'Task { await refreshNativeState() }' "$APP_AUDIT"
grep -Fq 'private func enableLimitAfterConsent() async' "$APP_AUDIT"
grep -Fq 'policy == .remove' "$APP_AUDIT"
grep -Fq 'MODE="remove"' "$ROOT/Scripts/uninstall-native-firmware-helper.sh"
grep -Fq 'launchctl bootout' "$ROOT/Scripts/uninstall-native-firmware-helper.sh"
grep -A1 '<key>RunAtLoad</key>' "$ROOT/Support/com.local.chargecap.firmware-helper.plist" | grep -Fq '<false/>'

bash -n "$ROOT/Scripts/complete-deferred-uninstall.sh"
grep -Fq 'complete-deferred-uninstall.sh' "$ROOT/Scripts/install-native-firmware-helper.sh"
grep -Fq 'complete-deferred-uninstall.sh' "$ROOT/Scripts/ci/package-macos.sh"
grep -Fq 'deferred-uninstall.pending' "$ROOT/Scripts/uninstall-native-firmware-helper.sh"
grep -Fq 'legacy-restore.json' "$ROOT/Sources/Helper/FirmwareLimitHelperService.swift"
grep -Fq 'still quit' "$ROOT/docs/releases/PREVIEW_TEMPLATE.md" || \
  grep -Fq '仍然退出' "$ROOT/docs/releases/PREVIEW_TEMPLATE.md"
# Any compatible, signed root Helper is uninstallable after verified restore.
if grep -Fq '/usr/bin/cmp -s "$TARGET" "$SOURCE_BINARY"' "$ROOT/Scripts/uninstall-native-firmware-helper.sh"; then
    echo "Do not couple uninstall to the currently bundled Helper binary." >&2
    exit 1
fi
grep -Fq 'codesign --verify --strict "$TARGET"' "$ROOT/Scripts/uninstall-native-firmware-helper.sh"
grep -Fq 'helperBuildVersion' "$ROOT/Sources/Helper/FirmwareLimitHelperProtocol.swift"
grep -Fq 'FirmwareLimitHelperProtocolVersion.isCompatible' "$APP_AUDIT"
grep -Fq 'replaceNativeHelperAfterStartupCheck' "$APP_AUDIT"
grep -Fq 'trap rollback EXIT' "$ROOT/Scripts/install-native-firmware-helper.sh"
grep -Fq 'old-helper' "$ROOT/Scripts/install-native-firmware-helper.sh"
grep -Fq 'snapshot' "$ROOT/Scripts/install-native-firmware-helper.sh"
bash -n "$ROOT/Scripts/uninstall-macos26-27.sh"
grep -Fq 'original-firmware-state.json' "$ROOT/Scripts/uninstall-macos26-27.sh"
grep -Fq 'Native MauLeaf firmware helper or recovery data is present.' "$ROOT/Scripts/uninstall-macos26-27.sh"
if [[ "$(uname -s)" == Darwin ]]; then
    plutil -lint "$ROOT/Support/com.local.chargecap.firmware-helper.plist"
fi
echo "Native-only source parsing, tests and packaging checks passed"
