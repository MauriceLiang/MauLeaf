import Foundation

@main
private enum FirmwareLimitReconciliationTests {
    private static var checks = 0

    static func main() throws {
        let request = try FirmwareLimitRequest(upper: 80, lower: 78)
        let now = Date(timeIntervalSince1970: 1_000)
        let job = try FirmwareLimitOnceJob(
            jobID: "native-once-job",
            restore: request,
            deadline: Date(timeIntervalSince1970: 2_000)
        )
        expect(job.restoreRequest == request, "job persists the exact original upper/lower pair")
        expect(!job.isExpired(at: now), "job remains active before its deadline")
        expect(job.isExpired(at: Date(timeIntervalSince1970: 2_000)), "job expires at its deadline")
        let encoded = try JSONEncoder().encode(job)
        let decoded = try JSONDecoder().decode(FirmwareLimitOnceJob.self, from: encoded)
        expect(decoded == job, "job survives JSON persistence and reload")
        expectThrows({
            _ = try FirmwareLimitOnceJob(jobID: " ", restore: request, deadline: now)
        }, "empty job identifiers are rejected")
        let invalidJSON = Data(
            #"{ "jobID":"invalid", "restoreUpper":101, "restoreLower":99, "deadlineUnixSeconds":2000 }"#.utf8
        )
        expectThrows({ _ = try JSONDecoder().decode(FirmwareLimitOnceJob.self, from: invalidJSON) },
                     "invalid persisted restore thresholds are rejected")

        let charging = FirmwareLimitBatteryObservation(percent: 84, fullyCharged: false, externalConnected: true)
        expect(
            FirmwareLimitOneTimeChargeCoordinator.decision(job: job, observation: charging, now: now) == .continueCharging,
            "charging continues while AC is connected and target is not reached"
        )

        let full = FirmwareLimitBatteryObservation(percent: 100, fullyCharged: true, externalConnected: true)
        let fullDecision = FirmwareLimitOneTimeChargeCoordinator.decision(job: job, observation: full, now: now)
        expect(fullDecision == .restoreLimit(.fullyCharged), "100% completion requests limit restoration")
        expect(
            FirmwareLimitOneTimeChargeCoordinator.restoreRequest(for: fullDecision, job: job) == request,
            "completion restores the saved upper/lower pair"
        )

        let disconnected = FirmwareLimitBatteryObservation(percent: 100, fullyCharged: true, externalConnected: false)
        expect(
            FirmwareLimitOneTimeChargeCoordinator.decision(job: job, observation: disconnected, now: now)
                == .waitForAC(.fullyCharged),
            "completion while unplugged defers restoration until AC returns"
        )

        let unknownPower = FirmwareLimitBatteryObservation(percent: 84, fullyCharged: false, externalConnected: nil)
        expect(
            FirmwareLimitOneTimeChargeCoordinator.decision(job: job, observation: unknownPower, now: now)
                == .waitForAC(.waitingForAC),
            "unknown adapter state never assumes AC is connected"
        )

        let expired = FirmwareLimitOneTimeChargeCoordinator.decision(
            job: job, observation: charging, now: Date(timeIntervalSince1970: 2_001)
        )
        expect(expired == .restoreLimit(.deadlineExpired), "10-hour deadline requests restoration")

        let cancelled = FirmwareLimitOneTimeChargeCoordinator.decision(
            job: job, observation: charging, now: now, cancelRequested: true
        )
        expect(cancelled == .restoreLimit(.cancelled), "user cancellation requests restoration")

        var persistedCancellation = job
        persistedCancellation.cancelRequested = true
        let cancelledData = try JSONEncoder().encode(persistedCancellation)
        let reloadedCancellation = try JSONDecoder().decode(FirmwareLimitOnceJob.self, from: cancelledData)
        expect(reloadedCancellation.cancelRequested, "cancellation intent survives helper restart")
        expect(
            FirmwareLimitOneTimeChargeCoordinator.decision(job: reloadedCancellation, observation: charging, now: now)
                == .restoreLimit(.cancelled),
            "reloaded cancellation continues toward restoration"
        )
        expect(
            FirmwareLimitOneTimeChargeCoordinator.decision(
                job: reloadedCancellation, observation: disconnected, now: now
            ) == .waitForAC(.cancelled),
            "cancellation while unplugged stays pending until AC returns"
        )

        let missingTelemetry = FirmwareLimitBatteryObservation(percent: nil, fullyCharged: nil, externalConnected: true)
        expect(
            FirmwareLimitOneTimeChargeCoordinator.decision(job: job, observation: missingTelemetry, now: now)
                == .restoreLimit(.telemetryUnavailable),
            "missing telemetry on AC restores the limit"
        )
        let invalidTelemetry = FirmwareLimitBatteryObservation(percent: 120, fullyCharged: false, externalConnected: true)
        expect(
            FirmwareLimitOneTimeChargeCoordinator.decision(job: job, observation: invalidTelemetry, now: now)
                == .restoreLimit(.telemetryUnavailable),
            "out-of-range telemetry is treated as unavailable"
        )
        print("FirmwareLimitReconciliationTests: PASS (\(checks) assertions; pure native one-time state machine)")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !condition() {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    private static func expectThrows(_ body: () throws -> Void, _ message: String) {
        checks += 1
        do {
            try body()
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        } catch {
            // Expected.
        }
    }
}
