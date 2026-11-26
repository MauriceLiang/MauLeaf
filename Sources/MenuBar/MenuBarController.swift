import SwiftUI
import AppKit
import Combine
import Foundation
import QuartzCore

extension Notification.Name {
}

/// Measure the real SwiftUI content inside the scroll view. The panel height
/// follows this value unless there is insufficient room on the current screen.
private struct PanelContentHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// A key-capable borderless panel preserves keyboard focus, SwiftUI
/// controls and safety confirmations while avoiding the extra macOS window
/// chrome around the single floating card.
private final class MauLeafCardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// One permanent rounded popover surface; no morph, proxy or entrance
/// animation. The small pointer is part of the static shape.
struct FloatingCardShape: Shape {
    func path(in rect: CGRect) -> Path {
        let arrowHeight: CGFloat = 8
        let arrowHalfWidth: CGFloat = 10
        let body = CGRect(x: rect.minX, y: rect.minY + arrowHeight,
                          width: rect.width, height: max(0, rect.height - arrowHeight))
        var path = Path(roundedRect: body, cornerRadius: 20)
        var pointer = Path()
        pointer.move(to: CGPoint(x: rect.midX - arrowHalfWidth, y: body.minY))
        pointer.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
        pointer.addLine(to: CGPoint(x: rect.midX + arrowHalfWidth, y: body.minY))
        pointer.closeSubpath()
        path.addPath(pointer)
        return path
    }
}

@MainActor
final class MauLeafMenuController: NSObject {
    private let manager = ChargeManager()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let panel: NSPanel
    private var refreshSubscription: AnyCancellable?
    private var appearanceSubscription: AnyCancellable?
    private var renderedLeafStyle: MenuBarLeafStyle?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private let panelWidth: CGFloat = 360
    private var measuredContentHeight: CGFloat = 0
    private var lastTargetFrame: NSRect?
    private var allowAnimatedResizes = false
    private let resizeDuration: TimeInterval = 0.24

