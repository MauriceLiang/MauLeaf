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
        manager.requestLimit(80, immediate: true)
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
            let host = NSHostingView(rootView: ContentView(manager: manager).frame(width: 360))
            let overlay = NSHostingView(rootView: ContentView(manager: manager).frame(width: 360)
                .overlay(alignment: .bottom) {
                    OperationFeedbackView(manager: manager).padding(.horizontal, 16).padding(.bottom, 44)
                }
                .environment(\.colorScheme, .dark))
            let toast = NSHostingView(rootView: OperationFeedbackView(manager: manager).frame(width: 328))

            func measure() -> (CGFloat, CGFloat) {
                RunLoop.main.run(until: Date().addingTimeInterval(0.03))
                host.layoutSubtreeIfNeeded()
                overlay.layoutSubtreeIfNeeded()
                toast.layoutSubtreeIfNeeded()
                return (host.fittingSize.height, overlay.fittingSize.height)
            }
            let normal = measure()
            let normalToastHeight = toast.fittingSize.height
            manager.statusMessage = "正在写入原生固件充电上限 85%…"
            manager.isBusy = true
            let busy = measure()
            let busyToastHeight = toast.fittingSize.height
            manager.isBusy = false
            manager.isError = true
            manager.statusMessage = AppText(verbatim: String(repeating: language == .english
                ? "The native firmware write failed. Check AC power and retry. "
                : "原生固件写入失败，请检查电源和设备状态后重试。", count: 12))
            manager.autoApplyFeedback = manager.statusMessage
            let failure = measure()
            let failureToastHeight = toast.fittingSize.height
            guard normal.0 > 0,
                  normalToastHeight == 0, busyToastHeight > 0, failureToastHeight > 0,
                  abs(normal.0 - busy.0) < 0.5, abs(normal.0 - failure.0) < 0.5,
                  abs(normal.1 - busy.1) < 0.5, abs(normal.1 - failure.1) < 0.5,
                  abs(normal.0 - normal.1) < 0.5 else {
                fputs("FAIL: feedback layout: normal=\(normal), busy=\(busy), failure=\(failure); toast heights=\(normalToastHeight), \(busyToastHeight), \(failureToastHeight)\n", stderr)
                exit(1)
            }
            print("FeedbackLayoutTests: PASS (\(language.rawValue); content and overlay height \(normal.0) pt unchanged)")
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
