import Foundation
import Darwin

/// Standalone hardware experiment. It is NOT linked into MauLeaf.app and
/// contains no daemon installer or persistent charge-control loop.
@main
private enum MauLeafUnpluggedRestoreProbe {
    private static let snapshotPath =
        "/Library/Application Support/MauLeaf/original-firmware-state.json"
    private static let confirmation = "UNPLUGGED BFf0 OFF MacBookPro18,1"
    private static let otherControllers = [
        "MauLeaf", "batt", "calma", "OpenDente", "BatteryControl",
        "Chargectl", "AlDente", "BatFi"
    ]

    static func main() {
        let command = CommandLine.arguments.dropFirst().first ?? "status"
        do {
            switch command {
            case "status":
                try showStatus()
            case "test-unplugged-deactivation":
                try testUnpluggedDeactivation()
            case "test-unplugged-full-restore":
                try testUnpluggedFullRestore()
            case "help", "--help", "-h":
                showHelp()
            default:
                showHelp()
                exit(2)
            }
        } catch {
            fputs("FAILED: \(error.localizedDescription)\n", stderr)
            fputs("No firmware recovery may be assumed from this result. Keep the original snapshot and helper.\n", stderr)
            exit(1)
        }
    }

    private static func showHelp() {
        print("""
        MauLeaf Unplugged Restore Probe — independent macOS 15 / M1 Pro diagnostic

        Usage:
          ./MauLeafUnpluggedRestoreProbe status
          sudo ./MauLeafUnpluggedRestoreProbe status
          sudo ./MauLeafUnpluggedRestoreProbe test-unplugged-deactivation
          sudo ./MauLeafUnpluggedRestoreProbe test-unplugged-full-restore

        status                      READ ONLY; no administrator rights normally required
        test-unplugged-deactivation Requires a verified MauLeaf snapshot, active
                                    limit, physically disconnected AC power,
                                    strict device match and typed confirmation.
                                    Writes ONLY bfF0 = 0x00 (disables limit).
        test-unplugged-full-restore
                                    EXPERIMENTAL: deactivates bfF0 then restores
                                    saved original bfD0/bfE0, with readback at
                                    every step. Does not delete helper/snapshot.
        Neither write mode ever enables a limit. No installation performed.
        """)
    }

    private static func showStatus() throws {
        printHeader()
        let identity = FirmwareLimitRuntime.identity()
        print("Model           : \(identity.modelIdentifier)")
        print("System firmware : \(identity.systemFirmware.isEmpty ? "(unavailable)" : identity.systemFirmware)")
        print("macOS           : \(ProcessInfo.processInfo.operatingSystemVersionString)")
        print("Architecture    : \(identity.architecture)")
        if let problem = FirmwareLimitWritePermit.targetBlockReason(identity: identity) {
            print("Write allowlist : BLOCKED — \(problem)")
        } else {
            print("Write allowlist : exact target matched")
        }
        let battery = MauLeafBatteryStatusReader.read()
        let pmset = pmsetOnBattery()
        print("External power  : \(battery.isACConnected.map(String.init(describing:)) ?? "unknown")")
        print("pmset battery   : \(pmset.map(String.init(describing:)) ?? "unknown")")
        print("Battery level   : \(battery.percent.map(String.init(describing:)) ?? "unknown")%")
        print("IsCharging      : \(battery.isCharging)")
        print("MauLeaf running : \(processIsRunning("MauLeaf"))")
        let transport = AppleSMCFirmwareLimitTransport()
        let state = try FirmwareLimitController(transport: transport).readState()
        printFirmware(state)
        if FileManager.default.fileExists(atPath: snapshotPath) {
            do {
                let snapshot = try readOriginalSnapshot()
                print("Original snapshot: verified file; original bfF0=\(hex(snapshot.state.activationByte)); pendingRestore=\(snapshot.restoreRequested)")
                print("Snapshot matches : \(FirmwareLimitWritePermit.restoreBlockReason(identity: identity, snapshotIdentity: snapshot.deviceIdentity) == nil)")
            } catch {
                print("Original snapshot: present but not verified (\(error.localizedDescription))")
            }
        } else {
            print("Original snapshot: MISSING — offline write test is not allowed")
        }
        print("Mode            : READ ONLY; no SMC registers were written.")
        print("Important       : bfF0 readback is NOT proof of physical battery charging.")
    }

