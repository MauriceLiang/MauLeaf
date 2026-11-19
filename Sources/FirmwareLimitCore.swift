import Foundation

/// Firmware-managed charge-limit registers exposed by the bf* SMC family.
enum FirmwareLimitKey: String, CaseIterable {
    case activation = "bfF0"
    case upper = "bfD0"
    case lower = "bfE0"

    var expectedSize: Int {
        switch self {
        case .activation: return 1
        case .upper, .lower: return 4
        }
    }

    var expectedType: String {
        switch self {
        case .activation: return "ui8"
        case .upper, .lower: return "ui32"
        }
    }
}

struct FirmwareLimitKeyMetadata: Equatable {
    let size: Int
    let type: String
}

/// The transport is deliberately injected. Unit tests use an in-memory
/// implementation; only the macOS helper should construct the real SMC
/// transport.
protocol FirmwareLimitTransport {
    func metadata(for key: FirmwareLimitKey) throws -> FirmwareLimitKeyMetadata
    func read(_ key: FirmwareLimitKey, count: Int) throws -> [UInt8]
    func write(_ key: FirmwareLimitKey, bytes: [UInt8]) throws
}

struct FirmwareLimitDeviceIdentity: Equatable {
    let modelIdentifier: String
    let systemFirmware: String
    let macOSMajorVersion: Int
    let architecture: String
}

struct FirmwareLimitWriteContext: Equatable {
    let isAdministrator: Bool
    let isOnACPower: Bool
    let userConfirmed: Bool
}

/// A write permit can only be issued after all target and runtime guards pass.
/// Read-only status and plan generation do not require a permit.
struct FirmwareLimitWritePermit {
    private init() {}

    static func authorize(
        identity: FirmwareLimitDeviceIdentity,
        context: FirmwareLimitWriteContext
    ) throws -> FirmwareLimitWritePermit {
        guard identity.modelIdentifier == "MacBookPro18,1" else {
            throw FirmwareLimitCoreError.unsupportedTarget("Expected MacBookPro18,1; found \(identity.modelIdentifier).")
        }
        guard identity.systemFirmware == "mBoot-20457.41.3" else {
            throw FirmwareLimitCoreError.unsupportedTarget("Unverified system firmware: \(identity.systemFirmware).")
        }
        guard identity.macOSMajorVersion == 15 else {
            throw FirmwareLimitCoreError.unsupportedTarget("Expected macOS 15; found macOS \(identity.macOSMajorVersion).")
        }
        guard identity.architecture == "arm64" else {
            throw FirmwareLimitCoreError.unsupportedTarget("Expected arm64; found \(identity.architecture).")
        }
        guard context.isAdministrator else {
            throw FirmwareLimitCoreError.administratorRequired
        }
        guard context.isOnACPower else {
            throw FirmwareLimitCoreError.externalPowerRequired
        }
        guard context.userConfirmed else {
            throw FirmwareLimitCoreError.confirmationRequired
        }
        return FirmwareLimitWritePermit()
    }
}

struct FirmwareLimitRequest: Equatable {
    let upper: Int
    let lower: Int

    init(upper: Int, lower: Int) throws {
        guard (50...95).contains(upper),
              (5...100).contains(lower),
              lower < upper else {
            throw FirmwareLimitCoreError.invalidRequestedBand(upper: upper, lower: lower)
        }
        self.upper = upper
        self.lower = lower
    }

    /// MauLeaf's default resume threshold is two percentage points below
    /// the selected upper limit.
    static func standard(upper: Int) throws -> FirmwareLimitRequest {
        try FirmwareLimitRequest(upper: upper, lower: max(5, upper - 2))
    }
}

struct FirmwareLimitState: Equatable {
    let activationByte: UInt8
    let upper: Int
    let lower: Int

    var isActive: Bool { activationByte == 0x02 }
}

enum FirmwareLimitStep: Equatable, CustomStringConvertible {
    case deactivate
    case writeUpper(Int)
    case writeLower(Int)
    case activate

