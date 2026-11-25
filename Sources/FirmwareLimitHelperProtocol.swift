import Foundation

/// Narrow XPC surface for the native firmware controller. All SMC writes are
/// performed by the root helper after target, power-source, and consent checks.
@objc protocol FirmwareLimitHelperProtocol {
    func readState(withReply reply: @escaping (NSData?, NSString?) -> Void)
    func makePlan(upper: Int, lower: Int, withReply reply: @escaping (NSData?, NSString?) -> Void)
    func applyLimit(upper: Int, lower: Int, confirmed: Bool, withReply reply: @escaping (NSData?, NSString?) -> Void)
    func beginOneTimeCharge(upper: Int, lower: Int, confirmed: Bool, withReply reply: @escaping (NSData?, NSString?) -> Void)
    func cancelOneTimeCharge(withReply reply: @escaping (NSData?, NSString?) -> Void)
    func restoreOriginalState(withReply reply: @escaping (NSData?, NSString?) -> Void)
    func oneTimeChargeStatus(withReply reply: @escaping (NSData?, NSString?) -> Void)
}

/// Compatibility is intentionally independent of the visible app version.
/// A UI-only release never requires reinstalling the privileged Helper.
enum FirmwareLimitHelperProtocolVersion {
    static let current = 6
    static let supported: ClosedRange<Int> = 6...6

    /// Increment this floor only when a Helper behavior fix is required by
    /// the app. A cosmetic app version must NEVER change it.
    static let minimumBuild = "1.3.0"
    /// The new v6 Helper accepts a 100% temporary firmware ceiling.
    /// Unversioned older Helpers are not considered compatible.
    static let acceptsUnversionedV5 = false

    static func isCompatible(_ installed: Int, build: String? = nil) -> Bool {
        guard supported.contains(installed) else { return false }
        guard let build else { return acceptsUnversionedV5 }
        guard let actual = versionParts(build), let minimum = versionParts(minimumBuild) else {
            return false
        }
        return actual.lexicographicallyPrecedes(minimum) == false
    }

    static func canUpgradeFrom(_ installed: Int, build: String? = nil) -> Bool {
        if !supported.contains(installed) { return true }
        guard let build else { return !acceptsUnversionedV5 }
        guard let actual = versionParts(build), let minimum = versionParts(minimumBuild) else {
            return true // Replacement still requires verified safe removal.
        }
        return actual.lexicographicallyPrecedes(minimum)
    }

    private static func versionParts(_ value: String) -> [Int]? {
        let items = value.split(separator: ".", omittingEmptySubsequences: false)
        guard items.count == 3 else { return nil }
        let values = items.compactMap { Int($0) }
        guard values.count == 3, values.allSatisfy({ $0 >= 0 }) else { return nil }
        return values
    }
}

/// Version of the privileged binary, distinct from MauLeaf's app version.
/// A UI-only change does not change this constant.
enum FirmwareLimitHelperBuildVersion {
    static let current = "1.3.0"
}

struct FirmwareLimitHelperStateResponse: Codable, Equatable {
    let helperVersion: Int
    let helperBuildVersion: String?
    let activationByte: UInt8
    let active: Bool
    let upper: Int
    let lower: Int
    let writeSupported: Bool
    let writeBlockReason: String?
    let hasOriginalStateSnapshot: Bool
    let restorePending: Bool
    let restoreSupported: Bool
    let restoreBlockReason: String?

    /// Reported by the v6/1.2 Helper when firmware exposes inactive
    /// zeroed thresholds after boot. This is not a valid saved limit.
    var isInactiveUninitialized: Bool {
        activationByte == 0x00 && upper == 0 && lower == 0
    }

    /// Active zero bounds are an abnormal, read-only firmware diagnosis.
    /// The only permitted mutation is identity-checked snapshot recovery.
    var isActiveZeroed: Bool {
        activationByte == 0x02 && upper == 0 && lower == 0
    }

