import Foundation

enum AppAppearance: String, CaseIterable {
    case light, dark

    static let preferenceKey = "appAppearance"

    static func saved(in defaults: UserDefaults = .standard) -> AppAppearance {
        AppAppearance(rawValue: defaults.string(forKey: preferenceKey) ?? "") ?? .dark
    }

    func save(in defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.preferenceKey)
    }

    func title(in language: AppLanguage) -> String {
        switch self {
        case .light: return language == .english ? "Light" : "浅色"
        case .dark: return language == .english ? "Dark" : "深色"
        }
    }
}
