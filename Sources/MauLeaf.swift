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
private final class MauLeafMenuController: NSObject {
    private let manager = ChargeManager()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let panel: NSPanel
    private var refreshSubscription: AnyCancellable?
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
        updateStatusItem()
        manager.start()
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
        let policy = manager.quitComponentPolicy
        let restored = await manager.prepareForTermination()
        var completed = false
        if restored {
            completed = await manager.finishQuitComponentCleanup(policy)
        }
        guard !completed else { return true }

        positionPanel()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        startOutsideClickMonitoring()
        manager.setPanelVisible(true)

        // An unverified recovery is NOT a successful normal quit. Offer an
        // explicit emergency choice while preserving the root-owned snapshot
        // and helper for recovery; never imply Finder deletion is safe.
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = manager.didVerifyFirmwareOnQuit
            ? manager.text("固件已恢复，但后台组件未处理完成")
            : manager.text("无法验证充电限制恢复")
        alert.informativeText = manager.didVerifyFirmwareOnQuit
            ? manager.text("原始固件已恢复，但 Helper 停止或脚本清理失败。建议返回应用重试；如果仍然退出，请勿直接删除 App，以免留下系统后台组件。")
            : manager.text("原始固件配置尚未确认恢复。建议返回应用，连接电源或排查原因后重试退出。如果选择「仍然退出」，后台 Helper 和恢复快照会保留以尝试修复；此时不能直接将 MauLeaf.app 扔进废纸篓，否则可能留下后台服务或限充状态。")
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

/// Single-leaf branding shared between Finder, the panel, and the menu bar.
/// A template image is essential for legibility in both macOS light and dark menu bars.
private enum LeafAssets {
    static let templateName = "MenuBarLeafTemplate"

    static func appImage() -> NSImage? {
        guard let url = Bundle.main.url(forResource: "MauLeafIcon", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }

    static func menuBarImage(style: MenuBarLeafStyle) -> NSImage {
        let base = (Bundle.main.url(forResource: templateName, withExtension: "png").flatMap(NSImage.init(contentsOf:))
                    ?? NSImage(systemSymbolName: "leaf.fill", accessibilityDescription: "MauLeaf")
                    ?? NSImage())
        base.size = NSSize(width: 17, height: 17)
        switch style {
        case .monochrome:
            let image = base.copy() as? NSImage ?? base
            image.size = NSSize(width: 17, height: 17)
            image.isTemplate = true
            return image
        case .green:
            return tinted(image: base, color: NSColor.systemGreen)
        }
    }

    private static func tinted(image: NSImage, color: NSColor) -> NSImage {
        let size = NSSize(width: 17, height: 17)
        let tinted = NSImage(size: size)
        tinted.lockFocus()
        color.set()
        let rect = NSRect(origin: .zero, size: size)
        image.draw(in: rect)
        rect.fill(using: .sourceIn)
        tinted.unlockFocus()
        tinted.size = size
        tinted.isTemplate = false
        return tinted
    }
}



enum BatteryRingIcon: Hashable {
    case charging
    case adapter
    case battery
}

enum MenuBarLeafStyle {
    case monochrome
    case green
}

/// Kept as a small view so tests render the same ring displayed in the panel.
struct BatteryStatusRing: View {
    let percent: Int?
    let tint: Color
    let icon: BatteryRingIcon?

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.09), lineWidth: 7)
            Circle()
                .trim(from: 0, to: CGFloat(percent ?? 0) / 100)
                .stroke(tint, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if let icon {
                centerImage(icon)
                    .font(.system(size: 26, weight: .semibold))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(Color.primary.opacity(0.85))
                    .frame(width: 36, height: 36)
                    .id(icon)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: icon)
        .accessibilityHidden(true)
        .frame(width: 68, height: 68)
    }

    @ViewBuilder
    private func centerImage(_ icon: BatteryRingIcon) -> some View {
        if icon == .battery {
            // Loose bundle PNGs must be loaded explicitly; SwiftUI's named
            // lookup can produce an empty image without an asset catalog.
            Image(nsImage: LeafAssets.menuBarImage(style: .monochrome))
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 28, height: 28)
        } else {
            Image(systemName: icon == .charging ? "bolt.fill" : "powerplug.fill")
        }
    }
}

