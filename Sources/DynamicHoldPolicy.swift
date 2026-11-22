import Foundation

/// Pure, side-effect-free planner for the experimental above-target hold.
/// The user target is independent from the effective SMC interval.
enum DynamicHoldPolicy {
    enum Plan: Equatable {
        case target(upper: Int, lower: Int)
        case hold(upper: Int, lower: Int)

        var upper: Int {
            switch self { case .target(let value, _), .hold(let value, _): return value }
        }
        var lower: Int {
            switch self { case .target(_, let value), .hold(_, let value): return value }
        }
        var isTemporary: Bool {
            if case .hold = self { return true }
            return false
        }
    }

    /// Never round down a fractional battery level: 95.4% requires a 96%
    /// firmware ceiling, otherwise firmware may intentionally drain it.
    /// A nil/infinite raw reading is not safe to use for control.
    static func plan(userTarget: Int, rawPercent: Double?,
                     holdingUpper: Int? = nil) -> Plan? {
        guard (50...95).contains(userTarget),
              let rawPercent, rawPercent.isFinite, (0...101).contains(rawPercent) else {
            return nil
        }
        let resume = max(5, userTarget - 2)
        if rawPercent <= Double(userTarget) {
            return .target(upper: userTarget, lower: resume)
        }
        let captured = min(100, max(userTarget, Int(ceil(rawPercent))))
        let upper = holdingUpper.flatMap { (userTarget...100).contains($0) ? $0 : nil } ?? captured
        // Holding still uses the user's original resume threshold, not a
        // short interval around the temporary upper. This avoids recapturing
        // every tiny battery fluctuation on a long-lived AC connection.
        return .hold(upper: upper, lower: resume)
    }
}
