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