/// Native menu-bar-only popover. No detached main window or navigation.
struct ContentView: View {
    @ObservedObject var manager: ChargeManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var limitExpanded = false
    @State private var settingsExpanded = false
    private var expansionAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.24)
    }
    private var expansionTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -6))
    }
    private let presets = [70, 75, 80, 85, 90, 95]

    init(manager: ChargeManager) {
        self.manager = manager
    }

    #if MAULEAF_LAYOUT_TESTING
    init(manager: ChargeManager, initiallyExpandedLimit: Bool, initiallyExpandedSettings: Bool) {
        self.manager = manager
        self._limitExpanded = State(initialValue: initiallyExpandedLimit)
        self._settingsExpanded = State(initialValue: initiallyExpandedSettings)
    }
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // All six primary rows belong to the same visual surface.
            // Only the internal divider distinguishes charging from settings.
            batteryCard

            // Errors expand the same card; they never cover menu actions.
            OperationFeedbackView(manager: manager)
            groupDivider

            menuRow(
                icon: "slider.horizontal.3",
                title: "充电上限",
                value: "\(manager.limit)%",
                expanded: limitExpanded
            ) {
                withAnimation(expansionAnimation) {
                    limitExpanded.toggle()
                    if limitExpanded { settingsExpanded = false }
                }
            }

            if limitExpanded {
                limitControls
                    .padding(.leading, 30)
                    .padding(.trailing, 2)
                    .padding(.bottom, 12)
                    .transition(expansionTransition)
            }
            rowDivider

            menuRow(
                icon: "gearshape",
                title: "设置",
                expanded: settingsExpanded
            ) {
                withAnimation(expansionAnimation) {
                    settingsExpanded.toggle()
                    if settingsExpanded { limitExpanded = false }
                }
            }

            if settingsExpanded {
                settingsControls
                    .padding(.leading, 30)
                    .padding(.bottom, 10)
                    .transition(expansionTransition)
            }
            rowDivider

            Button {
                NSApp.terminate(nil)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "power")
                        .font(.system(size: 16, weight: .medium))
                        .frame(width: 20)
                    Text(manager.text("退出 MauLeaf"))
                        .font(.subheadline.weight(.medium))
                    Spacer()
                }
                .contentShape(Rectangle())
                .padding(.vertical, 11)
            }
            .buttonStyle(.plain)
            .disabled(manager.isPreparingToQuit)
            .help(manager.text("正常退出会先关闭限制充电并验证恢复。若无法安全恢复，将取消退出。"))
        }
        .padding(.horizontal, 17)
        .padding(.top, 22)
        .padding(.bottom, 15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipShape(FloatingCardShape())
        .background {
            FloatingCardShape()
                .fill(.regularMaterial)
                .overlay {
                    FloatingCardShape()
                        .fill(Color(nsColor: .windowBackgroundColor).opacity(0.28))
                }
                .clipShape(FloatingCardShape())
                .shadow(color: .black.opacity(0.20), radius: 7, x: 0, y: 3)
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 6)
        .alert(manager.text("启用原生固件控制？"), isPresented: $manager.showNativeWriteConfirmation) {
            Button(manager.text("确认并继续"), role: .destructive) {
                manager.confirmNativeWrite()
            }
            Button(manager.text("取消"), role: .cancel) {
                manager.cancelNativeWrite()
            }
        } message: {
            Text(manager.text("此操作会直接修改本机 AppleSMC 固件充电寄存器。仅支持已限定的 MacBookPro18,1、指定固件和 macOS 15，并且必须连接电源。程序会逐项读回校验并在失败时尝试恢复；寄存器写入成功仍不代表实际充电停止点已经验证。"))
        }
        .alert(manager.text("检测到旧版充电限制"), isPresented: $manager.showLegacyDisableConfirmation) {
            Button(manager.text("停用旧版限制"), role: .destructive) {
                manager.confirmDisableLegacyLimit()
            }
            Button(manager.text("取消"), role: .cancel) {}
        } message: {
            Text(manager.text("当前固件限充没有 MauLeaf 原始快照。无法确认这些值是否由 Preview 4 或其他工具设置。继续操作只会清除 bfF0 激活标志，并保留 bfD0、bfE0 当前值；无法恢复历史阈值。"))
        }
        .alert(manager.text("强制重置充电控制？"), isPresented: $manager.showForceResetConfirmation) {
            Button(manager.text("强制重置"), role: .destructive) {
                manager.confirmForceReset()
            }
            Button(manager.text("取消"), role: .cancel) {}
        } message: {
            Text(manager.text("取消本次充满及自动限充，恢复已保存的原始固件配置。不会删除无法确认的恢复数据，也不会重置 macOS 或电池。"))
        }
        .task { manager.start() }
    }

    /// Power flow replaces oversized battery digits. In compact mode the
    /// same source-state badge remains visible without any watt diagram.
    private var batteryCard: some View {
        VStack(alignment: .leading, spacing: 3) {
            if manager.showPowerFlow {
                MauLeafPowerFlowView(flow: manager.powerFlow, language: manager.language)
                    .padding(.bottom, 8)
                    .transition(.opacity)
            } else {
                // Hiding the chart never hides power-source information.
                // The exact same badge is used by the expanded diagram.
                MauLeafPowerStatusRow(mode: manager.powerFlow.mode, language: manager.language)
                    .padding(.bottom, 8)
                    .transition(.opacity)
            }

            statusRow(
                icon: "checkmark.shield",
                title: "限制充电",
                status: manager.popoverLimitStatus,
                highlighted: manager.currentState?.active == true
                    && manager.hasOriginalStateSnapshot
                    && !manager.fullOncePending
                    && !manager.restorePending,
                loading: manager.isBusy && manager.activeOperation?.affectsLimit == true,
                actionEnabled: manager.canToggleLimitFromCard,
                actionHint: manager.limitCardActionHint,
                action: { manager.toggleLimitFromCard() }
            )
            statusDivider
            statusRow(
                icon: "bolt",
                title: "本次充满",
                status: manager.popoverFullChargeStatus,
                highlighted: manager.fullOncePending && !manager.fullOnceCancelRequested,
                loading: manager.isBusy && manager.activeOperation?.affectsFullCharge == true,
                actionEnabled: manager.canToggleFullChargeFromCard,
                actionHint: manager.fullChargeCardActionHint,
                action: { manager.toggleFullChargeFromCard() }
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.2), value: manager.showPowerFlow)
    }

    /// Power status remains read-only; charge status capsules are buttons.
    private func statusRow(
        icon: String,
        title: AppText,
        status: AppText,
        detail: AppText? = nil,
        highlighted: Bool = false,
        loading: Bool = false,
        actionEnabled: Bool = false,
        actionHint: AppText = "",
        action: (() -> Void)? = nil
    ) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(highlighted ? Color.green : Color.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)

            Text(manager.text(title))
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            Spacer(minLength: 5)

            if let action {
                Button(action: action) {
                    statusPill(status, highlighted: highlighted, interactive: true, loading: loading)
                }
                .buttonStyle(.plain)
                .disabled(!actionEnabled)
                .help(manager.text(actionHint))
                .accessibilityLabel("\(manager.text(title))：\(manager.text(status))")
                .accessibilityHint(manager.text(actionHint))
            } else {
                // Power is a read-only measurement, not another clickable
                // pill. Keep the complete charging detail in the tooltip
                // and in VoiceOver while the visible value stays compact.
                Text(manager.text(status))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(highlighted ? Color.green : Color.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    // Align the trailing edge of this read-only text with the
                    // text inside the actionable status pills, not their border.
                    .padding(.trailing, 12)
                    .help(manager.text(detail ?? status))
                    .accessibilityLabel("\(manager.text(title))：\(manager.text(detail ?? status))")
            }
        }
        .frame(minHeight: 32)
    }

    private func statusPill(_ status: AppText, highlighted: Bool, interactive: Bool, loading: Bool) -> some View {
        HStack(spacing: 6) {
            if loading {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityHidden(true)
            }
            Text(manager.text(status))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(highlighted && !loading ? Color.green : Color.primary)
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .frame(height: 29)
        .padding(.horizontal, 12)
        .background(
            highlighted && !loading
                ? Color.green.opacity(0.15)
                : Color.primary.opacity(interactive ? 0.09 : 0.055),
            in: Capsule()
        )
        .overlay {
            if interactive {
                Capsule().strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
            }
        }
        .contentShape(Capsule())
        .animation(.easeInOut(duration: 0.2), value: loading)
    }

    private var statusDivider: some View {
        Divider()
            .opacity(0.55)
            .padding(.leading, 30)
    }

    private var rowDivider: some View {
        Divider()
            .opacity(0.55)
            .padding(.leading, 30)
    }

    /// One slightly stronger rule separates status from configuration
    /// without a second card, heading or colored strip.
    private var groupDivider: some View {
        Divider()
            .opacity(0.8)
            .padding(.vertical, 8)
    }

    private func menuRow(
        icon: String,
        title: AppText,
        value: String? = nil,
        expanded: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .regular))
                    .frame(width: 20)
                    .accessibilityHidden(true)

                Text(manager.text(title))
                    .font(.subheadline.weight(.medium))

                Spacer(minLength: 8)

                if let value {
                    Text(value)
                        .font(.subheadline.monospacedDigit().weight(.medium))
                }

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 11)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isButton)
    }

    private var limitControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Slider(
                value: Binding(
                    get: { Double(manager.limit) },
                    set: { manager.requestLimit(Int(($0 / 5).rounded()) * 5) }
                ),
                in: 50...95,
                step: 5
            )
            .accessibilityLabel(manager.text("充电上限"))
            .disabled(!canAdjustLimit)

            HStack(spacing: 4) {
                ForEach(presets, id: \.self) { preset in
                    Button {
                        manager.requestLimit(preset, immediate: true)
                    } label: {
                        Text("\(preset)%")
                            .font(.caption2.weight(manager.limit == preset ? .semibold : .regular))
                            .monospacedDigit()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(
                                manager.limit == preset
                                    ? Color.accentColor.opacity(0.20)
                                    : Color.primary.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: 7)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!canAdjustLimit)
                }
            }

            if manager.isLegacyActive {
                Text(manager.text("没有找到首次启用前的原始固件快照。停用旧版限制只能关闭激活标志，不能恢复未保存的阈值。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if manager.restorePending || manager.hasOriginalStateSnapshot && manager.currentState?.active != true {
                Text(manager.text("恢复任务仍在等待；请先恢复原始配置。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !manager.hasOriginalStateSnapshot {
                Text(manager.text("未启用时仅保存上限设置；启用后修改会立即应用。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var canAdjustLimit: Bool {
        !manager.isBusy && !manager.isPreparingToQuit
            && !manager.fullOncePending && !manager.isLegacyActive
            && (!manager.hasOriginalStateSnapshot || manager.isAdapterConnected)
    }

    /// Both preferences use the same compact segmented control so the
    /// selected value is visible without an extra click. These only update
    /// local UserDefaults; no privileged firmware action is involved.
    private var settingsControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                settingsLabel("显示供电详情")
                Spacer(minLength: 8)
                Picker("", selection: $manager.showPowerFlow) {
                    Text(manager.language == .english ? "Hide" : "关闭").tag(false)
                    Text(manager.language == .english ? "Show" : "开启").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 142)
                .accessibilityLabel(manager.text("显示供电详情"))
                .help(manager.text("关闭后保留供电状态，仅隐藏供电流向图"))
            }
            .frame(minHeight: 30)

            HStack(spacing: 8) {
                settingsLabel("界面语言")
                Spacer(minLength: 8)
                Picker("", selection: $manager.language) {
                    Text("中文").tag(AppLanguage.simplifiedChinese)
                    Text("EN").tag(AppLanguage.english)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 142)
                .accessibilityLabel(manager.text("界面语言"))
                .help(manager.text("切换界面语言"))
            }
            .frame(minHeight: 30)

            HStack(spacing: 8) {
                settingsLabel("动态保电")
                Spacer(minLength: 8)
                Picker("", selection: Binding(
                    get: { manager.dynamicHoldEnabled },
                    set: { manager.setDynamicHoldEnabled($0) }
                )) {
                    Text(manager.language == .english ? "Off" : "关闭").tag(false)
                    Text(manager.language == .english ? "On" : "开启").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 142)
                .disabled(manager.isDynamicHoldSwitchLocked)
                .accessibilityLabel(manager.text("动态保电"))
                .help(manager.text(manager.isDynamicHoldSwitchLocked
                    ? "本次充满期间不可修改动态保电"
                    : "高于目标时保持电量；关闭后在已测试机型上可能出现拔电识别延迟"))
            }
            .frame(minHeight: 30)
            Text(manager.text("超限时保持电量；关闭后拔电识别可能延迟（已测试机型）。"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if manager.fullOncePending {
                Text(manager.text(manager.dynamicHoldEnabled
                    ? "本次充满期间动态保电已暂停，完成后自动恢复。"
                    : "本次充满期间不可修改动态保电设置。"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if manager.dynamicHoldEnabled {
                Text(manager.text(manager.dynamicHoldStatus))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                settingsLabel("退出时移除组件")
                Spacer(minLength: 8)
                Picker("", selection: $manager.removeComponentsOnQuit) {
                    Text(manager.language == .english ? "Off" : "关闭").tag(false)
                    Text(manager.language == .english ? "On" : "开启").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 142)
                .accessibilityLabel(manager.text("退出时移除组件"))
                .help(manager.text("开启后每次退出会移除控制组件；关闭则保留。"))
            }
            .frame(minHeight: 30)
            Text(manager.text("建议卸载前开启，退出并确认清理完成后再删除 App。"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                settingsLabel("充电控制重置")
                Spacer(minLength: 8)
                Button(manager.text("强制重置")) { manager.requestForceReset() }
                    .controlSize(.small)
                    .disabled(!manager.canForceReset)
            }
            .frame(minHeight: 30)
        }
        .padding(.vertical, 2)
    }

    private func settingsLabel(_ title: AppText) -> some View {
        Text(manager.text(title))
            .font(.caption)
            .foregroundStyle(.primary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    #if MAULEAF_LAYOUT_TESTING
    var batteryCardForTesting: some View { batteryCard }
    var settingsControlsForTesting: some View { settingsControls }
    #endif
}

/// Error and exceptional-operation feedback is an inline row below the battery
/// card. Ordinary charging operations instead update their own status pills.
struct OperationFeedbackView: View {
    @ObservedObject var manager: ChargeManager
    @State private var dismissedError: AppText?
    @State private var showDetails = false
    @State private var errorDetails: AppText = ""

    private var errorVisible: Bool {
        !manager.isBusy && manager.isError && dismissedError != manager.statusMessage
    }

    private var genericBusy: Bool {
        manager.isBusy && manager.activeOperation == nil
    }

    var body: some View {
        Group {
            if errorVisible || genericBusy {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .top, spacing: 8) {
                        if genericBusy {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(Color.orange)
                        }
                        Text(manager.text(manager.statusMessage))
                            .font(.caption)
                            .lineLimit(errorVisible ? 3 : 2)
                            .fixedSize(horizontal: false, vertical: true)
                            .layoutPriority(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if errorVisible {
                            Button {
                                dismissedError = manager.statusMessage
                            } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain)
                            .accessibilityLabel(manager.text("关闭提示"))
                        }
                    }
                    if errorVisible {
                        HStack(spacing: 12) {
                            Button(manager.text("查看详情")) {
                                errorDetails = manager.statusMessage
                                showDetails = true
                            }
                            if manager.canRetryChargeRequest {
                                Button(manager.text("重试")) { manager.retryChargeRequest() }
                            }
                            if manager.canForceReset {
                                Button(manager.text("强制重置")) { manager.requestForceReset() }
                            }
                        }
                        .font(.caption)
                        .buttonStyle(.link)
                    }
                }
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
                .padding(.bottom, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.22), value: errorVisible)
        .animation(.easeInOut(duration: 0.22), value: genericBusy)
        .onReceive(manager.$isBusy.removeDuplicates().receive(on: RunLoop.main)) { busy in
            if busy { dismissedError = nil }
        }
        .onReceive(manager.$statusMessage.removeDuplicates().receive(on: RunLoop.main)) { message in
            if dismissedError != message { dismissedError = nil }
        }
        .alert(manager.text("操作未完成"), isPresented: $showDetails) {
            Button(manager.text("关闭"), role: .cancel) { }
        } message: { Text(manager.text(errorDetails)) }
    }
}

/// Explicit operation ownership prevents a stale background status message from
/// being mistaken for progress on an unrelated card.
enum ChargeOperation: Equatable {
    case enablingLimit
    case adjustingLimit
    case restoringLimit
    case startingFullCharge
    case cancelingFullCharge
    case repairingHelper

    var affectsLimit: Bool {
        switch self {
        case .enablingLimit, .adjustingLimit, .restoringLimit, .repairingHelper: return true
        case .startingFullCharge, .cancelingFullCharge: return false
        }
    }

    var affectsFullCharge: Bool { !affectsLimit }

    var status: AppText {
        switch self {
        case .enablingLimit: return "正在启用…"
        case .adjustingLimit: return "正在设置…"
        case .restoringLimit: return "正在恢复…"
        case .startingFullCharge: return "正在开启…"
        case .cancelingFullCharge: return "正在取消…"
        case .repairingHelper: return "正在修复…"
        }
    }
}

@MainActor
final class ChargeManager: ObservableObject {
    /// Status Trio-style fast read-only watt sampling while the panel is open.
    static let powerFlowRefreshInterval: TimeInterval = 2

    @Published var batteryPercent: Int?
    @Published var batteryStateText = "正在读取电池状态…"
    @Published var isAdapterConnected = false
    @Published var limit: Int {
        didSet { UserDefaults.standard.set(limit, forKey: "chargeLimit") }
    }
    @Published var language = AppLanguage.saved() {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: AppLanguage.preferenceKey) }
    }
    /// New flow diagram defaults ON, regardless of legacy battery digits
    /// preference. This only controls the read-only menu presentation.
    @Published var showPowerFlow: Bool {
        didSet {
            guard showPowerFlow != oldValue else { return }
            UserDefaults.standard.set(showPowerFlow, forKey: "showPowerFlow")
            restartPowerFlowTimer()
            if panelVisible {
                if showPowerFlow {
                    refreshPowerFlowOnly()
                } else {
                    // Update the status badge immediately from the native
                    // battery registry, without changing firmware policy.
                    readSystemBattery(allowDynamicScheduling: false)
                }
            }
        }
    }
    @Published var removeComponentsOnQuit: Bool {
        didSet { UserDefaults.standard.set(removeComponentsOnQuit, forKey: "removeComponentsOnQuit") }
    }
    var quitComponentPolicy: QuitComponentPolicy {
        removeComponentsOnQuit ? .remove : .keep
    }
    @Published private(set) var powerFlow = MauLeafPowerFlow(snapshot: nil)
    /// Experimental, explicit opt-in. Independent from the deprecated
    /// Preview 1 observation preference: existing installations are OFF.
    @Published private(set) var dynamicHoldEnabled: Bool {
        didSet {
            guard dynamicHoldEnabled != oldValue else { return }
            UserDefaults.standard.set(dynamicHoldEnabled, forKey: "dynamicHoldEnabled")
            dynamicSessionUpper = nil
            dynamicNeedsNewCapture = dynamicHoldEnabled
            recomputeAboveLimitPowerFinding()
            if started { scheduleDynamicHoldReconciliation() }
        }
    }

    /// The only policy mutation entrypoint. A persistent one-time full-charge
    /// job owns the SMC until the Helper confirms final restoration.
    /// Never write the @Published property back from its didSet observer:
    /// doing so can re-enter Combine's property wrapper and crash.
    func setDynamicHoldEnabled(_ enabled: Bool) {
        guard !isDynamicHoldSwitchLocked, dynamicHoldEnabled != enabled else { return }
        dynamicHoldEnabled = enabled
    }
    @Published private(set) var aboveLimitPowerFinding: AboveLimitPowerFinding = .disabled
    @Published private(set) var menuBarLeafStyle: MenuBarLeafStyle = .green
    @Published private(set) var fullOncePending = false
    @Published private(set) var fullOnceCancelRequested = false

    /// Full-charge creation/cancellation and the persistent Helper job own
    /// charge control. Dynamic Hold cannot be changed until that job ends.
    var isDynamicHoldSwitchLocked: Bool {
        fullOncePending || activeOperation == .startingFullCharge
            || activeOperation == .cancelingFullCharge || isPreparingToQuit
    }

    @Published var modeText: AppText = "正在检查原生固件控制…"
    @Published var statusMessage: AppText = "正在连接 MauLeaf 原生固件服务…"
    @Published var autoApplyFeedback: AppText = "调整后自动应用"
    @Published var backendReady = false
    @Published private(set) var restoreReady = false
    @Published var isBusy = false
    @Published private(set) var activeOperation: ChargeOperation?
    @Published private(set) var isPreparingToQuit = false
    @Published private(set) var didVerifyFirmwareOnQuit = false
    @Published var isError = false
    @Published var showNativeWriteConfirmation = false
    @Published var showLegacyDisableConfirmation = false
    @Published var showForceResetConfirmation = false
    @Published private(set) var helperNeedsInstallation = false
    @Published private(set) var helperNeedsUpgrade = false
    @Published private(set) var helperStateUnknown = false

    private let backend: NativeFirmwareBackend
    private let autoInstallNativeHelper: Bool
    private let batteryReader: () -> MauLeafBatterySnapshot
    private let powerFlowReader: () -> MauLeafPowerFlow
    private let observePowerSourceChanges: Bool
    private var powerSourceObserver: MauLeafPowerSourceObserver?
    private var powerRecheckTask: Task<Void, Never>?
    private let autoUpgradeInstalledHelperOnLaunch: Bool
    private var attemptedStartupHelperUpgrade = false
    private var helperVersionVerified = false
    private let exitLifecycleForTesting: ((QuitComponentPolicy) async throws -> Void)?
    private let helperInstallerForTesting: (() async throws -> Void)?
    private let helperArtifactsPresent: () -> Bool
    private let hardwareWriteBlockReason: String?
    private var started = false
    private var panelVisible = false
    private var refreshTimer: Timer?
    private var powerFlowTimer: Timer?
    private var powerFlowGeneration = 0
    private var powerFlowReadInFlight = false
    private var limitDebounce: Task<Void, Never>?
    private var latestBatteryObservation: MauLeafBatterySnapshot?
    private var consecutiveDischargeReadings = 0
    private var dynamicSessionUpper: Int?
    private var dynamicNeedsNewCapture = false
    private var dynamicACStableSince: Date?
    private var dynamicLastAC: Bool?
    private var dynamicReconcileTask: Task<Void, Never>?
    private var automaticUnplugRestoreTask: Task<Void, Never>?
    private var automaticReconnectApplyTask: Task<Void, Never>?
    private var automaticUnplugRetryAfter: Date?
    /// Explicit user preference, separate from transient hardware activation.
    private var desiredLimitEnabled: Bool
    private var dynamicRetryAfter: Date?
    private let dynamicSettleInterval: TimeInterval
    private let rebootSettleInterval: TimeInterval
    private var lastDynamicAppliedUpper: Int?
    @Published private(set) var currentState: FirmwareLimitHelperStateResponse?
    private var pendingAction: PendingAction?
    private var lastAction: PendingAction?

    #if MAULEAF_LAYOUT_TESTING
    func setFeedbackOperationForTesting(_ operation: ChargeOperation?) {
        activeOperation = operation
    }
    #endif

    private enum PendingAction {
        case enable
        case limit(Int)
        case full
    }

    init(
        backend: NativeFirmwareBackend = FirmwareLimitHelperClient(),
        autoInstallNativeHelper: Bool = true,
        autoUpgradeInstalledHelperOnLaunch: Bool? = nil,
        exitLifecycleForTesting: ((QuitComponentPolicy) async throws -> Void)? = nil,
        helperInstallerForTesting: (() async throws -> Void)? = nil,
        helperArtifactsPresent: @escaping () -> Bool = {
            let fs = FileManager.default
            return [
                "/Library/PrivilegedHelperTools/com.local.chargecap.firmware-helper",
                "/Library/LaunchDaemons/com.local.chargecap.firmware-helper.plist",
                "/Library/Application Support/MauLeaf"
            ].contains { fs.fileExists(atPath: $0) }
        },
        hardwarePreflightForTesting: (() -> String?)? = nil,
        batteryReader: @escaping () -> MauLeafBatterySnapshot = { MauLeafFastBatteryReader.read() },
        powerFlowReader: (() -> MauLeafPowerFlow)? = nil,
        observePowerSourceChanges: Bool? = nil,
        dynamicSettleInterval: TimeInterval = 8.0,
        rebootSettleInterval: TimeInterval = 15.0
    ) {
        self.backend = backend
        self.autoInstallNativeHelper = autoInstallNativeHelper
        self.batteryReader = batteryReader
        // Fixture tests can retain deterministic snapshots; production uses
        // short-lived, read-only AppleSMC power rails with registry fallback.
        self.powerFlowReader = powerFlowReader ?? (autoInstallNativeHelper
            ? { MauLeafLivePowerReader.read() }
            : { MauLeafPowerFlow(snapshot: batteryReader()) })
        self.dynamicSettleInterval = max(0, dynamicSettleInterval)
        self.rebootSettleInterval = max(0, rebootSettleInterval)
        // Fixture managers default to no OS observer; the real app enables
        // native events with the existing 20s background polling fallback.
        self.observePowerSourceChanges = observePowerSourceChanges ?? autoInstallNativeHelper
        self.autoUpgradeInstalledHelperOnLaunch = autoUpgradeInstalledHelperOnLaunch ?? autoInstallNativeHelper
        self.exitLifecycleForTesting = exitLifecycleForTesting
        self.helperInstallerForTesting = helperInstallerForTesting
        self.helperArtifactsPresent = helperArtifactsPresent
        if let hardwarePreflightForTesting {
            self.hardwareWriteBlockReason = hardwarePreflightForTesting()
        } else if autoInstallNativeHelper {
            self.hardwareWriteBlockReason = FirmwareLimitWritePermit.targetBlockReason(
                identity: FirmwareLimitRuntime.identity()
            )
        } else {
            self.hardwareWriteBlockReason = nil
        }
        let saved = UserDefaults.standard.integer(forKey: "chargeLimit")
        limit = (50...95).contains(saved) ? saved : 80
        showPowerFlow = UserDefaults.standard.object(forKey: "showPowerFlow") as? Bool ?? true
        removeComponentsOnQuit = UserDefaults.standard.bool(forKey: "removeComponentsOnQuit")
        dynamicHoldEnabled = UserDefaults.standard.bool(forKey: "dynamicHoldEnabled")
        desiredLimitEnabled = UserDefaults.standard.bool(forKey: "desiredChargeLimitEnabled")
    }

    func text(_ message: AppText) -> String { message.localized(in: language) }

    var isActivelyCharging: Bool {
        batteryStateText == "正在充电"
    }

    var aboveLimitPowerStatus: AppText {
        switch aboveLimitPowerFinding {
        case .disabled: return "未开启检测"
        case .limitInactive: return "等待启用限充"
        case .oneTimeCharge: return "本次充满期间暂停检测"
        case .disconnected: return "未接入适配器或供电状态未知"
        case .unknownBattery: return "电量信息不可用"
        case .withinLimit: return "电量未超过限充上限"
        case .unknownCurrent: return "电池电流不可用，无法判断是否放电"
        case .chargingAboveLimit: return "高于上限且检测到充电，请检查限充状态"
        case .observingDischarge: return "检测到放电，正在连续确认"
        case .batteryDischarging: return "仍检测到持续放电；固件保持效果尚未验证"
        case .noSignificantDischarge: return "未检测到明显放电；无法确认适配器实际供电"
        }
    }

    /// The observation is separate from firmware application. Never silently
    /// reconfigure bf* registers or claim battery drain was prevented.
    private func recomputeAboveLimitPowerFinding(countNewSample: Bool = false) {
        let observation = latestBatteryObservation
        let finding = AboveLimitPowerPolicy.classify(
            enabled: dynamicHoldEnabled,
            firmwareActive: currentState?.active == true,
            hasOriginalSnapshot: hasOriginalStateSnapshot,
            oneTimeCharge: fullOncePending,
            batteryPercent: observation?.percent,
            upperLimit: limit,
            externalConnected: observation?.isACConnected,
            isCharging: observation?.isCharging == true,
            amperageMilliAmps: observation?.amperageMilliAmps
        )
        if finding == .observingDischarge {
            if countNewSample { consecutiveDischargeReadings += 1 }
            aboveLimitPowerFinding = consecutiveDischargeReadings >= AboveLimitPowerPolicy.dischargeSamplesRequired
                ? .batteryDischarging : .observingDischarge
        } else {
            consecutiveDischargeReadings = 0
            aboveLimitPowerFinding = finding
        }
    }

    func recordPowerObservation(_ snapshot: MauLeafBatterySnapshot) {
        latestBatteryObservation = snapshot
        recomputeAboveLimitPowerFinding(countNewSample: true)
    }

    var dynamicHoldStatus: AppText {
        if !dynamicHoldEnabled { return "尚未开启动态保电" }
        if fullOncePending { return "本次充满期间暂停动态保电" }
        guard let state = currentState, state.active, hasOriginalStateSnapshot else {
            return "开启限充后，才会按当前电量计算保持上限"
        }
        if !isAdapterConnected { return "电池供电；停止自动固件调整" }
        if state.upper > limit {
            return "目标 \(limit)% · 临时上限 \(state.upper)%"
        }
        return "目标 \(limit)% · 当前使用原始上限"
    }

    private func setDesiredLimitEnabled(_ value: Bool) {
        guard desiredLimitEnabled != value else { return }
        desiredLimitEnabled = value
        UserDefaults.standard.set(value, forKey: "desiredChargeLimitEnabled")
    }

    /// When macOS finally reports a true disconnect, call the Helper's
    /// already-verified offline snapshot restore. It rechecks both pmset and
    /// AppleSmartBattery before writing and retains the durable recovery job
    /// on a failed attempt.
    private func scheduleUnpluggedFirmwareRestore() {
        automaticUnplugRestoreTask?.cancel()
        automaticUnplugRestoreTask = nil
        guard started, !isPreparingToQuit, !isAdapterConnected,
              latestBatteryObservation?.isACConnected == false,
              dynamicLastAC == false,
              let state = currentState, state.hasOriginalStateSnapshot,
              !state.restorePending, !isBusy, state.restoreSupported else { return }
        if let retry = automaticUnplugRetryAfter, retry > Date() { return }
        dynamicReconcileTask?.cancel()
        dynamicReconcileTask = nil
        automaticReconnectApplyTask?.cancel()
        automaticReconnectApplyTask = nil
        automaticUnplugRestoreTask = Task { [weak self] in
            guard let self, !Task.isCancelled, !self.isPreparingToQuit,
                  !self.isAdapterConnected, !self.isBusy else { return }
            self.activeOperation = .restoringLimit
            self.isBusy = true
            self.statusMessage = "已检测到电源断开，正在恢复原始固件参数…"
            defer {
                self.isBusy = false
                self.activeOperation = nil
                if self.isAdapterConnected { self.scheduleReconnectLimitResume() }
            }
            do {
                if self.desiredLimitEnabled {
                    _ = try await self.backend.suspendLimitForReconnect()
                } else {
                    _ = try await self.backend.restoreOriginalState()
                }
                let state = try await self.backend.readState()
                let once = try await self.backend.oneTimeChargeStatus()
                self.currentState = state
                self.fullOncePending = once.pending
                self.fullOnceCancelRequested = once.cancelRequested
                self.backendReady = state.writeSupported
                self.restoreReady = state.restoreSupported
                guard !state.active && !state.hasOriginalStateSnapshot
                        && !state.restorePending && !once.pending else {
                    throw NativeControlError.unsafeStateAfterInstall("恢复原始固件状态后校验未通过。")
                }
                self.dynamicSessionUpper = nil
                self.dynamicNeedsNewCapture = true
                self.automaticUnplugRetryAfter = nil
                self.modeText = self.isAdapterConnected
                    ? "原始固件参数已恢复" : "电池供电 · 原始固件参数已恢复"
                self.statusMessage = "已恢复启用前的原始固件参数，MauLeaf 停止限充控制。"
                self.isError = false
            } catch {
                self.automaticUnplugRetryAfter = Date().addingTimeInterval(8)
                self.isBusy = false
                await self.refreshNativeState()
                self.statusMessage = "拔电后尚未完成固件恢复；原始快照及后台恢复任务已保留：\(AppText(error: error))"
                self.isError = true
            }
        }
    }

    /// AC replug creates a fresh SMC snapshot only if the user had
    /// previously enabled limiting; no automatic re-enable after manual
    /// disabling, logout or an unknown pre-existing firmware state.
    private func scheduleReconnectLimitResume() {
        automaticReconnectApplyTask?.cancel()
        automaticReconnectApplyTask = nil
        guard started, !isPreparingToQuit, desiredLimitEnabled,
              UserDefaults.standard.bool(forKey: "nativeFirmwareWriteConfirmed"),
              isAdapterConnected, dynamicLastAC == true,
              !isBusy, !fullOncePending, !helperNeedsUpgrade,
              let state = currentState, !state.active,
              !state.hasOriginalStateSnapshot, !state.restorePending,
              state.writeSupported, !state.isActiveZeroed else { return }
        let since = dynamicACStableSince ?? Date()
        let remaining = max(0, dynamicSettleInterval - Date().timeIntervalSince(since))
        automaticReconnectApplyTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            guard !Task.isCancelled, let self, !self.isBusy,
                  !self.isPreparingToQuit, self.desiredLimitEnabled,
                  self.isAdapterConnected, self.dynamicLastAC == true else { return }
            let a = self.batteryReader()
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            let b = self.batteryReader()
            guard a.isACConnected == true, b.isACConnected == true,
                  (!self.dynamicHoldEnabled || b.precisePercent != nil) else { return }
            guard let current = try? await self.backend.readState(),
                  !current.active && !current.hasOriginalStateSnapshot,
                  !current.restorePending && current.writeSupported,
                  !current.isActiveZeroed,
                  self.desiredLimitEnabled && self.isAdapterConnected else { return }
            await self.applyLimit(self.limit)
        }
    }

    private func computedDynamicPlan(userTarget: Int) -> DynamicHoldPolicy.Plan? {
        if !dynamicHoldEnabled {
            return .target(upper: userTarget, lower: max(5, userTarget - 2))
        }
        return DynamicHoldPolicy.plan(
            userTarget: userTarget,
            rawPercent: latestBatteryObservation?.precisePercent,
            holdingUpper: dynamicSessionUpper
        )
    }

    /// Schedule a single bounded reconciliation after a stable AC observation.
    /// The macOS ExternalConnected field was measured to lag actual unplugging
    /// by several seconds on this firmware. Never write on unplug, and never
    /// trust one early "AC" sample as proof that a charger is still connected.
    /// A reboot may return bfF0 inactive and both thresholds zero while
    /// retaining the verified original snapshot. Recovery is allowed only
    /// for a pre-authorized, managed limit; an unknown zero state with no
    /// snapshot is read-only and must never become the new baseline.
    private var needsManagedBootReapply: Bool {
        guard let state = currentState else { return false }
        return state.isInactiveUninitialized && state.hasOriginalStateSnapshot
            && !state.restorePending && !fullOncePending
            && UserDefaults.standard.bool(forKey: "nativeFirmwareWriteConfirmed")
    }

    private func scheduleDynamicHoldReconciliation() {
        dynamicReconcileTask?.cancel()
        dynamicReconcileTask = nil
        guard started, !isPreparingToQuit, !fullOncePending,
              let state = currentState, state.hasOriginalStateSnapshot,
              (state.active || needsManagedBootReapply),
              state.writeSupported, isAdapterConnected,
              dynamicLastAC == true else { return }

        let bootReapply = needsManagedBootReapply
        let stableSince = dynamicACStableSince ?? Date()
        // Allow the SMC more time to finish its boot-time initialization
        // before reconfiguring any managed firmware limits.
        let requiredStableTime = bootReapply
            ? max(rebootSettleInterval, dynamicSettleInterval)
            : dynamicSettleInterval
        let waitSeconds = max(0, requiredStableTime - Date().timeIntervalSince(stableSince))
        dynamicReconcileTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(waitSeconds * 1_000_000_000))
            guard !Task.isCancelled, let self,
                  self.started, !self.isPreparingToQuit, !self.isBusy, !self.fullOncePending,
                  self.dynamicLastAC == true else { return }
            // Two fresh reads after the stability interval. Any uncertainty
            // blocks automatic writes, even if the existing status still
            // reports AC due to delayed system state propagation.
            let a = self.batteryReader()
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            let b = self.batteryReader()
            guard a.isACConnected == true, b.isACConnected == true,
                  (!self.dynamicHoldEnabled ||
                   (a.precisePercent != nil && b.precisePercent != nil)) else { return }
            self.readSystemBattery(allowDynamicScheduling: false)
            guard let current = self.currentState, current.hasOriginalStateSnapshot,
                  (current.active || self.needsManagedBootReapply),
                  current.writeSupported, !self.isBusy, self.isAdapterConnected,
                  self.dynamicLastAC == true else { return }
            if let retryAfter = self.dynamicRetryAfter, retryAfter > Date() { return }
            // A previously zeroed SMC may have become ready on its own.
            // Re-read the privileged Helper immediately before deciding
            // whether a restart recovery write is still appropriate.
            if bootReapply {
                guard let fresh = try? await self.backend.readState() else { return }
                guard fresh.isInactiveUninitialized && fresh.hasOriginalStateSnapshot
                        && !fresh.restorePending && fresh.writeSupported else {
                    let once = try? await self.backend.oneTimeChargeStatus()
                    if let once {
                        self.updateFromNativeState(fresh, oneTime: once,
                                                   status: "已重新读取固件启动状态。")
                    }
                    return
                }
            }
            guard let plan = self.computedDynamicPlan(userTarget: self.limit) else { return }
            guard bootReapply || current.upper != plan.upper || current.lower != plan.lower else { return }
            await self.applyLimit(self.limit)
        }
    }

    private func observeDynamicPowerConnection(_ external: Bool?) {
        guard external != dynamicLastAC else { return }
        dynamicLastAC = external
        switch external {
        case .some(false):
            limitDebounce?.cancel()
            limitDebounce = nil
            dynamicACStableSince = nil
            dynamicSessionUpper = nil
            dynamicNeedsNewCapture = true
            dynamicReconcileTask?.cancel()
            dynamicReconcileTask = nil
            automaticReconnectApplyTask?.cancel()
            automaticReconnectApplyTask = nil
            scheduleUnpluggedFirmwareRestore()
        case .some(true):
            dynamicACStableSince = Date()
            dynamicSessionUpper = nil
            automaticUnplugRestoreTask?.cancel()
            automaticUnplugRestoreTask = nil
            scheduleDynamicHoldReconciliation()
            scheduleReconnectLimitResume()
        case .none:
            dynamicACStableSince = nil
            dynamicReconcileTask?.cancel()
            dynamicReconcileTask = nil
            automaticReconnectApplyTask?.cancel()
            automaticReconnectApplyTask = nil
        }
    }

    /// Keep battery digits neutral while charging; only an unplugged low
    /// battery deserves warning colors. Charging activity is shown in the
    /// power-status row rather than competing with the limit's green badge.
    var batteryNumberColor: Color {
        guard !isAdapterConnected, let batteryPercent else { return .primary }
        if batteryPercent < 10 { return .red }
        if batteryPercent < 20 { return .orange }
        return .primary
    }

    var batteryTint: Color {
        if let batteryPercent, batteryPercent < 20 { return .red }
        if batteryStateText == "正在充电" { return .green }
        return .primary
    }

    var batteryRingIcon: BatteryRingIcon? {
        switch batteryStateText {
        case "正在充电": return .charging
        case "电池供电": return .battery
        case "已接电源，未充电", "已接电源，已充满": return .adapter
        default: return isAdapterConnected ? .adapter : nil
        }
    }

    var batteryDisplayText: AppText {
        AppText(key: batteryStateText)
    }

    /// Status labels for the compact popover, derived from the actual
    /// firmware and one-time task (not merely the saved slider preference).
    var popoverPowerStatus: AppText {
        switch batteryStateText {
        case "正在充电": return "充电中"
        case "已接电源，未充电": return "已接电源"
        case "已接电源，已充满": return "已充满"
        case "电池供电": return "电池供电"
        case "正在读取电池状态…": return "读取中…"
        default: return "状态未知"
        }
    }

    /// Preserve the full power / charging distinction on hover and for VoiceOver.
    var popoverPowerDetail: AppText {
        if batteryStateText == "正在充电" { return "已接电源，充电中" }
        return AppText(key: batteryStateText)
    }

    var popoverLimitStatus: AppText {
        if isBusy, let activeOperation, activeOperation.affectsLimit {
            return activeOperation.status
        }
        if !isAdapterConnected && currentState?.hasOriginalStateSnapshot == true {
            return restorePending ? "等待断电恢复" : "正在恢复原始参数"
        }
        if let state = currentState, state.isActiveZeroed {
            return state.hasOriginalStateSnapshot ? "固件异常 · 待恢复" : "固件异常"
        }
        if let state = currentState, state.isInactiveUninitialized {
            if state.hasOriginalStateSnapshot { return "重启后恢复中" }
            if state.hasReconnectBaseline && state.writeSupported { return "等待恢复限充" }
            return "固件未就绪"
        }
        if helperStateUnknown { return "状态未知" }
        if helperNeedsUpgrade {
            // For a known inactive old helper, the first click still means
            // Enable (and upgrades the helper first). Do not label it as an
            // update-only action when it would also modify AppleSMC.
            if currentState?.active == false && !hasOriginalStateSnapshot && !restorePending {
                return "未启用"
            }
            return "需要更新"
        }
        if restorePending { return "等待恢复" }
        if isLegacyActive { return "旧版限充" }
        if fullOncePending && hasOriginalStateSnapshot {
            return "已暂停 · \(limit)%"
        }
        if currentState?.active == true && hasOriginalStateSnapshot {
            // This is a persisted firmware setting, NOT an assertion that
            // charge control is currently running while on battery.
            if !isAdapterConnected { return "已配置 · 电池供电" }
            return "已启用 · \(dynamicHoldEnabled ? limit : (currentState?.upper ?? limit))%"
        }
        if hasOriginalStateSnapshot { return "待恢复" }
        return "未启用"
    }

    var popoverFullChargeStatus: AppText {
        if isBusy, let activeOperation, activeOperation.affectsFullCharge {
            return activeOperation.status
        }
        if fullOnceCancelRequested { return "正在恢复" }
        return fullOncePending ? "进行中" : "未开启"
    }



    var batteryStateSymbol: String {
        switch batteryStateText {
        case "正在充电": return "bolt.fill"
        case "已充满", "已接电源，已充满": return "battery.100percent"
        case "电池供电": return "battery.75percent"
        default: return "powerplug"
        }
    }


    var menuBarAccessibilityText: AppText {
        let level: AppText = batteryPercent.map { value -> AppText in "电量 \(value)%" } ?? "电量未知"
        if let batteryPercent, batteryPercent < 20 { return "\(level)，电量低" }
        if batteryStateText == "正在充电" { return "\(level)，正在充电" }
        if isAdapterConnected { return "\(level)，已接入电源" }
        return "\(level)，电池供电"
    }

    var canRetryChargeRequest: Bool {
        !isBusy && !isPreparingToQuit && (!backendReady || lastAction != nil)
    }

    var hasOriginalStateSnapshot: Bool {
        currentState?.hasOriginalStateSnapshot == true
    }

    var restorePending: Bool {
        currentState?.restorePending == true
    }

    var isLegacyActive: Bool {
        currentState?.active == true && !hasOriginalStateSnapshot
    }

    var canEnableLimit: Bool {
        let clean = currentState?.active == false && !hasOriginalStateSnapshot
            && !restorePending && !fullOncePending
        let needsFirstInstall = helperNeedsInstallation && currentState == nil && !helperArtifactsPresent()
        let needsExplicitUpgrade = helperNeedsUpgrade && clean
        return isAdapterConnected && !isBusy && !isPreparingToQuit && !fullOncePending
            && ((clean && backendReady) || (
                hardwareWriteBlockReason == nil && (needsFirstInstall || needsExplicitUpgrade)
            ))
    }

    var canDisableLimit: Bool {
        restoreReady && hasOriginalStateSnapshot
            && !isBusy && !isPreparingToQuit
    }

    var canRetryOriginalRestore: Bool {
        restoreReady && restorePending
            && !isBusy && !isPreparingToQuit
    }

    var canDisableLegacyLimit: Bool {
        restoreReady && isLegacyActive
            && !isBusy && !isPreparingToQuit
    }

    var canStartFullCharge: Bool {
        backendReady && hasOriginalStateSnapshot && currentState?.active == true
            && isAdapterConnected && !isBusy && !isPreparingToQuit && !fullOncePending
    }

    /// A stale/unknown installed Helper can be repaired explicitly without
    /// enabling a limit. This is essential when an older version was active.
    var canRepairNativeHelper: Bool {
        (helperNeedsUpgrade || (helperStateUnknown && !helperVersionVerified))
            && helperArtifactsPresent() && !isBusy && !isPreparingToQuit
            && !(helperNeedsUpgrade && canEnableLimit)
    }

    /// All card actions reuse the existing hardware and restore safeguards.
    private var canRecheckUninitializedFirmware: Bool {
        currentState?.isInactiveUninitialized == true && !backendReady
            && helperVersionVerified && !isBusy && !isPreparingToQuit
    }

    var canToggleLimitFromCard: Bool {
        if canRecheckUninitializedFirmware { return true }
        if canRepairNativeHelper { return true }
        if isLegacyActive { return canDisableLegacyLimit }
        if hasOriginalStateSnapshot || restorePending {
            return canDisableLimit || canRetryOriginalRestore
        }
        return canEnableLimit
    }

    var limitCardActionHint: AppText {
        if canRecheckUninitializedFirmware { return "重新检测固件" }
        if canRepairNativeHelper { return "修复控制服务" }
        if isLegacyActive { return "停用旧版限制" }
        if restorePending || (hasOriginalStateSnapshot && currentState?.active != true && !fullOncePending) {
            return "恢复原始配置"
        }
        return hasOriginalStateSnapshot ? "关闭限制充电" : "启用限制充电"
    }

    func toggleLimitFromCard() {
        guard canToggleLimitFromCard else { return }
        if canRecheckUninitializedFirmware {
            Task { await refreshNativeState() }
        } else if canRepairNativeHelper {
            Task { await repairNativeHelperAfterUserAction() }
        } else if isLegacyActive {
            requestLegacyDisableConfirmation()
        } else if hasOriginalStateSnapshot || restorePending {
            disableLimit()
        } else {
            enableLimit()
        }
    }

    var canToggleFullChargeFromCard: Bool {
        if fullOncePending {
            return !fullOnceCancelRequested && !isBusy && !isPreparingToQuit
        }
        return canStartFullCharge && (batteryPercent ?? 0) < 100
    }

    var fullChargeCardActionHint: AppText {
        fullOncePending
            ? "取消本次充满"
            : "仅本次允许充至 100%；完成后由原生后台服务恢复当前充电上限。"
    }

    func toggleFullChargeFromCard() {
        guard canToggleFullChargeFromCard else { return }
        if fullOncePending {
            cancelFullOnce()
        } else {
            beginOneTimeFullCharge()
        }
    }

    func start() {
        guard !started else { return }
        started = true
        readSystemBattery()
        if observePowerSourceChanges {
            let observer = MauLeafPowerSourceObserver { [weak self] in
                self?.handlePowerSourceChange()
            }
            if observer.start() {
                powerSourceObserver = observer
            } else {
                NSLog("MauLeaf IOKit power-source notification unavailable; periodic refresh remains active")
            }
        }
        Task { await refreshNativeState() }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isBusy else { return }
                // Preserve the independent 20s Helper/safety fallback.
                // The visible diagram refreshes on its own 2s rhythm.
                // Compact status still follows the 20 s fallback and
                // native power-source notifications while live watts are off.
                self.readSystemBattery(updateDisplayedPowerFlow: !self.showPowerFlow)
                await self.refreshNativeState()
            }
        }
    }

    /// On AC plug/unplug, update battery UI immediately (without waiting
    /// for the 20-second timer). A couple of bounded follow-up reads absorb
    /// transient lag while macOS updates AppleSmartBattery registry fields.
    /// No privileged Helper calls are made for these telemetry events.
    private func handlePowerSourceChange() {
        guard started, !isPreparingToQuit else { return }
        readSystemBattery()
        powerRecheckTask?.cancel()
        powerRecheckTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled, let self, !self.isPreparingToQuit else { return }
            self.readSystemBattery()
            try? await Task.sleep(nanoseconds: 850_000_000)
            guard !Task.isCancelled, !self.isPreparingToQuit else { return }
            self.readSystemBattery()
        }
    }

    #if MAULEAF_TESTING
    func simulatePowerSourceNotificationForTesting() {
        handlePowerSourceChange()
    }
    #endif

    func setPanelVisible(_ visible: Bool) {
        panelVisible = visible
        restartPowerFlowTimer()
        if visible {
            refresh()
            refreshPowerFlowOnly()
        }
    }

    /// Short-lived read-only AppleSMC telemetry runs off the main thread.
    /// A generation check discards a result after closing the menu or quitting.
    /// Never call the privileged Helper or schedule firmware changes here.
    private func refreshPowerFlowOnly() {
        guard started, panelVisible, showPowerFlow, !isPreparingToQuit,
              !powerFlowReadInFlight else { return }
        powerFlowReadInFlight = true
        let generation = powerFlowGeneration
        let read = powerFlowReader
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let sample = read()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.powerFlowReadInFlight = false
                guard generation == self.powerFlowGeneration,
                      self.panelVisible, self.showPowerFlow, !self.isPreparingToQuit else { return }
                if self.powerFlow != sample { self.powerFlow = sample }
            }
        }
    }

    private func restartPowerFlowTimer() {
        powerFlowTimer?.invalidate()
        powerFlowTimer = nil
        powerFlowGeneration &+= 1
        guard started, panelVisible, showPowerFlow, !isPreparingToQuit else { return }
        powerFlowTimer = Timer.scheduledTimer(
            withTimeInterval: Self.powerFlowRefreshInterval, repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshPowerFlowOnly() }
        }
    }

    #if MAULEAF_TESTING
    var isPowerFlowTimerActiveForTesting: Bool { powerFlowTimer?.isValid == true }
    #endif

    func refresh() {
        guard !isPreparingToQuit else { return }
        readSystemBattery()
        guard started, !isBusy else { return }
        Task { await refreshNativeState() }
    }

    private func refreshNativeState() async {
        guard !isPreparingToQuit, !isBusy else { return }
        var helperInfoVerified = false
        do {
            // Version handshake must run before SMC access. A compatible
            // Helper can report its identity even when firmware state or a
            // persisted recovery snapshot cannot currently be read.
            let info = try await backend.readHelperInfo()
            guard !isPreparingToQuit else { return }
            helperInfoVerified = true

            if !FirmwareLimitHelperProtocolVersion.isCompatible(info) {
                // Do not ask an incompatible Helper to interpret its own
                // firmware state. The bundled replacement will read the
                // preserved snapshot and pending jobs after installation.
                helperVersionVerified = false
                currentState = nil
                helperNeedsInstallation = false
                helperNeedsUpgrade = true
                helperStateUnknown = true
                backendReady = false
                restoreReady = false
                modeText = "原生控制服务版本不匹配"
                statusMessage = "当前 Helper 与应用要求的版本不一致；将卸载旧版并安装应用内置版本。"
                isError = false
                scheduleStartupHelperReplacement()
                return
            }

            helperVersionVerified = true
            let state = try await backend.readState()
            guard !isPreparingToQuit else { return }
            // The state response repeats the version so a stale or mixed
            // service response cannot authorize a firmware operation.
            if !FirmwareLimitHelperProtocolVersion.isCompatible(
                state.helperVersion, build: state.helperBuildVersion
            ) {
                helperVersionVerified = false
                currentState = state
                helperNeedsInstallation = false
                helperNeedsUpgrade = true
                helperStateUnknown = false
                backendReady = false
                restoreReady = false
                modeText = "原生控制服务版本不匹配"
                statusMessage = "控制服务版本校验不一致；将卸载旧版并安装应用内置版本。"
                isError = false
                scheduleStartupHelperReplacement()
                return
            }

            let once = try await backend.oneTimeChargeStatus()
            guard !isPreparingToQuit else { return }
            updateFromNativeState(state, oneTime: once, status: "已读取原生固件状态。")
        } catch {
            guard !isPreparingToQuit else { return }
            backendReady = false
            restoreReady = false

            if !helperInfoVerified {
                // Missing handshake means an older Helper or an unreachable
                // installed service. Read-only state is attempted only to
                // preserve the UI's knowledge of an active legacy limit;
                // it never authorizes writes. If the method is absent or
                // state decoding fails, keep the state explicitly unknown.
                helperVersionVerified = false
                if !helperArtifactsPresent() {
                    helperNeedsInstallation = true
                    helperNeedsUpgrade = false
                    helperStateUnknown = false
                    currentState = nil
                    fullOncePending = false
                    fullOnceCancelRequested = false
                    modeText = "限制充电未启用"
                    statusMessage = "未安装原生固件控制服务；点击启用限制充电时再请求授权。"
                    isError = false
                    return
                }

                // An installed Helper that cannot answer the version
                // handshake is not eligible for firmware operations. Do not
                // call its legacy readState: it may reject zeroed boot values
                // or omit the snapshot/recovery flags entirely.
                currentState = nil
                helperNeedsInstallation = false
                helperNeedsUpgrade = true
                helperStateUnknown = true
                modeText = "原生控制服务版本未知"
                statusMessage = "无法验证当前 Helper 版本；保留所有恢复数据，正在卸载旧版并重新安装内置 Helper。"
                isError = false
                scheduleStartupHelperReplacement()
                return
            }

            // The Helper version is already verified. A state-read failure
            // is a hardware/recovery problem, not a version mismatch; never
            // uninstall a correctly versioned recovery service for this.
            helperVersionVerified = true
            helperNeedsInstallation = false
            helperNeedsUpgrade = false
            helperStateUnknown = true
            modeText = "固件控制状态未知"
            statusMessage = "已确认原生控制服务版本，但无法读取固件或恢复状态；请保留 Helper 和恢复数据：\(AppText(error: error))"
            isError = true
        }
    }

    private func scheduleStartupHelperReplacement() {
        guard autoUpgradeInstalledHelperOnLaunch,
              !attemptedStartupHelperUpgrade,
              (autoInstallNativeHelper || helperInstallerForTesting != nil),
              helperArtifactsPresent() else { return }
        attemptedStartupHelperUpgrade = true
        Task { await replaceNativeHelperAfterStartupCheck() }
    }

    private func updateFromNativeState(
        _ state: FirmwareLimitHelperStateResponse,
        oneTime: FirmwareLimitHelperOneTimeStatusResponse,
        status: AppText
    ) {
        currentState = state
        helperVersionVerified = true
        helperNeedsInstallation = false
        helperNeedsUpgrade = false
        helperStateUnknown = false
        // Migration from the former active-only model. Never infer an
        // intent from an unknown active state without MauLeaf's snapshot.
        if UserDefaults.standard.object(forKey: "desiredChargeLimitEnabled") == nil,
           state.active && state.hasOriginalStateSnapshot && !state.restorePending {
            setDesiredLimitEnabled(true)
        }
        let fullChargeJustEnded = fullOncePending && !oneTime.pending
        fullOncePending = oneTime.pending
        fullOnceCancelRequested = oneTime.cancelRequested
        if fullChargeJustEnded {
            // The Helper has already restored the last effective interval.
            // Re-enter the dynamic policy only after that verified transition.
            dynamicSessionUpper = nil
            dynamicNeedsNewCapture = true
            dynamicACStableSince = Date()
        }
        backendReady = state.writeSupported
        restoreReady = state.restoreSupported
        recomputeAboveLimitPowerFinding()

        // The UI always stores the user's desired ceiling, never the
        // temporary firmware ceiling used by Dynamic Hold.
        if !dynamicHoldEnabled {
            if oneTime.pending, let restoreUpper = oneTime.restoreUpper,
               (50...95).contains(restoreUpper) {
                limit = restoreUpper
            } else if state.active, (50...95).contains(state.upper) {
                limit = state.upper
            }
        } else if state.active && state.hasOriginalStateSnapshot
                    && state.upper > limit && dynamicLastAC != .some(false)
                    && dynamicSessionUpper == nil && !dynamicNeedsNewCapture {
            // Recovered after a restart: adopt the existing hold until a
            // *confirmed* unplug/replug, avoiding repeated SMC rewrites.
            dynamicSessionUpper = state.upper
        }
        if started {
            if latestBatteryObservation?.isACConnected == false
                && state.hasOriginalStateSnapshot && !state.restorePending {
                scheduleUnpluggedFirmwareRestore()
            } else if isAdapterConnected {
                if state.hasOriginalStateSnapshot && !oneTime.pending
                    && (state.active || needsManagedBootReapply) {
                    scheduleDynamicHoldReconciliation()
                } else if !state.hasOriginalStateSnapshot {
                    scheduleReconnectLimitResume()
                }
            }
        }

        if state.restorePending {
            modeText = "等待恢复原始固件配置"
            statusMessage = "原始配置快照已保留；接入电源后后台服务会继续恢复。"
            isError = false
        } else if oneTime.pending && oneTime.cancelRequested {
            modeText = "等待接电后恢复原生充电上限"
            statusMessage = AppText(verbatim: oneTime.cancelRequested
                ? "已请求取消本次充满；接入电源后会恢复当前限充设置。"
                : status.localized(in: language))
            isError = false
        } else if oneTime.pending {
            modeText = "本次充满进行中 · 原上限 \(oneTime.restoreUpper ?? limit)%"
            statusMessage = status
            isError = false
        } else if state.isActiveZeroed {
            modeText = "固件控制异常 · 已阻止新的限充写入"
            statusMessage = state.hasOriginalStateSnapshot
                ? "重启后读到激活的无效固件上限 0/0；原始快照已保留。请连接充电器后通过关闭限充恢复原始配置。"
                : "重启后读到激活的无效固件上限 0/0，且没有可信原始快照；已阻止写入，请保留 Helper 并反馈诊断。"
            isError = true
        } else if state.isInactiveUninitialized {
            modeText = "固件重启后尚未初始化限充阈值"
            if state.hasOriginalStateSnapshot || (state.hasReconnectBaseline && state.writeSupported) {
                statusMessage = "已保留原始固件快照；待连接电源稳定后恢复原先的限充设置。"
                isError = false
            } else {
                statusMessage = "固件限充阈值尚未初始化。保持电源连接，点击固件未就绪重新检测；若持续异常，请正常重启 Mac 后重试。未写入固件。"
                isError = true
            }
        } else if state.active && state.hasOriginalStateSnapshot {
            modeText = "限制充电已启用 · 上限 \(state.upper)%"
            statusMessage = status
            isError = false
        } else if state.active {
            modeText = "检测到旧版或未托管的固件限充"
            statusMessage = "没有找到启用前的原始快照；停用时只能关闭激活标志，无法恢复历史阈值。"
            isError = false
        } else {
            modeText = "限制充电未启用"
            statusMessage = status
            isError = false
        }

        if state.isActiveZeroed || state.isInactiveUninitialized {
            // Do not overwrite a specific safety warning with the generic
            // "unsupported" message; a trusted snapshot is recoverable.
        } else if !state.writeSupported && !state.restoreSupported {
            statusMessage = AppText(verbatim: state.writeBlockReason ?? "当前硬件配置未通过原生写入验证。")
            isError = true
        } else if !state.writeSupported && state.restoreSupported {
            if state.hasOriginalStateSnapshot {
                statusMessage = "当前系统不允许启用新的限充配置，但可以使用已保存快照恢复原始状态。"
            } else if state.active {
                statusMessage = "当前系统不允许启用新的限充配置，但可以停用旧版限充；历史阈值无法恢复。"
            } else {
                statusMessage = "当前系统不支持新的充电限制写入；限制充电保持关闭。"
            }
            isError = false
        }
    }

    private func isHelperUnavailable(_ error: Error) -> Bool {
        guard let helperError = error as? FirmwareLimitHelperClientError else { return false }
        switch helperError {
        case .serviceUnavailable, .connectionInvalidated, .timedOut: return true
        default: return false
        }
    }

    private func installNativeHelper() async throws {
        guard let resources = Bundle.main.resourceURL?
            .appendingPathComponent("MauLeafNativeControl", isDirectory: true) else {
            throw NativeControlError.missingBundledHelper
        }
        let script = resources.appendingPathComponent("install-native-firmware-helper.sh")
        guard FileManager.default.isExecutableFile(atPath: script.path) else {
            throw NativeControlError.missingBundledHelper
        }
        let command = shellQuote(script.path)
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let result = try await runProcess(
            path: "/usr/bin/osascript",
            arguments: ["-e", "do shell script \"\(escaped)\" with administrator privileges"]
        )
        guard result.status == 0 else {
            let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw NativeControlError.authorizationFailed(
                detail.isEmpty ? "管理员授权被取消或原生服务安装失败（退出码 \(result.status)）" : detail
            )
        }
    }

    func requestLimit(_ value: Int, immediate: Bool = false) {
        guard !isPreparingToQuit, (50...95).contains(value) else { return }
        limit = value
        dynamicSessionUpper = nil
        dynamicNeedsNewCapture = dynamicHoldEnabled
        dynamicRetryAfter = nil
        limitDebounce?.cancel()

        guard currentState?.active == true, hasOriginalStateSnapshot else {
            autoApplyFeedback = "已保存设置；启用限制充电后生效"
            statusMessage = "当前限制充电未启用，此次调整仅保存在 MauLeaf 中。"
            isError = false
            return
        }
        guard !fullOncePending else {
            statusMessage = "本次充满进行中，暂不可修改充电上限。"
            isError = true
            return
        }
        guard backendReady else {
            statusMessage = "当前系统或硬件配置不允许写入新的充电上限。"
            isError = true
            return
        }
        guard isAdapterConnected else {
            statusMessage = "请先连接电源，再修改原生固件充电上限。"
            isError = true
            return
        }
        autoApplyFeedback = "等待自动应用 \(value)%…"
        if !UserDefaults.standard.bool(forKey: "nativeFirmwareWriteConfirmed") {
            pendingAction = .limit(value)
            showNativeWriteConfirmation = true
            return
        }
        lastAction = .limit(value)
        limitDebounce = Task { [weak self] in
            if !immediate { try? await Task.sleep(nanoseconds: 450_000_000) }
            guard !Task.isCancelled else { return }
            await self?.applyLimit(value)
        }
    }

    /// All Helper version mismatches use one service-only uninstall/reinstall
    /// path. Persistent firmware snapshots and recovery jobs are not touched.
    private func replaceNativeHelperAfterStartupCheck() async {
        await replaceNativeHelper(
            progress: "控制服务版本不匹配，正在卸载旧版并安装应用内置版本…",
            success: "原生控制服务已重新安装并验证。",
            failure: "原生控制服务自动重装未完成"
        )
    }

    private func repairNativeHelperAfterUserAction() async {
        await replaceNativeHelper(
            progress: "正在卸载旧版控制服务并安装应用内置版本，需要管理员授权…",
            success: "原生控制服务已重新安装并验证。",
            failure: "无法重新安装原生控制服务"
        )
    }

    private func replaceNativeHelper(
        progress: AppText,
        success: AppText,
        failure: AppText
    ) async {
        guard !isBusy, !isPreparingToQuit,
              helperNeedsUpgrade || (helperStateUnknown && !helperVersionVerified) else { return }
        activeOperation = .repairingHelper
        defer { activeOperation = nil }
        isBusy = true
        isError = false
        statusMessage = progress
        do {
            if let helperInstallerForTesting {
                try await helperInstallerForTesting()
            } else {
                try await installNativeHelper()
            }

            let info = try await backend.readHelperInfo()
            guard FirmwareLimitHelperProtocolVersion.isCompatible(info) else {
                throw NativeControlError.helperVersionMismatch
            }
            let state = try await backend.readState()
            guard FirmwareLimitHelperProtocolVersion.isCompatible(
                state.helperVersion, build: state.helperBuildVersion
            ) else {
                throw NativeControlError.helperUpgradeFailed
            }
            let once = try await backend.oneTimeChargeStatus()
            updateFromNativeState(state, oneTime: once, status: success)
            attemptedStartupHelperUpgrade = false
            isBusy = false
        } catch {
            isBusy = false
            await refreshNativeState()
            statusMessage = "\(failure)：\(AppText(error: error))"
            isError = true
        }
    }

    private func helperInstallSafetyBlockReason(
        state: FirmwareLimitHelperStateResponse,
        oneTime: FirmwareLimitHelperOneTimeStatusResponse
    ) -> AppText? {
        if oneTime.pending { return "检测到尚未完成的本次充满任务，已保留任务记录。" }
        if state.restorePending { return "检测到尚未完成的原始固件恢复任务，请等待恢复完成。" }
        if state.hasOriginalStateSnapshot {
            return "检测到已保存的原始固件快照，必须先完成恢复或确认现有限充状态。"
        }
        if state.active { return "检测到当前固件限充仍处于激活状态，未覆盖现有配置。" }
        if !state.writeSupported {
            return state.writeBlockReason.map { AppText(verbatim: $0) }
                ?? "当前固件状态不允许写入新的充电限制。"
        }
        return nil
    }

    func enableLimit() {
        guard canEnableLimit else {
            statusMessage = isAdapterConnected
                ? "当前设备暂时不能启用限制充电。"
                : "请先连接电源，再启用限制充电。"
            isError = true
            return
        }
        if !UserDefaults.standard.bool(forKey: "nativeFirmwareWriteConfirmed") {
            pendingAction = .enable
            showNativeWriteConfirmation = true
            return
        }
        lastAction = .enable
        Task { await enableLimitAfterConsent() }
    }

    /// The only privileged install/upgrade trigger is explicit opt-in.
    private func enableLimitAfterConsent() async {
        guard canEnableLimit else { return }
        activeOperation = .enablingLimit
        defer { activeOperation = nil }
        if helperNeedsInstallation || helperNeedsUpgrade {
            isBusy = true
            isError = false
            statusMessage = "正在安装或更新原生固件服务，需要管理员授权…"
            do {
                if let helperInstallerForTesting {
                    try await helperInstallerForTesting()
                } else {
                    try await installNativeHelper()
                }
                // Confirm the exact bundled Helper before reading hardware.
                let info = try await backend.readHelperInfo()
                guard FirmwareLimitHelperProtocolVersion.isCompatible(info) else {
                    throw NativeControlError.helperVersionMismatch
                }
                let state = try await backend.readState()
                guard FirmwareLimitHelperProtocolVersion.isCompatible(
                    state.helperVersion, build: state.helperBuildVersion
                ) else {
                    throw NativeControlError.helperUpgradeFailed
                }
                let once = try await backend.oneTimeChargeStatus()
                updateFromNativeState(state, oneTime: once, status: "原生控制服务已就绪。")
                attemptedStartupHelperUpgrade = false
                if state.isInactiveUninitialized && !state.writeSupported
                    && !state.active && !state.hasOriginalStateSnapshot && !state.restorePending && !once.pending {
                    // Installation succeeded. This is a hardware-readiness
                    // state, not a failed Helper installation.
                    isBusy = false
                    return
                }
                if let reason = helperInstallSafetyBlockReason(state: state, oneTime: once) {
                    throw NativeControlError.unsafeStateAfterInstall(reason)
                }
            } catch {
                isBusy = false
                await refreshNativeState()
                statusMessage = "无法准备原生控制服务：\(AppText(error: error))"
                isError = true
                return
            }
            isBusy = false
        }
        guard canEnableLimit else {
            statusMessage = "无法确认固件控制状态，未写入充电限制。"
            isError = true
            return
        }
        await applyLimit(limit)
    }

    func disableLimit() {
        guard (canDisableLimit || canRetryOriginalRestore) else { return }
        setDesiredLimitEnabled(false)
        automaticReconnectApplyTask?.cancel()
        automaticReconnectApplyTask = nil
        lastAction = nil
        Task { await restoreOriginalFirmwareState() }
    }

    func requestLegacyDisableConfirmation() {
        guard canDisableLegacyLimit else { return }
        showLegacyDisableConfirmation = true
    }

    func confirmDisableLegacyLimit() {
        showLegacyDisableConfirmation = false
        guard canDisableLegacyLimit else { return }
        setDesiredLimitEnabled(false)
        Task { await restoreOriginalFirmwareState() }
    }

    var canForceReset: Bool {
        helperVersionVerified && !helperNeedsUpgrade && !isBusy && !isPreparingToQuit
    }

    func requestForceReset() {
        guard canForceReset else { return }
        showForceResetConfirmation = true
    }

    func confirmForceReset() {
        showForceResetConfirmation = false
        guard canForceReset else { return }
        setDesiredLimitEnabled(false)
        UserDefaults.standard.set(false, forKey: "desiredChargeLimitEnabled")
        limitDebounce?.cancel()
        limitDebounce = nil
        dynamicReconcileTask?.cancel()
        dynamicReconcileTask = nil
        automaticUnplugRestoreTask?.cancel()
        automaticUnplugRestoreTask = nil
        automaticReconnectApplyTask?.cancel()
        automaticReconnectApplyTask = nil
        pendingAction = nil
        lastAction = nil
        dynamicSessionUpper = nil
        dynamicNeedsNewCapture = true
        isBusy = true
        activeOperation = .restoringLimit
        isError = false
        statusMessage = "正在重置充电控制…"
        Task {
            defer { isBusy = false; activeOperation = nil }
            do {
                _ = try await backend.restoreOriginalState()
                let state = try await backend.readState()
                let once = try await backend.oneTimeChargeStatus()
                updateFromNativeState(state, oneTime: once, status: "充电控制已重置。")
                guard !state.active, !state.hasOriginalStateSnapshot,
                      !state.hasReconnectBaseline, !state.restorePending, !once.pending else {
                    statusMessage = "重置尚未完成；已保留恢复数据，请保持电源连接后重试。"
                    isError = true
                    return
                }
                if state.writeSupported {
                    statusMessage = "充电控制已重置，所有充电任务已取消，可重新启用限充。"
                    isError = false
                } else {
                    statusMessage = "充电任务已清除，但固件阈值仍未就绪。请保持接电并重新检测，必要时重启 Mac。"
                    isError = true
                }
            } catch {
                NSLog("MauLeaf force reset failed: %@", error.localizedDescription)
                isBusy = false
                await refreshNativeState()
                statusMessage = "重置尚未完成；已保留恢复数据，请保持电源连接后重试。"
                isError = true
            }
        }
    }

    private func restoreOriginalFirmwareState() async {
        guard !isBusy, !isPreparingToQuit else { return }
        let hadOriginalSnapshot = hasOriginalStateSnapshot
        let hadLegacyLimit = isLegacyActive
        activeOperation = .restoringLimit
        isBusy = true
        isError = false
        statusMessage = "正在恢复启用前的原始固件配置…"
        defer { isBusy = false; activeOperation = nil }
        do {
            let response = try await backend.restoreOriginalState()
            currentState = response.state
            fullOncePending = false
            fullOnceCancelRequested = false
            backendReady = response.state.writeSupported
            restoreReady = response.state.restoreSupported
            modeText = response.state.active
                ? "检测到未托管的固件限充"
                : "限制充电未启用"
            // The root helper speaks English and may include a long audit
            // explanation. Keep it for diagnostics, not the user-facing toast.
            NSLog("MauLeaf original-state restore: %@", response.message)
            if response.state.active {
                statusMessage = "已恢复启用前的原始固件配置。"
            } else if hadOriginalSnapshot {
                statusMessage = "已关闭限制充电，原始固件配置已恢复。"
            } else if hadLegacyLimit {
                statusMessage = "已关闭旧版限充，历史阈值未知。"
            } else {
                statusMessage = "限充未启用，已核对固件状态。"
            }
            isError = false
        } catch {
            isBusy = false
            await refreshNativeState()
            if restorePending && !fullOncePending {
                modeText = "等待接电后恢复固件配置"
                statusMessage = "已提交持久恢复请求，接入电源后后台服务会自动恢复。"
                isError = false
            } else {
                statusMessage = "恢复原始固件配置失败：\(AppText(error: error))"
                isError = true
            }
        }
    }

    func beginOneTimeFullCharge() {
        guard canStartFullCharge, (batteryPercent ?? 0) < 100 else { return }
        if !UserDefaults.standard.bool(forKey: "nativeFirmwareWriteConfirmed") {
            pendingAction = .full
            showNativeWriteConfirmation = true
            return
        }
        lastAction = .full
        Task { await applyOneTimeFullCharge() }
    }

    func confirmNativeWrite() {
        UserDefaults.standard.set(true, forKey: "nativeFirmwareWriteConfirmed")
        showNativeWriteConfirmation = false
        guard let action = pendingAction else { return }
        pendingAction = nil
        switch action {
        case .enable:
            lastAction = .enable
            Task { await enableLimitAfterConsent() }
        case .limit(let value):
            lastAction = .limit(value)
            Task { await applyLimit(value) }
        case .full:
            lastAction = .full
            Task { await applyOneTimeFullCharge() }
        }
    }

    func cancelNativeWrite() {
        showNativeWriteConfirmation = false
        let action = pendingAction
        pendingAction = nil
        if let action, case .limit = action, currentState?.active == true,
           let currentState, (50...95).contains(currentState.upper) {
            limit = currentState.upper
        }
    }

    func cancelFullOnce() {
        guard !isBusy, !isPreparingToQuit else { return }
        lastAction = .full
        Task {
            activeOperation = .cancelingFullCharge
            isBusy = true
            isError = false
            statusMessage = "正在取消本次充满并恢复原生充电上限…"
            defer { isBusy = false; activeOperation = nil }
            do {
                let response = try await backend.cancelOneTimeCharge()
                currentState = response.state
                backendReady = response.state.writeSupported
                restoreReady = response.state.restoreSupported
                fullOncePending = response.oneTimePending
                fullOnceCancelRequested = response.oneTimePending
                modeText = response.oneTimePending
                    ? "等待接电后恢复原生充电上限"
                    : "原生固件限充至 \(response.state.upper)%"
                NSLog("MauLeaf one-time charge cancellation: %@", response.message)
                statusMessage = response.oneTimePending
                    ? "已请求取消本次充满，等待恢复充电上限。"
                    : "已取消本次充满，原充电上限已恢复。"
                isError = false
                if !response.oneTimePending {
                    dynamicSessionUpper = nil
                    dynamicNeedsNewCapture = true
                    // Do not race the Helper or try another SMC write while
                    // the cancellation operation still has the busy lock.
                    dynamicACStableSince = Date()
                    scheduleDynamicHoldReconciliation()
                }
            } catch {
                statusMessage = "取消本次充满失败：\(AppText(error: error))"
                isError = true
            }
        }
    }

    private func applyLimit(_ value: Int) async {
        guard backendReady, isAdapterConnected, !isBusy, !isPreparingToQuit,
              !fullOncePending else { return }
        // Only Dynamic Hold requires a fresh, precise hardware SoC.
        // Ordinary charge limiting retains its original validated flow,
        // including test machines without AppleSmartBattery.
        if dynamicHoldEnabled {
            readSystemBattery(allowDynamicScheduling: false)
            guard isAdapterConnected else { return }
        }
        guard let plan = computedDynamicPlan(userTarget: value) else {
            statusMessage = "无法读取精确电池电量；动态保电未执行固件写入。"
            isError = true
            return
        }
        activeOperation = activeOperation == .enablingLimit ? .enablingLimit : .adjustingLimit
        isBusy = true
        isError = false
        statusMessage = "正在写入原生固件充电上限 \(plan.upper)%…"
        autoApplyFeedback = "正在应用 \(plan.upper)%…"
        defer {
            isBusy = false
            activeOperation = nil
            if !isAdapterConnected { scheduleUnpluggedFirmwareRestore() }
        }
        do {
            let response = try await backend.applyLimit(
                upper: plan.upper,
                lower: plan.lower,
                confirmed: true
            )
            guard response.state.active && response.state.upper == plan.upper
                    && response.state.lower == plan.lower else {
                throw NativeControlError.unsafeStateAfterInstall("固件写入后的寄存器读回结果与请求不一致。")
            }
            currentState = response.state
            backendReady = response.state.writeSupported
            restoreReady = response.state.restoreSupported
            fullOncePending = response.oneTimePending
            fullOnceCancelRequested = false
            setDesiredLimitEnabled(true)
            dynamicSessionUpper = plan.isTemporary ? plan.upper : nil
            dynamicNeedsNewCapture = false
            dynamicRetryAfter = nil
            lastDynamicAppliedUpper = plan.isTemporary ? plan.upper : nil
            recomputeAboveLimitPowerFinding()
            modeText = "限制充电已启用 · 目标 \(value)%"
            autoApplyFeedback = "已写入并读回 \(plan.upper)%"
            NSLog("MauLeaf firmware limit apply: %@", response.message)
            statusMessage = plan.isTemporary
                ? "动态保电已应用：目标 \(value)%，临时上限 \(plan.upper)%。"
                : "充电上限已设为 \(response.state.upper)%，固件写入已验证。"
            isError = false
        } catch {
            dynamicRetryAfter = Date().addingTimeInterval(60)
            autoApplyFeedback = "原生固件写入失败：\(AppText(error: error))"
            statusMessage = autoApplyFeedback
            isError = true
        }
    }

    private func applyOneTimeFullCharge() async {
        guard backendReady, isAdapterConnected, !isBusy, !isPreparingToQuit,
              (batteryPercent ?? 0) < 100 else { return }
        activeOperation = .startingFullCharge
        isBusy = true
        isError = false
        statusMessage = "正在启动原生本次充满任务…"
        defer {
            isBusy = false
            activeOperation = nil
            if !isAdapterConnected { scheduleUnpluggedFirmwareRestore() }
        }
        do {
            let response = try await backend.beginOneTimeCharge(
                upper: currentState?.upper ?? limit,
                lower: currentState?.lower ?? max(5, limit - 2),
                confirmed: true
            )
            currentState = response.state
            backendReady = response.state.writeSupported
            restoreReady = response.state.restoreSupported
            fullOncePending = response.oneTimePending
            fullOnceCancelRequested = false
            dynamicSessionUpper = nil
            dynamicNeedsNewCapture = true
            dynamicReconcileTask?.cancel()
            dynamicReconcileTask = nil
            recomputeAboveLimitPowerFinding()
            modeText = "本次充满进行中 · 原上限 \(limit)%"
            NSLog("MauLeaf one-time full charge: %@", response.message)
            statusMessage = "本次充满已开启，固件限充暂时关闭。"
            isError = false
        } catch {
            statusMessage = "启动本次充满失败：\(AppText(error: error))"
            isError = true
        }
    }

    func retryChargeRequest() {
        guard canRetryChargeRequest else { return }
        if !backendReady {
            Task { await refreshNativeState() }
            return
        }
        switch lastAction {
        case .enable: Task { await applyLimit(limit) }
        case .limit(let value): Task { await applyLimit(value) }
        case .full:
            if fullOncePending { cancelFullOnce() }
            else { Task { await applyOneTimeFullCharge() } }
        case nil: refresh()
        }
    }

    /// A normal application quit is a firmware recovery transaction, not
    /// merely a UI shutdown. A failed or unverifiable restore cancels quitting.
    /// The privileged helper retains the original snapshot for retry.
    func prepareForTermination() async -> Bool {
        guard !isPreparingToQuit else { return false }
        isPreparingToQuit = true
        powerFlowTimer?.invalidate()
        powerFlowTimer = nil
        powerFlowGeneration &+= 1
        didVerifyFirmwareOnQuit = false
        limitDebounce?.cancel()
        limitDebounce = nil
        dynamicReconcileTask?.cancel()
        dynamicReconcileTask = nil
        automaticUnplugRestoreTask?.cancel()
        automaticUnplugRestoreTask = nil
        automaticReconnectApplyTask?.cancel()
        automaticReconnectApplyTask = nil
        pendingAction = nil
        lastAction = nil
        showNativeWriteConfirmation = false
        showLegacyDisableConfirmation = false
        showForceResetConfirmation = false

        let deadline = Date().addingTimeInterval(30)
        while isBusy {
            guard Date() < deadline else {
                return cancelTermination("原生固件操作仍在进行；无法确认恢复状态。")
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        isBusy = true
        isError = false
        statusMessage = "退出前正在核对固件状态并提交恢复请求…"

        do {
            if currentState == nil && !helperArtifactsPresent() {
                // No root helper or saved recovery artifacts to restore.
                didVerifyFirmwareOnQuit = true
                statusMessage = "未安装控制组件，无须恢复固件。"
                isError = false
                isBusy = false
                return true
            }
            let state = try await backend.readState()
            // Known previous protocol v4 has the same verified restore XPC
            // and CLI contract. Allow safe restoration without forcing a
            // reinstall just to quit; never trust arbitrary older/newer ones.
            guard FirmwareLimitHelperProtocolVersion.isCompatible(state.helperVersion, build: state.helperBuildVersion)
                    || state.helperVersion == 4 || state.helperVersion == 5 else {
                return cancelTermination("控制服务不支持当前恢复协议，请先完成安全升级；恢复数据将保留。")
            }
            let oneTime = try await backend.oneTimeChargeStatus()
            let needsRestore = state.active || state.hasOriginalStateSnapshot
                || state.hasReconnectBaseline || state.restorePending || oneTime.pending

            if needsRestore {
                guard state.restoreSupported else {
                    return cancelTermination("当前硬件无法安全恢复：\(state.restoreBlockReason ?? "身份校验失败")")
                }
                // Always attempt exact restoration immediately, including on
                // battery for the verified M1 Pro firmware profile. If it
                // cannot finish, the helper persists a recovery request;
                // normal quit is NOT reported as successful in that case.
                do {
                    _ = try await backend.restoreOriginalState()
                } catch {
                    NSLog("MauLeaf immediate restore unavailable; checking durable recovery: %@", error.localizedDescription)
                }
            }

            let verified = try await backend.readState()
            let verifiedOneTime = try await backend.oneTimeChargeStatus()
            let restored = !verified.active
                && !verified.hasOriginalStateSnapshot
                && !verified.hasReconnectBaseline
                && !verified.restorePending
                && !verifiedOneTime.pending
            let queued = verified.restorePending && !verifiedOneTime.pending

            // Publish the observed pending-restore state even when normal quit
            // is denied, so the UI accurately reports the retained snapshot
            // instead of incorrectly showing the pre-exit state.
            currentState = verified
            fullOncePending = verifiedOneTime.pending
            fullOnceCancelRequested = verifiedOneTime.cancelRequested
            backendReady = verified.writeSupported
            restoreReady = verified.restoreSupported

            // macOS users normally trash the app after quitting it. Never
            // treat "recovery queued" as the success path for an ordinary
            // quit: this may be the last chance for the app to restore its
            // firmware before the user deletes it. The root helper keeps the
            // snapshot and background recovery marker if a quit is forced.
            guard restored else {
                let detail = queued
                    ? "固件尚未恢复：已保留后台恢复任务。请连接电源或改善电池状态后重试正常退出；若仍然退出，删除应用前请先确认恢复完成。"
                    : "无法确认三个固件寄存器已恢复，请勿删除 MauLeaf 或恢复服务。"
                return cancelTermination(AppText(key: detail))
            }

            currentState = verified
            fullOncePending = false
            fullOnceCancelRequested = false
            backendReady = verified.writeSupported
            restoreReady = verified.restoreSupported
            modeText = "限制充电未启用"
            setDesiredLimitEnabled(false)
            didVerifyFirmwareOnQuit = true
            statusMessage = "退出前已将限充恢复至原始固件配置并完成校验。现在可以安全关闭应用。"
            isError = false
            isBusy = false
            // The helper still needs to stop or remove its own running
            // system components before we reply to NSApp that quit is safe.
            return true
        } catch {
            return cancelTermination("退出时无法确认固件恢复状态：\(AppText(error: error))")
        }
    }

    /// Keep the launchd MachService registered for password-free relaunch.
    /// Its root process self-exits after 20s idle with no pending recovery.
    func finishQuitComponentCleanup(_ policy: QuitComponentPolicy) async -> Bool {
        guard isPreparingToQuit, didVerifyFirmwareOnQuit, !isBusy else { return false }
        isBusy = true
        do {
            if policy == .remove {
                if let exitLifecycleForTesting {
                    try await exitLifecycleForTesting(policy)
                } else if autoInstallNativeHelper && helperArtifactsPresent() {
                    try await runPrivilegedNativeExitScript(policy: .remove)
                }
            }
            // Keep needs no root script, no launchctl bootout, no password.
            isBusy = false
            refreshTimer?.invalidate()
            refreshTimer = nil
            powerFlowTimer?.invalidate()
            powerFlowTimer = nil
            powerFlowGeneration &+= 1
            panelVisible = false
            powerRecheckTask?.cancel()
            powerRecheckTask = nil
            dynamicReconcileTask?.cancel()
            dynamicReconcileTask = nil
            automaticUnplugRestoreTask?.cancel()
            automaticUnplugRestoreTask = nil
            automaticReconnectApplyTask?.cancel()
            automaticReconnectApplyTask = nil
            powerSourceObserver?.stop()
            powerSourceObserver = nil
            return true
        } catch {
            return cancelTermination("固件已恢复，但无法安全处理后台控制组件：\(AppText(error: error))")
        }
    }

    private func runPrivilegedNativeExitScript(policy: QuitComponentPolicy) async throws {
        guard let resources = Bundle.main.resourceURL?
            .appendingPathComponent("MauLeafNativeControl", isDirectory: true) else {
            throw NativeControlError.missingBundledHelper
        }
        let script = resources.appendingPathComponent("uninstall-native-firmware-helper.sh")
        guard FileManager.default.isExecutableFile(atPath: script.path) else {
            throw NativeControlError.missingBundledHelper
        }
        let command = shellQuote(script.path) + " " + shellQuote(policy.rawValue)
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let result = try await runProcess(
            path: "/usr/bin/osascript",
            arguments: ["-e", "do shell script \"\(escaped)\" with administrator privileges"]
        )
        guard result.status == 0 else {
            let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw NativeControlError.authorizationFailed(
                detail.isEmpty
                    ? "管理员授权取消或后台控制组件处理失败（退出码 \(result.status)）"
                    : detail
            )
        }
    }

    private func cancelTermination(_ message: AppText) -> Bool {
        isBusy = false
        isPreparingToQuit = false
        restartPowerFlowTimer()
        isError = true
        statusMessage = message
        return false
    }

    private func readSystemBattery(
        allowDynamicScheduling: Bool = true,
        updateDisplayedPowerFlow: Bool = true
    ) {
        let snapshot = batteryReader()
        recordPowerObservation(snapshot)
        if updateDisplayedPowerFlow {
            powerFlow = MauLeafPowerFlow(snapshot: snapshot)
        }
        batteryPercent = snapshot.percent
        isAdapterConnected = snapshot.isACConnected == true
        if allowDynamicScheduling {
            observeDynamicPowerConnection(snapshot.isACConnected)
            // With the same charger session, only a genuine policy divergence
            // (e.g. falling below original target) needs another SMC write.
            // Scheduling is debounced; a matching SMC interval is a no-op.
            if snapshot.isACConnected == true,
               currentState?.active == true || needsManagedBootReapply {
                scheduleDynamicHoldReconciliation()
            } else if snapshot.isACConnected == false,
                      currentState?.hasOriginalStateSnapshot == true {
                scheduleUnpluggedFirmwareRestore()
            }
        }

        switch snapshot.isACConnected {
        case .some(true):
            if snapshot.isFullyCharged || snapshot.percent == 100 {
                batteryStateText = "已接电源，已充满"
            } else if snapshot.isCharging {
                batteryStateText = "正在充电"
            } else {
                batteryStateText = "已接电源，未充电"
            }
        case .some(false):
            batteryStateText = "电池供电"
        case .none:
            batteryStateText = "电池状态不可用"
        }
    }

    private func runProcess(path: String, arguments: [String]) async throws -> (status: Int32, output: String) {
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
            } catch {
                throw error
            }
        }.value
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private enum NativeControlError: LocalizedError {
    case missingBundledHelper
    case authorizationFailed(String)
    case helperUpgradeFailed
    case helperVersionMismatch
    case unsafeStateAfterInstall(AppText)

    var errorDescription: String? {
        switch self {
        case .missingBundledHelper:
            return "应用包中缺少 MauLeaf 原生固件服务文件，请重新安装 MauLeaf。"
        case .authorizationFailed(let detail):
            return detail
        case .helperVersionMismatch:
            return AppText(key: "重装后的 Helper 版本仍与应用要求不一致，请检查应用包或重新下载 MauLeaf。")
                .localized(in: AppLanguage.saved())
        case .unsafeStateAfterInstall(let reason):
            let message: AppText = "原生服务已安装，但当前固件状态不允许启用新的限充：\(reason)"
            return message.localized(in: AppLanguage.saved())
        case .helperUpgradeFailed:
            return AppText(key: "重装后的 Helper 仍与应用要求的版本不一致，请检查应用包或重新下载 MauLeaf。")
                .localized(in: AppLanguage.saved())
        }
    }
}
