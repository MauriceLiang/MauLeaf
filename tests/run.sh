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
        "$ROOT/Sources/SystemFirmwareReader.swift" \
        "$ROOT/Sources/FirmwareLimitRuntime.swift" \
        "$ROOT/Sources/FirmwareLimitSMCTransport.swift" \
        "$ROOT/Sources/FirmwareLimitHelperProtocol.swift" \
        "$ROOT/Sources/FirmwareLimitHelperService.swift" \
        "$ROOT/tests/FirmwareLimitHelperServiceTests.swift" \
        -o "$TMP/firmwarehelpertests"
    "$TMP/firmwarehelpertests"

    swiftc -parse-as-library -D MAULEAF_TESTING \
        -framework SwiftUI -framework AppKit -framework Combine -framework IOKit \
        "$ROOT/Sources/MauLeaf.swift" "$ROOT/Sources/AppLocalization.swift" \
        "$ROOT/Sources/BatteryStatusReader.swift" "$ROOT/Sources/FirmwareLimitCore.swift" \
        "$ROOT/Sources/FirmwareLimitReconciliation.swift" "$ROOT/Sources/SystemFirmwareReader.swift" "$ROOT/Sources/FirmwareLimitRuntime.swift" \
        "$ROOT/Sources/FirmwareLimitHelperProtocol.swift" \
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
        -framework SwiftUI -framework AppKit -framework Combine -framework IOKit \
        "$ROOT/Sources/MauLeaf.swift" "$ROOT/Sources/AppLocalization.swift" \
        "$ROOT/Sources/BatteryStatusReader.swift" "$ROOT/Sources/FirmwareLimitCore.swift" \
        "$ROOT/Sources/FirmwareLimitReconciliation.swift" "$ROOT/Sources/SystemFirmwareReader.swift" "$ROOT/Sources/FirmwareLimitRuntime.swift" \
        "$ROOT/Sources/FirmwareLimitHelperProtocol.swift" \
        "$ROOT/Sources/FirmwareLimitHelperClient.swift" \
        "$ROOT/tests/NativeFirmwareBackendFixture.swift" "$ROOT/tests/FeedbackLayoutTests.swift" \
        "$ROOT/tests/BatteryRingRenderingTests.swift" -o "$LAYOUT_APP/Contents/MacOS/layouttests"
    "$LAYOUT_APP/Contents/MacOS/layouttests" "$ROOT/build/ui-verification"
fi

swiftc -frontend -parse \
    "$ROOT/Sources/MauLeaf.swift" "$ROOT/Sources/AppLocalization.swift" \
    "$ROOT/Sources/BatteryStatusReader.swift" "$ROOT/Sources/FirmwareLimitCore.swift" "$ROOT/Sources/FirmwareLimitReconciliation.swift" \
    "$ROOT/Sources/SystemFirmwareReader.swift" "$ROOT/Sources/FirmwareLimitRuntime.swift" "$ROOT/Sources/FirmwareLimitSMCTransport.swift" \
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
# A raw English response.message from the privileged helper must not leak to
# the user-facing operation toast; preserve the helper text only for logging.
if grep -Fq 'AppText(verbatim: response.message)' "$ROOT/Sources/MauLeaf.swift"; then
    echo "Native helper audit messages must not be shown directly in the UI" >&2
    exit 1
fi