    override init() {
        panel = MauLeafCardPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 480),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.title = "MauLeaf"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The SwiftUI card draws its own rounded shadow, not the panel's
        // rectangular window shadow.
        panel.hasShadow = false
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]

        // A native menu-bar control panel must not behave like a webpage:
        // no ScrollView, wheel scrolling or trackpad rubber-band movement.
        // Layout itself determines the height; Settings/limit expansion and
        // inline errors still trigger the measured NSPanel frame resize.
        let root = ContentView(manager: manager)
            .fixedSize(horizontal: false, vertical: true)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: PanelContentHeightPreferenceKey.self,
                        value: proxy.size.height
                    )
                }
            }
        .onPreferenceChange(PanelContentHeightPreferenceKey.self) { [weak self] height in
            // Layout callbacks must not synchronously resize the AppKit window
            // while SwiftUI is still calculating its layout.
            DispatchQueue.main.async { [weak self] in
                self?.updateContentHeight(height)
            }
        }
        .background(Color.clear)
        .ignoresSafeArea(.container, edges: .top)
        .frame(width: panelWidth)
        panel.contentView = NSHostingView(rootView: root)
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.backgroundColor = NSColor.clear.cgColor

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePanel)
            button.imageScaling = .scaleProportionallyDown
            button.imagePosition = .imageOnly
            button.toolTip = manager.text("MauLeaf · 充电控制")
        }

        refreshSubscription = manager.objectWillChange.sink { [weak self] _ in
            // @Published fires before the stored value changes.
            DispatchQueue.main.async { [weak self] in self?.updateStatusItem() }
        }
        appearanceSubscription = manager.$appearance.removeDuplicates().sink { [weak self] appearance in
            self?.applyAppearance(appearance)
        }
        updateStatusItem()
        manager.start()
    }

    private func applyAppearance(_ appearance: AppAppearance) {
        let native: NSAppearance?
        switch appearance {
        case .system: native = nil
        case .light: native = NSAppearance(named: .aqua)
        case .dark: native = NSAppearance(named: .darkAqua)
        }
        panel.appearance = native
        panel.contentView?.appearance = native
        panel.contentView?.needsDisplay = true
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        // A single, always-present leaf glyph. Never show battery, charge state,
        // percentages or text inside the macOS menu bar.
        if renderedLeafStyle != manager.menuBarLeafStyle {
            button.title = ""
            button.attributedTitle = NSAttributedString(string: "")
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.image = LeafAssets.menuBarImage(style: manager.menuBarLeafStyle)
            renderedLeafStyle = manager.menuBarLeafStyle
        }
        button.setAccessibilityLabel(manager.text("MauLeaf · 电池养护"))
        let tooltip = manager.text(manager.menuBarAccessibilityText)
        if button.toolTip != tooltip { button.toolTip = tooltip }
    }

    func prepareForTermination() async -> Bool {
        // Normal quit follows the saved setting without interrupting the user.
        // An emergency alert is still required if firmware restoration fails.
        guard !(await manager.handoffQuitRecovery()) else { return true }

        positionPanel()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        startOutsideClickMonitoring()
        manager.setPanelVisible(true)

        // An unverified recovery is NOT a successful normal quit. Offer an
        // explicit emergency choice while preserving the root-owned snapshot
        // and helper for recovery; never imply Finder deletion is safe.
        let alert = NSAlert()
        alert.window.appearance = panel.appearance
        alert.alertStyle = .warning
        alert.messageText = manager.text("无法验证充电限制恢复")
        alert.informativeText = manager.text("未能确认后台服务已接收恢复任务。请返回应用重试；若选择仍然退出，请勿直接删除 App 或 Helper。")
        alert.addButton(withTitle: manager.text("仍然退出"))
        alert.addButton(withTitle: manager.text("返回应用"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    @objc private func togglePanel() {
        if panel.isVisible {
            // A confirmation or privileged operation must never lose
            // the panel simply because the status icon was clicked.
            if panel.attachedSheet != nil || manager.isBusy {
                NSApp.activate(ignoringOtherApps: true)
                panel.makeKeyAndOrderFront(nil)
                return
            }
            dismissPanelIfAllowed()
            return
        }
        // Open immediately. No SwiftUI morph state, fade, delayed callback,
        // second NSPanel or transient compact shell.
        allowAnimatedResizes = false
        lastTargetFrame = nil
        positionPanel()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        startOutsideClickMonitoring()
        manager.refresh()
        manager.setPanelVisible(true)
    }

    private func startOutsideClickMonitoring() {
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if globalMouseMonitor == nil {
            // Global monitors receive clicks delivered to other applications.
            globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] _ in
                self?.dismissPanelIfAllowed()
            }
        }
        if localMouseMonitor == nil {
            localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: clicks) { [weak self] event in
                guard let self else { return event }
                // Let the status button perform its own toggle, and keep all
                // clicks inside the panel available to SwiftUI controls.
                if event.window !== self.panel && event.window !== self.statusItem.button?.window {
                    self.dismissPanelIfAllowed()
                }
                return event
            }
        }
    }

    private func dismissPanelIfAllowed() {
        guard panel.isVisible, panel.attachedSheet == nil,
              !manager.isBusy else { return }
        // Closing is immediate and restores normal pointer interaction.
        panel.orderOut(nil)
        allowAnimatedResizes = false
        manager.setPanelVisible(false)
        if let monitor = globalMouseMonitor {
            NSEvent.removeMonitor(monitor)
            globalMouseMonitor = nil
        }
        if let monitor = localMouseMonitor {
            NSEvent.removeMonitor(monitor)
            localMouseMonitor = nil
        }
    }

    private func updateContentHeight(_ height: CGFloat) {
        guard height.isFinite, height > 100 else { return }
        // Ignore sub-point geometry noise to avoid resize/layout loops.
        guard abs(height - measuredContentHeight) >= 1 else { return }
        measuredContentHeight = height
        if panel.isVisible {
            // The first visible size correction is immediate; only an
            // explicit in-card disclosure animates the subsequent height.
            positionPanel(animatedHeight: allowAnimatedResizes)
            allowAnimatedResizes = true
        }
    }

    private func positionPanel(animatedHeight: Bool = false) {
        guard let button = statusItem.button, let window = button.window else { return }
        let screen = window.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let menuRect = window.convertToScreen(button.convert(button.bounds, to: nil))

        // The TOP edge remains anchored beneath the menu bar. Animate the
        // height and y-origin as one transaction instead of snapping both.
        let anchorTop = min(menuRect.minY - 5, visible.maxY - 2)
        let maxHeight = max(120, anchorTop - visible.minY - 6)
        let wantedHeight = measuredContentHeight > 0 ? ceil(measuredContentHeight + 2) : 294
        let height = min(max(wantedHeight, 160), maxHeight)
        let x = min(max(menuRect.midX - panelWidth / 2, visible.minX + 6), visible.maxX - panelWidth - 6)
        let targetFrame = NSRect(x: x, y: anchorTop - height, width: panelWidth, height: height)

        // Compare target frames, not a partially animated presentation frame.
        if let last = lastTargetFrame,
           abs(targetFrame.minX - last.minX) < 1,
           abs(targetFrame.minY - last.minY) < 1,
           abs(targetFrame.height - last.height) < 1 {
            return
        }
        let oldTarget = lastTargetFrame
        lastTargetFrame = targetFrame
        let heightChanged = oldTarget.map { abs($0.height - height) >= 1 } ?? false
        let shouldAnimate = panel.isVisible && animatedHeight && heightChanged
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if shouldAnimate {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = resizeDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(targetFrame, display: true)
            } completionHandler: { [weak self] in
                self?.panel.invalidateShadow()
            }
        } else {
            panel.setFrame(targetFrame, display: true)
            panel.invalidateShadow()
        }
    }
}
