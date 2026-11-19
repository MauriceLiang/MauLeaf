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
        precondition(
            SystemFirmwareReader.decode("mBoot-20457.41.3") == "mBoot-20457.41.3",
            "firmware version strings are preserved"
        )
        precondition(
            SystemFirmwareReader.decode(Data("mBoot-20457.41.3".utf8) + Data([0, 0])) == "mBoot-20457.41.3",
            "CFData-style firmware values are decoded and trailing NUL bytes removed"
        )
        precondition(SystemFirmwareReader.decode(Data([0xFF, 0x00])) == nil,
                     "invalid firmware bytes are rejected")
        let legacyState = Data(#"{ "activationByte": 0, "active": false, "upper": 80, "lower": 78 }"#.utf8)
        let legacyResponse = try JSONDecoder().decode(FirmwareLimitHelperStateResponse.self, from: legacyState)
        precondition(legacyResponse.helperVersion == 0,
                     "a response from the previously installed helper is detected as outdated")

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
        let jobURL = directory.appendingPathComponent("one-time-charge.json")
        let originalStateURL = directory.appendingPathComponent("original-firmware-state.json")
        let restoreRequestURL = directory.appendingPathComponent("restore-original-state.pending")
        let service = FirmwareLimitHelperService(
            transport: transport,
            identityProvider: { identity },
            isOnACPower: { onAC },
            isAdministrator: { true },
            batteryObservation: { observation },
            jobURL: jobURL,
            originalStateURL: originalStateURL,
            restoreRequestURL: restoreRequestURL,
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
        let savedSnapshot = try JSONDecoder().decode(
            FirmwareLimitOriginalStateSnapshot.self,
            from: Data(contentsOf: originalStateURL)
        )
        precondition(savedSnapshot.state == FirmwareLimitState(activationByte: 0, upper: 80, lower: 78),
                     "the helper persists the exact original activation flag and thresholds before writing")
        precondition((try FileManager.default.attributesOfItem(atPath: originalStateURL.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600,
                     "the original-state snapshot is owner-only")

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

        var restoreData: NSData?
        var restoreError: NSString?
        service.restoreOriginalState { data, error in restoreData = data; restoreError = error }
        precondition(restoreError == nil, "disabling MauLeaf restores the saved original state")
        let restored = try JSONDecoder().decode(FirmwareLimitHelperOperationResponse.self, from: restoreData! as Data)
        precondition(!restored.state.active && restored.state.upper == 80 && restored.state.lower == 78,
                     "disable restores the original activation byte and both thresholds")
        precondition(!FileManager.default.fileExists(atPath: originalStateURL.path)
                     && !FileManager.default.fileExists(atPath: restoreRequestURL.path),
                     "the snapshot is removed only after successful read-back verification")

        var secondApplyError: NSString?
        service.applyLimit(upper: 85, lower: 83, confirmed: true) { _, error in secondApplyError = error }
        precondition(secondApplyError == nil, "a new managed limit can be enabled after restoring the original state")
        onAC = false
        var queuedRestoreError: NSString?
        service.restoreOriginalState { _, error in queuedRestoreError = error }
        precondition(queuedRestoreError != nil, "restoration refuses to write without AC power")
        let queuedSnapshot = try JSONDecoder().decode(
            FirmwareLimitOriginalStateSnapshot.self,
            from: Data(contentsOf: originalStateURL)
        )
        precondition(queuedSnapshot.restoreRequested
                     && FileManager.default.fileExists(atPath: restoreRequestURL.path),
                     "a failed unplugged restore keeps the snapshot and durable retry marker")
        onAC = true
        service.runOneTimeMonitorTickForTesting()
        precondition(!FileManager.default.fileExists(atPath: originalStateURL.path)
                     && transport.activation == 0 && transport.upper == 80 && transport.lower == 78,
                     "the helper retries and completes the original-state restore after AC returns")

        let upgradedIdentity = FirmwareLimitDeviceIdentity(
            modelIdentifier: identity.modelIdentifier,
            systemFirmware: identity.systemFirmware,
            macOSMajorVersion: 27,
            architecture: identity.architecture
        )
        precondition(FirmwareLimitWritePermit.targetBlockReason(identity: upgradedIdentity) != nil,
                     "new firmware writes remain blocked on an unvalidated macOS release")
        precondition(FirmwareLimitWritePermit.restoreBlockReason(
            identity: upgradedIdentity,
            snapshotIdentity: identity
        ) == nil, "exact snapshot restoration remains available after an OS upgrade")

        let legacyTransport = HelperFakeTransport()
        legacyTransport.activation = 0x02
        legacyTransport.upper = 85
        legacyTransport.lower = 83
        let legacyService = FirmwareLimitHelperService(
            transport: legacyTransport,
            identityProvider: { identity },
            isOnACPower: { true },
            isAdministrator: { true },
            batteryObservation: { observation },
            jobURL: directory.appendingPathComponent("legacy-one-time-charge.json"),
            originalStateURL: directory.appendingPathComponent("legacy-original-state.json"),
            restoreRequestURL: directory.appendingPathComponent("legacy-restore.pending"),
            monitorEnabled: false
        )
        var legacyData: NSData?
        var legacyError: NSString?
        legacyService.restoreOriginalState { data, error in legacyData = data; legacyError = error }
        precondition(legacyError == nil, "legacy Preview 4 limits can be safely deactivated")
        let legacyResponse = try JSONDecoder().decode(FirmwareLimitHelperOperationResponse.self, from: legacyData! as Data)
        precondition(!legacyResponse.state.active && legacyTransport.upper == 85 && legacyTransport.lower == 83,
                     "legacy migration only clears the activation flag and never invents original thresholds")
        precondition(legacyResponse.message.contains("cannot be reconstructed"),
                     "legacy migration explicitly reports that historical thresholds are unavailable")

        print("FirmwareLimitHelperServiceTests: PASS (snapshot, exact restore, deferred restore, legacy migration)")
    }
}
