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

struct ContentView: View {
    @ObservedObject var manager: ChargeManager
    private let presets = [70, 75, 80, 85, 90, 95]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            batteryCard
            limitSection
                .disabled(manager.isPreparingToQuit)
            limitControlSection
                .disabled(manager.isPreparingToQuit)
            if manager.hasOriginalStateSnapshot || manager.fullOncePending {
                oneTimeChargeSection
                    .disabled(manager.isPreparingToQuit)
            }
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
        .alert(manager.text("检测到旧版充电限制"), isPresented: $manager.showLegacyDisableConfirmation) {
            Button(manager.text("停用旧版限制"), role: .destructive) {
                manager.confirmDisableLegacyLimit()
            }
            Button(manager.text("取消"), role: .cancel) {}
        } message: {
            Text(manager.text("Preview 4 没有保存首次启用前的固件阈值，因此无法恢复原始上限。继续操作只会关闭旧版限充激活标志，并保留当前阈值；这不等于恢复历史原状。"))
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
            .disabled(manager.isBusy || manager.isPreparingToQuit || manager.fullOncePending || manager.isLegacyActive)

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
                    .disabled(manager.isBusy || manager.isPreparingToQuit || manager.fullOncePending || manager.isLegacyActive)
                }
            }
            Text(manager.text("未启用时仅保存上限设置；启用后修改会立即应用。"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var limitControlSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            if manager.isLegacyActive {
                Label(manager.text("检测到旧版或未托管的固件限充"), systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.orange)
                Text(manager.text("没有找到首次启用前的原始固件快照。停用旧版限制只能关闭激活标志，不能恢复未保存的阈值。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    manager.requestLegacyDisableConfirmation()
                } label: {
                    Label(manager.text("停用旧版限制"), systemImage: "power")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!manager.canDisableLegacyLimit)
            } else if manager.restorePending {
                Label(manager.text("正在等待恢复原始固件配置"), systemImage: "arrow.triangle.2.circlepath")
                    .font(.subheadline.weight(.semibold))
                Text(manager.text("原始配置快照已保留。接入电源后，后台服务会继续恢复；也可以手动重试。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    manager.disableLimit()
                } label: {
                    Label(manager.text("重试恢复原始配置"), systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!manager.canRetryOriginalRestore)
            } else if manager.hasOriginalStateSnapshot {
                HStack {
                    Label(manager.text("限制充电已启用"), systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.green)
                    Spacer()
                    Text(manager.text("上限 \(manager.limit)%"))
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                }
                Text(manager.text("MauLeaf 已保存启用前的固件配置。关闭时会逐项恢复并验证原始值。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    manager.disableLimit()
                } label: {
                    Label(manager.text("关闭限制充电"), systemImage: "power")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!manager.canDisableLimit)
            } else {
                Label(manager.text("限制充电尚未启用"), systemImage: "leaf")
                    .font(.subheadline.weight(.semibold))
                Text(manager.text("当前不会向固件写入充电上限。启用时会先保存原始配置，之后可随时关闭并恢复。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    manager.enableLimit()
                } label: {
                    Label(manager.text("启用限制充电"), systemImage: "leaf.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!manager.canEnableLimit)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 11))
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
                Text(manager.text(manager.fullOnceCancelRequested
                    ? "已请求恢复原上限；当前未连接电源，重新接电后会继续恢复。"
                    : "原生固件限充已临时关闭；达到 100% 或 10 小时期限后自动恢复原上限。断开电源时会等待重新接电再恢复。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !manager.fullOnceCancelRequested {
                    Button {
                        manager.cancelFullOnce()
                    } label: {
                        Label(manager.text("取消本次充满并恢复上限"), systemImage: "arrow.uturn.backward")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(manager.isBusy)
                }
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
                    !manager.canStartFullCharge || (manager.batteryPercent ?? 0) >= 100
                )
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 11))
    }

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
    @Published private(set) var fullOnceCancelRequested = false
    @Published var modeText: AppText = "正在检查原生固件控制…"
    @Published var statusMessage: AppText = "正在连接 MauLeaf 原生固件服务…"
    @Published var autoApplyFeedback: AppText = "调整后自动应用"
    @Published var backendReady = false
    @Published private(set) var restoreReady = false
    @Published var isBusy = false
    @Published private(set) var isPreparingToQuit = false
    @Published var isError = false
    @Published var showNativeWriteConfirmation = false
    @Published var showLegacyDisableConfirmation = false

    private let backend: NativeFirmwareBackend
    private let autoInstallNativeHelper: Bool
    private var helperInstallAttempted = false
    private var started = false
    private var refreshTimer: Timer?
    private var limitDebounce: Task<Void, Never>?
    @Published private(set) var currentState: FirmwareLimitHelperStateResponse?
    private var pendingAction: PendingAction?
    private var lastAction: PendingAction?

    private enum PendingAction {
        case enable
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
        backendReady && currentState != nil && currentState?.active == false
            && !restorePending && isAdapterConnected
            && !isBusy && !isPreparingToQuit && !fullOncePending
    }

    var canDisableLimit: Bool {
        restoreReady && hasOriginalStateSnapshot && isAdapterConnected
            && !isBusy && !isPreparingToQuit
    }

    var canRetryOriginalRestore: Bool {
        restoreReady && restorePending && isAdapterConnected
            && !isBusy && !isPreparingToQuit
    }

    var canDisableLegacyLimit: Bool {
        backendReady && isLegacyActive && isAdapterConnected
            && !isBusy && !isPreparingToQuit
    }

    var canStartFullCharge: Bool {
        backendReady && hasOriginalStateSnapshot && currentState?.active == true
            && isAdapterConnected && !isBusy && !isPreparingToQuit && !fullOncePending
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
            let initialState = try await backend.readState()
            let state = try await ensureCurrentNativeHelper(initialState, allowInstall: allowInstall)
            let oneTime = try await backend.oneTimeChargeStatus()
            updateFromNativeState(state, oneTime: oneTime, status: "已读取原生固件状态。")
        } catch {
            if allowInstall, autoInstallNativeHelper, !helperInstallAttempted, isHelperUnavailable(error) {
                helperInstallAttempted = true
                isBusy = true
                statusMessage = "正在启用 MauLeaf 原生固件服务，需要一次管理员授权…"
                do {
                    try await installNativeHelper()
                    let state = try await backend.readState()
                    let oneTime = try await backend.oneTimeChargeStatus()
                    updateFromNativeState(state, oneTime: oneTime, status: "MauLeaf 原生固件服务已启用。")
                    isBusy = false
                    return
                } catch {
                    isBusy = false
                    backendReady = false
                    restoreReady = false
                    currentState = nil
                    modeText = "原生固件服务未启用"
                    statusMessage = "无法启用原生固件服务：\(AppText(error: error))"
                    isError = true
                    return
                }
            }
            backendReady = false
            restoreReady = false
            currentState = nil
            modeText = "原生固件控制不可用"
            statusMessage = AppText(error: error)
            isError = true
        }
    }

    private func updateFromNativeState(
        _ state: FirmwareLimitHelperStateResponse,
        oneTime: FirmwareLimitHelperOneTimeStatusResponse,
        status: AppText
    ) {
        currentState = state
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
            statusMessage = "当前系统不允许启用新的限充配置，但可以使用已保存快照恢复原始状态。"
            isError = false
        }
    }

    private func ensureCurrentNativeHelper(
        _ state: FirmwareLimitHelperStateResponse,
        allowInstall: Bool
    ) async throws -> FirmwareLimitHelperStateResponse {
        let required = FirmwareLimitHelperProtocolVersion.current
        guard state.helperVersion < required else { return state }
        guard allowInstall, autoInstallNativeHelper, !helperInstallAttempted else {
            throw NativeControlError.outdatedHelper(found: state.helperVersion, required: required)
        }

        helperInstallAttempted = true
        isBusy = true
        statusMessage = "检测到旧版 MauLeaf 原生固件服务，正在更新，需要管理员授权…"
        defer { isBusy = false }
        try await installNativeHelper()

        let updated = try await backend.readState()
        guard updated.helperVersion >= required else {
            throw NativeControlError.helperUpgradeFailed(
                found: updated.helperVersion,
                required: required
            )
        }
        return updated
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
        Task { await applyLimit(limit) }
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
        isBusy = true
        isError = false
        statusMessage = "正在恢复启用前的原始固件配置…"
        defer { isBusy = false }
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
            statusMessage = AppText(verbatim: response.message)
            isError = false
        } catch {
            isBusy = false
            statusMessage = "恢复原始固件配置失败：\(AppText(error: error))"
            isError = true
            await refreshNativeState(allowInstall: false)
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
            Task { await applyLimit(limit) }
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
            isBusy = true
            isError = false
            statusMessage = "正在取消本次充满并恢复原生充电上限…"
            defer { isBusy = false }
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
            backendReady = response.state.writeSupported
            restoreReady = response.state.restoreSupported
            fullOncePending = response.oneTimePending
            fullOnceCancelRequested = false
            modeText = "限制充电已启用 · 上限 \(value)%"
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
                lower: currentState?.lower ?? max(5, limit - 2),
                confirmed: true
            )
            currentState = response.state
            backendReady = response.state.writeSupported
            restoreReady = response.state.restoreSupported
            fullOncePending = response.oneTimePending
            fullOnceCancelRequested = false
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
        case .enable: Task { await applyLimit(limit) }
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

    var errorDescription: String? {
        switch self {
        case .missingBundledHelper:
            return "应用包中缺少 MauLeaf 原生固件服务文件，请重新安装预览版。"
        case .authorizationFailed(let detail):
            return detail
        case .outdatedHelper(let found, let required):
            return "MauLeaf 原生固件服务版本过旧（当前协议版本 \(found)，需要 \(required)），请重新启动应用并允许更新服务。"
        case .helperUpgradeFailed(let found, let required):
            return "MauLeaf 原生固件服务更新未生效（当前协议版本 \(found)，需要 \(required)）。请退出应用后重新启动，再尝试更新。"
        }
    }
}
