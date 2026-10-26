import Foundation

@MainActor
enum DischargeAgent {
    static let label = "dev.mauriceliang.chargecap.discharge"
    private static let monitor = DischargeMonitor(directory: DischargeMonitor.directory)
    private static let plistURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/\(label).plist")

    static var hasPendingJob: Bool { monitor.hasPendingJob }
    static var result: DischargeResult? { monitor.result }

    static func start(battPath: String, limit: Int) async throws {
        try await stop()
        guard let helper = Bundle.main.url(forResource: "ChargeCapOnceHelper", withExtension: nil),
              FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw ChargingError.helper("应用包内缺少充电监控程序，请重新构建")
        }
        let executable = monitor.directory.appendingPathComponent("ChargeCapDischargeHelper")
        try FileManager.default.createDirectory(at: monitor.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if FileManager.default.fileExists(atPath: executable.path) { try FileManager.default.removeItem(at: executable) }
        try FileManager.default.copyItem(at: helper, to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let monitor = monitor
        try await Task.detached(priority: .utility) { try monitor.start(battPath: battPath, limit: limit) }.value
        guard monitor.hasPendingJob else { return }
        do {
            try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let config: [String: Any] = [
                "Label": label,
                "ProgramArguments": [executable.path, "--discharge"],
                "RunAtLoad": true,
                "KeepAlive": ["SuccessfulExit": false],
                "ThrottleInterval": 10,
                "ProcessType": "Background",
                "StandardErrorPath": monitor.directory.appendingPathComponent("discharge.log").path
            ]
            try PropertyListSerialization.data(fromPropertyList: config, format: .xml, options: 0)
                .write(to: plistURL, options: .atomic)
            let path = plistURL.path
            let launched = await Task.detached(priority: .utility) {
                ChargeProcess.run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", path])
            }.value
            guard launched.status == 0 else { throw ChargingError.helper(launched.output) }
        } catch {
            try await stop()
            throw error
        }
    }

    static func stop() async throws {
        // Wait for any in-flight CLI to finish under the shared lock before
        // killing the helper; otherwise its child could cut power after recovery.
        let monitor = monitor
        try await Task.detached(priority: .utility) { try monitor.cancel() }.value
        let service = "gui/\(getuid())/\(label)"
        _ = await Task.detached(priority: .utility) {
            ChargeProcess.run("/bin/launchctl", ["bootout", service])
        }.value
        if FileManager.default.fileExists(atPath: plistURL.path) { try FileManager.default.removeItem(at: plistURL) }
    }

    static func pauseForFullCharge() throws { try monitor.pauseForFullCharge() }
}
