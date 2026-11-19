import Foundation
import IOKit
import Darwin

// A narrowly scoped, opt-in write-access check for the firmware charge-limit
// keys found on the user's MacBookPro18,1. It writes each key's EXISTING value
// only while bfF0 is inactive (0x00), then reads every value back.
// It never enables a charging limit and never touches adapter-input keys.

private typealias SMCBytes = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

private struct SMCParam {
    struct Version {
        var major: UInt8 = 0
        var minor: UInt8 = 0
        var build: UInt8 = 0
        var reserved: UInt8 = 0
        var release: UInt16 = 0
    }
    struct PLimit {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpu: UInt32 = 0
        var gpu: UInt32 = 0
        var mem: UInt32 = 0
    }
    struct KeyInfo {
        var size: UInt32 = 0
        var type: UInt32 = 0
        var attributes: UInt8 = 0
    }
    var key: UInt32 = 0
    var version = Version()
    var pLimit = PLimit()
    var info = KeyInfo()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var selector: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes = (
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    )
}

private enum SMCError: Error, CustomStringConvertible {
    case serviceMissing
    case open(kern_return_t)
    case keyMissing(String)
    case denied
    case call(kern_return_t, UInt8)

    var description: String {
        switch self {
        case .serviceMissing: return "AppleSMC service not found"
        case .open(let code): return "IOServiceOpen failed: \(code)"
        case .keyMissing(let key): return "\(key) is not present"
        case .denied: return "SMC write was denied; run the command with sudo"
        case .call(let code, let result): return "SMC call failed: IOReturn=\(code), result=\(result)"
        }
    }
}

private func fourCC(_ text: String) -> UInt32 {
    let bytes = Array(text.utf8)
    guard bytes.count == 4 else { return 0 }
    return (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16)
        | (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
}

private func fourCCString(_ value: UInt32) -> String {
    let bytes: [UInt8] = [
        UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
        UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)
    ]
    return String(bytes: bytes, encoding: .ascii)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? String(format: "0x%08X", value)
}

private final class SMCClient {
    private var connection: io_connect_t = 0
    private var opened = false

    deinit { close() }

    func open() throws {
        guard !opened else { return }
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSMC")
        )
        guard service != 0 else { throw SMCError.serviceMissing }
        defer { IOObjectRelease(service) }

        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        if result == kIOReturnNotPrivileged { throw SMCError.denied }
        guard result == kIOReturnSuccess else { throw SMCError.open(result) }
        opened = true
    }

    func close() {
        guard opened else { return }
        _ = IOServiceClose(connection)
        connection = 0
        opened = false
    }

    func keyInfo(_ name: String) throws -> (size: UInt32, type: UInt32) {
        try open()
        var input = SMCParam()
        input.key = fourCC(name)
        input.selector = 9 // kSMCGetKeyInfo
        let output = try call(&input)
        return (output.info.size, output.info.type)
    }

    func readBytes(_ name: String, size: UInt32 = 32) throws -> [UInt8] {
        try open()
        var input = SMCParam()
        input.key = fourCC(name)
        input.info.size = min(max(size, 1), 32)
        input.selector = 5 // kSMCReadKey
        let output = try call(&input)
        return withUnsafeBytes(of: output.bytes) { Array($0.prefix(32)) }
    }

    func readUInt8(_ name: String) throws -> UInt8 {
        let bytes = try readBytes(name, size: 1)
        guard let first = bytes.first else { throw SMCError.keyMissing(name) }
        return first
    }

    func readUInt32LE(_ name: String) throws -> UInt32 {
        let bytes = try readBytes(name, size: 4)
        guard bytes.count >= 4 else { throw SMCError.keyMissing(name) }
        return UInt32(bytes[0])
            | (UInt32(bytes[1]) << 8)
            | (UInt32(bytes[2]) << 16)
            | (UInt32(bytes[3]) << 24)
    }

    func writeUInt8(_ name: String, value: UInt8) throws {
        try open()
        var input = SMCParam()
        input.key = fourCC(name)
        input.info.size = 1
        input.selector = 6 // kSMCWriteKey
        input.bytes.0 = value
        _ = try call(&input)
    }

    func writeUInt32LE(_ name: String, value: UInt32) throws {
        try open()
        var input = SMCParam()
        input.key = fourCC(name)
        input.info.size = 4
        input.selector = 6 // kSMCWriteKey
        input.bytes.0 = UInt8(value & 0xFF)
        input.bytes.1 = UInt8((value >> 8) & 0xFF)
        input.bytes.2 = UInt8((value >> 16) & 0xFF)
        input.bytes.3 = UInt8((value >> 24) & 0xFF)
        _ = try call(&input)
    }

    private func call(_ input: inout SMCParam) throws -> SMCParam {
        let size = MemoryLayout<SMCParam>.stride
        guard size == 80 else { throw SMCError.call(kIOReturnError, 255) }

        var output = SMCParam()
        var outputSize = size
        let result = IOConnectCallStructMethod(
            connection, 2, &input, size, &output, &outputSize
        )
        if result == kIOReturnNotPrivileged { throw SMCError.denied }
        if result == kIOReturnSuccess && output.result == 132 {
            throw SMCError.keyMissing("requested SMC key")
        }
        guard result == kIOReturnSuccess, output.result == 0 else {
            throw SMCError.call(result, output.result)
        }
        return output
    }
}

