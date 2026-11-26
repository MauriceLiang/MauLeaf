import SwiftUI

// Inspired by the compact cards, proportional ribbons and masked translucent
// connections of Status Trio (lingyired/status-trio, Apache-2.0).
// Reimplemented for MauLeaf's read-only power metrics and 360pt popover.
// No firmware or background sampling changes.
/// The single source of truth for the status text and tint shared by the
/// expanded power diagram and the collapsed read-only power-status row.
struct MauLeafPowerStatusBadge: View {
    @Environment(\.colorScheme) private var colorScheme
    private var style: PowerFlowStyle { PowerFlowStyle(scheme: colorScheme) }
    let mode: MauLeafPowerFlow.Mode
    let language: AppLanguage

    static func title(for mode: MauLeafPowerFlow.Mode, language: AppLanguage) -> String {
        let english = language == .english
        switch mode {
        case .battery: return english ? "On Battery" : "电池供电"
        case .adapter: return english ? "On Adapter" : "适配器供电"
        case .charging: return english ? "Charging" : "充电中"
        case .assisted: return english ? "Battery Assist" : "电池辅助供电"
        case .unavailable: return english ? "Power Unknown" : "供电状态未知"
        }
    }

    static func tint(for mode: MauLeafPowerFlow.Mode) -> Color {
        switch mode {
        case .battery, .assisted: return .orange
        case .adapter, .charging: return .green
        case .unavailable: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(style.status(mode))
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(Self.title(for: mode, language: language))
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .foregroundStyle(style.primaryText)
        .background(style.badgeFill, in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

/// The display-only fallback is a short line, not an empty reserved chart.
/// It never introduces additional polling or privileged power operations.
struct MauLeafPowerStatusRow: View {
    let mode: MauLeafPowerFlow.Mode
    let language: AppLanguage

    var body: some View {
        HStack(spacing: 8) {
            Text(language == .english ? "Power" : "供电状态")
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 6)
            MauLeafPowerStatusBadge(mode: mode, language: language)
        }
        .padding(.horizontal, 2)
        .padding(.top, 4)
        .padding(.bottom, 11)
    }
}

struct MauLeafPowerFlowView: View {
    @Environment(\.colorScheme) private var colorScheme
    private var style: PowerFlowStyle { PowerFlowStyle(scheme: colorScheme) }

    let flow: MauLeafPowerFlow
    let language: AppLanguage

    private let sourceWidth: CGFloat = 74
    private let targetWidth: CGFloat = 99
    private let singleHeight: CGFloat = 76
    private let dualHeight: CGFloat = 110
    private let branchGap: CGFloat = 7
    private let cornerRadius: CGFloat = 12
    private let overlap: CGFloat = 6

    private enum Kind {
        case adapter, batterySource, batteryCharge, system

        var symbol: String {
            switch self {
            case .adapter: return "powerplug.fill"
            case .batterySource: return "battery.100percent"
            case .batteryCharge: return "battery.100percent.bolt"
            case .system: return "desktopcomputer"
            }
        }

        var role: PowerFlowStyle.Role {
            switch self {
            case .adapter: return .adapter
            case .batterySource: return .batterySource
            case .batteryCharge: return .batteryCharge
            case .system: return .system
            }
        }
    }

    private struct Metric: Identifiable {
        let id: String
        let label: String
        let watts: Double?
        let kind: Kind
    }

    private struct Band: Identifiable {
        let id: Int
        let start: CGPoint
        let end: CGPoint
        let startThickness: CGFloat
        let endThickness: CGFloat
        let color: Color
    }

    private func tr(_ chinese: String, _ english: String) -> String {
        language == .english ? english : chinese
    }

    private var sources: [Metric] {
        switch flow.mode {
        case .battery:
            return [Metric(id: "batterySource", label: tr("电池", "Battery"),
                           watts: flow.batteryWatts.map { abs($0) }, kind: .batterySource)]
        case .adapter, .charging:
            return [Metric(id: "adapter", label: tr("适配器", "Adapter"),
                           watts: flow.adapterWatts, kind: .adapter)]
        case .assisted:
            return [
                Metric(id: "adapter", label: tr("适配器", "Adapter"),
                       watts: flow.adapterWatts, kind: .adapter),
                Metric(id: "batterySource", label: tr("电池", "Battery"),
                       watts: flow.batteryWatts.map { abs($0) }, kind: .batterySource)
            ]
        case .unavailable: return []
        }
    }

    private var destinations: [Metric] {
        switch flow.mode {
        case .battery, .adapter, .assisted:
            return [Metric(id: "system", label: tr("系统", "System"),
                           watts: flow.systemWatts, kind: .system)]
        case .charging:
            return [
                Metric(id: "system", label: tr("系统", "System"),
                       watts: flow.systemWatts, kind: .system),
                Metric(id: "batteryCharge", label: tr("电池充电", "Charging"),
                       watts: flow.batteryWatts, kind: .batteryCharge)
            ]
        case .unavailable: return []
        }
    }

    private var chartHeight: CGFloat {
        flow.mode == .charging || flow.mode == .assisted ? dualHeight : singleHeight
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(tr("供电详情", "Power Flow"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(style.primaryText)
                Spacer(minLength: 6)
                MauLeafPowerStatusBadge(mode: flow.mode, language: language)
            }

            if flow.mode == .unavailable {
                Text(tr("暂时无法读取供电数据", "Power data unavailable"))
                    .font(.caption)
                    .foregroundStyle(style.secondaryText)
                    .frame(maxWidth: .infinity)
                    .frame(height: 60)
            } else {
                GeometryReader { geometry in
                    let width = geometry.size.width
                    let left = frames(for: sources, x: 0,
                                      width: sourceWidth, height: chartHeight)
                    let right = frames(for: destinations, x: width - targetWidth,
                                       width: targetWidth, height: chartHeight)
                    let bands = makeBands(left: left, right: right)

                    ZStack(alignment: .topLeading) {
                        // A band meets a node's rounded rim without showing
                        // through that node's translucent interior.
                        ZStack(alignment: .topLeading) {
                            ForEach(bands) { band in
                                bandPath(band)
                                    .fill(LinearGradient(
                                        colors: [band.color.opacity(style.bandStartOpacity),
                                                 band.color.opacity(style.bandEndOpacity)],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    ))
                            }
                        }
                        .frame(width: width, height: chartHeight)
                        .mask {
                            PowerFlowCardCutout(frames: left + right,
                                                radius: cornerRadius)
                                .fill(style: FillStyle(eoFill: true))
                        }

                        ForEach(sources.indices, id: \.self) { index in
                            node(sources[index], isSource: true,
                                 height: left[index].height)
                                .frame(width: left[index].width,
                                       height: left[index].height)
                                .position(x: left[index].midX, y: left[index].midY)
                        }
                        ForEach(destinations.indices, id: \.self) { index in
                            node(destinations[index], isSource: false,
                                 height: right[index].height)
                                .frame(width: right[index].width,
                                       height: right[index].height)
                                .position(x: right[index].midX, y: right[index].midY)
                        }
                    }
                    .frame(width: width, height: chartHeight)
                }
                .frame(height: chartHeight)
            }
        }
        .padding(.horizontal, 2)
        .padding(.top, 4)
        .padding(.bottom, 11)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    // Row height is proportional only when both readings are trustworthy.
    // Missing readings get equal-height cards for layout, but NO fake ribbons.
    private func frames(for metrics: [Metric], x: CGFloat,
                        width: CGFloat, height: CGFloat) -> [CGRect] {
        guard !metrics.isEmpty else { return [] }
        if metrics.count == 1 {
            return [CGRect(x: x, y: (height - singleHeight) / 2,
                           width: width, height: singleHeight)]
        }
        let shares = Self.fractions(metrics.map(\.watts))
        let first = 28 + 42 * CGFloat(shares?.first ?? 0.5)
        let second = 28 + 42 * CGFloat(shares?.last ?? 0.5)
        let top = (height - first - second - branchGap) / 2
        return [
            CGRect(x: x, y: top, width: width, height: first),
            CGRect(x: x, y: top + first + branchGap,
                   width: width, height: second)
        ]
    }

    // Pure layout-policy helper: do not create proportions from nil, NaN,
    // negative or zero-total samples.
    static func fractions(_ watts: [Double?]) -> [Double]? {
        let values = watts.compactMap { $0 }
        guard !values.isEmpty, values.count == watts.count,
              values.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
        let total = values.reduce(0, +)
        guard total > 0 else { return nil }
        return values.map { $0 / total }
    }

    private func makeBands(left: [CGRect], right: [CGRect]) -> [Band] {
        guard !left.isEmpty, !right.isEmpty else { return [] }
        let startX = left[0].maxX - overlap
        let endX = right[0].minX + overlap
        guard endX > startX else { return [] }

        if left.count == 1 && right.count == 1 {
            guard let source = sources.first?.watts, source > 0,
                  let target = destinations.first?.watts, target > 0 else { return [] }
            return [Band(id: 0, start: CGPoint(x: startX, y: left[0].midY),
                         end: CGPoint(x: endX, y: right[0].midY),
                         startThickness: 22, endThickness: 22,
                         color: style.band(sources[0].kind == .batterySource ? .batterySource : .system))]
        }

        // Adapter -> system + battery charging.
        if left.count == 1 && right.count == 2 {
            guard let input = sources.first?.watts, input > 0,
                  let shares = Self.fractions(destinations.map(\.watts)) else { return [] }
            let total = destinations.compactMap(\.watts).reduce(0, +)
            guard abs(total - input) < 1 else { return [] }
            var offset = left[0].midY - 27
            return shares.enumerated().compactMap { index, fraction in
                guard fraction > 0 else { return nil }
                let thickness = 54 * CGFloat(fraction)
                let start = CGPoint(x: startX, y: offset + thickness / 2)
                offset += thickness
                return Band(id: index, start: start,
                            end: CGPoint(x: endX, y: right[index].midY),
                            startThickness: thickness,
                            endThickness: min(thickness, right[index].height - 8),
                            color: style.band(destinations[index].kind.role))
            }
        }

        // Adapter + discharging battery -> system.
        if left.count == 2 && right.count == 1 {
            guard let output = destinations.first?.watts, output > 0,
                  let shares = Self.fractions(sources.map(\.watts)) else { return [] }
            let total = sources.compactMap(\.watts).reduce(0, +)
            guard abs(total - output) < 1 else { return [] }
            var offset = right[0].midY - 27
            return shares.enumerated().compactMap { index, fraction in
                guard fraction > 0 else { return nil }
                let thickness = 54 * CGFloat(fraction)
                let end = CGPoint(x: endX, y: offset + thickness / 2)
                offset += thickness
                return Band(id: index,
                            start: CGPoint(x: startX, y: left[index].midY),
                            end: end,
                            startThickness: min(thickness, left[index].height - 8),
                            endThickness: thickness,
                            color: style.band(sources[index].kind == .adapter ? .system : .batterySource))
            }
        }
        return []
    }

    private func bandPath(_ band: Band) -> Path {
        let bend = (band.end.x - band.start.x) * 0.5
        var path = Path()
        path.move(to: CGPoint(x: band.start.x,
                              y: band.start.y - band.startThickness / 2))
        path.addCurve(to: CGPoint(x: band.end.x,
                                  y: band.end.y - band.endThickness / 2),
                      control1: CGPoint(x: band.start.x + bend,
                                        y: band.start.y - band.startThickness / 2),
                      control2: CGPoint(x: band.end.x - bend,
                                        y: band.end.y - band.endThickness / 2))
        path.addLine(to: CGPoint(x: band.end.x,
                                 y: band.end.y + band.endThickness / 2))
        path.addCurve(to: CGPoint(x: band.start.x,
                                  y: band.start.y + band.startThickness / 2),
                      control1: CGPoint(x: band.end.x - bend,
                                        y: band.end.y + band.endThickness / 2),
                      control2: CGPoint(x: band.start.x + bend,
                                        y: band.start.y + band.startThickness / 2))
        path.closeSubpath()
        return path
    }

    private func node(_ metric: Metric, isSource: Bool, height: CGFloat) -> some View {
        let compact = height < 39
        let fill = style.fill(metric.kind.role)
        let rim = style.rim(metric.kind.role)

        return Group {
            if isSource && !compact {
                VStack(spacing: 3) {
                    Image(systemName: metric.kind.symbol)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(style.icon(metric.kind.role))
                    Text(MauLeafPowerFlow.display(metric.watts))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    Text(metric.label)
                        .font(.system(size: 9))
                        .foregroundStyle(style.secondaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            } else if compact {
                HStack(spacing: 3) {
                    Image(systemName: metric.kind.symbol)
                        .font(.system(size: 10))
                        .foregroundStyle(style.icon(metric.kind.role))
                    Text(MauLeafPowerFlow.display(metric.watts))
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            } else {
                VStack(spacing: 2) {
                    HStack(spacing: 5) {
                        Image(systemName: metric.kind.symbol)
                            .font(.system(size: 12))
                            .foregroundStyle(style.icon(metric.kind.role))
                        Text(MauLeafPowerFlow.display(metric.watts))
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)
                    }
                    Text(metric.label)
                        .font(.system(size: 10))
                        .foregroundStyle(style.secondaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
        }
        .foregroundStyle(style.primaryText)
        .padding(.horizontal, compact ? 5 : 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: cornerRadius).fill(fill))
        .overlay(RoundedRectangle(cornerRadius: cornerRadius)
            .stroke(rim, lineWidth: 0.75))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(metric.label)，\(MauLeafPowerFlow.display(metric.watts))")
    }

    private var accessibilityDescription: String {
        let entries = (sources + destinations).map {
            "\($0.label) \(MauLeafPowerFlow.display($0.watts))"
        }
        return ([tr("供电详情", "Power Flow"),
                 MauLeafPowerStatusBadge.title(for: flow.mode, language: language)] + entries)
            .joined(separator: "，")
    }
}

// Even-odd mask removes the ribbon under each translucent rounded node.
private struct PowerFlowCardCutout: Shape {
    let frames: [CGRect]
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        for frame in frames {
            path.addPath(RoundedRectangle(cornerRadius: radius).path(in: frame))
        }
        return path
    }
}
