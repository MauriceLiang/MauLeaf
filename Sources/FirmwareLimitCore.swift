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

struct FirmwareLimitDeviceIdentity: Equatable, Codable {
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

struct FirmwareLimitOfflineRestoreContext: Equatable {
    let isAdministrator: Bool
    let externalConnected: Bool?
    let pmsetReportsBatteryPower: Bool
    let batteryPercent: Int?
    let isCharging: Bool
    let userConfirmed: Bool
}

/// A write permit can only be issued after all target and runtime guards pass.
/// Read-only status and plan generation do not require a permit.
struct FirmwareLimitWritePermit {
    private init() {}

    static func targetBlockReason(identity: FirmwareLimitDeviceIdentity) -> String? {
        guard identity.modelIdentifier == "MacBookPro18,1" else {
            return "Expected MacBookPro18,1; found \(identity.modelIdentifier)."
        }
        guard !identity.systemFirmware.isEmpty else {
            return "Unable to read system-firmware-version from the IODeviceTree; firmware writes are blocked."
        }
        guard identity.systemFirmware == "mBoot-20457.41.3" else {
            return "Unverified system firmware: \(identity.systemFirmware)."
        }
        guard identity.macOSMajorVersion == 15 else {
            return "Expected macOS 15; found macOS \(identity.macOSMajorVersion)."
        }
        guard identity.architecture == "arm64" else {
            return "Expected arm64; found \(identity.architecture)."
        }
        return nil
    }

    /// Restoration is narrower than a normal write: it may run after a macOS
    /// upgrade, but only for the exact model, system firmware, and architecture
    /// recorded in the snapshot. It can never be used to select a new limit.
    static func restoreBlockReason(
        identity: FirmwareLimitDeviceIdentity,
        snapshotIdentity: FirmwareLimitDeviceIdentity
    ) -> String? {
        guard identity.modelIdentifier == "MacBookPro18,1",
              identity.modelIdentifier == snapshotIdentity.modelIdentifier else {
            return "The saved state does not belong to this Mac model."
        }
        guard identity.systemFirmware == "mBoot-20457.41.3",
              identity.systemFirmware == snapshotIdentity.systemFirmware else {
            return "The saved state does not match the current system firmware."
        }
        guard identity.architecture == "arm64",
              identity.architecture == snapshotIdentity.architecture else {
            return "The saved state does not match the current Apple Silicon architecture."
        }
        return nil
    }

