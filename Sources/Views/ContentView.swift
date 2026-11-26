import SwiftUI
import AppKit
import Combine
import Foundation
import QuartzCore

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
                    .padding(.bottom, 8)
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
                    .padding(.leading, 4)
                    .padding(.bottom, 6)
                    .transition(expansionTransition)
            }
            rowDivider

            Button {
                NSApp.terminate(nil)
            } label: {
                HStack(spacing: 10) {
                    Group {
                        if manager.isPreparingToQuit {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "power").font(.system(size: 16, weight: .medium))
                        }
                    }
                    .frame(width: 20)
                    Text(manager.text(manager.isPreparingToQuit ? "正在退出…" : "退出 MauLeaf"))
                        .font(.subheadline.weight(.medium))
                    Spacer()
                }
                .contentShape(Rectangle())
                .padding(.vertical, 7)
            }
            .buttonStyle(.plain)
            .disabled(manager.isPreparingToQuit)
            .help(manager.text("退出时将恢复任务交给后台服务，应用无需等待恢复完成。"))
        }
        .padding(.horizontal, 17)
        .padding(.top, 22)
        .padding(.bottom, 8)
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
            Text(manager.text("取消充电任务并恢复原始配置。恢复失败时保留恢复数据。"))
        }
        .task { manager.start() }
    }

    /// Power flow replaces oversized battery digits. In compact mode the
    /// same source-state badge remains visible without any watt diagram.
    private var batteryCard: some View {
        VStack(alignment: .leading, spacing: 3) {
            if manager.showPowerFlow {
                MauLeafPowerFlowView(flow: manager.powerFlow, language: manager.language)
                    .padding(.bottom, 2)
                    .transition(.opacity)
            } else {
                // Hiding the chart never hides power-source information.
                // The exact same badge is used by the expanded diagram.
                MauLeafPowerStatusRow(mode: manager.powerFlow.mode, language: manager.language)
                    .padding(.bottom, 2)
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
            .padding(.vertical, 4)
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
            .padding(.vertical, 7)
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

    /// Native controls; settings retain their existing business bindings.
    private var settingsControls: some View {
        SettingsView(manager: manager)
    }

    #if MAULEAF_LAYOUT_TESTING
    var batteryCardForTesting: some View { batteryCard }
    var settingsControlsForTesting: some View { settingsControls }
    #endif
}
