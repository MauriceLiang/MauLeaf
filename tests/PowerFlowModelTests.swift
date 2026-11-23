import Foundation

@main
enum PowerFlowModelTests {
    static func main() {
        let battery = MauLeafPowerFlow(snapshot: .init(
            percent: 85, isCharging: false, isFullyCharged: false,
            isACConnected: false, batteryPowerWatts: -8.41,
            adapterInputWatts: 27, systemLoadWatts: 11
        ))
        check(battery.mode == .battery && battery.adapterWatts == nil,
              "battery mode ignores stale adapter telemetry after unplug")
        check(battery.systemWatts == 8.41 && battery.batteryWatts == -8.41,
              "battery discharge is the system power source")

        let charging = MauLeafPowerFlow(snapshot: .init(
            percent: 70, isCharging: true, isFullyCharged: false,
            isACConnected: true, batteryPowerWatts: 8.41,
            adapterInputWatts: 27, systemLoadWatts: nil
        ))
        check(charging.mode == .charging && charging.adapterWatts == 27,
              "measured adapter input is the source when charging")
        check(abs((charging.systemWatts ?? 0) - 18.59) < 0.001,
              "system draw is derived from same-sample adapter and battery energy budget")

        let resting = MauLeafPowerFlow(snapshot: .init(
            percent: 85, isCharging: false, isFullyCharged: true,
            isACConnected: true, batteryPowerWatts: 0.05,
            adapterInputWatts: 7.1, systemLoadWatts: nil
        ))
        check(resting.mode == .adapter && resting.systemWatts == 7.1,
              "adapter-only branch contains no fake battery charge node")

        let assist = MauLeafPowerFlow(snapshot: .init(
            percent: 95, isCharging: false, isFullyCharged: false,
            isACConnected: true, batteryPowerWatts: -9.9,
            adapterInputWatts: 0.5, systemLoadWatts: nil
        ))
        check(assist.mode == .assisted && abs((assist.systemWatts ?? 0) - 10.4) < 0.001,
              "plugged in but battery still draining shows both power sources")

        let partial = MauLeafPowerFlow(snapshot: .init(
            percent: 90, isCharging: true, isFullyCharged: false,
            isACConnected: true, batteryPowerWatts: 8.41,
            adapterInputWatts: nil, systemLoadWatts: nil
        ))
        check(partial.mode == .charging && partial.systemWatts == nil,
              "no adapter input means system watts are unknown, not invented")

        let inconsistent = MauLeafPowerFlow(snapshot: .init(
            percent: 90, isCharging: true, isFullyCharged: false,
            isACConnected: true, batteryPowerWatts: 15,
            adapterInputWatts: 2, systemLoadWatts: 9
        ))
        check(inconsistent.systemWatts == nil,
              "contradictory watt readings must not produce negative system load")

        let unknown = MauLeafPowerFlow(snapshot: .init(
            percent: nil, isCharging: false, isFullyCharged: false,
            isACConnected: nil, batteryPowerWatts: -5,
            adapterInputWatts: 10
        ))
        check(unknown.mode == .unavailable && unknown.systemWatts == nil,
              "unknown physical power state must not create a fictional flow")
        check(MauLeafPowerFlow.display(nil) == "—"
              && MauLeafPowerFlow.display(.infinity) == "—"
              && MauLeafPowerFlow.display(8.41) == "8.4 W",
              "unknown watts are displayed as dashes, measured watts are compact")
        print("PowerFlowModelTests: PASS (battery, adapter, charge, assist, unknown, stale/missing data)")
    }

    private static func check(_ ok: @autoclosure () -> Bool, _ reason: String) {
        if !ok() { fputs("FAIL: \(reason)\n", stderr); exit(1) }
    }
}
