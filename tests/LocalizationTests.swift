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
        let translations = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: path).appendingPathComponent("Localizable.strings")), format: nil) as! [String: String]
        let chinesePath = Bundle.main.path(forResource: "zh-Hans", ofType: "lproj")!
        let chinese = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: chinesePath).appendingPathComponent("Localizable.strings")), format: nil) as! [String: String]
        check(Set(translations.keys) == Set(chinese.keys), "Chinese and English resources cover the same messages")
        let placeholder = try NSRegularExpression(pattern: "%@")
        for (key, value) in translations {
            let count = { (text: String) in placeholder.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text)) }
            check(count(key) == count(value), "translation preserves interpolation arguments: \(key)")
            check(!value.isEmpty, "translation is not empty: \(key)")
        }
        let limit: AppText = "限充至 \(85)%"
        check(limit.source == "限充至 85%", "Chinese interpolation preserves the percent sign")
        check(limit.localized(in: .english) == "Charge limit: 85%", "English interpolated limit")
        let nested: AppText = "应用失败：\(AppText(error: ChargingError.verification("未确认适配器供电已恢复")))"
        check(nested.localized(in: .english) == "Could not apply: Status verification failed: Could not confirm adapter power restoration.",
              "nested app error switches languages without losing its detail")
        check(nested.source == "应用失败：状态校验失败：未确认适配器供电已恢复", "source diagnostic remains unchanged")
        let command = AppText(error: ChargingError.command("fixture: permission denied\n"))
        check(command.localized(in: .english) == "batt command failed: fixture: permission denied", "CLI diagnostics stay intact")
        check(AppText(key: "unknown detail").localized(in: .english) == "unknown detail", "unknown diagnostics are preserved")
        let level: AppText = "电量 \(75)%"
        let tooltip: AppText = "\(level)，正在充电"
        check(tooltip.localized(in: .english) == "Battery 75%, charging", "nested menu bar tooltip")
        check(AppText(key: "正在充电").localized(in: .english) == "Charging", "battery status label")
        check(AppText(key: "已合盖，已停止主动降电量").localized(in: .english).contains("lid is closed"),
              "persisted safety messages are translated")
        print("LocalizationTests: PASS (\(checks) checks; real bundled string tables)")
    }

}
