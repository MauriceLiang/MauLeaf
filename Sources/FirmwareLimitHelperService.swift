import Foundation
import Security
import Darwin

private struct FirmwareLimitLegacyRestoreRequest: Codable {
    let deviceIdentity: FirmwareLimitDeviceIdentity
    let requestedAt: Date
}

/// A previously verified inactive original configuration from this boot only.
private struct FirmwareReconnectBaseline: Codable {
    let bootSession: String
    let snapshot: FirmwareLimitOriginalStateSnapshot
}

/// Privileged native firmware controller. The app never receives a raw SMC
/// transport; every write is guarded and verified inside this root process.
final class FirmwareLimitHelperService: NSObject, FirmwareLimitHelperProtocol {
    private let controller: FirmwareLimitController
    private let identityProvider: () -> FirmwareLimitDeviceIdentity
    private let isOnACPower: () -> Bool
    private let isAdministrator: () -> Bool
    private let batteryObservation: () -> FirmwareLimitBatteryObservation
    private let pmsetReportsBatteryPower: () -> Bool
    private let isChargingNow: () -> Bool
    private let jobURL: URL
    private let originalStateURL: URL
    private let reconnectBaselineURL: URL
    private let bootSessionProvider: () -> String?
    private let restoreRequestURL: URL
    private let backgroundRecoveryURL: URL
    private let legacyRestoreURL: URL
    private let deferredUninstallURL: URL
    private let deferredUninstallScriptURL: URL
    private let now: () -> Date
    private let monitorEnabled: Bool
    private let hardwareLock = NSLock()
    private let watchdogLock = NSLock()
    private let stateLock = NSLock()
    private var operationSequence = 0
    private var activeOperation: Int?
    private var pendingJob: FirmwareLimitOnceJob?
    private var originalStateSnapshot: FirmwareLimitOriginalStateSnapshot?
    private var originalSnapshotLoadError: String?
    private var legacyRestoreRequest: FirmwareLimitLegacyRestoreRequest?
    private var legacyRestoreLoadError: String?
    private var deferredUninstallLaunched = false
    private var monitorTimer: DispatchSourceTimer?
    private let watchdogTimeout: TimeInterval = 15

    init(
        transport: FirmwareLimitTransport,
        identityProvider: @escaping () -> FirmwareLimitDeviceIdentity = FirmwareLimitRuntime.identity,
        isOnACPower: @escaping () -> Bool = FirmwareLimitRuntime.isOnACPower,
        isAdministrator: @escaping () -> Bool = { FirmwareLimitRuntime.isAdministrator },
        batteryObservation: @escaping () -> FirmwareLimitBatteryObservation = FirmwareLimitRuntime.batteryObservation,
        pmsetReportsBatteryPower: @escaping () -> Bool = FirmwareLimitRuntime.pmsetReportsBatteryPower,
        isChargingNow: @escaping () -> Bool = { MauLeafBatteryStatusReader.read().isCharging },
        jobURL: URL = URL(fileURLWithPath: "/Library/Application Support/MauLeaf/one-time-charge.json"),
        originalStateURL: URL = URL(fileURLWithPath: "/Library/Application Support/MauLeaf/original-firmware-state.json"),
        restoreRequestURL: URL = URL(fileURLWithPath: "/Library/Application Support/MauLeaf/restore-original-state.pending"),
        backgroundRecoveryURL: URL = URL(fileURLWithPath: "/Library/Application Support/MauLeaf/background-recovery.pending"),
        legacyRestoreURL: URL = URL(fileURLWithPath: "/Library/Application Support/MauLeaf/legacy-restore.json"),
        deferredUninstallURL: URL = URL(fileURLWithPath: "/Library/Application Support/MauLeaf/deferred-uninstall.pending"),
        deferredUninstallScriptURL: URL = URL(fileURLWithPath: "/Library/Application Support/MauLeaf/complete-deferred-uninstall.sh"),
        bootSessionProvider: @escaping () -> String? = FirmwareLimitRuntime.bootSessionID,
        now: @escaping () -> Date = Date.init,
        monitorEnabled: Bool = true
    ) {
        controller = FirmwareLimitController(transport: transport)
        self.identityProvider = identityProvider
        self.isOnACPower = isOnACPower
        self.isAdministrator = isAdministrator
        self.batteryObservation = batteryObservation
        self.pmsetReportsBatteryPower = pmsetReportsBatteryPower
        self.isChargingNow = isChargingNow
        self.jobURL = jobURL
        self.originalStateURL = originalStateURL
        self.reconnectBaselineURL = originalStateURL.deletingLastPathComponent().appendingPathComponent("reconnect-baseline.json")
        self.bootSessionProvider = bootSessionProvider
        self.restoreRequestURL = restoreRequestURL
        self.backgroundRecoveryURL = backgroundRecoveryURL
        self.legacyRestoreURL = legacyRestoreURL
        self.deferredUninstallURL = deferredUninstallURL
        self.deferredUninstallScriptURL = deferredUninstallScriptURL
        self.now = now
        self.monitorEnabled = monitorEnabled
        super.init()
        pendingJob = loadPendingJob()
        originalStateSnapshot = loadOriginalStateSnapshot()
        legacyRestoreRequest = loadLegacyRestoreRequest()
        if FileManager.default.fileExists(atPath: restoreRequestURL.path),
           var snapshot = originalStateSnapshot {
            snapshot.restoreRequested = true
            originalStateSnapshot = snapshot
        }
        if let snapshot = originalStateSnapshot, snapshot.restoreRequested {
            // Recreate missing markers so launchd can restart us after a crash.
            try? persistOriginalStateSnapshot(snapshot)
            try? persistBackgroundRecoveryMarker()
        } else if originalSnapshotLoadError != nil {
            // A corrupt snapshot cannot be retried automatically, but is kept
            // intact for diagnostics and must still block uninstallation.
            try? FileManager.default.removeItem(at: restoreRequestURL)
            if pendingJob != nil || legacyRestoreRequest != nil
                || FileManager.default.fileExists(atPath: deferredUninstallURL.path) {
                try? persistBackgroundRecoveryMarker()
            } else {
                try? FileManager.default.removeItem(at: backgroundRecoveryURL)
            }
        } else if originalStateSnapshot == nil && pendingJob == nil
                    && legacyRestoreRequest == nil
                    && !FileManager.default.fileExists(atPath: deferredUninstallURL.path) {
            try? FileManager.default.removeItem(at: restoreRequestURL)
            try? FileManager.default.removeItem(at: backgroundRecoveryURL)
        } else if pendingJob != nil {
            try? persistBackgroundRecoveryMarker()
        }
        if legacyRestoreRequest != nil || FileManager.default.fileExists(atPath: deferredUninstallURL.path) {
            try? persistBackgroundRecoveryMarker()
        }
        if hasPendingBackgroundRecovery {
            startMonitoring()
        }
    }