# The approved design is one transparent borderless menu-bar panel, with
# exactly one SwiftUI floating card rather than an outer frame + inner tile.
# Charging operations remain in-row; errors still expand inline.
grep -Fq 'private final class MauLeafCardPanel: NSPanel' "$ROOT/Sources/MauLeaf.swift"
grep -Fq 'styleMask: [.borderless]' "$ROOT/Sources/MauLeaf.swift"
grep -Fq 'panel.isOpaque = false' "$ROOT/Sources/MauLeaf.swift"
grep -Fq 'panel.backgroundColor = .clear' "$ROOT/Sources/MauLeaf.swift"
grep -Fq 'panel.hasShadow = false' "$ROOT/Sources/MauLeaf.swift"
# Preview 10 uses one fixed transparent NSPanel and one SwiftUI
# animatable material shape. No temporary proxy panel may be spawned.
grep -Fq 'final class MenuCardPresentation: ObservableObject' "$ROOT/Sources/MauLeaf.swift"
grep -Fq 'private struct AnimatedFloatingCardShape: Shape' "$ROOT/Sources/MauLeaf.swift"
grep -Fq 'struct MenuCardMorphRoot: View' "$ROOT/Sources/MauLeaf.swift"
grep -Fq 'MenuCardMorphRoot(manager: manager, presentation: presentation)' "$ROOT/Sources/MauLeaf.swift"
grep -Fq 'var animatableData: AnimatablePair<CGFloat, CGFloat>' "$ROOT/Sources/MauLeaf.swift"
grep -Fq 'static let compactWidth: CGFloat = 52' "$ROOT/Sources/MauLeaf.swift"
grep -Fq 'static let compactHeight: CGFloat = 14' "$ROOT/Sources/MauLeaf.swift"
grep -Fq 'static let closeDuration: TimeInterval = 0.26' "$ROOT/Sources/MauLeaf.swift"
grep -Fq 'dampingFraction: 0.9' "$ROOT/Sources/MauLeaf.swift"
grep -Fq 'MenuCardMotion.contentOpacity(presentation.progress)' "$ROOT/Sources/MauLeaf.swift"
grep -Fq '.clipShape(shape)' "$ROOT/Sources/MauLeaf.swift"
grep -Fq 'panel.hasShadow = false' "$ROOT/Sources/MauLeaf.swift"
grep -Fq 'panel.ignoresMouseEvents = true' "$ROOT/Sources/MauLeaf.swift"
grep -Fq 'morphGeneration &+= 1' "$ROOT/Sources/MauLeaf.swift"
grep -Fq 'accessibilityDisplayShouldReduceMotion' "$ROOT/Sources/MauLeaf.swift"
[[ "$(grep -Fc 'panel = MauLeafCardPanel(' "$ROOT/Sources/MauLeaf.swift")" -eq 1 ]]
if grep -Fq 'NSPanel(contentRect:' "$ROOT/Sources/MauLeaf.swift"; then
    echo "No second NSPanel or animation proxy is permitted" >&2
    exit 1
fi
[[ "$(grep -Fc '.fill(.regularMaterial)' "$ROOT/Sources/MauLeaf.swift")" -eq 1 ]]
if grep -Eq 'morphWindow|makeMorphWindow|MenuPanelMorph|MenuPanelEntrance|NSVisualEffectView\(frame:|private struct FloatingCardShape' "$ROOT/Sources/MauLeaf.swift"; then
    echo "The Preview 9 proxy or a second static surface must not return" >&2
    exit 1
fi
# The menu control is a non-scrollable native card: a trackpad or mouse wheel
# must never move the entire popup or reveal rubber-band overscroll.
grep -Fq 'let root = MenuCardMorphRoot(manager: manager, presentation: presentation)' "$ROOT/Sources/MauLeaf.swift"
grep -Fq '.fixedSize(horizontal: false, vertical: true)' "$ROOT/Sources/MauLeaf.swift"
grep -Fq '.onPreferenceChange(PanelContentHeightPreferenceKey.self)' "$ROOT/Sources/MauLeaf.swift"
if grep -Eq 'ScrollView[[:space:]]*\\{|NSScrollView[[:space:]]*\\(' "$ROOT/Sources/MauLeaf.swift"; then
    echo "Menu bar popup must not contain a scrollable view" >&2
    exit 1
fi
# A SwiftUI disclosure transition alone cannot animate the AppKit window
# height; both layers must share the same 240ms timing and preserve the
# top edge when Settings or Charge limit expands.
grep -Fq 'private let resizeDuration: TimeInterval = 0.24' "$ROOT/Sources/MauLeaf.swift"
grep -Fq 'context.duration = resizeDuration' "$ROOT/Sources/MauLeaf.swift"
grep -Fq 'panel.animator().setFrame(targetFrame, display: true)' "$ROOT/Sources/MauLeaf.swift"
grep -Fq 'y: anchorTop - height' "$ROOT/Sources/MauLeaf.swift"
grep -Fq 'accessibilityDisplayShouldReduceMotion' "$ROOT/Sources/MauLeaf.swift"
grep -Fq 'reduceMotion ? nil : .easeInOut(duration: 0.24)' "$ROOT/Sources/MauLeaf.swift"
[[ "$(grep -Fc 'withAnimation(expansionAnimation)' "$ROOT/Sources/MauLeaf.swift")" -eq 2 ]]
[[ "$(grep -Fc '.transition(expansionTransition)' "$ROOT/Sources/MauLeaf.swift")" -eq 2 ]]
if grep -Fq 'panel.setContentSize(NSSize(width: panelWidth' "$ROOT/Sources/MauLeaf.swift"; then
    echo "Direct size changes bypass the floating card disclosure animation" >&2
    exit 1
