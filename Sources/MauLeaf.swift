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
    private let presets = [70, 75, 80, 85, 90, 95]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            batteryCard
            #if MAULEAF_INTEL_EXPERIMENTAL
            intelPreviewSection
            #else
            limitSection
                .disabled(manager.isPreparingToQuit)
            oneTimeChargeSection
                .disabled(manager.isPreparingToQuit)
            #endif
            Divider()
            footer
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 16)
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
        .task { manager.start() }
    }

    private var batteryCard: some View {
        VStack(alignment: .leading, spacing: 11) {
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
                BatteryStatusRing(
                    percent: manager.batteryPercent,
                    tint: manager.batteryTint,
                    icon: manager.batteryRingIcon
                )
                .padding(.trailing, 3)
            }

            Divider().opacity(0.7)

            HStack(spacing: 8) {
                Circle()
                    .fill(manager.backendReady ? Color.green : Color.secondary)
                    .frame(width: 7, height: 7)
                Text(manager.text(manager.modeText))
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
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
            .disabled(!manager.backendReady || !manager.isAdapterConnected || manager.isBusy || manager.fullOncePending)

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
                    .disabled(!manager.backendReady || !manager.isAdapterConnected || manager.isBusy || manager.fullOncePending)
                }
            }
            Text(manager.text("连接电源后自动写入原生固件；本次充满期间暂不可修改上限。"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var oneTimeChargeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(manager.text("本次充满"))
                    .font(.subheadline.weight(.medium))
                Spacer()
                if manager.fullOncePending {
                    Text(manager.text("进行中"))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.green)
                }
            }

            if manager.fullOncePending {
                Text(manager.text("原生固件限充已临时关闭；达到 100% 或 10 小时期限后自动恢复原上限。断开电源时会等待重新接电再恢复。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    manager.cancelFullOnce()
                } label: {
                    Label(manager.text("取消本次充满并恢复上限"), systemImage: "arrow.uturn.backward")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(manager.isBusy)
            } else {
                Text(manager.text("仅本次允许充至 100%；完成后由原生后台服务恢复当前充电上限。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    manager.beginOneTimeFullCharge()
                } label: {
                    Label(manager.text("充满至 100%"), systemImage: "bolt.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    !manager.backendReady || !manager.isAdapterConnected || manager.isBusy
                    || (manager.batteryPercent ?? 0) >= 100
                )
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 11))
    }

    #if MAULEAF_INTEL_EXPERIMENTAL
    private var intelPreviewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(manager.language == .english ? "Intel experimental preview" : "Intel 实验预览版")
                .font(.subheadline.weight(.semibold))
            Text(manager.language == .english
                 ? "Unverified Intel preview: the developer has no Intel Mac and has not tested launching or running this build on Intel hardware. Actual operation, accuracy and stability are unknown. Battery information only; native charging controls are unavailable. Provided AS IS, at your own risk."
                 : "未经实机测试的 Intel 实验预览版：开发者没有 Intel Mac，未在 Intel 设备上安装、启动或运行本版本。实际运行情况、数据准确性与稳定性均未知。仅展示电池信息，不提供原生充电控制；软件按现状提供，风险由使用者自行评估。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.075), in: RoundedRectangle(cornerRadius: 10))
    }
    #endif

    private var footer: some View {
        HStack(spacing: 12) {
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
                .help(manager.text("退出 MauLeaf 不会取消已写入固件的充电上限；本次充满由原生后台服务负责恢复。"))
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
    @Published private(set) var menuBarLeafStyle: MenuBarLeafStyle = .green
    @Published private(set) var fullOncePending = false
    @Published var modeText: AppText = "正在检查原生固件控制…"
    @Published var statusMessage: AppText = "正在连接 MauLeaf 原生固件服务…"
    @Published var autoApplyFeedback: AppText = "调整后自动应用"
    @Published var backendReady = false
    @Published var isBusy = false
    @Published private(set) var isPreparingToQuit = false
    @Published var isError = false
    @Published var lowPowerMode: Bool?
    @Published var showNativeWriteConfirmation = false

    private let backend: NativeFirmwareBackend
    private let autoInstallNativeHelper: Bool
    private var helperInstallAttempted = false
    private var started = false
    private var panelVisible = false
    private var refreshTimer: Timer?
    private var limitDebounce: Task<Void, Never>?
    private var currentState: FirmwareLimitHelperStateResponse?
    private var pendingAction: PendingAction?
    private var lastAction: PendingAction?

    private enum PendingAction {
        case limit(Int)
        case full
    }

    init(
        backend: NativeFirmwareBackend = FirmwareLimitHelperClient(),
        autoInstallNativeHelper: Bool = true
    ) {
        self.backend = backend
        self.autoInstallNativeHelper = autoInstallNativeHelper
        let saved = UserDefaults.standard.integer(forKey: "chargeLimit")
        limit = (50...95).contains(saved) ? saved : 80
    }

    func text(_ message: AppText) -> String { message.localized(in: language) }

    var batteryTint: Color {
        if let batteryPercent, batteryPercent < 20 { return .red }
        if batteryStateText == "正在充电" { return .green }
        if lowPowerMode == true { return .yellow }
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
        let state = AppText(key: batteryStateText)
        if lowPowerMode == true { return "\(state)，低电量模式" }
        return state
    }

    var batteryStateSymbol: String {
        switch batteryStateText {
        case "正在充电": return "bolt.fill"
        case "已充满", "已接电源，已充满": return "battery.100percent"
        case "电池供电": return "battery.75percent"
        default: return "powerplug"
        }
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

    func start() {
        guard !started else { return }
        started = true
        readSystemBattery()
        Task { await refreshNativeState(allowInstall: true) }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isBusy else { return }
                self.readSystemBattery()
                await self.refreshNativeState(allowInstall: false)
            }
        }
    }

    func setPanelVisible(_ visible: Bool) {
        panelVisible = visible
        if visible { refresh() }
    }

    func refresh() {
        guard !isPreparingToQuit else { return }
        readSystemBattery()
        guard started, !isBusy else { return }
        Task { await refreshNativeState(allowInstall: false) }
    }

    private func refreshNativeState(allowInstall: Bool) async {
        guard !isPreparingToQuit, !isBusy else { return }
        do {
            let state = try await backend.readState()
            let oneTime = try await backend.oneTimeChargeStatus()
            currentState = state
            fullOncePending = oneTime.pending
            backendReady = true
            if (50...95).contains(state.upper) { limit = state.upper }
            if oneTime.pending {
                modeText = "本次充满进行中 · 原上限 \(oneTime.restoreUpper ?? limit)%"
            } else if state.active {
                modeText = "原生固件限充至 \(state.upper)%"
            } else {
                modeText = "原生固件限充未启用"
            }
            statusMessage = "已读取原生固件状态；寄存器读回成功仍需进一步验证实际充电行为。"
            isError = false
        } catch {
            if allowInstall, autoInstallNativeHelper, !helperInstallAttempted, isHelperUnavailable(error) {
                helperInstallAttempted = true
                isBusy = true
                statusMessage = "正在启用 MauLeaf 原生固件服务，需要一次管理员授权…"
                do {
                    try await installNativeHelper()
                    let state = try await backend.readState()
                    let oneTime = try await backend.oneTimeChargeStatus()
                    currentState = state
                    fullOncePending = oneTime.pending
                    backendReady = true
                    if (50...95).contains(state.upper) { limit = state.upper }
                    modeText = oneTime.pending
                        ? "本次充满进行中 · 原上限 \(oneTime.restoreUpper ?? limit)%"
                        : (state.active ? "原生固件限充至 \(state.upper)%" : "原生固件限充未启用")
                    statusMessage = "MauLeaf 原生固件服务已启用。"
                    isError = false
                    isBusy = false
                    return
                } catch {
                    isBusy = false
                    backendReady = false
                    modeText = "原生固件服务未启用"
                    statusMessage = "无法启用原生固件服务：\(AppText(error: error))"
                    isError = true
                    return
                }
            }
            backendReady = false
            currentState = nil
            modeText = "原生固件控制不可用"
            statusMessage = AppText(error: error)
            isError = true
        }
    }

    private func isHelperUnavailable(_ error: Error) -> Bool {
        guard let helperError = error as? FirmwareLimitHelperClientError else { return false }
        switch helperError {
        case .serviceUnavailable, .connectionInvalidated: return true
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
        autoApplyFeedback = "等待自动应用 \(value)%…"
        guard backendReady else {
            statusMessage = "原生固件控制尚未就绪。"
            isError = true
            return
        }
        guard isAdapterConnected else {
            statusMessage = "请先连接电源，再修改原生固件充电上限。"
            isError = true
            return
        }
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

    func beginOneTimeFullCharge() {
        guard backendReady, isAdapterConnected, !isBusy, !isPreparingToQuit,
              (batteryPercent ?? 0) < 100 else { return }
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
        pendingAction = nil
        if let currentState, (50...95).contains(currentState.upper) { limit = currentState.upper }
    }

    func cancelFullOnce() {
        guard !isBusy, !isPreparingToQuit else { return }
        lastAction = .full
        Task {
            isBusy = true
            isError = false
            statusMessage = "正在取消本次充满并恢复原生充电上限…"
            defer { isBusy = false }
            do {
                let response = try await backend.cancelOneTimeCharge()
                currentState = response.state
                fullOncePending = response.oneTimePending
                modeText = response.oneTimePending
                    ? "等待接电后恢复原生充电上限"
                    : "原生固件限充至 \(response.state.upper)%"
                statusMessage = AppText(verbatim: response.message)
                isError = false
            } catch {
                statusMessage = "取消本次充满失败：\(AppText(error: error))"
                isError = true
            }
        }
    }

    private func applyLimit(_ value: Int) async {
        guard backendReady, isAdapterConnected, !isBusy, !isPreparingToQuit else { return }
        isBusy = true
        isError = false
        statusMessage = "正在写入原生固件充电上限 \(value)%…"
        autoApplyFeedback = "正在应用 \(value)%…"
        defer { isBusy = false }
        do {
            let response = try await backend.applyLimit(
                upper: value,
                lower: max(5, value - 2),
                confirmed: true
            )
            currentState = response.state
            fullOncePending = response.oneTimePending
            modeText = "原生固件限充寄存器：\(value)%"
            autoApplyFeedback = "已写入并读回 \(value)%"
            statusMessage = AppText(verbatim: response.message)
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
        isBusy = true
        isError = false
        statusMessage = "正在启动原生本次充满任务…"
        defer { isBusy = false }
        do {
            let response = try await backend.beginOneTimeCharge(
                upper: limit,
                lower: max(5, limit - 2),
                confirmed: true
            )
            currentState = response.state
            fullOncePending = response.oneTimePending
            modeText = "本次充满进行中 · 原上限 \(limit)%"
            statusMessage = AppText(verbatim: response.message)
            isError = false
        } catch {
            statusMessage = "启动本次充满失败：\(AppText(error: error))"
            isError = true
        }
    }

    func retryChargeRequest() {
        guard canRetryChargeRequest else { return }
        if !backendReady {
            helperInstallAttempted = false
            Task { await refreshNativeState(allowInstall: true) }
            return
        }
        switch lastAction {
        case .limit(let value): Task { await applyLimit(value) }
        case .full:
            if fullOncePending { cancelFullOnce() }
            else { Task { await applyOneTimeFullCharge() } }
        case nil: refresh()
        }
    }

    func prepareForTermination() async -> Bool {
        if isPreparingToQuit { return false }
        isPreparingToQuit = true
        limitDebounce?.cancel()
        refreshTimer?.invalidate()
        refreshTimer = nil
        let deadline = Date().addingTimeInterval(30)
        while isBusy {
            guard Date() < deadline else {
                isPreparingToQuit = false
                statusMessage = "当前原生固件操作尚未结束，已取消退出。"
                isError = true
                return false
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        // The firmware keeps the configured limit after the UI exits. The
        // privileged helper independently owns one-time restoration.
        return true
    }

    private func readSystemBattery() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "batt"]
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw NativeControlError.batteryReadFailed }
            let output = String(data: data, encoding: .utf8) ?? ""
            isAdapterConnected = output.localizedCaseInsensitiveContains("AC Power")
            if let range = output.range(of: #"\b\d{1,3}%"#, options: .regularExpression) {
                let value = Int(output[range].filter(\.isNumber))
                batteryPercent = value.flatMap { (0...100).contains($0) ? $0 : nil }
            } else {
                batteryPercent = nil
            }
            if isAdapterConnected {
                if output.localizedCaseInsensitiveContains("charging") {
                    batteryStateText = "正在充电"
                } else if batteryPercent == 100 || output.localizedCaseInsensitiveContains("charged") {
                    batteryStateText = "已接电源，已充满"
                } else {
                    batteryStateText = "已接电源，未充电"
                }
            } else {
                batteryStateText = "电池供电"
            }
        } catch {
            batteryPercent = nil
            isAdapterConnected = false
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
    case batteryReadFailed

    var errorDescription: String? {
        switch self {
        case .missingBundledHelper:
            return "应用包中缺少 MauLeaf 原生固件服务文件，请重新安装预览版。"
        case .authorizationFailed(let detail):
            return detail
        case .batteryReadFailed:
            return "无法读取 macOS 电池状态。"
        }
    }
}
