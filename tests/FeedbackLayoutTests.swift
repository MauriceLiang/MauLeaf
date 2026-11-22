import AppKit
import SwiftUI

@main
struct FeedbackLayoutTests {
    @MainActor
    static func main() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        // Static geometry: the native menu popup has one full-sized
        // rounded surface and pointer; there is no compact morph endpoint.
        for height in [292.0, 374.0, 510.0] {
            let rect = CGRect(x: 0, y: 0, width: 360, height: height)
            let path = FloatingCardShape().path(in: rect)
            let outline = path.boundingRect
            guard abs(outline.minX - rect.minX) < 0.01,
                  abs(outline.minY - rect.minY) < 0.01,
                  abs(outline.width - rect.width) < 0.01,
                  abs(outline.height - rect.height) < 0.01 else {
                fatalError("The static popup shape must cover the full card")
            }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mauleaf-layout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        UserDefaults.standard.set(80, forKey: "chargeLimit")
        UserDefaults.standard.removeObject(forKey: "showBatteryLevel")
        UserDefaults.standard.set(true, forKey: "nativeFirmwareWriteConfirmed")
        let backend = FixtureNativeFirmwareBackend()
        let manager = ChargeManager(backend: backend, autoInstallNativeHelper: false)
        manager.start()
        try await wait { manager.backendReady }
        manager.isAdapterConnected = true
        manager.batteryPercent = 80
        manager.enableLimit()
        try await wait { backend.applyCount == 1 && !manager.isBusy }

        guard manager.menuBarLeafStyle == .green else {
            fatalError("The menu-bar leaf must remain fixed to green.")
        }
        guard let leafURL = Bundle.main.url(forResource: "MenuBarLeafTemplate", withExtension: "png"),
              let leaf = NSImage(contentsOf: leafURL), leaf.isValid else {
            fatalError("The actual brand leaf template must be bundled for UI tests")
        }
        let sourceLeaf = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Assets/MenuBarLeafTemplate.png")
        guard try Data(contentsOf: leafURL) == Data(contentsOf: sourceLeaf) else {
            fatalError("Bundled leaf must match the canonical brand template")
        }

        let renderOutput = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try verifyBatteryRingRendering(outputDirectory: renderOutput)

        for language in AppLanguage.allCases {
            manager.language = language
            manager.isBusy = false
            manager.isError = false
            manager.statusMessage = ""
            let host = NSHostingView(rootView: ContentView(manager: manager).frame(width: 360)
                .environment(\.colorScheme, .dark))
            let feedback = NSHostingView(rootView: OperationFeedbackView(manager: manager).frame(width: 328)
                .environment(\.colorScheme, .dark))

            func measure() -> (CGFloat, CGFloat) {
                RunLoop.main.run(until: Date().addingTimeInterval(0.04))
                host.layoutSubtreeIfNeeded()
                feedback.layoutSubtreeIfNeeded()
                return (host.fittingSize.height, feedback.fittingSize.height)
            }
            let normal = measure()
            // Exercise the same NON-SCROLLING root that the real panel
            // hosts, including intrinsic height and static card background.
            let panelHost = NSHostingView(rootView:
                ContentView(manager: manager)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 360)
                    .environment(\.colorScheme, .dark))
            panelHost.layoutSubtreeIfNeeded()
            func containsScrollView(_ view: NSView) -> Bool {
                if view is NSScrollView { return true }
                return view.subviews.contains(where: containsScrollView)
            }
            guard !containsScrollView(panelHost),
                  abs(panelHost.fittingSize.height - normal.0) < 5 else {
                fputs("FAIL: popup must size intrinsically without an NSScrollView: panel=\(panelHost.fittingSize.height), content=\(normal.0)\n", stderr)
                exit(1)
            }
            // Exercise both disclosure layouts in each language. They must
            // grow the same single-card popover, not overlay or replace it.
            func measuredDisclosureHeight(limit: Bool, settings: Bool) -> CGFloat {
                let view = ContentView(manager: manager,
                                       initiallyExpandedLimit: limit,
                                       initiallyExpandedSettings: settings)
                let expandedHost = NSHostingView(rootView: view.frame(width: 360)
                    .environment(\.colorScheme, .dark))
                expandedHost.layoutSubtreeIfNeeded()
                return expandedHost.fittingSize.height
            }
            let limitOpenHeight = measuredDisclosureHeight(limit: true, settings: false)
            let settingsOpenHeight = measuredDisclosureHeight(limit: false, settings: true)
            guard limitOpenHeight > normal.0 + 35,
                  settingsOpenHeight > normal.0 + 35,
                  limitOpenHeight < normal.0 + 220,
                  settingsOpenHeight < normal.0 + 280 else {
                fputs("FAIL: disclosure must grow the existing card: normal=\(normal.0), limit=\(limitOpenHeight), settings=\(settingsOpenHeight)\n", stderr)
                exit(1)
            }
            guard (275...335).contains(normal.0) else {
                fputs("FAIL: single-card compact popover height unexpected: \(normal.0)\n", stderr)
                exit(1)
            }
            // Measure each piece separately: the closed battery card must
            // actually reclaim space, not merely shrink its outer popover.
            // Each isolated card hosts a fresh view because the observed
            // ContentView wrapper is not mounted when extracting this private
            // subview. Reusing that detached host would retain stale state.
            func measuredCardHeight() -> CGFloat {
                let cardHost = NSHostingView(rootView: ContentView(manager: manager)
                    .batteryCardForTesting.frame(width: 328)
                    .environment(\.colorScheme, .dark))
                cardHost.layoutSubtreeIfNeeded()
                return cardHost.fittingSize.height
            }
            let settingsHost = NSHostingView(rootView: ContentView(manager: manager)
                .settingsControlsForTesting.frame(width: 298)
                .environment(\.colorScheme, .dark))
            settingsHost.layoutSubtreeIfNeeded()
            let compactCardHeight = measuredCardHeight()
            let compactSettingsHeight = settingsHost.fittingSize.height
            // Preview 6 removes 26pt of nested card padding/background:
            // the overview is now an unframed content group in one card.
            guard (100...123).contains(compactCardHeight),
                  (125...220).contains(compactSettingsHeight) else {
                fputs("FAIL: compact overview/settings are too tall in \(language.rawValue): card=\(compactCardHeight), settings=\(compactSettingsHeight)\n", stderr)
                exit(1)
            }
            guard !manager.showBatteryLevel else {
                fatalError("Compact mode must be the default.")
            }
            manager.showBatteryLevel = true
            try await Task.sleep(nanoseconds: 280_000_000)
            let expanded = measure()
            panelHost.layoutSubtreeIfNeeded()
            guard panelHost.fittingSize.height > normal.0 + 40,
                  !containsScrollView(panelHost) else {
                fputs("FAIL: non-scrolling popup did not grow with optional battery header\n", stderr)
                exit(1)
            }
            let expandedCardHeight = measuredCardHeight()
            guard expandedCardHeight > compactCardHeight + 40,
                  expanded.0 > normal.0 + 40 && expanded.1 == 0
                  && UserDefaults.standard.bool(forKey: "showBatteryLevel") else {
                fputs("FAIL: optional battery display should expand the panel without an overlay: compact=\(normal), expanded=\(expanded), isolated cards=\(compactCardHeight)/\(expandedCardHeight)\n", stderr)
                exit(1)
            }
            manager.showBatteryLevel = false
            try await Task.sleep(nanoseconds: 280_000_000)
            let compactAgain = measure()
            let restoredCardHeight = measuredCardHeight()
            guard abs(restoredCardHeight - compactCardHeight) < 1.5,
                  abs(compactAgain.0 - normal.0) < 1.5
                  && !UserDefaults.standard.bool(forKey: "showBatteryLevel") else {
                fputs("FAIL: disabling battery level should reclaim header space: normal=\(normal), compactAgain=\(compactAgain)\n", stderr)
                exit(1)
            }
            for supplyState in ["正在充电", "已接电源，未充电", "已接电源，已充满", "电池供电", "电池状态不可用"] {
                manager.batteryStateText = supplyState
                let variant = measure()
                guard abs(variant.0 - normal.0) < 1.5 && variant.1 == 0 else {
                    fputs("FAIL: supply status unexpectedly wrapped in \(language.rawValue): \(supplyState), normal=\(normal), variant=\(variant)\n", stderr)
                    exit(1)
                }
            }
            manager.statusMessage = "正在写入原生固件充电上限 85%…"
            manager.setFeedbackOperationForTesting(.adjustingLimit)
            manager.isBusy = true
            let busy = measure()
            let limitProgress = manager.text(manager.popoverLimitStatus)
            manager.isBusy = false
            manager.setFeedbackOperationForTesting(nil)
            manager.isError = false
            manager.statusMessage = "充电上限已设为 85%，固件写入已验证。"
            let success = measure()
            manager.isError = true
            manager.statusMessage = AppText(verbatim: String(repeating: language == .english
                ? "The native firmware write failed. Check AC power and retry. "
                : "原生固件写入失败，请检查电源和设备状态后重试。", count: 12))
            manager.autoApplyFeedback = manager.statusMessage
            let failure = measure()
            guard normal.0 > 0,
                  normal.1 == 0, busy.1 == 0, success.1 == 0, failure.1 > 0,
                  limitProgress == manager.text("正在设置…"),
                  failure.0 > normal.0 + 20,
                  abs(normal.0 - success.0) < 1,
                  abs(normal.0 - busy.0) < 20 else {
                fputs("FAIL: inline feedback layout: normal=\(normal), busy=\(busy), success=\(success), failure=\(failure); progress=\(limitProgress)\n", stderr)
                exit(1)
            }
            print("FeedbackLayoutTests: PASS (\(language.rawValue); single card=\(normal.0)pt, expanded limit=\(limitOpenHeight)pt, expanded settings=\(settingsOpenHeight)pt, status group=\(compactCardHeight)pt, optional battery and inline feedback)")
        }
        _ = await manager.prepareForTermination()
        UserDefaults.standard.removeObject(forKey: "nativeFirmwareWriteConfirmed")
        UserDefaults.standard.removeObject(forKey: "showBatteryLevel")
    }

    @MainActor
    static func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<300 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw NSError(domain: "FeedbackLayoutTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for fixture backend"])
    }
}
