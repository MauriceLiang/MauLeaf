import AppKit
import SwiftUI

@main
struct FeedbackLayoutTests {
    @MainActor
    static func main() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mauleaf-layout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        UserDefaults.standard.set(80, forKey: "chargeLimit")
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
            print("FeedbackLayoutTests: PASS (\(language.rawValue); in-card progress, inline errors, no overlay)")
        }
        _ = await manager.prepareForTermination()
        UserDefaults.standard.removeObject(forKey: "nativeFirmwareWriteConfirmed")
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