private struct DeviceIdentity {
    let model: String
    let firmware: String
    let osMajor: Int
    let osVersion: String
    let osBuild: String

    static func current() throws -> DeviceIdentity {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        guard let model = readSysctl("hw.model"),
              let firmwareOutput = runCommand("/usr/sbin/ioreg", ["-p", "IODeviceTree", "-l", "-w0"]),
              let firmware = capture(#"system-firmware-version"\s*=\s*<"([^"]+)""#, in: firmwareOutput),
              let build = readSysctl("kern.osversion") else {
            throw ValidationError.identityUnavailable
        }
        return DeviceIdentity(
            model: model,
            firmware: firmware,
            osMajor: os.majorVersion,
            osVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            osBuild: build
        )
    }

    func requireSupportedTarget() throws {
        #if !arch(arm64)
        throw ValidationError.unsupportedTarget("This diagnostic is built for Apple Silicon arm64 only.")
        #endif
        guard model == "MacBookPro18,1" else {
            throw ValidationError.unsupportedTarget("Expected MacBookPro18,1; found \(model).")
        }
        guard firmware == "mBoot-20457.41.3" else {
            throw ValidationError.unsupportedTarget("Expected mBoot-20457.41.3; found \(firmware). Refusing an unverified firmware build.")
        }
        guard osMajor == 15 else {
            throw ValidationError.unsupportedTarget("Expected macOS 15; found macOS \(osVersion).")
        }
    }
}

private struct PowerState {
    let onAC: Bool
    let percent: Int?

    static func current() -> PowerState? {
        guard let output = runCommand("/usr/bin/pmset", ["-g", "batt"]) else { return nil }
        let onAC = output.contains("Now drawing from 'AC Power'")
        let percentText = capture(#"(\d{1,3})%;"#, in: output)
        return PowerState(onAC: onAC, percent: percentText.flatMap(Int.init))
    }
}

private struct FirmwareState: Equatable {
    let activation: UInt8
    let upper: UInt32
    let lower: UInt32
}

private enum ValidationError: Error, CustomStringConvertible {
    case identityUnavailable
    case unsupportedTarget(String)
    case notRoot
    case powerStateUnavailable
    case notOnAC
    case conflictingController(String)
    case activeLimit
    case invalidCurrentValues
    case unexpectedKeyShape(String)
    case confirmationCancelled
    case verificationFailed(String)

