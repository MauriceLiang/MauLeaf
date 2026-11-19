import Foundation
import IOKit
import Darwin

// Read-only AppleSMC capability probe for MauLeaf. No SMC write operation exists.
private typealias SMCBytes = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                              UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                              UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                              UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)

private struct SMCParam {
    struct Version { var major: UInt8 = 0; var minor: UInt8 = 0; var build: UInt8 = 0; var reserved: UInt8 = 0; var release: UInt16 = 0 }
    struct PLimit { var version: UInt16 = 0; var length: UInt16 = 0; var cpu: UInt32 = 0; var gpu: UInt32 = 0; var mem: UInt32 = 0 }
    struct KeyInfo { var size: UInt32 = 0; var type: UInt32 = 0; var attributes: UInt8 = 0 }
    var key: UInt32 = 0
    var version = Version()
    var pLimit = PLimit()
    var info = KeyInfo()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var selector: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                           0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

private enum ProbeError: Error, CustomStringConvertible {
    case serviceMissing, open(kern_return_t), keyMissing, denied, call(kern_return_t, UInt8)
    var description: String {
        switch self {
        case .serviceMissing: return "AppleSMC service not found"
        case .open(let code): return "IOServiceOpen failed: \(code)"
        case .keyMissing: return "key not found"
        case .denied: return "access denied (not privileged)"
        case .call(let code, let result): return "SMC read failed: IOReturn=\(code), result=\(result)"
        }
    }
}

private final class SMCReader {
    private var connection: io_connect_t = 0
    private var opened = false
    deinit { close() }

    func open() throws {
        guard !opened else { return }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw ProbeError.serviceMissing }
        defer { IOObjectRelease(service) }
        let status = IOServiceOpen(service, mach_task_self_, 0, &connection)
        if status == kIOReturnNotPrivileged { throw ProbeError.denied }
        guard status == kIOReturnSuccess else { throw ProbeError.open(status) }
        opened = true
    }

    func close() {
        guard opened else { return }
        _ = IOServiceClose(connection)
        connection = 0
        opened = false
    }

    func keyInfo(_ key: UInt32) throws -> (size: UInt32, type: UInt32) {
        try open()
        var input = SMCParam(); input.key = key; input.selector = 9 // kSMCGetKeyInfo
        let output = try call(&input)
        return (output.info.size, output.info.type)
    }

    func read(_ key: UInt32, size: UInt32) throws -> [UInt8] {
        try open()
        var input = SMCParam(); input.key = key
        input.info.size = min(max(size, 1), 32); input.selector = 5 // kSMCReadKey
        let output = try call(&input)
        return withUnsafeBytes(of: output.bytes) { Array($0.prefix(32)) }
    }

    private func call(_ input: inout SMCParam) throws -> SMCParam {
        let size = MemoryLayout<SMCParam>.stride
        guard size == 80 else { throw ProbeError.call(kIOReturnError, 255) }
        var output = SMCParam(); var outputSize = size
        let status = IOConnectCallStructMethod(connection, 2, &input, size, &output, &outputSize) // kSMCHandleYPCEvent
        if status == kIOReturnNotPrivileged { throw ProbeError.denied }
        if status == kIOReturnSuccess && output.result == 132 { throw ProbeError.keyMissing }
        guard status == kIOReturnSuccess, output.result == 0 else { throw ProbeError.call(status, output.result) }
        return output
    }
}

private struct KeyResult {
    let name: String
    let expected: UInt32
    let metadataSize: UInt32?
    let dataType: UInt32?
    let bytes: [UInt8]?
    let error: String?
    var usable: Bool {
        guard bytes != nil else { return false }
        guard let metadataSize, metadataSize > 0 else { return true }
        return metadataSize == expected
    }
}

private func code(_ text: String) -> UInt32 {
    let b = Array(text.utf8)
    guard b.count == 4 else { return 0 }
    return (UInt32(b[0]) << 24) | (UInt32(b[1]) << 16) | (UInt32(b[2]) << 8) | UInt32(b[3])
}

private func fourCC(_ value: UInt32) -> String {
    let b: [UInt8] = [UInt8((value >> 24) & 255), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)]
    return String(bytes: b, encoding: .ascii)?.trimmingCharacters(in: .whitespaces).nonEmpty ?? String(format: "0x%08X", value)
}

private extension String { var nonEmpty: String? { isEmpty ? nil : self } }

