import SwiftUI
import AppKit
import Foundation

@main
struct ChargeCapUninstallerApp: App {
    @StateObject private var model = UninstallerModel()

    var body: some Scene {
        WindowGroup {
            UninstallerView(model: model)
                .frame(width: 440, height: 330)
        }
        .windowResizability(.contentSize)
    }
}

struct UninstallerView: View {
    @ObservedObject var model: UninstallerModel
    @State private var showConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Group {
                    if let url = Bundle.main.url(forResource: "ChargeCapIcon", withExtension: "png"),
                       let icon = NSImage(contentsOf: url) {
                        Image(nsImage: icon).resizable().interpolation(.high)
                    } else {
                        Image(systemName: "leaf.fill").resizable().scaledToFit().padding(12)
                    }
                }
                .frame(width: 54, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 3) {
                    Text("卸载 ChargeCap")
                        .font(.title2.weight(.semibold))
                    Text("移除应用及其管理的充电控制组件")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Label("停止并卸载 ChargeCap 管理的 batt 服务", systemImage: "server.rack")
                Label("清理组件文件、系统服务和组件配置", systemImage: "trash")
                Label("移除 /Applications 中的 ChargeCap.app", systemImage: "app.badge.minus")
                Label("保留 Homebrew 或其他来源安装的 batt", systemImage: "checkmark.shield")
            }
            .font(.callout)

