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

        let firmware: String
        let root = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/")
        if root != 0 {
            defer { IOObjectRelease(root) }
            if let value = IORegistryEntryCreateCFProperty(
                root, "system-firmware-version" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() {
                if let text = value as? String {
                    firmware = text.trimmingCharacters(in: .whitespacesAndNewlines)
                } else if let data = value as? Data {
                    firmware = String(decoding: data, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
                } else {
                    firmware = ""
                }
            } else {
                firmware = ""
            }
        } else {
            firmware = ""
        }

        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "unknown"
        #endif

        return FirmwareLimitDeviceIdentity(
            modelIdentifier: model,
            systemFirmware: firmware,
            macOSMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
            architecture: architecture
        )
    }

    static func batteryObservation() -> FirmwareLimitBatteryObservation {
        let result = run("/usr/bin/pmset", ["-g", "batt"])
        guard result.status == 0 else {
            return FirmwareLimitBatteryObservation(percent: nil, fullyCharged: nil, externalConnected: nil)
        }
        let output = result.output
        let external = output.localizedCaseInsensitiveContains("AC Power")
        let percent: Int?
        if let range = output.range(of: #"\b(\d{1,3})%"#, options: .regularExpression) {
            let token = String(output[range]).filter(\.isNumber)
            percent = Int(token).flatMap { (0...100).contains($0) ? $0 : nil }
        } else {
            percent = nil
        }
        let full = percent == 100 || output.localizedCaseInsensitiveContains("charged")
        return FirmwareLimitBatteryObservation(percent: percent, fullyCharged: full, externalConnected: external)
    }

    static func isOnACPower() -> Bool {
        batteryObservation().externalConnected == true
    }

    static var isAdministrator: Bool { geteuid() == 0 }

    private static func run(_ path: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        } catch {
            return (-1, error.localizedDescription)
        }
    }
}
