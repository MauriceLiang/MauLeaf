import SwiftUI

/// Only the light-mode charging accent is overridden. Preserve the original
/// SwiftUI system green in dark mode and the independent menu-bar icon tint.
enum AppTheme {
    static func chargeGreen(in scheme: ColorScheme) -> Color {
        if scheme == .dark { return .green }
        return Color(.sRGB, red: 22.0 / 255, green: 101.0 / 255, blue: 52.0 / 255, opacity: 1)
    }
}