    var description: String {
        switch self {
        case .identityUnavailable: return "Could not read model, system firmware, or macOS build."
        case .unsupportedTarget(let reason): return reason
        case .notRoot: return "Write check requires administrator privileges. Run with sudo."
        case .powerStateUnavailable: return "Could not read current battery and power state."
        case .notOnAC: return "Connect the MacBook to its power adapter before running the write check."
        case .conflictingController(let name): return "\(name) is running. Quit MauLeaf and stop other battery-control tools first."
        case .activeLimit: return "bfF0 is already active. This no-op write check only runs while the firmware limit is disabled."
        case .invalidCurrentValues: return "Current bfD0/bfE0 values are outside the expected percentage range."
        case .unexpectedKeyShape(let key): return "Unexpected metadata for \(key); refusing to write."
        case .confirmationCancelled: return "Confirmation did not match; no SMC writes were attempted."
        case .verificationFailed(let key): return "Read-back verification failed for \(key)."
        }
    }
}

private func readSysctl(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else { return nil }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
    return String(cString: buffer)
}

private func runCommand(_ path: String, _ arguments: [String]) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    } catch {
        return nil
    }
}

private func capture(_ pattern: String, in text: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          let range = Range(match.range(at: 1), in: text) else { return nil }
    return String(text[range])
}

