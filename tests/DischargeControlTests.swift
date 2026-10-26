import Foundation

@main
struct DischargeControlTests {
    static var checks = 0

    final class Fixture {
        var percent: Int? = 90
        var temperature: Double? = 30
        var lidClosed: Bool? = false
        var externalConnected: Bool? = true
        var adapter = true
        var supportsAdapter = true
        var limit = 75
        var clock = Date(timeIntervalSince1970: 1000)
        var failDisable = false
        var failEnable = false
        var ignoreDisable = false
        var invalidStatus = false
        var commands: [[String]] = []
        var onDisable: (() -> Void)?

        func run(_ path: String, _ args: [String]) -> ChargeProcessResult {
            commands.append(args)
            switch args {
            case ["status"]:
                return ChargeProcessResult(status: 0, output: invalidStatus ? "unrecognized status" : """
                Upper limit: \(limit)%
                Use power adapter: \(adapter)
                Power adapter control: \(supportsAdapter)
                """)
            case BattCommand.useBatteryTemporarily.arguments:
                onDisable?()
                if failDisable { return ChargeProcessResult(status: 1, output: "fixture disable failure") }
                if !ignoreDisable { adapter = false }
                return ChargeProcessResult(status: 0, output: "ok")
            case BattCommand.useAdapter.arguments:
                if failEnable { return ChargeProcessResult(status: 1, output: "fixture recovery failure") }
                adapter = true
                return ChargeProcessResult(status: 0, output: "ok")
            default: return ChargeProcessResult(status: 1, output: "unexpected command: \(args)")
            }
        }

        var snapshot: DischargeSafetySnapshot {
            DischargeSafetySnapshot(percent: percent, temperatureCelsius: temperature,
                                    lidClosed: lidClosed, externalConnected: externalConnected)
        }
    }

