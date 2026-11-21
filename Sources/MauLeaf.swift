import SwiftUI
import AppKit
import Combine
import Foundation

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
    private var lastPanelHeight: CGFloat = 0

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 480),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.title = "MauLeaf"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]

        // Scroll only if the visible screen is too short for the current content.
        // The measured height includes all SwiftUI padding, install prompts and
        // error messages. Do not size the NSPanel from a fixed estimate.
        let root = ScrollView {
            ContentView(manager: manager)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: PanelContentHeightPreferenceKey.self,
                            value: proxy.size.height
                        )
                    }
                }
        }
        .onPreferenceChange(PanelContentHeightPreferenceKey.self) { [weak self] height in
            // Layout callbacks must not synchronously resize the AppKit window
            // while SwiftUI is still calculating its layout.
            DispatchQueue.main.async { [weak self] in
                self?.updateContentHeight(height)
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(width: panelWidth)
        panel.contentView = NSHostingView(rootView: root)

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
        positionPanel()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        let question = NSAlert()
        question.alertStyle = .informational
        question.messageText = manager.text("退出时是否保留控制组件？")
        question.informativeText = manager.text("两种方式都会先恢复并验证原始充电配置，停止后台服务。保留组件便于下次启动；移除组件会删除特权 Helper、LaunchDaemon 和系统脚本，退出后可将 App 移入废纸篓。")
        question.addButton(withTitle: manager.text("保留组件并退出"))
        question.addButton(withTitle: manager.text("移除组件并退出"))
        question.addButton(withTitle: manager.text("取消"))
        let answer = question.runModal()
        let policy: QuitComponentPolicy
        switch answer {
        case .alertFirstButtonReturn: policy = .keep
        case .alertSecondButtonReturn: policy = .remove
        default: return false
        }

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
            // Never hide an open confirmation sheet or an in-flight privilege request.
            if panel.attachedSheet != nil || manager.isBusy {
                NSApp.activate(ignoringOtherApps: true)
                panel.makeKeyAndOrderFront(nil)
                return
            }
            dismissPanelIfAllowed()
            return
        }
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
        guard panel.isVisible, panel.attachedSheet == nil, !manager.isBusy else { return }
        panel.orderOut(nil)
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
        // Ignore sub-point changes; these can otherwise create a preference/
        // window-layout feedback loop while the scrollbar appears or disappears.
        guard abs(height - measuredContentHeight) >= 1 else { return }
        measuredContentHeight = height
        if panel.isVisible {
            positionPanel()
        }
    }

    private func positionPanel() {
        guard let button = statusItem.button, let window = button.window else { return }
        let screen = window.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let menuRect = window.convertToScreen(button.convert(button.bounds, to: nil))

        // Anchor the TOP edge just below the menu bar even when the panel grows
        // after an installation prompt appears or collapses after installation.
        let anchorTop = min(menuRect.minY - 5, visible.maxY - 2)
        let maxHeight = max(120, anchorTop - visible.minY - 6)
        let wantedHeight = measuredContentHeight > 0 ? ceil(measuredContentHeight + 2) : 480
        let height = min(max(wantedHeight, 160), maxHeight)
        let x = min(max(menuRect.midX - panelWidth / 2, visible.minX + 6), visible.maxX - panelWidth - 6)

        if abs(height - lastPanelHeight) >= 1 {
            panel.setContentSize(NSSize(width: panelWidth, height: height))
            lastPanelHeight = height
        }
        panel.setFrameOrigin(NSPoint(x: x, y: anchorTop - height))
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
    @State private var limitExpanded = false
    @State private var settingsExpanded = false
    private let presets = [70, 75, 80, 85, 90, 95]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            batteryCard
                .padding(.bottom, 8)

            // Errors and quit operations participate in layout instead of
            // covering the Settings and Quit controls at the bottom.
            OperationFeedbackView(manager: manager)

            menuRow(
                icon: "slider.horizontal.3",
                title: "充电上限",
                value: "\(manager.limit)%",
                expanded: limitExpanded
            ) {
                withAnimation(.easeInOut(duration: 0.18)) {
                    limitExpanded.toggle()
                    if limitExpanded { settingsExpanded = false }
                }
            }

            if limitExpanded {
                limitControls
                    .padding(.leading, 30)
                    .padding(.trailing, 2)
                    .padding(.bottom, 12)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            rowDivider

            menuRow(
                icon: "gearshape",
                title: "设置",
                expanded: settingsExpanded
            ) {
                withAnimation(.easeInOut(duration: 0.18)) {
                    settingsExpanded.toggle()
                    if settingsExpanded { limitExpanded = false }
                }
            }

            if settingsExpanded {
                settingsControls
                    .padding(.leading, 30)
                    .padding(.bottom, 10)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            rowDivider

            Button {
                NSApp.terminate(nil)
            } label: {
                HStack(spacing: 11) {
                    Image(systemName: "power")
                        .font(.system(size: 16, weight: .medium))
                        .frame(width: 20)
                    Text(manager.text("退出 MauLeaf"))
                        .font(.subheadline.weight(.medium))
                    Spacer()
                }
                .contentShape(Rectangle())
                .padding(.vertical, 13)
            }
            .buttonStyle(.plain)
            .disabled(manager.isPreparingToQuit)
            .help(manager.text("正常退出会先关闭限制充电并验证恢复。若无法安全恢复，将取消退出。"))
        }
        .padding(.horizontal, 16)
        .padding(.top, 17)
        .padding(.bottom, 9)
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
        .task { manager.start() }
    }

    /// The default card is a compact three-row control surface. The
    /// optional battery percentage adds a small header without reserving
    /// empty space when disabled.
    private var batteryCard: some View {
        VStack(alignment: .leading, spacing: 3) {
            if manager.showBatteryLevel {
                VStack(alignment: .leading, spacing: 3) {
                    Text(manager.text("当前电量"))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)

                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(manager.batteryPercent.map { String($0) } ?? "--")
                            .font(.system(size: 42, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(manager.batteryNumberColor)
                            .contentTransition(.numericText())

                        if manager.batteryPercent != nil {
                            Text("%")
                                .font(.system(size: 24, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .animation(.easeInOut(duration: 0.2), value: manager.batteryPercent)
                }
                .padding(.bottom, 3)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            statusRow(
                icon: "powerplug",
                title: "供电状态",
                status: manager.popoverPowerStatus,
                detail: manager.popoverPowerDetail,
                highlighted: manager.isActivelyCharging
            )
            statusDivider
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
        .padding(.horizontal, 17)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
        .animation(.easeInOut(duration: 0.2), value: manager.showBatteryLevel)
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

    private func menuRow(
        icon: String,
        title: AppText,
        value: String? = nil,
        expanded: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 11) {
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
            .padding(.vertical, 12)
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
                settingsLabel("显示当前电量")
                Spacer(minLength: 8)
                Picker("", selection: $manager.showBatteryLevel) {
                    Text(manager.language == .english ? "Hide" : "关闭").tag(false)
                    Text(manager.language == .english ? "Show" : "开启").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 142)
                .accessibilityLabel(manager.text("显示当前电量"))
                .help(manager.text("在顶部卡片中显示当前电量百分比"))
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
    @Published var batteryPercent: Int?
    @Published var batteryStateText = "正在读取电池状态…"
    @Published var isAdapterConnected = false
    @Published var limit: Int {
        didSet { UserDefaults.standard.set(limit, forKey: "chargeLimit") }
    }
    @Published var language = AppLanguage.saved() {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: AppLanguage.preferenceKey) }
    }
    /// New installs and upgrades default to the compact card. Changing this
    /// preference does not touch the privileged helper or firmware.
    @Published var showBatteryLevel: Bool {
        didSet { UserDefaults.standard.set(showBatteryLevel, forKey: "showBatteryLevel") }
    }
    @Published private(set) var menuBarLeafStyle: MenuBarLeafStyle = .green
    @Published private(set) var fullOncePending = false
    @Published private(set) var fullOnceCancelRequested = false
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
    @Published private(set) var helperNeedsInstallation = false
    @Published private(set) var helperNeedsUpgrade = false
    @Published private(set) var helperStateUnknown = false

    private let backend: NativeFirmwareBackend
    private let autoInstallNativeHelper: Bool
    private let exitLifecycleForTesting: ((QuitComponentPolicy) async throws -> Void)?
    private let helperInstallerForTesting: (() async throws -> Void)?
    private let helperArtifactsPresent: () -> Bool
    private let hardwareWriteBlockReason: String?
    private var started = false
    private var refreshTimer: Timer?
    private var limitDebounce: Task<Void, Never>?
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
        hardwarePreflightForTesting: (() -> String?)? = nil
    ) {
        self.backend = backend
        self.autoInstallNativeHelper = autoInstallNativeHelper
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
        showBatteryLevel = UserDefaults.standard.bool(forKey: "showBatteryLevel")
    }

    func text(_ message: AppText) -> String { message.localized(in: language) }

    var isActivelyCharging: Bool {
        batteryStateText == "正在充电"
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
            return "已启用 · \(currentState?.upper ?? limit)%"
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
        (helperNeedsUpgrade || helperStateUnknown) && helperArtifactsPresent()
            && !isBusy && !isPreparingToQuit
            && !(helperNeedsUpgrade && canEnableLimit)
    }

    /// All card actions reuse the existing hardware and restore safeguards.
    var canToggleLimitFromCard: Bool {
        if canRepairNativeHelper { return true }
        if isLegacyActive { return canDisableLegacyLimit }
        if hasOriginalStateSnapshot || restorePending {
            return canDisableLimit || canRetryOriginalRestore
        }
        return canEnableLimit
    }

    var limitCardActionHint: AppText {
        if canRepairNativeHelper { return "修复控制服务" }
        if isLegacyActive { return "停用旧版限制" }
        if restorePending || (hasOriginalStateSnapshot && currentState?.active != true && !fullOncePending) {
            return "恢复原始配置"
        }
        return hasOriginalStateSnapshot ? "关闭限制充电" : "启用限制充电"
    }

    func toggleLimitFromCard() {
        guard canToggleLimitFromCard else { return }
        if canRepairNativeHelper {
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
        Task { await refreshNativeState() }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isBusy else { return }
                self.readSystemBattery()
                await self.refreshNativeState()
            }
        }
    }

    func setPanelVisible(_ visible: Bool) {
        if visible { refresh() }
    }

    func refresh() {
        guard !isPreparingToQuit else { return }
        readSystemBattery()
        guard started, !isBusy else { return }
        Task { await refreshNativeState() }
    }

    private func refreshNativeState() async {
        guard !isPreparingToQuit, !isBusy else { return }
        do {
            let state = try await backend.readState()
            guard !isPreparingToQuit else { return }
            if state.helperVersion < FirmwareLimitHelperProtocolVersion.current {
                // Never silently reinstall root code on launch or timer refresh.
                currentState = state
                helperNeedsInstallation = false
                helperNeedsUpgrade = true
                helperStateUnknown = false
                backendReady = false
                restoreReady = false
                modeText = "原生控制服务需要更新"
                statusMessage = state.active || state.hasOriginalStateSnapshot || state.restorePending
                    ? "旧版控制服务存在未确认的限充或恢复状态，请勿移除恢复组件。"
                    : "点击启用限制充电时才会申请管理员授权更新服务。"
                isError = state.active || state.hasOriginalStateSnapshot || state.restorePending
                return
            }
            let once = try await backend.oneTimeChargeStatus()
            guard !isPreparingToQuit else { return }
            updateFromNativeState(state, oneTime: once, status: "已读取原生固件状态。")
        } catch {
            guard !isPreparingToQuit else { return }
            backendReady = false
            restoreReady = false
            helperNeedsUpgrade = false
            if isHelperUnavailable(error) && !helperArtifactsPresent() {
                // First launch, no Helper or root-owned recovery files.
                helperNeedsInstallation = true
                helperStateUnknown = false
                currentState = nil
                fullOncePending = false
                fullOnceCancelRequested = false
                modeText = "限制充电未启用"
                statusMessage = "未安装原生固件控制服务；点击启用限制充电时再请求授权。"
                isError = false
            } else {
                // Connection failure with existing files is NOT clean state.
                helperNeedsInstallation = false
                helperStateUnknown = true
                modeText = "固件控制状态未知"
                statusMessage = "无法连接固件控制服务；请保留恢复组件：\(AppText(error: error))"
                isError = true
            }
        }
    }

    private func updateFromNativeState(
        _ state: FirmwareLimitHelperStateResponse,
        oneTime: FirmwareLimitHelperOneTimeStatusResponse,
        status: AppText
    ) {
        currentState = state
        helperNeedsInstallation = false
        helperNeedsUpgrade = false
        helperStateUnknown = false
        fullOncePending = oneTime.pending
        fullOnceCancelRequested = oneTime.cancelRequested
        backendReady = state.writeSupported
        restoreReady = state.restoreSupported

        if oneTime.pending, let restoreUpper = oneTime.restoreUpper {
            limit = restoreUpper
        } else if state.active, (50...95).contains(state.upper) {
            limit = state.upper
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

        if !state.writeSupported && !state.restoreSupported {
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

    /// Explicit recovery of an installed but outdated/unreachable Helper.
    /// No charging-limit write occurs in this path.
    private func repairNativeHelperAfterUserAction() async {
        guard canRepairNativeHelper else { return }
        activeOperation = .repairingHelper
        defer { activeOperation = nil }
        isBusy = true
        isError = false
        statusMessage = "正在修复原生控制服务，需要管理员授权…"
        do {
            if let helperInstallerForTesting {
                try await helperInstallerForTesting()
            } else {
                try await installNativeHelper()
            }
            let state = try await backend.readState()
            guard state.helperVersion >= FirmwareLimitHelperProtocolVersion.current else {
                throw NativeControlError.helperUpgradeFailed(
                    found: state.helperVersion,
                    required: FirmwareLimitHelperProtocolVersion.current
                )
            }
            let once = try await backend.oneTimeChargeStatus()
            updateFromNativeState(state, oneTime: once, status: "原生控制服务已修复。")
            isBusy = false
        } catch {
            isBusy = false
            await refreshNativeState()
            statusMessage = "无法修复原生控制服务：\(AppText(error: error))"
            isError = true
        }
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
                // Re-read real firmware before any write, even after install.
                let state = try await backend.readState()
                guard state.helperVersion >= FirmwareLimitHelperProtocolVersion.current else {
                    throw NativeControlError.helperUpgradeFailed(
                        found: state.helperVersion,
                        required: FirmwareLimitHelperProtocolVersion.current
                    )
                }
                let once = try await backend.oneTimeChargeStatus()
                updateFromNativeState(state, oneTime: once, status: "原生控制服务已就绪。")
                guard state.writeSupported, !state.active, !state.hasOriginalStateSnapshot,
                      !state.restorePending, !once.pending else {
                    throw NativeControlError.unsafeStateAfterInstall
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
        Task { await restoreOriginalFirmwareState() }
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
            } catch {
                statusMessage = "取消本次充满失败：\(AppText(error: error))"
                isError = true
            }
        }
    }

    private func applyLimit(_ value: Int) async {
        guard backendReady, isAdapterConnected, !isBusy, !isPreparingToQuit else { return }
        activeOperation = activeOperation == .enablingLimit ? .enablingLimit : .adjustingLimit
        isBusy = true
        isError = false
        statusMessage = "正在写入原生固件充电上限 \(value)%…"
        autoApplyFeedback = "正在应用 \(value)%…"
        defer { isBusy = false; activeOperation = nil }
        do {
            let response = try await backend.applyLimit(
                upper: value,
                lower: max(5, value - 2),
                confirmed: true
            )
            currentState = response.state
            backendReady = response.state.writeSupported
            restoreReady = response.state.restoreSupported
            fullOncePending = response.oneTimePending
            fullOnceCancelRequested = false
            modeText = "限制充电已启用 · 上限 \(value)%"
            autoApplyFeedback = "已写入并读回 \(value)%"
            NSLog("MauLeaf firmware limit apply: %@", response.message)
            statusMessage = "充电上限已设为 \(response.state.upper)%，固件写入已验证。"
            isError = false
        } catch {
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
        defer { isBusy = false; activeOperation = nil }
        do {
            let response = try await backend.beginOneTimeCharge(
                upper: limit,
                lower: currentState?.lower ?? max(5, limit - 2),
                confirmed: true
            )
            currentState = response.state
            backendReady = response.state.writeSupported
            restoreReady = response.state.restoreSupported
            fullOncePending = response.oneTimePending
            fullOnceCancelRequested = false
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
        didVerifyFirmwareOnQuit = false
        limitDebounce?.cancel()
        limitDebounce = nil
        pendingAction = nil
        lastAction = nil
        showNativeWriteConfirmation = false
        showLegacyDisableConfirmation = false

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
            guard state.helperVersion >= FirmwareLimitHelperProtocolVersion.current else {
                return cancelTermination("控制服务版本过旧；退出不会自动授权升级。")
            }
            let oneTime = try await backend.oneTimeChargeStatus()
            let needsRestore = state.active || state.hasOriginalStateSnapshot
                || state.restorePending || oneTime.pending

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
        isError = true
        statusMessage = message
        return false
    }

    private func readSystemBattery() {
        let snapshot = MauLeafBatteryStatusReader.read()
        batteryPercent = snapshot.percent
        isAdapterConnected = snapshot.isACConnected == true

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
    case outdatedHelper(found: Int, required: Int)
    case helperUpgradeFailed(found: Int, required: Int)
    case unsafeStateAfterInstall

    var errorDescription: String? {
        switch self {
        case .missingBundledHelper:
            return "应用包中缺少 MauLeaf 原生固件服务文件，请重新安装预览版。"
        case .authorizationFailed(let detail):
            return detail
        case .unsafeStateAfterInstall:
            return "安装后的服务存在活动限充或待恢复任务，拒绝覆盖固件状态。"
        case .outdatedHelper(let found, let required):
            return "MauLeaf 原生固件服务版本过旧（当前协议版本 \(found)，需要 \(required)），请重新启动应用并允许更新服务。"
        case .helperUpgradeFailed(let found, let required):
            return "MauLeaf 原生固件服务更新未生效（当前协议版本 \(found)，需要 \(required)）。请退出应用后重新启动，再尝试更新。"
        }
    }
}
