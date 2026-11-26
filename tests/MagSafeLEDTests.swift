import Foundation

private final class FakeMagSafeLEDTransport: MagSafeLEDTransport {
    var value: UInt8 = 0x04
    var commands: [UInt8] = []
    var failAuto = false
    var ignoreGreen = false
    var pendingGreen = false

    func readMagSafeLED() throws -> UInt8 { value }
    func writeMagSafeLED(_ value: UInt8) throws {
        precondition(value == 0x03 || value == 0x00)
        commands.append(value)
        if value == 0x00 {
            if failAuto { throw NSError(domain: "fake", code: 1) }
            self.value = 0x04
        } else if !ignoreGreen { pendingGreen = true }
    }
    func advance() {
        if pendingGreen { value = 0x03; pendingGreen = false }
    }
}

enum MagSafeLEDTests {
    static func run() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MauLeafLED-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("magsafe-led.pending")
        let fake = FakeMagSafeLEDTransport()
        let led = MagSafeLEDController(transport: fake, marker: marker, wait: { _ in fake.advance() })
        let active = FirmwareLimitState(activationByte: 2, upper: 80, lower: 78)
        let inactive = FirmwareLimitState(activationByte: 0, upper: 80, lower: 78)
        func observation(_ pct: Double?, charging: Bool? = false, full: Bool? = false,
                         ac: Bool? = true, magSafe: Bool = true) -> MagSafeLEDObservation {
            MagSafeLEDObservation(externalConnected: ac, isCharging: charging,
                isFullyCharged: full, rawPercent: pct, magSafeConnected: magSafe)
        }
        func sync(_ state: FirmwareLimitState = active, _ value: MagSafeLEDObservation,
                  owns: Bool = true, allowed: Bool = true) {
            led.synchronize(state: state, observation: value, ownsChargeLimit: owns, authorized: allowed)
        }
        sync(active, observation(80), allowed: false)
        sync(active, observation(80), owns: false)
        sync(active, observation(80, charging: nil))
        sync(active, observation(80, magSafe: false))
        sync(active, observation(80, ac: nil))
        sync(active, observation(nil))
        sync(active, observation(79.0))
        sync(active, observation(80, charging: true))
        sync(inactive, observation(80))
        precondition(fake.commands.isEmpty && !led.hasMarker)
        sync(active, observation(79.9))
        precondition(fake.commands == [3] && fake.value == 3 && led.hasMarker)
        sync(active, observation(79))
        precondition(fake.commands == [3], "Holding band must not rewrite green")
        sync(active, observation(78))
        precondition(fake.commands == [3, 0] && !led.hasMarker)
        sync(active, observation(80))
        sync(active, observation(80, charging: true))
        precondition(fake.commands == [3, 0, 3, 0])
        sync(active, observation(80))
        sync(active, observation(80, ac: false, magSafe: false))
        precondition(fake.commands.suffix(2) == [3, 0] && !led.hasMarker)
        sync(active, observation(80))
        sync(inactive, observation(80))
        precondition(fake.commands.suffix(2) == [3, 0] && !led.hasMarker)
        fake.value = 3
        let count = fake.commands.count
        sync(active, observation(80))
        precondition(fake.commands.count == count && !led.hasMarker, "Do not own system green")
        fake.value = 4
        sync(active, observation(80))
        let restarted = MagSafeLEDController(transport: fake, marker: marker, wait: { _ in })
        precondition(restarted.needsRelease)
        fake.failAuto = true
        restarted.restoreAutomatic(authorized: true)
        precondition(restarted.hasMarker && restarted.needsRelease)
        fake.failAuto = false
        restarted.restoreAutomatic(authorized: true)
        precondition(!restarted.hasMarker && fake.commands.last == 0)
        // Failed verification must release automatically and never loop writes.
        let failing = MagSafeLEDController(transport: fake, marker: marker, wait: { _ in })
        fake.ignoreGreen = true
        failing.synchronize(state: active, observation: observation(80), ownsChargeLimit: true, authorized: true)
        precondition(fake.commands.suffix(2) == [3, 0] && !failing.hasMarker)
        let failedCount = fake.commands.count
        failing.synchronize(state: active, observation: observation(80), ownsChargeLimit: true, authorized: true)
        precondition(fake.commands.count == failedCount)
        print("MagSafeLEDTests: PASS (policy, asynchronous readback, hysteresis, fail closed, durable handoff, no repeated writes)")
    }
}
