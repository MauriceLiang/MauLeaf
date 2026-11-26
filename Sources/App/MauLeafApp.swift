import SwiftUI
import AppKit
import Combine
import Foundation
import QuartzCore

/// AppKit owns the menu-bar button and a persistent panel. The old MenuBarExtra
/// transient window could disappear during confirmation and authorization,
/// leaving SwiftUI alerts behind when reopened.
#if !MAULEAF_TESTING
@main
struct MauLeafApp: App {
    @NSApplicationDelegateAdaptor(MauLeafAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}
#endif

/// Both choices restore the original SMC state before the app can quit.
enum QuitComponentPolicy: String {
    case keep = "--keep-components"
    case remove = "--remove-components"
}

@MainActor
final class MauLeafAppDelegate: NSObject, NSApplicationDelegate {
    private var controller: MauLeafMenuController?
    private var terminationPending = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        // Retire the 1.2 preference without changing any charging settings.
        UserDefaults.standard.removeObject(forKey: "appAppearance")
        controller = MauLeafMenuController()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let controller else { return .terminateNow }
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        Task { @MainActor in
            let allowed = await controller.prepareForTermination()
            terminationPending = false
            sender.reply(toApplicationShouldTerminate: allowed)
        }
        return .terminateLater
    }
}