    init(
        state: FirmwareLimitState,
        identity: FirmwareLimitDeviceIdentity? = nil,
        snapshot: FirmwareLimitOriginalStateSnapshot? = nil,
        legacyRestorePending: Bool = false,
        durableRecoveryRecorded: Bool = true
    ) {
        helperVersion = FirmwareLimitHelperProtocolVersion.current
        helperBuildVersion = FirmwareLimitHelperBuildVersion.current
        activationByte = state.activationByte
        active = state.isActive
        upper = state.upper
        lower = state.lower
        hasOriginalStateSnapshot = snapshot != nil
        restorePending = durableRecoveryRecorded
            && ((snapshot?.restoreRequested ?? false) || legacyRestorePending)
        if let identity {
            let identityBlock = FirmwareLimitWritePermit.targetBlockReason(identity: identity)
            // On a cold reboot bfF0 can report inactive with bfD0/bfE0
            // both zero. Do not create a new snapshot from those values.
            // A valid existing snapshot may be used for managed recovery.
            writeBlockReason = identityBlock ?? (
                state.isActiveZeroed
                    ? "Active firmware limit has zeroed thresholds; new writes are blocked. Restore the verified original-state snapshot."
                    : state.isInactiveUninitialized && snapshot == nil
                        ? "Firmware limits are not initialized after startup; no managed recovery snapshot is present."
                        : nil
            )
            writeSupported = writeBlockReason == nil
            if let snapshot {
                restoreBlockReason = FirmwareLimitWritePermit.restoreBlockReason(
                    identity: identity,
                    snapshotIdentity: snapshot.deviceIdentity
                )
            } else {
                // Without a snapshot, this capability is limited to clearing
                // a legacy activation flag on the exact validated hardware.
                restoreBlockReason = FirmwareLimitWritePermit.restoreBlockReason(
                    identity: identity,
                    snapshotIdentity: identity
                )
            }
            restoreSupported = restoreBlockReason == nil
                && (!state.isActiveZeroed || (snapshot?.isValid == true))
        } else {
            writeSupported = state.isValid || (state.isInactiveUninitialized && snapshot != nil)
            writeBlockReason = writeSupported ? nil : "Firmware limits are not initialized or are invalid."
            restoreSupported = !state.isActiveZeroed || (snapshot?.isValid == true)
            restoreBlockReason = restoreSupported ? nil : "No verified original-state snapshot for active zeroed firmware."
        }
    }

    private enum CodingKeys: String, CodingKey {
        case helperVersion, helperBuildVersion, activationByte, active, upper, lower, writeSupported, writeBlockReason
        case hasOriginalStateSnapshot, restorePending, restoreSupported, restoreBlockReason
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Missing helperVersion identifies a previously installed helper.
        helperVersion = try container.decodeIfPresent(Int.self, forKey: .helperVersion) ?? 0
        helperBuildVersion = try container.decodeIfPresent(String.self, forKey: .helperBuildVersion)
        activationByte = try container.decode(UInt8.self, forKey: .activationByte)
        active = try container.decode(Bool.self, forKey: .active)
        upper = try container.decode(Int.self, forKey: .upper)
        lower = try container.decode(Int.self, forKey: .lower)
        // Older read-only helpers returned only the four state fields. Treat
        // them as legacy so the subsequent XPC version probe can trigger upgrade.
        writeSupported = try container.decodeIfPresent(Bool.self, forKey: .writeSupported) ?? false
        writeBlockReason = try container.decodeIfPresent(String.self, forKey: .writeBlockReason)
        hasOriginalStateSnapshot = try container.decodeIfPresent(Bool.self, forKey: .hasOriginalStateSnapshot) ?? false
        restorePending = try container.decodeIfPresent(Bool.self, forKey: .restorePending) ?? false
        restoreSupported = try container.decodeIfPresent(Bool.self, forKey: .restoreSupported) ?? writeSupported
        restoreBlockReason = try container.decodeIfPresent(String.self, forKey: .restoreBlockReason)
    }
}

struct FirmwareLimitHelperPlanResponse: Codable, Equatable {
    let current: FirmwareLimitHelperStateResponse
    let requestedUpper: Int
    let requestedLower: Int
    let noOp: Bool
    let steps: [String]

    init(plan: FirmwareLimitPlan) {
        current = FirmwareLimitHelperStateResponse(state: plan.previous)
        requestedUpper = plan.requested.upper
        requestedLower = plan.requested.lower
        noOp = plan.isNoOp
        steps = plan.steps.map(\.description)
    }
}

struct FirmwareLimitHelperOperationResponse: Codable, Equatable {
    let state: FirmwareLimitHelperStateResponse
    let oneTimePending: Bool
    let message: String
}

struct FirmwareLimitHelperOneTimeStatusResponse: Codable, Equatable {
    let pending: Bool
    let restoreUpper: Int?
    let deadlineUnixSeconds: Double?
    let cancelRequested: Bool
}
