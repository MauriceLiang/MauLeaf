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
        try await wait { manager.backendReady }
        manager.isAdapterConnected = true
        manager.batteryPercent = 80

        try check(manager.menuBarLeafStyle == .green, "menu-bar leaf is fixed to green")
        try check(manager.limit == 80 && manager.modeText.source == "原生固件限充至 80%",
                   "startup reflects the observed native firmware limit")

        manager.requestLimit(85, immediate: true)
        try check(manager.showNativeWriteConfirmation && backend.applyCount == 0,
                  "first hardware write requires explicit user confirmation")
        manager.confirmNativeWrite()
        try await wait { backend.applyCount == 1 && !manager.isBusy }
        try check(backend.state.active && backend.state.upper == 85 && backend.state.lower == 83,
                  "confirmed limit writes the native upper and resume thresholds")
        try check(!manager.isError && manager.statusMessage.source.contains("Fake native firmware"),
                  "success reports read-back, not claimed charging enforcement")

        manager.batteryPercent = 90
        manager.beginOneTimeFullCharge()
        try await wait { backend.beginCount == 1 && !manager.isBusy }
        try check(manager.fullOncePending && !backend.state.active,
                  "one-time full charge disables only the firmware limit")
        manager.cancelFullOnce()
        try await wait { backend.cancelCount == 1 && !manager.isBusy }
        try check(!manager.fullOncePending && backend.state.active && backend.state.upper == 85,
                  "cancellation restores the saved native limit")

        backend.failNextApply = true
        manager.requestLimit(90, immediate: true)
        try await wait { backend.applyCount == 2 && !manager.isBusy }
        try check(manager.isError, "failed native write is reported")
        manager.retryChargeRequest()
        try await wait { backend.applyCount == 3 && !manager.isBusy }
        try check(!manager.isError && backend.state.upper == 90,
                  "retry repeats the failed native operation")

        manager.isAdapterConnected = false
        manager.requestLimit(95, immediate: true)
        try check(backend.applyCount == 3 && manager.isError,
                  "native firmware writes are blocked without AC power")
        manager.isAdapterConnected = true

        let allowed = await manager.prepareForTermination()
        try check(allowed, "app can quit after current operation completes")
        try check(backend.state.active && backend.state.upper == 90 && !backend.pending,
                  "quitting the UI does not clear the persistent firmware limit")

        UserDefaults.standard.removeObject(forKey: "nativeFirmwareWriteConfirmed")
        print("ChargeManagerTests: PASS (native-only control, explicit consent, AC guard, restore and retry)")
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
