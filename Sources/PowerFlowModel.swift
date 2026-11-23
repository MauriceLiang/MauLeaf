import Foundation

/// Read-only diagram data. Values are measured/derived from one system
/// battery snapshot, never inferred from adapter nameplate wattage.
struct MauLeafPowerFlow: Equatable {
    enum Mode: Equatable {
        case battery, adapter, charging, assisted, unavailable
    }

    let mode: Mode
    let adapterWatts: Double?
    /// Positive = into battery; negative = battery delivering power.
    let batteryWatts: Double?
    let systemWatts: Double?

    init(snapshot: MauLeafBatterySnapshot?) {
        guard let snapshot, let connected = snapshot.isACConnected else {
            mode = .unavailable
            adapterWatts = nil
            batteryWatts = nil
            systemWatts = nil
            return
        }
        let pack = Self.validSigned(snapshot.batteryPowerWatts)
        let input = connected ? Self.valid(snapshot.adapterInputWatts) : nil
        // The telemetry dictionary can be stale after a plug/unplug.
        // Do not mix unrelated samples into a false, balanced flow.
        if !connected {
            mode = .battery
            adapterWatts = nil
            batteryWatts = pack.flatMap { $0 < -0.3 ? $0 : nil }
            systemWatts = batteryWatts.map { -$0 }
        } else if let pack, pack < -0.3 {
            mode = .assisted
            adapterWatts = input
            batteryWatts = pack
            systemWatts = input.map { $0 - pack }
        } else if snapshot.isCharging, let pack, pack > 0.3 {
            mode = .charging
            adapterWatts = input
            batteryWatts = pack
            systemWatts = input.flatMap { $0 >= pack ? $0 - pack : nil }
        } else {
            mode = .adapter
            adapterWatts = input
            batteryWatts = nil
            systemWatts = input ?? Self.valid(snapshot.systemLoadWatts)
        }
    }

    private static func valid(_ value: Double?) -> Double? {
        guard let value, value.isFinite, (0...250).contains(value) else { return nil }
        return value
    }

    private static func validSigned(_ value: Double?) -> Double? {
        guard let value, value.isFinite, (-250...250).contains(value) else { return nil }
        return value
    }

    static func display(_ watts: Double?) -> String {
        guard let watts, watts.isFinite, (0...250).contains(watts) else { return "—" }
        return String(format: "%.1f W", watts)
    }

    var hasPowerReading: Bool {
        adapterWatts != nil || batteryWatts != nil || systemWatts != nil
    }
}
