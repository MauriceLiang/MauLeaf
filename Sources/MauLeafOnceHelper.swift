import Foundation

/// User-session watchdog for batt v0.8.0, which has `disable --for` but no
/// `charge full` command. launchd relaunches this checker every 20 seconds.
/// This code is intentionally a separate executable and does not depend on
/// SwiftUI, so monitoring does not depend on UI refreshes. Normal application
/// quit cancels this job before restoring system charging.
/// With --discharge it instead monitors a bounded adapter-disable lease until
/// completion; launchd restarts failures, but leaves completed tasks stopped.
@main
struct MauLeafOnceHelper {
    // Keep the legacy identity/path so ChargeCap settings and tasks remain compatible.
    static let label = "dev.mauriceliang.chargecap.once"

    static func main() {
        if CommandLine.arguments.dropFirst().contains("--discharge") {
            let monitor = DischargeMonitor(directory: DischargeMonitor.directory)
            do {
                while monitor.hasPendingJob {
                    try monitor.tick()
                    if monitor.hasPendingJob { Thread.sleep(forTimeInterval: 20) }
                }
            }
            catch {
                fputs("\(error.localizedDescription)\n", stderr)
                exit(1)
            }
            return
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let support = home.appendingPathComponent("Library/Application Support/ChargeCap", isDirectory: true)
        do {
            try ChargeTaskLock.exclusive(in: support, file: "once.lock") {
                restoreOnce(home: home, support: support)
            }
        } catch { fputs("\(error.localizedDescription)\n", stderr) }
    }

    private static func restoreOnce(home: URL, support: URL) {
        let jobURL = support.appendingPathComponent("once-task.json")
        let agentURL = home.appendingPathComponent("Library/LaunchAgents/\(label).plist")

        guard let data = try? Data(contentsOf: jobURL),
              let job = try? JSONDecoder().decode(OnceJob.self, from: data),
              (50...95).contains(job.limit),
              job.battPath.hasPrefix("/") else {
            return
        }
        let expired = Date().timeIntervalSince1970 >= job.expiryUnixSeconds
        let battery = process("/usr/bin/pmset", ["-g", "batt"])
        let isFull = battery?.exit == 0 &&
            battery?.output.range(of: #"\b100%"#, options: .regularExpression) != nil
        guard expired || isFull else { return }

        // Persist this before restoring the limit so restarting the UI cannot
        // immediately drain a battery that has just completed a full charge.
        do { try DischargeMonitor(directory: support).pauseForFullCharge(completed: true) }
        catch { fputs("\(error.localizedDescription)\n", stderr) }

        guard let restored = process(job.battPath, ["limit", String(job.limit)]), restored.exit == 0 else {
            // Keep task for retry. batt's --for=10h is a second independent
            // failsafe if this user-session helper is not available.
            return
        }
        guard let observed = process(job.battPath, ["status"]), observed.exit == 0,
              BattStatus.parse(observed.output).upperLimit == job.limit else { return }

        // Do not remove a new job created while we were working.
        guard let current = try? Data(contentsOf: jobURL),
              let recorded = try? JSONDecoder().decode(OnceJob.self, from: current),
              recorded.jobID == job.jobID else { return }
        try? FileManager.default.removeItem(at: jobURL)
        try? FileManager.default.removeItem(at: agentURL)
        _ = process("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
    }

    private static func process(_ binary: String, _ args: [String]) -> (exit: Int32, output: String)? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        let output = Pipe()
        p.standardOutput = output
        p.standardError = output
        do {
            try p.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        } catch { return nil }
    }
}
