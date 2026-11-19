import Foundation

/// Narrow XPC surface for the native firmware controller. All SMC writes are
/// performed by the root helper after target, AC-power, and consent checks.
@objc protocol FirmwareLimitHelperProtocol {
    func readState(withReply reply: @escaping (NSData?, NSString?) -> Void)
    func makePlan(upper: Int, lower: Int, withReply reply: @escaping (NSData?, NSString?) -> Void)
    func applyLimit(upper: Int, lower: Int, confirmed: Bool, withReply reply: @escaping (NSData?, NSString?) -> Void)
    func beginOneTimeCharge(upper: Int, lower: Int, confirmed: Bool, withReply reply: @escaping (NSData?, NSString?) -> Void)
    func cancelOneTimeCharge(withReply reply: @escaping (NSData?, NSString?) -> Void)
    func restoreOriginalState(withReply reply: @escaping (NSData?, NSString?) -> Void)
    func oneTimeChargeStatus(withReply reply: @escaping (NSData?, NSString?) -> Void)
}

enum FirmwareLimitHelperProtocolVersion {
    static let current = 3
}

struct FirmwareLimitHelperStateResponse: Codable, Equatable {
    let helperVersion: Int
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

    init(
        state: FirmwareLimitState,
        identity: FirmwareLimitDeviceIdentity? = nil,
        snapshot: FirmwareLimitOriginalStateSnapshot? = nil
    ) {
        helperVersion = FirmwareLimitHelperProtocolVersion.current
        activationByte = state.activationByte
        active = state.isActive
        upper = state.upper
        lower = state.lower
        hasOriginalStateSnapshot = snapshot != nil
        restorePending = snapshot?.restoreRequested ?? false
        if let identity {
            writeBlockReason = FirmwareLimitWritePermit.targetBlockReason(identity: identity)
            writeSupported = writeBlockReason == nil
            if let snapshot {
                restoreBlockReason = FirmwareLimitWritePermit.restoreBlockReason(
                    identity: identity,
                    snapshotIdentity: snapshot.deviceIdentity
                )
            } else {
                restoreBlockReason = writeBlockReason
            }
            restoreSupported = restoreBlockReason == nil
        } else {
            writeSupported = true
            writeBlockReason = nil
            restoreSupported = true
            restoreBlockReason = nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case helperVersion, activationByte, active, upper, lower, writeSupported, writeBlockReason
        case hasOriginalStateSnapshot, restorePending, restoreSupported, restoreBlockReason
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Missing helperVersion identifies a previously installed helper.
        helperVersion = try container.decodeIfPresent(Int.self, forKey: .helperVersion) ?? 0
        activationByte = try container.decode(UInt8.self, forKey: .activationByte)
        active = try container.decode(Bool.self, forKey: .active)
        upper = try container.decode(Int.self, forKey: .upper)
        lower = try container.decode(Int.self, forKey: .lower)
        // Older read-only helpers returned only the four state fields. Treat
        // them as legacy so the subsequent XPC version probe can trigger upgrade.
        writeSupported = try container.decodeIfPresent(Bool.self, forKey: .writeSupported) ?? true
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