    var hasPendingOneTimeCharge: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return pendingJob != nil
    }

    var hasPendingBackgroundRecovery: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return pendingJob != nil
            || originalStateSnapshot?.restoreRequested == true
            || legacyRestoreRequest != nil
            || FileManager.default.fileExists(atPath: deferredUninstallURL.path)
    }

    /// Version discovery is independent of SMC reads and recovery-file validity.
    /// Older Helpers that do not implement this method are treated as a
    /// version mismatch by the app and replaced from its bundled resources.
    func readHelperInfo(withReply reply: @escaping (NSData?, NSString?) -> Void) {
        do {
            reply(try JSONEncoder().encode(FirmwareLimitHelperInfoResponse.current) as NSData, nil)
        } catch {
            reply(nil, error.localizedDescription as NSString)
        }
    }

    func readState(withReply reply: @escaping (NSData?, NSString?) -> Void) {
        do {
            guard originalSnapshotLoadError == nil else {
                throw FirmwareLimitCoreError.invalidOriginalSnapshot
            }
            let state = try withHardwareWatchdog { try readStateForDisplay() }
            let response = stateResponse(state)
            reply(try JSONEncoder().encode(response) as NSData, nil)
        } catch {
            reply(nil, error.localizedDescription as NSString)
        }
    }

    /// Only one invalid hardware shape (bfF0=active, upper/lower=0/0)
    /// is exposed to the UI as a *read-only* recovery diagnosis.
    /// Invalid ranges remain invalid for normal firmware writes.
    private func readStateForDisplay() throws -> FirmwareLimitState {
        do { return try controller.readState() }
        catch FirmwareLimitCoreError.invalidStoredBand {
            return try controller.readActiveZeroedForRecovery()
        }
    }

    func makePlan(upper: Int, lower: Int, withReply reply: @escaping (NSData?, NSString?) -> Void) {
        do {
            let request = try FirmwareLimitRequest(upper: upper, lower: lower)
            let response = FirmwareLimitHelperPlanResponse(
                plan: try withHardwareWatchdog { try controller.makePlan(for: request) }
            )
            reply(try JSONEncoder().encode(response) as NSData, nil)
        } catch {
            reply(nil, error.localizedDescription as NSString)
        }
    }

    func applyLimit(upper: Int, lower: Int, confirmed: Bool, withReply reply: @escaping (NSData?, NSString?) -> Void) {
        do {
            guard originalSnapshotLoadError == nil else {
                throw FirmwareLimitCoreError.invalidOriginalSnapshot
            }
            let request = try FirmwareLimitRequest(upper: upper, lower: lower)
            let response = try withHardwareWatchdog {
                guard !hasPendingOneTimeCharge else {
                    throw FirmwareLimitCoreError.transportFailure("A one-time full-charge task is active; cancel it before changing the limit.")
                }
                let permit = try writePermit(confirmed: confirmed)
                let previous = try controller.readState()
                let snapshot = try ensureOriginalStateSnapshot(beforeEnablingFrom: previous)
                do {
                    let state = try controller.configure(request, permit: permit)
                    return FirmwareLimitHelperOperationResponse(
                        state: stateResponse(state),
                        oneTimePending: false,
                        message: "The original firmware state was saved before enabling MauLeaf. The requested registers were written and read back; actual charging behavior still requires hardware verification."
                    )
                } catch {
                    do {
                        let restorePermit = try writeRestorePermit(for: snapshot)
                        _ = try controller.restore(snapshot.state, permit: restorePermit)
                        try removePersistedOriginalStateSnapshot()
                    } catch {
                        var pending = snapshot
                        pending.restoreRequested = true
                        try? persistOriginalStateSnapshot(pending)
                        startMonitoring()
                    }
                    throw error
                }
            }
            reply(try JSONEncoder().encode(response) as NSData, nil)
        } catch {
            reply(nil, error.localizedDescription as NSString)
        }
    }

    func beginOneTimeCharge(upper: Int, lower: Int, confirmed: Bool, withReply reply: @escaping (NSData?, NSString?) -> Void) {
        do {
            let request = try FirmwareLimitRequest(upper: upper, lower: lower)
            let response = try withHardwareWatchdog {
                guard !hasPendingOneTimeCharge else {
                    throw FirmwareLimitCoreError.transportFailure("A one-time full-charge task is already active.")
                }
                guard originalStateSnapshot != nil, originalStateSnapshot?.restoreRequested == false else {
                    throw FirmwareLimitCoreError.legacyActiveStateWithoutSnapshot
                }
                let permit = try writePermit(confirmed: confirmed)
                let previous = try controller.readState()
                guard previous.isActive,
                      previous.upper == request.upper,
                      previous.lower == request.lower else {
                    throw FirmwareLimitCoreError.readbackMismatch(
                        key: "bfF0/bfD0/bfE0",
                        expected: "active \(request.upper)/\(request.lower)",
                        actual: "\(previous.isActive ? "active" : "inactive") \(previous.upper)/\(previous.lower)"
                    )
                }
                let job = try FirmwareLimitOnceJob(
                    jobID: UUID().uuidString,
                    restore: request,
                    deadline: now().addingTimeInterval(10 * 60 * 60)
                )
                try persist(job)
                do {
                    let state = try controller.deactivate(permit: permit)
                    setPendingJob(job)
                    startMonitoring()
                    return FirmwareLimitHelperOperationResponse(
                        state: stateResponse(state),
                        oneTimePending: true,
                        message: "The native limit is temporarily disabled. The helper will restore the saved limit at 100%, on cancellation, or after 10 hours."
                    )
                } catch {
                    let recovery: String?
                    if let coreError = error as? FirmwareLimitCoreError,
                       case .transactionFailed(_, let detail) = coreError {
                        recovery = detail
                    } else {
                        recovery = nil
                    }
                    if let recovery,
                       !recovery.contains("previous firmware state was restored and verified") {
                        var recoveryJob = job
                        recoveryJob.cancelRequested = true
                        do {
                            try persist(recoveryJob)
                            setPendingJob(recoveryJob)
                            startMonitoring()
                        } catch {
                            NSLog("MauLeaf could not persist the native restore job: %@", error.localizedDescription)
                        }
                    } else {
                        removePersistedJob()
                    }
                    throw error
                }
            }
            reply(try JSONEncoder().encode(response) as NSData, nil)
        } catch {
            reply(nil, error.localizedDescription as NSString)
        }
    }

    func cancelOneTimeCharge(withReply reply: @escaping (NSData?, NSString?) -> Void) {
        do {
            let response = try withHardwareWatchdog {
                stateLock.lock()
                guard var job = pendingJob else {
                    stateLock.unlock()
                    let state = try controller.readState()
                    return FirmwareLimitHelperOperationResponse(
                        state: stateResponse(state),
                        oneTimePending: false,
                        message: "No one-time full-charge task is active."
                    )
                }
                job.cancelRequested = true
                stateLock.unlock()
                try persist(job)
                setPendingJob(job)
                monitorOneTimeChargeLocked()
                let state = try controller.readState()
                return FirmwareLimitHelperOperationResponse(
                    state: stateResponse(state),
                    oneTimePending: hasPendingOneTimeCharge,
                    message: hasPendingOneTimeCharge
                        ? "Cancellation is saved. The original limit will be restored when AC power is connected."
                        : "The original charging limit was restored and verified."
                )
            }
            reply(try JSONEncoder().encode(response) as NSData, nil)
        } catch {
            reply(nil, error.localizedDescription as NSString)
        }
    }

    /// Physical disconnect: restore the exact original state, retain only a
    /// same-boot, identity-bound baseline for the next authorized AC session.
    func suspendLimitForReconnect(withReply reply: @escaping (NSData?, NSString?) -> Void) {
        do {
            let response = try withHardwareWatchdog {
                guard isAdministrator(), batteryObservation().externalConnected == false,
                      pmsetReportsBatteryPower(), !isChargingNow(),
                      !FileManager.default.fileExists(atPath: deferredUninstallURL.path) else {
                    throw FirmwareLimitCoreError.transportFailure("Cannot verify a battery-only disconnect; no reconnect baseline was created.")
                }
                return try restoreOriginalStateLocked(retainReconnectBaseline: true)
            }
            reply(try JSONEncoder().encode(response) as NSData, nil)
        } catch {
            reply(nil, error.localizedDescription as NSString)
        }
    }

    func restoreOriginalState(withReply reply: @escaping (NSData?, NSString?) -> Void) {
        do {
            let response = try withHardwareWatchdog {
                try restoreOriginalStateLocked()
            }
            reply(try JSONEncoder().encode(response) as NSData, nil)
        } catch {
            reply(nil, error.localizedDescription as NSString)
        }
    }

    /// Used by the bundled uninstaller after the app has stopped. It performs
    /// the same verified restore without depending on a running XPC client.
    func restoreOriginalStateForUninstall() throws -> FirmwareLimitHelperOperationResponse {
        try withHardwareWatchdog {
            try restoreOriginalStateLocked()
        }
    }

    /// Read-only verification for the root-owned finalizer, which may run
    /// after the main app bundle has already been deleted.
    func verifyReadyForDeferredRemoval() throws {
        guard isAdministrator() else { throw FirmwareLimitCoreError.administratorRequired }
        stateLock.lock()
        let hasSnapshot = originalStateSnapshot != nil
        let hasLegacy = legacyRestoreRequest != nil
        let hasJob = pendingJob != nil
        stateLock.unlock()
        guard originalSnapshotLoadError == nil,
              legacyRestoreLoadError == nil,
              !hasSnapshot, !hasLegacy, !hasJob,
              !FileManager.default.fileExists(atPath: originalStateURL.path),
              !FileManager.default.fileExists(atPath: legacyRestoreURL.path),
              !FileManager.default.fileExists(atPath: restoreRequestURL.path),
              !FileManager.default.fileExists(atPath: jobURL.path),
              !FileManager.default.fileExists(atPath: reconnectBaselineURL.path) else {
            throw FirmwareLimitCoreError.transportFailure(
                "Pending or unverified firmware recovery data still exists."
            )
        }
        let firmware = try withHardwareWatchdog { try controller.readState() }
        guard !firmware.isActive else {
            throw FirmwareLimitCoreError.transportFailure(
                "The firmware limit is still active; do not remove its recovery helper."
            )
        }
    }

    func oneTimeChargeStatus(withReply reply: @escaping (NSData?, NSString?) -> Void) {
        stateLock.lock()
        let job = pendingJob
        stateLock.unlock()
        let response = FirmwareLimitHelperOneTimeStatusResponse(
            pending: job != nil,
            restoreUpper: job?.restoreUpper,
            deadlineUnixSeconds: job?.deadlineUnixSeconds,
            cancelRequested: job?.cancelRequested ?? false
        )
        do { reply(try JSONEncoder().encode(response) as NSData, nil) }
        catch { reply(nil, error.localizedDescription as NSString) }
    }

    /// Exposed internally for deterministic service tests.
    func runOneTimeMonitorTickForTesting() {
        monitorOneTimeCharge()
    }

    private func writePermit(confirmed: Bool) throws -> FirmwareLimitWritePermit {
        try FirmwareLimitWritePermit.authorize(
            identity: identityProvider(),
            context: FirmwareLimitWriteContext(
                isAdministrator: isAdministrator(),
                isOnACPower: isOnACPower(),
                userConfirmed: confirmed
            )
        )
    }

    private func stateResponse(_ state: FirmwareLimitState) -> FirmwareLimitHelperStateResponse {
        stateLock.lock()
        let snapshot = originalStateSnapshot
        let legacyPending = legacyRestoreRequest != nil
        stateLock.unlock()
        return FirmwareLimitHelperStateResponse(
            state: state,
            identity: identityProvider(),
            snapshot: snapshot,
            hasReconnectBaseline: snapshot == nil && verifiedReconnectBaseline() != nil,
            legacyRestorePending: legacyPending,
            durableRecoveryRecorded: FileManager.default.fileExists(
                atPath: backgroundRecoveryURL.path
            )
        )
    }

    private func ensureOriginalStateSnapshot(
        beforeEnablingFrom previous: FirmwareLimitState
    ) throws -> FirmwareLimitOriginalStateSnapshot {
        stateLock.lock()
        let existing = originalStateSnapshot
        stateLock.unlock()

        if let existing {
            guard existing.isValid,
                  FirmwareLimitWritePermit.restoreBlockReason(
                    identity: identityProvider(),
                    snapshotIdentity: existing.deviceIdentity
                  ) == nil else {
                throw FirmwareLimitCoreError.originalStateDeviceMismatch
            }
            guard !existing.restoreRequested else {
                throw FirmwareLimitCoreError.transportFailure("Original firmware restoration is pending; wait for it to finish before enabling a new limit.")
            }
            return existing
        }

        guard !previous.isActive else {
            throw FirmwareLimitCoreError.legacyActiveStateWithoutSnapshot
        }
        // Prefer a valid current hardware state. Only inactive 0/0 may
        // use a root-owned, same-boot baseline verified at unplug.
        let snapshot: FirmwareLimitOriginalStateSnapshot
        if previous.isValid {
            snapshot = try FirmwareLimitOriginalStateSnapshot(
                deviceIdentity: identityProvider(), state: previous
            )
        } else if previous.isInactiveUninitialized,
                  let baseline = verifiedReconnectBaseline(),
                  !FileManager.default.fileExists(atPath: deferredUninstallURL.path) {
            snapshot = baseline
        } else {
            throw FirmwareLimitCoreError.invalidStoredBand(upper: previous.upper, lower: previous.lower)
        }
        try persistOriginalStateSnapshot(snapshot)
        try clearReconnectBaseline()
        return snapshot
    }

    private func restoreOriginalStateLocked(retainReconnectBaseline: Bool = false) throws -> FirmwareLimitHelperOperationResponse {
        guard originalSnapshotLoadError == nil else {
            throw FirmwareLimitCoreError.invalidOriginalSnapshot
        }

        stateLock.lock()
        var snapshot = originalStateSnapshot
        stateLock.unlock()

        // An explicitly requested reset may restore a verified suspended
        // baseline if the live firmware became inactive 0/0. Promote it
        // durably before clearing the archive. Never invent thresholds.
        if !retainReconnectBaseline, snapshot == nil,
           let baseline = verifiedReconnectBaseline(),
           let live = try? controller.readState(), live.isInactiveUninitialized {
            try persistOriginalStateSnapshot(baseline)
            snapshot = baseline
        }

        if !retainReconnectBaseline {
            // Explicit disable, quit and the stable uninstall CLI end the
            // suspended session. The archive is never an active restore job.
            try clearReconnectBaseline()
        }

        if let snapshot {
            guard snapshot.isValid,
                  FirmwareLimitWritePermit.restoreBlockReason(
                    identity: identityProvider(),
                    snapshotIdentity: snapshot.deviceIdentity
                  ) == nil else {
                throw FirmwareLimitCoreError.originalStateDeviceMismatch
            }

            var requested = snapshot
            requested.restoreRequested = true
            try persistOriginalStateSnapshot(requested)
            setPendingJob(nil)
            removePersistedJob()
            startMonitoring()

            let current = try readStateForDisplay()
            // Even active zeroed thresholds may be restored from a verified
            // original snapshot on battery power. Offline permit validation
            // still requires exact hardware identity, both power sources
            // agreeing on battery, >=30% SoC and no charging before EACH write.
            let restored: FirmwareLimitState
            if current == requested.state {
                // All keys already match: verification requires no write
                // permit or external power, even below the 30% write floor.
                restored = current
            } else {
                let permit = try writeRestorePermit(for: requested)
                restored = try controller.restore(
                    requested.state,
                    permit: permit,
                    preflight: { [self] in
                        // Re-evaluate model, snapshot and power before
                        // every SMC write attempt, including retries.
                        _ = try writeRestorePermit(for: requested)
                    }
                )
            }
            if retainReconnectBaseline, !restored.isActive,
               restored == snapshot.state, let boot = bootSessionProvider(), !boot.isEmpty {
                var baseline = snapshot
                baseline.restoreRequested = false
                let data = try JSONEncoder().encode(FirmwareReconnectBaseline(bootSession: boot, snapshot: baseline))
                try data.write(to: reconnectBaselineURL, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: reconnectBaselineURL.path)
            }
            try removePersistedOriginalStateSnapshot()
            stopMonitoringIfIdle()
            triggerDeferredUninstallIfReady()
            return FirmwareLimitHelperOperationResponse(
                state: stateResponse(restored),
                oneTimePending: false,
                message: "The exact original firmware state was restored and verified. MauLeaf's saved snapshot was removed."
            )
        }

        guard legacyRestoreLoadError == nil else {
            throw FirmwareLimitCoreError.transportFailure(
                "The pending legacy firmware restoration record is corrupt. It was retained for manual recovery."
            )
        }
        let current = try controller.readState()
        if current.isActive {
            // A Preview 4 installation has no original threshold snapshot.
            // Persist an identity-bound deactivation request *before* checking
            // AC power, so an unplugged quit or uninstall never traps the user.
            let request = legacyRestoreRequest ?? FirmwareLimitLegacyRestoreRequest(
                deviceIdentity: identityProvider(),
                requestedAt: now()
            )
            guard FirmwareLimitWritePermit.restoreBlockReason(
                identity: identityProvider(),
                snapshotIdentity: request.deviceIdentity
            ) == nil else {
                throw FirmwareLimitCoreError.originalStateDeviceMismatch
            }
            try persistLegacyRestoreRequest(request)
            setPendingJob(nil)
            removePersistedJob()
            startMonitoring()

            let permit = try writeLegacyDisablePermit()
            let inactive = try controller.deactivate(permit: permit)
            try removeLegacyRestoreRequest()
            stopMonitoringIfIdle()
            triggerDeferredUninstallIfReady()
            return FirmwareLimitHelperOperationResponse(
                state: stateResponse(inactive),
                oneTimePending: false,
                message: "Legacy limit disabled. Preview 4 did not save the pre-MauLeaf thresholds, so only the activation flag was cleared; the original threshold values cannot be reconstructed."
            )
        }

        // Inactive firmware needs no SMC write to abandon a stale charge
        // job. Remove the durable record before clearing the in-memory job.
        if FileManager.default.fileExists(atPath: jobURL.path) {
            try FileManager.default.removeItem(at: jobURL)
        }
        setPendingJob(nil)
        removeBackgroundRecoveryMarkerIfIdle()
        if legacyRestoreRequest != nil {
            try removeLegacyRestoreRequest()
        }
        stopMonitoringIfIdle()
        triggerDeferredUninstallIfReady()
        return FirmwareLimitHelperOperationResponse(
            state: stateResponse(current),
            oneTimePending: false,
            message: "No MauLeaf original-state snapshot exists and the firmware limit is already inactive. No register values were changed."
        )
    }

    private func persistLegacyRestoreRequest(
        _ request: FirmwareLimitLegacyRestoreRequest
    ) throws {
        let directory = legacyRestoreURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        let data = try JSONEncoder().encode(request)
        try data.write(to: legacyRestoreURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: legacyRestoreURL.path
        )
        // KeepAlive persistence must succeed before the XPC caller can
        // observe/acknowledge an unplugged background restore request.
        try persistBackgroundRecoveryMarker()
        stateLock.lock()
        legacyRestoreRequest = request
        stateLock.unlock()
    }

    private func loadLegacyRestoreRequest() -> FirmwareLimitLegacyRestoreRequest? {
        guard FileManager.default.fileExists(atPath: legacyRestoreURL.path) else { return nil }
        do {
            return try JSONDecoder().decode(
                FirmwareLimitLegacyRestoreRequest.self,
                from: Data(contentsOf: legacyRestoreURL)
            )
        } catch {
            legacyRestoreLoadError = error.localizedDescription
            NSLog("MauLeaf legacy restore request is unreadable: %@", error.localizedDescription)
            return nil
        }
    }

    private func removeLegacyRestoreRequest() throws {
        if FileManager.default.fileExists(atPath: legacyRestoreURL.path) {
            try FileManager.default.removeItem(at: legacyRestoreURL)
        }
        stateLock.lock()
        legacyRestoreRequest = nil
        stateLock.unlock()
        removeBackgroundRecoveryMarkerIfIdle()
    }

    /// Legacy Preview 4 state has no original threshold snapshot. This
    /// permit can only clear bfF0 on the exact validated hardware identity;
    /// it never writes or invents bfD0/bfE0 values.
    private func writeLegacyDisablePermit() throws -> FirmwareLimitWritePermit {
        let identity = identityProvider()
        return try FirmwareLimitWritePermit.authorizeRestore(
            identity: identity,
            snapshotIdentity: identity,
            context: FirmwareLimitWriteContext(
                isAdministrator: isAdministrator(),
                isOnACPower: isOnACPower(),
                userConfirmed: true
            )
        )
    }

    private func writeRestorePermit(
        for snapshot: FirmwareLimitOriginalStateSnapshot
    ) throws -> FirmwareLimitWritePermit {
        let identity = identityProvider()
        if isOnACPower() {
            // Existing, compatible AC restore path remains available even
            // after macOS upgrades. Only firmware identity must still match.
            return try FirmwareLimitWritePermit.authorizeRestore(
                identity: identity,
                snapshotIdentity: snapshot.deviceIdentity,
                context: FirmwareLimitWriteContext(
                    isAdministrator: isAdministrator(),
                    isOnACPower: true,
                    userConfirmed: true
                )
            )
        }

        // A special, separately proven offline path. Other machines,
        // unknown power readings, old active snapshots, and low battery
        // fail closed and retain the original state for future recovery.
        let battery = batteryObservation()
        return try FirmwareLimitWritePermit.authorizeOfflineRestore(
            identity: identity,
            snapshot: snapshot,
            context: FirmwareLimitOfflineRestoreContext(
                isAdministrator: isAdministrator(),
                externalConnected: battery.externalConnected,
                pmsetReportsBatteryPower: pmsetReportsBatteryPower(),
                batteryPercent: battery.percent,
                isCharging: isChargingNow(),
                userConfirmed: true
            )
        )
    }

    private func verifiedReconnectBaseline() -> FirmwareLimitOriginalStateSnapshot? {
        guard let boot = bootSessionProvider(), !boot.isEmpty,
              !FileManager.default.fileExists(atPath: restoreRequestURL.path),
              !FileManager.default.fileExists(atPath: jobURL.path),
              !FileManager.default.fileExists(atPath: legacyRestoreURL.path),
              !FileManager.default.fileExists(atPath: deferredUninstallURL.path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: reconnectBaselineURL.path),
              attrs[.type] as? FileAttributeType == .typeRegular,
              (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid(),
              (attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600,
              let data = try? Data(contentsOf: reconnectBaselineURL),
              let baseline = try? JSONDecoder().decode(FirmwareReconnectBaseline.self, from: data),
              baseline.bootSession == boot, baseline.snapshot.isValid,
              !baseline.snapshot.state.isActive, !baseline.snapshot.restoreRequested,
              FirmwareLimitWritePermit.targetBlockReason(identity: identityProvider()) == nil,
              FirmwareLimitWritePermit.restoreBlockReason(identity: identityProvider(), snapshotIdentity: baseline.snapshot.deviceIdentity) == nil
        else { return nil }
        return baseline.snapshot
    }

    private func clearReconnectBaseline() throws {
        if FileManager.default.fileExists(atPath: reconnectBaselineURL.path) {
            try FileManager.default.removeItem(at: reconnectBaselineURL)
        }
    }

    private func persistOriginalStateSnapshot(
        _ snapshot: FirmwareLimitOriginalStateSnapshot
    ) throws {
        let directory = originalStateURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: originalStateURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: originalStateURL.path
        )
        stateLock.lock()
        originalStateSnapshot = snapshot
        stateLock.unlock()
        if snapshot.restoreRequested {
            try Data("restore".utf8).write(to: restoreRequestURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: restoreRequestURL.path
            )
            try persistBackgroundRecoveryMarker()
        } else {
            if FileManager.default.fileExists(atPath: restoreRequestURL.path) {
                try FileManager.default.removeItem(at: restoreRequestURL)
            }
            removeBackgroundRecoveryMarkerIfIdle()
        }
    }

    private func loadOriginalStateSnapshot() -> FirmwareLimitOriginalStateSnapshot? {
        guard FileManager.default.fileExists(atPath: originalStateURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: originalStateURL)
            let snapshot = try JSONDecoder().decode(FirmwareLimitOriginalStateSnapshot.self, from: data)
            guard snapshot.isValid else { throw FirmwareLimitCoreError.invalidOriginalSnapshot }
            return snapshot
        } catch {
            originalSnapshotLoadError = error.localizedDescription
            NSLog("MauLeaf original firmware snapshot could not be read: %@", error.localizedDescription)
            return nil
        }
    }

    private func removePersistedOriginalStateSnapshot() throws {
        if FileManager.default.fileExists(atPath: restoreRequestURL.path) {
            try FileManager.default.removeItem(at: restoreRequestURL)
        }
        if FileManager.default.fileExists(atPath: originalStateURL.path) {
            try FileManager.default.removeItem(at: originalStateURL)
        }
        stateLock.lock()
        originalStateSnapshot = nil
        stateLock.unlock()
        removeBackgroundRecoveryMarkerIfIdle()
    }

    private func monitorOneTimeCharge() {
        do {
            try withHardwareWatchdog { monitorOneTimeChargeLocked() }
        } catch {
            NSLog("MauLeaf native one-time charge monitor will retry: %@", error.localizedDescription)
        }
    }

    private func monitorOneTimeChargeLocked() {
        stateLock.lock()
        let snapshot = originalStateSnapshot
        let job = pendingJob
        stateLock.unlock()

        if let snapshot, snapshot.restoreRequested {
            do {
                let current = try readStateForDisplay()
                // A snapshot-bound offline recovery is permitted even
                // after an active 0/0 boot read, but never without the
                // already-validated offline restore preflight.
                if current != snapshot.state {
                    let permit = try writeRestorePermit(for: snapshot)
                    _ = try controller.restore(
                        snapshot.state,
                        permit: permit,
                        preflight: { [self] in
                            _ = try writeRestorePermit(for: snapshot)
                        }
                    )
                }
                try removePersistedOriginalStateSnapshot()
                setPendingJob(nil)
                removePersistedJob()
                stopMonitoringIfIdle()
                triggerDeferredUninstallIfReady()
            } catch {
                NSLog("MauLeaf original firmware restore will retry: %@", error.localizedDescription)
            }
            return
        }

        stateLock.lock()
        let legacy = legacyRestoreRequest
        stateLock.unlock()
        if let legacy {
            guard isOnACPower() else { return }
            do {
                guard FirmwareLimitWritePermit.restoreBlockReason(
                    identity: identityProvider(),
                    snapshotIdentity: legacy.deviceIdentity
                ) == nil else {
                    throw FirmwareLimitCoreError.originalStateDeviceMismatch
                }
                let current = try controller.readState()
                if current.isActive {
                    let permit = try writeLegacyDisablePermit()
                    _ = try controller.deactivate(permit: permit)
                }
                try removeLegacyRestoreRequest()
                setPendingJob(nil)
                removePersistedJob()
                stopMonitoringIfIdle()
                triggerDeferredUninstallIfReady()
            } catch {
                NSLog("MauLeaf legacy deactivation will retry: %@", error.localizedDescription)
            }
            return
        }

        guard let job else {
            triggerDeferredUninstallIfReady()
            stopMonitoringIfIdle()
            return
        }

        // An orphaned full-charge job cannot authorize a new limit.
        // If no trustworthy original snapshot survives, only clear a
        // stale job after verifying that the hardware is already inactive.
        guard let snapshot, snapshot.isValid, !snapshot.restoreRequested,
              FirmwareLimitWritePermit.restoreBlockReason(
                  identity: identityProvider(), snapshotIdentity: snapshot.deviceIdentity
              ) == nil else {
            if originalSnapshotLoadError == nil, legacyRestoreLoadError == nil,
               snapshot == nil, let live = try? controller.readState(), !live.isActive {
                do {
                    if FileManager.default.fileExists(atPath: jobURL.path) {
                        try FileManager.default.removeItem(at: jobURL)
                    }
                    setPendingJob(nil)
                    removeBackgroundRecoveryMarkerIfIdle()
                    stopMonitoringIfIdle()
                } catch {
                    NSLog("MauLeaf orphan job cleanup will retry: %@", error.localizedDescription)
                }
            }
            return
        }

        let observation = batteryObservation()
        let decision = FirmwareLimitOneTimeChargeCoordinator.decision(
            job: job,
            observation: observation,
            now: now()
        )
        switch decision {
        case .continueCharging, .waitForAC:
            return
        case .restoreLimit:
            guard isOnACPower(), let request = job.restoreRequest else { return }
            do {
                let permit = try writePermit(confirmed: true)
                _ = try controller.configure(request, permit: permit)
                setPendingJob(nil)
                removePersistedJob()
                stopMonitoringIfIdle()
            } catch {
                NSLog("MauLeaf native one-time charge restore will retry: %@", error.localizedDescription)
            }
        }
    }

    private func setPendingJob(_ job: FirmwareLimitOnceJob?) {
        stateLock.lock()
        pendingJob = job
        stateLock.unlock()
    }

    private func persist(_ job: FirmwareLimitOnceJob) throws {
        let directory = jobURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        let data = try JSONEncoder().encode(job)
        try data.write(to: jobURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: jobURL.path)
        try persistBackgroundRecoveryMarker()
    }

    private func loadPendingJob() -> FirmwareLimitOnceJob? {
        guard let data = try? Data(contentsOf: jobURL),
              let job = try? JSONDecoder().decode(FirmwareLimitOnceJob.self, from: data),
              job.restoreRequest != nil else { return nil }
        return job
    }

    private func removePersistedJob() {
        try? FileManager.default.removeItem(at: jobURL)
        removeBackgroundRecoveryMarkerIfIdle()
    }

    /// Only launch the independent removal script after a successful,
    /// independently verified restore. The script is installed outside the
    /// app bundle and remains available after the user removes MauLeaf.app.
    private func triggerDeferredUninstallIfReady() {
        // Standalone CLI uninstallation owns its own cleanup; only the
        // long-lived launchd helper may spawn deferred self-removal.
        guard monitorEnabled, isAdministrator(),
              FileManager.default.fileExists(atPath: deferredUninstallURL.path),
              FileManager.default.isExecutableFile(atPath: deferredUninstallScriptURL.path) else {
            return
        }
        stateLock.lock()
        let idle = originalStateSnapshot == nil
            && legacyRestoreRequest == nil
            && pendingJob == nil
            && !deferredUninstallLaunched
        stateLock.unlock()
        guard idle,
              !FileManager.default.fileExists(atPath: originalStateURL.path),
              !FileManager.default.fileExists(atPath: legacyRestoreURL.path),
              !FileManager.default.fileExists(atPath: jobURL.path),
              !FileManager.default.fileExists(atPath: restoreRequestURL.path),
              let firmware = try? controller.readState(),
              !firmware.isActive else { return }
        // A deferred full removal ends any suspended session as well.
        do { try clearReconnectBaseline() } catch { return }

        let process = Process()
        process.executableURL = deferredUninstallScriptURL
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] finished in
            guard finished.terminationStatus != 0, let self else { return }
            self.stateLock.lock()
            self.deferredUninstallLaunched = false
            self.stateLock.unlock()
            NSLog("MauLeaf deferred uninstaller exited with status %d; it will retry.",
                  finished.terminationStatus)
        }
        stateLock.lock()
        deferredUninstallLaunched = true
        stateLock.unlock()
        do {
            try process.run()
        } catch {
            stateLock.lock()
            deferredUninstallLaunched = false
            stateLock.unlock()
            NSLog("MauLeaf deferred uninstaller could not launch: %@", error.localizedDescription)
        }
    }

    private func persistBackgroundRecoveryMarker() throws {
        let directory = backgroundRecoveryURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        try Data("pending".utf8).write(to: backgroundRecoveryURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: backgroundRecoveryURL.path
        )
    }

    private func removeBackgroundRecoveryMarkerIfIdle() {
        stateLock.lock()
        let idle = pendingJob == nil
            && originalStateSnapshot?.restoreRequested != true
            && legacyRestoreRequest == nil
            && !FileManager.default.fileExists(atPath: deferredUninstallURL.path)
        stateLock.unlock()
        guard idle, FileManager.default.fileExists(atPath: backgroundRecoveryURL.path) else { return }
        try? FileManager.default.removeItem(at: backgroundRecoveryURL)
    }

    private func startMonitoring() {
        guard monitorEnabled else { return }
        stateLock.lock()
        guard (pendingJob != nil || originalStateSnapshot?.restoreRequested == true
               || legacyRestoreRequest != nil
               || FileManager.default.fileExists(atPath: deferredUninstallURL.path)),
              monitorTimer == nil else {
            stateLock.unlock()
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 20, repeating: 20)
        timer.setEventHandler { [weak self] in self?.monitorOneTimeCharge() }
        monitorTimer = timer
        stateLock.unlock()
        timer.resume()
    }

    private func stopMonitoringIfIdle() {
        stateLock.lock()
        guard pendingJob == nil,
              originalStateSnapshot?.restoreRequested != true,
              legacyRestoreRequest == nil,
              !FileManager.default.fileExists(atPath: deferredUninstallURL.path),
              let timer = monitorTimer else {
            stateLock.unlock()
            return
        }
        monitorTimer = nil
        stateLock.unlock()
        timer.cancel()
    }

    /// SMC calls are synchronous kernel calls with no cancellation API. If one
    /// wedges, terminate this helper process so launchd can start a clean
    /// instance on the next request rather than leaving the app blocked.
    private func withHardwareWatchdog<T>(_ body: () throws -> T) throws -> T {
        hardwareLock.lock()
        defer { hardwareLock.unlock() }

        watchdogLock.lock()
        operationSequence += 1
        let token = operationSequence
        activeOperation = token
        watchdogLock.unlock()

        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + watchdogTimeout
        ) { [weak self] in
            guard let self else { return }
            self.watchdogLock.lock()
            let shouldTerminate = self.activeOperation == token
            self.watchdogLock.unlock()
            if shouldTerminate { exit(3) }
        }

        defer {
            watchdogLock.lock()
            if activeOperation == token { activeOperation = nil }
            watchdogLock.unlock()
        }
        return try body()
    }
}

