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
        check(AppText(key: "正在充电").localized(in: .english) == "Charging", "battery status label")
        check(AppText(key: "已接电源，未充电").localized(in: .english) == "Connected to power, not charging",
              "adapter idle status is translated")
        check(AppText(key: "unknown detail").localized(in: .english) == "unknown detail",
              "unknown diagnostics are preserved")
        check(translations["退出时是否保留控制组件？"] == "Keep the native control components when quitting?",
              "native quit question has an English translation")
        check(translations["保留组件并退出"] == "Keep components and quit"
              && translations["移除组件并退出"] == "Remove components and quit",
              "both quit component lifecycle choices have bilingual labels")
        check(translations["固件已恢复，但后台组件未处理完成"] != nil,
              "component cleanup failure is distinguished from unverified firmware")
        // Native privileged helper responses are English technical audit
        // strings. The UI must use a short translated message, not that raw
        // response, in either language. Check all four user actions.
        let confirmation: AppText = "充电上限已设为 \(85)%，固件写入已验证。"
        check(confirmation.source == "充电上限已设为 85%，固件写入已验证。"
              && confirmation.localized(in: .english) == "Charging limit set to 85%. Firmware write verified.",
              "successful limit write is localizable with a numeric threshold")
        for key in [
            "已恢复启用前的原始固件配置。",
            "已关闭限制充电，原始固件配置已恢复。",
            "已关闭旧版限充，历史阈值未知。",
            "限充未启用，已核对固件状态。",
            "已请求取消本次充满，等待恢复充电上限。",
            "已取消本次充满，原充电上限已恢复。",
            "本次充满已开启，固件限充暂时关闭。"
        ] {
            check(chinese[key] == key
                  && translations[key] != nil
                  && translations[key] != key,
                  "native operation success has distinct Chinese and English translations: \(key)")
        }


        let activeLimit: AppText = "已启用 · \(85)%"
        check(activeLimit.source == "已启用 · 85%"
              && activeLimit.localized(in: .english) == "On · 85%",
              "active compact status badge localizes numeric charge limit")
        let pausedLimit: AppText = "已暂停 · \(85)%"
        check(pausedLimit.localized(in: .english) == "Paused · 85%",
              "one-time charge temporarily pauses rather than disables configured limit")
        for key in ["供电状态", "限制充电", "本次充满", "取消本次充满", "设置", "退出 MauLeaf",
                    "界面语言", "正在恢复", "恢复任务仍在等待；请先恢复原始配置。"] {
            check(chinese[key] == key && translations[key] != nil,
                  "compact popover label is available in both languages: \(key)")
        }
        check(translations["取消本次充满"] == "Cancel one-time full charge",
              "direct card cancellation hint follows selected language")
        check(translations["显示当前电量"] == "Show battery level"
              && translations["在顶部卡片中显示当前电量百分比"] == "Show the battery percentage in the overview card"
              && chinese["显示当前电量"] == "显示当前电量",
              "optional battery setting is fully localized")
        for key in ["退出时移除组件", "开启后每次退出会移除控制组件；关闭则保留。",
                    "建议卸载前开启，退出并确认清理完成后再删除 App。",
                    "高于目标时保持电量；关闭后在已测试机型上可能出现拔电识别延迟",
                    "超限时保持电量；关闭后拔电识别可能延迟（已测试机型）。"] {
            check(chinese[key] == key && translations[key] != nil && translations[key] != key,
                  "quit policy and Dynamic Hold warning localize in both languages: \(key)")
        }
        check(translations["目标 %@%% · 临时上限 %@%%"] != nil
              && translations["动态保电已应用：目标 %@%%，临时上限 %@%%。"] != nil,
              "Dynamic Hold retains concise localized numeric ceilings")
        check(chinese["关闭后保留供电状态，仅隐藏供电流向图"] == "关闭后保留供电状态，仅隐藏供电流向图"
              && translations["关闭后保留供电状态，仅隐藏供电流向图"] == "When disabled, keep the power status visible and hide only the flow diagram.",
              "power details setting clearly explains that the compact status remains")
        check(translations["退出 MauLeaf"] == "Quit MauLeaf"
              && translations["供电状态"] == "Power"
              && translations["限制充电"] == "Charge limit"
              && translations["本次充满"] == "Full charge",
              "English card titles are shortened without reducing the panel font")
        for (key, expected) in [
            ("充电中", "Charging"),
            ("已接电源", "Plugged in"),
            ("已充满", "Fully charged"),
            ("电池供电", "On battery"),
            ("读取中…", "Loading…"),
            ("未启用", "Off"),
            ("进行中", "Active")
        ] {
            check(translations[key] == expected && chinese[key] == key,
                  "compact status remains bilingual: \(key)")
        }

        print("LocalizationTests: PASS (\(checks) checks; real bundled string tables)")
    }
}