private func processIsRunning(_ name: String) -> Bool {
    guard let output = runCommand("/usr/bin/pgrep", ["-x", name]) else { return false }
    return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

private enum FirmwareLimitWriteCheck {
    static let keys = [
        ("bfF0", UInt32(1), "ui8 "),
        ("bfD0", UInt32(4), "ui32"),
        ("bfE0", UInt32(4), "ui32")
    ]

    static func readState(using smc: SMCClient) throws -> FirmwareState {
        for (key, expectedSize, expectedType) in keys {
            let info = try smc.keyInfo(key)
            let actualType = info.type == 0
                ? ""
                : fourCCString(info.type).trimmingCharacters(in: .whitespacesAndNewlines)
            let expectedTypeName = expectedType.trimmingCharacters(in: .whitespacesAndNewlines)
            let metadataMatches = info.size == 0
                ? (actualType.isEmpty || actualType == expectedTypeName)
                : (info.size == expectedSize && actualType == expectedTypeName)
            guard metadataMatches else {
                throw ValidationError.unexpectedKeyShape(key)
            }
        }

        let state = FirmwareState(
            activation: try smc.readUInt8("bfF0"),
            upper: try smc.readUInt32LE("bfD0"),
            lower: try smc.readUInt32LE("bfE0")
        )
        guard state.activation == 0x00 || state.activation == 0x02 else {
            throw ValidationError.invalidCurrentValues
        }
        guard (5...100).contains(Int(state.upper)),
              (5...100).contains(Int(state.lower)),
              state.lower < state.upper else {
            throw ValidationError.invalidCurrentValues
        }
        return state
    }

    static func status() throws {
        let identity = try DeviceIdentity.current()
        printReport(identity: identity)
        let smc = SMCClient()
        try smc.open()
        let state = try readState(using: smc)
        printState(state)
        print("Mode        : READ ONLY")
        print("No SMC writes were performed.")
    }

    static func writeCheck() throws {
        guard geteuid() == 0 else { throw ValidationError.notRoot }

        let identity = try DeviceIdentity.current()
        try identity.requireSupportedTarget()

        if processIsRunning("MauLeaf") {
            throw ValidationError.conflictingController("MauLeaf")
        }
        if processIsRunning("batt") {
            throw ValidationError.conflictingController("batt")
        }

        guard let power = PowerState.current() else {
            throw ValidationError.powerStateUnavailable
        }
        guard power.onAC else { throw ValidationError.notOnAC }

        let smc = SMCClient()
        try smc.open()
        let original = try readState(using: smc)
        guard original.activation == 0x00 else { throw ValidationError.activeLimit }

        printReport(identity: identity)
        printState(original)
        print("Mode        : NO-OP WRITE CHECK")
        print("Power       : AC connected\(power.percent.map { ", battery \($0)%" } ?? "")")
        print("")
        print("This test writes ONLY the values already stored in these three keys:")
        print("  bfF0 = 0x00 (limit remains disabled)")
        print("  bfD0 = \(original.upper) (unchanged)")
        print("  bfE0 = \(original.lower) (unchanged)")
        print("It then reads each key back. It does NOT enable a charge limit.")
        print("No daemon, login item, or persistent setting will be installed.")
        print("")

        let phrase = "WRITE-CHECK MacBookPro18,1"
        print("Type exactly '\(phrase)' to continue:")
        guard readLine() == phrase else { throw ValidationError.confirmationCancelled }

        do {
            try writeAndVerifyUInt8("bfF0", value: original.activation, using: smc)
            try writeAndVerifyUInt32LE("bfD0", value: original.upper, using: smc)
            try writeAndVerifyUInt32LE("bfE0", value: original.lower, using: smc)

            let final = try readState(using: smc)
            guard final == original else {
                throw ValidationError.verificationFailed("final state")
            }

            print("")
            print("WRITE CHECK: SUCCESS")
            print("bfF0: write 0x00 -> read 0x00")
            print("bfD0: write \(original.upper) -> read \(final.upper)")
            print("bfE0: write \(original.lower) -> read \(final.lower)")
            print("Firmware activation remains OFF (0x00).")
            print("Charging behavior was not intentionally changed.")
            print("This confirms write/read-back access only; real limit enforcement is NOT tested.")
        } catch {
            print("")
            print("Write check failed: \(error)")
            print("Attempting to restore the exact values read before the test...")
            do {
                try restore(original, using: smc)
                print("Recovery read-back: SUCCESS")
            } catch {
                print("RECOVERY COULD NOT BE VERIFIED: \(error)")
                print("Keep the Mac connected to power and do not run another battery-control utility.")
            }
            throw error
        }
        smc.close()
    }

    private static func writeAndVerifyUInt8(_ key: String, value: UInt8, using smc: SMCClient) throws {
        try smc.writeUInt8(key, value: value)
        for _ in 0..<3 {
            Thread.sleep(forTimeInterval: 0.15)
            if (try? smc.readUInt8(key)) == value { return }
        }
        throw ValidationError.verificationFailed(key)
    }

    private static func writeAndVerifyUInt32LE(_ key: String, value: UInt32, using smc: SMCClient) throws {
        try smc.writeUInt32LE(key, value: value)
        for _ in 0..<3 {
            Thread.sleep(forTimeInterval: 0.15)
            if (try? smc.readUInt32LE(key)) == value { return }
        }
        throw ValidationError.verificationFailed(key)
    }

    private static func restore(_ state: FirmwareState, using smc: SMCClient) throws {
        try writeAndVerifyUInt8("bfF0", value: 0x00, using: smc)
        try writeAndVerifyUInt32LE("bfD0", value: state.upper, using: smc)
        try writeAndVerifyUInt32LE("bfE0", value: state.lower, using: smc)
        try writeAndVerifyUInt8("bfF0", value: state.activation, using: smc)
    }

    private static func printReport(identity: DeviceIdentity) {
        print("MauLeaf Firmware Limit Write Check")
        print("==================================")
        print("Model       : \(identity.model)")
        print("Firmware    : \(identity.firmware)")
        print("macOS       : \(identity.osVersion) (build \(identity.osBuild))")
        print("Architecture: arm64")
        print("AppleSMC    : available")
    }

    private static func printState(_ state: FirmwareState) {
        let activation = String(format: "0x%02X", state.activation)
        print("bfF0        : \(activation) (\(state.activation == 0x02 ? "active" : "inactive"))")
        print("bfD0        : \(state.upper)% upper")
        print("bfE0        : \(state.lower)% lower")
    }
}

@main
private enum Main {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let command = arguments.first ?? "status"

        do {
            switch command {
            case "status":
                try FirmwareLimitWriteCheck.status()
            case "write-check":
                try FirmwareLimitWriteCheck.writeCheck()
            case "--help", "help":
                print("Usage:")
                print("  MauLeafFirmwareLimitWriteCheck status")
                print("  sudo MauLeafFirmwareLimitWriteCheck write-check")
                print("")
                print("status is read-only. write-check rewrites only the currently stored values")
                print("while bfF0 is inactive; it never enables firmware charge limiting.")
            default:
                fputs("Unknown command: \(command)\n", stderr)
                exit(2)
            }
        } catch {
            fputs("ERROR: \(error)\n", stderr)
            exit(1)
        }
    }
}
