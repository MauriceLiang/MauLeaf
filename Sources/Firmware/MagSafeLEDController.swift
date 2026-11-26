import Foundation

protocol MagSafeLEDTransport {
    func readMagSafeLED() throws -> UInt8
    func writeMagSafeLED(_ value: UInt8) throws
}

extension AppleSMCFirmwareLimitTransport: MagSafeLEDTransport {}

/// Used only inside the existing privileged Helper's serialized hardware
/// section. A durable marker precedes every green override, so a crash,
/// normal quit or uninstall cannot silently abandon an override.
final class MagSafeLEDController {
    private let transport: MagSafeLEDTransport
    private let marker: URL
    private let wait: (TimeInterval) -> Void
    private let lock = NSRecursiveLock()
    private var ownedBand: FirmwareLimitState?
    private var failedBand: FirmwareLimitState?

    init(transport: MagSafeLEDTransport, marker: URL,
         wait: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) {
        self.transport = transport
        self.marker = marker
        self.wait = wait
    }

    var hasMarker: Bool {
        FileManager.default.fileExists(atPath: marker.path)
    }

    var needsRelease: Bool {
        lock.lock()
        defer { lock.unlock() }
        return hasMarker && ownedBand == nil
    }

    func synchronize(state: FirmwareLimitState, observation: MagSafeLEDObservation,
                     ownsChargeLimit: Bool, authorized: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard authorized else { return }
        // A surviving marker belongs to an interrupted session. Release it
        // before starting a fresh override (including after helper upgrade).
        if needsRelease {
            restoreAutomatic(authorized: authorized)
            return
        }
        let wantsGreen = MagSafeLEDPolicy.wantsGreen(
            state: state, observation: observation, ownsChargeLimit: ownsChargeLimit,
            ownsSameBand: hasMarker && ownedBand == state)
        guard wantsGreen else {
            failedBand = nil
            restoreAutomatic(authorized: authorized)
            return
        }
        guard failedBand != state else { return }
        do {
            let value = try transport.readMagSafeLED()
            // Do not take ownership of a green LED already controlled by macOS.
            if !hasMarker && value != 0x04 { return }
            if hasMarker && ownedBand == state && value == 0x03 { return }
            // Never force an unrecognized/off LED into a visible state.
            guard value == 0x04 || (hasMarker && value == 0x03) else {
                restoreAutomatic(authorized: authorized)
                return
            }
            if !hasMarker {
                let fs = FileManager.default
                try fs.createDirectory(at: marker.deletingLastPathComponent(),
                    withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
                try Data("green-v1".utf8).write(to: marker, options: .atomic)
                try fs.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
            }
            try transport.writeMagSafeLED(0x03)
            // Verified hardware updates asynchronously: do not treat an
            // immediate read of the previous value as a write failure.
            for _ in 0..<3 {
                wait(0.05)
                if try transport.readMagSafeLED() == 0x03 {
                    ownedBand = state
                    return
                }
            }
            throw NSError(domain: "MauLeaf.MagSafeLED", code: 1)
        } catch {
            failedBand = state
            NSLog("MauLeaf MagSafe LED override unavailable; charging control unchanged: %@", error.localizedDescription)
            restoreAutomatic(authorized: authorized)
        }
    }

    func restoreAutomatic(authorized: Bool) {
        lock.lock()
        defer { lock.unlock() }
        ownedBand = nil
        guard hasMarker, authorized else { return }
        do {
            // Only release an override recorded by MauLeaf. Do not restore
            // an arbitrary previous color or forcibly command orange.
            guard try Data(contentsOf: marker) == Data("green-v1".utf8) else {
                throw NSError(domain: "MauLeaf.MagSafeLED", code: 2)
            }
            _ = try transport.readMagSafeLED()
            try transport.writeMagSafeLED(0x00)
            // On validated hardware 00 is an accepted command, not a stable
            // register value. macOS selects the color asynchronously.
            try FileManager.default.removeItem(at: marker)
        } catch {
            NSLog("MauLeaf MagSafe automatic-control handoff pending: %@", error.localizedDescription)
        }
    }
}
