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
    private var reconnectBaseline: FirmwareLimitOriginalStateSnapshot?

    var state = FirmwareLimitHelperStateResponse(
        state: FirmwareLimitState(activationByte: 0x00, upper: 80, lower: 78)
    )
    var pending = false
    var applyCount = 0
    var beginCount = 0
    var cancelCount = 0
    var restoreCount = 0
    var quitHandoffCount = 0
    var quitHandoffRemove = false
    var failQuitHandoff = false
    var failNextApply = false
    var failNextRestore = false
    var failNextRead = false
    var failLegacyZeroReadOnce = false
    var helperAvailable = true
    var helperInfoAvailable = true
    var reportedHelperVersion: Int?
    var reportedHelperBuildVersion: String?
    var readCount = 0
    var falselyReportRestoreSuccess = false
    var acConnected = true
    // Simulates the verified target machine with a safe, readable battery
    // supply. Fail-closed scenarios set this to false.
    var offlineRestoreAllowed = true
    var pendingLegacyRestore = false

    /// Simulates a reboot on firmware that resets bfD0/bfE0 to zero
    /// while the root-owned original snapshot survives.
    func simulateFirmwareBootReset() {
        reconnectBaseline = nil
        state = FirmwareLimitHelperStateResponse(
            state: FirmwareLimitState(activationByte: 0, upper: 0, lower: 0),
            identity: identity, snapshot: originalSnapshot
        )
    }

    func simulateReconnectZero() {
        state = FirmwareLimitHelperStateResponse(
            state: FirmwareLimitState(activationByte: 0, upper: 0, lower: 0),
            identity: identity, snapshot: originalSnapshot,
            hasReconnectBaseline: reconnectBaseline != nil
        )
    }

    func readHelperInfo() async throws -> FirmwareLimitHelperInfoResponse {
        guard helperAvailable else { throw FirmwareLimitHelperClientError.serviceUnavailable }
        guard helperInfoAvailable else {
            throw FirmwareLimitHelperClientError.remote("Installed Helper does not expose the required version handshake.")
        }
        return FirmwareLimitHelperInfoResponse(
            protocolVersion: reportedHelperVersion ?? state.helperVersion,
            buildVersion: reportedHelperBuildVersion ?? state.helperBuildVersion ?? "0.0.0"
        )
    }

    func readState() async throws -> FirmwareLimitHelperStateResponse {
        readCount += 1
        guard helperAvailable else { throw FirmwareLimitHelperClientError.serviceUnavailable }
        if failLegacyZeroReadOnce {
            failLegacyZeroReadOnce = false
            throw FirmwareLimitHelperClientError.remote(
                "Stored firmware limits are invalid: upper 0%, lower 0%."
            )
        }
        if failNextRead {
            failNextRead = false
            throw FixtureBackendError.injected
        }
        if reportedHelperVersion != nil || reportedHelperBuildVersion != nil {
            let data = try JSONEncoder().encode(state)
            var body = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            if let reportedHelperVersion { body["helperVersion"] = reportedHelperVersion }
            if let reportedHelperBuildVersion { body["helperBuildVersion"] = reportedHelperBuildVersion }
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
            if state.isInactiveUninitialized, let reconnectBaseline {
                originalSnapshot = reconnectBaseline
            } else {
                originalSnapshot = try FirmwareLimitOriginalStateSnapshot(
                    deviceIdentity: identity,
                    state: FirmwareLimitState(
                        activationByte: state.activationByte,
                        upper: state.upper,
                        lower: state.lower
                    )
                )
            }
        }
        reconnectBaseline = nil
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

    func suspendLimitForReconnect() async throws -> FirmwareLimitHelperOperationResponse {
        let baseline = originalSnapshot
        let restored = try await restoreOriginalState()
        if let baseline, !restored.state.active, !restored.state.hasOriginalStateSnapshot {
            reconnectBaseline = baseline
            state = FirmwareLimitHelperStateResponse(
                state: baseline.state, identity: identity, hasReconnectBaseline: true
            )
        }
        return FirmwareLimitHelperOperationResponse(state: state, oneTimePending: pending, message: restored.message)
    }

    func restoreOriginalState() async throws -> FirmwareLimitHelperOperationResponse {
        reconnectBaseline = nil
        restoreCount += 1
        if failNextRestore {
            failNextRestore = false
            throw FixtureBackendError.injected
        }
        if !acConnected && (state.active || originalSnapshot != nil) && (originalSnapshot == nil || !offlineRestoreAllowed) {
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
        // Match the real Helper's AC-only exact zero restore: offline
        // deactivation succeeds, the root snapshot remains pending.
        if !acConnected, var snapshot = originalSnapshot,
           snapshot.state.isInactiveUninitialized,
           !state.isInactiveUninitialized {
            snapshot.restoreRequested = true
            originalSnapshot = snapshot
            state = FirmwareLimitHelperStateResponse(
                state: FirmwareLimitState(activationByte: 0x00, upper: state.upper, lower: state.lower),
                identity: identity, snapshot: snapshot
            )
            pending = false
            throw FirmwareLimitCoreError.externalPowerRequired
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

    func enqueueQuitRecovery(removeComponents: Bool) async throws -> FirmwareLimitQuitRecoveryResponse {
        quitHandoffCount += 1
        quitHandoffRemove = removeComponents
        guard !failQuitHandoff else { throw FixtureBackendError.injected }
        return FirmwareLimitQuitRecoveryResponse(accepted: true, removeComponents: removeComponents)
    }

    func oneTimeChargeStatus() async throws -> FirmwareLimitHelperOneTimeStatusResponse {
        guard helperAvailable else { throw FirmwareLimitHelperClientError.serviceUnavailable }
        return FirmwareLimitHelperOneTimeStatusResponse(
            pending: pending,
            restoreUpper: pending ? state.upper : nil,
            deadlineUnixSeconds: pending ? Date().addingTimeInterval(3600).timeIntervalSince1970 : nil,
            cancelRequested: false
        )
    }
}