            Text(model.status)
                .font(.caption)
                .foregroundStyle(model.isError ? Color.orange : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            HStack {
                Button("关闭") { NSApp.terminate(nil) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(role: .destructive) {
                    showConfirmation = true
                } label: {
                    Label(model.isBusy ? "正在卸载…" : "卸载 ChargeCap", systemImage: "trash")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isBusy)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .alert("确认完整卸载？", isPresented: $showConfirmation) {
            Button("取消", role: .cancel) { }
            Button("完整卸载", role: .destructive) { model.uninstallEverything() }
        } message: {
            Text("将先尝试恢复默认充电控制，再卸载由 ChargeCap 管理的服务和配置。此操作需要管理员授权。外部安装的 batt 不会被删除。")
        }
    }
}

@MainActor
final class UninstallerModel: ObservableObject {
    @Published var status = "准备就绪。建议先退出 ChargeCap 主应用。"
    @Published var isBusy = false
    @Published var isError = false

    private let receiptPath = "/Library/Application Support/ChargeCap/managed-install"
    private let daemonPlistPath = "/Library/LaunchDaemons/cc.chlc.batt.plist"
    private let managedBinaryPath = "/usr/local/bin/batt"

    func uninstallEverything() {
        guard !isBusy else { return }
        isBusy = true
        isError = false
        status = "正在检查安装来源并请求管理员授权…授权后将先恢复默认充电控制。"

        Task {
            do {
                try await DischargeAgent.stop()
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ChargeCapFullUninstall-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                defer { try? FileManager.default.removeItem(at: directory) }

                let scriptURL = directory.appendingPathComponent("uninstall-chargecap.sh")
                let receipt = shellQuote(receiptPath)
                let daemonPlist = shellQuote(daemonPlistPath)
                let target = shellQuote(managedBinaryPath)
                let userHome = shellQuote(FileManager.default.homeDirectoryForCurrentUser.path)
                let bundledBatt = shellQuote(Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/batt").path)
                let script = """
                #!/bin/bash
                set -euo pipefail
                RECEIPT=\(receipt)
                DAEMON_PLIST=\(daemonPlist)
                TARGET=\(target)
                USER_HOME=\(userHome)
                BUNDLED_BATT=\(bundledBatt)

                if /usr/bin/pgrep -x ChargeCap >/dev/null 2>&1; then
                  echo '请先完全退出 ChargeCap 主应用，再运行卸载器。' >&2
                  exit 51
                fi

                PLIST_LABEL=$(/usr/libexec/PlistBuddy -c 'Print :Label' "$DAEMON_PLIST" 2>/dev/null || true)
                PLIST_ARGS=$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments' "$DAEMON_PLIST" 2>/dev/null || true)
                LEGACY_MANAGED=0
                if [ -f "$DAEMON_PLIST" ] && [ "$PLIST_LABEL" = 'cc.chlc.batt' ] && [[ "$PLIST_ARGS" == *"$TARGET"* ]]; then
                  LEGACY_MANAGED=1
                fi
                MANAGED=0
                if [ -f "$RECEIPT" ] || [ "$LEGACY_MANAGED" = "1" ]; then
                  MANAGED=1
                fi

                if [ "$MANAGED" = "1" ]; then
                  for candidate in /opt/homebrew/bin/batt /opt/homebrew/sbin/batt /usr/local/sbin/batt; do
                    if [ -x "$candidate" ]; then
                      echo "检测到其他位置的 batt：$candidate。为避免影响另一种安装方式，已停止卸载。" >&2
                      exit 52
                    fi
                  done
                  if [ -f "$DAEMON_PLIST" ] && { [ "$PLIST_LABEL" != 'cc.chlc.batt' ] || [[ "$PLIST_ARGS" != *"$TARGET"* ]]; }; then
                    echo '系统服务的名称或程序路径与预期不一致；已停止卸载。' >&2
                    exit 56
                  fi
                  if [ ! -x "$TARGET" ]; then
                    if [ ! -x "$BUNDLED_BATT" ]; then
                      echo '控制程序缺失，且卸载器没有可用的内置副本，无法安全恢复默认充电控制。' >&2
                      exit 53
                    fi
                    /bin/mkdir -p /usr/local/bin
                    /usr/bin/install -m 755 "$BUNDLED_BATT" "$TARGET"
                    /usr/bin/xattr -d com.apple.quarantine "$TARGET" >/dev/null 2>&1 || true
                  fi
                  if ! "$TARGET" disable; then
                    echo '恢复默认充电控制失败（batt disable）；为安全起见，未继续卸载。' >&2
                    exit 54
                  fi
                  if ! "$TARGET" uninstall; then
                    echo 'batt uninstall 未成功；未删除服务和程序文件。' >&2
                    exit 55
                  fi
                  /bin/launchctl bootout system/cc.chlc.batt >/dev/null 2>&1 || true
                  /bin/rm -f "$DAEMON_PLIST" "$TARGET"
                  /bin/rm -f /etc/batt* 2>/dev/null || true
                  /bin/rm -f "$RECEIPT"
                  /bin/rmdir "$(/usr/bin/dirname "$RECEIPT")" >/dev/null 2>&1 || true
                else
                  echo '未找到 ChargeCap 管理凭据；未触碰任何现有 batt 安装。'
                fi

                # Unregister only ChargeCap's own one-time-charge LaunchAgent.
                USER_UID=$(/usr/bin/stat -f %u "$USER_HOME" 2>/dev/null || true)
                if [[ "$USER_UID" =~ ^[0-9]+$ ]]; then
                  /bin/launchctl bootout "gui/$USER_UID/dev.mauriceliang.chargecap.once" >/dev/null 2>&1 || true
                  /bin/launchctl bootout "gui/$USER_UID/dev.mauriceliang.chargecap.discharge" >/dev/null 2>&1 || true
                fi
                /bin/rm -f "$USER_HOME/Library/LaunchAgents/dev.mauriceliang.chargecap.once.plist"
                /bin/rm -f "$USER_HOME/Library/LaunchAgents/dev.mauriceliang.chargecap.discharge.plist"
                /bin/rm -f "$USER_HOME/Library/Preferences/com.local.chargecap.plist"
                /bin/rm -rf "$USER_HOME/Library/Application Support/ChargeCap"
                /bin/rm -rf /Applications/ChargeCap.app
                echo 'ChargeCap 主应用及其管理的组件已清理。请将独立卸载器移入废纸篓。'
                """
                try script.write(to: scriptURL, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
                _ = try await runPrivileged(command: "/bin/bash \(shellQuote(scriptURL.path))")
                isBusy = false
                status = "卸载完成。若 ChargeCap.app 不在 /Applications 中，请手动将其移入废纸篓；最后也可删除此卸载器。"
                isError = false
            } catch {
                isBusy = false
                status = "卸载未完成：\(error.localizedDescription)。未强制删除控制组件，请检查提示后重试。"
                isError = true
            }
        }
    }

    private func runPrivileged(command: String) async throws -> String {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = "do shell script \"\(escaped)\" with administrator privileges"
        return try await runProcess(path: "/usr/bin/osascript", arguments: ["-e", appleScript])
    }

    private func runProcess(path: String, arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
                return
            }
            // Read while the process runs to avoid pipe-buffer deadlocks.
            DispatchQueue.global(qos: .utility).async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let output = String(data: data, encoding: .utf8) ?? ""
                if process.terminationStatus == 0 {
                    continuation.resume(returning: output)
                } else {
                    continuation.resume(throwing: UninstallerError.failed(output.isEmpty ? "管理员授权被取消或卸载命令失败" : output))
                }
            }
        }
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private enum UninstallerError: LocalizedError {
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .failed(let message): return message.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }
}
