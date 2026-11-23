import Foundation
import IOKit

/// Display-only power sampler, inspired by Status Trio's SystemPowerReader
/// and SMCReadOnlyClient (Apache-2.0, github.com/lingyired/status-trio).
/// Reads fixed AppleSMC sensor keys PDTR/B0AC/B0AV only (commands 9 and 5).
/// Never enumerates keys, writes firmware, opens the privileged Helper, or
/// changes charging state. Missing sensors fall back to AppleSmartBattery.
enum MauLeafLivePowerReader {
    private struct Rails {
        let adapterWatts: Double?
        let batteryWatts: Double?
    }

    static func read() -> MauLeafPowerFlow {
        let battery = MauLeafFastBatteryReader.read()
        guard let rails = readSMC() else {
            return MauLeafPowerFlow(snapshot: battery)
        }
        let batteryWatts = rails.batteryWatts ?? battery.batteryPowerWatts
        let adapterWatts = battery.isACConnected == true
            ? (rails.adapterWatts ?? battery.adapterInputWatts) : nil
        let snapshot = MauLeafBatterySnapshot(
            percent: battery.percent,
            isCharging: battery.isCharging || (battery.isACConnected == true
                && (batteryWatts ?? 0) > 0.3),
            isFullyCharged: battery.isFullyCharged,
            isACConnected: battery.isACConnected,
            amperageMilliAmps: battery.amperageMilliAmps,
            precisePercent: battery.precisePercent,
            batteryPowerWatts: batteryWatts,
            adapterInputWatts: adapterWatts,
            systemLoadWatts: battery.systemLoadWatts
        )
        return MauLeafPowerFlow(snapshot: snapshot)
    }

    /// A single short-lived read-only SMC connection per 2-second refresh.
    private static func readSMC() -> Rails? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("AppleSMC")
        )
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }

        var connection: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS
        else { return nil }
        defer { IOServiceClose(connection) }

        func exchange(_ request: [UInt8]) -> [UInt8]? {
            // The app is read-only: only get-key-info or read-key.
            guard request.count == 80, request[42] == 9 || request[42] == 5
            else { return nil }
            var output = [UInt8](repeating: 0, count: 80)
            var size = output.count
            let result = request.withUnsafeBytes { input in
                output.withUnsafeMutableBytes { response in
                    IOConnectCallStructMethod(
                        connection, 2, input.baseAddress, input.count,
                        response.baseAddress, &size
                    )
                }
            }
            guard result == KERN_SUCCESS, size == 80 else { return nil }
            return output
        }

        func le32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
            UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8)
                | (UInt32(bytes[offset + 2]) << 16)
                | (UInt32(bytes[offset + 3]) << 24)
        }

        func value(_ key: UInt32, batteryMilliscale: Bool = false) -> Double? {
            var request = [UInt8](repeating: 0, count: 80)
            for index in 0..<4 {
                request[index] = UInt8(truncatingIfNeeded: key >> (index * 8))
            }
            request[42] = 9 // kSMCGetKeyInfo
            guard let info = exchange(request), info[40] == 0 else { return nil }
            let size = le32(info, 28)
            let type = le32(info, 32)
            let accepted = (type == 0x666c7420 && size == 4)
                || (type == 0x66706532 && size == 2)
                || (type == 0x73703738 && size == 2)
                || (batteryMilliscale && size == 2
                    && (type == 0x73693136 || type == 0x75693136))
            guard accepted else { return nil }
            request.replaceSubrange(28..<32, with: info[28..<32])
            request[42] = 5 // kSMCReadKey. Never send write command 6.
            guard let reply = exchange(request), reply[40] == 0 else { return nil }
            let decoded: Double
            if type == 0x666c7420 {
                decoded = Double(Float(bitPattern: le32(reply, 48)))
            } else if batteryMilliscale
                        && (type == 0x73693136 || type == 0x75693136) {
                let raw = UInt16(reply[48]) | (UInt16(reply[49]) << 8)
                decoded = (type == 0x73693136
                    ? Double(Int16(bitPattern: raw)) : Double(raw)) / 1_000
            } else {
                let raw = (UInt16(reply[48]) << 8) | UInt16(reply[49])
                decoded = type == 0x66706532
                    ? Double(raw) / 4 : Double(Int16(bitPattern: raw)) / 256
            }
            return decoded.isFinite ? decoded : nil
        }

        // PDTR input power, B0AC battery current (A), B0AV voltage (V).
        let input = value(0x50445452)
        let current = value(0x42304143, batteryMilliscale: true)
        let volts = value(0x42304156, batteryMilliscale: true)
        let batteryWatts: Double?
        if let current, let volts, abs(current) <= 30, (1...30).contains(volts) {
            batteryWatts = current * volts
        } else {
            batteryWatts = nil
        }
        return Rails(
            adapterWatts: input.flatMap { (0...250).contains($0) ? $0 : nil },
            batteryWatts: batteryWatts
        )
    }
}