    static func main() throws {
        try check(BattCommand.useBatteryTemporarily.arguments == ["adapter", "disable", "--for=1m"], "only bounded adapter-disable commands are allowed")
        try check(BattCommand.useAdapter.arguments == ["adapter", "enable"], "restoration command")
        let battery = try PropertyListSerialization.data(fromPropertyList: [["CurrentCapacity": 90, "Temperature": 3031, "ExternalConnected": true]], format: .xml, options: 0)
        let lid = try PropertyListSerialization.data(fromPropertyList: [["AppleClamshellState": false]], format: .xml, options: 0)
        let parsed = DischargeSafetySnapshot.parse(batteryData: battery, lidData: lid)
        try check(parsed.percent == 90 && parsed.externalConnected == true && parsed.lidClosed == false, "IORegistry telemetry parsing")
        try check(abs((parsed.temperatureCelsius ?? 0) - 29.95) < 0.001, "battery temperature uses tenths of Kelvin")
        try check(DischargeSafetySnapshot.parse(batteryData: Data(), lidData: Data()).stopReason(target: 75)?.paused == true, "malformed telemetry must fail closed")

        try fixture { monitor, state in
            try monitor.start(battPath: "/fixture/batt", limit: 75)
            try check(monitor.hasPendingJob && !state.adapter, "high battery must start a lease")
            try monitor.tick()
            try check(state.commands.filter { $0 == BattCommand.useBatteryTemporarily.arguments }.count == 2, "healthy watchdog renews the bounded lease")
            state.percent = 75
            try monitor.tick()
            try check(!monitor.hasPendingJob && state.adapter, "target reached must restore adapter and finish")
            try check(monitor.result?.paused == false, "target completion must allow future limit changes")
            let count = state.commands.count
            try monitor.tick()
            try check(state.commands.count == count, "finished tasks must never renew")
        }
        try fixture { monitor, state in
            state.percent = 70
            try monitor.start(battPath: "/fixture/batt", limit: 75)
            try check(!monitor.hasPendingJob && state.adapter, "battery below limit stays on adapter")
            try check(!state.commands.contains(BattCommand.useBatteryTemporarily.arguments), "no discharge command below target")
        }
        for mutate in [
            { (s: Fixture) in s.lidClosed = true },
            { (s: Fixture) in s.lidClosed = nil },
            { (s: Fixture) in s.temperature = 45 },
            { (s: Fixture) in s.temperature = 0 },
            { (s: Fixture) in s.temperature = nil },
            { (s: Fixture) in s.percent = nil },
            { (s: Fixture) in s.percent = 101 }
        ] {
            try fixture { monitor, state in
                mutate(state)
                try fails { try monitor.start(battPath: "/fixture/batt", limit: 75) }
                try check(!monitor.hasPendingJob && !state.commands.contains(BattCommand.useBatteryTemporarily.arguments), "unsafe startup must never cut power")
            }
        }
        try fixture { monitor, state in
            state.supportsAdapter = false
            try fails { try monitor.start(battPath: "/fixture/batt", limit: 75) }
            try check(state.adapter && !monitor.hasPendingJob, "unsupported hardware rejected")
        }
        try fixture { monitor, state in
            state.externalConnected = false
            try monitor.start(battPath: "/fixture/batt", limit: 75)
            try check(state.adapter && !monitor.hasPendingJob && monitor.result?.paused == false,
                      "unplugged policy must wait for an adapter without cutting power")
        }
        try fixture { monitor, state in
            state.externalConnected = nil
            try fails { try monitor.start(battPath: "/fixture/batt", limit: 75) }
            try check(state.adapter && !monitor.hasPendingJob && monitor.result?.paused == true,
                      "unknown adapter connection must pause without cutting power")
        }
        try fixture { monitor, _ in
            try fails { try monitor.start(battPath: "/fixture/batt", limit: 10) }
            try fails { try monitor.start(battPath: "relative/batt", limit: 75) }
        }
        for mutate in [
            { (s: Fixture) in s.lidClosed = true },
            { (s: Fixture) in s.temperature = 46 },
            { (s: Fixture) in s.percent = nil },
            { (s: Fixture) in s.limit = 100 },
            { (s: Fixture) in s.clock = s.clock.addingTimeInterval(4 * 3600) }
        ] {
            try fixture { monitor, state in
                try monitor.start(battPath: "/fixture/batt", limit: 75)
                mutate(state)
                try monitor.tick()
                try check(state.adapter && !monitor.hasPendingJob && monitor.result?.paused == true, "runtime safety stop must restore power and pause")
            }
        }
        try fixture { monitor, state in
            try monitor.start(battPath: "/fixture/batt", limit: 75)
            try Data().write(to: monitor.directory.appendingPathComponent("once-task.json"))
            try monitor.tick()
            try check(state.adapter && monitor.result?.paused == true, "one-time charging must preempt discharge")
        }
        try fixture { monitor, state in
            state.failDisable = true
            try fails { try monitor.start(battPath: "/fixture/batt", limit: 75) }
            try check(state.adapter && !monitor.hasPendingJob && monitor.result?.paused == true, "failed disable must recover and pause")
        }
        try fixture { monitor, state in
            state.ignoreDisable = true
            try fails { try monitor.start(battPath: "/fixture/batt", limit: 75) }
            try check(state.adapter && !monitor.hasPendingJob, "command success without observed battery power is a failure")
        }
        try fixture { monitor, state in
            try monitor.start(battPath: "/fixture/batt", limit: 75)
            state.percent = 75
            state.failEnable = true
            try fails { try monitor.tick() }
            try check(monitor.hasPendingJob && monitor.result?.paused == true, "failed recovery keeps a paused retry task")
            let disableCount = state.commands.filter { $0 == BattCommand.useBatteryTemporarily.arguments }.count
            state.percent = 90
            state.failEnable = false
            try monitor.tick()
            try check(state.adapter && !monitor.hasPendingJob, "recovery retries must finish when backend recovers")
            try check(state.commands.filter { $0 == BattCommand.useBatteryTemporarily.arguments }.count == disableCount, "failed recovery must never renew the discharge lease")
        }
        try fixture { monitor, state in
            try monitor.start(battPath: "/fixture/batt", limit: 75)
            try monitor.cancel()
            try monitor.pauseForFullCharge()
            let restarted = DischargeMonitor(directory: monitor.directory)
            try check(restarted.result?.paused == true && !restarted.hasPendingJob && state.adapter, "full-charge pause must survive a process restart")
            try monitor.start(battPath: "/fixture/batt", limit: 75)
            try check(monitor.result == nil && monitor.hasPendingJob, "explicit restart clears the pause")
        }
        try fixture { monitor, state in
            try monitor.start(battPath: "/fixture/batt", limit: 75)
            state.invalidStatus = true
            try fails { try monitor.tick() }
            try check(monitor.hasPendingJob && monitor.result?.paused == true, "unverifiable recovery must keep retry state")
            state.invalidStatus = false
            try monitor.tick()
            try check(!monitor.hasPendingJob && state.adapter, "recovery can complete once status is readable")
        }
        try fixture { monitor, state in
            try monitor.start(battPath: "/fixture/batt", limit: 75)
            try Data("invalid task".utf8).write(to: monitor.jobURL, options: .atomic)
            let count = state.commands.count
            try fails { try monitor.tick() }
            try check(monitor.result?.paused == true && state.commands.count == count,
                      "corrupt task state must be reported without issuing or renewing commands")
        }
        try cancellationRace()
        print("DischargeControlTests: PASS (\(checks) checks; deterministic telemetry, no hardware writes)")
    }

    static func cancellationRace() throws {
        try fixture { monitor, state in
            try monitor.start(battPath: "/fixture/batt", limit: 75)
            let entered = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            state.onDisable = { entered.signal(); _ = release.wait(timeout: .now() + 3) }
            let group = DispatchGroup()
            let failures = NSLock()
            var errorCount = 0
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                do { try monitor.tick() } catch { failures.lock(); errorCount += 1; failures.unlock() }
            }
            try check(entered.wait(timeout: .now() + 3) == .success, "watchdog must enter the in-flight renewal")
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                do { try monitor.cancel() } catch { failures.lock(); errorCount += 1; failures.unlock() }
            }
            release.signal()
            try check(group.wait(timeout: .now() + 3) == .success && errorCount == 0, "concurrent renewal and cancellation must complete")
            try check(!monitor.hasPendingJob && state.adapter && state.commands.last == BattCommand.readStatus.arguments,
                      "cancellation must restore power after any in-flight renewal")
            let count = state.commands.count
            try monitor.tick()
            try check(state.commands.count == count, "cancelled watchdog cannot cut power again")
        }
    }

    static func fixture(_ body: (DischargeMonitor, Fixture) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("chargecap-discharge-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = Fixture()
        let monitor = DischargeMonitor(directory: directory, run: state.run,
                                       snapshot: { state.snapshot }, now: { state.clock })
        try body(monitor, state)
    }

    static func fails(_ body: () throws -> Void) throws {
        do { try body() } catch { checks += 1; return }
        try check(false, "expected a reported failure")
    }

    static func check(_ condition: Bool, _ message: String) throws {
        checks += 1
        guard condition else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }
}
