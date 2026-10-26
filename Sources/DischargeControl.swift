import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct ChargeProcessResult {
    let status: Int32
    let output: String
}

// A stuck CLI must not keep the watchdog locked or renew an unsafe lease.
enum ChargeProcess {
    static func run(_ path: String, _ arguments: [String]) -> ChargeProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch {
            return ChargeProcessResult(status: -1, output: error.localizedDescription)
        }
        let timeout = DispatchWorkItem {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 8, execute: timeout)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        return ChargeProcessResult(status: process.terminationStatus, output: String(data: data, encoding: .utf8) ?? "")
    }
}

struct DischargeSafetySnapshot {
    let percent: Int?
    let temperatureCelsius: Double?
    let lidClosed: Bool?
    let externalConnected: Bool?

    func stopReason(target: Int) -> DischargeResult? {
        guard let percent, (0...100).contains(percent),
              let temperatureCelsius, temperatureCelsius.isFinite,
              let lidClosed else { return DischargeResult(paused: true, message: "安全读数不可用，已停止主动降电量") }
        if lidClosed { return DischargeResult(paused: true, message: "已合盖，已停止主动降电量") }
        if temperatureCelsius <= 0 || temperatureCelsius >= 45 {
            return DischargeResult(paused: true, message: "电池温度超出 0–45°C 安全范围，已停止主动降电量")
        }
        if percent <= target { return DischargeResult(paused: false, message: "已达到充电上限") }
        return nil
    }

    static func parse(batteryData: Data, lidData: Data) -> DischargeSafetySnapshot {
        func properties(_ data: Data) -> [String: Any] {
            guard let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]],
                  let first = list.first else { return [:] }
            return first
        }
        let battery = properties(batteryData)
        let lid = properties(lidData)
        return DischargeSafetySnapshot(
            percent: (battery["CurrentCapacity"] as? NSNumber)?.intValue,
            temperatureCelsius: (battery["Temperature"] as? NSNumber).map { $0.doubleValue / 10 - 273.15 },
            lidClosed: (lid["AppleClamshellState"] as? NSNumber)?.boolValue,
            externalConnected: (battery["ExternalConnected"] as? NSNumber)?.boolValue)
    }

    static func read() -> DischargeSafetySnapshot {
        let battery = ChargeProcess.run("/usr/sbin/ioreg", ["-a", "-r", "-c", "AppleSmartBattery"])
        let lid = ChargeProcess.run("/usr/sbin/ioreg", ["-a", "-r", "-c", "IOPMrootDomain"])
        return parse(batteryData: Data((battery.status == 0 ? battery.output : "").utf8),
                     lidData: Data((lid.status == 0 ? lid.output : "").utf8))
    }
}

enum ChargeTaskLock {
    static func exclusive<T>(in directory: URL, file: String, _ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let descriptor = open(directory.appendingPathComponent(file).path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw ChargingError.helper("无法打开后台充电任务锁") }
        defer { close(descriptor) }
        let deadline = Date().addingTimeInterval(30)
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EAGAIN else { throw ChargingError.helper("无法锁定后台充电任务") }
            guard Date() < deadline else { throw ChargingError.helper("等待后台充电任务结束超时，请稍后重试") }
            Thread.sleep(forTimeInterval: 0.02)
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }
}

struct DischargeJob: Codable {
    let limit: Int
    let battPath: String
    let expiryUnixSeconds: Double
}

struct DischargeResult: Codable {
    let paused: Bool
    let message: String
    var completedFullCharge = false
}

// Shared by the UI and the independent helper. Every hardware transition is
// serialized across processes; cancellation cannot race a lease renewal.
struct DischargeMonitor {
    // Keep the legacy identity/path so ChargeCap settings and tasks remain compatible.
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ChargeCap", isDirectory: true)
    let directory: URL
    var run: (String, [String]) -> ChargeProcessResult = ChargeProcess.run
    var snapshot: () -> DischargeSafetySnapshot = DischargeSafetySnapshot.read
    var now: () -> Date = Date.init

    var jobURL: URL { directory.appendingPathComponent("discharge-task.json") }
    var resultURL: URL { directory.appendingPathComponent("discharge-result.json") }
    var hasPendingJob: Bool { FileManager.default.fileExists(atPath: jobURL.path) }
    var result: DischargeResult? {
        guard FileManager.default.fileExists(atPath: resultURL.path) else { return nil }
        do { return try JSONDecoder().decode(DischargeResult.self, from: Data(contentsOf: resultURL)) }
        catch { return DischargeResult(paused: true, message: "后台结果文件无法读取，请重新选择处理策略") }
    }

