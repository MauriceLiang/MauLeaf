import Foundation

@main
private enum DynamicHoldPolicyTests {
    static func main() {
        check(DynamicHoldPolicy.plan(userTarget: 80, rawPercent: 75) == .target(upper: 80, lower: 78),
              "below the original limit, use the user target")
        check(DynamicHoldPolicy.plan(userTarget: 80, rawPercent: 80) == .target(upper: 80, lower: 78),
              "at the target, use the saved target")
        check(DynamicHoldPolicy.plan(userTarget: 80, rawPercent: 95.4) == .hold(upper: 96, lower: 78),
              "capture fractional SoC by rounding up")
        check(DynamicHoldPolicy.plan(userTarget: 80, rawPercent: 100) == .hold(upper: 100, lower: 78),
              "allow a bounded 100 percent temporary hold")
        check(DynamicHoldPolicy.plan(userTarget: 80, rawPercent: 90.4, holdingUpper: 96)
              == .hold(upper: 96, lower: 78),
              "never ratchet a held target downward on ordinary polling")
        check(DynamicHoldPolicy.plan(userTarget: 80, rawPercent: 90.4, holdingUpper: nil)
              == .hold(upper: 91, lower: 78),
              "a new adapter connection captures new SoC")
        check(DynamicHoldPolicy.plan(userTarget: 80, rawPercent: 76, holdingUpper: 96)
              == .target(upper: 80, lower: 78),
              "restore original ceiling once battery falls below it")
        check(DynamicHoldPolicy.plan(userTarget: 80, rawPercent: nil) == nil,
              "unknown raw SoC blocks a write")
        check(DynamicHoldPolicy.plan(userTarget: 80, rawPercent: .nan) == nil,
              "non-finite SoC blocks a write")
        check(DynamicHoldPolicy.plan(userTarget: 80, rawPercent: 101) == nil,
              "out of range SoC blocks a write")
        check(DynamicHoldPolicy.plan(userTarget: 45, rawPercent: 90) == nil,
              "unsupported user targets cannot be used")
        print("DynamicHoldPolicyTests: PASS")
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ why: String) {
        guard condition() else { fputs("FAIL: \(why)\n", stderr); exit(1) }
    }
}