    private static func testUnpluggedDeactivation() throws {
        guard geteuid() == 0 else {
            throw UnpluggedRestoreProbeError.administratorRequired
        }
        guard isatty(STDIN_FILENO) == 1 else {
            throw UnpluggedRestoreProbeError.confirmationMissing
        }

        let transport = AppleSMCFirmwareLimitTransport()
        let controller = FirmwareLimitController(transport: transport)
        let initialState = try controller.readState()
        // Preflight is repeated immediately before every actual SMC write.
        try preflight(transport: transport, baseline: initialState, confirmed: false,
                      ignoreMissingConfirmation: true)

        printHeader()
        let identity = FirmwareLimitRuntime.identity()
        print("Validated Mac   : \(identity.modelIdentifier), \(identity.systemFirmware)")
        print("Battery supply  : IOKit=false, pmset=Battery Power")
        print("Before write    :")
        printFirmware(initialState)
        print("")
        print("EXPERIMENTAL HARDWARE WRITE:")
        print("  Will write ONLY bfF0 = 0x00, to turn the active firmware limit OFF.")
        print("  Will NOT write bfD0 or bfE0, and will NEVER re-activate bfF0.")
        print("  Will NOT delete or modify your MauLeaf original-state snapshot.")
        print("  Will NOT uninstall the helper, create a daemon, or change adapter keys.")
        print("  This is a real SMC operation; failures or incomplete readback are possible.")
        print("  It tests the safety prerequisite for offline uninstall, NOT full uninstall.")
        print("")
        print("Enter EXACTLY: \(confirmation)")
        guard readLine(strippingNewline: true) == confirmation else {
            throw UnpluggedRestoreProbeError.confirmationMissing
        }
        try preflight(transport: transport, baseline: initialState, confirmed: true)

        let verified = try UnpluggedRestorePolicy.deactivate(
            transport: transport,
            baseline: initialState,
            preflight: {
                try preflight(transport: transport, baseline: initialState, confirmed: true)
            }
        )

        print("")
        print("OFFLINE DEACTIVATION TEST: PASS")
        print("After write     :")
        printFirmware(verified)
        print("Source          : battery-only power rechecked before every SMC write.")
        print("Snapshot        : preserved for subsequent full restoration.")
        print("Interpretation  : bfF0 readback confirms deactivation only.")
        print("NEXT: Reconnect power, allow the existing MauLeaf helper to finish exact")
        print("snapshot restoration, and verify actual charging above the former limit.")
        print("DO NOT uninstall all components based on this test alone.")
    }

    private static func testUnpluggedFullRestore() throws {
        guard geteuid() == 0 else {
            throw UnpluggedRestoreProbeError.administratorRequired
        }
        guard isatty(STDIN_FILENO) == 1 else {
            throw UnpluggedRestoreProbeError.confirmationMissing
        }

        let transport = AppleSMCFirmwareLimitTransport()
        let controller = FirmwareLimitController(transport: transport)
        let initial = try controller.readState()
        let snapshot = try readOriginalSnapshot()
        try preflight(transport: transport, baseline: initial, confirmed: false,
                      ignoreMissingConfirmation: true)
        guard initial.upper != snapshot.state.upper,
              initial.lower != snapshot.state.lower else {
            throw UnpluggedRestoreProbeError.firmwareWriteNotVerified(
                "A meaningful full-restore test requires BOTH current thresholds to differ from the saved original values."
            )
        }

        printHeader()
        print("TEST            : UNPLUGGED FULL ORIGINAL-STATE RESTORE")
        print("Before          :")
        printFirmware(initial)
        print("Original        :")
        printFirmware(snapshot.state)
        print("")
        print("EXPERIMENTAL HARDWARE WRITES WHILE UNPLUGGED:")
        print("  1. Write bfF0 = 0x00 (deactivate firmware limit).")
        print("  2. Restore EXACT original bfD0/bfE0 from root-owned snapshot.")
        print("  3. Verify all three registers; never re-enable bfF0.")
        print("  4. Preserve the snapshot and helper; do NOT uninstall yet.")
        print("The threshold write order preserves a valid range at each step.")
        print("The experiment is not risk-free and cannot prove future charging.")
        print("")
        let confirmation = "UNPLUGGED FULL RESTORE MacBookPro18,1"
        print("Enter EXACTLY: \(confirmation)")
        guard readLine(strippingNewline: true) == confirmation else {
            throw UnpluggedRestoreProbeError.confirmationMissing
        }
        try preflight(transport: transport, baseline: initial, confirmed: true)

        let final = try UnpluggedRestorePolicy.restoreOriginal(
            transport: transport,
            before: initial,
            original: snapshot.state,
            preflight: { expected in
                try preflight(transport: transport, baseline: expected, confirmed: true)
            }
        )

        print("")
        print("OFFLINE FULL RESTORE TEST: PASS")
        print("After           :")
        printFirmware(final)
        print("Snapshot        : preserved for the existing Helper to remove after reconnect.")
        print("IMPORTANT       : Full register readback passed; this is not a complete uninstall.")
        print("NEXT            : Reconnect AC, let Helper finish recovery, and confirm actual charging.")
        print("DO NOT remove helper/snapshot just because this experiment passed.")
    }

