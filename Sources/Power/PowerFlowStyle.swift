import SwiftUI

/// Color-only tokens. No sizing, geometry, symbol or power sampling policy.
struct PowerFlowStyle {
    enum Role: CaseIterable { case adapter, batterySource, batteryCharge, system }
    let scheme: ColorScheme
    private var dark: Bool { scheme == .dark }

    private func color(_ hex: UInt32) -> Color {
        Color(.sRGB, red: Double((hex >> 16) & 255) / 255,
              green: Double((hex >> 8) & 255) / 255,
              blue: Double(hex & 255) / 255, opacity: 1)
    }

    var primaryText: Color { color(dark ? 0xF4F4F5 : 0x202124) }
    var secondaryText: Color { color(dark ? 0xC7C9CE : 0x4D535D) }
    var badgeFill: Color { color(dark ? 0x373737 : 0xE7E9EB) }
    var bandStartOpacity: Double { dark ? 0.40 : 0.75 }
    var bandEndOpacity: Double { dark ? 0.76 : 0.95 }

    func fill(_ role: Role) -> Color {
        switch role {
        case .adapter: return color(dark ? 0x41464D : 0xE5EAF0)
        case .batterySource: return color(dark ? 0x47382C : 0xF7E8D7)
        case .batteryCharge: return color(dark ? 0x263E30 : 0xE0F0E4)
        case .system: return color(dark ? 0x303049 : 0xE9E8F5)
        }
    }

    func rim(_ role: Role) -> Color {
        switch role {
        case .adapter: return color(dark ? 0x697580 : 0x7A8594)
        case .batterySource: return color(dark ? 0x9C7048 : 0xA2662E)
        case .batteryCharge: return color(dark ? 0x548363 : 0x548364)
        case .system: return color(dark ? 0x65669A : 0x7976AA)
        }
    }

    func icon(_ role: Role) -> Color {
        switch role {
        case .adapter: return color(dark ? 0xE4E8ED : 0x394554)
        case .batterySource: return color(dark ? 0xF3B46C : 0x984B11)
        case .batteryCharge: return color(dark ? 0x7DDC99 : 0x166534)
        case .system: return color(dark ? 0xA8A5EF : 0x4D4788)
        }
    }

    func band(_ role: Role) -> Color {
        switch role {
        case .adapter, .system: return color(dark ? 0x8078D7 : 0x5750A3)
        case .batterySource: return color(dark ? 0xD38A45 : 0xA45D1B)
        case .batteryCharge: return color(dark ? 0x58B278 : 0x31804D)
        }
    }

    func status(_ mode: MauLeafPowerFlow.Mode) -> Color {
        switch mode {
        case .battery, .assisted: return icon(.batterySource)
        case .adapter, .charging: return color(dark ? 0x30D158 : 0x166534)
        case .unavailable: return secondaryText
        }
    }
}
