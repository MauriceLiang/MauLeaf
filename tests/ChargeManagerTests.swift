import Foundation

@main
private enum ChargeManagerTests {
    @MainActor
    static func main() async throws {
        let backend = FixtureNativeFirmwareBackend()
        UserDefaults.standard.set(false, forKey: "nativeFirmwareWriteConfirmed")
        UserDefaults.standard.set(80, forKey: "chargeLimit")
        let manager = ChargeManager(backend: backend, autoInstallNativeHelper: false)
        manager.start()
        try await wait { manager.backendReady && manager.currentState != nil }
        manager.isAdapterConnected = true
        manager.batteryPercent = 80

        try check(manager.menuBarLeafStyle == .green, "menu-bar leaf is fixed to green")
        try check(manager.limit == 80 && manager.modeText.source == "限制充电未启用",
                  "startup leaves firmware charging limits disabled")

        manager.requestLimit(85, immediate: true)
        try check(manager.limit == 85 && backend.applyCount == 0 && !manager.showNativeWriteConfirmation,
                  "changing the limit before activation only saves the local preference")

        manager.enableLimit()
        try check(manager.showNativeWriteConfirmation && backend.applyCount == 0,
                  "first activation requires explicit hardware-write confirmation")
        manager.confirmNativeWrite()
        try await wait { backend.applyCount == 1 && !manager.isBusy }
        try check(backend.state.active && backend.state.upper == 85 && backend.state.lower == 83,
                  "confirmed activation writes the requested native upper and resume thresholds")
        try check(manager.hasOriginalStateSnapshot,
                  "the original firmware state is captured before the first managed limit is applied")
        try check(!manager.isError && manager.statusMessage.source.contains("Fake native firmware"),
                  "success reports register read-back, not unverified charging enforcement")

        manager.batteryPercent = 90
        manager.beginOneTimeFullCharge()
        try await wait { backend.beginCount == 1 && !manager.isBusy }
        try check(manager.fullOncePending && !backend.state.active && manager.hasOriginalStateSnapshot,
                  "one-time full charge temporarily disables the active limit but keeps the original snapshot")
        manager.cancelFullOnce()
        try await wait { backend.cancelCount == 1 && !manager.isBusy }
        try check(!manager.fullOncePending && backend.state.active && backend.state.upper == 85,
                  "cancelling one-time full charge restores the current MauLeaf limit")

        backend.failNextApply = true
        manager.requestLimit(90, immediate: true)
        try await wait { backend.applyCount == 2 && !manager.isBusy }
        try check(manager.isError, "failed native write is reported")
        manager.retryChargeRequest()
        try await wait { backend.applyCount == 3 && !manager.isBusy }
        try check(!manager.isError && backend.state.upper == 90 && manager.hasOriginalStateSnapshot,
                  "retry updates the active limit without overwriting the original snapshot")

        manager.isAdapterConnected = false
        manager.requestLimit(95, immediate: true)
        try check(backend.applyCount == 3 && manager.isError,
                  "native firmware writes are blocked without AC power")
        manager.isAdapterConnected = true

        manager.disableLimit()
        try await wait { backend.restoreCount == 1 && !manager.isBusy }
        try check(!manager.hasOriginalStateSnapshot && !backend.state.active
                  && backend.state.upper == 80 && backend.state.lower == 78,
                  "disabling restores the exact pre-MauLeaf firmware state and removes the snapshot")

        let allowed = await manager.prepareForTermination()
        try check(allowed, "app can quit after current operation completes")
        try check(!backend.state.active && !backend.pending,
                  "quitting after disable leaves the original firmware state intact")

        UserDefaults.standard.removeObject(forKey: "nativeFirmwareWriteConfirmed")
        print("ChargeManagerTests: PASS (opt-in activation, snapshot preservation, exact disable restore, AC guard)")
    }

    @MainActor
    private static func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<300 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw NSError(domain: "ChargeManagerTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for native manager operation"])
    }

    @MainActor
    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            throw NSError(domain: "ChargeManagerTests", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}
