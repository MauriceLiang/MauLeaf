import Foundation

enum AppLanguage: String, CaseIterable {
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    static let preferenceKey = "appLanguage"

    static func saved(in defaults: UserDefaults = .standard) -> AppLanguage {
        AppLanguage(rawValue: defaults.string(forKey: preferenceKey) ?? "") ?? .simplifiedChinese
    }

    var other: AppLanguage { self == .english ? .simplifiedChinese : .english }
    var switchTitle: String { self == .english ? "中文" : "English" }
}

/// Keep the message and its arguments separate so existing feedback can be
/// rendered in either language without repeating a charging operation.
struct AppText: ExpressibleByStringLiteral, ExpressibleByStringInterpolation, Hashable {
    let key: String
    private var arguments: [AppText] = []
    private var verbatim = false

    init(stringLiteral value: String) { key = value }
    init(key: String) { self.key = key }
    init(verbatim value: String) { key = value; verbatim = true }
    init(stringInterpolation: StringInterpolation) {
        key = stringInterpolation.key
        arguments = stringInterpolation.arguments
    }

    struct StringInterpolation: StringInterpolationProtocol {
        var key = ""
        var arguments: [AppText] = []

        init(literalCapacity: Int, interpolationCount: Int) {
            key.reserveCapacity(literalCapacity)
            arguments.reserveCapacity(interpolationCount)
        }

        mutating func appendLiteral(_ value: String) {
            key += value.replacingOccurrences(of: "%", with: "%%")
        }

        mutating func appendInterpolation(_ value: AppText) {
            key += "%@"
            arguments.append(value)
        }

        mutating func appendInterpolation<T>(_ value: T) {
            appendInterpolation(AppText(verbatim: String(describing: value)))
        }
    }

    var source: String { localized(in: .simplifiedChinese) }

    func localized(in language: AppLanguage, bundle: Bundle = .main) -> String {
        var format = key
        if !verbatim, language == .english,
           let path = bundle.path(forResource: language.rawValue, ofType: "lproj"),
           let localizedBundle = Bundle(path: path) {
            format = localizedBundle.localizedString(forKey: key, value: key, table: nil)
        }
        guard !arguments.isEmpty else { return format }
        return String(format: format, arguments: arguments.map { $0.localized(in: language, bundle: bundle) as CVarArg })
    }

    init(error: Error) {
        guard let charging = error as? ChargingError else {
            self.init(key: error.localizedDescription)
            return
        }
        switch charging {
        case .notInstalled: self = "找不到 batt 控制程序"
        case .command(let detail): self = "batt 执行失败：\(AppText(verbatim: detail.trimmingCharacters(in: .whitespacesAndNewlines)))"
        case .verification(let detail): self = "状态校验失败：\(detail)"
        case .helper(let detail): self = "后台恢复服务不可用：\(detail)"
        }
    }
}
