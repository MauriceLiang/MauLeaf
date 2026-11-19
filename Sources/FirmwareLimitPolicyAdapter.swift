import Foundation

enum FirmwareLimitCompatibilityTier: String, Codable {
    case verified
    case candidate
    case unsupported
}

struct FirmwareLimitKeyObservation: Equatable {
    let present: Bool
    let size: Int
    let type: String
    let bytes: [UInt8]
}

struct FirmwareLimitHardwareEvidence: Equatable {
    let identity: FirmwareLimitDeviceIdentity
    let keys: [String: FirmwareLimitKeyObservation]
}

struct FirmwareLimitCompatibilityReport: Equatable {
    let tier: FirmwareLimitCompatibilityTier
    let state: FirmwareLimitState?
    let canReadFirmwareLimit: Bool
    let canGeneratePlan: Bool
    let canRunManualValidation: Bool
    let canApplyAutomatically: Bool
    let supportsForceDischarge: Bool
    let notes: [String]

    static func unsupported(_ reason: String) -> FirmwareLimitCompatibilityReport {
        FirmwareLimitCompatibilityReport(
            tier: .unsupported,
            state: nil,
            canReadFirmwareLimit: false,
            canGeneratePlan: false,
            canRunManualValidation: false,
            canApplyAutomatically: false,
            supportsForceDischarge: false,
            notes: [reason]
        )
    }
}

/// A readable key is capability evidence only. No device is promoted to
/// verified by this classifier; that requires a separate recorded
/// write/read-back and real charging-enforcement test.
enum FirmwareLimitCompatibilityClassifier {
    static let targetModel = "MacBookPro18,1"
    static let targetFirmware = "mBoot-20457.41.3"
    static let targetOSMajor = 15
    static let targetArchitecture = "arm64"

    static func classify(_ evidence: FirmwareLimitHardwareEvidence) -> FirmwareLimitCompatibilityReport {
        let identity = evidence.identity
        guard identity.modelIdentifier == targetModel,
              identity.systemFirmware == targetFirmware,
              identity.macOSMajorVersion == targetOSMajor,
              identity.architecture == targetArchitecture else {
            return .unsupported("This model, firmware, macOS version, or architecture has no validated MauLeaf firmware profile.")
        }

        for key in FirmwareLimitKey.allCases {
            guard let observation = evidence.keys[key.rawValue],
                  observation.present else {
                return .unsupported("Required firmware key \(key.rawValue) is absent or unreadable.")
            }
            let metadata = FirmwareLimitKeyMetadata(size: observation.size, type: observation.type)
            guard FirmwareLimitPolicy.accepts(metadata, for: key),
                  observation.bytes.count == key.expectedSize else {
                return .unsupported("Required firmware key \(key.rawValue) has an unexpected metadata shape or payload length.")
            }
        }

        guard let activation = evidence.keys["bfF0"]?.bytes.first,
              activation == 0x00 || activation == 0x02,
              let upperBytes = evidence.keys["bfD0"]?.bytes,
              let lowerBytes = evidence.keys["bfE0"]?.bytes,
              let upper = FirmwareLimitPolicy.decodeUInt32LittleEndian(upperBytes),
              let lower = FirmwareLimitPolicy.decodeUInt32LittleEndian(lowerBytes),
              (5...100).contains(upper),
              (5...100).contains(lower),
              lower < upper else {
            return .unsupported("The observed firmware-limit register values are invalid.")
        }

        let adapterCandidates = ["CH0J", "CHIE"].filter {
            evidence.keys[$0]?.present == true
        }
        var notes = [
            "bfF0/bfD0/bfE0 are readable with the expected payload shapes.",
            "Firmware write access and actual charge-limit enforcement have not been verified on this exact machine.",
            "Automatic production writes remain disabled until the target hardware passes the dedicated AC-power test."
        ]
        if !adapterCandidates.isEmpty {
            notes.append(
                "\(adapterCandidates.joined(separator: " and ")) are readable, but adapter-cut semantics are unverified; force-discharge remains unsupported."
            )
        }

        return FirmwareLimitCompatibilityReport(
            tier: .candidate,
            state: FirmwareLimitState(activationByte: activation, upper: upper, lower: lower),
            canReadFirmwareLimit: true,
            canGeneratePlan: true,
            canRunManualValidation: true,
            canApplyAutomatically: false,
            supportsForceDischarge: false,
            notes: notes
        )
    }
}

enum FirmwareLimitPolicyAction: Equatable {
    case configure(FirmwareLimitRequest)
    case configureAndEnableAdapterCut(FirmwareLimitRequest)
    case deactivate
    case oneTimeFullCharge(restore: FirmwareLimitRequest, target: Int)
    case unsupported(String)
}

struct FirmwareLimitPolicyDecision: Equatable {
    let action: FirmwareLimitPolicyAction
    let canExecuteAutomatically: Bool
    let isPreviewOnly: Bool
}

/// Maps MauLeaf's existing user-facing settings to the native firmware
/// backend. This is a pure adapter: it does not write SMC or change app state.
enum FirmwareLimitPolicyAdapter {
    static func decide(
        chargeMode: ChargeMode,
        fullBehavior: FullBehavior,
        highChargePolicy: HighChargePolicy,
        upperLimit: Int,
        compatibility: FirmwareLimitCompatibilityReport
    ) -> FirmwareLimitPolicyDecision {
        guard compatibility.canReadFirmwareLimit else {
            return blocked("The firmware-limit keys are not readable on this device.")
        }

        let request: FirmwareLimitRequest
        do {
            request = try FirmwareLimitRequest.standard(upper: upperLimit)
        } catch {
            return blocked("The selected upper limit is outside MauLeaf's supported 50–95% range.")
        }

        let action: FirmwareLimitPolicyAction
        switch chargeMode {
        case .limited:
            if highChargePolicy == .discharge {
                guard compatibility.supportsForceDischarge else {
                    return blocked("Force-discharge is unavailable: CH0J/CHIE are readable candidates, but their adapter-cut values have not been verified.")
                }
                action = .configureAndEnableAdapterCut(request)
            } else {
                action = .configure(request)
            }
        case .full:
            switch fullBehavior {
            case .once:
                action = .oneTimeFullCharge(restore: request, target: 100)
            case .always:
                action = .deactivate
            }
        }

        let canExecute = compatibility.canApplyAutomatically
        return FirmwareLimitPolicyDecision(
            action: action,
            canExecuteAutomatically: canExecute,
            isPreviewOnly: !canExecute
        )
    }

    private static func blocked(_ reason: String) -> FirmwareLimitPolicyDecision {
        FirmwareLimitPolicyDecision(
            action: .unsupported(reason),
            canExecuteAutomatically: false,
            isPreviewOnly: true
        )
    }
}