private func probe(_ reader: SMCReader, _ name: String, _ expected: UInt32) -> KeyResult {
    let key = code(name)
    var meta: UInt32?; var type: UInt32?
    do {
        let info = try reader.keyInfo(key); meta = info.size; type = info.type
    } catch ProbeError.keyMissing {
        return KeyResult(name: name, expected: expected, metadataSize: nil, dataType: nil, bytes: nil, error: "not present")
    } catch { /* Try a direct read when firmware metadata is unavailable. */ }
    let readSize = (meta ?? 0) > 0 ? meta! : 32
    do {
        let bytes = try reader.read(key, size: readSize)
        return KeyResult(name: name, expected: expected, metadataSize: meta, dataType: type, bytes: bytes, error: nil)
    } catch ProbeError.keyMissing {
        return KeyResult(name: name, expected: expected, metadataSize: meta, dataType: type, bytes: nil, error: "not present")
    } catch {
        return KeyResult(name: name, expected: expected, metadataSize: meta, dataType: type, bytes: nil, error: String(describing: error))
    }
}

private func sysctl(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else { return nil }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
    return String(cString: buffer)
}

private func hex(_ bytes: [UInt8]) -> String { bytes.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " ") }
private func le32(_ b: [UInt8]) -> UInt32? {
    guard b.count >= 4 else { return nil }
    return UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
}

private func run() {
    let os = ProcessInfo.processInfo.operatingSystemVersion
    print("MauLeaf Hardware Probe — READ ONLY")
    print("===================================")
    print("Model       : \(sysctl("hw.model") ?? "Unknown")")
    print("Chip        : \(sysctl("machdep.cpu.brand_string") ?? "Not reported")")
    print("Firmware    : \\(SystemFirmwareReader.read() ?? "Not reported")")
    #if arch(arm64)
    print("Architecture: arm64")
    #elseif arch(x86_64)
    print("Architecture: x86_64")
    #else
    print("Architecture: unknown")
    #endif
    print("macOS       : \(os.majorVersion).\(os.minorVersion).\(os.patchVersion) (build \(sysctl("kern.osversion") ?? "unknown"))")

    let reader = SMCReader()
    do { try reader.open(); print("AppleSMC    : available") }
    catch {
        print("AppleSMC    : unavailable — \(error)")
        print("\nNo control backend can be selected from this report.")
        print("If access was denied, retry this same read-only binary with sudo.")
        return
    }

    let definitions: [(String, UInt32)] = [
        ("CH0B", 1), ("CH0C", 1), ("CHTE", 4),
        ("bfF0", 1), ("bfD0", 4), ("bfE0", 4),
        ("CH0I", 1), ("CH0J", 1), ("CHIE", 1)
    ]
    let results = definitions.map { probe(reader, $0.0, $0.1) }
    print("\nSMC key results (metadata/read only)")
    for item in results {
        if let bytes = item.bytes {
            let size = item.metadataSize.map { $0 == 0 ? "0 (unpopulated)" : String($0) } ?? "unknown"
            let type = item.dataType.map(fourCC) ?? "unknown"
            let shape = item.usable ? "READABLE / expected shape" : "READABLE / size mismatch"
            print("\(item.name): \(shape) | size=\(size) | type=\(type) | data=\(hex(bytes))")
        } else {
            print("\(item.name): unavailable | \(item.error ?? "unknown")")
        }
    }

    let byName = Dictionary(uniqueKeysWithValues: results.map { ($0.name, $0) })
    func ok(_ name: String) -> Bool { byName[name]?.usable == true }
    let firmware = ok("bfF0") && ok("bfD0") && ok("bfE0")
    let legacy = ok("CH0B") && ok("CH0C")
    let alternate = ok("CHTE")

    print("\nFirmware values (raw read only)")
    if let b = byName["bfF0"]?.bytes?.first { print(String(format: "bfF0 activation: 0x%02X", b)) }
    if let b = byName["bfD0"]?.bytes, let n = le32(b) { print("bfD0 upper     : \(n)") }
    if let b = byName["bfE0"]?.bytes, let n = le32(b) { print("bfE0 lower     : \(n)") }

    print("\nPreliminary recommendation")
    if firmware { print("Candidate: firmware-managed limit (bfF0 / bfD0 / bfE0).") }
    else if legacy { print("Candidate: legacy SMC charge inhibit (CH0B + CH0C).") }
    else if alternate { print("Candidate: alternate SMC charge inhibit (CHTE).") }
    else { print("No known direct charge-limit key family was confirmed.") }
    print("This is key-presence evidence only; write permission and real charge enforcement are NOT tested.")
    print("Adapter-input keys are diagnostic only and are never substituted for a charge-limit backend.")
    print("\nSafety: no SMC writes, charging changes, or power-setting changes were performed.")
    reader.close()
}


@main
private enum MauLeafHardwareProbeMain {
    static func main() {
        run()
    }
}