fi
if grep -Fq 'titlebarAppearsTransparent' "$ROOT/Sources/MauLeaf.swift"; then
    echo "The extra native titlebar/frame must not return" >&2
    exit 1
fi
[[ "$(grep -Fc '.fill(.regularMaterial)' "$ROOT/Sources/MauLeaf.swift")" -eq 1 ]]
grep -Fq 'private var groupDivider: some View' "$ROOT/Sources/MauLeaf.swift"
if grep -Fq '.background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))' "$ROOT/Sources/MauLeaf.swift"; then
    echo "The nested battery status tile must not return" >&2
    exit 1
fi
# Charging operations remain in-row; errors still expand inline.
if grep -Fq '.overlay(alignment: .bottom)' "$ROOT/Sources/MauLeaf.swift"; then
    echo "Operation feedback must never overlay the bottom menu controls" >&2
    exit 1
fi
grep -Fq 'OperationFeedbackView(manager: manager)' "$ROOT/Sources/MauLeaf.swift"
grep -Fq 'activeOperation?.affectsLimit' "$ROOT/Sources/MauLeaf.swift"
grep -Fq 'activeOperation?.affectsFullCharge' "$ROOT/Sources/MauLeaf.swift"
# Keep the icon/status overview, direct card controls and inline settings.
POPOVER_SOURCE="$(sed -n '/^struct ContentView: View {/,/^\/\/\/ Error and exceptional-operation feedback/p' "$ROOT/Sources/MauLeaf.swift")"
if grep -Fq 'BatteryStatusRing(' <<< "$POPOVER_SOURCE"; then
    echo "The oversized battery ring must not return to the compact menu-bar overview" >&2
    exit 1
fi
for required in 'manager.popoverPowerStatus' 'manager.popoverLimitStatus' \
    'manager.popoverFullChargeStatus' 'limitExpanded' 'settingsExpanded' \
    'manager.toggleLimitFromCard()' 'manager.toggleFullChargeFromCard()' \
    'private var limitControls' 'NSApp.terminate(nil)'; do
    if ! grep -Fq "$required" <<< "$POPOVER_SOURCE"; then
        echo "Missing a required compact popover state or action: $required" >&2
        exit 1
    fi
done

# Both compact preferences must share the native segmented style. Never
# restore the redundant limit/full-charge switches or the mixed settings UI.
if grep -Eq 'oneTimeToggleRow|private var limitAction|Toggle\(isOn:' <<< "$POPOVER_SOURCE"; then
    echo "The compact popover must not contain old switches or lower charge actions" >&2
    exit 1