/// Launchd starts this process on the first Mach-service request. Once the
/// last XPC client disconnects, the helper exits after a short idle window so
/// the root process does not remain resident indefinitely.
final class FirmwareLimitHelperListener: NSObject, NSXPCListenerDelegate {
    static let machServiceName = "com.local.chargecap.firmware-helper"
    static let authorizedClientIdentifier = "com.local.chargecap"
    static let idleExitDelay: TimeInterval = 20

    private let listener: NSXPCListener
    private let service: FirmwareLimitHelperService
    private let stateLock = NSLock()
    private var activeConnections = 0
    private var idleGeneration = 0

    init(service: FirmwareLimitHelperService = FirmwareLimitHelperService(
        transport: AppleSMCFirmwareLimitTransport()
    )) {
        self.service = service
        listener = NSXPCListener(machServiceName: Self.machServiceName)
        super.init()
        listener.delegate = self
    }

    func run() {
        listener.resume()
        scheduleIdleExit()
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        guard Self.clientIdentifier(for: connection.processIdentifier)
                == Self.authorizedClientIdentifier else {
            return false
        }

        stateLock.lock()
        activeConnections += 1
        idleGeneration += 1
        stateLock.unlock()

        connection.exportedInterface = NSXPCInterface(with: FirmwareLimitHelperProtocol.self)
        connection.exportedObject = service
        connection.invalidationHandler = { [weak self] in
            self?.clientDidDisconnect()
        }
        connection.resume()
        return true
    }

    private func clientDidDisconnect() {
        stateLock.lock()
        activeConnections = max(0, activeConnections - 1)
        stateLock.unlock()
        scheduleIdleExit()
    }

    private func scheduleIdleExit() {
        stateLock.lock()
        idleGeneration += 1
        let generation = idleGeneration
        stateLock.unlock()

        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + Self.idleExitDelay
        ) { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let idle = self.activeConnections == 0 && self.idleGeneration == generation
            self.stateLock.unlock()
            if idle {
                if self.service.hasPendingBackgroundRecovery {
                    self.scheduleIdleExit()
                } else {
                    exit(0)
                }
            }
        }
    }

    private static func clientIdentifier(for pid: pid_t) -> String? {
        var guestCode: SecCode?
        let attributes = [kSecGuestAttributePid as String: pid] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &guestCode) == errSecSuccess,
              let guestCode else {
            return nil
        }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(guestCode, [], &staticCode) == errSecSuccess,
              let staticCode else {
            return nil
        }

        var signingInformation: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &signingInformation) == errSecSuccess,
              let values = signingInformation as? [String: Any] else {
            return nil
        }
        return values[kSecCodeInfoIdentifier as String] as? String
    }
}
