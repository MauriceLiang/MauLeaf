import Foundation

private enum FakeTransportError: Error {
    case injectedWriteFailure
}

private final class FakeFirmwareLimitTransport: FirmwareLimitTransport {
    var metadataValues: [FirmwareLimitKey: FirmwareLimitKeyMetadata] = [
        .activation: FirmwareLimitKeyMetadata(size: 1, type: "ui8 "),
        .upper: FirmwareLimitKeyMetadata(size: 4, type: "ui32"),
        .lower: FirmwareLimitKeyMetadata(size: 4, type: "ui32")
    ]
    var activation: UInt8 = 0x00
    var upper = 80
    var lower = 78
    var writes: [String] = []
    var writeCount = 0
    var failuresRemainingByKey: [FirmwareLimitKey: Int] = [:]
    var mismatchedReadKey: FirmwareLimitKey?

    func metadata(for key: FirmwareLimitKey) throws -> FirmwareLimitKeyMetadata {
        guard let value = metadataValues[key] else { throw FakeTransportError.injectedWriteFailure }
        return value
    }

    func read(_ key: FirmwareLimitKey, count: Int) throws -> [UInt8] {
        let bytes: [UInt8]
        switch key {
        case .activation: bytes = [activation]
        case .upper: bytes = FirmwareLimitPolicy.encodeUInt32LittleEndian(upper)
        case .lower: bytes = FirmwareLimitPolicy.encodeUInt32LittleEndian(lower)
        }
        if mismatchedReadKey == key {
            var changed = bytes
            if !changed.isEmpty { changed[0] ^= 0x01 }
            return Array(changed.prefix(count))
        }
        return Array(bytes.prefix(count))
    }

    func write(_ key: FirmwareLimitKey, bytes: [UInt8]) throws {
        writeCount += 1
        writes.append("\(key.rawValue)=\(bytes.map { String(format: "%02X", $0) }.joined())")
        if let remaining = failuresRemainingByKey[key], remaining > 0 {
            failuresRemainingByKey[key] = remaining - 1
            throw FakeTransportError.injectedWriteFailure
        }
        switch key {
        case .activation:
            guard bytes.count == 1 else { throw FakeTransportError.injectedWriteFailure }
            activation = bytes[0]
        case .upper:
            guard let value = FirmwareLimitPolicy.decodeUInt32LittleEndian(bytes) else {
                throw FakeTransportError.injectedWriteFailure
            }
            upper = value
        case .lower:
            guard let value = FirmwareLimitPolicy.decodeUInt32LittleEndian(bytes) else {
                throw FakeTransportError.injectedWriteFailure
            }
            lower = value
        }
    }
}

@main
private enum FirmwareLimitCoreTests {
    private static var checks = 0

