import SwiftUI

/// Color-only tokens. No sizing, geometry, symbol or power sampling policy.
struct PowerFlowStyle {
    enum Role: CaseIterable { case adapter, batterySource, batteryCharge, system }

    private func color(_ hex: UInt32) -> Color {
        Color(.sRGB, red: Double((hex >> 16) & 255) / 255,
              green: Double((hex >> 8) & 255) / 255,
              blue: Double(hex & 255) / 255, opacity: 1)
    }

    var primaryText: Color { color(0xF4F4F5) }
    var secondaryText: Color { color(0xC7C9CE) }
    var badgeFill: Color { color(0x373737) }
    var bandStartOpacity: Double { 0.40 }
    var bandEndOpacity: Double { 0.76 }

    func fill(_ role: Role) -> Color {
        switch role {
        case .adapter: return color(0x41464D)
        case .batterySource: return color(0x47382C)
        case .batteryCharge: return color(0x263E30)
        case .system: return color(0x303049)
        }
    }

    func rim(_ role: Role) -> Color {
        switch role {
        case .adapter: return color(0x697580)
        case .batterySource: return color(0x9C7048)
        case .batteryCharge: return color(0x548363)
        case .system: return color(0x65669A)
        }
    }

    func icon(_ role: Role) -> Color {
        switch role {
        case .adapter: return color(0xE4E8ED)
        case .batterySource: return color(0xF3B46C)
        case .batteryCharge: return color(0x7DDC99)
        case .system: return color(0xA8A5EF)
        }
    }

    func band(_ role: Role) -> Color {
        switch role {
        case .adapter, .system: return color(0x8078D7)
        case .batterySource: return color(0xD38A45)
        case .batteryCharge: return color(0x58B278)
        }
    }

    func status(_ mode: MauLeafPowerFlow.Mode) -> Color {
        switch mode {
        case .battery, .assisted: return icon(.batterySource)
        case .adapter, .charging: return color(0x30D158)
        case .unavailable: return secondaryText
        }
    }
}
