import Foundation

enum FixtureBackendError: Error {
    case injected
}

final class FixtureNativeFirmwareBackend: NativeFirmwareBackend {
    var state = FirmwareLimitHelperStateResponse(
        state: FirmwareLimitState(activationByte: 0x02, upper: 80, lower: 78)
    )
    var pending = false
    var applyCount = 0
    var beginCount = 0
    var cancelCount = 0
    var failNextApply = false

    func readState() async throws -> FirmwareLimitHelperStateResponse { state }

    func applyLimit(upper: Int, lower: Int, confirmed: Bool) async throws -> FirmwareLimitHelperOperationResponse {
        applyCount += 1
        guard confirmed else { throw FixtureBackendError.injected }
        if failNextApply {
            failNextApply = false
            throw FixtureBackendError.injected
        }
        state = FirmwareLimitHelperStateResponse(
            state: FirmwareLimitState(activationByte: 0x02, upper: upper, lower: lower)
        )
        return FirmwareLimitHelperOperationResponse(
            state: state,
            oneTimePending: false,
            message: "Fake native firmware registers were written and read back."
        )
    }

    func beginOneTimeCharge(upper: Int, lower: Int, confirmed: Bool) async throws -> FirmwareLimitHelperOperationResponse {
        beginCount += 1
        guard confirmed, state.active, state.upper == upper, state.lower == lower else {
            throw FixtureBackendError.injected
        }
        state = FirmwareLimitHelperStateResponse(
            state: FirmwareLimitState(activationByte: 0x00, upper: upper, lower: lower)
        )
        pending = true
        return FirmwareLimitHelperOperationResponse(
            state: state,
            oneTimePending: true,
            message: "Fake native one-time task started."
        )
    }

    func cancelOneTimeCharge() async throws -> FirmwareLimitHelperOperationResponse {
        cancelCount += 1
        state = FirmwareLimitHelperStateResponse(
            state: FirmwareLimitState(activationByte: 0x02, upper: state.upper, lower: state.lower)
        )
        pending = false
        return FirmwareLimitHelperOperationResponse(
            state: state,
            oneTimePending: false,
            message: "Fake native limit restored."
        )
    }

    func oneTimeChargeStatus() async throws -> FirmwareLimitHelperOneTimeStatusResponse {
        FirmwareLimitHelperOneTimeStatusResponse(
            pending: pending,
            restoreUpper: pending ? state.upper : nil,
            deadlineUnixSeconds: pending ? Date().addingTimeInterval(3600).timeIntervalSince1970 : nil,
            cancelRequested: false
        )
    }
}
