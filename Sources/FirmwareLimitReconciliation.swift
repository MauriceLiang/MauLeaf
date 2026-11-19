import Foundation

enum FirmwareLimitReconciliationAction: Equatable {
    case noChange
    case configure(FirmwareLimitRequest)
    case deactivate
    case unsupported(String)
}

/// Reconciles the observed firmware registers with the action selected by
/// MauLeaf settings. Safe to run after app launch or wake because it is pure.
enum FirmwareLimitReconciliationPolicy {
    static func action(
        for desired: FirmwareLimitPolicyAction,
        observed: FirmwareLimitState
    ) -> FirmwareLimitReconciliationAction {
        switch desired {
        case .configure(let request):
            if observed.isActive,
               observed.upper == request.upper,
               observed.lower == request.lower {
                return .noChange
            }
            return .configure(request)

        case .configureAndEnableAdapterCut:
            return .unsupported("Adapter-cut semantics have not been validated on this hardware.")

        case .deactivate:
            return observed.isActive ? .deactivate : .noChange

        case .oneTimeFullCharge:
            // The one-time coordinator owns the restore job. During the
            // temporary full-charge window the firmware limit should be off.
            return observed.isActive ? .deactivate : .noChange

        case .unsupported(let reason):
            return .unsupported(reason)
        }
    }
}

enum FirmwareLimitOnceJobError: Error, LocalizedError {
    case invalidMetadata

    var errorDescription: String? {
        "The persisted one-time charge job is invalid."
    }
}

struct FirmwareLimitOnceJob: Codable, Equatable {
    let jobID: String
    let restoreUpper: Int
    let restoreLower: Int
    let deadlineUnixSeconds: Double

    init(jobID: String, restore: FirmwareLimitRequest, deadline: Date) throws {
        guard !jobID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              deadline.timeIntervalSince1970.isFinite else {
            throw FirmwareLimitOnceJobError.invalidMetadata
        }
        self.jobID = jobID
        restoreUpper = restore.upper
        restoreLower = restore.lower
        deadlineUnixSeconds = deadline.timeIntervalSince1970
    }

    private enum CodingKeys: String, CodingKey {
        case jobID
        case restoreUpper
        case restoreLower
        case deadlineUnixSeconds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let jobID = try container.decode(String.self, forKey: .jobID)
        let upper = try container.decode(Int.self, forKey: .restoreUpper)
        let lower = try container.decode(Int.self, forKey: .restoreLower)
        let deadline = try container.decode(Double.self, forKey: .deadlineUnixSeconds)
        guard !jobID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              deadline.isFinite else {
            throw FirmwareLimitOnceJobError.invalidMetadata
        }
        _ = try FirmwareLimitRequest(upper: upper, lower: lower)
        self.jobID = jobID
        restoreUpper = upper
        restoreLower = lower
        deadlineUnixSeconds = deadline
    }

    var restoreRequest: FirmwareLimitRequest? {
        try? FirmwareLimitRequest(upper: restoreUpper, lower: restoreLower)
    }

    func isExpired(at date: Date) -> Bool {
        date.timeIntervalSince1970 >= deadlineUnixSeconds
    }
}

struct FirmwareLimitBatteryObservation: Equatable {
    let percent: Int?
    let fullyCharged: Bool?
    let externalConnected: Bool?
}

enum FirmwareLimitOnceRestoreReason: String, Codable {
    case fullyCharged
    case deadlineExpired
    case telemetryUnavailable
    case cancelled
    case waitingForAC
}

enum FirmwareLimitOnceDecision: Equatable {
    case continueCharging
    case restoreLimit(FirmwareLimitOnceRestoreReason)
    case waitForAC(FirmwareLimitOnceRestoreReason)
}

/// Pure state machine for the existing "charge to 100% once" setting.
/// The caller persists the job and invokes this policy after battery refresh,
/// wake, app relaunch, or cancellation.
enum FirmwareLimitOneTimeChargeCoordinator {
    static func decision(
        job: FirmwareLimitOnceJob,
        observation: FirmwareLimitBatteryObservation,
        now: Date,
        cancelRequested: Bool = false
    ) -> FirmwareLimitOnceDecision {
        let terminalReason: FirmwareLimitOnceRestoreReason?
        if cancelRequested {
            terminalReason = .cancelled
        } else if job.isExpired(at: now) {
            terminalReason = .deadlineExpired
        } else if observation.fullyCharged == true || observation.percent == 100 {
            terminalReason = .fullyCharged
        } else {
            terminalReason = nil
        }

        if let terminalReason {
            return observation.externalConnected == true
                ? .restoreLimit(terminalReason)
                : .waitForAC(terminalReason)
        }

        guard observation.externalConnected == true else {
            return .waitForAC(.waitingForAC)
        }

        guard let percent = observation.percent, (0...100).contains(percent) else {
            return .restoreLimit(.telemetryUnavailable)
        }

        return .continueCharging
    }

    static func restoreRequest(
        for decision: FirmwareLimitOnceDecision,
        job: FirmwareLimitOnceJob
    ) -> FirmwareLimitRequest? {
        guard case .restoreLimit = decision else { return nil }
        return job.restoreRequest
    }
}
