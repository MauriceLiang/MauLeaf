import Foundation

@main
private enum FirmwareLimitPolicyAdapterTests {
    private static var checks = 0

    static func main() throws {
        let report = FirmwareLimitCompatibilityClassifier.classify(targetEvidence())
        testTargetClassifiesAsCandidate(report)
        try testLimitedPolicy(report)
        try testFullPolicies(report)
        testDischargeRemainsUnsupported(report)
        testUnsafeUpperIsBlocked(report)
        testUnverifiedIdentityIsUnsupported()
        testMissingFirmwareKeyIsUnsupported()
        print("FirmwareLimitPolicyAdapterTests: PASS (\(checks) assertions; no hardware writes)")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !condition() {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    private static func targetEvidence() -> FirmwareLimitHardwareEvidence {
        FirmwareLimitHardwareEvidence(
            identity: FirmwareLimitDeviceIdentity(
                modelIdentifier: "MacBookPro18,1",
                systemFirmware: "mBoot-20457.41.3",
                macOSMajorVersion: 15,
                architecture: "arm64"
            ),
            keys: [
                "bfF0": FirmwareLimitKeyObservation(present: true, size: 1, type: "ui8 ", bytes: [0x00]),
                "bfD0": FirmwareLimitKeyObservation(present: true, size: 4, type: "ui32", bytes: [0x50, 0, 0, 0]),
                "bfE0": FirmwareLimitKeyObservation(present: true, size: 4, type: "ui32", bytes: [0x4E, 0, 0, 0]),
                "CH0B": FirmwareLimitKeyObservation(present: false, size: 0, type: "", bytes: []),
                "CH0C": FirmwareLimitKeyObservation(present: false, size: 0, type: "", bytes: []),
                "CHTE": FirmwareLimitKeyObservation(present: false, size: 0, type: "", bytes: []),
                "CH0I": FirmwareLimitKeyObservation(present: false, size: 0, type: "", bytes: []),
                "CH0J": FirmwareLimitKeyObservation(present: true, size: 1, type: "ui8 ", bytes: [0x00]),
                "CHIE": FirmwareLimitKeyObservation(present: true, size: 1, type: "hex_", bytes: [0x00])
            ]
        )
    }

    private static func testTargetClassifiesAsCandidate(_ report: FirmwareLimitCompatibilityReport) {
        expect(report.tier == .candidate, "target M1 Pro is a capability candidate, not verified")
        expect(report.state == FirmwareLimitState(activationByte: 0, upper: 80, lower: 78),
               "probe data decodes to inactive 80/78 firmware state")
        expect(report.canReadFirmwareLimit && report.canGeneratePlan, "read-only state and plan are available")
        expect(report.canRunManualValidation, "explicit hardware validation can be performed when AC is available")
        expect(!report.canApplyAutomatically, "automatic production writes remain disabled")
        expect(!report.supportsForceDischarge, "readable CH0J/CHIE do not prove adapter-cut semantics")
    }

    private static func testLimitedPolicy(_ report: FirmwareLimitCompatibilityReport) throws {
        let decision = FirmwareLimitPolicyAdapter.decide(
            chargeMode: .limited,
            fullBehavior: .once,
            highChargePolicy: .adapter,
            upperLimit: 80,
            compatibility: report
        )
        let expected = try FirmwareLimitRequest(upper: 80, lower: 78)
        expect(decision.action == .configure(expected), "limited mode maps to an 80/78 firmware plan")
        expect(!decision.canExecuteAutomatically && decision.isPreviewOnly,
               "candidate firmware produces a preview-only decision")
    }

    private static func testFullPolicies(_ report: FirmwareLimitCompatibilityReport) throws {
        let once = FirmwareLimitPolicyAdapter.decide(
            chargeMode: .full,
            fullBehavior: .once,
            highChargePolicy: .adapter,
            upperLimit: 80,
            compatibility: report
        )
        let expected = try FirmwareLimitRequest(upper: 80, lower: 78)
        expect(once.action == .oneTimeFullCharge(restore: expected, target: 100),
               "one-time full mode records the original limit for restoration")
        expect(!once.canExecuteAutomatically, "one-time full mode remains preview-only before hardware validation")

        let always = FirmwareLimitPolicyAdapter.decide(
            chargeMode: .full,
            fullBehavior: .always,
            highChargePolicy: .adapter,
            upperLimit: 80,
            compatibility: report
        )
        expect(always.action == .deactivate, "always-full mode maps to deactivation")
        expect(!always.canExecuteAutomatically, "always-full deactivation remains blocked before hardware validation")
    }

    private static func testDischargeRemainsUnsupported(_ report: FirmwareLimitCompatibilityReport) {
        let decision = FirmwareLimitPolicyAdapter.decide(
            chargeMode: .limited,
            fullBehavior: .once,
            highChargePolicy: .discharge,
            upperLimit: 80,
            compatibility: report
        )
        if case .unsupported = decision.action {
            expect(true, "force-discharge is blocked until CH0J/CHIE semantics are verified")
        } else {
            expect(false, "force-discharge must not be inferred from key readability")
        }
    }

    private static func testUnsafeUpperIsBlocked(_ report: FirmwareLimitCompatibilityReport) {
        let decision = FirmwareLimitPolicyAdapter.decide(
            chargeMode: .limited,
            fullBehavior: .once,
            highChargePolicy: .adapter,
            upperLimit: 99,
            compatibility: report
        )
        if case .unsupported = decision.action {
            expect(true, "upper limits outside the existing UI range are rejected")
        } else {
            expect(false, "invalid upper limit must not produce a firmware action")
        }
    }

    private static func testUnverifiedIdentityIsUnsupported() {
        let original = targetEvidence()
        let evidence = FirmwareLimitHardwareEvidence(
            identity: FirmwareLimitDeviceIdentity(
                modelIdentifier: "MacBookPro18,1",
                systemFirmware: "mBoot-20457.1.29",
                macOSMajorVersion: 15,
                architecture: "arm64"
            ),
            keys: original.keys
        )
        let report = FirmwareLimitCompatibilityClassifier.classify(evidence)
        expect(report.tier == .unsupported && !report.canReadFirmwareLimit,
               "a different firmware build is not treated as compatible")
    }

    private static func testMissingFirmwareKeyIsUnsupported() {
        let original = targetEvidence()
        var keys = original.keys
        keys.removeValue(forKey: "bfE0")
        let evidence = FirmwareLimitHardwareEvidence(identity: original.identity, keys: keys)
        let report = FirmwareLimitCompatibilityClassifier.classify(evidence)
        expect(report.tier == .unsupported, "missing required firmware register blocks the backend")
    }
}
