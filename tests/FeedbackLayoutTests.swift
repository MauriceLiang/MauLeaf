import AppKit
import SwiftUI

@main
struct FeedbackLayoutTests {
    @MainActor
    static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mauleaf-layout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = directory.appendingPathComponent("batt")
        try "#!/bin/sh\necho 'Upper limit: 80%'\necho 'Use power adapter: true'\necho 'Power adapter control: false'\n"
            .write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        DischargeAgent.monitor = DischargeMonitor(directory: directory)
        UserDefaults.standard.set(80, forKey: "chargeLimit")
        UserDefaults.standard.set("limited", forKey: "chargeModeV5")
        UserDefaults.standard.set("adapter", forKey: "highChargePolicy")
        UserDefaults.standard.set(false, forKey: "chargeControlReleasedOnQuit")
        let manager = ChargeManager(battPath: binary.path)
        manager.start()
        manager.requestLimit(80, immediate: true)
        let deadline = Date().addingTimeInterval(3)
        while manager.autoApplyFeedback.source != "已自动应用 80%", Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        guard manager.autoApplyFeedback.source == "已自动应用 80%" else {
            fputs("FAIL: fixture limit operation did not complete\n", stderr)
            exit(1)
        }
        for language in AppLanguage.allCases {
            manager.language = language
            manager.isBusy = false
            manager.isError = false
            manager.statusMessage = ""
            let host = NSHostingView(rootView: ContentView(manager: manager).frame(width: 360))
            let overlay = NSHostingView(rootView: ContentView(manager: manager).frame(width: 360)
                .overlay(alignment: .bottom) { OperationFeedbackView(manager: manager).padding(.horizontal, 16).padding(.bottom, 44) }
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
            manager.statusMessage = "正在应用充电上限 \(85)%…"
            manager.isBusy = true
            let busy = measure()
            let busyToastHeight = toast.fittingSize.height
            manager.isBusy = false
            manager.isError = true
            manager.statusMessage = AppText(verbatim: String(repeating: language == .english
                ? "The control command failed. Check the service and retry. "
                : "控制程序执行失败，请检查服务后重试。", count: 12))
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
            print("FeedbackLayoutTests: PASS (\(language.rawValue); content and overlay height \(normal.0) pt unchanged in normal, busy and long-error states; offscreen views)")
        }
    }
}