    static func main() throws {
        try testRequestValidation()
        testMetadataPolicy()
        testEncoding()
        try testReadOnlyPlan()
        try testConfigureSequence()
        try testTransientWriteFailureRetries()
        try testNoOp()
        try testDeactivate()
        try testExactOriginalStateRestore()
        try testInactiveZeroBandAfterReboot()
        try testOriginalStateSnapshot()
        try testSafetyPermit()
        try testRestorePermitAcrossOSUpgrade()
        try testInvalidStateRefusesWrites()
        try testUnexpectedMetadataRefusesWrites()
        try testRollbackRestoresPreviousState()
        try testRollbackFallsBackToInactive()
        print("FirmwareLimitCoreTests: PASS (\(checks) assertions; no hardware writes)")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !condition() {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    private static func expectThrows(_ body: () throws -> Void, _ message: String) {
        checks += 1
        do {
            try body()
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        } catch {
            // Expected.
        }
    }

    private static func controller(_ transport: FakeFirmwareLimitTransport) -> FirmwareLimitController {
        FirmwareLimitController(transport: transport, wait: { _ in })
    }

    private static func permit() throws -> FirmwareLimitWritePermit {
        try FirmwareLimitWritePermit.authorize(
            identity: FirmwareLimitDeviceIdentity(
                modelIdentifier: "MacBookPro18,1",
                systemFirmware: "mBoot-20457.41.3",
                macOSMajorVersion: 15,
                architecture: "arm64"
            ),
            context: FirmwareLimitWriteContext(
                isAdministrator: true,
                isOnACPower: true,
                userConfirmed: true
            )
        )
    }

    private static func testRequestValidation() throws {
        let standard = try FirmwareLimitRequest.standard(upper: 80)
        let expected = try FirmwareLimitRequest(upper: 80, lower: 78)
        expect(standard == expected, "default resume threshold is two points below upper")
        expectThrows({ _ = try FirmwareLimitRequest(upper: 49, lower: 47) }, "upper below MauLeaf's 50% floor is rejected")
        let temporary = try FirmwareLimitRequest(upper: 100, lower: 78)
        expect(temporary.upper == 100,
               "experimental hold can use a temporary 100 percent firmware ceiling")
        expectThrows({ _ = try FirmwareLimitRequest(upper: 101, lower: 78) },
                     "upper above hardware 100 percent is rejected")
        expectThrows({ _ = try FirmwareLimitRequest(upper: 80, lower: 80) }, "lower must be below upper")
        expectThrows({ _ = try FirmwareLimitRequest(upper: 80, lower: 4) }, "lower below 5% is rejected")
    }

    private static func testMetadataPolicy() {
        expect(FirmwareLimitPolicy.accepts(.init(size: 1, type: "ui8 "), for: .activation), "bfF0 accepts ui8 metadata")
        expect(FirmwareLimitPolicy.accepts(.init(size: 4, type: "ui32"), for: .upper), "bfD0 accepts ui32 metadata")
        expect(FirmwareLimitPolicy.accepts(.init(size: 0, type: ""), for: .lower), "unpopulated metadata is accepted for direct-read validation")
        expect(FirmwareLimitPolicy.accepts(.init(size: 0, type: "ui32"), for: .lower), "zero-size metadata with expected type is accepted")
        expect(!FirmwareLimitPolicy.accepts(.init(size: 1, type: "ui32"), for: .activation), "wrong activation type is rejected")
        expect(!FirmwareLimitPolicy.accepts(.init(size: 8, type: "ui32"), for: .upper), "wrong register width is rejected")
    }

    private static func testEncoding() {
        expect(FirmwareLimitPolicy.encodeUInt32LittleEndian(80) == [0x50, 0, 0, 0], "80% is encoded little-endian")
        expect(FirmwareLimitPolicy.decodeUInt32LittleEndian([0x4E, 0, 0, 0]) == 78, "78% is decoded little-endian")
        expect(FirmwareLimitPolicy.decodeUInt32LittleEndian([0x4E, 0, 0]) == nil, "short uint32 payload is rejected")
    }

    private static func testReadOnlyPlan() throws {
        let transport = FakeFirmwareLimitTransport()
        let plan = try controller(transport).makePlan(for: FirmwareLimitRequest(upper: 85, lower: 83))
        expect(plan.previous == FirmwareLimitState(activationByte: 0, upper: 80, lower: 78), "plan records the actual pre-write state")
        expect(plan.steps == [.deactivate, .writeUpper(85), .writeLower(83), .activate], "plan uses required deactivate/upper/lower/activate order")
        expect(transport.writes.isEmpty, "planning never writes SMC")
    }

    private static func testConfigureSequence() throws {
        let transport = FakeFirmwareLimitTransport()
        let final = try controller(transport).configure(
            FirmwareLimitRequest(upper: 85, lower: 83),
            permit: permit()
        )
        expect(final == FirmwareLimitState(activationByte: 2, upper: 85, lower: 83), "configure returns verified active state")
        expect(transport.writes == [
            "bfF0=00", "bfD0=55000000", "bfE0=53000000", "bfF0=02"
        ], "writes follow the firmware-required order")
    }

    private static func testTransientWriteFailureRetries() throws {
        let transport = FakeFirmwareLimitTransport()
        transport.failuresRemainingByKey[.lower] = 1
        let final = try controller(transport).configure(
            FirmwareLimitRequest(upper: 85, lower: 83),
            permit: permit()
        )
        expect(final == FirmwareLimitState(activationByte: 2, upper: 85, lower: 83),
               "a transient write failure is retried and verified")
        expect(transport.writes.filter { $0 == "bfE0=53000000" }.count == 2,
               "a failed lower-threshold write is retried once")
    }

    private static func testNoOp() throws {
        let transport = FakeFirmwareLimitTransport()
        transport.activation = 0x02
        let final = try controller(transport).configure(
            FirmwareLimitRequest(upper: 80, lower: 78),
            permit: permit()
        )
        expect(final.isActive, "already matching active state is returned")
        expect(transport.writes.isEmpty, "matching state does not cause redundant writes")
    }

    private static func testDeactivate() throws {
        let transport = FakeFirmwareLimitTransport()
        transport.activation = 0x02
        let final = try controller(transport).deactivate(permit: permit())
        expect(final.activationByte == 0, "deactivate confirms firmware limit is off")
        expect(final.upper == 80 && final.lower == 78, "deactivate leaves both thresholds unchanged")
        expect(transport.writes == ["bfF0=00"], "deactivate writes only activation byte")
    }

    private static func testExactOriginalStateRestore() throws {
        let transport = FakeFirmwareLimitTransport()
        transport.activation = 0x02
        transport.upper = 85
        transport.lower = 83
        let original = FirmwareLimitState(activationByte: 0x00, upper: 80, lower: 78)
        let restored = try controller(transport).restore(original, permit: permit())
        expect(restored == original, "restore returns the exact saved firmware state")
        expect(transport.activation == 0x00 && transport.upper == 80 && transport.lower == 78,
               "restore writes the original activation byte and both thresholds")
        expect(transport.writes == [
            "bfF0=00", "bfE0=4E000000", "bfD0=50000000"
        ], "restore disables bfF0 before lowering the lower bound and then upper bound")

        // The opposite direction must first raise the upper bound.
        let smaller = FakeFirmwareLimitTransport()
        smaller.activation = 0x02
        smaller.upper = 75
        smaller.lower = 73
        let raised = try controller(smaller).restore(original, permit: permit())
        expect(raised == original, "restoration from a smaller range succeeds")
        expect(smaller.writes == [
            "bfF0=00", "bfD0=50000000", "bfE0=4E000000"
        ], "raising the band writes upper before lower")

        // A lost power-source preflight blocks all further writes and
        // preserves the already-disabled activation state.
        let gated = FakeFirmwareLimitTransport()
        gated.activation = 0x02
        gated.upper = 85
        gated.lower = 83
        var preflightCount = 0
        expectThrows({
            _ = try controller(gated).restore(original, permit: permit(), preflight: {
                preflightCount += 1
                if preflightCount == 2 {
                    throw FirmwareLimitCoreError.externalPowerRequired
                }
            })
        }, "power-state change in the middle blocks subsequent threshold writes")
        expect(gated.activation == 0x00 && gated.upper == 85 && gated.lower == 83,
               "abort after activation-off never reactivates or mutates thresholds")

        let partiallyWritten = FakeFirmwareLimitTransport()
        partiallyWritten.activation = 0x02
        partiallyWritten.upper = 40
        partiallyWritten.lower = 45
        let recovered = try controller(partiallyWritten).restore(original, permit: permit())
        expect(recovered == original,
               "restore can recover from an invalid intermediate threshold pair after a partial write")
    }

    private static func testInactiveZeroBandAfterReboot() throws {
        let transport = FakeFirmwareLimitTransport()
        transport.activation = 0x00
        transport.upper = 0
        transport.lower = 0

        let state = try controller(transport).readState()
        expect(state.isInactiveUninitialized && !state.isValid && !state.isActive,
               "inactive zero/zero is observable after reboot but cannot be a trusted original state")
        expect(transport.writes.isEmpty, "startup state reads never write SMC")

        let original = FirmwareLimitState(activationByte: 0x00, upper: 80, lower: 78)
        let recovered = try controller(transport).restore(original, permit: permit())
        expect(recovered == original && transport.upper == 80 && transport.lower == 78,
               "identity-authorized exact snapshot restoration works from zero/zero")
        expect(transport.writes == [
            "bfD0=50000000",
            "bfE0=4E000000"
        ], "inactive zero/zero restores upper before lower, preserving inactive activation")
        expect(try controller(transport).readState() == original,
               "restoration must pass exact hardware readback")

        let badActive = FakeFirmwareLimitTransport()
        badActive.activation = 0x02
        badActive.upper = 0
        badActive.lower = 0
        expectThrows({ _ = try controller(badActive).readState() },
                     "active zero/zero stays invalid and fails closed")
        expect(badActive.writes.isEmpty, "active invalid state never causes an automatic write")

        let badPartial = FakeFirmwareLimitTransport()
        badPartial.upper = 0
        badPartial.lower = 78
        expectThrows({ _ = try controller(badPartial).readState() },
                     "partly zeroed bands remain invalid and cannot be normalized")
        expect(badPartial.writes.isEmpty, "partial zero state remains read-only")
    }

    private static func testOriginalStateSnapshot() throws {
        let identity = FirmwareLimitDeviceIdentity(
            modelIdentifier: "MacBookPro18,1",
            systemFirmware: "mBoot-20457.41.3",
            macOSMajorVersion: 15,
            architecture: "arm64"
        )
        var snapshot = try FirmwareLimitOriginalStateSnapshot(
            deviceIdentity: identity,
            state: FirmwareLimitState(activationByte: 0x00, upper: 80, lower: 78)
        )
        snapshot.restoreRequested = true
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(FirmwareLimitOriginalStateSnapshot.self, from: data)
        expect(decoded == snapshot && decoded.isValid,
               "the root helper snapshot round-trips the exact state and durable restore request")
    }

    private static func testSafetyPermit() throws {
        let identity = FirmwareLimitDeviceIdentity(
            modelIdentifier: "MacBookPro18,1",
            systemFirmware: "mBoot-20457.41.3",
            macOSMajorVersion: 15,
            architecture: "arm64"
        )
        let base = FirmwareLimitWriteContext(
            isAdministrator: true, isOnACPower: true,
            userConfirmed: true
        )
        _ = try FirmwareLimitWritePermit.authorize(identity: identity, context: base)
        let originalSnapshot = try FirmwareLimitOriginalStateSnapshot(
            deviceIdentity: identity,
            state: FirmwareLimitState(activationByte: 0, upper: 80, lower: 78)
        )
        let offline = FirmwareLimitOfflineRestoreContext(
            isAdministrator: true,
            externalConnected: false,
            pmsetReportsBatteryPower: true,
            batteryPercent: 85,
            isCharging: false,
            userConfirmed: true
        )
        _ = try FirmwareLimitWritePermit.authorizeOfflineRestore(
            identity: identity, snapshot: originalSnapshot, context: offline
        )
        expectThrows({
            _ = try FirmwareLimitWritePermit.authorizeOfflineRestore(
                identity: identity, snapshot: originalSnapshot,
                context: FirmwareLimitOfflineRestoreContext(
                    isAdministrator: true, externalConnected: true,
                    pmsetReportsBatteryPower: true, batteryPercent: 85,
                    isCharging: false, userConfirmed: true
                )
            )
        }, "offline restoration refuses AC mismatch")
        expectThrows({
            _ = try FirmwareLimitWritePermit.authorizeOfflineRestore(
                identity: identity, snapshot: originalSnapshot,
                context: FirmwareLimitOfflineRestoreContext(
                    isAdministrator: true, externalConnected: false,
                    pmsetReportsBatteryPower: false, batteryPercent: 85,
                    isCharging: false, userConfirmed: true
                )
            )
        }, "offline restoration requires pmset confirmation")
        expectThrows({
            _ = try FirmwareLimitWritePermit.authorizeOfflineRestore(
                identity: identity, snapshot: originalSnapshot,
                context: FirmwareLimitOfflineRestoreContext(
                    isAdministrator: true, externalConnected: false,
                    pmsetReportsBatteryPower: true, batteryPercent: 20,
                    isCharging: false, userConfirmed: true
                )
            )
        }, "offline restoration refuses low battery")
        expectThrows({
            _ = try FirmwareLimitWritePermit.authorizeOfflineRestore(
                identity: identity, snapshot: originalSnapshot,
                context: FirmwareLimitOfflineRestoreContext(
                    isAdministrator: true, externalConnected: false,
                    pmsetReportsBatteryPower: true, batteryPercent: 85,
                    isCharging: true, userConfirmed: true
                )
            )
        }, "offline restoration refuses contradictory charging telemetry")
        let oldActive = try FirmwareLimitOriginalStateSnapshot(
            deviceIdentity: identity,
            state: FirmwareLimitState(activationByte: 2, upper: 80, lower: 78)
        )
        expectThrows({
            _ = try FirmwareLimitWritePermit.authorizeOfflineRestore(
                identity: identity, snapshot: oldActive, context: offline
            )
        }, "offline restoration refuses originally active state")

        let missingFirmware = FirmwareLimitDeviceIdentity(
            modelIdentifier: identity.modelIdentifier,
            systemFirmware: "",
            macOSMajorVersion: 15,
            architecture: "arm64"
        )
        expect(
            FirmwareLimitWritePermit.targetBlockReason(identity: missingFirmware)
                == "Unable to read system-firmware-version from the IODeviceTree; firmware writes are blocked.",
            "missing firmware metadata is reported explicitly and remains write-blocked"
        )
        expectThrows({
            _ = try FirmwareLimitWritePermit.authorize(
                identity: identity,
                context: FirmwareLimitWriteContext(
                    isAdministrator: true, isOnACPower: false,
                    userConfirmed: true
                )
            )
        }, "no AC power blocks write authorization")
        expectThrows({
            _ = try FirmwareLimitWritePermit.authorize(
                identity: identity,
                context: FirmwareLimitWriteContext(
                    isAdministrator: false, isOnACPower: true,
                    userConfirmed: true
                )
            )
        }, "non-administrator blocks write authorization")
        expectThrows({
            _ = try FirmwareLimitWritePermit.authorize(
                identity: identity,
                context: FirmwareLimitWriteContext(
                    isAdministrator: true, isOnACPower: true,
                    userConfirmed: false
                )
            )
        }, "missing typed confirmation blocks write authorization")
        expectThrows({
            _ = try FirmwareLimitWritePermit.authorize(
                identity: FirmwareLimitDeviceIdentity(
                    modelIdentifier: "MacBookAir10,1",
                    systemFirmware: identity.systemFirmware,
                    macOSMajorVersion: 15,
                    architecture: "arm64"
                ),
                context: base
            )
        }, "unverified Mac model is rejected")
        expectThrows({
            _ = try FirmwareLimitWritePermit.authorize(
                identity: FirmwareLimitDeviceIdentity(
                    modelIdentifier: identity.modelIdentifier,
                    systemFirmware: "mBoot-20457.1.29",
                    macOSMajorVersion: 15,
                    architecture: "arm64"
                ),
                context: base
            )
        }, "different firmware build is rejected")
        expectThrows({
            _ = try FirmwareLimitWritePermit.authorize(
                identity: FirmwareLimitDeviceIdentity(
                    modelIdentifier: identity.modelIdentifier,
                    systemFirmware: identity.systemFirmware,
                    macOSMajorVersion: 27,
                    architecture: "arm64"
                ),
                context: base
            )
        }, "unverified macOS major version is rejected")
    }

    private static func testRestorePermitAcrossOSUpgrade() throws {
        let savedIdentity = FirmwareLimitDeviceIdentity(
            modelIdentifier: "MacBookPro18,1",
            systemFirmware: "mBoot-20457.41.3",
            macOSMajorVersion: 15,
            architecture: "arm64"
        )
        let upgradedIdentity = FirmwareLimitDeviceIdentity(
            modelIdentifier: savedIdentity.modelIdentifier,
            systemFirmware: savedIdentity.systemFirmware,
            macOSMajorVersion: 27,
            architecture: savedIdentity.architecture
        )
        let context = FirmwareLimitWriteContext(
            isAdministrator: true,
            isOnACPower: true,
            userConfirmed: true
        )
        expect(FirmwareLimitWritePermit.targetBlockReason(identity: upgradedIdentity) != nil,
               "new charging-limit writes remain blocked on an unvalidated OS")
        _ = try FirmwareLimitWritePermit.authorizeRestore(
            identity: upgradedIdentity,
            snapshotIdentity: savedIdentity,
            context: context
        )
        let changedFirmware = FirmwareLimitDeviceIdentity(
            modelIdentifier: savedIdentity.modelIdentifier,
            systemFirmware: "different-firmware",
            macOSMajorVersion: 27,
            architecture: savedIdentity.architecture
        )
        expectThrows({
            _ = try FirmwareLimitWritePermit.authorizeRestore(
                identity: changedFirmware,
                snapshotIdentity: savedIdentity,
                context: context
            )
        }, "restore is blocked when the saved model or firmware identity no longer matches")
    }

    private static func testInvalidStateRefusesWrites() throws {
        let transport = FakeFirmwareLimitTransport()
        transport.activation = 0x01
        expectThrows({ _ = try controller(transport).readState() }, "unknown activation byte is rejected")
        expect(transport.writes.isEmpty, "invalid activation state causes no writes")

        let invalidBand = FakeFirmwareLimitTransport()
        invalidBand.lower = 80
        expectThrows({ _ = try controller(invalidBand).readState() }, "invalid stored lower/upper band is rejected")
        expect(invalidBand.writes.isEmpty, "invalid stored band causes no writes")
    }

    private static func testUnexpectedMetadataRefusesWrites() throws {
        let transport = FakeFirmwareLimitTransport()
        transport.metadataValues[.upper] = FirmwareLimitKeyMetadata(size: 8, type: "ui64")
        expectThrows({ _ = try controller(transport).configure(
            FirmwareLimitRequest(upper: 85, lower: 83),
            permit: permit()
        ) }, "unexpected key metadata prevents configuration")
        expect(transport.writes.isEmpty, "unexpected key metadata causes no writes")
    }

    private static func testRollbackRestoresPreviousState() throws {
        let transport = FakeFirmwareLimitTransport()
        transport.activation = 0x02
        transport.failuresRemainingByKey[.lower] = 3
        expectThrows({ _ = try controller(transport).configure(
            FirmwareLimitRequest(upper: 85, lower: 83),
            permit: permit()
        ) }, "injected write failure is surfaced")
        expect(transport.activation == 0x02 && transport.upper == 80 && transport.lower == 78,
               "failed transaction restores and verifies previous active state")
    }

    private static func testRollbackFallsBackToInactive() throws {
        let transport = FakeFirmwareLimitTransport()
        transport.activation = 0x02
        transport.mismatchedReadKey = .upper
        expectThrows({ _ = try controller(transport).configure(
            FirmwareLimitRequest(upper: 85, lower: 83),
            permit: permit()
        ) }, "readback mismatch is surfaced")
        expect(transport.activation == 0x00, "failed rollback falls back to verified inactive state")
    }
}
