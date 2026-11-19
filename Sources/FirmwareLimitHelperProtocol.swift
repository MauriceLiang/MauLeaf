import Foundation

/// Narrow read-only XPC surface for the privileged firmware helper.
/// No raw SMC write operation is exposed to the menu-bar application.
@objc protocol FirmwareLimitHelperProtocol {
    func readState(withReply reply: @escaping (NSData?, NSString?) -> Void)
    func makePlan(upper: Int, lower: Int, withReply reply: @escaping (NSData?, NSString?) -> Void)
}

struct FirmwareLimitHelperStateResponse: Codable, Equatable {
    let activationByte: UInt8
    let active: Bool
    let upper: Int
    let lower: Int

    init(state: FirmwareLimitState) {
        activationByte = state.activationByte
        active = state.isActive
        upper = state.upper
        lower = state.lower
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
