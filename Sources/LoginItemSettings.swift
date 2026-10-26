import Foundation
import Combine
import ServiceManagement

/// Read the OS registration state instead of saving an independent Boolean.
/// Reading or launching the app never registers a login item.
@MainActor
final class LoginItemSettings: ObservableObject {
    @Published private(set) var status: SMAppService.Status
    @Published var errorMessage: AppText?

    private let readStatus: () -> SMAppService.Status
    private let register: () throws -> Void
    private let unregister: () throws -> Void

    init(readStatus: @escaping () -> SMAppService.Status = { SMAppService.mainApp.status },
         register: @escaping () throws -> Void = { try SMAppService.mainApp.register() },
         unregister: @escaping () throws -> Void = { try SMAppService.mainApp.unregister() }) {
        self.readStatus = readStatus
        self.register = register
        self.unregister = unregister
        status = readStatus()
    }

    // A pending request stays selected so the user can cancel it. Its
    // explanation explicitly says it is not yet allowed to launch.
    var isRequested: Bool { status == .enabled || status == .requiresApproval }

    var explanation: AppText {
        if status == .requiresApproval { return "等待系统允许，请在登录项设置中开启 MauLeaf 后生效。" }
        return "登录 Mac 后自动启动 MauLeaf；关闭后不会在下次登录时启动。"
    }

    func refresh() { status = readStatus() }

    func setEnabled(_ enabled: Bool) {
        refresh()
        errorMessage = nil
        guard enabled != isRequested else { return }
        do {
            if enabled { try register() }
            else { try unregister() }
            refresh()
            guard enabled == isRequested else {
                errorMessage = "系统尚未确认登录项更改，请检查系统设置后重试。"
                return
            }
        } catch {
            refresh()
            errorMessage = "登录项设置失败：\(AppText(error: error))"
        }
    }

    static func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
