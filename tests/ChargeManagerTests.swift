import Foundation

// Replace launchd only; mode changes still run ChargeManager's real command
// execution and status verification against the fixture CLI below.
@MainActor
enum OnceChargeAgent {
    static var hasPendingJob = false
    static var prepareCount = 0

    static func prepare(battPath: String, limit: Int) async throws {
        prepareCount += 1
        hasPendingJob = true
    }

    static func cancel() async throws { hasPendingJob = false }
}

@MainActor
enum DischargeAgent {
    static var monitor: DischargeMonitor!
    static var hasPendingJob: Bool { monitor.hasPendingJob }
    static var result: DischargeResult? { monitor.result }
    static func start(battPath: String, limit: Int) async throws { try monitor.start(battPath: battPath, limit: limit) }
    static func stop() async throws { try monitor.cancel() }
    static func pauseForFullCharge() throws { try monitor.pauseForFullCharge() }
}

#if !MAULEAF_LAYOUT_TESTING
@main
struct ChargeManagerTests {
    static var checks = 0
    @MainActor
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mauleaf-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = directory.appendingPathComponent("batt")
        try #"""
        #!/bin/bash
        set -euo pipefail
        cd "$(dirname "$0")"
        echo "$*" >> commands
        case "$1" in
          status)
            if [[ -f fail-status ]]; then echo "fixture: status unavailable"; exit 1; fi
            echo "Upper limit: $(cat upper)%"
            echo "Use power adapter: $(cat adapter)"
            echo "Power adapter control: $(cat capability)"
            if [[ -f restore ]]; then echo "Restoring $(cat restore)% limit: in 10h"; fi
            ;;
          limit)
            if [[ -f fail-limit ]]; then echo "fixture: limit failed"; exit 1; fi
            if [[ -f slow-limit ]]; then sleep 0.15; fi
            echo "$2" > upper
            rm -f restore
            ;;
          disable)
            if [[ -f fail-full ]]; then echo "fixture: disable failed"; exit 1; fi
            if [[ "${2:-}" == --for=10h ]]; then cp upper restore; elif [[ ! -f keep-restore ]]; then rm -f restore; fi
            if [[ ! -f ignore-disable ]]; then echo 100 > upper; fi
            ;;
          adapter)
            case "$2" in
              enable) if [[ -f fail-adapter ]]; then echo "fixture: adapter failed"; exit 1; fi; echo true > adapter ;;
              disable) [[ "${3:-}" == --for=1m ]]; echo false > adapter ;;
              *) exit 1 ;;
            esac
            ;;
          *) exit 1 ;;
        esac
        """#.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        try "75".write(to: directory.appendingPathComponent("upper"), atomically: true, encoding: .utf8)
        try "true".write(to: directory.appendingPathComponent("adapter"), atomically: true, encoding: .utf8)
        try "true".write(to: directory.appendingPathComponent("capability"), atomically: true, encoding: .utf8)
        DischargeAgent.monitor = DischargeMonitor(directory: directory, snapshot: {
            DischargeSafetySnapshot(percent: 90, temperatureCelsius: 30, lidClosed: false, externalConnected: true)
        })
        // This executable has its own defaults domain, separate from the app.
        UserDefaults.standard.set(75, forKey: "chargeLimit")
        UserDefaults.standard.set("limited", forKey: "chargeModeV5")
        UserDefaults.standard.set("once", forKey: "fullBehaviorV5")
        UserDefaults.standard.set("adapter", forKey: "highChargePolicy")
        UserDefaults.standard.set(false, forKey: "chargeControlReleasedOnQuit")
        let manager = ChargeManager(battPath: binary.path)
        manager.refresh()
        try check(manager.backendReady, "fixture backend must be ready")
        manager.batteryPercent = 100
        manager.selectChargeMode(.full)
        try await finish(manager)
        try check(manager.chargeMode == .full, "100% battery must still open full-charge options")
        try check(!manager.fullOncePending && OnceChargeAgent.prepareCount == 0,
                  "100% battery must not start a redundant one-time task")
        manager.refresh()
        try check(manager.chargeMode == .full, "refresh must keep idle full-charge options accessible")
        try check(!(try String(contentsOf: directory.appendingPathComponent("commands"), encoding: .utf8))
            .contains("disable"), "entering idle full-charge options must not disable limiting")
        manager.batteryPercent = 80
        manager.selectFullBehavior(.once)
        try await finish(manager)
        try check(manager.fullOncePending, "idle one-time selection must be startable after the battery drops")
        manager.cancelFullOnce()
        try await finish(manager)
        try check(manager.chargeMode == .limited && !OnceChargeAgent.hasPendingJob,
                  "cancelling one-time charging must restore limited mode and clear the task")
        manager.batteryPercent = 100
        manager.selectChargeMode(.full)
        try await finish(manager)
        try check(manager.chargeMode == .full, "full-charge options must remain accessible after cancellation")

        manager.selectFullBehavior(.always)
        try await finish(manager)
        try check(manager.chargeMode == .full && manager.fullBehavior == .always,
                  "persistent full charge must be selectable from a full battery")
        try check(!manager.isError, "persistent full charge must verify successfully")
        manager.refresh()
        try check(manager.chargeMode == .full, "refresh must preserve persistent full charge")
        manager.selectChargeMode(.limited)
        try await finish(manager)
        try check(manager.chargeMode == .limited && manager.limit == 75,
                  "returning to limited mode must preserve the saved limit")
        try check(try String(contentsOf: directory.appendingPathComponent("upper"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) == "75", "saved limit must reach the backend")

        manager.batteryPercent = 80
        manager.selectChargeMode(.full)
        try await finish(manager)
        try check(manager.chargeMode == .full && manager.fullOncePending,
                  "below 100% must start one-time charging")
        try check(OnceChargeAgent.prepareCount == 2, "one-time charging must prepare its helper")
        manager.refresh()
        try check(manager.fullOncePending, "refresh must keep an active task")
        // Simulate the helper restoring the saved limit and removing its task.
        try "75".write(to: directory.appendingPathComponent("upper"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("restore"))
        OnceChargeAgent.hasPendingJob = false
        manager.refresh()
        try check(manager.chargeMode == .limited, "completed one-time charging must return to limited mode")

        try "".write(to: directory.appendingPathComponent("fail-full"), atomically: true, encoding: .utf8)
        manager.selectFullBehavior(.always)
        try await finish(manager)
        try check(manager.isError && manager.chargeMode == .limited,
                  "failed mode changes must display an error and preserve the prior mode")
        try FileManager.default.removeItem(at: directory.appendingPathComponent("fail-full"))
        manager.retryChargeRequest()
        try await finish(manager)
        try check(manager.chargeMode == .full && manager.fullBehavior == .always && !manager.isError,
                  "retry must repeat the failed full-charge action rather than the currently displayed mode")
        manager.selectChargeMode(.limited)
        try await finish(manager)

        manager.selectHighChargePolicy(.discharge)
        try await finish(manager)
        try check(manager.highChargePolicy == .discharge && DischargeAgent.hasPendingJob && !manager.isError,
                  "high battery policy must start a verified background discharge")
        manager.selectHighChargePolicy(.adapter)
        try await finish(manager)
        try check(manager.highChargePolicy == .adapter && !DischargeAgent.hasPendingJob,
                  "adapter policy must cancel the background task")
        try check(try String(contentsOf: directory.appendingPathComponent("adapter"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) == "true", "adapter policy must restore power")
        manager.selectHighChargePolicy(.discharge)
        try await finish(manager)
        manager.selectFullBehavior(.always)
        try await finish(manager)
        try check(!DischargeAgent.hasPendingJob && manager.dischargePaused,
                  "full-charge mode must stop discharging and persist a pause")
        manager.selectChargeMode(.limited)
        try await finish(manager)
        try check(manager.highChargePolicy == .discharge && !DischargeAgent.hasPendingJob && manager.dischargePaused,
                  "returning from full charge must preserve the policy without immediately draining the battery")
        manager.selectHighChargePolicy(.discharge)
        try await finish(manager)
        try check(DischargeAgent.hasPendingJob && !manager.dischargePaused,
                  "explicit resume must clear the full-charge pause")
        manager.batteryPercent = 80
        manager.selectFullBehavior(.once)
        try await finish(manager)
        try check(manager.fullOncePending && !DischargeAgent.hasPendingJob && manager.dischargePaused,
                  "one-time full charging must preempt active discharging")
        try "75".write(to: directory.appendingPathComponent("upper"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("restore"))
        try DischargeAgent.monitor.pauseForFullCharge(completed: true)
        OnceChargeAgent.hasPendingJob = false
        let reopened = ChargeManager(battPath: binary.path)
        reopened.refresh()
        try check(reopened.chargeMode == .limited && reopened.dischargePaused && !DischargeAgent.hasPendingJob,
                  "reopening after one-time completion must show limited mode without draining the full battery")
        manager.refresh()
        try check(manager.chargeMode == .limited && manager.dischargePaused,
                  "one-time completion must restore limited mode and preserve the discharge pause")
        manager.selectHighChargePolicy(.discharge)
        try await finish(manager)
        // Changing the limit must replace the old task, rather than restore an obsolete target later.
        manager.requestLimit(70, immediate: true)
        try await finish(manager)
        let job = try JSONDecoder().decode(DischargeJob.self, from: Data(contentsOf: DischargeAgent.monitor.jobURL))
        try check(job.limit == 70 && manager.limit == 70, "limit changes must update the discharge target")
        manager.selectHighChargePolicy(.adapter)
        try await finish(manager)
        try "false".write(to: directory.appendingPathComponent("capability"), atomically: true, encoding: .utf8)
        manager.refresh()
        manager.selectHighChargePolicy(.discharge)
        try await finish(manager)
        try check(manager.highChargePolicy == .adapter && !DischargeAgent.hasPendingJob,
                  "unsupported hardware must not allow active discharge")
        try "".write(to: directory.appendingPathComponent("fail-limit"), atomically: true, encoding: .utf8)
        manager.requestLimit(85, immediate: true)
        try await finish(manager)
        try check(manager.isError && manager.canRetryChargeRequest, "failed limit update must offer a retry")
        try FileManager.default.removeItem(at: directory.appendingPathComponent("fail-limit"))
        manager.retryChargeRequest()
        try await finish(manager)
        try check(!manager.isError && manager.limit == 85 && manager.modeText == "限充至 85%",
                  "retry must apply and verify the requested limit")
        func freshForQuit() throws -> ChargeManager {
            for name in ["fail-limit", "fail-full", "fail-status", "fail-adapter", "slow-limit", "keep-restore", "ignore-disable", "restore"] {
                let file = directory.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            }
            try DischargeAgent.monitor.cancel()
            OnceChargeAgent.hasPendingJob = false
            for (name, value) in [("upper", "80"), ("adapter", "true"), ("capability", "true")] {
                try value.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
            UserDefaults.standard.set(80, forKey: "chargeLimit")
            UserDefaults.standard.set("limited", forKey: "chargeModeV5")
            UserDefaults.standard.set("once", forKey: "fullBehaviorV5")
            UserDefaults.standard.set("adapter", forKey: "highChargePolicy")
            UserDefaults.standard.set(false, forKey: "chargeControlReleasedOnQuit")
            let manager = ChargeManager(battPath: binary.path)
            manager.refresh()
            return manager
        }
        func value(_ name: String) throws -> String {
            try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let limitedQuit = try freshForQuit()
        try check(await limitedQuit.prepareForTermination(), "normal quit must complete cleanup before permitting termination")
        try check(try value("upper") == "100" && value("adapter") == "true", "quit must restore normal charging and adapter power")
        try check(UserDefaults.standard.integer(forKey: "chargeLimit") == 80
                  && UserDefaults.standard.bool(forKey: "chargeControlReleasedOnQuit"), "quit must preserve the chosen limit for next launch")
        let commandsAfterQuit = try value("commands")
        limitedQuit.requestLimit(55, immediate: true)
        limitedQuit.refresh()
        try await Task.sleep(nanoseconds: 30_000_000)
        try check(try value("commands") == commandsAfterQuit && limitedQuit.limit == 80,
                  "no queued input or timer refresh may re-enable limiting after cleanup")
        try check(await limitedQuit.prepareForTermination(), "repeated termination requests must be idempotent")
        try check(try value("commands") == commandsAfterQuit, "successful cleanup must not run twice")

        let resumed = ChargeManager(battPath: binary.path)
        resumed.start()
        for _ in 0..<200 {
            if !resumed.isBusy && !UserDefaults.standard.bool(forKey: "chargeControlReleasedOnQuit") { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try check(try value("upper") == "80" && !resumed.isError, "next launch must reapply the saved limit")

        let onceQuit = try freshForQuit()
        onceQuit.batteryPercent = 90
        onceQuit.selectFullBehavior(.once)
        try await finish(onceQuit)
        try check(OnceChargeAgent.hasPendingJob, "one-time quit fixture must have a pending restore")
        try check(await onceQuit.prepareForTermination(), "quit during one-time full charge must clean up successfully")
        try check(!OnceChargeAgent.hasPendingJob && !FileManager.default.fileExists(atPath: directory.appendingPathComponent("restore").path),
                  "quit must cancel both the helper and batt's scheduled restoration")
        try check(UserDefaults.standard.string(forKey: "chargeModeV5") == "limited", "cancelled one-time mode must not restart on next launch")

        let dischargeQuit = try freshForQuit()
        dischargeQuit.selectHighChargePolicy(.discharge)
        try await finish(dischargeQuit)
        try check(DischargeAgent.hasPendingJob, "discharging quit fixture must have an active task")
        try check(await dischargeQuit.prepareForTermination(), "active discharge must stop before quitting")
        try check(!DischargeAgent.hasPendingJob && (try value("adapter")) == "true" && (try value("upper")) == "100",
                  "discharge cleanup must restore adapter input and remove limiting")

        let failedQuit = try freshForQuit()
        try "".write(to: directory.appendingPathComponent("fail-full"), atomically: true, encoding: .utf8)
        try check(!(await failedQuit.prepareForTermination()), "failed disable must prevent application termination")
        try check(failedQuit.isError && !failedQuit.isPreparingToQuit && !failedQuit.isBusy,
                  "failed cleanup must leave a usable application with an error")
        try check(!UserDefaults.standard.bool(forKey: "chargeControlReleasedOnQuit"), "failed cleanup must not claim charging was released")
        try FileManager.default.removeItem(at: directory.appendingPathComponent("fail-full"))
        try check(await failedQuit.prepareForTermination(), "retrying quit must recover after a transient backend failure")

        let pausedFailure = try freshForQuit()
        pausedFailure.selectHighChargePolicy(.discharge)
        try await finish(pausedFailure)
        try "".write(to: directory.appendingPathComponent("fail-full"), atomically: true, encoding: .utf8)
        try check(!(await pausedFailure.prepareForTermination()), "failed quit from active discharge must stay open")
        pausedFailure.refresh()
        try await Task.sleep(nanoseconds: 30_000_000)
        try check(pausedFailure.isError && !DischargeAgent.hasPendingJob,
                  "automatic refresh must not restart discharging after cleanup failed")

        let unchangedQuit = try freshForQuit()
        try "".write(to: directory.appendingPathComponent("ignore-disable"), atomically: true, encoding: .utf8)
        try check(!(await unchangedQuit.prepareForTermination()) && unchangedQuit.isError,
                  "a successful command without observed 100% limit must not permit termination")
        let scheduledQuit = try freshForQuit()
        try "80".write(to: directory.appendingPathComponent("restore"), atomically: true, encoding: .utf8)
        try "".write(to: directory.appendingPathComponent("keep-restore"), atomically: true, encoding: .utf8)
        try check(!(await scheduledQuit.prepareForTermination()), "a remaining scheduled restore must prevent termination")
        let unavailableQuit = try freshForQuit()
        try "".write(to: directory.appendingPathComponent("fail-status"), atomically: true, encoding: .utf8)
        try check(!(await unavailableQuit.prepareForTermination()) && unavailableQuit.isError,
                  "an unreachable daemon must not be treated as successful cleanup")
        let adapterQuit = try freshForQuit()
        try "false".write(to: directory.appendingPathComponent("adapter"), atomically: true, encoding: .utf8)
        try "".write(to: directory.appendingPathComponent("fail-adapter"), atomically: true, encoding: .utf8)
        try check(!(await adapterQuit.prepareForTermination()), "failed adapter recovery must prevent termination")

        let busyQuit = try freshForQuit()
        try "".write(to: directory.appendingPathComponent("slow-limit"), atomically: true, encoding: .utf8)
        busyQuit.requestLimit(75, immediate: true)
        for _ in 0..<200 {
            if busyQuit.isBusy { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        try check(busyQuit.isBusy, "busy quit fixture must have an in-flight command")
        busyQuit.requestLimit(70, immediate: true)
        try await Task.sleep(nanoseconds: 5_000_000)
        try check(await busyQuit.prepareForTermination(), "quit must wait for the current command and discard queued limits")
        try await Task.sleep(nanoseconds: 40_000_000)
        try check(try value("upper") == "100", "an in-flight or queued limit must never overwrite the final disable")
        print("ChargeManagerTests: PASS (\(checks) checks; fixture CLI, no hardware writes)")
    }

    @MainActor
    static func finish(_ manager: ChargeManager) async throws {
        for _ in 0..<300 {
            try await Task.sleep(nanoseconds: 10_000_000)
            if !manager.isBusy { return }
        }
        throw NSError(domain: "ChargeManagerTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "mode change timed out"])
    }

    static func check(_ condition: Bool, _ message: String) throws {
        checks += 1
        guard condition else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }
}
#endif
