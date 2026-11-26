import Foundation

struct MauLeafBatterySnapshot: Equatable {
    let percent: Int?
    let isCharging: Bool
    let isFullyCharged: Bool
    let isACConnected: Bool?
    /// Signed battery current (mA), when exposed by AppleSmartBattery.
    /// Negative can indicate discharge; it does not prove wall-power routing.
    let amperageMilliAmps: Int?
    /// Unrounded battery state of charge from raw AppleSmartBattery capacity.
    /// Optional: an unknown value must not authorize an automatic SMC write.
    let precisePercent: Double?
    /// Read-only battery power, positive when charging and negative when
    /// discharging; measured at pack terminals, not adapter wall input.
    let batteryPowerWatts: Double?
    /// SystemPowerIn from AppleSmartBattery.PowerTelemetryData (mW -> W).
    /// NEVER populated from AdapterDetails.Watts, which is a rated maximum.
    let adapterInputWatts: Double?
    /// Telemetry SystemLoad in watts; may lag a connection-state transition.
    let systemLoadWatts: Double?

    init(percent: Int?, isCharging: Bool, isFullyCharged: Bool,
         isACConnected: Bool?, amperageMilliAmps: Int? = nil,
         precisePercent: Double? = nil, batteryPowerWatts: Double? = nil,
         adapterInputWatts: Double? = nil, systemLoadWatts: Double? = nil) {
        self.percent = percent
        self.isCharging = isCharging
        self.isFullyCharged = isFullyCharged
        self.isACConnected = isACConnected
        self.amperageMilliAmps = amperageMilliAmps
        self.precisePercent = precisePercent
        self.batteryPowerWatts = batteryPowerWatts
        self.adapterInputWatts = adapterInputWatts
        self.systemLoadWatts = systemLoadWatts
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
        // Rounded UI percentage is not precise enough for hardware bounds.
        // The raw capacity pair is captured separately and never synthesized
        // from the displayed integer percentage.
        let rawCurrent = integer(battery["AppleRawCurrentCapacity"])
        let rawMaximum = integer(battery["AppleRawMaxCapacity"])
        let precise: Double?
        if let rawCurrent, let rawMaximum, rawMaximum > 0, rawCurrent >= 0 {
            let value = 100.0 * Double(rawCurrent) / Double(rawMaximum)
            precise = value.isFinite && (0...101).contains(value) ? value : nil
        } else {
            precise = nil
        }
        let charging = boolean(battery["IsCharging"]) ?? false
        // Sensor units: current mA × voltage mV / 1,000,000 = W.
        // Some battery drivers only expose Amperage, others expose
        // InstantAmperage. Neither is a wall-adapter power measurement.
        let amperage = integer(battery["Amperage"])
            ?? integer(battery["InstantAmperage"])
        let voltage = integer(battery["Voltage"])
        let batteryWatts: Double?
        if let amperage, let voltage, (6_000...30_000).contains(voltage),
           (-30_000...30_000).contains(amperage) {
            batteryWatts = Double(amperage) * Double(voltage) / 1_000_000
        } else {
            batteryWatts = nil
        }
        let telemetry = battery["PowerTelemetryData"] as? [String: Any]
        func telemetryWatts(_ key: String) -> Double? {
            guard let raw = integer(telemetry?[key]), (0...250_000).contains(raw) else {
                return nil
            }
            return Double(raw) / 1_000
        }
        let powerIn = telemetryWatts("SystemPowerIn")
        let systemLoad = telemetryWatts("SystemLoad")
        let fullyCharged = boolean(battery["FullyCharged"]) ?? (percent == 100)
        let external = boolean(battery["ExternalConnected"])
        return MauLeafBatterySnapshot(
            percent: percent,
            isCharging: charging,
            isFullyCharged: fullyCharged,
            isACConnected: external,
            amperageMilliAmps: amperage,
            precisePercent: precise,
            batteryPowerWatts: batteryWatts,
            adapterInputWatts: external == true ? powerIn : nil,
            systemLoadWatts: systemLoad
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
