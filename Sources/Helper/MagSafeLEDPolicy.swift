import Foundation

/// Pure presentation policy; does not control charging. Missing observations
/// must never be interpreted as "not charging".
struct MagSafeLEDObservation {
    let externalConnected: Bool?
    let isCharging: Bool?
    let isFullyCharged: Bool?
    let rawPercent: Double?
    let magSafeConnected: Bool
}

enum MagSafeLEDPolicy {
    static func wantsGreen(
        state: FirmwareLimitState, observation: MagSafeLEDObservation,
        ownsChargeLimit: Bool, ownsSameBand: Bool
    ) -> Bool {
        guard ownsChargeLimit, state.isActive, state.isValid,
              observation.magSafeConnected,
              observation.externalConnected == true,
              observation.isCharging == false,
              observation.isFullyCharged == false,
              let percent = observation.rawPercent,
              percent.isFinite, (0...100).contains(percent),
              percent > Double(state.lower) else { return false }
        // Firmware thresholds use raw capacity. A dynamic hold can capture
        // ceil(raw SoC); allow that sub-1% band only when actually not charging.
        // After observing a stop near the upper bound, retain green inside
        // this exact hysteresis band until charging resumes or lower is reached.
        return ownsSameBand || ceil(percent) >= Double(state.upper)
    }
}