    var description: String {
        switch self {
        case .deactivate: return "bfF0 = 0x00 (deactivate)"
        case .writeUpper(let value): return "bfD0 = \(value) (upper)"
        case .writeLower(let value): return "bfE0 = \(value) (lower)"
        case .activate: return "bfF0 = 0x02 (activate)"
        }
    }
}

struct FirmwareLimitPlan: Equatable {
    let previous: FirmwareLimitState
    let requested: FirmwareLimitRequest
    let steps: [FirmwareLimitStep]

    var isNoOp: Bool { steps.isEmpty }
}

enum FirmwareLimitCoreError: Error, Equatable, LocalizedError {
    case unsupportedTarget(String)
    case administratorRequired
    case externalPowerRequired
    case confirmationRequired
    case invalidRequestedBand(upper: Int, lower: Int)
    case unexpectedKeyShape(key: String, size: Int, type: String)
    case invalidReadLength(key: String, expected: Int, actual: Int)
    case invalidActivation(UInt8)
    case invalidStoredBand(upper: Int, lower: Int)
    case readbackMismatch(key: String, expected: String, actual: String)
    case transportFailure(String)
    case transactionFailed(primary: String, recovery: String)

    var errorDescription: String? {
        switch self {
        case .unsupportedTarget(let reason): return reason
        case .administratorRequired: return "Administrator privileges are required."
        case .externalPowerRequired: return "Connect the Mac to AC power before changing firmware charging settings."
        case .confirmationRequired: return "The explicit hardware-write confirmation was not provided."
        case .invalidRequestedBand(let upper, let lower):
            return "Invalid requested charge band: upper \(upper)%, lower \(lower)%."
        case .unexpectedKeyShape(let key, let size, let type):
            return "\(key) has an unexpected SMC shape: size=\(size), type=\(type)."
        case .invalidReadLength(let key, let expected, let actual):
            return "\(key) returned \(actual) bytes; expected \(expected)."
        case .invalidActivation(let value):
            return String(format: "bfF0 contains an unknown activation value: 0x%02X.", value)
        case .invalidStoredBand(let upper, let lower):
            return "Stored firmware limits are invalid: upper \(upper)%, lower \(lower)%."
        case .readbackMismatch(let key, let expected, let actual):
            return "\(key) read-back mismatch: expected \(expected), got \(actual)."
        case .transportFailure(let detail):
            return "AppleSMC transport failed: \(detail)"
        case .transactionFailed(let primary, let recovery):
            return "Firmware-limit transaction failed: \(primary). Recovery: \(recovery)."
        }
    }
}

enum FirmwareLimitPolicy {
    /// A size of zero means the firmware leaves metadata unpopulated for a
    /// live key. It is accepted only when the type is also absent or matches;
    /// direct reads must still return the exact expected number of bytes.
    static func accepts(_ metadata: FirmwareLimitKeyMetadata, for key: FirmwareLimitKey) -> Bool {
        let normalizedType = metadata.type.trimmingCharacters(in: .whitespacesAndNewlines)
        if metadata.size == 0 {
            return normalizedType.isEmpty || normalizedType == key.expectedType
        }
        return metadata.size == key.expectedSize && normalizedType == key.expectedType
    }

    static func encodeUInt32LittleEndian(_ value: Int) -> [UInt8] {
        let number = UInt32(value)
        return [
            UInt8(number & 0xFF),
            UInt8((number >> 8) & 0xFF),
            UInt8((number >> 16) & 0xFF),
            UInt8((number >> 24) & 0xFF)
        ]
    }

    static func decodeUInt32LittleEndian(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        let value = UInt32(bytes[0])
            | (UInt32(bytes[1]) << 8)
            | (UInt32(bytes[2]) << 16)
            | (UInt32(bytes[3]) << 24)
        return Int(value)
    }

