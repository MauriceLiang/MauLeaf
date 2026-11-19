import Foundation

/// Narrow XPC surface for the native firmware controller. All SMC writes are
/// performed by the root helper after target, AC-power, and consent checks.
@objc protocol FirmwareLimitHelperProtocol {
    func readState(withReply reply: @escaping (NSData?, NSString?) -> Void)
    func makePlan(upper: Int, lower: Int, withReply reply: @escaping (NSData?, NSString?) -> Void)
    func applyLimit(upper: Int, lower: Int, confirmed: Bool, withReply reply: @escaping (NSData?, NSString?) -> Void)
    func beginOneTimeCharge(upper: Int, lower: Int, confirmed: Bool, withReply reply: @escaping (NSData?, NSString?) -> Void)
    func cancelOneTimeCharge(withReply reply: @escaping (NSData?, NSString?) -> Void)
    func oneTimeChargeStatus(withReply reply: @escaping (NSData?, NSString?) -> Void)
}

struct FirmwareLimitHelperStateResponse: Codable, Equatable {
    let activationByte: UInt8
    let active: Bool
    let upper: Int
    let lower: Int
    let writeSupported: Bool
    let writeBlockReason: String?

    init(state: FirmwareLimitState, identity: FirmwareLimitDeviceIdentity? = nil) {
        activationByte = state.activationByte
        active = state.isActive
        upper = state.upper
        lower = state.lower
        if let identity {
            writeBlockReason = FirmwareLimitWritePermit.targetBlockReason(identity: identity)
            writeSupported = writeBlockReason == nil
        } else {
            writeSupported = true
            writeBlockReason = nil
        }
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
