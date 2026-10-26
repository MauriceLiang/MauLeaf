import Foundation

@main
struct PowerRefreshTests {
    @MainActor static var checks = 0

    final class Reader: @unchecked Sendable {
        private let lock = NSLock()
        private var value: BatteryPowerSample?
        private var calls = 0
        private var active = 0
        private var maximumActive = 0
        private var ranOnMainThread = false
        private var gate: DispatchSemaphore?

        init(_ value: BatteryPowerSample?) { self.value = value }
        func set(_ value: BatteryPowerSample?) { lock.lock(); self.value = value; lock.unlock() }
        func holdNext() -> DispatchSemaphore {
            lock.lock()
            defer { lock.unlock() }
            let gate = DispatchSemaphore(value: 0)
            self.gate = gate
            return gate
        }
        func read() -> BatteryPowerSample? {
            lock.lock()
            calls += 1
            active += 1
            maximumActive = max(maximumActive, active)
            ranOnMainThread = ranOnMainThread || Thread.isMainThread
            let sample = value
            let gate = gate
            self.gate = nil
            lock.unlock()
            if let gate { _ = gate.wait(timeout: .now() + 3) }
            lock.lock(); active -= 1; lock.unlock()
            return sample
        }
        var stats: (calls: Int, active: Int, maximum: Int, onMain: Bool) {
            lock.lock(); defer { lock.unlock() }
            return (calls, active, maximumActive, ranOnMainThread)
        }
    }

    static func sample(current: NSNumber = -800, charging: Bool = false, connected: Bool = false) -> BatteryPowerSample {
        BatteryPowerSample(properties: ["Voltage": 12500, "InstantAmperage": current,
                                        "IsCharging": charging, "ExternalConnected": connected,
                                        "CurrentCapacity": 88, "FullyCharged": false])
    }

    @MainActor
    static func main() async throws {
        let discharging = sample()
        let charging = sample(current: 1500, charging: true, connected: true)
        let idle = sample(current: 0, connected: true)
        try check(discharging.dischargeWatts == 10 && discharging.chargeWatts == nil, "signed discharging current")
        try check(discharging.refreshInterval == 2 && charging.refreshInterval == 2, "charge/discharge must sample every 2 seconds")
        try check(charging.chargeWatts == 18.75 && charging.dischargeWatts == nil, "charging must publish only charge power")
        try check(idle.refreshInterval == 5 && idle.chargeWatts == nil && idle.dischargeWatts == nil, "idle battery must slow to 5 seconds")
        try check(sample(current: NSNumber(value: UInt64.max - 799)) == discharging, "unsigned negative current must preserve sign")
        try check(sample(current: 0, charging: true, connected: true).chargeWatts == 0, "zero current while charging remains a valid reading")
        try check(BatteryPowerSample(properties: ["Voltage": 12500, "Amperage": -800]).dischargeWatts == 10, "average-current fallback")
        try check(BatteryPowerSample(properties: ["Voltage": 0, "Amperage": -800]).dischargeWatts == nil, "invalid voltage must not fabricate power")
        try check(BatteryPowerSample(properties: ["ExternalConnected": false]).dischargeWatts == nil, "missing current must stay unavailable")
        try check(BatteryPowerSample(properties: ["CurrentCapacity": 101]).percent == nil, "invalid percentage rejected")
        try check(BatteryPowerSample(properties: [:]).refreshInterval == 5, "unknown state uses the slower retry interval")

        let reader = Reader(discharging)
        var updates: [BatteryPowerSample?] = []
        var controlRefreshes = 0
        let controller = PowerRefreshController(read: { reader.read() }, onUpdate: { updates.append($0) },
                                                 onSystemChange: { controlRefreshes += 1 })
        controller.refreshNow()
        controller.sampleIfNeeded()
        try check(reader.stats.calls == 0 && controller.refreshInterval == nil, "hidden window must not sample")
        controller.setVisible(true)
        try await wait { updates.count == 1 && !controller.isSampling }
        try check(reader.stats.calls == 1 && updates[0] == discharging, "opening must sample immediately")
        try check(controller.refreshInterval == 2 && !reader.stats.onMain, "sampling must run off the main thread")
        controller.sampleIfNeeded()
        try await wait { updates.count == 2 && !controller.isSampling }
        try check(controlRefreshes == 0, "ordinary power ticks must not query control status")
        reader.set(idle)
        controller.refreshNow()
        try await wait { updates.count == 3 && !controller.isSampling }
        try check(controller.refreshInterval == 5, "idle transition must reconfigure the timer")
        reader.set(charging)
        controller.refreshNow()
        try await wait { updates.count == 4 && !controller.isSampling }
        try check(controller.refreshInterval == 2, "charging transition must restore fast sampling")
        reader.set(nil)
        controller.refreshNow()
        try await wait { updates.count == 5 && !controller.isSampling }
        try check(updates[4] == nil && controller.refreshInterval == 5, "failed read must clear stale power and slow retry")
        controller.setVisible(false)
        let calls = reader.stats.calls
        controller.refreshNow()
        controller.sampleIfNeeded()
        try check(reader.stats.calls == calls && controller.refreshInterval == nil, "closing must stop the fast timer")

        // A slow read must not overlap another one, even after multiple ticks.
        reader.set(discharging)
        let gate = reader.holdNext()
        controller.setVisible(true)
        try await wait { reader.stats.active == 1 }
        let updatesBeforeClose = updates.count
        let callsBeforeClose = reader.stats.calls
        controller.sampleIfNeeded()
        controller.sampleIfNeeded()
        try check(reader.stats.calls == callsBeforeClose && reader.stats.maximum == 1, "busy timer ticks must be skipped")
        controller.setVisible(false)
        gate.signal()
        try await wait { !controller.isSampling }
        try check(updates.count == updatesBeforeClose, "closing must discard an in-flight result")

        // Reopening during a read queues one fresh read, without publishing
        // the result captured before the window was reopened.
        let reopenGate = reader.holdNext()
        controller.setVisible(true)
        try await wait { reader.stats.active == 1 }
        controller.setVisible(false)
        reader.set(charging)
        controller.setVisible(true)
        controller.refreshNow()
        controller.refreshNow()
        let callsBeforeRelease = reader.stats.calls
        reopenGate.signal()
        try await wait { !controller.isSampling && updates.count == updatesBeforeClose + 1 }
        try check(updates.last! == charging && reader.stats.calls == callsBeforeRelease + 1,
                  "urgent refresh requests must coalesce into one fresh reading")
        try check(reader.stats.maximum == 1, "hide/reopen must never create concurrent readers")

        controller.suspend()
        let callsBeforeSleep = reader.stats.calls
        controller.refreshNow()
        controller.sampleIfNeeded()
        try check(controller.refreshInterval == nil && reader.stats.calls == callsBeforeSleep, "sleep must stop sampling")
        controller.resume()
        try await wait { !controller.isSampling && reader.stats.calls > callsBeforeSleep }
        try check(controlRefreshes == 1 && controller.refreshInterval == 2, "wake must refresh control state and visible power")
        controller.setVisible(false)
        controller.suspend()
        let hiddenCalls = reader.stats.calls
        controller.resume()
        try check(controlRefreshes == 2 && reader.stats.calls == hiddenCalls && controller.refreshInterval == nil,
                  "hidden wake must refresh control state without resuming power sampling")
        print("PowerRefreshTests: PASS (\(checks) checks; no GUI or hardware control)")
    }

    @MainActor
    static func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try check(false, "asynchronous power refresh timed out")
    }

    @MainActor
    static func check(_ condition: Bool, _ message: String) throws {
        checks += 1
        guard condition else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }
}
