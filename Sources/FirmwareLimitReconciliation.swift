import Foundation

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
    var cancelRequested: Bool

    init(
        jobID: String,
        restore: FirmwareLimitRequest,
        deadline: Date,
        cancelRequested: Bool = false
    ) throws {
        guard !jobID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              deadline.timeIntervalSince1970.isFinite else {
            throw FirmwareLimitOnceJobError.invalidMetadata
        }
        self.jobID = jobID
        restoreUpper = restore.upper
        restoreLower = restore.lower
        deadlineUnixSeconds = deadline.timeIntervalSince1970
        self.cancelRequested = cancelRequested
    }

    private enum CodingKeys: String, CodingKey {
        case jobID
        case restoreUpper
        case restoreLower
        case deadlineUnixSeconds
        case cancelRequested
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
        cancelRequested = try container.decodeIfPresent(Bool.self, forKey: .cancelRequested) ?? false
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

/// Pure state machine used by the privileged helper after battery refresh,
/// wake, relaunch, cancellation, and the 10-hour safety deadline.
enum FirmwareLimitOneTimeChargeCoordinator {
    static func decision(
        job: FirmwareLimitOnceJob,
        observation: FirmwareLimitBatteryObservation,
        now: Date,
        cancelRequested: Bool = false
    ) -> FirmwareLimitOnceDecision {
        let terminalReason: FirmwareLimitOnceRestoreReason?
        if cancelRequested || job.cancelRequested {
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
