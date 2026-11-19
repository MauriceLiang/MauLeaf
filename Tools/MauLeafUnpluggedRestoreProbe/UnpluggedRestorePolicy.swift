import Foundation

/// A deliberately separate experimental gate. Production MauLeaf keeps its
/// AC-power requirement; this test never changes that policy.
struct UnpluggedRestoreConditions {
    let identity: FirmwareLimitDeviceIdentity
    let originalSnapshot: FirmwareLimitOriginalStateSnapshot
    let currentState: FirmwareLimitState
    let isAdministrator: Bool
    let externalConnected: Bool?
    let pmsetReportsBatteryPower: Bool
    let batteryPercent: Int?
    let batteryIsCharging: Bool
    let conflictingProcess: String?
    let explicitlyConfirmed: Bool
}

enum UnpluggedRestoreProbeError: Error, LocalizedError, Equatable {
    case unsupportedHardware(String)
    case administratorRequired
    case powerStateUncertain
    case requiresUnpluggedMac
    case insufficientBattery
    case conflictingController(String)
    case missingOriginalInactiveSnapshot
    case snapshotIdentityMismatch
    case limitNotActive
    case confirmationMissing
    case firmwareStateChanged
    case firmwareWriteNotVerified(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedHardware(let reason): return reason
        case .administratorRequired: return "Use sudo for the experimental SMC write."
        case .powerStateUncertain: return "Cannot independently confirm battery-only power from IOKit and pmset."
        case .requiresUnpluggedMac: return "Unplug every external power source before running this test."
        case .insufficientBattery: return "Battery capacity must be readable and at least 30%, and the battery must not be charging."
        case .conflictingController(let name): return "A conflicting charging controller is running: \(name)."
        case .missingOriginalInactiveSnapshot:
            return "A valid MauLeaf original-state snapshot with bfF0=0x00 is required. The test refuses legacy/no-snapshot cases."
        case .snapshotIdentityMismatch: return "The snapshot does not match the current model and firmware."
        case .limitNotActive: return "bfF0 is not active (0x02). Nothing needs to be deactivated; the write test was not run."
        case .confirmationMissing: return "The exact interactive confirmation phrase was not entered."
        case .firmwareStateChanged: return "Firmware state changed unexpectedly. Refusing the next write."
        case .firmwareWriteNotVerified(let reason): return "Offline bfF0 deactivation was not verified: \(reason)."
        }
    }
}

enum UnpluggedRestorePolicy {
    static func authorize(_ context: UnpluggedRestoreConditions) throws {
        // Use the exact target/firmware/macOS allowlist, not a broad profile.
        if let reason = FirmwareLimitWritePermit.targetBlockReason(identity: context.identity) {
            throw UnpluggedRestoreProbeError.unsupportedHardware(reason)
        }
        guard context.isAdministrator else {
            throw UnpluggedRestoreProbeError.administratorRequired
        }
        guard let connected = context.externalConnected else {
            throw UnpluggedRestoreProbeError.powerStateUncertain
        }
        guard !connected, context.pmsetReportsBatteryPower else {
            throw UnpluggedRestoreProbeError.requiresUnpluggedMac
        }
        guard let percent = context.batteryPercent,
              (30...100).contains(percent),
              !context.batteryIsCharging else {
            throw UnpluggedRestoreProbeError.insufficientBattery
        }
        if let process = context.conflictingProcess {
            throw UnpluggedRestoreProbeError.conflictingController(process)
        }
        let snapshot = context.originalSnapshot
        guard snapshot.isValid, snapshot.state.activationByte == 0x00 else {
            throw UnpluggedRestoreProbeError.missingOriginalInactiveSnapshot
        }
        guard FirmwareLimitWritePermit.restoreBlockReason(
            identity: context.identity,
            snapshotIdentity: snapshot.deviceIdentity
        ) == nil else {
            throw UnpluggedRestoreProbeError.snapshotIdentityMismatch
        }
        guard context.currentState.isValid, context.currentState.isActive else {
            throw UnpluggedRestoreProbeError.limitNotActive
        }
        guard context.explicitlyConfirmed else {
            throw UnpluggedRestoreProbeError.confirmationMissing
        }
    }

    /// One permitted hardware mutation: write bfF0=0x00. Never enable a
    /// limit, never rewrite either threshold, never cut adapter input, and
    /// never roll back to the previously active (unsafe) activation byte.
    ///
    /// A preflight callback runs before EVERY write attempt; the real tool
    /// rechecks physical power state, hardware identity, snapshot, and app
    /// conflicts. Tests inject a fake callback and fake SMC transport.
    static func deactivate(
        transport: FirmwareLimitTransport,
        baseline: FirmwareLimitState,
        preflight: () throws -> Void,
        pause: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) throws -> FirmwareLimitState {
        guard baseline.isValid, baseline.isActive else {
            throw UnpluggedRestoreProbeError.limitNotActive
        }
        let controller = FirmwareLimitController(transport: transport)
        var lastFailure = "no verified readback"
        var wroteActivation = false

        for _ in 0..<3 {
            try preflight()
            let before = try controller.readState()
            guard before.upper == baseline.upper,
                  before.lower == baseline.lower else {
                throw UnpluggedRestoreProbeError.firmwareStateChanged
            }
            // If a concurrent actor already turned the limit off, do not
            // claim this probe proved offline write support.
            if !before.isActive {
                if wroteActivation { return before }
                throw UnpluggedRestoreProbeError.firmwareStateChanged
            }

            do {
                try transport.write(.activation, bytes: [0x00])
                wroteActivation = true
            } catch {
                lastFailure = String(describing: error)
                continue
            }

            pause(0.25)
            do {
                let verified = try controller.readState()
                guard verified.upper == baseline.upper,
                      verified.lower == baseline.lower else {
                    throw UnpluggedRestoreProbeError.firmwareStateChanged
                }
                if verified.activationByte == 0x00 { return verified }
                lastFailure = "bfF0 still reads 0x02 after writing 0x00"
            } catch let error as UnpluggedRestoreProbeError {
                throw error
            } catch {
                lastFailure = String(describing: error)
            }
        }
        // Never try to re-enable on failure: that could strand charging.
        throw UnpluggedRestoreProbeError.firmwareWriteNotVerified(lastFailure)
    }
}
