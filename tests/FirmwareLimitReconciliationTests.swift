import Foundation

@main
private enum FirmwareLimitReconciliationTests {
    private static var checks = 0

    static func main() throws {
        try testStartupAndWakeReconciliation()
        try testOneTimeJobLifecycle()
        print("FirmwareLimitReconciliationTests: PASS (\(checks) assertions; no hardware writes)")
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

    private static func testStartupAndWakeReconciliation() throws {
        let request = try FirmwareLimitRequest(upper: 80, lower: 78)
        let matching = FirmwareLimitState(activationByte: 0x02, upper: 80, lower: 78)
        expect(
            FirmwareLimitReconciliationPolicy.action(for: .configure(request), observed: matching) == .noChange,
            "startup/wake does not rewrite an already matching active limit"
        )

        let inactive = FirmwareLimitState(activationByte: 0x00, upper: 80, lower: 78)
        expect(
            FirmwareLimitReconciliationPolicy.action(for: .configure(request), observed: inactive) == .configure(request),
            "inactive firmware state requests reconfiguration"
        )

        let mismatched = FirmwareLimitState(activationByte: 0x02, upper: 85, lower: 83)
        expect(
            FirmwareLimitReconciliationPolicy.action(for: .configure(request), observed: mismatched) == .configure(request),
            "mismatched thresholds request reconfiguration"
        )

        expect(
            FirmwareLimitReconciliationPolicy.action(for: .deactivate, observed: matching) == .deactivate,
            "full-always policy disables an active limit"
        )
        expect(
            FirmwareLimitReconciliationPolicy.action(for: .deactivate, observed: inactive) == .noChange,
            "full-always policy does not redundantly disable an inactive limit"
        )
        expect(
            FirmwareLimitReconciliationPolicy.action(
                for: .oneTimeFullCharge(restore: request, target: 100),
                observed: matching
            ) == .deactivate,
            "one-time full-charge window disables an active limit"
        )
        if case .unsupported = FirmwareLimitReconciliationPolicy.action(
            for: .configureAndEnableAdapterCut(request),
            observed: inactive
        ) {
            expect(true, "unverified adapter-cut operation is blocked")
        } else {
            expect(false, "adapter-cut operation must remain blocked")
        }
    }

    private static func testOneTimeJobLifecycle() throws {
        let request = try FirmwareLimitRequest(upper: 80, lower: 78)
        let now = Date(timeIntervalSince1970: 1_000)
        let job = try FirmwareLimitOnceJob(
            jobID: "test-once-job",
            restore: request,
            deadline: Date(timeIntervalSince1970: 2_000)
        )
        expect(job.restoreRequest == request, "one-time job persists the exact original limit")
        expect(!job.isExpired(at: now), "job remains active before its deadline")
        expect(job.isExpired(at: Date(timeIntervalSince1970: 2_000)), "job expires at its deadline")
        let encoded = try JSONEncoder().encode(job)
        let decoded = try JSONDecoder().decode(FirmwareLimitOnceJob.self, from: encoded)
        expect(decoded == job, "one-time job survives JSON persistence and reload")
        expectThrows({
            _ = try FirmwareLimitOnceJob(jobID: " ", restore: request, deadline: now)
        }, "empty job identifiers are rejected")
        let invalidJobJSON = Data(
            #"{"jobID":"invalid","restoreUpper":101,"restoreLower":99,"deadlineUnixSeconds":2000}"#.utf8
        )
        expectThrows({
            _ = try JSONDecoder().decode(FirmwareLimitOnceJob.self, from: invalidJobJSON)
        }, "invalid persisted restore thresholds are rejected")

        let charging = FirmwareLimitBatteryObservation(
            percent: 84, fullyCharged: false, externalConnected: true
        )
        expect(
            FirmwareLimitOneTimeChargeCoordinator.decision(job: job, observation: charging, now: now) == .continueCharging,
            "charging continues while AC is connected and target is not reached"
        )

        let full = FirmwareLimitBatteryObservation(
            percent: 100, fullyCharged: true, externalConnected: true
        )
        let fullDecision = FirmwareLimitOneTimeChargeCoordinator.decision(
            job: job, observation: full, now: now
        )
        expect(fullDecision == .restoreLimit(.fullyCharged), "100% completion requests limit restoration")
        expect(
            FirmwareLimitOneTimeChargeCoordinator.restoreRequest(for: fullDecision, job: job) == request,
            "completion restores the saved upper/lower pair"
        )

        let disconnected = FirmwareLimitBatteryObservation(
            percent: 100, fullyCharged: true, externalConnected: false
        )
        expect(
            FirmwareLimitOneTimeChargeCoordinator.decision(job: job, observation: disconnected, now: now)
                == .waitForAC(.fullyCharged),
            "completion while unplugged defers restoration until AC returns"
        )

        let unknownPower = FirmwareLimitBatteryObservation(
            percent: 84, fullyCharged: false, externalConnected: nil
        )
        expect(
            FirmwareLimitOneTimeChargeCoordinator.decision(job: job, observation: unknownPower, now: now)
                == .waitForAC(.waitingForAC),
            "unknown adapter state never assumes AC is connected"
        )

        let expired = FirmwareLimitOneTimeChargeCoordinator.decision(
            job: job,
            observation: charging,
            now: Date(timeIntervalSince1970: 2_001)
        )
        expect(expired == .restoreLimit(.deadlineExpired), "expired one-time job restores the saved limit")

        let cancelled = FirmwareLimitOneTimeChargeCoordinator.decision(
            job: job, observation: charging, now: now, cancelRequested: true
        )
        expect(cancelled == .restoreLimit(.cancelled), "user cancellation restores the saved limit")

        let cancelledUnplugged = FirmwareLimitOneTimeChargeCoordinator.decision(
            job: job,
            observation: disconnected,
            now: now,
            cancelRequested: true
        )
        expect(cancelledUnplugged == .waitForAC(.cancelled), "cancellation while unplugged remains pending")

        let missingTelemetry = FirmwareLimitBatteryObservation(
            percent: nil, fullyCharged: nil, externalConnected: true
        )
        expect(
            FirmwareLimitOneTimeChargeCoordinator.decision(job: job, observation: missingTelemetry, now: now)
                == .restoreLimit(.telemetryUnavailable),
            "missing battery telemetry on AC restores the limit instead of leaving full-charge mode active"
        )

        let invalidTelemetry = FirmwareLimitBatteryObservation(
            percent: 120, fullyCharged: false, externalConnected: true
        )
        expect(
            FirmwareLimitOneTimeChargeCoordinator.decision(job: job, observation: invalidTelemetry, now: now)
                == .restoreLimit(.telemetryUnavailable),
            "out-of-range battery telemetry is treated as unavailable"
        )
    }
}
