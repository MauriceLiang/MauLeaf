import SwiftUI

struct SettingsView: View {
    @ObservedObject var manager: ChargeManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                settingsLabel("显示供电详情")
                Spacer(minLength: 8)
                Toggle(isOn: $manager.showPowerFlow) { EmptyView() }
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                    .tint(.green)
                    .accessibilityLabel(manager.text("显示供电详情"))
                    .help(manager.text("关闭后保留供电状态，仅隐藏供电流向图"))
            }
            .frame(minHeight: 24)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    settingsLabel("动态保电")
                    Spacer(minLength: 8)
                    Toggle(isOn: Binding(
                        get: { manager.dynamicHoldEnabled },
                        set: { manager.setDynamicHoldEnabled($0) }
                    )) { EmptyView() }
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                    .tint(.green)
                    .disabled(manager.isDynamicHoldSwitchLocked)
                    .accessibilityLabel(manager.text("动态保电"))
                    .help(manager.text(manager.isDynamicHoldSwitchLocked
                        ? "本次充满期间不可修改动态保电"
                        : "高于目标时保持电量；关闭后在已测试机型上可能出现拔电识别延迟"))
                }
                .frame(minHeight: 24)
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
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    settingsLabel("退出时移除组件")
                    Spacer(minLength: 8)
                    Toggle(isOn: $manager.removeComponentsOnQuit) { EmptyView() }
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(.small)
                        .tint(.green)
                        .accessibilityLabel(manager.text("退出时移除组件"))
                        .help(manager.text("开启后每次退出会移除控制组件；关闭则保留。"))
                }
                .frame(minHeight: 24)
                Text(manager.text("建议卸载前开启，退出并确认清理完成后再删除 App。"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                settingsLabel("界面语言")
                Spacer(minLength: 8)
                Picker("", selection: $manager.language) {
                    Text("简体中文").tag(AppLanguage.simplifiedChinese)
                    Text("English").tag(AppLanguage.english)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 112)
                .accessibilityLabel(manager.text("界面语言"))
                .help(manager.text("切换界面语言"))
            }
            .frame(minHeight: 24)

            Divider().opacity(0.55)
            HStack {
                settingsLabel("充电控制重置")
                Spacer(minLength: 8)
                Button(manager.text("强制重置")) { manager.requestForceReset() }
                    .controlSize(.small)
                    .disabled(!manager.canForceReset)
            }
            .frame(minHeight: 24)
        }
        .padding(.vertical, 2)
    }

    private func settingsLabel(_ title: AppText) -> some View {
        Text(manager.text(title))
            .font(.caption)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
