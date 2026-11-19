import Foundation
import Darwin
import IOKit

enum FirmwareLimitRuntime {
    static func identity() -> FirmwareLimitDeviceIdentity {
        var modelSize = 0
        _ = sysctlbyname("hw.model", nil, &modelSize, nil, 0)
        var modelBuffer = [CChar](repeating: 0, count: max(modelSize, 1))
        _ = sysctlbyname("hw.model", &modelBuffer, &modelSize, nil, 0)
        let model = String(cString: modelBuffer)

        let firmware = SystemFirmwareReader.read() ?? ""
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "unsupported"
        #endif

        return FirmwareLimitDeviceIdentity(
            modelIdentifier: model,
            systemFirmware: firmware,
            macOSMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
            architecture: architecture
        )
    }

    static func batteryObservation() -> FirmwareLimitBatteryObservation {
        let snapshot = MauLeafBatteryStatusReader.read()
        return FirmwareLimitBatteryObservation(
            percent: snapshot.percent,
            fullyCharged: snapshot.isFullyCharged,
            externalConnected: snapshot.isACConnected
        )
    }

    static func isOnACPower() -> Bool {
        batteryObservation().externalConnected == true
    }

    static var isAdministrator: Bool { geteuid() == 0 }

}
