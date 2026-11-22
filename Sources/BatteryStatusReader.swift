import Foundation

struct MauLeafBatterySnapshot: Equatable {
    let percent: Int?
    let isCharging: Bool
    let isFullyCharged: Bool
    let isACConnected: Bool?
    /// Signed battery current (mA), when exposed by AppleSmartBattery.
    /// Negative can indicate discharge; it does not prove wall-power routing.
    let amperageMilliAmps: Int?

    init(percent: Int?, isCharging: Bool, isFullyCharged: Bool,
         isACConnected: Bool?, amperageMilliAmps: Int? = nil) {
        self.percent = percent
        self.isCharging = isCharging
        self.isFullyCharged = isFullyCharged
        self.isACConnected = isACConnected
        self.amperageMilliAmps = amperageMilliAmps
    }
}

enum MauLeafBatteryStatusReader {
    /// Conservative ioreg path retained for the root Helper's power/restore
    /// safety checks. The UI uses a separate fast IOKit reader instead.
    static func read() -> MauLeafBatterySnapshot {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        process.arguments = ["-r", "-c", "AppleSmartBattery", "-a"]
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return unavailable }
            return parse(data)
        } catch {
            return unavailable
        }
    }

    static func parse(_ data: Data) -> MauLeafBatterySnapshot {
        guard let propertyList = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let rows = propertyList as? [[String: Any]],
              let battery = rows.first else {
            return unavailable
        }
        return parseProperties(battery)
    }

    static func parseProperties(_ battery: [String: Any]) -> MauLeafBatterySnapshot {
        let current = integer(battery["CurrentCapacity"])
        let maximum = integer(battery["MaxCapacity"])
        let percent: Int?
        if let current, let maximum, maximum > 0 {
            let value = Int((Double(current) / Double(maximum) * 100).rounded())
            percent = (0...100).contains(value) ? value : nil
        } else {
            percent = nil
        }
        let charging = boolean(battery["IsCharging"]) ?? false
        let fullyCharged = boolean(battery["FullyCharged"]) ?? (percent == 100)
        let external = boolean(battery["ExternalConnected"])
        return MauLeafBatterySnapshot(
            percent: percent,
            isCharging: charging,
            isFullyCharged: fullyCharged,
            isACConnected: external,
            amperageMilliAmps: integer(battery["Amperage"])
        )
    }

    private static var unavailable: MauLeafBatterySnapshot {
        MauLeafBatterySnapshot(percent: nil, isCharging: false, isFullyCharged: false, isACConnected: nil)
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    private static func boolean(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        return nil
    }
}