    static func authorizeRestore(
        identity: FirmwareLimitDeviceIdentity,
        snapshotIdentity: FirmwareLimitDeviceIdentity,
        context: FirmwareLimitWriteContext
    ) throws -> FirmwareLimitWritePermit {
        guard restoreBlockReason(identity: identity, snapshotIdentity: snapshotIdentity) == nil else {
            throw FirmwareLimitCoreError.originalStateDeviceMismatch
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

    /// Explicitly separate from normal AC-only charge configuration.
    /// Supported only where the full unplugged restore sequence was tested.
    /// Snapshot-less legacy charge states are deliberately excluded.
    static func authorizeOfflineRestore(
        identity: FirmwareLimitDeviceIdentity,
        snapshot: FirmwareLimitOriginalStateSnapshot,
        context: FirmwareLimitOfflineRestoreContext
    ) throws -> FirmwareLimitWritePermit {
        if let reason = targetBlockReason(identity: identity) {
            throw FirmwareLimitCoreError.unsupportedTarget(reason)
        }
        guard snapshot.isValid,
              snapshot.state.activationByte == 0x00 else {
            throw FirmwareLimitCoreError.invalidOriginalSnapshot
        }
        guard restoreBlockReason(
            identity: identity,
            snapshotIdentity: snapshot.deviceIdentity
        ) == nil else {
            throw FirmwareLimitCoreError.originalStateDeviceMismatch
        }
        guard context.isAdministrator else {
            throw FirmwareLimitCoreError.administratorRequired
        }
        guard context.externalConnected == false,
              context.pmsetReportsBatteryPower else {
            throw FirmwareLimitCoreError.externalPowerRequired
        }
        guard let percent = context.batteryPercent,
              (30...100).contains(percent),
              !context.isCharging else {
            throw FirmwareLimitCoreError.transportFailure(
                "Battery-only restore requires readable battery level >= 30% and no charging."
            )
        }
        guard context.userConfirmed else {
            throw FirmwareLimitCoreError.confirmationRequired
        }
        return FirmwareLimitWritePermit()
    }

    static func authorize(
        identity: FirmwareLimitDeviceIdentity,
        context: FirmwareLimitWriteContext
    ) throws -> FirmwareLimitWritePermit {
        if let reason = targetBlockReason(identity: identity) {
            throw FirmwareLimitCoreError.unsupportedTarget(reason)
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
        guard (50...100).contains(upper),
              (5...100).contains(lower),
              lower < upper else {
            throw FirmwareLimitCoreError.invalidRequestedBand(upper: upper, lower: lower)
        }
        self.upper = upper
        self.lower = lower
    }

    /// MauLeaf's normal UI target is 50–95%; experimental hold requests
    /// may reach 100% and keep the user's original lower threshold.
    static func standard(upper: Int) throws -> FirmwareLimitRequest {
        try FirmwareLimitRequest(upper: upper, lower: max(5, upper - 2))
    }
}

struct FirmwareLimitState: Equatable, Codable {
    let activationByte: UInt8
    let upper: Int
    let lower: Int

    var isActive: Bool { activationByte == 0x02 }

    /// The target firmware can report zeroed limit registers after boot
    /// while bfF0 is inactive. This is safe to *observe* but is not a
    /// valid original snapshot or evidence that restoration succeeded.
    var isInactiveUninitialized: Bool {
        activationByte == 0x00 && upper == 0 && lower == 0
    }

    var isValid: Bool {
        (activationByte == 0x00 || activationByte == 0x02)
            && (5...100).contains(upper)
            && (5...100).contains(lower)
            && lower < upper
    }
}

/// Captures the exact firmware state before MauLeaf first enables a limit.
/// This snapshot is root-owned and survives app upgrades and uninstallation.
struct FirmwareLimitOriginalStateSnapshot: Codable, Equatable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let deviceIdentity: FirmwareLimitDeviceIdentity
    let state: FirmwareLimitState
    let capturedAt: Date
    var restoreRequested: Bool

    init(
        deviceIdentity: FirmwareLimitDeviceIdentity,
        state: FirmwareLimitState,
        capturedAt: Date = Date(),
        restoreRequested: Bool = false
    ) throws {
        guard state.isValid, capturedAt.timeIntervalSince1970.isFinite else {
            throw FirmwareLimitCoreError.invalidOriginalSnapshot
        }
        schemaVersion = Self.currentSchemaVersion
        self.deviceIdentity = deviceIdentity
        self.state = state
        self.capturedAt = capturedAt
        self.restoreRequested = restoreRequested
    }

    var isValid: Bool {
        schemaVersion == Self.currentSchemaVersion
            && state.isValid
            && capturedAt.timeIntervalSince1970.isFinite
    }
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
    case invalidOriginalSnapshot
    case legacyActiveStateWithoutSnapshot
    case originalStateDeviceMismatch
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
        case .invalidOriginalSnapshot:
            return "The saved original firmware state is invalid; it will be retained for manual recovery."
        case .legacyActiveStateWithoutSnapshot:
            return "An active firmware limit exists without a MauLeaf original-state snapshot. Disable the legacy limit before enabling a new managed limit."
        case .originalStateDeviceMismatch:
            return "The saved original firmware state belongs to a different hardware or firmware identity; restoration is blocked."
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
        try validateKeyMetadata()
        return try readRawState()
    }

    private func validateKeyMetadata() throws {
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

    /// Restores the exact activation byte and thresholds captured before
    /// MauLeaf first enabled its limit. A failed restore never discards the
    /// snapshot; the privileged helper can retry it later.
    func restore(
        _ original: FirmwareLimitState,
        permit: FirmwareLimitWritePermit,
        preflight: () throws -> Void = {}
    ) throws -> FirmwareLimitState {
        guard original.isValid else { throw FirmwareLimitCoreError.invalidOriginalSnapshot }
        try validateKeyMetadata()
        if let current = try? readRawState(), current == original { return current }

        do {
            // Never create an invalid intermediate lower >= upper band.
            // First deactivate the limit. When reducing the upper bound
            // (85/83 -> 80/78), write the LOWER bound first.
            // Conversely (75/73 -> 80/78), write the UPPER bound first.
            // An interrupted older Preview may have left an invalid
            // intermediate pair. Read each register independently so it can
            // still be restored, even when readState() rejects that pair.
            let activation = try readRaw(.activation).first ?? 0xFF
            guard activation == 0x00 || activation == 0x02 else {
                throw FirmwareLimitCoreError.invalidActivation(activation)
            }
            guard let previousUpper = FirmwareLimitPolicy.decodeUInt32LittleEndian(try readRaw(.upper)),
                  let previousLower = FirmwareLimitPolicy.decodeUInt32LittleEndian(try readRaw(.lower)) else {
                throw FirmwareLimitCoreError.invalidOriginalSnapshot
            }
            let zeroedAfterBoot = activation == 0x00
                && previousUpper == 0 && previousLower == 0
            guard zeroedAfterBoot || (
                (5...100).contains(previousUpper)
                && (5...100).contains(previousLower)
            ) else {
                throw FirmwareLimitCoreError.invalidOriginalSnapshot
            }
            if activation == 0x02 {
                try writeAndVerify(.activation, bytes: [0x00], preflight: preflight)
            }
            // A zero/zero interval has no valid ordering. Rebuild it only
            // through the existing identity-bound, persisted-snapshot
            // restore permit; never try to save zeroes as the original state.
            let upperFirst = zeroedAfterBoot || original.upper > previousLower
            if upperFirst {
                if previousUpper != original.upper {
                    try writeAndVerify(.upper, bytes: FirmwareLimitPolicy.encodeUInt32LittleEndian(original.upper), preflight: preflight)
                }
                if previousLower != original.lower {
                    try writeAndVerify(.lower, bytes: FirmwareLimitPolicy.encodeUInt32LittleEndian(original.lower), preflight: preflight)
                }
            } else {
                if previousLower != original.lower {
                    try writeAndVerify(.lower, bytes: FirmwareLimitPolicy.encodeUInt32LittleEndian(original.lower), preflight: preflight)
                }
                if previousUpper != original.upper {
                    try writeAndVerify(.upper, bytes: FirmwareLimitPolicy.encodeUInt32LittleEndian(original.upper), preflight: preflight)
                }
            }
            if original.activationByte != 0x00 {
                try writeAndVerify(.activation, bytes: [original.activationByte], preflight: preflight)
            }
            let restored = try readState()
            guard restored == original else {
                throw FirmwareLimitCoreError.readbackMismatch(
                    key: "bfF0/bfD0/bfE0",
                    expected: "\(original.activationByte) \(original.upper)/\(original.lower)",
                    actual: "\(restored.activationByte) \(restored.upper)/\(restored.lower)"
                )
            }
            return restored
        } catch {
            // Prefer an inactive controller state while the exact original
            // snapshot remains persisted for the next restoration attempt.
            try? writeAndVerify(.activation, bytes: [0x00], preflight: preflight)
            throw FirmwareLimitCoreError.transactionFailed(
                primary: String(describing: error),
                recovery: "the original-state snapshot was retained; restoration must be retried"
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

    private func writeAndVerify(
        _ key: FirmwareLimitKey,
        bytes: [UInt8],
        preflight: () throws -> Void = {}
    ) throws {
        var lastFailure = "no read-back result"
        for _ in 0..<attempts {
            // Power source, identity and snapshot must be rechecked on
            // every retry, not just once at the start of the transaction.
            try preflight()
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
              let lower = FirmwareLimitPolicy.decodeUInt32LittleEndian(try readRaw(.lower)) else {
            throw FirmwareLimitCoreError.invalidStoredBand(upper: -1, lower: -1)
        }
        let state = FirmwareLimitState(activationByte: activation, upper: upper, lower: lower)
        // Read-only reporting can represent this one exact transient
        // post-reboot state. Active zero/zero or any malformed band still
        // fails closed. Callers must never snapshot it as the original state.
        guard state.isValid || state.isInactiveUninitialized else {
            throw FirmwareLimitCoreError.invalidStoredBand(upper: upper, lower: lower)
        }
        return state
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
