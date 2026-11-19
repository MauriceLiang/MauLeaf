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
    private let now: () -> Date
    private let monitorEnabled: Bool
    private let hardwareLock = NSLock()
    private let watchdogLock = NSLock()
    private let stateLock = NSLock()
    private var operationSequence = 0
    private var activeOperation: Int?
    private var pendingJob: FirmwareLimitOnceJob?
    private var monitorTimer: DispatchSourceTimer?
    private let watchdogTimeout: TimeInterval = 15

    init(
        transport: FirmwareLimitTransport,
        identityProvider: @escaping () -> FirmwareLimitDeviceIdentity = FirmwareLimitRuntime.identity,
        isOnACPower: @escaping () -> Bool = FirmwareLimitRuntime.isOnACPower,
        isAdministrator: @escaping () -> Bool = { FirmwareLimitRuntime.isAdministrator },
        batteryObservation: @escaping () -> FirmwareLimitBatteryObservation = FirmwareLimitRuntime.batteryObservation,
        jobURL: URL = URL(fileURLWithPath: "/Library/Application Support/MauLeaf/one-time-charge.json"),
        now: @escaping () -> Date = Date.init,
        monitorEnabled: Bool = true
    ) {
        controller = FirmwareLimitController(transport: transport)
        self.identityProvider = identityProvider
        self.isOnACPower = isOnACPower
        self.isAdministrator = isAdministrator
        self.batteryObservation = batteryObservation
        self.jobURL = jobURL
        self.now = now
        self.monitorEnabled = monitorEnabled
        super.init()
        pendingJob = loadPendingJob()
        if pendingJob != nil { startMonitoring() }
    }

    var hasPendingOneTimeCharge: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return pendingJob != nil
    }

    func readState(withReply reply: @escaping (NSData?, NSString?) -> Void) {
        do {
            let response = FirmwareLimitHelperStateResponse(
                state: try withHardwareWatchdog { try controller.readState() }
            )
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
            let request = try FirmwareLimitRequest(upper: upper, lower: lower)
            let response = try withHardwareWatchdog {
                guard !hasPendingOneTimeCharge else {
                    throw FirmwareLimitCoreError.transportFailure("A one-time full-charge task is active; cancel it before changing the limit.")
                }
                let permit = try writePermit(confirmed: confirmed)
                let state = try controller.configure(request, permit: permit)
                return FirmwareLimitHelperOperationResponse(
                    state: FirmwareLimitHelperStateResponse(state: state),
                    oneTimePending: false,
                    message: "Firmware registers were written and read back successfully. Real charging enforcement still requires hardware observation."
                )
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
                        state: FirmwareLimitHelperStateResponse(state: state),
                        oneTimePending: true,
                        message: "The native limit is temporarily disabled. The helper will restore the saved limit at 100%, on cancellation, or after 10 hours."
                    )
                } catch {
                    removePersistedJob()
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
                        state: FirmwareLimitHelperStateResponse(state: state),
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
                    state: FirmwareLimitHelperStateResponse(state: state),
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

    private func monitorOneTimeCharge() {
        do {
            try withHardwareWatchdog { monitorOneTimeChargeLocked() }
        } catch {
            NSLog("MauLeaf native one-time charge monitor will retry: %@", error.localizedDescription)
        }
    }

    private func monitorOneTimeChargeLocked() {
        stateLock.lock()
        let job = pendingJob
        stateLock.unlock()
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
                removePersistedJob()
                setPendingJob(nil)
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
    }

    private func loadPendingJob() -> FirmwareLimitOnceJob? {
        guard let data = try? Data(contentsOf: jobURL),
              let job = try? JSONDecoder().decode(FirmwareLimitOnceJob.self, from: data),
              job.restoreRequest != nil else { return nil }
        return job
    }

    private func removePersistedJob() {
        try? FileManager.default.removeItem(at: jobURL)
    }

    private func startMonitoring() {
        guard monitorEnabled else { return }
        stateLock.lock()
        guard pendingJob != nil, monitorTimer == nil else {
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
        guard pendingJob == nil, let timer = monitorTimer else {
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
                if self.service.hasPendingOneTimeCharge {
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
