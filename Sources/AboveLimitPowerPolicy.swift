import Foundation

/// Read-only interpretation of above-limit battery telemetry.
/// This deliberately does not claim that ExternalConnected proves the Mac is
/// actually powered by the adapter, or write any SMC charge/adapter keys.
enum AboveLimitPowerFinding: Equatable {
    case disabled
    case limitInactive
    case oneTimeCharge
    case disconnected
    case unknownBattery
    case withinLimit
    case unknownCurrent
    case chargingAboveLimit
    case observingDischarge
    case batteryDischarging
    case noSignificantDischarge
}

enum AboveLimitPowerPolicy {
    // Battery current can fluctuate around zero; do not treat a single
    // negative sample as proof that the adapter was cut off.
    static let meaningfulCurrentMA = 150
    static let dischargeSamplesRequired = 3

    static func classify(
        enabled: Bool,
        firmwareActive: Bool,
        hasOriginalSnapshot: Bool,
        oneTimeCharge: Bool,
        batteryPercent: Int?,
        upperLimit: Int,
        externalConnected: Bool?,
        isCharging: Bool,
        amperageMilliAmps: Int?
    ) -> AboveLimitPowerFinding {
        guard enabled else { return .disabled }
        guard !oneTimeCharge else { return .oneTimeCharge }
        guard firmwareActive, hasOriginalSnapshot, (50...95).contains(upperLimit) else {
            return .limitInactive
        }
        guard externalConnected == true else { return .disconnected }
        guard let batteryPercent else { return .unknownBattery }
        guard batteryPercent > upperLimit else { return .withinLimit }
        if isCharging { return .chargingAboveLimit }
        guard let current = amperageMilliAmps else { return .unknownCurrent }
        if current >= meaningfulCurrentMA { return .chargingAboveLimit }
        if current <= -meaningfulCurrentMA { return .observingDischarge }
        return .noSignificantDischarge
    }
}
