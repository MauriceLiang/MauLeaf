import Foundation

@main
struct LocalizationTests {
    static var checks = 0

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    static func main() throws {
        let suite = "MauLeafLocalizationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        check(AppLanguage.saved(in: defaults) == .simplifiedChinese, "existing users keep Chinese by default")
        defaults.set("invalid", forKey: AppLanguage.preferenceKey)
        check(AppLanguage.saved(in: defaults) == .simplifiedChinese, "invalid preference falls back to Chinese")
        defaults.set("en", forKey: AppLanguage.preferenceKey)
        check(AppLanguage.saved(in: defaults) == .english, "English preference is restored")
        check(AppLanguage.english.other == .simplifiedChinese && AppLanguage.simplifiedChinese.other == .english,
              "one click switches in either direction")
        check(AppLanguage.english.switchTitle == "中文" && AppLanguage.simplifiedChinese.switchTitle == "English",
              "button names its target language")

        guard let path = Bundle.main.path(forResource: "en", ofType: "lproj") else {
            fatalError("Test runner must copy the real localization resources alongside its executables")
        }
        let translations = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: URL(fileURLWithPath: path).appendingPathComponent("Localizable.strings")),
            format: nil
        ) as! [String: String]
        let chinesePath = Bundle.main.path(forResource: "zh-Hans", ofType: "lproj")!
        let chinese = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: URL(fileURLWithPath: chinesePath).appendingPathComponent("Localizable.strings")),
            format: nil
        ) as! [String: String]
        check(Set(translations.keys) == Set(chinese.keys), "Chinese and English resources cover the same messages")
        let placeholder = try NSRegularExpression(pattern: "%@")
        for (key, value) in translations {
            let count = { (text: String) in placeholder.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text)) }
            check(count(key) == count(value), "translation preserves interpolation arguments: \(key)")
            check(!value.isEmpty, "translation is not empty: \(key)")
        }

        let limit: AppText = "原生固件限充至 \(85)%"
        check(limit.source == "原生固件限充至 85%", "Chinese interpolation preserves the percent sign")
        check(limit.localized(in: .english) == "Native firmware limit: 85%", "English native firmware status")
        let failure = AppText(error: NSError(domain: "Fixture", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "fixture native write failure"]))
        let nested: AppText = "原生控制失败：\(failure)"
        check(nested.localized(in: .english) == "Native control failed: fixture native write failure",
              "native helper errors remain visible in English")
        check(translations["启用原生固件控制？"] == "Enable native firmware control?",
              "hardware write consent has an English string-table entry")
        let tooltipFormat = translations["%@，正在充电"]
        check(tooltipFormat == "Battery %@, charging", "menu bar tooltip has an English string-table entry")
        check(tooltipFormat!.contains("%@"), "menu bar tooltip keeps its nested battery argument")
        check(AppText(key: "正在充电").localized(in: .english) == "Charging", "battery status label")
        check(AppText(key: "已接电源，未充电").localized(in: .english) == "Connected to power, not charging",
              "adapter idle status is translated")
        check(AppText(key: "unknown detail").localized(in: .english) == "unknown detail",
              "unknown diagnostics are preserved")
        print("LocalizationTests: PASS (\(checks) checks; real bundled string tables)")
    }
}
