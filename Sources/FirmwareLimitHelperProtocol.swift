import Foundation

/// Narrow XPC surface for the native firmware controller. All SMC writes are
/// performed by the root helper after target, power-source, and consent checks.
@objc protocol FirmwareLimitHelperProtocol {
    func readHelperInfo(withReply reply: @escaping (NSData?, NSString?) -> Void)
    func readState(withReply reply: @escaping (NSData?, NSString?) -> Void)
    func makePlan(upper: Int, lower: Int, withReply reply: @escaping (NSData?, NSString?) -> Void)
    func applyLimit(upper: Int, lower: Int, confirmed: Bool, withReply reply: @escaping (NSData?, NSString?) -> Void)
    func beginOneTimeCharge(upper: Int, lower: Int, confirmed: Bool, withReply reply: @escaping (NSData?, NSString?) -> Void)
    func cancelOneTimeCharge(withReply reply: @escaping (NSData?, NSString?) -> Void)
    func restoreOriginalState(withReply reply: @escaping (NSData?, NSString?) -> Void)
    func oneTimeChargeStatus(withReply reply: @escaping (NSData?, NSString?) -> Void)
}

/// The app checks this lightweight handshake before asking the Helper to
/// inspect AppleSMC. It remains available even when firmware registers or a
/// persisted snapshot are invalid.
struct FirmwareLimitHelperInfoResponse: Codable, Equatable {
    let protocolVersion: Int
    let buildVersion: String

    static var current: FirmwareLimitHelperInfoResponse {
        FirmwareLimitHelperInfoResponse(
            protocolVersion: FirmwareLimitHelperProtocolVersion.current,
            buildVersion: FirmwareLimitHelperBuildVersion.current
        )
    }
}

/// A Helper is compatible only when it is exactly the version bundled with
/// this app. Any mismatch, including a newer Helper, uses the same
/// service-only uninstall and reinstall path.
enum FirmwareLimitHelperProtocolVersion {
    static let current = 7
    static let requiredBuild = FirmwareLimitHelperBuildVersion.current

    static func isCompatible(_ installed: Int, build: String? = nil) -> Bool {
        installed == current && build == requiredBuild
    }

    static func isCompatible(_ info: FirmwareLimitHelperInfoResponse) -> Bool {
        isCompatible(info.protocolVersion, build: info.buildVersion)
    }

    static func canUpgradeFrom(_ installed: Int, build: String? = nil) -> Bool {
        !isCompatible(installed, build: build)
    }
}

/// Increment this build whenever the privileged Helper implementation or
/// its externally observable behavior changes.
enum FirmwareLimitHelperBuildVersion {
    static let current = "1.4.0"
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
        // Missing safety metadata is unknown, never a false/clean value.
        // An incomplete legacy response therefore fails closed; the app
        // performs the independent version handshake before requesting state.
        writeSupported = try container.decode(Bool.self, forKey: .writeSupported)
        writeBlockReason = try container.decodeIfPresent(String.self, forKey: .writeBlockReason)
        hasOriginalStateSnapshot = try container.decode(Bool.self, forKey: .hasOriginalStateSnapshot)
        restorePending = try container.decode(Bool.self, forKey: .restorePending)
        restoreSupported = try container.decode(Bool.self, forKey: .restoreSupported)
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
