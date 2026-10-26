import Foundation
import AppKit

/// Installs a per-user launchd checker. No root is needed because MauLeaf's
/// batt installation enables the socket's non-root access. If a preexisting
/// service does not allow writes, we report a real error and do not start the
/// one-time mode.
@MainActor
enum OnceChargeAgent {
    // Keep the legacy identity/path so ChargeCap settings and tasks remain compatible.
    private static let label = "dev.mauriceliang.chargecap.once"
    private static let home = FileManager.default.homeDirectoryForCurrentUser
    private static let support = home.appendingPathComponent("Library/Application Support/ChargeCap", isDirectory: true)
    private static let jobFile = support.appendingPathComponent("once-task.json")
    private static let executable = support.appendingPathComponent("MauLeafOnceHelper")
    private static let plistURL = home.appendingPathComponent("Library/LaunchAgents/\(label).plist")

    static var hasPendingJob: Bool { FileManager.default.fileExists(atPath: jobFile.path) }

    static func prepare(battPath: String, limit: Int) async throws {
        guard let helper = Bundle.main.url(forResource: "MauLeafOnceHelper", withExtension: nil),
              FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw ChargingError.helper("应用包内缺少 MauLeafOnceHelper，请重新构建")
        }
        guard (50...95).contains(limit), FileManager.default.isExecutableFile(atPath: battPath) else {
            throw ChargingError.helper("控制组件或上限值不正确")
        }
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: executable)
        try FileManager.default.copyItem(at: helper, to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let job = OnceJob(limit: limit, battPath: battPath,
                          expiryUnixSeconds: Date().addingTimeInterval(10 * 3600).timeIntervalSince1970,
                          jobID: UUID().uuidString)
        try JSONEncoder().encode(job).write(to: jobFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: jobFile.path)

        let config: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable.path],
            "RunAtLoad": true,
            "StartInterval": 20,
            "ProcessType": "Background"
        ]
        let plist = try PropertyListSerialization.data(fromPropertyList: config, format: .xml, options: 0)
        try plist.write(to: plistURL, options: .atomic)
        // First try to remove any previously registered instance.
        _ = await process("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
        let launched = await process("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plistURL.path])
        guard launched.0 == 0 else {
            try? FileManager.default.removeItem(at: jobFile)
            try? FileManager.default.removeItem(at: plistURL)
            throw ChargingError.helper(AppText(verbatim: launched.1))
        }
    }

    static func cancel() async throws {
        let support = support
        let jobFile = jobFile
        let plistURL = plistURL
        // Let an in-flight restore finish before removing the marker and
        // stopping launchd, so its child cannot restore a limit after quit.
        try await Task.detached(priority: .utility) {
            try ChargeTaskLock.exclusive(in: support, file: "once.lock") {
                if FileManager.default.fileExists(atPath: jobFile.path) { try FileManager.default.removeItem(at: jobFile) }
                if FileManager.default.fileExists(atPath: plistURL.path) { try FileManager.default.removeItem(at: plistURL) }
            }
        }.value
        _ = await process("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
    }

    private static func process(_ binary: String, _ arguments: [String]) async -> (Int32, String) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: binary)
                task.arguments = arguments
                task.standardInput = FileHandle.nullDevice
                let pipe = Pipe()
                task.standardOutput = pipe
                task.standardError = pipe
                do {
                    try task.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    task.waitUntilExit()
                    continuation.resume(returning: (task.terminationStatus, String(data: data, encoding: .utf8) ?? ""))
                } catch {
                    continuation.resume(returning: (-1, error.localizedDescription))
                }
            }
        }
    }
}
