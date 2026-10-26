import Foundation
import ServiceManagement

@main
struct LoginItemSettingsTests {
    static var checks = 0

    @MainActor
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    @MainActor
    static func main() {
        var actual: SMAppService.Status = .notRegistered
        var registers = 0
        var unregisters = 0
        var failRegister = false
        var failUnregister = false
        var nextStatus: SMAppService.Status = .enabled
        let failure = NSError(domain: "LoginItemFixture", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "fixture: denied"])
        let model = LoginItemSettings(readStatus: { actual }, register: {
            registers += 1
            if failRegister { throw failure }
            actual = nextStatus
        }, unregister: {
            unregisters += 1
            if failUnregister { throw failure }
            actual = .notRegistered
        })
        check(!model.isRequested && registers == 0 && unregisters == 0, "launch does not enable login items")
        model.refresh()
        check(registers == 0 && unregisters == 0, "refresh is read-only")
        model.setEnabled(false)
        check(unregisters == 0, "disabled initial state does not unregister an absent service")
        model.setEnabled(true)
        check(model.isRequested && model.status == .enabled && registers == 1, "explicit enable registers the main app")
        check(model.errorMessage == nil, "successful enable completes cleanly")
        model.setEnabled(true)
        check(registers == 1, "repeated enable does not duplicate registration")
        let relaunched = LoginItemSettings(readStatus: { actual }, register: {}, unregister: {})
        check(relaunched.isRequested, "new app instance reads the saved system registration")
        check(registers == 1 && unregisters == 0, "reading persisted state does not modify it")
        model.setEnabled(false)
        check(!model.isRequested && unregisters == 1, "explicit disable unregisters the main app")

        nextStatus = .requiresApproval
        model.setEnabled(true)
        check(model.isRequested && model.status == .requiresApproval, "pending approval remains cancellable")
        check(model.explanation.localized(in: .english).contains("Waiting for system approval"), "pending approval is not described as active")
        model.setEnabled(false)
        check(model.status == .notRegistered, "user can cancel a pending approval request")

        actual = .enabled
        model.refresh()
        check(model.isRequested, "external system enable is reflected")
        failUnregister = true
        model.setEnabled(false)
        check(model.isRequested && model.errorMessage != nil, "failed disable keeps actual system state and reports the error")
        check(model.errorMessage!.localized(in: .english).contains("fixture: denied"), "failure preserves the native error detail")
        failUnregister = false
        model.setEnabled(false)
        check(!model.isRequested && model.errorMessage == nil, "disable can be retried after failure")

        failRegister = true
        model.setEnabled(true)
        check(!model.isRequested && model.errorMessage != nil, "failed enable does not falsely switch on")
        failRegister = false
        nextStatus = .notRegistered
        model.setEnabled(true)
        check(!model.isRequested && model.errorMessage != nil, "unverified registration is not reported as enabled")
        actual = .notFound
        model.refresh()
        check(!model.isRequested, "missing app registration is off")
        actual = .enabled
        model.refresh()
        actual = .notRegistered
        model.refresh()
        check(!model.isRequested, "external system disable is reflected without re-enabling")

        print("LoginItemSettingsTests: PASS (\(checks) checks; simulated service, no real login item changes)")
    }
}
