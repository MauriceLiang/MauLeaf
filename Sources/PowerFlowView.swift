import SwiftUI

/// Compact power-flow visualization replacing the old large battery number.
/// The ribbons show direction, not independently measured per-component load.
struct MauLeafPowerFlowView: View {
    let flow: MauLeafPowerFlow
    let language: AppLanguage

    private let sourceWidth: CGFloat = 105
    private let sinkWidth: CGFloat = 120
    private let nodeHeight: CGFloat = 57
    private let teal = Color(red: 0.18, green: 0.78, blue: 0.91)
    private let blue = Color(red: 0.36, green: 0.40, blue: 0.97)
    private let green = Color(red: 0.27, green: 0.85, blue: 0.42)
    private let amber = Color(red: 0.96, green: 0.64, blue: 0.20)

    private func tr(_ chinese: String, _ english: String) -> String {
        language == .english ? english : chinese
    }

    private var header: String {
        switch flow.mode {
        case .battery: return tr("电池供电", "On Battery")
        case .adapter: return tr("适配器供电", "Adapter Connected")
        case .charging: return tr("充电中", "Charging")
        case .assisted: return tr("电池辅助供电", "Battery Discharging")
        case .unavailable: return tr("供电状态未知", "Power Unavailable")
        }
    }

    private var headerColor: Color {
        switch flow.mode {
        case .battery, .assisted: return amber
        case .adapter, .charging: return green
        case .unavailable: return .secondary
        }
    }

