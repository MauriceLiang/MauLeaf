import Foundation

private enum HelperTestError: Error {
    case missingMetadata
}

private final class HelperFakeTransport: FirmwareLimitTransport {
    var activation: UInt8 = 0
    var upper = 80
    var lower = 78
    var writes: [String] = []

    func metadata(for key: FirmwareLimitKey) throws -> FirmwareLimitKeyMetadata {
        switch key {
        case .activation: return FirmwareLimitKeyMetadata(size: 1, type: "ui8 ")
        case .upper, .lower: return FirmwareLimitKeyMetadata(size: 4, type: "ui32")
        }
    }

    func read(_ key: FirmwareLimitKey, count: Int) throws -> [UInt8] {
        let bytes: [UInt8]
        switch key {
        case .activation: bytes = [activation]
        case .upper: bytes = FirmwareLimitPolicy.encodeUInt32LittleEndian(upper)
        case .lower: bytes = FirmwareLimitPolicy.encodeUInt32LittleEndian(lower)
        }
        return Array(bytes.prefix(count))
    }

    func write(_ key: FirmwareLimitKey, bytes: [UInt8]) throws {
        writes.append(key.rawValue)
        switch key {
        case .activation:
            activation = bytes[0]
        case .upper:
            upper = FirmwareLimitPolicy.decodeUInt32LittleEndian(bytes) ?? upper
        case .lower:
            lower = FirmwareLimitPolicy.decodeUInt32LittleEndian(bytes) ?? lower
        }
    }
}

@main
private enum FirmwareLimitHelperServiceTests {
    static func main() throws {
        let transport = HelperFakeTransport()
        let service = FirmwareLimitHelperService(transport: transport)

        var stateData: NSData?
        var stateError: NSString?
        service.readState { data, error in
            stateData = data
            stateError = error
        }
        precondition(stateError == nil, "readState must not return an error")
        let state = try JSONDecoder().decode(
            FirmwareLimitHelperStateResponse.self,
            from: stateData! as Data
        )
        precondition(state == FirmwareLimitHelperStateResponse(
            state: FirmwareLimitState(activationByte: 0, upper: 80, lower: 78)
        ), "readState returns the observed fake hardware state")
        precondition(transport.writes.isEmpty, "readState must never write SMC")

        var planData: NSData?
        var planError: NSString?
        service.makePlan(upper: 85, lower: 83) { data, error in
            planData = data
            planError = error
        }
        precondition(planError == nil, "makePlan must not return an error for a valid band")
        let plan = try JSONDecoder().decode(
            FirmwareLimitHelperPlanResponse.self,
            from: planData! as Data
        )
        precondition(plan.steps == [
            "bfF0 = 0x00 (deactivate)",
            "bfD0 = 85 (upper)",
            "bfE0 = 83 (lower)",
            "bfF0 = 0x02 (activate)"
        ], "makePlan returns the reviewed transaction order")
        precondition(transport.writes.isEmpty, "makePlan must never write SMC")

        var invalidData: NSData?
        var invalidError: NSString?
        service.makePlan(upper: 80, lower: 80) { data, error in
            invalidData = data
            invalidError = error
        }
        precondition(invalidData == nil && invalidError != nil, "invalid bands are rejected at the XPC service boundary")
        precondition(transport.writes.isEmpty, "invalid plan requests still perform no SMC writes")

        print("FirmwareLimitHelperServiceTests: PASS (8 assertions; read-only fake transport)")
    }
}