    static func plan(current: FirmwareLimitState, request: FirmwareLimitRequest) -> FirmwareLimitPlan {
        if current.isActive, current.upper == request.upper, current.lower == request.lower {
            return FirmwareLimitPlan(previous: current, requested: request, steps: [])
        }
        return FirmwareLimitPlan(
            previous: current,
            requested: request,
            steps: [.deactivate, .writeUpper(request.upper), .writeLower(request.lower), .activate]
        )
    }
}

/// Transactional controller for the bfF0/bfD0/bfE0 register family.
///
/// This type contains no process, UI, launchd, or privilege-management code.
/// A caller must obtain a FirmwareLimitWritePermit before any mutating call.
/// The application does not construct this controller in its current release.
struct FirmwareLimitController {
    private let transport: FirmwareLimitTransport
    private let wait: (TimeInterval) -> Void
    private let attempts: Int

    init(
        transport: FirmwareLimitTransport,
        attempts: Int = 3,
        wait: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) {
        self.transport = transport
        self.attempts = max(1, attempts)
        self.wait = wait
    }

    /// Read-only operation. Checks all three key shapes before reading values.
    func readState() throws -> FirmwareLimitState {
        for key in FirmwareLimitKey.allCases {
            let metadata: FirmwareLimitKeyMetadata
            do {
                metadata = try transport.metadata(for: key)
            } catch {
                throw FirmwareLimitCoreError.transportFailure(String(describing: error))
            }
            guard FirmwareLimitPolicy.accepts(metadata, for: key) else {
                throw FirmwareLimitCoreError.unexpectedKeyShape(
                    key: key.rawValue, size: metadata.size, type: metadata.type
                )
            }
        }
        return try readRawState()
    }

    /// Read-only planning. The returned sequence can be reviewed without
    /// changing the SMC or requiring AC power.
    func makePlan(for request: FirmwareLimitRequest) throws -> FirmwareLimitPlan {
        FirmwareLimitPolicy.plan(current: try readState(), request: request)
    }

    /// Applies the full deactivate → upper → lower → activate transaction.
    /// Every write is read back. Any failure triggers restoration of the
    /// exact pre-transaction state; if that cannot be restored, the final
    /// fallback is to leave the firmware limit inactive and verify that.
    func configure(
        _ request: FirmwareLimitRequest,
        permit: FirmwareLimitWritePermit
    ) throws -> FirmwareLimitState {
        let plan = try makePlan(for: request)
        if plan.isNoOp { return plan.previous }

        do {
            for step in plan.steps {
                try execute(step)
            }
            let final = try readState()
            guard final.isActive, final.upper == request.upper, final.lower == request.lower else {
                throw FirmwareLimitCoreError.readbackMismatch(
                    key: "bfF0/bfD0/bfE0",
                    expected: "active \(request.upper)/\(request.lower)",
                    actual: "\(final.activationByte == 0x02 ? "active" : "inactive") \(final.upper)/\(final.lower)"
                )
            }
            return final
        } catch {
            let recovery = recover(previous: plan.previous)
            throw FirmwareLimitCoreError.transactionFailed(
                primary: String(describing: error),
                recovery: recovery
            )
        }
    }

    /// Disables the firmware-managed limit without changing either threshold.
    func deactivate(permit: FirmwareLimitWritePermit) throws -> FirmwareLimitState {
        let previous = try readState()
        guard previous.isActive else { return previous }

        do {
            try writeAndVerify(.activation, bytes: [0x00])
            let final = try readState()
            guard final.activationByte == 0x00,
                  final.upper == previous.upper,
                  final.lower == previous.lower else {
                throw FirmwareLimitCoreError.readbackMismatch(
                    key: "bfF0",
                    expected: "inactive; thresholds unchanged",
                    actual: "\(final.activationByte) \(final.upper)/\(final.lower)"
                )
            }
            return final
        } catch {
            throw FirmwareLimitCoreError.transactionFailed(
                primary: String(describing: error),
                recovery: recover(previous: previous)
            )
        }
    }

