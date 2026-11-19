import Foundation

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
        writes.append("\(key.rawValue)=\(bytes.map { String(format: "%02X", $0) }.joined())")
        switch key {
        case .activation: activation = bytes[0]
        case .upper: upper = FirmwareLimitPolicy.decodeUInt32LittleEndian(bytes) ?? upper
        case .lower: lower = FirmwareLimitPolicy.decodeUInt32LittleEndian(bytes) ?? lower
        }
    }
}

@main
private enum FirmwareLimitHelperServiceTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mauleaf-native-helper-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let transport = HelperFakeTransport()
        var onAC = true
        var observation = FirmwareLimitBatteryObservation(percent: 90, fullyCharged: false, externalConnected: true)
        let identity = FirmwareLimitDeviceIdentity(
            modelIdentifier: "MacBookPro18,1",
            systemFirmware: "mBoot-20457.41.3",
            macOSMajorVersion: 15,
            architecture: "arm64"
        )
        let service = FirmwareLimitHelperService(
            transport: transport,
            identityProvider: { identity },
            isOnACPower: { onAC },
            isAdministrator: { true },
            batteryObservation: { observation },
            jobURL: directory.appendingPathComponent("one-time-charge.json"),
            monitorEnabled: false
        )

        var stateData: NSData?
        var stateError: NSString?
        service.readState { data, error in stateData = data; stateError = error }
        precondition(stateError == nil, "readState must not return an error")
        let state = try JSONDecoder().decode(FirmwareLimitHelperStateResponse.self, from: stateData! as Data)
        precondition(state == FirmwareLimitHelperStateResponse(
            state: FirmwareLimitState(activationByte: 0, upper: 80, lower: 78)
        ), "readState returns the observed fake hardware state")
        precondition(transport.writes.isEmpty, "readState never writes SMC")

        var planData: NSData?
        var planError: NSString?
        service.makePlan(upper: 85, lower: 83) { data, error in planData = data; planError = error }
        precondition(planError == nil, "makePlan accepts a valid band")
        let plan = try JSONDecoder().decode(FirmwareLimitHelperPlanResponse.self, from: planData! as Data)
        precondition(plan.steps == [
            "bfF0 = 0x00 (deactivate)",
            "bfD0 = 85 (upper)",
            "bfE0 = 83 (lower)",
            "bfF0 = 0x02 (activate)"
        ], "makePlan returns the reviewed transaction order")
        precondition(transport.writes.isEmpty, "makePlan never writes SMC")

        var invalidData: NSData?
        var invalidError: NSString?
        service.makePlan(upper: 80, lower: 80) { data, error in invalidData = data; invalidError = error }
        precondition(invalidData == nil && invalidError != nil, "invalid bands are rejected")
        precondition(transport.writes.isEmpty, "invalid plan requests never write SMC")

        var applyData: NSData?
        var applyError: NSString?
        service.applyLimit(upper: 85, lower: 83, confirmed: true) { data, error in applyData = data; applyError = error }
        precondition(applyError == nil, "confirmed native limit application succeeds with fake transport")
        let applied = try JSONDecoder().decode(FirmwareLimitHelperOperationResponse.self, from: applyData! as Data)
        precondition(applied.state.active && applied.state.upper == 85 && applied.state.lower == 83,
                     "native limit application returns the verified register state")
        precondition(transport.writes == [
            "bfF0=00", "bfD0=55000000", "bfE0=53000000", "bfF0=02"
        ], "native helper applies the guarded firmware transaction")

        var unconfirmedData: NSData?
        var unconfirmedError: NSString?
        service.applyLimit(upper: 90, lower: 88, confirmed: false) { data, error in
            unconfirmedData = data; unconfirmedError = error
        }
        precondition(unconfirmedData == nil && unconfirmedError != nil,
                     "SMC writes require explicit user confirmation")

        var beginData: NSData?
        var beginError: NSString?
        service.beginOneTimeCharge(upper: 85, lower: 83, confirmed: true) { data, error in
            beginData = data; beginError = error
        }
        precondition(beginError == nil, "one-time full charge starts")
        let begun = try JSONDecoder().decode(FirmwareLimitHelperOperationResponse.self, from: beginData! as Data)
        precondition(begun.oneTimePending && !begun.state.active,
                     "one-time full charge deactivates the firmware limit and persists a job")
        precondition(service.hasPendingOneTimeCharge, "helper retains the one-time task after the XPC request")

        onAC = false
        var cancelData: NSData?
        var cancelError: NSString?
        service.cancelOneTimeCharge { data, error in cancelData = data; cancelError = error }
        precondition(cancelError == nil, "cancellation can be recorded while on battery")
        let waiting = try JSONDecoder().decode(FirmwareLimitHelperOperationResponse.self, from: cancelData! as Data)
        precondition(waiting.oneTimePending, "restore waits until AC power is available")

        onAC = true
        service.runOneTimeMonitorTickForTesting()
        precondition(!service.hasPendingOneTimeCharge, "pending cancellation restores once AC returns")
        precondition(transport.activation == 2 && transport.upper == 85 && transport.lower == 83,
                     "cancellation restores and verifies the original native limit")

        var secondBeginError: NSString?
        service.beginOneTimeCharge(upper: 85, lower: 83, confirmed: true) { _, error in secondBeginError = error }
        precondition(secondBeginError == nil, "a second one-time task can start after the first completes")
        observation = FirmwareLimitBatteryObservation(percent: 100, fullyCharged: true, externalConnected: true)
        service.runOneTimeMonitorTickForTesting()
        precondition(!service.hasPendingOneTimeCharge, "100% battery triggers native limit restoration")
        precondition(transport.activation == 2 && transport.upper == 85 && transport.lower == 83,
                     "automatic completion restores the exact saved thresholds")

        print("FirmwareLimitHelperServiceTests: PASS (native helper, guarded writes, persistent one-time restore)")
    }
}
