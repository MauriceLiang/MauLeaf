import Foundation

enum AppAppearance: String, CaseIterable {
    case system, light, dark

    static let preferenceKey = "appAppearance"

    static func saved(in defaults: UserDefaults = .standard) -> AppAppearance {
        AppAppearance(rawValue: defaults.string(forKey: preferenceKey) ?? "") ?? .system
    }

    func save(in defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.preferenceKey)
    }

    func title(in language: AppLanguage) -> String {
        switch self {
        case .system: return language == .english ? "System" : "跟随系统"
        case .light: return language == .english ? "Light" : "浅色"
        case .dark: return language == .english ? "Dark" : "深色"
        }
    }
}
