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

    /// Independent confirmation of the power source, matching the hardware
    /// probe that successfully performed full unplugged restoration.
    /// Fail closed if pmset cannot be executed or its output is ambiguous.
    static func pmsetReportsBatteryPower() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "batt"]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        do {
            try process.run()
            let bytes = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let report = String(data: bytes, encoding: .utf8) else {
                return false
            }
            return report.contains("Now drawing from 'Battery Power'")
                && !report.contains("Now drawing from 'AC Power'")
        } catch {
            return false
        }
    }

    static var isAdministrator: Bool { geteuid() == 0 }

}