    private func execute(_ step: FirmwareLimitStep) throws {
        switch step {
        case .deactivate:
            try writeAndVerify(.activation, bytes: [0x00])
        case .writeUpper(let value):
            try writeAndVerify(.upper, bytes: FirmwareLimitPolicy.encodeUInt32LittleEndian(value))
        case .writeLower(let value):
            try writeAndVerify(.lower, bytes: FirmwareLimitPolicy.encodeUInt32LittleEndian(value))
        case .activate:
            try writeAndVerify(.activation, bytes: [0x02])
        }
    }

    private func writeAndVerify(_ key: FirmwareLimitKey, bytes: [UInt8]) throws {
        var lastFailure = "no read-back result"
        for _ in 0..<attempts {
            do {
                try transport.write(key, bytes: bytes)
                wait(0.12)
                let actual = try readRaw(key)
                if actual == bytes { return }
                lastFailure = actual.map { String(format: "%02X", $0) }.joined(separator: " ")
            } catch {
                lastFailure = String(describing: error)
            }
        }
        throw FirmwareLimitCoreError.readbackMismatch(
            key: key.rawValue,
            expected: bytes.map { String(format: "%02X", $0) }.joined(separator: " "),
            actual: lastFailure
        )
    }

    private func recover(previous: FirmwareLimitState) -> String {
        do {
            try writeAndVerify(.activation, bytes: [0x00])
            try writeAndVerify(.upper, bytes: FirmwareLimitPolicy.encodeUInt32LittleEndian(previous.upper))
            try writeAndVerify(.lower, bytes: FirmwareLimitPolicy.encodeUInt32LittleEndian(previous.lower))
            try writeAndVerify(.activation, bytes: [previous.activationByte])
            let restored = try readState()
            guard restored == previous else {
                throw FirmwareLimitCoreError.readbackMismatch(
                    key: "bfF0/bfD0/bfE0",
                    expected: "\(previous.activationByte) \(previous.upper)/\(previous.lower)",
                    actual: "\(restored.activationByte) \(restored.upper)/\(restored.lower)"
                )
            }
            return "the previous firmware state was restored and verified"
        } catch {
            do {
                try writeAndVerify(.activation, bytes: [0x00])
                let activation = try readRaw(.activation).first ?? 0xFF
                guard activation == 0x00 else {
                    throw FirmwareLimitCoreError.invalidActivation(activation)
                }
                return "the previous state could not be restored; the firmware limit is inactive and verified"
            } catch {
                return "the previous state could not be restored and the inactive state could not be verified: \(error)"
            }
        }
    }

    private func readRawState() throws -> FirmwareLimitState {
        let activationBytes = try readRaw(.activation)
        guard let activation = activationBytes.first,
              activation == 0x00 || activation == 0x02 else {
            throw FirmwareLimitCoreError.invalidActivation(activationBytes.first ?? 0xFF)
        }
        guard let upper = FirmwareLimitPolicy.decodeUInt32LittleEndian(try readRaw(.upper)),
              let lower = FirmwareLimitPolicy.decodeUInt32LittleEndian(try readRaw(.lower)),
              (5...100).contains(upper), (5...100).contains(lower), lower < upper else {
            let upper = FirmwareLimitPolicy.decodeUInt32LittleEndian((try? readRaw(.upper)) ?? []) ?? -1
            let lower = FirmwareLimitPolicy.decodeUInt32LittleEndian((try? readRaw(.lower)) ?? []) ?? -1
            throw FirmwareLimitCoreError.invalidStoredBand(upper: upper, lower: lower)
        }
        return FirmwareLimitState(activationByte: activation, upper: upper, lower: lower)
    }

    private func readRaw(_ key: FirmwareLimitKey) throws -> [UInt8] {
        do {
            let bytes = try transport.read(key, count: key.expectedSize)
            guard bytes.count == key.expectedSize else {
                throw FirmwareLimitCoreError.invalidReadLength(
                    key: key.rawValue, expected: key.expectedSize, actual: bytes.count
                )
            }
            return bytes
        } catch let error as FirmwareLimitCoreError {
            throw error
        } catch {
            throw FirmwareLimitCoreError.transportFailure(String(describing: error))
        }
    }
}
