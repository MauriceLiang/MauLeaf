import Foundation

enum FixtureBackendError: Error {
    case injected
}

final class FixtureNativeFirmwareBackend: NativeFirmwareBackend {
    private let identity = FirmwareLimitDeviceIdentity(
        modelIdentifier: "MacBookPro18,1",
        systemFirmware: "mBoot-20457.41.3",
        macOSMajorVersion: 15,
        architecture: "arm64"
    )
    private var originalSnapshot: FirmwareLimitOriginalStateSnapshot?

    var state = FirmwareLimitHelperStateResponse(
        state: FirmwareLimitState(activationByte: 0x00, upper: 80, lower: 78)
    )
    var pending = false
    var applyCount = 0
    var beginCount = 0
    var cancelCount = 0
    var restoreCount = 0
    var failNextApply = false
    var failNextRestore = false
    var failNextRead = false
    var helperAvailable = true
    var reportedHelperVersion: Int?
    var readCount = 0
    var falselyReportRestoreSuccess = false
    var acConnected = true
    // Simulates the verified target machine with a safe, readable battery
    // supply. Fail-closed scenarios set this to false.
    var offlineRestoreAllowed = true
    var pendingLegacyRestore = false

    func readState() async throws -> FirmwareLimitHelperStateResponse {
        readCount += 1
        guard helperAvailable else { throw FirmwareLimitHelperClientError.serviceUnavailable }
        if failNextRead {
            failNextRead = false
            throw FixtureBackendError.injected
        }
        if let reportedHelperVersion {
            let data = try JSONEncoder().encode(state)
            var body = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            body["helperVersion"] = reportedHelperVersion
            return try JSONDecoder().decode(
                FirmwareLimitHelperStateResponse.self,
                from: JSONSerialization.data(withJSONObject: body)
            )
        }
        return state
    }

    func applyLimit(upper: Int, lower: Int, confirmed: Bool) async throws -> FirmwareLimitHelperOperationResponse {
        applyCount += 1
        guard confirmed else { throw FixtureBackendError.injected }
        if failNextApply {
            failNextApply = false
            throw FixtureBackendError.injected
        }
        if originalSnapshot == nil {
            originalSnapshot = try! FirmwareLimitOriginalStateSnapshot(
                deviceIdentity: identity,
                state: FirmwareLimitState(
                    activationByte: state.activationByte,
                    upper: state.upper,
                    lower: state.lower
                )
            )
        }
        state = FirmwareLimitHelperStateResponse(
            state: FirmwareLimitState(activationByte: 0x02, upper: upper, lower: lower),
            identity: identity,
            snapshot: originalSnapshot
        )
        return FirmwareLimitHelperOperationResponse(
            state: state,
            oneTimePending: false,
            message: "Fake native firmware registers were written and read back."
        )
    }

    func beginOneTimeCharge(upper: Int, lower: Int, confirmed: Bool) async throws -> FirmwareLimitHelperOperationResponse {
        beginCount += 1
        guard confirmed, originalSnapshot != nil, state.active,
              state.upper == upper, state.lower == lower else {
            throw FixtureBackendError.injected
        }
        state = FirmwareLimitHelperStateResponse(
            state: FirmwareLimitState(activationByte: 0x00, upper: upper, lower: lower),
            identity: identity,
            snapshot: originalSnapshot
        )
        pending = true
        return FirmwareLimitHelperOperationResponse(
            state: state,
            oneTimePending: true,
            message: "Fake native one-time task started."
        )
    }

    func cancelOneTimeCharge() async throws -> FirmwareLimitHelperOperationResponse {
        cancelCount += 1
        state = FirmwareLimitHelperStateResponse(
            state: FirmwareLimitState(activationByte: 0x02, upper: state.upper, lower: state.lower),
            identity: identity,
            snapshot: originalSnapshot
        )
        pending = false
        return FirmwareLimitHelperOperationResponse(
            state: state,
            oneTimePending: false,
            message: "Fake native limit restored."
        )
    }

    func restoreOriginalState() async throws -> FirmwareLimitHelperOperationResponse {
        restoreCount += 1
        if failNextRestore {
            failNextRestore = false
            throw FixtureBackendError.injected
        }
        if !acConnected && (originalSnapshot == nil || !offlineRestoreAllowed) {
            if var snapshot = originalSnapshot {
                snapshot.restoreRequested = true
                originalSnapshot = snapshot
                state = FirmwareLimitHelperStateResponse(
                    state: FirmwareLimitState(
                        activationByte: state.activationByte,
                        upper: state.upper,
                        lower: state.lower
                    ),
                    identity: identity, snapshot: snapshot
                )
            } else if state.active {
                pendingLegacyRestore = true
                state = FirmwareLimitHelperStateResponse(
                    state: FirmwareLimitState(
                        activationByte: state.activationByte,
                        upper: state.upper,
                        lower: state.lower
                    ),
                    identity: identity, legacyRestorePending: true
                )
            }
            pending = false
            throw FixtureBackendError.injected
        }
        if falselyReportRestoreSuccess {
            falselyReportRestoreSuccess = false
            let fabricated = FirmwareLimitHelperStateResponse(
                state: FirmwareLimitState(activationByte: 0x00, upper: 80, lower: 78),
                identity: identity
            )
            return FirmwareLimitHelperOperationResponse(
                state: fabricated,
                oneTimePending: false,
                message: "Fault-injected false restore acknowledgment."
            )
        }
        if let originalSnapshot {
            state = FirmwareLimitHelperStateResponse(
                state: originalSnapshot.state,
                identity: identity
            )
            self.originalSnapshot = nil
            pendingLegacyRestore = false
        } else if state.active {
            state = FirmwareLimitHelperStateResponse(
                state: FirmwareLimitState(activationByte: 0x00, upper: state.upper, lower: state.lower),
                identity: identity
            )
        }
        pending = false
        pendingLegacyRestore = false
        state = FirmwareLimitHelperStateResponse(
            state: FirmwareLimitState(
                activationByte: state.activationByte, upper: state.upper, lower: state.lower
            ),
            identity: identity
        )
        return FirmwareLimitHelperOperationResponse(
            state: state,
            oneTimePending: false,
            message: "Fake original firmware state restored and verified."
        )
    }

    func oneTimeChargeStatus() async throws -> FirmwareLimitHelperOneTimeStatusResponse {
        guard helperAvailable else { throw FirmwareLimitHelperClientError.serviceUnavailable }
        FirmwareLimitHelperOneTimeStatusResponse(
            pending: pending,
            restoreUpper: pending ? state.upper : nil,
            deadlineUnixSeconds: pending ? Date().addingTimeInterval(3600).timeIntervalSince1970 : nil,
            cancelRequested: false
        )
    }
}