    private static func preflight(
        transport: FirmwareLimitTransport,
        baseline: FirmwareLimitState,
        confirmed: Bool,
        ignoreMissingConfirmation: Bool = false
    ) throws {
        let identity = FirmwareLimitRuntime.identity()
        let original = try readOriginalSnapshot()
        let battery = MauLeafBatteryStatusReader.read()
        let pmset = pmsetOnBattery()
        let conflict = otherControllers.first(where: processIsRunning)
        let context = UnpluggedRestoreConditions(
            identity: identity,
            originalSnapshot: original,
            currentState: baseline,
            isAdministrator: geteuid() == 0,
            externalConnected: battery.isACConnected,
            pmsetReportsBatteryPower: pmset == true,
            batteryPercent: battery.percent,
            batteryIsCharging: battery.isCharging,
            conflictingProcess: conflict,
            explicitlyConfirmed: confirmed || ignoreMissingConfirmation
        )
        try UnpluggedRestorePolicy.authorize(context, requireActive: baseline.isActive)
        // Ensure no other actor has changed the thresholds since the first
        // successful read. No write is permitted if the baseline is stale.
        let latest = try FirmwareLimitController(transport: transport).readState()
        guard latest == baseline else {
            throw UnpluggedRestoreProbeError.firmwareStateChanged
        }
    }

    private static func readOriginalSnapshot() throws -> FirmwareLimitOriginalStateSnapshot {
        let url = URL(fileURLWithPath: snapshotPath)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attrs[.type] as? FileAttributeType) == .typeRegular,
              (attrs[.ownerAccountID] as? NSNumber)?.intValue == 0,
              let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue,
              perms & 0o077 == 0,
              let size = (attrs[.size] as? NSNumber)?.intValue,
              size > 0, size <= 65_536,
              (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw UnpluggedRestoreProbeError.missingOriginalInactiveSnapshot
        }
        let data = try Data(contentsOf: url)
        let snapshot = try JSONDecoder().decode(FirmwareLimitOriginalStateSnapshot.self, from: data)
        guard snapshot.isValid, snapshot.state.activationByte == 0 else {
            throw UnpluggedRestoreProbeError.missingOriginalInactiveSnapshot
        }
        return snapshot
    }

    private static func pmsetOnBattery() -> Bool? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "batt"]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let text = String(data: data, encoding: .utf8) else { return nil }
            if text.contains("Now drawing from 'Battery Power'") { return true }
            if text.contains("Now drawing from 'AC Power'") { return false }
            return nil
        } catch {
            return nil
        }
    }

    private static func processIsRunning(_ name: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-x", name]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            // Fail closed: inability to inspect other SMC controllers is NOT
            // evidence that no other controller is running.
            return true
        }
    }

    private static func printHeader() {
        print("MauLeaf Unplugged Restore Probe — macOS 15, MacBookPro18,1")
        print("========================================================")
        print("Timestamp       : \(ISO8601DateFormatter().string(from: Date()))")
    }

    private static func printFirmware(_ state: FirmwareLimitState) {
        print("bfF0            : \(hex(state.activationByte)) \(state.isActive ? "(ACTIVE)" : "(inactive)")")
        print("bfD0 upper      : \(state.upper)%")
        print("bfE0 lower      : \(state.lower)%")
    }

    private static func hex(_ byte: UInt8) -> String {
        String(format: "0x%02X", byte)
    }
}