    func start(battPath: String, limit: Int) throws {
        try locked {
            guard (50...95).contains(limit), battPath.hasPrefix("/") else {
                throw ChargingError.helper("主动降电量的上限或控制程序路径不正确")
            }
            guard !hasPendingJob else { throw ChargingError.helper("上一次主动降电量任务尚未停止") }
            let status = try checkedStatus(battPath)
            guard status.supportsAdapterControl == true, status.adapterEnabled == true,
                  status.upperLimit == limit else {
                throw ChargingError.verification("需确认适配器控制受支持、适配器已启用且限充上限已生效")
            }
            let sample = snapshot()
            if let reason = sample.stopReason(target: limit) {
                if !reason.paused {
                    try writeResult(reason)
                    return
                }
                try writeResult(reason)
                throw ChargingError.verification(reason.message)
            }
            if sample.externalConnected == false {
                try writeResult(DischargeResult(paused: false, message: "当前未接适配器，正常使用电池；接入适配器后处理高电量"))
                return
            }
            guard sample.externalConnected == true else {
                let reason = DischargeResult(paused: true, message: "无法确认适配器连接状态，主动降电量已暂停")
                try writeResult(reason)
                throw ChargingError.verification(reason.message)
            }
            if FileManager.default.fileExists(atPath: resultURL.path) { try FileManager.default.removeItem(at: resultURL) }
            let job = DischargeJob(limit: limit, battPath: battPath,
                                   expiryUnixSeconds: now().addingTimeInterval(4 * 3600).timeIntervalSince1970)
            try JSONEncoder().encode(job).write(to: jobURL, options: .atomic)
            try tickLocked(job)
        }
    }

    func tick() throws {
        try locked {
            guard hasPendingJob else { return }
            let job = try readJob()
            try tickLocked(job)
        }
    }

    func cancel() throws {
        try locked {
            guard hasPendingJob else { return }
            let job = try readJob()
            try writeResult(DischargeResult(paused: true, message: "正在恢复适配器供电，尚未确认完成"))
            try restore(job, result: DischargeResult(paused: false, message: "已恢复适配器供电"))
        }
    }

    func pauseForFullCharge(completed: Bool = false) throws {
        try locked {
            try writeResult(DischargeResult(paused: true, message: "充满操作后暂缓主动放电，可手动恢复",
                                            completedFullCharge: completed))
        }
    }

    private func tickLocked(_ job: DischargeJob) throws {
        do {
            let status = try checkedStatus(job.battPath)
            let sample = snapshot()
            let reason: DischargeResult?
            if let result, result.paused { reason = result }
            else if now().timeIntervalSince1970 >= job.expiryUnixSeconds {
                reason = DischargeResult(paused: true, message: "主动降电量已达 4 小时，已触发超时保护")
            } else if status.supportsAdapterControl != true || status.upperLimit != job.limit
                        || FileManager.default.fileExists(atPath: directory.appendingPathComponent("once-task.json").path) {
                reason = DischargeResult(paused: true, message: "充电模式或设备能力已变化，已停止主动降电量")
            } else if let stop = sample.stopReason(target: job.limit) {
                reason = stop
            } else { reason = nil }
            if let reason { try restore(job, result: reason); return }

            try command(job.battPath, .useBatteryTemporarily)
            guard try checkedStatus(job.battPath).adapterEnabled == false else {
                throw ChargingError.verification("未确认设备已切换为电池供电")
            }
        } catch {
            let failure = DischargeResult(paused: true, message: "主动降电量失败：\(error.localizedDescription)")
            // Record the stop before recovery: failed recovery must never be
            // followed by another adapter-disable lease on the next tick.
            try writeResult(failure)
            do { try restore(job, result: failure) } catch {
                throw ChargingError.helper("恢复适配器供电尚未确认，将重试；\(error.localizedDescription)")
            }
            throw error
        }
    }

    private func restore(_ job: DischargeJob, result: DischargeResult) throws {
        try command(job.battPath, .useAdapter)
        guard try checkedStatus(job.battPath).adapterEnabled == true else {
            throw ChargingError.verification("未确认适配器供电已恢复")
        }
        try writeResult(result)
        try FileManager.default.removeItem(at: jobURL)
    }

    private func checkedStatus(_ path: String) throws -> BattStatus {
        let result = run(path, BattCommand.readStatus.arguments)
        guard result.status == 0 else { throw ChargingError.command(result.output) }
        return BattStatus.parse(result.output)
    }

    private func readJob() throws -> DischargeJob {
        do {
            let job = try JSONDecoder().decode(DischargeJob.self, from: Data(contentsOf: jobURL))
            guard (50...95).contains(job.limit), job.battPath.hasPrefix("/"), job.expiryUnixSeconds.isFinite else {
                throw ChargingError.helper("主动降电量任务参数不正确")
            }
            return job
        } catch {
            try writeResult(DischargeResult(paused: true, message: "后台任务文件无法读取；不会续期停供，请检查组件状态"))
            throw error
        }
    }

    private func command(_ path: String, _ command: BattCommand) throws {
        let result = run(path, command.arguments)
        guard result.status == 0 else { throw ChargingError.command(result.output) }
    }

    private func writeResult(_ result: DischargeResult) throws {
        try JSONEncoder().encode(result).write(to: resultURL, options: .atomic)
    }

    private func locked<T>(_ body: () throws -> T) throws -> T {
        try ChargeTaskLock.exclusive(in: directory, file: "discharge.lock", body)
    }
}
