import Foundation

@main
enum AboveLimitPowerPolicyTests {
    static func main() {
        func evaluate(
            enabled: Bool = true, active: Bool = true, snapshot: Bool = true,
            once: Bool = false, percent: Int? = 92, limit: Int = 80,
            ac: Bool? = true, charging: Bool = false, current: Int? = -300
        ) -> AboveLimitPowerFinding {
            AboveLimitPowerPolicy.classify(
                enabled: enabled, firmwareActive: active, hasOriginalSnapshot: snapshot,
                oneTimeCharge: once, batteryPercent: percent, upperLimit: limit,
                externalConnected: ac, isCharging: charging, amperageMilliAmps: current
            )
        }
        precondition(evaluate(enabled: false) == .disabled)
        precondition(evaluate(active: false) == .limitInactive)
        precondition(evaluate(snapshot: false) == .limitInactive)
        precondition(evaluate(once: true) == .oneTimeCharge)
        precondition(evaluate(ac: false) == .disconnected)
        precondition(evaluate(ac: nil) == .disconnected)
        precondition(evaluate(percent: nil) == .unknownBattery)
        precondition(evaluate(percent: 80) == .withinLimit)
        precondition(evaluate(percent: 79) == .withinLimit)
        precondition(evaluate(charging: true) == .chargingAboveLimit)
        precondition(evaluate(current: 200) == .chargingAboveLimit)
        precondition(evaluate(current: nil) == .unknownCurrent)
        precondition(evaluate(current: -300) == .observingDischarge)
        precondition(evaluate(current: -40) == .noSignificantDischarge)
        precondition(evaluate(current: 0) == .noSignificantDischarge)
        print("AboveLimitPowerPolicyTests: PASS (read-only; no SMC writes)")
    }
}
