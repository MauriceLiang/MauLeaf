import Foundation

private final class OfflineFakeSMC: FirmwareLimitTransport {
    var activation: UInt8 = 0x02
    var upper: Int = 80
    var lower: Int = 78
    var writes: [(String, [UInt8])] = []
    var failWrites = 0
    var ignoreWrites = 0

    func metadata(for key: FirmwareLimitKey) throws -> FirmwareLimitKeyMetadata {
        FirmwareLimitKeyMetadata(
            size: key.expectedSize,
            type: key == .activation ? "ui8 " : "ui32"
        )
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
        writes.append((key.rawValue, bytes))
        if failWrites > 0 {
            failWrites -= 1
            throw UnpluggedRestoreProbeError.firmwareWriteNotVerified("injected transport failure")
        }
        if ignoreWrites > 0 {
            ignoreWrites -= 1
            return
        }
        guard key == .activation && bytes == [0x00] else {
            fatalError("Safety violation: offline probe attempted a non-deactivation write")
        }
        activation = 0x00
    }
}

@main
private enum UnpluggedRestorePolicyTests {
    static func main() throws {
        let identity = FirmwareLimitDeviceIdentity(
            modelIdentifier: "MacBookPro18,1",
            systemFirmware: "mBoot-20457.41.3",
            macOSMajorVersion: 15,
            architecture: "arm64"
        )
        let original = try FirmwareLimitOriginalStateSnapshot(
            deviceIdentity: identity,
            state: FirmwareLimitState(activationByte: 0, upper: 80, lower: 78)
        )
        let active = FirmwareLimitState(activationByte: 2, upper: 85, lower: 83)

        func context(
            identity id: FirmwareLimitDeviceIdentity? = nil,
            snapshot: FirmwareLimitOriginalStateSnapshot? = nil,
            current: FirmwareLimitState? = nil,
            root: Bool = true,
            external: Bool? = false,
            pmsetBattery: Bool = true,
            conflict: String? = nil,
            confirmed: Bool = true
        ) -> UnpluggedRestoreConditions {
            UnpluggedRestoreConditions(
                identity: id ?? identity,
                originalSnapshot: snapshot ?? original,
                currentState: current ?? active,
                isAdministrator: root,
                externalConnected: external,
                pmsetReportsBatteryPower: pmsetBattery,
                conflictingProcess: conflict,
                explicitlyConfirmed: confirmed
            )
        }

        try UnpluggedRestorePolicy.authorize(context())

        func mustReject(_ explanation: String, _ check: () throws -> Void) {
            do {
                try check()
                fatalError("Expected rejection: \(explanation)")
            } catch is UnpluggedRestoreProbeError {
                // Expected.
            } catch {
                fatalError("Unexpected exception for \(explanation): \(error)")
            }
        }

        mustReject("AC detected") {
            try UnpluggedRestorePolicy.authorize(context(external: true))
        }
        mustReject("battery source unknown") {
            try UnpluggedRestorePolicy.authorize(context(external: nil))
        }
        mustReject("pmset disagrees") {
            try UnpluggedRestorePolicy.authorize(context(pmsetBattery: false))
        }
        mustReject("not root") {
            try UnpluggedRestorePolicy.authorize(context(root: false))
        }
        mustReject("charging controller running") {
            try UnpluggedRestorePolicy.authorize(context(conflict: "MauLeaf"))
        }
        mustReject("not explicitly authorized") {
            try UnpluggedRestorePolicy.authorize(context(confirmed: false))
        }
        mustReject("no active limit") {
            try UnpluggedRestorePolicy.authorize(context(current:
                FirmwareLimitState(activationByte: 0, upper: 85, lower: 83)))
        }
        let wrongFirmware = FirmwareLimitDeviceIdentity(
            modelIdentifier: "MacBookPro18,1",
            systemFirmware: "mBoot-20457.99.99",
            macOSMajorVersion: 15,
            architecture: "arm64"
        )
        mustReject("unverified firmware") {
            try UnpluggedRestorePolicy.authorize(context(identity: wrongFirmware))
        }
        let wrongOS = FirmwareLimitDeviceIdentity(
            modelIdentifier: "MacBookPro18,1",
            systemFirmware: "mBoot-20457.41.3",
            macOSMajorVersion: 27,
            architecture: "arm64"
        )
        mustReject("unverified OS") {
            try UnpluggedRestorePolicy.authorize(context(identity: wrongOS))
        }
        let wrongModel = FirmwareLimitDeviceIdentity(
            modelIdentifier: "MacBookPro18,2",
            systemFirmware: "mBoot-20457.41.3",
            macOSMajorVersion: 15,
            architecture: "arm64"
        )
        mustReject("different model") {
            try UnpluggedRestorePolicy.authorize(context(identity: wrongModel))
        }
        let wrongSnapshot = try FirmwareLimitOriginalStateSnapshot(
            deviceIdentity: wrongModel,
            state: original.state
        )
        mustReject("snapshot from another model") {
            try UnpluggedRestorePolicy.authorize(context(snapshot: wrongSnapshot))
        }
        let activatedOriginal = try FirmwareLimitOriginalStateSnapshot(
            deviceIdentity: identity,
            state: FirmwareLimitState(activationByte: 2, upper: 80, lower: 78)
        )
        mustReject("originally active, not safe to claim reset") {
            try UnpluggedRestorePolicy.authorize(context(snapshot: activatedOriginal))
        }

        let fake = OfflineFakeSMC()
        fake.upper = 85
        fake.lower = 83
        let result = try UnpluggedRestorePolicy.deactivate(
            transport: fake,
            baseline: active,
            preflight: {},
            pause: { _ in }
        )
        precondition(result.activationByte == 0 && fake.activation == 0
                     && fake.upper == 85 && fake.lower == 83,
                     "the sole mutation disables the charging limit")
        precondition(fake.writes.count == 1
                     && fake.writes.allSatisfy({ $0.0 == "bfF0" && $0.1 == [0x00] }),
                     "only bfF0=0x00 was written")

        let retry = OfflineFakeSMC()
        retry.upper = 85
        retry.lower = 83
        retry.ignoreWrites = 1
        let recovered = try UnpluggedRestorePolicy.deactivate(
            transport: retry,
            baseline: active,
            preflight: {},
            pause: { _ in }
        )
        precondition(!recovered.isActive && retry.writes.count == 2,
                     "transient no-effect SMC write is retried at most three times")

        let blocked = OfflineFakeSMC()
        blocked.upper = 85
        blocked.lower = 83
        mustReject("preflight power race") {
            try UnpluggedRestorePolicy.deactivate(
                transport: blocked, baseline: active,
                preflight: { throw UnpluggedRestoreProbeError.requiresUnpluggedMac },
                pause: { _ in }
            )
        }
        precondition(blocked.writes.isEmpty, "failed preflight never mutates SMC")

        let changed = OfflineFakeSMC()
        changed.upper = 90
        mustReject("stale original upper bound") {
            _ = try UnpluggedRestorePolicy.deactivate(
                transport: changed, baseline: active,
                preflight: {}, pause: { _ in }
            )
        }
        precondition(changed.writes.isEmpty, "unexpected firmware changes block all writes")

        let failures = OfflineFakeSMC()
        failures.upper = 85
        failures.lower = 83
        failures.failWrites = 10
        mustReject("repeated write failure") {
            _ = try UnpluggedRestorePolicy.deactivate(
                transport: failures, baseline: active,
                preflight: {}, pause: { _ in }
            )
        }
        precondition(failures.writes.count == 3
                     && failures.writes.allSatisfy({ $0.0 == "bfF0" && $0.1 == [0x00] }),
                     "bounded retries never re-enable the limit or touch thresholds")

        let inactive = OfflineFakeSMC()
        inactive.activation = 0
        mustReject("inactive status is not a successful active-write test") {
            _ = try UnpluggedRestorePolicy.deactivate(
                transport: inactive,
                baseline: FirmwareLimitState(activationByte: 0, upper: 85, lower: 83),
                preflight: {}, pause: { _ in }
            )
        }
        precondition(inactive.writes.isEmpty, "inactive starting point must not be modified")
        print("UnpluggedRestorePolicyTests: PASS (identity, AC mismatch, snapshot, concurrency, single-key writes, no reactivation)")
    }
}