    private var twoPaths: Bool {
        flow.mode == .charging || flow.mode == .assisted
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(tr("供电详情", "Power Flow"))
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 3)
                HStack(spacing: 5) {
                    Circle().fill(headerColor).frame(width: 6, height: 6)
                    Text(header)
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.065),
                            in: Capsule())
            }

            GeometryReader { proxy in
                let height = proxy.size.height
                let midX = proxy.size.width
                ZStack(alignment: .topLeading) {
                    Canvas { context, size in
                        let startX = sourceWidth - 3
                        let endX = size.width - sinkWidth + 2
                        switch flow.mode {
                        case .charging:
                            ribbon(&context, x1: startX, y1: height / 2 - 6,
                                   x2: endX, y2: nodeHeight / 2,
                                   value: flow.systemWatts, tint: blue)
                            ribbon(&context, x1: startX, y1: height / 2 + 9,
                                   x2: endX, y2: height - nodeHeight / 2,
                                   value: flow.batteryWatts, tint: green)
                        case .assisted:
                            ribbon(&context, x1: startX, y1: nodeHeight / 2,
                                   x2: endX, y2: height / 2 - 6,
                                   value: flow.adapterWatts, tint: teal)
                            ribbon(&context, x1: startX, y1: height - nodeHeight / 2,
                                   x2: endX, y2: height / 2 + 9,
                                   value: flow.batteryWatts.map { abs($0) }, tint: amber)
                        case .battery:
                            ribbon(&context, x1: startX, y1: height / 2,
                                   x2: endX, y2: height / 2,
                                   value: flow.systemWatts, tint: amber)
                        case .adapter:
                            ribbon(&context, x1: startX, y1: height / 2,
                                   x2: endX, y2: height / 2,
                                   value: flow.adapterWatts, tint: blue)
                        case .unavailable:
                            break
                        }
                    }
                    if flow.mode == .charging {
                        powerNode(tr("适配器", "Adapter"), icon: "powerplug.fill",
                                  watts: flow.adapterWatts, color: teal, width: sourceWidth, height: 82)
                            .position(x: sourceWidth / 2, y: height / 2)
                        powerNode(tr("系统功耗", "System"), icon: "desktopcomputer",
                                  watts: flow.systemWatts, color: blue, width: sinkWidth)
                            .position(x: midX - sinkWidth / 2, y: nodeHeight / 2)
                        powerNode(tr("电池充电", "Battery Charge"), icon: "battery.100percent.bolt",
                                  watts: flow.batteryWatts, color: green, width: sinkWidth)
                            .position(x: midX - sinkWidth / 2, y: height - nodeHeight / 2)
                    } else if flow.mode == .assisted {
                        powerNode(tr("适配器", "Adapter"), icon: "powerplug.fill",
                                  watts: flow.adapterWatts, color: teal, width: sourceWidth)
                            .position(x: sourceWidth / 2, y: nodeHeight / 2)
                        powerNode(tr("电池放电", "Battery"), icon: "battery.50percent",
                                  watts: flow.batteryWatts.map { abs($0) },
                                  color: amber, width: sourceWidth)
                            .position(x: sourceWidth / 2, y: height - nodeHeight / 2)
                        powerNode(tr("系统功耗", "System"), icon: "desktopcomputer",
                                  watts: flow.systemWatts, color: blue, width: sinkWidth, height: 82)
                            .position(x: midX - sinkWidth / 2, y: height / 2)
                    } else if flow.mode == .battery {
                        powerNode(tr("电池放电", "Battery"), icon: "battery.50percent",
                                  watts: flow.batteryWatts.map { abs($0) },
                                  color: amber, width: sourceWidth)
                            .position(x: sourceWidth / 2, y: height / 2)
                        powerNode(tr("系统功耗", "System"), icon: "desktopcomputer",
                                  watts: flow.systemWatts, color: blue, width: sinkWidth)
                            .position(x: midX - sinkWidth / 2, y: height / 2)
                    } else if flow.mode == .adapter {
                        powerNode(tr("适配器", "Adapter"), icon: "powerplug.fill",
                                  watts: flow.adapterWatts, color: teal, width: sourceWidth)
                            .position(x: sourceWidth / 2, y: height / 2)
                        powerNode(tr("系统功耗", "System"), icon: "desktopcomputer",
                                  watts: flow.systemWatts, color: blue, width: sinkWidth)
                            .position(x: midX - sinkWidth / 2, y: height / 2)
                    } else {
                        Text(tr("暂时无法读取供电数据", "Power data currently unavailable"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: midX, height: height)
                    }
                }
            }
            .frame(height: twoPaths ? 128 : 66)
            .accessibilityElement(children: .combine)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 13)
            .fill(Color.primary.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 13)
            .stroke(Color.primary.opacity(0.10), lineWidth: 0.7))
        .accessibilityLabel(accessibilityDescription)
    }

    private var accessibilityDescription: String {
        let source = tr("供电详情", "Power Flow") + "，" + header
        let adapter = tr("适配器", "Adapter") + " " + MauLeafPowerFlow.display(flow.adapterWatts)
        let battery = tr("电池", "Battery") + " " + MauLeafPowerFlow.display(flow.batteryWatts.map { abs($0) })
        let system = tr("系统", "System") + " " + MauLeafPowerFlow.display(flow.systemWatts)
        return "\(source)，\(adapter)，\(battery)，\(system)"
    }

    private func powerNode(_ title: String, icon: String, watts: Double?,
                           color: Color, width: CGFloat, height: CGFloat = 57) -> some View {
        HStack(alignment: .center, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(MauLeafPowerFlow.display(watts))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(title)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(width: width, height: height)
        .background(RoundedRectangle(cornerRadius: 12).fill(color.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .stroke(color.opacity(0.58), lineWidth: 1))
    }

    private func ribbon(_ context: inout GraphicsContext,
                        x1: CGFloat, y1: CGFloat, x2: CGFloat, y2: CGFloat,
                        value: Double?, tint: Color) {
        // Only direction is visualized; width is decorative, not a claim
        // of calibrated energy accounting. Unknown readings are subdued.
        let half: CGFloat = value == nil ? 2 : 5
        let bend = (x2 - x1) * 0.47
        var path = Path()
        path.move(to: CGPoint(x: x1, y: y1 - half))
        path.addCurve(to: CGPoint(x: x2, y: y2 - half),
                      control1: CGPoint(x: x1 + bend, y: y1 - half),
                      control2: CGPoint(x: x2 - bend, y: y2 - half))
        path.addLine(to: CGPoint(x: x2, y: y2 + half))
        path.addCurve(to: CGPoint(x: x1, y: y1 + half),
                      control1: CGPoint(x: x2 - bend, y: y2 + half),
                      control2: CGPoint(x: x1 + bend, y: y1 + half))
        path.closeSubpath()
        context.fill(path, with: .linearGradient(
            Gradient(colors: [tint.opacity(value == nil ? 0.12 : 0.70),
                              tint.opacity(value == nil ? 0.10 : 0.90)]),
            startPoint: CGPoint(x: x1, y: y1),
            endPoint: CGPoint(x: x2, y: y2)
        ))
    }
}
