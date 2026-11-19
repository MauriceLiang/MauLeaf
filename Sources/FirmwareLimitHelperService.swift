import Foundation
import Security
import Darwin

/// Read-only service facade. The controller's mutating APIs are deliberately
/// not exported over XPC; they remain unavailable until real hardware
/// activation and enforcement have been verified on the target Mac.
final class FirmwareLimitHelperService: NSObject, FirmwareLimitHelperProtocol {
    private let controller: FirmwareLimitController
    private let hardwareLock = NSLock()
    private let watchdogLock = NSLock()
    private var operationSequence = 0
    private var activeOperation: Int?
    private let watchdogTimeout: TimeInterval = 15

    init(transport: FirmwareLimitTransport) {
        controller = FirmwareLimitController(transport: transport)
        super.init()
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
            let shouldExit = self.activeConnections == 0 && self.idleGeneration == generation
            self.stateLock.unlock()
            if shouldExit { exit(0) }
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
