import Foundation

@main
private enum BatteryStatusReaderTests {
    static func main() throws {
        let charging = try snapshot([
            "CurrentCapacity": 4_800,
            "MaxCapacity": 6_000,
            "IsCharging": true,
            "FullyCharged": false,
            "ExternalConnected": true,
            "Amperage": 420
        ])
        expect(charging.percent == 80, "capacity ratio is converted to a percentage")
        expect(charging.isCharging && !charging.isFullyCharged, "charging state is preserved")
        expect(charging.isACConnected == true, "AC connection is preserved")
        expect(charging.amperageMilliAmps == 420, "battery current is parsed when available")

        let full = try snapshot([
            "CurrentCapacity": 6_000,
            "MaxCapacity": 6_000,
            "IsCharging": false,
            "FullyCharged": true,
            "ExternalConnected": true
        ])
        expect(full.percent == 100 && full.isFullyCharged, "fully charged state is recognized")

        let unplugged = try snapshot([
            "CurrentCapacity": 3_000,
            "MaxCapacity": 6_000,
            "IsCharging": false,
            "ExternalConnected": false,
            "Amperage": -360
        ])
        expect(unplugged.percent == 50 && unplugged.isACConnected == false, "battery power is recognized")
        expect(unplugged.amperageMilliAmps == -360, "signed negative current is retained")
        let native = MauLeafBatteryStatusReader.parseProperties([
            "CurrentCapacity": 3_000, "MaxCapacity": 6_000,
            "IsCharging": false, "ExternalConnected": false, "Amperage": -360
        ])
        expect(native == unplugged,
               "native IORegistry dictionary and ioreg plist path yield identical battery state")
        let replugged = MauLeafBatteryStatusReader.parseProperties([
            "CurrentCapacity": 3_000, "MaxCapacity": 6_000,
            "IsCharging": true, "ExternalConnected": true, "Amperage": 250
        ])
        expect(replugged.isACConnected == true && replugged.isCharging,
               "native dictionary recognizes a fresh external-power connection")

        let precise = MauLeafBatteryStatusReader.parseProperties([
            "CurrentCapacity": 95, "MaxCapacity": 100,
            "AppleRawCurrentCapacity": 4770, "AppleRawMaxCapacity": 5000,
            "IsCharging": false, "ExternalConnected": true
        ])
        expect(precise.precisePercent.map { abs($0 - 95.4) < 0.001 } == true,
               "raw capacities supply fractional SoC for dynamic hold")
        expect(charging.precisePercent == nil,
               "missing raw SoC stays unknown instead of guessing from UI percent")
        let power = MauLeafBatteryStatusReader.parseProperties([
            "CurrentCapacity": 4800, "MaxCapacity": 6000,
            "IsCharging": true, "ExternalConnected": true,
            "Voltage": 12000, "Amperage": 700,
            "PowerTelemetryData": [
                "SystemPowerIn": 27000, "SystemLoad": 18600
            ],
            "AdapterDetails": ["Watts": 140]
        ])
        expect(abs((power.batteryPowerWatts ?? 0) - 8.4) < 0.001,
               "battery current mA and voltage mV yield signed battery watts")
        expect(power.adapterInputWatts == 27.0 && power.systemLoadWatts == 18.6,
               "adapter input and system load are parsed from telemetry mW")
        expect(power.adapterInputWatts != 140,
               "adapter rated maximum must never masquerade as live power draw")
        let unpluggedPower = MauLeafBatteryStatusReader.parseProperties([
            "CurrentCapacity": 2500, "MaxCapacity": 6000,
            "IsCharging": false, "ExternalConnected": false,
            "Voltage": 12000, "InstantAmperage": -500,
            "PowerTelemetryData": ["SystemPowerIn": 12000]
        ])
        expect(unpluggedPower.batteryPowerWatts == -6.0
               && unpluggedPower.adapterInputWatts == nil,
               "disconnected state ignores stale adapter watts and preserves signed discharge")
        let invalidPower = MauLeafBatteryStatusReader.parseProperties([
            "ExternalConnected": true, "Voltage": 0,
            "Amperage": -400, "PowerTelemetryData": ["SystemPowerIn": -1000]
        ])
        expect(invalidPower.batteryPowerWatts == nil
               && invalidPower.adapterInputWatts == nil,
               "invalid telemetry is missing rather than rendered as negative or false power")
        let missing = MauLeafBatteryStatusReader.parse(Data("invalid".utf8))
        expect(missing.percent == nil && missing.isACConnected == nil, "invalid IORegistry output is unknown, never assumed to be AC")

        print("BatteryStatusReaderTests: PASS")
    }

    private static func snapshot(_ row: [String: Any]) throws -> MauLeafBatterySnapshot {
        let data = try PropertyListSerialization.data(fromPropertyList: [row], format: .xml, options: 0)
        return MauLeafBatteryStatusReader.parse(data)
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }
}
