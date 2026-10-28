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
        .overlay(alignment: .bottom) {
            OperationFeedbackView(manager: manager)
                .padding(.horizontal, 16)
                .padding(.bottom, 44)
        }
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
        let allowed = await manager.prepareForTermination()
        if !allowed {
            positionPanel()
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            startOutsideClickMonitoring()
            manager.setPanelVisible(true)
        }
        return allowed
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

enum MenuBarLeafStyle: String, CaseIterable, Identifiable {
    case monochrome
    case green

    var id: String { rawValue }
    var title: String {
        switch self {
        case .monochrome: return "单色叶子"
        case .green: return "绿色叶子"
        }
    }
}

/// A larger, native-looking battery glyph for the main status card.
/// State priority: critical battery (<20%) > charging > Low Power Mode > normal.
private struct MenuBarBatteryIcon: View {
    let percent: Int?
    let isCharging: Bool
    let isAdapterConnected: Bool
    let lowPowerMode: Bool?
    var scale: CGFloat = 1
    @Environment(\.colorScheme) private var colorScheme

    private var tint: Color {
        if let percent, percent < 20 { return .red }
        if isCharging { return .green }
        if lowPowerMode == true { return .yellow }
        return .primary
    }

    var body: some View {
        let level = max(0, min(100, percent ?? 0))
        ZStack {
            RoundedRectangle(cornerRadius: 3.2, style: .continuous)
                .stroke(Color.primary.opacity(0.92), lineWidth: 1.05)
                .frame(width: 22, height: 13)
                .offset(x: -1.5)

            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(tint)
                .frame(width: max(1, 17 * CGFloat(level) / 100), height: 8)
                .offset(x: -1.5)

            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(Color.primary.opacity(0.92))
                .frame(width: 2.5, height: 4.8)
                .offset(x: 11.8)

            if isCharging {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 9, weight: .black))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.18), radius: 0.4)
                    .offset(x: -1.5)
            } else if isAdapterConnected {
                Image(systemName: "powerplug.fill")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(plugContrast)
                    .offset(x: -1.5)
            } else if lowPowerMode == true && (percent ?? 100) >= 20 {
                Image(systemName: "leaf.fill")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(Color.black.opacity(0.82))
                    .offset(x: -1.5)
            }
        }
        .frame(width: 28, height: 19)
        .scaleEffect(scale)
        .frame(width: 28 * scale, height: 19 * scale)
        .accessibilityElement()
        .accessibilityLabel(accessibilityText)
    }

    private var plugContrast: Color {
        if let percent, percent < 20 { return .white }
        if isCharging { return .white }
        if lowPowerMode == true { return .black }
        return colorScheme == .dark ? .black : .white
    }

    private var accessibilityText: String {
        let level = percent.map { "\($0) percent" } ?? "Battery level unavailable"
        if let percent, percent < 20 { return "\(level), low battery" }
        if isCharging { return "\(level), charging" }
        if lowPowerMode == true { return "\(level), Low Power Mode" }
        return level
    }
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

struct ContentView: View {
    @ObservedObject var manager: ChargeManager
    @State private var confirmation: Confirmation?
    @StateObject private var loginItem = LoginItemSettings()

    private let presets = [70, 75, 80, 85, 90, 95]

    private enum Confirmation: String, Identifiable {
        case install
        case uninstall
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            batteryCard
            powerSection
            menuBarIconStyleSection
            loginItemSection
            Divider()
            #if MAULEAF_INTEL_EXPERIMENTAL
            intelPreviewSection
            #else
            chargeModeSection
                .disabled(manager.isPreparingToQuit)

            if !manager.backendReady {
                componentSetupSection
            }
            #endif

