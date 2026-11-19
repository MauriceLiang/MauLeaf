import Foundation
import Security
import Darwin

/// Privileged native firmware controller. The app never receives a raw SMC
/// transport; every write is guarded and verified inside this root process.
final class FirmwareLimitHelperService: NSObject, FirmwareLimitHelperProtocol {
    private let controller: FirmwareLimitController
    private let identityProvider: () -> FirmwareLimitDeviceIdentity
    private let isOnACPower: () -> Bool
    private let isAdministrator: () -> Bool
    private let batteryObservation: () -> FirmwareLimitBatteryObservation
    private let jobURL: URL
    private let originalStateURL: URL
    private let restoreRequestURL: URL
    private let backgroundRecoveryURL: URL
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
    private var monitorTimer: DispatchSourceTimer?
    private let watchdogTimeout: TimeInterval = 15

    init(
        transport: FirmwareLimitTransport,
        identityProvider: @escaping () -> FirmwareLimitDeviceIdentity = FirmwareLimitRuntime.identity,
        isOnACPower: @escaping () -> Bool = FirmwareLimitRuntime.isOnACPower,
        isAdministrator: @escaping () -> Bool = { FirmwareLimitRuntime.isAdministrator },
        batteryObservation: @escaping () -> FirmwareLimitBatteryObservation = FirmwareLimitRuntime.batteryObservation,
        jobURL: URL = URL(fileURLWithPath: "/Library/Application Support/MauLeaf/one-time-charge.json"),
        originalStateURL: URL = URL(fileURLWithPath: "/Library/Application Support/MauLeaf/original-firmware-state.json"),
        restoreRequestURL: URL = URL(fileURLWithPath: "/Library/Application Support/MauLeaf/restore-original-state.pending"),
        backgroundRecoveryURL: URL = URL(fileURLWithPath: "/Library/Application Support/MauLeaf/background-recovery.pending"),
        now: @escaping () -> Date = Date.init,
        monitorEnabled: Bool = true
    ) {
        controller = FirmwareLimitController(transport: transport)
        self.identityProvider = identityProvider
        self.isOnACPower = isOnACPower
        self.isAdministrator = isAdministrator
        self.batteryObservation = batteryObservation
        self.jobURL = jobURL
        self.originalStateURL = originalStateURL
        self.restoreRequestURL = restoreRequestURL
        self.backgroundRecoveryURL = backgroundRecoveryURL
        self.now = now
        self.monitorEnabled = monitorEnabled
        super.init()
        pendingJob = loadPendingJob()
        originalStateSnapshot = loadOriginalStateSnapshot()
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
            if pendingJob != nil {
                try? persistBackgroundRecoveryMarker()
            } else {
                try? FileManager.default.removeItem(at: backgroundRecoveryURL)
            }
        } else if originalStateSnapshot == nil && pendingJob == nil {
            try? FileManager.default.removeItem(at: restoreRequestURL)
            try? FileManager.default.removeItem(at: backgroundRecoveryURL)
        } else if pendingJob != nil {
            try? persistBackgroundRecoveryMarker()
        }
        if pendingJob != nil || originalStateSnapshot?.restoreRequested == true {
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
        return pendingJob != nil || originalStateSnapshot?.restoreRequested == true
    }

    func readState(withReply reply: @escaping (NSData?, NSString?) -> Void) {
        do {
            guard originalSnapshotLoadError == nil else {
                throw FirmwareLimitCoreError.invalidOriginalSnapshot
            }
            let state = try withHardwareWatchdog { try controller.readState() }
            let response = stateResponse(state)
            reply(try JSONEncoder().encode(response) as NSData, nil)
        } catch {
            reply(nil, error.localizedDescription as NSString)
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
        stateLock.unlock()
        return FirmwareLimitHelperStateResponse(
            state: state,
            identity: identityProvider(),
            snapshot: snapshot
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
        let snapshot = try FirmwareLimitOriginalStateSnapshot(
            deviceIdentity: identityProvider(),
            state: previous
        )
        try persistOriginalStateSnapshot(snapshot)
        return snapshot
    }

    private func restoreOriginalStateLocked() throws -> FirmwareLimitHelperOperationResponse {
        guard originalSnapshotLoadError == nil else {
            throw FirmwareLimitCoreError.invalidOriginalSnapshot
        }

        stateLock.lock()
        let snapshot = originalStateSnapshot
        stateLock.unlock()

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

            let permit = try writeRestorePermit(for: requested)
            let restored = try controller.restore(requested.state, permit: permit)
            try removePersistedOriginalStateSnapshot()
            stopMonitoringIfIdle()
            return FirmwareLimitHelperOperationResponse(
                state: stateResponse(restored),
                oneTimePending: false,
                message: "The exact original firmware state was restored and verified. MauLeaf's saved snapshot was removed."
            )
        }

        setPendingJob(nil)
        removePersistedJob()
        let current = try controller.readState()
        if current.isActive {
            let permit = try writePermit(confirmed: true)
            let inactive = try controller.deactivate(permit: permit)
            return FirmwareLimitHelperOperationResponse(
                state: stateResponse(inactive),
                oneTimePending: false,
                message: "Legacy limit disabled. Preview 4 did not save the pre-MauLeaf thresholds, so only the activation flag was cleared; the original threshold values cannot be reconstructed."
            )
        }
        return FirmwareLimitHelperOperationResponse(
            state: stateResponse(current),
            oneTimePending: false,
            message: "No MauLeaf original-state snapshot exists and the firmware limit is already inactive. No register values were changed."
        )
    }

    private func writeRestorePermit(
        for snapshot: FirmwareLimitOriginalStateSnapshot
    ) throws -> FirmwareLimitWritePermit {
        try FirmwareLimitWritePermit.authorizeRestore(
            identity: identityProvider(),
            snapshotIdentity: snapshot.deviceIdentity,
            context: FirmwareLimitWriteContext(
                isAdministrator: isAdministrator(),
                isOnACPower: isOnACPower(),
                userConfirmed: true
            )
        )
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
            guard isOnACPower() else { return }
            do {
                let permit = try writeRestorePermit(for: snapshot)
                _ = try controller.restore(snapshot.state, permit: permit)
                try removePersistedOriginalStateSnapshot()
                setPendingJob(nil)
                removePersistedJob()
                stopMonitoringIfIdle()
            } catch {
                NSLog("MauLeaf original firmware restore will retry: %@", error.localizedDescription)
            }
            return
        }

        guard let job else { stopMonitoringIfIdle(); return }

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
        let idle = pendingJob == nil && originalStateSnapshot?.restoreRequested != true
        stateLock.unlock()
        guard idle, FileManager.default.fileExists(atPath: backgroundRecoveryURL.path) else { return }
        try? FileManager.default.removeItem(at: backgroundRecoveryURL)
    }

    private func startMonitoring() {
        guard monitorEnabled else { return }
        stateLock.lock()
        guard (pendingJob != nil || originalStateSnapshot?.restoreRequested == true),
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
