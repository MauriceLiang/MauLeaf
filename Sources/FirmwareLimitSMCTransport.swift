import Foundation
import IOKit

private typealias FirmwareSMCBytes = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

private struct FirmwareSMCParam {
    struct Version {
        var major: UInt8 = 0
        var minor: UInt8 = 0
        var build: UInt8 = 0
        var reserved: UInt8 = 0
        var release: UInt16 = 0
    }
    struct PowerLimit {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpu: UInt32 = 0
        var gpu: UInt32 = 0
        var memory: UInt32 = 0
    }
    struct KeyInfo {
        var size: UInt32 = 0
        var type: UInt32 = 0
        var attributes: UInt8 = 0
    }

    var key: UInt32 = 0
    var version = Version()
    var powerLimit = PowerLimit()
    var info = KeyInfo()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var selector: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: FirmwareSMCBytes = (
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    )
}

enum FirmwareSMCTransportError: Error, CustomStringConvertible {
    case serviceMissing
    case openFailed(Int32)
    case accessDenied
    case keyMissing(String)
    case callFailed(io_return_t, UInt8)
    case invalidPayloadSize(Int)

    var description: String {
        switch self {
        case .serviceMissing: return "AppleSMC service not found"
        case .openFailed(let code): return "IOServiceOpen failed: \(code)"
        case .accessDenied: return "AppleSMC access denied; the helper must run with administrator privileges"
        case .keyMissing(let key): return "\(key) is not present"
        case .callFailed(let code, let result): return "SMC call failed: IOReturn=\(code), result=\(result)"
        case .invalidPayloadSize(let size): return "Invalid SMC payload size: \(size)"
        }
    }
}

/// A serialized AppleSMC transport. This class exposes raw register reads and
/// writes only to the isolated firmware controller; it is not wired into the
/// MauLeaf app or its current charging workflow.
final class AppleSMCFirmwareLimitTransport: FirmwareLimitTransport {
    private let lock = NSRecursiveLock()
    private var connection: io_connect_t = 0
    private var opened = false

    deinit { close() }

    func metadata(for key: FirmwareLimitKey) throws -> FirmwareLimitKeyMetadata {
        try locked {
            var input = FirmwareSMCParam()
            input.key = Self.fourCC(key.rawValue)
            input.selector = 9 // kSMCGetKeyInfo
            let output = try call(&input)
            return FirmwareLimitKeyMetadata(
                size: Int(output.info.size),
                type: Self.fourCCString(output.info.type)
            )
        }
    }

    func read(_ key: FirmwareLimitKey, count: Int) throws -> [UInt8] {
        guard (1...32).contains(count) else {
            throw FirmwareSMCTransportError.invalidPayloadSize(count)
        }
        return try locked {
            var input = FirmwareSMCParam()
            input.key = Self.fourCC(key.rawValue)
            input.info.size = UInt32(count)
            input.selector = 5 // kSMCReadKey
            let output = try call(&input)
            return withUnsafeBytes(of: output.bytes) { Array($0.prefix(count)) }
        }
    }

    func write(_ key: FirmwareLimitKey, bytes: [UInt8]) throws {
        guard (1...32).contains(bytes.count) else {
            throw FirmwareSMCTransportError.invalidPayloadSize(bytes.count)
        }
        try locked {
            var input = FirmwareSMCParam()
            input.key = Self.fourCC(key.rawValue)
            input.info.size = UInt32(bytes.count)
            input.selector = 6 // kSMCWriteKey
            withUnsafeMutableBytes(of: &input.bytes) { destination in
                destination.copyBytes(from: bytes)
            }
            _ = try call(&input)
        }
    }

    private func locked<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        try openIfNeeded()
        return try body()
    }

    private func openIfNeeded() throws {
        guard !opened else { return }
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSMC")
        )
        guard service != 0 else { throw FirmwareSMCTransportError.serviceMissing }
        defer { IOObjectRelease(service) }

        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        if result == kIOReturnNotPrivileged { throw FirmwareSMCTransportError.accessDenied }
        guard result == kIOReturnSuccess else {
            throw FirmwareSMCTransportError.openFailed(result)
        }
        opened = true
    }

    private func close() {
        lock.lock()
        defer { lock.unlock() }
        guard opened else { return }
        _ = IOServiceClose(connection)
        connection = 0
        opened = false
    }

    private func call(_ input: inout FirmwareSMCParam) throws -> FirmwareSMCParam {
        let size = MemoryLayout<FirmwareSMCParam>.stride
        guard size == 80 else {
            throw FirmwareSMCTransportError.callFailed(kIOReturnError, 0xFF)
        }
        var output = FirmwareSMCParam()
        var outputSize = size
        let result = IOConnectCallStructMethod(
            connection, 2, &input, size, &output, &outputSize
        )
        if result == kIOReturnNotPrivileged { throw FirmwareSMCTransportError.accessDenied }
        if result == kIOReturnSuccess && output.result == 132 {
            throw FirmwareSMCTransportError.keyMissing("requested SMC key")
        }
        guard result == kIOReturnSuccess, output.result == 0 else {
            throw FirmwareSMCTransportError.callFailed(result, output.result)
        }
        return output
    }

    private static func fourCC(_ text: String) -> UInt32 {
        let bytes = Array(text.utf8)
        guard bytes.count == 4 else { return 0 }
        return (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16)
            | (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
    }

    private static func fourCCString(_ value: UInt32) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)
        ]
        return String(bytes: bytes, encoding: .ascii)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
