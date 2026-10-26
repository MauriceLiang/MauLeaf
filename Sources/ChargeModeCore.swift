import Foundation

/// The user chooses between two mutually exclusive charge modes.
enum ChargeMode: String, Codable {
    case limited
    case full
}

enum FullBehavior: String, Codable {
    case once
    case always
}

enum HighChargePolicy: String, Codable {
    case adapter
    case discharge
}

/// Pinned CLI command plan for batt v0.8.0. The documented upstream
/// `charge full` command is NOT registered in this release.
enum BattCommand: Equatable {
    case setLimit(Int)
    case allowFullForever
    case allowFullTemporarily
    case readStatus
    case useAdapter
    case useBatteryTemporarily

    var arguments: [String] {
        switch self {
        case .setLimit(let percent): return ["limit", String(percent)]
        case .allowFullForever: return ["disable"]
        case .allowFullTemporarily: return ["disable", "--for=10h"]
        case .readStatus: return ["status"]
        case .useAdapter: return ["adapter", "enable"]
        case .useBatteryTemporarily: return ["adapter", "disable", "--for=1m"]
        }
    }
}

/// Parse *observed* batt state; never equate the last successful command with
/// hardware state. Does not infer compatibility from the macOS version.
struct BattStatus: Equatable {
    let upperLimit: Int?
    let adapterEnabled: Bool?
    let supportsAdapterControl: Bool?
    let scheduledRestoreLimit: Int?

    static func parse(_ output: String) -> BattStatus {
        // v0.8.0 prints "Upper limit: 80%" while limiting, but switches to
        // "Charge limit: 100% (batt disabled)" after `batt disable`.
        let upper = percentage(after: "Upper limit", in: output)
            ?? percentage(after: "Charge limit", in: output)
        let adapter = checkmark(after: "Use power adapter", in: output)
        let adapterControl = checkmark(after: "Power adapter control", in: output)
        let restore = restorePercentage(in: output)
        return BattStatus(upperLimit: upper, adapterEnabled: adapter,
                          supportsAdapterControl: adapterControl, scheduledRestoreLimit: restore)
    }

    private static func percentage(after key: String, in string: String) -> Int? {
        let escaped = NSRegularExpression.escapedPattern(for: key)
        let pattern = "(?im)^\\s*" + escaped + "\\s*:\\s*(\\d{1,3})\\s*%"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)),
              let range = Range(match.range(at: 1), in: string) else { return nil }
        return Int(string[range])
    }

    private static func restorePercentage(in string: String) -> Int? {
        let pattern = #"(?im)^\s*Restoring\s+(\d{1,3})%\s+limit:"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)),
              let range = Range(match.range(at: 1), in: string) else { return nil }
        return Int(string[range])
    }

    private static func checkmark(after key: String, in string: String) -> Bool? {
        let escaped = NSRegularExpression.escapedPattern(for: key)
        let pattern = "(?im)^\\s*" + escaped + "\\s*:\\s*([^\\r\\n]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)),
              let range = Range(match.range(at: 1), in: string) else { return nil }
        let field = String(string[range]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if field.hasPrefix("✔") || field.hasPrefix("✓") || field.hasPrefix("true") { return true }
        if field.hasPrefix("✘") || field.hasPrefix("✗") || field.hasPrefix("false") { return false }
        return nil
    }
}

struct OnceJob: Codable, Equatable {
    let limit: Int
    let battPath: String
    let expiryUnixSeconds: Double
    let jobID: String
}

enum BatteryPower {
    static func watts(from output: String) -> Double? {
        func number(_ key: String) -> Int64? {
            let pattern = "(?m)^\\s*\"" + key + "\"\\s*=\\s*(-?\\d+)"
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
                  let range = Range(match.range(at: 1), in: output) else { return nil }
            let raw = String(output[range])
            // ioreg can print a negative battery current as its unsigned
            // 64-bit representation. Preserve those bits when restoring sign.
            return Int64(raw) ?? UInt64(raw).map { Int64(bitPattern: $0) }
        }
        return watts(voltage: number("Voltage"), current: number("InstantAmperage") ?? number("Amperage"))
    }

    static func watts(voltage: Int64?, current: Int64?) -> Double? {
        guard let voltage, voltage > 0, let current else { return nil }
        return abs(Double(voltage) * Double(current)) / 1_000_000
    }
}

struct BatteryPowerSample: Equatable, Sendable {
    let percent: Int?
    let externalConnected: Bool?
    let fullyCharged: Bool?
    let isCharging: Bool
    let isDischarging: Bool
    let chargeWatts: Double?
    let dischargeWatts: Double?

    var refreshInterval: TimeInterval { isCharging || isDischarging ? 2 : 5 }

    init(properties: [String: Any]) {
        let capacity = (properties["CurrentCapacity"] as? NSNumber)?.intValue
        percent = capacity.flatMap { (0...100).contains($0) ? $0 : nil }
        externalConnected = (properties["ExternalConnected"] as? NSNumber)?.boolValue
        fullyCharged = (properties["FullyCharged"] as? NSNumber)?.boolValue
        let current = (properties["InstantAmperage"] as? NSNumber)?.int64Value
            ?? (properties["Amperage"] as? NSNumber)?.int64Value
        isDischarging = current.map { $0 < 0 } == true
            || (externalConnected == false && (properties["IsCharging"] as? NSNumber)?.boolValue != true)
        isCharging = !isDischarging && (properties["IsCharging"] as? NSNumber)?.boolValue == true
        let watts = BatteryPower.watts(voltage: (properties["Voltage"] as? NSNumber)?.int64Value, current: current)
        chargeWatts = isCharging ? watts : nil
        dischargeWatts = isDischarging ? watts : nil
    }
}

enum ChargingError: LocalizedError {
    case notInstalled
    case command(String)
    case verification(String)
    case helper(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled: return "找不到 batt 控制程序"
        case .command(let detail): return "batt 执行失败：\(detail.trimmingCharacters(in: .whitespacesAndNewlines))"
        case .verification(let detail): return "状态校验失败：\(detail)"
        case .helper(let detail): return "后台恢复服务不可用：\(detail)"
        }
    }
}