            Divider()
            footer
        }
        // Feedback is overlaid on the viewport, outside this measured content.
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 16)
        .alert(item: $confirmation) { item in
            switch item {
            case .install:
                return Alert(
                    title: Text(manager.text("安装官方充电控制组件？")),
                    message: Text(manager.text("MauLeaf 已内置经过版本固定和构建时校验的 batt 控制程序。安装时会将其部署为系统服务并请求 macOS 管理员授权，不会在运行时下载组件，也不会覆盖其他来源的安装。")),
                    primaryButton: .default(Text(manager.text("继续安装")), action: { manager.installBackend() }),
                    secondaryButton: .cancel(Text(manager.text("取消")))
                )
            case .uninstall:
                return Alert(
                    title: Text(manager.text("卸载充电控制组件？")),
                    message: Text(manager.text("将先恢复默认充电控制，再移除 MauLeaf 安装的 batt 程序、系统服务和 batt 配置。MauLeaf 应用本身不会被删除。此操作需要管理员授权。")),
                    primaryButton: .destructive(Text(manager.text("卸载组件")), action: { manager.uninstallBackend() }),
                    secondaryButton: .cancel(Text(manager.text("取消")))
                )
            }
        }
        .task { manager.start() }
    }

    private var batteryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(manager.text("当前电量"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(manager.batteryPercent.map { "\($0)%" } ?? "--")
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Label(manager.text(manager.batteryDisplayText), systemImage: manager.batteryStateSymbol)
                        .font(.caption)
                        .foregroundStyle(manager.batteryTint)
                }
                Spacer()
                BatteryStatusRing(percent: manager.batteryPercent, tint: manager.batteryTint,
                                  icon: manager.batteryRingIcon)
                    .padding(.trailing, 3)
            }

            Divider().opacity(0.7)

            HStack(spacing: 8) {
                Image(systemName: manager.backendReady ? "shield.checkered" : "shield.lefthalf.filled")
                    .foregroundStyle(manager.backendReady ? Color.green : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(manager.text(manager.modeText))
                        .font(.subheadline.weight(.medium))
                    Text(manager.backendReady ? manager.text("控制服务已连接") : manager.text("充电控制尚未生效"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if manager.backendReady {
                    Circle().fill(Color.green).frame(width: 7, height: 7)
                }
            }
        }
        .padding(14)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
    }

    private var powerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(manager.text("实时电池功率"))
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(manager.text("非充电器输入功率"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 9) {
                powerCard(
                    title: manager.text("充电功率"),
                    value: manager.chargePowerWatts.map { String(format: "%.1f W", $0) } ?? "—",
                    subtitle: manager.text(AppText(key: manager.chargePowerSubtitle)),
                    symbol: "arrow.down.circle.fill",
                    tint: .green
                )
                powerCard(
                    title: manager.text("放电功率"),
                    value: manager.dischargePowerWatts.map { String(format: "%.1f W", $0) } ?? "—",
                    subtitle: manager.text(AppText(key: manager.dischargePowerSubtitle)),
                    symbol: "arrow.up.circle.fill",
                    tint: .secondary
                )
            }
        }
    }

    private func powerCard(title: String, value: String, subtitle: String, symbol: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 11))
    }

    private var menuBarIconStyleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(manager.text("菜单栏图标样式"))
                .font(.subheadline.weight(.medium))
            Picker(manager.text("菜单栏图标样式"), selection: $manager.menuBarLeafStyle) {
                ForEach(MenuBarLeafStyle.allCases) { style in
                    Text(manager.text(AppText(key: style.title))).tag(style)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(manager.text("菜单栏仅显示叶子图标；可选择跟随系统外观的单色叶子，或固定绿色叶子。"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var loginItemSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(manager.text("登录时自动启动"), isOn: Binding(
                get: { loginItem.isRequested },
                set: { loginItem.setEnabled($0) }
            ))
            .toggleStyle(.switch)
            .font(.subheadline)
            .disabled(manager.isPreparingToQuit)

            Text(manager.text(loginItem.explanation))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(manager.text("管理登录项")) { LoginItemSettings.openSystemSettings() }
                .buttonStyle(.link)
                .font(.caption2)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItem.refresh()
        }
        .alert(manager.text("无法更新登录项"), isPresented: Binding(
            get: { loginItem.errorMessage != nil },
            set: { if !$0 { loginItem.errorMessage = nil } }
        )) {
            Button(manager.text("关闭"), role: .cancel) { }
        } message: {
            Text(manager.text(loginItem.errorMessage ?? ""))
        }
    }

    private var chargeModeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(manager.text("充电模式"))
                .font(.subheadline.weight(.medium))

            Picker(manager.text("充电模式"), selection: Binding(
                get: { manager.chargeMode },
                set: { manager.selectChargeMode($0) }
            )) {
                Text(manager.text("控制模式")).tag(ChargeMode.limited)
                Text(manager.text("直接充满")).tag(ChargeMode.full)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(manager.isBusy || !manager.backendReady)

            if manager.chargeMode == .limited {
                limitSection
                highChargeSection
            } else {
                Picker(manager.text("充满方式"), selection: Binding(
                    get: { manager.fullBehavior },
                    set: { manager.selectFullBehavior($0) }
                )) {
                    Text(manager.text("仅充满一次")).tag(FullBehavior.once)
                    Text(manager.text("持续允许充满")).tag(FullBehavior.always)
                }
                .pickerStyle(.radioGroup)
                .disabled(manager.isBusy || !manager.backendReady)
                .padding(.vertical, 2)

                if manager.fullBehavior == .once {
                    Text(manager.text("限时解除限充；到达 100% 时后台恢复原上限，最长 10 小时后自动恢复。"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if manager.fullOncePending {
                        Button(manager.text("取消本次充满，恢复上限")) { manager.cancelFullOnce() }
                            .buttonStyle(.bordered)
                            .disabled(manager.isBusy)
                    } else {
                        Text((manager.batteryPercent ?? 0) >= 100
                             ? manager.text("当前已充满，原限充上限保持生效；可选择持续允许充满。")
                             : manager.text("本次充满尚未启动，原限充上限保持生效。"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Button(manager.text("启动仅充满一次")) { manager.selectFullBehavior(.once) }
                            .buttonStyle(.bordered)
                            .disabled(manager.isBusy || !manager.backendReady || (manager.batteryPercent ?? 0) >= 100)
                    }
                } else {
                    Text(manager.text("持续解除充电上限，直到切回控制模式；原先的上限值会保留。"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var highChargeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(manager.text("超过上限时")).font(.subheadline.weight(.medium))
            Picker(manager.text("高电量处理策略"), selection: Binding(
                get: { manager.highChargePolicy },
                set: { manager.selectHighChargePolicy($0) }
            )) {
                Text(manager.text("保持适配器供电")).tag(HighChargePolicy.adapter)
                Text(manager.text("主动使用电池，降至上限")).tag(HighChargePolicy.discharge)
                    .disabled(manager.supportsAdapterControl != true)
            }
            .pickerStyle(.radioGroup)
            .disabled(manager.isBusy || !manager.backendReady)
            Text(manager.text(manager.dischargeMessage))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if manager.supportsAdapterControl != true {
                Text(manager.text("尚未确认设备支持适配器控制，主动降电量不可用。"))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if manager.highChargePolicy == .discharge && manager.dischargePaused {
                Button(manager.text("恢复主动降电量")) { manager.selectHighChargePolicy(.discharge) }
                    .buttonStyle(.bordered)
                    .disabled(manager.isBusy || !manager.backendReady || manager.supportsAdapterControl != true)
            }
            if manager.highChargePolicy == .discharge {
                Text(manager.text("到达上限或触发保护即恢复适配器供电。合盖会停止主动降电量；可能导致合盖外接屏模式进入睡眠。"))
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var limitSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(manager.text("充电上限"))
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text("\(manager.limit)%")
                    .font(.subheadline.monospacedDigit().weight(.semibold))
            }
            Slider(
                value: Binding(
                    get: { Double(manager.limit) },
                    set: { manager.requestLimit(Int(($0 / 5).rounded()) * 5) }
                ),
                in: 50...95,
                step: 5
            )
            .disabled(!manager.backendReady)
            HStack(spacing: 5) {
                ForEach(presets, id: \.self) { preset in
                    Button {
                        manager.requestLimit(preset, immediate: true)
                    } label: {
                        Text("\(preset)%")
                            .font(.caption.weight(manager.limit == preset ? .semibold : .regular))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(manager.limit == preset ? Color.accentColor.opacity(0.17) : Color.primary.opacity(0.045))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .disabled(!manager.backendReady)
                }
            }
            Text(manager.text("调整后自动应用，点击预设值立即生效。"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    #if MAULEAF_INTEL_EXPERIMENTAL
    private var intelPreviewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(manager.language == .english ? "Intel experimental preview" : "Intel 实验预览版")
                .font(.subheadline.weight(.semibold))
            Text(manager.language == .english
                 ? "Unverified Intel preview: the developer has no Intel Mac and has not tested launching or running this build on Intel hardware. Actual operation, accuracy and stability are unknown. Battery information only; all charging controls and batt installation/removal are disabled. Provided AS IS, at your own risk."
                 : "未经实机测试的 Intel 实验预览版：开发者没有 Intel Mac，未在 Intel 设备上安装、启动或运行本版本。实际运行情况、数据准确性与稳定性均未知。仅展示电池信息，充电控制和 batt 安装、卸载全部禁用；软件按现状提供，风险由使用者自行评估。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.075), in: RoundedRectangle(cornerRadius: 10))
    }
    #endif

    private var componentSetupSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(manager.componentPresent ? manager.text("检测到已有控制组件") : manager.text("首次使用需要安装控制组件"))
                .font(.subheadline.weight(.medium))
            Text(manager.componentPresent
                 ? manager.text("已找到 \(manager.detectedBattPath ?? "batt")，但服务不可用。为避免覆盖其他安装方式，请先检查现有服务。")
                 : manager.text("MauLeaf 已内置 batt 控制程序。点击后会直接安装内置组件并注册系统服务，无需联网下载；首次安装需要管理员授权。"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !manager.componentPresent {
                Button {
                    confirmation = .install
                } label: {
                    Label(manager.isBusy ? manager.text("正在安装…") : manager.text("一键安装内置组件"), systemImage: "shippingbox.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(manager.isBusy)
            } else {
                Button {
                    manager.refresh()
                } label: {
                    Label(manager.text("重新检查服务"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(manager.isBusy)
            }

            Button(manager.text("查看官方项目与安装说明")) {
                if let url = URL(string: "https://github.com/charlie0129/batt") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.link)
            .font(.caption)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.075), in: RoundedRectangle(cornerRadius: 10))
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if manager.isManagedInstall {
                Button {
                    confirmation = .uninstall
                } label: {
                    Label(manager.text("卸载组件"), systemImage: "trash")
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
                .disabled(manager.isBusy)
            }

            Spacer()

            Button {
                manager.language = manager.language.other
            } label: {
                Label(manager.language.switchTitle, systemImage: "globe")
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
            .help(manager.text("切换界面语言"))

            Button(manager.text("退出")) { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
                .disabled(manager.isPreparingToQuit)
                .help(manager.text("停止后台充电任务、解除充电限制并恢复适配器供电后退出"))
        }
    }
}

/// This view overlays the scroll viewport so notifications never contribute
/// to the content-height preference or move the controls being operated.
struct OperationFeedbackView: View {
    @ObservedObject var manager: ChargeManager
    @State private var successMessage: AppText?
    @State private var dismissedError: AppText?
    @State private var showDetails = false
    @State private var errorDetails: AppText = ""

    private var errorVisible: Bool {
        !manager.isBusy && manager.isError && dismissedError != manager.statusMessage
    }

    var body: some View {
        Group {
            if manager.isBusy || errorVisible || (!manager.isError && successMessage != nil) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .top, spacing: 8) {
                        if manager.isBusy {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: errorVisible ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                                .foregroundStyle(errorVisible ? Color.orange : Color.green)
                        }
                        Text(manager.text(manager.isBusy || errorVisible ? manager.statusMessage : successMessage ?? ""))
                            .font(.caption)
                            .lineLimit(2)
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
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08)))
                .shadow(color: .black.opacity(0.14), radius: 7, y: 3)
                .transition(.opacity)
            }
        }
        .allowsHitTesting(errorVisible)
        .animation(.easeInOut(duration: 0.15), value: manager.isBusy)
        .animation(.easeInOut(duration: 0.15), value: errorVisible)
        .animation(.easeInOut(duration: 0.15), value: successMessage)
        .onReceive(manager.$isBusy.removeDuplicates().dropFirst().receive(on: RunLoop.main)) { busy in
            successMessage = nil
            if busy { dismissedError = nil }
            else if !manager.isError { successMessage = manager.statusMessage }
        }
        .task(id: successMessage) {
            guard successMessage != nil else { return }
            do { try await Task.sleep(nanoseconds: 2_000_000_000) }
            catch { return }
            successMessage = nil
        }
        .alert(manager.text("操作未完成"), isPresented: $showDetails) {
            Button(manager.text("关闭"), role: .cancel) { }
        } message: { Text(manager.text(errorDetails)) }
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
    @Published var menuBarLeafStyle: MenuBarLeafStyle {
        didSet { UserDefaults.standard.set(menuBarLeafStyle.rawValue, forKey: "menuBarLeafStyle") }
    }
    @Published private(set) var chargeMode: ChargeMode = .limited
    @Published private(set) var fullBehavior: FullBehavior = .once
    @Published private(set) var fullOncePending = false
    @Published private(set) var highChargePolicy: HighChargePolicy = .adapter
    @Published private(set) var supportsAdapterControl: Bool?
    @Published private(set) var dischargePaused = false
    @Published private(set) var dischargeMessage: AppText = "高于上限时停止充电，保持适配器供电。"
    @Published var autoApplyFeedback: AppText = "调整后自动应用"
    private var limitDebounce: Task<Void, Never>?
    private var lastVerifiedLimit: Int?
    private var queuedLimit: Int?
    private var operationToken: UUID?
    private enum ChargeRequest {
        case limit(HighChargePolicy?)
        case full(FullBehavior)
    }
    private var lastChargeRequest: ChargeRequest?
    @Published var modeText: AppText = "正在读取状态…"
    @Published var statusMessage: AppText = "正在检查充电控制组件…"
    @Published var backendReady = false
    @Published var componentPresent = false
    @Published var detectedBattPath: String?
    @Published var isBusy = false
    @Published private(set) var isPreparingToQuit = false
    @Published var isError = false
    @Published var chargePowerWatts: Double?
    @Published var dischargePowerWatts: Double?
    @Published var lowPowerMode: Bool?
    @Published var isManagedInstall = false

    private var timer: Timer?
    private lazy var powerRefresh = PowerRefreshController(
        onUpdate: { [weak self] sample in self?.applyPowerSample(sample) },
        onSystemChange: { [weak self] in self?.refresh() })
    private var started = false
    private var panelVisible = false
    private var terminationReady = false
    private var battPath: String?

    private let managedBinaryPath = "/usr/local/bin/batt"
    // Keep the legacy identity/path so ChargeCap settings and tasks remain compatible.
    private let managedReceiptPath = "/Library/Application Support/ChargeCap/managed-install"
    private let managedDaemonPlistPath = "/Library/LaunchDaemons/cc.chlc.batt.plist"

    init(battPath: String? = nil) {
        self.battPath = battPath
        let saved = UserDefaults.standard.integer(forKey: "chargeLimit")
        self.limit = (50...95).contains(saved) ? saved : 80
        self.menuBarLeafStyle = MenuBarLeafStyle(rawValue: UserDefaults.standard.string(forKey: "menuBarLeafStyle") ?? "monochrome") ?? .monochrome
        self.chargeMode = ChargeMode(rawValue: UserDefaults.standard.string(forKey: "chargeModeV5") ?? "limited") ?? .limited
        self.fullBehavior = FullBehavior(rawValue: UserDefaults.standard.string(forKey: "fullBehaviorV5") ?? "once") ?? .once
        self.fullOncePending = OnceChargeAgent.hasPendingJob
        self.highChargePolicy = HighChargePolicy(rawValue: UserDefaults.standard.string(forKey: "highChargePolicy") ?? "adapter") ?? .adapter
    }

    func text(_ message: AppText) -> String { message.localized(in: language) }

    var batteryTint: Color {
        if let batteryPercent, batteryPercent < 20 { return .red }
        if batteryStateText == "正在充电" { return .green }
        if lowPowerMode == true { return .yellow }
        return .primary
    }

    /// The center describes the power source; ring color describes battery state.
    var batteryRingIcon: BatteryRingIcon? {
        switch batteryStateText {
        case "正在充电": return .charging
        case "电池供电": return .battery
        case "已接电源，未充电", "已接电源，已充满": return .adapter
        default: return isAdapterConnected ? .adapter : nil
        }
    }

    var batteryDisplayText: AppText {
        let state = AppText(key: batteryStateText)
        if lowPowerMode == true { return "\(state)，低电量模式" }
        return state
    }

    var batteryCardSymbol: String {
        if let batteryPercent, batteryPercent < 20 { return "battery.25percent" }
        if batteryStateText == "正在充电" { return "battery.100percent.bolt" }
        if lowPowerMode == true { return "battery.100percent" }
        return menuBarSymbol
    }

    var menuBarAccessibilityText: AppText {
        let level: AppText = batteryPercent.map { value -> AppText in "电量 \(value)%" } ?? "电量未知"
        if let batteryPercent, batteryPercent < 20 { return "\(level)，电量低" }
        if batteryStateText == "正在充电" { return "\(level)，正在充电" }
        if isAdapterConnected { return "\(level)，已接入电源但未充电" }
        if lowPowerMode == true { return "\(level)，低电量模式" }
        return level
    }

    var chargePowerSubtitle: String {
        if batteryStateText != "正在充电" { return "当前未充电" }
        return chargePowerWatts == nil ? "电池电流数据不可用" : "功率流入电池"
    }

    var dischargePowerSubtitle: String {
        if batteryStateText == "正在充电" { return "当前未放电" }
        if batteryStateText == "电池供电" {
            return dischargePowerWatts == nil ? "电池电流数据不可用" : "电池正在供电"
        }
        return "当前未放电"
    }

    var menuBarSymbol: String {
        guard let percent = batteryPercent else { return "battery.0percent" }
        switch percent {
        case 0..<20: return "battery.25percent"
        case 20..<45: return "battery.50percent"
        case 45..<70: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    var batteryStateSymbol: String {
        switch batteryStateText {
        case "正在充电": return "bolt.fill"
        case "已充满": return "battery.100percent"
        case "电池供电": return "battery.75percent"
        case "已接电源，未充电", "已接电源，已充满": return "powerplug"
        default: return "powerplug"
        }
    }

    /// Detects the exact batt launch daemon regardless of whether an older
    /// build created MauLeaf's receipt or UserDefaults marker.
    private var hasManagedLaunchDaemon: Bool {
        let url = URL(fileURLWithPath: managedDaemonPlistPath)
        guard let data = try? Data(contentsOf: url),
              let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let plist = object as? [String: Any],
              let label = plist["Label"] as? String,
              label == "cc.chlc.batt",
              let arguments = plist["ProgramArguments"] as? [String] else {
            return false
        }
        return arguments.contains(managedBinaryPath)
    }

    func start() {
        guard !started else { return }
        started = true
        refresh()
        powerRefresh.startObservingSystemEvents()
        if backendReady, UserDefaults.standard.bool(forKey: "chargeControlReleasedOnQuit") {
            Task {
                if chargeMode == .full && fullBehavior == .always { await applyFullBehavior(.always) }
                else { await applyDesiredLimit() }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func setPanelVisible(_ visible: Bool) {
        panelVisible = visible
        powerRefresh.setVisible(visible && !isPreparingToQuit)
    }

    func refresh() {
        guard !isPreparingToQuit else { return }
        #if MAULEAF_INTEL_EXPERIMENTAL
        readSystemBattery()
        backendReady = false
        componentPresent = false
        isManagedInstall = false
        detectedBattPath = nil
        supportsAdapterControl = false
        modeText = "Intel 实验预览"
        statusMessage = "Intel 充电控制未经验证，已禁用所有充电控制操作。"
        isError = false
        return
        #endif
        if isBusy {
            readSystemBattery()
            return
        }
        readSystemBattery()
        detectedBattPath = locateBatt()
        componentPresent = detectedBattPath != nil
        let hasReceipt = FileManager.default.fileExists(atPath: managedReceiptPath)
        let legacyDaemonInstall = hasManagedLaunchDaemon
            && FileManager.default.isExecutableFile(atPath: managedBinaryPath)
        // Older builds and manual `batt install` commands may not have created
        // MauLeaf's receipt/UserDefaults flag. The exact launchd label plus
        // ProgramArguments path is a stronger, backward-compatible signal.
        isManagedInstall = detectedBattPath == managedBinaryPath
            && FileManager.default.isExecutableFile(atPath: managedBinaryPath)
            && (hasReceipt || legacyDaemonInstall)

        guard let path = detectedBattPath else {
            backendReady = false
            modeText = "控制组件未安装"
            statusMessage = "电池状态可读取，但限充控制尚未安装。"
            isError = false
            return
        }

        let result = run(path: path, arguments: ["status"])
        guard result.status == 0 else {
            backendReady = false
            modeText = "控制组件不可用"
            statusMessage = "已找到 batt，但无法连接控制服务。请检查服务是否正常运行。"
            isError = true
            return
        }

        backendReady = true
        let status = BattStatus.parse(result.output)
        updateDischargeState(status)
        if lastVerifiedLimit == nil && !UserDefaults.standard.bool(forKey: "chargeCapV5LimitInitialized") {
            if let remote = status.upperLimit, (50...95).contains(remote) {
                limit = remote
                UserDefaults.standard.set(true, forKey: "chargeCapV5LimitInitialized")
            }
        }
        lastVerifiedLimit = status.upperLimit
        let hasPendingJob = OnceChargeAgent.hasPendingJob
        let onceCompleted = !hasPendingJob && (fullOncePending
            || (DischargeAgent.result?.completedFullCharge == true && status.upperLimit == limit))
        fullOncePending = hasPendingJob
        // On first migration from 0.4.x, reflect an existing permanent
        // batt-disable state instead of pretending the control mode is active.
        if UserDefaults.standard.object(forKey: "chargeModeV5") == nil,
           !fullOncePending, status.upperLimit == 100,
           status.scheduledRestoreLimit == nil {
            chargeMode = .full
            fullBehavior = .always
            UserDefaults.standard.set(chargeMode.rawValue, forKey: "chargeModeV5")
            UserDefaults.standard.set(fullBehavior.rawValue, forKey: "fullBehaviorV5")
        }
        if fullOncePending {
            chargeMode = .full
            fullBehavior = .once
            modeText = "本次充满进行中 · 目标 100%"
        } else if chargeMode == .full && fullBehavior == .once && onceCompleted {
            // The helper cleared its job only after successful restoration.
            chargeMode = .limited
            UserDefaults.standard.set(chargeMode.rawValue, forKey: "chargeModeV5")
            modeText = "限充至 \(status.upperLimit ?? limit)%"
        } else if chargeMode == .full && fullBehavior == .once {
            modeText = "仅充满一次未运行 · 限充至 \(status.upperLimit ?? limit)%"
        } else if let current = status.upperLimit {
            if chargeMode == .full && fullBehavior == .always {
                modeText = current >= 100 ? "持续允许充满" : "设备设定与充满模式不一致"
            } else {
                modeText = current == limit ? "限充至 \(current)%" : "设备报告上限 \(current)% · 设定 \(limit)%"
            }
        } else {
            modeText = "控制组件已连接"
        }
        if !isError { statusMessage = "控制服务正常 · 每 20 秒刷新" }
        if !isError, chargeMode == .limited, highChargePolicy == .discharge, isAdapterConnected,
           let percent = batteryPercent, percent > limit, status.upperLimit == limit,
           status.supportsAdapterControl == true, !DischargeAgent.hasPendingJob,
           DischargeAgent.result?.paused != true {
            Task { [weak self] in
                guard let self, !self.isBusy, !self.isError, self.chargeMode == .limited,
                      self.highChargePolicy == .discharge, !DischargeAgent.hasPendingJob,
                      DischargeAgent.result?.paused != true else { return }
                await self.applyDesiredLimit()
            }
        }
    }

    func requestLimit(_ value: Int, immediate: Bool = false) {
        guard !isPreparingToQuit, (50...95).contains(value) else { return }
        limit = value
        limitDebounce?.cancel()
        autoApplyFeedback = "等待自动应用 \(value)%…"
        guard chargeMode == .limited && backendReady else { return }
        lastChargeRequest = .limit(nil)
        limitDebounce = Task { [weak self] in
            if !immediate {
                try? await Task.sleep(nanoseconds: 450_000_000)
            }
            guard !Task.isCancelled else { return }
            await self?.applyDesiredLimit()
        }
    }

    func selectChargeMode(_ mode: ChargeMode) {
        guard backendReady, !isPreparingToQuit else { return }
        if mode == .limited {
            limitDebounce?.cancel()
            Task { await applyDesiredLimit() }
        } else if chargeMode != .full {
            selectFullBehavior(fullBehavior, force: true)
        }
    }

    func selectFullBehavior(_ behavior: FullBehavior) {
        selectFullBehavior(behavior, force: chargeMode != .full || fullBehavior != behavior
                           || (behavior == .once && !fullOncePending))
    }

    private func selectFullBehavior(_ behavior: FullBehavior, force: Bool) {
        guard backendReady, force, !isPreparingToQuit else { return }
        limitDebounce?.cancel()
        Task { await applyFullBehavior(behavior) }
    }

    func cancelFullOnce() {
        Task { await applyDesiredLimit() }
    }

    func selectHighChargePolicy(_ policy: HighChargePolicy) {
        guard backendReady, !isBusy, !isPreparingToQuit, chargeMode == .limited else { return }
        guard policy != .discharge || supportsAdapterControl == true else { return }
        limitDebounce?.cancel()
        Task { await applyDesiredLimit(policy: policy) }
    }

    private func updateDischargeState(_ status: BattStatus? = nil) {
        if let status { supportsAdapterControl = status.supportsAdapterControl }
        let result = DischargeAgent.result
        dischargePaused = result?.paused == true
        if DischargeAgent.hasPendingJob {
            if let result, result.paused { dischargeMessage = AppText(key: result.message) }
            else { dischargeMessage = "正在使用电池，降至 \(limit)% 后自动恢复适配器供电。" }
        } else if highChargePolicy == .discharge {
            dischargeMessage = result.map { AppText(key: $0.message) } ?? "当前未主动放电；高于上限时按所选策略处理。"
        } else {
            dischargeMessage = "高于上限时停止充电，保持适配器供电。"
        }
    }

    private func ensureAdapterPower() async throws {
        let status = try await checkedStatus()
        if status.supportsAdapterControl == true, status.adapterEnabled != true {
            let enabled = try await invokeBatt(BattCommand.useAdapter.arguments)
            guard enabled.status == 0 else { throw ChargingError.command(enabled.output) }
            guard try await checkedStatus().adapterEnabled == true else {
                throw ChargingError.verification("未确认适配器供电已恢复")
            }
        }
    }

    private func applyDesiredLimit(policy: HighChargePolicy? = nil) async {
        guard backendReady, !isPreparingToQuit else { return }
        if isBusy { queuedLimit = limit; return }
        lastChargeRequest = .limit(policy)
        isBusy = true
        isError = false
        let value = limit
        statusMessage = "正在应用充电上限 \(value)%…"
        autoApplyFeedback = "正在应用 \(value)%…"
        defer { finishChargeCommand() }
        var limitApplied = false
        do {
            try await DischargeAgent.stop()
            try await ensureAdapterPower()
            try await OnceChargeAgent.cancel()
            let result = try await invokeBatt(BattCommand.setLimit(value).arguments)
            guard result.status == 0 else { throw ChargingError.command(result.output) }
            let current = try await checkedStatus()
            guard current.upperLimit == value else {
                throw ChargingError.verification("设备报告上限 \(AppText(key: current.upperLimit.map(String.init) ?? "未知"))%，预期 \(value)%")
            }
            limitApplied = true
            UserDefaults.standard.set(false, forKey: "chargeControlReleasedOnQuit")
            chargeMode = .limited
            fullBehavior = .once
            fullOncePending = false
            UserDefaults.standard.set(chargeMode.rawValue, forKey: "chargeModeV5")
            UserDefaults.standard.set(fullBehavior.rawValue, forKey: "fullBehaviorV5")
            let desiredPolicy = policy ?? highChargePolicy
            if desiredPolicy == .discharge && (policy != nil || DischargeAgent.result?.paused != true) {
                guard let path = locateBatt() else { throw ChargingError.notInstalled }
                try await DischargeAgent.start(battPath: path, limit: value)
            }
            highChargePolicy = desiredPolicy
            UserDefaults.standard.set(highChargePolicy.rawValue, forKey: "highChargePolicy")
            updateDischargeState(current)
            modeText = "限充至 \(value)%"
            autoApplyFeedback = "已自动应用 \(value)%"
            statusMessage = "已验证设备充电上限 \(value)%"
            isError = false
        } catch {
            updateDischargeState()
            autoApplyFeedback = limitApplied ? "上限已应用，但高电量策略失败：\(AppText(error: error))"
                : "应用失败：\(AppText(error: error))"
            statusMessage = autoApplyFeedback
            isError = true
        }
    }

    private func applyFullBehavior(_ behavior: FullBehavior) async {
        guard backendReady, !isPreparingToQuit, let path = locateBatt() else { return }
        if isBusy { return }
        lastChargeRequest = .full(behavior)
        isBusy = true
        isError = false
        statusMessage = behavior == .once ? "正在启动仅充满一次…" : "正在切换为持续充满…"
        defer { finishChargeCommand() }
        let previousMode = chargeMode
        let previousBehavior = fullBehavior
        var changedHardware = false
        do {
            try await DischargeAgent.stop()
            try await ensureAdapterPower()
            try DischargeAgent.pauseForFullCharge()
            updateDischargeState()
            try await OnceChargeAgent.cancel()
            if behavior == .always {
                let result = try await invokeBatt(BattCommand.allowFullForever.arguments)
                guard result.status == 0 else { throw ChargingError.command(result.output) }
                changedHardware = true
                let current = try await checkedStatus()
                guard current.upperLimit == 100 else {
                    throw ChargingError.verification("未确认限充已关闭；请查看 batt 状态")
                }
            } else {
                // v0.8.0 does not include 'batt charge full'. Use the supported
                // temporary disable and a separately scheduled restoration agent.
                let current = try await checkedStatus()
                if current.upperLimit != limit {
                    let reset = try await invokeBatt(BattCommand.setLimit(limit).arguments)
                    guard reset.status == 0 else { throw ChargingError.command(reset.output) }
                    changedHardware = true
                    guard try await checkedStatus().upperLimit == limit else {
                        throw ChargingError.verification("未确认已恢复原限充上限 \(limit)%")
                    }
                }
                if (batteryPercent ?? 0) >= 100 {
                    // Keep the full-charge options accessible without starting
                    // a redundant job or claiming a full-charge task is active.
                    chargeMode = .full
                    fullBehavior = .once
                    fullOncePending = false
                    modeText = "当前已充满 · 限充至 \(limit)%"
                    statusMessage = "当前已充满，无需启动任务；原限充上限保持不变。"
                    UserDefaults.standard.set(chargeMode.rawValue, forKey: "chargeModeV5")
                    UserDefaults.standard.set(fullBehavior.rawValue, forKey: "fullBehaviorV5")
                    UserDefaults.standard.set(false, forKey: "chargeControlReleasedOnQuit")
                    return
                }
                try await OnceChargeAgent.prepare(battPath: path, limit: limit)
                let result = try await invokeBatt(BattCommand.allowFullTemporarily.arguments)
                if result.status != 0 {
                    try? await OnceChargeAgent.cancel()
                    throw ChargingError.command(result.output)
                }
                changedHardware = true
                // v0.8.0 shows `Charge limit: 100% (batt disabled)` and
                // `Restoring N% limit: ...` for the durable temporary disable.
                let temporary = try await checkedStatus()
                guard temporary.upperLimit == 100 && temporary.scheduledRestoreLimit == limit else {
                    throw ChargingError.verification("未确认 batt 已启用限时充满及恢复 \(limit)% 的计划")
                }
            }
            chargeMode = .full
            fullBehavior = behavior
            fullOncePending = behavior == .once
            UserDefaults.standard.set(chargeMode.rawValue, forKey: "chargeModeV5")
            UserDefaults.standard.set(fullBehavior.rawValue, forKey: "fullBehaviorV5")
            UserDefaults.standard.set(false, forKey: "chargeControlReleasedOnQuit")
            modeText = behavior == .once ? "本次充满进行中" : "持续允许充满"
            statusMessage = behavior == .once ? "任务已启动；达到 100% 后自动恢复上限（最长 10 小时）" : "持续充满已启用，切回控制模式可恢复原上限"
            isError = false
        } catch {
            // A failure may happen after we have changed batt but before the
            // helper was installed or verification finished. Restore the
            // previous selected mode, never leave the displayed state stale.
            try? await OnceChargeAgent.cancel()
            if changedHardware || (behavior == .once && previousMode == .full && previousBehavior == .always) {
                if previousMode == .full && previousBehavior == .always {
                    _ = try? await invokeBatt(BattCommand.allowFullForever.arguments)
                } else {
                    _ = try? await invokeBatt(BattCommand.setLimit(limit).arguments)
                }
            }
            statusMessage = "切换失败：\(AppText(error: error))。已尝试恢复上一充电模式，请检查实际状态。"
            isError = true
        }
    }

    var canRetryChargeRequest: Bool { backendReady && !isBusy && !isPreparingToQuit && lastChargeRequest != nil }

    func retryChargeRequest() {
        guard canRetryChargeRequest else { return }
        switch lastChargeRequest {
        case .limit(let policy): Task { await applyDesiredLimit(policy: policy) }
        case .full(let behavior): selectFullBehavior(behavior, force: true)
        case nil: break
        }
    }

    private func finishChargeCommand() {
        isBusy = false
        powerRefresh.refreshNow()
        // Keep the current operation result visible; refresh normally would
        // replace it with a generic “service connected” message.
        if let pending = queuedLimit {
            queuedLimit = nil
            if pending != limit { return }
            Task { await applyDesiredLimit() }
        }
    }

    private func invokeBatt(_ args: [String]) async throws -> (status: Int32, output: String) {
        guard let path = locateBatt() else { throw ChargingError.notInstalled }
        return try await runProcess(path: path, arguments: args)
    }

    private func checkedStatus() async throws -> BattStatus {
        let result = try await invokeBatt(BattCommand.readStatus.arguments)
        guard result.status == 0 else { throw ChargingError.command(result.output) }
        return BattStatus.parse(result.output)
    }

    func prepareForTermination() async -> Bool {
        #if MAULEAF_INTEL_EXPERIMENTAL
        // Never touch charging tasks or other installed batt services on Intel.
        timer?.invalidate()
        timer = nil
        powerRefresh.setVisible(false)
        terminationReady = true
        return true
        #endif
        if terminationReady { return true }
        guard !isPreparingToQuit else { return false }
        isPreparingToQuit = true
        limitDebounce?.cancel()
        queuedLimit = nil
        lastChargeRequest = nil
        powerRefresh.setVisible(false)
        defer {
            if !terminationReady {
                isPreparingToQuit = false
                powerRefresh.setVisible(panelVisible)
            }
        }
        do {
            // Do not let a previous command complete after the final disable.
            let deadline = Date().addingTimeInterval(30)
            while isBusy {
                guard Date() < deadline else { throw ChargingError.command("当前操作尚未结束，请完成或取消后重试退出") }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            isBusy = true
            defer { isBusy = false }
            statusMessage = "正在停止后台任务并恢复系统充电…"
            isError = false
            let hadControl = componentPresent || backendReady || OnceChargeAgent.hasPendingJob || DischargeAgent.hasPendingJob
            try await DischargeAgent.stop()
            try await OnceChargeAgent.cancel()
            if let path = locateBatt() {
                func command(_ command: BattCommand) async throws -> String {
                    let result = await Task.detached(priority: .utility) { ChargeProcess.run(path, command.arguments) }.value
                    guard result.status == 0 else { throw ChargingError.command(result.output) }
                    return result.output
                }
                let before = BattStatus.parse(try await command(.readStatus))
                if before.supportsAdapterControl == true { _ = try await command(.useAdapter) }
                _ = try await command(.allowFullForever)
                let restored = BattStatus.parse(try await command(.readStatus))
                guard restored.upperLimit == 100, restored.scheduledRestoreLimit == nil,
                      before.supportsAdapterControl != true || restored.adapterEnabled == true else {
                    throw ChargingError.verification("未确认已解除限充、取消定时恢复并恢复适配器供电")
                }
                // A cancelled one-time charge should not restart on next launch.
                if chargeMode == .full && fullBehavior == .once {
                    chargeMode = .limited
                    UserDefaults.standard.set(chargeMode.rawValue, forKey: "chargeModeV5")
                }
                UserDefaults.standard.set(true, forKey: "chargeControlReleasedOnQuit")
                fullOncePending = false
                lastVerifiedLimit = 100
            } else if hadControl {
                throw ChargingError.notInstalled
            }
            timer?.invalidate()
            timer = nil
            terminationReady = true
            statusMessage = "已解除充电控制，正在退出。"
            return true
        } catch {
            statusMessage = "退出已取消：\(AppText(error: error))。未确认恢复系统充电，请检查后重试退出。"
            isError = true
            return false
        }
    }

    func installBackend() {
        #if MAULEAF_INTEL_EXPERIMENTAL
        statusMessage = "Intel 实验预览版禁止安装充电控制组件。"
        isError = true
        return
        #endif
        guard !isBusy, !isPreparingToQuit else { return }
        lastChargeRequest = nil
        refresh()
        guard !componentPresent else {
            isError = true
            statusMessage = "检测到现有 batt，未进行覆盖安装。请先检查当前安装方式，避免与 Homebrew 或其他服务冲突。"
            return
        }
        guard let bundledBinaryURL = Bundle.main.resourceURL?.appendingPathComponent("batt"),
              FileManager.default.isExecutableFile(atPath: bundledBinaryURL.path) else {
            isError = true
            statusMessage = "应用包中没有找到内置 batt。请重新构建 MauLeaf，并确认构建时成功嵌入控制组件。"
            return
        }

        isBusy = true
        isError = false
        statusMessage = "正在安装内置控制组件…"

        Task {
            do {
                let version = bundledBattVersion
                let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MauLeafInstall-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                defer { try? FileManager.default.removeItem(at: directory) }

                let scriptURL = directory.appendingPathComponent("install-as-root.sh")
                let receipt = shellQuote(managedReceiptPath)
                let daemonPlist = shellQuote(managedDaemonPlistPath)
                let binary = shellQuote(bundledBinaryURL.path)
                let script = """
                #!/bin/bash
                set -euo pipefail
                RECEIPT=\(receipt)
                DAEMON_PLIST=\(daemonPlist)
                TARGET=/usr/local/bin/batt
                if [ -e "$RECEIPT" ] || [ -e "$DAEMON_PLIST" ]; then
                  echo '检测到 MauLeaf 或 batt 遗留的系统服务/安装凭据。为避免覆盖，已停止安装。请先使用卸载器清理。' >&2
                  exit 23
                fi
                for candidate in /opt/homebrew/bin/batt /opt/homebrew/sbin/batt /usr/local/bin/batt /usr/local/sbin/batt; do
                  if [ -x "$candidate" ]; then
                    echo "检测到已有 batt：$candidate。为避免与 Homebrew 或其他安装方式冲突，已停止安装。" >&2
                    exit 21
                  fi
                done
                /bin/mkdir -p /usr/local/bin
                /usr/bin/install -m 755 \(binary) "$TARGET"
                /usr/bin/xattr -d com.apple.quarantine "$TARGET" >/dev/null 2>&1 || true
                if ! "$TARGET" install --allow-non-root-access; then
                  "$TARGET" uninstall >/dev/null 2>&1 || true
                  /bin/launchctl bootout system/cc.chlc.batt >/dev/null 2>&1 || true
                  /bin/rm -f "$DAEMON_PLIST" "$TARGET"
                  echo 'batt 系统服务安装失败，已尝试清理部分安装。' >&2
                  exit 24
                fi
                /bin/mkdir -p "$(/usr/bin/dirname "$RECEIPT")"
                /usr/bin/printf 'source=MauLeaf\\nmauleaf_version=%s\\nbatt_version=%s\\n' \(shellQuote(appVersion)) \(shellQuote(version)) > "$RECEIPT"
                /usr/sbin/chown root:wheel "$RECEIPT"
                /bin/chmod 644 "$RECEIPT"
                """
                try script.write(to: scriptURL, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
                statusMessage = "等待 macOS 管理员授权…"
                _ = try await runPrivileged(command: "/bin/bash \(shellQuote(scriptURL.path))")

                UserDefaults.standard.set(true, forKey: "chargeCapManagedBattInstall")
                battPath = managedBinaryPath
                isBusy = false
                refresh()
                if backendReady && FileManager.default.fileExists(atPath: managedReceiptPath) {
                    statusMessage = "内置控制组件安装成功，服务已连接。"
                    isError = false
                } else {
                    statusMessage = "组件已部署，但服务验证未通过。请检查设备固件兼容性后重试。"
                    isError = true
                }
            } catch {
                isBusy = false
                let receiptExists = FileManager.default.fileExists(atPath: managedReceiptPath)
                UserDefaults.standard.set(receiptExists, forKey: "chargeCapManagedBattInstall")
                isManagedInstall = receiptExists && FileManager.default.isExecutableFile(atPath: managedBinaryPath)
                refresh()
                statusMessage = "安装未完成：\(AppText(error: error))"
                isError = true
            }
        }
    }

    func uninstallBackend() {
        #if MAULEAF_INTEL_EXPERIMENTAL
        statusMessage = "Intel 实验预览版禁止卸载充电控制组件。"
        isError = true
        return
        #endif
        guard !isBusy, !isPreparingToQuit else { return }
        lastChargeRequest = nil
        let hasReceipt = FileManager.default.fileExists(atPath: managedReceiptPath)
        let legacyDaemonInstall = hasManagedLaunchDaemon
            && FileManager.default.isExecutableFile(atPath: managedBinaryPath)
        guard detectedBattPath == managedBinaryPath,
              FileManager.default.isExecutableFile(atPath: managedBinaryPath),
              (hasReceipt || legacyDaemonInstall) else {
            isError = true
            statusMessage = "未确认这是由 MauLeaf 或旧版 batt 安装流程创建的服务。为避免误删 Homebrew 或其他来源的组件，未执行卸载。"
            return
        }

        isBusy = true
        isError = false
        statusMessage = "准备卸载控制组件，等待 macOS 管理员授权…"

        Task {
            do {
                // Do not allow a previously scheduled full-once helper to issue
                // commands after the control daemon has been removed.
                try await DischargeAgent.stop()
                try await OnceChargeAgent.cancel()
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MauLeafUninstall-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                defer { try? FileManager.default.removeItem(at: directory) }

                let scriptURL = directory.appendingPathComponent("uninstall-as-root.sh")
                let receipt = shellQuote(managedReceiptPath)
                let daemonPlist = shellQuote(managedDaemonPlistPath)
                let allowLegacy = legacyDaemonInstall ? "1" : "0"
                let script = """
                #!/bin/bash
                set -euo pipefail
                RECEIPT=\(receipt)
                DAEMON_PLIST=\(daemonPlist)
                ALLOW_LEGACY=\(allowLegacy)
                TARGET=/usr/local/bin/batt
                if [ ! -f "$RECEIPT" ]; then
                  PLIST_LABEL=$(/usr/libexec/PlistBuddy -c 'Print :Label' "$DAEMON_PLIST" 2>/dev/null || true)
                  PLIST_ARGS=$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments' "$DAEMON_PLIST" 2>/dev/null || true)
                  if [ "$ALLOW_LEGACY" != "1" ] || [ "$PLIST_LABEL" != 'cc.chlc.batt' ] || [[ "$PLIST_ARGS" != *"$TARGET"* ]]; then
                    echo '未找到 MauLeaf 安装凭据，且系统服务未指向 /usr/local/bin/batt；已停止卸载。' >&2
                    exit 41
                  fi
                fi
                for candidate in /opt/homebrew/bin/batt /opt/homebrew/sbin/batt /usr/local/sbin/batt; do
                  if [ -x "$candidate" ]; then
                    echo "检测到其他位置的 batt：$candidate。为避免影响另一种安装方式，已停止卸载。" >&2
                    exit 45
                  fi
                done
                if [ -f "$DAEMON_PLIST" ]; then
                  PLIST_LABEL=$(/usr/libexec/PlistBuddy -c 'Print :Label' "$DAEMON_PLIST" 2>/dev/null || true)
                  PLIST_ARGS=$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments' "$DAEMON_PLIST" 2>/dev/null || true)
                  if [ "$PLIST_LABEL" != 'cc.chlc.batt' ] || [[ "$PLIST_ARGS" != *"$TARGET"* ]]; then
                    echo '系统服务的名称或程序路径与预期不一致；已停止卸载。' >&2
                    exit 46
                  fi
                fi
                if [ -x "$TARGET" ]; then
                  if ! "$TARGET" disable; then
                    echo '恢复默认充电控制失败（batt disable）。为安全起见，未继续删除服务和文件。' >&2
                    exit 43
                  fi
                  if ! "$TARGET" uninstall; then
                    echo 'batt uninstall 未成功。服务和程序文件未被删除，请检查上方错误后重试。' >&2
                    exit 44
                  fi
                else
                  echo '找不到 batt 可执行文件，无法确认已恢复默认充电控制。为安全起见，未清理服务。' >&2
                  exit 42
                fi
                /bin/launchctl bootout system/cc.chlc.batt >/dev/null 2>&1 || true
                /bin/rm -f "$DAEMON_PLIST" "$TARGET"
                /bin/rm -f /etc/batt* 2>/dev/null || true
                /bin/rm -f "$RECEIPT"
                /bin/rmdir "$(/usr/bin/dirname "$RECEIPT")" >/dev/null 2>&1 || true
                """
                try script.write(to: scriptURL, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
                _ = try await runPrivileged(command: "/bin/bash \(shellQuote(scriptURL.path))")

                UserDefaults.standard.set(false, forKey: "chargeCapManagedBattInstall")
                isManagedInstall = false
                battPath = nil
                detectedBattPath = nil
                componentPresent = false
                backendReady = false
                isBusy = false
                modeText = "未启用限充"
                statusMessage = "已卸载 MauLeaf 控制组件并清理其配置。"
                isError = false
                readSystemBattery()
            } catch {
                isBusy = false
                // Refresh actual state first; refresh() also updates statusMessage.
                // Preserve the actionable error after refreshing so it is not hidden.
                refresh()
                statusMessage = "卸载未完成：\(AppText(error: error))。组件未被强制删除，请检查提示后重试。"
                isError = true
            }
        }
    }

    private var bundledBattVersion: String {
        guard let url = Bundle.main.url(forResource: "batt-version", withExtension: "txt"),
              let version = try? String(contentsOf: url, encoding: .utf8) else { return "unknown" }
        return version.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func runPrivileged(command: String) async throws -> String {
        // Keep our dedicated NSPanel alive and visible while the system password
        // dialog is presented by osascript. Never issue this from a MenuBarExtra.
        NSApp.activate(ignoringOtherApps: true)
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = "do shell script \"\(escaped)\" with administrator privileges"
        let result = try await runProcess(path: "/usr/bin/osascript", arguments: ["-e", appleScript])
        guard result.status == 0 else {
            let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw InstallError.authorizationFailed(detail.isEmpty ? "授权被取消或操作失败（退出码 \(result.status)）" : detail)
        }
        return result.output
    }

    private func runProcess(path: String, arguments: [String]) async throws -> (status: Int32, output: String) {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(status: Int32, output: String), Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
                return
            }
            // Drain output concurrently. Waiting for process termination before reading
            // a Pipe can deadlock if the child writes enough stderr/stdout.
            DispatchQueue.global(qos: .utility).async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let output = String(data: data, encoding: .utf8) ?? ""
                continuation.resume(returning: (process.terminationStatus, output))
            }
        }
    }

    private func readSystemBattery() {
        let result = run(path: "/usr/bin/pmset", arguments: ["-g", "batt"])
        guard result.status == 0 else { return }
        let output = result.output
        let lower = output.lowercased()

        if let range = output.range(of: #"\d+%"#, options: .regularExpression) {
            let value = String(output[range]).replacingOccurrences(of: "%", with: "")
            batteryPercent = Int(value)
        }

        // Do not use lower.contains("charging") by itself: "discharging" also
        // contains that substring, which previously misclassified battery power
        // as charging and left discharge watts permanently unavailable.
        let isAC = lower.contains("ac power")
        isAdapterConnected = isAC
        let isBattery = lower.contains("battery power")
        let isNotCharging = lower.contains("not charging")
        let hasDischargingToken = lower.range(of: #"\bdischarging\b"#, options: .regularExpression) != nil
        let hasChargingToken = lower.range(of: #"\bcharging\b"#, options: .regularExpression) != nil
        let hasChargedToken = lower.range(of: #"\bcharged\b"#, options: .regularExpression) != nil
        let isCharging = hasChargingToken && !isNotCharging && !hasDischargingToken
        let isDischarging = hasDischargingToken || (isBattery && !isAC && !isCharging && !isNotCharging)

        if isDischarging {
            batteryStateText = "电池供电"
        } else if isCharging {
            batteryStateText = "正在充电"
        } else if isAC {
            batteryStateText = hasChargedToken ? "已接电源，已充满" : "已接电源，未充电"
        } else if isNotCharging {
            batteryStateText = "未充电"
        } else if hasChargedToken {
            batteryStateText = "已充满"
        } else {
            batteryStateText = isBattery ? "电池供电" : "未充电"
        }

        readLowPowerMode(onACPower: isAC ? true : (isBattery ? false : nil))
    }

    private func applyPowerSample(_ sample: BatteryPowerSample?) {
        if chargePowerWatts != sample?.chargeWatts { chargePowerWatts = sample?.chargeWatts }
        if dischargePowerWatts != sample?.dischargeWatts { dischargePowerWatts = sample?.dischargeWatts }
        guard let sample else { return }
        if let percent = sample.percent, batteryPercent != percent { batteryPercent = percent }
        if let connected = sample.externalConnected, isAdapterConnected != connected { isAdapterConnected = connected }
        let state: String
        if sample.isDischarging { state = "电池供电" }
        else if sample.isCharging { state = "正在充电" }
        else if sample.externalConnected == true {
            state = sample.fullyCharged == true ? "已接电源，已充满" : "已接电源，未充电"
        } else { return }
        if batteryStateText != state { batteryStateText = state }
    }

    private func readLowPowerMode(onACPower: Bool?) {
        guard let onACPower else {
            lowPowerMode = nil
            return
        }
        let result = run(path: "/usr/bin/pmset", arguments: ["-g", "custom"])
        guard result.status == 0 else {
            lowPowerMode = nil
            return
        }
        let target = onACPower ? "AC Power:" : "Battery Power:"
        let lines = result.output.components(separatedBy: .newlines)
        var inTargetSection = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasSuffix("Power:") {
                inTargetSection = trimmed.caseInsensitiveCompare(target) == .orderedSame
                continue
            }
            if inTargetSection,
               let value = extractNumber(pattern: #"^lowpowermode\s+([01])"#, from: trimmed) {
                lowPowerMode = value == 1
                return
            }
        }
        lowPowerMode = nil
    }

    private func locateBatt() -> String? {
        #if MAULEAF_INTEL_EXPERIMENTAL
        return nil
        #endif
        if let cached = battPath, FileManager.default.isExecutableFile(atPath: cached) {
            return cached
        }
        let candidates = [
            "/opt/homebrew/bin/batt",
            "/usr/local/bin/batt",
            "/opt/homebrew/sbin/batt",
            "/usr/local/sbin/batt"
        ]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            battPath = found
            return found
        }
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for directory in path.split(separator: ":") {
                let candidate = "\(directory)/batt"
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    battPath = candidate
                    return candidate
                }
            }
        }
        battPath = nil
        return nil
    }

    private func run(path: String, arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        } catch {
            return (-1, error.localizedDescription)
        }
    }

    private func extractNumber(pattern: String, from text: String) -> Int? {
        guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        let matched = String(text[range])
        guard let digits = matched.range(of: #"-?\d+"#, options: .regularExpression) else { return nil }
        return Int(matched[digits])
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private enum InstallError: LocalizedError {
        case authorizationFailed(String)

        var errorDescription: String? {
            switch self {
            case .authorizationFailed(let message): return message
            }
        }
    }
}
