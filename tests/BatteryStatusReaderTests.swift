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