fi
grep -Fq 'Picker("", selection: $manager.showBatteryLevel)' <<< "$POPOVER_SOURCE"
grep -Fq 'Picker("", selection: $manager.language)' <<< "$POPOVER_SOURCE"
[[ "$(grep -Fc '.pickerStyle(.segmented)' <<< "$POPOVER_SOURCE")" -eq 2 ]]
[[ "$(grep -Fc '.frame(width: 142)' <<< "$POPOVER_SOURCE")" -eq 2 ]]
grep -Fq 'if manager.showBatteryLevel' <<< "$POPOVER_SOURCE"
grep -Fq 'highlighted: manager.isActivelyCharging' <<< "$POPOVER_SOURCE"
# Read-only power status aligns with the inner text of the two capsule
# buttons (which have 12pt horizontal inset), not their outer borders.
POWER_READONLY_SOURCE="$(sed -n '/\/\/ Power is a read-only measurement/,/\.accessibilityLabel(/p' "$ROOT/Sources/MauLeaf.swift")"
grep -Fq '.padding(.trailing, 12)' <<< "$POWER_READONLY_SOURCE"
grep -Fq '.padding(.horizontal, 12)' <<< "$POPOVER_SOURCE"
grep -Fq 'spacing: 3) {' <<< "$POPOVER_SOURCE"
if grep -Eq 'componentSetupSection|installBackend|uninstallBackend' "$ROOT/Sources/MauLeaf.swift"; then
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
grep -Fq -- '--restore-original-state' "$ROOT/Sources/FirmwareLimitHelperMain.swift"
grep -Fq 'original-firmware-state.json' "$ROOT/Sources/FirmwareLimitHelperService.swift"
grep -Fq 'background-recovery.pending' "$ROOT/Support/com.local.chargecap.firmware-helper.plist"
grep -Fq 'restore-original-state.pending' "$ROOT/Sources/FirmwareLimitHelperService.swift"
grep -Fq '启用限制充电' "$ROOT/Sources/MauLeaf.swift"
grep -Fq '关闭限制充电' "$ROOT/Sources/MauLeaf.swift"
grep -Fq '@Published private(set) var menuBarLeafStyle: MenuBarLeafStyle = .green' "$ROOT/Sources/MauLeaf.swift"
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
# Normal quit restores first; Keep retains launchd registration, Remove needs administrator authorization.
grep -Fq -- '--keep-components' "$ROOT/Scripts/uninstall-native-firmware-helper.sh"
grep -Fq -- '--remove-components' "$ROOT/Scripts/uninstall-native-firmware-helper.sh"
grep -Fq 'MODE="keep"' "$ROOT/Scripts/uninstall-native-firmware-helper.sh"
# No privilege on launch or read-only refresh, and Keep must never bootout.
if grep -q 'refreshNativeState(allowInstall:' "$ROOT/Sources/MauLeaf.swift"; then
    echo "Startup/refresh must remain read-only" >&2
    exit 1
fi
grep -Fq 'Task { await refreshNativeState() }' "$ROOT/Sources/MauLeaf.swift"
grep -Fq 'private func enableLimitAfterConsent() async' "$ROOT/Sources/MauLeaf.swift"
grep -Fq 'policy == .remove' "$ROOT/Sources/MauLeaf.swift"
grep -Fq 'MODE="remove"' "$ROOT/Scripts/uninstall-native-firmware-helper.sh"
grep -Fq 'launchctl bootout' "$ROOT/Scripts/uninstall-native-firmware-helper.sh"
grep -A1 '<key>RunAtLoad</key>' "$ROOT/Support/com.local.chargecap.firmware-helper.plist" | grep -Fq '<false/>'

bash -n "$ROOT/Scripts/complete-deferred-uninstall.sh"
grep -Fq 'complete-deferred-uninstall.sh' "$ROOT/Scripts/install-native-firmware-helper.sh"
grep -Fq 'complete-deferred-uninstall.sh' "$ROOT/Scripts/ci/package-macos.sh"
grep -Fq 'deferred-uninstall.pending' "$ROOT/Scripts/uninstall-native-firmware-helper.sh"
grep -Fq 'legacy-restore.json' "$ROOT/Sources/FirmwareLimitHelperService.swift"
grep -Fq 'still quit' "$ROOT/docs/releases/PREVIEW_TEMPLATE.md" || \
  grep -Fq '仍然退出' "$ROOT/docs/releases/PREVIEW_TEMPLATE.md"
grep -Fq '/usr/bin/cmp -s "$TARGET" "$SOURCE_BINARY"' "$ROOT/Scripts/uninstall-native-firmware-helper.sh"
bash -n "$ROOT/Scripts/uninstall-macos26-27.sh"
grep -Fq 'original-firmware-state.json' "$ROOT/Scripts/uninstall-macos26-27.sh"
grep -Fq 'Native MauLeaf firmware helper or recovery data is present.' "$ROOT/Scripts/uninstall-macos26-27.sh"
if [[ "$(uname -s)" == Darwin ]]; then
    plutil -lint "$ROOT/Support/com.local.chargecap.firmware-helper.plist"
fi
echo "Native-only source parsing, tests and packaging checks passed"
